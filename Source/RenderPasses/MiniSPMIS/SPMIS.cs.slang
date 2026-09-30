#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Sampling.UniformSampleGenerator;
import Scene.Shading;
import Reservoir;
import HashMap;

static const bool kDefensivePairwise = (bool)USE_DEFENSIVE_PAIRWISE;

struct PackedPixelConfidence
{
    uint  flatPixel;
    float confidence;
};

#define is_valid(name) (is_valid_##name != 0)

RWStructuredBuffer<uint> gReservoirCellConfidences;
RWStructuredBuffer<float> gReservoirCellImportances; // cached reservoir importance (eq. 17)
uniform HashSet gReservoirCells;
uniform MultiMap<Reservoir> gReservoirCellMap;
uniform MultiMap<PackedPixelConfidence> gReservoirCellInverseMap;
uniform uint2 gReservoirCellSize;
uniform float gJitterRadius;
uniform uint  gSpatialCandidates;
uniform uint  gSpatialPassIndex;

Reservoir spatialShift(const Reservoir src, const uint2 dstPixel, out float jacobian)
{
    const HitInfo hit = HitInfo(gVBuffer[dstPixel]);
    if (!hit.isValid())
    {
        jacobian = 0;
        return {};
    }

    float3 rayDir;
    if (is_valid(gViewW))
    {
        // If we have the view vector bound as a buffer, just fetch it. No need to compute anything.
        rayDir = -gViewW[dstPixel].xyz;
    }
    else
    {
        // Compute the view vector. This must exactly match what the G-buffer pass is doing (jitter etc.).
        // Note that we do not take depth-of-field into account as it would require exactly matching the
        // sample generator between the passes, which is error prone. The host side will issue a warning instead.
        rayDir = gScene.camera.computeRayPinhole(dstPixel, gFrameDim).dir;
    }

    const ShadingData sd = loadShadingData(hit, rayDir);
    let mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0));

    Reservoir dst = src;
    dst.radiance = evalSample(src.sample, sd, mi);
    jacobian = 1; // PSS random replay Jacobian is 1
    return dst;
}

float safeDivide(float a, float b)
{
    return abs(b) > 0 ? a / b : 0;
}

// Non-defensive m_c is the sum of beta terms. Defensive m_c terms is the sum of beta terms plus c_c / (c_c + c_sum)
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


// Select a reservoir according to eq. 17 from within cellRange
uint sampleFromCell<S : ISampleGenerator>(inout S sg, uint2 cellRange, out float selectionW)
{
    const uint N = cellRange.y - cellRange.x;

    float wsum = 0;
    uint  selected = 0;
    float selectedp = 0;

    // just choose 8 samples from the cell and RIS over them.
    // full importance sampling can be acheived by visiting the entire cellRange.
    for (uint k = 0; k < 8; k++)
    {
        const float u = (k + sampleNext1D(sg)) / 8; // basic stratification

        const uint j = min(uint(u*N), N - 1);
        const float p = gReservoirCellImportances[cellRange.x + j];

        const float w = p * N;

        wsum += w;
        if (wsum * sampleNext1D(sg) < w)
        {
            selected = j;
            selectedp = p;
        }
    }

    selectionW = selectedp > 0 ? wsum / (8*selectedp) : 0;
    return selected;
}

// Quantize g-buffer attributes (xyz: normal, w: roughness)
int4 quantizeAttributes(uint2 pixel)
{
    const float4 v = gOutputNormalRoughness[pixel];
    const float3 n = oct_to_ndir_unorm(v.xy);
    const float r = 0;//1 - sqr(v.z * .999 + .001);
    return int4(floor(float4(n * 2, r * 4)));
}

// Hash tile index + attributes
HashKey hashPixel(uint2 pixel, int4 attributes)
{
    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    return HashKey(pixel.x / gReservoirCellSize.x) +
           HashKey(pixel.y / gReservoirCellSize.y) +
           HashKey(hit.getInstanceID().index) + // instance ID
           HashKey(attributes.x) + // normal x
           HashKey(attributes.y) + // normal y
           HashKey(attributes.z) + // normal z
           HashKey(attributes.w);  // roughness
}

