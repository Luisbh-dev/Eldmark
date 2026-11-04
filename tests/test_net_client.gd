extends TestCase
## Tests for [NetClient] against a fake server that speaks the protocol by hand (docs/red.md,
## sections 3, 5.4, 6.2 and 9.4): the contents of the HELLO, that no input is sent before its own
## SPAWN, the redundancy and the trimming by the INPUT_BATCH ack, the batch header, that
## out-of-order snapshots do not reconcile, how the prediction differences are classified
## (explained, unexplained, teleports, hard resets), the NOTICEs, the orderly exit and
## connection failures. The fake server does not simulate: it sends what each test asks of it.
## [br][br]
## The tests with a real server (that of [ZoneServer]) are in [code]test_net_loopback.gd[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const WAIT_FRAMES: int = 600


## Server that answers the handshake, registers the client when the test asks and keeps everything
## it receives. Its snapshots carry no state of their own except those the test sends by hand.
class FakeServer extends Node:
	var transport: NetTransport
	var tick: int = 0
	var peer_id: int = 0
	var zone_id: String = "test_world"
	var tick_rate: int = 60
	var welcome_version: int = NetProtocol.PROTOCOL_VERSION
	## Per-realm count carried in the WELCOME and reason with which the HELLO is rejected (0 = accepted).
	var realm_counts: PackedInt32Array = PackedInt32Array([0, 0, 0])
	var reject_result: int = 0
	var spawn_state: PlayerState
	var spawn_net_id: int = 5
	## Ticks between the CLIENT_READY and its own SPAWN (very large = never).
	var spawn_delay_ticks: int = 2
	var auto_snapshots: bool = true
	var snapshot_interval_ticks: int = 2
	## true: the snapshots' ack is the last input tick received; false: [member fixed_ack].
	var follow_ack: bool = false
	var fixed_ack: int = 0
	var substitutions: int = 0
	var margin: int = 2
	var hello: NetMessages.Hello = null
	var ready_count: int = 0
	var ready_tick: int = -1
	var spawn_tick: int = -1
	## {batch, tick, after_spawn}
	var batches: Array[Dictionary] = []
	var debug_commands: Array[NetMessages.DebugCommand] = []
	var chat_sends: Array[NetMessages.ChatSend] = []
	## LOADOUT_SELECTs received: {template, ready_count} (CLIENT_READYs received up to then).
	var loadout_selects: Array[Dictionary] = []
	var leave_received: bool = false
	var snapshots_sent: int = 0
	var last_newest: int = 0

	func _init() -> void:
		name = "FakeServer"
		process_physics_priority = -100
		spawn_state = PlayerState.new()
		spawn_state.position = Vector3(-20.0, 0.0, 0.0)
		spawn_state.grounded = true

	func listen(port: int) -> Error:
		transport = NetTransport.new()
		transport.name = "FakeTransport"
		add_child(transport)
		transport.auth_received.connect(_on_auth_received)
		transport.packet_received.connect(_on_packet)
		return transport.host(port, 4)

	func _physics_process(_delta: float) -> void:
		transport.poll(tick)
		tick += 1
		if ready_tick >= 0 and spawn_tick < 0 and tick >= ready_tick + spawn_delay_ticks:
			_send_spawn()
		if auto_snapshots and spawn_tick >= 0 and tick % snapshot_interval_ticks == 0:
			send_snapshot(tick)
		transport.flush()

	func send_snapshot(server_tick: int, own_state: PlayerState = null,
			teleport_counter: int = 0) -> void:
		var snapshot := NetMessages.Snapshot.new()
		snapshot.server_tick = server_tick
		snapshot.input_ack_tick = last_newest if follow_ack else fixed_ack
		snapshot.input_margin = margin
		snapshot.substitutions = substitutions & 0xFFFF
		snapshot.own_teleport = teleport_counter
		snapshot.own_state = own_state
		transport.send(peer_id, NetProtocol.CH_SNAPSHOT, snapshot.encode())
		snapshots_sent += 1

	func send_notice(code: int, text: String) -> void:
		var notice := NetMessages.Notice.new()
		notice.code = code
		notice.text = text
		transport.send(peer_id, NetProtocol.CH_RELIABLE, notice.encode())

	func batches_after_spawn() -> Array[Dictionary]:
		var found: Array[Dictionary] = []
		for entry: Dictionary in batches:
			if entry["after_spawn"]:
				found.append(entry)
		return found

	func _send_spawn() -> void:
		spawn_tick = tick
		var spawn := NetMessages.EntitySpawn.new()
		spawn.net_id = spawn_net_id
		spawn.spawn_tick = tick
		spawn.realm = NetProtocol.Realm.VARDHEIM
		spawn.is_yours = true
		spawn.state = spawn_state
		spawn.display_name = "Bot-9"
		transport.send(peer_id, NetProtocol.CH_RELIABLE, spawn.encode())

	func _on_auth_received(from_peer: int, bytes: PackedByteArray) -> void:
		peer_id = from_peer
		hello = NetMessages.Hello.decode(bytes)
		if reject_result > 0:
			var reject := NetMessages.Reject.new()
			reject.result = reject_result
			reject.text = NetProtocol.result_text(reject_result)
			transport.send_auth(from_peer, reject.encode())
			transport.disconnect_after_flush(from_peer)
			return
		var welcome := NetMessages.Welcome.new()
		welcome.protocol_version = welcome_version
		welcome.server_tick = tick
		welcome.tick_rate = tick_rate
		welcome.realm = hello.realm if hello != null else NetProtocol.Realm.VARDHEIM
		welcome.zone_id = zone_id
		welcome.realm_counts = realm_counts
		transport.send_auth(from_peer, welcome.encode())
		transport.complete_auth(from_peer)

	func _on_packet(from_peer: int, bytes: PackedByteArray) -> void:
		match NetMessages.peek_type(bytes):
			NetProtocol.MSG_CLIENT_READY:
				ready_count += 1
				ready_tick = tick
			NetProtocol.MSG_INPUT_BATCH:
				var batch: NetMessages.InputBatch = NetMessages.InputBatch.decode(bytes)
				if batch != null:
					last_newest = maxi(last_newest, batch.newest_tick)
					batches.append({"batch": batch, "tick": tick, "after_spawn": spawn_tick >= 0})
			NetProtocol.MSG_CLIENT_LEAVE:
				leave_received = true
				transport.disconnect_after_flush(from_peer)
			NetProtocol.MSG_DEBUG_COMMAND:
				var command: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(bytes)
				if command != null:
					debug_commands.append(command)
			NetProtocol.MSG_CHAT_SEND:
				var chat: NetMessages.ChatSend = NetMessages.ChatSend.decode(bytes)
				if chat != null:
					chat_sends.append(chat)
			NetProtocol.MSG_LOADOUT_SELECT:
				var select: NetMessages.LoadoutSelect = NetMessages.LoadoutSelect.decode(bytes)
				if select != null:
					loadout_selects.append({"template": select.template_id, "ready_count": ready_count})


