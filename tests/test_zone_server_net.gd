extends TestCase
## Tests for [ZoneServer] with real clients over ENet on 127.0.0.1, in a single process.
## [br][br]
## The server and each client have their own [NetTransport] (with its [SceneMultiplayer]); the clients
## are [RawClient]: they speak the protocol by hand (HELLO, WELCOME, CLIENT_READY, INPUT_BATCH...)
## with no prediction or interpolation, which belong to the real client. The tests check the handshake
## and rejections, sign-up with the "after S" state, snapshots, inputs, interest, removals, security
## (warnings, kicks, unexpected types, debug commands), the network simulator and shutdown with a
## warning. The runner fails on any engine error, so each test also checks that nothing is sent before
## [signal NetTransport.peer_connected].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const FIRST_PORT: int = 24900
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
var _raw_peers: Array[ENetMultiplayerPeer] = []
var _raw_attackers: Array[RawEnetAttacker] = []


## A client that speaks the protocol by hand: it sends its HELLO on connecting, completes
## authentication with the WELCOME, sends CLIENT_READY on connecting (if [member auto_ready]) and stores
## everything it receives from the server.
class RawClient:
	extends RefCounted

	var transport: NetTransport
	var hello: PackedByteArray
	var tick: int = 0
	var auto_ready: bool = true
	## Ticks by which it delays the snapshot ack it declares in each batch (faking lag).
	var ack_lag_ticks: int = 0
	## Interpolation delay (×8) it declares in each batch.
	var interp_delay_q: int = 32
	var welcome: NetMessages.Welcome = null
	var reject: NetMessages.Reject = null
	var connected: bool = false
	var disconnected: bool = false
	var failed: bool = false
	var ready_sent: bool = false
	var own_spawn: NetMessages.EntitySpawn = null
	var spawns: Array[NetMessages.EntitySpawn] = []
	var despawns: Array[NetMessages.EntityDespawn] = []
	var snapshots: Array[NetMessages.Snapshot] = []
	var notices: Array[NetMessages.Notice] = []

	func _init(p_transport: NetTransport, p_hello: PackedByteArray) -> void:
		transport = p_transport
		hello = p_hello
		transport.peer_authenticating.connect(_on_authenticating)
		transport.auth_received.connect(_on_auth_received)
		transport.peer_connected.connect(_on_connected)
		transport.peer_disconnected.connect(_on_disconnected)
		transport.packet_received.connect(_on_packet)
		transport.connection_failed.connect(_on_failed)

	func _on_authenticating(peer_id: int) -> void:
		transport.send_auth(peer_id, hello)

	func _on_auth_received(peer_id: int, bytes: PackedByteArray) -> void:
		var result: int = NetMessages.peek_auth_result(bytes)
		if result == NetProtocol.Result.OK:
			welcome = NetMessages.Welcome.decode(bytes)
			transport.complete_auth(peer_id)
		elif result > 0:
			reject = NetMessages.Reject.decode(bytes)

	func _on_connected(_peer_id: int) -> void:
		connected = true
		if auto_ready:
			send_ready()

	func _on_disconnected(_peer_id: int) -> void:
		disconnected = true

	func _on_failed() -> void:
		failed = true

	func _on_packet(_peer_id: int, bytes: PackedByteArray) -> void:
		match NetMessages.peek_type(bytes):
			NetProtocol.MSG_ENTITY_SPAWN:
				var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
				if spawn != null:
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

	func send_ready() -> void:
		ready_sent = true
		transport.send(1, NetProtocol.CH_RELIABLE, NetMessages.ClientReady.new().encode())

	func send_raw(channel: int, bytes: PackedByteArray) -> Error:
		return transport.send(1, channel, bytes)

	## INPUT_BATCH with [param count] inputs ending at [param newest_tick], all with the same movement
	## and the same view.
	func send_inputs(newest_tick: int, count: int, move: Vector2, look_yaw: float) -> void:
		var batch := NetMessages.InputBatch.new()
		if not snapshots.is_empty():
			batch.ack_snapshot_tick = maxi(last_snapshot().server_tick - ack_lag_ticks, 1)
		batch.interp_delay_q = interp_delay_q
		batch.newest_tick = newest_tick
		for i: int in count:
			var input := PlayerInput.new()
			input.tick = newest_tick - count + 1 + i
			input.move = move
			input.look_yaw = look_yaw
			batch.inputs.append(input.quantized())
			batch.view_offsets_q.append(0)
		transport.send(1, NetProtocol.CH_INPUT, batch.encode())

	func last_snapshot() -> NetMessages.Snapshot:
		return snapshots[snapshots.size() - 1] if not snapshots.is_empty() else null

	func spawns_of(net_id: int) -> Array[NetMessages.EntitySpawn]:
		var found: Array[NetMessages.EntitySpawn] = []
		for spawn: NetMessages.EntitySpawn in spawns:
			if spawn.net_id == net_id:
				found.append(spawn)
		return found

	func notice_with_code(code: int) -> NetMessages.Notice:
		for notice: NetMessages.Notice in notices:
			if notice.code == code:
				return notice
		return null

	## net_id of the records in the last snapshot, sorted.
	func visible_ids() -> Array[int]:
		var ids: Array[int] = []
		if not snapshots.is_empty():
			for record: EntityRecord in last_snapshot().records:
				ids.append(record.net_id)
		ids.sort()
		return ids


## Interest policy that can hide the fake players (those named "Bot...").
class HidingPolicy:
	extends InterestPolicy

	var hide_bots: bool = false

	func is_relevant(_observer: NetEntity, entity: NetEntity, _was_relevant: bool) -> bool:
		return not (hide_bots and entity.display_name.begins_with("Bot"))


func after_each() -> void:
	_hooks.clear()
	for raw: ENetMultiplayerPeer in _raw_peers:
		raw.close()
	_raw_peers.clear()
	for attacker: RawEnetAttacker in _raw_attackers:
		attacker.close()
	_raw_attackers.clear()
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

## Test zone and server listening on a free port. [param configure] receives the
## [ServerConfig] before startup.
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


func _hello(realm: int = VARDHEIM, player_name: String = "Ana",
		protocol_version: int = NetProtocol.PROTOCOL_VERSION, sim_hash: int = -1) -> PackedByteArray:
	var hello := NetMessages.Hello.new()
	hello.protocol_version = protocol_version
	hello.sim_hash = sim_hash if sim_hash >= 0 else _client_sim_hash()
	hello.realm = realm
	hello.display_name = player_name
	return hello.encode()


## Fingerprint of the simulation computed by the client on its own instance of the character.
func _client_sim_hash(run_speed: float = 5.0) -> int:
	var character: PlayerCharacter = PLAYER_SCENE.instantiate() as PlayerCharacter
	character.run_speed = run_speed
	_world.add_child(character)
	var hash_value: int = NetProtocol.compute_sim_hash(character)
	_world.remove_child(character)
	character.free()
	return hash_value


func _connect_client(hello: PackedByteArray, auto_ready: bool = true,
		net_sim_spec: String = "") -> RawClient:
	var transport := NetTransport.new()
	transport.name = "ClientTransport%d" % _next_client_index
	_next_client_index += 1
	_viewport.add_child(transport)
	transport.set_net_sim_spec(net_sim_spec)
	var client := RawClient.new(transport, hello)
	client.auto_ready = auto_ready
	_clients.append(client)
	assert_eq(transport.connect_to("127.0.0.1", _port, 2000), OK, "the client connects")
	return client


## One physics step of the clients: poll, hooks (what each test sends) and flush. The server does its
## own in its own _physics_process.
func _step() -> void:
	await tree.physics_frame
	_client_tick += 1
	for client: RawClient in _clients:
		client.tick = _client_tick
		client.transport.poll(_client_tick)
	for hook: Callable in _hooks:
		hook.call(_client_tick)
	for client: RawClient in _clients:
		client.transport.flush()


func _run_frames(count: int) -> void:
	for _i: int in count:
		await _step()


## Advances until [param condition] is true. false if it does not happen within [param max_frames].
func _run_until(condition: Callable, max_frames: int = MAX_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await _step()
	return condition.call()


func _find_free_port() -> int:
	var start: int = FIRST_PORT + OS.get_process_id() % 40
	for port: int in range(start, start + 200):
		var probe := PacketPeerUDP.new()
		var error: Error = probe.bind(port, "*")
		probe.close()
		if error == OK:
			return port
	return -1


## A client joins and waits to be signed up. null if it is not.
func _join(player_name: String, realm: int = VARDHEIM) -> RawClient:
	var client: RawClient = _connect_client(_hello(realm, player_name))
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null)
	if not assert_true(joined, "%s enters the world" % player_name):
		return null
	return client


func _read_report() -> Dictionary:
	var path: String = ProjectSettings.globalize_path("res://build/test_zone_server_net_report.json")
	assert_eq(_server.write_report(path), OK, "the report is written")
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		fail("could not read the report")
		return {}
	return json.data


# --- Tests ------------------------------------------------------------------------------------

func test_sim_hash_depends_on_the_character_settings() -> void:
	await _start_server()
	assert_eq(_server.get_sim_hash(), _client_sim_hash(),
			"the server and a client instance compute the same fingerprint")
	assert_true(_server.get_sim_hash() != _client_sim_hash(6.5),
			"a different run speed changes the fingerprint")


