extends TestCase
## GUE-14 and UI-21, end to end: after a real capture on the server, the respawn index that the client
## computes from the map ([RespawnPointList], the same list the death screen and [WorldMap] use) puts the
## player inside the freshly captured fort, and the server refuses what the client should never send: an
## enemy fort, a fort that is being attacked or a fort that is not owned yet.
## [br][br]
## The server is the F3 one from [FortressFixture] (circle, captain, gate and respawn markers: two camps
## and the fort's interior), advanced by hand with a [FortressFixture.Stepper].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const FORTRESS: StringName = FortressFixture.FORTRESS_ID

var _viewport: SubViewport
var _world: Node3D
var _server: ZoneServer
var _stepper: FortressFixture.Stepper
var _respawns: Array[NetMessages.EntityEvent] = []


func after_each() -> void:
	if is_instance_valid(_server):
		_server.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_server = null
	_world = null
	_viewport = null
	_stepper = null
	_respawns.clear()
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _start_server() -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	FortressFixture.add_fortress(_world, FortressFixture.make_definition())
	FortressFixture.add_respawn_points(_world)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	config.max_players = 32
	config.no_dummies = true
	assert_eq(_server.start(config, _world, null, DevAuthProvider.new()), OK, "the server starts")
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void:
		if event.event == NetMessages.EntityEvent.Kind.RESPAWN:
			_respawns.append(event))
	_server.set_physics_process(false)
	_stepper = FortressFixture.Stepper.new()
	_stepper.server = _server
	_viewport.add_child(_stepper)


func _advance(ticks: int) -> void:
	_stepper.remaining += ticks
	while _stepper.remaining > 0:
		await tree.physics_frame


func _brain() -> CombatFixture.ScriptBrain:
	return CombatFixture.ScriptBrain.new(1)


func _idle_player(realm: int, position: Vector3) -> int:
	var net_id: int = _server.add_fake_player(_brain(), realm)
	_server.teleport(net_id, position)
	return net_id


func _combatant(net_id: int) -> Combatant:
	return _server.get_combat().get_combatant(net_id)


func _state() -> FortressState:
	return _server.get_fortresses().get_fortress_state(FORTRESS)


## What the client sees of the fort: the same state the server replicates, keyed by the fort's id as
## [method FortressView.get_states_by_definition] does.
func _client_states() -> Dictionary:
	return {FORTRESS: _state()}


## Vardheim takes the fort for real: the captain falls and a Vardheim player holds the circle through the
## capture and the consolidation, until the garrison is back.
func _capture_for_vardheim() -> void:
	var captain: int = _server.spawn_captain_double(FORTRESS)
	assert_true(captain > 0, "the captain double appears")
	_idle_player(VARDHEIM, FortressFixture.circle_center())
	await _advance(120)
	_server.console_command("fort_kill_captain")
	await _advance(210)
	assert_eq(_state().owner, VARDHEIM, "captured by Vardheim")
	await _advance(130)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "and settled")


## Kills [param net_id] and waits for its respawn window, like the death screen does.
func _die_and_wait(net_id: int) -> void:
	_server.console_command("kill %d" % net_id)
	await _advance(2)
	var wait_ticks: int = _combatant(net_id).respawn_tick - _server.get_tick() - 6
	await _advance(maxi(wait_ticks, 0))


func _request(net_id: int, index: int) -> int:
	return _server.get_combat().request_respawn(net_id, index, _server.get_tick() + 1)


func _last_respawn(net_id: int) -> NetMessages.EntityEvent:
	for i: int in range(_respawns.size() - 1, -1, -1):
		if _respawns[i].net_id == net_id:
			return _respawns[i]
	return null


func _fort_option(options: Array[RespawnPointList.Option]) -> RespawnPointList.Option:
	for option: RespawnPointList.Option in options:
		if option.fortress_id == FORTRESS:
			return option
	return null


# --- The tests --------------------------------------------------------------------------------

