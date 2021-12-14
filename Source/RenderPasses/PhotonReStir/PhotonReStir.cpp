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
#include "PhotonReStir.h"
#include <RenderGraph/RenderPassHelpers.h>

namespace
{
    const char kShaderGeneratePhoton[] = "RenderPasses/PhotonReStir/PhotonReStirGenerate.rt.slang";
    const char kShaderCollectPhoton[] = "RenderPasses/PhotonReStir/PhotonReStirCollect.rt.slang";
    const char kDesc[] = "Shoots Photons and then gathers them";

    // Ray tracing settings that affect the traversal stack size.
   // These should be set as small as possible.
   //TODO: set them later to the right vals
    const uint32_t kMaxPayloadSizeBytes = 80u;
    const uint32_t kMaxAttributeSizeBytes = 8u;
    const uint32_t kMaxRecursionDepth = 2u;

    const ChannelList kInputChannels =
    {
        { "WPos",          "gWPos",               " World Position "                   ,true }, ///< optional for now
        { "WNormal",       "gWNormals",           " World Normals "                    ,true }, ///< optional for now
    };

    const ChannelList kOutputChannels =
    {
        { "PhotonImage",          "gPhotonImage",               "An image that shows the caustics and indirect light from global photons"                        },
    };

    
    const char kCausticAABBDesc[] = "A buffer holding the AABB Data for the caustic Photons";
    const char kCausticInfoDesc[] = "A buffer holding the Photon Info Data for the caustic Photons";
    const char kGlobalAABBDesc[] = "A buffer holding the AABB Data for the global Photons";
    const char kGlobalInfoDesc[] = "A buffer holding the Photon Info Data for the global Photons";

    const char kCausticAABBSName[] = "gCausticAABB";
    const char kCausticInfoSName[] = "gCaustic";
    const char kGlobalAABBSName[] = "gGlobalAABB";
    const char kGlobalInfoSName[] = "gGlobal";
}

// Don't remove this. it's required for hot-reload to function properly
extern "C" __declspec(dllexport) const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" __declspec(dllexport) void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerClass("PhotonReStir", kDesc, PhotonReStir::create);
}

PhotonReStir::SharedPtr PhotonReStir::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new PhotonReStir);
    return pPass;
}

PhotonReStir::PhotonReStir()
{
    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_DEFAULT);
    assert(mpSampleGenerator);
}


std::string PhotonReStir::getDesc() { return kDesc; }

Dictionary PhotonReStir::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection PhotonReStir::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);

    /*
    reflector.addOutput("CausticAABB", kCausticAABBDesc).rawBuffer(mNumPhotons * sizeof(AABB));
    reflector.addOutput("CausticInfo", kCausticInfoDesc).rawBuffer(mNumPhotons * sizeof(AABB));
    reflector.addOutput("GlobalAABB", kGlobalAABBDesc).rawBuffer(mNumPhotons * sizeof(AABB));
    reflector.addOutput("GlobalInfo", kGlobalInfoDesc).rawBuffer(mNumPhotons * sizeof(AABB));
    */

    return reflector;
}

void PhotonReStir::compile(RenderContext* pContext, const CompileData& compileData)
{
    // put reflector outputs here and create again if needed
    
}

void PhotonReStir::execute(RenderContext* pRenderContext, const RenderData& renderData)
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
    {
        return;
    }

    if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::GeometryChanged))
    {
        throw std::runtime_error("This render pass does not support scene geometry changes. Aborting.");
    }

    // Request the light collection if emissive lights are enabled.
    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    
    if (!mPhotonBuffersReady)
        mPhotonBuffersReady = preparePhotonBuffers();

    //
    // Generate Ray Pass
    //


   


    generatePhotons(pRenderContext, renderData);
    

    //flush
    //pRenderContext->flush();

    //Gather the photons with short rays
    

    mFrameCount++;
}

void PhotonReStir::generatePhotons(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Reset counter Buffers
    pRenderContext->copyBufferRegion(mPhotonCounterBuffer.counter.get(), 0, mPhotonCounterBuffer.reset.get(), 0, sizeof(uint64_t));

    // Specialize the Generate program.
   // These defines should not modify the program vars. Do not trigger program vars re-creation.
    mTracerGenerate.pProgram->addDefine("MAX_BOUNCES", std::to_string(mMaxBounces));
    mTracerGenerate.pProgram->addDefine("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    mTracerGenerate.pProgram->addDefine("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    mTracerGenerate.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    mTracerGenerate.pProgram->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    mTracerGenerate.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mTracerGenerate.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    // Prepare program vars. This may trigger shader compilation.
    // The program should have all necessary defines set at this point.

    if (!mTracerGenerate.pVars) prepareVars();
    assert(mTracerGenerate.pVars);

    // Set constants.
    auto var = mTracerGenerate.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;

    //set the buffers

    var[kCausticAABBSName] = mCausticBuffers.aabb;
    var[kCausticInfoSName] = mCausticBuffers.info;
    var[kGlobalAABBSName] = mGlobalBuffers.aabb;
    var[kGlobalInfoSName] = mGlobalBuffers.info;

    var["gPhotonCounter"] = mPhotonCounterBuffer.counter;
    // Bind Output Buffers. These needs to be done per-frame as the buffers may change anytime.
    /*
    var[kCausticAABBSName] = renderData["CausticAABB"]->asBuffer();
    var[kCausticInfoSName] = renderData["CausticInfo"]->asBuffer();
    var[kGlobalAABBSName] = renderData["GlobalAABB"]->asBuffer();
    var[kGlobalInfoSName] = renderData["GlobalInfo"]->asBuffer();
    */

    // Bind Output Textures. These needs to be done per-frame as the buffers may change anytime.
    auto bindAsTex = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData[desc.name]->asTexture();
        }
    };
    for (auto channel : kOutputChannels) bindAsTex(channel);

    // Get dimensions of ray dispatch.
    const uint2 targetDim = uint2(static_cast<uint>(sqrt(mNumPhotons)));
    assert(targetDim.x > 0 && targetDim.y > 0);

    // Trace the photons
    mpScene->raytrace(pRenderContext, mTracerGenerate.pProgram.get(), mTracerGenerate.pVars, uint3(targetDim, 1));
}

