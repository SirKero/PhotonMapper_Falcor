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
#include "PhotonMapper.h"
#include <RenderGraph/RenderPassHelpers.h>

//for random seed generation
#include <random>
#include <ctime>
#include <limits>

constexpr float kUint32tMaxF = float((uint32_t)-1);

const RenderPass::Info PhotonMapper::kInfo{"PhotonMapper", "A Photon Mapper with full RTX support" };

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary & lib)
{
    lib.registerPass(PhotonMapper::kInfo, PhotonMapper::create);
}

namespace
{
    const char kShaderGeneratePhoton[] = "RenderPasses/PhotonMapper/PhotonMapperGenerate.rt.slang";
    const char kShaderCollectPhoton[] = "RenderPasses/PhotonMapper/PhotonMapperCollect.rt.slang";

    // Ray tracing settings that affect the traversal stack size.
   // These should be set as small as possible.
   //TODO: set them later to the right vals
    const uint32_t kMaxPayloadSizeBytes = 80u;
    const uint32_t kMaxPayloadSizeBytesCollect = 96u;
    const uint32_t kMaxAttributeSizeBytes = 8u;
    const uint32_t kMaxRecursionDepth = 2u;

    const ChannelList kInputChannels =
    {
        {"posW",                "gWorldPosition",           "World Position",               false},
        {"normalW",             "gWorldNormal",             "World Normals",                false},
        {"tangentW",            "gWorldTangent",            "World Tangent",                false},
        {"texC",                "gTextureCoordinate",       "Texture Coordinate",           false},
        {"viewW",               "gViewWorld",               "World View Direction",         false},
        {"faceNormal",          "gFaceNormal",              "Normal for the face",          false},
        {"thpMatID",            "gThpMatID",                "Throughput and material id(w)",false},
        {"emissive",            "gEmissive",                "Emissive",                     false},
    };

    const ChannelList kOutputChannels =
    {
        { "PhotonImage",          "gPhotonImage",               "An image that shows the caustics and indirect light from global photons" , false , ResourceFormat::RGBA32Float }
    };


    const char kCausticAABBSName[] = "gCausticAABB";
    const char kCausticInfoSName[] = "gCaustic";
    const char kGlobalAABBSName[] = "gGlobalAABB";
    const char kGlobalInfoSName[] = "gGlobal";
}

PhotonMapper::SharedPtr PhotonMapper::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new PhotonMapper);
    return pPass;
}

PhotonMapper::PhotonMapper():
    RenderPass(kInfo)
{
    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

Dictionary PhotonMapper::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection PhotonMapper::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);


    return reflector;
}

void PhotonMapper::compile(RenderContext* pContext, const CompileData& compileData)
{
    // put reflector outputs here and create again if needed
    
}

