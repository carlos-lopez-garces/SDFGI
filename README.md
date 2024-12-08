![mainCoverPhoto](https://github.com/user-attachments/assets/e9a462d7-2068-4fba-8dce-e96ef2cd7070)
# Signed Distance Field Global Illumination (SDFGI)

> **University of Pennsylvania, CIS 5650: GPU Programming and Architecture, Final Project**
> * Carlos Lopez Garces
>   + [Personal Website](https://carlos-lopez-garces.github.io/) 
> * Logan Cho
>   + [Personal Website](https://www.logancho.com/)
> * Michael Mason
>   + [Personal Website](https://www.michaelmason.xyz/)

## 🚀 Overview

**Signed Distance Field Global Illumination (SDFGI) is a solution to real-time diffuse global illumination for games.**

SDFGI is a variant of Dynamic Diffuse Global Illumination (DDGI) that takes advantage of Signed Distance Fields (SDFs). Since SDFGI uses an SDF of to ray-march the scene, it does not require hardware accelerated ray-tracing, unlike DDGI. Our implementation is inspired by a similar DDGI approach in Godot 4.0, which was released in 2023 and pioneered by Godot's co-creator, Juan Linietsky. 

This is a DirectX12 implementation built on top of a starter project provided my Microsoft, MiniEngine, as part of their [DirectX Samples repo](https://github.com/microsoft/DirectX-Graphics-Samples/tree/master/MiniEngine). 

Features include: 
* Probe-based, non-RT global illumination effects, such as interreflections (color "bleeding") and ambient lighting
* Dynamic lighting: shading of the scene changes in response to changes to the direction of the sun directional light
* Arbitrary irradiance probe grid placement
* Cube-Map DDGI: A non-dynamic version of DDGI that serves as a reference implementation to compare our final results.
* Arbitrary glTF loading

## 🖼️ Gallery

<div align="center">
  <br>
  <img width="717" alt="image" src="https://github.com/user-attachments/assets/c83af0df-d13b-4e7c-8249-e6bfea015a21">
  <br>
  <p><i>Colors of curtains reflected off of the floor.</i></p>
</div>

<div align="center">
  <br>
  <img width="717" alt="image" src="https://github.com/user-attachments/assets/410fcfb3-b4bf-4b00-8156-afd8cc9fdd26">
  <br>
  <p><i>Blue from the curtain reflecting off of nearby pillar and floor.</i></p>
</div>

<div align="center">
  <br>
  <img width="717" alt="image" src="https://github.com/user-attachments/assets/b5f5b37e-97d3-4690-bef2-44b3b294ccb3">
  <br>
  <p><i>Colors from curtains reflecting off of nearby pillars and floor.</i></p>
</div>

<div align="center">
  <br>
  <img width="717" alt="image" src="https://github.com/user-attachments/assets/51e61097-b515-4e82-9156-63862205b8d5">
  <br>
  <p><i>Color reflected off of nearby banners.</i></p>
</div>

<div align="center">
  <br>
  <img width="717" alt="image" src="https://github.com/user-attachments/assets/cf85eee0-3550-4425-9124-a9a4fc814454">
  <br>
  <p><i>A wider angle of the scene.</i></p>
</div>

<div align="center">
  <br>
  <img width="717" alt="image" src="https://github.com/user-attachments/assets/8f7d451c-c9df-4f67-8087-b49893c79af5">
  <br>
  <p><i>A shot from behind the curtains. Simulated second-bounce GI in regions that aren't directly lit.</i></p>
</div>

## 📜 Implementation Details

This section details our implementation of SDFGI, but here is a basic overview: 

<div align="center">
  <br>
  <img width="717" alt="image" src="https://github.com/user-attachments/assets/1cdb5b46-686d-4579-9e24-617e85bfa414">
  <br>
  <p><i>Overview of SDFGI.</i></p>
</div>

SDFGI starts with a **direct lighting pass** of the scene. Using this direct lighting pass, we build an SDF (**SDF Pass**) that represents the scene in a voxelized form that can be ray-marched. Alternatively, we can do a **Cube Map Pass**, where we build cube maps for each probe. This is used for *Cube-Map DDGI* which was a reference implementation we used during development of SDFGI. 

In the **Probe Update Pass**, each probe casts rays around the scene, and at each hit, stores the irradiance color at that point into an irradiance atlas. To cast rays, we use the scene SDF to perform efficient ray-marching of the scene (and for *Cube Map DDGI*, the probes sample irradiance from its respective cube map). 

In the **Final Pass**, the scene is rendered again, but in this case, each fragment will now sample from the irradiance probes to shade it's final indirect lighting. 

### 🏁 SDF Pass

In the **SDF Pass**, a 3D SDF Texture is created that represents the scene. As an intermediate step, we perform a **GPU Voxelization** pass of the scene. This creates a 3D Voxel Albedo Texture that is used to sample irradiance. Additionally, an intermediate 3D Texture is created that is used as input to a **3D Jump Flood** Pass. Jump Flooding is a GPU flooding algorithm that can be modified to build a Distance Field texture, and thus we use this algorithm to produce the final SDF that can be used for ray-marching. 

<div align="center">
  <br>
  <img width="707" alt="image" src="https://github.com/user-attachments/assets/178ad06d-ba91-4075-aaf1-a5cf2da866e1">
  <br>
  <p><i>Overview of SDF Pass.</i></p>
</div>

#### GPU Voxelization

The **GPU Voxelizaiton** step voxelizes the scene by taking advantage of the GPU's rasterizer. We can do this by rendering the entire scene from three orthographics views in the x, y and z directions. In the fragment shader, we can use a combination of the x & y screen coordinates and the z-depth buffer to store voxels into a 3D texture. 

#### 3D Jump Flood Algorithm

The **3D Jump Flood Algorithm** step will generate an SDF by running multiple compute passes on an intermediate texture that has an encoded texture coordinate per pixel. After these passes, the final SDF texture is produced. 

#### Ray-Marching the Scene

The final SDF texture can be used to do sphere-marching. From a world space position, we can find the equivalent position in the SDF texture, and begin ray-marching. Since each pixel in the 3D texture represents a distance to the nearest geometry, the ray is marched at the sampled distance until it hits a pixel that has a distance of `0.0f`. Once we have a hit, we can sample the Voxel Albedo Texture at the same texture coordinate. Additionally we can also sample the ray depth. 

<div align="center">
  <br>
  <img width="557" alt="image" src="https://github.com/user-attachments/assets/ae80a5f0-9f5f-4ff4-b0b3-255ee068d615">
  <br>
  <p><i>Ray Marching the Scene.</i></p>
</div>

The scene can finally be raymarched. The resolution of the SDF is variable, but we mainly stick to either a 128x128x128 texture or a 512x512x512 texture. The global illumination is more accurate at higher samples. 

<div align="center">
  <br>
  <img width="743" alt="image" src="https://github.com/user-attachments/assets/1dd55144-1b20-4bda-a35a-684e1866f1cd">
  <br>
  <p><i>Ray-Marched SDF.</i></p>
</div>

### 🧊 Cube Map Pass (Cube Map DDGI)

### 💡 Irradiance Probes (Probe Update Pass & Final Pass)

Irradiance probes are a type of cache that can be sampled from during a final graphics pass to produce lighting in indirect areas. As per DDGI, these probes are computed and updated per-frame, so dynamic lighting is possible. These probes cover a volume in the world that covers the entire scene. While each probe is represented as a position in world-space, the irradiance information of each probe is actually stored in a 3D texture known as an Irradiance Atlas. 

#### Probe Placement

A rectangular, regularly spaced grid of probes spans the entire bounding box of the scene. Ideally, every room-like region of a scene should have at least one "cage" of probes (i.e. 8 adjacent probes forming a cube); this way, every fragment in the room can receive irradiance from every direction.

<div align="center">
  <br>
  <img width="557" alt="image" src="https://github.com/user-attachments/assets/f7cc9bad-3e68-4dff-831c-022680cd5d5b">
  <br>
  <p><i>Debug visualization of probe positions.</i></p>
</div>

The grid of probes is determined and built at load-time and its resolution cannot change dynamically at runtime.

#### Irradiance & Depth Atlas

##### Octahedral Encoding

<div align="center">
  <br>
  <img width="557" alt="image" src="https://github.com/user-attachments/assets/3f8967bc-7ab6-43a0-8be0-c7063a1d2a44">
  <br>
  <p><i>Octahedral Encoding of sphere normals to a unit square texture.</i></p>
</div>
<div align="center">
  <br>
  <img width="557" alt="image" src="https://github.com/user-attachments/assets/a938292d-683c-457b-a535-88549a2df4d3">
  <br>
  <p><i>Example of Atlas of 4 probes, each with sphere normals encoded as color to visualize the octahedral encoding pattern.</i></p>
</div>


#### Updating Probes (Probe Update Pass)

Probes are updated every frame to support dynamic lighting: if the lighting conditions change, e.g. the sun directional light changed direction, we want to rebuild the probes to capture the new irradiance levels surrounding them. Updating probes involves recomputing the irradiance and visibility atlas, i.e. for every texel belonging to the probe's 16x16 region in the atlas, we want obtain the canonical direction obtained by decoding the texel's coordinate; this direction is then used to sample the SDF's albedo to obtain a radiance value to write back to the texel; this also involves obtaining the distance to the corresponding hit in world space and write it back to the probe's region in the visibility atlas.

Since lighting may change drastically from frame to frame, flickering may be observed as a consequence of updating the irradiance probes so fast. To counter that effect, a lagging factor (called "hysteresis") is used to smoothly transition from the previous frame's probes to the new frame's probes. The DDGI paper explains that "hysteresis" is "the phenomenon in which the value of a physical property lags behind changes in the effect causing it".

<div align="center">
  <br>
  <img width="557" alt="image" src="https://github.com/user-attachments/assets/d69301d3-db7b-4737-91f1-a797e16e073c">
  <br>
  <p><i>How a probe captures irradiance from its surroundings. Source: Godot.</i></p>
</div>

#### Sampling Probes (Probe Final Pass)

To shade a fragment, we need to combine its color obtained from evaluating the direct lighting model and the diffuse irradiance around the fragment. The diffuse irradiance for a fragment is sampled from the 8 nearest probes (a "probe cage") that completely encloses it. This process of sampling involves:

1. Computing the grid space and world space positions of each of the probes in the cage, as well as the grid space position of the fragment.

2. For each of the 8 probes, compute the texture coordinate of the region in the atlas corresponding to the probe, encode octahedrally the normal vector of the fragment, and use the resulting texture coordinate to sample the irradiance and visibility atlases to obtain a radiance and depth values. A weight for each probe is computed, which takes into account the relative orientations of the fragment and the probes, as well as their distances.

3. Trilinearly interpolate the 8 irradiance samples to obtain a final irradiance sample.

<div align="center">
  <br>
  <img width="557" alt="image" src="https://github.com/user-attachments/assets/d877e62a-3d75-4c36-b20d-1947883d7815">
  <br>
  <p><i>Interpolating irradiance from probe. Source: Godot.</i></p>
</div>

## Performance Analysis

TODO: Any performance experiments, graphs etc.

## Credits

TODO: References here. 
