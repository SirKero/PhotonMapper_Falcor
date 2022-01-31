# Graphs
from falcor import *

def render_graph_PhotonMapper():
    g = RenderGraph('PhotonMapper')
    loadRenderPassLibrary('AccumulatePass.dll')
    loadRenderPassLibrary('PhotonMapper.dll')
    loadRenderPassLibrary('BSDFViewer.dll')
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
    PhotonMapper = createPass('PhotonMapper')
    g.addPass(PhotonMapper, 'PhotonMapper')
    g.addEdge('PTGBuffer.posW', 'PhotonMapper.WPos')
    g.addEdge('PTGBuffer.normW', 'PhotonMapper.WNormal')
    g.addEdge('PTGBuffer.tangentW', 'PhotonMapper.WTangent')
    g.addEdge('PTGBuffer.texC', 'PhotonMapper.TexC')
    g.addEdge('PTGBuffer.diffuseOpacity', 'PhotonMapper.DiffuseOpacity')
    g.addEdge('PTGBuffer.specRough', 'PhotonMapper.SpecularRoughness')
    g.addEdge('PTGBuffer.emissive', 'PhotonMapper.Emissive')
    g.addEdge('PTGBuffer.matlExtra', 'PhotonMapper.MaterialExtra')
    g.addEdge('PTGBuffer.viewW', 'PhotonMapper.WView')
    g.addEdge('PTGBuffer.faceNormal', 'PhotonMapper.WFaceNormal')
    g.markOutput('PhotonMapper.PhotonImage')
    return g
m.addGraph(render_graph_PhotonMapper())
from falcor import *

def render_graph_PTGBuffer():
    g = RenderGraph('PTGBuffer')
    loadRenderPassLibrary('AccumulatePass.dll')
    loadRenderPassLibrary('PhotonMapper.dll')
    loadRenderPassLibrary('BSDFViewer.dll')
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

# Scene
m.loadScene('E:/VSProjects/Models/FalcorTestScenes/CornellBoxGlass.pyscene')
m.scene.renderSettings = SceneRenderSettings(useEnvLight=True, useAnalyticLights=True, useEmissiveLights=True, useVolumes=True)
m.scene.camera.position = float3(0.000000,4.500000,10.500000)
m.scene.camera.target = float3(0.000000,4.200000,9.000000)
m.scene.camera.up = float3(0.000000,1.000000,0.000000)
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

