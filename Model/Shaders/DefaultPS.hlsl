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
    float GIIntensity;
    float BakedGIIntensity;
    int BakedSunShadow;

    int ProbeOffsetX;
    int ProbeOffsetY;
    int ProbeOffsetZ;
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

float3 ShadeDirectionalLight2(SurfaceProperties Surface, float3 L, float3 c_light, float4 baseColor)
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
    return Light.NdotL * c_light * (diffuse + specular) + baseColor.rgb;
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

float3 TestGI(
    float3 fragmentWorldPos,
    float3 normal
) {
    float3 localPos = (fragmentWorldPos - SceneMinBounds) / (float)ProbeSpacing;
    //float3 localPos = (fragmentWorldPos - SceneMinBounds);
    //localPos.x /= 600.0;
    //localPos.y /= 600.0;
    //localPos.z /= 600.0;

    bool hasNegative = any(localPos < 0.0);
    bool isOver = any(localPos > 1.0);
    if (hasNegative || isOver) {
        return float3(1, 1, 1);
    }

    //Double floor?....
    uint3 probeCoord = uint3(floor(floor(localPos)));

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

    for (int i = 0; i < 8; ++i) 
    //int i = 3;
    {
        float2 irradianceUV = GetUV(normal, probeIndices[i].xyz);
        uint slice_idx = (uint)floor(probeIndices[i].z);
    //    //return float3(irradianceUV, 0);

        float3 probeWorldPos = SceneMinBounds + float3(probeIndices[i]) * ProbeSpacing;
        float3 dirToProbe = normalize(probeWorldPos - fragmentWorldPos);
        float normalDotDir = dot(normal, dirToProbe);
        weights[i] = 1.0;
        if (normalDotDir <= 0.0) {
            weights[i] = 0.0;
            //continue;
        }

        resultIrradiance += weights[i] * IrradianceAtlas.SampleLevel(defaultSampler, float3(irradianceUV, slice_idx), 0);
    }

    return resultIrradiance.rgb;
}

// int3 world_to_grid_indices( float3 world_position ) {
//     float3 probe_grid_position = SceneMinBounds;
//     int3 probe_counts = int3(GridSize.x, GridSize.y, GridSize.z);
//     return clamp(
//         int3((world_position - probe_grid_position) / ProbeSpacing),
//         int3(0, 0, 0), 
//         probe_counts - int3(1, 1, 1)
//     );
// }

// float3 grid_indices_to_world_no_offsets( int3 grid_indices ) {
//     float3 probe_grid_position = SceneMinBounds;
//     return grid_indices * ProbeSpacing + probe_grid_position;
// }

// int probe_indices_to_index(in int3 probe_coords) {
//     int3 probe_counts = int3(GridSize.x, GridSize.y, GridSize.z);
//     return int(probe_coords.x + probe_coords.y * probe_counts.x + probe_coords.z * probe_counts.x * probe_counts.y);
// }

// float3 grid_indices_to_world( int3 grid_indices, int probe_index ) {
//     int3 probe_counts = int3(GridSize.x, GridSize.y, GridSize.z);
//     const int probe_counts_xy = probe_counts.x * probe_counts.y;
//     int2 probe_offset_sampling_coordinates = int2(probe_index % probe_counts_xy, probe_index / probe_counts_xy);
//     return grid_indices_to_world_no_offsets( grid_indices );
// }

// float sign_not_zero(in float k) {
//     return (k >= 0.0) ? 1.0 : -1.0;
// }

// float2 sign_not_zero2(in float2 v) {
//     return float2(sign_not_zero(v.x), sign_not_zero(v.y));
// }

// // Assumes that v is a unit vector. The result is an octahedral vector on the [-1, +1] square.
// float2 oct_encode(in float3 v) {
//     float l1norm = abs(v.x) + abs(v.y) + abs(v.z);
//     float2 result = v.xy * (1.0 / l1norm);
//     if (v.z < 0.0) {
//         result = (1.0 - abs(result.yx)) * sign_not_zero2(result.xy);
//     }
//     return result;
// }

// float2 get_probe_uv(float3 direction, int probe_index, int full_texture_width, int full_texture_height, int probe_side_length) {

//     // Get octahedral coordinates (-1,1)
//     const float2 octahedral_coordinates = oct_encode(normalize(direction));
//     // // TODO: use probe index for this.
//     const float probe_with_border_side = float(probe_side_length) + 2.0f;
//     const int probes_per_row = (full_texture_width) / int(probe_with_border_side);
//     // // Get probe indices in the atlas
//     int2 probe_indices = int2((probe_index % probes_per_row), 
//                                (probe_index / probes_per_row));
    