void PhotonMapper::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    /// Update refresh flag if options that affect the output have changed.
    auto& dict = renderData.getDictionary();
    if (mOptionsChanged) {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mResetIterations = true;
        mOptionsChanged = false;
    }

    //If we have no scene just return
    if (!mpScene)
    {
        return;
    }

    //Reset Frame Count if conditions are met
    if (mResetIterations || mAlwaysResetIterations || is_set(mpScene->getUpdates(), Scene::UpdateFlags::CameraMoved)) {
        mFrameCount = 0;
        mResetIterations = false;
    }

    //reset radius
    if (mFrameCount == 0) {
        mCausticRadius = mCausticRadiusStart;
        mGlobalRadius = mGlobalRadiusStart;
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

    if (mResizePhotonBuffers) {
        //if size of conter is 0 wait till next iteration
        if (mPhotonCount[0] > 0 || mPhotonCount[1] > 0) {
            //Set size as max + 10%
            mCausticBuffers.maxSize = (uint)(mPhotonCount[0] * 1.1f);
            mGlobalBuffers.maxSize = (uint)(mPhotonCount[1] * 1.1f);
            mResizePhotonBuffers = false;
            mPhotonBuffersReady = false;
            mRebuildAS = true;
        }
    }
    
    if (!mPhotonBuffersReady) {
        mPhotonBuffersReady = preparePhotonBuffers();
    }

    if (!mRandNumSeedBuffer) {
        prepareRandomSeedBuffer(renderData.getDefaultTextureDims());
    }


    //
    // Generate Ray Pass
    //

    generatePhotons(pRenderContext, renderData);

         
    //barrier for the aabb buffers and copying the needed datas
    bool valid = syncPasses(pRenderContext);

    //Gather the photons with short rays
    if (valid && !mResizePhotonBuffers) {
        collectPhotons(pRenderContext, renderData);
        mFrameCount++;

        if (mUseStatisticProgressivePM) {
            float itF = static_cast<float>(mFrameCount);
            mGlobalRadius *= sqrt((itF + mSPPMAlphaGlobal) / (itF + 1.0f));
            mCausticRadius *= sqrt((itF + mSPPMAlphaCaustic) / (itF + 1.0f));

            //Clamp to min radius
            mGlobalRadius = std::max(mGlobalRadius, kMinPhotonRadius);
            mCausticRadius = std::max(mCausticRadius, kMinPhotonRadius);
        }
    }
    //check if the photon buffers needs to be resized (max size reached)
    if (mPhotonCount[0] >= mCausticBuffers.maxSize || mPhotonCount[1] >= mGlobalBuffers.maxSize)
        mResizePhotonBuffers = true;
}

void PhotonMapper::generatePhotons(RenderContext* pRenderContext, const RenderData& renderData)
{

    //Reset counter Buffers
    pRenderContext->copyBufferRegion(mPhotonCounterBuffer.counter.get(), 0, mPhotonCounterBuffer.reset.get(), 0, sizeof(uint64_t));
    pRenderContext->resourceBarrier(mPhotonCounterBuffer.counter.get(), Resource::State::ShaderResource);


    auto lights = mpScene->getLights();
    auto lightCollection = mpScene->getLightCollection(pRenderContext);

    // Specialize the Generate program.
    // These defines should not modify the program vars. Do not trigger program vars re-creation.
    mTracerGenerate.pProgram->addDefine("MAX_RECURSION", std::to_string(mMaxBounces));
    mTracerGenerate.pProgram->addDefine("MAX_UINT32F", std::to_string(kUint32tMaxF));
    mTracerGenerate.pProgram->addDefine("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    mTracerGenerate.pProgram->addDefine("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    mTracerGenerate.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    mTracerGenerate.pProgram->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    mTracerGenerate.pProgram->addDefine("MAX_PHOTON_INDEX_GLOBAL", std::to_string(mGlobalBuffers.maxSize));
    mTracerGenerate.pProgram->addDefine("MAX_PHOTON_INDEX_CAUSTIC", std::to_string(mCausticBuffers.maxSize));
    mTracerGenerate.pProgram->addDefine("ALLOW_WRITES", mResizePhotonBuffers ? "0" : "1");

    
    // Prepare program vars. This may trigger shader compilation.
    // The program should have all necessary defines set at this point.

    if (!mTracerGenerate.pVars) prepareVars();
    FALCOR_ASSERT(mTracerGenerate.pVars);

    auto& dict = renderData.getDictionary();

    // Set constants.
    auto var = mTracerGenerate.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gDirLightWorldPos"] = mDirLightWorldPos;
    var["CB"]["gCausticRadius"] = mCausticRadius;
    var["CB"]["gGlobalRadius"] = mGlobalRadius;
    var["CB"]["gRussianRoulette"] = mRussianRoulette;
    var["CB"]["gEmissiveScale"] = mIntensityScalar;
    var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
        

    //set the buffers

    var[kCausticAABBSName] = mCausticBuffers.aabb;
    var[kCausticInfoSName] = mCausticBuffers.info;
    var[kGlobalAABBSName] = mGlobalBuffers.aabb;
    var[kGlobalInfoSName] = mGlobalBuffers.info;
    var["gRndSeedBuffer"] = mRandNumSeedBuffer;

    var["gPhotonCounter"] = mPhotonCounterBuffer.counter;
   

    // Bind Output Textures. These needs to be done per-frame as the buffers may change anytime.
    auto bindAsTex = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData[desc.name]->asTexture();
        }
    };

    // Get dimensions of ray dispatch.
    const uint2 targetDim = uint2(static_cast<uint>(sqrt(mNumPhotons)));
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    // Trace the photons
    mpScene->raytrace(pRenderContext, mTracerGenerate.pProgram.get(), mTracerGenerate.pVars, uint3(targetDim, 1));
}

