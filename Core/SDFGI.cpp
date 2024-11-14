#include "pch.h"
#include "SDFGI.h"
#include "BufferManager.h"
#include "GraphicsCore.h"
#include "CommandContext.h"
#include "Camera.h"
#include "GraphicsCore.h"
#include "CommandContext.h"
#include "RootSignature.h"
#include "PipelineState.h"
#include "Utility.h"
#include <random>

#include "CompiledShaders/SDFGIProbeVizVS.h"
#include "CompiledShaders/SDFGIProbeVizPS.h"
#include "CompiledShaders/SDFGIProbeVizGS.h"
#include "CompiledShaders/SDFGIProbeUpdateCS.h"
#include "CompiledShaders/SDFGIProbeIrradianceDepthVizPS.h"
#include "CompiledShaders/SDFGIProbeIrradianceDepthVizVS.h"
#include "CompiledShaders/SDFGIProbeCubemapVizVS.h"
#include "CompiledShaders/SDFGIProbeCubemapVizPS.h"
#include "CompiledShaders/SDFGIProbeCubemapDownsampleCS.h"

#define PROBE_IDX_VIZ 123

using namespace Graphics;
using namespace DirectX;

namespace SDFGI {

    float GenerateRandomNumber(float min, float max) {
        static std::random_device rd;
        static std::mt19937 gen(rd());
        std::uniform_real_distribution<float> dis(min, max);
        return dis(gen);
    }

    // Used to rotate spherical fibonacci directions.
    XMMATRIX GenerateRandomRotationMatrix(float rotation_scaler) {
        float randomX = GenerateRandomNumber(-1.0f, 1.0f) * rotation_scaler;
        float randomY = GenerateRandomNumber(-1.0f, 1.0f) * rotation_scaler;
        float randomZ = GenerateRandomNumber(-1.0f, 1.0f) * rotation_scaler;
        return XMMatrixRotationRollPitchYaw(randomX, randomY, randomZ);
    }

    // TODO: grid has to be a perfect square.
    SDFGIProbeGrid::SDFGIProbeGrid(Vector3 &sceneSize, Vector3 &sceneMin) {
        probeSpacing[0] = 350.0f;
        probeSpacing[1] = 350.0f;
        probeSpacing[2] = 350.0f;

        probeCount[0] = std::max(1u, static_cast<uint32_t>(sceneSize.GetX() / probeSpacing[0]));
        probeCount[1] = std::max(1u, static_cast<uint32_t>(sceneSize.GetY() / probeSpacing[1]));
        probeCount[2] = std::max(1u, static_cast<uint32_t>(sceneSize.GetZ() / probeSpacing[2]));

        GenerateProbes(sceneMin);
    }

    // TODO: we'll need to be able to map a probe world space position or linear index to a 3D texture coordinate.
    void SDFGIProbeGrid::GenerateProbes(Vector3 &sceneMin) {
        probes.clear();
        // TODO: make sure that grid really covers the bounding box.
        for (uint32_t x = 0; x < probeCount[0]; ++x) {
            for (uint32_t y = 0; y < probeCount[1]; ++y) {
                for (uint32_t z = 0; z < probeCount[2]; ++z) {
                    Vector3 position = sceneMin + Vector3(
                        x * probeSpacing[0],
                        y * probeSpacing[1],
                        z * probeSpacing[2]
                    );
                    probes.push_back({position});
                }
            }
        }
    }

    SDFGIManager::SDFGIManager(
        const Math::AxisAlignedBox &sceneBounds, 
        std::function<void(GraphicsContext&, const Math::Camera&, const D3D12_VIEWPORT&, const D3D12_RECT&)> renderFunc
    )
        : probeGrid(sceneBounds.GetDimensions(), sceneBounds.GetMin()), sceneBounds(sceneBounds), renderFunc(renderFunc) {
        InitializeTextures();
        InitializeViews();
        InitializeProbeBuffer();
        InitializeProbeVizShader();
        InitializeProbeUpdateShader();
        InitializeProbeAtlasVizShader();
        InitializeCubemapVizShader();
        InitializeDownsampleShader();
    };

