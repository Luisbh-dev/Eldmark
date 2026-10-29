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
## [b]Bot tramposo de combate[/b] ([code]rewind[/code], [code]reach[/code] y [code]rate[/code], los tres a la
## vez contra el maniquí de [code]test_world[/code]): ninguno hace daño de más.
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
## El servidor lo cierra el archivo de parada en cuanto se han ido todos los bots; sus
## [code]--quit-after-ticks[/code] (los pedidos por este factor) solo son el tope por si eso no llega.
## Antes los ticks pedidos lo cerraban, y un bot que tardaba en arrancar o en cargar la zona (sus ticks
## se cuentan desde que arranca su proceso y se retrasan con la máquina cargada) se encontraba el
## servidor cerrado: salía con 1 y «CLOSED».
const SERVER_TICKS_CAP_FACTOR: int = 3

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
## [param extra_args] son los argumentos de más ([code]--bot-brain=combat[/code]...).
func _swarm(count: int, seed_value: int, realm_name: String = "vardheim",
		extra_args: PackedStringArray = PackedStringArray()) -> Dictionary:
	return {"seed": seed_value, "realm": realm_name, "extra": extra_args, "swarm": count}


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
		"stop": _build_path("np_%s_server.stop" % tag),
	}
	for key: String in ["report", "states", "log", "stop"]:
		DirAccess.remove_absolute(server[key])
	var server_args := PackedStringArray([
		"--server", "--port=%d" % port,
		"--quit-after-ticks=%d" % (server_ticks * SERVER_TICKS_CAP_FACTOR),
		"--stop-file=%s" % server["stop"],
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

	# Primero se van los bots (por sus ticks, expulsados o rechazados); después se cierra el servidor con
	# el archivo de parada, que mira cada segundo.
	var bots_done: bool = await _wait_for(func() -> bool:
		for info: Dictionary in bot_infos:
			if OS.is_process_running(info["pid"]):
				return false
		return true, started_msec)
	if bots_done:
		var stop := FileAccess.open(server["stop"], FileAccess.WRITE)
		if stop != null:
			stop.store_string("fin de la prueba\n")
			stop.close()
	var finished: bool = bots_done and await _wait_for(func() -> bool:
		return not OS.is_process_running(server_pid), started_msec)
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
	return NetHarness.error_lines(log_path)


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
	assert_eq(_error_lines(bot["log"]), PackedStringArray(), "%s: sin errores en su registro" % label)
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
	assert_true(int(data.get("ticks", 0)) >= 700 and int(data.get("ticks", 0)) < 900 * SERVER_TICKS_CAP_FACTOR,
			"vive lo que los bots y lo cierra el archivo de parada (%s ticks)" % data.get("ticks"))
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
		assert_eq(_error_lines(bot["log"]), PackedStringArray(), "%s: sin errores en su registro" % label)
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
	assert_eq(_error_lines(scenario["bots"][1]["log"]), PackedStringArray(),
			"el tramposo tampoco registra errores (el rechazo y la expulsión no son errores del motor)")
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


## Los tres modos de combate del bot tramposo (TEC-14) a la vez, cada uno un proceso de verdad con
## [code]--bot --bot-cheat=<modo>[/code], contra el maniquí de test_world. Ninguno hace daño de más: el
## de [code]rewind[/code] (40 ticks de vista) ni acierta y suma sospecha con cada golpe; el de
## [code]reach[/code] ataca desde 5 m y no conecta; el de [code]rate[/code] machaca el botón y pega solo al
## ritmo del combo de los datos.
func test_combat_cheaters_in_real_processes_deal_no_damage_beyond_the_rules() -> void:
	var bots: Array[Dictionary] = [
		_bot(1, "solmarch", PackedStringArray(["--bot-cheat=rewind"])),
		_bot(2, "solmarch", PackedStringArray(["--bot-cheat=reach"])),
		_bot(3, "solmarch", PackedStringArray(["--bot-cheat=rate"])),
	]
	# 5,3 s de margen entre lo que dura cada bot y lo que dura el servidor: los tres procesos de bot
	# arrancan uno tras otro y, con la máquina cargada, entran hacia el tick 170 del servidor; si el
	# servidor cierra antes de que el bot acabe sus 640 ticks, el bot sale con 1.
	var scenario: Dictionary = await _run_scenario("cheat_combat", LIGHT_ZONE, 960, 640, bots)
	if not assert_true(scenario["ok"], "el escenario termina"):
		return
	var server: Dictionary = scenario["server"]
	assert_eq(server["exit"], 0, "el servidor sale con 0")
	assert_eq(_error_lines(server["log"]), PackedStringArray(), "sin errores en el registro del servidor")
	var data: Dictionary = server["data"]
	assert_eq(int((data.get("strikes", {}) as Dictionary).get("total", -1)), 0, "sin avisos: ninguno rompe el protocolo")
	assert_true((data.get("kicks", []) as Array).is_empty(), "ni expulsiones")
	var players: Dictionary = {}
	for index: int in 3:
		var bot: Dictionary = scenario["bots"][index]
		var report: Dictionary = bot["data"]
		assert_eq(bot["exit"], 0, "el tramposo %d sale con 0" % (index + 1))
		assert_eq(_error_lines(bot["log"]), PackedStringArray(), "y sin errores en su registro")
		assert_eq(report.get("cheat"), ["rewind", "reach", "rate"][index], "lleva el modo pedido")
		assert_eq(int(report.get("unexplained_diffs", -1)), 0, "su predicción no falla")
		players[report.get("cheat")] = _server_player(scenario, int(report.get("net_id", 0)))
	var rewind: Dictionary = players["rewind"]
	var reach: Dictionary = players["reach"]
	var rate: Dictionary = players["rate"]
	assert_true(int(rewind.get("swings", 0)) >= 3, "rewind lanza golpes (%s)" % rewind.get("swings"))
	assert_eq(int(rewind.get("swings_landed", -1)), 0, "ninguno acierta")
	assert_true(int(rewind.get("rewind_rejects", 0)) >= 3, "el servidor los rechaza por el tope")
	assert_eq(int(rewind.get("suspicion", -1)), int(rewind.get("rewind_rejects", -2)), "y la sospecha sube")
	assert_true(int(reach.get("swings", 0)) >= 3, "reach lanza golpes (%s)" % reach.get("swings"))
	assert_eq(int(reach.get("swings_landed", -1)), 0, "desde 5 m no acierta ninguno")
	assert_eq(int(reach.get("suspicion", -1)), 0, "con entradas legítimas no hay sospecha")
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var combo_ticks: int = 0
	for light_id: int in weapon.light_ids:
		combo_ticks += CombatCatalog.attack(light_id).total_ticks
	var most_swings: int = ceili(640.0 * float(weapon.light_ids.size()) / float(combo_ticks)) + 1
	assert_true(int(rate.get("swings_landed", 0)) >= 3, "rate sí acierta alguno (%s)" % rate.get("swings_landed"))
	assert_true(int(rate.get("swings", 0)) <= most_swings,
			"pero no lanza más ataques que el combo permite: %s <= %d" % [rate.get("swings"), most_swings])
	assert_eq(int(rate.get("suspicion", -1)), 0, "machacar el botón no suma sospecha")
	var combat: Dictionary = data.get("combat", {})
	assert_eq(int(combat.get("rewind_rejected", -1)), int(rewind.get("rewind_rejects", -2)),
			"el servidor rechazó solo los de rewind")
	var suspicious: Array = combat.get("suspicious", [])
	if assert_eq(suspicious.size(), 1, "el informe señala a uno solo"):
		assert_eq(int((suspicious[0] as Dictionary).get("net_id", 0)), int(rewind.get("net_id", -1)))


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


## Dos enjambres de combate ([code]--bots=3 --bot-brain=combat[/code], uno por reino) contra el servidor de
## [code]test_world[/code]: los bots ligeros, que no simulan, se buscan por los ENTITY_SPAWN y los
## snapshots, pelean con rebobinado de verdad (mandan su desfase de vista) y reciben los ENTITY_EVENT.
func test_combat_swarms_fight_each_other_with_the_rewind_of_a_real_client() -> void:
	var combat: PackedStringArray = PackedStringArray(["--bot-brain=combat"])
	var scenario: Dictionary = await _run_scenario("swarm_combat", LIGHT_ZONE, 700, 560,
			[_swarm(3, 100, "vardheim", combat), _swarm(3, 200, "solmarch", combat)])
	if not assert_true(scenario["ok"], "el escenario termina"):
		return
	var server: Dictionary = scenario["server"]
	assert_eq(server["exit"], 0, "el servidor sale con 0")
	assert_eq(_error_lines(server["log"]), PackedStringArray(), "sin errores en el registro del servidor")
	var data: Dictionary = server["data"]
	var stats: Dictionary = data.get("combat", {})
	print("[enjambres de combate] golpes %d, bloqueados %d, muertes %d, eventos enviados %d, rebobinados rechazados %d" % [
			int(stats.get("hits", 0)), int(stats.get("blocked", 0)), int(stats.get("deaths", 0)),
			int(stats.get("events_sent", 0)), int(stats.get("rewind_rejected", 0))])
	assert_true(int(stats.get("hits", 0)) >= 8, "se pegan (%s golpes)" % stats.get("hits"))
	assert_true(int(stats.get("deaths", 0)) >= 1, "y alguien muere (%s muertes)" % stats.get("deaths"))
	assert_true(int(stats.get("events_sent", 0)) > int(stats.get("events", 0)),
			"cada evento llega a varios clientes (%s enviados, %s emitidos)" % [stats.get("events_sent"),
			stats.get("events")])
	assert_eq(int(stats.get("rewind_rejected", -1)), 0, "ningún desfase de vista pasa del tope")
	assert_eq((stats.get("suspicious", []) as Array).size(), 0, "y nadie levanta sospechas")
	assert_eq(int((data.get("strikes", {}) as Dictionary).get("total", -1)), 0, "sin avisos")
	assert_true((data.get("kicks", []) as Array).is_empty(), "ni expulsiones")
	for index: int in 2:
		var swarm: Dictionary = scenario["bots"][index]
		assert_eq(swarm["exit"], 0, "el enjambre %d sale con 0: todos jugaban" % (index + 1))
		assert_eq(_error_lines(swarm["log"]), PackedStringArray(), "sin errores en su registro")
		var clients: Array = (swarm["data"] as Dictionary).get("clients", [])
		assert_eq(clients.size(), 3)
		var known: int = 0
		for entry: Dictionary in clients:
			# El máximo de la sesión, no el valor al irse: bajo carga el otro enjambre puede haberse ido
			# antes y el recuento final depende del orden de salida.
			known += int(entry.get("enemies_known_max", 0))
			assert_true(bool(entry.get("combat", false)), "%s pelea" % entry.get("name"))
			assert_true(int(entry.get("spawns_seen", 0)) >= 5, "%s ve a los demás (%s)" % [
					entry.get("name"), entry.get("spawns_seen")])
			assert_true(int(entry.get("hit_events_seen", 0)) > 0, "%s recibe eventos de golpe" % entry.get("name"))
			assert_true(int(entry.get("event_bytes", 0)) > 0)
			assert_eq(int(entry.get("malformed_packets", -1)), 0, "ni paquetes mal formados")
		if index == 0:
			assert_eq(known, 9, "cada bot del primer enjambre llegó a conocer a los 3 enemigos")
