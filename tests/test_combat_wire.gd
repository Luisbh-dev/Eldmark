extends TestCase
## Server combat over the network, with clients that speak the protocol by hand over ENet on
## 127.0.0.1 (docs/combate.md, sections 5 and 6; docs/networking.md, 5.5 and 5.6): who each
## ENTITY_EVENT is sent to (HIT, DOWNED, DEATH, KILL and RESPAWN), the extra snapshot block with health, the NPC in
## the snapshots, RESPAWN_REQUEST (on time, past the deadline and with an index that is no longer valid) and the
## debug commands (with and without [code]--debug-commands[/code]).
## [br][br]
## Since phase 4 (docs/abilities.md, sections 4.5 and 4.6) each player receives their LOADOUT on entering (and
## the public one of those who enter later and are relevant to them), so the tests wait for events by
## their class; and in an RVR zone (\"test_world\") the killing blow from another realm knocks down: the DEATH and the KILL
## arrive with the finishing blow.
## [br][br]
## The clients are [RawClient]: no prediction or interpolation, they send the inputs each test says
## (with buttons) on the server ticks.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const FIRST_PORT: int = 25100
const MAX_FRAMES: int = 400

var _viewport: SubViewport
var _world: Node3D
var _server: ZoneServer
var _server_transport: NetTransport
var _port: int = 0
var _clients: Array[RawClient] = []
var _hooks: Array[Callable] = []
var _client_tick: int = 0
var _next_client_index: int = 0


## A client that speaks the protocol by hand and stores what it receives from the server, with the events.
class RawClient:
	extends RefCounted

	var transport: NetTransport
	var hello: PackedByteArray
	var welcome: NetMessages.Welcome = null
	var own_spawn: NetMessages.EntitySpawn = null
	var spawns: Array[NetMessages.EntitySpawn] = []
	var snapshots: Array[NetMessages.Snapshot] = []
	var events: Array[NetMessages.EntityEvent] = []
	var notices: Array[NetMessages.Notice] = []
	var connected: bool = false
	var disconnected: bool = false

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
		if NetMessages.peek_auth_result(bytes) == NetProtocol.Result.OK:
			welcome = NetMessages.Welcome.decode(bytes)
			transport.complete_auth(peer_id)

	func _on_packet(_peer_id: int, bytes: PackedByteArray) -> void:
		match NetMessages.peek_type(bytes):
			NetProtocol.MSG_ENTITY_SPAWN:
				var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
				if spawn != null:
					spawns.append(spawn)
					if spawn.is_yours:
						own_spawn = spawn
			NetProtocol.MSG_SNAPSHOT:
				var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
				if snapshot != null:
					snapshots.append(snapshot)
			NetProtocol.MSG_ENTITY_EVENT:
				var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
				if event != null:
					events.append(event)
			NetProtocol.MSG_NOTICE:
				var notice: NetMessages.Notice = NetMessages.Notice.decode(bytes)
				if notice != null:
					notices.append(notice)

	func send_raw(channel: int, bytes: PackedByteArray) -> Error:
		return transport.send(1, channel, bytes)

	## INPUT_BATCH with the inputs of ticks [param first_tick] to [param last_tick]; the buttons
	## of each tick are given by [param buttons_of] ([code](tick: int) -> int[/code]).
	func send_inputs(first_tick: int, last_tick: int, look_yaw: float, buttons_of: Callable) -> void:
		var batch := NetMessages.InputBatch.new()
		if not snapshots.is_empty():
			batch.ack_snapshot_tick = last_snapshot().server_tick
		batch.interp_delay_q = 32
		batch.newest_tick = last_tick
		for tick: int in range(first_tick, last_tick + 1):
			var input := PlayerInput.new()
			input.tick = tick
			input.look_yaw = look_yaw
			input.buttons = buttons_of.call(tick) if buttons_of.is_valid() else 0
			batch.inputs.append(input.quantized())
			batch.view_offsets_q.append(0)
		transport.send(1, NetProtocol.CH_INPUT, batch.encode())

	func last_snapshot() -> NetMessages.Snapshot:
		return snapshots[snapshots.size() - 1] if not snapshots.is_empty() else null

	func events_of(kind: int) -> Array[NetMessages.EntityEvent]:
		var found: Array[NetMessages.EntityEvent] = []
		for event: NetMessages.EntityEvent in events:
			if event.event == kind:
				found.append(event)
		return found


