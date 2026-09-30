#include "Utils/Math/MathConstants.slangh"
#include "Scene/SceneDefines.slangh"

import Scene.Shading;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Utils.Sampling.UniformSampleGenerator;
import Reservoir;
import HashMap;

#define is_valid(name) (is_valid_##name != 0)

// Maximum ratio of temporal-to-current confidence (caps stale reservoir influence).
static const float mCap = 20.0;

static const bool kDefensivePairwise = true;

// -- Geometry validation helpers --

// Returns true when the reprojected pixel passes depth + normal similarity tests.
// depthCurrent / depthPrevious  : linear (view-space) depth values.
// normalCurrent / normalPrevious: world-space surface normals.
bool isValidTemporalNeighbor(
    float  depthCurrent,
    float  depthPrevious,
    float3 normalCurrent,
    float3 normalPrevious)
{
    // Reject sky / miss pixels that stored depth = 0.
    if (depthPrevious <= 0.0 || depthCurrent <= 0.0)
        return false;

    // Relative depth threshold: 10 % of current depth.
    if (abs(depthCurrent - depthPrevious) > 0.1 * depthCurrent)
        return false;

    // Normal similarity: cosine > cos(25 degrees) ~= 0.906.
    if (dot(normalCurrent, normalPrevious) < 0.906)
        return false;

    return true;
}

// Decode a world-space normal from an oct-encoded (normalRoughness) texture.
float3 decodeNormal(float4 normalRoughnessTexel)
{
    return oct_to_ndir_unorm(normalRoughnessTexel.xy);
}

float safeDivide(float a, float b)
{
    return abs(b) > 0 ? a / b : 0;
}

float computePairwiseMIS_canonical_beta(float c_i, float c_c, float c_sum, float phat_from_i, float phat_c)
{
    if (kDefensivePairwise)
        return (c_i / (c_sum + c_c)) * safeDivide(
            c_c * phat_c,
            c_c * phat_c + c_sum * phat_from_i );
    else
        return (c_i / c_sum) * safeDivide(
            c_c * phat_c,
            c_c * phat_c + c_sum * phat_from_i );
}

float computePairwiseMIS_noncanonical(float c_i, float c_c, float c_sum, float phat_from_i, float phat_c)
{
    if (kDefensivePairwise)
        return (c_sum / (c_sum + c_c)) * safeDivide(
            c_i * phat_from_i,
            c_sum * phat_from_i + c_c * phat_c );
    else
        return safeDivide(
            c_i * phat_from_i,
            c_sum * phat_from_i + c_c * phat_c );
}

float balanceMis(float a, float b)
{
    return (a > 0.0 && b > 0.0) ? a / (a + b) : 0.0;
}


// -- Main temporal reuse kernel --

