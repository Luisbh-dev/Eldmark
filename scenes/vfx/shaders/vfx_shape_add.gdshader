shader_type spatial;
// Light shapes (additive, with optional [cover] to cover the background a little) on a quad
// (MeshInstance3D with QuadMesh), animated by the instance parameter [progress] (0 at the start,
// 1 at the end), which [VfxEffect] drives.
// Since progress is per instance, a single material serves the whole reuse pool.
//
// [mode]: 0 flash (the texture is a pointed flash), 1 shock ring (analytic: a thin, sharp edge
// with a short tail inward, no fill), 2 radial rays (ray texture that rotates), 3 glow (soft disc
// of light), 4 ground rune (notched ring that rotates and closes with [progress] as it charges; it
// is continuous, it does not fade out) and 5 lens flare (a horizontal streak across the screen,
// with a hot core: the quad is elongated).
//
// Orientation: with [billboard] the quad faces the camera (flashes, rays); without it, it stays
// in the node's plane, which [VfxEffect.play_at] orients with the impact normal: this way shock
// rings are a wave that opens out over the struck surface, not a bubble facing the player.
render_mode blend_premul_alpha, unshaded, depth_draw_never, cull_disabled, fog_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform int mode = 0;
uniform bool billboard = true;
uniform float intensity = 3.0;
// 0 = pure additive; 1 = the light covers the background like a normal blend (see vfx_particle_add).
uniform float cover = 0.0;
uniform float start_scale = 0.6;
uniform float end_scale = 1.0;
// Meters the quad is pushed toward the camera (in view space if billboard, or along its normal if
// not): a flash born flush against a surface (the shield) is not clipped by the geometry.
uniform float push = 0.0;
// Total rotation (radians) over its life, for flashes and rays.
uniform float spin = 0.0;
uniform float fade_power = 2.0;
// Fraction of its life it takes to reach the peak.
uniform float attack = 0.05;
// Ring: starting radius (fraction of the final radius) and thickness of the edge and the tail at birth and at death.
uniform float ring_start_radius = 0.15;
uniform float ring_width_start = 0.16;
uniform float ring_width_end = 0.02;
// Ring: edge thickness (in quad units, from -1 to 1) and strength of the short tail that follows
// it inward (0 = edge only).
uniform float ring_line = 0.03;
uniform float ring_tail = 0.35;
// Ring: how visible the soft fill inside is. 0 = none (a ring, not a disc); it is what turned the
// ring into a soap bubble.
uniform float ring_fill = 0.0;
// Ring: fraction of the circumference that is painted (1 = whole, 0.5 = half, centered on +Y) and
// vertical flattening (1 = circular, 0.5 = lying-down ellipse).
uniform float ring_arc = 1.0;
uniform float ring_squash = 1.0;
// Rune: number of notches.
uniform float runes = 14.0;
// Lens flare: streak thickness at birth and at the end (from -1 to 1 vertically).
uniform float lens_thick_start = 0.2;
uniform float lens_thick_end = 0.05;
instance uniform float progress : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0);

varying float v_p;

void vertex() {
	v_p = clamp(progress, 0.0, 1.0);
	if (mode != 4) {
		VERTEX.xy *= mix(start_scale, end_scale, vfx_ease_out(v_p));
	}
	VERTEX.z += push;
	if (billboard) {
		MODELVIEW_MATRIX = vfx_billboard(VIEW_MATRIX, INV_VIEW_MATRIX, MODEL_MATRIX);
	}
}

void fragment() {
	float p = v_p;
	vec2 c = (UV - 0.5) * 2.0;
	float d = length(c);
	float life = smoothstep(0.0, max(attack, 0.001), p) * pow(1.0 - p, fade_power);
	float a = 0.0;
	float edge_fade = 1.0 - smoothstep(0.88, 1.0, d);
	if (mode == 0) {
		vec2 suv = vfx_rot(spin * p) * c * 0.5 + 0.5;
		float star = texture(tex, suv).r;
		float core = exp(-d * d * 14.0);
		a = (star + core * 0.7) * life;
	} else if (mode == 1) {
		float turn = atan(c.y, c.x) / 6.2831853 + 0.5;
		float n = texture(noise_tex, vec2(turn * 2.0, p * 0.4 + 0.2)).g;
		float radius = mix(ring_start_radius, 1.0, vfx_ease_out(p)) * 0.94;
		float width = mix(ring_width_start, ring_width_end, p) * (0.6 + 0.8 * n);
		float dist = length(vec2(c.x, c.y / max(ring_squash, 0.05)));
		float inside = radius - dist;
		float depth = max(inside, 0.0);
		// The edge: a thin, sharp line (thicker at birth), with a little noise so it does not look compass-drawn.
		float line_width = ring_line * mix(1.5, 0.8, p) * (0.8 + 0.4 * n);
		float edge = exp(-pow((dist - radius) / line_width, 2.0));
		// Short tail inward (the edge's trail as it opens); it does not reach the center.
		float tail = step(0.0, inside) * exp(-pow(depth / max(width, 0.001), 1.4)) * ring_tail;
		float band = smoothstep(-width * 0.1, 0.0, inside) * exp(-pow(depth / max(width * 3.0, 0.001), 1.6));
		a = (edge + tail * 0.5 + band * ring_fill) * life;
		if (ring_arc < 0.999) {
			// UV.y grows downward: the node's +Y (up) is negative c.y.
			float angle = abs(atan(c.x, -c.y));
			a *= 1.0 - smoothstep(ring_arc * 3.14159 - 0.35, ring_arc * 3.14159, angle);
		}
		edge_fade = 1.0 - smoothstep(0.96, 1.0, max(abs(c.x), abs(c.y)));
	} else if (mode == 2) {
		vec2 suv = vfx_rot(spin * p) * c * 0.5 + 0.5;
		a = texture(tex, suv).r * life;
	} else if (mode == 3) {
		a = texture(tex, c * 0.5 + 0.5).r * life;
	} else if (mode == 5) {
		float ax = abs(c.x);
		float thick = mix(lens_thick_start, lens_thick_end, vfx_ease_out(p * 1.4));
		float line = exp(-pow(c.y / thick, 2.0)) * pow(clamp(1.0 - ax, 0.0, 1.0), 1.7);
		float core = exp(-(ax * ax * 26.0 + c.y * c.y * 5.0)) * 0.9;
		a = (line + core) * life;
		edge_fade = (1.0 - smoothstep(0.9, 1.0, ax)) * (1.0 - smoothstep(0.9, 1.0, abs(c.y)));
	} else {
		float angle = atan(c.y, c.x);
		float radius = mix(0.9, 0.7, p);
		float notch = smoothstep(0.15, 0.55, sin(angle * runes + TIME * 1.6) * 0.5 + 0.5);
		float band = exp(-pow((d - radius) / 0.04, 2.0)) * (0.3 + 0.7 * notch);
		float outer = exp(-pow((d - radius - 0.1) / 0.014, 2.0)) * 0.7;
		float fill = smoothstep(radius, 0.0, d) * 0.22;
		float inner_marks = exp(-pow((d - radius * 0.62) / 0.02, 2.0))
				* smoothstep(0.3, 0.7, sin(angle * 5.0 - TIME * 2.2) * 0.5 + 0.5) * 0.6;
		a = (band + outer + fill + inner_marks) * smoothstep(0.0, 0.12, p) * (0.25 + 0.75 * p);
	}
	a *= edge_fade;
	a = clamp(a, 0.0, 1.0);
	ALBEDO = tint.rgb * intensity * a;
	ALPHA = a * cover;
}
