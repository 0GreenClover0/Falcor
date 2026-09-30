# Graphs
from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_MiniSPMIS():
    g = RenderGraph('MiniSPMIS')
    g.create_pass('AccumulatePass', 'AccumulatePass', {'enabled': True, 'outputSize': 'Default', 'autoReset': True, 'precisionMode': 'Single', 'maxFrameCount': 0, 'overflowMode': 'Stop'})
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.create_pass('ErrorMeasurePass', 'ErrorMeasurePass', {'ReferenceImagePath': '', 'MeasurementsFilePath': '', 'IgnoreBackground': True, 'ComputeSquaredDifference': True, 'ComputeAverage': False, 'UseLoadedReference': False, 'ReportRunningError': True, 'RunningErrorSigma': 0.9950000047683716, 'SelectedOutputId': 'Source'})
    g.create_pass('MiniSPMIS', 'MiniSPMIS', {})
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Stratified', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('GBufferRT', 'GBufferRT', {'samplePattern': 'Halton', 'sampleCount': 32, 'useAlphaTest': True})
    g.add_edge('VBufferRT.vbuffer', 'MiniSPMIS.vbuffer')
    g.add_edge('VBufferRT.viewW', 'MiniSPMIS.viewW')
    g.add_edge("VBufferRT.mvec", "MiniSPMIS.motionVectors")
#    g.add_edge("GBufferRT.linearZ", "MiniSPMIS.depth")
    g.add_edge('MiniSPMIS.color', 'AccumulatePass.input')
    g.add_edge('AccumulatePass.output', 'ErrorMeasurePass.Source')
    g.add_edge('ErrorMeasurePass.Output', 'ToneMapper.src')
    g.mark_output('ToneMapper.dst')
    return g
m.addGraph(render_graph_MiniSPMIS())

# Scene
m.loadScene('D:/packman-repo/chk/falcor_media/7acdf8b0/test_scenes/Bistro_v5_2/BistroExterior.fbx')
m.scene.renderSettings = SceneRenderSettings(useEnvLight=True, useAnalyticLights=True, useEmissiveLights=True, useGridVolumes=True, diffuseAlbedoMultiplier=1)
m.scene.camera.animated = False
m.scene.camera.position = float3(21.238686, 3.988723, -51.456573)
m.scene.camera.target = float3(21.233591, 3.987791, -51.441437)
m.scene.camera.up = float3(-0.000297, 0.015973, 0.000883)
m.scene.cameraSpeed = 1.0
m.scene.addViewpoint(float3(21.238686, 3.988723, -51.456573), float3(21.233591, 3.987791, -51.441437), float3(-0.000297, 0.015973, 0.000883), 0)
m.scene.addViewpoint(float3(21.238686, 3.988723, -51.456573), float3(21.233591, 3.987791, -51.441437), float3(-0.000297, 0.015973, 0.000883), 0)
m.scene.addViewpoint(float3(21.238686, 3.988723, -51.456573), float3(21.233591, 3.987791, -51.441437), float3(-0.000297, 0.015973, 0.000883), 0)
m.scene.addViewpoint(float3(21.238686, 3.988723, -51.456573), float3(21.233591, 3.987791, -51.441437), float3(-0.000297, 0.015973, 0.000883), 0)
m.scene.addViewpoint(float3(21.238686, 3.988723, -51.456573), float3(21.233591, 3.987791, -51.441437), float3(-0.000297, 0.015973, 0.000883), 0)

# Window Configuration
m.resizeFrameBuffer(1920, 1080)
m.ui = True

# Clock Settings
m.clock.time = 0
m.clock.framerate = 0
# If framerate is not zero, you can use the frame property to set the start frame
# m.clock.frame = 0

# Frame Capture
m.frameCapture.outputDir = '.'
m.frameCapture.baseFilename = 'Mogwai'

