
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

//SamplerState bruhSampler : register(s24);

Texture2D<float4> baseColorTexture          : register(t0);
Texture2D<float3> metallicRoughnessTexture  : register(t1);
Texture2D<float1> occlusionTexture          : register(t2);
Texture2D<float3> emissiveTexture           : register(t3);
Texture2D<float3> normalTexture             : register(t4);



SamplerState baseColorSampler               : register(s10);
SamplerState metallicRoughnessSampler       : register(s11);
SamplerState occlusionSampler               : register(s12);
SamplerState emissiveSampler                : register(s13);
SamplerState normalSampler                  : register(s14);

//SamplerState bilinearSampler                : register(s11);

TextureCube<float3> radianceIBLTexture      : register(t10);
TextureCube<float3> irradianceIBLTexture    : register(t11);
Texture2D<float> texSSAO			        : register(t12);
Texture2D<float> texSunShadow			    : register(t13);
Texture2DArray<float4> IrradianceAtlas : register(t21);

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
    float3 GridSize;
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
    float Pad3;
    float Pad4;
    float Pad5;
};

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

float3 TestGI(
    float3 fragmentWorldPos,
    float3 normal
) {
    float3 localPos = (fragmentWorldPos - SceneMinBounds) / ProbeSpacing;
    bool hasNegative = any(localPos < 0.0);
    bool isOver = any(localPos > 1.0);
    if (hasNegative || isOver) {
        return float3(1, 0, 1);
    }

    //We are in our test grid now

    float3 probeCoord = floor(localPos); //[0,0,0] to [1,1,1] is possible here

    float3 interpWeight = frac(localPos);

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

    float4 irradiance[8];
    float weights[8];
    float weightSum = 0.0;
    float4 resultIrradiance = float4(0.0, 0.0, 0.0, 0.0);


    for (int i = 0; i < 1; ++i) {
        float3 probeWorldPos = SceneMinBounds + float3(probeIndices[i]) * ProbeSpacing;
        float3 dirToProbe = normalize(probeWorldPos - fragmentWorldPos);

        // Exclude probes behind the fragment.
        float normalDotDir = dot(normal, dirToProbe);
        if (normalDotDir <= 0.0) {
            weights[i] = 0.0;
            continue;
        }

        float distance = length(probeWorldPos - fragmentWorldPos);
        // Prevent near-zero distances.
        float distanceWeight = 1.0 / (distance * distance + 1.0e-4f);
        weights[i] = normalDotDir * distanceWeight;
        weightSum += weights[i];

        //float2 encodedDir = octEncode(normal);
        //float2 encodedDir = octEncode(dirToProbe);
        float2 encodedDir = float2(interpWeight.y, 0);

        

        //uint2 atlasCoord = uint2(GutterSize, GutterSize) + 
        //    probeIndices[i].xy * uint2(ProbeAtlasBlockResolution + GutterSize, ProbeAtlasBlockResolution + GutterSize);

        //float2 texCoord = atlasCoord.xy + uint2(
        //    (encodedDir.x * 0.5 + 0.5) * ProbeAtlasBlockResolution,
        //    (encodedDir.y * 0.5 + 0.5) * ProbeAtlasBlockResolution
        //);

        //texCoord = texCoord / float2(AtlasWidth, AtlasHeight);

        //irradiance[i] = IrradianceAtlas.SampleLevel(defaultSampler, float3(/* float2 UV */ texCoord,/* int Probe Slice Index */ probeIndices[i].z), 0);
        ////bilinearsampler



        //resultIrradiance += weights[i] * irradiance[i];
    }


    //if (weightSum > 0.0) {
    //    // Normalize irradiance.
    //    resultIrradiance /= weightSum;
    //}
    //else {
    //    resultIrradiance = float4(1.0, 0.0, 0.0, 1.0);
    //}
    float2 uv = float2(interpWeight.x, interpWeight.z);
    float2 texCoord = uint2(GutterSize, GutterSize) + uint2(uv.x * ProbeAtlasBlockResolution, uv.y * ProbeAtlasBlockResolution);
    texCoord /= float2(AtlasWidth, AtlasHeight);


        //atlasCoord.xy + uint2(
        //    //    (encodedDir.x * 0.5 + 0.5) * ProbeAtlasBlockResolution,
        //    //    (encodedDir.y * 0.5 + 0.5) * ProbeAtlasBlockResolution
    resultIrradiance = float4(interpWeight.x, interpWeight.z, 0, 1);
    resultIrradiance *= 5.0;

    //resultIrradiance = IrradianceAtlas.SampleLevel(defaultSampler, float3(/* float2 UV */ texCoord,/* int Probe Slice Index */ 0), 0);
    //resultIrradiance = IrradianceAtlas.Sample(baseColorSampler, float3(texCoord, 0));
    float depth = texSunShadow.SampleLevel(defaultSampler, texCoord * 80.0, -1).r;
    //resultIrradiance = float4(depth, depth, depth, 1);
    return resultIrradiance.rgb;







    //return float3(1, 0, 0);
}

