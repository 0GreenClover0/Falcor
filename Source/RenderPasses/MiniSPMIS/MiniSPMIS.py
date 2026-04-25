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

    g.addEdge("VBufferRT.vbuffer", "MiniSPMIS.vbuffer")
    g.addEdge("VBufferRT.viewW", "MiniSPMIS.viewW")
    g.addEdge("MiniSPMIS.color", "AccumulatePass.input")

    g.addEdge("AccumulatePass.output", "ErrorMeasurePass.Source")

    g.addEdge("ErrorMeasurePass.Output", "ToneMapper.src")
    g.markOutput("ToneMapper.dst")
    return g

MiniSPMIS = render_graph_MiniSPMIS()
try: m.addGraph(MiniSPMIS)
except NameError: None
