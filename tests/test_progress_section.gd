extends TestCase
## Pruebas de la sección [code]progress[/code] de [CharacterSaver] en [ZoneServer] con [FakeZonePlatform] y clientes
## de verdad sobre ENet en 127.0.0.1 (docs/progresion.md §9 y §15 P5a): la sección registrada la primera; el kit de
## la primera entrada como crítico; el reintento con el mismo cuerpo; [code]duplicate[/code] confirma;
## [code]lease_lost[/code] descarta el estado; un 400 [code]invalid_save[/code] expulsa y libera, y después ningún
## gancho de [ProgressService] falla con ese [code]net_id[/code]; [method PlayerProgress.is_dirty] con solo moverse
## o perder vida; [code]prepare[/code] con un registro roto → REJECT UNAVAILABLE y liberación; irse en LOADING →
## [code]cancel_prepared[/code] y liberación; la reclamación siguiente del falso trae lo último aplicado; y el final
## construido con un guardado en vuelo sale tras él sin repetir sus operaciones.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const ZONE_ID: String = "test_world"
const FIRST_TICKET_ID: int = 9007199254740993
# Los personajes tienen el punto de control en la fase character_id % 3600: con 2042 y 2043, a los 34 s, después de
# cada prueba. Así solo salen los guardados que cada una provoca.

var _viewport: SubViewport
var _world: Node3D
var _server: ZoneServer
var _server_transport: NetTransport
var _platform: FakeZonePlatform
var _provider: TicketAuthProvider
var _keys: Dictionary[int, PackedByteArray] = {}
var _port: int = 0
var _clients: Array[RawTicketClient] = []
var _client_tick: int = 0
var _next_client_index: int = 0
var _next_ticket_id: int = FIRST_TICKET_ID
var _sim_hash: int = -1


func before_each() -> void:
	_keys = {2: "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858".hex_decode()}


func after_each() -> void:
	for client: RawTicketClient in _clients:
		if is_instance_valid(client.transport):
			client.transport.free()
	_clients.clear()
	if is_instance_valid(_server):
		_server.free()
	if is_instance_valid(_server_transport):
		_server_transport.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_server = null
	_server_transport = null
	_platform = null
	_provider = null
	_world = null
	_viewport = null
	_client_tick = 0
	_sim_hash = -1
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

## La zona de prueba con la plataforma falsa ya arrancada y el servidor escuchando (puntos de control cada 60 s: en
## estas pruebas solo salen los críticos y los finales). [param setup] recibe la plataforma antes de arrancar.
func _start(setup: Callable = Callable()) -> bool:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	_server_transport = NetTransport.new()
	_server_transport.name = "ServerTransport"
	_viewport.add_child(_server_transport)
	_platform = FakeZonePlatform.new()
	_platform.name = "Platform"
	_platform.log_sink = func(_text: String) -> void: pass
	_viewport.add_child(_platform)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.platform_url = "http://fake"
	config.save_interval_s = 60
	_port = NetHarness.free_udp_port()
	config.port = _port
	if setup.is_valid():
		setup.call(_platform)
	var finished: Array = []
	_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	_platform.start(config, {"token": "token", "ticket_keys": _keys})
	for _i: int in 120:
		if not finished.is_empty():
			break
		await wait_process_frames()
	if not assert_eq(finished, [[true, ""]], "la plataforma falsa arranca"):
		return false
	_provider = TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, _keys)
	_provider.log_sink = func(_text: String) -> void: pass
	if not assert_eq(_server.start(config, _world, _server_transport, _provider, _platform), OK,
			"el servidor abre el puerto %d" % _port):
		return false
	_server.get_progress().log_sink = func(_text: String) -> void: pass
	_platform.go_live()
	return true


func _ticket(character_id: int) -> PackedByteArray:
	var ticket := HandoffTicket.new()
	ticket.key_id = 2
	ticket.world_id = 1
	ticket.ticket_id = _next_ticket_id
	_next_ticket_id += 1
	ticket.character_id = character_id
	ticket.zone_key = HandoffTicket.zone_key_of(ZONE_ID)
	ticket.realm = VARDHEIM
	ticket.flags = HandoffTicket.FLAG_FROM_MENU
	ticket.issued_at = _platform.now_unix()
	ticket.expires_at = ticket.issued_at + 10
	return ticket.sign(_keys[2])


