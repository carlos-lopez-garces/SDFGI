Texture2D<float4> CubemapFaces[6] : register(t0);
SamplerState LinearSampler : register(s0);

cbuffer CubemapGridConfig : register(b0) {
    int GridColumns;
    int GridRows; 
    float CellSize;      
};

struct VS_OUTPUT {
    float4 pos : SV_POSITION;
    float2 texCoord : TEXCOORD0;
};

// Renders a grid of 6 cubemap face textures to a fullscreen quad.
float4 main(VS_OUTPUT input) : SV_Target{
    int faceIndex = int(input.texCoord.y * GridRows) * GridColumns + int(input.texCoord.x * GridColumns);

    if (faceIndex >= 6) return float4(0, 0, 0, 1);
    
    float2 uv = input.texCoord;
    uv.x = uv.x % (1.0 / 3.0) * 3.0;
    uv.y = uv.y % (0.5) * 2.0;
    return CubemapFaces[faceIndex].Sample(LinearSampler, uv); //is this even .. correct? doesn't it have to be modded?
}
