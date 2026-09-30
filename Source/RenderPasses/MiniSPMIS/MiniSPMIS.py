from falcor import *

def render_graph_MiniSPMIS():
    g = RenderGraph("MiniSPMIS")
    AccumulatePass = createPass("AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})
    g.addPass(AccumulatePass, "AccumulatePass")
    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    g.addPass(ToneMapper, "ToneMapper")
    ErrorMeasurePass = createPass("ErrorMeasurePass")
    g.addPass(ErrorMeasurePass, "ErrorMeasurePass")
    MiniSPMIS = createPass("MiniSPMIS")
    g.addPass(MiniSPMIS, "MiniSPMIS")
    VBufferRT = createPass("VBufferRT", {'samplePattern': 'Stratified', 'sampleCount': 16})
    g.addPass(VBufferRT, "VBufferRT")
    GBufferRT = createPass("GBufferRT", {'samplePattern': 'Halton', 'sampleCount': 32, 'useAlphaTest': True})
    g.addPass(GBufferRT, "GBufferRT")

    g.addEdge("VBufferRT.vbuffer", "MiniSPMIS.vbuffer")
    g.addEdge("VBufferRT.viewW", "MiniSPMIS.viewW")
    g.addEdge("VBufferRT.mvec", "MiniSPMIS.motionVectors")
    g.addEdge("GBufferRT.linearZ", "MiniSPMIS.linearZ")
    g.addEdge("MiniSPMIS.color", "AccumulatePass.input")

    g.addEdge("AccumulatePass.output", "ErrorMeasurePass.Source")

    g.addEdge("ErrorMeasurePass.Output", "ToneMapper.src")
    g.markOutput("ToneMapper.dst")
    return g

MiniSPMIS = render_graph_MiniSPMIS()
try: m.addGraph(MiniSPMIS)
except NameError: None

# Scene
m.scene.camera.animated = False
m.scene.camera.position = float3(21.238686, 3.988723, -51.456573)
m.scene.camera.target = float3(21.233591, 3.987791, -51.441437)
m.scene.camera.up = float3(-0.000297, 0.015973, 0.000883)
m.scene.cameraSpeed = 1.0