## Interest policy that hides some players from others: observer's net_id -> net_id
## it does not see.
class HidingPolicy:
	extends InterestPolicy

	var hidden: Dictionary = {}

	func is_relevant(observer: NetEntity, entity: NetEntity, _was_relevant: bool) -> bool:
		var hidden_ids: Array = hidden.get(observer.net_id, [])
		return not hidden_ids.has(entity.net_id)


func after_each() -> void:
	_hooks.clear()
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

func _start_server(configure: Callable = Callable()) -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
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
	_port = _find_free_port()
	config.port = _port
	if configure.is_valid():
		configure.call(config)
	assert_eq(_server.start(config, _world, _server_transport, DevAuthProvider.new()), OK,
			"the server opens port %d" % _port)


func _hello(realm: int, player_name: String) -> PackedByteArray:
	var hello := NetMessages.Hello.new()
	hello.protocol_version = NetProtocol.PROTOCOL_VERSION
	hello.sim_hash = _server.get_sim_hash()
	hello.realm = realm
	hello.display_name = player_name
	return hello.encode()


func _find_free_port() -> int:
	var start: int = FIRST_PORT + OS.get_process_id() % 40
	for port: int in range(start, start + 200):
		var probe := PacketPeerUDP.new()
		var error: Error = probe.bind(port, "*")
		probe.close()
		if error == OK:
			return port
	return -1


## One physics step of the clients: poll, hooks and flush.
func _step() -> void:
	await tree.physics_frame
	_client_tick += 1
	for client: RawClient in _clients:
		client.transport.poll(_client_tick)
	for hook: Callable in _hooks:
		hook.call(_client_tick)
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


## A client joins and waits for its registration.
func _join(player_name: String, realm: int) -> RawClient:
	var transport := NetTransport.new()
	transport.name = "ClientTransport%d" % _next_client_index
	_next_client_index += 1
	_viewport.add_child(transport)
	var client := RawClient.new(transport, _hello(realm, player_name))
	_clients.append(client)
	assert_eq(transport.connect_to("127.0.0.1", _port, 2000), OK, "%s connects" % player_name)
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null)
	if not assert_true(joined, "%s enters the world" % player_name):
		return null
	return client


func _entity_of(client: RawClient) -> NetEntity:
	return _server.get_registry().get_entity(client.own_spawn.net_id)


func _combatant_of(client: RawClient) -> Combatant:
	return _server.get_combat().get_combatant(client.own_spawn.net_id)


## Makes [param client] send, on each step, the inputs of the next server ticks with
## [param look_yaw] and those buttons ([param buttons_of] receives the server tick).
func _drive(client: RawClient, look_yaw: float, buttons_of: Callable = Callable()) -> void:
	_hooks.append(func(_tick: int) -> void:
		var next: int = _server.get_tick() + 1
		client.send_inputs(next, next + 3, look_yaw, buttons_of))


## Places [param client] at [param position] facing [param yaw] (on the server).
func _place(client: RawClient, position: Vector3, yaw: float) -> void:
	_server.teleport(client.own_spawn.net_id, position)
	_entity_of(client).get_character().yaw = yaw


# --- What does not travel ----------------------------------------------------------------------

## R4: whoever enters the zone receives an ENTITY_SPAWN for each entity that was already there, and that of the others does not
## carry their stamina, exhaustion, parry cooldown or controls; the own one does carry everything.
func test_the_spawn_of_other_players_does_not_leak_their_private_combat_state() -> void:
	await _start_server()
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var combat: CombatState = _entity_of(ana).get_character().combat
	combat.stamina = 137
	combat.stamina_regen_tick = _server.get_tick() + 100000
	combat.combat_flags = CombatState.FLAG_EXHAUSTED
	combat.parry_ready_tick = _server.get_tick() + 5000
	var bea: RawClient = await _join("Bea", SOLMARCH)
	if bea == null:
		return
	var seen: NetMessages.EntitySpawn = null
	for spawn: NetMessages.EntitySpawn in bea.spawns:
		if spawn.net_id == ana.own_spawn.net_id:
			seen = spawn
	if not assert_not_null(seen, "Bea receives Ana's SPAWN"):
		return
	assert_false(seen.is_yours, "foreign")
	var neutral: CombatState = CombatState.initial(CombatCatalog.rules(), combat.weapon_id)
	assert_eq(seen.state.combat.stamina, neutral.stamina, "without the exact stamina")
	assert_eq(seen.state.combat.combat_flags, 0, "nor the exhaustion")
	assert_eq(seen.state.combat.parry_ready_tick, 0, "nor the parry cooldown")
	assert_eq(seen.state.combat.stamina_regen_tick, 0)
	assert_eq(seen.state.combat.weapon_id, combat.weapon_id, "the weapon does")
	assert_true(ana.own_spawn.is_yours, "the own SPAWN is still marked as yours")


