#include "pch.h"
#include "VoxelCamera.h"

using namespace Math;

// TODO: probably need params here that change the bounds
void VoxelCamera::UpdateMatrix(AXIS axis)
{
	// TODO: the orthographic frustum should be based on ??? something ??? (bounds of the scene? size of the cascade?)
	constexpr float DUMMY = 500;

	float right = DUMMY;
	float left = -DUMMY;
	float top = DUMMY;
	float bottom = -DUMMY;
	float _near = -2000;
	float _far = 2000;

	float rml = right - left;
	float rpl = right + left;
	float tmb = top - bottom;
	float tpb = top + bottom;
	float fmn = _far - _near;
	float fpn = _far + _near;

	// directions
	switch (axis) {
	case AXIS::X:
		SetEyeAtUp(Vector3(2000, 0, 0), Vector3(0, 0, 0), Vector3(0, 1, 0));
		break;
	case AXIS::Y:
		SetEyeAtUp(Vector3(0, DUMMY, 0), Vector3(0, 0, 0), Vector3(1, 0, 0));
		break;
	case AXIS::Z:
		SetEyeAtUp(Vector3(0, 0, DUMMY), Vector3(0, 0, 0), Vector3(0, 1, 0));
		break;
	default:
		ASSERT(false); 
		break;
	}

	// create an orthographic matrix
	// https://wikimedia.org/api/rest_v1/media/math/render/svg/8ea4e438d7439b8fa504fb53fd7fafd678007243
	Matrix4 ortho = Matrix4::MakeScale(Vector3(1., 1., 1.));
	{
		ortho.SetX(Vector4(2. / rml, 0, 0, 0));
		ortho.SetY(Vector4(0, 2. / tmb, 0, 0));
		ortho.SetZ(Vector4(0, 0, -2. / fmn, 0));
		ortho.SetW(Vector4(-(rpl / rml), -(tpb / tmb), -(fpn / fmn), 1.));
	}

	SetProjMatrix(ortho);
	Update();
}