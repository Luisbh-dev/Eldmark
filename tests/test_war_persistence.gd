extends TestCase
## Pruebas de la guerra persistente en la zona (docs/plataforma.md §8 y §15 P6, GUE-19): la ida y vuelta de
## [FortressPersistence] (ticks y hora Unix con el reloj fijo), arrancar con CONSOLIDATING a medias (dueño y plazo),
## CAPTURING que vuelve con su progreso (y, sin nadie, a VULNERABLE), la plataforma muda al arrancar, la lista vacía
## (estado inicial sin aviso) y otro esquema (con aviso), [code]version_conflict[/code] con reenvío, capturas y
## [code]defend_ticks[/code] (solo el dueño, sin [member NetEntity.gm_forced], que la reaparición quita), las
## capturas forzadas por un comando, la sección [code]pvp[/code] (reconexión y final antes de
## [method ScoreKeeper.forget]) y el lote de eventos reenviado sin duplicar.
## [br][br]
## Un [ZoneServer] sin red sobre la zona plana con la fortaleza de [FortressFixture], avanzado deprisa con su
## [FortressFixture.Stepper], y la plataforma falsa ([FakeZonePlatform]) con el reloj fijo; los personajes con
## reclamación se montan a mano como el alta de verdad (LOADING, reclamación, [method ProgressService.prepare] y
## CLIENT_READY). El arranque de verdad ([ServerMain] con [code]--platform[/code] contra [FakeHttpServer]) está en
## [code]test_war_platform_process.gd[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const FORTRESS: StringName = FortressFixture.FORTRESS_ID
const ZONE_ID: String = "test_world"
## La hora Unix de la plataforma falsa.
const NOW: int = 1_800_000_000
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"
const PHASE: Dictionary = {
	&"garrisoned": FortressState.Phase.GARRISONED, &"vulnerable": FortressState.Phase.VULNERABLE,
	&"capturing": FortressState.Phase.CAPTURING, &"consolidating": FortressState.Phase.CONSOLIDATING,
}


## Un transporte que no conecta nada y apunta lo que el servidor manda a cada peer.
class RecordingTransport:
	extends NetTransport

	var sent: Dictionary[int, Array] = {}

	func send(peer_id: int, _channel: int, bytes: PackedByteArray) -> Error:
		if not sent.has(peer_id):
			sent[peer_id] = []
		(sent[peer_id] as Array).append(bytes)
		return OK


var _viewport: SubViewport = null
var _world: Node3D = null
var _server: ZoneServer = null
var _platform: FakeZonePlatform = null
var _stepper: FortressFixture.Stepper = null
var _recorder: RecordingTransport = null
var _captured: Array[Array] = []


func after_each() -> void:
	if is_instance_valid(_stepper):
		_stepper.get_parent().remove_child(_stepper)
		_stepper.free()
	if is_instance_valid(_server):
		_server._transport = null
		_server.get_parent().remove_child(_server)
		_server.free()
	if is_instance_valid(_recorder):
		_recorder.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_stepper = null
	_server = null
	_recorder = null
	_platform = null
	_viewport = null
	_world = null
	_captured.clear()
	await wait_process_frames()


# --- Montaje ----------------------------------------------------------------------------------

## La zona plana con la fortaleza de pruebas (captura de 2 s, consolidación de 2 s) y el servidor sin red. Con
## [param with_platform], la plataforma falsa con el reloj en [constant NOW], ya arrancada y viva; [param setup]
## recibe la plataforma antes de arrancar (sus [member FakeZonePlatform.fake_fortresses], sus guiones…).
func _start(with_platform: bool = true, setup: Callable = Callable()) -> bool:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	FortressFixture.add_fortress(_world, FortressFixture.make_definition())
	FortressFixture.add_respawn_points(_world)
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.max_players = 16
	config.no_dummies = true
	config.no_npcs = true
	var keys: Dictionary[int, PackedByteArray] = {2: KEY_HEX.hex_decode()}
	if with_platform:
		config.platform_url = "http://fake"
		config.save_interval_s = 600
		_platform = FakeZonePlatform.new()
		_platform.name = "Platform"
		_platform.log_sink = func(_text: String) -> void: pass
		_platform.fake_now_unix = NOW
		_viewport.add_child(_platform)
		if setup.is_valid():
			setup.call(_platform)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	await wait_physics_frames(3)
	var provider: AuthProvider = DevAuthProvider.new()
	if with_platform:
		var finished: Array = await _start_platform(config, keys)
		if not assert_eq(finished, [[true, ""]], "la plataforma falsa arranca"):
			return false
		var tickets := TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, keys)
		tickets.log_sink = func(_text: String) -> void: pass
		provider = tickets
	if not assert_eq(_server.start(config, _world, null, provider, _platform), OK, "el servidor arranca"):
		return false
	_server.get_progress().log_sink = func(_text: String) -> void: pass
	_server.set_physics_process(false)
	_recorder = RecordingTransport.new()
	_server._transport = _recorder
	_stepper = FortressFixture.Stepper.new()
	_stepper.server = _server
	_viewport.add_child(_stepper)
	_server.get_fortresses().fortress_captured.connect(func(fortress_id: StringName, owner_realm: int,
			in_circle: PackedInt32Array, tick: int) -> void:
		_captured.append([fortress_id, owner_realm, in_circle, tick]))
	if with_platform:
		_platform.go_live()
		var live: bool = await _pump_until(func() -> bool: return _platform.is_live())
		if not assert_true(live, "la instancia está viva"):
			return false
	return true


