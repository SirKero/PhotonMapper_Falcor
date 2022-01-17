# Graphs
from falcor import *

def render_graph_DefaultRenderGraph():
    g = RenderGraph('DefaultRenderGraph')
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
    GBufferRT = createPass('GBufferRT', {'samplePattern': SamplePattern.Center, 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': CullMode.CullBack, 'texLOD': TexLODMode.Mip0, 'useTraceRayInline': False})
    g.addPass(GBufferRT, 'GBufferRT')
    PhotonReStir = createPass('PhotonReStir')
    g.addPass(PhotonReStir, 'PhotonReStir')
    g.addEdge('GBufferRT.posW', 'PhotonReStir.WPos')
    g.addEdge('GBufferRT.normW', 'PhotonReStir.WNormal')
    g.addEdge('GBufferRT.texC', 'PhotonReStir.TexC')
    g.addEdge('GBufferRT.tangentW', 'PhotonReStir.WTangent')
    g.addEdge('GBufferRT.diffuseOpacity', 'PhotonReStir.DiffuseOpacity')
    g.addEdge('GBufferRT.specRough', 'PhotonReStir.SpecularRoughness')
    g.addEdge('GBufferRT.emissive', 'PhotonReStir.Emissive')
    g.addEdge('GBufferRT.matlExtra', 'PhotonReStir.MaterialExtra')
    g.addEdge('GBufferRT.viewW', 'PhotonReStir.WView')
    g.addEdge('GBufferRT.faceNormalW', 'PhotonReStir.WFaceNormal')
    g.markOutput('PhotonReStir.PhotonImage')
    return g
m.addGraph(render_graph_DefaultRenderGraph())

# Scene
m.loadScene('Arcade/Arcade.pyscene')
m.scene.renderSettings = SceneRenderSettings(useEnvLight=True, useAnalyticLights=True, useEmissiveLights=True, useVolumes=True)
m.scene.camera.position = float3(-3.192799,2.636635,3.310391)
m.scene.camera.target = float3(-2.570774,2.199951,2.660473)
m.scene.camera.up = float3(-0.001150,0.999999,0.001203)
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
