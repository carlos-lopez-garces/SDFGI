Texture2D<float4> depthTexture : register(t0);     // Depth texture (SRV in slot t0)
SamplerState samplerState : register(s0);  // Static sampler (Sampler in slot s0)

struct VSOutput {
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD0;
};

float4 main(VSOutput input) : SV_TARGET{
    return float4(input.uv.x, input.uv.y, 0., 1.); 
}