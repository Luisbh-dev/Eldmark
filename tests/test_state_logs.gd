extends TestCase
## Registros de estado ([code]--state-log[/code]) y [code]tools/compare_state_logs.gd[/code] (docs/red.md,
## sección 13; TEC-46):
## [br]- la lógica de [StateLogComparer] con registros sintéticos (coincidencias, diferencias explicadas
## por una sustitución, sin explicar, sin predicción, errores y deducción del jugador);
## [br]- registros de verdad: un servidor y un bot en un proceso, sin y con pérdida de paquetes, y las
## dos formas de ejecutar la herramienta (la clase y el script de [code]SceneTree[/code] en otro proceso).
## [br]Los registros reales van en [code]build/[/code] con extensión [code].txt[/code]: el importador de
## Godot convierte los [code].csv[/code] de dentro del proyecto en traducciones.

const ZONE_ID: String = "test_world"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const WAIT_FRAMES: int = 900
const MAX_WAIT_SECONDS: float = 25.0

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _client_viewport: SubViewport
var _client: NetClient
var _extra_viewports: Array[SubViewport] = []
var _client_substitutions: int = 0


func before_each() -> void:
	_root = Node.new()
	_root.name = "StateLogs"
	tree.root.add_child(_root)


func after_each() -> void:
	for viewport: SubViewport in _extra_viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_extra_viewports.clear()
	if is_instance_valid(_client_viewport):
		_client_viewport.free()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_client_viewport = null
	_server_viewport = null
	_client = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _build_path(file_name: String) -> String:
	return NetHarness.build_path(file_name)


## Estado de mentira: 70 caracteres hexadecimales con el valor [param value] repetido.
func _state(value: int) -> String:
	return ("%02x" % value).repeat(35)


## Líneas del servidor de un jugador para los ticks [param first] a [param last], con el estado
## [code]_state(tick)[/code]; las de [param substituted_ticks] van marcadas como sustituidas.
func _server_lines(net_id: int, first: int, last: int, substituted_ticks: Array[int],
		offset: int = 0) -> PackedStringArray:
	var lines := PackedStringArray()
	for tick: int in range(first, last + 1):
		lines.append("%d,%d,%d,%s" % [tick, net_id, 1 if substituted_ticks.has(tick) else 0,
				_state((tick + offset) % 200)])
	return lines


## Línea del bot para el snapshot [param tick]: lo que predijo y lo que le llegó (el estado del
## servidor en ese tick, salvo que se diga otra cosa).
func _bot_line(tick: int, predicted: String, from_server: String = "", offset: int = 0) -> String:
	if from_server.is_empty():
		from_server = _state((tick + offset) % 200)
	return "%d,%s,%s" % [tick, predicted, from_server]


# --- La lógica con registros sintéticos -------------------------------------------------------

func test_classifies_matches_explained_and_unexplained_differences() -> void:
	# Servidor: ticks 10 a 30; el 17 se sustituyó una entrada.
	var server: PackedStringArray = _server_lines(1, 10, 30, [17] as Array[int])
	var bot := PackedStringArray([
		_bot_line(12, _state(12)),                  # coincide
		_bot_line(14, _state(14)),                  # coincide
		_bot_line(18, _state(99)),                  # distinto, y el 17 (entre 15 y 18) se sustituyó
		_bot_line(20, _state(20)),                  # coincide: la reconciliación lo corrigió
		_bot_line(22, _state(98)),                  # distinto, sin sustitución entre el 21 y el 22
		_bot_line(24, _state(24)),                  # coincide
		_bot_line(26, ""),                          # sin predicción
	])
	var result: StateLogComparer.Result = StateLogComparer.compare(server, bot, 1)
	assert_eq(result.error, "")
	assert_eq(result.bot_lines, 7)
	assert_eq(result.matches, 4)
	assert_eq(result.explained, 1, "la diferencia del tick 18 la explica la sustitución del 17")
	assert_eq(result.explained_ticks, [18] as Array[int])
	assert_eq(result.unexplained, 1, "la del 22 no tiene explicación")
	assert_eq(result.unexplained_ticks, [22] as Array[int])
	assert_eq(result.unpredicted, 1)
	assert_eq(result.server_mismatches, 0)
	assert_eq(result.missing_ticks, 0)
	assert_false(result.is_ok(), "con una diferencia sin explicar no es correcto")
	assert_true(result.summary().contains("DIFERENCIAS SIN EXPLICAR"))
	assert_true(result.summary().contains("22"), "y el resumen dice en qué tick")