# --- Events -----------------------------------------------------------------------------------

func test_a_hit_reaches_attacker_victim_and_a_third_player_with_the_same_content() -> void:
	await _start_server()
	var attacker: RawClient = await _join("Ana", VARDHEIM)
	var victim: RawClient = await _join("Bea", SOLMARCH)
	var third: RawClient = await _join("Cleo", VARDHEIM)
	if attacker == null or victim == null or third == null:
		return
	_place(attacker, Vector3(0.0, 0.05, 0.0), 0.0)
	_place(victim, Vector3(0.0, 0.05, -1.5), PI)
	_place(third, Vector3(8.0, 0.05, 8.0), 0.0)
	var press: int = _server.get_tick() + 10
	_drive(attacker, 0.0, func(tick: int) -> int:
		return PlayerInput.PRIMARY if tick >= press and tick < press + 2 else 0)
	_drive(victim, PI)
	_drive(third, 0.0)
	var hit_kind: int = NetMessages.EntityEvent.Kind.HIT
	var delivered: bool = await _run_until(func() -> bool:
		return not attacker.events_of(hit_kind).is_empty() and not victim.events_of(hit_kind).is_empty() \
				and not third.events_of(hit_kind).is_empty())
	if not assert_true(delivered, "all three receive the event"):
		return
	var first: NetMessages.EntityEvent = attacker.events_of(NetMessages.EntityEvent.Kind.HIT)[0]
	for client: RawClient in [victim, third]:
		var copy: NetMessages.EntityEvent = client.events_of(NetMessages.EntityEvent.Kind.HIT)[0]
		assert_eq(copy.encode(), first.encode(), "the same HIT, byte for byte")
	assert_eq(first.attacker, attacker.own_spawn.net_id)
	assert_eq(first.net_id, victim.own_spawn.net_id)
	assert_eq(first.amount, 90)
	# The victim's health drops in its extra block and in the ledger that the others see.
	await _run_frames(6)
	var own: NetMessages.Snapshot = victim.last_snapshot()
	assert_eq(own.health, 910, "the victim's own extra block")
	assert_eq(own.max_health, 1000)
	assert_true(own.is_in_combat(), "in combat")
	var seen_by_third: EntityRecord = null
	for record: EntityRecord in third.last_snapshot().records:
		if record.net_id == victim.own_spawn.net_id:
			seen_by_third = record
	if assert_not_null(seen_by_third, "the third party sees the victim"):
		assert_eq(seen_by_third.health_q, EntityRecord.quantize_health(910, 1000),
				"and its quantized health in the ledger")
	assert_eq(attacker.last_snapshot().health, 1000, "the attacker loses no health")


func test_events_only_go_to_players_who_own_or_see_the_entities() -> void:
	await _start_server()
	var policy := HidingPolicy.new()
	_server.interest_policy = policy
	var attacker: RawClient = await _join("Ana", VARDHEIM)
	var victim: RawClient = await _join("Bea", SOLMARCH)
	var blind: RawClient = await _join("Cleo", VARDHEIM)
	if attacker == null or victim == null or blind == null:
		return
	# Cleo sees neither Ana nor Bea.
	policy.hidden[blind.own_spawn.net_id] = [attacker.own_spawn.net_id, victim.own_spawn.net_id]
	_place(attacker, Vector3(0.0, 0.05, 0.0), 0.0)
	_place(victim, Vector3(0.0, 0.05, -1.5), PI)
	var press: int = _server.get_tick() + 30
	_drive(attacker, 0.0, func(tick: int) -> int:
		return PlayerInput.PRIMARY if tick >= press and tick < press + 2 else 0)
	_drive(victim, PI)
	_drive(blind, 0.0)
	var hit_kind: int = NetMessages.EntityEvent.Kind.HIT
	assert_true(await _run_until(func() -> bool: return not victim.events_of(hit_kind).is_empty()),
			"the victim receives the hit")
	await _run_frames(20)
	assert_false(attacker.events_of(hit_kind).is_empty(), "the attacker too")
	# Only its own LOADOUT from joining: nothing of Ana or Bea.
	var foreign: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in blind.events:
		if event.net_id != blind.own_spawn.net_id:
			foreign.append(event)
	assert_eq(foreign.size(), 0, "whoever sees neither of the two receives nothing")