## Arranca la plataforma falsa con [param config] y espera [signal ZonePlatform.startup_finished].
func _start_platform(config: ServerConfig, keys: Dictionary[int, PackedByteArray]) -> Array:
	var finished: Array = []
	_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	_platform.start(config, {"token": "token", "ticket_keys": keys})
	var started: int = Time.get_ticks_msec()
	while finished.is_empty() and Time.get_ticks_msec() - started < 5000:
		await wait_process_frames()
	return finished


## Fotogramas sin avanzar el servidor (las respuestas de la plataforma falsa llegan en ellos) hasta que se cumpla
## [param condition] o pasen [param max_ms] ms (o, con [param max_ms] 0, unos pocos fotogramas).
func _pump_until(condition: Callable, max_ms: int = 3000) -> bool:
	var started: int = Time.get_ticks_msec()
	var frames: int = 0
	while Time.get_ticks_msec() - started < max_ms or frames < 3:
		if condition.call():
			return true
		await wait_process_frames()
		frames += 1
	return bool(condition.call())


## Avanza [param ticks] ticks del servidor deprisa.
func _advance(ticks: int) -> void:
	_stepper.remaining += ticks
	while _stepper.remaining > 0:
		await tree.physics_frame


## Avanza de 2 en 2 ticks (con fotogramas entre medias para las respuestas de la plataforma) hasta que se cumpla
## [param condition] o pasen [param max_ticks].
func _advance_until(condition: Callable, max_ticks: int = 600) -> bool:
	var elapsed: int = 0
	while elapsed < max_ticks:
		if condition.call():
			return true
		await _advance(2)
		await wait_process_frames()
		elapsed += 2
	return bool(condition.call())


func _state() -> FortressState:
	return _server.get_fortresses().get_fortress_state(FORTRESS)


func _definition() -> FortressDefinition:
	return _server.get_fortresses().get_definition(FORTRESS)


func _persistence() -> FortressPersistence:
	return _server.get_fortress_persistence()


## Los PUT de fortaleza recibidos por la plataforma falsa.
func _puts() -> Array[Dictionary]:
	return _platform.sent(PlatformEvent.KIND_FORTRESS)


## Un registro de la fortaleza de pruebas con [param changes] sobre uno GARRISONED neutral entero.
func _record(changes: Dictionary) -> Dictionary:
	var record: Dictionary = {
		"schema": 1, "owner": 0, "phase": "garrisoned", "phase_ends_at_unix": null, "captain_alive": true,
		"captain_respawn_at_unix": null, "gate_health": 900, "capture_realm": 0, "capture_progress": 0,
		"last_reset_at_unix": NOW - 100,
	}
	record.merge(changes, true)
	return record


## Un jugador falso quieto de [param realm] en [param position].
func _idle_player(realm: int, position: Vector3) -> int:
	var brain := CombatFixture.ScriptBrain.new(1)
	var net_id: int = _server.add_fake_player(brain, realm)
	_server.teleport(net_id, position)
	return net_id


func _entity(net_id: int) -> NetEntity:
	return _server.get_registry().get_entity(net_id)


## Monta un peer con la reclamación [param claimed] como el alta de verdad y espera su alta.
func _enter(peer_id: int, claimed: ClaimedCharacter) -> ServerPeer:
	var peer := ServerPeer.new(peer_id)
	peer.state = ServerPeer.State.LOADING
	peer.realm = claimed.realm
	peer.display_name = claimed.display_name
	peer.loading_since_tick = _server.get_tick()
	_server._peers[peer_id] = peer
	peer.claimed = claimed
	assert_true(_server.get_progress().prepare(peer_id, claimed), "se prepara el registro")
	_server._pending_ready.append(peer_id)
	await _advance(1)
	assert_not_null(peer.entity, "el peer %d entra en el mundo" % peer_id)
	return peer


## La reclamación siguiente de [param character_id] en la plataforma falsa, con la ida y vuelta por JSON.
func _claim(character_id: int) -> ClaimedCharacter:
	var answer: Array = _platform._claim_answer({"character_id": str(character_id), "ticket_id": "1"})
	var json := JSON.new()
	json.parse(JSON.stringify(answer[1]))
	return ClaimedCharacter.from_claim(json.data)


## Sale [param peer] (como un CLIENT_LEAVE) y espera a que la plataforma conteste su guardado final.
func _leave(peer: ServerPeer) -> void:
	var saves_before: int = _platform.sent(PlatformEvent.KIND_SAVE).size()
	_server._mark_leaving(peer)
	await _advance(1)
	await _advance_until(func() -> bool:
		return _platform.sent(PlatformEvent.KIND_SAVE).size() > saves_before \
				and _server.get_saver().pending_count() == 0)
	_server._peers.erase(peer.peer_id)