bool PhotonMapper::syncPasses(RenderContext* pRenderContext)
{
    FALCOR_PROFILE("syncPasses");
    //Copy the photonConter to a CPU Buffer
    pRenderContext->uavBarrier(mPhotonCounterBuffer.counter.get());
    pRenderContext->copyBufferRegion(mPhotonCounterBuffer.cpuCopy.get(),0, mPhotonCounterBuffer.counter.get(),0, sizeof(uint32_t) * 2);

    //TODO:: Implement a better way than a full flush
    pRenderContext->flush(true);

    void* data = mPhotonCounterBuffer.cpuCopy->map(Buffer::MapType::Read);
    std::memcpy(mPhotonCount.data(), data, sizeof(uint) * 2);
    mPhotonCounterBuffer.cpuCopy->unmap();

    //When there are no photons or the photon buffer is not ready abort
    if (mPhotonCount[0] == 0 || !mPhotonBuffersReady)
        return false;

    createAccelerationStructure(pRenderContext, mPhotonCount);
    return true;
}

void PhotonMapper::collectPhotons(RenderContext* pRenderContext, const RenderData& renderData)
{
    // Trace the photons
    FALCOR_PROFILE("collect photons");
    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    mTracerCollect.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mTracerCollect.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    mTracerCollect.pProgram->addDefine("COLLECT_GLOBAL_PHOTONS", !mDisableGlobalCollection ? "1" : "0");
    mTracerCollect.pProgram->addDefine("COLLECT_CAUSTIC_PHOTONS", !mDisableCausticCollection ? "1" : "0");


    // Prepare program vars. This may trigger shader compilation.
    if (!mTracerCollect.pVars) {
        FALCOR_ASSERT(mTracerCollect.pProgram);
        mTracerCollect.pProgram->addDefines(mpSampleGenerator->getDefines());
        mTracerCollect.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mTracerCollect.pVars = RtProgramVars::create(mTracerCollect.pProgram, mTracerCollect.pBindingTable);
        // Bind utility classes into shared data.
        auto var = mTracerGenerate.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
    }
    FALCOR_ASSERT(mTracerCollect.pVars);

    // Set constants.
    auto var = mTracerCollect.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gCausticRadius"] = mCausticRadius;
    var["CB"]["gGlobalRadius"] = mGlobalRadius;
    var["CB"]["gNoColorOutput"] = false;            //TODO: save as variable
    var["CB"]["gEmissiveScale"] = mIntensityScalar;

    //set the buffers

    var[kCausticAABBSName] = mCausticBuffers.aabb;
    var[kCausticInfoSName] = mCausticBuffers.info;
    var[kGlobalAABBSName] = mGlobalBuffers.aabb;
    var[kGlobalInfoSName] = mGlobalBuffers.info;

    // Lamda for binding textures. These needs to be done per-frame as the buffers may change anytime.
    auto bindAsTex = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData[desc.name]->asTexture();
        }
    };
    //Bind input and output textures
    for (auto& channel : kInputChannels) bindAsTex(channel);
    bindAsTex(kOutputChannels[0]);

    // Get dimensions of ray dispatch.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    

    FALCOR_ASSERT(pRenderContext && mTracerCollect.pProgram && mTracerCollect.pVars);

    //bind TLAS
    bool tlasValid = var["gPhotonAS"].setSrv(mPhotonTlas.pSrv);
    FALCOR_ASSERT(tlasValid);
    
    //pRenderContext->raytrace(mTracerCollect.pProgram.get(), mTracerCollect.pVars.get(), targetDim.x, targetDim.y, 1);
    // Trace the photons
    mpScene->raytrace(pRenderContext, mTracerCollect.pProgram.get(), mTracerCollect.pVars, uint3(targetDim, 1));    //TODO: Check if scene defines can be set manually
}

