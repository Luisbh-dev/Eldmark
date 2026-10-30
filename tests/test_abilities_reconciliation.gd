extends TestCase
## La reconciliación con el kit entero de la fase 4 y red mala (H5; docs/habilidades.md, secciones 6.1 y 7.3; la
## aceptación de la fase 2): tres bots de combate ([code]--bot-brain=combat[/code], con el kit de [BotBrain]) con
## las dos plantillas, ENet real sobre 127.0.0.1 y un [NetSim] de 120 ms de RTT, 20 ms de jitter y un 5 % de
## pérdida en el servidor (en los dos sentidos): un tirador herido y un escudero de Vardheim contra un tirador de
## Solmarch.
## [br][br]
## En 900 ticks de pelea usan habilidades (golpe de escudo, embestida, muro, abanico, flecha lastrante, salto
## atrás), cambian de arma, beben pociones, disparan flechas, se ralentizan y alguien cae derribado. El servidor
## impone lo que el cliente no predice (golpes recibidos, efectos de movimiento, derribos, levantar y rematar,
## LOADOUT), y cada corrección la tiene que explicar el [NetClient]: una entrada sustituida, un teletransporte o un
## evento de combate propio. Se comprueba, como en test_combat_reconciliation:
## [br]- todo lo de arriba ha pasado de verdad, y se cuenta en el [b]servidor[/b] (revisión de H5: los contadores
## del bot solo dicen lo que quiso pulsar): habilidades, cambios de arma y tragos que empieza el estado del
## servidor, golpes de habilidad, curaciones y el HIT con el bit 6 que derriba. Si a mitad de la pelea nadie se ha
## ralentizado, el servidor ralentiza al de Solmarch (como el comando 14) y, si nadie ha caído, lo deja con 1 de vida y
## sin pociones de vida (con su LOADOUT, como el comando 16) para que lo derribe el siguiente golpe; solo si a cinco
## sextos sigue sin caer lo derriba él (como el 15). Es estado del servidor igual: lo que se prueba es que el cliente lo explica y converge;
## [br]- ninguna corrección sin explicar, ningún reinicio duro ni resincronización;
## [br]- al quedarse quietos 180 ticks, el estado predicho para el último tick del servidor es idéntico bit a bit
## al del servidor (convergencia), también para quien está derribado.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900
## Simulador de red, en el servidor (en los dos sentidos y para los tres bots): el tope del rebobinado cuenta el
## retardo que añade el simulador del servidor y no el de un cliente (docs/red.md, sección 10), así que con el
## simulador en cada bot el servidor rechazaba sus rebobinados y sus flechas salían inofensivas.
const NET_SIM: String = "rtt=120,jitter=20,loss=5,seed=7"
const FIGHT_TICKS: int = 900
const IDLE_TICKS: int = 180
## Vida con la que empieza el tirador de Vardheim (bebe enseguida).
const WOUNDED_HEALTH: int = 450

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _clients: Array[NetClient] = []
var _viewports: Array[SubViewport] = []
# Eventos del servidor por clase (y los STATUS de ralentizar aparte).
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


