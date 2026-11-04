shader_type spatial;
// Light particle with ADDITIVE blending (sparks, flashes, energy motes) for GPUParticles3D.
// With [cover] > 0 the light also covers the background a little (premultiplied blend): against
// a bright sky a purely additive glow washes out, and this keeps color and contrast.
//
// The texture is a light mask (the red channel is read). The color comes from the particle's
// color (the process material's ramp) times the instance tint and [intensity], which can exceed
// 1 (HDR) so the environment's glow makes it bloom. With [aligned_by_engine] the engine already
// orients the particle (the node's transform_align, for example Y axis following the velocity in
// sparks); without it, the shader turns it toward the camera and rotates it by the particle's angle.
//
// Per-particle data: INSTANCE_CUSTOM.x angle, .y life phase (0 at birth, 1 at death), .z atlas cell.
render_mode blend_premul_alpha, unshaded, depth_draw_never, cull_disabled, fog_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform int h_frames = 1;
uniform int v_frames = 1;
uniform float intensity = 2.0;
// 0 = pure additive; 1 = the light covers the background like a normal blend.
uniform float cover = 0.0;
// Meters of fade against geometry (0 = no soft particles).
uniform float soft_distance = 0.0;
uniform bool aligned_by_engine = false;
// Fraction of its life it takes to appear and fraction at which it starts to fade out.
uniform float fade_in = 0.03;
uniform float fade_out_start = 0.45;
// How much the particle grows (+) or shrinks (-) over its life, in addition to its scale curve.
uniform float grow = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0);

varying float v_age;
varying float v_frame;

void vertex() {
	v_age = INSTANCE_CUSTOM.y;
	v_frame = INSTANCE_CUSTOM.z;
	VERTEX.xy *= 1.0 + grow * v_age;
	if (!aligned_by_engine) {
		VERTEX.xy = vfx_rot(INSTANCE_CUSTOM.x) * VERTEX.xy;
		MODELVIEW_MATRIX = vfx_billboard(VIEW_MATRIX, INV_VIEW_MATRIX, MODEL_MATRIX);
	}
}

void fragment() {
	vec2 uv = vfx_atlas_uv(UV, v_frame * float(h_frames * v_frames), h_frames, v_frames);
	float mask = texture(tex, uv).r;
	float life = smoothstep(0.0, max(fade_in, 0.001), v_age) * (1.0 - smoothstep(fade_out_start, 1.0, v_age));
	float soft = vfx_soft_fade(texture(depth_tex, SCREEN_UV).r, SCREEN_UV, INV_PROJECTION_MATRIX,
			VERTEX.z, soft_distance);
	float amount = mask * COLOR.a * tint.a * life * soft;
	ALBEDO = COLOR.rgb * tint.rgb * intensity * amount;
	ALPHA = amount * cover;
}