## Los seis totales pvp de [param body] con int().
static func _pvp(body: Dictionary) -> Dictionary:
	var totals: Dictionary = {}
	var pvp: Dictionary = body.get("pvp", {}) if body.get("pvp") is Dictionary else {}
	for key: String in ClaimedCharacter.PVP_KEYS:
		totals[key] = int(pvp.get(key, -1))
	return totals


# --- FortressPersistence: la conversión --------------------------------------------------------

func test_the_record_round_trips_ticks_and_unix_time_with_a_fixed_clock() -> void:
	var def := FortressFixture.make_definition(30.0, 120.0)
	# CONSOLIDATING de Vardheim, a 50,5 s de los 120: el fin se escribe redondeado hacia arriba (69,5 → 70 s).
	var state := FortressState.initial(def, 0)
	state.owner = VARDHEIM
	state.phase = FortressState.Phase.CONSOLIDATING
	state.phase_tick = 1000
	state.captain_alive = false
	state.gate_health = 450
	state.last_reset_tick = 1000
	var tick: int = 1000 + 3030
	var record: Dictionary = FortressPersistence.to_record(state, def, tick, NOW)
	assert_eq(record, {"schema": 1, "owner": VARDHEIM, "phase": "consolidating", "phase_ends_at_unix": NOW + 70,
			"captain_alive": false, "captain_respawn_at_unix": null, "gate_health": 450, "capture_realm": 0,
			"capture_progress": 0, "last_reset_at_unix": NOW - 50}, "el registro de §8")
	# Por JSON (los números vuelven como float) y 10 s más tarde, en otro proceso que va por el tick 500.
	var json := JSON.new()
	json.parse(JSON.stringify(record))
	var loaded: FortressPersistence.Loaded = FortressPersistence.from_record(json.data, def, 500, NOW + 10)
	assert_eq(loaded.error, "", "vale")
	assert_eq(loaded.state.owner, VARDHEIM, "conserva el dueño")
	assert_eq(loaded.state.phase, FortressState.Phase.CONSOLIDATING)
	assert_eq(loaded.consolidation_ends_tick, 500 + 60 * 60, "y el plazo: quedan 60 s")
	assert_eq(loaded.state.gate_health, 450, "la vida de la puerta")
	assert_eq(loaded.state.gate_last_damage_tick, 500, "la reparación cuenta desde el arranque")
	assert_eq(loaded.state.last_reset_tick, 500 - 60 * 60, "el último reinicio, 60 s antes")
	assert_true(loaded.state.phase_tick >= 0, "el inicio de la fase cabe en OBJECT_STATE")

	# VULNERABLE: el capitán vuelve a los 299 s y un tick (→ 300 s).
	state = FortressState.initial(def, 0)
	state.owner = SOLMARCH
	state.on_captain_died(2000, VARDHEIM)
	state.captain_respawn_tick = 2000 + 299 * 60 + 1
	record = FortressPersistence.to_record(state, def, 2000, NOW)
	assert_eq(record["phase"], "vulnerable")
	assert_eq(record["captain_respawn_at_unix"], NOW + 300)
	assert_eq(record["phase_ends_at_unix"], NOW + 300, "la fase acaba cuando vuelve el capitán")
	loaded = FortressPersistence.from_record(record, def, 0, NOW + 100)
	assert_eq(loaded.state.phase, FortressState.Phase.VULNERABLE)
	assert_false(loaded.state.captain_alive)
	assert_eq(loaded.state.captain_respawn_tick, 200 * 60, "quedan 200 s")
	# Un plazo que ya pasó vuelve en el tick de la carga, nunca antes.
	loaded = FortressPersistence.from_record(record, def, 70, NOW + 400)
	assert_eq(loaded.state.captain_respawn_tick, 70)

	# CAPTURING: el progreso del tick en que se escribe.
	state = FortressState.initial(def, 0)
	state.on_captain_died(100, VARDHEIM)
	state.phase = FortressState.Phase.CAPTURING
	state.capture_realm = VARDHEIM
	state.capture_start_tick = 100
	state.capture_rate = 12
	state.capture_progress_at_start = 0
	record = FortressPersistence.to_record(state, def, 700, NOW)
	assert_eq([record["phase"], record["capture_realm"], record["capture_progress"]], ["capturing", VARDHEIM, 7200])
	loaded = FortressPersistence.from_record(record, def, 40, NOW + 3)
	assert_eq(loaded.state.phase, FortressState.Phase.CAPTURING, "con su captor y su progreso")
	assert_eq(loaded.state.capture_realm, VARDHEIM)
	assert_eq(loaded.state.progress_at(40), 7200)
	assert_eq([loaded.state.capture_rate, loaded.state.empty_since_tick], [0, 40], "el círculo vacío, decayendo")

	# GARRISONED neutral: sin plazos.
	record = FortressPersistence.to_record(FortressState.initial(def, 0), def, 0, NOW)
	assert_eq([record["phase_ends_at_unix"], record["captain_respawn_at_unix"], record["captain_alive"]],
			[null, null, true])


