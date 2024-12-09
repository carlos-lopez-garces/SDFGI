//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
// Developed by Minigraph
//
// Author(s):	James Stanard
//              Justin Saunders (ATG)

#include "Common.hlsli"

Texture2D<float4> baseColorTexture          : register(t0);
Texture2D<float3> metallicRoughnessTexture  : register(t1);
Texture2D<float1> occlusionTexture          : register(t2);
Texture2D<float3> emissiveTexture           : register(t3);
Texture2D<float3> normalTexture             : register(t4);

SamplerState baseColorSampler               : register(s0);
SamplerState metallicRoughnessSampler       : register(s1);
SamplerState occlusionSampler               : register(s2);
SamplerState emissiveSampler                : register(s3);
SamplerState normalSampler                  : register(s4);

TextureCube<float3> radianceIBLTexture      : register(t10);
TextureCube<float3> irradianceIBLTexture    : register(t11);
Texture2D<float> texSSAO			        : register(t12);
Texture2D<float> texSunShadow			    : register(t13);
Texture2DArray<float4> IrradianceAtlas      : register(t21);
Texture2DArray<float2> DepthAtlas            : register(t22);

cbuffer MaterialConstants : register(b0)
{
    float4 baseColorFactor;
    float3 emissiveFactor;
    float normalTextureScale;
    float2 metallicRoughnessFactor;
    uint flags;
}

cbuffer GlobalConstants : register(b1)
{
    float4x4 ViewProj;
    float4x4 SunShadowMatrix;
    float3 ViewerPos;
    float3 SunDirection;
    float3 SunIntensity;
    float _pad;
    float IBLRange;
    float IBLBias;
}

cbuffer SDFGIConstants : register(b2) {
    int3 GridSize;
    float Pad0;

    float3 ProbeSpacing;
    float Pad1;

    float3 SceneMinBounds;
    float Pad2;

    uint ProbeAtlasBlockResolution;	
    uint GutterSize;
    float AtlasWidth;
    float AtlasHeight;

    bool UseAtlas;
    bool ShowGIOnly;
    float GIintensity;
    float Pad5;
};

cbuffer VoxelConsts : register(b3)
{
    float viewWidth; 
    float viewHeight;
    float voxelTextureResolution; 
    int axis;
    bool voxelPass; 
}

RWTexture3D<uint> SDFGIVoxelAlbedo : register(u0);
RWTexture3D<uint4> SDFGIVoxelVoronoi : register(u1);

struct VSOutput
{
    float4 position : SV_POSITION;
    float3 normal : NORMAL;
#ifndef NO_TANGENT_FRAME
    float4 tangent : TANGENT;
#endif
    float2 uv0 : TEXCOORD0;
#ifndef NO_SECOND_UV
    float2 uv1 : TEXCOORD1;
#endif
    float3 worldPos : TEXCOORD2;
    float3 sunShadowCoord : TEXCOORD3;
};

// Numeric constants
static const float PI = 3.14159265;
static const float3 kDielectricSpecular = float3(0.04, 0.04, 0.04);

// Flag helpers
static const uint BASECOLOR = 0;
static const uint METALLICROUGHNESS = 1;
static const uint OCCLUSION = 2;
static const uint EMISSIVE = 3;
static const uint NORMAL = 4;
#ifdef NO_SECOND_UV
#define UVSET( offset ) vsOutput.uv0
#else
#define UVSET( offset ) lerp(vsOutput.uv0, vsOutput.uv1, (flags >> offset) & 1)
#endif

struct SurfaceProperties
{
    float3 N;
    float3 V;
    float3 c_diff;
    float3 c_spec;
    float roughness;
    float alpha; // roughness squared
    float alphaSqr; // alpha squared
    float NdotV;
};

struct LightProperties
{
    float3 L;
    float NdotL;
    float LdotH;
    float NdotH;
};

//
// Shader Math
//

float Pow5(float x)
{
    float xSq = x * x;
    return xSq * xSq * x;
}

// Shlick's approximation of Fresnel
float3 Fresnel_Shlick(float3 F0, float3 F90, float cosine)
{
    return lerp(F0, F90, Pow5(1.0 - cosine));
}

