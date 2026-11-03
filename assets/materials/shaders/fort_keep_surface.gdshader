// Superficie del torreón del fuerte (ART-57): la receta de realm_surface (recolorear la textura hacia
// la paleta de cada reino conservando el detalle de luminancia, capa de nieve en las caras que miran
// arriba) más lo que necesita una malla modelada con color de vértice:
//
// - COLOR.rgb: valor y tono de cada sillar, oclusión de las juntas y suciedad del pie, horneados por
//   tools/blender/build_fort_keep.py. Se multiplica por vertex_color_gain porque el generador lo
//   guarda dividido para no pasar de 1.
// - COLOR.a: máscara de desgaste. En la piedra y el paño es dónde crecen el musgo, el polvo o la
//   ceniza (weather_color) y, en las zonas con la máscara casi llena, dónde brillan las grietas de
//   brasa (el alfa de la textura de piedra es la máscara de grietas). En la argamasa (ember_from_texture
//   = false) es directamente la brasa de las juntas. En el tejado vale 1 y sirve para recortar los
//   trozos que faltan (hole_amount, ruina de Eldrun).
// - Mallas cerradas con las caras bien orientadas: cull_back (la mitad de rasterizado en las sombras).
//
// Nombres de parámetros iguales a los de realm_surface donde significan lo mismo.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

group_uniforms textura;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable, hint_default_white;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_normal_map = false;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform vec2 uv_scale = vec2(1.0, 1.0);

group_uniforms color;
uniform vec4 target_color : source_color = vec4(0.55, 0.55, 0.52, 1.0);
// 0 = textura tal cual; 1 = color objetivo con el detalle de luminancia de la textura.
uniform float colorize : hint_range(0.0, 1.0) = 1.0;
uniform float reference_luminance : hint_range(0.05, 1.0) = 0.45;
uniform float detail_strength : hint_range(0.0, 2.0) = 1.0;
uniform float detail_min : hint_range(0.0, 1.0) = 0.5;
uniform float detail_max : hint_range(1.0, 3.0) = 1.4;
uniform float albedo_gain : hint_range(0.0, 2.0) = 1.0;
// Multiplicador final (la falda de tierra lo usa para tomar la paleta del reino).
uniform vec4 tint_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

group_uniforms vertice;
uniform float vertex_color_strength : hint_range(0.0, 1.0) = 1.0;
uniform float vertex_color_gain : hint_range(0.5, 2.0) = 1.25;

group_uniforms capa;
uniform vec4 layer_color : source_color = vec4(0.9, 0.93, 0.95, 1.0);
uniform float layer_amount : hint_range(0.0, 1.0) = 0.0;
uniform float layer_threshold : hint_range(0.0, 1.0) = 0.6;
uniform float layer_softness : hint_range(0.01, 1.0) = 0.2;
uniform float layer_roughness : hint_range(0.0, 1.0) = 0.9;

group_uniforms desgaste;
uniform vec4 weather_color : source_color = vec4(0.30, 0.40, 0.20, 1.0);
uniform float weather_amount : hint_range(0.0, 1.0) = 0.0;

group_uniforms brasa;
uniform vec4 ember_color : source_color = vec4(1.0, 0.54, 0.16, 1.0);
uniform float ember_energy : hint_range(0.0, 16.0) = 0.0;
// true: la brasa sale de las grietas de la textura (alfa) donde el desgaste del vértice es alto;
// false: sale directamente del alfa del vértice (juntas de argamasa).
uniform bool ember_from_texture = true;

group_uniforms ruina;
uniform float hole_amount : hint_range(0.0, 1.0) = 0.0;

group_uniforms superficie;
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.35;

varying vec3 world_position;
varying vec3 world_normal;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
			mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV * uv_scale);
	float lum = dot(tex.rgb, vec3(0.299, 0.587, 0.114));

	// Tejado en ruina: trozos que faltan, con un borde roto por la luminancia de la textura.
	if (hole_amount > 0.0 && COLOR.a > 0.5) {
		float n = value_noise(world_position.xz * 0.42 + world_position.y * 0.17) * 0.65
				+ value_noise(world_position.xz * 1.3 + 7.0) * 0.35;
		if (n + (lum - reference_luminance) * 0.35 < hole_amount) {
			discard;
		}
	}

	float detail = mix(1.0, clamp(lum / reference_luminance, detail_min, detail_max), detail_strength);
	vec3 color = mix(tex.rgb, target_color.rgb * detail, colorize);

	// Nieve (o la capa que toque) en las caras que miran arriba.
	float up = dot(normalize(world_normal), vec3(0.0, 1.0, 0.0));
	float edge = layer_threshold + (lum - reference_luminance) * 0.12;
	float layer = layer_amount * smoothstep(edge, edge + layer_softness, up);
	color = mix(color, layer_color.rgb * mix(1.0, detail, 0.3), layer);

	// Color de vértice: valor del sillar, oclusión de las juntas, suciedad.
	vec3 vc = mix(vec3(1.0), COLOR.rgb * vertex_color_gain, vertex_color_strength);
	color *= vc;

	// Desgaste: musgo, polvo o ceniza donde la máscara del vértice es alta (rota por la textura).
	float wear = smoothstep(0.20, 0.62, COLOR.a * (0.9 + 0.12 * clamp(lum / max(reference_luminance, 0.05), 0.0, 2.0)));
	color = mix(color, weather_color.rgb * mix(1.0, detail, 0.5) * vc, wear * weather_amount * (1.0 - layer));

	ALBEDO = clamp(color * albedo_gain * tint_color.rgb, vec3(0.0), vec3(1.0));
	ROUGHNESS = mix(roughness, layer_roughness, layer);
	METALLIC = metallic * (1.0 - layer);
	SPECULAR = specular;
	if (use_normal_map) {
		NORMAL_MAP = texture(normal_texture, UV * uv_scale).rgb;
		NORMAL_MAP_DEPTH = normal_strength * (1.0 - layer * 0.7);
	}

	// Brasas de Eldrun: en las grietas de la piedra de las zonas muy desgastadas y en las juntas.
	if (ember_energy > 0.0) {
		float mask = ember_from_texture ? tex.a * smoothstep(0.70, 0.96, COLOR.a) : smoothstep(0.08, 0.7, COLOR.a);
		float pulse = 0.82 + 0.18 * sin(TIME * 1.7 + world_position.x * 2.3 + world_position.z * 1.9);
		EMISSION = ember_color.rgb * ember_energy * mask * pulse;
	}
}
