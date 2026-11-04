extends TestCase
## The fort server with real clients over ENet on 127.0.0.1, in a single process (package F3):
## what a client sees of a full capture (the fortress SPAWN, the OBJECT_STATEs and the WAR notices
## in order), the KILL to the whole zone, the scoreboard every 2 s in pages, leaving and disconnecting in
## combat (GUE-41) and the /atascado command (MUN-41). The clients are [RawClient]s that speak the protocol by
## hand, as in [code]test_zone_server_net.gd[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const FORTRESS: StringName = FortressFixture.FORTRESS_ID
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const FIRST_PORT: int = 25400
const MAX_FRAMES: int = 600

var _viewport: SubViewport
var _world: Node3D
var _server: ZoneServer
var _server_transport: NetTransport
var _port: int = 0
var _clients: Array[RawClient] = []
var _client_tick: int = 0
var _next_client_index: int = 0


## A client that speaks the protocol by hand and stores everything it receives, including the fortress stuff.
class RawClient:
	extends RefCounted

	var transport: NetTransport
	var hello: PackedByteArray
	var welcome: NetMessages.Welcome = null
	var reject: NetMessages.Reject = null
	var connected: bool = false
	var disconnected: bool = false
	var own_spawn: NetMessages.EntitySpawn = null
	var spawns: Array[NetMessages.EntitySpawn] = []
	var despawns: Array[NetMessages.EntityDespawn] = []
	var snapshots: Array[NetMessages.Snapshot] = []
	var notices: Array[NetMessages.Notice] = []
	var events: Array[NetMessages.EntityEvent] = []
	var object_states: Array[NetMessages.ObjectState] = []
	var scoreboards: Array[NetMessages.Scoreboard] = []
	var malformed: int = 0

	func _init(p_transport: NetTransport, p_hello: PackedByteArray) -> void:
		transport = p_transport
		hello = p_hello
		transport.peer_authenticating.connect(func(peer_id: int) -> void:
			transport.send_auth(peer_id, hello))
		transport.auth_received.connect(_on_auth_received)
		transport.peer_connected.connect(func(_peer_id: int) -> void:
			connected = true
			transport.send(1, NetProtocol.CH_RELIABLE, NetMessages.ClientReady.new().encode()))
		transport.peer_disconnected.connect(func(_peer_id: int) -> void: disconnected = true)
		transport.packet_received.connect(_on_packet)

	func _on_auth_received(peer_id: int, bytes: PackedByteArray) -> void:
		var result: int = NetMessages.peek_auth_result(bytes)
		if result == NetProtocol.Result.OK:
			welcome = NetMessages.Welcome.decode(bytes)
			transport.complete_auth(peer_id)
		elif result > 0:
			reject = NetMessages.Reject.decode(bytes)

	func _on_packet(_peer_id: int, bytes: PackedByteArray) -> void:
		match NetMessages.peek_type(bytes):
			NetProtocol.MSG_ENTITY_SPAWN:
				var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
				if spawn == null:
					malformed += 1
					return
				spawns.append(spawn)
				if spawn.is_yours:
					own_spawn = spawn
			NetProtocol.MSG_ENTITY_DESPAWN:
				var despawn: NetMessages.EntityDespawn = NetMessages.EntityDespawn.decode(bytes)
				if despawn != null:
					despawns.append(despawn)
			NetProtocol.MSG_SNAPSHOT:
				var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
				if snapshot != null:
					snapshots.append(snapshot)
			NetProtocol.MSG_NOTICE:
				var notice: NetMessages.Notice = NetMessages.Notice.decode(bytes)
				if notice != null:
					notices.append(notice)
			NetProtocol.MSG_ENTITY_EVENT:
				var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
				if event == null:
					malformed += 1
				else:
					events.append(event)
			NetProtocol.MSG_OBJECT_STATE:
				var object_state: NetMessages.ObjectState = NetMessages.ObjectState.decode(bytes)
				if object_state == null:
					malformed += 1
				else:
					object_states.append(object_state)
			NetProtocol.MSG_SCOREBOARD:
				var board: NetMessages.Scoreboard = NetMessages.Scoreboard.decode(bytes)
				if board == null:
					malformed += 1
				else:
					scoreboards.append(board)

	func send_raw(channel: int, bytes: PackedByteArray) -> Error:
		return transport.send(1, channel, bytes)

	func events_of(kind: int) -> Array[NetMessages.EntityEvent]:
		var found: Array[NetMessages.EntityEvent] = []
		for event: NetMessages.EntityEvent in events:
			if event.event == kind:
				found.append(event)
		return found

	func war_ids() -> Array[int]:
		var ids: Array[int] = []
		for event: NetMessages.EntityEvent in events_of(NetMessages.EntityEvent.Kind.WAR):
			ids.append(event.war_event)
		return ids

	## The realms that accompany the notices of type [param war_event], in the order they arrived.
	func war_realms_of(war_event: int) -> Array[int]:
		var realms: Array[int] = []
		for event: NetMessages.EntityEvent in events_of(NetMessages.EntityEvent.Kind.WAR):
			if event.war_event == war_event:
				realms.append(event.war_realm)
		return realms

	func has_notice_containing(text: String) -> bool:
		for notice: NetMessages.Notice in notices:
			if notice.text.contains(text):
				return true
		return false


