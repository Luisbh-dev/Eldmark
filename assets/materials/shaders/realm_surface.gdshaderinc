// Superficie de reino (docs/arte.md, 4.4): recolorea la textura de un kit para cada reino sin
// tocar la malla.
//
// - Ajuste de color: desplazamiento de tono, saturación, brillo y contraste sobre la textura.
// - "Colorear": lleva la textura hacia un color objetivo conservando su detalle de luminancia.
//   Multiplicar solo oscurece; esto permite pasar de un ladrillo gris a caliza crema o de tejas
//   de terracota a pizarra azul (paleta de docs/mundo.md, "Paleta por material").
// - Capa extra en las caras que miran hacia arriba (nieve en Vardheim, musgo en Solmarch,
//   ceniza en Eldrun), con un borde roto por la propia textura.
// - Color de bando por instancia (instance uniform faction_color): estandartes y telas toman el
//   color del dueño sin cambiar de material. faction_mix = 0 en piedra y madera.
// - Proyección triplanar opcional para piezas cuyas UV no casan con la textura (Kenney,
//   primitivas de blockout).
// Cuerpo común de realm_surface.gdshader (piezas de una cara, cull_disabled) y de
// realm_surface_closed.gdshader (mallas cerradas: troncos, lonas; cull_back, la mitad de
// rasterizado en cada corte de sombra).

group_uniforms textura;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable, hint_default_white;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_normal_map = false;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform bool use_triplanar = false;
// Repeticiones de la textura por metro en modo triplanar.
uniform float triplanar_scale = 0.25;
uniform float triplanar_sharpness : hint_range(1.0, 16.0) = 6.0;
// Recorte por alfa (estandartes con forma, rejas). 0 = opaco.
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.0;

group_uniforms color;
uniform float hue_shift : hint_range(-0.5, 0.5) = 0.0;
uniform float saturation : hint_range(0.0, 2.0) = 1.0;
uniform float brightness : hint_range(0.0, 3.0) = 1.0;
uniform float contrast : hint_range(0.0, 3.0) = 1.0;
uniform vec4 target_color : source_color = vec4(0.55, 0.55, 0.52, 1.0);
// 0 = textura ajustada; 1 = color objetivo con el detalle de luminancia de la textura.
uniform float colorize : hint_range(0.0, 1.0) = 0.0;
// Luminancia media de la textura: el detalle se mide respecto a ella.
uniform float reference_luminance : hint_range(0.05, 1.0) = 0.45;
uniform float detail_strength : hint_range(0.0, 2.0) = 1.0;
// Límites del detalle (luminancia / referencia): sin ellos las juntas claras del ladrillo
// pasaban de 1 y se quemaban a blanco puro con colores objetivo claros (caliza de Solmarch).
uniform float detail_min : hint_range(0.0, 1.0) = 0.5;
uniform float detail_max : hint_range(1.0, 3.0) = 1.4;
// Ganancia final del albedo (después de colorear): para materiales muy claros.
uniform float albedo_gain : hint_range(0.0, 2.0) = 1.0;

group_uniforms capa;
uniform vec4 layer_color : source_color = vec4(0.9, 0.93, 0.95, 1.0);
uniform float layer_amount : hint_range(0.0, 1.0) = 0.0;
// Cuánto debe mirar hacia arriba la cara (1 = solo horizontales).
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

	// Ajuste de tono, saturación, brillo y contraste.
	vec3 hsv = rgb_to_hsv(base);
	hsv.x = fract(hsv.x + hue_shift);
	hsv.y = clamp(hsv.y * saturation, 0.0, 1.0);
	vec3 adjusted = hsv_to_rgb(hsv);
	adjusted = (adjusted - 0.5) * contrast + 0.5;
	adjusted = max(adjusted * brightness, vec3(0.0));

	// Color objetivo con el detalle de la textura.
	float lum = dot(base, vec3(0.299, 0.587, 0.114));
	float detail = mix(1.0, clamp(lum / reference_luminance, detail_min, detail_max), detail_strength);
	vec3 colorized = target_color.rgb * detail;
	vec3 color = mix(adjusted, colorized, colorize);

	// Color de bando.
	color = mix(color, faction_color.rgb * detail, faction_mix);

	// Capa en las caras que miran arriba, con borde roto por la luminancia.
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
