extends TestCase
## Pruebas de [PlatformClient] y [ZonePlatform] con [HTTPRequest] de verdad contra [FakeHttpServer] (un
## [TCPServer] en el mismo proceso, docs/plataforma.md §6 y §15 P4): plazo vencido y reintento con los mismos bytes,
## la reclamación que no se reintenta, el latido y la reclamación que no esperan detrás de cuatro guardados lentos,
## el orden por prioridad, cuerpos vacíos y rotos sin errores del motor, [code]zone_instance_id[/code] y la
## [code]key[/code] de los lotes, el conjunto del latido, un solo [code]instance_closed[/code], la liberación con
## 403 que no se repite y el servidor de zona de verdad ([code]--platform[/code]) en otro proceso.

const INSTANCE_ID: String = "0b9d6a2e-8f0c-4c5b-9d43-3d0f1e2a4b5c"

var _http: FakeHttpServer = null
var _platform: ZonePlatform = null
var _events: Array[PlatformEvent] = []
var _lease_counter: int = 0
var _register_env: String = "test"
var _register_heartbeat_s: float = 60.0


func after_each() -> void:
	for node: Node in [_platform, _http]:
		if is_instance_valid(node):
			node.get_parent().remove_child(node)
			node.free()
	_platform = null
	_http = null
	_events.clear()
	_lease_counter = 0
	_register_env = "test"
	_register_heartbeat_s = 60.0
	OS.unset_environment("ELDMARK_ZONE_TOKEN")
	OS.unset_environment("ELDMARK_TICKET_KEYS")
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _start_http() -> void:
	_http = FakeHttpServer.new()
	_http.name = "FakeHttpServer"
	tree.root.add_child(_http)
	assert_true(_http.listen() > 0, "el servidor HTTP falso escucha")
	_http.handler = _answer


## Lo que contesta la plataforma falsa a lo que no está guionizado.
func _answer(request: FakeHttpServer.Received) -> Array:
	var path: String = request.path
	var now: int = int(Time.get_unix_time_from_system())
	if request.method == "POST" and path == "/internal/v1/zone-instances":
		return [200, {"zone_instance_id": INSTANCE_ID, "env": _register_env, "heartbeat_s": _register_heartbeat_s,
				"lease_ttl_s": 30, "now_unix": now}, 0.0]
	if request.method == "GET" and path == "/internal/v1/fortresses":
		return [200, {"fortresses": []}, 0.0]
	if path == "/internal/v1/id-blocks":
		return [200, {"first": "1025", "count": 1024}, 0.0]
	if path.ends_with("/heartbeat"):
		return [200, {"now_unix": now, "revoked": [], "mutes": [], "maintenance": null}, 0.0]
	if path.ends_with("/live") or request.method == "DELETE" or path.ends_with("/release"):
		return [204, null, 0.0]
	if path == "/internal/v1/claims":
		var body: Variant = request.json()
		var character_id: String = String((body as Dictionary).get("character_id", "0")) if body is Dictionary else "0"
		_lease_counter += 1
		return [200, {"lease_id": "00000000-0000-4000-8000-%012d" % _lease_counter, "instance_status": "live",
				"account": {"account_id": "7", "role": "player", "muted_until_unix": 0, "ignored_account_ids": [],
						"warnings": []},
				"character": {"character_id": character_id, "world_id": 1, "realm": 1, "name": "Aneira"},
				"progress": {}, "pvp": {"kills": 0, "deaths": 0, "assists": 0, "captures": 0, "gate_damage": 0,
						"defend_s": 0}}, 0.0]
	if request.method == "PUT" and path.ends_with("/state"):
		return [200, {"applied": true, "duplicate": false, "save_version": 1, "instance_status": "live"}, 0.0]
	if request.method == "PUT" and path.begins_with("/internal/v1/fortresses/"):
		return [200, {"version": 1}, 0.0]
	if path == "/internal/v1/chat" or path == "/internal/v1/audit" or path == "/internal/v1/war-events":
		return [204, null, 0.0]
	return [404, {"error": {"code": "not_found", "message": "No existe"}}, 0.0]