var _root: Node
var _fake: FakeServer
var _viewport: SubViewport
var _client: NetClient
var _port: int = 0


func before_each() -> void:
	_root = Node.new()
	_root.name = "NetClientTest"
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_viewport):
		_viewport.free()
	if is_instance_valid(_fake):
		_fake.free()
	_viewport = null
	_fake = null
	_client = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

## Fake server and a bot connected to it. [param configure] receives the server before it starts.
func _start(configure: Callable = Callable()) -> void:
	_port = NetHarness.free_udp_port()
	_fake = FakeServer.new()
	if configure.is_valid():
		configure.call(_fake)
	_root.add_child(_fake)
	assert_eq(_fake.listen(_port), OK)
	_viewport = NetHarness.make_world_viewport(_root, "")
	_client = NetHarness.start_bot(_viewport, _port, VARDHEIM, 9)


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _in_world() -> bool:
	return _client.get_state() == NetClient.State.IN_WORLD


## Counts how many input batches the client has sent and returns the new ones within [param frames]
## frames.
func _collect_batches(frames: int) -> Array[Dictionary]:
	var before: int = _fake.batches.size()
	await wait_physics_frames(frames)
	var found: Array[Dictionary] = []
	for i: int in range(before, _fake.batches.size()):
		found.append(_fake.batches[i])
	return found


func _counts_of(entries: Array[Dictionary]) -> Array[int]:
	var counts: Array[int] = []
	for entry: Dictionary in entries:
		counts.append((entry["batch"] as NetMessages.InputBatch).inputs.size())
	return counts


# --- Handshake and startup --------------------------------------------------------------------

func test_hello_carries_the_clients_identity() -> void:
	await _start()
	assert_true(await _wait_until(func() -> bool: return _fake.hello != null), "the HELLO arrives")
	var hello: NetMessages.Hello = _fake.hello
	assert_eq(hello.protocol_version, NetProtocol.PROTOCOL_VERSION)
	assert_eq(hello.realm, VARDHEIM)
	assert_eq(hello.display_name, NameRules.bot_name(9))
	assert_true(hello.is_bot(), "a bot declares it in the flags")
	assert_eq(hello.character_id, 0)
	assert_true(hello.ticket.is_empty())
	var scene: PackedScene = load(NetClient.PLAYER_SCENE_PATH) as PackedScene
	var probe: PlayerCharacter = scene.instantiate() as PlayerCharacter
	_root.add_child(probe)
	assert_eq(hello.sim_hash, NetProtocol.compute_sim_hash(probe),
			"the fingerprint is that of the character simulation")
	probe.free()


## With a ticket (docs/plataforma.md §5.4 and §15 P8): the HELLO carries the character and the 52 B of enter, with the realm and the
## character's name.
func test_hello_carries_the_ticket_and_the_character_of_enter() -> void:
	_port = NetHarness.free_udp_port()
	_fake = FakeServer.new()
	_root.add_child(_fake)
	assert_eq(_fake.listen(_port), OK)
	_viewport = NetHarness.make_world_viewport(_root, "")
	var transport := NetTransport.new()
	_viewport.add_child(transport)
	var controller := LocalPlayerController.new()
	_viewport.add_child(controller)
	_client = NetClient.new()
	_viewport.add_child(_client)
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.ONLINE
	config.port = _port
	config.realm = NetProtocol.Realm.SOLMARCH
	config.display_name = "Anéira"
	config.character_id = 9007199254740993
	config.ticket = PackedByteArray(range(52))
	config.from_front = true
	assert_eq(_client.start(config, transport, controller), OK)
	assert_true(await _wait_until(func() -> bool: return _fake.hello != null), "the HELLO arrives")
	var hello: NetMessages.Hello = _fake.hello
	assert_eq(hello.character_id, 9007199254740993, "the character from enter (over 2^53)")
	assert_eq(hello.ticket, PackedByteArray(range(52)), "the ticket as is")
	assert_eq(hello.realm, NetProtocol.Realm.SOLMARCH, "the character's realm")
	assert_eq(hello.display_name, "Anéira", "and its name")
	assert_false(hello.is_bot(), "a player is not a bot")
	assert_true(await _wait_until(func() -> bool: return _client.get_state() == NetClient.State.WELCOMED),
			"and enters as usual")


func test_a_dtls_certificate_that_cannot_be_read_does_not_connect() -> void:
	_viewport = NetHarness.make_world_viewport(_root, "")
	var transport := NetTransport.new()
	_viewport.add_child(transport)
	var controller := LocalPlayerController.new()
	_viewport.add_child(controller)
	_client = NetClient.new()
	_viewport.add_child(_client)
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.ONLINE
	config.port = NetHarness.free_udp_port()
	config.realm = VARDHEIM
	config.dtls_cert_path = "res://no/existe.pem"
	config.dtls_name = "zona"
	assert_null(NetClient.dtls_options(config), "without a certificate there are no DTLS options")
	assert_eq(_client.start(config, transport, controller), ERR_INVALID_DATA,
			"it does not connect in the clear when DTLS was requested")
	assert_eq(_client.get_state(), NetClient.State.IDLE)
	assert_null(NetClient.dtls_options(ClientConfig.new()), "without DTLS requested, nothing")


func test_the_welcome_carries_the_realm_counts_for_the_realm_select() -> void:
	await _start(func(fake: FakeServer) -> void: fake.realm_counts = PackedInt32Array([12, 3, 40]))
	assert_true(await _wait_until(_in_world))
	var welcome: NetMessages.Welcome = _client.get_welcome()
	assert_eq(welcome.realm_counts, PackedInt32Array([12, 3, 40]), "the WELCOME's per-realm count")
	assert_eq(welcome.get_realm_count(NetProtocol.Realm.SOLMARCH), 3)


func test_an_imbalance_rejection_reaches_the_client_with_its_spanish_text() -> void:
	await _start(func(fake: FakeServer) -> void: fake.reject_result = NetProtocol.Result.IMBALANCE)
	var rejections: Array[Dictionary] = []
	_client.rejected.connect(func(result: int, text: String) -> void:
		rejections.append({"result": result, "text": text}))
	assert_true(await _wait_until(func() -> bool: return not rejections.is_empty()), "the REJECT arrives")
	assert_eq(rejections[0]["result"], NetProtocol.Result.IMBALANCE, "REJECT 9")
	assert_eq(rejections[0]["text"], NetProtocol.result_text(NetProtocol.Result.IMBALANCE))
	assert_true(String(rejections[0]["text"]).contains("demasiados jugadores"), "it says why (%s)" % rejections[0]["text"])
	assert_true(String(rejections[0]["text"]).contains("elige otro"), "and what to do")
	assert_eq(_client.get_state(), NetClient.State.CLOSED, "and the session closes")


