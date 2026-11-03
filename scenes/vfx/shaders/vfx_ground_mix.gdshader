shader_type spatial;
// Polvo que se levanta del suelo, sobre un quad tumbado (el +Z del nodo es el suelo hacia arriba), con
// luz y sombra de verdad: lo que cae a la sombra de un árbol o una muralla se oscurece, no brilla como
// un cartel.
//
// [mode]: 0 anillo bajo (solo caídas fuertes; textura de anillo) y 1 media luna de la esquiva (analítica:
// gruesa por detrás del cuerpo, con las puntas hacia delante; el +Y del nodo es hacia atrás). En los dos
// el polvo se deshace desde el borde con ruido a lo largo de la vida ([hold] es la fracción que aguanta
// entero) en vez de bajar el alfa de golpe, y se funde con el suelo ([soft_distance]).
// El color sale del tinte de instancia: el del material del suelo ([VfxPalette.ground], no el reino).
render_mode blend_mix, depth_draw_never, cull_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform int mode = 0;
uniform float start_scale = 0.4;
uniform float end_scale = 1.0;
// Velocidad del crecimiento (1 = tarda toda la vida; 4 = en un cuarto).
uniform float grow_speed = 3.0;
uniform float hold = 0.15;
// Cuánto roe el ruido el borde al deshacerse.
uniform float erosion = 0.7;
uniform float brightness = 1.0;
uniform float soft_distance = 0.12;
uniform float opacity = 0.5;
// Cuánto se desplaza la media luna hacia atrás (en unidades del quad) a lo largo de la vida.
uniform float drift = 0.25;
// Luz: cuánto cuenta la luz directa (con sombra) y cuánto el ambiente.
uniform float light_gain = 0.9;
instance uniform float progress : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0);

varying float v_p;

void vertex() {
	v_p = clamp(progress, 0.0, 1.0);
	VERTEX.xy *= mix(start_scale, end_scale, vfx_ease_out(v_p * grow_speed));
	if (mode == 1) {
		VERTEX.y += drift * 0.5 * vfx_ease_out(v_p);
	}
}

void fragment() {
	float p = v_p;
	vec2 c = (UV - 0.5) * 2.0;
	float n = texture(noise_tex, UV * 2.3 + vec2(0.13, 0.31)).g;
	float n2 = texture(noise_tex, UV * 5.1 + vec2(0.57, 0.11)).b;
	float shape;
	float shade;
	if (mode == 0) {
		vec4 t = texture(tex, UV);
		shape = t.a;
		shade = t.r;
	} else {
		// Media luna: el círculo grande menos otro desplazado hacia delante (-Y).
		float outer = length(c * vec2(0.92, 1.0));
		float inner = length((c - vec2(0.0, -0.5)) * vec2(1.0, 1.05));
		float body = smoothstep(1.0, 0.72, outer) * smoothstep(0.82, 1.05, inner);
		shape = body;
		shade = 0.75 + 0.25 * smoothstep(0.7, 1.0, inner);
	}
	float cut = clamp((p - hold) / max(1.0 - hold, 0.001), 0.0, 1.0);
	float coverage = shape * 0.9 + (n - 0.5) * erosion + (n2 - 0.5) * erosion * 0.4;
	float a = smoothstep(cut * 1.15, cut * 1.15 + 0.2, coverage);
	a *= smoothstep(0.0, 0.05, p);
	a *= vfx_soft_fade(texture(depth_tex, SCREEN_UV).r, SCREEN_UV, INV_PROJECTION_MATRIX, VERTEX.z, soft_distance);
	ALBEDO = tint.rgb * shade * brightness;
	ALPHA = clamp(a * tint.a * opacity, 0.0, 1.0);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float ndl = clamp(dot(NORMAL, LIGHT) * 0.5 + 0.5, 0.0, 1.0);
	DIFFUSE_LIGHT += ATTENUATION * LIGHT_COLOR * ndl * ndl * light_gain / PI;
}