## El servidor HTTP falso y una [ZonePlatform] arrancada contra él, con [param timeout_s] por intento.
func _start(timeout_s: float = 3.0) -> bool:
	_start_http()
	_platform = ZonePlatform.new()
	_platform.name = "ZonePlatform"
	_platform.timeout_s = timeout_s
	_platform.log_sink = func(_text: String) -> void: pass
	tree.root.add_child(_platform)
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	config.platform_url = _http.base_url()
	var finished: Array = []
	_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	var keys: Dictionary[int, PackedByteArray] = {}
	_platform.start(config, {"token": "token-de-prueba", "ticket_keys": keys})
	await _wait(func() -> bool: return not finished.is_empty(), 5000)
	if not assert_eq(finished, [[true, ""]], "la zona arranca contra la plataforma falsa"):
		return false
	_platform.get_client().retry_scale = 0.1
	_take()
	return true


## Avanza fotogramas recogiendo los eventos hasta que [param condition] sea verdadera o pasen [param max_ms] ms.
func _wait(condition: Callable, max_ms: int = 4000) -> bool:
	var started: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < max_ms:
		if condition.call():
			return true
		await wait_process_frames()
		if _platform != null:
			_events.append_array(_platform.take_events())
	return condition.call()


func _wait_ms(ms: int) -> void:
	await _wait(func() -> bool: return false, ms)


func _take() -> void:
	_events.append_array(_platform.take_events())


func _events_of(kind: StringName) -> Array[PlatformEvent]:
	var found: Array[PlatformEvent] = []
	for event: PlatformEvent in _events:
		if event.kind == kind:
			found.append(event)
	return found


func _ticket(character_id: int) -> HandoffTicket:
	var ticket := HandoffTicket.new()
	ticket.ticket_id = 9223372036854775807
	ticket.character_id = character_id
	return ticket


## Los personajes del último latido recibido.
func _last_heartbeat_characters() -> Array:
	var beats: Array[FakeHttpServer.Received] = _http.requests_to("POST", "/internal/v1/zone-instances/%s/heartbeat"
			% INSTANCE_ID)
	if beats.is_empty():
		return []
	return (beats.back().json() as Dictionary).get("characters", [])


## Manda un latido, espera a que su respuesta se haya atendido y devuelve los personajes que llevaba.
func _beat() -> Array:
	var path: String = "/internal/v1/zone-instances/%s/heartbeat" % INSTANCE_ID
	var before: int = _http.requests_to("POST", path).size()
	var answered: int = _events_of(PlatformEvent.KIND_HEARTBEAT).size()
	_platform.send_heartbeat_now()
	await _wait(func() -> bool:
		return _http.requests_to("POST", path).size() > before \
				and _events_of(PlatformEvent.KIND_HEARTBEAT).size() > answered)
	return _last_heartbeat_characters()


# --- Pruebas ----------------------------------------------------------------------------------