float Fresnel_Shlick(float F0, float F90, float cosine)
{
    return lerp(F0, F90, Pow5(1.0 - cosine));
}

// Burley's diffuse BRDF
float3 Diffuse_Burley(SurfaceProperties Surface, LightProperties Light)
{
    float fd90 = 0.5 + 2.0 * Surface.roughness * Light.LdotH * Light.LdotH;
    return Surface.c_diff * Fresnel_Shlick(1, fd90, Light.NdotL).x * Fresnel_Shlick(1, fd90, Surface.NdotV).x;
}

// GGX specular D (normal distribution)
float Specular_D_GGX(SurfaceProperties Surface, LightProperties Light)
{
    float lower = lerp(1, Surface.alphaSqr, Light.NdotH * Light.NdotH);
    return Surface.alphaSqr / max(1e-6, PI * lower * lower);
}

// Schlick-Smith specular geometric visibility function
float G_Schlick_Smith(SurfaceProperties Surface, LightProperties Light)
{
    return 1.0 / max(1e-6, lerp(Surface.NdotV, 1, Surface.alpha * 0.5) * lerp(Light.NdotL, 1, Surface.alpha * 0.5));
}

// Schlick-Smith specular visibility with Hable's LdotH approximation
float G_Shlick_Smith_Hable(SurfaceProperties Surface, LightProperties Light)
{
    return 1.0 / lerp(Light.LdotH * Light.LdotH, 1, Surface.alphaSqr * 0.25);
}

//
//  Voxelization Helper Functions
//

uint3 GetVoxelCoords(float3 position, float2 uv, float textureResolution, int axis)
{
    uint x, y, z;

    switch (axis) {
    case 0: // X-axis pass
        x = (1. - saturate(position.z)) * textureResolution;
        y = uv.y * textureResolution;
        z = uv.x * textureResolution;
        break;
    case 1: // Y-axis pass
        x = (1. - uv.x) * textureResolution;
        y = saturate(position.z) * textureResolution;
        z = uv.y * textureResolution;
        break;
    case 2: // Z-axis pass
        x = uv.x * textureResolution;
        y = uv.y * textureResolution;
        z = saturate(position.z) * textureResolution;
        break;
    default:
        return uint3(0, 0, 0); // Invalid axis
    }

    return uint3(clamp(x, 0, textureResolution - 1),
        clamp(y, 0, textureResolution - 1),
        clamp(z, 0, textureResolution - 1));
}

// Converts a uint representing an RGBA8 color to a float4
float4 UnpackRGBA8(uint packedColor) {
    float4 color;
    color.r = ((packedColor >> 24) & 0xFF); // Extract red and normalize
    color.g = ((packedColor >> 16) & 0xFF); // Extract green and normalize
    color.b = ((packedColor >> 8) & 0xFF);  // Extract blue and normalize
    color.a = (packedColor & 0xFF);         // Extract alpha and normalize
    return color;
}

// Converts a float4 to a uint representing an RGBA8 color
uint PackRGBA8(float4 color) {
    uint packedColor = 0;
    packedColor |= (uint)(color.r) << 24; // Pack red
    packedColor |= (uint)(color.g) << 16; // Pack green
    packedColor |= (uint)(color.b) << 8;  // Pack blue
    packedColor |= (uint)(color.a);       // Pack alpha
    return packedColor;
}

void ImageAtomicRGBA8Avg(RWTexture3D<uint> img, uint3 coords, float4 val) {
    val.xyz *= 255.f;
    val.w = 1.f;
    uint newVal = PackRGBA8(val);
    uint prevStoredVal = 0;
    uint curStoredVal;
    // Loop as long as destination value gets changed by other threads
    do {
        InterlockedCompareExchange(img[coords], prevStoredVal, newVal, curStoredVal);
        if (curStoredVal == prevStoredVal) // sucessfully stored into image
            break;
        prevStoredVal = curStoredVal;
        float4 rval = UnpackRGBA8(curStoredVal);
        rval.xyz *= rval.w;          // Denormalize
        float4 curValF = rval + val; // Add new value
        //curValF = float4(1., 0., 0., 0.); 
        curValF.xyz /= curValF.w;    // Renormalize
        newVal = PackRGBA8(curValF);
    } while (true);
}

