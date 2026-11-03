shader_type spatial;
// Estela del arma: cinta que sigue el arco del filo (ver WeaponTrail).
//
// La malla trae UV.x = edad a lo largo de la cinta (0 en la posición más reciente, 1 en la más vieja) y
// UV.y = posición a lo ancho (0 en la base de la hoja, 1 en la punta). Además, por vértice (COLOR):
// COLOR.r = lo que queda de cuerpo según el número de muestra (1 en la cabeza, 0 en la cola), COLOR.g = lo
// lateral que es el movimiento de la hoja (1 si barre de lado, 0 si se mueve a lo largo de su propio eje,
// como en una estocada).
//
// La cola se deshace con la edad Y se estrecha con el número de muestra: la banda visible se recoge hacia
// el filo, así la cinta acaba en punta y no en un cuadrilátero de bordes rectos (una escoba). A lo ancho
// solo se pinta el tramo exterior de la hoja y unas vetas largas de ruido que corren a lo largo la
// rompen en hebras. Los dos colores ([core_color] caliente en el filo, [edge_color] en el cuerpo) los pone
// el reino (WeaponTrail.set_realm). La mezcla es premultiplicada con [cover]: tapa un poco el fondo, así
// se lee también sobre un cielo claro.
render_mode blend_premul_alpha, unshaded, depth_draw_never, cull_disabled, fog_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
instance uniform vec4 core_color : source_color = vec4(1.0, 0.97, 0.9, 1.0);
instance uniform vec4 edge_color : source_color = vec4(0.45, 0.7, 1.0, 1.0);
uniform float intensity = 1.3;
// Cuánto tapa el fondo (0 = aditivo puro).
uniform float cover = 0.75;
// Cuánto dura la cola (exponente: más alto = se acorta antes).
uniform float tail_power = 1.3;
// Desde qué punto de la hoja (0 base, 1 punta) empieza a verse la cinta en la cabeza.
uniform float inner_edge = 0.5;
// Desde qué punto empieza a verse en la cola (se recoge hacia el filo).
uniform float inner_edge_tail = 0.93;
// Desplazamiento de las vetas con el tiempo.
uniform float scroll_speed = 1.2;
uniform float streak_scale = 2.2;
instance uniform float fade : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float age = clamp(UV.x, 0.0, 1.0);
	float across = clamp(UV.y, 0.0, 1.0);
	float body_left = clamp(COLOR.r, 0.0, 1.0);
	float lateral = clamp(COLOR.g, 0.0, 1.0);
	float along = pow(1.0 - age, tail_power) * smoothstep(0.0, 0.35, body_left);
	float streak = texture(noise_tex, vec2(age * streak_scale - TIME * scroll_speed, across * 0.7 + 0.2)).b;
	float fine = texture(noise_tex, vec2(age * 5.0 + 0.3, across * 3.0 - TIME * 0.4)).g;
	// La banda se recoge hacia el filo según se acerca a la cola.
	float inner = mix(inner_edge_tail, inner_edge, pow(body_left, 0.8));
	float outer = smoothstep(inner, 1.0, across);
	float body = pow(outer, 1.25) * mix(0.6, 1.0, streak) * mix(0.8, 1.0, fine);
	float strength = body * along;
	// Hilo caliente justo en el filo de la punta.
	float hot = smoothstep(0.9, 1.0, across) * pow(1.0 - age, 0.7) * smoothstep(0.0, 0.4, body_left);
	// La cabeza (lo más reciente) entra con suavidad: no se ve un corte recto junto a la hoja.
	float head = smoothstep(0.0, 0.1, age);
	float alpha = smoothstep(0.05, 0.5, strength) * mix(0.55, 1.0, head);
	alpha = clamp(max(alpha * 0.9, hot * mix(0.7, 1.0, head)) * fade * mix(0.2, 1.0, lateral), 0.0, 1.0);
	vec3 color = mix(edge_color.rgb, core_color.rgb, clamp(hot * 1.3 + strength * 0.12, 0.0, 1.0));
	ALBEDO = color * intensity * alpha;
	ALPHA = alpha * cover;
}
