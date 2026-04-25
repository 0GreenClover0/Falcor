
#pragma once

#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "Rendering/Lights/EnvMapSampler.h"
#include "Utils/Debug/PixelDebug.h"

using namespace Falcor;

struct GPUHashSet {
    ref<Buffer> mpChecksums;

    inline static std::unique_ptr<GPUHashSet> create(const ref<Device>& pDevice, const uint size) {
        auto h = std::make_unique<GPUHashSet>();
        h->mpChecksums = pDevice->createStructuredBuffer(sizeof(uint), size);
        return h;
    }

    inline uint maxSize() const { return mpChecksums->getElementCount(); }

    // clear the set on the GPU
    inline void clear(RenderContext* pRenderContext) const {
        pRenderContext->clearUAV(mpChecksums->getUAV().get(), uint4(0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu));
    }

    inline void bindShaderVars(ShaderVar var) const {
        var["checksums"] = mpChecksums;
        var["size"] = (uint)mpChecksums->getElementCount();
    }

    // size of internal buffer in bytes
    inline size_t getSize() const {
        return mpChecksums->getSize();
    }
};

struct GPUMultiMap {
    ref<Buffer> mpData; // inserted items, in order of insertion
    ref<Buffer> mpSortedData; // items sorted by cell index
    ref<Buffer> mpDataIndices; // for items in mpData: stores uint2(cellIndex, indexInCell)
    ref<Buffer> mpCellCounters;
    ref<Buffer> mpCellOffsets;
    ref<Buffer> mpCounters;

    inline static std::unique_ptr<GPUMultiMap> create(const ref<Device>& pDevice, const uint elementSize, const uint maxCells, const uint maxElements) {
        auto h = std::make_unique<GPUMultiMap>();
        h->mpData         = pDevice->createStructuredBuffer(elementSize, maxElements);
        h->mpSortedData   = pDevice->createStructuredBuffer(elementSize, maxElements);
        h->mpDataIndices  = pDevice->createStructuredBuffer(sizeof(uint2), maxElements);
        h->mpCellCounters = pDevice->createStructuredBuffer(sizeof(uint), maxCells);
        h->mpCellOffsets  = pDevice->createStructuredBuffer(sizeof(uint), maxCells);
        h->mpCounters     = pDevice->createStructuredBuffer(sizeof(uint), 2);
        return h;
    }

    inline static std::unique_ptr<GPUMultiMap> create(const ref<Device>& pDevice, const ShaderVar var, const uint maxCells, const uint maxElements) {
        const uint elementSize = var["data"].getType()->unwrapArray()->asResourceType()->getStructType()->getSlangTypeLayout()->getStride();
        return create(pDevice, elementSize, maxCells, maxElements);
    }

    inline uint maxElements() const { return mpData->getElementCount(); }
    inline uint maxCells() const { return mpCellCounters->getElementCount(); }

    inline void bindShaderVars(ShaderVar var) const {
        var["data"]         = mpData;
        var["sortedData"]   = mpSortedData;
        var["dataIndices"]  = mpDataIndices;
        var["cellCounters"] = mpCellCounters;
        var["cellOffsets"]  = mpCellOffsets;
        var["counters"]     = mpCounters;
        var["maxSize"] = (uint)mpData->getElementCount();
    }

    inline void clear(RenderContext* pRenderContext) const {
        pRenderContext->clearUAV(mpCellCounters->getUAV().get(), uint4(0,0,0,0));
        pRenderContext->clearUAV(mpCounters->getUAV().get(), uint4(0,0,0,0));
    }

    // size of all internal buffers in bytes
    inline size_t getSize() const {
        return mpData->getSize() +
               mpSortedData->getSize() +
               mpDataIndices->getSize() +
               mpCellCounters->getSize() +
               mpCellOffsets->getSize() +
               mpCounters->getSize();
    }
};

class MiniSPMIS : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(MiniSPMIS, "MiniSPMIS", "Stochastic Pairwise MIS minimal example.");

    static ref<MiniSPMIS> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<MiniSPMIS>(pDevice, props);
    }

    MiniSPMIS(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;

private:
    void parseProperties(const Properties& props);
    void preparePass(ref<ComputePass>& pass, const char* shaderFile, const char* entryPoint, const DefineList& defines);
    void sampleInitialPaths(RenderContext* pRenderContext, const RenderData& renderData);
    void spmis(RenderContext* pRenderContext, const RenderData& renderData);

private:
    ref<Scene>  mpScene;
    std::unique_ptr<EnvMapSampler> mpEnvSampler;
    std::unique_ptr<PixelDebug>    mpPixelDebug;

    // ------------ Path tracing resources ------------

    ref<ComputePass> mpInitialSamplingPass;

    ref<Buffer>  mpReservoirs;
    ref<Texture> mpReservoirConfidences;

    uint mFrameSeed = 0;
    uint mFixedSeed = 0;
    bool mUseFixedSeed = 0;

    // ------------ SPMIS resources ------------

    ref<ComputePass> mpCreateReservoirCellPass;
    ref<ComputePass> mpComputeOffsetsPass;
    ref<ComputePass> mpSortPass;
    ref<ComputePass> mpSpatialReusePass;

    std::unique_ptr<GPUHashSet>  mpReservoirCells; // hashed pixel -> cellId
    std::unique_ptr<GPUMultiMap> mpReservoirCellMap; // cellId -> reservoir indices
    std::unique_ptr<GPUMultiMap> mpReservoirCellInverseMap; // cellId -> pixel indices
    ref<Buffer>  mpReservoirCellConfidences; // cellId -> confidence sum
    ref<Buffer>  mpReservoirCellImportances; // cached reservoir importance (eq. 17)

    bool  mEnableSpmis = false;
    uint  mPassCount = 1;
    uint  mCandidateCount = 3;
    bool  mDefensivePairwise = true;
    uint2 mReservoirCellSize = uint2(16,16);
    float mJitterRadius = 30;
};