// A microfacet based BRDF.
// alpha:    This is roughness squared as in the Disney PBR model by Burley et al.
// c_spec:   The F0 reflectance value - 0.04 for non-metals, or RGB for metals.  This is the specular albedo.
// NdotV, NdotL, LdotH, NdotH:  vector dot products
//  N - surface normal
//  V - normalized view vector
//  L - normalized direction to light
//  H - normalized half vector (L+V)/2 -- halfway between L and V
float3 Specular_BRDF(SurfaceProperties Surface, LightProperties Light)
{
    // Normal Distribution term
    float ND = Specular_D_GGX(Surface, Light);

    // Geometric Visibility term
    //float GV = G_Schlick_Smith(Surface, Light);
    float GV = G_Shlick_Smith_Hable(Surface, Light);

    // Fresnel term
    float3 F = Fresnel_Shlick(Surface.c_spec, 1.0, Light.LdotH);

    return ND * GV * F;
}

float3 ShadeDirectionalLight(SurfaceProperties Surface, float3 L, float3 c_light)
{
    LightProperties Light;
    Light.L = L;

    // Half vector
    float3 H = normalize(L + Surface.V);

    // Pre-compute dot products
    Light.NdotL = saturate(dot(Surface.N, L));
    Light.LdotH = saturate(dot(L, H));
    Light.NdotH = saturate(dot(Surface.N, H));

    // Diffuse & specular factors
    float3 diffuse = Diffuse_Burley(Surface, Light);
    float3 specular = Specular_BRDF(Surface, Light);

    // Directional light
    return Light.NdotL * c_light * (diffuse + specular);
}

// Diffuse irradiance
float3 Diffuse_IBL(SurfaceProperties Surface)
{
    // Assumption:  L = N

    //return Surface.c_diff * irradianceIBLTexture.Sample(defaultSampler, Surface.N);

    // This is nicer but more expensive, and specular can often drown out the diffuse anyway
    float LdotH = saturate(dot(Surface.N, normalize(Surface.N + Surface.V)));
    float fd90 = 0.5 + 2.0 * Surface.roughness * LdotH * LdotH;
    float3 DiffuseBurley = Surface.c_diff * Fresnel_Shlick(1, fd90, Surface.NdotV);
    return DiffuseBurley * irradianceIBLTexture.Sample(defaultSampler, Surface.N);
}

// Approximate specular IBL by sampling lower mips according to roughness.  Then modulate by Fresnel. 
float3 Specular_IBL(SurfaceProperties Surface)
{
    float lod = Surface.roughness * IBLRange + IBLBias;
    float3 specular = Fresnel_Shlick(Surface.c_spec, 1, Surface.NdotV);
    return specular * radianceIBLTexture.SampleLevel(cubeMapSampler, reflect(-Surface.V, Surface.N), lod);
}

float3 ComputeNormal(VSOutput vsOutput)
{
    float3 normal = normalize(vsOutput.normal);

#ifdef NO_TANGENT_FRAME
    return normal;
#else
    // Construct tangent frame
    float3 tangent = normalize(vsOutput.tangent.xyz);
    float3 bitangent = normalize(cross(normal, tangent)) * vsOutput.tangent.w;
    float3x3 tangentFrame = float3x3(tangent, bitangent, normal);

    // Read normal map and convert to SNORM (TODO:  convert all normal maps to R8G8B8A8_SNORM?)
    normal = normalTexture.Sample(normalSampler, UVSET(NORMAL)) * 2.0 - 1.0;

    // glTF spec says to normalize N before and after scaling, but that's excessive
    normal = normalize(normal * float3(normalTextureScale, normalTextureScale, 1));

    // Multiply by transpose (reverse order)
    return mul(normal, tangentFrame);
#endif
}

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

float3 ACESToneMapping(float3 color) {
    const float a = 2.51f;
    const float b = 0.03f;
    const float c = 2.43f;
    const float d = 0.59f;
    const float e = 0.14f;
    return clamp((color * (a * color + b)) / (color * (c * color + d) + e), 0.0f, 1.0f);
}