float3 SampleIrradiance(
    float3 fragmentWorldPos,       
    float3 normal
) {
    float3 localPos = (fragmentWorldPos - SceneMinBounds) / ProbeSpacing;
    float3 probeCoord = floor(localPos); 

    float3 interpWeight = frac(localPos);

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

    float4 irradiance[8];
    float weights[8];
    float weightSum = 0.0;
    float4 resultIrradiance = float4(0.0, 0.0, 0.0, 0.0);

    for (int i = 0; i < 1; ++i) {
        float3 probeWorldPos = SceneMinBounds + float3(probeIndices[i]) * ProbeSpacing;
        float3 dirToProbe = normalize(probeWorldPos - fragmentWorldPos);

        // Exclude probes behind the fragment.
        float normalDotDir = dot(normal, dirToProbe);
        if (normalDotDir <= 0.0) {
            weights[i] = 0.0;
            continue;
        }

        float distance = length(probeWorldPos - fragmentWorldPos);
         // Prevent near-zero distances.
        float distanceWeight = 1.0 / (distance * distance + 1.0e-4f);
        weights[i] = normalDotDir * distanceWeight;
        weightSum += weights[i];

        float2 encodedDir = octEncode(normal);
        uint3 atlasCoord = probeIndices[i] * uint3(ProbeAtlasBlockResolution + GutterSize, ProbeAtlasBlockResolution + GutterSize, 1);
        float2 texCoord = atlasCoord.xy + uint2(
            (encodedDir.x * 0.5 + 0.5) * (ProbeAtlasBlockResolution - GutterSize),
            (encodedDir.y * 0.5 + 0.5) * (ProbeAtlasBlockResolution - GutterSize)
        );
        texCoord = texCoord / float2(AtlasWidth, AtlasHeight);

        irradiance[i] = IrradianceAtlas.SampleLevel(defaultSampler, float3(texCoord, probeIndices[i].z), 0);

        //resultIrradiance += weights[i] * irradiance[i];
        resultIrradiance = irradiance[i];
    }

    //if (weightSum > 0.0) {
    //    // Normalize irradiance.
    //    resultIrradiance /= weightSum;
    //} else {
    //    resultIrradiance = float4(0.0, 0.0, 0.0, 1.0);
    //}

    return resultIrradiance.rgb;
}

//[RootSignature(Renderer_RootSig)]
float4 main(VSOutput vsOutput) : SV_Target0
{
    // Load and modulate textures
    float4 baseColor = baseColorFactor * baseColorTexture.Sample(baseColorSampler, UVSET(BASECOLOR));
    float2 metallicRoughness = metallicRoughnessFactor * 
        metallicRoughnessTexture.Sample(metallicRoughnessSampler, UVSET(METALLICROUGHNESS)).bg;
    float occlusion = occlusionTexture.Sample(occlusionSampler, UVSET(OCCLUSION));
    float3 emissive = emissiveFactor * emissiveTexture.Sample(emissiveSampler, UVSET(EMISSIVE));
    float3 normal = ComputeNormal(vsOutput);

    SurfaceProperties Surface;
    Surface.N = normal;
    Surface.V = normalize(ViewerPos - vsOutput.worldPos);
    Surface.NdotV = saturate(dot(Surface.N, Surface.V));
    Surface.c_diff = baseColor.rgb * (1 - kDielectricSpecular) * (1 - metallicRoughness.x) * occlusion;
    Surface.c_spec = lerp(kDielectricSpecular, baseColor.rgb, metallicRoughness.x) * occlusion;
    Surface.roughness = metallicRoughness.y;
    Surface.alpha = metallicRoughness.y * metallicRoughness.y;
    Surface.alphaSqr = Surface.alpha * Surface.alpha;

    // Begin accumulating light starting with emissive
    float3 colorAccum = emissive;

#if 1
    float sunShadow = texSunShadow.SampleCmpLevelZero( shadowSampler, vsOutput.sunShadowCoord.xy, vsOutput.sunShadowCoord.z );
    colorAccum += ShadeDirectionalLight(Surface, SunDirection, sunShadow * SunIntensity);

    uint2 pixelPos = uint2(vsOutput.position.xy);
    float ssao = texSSAO[pixelPos];

    Surface.c_diff *= ssao;
    Surface.c_spec *= ssao;

#else
    //PBR
    uint2 pixelPos = uint2(vsOutput.position.xy);
    float ssao = texSSAO[pixelPos];

    Surface.c_diff *= ssao;
    Surface.c_spec *= ssao;

     //Add IBL
    colorAccum += Diffuse_IBL(Surface);
    colorAccum += Specular_IBL(Surface);
#endif

    // TODO: Shade each light using Forward+ tiles
    //
#if 0 //View normals
    return float4(0.5 * (normalize(vsOutput.normal) + float3(1.0, 1.0, 1.0)), 1.0);
#endif


    if (UseAtlas) {
        //return float4(GammaCorrection(ACESToneMapping(SampleIrradiance(vsOutput.worldPos, normalize(vsOutput.normal))), 2.2f), 1.0f);
        float3 col = TestGI(vsOutput.worldPos, normalize(vsOutput.normal));
        if (col.x == 1 && col.y == 0 && col.z == 1) {
            //return float4(col, 1.0);
            //return float4(GammaCorrection(ACESToneMapping(colorAccum), 2.2f), baseColor.a);
            return float4(1, 0, 1, 1);
            //return float4(colorAccum.rgb, baseColor.a);
        }
        //return float4(GammaCorrection(ACESToneMapping(col), 2.2f), baseColor.a);
        return float4(col.rgb, baseColor.a);
    } else {
        //return float4(GammaCorrection(ACESToneMapping(colorAccum), 2.2f), baseColor.a);
        //return float4(colorAccum.rgb, baseColor.a);
        return float4(baseColor);
        //return float4(colorAccum, baseColor.a);
    }
}
