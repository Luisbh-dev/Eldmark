extends TestCase
## Reconciliation with the whole phase-4 kit and a bad network (H5; docs/abilities.md, sections 6.1 and 7.3; the
## acceptance of phase 2): three combat bots ([code]--bot-brain=combat[/code], with the [BotBrain] kit) with
## both templates, real ENet over 127.0.0.1 and a [NetSim] of 120 ms RTT, 20 ms jitter and 5 % loss
## on the server (in both directions): a wounded archer and a Vardheim squire against a Solmarch
## archer.
## [br][br]
## Over 900 ticks of fighting they use abilities (shield bash, charge, wall, fan, weighted arrow, backflip),
## swap weapons, drink potions, fire arrows, get slowed and someone gets knocked down. The server
## imposes what the client does not predict (hits received, movement effects, knockdowns, getting up and finishing off,
## LOADOUT), and every correction has to be explained by the [NetClient]: a replaced input, a teleport or an
## own combat event. As in test_combat_reconciliation, the test checks:
## [br]- everything above really happened, and is counted on the [b]server[/b] (H5 review: the bot's
## counters only say what it tried to press): abilities, weapon swaps and sips that the server state
## starts, ability hits, heals and the HIT with bit 6 that knocks down. If halfway through the fight nobody has been
## slowed, the server slows the Solmarch one (like command 14) and, if nobody has fallen, leaves it with 1 health and
## no health potions (with its LOADOUT, like command 16) so the next hit knocks it down; only if at five
## sixths it still has not fallen does the server knock it down itself (like 15). That is server state all the same: what is tested is that the client explains it and converges;
## [br]- no unexplained correction, no hard reset or resync;
## [br]- once they stand still for 180 ticks, the state predicted for the server's last tick is bit-for-bit identical
## to the server's (convergence), also for the one who is knocked down.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900
## Network simulator, on the server (in both directions and for all three bots): the rewind cap counts the
## delay added by the server's simulator and not that of a client (docs/networking.md, section 10), so with the
## simulator on each bot the server rejected their rewinds and their arrows came out harmless.
const NET_SIM: String = "rtt=120,jitter=20,loss=5,seed=7"
const FIGHT_TICKS: int = 900
const IDLE_TICKS: int = 180
## Health the Vardheim archer starts with (drinks right away).
const WOUNDED_HEALTH: int = 450

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _clients: Array[NetClient] = []
var _viewports: Array[SubViewport] = []
# Server events per class (and the slow STATUSes apart).
var _events: Dictionary[int, int] = {}
var _slowed: int = 0
var _ability_hits: int = 0
var _downing_hits: int = 0


func before_each() -> void:
	_root = Node.new()
	_root.name = "AbilitiesReconciliation"
	tree.root.add_child(_root)
	_events.clear()
	_slowed = 0
	_ability_hits = 0
	_downing_hits = 0


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


