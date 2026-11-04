extends TestCase
## Tests of [OnlineMain] (docs/red.md, 1.2 and 17.5) against a real [ZoneServer] in the same process:
## the whole scene, with the zone loaded in a thread, and the shutdown via [code]--quit-after-ticks[/code]
## (which here does not close the process: [member OnlineMain.quit_hook] collects the exit code).
## [br]- Normal client: camera, HUD and animated humanoid on spawn, and the loading screen gone.
## [br]- Bot: no camera or HUD, report when finished, standing still at the end and exit code 0.
## [br]- Rejection, server shutdown and unknown zone: exit code 1 and a report.
## [br]- The [code]progress[/code] scenario ([BotProgressScenario], progresion.md §15 P8): equips the bow,
## gives gold and a potion, rewrites the report at each step and exits with 0 and its progress in the
## report; if a step is not fulfilled, code 1 and the reason in the report.

const ONLINE_MAIN_SCENE: String = "res://scenes/client/online_main.tscn"
const REPORT_FILE: String = "test_online_main_report.json"
const WAIT_FRAMES: int = 900

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _online: OnlineMain
var _port: int = 0
var _exit_codes: Array[int] = []
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_max_fps: int = 0


func before_each() -> void:
	_saved_config = OnlineMain.config
	_saved_hook = OnlineMain.quit_hook
	_saved_max_fps = Engine.max_fps
	_exit_codes.clear()
	OnlineMain.quit_hook = func(code: int) -> void: _exit_codes.append(code)
	DirAccess.remove_absolute(NetHarness.build_path(REPORT_FILE))
	_root = Node.new()
	_root.name = "OnlineMainTest"
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_online):
		_online.get_parent().remove_child(_online)
		_online.free()
	_online = null
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	OnlineMain.config = _saved_config
	OnlineMain.quit_hook = _saved_hook
	Engine.max_fps = _saved_max_fps
	await wait_process_frames(2)


# --- Helpers ----------------------------------------------------------------------------------

## Server with the real test_world zone listening on a free port.
func _start_server(zone_id: String = "test_world", max_players: int = 8, debug_commands: bool = false) -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, NetZones.scene_path("test_world"))
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = zone_id
	config.max_players = max_players
	config.debug_commands = debug_commands
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)


## Networked client with the real scene.
func _start_online(mode: ClientConfig.Mode, configure: Callable = Callable()) -> void:
	var config := ClientConfig.new()
	config.mode = mode
	config.port = _port
	config.realm = NetProtocol.Realm.SOLMARCH
	config.display_name = "Ana"
	config.bot_seed = 3
	config.report_path = NetHarness.build_path(REPORT_FILE)
	if configure.is_valid():
		configure.call(config)
	OnlineMain.config = config
	var packed: PackedScene = load(ONLINE_MAIN_SCENE) as PackedScene
	_online = packed.instantiate() as OnlineMain
	tree.root.add_child(_online)


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _in_world() -> bool:
	return _online.get_client().get_state() == NetClient.State.IN_WORLD


func _exited() -> bool:
	return not _exit_codes.is_empty()


# --- Tests ------------------------------------------------------------------------------------

func test_human_client_loads_the_zone_and_mounts_camera_hud_and_visual() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.ONLINE)
	var client: NetClient = _online.get_client()
	assert_true(await _wait_until(_in_world), "gets into the world (state %s)"
			% NetClient.State.keys()[client.get_state()])
	var world: Node3D = _online.get_world()
	if not assert_not_null(world, "the zone was loaded"):
		return
	assert_eq(world.name, "TestWorld", "the one from the WELCOME")
	var character: PlayerCharacter = client.get_character()
	assert_not_null(character)
	assert_not_null(_online.get_camera_rig(), "with an action camera")
	assert_not_null(_online.get_hud(), "and HUD")
	assert_null(_online.get_bot_brain(), "and without a bot brain")
	var visual: HumanoidVisual = character.get_node_or_null(^"Visual/HumanoidVisual") \
			as HumanoidVisual
	assert_not_null(visual, "with the animated humanoid")
	for child: Node in character.get_node(^"Visual").get_children():
		assert_false(child is MeshInstance3D, "and without the provisional capsule")
	var overlay: CanvasLayer = _online.get_node(^"Overlay") as CanvasLayer
	assert_false(overlay.visible, "the loading screen is removed on spawn")
	assert_eq(_server.get_player_count(), 1)
	# A few seconds of play: the prediction matches the server.
	await wait_physics_frames(90)
	var stats: Dictionary = client.get_stats()
	assert_eq(stats["unexplained_diffs"], 0, "%s" % [stats])
	assert_true(stats["matches"] > 20)
	assert_true(_exit_codes.is_empty())


