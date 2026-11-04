extends TestCase
## Tests for the fort view on the client (docs/fuerte.md, sections 2 and 3.2; package F5):
## [FortressTimeline] (change history, validity tick, progress formula) and [FortressView]
## (interface and banners at the draw tick, gate layers per simulated tick). The messages
## are synthetic: the client does not need a server for this.

const FORT_SCENE_PATH: String = "res://scenes/world/props/fort/vado_gris_fort.tscn"
const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const FORTRESS_ID: String = "vado_gris_fort"
const NET_ID: int = 900
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA

var _def: FortressDefinition = null
var _zone: Node3D = null
var _fort: Node3D = null
var _view: FortressView = null


func before_each() -> void:
	_def = load(DEFINITION_PATH) as FortressDefinition


func after_each() -> void:
	for node: Node in [_view, _zone]:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.queue_free()
	_view = null
	_zone = null
	_fort = null
	await wait_process_frames()


# --- FortressTimeline -------------------------------------------------------------------------

func test_a_state_is_valid_after_the_tick_of_its_message() -> void:
	var timeline := FortressTimeline.new(_def)
	assert_false(timeline.has_state(), "with no messages there is no state")
	assert_eq(timeline.state_at(500).owner, 0, "and the default state is the neutral one")
	timeline.apply_object_state(_spawn_message(100))
	timeline.apply_object_state(_change(200, {FortressFields.OWNER: VARDHEIM}))
	timeline.apply_object_state(_change(300, {FortressFields.OWNER: SOLMARCH}))
	assert_eq(timeline.get_entry_count(), 3)
	assert_eq(timeline.state_at(100).owner, 0, "after the SPAWN tick, the SPAWN state")
	assert_eq(timeline.state_at(199).owner, 0, "up to the tick before the change, the old one")
	assert_eq(timeline.state_at(200).owner, VARDHEIM, "after the change tick, the new one")
	assert_eq(timeline.state_at(299).owner, VARDHEIM)
	assert_eq(timeline.state_at(300).owner, SOLMARCH)
	assert_eq(timeline.state_at(99999).owner, SOLMARCH, "after the last one, the last one")
	assert_eq(timeline.state_at(10).owner, 0, "before the first one the first is assumed (the SPAWN is complete)")
	assert_eq(timeline.change_tick_at(250), 200)
	assert_eq(timeline.get_latest_tick(), 300)


func test_a_change_sticks_to_the_fields_it_carried() -> void:
	var timeline := FortressTimeline.new(_def)
	var full: FortressState = _state_with({FortressFields.GATE_HEALTH: 4000, FortressFields.PHASE: 1})
	timeline.apply_object_state(NetMessages.ObjectState.from_fortress(NET_ID, 100, full))
	timeline.apply_object_state(_change(160, {FortressFields.OWNER: SOLMARCH}))
	var later: FortressState = timeline.state_at(200)
	assert_eq(later.owner, SOLMARCH, "the field that changed")
	assert_eq(later.gate_health, 4000, "the others stay as they were")
	assert_eq(later.phase, 1)
	assert_eq(timeline.state_at(150).owner, 0, "and the previous state is untouched")


func test_gate_layers_change_from_the_tick_after_the_change() -> void:
	var timeline := FortressTimeline.new(_def)
	timeline.apply_object_state(_spawn_message(50))
	timeline.apply_object_state(_change(100, {FortressFields.OWNER: VARDHEIM}))
	timeline.apply_object_state(_change(200, {FortressFields.GATE_HEALTH: 0}))
	timeline.apply_object_state(_change(300, {FortressFields.GATE_HEALTH: 9000}))
	var neutral: int = FortGate.layers_for(0, false)
	var vardheim: int = FortGate.layers_for(VARDHEIM, false)
	assert_true(neutral != vardheim, "the test tells the two gates apart")
	assert_eq(timeline.gate_layers_for_tick(100), neutral, "tick 100 is still simulated with the neutral gate")
	assert_eq(timeline.gate_layers_for_tick(101), vardheim, "and 101 already with the new owner's")
	assert_eq(timeline.gate_layers_for_tick(200), vardheim, "tick 200 still with the intact gate")
	assert_eq(timeline.gate_layers_for_tick(201), 0, "broken from 201: no layers")
	assert_eq(timeline.gate_layers_for_tick(300), 0, "repaired, but not until the next tick")
	assert_eq(timeline.gate_layers_for_tick(301), vardheim, "301 closes again for enemies")
	assert_eq(timeline.gate_layers_for_tick(1), neutral, "and before everything, that of the first known state")