func test_respawning_from_the_map_index_puts_the_player_in_the_freshly_captured_fort() -> void:
	await _start_server()
	await _capture_for_vardheim()
	var ally: int = _idle_player(VARDHEIM, Vector3(-20.0, 0.05, 6.0))
	await _advance(5)
	await _die_and_wait(ally)
	# The client builds its options from the zone and the replicated state, exactly as the map does.
	var options: Array[RespawnPointList.Option] = RespawnPointList.options(_world, VARDHEIM, _client_states(),
			_server.get_tick())
	var fort: RespawnPointList.Option = _fort_option(options)
	if not assert_not_null(fort, "the map offers the fort as a site"):
		return
	assert_true(fort.valid, "and, with the fort theirs and calm, as a valid one")
	var index: int = fort.index_for(ally)
	assert_true(fort.has_member(index), "the index it sends is one of the fort's markers")
	assert_eq(_request(ally, index), CombatDirector.RespawnRequestResult.ACCEPTED, "the server accepts it")
	await _advance(10)
	var event: NetMessages.EntityEvent = _last_respawn(ally)
	if not assert_not_null(event, "the respawn happens"):
		return
	assert_eq(event.point, index, "the event carries the index that was asked for")
	var inner: Vector3 = FortressFixture.ORIGIN + FortressFixture.INNER_POINTS_LOCAL[0]
	var landed: Vector3 = _server.get_registry().get_entity(ally).get_position()
	assert_true(landed.distance_to(inner) < 6.0, "the player stands inside the fort (%s)" % landed)
	assert_true(landed.distance_to(FortressFixture.VARDHEIM_CAMP) > 20.0, "and not at the camp")


func test_the_server_rejects_an_enemy_fort_even_if_a_client_sends_its_index() -> void:
	await _start_server()
	await _capture_for_vardheim()
	var enemy: int = _idle_player(SOLMARCH, Vector3(20.0, 0.05, 6.0))
	await _advance(5)
	await _die_and_wait(enemy)
	var options: Array[RespawnPointList.Option] = RespawnPointList.options(_world, SOLMARCH, _client_states(),
			_server.get_tick())
	var fort: RespawnPointList.Option = _fort_option(options)
	if not assert_not_null(fort, "the map still lists the fort"):
		return
	assert_false(fort.valid, "but greyed out for the rival")
	assert_eq(RespawnPointList.valid_options(_world, SOLMARCH, _client_states(), _server.get_tick()).size(), 1,
			"only its own camp can be chosen")
	# A modified client sends the fort's index anyway: the server decides, and it is the camp.
	var forged: int = fort.index_for(enemy)
	assert_eq(_request(enemy, forged), CombatDirector.RespawnRequestResult.ACCEPTED,
			"the request is processed")
	await _advance(10)
	var landed: Vector3 = _server.get_registry().get_entity(enemy).get_position()
	assert_vec_near(landed, FortressFixture.SOLMARCH_CAMP, 1.0, "and the player comes out at their own camp")
	var event: NetMessages.EntityEvent = _last_respawn(enemy)
	if assert_not_null(event, "with its respawn event"):
		assert_true(not fort.has_member(event.point), "which does not point at the enemy fort")


func test_a_fort_under_attack_is_greyed_out_and_the_server_sends_the_player_to_the_camp() -> void:
	await _start_server()
	await _capture_for_vardheim()
	var ally: int = _idle_player(VARDHEIM, Vector3(-20.0, 0.05, 6.0))
	await _advance(5)
	await _die_and_wait(ally)
	# Solmarch hits the fort's defenders just before the player decides.
	_state().on_defender_damaged(_server.get_tick(), SOLMARCH)
	var options: Array[RespawnPointList.Option] = RespawnPointList.options(_world, VARDHEIM, _client_states(),
			_server.get_tick())
	var fort: RespawnPointList.Option = _fort_option(options)
	if not assert_not_null(fort, "the fort is listed"):
		return
	assert_false(fort.valid, "while it is under attack it cannot be chosen on the map")
	var stale: int = fort.index_for(ally)
	_request(ally, stale)
	await _advance(10)
	assert_vec_near(_server.get_registry().get_entity(ally).get_position(), FortressFixture.VARDHEIM_CAMP, 1.0,
			"a request that arrives anyway lands at the camp")


func test_a_fort_that_nobody_owns_yet_is_not_a_choice() -> void:
	await _start_server()
	var ally: int = _idle_player(VARDHEIM, Vector3(-20.0, 0.05, 6.0))
	await _advance(5)
	await _die_and_wait(ally)
	var fort: RespawnPointList.Option = _fort_option(RespawnPointList.options(_world, VARDHEIM,
			_client_states(), _server.get_tick()))
	if not assert_not_null(fort, "the fort is listed"):
		return
	assert_false(fort.valid, "neutral: greyed out")
	_request(ally, fort.index_for(ally))
	await _advance(10)
	assert_vec_near(_server.get_registry().get_entity(ally).get_position(), FortressFixture.VARDHEIM_CAMP, 1.0,
			"and the server puts the player at their camp")
