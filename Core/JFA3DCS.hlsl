cbuffer JFAData : register(b0) {
		float3 gridResolution; // 12 bytes
		uint stepSize;         // 4 bytes
};

RWTexture3D<float4> inputJFATexture        : register(u0);
RWTexture3D<float4> finalSDFTexture        : register(u1);
RWTexture3D<float4> intermediateJFATexture : register(u2);

SamplerState samplerState : register(s0);  // Static sampler (Sampler in slot s0)

[numthreads(8, 8, 8)]
void main( uint3 DTid : SV_DispatchThreadID )
{
		inputJFATexture[DTid] = float4(0, 1, 0, 1);
		finalSDFTexture[DTid] = float4(1, 0, 0, 1);
		intermediateJFATexture[DTid] = float4(0, 0, 1, 1);
}