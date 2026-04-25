
#pragma once

#include "MiniSPMIS.h"
#include "RenderGraph/RenderPassHelpers.h"

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, MiniSPMIS>();
}

namespace
{
    inline const ChannelList kInputChannels = {
        // clang-format off
        { "vbuffer",        "gVBuffer",     "Visibility buffer in packed format" },
        { "viewW",          "gViewW",       "World-space view direction (xyz float format)", true /* optional */ },
        // clang-format on
    };
    inline const ChannelList kOutputChannels = {
        // clang-format off
        { "color",           "gOutputColor",           "Output color (sum of direct and indirect)", false, ResourceFormat::RGBA32Float },
        { "normalRoughness", "gOutputNormalRoughness", "Output world-space normal and roughness",   false, ResourceFormat::RGBA32Float },
        // clang-format on
    };
}

MiniSPMIS::MiniSPMIS(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);
    mpPixelDebug = std::make_unique<PixelDebug>(pDevice);
}

void MiniSPMIS::parseProperties(const Properties& props)
{

}
Properties MiniSPMIS::getProperties() const
{
    return {};
}
RenderPassReflection MiniSPMIS::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector,  kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

void MiniSPMIS::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpScene = pScene;
    mFrameSeed = 0;

    mpEnvSampler = nullptr;

    mpInitialSamplingPass = nullptr;
    mpCreateReservoirCellPass = nullptr;
    mpComputeOffsetsPass = nullptr;
    mpSortPass = nullptr;
    mpSpatialReusePass = nullptr;
}

bool MiniSPMIS::onMouseEvent(const MouseEvent& mouseEvent)
{
    return mpPixelDebug->onMouseEvent(mouseEvent);
}

void MiniSPMIS::renderUI(Gui::Widgets& widget)
{
    widget.checkbox("Enable SPMIS", mEnableSpmis);
    if (auto group = widget.group("SPMIS"))
    {
        ImGui::BeginDisabled(!mEnableSpmis);
        group.checkbox("Defensive variant", mDefensivePairwise);
        group.tooltip("Use the defensive variant of Pairwise MIS.");
        group.var("SPMIS passes", mPassCount);
        group.tooltip("Number of times to run SPMIS per-frame.");
        group.var("Candidates", mCandidateCount);
        group.tooltip("Number of candidates to reuse (from a\nsingle cell) within each SPMIS pass");
        group.var("Cell size", mReservoirCellSize);
        group.tooltip("Maximum size of a reuse cell, in pixels.");
        group.var("Jitter radius", mJitterRadius);
        group.tooltip("Minimum radius to use when searching for\na similar cell.");
        ImGui::EndDisabled();
    }
    widget.checkbox("Use fixed seed", mUseFixedSeed);
    widget.var("Fixed seed", mFixedSeed);
    if (auto group = widget.group("Pixel debug"))
    {
        mpPixelDebug->renderUI(group);
    }
}

void MiniSPMIS::preparePass(ref<ComputePass>& pass, const char* shaderFile, const char* entryPoint, const DefineList& defines)
{
    if (!pass)
    {
        ProgramDesc desc;
        desc.addShaderLibrary(shaderFile);
        desc.csEntry(entryPoint);
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addTypeConformances(mpScene->getTypeConformances());
        pass = ComputePass::create(mpDevice, desc, defines);
    }
    pass->getProgram()->addDefines(defines);
}

void MiniSPMIS::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpScene)
        return;

    if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::EnvMapChanged) || is_set(mpScene->getUpdates(), Scene::UpdateFlags::EnvMapPropertiesChanged))
        mpEnvSampler = nullptr;

    if (mpScene->useEnvLight())
    {
        if (!mpEnvSampler)
        {
            mpEnvSampler = std::make_unique<EnvMapSampler>(mpDevice, mpScene->getEnvMap());
        }
    }
    else
    {
        mpEnvSampler = nullptr;
    }

    mpScene->getLightCollection(pRenderContext); // needed to populate emissive triangle shader data

    mpPixelDebug->beginFrame(pRenderContext, renderData.getDefaultTextureDims());

    sampleInitialPaths(pRenderContext, renderData);
    spmis(pRenderContext, renderData);

    mpPixelDebug->endFrame(pRenderContext);

    mFrameSeed++;
}