func test_handshake_spawns_the_player_and_streams_snapshots() -> void:
	await _start_server()
	var joined: Array[Vector2i] = []
	_server.player_joined.connect(func(peer_id: int, net_id: int) -> void:
		joined.append(Vector2i(peer_id, net_id)))
	var client: RawClient = _connect_client(_hello(VARDHEIM, "Ana"))
	var spawned: bool = await _run_until(func() -> bool: return client.own_spawn != null)
	if not assert_true(spawned, "the player's own ENTITY_SPAWN arrives"):
		return

	var welcome: NetMessages.Welcome = client.welcome
	if assert_not_null(welcome, "the WELCOME arrived"):
		assert_eq(welcome.zone_id, "test_world", "zone")
		assert_eq(welcome.tick_rate, 60, "60 ticks per second")
		assert_eq(welcome.snapshot_interval, NetProtocol.SNAPSHOT_INTERVAL_TICKS)
		assert_eq(welcome.max_input_batch, NetProtocol.MAX_INPUTS_PER_BATCH)
		assert_eq(welcome.max_rewind_ticks, NetProtocol.MAX_REWIND_TICKS)
		assert_eq(welcome.realm, VARDHEIM, "realm accepted")
		assert_eq(welcome.channel, 0, "channel 0")
	var peer_ids: PackedInt32Array = _server.get_peer_ids()
	assert_eq(peer_ids.size(), 1, "one peer")
	var peer: ServerPeer = _server.get_peer(peer_ids[0])
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "the peer is in the world")
	assert_eq(peer.display_name, "Ana")
	assert_eq(peer.realm, VARDHEIM)
	assert_eq(joined, [Vector2i(peer.peer_id, peer.entity.net_id)], "player_joined")
	assert_eq(_server.get_player_count(), 1)

	var own: NetMessages.EntitySpawn = client.own_spawn
	assert_true(own.is_yours, "the \"yours\" bit")
	assert_eq(own.net_id, peer.entity.net_id, "net_id")
	assert_eq(own.kind, NetProtocol.EntityKind.PLAYER)
	assert_eq(own.realm, VARDHEIM)
	assert_eq(own.display_name, "Ana")
	assert_eq(own.spawn_tick, peer.entity.spawn_tick, "spawn_tick = sign-up tick S")
	assert_eq(own.state.last_input_tick, own.spawn_tick, "the state is \"after S\"")
	assert_vec_near(own.state.position, ZoneFixture.VARDHEIM_SPAWNS[0], 1e-4,
			"at Vardheim's first spawn point")
	assert_true(own.state.grounded, "on the ground")
	assert_vec_near(own.state.velocity, Vector3.ZERO, 1e-6, "velocity 0")
	assert_true(own.state.equals_exact(PlayerState.decode(own.state.encode())),
			"the imposed state goes through encode/decode")
	var history: StateHistory = _server.get_history()
	assert_true(history.has_tick(own.net_id, own.spawn_tick), "the history records the sign-up tick")
	var at_spawn: StateHistory.Sample = history.sample(own.net_id, float(own.spawn_tick))
	if assert_not_null(at_spawn, "and it can be sampled"):
		assert_vec_near(at_spawn.position, own.state.position, 1e-4, "with the sign-up position")

	# Snapshots: with no real inputs, the server substitutes the neutral sign-up input.
	await _run_frames(40)
	assert_true(client.snapshots.size() >= 10, "snapshots arrive (%d)" % client.snapshots.size())
	var previous_tick: int = 0
	for snapshot: NetMessages.Snapshot in client.snapshots:
		assert_true(snapshot.server_tick > previous_tick, "the snapshots advance")
		previous_tick = snapshot.server_tick
		if assert_not_null(snapshot.own_state, "it carries the player's own state"):
			assert_eq(snapshot.own_state.last_input_tick, snapshot.server_tick,
					"the player's own state is the \"after simulating that tick\" one")
			assert_vec_near(snapshot.own_state.position, own.state.position, 0.01,
					"still idle at the spawn point")
		assert_eq(snapshot.input_ack_tick, snapshot.server_tick, "ack = last consumed tick")
		assert_true(snapshot.records.is_empty(), "only they are there")
		assert_eq(snapshot.server_tick % NetProtocol.SNAPSHOT_INTERVAL_TICKS,
				own.net_id % NetProtocol.SNAPSHOT_INTERVAL_TICKS,
				"snapshots go out on the ticks matching their net_id parity")
	var last: NetMessages.Snapshot = client.last_snapshot()
	assert_true(last.substitutions > 0, "substituted inputs are counted")
	assert_eq(last.input_margin, NetProtocol.NO_MARGIN, "with no inputs there is no margin")
	assert_eq(last.own_teleport, 0)


func test_rejected_connections_get_a_reject_with_the_reason() -> void:
	await _start_server()
	var cases: Array[Dictionary] = [
		{"hello": _hello(VARDHEIM, "Ana", NetProtocol.PROTOCOL_VERSION + 1),
				"result": NetProtocol.Result.VERSION},
		{"hello": _hello(VARDHEIM, "Ana", NetProtocol.PROTOCOL_VERSION, 12345),
				"result": NetProtocol.Result.SIM_HASH},
		{"hello": _hello(NetProtocol.Realm.NONE, "Ana"), "result": NetProtocol.Result.REALM},
		{"hello": _hello(VARDHEIM, "ab"), "result": NetProtocol.Result.NAME},
		{"hello": PackedByteArray([1, 2, 3]), "result": NetProtocol.Result.MALFORMED},
	]
	for case: Dictionary in cases:
		var client: RawClient = _connect_client(case["hello"])
		var rejected: bool = await _run_until(func() -> bool: return client.reject != null)
		if not assert_true(rejected, "a REJECT arrives (%s)" % NetProtocol.result_text(case["result"])):
			continue
		assert_eq(client.reject.result, case["result"], "rejection reason")
		assert_eq(client.reject.text, NetProtocol.result_text(case["result"]), "Spanish text")
		assert_null(client.welcome, "there is no WELCOME")
		assert_false(client.ready_sent, "nothing else is sent")
	await _run_frames(90)
	assert_eq(_server.get_peer_ids().size(), 0, "the rejected peers are gone")
	assert_eq(_server.get_player_count(), 0, "and do not take up a slot")
	var report: Dictionary = _read_report()
	var rejects: Dictionary = report.get("rejects", {})
	assert_eq(rejects.size(), 5, "the report counts each rejection reason")


func test_full_server_rejects_with_full() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.max_players = 2)
	_server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), SOLMARCH)
	var first: RawClient = await _join("Ana")
	if first == null:
		return
	var second: RawClient = _connect_client(_hello(VARDHEIM, "Bruno"))
	var rejected: bool = await _run_until(func() -> bool: return second.reject != null)
	assert_true(rejected, "the second one receives a REJECT")
	assert_eq(second.reject.result, NetProtocol.Result.FULL, "server full (the fake one counts)")
	assert_eq(_server.get_player_count(), 2, "two remain")


func test_max_realm_diff_rejects_the_realm_that_would_lead_by_too_much() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.max_realm_diff = 1)
	var first: RawClient = await _join("Ana", VARDHEIM)
	if first == null:
		return
	# 2 against 0 is a 2-player lead with the limit at 1: Vardheim's second person is rejected.
	var second: RawClient = _connect_client(_hello(VARDHEIM, "Bruno"))
	var rejected: bool = await _run_until(func() -> bool: return second.reject != null)
	if not assert_true(rejected, "a REJECT arrives"):
		return
	assert_eq(second.reject.result, NetProtocol.Result.IMBALANCE, "REJECT 9 IMBALANCE")
	assert_eq(second.reject.text, NetProtocol.result_text(NetProtocol.Result.IMBALANCE), "with its own text")
	assert_true(second.reject.text.contains("demasiados jugadores"), "which states the reason")
	assert_null(second.welcome, "no WELCOME")
	# The same name in another realm does get in: the rejection leaves no trace (no cooldown either).
	var third: RawClient = await _join("Bruno", SOLMARCH)
	if third == null:
		return
	# With Askarra empty (the test zone admits all three realms) Vardheim is still 2 against 0.
	var fourth: RawClient = _connect_client(_hello(VARDHEIM, "Carlos"))
	assert_true(await _run_until(func() -> bool: return fourth.reject != null))
	assert_eq(fourth.reject.result, NetProtocol.Result.IMBALANCE, "Askarra is still empty")
	var fifth: RawClient = await _join("Diego", NetProtocol.Realm.ASKARRA)
	if fifth == null:
		return
	# 1 against 1 against 1: anyone can now join, and tying at two leaves no extra lead.
	var sixth: RawClient = await _join("Elena", VARDHEIM)
	assert_not_null(sixth, "with all three realms at 1, Vardheim admits another one")
	var report: Dictionary = _read_report()
	var rejects: Dictionary = report.get("rejects", {})
	assert_eq(int(rejects.get(NetProtocol.result_text(NetProtocol.Result.IMBALANCE), 0)), 2,
			"the report counts the two imbalance rejections")


func test_fake_players_do_not_count_to_reject_a_person() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.max_realm_diff = 1)
	for i: int in 5:
		_server.add_fake_player(BotBrain.new(1 + i, BotBrain.Pattern.IDLE), VARDHEIM)
	assert_eq(_server.get_realm_counts(), PackedInt32Array([0, 0, 0]), "the fakes are not people")
	var person: RawClient = await _join("Ana", VARDHEIM)
	assert_not_null(person, "Vardheim's first person gets in even with five fakes around")
	_server.add_fake_player(BotBrain.new(9, BotBrain.Pattern.IDLE), SOLMARCH)
	assert_eq(_server.get_realm_counts(), PackedInt32Array([1, 0, 0]), "only the person counts")


func test_without_a_limit_any_realm_takes_everyone() -> void:
	await _start_server()
	for name_text: String in ["Ana", "Bruno", "Carlos", "Diego"]:
		assert_not_null(await _join(name_text, VARDHEIM), "%s enters" % name_text)
	assert_eq(_server.get_realm_counts(), PackedInt32Array([4, 0, 0]))


func test_the_welcome_carries_the_real_count_per_realm() -> void:
	await _start_server()
	var first: RawClient = await _join("Ana", VARDHEIM)
	if first == null:
		return
	assert_eq(first.welcome.realm_counts, PackedInt32Array([0, 0, 0]), "the first one does not count itself")
	var second: RawClient = await _join("Bruno", SOLMARCH)
	if second == null:
		return
	assert_eq(second.welcome.realm_counts, PackedInt32Array([1, 0, 0]), "the second sees the first")
	var third: RawClient = await _join("Carlos", VARDHEIM)
	if third == null:
		return
	assert_eq(third.welcome.realm_counts, PackedInt32Array([1, 1, 0]), "and the third sees both")
	assert_eq(third.welcome.get_realm_count(VARDHEIM), 1)
	assert_eq(_server.get_realm_counts(), PackedInt32Array([2, 1, 0]), "the server counts the three people")
	assert_eq(_server.get_realm_counts(true), PackedInt32Array([2, 1, 0]), "all are inside now")
	# A fake does not enter the count, and whoever leaves stops counting.
	_server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), SOLMARCH)
	var leave := NetMessages.ClientLeave.new()
	first.send_raw(NetProtocol.CH_RELIABLE, leave.encode())
	var gone: bool = await _run_until(func() -> bool: return _server.get_realm_counts() == PackedInt32Array([1, 1, 0]))
	assert_true(gone, "when Ana leaves, Vardheim drops to 1")
	var fourth: RawClient = await _join("Diego", NetProtocol.Realm.ASKARRA)
	if fourth != null:
		assert_eq(fourth.welcome.realm_counts, PackedInt32Array([1, 1, 0]))


