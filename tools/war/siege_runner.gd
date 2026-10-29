class_name SiegeRunner
extends Node
## Un asedio con jugadores falsos sobre la zona de verdad (GUE-15, GUE-17; docs/fuerte.md, sección 7), en un
## solo proceso y sin red: carga el Vado Gris con su Terrain3D, arranca un [ZoneServer] y lo avanza «a mano»,
## muchos ticks por fotograma de física ([member ticks_per_frame]), para que una batalla de minutos de juego
## dure segundos. Lo usan [code]tools/war/siege_battle.gd[/code] (la herramienta de línea de órdenes, que
## imprime el informe) y [code]tests/test_siege_zone.gd[/code] (una versión corta dentro de la suite).
## [br][br]
## Apunta lo que hace falta para medir: cuándo llega cada bot a la puerta y por qué ruta, los avisos de guerra y
## las muertes de jugadores y de PNJ. Sin PNJ (el asedio de F6a), [method kill_captain] da por muerto al capitán como
## el comando [code]fort_kill_captain[/code] y [method spawn_captain_double] pone un PNJ mortal en su sitio para que
## los bots lo maten ellos. Con ellos ([code]with_npcs[/code] en [method start], F6b) defienden el fuerte los
## Huecos, el Capitán del Vado y la guarnición del dueño de verdad, y [method set_npc_health] los debilita para las
## pruebas cortas sin tocar [code]data/npcs/[/code]. Los bots esperan a los suyos en su campamento y van en formación
## (GUE-44); [method set_rally] lo cambia o lo quita, y [member rally_departures] apunta cada salida.

## Zona del asedio.
const ZONE_ID: String = "vado_gris"
## A esta distancia (m) de la puerta, en horizontal, se cuenta que un bot ha llegado.
const ARRIVAL_DISTANCE: float = 3.0
## Ticks que se avanzan por fotograma de física.
const DEFAULT_TICKS_PER_FRAME: int = 40
## Ticks entre dos comprobaciones de la condición de [method advance_until].
const CHECK_TICKS: int = 30
## Tick por segundo.
const TICK_RATE: int = 60

## Ticks que se avanzan por fotograma de física.
var ticks_per_frame: int = DEFAULT_TICKS_PER_FRAME
## El servidor de la zona (null antes de [method start]).
var server: ZoneServer = null
var world: Node3D = null
## Avisos de guerra en el orden en que salieron (cada uno con su tick), muertes de jugadores y muertes de PNJ
## ([code]{tick, net_id, npc}[/code], con el id de su definición).
var war_events: Array[NetMessages.EntityEvent] = []
var deaths: Array[Dictionary] = []
var npc_deaths: Array[Dictionary] = []
## net_id -> {realm, route, tick} de cada bot que ha llegado a la puerta.
var arrivals: Dictionary[int, Dictionary] = {}
## net_id -> realm de los jugadores falsos de asedio.
var bots: Dictionary[int, int] = {}
## Salidas de la reunión (GUE-44), en el orden en que pasan: [code]{tick, net_id, realm, route}[/code] de cada bot que
## sale del punto de reunión de su campamento con los suyos (también si no tuvo que esperar porque ya eran bastantes).
var rally_departures: Array[Dictionary] = []

# net_id -> cerebro de cada bot de asedio (para saber qué ruta sigue).
var _brains: Dictionary[int, BotBrain] = {}
var _remaining: int = 0
var _running: bool = false
# La reunión que se impone a los bots (set_rally; -1 = la de BotBrain) y la última salida de la reunión que se ha
# apuntado de cada bot.
var _rally_size: int = -1
var _rally_period: int = BotBrain.SIEGE_RALLY_PERIOD_TICKS
var _rally_seen: Dictionary[int, int] = {}


## Carga la zona, arranca el servidor y lo deja listo (sin avanzar). [param battle_log_path] activa el
## [code]--battle-log[/code] del servidor. Sin [param with_npcs] el servidor arranca con
## [code]--no-npcs[/code] (sin Huecos, Capitán ni Guardianes: el asedio de F6a, medido así); con él, los PNJ
## de la zona (F4) defienden el fuerte (F6b). Devuelve false si no ha podido.
func start(parent: Node, battle_log_path: String = "", max_players: int = 256, with_npcs: bool = false) -> bool:
	var packed: PackedScene = load(NetZones.scene_path(ZONE_ID)) as PackedScene
	if packed == null:
		return false
	world = packed.instantiate() as Node3D
	parent.add_child(world)
	var zone_root: ZoneRoot = world as ZoneRoot
	if zone_root != null:
		zone_root.strip_for_server()
	server = ZoneServer.new()
	server.name = "ZoneServer"
	server.log_enabled = false
	parent.add_child(server)
	for _i: int in 4:
		await get_tree().physics_frame
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.max_players = max_players
	config.no_dummies = true
	config.no_npcs = not with_npcs
	config.battle_log_path = battle_log_path
	if server.start(config, world, null, DevAuthProvider.new()) != OK:
		return false
	server.set_physics_process(false)
	server.get_fortresses().war_event_emitted.connect(func(event: NetMessages.EntityEvent) -> void:
		war_events.append(event))
	server.get_combat().event_emitted.connect(_on_combat_event)
	server.tick_finished.connect(_on_tick_finished)
	return true