func test_startup_registers_reads_fortresses_and_asks_for_the_first_block() -> void:
	if not await _start():
		return
	var registers: Array[FakeHttpServer.Received] = _http.requests_to("POST", "/internal/v1/zone-instances")
	if assert_eq(registers.size(), 1, "un registro"):
		var body: Dictionary = registers[0].json()
		var keys: Array = body.keys()
		keys.sort()
		var expected: Array = ["world_id", "zone_id", "channel", "public_host", "public_port", "realms", "build_id",
				"protocol_version", "record_format", "max_players", "dtls_cert_pem", "dtls_name", "replace"]
		expected.sort()
		assert_eq(keys, expected, "exactamente los campos de §6 (la plataforma los lee estrictos)")
		assert_eq([body["zone_id"], body["protocol_version"], body["record_format"], body["public_host"]],
				["test_world", float(NetProtocol.PROTOCOL_VERSION), float(ZonePlatform.RECORD_FORMAT), "127.0.0.1"],
				"zona, protocolo, formato y host")
		assert_eq(registers[0].headers.get("authorization"), "Bearer token-de-prueba", "con el token de la zona")
	assert_eq(_http.requests_to("GET", "/internal/v1/fortresses")[0].query, "zone_instance_id=" + INSTANCE_ID,
			"las fortalezas de la instancia")
	assert_eq(_http.requests_to("POST", "/internal/v1/id-blocks")[0].json(), {"zone_instance_id": INSTANCE_ID},
			"y el primer bloque")
	var blocks: Array[PlatformEvent] = _events_of(PlatformEvent.KIND_ID_BLOCK)
	if assert_eq(blocks.size(), 1, "el primer bloque sale también como evento"):
		assert_eq(blocks[0].body_dict(), {"first": "1025", "count": 1024.0}, "con su cuerpo")
	assert_eq([_platform.instance_id(), _platform.env(), _platform.is_live(), _platform.is_fenced()],
			[INSTANCE_ID, &"test", false, false], "registrada, sin vivir aún y sin cercar")
	_platform.go_live()
	await _wait(func() -> bool: return _platform.is_live())
	assert_true(_platform.is_live(), "live")


func test_a_timed_out_save_is_retried_with_the_same_bytes() -> void:
	if not await _start(0.5):
		return
	_http.script("PUT", "/internal/v1/characters/5/state", 200, {"applied": true, "duplicate": false,
			"save_version": 9, "instance_status": "live"}, 1.5)
	var bytes: PackedByteArray = "{\"save_format\": 1, \"character_id\": \"5\", \"seq\": 1, \"x\": [1.0, \"ñ\"]}" \
			.to_utf8_buffer()
	_platform.save(5, "lease", bytes, false, {"seq": 1})
	var answered: bool = await _wait(func() -> bool: return not _events_of(PlatformEvent.KIND_SAVE).is_empty(), 5000)
	if not assert_true(answered, "el guardado acaba con una respuesta"):
		return
	var saves: Array[PlatformEvent] = _events_of(PlatformEvent.KIND_SAVE)
	assert_eq(saves.size(), 1, "un solo evento: el plazo vencido no es una respuesta")
	assert_eq([saves[0].status, saves[0].context], [200, {"seq": 1}], "el 200 del reintento, con su context")
	var received: Array[FakeHttpServer.Received] = _http.requests_to("PUT", "/internal/v1/characters/5/state")
	assert_eq(received.size(), 2, "dos intentos")
	for request: FakeHttpServer.Received in received:
		assert_eq(request.body, bytes, "los mismos bytes, sin tocar")


func test_the_claim_is_not_retried() -> void:
	if not await _start(0.5):
		return
	_http.script("POST", "/internal/v1/claims", 200, {}, 1.5)
	_platform.claim(3, _ticket(42))
	var answered: bool = await _wait(func() -> bool: return not _events_of(PlatformEvent.KIND_CLAIM).is_empty(), 3000)
	if assert_true(answered, "la reclamación acaba"):
		var claim: PlatformEvent = _events_of(PlatformEvent.KIND_CLAIM)[0]
		assert_false(claim.transport_ok, "sin respuesta (plazo vencido)")
		assert_eq(claim.context, {"peer_id": 3, "character_id": 42, "ticket_id": 9223372036854775807},
				"con su context")
	await _wait_ms(1500)
	var claims: Array[FakeHttpServer.Received] = _http.requests_to("POST", "/internal/v1/claims")
	assert_eq(claims.size(), 1, "un solo intento")
	assert_eq(claims[0].json(), {"zone_instance_id": INSTANCE_ID, "ticket_id": "9223372036854775807",
			"character_id": "42"}, "el ticket_id de 2^63 − 1 en cadena")


