/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "PTGBuffer.h"
#include <RenderGraph/RenderPassHelpers.h>

const RenderPass::Info PTGBuffer::kInfo{ "PTGBuffer", "A GBuffer that traces until it reaches a diffuse Surface." };

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary & lib)
{
    lib.registerPass(PTGBuffer::kInfo, PTGBuffer::create);
}

namespace
{
    const char kShader[] = "RenderPasses/PTGBuffer/PTGBuffer.rt.slang";
    const char kDesc[] = "A GBuffer that traces until it reaches a diffuse Surface";

    const uint32_t kMaxPayloadSizeBytes = 64u;
    const uint32_t kMaxAttributeSizeBytes = 8u;
    const uint32_t kMaxRecursionDepth = 2u;

    const ChannelList kOutputChannels = {
        { "posW",           "gPosW",            "world space position",              false , ResourceFormat::RGBA32Float },
        { "normW",          "gNormW",           "world space normal",                false , ResourceFormat::RGBA32Float },
        { "tangentW",       "gTangentW",        "world space tangent",               false , ResourceFormat::RGBA32Float },
        { "texC",           "gTexC",            "texture coordinates",               false , ResourceFormat::RGBA32Float },
        { "viewW",          "gViewWorld",       "World View Direction",              false , ResourceFormat::RGBA32Float },
        { "faceNormal",     "gFaceNormal",      "Normal for the face",               false, ResourceFormat::RGBA32Float },
        { "throughputMatID", "gThpMatID",       "Throughput and material id(w)",     false , ResourceFormat::RGBA32Float },
        { "emissive",       "gEmissive",        "Emissive color",                    false , ResourceFormat::RGBA32Float },
    };

    // UI variables.
    const Gui::DropdownList kSamplePatternList =
    {
        { (uint32_t)PTGBuffer::SamplePattern::Center, "Center" },
        { (uint32_t)PTGBuffer::SamplePattern::DirectX, "DirectX" },
        { (uint32_t)PTGBuffer::SamplePattern::Halton, "Halton" },
        { (uint32_t)PTGBuffer::SamplePattern::Stratified, "Stratified" },
    };
}

PTGBuffer::SharedPtr PTGBuffer::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new PTGBuffer);
    return pPass;
}

PTGBuffer::PTGBuffer()
    : RenderPass(kInfo)
{
    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

Dictionary PTGBuffer::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection PTGBuffer::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

void PTGBuffer::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    /// Update refresh flag if options that affect the output have changed.
    auto& dict = renderData.getDictionary();
    if (mOptionsChanged) {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }

    //If we have no scene just return
    if (!mpScene)
        return;

    if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::GeometryChanged))
        throw std::runtime_error("This render pass does not support scene geometry changes. Aborting.");

    //Check if camera jitter sample gen needs to be set
    if (mFrameDim != renderData.getDefaultTextureDims() || mJitterGenChanged ) {
        setCameraJitter(renderData.getDefaultTextureDims());
        mJitterGenChanged = false;
    }

    //clear all output images
    auto clear = [&](const ChannelDesc& channel)
    {
        auto pTex = renderData[channel.name]->asTexture();
        if (pTex) pRenderContext->clearUAV(pTex->getUAV().get(), float4(0.f));
    };
    for (const auto& channel : kOutputChannels) clear(channel);

    // Specialize the program
    // These defines should not modify the program vars. Do not trigger program vars re-creation.
    mTracer.pProgram->addDefine("MAX_RECURSION", std::to_string(mRecursionDepth));
    mTracer.pProgram->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");

    // Prepare program vars. This may trigger shader compilation.
    // The program should have all necessary defines set at this point.

    if (!mTracer.pVars) prepareVars();
    FALCOR_ASSERT(mTracer.pVars);

    // Set constants.
    auto var = mTracer.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    //Set Buffers
        //No Buffers needed atm

    // Bind Output Textures. These needs to be done per-frame as the buffers may change anytime.
    auto bindAsTex = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData[desc.name]->asTexture();
        }
    };

    for (auto& output : kOutputChannels) bindAsTex(output);

    // Get dimensions of ray dispatch.
    FALCOR_ASSERT(mFrameDim.x > 0 && mFrameDim.y > 0);

    // Trace the Scene
    mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pVars, uint3(mFrameDim, 1));

    mFrameCount++;
}

