// Sky of the Eldrun frontier: a storm breaking open (ART-54).
//
// A dome of broken clouds over a cold gradient: dense and dark to the east and at the zenith, with a
// clearing to the west, around the low sun. The edge of each cloud that faces the sun lights up
// (silver lining) and the clearing has the warmth of the sun. The sun direction comes from the
// scene's directional light (LIGHT0_DIRECTION), so sky and light are always consistent.
//
// No TIME on purpose: an animated sky forces the radiance map (ambient light and reflections) to be
// regenerated every frame. Used only on the client: the headless server does not draw.
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

// Cloud density toward a direction (0 = clear, 1 = dense).
float cloud_density(vec3 dir, vec3 sun_dir) {
	float h = max(dir.y, 0.0);
	// Projection onto a cloud plane: the clouds bunch up toward the horizon.
	vec2 uv = dir.xz / (h + 0.28) * cloud_scale * 0.35;
	float base = fbm(uv);
	float detail = textureLod(cloud_noise, uv * 3.1 + 7.3, 0.0).r;
	float d = base * 0.85 + detail * 0.15;
	// Clearing: around the sun, broken up by the noise itself so it is not a circle.
	float near_sun = smoothstep(0.35, 0.93, dot(dir, sun_dir));
	float west = clamp(dot(normalize(vec2(dir.x, dir.z) + 1e-5), vec2(-1.0, 0.0)) * 0.5 + 0.5, 0.0, 1.0);
	float threshold = coverage + (1.0 - west) * 0.1 - near_sun * sun_break - west * 0.08;
	float density = smoothstep(threshold, threshold + 0.38, d);
	// Heavier sky at the zenith.
	density = max(density, smoothstep(0.55, 1.0, dir.y) * 0.45 * smoothstep(threshold - 0.15, threshold + 0.35, d));
	return density;
}

void sky() {
	vec3 dir = EYEDIR;
	vec3 sun_dir = LIGHT0_ENABLED ? normalize(LIGHT0_DIRECTION) : normalize(vec3(-0.88, 0.47, 0.0));
	float elevation = dir.y;
	float sun_dot = dot(dir, sun_dir);
	float west = clamp(dot(normalize(vec2(dir.x, dir.z) + 1e-5), vec2(-1.0, 0.0)) * 0.5 + 0.5, 0.0, 1.0);

	// Identity of each half (ART-62): depending on which side of the river the camera is on, the horizon
	// turns colder and bluer (Vardheim, to the north) or warmer and more golden (Solmarch, to the south).
	// Only in the full-screen pass: the radiance map (ambient light and reflections) is computed once
	// and does not follow the camera, so the light of the two halves is identical.
	float realm_mix = 0.5;
	if (!AT_CUBEMAP_PASS && !AT_HALF_RES_PASS && !AT_QUARTER_RES_PASS) {
		realm_mix = smoothstep(-70.0, 70.0, POSITION.z);
	}
	vec3 horizon = mix(horizon_color * realm_cold, horizon_color * realm_warm, realm_mix);
	vec3 glow_tint = mix(sun_glow_color * vec3(0.85, 0.95, 1.1), sun_glow_color * vec3(1.1, 1.0, 0.8), realm_mix);

	// Background gradient: cold at the top, bright and slightly warm toward the sun, never white.
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
		// Lit edge: compare the density one step toward the sun with the density here.
		vec3 toward = normalize(dir + normalize(vec3(sun_dir.x, max(sun_dir.y, 0.15), sun_dir.z)) * 0.07);
		float thin = 1.0 - density;
		float facing = clamp(sun_dot * 0.5 + 0.5, 0.0, 1.0);
		// Clouds get darker the denser they are; the edge facing the sun lights up.
		float core = smoothstep(0.3, 1.0, density);
		vec3 body = mix(cloud_mid_color, cloud_shadow_color, core * mix(0.75, 1.0, 1.0 - west));
		float rim = clamp((density - cloud_density(toward, sun_dir)) * 2.2, 0.0, 1.0) * facing;
		cloud_color = mix(body, cloud_lit_color, clamp(rim * 0.85 + thin * 0.25 * facing, 0.0, 1.0));
		cloud_color = mix(cloud_color, glow_tint * 1.05, glow * 0.4 * thin);
		// Clouds blend into the horizon haze.
		cloud_color = mix(cloud_color, horizon, smoothstep(0.25, 0.0, elevation) * 0.7);
	}
	vec3 color = mix(sky_color, cloud_color, density);

	// Sun disc, only where a cloud does not cover it.
	float disk = smoothstep(sun_disk_size, 0.99995, sun_dot);
	color += glow_tint * disk * sun_disk_intensity * (1.0 - density);

	// Below the horizon, the ground color (the terrain almost always covers it).
	float below = smoothstep(0.0, -0.12, elevation);
	color = mix(color, ground_color, below);
	COLOR = color;
}