func test_a_person_who_is_still_loading_counts_for_the_limit_but_not_for_the_world_count() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.max_realm_diff = 1)
	var loading: RawClient = _connect_client(_hello(VARDHEIM, "Ana"), false)
	assert_true(await _run_until(func() -> bool: return loading.connected), "Ana connects and loads the zone")
	assert_eq(_server.get_realm_counts(), PackedInt32Array([1, 0, 0]), "loading already counts toward the limit")
	assert_eq(_server.get_realm_counts(true), PackedInt32Array([0, 0, 0]), "but she is not in the world yet")
	var second: RawClient = _connect_client(_hello(VARDHEIM, "Bruno"))
	assert_true(await _run_until(func() -> bool: return second.reject != null))
	assert_eq(second.reject.result, NetProtocol.Result.IMBALANCE, "two at once do not slip in by being in the loading state")


## A filler fakes guardian like [ServerMain]'s (GUE-42), with the quota [param budget] already created:
## each fake, in the realm with the lowest total. It is handed to the server, which frees it along with itself.
func _fill_with_fillers(budget: int) -> FillerKeeper:
	var keeper := FillerKeeper.new(NetZones.allowed_realms("test_world"), budget,
			_server.get_realm_counts.bind(true))
	keeper.creator = func(realm: int) -> int:
		return _server.add_fake_player(BotBrain.new(500 + realm, BotBrain.Pattern.IDLE), realm)
	keeper.remover = func(net_id: int) -> void: _server.remove_fake_player(net_id)
	_server.set_filler_keeper(keeper)
	for _i: int in budget:
		var realm: int = keeper.next_realm()
		keeper.track(int(keeper.creator.call(realm)), realm)
	return keeper


func test_a_server_full_of_fillers_lets_people_in_and_a_filler_yields_each_seat() -> void:
	# GUE-43: with --max-realm-diff the filler does not take up people's slots.
	await _start_server(func(config: ServerConfig) -> void:
		config.max_players = 4
		config.max_realm_diff = 1)
	var keeper: FillerKeeper = _fill_with_fillers(4)
	assert_eq(keeper.filler_counts(), PackedInt32Array([2, 1, 1]), "four filler fakes across the three realms")
	assert_eq(_server.get_player_count(), 4, "the server is full, but only with filler")
	var first_of_vardheim: int = -1
	for entity: NetEntity in _server.get_registry().get_sorted():
		if keeper.is_filler(entity.net_id) and entity.realm == VARDHEIM:
			first_of_vardheim = entity.net_id
			break
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	assert_null(ana.reject, "Ana does not receive \"full\"")
	# The fake that holds her slot leaves when she enters the world (its removal, at the start of the next tick).
	assert_true(await _run_until(func() -> bool: return _server.get_registry().get_entity(first_of_vardheim) == null),
			"Vardheim's oldest filler fake is gone")
	assert_eq(keeper.filler_counts(), PackedInt32Array([1, 1, 1]), "just one: one per person")
	assert_eq(_server.get_player_count(), 4, "four remain")
	var bruno: RawClient = await _join("Bruno", SOLMARCH)
	var carla: RawClient = await _join("Carla", NetProtocol.Realm.ASKARRA)
	if bruno == null or carla == null:
		return
	assert_eq(keeper.filler_counts(), PackedInt32Array([1, 0, 0]), "each person in the slot of a fake from their realm")
	var diego: RawClient = await _join("Diego", VARDHEIM)
	if diego == null:
		return
	assert_eq(keeper.filler_count(), 0, "the last filler fake gives up its slot")
	assert_eq(_server.get_realm_counts(), PackedInt32Array([2, 1, 1]), "four people")
	# No filler is left: people never exceed --max-players.
	var elena: RawClient = _connect_client(_hello(SOLMARCH, "Elena"))
	assert_true(await _run_until(func() -> bool: return elena.reject != null), "the fifth person receives a REJECT")
	assert_eq(elena.reject.result, NetProtocol.Result.FULL, "server full of people")
	await _run_frames(2)
	assert_eq(_server.get_player_count(), 4, "four players, none of them fake")
	var report: Dictionary = _read_report()
	var rejects: Dictionary = report.get("rejects", {})
	assert_eq(int(rejects.get(NetProtocol.result_text(NetProtocol.Result.FULL), 0)), 1, "a single \"full\": Elena's")


func test_fakes_that_are_not_fillers_still_take_a_seat() -> void:
	await _start_server(func(config: ServerConfig) -> void:
		config.max_players = 2
		config.max_realm_diff = 1)
	var keeper: FillerKeeper = _fill_with_fillers(1)
	var plain: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), SOLMARCH)
	assert_eq(_server.get_player_count(), 2, "one filler fake and another that is not")
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	assert_eq(keeper.filler_count(), 0, "the filler gives up its slot")
	var bruno: RawClient = _connect_client(_hello(SOLMARCH, "Bruno"))
	assert_true(await _run_until(func() -> bool: return bruno.reject != null), "Bruno receives a REJECT")
	assert_eq(bruno.reject.result, NetProtocol.Result.FULL, "the non-filler fake keeps its slot")
	assert_not_null(_server.get_registry().get_entity(plain), "and stays in the world")


func test_a_person_who_leaves_before_entering_frees_the_seat_and_no_filler_moves() -> void:
	await _start_server(func(config: ServerConfig) -> void:
		config.max_players = 2
		config.max_realm_diff = 1)
	var keeper: FillerKeeper = _fill_with_fillers(2)
	var fillers: Array[int] = _filler_ids(keeper)
	var loading: RawClient = _connect_client(_hello(VARDHEIM, "Ana"), false)
	assert_true(await _run_until(func() -> bool: return loading.connected), "Ana joins and loads the zone")
	assert_null(loading.reject, "no \"full\": the filler holds a slot for her")
	assert_eq(keeper.reserved_count(), 1, "the reserved slot")
	assert_eq(_filler_ids(keeper), fillers, "but the fake does not leave while she is loading")
	assert_eq(_server.get_player_count(), 3, "meanwhile there is one too many")
	loading.send_raw(NetProtocol.CH_RELIABLE, NetMessages.ClientLeave.new().encode())
	assert_true(await _run_until(func() -> bool: return keeper.reserved_count() == 0),
			"she leaves without entering the world and the slot is freed")
	assert_eq(_filler_ids(keeper), fillers, "the same filler fakes, with no sign-ups or removals")
	assert_eq(_server.get_player_count(), 2, "the server is full of filler again")


func test_a_hello_and_a_disconnect_in_a_loop_do_not_churn_the_fillers() -> void:
	# F6b review (GUE-43): each accepted HELLO with the server full already removed a filler fake (DESPAWN to
	# everyone; with some counts, from the opposing side) and, if the person dropped before CLIENT_READY, created another in
	# their camp (SPAWN to everyone). In a loop, without limit. Now the fake only holds its slot until the person enters.
	await _start_server(func(config: ServerConfig) -> void:
		config.max_players = 3
		config.max_realm_diff = 2)
	var keeper: FillerKeeper = _fill_with_fillers(3)
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	assert_true(await _run_until(func() -> bool: return keeper.filler_count() == 2 and _server.get_player_count() == 3),
			"Ana in the slot of Vardheim's fake")
	await _run_frames(10)
	var fillers: Array[int] = _filler_ids(keeper)
	var spawns_before: int = ana.spawns.size()
	var despawns_before: int = ana.despawns.size()
	var visitors: Array[String] = ["Bruno", "Carla", "Diego", "Elena", "Fabio"]
	for round_index: int in visitors.size():
		var visitor: RawClient = _connect_client(_hello(VARDHEIM, visitors[round_index]), false)
		assert_true(await _run_until(func() -> bool: return visitor.connected or visitor.reject != null),
				"round %d: the HELLO arrives" % round_index)
		assert_null(visitor.reject, "round %d: it is accepted (the filler holds her slot): %s" % [round_index,
				visitor.reject.text if visitor.reject != null else ""])
		visitor.send_raw(NetProtocol.CH_RELIABLE, NetMessages.ClientLeave.new().encode())
		assert_true(await _run_until(func() -> bool: return _server.get_peer_ids().size() == 1),
				"round %d: she leaves without entering" % round_index)
		await _run_frames(3)
	await _run_frames(10)
	assert_eq(_filler_ids(keeper), fillers, "the same filler fakes")
	assert_eq(ana.despawns.size(), despawns_before, "Ana receives no removals")
	assert_eq(ana.spawns.size(), spawns_before, "nor any sign-ups")


func test_a_seat_abandoned_while_another_person_loads_keeps_the_sides_even() -> void:
	# F6b review (GUE-43): Ana (Vardheim) and Sam (Solmarch) arrive with the server full of filler and load at the same time;
	# Sam leaves without entering. With the removal on HELLO arrival, Sam's fake went back to the realm with the lowest total without counting
	# Ana, who was loading (Vardheim), and when she entered there were 2 from Vardheim against 0 from Solmarch. Now: one per realm.
	await _start_server(func(config: ServerConfig) -> void:
		config.max_players = 3
		config.max_realm_diff = 1)
	_fill_with_fillers(3)
	var ana: RawClient = _connect_client(_hello(VARDHEIM, "Ana"), false)
	var sam: RawClient = _connect_client(_hello(SOLMARCH, "Sam"), false)
	assert_true(await _run_until(func() -> bool: return ana.connected and sam.connected), "both load the zone")
	sam.send_raw(NetProtocol.CH_RELIABLE, NetMessages.ClientLeave.new().encode())
	assert_true(await _run_until(func() -> bool: return _server.get_peer_ids().size() == 1), "Sam leaves without entering")
	ana.send_ready()
	assert_true(await _run_until(func() -> bool: return ana.own_spawn != null), "Ana enters the world")
	await _run_frames(5)
	var by_realm := PackedInt32Array([0, 0, 0])
	for entity: NetEntity in _server.get_registry().get_sorted():
		if entity.kind == NetProtocol.EntityKind.PLAYER and entity.realm >= 1 and entity.realm <= 3:
			by_realm[entity.realm - 1] += 1
	assert_eq(by_realm, PackedInt32Array([1, 1, 1]), "one per realm: Ana and the Solmarch and Askarra fakes")
	assert_eq(_server.get_player_count(), 3)


