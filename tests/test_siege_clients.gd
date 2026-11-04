extends TestCase
## The clients that besiege (GUE-15; docs/fortress.md, section 7) against a real server over ENet on
## 127.0.0.1:
## [br]- the [SwarmBot]s of [code]--bots=N --bot-brain=siege[/code], which neither load the zone nor simulate: they fill their
## [SiegeView] by hand-decoding the fortress registration and each OBJECT_STATE, reach the door (the server
## simulates their steps over the real Vado Gris), break it, enter the circle and capture the fort;
## [br]- the [code]--bot --bot-brain=siege[/code] bot (a predicting [NetClient]), whose [SiegeView] fills
## [FortressView] (ClientBotBrains).
## So that it lasts seconds, the test trims the door's health and places the bots in front of it: the trip
## from camp to door, along both paths, is measured by [code]test_siege_zone[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const SWARM_SCENE: String = "res://scenes/client/bot_swarm.tscn"
const WAIT_FRAMES: int = 1200

var _root: Node
var _server_viewport: SubViewport
var _client_viewport: SubViewport
var _server: ZoneServer
var _swarm: BotSwarm
var _client: NetClient
var _port: int = 0
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_max_fps: int = 0


func before_each() -> void:
	_saved_config = BotSwarm.config
	_saved_hook = BotSwarm.quit_hook
	_saved_max_fps = Engine.max_fps
	BotSwarm.quit_hook = func(_code: int) -> void: pass
	_root = Node.new()
	_root.name = "SiegeClients"
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_swarm):
		_swarm.get_parent().remove_child(_swarm)
		_swarm.free()
	_swarm = null
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
	BotSwarm.config = _saved_config
	BotSwarm.quit_hook = _saved_hook
	Engine.max_fps = _saved_max_fps
	await wait_process_frames(2)


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _state() -> FortressState:
	return _server.get_fortresses().get_fortress_state(_server.get_fortresses().get_fortress_ids()[0])


