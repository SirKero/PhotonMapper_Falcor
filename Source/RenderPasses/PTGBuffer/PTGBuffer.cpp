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

    const uint32_t kMaxPayloadSizeBytes = 80u;
    const uint32_t kMaxAttributeSizeBytes = 8u;
    const uint32_t kMaxRecursionDepth = 2u;

    const ChannelList kOutputChannels = {
        {"Output",          "gOutput",          "Testing Output Image",        false /* optional */, ResourceFormat::RGBA32Float },
        { "posW",           "gPosW",            "world space position",         false /* optional */, ResourceFormat::RGBA32Float },
        { "normW",          "gNormW",           "world space normal",           false /* optional */, ResourceFormat::RGBA32Float },
        { "tangentW",       "gTangentW",        "world space tangent",          false /* optional */, ResourceFormat::RGBA32Float },
        { "texC",           "gTexC",            "texture coordinates",          false /* optional */, ResourceFormat::RGBA32Float },
        { "diffuseOpacity", "gDiffuseOpacity",  "diffuse color and opacity",    false /* optional */, ResourceFormat::RGBA32Float },
        { "specRough",      "gSpecRough",       "specular color and roughness", false /* optional */, ResourceFormat::RGBA32Float },
        { "emissive",       "gEmissive",        "emissive color",               false /* optional */, ResourceFormat::RGBA32Float },
        { "matlExtra",      "gMatlExtra",       "additional material data",     false /* optional */, ResourceFormat::RGBA32Uint },
        { "viewW",          "gViewWorld",       "World View Direction",             false /* optional */, ResourceFormat::RGBA32Float },
        { "faceNormal",     "gFaceNormal",      "Normal for the face",              false /* optional */, ResourceFormat::RGBA32Float },
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
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    // Trace the Scene
    mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pVars, uint3(targetDim, 1));

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
    bool dirty = false;

    //miscellaneous
    dirty |= widget.slider("Max Recursion Depth", mRecursionDepth, 1u, 32u);
    widget.tooltip("Maximum path length for Photon Bounces");

    //set flag to indicate that settings have changed and the pass has to be rebuild
    if (dirty)
        mOptionsChanged = true;
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
