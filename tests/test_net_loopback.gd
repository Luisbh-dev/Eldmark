extends TestCase
## Network integration in a single process, with real ENet over 127.0.0.1 (docs/networking.md, section 16,
## "Integration in one process"; milestones M2 and M3).
## [br][br]
## A [ZoneServer] and several bot [NetClient]s, each in its own [SubViewport] with its own physics
## world and its own [NetTransport] (with its [SceneMultiplayer]). The zone is the flat ground of
## [ZoneFixture], so that each test lasts under 30 s. One method per scenario:
## [br]- a) correct handshake, and REJECT by version, realm and simulation fingerprint;
## [br]- b) SPAWN and DESPAWN on connecting and disconnecting (CLIENT_LEAVE and drop);
## [br]- c) without a network simulator: 0 corrections from tick 60, and each bot draws the others
## within 0.5 m of [method StateHistory.sample] at its draw tick;
## [br]- d) with [NetSim] on the bots (rtt 150 ms, jitter 30 ms, loss 10 %): input lead time
## in steady state, late inputs, corrections explained by substitutions, exact convergence
## on standing still and no hard resynchronisation after startup;
## [br]- e) teleport DEBUG_COMMAND: the client jumps without smoothing and ends up exact.
## [br]The runner fails on any engine error, so all the tests also check
## that nothing is sent before [signal NetTransport.peer_connected] and that nothing odd
## is logged when connecting, rejecting or dropping.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
## Physics frames at most to wait for a condition (10 s).
const WAIT_FRAMES: int = 600

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _port: int = 0
var _clients: Array[NetClient] = []
var _client_viewports: Array[SubViewport] = []


func before_each() -> void:
	_root = Node.new()
	_root.name = "NetLoopback"
	tree.root.add_child(_root)


func after_each() -> void:
	# Clients first (they close their transport), then the server.
	for viewport: SubViewport in _client_viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_client_viewports.clear()
	_clients.clear()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

## Server with the flat zone listening on a free port. [param configure] receives the
## [ServerConfig] before starting.
func _start_server(configure: Callable = Callable()) -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	if configure.is_valid():
		configure.call(config)
	_server = NetHarness.start_server(_server_viewport, config)
	# The collision bodies enter the physics space in the first steps.
	await wait_physics_frames(3)


func _add_bot(realm: int, bot_seed: int, net_sim_spec: String = "") -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
	_client_viewports.append(viewport)
	var client: NetClient = NetHarness.start_bot(viewport, _port, realm, bot_seed, net_sim_spec)
	_clients.append(client)
	return client


## Waits, physics frame by physics frame, until [param condition] is met.
func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _all_in_world() -> bool:
	for client: NetClient in _clients:
		if client.get_state() != NetClient.State.IN_WORLD:
			return false
	return true


## How many remotes each client draws.
func _all_see_the_others() -> bool:
	for client: NetClient in _clients:
		if client.get_remote_world().get_view_count() != _clients.size() - 1:
			return false
	return true


## Server position of the player with that net_id (infinite if it does not exist).
func _server_position(net_id: int) -> Vector3:
	var entity: NetEntity = _server.get_registry().get_entity(net_id)
	if entity == null:
		return Vector3(INF, INF, INF)
	return entity.get_position()


# --- a) Handshake -----------------------------------------------------------------------------

func test_a_handshake_brings_the_player_into_the_world() -> void:
	await _start_server()
	var client: NetClient = _add_bot(VARDHEIM, 1)
	var welcomes: Array[NetMessages.Welcome] = []
	client.welcomed.connect(func(welcome: NetMessages.Welcome) -> void: welcomes.append(welcome))
	var spawned: Array[PlayerCharacter] = []
	client.local_spawned.connect(func(character: PlayerCharacter) -> void:
		spawned.append(character))
	assert_true(await _wait_until(_all_in_world), "the bot enters the world")
	assert_eq(welcomes.size(), 1, "welcomed is emitted once")
	assert_eq(spawned.size(), 1, "local_spawned is emitted once")
	assert_eq(welcomes[0].zone_id, ZONE_ID)
	assert_eq(welcomes[0].realm, VARDHEIM)
	assert_eq(welcomes[0].tick_rate, Engine.physics_ticks_per_second)
	assert_eq(_server.get_player_count(), 1)

	var net_id: int = client.get_net_id()
	assert_true(net_id > 0, "the own SPAWN gives the net_id")
	assert_not_null(_server.get_registry().get_entity(net_id), "and the server knows it")
	assert_true(client.get_character() == spawned[0])
	assert_true(client.get_prediction().is_started())
	assert_eq(client.get_prediction().get_first_real_tick(),
			client.get_spawn_tick() + client.get_rtt_ticks() + TickSync.MIN_TARGET + 1,
			"P0 = S + rtt + target margin + 1")
	assert_false(client.get_controller().auto_step, "the prediction advances the controller")
	assert_true(client.get_rtt_ticks() >= 0 and client.get_rtt_ticks() <= 6,
			"the RTT measured on loopback is a few ticks (%d)" % client.get_rtt_ticks())
	# It appears at a point of its realm, facing where the point faces.
	var spawn_position: Vector3 = ZoneFixture.VARDHEIM_SPAWNS[0]
	assert_vec_near(client.get_character().global_position, spawn_position, 2.0)

	await wait_physics_frames(120)
	var stats: Dictionary = client.get_stats()
	assert_true(stats["snapshots"] > 30, "snapshots arrive: %d" % stats["snapshots"])
	assert_true(stats["matches"] > 20, "and they match the prediction: %d" % stats["matches"])
	assert_eq(stats["malformed_packets"], 0)


