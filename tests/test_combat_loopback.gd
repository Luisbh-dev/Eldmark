extends TestCase
## El combate de punta a punta con ENet real sobre 127.0.0.1, en un solo proceso (docs/combate.md,
## secciones 4 a 6; CMB-10): un [ZoneServer] y varios [NetClient] bots, cada uno en su
## [SubViewport] con su propio mundo de física y su propio [NetTransport].
## [br][br]
## Un bot ataca a otro: el atacante, la víctima y un tercero reciben el mismo HIT y el bloque extra
## de los snapshots de la víctima lleva su vida bajada. Con rebobinado de verdad: las entradas del
## cliente real llevan su [code]view_offset_q[/code] y el servidor las acepta dentro del tope. El
## tercer escenario golpea a un maniquí: todos ven bajar su vida en el registro del snapshot.
## [br][br]
## Los bots no leen los ENTITY_EVENT (eso es del cliente de combate): la prueba escucha los paquetes
## del transporte de cada uno.
## [br][br]
## [b]Rebobinado con red mala[/b] (CMB-09, TEC-14; docs/combate.md, secciones 4.3 y 4.5): el servidor
## lleva un [NetSim] de 150 ms de RTT y 30 ms de jitter (el del cliente no cuenta para el tope: red.md,
## sección 10) y dos atacantes golpean a un objetivo que corre en lateral. [SwingRecorder] guarda, en cada
## entrada que genera el atacante, dónde dibuja al objetivo (su [code]render_tick[/code]) y, con su estado
## predicho, calcula qué golpes [i]veía[/i] dentro del arco; el servidor debe confirmar al menos el 95 %.
## Con un [code]view_offset_q[/code] de 30 ticks contra un objetivo quieto, ningún golpe entra (tope de 24).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 600
## Simulador de red del servidor en las pruebas de rebobinado: 150 ms de RTT y 30 ms de jitter por sentido
## (el criterio de TEC-14), retardo en los dos sentidos. Con 200 ms ya no se llega al 95 %: el tope de
## 24 ticks no cubre el margen de [TickSync] y la interpolación (docs/red.md, sección 10).
const REWIND_NET_SIM: String = "rtt=150,jitter=30,seed=5"
## Distancia (m) a la que está el objetivo de cada atacante y semianchura (m) de su carrera en lateral.
const REWIND_DISTANCE: float = 2.7
const REWIND_RUN_HALF_WIDTH: float = 3.6
## Ticks entre dos pulsaciones del atacante (el ligero dura 36) y cuánto se adelanta (ticks) al objetivo
## al apuntar (el golpe activo llega ~15 ticks después de pulsar).
const REWIND_CYCLE_TICKS: int = 48
const REWIND_LEAD_TICKS: float = 15.0
## Ticks desde la pulsación a partir de los que el atacante retrocede (recuperación del ligero) y desde
## los que vuelve a su sitio con las piernas libres; distancia máxima (m) al objetivo con la que pulsa y
## probabilidad por tick de pulsar cuando lo tiene a su alcance y ya pasó el ciclo.
const REWIND_RECOVERY_FROM: int = 20
const REWIND_FREE_FROM: int = 36
const REWIND_PRESS_DISTANCE: float = 3.0
const REWIND_PRESS_CHANCE: float = 0.07
## Ticks de medida de la prueba del 95 % y mínimo de golpes vistos para que la cifra signifique algo.
const REWIND_MEASURED_TICKS: int = 900
const REWIND_MIN_SEEN_SWINGS: int = 16
## Fracción de los golpes vistos que el servidor debe confirmar.
const REWIND_MIN_CONFIRMED: float = 0.95
## Ticks de rebobinado que falsea el atacante de la prueba del tope (el tope es de 24).
const CHEAT_VIEW_TICKS: int = 30

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _port: int = 0
var _clients: Array[NetClient] = []
var _client_viewports: Array[SubViewport] = []
var _listeners: Array[Listener] = []