## In RVR Ana's killing blow knocks Bea down (HIT with bit 6 and DOWNED to all three) and Ana finishes her
## by holding E: the DEATH and the KILL name the killer, the finishing blow source and Cleo, who assisted.
func test_kill_and_death_events_name_the_killer_and_the_assistants() -> void:
	await _start_server()
	var attacker: RawClient = await _join("Ana", VARDHEIM)
	var victim: RawClient = await _join("Bea", SOLMARCH)
	var helper: RawClient = await _join("Cleo", VARDHEIM)
	if attacker == null or victim == null or helper == null:
		return
	_place(attacker, Vector3(0.0, 0.05, 0.0), 0.0)
	_place(victim, Vector3(0.0, 0.05, -1.5), PI)
	_place(helper, Vector3(8.0, 0.05, 8.0), 0.0)
	# Cleo had already done half the damage; Bea has 60 left.
	var combatant: Combatant = _combatant_of(victim)
	combatant.health = 60
	combatant.mark_combat(_server.get_tick())
	combatant.ledger.record(_server.get_tick(), helper.own_spawn.net_id, 500)
	var press: int = _server.get_tick() + 10
	# After the light attack ends, Ana holds E to finish (60 ticks).
	var hold_from: int = press + 90
	_drive(attacker, 0.0, func(tick: int) -> int:
		if tick >= press and tick < press + 2:
			return PlayerInput.PRIMARY
		return PlayerInput.INTERACT if tick >= hold_from else 0)
	_drive(victim, PI)
	_drive(helper, 0.0)
	var delivered: bool = await _run_until(func() -> bool:
		return not helper.events_of(NetMessages.EntityEvent.Kind.KILL).is_empty() \
				and not attacker.events_of(NetMessages.EntityEvent.Kind.KILL).is_empty() \
				and not victim.events_of(NetMessages.EntityEvent.Kind.DEATH).is_empty())
	if not assert_true(delivered, "killer, victim and assister receive their event"):
		return
	var kill: NetMessages.EntityEvent = attacker.events_of(NetMessages.EntityEvent.Kind.KILL)[0]
	assert_eq(kill.killer, attacker.own_spawn.net_id)
	assert_eq(kill.net_id, victim.own_spawn.net_id)
	assert_eq(kill.assistants, PackedInt32Array([helper.own_spawn.net_id]), "Cleo assisted")
	assert_eq(kill.get_source(), CombatSource.EXECUTE, "with the finishing blow source")
	var death: NetMessages.EntityEvent = victim.events_of(NetMessages.EntityEvent.Kind.DEATH)[0]
	assert_eq(death.killer, attacker.own_spawn.net_id)
	assert_eq(death.get_source(), CombatSource.EXECUTE)
	var hit: NetMessages.EntityEvent = victim.events_of(NetMessages.EntityEvent.Kind.HIT)[0]
	assert_eq(hit.get_source(), CombatSource.make(CombatSource.Kind.ATTACK,
			CombatCatalog.attack_id(&"sword_light_1")), "the hit is the light attack")
	assert_true(hit.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_DOWNED), "the hit knocks down")
	assert_false(hit.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_LETHAL), "it does not kill")
	assert_eq(hit.amount, 60, "what was left")
	for client: RawClient in [attacker, victim, helper]:
		var downed: Array[NetMessages.EntityEvent] = client.events_of(NetMessages.EntityEvent.Kind.DOWNED)
		if assert_eq(downed.size(), 1, "DOWNED to the whole zone"):
			assert_eq(downed[0].net_id, victim.own_spawn.net_id)
	await _run_frames(10)
	assert_eq(victim.events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1, "a single DEATH")
	assert_eq(attacker.events_of(NetMessages.EntityEvent.Kind.KILL).size(), 1, "a single KILL")
	# And the victim's own snapshot reports her as dead with her respawn tick.
	var own: NetMessages.Snapshot = victim.last_snapshot()
	assert_true(own.is_dead(), "dead")
	assert_eq(own.health, 0)
	assert_eq(own.respawn_tick, combatant.respawn_tick)


