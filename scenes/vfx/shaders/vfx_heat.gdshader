shader_type spatial;
// Distorsión de calor (ChargeAura a carga casi completa): desplaza un poco la imagen que hay detrás con
// un ruido que sube, como el aire sobre una hoja al rojo. No pinta color: lee la pantalla (hint_screen_texture)
// y la vuelve a escribir desplazada, con la máscara a cero en el borde para que no se vea el quad.
// [charge] (instancia, de 0 a 1) la enciende a partir de [start_charge].
render_mode blend_mix, unshaded, depth_draw_never, cull_disabled, fog_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float strength = 0.014;
uniform float start_charge = 0.6;
uniform float rise_speed = 0.8;
instance uniform float charge : hint_range(0.0, 1.0) = 0.0;

void vertex() {
	MODELVIEW_MATRIX = vfx_billboard(VIEW_MATRIX, INV_VIEW_MATRIX, MODEL_MATRIX);
}

void fragment() {
	vec2 c = (UV - 0.5) * 2.0;
	float level = smoothstep(start_charge, 1.0, charge);
	float mask = (1.0 - smoothstep(0.15, 1.0, length(c))) * level;
	vec2 flow = texture(noise_tex, UV * vec2(1.6, 2.4) + vec2(0.0, TIME * rise_speed)).rg - 0.5;
	vec2 shifted = SCREEN_UV + flow * strength * mask;
	ALBEDO = texture(screen_tex, shifted).rgb;
	ALPHA = clamp(mask * 2.0, 0.0, 1.0);
}
