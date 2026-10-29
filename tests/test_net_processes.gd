extends TestCase
## Varios procesos de verdad (docs/red.md, sección 16, «Varios procesos»; TEC-10 y TEC-46): un servidor
## headless y dos bots, cada uno su proceso de Godot, con ENet real sobre 127.0.0.1, lanzados con
## [method NetHarness.launch_process] y esperados como mucho 25 s.
## [br][br]
## [b]Determinismo entre procesos[/b] (en el Vado Gris, la zona real, con su Terrain3D): cada bot compara
## su estado predicho con el del servidor en cada snapshot. Sin simulador de red no puede haber ninguna
## diferencia sin explicar (la que no coincide con una entrada sustituida), y la comparación de los
## registros de estado ([StateLogComparer], la lógica de [code]tools/compare_state_logs.gd[/code]) lo
## confirma. El servidor lleva además jugadores falsos: sus cuerpos existen en el espacio de física del
## servidor y no en el de los bots, así que también se comprueba que no alteran las consultas de Jolt.
## [br]Segunda pasada con [code]--net-sim[/code] en los bots: convergencia final exacta y ninguna
## resincronización dura.
## [br][br]
## [b]Bot tramposo[/b] ([code]--bot-cheat[/code], un método por modo, en [code]test_world[/code] para que
## sea rápido): rechazado o expulsado, sin que el bot honrado tenga diferencias sin explicar ni el
## servidor registre errores en su registro.
## [br][br]
## [b]Enjambre[/b] ([code]--bots=N[/code], [BotSwarm]): un proceso con seis clientes ligeros contra el servidor.
## [br][br]
## Los registros y los informes quedan en [code]build/<pid>/np_*[/code] ([method NetHarness.build_path]:
## una carpeta por proceso de pruebas, para que dos suites a la vez no se pisen; los de estado con
## extensión [code].txt[/code]: el importador convierte los [code].csv[/code] del proyecto en
## traducciones).

## Tiempo máximo de espera a todos los procesos (cada prueba dura menos de 30 s).
const MAX_WAIT_SECONDS: float = 25.0
## Zona de las pruebas de tramposos: el circuito plano, que carga en un instante.
const LIGHT_ZONE: String = "test_world"

var _pids: Array[int] = []


func after_each() -> void:
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _build_path(file_name: String) -> String:
	return NetHarness.build_path(file_name)


## Un bot del escenario: [param extra_args] son los argumentos de usuario de más ([code]--net-sim[/code],
## [code]--bot-cheat[/code]...).
func _bot(seed_value: int, realm_name: String,
		extra_args: PackedStringArray = PackedStringArray()) -> Dictionary:
	return {"seed": seed_value, "realm": realm_name, "extra": extra_args}


## Un proceso [code]--bots=N[/code] (enjambre de clientes ligeros) en lugar de un [code]--bot[/code].
func _swarm(count: int, seed_value: int, realm_name: String = "vardheim") -> Dictionary:
	return {"seed": seed_value, "realm": realm_name, "extra": PackedStringArray(), "swarm": count}


