shader_type spatial;
// Particle with volume and NORMAL blending (dust, smoke, splinters, shards, droplets) for GPUParticles3D.
//
// The texture carries the silhouette in alpha and the shading in red (1 = light): [shade_contrast]
// decides how noticeable the relief is. On top of the blend, a heat [hot_color] is added that
// fades over its life ([hot_decay]): metal shards are born incandescent and end up cold. With
// [soft_distance] > 0 the dust blends into the ground instead of being cut off.
//
// With [accent_amount] > 0 the texture's green channel is a mask for a second tone ([accent]): the
// wooden splinters use it for the fresh, light wood of the break, against the weathered plank.
render_mode blend_mix, unshaded, depth_draw_never, cull_disabled, fog_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform int h_frames = 1;
uniform int v_frames = 1;
uniform float brightness = 1.0;
uniform float shade_contrast = 1.0;
uniform float soft_distance = 0.0;
uniform bool aligned_by_engine = false;
uniform float fade_in = 0.05;
uniform float fade_out_start = 0.5;
uniform vec4 hot_color : source_color = vec4(0.0);
uniform float hot_decay = 8.0;
uniform vec4 accent : source_color = vec4(1.0);
uniform float accent_amount = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0);

varying float v_age;
varying float v_frame;

void vertex() {
	v_age = INSTANCE_CUSTOM.y;
	v_frame = INSTANCE_CUSTOM.z;
	if (!aligned_by_engine) {
		VERTEX.xy = vfx_rot(INSTANCE_CUSTOM.x) * VERTEX.xy;
		MODELVIEW_MATRIX = vfx_billboard(VIEW_MATRIX, INV_VIEW_MATRIX, MODEL_MATRIX);
	}
}

void fragment() {
	vec2 uv = vfx_atlas_uv(UV, v_frame * float(h_frames * v_frames), h_frames, v_frames);
	vec4 t = texture(tex, uv);
	float shade = mix(1.0, t.r, shade_contrast);
	float life = smoothstep(0.0, max(fade_in, 0.001), v_age) * (1.0 - smoothstep(fade_out_start, 1.0, v_age));
	float soft = vfx_soft_fade(texture(depth_tex, SCREEN_UV).r, SCREEN_UV, INV_PROJECTION_MATRIX,
			VERTEX.z, soft_distance);
	vec3 color = COLOR.rgb * tint.rgb * shade * brightness;
	color = mix(color, accent.rgb * shade * brightness, clamp(t.g * accent_amount, 0.0, 1.0));
	color += hot_color.rgb * hot_color.a * exp(-v_age * hot_decay);
	ALBEDO = color;
	ALPHA = t.a * COLOR.a * tint.a * life * soft;
}
