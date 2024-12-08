static const float PI = 3.14159265f;
static int MAX_MARCHING_STEPS = 512;

cbuffer ProbeData : register(b0) {
    float4x4 RandomRotation;         

    float3 GridSize;  
    float pad0;

    float3 ProbeSpacing;
    float pad1;

    float3 SceneMinBounds;
    float pad2;

    uint ProbeCount;
    uint ProbeAtlasBlockResolution;
    uint GutterSize;
    float MaxWorldDepth;

    bool SampleSDF;
};

cbuffer SDFData : register(b1) {
    // world space texture bounds
    float xmin;
    float xmax;
    float ymin;
    float ymax;
    float zmin;
    float zmax;
    // texture resolution
    float sdfResolution;
};

StructuredBuffer<float3> ProbePositions : register(t0);
Texture2DArray<float4> ProbeCubemapArray : register(t1);

RWTexture2DArray<float4> IrradianceAtlas : register(u0);
RWTexture2DArray<float2> DepthAtlas : register(u1);

RWTexture3D<uint4> AlbedoTex : register(u2);
RWTexture3D<float> SDFTex : register(u3);

SamplerState LinearSampler : register(s0);

// --- SDF Helper Functions ---

// assuming that the 3D texture covers a box (in world space) that:
//      * is centered at the origin
//      * Xbounds = [-2000, 2000]
//      * Ybounds = [-2000, 2000]
//      * Zbounds = [-2000, 2000]
float3 WorldSpaceToTextureSpace(float3 worldPos) {
    float3 texCoord = float3(0, 0, 0);

    // world coord to [0, 1] coords
    texCoord.x = (worldPos.x - xmin) / (xmax - xmin);
    texCoord.y = (worldPos.y - ymin) / (ymax - ymin);
    texCoord.z = (worldPos.z - zmin) / (zmax - zmin);

    // assuming a 128 * 128 * 128 texture, but we could make this dynamic
    // u' = u * (tmax - tmin) + tmin
    // where tmax == 127 and tmin == 0
    return texCoord * (sdfResolution - 1);
}

float3 TextureSpaceToWorldSpace(float3 texCoord) {
    // Texture space bounds.
    float tmin = 0.0;
    float tmax = sdfResolution - 1;

    // Normalize texture coordinates to [0, 1].
    float3 normCoord = texCoord / tmax;

    // Map normalized coordinates back to world space.
    float3 worldPos;
    worldPos.x = normCoord.x * (xmax - xmin) + xmin;
    worldPos.y = normCoord.y * (ymax - ymin) + ymin;
    worldPos.z = normCoord.z * (zmax - zmin) + zmin;

    return worldPos;
}

float computeFalloff(float dist, float dk) {
    return 1.0 / (1.0 + dk * dist);
}

float4 UnpackRGBA8(uint packedColor) {
    float4 color;
    color.r = ((packedColor >> 24) & 0xFF) / 255.0; // Extract red and normalize
    color.g = ((packedColor >> 16) & 0xFF) / 255.0; // Extract green and normalize
    color.b = ((packedColor >> 8) & 0xFF) / 255.0;  // Extract blue and normalize
    color.a = (packedColor & 0xFF) / 255.0;         // Extract alpha and normalize
    return color;
}

float4 SampleSDFAlbedo(float3 worldPos, float3 marchingDirection, out float3 worldHitPos) {
    float3 eye = WorldSpaceToTextureSpace(worldPos); 
    float test = 4.0f;
    // Ray March Code
    float start = 0;
    float depth = start;
    for (int i = 0; i < MAX_MARCHING_STEPS; i++) {
        int3 hit = (eye + depth * marchingDirection);
        if (any(hit > int3(sdfResolution - 1, sdfResolution - 1, sdfResolution - 1)) || any(hit < int3(0, 0, 0))) {
            return float4(0., 0., 0., 1.);
        }
        hit.y = sdfResolution - 1 - hit.y;
        hit.z = sdfResolution - 1 - hit.z;
        float dist = SDFTex[hit];
        if (dist == 0.f) {
            if (i == 0) {
                dist = test;
            }
            else {
                worldHitPos = TextureSpaceToWorldSpace(eye + depth * marchingDirection);
                return UnpackRGBA8(AlbedoTex[hit]) * computeFalloff(depth - start, 0.5f);
            }
        }
        depth += dist;
    }
    return float4(0., 0., 0., 1.);
}

