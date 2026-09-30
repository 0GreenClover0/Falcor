#include "Utils/Math/MathConstants.slangh"
#include "Scene/SceneDefines.slangh"
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.UniformSampleGenerator;
import Rendering.Lights.EnvMapSampler;
import Scene.Scene;
import Scene.RaytracingInline;

static const bool kSceneHasEmissiveLights = SCENE_HAS_EMISSIVE_LIGHTS;
static const bool kSceneHasEnvLight       = SCENE_HAS_ENV_LIGHT;
static const bool kSceneHasEnvBackground  = SCENE_HAS_ENV_BACKGROUND;
uniform EnvMapSampler gEnvSampler;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional
RWTexture2D<float4> gOutputColor;
RWTexture2D<float4> gOutputNormalRoughness;

RWStructuredBuffer<Reservoir> gOutputReservoirs;
RWTexture2D<float>  gOutputReservoirConfidences;
uniform uint2 gFrameDim;
uniform uint  gFrameSeed;

// Previous-frame resources (temporal reuse)
Texture2D<float2> gMotionVectors;              // Screen-space motion vectors
Texture2D<float>  gLinearZ;                    // Current-frame linear depth
Texture2D<float>  gPrevLinearZ;                // Previous-frame linear depth
Texture2D<float4> gPrevNormalRoughness;        // Previous-frame world-space normals + roughness
StructuredBuffer<Reservoir> gPrevReservoirs;   // Previous-frame reservoirs (read-only)
Texture2D<float>  gPrevReservoirConfidences;   // Previous-frame reservoir confidences (read-only)

struct Reservoir
{
    float3 radiance = 0;
    float UCW = 0;
    uint3 sample = {}; // RNG seed
    float confidence = 1; // confidence is also stored in gOutputReservoirConfidences, but duplicated here for convenience
    float3 _;
    float weightSum = 0;

    float phat() { return luminance(radiance); }
}

void combineReservoirWith<S : ISampleGenerator>(inout Reservoir current, Reservoir otherReservoir, float MISWeight, float3 radiance, float phat, float jacobian, inout S sg)
{
    if (otherReservoir.UCW <= 0.0f)
    {
        current.confidence += otherReservoir.confidence;
        return;
    }

    float sampleWeight = MISWeight * phat * otherReservoir.UCW * jacobian;

    current.confidence += otherReservoir.confidence;
    current.weightSum += sampleWeight;

    if (sampleNext1D(sg) * current.weightSum < sampleWeight)
    {
        current.sample = otherReservoir.sample;
        current.radiance = radiance;
    }
}

void getNormalization(inout float normalizationNumerator, inout float normalizationDenominator, Reservoir finalReservoir, float initialPhat, float temporalPhat)
{
    if (finalReservoir.weightSum <= 0.0f)
    {
        normalizationNumerator = 1.0f;
        normalizationDenominator = 1.0f;
        return;
    }

    normalizationNumerator = 1.0f;

    // Checking how many of our neighbors could have produced the sample that we just picked
    // and we're going to divide by the sum of M values of those neighbors.
    normalizationDenominator = 0.0f;

    normalizationDenominator += (initialPhat > 0.0f) * 1.0f;
    normalizationDenominator += (temporalPhat > 0.0f) * 1.0f;
}

void endWithNormalization(inout Reservoir current, float normalizationNumerator, float normalizationDenominator)
{
    if (current.weightSum == 0.0f || current.weightSum < 1.0e-10f || current.weightSum > 1.0e10f || normalizationDenominator == 0.0f || normalizationNumerator == 0.0f)
    {
        current.UCW = 0.0f;
    }
    else
    {
        current.UCW = current.weightSum / current.phat() / normalizationDenominator;
    }

    // Hard limit confidence if there is no M cap.
    if (current.confidence > 1000000.0f)
    {
        current.confidence = 1000000.0f;
    }
}

