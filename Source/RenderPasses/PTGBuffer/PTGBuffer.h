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

class PTGBuffer : public RenderPass
{
public:
    //Sample patterns for camera jitter
    enum class SamplePattern : uint32_t
    {
        Center,
        DirectX,
        Halton,
        Stratified,
    };

    using SharedPtr = std::shared_ptr<PTGBuffer>;

    static const Info kInfo;

    /** Create a new render pass object.
        \param[in] pRenderContext The render context.
        \param[in] dict Dictionary of serialized parameters.
        \return A new object, or an exception is thrown if creation failed.
    */
    static SharedPtr create(RenderContext* pRenderContext = nullptr, const Dictionary& dict = {});

    virtual Dictionary getScriptingDictionary() override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    PTGBuffer();

    /** Prepares Program Variables and binds the sample generator
    */
    void prepareVars();

    /** Updates the camera jitter
    * Is called when frame dimensions or the sample generator changed
    */
    void setCameraJitter(const uint2 frameDim);

    /** Updates the sample pattern if it was changed
    */
    void updateSamplePattern();

    // Internal state
    Scene::SharedPtr            mpScene;                            ///< Current scene.
    SampleGenerator::SharedPtr  mpSampleGenerator;                  ///< GPU sample generator.
    CPUSampleGenerator::SharedPtr   mpCameraJitterSampleGenerator;  ///< CPU Sample generator for camera jitter.

    // Configuration
    uint                        mRecursionDepth = 5;                            ///< Depth of recursion (0 = none).
    SamplePattern               mSamplePattern = SamplePattern::DirectX;         ///< Which camera jitter sample pattern to use.
    uint32_t                    mSampleCount = 8;                              ///< Sample count for camera jitter.

     // Runtime data
    uint                        mFrameCount = 0;            ///< Frame count since last Reset
    bool                        mOptionsChanged = false;
    bool                        mJitterGenChanged = false;
    uint2                       mFrameDim = { 0,0 };

    //Ray Tracing Program
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

    RayTraceProgramHelper mTracer;
};
