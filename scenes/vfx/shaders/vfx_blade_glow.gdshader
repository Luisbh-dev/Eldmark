shader_type spatial;
// Brillo de la hoja cargada (ChargeAura): una franja de luz a lo largo del arma que crece con la carga.
//
// Es un quad que cuelga del arma (su eje X es la hoja: UV.x va de la empuñadura, 0, a la punta, 1) y gira
// alrededor de ese eje para mirar a la cámara (billboard cilíndrico). Con poca carga es un filo tenue; con
// más, el núcleo se ensancha y se calienta, corren pulsos de energía hacia la punta y la punta se
// enciende. [charge] (de 0 a 1) es un parámetro de instancia. Mezcla premultiplicada con [cover]: tapa un
// poco el fondo para que se lea también sobre un cielo claro.
render_mode blend_premul_alpha, unshaded, depth_draw_never, cull_disabled, fog_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float intensity = 3.2;
uniform float cover = 0.4;
uniform float flow_speed = 1.5;
instance uniform float charge : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0);

void vertex() {
	MODELVIEW_MATRIX = vfx_axial_billboard(VIEW_MATRIX, MODEL_MATRIX, CAMERA_POSITION_WORLD);
}

void fragment() {
	float along_pos = clamp(UV.x, 0.0, 1.0);
	float across = abs((UV.y - 0.5) * 2.0);
	float width = mix(0.16, 0.55, charge);
	float profile = exp(-pow(across / width, 2.0));
	float hot = exp(-pow(across / (width * 0.32), 2.0));
	// Pulsos de energía que suben hacia la punta, más rápidos y marcados cuanto más carga.
	float speed = flow_speed * (0.5 + charge * 1.2);
	float flow_a = texture(noise_tex, vec2(along_pos * 2.4 - TIME * speed, across * 0.4 + 0.2)).b;
	float flow_b = texture(noise_tex, vec2(along_pos * 4.1 - TIME * speed * 1.7 + 0.37, across * 0.6 + 0.6)).b;
	float pulses = smoothstep(0.34, 0.82, flow_a * 0.65 + flow_b * 0.45);
	float envelope = smoothstep(0.0, 0.1, along_pos) * (1.0 - smoothstep(0.93, 1.0, along_pos));
	float tip = exp(-pow((1.0 - along_pos) / 0.14, 2.0)) * charge;
	float level = 0.2 + 0.8 * charge;
	float glow = profile * (0.3 + 0.7 * pulses) * level + hot * (0.15 + 0.95 * charge) + tip * profile * 0.9;
	float a = clamp(glow * envelope, 0.0, 1.0);
	vec3 color = mix(tint.rgb, vec3(1.0), clamp(hot * charge * 0.7 + tip * 0.5, 0.0, 1.0));
	ALBEDO = color * intensity * a;
	ALPHA = a * cover;
}