ShadingData loadShadingData(const HitInfo hit, const float3 rayDir)
{
    uint materialID = {};
    VertexData v = {};
    materialID = {};

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (hit.getType() == HitType::Triangle)
    {
        const TriangleHit triangleHit = hit.getTriangleHit();
        StaticVertexData vertices[3];
        v = gScene.getVertexData(triangleHit, vertices);
        materialID = gScene.getMaterialID(triangleHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_DISPLACED_TRIANGLE_MESH)
    if (hit.getType() == HitType::DisplacedTriangle)
    {
        const DisplacedTriangleHit displacedTriangleHit = hit.getDisplacedTriangleHit();
        v = gScene.getVertexData(displacedTriangleHit, -rayDir);
        materialID = gScene.getMaterialID(displacedTriangleHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_CURVE)
    if (hit.getType() == HitType::Curve)
    {
        const CurveHit curveHit = hit.getCurveHit();
        v = gScene.getVertexDataFromCurve(curveHit);
        materialID = gScene.getMaterialID(curveHit.instanceID);
    }
#endif

    return gScene.materials.prepareShadingData(v, materialID, -rayDir);
}

float3 evalSample(const uint3 sample, const ShadingData sd, const IMaterialInstance mi)
{
    float3 radiance;
    Ray shadowRay;

    UniformSampleGenerator sg = UniformSampleGenerator(sample.xy, sample.z);

    const float envProb = kSceneHasEnvLight ? (kSceneHasEmissiveLights ? 0.5 : 1) : 0;
    const bool env = sampleNext1D(sg) < envProb;

    if (kSceneHasEmissiveLights && !env)
    {
        const uint triangleCount = gScene.lightCollection.getActiveTriangleCount();
        if (triangleCount == 0)
            return 0;

        // Randomly pick a triangle out of the global list of active triangles with uniform probability.
        const uint idx = min((uint)(sampleNext1D(sg) * triangleCount), triangleCount - 1);
        const uint triangleIndex = gScene.lightCollection.activeTriangles[idx];

        const EmissiveTriangle tri = gScene.lightCollection.getTriangle(triangleIndex);

        const float3 barycentrics = sample_triangle(sampleNext2D(sg));

        const float3 Le = gScene.materials.evalEmissive(tri.materialID, tri.getTexCoord(barycentrics));
        float pdf = 1 / (float(triangleCount) * tri.area);
        pdf *= 1 - envProb;

        const MeshLightData meshData = gScene.lightCollection.getMeshData(triangleIndex);
        TriangleHit triHit = {};
        triHit.instanceID = { meshData.instanceID };
        triHit.primitiveIndex = triangleIndex - meshData.triangleOffset;
        triHit.barycentrics = barycentrics.yz;

        const float3 lightPos = tri.getPosition(barycentrics);
        float3 toLight = lightPos - sd.posW;
        const float dist2 = dot(toLight, toLight);
        toLight = normalize(toLight);

        float G = max(0, -dot(toLight, tri.normal)) / dist2;

        radiance = mi.eval(sd, toLight, sg) * Le * G / pdf;

        const float3 rayOrigin = computeRayOrigin(sd.posW, sd.faceN * sign(dot(sd.faceN, toLight)));
        shadowRay = Ray(rayOrigin, computeRayOrigin(lightPos, tri.normal) - rayOrigin, 0, 1);
    }
    else if (kSceneHasEnvLight && env)
    {
        EnvMapSample result;
        if (!gEnvSampler.sample(sampleNext2D(sg), result))
            return 0;

        float pdf = result.pdf * envProb;
        radiance = mi.eval(sd, result.dir, sg) * result.Le / pdf;

        const float3 rayOrigin = computeRayOrigin(sd.posW, sd.faceN * sign(dot(sd.faceN, result.dir)));
        shadowRay = Ray(rayOrigin, result.dir, 0, FLT_MAX);
    }

    if (!any(radiance > 0))
        return 0;

    if (!traceSceneVisibilityRay<1>(shadowRay, RAY_FLAG_NONE, 0xFF))
        return 0;

    return radiance;
}

uint flattenIndex(uint2 index, uint width)
{
    return index.y * width + index.x;
}

uint2 unflattenIndex(uint index, uint width)
{
    return uint2(index%width, index/width);
}