# Cuenta las acciones que empieza el estado del servidor de cada bot desde el último tick: habilidades (no
# consumibles), cambios de arma y tragos (una acción nueva es un par acción y tick de inicio distinto).
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
	if not assert_true(await _wait_until(_all_in_world), "entran los tres bots"):
		return
	await wait_physics_frames(60)
	var spots: Array[Vector3] = [Vector3(-10.0, 0.05, 3.0), Vector3(0.0, 0.05, 0.0), Vector3(8.0, 0.05, 0.0)]
	for index: int in _clients.size():
		_server.teleport(_clients[index].get_net_id(), spots[index])
	# El tirador de Vardheim empieza herido: bebe enseguida.
	var wounded: Combatant = _server.get_combat().get_combatant(_clients[0].get_net_id())
	wounded.take_damage(wounded.health - WOUNDED_HEALTH, _server.get_tick())
	# Respaldo para que la prueba pruebe siempre lo mismo: si a mitad de la pelea nadie ha quedado ralentizado, el
	# servidor ralentiza al de Solmarch (como el comando 14); si nadie ha caído, le deja 1 de vida y sin pociones de
	# vida (el siguiente golpe de un enemigo lo derriba, y no puede curarse) y, si a cinco sextos sigue en pie, lo
	# derriba (como el comando 15). Todo es estado que impone el servidor y el cliente tiene que explicar igual.
	var lonely: Combatant = _server.get_combat().get_combatant(_clients[2].get_net_id())
	var nudged: PackedStringArray = PackedStringArray()
	# Lo que empieza el estado del servidor de cada bot (no lo que el bot quiso pulsar).
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
	# Lo que ha hecho el servidor, no lo que el bot quiso pulsar.
	assert_true(server_starts[&"ability"] >= 3, "el servidor lanza habilidades (%d)" % server_starts[&"ability"])
	assert_true(_ability_hits >= 1, "y alguna da (%d golpes de habilidad)" % _ability_hits)
	assert_true(server_starts[&"swap"] >= 1, "el servidor cambia de arma (%d)" % server_starts[&"swap"])
	assert_true(server_starts[&"drink"] >= 1, "el servidor bebe (%d)" % server_starts[&"drink"])
	assert_true(_events.get(NetMessages.EntityEvent.Kind.HEAL, 0) >= 1,
			"y la poción cura (%d HEAL)" % _events.get(NetMessages.EntityEvent.Kind.HEAL, 0))
	assert_true(combat.projectiles.stats[&"projectiles_fired"] >= 5,
			"disparan flechas (%d)" % combat.projectiles.stats[&"projectiles_fired"])
	assert_true(_slowed >= 1, "alguien queda ralentizado (%d)" % _slowed)
	assert_true(combat.downed.stats[&"downs"] >= 1, "alguien cae derribado (%d)" % combat.downed.stats[&"downs"])
	assert_true(_downing_hits >= 1 or nudged.has("derribo"),
			"por un golpe (HIT con el bit 6: %d), salvo que haya hecho falta el respaldo" % _downing_hits)
	assert_true(combat.stats[&"hits"] >= 10, "y de verdad se pelean (%d golpes)" % combat.stats[&"hits"])

	# Quietos: se espera a que acabe lo que tuvieran en marcha y a que el servidor y el cliente coincidan.
	for client: NetClient in _clients:
		var brain: BotBrain = client.get_meta(&"bot_brain") as BotBrain
		brain.set_idle_from(client.get_prediction().get_predicted_tick() + 1)
	await wait_physics_frames(IDLE_TICKS)
	var any_combat_correction: bool = false
	for client: NetClient in _clients:
		var name: String = client.get_config().display_name
		var stats: Dictionary = client.get_stats()
		assert_eq(client.get_state(), NetClient.State.IN_WORLD, "%s: sigue en el mundo" % name)
		assert_eq(stats["unexplained_diffs"], 0,
				"%s: toda corrección la explica una sustitución, un teletransporte o el combate: %s" % [name, stats])
		assert_eq(stats["hard_resets"], 0, "%s: ningún reinicio duro" % name)
		assert_eq(stats["resyncs"], 0, "%s: ninguna resincronización" % name)
		if int(stats.get("combat_diffs", 0)) > 0:
			any_combat_correction = true
		var server_state: PlayerState = client.get_last_server_state()
		var predicted: PlayerState = client.get_prediction().get_predicted_state(client.get_last_snapshot_tick())
		if assert_not_null(server_state, "%s: recibió su estado" % name) \
				and assert_not_null(predicted, "%s: guarda lo que predijo" % name):
			assert_true(predicted.equals_exact(server_state),
					"%s: convergencia exacta con el servidor al quedarse quieto (acción %d)" % [name,
					server_state.combat.action])
	assert_true(any_combat_correction, "alguna corrección la causó el combate (se explica a sí mismo)")