func test_unknown_fields_and_wrong_types_are_skipped() -> void:
	var timeline := FortressTimeline.new(_def)
	var changes := NetMessages.ObjectState.new()
	changes.net_id = NET_ID
	changes.tick = 100
	changes.add_field(250, NetMessages.ObjectField.ValueType.U16, 7)
	changes.add_field(FortressFields.OWNER, NetMessages.ObjectField.ValueType.U32, 2)
	assert_eq(timeline.apply_object_state(changes), 0, "neither an unknown id nor a wrong type counts")
	assert_false(timeline.has_state(), "and if nothing is applied nothing is recorded")
	changes.add_field(FortressFields.GATE_HEALTH, NetMessages.ObjectField.ValueType.U32, 1234)
	assert_eq(timeline.apply_object_state(changes), 1, "only the good field")
	assert_eq(timeline.state_at(100).gate_health, 1234)
	assert_eq(timeline.state_at(100).owner, 0, "the wrong-type one was not applied")
	assert_eq(timeline.apply_object_state(null), 0)


func test_a_message_out_of_order_is_inserted_and_the_next_states_are_rebuilt() -> void:
	var timeline := FortressTimeline.new(_def)
	timeline.apply_object_state(_spawn_message(100))
	timeline.apply_object_state(_change(300, {FortressFields.GATE_HEALTH: 100}))
	# A change from tick 200 arrives late: the one at 300 has to see it.
	timeline.apply_object_state(_change(200, {FortressFields.OWNER: SOLMARCH}))
	assert_eq(timeline.get_entry_count(), 3)
	assert_eq(timeline.state_at(250).owner, SOLMARCH)
	assert_eq(timeline.state_at(250).gate_health, 9000, "at 250 the gate is still intact")
	assert_eq(timeline.state_at(300).owner, SOLMARCH, "the change at 300 inherits the owner from the one at 200")
	assert_eq(timeline.state_at(300).gate_health, 100)
	# Two messages with the same tick accumulate in the order they arrived.
	timeline.apply_object_state(_change(300, {FortressFields.GATE_HEALTH: 50}))
	assert_eq(timeline.state_at(300).gate_health, 50)
	assert_eq(timeline.state_at(300).owner, SOLMARCH)


func test_old_changes_are_pruned_but_a_base_stays() -> void:
	var timeline := FortressTimeline.new(_def)
	timeline.apply_object_state(_spawn_message(0))
	timeline.apply_object_state(_change(10, {FortressFields.OWNER: VARDHEIM}))
	for i: int in 700:
		timeline.apply_object_state(_change(20 + i * 6, {FortressFields.GATE_HEALTH: 8000 - i}))
	assert_true(timeline.get_entry_count() <= FortressTimeline.MAX_ENTRIES, "there is a cap on changes")
	assert_true(timeline.get_oldest_tick() > 10, "the oldest was pruned")
	assert_eq(timeline.state_at(timeline.get_oldest_tick()).owner, VARDHEIM,
			"the base keeps what was accumulated (the owner from the pruned change)")
	assert_eq(timeline.state_at(1).owner, VARDHEIM, "and a query earlier than the base returns the base")
	var count: int = timeline.get_entry_count()
	assert_eq(timeline.apply_object_state(_change(5, {FortressFields.OWNER: SOLMARCH})), 0,
			"a message earlier than the pruned base is ignored")
	assert_eq(timeline.get_entry_count(), count)
	# Pruning by time: a much newer change takes the old ones with it.
	timeline.apply_object_state(_change(100000, {FortressFields.OWNER: ASKARRA}))
	assert_eq(timeline.get_entry_count(), 2,
			"the new change remains and, as base, the last one before the last %d ticks"
			% FortressTimeline.RETAIN_TICKS)
	assert_eq(timeline.state_at(99999).owner, VARDHEIM, "the base stays valid until the new change")
	assert_eq(timeline.state_at(100001).owner, ASKARRA)