func test_a_heartbeat_does_not_wait_behind_four_slow_saves() -> void:
	if not await _start(5.0):
		return
	for character_id: int in range(1, 5):
		_http.script("PUT", "/internal/v1/characters/%d/state" % character_id, 200, {"applied": true,
				"duplicate": false, "save_version": 1, "instance_status": "live"}, 2.0)
		_platform.save(character_id, "lease", "{}".to_utf8_buffer(), false, character_id)
	await _wait(func() -> bool: return _http.requests_to("PUT", "/internal/v1/characters/").size() == 4)
	_platform.send_heartbeat_now()
	var beat: bool = await _wait(func() -> bool: return not _events_of(PlatformEvent.KIND_HEARTBEAT).is_empty(), 1500)
	assert_true(beat, "el latido vuelve enseguida")
	assert_eq(_events_of(PlatformEvent.KIND_SAVE).size(), 0, "con los cuatro guardados aún en vuelo")


func test_a_claim_goes_out_with_four_saves_in_flight() -> void:
	if not await _start(5.0):
		return
	for character_id: int in range(1, 5):
		_http.script("PUT", "/internal/v1/characters/%d/state" % character_id, 200, {"applied": true,
				"duplicate": false, "save_version": 1, "instance_status": "live"}, 2.0)
		_platform.save(character_id, "lease", "{}".to_utf8_buffer(), false, character_id)
	_platform.save(5, "lease", "{}".to_utf8_buffer(), false, 5)
	_platform.claim(9, _ticket(42))
	var claimed: bool = await _wait(func() -> bool: return not _events_of(PlatformEvent.KIND_CLAIM).is_empty(), 1500)
	assert_true(claimed, "la reclamación sale y vuelve")
	assert_eq(_platform.get_client().in_flight_count(), 4, "los cuatro guardados siguen en vuelo")
	assert_eq(_http.requests_to("PUT", "/internal/v1/characters/5/state").size(), 0,
			"el quinto guardado espera: las prioridades 2 a 4 ocupan cuatro plazas como mucho")


## Con cuatro guardados lentos que acaban escalonados, lo que espera sale por prioridad y no por llegada: el
## guardado (2) antes que la fortaleza (3) y que el lote (4), aunque llegaron después.
func test_waiting_requests_go_out_by_priority() -> void:
	if not await _start(5.0):
		return
	for i: int in 4:
		_http.script("PUT", "/internal/v1/characters/%d/state" % (i + 1), 200, {"applied": true,
				"duplicate": false, "save_version": 1, "instance_status": "live"}, 0.8 + 0.6 * i)
		_platform.save(i + 1, "lease", "{}".to_utf8_buffer(), false, i + 1)
	await _wait(func() -> bool: return _http.requests_to("PUT", "/internal/v1/characters/").size() == 4)
	_platform.enqueue_batch(&"audit", {"command": "item_give"})
	_platform.begin_flush()
	_platform.put_fortress(&"vado_gris_fort", {"schema": 1, "owner": 1})
	_platform.save(5, "lease", "{}".to_utf8_buffer(), false, 5)
	var done: bool = await _wait(func() -> bool: return _http.requests_to("POST", "/internal/v1/audit").size() == 1,
			6000)
	if not assert_true(done, "todo sale"):
		return
	var order: Array[String] = []
	for request: FakeHttpServer.Received in _http.received:
		if request.path in ["/internal/v1/characters/5/state", "/internal/v1/fortresses/vado_gris_fort",
				"/internal/v1/audit"]:
			order.append(request.path)
	assert_eq(order, ["/internal/v1/characters/5/state", "/internal/v1/fortresses/vado_gris_fort",
			"/internal/v1/audit"], "guardado, fortaleza y lote")