    SDFGIManager::~SDFGIManager() {
        for (uint32_t probe = 0; probe < probeCount; ++probe) {
            delete[] probeCubemapFaceTextures[probe];
            delete[] probeCubemapFaceUAVs[probe];
        }
        delete[] probeCubemapFaceTextures;
        delete[] probeCubemapFaceUAVs;
    }

    void SDFGIManager::InitializeTextures() {
        uint32_t width = probeGrid.probeCount[0];
        uint32_t height = probeGrid.probeCount[1];
        uint32_t depth = probeGrid.probeCount[2];
        probeCount = width * height * depth;

        // 4x4 pixels per probe for octahedral mapping.
        uint32_t probeBlockSize = 4;
        // Padding between probes
        uint32_t gutterSize = 1; 

        uint32_t atlasWidth = (width * probeBlockSize) + (width + 1) * gutterSize;
        uint32_t atlasHeight = (height * probeBlockSize) + (height + 1) * gutterSize;
        // Number of bytes occupied by a single row of pixels in a texture.
        size_t rowPitchBytes = atlasWidth * sizeof(float) * 4;

        irradianceAtlas.Create2D(rowPitchBytes, atlasWidth, atlasHeight, DXGI_FORMAT_R16G16B16A16_FLOAT, nullptr, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);

        depthAtlas.Create2D(rowPitchBytes / 2, atlasWidth, atlasHeight, DXGI_FORMAT_R16_FLOAT, nullptr, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);

        // Individual cubemap faces for all probes.
        probeCubemapFaceTextures = new Texture*[probeCount];
        for (uint32_t probe  = 0; probe < probeCount; ++probe) {
            probeCubemapFaceTextures[probe] = new Texture[6];

            for (int face = 0; face < 6; ++face)
            {
                probeCubemapFaceTextures[probe][face].Create2D(
                    cubemapFaceResolution * sizeof(float) * 4,
                    cubemapFaceResolution, cubemapFaceResolution,
                    DXGI_FORMAT_R11G11B10_FLOAT,
                    nullptr,
                    // TODO: doesn't need render target flag.
                    D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS | D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET
                );
            }
        }

        // A single texture array containing all cubemap faces.
        D3D12_RESOURCE_DESC texArrayDesc = {};
        texArrayDesc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        texArrayDesc.Width = cubemapFaceResolution;
        texArrayDesc.Height = cubemapFaceResolution;
        texArrayDesc.DepthOrArraySize = probeCount * 6;
        texArrayDesc.MipLevels = 1;
        texArrayDesc.Format = DXGI_FORMAT_R11G11B10_FLOAT;
        texArrayDesc.SampleDesc.Count = 1;
        texArrayDesc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
        texArrayDesc.Flags = D3D12_RESOURCE_FLAG_NONE;
        D3D12_HEAP_PROPERTIES HeapProps;
        HeapProps.Type = D3D12_HEAP_TYPE_DEFAULT;
        HeapProps.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
        HeapProps.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
        HeapProps.CreationNodeMask = 1;
        HeapProps.VisibleNodeMask = 1;
        Microsoft::WRL::ComPtr<ID3D12Resource> textureArrayResource;
        g_Device->CreateCommittedResource(
            &HeapProps,
            D3D12_HEAP_FLAG_NONE,
            &texArrayDesc,
            D3D12_RESOURCE_STATE_COPY_DEST,
            nullptr,
            IID_PPV_ARGS(&textureArrayResource)
        );
        probeCubemapFaceArrayGpuResource = new GpuResource(textureArrayResource.Get(), D3D12_RESOURCE_STATE_COPY_DEST);
    };

