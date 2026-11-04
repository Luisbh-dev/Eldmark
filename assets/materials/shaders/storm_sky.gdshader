// Cielo de la frontera de Eldrun: una tormenta que se abre (ART-54).
//
// Cúpula de nubes rotas sobre un degradado frío: densas y oscuras al este y en el cénit, con un
// claro hacia el oeste, alrededor del sol bajo. El borde de cada nube que mira al sol se ilumina
// (filo plateado) y el claro tiene la calidez del sol. La dirección del sol sale de la luz
// direccional de la escena (LIGHT0_DIRECTION), así que cielo y luz son siempre coherentes.
//
// Sin TIME a propósito: un cielo animado obliga a regenerar el mapa de radiancia (luz ambiente y
// reflejos) en cada fotograma. Solo se usa en el cliente: el servidor headless no dibuja.
shader_type sky;

uniform sampler2D cloud_noise : repeat_enable, filter_linear_mipmap;
uniform vec3 zenith_color : source_color = vec3(0.17, 0.2, 0.25);
uniform vec3 horizon_color : source_color = vec3(0.55, 0.58, 0.6);
uniform vec3 clear_color : source_color = vec3(0.62, 0.7, 0.78);
uniform vec3 sun_glow_color : source_color = vec3(1.0, 0.78, 0.5);
uniform vec3 cloud_shadow_color : source_color = vec3(0.24, 0.27, 0.31);
uniform vec3 cloud_mid_color : source_color = vec3(0.5, 0.53, 0.57);
uniform vec3 cloud_lit_color : source_color = vec3(0.78, 0.74, 0.68);
uniform vec3 ground_color : source_color = vec3(0.26, 0.28, 0.28);
uniform vec3 realm_cold = vec3(0.92, 0.98, 1.08);
uniform vec3 realm_warm = vec3(1.08, 1.0, 0.88);
uniform float cloud_scale = 0.55;
uniform float coverage = 0.46;
uniform float sun_break = 0.5;
uniform float sun_disk_intensity = 14.0;
uniform float sun_disk_size = 0.9996;

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 4; i++) {
		value += amplitude * textureLod(cloud_noise, p, 0.0).r;
		p = p * 2.03 + vec2(0.37, 0.11);
		amplitude *= 0.5;
	}
	return value / 0.9375;
}

// Densidad de nube hacia una dirección (0 = claro, 1 = denso).
float cloud_density(vec3 dir, vec3 sun_dir) {
	float h = max(dir.y, 0.0);
	// Proyección sobre un plano de nubes: las nubes se juntan hacia el horizonte.
	vec2 uv = dir.xz / (h + 0.28) * cloud_scale * 0.35;
	float base = fbm(uv);
	float detail = textureLod(cloud_noise, uv * 3.1 + 7.3, 0.0).r;
	float d = base * 0.85 + detail * 0.15;
	// Claro: alrededor del sol, roto por el propio ruido para que no sea un círculo.
	float near_sun = smoothstep(0.35, 0.93, dot(dir, sun_dir));
	float west = clamp(dot(normalize(vec2(dir.x, dir.z) + 1e-5), vec2(-1.0, 0.0)) * 0.5 + 0.5, 0.0, 1.0);
	float threshold = coverage + (1.0 - west) * 0.1 - near_sun * sun_break - west * 0.08;
	float density = smoothstep(threshold, threshold + 0.38, d);
	// Cielo más cargado en el cénit.
	density = max(density, smoothstep(0.55, 1.0, dir.y) * 0.45 * smoothstep(threshold - 0.15, threshold + 0.35, d));
	return density;
}

void sky() {
	vec3 dir = EYEDIR;
	vec3 sun_dir = LIGHT0_ENABLED ? normalize(LIGHT0_DIRECTION) : normalize(vec3(-0.88, 0.47, 0.0));
	float elevation = dir.y;
	float sun_dot = dot(dir, sun_dir);
	float west = clamp(dot(normalize(vec2(dir.x, dir.z) + 1e-5), vec2(-1.0, 0.0)) * 0.5 + 0.5, 0.0, 1.0);

	// Identidad de cada mitad (ART-62): según de qué lado del río está la cámara, el horizonte se vuelve
	// más frío y azulado (Vardheim, al norte) o más cálido y dorado (Solmarch, al sur). Solo en la
	// pasada de pantalla completa: el mapa de radiancia (luz ambiente y reflejos) se calcula una vez
	// y no sigue a la cámara, así que la luz de las dos mitades es idéntica.
	float realm_mix = 0.5;
	if (!AT_CUBEMAP_PASS && !AT_HALF_RES_PASS && !AT_QUARTER_RES_PASS) {
		realm_mix = smoothstep(-70.0, 70.0, POSITION.z);
	}
	vec3 horizon = mix(horizon_color * realm_cold, horizon_color * realm_warm, realm_mix);
	vec3 glow_tint = mix(sun_glow_color * vec3(0.85, 0.95, 1.1), sun_glow_color * vec3(1.1, 1.0, 0.8), realm_mix);

	// Degradado de fondo: frío arriba, claro y algo cálido hacia el sol, nunca blanco.
	float up = pow(clamp(elevation, 0.0, 1.0), 0.45);
	vec3 sky_color = mix(horizon, zenith_color, up);
	vec3 open_sky = mix(horizon * 1.05, clear_color, smoothstep(0.0, 0.5, elevation));
	float glow = pow(clamp(sun_dot, 0.0, 1.0), 6.0);
	float wide_glow = pow(clamp(sun_dot, 0.0, 1.0), 2.0);
	open_sky = mix(open_sky, glow_tint, glow * 0.65 + wide_glow * 0.12);
	sky_color = mix(sky_color, open_sky, west * 0.55);

	float density = 0.0;
	vec3 cloud_color = cloud_shadow_color;
	if (elevation > -0.02) {
		density = cloud_density(dir, sun_dir);
		// Filo iluminado: se compara la densidad un paso hacia el sol con la de aquí.
		vec3 toward = normalize(dir + normalize(vec3(sun_dir.x, max(sun_dir.y, 0.15), sun_dir.z)) * 0.07);
		float thin = 1.0 - density;
		float facing = clamp(sun_dot * 0.5 + 0.5, 0.0, 1.0);
		// Las nubes son más oscuras cuanto más densas; el filo que mira al sol se ilumina.
		float core = smoothstep(0.3, 1.0, density);
		vec3 body = mix(cloud_mid_color, cloud_shadow_color, core * mix(0.75, 1.0, 1.0 - west));
		float rim = clamp((density - cloud_density(toward, sun_dir)) * 2.2, 0.0, 1.0) * facing;
		cloud_color = mix(body, cloud_lit_color, clamp(rim * 0.85 + thin * 0.25 * facing, 0.0, 1.0));
		cloud_color = mix(cloud_color, glow_tint * 1.05, glow * 0.4 * thin);
		// Las nubes se funden con la neblina del horizonte.
		cloud_color = mix(cloud_color, horizon, smoothstep(0.25, 0.0, elevation) * 0.7);
	}
	vec3 color = mix(sky_color, cloud_color, density);

	// Disco solar, solo donde no lo tapa una nube.
	float disk = smoothstep(sun_disk_size, 0.99995, sun_dot);
	color += glow_tint * disk * sun_disk_intensity * (1.0 - density);

	// Bajo el horizonte, el color del suelo (el terreno lo tapa casi siempre).
	float below = smoothstep(0.0, -0.12, elevation);
	color = mix(color, ground_color, below);
	COLOR = color;
}