func test_a_record_that_does_not_fit_gives_the_initial_state_and_why() -> void:
	var def := FortressFixture.make_definition()
	var good: Dictionary = _record({"owner": SOLMARCH})
	assert_eq(FortressPersistence.from_record(good, def, 0, NOW).error, "", "el bueno vale")
	var cases: Array[Array] = [
		[{"schema": 2}, "esquema 2"],
		[{"owner": 4}, "owner"],
		[{"phase": "asediado"}, "phase"],
		[{"gate_health": -1}, "gate_health"],
		[{"captain_alive": 1}, "captain_alive"],
		[{"last_reset_at_unix": "ayer"}, "last_reset_at_unix"],
		[{"phase": "consolidating", "owner": 0, "phase_ends_at_unix": NOW}, "consolidating sin dueño"],
		[{"phase": "capturing", "owner": SOLMARCH, "capture_realm": SOLMARCH}, "capturing sin captor"],
	]
	for entry: Array in cases:
		var record: Dictionary = good.duplicate()
		record.merge(entry[0], true)
		var loaded: FortressPersistence.Loaded = FortressPersistence.from_record(record, def, 0, NOW)
		assert_true(loaded.error.contains(entry[1]), "%s → %s (%s)" % [entry[0], entry[1], loaded.error])
		assert_eq([loaded.state.owner, loaded.state.phase], [0, FortressState.Phase.GARRISONED],
				"y el estado inicial")
	assert_eq(FortressPersistence.from_record("{}", def, 0, NOW).error, "no es un objeto")
	var no_schema: Dictionary = good.duplicate()
	no_schema.erase("schema")
	assert_eq(FortressPersistence.from_record(no_schema, def, 0, NOW).error, "esquema desconocido")


# --- El arranque con la plataforma -------------------------------------------------------------

func test_starting_with_consolidating_half_way_keeps_the_owner_and_the_deadline() -> void:
	var saved: Dictionary = _record({"owner": SOLMARCH, "phase": "consolidating", "phase_ends_at_unix": NOW + 1,
			"captain_alive": false, "gate_health": 450})
	var started: bool = await _start(true, func(platform: FakeZonePlatform) -> void:
		platform.fake_fortresses = [{"fortress_id": String(FORTRESS), "record": saved, "version": 4}])
	if not started:
		return
	var load_tick: int = 0
	assert_eq([_state().owner, _state().phase, _state().gate_health], [SOLMARCH,
			FortressState.Phase.CONSOLIDATING, 450], "conserva dueño, fase y puerta")
	assert_eq(_server.get_fortresses().get_consolidation_end_tick(FORTRESS), load_tick + 60, "y el plazo: 1 s")
	assert_eq(_server.get_fortresses().get_gate(FORTRESS).collision_layer, FortGate.layers_for(SOLMARCH, false),
			"la puerta es de Solmarch")
	assert_false(_server.get_fortresses().get_entity(FORTRESS).encode_spawn(_server.get_tick(), false).is_empty(),
			"el alta de la fortaleza se codifica (ningún tick negativo)")
	assert_eq(_persistence().get_stats()["loaded"], 1)
	await _advance(58 - _server.get_tick())
	await _pump_until(func() -> bool: return false, 50)
	assert_eq(_state().phase, FortressState.Phase.CONSOLIDATING, "a 2 ticks del fin, consolidando")
	assert_eq(_puts().size(), 0, "cargar no escribe nada")
	# El reloj falso no anda solo: en el tick 60 ha pasado 1 s.
	_platform.fake_now_unix = NOW + 1
	await _advance(60 - _server.get_tick())
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "en su tick, la guarnición")
	assert_eq(_state().owner, SOLMARCH)
	var written: bool = await _pump_until(func() -> bool: return _puts().size() == 1)
	if assert_true(written, "el cambio de fase se escribe enseguida"):
		var put: Dictionary = _puts()[0]
		assert_eq(int(put["expected_version"]), 4, "con la versión del GET")
		var record: Dictionary = put["record"]
		assert_eq([int(record["owner"]), record["phase"], int(record["gate_health"])], [SOLMARCH, "garrisoned",
				450])
		assert_eq(int(record["last_reset_at_unix"]), NOW - 100, "el ciclo de reinicio no vuelve a empezar")


func test_capturing_comes_back_with_its_progress_and_falls_to_vulnerable_if_nobody_returns() -> void:
	# Captura de 2 s: 120 ticks × 12 = 1440 de progreso; vuelve con 600.
	var saved: Dictionary = _record({"phase": "capturing", "captain_alive": false, "capture_realm": VARDHEIM,
			"capture_progress": 600})
	var started: bool = await _start(true, func(platform: FakeZonePlatform) -> void:
		platform.fake_fortresses = [{"fortress_id": String(FORTRESS), "record": saved, "version": 2}])
	if not started:
		return
	assert_eq([_state().phase, _state().capture_realm, _state().progress_at(_server.get_tick())],
			[FortressState.Phase.CAPTURING, VARDHEIM, 600], "con su captor y su progreso")
	await _advance(30)
	assert_eq(_state().progress_at(_server.get_tick()), 600, "el círculo vacío espera su retardo (1 s)")
	# Después decae a −4 por tick: 600 / 4 = 150 ticks.
	var fell: bool = await _advance_until(func() -> bool:
		return _state().phase == FortressState.Phase.VULNERABLE, 300)
	if assert_true(fell, "sin nadie, vuelve a VULNERABLE"):
		assert_true(_server.get_tick() >= 60 + 150 and _server.get_tick() <= 60 + 150 + 6,
				"al decaer a 0 (tick %d)" % _server.get_tick())
		assert_false(_state().captain_alive, "el capitán sigue caído")
		assert_eq(_state().capture_realm, 0)
		assert_eq(_state().captain_respawn_tick, _state().phase_tick + _definition().captain_respawn_ticks(),
				"con un plazo nuevo para el capitán")