    void SDFGIManager::InitializeViews() {
        irradianceAtlasUAV = AllocateDescriptor(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        D3D12_UNORDERED_ACCESS_VIEW_DESC atlasUavDesc = {};
        atlasUavDesc.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
        atlasUavDesc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
        atlasUavDesc.Texture2D.MipSlice = 0;
        atlasUavDesc.Texture2D.PlaneSlice = 0;
        g_Device->CreateUnorderedAccessView(irradianceAtlas.GetResource(), nullptr, &atlasUavDesc, irradianceAtlasUAV);

        depthAtlasUAV = AllocateDescriptor(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        atlasUavDesc.Format = DXGI_FORMAT_R16_FLOAT;
        g_Device->CreateUnorderedAccessView(depthAtlas.GetResource(), nullptr, &atlasUavDesc, depthAtlasUAV);

        probeCubemapFaceUAVs = new D3D12_CPU_DESCRIPTOR_HANDLE*[probeCount];
        for (int probe = 0; probe < probeCount; ++probe)
        {
            probeCubemapFaceUAVs[probe] = new D3D12_CPU_DESCRIPTOR_HANDLE[6];
            for (int face = 0; face < 6; ++face)
            {
                probeCubemapFaceUAVs[probe][face] = AllocateDescriptor(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
                D3D12_UNORDERED_ACCESS_VIEW_DESC  uavDesc = {};
                uavDesc.Format = DXGI_FORMAT_R11G11B10_FLOAT;
                uavDesc.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
                uavDesc.Texture2D.MipSlice = 0;
                g_Device->CreateUnorderedAccessView(probeCubemapFaceTextures[probe][face].GetResource(), nullptr, &uavDesc, probeCubemapFaceUAVs[probe][face]);
            }
        }

        D3D12_SHADER_RESOURCE_VIEW_DESC srvDesc = {};
        srvDesc.Format = DXGI_FORMAT_R11G11B10_FLOAT;
        srvDesc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2DARRAY;
        srvDesc.Texture2DArray.MostDetailedMip = 0;
        srvDesc.Texture2DArray.MipLevels = 1;
        srvDesc.Texture2DArray.FirstArraySlice = 0;
        srvDesc.Texture2DArray.ArraySize = probeCount * 6;
        srvDesc.Texture2DArray.PlaneSlice = 0;
        srvDesc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        probeCubemapFaceArraySRV = AllocateDescriptor(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        g_Device->CreateShaderResourceView(probeCubemapFaceArrayGpuResource->GetResource(), &srvDesc, probeCubemapFaceArraySRV);
    };

    void SDFGIManager::InitializeProbeBuffer() {
        std::vector<float> probeData;

        for (const auto& probe : probeGrid.probes) {
            probeData.push_back(probe.position.GetX());
            probeData.push_back(probe.position.GetY());
            probeData.push_back(probe.position.GetZ());
        }

        probeBuffer.Create(L"Probe Data Buffer", probeData.size(), sizeof(float), probeData.data());
    }

    void SDFGIManager::InitializeProbeVizShader()  {
        probeVizRS.Reset(2, 1);

        // First root parameter is a constant buffer for camera data. Register b0.
        // Visibility ALL because VS and GS access it.
        probeVizRS[0].InitAsConstantBuffer(0, D3D12_SHADER_VISIBILITY_ALL);

        // Second root parameter is a structured buffer SRV for probe buffer. Register t0.
        probeVizRS[1].InitAsBufferSRV(0, D3D12_SHADER_VISIBILITY_VERTEX);

        probeVizRS.InitStaticSampler(0, SamplerLinearClampDesc);

        probeVizRS.Finalize(L"SDFGI Root Signature", D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT);

        probeVizPSO.SetRootSignature(probeVizRS);
        probeVizPSO.SetRasterizerState(RasterizerDefault);
        probeVizPSO.SetBlendState(BlendDisable);
        probeVizPSO.SetDepthStencilState(DepthStateReadWrite);
        probeVizPSO.SetVertexShader(g_pSDFGIProbeVizVS, sizeof(g_pSDFGIProbeVizVS));
        probeVizPSO.SetGeometryShader(g_pSDFGIProbeVizGS, sizeof(g_pSDFGIProbeVizGS));
        probeVizPSO.SetPixelShader(g_pSDFGIProbeVizPS, sizeof(g_pSDFGIProbeVizPS));
        probeVizPSO.SetPrimitiveTopologyType(D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT);
        probeVizPSO.SetRenderTargetFormat(g_SceneColorBuffer.GetFormat(), g_SceneDepthBuffer.GetFormat());
        probeVizPSO.Finalize();
    }

    void SDFGIManager::RenderProbeViz(GraphicsContext& context, const Math::Camera& camera) {
        context.SetPipelineState(probeVizPSO);
        context.SetRootSignature(probeVizRS);

        CameraData camData = {};
        camData.viewProjMatrix = camera.GetViewProjMatrix();
        camData.position = camera.GetPosition();

        context.SetDynamicConstantBufferView(0, sizeof(camData), &camData);

        context.SetBufferSRV(1, probeBuffer);

        context.SetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_POINTLIST);

        context.DrawInstanced(probeGrid.probes.size(), 1, 0, 0);
    }

    void SDFGIManager::InitializeProbeUpdateShader() {
        probeUpdateRS.Reset(6, 1);

        // probeBuffer.
        probeUpdateRS[0].InitAsBufferSRV(/*register=t*/0, D3D12_SHADER_VISIBILITY_ALL);

        // Irradiance atlas.
        probeUpdateRS[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, /*register=u*/0, 1);

        // Depth atlas.
        probeUpdateRS[2].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, /*register=u*/1, 1);

        probeUpdateRS[3].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, /*register=t*/1, 6, D3D12_SHADER_VISIBILITY_ALL); 

        probeUpdateRS[4].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, /*register=t*/7, 1, D3D12_SHADER_VISIBILITY_ALL);

        // Probe grid info.
        probeUpdateRS[5].InitAsConstantBuffer(/*register=b*/0, D3D12_SHADER_VISIBILITY_ALL);

        probeUpdateRS.InitStaticSampler(0, SamplerLinearClampDesc, D3D12_SHADER_VISIBILITY_ALL);

        probeUpdateRS.Finalize(L"DDGI Compute Root Signature");

        probeUpdatePSO.SetRootSignature(probeUpdateRS);
        probeUpdatePSO.SetComputeShader(g_pSDFGIProbeUpdateCS, sizeof(g_pSDFGIProbeUpdateCS));
        probeUpdatePSO.Finalize();
    }


