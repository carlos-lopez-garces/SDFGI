static const float PI = 3.14159265f;

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
    float pad3;
};

StructuredBuffer<float4> ProbePositions : register(t0);
Texture2DArray<float4> ProbeCubemapArray : register(t1);

RWTexture2DArray<float4> IrradianceAtlas : register(u0);
RWTexture2DArray<float> DepthAtlas : register(u1);

SamplerState LinearSampler : register(s0);

float2 signNotZero(float2 v) {
    return float2((v.x >= 0.0 ? 1.0 : -1.0), (v.y >= 0.0 ? 1.0 : -1.0));
}

float2 octEncode(float3 v) {
    float l1norm = abs(v.x) + abs(v.y) + abs(v.z);
    float2 result = v.xy * (1.0 / l1norm);
    
    if (v.z < 0.0) {
        result = (1.0 - abs(result.yx)) * signNotZero(result.xy);
    }
    
    return result;
}

/** Returns a unit vector. Argument o is an octahedral vector packed via octEncode,
    on the [-1, +1] square*/
float3 octDecode(float2 o) {
    float3 v = float3(o.x, o.y, 1.0 - abs(o.x) - abs(o.y));
    if (v.z < 0.0) {
        v.xy = (1.0 - abs(v.yx)) * signNotZero(v.xy);
    }
    return normalize(v);
}

int GetFaceIndex(float3 dir)
{
    float3 absDir = abs(dir);

    if (absDir.x > absDir.y && absDir.x > absDir.z)
    {
        // X component is largest
        return dir.x > 0 ? 0 : 1; // +X or -X
    }
    else if (absDir.y > absDir.x && absDir.y > absDir.z)
    {
        // Y component is largest
        return dir.y > 0 ? 2 : 3; // +Y or -Y
    }
    else
    {
        // Z component is largest
        return dir.z > 0 ? 4 : 5; // +Z or -Z
    }
}

float3 spherical_fibonacci(uint index, uint sample_count) {
    const float PHI = sqrt(5.0) * 0.5 + 0.5;
    float phi = 2.0 * PI * frac(index * (PHI - 1));
    float cos_theta = 1.0 - (2.0 * index + 1.0) / sample_count;
    float sin_theta = sqrt(1.0 - cos_theta * cos_theta);
    return float3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
}

//Returns in [0, 1] UV space
float2 sampleCube(out uint faceIndex,
    float3 v)
{
    float3 vAbs = abs(v);
    float ma;
    float2 uv;
    if (vAbs.z >= vAbs.x && vAbs.z >= vAbs.y)
    {
        faceIndex = v.z < 0.0 ? 5 : 4;
        ma = 0.5 / vAbs.z;
        uv = float2(v.z < 0.0 ? v.x : -v.x, -v.y);
    }
    else if (vAbs.y >= vAbs.x)
    {
        faceIndex = v.y < 0.0 ? 3 : 2;
        ma = 0.5 / vAbs.y;
        uv = float2(v.x, v.y < 0.0 ? v.z : -v.z);
    }
    else
    {
        faceIndex = v.x < 0.0 ? 1 : 0;
        ma = 0.5 / vAbs.x;
        uv = float2(v.x < 0.0 ? -v.z : v.z, -v.y);
    }
    return uv * ma + 0.5;
}

