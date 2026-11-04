extends TestCase
## Reconciliation in a melee with a bad network (TEC-15; docs/combate.md, sections 1 and 3.4): four
## combat bots ([code]--bot-brain=combat[/code], two per realm) fight each other with real ENet over
## 127.0.0.1 and a [NetSim] of 120 ms RTT, 20 ms jitter and 5 % loss on each.
## [br][br]
## The server imposes states that the client does not predict (stagger, stun, knockback, death,
## respawn, the stamina that a blocked hit spends). Each of them forces a correction of the
## prediction of the one who suffers it, and that correction is [i]expected[/i]: the
## [NetClient] has to explain it (an own combat event on those ticks), not count it as a prediction failure. What
## is checked:
## [br]- there are corrections (the real melee changes the state) and all are explained by a
## substituted input, a teleport or an own combat event;
## [br]- no hard reset or [TickSync] resync because of combat;
## [br]- when they stand still, the state predicted for the server's last tick is bit-for-bit identical
## to the server's (convergence).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900
## Network simulator of each bot (the seed is added to the bot's index so they do not lose the same packets).
const NET_SIM: String = "rtt=120,jitter=20,loss=5,seed=%d"
## Ticks they fight and idle ticks at the end (more than it takes for the current action to finish and for
## the last snapshot to arrive).
const FIGHT_TICKS: int = 900
const IDLE_TICKS: int = 180

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _clients: Array[NetClient] = []
var _viewports: Array[SubViewport] = []


func before_each() -> void:
	_root = Node.new()
	_root.name = "CombatReconciliation"
	tree.root.add_child(_root)


func after_each() -> void:
	for viewport: SubViewport in _viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_viewports.clear()
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


# --- Test -------------------------------------------------------------------------------------

func test_a_brawl_of_combat_bots_over_a_bad_network_is_explained_and_converges() -> void:
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = port
	config.zone_id = ZONE_ID
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	var realms: Array[int] = [VARDHEIM, SOLMARCH, VARDHEIM, SOLMARCH, VARDHEIM, SOLMARCH]
	for index: int in realms.size():
		var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
		_viewports.append(viewport)
		_clients.append(NetHarness.start_bot(viewport, port, realms[index], index + 1,
				NET_SIM % (7 * (index + 1)), "", ClientConfig.BOT_BRAIN_COMBAT))
	if not assert_true(await _wait_until(_all_in_world), "the four bots enter"):
		return
	await wait_physics_frames(60)
	# I run: two against two, a couple of meters apart.
	var spots: Array[Vector3] = [Vector3(-2.0, 0.05, 0.0), Vector3(2.0, 0.05, 0.0),
			Vector3(-2.0, 0.05, 3.0), Vector3(2.0, 0.05, 3.0), Vector3(-2.0, 0.05, 6.0),
			Vector3(2.0, 0.05, 6.0)]
	for index: int in _clients.size():
		_server.teleport(_clients[index].get_net_id(), spots[index])
	await wait_physics_frames(FIGHT_TICKS)

	var combat: Dictionary = _server.get_combat().stats
	print("[refriega] golpes %d, bloqueados %d, paradas %d, rotura de guardia %d, muertes %d, eventos %d" % [
			combat[&"hits"], combat[&"blocked"], combat[&"parried"], combat[&"guard_breaks"],
			combat[&"deaths"], combat[&"events"]])
	assert_true(combat[&"hits"] >= 10, "they really fight (%d hits)" % combat[&"hits"])
	for client: NetClient in _clients:
		var stats: Dictionary = client.get_stats()
		print("[refriega] %s: diffs %d, explicadas %d, de combate %d, sin explicar %d, correcciones %d, "
				% [client.get_config().display_name, stats["diffs"], stats["explained_diffs"],
				stats.get("combat_diffs", -1), stats["unexplained_diffs"], stats["corrections"]]
				+ "reinicios duros %d, resincronizaciones %d, sustituciones %d" % [stats["hard_resets"],
				stats["resyncs"], stats["substitutions_total"]])

	# Idle: wait for whatever they had going to finish and for the server and client to agree.
	for client: NetClient in _clients:
		var brain: BotBrain = client.get_meta(&"bot_brain") as BotBrain
		brain.set_idle_from(client.get_prediction().get_predicted_tick() + 1)
	await wait_physics_frames(IDLE_TICKS)

	var any_combat_correction: bool = false
	for client: NetClient in _clients:
		var name: String = client.get_config().display_name
		var stats: Dictionary = client.get_stats()
		assert_eq(client.get_state(), NetClient.State.IN_WORLD, "%s: still in the world" % name)
		assert_eq(stats["unexplained_diffs"], 0,
				"%s: every correction is explained by a substitution, a teleport or combat: %s"
				% [name, stats])
		assert_eq(stats["hard_resets"], 0, "%s: no hard reset" % name)
		assert_eq(stats["resyncs"], 0, "%s: no resync" % name)
		if int(stats.get("combat_diffs", 0)) > 0:
			any_combat_correction = true
		var server_state: PlayerState = client.get_last_server_state()
		var predicted: PlayerState = client.get_prediction().get_predicted_state(client.get_last_snapshot_tick())
		if assert_not_null(server_state, "%s: received its state" % name) \
				and assert_not_null(predicted, "%s: stores what it predicted" % name):
			assert_true(predicted.equals_exact(server_state),
					"%s: exact convergence with the server when standing still" % name)
	assert_true(any_combat_correction, "some correction was caused by a hit (combat explains itself)")
