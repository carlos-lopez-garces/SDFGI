//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
// Developed by Minigraph
//
// Author:  James Stanard
//

#include "GameCore.h"
#include "CameraController.h"
#include "BufferManager.h"
#include "Camera.h"
#include "VoxelCamera.h"
#include "CommandContext.h"
#include "TemporalEffects.h"
#include "MotionBlur.h"
#include "DepthOfField.h"
#include "PostEffects.h"
#include "SSAO.h"
#include "FXAA.h"
#include "SystemTime.h"
#include "TextRenderer.h"
#include "ParticleEffectManager.h"
#include "GameInput.h"
#include "SponzaRenderer.h"
#include "glTF.h"
#include "Renderer.h"
#include "Model.h"
#include "ModelLoader.h"
#include "ShadowCamera.h"
#include "Display.h"
#include "imgui.h"
#include "imgui_impl_win32.h"
#include "imgui_impl_dx12.h"
#include "SDFGI.h"
#include "Settings.h"

#define RENDER_DIRECT_ONLY 0
//0- sponza, 1- sonic, 2- sphere 3- Breakfast Room, 4- Japanese Street, 5- San Miguel, 6- SponzaAnimated
#define SCENE 0
// #define LEGACY_RENDERER
#include <string>


using namespace GameCore;
using namespace Math;
using namespace Graphics;
using namespace std;

using Renderer::MeshSorter;
using namespace SampleFramework12;

namespace GameCore
{
    extern HWND g_hWnd;
}

namespace Graphics
{
    extern ID3D12Device* g_Device;
}

class ModelViewer : public GameCore::IGameApp
{
public:

    ModelViewer( void ) {}

    virtual void Startup( void ) override;
    virtual void Cleanup( void ) override;

    virtual void Update( float deltaT ) override;
    virtual void RenderScene( void ) override;
    

    virtual void RenderUI( class GraphicsContext& ) override;

    void InitializeGUI();

    GlobalConstants ModelViewer::UpdateGlobalConstants(const Math::BaseCamera& cam, bool renderShadows);
    void NonLegacyRenderSDF(GraphicsContext& gfxContext, bool runOnce);
    void RayMarcherDebug(GraphicsContext& gfxContext, const Math::Camera& cam, const D3D12_VIEWPORT& viewport, const D3D12_RECT& scissor);
    void NonLegacyRenderShadowMap(GraphicsContext& gfxContext, const Math::Camera& cam, const D3D12_VIEWPORT& viewport, const D3D12_RECT& scissor);
    void NonLegacyRenderScene(GraphicsContext& gfxContext, const Math::Camera& cam, const D3D12_VIEWPORT& viewport, const D3D12_RECT& scissor, bool renderShadows = true, bool useSDFGI = false);

    DirectionSetting SunDirection;
private:

    Camera m_Camera;
    unique_ptr<CameraController> m_CameraController;

    D3D12_VIEWPORT m_MainViewport;
    D3D12_RECT m_MainScissor;

    ModelInstance m_ModelInst;
    ShadowCamera m_SunShadowCamera;

    SDFGI::SDFGIManager *mp_SDFGIManager;
    bool rayMarchDebug = false;
    bool showDIPlusGI = true;
    bool showDIOnly = false;
    bool showGIOnly = false;
    float giIntensity = 1.0f;
    bool showIrradianceAtlas = false;
    bool showVisibilityAtlas = false;
    bool runSDFOnce = true;
};

CREATE_APPLICATION( ModelViewer )

ExpVar g_SunLightIntensity("Viewer/Lighting/Sun Light Intensity", 0.f, 0.0f, 16.0f, 0.1f);
// For sphere scene.
// NumVar g_SunOrientation("Viewer/Lighting/Sun Orientation", -1.5f, -100.0f, 100.0f, 0.1f );
// For Sonic scene.
// NumVar g_SunOrientation("Viewer/Lighting/Sun Orientation", -0.0f, -100.0f, 100.0f, 0.1f );
// NumVar g_SunInclination("Viewer/Lighting/Sun Inclination", 0.0f, 0.0f, 1.0f, 0.01f );
// See SunDirection.Initialize in Startup for settting initial sun direction.

void ChangeIBLSet(EngineVar::ActionType);
void ChangeIBLBias(EngineVar::ActionType);

DynamicEnumVar g_IBLSet("Viewer/Lighting/Environment", ChangeIBLSet);
std::vector<std::pair<TextureRef, TextureRef>> g_IBLTextures;
NumVar g_IBLBias("Viewer/Lighting/Gloss Reduction", 2.0f, 0.0f, 10.0f, 1.0f, ChangeIBLBias);