[numthreads(1, 1, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID) {
    //for each thread, write into IrradianceAtlas
    uint probeIndex = dispatchThreadID.x
        + dispatchThreadID.y * GridSize.x
        + dispatchThreadID.z * GridSize.x * GridSize.y;

    if (probeIndex >= ProbeCount) return;

    float3 probePosition = ProbePositions[probeIndex].xyz;

    //uint3 atlasCoord = uint3(
    //    dispatchThreadID.x * (ProbeAtlasBlockResolution + GutterSize),
    //    dispatchThreadID.y * (ProbeAtlasBlockResolution + GutterSize),
    //    dispatchThreadID.z
    //);

    //In Screenspace, 0,0 = top left, (width - 1, height -1) = bot right
    uint3 atlasCoordStart_SS = uint3(
        dispatchThreadID.x * (ProbeAtlasBlockResolution + GutterSize),
        dispatchThreadID.y * (ProbeAtlasBlockResolution + GutterSize),
        dispatchThreadID.z
    );

    //probeIndex = 2;
    for (int i = 0; i < ProbeAtlasBlockResolution; i++) {
        for (int j = 0; j < ProbeAtlasBlockResolution; j++) {
            uint3 probeTexCoord = atlasCoordStart_SS + uint3(i, j, 0);
            //float4 col = float4((float)i / ProbeAtlasBlockResolution, (float)j / ProbeAtlasBlockResolution, 0, 1);
            //IrradianceAtlas[probeTexCoord] = col;

            float2 o = float2(((float)i + 0.5f)/ ProbeAtlasBlockResolution, ((float)j + 0.5f) / ProbeAtlasBlockResolution);
            //o += float2(0.5, 0.5);
            //for (int k = 0; k < 4; k++) {
            //    o += float2()
            //}

            o *= float2(2.0, 2.0);
            o -= float2(1.0, 1.0);


            float3 decodedSphereNormal = octDecode(o);
            float4 col = float4((decodedSphereNormal * 0.5) + float3(0.5, 0.5, 0.5), 1.0);
            //float4 col = float4(decodedSphereNormal, 1.0);
            //col = float4(1, 0, 0, 1);
            uint faceIndex = 0;
            float2 uv = sampleCube(faceIndex, decodedSphereNormal);

            col = float4(uv, 0, 1);



            //int faceIndex = GetFaceIndex(decodedSphereNormal);
            

            uint textureIndex = 6 * probeIndex + faceIndex;

            // TODO: sample SDF for color and depth in direction 'dir'.

            float4 irradianceSample = ProbeCubemapArray.SampleLevel(LinearSampler, float3(uv, textureIndex), 0);

            col = irradianceSample;





#if 0
            if (faceIndex == 0) {
                col = float4(1, 0, 0, 1);
            }
            else if (faceIndex == 1) {
                col = float4(0, 1, 0, 1);
            }
            else if (faceIndex == 2) {
                col = float4(0, 0, 1, 1);
            }
            else if (faceIndex == 3) {
                col = float4(1, 1, 0, 1);
            }
            else if (faceIndex == 4) {
                col = float4(0, 1, 1, 1);
            }
            else if (faceIndex == 5) {
                col = float4(1, 1, 1, 1);
            }
#endif
#if 0
            o += float2(1.0, 1.0);
            o *= 0.5;
            col = float4(o.x, o.y, 0, 1);
#endif
#if 0
            col = float4(uv, 0, 1);
#endif
#if 0
            if (probeIndex == 0) {
                col = float4(1, 0, 0, 1);
            }
            else {
                col = float4(0, 1, 0, 1);
            }
#endif
            IrradianceAtlas[probeTexCoord] = col;

            
        }
    }

    //for (int i = 0; i < ProbeAtlasBlockResolution; i++) {
    //    int j = ProbeAtlasBlockResolution - 1;
    //    uint3 probeTexCoord = atlasCoordStart_SS + uint3(i, j + 1, 0);

    //    float2 o = float2((float)i / ProbeAtlasBlockResolution, (float)j / ProbeAtlasBlockResolution);
    //    o *= float2(2.0, 2.0);
    //    o -= float2(1.0, 1.0);
    //    float3 decodedSphereNormal = octDecode(o);
    //    float4 col = float4((decodedSphereNormal * 0.5) + float3(0.5, 0.5, 0.5), 1.0);
    //    IrradianceAtlas[probeTexCoord] = col;
    //}
    //for (int i = 0; i < ProbeAtlasBlockResolution; i++) {
    //    int j = ProbeAtlasBlockResolution - 1;
    //    uint3 probeTexCoord = atlasCoordStart_SS + uint3(j + 1, i, 0);

    //    float2 o = float2((float)j / ProbeAtlasBlockResolution, (float)i / ProbeAtlasBlockResolution);
    //    o *= float2(2.0, 2.0);
    //    o -= float2(1.0, 1.0);
    //    float3 decodedSphereNormal = octDecode(o);
    //    float4 col = float4((decodedSphereNormal * 0.5) + float3(0.5, 0.5, 0.5), 1.0);
    //    IrradianceAtlas[probeTexCoord] = col;
    //}
    /*
    
    uint probeIndex = dispatchThreadID.x 
                + dispatchThreadID.y * GridSize.x 
                + dispatchThreadID.z * GridSize.x * GridSize.y;

    if (probeIndex >= ProbeCount) return;

    float3 probePosition = ProbePositions[probeIndex].xyz;

    uint3 atlasCoord = uint3(
        dispatchThreadID.x * (ProbeAtlasBlockResolution + GutterSize),
        dispatchThreadID.y * (ProbeAtlasBlockResolution + GutterSize),
        dispatchThreadID.z
    );

    const uint sample_count = ProbeAtlasBlockResolution*ProbeAtlasBlockResolution;

    for (uint i = 0; i < sample_count; ++i) {
        float3 dir = normalize(mul(RandomRotation, float4(spherical_fibonacci(i, sample_count), 1.0)).xyz);
        float2 encodedCoord = octEncode(dir);
        uint3 probeTexCoord = atlasCoord + uint3(
            (encodedCoord.x * 0.5 + 0.5) * (ProbeAtlasBlockResolution - GutterSize),
            (encodedCoord.y * 0.5 + 0.5) * (ProbeAtlasBlockResolution - GutterSize),
            0.0f
        );

        int faceIndex = GetFaceIndex(dir);

        uint textureIndex = probeIndex * 6 + faceIndex;

        // TODO: sample SDF for color and depth in direction 'dir'.

        float4 irradianceSample = ProbeCubemapArray.SampleLevel(LinearSampler, float3(encodedCoord.xy * 0.5 + 0.5, textureIndex), 0);
        
        IrradianceAtlas[probeTexCoord] = irradianceSample;
        // DepthAtlas[probeTexCoord] = ...;
    }
    */
}