// --- Atlas Helper Functions ---

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

int GetFaceIndex(float3 dir)
{
    float3 absDir = abs(dir);

    if (absDir.x > absDir.y && absDir.x > absDir.z)
    {
        // X component is largest
        return dir.x > 0 ? 0 : 1; // +X or -X
    }
    else if (absDir.y > absDir.x && absDir.y > absDir.z)
    {
        // Y component is largest
        return dir.y > 0 ? 2 : 3; // +Y or -Y
    }
    else
    {
        // Z component is largest
        return dir.z > 0 ? 4 : 5; // +Z or -Z
    }
}

float3 spherical_fibonacci(uint index, uint sample_count) {
    const float PHI = sqrt(5.0) * 0.5 + 0.5;
    float phi = 2.0 * PI * frac(index * (PHI - 1));
    float cos_theta = 1.0 - (2.0 * index + 1.0) / sample_count;
    float sin_theta = sqrt(1.0 - cos_theta * cos_theta);
    return float3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
}

float2 normalized_oct_coord(int2 fragCoord, int probe_side_length) {

    int probe_with_border_side = probe_side_length + 2;
    float2 octahedral_texel_coordinates = int2((fragCoord.x - 1) % probe_with_border_side, (fragCoord.y - 1) % probe_with_border_side);

    octahedral_texel_coordinates += float2(0.5f, 0.5f);
    octahedral_texel_coordinates *= (2.0f / float(probe_side_length));
    octahedral_texel_coordinates -= float2(1.0f, 1.0f);

    return octahedral_texel_coordinates;
}

float sign_not_zero(in float k) {
    return (k >= 0.0) ? 1.0 : -1.0;
}

float2 sign_not_zero2(in float2 v) {
    return float2(sign_not_zero(v.x), sign_not_zero(v.y));
}



float3 oct_decode(float2 o) {
    float3 v = float3(o.x, o.y, 1.0 - abs(o.x) - abs(o.y));
    if (v.z < 0.0) {
        v.xy = (1.0 - abs(v.yx)) * sign_not_zero2(v.xy);
    }
    return normalize(v);
}


//static const float2 offsets[5] = {
//    float2(0.15, 0.15),
//    float2(0.15, 0.85),
//    float2(0.85, 0.15),
//    float2(0.85, 0.85),
//    float2(0.5, 0.5)
//};

static const float2 offsets[36] = {
    float2(0.15, 0.15),
    float2(0.15, 0.3),
    float2(0.15, 0.45),
    float2(0.15, 0.6),
    float2(0.15, 0.75),
    float2(0.15, 0.9),

    float2(0.3, 0.15),
    float2(0.3, 0.3),
    float2(0.3, 0.45),
    float2(0.3, 0.6),
    float2(0.3, 0.75),
    float2(0.3, 0.9),

    float2(0.45, 0.15),
    float2(0.45, 0.3),
    float2(0.45, 0.45),
    float2(0.45, 0.6),
    float2(0.45, 0.75),
    float2(0.45, 0.9),

    float2(0.6, 0.15),
    float2(0.6, 0.3),
    float2(0.6, 0.45),
    float2(0.6, 0.6),
    float2(0.6, 0.75),
    float2(0.6, 0.9),

    float2(0.75, 0.15),
    float2(0.75, 0.3),
    float2(0.75, 0.45),
    float2(0.75, 0.6),
    float2(0.75, 0.75),
    float2(0.75, 0.9),

    float2(0.9, 0.15),
    float2(0.9, 0.3),
    float2(0.9, 0.45),
    float2(0.9, 0.6),
    float2(0.9, 0.75),
    float2(0.9, 0.9),
};
//
//static const float2 offsets[9] = {
//    float2(0.15, 0.15),
//    float2(0.15, 0.5),
//    float2(0.15, 0.85),
//
//    float2(0.5, 0.15),
//    float2(0.5, 0.85),
//    float2(0.5, 0.5),
//
//    float2(0.85, 0.15),
//    float2(0.85, 0.5),
//    float2(0.85, 0.85),
//};




// --- Shader Start ---

