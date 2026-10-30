extends TestCase
## El cierre ordenado del servidor de zona de verdad (otro proceso, [code]--platform[/code] contra [FakeHttpServer],
## que contesta las liberaciones a los 2 s) con cada uno de los cinco disparadores de docs/plataforma.md §7.2:
## [code]--stop-file[/code], [code]--quit-after-ticks[/code], [code]--idle-quit[/code], el [code]shutdown[/code] de
## la consola (con [code]--run-at[/code]) y el [code]maintenance[/code] del latido. Con un jugador en el mundo, uno en
## LOADING y uno en VERIFYING, el proceso no se da de baja (DELETE) hasta que la plataforma ha contestado lo que
## le queda de cada uno, y sale con código 0 sin errores. Hasta progresion.md P5a la zona no tiene secciones que
## guardar: el final de quien está en el mundo es su liberación (CharacterSaver sin secciones); los guardados de
## verdad con la espera se prueban en [code]test_zone_server_saves.gd[/code].

const INSTANCE_ID: String = "1f6a1c1e-5b9e-4c1a-9a51-6d2f0e3b7c44"
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const ZONE_ID: String = "test_world"
const NAMES: Dictionary[int, String] = {1: "Aneira", 2: "Brais", 3: "Carmela"}
## Lo que tarda la plataforma falsa en contestar una liberación (menos que el plazo de 3 s del cliente).
const RELEASE_DELAY_S: float = 2.0
## Lo que tarda en contestar la reclamación del tercero, que espera en VERIFYING (también menos de 3 s).
const VERIFYING_CLAIM_DELAY_S: float = 2.5

var _http: FakeHttpServer = null
var _viewport: SubViewport = null
var _world: Node3D = null
var _clients: Array[RawTicketClient] = []
var _pid: int = -1
var _port: int = 0
var _log_name: String = ""
var _lease_counter: int = 0
## character_id -> lease_id que dio la reclamación.
var _leases: Dictionary[int, String] = {}
var _release_delay_s: float = RELEASE_DELAY_S
## El maintenance de los latidos (null o {at_unix, message}).
var _maintenance: Variant = null
var _client_tick: int = 0
var _sim_hash: int = -1
var _next_ticket_id: int = 4000


func after_each() -> void:
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	for client: RawTicketClient in _clients:
		if is_instance_valid(client.transport):
			client.transport.free()
	_clients.clear()
	for node: Node in [_viewport, _http]:
		if is_instance_valid(node):
			node.get_parent().remove_child(node)
			node.free()
	_viewport = null
	_world = null
	_http = null
	_leases.clear()
	_lease_counter = 0
	_release_delay_s = RELEASE_DELAY_S
	_maintenance = null
	_client_tick = 0
	_sim_hash = -1
	OS.unset_environment("ELDMARK_ZONE_TOKEN")
	OS.unset_environment("ELDMARK_TICKET_KEYS")
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

## Lo que contesta la plataforma falsa.
func _answer(request: FakeHttpServer.Received) -> Array:
	var path: String = request.path
	var now: int = int(Time.get_unix_time_from_system())
	if request.method == "POST" and path == "/internal/v1/zone-instances":
		return [200, {"zone_instance_id": INSTANCE_ID, "env": "test", "heartbeat_s": 1.0, "lease_ttl_s": 30,
				"now_unix": now}, 0.0]
	if request.method == "GET" and path == "/internal/v1/fortresses":
		return [200, {"fortresses": []}, 0.0]
	if path == "/internal/v1/id-blocks":
		return [200, {"first": "1025", "count": 1024}, 0.0]
	if path.ends_with("/heartbeat"):
		return [200, {"now_unix": now, "revoked": [], "mutes": [], "maintenance": _maintenance}, 0.0]
	if path.ends_with("/release"):
		return [204, null, _release_delay_s]
	if path.ends_with("/live") or request.method == "DELETE":
		return [204, null, 0.0]
	if path == "/internal/v1/claims":
		var body: Dictionary = request.json() if request.json() is Dictionary else {}
		var character_id: int = String(body.get("character_id", "0")).to_int()
		if not NAMES.has(character_id):
			return [409, {"error": {"code": "ticket_invalid", "message": "Billete no válido"}}, 0.0]
		_lease_counter += 1
		_leases[character_id] = "00000000-0000-4000-8000-%012d" % _lease_counter
		return [200, {"lease_id": _leases[character_id], "instance_status": "live",
				"account": {"account_id": str(100 + character_id), "role": "player", "muted_until_unix": 0,
						"ignored_account_ids": [], "warnings": []},
				"character": {"character_id": str(character_id), "world_id": 1, "realm": 1,
						"name": NAMES[character_id]},
				"progress": {}, "pvp": {"kills": 0, "deaths": 0, "assists": 0, "captures": 0, "gate_damage": 0,
						"defend_s": 0}}, VERIFYING_CLAIM_DELAY_S if character_id == 3 else 0.0]
	if request.method == "PUT" and path.ends_with("/state"):
		return [200, {"applied": true, "duplicate": false, "save_version": 1, "instance_status": "live"}, 2.0]
	return [404, {"error": {"code": "not_found", "message": "No existe"}}, 0.0]