func test_the_captors_that_come_back_continue_from_the_saved_progress() -> void:
	var saved: Dictionary = _record({"phase": "capturing", "captain_alive": false, "capture_realm": VARDHEIM,
			"capture_progress": 1200})
	var started: bool = await _start(true, func(platform: FakeZonePlatform) -> void:
		platform.fake_fortresses = [{"fortress_id": String(FORTRESS), "record": saved, "version": 2}])
	if not started:
		return
	_idle_player(VARDHEIM, FortressFixture.circle_center())
	# Faltan 240: con uno dentro, 12 por tick, 20 ticks (más el recuento cada 6).
	var captured: bool = await _advance_until(func() -> bool: return _state().owner == VARDHEIM, 60)
	assert_true(captured and _server.get_tick() <= 30, "Vardheim termina lo que empezó (tick %d)" % _server.get_tick())


func test_a_platform_that_never_answers_the_fortresses_stops_the_startup_without_writing() -> void:
	_viewport = SubViewport.new()
	tree.root.add_child(_viewport)
	_platform = FakeZonePlatform.new()
	_platform.name = "Platform"
	_platform.log_sink = func(_text: String) -> void: pass
	_platform.startup_limit_s = 1.0
	for _i: int in 40:
		_platform.script_next(&"fortresses", 0, null)
	_viewport.add_child(_platform)
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.platform_url = "http://fake"
	var keys: Dictionary[int, PackedByteArray] = {2: KEY_HEX.hex_decode()}
	var finished: Array = await _start_platform(config, keys)
	assert_eq(finished, [[false, "No se han podido leer las fortalezas de la plataforma: sin respuesta de la plataforma"]],
			"sin respuesta no es «sin registro»: el arranque falla")
	assert_true(_platform.sent(&"fortresses").size() >= 3, "tras reintentarlo (%d)" % _platform.sent(&"fortresses").size())
	assert_true(_platform.fortress_records().is_empty(), "ninguna fortaleza cargada")
	assert_eq(_platform.sent(PlatformEvent.KIND_ID_BLOCK).size(), 0, "ni el primer bloque")
	assert_eq(_platform.sent(PlatformEvent.KIND_FORTRESS).size(), 0, "y nada escrito: el dueño guardado no se pisa")


func test_an_empty_list_is_the_initial_state_without_a_warning_and_is_written_once_live() -> void:
	if not await _start(true):
		return
	assert_eq([_state().owner, _state().phase, _state().gate_health], [0, FortressState.Phase.GARRISONED, 900])
	var stats: Dictionary = _persistence().get_stats()
	assert_eq([stats["initial"], stats["discarded"], stats["loaded"]], [1, 0, 0], "estado inicial, sin aviso")
	await _advance(1)
	var written: bool = await _pump_until(func() -> bool: return _puts().size() == 1)
	if assert_true(written, "el primer arranque escribe el estado inicial en cuanto la instancia está viva"):
		assert_eq(int(_puts()[0]["expected_version"]), 0, "crea la fila")
		assert_eq(_puts()[0]["record"]["phase"], "garrisoned")
	await _advance(120)
	await _pump_until(func() -> bool: return false, 50)
	assert_eq(_puts().size(), 1, "sin cambios no escribe más")


func test_a_record_with_another_schema_is_the_initial_state_with_a_warning() -> void:
	var started: bool = await _start(true, func(platform: FakeZonePlatform) -> void:
		platform.fake_fortresses = [{"fortress_id": String(FORTRESS), "record": _record({"schema": 2,
				"owner": SOLMARCH}), "version": 9}])
	if not started:
		return
	assert_eq(_state().owner, 0, "estado inicial")
	var stats: Dictionary = _persistence().get_stats()
	assert_eq([stats["discarded"], stats["initial"]], [1, 0], "con aviso")
	await _advance(30)
	await _pump_until(func() -> bool: return false, 50)
	assert_eq(_puts().size(), 0, "no lo pisa hasta que cambie algo")
	_server.console_command("fort_owner vardheim")
	await _advance(1)
	var written: bool = await _pump_until(func() -> bool: return _puts().size() == 1)
	if assert_true(written, "el cambio se escribe"):
		assert_eq(int(_puts()[0]["expected_version"]), 9, "sobre la versión que había")