## Interest policy that hides the fake players (the \"Bot...\" ones) to test what goes to the whole zone.
class HidingPolicy:
	extends InterestPolicy

	func is_relevant(_observer: NetEntity, entity: NetEntity, _was_relevant: bool) -> bool:
		return not entity.display_name.begins_with("Bot")


func after_each() -> void:
	for client: RawClient in _clients:
		if is_instance_valid(client.transport):
			client.transport.free()
	_clients.clear()
	if is_instance_valid(_server):
		_server.free()
	if is_instance_valid(_server_transport):
		_server_transport.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_server = null
	_server_transport = null
	_world = null
	_viewport = null
	_client_tick = 0
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _start_server(definition: FortressDefinition = null, configure: Callable = Callable()) -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	FortressFixture.add_fortress(_world, definition if definition != null
			else FortressFixture.make_definition())
	FortressFixture.add_respawn_points(_world)
	_server_transport = NetTransport.new()
	_server_transport.name = "ServerTransport"
	_viewport.add_child(_server_transport)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	config.no_dummies = true
	_port = _find_free_port()
	config.port = _port
	if configure.is_valid():
		configure.call(config)
	assert_eq(_server.start(config, _world, _server_transport, DevAuthProvider.new()), OK,
			"the server opens port %d" % _port)


func _find_free_port() -> int:
	var start: int = FIRST_PORT + OS.get_process_id() % 40
	for port: int in range(start, start + 200):
		var probe := PacketPeerUDP.new()
		var error: Error = probe.bind(port, "*")
		probe.close()
		if error == OK:
			return port
	return -1


func _client_sim_hash() -> int:
	var character: PlayerCharacter = PLAYER_SCENE.instantiate() as PlayerCharacter
	_world.add_child(character)
	var hash_value: int = NetProtocol.compute_sim_hash(character)
	_world.remove_child(character)
	character.free()
	return hash_value


func _hello(realm: int, player_name: String) -> PackedByteArray:
	var hello := NetMessages.Hello.new()
	hello.protocol_version = NetProtocol.PROTOCOL_VERSION
	hello.sim_hash = _client_sim_hash()
	hello.realm = realm
	hello.display_name = player_name
	return hello.encode()


func _connect_client(realm: int, player_name: String) -> RawClient:
	var transport := NetTransport.new()
	transport.name = "ClientTransport%d" % _next_client_index
	_next_client_index += 1
	_viewport.add_child(transport)
	var client := RawClient.new(transport, _hello(realm, player_name))
	_clients.append(client)
	assert_eq(transport.connect_to("127.0.0.1", _port, 2000), OK, "the client connects")
	return client


func _step() -> void:
	await tree.physics_frame
	_client_tick += 1
	for client: RawClient in _clients:
		client.transport.poll(_client_tick)
	for client: RawClient in _clients:
		client.transport.flush()


func _run_frames(count: int) -> void:
	for _i: int in count:
		await _step()


func _run_until(condition: Callable, max_frames: int = MAX_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await _step()
	return condition.call()


## A client joins and waits for its registration. null if it does not get one.
func _join(player_name: String, realm: int = VARDHEIM) -> RawClient:
	var client: RawClient = _connect_client(realm, player_name)
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null)
	if not assert_true(joined, "%s enters the world" % player_name):
		return null
	return client


func _state() -> FortressState:
	return _server.get_fortresses().get_fortress_state(FORTRESS)


func _gate() -> FortGate:
	return _server.get_fortresses().get_gate(FORTRESS)


func _combatant(net_id: int) -> Combatant:
	return _server.get_combat().get_combatant(net_id)


func _brain() -> CombatFixture.ScriptBrain:
	return CombatFixture.ScriptBrain.new(1)


# --- The fort on the client ---------------------------------------------------------------------

func test_a_joining_client_gets_the_fortress_spawn_with_its_whole_state() -> void:
	await _start_server()
	var ana: RawClient = await _join("Ana")
	if ana == null:
		return
	var gate_id: int = _server.get_fortresses().get_net_id(FORTRESS)
	var found: Array[NetMessages.EntitySpawn] = []
	for spawn: NetMessages.EntitySpawn in ana.spawns:
		if spawn.net_id == gate_id:
			found.append(spawn)
	if not assert_eq(found.size(), 1, "a fortress SPAWN"):
		return
	assert_eq(found[0].kind, NetProtocol.EntityKind.STRUCTURE)
	assert_eq(found[0].definition_id, String(FORTRESS))
	assert_eq(found[0].fields.size(), FortressFields.all_ids().size(), "with all the fields")
	var mirror: FortressState = FortressState.initial(FortressFixture.make_definition(), 0)
	found[0].to_object_state().apply_to_fortress(mirror)
	assert_eq(mirror.gate_health, 900)
	assert_eq(mirror.owner, 0)
	assert_eq(ana.malformed, 0)
	# The snapshots carry no structure records.
	await _run_frames(10)
	for snapshot: NetMessages.Snapshot in ana.snapshots:
		for record: EntityRecord in snapshot.records:
			assert_true(record.net_id != gate_id, "the fortress does not go in the snapshots")