func test_bot_has_no_camera_and_finishes_with_a_report_and_code_zero() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.quit_after_ticks = 300)
	assert_true(await _wait_until(_in_world))
	assert_null(_online.get_camera_rig(), "a bot has no camera")
	assert_null(_online.get_hud(), "nor HUD")
	assert_not_null(_online.get_bot_brain(), "but it does have a brain")
	assert_false(_online.has_node(^"Overlay"), "nor screens")
	assert_true(await _wait_until(_exited), "on reaching --quit-after-ticks it closes")
	assert_eq(_exit_codes, [0] as Array[int], "with code 0, only once")
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	assert_eq(report.get("name"), "Ana")
	assert_eq(report.get("mode"), "BOT")
	assert_eq(report.get("zone"), "test_world")
	assert_eq(report.get("rejected"), false)
	assert_eq(report.get("state"), "IN_WORLD", "the report is written before leaving the zone")
	assert_eq(int(report.get("unexplained_diffs", -1)), 0)
	assert_true(int(report.get("matches", 0)) > 50)
	var final_state: Dictionary = report.get("final", {})
	assert_true(bool(final_state.get("exact", false)))
	var velocity: Array = final_state.get("velocity", [1.0, 1.0, 1.0])
	assert_vec_near(Vector3(velocity[0], velocity[1], velocity[2]), Vector3.ZERO, 0.001,
			"the bot ends standing still")
	# Leaves the zone with CLIENT_LEAVE: the server is left without players.
	assert_true(await _wait_until(func() -> bool: return _server.get_player_count() == 0),
			"the server removes the bot that leaves")


func test_the_bot_brain_follows_bot_brain_and_bot_cheat() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.bot_brain = ClientConfig.BOT_BRAIN_COMBAT)
	assert_true(await _wait_until(_in_world))
	var brain: BotBrain = _online.get_bot_brain()
	if assert_not_null(brain, "with a brain"):
		assert_eq(brain.get_pattern(), BotBrain.Pattern.COMBAT, "--bot-brain=combat fights")
		assert_true(brain.has_enemy_finder(), "and knows how to look for enemies")


func test_a_combat_cheat_mode_gives_the_bot_the_cheaters_brain() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.bot_cheat = BotCheater.MODE_REACH)
	assert_true(await _wait_until(_in_world))
	var brain: BotBrain = _online.get_bot_brain()
	if assert_not_null(brain):
		assert_true(brain is BotCheatBrain, "--bot-cheat=reach uses the cheater's brain")
		assert_true(brain.has_enemy_finder())


# Phase 4 (war) revision: the dead bot asks to respawn as soon as it can, like someone pressing the button (without
# asking it would wait for the automatic respawn; with waves, that took it out of its own).
func test_a_dead_bot_asks_for_its_respawn_as_soon_as_it_can() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT)
	assert_true(await _wait_until(_in_world))
	var client: NetClient = _online.get_client()
	var combatant: Combatant = _server.get_combat().get_combatant(client.get_net_id())
	if not assert_not_null(combatant):
		return
	var timing: CombatTiming = _server.get_combat_timing()
	timing.respawn = 60
	timing.auto_respawn = 100000
	_server.get_combat().kill(combatant, _server.get_tick() + 1)
	assert_true(await _wait_until(func() -> bool: return client.is_dead(), 120), "the bot knows it is dead")
	var back: bool = await _wait_until(func() -> bool: return combatant.is_alive(), 400)
	assert_true(back, "it respawns when asked, well before the automatic one")
	assert_true(int(client.get_stats()["respawn_requests"]) >= 1, "with its RESPAWN_REQUEST")
	assert_eq(_server.get_combat().stats[&"respawns"], 1)
	await wait_physics_frames(90)
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_eq(peer.strikes_total, 0, "neither too early nor too much: no warning from the server")


func test_the_default_bot_brain_wanders() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT)
	assert_true(await _wait_until(_in_world))
	var brain: BotBrain = _online.get_bot_brain()
	if assert_not_null(brain):
		assert_eq(brain.get_pattern(), BotBrain.Pattern.WANDER)
		assert_false(brain is BotCheatBrain)


func test_rejection_ends_with_code_one_and_the_reason_in_the_report() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.display_name = "ab"
		config.quit_after_ticks = 600)
	assert_true(await _wait_until(_exited), "it closes")
	assert_eq(_exit_codes, [1] as Array[int])
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	assert_eq(report.get("rejected"), true)
	assert_eq(int(report.get("reject_result", 0)), NetProtocol.Result.NAME)
	assert_eq(report.get("reject_text"), NetProtocol.result_text(NetProtocol.Result.NAME))
	assert_eq(_server.get_player_count(), 0)


func test_server_shutdown_ends_with_code_one_and_keeps_the_report() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.quit_after_ticks = 3000)
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(60)
	_server.stop("Cierre de prueba")
	assert_true(await _wait_until(_exited), "it closes when the server leaves")
	assert_eq(_exit_codes, [1] as Array[int])
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	assert_eq(report.get("disconnect_text"), "Cierre de prueba")
	assert_eq(report.get("state"), "CLOSED")
	assert_true(int(report.get("matches", 0)) > 10, "with what was lived up to then")