//     // // Get top left atlas texels
//     float2 atlas_texels = float2( probe_indices.x * probe_with_border_side, probe_indices.y * probe_with_border_side );
//     // // Account for 1 pixel border
//     atlas_texels += float2(1.0f,1.0f);
//     // // Move to center of the probe area
//     atlas_texels += float2(probe_side_length * 0.5f, probe_side_length * 0.5f);
//     // // Use octahedral coordinates (-1,1) to move between internal pixels, no border
//     atlas_texels += octahedral_coordinates * (probe_side_length * 0.5f);
//     // // Calculate final uvs
//     const float2 uv = atlas_texels / float2(float(full_texture_width), float(full_texture_height));
//     return uv;
// }

// float3 sample_irradiance( float3 world_position, float3 normal, float3 camera_position ) {
//     float self_shadow_bias = 0.3f;

//     const float3 Wo = normalize(camera_position.xyz - world_position);
//     // Bias vector to offset probe sampling based on normal and view vector.
//     const float minimum_distance_between_probes = 1.0f;
//     float3 bias_vector = (normal * 0.2f + Wo * 0.8f) * (0.75f * minimum_distance_between_probes) * self_shadow_bias;

//     float3 biased_world_position = world_position + bias_vector;

//     // Sample at world position + probe offset reduces shadow leaking.
//     int3 base_grid_indices = world_to_grid_indices(biased_world_position);
//     float3 base_probe_world_position = grid_indices_to_world_no_offsets( base_grid_indices );

//     // alpha is how far from the floor(currentVertex) position. on [0, 1] for each axis.
//     float3 alpha = clamp((biased_world_position - base_probe_world_position) , float3(0.0f,0.0f,0.0f), float3(1.0f,1.0f,1.0f));

//     float3  sum_irradiance = float3(0.0f,0.0f,0.0f);
//     float sum_weight = 0.0f;

//     int3 probe_counts = int3(GridSize.x, GridSize.y, GridSize.z);

//     for (int i = 0; i < 8; ++i) {
//         int3  offset = int3(i, i >> 1, i >> 2) & int3(1,1,1);
//         int3  probe_grid_coord = clamp(base_grid_indices + offset, int3(0,0,0), probe_counts - int3(1,1,1));
//         int probe_index = probe_indices_to_index(probe_grid_coord);

//         float3 probe_pos = grid_indices_to_world(probe_grid_coord, probe_index);

//         float3 trilinear = lerp(1.0 - alpha, alpha, offset);
//         float weight = 1.0;

//     //     if ( use_smooth_backface() ) {
//             // Computed without the biasing applied to the "dir" variable. 
//             // This test can cause reflection-map looking errors in the image
//             // (stuff looks shiny) if the transition is poor.
//             float3 direction_to_probe = normalize(probe_pos - world_position);

//             // The naive soft backface weight would ignore a probe when
//             // it is behind the surface. That's good for walls. But for small details inside of a
//             // room, the normals on the details might rule out all of the probes that have mutual
//             // visibility to the point. So, we instead use a "wrap shading" test below inspired by
//             // NPR work.

//             // The small offset at the end reduces the "going to zero" impact
//             // where this is really close to exactly opposite
//             const float dir_dot_n = (dot(direction_to_probe, normal) + 1.0) * 0.5f;
//             weight *= (dir_dot_n * dir_dot_n) + 0.2;
//     //     }

//         // Bias the position at which visibility is computed; this avoids performing a shadow 
//         // test *at* a surface, which is a dangerous location because that is exactly the line
//         // between shadowed and unshadowed. If the normal bias is too small, there will be
//         // light and dark leaks. If it is too large, then samples can pass through thin occluders to
//         // the other side (this can only happen if there are MULTIPLE occluders near each other, a wall surface
//         // won't pass through itself.)
//         float3 probe_to_biased_point_direction = biased_world_position - probe_pos;
//         float distance_to_biased_point = length(probe_to_biased_point_direction);
//         probe_to_biased_point_direction *= 1.0 / distance_to_biased_point;

//     //     // Visibility
//     //     if ( use_visibility() ) {

//             float2 depthUV = get_probe_uv(probe_to_biased_point_direction, probe_index, AtlasWidth, AtlasHeight, ProbeAtlasBlockResolution );
//             // float2 depthUV = GetUV(probe_to_biased_point_direction, probe_grid_coord);