func test_a_full_capture_reaches_every_client_as_object_state_and_war_events_in_order() -> void:
	await _start_server()
	_server.spawn_captain_double(FORTRESS)
	var ana: RawClient = await _join("Ana", VARDHEIM)
	var bo: RawClient = await _join("Bob", SOLMARCH)
	if ana == null or bo == null:
		return
	_server.teleport(ana.own_spawn.net_id, FortressFixture.circle_center())
	await _run_frames(30)
	assert_true(ana.war_ids().is_empty(), "with the captain alive, nothing")
	_server.console_command("fort_kill_captain")
	var both_notified := func() -> bool: return ana.war_ids().size() >= 3 and bo.war_ids().size() >= 3
	var captured: bool = await _run_until(both_notified)
	assert_true(captured, "both clients receive the three notices (%s and %s)" % [ana.war_ids(), bo.war_ids()])
	assert_eq(ana.war_ids(), [WarEvents.CAPTAIN_DOWN, WarEvents.CAPTURE_STARTED, WarEvents.FORT_CAPTURED] as Array[int],
			"in the order they happen")
	assert_eq(bo.war_ids(), ana.war_ids(), "to the whole zone, the same notice")
	var gate_id: int = _server.get_fortresses().get_net_id(FORTRESS)
	var realms: Array[int] = []
	for event: NetMessages.EntityEvent in ana.events_of(NetMessages.EntityEvent.Kind.WAR):
		assert_eq(event.net_id, gate_id)
		realms.append(event.war_realm)
	assert_eq(realms, [0, VARDHEIM, VARDHEIM] as Array[int], "the captain was killed by the debug order (realm 0)")
	# The client rebuilds the state with the OBJECT_STATEs (plus the SPAWN).
	await _run_frames(20)
	var mirror: FortressState = FortressState.initial(FortressFixture.make_definition(), 0)
	for spawn: NetMessages.EntitySpawn in bo.spawns:
		if spawn.net_id == gate_id:
			spawn.to_object_state().apply_to_fortress(mirror)
	for object_state: NetMessages.ObjectState in bo.object_states:
		assert_eq(object_state.net_id, gate_id)
		object_state.apply_to_fortress(mirror)
	assert_eq(mirror.owner, VARDHEIM, "the client sees the owner change")
	assert_eq(mirror.phase, _state().phase)
	assert_eq(mirror.presence[VARDHEIM], _state().presence[VARDHEIM])
	assert_eq(mirror.capture_progress_at_start, _state().capture_progress_at_start)
	# Rate: at most one every 6 ticks, except those that change the gate's collision.
	var previous: NetMessages.ObjectState = null
	for object_state: NetMessages.ObjectState in bo.object_states:
		if previous != null and object_state.tick - previous.tick < FortressController.OBJECT_STATE_INTERVAL_TICKS:
			assert_true(object_state.has_field(FortressFields.OWNER) or object_state.has_field(FortressFields.GATE_HEALTH),
					"two OBJECT_STATEs less than 6 ticks apart only if the gate's collision changes")
		previous = object_state
	assert_eq(bo.malformed, 0)


func test_a_kill_goes_to_the_whole_zone_even_to_a_client_that_does_not_see_the_bots() -> void:
	await _start_server(null, func(config: ServerConfig) -> void: config.max_players = 8)
	_server.interest_policy = HidingPolicy.new()
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var killer: int = _server.add_fake_player(_brain(), VARDHEIM)
	var victim: int = _server.add_fake_player(_brain(), SOLMARCH)
	await _run_frames(10)
	var combat: CombatDirector = _server.get_combat()
	var tick: int = _server.get_tick() + 1
	combat.event_emitted.emit(NetMessages.EntityEvent.death(victim, tick, killer, 1),
			PackedInt32Array([victim, killer]))
	combat.event_emitted.emit(NetMessages.EntityEvent.kill(victim, tick, killer, 1, PackedInt32Array()),
			PackedInt32Array([victim, killer]))
	await _run_frames(20)
	assert_eq(ana.events_of(NetMessages.EntityEvent.Kind.KILL).size(), 1,
			"the KILL reaches whoever sees neither of the two")
	assert_eq(ana.events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 0,
			"the DEATH, which is not zone-wide, does not")
	assert_eq(ana.events_of(NetMessages.EntityEvent.Kind.KILL)[0].killer, killer)


