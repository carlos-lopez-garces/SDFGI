Texture2DArray<float4> IrradianceAtlas : register(t0);
Texture2DArray<float> DepthAtlas : register(t1);
SamplerState LinearSampler : register(s0);

struct VS_OUTPUT
{
    float4 pos : SV_POSITION;
    float2 texCoord : TEXCOORD0;
};

float4 main(VS_OUTPUT input) : SV_Target
{
    //1920 1080 border cut off so I can get a square render
    if (input.texCoord.x < 3.5f / 16.0f || input.texCoord.x > 12.5f / 16.0f) {
        return float4(0.1, 0.1, 0.1, 1);
    }
    float2 uv = float2(
        (input.texCoord.x - 3.5f / 16.0f) / (9.0f / 16.0f),
        input.texCoord.y
    );
//float2 uv = input.texCoord;
    
    return IrradianceAtlas.SampleLevel(LinearSampler, float3(uv, /*slice_index=*/0), 0);
    //return IrradianceAtlas[0].SampleLevel(LinearSampler, float2(input.texCoord), 0);
}

//CubemapFaces[faceIndex].Sample(LinearSampler, uv); 