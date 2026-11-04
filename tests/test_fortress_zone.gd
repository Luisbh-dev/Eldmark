extends TestCase
## The fort server on the real zone, Vado Gris (docs/fortress.md, sections 1 to 5): the fortress from the
## [code]fortresses[/code] group with its definition, circle and gate; the 12 respawn points (camps
## first, then the inside of the fort) and which ones are valid depending on the owner; a real hit on the
## gate, which no collider of the zone stops; and a capture with fake players on the real terrain. It
## advances quickly with a [FortressFixture.Stepper].

const ZONE_ID: String = "vado_gris"
const DEFINITION_ID: StringName = &"vado_gris_fort"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const YAW_EAST: float = -PI * 0.5

var _world: Node3D
var _server: ZoneServer
var _stepper: FortressFixture.Stepper
var _war: Array[NetMessages.EntityEvent] = []


func before_each() -> void:
	var packed: PackedScene = load(NetZones.scene_path(ZONE_ID)) as PackedScene
	_world = packed.instantiate() as Node3D
	tree.root.add_child(_world)
	var zone_root: ZoneRoot = _world as ZoneRoot
	if zone_root != null:
		zone_root.strip_for_server()
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	tree.root.add_child(_server)
	await wait_physics_frames(4)
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.max_players = 16
	config.no_dummies = true
	# This test talks about the fort with the captain double (spawn_captain_double): without the real NPCs.
	config.no_npcs = true
	assert_eq(_server.start(config, _world, null, DevAuthProvider.new()), OK, "the server starts")
	_server.get_fortresses().war_event_emitted.connect(func(event: NetMessages.EntityEvent) -> void:
		_war.append(event))
	_server.set_physics_process(false)
	_stepper = FortressFixture.Stepper.new()
	_stepper.server = _server
	tree.root.add_child(_stepper)


func after_each() -> void:
	if is_instance_valid(_stepper):
		_stepper.get_parent().remove_child(_stepper)
		_stepper.free()
	if is_instance_valid(_server):
		_server.get_parent().remove_child(_server)
		_server.free()
	if is_instance_valid(_world):
		_world.get_parent().remove_child(_world)
		_world.queue_free()
	_server = null
	_world = null
	_stepper = null
	_war.clear()
	await wait_process_frames()


func _advance(ticks: int) -> void:
	_stepper.remaining += ticks
	while _stepper.remaining > 0:
		await tree.physics_frame


func _state() -> FortressState:
	return _server.get_fortresses().get_fortress_state(DEFINITION_ID)


func _brain(script: Callable = Callable()) -> CombatFixture.ScriptBrain:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = script
	return brain


func test_the_server_builds_the_vado_gris_fortress_from_the_scene() -> void:
	var fortresses: FortressController = _server.get_fortresses()
	if not assert_eq(fortresses.get_fortress_ids(), [DEFINITION_ID] as Array[StringName], "one fortress"):
		return
	var fort: Node3D = fortresses.get_node_of(DEFINITION_ID)
	assert_eq(fort.name, &"Fuerte")
	var definition: FortressDefinition = fortresses.get_definition(DEFINITION_ID)
	assert_eq(definition.gate_health, 9000)
	assert_eq(definition.capture_s, 30.0)
	assert_eq(_state().gate_health, 9000)
	assert_eq(_state().gate_max, 9000)
	var circle: Dictionary = fortresses.get_circle(DEFINITION_ID)
	assert_vec_near(circle["center"], fort.global_position + Vector3(-8.5, 0.05, 0.0), 1e-3,
			"the circle is the CaptureCircle marker")
	assert_eq(circle["radius"], 5.0, "with the marker's radius")
	var gate: FortGate = fortresses.get_gate(DEFINITION_ID)
	if assert_not_null(gate, "the scene's gate"):
		var targets: Array[StructureTarget] = fortresses.get_structure_targets()
		assert_eq(targets.size(), 1)
		assert_vec_near(targets[0].box.origin, gate.global_position + Vector3(0.0, 2.15, 0.0), 1e-3)
		assert_vec_near(targets[0].half_extents, Vector3(0.25, 2.15, 2.0), 1e-3)
		assert_eq(gate.collision_layer, FortGate.layers_for(0, false), "closed to the three realms")
	assert_eq(_server.get_combat_timing().respawn_wave_ticks, 600, "10 s waves")
	assert_eq(_server.get_combat().get_all_respawn_points().size(), 12, "the static list: 8 + 4")
	assert_eq(_server.get_registry().size(), 1, "only the fortress")