//     //         vec2 visibility = textureLod(global_textures[nonuniformEXT(grid_visibility_texture_index)], uv, 0).rg;

//             float2 visibility = DepthAtlas.SampleLevel(defaultSampler, float3(depthUV, probe_grid_coord.z), 0).rg;


//             float mean_distance_to_occluder = visibility.x;

//             float chebyshev_weight = 1.0;
//             if (distance_to_biased_point > mean_distance_to_occluder) {
//                 // In "shadow"
//                 float variance = abs((visibility.x * visibility.x) - visibility.y);
//                 // http://www.punkuser.net/vsm/vsm_paper.pdf; equation 5
//                 // Need the max in the denominator because biasing can cause a negative displacement
//                 const float distance_diff = distance_to_biased_point - mean_distance_to_occluder;
//                 chebyshev_weight = variance / (variance + (distance_diff * distance_diff));
                
//                 // Increase contrast in the weight
//                 chebyshev_weight = max((chebyshev_weight * chebyshev_weight * chebyshev_weight), 0.0f);
//             }

//     //         // Avoid visibility weights ever going all of the way to zero because when *no* probe has
//     //         // visibility we need some fallback value.
//             chebyshev_weight = max(0.05f, chebyshev_weight);
//             weight *= chebyshev_weight;
//     //     }

//         // Avoid zero weight
//         weight = max(0.000001, weight);

//         // A small amount of light is visible due to logarithmic perception, so
//         // crush tiny weights but keep the curve continuous
//         const float crushThreshold = 0.2f;
//         if (weight < crushThreshold) {
//             weight *= (weight * weight) * (1.f / (crushThreshold * crushThreshold));
//         }

//         float2 uv = get_probe_uv(normal, probe_index, AtlasWidth, AtlasHeight, ProbeAtlasBlockResolution );
//         // float2 uv = GetUV(normal, probe_grid_coord);

//     //     vec3 probe_irradiance = textureLod(global_textures[nonuniformEXT(grid_irradiance_output_index)], uv, 0).rgb;
//         float3 probe_irradiance = IrradianceAtlas.SampleLevel(defaultSampler, float3(uv, probe_grid_coord.z), 0).rgb;

//     //     if ( use_perceptual_encoding() ) {
//             // probe_irradiance = pow(probe_irradiance, float3(0.5f * 5.0f,0.5f * 5.0f,0.5f * 5.0f));
//     //     }

//         // Trilinear weights
//         weight *= trilinear.x * trilinear.y * trilinear.z + 0.001f;

//         sum_irradiance += weight * probe_irradiance;
//         sum_weight += weight;
//     }

//     float3 net_irradiance = sum_irradiance / sum_weight;

//     // if ( use_perceptual_encoding() ) {
//     //     net_irradiance = net_irradiance * net_irradiance;
//     // }

//     float3 irradiance = 0.5f * PI * net_irradiance * 0.95f;

//     return irradiance;
// }

// float3 SampleIrradiance2(
//     float3 fragmentWorldPos,       
//     float3 normal
// ) {
//     float3 world_position = fragmentWorldPos;
//     float self_shadow_bias = 0.3f;
//     const float3 Wo = normalize(ViewerPos.xyz - fragmentWorldPos);
//     // Bias vector to offset probe sampling based on normal and view vector.
//     const float minimum_distance_between_probes = 1.0f;
//     float3 bias_vector = (normal * 0.2f + Wo * 0.8f) * (0.75f * minimum_distance_between_probes) * self_shadow_bias;
//     float3 biased_world_position = fragmentWorldPos + bias_vector;
//     // Sample at world position + probe offset reduces shadow leaking.
//     int3 base_grid_indices = world_to_grid_indices(biased_world_position);
//     float3 base_probe_world_position = grid_indices_to_world_no_offsets( base_grid_indices );
//     // alpha is how far from the floor(currentVertex) position. on [0, 1] for each axis.
//     float3 alpha = clamp((biased_world_position - base_probe_world_position) , float3(0.0f,0.0f,0.0f), float3(1.0f,1.0f,1.0f));
//     float3  sum_irradiance = float3(0.0f,0.0f,0.0f);
//     float sum_weight = 0.0f;
//     int3 probe_counts = int3(GridSize.x, GridSize.y, GridSize.z);