## Cierra el servidor y libera la zona.
func finish() -> void:
	if is_instance_valid(server):
		server.stop()
		if server.get_parent() != null:
			server.get_parent().remove_child(server)
		server.free()
	server = null
	if is_instance_valid(world):
		if world.get_parent() != null:
			world.get_parent().remove_child(world)
		world.queue_free()
	world = null


## Añade [param count] jugadores falsos de asedio de [param realm], con las semillas [param seed_base],
## [param seed_base] + 1... Devuelve sus net_id.
func add_siege_bots(realm: int, count: int, seed_base: int) -> Array[int]:
	var ids: Array[int] = []
	for i: int in count:
		var brain := BotBrain.new(seed_base + i, BotBrain.Pattern.SIEGE)
		if _rally_size >= 0:
			brain.set_rally(_rally_size, _rally_period)
		var net_id: int = server.add_fake_player(brain, realm)
		if net_id > 0:
			bots[net_id] = realm
			_brains[net_id] = brain
			ids.append(net_id)
	return ids


## Cambia la reunión de los bots de asedio (GUE-44; [method BotBrain.set_rally]), los que ya hay y los que se añadan:
## salen de su campamento cuando hay [param group_size] de su reino o en la siguiente salida del reloj, que da una vuelta
## cada [param period_ticks] ticks. Con [param group_size] 1 o menos no esperan (como antes de GUE-44).
func set_rally(group_size: int, period_ticks: int = BotBrain.SIEGE_RALLY_PERIOD_TICKS) -> void:
	_rally_size = group_size
	_rally_period = period_ticks
	for net_id: int in _brains:
		_brains[net_id].set_rally(group_size, period_ticks)


## Los PNJ de la definición [param npc_id] que aparezcan desde ahora tendrán [param health] de vida (una copia de la
## definición con otra vida, solo en este servidor: [method NpcSpawnerSystem.set_definition_override]). Hay que
## llamarlo justo después de [method start], antes de avanzar, para que valga ya para los primeros. Devuelve false si
## el servidor no tiene PNJ o la definición no existe.
func set_npc_health(npc_id: StringName, health: int) -> bool:
	var system: NpcSpawnerSystem = server.get_npc_system()
	var base: NpcDefinition = NpcCatalog.get_definition(npc_id)
	if system == null or base == null or health <= 0:
		return false
	var weaker: NpcDefinition = base.duplicate() as NpcDefinition
	weaker.max_health = health
	system.set_definition_override(npc_id, weaker)
	return true


## Pone en el sitio del capitán un PNJ mortal y quieto, registrado como capitán (ver
## [method ZoneServer.spawn_captain_double]). Devuelve su net_id.
func spawn_captain_double() -> int:
	return server.spawn_captain_double(fortress_id())


## Da por muerto al capitán con la orden de la consola [code]fort_kill_captain[/code]. Devuelve true si el
## fuerte lo guardaba (fase GARRISONED con el capitán vivo).
func kill_captain() -> bool:
	return server.console_command("fort_kill_captain").contains("ha muerto")


## Multiplica la velocidad de captura ([code]fort_capture_speed[/code]).
func set_capture_speed(factor: int) -> void:
	server.get_fortresses().set_capture_speed(fortress_id(), factor)


## Id de la fortaleza de la zona.
func fortress_id() -> StringName:
	return server.get_fortresses().get_fortress_ids()[0]


## Estado vivo de la fortaleza.
func state() -> FortressState:
	return server.get_fortresses().get_fortress_state(fortress_id())


## Avanza [param ticks] ticks del servidor.
func advance(ticks: int) -> void:
	_remaining += ticks
	_running = true
	while _remaining > 0:
		await get_tree().physics_frame
	_running = false