## Escucha los paquetes que llegan a un cliente y guarda los eventos y el último snapshot.
class Listener:
	extends RefCounted

	var events: Array[NetMessages.EntityEvent] = []
	var snapshots: Array[NetMessages.Snapshot] = []

	func _init(transport: NetTransport) -> void:
		transport.packet_received.connect(_on_packet)

	func _on_packet(_peer_id: int, bytes: PackedByteArray) -> void:
		match NetMessages.peek_type(bytes):
			NetProtocol.MSG_ENTITY_EVENT:
				var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
				if event != null:
					events.append(event)
			NetProtocol.MSG_SNAPSHOT:
				var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
				if snapshot != null:
					snapshots.append(snapshot)

	func hits() -> Array[NetMessages.EntityEvent]:
		var found: Array[NetMessages.EntityEvent] = []
		for event: NetMessages.EntityEvent in events:
			if event.event == NetMessages.EntityEvent.Kind.HIT:
				found.append(event)
		return found

	func last_snapshot() -> NetMessages.Snapshot:
		return snapshots[snapshots.size() - 1] if not snapshots.is_empty() else null


## Lo que ve un atacante mientras juega y qué golpes veía dentro del arco (ver la documentación del
## archivo). Cada entrada que genera guarda dónde dibuja al objetivo en ese momento; [method evaluate]
## (una vez por fotograma de física) la cruza con el estado que predijo para ese tick: si el golpe estaba
## activo y el objetivo dibujado cae en el sector, el atacante [i]veía[/i] ese golpe acertar. Además anota
## si el objetivo habría estado dentro con su posición [b]del servidor en ese mismo tick[/b] (lo que
## probaría un servidor sin rebobinado).
class SwingRecorder:
	extends RefCounted

	var client: NetClient
	var server: ZoneServer
	var target_id: int = 0
	## Tick de la entrada -> posición con la que dibujaba al objetivo al generarla.
	var views: Dictionary[int, Vector3] = {}
	## action_tick del golpe -> {"seen": lo veía dentro del arco, "now": el objetivo estaba dentro en el
	## servidor sin rebobinar}.
	var swings: Dictionary[int, Dictionary] = {}

	func _init(p_client: NetClient, p_server: ZoneServer, p_target_id: int) -> void:
		client = p_client
		server = p_server
		target_id = p_target_id
		var controller: LocalPlayerController = client.get_meta(&"controller") as LocalPlayerController
		controller.input_generated.connect(_on_input_generated)

	func _on_input_generated(input: PlayerInput) -> void:
		var world: RemoteWorld = client.get_remote_world()
		var view: RemotePlayerView = world.get_view(target_id)
		if view == null or not view.is_drawn() or world.get_last_drawn_render_tick() <= 0.0:
			return
		views[input.tick] = view.get_drawn_position()

	## Cruza las entradas generadas con el estado predicho (solo los ticks que el servidor ya ha simulado,
	## para poder mirar su historial).
	func evaluate() -> void:
		var prediction: ClientPrediction = client.get_prediction()
		var limit: int = mini(prediction.get_predicted_tick(), server.get_tick())
		var done: Array[int] = []
		for tick: int in views:
			if tick > limit:
				continue
			done.append(tick)
			var state: PlayerState = prediction.get_predicted_state(tick)
			if state == null or not ActionMachine.is_attack_active(state.combat, tick):
				continue
			var attack: AttackTicks = CombatCatalog.attack(state.combat.action_id)
			if attack == null or attack.shape == null:
				continue
			var swing: Dictionary = swings.get(state.combat.action_tick, {"seen": false, "now": false})
			if _inside(state, attack, views[tick]):
				swing["seen"] = true
			var current: StateHistory.Sample = server.get_history().sample(target_id, float(tick))
			if current != null and _inside(state, attack, current.position):
				swing["now"] = true
			swings[state.combat.action_tick] = swing
		for tick: int in done:
			views.erase(tick)

	func _inside(state: PlayerState, attack: AttackTicks, feet: Vector3) -> bool:
		return HitShapes.sector_hits_capsule(state.position, state.yaw, attack.shape, feet,
				HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT)

	## Golpes que veía acertar.
	func seen_swings() -> Array[int]:
		var found: Array[int] = []
		for action_tick: int in swings:
			if swings[action_tick]["seen"]:
				found.append(action_tick)
		return found

	## De los que veía acertar, cuántos también habrían acertado sin rebobinar.
	func seen_and_current() -> int:
		var count: int = 0
		for action_tick: int in swings:
			if swings[action_tick]["seen"] and swings[action_tick]["now"]:
				count += 1
		return count