## Arranca la plataforma falsa y el proceso de zona con [param extra_args], y espera a que esté viva.
func _launch(extra_args: PackedStringArray, log_name: String) -> bool:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = Node3D.new()
	_viewport.add_child(_world)
	_http = FakeHttpServer.new()
	_http.name = "FakeHttpServer"
	tree.root.add_child(_http)
	if not assert_true(_http.listen() > 0, "el servidor HTTP falso escucha"):
		return false
	_http.handler = _answer
	OS.set_environment("ELDMARK_ZONE_TOKEN", "token-de-proceso")
	OS.set_environment("ELDMARK_TICKET_KEYS", "2:" + Marshalls.raw_to_base64(KEY_HEX.hex_decode()))
	_port = NetHarness.free_udp_port()
	_log_name = "%s_%d" % [log_name, Time.get_ticks_msec()]
	var args := PackedStringArray(["--server", "--zone=" + ZONE_ID, "--port=%d" % _port,
			"--platform=" + _http.base_url(), "--no-npcs", "--no-dummies"])
	args.append_array(extra_args)
	_pid = NetHarness.launch_process(args, _log_name)
	OS.unset_environment("ELDMARK_ZONE_TOKEN")
	OS.unset_environment("ELDMARK_TICKET_KEYS")
	if not assert_true(_pid > 0, "el proceso arranca"):
		return false
	var live: bool = await _run_until(func() -> bool:
		return _http.requests_to("POST", "/internal/v1/zone-instances/%s/live" % INSTANCE_ID).size() == 1, 20000)
	return assert_true(live, "la zona se registra y se da por viva")


func _ticket(character_id: int) -> PackedByteArray:
	var ticket := HandoffTicket.new()
	ticket.key_id = 2
	ticket.world_id = 1
	ticket.ticket_id = _next_ticket_id
	_next_ticket_id += 1
	ticket.character_id = character_id
	ticket.zone_key = HandoffTicket.zone_key_of(ZONE_ID)
	ticket.realm = NetProtocol.Realm.VARDHEIM
	ticket.flags = HandoffTicket.FLAG_FROM_MENU
	ticket.issued_at = int(Time.get_unix_time_from_system())
	ticket.expires_at = ticket.issued_at + 10
	return ticket.sign(KEY_HEX.hex_decode())


func _connect(character_id: int, auto_ready: bool = true) -> RawTicketClient:
	if _sim_hash < 0:
		var character: PlayerCharacter = PLAYER_SCENE.instantiate() as PlayerCharacter
		_world.add_child(character)
		_sim_hash = NetProtocol.compute_sim_hash(character)
		_world.remove_child(character)
		character.free()
	var hello := NetMessages.Hello.new()
	hello.sim_hash = _sim_hash
	hello.realm = NetProtocol.Realm.VARDHEIM
	hello.display_name = NAMES[character_id]
	hello.character_id = character_id
	hello.ticket = _ticket(character_id)
	var transport := NetTransport.new()
	transport.name = "Client%d" % character_id
	_viewport.add_child(transport)
	var client := RawTicketClient.new(transport, hello.encode())
	client.auto_ready = auto_ready
	_clients.append(client)
	assert_eq(transport.connect_to("127.0.0.1", _port, 4000), OK, "el cliente %d conecta" % character_id)
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


## Uno en el mundo (1), uno en LOADING (2) y uno en VERIFYING (3, con su reclamación a 2,5 s).
func _put_players_in_every_state() -> Array[RawTicketClient]:
	var in_world: RawTicketClient = _connect(1)
	var loading: RawTicketClient = _connect(2, false)
	var ready: bool = await _run_until(func() -> bool: return in_world.own_spawn != null and loading.connected, 8000)
	if not assert_true(ready, "uno entra en el mundo y otro carga la zona"):
		return []
	var verifying: RawTicketClient = _connect(3)
	var claimed: bool = await _run_until(func() -> bool: return _claims_of(3) == 1, 4000)
	if not assert_true(claimed, "el tercero espera su reclamación en VERIFYING"):
		return []
	return [in_world, loading, verifying]


func _claims_of(character_id: int) -> int:
	var count: int = 0
	for request: FakeHttpServer.Received in _http.requests_to("POST", "/internal/v1/claims"):
		var body: Variant = request.json()
		if body is Dictionary and String((body as Dictionary).get("character_id", "")) == str(character_id):
			count += 1
	return count


func _releases() -> Array[FakeHttpServer.Received]:
	var found: Array[FakeHttpServer.Received] = []
	for request: FakeHttpServer.Received in _http.received:
		if request.method == "POST" and request.path.ends_with("/release"):
			found.append(request)
	return found


