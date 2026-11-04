shader_type spatial;
// Glow of the charged blade (ChargeAura): a strip of light along the weapon that grows with the charge.
//
// It is a quad hanging from the weapon (its X axis is the blade: UV.x goes from the hilt, 0, to
// the tip, 1) and it rotates around that axis to face the camera (cylindrical billboard). With
// little charge it is a faint edge; with more, the core widens and heats up, energy pulses run
// toward the tip and the tip lights up. [charge] (from 0 to 1) is an instance parameter. Premultiplied
// blend with [cover]: it covers the background a little so it also reads against a bright sky.
render_mode blend_premul_alpha, unshaded, depth_draw_never, cull_disabled, fog_disabled;

#include "res://scenes/vfx/shaders/vfx_common.gdshaderinc"

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float intensity = 3.2;
uniform float cover = 0.4;
uniform float flow_speed = 1.5;
instance uniform float charge : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0);

void vertex() {
	MODELVIEW_MATRIX = vfx_axial_billboard(VIEW_MATRIX, MODEL_MATRIX, CAMERA_POSITION_WORLD);
}

void fragment() {
	float along_pos = clamp(UV.x, 0.0, 1.0);
	float across = abs((UV.y - 0.5) * 2.0);
	float width = mix(0.16, 0.55, charge);
	float profile = exp(-pow(across / width, 2.0));
	float hot = exp(-pow(across / (width * 0.32), 2.0));
	// Energy pulses that rise toward the tip, faster and more pronounced the more charge there is.
	float speed = flow_speed * (0.5 + charge * 1.2);
	float flow_a = texture(noise_tex, vec2(along_pos * 2.4 - TIME * speed, across * 0.4 + 0.2)).b;
	float flow_b = texture(noise_tex, vec2(along_pos * 4.1 - TIME * speed * 1.7 + 0.37, across * 0.6 + 0.6)).b;
	float pulses = smoothstep(0.34, 0.82, flow_a * 0.65 + flow_b * 0.45);
	float envelope = smoothstep(0.0, 0.1, along_pos) * (1.0 - smoothstep(0.93, 1.0, along_pos));
	float tip = exp(-pow((1.0 - along_pos) / 0.14, 2.0)) * charge;
	float level = 0.2 + 0.8 * charge;
	float glow = profile * (0.3 + 0.7 * pulses) * level + hot * (0.15 + 0.95 * charge) + tip * profile * 0.9;
	float a = clamp(glow * envelope, 0.0, 1.0);
	vec3 color = mix(tint.rgb, vec3(1.0), clamp(hot * charge * 0.7 + tip * 0.5, 0.0, 1.0));
	ALBEDO = color * intensity * a;
	ALPHA = a * cover;
}
