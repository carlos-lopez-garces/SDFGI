# Signed Distance Field Global Illumination (SDFGI)

## 🚀 Overview

> **University of Pennsylvania, CIS 5650: GPU Programming and Architecture, Final Project**
> * Carlos Lopez Garces
>   + *LinkedIn/Website/Github* 
> * Logan Cho
>   + *LinkedIn/Website/Github*
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

This section details our implementation of SDFGI. In addition, this will serve as a run-down of the seminal paper, [Dynamic Diffuse Global Illumination by Majercik et. al.](https://jcgt.org/published/0008/02/01/)

### 🏁 SDF Generation & Ray-Marching

#### GPU Voxelization

#### 3D Jump Flood Algorithm

#### Ray-Marching the Scene

### 💡 Irradiance Probes

#### Probe Placement

#### Irradiance & Depth Atlas

##### Octahedral Encoding

#### Updating Probes

#### Sampling Probes

```
TODO: 
Voxel & SDF Representation
  GPU Voxelization
  3D Jump Flood Algorithm
  Ray-Marching
Irradiance Probes
  Probe Placement
  Irradiance & Depth Atlas
    Octahedral Encoding
  Probe Update
  Probe Sampling
```

## Performance Analysis

TODO: Any performance experiments, graphs etc.

## Credits