func test_a_gate_hit_reaches_the_attackers_client_with_the_fortress_net_id() -> void:
	await _start_server()
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var net_id: int = ana.own_spawn.net_id
	_server.teleport(net_id, Vector3(77.5, 0.05, 0.0))
	_server.get_registry().get_entity(net_id).get_character().yaw = -PI * 0.5
	var combatant: Combatant = _combatant(net_id)
	var target: StructureTarget = _server.get_fortresses().get_structure_targets()[0]
	_server.get_fortresses().on_structure_hit(target, combatant, 31, _server.get_tick() + 1)
	await _run_frames(10)
	assert_eq(ana.war_ids(), [WarEvents.UNDER_ATTACK] as Array[int], "the notice reaches the zone")
	assert_eq(_state().gate_health, 900 - 31)


# --- Scoreboard --------------------------------------------------------------------------------

func test_the_scoreboard_arrives_every_two_seconds_in_pages_of_66_rows() -> void:
	await _start_server(null, func(config: ServerConfig) -> void: config.max_players = 100)
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	for _i: int in 70:
		_server.add_fake_player(_brain(), SOLMARCH)
	var combat: CombatDirector = _server.get_combat()
	var victim: int = _server.get_fortresses().get_net_id(FORTRESS) + 2
	combat.event_emitted.emit(NetMessages.EntityEvent.kill(victim, 5, ana.own_spawn.net_id, 1,
			PackedInt32Array()), PackedInt32Array())
	var arrived: bool = await _run_until(func() -> bool: return ana.scoreboards.size() >= 2, 400)
	assert_true(arrived, "a scoreboard arrives, split into two pages")
	var pages: Dictionary = {}
	for board: NetMessages.Scoreboard in ana.scoreboards:
		assert_eq(board.page_count, 2)
		pages[board.page_index] = board
	assert_true(pages.has(0) and pages.has(1))
	assert_eq((pages[0] as NetMessages.Scoreboard).rows.size(), 66, "one full page")
	assert_eq((pages[1] as NetMessages.Scoreboard).rows.size(), 71 - 66, "and the rest in the other")
	var own_row: NetMessages.ScoreRow = null
	for board: NetMessages.Scoreboard in pages.values():
		for row: NetMessages.ScoreRow in board.rows:
			if row.net_id == ana.own_spawn.net_id:
				own_row = row
	if assert_not_null(own_row, "my row is there"):
		assert_eq(own_row.kills, 1)
		assert_eq(own_row.merits, 10)
	var more: int = ana.scoreboards.size()
	var again: bool = await _run_until(func() -> bool: return ana.scoreboards.size() >= more + 2, 400)
	assert_true(again, "and it repeats every 2 s")
	assert_eq(ana.malformed, 0)


# --- Leaving and disconnecting in combat (GUE-41) -----------------------------------------------

func test_leaving_in_combat_leaves_a_neutral_attackable_body_for_the_linger_time() -> void:
	await _start_server()
	_server.linger_ticks = 120
	var ana: RawClient = await _join("Ana", VARDHEIM)
	var bo: RawClient = await _join("Bob", SOLMARCH)
	if ana == null or bo == null:
		return
	var net_id: int = ana.own_spawn.net_id
	_server.teleport(net_id, FortressFixture.circle_center())
	_combatant(net_id).mark_combat(_server.get_tick() + 1)
	await _run_frames(5)
	ana.send_raw(NetProtocol.CH_RELIABLE, NetMessages.ClientLeave.new().encode())
	var gone: bool = await _run_until(func() -> bool: return ana.disconnected)
	assert_true(gone, "the client leaves")
	await _run_frames(10)
	assert_true(_server.is_lingering(net_id), "its body stays in the world")
	assert_not_null(_server.get_registry().get_entity(net_id))
	assert_eq(_server.get_lingering_count(), 1)
	assert_false(bo.despawns.any(func(d: NetMessages.EntityDespawn) -> bool: return d.net_id == net_id),
			"the others do not receive the DESPAWN yet")
	# Still and with no buttons: truly neutral inputs.
	var body: PlayerCharacter = _server.get_registry().get_entity(net_id).get_character()
	var position: Vector3 = body.global_position
	await _run_frames(20)
	assert_vec_near(body.global_position, position, 0.05, "still")
	assert_eq(body.combat.action, CombatState.Action.NONE, "no action or block")
	# Attackable: the combatant is still alive and can take damage.
	assert_true(_combatant(net_id).is_alive())
	# Its name stays reserved.
	var again: RawClient = _connect_client(VARDHEIM, "Ana")
	var rejected: bool = await _run_until(func() -> bool: return again.reject != null)
	assert_true(rejected, "the name is reserved")
	assert_eq(again.reject.result, NetProtocol.Result.NAME)
	# It does not count in the circle: with the fort open, being inside does not capture.
	_state().on_captain_died(_server.get_tick() + 1, SOLMARCH)
	await _run_frames(30)
	assert_eq(_state().presence[VARDHEIM], 0, "the body left behind does not count")
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	# After the deadline, it disappears and everyone receives its DESPAWN.
	var removed: bool = await _run_until(func() -> bool: return not _server.is_lingering(net_id))
	assert_true(removed, "the body is removed after %d ticks" % _server.linger_ticks)
	assert_null(_server.get_registry().get_entity(net_id))
	var despawned: bool = await _run_until(func() -> bool:
		return bo.despawns.any(func(d: NetMessages.EntityDespawn) -> bool: return d.net_id == net_id))
	assert_true(despawned, "DESPAWN for whoever saw it")
	var free_again: RawClient = _connect_client(VARDHEIM, "Ana")
	var entered: bool = await _run_until(func() -> bool: return free_again.own_spawn != null)
	assert_true(entered, "and the name becomes free")


