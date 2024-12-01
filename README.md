# Signed Distance Field Global Illumination (SDFGI)

## 🚀 Overview

> University of Pennsylvania, CIS 5650: GPU Programming and Architecture, Final Project
> * Carlos Lopez Garces
> * Logan Cho
> * Michael Mason
>   + [Personal Website](https://www.michaelmason.xyz/)

**Signed Distance Field Global Illumination (SDFGI) is a solution to real-time diffuse global illumination for games.**

SDFGI is a SDF-based variant of Dynamic Diffuse Global Illumination (DDGI). SDFGI takes advantage of ray-marching and, unlike SDFGI, does not need hardware accelerated ray-tracing. Our implementation is inspired by a similar DDGI approach in Godot 4.0, which was released in 2023 and pioneered by Godot's co-creator, Juan Linietsky. 

This is a DirectX12 implementation built on top of a starter project provided my Microsoft, MiniEngine, as part of their [DirectX Samples repo](https://github.com/microsoft/DirectX-Graphics-Samples/tree/master/MiniEngine). 

Features include: 
* Arbitrary glTF loading
* Dynamic lighting
* Arbitrary irradiance probe placement
* Cube-Map DDGI: A non-dynamic version of DDGI that serves as a reference implementation to compare to. 

## 📜 Implementation Details

This section details our implementation of SDFGI. In addition, this will serve as a run-down of the seminal paper, [Dynamic Diffuse Global Illumination by Majercik et. al.](https://jcgt.org/published/0008/02/01/)