func _client_sim_hash() -> int:
	if _sim_hash >= 0:
		return _sim_hash
	var character: PlayerCharacter = PLAYER_SCENE.instantiate() as PlayerCharacter
	_world.add_child(character)
	_sim_hash = NetProtocol.compute_sim_hash(character)
	_world.remove_child(character)
	character.free()
	return _sim_hash


func _connect(character_id: int, auto_ready: bool = true) -> RawTicketClient:
	var hello := NetMessages.Hello.new()
	hello.sim_hash = _client_sim_hash()
	hello.realm = VARDHEIM
	hello.display_name = "Cualquiera"
	hello.character_id = character_id
	hello.ticket = _ticket(character_id)
	var transport := NetTransport.new()
	transport.name = "ClientTransport%d" % _next_client_index
	_next_client_index += 1
	_viewport.add_child(transport)
	var client := RawTicketClient.new(transport, hello.encode())
	client.auto_ready = auto_ready
	_clients.append(client)
	assert_eq(transport.connect_to("127.0.0.1", _port, 2000), OK, "el cliente conecta")
	return client


func _step() -> void:
	await tree.physics_frame
	_client_tick += 1
	for client: RawTicketClient in _clients:
		if not is_instance_valid(client.transport):
			continue
		client.transport.poll(_client_tick)
		client.step()
		client.transport.flush()


func _run_until(condition: Callable, max_ms: int = 5000) -> bool:
	var started: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < max_ms:
		if condition.call():
			return true
		await _step()
	return condition.call()


func _run_ms(ms: int) -> void:
	var started: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < ms:
		await _step()


## Entra con billete el personaje [param character_id], espera su alta y que su primer guardado (el kit, si lo hay)
## tenga respuesta.
func _join(character_id: int) -> RawTicketClient:
	var client: RawTicketClient = _connect(character_id)
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null or client.reject != null)
	if not assert_true(joined and client.own_spawn != null, "el personaje %d entra en el mundo" % character_id):
		return null
	await _run_until(func() -> bool: return _server.get_saver().pending_count() == 0)
	return client


func _progress() -> ProgressService:
	return _server.get_progress()


func _saves() -> Array[Dictionary]:
	return _platform.sent(PlatformEvent.KIND_SAVE)


func _releases() -> Array[Dictionary]:
	return _platform.sent(ZonePlatform.KIND_RELEASE)


func _has_body(net_id: int) -> bool:
	return _server.get_registry().get_entity(net_id) != null


func _op_ids(body: Dictionary) -> Array:
	return ((body["progress"] as Dictionary)["ops"] as Array).map(func(o: Dictionary) -> String: return o["op_id"])


# Una operación GM de +[param gold] de oro en el progreso de [param net_id].
func _gm_gold(net_id: int, gold: int) -> EconomyOp:
	var player: PlayerProgress = _progress().get_player(net_id)
	var op: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 7, "prueba", {"command": "currency_add",
			"source": "console", "at_unix": _platform.now_unix(), "args": [str(player.character_id), "oro",
			str(gold)]})
	player.change_currency(op, Currency.Code.GOLD, gold, EconomyReason.GM_GRANT, 0, 0)
	return op


# --- Pruebas ----------------------------------------------------------------------------------

