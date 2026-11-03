shader_type spatial;
// Formas de luz (aditivas, con [cover] opcional para tapar un poco el fondo) sobre un quad
// (MeshInstance3D con QuadMesh de 1 x 1), animadas por el parámetro de instancia [progress] (0 al
// empezar, 1 al acabar), que mueve el [VfxEffect].
// Como el avance es por instancia, un solo material sirve a todo el grupo de reutilización.
//
// [mode]: 0 destello (la textura es un destello de puntas), 1 anillo de choque (analítico, borde
// exterior brillante y estela hacia dentro), 2 rayos radiales (textura de rayos que gira), 3 resplandor
// (disco de luz blando) y 4 runa de suelo (anillo con muescas que gira y se cierra con [progress] como
// carga; es continuo, no se apaga).
render_mode blend_premul_alpha, unshaded, depth_draw_never, cull_disabled, fog_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform int mode = 0;
uniform bool billboard = true;
uniform float intensity = 3.0;
// 0 = aditivo puro; 1 = la luz tapa el fondo como una mezcla normal (ver vfx_particle_add).
uniform float cover = 0.0;
uniform float start_scale = 0.6;
uniform float end_scale = 1.0;
// Giro total (radianes) a lo largo de la vida, en destellos y rayos.
uniform float spin = 0.0;
uniform float fade_power = 2.0;
// Fracción de la vida que tarda en alcanzar el máximo.
uniform float attack = 0.05;
// Anillo: radio inicial (fracción del radio final) y grosor al nacer y al morir.
uniform float ring_start_radius = 0.15;
uniform float ring_width_start = 0.16;
uniform float ring_width_end = 0.02;
// Anillo: cuánto se ve la estela de dentro (0 = solo el filo; 1 = anillo con relleno suave).
uniform float ring_fill = 0.5;
// Runa: número de muescas.
uniform float runes = 14.0;
instance uniform float progress : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0);

varying float v_p;

void vertex() {
	v_p = clamp(progress, 0.0, 1.0);
	if (mode != 4) {
		VERTEX.xy *= mix(start_scale, end_scale, vfx_ease_out(v_p));
	}
	if (billboard) {
		MODELVIEW_MATRIX = vfx_billboard(VIEW_MATRIX, INV_VIEW_MATRIX, MODEL_MATRIX);
	}
}

void fragment() {
	float p = v_p;
	vec2 c = (UV - 0.5) * 2.0;
	float d = length(c);
	float life = smoothstep(0.0, max(attack, 0.001), p) * pow(1.0 - p, fade_power);
	float a = 0.0;
	if (mode == 0) {
		vec2 suv = vfx_rot(spin * p) * c * 0.5 + 0.5;
		float star = texture(tex, suv).r;
		float core = exp(-d * d * 14.0);
		a = (star + core * 0.7) * life;
	} else if (mode == 1) {
		float turn = atan(c.y, c.x) / 6.2831853 + 0.5;
		float n = texture(noise_tex, vec2(turn * 2.0, p * 0.4 + 0.2)).g;
		float radius = mix(ring_start_radius, 1.0, vfx_ease_out(p)) * 0.94;
		float width = mix(ring_width_start, ring_width_end, p) * (0.6 + 0.8 * n);
		float inside = radius - d;
		float depth = max(inside, 0.0);
		// Estela suave hacia dentro y un filo exterior nítido: es un anillo, no un disco.
		float band = smoothstep(-width * 0.1, 0.0, inside) * exp(-pow(depth / max(width, 0.001), 1.6));
		float edge = exp(-pow(depth / (0.006 + width * 0.1), 2.0)) * smoothstep(-0.01, 0.0, inside);
		a = (band * ring_fill + edge * 0.95) * life;
	} else if (mode == 2) {
		vec2 suv = vfx_rot(spin * p) * c * 0.5 + 0.5;
		a = texture(tex, suv).r * life;
	} else if (mode == 3) {
		a = texture(tex, c * 0.5 + 0.5).r * life;
	} else {
		float angle = atan(c.y, c.x);
		float radius = mix(0.9, 0.7, p);
		float notch = smoothstep(0.15, 0.55, sin(angle * runes + TIME * 1.6) * 0.5 + 0.5);
		float band = exp(-pow((d - radius) / 0.04, 2.0)) * (0.3 + 0.7 * notch);
		float outer = exp(-pow((d - radius - 0.1) / 0.014, 2.0)) * 0.7;
		float fill = smoothstep(radius, 0.0, d) * 0.22;
		float inner_marks = exp(-pow((d - radius * 0.62) / 0.02, 2.0))
				* smoothstep(0.3, 0.7, sin(angle * 5.0 - TIME * 2.2) * 0.5 + 0.5) * 0.6;
		a = (band + outer + fill + inner_marks) * smoothstep(0.0, 0.12, p) * (0.25 + 0.75 * p);
	}
	a *= smoothstep(1.0, 0.88, d);
	a = clamp(a, 0.0, 1.0);
	ALBEDO = tint.rgb * intensity * a;
	ALPHA = a * cover;
}