float3 GammaCorrection(float3 color, float gamma)
{
    return pow(color, float3(1.f / gamma, 1.f / gamma, 1.f / gamma));
}

float2 GetUV(float3 direction, uint3 probeIndex) {
    float2 encodedDir = octEncode(direction);

    uint3 atlasCoord = 
        uint3(GutterSize, GutterSize, 0) 
        + probeIndex * uint3(ProbeAtlasBlockResolution + GutterSize, ProbeAtlasBlockResolution + GutterSize, 1);
    float2 texCoord = atlasCoord.xy;
    texCoord += float2(ProbeAtlasBlockResolution * 0.5f, ProbeAtlasBlockResolution * 0.5f);
    texCoord += encodedDir * (ProbeAtlasBlockResolution * 0.5f);
    texCoord = texCoord / float2(AtlasWidth, AtlasHeight);

    return texCoord;
}

float3 gridCoordToPosition(int3 c) {
    return ProbeSpacing * float3(c) + SceneMinBounds;
}

int3 BaseGridCoord(float3 X) {
    return clamp(int3((X - SceneMinBounds) / ProbeSpacing),
        int3(0, 0, 0),
        int3(GridSize) - int3(1, 1, 1));
}


float3 TestGI(
    float3 fragmentWorldPos,
    float3 normal
) {
    float3 localPos = (fragmentWorldPos - SceneMinBounds) / (float)ProbeSpacing;

    uint3 probeCoord = floor(uint3(floor(floor(localPos))));

    float3 interpWeight = frac(localPos);

    uint3 probeIndices[8] = {
        uint3(probeCoord),
        uint3(probeCoord + uint3(1, 0, 0)),
        uint3(probeCoord + uint3(0, 1, 0)),
        uint3(probeCoord + uint3(1, 1, 0)),
        uint3(probeCoord + uint3(0, 0, 1)),
        uint3(probeCoord + uint3(1, 0, 1)),
        uint3(probeCoord + uint3(0, 1, 1)),
        uint3(probeCoord + uint3(1, 1, 1))
    };

    float4 irradiance[8];
    float weights[8];
    float weightSum = 0.0;
    float4 resultIrradiance = float4(0.0, 0.0, 0.0, 0.0);


    int3 baseGridCoord = BaseGridCoord(fragmentWorldPos);
    float3 baseProbePos = gridCoordToPosition(baseGridCoord);
    float4 sumIrradiance = float4(0.0, 0.0, 0.0, 0.0);
    float sumWeight = 0.0;

    // alpha is how far from the floor(currentVertex) position. on [0, 1] for each axis.
    float3 alpha = clamp((fragmentWorldPos - baseProbePos) / ProbeSpacing, float3(0, 0, 0), float3(1, 1, 1));

    for (int i = 0; i < 8; ++i) 
    //int i = 0;
    //int i = 3;
    {
        float2 irradianceUV = GetUV(normal, probeIndices[i].xyz);
        uint slice_idx = (uint)floor(probeIndices[i].z);
        //return float3(irradianceUV, 0);

        float3 probeWorldPos = SceneMinBounds + float3(probeIndices[i]) * ProbeSpacing;
        float3 dirToProbe = normalize(probeWorldPos - fragmentWorldPos);
        float normalDotDir = dot(normal, dirToProbe);
        weights[i] = 1.0;
        if (normalDotDir <= 0.0) {
            weights[i] = 0.0;
            //continue;
        }

        {
            //float3 trueDirectionToProbe = normalize(probeWorldPos - fragmentWorldPos);
            //weights[i] *= pow(max(0.0001, (dot(trueDirectionToProbe, normal) + 1.0) * 0.5), 1) + 0.0;
            //weights[i] += 0.2;
            //if (dot(trueDirectionToProbe, normal) < 0) {
            //    weight = 0;
            //}
        }
        //if (length(dirToProbe) <= 0.5) {
        //    weights[i] = 0;
        //}
        int3  offset = int3(i, i >> 1, i >> 2) & int3(1, 1, 1);
        float3 trilinear = lerp(1.0 - alpha, alpha, offset);
        weights[i] *= trilinear.x * trilinear.y * trilinear.z;
        resultIrradiance += weights[i] * IrradianceAtlas.SampleLevel(defaultSampler, float3(irradianceUV, slice_idx), 0);
    }

    return resultIrradiance.rgb;
}