func test_the_vado_gris_definition_restarts_the_fort_every_thirty_minutes() -> void:
	var definition: FortressDefinition = _server.get_fortresses().get_definition(DEFINITION_ID)
	var thirty_minutes: int = 30 * 60 * CombatCatalog.TICK_RATE
	assert_eq(definition.reset_to_neutral_ticks(), thirty_minutes, "1800 s in ticks")
	assert_eq(_state().last_reset_tick, 0, "the reset clock starts with the server")
	# The same definition, without a server: exactly at 30 min, and not one tick earlier, it goes back to neutral.
	var state: FortressState = FortressState.initial(definition, 0)
	state.owner = SOLMARCH
	var nobody := PackedInt32Array([0, 0, 0, 0])
	assert_true(state.advance(definition, thirty_minutes - 1, nobody).is_empty(), "one tick earlier, nothing")
	assert_eq(state.owner, SOLMARCH)
	assert_eq(state.advance(definition, thirty_minutes, nobody),
			PackedInt32Array([WarEvents.FORT_RESET]), "at 30 min, the reset alert")
	assert_eq(state.owner, 0)
	assert_eq(state.last_reset_tick, thirty_minutes, "and the clock starts counting again")


func test_which_respawn_points_are_valid_depends_on_the_owner_of_the_fort() -> void:
	var combat: CombatDirector = _server.get_combat()
	assert_eq(combat.get_valid_respawn_points(VARDHEIM, 10), PackedInt32Array([0, 1, 2, 3]),
			"neutral: only the own camp")
	assert_eq(combat.get_valid_respawn_points(SOLMARCH, 10), PackedInt32Array([4, 5, 6, 7]))
	_server.console_command("fort_owner vardheim")
	await _advance(3)
	assert_eq(combat.get_valid_respawn_points(VARDHEIM, _server.get_tick()),
			PackedInt32Array([0, 1, 2, 3, 8, 9, 10, 11]), "Vardheim's: the camp and the inside")
	assert_eq(combat.get_valid_respawn_points(SOLMARCH, _server.get_tick()), PackedInt32Array([4, 5, 6, 7]),
			"Solmarch still cannot choose the enemy fort")
	# A reset leaves it neutral again.
	_server.console_command("fort_reset")
	await _advance(3)
	assert_eq(combat.get_valid_respawn_points(VARDHEIM, _server.get_tick()), PackedInt32Array([0, 1, 2, 3]))


func test_a_real_swing_hits_the_real_gate() -> void:
	var fortresses: FortressController = _server.get_fortresses()
	var gate: FortGate = fortresses.get_gate(DEFINITION_ID)
	var gate_position: Vector3 = gate.global_position
	var press_tick: int = 90
	var attacker: int = _server.add_fake_player(_brain(func(tick: int, _position: Vector3,
			_yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = YAW_EAST
		if tick >= press_tick and tick < press_tick + 2:
			input.buttons = PlayerInput.PRIMARY
		return input), VARDHEIM)
	# 2.25 m from the west face of the gate, a few centimetres above the ground: it falls and settles.
	_server.teleport(attacker, gate_position + Vector3(-2.5, 0.4, 0.0))
	_server.get_registry().get_entity(attacker).get_character().yaw = YAW_EAST
	await _advance(150)
	assert_eq(_state().gate_health, 9000 - roundi(90.0 * 0.35), "the real hit removes what the data says")
	assert_eq(_war.size(), 1, "and alerts that the fort is being attacked")
	assert_eq(_war[0].war_event, WarEvents.UNDER_ATTACK)


func test_a_full_capture_on_the_real_terrain() -> void:
	var fortresses: FortressController = _server.get_fortresses()
	var circle: Vector3 = fortresses.get_circle(DEFINITION_ID)["center"]
	var captain: int = _server.spawn_captain_double(DEFINITION_ID)
	assert_true(captain > 0)
	var player: int = _server.add_fake_player(_brain(), VARDHEIM)
	_server.teleport(player, circle + Vector3(0.0, 0.3, 0.0))
	await _advance(60)
	assert_eq(_state().presence[VARDHEIM], 1, "inside the Vado Gris circle")
	assert_eq(_server.console_command("fort_capture_speed 30"), "Captura de %s a x30" % DEFINITION_ID)
	assert_true(_server.console_command("fort_kill_captain").contains("ha muerto"))
	await _advance(120)
	assert_eq(_state().owner, VARDHEIM, "captured")
	assert_eq(_server.get_fortresses().get_gate(DEFINITION_ID).get_owner_realm(), VARDHEIM)
	var ids: Array[int] = []
	for event: NetMessages.EntityEvent in _war:
		ids.append(event.war_event)
	assert_eq(ids, [WarEvents.CAPTAIN_DOWN, WarEvents.CAPTURE_STARTED, WarEvents.FORT_CAPTURED] as Array[int])