func test_progress_follows_the_capture_formula() -> void:
	var timeline := FortressTimeline.new(_def)
	var maximum: int = FortressState.initial(_def, 0).progress_max
	assert_eq(maximum, 21600, "30 s of capture: 1800 ticks · 12")
	timeline.apply_object_state(_spawn_message(50))
	assert_eq(timeline.progress_at(60.0), 0, "with no capture the progress is 0")
	# One attacker: 12 per tick from 100.
	timeline.apply_object_state(_change(100, {FortressFields.PHASE: FortressState.Phase.CAPTURING,
			FortressFields.CAPTURE_REALM: VARDHEIM, FortressFields.CAPTURE_START_TICK: 100,
			FortressFields.CAPTURE_RATE: 12, FortressFields.CAPTURE_PROGRESS_AT_START: 0}))
	assert_eq(timeline.progress_at(100.0), 0)
	assert_eq(timeline.progress_at(160.0), 720, "60 ticks · 12")
	assert_eq(timeline.progress_at(160.5), 726, "with a tick fraction")
	assert_eq(timeline.progress_at(100.0 + 1799.0), 21588)
	assert_eq(timeline.progress_at(100.0 + 1800.0), maximum, "at 30 s, the maximum")
	assert_eq(timeline.progress_at(100.0 + 5000.0), maximum, "and it does not go beyond")
	assert_near(timeline.progress_fraction_at(160.0), 720.0 / 21600.0, 1e-9)
	# It is contested at 300 (the progress at that tick becomes the anchor) and freezes.
	timeline.apply_object_state(_change(300, {FortressFields.CAPTURE_START_TICK: 300,
			FortressFields.CAPTURE_RATE: 0, FortressFields.CAPTURE_PROGRESS_AT_START: 2400,
			FortressFields.CONTESTED: 1}))
	assert_eq(timeline.progress_at(299.0), 2388, "before 300 the old formula still applies")
	assert_eq(timeline.progress_at(300.0), 2400)
	assert_eq(timeline.progress_at(900.0), 2400, "frozen")
	# It decays slowly (−4 per tick) and reaches 0 without going beyond.
	timeline.apply_object_state(_change(1000, {FortressFields.CAPTURE_START_TICK: 1000,
			FortressFields.CAPTURE_RATE: -4}))
	assert_eq(timeline.progress_at(1100.0), 2000, "−4 per tick for 100 ticks")
	assert_eq(timeline.progress_at(5000.0), 0, "the progress does not go below 0")


# --- FortressView: interface at the draw tick -------------------------------------------------

func test_the_view_applies_a_state_when_the_render_tick_reaches_it() -> void:
	await _build_view()
	var changes: Array[Dictionary] = []
	_view.state_changed.connect(func(net_id: int, state: FortressState, previous: FortressState) -> void:
		changes.append({"net_id": net_id, "owner": state.owner, "had_previous": previous != null}))
	_view.on_spawn(_spawn_for_fortress(100))
	assert_true(_view.has_fortress(NET_ID), "the SPAWN creates the fortress")
	assert_true(_view.is_bound(NET_ID), "and links it to the scene node")
	assert_null(_view.get_displayed_state(NET_ID), "no tick has been drawn yet")
	_view.advance(0.0)
	assert_null(_view.get_displayed_state(NET_ID), "with the clock not started nothing is applied")
	_view.advance(100.0)
	assert_eq(_view.get_displayed_state(NET_ID).owner, 0, "with the SPAWN on screen")
	assert_eq(changes.size(), 1, "the first time the state is emitted")
	assert_false(changes[0]["had_previous"])
	# A change from tick 160 arrives: it is not seen until the draw tick reaches it.
	assert_true(_view.on_object_state(_change(160, {FortressFields.OWNER: VARDHEIM,
			FortressFields.PHASE: FortressState.Phase.CONSOLIDATING})))
	assert_eq(_view.get_latest_state(NET_ID).owner, VARDHEIM, "the latest known is already the new one")
	_view.advance(130.0)
	_view.advance(159.9)
	assert_eq(_view.get_displayed_state(NET_ID).owner, 0, "at 159.9 the old one is still seen")
	assert_eq(changes.size(), 1, "and there is no signal")
	_view.advance(160.0)
	assert_eq(_view.get_displayed_state(NET_ID).owner, VARDHEIM, "at 160 it is applied")
	assert_eq(changes.size(), 2, "with one signal")
	assert_true(changes[1]["had_previous"])
	_view.advance(161.0)
	_view.advance(400.0)
	assert_eq(changes.size(), 2, "with no new changes the signal is not repeated")


