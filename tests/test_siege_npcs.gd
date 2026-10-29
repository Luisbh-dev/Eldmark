extends TestCase
## El asedio con los PNJ de verdad (F6b; GUE-15, MUN-10, MUN-11; docs/fuerte.md, secciones 7 y 8.3): jugadores falsos con
## el cerebro de asedio ([constant BotBrain.Pattern.SIEGE]) rompen la puerta del fuerte neutral del Vado Gris, matan a
## los Huecos y al Capitán del Vado ellos solos (sin [code]fort_kill_captain[/code]) y lo capturan, saliendo de la zona
## del golpe imbloqueable del Capitán cuando lo avisa (TELEGRAPH). Es la versión corta de
## [code]tools/war/siege_battle.gd --npcs[/code]: para que quepa en la suite, los bots empiezan delante de la puerta,
## la captura va x30 (orden 11) y los PNJ tienen menos vida, solo en este servidor
## ([method SiegeRunner.set_npc_health]; los datos de [code]data/npcs/[/code] no cambian).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
## Bots del asedio, y vida de los PNJ en esta prueba (la de verdad: Capitán 30 000, Huecos 2500).
const BOTS: int = 12
const CAPTAIN_HEALTH: int = 9000
const HOLLOW_HEALTH: int = 1000
## Delante de la puerta, en la explanada (la puerta está en x = -20 y el fuerte hacia +X).
const START: Vector3 = Vector3(-27.0, 10.3, 0.0)

var _runner: SiegeRunner = null
var _evading: Dictionary[int, bool] = {}
var _unblockable_hits: int = 0
var _unblockable_on_evading: int = 0
var _telegraphs: int = 0


func before_each() -> void:
	_runner = SiegeRunner.new()
	tree.root.add_child(_runner)
	assert_true(await _runner.start(tree.root, "", 64, true), "el servidor arranca sobre el Vado Gris con sus PNJ")
	assert_true(_runner.set_npc_health(&"ford_captain", CAPTAIN_HEALTH), "Capitán más débil en esta prueba")
	assert_true(_runner.set_npc_health(&"hollow", HOLLOW_HEALTH), "y Huecos")
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
	if not assert_not_null(system, "con PNJ"):
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
	if not assert_true(captured >= 0, "Vardheim captura el fuerte neutral (fase %d, dueño %d)" % [state.phase, state.owner]):
		return
	var ids_of_war: Array[int] = _runner.war_ids()
	assert_true(ids_of_war.find(WarEvents.GATE_BROKEN) < ids_of_war.find(WarEvents.CAPTAIN_DOWN),
			"rompen la puerta antes de matar al capitán: %s" % [ids_of_war])
	assert_true(ids_of_war.find(WarEvents.CAPTAIN_DOWN) < ids_of_war.find(WarEvents.FORT_CAPTURED), "y lo matan antes de capturar")
	var deaths: Dictionary = _npc_death_counts()
	assert_eq(int(deaths.get(&"ford_captain", 0)), 1, "el Capitán del Vado muere a manos de los bots")
	assert_true(int(deaths.get(&"hollow", 0)) >= 4, "y los cuatro Huecos (más los refuerzos): %s" % [deaths])
	for event: NetMessages.EntityEvent in _runner.war_events:
		if event.war_event == WarEvents.CAPTAIN_DOWN:
			assert_eq(event.war_realm, VARDHEIM, "lo mató Vardheim, no una orden")
	# El golpe imbloqueable: salen de su zona en cuanto lo avisa, y los que salían no se lo comen.
	assert_true(_telegraphs > 0, "el Capitán avisa sus golpes fuertes")
	assert_true(_evading.size() > 0, "algún bot sale de la zona de un golpe avisado")
	assert_eq(_unblockable_on_evading, 0, "ninguno de los que salían se come el golpe imbloqueable")


# Cada tick, quién está saliendo de la zona de un golpe avisado.
func _on_tick(_tick: int) -> void:
	for net_id: int in _runner.bots:
		var brain: BotBrain = _runner.get_brain(net_id)
		if brain != null and brain.get_siege_task() == BotBrain.SiegeTask.EVADE:
			_evading[net_id] = true


# Los golpes imbloqueables (el del Capitán) que dan a un bot, y a cuántos de los que estaban saliendo.
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
