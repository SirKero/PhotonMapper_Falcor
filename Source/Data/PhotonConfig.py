# Graphs
from falcor import *

def render_graph_PTGBuffer():
    g = RenderGraph('PTGBuffer')
    loadRenderPassLibrary('AccumulatePass.dll')
    loadRenderPassLibrary('BSDFViewer.dll')
    loadRenderPassLibrary('PhotonReStir.dll')
    loadRenderPassLibrary('ErrorMeasurePass.dll')
    loadRenderPassLibrary('Antialiasing.dll')
    loadRenderPassLibrary('BlitPass.dll')
    loadRenderPassLibrary('CSM.dll')
    loadRenderPassLibrary('DebugPasses.dll')
    loadRenderPassLibrary('DepthPass.dll')
    loadRenderPassLibrary('ExampleBlitPass.dll')
    loadRenderPassLibrary('FLIPPass.dll')
    loadRenderPassLibrary('ForwardLightingPass.dll')
    loadRenderPassLibrary('GBuffer.dll')
    loadRenderPassLibrary('OptixDenoiser.dll')
    loadRenderPassLibrary('ImageLoader.dll')
    loadRenderPassLibrary('MegakernelPathTracer.dll')
    loadRenderPassLibrary('WireframePass.dll')
    loadRenderPassLibrary('MinimalPathTracer.dll')
    loadRenderPassLibrary('PassLibraryTemplate.dll')
    loadRenderPassLibrary('PixelInspectorPass.dll')
    loadRenderPassLibrary('PTGBuffer.dll')
    loadRenderPassLibrary('SceneDebugger.dll')
    loadRenderPassLibrary('SimplePostFX.dll')
    loadRenderPassLibrary('SkyBox.dll')
    loadRenderPassLibrary('SSAO.dll')
    loadRenderPassLibrary('SVGFPass.dll')
    loadRenderPassLibrary('TemporalDelayPass.dll')
    loadRenderPassLibrary('TestPasses.dll')
    loadRenderPassLibrary('ToneMapper.dll')
    loadRenderPassLibrary('Utils.dll')
    loadRenderPassLibrary('WhittedRayTracer.dll')
    PTGBuffer = createPass('PTGBuffer')
    g.addPass(PTGBuffer, 'PTGBuffer')
    AccumulatePass = createPass('AccumulatePass', {'enabled': True, 'autoReset': True, 'precisionMode': AccumulatePrecision.Single, 'subFrameCount': 0, 'maxAccumulatedFrames': 0})
    g.addPass(AccumulatePass, 'AccumulatePass')
    g.addEdge('PTGBuffer.Output', 'AccumulatePass.input')
    g.markOutput('AccumulatePass.output')
    return g
m.addGraph(render_graph_PTGBuffer())
from falcor import *

def render_graph_PhotonMapper():
    g = RenderGraph('PhotonMapper')
    loadRenderPassLibrary('AccumulatePass.dll')
    loadRenderPassLibrary('BSDFViewer.dll')
    loadRenderPassLibrary('PhotonReStir.dll')
    loadRenderPassLibrary('ErrorMeasurePass.dll')
    loadRenderPassLibrary('Antialiasing.dll')
    loadRenderPassLibrary('BlitPass.dll')
    loadRenderPassLibrary('CSM.dll')
    loadRenderPassLibrary('DebugPasses.dll')
    loadRenderPassLibrary('DepthPass.dll')
    loadRenderPassLibrary('ExampleBlitPass.dll')
    loadRenderPassLibrary('FLIPPass.dll')
    loadRenderPassLibrary('ForwardLightingPass.dll')
    loadRenderPassLibrary('GBuffer.dll')
    loadRenderPassLibrary('OptixDenoiser.dll')
    loadRenderPassLibrary('ImageLoader.dll')
    loadRenderPassLibrary('MegakernelPathTracer.dll')
    loadRenderPassLibrary('WireframePass.dll')
    loadRenderPassLibrary('MinimalPathTracer.dll')
    loadRenderPassLibrary('PassLibraryTemplate.dll')
    loadRenderPassLibrary('PixelInspectorPass.dll')
    loadRenderPassLibrary('PTGBuffer.dll')
    loadRenderPassLibrary('SceneDebugger.dll')
    loadRenderPassLibrary('SimplePostFX.dll')
    loadRenderPassLibrary('SkyBox.dll')
    loadRenderPassLibrary('SSAO.dll')
    loadRenderPassLibrary('SVGFPass.dll')
    loadRenderPassLibrary('TemporalDelayPass.dll')
    loadRenderPassLibrary('TestPasses.dll')
    loadRenderPassLibrary('ToneMapper.dll')
    loadRenderPassLibrary('Utils.dll')
    loadRenderPassLibrary('WhittedRayTracer.dll')
    PTGBuffer = createPass('PTGBuffer')
    g.addPass(PTGBuffer, 'PTGBuffer')
    PhotonReStir = createPass('PhotonReStir')
    g.addPass(PhotonReStir, 'PhotonReStir')
    g.addEdge('PTGBuffer.matlExtra', 'PhotonReStir.MaterialExtra')
    g.addEdge('PTGBuffer.posW', 'PhotonReStir.WPos')
    g.addEdge('PTGBuffer.normW', 'PhotonReStir.WNormal')
    g.addEdge('PTGBuffer.tangentW', 'PhotonReStir.WTangent')
    g.addEdge('PTGBuffer.texC', 'PhotonReStir.TexC')
    g.addEdge('PTGBuffer.diffuseOpacity', 'PhotonReStir.DiffuseOpacity')
    g.addEdge('PTGBuffer.specRough', 'PhotonReStir.SpecularRoughness')
    g.addEdge('PTGBuffer.emissive', 'PhotonReStir.Emissive')
    g.addEdge('PTGBuffer.viewW', 'PhotonReStir.WView')
    g.addEdge('PTGBuffer.faceNormal', 'PhotonReStir.WFaceNormal')
    g.markOutput('PhotonReStir.PhotonImage')
    return g
m.addGraph(render_graph_PhotonMapper())

# Scene
m.loadScene('E:/VSProjects/Models/FalcorTestScenes/CornellBoxGlass.pyscene')
m.scene.renderSettings = SceneRenderSettings(useEnvLight=True, useAnalyticLights=True, useEmissiveLights=True, useVolumes=True)
m.scene.camera.position = float3(0.000000,4.500000,10.500000)
m.scene.camera.target = float3(0.008836,4.310907,9.518081)
m.scene.camera.up = float3(0.000008,1.000000,-0.000909)
m.scene.cameraSpeed = 1.0

# Window Configuration
m.resizeSwapChain(1920, 1080)
m.ui = True

# Clock Settings
m.clock.time = 0
m.clock.framerate = 0
# If framerate is not zero, you can use the frame property to set the start frame
# m.clock.frame = 0

# Frame Capture
m.frameCapture.outputDir = '.'
m.frameCapture.baseFilename = 'Mogwai'

