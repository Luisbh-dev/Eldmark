shader_type spatial;
// Estela del arma: cinta que sigue el arco del filo (ver WeaponTrail).
//
// La malla trae UV.x = edad a lo largo de la cinta (0 en la posición más reciente, 1 en la más vieja)
// y UV.y = posición a lo ancho (0 en la base de la hoja, 1 en la punta). La cola se deshace con la edad,
// a lo ancho solo se pinta el tramo exterior de la hoja (la mitad de dentro queda transparente) y unas
// vetas largas de ruido que corren a lo largo la rompen en hebras. Los dos colores ([core_color] caliente
// en el filo, [edge_color] en el cuerpo) los pone el reino (WeaponTrail.set_realm). La mezcla es
// premultiplicada con [cover]: tapa un poco el fondo, así se lee también sobre un cielo claro.
render_mode blend_premul_alpha, unshaded, depth_draw_never, cull_disabled, fog_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
instance uniform vec4 core_color : source_color = vec4(1.0, 0.97, 0.9, 1.0);
instance uniform vec4 edge_color : source_color = vec4(0.45, 0.7, 1.0, 1.0);
uniform float intensity = 1.3;
// Cuánto tapa el fondo (0 = aditivo puro).
uniform float cover = 0.75;
// Cuánto dura la cola (exponente: más alto = se acorta antes).
uniform float tail_power = 1.3;
// Desde qué punto de la hoja (0 base, 1 punta) empieza a verse la cinta.
uniform float inner_edge = 0.2;
// Desplazamiento de las vetas con el tiempo.
uniform float scroll_speed = 1.2;
uniform float streak_scale = 2.2;
instance uniform float fade : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float age = clamp(UV.x, 0.0, 1.0);
	float across = clamp(UV.y, 0.0, 1.0);
	float along = pow(1.0 - age, tail_power);
	float streak = texture(noise_tex, vec2(age * streak_scale - TIME * scroll_speed, across * 0.7 + 0.2)).b;
	float fine = texture(noise_tex, vec2(age * 5.0 + 0.3, across * 3.0 - TIME * 0.4)).g;
	// Solo el tramo exterior de la hoja, con el brillo creciendo hacia el filo.
	float outer = smoothstep(inner_edge, 1.0, across);
	float body = pow(outer, 1.25) * mix(0.6, 1.0, streak) * mix(0.8, 1.0, fine);
	float strength = body * along;
	// Hilo caliente justo en el filo de la punta.
	float hot = smoothstep(0.9, 1.0, across) * pow(1.0 - age, 0.7);
	// La cabeza (lo más reciente) entra con suavidad: no se ve un corte recto junto a la hoja.
	float head = smoothstep(0.0, 0.1, age);
	float alpha = smoothstep(0.05, 0.5, strength) * mix(0.55, 1.0, head);
	alpha = clamp(max(alpha * 0.9, hot * mix(0.7, 1.0, head)) * fade, 0.0, 1.0);
	vec3 color = mix(edge_color.rgb, core_color.rgb, clamp(hot * 1.3 + strength * 0.12, 0.0, 1.0));
	ALBEDO = color * intensity * alpha;
	ALPHA = alpha * cover;
}
