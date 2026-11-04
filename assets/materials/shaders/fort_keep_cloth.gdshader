// Cloth of the keep banners (ART-57): the pole pennant and the scaffold hangings.
//
// Everything the fort controller decides is a per-instance parameter (instance uniform) of the
// Banner node, so capturing a fort changes neither meshes nor materials:
//   faction_color     owner color: tints the cloth (same name as in realm_surface)
//   emblem_index      owner emblem in the atlas: 0 Vardheim, 1 Solmarch, 2 Askarra, 3 the Hollow.
//                     A negative value leaves the cloth plain (unowned frontier)
//   capture_progress  0..1: the attacker's stripe (contest_color) advances across the cloth, from
//                     the tip (pennant) or from the bottom (hanging)
//   contest_color     attacker color
//   wind_strength     0 = still cloth; 1 = normal wind
//
// The vertex color carries the wind: alpha is the weight (0 where the cloth is fastened, 1 at the
// free tip) and RGB the encoded sway direction (0..1 -> -1..1, in model space).
// The atlas carries in RGB the light gray cloth (tinted with faction_color) and the emblems in their
// colors, and in alpha where the emblem rules (dark disc with the emblem on top).
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable, hint_default_white;
// Atlas cells: (1, 4) the pennant (stacked), (4, 1) the hangings (in a row).
uniform vec2 atlas_cells = vec2(1.0, 4.0);
// Direction in which capture_progress grows: (1, 0) along u (pennant), (0, 1) downwards (hanging).
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
	// The sway direction goes in COLOR.rgb (shared by the whole piece): with each face's normal, the
	// loose faces of the pennant separated as they moved.
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
