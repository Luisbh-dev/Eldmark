class_name NpcVisualProfile
extends RefCounted
## Visual profile of an NPC type (ART-52, client only): what sets it apart from a player at 20 m until the
## final ART-16 model arrives. It is chosen by the NPC's combat weapon ([code]npc_hollow[/code],
## [code]npc_captain[/code]...), which is what the visual already knows about it (the remote sees it in its record and the sandbox
## puts it in its state), and [method HumanoidVisual.apply_profile] applies it.
## [br][br]
## [b]Hollow[/b]: no shield, skin and clothes of desaturated gray bone, glowing (emissive) eyes and the dragging zombie
## gait ([ArmedStanceModifier.use_zombie_profile]). [b]Ford Captain[/b]: visual scale 1.25, reddened iron and
## a larger weapon. Scale and color are visual only: the capsule and hit boxes do not change. The guard and the
## Gate Guardian have no profile: they look like a soldier with sword and shield.

## Shader that recolors the texture of a body material: desaturates toward its luminance ([code]saturation[/code])
## and tints it ([code]tint[/code]). A multiplied color is not enough: a green jerkin multiplied by gray is still green.
const RECOLOR_SHADER: String = """shader_type spatial;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0);
uniform float saturation = 1.0;
uniform float roughness_value = 0.85;
void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb;
	float luminance = dot(base, vec3(0.299, 0.587, 0.114));
	ALBEDO = mix(vec3(luminance), base, saturation) * tint.rgb;
	ROUGHNESS = roughness_value;
}
"""

## Weapon name -> profile (created once).
static var _profiles: Dictionary[StringName, NpcVisualProfile] = {}

## Identifier (that of the combat weapon).
var id: StringName = &""
## Visual scale of the whole model (1 = the player's).
var scale: float = 1.0
## Color the albedo of each body material is multiplied by (white = its own).
var tint: Color = Color.WHITE
## Saturation of the body texture (1 = its own, 0 = grays): below 1 the color goes through the recolor shader
## ([constant RECOLOR_SHADER]) instead of being multiplied.
var saturation: float = 1.0
## Eye glow: color and energy (0 = no glow).
var eye_glow: Color = Color.WHITE
var eye_energy: float = 0.0
## false: no shield on the left arm.
var shield: bool = true
## Scale of the right-hand weapon (1 = normal).
var weapon_scale: float = 1.0
## Idle and locomotion stance: [code]shield[/code] (guard with shield) or [code]zombie[/code].
var stance: StringName = &"shield"


## Profile of the NPC whose combat weapon is named [param weapon_name], or null if that NPC (or a player) has none.
static func for_weapon(weapon_name: StringName) -> NpcVisualProfile:
	if _profiles.is_empty():
		_build()
	return _profiles.get(weapon_name)


## Profile of the NPC with [param weapon_id] (combat catalog id) or null.
static func for_weapon_id(weapon_id: int) -> NpcVisualProfile:
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	return for_weapon(weapon.name) if weapon != null else null


## true if the profile changes the look (scale, color, eyes or shield) compared with a player's.
func changes_look() -> bool:
	return scale != 1.0 or tint != Color.WHITE or saturation != 1.0 or eye_energy > 0.0 or not shield or weapon_scale != 1.0


static func _build() -> void:
	var hollow := NpcVisualProfile.new()
	hollow.id = &"npc_hollow"
	hollow.saturation = 0.15
	hollow.tint = Color(1.95, 1.97, 1.82)
	hollow.eye_glow = Color(0.45, 1.0, 0.78)
	hollow.eye_energy = 3.5
	hollow.shield = false
	hollow.stance = &"zombie"
	_profiles[hollow.id] = hollow
	var captain := NpcVisualProfile.new()
	captain.id = &"npc_captain"
	captain.scale = 1.25
	captain.saturation = 0.4
	captain.tint = Color(1.45, 0.78, 0.65)
	captain.weapon_scale = 1.3
	_profiles[captain.id] = captain