void PhotonReStir::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;

    dirty |= widget.var("Max bounces", mMaxBounces, 0u, 1u << 16);
    widget.tooltip("Maximum path length for Photon Bounces");

    //set flag to indicate that settings have changed and the pass has to be rebuild
    if (dirty)
        mOptionsChanged = true;
}

void PhotonReStir::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    // Clear data for previous scene.
   // After changing scene, the raytracing program should to be recreated.
    mTracerGenerate.pProgram = nullptr;
    mTracerGenerate.pBindingTable = nullptr;
    mTracerGenerate.pVars = nullptr;
    mFrameCount = 0;

    // Set new scene.
    mpScene = pScene;

    if (mpScene)
    {
        if (mpScene->hasGeometryType(Scene::GeometryType::Procedural))
        {
            logWarning("This render pass only supports triangles. Other types of geometry will be ignored.");
        }

        // Create ray tracing program.
        RtProgram::Desc desc;
        desc.addShaderLibrary(kShaderGeneratePhoton);
        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.addDefines(mpScene->getSceneDefines());
        

        mTracerGenerate.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mTracerGenerate.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));
        sbt->setHitGroupByType(0, mpScene, Scene::GeometryType::TriangleMesh, desc.addHitGroup("closestHit"));

        mTracerGenerate.pProgram = RtProgram::create(desc);
    }
}

void PhotonReStir::prepareVars()
{
    assert(mTracerGenerate.pProgram);

    // Configure program.
    mTracerGenerate.pProgram->addDefines(mpSampleGenerator->getDefines());

    // Create program variables for the current program.
    // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
    mTracerGenerate.pVars = RtProgramVars::create(mTracerGenerate.pProgram, mTracerGenerate.pBindingTable);

    // Bind utility classes into shared data.
    auto var = mTracerGenerate.pVars->getRootVar();
    bool success = mpSampleGenerator->setShaderData(var);
    if (!success) throw std::exception("Failed to bind sample generator");
}

bool PhotonReStir::preparePhotonBuffers()
{
    //caustic
    
    //if size is not initilized give it a standard value
    if (mCausticBuffers.maxSize == 0)
        mCausticBuffers.maxSize = mNumPhotons;

    //TODO: Change Buffer Generation to initilize with program
    mCausticBuffers.aabb = Buffer::createStructured(sizeof(D3D12_RAYTRACING_AABB), mCausticBuffers.maxSize);
    mCausticBuffers.aabb->setName("PhotonReStir::mCausticBuffers.aabb");
    mCausticBuffers.info = Buffer::createStructured(sizeof(PhotonInfo), mCausticBuffers.maxSize);
    mCausticBuffers.info->setName("PhotonReStir::mCausticBuffers.info");

    assert(mCausticBuffers.aabb);   assert(mCausticBuffers.info);

    //global

     //if size is not initilized give it a standard value
    if (mGlobalBuffers.maxSize == 0)
        mGlobalBuffers.maxSize = mNumPhotons;

    //only set aabb buffer if it is used
    if (!mUsePhotonReStir) {
        mGlobalBuffers.aabb = Buffer::createStructured(sizeof(D3D12_RAYTRACING_AABB), mGlobalBuffers.maxSize);
        mGlobalBuffers.aabb->setName("PhotonReStir::mGlobalBuffers.aabb");

        assert(mGlobalBuffers.aabb);
    }

    mGlobalBuffers.info = Buffer::createStructured(sizeof(PhotonInfo), mGlobalBuffers.maxSize);
    mGlobalBuffers.info->setName("PhotonReStir::mGlobalBuffers.info");

    assert(mGlobalBuffers.info);

    //photon counter
    mPhotonCounterBuffer.counter = Buffer::createStructured(sizeof(uint), 2);
    mPhotonCounterBuffer.counter->setName("PhotonReStir::PhotonCounter");
    uint64_t zeroInit = 0;
    mPhotonCounterBuffer.reset = Buffer::create(sizeof(uint64_t), ResourceBindFlags::None, Buffer::CpuAccess::None, &zeroInit);

    return true;
}
