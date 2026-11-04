class_name StructureTarget
extends RefCounted
## Static target of hits: the gate of a fortress (docs/fortress.md, section 3.3). It is created by the
## [FortressController] and traversed by the [CombatResolver] after the players and NPCs of each
## active attack: no rewind (gates do not move), no crits and no defense. The shape is an oriented
## box ([method HitShapes.sector_hits_box]).
## [br][br]
## It holds the [b]live[/b] [FortressState] of the fortress (not a copy): the gate health and the
## owner are the current ones.

## Network id of the fortress (the [code]net_id[/code] carried by the HIT).
var net_id: int = 0
## Id of the fortress ([member FortressDefinition.id]).
var fortress_id: StringName = &""
## Live state of the fortress.
var state: FortressState = null
## Center of the gate box (global transform) and its half extents.
var box: Transform3D = Transform3D.IDENTITY
var half_extents: Vector3 = Vector3.ONE
## Physics bodies of the gate, which the hit's line of sight does not count.
var exclude: Array[RID] = []


## true if an attacker of side [param attacker_realm] can damage the gate now: it is intact and the
## attacker is a realm other than the owner (with the fort neutral, any of the three). The Hollow
## and the NPCs of the owner itself do not damage it.
func can_be_hit_by(attacker_realm: int) -> bool:
	if state == null or state.is_gate_broken():
		return false
	if not RealmCatalog.is_realm_code(attacker_realm):
		return false
	return attacker_realm != state.owner


## The point of the box closest to [param point] (in the world): where the line of sight of a hit is
## cast. If the point is inside the box, it is itself.
func closest_point(point: Vector3) -> Vector3:
	var local: Vector3 = box.affine_inverse() * point
	var clamped := Vector3(clampf(local.x, -half_extents.x, half_extents.x),
			clampf(local.y, -half_extents.y, half_extents.y),
			clampf(local.z, -half_extents.z, half_extents.z))
	return box * clamped