## Lanza un servidor (con [param server_extra] de más) y los bots, espera a que terminen y recoge sus
## informes. [param zone] vacío = la zona por defecto (el Vado Gris). Devuelve:
## [code]{ok, elapsed, server: {...}, bots: [{...}]}[/code], con, por proceso, [code]exit[/code],
## [code]report[/code], [code]log[/code] y [code]states[/code] (rutas).
func _run_scenario(tag: String, zone: String, server_ticks: int, bot_ticks: int,
		bots: Array[Dictionary], server_extra: PackedStringArray = PackedStringArray()) -> Dictionary:
	var port: int = NetHarness.free_udp_port()
	var server: Dictionary = {
		"report": _build_path("np_%s_server.json" % tag),
		"states": _build_path("np_%s_server.txt" % tag),
		"log": _build_path("np_%s_server.log" % tag),
	}
	for key: String in ["report", "states", "log"]:
		DirAccess.remove_absolute(server[key])
	var server_args := PackedStringArray([
		"--server", "--port=%d" % port, "--quit-after-ticks=%d" % server_ticks,
		"--report=%s" % server["report"], "--state-log=%s" % server["states"],
	])
	if not zone.is_empty():
		server_args.append("--zone=%s" % zone)
	server_args.append_array(server_extra)
	var started_msec: int = Time.get_ticks_msec()
	var server_pid: int = NetHarness.launch_process(server_args, "np_%s_server" % tag)
	if server_pid > 0:
		_pids.append(server_pid)
	server["pid"] = server_pid
	var result: Dictionary = {"ok": false, "server": server, "bots": [], "elapsed": 0.0}
	if not assert_true(server_pid > 0, "el servidor se lanza"):
		return result

	# El registro de estados existe en cuanto el servidor escucha.
	var listening: bool = await _wait_for(func() -> bool: return FileAccess.file_exists(server["states"]),
			started_msec)
	if not assert_true(listening, "el servidor empieza a escuchar"):
		return result
	var bot_infos: Array[Dictionary] = []
	for i: int in bots.size():
		var spec: Dictionary = bots[i]
		var info: Dictionary = {
			"report": _build_path("np_%s_bot%d.json" % [tag, i]),
			"states": _build_path("np_%s_bot%d.txt" % [tag, i]),
			"log": _build_path("np_%s_bot%d.log" % [tag, i]),
		}
		for key: String in ["report", "states", "log"]:
			DirAccess.remove_absolute(info[key])
		var args := PackedStringArray([
			"--connect=127.0.0.1:%d" % port, "--realm=%s" % spec["realm"],
			"--bot-seed=%d" % spec["seed"], "--quit-after-ticks=%d" % bot_ticks,
			"--report=%s" % info["report"],
		])
		if spec.has("swarm"):
			args.append("--bots=%d" % spec["swarm"])
		else:
			args.append_array(PackedStringArray(["--bot", "--state-log=%s" % info["states"]]))
		args.append_array(spec["extra"])
		info["pid"] = NetHarness.launch_process(args, "np_%s_bot%d" % [tag, i])
		if info["pid"] > 0:
			_pids.append(info["pid"])
		assert_true(info["pid"] > 0, "el bot %d se lanza" % i)
		bot_infos.append(info)
	result["bots"] = bot_infos

	var all_pids: Array[int] = [server_pid]
	for info: Dictionary in bot_infos:
		all_pids.append(info["pid"])
	var finished: bool = await _wait_for(func() -> bool:
		for pid: int in all_pids:
			if OS.is_process_running(pid):
				return false
		return true, started_msec)
	result["elapsed"] = float(Time.get_ticks_msec() - started_msec) / 1000.0
	if not assert_true(finished, "los procesos terminan solos en menos de %d s" % int(MAX_WAIT_SECONDS)):
		return result
	server["exit"] = OS.get_process_exit_code(server_pid)
	server["data"] = NetHarness.read_report(server["report"])
	for info: Dictionary in bot_infos:
		info["exit"] = OS.get_process_exit_code(info["pid"])
		info["data"] = NetHarness.read_report(info["report"])
	result["ok"] = true
	return result


## Espera a que se cumpla [param condition] hasta [constant MAX_WAIT_SECONDS] después de
## [param started_msec].
func _wait_for(condition: Callable, started_msec: int) -> bool:
	var deadline: int = started_msec + int(MAX_WAIT_SECONDS * 1000.0)
	while not condition.call():
		if Time.get_ticks_msec() > deadline:
			return false
		await tree.create_timer(0.1).timeout
	return true


## Líneas del registro del proceso que contienen errores del motor o de scripts.
func _error_lines(log_path: String) -> PackedStringArray:
	var found := PackedStringArray()
	for line: String in FileAccess.get_file_as_string(log_path).split("\n"):
		if line.contains("ERROR") or line.contains("SCRIPT ERROR"):
			found.append(line)
	return found