func test_a_protocol_version_mismatch_is_rejected() -> void:
	await _start_server()
	var client: NetClient = _add_bot(VARDHEIM, 1)
	client.hello_hook = func(hello: NetMessages.Hello) -> void: hello.protocol_version += 1
	await _expect_rejection(client, NetProtocol.Result.VERSION)


func test_a_simulation_hash_mismatch_is_rejected() -> void:
	await _start_server()
	var client: NetClient = _add_bot(VARDHEIM, 1)
	client.hello_hook = func(hello: NetMessages.Hello) -> void: hello.sim_hash ^= 0x5A5A5A5A
	await _expect_rejection(client, NetProtocol.Result.SIM_HASH)


func test_a_missing_realm_is_rejected() -> void:
	await _start_server()
	var client: NetClient = _add_bot(NetProtocol.Realm.NONE, 1)
	await _expect_rejection(client, NetProtocol.Result.REALM)


## The client receives the REJECT in Spanish, neither enters the world nor leaves anything on the server, and
## after being rejected does not warn of a disconnection again.
func _expect_rejection(client: NetClient, expected_result: int) -> void:
	var rejections: Array[Dictionary] = []
	client.rejected.connect(func(result: int, text: String) -> void:
		rejections.append({"result": result, "text": text}))
	var disconnections: Array[String] = []
	client.disconnected.connect(func(text: String) -> void: disconnections.append(text))
	var welcomed: Array[bool] = []
	client.welcomed.connect(func(_welcome: NetMessages.Welcome) -> void: welcomed.append(true))
	assert_true(await _wait_until(func() -> bool: return not rejections.is_empty()),
			"the REJECT arrives")
	if rejections.is_empty():
		return
	assert_eq(rejections[0]["result"], expected_result)
	assert_eq(rejections[0]["text"], NetProtocol.result_text(expected_result),
			"the text is in Spanish")
	assert_eq(client.get_state(), NetClient.State.CLOSED)
	assert_true(welcomed.is_empty(), "there is no WELCOME")
	assert_null(client.get_character(), "there is no character")
	await wait_physics_frames(60)
	assert_true(disconnections.is_empty(), "after a REJECT no disconnection is notified")
	assert_eq(_server.get_player_count(), 0, "the server leaves nobody inside")
	assert_eq(rejections.size(), 1, "and the REJECT is notified only once")


# --- b) Joins and leaves ----------------------------------------------------------------------

