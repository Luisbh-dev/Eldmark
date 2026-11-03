shader_type spatial;
// Chorro de salpicadura en secuencia (impacto en carne) sobre un quad, con mezcla NORMAL.
//
// La textura es un atlas de [variants] filas (variantes del chorro) por [frames] columnas (los
// fotogramas de la secuencia): R es el sombreado, G el brillo especular y A la silueta. El chorro sale del
// centro de la casilla hacia +X del nodo (la dirección del golpe: [VfxEffect.play_at]); el quad se
// desplaza [pivot] metros para que el arranque del chorro caiga en el punto de impacto. Gira alrededor de
// su eje X para mirar a la cámara (billboard cilíndrico), así se ve desde cualquier lado.
//
// El fotograma sale de [progress], el parámetro de instancia que mueve el [VfxEffect]. [variant] y [flip]
// (la fila y si el chorro se refleja) los pone el [VfxEffect] en cada disparo: con cuatro filas y el
// reflejo salen ocho chorros distintos. [fade_start] es la fracción de la vida en la que se apaga.
render_mode blend_mix, unshaded, depth_draw_never, cull_disabled, fog_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D tex : filter_linear_mipmap, repeat_disable;
uniform int frames = 5;
uniform int variants = 4;
uniform vec2 pivot = vec2(0.0, 0.0);
uniform float brightness = 1.0;
uniform float spec_strength = 0.7;
uniform vec3 spec_color : source_color = vec3(1.0, 0.82, 0.78);
uniform float fade_start = 0.7;
uniform float opacity = 0.95;
// Cuánto se mezclan dos fotogramas contiguos (0 = a saltos, 1 = fundido completo).
uniform float frame_blend = 0.3;
instance uniform float progress : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0);
instance uniform float variant = 0.0;
instance uniform float flip = 1.0;

varying float v_p;

void vertex() {
	v_p = clamp(progress, 0.0, 1.0);
	VERTEX.xy += pivot;
	MODELVIEW_MATRIX = vfx_axial_billboard(VIEW_MATRIX, MODEL_MATRIX, CAMERA_POSITION_WORLD);
}

vec4 sample_frame(vec2 uv, float frame, float row) {
	float f = clamp(floor(frame), 0.0, float(frames) - 1.0);
	vec2 cell = (vec2(uv.x, uv.y) + vec2(f, row)) / vec2(float(frames), float(variants));
	return texture(tex, cell);
}

void fragment() {
	float p = v_p;
	vec2 uv = vec2(UV.x, flip < 0.0 ? 1.0 - UV.y : UV.y);
	float row = mod(floor(variant + 0.5), float(variants));
	float position = p * float(frames) * 0.999;
	vec4 a = sample_frame(uv, position, row);
	vec4 b = sample_frame(uv, position + 1.0, row);
	float mix_amount = smoothstep(1.0 - max(frame_blend, 0.001), 1.0, fract(position));
	vec4 t = mix(a, b, mix_amount);
	float life = 1.0 - smoothstep(fade_start, 1.0, p);
	vec3 color = tint.rgb * t.r * brightness + spec_color * t.g * spec_strength;
	ALBEDO = color;
	ALPHA = clamp(t.a * life * opacity * tint.a, 0.0, 1.0);
}