## Ficha del servidor del jugador con ese net_id (vacía si no existe).
func _server_player(scenario: Dictionary, net_id: int) -> Dictionary:
	var data: Dictionary = (scenario["server"] as Dictionary).get("data", {})
	for entry: Dictionary in data.get("player_list", []):
		if int(entry.get("net_id", 0)) == net_id:
			return entry
	return {}


## Comparación del registro de estados de un bot con el del servidor.
func _compare(scenario: Dictionary, bot: Dictionary) -> StateLogComparer.Result:
	var net_id: int = int((bot["data"] as Dictionary).get("net_id", 0))
	return StateLogComparer.compare_files(scenario["server"]["states"], bot["states"], net_id)


## Lo que debe cumplir un bot honrado que ha jugado entero: salió bien, no se equivocó nunca sin
## que el servidor sustituyera una entrada y su registro de estados lo confirma.
func _assert_honest_bot(scenario: Dictionary, bot: Dictionary, label: String) -> void:
	var report: Dictionary = bot["data"]
	assert_eq(bot["exit"], 0, "%s: código de salida 0" % label)
	assert_eq(report.get("state"), "IN_WORLD", "%s: estaba jugando al terminar" % label)
	assert_eq(int(report.get("unexplained_diffs", -1)), 0, "%s: sin diferencias sin explicar" % label)
	assert_eq(int(report.get("malformed_packets", -1)), 0, "%s: sin paquetes mal formados" % label)
	assert_eq(int(report.get("late_snapshots", -1)), 0, "%s: sin snapshots desordenados" % label)
	assert_true(int(report.get("snapshots_with_state", 0)) > 100,
			"%s: recibe snapshots con su estado (%s)" % [label, report.get("snapshots_with_state")])
	var comparison: StateLogComparer.Result = _compare(scenario, bot)
	assert_eq(comparison.error, "", "%s: se pueden comparar los registros" % label)
	assert_true(comparison.is_ok(), "%s: %s" % [label, comparison.summary()])
	assert_true(comparison.matches > 100, "%s: muchas coincidencias bit a bit (%d)" % [label, comparison.matches])


# --- Determinismo entre procesos (Vado Gris, la zona real) ------------------------------------

func test_two_bots_predict_exactly_across_processes_on_the_real_zone() -> void:
	var bots: Array[Dictionary] = [_bot(1, "vardheim"), _bot(2, "solmarch")]
	var scenario: Dictionary = await _run_scenario("exact", "", 900, 700, bots,
			PackedStringArray(["--fake-players=6"]))
	if not assert_true(scenario["ok"], "el escenario termina"):
		return
	var server: Dictionary = scenario["server"]
	assert_eq(server["exit"], 0, "el servidor sale con 0")
	var data: Dictionary = server["data"]
	assert_eq(data.get("zone"), String(Zones.DEFAULT_ZONE), "sirve el Vado Gris")
	assert_eq(int(data.get("ticks", 0)), 900, "900 ticks")
	assert_eq(int((data.get("players", {}) as Dictionary).get("joined_total", 0)), 8,
			"dos bots y seis jugadores falsos")
	assert_eq(int(data.get("physics_errors", -1)), 0, "sin errores de física en el servidor")
	assert_eq(int(data.get("respawns", -1)), 0, "nadie cae fuera del mundo")
	assert_eq(int((data.get("strikes", {}) as Dictionary).get("total", -1)), 0, "sin avisos")
	assert_true((data.get("kicks", []) as Array).is_empty(), "sin expulsiones")
	assert_eq((data.get("rejects", {}) as Dictionary).size(), 0, "ni rechazos")
	assert_eq(_error_lines(server["log"]), PackedStringArray(), "sin errores en el registro del servidor")
	for i: int in 2:
		var bot: Dictionary = scenario["bots"][i]
		_assert_honest_bot(scenario, bot, "bot %d" % (i + 1))
		var report: Dictionary = bot["data"]
		assert_eq(int(report.get("hard_resets", -1)), 0, "bot %d: ningún reinicio duro" % (i + 1))
		assert_eq(int(report.get("resyncs", -1)), 0, "bot %d: ni resincronización" % (i + 1))
		assert_eq(int(report.get("corrections", -1)), 0, "bot %d: ni una corrección" % (i + 1))
		assert_true(bool((report.get("final", {}) as Dictionary).get("exact", false)),
				"bot %d: su estado final es el del servidor" % (i + 1))
		assert_eq(_error_lines(bot["log"]), PackedStringArray(), "bot %d: sin errores en su registro" % (i + 1))


