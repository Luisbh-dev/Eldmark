extends SceneTree
## Ejecutor de las pruebas automáticas de Eldmark.
##
## Uso (desde la raíz del proyecto):
## [codeblock]
## godot --headless --path . -s res://tests/run_tests.gd
## godot --headless --path . -s res://tests/run_tests.gd -- --filter=replay
## [/codeblock]
## Descubre [code]res://tests/test_*.gd[/code] (cada uno hereda de [TestCase]), ejecuta todos sus
## métodos que empiezan por [code]test_[/code] (pueden usar [code]await[/code]) con
## [code]before_each()[/code]/[code]after_each()[/code] opcionales, imprime PASS/FAIL por prueba
## y un resumen, y termina con código 0 si todo pasa o 1 si algo falla.
## [br][br]
## Una prueba también falla si durante su ejecución se registra un error de script o del motor
## (salvo que llame a [method TestCase.allow_logged_errors], que solo tolera los del motor).
## Nunca se queda colgado: cada fase tiene un tiempo límite y hay un temporizador global.
## [br][br]
## [code]--filter=<texto>[/code] ejecuta solo las pruebas cuyo nombre
## ([code]archivo::método[/code]) contiene el texto.

const TESTS_DIR: String = "res://tests"
const TEST_FILE_PREFIX: String = "test_"
const TEST_METHOD_PREFIX: String = "test_"
## Fotogramas que se esperan antes de empezar, para que la caché de clases y los autoloads
## estén listos.
const STARTUP_FRAMES: int = 2
## Tiempo máximo de cada fase (before_each, la prueba, after_each).
const PHASE_TIMEOUT_MSEC: int = 30000
## Temporizador de seguridad para toda la ejecución.
const GLOBAL_TIMEOUT_SEC: float = 600.0

const TestCaseScript = preload("res://tests/test_case.gd")