void PTGBuffer::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    //Clear data from previous scenne
    //Rt program should be recreated
    mTracer = RayTraceProgramHelper::create();

    mpScene = pScene;

    if (mpScene) {
        if (mpScene->hasGeometryType(Scene::GeometryType::Custom))
        {
            logWarning("This render pass only supports triangles. Other types of geometry will be ignored.");
        }

        //Create Ray Tracing Program
        RtProgram::Desc desc;
        desc.addShaderLibrary(kShader);
        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        //desc.addDefines(mpScene->getSceneDefines());

        mTracer.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mTracer.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));
        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh)) {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit"));
        }

        mTracer.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
    }
}

void PTGBuffer::renderUI(Gui::Widgets& widget)
{
    //Recursion Settings
    mOptionsChanged |= widget.slider("Max Recursion Depth", mRecursionDepth, 1u, 32u);
    widget.tooltip("Maximum path length for Photon Bounces");

    // Sample pattern controls.
    bool updatePattern = widget.dropdown("Sample pattern", kSamplePatternList, (uint32_t&)mSamplePattern);
    widget.tooltip("Selects sample pattern for anti-aliasing over multiple frames.\n\n"
        "The camera jitter is set at the start of each frame based on the chosen pattern. All render passes should see the same jitter.\n"
        "'Center' disables anti-aliasing by always sampling at the center of the pixel.", true);
    if (mSamplePattern != SamplePattern::Center)
    {
        updatePattern |= widget.var("Sample count", mSampleCount, 1u);
        widget.tooltip("Number of samples in the anti-aliasing sample pattern.", true);
    }
    if (updatePattern)
    {
        updateSamplePattern();
        mJitterGenChanged = true;
    }
   
}

void PTGBuffer::prepareVars()
{
    FALCOR_ASSERT(mTracer.pProgram);

    //Configure Program
    mTracer.pProgram->addDefines(mpSampleGenerator->getDefines());
    mTracer.pProgram->setTypeConformances(mpScene->getTypeConformances());

    // Create program variables for the current program.
    // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
    mTracer.pVars = RtProgramVars::create(mTracer.pProgram, mTracer.pBindingTable);

    // Bind utility classes into shared data.
    auto var = mTracer.pVars->getRootVar();
    mpSampleGenerator->setShaderData(var);
}

static CPUSampleGenerator::SharedPtr createSamplePattern(PTGBuffer::SamplePattern type, uint32_t sampleCount)
{
    switch (type)
    {
    case PTGBuffer::SamplePattern::Center:
        return nullptr;
    case PTGBuffer::SamplePattern::DirectX:
        return DxSamplePattern::create(sampleCount);
    case PTGBuffer::SamplePattern::Halton:
        return HaltonSamplePattern::create(sampleCount);
    case PTGBuffer::SamplePattern::Stratified:
        return StratifiedSamplePattern::create(sampleCount);
    default:
        FALCOR_UNREACHABLE();
        return nullptr;
    }
}

void PTGBuffer::setCameraJitter(const uint2 frameDim) {
    FALCOR_ASSERT(frameDim.x > 0 && frameDim.y > 0);
    mFrameDim = frameDim;
    float2 mInvFrameDim = 1.f / float2(frameDim);

    // Update sample generator for camera jitter.
    if (mpScene) mpScene->getCamera()->setPatternGenerator(mpCameraJitterSampleGenerator, mInvFrameDim);
}

void PTGBuffer::updateSamplePattern() {
    mpCameraJitterSampleGenerator = createSamplePattern(mSamplePattern, mSampleCount);
    if (mpCameraJitterSampleGenerator) mSampleCount = mpCameraJitterSampleGenerator->getSampleCount();
}
