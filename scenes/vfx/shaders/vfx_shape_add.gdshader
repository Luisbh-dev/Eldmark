shader_type spatial;
// Formas de luz (aditivas, con [cover] opcional para tapar un poco el fondo) sobre un quad
// (MeshInstance3D con QuadMesh), animadas por el parámetro de instancia [progress] (0 al empezar, 1 al
// acabar), que mueve el [VfxEffect].
// Como el avance es por instancia, un solo material sirve a todo el grupo de reutilización.
//
// [mode]: 0 destello (la textura es un destello de puntas), 1 anillo de choque (analítico: un filo fino y
// nítido con una cola corta hacia dentro, sin relleno), 2 rayos radiales (textura de rayos que gira),
// 3 resplandor (disco de luz blando), 4 runa de suelo (anillo con muescas que gira y se cierra con
// [progress] como carga; es continuo, no se apaga) y 5 destello de lente (una raya horizontal en la
// pantalla, con un núcleo caliente: el quad es alargado).
//
// Orientación: con [billboard] el quad mira a la cámara (destellos, rayos); sin él se queda en el plano
// del nodo, que [VfxEffect.play_at] orienta con la normal del impacto: así los anillos de choque son una
// onda que se abre sobre la superficie golpeada, no una pompa que mira al jugador.
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
// Metros que se adelanta el quad hacia la cámara (en el espacio de vista si es billboard, o a lo largo de
// su normal si no): un destello que nace pegado a una superficie (el escudo) no lo corta la geometría.
uniform float push = 0.0;
// Giro total (radianes) a lo largo de la vida, en destellos y rayos.
uniform float spin = 0.0;
uniform float fade_power = 2.0;
// Fracción de la vida que tarda en alcanzar el máximo.
uniform float attack = 0.05;
// Anillo: radio inicial (fracción del radio final) y grosor del filo y de la cola al nacer y al morir.
uniform float ring_start_radius = 0.15;
uniform float ring_width_start = 0.16;
uniform float ring_width_end = 0.02;
// Anillo: grosor del filo (en unidades del quad, de -1 a 1) y fuerza de la cola corta que lo sigue por
// dentro (0 = solo el filo).
uniform float ring_line = 0.03;
uniform float ring_tail = 0.35;
// Anillo: cuánto se ve el relleno suave de dentro. 0 = nada (un anillo, no un disco); es lo que convertía
// el anillo en una pompa de jabón.
uniform float ring_fill = 0.0;
// Anillo: fracción de la circunferencia que se pinta (1 = entera, 0,5 = media, centrada en +Y) y
// achatamiento vertical (1 = circular, 0,5 = elipse tumbada).
uniform float ring_arc = 1.0;
uniform float ring_squash = 1.0;
// Runa: número de muescas.
uniform float runes = 14.0;
// Destello de lente: grosor de la raya al nacer y al acabar (de -1 a 1 en vertical).
uniform float lens_thick_start = 0.2;
uniform float lens_thick_end = 0.05;
instance uniform float progress : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0);

varying float v_p;

void vertex() {
	v_p = clamp(progress, 0.0, 1.0);
	if (mode != 4) {
		VERTEX.xy *= mix(start_scale, end_scale, vfx_ease_out(v_p));
	}
	VERTEX.z += push;
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
	float edge_fade = 1.0 - smoothstep(0.88, 1.0, d);
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
		float dist = length(vec2(c.x, c.y / max(ring_squash, 0.05)));
		float inside = radius - dist;
		float depth = max(inside, 0.0);
		// El filo: una línea fina y nítida (más gruesa al nacer), con un poco de ruido para que no sea de compás.
		float line_width = ring_line * mix(1.5, 0.8, p) * (0.8 + 0.4 * n);
		float edge = exp(-pow((dist - radius) / line_width, 2.0));
		// Cola corta hacia dentro (la estela del filo al abrirse); no llega al centro.
		float tail = step(0.0, inside) * exp(-pow(depth / max(width, 0.001), 1.4)) * ring_tail;
		float band = smoothstep(-width * 0.1, 0.0, inside) * exp(-pow(depth / max(width * 3.0, 0.001), 1.6));
		a = (edge + tail * 0.5 + band * ring_fill) * life;
		if (ring_arc < 0.999) {
			// UV.y crece hacia abajo: el +Y del nodo (arriba) es c.y negativo.
			float angle = abs(atan(c.x, -c.y));
			a *= 1.0 - smoothstep(ring_arc * 3.14159 - 0.35, ring_arc * 3.14159, angle);
		}
		edge_fade = 1.0 - smoothstep(0.96, 1.0, max(abs(c.x), abs(c.y)));
	} else if (mode == 2) {
		vec2 suv = vfx_rot(spin * p) * c * 0.5 + 0.5;
		a = texture(tex, suv).r * life;
	} else if (mode == 3) {
		a = texture(tex, c * 0.5 + 0.5).r * life;
	} else if (mode == 5) {
		float ax = abs(c.x);
		float thick = mix(lens_thick_start, lens_thick_end, vfx_ease_out(p * 1.4));
		float line = exp(-pow(c.y / thick, 2.0)) * pow(clamp(1.0 - ax, 0.0, 1.0), 1.7);
		float core = exp(-(ax * ax * 26.0 + c.y * c.y * 5.0)) * 0.9;
		a = (line + core) * life;
		edge_fade = (1.0 - smoothstep(0.9, 1.0, ax)) * (1.0 - smoothstep(0.9, 1.0, abs(c.y)));
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
	a *= edge_fade;
	a = clamp(a, 0.0, 1.0);
	ALBEDO = tint.rgb * intensity * a;
	ALPHA = a * cover;
}