func test_banners_take_the_owner_color_in_the_draw_tick() -> void:
	await _build_view()
	var neutral_color: Color = RealmCatalog.color_of(RealmCatalog.HUECOS)
	_view.on_spawn(_spawn_for_fortress(100))
	assert_true(_view.get_banners(NET_ID).size() >= 3, "tower banner and the two gate ones (%d)"
			% _view.get_banners(NET_ID).size())
	_view.advance(100.0)
	assert_true(_view.has_banner_color(NET_ID))
	assert_true(_banner_colors_are(neutral_color), "neutral: the Hollow's bone grey")
	_view.on_object_state(_change(200, {FortressFields.OWNER: VARDHEIM}))
	_view.advance(199.0)
	assert_true(_banner_colors_are(neutral_color), "before tick 200 the banners are still neutral")
	_view.advance(200.0)
	assert_true(_banner_colors_are(RealmCatalog.color_of(RealmCatalog.VARDHEIM)),
			"at 200 they turn to Vardheim's blue (faction_color)")
	assert_eq(_view.get_banner_color(NET_ID), RealmCatalog.color_of(RealmCatalog.VARDHEIM))
	_view.on_object_state(_change(300, {FortressFields.OWNER: SOLMARCH}))
	_view.advance(300.0)
	assert_true(_banner_colors_are(RealmCatalog.color_of(RealmCatalog.SOLMARCH)), "and then to Solmarch's gold")
	_view.on_object_state(_change(400, {FortressFields.OWNER: 0}))
	_view.advance(400.0)
	assert_true(_banner_colors_are(neutral_color), "and neutral again after a reset")


func test_the_gate_pose_follows_the_draw_tick_and_the_movement_layers_follow_the_hook() -> void:
	await _build_view()
	var gate: FortGate = _view.get_gate(NET_ID)
	if not assert_null(gate, "before the SPAWN the view does not know the gate"):
		return
	_view.on_spawn(_spawn_for_fortress(100))
	gate = _view.get_gate(NET_ID)
	if not assert_not_null(gate, "with the SPAWN it links the scene's gate"):
		return
	_view.on_object_state(_change(200, {FortressFields.OWNER: VARDHEIM}))
	_view.on_object_state(_change(300, {FortressFields.GATE_HEALTH: 0}))
	var neutral: int = FortGate.layers_for(0, false)
	var vardheim: int = FortGate.layers_for(VARDHEIM, false)
	# The prediction runs ahead of the drawing: it simulates tick 250 while 150 is being drawn.
	_view.advance(150.0)
	_view.before_simulate(250)
	assert_eq(gate.collision_layer, vardheim, "the collision is that of the simulated tick (250), not of the drawing")
	assert_eq(gate.get_owner_realm(), 0, "while the pose follows that of the draw tick (150)")
	assert_false(gate.is_broken())
	# When drawing 200 the pose changes, but the collision set by the prediction is not overwritten.
	_view.advance(200.0)
	assert_eq(gate.get_owner_realm(), VARDHEIM, "the pose switches to the new owner's")
	assert_eq(gate.collision_layer, vardheim, "and the collision remains that of the last simulated tick")
	# The hook also goes backwards (reconciliation replays).
	_view.before_simulate(150)
	assert_eq(gate.collision_layer, neutral, "when simulating 150 the gate was neutral")
	_view.before_simulate(301)
	assert_eq(gate.collision_layer, 0, "and from 301 it is broken: no layers")
	_view.advance(300.0)
	assert_true(gate.is_broken(), "when drawing 300 the leaves hang")
	assert_eq(gate.collision_layer, 0, "without touching the simulated tick's collision")
	assert_eq(_view.get_gate_movement_layers(NET_ID), 0)
	assert_true(int(_view.get_stats()["hook_calls"]) == 3, "three calls to the hook")