## The net_ids of the live filler fakes, sorted.
func _filler_ids(keeper: FillerKeeper) -> Array[int]:
	var ids: Array[int] = []
	for entity: NetEntity in _server.get_registry().get_sorted():
		if keeper.is_filler(entity.net_id):
			ids.append(entity.net_id)
	return ids


func test_duplicate_name_is_rejected_while_the_first_player_is_connected() -> void:
	await _start_server()
	var first: RawClient = await _join("Álvaro")
	if first == null:
		return
	assert_true(_server.get_connected_names().has("Álvaro"), "the server knows the name")
	# Same name with different capitalization and no accent: it is rejected with NAME.
	var second: RawClient = _connect_client(_hello(VARDHEIM, "ALVARO"))
	var rejected: bool = await _run_until(func() -> bool: return second.reject != null)
	if not assert_true(rejected, "the second one receives a REJECT"):
		return
	assert_eq(second.reject.result, NetProtocol.Result.NAME, "duplicate name")
	assert_null(second.welcome, "there is no WELCOME")
	assert_eq(_server.get_player_count(), 1, "only the first remains")
	# Another name does get in.
	var third: RawClient = await _join("Bruno", SOLMARCH)
	if third == null:
		return
	assert_eq(_server.get_connected_names().size(), 2, "Álvaro and Bruno")
	# When the first one leaves, their name is freed.
	var leave := NetMessages.ClientLeave.new()
	first.send_raw(NetProtocol.CH_RELIABLE, leave.encode())
	var gone: bool = await _run_until(func() -> bool:
		return not _server.get_connected_names().has("Álvaro"))
	assert_true(gone, "Álvaro has left")
	var again: RawClient = await _join("Alvaro")
	assert_not_null(again, "and his name can be used again")


func test_inputs_move_the_player_and_the_snapshot_feeds_back() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var spawn_tick: int = client.own_spawn.spawn_tick
	var start: Vector3 = client.own_spawn.state.position
	var first_tick: int = spawn_tick + 3
	_hooks.append(func(_tick: int) -> void:
		# Inputs one tick ahead of time: the one for tick T arrives just before T is simulated.
		var newest: int = _server.get_tick() + 2
		if newest >= first_tick:
			client.send_inputs(newest, mini(4, newest - first_tick + 1), Vector2(0.0, 1.0),
					client.own_spawn.state.yaw))
	await _run_frames(90)

	var last: NetMessages.Snapshot = client.last_snapshot()
	assert_true(last.own_state.position.z < start.z - 3.0,
			"runs forward (-Z): from z=%.2f to z=%.2f" % [start.z, last.own_state.position.z])
	assert_eq(last.own_state.last_input_tick, last.server_tick, "applied the tick's input")
	assert_true(last.input_margin >= 0 and last.input_margin <= 3,
			"lead margin %d" % last.input_margin)
	var earlier: NetMessages.Snapshot = client.snapshots[client.snapshots.size() - 6]
	assert_eq(last.substitutions, earlier.substitutions,
			"in steady state inputs are no longer substituted")
	assert_true(last.input_ack_tick >= last.server_tick and last.input_ack_tick <= last.server_tick + 3,
			"the ack runs ahead of the tick if inputs have been received (%d, %d)"
			% [last.input_ack_tick, last.server_tick])
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_true(peer.rtt_ticks >= 1 and peer.rtt_ticks <= 4,
			"the server measures the RTT in ticks (%d)" % peer.rtt_ticks)
	assert_eq(peer.interp_delay_q, 32, "it stores the declared interpolation delay")
	assert_true(peer.ack_snapshot_tick > 0, "and the last confirmed snapshot")
	var queue_stats: Dictionary = _read_report().get("inputs", {})
	assert_true(int(queue_stats.get("consumed", 0)) > 80, "the report counts the inputs")


func test_players_see_each_other_and_leave_cleanly() -> void:
	await _start_server()
	var bot_id: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), SOLMARCH)
	var left: Array[Vector2i] = []
	_server.player_left.connect(func(peer_id: int, net_id: int) -> void:
		left.append(Vector2i(peer_id, net_id)))
	var a: RawClient = await _join("Ana", VARDHEIM)
	var b: RawClient = await _join("Bruno", SOLMARCH)
	if a == null or b == null:
		return
	var a_id: int = a.own_spawn.net_id
	var b_id: int = b.own_spawn.net_id
	await _run_frames(30)

	# Each one receives the others' SPAWN (the fake, the other) and their records in the snapshots.
	assert_eq(a.spawns_of(a_id).size(), 1, "Ana receives her own SPAWN once")
	assert_eq(a.spawns_of(bot_id).size(), 1, "Ana sees the fake player")
	assert_eq(a.spawns_of(b_id).size(), 1, "and Bruno")
	assert_eq(a.spawns_of(b_id)[0].display_name, "Bruno")
	assert_false(a.spawns_of(b_id)[0].is_yours, "someone else's SPAWN is not \"yours\"")
	assert_eq(b.spawns_of(a_id).size(), 1, "Bruno sees Ana")
	assert_eq(b.spawns_of(bot_id).size(), 1, "and the fake")
	assert_eq(a.spawns_of(bot_id)[0].display_name, "Bot-01")
	assert_eq(a.spawns_of(bot_id)[0].realm, SOLMARCH)
	var expected_for_a: Array[int] = [bot_id, b_id]
	expected_for_a.sort()
	assert_eq(a.visible_ids(), expected_for_a, "Ana sees Bruno and the fake in her snapshots, not herself")
	var expected_for_b: Array[int] = [bot_id, a_id]
	expected_for_b.sort()
	assert_eq(b.visible_ids(), expected_for_b, "and Bruno sees Ana and the fake")

	# Bruno leaves with CLIENT_LEAVE: Ana receives the DESPAWN with the reason "disconnect".
	var leave := NetMessages.ClientLeave.new()
	b.send_raw(NetProtocol.CH_RELIABLE, leave.encode())
	var despawned: bool = await _run_until(func() -> bool: return not a.despawns.is_empty())
	if not assert_true(despawned, "Ana receives Bruno's DESPAWN"):
		return
	var despawn: NetMessages.EntityDespawn = a.despawns[0]
	assert_eq(despawn.net_id, b_id, "it is Bruno's")
	assert_eq(despawn.reason, NetProtocol.DespawnReason.DISCONNECTED, "reason: disconnect")
	assert_true(despawn.despawn_tick > a.own_spawn.spawn_tick and despawn.despawn_tick <= _server.get_tick(),
			"despawn_tick is the removal tick (%d)" % despawn.despawn_tick)
	await _run_frames(30)
	assert_null(_server.get_registry().get_entity(b_id), "Bruno is no longer in the registry")
	assert_false(_server.get_history().has_tick(b_id, _server.get_tick()),
			"nor is his history track")
	assert_true(_server.get_registry().is_quarantined(b_id, _server.get_tick()),
			"his id is quarantined")
	assert_eq(_server.get_peer_ids().size(), 1, "only Ana remains")
	assert_eq(left.size(), 1, "player_left")
	assert_eq(left[0].y, b_id)
	assert_false(a.visible_ids().has(b_id), "Bruno disappears from Ana's snapshots")
	assert_eq(_server.get_player_count(), 2, "Ana and the fake")

	# A third player who drops without notice is also removed (ENet detects the drop).
	var c: RawClient = await _join("Carla", VARDHEIM)
	if c == null:
		return
	assert_true(c.own_spawn.net_id != b_id, "Bruno's id is not reused within 10 s")
	var c_id: int = c.own_spawn.net_id
	_clients.erase(c)
	c.transport.close()
	var c_gone: bool = await _run_until(func() -> bool:
		for despawn_c: NetMessages.EntityDespawn in a.despawns:
			if despawn_c.net_id == c_id:
				return true
		return false)
	assert_true(c_gone, "Ana receives Carla's DESPAWN when her connection drops")
	c.transport.free()


func test_unexpected_messages_count_strikes_by_session_state() -> void:
	await _start_server()
	var client: RawClient = _connect_client(_hello(VARDHEIM, "Ana"), false)
	var connected: bool = await _run_until(func() -> bool: return client.connected)
	if not assert_true(connected, "the client connects"):
		return
	var peer_id: int = _server.get_peer_ids()[0]
	var peer: ServerPeer = _server.get_peer(peer_id)
	assert_eq(peer.state, ServerPeer.State.LOADING, "loading the zone")

	# While loading: inputs make no sense.
	client.send_inputs(10, 1, Vector2.ZERO, 0.0)
	await _run_frames(3)
	assert_eq(peer.strikes_total, 1, "INPUT_BATCH before entering the world")
	# Two CLIENT_READY in a row: the second is redundant.
	client.send_ready()
	client.send_ready()
	var entered: bool = await _run_until(func() -> bool: return client.own_spawn != null)
	assert_true(entered, "enters the world")
	assert_eq(peer.strikes_total, 2, "the second CLIENT_READY is a warning")
	# Inside the world: another CLIENT_READY, a server-to-client message and a malformed batch.
	client.send_ready()
	client.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([NetProtocol.MSG_SNAPSHOT, 1, 2, 3]))
	client.send_raw(NetProtocol.CH_INPUT, PackedByteArray([NetProtocol.MSG_INPUT_BATCH, 0, 0, 0]))
	await _run_frames(5)
	assert_eq(peer.strikes_total, 5, "three more warnings")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "no kick")
	assert_true(client.notices.is_empty(), "nor a warning to the client")
	var report: Dictionary = _read_report()
	assert_eq(int((report.get("strikes", {}) as Dictionary).get("total", 0)), 5, "the report counts the warnings")