void MiniSPMIS::sampleInitialPaths(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "SPMIS spatial reuse");

    const uint3 outputDim = uint3(renderData.getDefaultTextureDims(), 1u);
    FALCOR_ASSERT(outputDim.x > 0 && outputDim.y > 0);

    DefineList defines;
    mpScene->getShaderDefines(defines);
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    defines.add(getValidResourceDefines(kOutputChannels, renderData));
    defines.add("SCENE_HAS_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("SCENE_HAS_ENV_LIGHT",       mpScene->useEnvLight() ? "1" : "0");
    defines.add("SCENE_HAS_ENV_BACKGROUND",  mpScene->useEnvBackground() ? "1" : "0");

    preparePass(mpInitialSamplingPass, "RenderPasses/MiniSPMIS/InitialSampling.cs.slang", "main", defines);

    // Create resources if needed

    const uint numPixels = outputDim.x * outputDim.y;

    auto reflectVar = mpInitialSamplingPass->getRootVar();
    if (!mpReservoirConfidences || mpReservoirConfidences->getWidth() != outputDim.x || mpReservoirConfidences->getHeight() != outputDim.y)
    {
        mpReservoirs = mpDevice->createStructuredBuffer(reflectVar["gOutputReservoirs"], numPixels);
        mpReservoirConfidences = mpDevice->createTexture2D(outputDim.x, outputDim.y, ResourceFormat::R32Float, 1u, 1u, nullptr, ResourceBindFlags::ShaderResource|ResourceBindFlags::UnorderedAccess);
    }

    // Bind resources

    auto bindVars = [&](const ref<ComputePass>& pass) {
        auto var = pass->getRootVar();

        var["gOutputColor"] = renderData.getTexture("color");
        var["gOutputNormalRoughness"] = renderData.getTexture("normalRoughness");
        var["gOutputReservoirs"] = mpReservoirs;
        var["gOutputReservoirConfidences"] = mpReservoirConfidences;
        if (mpEnvSampler) mpEnvSampler->bindShaderData(var["gEnvSampler"]);
        var["gFrameDim"] = uint2(outputDim.x, outputDim.y);
        var["gFrameSeed"] = mUseFixedSeed ? mFixedSeed : mFrameSeed;

        mpPixelDebug->prepareProgram(pass->getProgram(), var);

        mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);

        for (auto channel : kInputChannels)
            if (!channel.texname.empty())
                var[channel.texname] = renderData.getTexture(channel.name);
        for (auto channel : kOutputChannels)
            if (!channel.texname.empty())
                var[channel.texname] = renderData.getTexture(channel.name);
    };
    bindVars(mpInitialSamplingPass);

    // Sample lighting

    FALCOR_PROFILE(pRenderContext, "Initial sampling");
    mpInitialSamplingPass->execute(pRenderContext, outputDim);
}

