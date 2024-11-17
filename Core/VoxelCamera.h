#pragma once
#include "Camera.h"
#include "VectorMath.h"

class VoxelCamera : public Math::BaseCamera
{
public:

	enum AXIS {
		X, // Implicitly assigned 0
		Y, // Implicitly assigned 1
		Z  // Implicitly assigned 2
	};

	VoxelCamera() {}

	void UpdateMatrix(AXIS axis);
};
