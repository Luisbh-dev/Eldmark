extends TestCase
## La guerra persistente con el servidor de zona de verdad (docs/plataforma.md §8 y §15 P6, GUE-19): el Vado Gris
## en otro proceso con [code]--platform[/code] contra [FakeHttpServer], que guarda los registros de las fortalezas
## como la plataforma (con [code]expected_version[/code]). Un primer proceso cambia el dueño y mata al capitán con
## [code]--run-at[/code]; un segundo arranca con la plataforma sin responder a las fortalezas: no abre el puerto
## hasta tenerlas, carga el dueño y el plazo del capitán que corría y no pisa nada.

const INSTANCE_ID: String = "0b9d6a2e-8f0c-4c5b-9d43-3d0f1e2a4b5d"
const FORTRESS: String = "vado_gris_fort"
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"

var _http: FakeHttpServer = null
## fortress_id -> {record, version}: lo que la plataforma falsa tiene guardado.
var _stored: Dictionary = {}
var _pids: Array[int] = []


func after_each() -> void:
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()
	if is_instance_valid(_http):
		_http.get_parent().remove_child(_http)
		_http.free()
	_http = null
	_stored.clear()
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


## La plataforma falsa: lo justo para el arranque, los latidos y la baja, y las fortalezas con su versión.
func _answer(request: FakeHttpServer.Received) -> Array:
	var path: String = request.path
	var now: int = int(Time.get_unix_time_from_system())
	if request.method == "POST" and path == "/internal/v1/zone-instances":
		return [200, {"zone_instance_id": INSTANCE_ID, "env": "test", "heartbeat_s": 1.0, "lease_ttl_s": 30,
				"now_unix": now}, 0.0]
	if request.method == "GET" and path == "/internal/v1/fortresses":
		var list: Array = []
		for fortress_id: String in _stored:
			list.append({"fortress_id": fortress_id, "record": _stored[fortress_id]["record"],
					"version": _stored[fortress_id]["version"]})
		return [200, {"fortresses": list}, 0.0]
	if request.method == "PUT" and path.begins_with("/internal/v1/fortresses/"):
		var body: Dictionary = request.json() if request.json() is Dictionary else {}
		var fortress_id: String = path.get_file()
		var current: int = int((_stored.get(fortress_id, {}) as Dictionary).get("version", 0))
		if int(body.get("expected_version", -1)) != current:
			return [409, {"error": {"code": "version_conflict", "message": "Ha cambiado", "version": current}}, 0.0]
		_stored[fortress_id] = {"record": body.get("record"), "version": current + 1}
		return [200, {"version": current + 1}, 0.0]
	if path == "/internal/v1/id-blocks":
		return [200, {"first": "1025", "count": 1024}, 0.0]
	if path.ends_with("/heartbeat"):
		return [200, {"now_unix": now, "revoked": [], "mutes": [], "maintenance": null}, 0.0]
	if path.ends_with("/live") or request.method == "DELETE" or path.ends_with("/release"):
		return [204, null, 0.0]
	if path == "/internal/v1/war-events" or path == "/internal/v1/chat" or path == "/internal/v1/audit":
		return [204, null, 0.0]
	return [404, {"error": {"code": "not_found", "message": "No existe"}}, 0.0]


## El Vado Gris (la zona por defecto) con la plataforma falsa, sin PNJ ni maniquíes, en [param port].
func _launch(port: int, extra: PackedStringArray, log_name: String) -> int:
	OS.set_environment("ELDMARK_ZONE_TOKEN", "token-de-proceso")
	OS.set_environment("ELDMARK_TICKET_KEYS", "2:" + Marshalls.raw_to_base64(KEY_HEX.hex_decode()))
	var args := PackedStringArray(["--server", "--port=%d" % port, "--platform=" + _http.base_url(), "--no-npcs",
			"--no-dummies"])
	args.append_array(extra)
	var pid: int = NetHarness.launch_process(args, log_name)
	OS.unset_environment("ELDMARK_ZONE_TOKEN")
	OS.unset_environment("ELDMARK_TICKET_KEYS")
	if pid > 0:
		_pids.append(pid)
	return pid


func _wait(condition: Callable, max_ms: int) -> bool:
	var started: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < max_ms:
		if condition.call():
			return true
		await wait_process_frames()
	return condition.call()


## true si el puerto UDP [param port] está libre (nadie lo tiene abierto: PacketPeerUDP no lo comparte).
static func _port_free(port: int) -> bool:
	var probe := PacketPeerUDP.new()
	var error: Error = probe.bind(port)
	probe.close()
	return error == OK


static func _fortress_in(report: Dictionary) -> Dictionary:
	var list: Array = (report.get("war", {}) as Dictionary).get("fortresses", [])
	return list[0] if not list.is_empty() and list[0] is Dictionary else {}


# --- Prueba -----------------------------------------------------------------------------------