func test_bots_with_a_network_simulator_converge_exactly_without_hard_resyncs() -> void:
	var sim: PackedStringArray = PackedStringArray(["--net-sim=rtt=120,jitter=20,loss=5"])
	var bots: Array[Dictionary] = [_bot(1, "vardheim", sim), _bot(2, "solmarch", sim)]
	var scenario: Dictionary = await _run_scenario("netsim", "", 900, 700, bots)
	if not assert_true(scenario["ok"], "el escenario termina"):
		return
	assert_eq(scenario["server"]["exit"], 0, "el servidor sale con 0")
	assert_eq(_error_lines(scenario["server"]["log"]), PackedStringArray(),
			"sin errores en el registro del servidor")
	for i: int in 2:
		var bot: Dictionary = scenario["bots"][i]
		var report: Dictionary = bot["data"]
		var label: String = "bot %d" % (i + 1)
		assert_eq(bot["exit"], 0, "%s: código de salida 0" % label)
		assert_eq(report.get("net_sim"), "rtt=120,jitter=20,loss=5", "%s: lleva el simulador" % label)
		assert_true(bool((report.get("final", {}) as Dictionary).get("exact", false)),
				"%s: convergencia final exacta (quieto los últimos ticks)" % label)
		assert_eq(int(report.get("hard_resets", -1)), 0, "%s: ningún reinicio duro" % label)
		assert_eq(int(report.get("resyncs", -1)), 0, "%s: ninguna resincronización dura" % label)
		assert_eq(int(report.get("unexplained_diffs", -1)), 0,
				"%s: todo error de predicción lo explica una entrada sustituida" % label)
		assert_true(int(report.get("snapshots_with_state", 0)) > 100, "%s: recibe snapshots" % label)
		var comparison: StateLogComparer.Result = _compare(scenario, bot)
		assert_eq(comparison.error, "", "%s: se pueden comparar los registros" % label)
		assert_eq(comparison.unexplained, 0, "%s: %s" % [label, comparison.summary()])
		assert_eq(comparison.server_mismatches, 0, "%s: su estado propio es el del servidor" % label)


# --- Bot tramposo (un método por modo, en el circuito plano) ----------------------------------

## Servidor de test_world con un bot honrado y un tramposo del modo [param cheat]; los tiempos son
## cortos porque la zona carga al instante.
func _run_cheat_scenario(cheat: String) -> Dictionary:
	var bots: Array[Dictionary] = [
		_bot(1, "vardheim"),
		_bot(2, "solmarch", PackedStringArray(["--bot-cheat=%s" % cheat])),
	]
	return await _run_scenario("cheat_%s" % cheat, LIGHT_ZONE, 560, 400, bots)


