extends TestCase
## A real client ([NetClient] in bot mode) sees the fort over ENet on 127.0.0.1 (package F3): the
## fortress SPAWN on entering, the OBJECT_STATEs and the WAR notices of a full capture (neutral ->
## Vardheim) made by fake players on the server, and the scoreboard every 2 s, without a single malformed
## packet. It complements [code]test_fortress_net.gd[/code], whose clients speak the protocol by hand.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const FORTRESS: StringName = FortressFixture.FORTRESS_ID
const WAIT_FRAMES: int = 900

var _root: Node
var _server_viewport: SubViewport
var _client_viewport: SubViewport
var _server: ZoneServer
var _client: NetClient
var _port: int = 0


func before_each() -> void:
	_root = Node.new()
	_root.name = "FortressLoopback"
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_client_viewport):
		_client_viewport.free()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_client_viewport = null
	_server_viewport = null
	_server = null
	_client = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func test_a_bot_client_sees_a_full_capture_as_object_states_and_war_events() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var server_world: Node3D = NetHarness.get_world(_server_viewport)
	FortressFixture.add_fortress(server_world, FortressFixture.make_definition())
	FortressFixture.add_respawn_points(server_world)
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = "test_world"
	config.max_players = 8
	config.no_dummies = true
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	if not assert_not_null(_server, "the server starts"):
		return
	# The client loads the same zone (with the fortress) and connects as a Solmarch bot.
	_client_viewport = NetHarness.make_world_viewport(_root, "")
	var client_world: Node3D = NetHarness.get_world(_client_viewport)
	FortressFixture.add_fortress(client_world, FortressFixture.make_definition())
	_client = NetHarness.start_bot(_client_viewport, _port, NetProtocol.Realm.SOLMARCH, 7)
	var in_world: bool = await _wait_until(func() -> bool:
		return _client.get_state() == NetClient.State.IN_WORLD)
	if not assert_true(in_world, "the bot enters the world"):
		return
	var spawned: bool = await _wait_until(func() -> bool:
		return int(_client.get_stats()["structure_spawns"]) >= 1)
	assert_true(spawned, "receives the fortress SPAWN on entering")
	# The capture is made by a fake Vardheim player, after killing the Hollows' captain.
	_server.spawn_captain_double(FORTRESS)
	var attacker: int = _server.add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM)
	_server.teleport(attacker, FortressFixture.circle_center())
	await wait_physics_frames(20)
	_server.console_command("fort_kill_captain")
	var captured: bool = await _wait_until(func() -> bool:
		return _server.get_fortresses().get_fortress_state(FORTRESS).owner == VARDHEIM)
	assert_true(captured, "the fort passes to Vardheim")
	var told: bool = await _wait_until(func() -> bool:
		return int(_client.get_stats()["war_events"]) >= 3)
	assert_true(told, "the client receives the three capture notices")
	var stats: Dictionary = _client.get_stats()
	assert_eq(int(stats["war_events"]), 3, "captain fallen, capture started and fort captured")
	assert_true(int(stats["object_states"]) >= 3, "and the OBJECT_STATEs of presence, capture and owner")
	assert_eq(int(stats["structure_spawns"]), 1)
	assert_eq(int(stats["malformed_packets"]), 0, "not a single malformed packet")
	# The scoreboard arrives every 2 s.
	var board: bool = await _wait_until(func() -> bool:
		return int(_client.get_stats()["scoreboards"]) >= 2, 600)
	assert_true(board, "the zone scoreboard")
	assert_eq(int(_client.get_stats()["malformed_packets"]), 0)


## It always advances east (into the fort, through the gate).
class EastBrain extends BotBrain:
	func _init() -> void:
		super(1, BotBrain.Pattern.IDLE)


	func next_input(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = -PI * 0.5
		input.move = Vector2(0.0, 1.0)
		return input


## Phase 4 revision (client): when the gate changes (owner or broken) the server applies it from s + 1, but the
## ticks that the client had already predicted before receiving the OBJECT_STATE were simulated with the old one. The correction
## this brings (the bot was pushing the gate and suddenly gets through) is expected: it has to count as explained by the gate
## (gate_diffs), not as a prediction failure. And the test client moves its own gate, not the server's.
func test_a_gate_that_opens_under_the_bots_feet_is_an_explained_correction() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var server_world: Node3D = NetHarness.get_world(_server_viewport)
	FortressFixture.add_fortress(server_world, FortressFixture.make_definition())
	FortressFixture.add_respawn_points(server_world)
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = "test_world"
	config.max_players = 8
	config.no_dummies = true
	config.no_npcs = true
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	if not assert_not_null(_server, "the server starts"):
		return
	_client_viewport = NetHarness.make_world_viewport(_root, "")
	var client_world: Node3D = NetHarness.get_world(_client_viewport)
	FortressFixture.add_fortress(client_world, FortressFixture.make_definition())
	_client = NetHarness.start_bot(_client_viewport, _port, NetProtocol.Realm.SOLMARCH, 7)
	var in_world: bool = await _wait_until(func() -> bool:
		return (_client.get_state() == NetClient.State.IN_WORLD and _client.has_meta(&"bot_brain")
				and int(_client.get_stats()["structure_spawns"]) >= 1))
	if not assert_true(in_world, "the bot enters the world and knows the fort"):
		return
	var fortress_id: int = _client.get_fortress_view().get_primary_id()
	var client_gate: FortGate = _client.get_fortress_view().get_gate(fortress_id)
	if not assert_not_null(client_gate, "the client view links a gate"):
		return
	assert_true(_client_viewport.is_ancestor_of(client_gate),
			"the one from its own world, not the server's (the harness gives it its zone, like OnlineMain)")
	# The bot pushes the closed gate of the neutral fort (at x = 80) and stands still against it.
	(_client.get_meta(&"controller") as LocalPlayerController).set_bot(EastBrain.new())
	_server.teleport(_client.get_net_id(), FortressFixture.gate_position() + Vector3(-5.0, 0.05, 0.0))
	await wait_physics_frames(150)
	var feet: Vector3 = _client.get_character().global_position
	assert_true(feet.x < FortressFixture.gate_position().x, "stopped before the closed gate (x = %.2f)" % feet.x)
	var before: Dictionary = _client.get_stats()
	assert_eq(int(before["unexplained_diffs"]), 0, "up to here, no prediction failures")
	# The fort passes to Solmarch: the gate opens for the bot and it crosses it.
	assert_true(_server.console_command("fort_owner solmarch").length() > 0)
	await wait_physics_frames(60)
	assert_true(_client.get_character().global_position.x > FortressFixture.gate_position().x + 1.0,
			"the bot crosses the open gate (x = %.2f)" % _client.get_character().global_position.x)
	# It waits for the pending differences to be treated as final (DIFF_SETTLE_TICKS).
	await wait_physics_frames(NetClient.DIFF_SETTLE_TICKS + 30)
	var after: Dictionary = _client.get_stats()
	assert_true(int(after["diffs"]) > int(before["diffs"]), "the gate change brings at least one correction (%d -> %d)"
			% [int(before["diffs"]), int(after["diffs"])])
	assert_eq(int(after["unexplained_diffs"]), 0, "but none unexplained (ticks %s)" % [after["unexplained_ticks"]])
	assert_true(int(after.get("gate_diffs", 0)) >= 1, "the gate explains it (gate_diffs = %d)" % int(after.get("gate_diffs", 0)))
	assert_eq(int(after["hard_resets"]), int(before["hard_resets"]), "no hard resets")