//     float3 localPos = (fragmentWorldPos - SceneMinBounds) / ProbeSpacing;
//     uint3 probeCoord = uint3(floor(floor(localPos))); 

//     float3 interpWeight = frac(localPos);

//     uint3 probeIndices[8] = {
//         uint3(probeCoord),
//         uint3(probeCoord + float3(1, 0, 0)),
//         uint3(probeCoord + float3(0, 1, 0)),
//         uint3(probeCoord + float3(1, 1, 0)),
//         uint3(probeCoord + float3(0, 0, 1)),
//         uint3(probeCoord + float3(1, 0, 1)),
//         uint3(probeCoord + float3(0, 1, 1)),
//         uint3(probeCoord + float3(1, 1, 1))
//     };

//     // float4 irradiance[8];
//     float weights[8];
//     float weightSum = 0.0;
//     float4 resultIrradiance = float4(0.0, 0.0, 0.0, 0.0);

//     for (int i = 0; i < 8; ++i) {
//         int3  offset = int3(i, i >> 1, i >> 2) & int3(1,1,1);
//         int3  probe_grid_coord = clamp(base_grid_indices + offset, int3(0,0,0), probe_counts - int3(1,1,1));
//         int probe_index = probe_indices_to_index(probe_grid_coord);

//         float3 probe_pos = grid_indices_to_world(probe_grid_coord, probe_index);

//         float3 trilinear = lerp(1.0 - alpha, alpha, offset);
//         float weight = 1.0;

//     //     if ( use_smooth_backface() ) {
//             // Computed without the biasing applied to the "dir" variable. 
//             // This test can cause reflection-map looking errors in the image
//             // (stuff looks shiny) if the transition is poor.
//             float3 direction_to_probe = normalize(probe_pos - world_position);

//             // The naive soft backface weight would ignore a probe when
//             // it is behind the surface. That's good for walls. But for small details inside of a
//             // room, the normals on the details might rule out all of the probes that have mutual
//             // visibility to the point. So, we instead use a "wrap shading" test below inspired by
//             // NPR work.

//             // The small offset at the end reduces the "going to zero" impact
//             // where this is really close to exactly opposite
//             const float dir_dot_n = (dot(direction_to_probe, normal) + 1.0) * 0.5f;
//             weight *= (dir_dot_n * dir_dot_n) + 0.2;
//     //     }

//         // Bias the position at which visibility is computed; this avoids performing a shadow 
//         // test *at* a surface, which is a dangerous location because that is exactly the line
//         // between shadowed and unshadowed. If the normal bias is too small, there will be
//         // light and dark leaks. If it is too large, then samples can pass through thin occluders to
//         // the other side (this can only happen if there are MULTIPLE occluders near each other, a wall surface
//         // won't pass through itself.)
//         float3 probe_to_biased_point_direction = biased_world_position - probe_pos;
//         float distance_to_biased_point = length(probe_to_biased_point_direction);
//         probe_to_biased_point_direction *= 1.0 / distance_to_biased_point;

//     //     // Visibility
//     //     if ( use_visibility() ) {

//             float2 depthUV = GetUV(direction_to_probe, probeIndices[i]);
//             float2 visibility = DepthAtlas.SampleLevel(defaultSampler, float3(depthUV, probeIndices[i].z), 0).rg;

//             float mean_distance_to_occluder = visibility.x;

//             float chebyshev_weight = 1.0;
//             if (distance_to_biased_point > mean_distance_to_occluder) {
//                 // In "shadow"
//                 float variance = abs((visibility.x * visibility.x) - visibility.y);
//                 // http://www.punkuser.net/vsm/vsm_paper.pdf; equation 5
//                 // Need the max in the denominator because biasing can cause a negative displacement
//                 const float distance_diff = distance_to_biased_point - mean_distance_to_occluder;
//                 chebyshev_weight = variance / (variance + (distance_diff * distance_diff));
                
//                 // Increase contrast in the weight
//                 chebyshev_weight = max((chebyshev_weight * chebyshev_weight * chebyshev_weight), 0.0f);
//             }

//     //         // Avoid visibility weights ever going all of the way to zero because when *no* probe has
//     //         // visibility we need some fallback value.
//             chebyshev_weight = max(0.05f, chebyshev_weight);
//             weight *= chebyshev_weight;
//     //     }

//         // Avoid zero weight
//         weight = max(0.000001, weight);

