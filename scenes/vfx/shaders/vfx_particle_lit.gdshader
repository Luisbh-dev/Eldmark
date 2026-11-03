shader_type spatial;
// Bocanada de polvo o humo con volumen, luz y sombra, para GPUParticles3D (mezcla NORMAL).
//
// La textura (puffs.png) no lleva color: R es la altura del relieve, G un ruido fino y B uno de remolino.
// De la altura sale la normal en cada píxel, y la luz del sol (con su sombra: lo que cae a la sombra de
// un árbol o una muralla se oscurece) la modela como un volumen, no como un cartel plano. El color base
// es el tinte de instancia (el del suelo).
//
// La bocanada no se apaga bajando el alfa: se DESHACE desde el borde. El umbral [erode_start] ->
// [erode_end] sube a lo largo de la vida (a partir de [hold]) y se come primero lo más fino, con el ruido
// como contorno; el interior aguanta hasta casi el final. Con [soft_distance] > 0 el polvo se funde con
// el suelo en vez de cortarlo.
//
// Datos por partícula: INSTANCE_CUSTOM.x ángulo, .y fase de vida (0 al nacer, 1 al morir), .z casilla del
// atlas.
render_mode blend_mix, depth_draw_never, cull_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform int h_frames = 2;
uniform int v_frames = 2;
// Cuánto marca el relieve la normal.
uniform float bump = 12.0;
uniform float opacity = 0.7;
uniform float soft_distance = 0.3;
// Fracción de la vida que tarda en aparecer, y desde cuándo se deshace.
uniform float fade_in = 0.06;
uniform float hold = 0.25;
uniform float erode_start = 0.08;
uniform float erode_end = 0.82;
// Anchura del borde al deshacerse y opacidad relativa del borde (más transparente que el centro).
uniform float edge_soft = 0.28;
uniform float edge_alpha = 0.3;
// Cuánto crece (+) o encoge (-) a lo largo de su vida, además de su curva de escala.
uniform float grow = 0.0;
// Luz: cuánto cuenta la luz directa (con sombra); el ambiente del entorno se suma aparte.
uniform float light_gain = 1.6;
// Cuánto se oscurece el color base (la luz del sol y el ambiente lo suben otra vez).
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
	// Gradiente en el plano de la imagen (x a la derecha, y hacia arriba) y giro de la partícula.
	vec2 gradient = vfx_rot(v_angle) * vec2(hx, -hy) * bump;
	NORMAL = normalize(vec3(-gradient, 1.0));
	// Deshacerse desde el borde: el umbral sube con la edad y se come primero lo fino.
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
	// Una bocanada difunde la luz: poco contraste entre el lado de la luz y el otro, pero el sol entero
	// (ATTENUATION lleva la sombra) pesa lo bastante para que a la sombra se note.
	float lambert = clamp(dot(NORMAL, LIGHT) * 0.5 + 0.5, 0.0, 1.0);
	DIFFUSE_LIGHT += ATTENUATION * LIGHT_COLOR * (0.45 + 0.55 * lambert) * light_gain / PI;
}