## Lo común a todos los modos: el servidor no se entera de nada raro en su registro, el honrado no
## sufre y el servidor sale bien.
func _assert_honest_side_untouched(scenario: Dictionary) -> void:
	var server: Dictionary = scenario["server"]
	assert_eq(server["exit"], 0, "el servidor sale con 0")
	assert_eq(_error_lines(server["log"]), PackedStringArray(), "sin errores en el registro del servidor")
	assert_eq(int((server["data"] as Dictionary).get("physics_errors", -1)), 0, "ni errores de física")
	_assert_honest_bot(scenario, scenario["bots"][0], "bot honrado")
	var honest_id: int = int((scenario["bots"][0]["data"] as Dictionary).get("net_id", 0))
	var record: Dictionary = _server_player(scenario, honest_id)
	assert_eq(int(record.get("strikes", -1)), 0, "el honrado no suma avisos")
	assert_false(bool(record.get("kicked", true)), "ni lo expulsan")


func test_cheater_with_another_protocol_version_is_rejected() -> void:
	var scenario: Dictionary = await _run_cheat_scenario("version")
	if not assert_true(scenario["ok"], "el escenario termina"):
		return
	_assert_honest_side_untouched(scenario)
	var cheater: Dictionary = scenario["bots"][1]
	var report: Dictionary = cheater["data"]
	assert_eq(cheater["exit"], 1, "el tramposo sale con 1")
	assert_true(bool(report.get("rejected", false)), "porque lo rechazan")
	assert_eq(int(report.get("reject_result", 0)), NetProtocol.Result.VERSION, "por la versión")
	assert_eq(report.get("reject_text"), NetProtocol.result_text(NetProtocol.Result.VERSION))
	assert_eq(report.get("cheat"), "version")
	var data: Dictionary = scenario["server"]["data"]
	assert_eq(int((data.get("players", {}) as Dictionary).get("joined_total", 0)), 1, "solo entra el honrado")
	assert_eq((data.get("rejects", {}) as Dictionary).size(), 1, "y el servidor cuenta un rechazo")


func test_cheater_with_inputs_from_the_future_gains_nothing() -> void:
	var scenario: Dictionary = await _run_cheat_scenario("future")
	if not assert_true(scenario["ok"], "el escenario termina"):
		return
	_assert_honest_side_untouched(scenario)
	var cheater: Dictionary = scenario["bots"][1]
	var report: Dictionary = cheater["data"]
	assert_eq(cheater["exit"], 0, "el tramposo sigue jugando y sale con 0")
	assert_true(int(report.get("cheat_packets", 0)) > 100, "de verdad enviaba entradas de futuro")
	var record: Dictionary = _server_player(scenario, int(report.get("net_id", 0)))
	assert_true(int(record.get("too_early_inputs", 0)) > 100, "el servidor las descarta y las cuenta")
	assert_eq(int(record.get("strikes", -1)), 0, "sin avisos")
	# Sin ventaja: el servidor solo aplica las honradas, así que el estado del tramposo es el que predice.
	assert_eq(int(report.get("unexplained_diffs", -1)), 0, "su predicción nunca falla")
	var comparison: StateLogComparer.Result = _compare(scenario, cheater)
	assert_true(comparison.is_ok(), comparison.summary())


func test_cheater_with_conflicting_duplicates_gets_the_first_copy() -> void:
	var scenario: Dictionary = await _run_cheat_scenario("dupes")
	if not assert_true(scenario["ok"], "el escenario termina"):
		return
	_assert_honest_side_untouched(scenario)
	var cheater: Dictionary = scenario["bots"][1]
	var report: Dictionary = cheater["data"]
	assert_eq(cheater["exit"], 0, "el tramposo sigue jugando y sale con 0")
	assert_true(int(report.get("cheat_packets", 0)) > 100, "de verdad enviaba copias distintas")
	var record: Dictionary = _server_player(scenario, int(report.get("net_id", 0)))
	assert_eq(int(record.get("strikes", -1)), 0, "sin avisos")
	assert_eq(int(report.get("unexplained_diffs", -1)), 0,
			"gana la primera copia, la honrada: su predicción nunca falla")
	var comparison: StateLogComparer.Result = _compare(scenario, cheater)
	assert_true(comparison.is_ok(), comparison.summary())


func test_cheater_sending_garbage_is_kicked() -> void:
	await _assert_kicked("garbage")