func before_each() -> void:
	_root = Node.new()
	_root.name = "CombatLoopback"
	tree.root.add_child(_root)


func after_each() -> void:
	_listeners.clear()
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


# --- Ayudantes --------------------------------------------------------------------------------

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
	await wait_physics_frames(3)


func _add_bot(realm: int, bot_seed: int) -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
	_client_viewports.append(viewport)
	var client: NetClient = NetHarness.start_bot(viewport, _port, realm, bot_seed)
	_clients.append(client)
	_listeners.append(Listener.new(client.get_meta(&"transport") as NetTransport))
	return client


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


## Cambia lo que hace el bot: [param script] es [code](tick, position, yaw) -> PlayerInput[/code].
func _set_script(client: NetClient, script: Callable) -> void:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = script
	(client.get_meta(&"controller") as LocalPlayerController).set_bot(brain)


func _idle(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	return input


# --- Pruebas ----------------------------------------------------------------------------------

func test_a_bot_hits_another_and_attacker_victim_and_a_third_get_the_same_event() -> void:
	await _start_server()
	var attacker: NetClient = _add_bot(VARDHEIM, 1)
	var victim: NetClient = _add_bot(SOLMARCH, 2)
	var third: NetClient = _add_bot(VARDHEIM, 3)
	if not assert_true(await _wait_until(_all_in_world), "los tres bots entran en el mundo"):
		return
	await wait_physics_frames(30)
	var attacker_id: int = attacker.get_net_id()
	var victim_id: int = victim.get_net_id()
	# Primero se les quita el paseo (que no se muevan), después se les coloca.
	var press: int = _server.get_tick() + 150
	_set_script(attacker, func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = 0.0
		if tick >= press and tick < press + 2:
			input.buttons = PlayerInput.PRIMARY
		return input)
	_set_script(victim, func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI
		return input)
	_set_script(third, _idle)
	await wait_physics_frames(20)
	_server.teleport(attacker_id, Vector3(0.0, 0.05, 0.0))
	_server.teleport(victim_id, Vector3(0.0, 0.05, -1.5))
	_server.teleport(third.get_net_id(), Vector3(10.0, 0.05, 10.0))
	_server.get_registry().get_entity(victim_id).get_character().yaw = PI
	var delivered: bool = await _wait_until(func() -> bool:
		return not _listeners[0].hits().is_empty() and not _listeners[1].hits().is_empty() \
				and not _listeners[2].hits().is_empty())
	if not assert_true(delivered, "los tres reciben el HIT"):
		return
	var first: NetMessages.EntityEvent = _listeners[0].hits()[0]
	for index: int in [1, 2]:
		assert_eq(_listeners[index].hits()[0].encode(), first.encode(),
				"el cliente %d recibe el mismo HIT, byte a byte" % index)
	assert_eq(first.attacker, attacker_id, "del atacante")
	assert_eq(first.net_id, victim_id, "a la víctima")
	assert_eq(first.amount, 90, "un ligero de frente")
	assert_eq(first.attack_id, CombatCatalog.attack_id(&"sword_light_1"))
	assert_eq(first.hit_flags, 0)
	assert_eq(_listeners[0].hits().size(), 1, "y un solo golpe por ataque")
	# El rebobinado de un cliente real no se rechaza: las entradas llevan su vista y entran en el tope.
	assert_eq(_server.get_combat().stats[&"rewind_rejected"], 0, "ningún rebobinado excesivo")
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_eq(peer.suspicion_score, 0, "y ninguna sospecha")
	# La vida de la víctima baja en su bloque extra y en el registro que ven los demás.
	await wait_physics_frames(12)
	var own: NetMessages.Snapshot = _listeners[1].last_snapshot()
	assert_not_null(own.own_state, "el snapshot lleva el estado propio")
	assert_eq(own.health, 910, "el bloque extra de la víctima lleva su vida")
	assert_eq(own.max_health, 1000)
	assert_true(own.is_in_combat())
	var seen: EntityRecord = null
	for record: EntityRecord in _listeners[2].last_snapshot().records:
		if record.net_id == victim_id:
			seen = record
	if assert_not_null(seen, "el tercero ve a la víctima"):
		assert_eq(seen.health_q, EntityRecord.quantize_health(910, 1000), "con su vida en el registro")
	assert_eq(_listeners[0].last_snapshot().health, 1000, "el atacante no pierde vida")
	# El envío de los eventos tiene su sección de medida y sus bytes en el informe (pruebas de carga).
	var sections: Dictionary = _server.get_metrics().summary()["sections"]
	assert_true(sections.has("combat_events"), "la sección del envío de eventos (%s)" % [sections.keys()])
	assert_true(sections.has("combat_resolve"))
	var report_path: String = NetHarness.build_path("test_combat_loopback_report.json")
	assert_eq(_server.write_report(report_path), OK)
	var combat_report: Dictionary = NetHarness.read_report(report_path).get("combat", {})
	assert_true(int(combat_report.get("event_bytes_sent", 0)) >= 3 * first.encode().size(),
			"tres paquetes de ese evento al menos")


func test_both_players_hit_the_dummy_and_every_snapshot_shows_its_health_drop() -> void:
	await _start_server()
	var first: NetClient = _add_bot(VARDHEIM, 1)
	var second: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _wait_until(_all_in_world)):
		return
	await wait_physics_frames(30)
	var dummy: int = _server.spawn_dummy(Vector3(0.0, 0.0, -1.5), PI)
	assert_true(dummy > 0, "el servidor coloca el maniquí")
	var press: int = _server.get_tick() + 150
	for client: NetClient in [first, second]:
		_set_script(client, func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
			var input := PlayerInput.new()
			input.tick = tick
			input.look_yaw = 0.0
			if tick >= press and tick < press + 2:
				input.buttons = PlayerInput.PRIMARY
			return input)
	await wait_physics_frames(20)
	_server.teleport(first.get_net_id(), Vector3(0.0, 0.05, 0.0))
	_server.teleport(second.get_net_id(), Vector3(0.6, 0.05, 0.0))
	var done: bool = await _wait_until(func() -> bool:
		return _listeners[0].hits().size() >= 2 and _listeners[1].hits().size() >= 2)
	if not assert_true(done, "los dos golpean al maniquí y los dos ven los dos golpes"):
		return
	for listener: Listener in _listeners:
		for event: NetMessages.EntityEvent in listener.hits():
			assert_eq(event.net_id, dummy, "todos los golpes son al maniquí")
	await wait_physics_frames(12)
	var combatant: Combatant = _server.get_combat().get_combatant(dummy)
	assert_eq(combatant.health, 1000 - 180, "dos ligeros de 90")
	for listener: Listener in _listeners:
		var record: EntityRecord = null
		for candidate: EntityRecord in listener.last_snapshot().records:
			if candidate.net_id == dummy:
				record = candidate
		if assert_not_null(record, "cada cliente recibe el registro del maniquí") and record != null:
			assert_eq(record.kind, NetProtocol.EntityKind.NPC)
			assert_eq(record.health_q, EntityRecord.quantize_health(820, 1000), "con su vida")
	assert_eq(_server.get_combat().stats[&"rewind_rejected"], 0)


