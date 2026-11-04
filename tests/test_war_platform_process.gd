extends TestCase
## Persistent war with the real zone server (docs/plataforma.md §8 and §15 P6, GUE-19): the Vado Gris
## in another process with [code]--platform[/code] against [FakeHttpServer], which stores the fortress
## records like the platform does (with [code]expected_version[/code]). A first process changes the
## owner and kills the captain with [code]--run-at[/code]; a second one starts with the platform not
## answering the fortress requests: it does not open the port until it has them, loads the owner and
## the deadline of the captain that was running, and overwrites nothing.

const INSTANCE_ID: String = "0b9d6a2e-8f0c-4c5b-9d43-3d0f1e2a4b5d"
const FORTRESS: String = "vado_gris_fort"
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"

var _http: FakeHttpServer = null
## fortress_id -> {record, version}: what the fake platform has stored.
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


# --- Helpers ----------------------------------------------------------------------------------

func _start_http() -> void:
	_http = FakeHttpServer.new()
	_http.name = "FakeHttpServer"
	tree.root.add_child(_http)
	assert_true(_http.listen() > 0, "the fake HTTP server listens")
	_http.handler = _answer


## The fake platform: just enough for startup, heartbeats and deregistration, and the fortresses with their version.
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


## The Vado Gris (the default zone) with the fake platform, with no NPCs or dummies, on [param port].
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


## true if the UDP port [param port] is free (nobody has it open: PacketPeerUDP does not share it).
static func _port_free(port: int) -> bool:
	var probe := PacketPeerUDP.new()
	var error: Error = probe.bind(port)
	probe.close()
	return error == OK


static func _fortress_in(report: Dictionary) -> Dictionary:
	var list: Array = (report.get("war", {}) as Dictionary).get("fortresses", [])
	return list[0] if not list.is_empty() and list[0] is Dictionary else {}


# --- Test -------------------------------------------------------------------------------------

func test_a_restart_keeps_the_owner_and_the_captain_timer_and_an_outage_never_overwrites_them() -> void:
	_start_http()
	# First process: Solmarch takes the fort (tick 30) and its captain falls (tick 60); the war is written on change.
	var report_a: String = NetHarness.build_path("war_restart_a.json")
	DirAccess.remove_absolute(report_a)
	var pid_a: int = _launch(NetHarness.free_udp_port(), PackedStringArray(["--run-at=30:fort_owner solmarch",
			"--run-at=60:fort_kill_captain", "--quit-after-ticks=150", "--report=" + report_a]), "war_restart_a")
	if not assert_true(pid_a > 0, "the first process starts"):
		return
	var exited: bool = await _wait(func() -> bool: return not OS.is_process_running(pid_a), 25000)
	if not assert_true(exited, "the first process ends"):
		return
	assert_eq(OS.get_process_exit_code(pid_a), 0, "with code 0")
	assert_eq(NetHarness.error_lines(NetHarness.build_path("war_restart_a.log")), PackedStringArray(),
			"no errors in its log")
	if not assert_true(_stored.has(FORTRESS), "the fortress is saved"):
		return
	var saved: Dictionary = _stored[FORTRESS]["record"]
	var killed_at: int = int(Time.get_unix_time_from_system())
	assert_eq([int(saved["owner"]), saved["phase"], saved["captain_alive"]], [NetProtocol.Realm.SOLMARCH,
			"vulnerable", false], "Solmarch's, with the captain fallen")
	var back_at: int = int(saved["captain_respawn_at_unix"])
	assert_true(back_at > killed_at + 280 and back_at <= killed_at + 300,
			"the captain returns 300 s after falling (%d s from now)" % (back_at - killed_at))
	var version: int = int(_stored[FORTRESS]["version"])
	var puts_before: int = _http.requests_to("PUT", "/internal/v1/fortresses/").size()
	assert_eq(version, puts_before, "the initial state, the owner and the phase: each with its own version")

	# Second process: the platform does not answer the fortress requests twice (1 and 2 s retry).
	_http.script("GET", "/internal/v1/fortresses", 503, {"error": {"code": "db_unavailable",
			"message": "La base no responde"}}, 0.0, 2)
	var port_b: int = NetHarness.free_udp_port()
	var report_b: String = NetHarness.build_path("war_restart_b.json")
	DirAccess.remove_absolute(report_b)
	var gets_before: int = _http.requests_to("GET", "/internal/v1/fortresses").size()
	var pid_b: int = _launch(port_b, PackedStringArray(["--quit-after-ticks=120", "--report=" + report_b]),
			"war_restart_b")
	if not assert_true(pid_b > 0, "the second process starts"):
		return
	var refused: bool = await _wait(func() -> bool:
		return _http.requests_to("GET", "/internal/v1/fortresses").size() >= gets_before + 2, 20000)
	if not assert_true(refused, "it asks for the fortresses and does not have them"):
		return
	assert_true(_port_free(port_b), "with the platform silent, the port stays closed")
	var live_path: String = "/internal/v1/zone-instances/%s/live" % INSTANCE_ID
	var lives_before: int = _http.requests_to("POST", live_path).size()
	var live: bool = await _wait(func() -> bool: return _http.requests_to("POST", live_path).size() > lives_before,
			15000)
	if not assert_true(live, "once it has them, it opens the port and considers itself alive"):
		return
	assert_false(_port_free(port_b), "it now listens on its port")
	var gets: Array[FakeHttpServer.Received] = _http.requests_to("GET", "/internal/v1/fortresses")
	assert_eq(gets.size(), gets_before + 3, "two with no answer and the good one")
	assert_true(_http.requests_to("POST", live_path).back().at_msec > gets.back().at_msec,
			"the port opens after reading them")
	exited = await _wait(func() -> bool: return not OS.is_process_running(pid_b), 20000)
	if not assert_true(exited, "the second process ends"):
		return
	assert_eq(OS.get_process_exit_code(pid_b), 0, "with code 0")
	assert_eq(_http.requests_to("PUT", "/internal/v1/fortresses/").size(), puts_before,
			"with no changes it does not write: the saved owner is not overwritten")
	assert_eq(int(_stored[FORTRESS]["version"]), version)
	var fortress: Dictionary = _fortress_in(NetHarness.read_report(report_b))
	assert_eq([int(fortress.get("owner", -1)), int(fortress.get("phase", -1)), fortress.get("captain_alive")],
			[NetProtocol.Realm.SOLMARCH, FortressState.Phase.VULNERABLE, false],
			"the second process continues with the saved owner and phase")
	var log_b: String = FileAccess.get_file_as_string(NetHarness.build_path("war_restart_b.log"))
	var regex := RegEx.create_from_string(
			"Fortaleza vado_gris_fort cargada de la plataforma \\(versión (\\d+)\\): dueño Solmarch, fase vulnerable; " +
			"el capitán reaparece en (\\d+) s")
	var found: RegExMatch = regex.search(log_b)
	if assert_not_null(found, "its record says so"):
		assert_eq(int(found.get_string(1)), version)
		var remaining: int = int(found.get_string(2))
		assert_true(remaining >= 240 and remaining < 300,
				"with the captain's deadline half elapsed: %d s of 300" % remaining)
	assert_eq(NetHarness.error_lines(NetHarness.build_path("war_restart_b.log")), PackedStringArray(),
			"no errors in its log")