# --- Requested respawn ------------------------------------------------------------------------

func test_respawn_request_flow_and_its_warnings() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana", SOLMARCH)
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	_drive(client, 0.0)
	var timing: CombatTiming = _server.get_combat_timing()
	timing.respawn = 60
	timing.auto_respawn = 600
	# Alive: requesting a respawn is past the deadline.
	client.send_raw(NetProtocol.CH_RELIABLE, _respawn_request(0))
	await _run_frames(10)
	assert_eq(peer.strikes_total, 1, "alive: a notice")
	# Dead, but long before it can: another notice.
	_server.get_combat().kill(_combatant_of(client), _server.get_tick() + 1)
	await _run_frames(5)
	client.send_raw(NetProtocol.CH_RELIABLE, _respawn_request(0))
	await _run_frames(5)
	assert_eq(peer.strikes_total, 2, "too early: a notice")
	assert_true(_combatant_of(client).is_dead(), "still dead")
	# At its time, with an index that is no longer valid: it is not a notice and it respawns at the first point.
	var respawn_tick: int = client.last_snapshot().respawn_tick
	assert_eq(respawn_tick, _combatant_of(client).respawn_tick, "the snapshot gives the respawn tick")
	assert_true(await _run_until(func() -> bool: return _server.get_tick() >= respawn_tick - 6),
			"the time arrives")
	client.send_raw(NetProtocol.CH_RELIABLE, _respawn_request(200))
	var back: bool = await _run_until(func() -> bool: return _combatant_of(client).is_alive())
	if not assert_true(back, "respawns"):
		return
	assert_eq(peer.strikes_total, 2, "an index that is no longer valid adds no notices")
	assert_vec_near(_entity_of(client).get_position(), ZoneFixture.SOLMARCH_SPAWN, 0.1,
			"at the first point of its realm")
	await _run_frames(8)
	var own: NetMessages.Snapshot = client.last_snapshot()
	assert_false(own.is_dead())
	assert_true(own.is_protected(), "with respawn protection")
	assert_eq(own.health, 1000)
	assert_eq(own.own_teleport, 1, "with teleport")
	var respawns: Array[NetMessages.EntityEvent] = client.events_of(NetMessages.EntityEvent.Kind.RESPAWN)
	if assert_eq(respawns.size(), 1, "receives its RESPAWN"):
		# Since phase 4 the index is that of the zone's static list (Vardheim0, Vardheim1,
		# Solmarch0), not that of the realm's list.
		assert_eq(respawns[0].point, 2, "the index of Solmarch's first point in the zone list")
		assert_eq(respawns[0].net_id, client.own_spawn.net_id)
	# Already alive, another request is one more notice.
	client.send_raw(NetProtocol.CH_RELIABLE, _respawn_request(0))
	await _run_frames(8)
	assert_eq(peer.strikes_total, 3)
	# A malformed message too.
	client.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([NetProtocol.MSG_RESPAWN_REQUEST]))
	await _run_frames(8)
	assert_eq(peer.strikes_total, 4)


func _respawn_request(point_index: int) -> PackedByteArray:
	var request := NetMessages.RespawnRequest.new()
	request.point_index = point_index
	return request.encode()


# --- Debug commands ---------------------------------------------------------------------------

func _command(id: int, payload: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var command := NetMessages.DebugCommand.new()
	command.command = id
	command.payload = payload
	return command.encode()


func test_debug_commands_without_the_flag_are_warnings() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana", VARDHEIM)
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	_combatant_of(client).take_damage(400, 1)
	_combatant_of(client).mark_combat(_server.get_tick())
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_HEAL))
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_KILL))
	await _run_frames(10)
	assert_eq(peer.strikes_total, 2, "without --debug-commands, each one is a notice")
	assert_eq(_combatant_of(client).health, 600, "and they do nothing")
	assert_eq(_server.get_commands().audit_total, 0, "nor are they audited")


