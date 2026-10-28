class_name TestCase
extends RefCounted
## Clase base de las pruebas automáticas.
##
## Cada archivo [code]res://tests/test_*.gd[/code] hereda de esta clase. El ejecutor
## ([code]res://tests/run_tests.gd[/code]) crea una instancia nueva para cada prueba, rellena
## [member tree] y llama, en este orden, a [code]before_each()[/code] (si existe), al método
## [code]test_*[/code] y a [code]after_each()[/code] (si existe). Los tres pueden usar
## [code]await[/code].
## [br][br]
## Las comprobaciones no detienen la prueba: registran el fallo con su mensaje (y la línea donde
## ocurrió) y devuelven [code]false[/code], para que la prueba pueda salir antes si lo necesita:
## [codeblock]
## if not assert_not_null(scene, "No se pudo cargar la escena"):
##     return
## [/codeblock]

## Árbol de escena en el que se ejecutan las pruebas.
var tree: SceneTree

var _failures: PackedStringArray = PackedStringArray()
var _assertion_count: int = 0
var _logged_errors_allowed: bool = false


## Comprueba que [param condition] es verdadera.
func assert_true(condition: bool, message: String = "") -> bool:
	return _check(condition, "se esperaba verdadero", message)


## Comprueba que [param condition] es falsa.
func assert_false(condition: bool, message: String = "") -> bool:
	return _check(not condition, "se esperaba falso", message)


## Comprueba que [param actual] es igual a [param expected]. Los tipos deben coincidir, salvo
## int/float y String/StringName, que se comparan por valor.
func assert_eq(actual: Variant, expected: Variant, message: String = "") -> bool:
	var detail: String = "se esperaba %s, se obtuvo %s" % [_repr(expected), _repr(actual)]
	return _check(_values_equal(actual, expected), detail, message)


## Comprueba que [code]|a - b| <= eps[/code]. Un NaN o un infinito siempre falla.
func assert_near(a: float, b: float, eps: float, message: String = "") -> bool:
	var ok: bool = is_finite(a) and is_finite(b) and absf(a - b) <= eps
	var detail: String = "%s no está a menos de %s de %s (diferencia %s)" % [
		_repr(a), _repr(eps), _repr(b), _repr(absf(a - b)),
	]
	return _check(ok, detail, message)


## Comprueba que la distancia entre dos vectores ([Vector2], [Vector3] o [Vector4] del mismo
## tipo) es [code]<= eps[/code]. Un componente NaN o infinito siempre falla.
func assert_vec_near(a: Variant, b: Variant, eps: float, message: String = "") -> bool:
	var vector_types: Array[int] = [TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4]
	if typeof(a) != typeof(b) or typeof(a) not in vector_types:
		return _check(false, "assert_vec_near necesita dos vectores del mismo tipo (%s, %s)" % [
			type_string(typeof(a)), type_string(typeof(b)),
		], message)
	var distance: float = a.distance_to(b)
	var ok: bool = a.is_finite() and b.is_finite() and distance <= eps
	var detail: String = "%s no está a menos de %s de %s (distancia %s)" % [
		_repr(a), _repr(eps), _repr(b), _repr(distance),
	]
	return _check(ok, detail, message)


## Comprueba que [param value] es null (o un objeto ya liberado).
func assert_null(value: Variant, message: String = "") -> bool:
	return _check(not _is_present(value), "se esperaba null, se obtuvo %s" % _repr(value), message)


## Comprueba que [param value] no es null ni un objeto liberado.
func assert_not_null(value: Variant, message: String = "") -> bool:
	return _check(_is_present(value), "se esperaba un valor, se obtuvo null", message)


## Registra un fallo sin condición.
func fail(message: String) -> void:
	_check(false, "", message)


## Permite que la prueba actual registre errores del motor sin que el ejecutor la marque como
## fallida, para las pruebas que provocan a propósito un error del motor (por ejemplo, cargar un
## recurso que no existe). Los errores de script (llamadas a null, métodos inexistentes...)
## siempre hacen fallar la prueba.
func allow_logged_errors() -> void:
	_logged_errors_allowed = true


## Espera [param count] pasos de física. Al volver, el código se ejecuta dentro del paso de
## física ([method Engine.is_in_physics_frame] es true) hasta el siguiente [code]await[/code].
func wait_physics_frames(count: int = 1) -> void:
	for _i: int in count:
		await tree.physics_frame


## Espera [param count] fotogramas de proceso.
func wait_process_frames(count: int = 1) -> void:
	for _i: int in count:
		await tree.process_frame


# --- API para el ejecutor ---------------------------------------------------------------------

## Usado por el ejecutor: deja la instancia lista para empezar una prueba.
func reset_results() -> void:
	_failures = PackedStringArray()
	_assertion_count = 0
	_logged_errors_allowed = false


## Usado por el ejecutor: mensajes de las comprobaciones fallidas.
func get_failures() -> PackedStringArray:
	return _failures


## Usado por el ejecutor: número de comprobaciones hechas.
func get_assertion_count() -> int:
	return _assertion_count


## Usado por el ejecutor: si la prueba aceptó errores del motor con [method allow_logged_errors].
func are_logged_errors_allowed() -> bool:
	return _logged_errors_allowed


# --- Interno ----------------------------------------------------------------------------------

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


# Primer marco de la pila que no pertenece a este archivo (la línea de la prueba que falló).
func _caller_location() -> String:
	# get_script() es el script de la prueba; el de esta clase es la base de la cadena.
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
