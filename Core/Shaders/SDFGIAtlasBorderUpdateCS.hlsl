cbuffer ProbeData : register(b0) {
    float4x4 RandomRotation;

    float3 GridSize;
    float pad0;

    float3 ProbeSpacing;
    float pad1;

    float3 SceneMinBounds;
    float pad2;

    uint ProbeCount;
    uint ProbeAtlasBlockResolution;
    uint GutterSize;
    float MaxWorldDepth;

    bool SampleSDF;
};
RWTexture2DArray<float4> IrradianceAtlas : register(u0);
RWTexture2DArray<float2> DepthAtlas : register(u1);


[numthreads(36, 1, 1)]
void main( uint3 dispatchThreadID : SV_DispatchThreadID, uint3 groupThreadID : SV_GroupThreadID)
{
    //uint probeIndex = (dispatchThreadID.x / 32)
    //    + dispatchThreadID.y * GridSize.x
    //    + dispatchThreadID.z * GridSize.x * GridSize.y;
    //if (probeIndex >= ProbeCount) return;

    uint3 probeTexCoord = uint3(GutterSize, GutterSize, 0) + uint3(
        (dispatchThreadID.x / 36) * (GutterSize + ProbeAtlasBlockResolution),
        dispatchThreadID.y * (GutterSize + ProbeAtlasBlockResolution),
        dispatchThreadID.z
    );

    //IrradianceAtlas[probeTexCoord - uint3(1,1,0)] = float4(0, 1, 1, 1);
    if (groupThreadID.x == 0) {
        //TL
        uint3 a = probeTexCoord;
        a -= uint3(1, 1, 0);
        
        IrradianceAtlas[a] = IrradianceAtlas[a + uint3(9, 9, 0)];
        //BR
        IrradianceAtlas[a + uint3(10, 10, 0)] = IrradianceAtlas[probeTexCoord];

        ////TR
        a.x += 10;
        IrradianceAtlas[a] = IrradianceAtlas[probeTexCoord + uint3(0, 8, 0)];
        ////BL
        //
        IrradianceAtlas[a + uint3(-10, 10, 0)] = IrradianceAtlas[probeTexCoord + uint3(8, 0, 0)];
    }

    int diff = groupThreadID.x % 9;
    if (groupThreadID.x < 9) {
        //Top
        uint3 mirror = probeTexCoord;
        probeTexCoord.y -= 1;
        probeTexCoord.x += diff;
        mirror.x += 8 - diff;

        IrradianceAtlas[probeTexCoord] = IrradianceAtlas[mirror];
    }
    else if (groupThreadID.x < 18) {
        ////Bottom
        probeTexCoord.y += 9;

        uint3 mirror = probeTexCoord;
        mirror.y -= 1;

        probeTexCoord.x += diff;
        mirror.x += 8 - diff;

        IrradianceAtlas[probeTexCoord] = IrradianceAtlas[mirror];
    }
    else if (groupThreadID.x < 27) {
        ////Left
        uint3 mirror = probeTexCoord;
        probeTexCoord.x -= 1;

        probeTexCoord.y += diff;
        mirror.y += 8 - diff;

        IrradianceAtlas[probeTexCoord] = IrradianceAtlas[mirror];
    }
    else {
        ////Right
        probeTexCoord.x += 9;
        uint3 mirror = probeTexCoord;
        mirror.x -= 1;

        probeTexCoord.y += diff;
        mirror.y += 8 - diff;

        IrradianceAtlas[probeTexCoord] = IrradianceAtlas[mirror];
    }
}