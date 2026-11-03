shader_type spatial;
// Partícula con volumen y mezcla NORMAL (polvo, humo, astillas, esquirlas, gotas) para GPUParticles3D.
//
// La textura lleva la silueta en alfa y el sombreado en rojo (1 = claro): [shade_contrast] decide
// cuánto se nota el relieve. Encima de la mezcla se suma un calor [hot_color] que se apaga con la
// vida ([hot_decay]): las esquirlas de metal nacen incandescentes y acaban frías. Con
// [soft_distance] > 0 el polvo se funde con el suelo en vez de cortarlo.
//
// Con [accent_amount] > 0 el canal verde de la textura es una máscara de un segundo tono ([accent]): las
// tablillas de madera lo usan para la madera fresca de la rotura, clara, frente a la tabla curtida.
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