func test_protocol_3_messages_do_not_count_as_strikes() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	# While loading the zone, /atascado makes no sense (like the rest of the player requests).
	var loading: RawClient = _connect_client(_hello(VARDHEIM, "Ana"), false)
	var connected: bool = await _run_until(func() -> bool: return loading.connected)
	if not assert_true(connected, "the client connects"):
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	if assert_not_null(loading.welcome, "the WELCOME arrived"):
		assert_eq(loading.welcome.realm_counts.size(), 3, "the WELCOME carries the per-realm count")
	loading.send_raw(NetProtocol.CH_RELIABLE, NetMessages.UnstuckRequest.new().encode())
	await _run_frames(3)
	assert_eq(peer.strikes_total, 1, "UNSTUCK_REQUEST before entering the world is a warning")
	loading.send_ready()
	var entered: bool = await _run_until(func() -> bool: return loading.own_spawn != null)
	if not assert_true(entered, "enters the world"):
		return
	# Inside the world, a well-formed /atascado is accepted (F3 will do what it asks) and adds nothing.
	loading.send_raw(NetProtocol.CH_RELIABLE, NetMessages.UnstuckRequest.new().encode())
	await _run_frames(3)
	assert_eq(peer.strikes_total, 1, "UNSTUCK_REQUEST in the world adds no warnings")
	# Neither do the debug commands with the fixed id of version 4 and valid data, even though F4 has not
	# yet given them a handler.
	for command: NetMessages.DebugCommand in [
			NetMessages.DebugCommand.simple(NetProtocol.DEBUG_FORT_RESET),
			NetMessages.DebugCommand.fort_owner(NetProtocol.Realm.SOLMARCH),
			NetMessages.DebugCommand.simple(NetProtocol.DEBUG_FORT_KILL_CAPTAIN),
			NetMessages.DebugCommand.fort_capture_speed(10), NetMessages.DebugCommand.npc_debug(true),
			NetMessages.DebugCommand.simple(NetProtocol.DEBUG_UNSTUCK)]:
		loading.send_raw(NetProtocol.CH_RELIABLE, command.encode())
	await _run_frames(5)
	assert_eq(peer.strikes_total, 1, "valid commands 7 to 12 add no warnings")
	# What is malformed or does not come from a client does count.
	loading.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([NetProtocol.MSG_UNSTUCK_REQUEST, 0]))
	loading.send_raw(NetProtocol.CH_RELIABLE,
			PackedByteArray([NetProtocol.MSG_DEBUG_COMMAND, NetProtocol.DEBUG_FORT_OWNER, 9]))
	loading.send_raw(NetProtocol.CH_RELIABLE,
			NetMessages.Scoreboard.new().encode())
	loading.send_raw(NetProtocol.CH_RELIABLE,
			NetMessages.ObjectState.from_fortress(1, 1, FortressState.new()).encode())
	await _run_frames(5)
	assert_eq(peer.strikes_total, 5, "a /atascado with data, fort_owner 9 and two server messages")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "no kick")


func test_flooding_gets_the_client_kicked_with_a_notice() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	var peer_id: int = _server.get_peer_ids()[0]
	# Messages of a type nobody sends to the server, far above the allowed rate.
	for i: int in 120:
		client.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([0x7F, i]))
	var kicked: bool = await _run_until(func() -> bool:
		return client.notice_with_code(NetProtocol.NoticeCode.KICK) != null)
	if not assert_true(kicked, "the client receives the kick NOTICE"):
		return
	assert_true(client.notice_with_code(NetProtocol.NoticeCode.KICK).text.contains("Expulsado"),
			"with a Spanish text")
	var gone: bool = await _run_until(func() -> bool: return _server.get_peer(peer_id) == null)
	assert_true(gone, "the kicked peer is removed")
	assert_null(_server.get_registry().get_entity(net_id), "and their character disappears")
	var disconnected: bool = await _run_until(func() -> bool:
		return client.disconnected or client.failed)
	assert_true(disconnected, "the server cuts the connection after the notice")
	var report: Dictionary = _read_report()
	var kicks: Array = report.get("kicks", [])
	if assert_eq(kicks.size(), 1, "the report records the kick"):
		assert_eq(int((kicks[0] as Dictionary).get("net_id", 0)), net_id)
		assert_false(String((kicks[0] as Dictionary).get("reason", "")).is_empty(), "with its reason")
	var list: Array = report.get("player_list", [])
	assert_true(list.size() == 1 and bool((list[0] as Dictionary).get("kicked", false)),
			"and marks the player as kicked")


## The report's kicks are the latest max_logged_kicks, but all of them are counted (finding S3:
## the list grew with each kick, without limit).
func test_kick_list_in_the_report_is_bounded_but_counts_every_kick() -> void:
	await _start_server()
	_server.max_logged_kicks = 10
	for i: int in 25:
		var peer_id: int = 9000 + i
		_server_transport.peer_authenticating.emit(peer_id)
		# Messages before authenticating: each one is a warning and at 50 the peer is kicked.
		for _j: int in 50:
			_server_transport.packet_received.emit(peer_id, NetMessages.ClientReady.new().encode())
	var report: Dictionary = _read_report()
	var kicks: Array = report.get("kicks", [])
	assert_eq(kicks.size(), 10, "the report keeps the latest 10 kicks")
	assert_eq(int((report.get("strikes", {}) as Dictionary).get("kicks_total", 0)), 25,
			"but counts all 25")
	assert_eq(int((kicks[kicks.size() - 1] as Dictionary).get("peer_id", 0)), 9024,
			"the last one is the most recent")
	assert_eq(int((kicks[0] as Dictionary).get("peer_id", 0)), 9015, "and the first one is the tenth from the end")


## A kicked client cannot come back within one RTT with its warnings at 0 and its buckets full
## (finding S6): during the cooldown, its IP receives a REJECT right on connecting. After the
## cooldown, it can join again.
func test_a_kicked_address_is_rejected_during_the_cooldown() -> void:
	await _start_server()
	_server.kick_cooldown_ticks = 240
	var address: Array[String] = ["203.0.113.7"]
	_server.remote_address_override = func(_peer_id: int, _address: String) -> String:
		return address[0]
	var abuser: RawClient = await _join("Ana")
	if abuser == null:
		return
	for i: int in 120:
		abuser.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([0x7F, i]))
	var kicked: bool = await _run_until(func() -> bool:
		return abuser.notice_with_code(NetProtocol.NoticeCode.KICK) != null)
	if not assert_true(kicked, "the abuser is kicked"):
		return
	await _run_until(func() -> bool: return _server.get_player_count() == 0)
	assert_eq(_server.get_cooldown_count(), 1, "and its IP is on cooldown")
	# It comes back immediately, with another name: rejected before authenticating.
	var again: RawClient = _connect_client(_hello(VARDHEIM, "Bruno"))
	var rejected: bool = await _run_until(func() -> bool: return again.reject != null)
	if assert_true(rejected, "the immediate reconnection receives a REJECT"):
		assert_eq(again.reject.result, NetProtocol.Result.TOO_MANY_CONNECTIONS, "for too many connections")
	assert_null(again.welcome, "no WELCOME")
	assert_eq(_server.get_player_count(), 0, "and it does not take up a slot")
	# Another IP is not affected.
	address[0] = "198.51.100.9"
	var other: RawClient = await _join("Carla")
	assert_not_null(other, "another IP joins normally")
	# After the cooldown, the abuser's IP can join again.
	address[0] = "203.0.113.7"
	await _run_frames(260)
	var back: RawClient = await _join("Diana")
	assert_not_null(back, "after the cooldown, it joins again")
	var rejects: Dictionary = _read_report().get("rejects", {})
	assert_eq(int(rejects.get(NetProtocol.result_text(NetProtocol.Result.TOO_MANY_CONNECTIONS), 0)), 1,
			"the report counts the rejection")


## From loopback there is no per-IP cap, so the cooldown goes by name (ignoring case and accents,
## like the rest of the name checks).
func test_a_kicked_name_from_loopback_is_rejected_during_the_cooldown() -> void:
	await _start_server()
	_server.kick_cooldown_ticks = 240
	var abuser: RawClient = await _join("Álvaro")
	if abuser == null:
		return
	for i: int in 120:
		abuser.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([0x7F, i]))
	var kicked: bool = await _run_until(func() -> bool:
		return abuser.notice_with_code(NetProtocol.NoticeCode.KICK) != null)
	if not assert_true(kicked, "the abuser is kicked"):
		return
	await _run_until(func() -> bool: return _server.get_player_count() == 0)
	var again: RawClient = _connect_client(_hello(VARDHEIM, "ALVARO"))
	var rejected: bool = await _run_until(func() -> bool: return again.reject != null)
	if assert_true(rejected, "coming back with the same name receives a REJECT"):
		assert_eq(again.reject.result, NetProtocol.Result.TOO_MANY_CONNECTIONS)
	var other: RawClient = await _join("Bruno")
	assert_not_null(other, "with another name, from loopback, it gets in")
	await _run_frames(260)
	var back: RawClient = await _join("Alvaro")
	assert_not_null(back, "after the cooldown, the name is free again")


## Expired entries are purged at the next cooldown registration: the dictionary does not grow without
## limit.
func test_expired_cooldowns_are_purged() -> void:
	await _start_server()
	_server.kick_cooldown_ticks = 30
	var address: Array[String] = ["203.0.113.1"]
	_server.remote_address_override = func(_peer_id: int, _address: String) -> String:
		return address[0]
	for i: int in 4:
		address[0] = "203.0.113.%d" % (1 + i)
		_server_transport.peer_authenticating.emit(9100 + i)
		for _j: int in 50:
			_server_transport.packet_received.emit(9100 + i, NetMessages.ClientReady.new().encode())
	assert_eq(_server.get_cooldown_count(), 4, "four kicked IPs")
	await _run_frames(40)
	address[0] = "203.0.113.50"
	_server_transport.peer_authenticating.emit(9200)
	for _j: int in 50:
		_server_transport.packet_received.emit(9200, NetMessages.ClientReady.new().encode())
	assert_eq(_server.get_cooldown_count(), 1, "the expired ones are purged; only the new one remains")


