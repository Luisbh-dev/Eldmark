// Agua estilizada para ríos y vados. Solo visual: no tiene colisión y se pisa el lecho del
// terreno que hay debajo.
//
// - Color por profundidad (distancia entre la superficie y el fondo, leída del búfer de
//   profundidad): orillas y vado claros, centro del cauce oscuro.
// - Espuma en el contacto con la orilla, las piedras y los pilares, rota con ruido.
// - Dos capas de ruido que se desplazan a lo largo del río (UV.x = metros a lo largo del cauce)
//   dan las ondas del reflejo; flow_speed regula la corriente.
// - TIME vuelve a cero cada cierto tiempo (docs/mundo.md, precisión numérica): el desplazamiento
//   usa fract() para que el salto no se note.
shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.47, 0.6, 0.62, 1.0);
uniform vec4 deep_color : source_color = vec4(0.22, 0.31, 0.36, 1.0);
uniform vec4 foam_color : source_color = vec4(0.86, 0.9, 0.9, 1.0);
// Profundidad (m) a la que el agua alcanza el color profundo.
uniform float depth_fade : hint_range(0.05, 6.0) = 1.4;
// Profundidad (m) por debajo de la cual aparece espuma.
uniform float foam_depth : hint_range(0.0, 1.0) = 0.22;
uniform float foam_amount : hint_range(0.0, 1.0) = 0.8;
uniform float min_alpha : hint_range(0.0, 1.0) = 0.45;
uniform float max_alpha : hint_range(0.0, 1.0) = 0.93;
uniform float flow_speed = 0.35;
uniform float wave_scale = 0.12;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.45;
uniform sampler2D wave_normal_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D wave_normal_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D foam_noise : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Profundidad del agua en este píxel.
	float raw_depth = texture(depth_texture, SCREEN_UV).r;
	vec4 view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw_depth, 1.0);
	view_pos.xyz /= view_pos.w;
	float water_depth = max(VERTEX.z - view_pos.z, 0.0);

	float flow = fract(TIME * flow_speed * 0.02) * 50.0;
	vec2 uv_a = vec2(UV.x * wave_scale - flow * 0.9, UV.y * wave_scale * 1.3);
	vec2 uv_b = vec2(UV.x * wave_scale * 0.7 - flow * 0.55 + 0.37, UV.y * wave_scale * 0.9 + 0.21);
	vec3 n_a = texture(wave_normal_a, uv_a).rgb;
	vec3 n_b = texture(wave_normal_b, uv_b).rgb;
	NORMAL_MAP = normalize(mix(n_a, n_b, 0.5));
	NORMAL_MAP_DEPTH = normal_strength;

	float deep = smoothstep(0.0, depth_fade, water_depth);
	vec3 color = mix(shallow_color.rgb, deep_color.rgb, deep);
	float noise = texture(foam_noise, vec2(UV.x * 0.18 - flow * 0.5, UV.y * 0.25)).r;
	float foam = (1.0 - smoothstep(0.0, foam_depth, water_depth - noise * 0.12)) * foam_amount;
	foam *= smoothstep(0.35, 0.6, noise + 0.25);
	color = mix(color, foam_color.rgb, foam);

	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALBEDO = color;
	ALPHA = clamp(mix(min_alpha, max_alpha, deep) + foam * 0.5 + fresnel * 0.2, 0.0, 1.0);
	ROUGHNESS = mix(0.06, 0.6, foam);
	SPECULAR = 0.55;
	METALLIC = 0.0;
}