func test_a_view_that_finds_its_scene_late_binds_and_paints_then() -> void:
	await _build_view(false)
	_view.on_spawn(_spawn_for_fortress(100))
	_view.on_object_state(_change(150, {FortressFields.OWNER: SOLMARCH}))
	assert_false(_view.is_bound(NET_ID), "with no zone loaded there is no node")
	_view.before_simulate(200)
	_view.advance(160.0)
	assert_eq(_view.get_displayed_state(NET_ID).owner, SOLMARCH, "the state is still stored and shown")
	assert_false(_view.has_banner_color(NET_ID) and _view.is_bound(NET_ID))
	# The zone appears (it loads after the SPAWN).
	_add_zone()
	_view.set_zone(_zone)
	assert_true(_view.is_bound(NET_ID), "when given the zone it links up")
	assert_true(_banner_colors_are(RealmCatalog.color_of(RealmCatalog.SOLMARCH)),
			"and paints what was already being shown")
	assert_eq(_view.get_gate(NET_ID).get_owner_realm(), SOLMARCH, "the gate too")
	_view.before_simulate(200)
	assert_eq(_view.get_gate(NET_ID).collision_layer, FortGate.layers_for(SOLMARCH, false))


func test_the_group_and_metadata_names_match_the_zone_registry() -> void:
	# The networking code does not name Zones: FortressView repeats these names and here we check they are the same.
	assert_eq(FortressView.FORTRESS_GROUP, Zones.FORTRESS_GROUP)
	assert_eq(FortressView.DEFINITION_META, Zones.FORTRESS_DEFINITION_META)
	assert_eq(RespawnPointList.GROUP, Zones.RESPAWN_GROUP)


func test_scene_geometry_is_available_for_the_hud() -> void:
	await _build_view()
	assert_eq(_view.get_circle_center(NET_ID), Vector3.INF, "without a SPAWN there is nothing to query")
	_view.on_spawn(_spawn_for_fortress(100))
	assert_near(_view.get_circle_radius(NET_ID), 5.0, 1e-6, "the radius comes from the marker, 5 m")
	var circle: Node3D = _fort.get_node(^"CaptureCircle") as Node3D
	assert_vec_near(_view.get_circle_center(NET_ID), circle.global_position, 1e-6)
	assert_vec_near(_view.get_gate_position(NET_ID), _fort.get_node(^"FortGate").global_position, 1e-6)
	assert_vec_near(_view.get_anchor_position(NET_ID), _fort.global_position, 1e-6)
	assert_eq(String(_view.get_definition_id(NET_ID)), FORTRESS_ID)
	assert_eq(_view.get_definition(NET_ID).id, &"vado_gris_fort", "the definition comes from the scene metadata")
	assert_eq(_view.get_primary_id(), NET_ID)


func test_unknown_structures_and_empty_messages_are_ignored() -> void:
	await _build_view()
	assert_false(_view.on_object_state(_change(100, {FortressFields.OWNER: VARDHEIM})),
			"an OBJECT_STATE for a fortress that is not known is discarded")
	assert_eq(_view.get_stats()["ignored_states"], 1, "and counted")
	assert_false(_view.on_spawn(null))
	var player := NetMessages.EntitySpawn.new()
	player.kind = NetProtocol.EntityKind.PLAYER
	assert_false(_view.on_spawn(player), "only the structures")
	_view.on_spawn(_spawn_for_fortress(100))
	var unknown_only := NetMessages.ObjectState.new()
	unknown_only.net_id = NET_ID
	unknown_only.tick = 120
	unknown_only.add_field(99, NetMessages.ObjectField.ValueType.U8, 1)
	assert_false(_view.on_object_state(unknown_only), "a message with only unknown fields changes nothing")
	assert_eq(_view.get_timeline(NET_ID).get_entry_count(), 1)
	# A second SPAWN of the same structure (leaving interest and coming back) is just one more change.
	assert_true(_view.on_spawn(_spawn_for_fortress(500, {FortressFields.OWNER: ASKARRA})))
	assert_eq(_view.get_fortress_ids().size(), 1)
	assert_eq(_view.get_latest_state(NET_ID).owner, ASKARRA)
	assert_eq(_view.get_progress(NET_ID + 1, 100.0), 0, "an unknown fortress has no progress")


func test_the_view_loads_the_definition_without_a_scene() -> void:
	await _build_view(false)
	_view.on_spawn(_spawn_for_fortress(100))
	var definition: FortressDefinition = _view.get_definition(NET_ID)
	if not assert_not_null(definition):
		return
	assert_eq(definition.id, &"vado_gris_fort", "without a scene, the definition comes from data/fortresses by its id")
	assert_eq(_view.get_timeline(NET_ID).state_at(100).progress_max, 21600, "with its timings")
	_view.on_object_state(_change(100, {FortressFields.CAPTURE_REALM: VARDHEIM, FortressFields.CAPTURE_RATE: 12,
			FortressFields.CAPTURE_START_TICK: 100, FortressFields.PHASE: FortressState.Phase.CAPTURING}))
	assert_eq(_view.get_progress(NET_ID, 160.0), 720)
	assert_near(_view.get_progress_fraction(NET_ID, 100.0 + 900.0), 0.5, 1e-9, "halfway through the capture")


