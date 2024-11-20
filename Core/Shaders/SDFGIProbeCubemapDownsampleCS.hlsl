Texture2D<float4> srcTexture : register(t0);  
RWTexture2D<float4> dstTexture : register(u0);

SamplerState samplerBilinear : register(s0); 

cbuffer DownsampleCB : register(b0) {
    float4 srcSize;  
    float4 dstSize;  
    float4 scale;    
};

[numthreads(8, 8, 1)]
void main(uint3 DTid : SV_DispatchThreadID) {
    uint2 dstCoord = DTid.xy;

    if (dstCoord.x >= dstSize.x || dstCoord.y >= dstSize.y) return;

    float2 uv = (dstCoord.xy + float2(0.5, 0.5)) * scale.xy / srcSize.xy;

    float4 color = srcTexture.SampleLevel(samplerBilinear, uv, 0);

    dstTexture[dstCoord] = color;
}
