cbuffer ProbeData : register(b0) {
    uint ProbeCount;
    float ProbeMaxDistance;
    float3 GridSize;
    float3 ProbeSpacing;
    float3 SceneMinBounds;
    uint ProbeIndex;
};

StructuredBuffer<float4> ProbePositions : register(t0);
Texture2D<float4> ProbeFaceTextures[6] : register(t1);
RWTexture3D<float4> IrradianceTexture : register(u0);
RWTexture3D<float> DepthTexture : register(u1);
RWTexture2D<float4> IrradianceAtlas : register(u2);
RWTexture2D<float> DepthAtlas : register(u3);
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

[numthreads(1, 1, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID) {
    uint probeIndex = dispatchThreadID.x 
                + dispatchThreadID.y * GridSize.x 
                + dispatchThreadID.z * GridSize.x * GridSize.y;

    if (probeIndex >= ProbeCount) return;

    float3 probePosition = ProbePositions[probeIndex].xyz;

    uint probeBlockSize = 4;
    uint2 atlasCoord = uint2(
        (probeIndex % GridSize.x) * (probeBlockSize),
        (probeIndex / GridSize.x) * (probeBlockSize)
    );

    float3 sampleDirections[16] = {
        normalize(float3(1,  1,  0)), normalize(float3(-1,  1,  0)), normalize(float3(1, -1,  0)), normalize(float3(-1, -1,  0)),
        normalize(float3(1,  0,  1)), normalize(float3(-1,  0,  1)), normalize(float3(1,  0, -1)), normalize(float3(-1,  0, -1)),
        normalize(float3(0,  1,  1)), normalize(float3(0, -1,  1)), normalize(float3(0,  1, -1)), normalize(float3(0, -1, -1)),
        float3(1, 0, 0), float3(-1, 0, 0), float3(0, 1, 0), float3(0, 0, 1)
    };

    for (int i = 0; i < 16; ++i) {
        float2 encodedCoord = octEncode(sampleDirections[i]);

        uint2 probeTexCoord = atlasCoord + uint2(
            (encodedCoord.x * 0.5 + 0.5) * (probeBlockSize - 1),
            (encodedCoord.y * 0.5 + 0.5) * (probeBlockSize - 1)
        );

        float3 dir = sampleDirections[i];
        int faceIndex = GetFaceIndex(dir);

        float4 irradianceSample = ProbeFaceTextures[faceIndex].SampleLevel(LinearSampler, encodedCoord, 0);
        
        IrradianceAtlas[probeTexCoord] = irradianceSample;
        DepthAtlas[probeTexCoord] = length(probePosition - (probePosition + sampleDirections[i] * ProbeMaxDistance)) / ProbeMaxDistance;
    }
}