//         // A small amount of light is visible due to logarithmic perception, so
//         // crush tiny weights but keep the curve continuous
//         const float crushThreshold = 0.2f;
//         if (weight < crushThreshold) {
//             weight *= (weight * weight) * (1.f / (crushThreshold * crushThreshold));
//         }

//         // float2 uv = get_probe_uv(normal, probe_index, AtlasWidth, AtlasHeight, ProbeAtlasBlockResolution );
//         // float2 uv = GetUV(normal, probe_grid_coord);

//     //     vec3 probe_irradiance = textureLod(global_textures[nonuniformEXT(grid_irradiance_output_index)], uv, 0).rgb;
//         // float3 probe_irradiance = IrradianceAtlas.SampleLevel(defaultSampler, float3(uv, probe_grid_coord.z), 0).rgb;

//         float2 uv = GetUV(normal, probeIndices[i]);
//         //return float3(irradianceUV, 0);
//         float3 probe_irradiance = IrradianceAtlas.SampleLevel(defaultSampler, float3(uv, probeIndices[i].z), 0).rgb;

//     //     if ( use_perceptual_encoding() ) {
//             // probe_irradiance = pow(probe_irradiance, float3(0.5f * 5.0f,0.5f * 5.0f,0.5f * 5.0f));
//     //     }

//         // Trilinear weights
//         weight *= trilinear.x * trilinear.y * trilinear.z + 0.001f;

//         sum_irradiance += weight * probe_irradiance;
//         sum_weight += weight;
//     }

//     float3 net_irradiance = sum_irradiance / sum_weight;

//     // if ( use_perceptual_encoding() ) {
//     //     net_irradiance = net_irradiance * net_irradiance;
//     // }

//     float3 irradiance = 0.5f * PI * net_irradiance * 0.95f;

//     return irradiance;
// }