## Avanza hasta que [param condition] sea verdadera (se mira cada [constant CHECK_TICKS] ticks) o pasen
## [param max_ticks]. Devuelve los ticks que ha avanzado, o -1 si no se cumplió.
func advance_until(condition: Callable, max_ticks: int) -> int:
	var advanced: int = 0
	while advanced < max_ticks:
		if bool(condition.call()):
			return advanced
		var chunk: int = mini(CHECK_TICKS, max_ticks - advanced)
		await advance(chunk)
		advanced += chunk
	return advanced if bool(condition.call()) else -1


## Tick del servidor.
func tick() -> int:
	return server.get_tick()


## Los avisos de guerra (ids de [WarEvents]) en el orden en que salieron.
func war_ids() -> Array[int]:
	var ids: Array[int] = []
	for event: NetMessages.EntityEvent in war_events:
		ids.append(event.war_event)
	return ids


## Tick del primer aviso de guerra [param war_event] desde el tick [param from_tick] (-1 si no ha salido).
func tick_of_war(war_event: int, from_tick: int = 0) -> int:
	for event: NetMessages.EntityEvent in war_events:
		if event.war_event == war_event and event.tick >= from_tick:
			return event.tick
	return -1


## Cuántas veces ha salido el aviso de guerra [param war_event] desde el tick [param from_tick].
func count_war(war_event: int, from_tick: int = 0) -> int:
	var count: int = 0
	for event: NetMessages.EntityEvent in war_events:
		if event.war_event == war_event and event.tick >= from_tick:
			count += 1
	return count


## El cerebro del bot de asedio [param net_id] (null si no es uno de los suyos).
func get_brain(net_id: int) -> BotBrain:
	return _brains.get(net_id)


## Cuántos bots de [param realm] siguen vivos.
func alive_bots(realm: int) -> int:
	var count: int = 0
	for net_id: int in bots:
		if bots[net_id] != realm:
			continue
		var combatant: Combatant = server.get_combat().get_combatant(net_id)
		if combatant != null and combatant.is_alive():
			count += 1
	return count


## Segundos de juego que son [param ticks].
static func seconds(ticks: int) -> float:
	return float(ticks) / float(TICK_RATE)


func _physics_process(delta: float) -> void:
	if not _running or server == null:
		return
	var count: int = mini(_remaining, ticks_per_frame)
	for _i: int in count:
		server._physics_process(delta)
	_remaining -= count


# Anota las muertes de jugadores (con el reino de la víctima y su sitio) y de PNJ de guerra (con su definición).
func _on_combat_event(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
	if event.event != NetMessages.EntityEvent.Kind.DEATH:
		return
	var victim: NetEntity = server.get_registry().get_entity(event.net_id)
	if victim != null and victim.kind == NetProtocol.EntityKind.NPC and victim.npc_def_id > 0:
		var definition: NpcDefinition = NpcCatalog.get_by_number(victim.npc_def_id)
		npc_deaths.append({"tick": event.tick, "net_id": event.net_id,
				"npc": definition.id if definition != null else &""})
		return
	if victim == null or victim.kind != NetProtocol.EntityKind.PLAYER:
		return
	deaths.append({"tick": event.tick, "net_id": event.net_id, "realm": victim.realm,
			"position": victim.get_position()})


# Al terminar cada tick, anota quién sale de la reunión y quién acaba de llegar a la puerta y por qué ruta.
func _on_tick_finished(tick_now: int) -> void:
	_note_rally_departures()
	var gate: FortGate = server.get_fortresses().get_gate(fortress_id())
	if gate == null:
		return
	var gate_point := Vector2(gate.global_position.x, gate.global_position.z)
	for net_id: int in bots:
		if arrivals.has(net_id):
			continue
		var entity: NetEntity = server.get_registry().get_entity(net_id)
		if entity == null:
			continue
		var position: Vector3 = entity.get_position()
		if Vector2(position.x, position.z).distance_to(gate_point) <= ARRIVAL_DISTANCE:
			arrivals[net_id] = {"realm": bots[net_id], "route": _route_of(net_id), "tick": tick_now}


# Los bots que acaban de salir del punto de reunión (GUE-44).
func _note_rally_departures() -> void:
	for net_id: int in _brains:
		var left: int = _brains[net_id].get_last_rally_departure()
		if left >= 0 and left != _rally_seen.get(net_id, -1):
			_rally_seen[net_id] = left
			rally_departures.append({"tick": left, "net_id": net_id, "realm": bots.get(net_id, 0),
					"route": _route_of(net_id)})


# La ruta que sigue el bot [param net_id] (el cerebro la elige al empezar).
func _route_of(net_id: int) -> StringName:
	var brain: BotBrain = _brains.get(net_id)
	return brain.get_siege_route() if brain != null else &""