func test_ready_is_sent_once_after_the_zone_is_ready() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	assert_eq(_fake.ready_count, 1, "a single CLIENT_READY")
	assert_true(_client.get_controller().auto_step == false)
	assert_eq(_client.get_net_id(), _fake.spawn_net_id)
	assert_eq(_client.get_spawn_tick(), _fake.spawn_tick)


func test_no_input_is_sent_before_the_own_spawn() -> void:
	await _start(func(fake: FakeServer) -> void: fake.spawn_delay_ticks = 45)
	assert_true(await _wait_until(func() -> bool: return _fake.ready_tick >= 0))
	await wait_physics_frames(40)
	assert_eq(_client.get_state(), NetClient.State.READY_SENT, "still without a character")
	assert_true(_fake.batches.is_empty(), "not a single input before its own SPAWN")
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(8)
	assert_false(_fake.batches.is_empty(), "and with the SPAWN they start to go out")
	for entry: Dictionary in _fake.batches:
		assert_true(entry["after_spawn"], "all after the spawn")
	var first: NetMessages.InputBatch = _fake.batches[0]["batch"]
	assert_eq(first.newest_tick, _client.get_prediction().get_first_real_tick(),
			"the first real input is P0")


func test_send_debug_command_needs_a_character() -> void:
	await _start(func(fake: FakeServer) -> void: fake.spawn_delay_ticks = 30)
	assert_true(await _wait_until(func() -> bool: return _fake.ready_tick >= 0))
	var payload: PackedByteArray = NetMessages.DebugCommand.teleport(Vector3(1.0, 2.0, 3.0)).payload
	_client.send_debug_command(NetProtocol.DEBUG_TELEPORT, payload)
	await wait_physics_frames(10)
	assert_true(_fake.debug_commands.is_empty(), "without a character nothing is sent")
	assert_true(await _wait_until(_in_world))
	_client.send_debug_command(NetProtocol.DEBUG_TELEPORT, payload)
	assert_true(await _wait_until(func() -> bool: return not _fake.debug_commands.is_empty()))
	assert_vec_near(_fake.debug_commands[0].get_teleport_position(), Vector3(1.0, 2.0, 3.0), 0.001)


# --- INPUT_BATCH ------------------------------------------------------------------------------

func test_batches_repeat_the_last_four_inputs_by_default() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(20)
	var batches: Array[Dictionary] = await _collect_batches(40)
	assert_true(batches.size() >= 38, "one per physics tick (%d)" % batches.size())
	var first_real: int = _client.get_prediction().get_first_real_tick()
	var previous_newest: int = 0
	for entry: Dictionary in batches:
		var batch: NetMessages.InputBatch = entry["batch"]
		assert_eq(batch.inputs.size(), NetProtocol.INPUT_REDUNDANCY, "R = 4 with no ack or losses")
		assert_true(batch.inputs[0].tick >= first_real, "never before P0")
		assert_eq(batch.view_offsets_q.size(), 4)
		for i: int in batch.inputs.size():
			assert_eq(batch.inputs[i].tick, batch.newest_tick - batch.inputs.size() + 1 + i)
		var step: int = batch.newest_tick - previous_newest
		assert_true(previous_newest == 0 or (step >= 0 and step <= 2),
				"newest rises 0, 1 or 2 per tick (%d)" % step)
		previous_newest = batch.newest_tick
	var sent: int = _client.get_stats()["batches_sent"]
	assert_true(sent - _fake.batches.size() >= 0 and sent - _fake.batches.size() <= 2,
			"what was sent is what was received, except what is in transit (%d, %d)"
			% [sent, _fake.batches.size()])


func test_acknowledged_inputs_are_not_sent_again() -> void:
	await _start(func(fake: FakeServer) -> void: fake.follow_ack = true)
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(30)
	var counts: Array[int] = _counts_of(await _collect_batches(60))
	assert_false(counts.is_empty())
	assert_true(counts.max() <= 3, "with the ack up to date only the pending is resent: %s" % [counts])
	assert_true(counts.min() >= 1)


func test_a_rise_of_substitutions_widens_the_redundancy_for_two_seconds() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(30)
	assert_eq(_counts_of(await _collect_batches(10)).max(), 4)
	_fake.substitutions = 3
	var counts: Array[int] = _counts_of(await _collect_batches(30))
	assert_eq(counts.max(), 8, "R = 8 after a rise in substitutions: %s" % [counts])
	assert_eq(counts[counts.size() - 1], 8)
	assert_eq(_client.get_stats()["substitution_rises"], 1)
	assert_eq(_client.get_stats()["substitutions_total"], 3)
	await wait_physics_frames(110)
	counts = _counts_of(await _collect_batches(10))
	assert_eq(counts.max(), 4, "and after 120 ticks it goes back to R = 4")


func test_batch_header_has_ack_delay_and_view_offsets() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(120)
	var entries: Array[Dictionary] = _fake.batches_after_spawn()
	var early: NetMessages.InputBatch = entries[0]["batch"]
	assert_true(early.ack_snapshot_tick <= _fake.tick)
	assert_eq(early.view_offsets_q[0], 0, "without a draw clock, skew 0")
	var late: NetMessages.InputBatch = entries[entries.size() - 1]["batch"]
	assert_true(late.ack_snapshot_tick > 0 and late.ack_snapshot_tick <= _fake.tick,
			"ack = the newest snapshot received (%d)" % late.ack_snapshot_tick)
	assert_true(late.interp_delay_q >= 32 and late.interp_delay_q <= 96,
			"interpolation delay × 8 between 4 and 12 ticks (%d)" % late.interp_delay_q)
	for q: int in late.view_offsets_q:
		assert_true(q > 0 and q < 65535, "(tick - render_tick) × 16 (%d)" % q)
	var previous: int = 0
	for entry: Dictionary in entries:
		var ack: int = (entry["batch"] as NetMessages.InputBatch).ack_snapshot_tick
		assert_true(ack >= previous, "the ack does not go backwards")
		previous = ack


## The local character carries in its mask its realm's movement layer (the one stopped by the
## closed gates of foreign forts), set after its _ready().
func test_the_local_character_collides_with_the_layer_of_its_realm() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var character: PlayerCharacter = _client.get_character()
	assert_eq(character.collision_mask, PlayerCharacter.WORLD_COLLISION_LAYER
			| PlayerCharacter.PLAYER_BLOCKER_LAYER | PlayerCharacter.realm_layer(VARDHEIM),
			"world, invisible blockers and Vardheim's layer 5")


# --- Snapshots and reconciliation -------------------------------------------------------------