func test_a_substitution_explains_only_the_snapshots_that_follow_it() -> void:
	# Sustitución en el 20. El snapshot 20 (distinto) la explica; el 22, si vuelve a diferir, ya no.
	var server: PackedStringArray = _server_lines(1, 10, 30, [20] as Array[int])
	var bot := PackedStringArray([
		_bot_line(18, _state(18)),
		_bot_line(20, _state(77)),
		_bot_line(22, _state(78)),
	])
	var result: StateLogComparer.Result = StateLogComparer.compare(server, bot, 1)
	assert_eq(result.explained_ticks, [20] as Array[int])
	assert_eq(result.unexplained_ticks, [22] as Array[int], "la ventana de cada snapshot empieza en el anterior")
	# Un snapshot perdido ensancha la ventana: sin el 20 en el registro del bot, el 22 la incluye.
	var lost := PackedStringArray([_bot_line(18, _state(18)), _bot_line(22, _state(78))])
	var wide: StateLogComparer.Result = StateLogComparer.compare(server, lost, 1)
	assert_eq(wide.explained_ticks, [22] as Array[int], "los snapshots perdidos no esconden la sustitución")
	assert_eq(wide.unexplained, 0)


func test_the_first_snapshot_window_starts_when_the_player_joined() -> void:
	# El jugador entra en el tick 10 y el bot ve su primer snapshot en el 14; el 11 se sustituyó.
	var server: PackedStringArray = _server_lines(1, 10, 20, [11] as Array[int])
	var result: StateLogComparer.Result = StateLogComparer.compare(server,
			PackedStringArray([_bot_line(14, _state(55))]), 1)
	assert_eq(result.explained, 1)
	assert_eq(result.unexplained, 0)
	assert_true(result.is_ok(), "sin diferencias sin explicar es correcto")
	assert_true(result.summary().contains("CORRECTO"))


func test_reports_snapshots_that_do_not_match_the_server_log_and_missing_ticks() -> void:
	var server: PackedStringArray = _server_lines(1, 10, 20, [] as Array[int])
	var bot := PackedStringArray([
		_bot_line(12, _state(12)),
		_bot_line(14, _state(14), _state(150)),   # el estado propio no es el del registro del servidor
		_bot_line(40, _state(40)),                # el servidor no tiene ese tick
	])
	var result: StateLogComparer.Result = StateLogComparer.compare(server, bot, 1)
	assert_eq(result.matches, 1)
	assert_eq(result.server_mismatches, 1)
	assert_eq(result.missing_ticks, 1)
	assert_false(result.is_ok(), "los dos son errores")


func test_other_players_lines_are_ignored_and_the_player_is_deduced() -> void:
	var server: PackedStringArray = _server_lines(1, 10, 30, [] as Array[int])
	server.append_array(_server_lines(2, 10, 30, [15, 16, 17, 18, 19, 20] as Array[int], 50))
	var bot := PackedStringArray([_bot_line(14, _state(64), "", 50), _bot_line(16, _state(66), "", 50)])
	var result: StateLogComparer.Result = StateLogComparer.compare(server, bot)
	assert_eq(result.error, "")
	assert_eq(result.net_id, 2, "es el jugador cuyo estado en el tick 14 es el del primer snapshot")
	assert_eq(result.matches, 2)
	var explicit: StateLogComparer.Result = StateLogComparer.compare(server, bot, 1)
	assert_true(explicit.server_mismatches == 2, "con otro net_id no coincide con nada")