## La sección progress es la primera de CharacterSaver y la primera entrada sale con el kit como crítico, en el
## mismo tick del alta, con su STARTER_KIT y la foto del personaje.
func test_the_section_is_registered_first_and_the_kit_is_critical() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})):
		return
	# Desde plataforma.md P6, start registra también la de verdad de pvp (ScoreKeeper), detrás de progress.
	assert_eq(_server.get_saver().section_names(), [ProgressService.SECTION, ScoreKeeper.SECTION] as Array[StringName],
			"progress, registrada en start la primera")
	var other := FakeSaveSection.new()
	other.attach(_server.get_saver())
	assert_eq(_server.get_saver().section_names(), [&"progress", &"pvp"] as Array[StringName],
			"la falsa sustituye a pvp y progress sigue la primera")
	var client: RawTicketClient = await _join(2042)
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	assert_true(_progress().has_inventory(net_id), "el cuerpo tiene su progreso")
	var saves: Array[Dictionary] = _saves()
	if not assert_eq(saves.size(), 1, "un guardado: el del kit"):
		return
	assert_eq(int(saves[0]["reason"]), CharacterSaver.Reason.CRITICAL, "crítico")
	var progress: Dictionary = saves[0]["progress"]
	assert_eq(progress["starter_granted"], true, "con starter_granted")
	var ops: Array = progress["ops"]
	if assert_eq(ops.size(), 1, "una operación"):
		assert_eq(int(ops[0]["kind"]), EconomyOp.Kind.STARTER_KIT, "STARTER_KIT")
		assert_eq((ops[0]["items"] as Array).size(), 4, "con los cuatro objetos del kit del arquero")
	assert_eq((progress["items"] as Array).size(), 4, "y la foto con ellos")
	assert_eq(progress["location"]["zone_id"], ZONE_ID, "la posición, en esta zona")
	assert_false(progress.has("race_id") or progress.has("appearance") or progress.has("starter_template_id"),
			"sin los campos de solo lectura")
	assert_true(saves[0].has("pvp"), "y la sección pvp detrás")
	assert_eq(_progress().get_player(net_id).unconfirmed_count(), 0, "el 200 confirma: el diario se vacía")
	assert_false(_progress().get_player(net_id).is_dirty(), "y queda limpio")
	assert_eq(_progress().get_ids().available(), 1024 - 5, "el kit gasta 5 ids del primer bloque")


## Sin respuesta (sin conexión) el guardado se reintenta con el mismo cuerpo; un duplicate confirma como un applied.
func test_a_retry_resends_the_same_body_and_duplicate_confirms() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})
			platform.script_next(PlatformEvent.KIND_SAVE, 0, null)
			platform.script_next(PlatformEvent.KIND_SAVE, 0, null)
			platform.script_next(PlatformEvent.KIND_SAVE, 200, {"applied": false, "duplicate": true,
					"save_version": 1, "instance_status": "live"})):
		return
	var client: RawTicketClient = await _join(2042)
	if client == null:
		return
	var saves: Array[Dictionary] = _saves()
	if assert_eq(saves.size(), 3, "dos intentos sin respuesta y el tercero"):
		assert_eq(saves[1], saves[0], "el mismo cuerpo")
		assert_eq(saves[2], saves[0], "también el tercero")
	var player: PlayerProgress = _progress().get_player(client.own_spawn.net_id)
	assert_eq(player.unconfirmed_count(), 0, "duplicate confirma: el kit sale del diario")
	assert_false(player.is_dirty(), "y queda limpio")


## Un lease_lost (del latido o de un guardado) es la baja sin guardado: el estado se descarta (on_departure).
func test_lease_lost_discards_the_state() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})
			platform.add_character(2043, 8, &"player", VARDHEIM, {})):
		return
	var first: RawTicketClient = await _join(2042)
	var second: RawTicketClient = await _join(2043)
	if first == null or second == null:
		return
	var net_42: int = first.own_spawn.net_id
	var net_43: int = second.own_spawn.net_id
	_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 200, {"now_unix": _platform.now_unix(), "revoked": [
			{"character_id": "2042", "lease_id": _platform.claimed(2042).lease_id, "reason": "lease_lost",
			"text": "Tu personaje ha entrado en otro servidor"}], "mutes": [], "maintenance": null})
	_platform.send_heartbeat_now()
	await _run_until(func() -> bool: return not _has_body(net_42))
	assert_false(_progress().has_inventory(net_42), "el latido: sin progreso")
	_platform.script_next(PlatformEvent.KIND_SAVE, 409, FakeZonePlatform.error_body("lease_lost"))
	_gm_gold(net_43, 5)
	_server.get_saver().mark_critical(net_43, &"gm")
	await _run_until(func() -> bool: return not _has_body(net_43))
	assert_false(_progress().has_inventory(net_43), "el guardado: sin progreso")
	await _run_ms(200)
	assert_eq(_releases().size(), 0, "lease_lost no libera")