void MiniSPMIS::spmis(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mEnableSpmis)
        return;

    FALCOR_PROFILE(pRenderContext, "SPMIS spatial reuse");

    const uint3 outputDim = uint3(renderData.getDefaultTextureDims(), 1u);
    FALCOR_ASSERT(outputDim.x > 0 && outputDim.y > 0);

    DefineList defines;
    mpScene->getShaderDefines(defines);
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    defines.add(getValidResourceDefines(kOutputChannels, renderData));
    defines.add("SCENE_HAS_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("SCENE_HAS_ENV_LIGHT",       mpScene->useEnvLight() ? "1" : "0");
    defines.add("SCENE_HAS_ENV_BACKGROUND",  mpScene->useEnvBackground() ? "1" : "0");
    defines.add("USE_DEFENSIVE_PAIRWISE", mDefensivePairwise ? "1" : "0");

    preparePass(mpCreateReservoirCellPass, "RenderPasses/MiniSPMIS/SPMIS.cs.slang", "createReuseCells", defines);
    preparePass(mpComputeOffsetsPass,      "RenderPasses/MiniSPMIS/SPMIS.cs.slang", "computeOffsets", defines);
    preparePass(mpSortPass,                "RenderPasses/MiniSPMIS/SPMIS.cs.slang", "sort", defines);
    preparePass(mpSpatialReusePass,        "RenderPasses/MiniSPMIS/SPMIS.cs.slang", "main", defines);

    // Create resources if needed

    const uint maxCells = outputDim.x * outputDim.y;

    auto reflectVar = mpSpatialReusePass->getRootVar();

    if (!mpReservoirCells || mpReservoirCells->maxSize() != maxCells)
    {
        mpReservoirCells          = GPUHashSet::create(mpDevice, maxCells);
        mpReservoirCellMap        = GPUMultiMap::create(mpDevice, reflectVar["gReservoirCellMap"],        maxCells, maxCells);
        mpReservoirCellInverseMap = GPUMultiMap::create(mpDevice, reflectVar["gReservoirCellInverseMap"], maxCells, maxCells);
    }
    if (!mpReservoirCellConfidences || mpReservoirCellConfidences->getElementCount() != maxCells)
    {
        mpReservoirCellConfidences = mpDevice->createStructuredBuffer(reflectVar["gReservoirCellConfidences"], maxCells);
        mpReservoirCellImportances = mpDevice->createStructuredBuffer(reflectVar["gReservoirCellImportances"], maxCells);
    }

    // Bind resources

    auto bindVars = [&](const ref<ComputePass>& pass) {
        auto var = pass->getRootVar();
        var["gOutputColor"] = renderData.getTexture("color");
        var["gOutputNormalRoughness"] = renderData.getTexture("normalRoughness");
        var["gOutputReservoirs"] = mpReservoirs;
        var["gOutputReservoirConfidences"] = mpReservoirConfidences;
        var["gReservoirCellConfidences"] = mpReservoirCellConfidences;
        var["gReservoirCellImportances"] = mpReservoirCellImportances;
        mpReservoirCells->bindShaderVars(var["gReservoirCells"]);
        mpReservoirCellMap->bindShaderVars(var["gReservoirCellMap"]);
        mpReservoirCellInverseMap->bindShaderVars(var["gReservoirCellInverseMap"]);
        if (mpEnvSampler) mpEnvSampler->bindShaderData(var["gEnvSampler"]);
        var["gFrameDim"] = uint2(outputDim.x, outputDim.y);
        var["gReservoirCellSize"] = mReservoirCellSize;
        var["gFrameSeed"] = mUseFixedSeed ? mFixedSeed : mFrameSeed;
        var["gJitterRadius"] = mJitterRadius;
        var["gSpatialCandidates"] = mCandidateCount;

        mpPixelDebug->prepareProgram(pass->getProgram(), var);

        mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);

        for (auto channel : kInputChannels)
            if (!channel.texname.empty())
                var[channel.texname] = renderData.getTexture(channel.name);
        for (auto channel : kOutputChannels)
            if (!channel.texname.empty())
                var[channel.texname] = renderData.getTexture(channel.name);
    };
    bindVars(mpCreateReservoirCellPass);
    bindVars(mpComputeOffsetsPass);
    bindVars(mpSortPass);
    bindVars(mpSpatialReusePass);

    for (uint i = 0; i < mPassCount; i++)
    {
        mpCreateReservoirCellPass->getRootVar()["gSpatialPassIndex"] = i;
        mpSpatialReusePass->getRootVar()["gSpatialPassIndex"] = i;

        {
            FALCOR_PROFILE(pRenderContext, "Create reuse cells");

            pRenderContext->clearUAV(mpReservoirCellConfidences->getUAV().get(), uint4(0,0,0,0));
            mpReservoirCells->clear(pRenderContext);
            mpReservoirCellMap->clear(pRenderContext);
            mpReservoirCellInverseMap->clear(pRenderContext);

            // insert reservoirs into multimaps, count cell confidences
            mpCreateReservoirCellPass->execute(pRenderContext, outputDim);

            // sort multimap data
            mpComputeOffsetsPass->execute(pRenderContext, uint3(4096u, div_round_up(maxCells, 4096u), 1u));
            mpSortPass->execute(pRenderContext, uint3(4096u, div_round_up(maxCells, 4096u), 1u));
        }

        {
            FALCOR_PROFILE(pRenderContext, "Resampling");
            mpSpatialReusePass->execute(pRenderContext, outputDim);
        }
    }
}
