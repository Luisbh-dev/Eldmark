// Common utilities for the hit effect shaders (ART-09).
// Included with: #include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

// Fast out and slowing at the end: 1 - (1 - t)^3. Good for the burst of a flash or a ring.
float vfx_ease_out(float t) {
	float u = 1.0 - clamp(t, 0.0, 1.0);
	return 1.0 - u * u * u;
}

// 2D rotation by [angle] radians.
mat2 vfx_rot(float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return mat2(vec2(c, s), vec2(-s, c));
}

// Coordinates inside cell [frame] of an atlas of [h_frames] x [v_frames] cells.
vec2 vfx_atlas_uv(vec2 uv, float frame, int h_frames, int v_frames) {
	float total = float(h_frames * v_frames);
	float index = mod(floor(frame), total);
	float col = mod(index, float(h_frames));
	float row = floor(index / float(h_frames));
	return (uv + vec2(col, row)) / vec2(float(h_frames), float(v_frames));
}

// Model-view matrix that always faces the camera and keeps the scale of the node or particle.
mat4 vfx_billboard(mat4 view, mat4 inv_view, mat4 model) {
	mat4 facing = view * mat4(inv_view[0], inv_view[1], inv_view[2], model[3]);
	return facing * mat4(
			vec4(length(model[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(model[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(model[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
}

// Cylindrical billboard: the quad keeps its X axis (the node's, in world space) and rotates
// around it to show its face to the camera. Good for things that have a direction (a jet, a flash
// along a blade): it is seen from any side while still pointing where it points.
mat4 vfx_axial_billboard(mat4 view, mat4 model, vec3 camera_position) {
	vec3 axis = normalize(model[0].xyz);
	vec3 to_camera = camera_position - model[3].xyz;
	vec3 facing = to_camera - axis * dot(to_camera, axis);
	if (dot(facing, facing) < 0.000001) {
		facing = model[2].xyz;
	}
	facing = normalize(facing);
	vec3 up = cross(facing, axis);
	mat4 oriented = mat4(vec4(axis, 0.0), vec4(up, 0.0), vec4(facing, 0.0), model[3]);
	return view * oriented * mat4(
			vec4(length(model[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(model[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(model[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
}

// Soft particle fade: 0 where the fragment touches the geometry behind it and 1 at [distance_m]
// meters or more from it. [raw_depth] is the depth buffer reading.
float vfx_soft_fade(float raw_depth, vec2 screen_uv, mat4 inv_projection, float fragment_view_z,
		float distance_m) {
	if (distance_m <= 0.0) {
		return 1.0;
	}
	vec3 ndc = vec3(screen_uv * 2.0 - 1.0, raw_depth);
	vec4 view = inv_projection * vec4(ndc, 1.0);
	view.xyz /= view.w;
	return clamp((fragment_view_z - view.z) / distance_m, 0.0, 1.0);
}