func test_b_spawn_and_despawn_on_connect_leave_and_cut() -> void:
	await _start_server()
	var first: NetClient = _add_bot(VARDHEIM, 1)
	var second: NetClient = _add_bot(SOLMARCH, 2)
	assert_true(await _wait_until(_all_in_world), "both enter")
	assert_true(await _wait_until(_all_see_the_others), "and see each other")
	assert_eq(_server.get_player_count(), 2)
	var first_view: RemotePlayerView = first.get_remote_world().get_view(second.get_net_id())
	var second_view: RemotePlayerView = second.get_remote_world().get_view(first.get_net_id())
	assert_not_null(first_view, "the first sees the second")
	assert_not_null(second_view, "and the second, the first")
	if first_view == null or second_view == null:
		return
	assert_eq(first_view.get_display_name(), NameRules.bot_name(2))
	assert_eq(second_view.get_display_name(), NameRules.bot_name(1))
	assert_eq(first_view.get_realm(), SOLMARCH)
	assert_true(await _wait_until(func() -> bool: return first_view.get_body().visible),
			"and appears on screen when the drawing reaches its spawn")

	# A third enters and leaves with CLIENT_LEAVE.
	var third: NetClient = _add_bot(VARDHEIM, 3)
	var third_net_id: int = 0
	var third_text: Array[String] = []
	third.disconnected.connect(func(text: String) -> void: third_text.append(text))
	assert_true(await _wait_until(_all_in_world), "the third enters")
	third_net_id = third.get_net_id()
	assert_true(await _wait_until(_all_see_the_others), "and the three see each other")
	assert_eq(_server.get_player_count(), 3)
	third.leave()
	assert_true(await _wait_until(func() -> bool: return _server.get_player_count() == 2),
			"the server removes whoever leaves")
	assert_true(await _wait_until(func() -> bool:
		return first.get_remote_world().get_view(third_net_id) == null \
				and second.get_remote_world().get_view(third_net_id) == null),
			"and the others remove them from the screen when their draw tick reaches the removal")
	assert_true(await _wait_until(func() -> bool: return not third_text.is_empty()),
			"the one leaving receives the disconnection")
	assert_eq(third.get_state(), NetClient.State.CLOSED)
	assert_eq(third_text[0], NetClient.TEXT_LEFT, "with a text in Spanish")

	# The second drops without warning (cut): the server detects it when the socket closes.
	var second_net_id: int = second.get_net_id()
	_clients.erase(second)
	var second_viewport: SubViewport = _client_viewports[1]
	_client_viewports.erase(second_viewport)
	second_viewport.free()
	assert_true(await _wait_until(func() -> bool: return _server.get_player_count() == 1),
			"the server removes the one that drops")
	assert_true(await _wait_until(func() -> bool:
		return first.get_remote_world().get_view(second_net_id) == null),
			"and the one that remains removes them from the screen")
	assert_eq(first.get_state(), NetClient.State.IN_WORLD, "the one that remains is still in the world")
	assert_eq(first.get_remote_world().get_view_count(), 0)


func test_b_a_dropped_server_is_reported_to_the_client() -> void:
	await _start_server()
	var client: NetClient = _add_bot(VARDHEIM, 1)
	var texts: Array[String] = []
	client.disconnected.connect(func(text: String) -> void: texts.append(text))
	assert_true(await _wait_until(_all_in_world))
	_server.stop("Mantenimiento")
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty()),
			"the client learns of the closure")
	assert_eq(texts[0], "Mantenimiento", "with the server's NOTICE text")
	assert_eq(client.get_state(), NetClient.State.CLOSED)
	assert_eq(texts.size(), 1, "only once")


# --- c) Without a network simulator -----------------------------------------------------------

func test_c_three_bots_predict_exactly_and_see_each_other() -> void:
	await _start_server()
	var realms: Array[int] = [VARDHEIM, VARDHEIM, SOLMARCH]
	for i: int in 3:
		_add_bot(realms[i], i + 1)
	assert_true(await _wait_until(_all_in_world), "all three enter")
	assert_true(await _wait_until(_all_see_the_others), "and see each other")

	# 600 ticks. At tick 60 of each client, the number of differences so far is noted.
	var baseline: Dictionary[NetClient, int] = {}
	var worst_error: float = 0.0
	var samples: int = 0
	for frame: int in 600:
		await tree.physics_frame
		for client: NetClient in _clients:
			if not baseline.has(client) and client.get_local_tick() >= 60:
				baseline[client] = client.get_stats()["diffs"]
		if frame >= 120 and frame % 15 == 0:
			for client: NetClient in _clients:
				worst_error = maxf(worst_error, _drawing_error(client))
				samples += 1
	assert_true(samples > 0)
	assert_true(worst_error < 0.5, "the remotes are drawn within 0.5 m of the "
			+ "server's history (worst error: %.3f m)" % worst_error)
	for client: NetClient in _clients:
		var stats: Dictionary = client.get_stats()
		var name: String = client.get_config().display_name
		assert_eq(stats["diffs"] - baseline.get(client, 0), 0,
				"%s: 0 corrections since tick 60 (%s)" % [name, stats])
		assert_eq(stats["unexplained_diffs"], 0, "%s: no unexplained difference" % name)
		assert_eq(stats["hard_resets"], 0, "%s: no hard reset" % name)
		assert_eq(stats["resyncs"], 0, "%s: no resynchronisation" % name)
		assert_true(stats["matches"] > 200, "%s: matches on almost all snapshots (%d)"
				% [name, stats["matches"]])
		assert_eq(stats["malformed_packets"], 0)
		assert_eq(client.get_remote_world().get_view_count(), 2, "%s sees the other two" % name)
		assert_eq(stats["late_snapshots"], 0, "on loopback there are no out-of-order snapshots")
		# The local player is ahead of the server by a few ticks, no more.
		var server_position: Vector3 = _server_position(client.get_net_id())
		assert_true(client.get_character().global_position.distance_to(server_position) < 3.0,
				"%s: follows the server" % name)
	assert_true(_server.get_metrics().get_substituted_percent() < 5.0,
			"the server hardly substitutes any inputs")