void PhotonMapper::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;

    //Info
    widget.text("Iterations: " + std::to_string(mFrameCount));
    widget.text("Caustic Photons: " + std::to_string(mPhotonCount[0]) + " / " + std::to_string(mCausticBuffers.maxSize));
    widget.tooltip("Photons for current Iteration / Buffer Size");
    widget.text("Global Photons: " + std::to_string(mPhotonCount[1]) + " / " + std::to_string(mGlobalBuffers.maxSize));
    widget.tooltip("Photons for current Iteration / Buffer Size");

    widget.text("Current Global Radius: " + std::to_string(mGlobalRadius));
    widget.text("Current Caustic Radius: " + std::to_string(mCausticRadius));

    //Progressive PM
    dirty |= widget.checkbox("Use SPPM", mUseStatisticProgressivePM);
    widget.tooltip("Activate Statistically Progressive Photon Mapping");

    if (mUseStatisticProgressivePM) {
        dirty |= widget.var("Global Alpha", mSPPMAlphaGlobal, 0.1f, 1.0f, 0.001f);
        widget.tooltip("Sets the Alpha in SPPM for the Global Photons");
        dirty |= widget.var("Caustic Alpha", mSPPMAlphaGlobal, 0.1f, 1.0f, 0.001f);
        widget.tooltip("Sets the Alpha in SPPM for the Caustic Photons");
    }
    
    widget.text("");
    //miscellaneous
    dirty |= widget.slider("Max Recursion Depth", mMaxBounces, 1u, 32u);
    widget.tooltip("Maximum path length for Photon Bounces");
    dirty |= widget.var("DirLightPos", mDirLightWorldPos, -FLT_MAX, FLT_MAX, 0.001f);
    widget.tooltip("Position where all Dir lights come from");

    //Light settings
    dirty |= widget.var("IntensityScalar", mIntensityScalar, 0.0f, FLT_MAX, 0.001f);
    widget.tooltip("Scales the intensity of all Light Sources");

    //Radius settings
    dirty |= widget.var("Caustic Radius Start", mCausticRadiusStart, kMinPhotonRadius, FLT_MAX, 0.001f);
    widget.tooltip("The start value for the radius of caustic Photons");
    dirty |= widget.var("Global Radius Start", mGlobalRadiusStart, kMinPhotonRadius, FLT_MAX, 0.001f);
    widget.tooltip("The start value for the radius of global Photons");
    dirty |= widget.var("Russian Roulette", mRussianRoulette, 0.001f, 1.f, 0.001f);
    widget.tooltip("Probabilty that a Global Photon is saved");

    //Disable Photon Collecion
    widget.text("");
    dirty |= widget.checkbox("Disable Global Photons", mDisableGlobalCollection);
    widget.tooltip("Disables the collection of Global Photons. However they will still be generated");
    dirty |= widget.checkbox("Disable Caustic Photons", mDisableCausticCollection);
    widget.tooltip("Disables the collection of Caustic Photons. However they will still be generated");
    //Reset Iterations
    widget.text("");
    widget.checkbox("Always Reset Iterations", mAlwaysResetIterations);
    widget.tooltip("Always Resets the Iterations, currently good for moving the camera");
    mResetIterations |= widget.button("Reset Iterations");
    widget.tooltip("Resets the iterations");
    dirty |= mResetIterations;

    //set flag to indicate that settings have changed and the pass has to be rebuild
    if (dirty)
        mOptionsChanged = true;
}