## The RTT in ticks that the server measures with the snapshot ack is decided by the client: a cheater
## who delays their acks would pass as someone with lag and get the maximum phase 3 rewind (finding
## S4). The server bounds it with an independent source: the ENet RTT plus the delay of the server's own
## simulator, plus a margin.
func test_a_client_cannot_fake_lag_with_late_acks() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	client.ack_lag_ticks = 20
	client.interp_delay_q = NetProtocol.MAX_INTERP_DELAY_Q
	_hooks.append(func(_tick: int) -> void:
		client.send_inputs(_server.get_tick() + 2, 1, Vector2(0.0, 1.0), 0.0))
	await _run_frames(300)
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	var bound: int = ceili(_server_transport.get_rtt_ms(peer.peer_id) * 60.0 / 1000.0) \
			+ _server_transport.get_sim_round_trip_ticks() + ZoneServer.RTT_SLACK_TICKS
	assert_true(peer.rtt_ticks <= bound,
			"the measured RTT (%d ticks) does not exceed what ENet allows (%d)" % [peer.rtt_ticks, bound])
	assert_true(peer.rtt_ticks <= 6, "on loopback it is a few ticks (%d)" % peer.rtt_ticks)
	# The window maximum, which the rewind cap uses, is also bounded by the independent source:
	# delaying acks gives no more than the ENet RTT plus the margin.
	assert_true(peer.rtt_peak_ticks >= peer.rtt_ticks and peer.rtt_peak_ticks <= bound,
			"the RTT maximum (%d ticks) does not exceed what ENet allows either (%d)"
			% [peer.rtt_peak_ticks, bound])
	assert_eq(peer.strikes_total, 0, "no warnings: faking lag is not an illegal packet")
	# R1: the lower bound (the minimum rewind for defense) comes from the ENet RTT, not from the acks the
	# client delays.
	var enet_ticks: int = floori(_server_transport.get_rtt_ms(peer.peer_id) * 60.0 / 1000.0)
	assert_true(absi(peer.rtt_floor_ticks - enet_ticks) <= 1,
			"rtt_floor_ticks (%d) is the ENet RTT (%d ticks)" % [peer.rtt_floor_ticks, enet_ticks])
	assert_true(peer.rtt_floor_ticks < 20, "and not the 20 ticks of delayed ack")


## The server's own network simulator does count: it is real delay for the server.
func test_the_server_side_net_sim_still_raises_the_measured_rtt() -> void:
	await _start_server(func(config: ServerConfig) -> void:
		config.net_sim_spec = "rtt=200,jitter=0,loss=0,dup=0,seed=3")
	var client: RawClient = _connect_client(_hello(VARDHEIM, "Ana"))
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null, 900)
	if not assert_true(joined, "enters the world"):
		return
	_hooks.append(func(_tick: int) -> void:
		client.send_inputs(_server.get_tick() + 14, 4, Vector2(0.0, 1.0), 0.0))
	await _run_frames(240)
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_true(peer.rtt_ticks >= 10,
			"with 200 ms of simulated delay (12 ticks) the measured RTT reflects it (%d)" % peer.rtt_ticks)
	assert_true(peer.rtt_peak_ticks >= peer.rtt_ticks, "and the window maximum never drops below the minimum (%d)"
			% peer.rtt_peak_ticks)


## interp_delay_q cannot exceed the maximum of the client's interpolation clock (12 ticks × 8): the
## server clamps it and counts it as a warning.
func test_interp_delay_above_the_clients_maximum_is_clamped_and_costs_a_strike() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	client.interp_delay_q = 255
	client.send_inputs(_server.get_tick() + 2, 1, Vector2.ZERO, 0.0)
	await _run_frames(5)
	assert_eq(peer.interp_delay_q, NetProtocol.MAX_INTERP_DELAY_Q, "it is clamped to the client's maximum")
	assert_eq(peer.strikes_total, 1, "and adds a warning")
	assert_eq(_strike_reasons().get("retardo de interpolación fuera de rango", 0), 1, "with its reason")
	client.interp_delay_q = NetProtocol.MAX_INTERP_DELAY_Q
	client.send_inputs(_server.get_tick() + 2, 1, Vector2.ZERO, 0.0)
	await _run_frames(5)
	assert_eq(peer.interp_delay_q, NetProtocol.MAX_INTERP_DELAY_Q, "the legitimate maximum is accepted")
	assert_eq(peer.strikes_total, 1, "no more warnings")


## A raw ENet client (no SceneMultiplayer) that sends packets that are not part of the protocol before
## the HELLO: they used to log an engine error per packet (the runner fails on any), bypassed the
## limiters and the warnings, were only cut off by the 5 s auth_timeout, and 2000 packets pushed the
## tick to 28 ms (finding S1). Now each one adds a warning, at 50 the peer is kicked and the tick does
## not exceed its 16 ms budget.
func test_foreign_packets_before_the_hello_get_the_sender_kicked() -> void:
	await _start_server()
	var attacker := RawEnetAttacker.new()
	assert_eq(attacker.connect_to(_port), OK, "the attacker connects")
	_raw_attackers.append(attacker)
	_hooks.append(func(_tick: int) -> void: attacker.poll())
	var seen: bool = await _run_until(func() -> bool:
		return attacker.is_connected_to_server() and _server.get_peer_ids().size() == 1, 300)
	if not assert_true(seen, "the server sees the peer that is authenticating"):
		return
	for _i: int in 2000:
		attacker.send(PackedByteArray([3, 1]), 1)
	attacker.flush()
	var gone: bool = await _run_until(func() -> bool: return _server.get_peer_ids().is_empty(), 300)
	assert_true(gone, "the peer is kicked as soon as it reaches 50 warnings, without waiting for the auth_timeout")
	var reasons: Dictionary = _strike_reasons()
	assert_eq(int(reasons.get(ZoneServer.DISCARDED_REASON, 0)), ServerPeer.STRIKE_LIMIT,
			"each foreign packet is a warning, up to 50")
	var report: Dictionary = _read_report()
	assert_eq((report.get("kicks", []) as Array).size(), 1, "one kick")
	assert_eq(_server.get_player_count(), 0, "and nobody takes up a slot")
	var tick_max: int = _server.get_metrics().get_max_us(&"tick")
	assert_true(tick_max < 16000, "the longest tick does not exceed 16 ms (%d µs)" % tick_max)


## The same with the peer already authenticated and inside the world: RPC, SIMPLIFY_PATH, SPAWN and
## system commands. Someone playing normally does not notice.
func test_foreign_packets_after_the_hello_get_the_sender_kicked_and_not_the_others() -> void:
	await _start_server()
	var honest: RawClient = await _join("Ana")
	if honest == null:
		return
	var attacker := RawEnetAttacker.new()
	assert_eq(attacker.connect_to(_port), OK, "the attacker connects")
	_raw_attackers.append(attacker)
	_hooks.append(func(_tick: int) -> void: attacker.poll())
	var connected: bool = await _run_until(func() -> bool: return attacker.is_connected_to_server(), 300)
	if not assert_true(connected, "the attacker connects"):
		return
	attacker.send_auth(_hello(VARDHEIM, "Malvado"))
	attacker.flush()
	var welcomed: bool = await _run_until(func() -> bool:
		return attacker.server_confirmed and not attacker.auth_messages.is_empty(), 300)
	if not assert_true(welcomed, "answers WELCOME"):
		return
	assert_eq(NetMessages.peek_auth_result(attacker.auth_messages[0]), NetProtocol.Result.OK)
	attacker.send_confirmation()
	attacker.flush()
	var is_loading: Callable = func() -> bool:
		var peer: ServerPeer = _peer_named("Malvado")
		return peer != null and peer.state == ServerPeer.State.LOADING
	var admitted: bool = await _run_until(is_loading, 300)
	if not assert_true(admitted, "and admits it (loading the zone)"):
		return
	var mallory: ServerPeer = _peer_named("Malvado")
	var flood: int = 300
	for i: int in flood:
		attacker.send(PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0, 0, 0]), 0)  # SIMPLIFY_PATH
		attacker.send(PackedByteArray([0, 1, 2, 3, 4, 5, 6]), 0)  # RPC
		attacker.send(PackedByteArray([4, 1, 2, 3, 4, 5, 6, 7, 8]), 0)  # SPAWN
		attacker.send(PackedByteArray([7, 1, 2, 0, 0, 0]), 0)  # SYS ADD_PEER
	attacker.flush()
	var kicked: bool = await _run_until(func() -> bool: return _peer_named("Malvado") == null, 300)
	assert_true(kicked, "the attacker ends up kicked")
	assert_true(mallory.strikes_total >= ServerPeer.STRIKE_LIMIT, "after adding 50 warnings (%d)"
			% mallory.strikes_total)
	assert_eq(int(_strike_reasons().get(ZoneServer.DISCARDED_REASON, 0)), ServerPeer.STRIKE_LIMIT,
			"all of them from foreign packets")
	# The other player, going about their business.
	var honest_peer: ServerPeer = _peer_of(honest.own_spawn.net_id)
	assert_eq(honest_peer.strikes_total, 0, "the honest player adds no warnings")
	assert_eq(honest_peer.state, ServerPeer.State.IN_WORLD, "and stays in the world")
	var snapshots_before: int = honest.snapshots.size()
	await _run_frames(30)
	assert_true(honest.snapshots.size() > snapshots_before + 5, "receiving snapshots")
	var tick_max: int = _server.get_metrics().get_max_us(&"tick")
	assert_true(tick_max < 16000, "the longest tick does not exceed 16 ms (%d µs)" % tick_max)


func test_debug_commands_need_the_flag() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var teleport: NetMessages.DebugCommand = NetMessages.DebugCommand.teleport(Vector3(7.0, 0.5, -9.0))
	client.send_raw(NetProtocol.CH_RELIABLE, teleport.encode())
	await _run_frames(10)
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_eq(peer.strikes_total, 1, "without --debug-commands it is a warning")
	assert_eq(peer.entity.teleport_counter, 0, "and there is no teleport")
	assert_vec_near(peer.entity.get_position(), ZoneFixture.VARDHEIM_SPAWNS[0], 0.05,
			"the player stays in place")


func test_debug_teleport_with_the_flag() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var target := Vector3(7.0, 0.5, -9.0)
	client.send_raw(NetProtocol.CH_RELIABLE,
			NetMessages.DebugCommand.teleport(target).encode())
	var teleported: bool = await _run_until(func() -> bool:
		return client.last_snapshot() != null and client.last_snapshot().own_teleport == 1)
	if not assert_true(teleported, "the snapshot carries the player's own teleport counter"):
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_eq(peer.strikes_total, 0, "no warnings")
	assert_eq(peer.entity.teleport_counter, 1)
	var own: PlayerState = client.last_snapshot().own_state
	assert_true(absf(own.position.x - 7.0) < 0.1 and absf(own.position.z + 9.0) < 0.1,
			"the player's own state is at the destination (%s)" % own.position)
	# An out-of-range or non-finite destination is a warning and moves no one.
	client.send_raw(NetProtocol.CH_RELIABLE,
			NetMessages.DebugCommand.teleport(Vector3(1.0e9, 0.0, 0.0)).encode())
	client.send_raw(NetProtocol.CH_RELIABLE,
			NetMessages.DebugCommand.teleport(Vector3(NAN, 0.0, 0.0)).encode())
	await _run_frames(10)
	assert_eq(peer.strikes_total, 2, "two warnings")
	assert_eq(peer.entity.teleport_counter, 1, "no more teleports")