## Distance between where [param viewer] draws each of the others and the
## [method StateHistory.sample] sample at that same draw tick; the worst of them.
func _drawing_error(viewer: NetClient) -> float:
	var worst: float = 0.0
	var render_tick: float = viewer.get_remote_world().get_last_drawn_render_tick()
	for other: NetClient in _clients:
		if other == viewer:
			continue
		var view: RemotePlayerView = viewer.get_remote_world().get_view(other.get_net_id())
		var truth: StateHistory.Sample = _server.get_history().sample(other.get_net_id(),
				render_tick)
		if view == null or truth == null:
			return 1000.0
		worst = maxf(worst, view.get_drawn_position().distance_to(truth.position))
	return worst


func test_c_report_and_state_log_are_written() -> void:
	await _start_server()
	var report_path: String = ProjectSettings.globalize_path("res://build/test_loopback_report.json")
	var log_path: String = ProjectSettings.globalize_path("res://build/test_loopback_states.txt")
	DirAccess.remove_absolute(report_path)
	DirAccess.remove_absolute(log_path)
	var logged: NetClient = _add_bot(VARDHEIM, 5)
	# The log is opened on writing the first line, so it can be requested right after start().
	logged.get_config().state_log_path = log_path
	assert_true(await _wait_until(_all_in_world))
	await wait_physics_frames(120)
	assert_eq(logged.write_report(report_path), OK)
	var report: Dictionary = NetHarness.read_report(report_path)
	for key: String in ["matches", "diffs", "explained_diffs", "unexplained_diffs",
			"hard_resets", "resyncs", "tick_sync_adjustments", "substitutions", "final", "name",
			"snapshots_with_state", "state", "rtt_ticks"]:
		assert_true(report.has(key), "the report has \"%s\"" % key)
	assert_eq(report.get("name"), NameRules.bot_name(5))
	assert_eq(report.get("state"), "IN_WORLD")
	assert_true(int(report.get("matches", 0)) > 20)
	assert_eq(int(report.get("unexplained_diffs", -1)), 0)
	var final_state: Dictionary = report.get("final", {})
	assert_true(final_state.has("predicted_state") and final_state.has("server_state"),
			"with the final state")
	assert_eq(String(final_state.get("predicted_state", "")).length(),
			PlayerState.ENCODED_SIZE * 2, "in hexadecimal")
	assert_true(bool(final_state.get("exact", false)), "the final state matches the server's")
	# The log has server_tick,predicted,server for each snapshot with own state.
	var lines: PackedStringArray = FileAccess.get_file_as_string(log_path).split("\n", false)
	assert_true(lines.size() > 20, "one line per snapshot (%d)" % lines.size())
	var matching: int = 0
	for line: String in lines:
		var parts: PackedStringArray = line.split(",")
		assert_eq(parts.size(), 3)
		if parts.size() == 3 and parts[1] == parts[2]:
			matching += 1
	assert_true(matching > lines.size() / 2, "almost all with predicted equal to the server's")


# --- e) Debug teleport ------------------------------------------------------------------------

