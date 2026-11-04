extends TestCase
## Tests for [FortressPresence] (docs/fuerte.md, section 1.2): who counts inside the cylinder of the
## capture circle.

const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
## Vado Gris circle: center level with the fort plateau (y = 10.2), radius 5 m.
const CENTER: Vector3 = Vector3(-8.5, 10.2, 0.0)
const RADIUS: float = 5.0
const NOW: int = 10000

var _def: FortressDefinition = null


func before_each() -> void:
	_def = load(DEFINITION_PATH) as FortressDefinition


func _candidate(realm: int, feet: Vector3, last_input: int = NOW) -> FortressPresence.Candidate:
	return FortressPresence.Candidate.make(realm, feet, last_input)


func _count(candidates: Array[FortressPresence.Candidate]) -> PackedInt32Array:
	return FortressPresence.count(_def, CENTER, RADIUS, candidates, NOW)


func test_counts_players_by_realm_inside_the_circle() -> void:
	var candidates: Array[FortressPresence.Candidate] = [
		_candidate(1, CENTER), _candidate(1, CENTER + Vector3(2, 0, 1)), _candidate(2, CENTER + Vector3(-3, 0.5, 0)),
		_candidate(3, CENTER + Vector3(0, 0, 4)),
	]
	assert_eq(_count(candidates), PackedInt32Array([0, 2, 1, 1]))
	assert_eq(_count([] as Array[FortressPresence.Candidate]), PackedInt32Array([0, 0, 0, 0]), "empty")


func test_the_horizontal_edge_counts_and_outside_does_not() -> void:
	assert_true(FortressPresence.is_inside_cylinder(CENTER, RADIUS, 4.0, CENTER + Vector3(RADIUS, 0, 0)), "right at the edge, inside")
	assert_false(FortressPresence.is_inside_cylinder(CENTER, RADIUS, 4.0, CENTER + Vector3(RADIUS + 0.01, 0, 0)))
	assert_true(FortressPresence.is_inside_cylinder(CENTER, RADIUS, 4.0, CENTER + Vector3(3.0, 0, 4.0)), "diagonal of 5 m")
	assert_false(FortressPresence.is_inside_cylinder(CENTER, RADIUS, 4.0, CENTER + Vector3(3.6, 0, 3.6)), "diagonal of 5.09 m")


func test_the_vertical_range_is_one_meter_below_and_the_height_above() -> void:
	assert_true(FortressPresence.is_inside_cylinder(CENTER, RADIUS, 4.0, CENTER + Vector3(0, -1.0, 0)), "1 m below: inside")
	assert_false(FortressPresence.is_inside_cylinder(CENTER, RADIUS, 4.0, CENTER + Vector3(0, -1.01, 0)), "further below, no")
	assert_true(FortressPresence.is_inside_cylinder(CENTER, RADIUS, 4.0, CENTER + Vector3(0, 3.99, 0)))
	assert_false(FortressPresence.is_inside_cylinder(CENTER, RADIUS, 4.0, CENTER + Vector3(0, 4.0, 0)), "the ceiling does not count")
	# The walkway (3.35 m above the plateau) passes above the doorway but not over the circle; if it
	# were, at 3.35 m it would still count; a 4 m jump does take it out.
	assert_true(FortressPresence.is_inside_cylinder(CENTER, RADIUS, 4.0, CENTER + Vector3(0, 3.35, 0)))
	# The height comes from the definition.
	var low: FortressDefinition = _def.duplicate() as FortressDefinition
	low.circle_height_m = 2.0
	var above: Array[FortressPresence.Candidate] = [_candidate(1, CENTER + Vector3(0, 3.0, 0))]
	assert_eq(FortressPresence.count(low, CENTER, RADIUS, above, NOW), PackedInt32Array([0, 0, 0, 0]))
	assert_eq(_count(above), PackedInt32Array([0, 1, 0, 0]))


func test_dead_downed_and_disconnected_players_do_not_count() -> void:
	var dead: FortressPresence.Candidate = _candidate(1, CENTER)
	dead.alive = false
	var downed: FortressPresence.Candidate = _candidate(1, CENTER)
	downed.downed = true
	var gone: FortressPresence.Candidate = _candidate(1, CENTER)
	gone.connected = false
	var fine: FortressPresence.Candidate = _candidate(2, CENTER)
	assert_eq(_count([dead, downed, gone, fine] as Array[FortressPresence.Candidate]), PackedInt32Array([0, 0, 1, 0]))


func test_a_player_without_real_input_for_sixty_seconds_does_not_count() -> void:
	var recent: FortressPresence.Candidate = _candidate(1, CENTER, NOW - 3599)
	var stale: FortressPresence.Candidate = _candidate(1, CENTER, NOW - 3600)
	var idle: FortressPresence.Candidate = _candidate(2, CENTER, 0)
	assert_eq(_count([recent, stale, idle] as Array[FortressPresence.Candidate]), PackedInt32Array([0, 1, 0, 0]),
			"whoever spends 60 s without real inputs stops counting")
	assert_eq(FortressPresence.INPUT_TIMEOUT_TICKS, 60 * 60)


func test_npcs_and_unknown_realms_never_count() -> void:
	# The neutral side (the Hollows) and codes that are not realms are ignored, without breaking the count.
	var hollow: FortressPresence.Candidate = _candidate(0, CENTER)
	var strange: FortressPresence.Candidate = _candidate(7, CENTER)
	var negative: FortressPresence.Candidate = _candidate(-1, CENTER)
	assert_eq(_count([hollow, strange, negative] as Array[FortressPresence.Candidate]), PackedInt32Array([0, 0, 0, 0]))
	assert_false(FortressPresence.is_present(_def, CENTER, RADIUS, null, NOW), "a null candidate does not count")