func test_interest_policy_spawns_and_despawns_out_of_interest() -> void:
	await _start_server()
	var policy := HidingPolicy.new()
	_server.interest_policy = policy
	var bot_id: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), SOLMARCH)
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	await _run_frames(20)
	assert_eq(client.spawns_of(bot_id).size(), 1, "the fake is relevant")
	assert_true(client.visible_ids().has(bot_id), "and is in the snapshots")

	policy.hide_bots = true
	var hidden: bool = await _run_until(func() -> bool: return not client.despawns.is_empty(), 60)
	if not assert_true(hidden, "when it stops being relevant a DESPAWN arrives (every 6 ticks at most)"):
		return
	assert_eq(client.despawns[0].net_id, bot_id)
	assert_eq(client.despawns[0].reason, NetProtocol.DespawnReason.OUT_OF_INTEREST, "reason 0")
	await _run_frames(10)
	assert_false(client.visible_ids().has(bot_id), "it stops being in the snapshots")
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_false(peer.relevant.has(bot_id), "and in the peer's relevant set")

	policy.hide_bots = false
	var back: bool = await _run_until(func() -> bool: return client.spawns_of(bot_id).size() == 2, 60)
	assert_true(back, "when it becomes relevant again another SPAWN arrives")
	await _run_frames(10)
	assert_true(client.visible_ids().has(bot_id), "and it reappears in the snapshots")


func test_handshake_and_snapshots_with_a_network_simulator() -> void:
	await _start_server(func(config: ServerConfig) -> void:
		config.net_sim_spec = "rtt=100,jitter=10,loss=0,dup=0,seed=5")
	var client: RawClient = _connect_client(_hello(VARDHEIM, "Ana"))
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null, 600)
	if not assert_true(joined, "with 100 ms of RTT it also enters the world"):
		return
	_hooks.append(func(_tick: int) -> void:
		var newest: int = _server.get_tick() + 12
		if newest > client.own_spawn.spawn_tick + 3:
			client.send_inputs(newest, 4, Vector2(0.0, 1.0), client.own_spawn.state.yaw))
	await _run_frames(120)
	assert_true(client.snapshots.size() > 20, "snapshots arrive (%d)" % client.snapshots.size())
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_true(peer.rtt_ticks >= 3, "the measured RTT includes the simulated delay (%d ticks)"
			% peer.rtt_ticks)
	assert_true(client.last_snapshot().own_state.position.z < client.own_spawn.state.position.z - 2.0,
			"and the inputs take effect")


func test_client_that_never_sends_ready_is_kicked_after_the_loading_timeout() -> void:
	await _start_server()
	_server.loading_timeout_ticks = 90
	var client: RawClient = _connect_client(_hello(VARDHEIM, "Ana"), false)
	var connected: bool = await _run_until(func() -> bool: return client.connected)
	if not assert_true(connected, "the client connects and starts loading"):
		return
	assert_eq(_server.get_player_count(), 1, "loading the zone already takes up a slot")
	var kicked: bool = await _run_until(func() -> bool:
		return client.notice_with_code(NetProtocol.NoticeCode.KICK) != null, 400)
	if assert_true(kicked, "past the loading limit it receives a kick NOTICE"):
		assert_true(client.notice_with_code(NetProtocol.NoticeCode.KICK).text.contains("carga"),
				"that explains the reason")
	await _run_frames(10)
	assert_eq(_server.get_peer_ids().size(), 0, "and it is removed")
	assert_eq(_server.get_player_count(), 0)


func test_client_that_never_sends_hello_is_dropped_by_the_auth_timeout() -> void:
	await _start_server()
	# The server's own deadline for the HELLO is disabled: here NetTransport's (10 s) applies.
	_server.hello_timeout_ticks = 100000
	# No HELLO: the client connects but sends nothing during authentication.
	var client: RawClient = _connect_client(PackedByteArray())
	var seen: bool = await _run_until(func() -> bool: return _server.get_peer_ids().size() == 1, 120)
	if not assert_true(seen, "the server sees the peer that is authenticating"):
		return
	assert_eq(_server.get_player_count(), 0, "a peer that is authenticating does not take up a slot")
	var dropped: bool = await _run_until(func() -> bool: return _server.get_peer_ids().is_empty(),
			int(NetTransport.AUTH_TIMEOUT_SECONDS * 60.0) + 240)
	assert_true(dropped, "after the authentication time (10 s) the peer is removed")
	assert_true(client.failed or client.disconnected, "and the client sees the cut")


## An IP cannot take up all the ENet slots with connections that never send the HELLO (finding S2):
## the per-IP cap is applied on connecting, not only when the HELLO arrives. With max_players = 2
## there are 6 slots; an IP with 6 idle connections used to leave the seventh, legitimate client
## without a response (ENet silently drops its connection). The idle connections are raw ENet
## (no SceneMultiplayer), like an attacker's.
func test_idle_connections_cannot_exhaust_the_slots_of_one_ip() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.max_players = 2)
	# Only the per-IP cap is tested: the HELLO deadline must not cut anything off during the test.
	_server.hello_timeout_ticks = 100000
	var opened: Array[int] = [0]
	_server.remote_address_override = func(_peer_id: int, _address: String) -> String:
		opened[0] += 1
		return "203.0.113.7" if opened[0] <= 6 else "198.51.100.9"
	var idle: Array[ENetMultiplayerPeer] = []
	for _i: int in 6:
		var raw := ENetMultiplayerPeer.new()
		assert_eq(raw.create_client("127.0.0.1", _port, NetProtocol.CUSTOM_CHANNELS), OK)
		idle.append(raw)
		_raw_peers.append(raw)
		await _run_frames(3)
	_hooks.append(func(_tick: int) -> void:
		for raw: ENetMultiplayerPeer in idle:
			# A peer the server has cut off becomes inactive and poll() would log an error.
			if raw.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
				raw.poll())
	var connected_count: Callable = func() -> int:
		var count: int = 0
		for raw: ENetMultiplayerPeer in idle:
			if raw.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
				count += 1
		return count
	await _run_frames(60)
	assert_eq(connected_count.call(), 4,
			"the server cuts whatever exceeds the cap: 4 connections from the IP remain")
	var legit: RawClient = _connect_client(_hello(VARDHEIM, "Ana"))
	var answered: bool = await _run_until(func() -> bool:
		return legit.welcome != null or legit.reject != null, 120)
	assert_true(answered, "the legitimate client gets a response in fewer than 120 ticks")
	assert_not_null(legit.welcome, "and it is a WELCOME: the slots are not exhausted")
	assert_eq(_strike_reasons().size(), 0, "no warnings")
	var rejects: Dictionary = _read_report().get("rejects", {})
	assert_eq(int(rejects.get(NetProtocol.result_text(NetProtocol.Result.TOO_MANY_CONNECTIONS), 0)), 2,
			"the report counts the two rejections")


## A client that connects and does not send the HELLO is cut as soon as the server's own deadline
## expires (90 ticks), long before SceneMultiplayer's 10 s authentication.
func test_a_connection_without_hello_is_dropped_after_the_hello_deadline() -> void:
	await _start_server()
	assert_eq(_server.hello_timeout_ticks, ZoneServer.HELLO_TIMEOUT_TICKS, "90 ticks by default")
	var client: RawClient = _connect_client(PackedByteArray())
	var seen: bool = await _run_until(func() -> bool: return _server.get_peer_ids().size() == 1, 120)
	if not assert_true(seen, "the server sees the peer that is authenticating"):
		return
	var seen_at: int = _server.get_tick()
	var dropped: bool = await _run_until(func() -> bool: return _server.get_peer_ids().is_empty(),
			ZoneServer.HELLO_TIMEOUT_TICKS + 90)
	assert_true(dropped, "the peer with no HELLO is removed after the deadline")
	assert_true(_server.get_tick() - seen_at >= ZoneServer.HELLO_TIMEOUT_TICKS - 10,
			"not ahead of time (%d ticks)" % (_server.get_tick() - seen_at))
	assert_true(_server.get_tick() - seen_at < int(NetTransport.AUTH_TIMEOUT_SECONDS * 60.0),
			"and well before the 10 s of authentication")
	var closed: bool = await _run_until(func() -> bool: return client.failed or client.disconnected, 120)
	assert_true(closed, "the client sees the cut")
	var rejects: Dictionary = _read_report().get("rejects", {})
	assert_eq(int(rejects.get(ZoneServer.HELLO_TIMEOUT_REASON, 0)), 1, "the report counts it")
	# A client that does send the HELLO on time is not affected.
	var honest: RawClient = await _join("Ana")
	assert_not_null(honest, "a normal one gets in")


func test_stop_notifies_the_clients_and_closes_the_transport() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	_server.stop("Mantenimiento")
	assert_false(_server.is_stopped(), "with clients connected it waits for them to leave")
	var notified: bool = await _run_until(func() -> bool:
		return client.notice_with_code(NetProtocol.NoticeCode.SHUTDOWN) != null)
	if assert_true(notified, "the client receives the shutdown NOTICE"):
		assert_eq(client.notice_with_code(NetProtocol.NoticeCode.SHUTDOWN).text, "Mantenimiento")
	var stopped: bool = await _run_until(func() -> bool: return _server.is_stopped(), 90)
	assert_true(stopped, "the server finishes shutting down")
	assert_false(_server_transport.is_server(), "and closes the transport")
	assert_eq(_server.get_player_count(), 0)


# --- Security (docs/networking.md, section 12): the limiters, the per-IP cap and the warnings -----------

## Report warnings by reason: {reason: times}.
func _strike_reasons() -> Dictionary:
	var report: Dictionary = _read_report()
	return (report.get("strikes", {}) as Dictionary).get("by_reason", {})


## The peer with that name (null if there is none).
func _peer_named(player_name: String) -> ServerPeer:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.display_name == player_name:
			return peer
	return null


## The peer whose character is the one with that net_id (null if there is none).
func _peer_of(net_id: int) -> ServerPeer:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.entity != null and peer.entity.net_id == net_id:
			return peer
	return null


