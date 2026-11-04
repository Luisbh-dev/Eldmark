extends TestCase
## Tests for [RespawnRules] (docs/fuerte.md, section 5): which respawn points are valid for a
## player depending on their realm, the forts and the tick. Also with the real Vado Gris markers,
## in scene order.

const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const FORT_ID: StringName = &"vado_gris_fort"
const VARDHEIM: int = 1
const SOLMARCH: int = 2

var _def: FortressDefinition = null
var _nodes: Array[Node3D] = []


func before_each() -> void:
	_def = load(DEFINITION_PATH) as FortressDefinition


func after_each() -> void:
	for node: Node3D in _nodes:
		if is_instance_valid(node):
			node.free()
	_nodes.clear()


## List of markers like Vado Gris's: 2 for Vardheim, 2 for Solmarch and 2 for the fort.
func _points() -> Array[Node3D]:
	var list: Array[Node3D] = [
		_marker("V1", Zones.REALM_META, &"vardheim"), _marker("V2", Zones.REALM_META, &"vardheim"),
		_marker("S1", Zones.REALM_META, &"solmarch"), _marker("S2", Zones.REALM_META, &"solmarch"),
		_marker("F1", Zones.FORTRESS_META, FORT_ID), _marker("F2", Zones.FORTRESS_META, FORT_ID),
	]
	return list


func _marker(marker_name: String, meta: StringName, value: StringName) -> Node3D:
	var marker := Marker3D.new()
	marker.name = marker_name
	marker.set_meta(meta, value)
	_nodes.append(marker)
	return marker


func _state(owner_realm: int, phase: int, under_attack_until: int = 0) -> FortressState:
	var state: FortressState = FortressState.initial(_def, 0)
	state.owner = owner_realm
	state.phase = phase
	state.under_attack_until_tick = under_attack_until
	return state


func test_a_camp_is_always_offered_to_its_own_realm_only() -> void:
	var points: Array[Node3D] = _points()
	assert_eq(RespawnRules.points_for(VARDHEIM, points, {}, 500), PackedInt32Array([0, 1]), "Vardheim: its two camps")
	assert_eq(RespawnRules.points_for(SOLMARCH, points, {}, 500), PackedInt32Array([2, 3]), "Solmarch: its own")
	assert_eq(RespawnRules.points_for(0, points, {}, 500), PackedInt32Array(), "the Hollow does not respawn")
	assert_eq(RespawnRules.points_for(3, points, {}, 500), PackedInt32Array(), "Askarra has no camp here")
	assert_eq(RespawnRules.points_for(VARDHEIM, [] as Array[Node3D], {}, 500), PackedInt32Array())


func test_the_own_fortress_is_offered_when_garrisoned_and_not_under_attack() -> void:
	var points: Array[Node3D] = _points()
	var fortresses: Dictionary = {FORT_ID: _state(VARDHEIM, FortressState.Phase.GARRISONED)}
	assert_eq(RespawnRules.points_for(VARDHEIM, points, fortresses, 500), PackedInt32Array([0, 1, 4, 5]), "camp and fort")
	assert_eq(RespawnRules.points_for(SOLMARCH, points, fortresses, 500), PackedInt32Array([2, 3]), "the enemy cannot use the fort")


func test_a_neutral_or_enemy_fortress_is_never_offered() -> void:
	var points: Array[Node3D] = _points()
	for owner_realm: int in [0, SOLMARCH]:
		var fortresses: Dictionary = {FORT_ID: _state(owner_realm, FortressState.Phase.GARRISONED)}
		assert_eq(RespawnRules.points_for(VARDHEIM, points, fortresses, 500), PackedInt32Array([0, 1]), "owner %d" % owner_realm)


