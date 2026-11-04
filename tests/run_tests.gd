extends SceneTree
## Automated test runner for Eldmark.
##
## Usage (from the project root):
## [codeblock]
## godot --headless --path . -s res://tests/run_tests.gd
## godot --headless --path . -s res://tests/run_tests.gd -- --filter=replay
## [/codeblock]
## Discovers [code]res://tests/test_*.gd[/code] (each inherits from [TestCase]), runs all of their
## methods that start with [code]test_[/code] (they may use [code]await[/code]) with optional
## [code]before_each()[/code]/[code]after_each()[/code], prints PASS/FAIL per test and a summary,
## and exits with code 0 if everything passes or 1 if anything fails.
## [br][br]
## A test also fails if a script or engine error is logged while it runs (unless it calls
## [method TestCase.allow_logged_errors], which only tolerates engine ones).
## It never hangs: each phase has a time limit and there is a global timer.
## [br][br]
## [code]--filter=<text>[/code] runs only the tests whose name
## ([code]file::method[/code]) contains the text.
## [br][br]
## [code]--shard=K/N[/code] runs only part K (1 to N) of the test files, distributed
## round-robin in alphabetical order: continuous integration launches the N parts at once.

const TESTS_DIR: String = "res://tests"
const TEST_FILE_PREFIX: String = "test_"
const TEST_METHOD_PREFIX: String = "test_"
## Frames to wait before starting, so the class cache and the autoloads
## are ready.
const STARTUP_FRAMES: int = 2
## Maximum time for each phase (before_each, the test, after_each).
const PHASE_TIMEOUT_MSEC: int = 30000
## Safety timer for the whole run.
const GLOBAL_TIMEOUT_SEC: float = 3600.0

const TestCaseScript = preload("res://tests/test_case.gd")


## Captures engine and script errors while each test runs.
## It can be called from any thread, hence the mutex.
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
## Part being run (1 to [member _shard_count]); with 1 of 1, all of them.
var _shard_index: int = 1
var _shard_count: int = 1
var _finished: bool = false
var _passed: int = 0
var _failed_names: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--filter="):
			_filter = arg.trim_prefix("--filter=")
		elif arg.begins_with("--shard="):
			var parts: PackedStringArray = arg.trim_prefix("--shard=").split("/")
			var valid: bool = parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int()
			if valid:
				_shard_index = parts[0].to_int()
				_shard_count = parts[1].to_int()
			if not valid or _shard_count < 1 or _shard_index < 1 or _shard_index > _shard_count:
				push_error("--shard=K/N necesita 1 <= K <= N: '%s'" % arg)
				_shard_index = 1
				_shard_count = 0
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
	if _shard_count != 1:
		print("Parte %d de %d" % [_shard_index, _shard_count])

	var files: PackedStringArray = _shard_of(_discover_test_files())
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
		# In exported projects the scripts show up as .gd.remap.
		var plain: String = file_name.trim_suffix(".remap")
		if plain.begins_with(TEST_FILE_PREFIX) and plain.ends_with(".gd") and plain != own_file:
			if not result.has(plain):
				result.append(plain)
	result.sort()
	var paths: PackedStringArray = PackedStringArray()
	for file_name: String in result:
		paths.append(TESTS_DIR.path_join(file_name))
	return paths


## The files of the requested part: the i-th one (in alphabetical order) goes to part i % N + 1. With a
## misspelled [code]--shard[/code] it returns none, and the run fails.
func _shard_of(files: PackedStringArray) -> PackedStringArray:
	if _shard_count == 1:
		return files
	var result: PackedStringArray = PackedStringArray()
	if _shard_count < 1:
		return result
	for i: int in files.size():
		if i % _shard_count == _shard_index - 1:
			result.append(files[i])
	return result


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


## Calls a method (synchronous or coroutine) and waits for it to finish, with a time limit.
## Returns false if it did not finish in time; in that case it adds the reason to [param problems].
func _call_with_timeout(target: Object, method: StringName, problems: Array[String]) -> bool:
	var flow: Dictionary = {"done": false}
	_invoke(target, method, flow)
	var started_msec: int = Time.get_ticks_msec()
	# A coroutine that hits a script error still finishes (Godot emits its "completed"),
	# so the time limit is only needed for those waiting on something that never arrives.
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