func test_out_of_order_snapshots_only_feed_the_interpolators() -> void:
	await _start(func(fake: FakeServer) -> void: fake.auto_snapshots = false)
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(10)
	var prediction: ClientPrediction = _client.get_prediction()
	var newer: int = _client.get_spawn_tick() + 6
	var older: int = _client.get_spawn_tick() + 3
	var before: Dictionary = _client.get_stats()
	_fake.send_snapshot(newer, prediction.get_predicted_state(newer).duplicate_state())
	_fake.send_snapshot(older, prediction.get_predicted_state(older).duplicate_state())
	await wait_physics_frames(4)
	var stats: Dictionary = _client.get_stats()
	assert_eq(stats["snapshots"], before["snapshots"] + 2, "both arrive")
	assert_eq(stats["snapshots_with_state"], before["snapshots_with_state"] + 1,
			"only the newest is reconciled")
	assert_eq(stats["late_snapshots"], before["late_snapshots"] + 1, "and the other is counted")
	assert_eq(stats["matches"], before["matches"] + 1)
	assert_eq(stats["server_tick"], newer)
	# One older than the one already reconciled, arriving later, is not either.
	_fake.send_snapshot(newer - 1, prediction.get_predicted_state(newer - 1).duplicate_state())
	await wait_physics_frames(4)
	assert_eq(_client.get_stats()["snapshots_with_state"], before["snapshots_with_state"] + 1)
	assert_eq(_client.get_stats()["late_snapshots"], before["late_snapshots"] + 2)


func test_differences_are_classified_as_explained_unexplained_teleport_or_hard_reset() -> void:
	await _start(func(fake: FakeServer) -> void: fake.auto_snapshots = false)
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(14)
	var prediction: ClientPrediction = _client.get_prediction()
	var spawn: int = _client.get_spawn_tick()
	var character: PlayerCharacter = _client.get_character()
	var visual: Node3D = character.get_node(^"Visual") as Node3D

	# 1. A difference with no rise in substitutions: prediction failure.
	var wrong: PlayerState = prediction.get_predicted_state(spawn + 2).duplicate_state()
	wrong.position.x += 0.5
	_fake.send_snapshot(spawn + 2, wrong)
	await wait_physics_frames(3)
	var stats: Dictionary = _client.get_stats()
	assert_eq(stats["diffs"], 1)
	assert_eq(stats["unexplained_diffs"], 1, "without a rise in substitutions there is no explanation")
	assert_eq(stats["explained_diffs"], 0)
	assert_eq(stats["corrections"], 1, "the correction is over 1 mm")
	assert_near(stats["max_correction"], 0.5, 0.05)
	assert_eq(stats["consecutive_matches"], 0)
	assert_eq(stats["unexplained_ticks"].size(), 1)
	assert_true(visual.position.length() > 0.05, "and the error is spread out as a visual skew")

	# 2. A difference with a rise in substitutions: explained.
	var substituted: PlayerState = prediction.get_predicted_state(spawn + 4).duplicate_state()
	substituted.position.z -= 0.3
	_fake.substitutions = 1
	_fake.send_snapshot(spawn + 4, substituted)
	await wait_physics_frames(3)
	stats = _client.get_stats()
	assert_eq(stats["diffs"], 2)
	assert_eq(stats["explained_diffs"], 1, "matches a rise in substitutions")
	assert_eq(stats["unexplained_diffs"], 1)

	# 3. A state identical to the predicted one: exact match.
	_fake.send_snapshot(spawn + 6, prediction.get_predicted_state(spawn + 6).duplicate_state())
	await wait_physics_frames(3)
	stats = _client.get_stats()
	assert_eq(stats["matches"], 1)
	assert_eq(stats["consecutive_matches"], 1)
	assert_eq(stats["diffs"], 2)

	# 4. A teleport (the counter changes): explained, without smoothing.
	var teleported: PlayerState = prediction.get_predicted_state(spawn + 8).duplicate_state()
	teleported.position = Vector3(20.0, 0.0, 10.0)
	_fake.send_snapshot(spawn + 8, teleported, 1)
	await wait_physics_frames(3)
	stats = _client.get_stats()
	assert_eq(stats["teleport_diffs"], 1)
	assert_eq(stats["explained_diffs"], 2)
	assert_eq(stats["unexplained_diffs"], 1)
	assert_eq(visual.position, Vector3.ZERO, "a teleport is not smoothed")
	assert_vec_near(character.get_state().position, Vector3(20.0, 0.0, 10.0), 2.0,
			"the body jumps to the server's position")

	# 5. A state ahead of the predicted one: hard reset.
	var ahead: int = prediction.get_predicted_tick() + 10
	var reset_state: PlayerState = teleported.duplicate_state()
	reset_state.position = Vector3(5.0, 0.0, 5.0)
	_fake.send_snapshot(ahead, reset_state, 1)
	await wait_physics_frames(3)
	stats = _client.get_stats()
	assert_eq(stats["hard_resets"], 1)
	assert_eq(stats["hard_reset_ticks"].size(), 1)
	assert_true(prediction.get_predicted_tick() >= ahead, "the prediction resumes from there")


func test_resync_counter_follows_tick_sync_hard_jumps() -> void:
	# A server that says inputs arrive 20 ticks late forces TickSync to jump forward
	# at once: it is counted as a resynchronisation.
	await _start(func(fake: FakeServer) -> void: fake.margin = -20)
	assert_true(await _wait_until(_in_world))
	assert_true(await _wait_until(func() -> bool: return _client.get_stats()["resyncs"] > 0),
			"there is a hard forward resynchronisation")
	var stats: Dictionary = _client.get_stats()
	assert_true(stats["tick_sync_adjustments"] >= 1)
	assert_eq(stats["resync_ticks"].size(), stats["resyncs"])


# --- NOTICE, exit and failures ----------------------------------------------------------------

func test_notice_text_becomes_the_disconnect_text() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var notices: Array[Dictionary] = []
	_client.notice_received.connect(func(code: int, text: String) -> void:
		notices.append({"code": code, "text": text}))
	var texts: Array[String] = []
	_client.disconnected.connect(func(text: String) -> void: texts.append(text))
	_fake.send_notice(NetProtocol.NoticeCode.KICK, "Expulsado del servidor: prueba")
	_fake.transport.disconnect_after_flush(_fake.peer_id)
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty()))
	assert_eq(notices.size(), 1)
	assert_eq(notices[0]["code"], NetProtocol.NoticeCode.KICK)
	assert_eq(texts[0], "Expulsado del servidor: prueba")
	assert_eq(_client.get_state(), NetClient.State.CLOSED)
	assert_eq(texts.size(), 1)
	assert_eq(_client.get_last_notice_text(), "Expulsado del servidor: prueba")


func test_losing_the_server_without_a_notice_has_a_generic_text() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var texts: Array[String] = []
	_client.disconnected.connect(func(text: String) -> void: texts.append(text))
	_fake.transport.disconnect_after_flush(_fake.peer_id)
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty()))
	assert_eq(texts[0], NetClient.TEXT_CONNECTION_LOST)


