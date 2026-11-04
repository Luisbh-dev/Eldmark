class_name TestCase
extends RefCounted
## Base class of the automated tests.
##
## Each [code]res://tests/test_*.gd[/code] file inherits from this class. The runner
## ([code]res://tests/run_tests.gd[/code]) creates a fresh instance for each test, fills in
## [member tree] and calls, in this order, [code]before_each()[/code] (if it exists), the
## [code]test_*[/code] method and [code]after_each()[/code] (if it exists). All three may use
## [code]await[/code].
## [br][br]
## Assertions do not stop the test: they record the failure with its message (and the line where it
## happened) and return [code]false[/code], so the test can exit early if it needs to:
## [codeblock]
## if not assert_not_null(scene, "Could not load the scene"):
##     return
## [/codeblock]

## Scene tree in which the tests run.
var tree: SceneTree

var _failures: PackedStringArray = PackedStringArray()
var _assertion_count: int = 0
var _logged_errors_allowed: bool = false


## Checks that [param condition] is true.
func assert_true(condition: bool, message: String = "") -> bool:
	return _check(condition, "expected true", message)


## Checks that [param condition] is false.
func assert_false(condition: bool, message: String = "") -> bool:
	return _check(not condition, "expected false", message)


## Checks that [param actual] equals [param expected]. Types must match, except
## int/float and String/StringName, which are compared by value.
func assert_eq(actual: Variant, expected: Variant, message: String = "") -> bool:
	var detail: String = "expected %s, got %s" % [_repr(expected), _repr(actual)]
	return _check(_values_equal(actual, expected), detail, message)


## Checks that [code]|a - b| <= eps[/code]. A NaN or an infinity always fails.
func assert_near(a: float, b: float, eps: float, message: String = "") -> bool:
	var ok: bool = is_finite(a) and is_finite(b) and absf(a - b) <= eps
	var detail: String = "%s is not within %s of %s (difference %s)" % [
		_repr(a), _repr(eps), _repr(b), _repr(absf(a - b)),
	]
	return _check(ok, detail, message)


## Checks that the distance between two vectors ([Vector2], [Vector3] or [Vector4] of the same
## type) is [code]<= eps[/code]. A NaN or infinite component always fails.
func assert_vec_near(a: Variant, b: Variant, eps: float, message: String = "") -> bool:
	var vector_types: Array[int] = [TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4]
	if typeof(a) != typeof(b) or typeof(a) not in vector_types:
		return _check(false, "assert_vec_near needs two vectors of the same type (%s, %s)" % [
			type_string(typeof(a)), type_string(typeof(b)),
		], message)
	var distance: float = a.distance_to(b)
	var ok: bool = a.is_finite() and b.is_finite() and distance <= eps
	var detail: String = "%s is not within %s of %s (distance %s)" % [
		_repr(a), _repr(eps), _repr(b), _repr(distance),
	]
	return _check(ok, detail, message)


## Checks that [param value] is null (or an already freed object).
func assert_null(value: Variant, message: String = "") -> bool:
	return _check(not _is_present(value), "expected null, got %s" % _repr(value), message)


## Checks that [param value] is neither null nor a freed object.
func assert_not_null(value: Variant, message: String = "") -> bool:
	return _check(_is_present(value), "expected a value, got null", message)


## Records a failure unconditionally.
func fail(message: String) -> void:
	_check(false, "", message)


## Allows the current test to log engine errors without the runner marking it as
## failed, for tests that deliberately trigger an engine error (for example, loading a
## resource that does not exist). Script errors (calls on null, nonexistent methods...)
## always make the test fail.
func allow_logged_errors() -> void:
	_logged_errors_allowed = true


## Waits [param count] physics steps. On return, the code runs inside the physics
## step ([method Engine.is_in_physics_frame] is true) until the next [code]await[/code].
func wait_physics_frames(count: int = 1) -> void:
	for _i: int in count:
		await tree.physics_frame


## Waits [param count] process frames.
func wait_process_frames(count: int = 1) -> void:
	for _i: int in count:
		await tree.process_frame


# --- API for the runner ---------------------------------------------------------------------

## Used by the runner: leaves the instance ready to start a test.
func reset_results() -> void:
	_failures = PackedStringArray()
	_assertion_count = 0
	_logged_errors_allowed = false


## Used by the runner: messages of the failed assertions.
func get_failures() -> PackedStringArray:
	return _failures


## Used by the runner: number of assertions made.
func get_assertion_count() -> int:
	return _assertion_count


## Used by the runner: whether the test accepted engine errors with [method allow_logged_errors].
func are_logged_errors_allowed() -> bool:
	return _logged_errors_allowed


# --- Internal ----------------------------------------------------------------------------------

func _check(ok: bool, detail: String, message: String) -> bool:
	_assertion_count += 1
	if not ok:
		var text: String = message
		if message.is_empty():
			text = detail
		elif not detail.is_empty():
			text = "%s: %s" % [message, detail]
		var location: String = _caller_location()
		if not location.is_empty():
			text += "  [%s]" % location
		_failures.append(text)
	return ok


# First stack frame that does not belong to this file (the line of the test that failed).
func _caller_location() -> String:
	# get_script() is the test's script; this class's is the base of the chain.
	var base_script: Script = get_script() as Script
	while base_script.get_base_script() != null:
		base_script = base_script.get_base_script()
	var own_path: String = base_script.resource_path
	for backtrace: ScriptBacktrace in Engine.capture_script_backtraces(false):
		for i: int in backtrace.get_frame_count():
			var file: String = backtrace.get_frame_file(i)
			if file == own_path or file.is_empty():
				continue
			return "%s:%d" % [file.get_file(), backtrace.get_frame_line(i)]
	return ""


static func _is_present(value: Variant) -> bool:
	if value == null:
		return false
	if typeof(value) == TYPE_OBJECT:
		return is_instance_valid(value)
	return true


static func _values_equal(a: Variant, b: Variant) -> bool:
	var type_a: int = typeof(a)
	var type_b: int = typeof(b)
	var numeric: Array[int] = [TYPE_INT, TYPE_FLOAT]
	var textual: Array[int] = [TYPE_STRING, TYPE_STRING_NAME]
	if type_a in numeric and type_b in numeric:
		return a == b
	if type_a in textual and type_b in textual:
		return str(a) == str(b)
	if type_a != type_b:
		return false
	return a == b


static func _repr(value: Variant) -> String:
	match typeof(value):
		TYPE_STRING, TYPE_STRING_NAME:
			return "\"%s\"" % value
		TYPE_NIL:
			return "null"
	return str(value)
