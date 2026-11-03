shader_type spatial;
// Partícula de luz con mezcla ADITIVA (chispas, destellos, motas de energía) para GPUParticles3D.
// Con [cover] > 0 la luz también tapa un poco el fondo (mezcla premultiplicada): sobre un cielo claro un
// brillo puramente aditivo se lava, y así mantiene el color y el contraste.
//
// La textura es una máscara de luz (se lee el canal rojo). El color sale del color de la partícula
// (la rampa del material de proceso) por el tinte de instancia y por [intensity], que puede pasar de
// 1 (HDR) para que el brillo del entorno la haga florecer. Con [aligned_by_engine] el motor ya orienta
// la partícula (transform_align del nodo, por ejemplo eje Y siguiendo la velocidad en las chispas);
// sin él, el sombreador la gira hacia la cámara y la rota con el ángulo de la partícula.
//
// Datos por partícula: INSTANCE_CUSTOM.x ángulo, .y fase de vida (0 al nacer, 1 al morir), .z casilla
// del atlas.
render_mode blend_premul_alpha, unshaded, depth_draw_never, cull_disabled, fog_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform int h_frames = 1;
uniform int v_frames = 1;
uniform float intensity = 2.0;
// 0 = aditivo puro; 1 = la luz tapa el fondo como una mezcla normal.
uniform float cover = 0.0;
// Metros de atenuación contra la geometría (0 = sin partículas blandas).
uniform float soft_distance = 0.0;
uniform bool aligned_by_engine = false;
// Fracción de la vida que tarda en aparecer y fracción en la que empieza a apagarse.
uniform float fade_in = 0.03;
uniform float fade_out_start = 0.45;
// Cuánto crece (+) o encoge (-) la partícula a lo largo de su vida, además de su curva de escala.
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