func test_a_version_conflict_resends_the_record_with_the_new_version() -> void:
	var started: bool = await _start(true, func(platform: FakeZonePlatform) -> void:
		platform.script_next(PlatformEvent.KIND_FORTRESS, 409, FakeZonePlatform.error_body("version_conflict",
				"El registro de la fortaleza ha cambiado", {"version": 7})))
	if not started:
		return
	await _advance(1)
	var resent: bool = await _advance_until(func() -> bool:
		return _puts().size() == 2 and int(_persistence().get_stats()["put_ok"]) == 1, 60)
	if not assert_true(resent, "tras el 409 se reenvía"):
		return
	assert_eq([int(_puts()[0]["expected_version"]), int(_puts()[1]["expected_version"])], [0, 7],
			"con la versión del error")
	assert_eq(_puts()[1]["record"], _puts()[0]["record"], "el mismo registro: la instancia viva manda")
	assert_eq(_persistence().get_stats()["put_conflicts"], 1)
	# El siguiente cambio va con la versión que dio el 200 (la del falso, 1).
	_server.console_command("fort_owner solmarch")
	await _advance(1)
	await _pump_until(func() -> bool: return _puts().size() == 3)
	assert_eq(int(_puts()[2]["expected_version"]), 1, "y el siguiente, con la del 200")


# --- Capturas, tiempo defendiendo y cambios forzados ------------------------------------------------

func test_captures_and_defend_ticks_count_only_the_owner_and_skip_gm_forced() -> void:
	if not await _start(false):
		return
	var circle: Vector3 = FortressFixture.circle_center()
	var first: int = _idle_player(VARDHEIM, circle)
	var second: int = _idle_player(VARDHEIM, circle + Vector3(1.0, 0.0, 0.0))
	var forced: int = _idle_player(VARDHEIM, circle + Vector3(0.0, 0.0, 1.0))
	var outside: int = _idle_player(VARDHEIM, circle + Vector3(20.0, 0.0, 0.0))
	var enemy: int = _idle_player(SOLMARCH, circle + Vector3(-20.0, 0.0, 0.0))
	_entity(forced).gm_forced = true
	var scores: ScoreKeeper = _server.get_scores()
	# El capitán cae en combate (un cambio de verdad).
	assert_true(_server.get_fortresses().on_captain_died(FORTRESS, _server.get_tick(), VARDHEIM))
	var captured: bool = await _advance_until(func() -> bool: return _state().owner == VARDHEIM, 200)
	if not assert_true(captured, "Vardheim captura"):
		return
	assert_eq([scores.get_entry(first).captures, scores.get_entry(second).captures], [1, 1],
			"los del captor en el círculo suman una captura")
	assert_eq(scores.get_entry(forced).captures, 0, "el marcado por un comando de GM, no")
	assert_true(scores.get_entry(outside) == null or scores.get_entry(outside).captures == 0, "el de fuera, no")
	if assert_eq(_captured.size(), 1, "la lista sale una vez"):
		assert_eq(_captured[0][2], PackedInt32Array([first, second]), "la misma que suma ScoreKeeper")
		assert_eq(_captured[0][1], VARDHEIM)
	assert_eq(scores.get_entry(first).defend_ticks, 0, "capturar no es defender")
	# Consolidación (2 s) y guarnición; el capitán de Vardheim cae: el círculo se abre con el dueño dentro.
	await _advance_until(func() -> bool: return _state().phase == FortressState.Phase.GARRISONED, 200)
	await _advance(12)
	assert_eq(scores.get_entry(first).defend_ticks, 0, "con el círculo cerrado no se defiende")
	_server.teleport(enemy, circle + Vector3(-1.0, 0.0, 0.0))
	assert_true(_server.get_fortresses().on_captain_died(FORTRESS, _server.get_tick(), SOLMARCH))
	await _advance(120)
	assert_true(scores.get_entry(first).defend_ticks >= 108 and scores.get_entry(first).defend_ticks <= 126,
			"el dueño en el círculo activo defiende (%d ticks)" % scores.get_entry(first).defend_ticks)
	assert_eq(scores.get_entry(second).defend_ticks, scores.get_entry(first).defend_ticks)
	assert_eq(scores.get_entry(forced).defend_ticks, 0, "el marcado, no")
	assert_eq(scores.get_entry(enemy).defend_ticks, 0, "el atacante, no")
	assert_true(scores.get_entry(enemy).circle_ticks > 0, "aunque sí cuenta en el círculo (méritos)")
	# La reaparición quita la marca.
	_server.console_command("kill %d" % forced)
	await _advance(2)
	var combatant: Combatant = _server.get_combat().get_combatant(forced)
	await _advance(maxi(combatant.respawn_tick - _server.get_tick() - 6, 0))
	assert_true(_entity(forced).gm_forced, "muerto sigue marcado")
	assert_eq(_server.get_combat().request_respawn(forced, 0, _server.get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED)
	await _advance(10)
	assert_false(_entity(forced).gm_forced, "al reaparecer, ya no")


func test_a_capture_forced_by_a_fort_command_does_not_count() -> void:
	if not await _start(false):
		return
	var circle: Vector3 = FortressFixture.circle_center()
	var vardheim: int = _idle_player(VARDHEIM, circle)
	var scores: ScoreKeeper = _server.get_scores()
	var fortresses: FortressController = _server.get_fortresses()
	assert_false(fortresses.is_forced(FORTRESS), "al arrancar no hay nada forzado")
	# Con fort_capture_speed ≠ 1 la captura es forzada, aunque el capitán caiga en combate.
	_server.console_command("fort_capture_speed 20")
	assert_true(fortresses.on_captain_died(FORTRESS, _server.get_tick(), VARDHEIM))
	assert_true(fortresses.is_forced(FORTRESS))
	await _advance_until(func() -> bool: return _state().owner == VARDHEIM, 100)
	assert_eq(_state().owner, VARDHEIM, "capturado a x20")
	assert_true(scores.get_entry(vardheim) == null or scores.get_entry(vardheim).captures == 0, "sin captura")
	assert_eq(_captured.size(), 0, "ni lista")
	# Vuelve a x1; la guarnición de Vardheim llega por sí sola: el ciclo deja de ser forzado.
	_server.console_command("fort_capture_speed 1")
	assert_true(fortresses.is_forced(FORTRESS), "x1 no borra lo que ya era forzado")
	await _advance_until(func() -> bool: return _state().phase == FortressState.Phase.GARRISONED, 200)
	assert_false(fortresses.is_forced(FORTRESS), "la guarnición que llega sola empieza un ciclo de verdad")
	# Solmarch la captura de verdad y suma.
	_server.teleport(vardheim, circle + Vector3(30.0, 0.0, 0.0))
	var solmarch: int = _idle_player(SOLMARCH, circle)
	assert_true(fortresses.on_captain_died(FORTRESS, _server.get_tick(), SOLMARCH))
	await _advance_until(func() -> bool: return _state().owner == SOLMARCH, 200)
	assert_eq(scores.get_entry(solmarch).captures, 1, "una captura de verdad suma")
	# fort_owner: el cambio es forzado y no suma a nadie.
	_server.console_command("fort_owner vardheim")
	assert_true(fortresses.is_forced(FORTRESS), "fort_owner es forzado")
	await _advance(12)
	assert_eq(scores.get_entry(solmarch).captures, 1)
	# fort_kill_captain abre un círculo forzado: la captura que sigue no suma ni sale.
	_server.console_command("fort_kill_captain")
	assert_true(fortresses.is_forced(FORTRESS), "fort_kill_captain es forzado")
	await _advance_until(func() -> bool: return _state().owner == SOLMARCH, 200)
	assert_eq(_state().owner, SOLMARCH, "Solmarch recupera el fuerte")
	assert_eq(scores.get_entry(solmarch).captures, 1, "sin sumar: lo abrió un comando")
	assert_eq(_captured.size(), 1, "solo la captura de verdad salió")
	# fort_reset también es forzado; el capitán que cae en combate después lo quita.
	_server.console_command("fort_reset")
	assert_true(fortresses.is_forced(FORTRESS))
	await _advance(2)
	assert_true(fortresses.on_captain_died(FORTRESS, _server.get_tick(), SOLMARCH))
	assert_false(fortresses.is_forced(FORTRESS), "la muerte del capitán en combate es de verdad")


func test_the_captain_killed_by_a_command_is_already_forced_when_its_death_goes_out() -> void:
	if not await _start(false):
		return
	var captain: int = _server.spawn_captain_double(FORTRESS)
	if not assert_true(captain > 0, "el doble del capitán aparece"):
		return
	var seen: Array[bool] = []
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
		if event.event == NetMessages.EntityEvent.Kind.DEATH and event.net_id == captain:
			seen.append(_server.get_fortresses().is_forced(FORTRESS)))
	assert_false(_server.get_fortresses().is_forced(FORTRESS))
	assert_eq(_server.console_command("fort_kill_captain"), "El capitán de %s ha muerto" % FORTRESS)
	await _advance(2)
	assert_eq(seen, [true] as Array[bool], "su muerte ya sale forzada (on_npc_killed no la paga, progresion.md P5c)")
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)


