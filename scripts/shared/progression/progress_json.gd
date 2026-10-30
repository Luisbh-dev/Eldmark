class_name ProgressJson
extends RefCounted
## Lectura estricta de los valores del JSON del progreso (docs/progresion.md §3.4; plataforma.md §4.1),
## la misma que hace la plataforma en Go con [code]jsonx.ID[/code] y [code]jsonx.Int[/code].
## [br][br]
## [b]Ids[/b] ([code]uid[/code], [code]op_id[/code], [code]seed[/code]…): una cadena decimal, solo dígitos,
## sin signo, espacios ni ceros a la izquierda. Un número sin comillas no vale: [code]JSON.parse_string[/code]
## lo leería como [code]float[/code] y perdería precisión por encima de 2^53 sin avisar.
## [b]Enteros[/b] (cantidades, códigos, ranuras): un número exacto ([code]v == floor(v)[/code]); Godot
## escribe [code]820.0[/code] al volver a serializar lo que leyó, y eso vale. [b]Booleanos[/b]: solo
## [code]true[/code] y [code]false[/code].
## [br][br]
## Las comprobaciones nunca registran errores del motor: un id de 30 cifras se rechaza antes de llamar a
## [method String.to_int], que se quejaría al desbordar. Compartido: sin reloj ni azar.

## El mayor entero que un número JSON lleva exacto (2^53 − 1): el tope de todos los ids del progreso.
const MAX_SAFE_INT: int = (1 << 53) - 1
# Cifras de MAX_SAFE_INT (9007199254740991).
const _MAX_ID_DIGITS: int = 16


## true si [param value] es un id: una cadena decimal canónica con un entero entre [param minimum] y
## [param maximum] (como mucho [constant MAX_SAFE_INT]). Se lee con [method id_value].
static func is_id(value: Variant, minimum: int = 1, maximum: int = MAX_SAFE_INT) -> bool:
	if typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
		return false
	var text: String = String(value)
	if text.is_empty() or text.length() > _MAX_ID_DIGITS or (text.length() > 1 and text[0] == "0"):
		return false
	for i: int in range(text.length()):
		var code: int = text.unicode_at(i)
		if code < 48 or code > 57:
			return false
	var number: int = text.to_int()
	return number >= minimum and number <= mini(maximum, MAX_SAFE_INT)


## El valor de un id que ya ha pasado [method is_id].
static func id_value(value: Variant) -> int:
	return String(value).to_int()


## Un id como viaja en el JSON: su valor decimal en una cadena.
static func id_text(number: int) -> String:
	return str(number)


## true si [param value] es un número entero exacto (int, o float sin parte fraccionaria) entre
## [param minimum] y [param maximum]. Se lee con [code]int(value)[/code].
static func is_int(value: Variant, minimum: int, maximum: int) -> bool:
	match typeof(value):
		TYPE_INT:
			return value >= minimum and value <= maximum
		TYPE_FLOAT:
			var number: float = value
			if not is_finite(number) or number != floorf(number) or absf(number) > float(MAX_SAFE_INT):
				return false
			return int(number) >= minimum and int(number) <= maximum
	return false


## true si [param value] es un booleano de JSON.
static func is_bool(value: Variant) -> bool:
	return typeof(value) == TYPE_BOOL