func test_leave_sends_client_leave_and_stops_sending_inputs() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(20)
	var texts: Array[String] = []
	_client.disconnected.connect(func(text: String) -> void: texts.append(text))
	_client.leave()
	assert_eq(_client.get_state(), NetClient.State.LEAVING)
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty()))
	assert_true(_fake.leave_received, "the server receives CLIENT_LEAVE")
	assert_eq(texts[0], NetClient.TEXT_LEFT)
	assert_eq(_client.get_state(), NetClient.State.CLOSED)
	var sent: int = _fake.batches.size()
	await wait_physics_frames(20)
	assert_eq(_fake.batches.size(), sent, "after leaving nothing more is sent")
	_client.leave()
	assert_eq(texts.size(), 1, "and leaving twice does not notify twice")


func test_tick_rate_mismatch_aborts_the_connection() -> void:
	await _start(func(fake: FakeServer) -> void: fake.tick_rate = 30)
	var welcomed: Array[bool] = []
	_client.welcomed.connect(func(_welcome: NetMessages.Welcome) -> void: welcomed.append(true))
	var texts: Array[String] = []
	_client.disconnected.connect(func(text: String) -> void: texts.append(text))
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty()))
	assert_eq(texts[0], NetClient.TEXT_BAD_TICK_RATE % [30, Engine.physics_ticks_per_second])
	assert_true(welcomed.is_empty(), "it does not get to authenticate")
	assert_eq(_fake.ready_count, 0)
	assert_eq(_client.get_state(), NetClient.State.CLOSED)


func test_protocol_version_mismatch_in_welcome_aborts_the_connection() -> void:
	await _start(func(fake: FakeServer) -> void: fake.welcome_version = 99)
	var texts: Array[String] = []
	_client.disconnected.connect(func(text: String) -> void: texts.append(text))
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty()))
	assert_eq(texts[0], NetClient.TEXT_BAD_VERSION)
	assert_eq(_fake.ready_count, 0)


func test_connection_failure_is_reported_once() -> void:
	_port = NetHarness.free_udp_port()
	_viewport = NetHarness.make_world_viewport(_root, "")
	_client = NetHarness.start_bot(_viewport, _port, VARDHEIM, 9)
	var texts: Array[String] = []
	_client.disconnected.connect(func(text: String) -> void: texts.append(text))
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty(), 900),
			"without a server, the client gives up")
	assert_eq(texts[0], NetClient.TEXT_CONNECT_FAILED % ["127.0.0.1", _port])
	assert_eq(_client.get_state(), NetClient.State.CLOSED)
	await wait_physics_frames(30)
	assert_eq(texts.size(), 1)


func test_garbage_from_the_server_is_counted_not_fatal() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, PackedByteArray([0x7F, 1, 2]))
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_SNAPSHOT, PackedByteArray([0x10, 1, 2]))
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, PackedByteArray([0x20, 0, 0]))
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, PackedByteArray([0x21]))
	await wait_physics_frames(10)
	assert_eq(_client.get_stats()["malformed_packets"], 4)
	assert_eq(_client.get_state(), NetClient.State.IN_WORLD, "the client is still in the world")


func test_chat_messages_reach_the_signal_and_chat_sends_reach_the_server() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var received: Array[NetMessages.ChatMessage] = []
	_client.chat_received.connect(func(message: NetMessages.ChatMessage) -> void:
		received.append(message))
	var line := NetMessages.ChatMessage.new()
	line.channel = ChatChannel.Id.ZONE
	line.sender_realm = VARDHEIM
	line.tick = _fake.tick
	line.sender = "Ana"
	line.text = "Hola desde el servidor"
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, line.encode())
	var system := NetMessages.ChatMessage.new()
	system.channel = ChatChannel.Id.SYSTEM
	system.text = "Aviso del sistema"
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, system.encode())
	# A malformed CHAT_MESSAGE counts as a malformed packet and does not reach the signal.
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, PackedByteArray([0x41, 0, 0, 0]))
	assert_true(await _wait_until(func() -> bool: return received.size() >= 2), "both arrive")
	await wait_physics_frames(10)
	assert_eq(received.size(), 2, "only the valid ones")
	assert_eq(received[0].sender, "Ana", "sender")
	assert_eq(received[0].text, "Hola desde el servidor", "text")
	assert_eq(received[1].channel, ChatChannel.Id.SYSTEM, "the system's too")
	var stats: Dictionary = _client.get_stats()
	assert_eq(stats["chat_received"], 2, "two received")
	assert_eq(stats["malformed_packets"], 1, "one malformed")
	# Sending: the CHAT_SEND reaches the fake server sanitised and over the reliable channel.
	assert_true(_client.send_chat(ChatChannel.Id.WHISPER, " Bruno ", "[b]Hola[/b]  Bruno"), "it is sent")
	assert_false(_client.send_chat(ChatChannel.Id.SAY, "", "  "), "an empty text does not go out")
	assert_true(await _wait_until(func() -> bool: return not _fake.chat_sends.is_empty()),
			"the fake server receives the CHAT_SEND")
	assert_eq(_fake.chat_sends.size(), 1, "only one")
	assert_eq(_fake.chat_sends[0].channel, ChatChannel.Id.WHISPER, "whisper channel")
	assert_eq(_fake.chat_sends[0].recipient, "Bruno", "recipient without spaces")
	assert_eq(_fake.chat_sends[0].text, "Hola Bruno", "text sanitised on the client")
	assert_eq(_client.get_stats()["chat_sent"], 1, "only one was sent")