# --- Sección pvp ---------------------------------------------------------------------------------

func test_the_pvp_section_survives_a_reconnection_and_the_final_is_built_before_forget() -> void:
	if not await _start(true):
		return
	var ids: bool = await _advance_until(func() -> bool: return _server.get_progress().get_ids().available() > 0)
	if not assert_true(ids, "llega el primer bloque de ids"):
		return
	_platform.add_character(41, 410, &"player", VARDHEIM, {}, {"kills": 3, "deaths": 2, "assists": 1,
			"captures": 1, "gate_damage": 450, "defend_s": 120}, "Aneira")
	var peer: ServerPeer = await _enter(1, _claim(41))
	if peer == null or peer.entity == null:
		return
	var net_id: int = peer.entity.net_id
	var scores: ScoreKeeper = _server.get_scores()
	assert_eq(scores.pvp_totals(net_id), {"kills": 3, "deaths": 2, "assists": 1, "captures": 1, "gate_damage": 450,
			"defend_s": 120}, "la base son los totales de la reclamación")
	assert_false(scores.is_section_dirty(net_id), "entrar no ensucia la sección")
	# El crítico del kit lleva ya la sección pvp, detrás de progress.
	var kit_saved: bool = await _advance_until(func() -> bool: return not _platform.applied(41).is_empty())
	if assert_true(kit_saved, "el crítico del kit se aplica"):
		var kit: Dictionary = _platform.applied(41)
		assert_true(kit.has("progress") and kit.has("pvp"), "con las dos secciones")
		assert_eq(_pvp(kit), scores.pvp_totals(net_id))
	# La sesión: dos bajas, una captura, 125 ticks defendiendo (2 s) y daño a la puerta.
	scores.add_kill(net_id)
	scores.add_kill(net_id)
	scores.add_capture(net_id)
	scores.add_defend_ticks(net_id, 125)
	scores.add_gate_damage(net_id, 50)
	assert_true(scores.is_section_dirty(net_id), "la sesión ensucia la sección")
	var expected: Dictionary = {"kills": 5, "deaths": 2, "assists": 1, "captures": 2, "gate_damage": 500,
			"defend_s": 122}
	assert_eq(scores.pvp_totals(net_id), expected, "cargado más la sesión (defend_s = 120 + 125 / 60)")
	await _leave(peer)
	var final: Dictionary = _platform.applied(41)
	assert_eq(int(final.get("reason", 0)), CharacterSaver.Reason.LOGOUT, "el final de la salida")
	assert_eq(_pvp(final), expected, "construido antes de ScoreKeeper.forget: lleva la sesión")
	assert_null(scores.get_entry(net_id), "y después se olvida")
	# La reconexión trae lo último aplicado y sigue desde ahí.
	var again: ClaimedCharacter = _claim(41)
	assert_eq(again.pvp, expected, "la plataforma devuelve los totales")
	var back: ServerPeer = await _enter(2, again)
	if back == null or back.entity == null:
		return
	assert_eq(scores.pvp_totals(back.entity.net_id), expected, "y la zona los toma como base")
	scores.add_kill(back.entity.net_id)
	assert_eq(int(scores.pvp_totals(back.entity.net_id)["kills"]), 6)


