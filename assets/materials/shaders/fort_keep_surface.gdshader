// Surface of the fort keep (ART-57): the realm_surface recipe (recolor the texture toward each
// realm's palette while keeping the luminance detail, snow layer on upward-facing faces) plus what a
// mesh modeled with vertex color needs:
//
// - COLOR.rgb: value and tone of each ashlar block, joint occlusion and dirt at the base, baked by
//   tools/blender/build_fort_keep.py. It is multiplied by vertex_color_gain because the generator
//   stores it divided so as not to exceed 1.
// - COLOR.a: wear mask. On stone and cloth it is where moss, dust or ash (weather_color) grow and,
//   in the areas where the mask is nearly full, where the ember cracks glow (the alpha of the stone
//   texture is the crack mask). On the mortar (ember_from_texture = false) it is directly the ember
//   of the joints. On the roof it is 1 and is used to cut out the missing chunks (hole_amount, ruin
//   of Eldrun).
// - Closed meshes with correctly oriented faces: cull_back (half the rasterization in shadows).
//
// Parameter names match those of realm_surface where they mean the same thing.
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
// 0 = texture as is; 1 = target color with the texture's luminance detail.
uniform float colorize : hint_range(0.0, 1.0) = 1.0;
uniform float reference_luminance : hint_range(0.05, 1.0) = 0.45;
uniform float detail_strength : hint_range(0.0, 2.0) = 1.0;
uniform float detail_min : hint_range(0.0, 1.0) = 0.5;
uniform float detail_max : hint_range(1.0, 3.0) = 1.4;
uniform float albedo_gain : hint_range(0.0, 2.0) = 1.0;
// Final multiplier (the earth skirt uses it to take the realm palette).
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
// true: the ember comes from the cracks of the texture (alpha) where the vertex wear is high;
// false: it comes directly from the vertex alpha (mortar joints).
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

	// Ruined roof: missing chunks, with a broken edge from the texture's luminance.
	if (hole_amount > 0.0 && COLOR.a > 0.5) {
		float n = value_noise(world_position.xz * 0.42 + world_position.y * 0.17) * 0.65
				+ value_noise(world_position.xz * 1.3 + 7.0) * 0.35;
		if (n + (lum - reference_luminance) * 0.35 < hole_amount) {
			discard;
		}
	}

	float detail = mix(1.0, clamp(lum / reference_luminance, detail_min, detail_max), detail_strength);
	vec3 color = mix(tex.rgb, target_color.rgb * detail, colorize);

	// Snow (or whichever layer applies) on upward-facing faces.
	float up = dot(normalize(world_normal), vec3(0.0, 1.0, 0.0));
	float edge = layer_threshold + (lum - reference_luminance) * 0.12;
	float layer = layer_amount * smoothstep(edge, edge + layer_softness, up);
	color = mix(color, layer_color.rgb * mix(1.0, detail, 0.3), layer);

	// Vertex color: ashlar value, joint occlusion, dirt.
	vec3 vc = mix(vec3(1.0), COLOR.rgb * vertex_color_gain, vertex_color_strength);
	color *= vc;

	// Wear: moss, dust or ash where the vertex mask is high (broken up by the texture).
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

	// Eldrun embers: in the stone cracks of heavily worn areas and in the joints.
	if (ember_energy > 0.0) {
		float mask = ember_from_texture ? tex.a * smoothstep(0.70, 0.96, COLOR.a) : smoothstep(0.08, 0.7, COLOR.a);
		float pulse = 0.82 + 0.18 * sin(TIME * 1.7 + world_position.x * 2.3 + world_position.z * 1.9);
		EMISSION = ember_color.rgb * ember_energy * mask * pulse;
	}
}
