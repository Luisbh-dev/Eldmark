// Realm surface (docs/arte.md, 4.4): recolors a kit's texture for each realm without touching the
// mesh.
//
// - Color adjustment: hue shift, saturation, brightness and contrast over the texture.
// - "Colorize": pushes the texture toward a target color while keeping its luminance detail.
//   Multiplying only darkens; this makes it possible to go from a gray brick to cream limestone or
//   from terracotta tiles to blue slate (palette in docs/mundo.md, "Paleta por material").
// - Extra layer on upward-facing faces (snow in Vardheim, moss in Solmarch, ash in Eldrun), with an
//   edge broken up by the texture itself.
// - Per-instance faction color (instance uniform faction_color): banners and cloths take the
//   owner's color without changing material. faction_mix = 0 on stone and wood.
// - Optional triplanar projection for pieces whose UVs do not match the texture (Kenney, blockout
//   primitives).
// Common body of realm_surface.gdshader (single-sided pieces, cull_disabled) and of
// realm_surface_closed.gdshader (closed meshes: logs, canvas; cull_back, half the rasterization in
// each shadow cascade).

group_uniforms textura;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable, hint_default_white;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_normal_map = false;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform bool use_triplanar = false;
// Texture repetitions per meter in triplanar mode.
uniform float triplanar_scale = 0.25;
uniform float triplanar_sharpness : hint_range(1.0, 16.0) = 6.0;
// Alpha cutout (shaped banners, grilles). 0 = opaque.
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.0;

group_uniforms color;
uniform float hue_shift : hint_range(-0.5, 0.5) = 0.0;
uniform float saturation : hint_range(0.0, 2.0) = 1.0;
uniform float brightness : hint_range(0.0, 3.0) = 1.0;
uniform float contrast : hint_range(0.0, 3.0) = 1.0;
uniform vec4 target_color : source_color = vec4(0.55, 0.55, 0.52, 1.0);
// 0 = adjusted texture; 1 = target color with the texture's luminance detail.
uniform float colorize : hint_range(0.0, 1.0) = 0.0;
// Mean luminance of the texture: the detail is measured relative to it.
uniform float reference_luminance : hint_range(0.05, 1.0) = 0.45;
uniform float detail_strength : hint_range(0.0, 2.0) = 1.0;
// Detail limits (luminance / reference): without them the light brick joints went above 1 and burned
// out to pure white with light target colors (Solmarch limestone).
uniform float detail_min : hint_range(0.0, 1.0) = 0.5;
uniform float detail_max : hint_range(1.0, 3.0) = 1.4;
// Final albedo gain (after colorizing): for very light materials.
uniform float albedo_gain : hint_range(0.0, 2.0) = 1.0;

group_uniforms capa;
uniform vec4 layer_color : source_color = vec4(0.9, 0.93, 0.95, 1.0);
uniform float layer_amount : hint_range(0.0, 1.0) = 0.0;
// How far upward the face must point (1 = horizontals only).
uniform float layer_threshold : hint_range(0.0, 1.0) = 0.6;
uniform float layer_softness : hint_range(0.01, 1.0) = 0.2;
uniform float layer_roughness : hint_range(0.0, 1.0) = 0.9;

group_uniforms bando;
instance uniform vec4 faction_color : source_color = vec4(0.741, 0.714, 0.651, 1.0);
uniform float faction_mix : hint_range(0.0, 1.0) = 0.0;

group_uniforms superficie;
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.35;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy : hint_range(0.0, 16.0) = 0.0;

varying vec3 world_position;
varying vec3 world_normal;

vec3 rgb_to_hsv(vec3 c) {
	vec4 k = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, k.wz), vec4(c.gb, k.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv_to_rgb(vec3 c) {
	vec4 k = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + k.xyz) * 6.0 - k.www);
	return c.z * mix(k.xxx, clamp(p - k.xxx, 0.0, 1.0), c.y);
}

vec4 sample_albedo(vec2 uv) {
	if (use_triplanar) {
		vec3 w = pow(abs(world_normal), vec3(triplanar_sharpness));
		w /= max(w.x + w.y + w.z, 1.0e-4);
		vec3 p = world_position * triplanar_scale;
		return texture(albedo_texture, p.zy) * w.x
				+ texture(albedo_texture, p.xz) * w.y
				+ texture(albedo_texture, p.xy) * w.z;
	}
	return texture(albedo_texture, uv * uv_scale);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec4 tex = sample_albedo(UV);
	if (alpha_scissor > 0.0 && tex.a < alpha_scissor) {
		discard;
	}
	vec3 base = tex.rgb;

	// Hue, saturation, brightness and contrast adjustment.
	vec3 hsv = rgb_to_hsv(base);
	hsv.x = fract(hsv.x + hue_shift);
	hsv.y = clamp(hsv.y * saturation, 0.0, 1.0);
	vec3 adjusted = hsv_to_rgb(hsv);
	adjusted = (adjusted - 0.5) * contrast + 0.5;
	adjusted = max(adjusted * brightness, vec3(0.0));

	// Target color with the texture detail.
	float lum = dot(base, vec3(0.299, 0.587, 0.114));
	float detail = mix(1.0, clamp(lum / reference_luminance, detail_min, detail_max), detail_strength);
	vec3 colorized = target_color.rgb * detail;
	vec3 color = mix(adjusted, colorized, colorize);

	// Faction color.
	color = mix(color, faction_color.rgb * detail, faction_mix);

	// Layer on upward-facing faces, with an edge broken up by luminance.
	float up = dot(normalize(world_normal), vec3(0.0, 1.0, 0.0));
	float edge = layer_threshold + (lum - reference_luminance) * 0.5;
	float layer = layer_amount * smoothstep(edge, edge + layer_softness, up);
	color = mix(color, layer_color.rgb * mix(1.0, detail, 0.3), layer);

	ALBEDO = clamp(color * albedo_gain, vec3(0.0), vec3(1.0));
	ROUGHNESS = mix(roughness, layer_roughness, layer);
	METALLIC = metallic * (1.0 - layer);
	SPECULAR = specular;
	if (use_normal_map && !use_triplanar) {
		NORMAL_MAP = texture(normal_texture, UV * uv_scale).rgb;
		NORMAL_MAP_DEPTH = normal_strength * (1.0 - layer * 0.7);
	}
	EMISSION = emission_color.rgb * emission_energy;
}