## Un 400 invalid_save expulsa y libera; después, ningún gancho de ProgressService falla con ese net_id.
func test_an_invalid_save_kicks_releases_and_leaves_harmless_hooks() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = await _join(2042)
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	var lease_id: String = _platform.claimed(2042).lease_id
	var saves_before: int = _saves().size()
	_platform.script_next(PlatformEvent.KIND_SAVE, 400, FakeZonePlatform.error_body("invalid_save", "",
			{"fields": {"check": "S5", "detail": "uid fuera de los bloques"}}))
	_gm_gold(net_id, 5)
	_server.get_saver().mark_critical(net_id, &"gm")
	var kicked: bool = await _run_until(func() -> bool: return client.kick_notice() != null)
	if not assert_true(kicked, "expulsión"):
		return
	assert_eq(client.kick_notice().text, ZoneServer.SAVE_REJECTED_TEXT, "«No se ha podido guardar tu personaje…»")
	await _run_until(func() -> bool: return not _has_body(net_id), 1000)
	await _run_ms(200)
	assert_eq(_saves().size(), saves_before + 1, "la «Salida» no manda nada")
	assert_eq(_releases().map(func(b: Dictionary) -> String: return String(b["lease_id"])), [lease_id],
			"se libera una vez")
	var progress: ProgressService = _progress()
	assert_false(progress.has_inventory(net_id), "sin progreso")
	progress.on_departure(net_id)
	progress._acknowledge(net_id, 2)
	assert_false(progress._is_dirty(net_id), "is_dirty sin progreso: false")
	assert_eq(progress.level_of(net_id), 0, "level_of: 0")
	assert_null(progress.get_player(net_id), "y nada que atar")


## is_dirty con solo moverse o perder vida (§9.2), y nada más entrar, limpio.
func test_is_dirty_with_only_moving_or_losing_health() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = await _join(2042)
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	var player: PlayerProgress = _progress().get_player(net_id)
	assert_false(player.is_dirty(), "tras el kit confirmado, limpio")
	await _run_ms(300)
	assert_false(player.is_dirty(), "quieto, sigue limpio")
	var here: Vector3 = _server.get_registry().get_entity(net_id).get_position()
	_server.teleport(net_id, here + Vector3(2.0, 0.0, 0.0))
	assert_true(player.is_dirty(), "moverse ensucia")
	_server.get_saver().mark_critical(net_id, &"gm")
	await _run_until(func() -> bool: return _saves().size() == 2 and _server.get_saver().pending_count() == 0)
	assert_false(player.is_dirty(), "guardado y confirmado, limpio")
	var moved: Dictionary = _saves()[1]["progress"]["location"]
	assert_near(float(moved["x"]), here.x + 2.0, 0.01, "con la posición nueva")
	_server.get_combat().get_combatant(net_id).health -= 100
	assert_true(player.is_dirty(), "perder vida ensucia")


## prepare con un registro que no se puede leer: REJECT UNAVAILABLE con su texto y liberación.
func test_a_broken_record_is_rejected_and_released() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {"progress_format": 1, "level": 3})):
		return
	var client: RawTicketClient = _connect(2042)
	var rejected: bool = await _run_until(func() -> bool: return client.reject != null)
	if not assert_true(rejected, "REJECT"):
		return
	assert_eq(client.reject.result, NetProtocol.Result.UNAVAILABLE, "UNAVAILABLE")
	assert_eq(client.reject.text, ProgressService.PREPARE_FAILED_TEXT, "«No se ha podido cargar el personaje»")
	var released: bool = await _run_until(func() -> bool: return not _releases().is_empty(), 2000)
	if assert_true(released, "se libera"):
		assert_eq(_releases()[0]["lease_id"], _platform.claimed(2042).lease_id, "con su lease_id")
	assert_eq(_progress().get_stats()["prepare_failed"], 1, "y se cuenta")
	assert_eq(_saves().size(), 0, "sin guardar")


## Irse en LOADING: cancel_prepared y liberación, sin guardar.
func test_leaving_while_loading_cancels_the_prepared_progress() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = _connect(2042, false)
	var peer_id: Array[int] = [-1]
	var loading: bool = await _run_until(func() -> bool:
		for id: int in _server.get_peer_ids():
			if _server.get_peer(id).state == ServerPeer.State.LOADING:
				peer_id[0] = id
				return client.connected
		return false)
	if not assert_true(loading, "WELCOME y LOADING"):
		return
	assert_not_null(_progress().get_prepared(peer_id[0]), "preparado antes del WELCOME")
	client.transport.close()
	var released: bool = await _run_until(func() -> bool: return not _releases().is_empty())
	assert_true(released, "se libera")
	assert_null(_progress().get_prepared(peer_id[0]), "y lo preparado se descarta")
	assert_eq(_progress().get_stats()["cancelled"], 1, "cancel_prepared")
	assert_eq(_saves().size(), 0, "sin guardar")