float3 SampleIrradiance(
    float3 wsPosition,       
    float3 normal
) {
    float normalBias = 0.25f;
    float energyPreservation = 0.85f;
    float depthSharpness = 50.0f;

    const float3 w_o = normalize(ViewerPos.xyz - wsPosition);


    float3 localPos = (wsPosition - SceneMinBounds) / ProbeSpacing;
    uint3 probeCoord = uint3(floor(floor(localPos))); 

    uint3 probeIndices[8] = {
        uint3(probeCoord),
        uint3(probeCoord + float3(1, 0, 0)),
        uint3(probeCoord + float3(0, 1, 0)),
        uint3(probeCoord + float3(1, 1, 0)),
        uint3(probeCoord + float3(0, 0, 1)),
        uint3(probeCoord + float3(1, 0, 1)),
        uint3(probeCoord + float3(0, 1, 1)),
        uint3(probeCoord + float3(1, 1, 1))
    };

    // uint3 probeIndices[8] = {
    //     uint3(probeCoord) + (uint3(0, 0 >> 1, 0 >> 2) & uint3(1,1,1)),
    //     uint3(probeCoord) + (uint3(1, 1 >> 1, 1 >> 2) & uint3(1,1,1)),
    //     uint3(probeCoord) + (uint3(2, 2 >> 1, 2 >> 2) & uint3(1,1,1)),
    //     uint3(probeCoord) + (uint3(3, 3 >> 1, 3 >> 2) & uint3(1,1,1)),
    //     uint3(probeCoord) + (uint3(4, 4 >> 1, 4 >> 2) & uint3(1,1,1)),
    //     uint3(probeCoord) + (uint3(5, 5 >> 1, 5 >> 2) & uint3(1,1,1)),
    //     uint3(probeCoord) + (uint3(6, 6 >> 1, 6 >> 2) & uint3(1,1,1)),
    //     uint3(probeCoord) + (uint3(7, 7 >> 1, 7 >> 2) & uint3(1,1,1))
    // };

    int3 baseGridCoord = BaseGridCoord(wsPosition);
    float3 baseProbePos = gridCoordToPosition(baseGridCoord);
    float4 sumIrradiance = float4(0.0, 0.0, 0.0, 0.0);
    float sumWeight = 0.0;

    // alpha is how far from the floor(currentVertex) position. on [0, 1] for each axis.
    float3 alpha = clamp((wsPosition - baseProbePos) / ProbeSpacing, float3(0,0,0), float3(1,1,1));

    for (int i = 0; i < 8; ++i) {
        int3  offset = int3(i, i >> 1, i >> 2) & int3(1,1,1);
        int3  probeGridCoord = clamp(baseGridCoord + offset, int3(0,0,0), int3(GridSize) - int3(1, 1, 1));

        float3 probePos = gridCoordToPosition(probeGridCoord);

        float3 probeToPoint = wsPosition - probePos + (normal + 3.0 * w_o) * normalBias;
        float3 dir = normalize(-probeToPoint);

        float3 trilinear = lerp(1.0 - alpha, alpha, offset);
        float weight = 1.0;

        // Smooth backface test
        {
            float3 trueDirectionToProbe = normalize(probePos - wsPosition);
            weight *= pow(max(0.0001, (dot(trueDirectionToProbe, normal) + 1.0) * 0.5), 2) + 0.2;
            //if (dot(trueDirectionToProbe, normal) < 0) {
            //    weight = 0;
            //}
        }

        // Moment visibility test
        {
            float2 texCoord = GetUV(-dir, probeIndices[i]);
            float distToProbe = length(probeToPoint);
            float2 temp = DepthAtlas.SampleLevel(defaultSampler, float3(texCoord, probeIndices[i].z), 0).rg;
            float mean = temp.x;
            float variance = abs(pow(temp.x, 2) - temp.y);
            float chebyshevWeight = variance / (variance + pow(max(distToProbe - mean, 0.0), 2));
            chebyshevWeight = max(pow(chebyshevWeight, 3), 0.0);
            // weight *= (distToProbe <= mean) ? 1.0 : chebyshevWeight;
        }

        weight = max(0.000001, weight);

        float2 irradianceUV = GetUV(normal, probeIndices[i]);
        float4 probeIrradiance = IrradianceAtlas.SampleLevel(defaultSampler, float3(irradianceUV, probeIndices[i].z), 0);

        const float crushThreshold = 0.2;
        if (weight < crushThreshold) {
            weight *= weight * weight * (1.0 / pow(crushThreshold,2)); 
        }

        weight *= trilinear.x * trilinear.y * trilinear.z;

        sumIrradiance += weight * probeIrradiance;

        sumWeight += weight;
    }

    float3 netIrradiance = sumIrradiance.rgb / sumWeight;
    netIrradiance *= energyPreservation;

    return 0.5 * PI *netIrradiance;
}