[numthreads(9, 9, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID, uint3 groupThreadID : SV_GroupThreadID) {
    //Each thread is a texel in the atlas
    int bruh = 9;
    uint probeIndex = (dispatchThreadID.x / bruh)
        + (dispatchThreadID.y / bruh) * GridSize.x
        + dispatchThreadID.z * GridSize.x * GridSize.y;
    if (probeIndex >= ProbeCount) return;

    float3 probePosition = ProbePositions[probeIndex].xyz;

    uint3 probeTexCoord = uint3(GutterSize, GutterSize, 0) + uint3(
        (dispatchThreadID.x / bruh) * (GutterSize),
        (dispatchThreadID.y / bruh) * (GutterSize),
        dispatchThreadID.z
    );
    probeTexCoord += uint3(dispatchThreadID.xy, 0);

    const uint sample_count = 1;

    float x = groupThreadID.x;
    float y = groupThreadID.y;
    //for (int s = 0; s < sample_count; s++) {
    float2 offset = float2(x / 8.0, y / 8.0);
    //float2 offset = float2(0, 0);

    //SPECIAL CASES FOR CORNERS, MIDPOINTS AND CENTER PIXELS!!!
    //for (int s = 0; s < sample_count; s++)
    {
            //float2 inputToDecode = float2(((float)x + 0.5f)  / ProbeAtlasBlockResolution, ((float)y + 0.5f) / ProbeAtlasBlockResolution);

            float2 inputToDecode = float2(((float)x + offset.x)  / ProbeAtlasBlockResolution, ((float)y + offset.y) / ProbeAtlasBlockResolution);
             //float2 inputToDecode = float2(((float)x)  / ProbeAtlasBlockResolution, ((float)y) / ProbeAtlasBlockResolution);
            //float2 inputToDecode = float2(((float)x + offsets[s].x) / ProbeAtlasBlockResolution, ((float)y + offsets[s].y) / ProbeAtlasBlockResolution);
            inputToDecode *= 2;
            inputToDecode -= float2(1.0, 1.0);

            //Expects input in [-1, 1] range
            float3 texelDirection = oct_decode(inputToDecode);

            float3 worldHitPos;
            float4 irradianceSample = SampleSDFAlbedo(probePosition, normalize(texelDirection), worldHitPos);
            IrradianceAtlas[probeTexCoord] = irradianceSample;

            //IrradianceAtlas[probeTexCoord] = float4(texelDirection * 0.5 + float3(0.5,0.5,0.5), 1);
    }
        //IrradianceAtlas[probeTexCoord] /= sample_count;
        //IrradianceAtlas[probeTexCoord] = float4( x / 8.0, y / 8.0, 0, 1) + float4(0.1,0.1,0.1,0);
        //IrradianceAtlas[probeTexCoord] = float4(1, 0, 0, 1);
}

//
//void main(uint3 dispatchThreadID : SV_DispatchThreadID) {
//    uint probeIndex = dispatchThreadID.x
//        + dispatchThreadID.y * GridSize.x
//        + dispatchThreadID.z * GridSize.x * GridSize.y;
//
//    if (probeIndex >= ProbeCount) return;
//
//    float3 probePosition = ProbePositions[probeIndex].xyz;
//
//    uint3 atlasCoord = uint3(GutterSize, GutterSize, 0) + uint3(
//        dispatchThreadID.x * (ProbeAtlasBlockResolution + GutterSize),
//        dispatchThreadID.y * (ProbeAtlasBlockResolution + GutterSize),
//        dispatchThreadID.z
//    );
//
//    //const uint sample_count = ProbeAtlasBlockResolution * ProbeAtlasBlockResolution;
//    const uint sample_count = 36;
//    for (uint x = 0; x < ProbeAtlasBlockResolution; ++x) {
//        for (uint y = 0; y < ProbeAtlasBlockResolution; ++y) {
//            int2 coord = int2(x, y);
//            uint3 probeTexCoord = atlasCoord + uint3(coord, 0.0f);
//
//            //float2 inputToDecode = float2(((float)x + 0.5f) / ProbeAtlasBlockResolution, ((float)y + 0.5f) / ProbeAtlasBlockResolution);
//            //inputToDecode *= 2;
//            //inputToDecode -= float2(1.0, 1.0);
//
//            ////Expects input in [-1, 1] range
//            //float3 texelDirection = oct_decode(inputToDecode);
//            //float weight = 1.0f;
//
//
//
//            //float3 worldHitPos;
//            //float4 irradianceSample = SampleSDFAlbedo(probePosition, normalize(texelDirection), worldHitPos);
//
//            //IrradianceAtlas[probeTexCoord] += irradianceSample;
//
//
//            for (int s = 0; s < sample_count; s++) {
//                float2 inputToDecode = float2(((float)x + offsets[s].x) / ProbeAtlasBlockResolution, ((float)y + offsets[s].y) / ProbeAtlasBlockResolution);
//                inputToDecode *= 2;
//                inputToDecode -= float2(1.0, 1.0);
//
//                //Expects input in [-1, 1] range
//                float3 texelDirection = oct_decode(inputToDecode);
//                float weight = 1.0f;
//
//
//
//                float3 worldHitPos;
//                float4 irradianceSample = SampleSDFAlbedo(probePosition, normalize(texelDirection), worldHitPos);
//
//                //float4 irradianceSample = SampleSDFAlbedo(probePosition, normalize(float3(1, 1, 1)), worldHitPos);
//                IrradianceAtlas[probeTexCoord] += irradianceSample;
//                //float worldDepth = min(length(worldHitPos - probePosition), MaxWorldDepth);
//                //DepthAtlas[probeTexCoord] = float2(worldDepth, worldDepth * worldDepth);
//            }
//            IrradianceAtlas[probeTexCoord] /= sample_count;
//
//#if 0
//            float2 o = float2(((float)x + 0.5f) / ProbeAtlasBlockResolution, ((float)y + 0.5f) / ProbeAtlasBlockResolution);
//            IrradianceAtlas[probeTexCoord] = float4(o, 0, 1);
//#endif
//#if 0
//            IrradianceAtlas[probeTexCoord] = float4(1, 0, 0, 1);
//#endif
//#if 0
//            if (SampleSDF) {
//                float3 worldHitPos;
//                float4 irradianceSample = SampleSDFAlbedo(probePosition, normalize(texelDirection), worldHitPos);
//#if 0
//                probePosition = float3(-400, 20, -400);
//#endif
//                //float4 irradianceSample = SampleSDFAlbedo(probePosition, normalize(float3(1, 1, 1)), worldHitPos);
//                IrradianceAtlas[probeTexCoord] = weight * irradianceSample;
//                float worldDepth = min(length(worldHitPos - probePosition), MaxWorldDepth);
//                DepthAtlas[probeTexCoord] = float2(worldDepth, worldDepth * worldDepth);
//            }
//            else {
//                int faceIndex = GetFaceIndex(dir);
//                uint textureIndex = probeIndex * 6 + faceIndex;
//                float4 irradianceSample = ProbeCubemapArray.SampleLevel(LinearSampler, float3(coord.xy * 0.5 + 0.5, textureIndex), 0);
//                IrradianceAtlas[probeTexCoord] = weight * irradianceSample;
//                DepthAtlas[probeTexCoord] = 1;
//            }
//#endif
//#if 0
//            if (probeIndex == 0) {
//                IrradianceAtlas[probeTexCoord] = float4(1, 0, 0, 1);
//            }
//            else if (probeIndex == 1) {
//                IrradianceAtlas[probeTexCoord] = float4(0, 1, 0, 1);
//            }
//            else if (probeIndex == 2) {
//                IrradianceAtlas[probeTexCoord] = float4(0, 0, 1, 1);
//            }
//            else if (probeIndex == 3) {
//                IrradianceAtlas[probeTexCoord] = float4(1, 0, 1, 1);
//            }
//            else if (probeIndex == 4) {
//                IrradianceAtlas[probeTexCoord] = float4(0, 1, 1, 1);
//            }
//            else if (probeIndex == 5) {
//                IrradianceAtlas[probeTexCoord] = float4(1, 1, 0, 1);
//            }
//            else if (probeIndex == 6) {
//                IrradianceAtlas[probeTexCoord] = float4(1, 1, 1, 1);
//            }
//            else if (probeIndex == 7) {
//                IrradianceAtlas[probeTexCoord] = float4(0, 0, 0, 1);
//            }
//#endif
//        }
//    }
//}