func test_protocol_3_messages_are_accepted_and_not_counted_as_malformed() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var def: FortressDefinition = load("res://data/fortresses/vado_gris.tres") as FortressDefinition
	var state := FortressState.initial(def, 0)
	var send: Callable = func(bytes: PackedByteArray) -> void:
		_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, bytes)
	# The fortress SPAWN, two OBJECT_STATEs, the scoreboard and the two new alerts.
	send.call(NetMessages.EntitySpawn.for_fortress(900, _fake.tick, "vado_gris_fort", state).encode())
	send.call(NetMessages.ObjectState.from_fortress(900, _fake.tick, state).encode())
	var changes := NetMessages.ObjectState.new()
	changes.net_id = 900
	changes.tick = _fake.tick + 6
	changes.add_field(FortressFields.OWNER, NetMessages.ObjectField.ValueType.U8, 1)
	changes.add_field(250, NetMessages.ObjectField.ValueType.U16, 7)
	send.call(changes.encode())
	var board := NetMessages.Scoreboard.new()
	board.rows.append(NetMessages.ScoreRow.make(5, 1, 2, 3, 400, 50, 600))
	send.call(board.encode())
	send.call(NetMessages.EntityEvent.war(900, _fake.tick, WarEvents.CAPTURE_STARTED, 1).encode())
	send.call(NetMessages.EntityEvent.telegraph(901, _fake.tick, 3, NetMessages.EntityEvent.SHAPE_SECTOR,
			Vector3(4.0, 0.0, 4.0), 0.5, 400, 40).encode())
	# An NPC with its definition id is drawn like any remote.
	var npc := NetMessages.EntitySpawn.new()
	npc.net_id = 902
	npc.kind = NetProtocol.EntityKind.NPC
	npc.spawn_tick = _fake.tick
	npc.state = PlayerState.new()
	npc.state.position = Vector3(5.0, 0.0, 5.0)
	npc.display_name = "Hueco"
	npc.npc_def_id = 2
	send.call(npc.encode())
	assert_true(await _wait_until(func() -> bool:
		return _client.get_remote_world().get_view(902) != null), "the NPC's SPAWN creates its view")
	await wait_physics_frames(10)
	var stats: Dictionary = _client.get_stats()
	assert_eq(stats["malformed_packets"], 0, "none of the new messages counts as malformed")
	assert_eq(stats["structure_spawns"], 1, "the structure's SPAWN")
	assert_eq(stats["object_states"], 2, "the OBJECT_STATEs")
	assert_eq(stats["scoreboards"], 1, "the scoreboard")
	assert_eq(stats["war_events"], 1, "the war alert")
	assert_eq(stats["telegraphs"], 1, "the attack alert")
	assert_eq(stats["combat_events"], 0, "the new alerts are not combat events")
	assert_eq(stats["combat_events_pending"], 0, "nor do they wait in the combat queue")
	assert_eq(stats["remote_views"], 1, "only the NPC has a view: the structure is not drawn yet (F5)")
	assert_eq(_client.get_state(), NetClient.State.IN_WORLD, "the client is still in the world")
	# Malformed instances of the new types do count.
	send.call(PackedByteArray([NetProtocol.MSG_OBJECT_STATE, 1, 0, 0, 0, 0, 0, 0]))
	send.call(PackedByteArray([NetProtocol.MSG_SCOREBOARD, 0, 0, 0]))
	await wait_physics_frames(10)
	assert_eq(_client.get_stats()["malformed_packets"], 2, "an OBJECT_STATE without fields and a scoreboard without pages")


func test_the_fortress_flows_to_the_view_and_the_prediction_asks_for_the_gate() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var def: FortressDefinition = load("res://data/fortresses/vado_gris.tres") as FortressDefinition
	var view: FortressView = _client.get_fortress_view()
	assert_false(view.has_fortress(900), "before the SPAWN there is no fortress")
	var hook_calls: int = int(_client.get_stats()["fortress_hook_calls"])
	assert_true(hook_calls > 0, "the prediction already asks about the gate on every simulated tick (%d)" % hook_calls)
	var spawn_tick: int = _fake.tick
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE,
			NetMessages.EntitySpawn.for_fortress(900, spawn_tick, "vado_gris_fort",
			FortressState.initial(def, spawn_tick)).encode())
	assert_true(await _wait_until(func() -> bool: return view.has_fortress(900)), "the SPAWN creates the fortress")
	assert_eq(view.get_definition_id(900), "vado_gris_fort")
	# An owner change with a tick somewhat ahead: it is recorded at once, but shown when reached.
	var change_tick: int = _fake.tick + 40
	var change := NetMessages.ObjectState.new()
	change.net_id = 900
	change.tick = change_tick
	change.add_field(FortressFields.OWNER, NetMessages.ObjectField.ValueType.U8, 2)
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, change.encode())
	assert_true(await _wait_until(func() -> bool:
		return view.get_latest_state(900) != null and view.get_latest_state(900).owner == 2),
			"the change is recorded on arrival")
	var clock: InterpolationClock = _client.get_interpolation_clock()
	assert_true(clock.get_render_tick() < float(change_tick), "but the draw tick has not reached it yet")
	assert_true(view.get_displayed_state(900) == null or view.get_displayed_state(900).owner == 0,
			"and the interface keeps showing the previous state")
	assert_true(await _wait_until(func() -> bool:
		return view.get_displayed_state(900) != null and view.get_displayed_state(900).owner == 2),
			"when the draw tick reaches it, it is shown")
	assert_true(clock.get_render_tick() >= float(change_tick), "and not before (render_tick %.1f)" % clock.get_render_tick())
	assert_eq(_client.get_stats()["malformed_packets"], 0)


func test_war_events_wait_for_the_draw_tick_and_telegraphs_arrive_at_once() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var wars: Array[NetMessages.EntityEvent] = []
	var telegraphs: Array[NetMessages.EntityEvent] = []
	_client.war_event.connect(func(event: NetMessages.EntityEvent) -> void: wars.append(event))
	_client.telegraph_received.connect(func(event: NetMessages.EntityEvent) -> void: telegraphs.append(event))
	var war_tick: int = _fake.tick + 40
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE,
			NetMessages.EntityEvent.war(900, war_tick, WarEvents.FORT_CAPTURED, 2).encode())
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE,
			NetMessages.EntityEvent.telegraph(901, war_tick, 3, NetMessages.EntityEvent.SHAPE_CIRCLE,
			Vector3(1.0, 0.0, 2.0), 0.0, 250, 30).encode())
	assert_true(await _wait_until(func() -> bool: return telegraphs.size() == 1),
			"the TELEGRAPH is delivered on arrival")
	assert_eq(telegraphs[0].impact_in_ticks, 30)
	assert_true(wars.is_empty(), "the war alert waits for its draw tick")
	assert_eq(_client.get_stats()["war_events_pending"], 1)
	var clock: InterpolationClock = _client.get_interpolation_clock()
	assert_true(await _wait_until(func() -> bool: return wars.size() == 1), "and is then delivered")
	assert_true(clock.get_render_tick() >= float(war_tick), "not before its tick")
	assert_eq(wars[0].war_event, WarEvents.FORT_CAPTURED)
	assert_eq(wars[0].war_realm, 2)
	await wait_physics_frames(20)
	assert_eq(wars.size(), 1, "only once")
	assert_eq(_client.get_stats()["war_events_pending"], 0)
	assert_eq(_client.get_stats()["combat_events"], 0, "they are not combat events")


func test_scoreboard_pages_are_joined_and_names_come_from_the_spawns() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var boards: Array[int] = []
	_client.scoreboard_updated.connect(func(board: ScoreboardState) -> void: boards.append(board.get_row_count()))
	var other := NetMessages.EntitySpawn.new()
	other.net_id = 77
	other.spawn_tick = _fake.tick
	other.realm = NetProtocol.Realm.SOLMARCH
	other.state = PlayerState.new()
	other.display_name = "Brenna"
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, other.encode())
	var all_rows: Array[NetMessages.ScoreRow] = []
	for i: int in 70:
		all_rows.append(NetMessages.ScoreRow.make(100 + i, i, 1, 2, 3, 4, 5))
	var pages: Array[NetMessages.Scoreboard] = NetMessages.Scoreboard.split(all_rows)
	assert_eq(pages.size(), 2, "70 players fit in two pages")
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, pages[0].encode())
	await wait_physics_frames(10)
	assert_true(boards.is_empty(), "with a single page the scoreboard is not complete")
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, pages[1].encode())
	assert_true(await _wait_until(func() -> bool: return boards.size() == 1), "with the second it is published")
	assert_eq(boards[0], 70)
	assert_eq(_client.get_scoreboard().get_row(150).kills, 50)
	assert_true(await _wait_until(func() -> bool: return _client.get_directory().knows(77)))
	assert_eq(_client.get_directory().name_of(77), "Brenna")
	assert_eq(_client.get_directory().realm_of(77), NetProtocol.Realm.SOLMARCH)
	assert_eq(_client.get_directory().name_of(5), _client.get_config().display_name, "the setting's own name")
	assert_eq(_client.get_directory().name_of(4242), "Jugador 4242", "whoever has not been seen")


