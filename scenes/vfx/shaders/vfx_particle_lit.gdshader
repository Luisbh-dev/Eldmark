shader_type spatial;
// Puff of dust or smoke with volume, light and shadow, for GPUParticles3D (NORMAL blend).
//
// The texture (puffs.png) carries no color: R is the relief height, G a fine noise and B a swirl
// noise. The normal at each pixel comes from the height, and the sun's light (with its shadow:
// whatever falls in the shadow of a tree or a wall gets darker) models it as a volume, not as a
// flat sign. The base color is the instance tint (the ground's).
//
// The puff does not fade out by lowering the alpha: it BREAKS APART from the edge. The threshold
// [erode_start] -> [erode_end] rises over its life (starting from [hold]) and eats the thinnest
// parts first, with the noise as the outline; the interior holds until almost the end. With
// [soft_distance] > 0 the dust blends into the ground instead of being cut off.
//
// Per-particle data: INSTANCE_CUSTOM.x angle, .y life phase (0 at birth, 1 at death), .z atlas cell.
render_mode blend_mix, depth_draw_never, cull_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform int h_frames = 2;
uniform int v_frames = 2;
// How strongly the relief marks the normal.
uniform float bump = 12.0;
uniform float opacity = 0.7;
uniform float soft_distance = 0.3;
// Fraction of its life it takes to appear, and from when it breaks apart.
uniform float fade_in = 0.06;
uniform float hold = 0.25;
uniform float erode_start = 0.08;
uniform float erode_end = 0.82;
// Width of the edge as it breaks apart and relative opacity of the edge (more transparent than the center).
uniform float edge_soft = 0.28;
uniform float edge_alpha = 0.3;
// How much it grows (+) or shrinks (-) over its life, in addition to its scale curve.
uniform float grow = 0.0;
// Light: how much the direct light (with shadow) counts; the environment's ambient is added separately.
uniform float light_gain = 1.6;
// How much the base color is darkened (the sunlight and the ambient raise it again).
uniform float albedo_scale = 0.62;
instance uniform vec4 tint : source_color = vec4(1.0);

varying float v_age;
varying float v_frame;
varying float v_angle;

void vertex() {
	v_age = INSTANCE_CUSTOM.y;
	v_frame = INSTANCE_CUSTOM.z;
	v_angle = INSTANCE_CUSTOM.x;
	VERTEX.xy *= 1.0 + grow * v_age;
	VERTEX.xy = vfx_rot(INSTANCE_CUSTOM.x) * VERTEX.xy;
	MODELVIEW_MATRIX = vfx_billboard(VIEW_MATRIX, INV_VIEW_MATRIX, MODEL_MATRIX);
}

void fragment() {
	vec2 uv = vfx_atlas_uv(UV, v_frame * float(h_frames * v_frames), h_frames, v_frames);
	vec2 texel = 1.5 / vec2(textureSize(tex, 0));
	vec4 t = texture(tex, uv);
	float hx = texture(tex, uv + vec2(texel.x, 0.0)).r - texture(tex, uv - vec2(texel.x, 0.0)).r;
	float hy = texture(tex, uv + vec2(0.0, texel.y)).r - texture(tex, uv - vec2(0.0, texel.y)).r;
	// Gradient in the image plane (x to the right, y upward) and the particle's rotation.
	vec2 gradient = vfx_rot(v_angle) * vec2(hx, -hy) * bump;
	NORMAL = normalize(vec3(-gradient, 1.0));
	// Breaking apart from the edge: the threshold rises with age and eats the thin parts first.
	float decay = smoothstep(hold, 1.0, v_age);
	float cut = mix(erode_start, erode_end, decay);
	float body = t.r * (0.7 + 0.6 * t.g) + (t.b - 0.5) * 0.12 * decay;
	float alpha = smoothstep(cut, cut + edge_soft, body) * mix(edge_alpha, 1.0, smoothstep(0.0, 0.6, t.r));
	alpha *= smoothstep(0.0, max(fade_in, 0.001), v_age);
	alpha *= vfx_soft_fade(texture(depth_tex, SCREEN_UV).r, SCREEN_UV, INV_PROJECTION_MATRIX,
			VERTEX.z, soft_distance);
	ALBEDO = tint.rgb * COLOR.rgb * albedo_scale;
	ALPHA = clamp(alpha * opacity * COLOR.a * tint.a, 0.0, 1.0);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	// A puff diffuses light: little contrast between the lit side and the other, but the full sun
	// (ATTENUATION carries the shadow) weighs enough for the shade to be noticeable.
	float lambert = clamp(dot(NORMAL, LIGHT) * 0.5 + 0.5, 0.0, 1.0);
	DIFFUSE_LIGHT += ATTENUATION * LIGHT_COLOR * (0.45 + 0.55 * lambert) * light_gain / PI;
}