func test_e_debug_teleport_jumps_without_smoothing_and_converges_exactly() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	var client: NetClient = _add_bot(VARDHEIM, 4)
	assert_true(await _wait_until(_all_in_world))
	await wait_physics_frames(90)
	var before: Dictionary = client.get_stats()
	assert_eq(before["diffs"], 0, "no differences before the teleport (%s)" % before)

	var target := Vector3(-60.0, 0.0, -40.0)
	var payload: PackedByteArray = NetMessages.DebugCommand.teleport(target).payload
	client.send_debug_command(NetProtocol.DEBUG_TELEPORT, payload)
	assert_true(await _wait_until(func() -> bool:
		return client.get_stats()["teleport_diffs"] > 0), "the client notices the teleport")
	var character: PlayerCharacter = client.get_character()
	var visual: Node3D = character.get_node(^"Visual") as Node3D
	assert_true(character.global_position.distance_to(target) < 3.0,
			"and jumps to the new place (%s)" % character.global_position)
	assert_eq(visual.position, Vector3.ZERO, "without smoothing: the visual is not left displaced")
	assert_eq(client.get_stats()["unexplained_diffs"], 0, "the jump is not a prediction failure")

	# The bot keeps strolling (heads back home) and everything keeps matching.
	await wait_physics_frames(120)
	assert_eq(client.get_stats()["unexplained_diffs"], 0)
	assert_eq(client.get_stats()["hard_resets"], 0)
	assert_eq(client.get_stats()["teleport_diffs"], 1, "a single teleport")

	# Standing still, it ends up exact: the predicted state is bit-for-bit identical to the server's.
	var brain: BotBrain = client.get_meta(&"bot_brain") as BotBrain
	brain.set_idle_from(client.get_prediction().get_predicted_tick() + 1)
	await wait_physics_frames(90)
	var stats: Dictionary = client.get_stats()
	assert_true(stats["consecutive_matches"] >= 10, "it converges and keeps matching (%d)"
			% stats["consecutive_matches"])
	var server_entity: NetEntity = _server.get_registry().get_entity(client.get_net_id())
	var server_state: PlayerState = server_entity.get_character().get_state()
	var predicted_state: PlayerState = client.get_prediction().get_predicted_state(
			stats["server_tick"])
	assert_not_null(predicted_state)
	if predicted_state != null:
		assert_true(client.get_last_server_state().equals_exact(predicted_state),
				"the server's last state matches the predicted one exactly")
	assert_vec_near(character.get_state().position, server_state.position, 0.0001,
			"standing still, client and server are at the same point")
	assert_vec_near(server_state.velocity, Vector3.ZERO, 0.001)


func test_e_teleport_is_ignored_without_debug_commands() -> void:
	await _start_server()
	var client: NetClient = _add_bot(VARDHEIM, 4)
	assert_true(await _wait_until(_all_in_world))
	var start_position: Vector3 = client.get_character().global_position
	var payload: PackedByteArray = NetMessages.DebugCommand.teleport(Vector3(-60.0, 0.0, -40.0)) \
			.payload
	client.send_debug_command(NetProtocol.DEBUG_TELEPORT, payload)
	await wait_physics_frames(60)
	assert_eq(client.get_stats()["teleport_diffs"], 0)
	assert_true(client.get_character().global_position.distance_to(start_position) < 25.0,
			"the command had no effect")
	assert_eq(client.get_state(), NetClient.State.IN_WORLD, "and the client is still inside")


# --- d) Bad network: delay, jitter and loss ---------------------------------------------------

## Network simulator for each bot in test d (section 16): 150 ms of RTT, ±30 ms of jitter and
## 10 % loss in each direction. The seed differs per bot so that they do not lose the
## same packets.
const D_NET_SIM: String = "rtt=150,jitter=30,loss=10,seed=%d"
## Local ticks (since a bot's session starts) up to which it is considered startup: before that,
## TickSync is still finding its lead time (the first comes from an RTT measured with little
## data and from a jitter that is not yet known).
const D_STARTUP_TICKS: int = 150
## Local ticks from which the "steady-state" margin is measured.
const D_REGIME_FROM_TICK: int = 300
## Ticks measured from when the three bots enter, and idle ticks at the end (60 neutral inputs
## that the server must consume plus the time the last one and the snapshot take to arrive).
const D_MEASURED_TICKS: int = 720
const D_IDLE_TICKS: int = 90
const D_QUIET_TICKS: int = 60
## Maximum margin (ticks) of the minimum of TickSync's window in steady state: the maximum target (4)
## plus the 2-tick threshold from which TickSync starts to fall back. 0 is "just in time".
const D_MARGIN_MAX: int = 6
## Minimum fraction of the steady-state samples that must fall within [0, D_MARGIN_MAX]. Right
## after each adjustment TickSync empties the window and its minimum is computed from few samples, so
## it rises for a moment above the threshold (up to 8 in the measurements).
const D_MIN_IN_RANGE_FRACTION: float = 0.8
## Maximum of late inputs, out of those consumed by the server.
const D_MAX_LATE_FRACTION: float = 0.02