## La reclamación siguiente del falso trae lo último aplicado: el kit (mismos uids), la posición con saved_at_unix
## y el oro; la segunda entrada no vuelve a dar el kit.
func test_the_next_claim_brings_the_last_applied_progress() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = await _join(2042)
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	var uids: Array = _progress().get_player(net_id).record.inventory.all_items().map(
			func(i: ItemInstance) -> int: return i.uid)
	_gm_gold(net_id, 25)
	client.leave()
	await _run_until(func() -> bool: return _server.get_saver().entry_count() == 0)
	var finals: Array[Dictionary] = _saves().filter(func(b: Dictionary) -> bool: return bool(b["release_lease"]))
	assert_eq(finals.size(), 1, "el final al salir")
	assert_eq(_progress().get_stats()["players"], 0, "el estado se descarta al irse")
	var again: RawTicketClient = await _join(2042)
	if again == null:
		return
	var claimed: Dictionary = _platform.claimed(2042).progress
	assert_false(claimed.has("ops"), "la reclamación no lleva ops")
	assert_eq([claimed["race_id"], claimed["starter_template_id"]], ["race_vardheim", "marksman"],
			"con los campos de solo lectura de la anterior")
	assert_true((claimed["location"] as Dictionary).has("saved_at_unix"), "y location.saved_at_unix")
	var player: PlayerProgress = _progress().get_player(again.own_spawn.net_id)
	assert_eq(player.record.inventory.all_items().map(func(i: ItemInstance) -> int: return i.uid), uids,
			"los mismos objetos con los mismos uids")
	assert_eq(player.record.wallets[Currency.Code.GOLD], 25, "y el oro")
	assert_true(player.record.starter_granted, "con el kit ya dado")
	assert_eq(_saves().size(), 2, "la segunda entrada no da otro kit (ni guarda)")


## El final construido con un guardado en vuelo espera detrás de él y no repite sus operaciones: aplicados en
## orden, ningún op_id va dos veces (S2) y el final lleva la foto con todo.
func test_the_final_built_with_a_save_in_flight_applies_after_it() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = await _join(2042)
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	var first: EconomyOp = _gm_gold(net_id, 10)
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, FakeZonePlatform.DEFAULT, 0.6)
	_server.get_saver().mark_critical(net_id, &"gm")
	await _run_until(func() -> bool: return _saves().size() == 2)
	var second: EconomyOp = _gm_gold(net_id, 20)
	client.leave()
	await _run_until(func() -> bool: return not _has_body(net_id))
	assert_eq(_saves().size(), 2, "el final espera detrás del que vuela")
	var done: bool = await _run_until(func() -> bool: return _server.get_saver().entry_count() == 0, 3000)
	if not assert_true(done, "los dos tienen respuesta"):
		return
	var saves: Array[Dictionary] = _saves()
	if not assert_eq(saves.size(), 3, "el kit, el crítico y el final"):
		return
	assert_eq(_op_ids(saves[1]), [str(first.op_id)], "el crítico lleva la primera")
	assert_eq(_op_ids(saves[2]), [str(second.op_id)], "el final, solo la segunda")
	assert_true(bool(saves[2]["release_lease"]), "con release_lease")
	assert_eq(int(saves[2]["seq"]), int(saves[1]["seq"]) + 1, "con el seq siguiente")
	var seen: Dictionary = {}
	for body: Dictionary in saves:
		for op_id: String in _op_ids(body):
			assert_false(seen.has(op_id), "el op_id %s va una sola vez" % op_id)
			seen[op_id] = true
	var gold: int = -1
	for wallet: Dictionary in saves[2]["progress"]["wallets"]:
		if int(wallet["currency"]) == Currency.Code.GOLD:
			gold = int(wallet["balance"])
	assert_eq(gold, 30, "la foto final con los 30 de oro")
	assert_eq(_platform.applied(2042)["seq"], saves[2]["seq"], "lo último aplicado es el final")
