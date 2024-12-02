![image](https://github.com/user-attachments/assets/eb7d2ecf-490f-4916-993f-1ea53590ed7e)
# Signed Distance Field Global Illumination (SDFGI)

## 🚀 Overview

> **University of Pennsylvania, CIS 5650: GPU Programming and Architecture, Final Project**
> * Carlos Lopez Garces
>   + *LinkedIn/Website/Github* 
> * Logan Cho
>   + [Personal Website](https://www.logancho.com/)
> * Michael Mason
>   + [Personal Website](https://www.michaelmason.xyz/)

**Signed Distance Field Global Illumination (SDFGI) is a solution to real-time diffuse global illumination for games.**

SDFGI is a variant of Dynamic Diffuse Global Illumination (DDGI) that takes advantage of Signed Distance Fields (SDFs). Since SDFGI uses an SDF of to ray-march the scene, it does not require hardware accelerated ray-tracing, unlike DDGI. Our implementation is inspired by a similar DDGI approach in Godot 4.0, which was released in 2023 and pioneered by Godot's co-creator, Juan Linietsky. 

This is a DirectX12 implementation built on top of a starter project provided my Microsoft, MiniEngine, as part of their [DirectX Samples repo](https://github.com/microsoft/DirectX-Graphics-Samples/tree/master/MiniEngine). 

Features include: 
* Arbitrary glTF loading
* Dynamic lighting
* Arbitrary irradiance probe placement
* Cube-Map DDGI: A non-dynamic version of DDGI that serves as a reference implementation to compare our final results.

## 🖼️ Gallery

TODO: Cool Renders & Videos here

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

<div align="center">
  <br>
  <img width="707" alt="image" src="https://github.com/user-attachments/assets/178ad06d-ba91-4075-aaf1-a5cf2da866e1">
  <br>
  <p><i>Overview of SDF Pass.</i></p>
</div>

#### GPU Voxelization

#### 3D Jump Flood Algorithm

#### Ray-Marching the Scene

<div align="center">
  <br>
  <img width="557" alt="image" src="https://github.com/user-attachments/assets/ae80a5f0-9f5f-4ff4-b0b3-255ee068d615">
  <br>
  <p><i>Ray Marching the Scene.</i></p>
</div>

### 🧊 Cube Map Pass (Cube Map DDGI)

### 💡 Irradiance Probes (Probe Update Pass & Final Pass)

Irradiance probes are a type of cache that can be sampled from during a final graphics pass to produce lighting in indirect areas. As per DDGI, these probes are computed and updated per-frame, so dynamic lighting is possible. These probes cover a volume in the world that covers the entire scene. While each probe is represented as a position in world-space, the irradiance information of each probe is actually stored in a 3D texture known as an Irradiance Atlas. 

#### Probe Placement

#### Irradiance & Depth Atlas

##### Octahedral Encoding

#### Updating Probes (Probe Update Pass)

#### Sampling Probes (Probe Final Pass)

## Performance Analysis

TODO: Any performance experiments, graphs etc.

## Credits

## Markdown templates (TODO: DELETE ME)

Side-by-side images with a caption:

<div align="center">
  <br>
  <img src="https://github.com/user-attachments/assets/47875c71-d32f-45c6-aa0c-2ca4a2e334ff" height=200px>
  <img src="https://github.com/user-attachments/assets/df87cb5e-ffd1-490d-ba86-0f7535a2db38" height=200px>
  <p><i>Linear scaling vs Logarithmic scaling</i></p>
  <br>
</div>

Single Image with a caption:

<div align="center">
  <br>
  <img src="https://github.com/user-attachments/assets/47875c71-d32f-45c6-aa0c-2ca4a2e334ff" height=200px>
  <br>
  <p><i>Linear scaling vs Logarithmic scaling</i></p>
</div>

Code block with syntax highlighting code: 

```c++
int main() {
  std::cout << "hello there" << std::endl;
  return 0; 
}
```

Hide/Show drop down menu:

<details>
<div align="center">
  <br>
  <img src="https://github.com/user-attachments/assets/47875c71-d32f-45c6-aa0c-2ca4a2e334ff" height=200px>
  <br>
  <p><i>Linear scaling vs Logarithmic scaling</i></p>
</div>
</details>

Info blocks: 

> [!NOTE]  
> Highlights information that users should take into account, even when skimming.

> [!TIP]
> Optional information to help a user be more successful.

> [!IMPORTANT]  
> Crucial information necessary for users to succeed.

> [!WARNING]  
> Critical content demanding immediate user attention due to potential risks.

> [!CAUTION]
> Negative potential consequences of an action.