func test_debug_commands_with_the_flag_act_on_the_sender_and_are_audited() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	var client: RawClient = await _join("Ana", VARDHEIM)
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	var combatant: Combatant = _combatant_of(client)
	_drive(client, 0.0)
	# heal
	combatant.take_damage(400, 1)
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_HEAL))
	assert_true(await _run_until(func() -> bool: return combatant.health == 1000), "heal heals")
	# stamina_inf: with no data it toggles and with a byte it sets the value.
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_STAMINA_INF))
	assert_true(await _run_until(func() -> bool:
		return (_entity_of(client).get_character().combat.combat_flags
				& CombatState.FLAG_INFINITE_STAMINA) != 0), "stamina_inf turns on infinite stamina")
	client.send_raw(NetProtocol.CH_RELIABLE,
			_command(NetProtocol.DEBUG_STAMINA_INF, PackedByteArray([0])))
	assert_true(await _run_until(func() -> bool:
		return (_entity_of(client).get_character().combat.combat_flags
				& CombatState.FLAG_INFINITE_STAMINA) == 0), "and with 0 it turns it off")
	# set_weapon with the catalog id.
	var weapon_payload := PackedByteArray([0, 0])
	weapon_payload.encode_u16(0, CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_SET_WEAPON, weapon_payload))
	# spawn_dummy in front of the player, blocking.
	client.send_raw(NetProtocol.CH_RELIABLE,
			_command(NetProtocol.DEBUG_SPAWN_DUMMY, PackedByteArray([NpcBrain.Mode.BLOCK])))
	assert_true(await _run_until(func() -> bool: return _server.get_dummy_count() == 1), "the dummy appears")
	var dummy_spawns: Array[NetMessages.EntitySpawn] = []
	assert_true(await _run_until(func() -> bool:
		for spawn: NetMessages.EntitySpawn in client.spawns:
			if spawn.kind == NetProtocol.EntityKind.NPC and not dummy_spawns.has(spawn):
				dummy_spawns.append(spawn)
		return not dummy_spawns.is_empty()), "the player receives the NPC's SPAWN")
	if dummy_spawns.is_empty():
		return
	var dummy_spawn: NetMessages.EntitySpawn = dummy_spawns[0]
	assert_eq(dummy_spawn.display_name, ZoneServer.DUMMY_NAME)
	assert_eq(dummy_spawn.realm, RealmCatalog.NEUTRAL_CODE)
	# The NPC travels in its own section of the snapshot.
	assert_true(await _run_until(func() -> bool:
		for record: EntityRecord in client.last_snapshot().records:
			if record.net_id == dummy_spawn.net_id:
				return record.kind == NetProtocol.EntityKind.NPC
		return false), "and in the snapshot, as an NPC")
	# kill: the last one; after dying not even heal works.
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_KILL))
	assert_true(await _run_until(func() -> bool: return combatant.is_dead()), "kill kills")
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_HEAL))
	await _run_frames(10)
	assert_true(combatant.is_dead(), "a dead player is not healed by heal")
	assert_eq(peer.strikes_total, 0, "none of these uses is a notice")
	# Each use is audited with who and what.
	var audit: PackedStringArray = _server.get_commands().audit
	assert_true(audit.size() >= 6, "six audited uses (%d)" % audit.size())
	assert_true(audit[0].contains("Ana") and audit[0].contains("heal"), audit[0])
	assert_true(audit[audit.size() - 1].contains("rechazado"), "the last heal was rejected")


func test_bad_debug_commands_are_warnings() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	var client: RawClient = await _join("Ana", VARDHEIM)
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	client.send_raw(NetProtocol.CH_RELIABLE, _command(99))
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_SET_WEAPON, PackedByteArray([1])))
	var unknown_weapon := PackedByteArray([0, 0])
	unknown_weapon.encode_u16(0, 999)
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_SET_WEAPON, unknown_weapon))
	client.send_raw(NetProtocol.CH_RELIABLE,
			_command(NetProtocol.DEBUG_STAMINA_INF, PackedByteArray([1, 2, 3])))
	client.send_raw(NetProtocol.CH_RELIABLE,
			_command(NetProtocol.DEBUG_SPAWN_DUMMY, PackedByteArray([9])))
	await _run_frames(15)
	assert_eq(peer.strikes_total, 5, "unknown id, malformed weapon, nonexistent weapon, extra data and invalid mode")
	assert_eq(_server.get_dummy_count(), 0)
