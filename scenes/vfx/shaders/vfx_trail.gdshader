shader_type spatial;
// Weapon trail: a ribbon that follows the arc of the edge (see WeaponTrail).
//
// The mesh brings UV.x = age along the ribbon (0 at the most recent position, 1 at the oldest)
// and UV.y = position across the width (0 at the base of the blade, 1 at the tip). In addition,
// per vertex (COLOR): COLOR.r = how much body is left according to the sample number (1 at the
// head, 0 at the tail), COLOR.g = how lateral the blade's movement is (1 if it sweeps sideways,
// 0 if it moves along its own axis, as in a thrust).
//
// The tail fades with age AND narrows with the sample number: the visible band draws in toward
// the edge, so the ribbon ends in a point and not in a straight-edged quadrilateral (a broom).
// Across the width only the outer stretch of the blade is painted, and long noise streaks that
// run lengthwise break it into strands. The two colors ([core_color], hot at the edge,
// [edge_color] on the body) are set by the realm (WeaponTrail.set_realm). The blend is
// premultiplied with [cover]: it covers the background a little, so it also reads against a bright sky.
render_mode blend_premul_alpha, unshaded, depth_draw_never, cull_disabled, fog_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
instance uniform vec4 core_color : source_color = vec4(1.0, 0.97, 0.9, 1.0);
instance uniform vec4 edge_color : source_color = vec4(0.45, 0.7, 1.0, 1.0);
uniform float intensity = 1.3;
// How much it covers the background (0 = pure additive).
uniform float cover = 0.75;
// How long the tail lasts (exponent: higher = it shortens sooner).
uniform float tail_power = 1.3;
// From what point on the blade (0 base, 1 tip) the ribbon starts to show at the head.
uniform float inner_edge = 0.5;
// From what point it starts to show at the tail (it draws in toward the edge).
uniform float inner_edge_tail = 0.93;
// Streak scrolling over time.
uniform float scroll_speed = 1.2;
uniform float streak_scale = 2.2;
instance uniform float fade : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float age = clamp(UV.x, 0.0, 1.0);
	float across = clamp(UV.y, 0.0, 1.0);
	float body_left = clamp(COLOR.r, 0.0, 1.0);
	float lateral = clamp(COLOR.g, 0.0, 1.0);
	float along = pow(1.0 - age, tail_power) * smoothstep(0.0, 0.35, body_left);
	float streak = texture(noise_tex, vec2(age * streak_scale - TIME * scroll_speed, across * 0.7 + 0.2)).b;
	float fine = texture(noise_tex, vec2(age * 5.0 + 0.3, across * 3.0 - TIME * 0.4)).g;
	// The band draws in toward the edge as it nears the tail.
	float inner = mix(inner_edge_tail, inner_edge, pow(body_left, 0.8));
	float outer = smoothstep(inner, 1.0, across);
	float body = pow(outer, 1.25) * mix(0.6, 1.0, streak) * mix(0.8, 1.0, fine);
	float strength = body * along;
	// Hot thread right at the edge of the tip.
	float hot = smoothstep(0.9, 1.0, across) * pow(1.0 - age, 0.7) * smoothstep(0.0, 0.4, body_left);
	// The head (the most recent part) eases in: no straight cut is visible next to the blade.
	float head = smoothstep(0.0, 0.1, age);
	float alpha = smoothstep(0.05, 0.5, strength) * mix(0.55, 1.0, head);
	alpha = clamp(max(alpha * 0.9, hot * mix(0.7, 1.0, head)) * fade * mix(0.2, 1.0, lateral), 0.0, 1.0);
	vec3 color = mix(edge_color.rgb, core_color.rgb, clamp(hot * 1.3 + strength * 0.12, 0.0, 1.0));
	ALBEDO = color * intensity * alpha;
	ALPHA = alpha * cover;
}