func test_leaving_out_of_combat_is_immediate() -> void:
	await _start_server()
	var ana: RawClient = await _join("Ana", VARDHEIM)
	var bo: RawClient = await _join("Bob", SOLMARCH)
	if ana == null or bo == null:
		return
	var net_id: int = ana.own_spawn.net_id
	await _run_frames(5)
	ana.send_raw(NetProtocol.CH_RELIABLE, NetMessages.ClientLeave.new().encode())
	var despawned: bool = await _run_until(func() -> bool:
		return bo.despawns.any(func(d: NetMessages.EntityDespawn) -> bool: return d.net_id == net_id))
	assert_true(despawned, "out of combat, the removal is immediate")
	assert_false(_server.is_lingering(net_id))
	assert_eq(_server.get_lingering_count(), 0)


func test_a_dropped_connection_in_combat_also_leaves_the_body() -> void:
	await _start_server()
	_server.linger_ticks = 60
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var net_id: int = ana.own_spawn.net_id
	_combatant(net_id).mark_combat(_server.get_tick() + 1)
	await _run_frames(3)
	ana.transport.close()
	var lingering: bool = await _run_until(func() -> bool: return _server.is_lingering(net_id), 300)
	assert_true(lingering, "a disconnect in combat also leaves the body")
	var removed: bool = await _run_until(func() -> bool: return not _server.is_lingering(net_id), 300)
	assert_true(removed)


func test_killing_the_lingering_body_credits_the_killer_like_any_other_death() -> void:
	await _start_server()
	_server.linger_ticks = 600
	var ana: RawClient = await _join("Ana", VARDHEIM)
	var bo: RawClient = await _join("Bob", SOLMARCH)
	if ana == null or bo == null:
		return
	var net_id: int = ana.own_spawn.net_id
	_server.teleport(net_id, Vector3(-20.0, 0.05, 8.0))
	_combatant(net_id).mark_combat(_server.get_tick() + 1)
	_combatant(net_id).health = 40
	await _run_frames(3)
	ana.send_raw(NetProtocol.CH_RELIABLE, NetMessages.ClientLeave.new().encode())
	await _run_until(func() -> bool: return _server.is_lingering(net_id))
	# An enemy hits the body: a light attack of 90 knocks it down (docs/abilities.md, section 4.5: it is a player from
	# another realm) and finishes it off by holding E.
	var killer: int = _server.add_fake_player(_brain(), SOLMARCH)
	_server.teleport(killer, Vector3(-20.0, 0.05, 6.5))
	_server.get_registry().get_entity(killer).get_character().yaw = PI
	var attack_tick: int = _server.get_tick() + 3
	var brain: CombatFixture.ScriptBrain = _server._fakes[killer] as CombatFixture.ScriptBrain
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI
		if tick >= attack_tick and tick < attack_tick + 2:
			input.buttons = PlayerInput.PRIMARY
		elif tick >= attack_tick + 60 and tick < attack_tick + 150:
			input.buttons = PlayerInput.INTERACT
		return input
	var is_dead := func() -> bool: return _combatant(net_id) == null or _combatant(net_id).is_dead()
	var dead: bool = await _run_until(is_dead, 400)
	assert_true(dead, "the body dies like any other")
	var kills: Array[NetMessages.EntityEvent] = bo.events_of(NetMessages.EntityEvent.Kind.KILL)
	if assert_eq(kills.size(), 1, "with its KILL"):
		assert_eq(kills[0].killer, killer, "credited to whoever killed it")
		assert_eq(kills[0].net_id, net_id)
	assert_eq(_server.get_scores().get_entry(killer).kills, 1, "and the kill counts on the scoreboard")
	var removed: bool = await _run_until(func() -> bool: return not _server.is_lingering(net_id), 100)
	assert_true(removed, "dead, the body is removed right away")


# --- /atascado (MUN-41) --------------------------------------------------------------------------

func _unstuck_request() -> PackedByteArray:
	return NetMessages.UnstuckRequest.new().encode()