// quantize confidence values so that we can use integer atomics
uint  quantizeConfidence(float c) { return uint(c * 1000); }
// quantize confidence values so that we can use integer atomics
float dequantizeConfidence(uint q) { return float(q) / 1000.f; }

// Randomly select a high-confidence cell around the pixel.
uint3 findSimilarCell<S : ISampleGenerator>(const uint2 pixel, inout S sg)
{
    const int4 centerAttribs = quantizeAttributes(pixel);
    const uint centerCell = gReservoirCells.find(hashPixel(pixel, centerAttribs));

    #if 0

    // uniform cell selection

    // const int2 p = clamp(int2(float2(pixel) + ((sampleNext2D(sg) - 0.5) * gJitterRadius)), 0, gFrameDim - 1);
    // const uint cell = gReservoirCells.find(hashPixel(p, quantizeAttributes(p)));
    // return (cell == HashSet::kInvalidIndex) ? centerCell : cell;
    return uint3(0, 0, 0);
    #else

    // weighted cell selection
    // select high-confidence cells with similar normal/roughness

    float radius = gJitterRadius;

    const float c_center = (centerCell == HashSet::kInvalidIndex) ? 0 : dequantizeConfidence(gReservoirCellConfidences[centerCell]); ;

    uint selected1 = centerCell;
    uint selected2 = centerCell;
    uint selected3 = centerCell;

    float w_sum1 = c_center;
    float w_sum2 = c_center;
    float w_sum3 = c_center;

    const int4 centerAttribsMinusOne = centerAttribs - 1;
    const int4 centerAttribsPlusOne = centerAttribs + 1;

    const uint2 frameDimMinusOne = gFrameDim - 1;

    for (uint i = 0; i < 8; i++)
    {
        const int2 pixel_i1 = clamp(int2(pixel + sample_disk(sampleNext2D(sg)) * radius), 0, frameDimMinusOne);
        const int2 pixel_i2 = clamp(int2(pixel + sample_disk(sampleNext2D(sg)) * radius), 0, frameDimMinusOne);
        const int2 pixel_i3 = clamp(int2(pixel + sample_disk(sampleNext2D(sg)) * radius), 0, frameDimMinusOne);

        // increase radius for next iteration
        radius *= 1.25;

        // clamp cell attributes to within 1 quantization step of the center pixel
        const int4 attribs_i1 = clamp(quantizeAttributes(pixel_i1), centerAttribsMinusOne, centerAttribsPlusOne);
        const int4 attribs_i2 = clamp(quantizeAttributes(pixel_i2), centerAttribsMinusOne, centerAttribsPlusOne);
        const int4 attribs_i3 = clamp(quantizeAttributes(pixel_i3), centerAttribsMinusOne, centerAttribsPlusOne);

        const uint cell1 = gReservoirCells.find(hashPixel(pixel_i1, attribs_i1));
        const uint cell2 = gReservoirCells.find(hashPixel(pixel_i2, attribs_i2));
        const uint cell3 = gReservoirCells.find(hashPixel(pixel_i3, attribs_i3));

        if (cell1 != HashSet::kInvalidIndex && cell1 != centerCell)
        {
            const float c_cell = dequantizeConfidence(gReservoirCellConfidences[cell1]);
            w_sum1 += c_cell;
            if (sampleNext1D(sg) * w_sum1 < c_cell)
                selected1 = cell1;
        }

        if (cell2 != HashSet::kInvalidIndex && cell2 != centerCell)
        {
            const float c_cell = dequantizeConfidence(gReservoirCellConfidences[cell2]);
            w_sum2 += c_cell;
            if (sampleNext1D(sg) * w_sum2 < c_cell)
                selected2 = cell2;
        }

        if (cell3 != HashSet::kInvalidIndex && cell3 != centerCell)
        {
            const float c_cell = dequantizeConfidence(gReservoirCellConfidences[cell3]);
            w_sum3 += c_cell;
            if (sampleNext1D(sg) * w_sum3 < c_cell)
                selected3 = cell3;
        }
    }

    return uint3(selected1, selected2, selected3);
    #endif
}