void ChangeIBLSet(EngineVar::ActionType)
{
    int setIdx = g_IBLSet - 1;
    if (setIdx < 0)
    {
        Renderer::SetIBLTextures(nullptr, nullptr);
    }
    else
    {
        auto texturePair = g_IBLTextures[setIdx];
        Renderer::SetIBLTextures(texturePair.first, texturePair.second);
    }
}

void ChangeIBLBias(EngineVar::ActionType)
{
    Renderer::SetIBLBias(g_IBLBias);
}

#include <direct.h> // for _getcwd() to check data root path

void LoadIBLTextures()
{
    char CWD[256];
    _getcwd(CWD, 256);

    Utility::Printf("Loading IBL environment maps\n");

    WIN32_FIND_DATA ffd;
    HANDLE hFind = FindFirstFile(L"Textures/*_diffuseIBL.dds", &ffd);

    g_IBLSet.AddEnum(L"None");

    if (hFind != INVALID_HANDLE_VALUE) do
    {
        if (ffd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
            continue;

       std::wstring diffuseFile = ffd.cFileName;
       std::wstring baseFile = diffuseFile; 
       baseFile.resize(baseFile.rfind(L"_diffuseIBL.dds"));
       std::wstring specularFile = baseFile + L"_specularIBL.dds";

       TextureRef diffuseTex = TextureManager::LoadDDSFromFile(L"Textures/" + diffuseFile);
       if (diffuseTex.IsValid())
       {
           TextureRef specularTex = TextureManager::LoadDDSFromFile(L"Textures/" + specularFile);
           if (specularTex.IsValid())
           {
               g_IBLSet.AddEnum(baseFile);
               g_IBLTextures.push_back(std::make_pair(diffuseTex, specularTex));
           }
       }
    }
    while (FindNextFile(hFind, &ffd) != 0);

    FindClose(hFind);

    Utility::Printf("Found %u IBL environment map sets\n", g_IBLTextures.size());

    if (g_IBLTextures.size() > 0)
        g_IBLSet.Increment();
}

void ModelViewer::Startup( void )
{
    MotionBlur::Enable = false;
    TemporalEffects::EnableTAA = false;
    FXAA::Enable = false;
    PostEffects::EnableHDR = false;
    PostEffects::EnableAdaptation = false;
    SSAO::Enable = false;

    Renderer::Initialize();

    LoadIBLTextures();

    std::wstring gltfFileName;

    float scaleModel = 1.0f;

    bool forceRebuild = false;
    uint32_t rebuildValue;
    if (CommandLineArgs::GetInteger(L"rebuild", rebuildValue))
        forceRebuild = rebuildValue != 0;

    if (CommandLineArgs::GetString(L"model", gltfFileName) == false)
    {
#ifdef LEGACY_RENDERER
        Sponza::Startup(m_Camera);
#else
        scaleModel = 100.0f;
#if SCENE == 0
        m_ModelInst = Renderer::LoadModel(L"Sponza/PBR/sponza2.gltf", forceRebuild);
#elif SCENE == 1
        //m_ModelInst = Renderer::LoadModel(L"Models/CornellWithSonicThickWalls/CornellWithSonicThickWalls.gltf", forceRebuild);
        m_ModelInst = Renderer::LoadModel(L"Models/SonicNew/SonicNew.gltf", forceRebuild);
#elif SCENE == 2
        m_ModelInst = Renderer::LoadModel(L"Models/CornellSphere/CornellSphere.gltf", forceRebuild);
#elif SCENE == 3
        m_ModelInst = Renderer::LoadModel(L"Models/BreakfastRoom/BreakfastRoom.gltf", forceRebuild); 
#elif SCENE == 4
        m_ModelInst = Renderer::LoadModel(L"Models/JapaneseStreet/JapaneseStreet.gltf", forceRebuild);
#elif SCENE == 5
        m_ModelInst = Renderer::LoadModel(L"Models/SanMiguel/SanMiguel.gltf", forceRebuild);
#elif SCENE == 6
        m_ModelInst = Renderer::LoadModel(L"Models/SponzaAnimated/SponzaAnimated.gltf", forceRebuild);
#endif
        // 
        // m_ModelInst = Renderer::LoadModel(L"Models/BoxAndPlane/BoxAndPlane.gltf", forceRebuild);
         
        // m_ModelInst = Renderer::LoadModel(L"Models/CubemapTest/CubemapTest.gltf", forceRebuild);
        // m_ModelInst = Renderer::LoadModel(L"Models/2PlaneBall/2PlaneBall.gltf", forceRebuild);
         //
        m_ModelInst.Resize(scaleModel * m_ModelInst.GetRadius());
        OrientedBox obb = m_ModelInst.GetBoundingBox();
        float modelRadius = Length(obb.GetDimensions()) * 0.5f;
        const Vector3 eye = obb.GetCenter() + Vector3(modelRadius * 0.5f, 0.0f, 0.0f);
        m_Camera.SetEyeAtUp( eye, Vector3(kZero), Vector3(kYUnitVector) );
#endif
    }
    else
    {
        scaleModel = 10.0f;
        m_ModelInst = Renderer::LoadModel(gltfFileName, forceRebuild);
        m_ModelInst.LoopAllAnimations();
        m_ModelInst.Resize(scaleModel* m_ModelInst.GetRadius());

        MotionBlur::Enable = false;
    }

    m_Camera.SetZRange(1.0f, 10000.0f);
    if (gltfFileName.size() == 0)
        m_CameraController.reset(new FlyingFPSCamera(m_Camera, Vector3(kYUnitVector)));
    else
        m_CameraController.reset(new OrbitCamera(m_Camera, m_ModelInst.GetBoundingSphere(), Vector3(kYUnitVector)));

    // For Sonic scene.
#if SCENE == 0
    SunDirection.Initialize("SunDirection", "Sun", "Sun Direction", "Direction of the sun", Float3(-0.289f, 0.904f, 0.314f), true);
#elif SCENE == 1
    SunDirection.Initialize("SunDirection", "Sun", "Sun Direction", "Direction of the sun", Float3(0.95f, 0.19f, -0.24f), true);
#elif SCENE == 2
    SunDirection.Initialize("SunDirection", "Sun", "Sun Direction", "Direction of the sun", Float3(0.235f, 0.217f, -0.948f), true);
#elif SCENE == 3
    SunDirection.Initialize("SunDirection", "Sun", "Sun Direction", "Direction of the sun", Float3(0.235f, 0.217f, -0.948f), true);
#elif SCENE == 6
    SunDirection.Initialize("SunDirection", "Sun", "Sun Direction", "Direction of the sun", Float3(-0.289f, 0.904f, 0.213f), true);
#else
    SunDirection.Initialize("SunDirection", "Sun", "Sun Direction", "Direction of the sun", Float3(0.235f, 0.217f, -0.948f), true);
#endif
     
    // For Sponza scene.
    //
    // For Cornell scene
    //
#if UI_ENABLE
    InitializeGUI();
#endif

    #ifdef LEGACY_RENDERER
    const Math::AxisAlignedBox &sceneBounds = Sponza::GetBoundingBox();
    #else
    // Scale the AABB to match the scaling applied by m_ModelInst.Resize(..)
    Math::AxisAlignedBox& test = m_ModelInst.GetAxisAlignedBox();
    Math::AxisAlignedBox& sceneBounds = Math::AxisAlignedBox();
    sceneBounds.AddPoint(scaleModel * Vector3(test.GetMin()));
    sceneBounds.AddPoint(scaleModel * Vector3(test.GetMax()));
    #endif

    auto renderLambda = [&](GraphicsContext& ctx, const Math::Camera& cam, const D3D12_VIEWPORT& vp, const D3D12_RECT& sc) {
#ifdef LEGACY_RENDERER
        Sponza::RenderScene(ctx, cam, vp, sc, /*skipDiffusePass=*/false, /*skipShadowMap=*/false);
#else
        ModelViewer::NonLegacyRenderScene(ctx, cam, vp, sc);
#endif
    };

    mp_SDFGIManager = new SDFGI::SDFGIManager(
        sceneBounds,
        static_cast<std::function<void(GraphicsContext&, const Math::Camera&, const D3D12_VIEWPORT&, const D3D12_RECT&)>>(renderLambda),
        &Renderer::s_TextureHeap,
        /*useCubemaps=*/false
    );
}

void ModelViewer::InitializeGUI() {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad;

    // ImGUI needs a descriptor handle for it's fonts
    DescriptorHandle guiFontHeap = Renderer::s_TextureHeap.Alloc(1); 

    ImGui_ImplWin32_Init(GameCore::g_hWnd);
    ImGui_ImplDX12_Init(
        Graphics::g_Device,
        // Number of frames in flight.
        3,
        Graphics::g_OverlayBuffer.GetFormat(), 
        // imgui needs SRV descriptors for its font textures.
        Renderer::s_TextureHeap.GetHeapPointer(),
        D3D12_CPU_DESCRIPTOR_HANDLE(guiFontHeap),
        D3D12_GPU_DESCRIPTOR_HANDLE(guiFontHeap)
    );
}

void ModelViewer::Cleanup( void )
{
    m_ModelInst = nullptr;

    g_IBLTextures.clear();

    delete mp_SDFGIManager;

#ifdef LEGACY_RENDERER
    Sponza::Cleanup();
#endif
    Renderer::Shutdown();
#if UI_ENABLE
    ImGui_ImplDX12_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
#endif
}

namespace Graphics
{
    extern EnumVar DebugZoom;
}

void ModelViewer::Update( float deltaT )
{
    ScopedTimer _prof(L"Update State");

    if (GameInput::IsFirstPressed(GameInput::kLShoulder))
        DebugZoom.Decrement();
    else if (GameInput::IsFirstPressed(GameInput::kRShoulder))
        DebugZoom.Increment();

#if UI_ENABLE
    ImGuiIO& io = ImGui::GetIO();
    if (!io.WantCaptureMouse) {
        // Update camera only if imgui captures the mouse
        m_CameraController->Update(deltaT);
    }
#else 
    m_CameraController->Update(deltaT);
#endif

    GraphicsContext& gfxContext = GraphicsContext::Begin(L"Scene Update");

    m_ModelInst.Update(gfxContext, deltaT);

    gfxContext.Finish();

    // We use viewport offsets to jitter sample positions from frame to frame (for TAA.)
    // D3D has a design quirk with fractional offsets such that the implicit scissor
    // region of a viewport is floor(TopLeftXY) and floor(TopLeftXY + WidthHeight), so
    // having a negative fractional top left, e.g. (-0.25, -0.25) would also shift the
    // BottomRight corner up by a whole integer.  One solution is to pad your viewport
    // dimensions with an extra pixel.  My solution is to only use positive fractional offsets,
    // but that means that the average sample position is +0.5, which I use when I disable
    // temporal AA.
    TemporalEffects::GetJitterOffset(m_MainViewport.TopLeftX, m_MainViewport.TopLeftY);

    m_MainViewport.Width = (float)g_SceneColorBuffer.GetWidth();
    m_MainViewport.Height = (float)g_SceneColorBuffer.GetHeight();
    m_MainViewport.MinDepth = 0.0f;
    m_MainViewport.MaxDepth = 1.0f;

    m_MainScissor.left = 0;
    m_MainScissor.top = 0;
    m_MainScissor.right = (LONG)g_SceneColorBuffer.GetWidth();
    m_MainScissor.bottom = (LONG)g_SceneColorBuffer.GetHeight();
}

GlobalConstants ModelViewer::UpdateGlobalConstants(const Math::BaseCamera& cam, bool renderShadows)
{
    GlobalConstants globals;
    globals.ViewProjMatrix = cam.GetViewProjMatrix();
    globals.CameraPos = cam.GetPosition();
    globals.SunIntensity = Vector3(Scalar(g_SunLightIntensity));

    // Handle shadow-related global constants
    {
        Float3 dirInCartesian = SunDirection.Value();
        Vector3 SunDirection = Normalize(Vector3(dirInCartesian.x, dirInCartesian.y, dirInCartesian.z));
        Vector3 ShadowBounds = Vector3(m_ModelInst.GetRadius());
        Vector3 origin = Vector3(0);
        Vector3 ShadowCenter = origin;

        OrientedBox obb = m_ModelInst.GetBoundingBox();
        float x = obb.GetDimensions().GetX();
        float y = obb.GetDimensions().GetY();
        float z = obb.GetDimensions().GetZ();

        // Debug spam >:( -- Mikey

        /*  
        Utility::Print("Obb: ");
        Utility::Print(std::to_string(obb.GetDimensions().GetX()).c_str());
        Utility::Print(", ");
        Utility::Print(std::to_string(obb.GetDimensions().GetY()).c_str());
        Utility::Print(", ");
        Utility::Print(std::to_string(obb.GetDimensions().GetZ()).c_str());
        Utility::Print("\n");
        */

        //We should evaluate the correct center position based on the camera angle!
        //This is similar to your 3D Pixel art project!
        float maxLength = Length(obb.GetDimensions());
        //m_SunShadowCamera.UpdateMatrixImproved(-SunDirection, Vector3(0, 0, 0), Vector4(maxLength, maxLength, -maxLength, maxLength),
        //    (uint32_t)g_ShadowBuffer.GetWidth(), (uint32_t)g_ShadowBuffer.GetHeight(), 16);

        m_SunShadowCamera.UpdateMatrixImproved(-SunDirection, obb.GetCenter(), Vector3(maxLength, maxLength, maxLength),
            (uint32_t)g_ShadowBuffer.GetWidth(), (uint32_t)g_ShadowBuffer.GetHeight(), 16);

        // Update sun/shadow global constants
        globals.SunShadowMatrix = m_SunShadowCamera.GetShadowMatrix();
        globals.SunDirection = SunDirection;
    }

    return globals;
}

void ModelViewer::NonLegacyRenderShadowMap(GraphicsContext& gfxContext, const Math::Camera& cam, const D3D12_VIEWPORT& viewport, const D3D12_RECT& scissor)
{
    GlobalConstants globals = UpdateGlobalConstants(cam, true);
    ScopedTimer _prof(L"Sun Shadow Map", gfxContext);

    MeshSorter shadowSorter(MeshSorter::kShadows);
    shadowSorter.SetCamera(m_SunShadowCamera);
    shadowSorter.SetDepthStencilTarget(g_ShadowBuffer);

    m_ModelInst.Render(shadowSorter);

    shadowSorter.Sort();
    shadowSorter.RenderMeshes(MeshSorter::kZPass, gfxContext, globals);
}

// Generates the Voxel and SDF 3D Textures from the scene. If sdfRunOnce
// is true, then the SDF texture will only update once, at the beginning of the app. 
// Voxelization will continue to update every frame. 
void ModelViewer::NonLegacyRenderSDF(GraphicsContext& gfxContext, bool sdfRunOnce) {
    VoxelCamera cam; 
    SDFGIGlobalConstants SDFGIglobals{};
    D3D12_VIEWPORT voxelViewport{};
    D3D12_RECT voxelScissor{};

    {
        float width = 512.f;
        float height = 512.f;
        voxelViewport.Width = width;
        voxelViewport.Height = height;
        voxelViewport.MinDepth = 0.0f;
        voxelViewport.MaxDepth = 1.0f;

        voxelScissor.left = 0;
        voxelScissor.top = 0;
        voxelScissor.right = width;
        voxelScissor.bottom = height;

        SDFGIglobals.viewWidth = width;
        SDFGIglobals.viewHeight = height;
        SDFGIglobals.voxelTextureResolution = SDF_TEXTURE_RESOLUTION;
        SDFGIglobals.voxelPass = 1;
    }

    Renderer::ClearVoxelTextures(gfxContext);

    for (int i = 0; i < 3; ++i) {
        cam.UpdateMatrix(i); 
        GlobalConstants globals = UpdateGlobalConstants(cam, true);

        MeshSorter sorter(MeshSorter::kDefault);
        sorter.SetCamera(cam);
        sorter.SetViewport(voxelViewport);
        sorter.SetScissor(voxelScissor);
        sorter.SetDepthStencilTarget(g_SceneDepthBuffer);
        sorter.AddRenderTarget(g_SceneColorBuffer);

        // Begin rendering depth
        gfxContext.TransitionResource(g_SceneDepthBuffer, D3D12_RESOURCE_STATE_DEPTH_WRITE, true);
        gfxContext.ClearDepth(g_SceneDepthBuffer);

        m_ModelInst.Render(sorter);

        sorter.Sort();

        MeshSorter sorterInstance = sorter;

        {
            ScopedTimer _prof(L"Depth Pre-Pass", gfxContext);
            sorter.RenderMeshes(MeshSorter::kZPass, gfxContext, globals);
        }

        SSAO::Render(gfxContext, m_Camera);

        gfxContext.TransitionResource(g_SceneColorBuffer, D3D12_RESOURCE_STATE_RENDER_TARGET, true);
        gfxContext.ClearColor(g_SceneColorBuffer);

        {
            ScopedTimer _prof(i == 0 ? L"Render Voxel X" : i == 1 ? L"Render Voxel Y" : L"Render Voxel Z", gfxContext);

            gfxContext.TransitionResource(g_SSAOFullScreen, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gfxContext.TransitionResource(g_SceneDepthBuffer, D3D12_RESOURCE_STATE_DEPTH_READ);
            gfxContext.SetRenderTarget(g_SceneColorBuffer.GetRTV());

            SDFGIglobals.axis = i;

            sorter.RenderVoxels(MeshSorter::kOpaque, gfxContext, globals, SDFGIglobals);
        }
    }

    bool static run = true; 

    // if runOnce is false, SDF generation runs every time
    if (run || !sdfRunOnce)
    {
        Renderer::ClearSDFTextures(gfxContext); 
        ComputeContext& context = gfxContext.GetComputeContext();
        {
            ScopedTimer _prof(L"SDF Jump Flood Compute", context);
            Renderer::ComputeSDF(context);
        }
        run = false; 
    }

    return; 
}

void ModelViewer::RayMarcherDebug(GraphicsContext& gfxContext, const Math::Camera& cam, const D3D12_VIEWPORT& viewport, const D3D12_RECT& scissor)
{
    MeshSorter sorter(MeshSorter::kDefault);
    sorter.SetCamera(cam);
    sorter.SetViewport(viewport);
    sorter.SetScissor(scissor);
    sorter.SetDepthStencilTarget(g_SceneDepthBuffer);
    sorter.AddRenderTarget(g_SceneColorBuffer);

    // Begin rendering depth
    gfxContext.TransitionResource(g_SceneDepthBuffer, D3D12_RESOURCE_STATE_DEPTH_WRITE, true);
    gfxContext.ClearDepth(g_SceneDepthBuffer);

    m_ModelInst.Render(sorter);

    sorter.Sort();

    MeshSorter sorterInstance = sorter;

    {
        ScopedTimer _prof(L"Depth Pre-Pass", gfxContext);
        sorter.RenderMeshes(MeshSorter::kZPass, gfxContext, UpdateGlobalConstants(cam, false));
    }

    gfxContext.TransitionResource(g_SceneColorBuffer, D3D12_RESOURCE_STATE_RENDER_TARGET, true);
    gfxContext.ClearColor(g_SceneColorBuffer);

    {
        ScopedTimer _prof(L"Ray March Debug", gfxContext);
        Renderer::RayMarchSDF(gfxContext, cam, viewport, scissor);
    }
}

void ModelViewer::NonLegacyRenderScene(GraphicsContext& gfxContext, const Math::Camera& cam, 
    const D3D12_VIEWPORT& viewport, const D3D12_RECT& scissor, bool renderShadows, bool useSDFGI)
{
    GlobalConstants globals = UpdateGlobalConstants(cam, false);
    // Begin rendering depth
    gfxContext.TransitionResource(g_SceneDepthBuffer, D3D12_RESOURCE_STATE_DEPTH_WRITE, true);
    gfxContext.ClearDepth(g_SceneDepthBuffer);

    MeshSorter mainSorter(MeshSorter::kDefault);
    mainSorter.SetCamera(cam);
    mainSorter.SetViewport(viewport);
    mainSorter.SetScissor(scissor);
    mainSorter.SetDepthStencilTarget(g_SceneDepthBuffer);
    mainSorter.AddRenderTarget(g_SceneColorBuffer);

    m_ModelInst.Render(mainSorter);

    mainSorter.Sort();

#if ENABLE_DEPTH_PREPASS == 1
    {
        ScopedTimer _prof(L"Depth Pre-Pass", gfxContext);
        sorter.RenderMeshes(MeshSorter::kZPass, gfxContext, globals);
    }
#endif

    if (SSAO::Enable) {
        SSAO::Render(gfxContext, cam);
    }

    if (!SSAO::DebugDraw)
    {
        ScopedTimer _outerprof(L"Main Render", gfxContext);

        gfxContext.TransitionResource(g_SceneColorBuffer, D3D12_RESOURCE_STATE_RENDER_TARGET, true);
        gfxContext.ClearColor(g_SceneColorBuffer);

        {
            ScopedTimer _prof(L"Render Color", gfxContext);

            gfxContext.TransitionResource(g_SSAOFullScreen, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gfxContext.TransitionResource(g_SceneDepthBuffer, D3D12_RESOURCE_STATE_DEPTH_READ);
            gfxContext.SetRenderTarget(g_SceneColorBuffer.GetRTV(), g_SceneDepthBuffer.GetDSV_DepthReadOnly());
            gfxContext.SetViewportAndScissor(viewport, scissor);

            mainSorter.RenderMeshes(MeshSorter::kOpaque, gfxContext, globals, useSDFGI, mp_SDFGIManager);
        }

        Renderer::DrawSkybox(gfxContext, cam, viewport, scissor);

        mainSorter.RenderMeshes(MeshSorter::kTransparent, gfxContext, globals);
    }
}

void ModelViewer::RenderScene( void )
{
    GraphicsContext& gfxContext = GraphicsContext::Begin(L"Scene Render");

    // ray march debug toggle
    // static bool rayMarchDebug = false;
    // if (GameInput::IsFirstPressed(GameInput::kKey_0))
    //     rayMarchDebug = !rayMarchDebug;

    uint32_t FrameIndex = TemporalEffects::GetFrameIndexMod2();
    const D3D12_VIEWPORT& viewport = m_MainViewport;
    const D3D12_RECT& scissor = m_MainScissor;

    ParticleEffectManager::Update(gfxContext.GetComputeContext(), Graphics::GetFrameTime());
    if (m_ModelInst.IsNull())
    {
#ifdef LEGACY_RENDERER
        mp_SDFGIManager->Update(gfxContext, m_Camera, viewport, scissor);
        Sponza::RenderScene(gfxContext, m_Camera, viewport, scissor, false, false, mp_SDFGIManager, /*useAtlas=*/true);
#endif
    }
    else
    {
        NonLegacyRenderShadowMap(gfxContext, m_Camera, viewport, scissor);
        NonLegacyRenderSDF(gfxContext, /*runSDFOnce=*/runSDFOnce);
        mp_SDFGIManager->Update(gfxContext, m_Camera, viewport, scissor);

        if (rayMarchDebug) {
            RayMarcherDebug(gfxContext, m_Camera, viewport, scissor);
        } else {
#if RENDER_DIRECT_ONLY == 1
            NonLegacyRenderScene(gfxContext, m_Camera, viewport, scissor, /*renderShadows=*/true, /*useSDFGI=*/false);
#else
            NonLegacyRenderScene(gfxContext, m_Camera, viewport, scissor, /*renderShadows=*/true, /*useSDFGI=*/!showDIOnly);
#endif
        }
    }

    if (!rayMarchDebug)
        mp_SDFGIManager->Render(gfxContext, m_Camera);

#if MAIN_SUN_SHADOW_BUFFER_VIS == 1  //all main macros in pch.h
    Renderer::DrawShadowBuffer(gfxContext, viewport, scissor);
#endif

    // Commented Out Unnecessary MiniEngine Features
    //   E.g. MotionBlur, Particle Effects, etc.
    /*
    
    {
        // Some systems generate a per-pixel velocity buffer to better track dynamic and skinned meshes.  Everything
        // is static in our scene, so we generate velocity from camera motion and the depth buffer.  A velocity buffer
        // is necessary for all temporal effects (and motion blur).
        MotionBlur::GenerateCameraVelocityBuffer(gfxContext, m_Camera, true);

        TemporalEffects::ResolveImage(gfxContext);

        ParticleEffectManager::Render(gfxContext, m_Camera, g_SceneColorBuffer, g_SceneDepthBuffer,  g_LinearDepth[FrameIndex]);

        // Until I work out how to couple these two, it's "either-or".
        if (DepthOfField::Enable)
            DepthOfField::Render(gfxContext, m_Camera.GetNearClip(), m_Camera.GetFarClip());
        else
            MotionBlur::RenderObjectBlur(gfxContext, g_VelocityBuffer);
    }
    */
    gfxContext.Finish();
}

void ModelViewer::RenderUI( class GraphicsContext& gfxContext ) {
#if UI_ENABLE
    ImGui::Begin("SDFGI Settings");

    Matrix4 viewMat = m_Camera.GetViewMatrix();
    Float4 r0(viewMat.GetX().GetX(), viewMat.GetX().GetY(), viewMat.GetX().GetZ(), viewMat.GetX().GetW());
    Float4 r1(viewMat.GetY().GetX(), viewMat.GetY().GetY(), viewMat.GetY().GetZ(), viewMat.GetY().GetW());
    Float4 r2(viewMat.GetZ().GetX(), viewMat.GetZ().GetY(), viewMat.GetZ().GetZ(), viewMat.GetZ().GetW());
    Float4 r3(viewMat.GetW().GetX(), viewMat.GetW().GetY(), viewMat.GetW().GetZ(), viewMat.GetW().GetW());
    Float4x4 viewMatrix(r0, r1, r2, r3);
    SunDirection.Update(viewMatrix);

    // float sunLightIntensity = g_SunLightIntensity;
    // if (ImGui::SliderFloat("Sun Light Intensity", &sunLightIntensity, 0.0f, 16.0f, "%.2f"))
    // {
    //     g_SunLightIntensity = sunLightIntensity;
    // }
    ImGui::SliderFloat("GI Intensity", &giIntensity, 0.0f, 1.0f, "%.2f");
    mp_SDFGIManager->giIntensity = pow(giIntensity, 2.0f);
    ImGui::SliderFloat("Hysteresis", &mp_SDFGIManager->hysteresis, 0.0f, 1.0f);
    ImGui::Checkbox("Show Voxelized SDF Scene", &rayMarchDebug);
    static const char* shadingOptions[]{"Show DI + GI","Show DI Only","Show GI Only"};
    static int shadingMode = 0;
    ImGui::Combo("Shading", &shadingMode, shadingOptions, IM_ARRAYSIZE(shadingOptions));
    showDIPlusGI = shadingMode == 0;
    showDIOnly = shadingMode == 1;
    showGIOnly = shadingMode == 2;
    // ImGUI doesn't accept BOOL, only bool.
    mp_SDFGIManager->showGIOnly = showGIOnly;
    ImGui::Checkbox("Show Probes", &mp_SDFGIManager->renderProbViz);
    static const char* envOptions[]{"Show Environment Map","Show Irr. Atlas","Show Vis. Atlas"};
    static int envMode = 0;
    ImGui::Combo("Environment", &envMode, envOptions, IM_ARRAYSIZE(envOptions));
    mp_SDFGIManager->renderIrradianceAtlas = envMode == 1;
    mp_SDFGIManager->renderVisibilityAtlas = envMode == 2;
    ImGui::SliderInt("Atlas Slice", &mp_SDFGIManager->renderAtlasZIndex, 0.0, mp_SDFGIManager->maxZIndex);
    // ImGui::SliderFloat("Max Visibility Distance", &mp_SDFGIManager->maxVisibilityDistance, 0.0f, 1000.0f);

    static const char* animMode[]{ "Animation Paused", "Animation Playing" }; 
    static const char** animModeSelect = &animMode[0]; 

    ImGui::LabelText("", *animModeSelect);
    if (ImGui::Button("Play")) {
        m_ModelInst.PlayAnimation(0, true); 
        runSDFOnce = false; 
        animModeSelect = &animMode[1]; 
    }
    ImGui::SameLine(); 
    if (ImGui::Button("Pause")) {
        m_ModelInst.PauseAnimation(0); 
        runSDFOnce = true; 
        animModeSelect = &animMode[0];
    }

    ImGui::End();

    ImGui::Render();
    gfxContext.SetDescriptorHeap(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, Renderer::s_TextureHeap.GetHeapPointer()); 
    ImGui_ImplDX12_RenderDrawData(ImGui::GetDrawData(), gfxContext.GetCommandList());
#endif
}

// void ModelViewer::RenderUI( class GraphicsContext& gfxContext ) {
// #if UI_ENABLE
//     ImGui::Begin("SDFGI Settings");
//     Matrix4 viewMat = m_Camera.GetViewMatrix();
//     Float4 r0(viewMat.GetX().GetX(), viewMat.GetX().GetY(), viewMat.GetX().GetZ(), viewMat.GetX().GetW());
//     Float4 r1(viewMat.GetY().GetX(), viewMat.GetY().GetY(), viewMat.GetY().GetZ(), viewMat.GetY().GetW());
//     Float4 r2(viewMat.GetZ().GetX(), viewMat.GetZ().GetY(), viewMat.GetZ().GetZ(), viewMat.GetZ().GetW());
//     Float4 r3(viewMat.GetW().GetX(), viewMat.GetW().GetY(), viewMat.GetW().GetZ(), viewMat.GetW().GetW());
//     Float4x4 viewMatrix(r0, r1, r2, r3);
//     SunDirection.Update(viewMatrix);
//     // ImGui::SliderFloat("Sun Intensity", &m_SunIntensity, 1, 1.5);
//     ImGui::SliderFloat("GI Intensity", &mp_SDFGIManager->giIntensity, 0, 0.038);
//     // ImGui::SliderFloat("Baked GI Intensity", &mp_SDFGIManager->bakedGIIntensity, 0, 1);
//     // ImGui::SliderInt("Baked Sun Shadow", &mp_SDFGIManager->bakedSunShadow, 0, 100);
//     ImGui::SliderInt("Probe Offset X", &mp_SDFGIManager->probeOffsetX, -100, 100);
//     ImGui::SliderInt("Probe Offset Y", &mp_SDFGIManager->probeOffsetY, -100, 100);
//     ImGui::SliderInt("Probe Offset Z", &mp_SDFGIManager->probeOffsetZ, -100, 100);
//     ImGui::SliderFloat("Hysteresis", &mp_SDFGIManager->hysteresis, 0.0f, 1.0f);
//     ImGui::Checkbox("Render Probe Viz", &mp_SDFGIManager->renderProbViz);
//     ImGui::End();

//     ImGui::Render();
//     gfxContext.SetDescriptorHeap(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, Renderer::s_TextureHeap.GetHeapPointer()); 
//     ImGui_ImplDX12_RenderDrawData(ImGui::GetDrawData(), gfxContext.GetCommandList());
// #endif
// }