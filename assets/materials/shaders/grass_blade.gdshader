// Hierba del instanciador de Terrain3D (ART-59): mata de hojas con la base del color del terreno
// que sube hasta el color de la punta, un poco de translucidez a contraluz y un balanceo de viento
// que crece con la altura. Sin descarte de caras traseras (las hojas son planos).
//
// El balanceo usa TIME y la posición del mundo, así que se mueve por oleadas y no todas a la vez.
// El viento de árboles y estandartes (ART-14) usará los mismos parámetros globales.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable, hint_default_white;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
// Color del suelo bajo la mata: la base de las hojas se funde con él.
uniform vec3 base_color : source_color = vec3(0.30, 0.30, 0.20);
// Color de la punta de las hojas (se modula con la luminancia de la textura).
uniform vec3 tip_color : source_color = vec3(0.4, 0.44, 0.29);
uniform float reference_luminance : hint_range(0.05, 1.0) = 0.83;
// Altura del modelo en metros locales (para normalizar el degradado y el viento).
uniform float blade_height = 1.3;
uniform float wind_strength : hint_range(0.0, 0.5) = 0.12;
uniform float wind_speed : hint_range(0.0, 4.0) = 1.1;
uniform float translucency : hint_range(0.0, 1.0) = 0.35;

varying float height_factor;

void vertex() {
	height_factor = clamp(VERTEX.y / blade_height, 0.0, 1.0);
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME * wind_speed;
	float gust = sin(t + world.x * 0.23 + world.z * 0.17) * 0.6 + sin(t * 2.3 + world.x * 0.8 - world.z * 0.55) * 0.4;
	float bend = height_factor * height_factor * wind_strength * blade_height;
	VERTEX.x += gust * bend;
	VERTEX.z += gust * bend * 0.5;
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	if (tex.a < alpha_scissor) {
		discard;
	}
	float luminance = dot(tex.rgb, vec3(0.299, 0.587, 0.114)) / reference_luminance;
	vec3 tip = tip_color * clamp(luminance, 0.45, 1.25);
	ALBEDO = mix(base_color, tip, smoothstep(0.02, 0.6, height_factor));
	ROUGHNESS = 1.0;
	SPECULAR = 0.12;
	BACKLIGHT = ALBEDO * translucency;
}