[shader("compute")]
[numthreads(8, 4, 1)]
void createReuseCells(uint2 pixel: SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDim))
        return;

    const float confidence = gOutputReservoirConfidences[pixel];

    Reservoir center = gOutputReservoirs[flattenIndex(pixel, gFrameDim.x)];
    center.confidence = confidence; // ensure duplicated confidence values match

    const uint cellId = gReservoirCells.insert(hashPixel(pixel, quantizeAttributes(pixel)));
    if (cellId == HashSet::kInvalidIndex)
        return; // shouldnt happen

    // sum confidences inside the cell
    InterlockedAdd(gReservoirCellConfidences[cellId], quantizeConfidence(confidence));

    // insert pixel index into the cell
    gReservoirCellInverseMap.insert(cellId, { flattenIndex(pixel, gFrameDim.x), confidence });

    // insert reservoir into the cell if nonzero
    if (center.phat() > 0)
        gReservoirCellMap.insert(cellId, center);
}

[shader("compute")]
[numthreads(32, 1, 1)]
void computeOffsets(uint3 threadId: SV_DispatchThreadID)
{
    const uint cell = threadId.x + threadId.y * 4096;
    {
        uint i;
        InterlockedAdd(gReservoirCellInverseMap.counters[1], gReservoirCellInverseMap.cellCounters[cell], i);
        gReservoirCellInverseMap.cellOffsets[cell] = i;
    }
    {
        uint i;
        InterlockedAdd(gReservoirCellMap.counters[1], gReservoirCellMap.cellCounters[cell], i);
        gReservoirCellMap.cellOffsets[cell] = i;
    }
}

[shader("compute")]
[numthreads(32, 1, 1)]
void sort(uint3 threadId: SV_DispatchThreadID)
{
    const uint index = threadId.x + threadId.y * 4096;

    if (index < min(gReservoirCellInverseMap.maxSize, gReservoirCellInverseMap.counters[0]))
    {
        const uint2 p = gReservoirCellInverseMap.dataIndices[index];
        const uint cell = p.x;
        const uint indexInCell = p.y;
        gReservoirCellInverseMap.sortedData[gReservoirCellInverseMap.cellOffsets[cell] + indexInCell] = gReservoirCellInverseMap.data[index];
    }

    if (index < min(gReservoirCellMap.maxSize, gReservoirCellMap.counters[0]))
    {
        const Reservoir src = gReservoirCellMap.data[index];

        const uint2 p = gReservoirCellMap.dataIndices[index];
        const uint cell = p.x;
        const uint indexInCell = p.y;
        const uint dst = gReservoirCellMap.cellOffsets[cell] + indexInCell;
        gReservoirCellMap.sortedData[dst] = src;
        gReservoirCellImportances[dst] = src.confidence * src.phat() * src.UCW;
    }
}