func test_cheater_flooding_the_limiters_is_kicked() -> void:
	await _assert_kicked("flood")


func _assert_kicked(cheat: String) -> void:
	var scenario: Dictionary = await _run_cheat_scenario(cheat)
	if not assert_true(scenario["ok"], "el escenario termina"):
		return
	_assert_honest_side_untouched(scenario)
	var cheater: Dictionary = scenario["bots"][1]
	var report: Dictionary = cheater["data"]
	assert_eq(cheater["exit"], 1, "el tramposo sale con 1")
	assert_eq(report.get("cheat"), cheat)
	assert_eq(report.get("state"), "CLOSED", "su sesión está cerrada")
	assert_true(String(report.get("disconnect_text", "")).contains("Expulsado"),
			"por una expulsión: «%s»" % report.get("disconnect_text"))
	var data: Dictionary = scenario["server"]["data"]
	var kicks: Array = data.get("kicks", [])
	if assert_eq(kicks.size(), 1, "el servidor expulsa a uno"):
		assert_eq(int((kicks[0] as Dictionary).get("net_id", 0)), int(report.get("net_id", -1)),
				"al tramposo")
	assert_true(int((data.get("strikes", {}) as Dictionary).get("total", 0)) >= 50,
			"tras al menos 50 avisos")
	var record: Dictionary = _server_player(scenario, int(report.get("net_id", 0)))
	assert_true(bool(record.get("kicked", false)), "y su ficha lo marca como expulsado")
	var players: Dictionary = data.get("players", {})
	assert_eq(int(players.get("joined_total", 0)), 2, "entraron los dos")
	assert_eq(int(players.get("left_total", 0)), 2, "y se fueron los dos: uno expulsado y otro por su pie")


# --- Enjambre de bots (--bots=N) --------------------------------------------------------------

func test_a_swarm_process_fills_the_server_with_light_clients() -> void:
	var scenario: Dictionary = await _run_scenario("swarm", LIGHT_ZONE, 560, 360, [_swarm(6, 100)])
	if not assert_true(scenario["ok"], "el escenario termina"):
		return
	var server: Dictionary = scenario["server"]
	assert_eq(server["exit"], 0, "el servidor sale con 0")
	assert_eq(_error_lines(server["log"]), PackedStringArray(), "sin errores en el registro del servidor")
	var data: Dictionary = server["data"]
	assert_eq(int((data.get("players", {}) as Dictionary).get("joined_total", 0)), 6, "entran los 6 bots")
	assert_eq(int((data.get("strikes", {}) as Dictionary).get("total", -1)), 0, "sin avisos")
	assert_true((data.get("kicks", []) as Array).is_empty(), "ni expulsiones")
	assert_true(float((data.get("inputs", {}) as Dictionary).get("substituted_percent", 100.0)) < 5.0,
			"con casi todas las entradas a tiempo")
	var swarm: Dictionary = scenario["bots"][0]
	assert_eq(swarm["exit"], 0, "el enjambre sale con 0: todos jugaban")
	assert_eq(_error_lines(swarm["log"]), PackedStringArray(), "sin errores en el registro del enjambre")
	var report: Dictionary = swarm["data"]
	assert_eq(report.get("mode"), "SWARM")
	assert_eq(int((report.get("bots", {}) as Dictionary).get("played", 0)), 6)
	var clients: Array = report.get("clients", [])
	assert_eq(clients.size(), 6, "una ficha por bot")
	for entry: Dictionary in clients:
		assert_true(int(entry.get("snapshots", 0)) > 40, "%s recibe snapshots" % entry.get("name"))
		assert_true(int(entry.get("bytes_down", 0)) > 1000 and int(entry.get("bytes_up", 0)) > 1000,
				"%s: bytes de subida y de bajada" % entry.get("name"))
		assert_true(float(entry.get("avg_snapshot_bytes", 0.0)) > 49.0, "y tamaño medio de snapshot")