    void SDFGIManager::UpdateProbes(GraphicsContext& context) {
        // Only capture irradiance and depth once.
        if (irradianceCaptured) return;

        ComputeContext& computeContext = context.GetComputeContext();

        ScopedTimer _prof(L"Capture Irradiance and Depth", context);

        computeContext.SetPipelineState(probeUpdatePSO);
        computeContext.SetRootSignature(probeUpdateRS);

        computeContext.SetBufferSRV(0, probeBuffer);
        computeContext.SetDynamicDescriptor(1, 0, irradianceAtlasUAV);
        computeContext.SetDynamicDescriptor(2, 0, depthAtlasUAV);

        computeContext.SetDynamicDescriptor(3, 0, probeCubemapFaceTextures[32][0].GetSRV());
        computeContext.SetDynamicDescriptor(3, 1, probeCubemapFaceTextures[32][1].GetSRV());
        computeContext.SetDynamicDescriptor(3, 2, probeCubemapFaceTextures[32][2].GetSRV());
        computeContext.SetDynamicDescriptor(3, 3, probeCubemapFaceTextures[32][3].GetSRV());
        computeContext.SetDynamicDescriptor(3, 4, probeCubemapFaceTextures[32][4].GetSRV());
        computeContext.SetDynamicDescriptor(3, 5, probeCubemapFaceTextures[32][5].GetSRV());

        computeContext.SetDynamicDescriptor(4, 0, probeCubemapFaceArraySRV);

        computeContext.TransitionResource(irradianceAtlas, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        computeContext.TransitionResource(depthAtlas, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

        struct ProbeData {
            XMFLOAT4X4 randomRotation;
            unsigned int ProbeCount;
            float ProbeMaxDistance;
            Vector3 GridSize;
            Vector3 ProbeSpacing;
            Vector3 SceneMinBounds;
            int ProbeIndex;
        } probeData;

        float rotation_scaler = 3.14159f / 7.0f;
        XMMATRIX randomRotation = GenerateRandomRotationMatrix(rotation_scaler);
        XMStoreFloat4x4(&probeData.randomRotation, randomRotation);

        probeData.ProbeCount = probeGrid.probes.size();
        probeData.ProbeMaxDistance = 50;
        probeData.GridSize = Vector3(probeGrid.probeCount[0], probeGrid.probeCount[1], probeGrid.probeCount[2]);
        probeData.ProbeSpacing = Vector3(probeGrid.probeSpacing[0], probeGrid.probeSpacing[1], probeGrid.probeSpacing[2]);
        probeData.SceneMinBounds = sceneBounds.GetMin();

        computeContext.SetDynamicConstantBufferView(5, sizeof(probeData), &probeData);

        // One thread per probe.
        computeContext.Dispatch(probeGrid.probeCount[0], probeGrid.probeCount[1], probeGrid.probeCount[2]);

        computeContext.TransitionResource(irradianceAtlas, D3D12_RESOURCE_STATE_GENERIC_READ);
        computeContext.TransitionResource(depthAtlas, D3D12_RESOURCE_STATE_GENERIC_READ);

        irradianceCaptured = true;
    }
    
    void SDFGIManager::InitializeProbeAtlasVizShader() {
        atlasVizRS.Reset(2, 1);
        // Irradiance atlas.
        atlasVizRS[0].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 2, 1, D3D12_SHADER_VISIBILITY_PIXEL);
        // Depth atlas.
        atlasVizRS[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 3, 1, D3D12_SHADER_VISIBILITY_PIXEL);
        atlasVizRS.InitStaticSampler(0, SamplerLinearClampDesc);
        atlasVizRS.Finalize(L"SDFGI Visualization Root Signature", D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT);

        atlasVizPSO.SetRootSignature(atlasVizRS);
        atlasVizPSO.SetVertexShader(g_pSDFGIProbeIrradianceDepthVizVS, sizeof(g_pSDFGIProbeIrradianceDepthVizVS));
        atlasVizPSO.SetPixelShader(g_pSDFGIProbeIrradianceDepthVizPS, sizeof(g_pSDFGIProbeIrradianceDepthVizPS));
        atlasVizPSO.SetRasterizerState(RasterizerDefault);
        atlasVizPSO.SetBlendState(BlendDisable);
        atlasVizPSO.SetDepthStencilState(DepthStateReadWrite);
        atlasVizPSO.SetPrimitiveTopologyType(D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE);
        atlasVizPSO.SetRenderTargetFormat(g_SceneColorBuffer.GetFormat(), g_SceneDepthBuffer.GetFormat());
        atlasVizPSO.Finalize();
    }

    void SDFGIManager::RenderProbeAtlasViz(GraphicsContext& context, const Math::Camera& camera) {
        ScopedTimer _prof(L"Visualize SDFGI Textures", context);

        context.SetPipelineState(atlasVizPSO);
        context.SetRootSignature(atlasVizRS);

        context.SetDynamicDescriptor(0, 0, irradianceAtlas.GetSRV());
        context.SetDynamicDescriptor(1, 0, depthAtlas.GetSRV());

        context.SetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        context.Draw(4);
    }

    void SDFGIManager::InitializeDownsampleShader() {
        downsampleRS.Reset(3, 1);
        
        downsampleRS[0].InitAsConstantBuffer(0);
        
        // Source texture, typically g_SceneColorBuffer.
        downsampleRS[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 0, 1);
        
        // Destination texture, some probe's cubemap face.
        downsampleRS[2].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 0, 1);
        
        downsampleRS.InitStaticSampler(0, SamplerBilinearClampDesc);
        
        downsampleRS.Finalize(L"Downsample Root Signature", D3D12_ROOT_SIGNATURE_FLAG_NONE);

        downsamplePSO.SetRootSignature(downsampleRS);
        downsamplePSO.SetComputeShader(g_pSDFGIProbeCubemapDownsampleCS, sizeof(g_pSDFGIProbeCubemapDownsampleCS)); 
        downsamplePSO.Finalize();
    }

