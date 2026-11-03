// Tela de los estandartes del torreón (ART-57): gallardete del asta y pendones del cadalso.
//
// Todo lo que decide el controlador del fuerte son parámetros por instancia (instance uniform) del
// nodo Estandarte, así que capturar un fuerte no cambia ni mallas ni materiales:
//   faction_color     color del dueño: tiñe la tela (mismo nombre que en realm_surface)
//   emblem_index      emblema del dueño en el atlas: 0 Vardheim, 1 Solmarch, 2 Askarra, 3 Huecos.
//                     Un valor negativo deja la tela lisa (frontera sin dueño)
//   capture_progress  0..1: la franja del atacante (contest_color) avanza por la tela, desde la
//                     punta (gallardete) o desde abajo (pendón)
//   contest_color     color del atacante
//   wind_strength     0 = tela quieta; 1 = viento normal
//
// El color de vértice lleva el viento: el alfa es el peso (0 donde la tela está sujeta, 1 en la punta
// libre) y RGB la dirección del vaivén codificada (0..1 -> -1..1, en el espacio del modelo).
// El atlas lleva en RGB la tela gris clara (se tiñe con faction_color) y los emblemas con sus
// colores, y en el alfa dónde manda el emblema (disco oscuro con el emblema encima).
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable, hint_default_white;
// Casillas del atlas: (1, 4) el gallardete (apiladas), (4, 1) los pendones (en fila).
uniform vec2 atlas_cells = vec2(1.0, 4.0);
// Hacia dónde crece capture_progress: (1, 0) a lo largo de u (gallardete), (0, 1) hacia abajo (pendón).
uniform vec2 progress_axis = vec2(1.0, 0.0);
uniform float wind_amplitude : hint_range(0.0, 1.0) = 0.35;
uniform float wind_speed : hint_range(0.0, 6.0) = 1.7;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;

instance uniform vec4 faction_color : source_color = vec4(0.741, 0.714, 0.651, 1.0);
instance uniform vec4 contest_color : source_color = vec4(0.741, 0.714, 0.651, 1.0);
instance uniform float emblem_index = -1.0;
instance uniform float capture_progress = 0.0;
instance uniform float wind_strength = 1.0;

void vertex() {
	float w = COLOR.a * wind_strength;
	vec3 p = VERTEX;
	float phase = TIME * wind_speed + dot(p.xz, vec2(1.15, 0.85)) + p.y * 0.55;
	float wave = sin(phase) + 0.45 * sin(phase * 2.3 + 1.7) + 0.2 * sin(phase * 4.1);
	// La direccion del vaiven va en COLOR.rgb (comun a toda la pieza): con la normal de cada cara,
	// las caras sueltas del gallardete se separaban al moverse.
	vec3 dir = COLOR.rgb * 2.0 - 1.0;
	dir = length(dir) > 0.1 ? normalize(dir) : NORMAL;
	VERTEX += dir * wave * w * wind_amplitude;
	VERTEX.y -= 0.08 * w * wind_amplitude * (0.5 + 0.5 * sin(phase * 1.3));
}

void fragment() {
	float index = floor(emblem_index + 0.5);
	float has_emblem = step(-0.5, emblem_index);
	vec2 cell = (atlas_cells.y > atlas_cells.x) ? vec2(0.0, max(index, 0.0)) : vec2(max(index, 0.0), 0.0);
	vec4 t = texture(atlas, (UV + cell) / atlas_cells);

	float coord = dot(UV, progress_axis);
	float fill = smoothstep(1.0 - capture_progress - 0.02, 1.0 - capture_progress + 0.02, coord) * step(0.0001, capture_progress);
	vec3 field = mix(faction_color.rgb, contest_color.rgb, fill);
	vec3 cloth = t.rgb * field;
	vec3 color = mix(cloth, t.rgb, t.a * has_emblem);

	ALBEDO = color;
	ROUGHNESS = roughness;
	SPECULAR = 0.15;
	BACKLIGHT = color * 0.28;
}
