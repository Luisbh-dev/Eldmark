extends TestCase
## The siege with the real NPCs (F6b; GUE-15, MUN-10, MUN-11; docs/fortress.md, sections 7 and 8.3): fake players with
## the siege brain ([constant BotBrain.Pattern.SIEGE]) break the neutral fort's door in Vado Gris, kill
## the Hollow and the Ford Captain all by themselves (without [code]fort_kill_captain[/code]) and capture it, leaving the zone
## of the Captain's unblockable strike when it warns of it (TELEGRAPH). It is the short version of
## [code]tools/war/siege_battle.gd --npcs[/code]: so that it fits in the suite, the bots start in front of the door,
## the capture runs x30 (command 11) and the NPCs have less health, only on this server
## ([method SiegeRunner.set_npc_health]; the [code]data/npcs/[/code] data does not change).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
## Siege bots, and NPC health in this test (the real one: Captain 30,000, Hollow 2500).
const BOTS: int = 12
const CAPTAIN_HEALTH: int = 9000
const HOLLOW_HEALTH: int = 1000
## In front of the door, on the esplanade (the door is at x = -20 and the fort toward +X).
const START: Vector3 = Vector3(-27.0, 10.3, 0.0)

var _runner: SiegeRunner = null
var _evading: Dictionary[int, bool] = {}
var _unblockable_hits: int = 0
var _unblockable_on_evading: int = 0
var _telegraphs: int = 0


func before_each() -> void:
	_runner = SiegeRunner.new()
	tree.root.add_child(_runner)
	assert_true(await _runner.start(tree.root, "", 64, true), "the server starts on Vado Gris with its NPCs")
	assert_true(_runner.set_npc_health(&"ford_captain", CAPTAIN_HEALTH), "Captain weaker in this test")
	assert_true(_runner.set_npc_health(&"hollow", HOLLOW_HEALTH), "and Hollow")
	_evading.clear()
	_unblockable_hits = 0
	_unblockable_on_evading = 0
	_telegraphs = 0


func after_each() -> void:
	if is_instance_valid(_runner):
		_runner.finish()
		_runner.get_parent().remove_child(_runner)
		_runner.free()
	_runner = null
	await wait_process_frames()


func test_bots_capture_the_neutral_fort_killing_the_real_npcs_without_commands() -> void:
	var system: NpcSpawnerSystem = _runner.server.get_npc_system()
	if not assert_not_null(system, "with NPCs"):
		return
	var ids: Array[int] = _runner.add_siege_bots(VARDHEIM, BOTS, 40)
	assert_eq(ids.size(), BOTS)
	for index: int in ids.size():
		_runner.server.teleport(ids[index], START + Vector3(-float(index % 4), 0.0, float(index / 4) - 1.0))
	_runner.set_capture_speed(30)
	_runner.server.get_combat().event_emitted.connect(_on_combat_event)
	_runner.server.tick_finished.connect(_on_tick)
	var state: FortressState = _runner.state()
	var captured: int = await _runner.advance_until(func() -> bool: return state.owner == VARDHEIM, 6000)
	var captain_down: int = _runner.tick_of_war(WarEvents.CAPTAIN_DOWN)
	print("[siege-npcs] puerta rota %.1f s, capitán caído %.1f s, capturado %.1f s; PNJ muertos %s; golpes avisados %d, imbloqueables que dan %d (%d a quien salía)" % [
		SiegeRunner.seconds(_runner.tick_of_war(WarEvents.GATE_BROKEN)), SiegeRunner.seconds(captain_down),
		SiegeRunner.seconds(_runner.tick_of_war(WarEvents.FORT_CAPTURED)), _npc_death_counts(),
		_telegraphs, _unblockable_hits, _unblockable_on_evading])
	if not assert_true(captured >= 0, "Vardheim captures the neutral fort (phase %d, owner %d)" % [state.phase, state.owner]):
		return
	var ids_of_war: Array[int] = _runner.war_ids()
	assert_true(ids_of_war.find(WarEvents.GATE_BROKEN) < ids_of_war.find(WarEvents.CAPTAIN_DOWN),
			"they break the door before killing the captain: %s" % [ids_of_war])
	assert_true(ids_of_war.find(WarEvents.CAPTAIN_DOWN) < ids_of_war.find(WarEvents.FORT_CAPTURED), "and kill it before capturing")
	var deaths: Dictionary = _npc_death_counts()
	assert_eq(int(deaths.get(&"ford_captain", 0)), 1, "the Ford Captain dies at the hands of the bots")
	assert_true(int(deaths.get(&"hollow", 0)) >= 4, "and the four Hollow (plus the reinforcements): %s" % [deaths])
	for event: NetMessages.EntityEvent in _runner.war_events:
		if event.war_event == WarEvents.CAPTAIN_DOWN:
			assert_eq(event.war_realm, VARDHEIM, "Vardheim killed it, not a command")
	# The unblockable strike: they leave its zone as soon as it warns of it, and those who were leaving do not eat it.
	assert_true(_telegraphs > 0, "the Captain warns of its heavy attacks")
	assert_true(_evading.size() > 0, "some bot leaves the zone of a warned strike")
	assert_eq(_unblockable_on_evading, 0, "none of those who were leaving eats the unblockable strike")


# Each tick, who is leaving the zone of a warned strike.
func _on_tick(_tick: int) -> void:
	for net_id: int in _runner.bots:
		var brain: BotBrain = _runner.get_brain(net_id)
		if brain != null and brain.get_siege_task() == BotBrain.SiegeTask.EVADE:
			_evading[net_id] = true


# The unblockable strikes (the Captain's) that hit a bot, and how many of those who were leaving.
func _on_combat_event(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
	if event.event == NetMessages.EntityEvent.Kind.TELEGRAPH:
		_telegraphs += 1
	if event.event != NetMessages.EntityEvent.Kind.HIT or not _runner.bots.has(event.net_id):
		return
	var attack: AttackTicks = CombatCatalog.attack(event.attack_id)
	if attack == null or not attack.unblockable:
		return
	_unblockable_hits += 1
	var brain: BotBrain = _runner.get_brain(event.net_id)
	if brain != null and brain.get_siege_task() == BotBrain.SiegeTask.EVADE:
		_unblockable_on_evading += 1


func _npc_death_counts() -> Dictionary:
	var counts: Dictionary = {}
	for death: Dictionary in _runner.npc_deaths:
		counts[death["npc"]] = int(counts.get(death["npc"], 0)) + 1
	return counts