func test_swarm_bots_read_the_fort_from_object_states_break_the_gate_and_capture() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, NetZones.scene_path("vado_gris"))
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = "vado_gris"
	config.max_players = 8
	config.no_dummies = true
	# Without the F4 NPCs: here only how the SwarmBots read the fort is tested (with the Hollow in the courtyard
	# they would fight in the circle instead of staying put); the siege with NPCs belongs to F6b.
	config.no_npcs = true
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	if not assert_not_null(_server, "the server starts on Vado Gris"):
		return
	var client_config := ClientConfig.new()
	client_config.mode = ClientConfig.Mode.SWARM
	client_config.port = _port
	client_config.bot_count = 3
	client_config.bot_seed = 520
	client_config.realm = VARDHEIM
	client_config.bot_brain = ClientConfig.BOT_BRAIN_SIEGE
	BotSwarm.config = client_config
	_swarm = (load(SWARM_SCENE) as PackedScene).instantiate() as BotSwarm
	_root.add_child(_swarm)
	var all_in: bool = await _wait_until(func() -> bool: return _swarm.count_in_world() == 3)
	if not assert_true(all_in, "all three enter (%d)" % _swarm.count_in_world()):
		return
	var bots: Array[SwarmBot] = _swarm.get_bots()
	# The fortress registration arrives on entering and fills the SiegeView (with the complete fields).
	var known: bool = await _wait_until(func() -> bool:
		for bot: SwarmBot in bots:
			if not bot.get_siege_view().known:
				return false
		return true)
	if not assert_true(known, "all three know the fort from its ENTITY_SPAWN"):
		return
	for bot: SwarmBot in bots:
		var view: SiegeView = bot.get_siege_view()
		assert_eq(view.owner, 0, "neutral")
		assert_eq(view.gate_max, 9000, "with the door's health")
		assert_false(view.is_gate_broken())
		assert_true(view.circle_radius > 0.0, "and it knows where it is (the zone's routes)")
		assert_eq(bot.get_brain().get_pattern(), BotBrain.Pattern.SIEGE)
		assert_true(bot.get_brain().has_siege())
		assert_true(bot.get_brain().has_ally_counter(), "with whoever counts its own for it (GUE-44)")
		assert_true(bot.get_brain().has_threat_finder(), "with whoever warns it of hits (F6b)")
		assert_true(bot.get_brain().has_defender_finder(), "and with whoever finds the defending NPCs for it (F6b)")
		assert_eq(int(bot.get_stats()["fort_reached_tick"]), -1, "at the camp it has not reached the fort yet (GUE-16)")
	# Each one sees the other two of its realm through their spawns and the snapshots (it counts them at the rally, GUE-44).
	var counted: bool = await _wait_until(func() -> bool:
		for bot: SwarmBot in bots:
			if bot._count_allies(bot.get_position(), 60.0) != 2:
				return false
		return true)
	assert_true(counted, "each bot counts the other two (%d)" % bots[0]._count_allies(bots[0].get_position(), 60.0))
	# The door is left at 600 health (it arrives as OBJECT_STATE) and the bots start on the esplanade.
	_state().gate_health = 600
	var teleport_tick: int = _server.get_tick()
	var ground: float = _server.get_fortresses().get_gate(_server.get_fortresses().get_fortress_ids()[0]).global_position.y
	for i: int in 3:
		_server.teleport(bots[i].get_net_id(), Vector3(-25.0, ground + 0.4, -2.0 + 2.0 * float(i)))
	var broken: bool = await _wait_until(func() -> bool: return _state().is_gate_broken())
	if not assert_true(broken, "three bots break the door by hitting it (health %d)" % _state().gate_health):
		return
	# The client learns of it through an OBJECT_STATE and enters the circle.
	var told: bool = await _wait_until(func() -> bool: return bots[0].get_siege_view().is_gate_broken())
	assert_true(told, "a bot's SiegeView knows the door is broken (only through OBJECT_STATE)")
	var inside: bool = await _wait_until(func() -> bool: return _state().presence[VARDHEIM] == 3)
	if not assert_true(inside, "all three enter the circle (%d)" % _state().presence[VARDHEIM]):
		return
	assert_eq(String(bots[0].get_stats()["siege_task"]), "HOLD", "and stay in it")
	for bot: SwarmBot in bots:
		var reached: int = int(bot.get_stats()["fort_reached_tick"])
		assert_true(reached > teleport_tick and reached <= _server.get_tick(),
				"the bot's report says at which server tick it reached the fort (%d, after %d)" % [reached, teleport_tick])
	assert_true(int(bots[0].get_stats()["object_states_applied"]) >= 2, "after applying several OBJECT_STATEs")
	# The captain falls and they capture.
	_server.console_command("fort_capture_speed 30")
	assert_true(_server.console_command("fort_kill_captain").contains("ha muerto"))
	var captured: bool = await _wait_until(func() -> bool: return _state().owner == VARDHEIM)
	assert_true(captured, "Vardheim captures the fort (phase %d)" % _state().phase)
	var owner_told: bool = await _wait_until(func() -> bool: return bots[1].get_siege_view().owner == VARDHEIM)
	assert_true(owner_told, "and the bots know it is now theirs")
	assert_eq(int(bots[2].get_stats()["malformed_packets"]), 0, "no malformed packets")