func test_unstuck_teleports_to_the_nearest_valid_point_after_the_channel_and_logs_it() -> void:
	await _start_server()
	_server.get_unstuck().channel_ticks = 60
	_server.get_unstuck().cooldown_ticks = 300
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var net_id: int = ana.own_spawn.net_id
	var entity: NetEntity = _server.get_registry().get_entity(net_id)
	_server.teleport(net_id, Vector3(150.0, 0.05, 90.0))
	var counter: int = entity.teleport_counter
	await _run_frames(5)
	ana.send_raw(NetProtocol.CH_RELIABLE, _unstuck_request())
	var started: bool = await _run_until(func() -> bool: return _server.get_unstuck().is_channeling("ana"), 60)
	assert_true(started, "the channeling starts")
	var notified: bool = await _run_until(func() -> bool: return ana.has_notice_containing("/atascado"), 60)
	assert_true(notified, "and it is notified")
	assert_vec_near(entity.get_position(), Vector3(150.0, 0.05, 90.0), 0.5, "it has not moved yet")
	var moved: bool = await _run_until(func() -> bool: return _server.get_unstuck().completed_count == 1, 200)
	assert_true(moved, "completes the channeling")
	await _run_frames(3)
	assert_vec_near(entity.get_position(), FortressFixture.VARDHEIM_CAMP, 1.5,
			"to the nearest point of its realm (the camp: the fort is neutral)")
	assert_true(entity.teleport_counter != counter, "with a teleport jump for the clients")
	# It is logged: zone, origin and destination.
	var path: String = ProjectSettings.globalize_path("res://build/test_fortress_net_report.json")
	assert_eq(_server.write_report(path), OK)
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var unstuck: Dictionary = (report["war"] as Dictionary)["unstuck"]
	assert_eq(int(unstuck["uses"]), 1)
	var entry: Dictionary = (unstuck["log"] as Array)[0]
	assert_eq(entry["zone"], "test_world")
	assert_eq(entry["name"], "Ana")
	assert_eq((entry["from"] as Array)[0], 150.0)
	# Second immediate use: on cooldown.
	var notices_before: int = ana.notices.size()
	ana.send_raw(NetProtocol.CH_RELIABLE, _unstuck_request())
	await _run_until(func() -> bool: return ana.notices.size() > notices_before, 60)
	assert_true(ana.has_notice_containing("disponible de nuevo"), "5 min cooldown")
	assert_false(_server.get_unstuck().is_channeling("ana"))


func test_unstuck_is_refused_in_combat_and_interrupted_by_damage() -> void:
	await _start_server()
	_server.get_unstuck().channel_ticks = 90
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var net_id: int = ana.own_spawn.net_id
	_server.teleport(net_id, Vector3(150.0, 0.05, 90.0))
	var combatant: Combatant = _combatant(net_id)
	combatant.mark_combat(_server.get_tick() + 1)
	await _run_frames(3)
	ana.send_raw(NetProtocol.CH_RELIABLE, _unstuck_request())
	var refused: bool = await _run_until(func() -> bool: return ana.has_notice_containing("en combate"), 60)
	assert_true(refused, "in combat it cannot be used")
	assert_false(_server.get_unstuck().is_channeling("ana"))
	# Out of combat it starts; damage interrupts it and does not spend the cooldown.
	combatant.in_combat_until = 0
	await _run_frames(3)
	ana.send_raw(NetProtocol.CH_RELIABLE, _unstuck_request())
	var started: bool = await _run_until(func() -> bool: return _server.get_unstuck().is_channeling("ana"), 60)
	assert_true(started)
	await _run_frames(20)
	combatant.take_damage(10, _server.get_tick() + 1)
	combatant.mark_combat(_server.get_tick() + 1)
	var interrupted: bool = await _run_until(func() -> bool: return ana.has_notice_containing("interrumpido"), 60)
	assert_true(interrupted, "damage interrupts the channeling")
	assert_false(_server.get_unstuck().is_channeling("ana"))
	assert_eq(_server.get_unstuck().interrupted_count, 1)
	assert_eq(_server.get_unstuck().completed_count, 0)
	assert_vec_near(_server.get_registry().get_entity(net_id).get_position(), Vector3(150.0, 0.05, 90.0), 0.5,
			"it does not move")
	assert_eq(_server.get_unstuck().cooldown_remaining("ana", _server.get_tick()), 0, "and does not spend the cooldown")


func test_unstuck_goes_to_the_fortress_of_the_realm_when_it_is_the_nearest_valid_point() -> void:
	await _start_server()
	_server.get_unstuck().channel_ticks = 30
	_server.console_command("fort_owner vardheim")
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var net_id: int = ana.own_spawn.net_id
	_server.teleport(net_id, FortressFixture.ORIGIN + Vector3(30.0, 0.05, 0.0))
	await _run_frames(5)
	ana.send_raw(NetProtocol.CH_RELIABLE, _unstuck_request())
	var moved: bool = await _run_until(func() -> bool: return _server.get_unstuck().completed_count == 1, 200)
	assert_true(moved)
	await _run_frames(3)
	assert_vec_near(_server.get_registry().get_entity(net_id).get_position(),
			FortressFixture.ORIGIN + FortressFixture.INNER_POINTS_LOCAL[1], 1.5,
			"one's own, quiet fort is the nearest valid point")


