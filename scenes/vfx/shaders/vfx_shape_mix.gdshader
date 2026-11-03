shader_type spatial;
// Formas con mezcla NORMAL sobre un quad (MeshInstance3D con QuadMesh de 1 x 1), animadas por el
// parámetro de instancia [progress] que mueve el [VfxEffect].
//
// [mode]: 0 salpicadura de tinta (mira a la cámara, aparece de golpe y se deshace por los bordes) y
// 1 anillo de polvo para el suelo (quad tumbado: se abre y se funde con el terreno). La textura lleva
// la silueta en alfa y el sombreado en rojo.
render_mode blend_mix, unshaded, depth_draw_never, cull_disabled, fog_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform int mode = 0;
uniform bool billboard = true;
uniform float start_scale = 0.5;
uniform float end_scale = 1.0;
// Velocidad del crecimiento (1 = tarda toda la vida; 4 = en un cuarto).
uniform float grow_speed = 5.0;
uniform float spin = 0.0;
// Fracción de la vida que se mantiene entera antes de deshacerse.
uniform float hold = 0.35;
// Cuánto roe el ruido el borde al deshacerse.
uniform float erosion = 0.55;
uniform float brightness = 1.0;
uniform float shade_contrast = 1.0;
uniform float soft_distance = 0.0;
uniform float opacity = 1.0;
instance uniform float progress : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0);

varying float v_p;

void vertex() {
	v_p = clamp(progress, 0.0, 1.0);
	VERTEX.xy *= mix(start_scale, end_scale, vfx_ease_out(v_p * grow_speed));
	if (billboard) {
		MODELVIEW_MATRIX = vfx_billboard(VIEW_MATRIX, INV_VIEW_MATRIX, MODEL_MATRIX);
	}
}

void fragment() {
	float p = v_p;
	vec2 c = (UV - 0.5) * 2.0;
	vec2 suv = vfx_rot(spin * p) * c * 0.5 + 0.5;
	vec4 t = texture(tex, suv);
	float n = texture(noise_tex, UV * 1.7 + vec2(0.13, 0.31)).g;
	float cut = clamp((p - hold) / max(1.0 - hold, 0.001), 0.0, 1.0);
	float cover = t.a * 0.85 + (n - 0.5) * erosion;
	float a = smoothstep(cut * 1.2, cut * 1.2 + 0.16, cover);
	a *= smoothstep(0.0, 0.04, p);
	if (mode == 1) {
		a *= soft_distance > 0.0 ? vfx_soft_fade(texture(depth_tex, SCREEN_UV).r, SCREEN_UV,
				INV_PROJECTION_MATRIX, VERTEX.z, soft_distance) : 1.0;
	}
	float shade = mix(1.0, t.r, shade_contrast);
	ALBEDO = tint.rgb * shade * brightness;
	ALPHA = clamp(a * tint.a * opacity, 0.0, 1.0);
}