func _on_event(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
	_events[event.event] = _events.get(event.event, 0) + 1
	if event.event == NetMessages.EntityEvent.Kind.STATUS and event.status_id == CombatCatalog.status_id(&"slowed") \
			and event.op == NetMessages.EntityEvent.StatusOp.APPLIED:
		_slowed += 1
	if event.event == NetMessages.EntityEvent.Kind.HIT \
			and CombatSource.kind_of(event.get_source()) == CombatSource.Kind.ABILITY:
		_ability_hits += 1
	if event.event == NetMessages.EntityEvent.Kind.HIT \
			and (event.hit_flags & NetMessages.EntityEvent.HIT_FLAG_DOWNED) != 0:
		_downing_hits += 1


# Counts the actions that each bot's server state has started since the last tick: abilities (not
# consumables), weapon swaps and sips (a new action is an action and start-tick pair that differs).
func _count_server_starts(starts: Dictionary[StringName, int], last: Dictionary[int, Vector2i]) -> void:
	for client: NetClient in _clients:
		var entity: NetEntity = _server.get_registry().get_entity(client.get_net_id())
		if entity == null or entity.get_character() == null:
			continue
		var combat: CombatState = entity.get_character().combat
		var now := Vector2i(combat.action, combat.action_tick)
		if last.get(client.get_net_id(), Vector2i(-1, -1)) == now:
			continue
		last[client.get_net_id()] = now
		if combat.action == CombatState.Action.SWAP:
			starts[&"swap"] += 1
		elif combat.action == CombatState.Action.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(combat.action_id)
			if ability != null:
				starts[&"drink" if ability.is_consumable() else &"ability"] += 1


func test_a_fight_with_every_ability_over_a_bad_network_is_explained_and_converges() -> void:
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = port
	config.zone_id = ZONE_ID
	config.max_players = 8
	config.net_sim_spec = NET_SIM
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	_server.get_combat().event_emitted.connect(_on_event)
	var bots: Array[Array] = [[VARDHEIM, "marksman"], [VARDHEIM, "squire"], [SOLMARCH, "marksman"]]
	for index: int in bots.size():
		var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
		_viewports.append(viewport)
		_clients.append(NetHarness.start_bot(viewport, port, bots[index][0], index + 11, "", "",
				ClientConfig.BOT_BRAIN_COMBAT, bots[index][1]))
	if not assert_true(await _wait_until(_all_in_world), "all three bots join"):
		return
	await wait_physics_frames(60)
	var spots: Array[Vector3] = [Vector3(-10.0, 0.05, 3.0), Vector3(0.0, 0.05, 0.0), Vector3(8.0, 0.05, 0.0)]
	for index: int in _clients.size():
		_server.teleport(_clients[index].get_net_id(), spots[index])
	# The Vardheim archer starts wounded: it drinks right away.
	var wounded: Combatant = _server.get_combat().get_combatant(_clients[0].get_net_id())
	wounded.take_damage(wounded.health - WOUNDED_HEALTH, _server.get_tick())
	# Fallback so the test always tests the same thing: if halfway through the fight nobody has been slowed, the
	# server slows the Solmarch one (like command 14); if nobody has fallen, it leaves it with 1 health and no health
	# potions (the next enemy hit knocks it down, and it cannot heal) and, if at five sixths it is still standing, it
	# knocks it down (like command 15). All of it is state imposed by the server and the client has to explain it the same way.
	var lonely: Combatant = _server.get_combat().get_combatant(_clients[2].get_net_id())
	var nudged: PackedStringArray = PackedStringArray()
	# What each bot's server state starts (not what the bot tried to press).
	var server_starts: Dictionary[StringName, int] = {&"ability": 0, &"swap": 0, &"drink": 0}
	var last_start: Dictionary[int, Vector2i] = {}
	var downs: Dictionary[StringName, int] = _server.get_combat().downed.stats
	for frame: int in FIGHT_TICKS:
		await tree.physics_frame
		_count_server_starts(server_starts, last_start)
		if frame == FIGHT_TICKS / 2 and _slowed == 0 and lonely.is_alive():
			_server.get_combat().apply_status(lonely, CombatCatalog.status_id(&"slowed"), _server.get_tick() + 1)
			nudged.append("ralentización")
		if frame == FIGHT_TICKS / 2 and downs[&"downs"] == 0 and lonely.is_alive():
			lonely.take_damage(lonely.health - 1, _server.get_tick())
			var lonely_combat: CombatState = lonely.get_character().combat
			ActionMachine.set_charges(lonely_combat, CombatState.pack_charges(0, lonely_combat.charges_of(1)))
			CombatDirector.commit_state(lonely.get_character())
			_server.get_combat().announce_loadout(lonely, _server.get_tick(), false)
			nudged.append("1 de vida")
		if frame == FIGHT_TICKS * 5 / 6 and downs[&"downs"] == 0 and lonely.is_alive():
			_server.get_combat().down(lonely, _server.get_tick() + 1)
			nudged.append("derribo")
	print("[kit en red] impuesto por la prueba: %s; empezado en el servidor %s; HIT que derriban %d" % [
			nudged if not nudged.is_empty() else "nada", server_starts, _downing_hits])

	var counts: Dictionary[StringName, int] = {}
	for client: NetClient in _clients:
		var brain: BotBrain = client.get_meta(&"bot_brain") as BotBrain
		var kit: Dictionary[StringName, int] = brain.get_kit_counts()
		for key: StringName in kit:
			counts[key] = counts.get(key, 0) + kit[key]
		var stats: Dictionary = client.get_stats()
		print("[kit en red] %s: kit %s; diffs %d, explicadas %d, de combate %d, sin explicar %d, correcciones %d, "
				% [client.get_config().display_name, kit, stats["diffs"], stats["explained_diffs"],
				stats["combat_diffs"], stats["unexplained_diffs"], stats["corrections"]]
				+ "reinicios duros %d, sustituciones %d" % [stats["hard_resets"], stats["substitutions_total"]])
	var combat: CombatDirector = _server.get_combat()
	print("[kit en red] servidor: golpes %d (de habilidad %d), flechas %d, ralentizaciones %d, curaciones %d, derribos %d, eventos %s" % [
			combat.stats[&"hits"], _ability_hits, combat.projectiles.stats[&"projectiles_fired"], _slowed,
			combat.stats[&"heals"], combat.downed.stats[&"downs"], _events])
	print("[kit en red] proyectiles %s; combate %s" % [combat.projectiles.stats, combat.stats])
	# What the server did, not what the bot tried to press.
	assert_true(server_starts[&"ability"] >= 3, "the server casts abilities (%d)" % server_starts[&"ability"])
	assert_true(_ability_hits >= 1, "and some of them land (%d ability hits)" % _ability_hits)
	assert_true(server_starts[&"swap"] >= 1, "the server swaps weapons (%d)" % server_starts[&"swap"])
	assert_true(server_starts[&"drink"] >= 1, "the server drinks (%d)" % server_starts[&"drink"])
	assert_true(_events.get(NetMessages.EntityEvent.Kind.HEAL, 0) >= 1,
			"and the potion heals (%d HEAL)" % _events.get(NetMessages.EntityEvent.Kind.HEAL, 0))
	assert_true(combat.projectiles.stats[&"projectiles_fired"] >= 5,
			"they fire arrows (%d)" % combat.projectiles.stats[&"projectiles_fired"])
	assert_true(_slowed >= 1, "someone gets slowed (%d)" % _slowed)
	assert_true(combat.downed.stats[&"downs"] >= 1, "someone gets knocked down (%d)" % combat.downed.stats[&"downs"])
	assert_true(_downing_hits >= 1 or nudged.has("derribo"),
			"by a hit (HIT with bit 6: %d), unless the fallback was needed" % _downing_hits)
	assert_true(combat.stats[&"hits"] >= 10, "and they really fight (%d hits)" % combat.stats[&"hits"])

	# Standing still: wait for whatever they had in progress to finish and for the server and client to agree.
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
				"%s: every correction is explained by a replacement, a teleport or combat: %s" % [name, stats])
		assert_eq(stats["hard_resets"], 0, "%s: no hard reset" % name)
		assert_eq(stats["resyncs"], 0, "%s: no resync" % name)
		if int(stats.get("combat_diffs", 0)) > 0:
			any_combat_correction = true
		var server_state: PlayerState = client.get_last_server_state()
		var predicted: PlayerState = client.get_prediction().get_predicted_state(client.get_last_snapshot_tick())
		if assert_not_null(server_state, "%s: received its state" % name) \
				and assert_not_null(predicted, "%s: keeps what it predicted" % name):
			assert_true(predicted.equals_exact(server_state),
					"%s: exact convergence with the server when standing still (action %d)" % [name,
					server_state.combat.action])
	assert_true(any_combat_correction, "some correction was caused by combat (it explains itself)")