func test_a_predicting_bot_with_the_siege_brain_follows_the_fort_through_fortress_view() -> void:
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
	_client_viewport = NetHarness.make_world_viewport(_root, "")
	FortressFixture.add_fortress(NetHarness.get_world(_client_viewport), FortressFixture.make_definition())
	_client = NetHarness.start_bot(_client_viewport, _port, VARDHEIM, 9, "", "", ClientConfig.BOT_BRAIN_SIEGE)
	var in_world: bool = await _wait_until(func() -> bool:
		return _client.get_state() == NetClient.State.IN_WORLD and _client.has_meta(&"bot_brain"))
	if not assert_true(in_world, "the bot enters the world"):
		return
	var brain: BotBrain = _client.get_meta(&"bot_brain") as BotBrain
	assert_eq(brain.get_pattern(), BotBrain.Pattern.SIEGE, "with the siege brain")
	assert_true(brain.has_siege() and brain.has_enemy_finder())
	assert_true(brain.has_ally_counter(), "with whoever counts its own for it (BotAllySight, GUE-44)")
	assert_true(brain.has_threat_finder() and brain.has_defender_finder(), "with the warnings and the defenders (F6b)")
	# The warnings it avoids are only those from whoever can damage it (like the server's fake players): a warning from one of its own realm
	# does not count and one from the other does (the filter looks at the remote's realm, NPC or not).
	var friend: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), VARDHEIM)
	var foe: int = _server.add_fake_player(BotBrain.new(2, BotBrain.Pattern.IDLE), SOLMARCH)
	var seen: bool = await _wait_until(func() -> bool:
		return _client.get_remote_world().get_view(friend) != null and _client.get_remote_world().get_view(foe) != null)
	if not assert_true(seen, "the bot draws one of each realm"):
		return
	var now: int = _client.get_prediction().get_predicted_tick()
	_client.telegraph_received.emit(NetMessages.EntityEvent.telegraph(friend, now, 7,
			NetMessages.EntityEvent.SHAPE_SECTOR, Vector3.ZERO, 0.0, 350, 60))
	var own_threats: int = (brain._siege_threat_finder.call(Vector3.ZERO) as Array).size()
	_client.telegraph_received.emit(NetMessages.EntityEvent.telegraph(foe, now, 7,
			NetMessages.EntityEvent.SHAPE_SECTOR, Vector3.ZERO, 0.0, 350, 60))
	assert_eq(own_threats, 0, "the warning from one of its own realm is not a threat")
	assert_eq((brain._siege_threat_finder.call(Vector3.ZERO) as Array).size(), 1, "the one from the other realm is")
	_server.remove_fake_player(friend)
	_server.remove_fake_player(foe)
	var view: SiegeView = brain.get_siege_view()
	var fortress_known: bool = await _wait_until(func() -> bool: return view.known and view.circle_radius > 0.0)
	if not assert_true(fortress_known, "FortressView gives it the fort's state and positions"):
		return
	assert_vec_near(view.gate_position, FortressFixture.gate_position(), 0.05, "the door of the client's scene")
	assert_vec_near(view.circle_center, FortressFixture.circle_center(), 0.05, "and the circle")
	# Without routes for this test zone, it goes straight: it is placed in front of the 200-health door.
	_state().gate_health = 200
	var net_id: int = _client.get_net_id()
	_server.teleport(net_id, FortressFixture.gate_position() + Vector3(-5.0, 0.3, 0.0))
	var broken: bool = await _wait_until(func() -> bool: return _state().is_gate_broken())
	if not assert_true(broken, "the bot breaks the door (health %d)" % _state().gate_health):
		return
	var told: bool = await _wait_until(func() -> bool: return view.is_gate_broken())
	assert_true(told, "and its SiegeView sees it through the FortressView")
	var inside: bool = await _wait_until(func() -> bool: return _state().presence[VARDHEIM] == 1)
	assert_true(inside, "it enters the circle crossing the broken door")
	_server.console_command("fort_capture_speed 30")
	_server.console_command("fort_kill_captain")
	var captured: bool = await _wait_until(func() -> bool: return _state().owner == VARDHEIM)
	assert_true(captured, "and captures the fort")
	assert_eq(int(_client.get_stats()["malformed_packets"]), 0, "no malformed packets")
	assert_eq(int(_client.get_stats()["hard_resets"]), 0, "no hard prediction resets")


func test_the_siege_brain_is_a_valid_bot_brain_option() -> void:
	var config: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bots=4", "--bot-brain=Siege"]))
	assert_eq(config.bot_brain, ClientConfig.BOT_BRAIN_SIEGE, "--bot-brain=siege (case-insensitive)")
	assert_eq(config.mode, ClientConfig.Mode.SWARM)
	assert_true(config.warnings.is_empty())
	var bot: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bot", "--bot-brain=siege"]))
	assert_eq(bot.bot_brain, ClientConfig.BOT_BRAIN_SIEGE)
	assert_eq(bot.mode, ClientConfig.Mode.BOT)
	var wrong: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bots=2", "--bot-brain=asediar"]))
	assert_eq(wrong.bot_brain, "", "an unknown brain is ignored with a warning")
	assert_false(wrong.warnings.is_empty())