func test_empty_and_broken_bodies_are_null_without_engine_errors() -> void:
	if not await _start():
		return
	_http.script("GET", "/internal/v1/ops/5", 204, null)
	_http.script("GET", "/internal/v1/ops/6", 200, "")
	_http.script("GET", "/internal/v1/ops/7", 200, "{\"a\":")
	_http.script("GET", "/internal/v1/ops/8", 200, PackedByteArray([0xff, 0xfe, 0x7b]))
	for op_id: int in range(5, 10):
		_platform.request(PlatformEvent.KIND_PROGRESS_OP, HTTPClient.METHOD_GET, "/internal/v1/ops/%d" % op_id, {},
				PlatformClient.PRIORITY_PLAYER, op_id)
	await _wait(func() -> bool: return _events_of(PlatformEvent.KIND_PROGRESS_OP).size() == 5)
	var by_op: Dictionary = {}
	for event: PlatformEvent in _events_of(PlatformEvent.KIND_PROGRESS_OP):
		by_op[event.context] = event
	assert_eq([by_op[5].status, by_op[5].body, by_op[5].error_code], [204, null, ""], "204: null")
	assert_eq([by_op[6].status, by_op[6].body, by_op[6].error_code], [200, null, ""], "vacío: null")
	assert_eq([by_op[7].status, by_op[7].body, by_op[7].error_code], [200, null, "bad_json"], "roto: bad_json")
	assert_eq([by_op[8].body, by_op[8].error_code], [null, "bad_json"], "sin UTF-8: bad_json")
	assert_eq([by_op[9].status, by_op[9].error_code], [404, "not_found"], "un error lleva su código")


func test_requests_carry_the_instance_and_batches_their_keys() -> void:
	if not await _start():
		return
	_platform.request(PlatformEvent.KIND_PROGRESS_LEDGER, HTTPClient.METHOD_GET,
			"/internal/v1/characters/42/ledger?limit=5", {}, PlatformClient.PRIORITY_PLAYER, null)
	_platform.request(PlatformEvent.KIND_IGNORE, HTTPClient.METHOD_POST, "/internal/v1/ignores",
			{"character_id": "42", "target_name": "Bruna"}, PlatformClient.PRIORITY_PLAYER, null)
	_platform.enqueue_batch(&"audit", {"command": "item_give", "args": {"target_character_id": "42"}})
	_platform.enqueue_batch(&"audit", {"key": "op:5120", "command": "op_revert"})
	_platform.enqueue_batch(&"chat", {"channel": 1, "text": "hola"})
	_platform.begin_flush()
	await _wait(func() -> bool:
		return _http.requests_to("POST", "/internal/v1/audit").size() == 1 \
				and _http.requests_to("POST", "/internal/v1/chat").size() == 1 \
				and _events_of(PlatformEvent.KIND_IGNORE).size() == 1)
	assert_eq(_http.requests_to("GET", "/internal/v1/characters/42/ledger")[0].query,
			"limit=5&zone_instance_id=" + INSTANCE_ID, "un GET la lleva en la consulta")
	assert_eq(_http.requests_to("POST", "/internal/v1/ignores")[0].json(), {"character_id": "42",
			"target_name": "Bruna", "zone_instance_id": INSTANCE_ID}, "los demás, en el cuerpo")
	var audit: Dictionary = _http.requests_to("POST", "/internal/v1/audit")[0].json()
	assert_eq(audit, {"zone_instance_id": INSTANCE_ID, "entries": [
			{"command": "item_give", "args": {"target_character_id": "42"}, "key": INSTANCE_ID + ":1"},
			{"key": "op:5120", "command": "op_revert"}]}, "la key que falta, y op:<op_id> tal cual")
	var chat: Dictionary = _http.requests_to("POST", "/internal/v1/chat")[0].json()
	assert_eq(chat["messages"][0]["key"], INSTANCE_ID + ":2", "la secuencia es de la instancia")
	await _wait(func() -> bool: return _platform.is_flushed())
	assert_true(_platform.is_flushed(), "y no queda nada")