func test_a_restart_keeps_the_owner_and_the_captain_timer_and_an_outage_never_overwrites_them() -> void:
	_start_http()
	# Primer proceso: Solmarch toma el fuerte (tick 30) y su capitán cae (tick 60); la guerra se escribe al cambiar.
	var report_a: String = NetHarness.build_path("war_restart_a.json")
	DirAccess.remove_absolute(report_a)
	var pid_a: int = _launch(NetHarness.free_udp_port(), PackedStringArray(["--run-at=30:fort_owner solmarch",
			"--run-at=60:fort_kill_captain", "--quit-after-ticks=150", "--report=" + report_a]), "war_restart_a")
	if not assert_true(pid_a > 0, "el primer proceso arranca"):
		return
	var exited: bool = await _wait(func() -> bool: return not OS.is_process_running(pid_a), 25000)
	if not assert_true(exited, "el primer proceso termina"):
		return
	assert_eq(OS.get_process_exit_code(pid_a), 0, "con código 0")
	assert_eq(NetHarness.error_lines(NetHarness.build_path("war_restart_a.log")), PackedStringArray(),
			"sin errores en su registro")
	if not assert_true(_stored.has(FORTRESS), "la fortaleza está guardada"):
		return
	var saved: Dictionary = _stored[FORTRESS]["record"]
	var killed_at: int = int(Time.get_unix_time_from_system())
	assert_eq([int(saved["owner"]), saved["phase"], saved["captain_alive"]], [NetProtocol.Realm.SOLMARCH,
			"vulnerable", false], "de Solmarch y con el capitán caído")
	var back_at: int = int(saved["captain_respawn_at_unix"])
	assert_true(back_at > killed_at + 280 and back_at <= killed_at + 300,
			"el capitán vuelve a los 300 s de caer (%d s desde ahora)" % (back_at - killed_at))
	var version: int = int(_stored[FORTRESS]["version"])
	var puts_before: int = _http.requests_to("PUT", "/internal/v1/fortresses/").size()
	assert_eq(version, puts_before, "el estado inicial, el dueño y la fase: cada uno con su versión")

	# Segundo proceso: la plataforma no contesta a las fortalezas dos veces (1 y 2 s de reintento).
	_http.script("GET", "/internal/v1/fortresses", 503, {"error": {"code": "db_unavailable",
			"message": "La base no responde"}}, 0.0, 2)
	var port_b: int = NetHarness.free_udp_port()
	var report_b: String = NetHarness.build_path("war_restart_b.json")
	DirAccess.remove_absolute(report_b)
	var gets_before: int = _http.requests_to("GET", "/internal/v1/fortresses").size()
	var pid_b: int = _launch(port_b, PackedStringArray(["--quit-after-ticks=120", "--report=" + report_b]),
			"war_restart_b")
	if not assert_true(pid_b > 0, "el segundo proceso arranca"):
		return
	var refused: bool = await _wait(func() -> bool:
		return _http.requests_to("GET", "/internal/v1/fortresses").size() >= gets_before + 2, 20000)
	if not assert_true(refused, "pide las fortalezas y no las tiene"):
		return
	assert_true(_port_free(port_b), "con la plataforma muda, el puerto sigue cerrado")
	var live_path: String = "/internal/v1/zone-instances/%s/live" % INSTANCE_ID
	var lives_before: int = _http.requests_to("POST", live_path).size()
	var live: bool = await _wait(func() -> bool: return _http.requests_to("POST", live_path).size() > lives_before,
			15000)
	if not assert_true(live, "cuando las tiene, abre el puerto y se da por viva"):
		return
	assert_false(_port_free(port_b), "ya escucha en su puerto")
	var gets: Array[FakeHttpServer.Received] = _http.requests_to("GET", "/internal/v1/fortresses")
	assert_eq(gets.size(), gets_before + 3, "dos sin respuesta y la buena")
	assert_true(_http.requests_to("POST", live_path).back().at_msec > gets.back().at_msec,
			"el puerto se abre después de leerlas")
	exited = await _wait(func() -> bool: return not OS.is_process_running(pid_b), 20000)
	if not assert_true(exited, "el segundo proceso termina"):
		return
	assert_eq(OS.get_process_exit_code(pid_b), 0, "con código 0")
	assert_eq(_http.requests_to("PUT", "/internal/v1/fortresses/").size(), puts_before,
			"sin cambios no escribe: el dueño guardado no se pisa")
	assert_eq(int(_stored[FORTRESS]["version"]), version)
	var fortress: Dictionary = _fortress_in(NetHarness.read_report(report_b))
	assert_eq([int(fortress.get("owner", -1)), int(fortress.get("phase", -1)), fortress.get("captain_alive")],
			[NetProtocol.Realm.SOLMARCH, FortressState.Phase.VULNERABLE, false],
			"el segundo proceso sigue con el dueño y la fase guardados")
	var log_b: String = FileAccess.get_file_as_string(NetHarness.build_path("war_restart_b.log"))
	var regex := RegEx.create_from_string(
			"Fortaleza vado_gris_fort cargada de la plataforma \\(versión (\\d+)\\): dueño Solmarch, fase vulnerable; " +
			"el capitán reaparece en (\\d+) s")
	var found: RegExMatch = regex.search(log_b)
	if assert_not_null(found, "lo dice su registro"):
		assert_eq(int(found.get_string(1)), version)
		var remaining: int = int(found.get_string(2))
		assert_true(remaining >= 240 and remaining < 300,
				"con el plazo del capitán a medias: %d s de los 300" % remaining)
	assert_eq(NetHarness.error_lines(NetHarness.build_path("war_restart_b.log")), PackedStringArray(),
			"sin errores en su registro")
