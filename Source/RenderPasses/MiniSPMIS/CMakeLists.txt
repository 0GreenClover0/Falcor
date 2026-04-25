add_plugin(MiniSPMIS)

target_sources(MiniSPMIS PRIVATE
    MiniSPMIS.cpp
    MiniSPMIS.h
    HashMap.slang
    Reservoir.slang
    InitialSampling.cs.slang
    SPMIS.cs.slang
)

target_copy_shaders(MiniSPMIS RenderPasses/MiniSPMIS)

target_source_group(MiniSPMIS "RenderPasses")