float3 SampleIrradiance(
    float3 fragmentWorldPos,       
    float3 normal
) {
    float3 localPos = (fragmentWorldPos - SceneMinBounds) / ProbeSpacing;
    uint3 probeCoord = uint3(floor(floor(localPos))); 

    float3 interpWeight = frac(localPos);

    int xOff = ProbeOffsetX;
    int yOff = ProbeOffsetY;
    int zOff = ProbeOffsetZ;

    uint3 probeIndices[8] = {
        uint3(probeCoord + uint3(1+xOff, 0+yOff, 0+zOff)),
        uint3(probeCoord + uint3(1+xOff, 0+yOff, 0+zOff)),
        uint3(probeCoord + uint3(0+xOff, 1+yOff, 0+zOff)),
        uint3(probeCoord + uint3(1+xOff, 1+yOff, 0+zOff)),
        uint3(probeCoord + uint3(0+xOff, 0+yOff, 1+zOff)),
        uint3(probeCoord + uint3(1+xOff, 0+yOff, 1+zOff)),
        uint3(probeCoord + uint3(0+xOff, 1+yOff, 1+zOff)),
        uint3(probeCoord + uint3(1+xOff, 1+yOff, 1+zOff))
    };

    float4 irradiance[8];
    float weights[8];
    float weightSum = 0.0;
    float4 resultIrradiance = float4(0.0, 0.0, 0.0, 0.0);

    for (int i = 0; i < 8; ++i) {

        float2 irradianceUV = GetUV(normal, probeIndices[i]);
        //return float3(irradianceUV, 0);
        irradiance[i] = IrradianceAtlas.SampleLevel(defaultSampler, float3(irradianceUV, probeIndices[i].z), 0);

        float3 probeWorldPos = SceneMinBounds + float3(probeIndices[i]) * ProbeSpacing;
        float3 dirToProbe = normalize(probeWorldPos - fragmentWorldPos);

        // Exclude probes behind the fragment.
        float normalDotDir = dot(normal, dirToProbe);
        if (normalDotDir <= 0.0) {
            weights[i] = 0.0;
            continue;
        }

        float distance = max(1, length(probeWorldPos - fragmentWorldPos));
         // Prevent near-zero distances.
        float distanceWeight = 1.0 / (pow(distance, 6) + 1.0e-4f);
        weights[i] = normalDotDir * distanceWeight;

        float2 depthUV = GetUV(dirToProbe, probeIndices[i]);
        // visibility.r is world-space distance to the nearest occluder.
        // visibility.g is the squared distance to the nearest occluder.
        float2 visibility = DepthAtlas.SampleLevel(defaultSampler, float3(depthUV, probeIndices[i].z), 0).rg;

        float meanDistanceToOccluder = visibility.x;
        float chebyshevWeight = 1.0;
        if (distance < meanDistanceToOccluder) {
            // In shadow.
            float variance = abs((visibility.x * visibility.x) - visibility.y);
            const float distanceDiff = distance - meanDistanceToOccluder;
            chebyshevWeight = variance / (variance + (distanceDiff * distanceDiff));
            
            // Increase contrast in the weight.
            chebyshevWeight = max((chebyshevWeight * chebyshevWeight * chebyshevWeight), 0.0f);
            chebyshevWeight = 0.1;
        }

        // From Vulkan: Avoid visibility weights ever going all of the way to zero because when
        // *no* probe has visibility we need some fallback value.
        // chebyshevWeight = max(0.05f, chebyshevWeight);
        // weights[i] *= chebyshevWeight;

        weightSum += weights[i];

        resultIrradiance += weights[i] * irradiance[i];
    }

    if (weightSum > 0.0) {
        // Normalize irradiance.
        resultIrradiance /= weightSum;
    } else {
        resultIrradiance = float4(0.0, 0.0, 0.0, 1.0);
    }

    return resultIrradiance.rgb;
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
    // val.rgb *= 255.0f;                // Optimize following calculations
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
    if (UseAtlas) {
        //indirectIrradiance = SampleIrradiance(vsOutput.worldPos, normal);
        indirectIrradiance = SampleIrradiance(vsOutput.worldPos, normal);
        // indirectIrradiance = SampleIrradiance2(vsOutput.worldPos, normal);
        // indirectIrradiance = sample_irradiance(vsOutput.worldPos, normal, ViewerPos);
        //indirectIrradiance = TestGI(vsOutput.worldPos, normal);
        //indirectIrradiance *= occlusion;
        //float4(GammaCorrection(ACESToneMapping(colorAccum), 2.2f), baseColor.a);
        //return float4(indirectIrradiance, baseColor.a);
        //return float4(GammaCorrection(ACESToneMapping(indirectIrradiance), 2.2f), baseColor.a);
    }

    SurfaceProperties Surface;
    Surface.N = normal;
    Surface.V = normalize(ViewerPos - vsOutput.worldPos);
    Surface.NdotV = saturate(dot(Surface.N, Surface.V));
    Surface.c_diff = baseColor.rgb * (1 - kDielectricSpecular) * (1 - metallicRoughness.x) * occlusion;
    Surface.c_spec = lerp(kDielectricSpecular, baseColor.rgb, metallicRoughness.x) * occlusion;
    Surface.roughness = metallicRoughness.y;
    Surface.alpha = metallicRoughness.y * metallicRoughness.y;
    Surface.alphaSqr = Surface.alpha * Surface.alpha;

    float3 colorAccum = emissive;
    float sunShadow = texSunShadow.SampleCmpLevelZero(shadowSampler, vsOutput.sunShadowCoord.xy, vsOutput.sunShadowCoord.z);
    colorAccum += ShadeDirectionalLight(Surface, SunDirection, sunShadow * SunIntensity * indirectIrradiance);
    if (UseAtlas) {
        if (sunShadow > 0.0f) {
            colorAccum += indirectIrradiance * baseColor.rgb;
        } else {
            colorAccum += GIIntensity * baseColor.rgb;
        }
    } 

    // TODO: Shade each light using Forward+ tiles
    
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

        // TODO: using baseColor for debug purposes
        float bakedGIIntensity = 0.3f;
        if (sunShadow > 0.0f) {
            bakedGIIntensity = 0.3f;
        } else {
            sunShadow = 0.1f;
        }
        colorAccum = ShadeDirectionalLight2(Surface, SunDirection, sunShadow * SunIntensity, bakedGIIntensity*baseColor);
        ImageAtomicRGBA8Avg(SDFGIVoxelAlbedo, voxelCoords, float4(saturate(colorAccum), 1.0));
        //SDFGIVoxelAlbedo[voxelCoords] = float4(baseColor.xyz, 1.0);
        SDFGIVoxelVoronoi[voxelCoords] = uint4(voxelCoords, 255);

        // we don't really care about the output. how to write into an empty framebuffer? 
        return baseColor;
    }
    
    // return float4(GammaCorrection(ACESToneMapping(SampleIrradiance(vsOutput.worldPos, normalize(vsOutput.normal))), 2.2f), 1.0f);
    return float4(GammaCorrection(ACESToneMapping(colorAccum), 2.2f), baseColor.a);
}