## El conjunto del latido: entra con la reclamación, cambia con otra del mismo personaje y sale con release() o
## con la respuesta definitiva de un guardado con release_lease; no con la de uno sin él.
func test_the_heartbeat_set() -> void:
	if not await _start():
		return
	assert_eq(await _beat(), [], "vacío al empezar")
	_platform.claim(1, _ticket(9))
	await _wait(func() -> bool: return _events_of(PlatformEvent.KIND_CLAIM).size() == 1)
	var first: String = _platform.claimed(9).lease_id
	assert_eq(await _beat(), [{"character_id": "9", "lease_id": first}], "entra con el 200 de la reclamación")
	_platform.claim(2, _ticket(9))
	await _wait(func() -> bool: return _events_of(PlatformEvent.KIND_CLAIM).size() == 2)
	var second: String = _platform.claimed(9).lease_id
	assert_true(second != first, "otro lease_id")
	assert_eq(await _beat(), [{"character_id": "9", "lease_id": second}], "cambia con otra reclamación")
	_platform.save(9, second, "{}".to_utf8_buffer(), false, 1)
	await _wait(func() -> bool: return _events_of(PlatformEvent.KIND_SAVE).size() == 1)
	assert_eq(await _beat(), [{"character_id": "9", "lease_id": second}], "un guardado sin release_lease no lo saca")
	_platform.save(9, first, "{}".to_utf8_buffer(), true, 2)
	await _wait(func() -> bool: return _events_of(PlatformEvent.KIND_SAVE).size() == 2)
	assert_eq(await _beat(), [{"character_id": "9", "lease_id": second}],
			"el final de un lease_id viejo no saca al de ahora")
	_http.script("PUT", "/internal/v1/characters/9/state", 409, {"error": {"code": "lease_lost", "message": "x"}})
	_platform.save(9, second, "{}".to_utf8_buffer(), true, 3)
	await _wait(func() -> bool: return _events_of(PlatformEvent.KIND_SAVE).size() == 3)
	assert_eq(await _beat(), [], "la respuesta definitiva del final (aunque sea un 409) lo saca")
	_platform.claim(3, _ticket(9))
	await _wait(func() -> bool: return _events_of(PlatformEvent.KIND_CLAIM).size() == 3)
	var third: String = _platform.claimed(9).lease_id
	assert_eq(await _beat(), [{"character_id": "9", "lease_id": third}], "vuelve a entrar")
	_platform.release(9, third)
	assert_eq(await _beat(), [], "y sale con release()")
	_platform.claim(4, _ticket(9))
	await _wait(func() -> bool: return _events_of(PlatformEvent.KIND_CLAIM).size() == 4)
	var fourth: String = _platform.claimed(9).lease_id
	_http.script("POST", "/internal/v1/zone-instances/%s/heartbeat" % INSTANCE_ID, 200, {"now_unix": 1800000000,
			"revoked": [{"character_id": "9", "lease_id": fourth, "reason": "lease_lost", "text": "x"}],
			"mutes": [], "maintenance": null})
	assert_eq(await _beat(), [{"character_id": "9", "lease_id": fourth}], "con lease_lost…")
	assert_eq(await _beat(), [], "…deja de latir por él")


