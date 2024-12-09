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

Presentations: [Pitch](https://docs.google.com/presentation/d/1aPlUudL1580VITqtrAXmmnXsi4JR-WdlXJBNjOwY6qk/edit?usp=sharing) [Milestone 1](https://docs.google.com/presentation/d/1CGSyz1mFMZtE7p1p0P8-ub7I-UNBfNZd8faB8C6vZPY/edit?usp=sharing) [Milestone 2](https://docs.google.com/presentation/d/1MurpZTf0lUR05kxjy4_mHZ0qdXA8qLQ-06cROCB1KVk/edit?usp=sharing) [Milestone 3](https://docs.google.com/presentation/d/1VaAUuntPKr5uMi0Cq2ASDaPi3_IESDukNNXbSQGgHS8/edit#slide=id.p) [Final](https://docs.google.com/presentation/d/1bIjfXdzw9pElhEJ83sGUOgWKHLqTiwFmdMvlEGqkznM/edit?usp=sharing)

**Signed Distance Field Global Illumination (SDFGI) is a solution to real-time diffuse global illumination for games.**

SDFGI is a variant of Dynamic Diffuse Global Illumination (DDGI) that takes advantage of Signed Distance Fields (SDFs). Since SDFGI uses an SDF of to ray-march the scene, it does not require hardware accelerated ray-tracing, unlike DDGI. Our implementation is inspired by a similar DDGI approach in Godot 4.0, which was released in 2023 and pioneered by Godot's co-creator, Juan Linietsky. 

This is a DirectX12 implementation built on top of a starter project provided my Microsoft, MiniEngine, as part of their [DirectX Samples repo](https://github.com/microsoft/DirectX-Graphics-Samples/tree/master/MiniEngine). 

Features include: 
* Probe-based, non-RT global illumination effects, such as interreflections (color "bleeding") and ambient lighting
* Dynamic lighting: shading of the scene changes in response to changes to the direction of the sun directional light
* Dynamic objects: animated objects participate in the GI simulation
* Arbitrary irradiance probe grid placement
* Cube-Map DDGI: A non-dynamic version of DDGI that serves as a reference implementation to compare our final results.
* Arbitrary glTF loading

## 🖼️ Gallery: Sponza

<div align="center">
  <br>
  <img width="717" alt="image" src="https://github.com/user-attachments/assets/cd162189-022a-455a-8f84-6bea55d7b1c5">
  <br>
  <p><i>Green from the curtain reflecting off of nearby pillars, floor, and arched ceiling.</i></p>
</div>

<div align="center">
  <br>
  <img width="717" alt="image" src="https://github.com/user-attachments/assets/f1161c41-0033-4595-8e0e-85492d6e9d35">
  <br>
  <p><i>Blue from the curtain reflecting off of nearby pillars, floor, and arched ceiling.</i></p>
</div>

<div align="center">
  <br>
  <img width="717" alt="image" src="https://github.com/user-attachments/assets/add89436-16d9-43c5-8be4-0794c5570235">
  <br>
  <p><i>Red from the curtain reflecting off of nearby pillars, floor, and arched ceiling.</i></p>
</div>

<div align="center">
  <br>
  <img width="717" alt="image" src="https://github.com/user-attachments/assets/2498a5ae-a512-42ce-869a-8aae39ad37c1">
  <br>
  <p><i>Dynamic scene: walls reflect animated ball's color.</i></p>
</div>

## 🖼️ Gallery: San Miguel

![san_miguel](https://github.com/user-attachments/assets/09768a28-4f18-4592-aaeb-1f20239d3c87)

## 🖼️ Gallery: Japanese Street

![image](https://github.com/user-attachments/assets/e81e7b48-f8df-40f8-a2fb-584b6cc6ab50)


![image](https://github.com/user-attachments/assets/f2abeb35-8ab2-42ed-96a9-dc63524d8f8c)



## 🖼️ Gallery: Cornell Box with Sonic

## ⚙️ Configuration

The magnitude of the GI contribution to the final shaded color can be controlled using the `GI Intensity` slider (0,1).

| Low | Medium | High |
|--------------|--------------|--------------|
| ![Screenshot 2024-12-08 204222](https://github.com/user-attachments/assets/b18fd428-398b-46b5-b802-5c520fbed3b6) | ![Screenshot 2024-12-08 204304](https://github.com/user-attachments/assets/72161a84-587f-4822-81b9-9b216aefb683) | ![Screenshot 2024-12-08 204325](https://github.com/user-attachments/assets/f7719670-2b6e-4d69-8af1-b56c15922c73) |

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

The **3D Jump Flood Algorithm** step will generate an SDF by running multiple compute passes on an intermediate texture that has an encoded texture coordinate per pixel. After these passes, the final SDF texture is produced. Jump Flooding is a GPU flooding algorithm that was originally designed for textures in two-dimensions, and it can specifically be used to create Distance Fields & Voronoi Textures. It has seen many uses for games. For more information, see the [original paper by Rong & Tan.](https://www.comp.nus.edu.sg/~tants/jfa.html)

<div align="center">
  <br>
  <img width="557" alt="image" src="https://github.com/user-attachments/assets/745619b0-d21f-4d23-8e35-5271964041ce">
  <br>
  <p><i>7 Total Compute Passes to compute a 128 * 128 * 128 SDF Texture. Here is the evolution of a single slice of that texture.</i></p>
</div>


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
  <img width="557" alt="image" src="https://github.com/user-attachments/assets/d00b2781-a20d-4a17-ab37-5d74b63550e6">
  <br>
  <p><i>Probes cover the bounding box of the scene.</i></p>
</div>

<div align="center">
  <table>
    <tr>
      <td><img width="557" alt="image" src="https://github.com/user-attachments/assets/2adb22ae-9a03-4e10-91e7-516f0f763299"></td>
      <td><img width="557" alt="image" src="https://github.com/user-attachments/assets/c345fb08-3e84-427d-800a-c4aa9c4bbc04"></td>
    </tr>
  </table>
  <p><i>Each green quad is a probe.</i></p>
</div>

The grid of probes is determined and built at load-time and its resolution cannot change dynamically at runtime.

#### Irradiance & Visibility Atlas

The irradiance captured by a probe is encoded into a texture (see Octahedral Encoding). Since we have a 3D grid of probes, the octahedrally-encoded irradiance textures of all the probes are included in a series of atlas textures, one for each z-coordinate of the grid. To locate a probe's irradiance texture, we first locate the "slice" atlas that corresponds to its z-coordinate and then the texture coordinate in that atlas where its texture is.

In addition to the irradiance atlases, we use visibility atlases that are used to discard probes that are occluded from a fragment.

<table>
  <tr>
    <th>Irradiance Atlas for 2 z-slices</th>
    <th>Visibility Atlas for 2 z-slices</th>
  </tr>
  <tr>
    <td><img width="557" alt="image" src="https://github.com/user-attachments/assets/5ad0c4a8-c17f-44dc-831b-89cbde267f68"></td>
    <td><img width="557" alt="image" src="https://github.com/user-attachments/assets/ce7f0fa8-5c2e-42ba-92d2-d91427b1baa8"></td>
  </tr>
  <tr>
    <td><img width="557" alt="image" src="https://github.com/user-attachments/assets/da1260e9-c927-4334-ae45-0841f5d28a82"></td>
    <td><img width="557" alt="image" src="https://github.com/user-attachments/assets/ea20e582-4ec0-485a-9940-ebe95bb222c6"></td>
  </tr>
</table>


##### Octahedral Encoding

Octahedral mapping for irradiance works by projecting the spherical distribution of irradiance around a point (a probe) onto a 2D plane using an octahedral projection. The unit sphere, which contains irradiance values for all possible directions, is first split into an octahedron, with each of its eight triangular faces representing a portion of the sphere. These faces are then unfolded and laid flat onto a 2D texture. To sample irradiance for a given direction, the direction vector is normalized and projected onto the 2D octahedral map, where the UV coordinates are derived from the vector’s x, y, and z components. This mapping ensures a uniform distribution of sampling points across the sphere, minimizing distortions and artifacts. The irradiance values stored in the texture can then be filtered or interpolated efficiently, allowing for smooth and accurate directional irradiance sampling in real time.

<div align="center">
  <br>
  <img width="557" alt="image" src="https://github.com/user-attachments/assets/3f8967bc-7ab6-43a0-8be0-c7063a1d2a44">
  <br>
  <p><i>Octahedral Encoding of sphere normals to a unit square texture.</i></p>
</div>

To sample irradiance from an octahedral map, we start by normalizing the direction vector for which irradiance is required (typically the normal vector of a fragment). We then convert the normalized direction into a 2D UV coordinate using the octahedral projection formula. For a direction, the 2D coordinates are computed and then remapped to the texture space. Once the UV coordinate is obtained, use it to sample the irradiance value from the octahedral texture.

The following is an example of 4 of our octahedrally-encoded irradiance probes.

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
  <img width="300" alt="image" src="https://github.com/user-attachments/assets/d69301d3-db7b-4737-91f1-a797e16e073c">
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
  <img width="300" alt="image" src="https://github.com/user-attachments/assets/d877e62a-3d75-4c36-b20d-1947883d7815">
  <br>
  <p><i>Interpolating irradiance from probe. Source: Godot.</i></p>
</div>

The GI contribution is incorporated into the shading/illumination model on top of the direct illumination.

| DI | GI | DI + GI x Albedo |
|--------------|--------------|--------------|
| ![Screenshot 2024-12-08 225309](https://github.com/user-attachments/assets/9f72255d-a9d3-4644-a2c4-ed090866edf2) | ![Screenshot 2024-12-08 225329](https://github.com/user-attachments/assets/4dfb5e07-3d3d-48c7-93e0-ff55e45e07c2) | ![Screenshot 2024-12-08 225257](https://github.com/user-attachments/assets/376fa7e9-9172-43fa-86b5-db7037c43f82) |

## Performance Analysis

### Analysis: SDF Resolution

Here, we explore the impact of SDF resolutions (128, 256, 512) on FPS and frame time. The analysis is done for the Sponza scene, which is a medium-sized scene.

As the SDF resolution increases from 128 to 512, the FPS drops from 85 to 60, highlighting the increased computational and memory demands at higher resolutions. Frame time grows significantly with resolution, rising from 11.8 ms at 128 to 16.7 ms at 512. This indicates a linear-to-quadratic scaling in workload due to the higher sampling density.

<div align="center">
  <table>
    <tr>
      <th>SDF Resolution</th>
      <th>FPS</th>
      <th>Frame Time (ms)</th>
    </tr>
    <tr>
      <td>128</td>
      <td>85</td>
      <td>11.8</td>
    </tr>
    <tr>
      <td>256</td>
      <td>72</td>
      <td>13.9</td>
    </tr>
    <tr>
      <td>512</td>
      <td>60</td>
      <td>16.7</td>
    </tr>
  </table>
</div>

<div align="center">
  <br>
  <img width="300" alt="image" src="https://github.com/user-attachments/assets/f2990903-0bd8-4943-a6ba-0b0810d6570e">
  <br>
  <p><i>Impact of SDF resolution on framerate.</i></p>
</div>

### Analysis: Probe Grid Spacing (Probe Density)

Here, we explore the effect of varying probe grid spacings (50, 75, 100, 150, 200) on FPS and frame time. Probe grid spacing determines the density of probes in the scene, influencing both lighting quality and performance. The smaller the spacing, the more probes there are, which increases the size of each atlas slice (to fit more probes) as well as the number of slices. Spacing smaller than 50 leads to out-of-memory errors on our laptops.

As probe grid spacing increases, FPS steadily improves. At 50 spacing, the FPS is 60, while at 200 spacing, the FPS reaches 92. Larger spacings reduce the computational overhead of probe updates and sampling, with frame time dropping from 16.7 ms (50 spacing) to 10.9 ms (200 spacing).

<div align="center">
  <table>
    <tr>
      <th>Probe Grid Spacing</th>
      <th>FPS</th>
      <th>Frame Time (ms)</th>
    </tr>
    <tr>
      <td>50</td>
      <td>60</td>
      <td>16.7</td>
    </tr>
    <tr>
      <td>75</td>
      <td>68</td>
      <td>14.7</td>
    </tr>
    <tr>
      <td>100</td>
      <td>75</td>
      <td>13.3</td>
    </tr>
    <tr>
      <td>150</td>
      <td>85</td>
      <td>11.8</td>
    </tr>
    <tr>
      <td>200</td>
      <td>92</td>
      <td>10.9</td>
    </tr>
  </table>
</div>

<div align="center">
  <br>
  <img width="300" alt="image" src="https://github.com/user-attachments/assets/066d91cf-242d-40f9-a448-31d1bb34cbb6">
  <br>
  <p><i>Impact of probe density on framerate.</i></p>
</div>

### Analysis: Per-Probe Atlas Block Resolution

Here, we evaluate the impact of per-probe texture resolutions (8x8, 16x16, 32x32) on FPS and frame time. The per-probe texture resolution determines the coverage of the sphere of directions around the probe for which irradiance is captured; the higher the resolution, the more directions we are able to capture radiance for. 

As the per-probe texture resolution increases, the frame time grows significantly, from 11.8 ms for 8x8 textures to 16.1 ms for 32x32 textures. Higher texture resolutions result in fewer frames per second, with FPS dropping from 85 at 8x8 resolution to 62 at 32x32 resolution. This reflects the added computational cost of handling larger textures.

<div align="center">
  <table>
    <tr>
      <th>Per-Probe Texture Resolution</th>
      <th>FPS</th>
      <th>Frame Time (ms)</th>
    </tr>
    <tr>
      <td>8x8</td>
      <td>85</td>
      <td>11.8</td>
    </tr>
    <tr>
      <td>16x16</td>
      <td>75</td>
      <td>13.3</td>
    </tr>
    <tr>
      <td>32x32</td>
      <td>62</td>
      <td>16.1</td>
    </tr>
  </table>
</div>


<div align="center">
  <br>
  <img width="300" alt="image" src="https://github.com/user-attachments/assets/9f3e4d7f-3fa9-4c06-aba5-7a5255e4178f">
  <br>
  <p><i>Impact of per-probe texture resolution on frame time.</i></p>
</div>

## Credits

[Dynamic Diffuse Global Illumination with Ray-Traced Irradiance Fields by Majercik et. al. ](https://jcgt.org/published/0008/02/01/)

[Godot SDFGI Talk Slides by Juan Linietsky](https://www.docdroid.net/YNntL0e/godot-sdfgi-pdf)

[Jump Flooding in GPU with Applications to Voronoi Diagram and Distance Transform by Rong & Tan](https://www.comp.nus.edu.sg/~tants/jfa.html)

[Japanese street at night scene. (CC Attribution)](https://sketchfab.com/3d-models/japanese-street-at-night-fb1bdcd71a5544d699379d2d13dd1171)

[McGuire Computer Graphics Archive](https://casual-effects.com/data/)

[TheRealMJP Sun Direction Widget](https://github.com/TheRealMJP/DXRPathTracer)