## Three bots on a bad network. What is measured and why:
## [br]- [b]Lead time[/b] ([code]input_margin[/code]): the minimum of TickSync's window
## ([method TickSync.get_window_min]) at each steady-state tick, which is exactly what the control
## loop regulates. The margin of a single snapshot is no use: it is the minimum of two ticks' arrivals and with
## ±30 ms of jitter it oscillates by several ticks (its mean comes out about 2 ticks above the window's
## minimum). The mean for each bot is required to be in [0, 6] and almost all samples to be as well.
## [br]- [b]Late ones[/b]: the server's [member InputQueue.late_count] against the inputs consumed.
## [br]- [b]Corrections[/b]: counted by the client itself ([code]diffs[/code]); one is "explained" if it
## coincides with a rise in [code]substitutions[/code] in the same snapshot.
## [br]- [b]Convergence[/b]: after 60 idle ticks ([method BotBrain.set_idle_from]) the state
## predicted for the server's last tick is bit-for-bit identical to the server's.
func test_d_three_bots_under_a_bad_network_stay_in_sync() -> void:
	await _start_server()
	var realms: Array[int] = [VARDHEIM, VARDHEIM, SOLMARCH]
	for i: int in 3:
		_add_bot(realms[i], i + 1, D_NET_SIM % (11 * (i + 1)))
	assert_true(await _wait_until(_all_in_world, 900), "all three enter")
	assert_true(await _wait_until(_all_see_the_others, 900), "and see each other")

	# Minimum of TickSync's window at each steady-state tick.
	var window_mins: Dictionary[NetClient, Array] = {}
	for client: NetClient in _clients:
		window_mins[client] = []
	for _frame: int in D_MEASURED_TICKS:
		await tree.physics_frame
		for client: NetClient in _clients:
			var low: int = client.get_tick_sync().get_window_min()
			if client.get_local_tick() >= D_REGIME_FROM_TICK and low != NetProtocol.NO_MARGIN:
				window_mins[client].append(low)

	# Idle: the server consumes 60 ticks of neutral inputs and the client converges.
	var idle_ticks: Dictionary[NetClient, int] = {}
	for client: NetClient in _clients:
		var brain: BotBrain = client.get_meta(&"bot_brain") as BotBrain
		idle_ticks[client] = client.get_prediction().get_predicted_tick() + 1
		brain.set_idle_from(idle_ticks[client])
	await wait_physics_frames(D_IDLE_TICKS)

	for client: NetClient in _clients:
		var name: String = client.get_config().display_name
		var stats: Dictionary = client.get_stats()
		assert_eq(client.get_state(), NetClient.State.IN_WORLD, "%s: still in the world" % name)

		# Lead time in steady state.
		var samples: Array = window_mins[client]
		assert_true(samples.size() > D_MEASURED_TICKS / 2,
				"%s: there are steady-state samples (%d)" % [name, samples.size()])
		var total: int = 0
		var in_range: int = 0
		for value: int in samples:
			total += value
			if value >= 0 and value <= D_MARGIN_MAX:
				in_range += 1
		var mean: float = float(total) / maxf(samples.size(), 1)
		assert_true(mean >= 0.0 and mean <= float(D_MARGIN_MAX),
				"%s: mean margin in [0, %d] (%.2f)" % [name, D_MARGIN_MAX, mean])
		assert_true(float(in_range) >= D_MIN_IN_RANGE_FRACTION * samples.size(),
				"%s: the margin is in [0, %d] almost always (%d of %d samples)"
				% [name, D_MARGIN_MAX, in_range, samples.size()])

		# Late inputs.
		var queue: InputQueue = _server_queue(client)
		assert_not_null(queue, "%s: the server has its queue" % name)
		if queue != null:
			var consumed: int = queue.get_last_consumed() - client.get_spawn_tick()
			assert_true(consumed > D_MEASURED_TICKS,
					"%s: the server consumes inputs (%d)" % [name, consumed])
			assert_true(float(queue.late_count) < D_MAX_LATE_FRACTION * consumed,
					"%s: fewer than %d %% late inputs (%d of %d)"
					% [name, roundi(D_MAX_LATE_FRACTION * 100.0), queue.late_count, consumed])
			assert_eq(queue.too_early_count, 0, "%s: no input too far ahead" % name)

		# Corrections and resynchronisations.
		assert_eq(stats["unexplained_diffs"], 0,
				"%s: each correction coincides with a rise in substitutions (%s)"
				% [name, stats])
		assert_eq(stats["diffs"], stats["explained_diffs"], "%s: all explained" % name)
		assert_true(stats["diffs"] <= stats["substitution_rises"],
				"%s: at most one correction per rise (%d, %d)"
				% [name, stats["diffs"], stats["substitution_rises"]])
		for event_tick: int in stats["resync_ticks"]:
			assert_true(event_tick <= D_STARTUP_TICKS,
					"%s: hard resynchronisation outside startup (tick %d)" % [name, event_tick])
		for event_tick: int in stats["hard_reset_ticks"]:
			assert_true(event_tick <= D_STARTUP_TICKS,
					"%s: hard reset outside startup (tick %d)" % [name, event_tick])
		assert_eq(stats["malformed_packets"], 0)
		assert_true(stats["late_snapshots"] > 0, "%s: the jitter reorders some snapshot" % name)
		assert_eq(client.get_remote_world().get_view_count(), 2, "%s sees the other two" % name)

		# Exact convergence after 60 idle ticks.
		_assert_converged(client, idle_ticks[client])


