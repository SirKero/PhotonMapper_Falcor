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
#pragma once
#include "Falcor.h"
#include "Utils/Sampling/SampleGenerator.h"

using namespace Falcor;

class PhotonMapper : public RenderPass
{
public:
    using SharedPtr = std::shared_ptr<PhotonMapper>;

    static const Info kInfo;

    /** Create a new render pass object.
        \param[in] pRenderContext The render context.
        \param[in] dict Dictionary of serialized parameters.
        \return A new object, or an exception is thrown if creation failed.
    */
    static SharedPtr create(RenderContext* pRenderContext = nullptr, const Dictionary& dict = {});

    virtual Dictionary getScriptingDictionary() override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pContext, const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    PhotonMapper();

    /** Prepares Program Variables and binds the sample generator
    */
    void prepareVars();

    /** Prepares all buffers neede for the generate photon pass
    */
    bool preparePhotonBuffers();

    /** Creates the Generate Photon pass, where the photons are shot through the scene and saved in an AABB and information buffer
    */
    void generatePhotons(RenderContext* pRenderContext, const RenderData& renderData);

    /** Sync Pass which syncs the resources which were used by the generate Photon Pass and are nedded by the Trace Photon Pass.
    * It also will create the Acceleration Structure which is needed for the next pass
    * Returns false if Acceleration Structure could not be created (photon Counter is zero for example)
    */
    bool syncPasses(RenderContext* pRenderContext);

    /** Pass that collect the photons. It will shoot a infinit small ray at the current camera position and collect all photons.
    * The needed position etc. has to be provided by a gBuffer
    */
    void collectPhotons(RenderContext* pRenderContext, const RenderData& renderData);

    /** Creates the AS. Calls the createTopLevelAS(..) and createBottomLevelAS(..) functions
    */
    void createAccelerationStructure(RenderContext* pContext, const std::vector<uint>& aabbCount);

    /** Creates the TLAS for the Photon AABBs
    */
    void createTopLevelAS(RenderContext* pContext);

    /** Creates the BLAS for the Photon AABBs
   */
    void createBottomLevelAS(RenderContext* pContext, const std::vector<uint>& aabbCount);

    /** Prepares the buffer that holds the seeds for the SampleGenerator
    */
    void prepareRandomSeedBuffer(const uint2 screenDimensions);

    // Internal state
    Scene::SharedPtr            mpScene;                    ///< Current scene.
    SampleGenerator::SharedPtr  mpSampleGenerator;          ///< GPU sample generator.

    //Constants
    const float                 kMinPhotonRadius = 0.005f;                ///< At radius 0.005 Photons are still visible

    // Configuration
    uint                        mMaxBounces = 5;                        ///< Depth of recursion (0 = none).
    float                       mCausticRadiusStart = 0.04f;            ///< Start value for the caustic Radius
    float                       mGlobalRadiusStart = 0.1f;             ///< Start value for the caustic Radius
    float                       mCausticRadius = 1.f;                 ///< Current Radius for caustic Photons
    float                       mGlobalRadius = 1.f;                  ///< Current Radius for global Photons
    float                       mRussianRoulette = 0.3f;                ///< Probabilty that a Global photon is saved
    bool                        mUseStatisticProgressivePM = true;     ///< Activate Statistically Progressive Photon Mapping(SPPM)
    float                       mSPPMAlphaGlobal = 0.7f;                 ///< Global Alpha for SPPM
    float                       mSPPMAlphaCaustic = 0.7f;                ///< Caustic Alpha for SPPM

    uint                        mNumPhotons = 500000;                   ///< Number of Photons shot
    bool                        mUsePhotonMapper = false;               ///< Activates ReStir for global photons
    float3                      mDirLightWorldPos = float3(0.f, 10.f, 0.f); ///< Testing purposes only
    float                       mIntensityScalar = 1.0f;                ///<Scales the intensity of emissive light sources
    bool                        mResetIterations = false;               ///<Resets the iterations counter once
    bool                        mAlwaysResetIterations = false;         ///<Resets the iteration counter every frame
    bool                        mDisableGlobalCollection = false;       ///<Disabled the collection of global photons
    bool                        mDisableCausticCollection = false;       ///<Disabled the collection of caustic photons


    // Runtime data
    uint                        mFrameCount = 0;            ///< Frame count since last Reset
    std::vector<uint>           mPhotonCount = { 0,0 };
    bool                        mOptionsChanged = false;

    // Ray tracing program.
    struct RayTraceProgramHelper
    {
        RtProgram::SharedPtr pProgram;
        RtBindingTable::SharedPtr pBindingTable;
        RtProgramVars::SharedPtr pVars;

        static const RayTraceProgramHelper create()
        {
            RayTraceProgramHelper r;
            r.pProgram = nullptr;
            r.pBindingTable = nullptr;
            r.pVars = nullptr;
            return r;
        }
    };

    RayTraceProgramHelper mTracerGenerate;          ///<Description for the Generate Photon pass 
    RayTraceProgramHelper mTracerCollect;           ///<Collect pass collects the photons that where shot

    //
    //Photon Buffers
    //

    //Struct for the buffers that are needed for global and caustic photons
    bool mPhotonBuffersReady = false;

    bool mTestInit = false;

    struct {
        Buffer::SharedPtr counter;
        Buffer::SharedPtr reset;
        Buffer::SharedPtr cpuCopy;
    }mPhotonCounterBuffer;

    struct PhotonBuffers {
        uint maxSize = 0;
        Buffer::SharedPtr info;
        Buffer::SharedPtr aabb;
        Buffer::SharedPtr blas;
    };

    struct PhotonInfo {
        float3 pos;
        float radius;
        float3 flux;
        float pad2;
    };

    PhotonBuffers mCausticBuffers;              ///< Buffers for the caustic photons
    PhotonBuffers mGlobalBuffers;               ///< Buffers for the global photons

    Buffer::SharedPtr mRandNumSeedBuffer;       ///< Buffer for the random seeds

    struct BlasData
    {
        D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO prebuildInfo;
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS buildInputs;
        D3D12_RAYTRACING_GEOMETRY_DESC geomDescs;

        uint64_t blasByteSize = 0;                    ///< Maximum result data size for the BLAS build, including padding.
        uint64_t scratchByteSize = 0;                   ///< Maximum scratch data size for the BLAS build, including padding.
    };

    struct TlasData
    {
        Buffer::SharedPtr pTlas;
        ShaderResourceView::SharedPtr pSrv;             ///< Shader Resource View for binding the TLAS.
        Buffer::SharedPtr pInstanceDescs;               ///< Buffer holding instance descs for the TLAS.
    };

    std::vector<BlasData> mBlasData;
    Buffer::SharedPtr mBlasScratch;
    std::vector<D3D12_RAYTRACING_INSTANCE_DESC> mPhotonInstanceDesc;
    D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO mTlasPrebuildInfo;
    Buffer::SharedPtr mTlasScratch;
    TlasData mPhotonTlas;
};
