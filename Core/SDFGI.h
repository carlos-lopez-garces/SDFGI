#pragma once
#include "Texture.h"
#include "Math/Vector.h"
#include "CommandContext.h"
#include "GpuBuffer.h"
#include <array>

using namespace Math;

typedef Vector3 Vector3i;
typedef Vector3 uint3;
typedef Vector3 float3;

typedef std::array<uint32_t, 3> Vector3u;
typedef std::array<float, 3> Vector3f;

namespace Math { class Camera; }
class GraphicsContext;
class ComputeContext;
class BoolVar;

namespace SDFGI
{
    void Initialize(void);
    
    void Shutdown(void);
    
    void Render(GraphicsContext& context, const Math::Camera& camera, SDFGIManager *SDFGIManager);
    
    void UpdateProbeData(GraphicsContext& context);

    extern BoolVar Enable;
    extern BoolVar DebugDraw;
    
    struct SDFGIProbe {
        // Position of the probe in world space.
        Vector3 position;      
        float irradiance;    
        float depth;
    };

    struct SDFGIProbeGrid {
        // Number of probes along each axis (x, y, z).
        Vector3u probe_count;
        // Distance between probes in world space.
        Vector3f probe_spacing;
        std::vector<SDFGIProbe> probes;

        SDFGIProbeGrid(Vector3u count, Vector3f spacing);

        void GenerateProbes();
    };

    // A lot of "Managers" in the codebase.
    class SDFGIManager {
    public:
        Texture irradianceTexture;
        Texture depthTexture;
        SDFGIProbeGrid probeGrid;
        StructuredBuffer probeBuffer;

        SDFGIManager(Vector3u probeCount, Vector3f probeSpacing);

        void InitializeTextures();

        void InitializeProbeBuffer();
    };
}