func test_ambiguous_or_unknown_players_are_an_error() -> void:
	var server: PackedStringArray = _server_lines(1, 10, 20, [] as Array[int])
	server.append_array(_server_lines(2, 10, 20, [] as Array[int]))   # mismo estado: ambiguo
	var bot := PackedStringArray([_bot_line(12, _state(12))])
	var ambiguous: StateLogComparer.Result = StateLogComparer.compare(server, bot)
	assert_false(ambiguous.error.is_empty(), "dos jugadores con el mismo estado")
	assert_true(ambiguous.error.contains("net_id"), "y se pide el net_id")
	var unknown: StateLogComparer.Result = StateLogComparer.compare(server,
			PackedStringArray([_bot_line(12, _state(12), _state(190))]))
	assert_false(unknown.error.is_empty(), "ningún jugador con ese estado")
	var absent: StateLogComparer.Result = StateLogComparer.compare(server, bot, 7)
	assert_true(absent.error.contains("net_id 7"), "net_id que no está en el servidor")
	var empty: StateLogComparer.Result = StateLogComparer.compare(server, PackedStringArray())
	assert_false(empty.error.is_empty(), "registro del bot vacío")
	assert_false(empty.is_ok())


func test_malformed_lines_are_counted() -> void:
	var server: PackedStringArray = _server_lines(1, 10, 20, [] as Array[int])
	server.append("basura")
	var bot := PackedStringArray([_bot_line(12, _state(12)), "x,y,z", "12,solo,dos,cuatro", ""])
	var result: StateLogComparer.Result = StateLogComparer.compare(server, bot, 1)
	assert_eq(result.matches, 1)
	assert_eq(result.malformed_lines, 3, "dos del bot y una del servidor; las vacías no cuentan")
	assert_false(result.is_ok())


func test_compare_files_reports_missing_files() -> void:
	var result: StateLogComparer.Result = StateLogComparer.compare_files(
			_build_path("no_existe_servidor.txt"), _build_path("no_existe_bot.txt"))
	assert_true(result.error.contains("no existe"))


# --- Registros de verdad ----------------------------------------------------------------------

## Un servidor y un bot que juegan [param frames] fotogramas de física con el simulador de red
## [param net_sim_spec]; devuelve las rutas de los dos registros ya cerrados.
func _record_real_logs(tag: String, net_sim_spec: String, frames: int) -> PackedStringArray:
	var server_log: String = _build_path("test_state_logs_%s_server.txt" % tag)
	var bot_log: String = _build_path("test_state_logs_%s_bot.txt" % tag)
	for path: String in [server_log, bot_log]:
		DirAccess.remove_absolute(path)
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = port
	config.zone_id = ZONE_ID
	config.max_players = 4
	config.state_log_path = server_log
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	_client_viewport = NetHarness.make_world_viewport(_root, "")
	_client = NetHarness.start_bot(_client_viewport, port, VARDHEIM, 3, net_sim_spec)
	# El registro del bot se abre al llegar el primer snapshot.
	_client.get_config().state_log_path = bot_log
	var entered: bool = false
	for _i: int in WAIT_FRAMES:
		if _client.get_state() == NetClient.State.IN_WORLD:
			entered = true
			break
		await tree.physics_frame
	assert_true(entered, "el bot entra en el mundo")
	# Otro jugador (falso) para que el registro del servidor tenga más de uno.
	_server.add_fake_player(BotBrain.new(5, BotBrain.Pattern.WANDER, Vector3.ZERO, 20.0), SOLMARCH)
	await wait_physics_frames(frames)
	_client_substitutions = int(_client.get_stats()["substitutions_total"])
	# Cerrar el servidor cierra su registro; el del bot, al liberarlo.
	_client.leave()
	await wait_physics_frames(30)
	_server.stop()
	await wait_physics_frames(40)
	_client.free()
	_client = null
	return PackedStringArray([server_log, bot_log])