    void SDFGIManager::RenderCubemapFace(
        GraphicsContext& context, DepthBuffer& depthBuffer, int probe, int face, const Math::Camera& faceCamera, Vector3 &probePosition, const D3D12_VIEWPORT& mainViewport, const D3D12_RECT& mainScissor
    ) {
        // Render to g_SceneColorBuffer (the main render target) using the given cubemap face camera.
        renderFunc(context, faceCamera, mainViewport, mainScissor);

        // Now copy and downsample g_SceneColorBuffer into probeCubemapFaceTextures (which are square, typically 64x64).
        // Why not render the scene directly to probeCubemapFaceTextures? It was hard to make renderFunc invoke the scene
        // rendering function with an arbitrary render target (i.e. other than g_SceneColorBuffer).

        ComputeContext& computeContext = context.GetComputeContext();

        computeContext.TransitionResource(g_SceneColorBuffer, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, true);
        computeContext.TransitionResource(probeCubemapFaceTextures[probe][face], D3D12_RESOURCE_STATE_UNORDERED_ACCESS, true);

        DownsampleCB downsampleCB;
        downsampleCB.srcSize = Vector3(g_SceneColorBuffer.GetWidth(), g_SceneColorBuffer.GetHeight(), 0.0f);
        downsampleCB.dstSize = Vector3(probeCubemapFaceTextures[probe][face].GetWidth(), probeCubemapFaceTextures[probe][face].GetHeight(), 0.0f);
        downsampleCB.scale = Vector3(
            downsampleCB.srcSize.GetX() / downsampleCB.dstSize.GetX(),
            downsampleCB.srcSize.GetY() / downsampleCB.dstSize.GetY(), 0.0f
        );

        computeContext.SetRootSignature(downsampleRS);
        computeContext.SetPipelineState(downsamplePSO);
        computeContext.SetDynamicDescriptor(1, 0, g_SceneColorBuffer.GetSRV()); 
        computeContext.SetDynamicDescriptor(2, 0, probeCubemapFaceUAVs[probe][face]);
        computeContext.SetDynamicConstantBufferView(0, sizeof(downsampleCB), &downsampleCB);
        
        uint32_t dispatchX = (uint32_t)ceil(downsampleCB.dstSize.GetX() / 8.0f);
        uint32_t dispatchY = (uint32_t)ceil(downsampleCB.dstSize.GetY() / 8.0f);
        computeContext.Dispatch(dispatchX, dispatchY, 1);

        computeContext.TransitionResource(g_SceneColorBuffer, D3D12_RESOURCE_STATE_RENDER_TARGET, true);
        computeContext.TransitionResource(probeCubemapFaceTextures[probe][face], D3D12_RESOURCE_STATE_COPY_SOURCE, true);
    }