void PhotonMapper::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    // Clear data for previous scene.
   // After changing scene, the raytracing program should to be recreated.
    mTracerGenerate = RayTraceProgramHelper::create();
    mTracerCollect = RayTraceProgramHelper::create();
    mFrameCount = 0;

    //For Photon Buffers and resize
    mResizePhotonBuffers = true; mPhotonBuffersReady = false;
    mCausticBuffers.maxSize = 0; mGlobalBuffers.maxSize = 0;
    mPhotonCount[0] = 0; mPhotonCount[1] = 0;
    
    // Set new scene.
    mpScene = pScene;

    if (mpScene)
    {
        if (mpScene->hasGeometryType(Scene::GeometryType::Custom))
        {
            logWarning("This render pass only supports triangles. Other types of geometry will be ignored.");
        }

        // Create ray tracing program.
        {
            RtProgram::Desc desc;
            desc.addShaderLibrary(kShaderGeneratePhoton);
            desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
            desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
            desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
            //desc.addDefines(mpScene->getSceneDefines());
            


            mTracerGenerate.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
            auto& sbt = mTracerGenerate.pBindingTable;
            sbt->setRayGen(desc.addRayGen("rayGen"));
            sbt->setMiss(0, desc.addMiss("miss"));
            if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh)) {
                sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit"));
            }

            mTracerGenerate.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
        }
        

        //Create the photon collect programm
        {
            RtProgram::Desc desc;
            desc.addShaderLibrary(kShaderCollectPhoton);
            desc.setMaxPayloadSize(kMaxPayloadSizeBytesCollect);
            desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
            desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
            //desc.addDefines(mpScene->getSceneDefines());

            mTracerCollect.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());   //TODO: Check if that can be removed
            auto& sbt = mTracerCollect.pBindingTable;
            sbt->setRayGen(desc.addRayGen("rayGen"));
            sbt->setMiss(0, desc.addMiss("miss"));
            auto hitShader = desc.addHitGroup("closestHit", "anyHit", "intersection");
            sbt->setHitGroup(0, 0, hitShader);
            

            mTracerCollect.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
        }
    }

    //init the photon counters
    preparePhotonCounters();
}

void PhotonMapper::prepareVars()
{
    FALCOR_ASSERT(mTracerGenerate.pProgram);

    // Configure program.
    mTracerGenerate.pProgram->addDefines(mpSampleGenerator->getDefines());
    mTracerGenerate.pProgram->setTypeConformances(mpScene->getTypeConformances());
    // Create program variables for the current program.
    // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
    mTracerGenerate.pVars = RtProgramVars::create(mTracerGenerate.pProgram, mTracerGenerate.pBindingTable);

    // Bind utility classes into shared data.
    auto var = mTracerGenerate.pVars->getRootVar();
    mpSampleGenerator->setShaderData(var);
}

bool PhotonMapper::preparePhotonBuffers()
{
    if (mCausticBuffers.maxSize == 0 || mGlobalBuffers.maxSize == 0)
        return false;

    //TODO: Change Buffer Generation to initilize with program
    mCausticBuffers.aabb = Buffer::createStructured(sizeof(D3D12_RAYTRACING_AABB), mCausticBuffers.maxSize);
    mCausticBuffers.aabb->setName("PhotonMapper::mCausticBuffers.aabb");
    mCausticBuffers.info = Buffer::createStructured(sizeof(PhotonInfo), mCausticBuffers.maxSize);
    mCausticBuffers.info->setName("PhotonMapper::mCausticBuffers.info");

    FALCOR_ASSERT(mCausticBuffers.aabb);   FALCOR_ASSERT(mCausticBuffers.info);

    //only set aabb buffer if it is used
    if (!mUsePhotonMapper) {
        mGlobalBuffers.aabb = Buffer::createStructured(sizeof(D3D12_RAYTRACING_AABB), mGlobalBuffers.maxSize);
        mGlobalBuffers.aabb->setName("PhotonMapper::mGlobalBuffers.aabb");

        FALCOR_ASSERT(mGlobalBuffers.aabb);
    }

    mGlobalBuffers.info = Buffer::createStructured(sizeof(PhotonInfo), mGlobalBuffers.maxSize);
    mGlobalBuffers.info->setName("PhotonMapper::mGlobalBuffers.info");

    FALCOR_ASSERT(mGlobalBuffers.info);


    return true;
}

