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

    enum class TextureFormat {
        _8Bit = 0u,
        _16Bit = 1u,
        _32Bit = 2u
    };

private:
    PhotonMapper();

    /** Prepares Program Variables and binds the sample generator
    */
    void prepareVars();

    /** Prepares all buffers neede for the generate photon pass
    */
    bool preparePhotonBuffers();

    /** Prepares the info textures. Is called inside of preparePhotonBuffers. Can be called seperate for format changes
    */
    void preparePhotonInfoTexture();

    /** Creates the photon counter for caustic and global photon buffers
    */
    void preparePhotonCounters();

    /** Resets buffer and runtime vars. Used for scene change or number of photons change
    */
    void resetPhotonMapper();

    /** Applies the changes to the number of photons
    */
    void changeNumPhotons();

    /** Copies the photon counter to a cpu buffer
    */
    void copyPhotonCounter(RenderContext* pRenderContext);

    /** Creates the Generate Photon pass, where the photons are shot through the scene and saved in an AABB and information buffer
    */
    void generatePhotons(RenderContext* pRenderContext, const RenderData& renderData);

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

    /** Builds the Bottom Level Acceleration structure
    */
    void buildBottomLevelAS(RenderContext* pContext);

    /**Builds the Top Level Acceleration structure
    */
    void buildTopLevelAS(RenderContext* pContext);

    /** Prepares the buffer that holds the seeds for the SampleGenerator
    */
    void prepareRandomSeedBuffer(const uint2 screenDimensions);

    /** Prepares a light sample texture for the photon generate pass
    */
    void createLightSampleTexture(RenderContext* pRenderContext);

    /** Gets the active emissive triangles from the light collection.
    *  This is analogous to the function from LightCollection. It is here to prevent changes to the core of Falcor.
    *  As this is done once it has no impact on performance and only a minimal impact on CPU-Memory
    */
    void getActiveEmissiveTriangles(RenderContext* pRenderContext);

    /** Creates the Photon Collection Program
    */
    void createCollectionProgram();

    /** Inits the Hash buffer for the culling
    */
    void initPhotonCulling(RenderContext* pRenderContext, uint2 windowDim);

    /** resets the culling buffer to save gpu memory
    */
    void resetCullingVars();

    /**The culling compute pass which inserts a 1 in the hash for camera cells outside of the camera frustum
    */
    void photonCullingPass(RenderContext* pRenderContext, const RenderData& renderData);

    // Internal state
    Scene::SharedPtr            mpScene;                    ///< Current scene.
    SampleGenerator::SharedPtr  mpSampleGenerator;          ///< GPU sample generator.

    //Constants
    const float                 kMinPhotonRadius = 0.0001f;                 ///< At radius 0.0001 Photons are still visible
    const float                 kCollectTMin = 0.000001f;                   ///<non configurable constant for collection for now
    const float                 kCollectTMax = 0.000002f;                   ///< non configurable constant for collection for now
    const uint                  kInfoTexHeight = 512;                       ///< Height of the info tex as it is too big for 1D tex

    //***************************************************************************
    // Configuration
    //***************************************************************************

    bool                        mUseStatisticProgressivePM = true;     ///< Activate Statistically Progressive Photon Mapping(SPPM)
    float                       mSPPMAlphaGlobal = 0.7f;                 ///< Global Alpha for SPPM
    float                       mSPPMAlphaCaustic = 0.7f;                ///< Caustic Alpha for SPPM

    float                       mCausticRadiusStart = 0.01f;            ///< Start value for the caustic Radius
    float                       mGlobalRadiusStart = 0.05f;             ///< Start value for the caustic Radius
    float                       mCausticRadius = 1.f;                 ///< Current Radius for caustic Photons
    float                       mGlobalRadius = 1.f;                  ///< Current Radius for global Photons

    float                       mSpecRoughCutoff = 0.5f;               ///< If rougness is over this value interpret the material as diffuse

    bool                        mResetIterations = false;               ///<Resets the iterations counter once
    bool                        mAlwaysResetIterations = false;         ///<Resets the iteration counter every frame

    bool                        mNumPhotonsChanged = false;             ///<If true buffers needs to be restarted and Number of photons needs to be changed
    bool                        mFitBuffersToPhotonShot = false;        ///<Changes the buffer size to be around the number of photons shot

    bool                        mUseAlphaTest = true;                   ///<Uses alpha test (Generate)
    bool                        mAdjustShadingNormals = true;           ///<Adjusts the shading normals (Generate)

    // Generate only
    uint                        mMaxBounces = 10;                        ///< Depth of recursion (0 = none).
    float                       mRejectionProbability = 0.3f;                ///< Probabilty that a Global photon is saved

    uint                        mNumPhotons = 2000000;                   ///< Number of Photons shot
    uint                        mNumPhotonsUI = mNumPhotons;            ///< For UI. It is decopled from the runtime var because changes have to be confirmed
    uint                        mGlobalBufferSizeUI = mNumPhotons / 2;    ///< Size of the Global Photon Buffer
    uint                        mCausticBufferSizeUI = mNumPhotons / 4;   ///< Size of the Caustic Photon Buffer

    float                       mIntensityScalar = 1.0f;                ///<Scales the intensity of emissive light sources

    bool                        mAccelerationStructureFastBuild = true;    ///< Build mode for acceleration structure
    bool                        mAccelerationStructureFastBuildUI = mAccelerationStructureFastBuild;

    // Collect only
    bool                        mDisableGlobalCollection = false;       ///<Disabled the collection of global photons
    bool                        mDisableCausticCollection = false;       ///<Disabled the collection of caustic photons

    //Photon Culling
    bool                        mEnablePhotonCulling = true;            //<Photon Culling with AS
    uint                        mCullingHashBufferSizeBytes = 18;

    //Stochasic Collect
    
    bool                        mEnableStochasticCollect = true;       //< Stochastic collect
    bool                        mEnableStochasticCollectUI = mEnableStochasticCollect;
    uint                        mMaxNumberPhotonsSC = 3;                 //< Max number of photons that can get collected. (4 * x) - 1 for best fit
    uint                        mMaxNumberPhotonsSCUI = mMaxNumberPhotonsSC;

    //*******************************************************
    // Runtime data
    //*******************************************************
    
    uint                        mFrameCount = 0;            ///< Frame count since last Reset
    std::vector<uint>           mPhotonCount = { 0,0 };
    bool                        mOptionsChanged = false;
    bool                        mResetConstantBuffers = true;
    bool                        mResizePhotonBuffers = true;    ///< If true resize the Photon Buffers
    bool                        mPhotonInfoFormatChanged = false;         
    bool                        mRebuildAS = false;
    uint                        mInfoTexFormat = 1;
    bool                        mPhotonBuffersReady = false;

    uint                        mCullingYExtent = 512;

    //Light
    std::vector<uint> mActiveEmissiveTriangles;
    Texture::SharedPtr mLightSampleTex;
    Buffer::SharedPtr mPhotonsPerTriangle;
    const uint mMaxDispatchY = 512;
    uint mPGDispatchX = 0;
    uint mAnalyticEndIndex = 0;
    uint mNumLights = 0;
    float mAnalyticInvPdf = 0.0f;
    float mEmissiveInvPdf = 0.0f;

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

    struct PhotonBuffers {
        uint maxSize = 0;
        Texture::SharedPtr infoFlux;
        Texture::SharedPtr infoDir;
        Buffer::SharedPtr aabb;
        Buffer::SharedPtr blas;
    };

    struct {
        Buffer::SharedPtr counter;
        Buffer::SharedPtr reset;
        Buffer::SharedPtr cpuCopy;
    }mPhotonCounterBuffer;

    RayTraceProgramHelper mTracerGenerate;          ///<Description for the Generate Photon pass 
    RayTraceProgramHelper mTracerCollect;           ///<Collect pass collects the photons that where shot
    ComputePass::SharedPtr mPhotonCullingPass;      ///< Pass to create AABB's used for photon culling

    //
    //Photon Culling vars
    //
    Texture::SharedPtr               mCullingBuffer;

    //
    //Photon Buffers
    //
    PhotonBuffers mCausticBuffers;              ///< Buffers for the caustic photons
    PhotonBuffers mGlobalBuffers;               ///< Buffers for the global photons

    Texture::SharedPtr mRandNumSeedBuffer;       ///< Buffer for the random seeds

    size_t                    mBlasScratchMaxSize = 0;
    size_t                    mTlasScratchMaxSize = 0;
    std::vector<BlasData> mBlasData;
    Buffer::SharedPtr mBlasScratch;
    std::vector<D3D12_RAYTRACING_INSTANCE_DESC> mPhotonInstanceDesc;
    D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO mTlasPrebuildInfo;
    Buffer::SharedPtr mTlasScratch;
    TlasData mPhotonTlas;
};