func test_remote_entities_flow_to_the_remote_world() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var other := NetMessages.EntitySpawn.new()
	other.net_id = 77
	other.spawn_tick = _fake.tick
	other.realm = NetProtocol.Realm.SOLMARCH
	other.state = PlayerState.new()
	other.state.position = Vector3(3.0, 0.0, 3.0)
	other.display_name = "Otro"
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, other.encode())
	assert_true(await _wait_until(func() -> bool:
		return _client.get_remote_world().get_view(77) != null), "the other player's SPAWN creates their view")
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = 77
	despawn.despawn_tick = _fake.tick + 4
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, despawn.encode())
	assert_true(await _wait_until(func() -> bool:
		return _client.get_remote_world().get_view(77) == null), "and the DESPAWN removes it")
	assert_eq(_client.get_character().get_parent(), _client.get_meta(&"entities"),
			"the local character hangs from the node passed to notify_zone_ready")
	assert_eq(_client.get_remote_world().get_parent(), _client.get_meta(&"entities"))


# --- Protocol 6 -------------------------------------------------------------------------------

func test_protocol_6_projectiles_go_by_kind_and_new_events_are_timed_like_combat() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var own_id: int = _client.get_net_id()
	var character: PlayerCharacter = _client.get_character()
	var spawned: Array[NetMessages.EntitySpawn] = []
	var despawned: Array[Vector3i] = []
	var events: Array[Array] = []
	_client.projectile_spawned.connect(func(spawn: NetMessages.EntitySpawn) -> void: spawned.append(spawn))
	_client.projectile_despawned.connect(func(id: int, tick: int, reason: int) -> void:
		despawned.append(Vector3i(id, tick, reason)))
	_client.combat_event.connect(func(event: NetMessages.EntityEvent, is_own: bool) -> void:
		events.append([event.event, is_own]))
	var send: Callable = func(bytes: PackedByteArray) -> void:
		_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, bytes)
	# One own arrow (owner = the local net_id) and one foreign: neither is a character.
	var arrow: int = CombatCatalog.projectile_id(&"arrow")
	send.call(NetMessages.EntitySpawn.for_projectile(600, _fake.tick, VARDHEIM, own_id, arrow,
			CombatCatalog.attack_id(&"bow_quick"), 0, false, Vector3(1.0, 1.4, 0.0),
			Vector3(0.0, 0.0, 45.0)).encode())
	send.call(NetMessages.EntitySpawn.for_projectile(601, _fake.tick, NetProtocol.Realm.SOLMARCH, 77,
			arrow, CombatCatalog.attack_id(&"bow_quick"), 0, true, Vector3(5.0, 1.4, 0.0),
			Vector3(0.0, 0.0, -45.0)).encode())
	assert_true(await _wait_until(func() -> bool: return spawned.size() == 2), "the two projectile SPAWNs")
	assert_eq(spawned[0].owner_id, own_id, "the own one carries the local net_id as owner")
	assert_false(spawned[0].is_yours, "although it is never \"yours\" in the header")
	assert_true(spawned[1].is_harmless(), "the foreign one arrives harmless")
	assert_eq(_client.get_character(), character, "the local character does not change")
	assert_eq(_client.get_remote_world().get_view_count(), 0, "nor do they create remote views")
	assert_eq(_client.get_stats()["projectile_spawns"], 2)
	# Their DESPAWNs come out through their own signal with the tick and the reason.
	var impact := NetMessages.EntityDespawn.new()
	impact.net_id = 600
	impact.despawn_tick = _fake.tick + 20
	impact.reason = NetProtocol.DespawnReason.IMPACT
	send.call(impact.encode())
	var expired := NetMessages.EntityDespawn.new()
	expired.net_id = 601
	expired.despawn_tick = _fake.tick + 120
	expired.reason = NetProtocol.DespawnReason.EXPIRED
	send.call(expired.encode())
	assert_true(await _wait_until(func() -> bool: return despawned.size() == 2), "the two DESPAWNs")
	assert_eq(despawned[0], Vector3i(600, impact.despawn_tick, NetProtocol.DespawnReason.IMPACT), "impact")
	assert_eq(despawned[1], Vector3i(601, expired.despawn_tick, NetProtocol.DespawnReason.EXPIRED), "expired")
	# New events: the own STATUS and LOADOUT arrive at once; another player's DOWNED waits for its draw tick.
	var slowed: int = CombatCatalog.status_id(&"slowed")
	send.call(NetMessages.EntityEvent.status(own_id, _fake.tick, 77, NetMessages.EntityEvent.StatusOp.APPLIED,
			slowed, 1, _fake.tick + 180).encode())
	send.call(NetMessages.EntityEvent.loadout(own_id, _fake.tick, CombatCatalog.template_id(&"marksman"),
			CombatCatalog.weapon_id(&"bow"), CombatCatalog.weapon_id(&"sword_shield"), 0x32).encode())
	var downed_tick: int = _fake.tick + 40
	send.call(NetMessages.EntityEvent.downed(88, downed_tick, 77, CombatSource.make(CombatSource.Kind.ABILITY,
			CombatCatalog.ability_id(&"shield_bash"))).encode())
	assert_true(await _wait_until(func() -> bool: return events.size() >= 2), "the own ones arrive")
	assert_eq(events[0], [NetMessages.EntityEvent.Kind.STATUS, true], "own STATUS, on arrival")
	assert_eq(events[1], [NetMessages.EntityEvent.Kind.LOADOUT, true], "own LOADOUT, on arrival")
	assert_eq(events.size(), 2, "the other player's DOWNED still waits")
	var clock: InterpolationClock = _client.get_interpolation_clock()
	assert_true(await _wait_until(func() -> bool: return events.size() == 3), "and is then delivered")
	assert_eq(events[2], [NetMessages.EntityEvent.Kind.DOWNED, false], "other player's DOWNED")
	assert_true(clock.get_render_tick() >= float(downed_tick), "not before its tick")
	assert_eq(_client.get_stats()["malformed_packets"], 0, "nothing from protocol 6 counts as malformed")
	assert_eq(_client.get_state(), NetClient.State.IN_WORLD, "the client is still in the world")
	# An id that belonged to an arrow can come back as an entity (they share the id space) and goes to the remote world.
	var other := NetMessages.EntitySpawn.new()
	other.net_id = 600
	other.spawn_tick = _fake.tick
	other.realm = NetProtocol.Realm.SOLMARCH
	other.state = PlayerState.new()
	other.display_name = "Otro"
	send.call(other.encode())
	assert_true(await _wait_until(func() -> bool:
		return _client.get_remote_world().get_view(600) != null), "the reused id creates its view")


