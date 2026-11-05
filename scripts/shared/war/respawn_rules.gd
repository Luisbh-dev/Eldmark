class_name RespawnRules
extends RefCounted
## Where a player can respawn (docs/fortress.md, section 5; extends docs/combat.md, section 5). A
## pure function that the server uses to validate the choice and the client to offer only valid
## points: both compute the same thing from the same marker list.
## [br][br]
## A point's index is its position in the list of [i]all[/i] markers of the
## [constant Zones.RESPAWN_GROUP] group in the scene, in scene order (camps first; the Vado Gris
## generator keeps it stable), not in a list filtered by realm.
## [br][br]
## A point is valid for a player of [param realm] if it is:
## [br]- from their camp: the marker carries the [constant Zones.REALM_META] metadata with their
## realm;
## [br]- inside a fort (metadata [constant Zones.FORTRESS_META] with the fort's id) that belongs to
## their realm, is in GARRISONED and is not "under attack"
## ([code]tick ≥ under_attack_until_tick[/code]).
## [br]Other realms' camps and forts that are foreign, neutral, in another phase or under attack are
## not valid. Markers with neither metadata are never offered.
## [br][br]
## Shared: depends on neither the client nor the server.


## Indices (into [param points]) of the points where a player of realm [param realm] (network
## code) can respawn at tick [param tick], in order. [param fortresses] maps the id of each fort
## (the [code]fortress[/code] metadata of its markers, as [StringName] or [String]) to its
## [FortressState]; a fort missing here is not valid.
static func points_for(realm: int, points: Array[Node3D], fortresses: Dictionary, tick: int) -> PackedInt32Array:
	var valid := PackedInt32Array()
	for index: int in points.size():
		if is_point_valid(realm, points[index], fortresses, tick):
			valid.append(index)
	return valid


## true if [param point] is valid for realm [param realm] at tick [param tick] (see the class).
static func is_point_valid(realm: int, point: Node3D, fortresses: Dictionary, tick: int) -> bool:
	if point == null or not RealmCatalog.is_realm_code(realm):
		return false
	if point.has_meta(Zones.REALM_META):
		return RealmCatalog.code_of(Zones.get_spawn_realm(point)) == realm
	if not point.has_meta(Zones.FORTRESS_META):
		return false
	var fortress_id: StringName = StringName(point.get_meta(Zones.FORTRESS_META, &""))
	var state: FortressState = _state_of(fortresses, fortress_id)
	if state == null:
		return false
	return state.owner == realm and state.phase == FortressState.Phase.GARRISONED \
			and tick >= state.under_attack_until_tick


static func _state_of(fortresses: Dictionary, fortress_id: StringName) -> FortressState:
	var found: Variant = fortresses.get(fortress_id, fortresses.get(String(fortress_id), null))
	return found as FortressState
