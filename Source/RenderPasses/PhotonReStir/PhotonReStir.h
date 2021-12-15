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
#include "FalcorExperimental.h"
#include "Utils/Sampling/SampleGenerator.h"

using namespace Falcor;

class PhotonReStir : public RenderPass
{
public:
    using SharedPtr = std::shared_ptr<PhotonReStir>;

    /** Create a new render pass object.
        \param[in] pRenderContext The render context.
        \param[in] dict Dictionary of serialized parameters.
        \return A new object, or an exception is thrown if creation failed.
    */
    static SharedPtr create(RenderContext* pRenderContext = nullptr, const Dictionary& dict = {});

    virtual std::string getDesc() override;
    virtual Dictionary getScriptingDictionary() override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pContext, const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    PhotonReStir();
    void prepareVars();
    bool preparePhotonBuffers();
    void generatePhotons(RenderContext* pRenderContext, const RenderData& renderData);

    // Internal state
    Scene::SharedPtr            mpScene;                    ///< Current scene.
    SampleGenerator::SharedPtr  mpSampleGenerator;          ///< GPU sample generator.

    // Configuration
    uint                        mMaxBounces = 3;            ///< Max number of indirect bounces (0 = none).
    uint                        mNumPhotons = 500000;       ///< Number of Photons shot
    bool                        mUsePhotonReStir = false;   ///< Activates ReStir for global photons
    float3                      mDirLightWorldPos = float3(0.f, 10.f, 0.f); ///< Testing purposes only

    // Runtime data
    uint                        mFrameCount = 0;            ///< Frame count since scene was loaded.
    bool                        mOptionsChanged = false;

    // Ray tracing program.
    struct RayTraceProgramHelper
    {
        RtProgram::SharedPtr pProgram;
        RtBindingTable::SharedPtr pBindingTable;
        RtProgramVars::SharedPtr pVars;
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
    }mPhotonCounterBuffer;

    struct PhotonBuffers {
        uint maxSize = 0;
        Buffer::SharedPtr info;
        Buffer::SharedPtr aabb;
    };

    struct PhotonInfo {
        float3 pos;
        float radius;
        float3 flux;
        float pad2;
    };

    PhotonBuffers mCausticBuffers;              ///< Buffers for the caustic photons
    PhotonBuffers mGlobalBuffers;               ///< Buffers for the global photons
};