func test_unstuck_does_not_need_debug_commands_and_a_malformed_request_is_a_strike() -> void:
	await _start_server()
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	ana.send_raw(NetProtocol.CH_RELIABLE, _unstuck_request())
	await _run_frames(5)
	assert_eq(peer.strikes_total, 0, "it works without --debug-commands")
	ana.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([NetProtocol.MSG_UNSTUCK_REQUEST, 1]))
	await _run_frames(5)
	assert_eq(peer.strikes_total, 1, "a malformed one adds a notice")


# --- A real hit on the gate, seen by another client ---------------------------------------------

func _brain_with(script: Callable) -> CombatFixture.ScriptBrain:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = script
	return brain


func test_a_real_swing_at_the_gate_reaches_a_watching_client_as_hit_and_object_state() -> void:
	await _start_server(null, func(config: ServerConfig) -> void: config.max_players = 8)
	var ana: RawClient = await _join("Ana", SOLMARCH)
	if ana == null:
		return
	_server.teleport(ana.own_spawn.net_id, Vector3(70.0, 0.05, 6.0))
	var press_tick: int = _server.get_tick() + 15
	var attacker: int = _server.add_fake_player(_brain_with(func(tick: int, _position: Vector3,
			_yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = -PI * 0.5
		if tick >= press_tick and tick < press_tick + 2:
			input.buttons = PlayerInput.PRIMARY
		return input), VARDHEIM)
	_server.teleport(attacker, Vector3(77.5, 0.05, 0.0))
	_server.get_registry().get_entity(attacker).get_character().yaw = -PI * 0.5
	var gate_id: int = _server.get_fortresses().get_net_id(FORTRESS)
	var seen: bool = await _run_until(func() -> bool:
		return not ana.events_of(NetMessages.EntityEvent.Kind.HIT).is_empty(), 300)
	if not assert_true(seen, "the HIT of the hit on the gate reaches whoever sees the attacker"):
		return
	var hit: NetMessages.EntityEvent = ana.events_of(NetMessages.EntityEvent.Kind.HIT)[0]
	assert_eq(hit.net_id, gate_id, "with the fortress net_id")
	assert_eq(hit.attacker, attacker)
	assert_true(hit.amount > 0 and hit.amount < 90, "the slashing light attack, reduced by the multiplier")
	var health_told: bool = await _run_until(func() -> bool:
		return ana.object_states.any(func(o: NetMessages.ObjectState) -> bool:
			return o.has_field(FortressFields.GATE_HEALTH)), 120)
	assert_true(health_told, "and the gate's new health arrives as an OBJECT_STATE")
	var mirror: FortressState = FortressState.initial(FortressFixture.make_definition(), 0)
	for object_state: NetMessages.ObjectState in ana.object_states:
		object_state.apply_to_fortress(mirror)
	assert_eq(mirror.gate_health, 900 - hit.amount, "the health the client sees is that of the hit")
	assert_eq(ana.war_ids(), [WarEvents.UNDER_ATTACK] as Array[int])
	assert_eq(ana.malformed, 0)


# --- Fort debug commands over the network (ids 8 to 11) ----------------------------------------

func _send_command(client: RawClient, command: NetMessages.DebugCommand) -> void:
	client.send_raw(NetProtocol.CH_RELIABLE, command.encode())


func test_the_fortress_debug_commands_act_over_the_network_with_debug_commands() -> void:
	await _start_server(null, func(config: ServerConfig) -> void: config.debug_commands = true)
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	_server.teleport(ana.own_spawn.net_id, FortressFixture.circle_center())
	# 11 fort_capture_speed: the 2 s capture lasts a few ticks.
	_send_command(ana, NetMessages.DebugCommand.fort_capture_speed(30))
	var sped_up: bool = await _run_until(func() -> bool: return _state().capture_rate_multiplier == 30)
	assert_true(sped_up, "fort_capture_speed 30")
	# 10 fort_kill_captain: the Hollow' captain falls at the hands of the realm of whoever orders it and,
	# with Ana in the circle, the fort is captured.
	_send_command(ana, NetMessages.DebugCommand.simple(NetProtocol.DEBUG_FORT_KILL_CAPTAIN))
	var captured: bool = await _run_until(func() -> bool: return _state().owner == VARDHEIM)
	assert_true(captured, "fort_kill_captain opens the circle and Vardheim captures")
	# 9 fort_owner: the fort passes to Solmarch, with its garrison and the gate intact.
	_send_command(ana, NetMessages.DebugCommand.fort_owner(SOLMARCH))
	var given: bool = await _run_until(func() -> bool: return _state().owner == SOLMARCH)
	assert_true(given, "fort_owner solmarch")
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)
	assert_true(_state().captain_alive)
	# 8 fort_reset: back to neutral.
	_send_command(ana, NetMessages.DebugCommand.simple(NetProtocol.DEBUG_FORT_RESET))
	var reset: bool = await _run_until(func() -> bool: return _state().owner == 0)
	assert_true(reset, "fort_reset")
	await _run_frames(15)
	assert_eq(peer.strikes_total, 0, "none counts as a notice")
	assert_true(_server.get_commands().audit_total >= 4, "all four are audited")
	assert_eq(ana.war_ids(), [WarEvents.CAPTAIN_DOWN, WarEvents.CAPTURE_STARTED,
			WarEvents.FORT_CAPTURED, WarEvents.FORT_CAPTURED, WarEvents.FORT_RESET] as Array[int],
			"and the zone receives the notices in the order they happen")
	assert_eq(ana.war_realms_of(WarEvents.CAPTAIN_DOWN), [VARDHEIM] as Array[int],
			"the captain was killed by the realm of whoever sent the command")


