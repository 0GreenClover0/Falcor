#include "Utils/Math/MathConstants.slangh"
#include "Scene/SceneDefines.slangh"
import Scene.Shading;
import Scene.RaytracingInline;
import Utils.Geometry.GeometryHelpers;
import Utils.Math.MathHelpers;
import Utils.Sampling.UniformSampleGenerator;
import Reservoir;

#define is_valid(name) (is_valid_##name != 0)

[shader("compute")]
[numthreads(8, 4, 1)]
void main(uint2 pixel : SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDim))
        return;

    Reservoir reservoir = {};
    reservoir.radiance = 0;
    reservoir.UCW = 1;
    reservoir.sample = uint3(pixel, gFrameSeed);
    reservoir.confidence = 1;

    float3 normal = 0;
    float roughness = 0;

    float3 rayDir;
    if (is_valid(gViewW))
    {
        // If we have the view vector bound as a buffer, just fetch it. No need to compute anything.
        rayDir = -gViewW[pixel].xyz;
    }
    else
    {
        // Compute the view vector. This must exactly match what the G-buffer pass is doing (jitter etc.).
        // Note that we do not take depth-of-field into account as it would require exactly matching the
        // sample generator between the passes, which is error prone. The host side will issue a warning instead.
        rayDir = gScene.camera.computeRayPinhole(pixel, gFrameDim).dir;
    }

    float3 color = 0;

    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        ShadingData sd = loadShadingData(hit, rayDir);
        let mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0));
        let props = mi.getProperties(sd);
        roughness = props.roughness;
        normal = sd.frame.N;

        reservoir.radiance = evalSample(reservoir.sample, sd, mi);

        color = props.emission + reservoir.radiance * reservoir.UCW;
    }
    else
    {
        normal = rayDir;
        roughness = 0;

        if (kSceneHasEnvBackground)
        {
            color = gScene.envMap.eval(rayDir);
        }
    }

    gOutputColor[pixel] = float4(color, 1);
    gOutputNormalRoughness[pixel] = float4(ndir_to_oct_unorm(normal), roughness, 1);
    gOutputReservoirs[flattenIndex(pixel, gFrameDim.x)] = reservoir;
    gOutputReservoirConfidences[pixel] = reservoir.confidence;
}
