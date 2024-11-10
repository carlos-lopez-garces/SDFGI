struct VSOutput {
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD0;
};

float4 main(VSOutput input) : SV_TARGET{
    return float4(0.0f, input.uv.x, input.uv.y, 1.0f); // Red color
}