## Captura los errores del motor y de los scripts mientras se ejecuta cada prueba.
## Se puede llamar desde cualquier hilo, de ahí el mutex.
class ErrorCatcher extends Logger:
	var _mutex: Mutex = Mutex.new()
	var _capturing: bool = false
	var _engine_errors: PackedStringArray = PackedStringArray()
	var _script_errors: PackedStringArray = PackedStringArray()

	func begin() -> void:
		_mutex.lock()
		_engine_errors = PackedStringArray()
		_script_errors = PackedStringArray()
		_capturing = true
		_mutex.unlock()

	func end() -> void:
		_mutex.lock()
		_capturing = false
		_mutex.unlock()

	func get_engine_errors() -> PackedStringArray:
		_mutex.lock()
		var copy: PackedStringArray = _engine_errors.duplicate()
		_mutex.unlock()
		return copy

	func get_script_errors() -> PackedStringArray:
		_mutex.lock()
		var copy: PackedStringArray = _script_errors.duplicate()
		_mutex.unlock()
		return copy

	func _log_error(function: String, file: String, line: int, code: String,
			rationale: String, _editor_notify: bool, error_type: int,
			_script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING or error_type == ERROR_TYPE_SHADER:
			return
		var text: String = rationale if not rationale.is_empty() else code
		var entry: String = "%s (%s, %s:%d)" % [text, function, file, line]
		_mutex.lock()
		if _capturing:
			if error_type == ERROR_TYPE_SCRIPT:
				_script_errors.append(entry)
			else:
				_engine_errors.append(entry)
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass


var _catcher: ErrorCatcher = ErrorCatcher.new()
var _filter: String = ""
var _finished: bool = false
var _passed: int = 0
var _failed_names: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--filter="):
			_filter = arg.trim_prefix("--filter=")
	create_timer(GLOBAL_TIMEOUT_SEC, true, false, true).timeout.connect(_on_global_timeout)
	_run()


func _run() -> void:
	for _i: int in STARTUP_FRAMES:
		await process_frame
	OS.add_logger(_catcher)
	var started_msec: int = Time.get_ticks_msec()
	print("Eldmark · pruebas (Godot %s, %d ticks/s)" % [
		Engine.get_version_info().string, Engine.physics_ticks_per_second,
	])
	if not _filter.is_empty():
		print("Filtro: \"%s\"" % _filter)

	var files: PackedStringArray = _discover_test_files()
	if files.is_empty():
		_record_failure("(ejecutor)", PackedStringArray(["No se encontró ningún %s/%s*.gd" % [
			TESTS_DIR, TEST_FILE_PREFIX,
		]]))
	for path: String in files:
		await _run_file(path)

	OS.remove_logger(_catcher)
	var total: int = _passed + _failed_names.size()
	var elapsed: float = (Time.get_ticks_msec() - started_msec) / 1000.0
	print("")
	if _failed_names.is_empty() and total > 0:
		print("Resumen: %d pruebas, todas correctas (%.2f s)" % [total, elapsed])
	else:
		print("Resumen: %d pruebas, %d correctas, %d fallidas (%.2f s)" % [
			total, _passed, _failed_names.size(), elapsed,
		])
		for test_name: String in _failed_names:
			print("  FAIL %s" % test_name)
	_finish(0 if _failed_names.is_empty() and total > 0 else 1)


func _discover_test_files() -> PackedStringArray:
	var own_file: String = (TestCaseScript as Script).resource_path.get_file()
	var result: PackedStringArray = PackedStringArray()
	for file_name: String in DirAccess.get_files_at(TESTS_DIR):
		# En proyectos exportados los scripts aparecen como .gd.remap.
		var plain: String = file_name.trim_suffix(".remap")
		if plain.begins_with(TEST_FILE_PREFIX) and plain.ends_with(".gd") and plain != own_file:
			if not result.has(plain):
				result.append(plain)
	result.sort()
	var paths: PackedStringArray = PackedStringArray()
	for file_name: String in result:
		paths.append(TESTS_DIR.path_join(file_name))
	return paths


func _run_file(path: String) -> void:
	var file_name: String = path.get_file()
	_catcher.begin()
	var test_script: GDScript = load(path) as GDScript
	_catcher.end()
	if test_script == null or not test_script.can_instantiate():
		var reasons: PackedStringArray = _catcher.get_script_errors()
		reasons.append_array(_catcher.get_engine_errors())
		reasons.append("No se pudo cargar el script. Si menciona clases que sí existen, la "
				+ "caché de clases puede estar desactualizada: ejecuta "
				+ "'godot --headless --path . --import'.")
		_record_failure("%s (carga)" % file_name, reasons)
		return

	var probe: Object = test_script.new()
	if not (probe is TestCaseScript):
		_record_failure("%s (carga)" % file_name, PackedStringArray(["No hereda de TestCase"]))
		return

	var methods: PackedStringArray = PackedStringArray()
	for method: Dictionary in test_script.get_script_method_list():
		var method_name: String = method["name"]
		if method_name.begins_with(TEST_METHOD_PREFIX) and not methods.has(method_name):
			methods.append(method_name)
	if methods.is_empty():
		var reason: PackedStringArray = PackedStringArray(["No contiene métodos test_*"])
		_record_failure("%s (carga)" % file_name, reason)
		return

	for method_name: String in methods:
		var full_name: String = "%s::%s" % [file_name, method_name]
		if not _filter.is_empty() and not full_name.contains(_filter):
			continue
		var instance: TestCaseScript = test_script.new() as TestCaseScript
		await _run_test(instance, method_name, full_name)


func _run_test(instance: TestCaseScript, method_name: String, full_name: String) -> void:
	instance.tree = self
	instance.reset_results()
	var problems: Array[String] = []
	var started_usec: int = Time.get_ticks_usec()
	_catcher.begin()

	var setup_ok: bool = true
	if instance.has_method(&"before_each"):
		setup_ok = await _call_with_timeout(instance, &"before_each", problems)
	if setup_ok:
		await _call_with_timeout(instance, StringName(method_name), problems)
	if instance.has_method(&"after_each"):
		await _call_with_timeout(instance, &"after_each", problems)

	_catcher.end()
	var elapsed_ms: float = (Time.get_ticks_usec() - started_usec) / 1000.0

	var failures: PackedStringArray = instance.get_failures().duplicate()
	for problem: String in problems:
		failures.append(problem)
	for error: String in _catcher.get_script_errors():
		failures.append("Error de script: %s" % error)
	if not instance.are_logged_errors_allowed():
		for error: String in _catcher.get_engine_errors():
			failures.append("Error registrado: %s" % error)

	if failures.is_empty():
		_passed += 1
		var note: String = ""
		if instance.get_assertion_count() == 0:
			note = "  (aviso: la prueba no hizo ninguna comprobación)"
		print("PASS %s (%.1f ms)%s" % [full_name, elapsed_ms, note])
	else:
		_record_failure(full_name, failures, elapsed_ms)


## Llama a un método (síncrono o corrutina) y espera a que termine, con tiempo límite.
## Devuelve false si no terminó a tiempo; en ese caso añade el motivo a [param problems].
func _call_with_timeout(target: Object, method: StringName, problems: Array[String]) -> bool:
	var flow: Dictionary = {"done": false}
	_invoke(target, method, flow)
	var started_msec: int = Time.get_ticks_msec()
	# Una corrutina que sufre un error de script termina igualmente (Godot emite su "completed"),
	# así que solo hace falta el tiempo límite para las que esperan algo que nunca llega.
	while not flow["done"]:
		if Time.get_ticks_msec() - started_msec > PHASE_TIMEOUT_MSEC:
			problems.append("%s superó el tiempo límite (%.0f s)" % [
				method, PHASE_TIMEOUT_MSEC / 1000.0,
			])
			return false
		await process_frame
	return true


func _invoke(target: Object, method: StringName, flow: Dictionary) -> void:
	await target.call(method)
	flow["done"] = true


func _record_failure(full_name: String, reasons: PackedStringArray,
		elapsed_ms: float = -1.0) -> void:
	_failed_names.append(full_name)
	var timing: String = "" if elapsed_ms < 0.0 else " (%.1f ms)" % elapsed_ms
	print("FAIL %s%s" % [full_name, timing])
	for reason: String in reasons:
		print("    - %s" % reason)


func _on_global_timeout() -> void:
	if _finished:
		return
	printerr("Tiempo límite global (%d s) superado: abortando las pruebas."
			% int(GLOBAL_TIMEOUT_SEC))
	_finish(1)


func _finish(exit_code: int) -> void:
	if _finished:
		return
	_finished = true
	quit(exit_code)
