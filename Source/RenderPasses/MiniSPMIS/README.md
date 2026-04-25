# Stochastic Pairwise MIS (SPMIS)

This is a minimal example of Stochastic Pairwise MIS applied to direct lighting. For simplicity, direct lighting uses basic uniform light sampling with a random replay shift map. This is essentially equivalent to a reconnection shift as long as the scene doesn't change, since the same random numbers will generate the same point on a light.

`SPMIS.cs.slang` implements most of the method on the GPU. On the CPU, the `MiniSPMIS::spmis()` method creates necessary resources and dispatches shaders in `SPMIS.cs.slang`.

## Usage with existing renderers
Most of the implementation in `SPMIS.cs.slang` and `MiniSPMIS::spmis()` does not depend on the specific path sampling technique (DI, GI, etc.) and should be interchangeable between renderers.
However, to integrate `SPMIS.cs.slang` in an existing ReSTIR renderer, some code modification is required:
- Replace the `Reservoir` struct in `Reservoir.slang` with your renderer's reservoir struct. Note that the following fields are required:
```
float UCW
float confidence
float phat()
```
- Update `spatialShift()`, to properly shift a reservoir to another pixel and computes the Jacobian.
- Provide the following global variables (from `Reservoir.slang`):
```
RWStructuredBuffer<Reservoir> gOutputReservoirs; // per-pixel reservoirs
RWTexture2D<float>  gOutputReservoirConfidences; // per-pixel confidence values
uniform uint2 gFrameDim;
uniform uint  gFrameSeed;
```