    void SDFGIManager::RenderCubemapsForProbes(GraphicsContext& context, const Math::Camera& camera, const D3D12_VIEWPORT& mainViewport, const D3D12_RECT& mainScissor) {
        // Only render the cubemaps once.
        if (cubeMapsRendered) return;

        std::array<Camera, 6> cubemapCameras;

        Vector3 lookDirections[6] = {
            Vector3(1.0f, 0.0f, 0.0f), 
            Vector3(-1.0f, 0.0f, 0.0f),
            Vector3(0.0f, 1.0f, 0.0f), 
            Vector3(0.0f, -1.0f, 0.0f),
            Vector3(0.0f, 0.0f, 1.0f), 
            Vector3(0.0f, 0.0f, -1.0f) 
        };

        Vector3 upVectors[6] = {
            Vector3(0.0f, 1.0f, 0.0f), 
            Vector3(0.0f, 1.0f, 0.0f), 
            Vector3(0.0f, 0.0f, -1.0f),
            Vector3(0.0f, 0.0f, 1.0f), 
            Vector3(0.0f, 1.0f, 0.0f), 
            Vector3(0.0f, -1.0f, 0.0f) 
        };

        // Render 6 views of the scene for each probe to probeCubemapFaceTextures.
        for (size_t probe = 0; probe < probeGrid.probes.size(); ++probe) {
            Vector3& probePosition = probeGrid.probes[probe].position;

            for (int face = 0; face < 6; ++face)
            {
                Camera faceCamera;
                faceCamera.SetPosition(probePosition);
                faceCamera.SetLookDirection(lookDirections[face], upVectors[face]);
                faceCamera.SetPerspectiveMatrix(XM_PI / 2.0f, 1.0f, camera.GetNearClip(), camera.GetFarClip());
                faceCamera.ReverseZ(camera.GetReverseZ());
                faceCamera.Update();

                RenderCubemapFace(context, g_SceneDepthBuffer, probe, face, faceCamera, probePosition, mainViewport, mainScissor);
            }
        }

        // Copy each of the textures in probeCubemapFaceTextures to a texture array.
        // TODO: can we render directly to the texture array?
        // TODO: the shader seems to see the same texture at every index in the array.
        // TODO: look into ColorBuffer::CreateArray.
        for (int probe = 0; probe < probeCount; ++probe) {
            for (int face = 0; face < 6; ++face) {
                D3D12_TEXTURE_COPY_LOCATION srcLocation = {};
                srcLocation.pResource = probeCubemapFaceTextures[probe][face].GetResource();
                srcLocation.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
                srcLocation.SubresourceIndex = 0;

                D3D12_TEXTURE_COPY_LOCATION dstLocation = {};
                dstLocation.pResource = probeCubemapFaceArrayGpuResource->GetResource();
                dstLocation.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
                dstLocation.SubresourceIndex = probe * 6 + face;

                D3D12_BOX srcBox = { 0, 0, 0, cubemapFaceResolution, cubemapFaceResolution, 1 };
                context.GetCommandList()->CopyTextureRegion(&dstLocation, 0, 0, 0, &srcLocation, &srcBox);
            }
        }

        context.TransitionResource(*probeCubemapFaceArrayGpuResource, D3D12_RESOURCE_STATE_GENERIC_READ);

        cubeMapsRendered = true;
    }