func test_instance_lost_in_an_id_block_gives_a_single_instance_closed() -> void:
	if not await _start():
		return
	var lost: Dictionary = {"error": {"code": "instance_lost", "message": "La instancia se dio por perdida"}}
	_http.script("POST", "/internal/v1/id-blocks", 409, lost)
	_http.script("POST", "/internal/v1/zone-instances/%s/heartbeat" % INSTANCE_ID, 409, lost)
	_platform.request_id_block()
	await _wait(func() -> bool: return _events_of(PlatformEvent.KIND_ID_BLOCK).size() == 2)
	_platform.send_heartbeat_now()
	await _wait(func() -> bool: return _http.requests_to("POST", "/internal/v1/zone-instances/%s/heartbeat"
			% INSTANCE_ID).size() == 1)
	await _wait_ms(200)
	var closed: Array[PlatformEvent] = _events_of(PlatformEvent.KIND_INSTANCE_CLOSED)
	if assert_eq(closed.size(), 1, "un solo instance_closed"):
		assert_eq(closed[0].error_code, "instance_lost", "con el código")
	assert_eq(_events_of(PlatformEvent.KIND_ID_BLOCK).back().error_code, "instance_lost", "el bloque recibe su 409")
	assert_eq(_http.requests_to("POST", "/internal/v1/id-blocks").size(), 2,
			"un 409 no se reintenta (el otro es el del arranque)")


func test_a_release_with_403_is_not_repeated_but_one_with_503_is() -> void:
	if not await _start():
		return
	_http.script("POST", "/internal/v1/characters/5/release", 403, {"error": {"code": "forbidden", "message": "No"}})
	_platform.release(5, "lease-5")
	_http.script("POST", "/internal/v1/characters/6/release", 503, {"error": {"code": "db_unavailable",
			"message": "No"}})
	_platform.release(6, "lease-6")
	await _wait(func() -> bool: return _http.requests_to("POST", "/internal/v1/characters/6/release").size() == 2)
	await _wait(func() -> bool: return _platform.is_flushed())
	await _wait_ms(300)
	assert_eq(_http.requests_to("POST", "/internal/v1/characters/5/release").size(), 1, "un 403 es definitivo")
	assert_eq(_http.requests_to("POST", "/internal/v1/characters/6/release").size(), 2, "un 503 se repite")
	assert_eq(_http.requests_to("POST", "/internal/v1/characters/6/release")[1].json(),
			{"zone_instance_id": INSTANCE_ID, "lease_id": "lease-6"}, "con el mismo cuerpo")
	assert_true(_events.filter(func(e: PlatformEvent) -> bool: return e.kind == ZonePlatform.KIND_RELEASE).is_empty(),
			"la liberación no sale como evento")


func test_registration_retries_while_another_instance_is_alive() -> void:
	_start_http()
	_http.script("POST", "/internal/v1/zone-instances", 409, {"error": {"code": "instance_alive", "message": "x"}})
	_platform = ZonePlatform.new()
	_platform.log_sink = func(_text: String) -> void: pass
	tree.root.add_child(_platform)
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	config.platform_url = _http.base_url()
	var finished: Array = []
	_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	var keys: Dictionary[int, PackedByteArray] = {}
	_platform.start(config, {"token": "t", "ticket_keys": keys})
	await _wait(func() -> bool: return not finished.is_empty(), 5000)
	assert_eq(finished, [[true, ""]], "arranca al segundo intento")
	var registers: Array[FakeHttpServer.Received] = _http.requests_to("POST", "/internal/v1/zone-instances")
	if assert_eq(registers.size(), 2, "dos registros"):
		var gap: int = registers[1].at_msec - registers[0].at_msec
		assert_true(gap >= 1900 and gap < 3000, "a los 2 s (%d ms)" % gap)


