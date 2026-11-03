shader_type spatial;
// Aura de carga del golpe fuerte: cáscara de energía alrededor del cuerpo (ChargeAura).
//
// Se pinta sobre una cápsula algo mayor que el personaje. No dibuja una silueta continua (parecería un
// tubo de cristal): solo se ven las vetas de energía que suben por la cáscara, más brillantes hacia el
// borde (Fresnel) y hacia los pies, con un resplandor tenue de fondo que crece con la carga. [charge] es un
// parámetro de instancia de 0 a 1: con más carga hay más vetas, suben más rápido y la cáscara respira
// más. Mezcla premultiplicada con [cover]: tapa un poco el fondo para leerse sobre un cielo claro.
render_mode blend_premul_alpha, unshaded, depth_draw_never, cull_back, fog_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float intensity = 3.0;
uniform float cover = 0.45;
uniform float fresnel_power = 1.3;
uniform float rise_speed = 0.75;
uniform float vein_scale = 2.6;
instance uniform float charge : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0);

void vertex() {
	float breathe = 0.5 + 0.5 * sin(TIME * (5.0 + charge * 7.0));
	VERTEX += NORMAL * (0.015 + 0.05 * charge * breathe);
}

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fres = pow(1.0 - facing, fresnel_power);
	float speed = rise_speed * (0.6 + charge * 1.2);
	// Hebras verticales que suben: se muestrea la veta larga del ruido con los ejes cambiados, así queda
	// alargada de abajo arriba y no en manchas.
	vec2 flow = vec2(UV.y * vein_scale * 0.9 + TIME * speed, UV.x * vein_scale * 3.0);
	float veins_a = texture(noise_tex, flow).b;
	float veins_b = texture(noise_tex, vec2(flow.x * 1.7 + 0.31, flow.y * 1.3 + 0.5)).b;
	float field = veins_a * 0.6 + veins_b * 0.5;
	float veins = smoothstep(0.52 - 0.12 * charge, 0.78, field);
	// Más intensa abajo (junto a los pies) y se desvanece hacia la cabeza.
	float height = smoothstep(0.0, 1.0, UV.y);
	float body = mix(0.5, 1.0, height);
	// Vetas fuertes, sin contorno continuo; el halo de fondo es casi nada.
	float glow = (veins * (0.35 + fres * 1.5) + fres * 0.06) * body;
	float a = clamp(glow * charge, 0.0, 1.0);
	ALBEDO = tint.rgb * intensity * a;
	ALPHA = a * cover;
}