func test_the_pvp_section_is_clean_after_its_body_is_acknowledged() -> void:
	var scores := ScoreKeeper.new()
	scores.load_totals(5, {"kills": 1.0, "deaths": 0, "assists": 0, "captures": 0, "gate_damage": 0, "defend_s": 0})
	assert_false(scores.is_section_dirty(5))
	scores.add_kill(5)
	assert_true(scores.is_section_dirty(5))
	var body: Dictionary = scores.build_section(5, 1)
	assert_eq(int(body["kills"]), 2)
	scores.add_death(5)
	scores.acknowledge_section(5, 1)
	assert_true(scores.is_section_dirty(5), "lo que pasó después del cuerpo 1 sigue sucio")
	scores.build_section(5, 2)
	scores.acknowledge_section(5, 2)
	assert_false(scores.is_section_dirty(5), "confirmado el 2, limpia")
	scores.add_defend_ticks(5, 59)
	assert_false(scores.is_section_dirty(5), "menos de un segundo defendiendo no cambia defend_s")
	scores.add_defend_ticks(5, 1)
	assert_true(scores.is_section_dirty(5))
	# Un total que no cabe en la columna se recorta: con greatest en la plataforma no baja nada.
	scores.load_totals(6, {"kills": 2147483647})
	scores.add_kill(6)
	assert_eq(int(scores.pvp_totals(6)["kills"]), 2147483647)


# --- Historial ---------------------------------------------------------------------------------

func test_a_resent_war_event_batch_does_not_duplicate_anything() -> void:
	var started: bool = await _start(true, func(platform: FakeZonePlatform) -> void:
		platform.script_next(&"war", 503, FakeZonePlatform.error_body("db_unavailable")))
	if not started:
		return
	_idle_player(VARDHEIM, FortressFixture.circle_center())
	assert_true(_server.get_fortresses().on_captain_died(FORTRESS, _server.get_tick(), VARDHEIM))
	await _advance_until(func() -> bool: return _state().owner == VARDHEIM, 200)
	_server.console_command("fort_reset")
	await _advance(2)
	_platform.begin_flush()
	var delivered: bool = await _pump_until(func() -> bool:
		var keys: Dictionary = {}
		for body: Dictionary in _platform.sent(&"war"):
			for entry: Dictionary in body.get("events", []):
				keys[entry["key"]] = true
		return keys.size() >= 3 and _platform.is_flushed())
	if not assert_true(delivered, "los lotes llegan"):
		return
	var batches: Array[Dictionary] = _platform.sent(&"war")
	assert_true(batches.size() >= 2, "el primero se reenvía tras el 503")
	assert_eq(batches[1], batches[0], "con los mismos bytes: las mismas claves, que la plataforma no duplica")
	var seen: Dictionary = {}
	var events: Array = []
	for index: int in batches.size():
		if index == 1:
			continue
		for entry: Dictionary in batches[index].get("events", []):
			assert_false(seen.has(entry["key"]), "la clave %s no se repite entre lotes distintos" % entry["key"])
			seen[entry["key"]] = true
			events.append([int(entry["event"]), int(entry["realm"]), entry["fortress_id"], int(entry["at_unix"])])
	assert_eq(events, [[WarEvents.CAPTURE_STARTED, VARDHEIM, String(FORTRESS), NOW],
			[WarEvents.FORT_CAPTURED, VARDHEIM, String(FORTRESS), NOW],
			[WarEvents.FORT_RESET, 0, String(FORTRESS), NOW]],
			"solo los avisos 3, 6 y 7 (ni el capitán caído ni el ataque), con su reino y su hora")
	for key: String in seen:
		assert_true(key.begins_with(_platform.instance_id() + ":"), "la clave es de la instancia (%s)" % key)