[shader("compute")]
[numthreads(8, 4, 1)]
void main(uint2 pixel : SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDim))
        return;

    UniformSampleGenerator sg = UniformSampleGenerator(pixel, pcg(gSpatialPassIndex + pcg(gFrameSeed)));

    const int4 centerAttribs = quantizeAttributes(pixel);
    const uint centerCell = gReservoirCells.find(hashPixel(pixel, centerAttribs));

    gOutputColor[pixel] = float4(float(centerCell & 1), float(centerCell & 3) / 4, float(centerCell & 7) / 8, 1);
    return;

    // 2. cell <- SampleNeighborCell(c)
    const uint cellId1 = findSimilarCell(pixel, sg).x;

    // 4. Y <- 0 is not here. No output sample since this is not a function. Just merge with the center reservoir. 
    Reservoir center = gOutputReservoirs[flattenIndex(pixel, gFrameDim.x)];
    const float centerConfidence = dequantizeConfidence(quantizeConfidence(gOutputReservoirConfidences[pixel]));

    const uint2 pixelRange = gReservoirCellInverseMap.getRange(cellId1);
    const uint  pixelN = pixelRange.y - pixelRange.x;
    if (pixelN == 0)
        return; // shouldn't happen - the current pixel should always be in a cell

    // 3. cΣ <- cellConfidenceSums[cell]
    const float c_sum = dequantizeConfidence(gReservoirCellConfidences[cellId1]) * (float(gSpatialCandidates) / float(pixelN));

    // 5. w_sum <- 0
    float w_sum = 0;

    // 6. if ˆp(X_c) > 0 then
    // estimate canonical MIS weight with a single sample
    if (center.phat() > 0)
    {
        const uint j = min(uint(sampleNext1D(sg) * pixelN), pixelN - 1);
        const PackedPixelConfidence v = gReservoirCellInverseMap.get(pixelRange.x + j);
        const float selectionW = pixelN;
        const uint2 p = unflattenIndex(v.flatPixel, gFrameDim.x);
        // quantize+dequantize to ensure confidence agrees with c_sum, which has been quantized/dequantized
        float c_i = dequantizeConfidence(quantizeConfidence(v.confidence));
        // apply confidence adjustment (section 4.3)
        c_i *= (float(gSpatialCandidates) / float(pixelN));

        float jacobianToCandidate;
        const float shiftedTargetPdf = spatialShift(center, p, jacobianToCandidate).phat();

        float m_c = kDefensivePairwise ? (centerConfidence / (centerConfidence + c_sum)) : 0;
        m_c += selectionW * computePairwiseMIS_canonical_beta(c_i, centerConfidence, c_sum, shiftedTargetPdf * jacobianToCandidate, center.phat());

        w_sum = m_c * center.phat() * center.UCW;
    }

    const uint2 reservoirRange = gReservoirCellMap.getRange(cellId1);
    const uint reservoirN = reservoirRange.y - reservoirRange.x;
    if (reservoirN > 0)
    {
        for (uint i = 0; i < gSpatialCandidates; i++)
        {
            float selectionW;
            const uint j = sampleFromCell(sg, reservoirRange, selectionW);
            if (!(selectionW > 0))
                continue;

            const Reservoir x_i = gReservoirCellMap.get(reservoirRange.x + j);
            // quantize+dequantize to ensure confidence agrees with c_sum, which has been quantized/dequantized
            float c_i = dequantizeConfidence(quantizeConfidence(x_i.confidence));
            // apply confidence adjustment (section 4.3)
            c_i *= (float(gSpatialCandidates) / float(pixelN));

            const float candidateTargetPdf = x_i.phat();
            if (!(candidateTargetPdf > 0))
                continue;

            // shift candidate's sample to here
            float jacobianToCenter;
            const Reservoir y_i = spatialShift(x_i, pixel, jacobianToCenter);
            if (!(y_i.phat() > 0) || !(jacobianToCenter > 0))
                continue;

            const float m_i = (selectionW / gSpatialCandidates) * computePairwiseMIS_noncanonical(c_i, centerConfidence, c_sum, candidateTargetPdf / jacobianToCenter, y_i.phat());

            const float w_i = m_i * y_i.phat() * y_i.UCW * jacobianToCenter;
            w_sum += w_i;
            if (sampleNext1D(sg) * w_sum < w_i)
            {
                center = y_i;
            }
        }
    }

    // merge with center reservoir

    center.UCW = safeDivide(w_sum, center.phat());
    center.confidence = (c_sum + centerConfidence) / (1 + gSpatialCandidates);

    gOutputReservoirs[flattenIndex(pixel, gFrameDim.x)] = center;
    gOutputReservoirConfidences[pixel] = center.confidence;

    // add emission from primary hit to the DI reservoir estimate

    float3 primaryEmission = 0;
    {
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

        const HitInfo hit = HitInfo(gVBuffer[pixel]);
        if (hit.isValid())
        {
            ShadingData sd = loadShadingData(hit, rayDir);
            let mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0));
            let props = mi.getProperties(sd);

            primaryEmission = props.emission;
        }
        else
        {
            if (kSceneHasEnvBackground)
            {
                primaryEmission = gScene.envMap.eval(rayDir);
            }
        }
    }

    gOutputColor[pixel] = float4(primaryEmission + center.radiance * center.UCW, 1);
}