## Peer del servidor del jugador con ese net_id (null si no existe).
func _peer_of(net_id: int) -> ServerPeer:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.entity != null and peer.entity.net_id == net_id:
			return peer
	return null


## Guion del atacante: mira al objetivo que dibuja (adelantándose [param lead_ticks] a donde estará cuando
## el golpe llegue), pulsa PRIMARY (dos ticks) si lo tiene a su alcance y no ha pulsado hace un ciclo,
## retrocede durante la recuperación del ligero (lo que avanzó al lanzarlo) y entre golpes vuelve a su
## sitio. Pulsa con una probabilidad por tick ([constant REWIND_PRESS_CHANCE], con el generador
## [code]rng[/code] de [param state]) para que no caiga siempre en la misma fase de la carrera del
## objetivo. [param state] guarda lo que recuerda entre ticks ([code]last_press[/code]) y deja que la
## prueba lo desarme ([code]armed[/code]).
func _attacker_script(client: NetClient, target_id: int, home: Vector3, lead_ticks: float,
		state: Dictionary) -> Callable:
	return func(tick: int, position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = float(state.get("yaw", 0.0))
		var view: RemotePlayerView = client.get_remote_world().get_view(target_id)
		if view == null or not view.is_drawn():
			return input
		var velocity: Vector3 = view.get_body().velocity
		var aim: Vector3 = view.get_drawn_position() \
				+ Vector3(velocity.x, 0.0, velocity.z) * (lead_ticks / 60.0)
		var to_aim: Vector3 = aim - position
		to_aim.y = 0.0
		input.look_yaw = fposmod(atan2(-to_aim.x, -to_aim.z), TAU)
		state["yaw"] = input.look_yaw
		var since: int = tick - int(state["last_press"])
		if since < 2:
			input.buttons = PlayerInput.PRIMARY
		elif since >= REWIND_CYCLE_TICKS and bool(state.get("armed", true)) \
				and to_aim.length() < REWIND_PRESS_DISTANCE \
				and (state["rng"] as RandomNumberGenerator).randf() < REWIND_PRESS_CHANCE:
			state["last_press"] = tick
			input.buttons = PlayerInput.PRIMARY
		elif since >= REWIND_RECOVERY_FROM and since < REWIND_FREE_FROM:
			input.move = Vector2(0.0, -1.0)
		elif since >= REWIND_FREE_FROM:
			var forward := Vector3(-sin(input.look_yaw), 0.0, -cos(input.look_yaw))
			input.move = Vector2(0.0, clampf((home - position).dot(forward) * 6.0, -1.0, 1.0))
		return input


## Guion del objetivo: corre a lo ancho de [constant REWIND_RUN_HALF_WIDTH] m a cada lado, de ida y vuelta
## ([param state] guarda el sentido en [code]dir[/code]).
func _runner_script(state: Dictionary) -> Callable:
	return func(tick: int, position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		if position.x > REWIND_RUN_HALF_WIDTH:
			state["dir"] = -1.0
		elif position.x < -REWIND_RUN_HALF_WIDTH:
			state["dir"] = 1.0
		input.look_yaw = fposmod(-PI / 2.0 * float(state["dir"]), TAU)
		input.move = Vector2(0.0, 1.0)
		input.buttons = PlayerInput.SPRINT
		return input


## Golpes de [param recorder] que el servidor confirmó con un HIT al objetivo: los que el atacante
## [param listener] vio llegar con un tick dentro de la duración del golpe.
func _confirmed(recorder: SwingRecorder, listener: Listener, attacker_id: int) -> int:
	var confirmed: int = 0
	for action_tick: int in recorder.seen_swings():
		var found: bool = false
		for hit: NetMessages.EntityEvent in listener.hits():
			if hit.attacker == attacker_id and hit.net_id == recorder.target_id \
					and hit.tick >= action_tick and hit.tick < action_tick + 36:
				found = true
				break
		if found:
			confirmed += 1
	return confirmed


## Registro de combate del servidor (líneas ya partidas en columnas), tras cerrarlo para que se vuelque.
func _read_combat_log(path: String) -> Array[PackedStringArray]:
	_server.stop()
	var rows: Array[PackedStringArray] = []
	var lines: PackedStringArray = FileAccess.get_file_as_string(path).strip_edges().split("\n")
	for index: int in range(1, lines.size()):
		rows.append(lines[index].split(","))
	return rows


# --- Rebobinado con 150 ms de RTT ----------------------------------------------------------------

func test_the_server_confirms_at_least_95_percent_of_the_hits_attackers_saw_on_a_lateral_target() -> void:
	var log_path: String = NetHarness.build_path("test_combat_loopback_rewind.csv")
	await _start_server(func(config: ServerConfig) -> void:
		config.net_sim_spec = REWIND_NET_SIM
		config.combat_log_path = log_path)
	var first: NetClient = _add_bot(VARDHEIM, 1)
	var second: NetClient = _add_bot(VARDHEIM, 2)
	var runner: NetClient = _add_bot(SOLMARCH, 3)
	if not assert_true(await _wait_until(_all_in_world, 900), "entran los tres bots"):
		return
	await wait_physics_frames(30)
	var target_id: int = runner.get_net_id()
	_server.get_combat().get_combatant(target_id).immortal = true
	# El objetivo corre por z = -REWIND_DISTANCE; un atacante lo mira desde z = 0 y el otro desde el lado
	# opuesto de su carrera.
	var homes: Array[Vector3] = [Vector3(0.0, 0.05, 0.0),
			Vector3(0.0, 0.05, -2.0 * REWIND_DISTANCE)]
	var attackers: Array[NetClient] = [first, second]
	var script_states: Array[Dictionary] = []
	for index: int in 2:
		var rng := RandomNumberGenerator.new()
		rng.seed = 100 + index
		script_states.append({"last_press": -1000, "rng": rng})
		_set_script(attackers[index], _attacker_script(attackers[index], target_id, homes[index],
				REWIND_LEAD_TICKS, script_states[index]))
	_set_script(runner, _runner_script({"dir": 1.0}))
	await wait_physics_frames(10)
	_server.teleport(first.get_net_id(), homes[0])
	_server.teleport(second.get_net_id(), homes[1])
	_server.teleport(target_id, Vector3(-REWIND_RUN_HALF_WIDTH, 0.05, -REWIND_DISTANCE))
	await wait_physics_frames(90)

	var recorders: Array[SwingRecorder] = []
	for client: NetClient in attackers:
		recorders.append(SwingRecorder.new(client, _server, target_id))
	for _frame: int in REWIND_MEASURED_TICKS:
		await tree.physics_frame
		for recorder: SwingRecorder in recorders:
			recorder.evaluate()
	# Dejan de pulsar y se espera a que lleguen los HIT de los golpes que quedaban en el aire (lo que
	# dura un ligero más el retardo de la red).
	for state: Dictionary in script_states:
		state["armed"] = false
	for _frame: int in 80:
		await tree.physics_frame
		for recorder: SwingRecorder in recorders:
			recorder.evaluate()

	var seen: int = 0
	var confirmed: int = 0
	var current: int = 0
	for index: int in 2:
		seen += recorders[index].seen_swings().size()
		confirmed += _confirmed(recorders[index], _listeners[index], attackers[index].get_net_id())
		current += recorders[index].seen_and_current()
	print("[rebobinado] vistos %d, confirmados %d, habrían acertado sin rebobinar %d" % [
			seen, confirmed, current])
	assert_true(seen >= REWIND_MIN_SEEN_SWINGS,
			"los atacantes ven acertar suficientes golpes para que la cifra signifique algo (%d)" % seen)
	assert_true(float(confirmed) >= REWIND_MIN_CONFIRMED * float(seen),
			"el servidor confirma al menos el 95 %% de los golpes vistos: %d de %d" % [confirmed, seen])
	# Sin rebobinar, una parte de ellos habría fallado: la prueba discrimina.
	assert_true(float(current) <= 0.9 * float(seen),
			"sin rebobinado fallarían golpes que el atacante veía acertar (%d de %d acertarían)"
			% [current, seen])
	assert_eq(_server.get_combat().stats[&"rewind_rejected"], 0, "ningún rebobinado pasa del tope")
	for client: NetClient in attackers:
		assert_eq(_peer_of(client.get_net_id()).suspicion_score, 0, "y ninguna sospecha")
		assert_eq(client.get_stats()["unexplained_diffs"], 0, "el atacante predice sin fallos")
	var rows: Array[PackedStringArray] = _read_combat_log(log_path)
	var rewound: int = 0
	var rewind_total: float = 0.0
	for row: PackedStringArray in rows:
		if row[6] == "hit":
			rewound += 1
			rewind_total += row[5].to_float()
	assert_true(rewound >= confirmed, "el registro de combate anota los golpes (%d)" % rewound)
	var mean_rewind: float = rewind_total / float(maxi(rewound, 1))
	print("[rebobinado] rebobinado medio %.1f ticks en %d golpes" % [mean_rewind, rewound])
	assert_true(mean_rewind > 8.0 and mean_rewind <= float(NetProtocol.MAX_REWIND_TICKS),
			"se rebobina de verdad: %.1f ticks de media (tope %d)" % [mean_rewind,
			NetProtocol.MAX_REWIND_TICKS])


func test_a_view_offset_of_30_ticks_against_a_still_target_is_rejected_by_the_cap() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.net_sim_spec = REWIND_NET_SIM)
	var attacker: NetClient = _add_bot(VARDHEIM, 1)
	var target: NetClient = _add_bot(SOLMARCH, 2)
	if not assert_true(await _wait_until(_all_in_world, 900), "entran los dos bots"):
		return
	await wait_physics_frames(30)
	var home := Vector3(0.0, 0.05, 0.0)
	var target_id: int = target.get_net_id()
	var script_rng := RandomNumberGenerator.new()
	script_rng.seed = 7
	var script_state: Dictionary = {"last_press": -1000, "rng": script_rng}
	_set_script(attacker, _attacker_script(attacker, target_id, home, 0.0, script_state))
	_set_script(target, func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI
		return input)
	await wait_physics_frames(10)
	_server.teleport(attacker.get_net_id(), home)
	_server.teleport(target_id, Vector3(0.0, 0.05, -REWIND_DISTANCE))
	_server.get_combat().get_combatant(target_id).immortal = true
	await wait_physics_frames(60)
	var peer: ServerPeer = _peer_of(attacker.get_net_id())

	# Primero, sin trampa: tres golpes entran.
	assert_true(await _wait_until(func() -> bool: return _listeners[0].hits().size() >= 3, 600),
			"con la vista de verdad, los golpes entran")
	assert_eq(peer.suspicion_score, 0)
	# Ahora el atacante falsea su vista: 30 ticks atrás en todas sus entradas, más que el tope.
	script_state["armed"] = false
	await wait_physics_frames(REWIND_CYCLE_TICKS)
	var honest_hits: int = _listeners[0].hits().size()
	var health_before: int = _server.get_combat().get_combatant(target_id).health
	var swings_before: int = peer.swings
	attacker.batch_hook = func(batch: NetMessages.InputBatch) -> void:
		for index: int in batch.view_offsets_q.size():
			batch.view_offsets_q[index] = int(CHEAT_VIEW_TICKS * NetClient.VIEW_OFFSET_SCALE)
	script_state["armed"] = true
	assert_true(await _wait_until(func() -> bool: return peer.swings >= swings_before + 4, 600),
			"el tramposo lanza cuatro golpes más")
	await wait_physics_frames(60)
	assert_eq(_listeners[0].hits().size(), honest_hits, "ninguno de los golpes con la vista falseada entra")
	assert_true(_server.get_combat().get_combatant(target_id).health >= health_before,
			"y el objetivo no pierde vida")
	assert_true(_server.get_combat().stats[&"rewind_rejected"] >= 4,
			"el servidor los rechaza por el tope (%d)" % _server.get_combat().stats[&"rewind_rejected"])
	assert_eq(peer.rewind_rejects, _server.get_combat().stats[&"rewind_rejected"])
	assert_eq(peer.suspicion_score, peer.rewind_rejects, "y suman a su puntuación de sospecha")
	assert_eq(attacker.get_state(), NetClient.State.IN_WORLD, "no es un delito de red: sigue jugando")
	assert_eq(peer.strikes_total, 0, "sin avisos")