## The client, idle since [param idle_tick] (at least [constant D_QUIET_TICKS] ticks already
## consumed by the server), has as its predicted state for the last tick it reconciled
## exactly the server's, and is at the same point as the server's character.
func _assert_converged(client: NetClient, idle_tick: int) -> void:
	var name: String = client.get_config().display_name
	var stats: Dictionary = client.get_stats()
	assert_true(stats["server_tick"] >= idle_tick + D_QUIET_TICKS,
			"%s: the last snapshot is after 60 idle ticks (%d, idle since %d)"
			% [name, stats["server_tick"], idle_tick])
	assert_true(stats["consecutive_matches"] >= 10,
			"%s: it converges and keeps matching (%d)" % [name, stats["consecutive_matches"]])
	var server_state: PlayerState = client.get_last_server_state()
	var predicted_state: PlayerState = client.get_prediction().get_predicted_state(
			stats["server_tick"])
	assert_not_null(server_state)
	assert_not_null(predicted_state)
	if server_state != null and predicted_state != null:
		assert_true(server_state.equals_exact(predicted_state),
				"%s: the predicted state is bit-for-bit identical to the server's" % name)
	var entity: NetEntity = _server.get_registry().get_entity(client.get_net_id())
	if entity != null:
		var server_now: PlayerState = entity.get_character().get_state()
		assert_vec_near(client.get_character().get_state().position, server_now.position, 0.0001,
				"%s: standing still, client and server are at the same point" % name)
		assert_vec_near(server_now.velocity, Vector3.ZERO, 0.001)


## Input queue that the server keeps for [param client]'s player (null if absent).
func _server_queue(client: NetClient) -> InputQueue:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer != null and peer.entity != null and peer.entity.net_id == client.get_net_id():
			return peer.input_queue
	return null


## A total network outage (24 ticks with no unreliable packet getting through) with the bad network in the
## background. The server substitutes the inputs that do not arrive (and after 6 ticks leaves the player standing still),
## so the client has to correct itself: every correction must coincide with a rise
## in substitutions, and afterwards it ends up exact. It makes the "every correction is
## explained" check of the previous test non-vacuous.
func test_d_an_outage_is_corrected_and_explained_by_substitutions() -> void:
	await _start_server()
	var client: NetClient = _add_bot(VARDHEIM, 1, D_NET_SIM % 11)
	assert_true(await _wait_until(_all_in_world, 900), "enters")
	await wait_physics_frames(D_REGIME_FROM_TICK)
	var before: Dictionary = client.get_stats()
	assert_eq(before["unexplained_diffs"], 0, "no failures before the outage (%s)" % before)
	var transport: NetTransport = client.get_meta(&"transport") as NetTransport
	transport.set_net_sim_spec("rtt=150,jitter=30,loss=100,seed=3")
	await wait_physics_frames(24)
	transport.set_net_sim_spec(D_NET_SIM % 11)
	await wait_physics_frames(240)

	var brain: BotBrain = client.get_meta(&"bot_brain") as BotBrain
	var idle_tick: int = client.get_prediction().get_predicted_tick() + 1
	brain.set_idle_from(idle_tick)
	await wait_physics_frames(D_IDLE_TICKS)
	var stats: Dictionary = client.get_stats()
	assert_true(stats["diffs"] > before["diffs"], "the outage causes corrections (%s)" % stats)
	assert_true(stats["substitution_rises"] > before["substitution_rises"],
			"and the server substitutes inputs (%s)" % stats)
	assert_eq(stats["unexplained_diffs"], 0, "all coincide with a rise (%s)" % stats)
	assert_eq(stats["diffs"], stats["explained_diffs"])
	assert_eq(stats["malformed_packets"], 0)
	assert_eq(client.get_state(), NetClient.State.IN_WORLD)
	_assert_converged(client, idle_tick)


# --- f) Server stalls -------------------------------------------------------------------------