    // This shader renders the 6 faces of the cubemap of a single probe to a fullscreen quad. See RenderCubemapViz.
    void SDFGIManager::InitializeCubemapVizShader() {
        cubemapVizRS.Reset(2, 1);

        cubemapVizRS[0].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 0, 6, D3D12_SHADER_VISIBILITY_PIXEL);
        cubemapVizRS[1].InitAsConstantBuffer(0, D3D12_SHADER_VISIBILITY_PIXEL);
        cubemapVizRS.InitStaticSampler(0, SamplerLinearClampDesc);
        cubemapVizRS.Finalize(L"Cubemap Visualization Root Signature");

        cubemapVizPSO.SetRootSignature(cubemapVizRS);
        cubemapVizPSO.SetVertexShader(g_pSDFGIProbeCubemapVizVS, sizeof(g_pSDFGIProbeCubemapVizVS));
        cubemapVizPSO.SetPixelShader(g_pSDFGIProbeCubemapVizPS, sizeof(g_pSDFGIProbeCubemapVizPS));
        cubemapVizPSO.SetRasterizerState(RasterizerDefault);
        cubemapVizPSO.SetBlendState(BlendDisable);
        cubemapVizPSO.SetDepthStencilState(DepthStateReadWrite);
        cubemapVizPSO.SetPrimitiveTopologyType(D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE);
        cubemapVizPSO.SetRenderTargetFormat(g_SceneColorBuffer.GetFormat(), g_SceneDepthBuffer.GetFormat());
        cubemapVizPSO.Finalize();
    }

    // Renders the 6 faces of the cubemap of a single probe to a fullscreen quad.
    void SDFGIManager::RenderCubemapViz(GraphicsContext& context, const Math::Camera& camera) {
        ScopedTimer _prof(L"Visualize Cubemap Faces", context);

        context.SetPipelineState(cubemapVizPSO);
        context.SetRootSignature(cubemapVizRS);

        for (int face = 0; face < 6; ++face) {
            context.SetDynamicDescriptor(0, face, probeCubemapFaceTextures[PROBE_IDX_VIZ][face].GetSRV());
        }

        int GridColumns = 3;
        int GridRows = 2;
        float CellSize = 1.0f / std::max(GridColumns, GridRows);

        __declspec(align(16)) struct FaceGridConfig {
            int GridColumns;
            int GridRows;
            float CellSize;
            float pad;
        } config = { GridColumns, GridRows, CellSize, 0.0f };
        context.SetDynamicConstantBufferView(1, sizeof(config), &config);

        context.SetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        context.Draw(4);
    }

    void SDFGIManager::Render(GraphicsContext& context, const Math::Camera& camera, const D3D12_VIEWPORT& viewport, const D3D12_RECT& scissor) {
        ScopedTimer _prof(L"SDFGI Rendering", context);

        RenderCubemapsForProbes(context, camera, viewport, scissor);

        UpdateProbes(context);

        RenderProbeViz(context, camera);

        // Render to a fullscreen quad either the probe atlas or the cubemap of a single probe.
        //RenderProbeAtlasViz(context, camera);
        RenderCubemapViz(context, camera);
    }
}