func test_the_fortress_debug_commands_are_refused_without_debug_commands() -> void:
	await _start_server()
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	_send_command(ana, NetMessages.DebugCommand.fort_owner(SOLMARCH))
	_send_command(ana, NetMessages.DebugCommand.simple(NetProtocol.DEBUG_FORT_KILL_CAPTAIN))
	await _run_frames(20)
	assert_eq(_state().owner, 0, "the fort does not change hands")
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "nor is the captain killed")
	assert_eq(peer.strikes_total, 2, "each attempt is a notice")


# --- Periodic reset to neutral (docs/fortress.md, 1.5) -----------------------------------------------

func test_the_periodic_reset_reaches_every_client_and_closes_the_gate_for_everybody() -> void:
	await _start_server(FortressFixture.make_definition(2.0, 2.0, 4.0))
	var ana: RawClient = await _join("Ana", VARDHEIM)
	var bo: RawClient = await _join("Bob", SOLMARCH)
	if ana == null or bo == null:
		return
	var gate_id: int = _server.get_fortresses().get_net_id(FORTRESS)
	# The reset clock starts with the new owner; Ana waits in the circle.
	_server.teleport(ana.own_spawn.net_id, FortressFixture.circle_center())
	_server.console_command("fort_owner solmarch")
	var owned: bool = await _run_until(func() -> bool: return _state().owner == SOLMARCH)
	assert_true(owned)
	# The console order enters before the tick; the gate layers change at the end of that tick.
	await _run_frames(3)
	var given_at: int = _state().last_reset_tick
	assert_eq(_gate().collision_layer, FortGate.layers_for(SOLMARCH, false),
			"the gate holds back Solmarch's enemies")
	var position: Vector3 = _server.get_registry().get_entity(ana.own_spawn.net_id).get_position()
	var reset: bool = await _run_until(func() -> bool: return _state().owner == 0, 400)
	if not assert_true(reset, "at 4 s the fort becomes neutral again"):
		return
	assert_eq(_state().last_reset_tick - given_at, 4 * 60, "exactly 4 s after the last reset")
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)
	assert_true(_state().captain_alive, "with the Hollow and their Captain")
	assert_eq(_state().gate_health, 900)
	assert_eq(_gate().collision_layer, FortGate.layers_for(0, false), "now it holds back all three realms")
	assert_vec_near(_server.get_registry().get_entity(ana.own_spawn.net_id).get_position(), position, 0.2,
			"the players inside are not moved")
	# Both clients find out: a \"fuerte reiniciado\" (fort reset) notice and the new owner in an OBJECT_STATE.
	var told: bool = await _run_until(func() -> bool:
		return ana.war_ids().has(WarEvents.FORT_RESET) and bo.war_ids().has(WarEvents.FORT_RESET), 120)
	assert_true(told, "FORT_RESET to the whole zone")
	assert_eq(ana.war_realms_of(WarEvents.FORT_RESET), [0] as Array[int], "no realm")
	for client: RawClient in [ana, bo]:
		var mirror: FortressState = FortressState.initial(FortressFixture.make_definition(), 0)
		for spawn: NetMessages.EntitySpawn in client.spawns:
			if spawn.net_id == gate_id:
				spawn.to_object_state().apply_to_fortress(mirror)
		for object_state: NetMessages.ObjectState in client.object_states:
			object_state.apply_to_fortress(mirror)
		assert_eq(mirror.owner, 0, "the client sees the fort as neutral")
		assert_eq(mirror.phase, FortressState.Phase.GARRISONED)
		assert_eq(client.malformed, 0)
	# And it repeats again every 4 s since the last reset.
	var again: bool = await _run_until(func() -> bool:
		return ana.war_ids().count(WarEvents.FORT_RESET) >= 2, 400)
	assert_true(again, "the reset repeats")