## El servidor de zona de verdad en otro proceso, con --platform contra el servidor HTTP falso: registro,
## fortalezas, primer bloque, live y latidos; con --stop-file, cierre con la baja y código 0.
func test_the_zone_process_registers_goes_live_and_deregisters() -> void:
	_start_http()
	_register_heartbeat_s = 1.0
	var key: PackedByteArray = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858".hex_decode()
	OS.set_environment("ELDMARK_ZONE_TOKEN", "token-de-proceso")
	OS.set_environment("ELDMARK_TICKET_KEYS", "2:" + Marshalls.raw_to_base64(key))
	var stop_file: String = NetHarness.build_path("platform_zone.stop")
	DirAccess.remove_absolute(stop_file)
	var log_name: String = "platform_zone_%d" % Time.get_ticks_msec()
	var pid: int = NetHarness.launch_process(PackedStringArray(["--server", "--zone=test_world",
			"--port=%d" % NetHarness.free_udp_port(), "--platform=" + _http.base_url(), "--no-npcs", "--no-dummies",
			"--stop-file=" + stop_file]), log_name)
	OS.unset_environment("ELDMARK_ZONE_TOKEN")
	OS.unset_environment("ELDMARK_TICKET_KEYS")
	if not assert_true(pid > 0, "el proceso arranca"):
		return
	var live: bool = await _wait(func() -> bool:
		return _http.requests_to("POST", "/internal/v1/zone-instances/%s/live" % INSTANCE_ID).size() == 1 \
				and _http.requests_to("POST", "/internal/v1/zone-instances/%s/heartbeat" % INSTANCE_ID).size() >= 1,
			20000)
	if not assert_true(live, "la zona se registra, abre el puerto, se da por viva y late"):
		OS.kill(pid)
		return
	assert_eq(_http.requests_to("POST", "/internal/v1/zone-instances")[0].headers.get("authorization"),
			"Bearer token-de-proceso", "con el token del entorno")
	assert_eq(_http.requests_to("GET", "/internal/v1/fortresses").size(), 1, "lee las fortalezas")
	assert_eq(_http.requests_to("POST", "/internal/v1/id-blocks").size(), 1, "pide el primer bloque")
	FileAccess.open(stop_file, FileAccess.WRITE).store_string("stop")
	var exited: bool = await _wait(func() -> bool: return not OS.is_process_running(pid), 15000)
	if not assert_true(exited, "el proceso termina"):
		OS.kill(pid)
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "con código 0")
	assert_eq(_http.requests_to("DELETE", "/internal/v1/zone-instances/%s" % INSTANCE_ID).size(), 1,
			"tras darse de baja")
	assert_eq(NetHarness.error_lines(NetHarness.build_path("%s.log" % log_name)), PackedStringArray(),
			"sin errores en su registro")


## Con un env de production y --debug-commands, el servidor de zona de verdad sale con código 1 tras darse de baja
## (docs/plataforma.md §5.5).
func test_the_zone_process_exits_with_dev_options_in_production() -> void:
	_start_http()
	_register_env = "production"
	OS.set_environment("ELDMARK_ZONE_TOKEN", "token-de-proceso")
	OS.set_environment("ELDMARK_TICKET_KEYS", "2:" + Marshalls.raw_to_base64(
			"02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858".hex_decode()))
	var log_name: String = "platform_guard_%d" % Time.get_ticks_msec()
	var pid: int = NetHarness.launch_process(PackedStringArray(["--server", "--zone=test_world",
			"--port=%d" % NetHarness.free_udp_port(), "--platform=" + _http.base_url(), "--debug-commands",
			"--no-npcs", "--no-dummies"]), log_name)
	OS.unset_environment("ELDMARK_ZONE_TOKEN")
	OS.unset_environment("ELDMARK_TICKET_KEYS")
	if not assert_true(pid > 0, "el proceso arranca"):
		return
	var exited: bool = await _wait(func() -> bool: return not OS.is_process_running(pid), 20000)
	if not assert_true(exited, "el proceso termina"):
		OS.kill(pid)
		return
	assert_eq(OS.get_process_exit_code(pid), 1, "con código 1")
	assert_eq(_http.requests_to("DELETE", "/internal/v1/zone-instances/%s" % INSTANCE_ID).size(), 1,
			"tras darse de baja")
	assert_eq(_http.requests_to("GET", "/internal/v1/fortresses").size(), 0, "sin seguir con el arranque")
	assert_true(FileAccess.get_file_as_string(NetHarness.build_path("%s.log" % log_name)).contains(
			"Esa opción no se admite con la plataforma en staging/production: --debug-commands"),
			"con el motivo en el registro")