func test_states_by_definition_feed_the_respawn_rules() -> void:
	await _build_view()
	_view.on_spawn(_spawn_for_fortress(100, {FortressFields.OWNER: VARDHEIM}))
	_view.on_object_state(_change(300, {FortressFields.UNDER_ATTACK_UNTIL_TICK: 2000}))
	var states: Dictionary = _view.get_states_by_definition(200)
	assert_true(states.has(&"vado_gris_fort"), "the key is the definition id")
	# The test zone only has the fortress: the points inside the fort are set by the test.
	var points: Array[Node3D] = _fort_points()
	var valid: PackedInt32Array = RespawnRules.points_for(VARDHEIM, points, states, 200)
	assert_eq(valid.size(), 4, "with Vardheim's fort at rest its four points are valid")
	var attacked: PackedInt32Array = RespawnRules.points_for(VARDHEIM, points, _view.get_states_by_definition(400), 400)
	assert_eq(attacked.size(), 0, "\"attacked\" until tick 2000: none")
	assert_eq(RespawnRules.points_for(SOLMARCH, points, states, 200).size(), 0, "and for Solmarch never")


# --- Helpers ----------------------------------------------------------------------------------

# A zone with the fort (as the generator leaves it: group and definition metadata) and a view.
func _build_view(with_zone: bool = true) -> void:
	_view = FortressView.new()
	tree.root.add_child(_view)
	if with_zone:
		_add_zone()
		_view.set_zone(_zone)
	await wait_physics_frames(2)


func _add_zone() -> void:
	_zone = Node3D.new()
	_zone.name = "ZonaDePrueba"
	tree.root.add_child(_zone)
	var scene: PackedScene = load(FORT_SCENE_PATH) as PackedScene
	_fort = scene.instantiate() as Node3D
	_fort.name = "Fuerte"
	_fort.add_to_group(Zones.FORTRESS_GROUP)
	_fort.set_meta(Zones.FORTRESS_DEFINITION_META, DEFINITION_PATH)
	_zone.add_child(_fort)


# Four markers like those inside the fort (fortress metadata and no realm).
func _fort_points() -> Array[Node3D]:
	var points: Array[Node3D] = []
	for i: int in 4:
		var point := Marker3D.new()
		point.set_meta(Zones.FORTRESS_META, &"vado_gris_fort")
		_zone.add_child(point)
		points.append(point)
	return points


func _state_with(values: Dictionary) -> FortressState:
	var state := FortressState.initial(_def, 0)
	for field_id: int in values:
		FortressFields.set_value(state, field_id, int(values[field_id]))
	return state


func _spawn_message(tick: int) -> NetMessages.ObjectState:
	return NetMessages.ObjectState.from_fortress(NET_ID, tick, FortressState.initial(_def, tick))


func _spawn_for_fortress(tick: int, values: Dictionary = {}) -> NetMessages.EntitySpawn:
	var state: FortressState = FortressState.initial(_def, tick)
	for field_id: int in values:
		FortressFields.set_value(state, field_id, int(values[field_id]))
	return NetMessages.EntitySpawn.decode(NetMessages.EntitySpawn.for_fortress(NET_ID, tick,
			FORTRESS_ID, state).encode())


# OBJECT_STATE (passed through encode/decode) with only the fields in [param values] (id -> value).
func _change(tick: int, values: Dictionary) -> NetMessages.ObjectState:
	var message := NetMessages.ObjectState.new()
	message.net_id = NET_ID
	message.tick = tick
	for field_id: int in values:
		message.add_field(field_id, FortressFields.value_type(field_id), int(values[field_id]))
	return NetMessages.ObjectState.decode(message.encode())


func _banner_colors_are(expected: Color) -> bool:
	var banners: Array[MeshInstance3D] = _view.get_banners(NET_ID)
	if banners.is_empty():
		return false
	for mesh: MeshInstance3D in banners:
		var color: Variant = mesh.get("instance_shader_parameters/faction_color")
		if typeof(color) != TYPE_COLOR or not (color as Color).is_equal_approx(expected):
			return false
	return true