## Ticks the server loses in the tests' stalls (about 0.67 s: more than what Godot
## recovers at once, which is 8 ticks per frame).
const F_STALL_TICKS: int = 40
## Calm ticks before the stall and recovery ticks after, and the final window in which it is measured.
const F_CALM_TICKS: int = 120
const F_RECOVERY_TICKS: int = 360
const F_FINAL_TICKS: int = 120


## Stops the server loop for [param ticks] client ticks and resumes it: the server loses
## those ticks relative to the real clock, as in a process stall or a virtual machine
## pause (Godot only recovers 8 ticks per frame). The clients carry on at their own pace.
func _stall_server(ticks: int) -> void:
	_server.set_physics_process(false)
	await wait_physics_frames(ticks)
	_server.set_physics_process(true)


## After the server loses 40 ticks, the client is far ahead: its inputs arrive as
## too early. Even so, the server has to record that lead time (saturated) so that
## [TickSync] finds out and falls back gradually; otherwise, the window stays empty forever, the
## server substitutes all inputs and the character stands still on the server (finding N1).
func test_f_a_server_stall_does_not_leave_the_client_ahead_forever() -> void:
	await _start_server()
	var client: NetClient = _add_bot(VARDHEIM, 1)
	assert_true(await _wait_until(_all_in_world), "enters")
	await wait_physics_frames(F_CALM_TICKS)
	var queue: InputQueue = _server_queue(client)
	if not assert_not_null(queue, "the server has its queue"):
		return
	assert_eq(queue.too_early_count, 0, "before the stall, no input too far ahead")

	await _stall_server(F_STALL_TICKS)
	await wait_physics_frames(F_RECOVERY_TICKS)
	var too_early_before: int = queue.too_early_count
	var substitutions_before: int = queue.substitutions_total
	var diffs_before: int = client.get_stats()["diffs"]
	await wait_physics_frames(F_FINAL_TICKS)

	var stats: Dictionary = client.get_stats()
	assert_true(too_early_before > 0, "the stall did cause inputs too far ahead")
	assert_eq(queue.too_early_count, too_early_before,
			"after %d ticks no inputs too far ahead arrive any more" % F_RECOVERY_TICKS)
	assert_true(client.get_tick_sync().get_window_min() != NetProtocol.NO_MARGIN,
			"TickSync receives margin samples again")
	var lead: int = stats["predicted_tick"] - _server.get_tick()
	var bound: int = client.get_tick_sync().get_target_margin() + stats["rtt_ticks"] + 2
	assert_true(lead <= bound, "the lead time returns to normal (%d ticks, maximum %d)"
			% [lead, bound])
	assert_eq(queue.substitutions_total, substitutions_before,
			"the server no longer substitutes inputs")
	assert_eq(stats["diffs"], diffs_before, "and there are no new corrections")
	assert_eq(client.get_state(), NetClient.State.IN_WORLD)


## After the server loses 20 ticks, the snapshots' offsets drop by 20 at once. The remotes must not
## freeze (draw tick more than MAX_EXTRAPOLATION_TICKS ahead of the last
## data) until the interpolation clock's 2 s window expires (finding N3): they
## froze for about 80 ticks after the data came back.
func test_f_remotes_are_not_frozen_for_seconds_after_a_server_stall() -> void:
	await _start_server()
	var first: NetClient = _add_bot(VARDHEIM, 1)
	var second: NetClient = _add_bot(VARDHEIM, 2)
	assert_true(await _wait_until(_all_in_world), "both enter")
	assert_true(await _wait_until(_all_see_the_others), "and see each other")
	await wait_physics_frames(F_CALM_TICKS)

	_server.set_physics_process(false)
	await wait_physics_frames(20)
	_server.set_physics_process(true)
	var snapshots_at_resume: int = first.get_stats()["snapshots"]
	var frozen_after_data: int = 0
	var data_back: bool = false
	for _i: int in 300:
		await tree.physics_frame
		if first.get_stats()["snapshots"] > snapshots_at_resume:
			data_back = true
		var view: RemotePlayerView = first.get_remote_world().get_view(second.get_net_id())
		if not data_back or view == null:
			continue
		var ahead: float = first.get_interpolation_clock().get_render_tick() \
				- float(view.get_interpolator().get_newest_tick())
		if ahead > RemoteInterpolator.MAX_EXTRAPOLATION_TICKS:
			frozen_after_data += 1
	assert_true(data_back, "the snapshots come back")
	assert_true(frozen_after_data < 15,
			"the remote does not freeze after the data comes back (%d ticks)" % frozen_after_data)