func test_only_the_garrisoned_phase_counts() -> void:
	var points: Array[Node3D] = _points()
	for phase: int in [FortressState.Phase.VULNERABLE, FortressState.Phase.CAPTURING, FortressState.Phase.CONSOLIDATING]:
		var fortresses: Dictionary = {FORT_ID: _state(VARDHEIM, phase)}
		assert_eq(RespawnRules.points_for(VARDHEIM, points, fortresses, 500), PackedInt32Array([0, 1]), "phase %d" % phase)


func test_a_fortress_under_attack_is_offered_again_exactly_when_the_time_passes() -> void:
	var points: Array[Node3D] = _points()
	var fortresses: Dictionary = {FORT_ID: _state(VARDHEIM, FortressState.Phase.GARRISONED, 2000)}
	assert_eq(RespawnRules.points_for(VARDHEIM, points, fortresses, 1999), PackedInt32Array([0, 1]), "under attack until tick 2000")
	assert_eq(RespawnRules.points_for(VARDHEIM, points, fortresses, 2000), PackedInt32Array([0, 1, 4, 5]), "s >= under_attack_until_tick")
	assert_true(RespawnRules.is_point_valid(VARDHEIM, points[4], fortresses, 2000))
	assert_false(RespawnRules.is_point_valid(VARDHEIM, points[4], fortresses, 1999))


func test_unknown_fortresses_and_markers_without_metadata_are_not_offered() -> void:
	var points: Array[Node3D] = _points()
	var other: Node3D = _marker("X", Zones.FORTRESS_META, &"otro_fuerte")
	var bare := Marker3D.new()
	_nodes.append(bare)
	points.append(other)
	points.append(bare)
	var fortresses: Dictionary = {FORT_ID: _state(VARDHEIM, FortressState.Phase.GARRISONED)}
	assert_eq(RespawnRules.points_for(VARDHEIM, points, fortresses, 500), PackedInt32Array([0, 1, 4, 5]), "neither the unknown fort nor the marker without data")
	assert_false(RespawnRules.is_point_valid(VARDHEIM, null, fortresses, 500))
	assert_true(RespawnRules.points_for(VARDHEIM, _points(), {}, 500).size() == 2, "without states, there is no fort to offer")


func test_string_keys_work_like_string_names() -> void:
	var points: Array[Node3D] = _points()
	var fortresses: Dictionary = {"vado_gris_fort": _state(VARDHEIM, FortressState.Phase.GARRISONED)}
	assert_eq(RespawnRules.points_for(VARDHEIM, points, fortresses, 500), PackedInt32Array([0, 1, 4, 5]))


func test_with_the_real_vado_gris_markers_the_indices_are_the_scene_order() -> void:
	var zone: Node3D = (load(ZONE_SCENE_PATH) as PackedScene).instantiate() as Node3D
	tree.root.add_child(zone)
	var points: Array[Node3D] = Zones.get_group_nodes(zone, Zones.RESPAWN_GROUP)
	if not assert_eq(points.size(), 12, "12 respawn points"):
		zone.queue_free()
		return
	var neutral: Dictionary = {FORT_ID: FortressState.initial(_def, 0)}
	assert_eq(RespawnRules.points_for(VARDHEIM, points, neutral, 1000), PackedInt32Array([0, 1, 2, 3]), "Vardheim: its 4 camps")
	assert_eq(RespawnRules.points_for(SOLMARCH, points, neutral, 1000), PackedInt32Array([4, 5, 6, 7]), "Solmarch: its own")
	var owned: FortressState = FortressState.initial(_def, 0)
	owned.owner = SOLMARCH
	assert_eq(RespawnRules.points_for(SOLMARCH, points, {FORT_ID: owned}, 1000), PackedInt32Array([4, 5, 6, 7, 8, 9, 10, 11]),
			"with its own fort and calm, the interior too")
	assert_eq(RespawnRules.points_for(VARDHEIM, points, {FORT_ID: owned}, 1000), PackedInt32Array([0, 1, 2, 3]))
	zone.get_parent().remove_child(zone)
	zone.queue_free()
	await wait_process_frames()