## Espera la salida del proceso y comprueba el cierre ordenado: código 0, cada arrendamiento de [param characters]
## liberado una vez, la baja (DELETE) después de que la plataforma contestara cada liberación y sin errores.
func _expect_orderly_exit(characters: Array[int]) -> void:
	var exited: bool = await _run_until(func() -> bool: return not OS.is_process_running(_pid), 25000)
	if not assert_true(exited, "el proceso termina"):
		OS.kill(_pid)
		return
	assert_eq(OS.get_process_exit_code(_pid), 0, "con código 0")
	var deletes: Array[FakeHttpServer.Received] = _http.requests_to("DELETE",
			"/internal/v1/zone-instances/%s" % INSTANCE_ID)
	if not assert_eq(deletes.size(), 1, "se da de baja"):
		return
	var released: Dictionary[String, int] = {}
	var last_answer_msec: int = 0
	for request: FakeHttpServer.Received in _releases():
		var lease_id: String = String((request.json() as Dictionary).get("lease_id", ""))
		released[lease_id] = released.get(lease_id, 0) + 1
		last_answer_msec = maxi(last_answer_msec, request.at_msec + int(_release_delay_s * 1000.0))
	for character_id: int in characters:
		assert_eq(released.get(_leases.get(character_id, "?"), 0), 1,
				"el arrendamiento del personaje %d se libera una vez" % character_id)
	assert_true(deletes[0].at_msec >= last_answer_msec - 50,
			"la baja espera a la última respuesta (%d ms después)" % (deletes[0].at_msec - last_answer_msec))
	assert_eq(NetHarness.error_lines(NetHarness.build_path("%s.log" % _log_name)), PackedStringArray(),
			"sin errores en su registro")


# --- Pruebas ----------------------------------------------------------------------------------

func test_stop_file_waits_for_the_platform() -> void:
	var stop_file: String = NetHarness.build_path("shutdown_saves.stop")
	DirAccess.remove_absolute(stop_file)
	if not await _launch(PackedStringArray(["--stop-file=" + stop_file]), "shutdown_stop_file"):
		return
	var players: Array[RawTicketClient] = await _put_players_in_every_state()
	if players.is_empty():
		return
	FileAccess.open(stop_file, FileAccess.WRITE).store_string("parar")
	await _expect_orderly_exit([1, 2, 3])
	assert_true(players[0].notice_time(NetProtocol.NoticeCode.SHUTDOWN) >= 0, "NOTICE de cierre al del mundo")


func test_quit_after_ticks_waits_for_the_platform() -> void:
	if not await _launch(PackedStringArray(["--quit-after-ticks=240"]), "shutdown_quit_after"):
		return
	var players: Array[RawTicketClient] = await _put_players_in_every_state()
	if players.is_empty():
		return
	await _expect_orderly_exit([1, 2, 3])
	assert_true(players[0].notice_time(NetProtocol.NoticeCode.SHUTDOWN) >= 0, "NOTICE de cierre al del mundo")


func test_console_shutdown_waits_for_the_platform() -> void:
	if not await _launch(PackedStringArray(["--run-at=240:shutdown 0"]), "shutdown_console"):
		return
	var players: Array[RawTicketClient] = await _put_players_in_every_state()
	if players.is_empty():
		return
	await _expect_orderly_exit([1, 2, 3])
	assert_true(players[0].notice_time(NetProtocol.NoticeCode.SHUTDOWN) >= 0, "NOTICE de cierre al del mundo")


func test_maintenance_waits_for_the_platform() -> void:
	if not await _launch(PackedStringArray(), "shutdown_maintenance"):
		return
	var players: Array[RawTicketClient] = await _put_players_in_every_state()
	if players.is_empty():
		return
	_maintenance = {"at_unix": int(Time.get_unix_time_from_system()) + 2, "message": "versión nueva"}
	await _expect_orderly_exit([1, 2, 3])
	var texts: PackedStringArray = players[0].notice_texts(NetProtocol.NoticeCode.INFO)
	assert_true(texts.size() == 1 and texts[0].begins_with("El servidor se cerrará por mantenimiento en ")
			and texts[0].ends_with(": versión nueva"), "un aviso del mantenimiento (%s)" % ", ".join(texts))
	assert_true(players[0].notice_time(NetProtocol.NoticeCode.SHUTDOWN) >= 0, "y el NOTICE de cierre")


## --idle-quit solo cuenta sin nadie dentro: el jugador sale y su liberación sigue pendiente al cerrar.
func test_idle_quit_waits_for_the_platform() -> void:
	_release_delay_s = 2.8
	if not await _launch(PackedStringArray(["--idle-quit=1"]), "shutdown_idle"):
		return
	var client: RawTicketClient = _connect(1)
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null, 8000)
	if not assert_true(joined, "entra en el mundo"):
		return
	client.leave()
	await _expect_orderly_exit([1])
