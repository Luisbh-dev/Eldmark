class_name DustKick
extends VfxEffect
## Ground dust on landing or dodging (ART-09, client only).
## [br][br]
## The effect's +Z axis is the ground upward. A [b]landing[/b] ([method play_landing]) opens a ring of low
## puffs around the feet and, only on a hard fall, a low dust ring 1.2 m high or less that breaks up at the
## edge. A [b]dodge[/b] ([method play_dodge]) is something else: a crescent of dust hugging the ground
## behind the body and a spray of puffs backward, without a ring. The puffs have volume and light: whatever
## falls in shade darkens.
## [br][br]
## The color is the [b]ground's[/b], not the realm's: [method set_ground] by material
## ([VfxPalette.ground]) or [method set_ground_color] (the one [VfxGround] gives by looking at the terrain).

## Landing cue: the ring of puffs and the low ring for hard falls.
const CUE_LANDING: StringName = &"landing"
## Dodge cue: the crescent and the backward spray.
const CUE_DODGE: StringName = &"dodge"
## Strength (0 to 1) from which the landing also raises the low ring.
const RING_MIN_STRENGTH: float = 0.7


## Landing at [param position] (the ground): ring of puffs. [param strength] from 0 to 1 according to the
## fall height: with low strength fewer puffs appear and there is no ring.
func play_landing(position: Vector3, strength: float = 1.0) -> void:
	_apply_strength(strength)
	set_part_enabled(&"Ring", strength >= RING_MIN_STRENGTH)
	play_at(position, Vector3.UP)
	trigger(CUE_LANDING)


## Dodge from [param position] (the ground) with the body moving toward [param move_direction]: a crescent
## of dust and a backward spray.
func play_dodge(position: Vector3, move_direction: Vector3, strength: float = 1.0) -> void:
	_apply_strength(strength)
	var back: Vector3 = -Vector3(move_direction.x, 0.0, move_direction.z)
	if back.length_squared() < 0.0001:
		back = Vector3.BACK
	# The +Z axis points up and +Y backward: the crescent and the spray come out along +Y.
	var facing: Basis = Basis.looking_at(Vector3.DOWN, back.normalized())
	global_transform = Transform3D(facing, position)
	play()
	trigger(CUE_DODGE)


## Dust color by ground material ([constant VfxPalette.GROUND_KINDS]).
func set_ground(kind: StringName) -> void:
	tint = VfxPalette.ground(kind)


## Dust color set by hand (that of the material painted under the feet, see [VfxGround]).
func set_ground_color(color: Color) -> void:
	tint = color


func _apply_strength(strength: float) -> void:
	var amount: float = clampf(strength, 0.0, 1.0)
	for part: StringName in [&"Puffs", &"Spray"]:
		var puffs: GPUParticles3D = get_node_or_null(NodePath(part)) as GPUParticles3D
		if puffs != null:
			puffs.amount_ratio = lerpf(0.45, 1.0, amount)
	var ring: Node3D = get_node_or_null(^"Ring") as Node3D
	if ring != null:
		ring.scale = Vector3.ONE * lerpf(0.7, 1.0, amount)
