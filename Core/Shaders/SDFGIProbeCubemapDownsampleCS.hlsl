Texture2D<float4> srcTexture : register(t0);  
RWTexture2D<float4> dstTexture : register(u0);

SamplerState samplerBilinear : register(s0); 

cbuffer DownsampleCB : register(b0) {
    float3 srcSize;  
    float pad0;
    float3 dstSize;
    float pad1;  
    float3 scale;
    float pad2;    
};

[numthreads(8, 8, 1)]
void main(uint3 DTid : SV_DispatchThreadID) {
    uint2 dstCoord = DTid.xy;
    //float2 uv = dstCoord / float2(8.0f, 8.0f);
    if (dstCoord.x >= dstSize.x || dstCoord.y >= dstSize.y) return;

    float2 srcCoord = float2((srcSize.x - srcSize.y) * 0.5, 0);
    float2 uv = srcCoord / srcSize.xy;
    uv += (dstCoord / dstSize.xy) * float2(srcSize.y / srcSize.x, 1);

    float4 color = srcTexture.SampleLevel(samplerBilinear, uv, 0);
    float4 testUVCol = float4(uv, 0, 1);
    dstTexture[dstCoord] = color;
    //dstTexture[dstCoord] = testUVCol;
}


/*
What does this shader do?

Basically, we run smallSizeTexture.xy # of threads, and each of those threads should sample the original source texture at an appropriate UV.


A naive squished version of the whole image would be: using the exact same UV!



*/