func test_real_logs_have_no_unexplained_differences_without_a_network_simulator() -> void:
	var logs: PackedStringArray = await _record_real_logs("clean", "", 360)
	var result: StateLogComparer.Result = StateLogComparer.compare_files(logs[0], logs[1])
	assert_eq(result.error, "", "se deduce el jugador")
	assert_true(result.bot_lines > 100, "el bot registró sus snapshots (%d)" % result.bot_lines)
	assert_eq(result.unexplained, 0, result.summary())
	assert_eq(result.server_mismatches, 0, "el estado propio de cada snapshot es el del registro del servidor")
	assert_eq(result.missing_ticks, 0)
	assert_eq(result.malformed_lines, 0)
	assert_true(result.matches > 100, "casi todo coincide bit a bit (%d)" % result.matches)
	assert_true(result.is_ok(), result.summary())
	# Con el net_id explícito sale lo mismo.
	var explicit: StateLogComparer.Result = StateLogComparer.compare_files(logs[0], logs[1], result.net_id)
	assert_eq(explicit.matches, result.matches)


func test_real_logs_with_packet_loss_explain_every_difference() -> void:
	var logs: PackedStringArray = await _record_real_logs("lossy",
			"rtt=100,jitter=20,loss=55,dup=0,seed=11", 480)
	var result: StateLogComparer.Result = StateLogComparer.compare_files(logs[0], logs[1])
	assert_eq(result.error, "")
	assert_true(result.bot_lines > 100, "el bot registró sus snapshots (%d)" % result.bot_lines)
	assert_eq(result.unexplained, 0, "toda diferencia coincide con una entrada sustituida: " + result.summary())
	assert_eq(result.server_mismatches, 0)
	assert_eq(result.missing_ticks, 0)
	assert_true(result.is_ok(), result.summary())
	# Con tanta pérdida el servidor sustituye entradas, y alguna vez el bot se equivoca al predecirlas
	# (cuántas veces depende de cómo se adapte TickSync; lo que no puede haber son diferencias sin
	# explicar).
	var substitutions: int = _client_substitutions
	assert_true(substitutions > 0, "el servidor sustituyó entradas (%d)" % substitutions)
	var logged: int = result.matches + result.explained + result.unpredicted
	assert_eq(logged, result.bot_lines, "cada línea tiene su categoría")
	print("[test_state_logs] con pérdida: %d coinciden, %d explicadas, %d sin predicción" % [
		result.matches, result.explained, result.unpredicted])


func test_the_tool_script_exits_with_the_right_code() -> void:
	var server_log: String = _build_path("test_state_logs_tool_server.txt")
	var good_log: String = _build_path("test_state_logs_tool_good.txt")
	var bad_log: String = _build_path("test_state_logs_tool_bad.txt")
	_write(server_log, _server_lines(1, 10, 30, [17] as Array[int]))
	_write(good_log, PackedStringArray([_bot_line(12, _state(12)), _bot_line(18, _state(99))]))
	_write(bad_log, PackedStringArray([_bot_line(12, _state(12)), _bot_line(14, _state(98))]))
	var good: Dictionary = await _run_tool(PackedStringArray([server_log, good_log, "1"]))
	assert_eq(good["code"], 0, "sin diferencias sin explicar: salida 0 (%s)" % good["output"])
	assert_true(String(good["output"]).contains("CORRECTO"))
	var bad: Dictionary = await _run_tool(PackedStringArray([server_log, bad_log]))
	assert_eq(bad["code"], 1, "con una diferencia sin explicar: salida 1 (%s)" % bad["output"])
	assert_true(String(bad["output"]).contains("DIFERENCIAS SIN EXPLICAR"))
	var usage: Dictionary = await _run_tool(PackedStringArray([server_log]))
	assert_eq(usage["code"], 2, "uso incorrecto: salida 2")
	var missing: Dictionary = await _run_tool(PackedStringArray([server_log, _build_path("nada.txt")]))
	assert_eq(missing["code"], 2, "archivo que falta: salida 2")


func _write(path: String, lines: PackedStringArray) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()


## Ejecuta [code]tools/compare_state_logs.gd[/code] en otro proceso con [param tool_args] y devuelve
## {code, output}.
func _run_tool(tool_args: PackedStringArray) -> Dictionary:
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://tools/compare_state_logs.gd", "--"])
	args.append_array(tool_args)
	var output: Array = []
	var code: int = OS.execute(OS.get_executable_path(), args, output, true)
	return {"code": code, "output": "\n".join(PackedStringArray(output))}