float calculateBias(float3 normal, float3 lightDir) {
    float slopeBias = 0.005f; // Tunable slope-scaled bias
    float constantBias = 0.002f; // Tunable constant bias
    return constantBias + slopeBias * max(0.0f, 1.0f - dot(normal, lightDir));
}

float CalculateSlopeBias(float3 surfaceNormal, float3 lightDirection,
    float baseBias, float slopeFactor)
{
    // Calculate the angle between the surface normal and light direction
    float cosAngle = saturate(dot(surfaceNormal, -lightDirection));

    // Calculate slope-dependent bias
    // As the surface becomes more perpendicular to light, increase the bias
    float slopeBias = max(baseBias, slopeFactor * tan(acos(cosAngle)));

    return slopeBias;
}

[RootSignature(Renderer_RootSig)]
float4 main(VSOutput vsOutput) : SV_Target0
{
    // Load and modulate textures
    float4 baseColor = baseColorFactor * baseColorTexture.Sample(baseColorSampler, UVSET(BASECOLOR));
    float2 metallicRoughness = metallicRoughnessFactor * 
        metallicRoughnessTexture.Sample(metallicRoughnessSampler, UVSET(METALLICROUGHNESS)).bg;
    float occlusion = occlusionTexture.Sample(occlusionSampler, UVSET(OCCLUSION));
    float3 emissive = emissiveFactor * emissiveTexture.Sample(emissiveSampler, UVSET(EMISSIVE));
    float3 normal = ComputeNormal(vsOutput);

    float3 indirectIrradiance = float3(1.0f, 1.0f, 1.0f);

    float3 F = lerp(kDielectricSpecular, baseColor.rgb, metallicRoughness.x);

    float3 diffuse = (1.0 - F) * indirectIrradiance * baseColor.rgb * (1.0 - metallicRoughness.x);
    float3 specular = F * indirectIrradiance;

    SurfaceProperties Surface;
    Surface.N = normal;
    Surface.V = normalize(ViewerPos - vsOutput.worldPos);
    Surface.NdotV = saturate(dot(Surface.N, Surface.V));
    Surface.c_diff = diffuse;
    Surface.c_spec = specular;
    Surface.roughness = metallicRoughness.y;
    Surface.alpha = metallicRoughness.y * metallicRoughness.y;
    Surface.alphaSqr = Surface.alpha * Surface.alpha;

    float3 uh = float3(0, 0, 0);
    if (UseAtlas) {
        //indirectIrradiance = SampleIrradiance(vsOutput.worldPos, normal);
        //uh = SampleIrradiance(vsOutput.worldPos, normal);
        uh = TestGI(vsOutput.worldPos, normal);
        // uh = SampleIrradiance2(vsOutput.worldPos, normal);
        // uh = sample_irradiance(vsOutput.worldPos, normal, ViewerPos);
        //uh = TestGI(vsOutput.worldPos, normal);
        //indirectIrradiance = TestGI(vsOutput.worldPos, normal);
        //indirectIrradiance *= occlusion;
        //float4(GammaCorrection(ACESToneMapping(colorAccum), 2.2f), baseColor.a);
        //return float4(indirectIrradiance, baseColor.a);
        //return float4(GammaCorrection(ACESToneMapping(indirectIrradiance), 2.2f), baseColor.a);
        //return float4(uh, 1.0);
    }


    float3 colorAccum = emissive;
    //colorAccum += diffuse + specular;
    float bias = calculateBias(normal, SunDirection);
    //float bias = CalculateSlopeBias(normal, normalize(SunDirection),
    //    0.0f, 0.001f);
    //bias = 0;
    float sunShadow = texSunShadow.SampleCmpLevelZero(shadowSampler, vsOutput.sunShadowCoord.xy, vsOutput.sunShadowCoord.z + bias);
    //sunShadow = 1;
    colorAccum = ShadeDirectionalLight(Surface, SunDirection, sunShadow * SunIntensity);
    //colorAccum += 
    // TODO: Shade each light using Forward+ tiles
    float3 bruv = ShadeDirectionalLight(Surface, SunDirection, sunShadow * SunIntensity);
    bruv += uh * baseColor.rgb * GIintensity;
    
    if (voxelPass) {
        // TODO: These are hardcoded values. It's assumed that the viewport size is 
        //       512 * 512, and that the 3D texture is 128 * 128 * 128. We could 
        //       make these CBV's if we want. 
        float2 uv = vsOutput.position.xy / viewWidth;  // normalized UV coords

        uint3 voxelCoords = GetVoxelCoords(vsOutput.position.xyz, uv, voxelTextureResolution, axis);

        if (voxelCoords.x == 0 && voxelCoords.y == 0 && voxelCoords.z == 0)
        {
            return baseColor; // Early exit
        }

        //TODO:
        //1. Parallelize ProbeUpdate - done
        //2. Call ProbeUpdate every 3rd frame
        //3. Atomics for VoxelAlbedo
        //4. New DirectLighting Func that literally just multiplies baseColor with dot product and Light color
        //5. Trilinear blending between probes

        //ImageAtomicRGBA8Avg(SDFGIVoxelAlbedo, voxelCoords, float4(saturate(colorAccum.xyz), 1.0));
        // ImageAtomicRGBA8Avg(SDFGIVoxelAlbedo, voxelCoords, float4(saturate(dot(Surface.N, SunDirection)) * baseColor.xyz * sunShadow * SunIntensity, 1.0));
        float w = (dot(SunDirection, normal) >= 0) ? 1 : 0;
        ImageAtomicRGBA8Avg(SDFGIVoxelAlbedo, voxelCoords, float4(baseColor.xyz * sunShadow * w * SunIntensity, 1.0));

        //SDFGIVoxelAlbedo[voxelCoords] = float4(colorAccum.xyz * Surface.NdotV, 1.0);
        //SDFGIVoxelAlbedo[voxelCoords] = float4(baseColor.xyz, 1.0);
        //SDFGIVoxelAlbedo[voxelCoords] = UnpackUIntToFloat4(PackFloat4ToUInt( float4(colorAccum.xyz * Surface.NdotV, 1.0) )  );
        //float4 bruh = float4(baseColor.xyz * Surface.NdotV, 1.0);
        //SDFGIVoxelAlbedo[voxelCoords] = bruh;

        SDFGIVoxelVoronoi[voxelCoords] = uint4(voxelCoords, 255);

        // we don't really care about the output. how to write into an empty framebuffer? 
        return baseColor;
    }
    
    // return float4(GammaCorrection(ACESToneMapping(SampleIrradiance(vsOutput.worldPos, normalize(vsOutput.normal))), 2.2f), 1.0f);
    if (UseAtlas) {
        //return float4(GammaCorrection(ACESToneMapping(colorAccum), 2.2f), baseColor.a);
        //return float4(GammaCorrection(ACESToneMapping(uh), 2.2f), baseColor.a);
        if (ShowGIOnly) {
            return float4(GammaCorrection(ACESToneMapping(uh), 2.2f), baseColor.a);
        }  else {
            return float4(GammaCorrection(ACESToneMapping(bruv), 2.2f), baseColor.a);
        }
    }
    return float4(GammaCorrection(ACESToneMapping(colorAccum), 2.2f), baseColor.a);
}