void PhotonMapper::preparePhotonCounters()
{
    //photon counter
    mPhotonCounterBuffer.counter = Buffer::createStructured(sizeof(uint), 2);
    mPhotonCounterBuffer.counter->setName("PhotonMapper::PhotonCounter");
    uint64_t zeroInit = 0;
    mPhotonCounterBuffer.reset = Buffer::create(sizeof(uint64_t), ResourceBindFlags::None, Buffer::CpuAccess::None, &zeroInit);
    mPhotonCounterBuffer.reset->setName("PhotonMapper::PhotonCounterReset");
    uint32_t oneInit[2] = { 1,1 };
    mPhotonCounterBuffer.cpuCopy = Buffer::create(sizeof(uint64_t), ResourceBindFlags::None, Buffer::CpuAccess::Read, oneInit);
    mPhotonCounterBuffer.cpuCopy->setName("PhotonMapper::PhotonCounterCPU");
}

void PhotonMapper::createAccelerationStructure(RenderContext* pContext, const std::vector<uint>& aabbCount) {

    //clear all previous data
    if (mRebuildAS) {
        mBlasData.clear();
        mPhotonInstanceDesc.clear();
        mTlasScratch = nullptr;
        mPhotonTlas.pInstanceDescs = nullptr; mPhotonTlas.pSrv = nullptr; mPhotonTlas.pTlas = nullptr;
    }
    createBottomLevelAS(pContext, aabbCount, mRebuildAS);
    createTopLevelAS(pContext, mRebuildAS);
    if (mRebuildAS) mRebuildAS = false; //AS was rebuild so dont do that again

}
void PhotonMapper::createTopLevelAS(RenderContext* pContext, bool rebuild) {
    //TODO:: Update instead of bilding new

    //fill the instance description if empty
    if (mPhotonInstanceDesc.empty() || rebuild) {
        for (int i = 0; i < 2; i++) {
            D3D12_RAYTRACING_INSTANCE_DESC desc = {};
            desc.AccelerationStructure = i == 0 ? mCausticBuffers.blas->getGpuAddress() : mGlobalBuffers.blas->getGpuAddress();
            desc.Flags = D3D12_RAYTRACING_INSTANCE_FLAG_NONE;
            desc.InstanceID = i;
            desc.InstanceMask = i + 1;  //0b01 for Caustic and 0b10 for Global
            desc.InstanceContributionToHitGroupIndex = 0;

            //Create a identity matrix for the transform and copy it to the instance desc
            glm::mat4 transform4x4 = glm::identity<glm::mat4>();
            std::memcpy(desc.Transform, &transform4x4, sizeof(desc.Transform));
            mPhotonInstanceDesc.push_back(desc);
        }
    }

    FALCOR_PROFILE("buildPhotonTlas");

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs = {};
    inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
    inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
    inputs.NumDescs = (uint32_t)mPhotonInstanceDesc.size();
    inputs.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD;

    //if scratch is empty, create one
    if (mTlasScratch == nullptr || rebuild) {
        //Prebuild
        FALCOR_GET_COM_INTERFACE(gpDevice->getApiHandle(), ID3D12Device5, pDevice5);
        pDevice5->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &mTlasPrebuildInfo);
        mTlasScratch = Buffer::create(mTlasPrebuildInfo.ScratchDataSizeInBytes, Buffer::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);
        mTlasScratch->setName("PhotonMapper::TLAS_Scratch");
    }

    //if buffers for the tlas are empty create them
    if (mPhotonTlas.pTlas == nullptr || rebuild) {
        mPhotonTlas.pTlas = Buffer::create(mTlasPrebuildInfo.ResultDataMaxSizeInBytes, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);
        mPhotonTlas.pTlas->setName("PhotonMapper::TLAS");
        mPhotonTlas.pInstanceDescs = Buffer::create((uint32_t)mPhotonInstanceDesc.size() * sizeof(D3D12_RAYTRACING_INSTANCE_DESC), Buffer::BindFlags::None, Buffer::CpuAccess::Write, mPhotonInstanceDesc.data());
        mPhotonTlas.pInstanceDescs->setName("PhotonMapper:: TLAS Instance Description");
    }

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC asDesc = {};
    asDesc.Inputs = inputs;
    asDesc.Inputs.InstanceDescs = mPhotonTlas.pInstanceDescs->getGpuAddress();
    asDesc.ScratchAccelerationStructureData = mTlasScratch->getGpuAddress();
    asDesc.DestAccelerationStructureData = mPhotonTlas.pTlas->getGpuAddress();

    // Create TLAS
    FALCOR_GET_COM_INTERFACE(pContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
    pContext->resourceBarrier(mPhotonTlas.pInstanceDescs.get(), Resource::State::NonPixelShader);
    pList4->BuildRaytracingAccelerationStructure(&asDesc, 0, nullptr);
    pContext->uavBarrier(mPhotonTlas.pTlas.get());                   //barrier for the tlas so we can use it savely after creation

    //Create TLAS Shader Ressource View
    if (mPhotonTlas.pSrv == nullptr || rebuild) {
        mPhotonTlas.pSrv = ShaderResourceView::createViewForAccelerationStructure(mPhotonTlas.pTlas);
    }

}
void PhotonMapper::createBottomLevelAS(RenderContext* pContext, const std::vector<uint>& aabbCount, bool rebuild) {

    //Init the blas with a maximum size for scratch and result buffer
    if (mBlasData.empty() || rebuild) {
        mBlasData.resize(mUsePhotonMapper ? 1 : 2);
        uint64_t maxScratchSize = 0;
        //Prebuild
        for (size_t i = 0; i < mBlasData.size(); i++) {
            auto& blas = mBlasData[i];
            //Create geometry description
            D3D12_RAYTRACING_GEOMETRY_DESC& desc = blas.geomDescs;
            desc.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_PROCEDURAL_PRIMITIVE_AABBS;
            desc.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_NO_DUPLICATE_ANYHIT_INVOCATION;       //TODO: Check if opaque is needed
            desc.AABBs.AABBCount = i == 0 ? mCausticBuffers.maxSize : mGlobalBuffers.maxSize;                     //TODO: Put at max for the respective side (caustic or global)
            desc.AABBs.AABBs.StartAddress = i == 0 ? mCausticBuffers.aabb->getGpuAddress() : mGlobalBuffers.aabb->getGpuAddress();
            desc.AABBs.AABBs.StrideInBytes = sizeof(D3D12_RAYTRACING_AABB);

            //Create input for blas
            D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS& inputs = blas.buildInputs;
            inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
            inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
            inputs.NumDescs = 1;
            inputs.pGeometryDescs = &blas.geomDescs;
            inputs.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD;

            //get prebuild Info
            FALCOR_GET_COM_INTERFACE(gpDevice->getApiHandle(), ID3D12Device5, pDevice5);
            pDevice5->GetRaytracingAccelerationStructurePrebuildInfo(&blas.buildInputs, &blas.prebuildInfo);

            // Figure out the padded allocation sizes to have proper alignment.
            FALCOR_ASSERT(blas.prebuildInfo.ResultDataMaxSizeInBytes > 0);
            blas.blasByteSize = align_to((uint64_t)D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT, blas.prebuildInfo.ResultDataMaxSizeInBytes);

            uint64_t scratchByteSize = std::max(blas.prebuildInfo.ScratchDataSizeInBytes, blas.prebuildInfo.UpdateScratchDataSizeInBytes);
            blas.scratchByteSize = align_to((uint64_t)D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT, scratchByteSize);

            maxScratchSize = std::max(blas.scratchByteSize, maxScratchSize);
        }

        //Create the scratch and blas buffers
        mBlasScratch = Buffer::create(maxScratchSize, Buffer::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);
        mBlasScratch->setName("PhotonMapper::BlasScratch");

        mCausticBuffers.blas = Buffer::create(mBlasData[0].blasByteSize, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);
        mCausticBuffers.blas->setName("PhotonMapper::CausticBlasBuffer");

        if (!mUsePhotonMapper) {    //create a global buffer if they are not used as light
            mGlobalBuffers.blas = Buffer::create(mBlasData[1].blasByteSize, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);
            mGlobalBuffers.blas->setName("PhotonMapper::GlobalBlasBuffer");
        }
    }

    FALCOR_ASSERT(mBlasData.size() <= aabbCount.size()); //size of the blas data has to be equal or smaller than the aabbCounts 

    //Update size of the blas
    for (size_t i = 0; i < mBlasData.size(); i++) {
        mBlasData[i].geomDescs.AABBs.AABBCount = aabbCount[i];
    }

    FALCOR_PROFILE("buildPhotonBlas");
    if (!gpDevice->isFeatureSupported(Device::SupportedFeatures::Raytracing))
    {
        throw std::exception("Raytracing is not supported by the current device");
    }

    //aabb buffers need to be ready
    pContext->uavBarrier(mCausticBuffers.aabb.get());
    if(!mUsePhotonMapper)  pContext->uavBarrier(mGlobalBuffers.aabb.get());

    for (size_t i = 0; i < mBlasData.size(); i++) {
        auto& blas = mBlasData[i];

        //barriers for the scratch and blas buffer
        pContext->uavBarrier(mBlasScratch.get());
        pContext->uavBarrier(i == 0 ? mCausticBuffers.blas.get() : mGlobalBuffers.blas.get());

        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC asDesc = {};
        asDesc.Inputs = blas.buildInputs;
        asDesc.ScratchAccelerationStructureData = mBlasScratch->getGpuAddress();
        asDesc.DestAccelerationStructureData = i == 0 ? mCausticBuffers.blas->getGpuAddress(): mGlobalBuffers.blas->getGpuAddress();

        FALCOR_GET_COM_INTERFACE(pContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
        pList4->BuildRaytracingAccelerationStructure(&asDesc, 0, nullptr);

        //Barrier for the blas
        pContext->uavBarrier(i == 0 ? mCausticBuffers.blas.get() : mGlobalBuffers.blas.get());
    }
}

void PhotonMapper::prepareRandomSeedBuffer(const uint2 screenDimensions)
{
    FALCOR_ASSERT(screenDimensions.x > 0 && screenDimensions.y > 0);

    //fill a std vector with random seed from the seed_seq
    std::seed_seq seq{ time(0) };
    std::vector<uint32_t> cpuSeeds(screenDimensions.x * screenDimensions.y);
    seq.generate(cpuSeeds.begin(), cpuSeeds.end());

    //create the gpu buffer
    mRandNumSeedBuffer = Buffer::createStructured(sizeof(uint32_t), screenDimensions.x * screenDimensions.y, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, cpuSeeds.data());
    mRandNumSeedBuffer->setName("PhotonMapper::RandomSeedBuffer");

    FALCOR_ASSERT(mRandNumSeedBuffer);
}
