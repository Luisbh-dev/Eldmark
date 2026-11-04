shader_type spatial;
// Splash jet in sequence (flesh impact) on a quad, with NORMAL blending.
//
// The texture is an atlas of [variants] rows (jet variants) by [frames] columns (the sequence's
// frames): R is the shading, G the specular highlight and A the silhouette. The jet leaves from
// the center of the cell toward the node's +X (the hit direction: [VfxEffect.play_at]); the quad
// is shifted by [pivot] meters so that the start of the jet falls on the impact point. It rotates
// around its X axis to face the camera (cylindrical billboard), so it is seen from any side.
//
// The frame comes from [progress], the instance parameter that [VfxEffect] drives. [variant] and
// [flip] (the row and whether the jet is mirrored) are set by [VfxEffect] on each shot: with four
// rows and the mirroring, eight distinct jets result. [fade_start] is the fraction of its life at
// which it fades out.
render_mode blend_mix, unshaded, depth_draw_never, cull_disabled, fog_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D tex : filter_linear_mipmap, repeat_disable;
uniform int frames = 5;
uniform int variants = 4;
uniform vec2 pivot = vec2(0.0, 0.0);
uniform float brightness = 1.0;
uniform float spec_strength = 0.7;
uniform vec3 spec_color : source_color = vec3(1.0, 0.82, 0.78);
uniform float fade_start = 0.7;
uniform float opacity = 0.95;
// How much two adjacent frames blend (0 = stepped, 1 = full crossfade).
uniform float frame_blend = 0.3;
instance uniform float progress : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0);
instance uniform float variant = 0.0;
instance uniform float flip = 1.0;

varying float v_p;

void vertex() {
	v_p = clamp(progress, 0.0, 1.0);
	VERTEX.xy += pivot;
	MODELVIEW_MATRIX = vfx_axial_billboard(VIEW_MATRIX, MODEL_MATRIX, CAMERA_POSITION_WORLD);
}

vec4 sample_frame(vec2 uv, float frame, float row) {
	float f = clamp(floor(frame), 0.0, float(frames) - 1.0);
	vec2 cell = (vec2(uv.x, uv.y) + vec2(f, row)) / vec2(float(frames), float(variants));
	return texture(tex, cell);
}

void fragment() {
	float p = v_p;
	vec2 uv = vec2(UV.x, flip < 0.0 ? 1.0 - UV.y : UV.y);
	float row = mod(floor(variant + 0.5), float(variants));
	float position = p * float(frames) * 0.999;
	vec4 a = sample_frame(uv, position, row);
	vec4 b = sample_frame(uv, position + 1.0, row);
	float mix_amount = smoothstep(1.0 - max(frame_blend, 0.001), 1.0, fract(position));
	vec4 t = mix(a, b, mix_amount);
	float life = 1.0 - smoothstep(fade_start, 1.0, p);
	vec3 color = tint.rgb * t.r * brightness + spec_color * t.g * spec_strength;
	ALBEDO = color;
	ALPHA = clamp(t.a * life * opacity * tint.a, 0.0, 1.0);
}