func test_input_flood_trips_the_unreliable_limiter() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_eq(peer.strikes_total, 0, "a well-behaved client adds no warnings")
	# 40 valid batches in the same tick: the unreliable burst allows 30 (plus what it recovers,
	# 2 per tick); the rest are dropped and each one adds a warning.
	var next_tick: int = _server.get_tick() + 5
	for i: int in 40:
		client.send_inputs(next_tick + i % 20, 1, Vector2(0.0, 1.0), 0.0)
	await _run_frames(5)
	assert_true(peer.strikes_total >= 6 and peer.strikes_total <= 12,
			"batches beyond the burst are dropped (%d warnings)" % peer.strikes_total)
	assert_eq(_strike_reasons().get("exceso de ritmo", 0), peer.strikes_total,
			"and all the warnings are for exceeding the rate")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "without reaching a kick")
	assert_true(client.notices.is_empty(), "nor a warning to the client")
	# Taking it easy, on the other hand, the normal rate (one batch per tick) costs no warnings.
	var strikes_before: int = peer.strikes_total
	for _i: int in 90:
		client.send_inputs(_server.get_tick() + 6, 4, Vector2.ZERO, 0.0)
		await _run_frames(1)
	assert_eq(peer.strikes_total, strikes_before, "one batch per tick is not exceeding the rate")


## A server stall (the process goes without running) makes the input batches that the client kept
## sending all arrive together in the first poll afterwards: that is not exceeding the rate (finding
## N2). Without stall credit, the bucket does not refill because the tick does not advance, and the
## honest client adds a warning per batch and is kicked.
func test_a_server_stall_does_not_get_an_honest_client_kicked() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	_hooks.append(func(_tick: int) -> void:
		client.send_inputs(_server.get_tick() + 2, 4, Vector2(0.0, 1.0), 0.0))
	await _run_frames(30)
	assert_eq(peer.strikes_total, 0, "before the stall, no warnings")
	_server.set_physics_process(false)
	await _run_frames(90)
	_server.set_physics_process(true)
	await _run_frames(30)
	assert_eq(peer.strikes_total, 0, "after a 90-tick stall, no warnings")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "the client is still in the world")
	assert_null(client.notice_with_code(NetProtocol.NoticeCode.KICK), "no kick NOTICE")
	var report: Dictionary = _read_report()
	assert_eq((report.get("kicks", []) as Array).size(), 0, "the report records no kicks")
	assert_eq(int((report.get("strikes", {}) as Dictionary).get("total", 0)), 0,
			"nor warnings")


func test_reliable_flood_trips_the_reliable_limiter() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	# 30 valid teleports at once: the reliable ones allow a burst of 20 (the sign-up CLIENT_READY
	# already spent a token) plus 1 every 6 ticks, so the rest are dropped with one warning
	# each.
	for i: int in 30:
		client.send_raw(NetProtocol.CH_RELIABLE,
				NetMessages.DebugCommand.teleport(Vector3(float(i), 0.5, 0.0)).encode())
	await _run_frames(8)
	assert_true(peer.strikes_total >= 8 and peer.strikes_total <= 11,
			"the reliable ones beyond the burst add warnings (%d)" % peer.strikes_total)
	assert_eq(_strike_reasons().get("exceso de ritmo", 0), peer.strikes_total,
			"for exceeding the rate")
	var teleports: int = int(_read_report().get("teleports", 0))
	assert_true(teleports >= 19 and teleports <= 21,
			"those that fit in the burst are applied, which the CLIENT_READY already spent from (%d)" % teleports)
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "and there is no kick with fewer than 50 warnings")


func test_bytes_limiter_drops_big_packets_even_below_the_packet_rate() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	# 5 packets of 1000 B (the type of a batch, malformed): a 4 KB byte burst allows 4.
	var big: PackedByteArray = PackedByteArray()
	big.resize(1000)
	big[0] = NetProtocol.MSG_INPUT_BATCH
	for _i: int in 5:
		client.send_raw(NetProtocol.CH_INPUT, big)
	await _run_frames(5)
	var reasons: Dictionary = _strike_reasons()
	assert_eq(reasons.get("lote de entradas mal formado", 0), 4, "the first 4 get as far as being decoded")
	assert_eq(reasons.get("exceso de ritmo", 0), 1, "the fifth is dropped by the byte limiter")
	assert_eq(peer.strikes_total, 5)
	# A packet larger than the whole burst is never granted, however long you wait.
	var huge: PackedByteArray = PackedByteArray()
	huge.resize(5000)
	huge[0] = NetProtocol.MSG_CLIENT_LEAVE
	client.send_raw(NetProtocol.CH_RELIABLE, huge)
	await _run_frames(5)
	assert_eq(_strike_reasons().get("exceso de ritmo", 0), 2, "a 5 KB packet does not pass either")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "and its CLIENT_LEAVE was not executed")


func test_ip_cap_rejects_the_extra_connection_but_not_loopback() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.max_connections_per_ip = 2)
	# From loopback there is no cap: 4 clients get in with a cap of 2.
	var loopback: Array[RawClient] = []
	for player_name: String in ["Ana", "Bruno", "Carla", "Diana"]:
		var client: RawClient = await _join(player_name)
		if client == null:
			return
		loopback.append(client)
	assert_eq(_server.get_player_count(), 4, "four loopback players with a cap of 2")
	# The next ones are pretended to come from an external IP: now the cap does count.
	_server.remote_address_override = func(_peer_id: int, _address: String) -> String:
		return "203.0.113.7"
	var first: RawClient = await _join("Elena")
	var second: RawClient = await _join("Fabio")
	if first == null or second == null:
		return
	var third: RawClient = _connect_client(_hello(VARDHEIM, "Gloria"))
	var rejected: bool = await _run_until(func() -> bool: return third.reject != null)
	if not assert_true(rejected, "the third connection from the same IP receives a REJECT"):
		return
	assert_eq(third.reject.result, NetProtocol.Result.TOO_MANY_CONNECTIONS, "for too many connections")
	assert_eq(third.reject.text, NetProtocol.result_text(NetProtocol.Result.TOO_MANY_CONNECTIONS))
	assert_null(third.welcome, "no WELCOME")
	assert_eq(_server.get_player_count(), 6, "and it does not take up a slot")
	# When one of the two leaves, there is room again for that IP.
	first.transport.close()
	var gone: bool = await _run_until(func() -> bool: return _server.get_player_count() == 5)
	assert_true(gone, "the removal frees one connection from that IP")
	var fourth: RawClient = await _join("Hilda")
	assert_not_null(fourth, "and another one gets in")
	assert_eq(_server.get_player_count(), 6)


func test_unexpected_messages_for_the_session_state_are_strikes() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	# Loading the zone: a debug command before entering the world.
	var loading: RawClient = _connect_client(_hello(VARDHEIM, "Ana"), false)
	var connected: bool = await _run_until(func() -> bool: return loading.connected)
	if not assert_true(connected, "the client connects"):
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	loading.send_raw(NetProtocol.CH_RELIABLE,
			NetMessages.DebugCommand.teleport(Vector3(1.0, 0.5, 1.0)).encode())
	await _run_frames(3)
	assert_eq(peer.strikes_total, 1, "DEBUG_COMMAND while loading the zone is a warning")
	assert_eq(peer.state, ServerPeer.State.LOADING, "and it does not change its state")
	# A second HELLO from someone who is already authenticated.
	_server_transport.auth_received.emit(peer.peer_id, _hello(VARDHEIM, "Ana"))
	assert_eq(peer.strikes_total, 2, "a repeated HELLO is a warning")
	# An application packet from a peer that is still authenticating (it should not be able to arrive).
	_server_transport.peer_authenticating.emit(9999)
	var stranger: ServerPeer = _server.get_peer(9999)
	if assert_not_null(stranger, "the server registers the peer that is authenticating"):
		_server_transport.packet_received.emit(9999, NetMessages.ClientReady.new().encode())
		assert_eq(stranger.strikes_total, 1, "a message before authenticating is a warning")
	# A malformed CLIENT_LEAVE counts; a good one is a clean exit.
	loading.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([NetProtocol.MSG_CLIENT_LEAVE, 0, 0]))
	await _run_frames(3)
	assert_eq(peer.strikes_total, 3, "malformed CLIENT_LEAVE")
	assert_eq(peer.state, ServerPeer.State.LOADING)
	loading.send_raw(NetProtocol.CH_RELIABLE, NetMessages.ClientLeave.new().encode())
	var left: bool = await _run_until(func() -> bool: return _server.get_peer(peer.peer_id) == null)
	assert_true(left, "and the good one removes the peer with no further warnings")
	assert_eq(peer.strikes_total, 3)


func test_random_garbage_gets_the_sender_kicked_and_leaves_the_others_untouched() -> void:
	await _start_server()
	var honest: RawClient = await _join("Ana")
	var cheater: RawClient = await _join("Bruno")
	if honest == null or cheater == null:
		return
	# Peer ids are random: each peer is looked up by its character's net_id.
	var honest_peer: ServerPeer = _peer_of(honest.own_spawn.net_id)
	var cheater_peer: ServerPeer = _peer_of(cheater.own_spawn.net_id)
	var cheater_id: int = cheater.own_spawn.net_id
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	# Random bytes, of any size and type, over the three channels: nothing can break the server.
	var channels: Array[int] = [NetProtocol.CH_INPUT, NetProtocol.CH_RELIABLE]
	var sent: int = 0
	while sent < 400 and cheater_peer.state != ServerPeer.State.LEAVING:
		var garbage := PackedByteArray()
		garbage.resize(rng.randi_range(1, 160))
		for i: int in garbage.size():
			garbage[i] = rng.randi_range(0, 255)
		cheater.send_raw(channels[sent % channels.size()], garbage)
		sent += 1
		if sent % 4 == 0:
			await _run_frames(1)
	var kicked: bool = await _run_until(func() -> bool:
		return cheater.notice_with_code(NetProtocol.NoticeCode.KICK) != null)
	assert_true(kicked, "the one sending garbage receives the kick NOTICE")
	var gone: bool = await _run_until(func() -> bool: return _server.get_peer(cheater_peer.peer_id) == null)
	assert_true(gone, "and the server removes it")
	assert_null(_server.get_registry().get_entity(cheater_id), "with its character")
	assert_eq(honest_peer.strikes_total, 0, "the other client adds no warnings")
	assert_eq(honest_peer.state, ServerPeer.State.IN_WORLD, "and stays in the world")
	var snapshots_before: int = honest.snapshots.size()
	await _run_frames(30)
	assert_true(honest.snapshots.size() > snapshots_before + 5, "and receiving snapshots")
	assert_eq(_server.get_player_count(), 1, "one player remains")