[shader("compute")]
[numthreads(8, 4, 1)]
void main(uint2 pixel : SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDim))
        return;

    // ---- Fetch current reservoir (from InitialSampling, UCW=1) ----------
    Reservoir current = gOutputReservoirs[flattenIndex(pixel, gFrameDim.x)];
    const float currentConfidence = gOutputReservoirConfidences[pixel];
    current.confidence = currentConfidence;

    // ---- Motion vector reprojection -------------------------------------
    const float2 motion    = gMotionVectors[pixel];
    const int2   prevPixel = int2(float2(pixel) - motion + 0.5);

    if (any(prevPixel < 0) || any(prevPixel >= int2(gFrameDim)))
        return; // off-screen, keep current unchanged

    // ---- Geometry validation -------------------------------------------
    const float  depthCur   = gLinearZ[pixel].x;
    const float  depthPrev  = gPrevLinearZ[prevPixel].x;
    const float3 normalCur  = decodeNormal(gOutputNormalRoughness[pixel]);
    const float3 normalPrev = decodeNormal(gPrevNormalRoughness[prevPixel]);

    if (!isValidTemporalNeighbor(depthCur, depthPrev, normalCur, normalPrev))
        return; // geometry mismatch, keep current unchanged

    // ---- Fetch previous reservoir and apply M-cap ----------------------
    Reservoir prev = gPrevReservoirs[flattenIndex(prevPixel, gFrameDim.x)];
    float prevConfidence = min(prev.confidence, mCap);

    if (prevConfidence <= 0.0 || prev.UCW <= 0.0)
        return; // empty previous reservoir, keep current unchanged

    // ---- Load current surface ------------------------------------------
    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (!hit.isValid())
        return; // sky pixel, keep current unchanged

    float3 rayDir;
    if (is_valid(gViewW))
        rayDir = -gViewW[pixel].xyz;
    else
        rayDir = gScene.camera.computeRayPinhole(pixel, gFrameDim).dir;

    const ShadingData sd = loadShadingData(hit, rayDir);
    let mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0));

    // ---- Evaluate the previous sample at the current surface -----------
    // Jacobian = 1 for random-replay shift.
    const float3 prevRadianceAtCurrent = evalSample(prev.sample, sd, mi);
    const float  phatPrevAtCurrent     = luminance(prevRadianceAtCurrent);

    // ---- Target PDFs ---------------------------------------------------
    // phat_c: current sample at its own surface.
    const float phat_c = current.phat();

    // phat of the previous sample at its own (previous) surface.
    // We use the stored radiance — no re-evaluation needed.
    const float phatPrevAtPrev = luminance(prev.radiance);

    // phat of the current sample shifted to the previous surface.
    // Jacobian = 1 (random-replay), and the surfaces are geometrically similar
    // (depth + normal validated). We approximate this as phat_c since we don't
    // have the previous VBuffer to actually evaluate it there.
    const float phatCurrentAtPrev = phat_c;

    // ---- Balance heuristic MIS weights ---------------------------------
    // m_c: MIS weight for the canonical (current) reservoir.
    //   a = c_c * phat_c        (current domain contribution)
    //   b = c_prev * phatCurrentAtPrev / jacobian  = c_prev * phat_c  (prev domain, jacobian=1)
    const float m_c = balanceMis(
        currentConfidence * phat_c,
        prevConfidence    * phatCurrentAtPrev   // jacobian = 1
    );

    // m_i: MIS weight for the previous (non-canonical) reservoir.
    //   a = c_prev * phatPrevAtPrev            (its own domain contribution)
    //   b = c_c    * phatPrevAtCurrent / jacobian = c_c * phatPrevAtCurrent
    const float m_i = balanceMis(
        prevConfidence    * phatPrevAtPrev,
        currentConfidence * phatPrevAtCurrent   // jacobian = 1
    );

    // ---- Accumulate w_sum and stochastically select --------------------
    float Wsum = 0.0;

    // Canonical (current) contribution.
    const float w_c = m_c * current.UCW * phat_c;
    if (w_c > 0.0)
        Wsum = w_c;

    // Previous (non-canonical) contribution — shift to current surface.
    // jacobianToCenter = 1 for random-replay, so w_i = m_i * phatPrevAtCurrent * prev.UCW * 1.
    const float w_i = m_i * phatPrevAtCurrent * prev.UCW;

    Reservoir output = current; // default: keep current sample
    if (w_i > 0.0)
    {
        Wsum += w_i;
        UniformSampleGenerator sg = UniformSampleGenerator(pixel, pcg(gFrameSeed + 1u));
        if (sampleNext1D(sg) * Wsum < w_i)
        {
            output         = prev;
            output.radiance = prevRadianceAtCurrent;
        }
    }

    // ---- Finalize UCW --------------------------------------------------
    output.UCW        = safeDivide(Wsum, luminance(output.radiance));
    output.confidence = currentConfidence + prevConfidence;

    gOutputReservoirs[flattenIndex(pixel, gFrameDim.x)] = output;
    gOutputReservoirConfidences[pixel] = output.confidence;

    // ---- Write color ---------------------------------------------------
    let props = mi.getProperties(sd);
    gOutputColor[pixel] = float4(props.emission + output.radiance * output.UCW, 1.0);
}