## Phase 4 review ("abilities" lens): a remote's [StatusTracker] follows the server's tick order even when
## mixing foreign events (which wait for their draw tick) and own ones (whose signal goes out on
## arrival). Before, an ally's foreign STATUS 2 for the slow's expiry (tick t) was delivered
## after the own STATUS 1 with which the local player put it back at t + 2 and erased the new
## effect from the nameplate; and on a STACK renewal, the old foreign one overwrote the new own one (1 stack instead of 2).
func test_a_remote_status_tracker_follows_the_server_order_of_own_and_foreign_events() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var clock: InterpolationClock = _client.get_interpolation_clock()
	assert_true(await _wait_until(func() -> bool: return clock.get_render_tick() > 0.0), "the draw clock runs")
	var own_id: int = _client.get_net_id()
	var remote: int = 88
	var events: Array[Array] = []
	_client.combat_event.connect(func(event: NetMessages.EntityEvent, is_own: bool) -> void:
		events.append([event.status_id, event.source_entity, is_own]))
	var send: Callable = func(event: NetMessages.EntityEvent) -> void:
		_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, event.encode())
	var slowed: int = CombatCatalog.status_id(&"slowed")
	var bleed: int = CombatCatalog.status_id(&"bleed")
	var applied: int = NetMessages.EntityEvent.StatusOp.APPLIED
	var t: int = _fake.tick + 40
	# Ally 77's slow expires at t and the local player puts it back at t + 2.
	send.call(NetMessages.EntityEvent.status(remote, t, 77, NetMessages.EntityEvent.StatusOp.REMOVED, slowed,
			0, t))
	send.call(NetMessages.EntityEvent.status(remote, t + 2, own_id, applied, slowed, 1, t + 182))
	# The ally bleeds the remote at t and the local player renews it at t + 2 (two stacks).
	send.call(NetMessages.EntityEvent.status(remote, t, 77, applied, bleed, 1, t + 360))
	send.call(NetMessages.EntityEvent.status(remote, t + 2, own_id, applied, bleed, 2, t + 362))
	assert_true(await _wait_until(func() -> bool: return events.size() >= 2), "the own ones arrive")
	assert_eq(events, [[slowed, own_id, true], [bleed, own_id, true]], "the own ones' signal goes out on arrival")
	assert_true(clock.get_render_tick() < float(t), "before draw tick t")
	assert_null(_client.get_status_tracker(remote), "the remote's tracker receives them at its draw tick")
	assert_true(await _wait_until(func() -> bool: return clock.get_render_tick() >= float(t + 2), 300),
			"the draw tick goes past t + 2")
	await wait_physics_frames(2)
	assert_eq(events.size(), 4, "and then the two foreign ones go out")
	var tracker: StatusTracker = _client.get_status_tracker(remote)
	if assert_not_null(tracker, "the remote has a tracker"):
		var slow: StatusTracker.Entry = tracker.get_entry(slowed)
		if assert_not_null(slow, "the slow the local player applied stays on the nameplate"):
			assert_eq([slow.until_tick, slow.source_entity], [t + 182, own_id])
		var bleeding: StatusTracker.Entry = tracker.get_entry(bleed)
		if assert_not_null(bleeding, "the bleed too"):
			assert_eq([bleeding.stacks, bleeding.until_tick, bleeding.source_entity], [2, t + 362, own_id],
					"with the own renewal, the newest")
	assert_eq(_client.get_stats()["combat_events_pending"], 0, "nothing is left in the queue")


func test_the_chosen_template_goes_in_a_loadout_select_right_after_the_welcome() -> void:
	await _start()
	# The template chosen before connecting (realm choice or --loadout).
	_client.get_config().loadout = "marksman"
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(4)
	var marksman: int = CombatCatalog.template_id(&"marksman")
	assert_eq(_fake.loadout_selects.size(), 1, "a LOADOUT_SELECT")
	assert_eq(int(_fake.loadout_selects[0]["template"]), marksman, "with the marksman's id")
	assert_eq(int(_fake.loadout_selects[0]["ready_count"]), 0, "before the CLIENT_READY (valid already on load)")
	# From the death screen: another, which is also remembered for the next connection.
	var squire: int = CombatCatalog.template_id(&"squire")
	assert_true(_client.send_loadout_select(squire))
	assert_eq(_client.get_config().loadout, "squire")
	assert_false(_client.send_loadout_select(250), "an id that is not a template does not go out")
	assert_true(await _wait_until(func() -> bool: return _fake.loadout_selects.size() == 2))
	assert_eq(int(_fake.loadout_selects[1]["template"]), squire)
	assert_eq(_client.get_stats()["loadout_selects"], 2)


func test_protocol_6_own_events_explain_corrections() -> void:
	var client := NetClient.new()
	_root.add_child(client)
	client._net_id = 5
	var slowed: int = CombatCatalog.status_id(&"slowed")
	var bleed: int = CombatCatalog.status_id(&"bleed")
	var cases: Array[Array] = [
		# event, does it explain?, text
		[NetMessages.EntityEvent.status(5, 100, 9, 1, slowed, 1, 280), true, "una ralentización sobre uno mismo"],
		[NetMessages.EntityEvent.status(5, 200, 9, 1, bleed, 1, 560), false, "un sangrado no toca la simulación"],
		[NetMessages.EntityEvent.status(7, 300, 5, 1, slowed, 1, 480), false, "ralentizar a otro no"],
		[NetMessages.EntityEvent.downed(5, 400, 9, 0), true, "el derribo propio"],
		[NetMessages.EntityEvent.downed(7, 500, 5, 0), false, "derribar a otro no"],
		[NetMessages.EntityEvent.interact(7, 600, 5, 1, 780), true, "levantar a otro (el servidor empieza REVIVE)"],
		[NetMessages.EntityEvent.interact(5, 700, 9, 4, 760), true, "que le rematen a uno"],
		[NetMessages.EntityEvent.interact(7, 800, 9, 1, 980), false, "lo que hacen otros, no"],
		[NetMessages.EntityEvent.loadout(5, 900, 1, 1, 0, 0x23), true, "el LOADOUT propio"],
		[NetMessages.EntityEvent.loadout(7, 1000, 1, 1, 0, 0), false, "el ajeno no"],
		[NetMessages.EntityEvent.hit(5, 1100, 9, 30, 0, NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED, 1), true,
				"un golpe que interrumpe"],
	]
	for row: Array in cases:
		var event: NetMessages.EntityEvent = row[0]
		client._note_imposed_state(event)
		assert_eq(client._is_imposed_at(event.tick + 2), bool(row[1]), str(row[2]))
	client.free()