func test_unknown_zone_from_the_server_ends_with_code_one() -> void:
	await _start_server("zona_que_no_existe")
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.quit_after_ticks = 600)
	assert_true(await _wait_until(_exited), "there is no zone to load: it closes")
	assert_eq(_exit_codes, [1] as Array[int])
	assert_true(await _wait_until(func() -> bool: return _server.get_player_count() == 0, 120),
			"and it is not recorded on the server")


func test_quit_after_ticks_without_entering_the_world_is_a_failure() -> void:
	# Without a server to reach: the tick limit arrives before the connection failure.
	_port = NetHarness.free_udp_port()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.quit_after_ticks = 30)
	assert_true(await _wait_until(_exited, 300))
	assert_eq(_exit_codes, [1] as Array[int], "not getting into the zone is a failure")
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	assert_eq(report.get("state"), "CONNECTING")


func test_the_progress_scenario_equips_the_bow_gives_gold_and_a_potion_and_leaves() -> void:
	await _start_server("test_world", 8, true)
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.realm = NetProtocol.Realm.VARDHEIM
		config.bot_scenario = ClientConfig.BOT_SCENARIO_PROGRESS)
	assert_true(await _wait_until(func() -> bool: return _online.get_bot_scenario() != null), "it appears with the scenario")
	var scenario: BotProgressScenario = _online.get_bot_scenario()
	# Each step rewrites the report: it is read right afterward (OnlineMain writes it earlier, it connected first).
	var phases: Array[String] = []
	scenario.phase_completed.connect(func(_phase: String) -> void:
		var interim: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
		phases.append(str((interim.get("scenario", {}) as Dictionary).get("phase", ""))))
	var net_id: int = _online.get_client().get_net_id()
	var server_record: Array[ProgressRecord] = []
	var gold_given: bool = await _wait_until(func() -> bool:
		var player: PlayerProgress = _server.get_progress().get_player(net_id)
		if player != null:
			server_record.assign([player.record.duplicate_record()])
		return scenario.get_phase() == "gold", 900)
	assert_true(gold_given, "it manages to give the gold")
	assert_true(await _wait_until(_exited, 900), "and on finishing it exits")
	assert_eq(_exit_codes, [0] as Array[int], "with code 0")
	assert_eq(phases, ["equip", "gold", "potion", "done"] as Array[String], "the report, rewritten after each step")
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	var summary: Dictionary = report.get("scenario", {})
	assert_eq([summary.get("phase"), summary.get("error"), summary.get("completed")],
			["done", "", ["equip", "gold", "potion", "done"]], "the whole scenario, without error")
	assert_eq(summary.get("bow_slot"), [1.0, 1.0], "the bow, in WEAPON_2 (in JSON, numbers)")
	assert_false(bool(summary.get("already_equipped", true)), "he equipped it himself (the squire carries it in the bag)")
	var progress: Dictionary = report.get("progress", {})
	var by_slot: Dictionary = {}
	var potions: int = 0
	for item: Dictionary in progress.get("items", []):
		by_slot["%d:%d" % [int(item["container"]), int(item["slot"])]] = item["def_id"]
		if item["def_id"] == "potion_health":
			potions += int(item["count"])
	assert_eq([by_slot.get("1:0"), by_slot.get("1:1")], ["sword_shield_vado", "bow_vado"], "the report's equipment")
	assert_eq(potions, 4, "the three from the kit and the given one")
	assert_eq(progress.get("wallets"), [{"currency": 1.0, "balance": 50.0}, {"currency": 2.0, "balance": 0.0}],
			"and the balances")
	assert_eq(int(progress.get("active_weapon_slot", -1)), 0, "with the sword in hand")
	assert_eq(int(progress.get("pending", -1)), 0, "without requests in flight")
	if assert_eq(server_record.size(), 1, "the server had its record"):
		assert_eq(server_record[0].wallets[Currency.Code.GOLD], 50, "with the gold given")
	assert_true(await _wait_until(func() -> bool: return _server.get_player_count() == 0), "leaves the zone")


func test_a_progress_scenario_step_that_never_happens_ends_with_code_one() -> void:
	# Without --debug-commands in the zone, the gold never arrives.
	await _start_server()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.realm = NetProtocol.Realm.VARDHEIM
		config.bot_scenario = ClientConfig.BOT_SCENARIO_PROGRESS)
	assert_true(await _wait_until(func() -> bool: return _online.get_bot_scenario() != null))
	_online.get_bot_scenario().step_timeout_ticks = 90
	assert_true(await _wait_until(_exited, 900), "it closes")
	assert_eq(_exit_codes, [1] as Array[int], "with code 1")
	var summary: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE)).get("scenario", {})
	assert_eq(summary.get("phase"), "equip", "the bow does")
	assert_true(str(summary.get("error", "")).contains("«gold»"), "and the reason: %s" % summary.get("error"))
