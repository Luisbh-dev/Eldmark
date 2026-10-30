class_name PlatformJson
extends RefCounted
## Lectura estricta de los cuerpos de la API interna de la plataforma en la zona (docs/plataforma.md §4.1 y §6),
## la misma que hace Go con [code]jsonx.ID[/code] y [code]jsonx.Int[/code].
## [br][br]
## [b]Ids[/b] ([code]character_id[/code], [code]account_id[/code], [code]ticket_id[/code], [code]first[/code] de
## un bloque…): una cadena decimal de 0 a 2^63 − 1, sin signo, espacios ni ceros a la izquierda. Un número sin
## comillas no vale: [JSON] lo leería como [code]float[/code] y perdería precisión por encima de 2^53.
## [b]Enteros[/b]: un número exacto ([code]4[/code] o [code]4.0[/code]; Godot escribe [code]4.0[/code] al
## volver a serializar lo que leyó). Ninguna comprobación registra errores del motor: un id de 30 cifras se
## rechaza antes de llamar a [method String.to_int].

## El mayor id de la plataforma (2^63 − 1).
const MAX_ID: int = 0x7FFFFFFFFFFFFFFF
## El mayor entero que un número JSON lleva exacto (2^53 − 1).
const MAX_SAFE_INT: int = (1 << 53) - 1
const _MAX_ID_TEXT: String = "9223372036854775807"


## true si [param value] es un id canónico (una cadena decimal) entre [param minimum] y 2^63 − 1.
static func is_id(value: Variant, minimum: int = 1) -> bool:
	if typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
		return false
	var text: String = String(value)
	if text.is_empty() or text.length() > _MAX_ID_TEXT.length() or (text.length() > 1 and text[0] == "0"):
		return false
	for i: int in text.length():
		var code: int = text.unicode_at(i)
		if code < 48 or code > 57:
			return false
	# Con 19 cifras se compara el texto antes de convertir: to_int() se quejaría al desbordar.
	if text.length() == _MAX_ID_TEXT.length() and text > _MAX_ID_TEXT:
		return false
	return text.to_int() >= minimum


## El id de [param value], o -1 si no es un id canónico de al menos [param minimum].
static func id_of(value: Variant, minimum: int = 1) -> int:
	return String(value).to_int() if is_id(value, minimum) else -1


## Un id como viaja en el JSON: su valor decimal en una cadena.
static func id_text(number: int) -> String:
	return str(number)


## true si [param value] es un número entero exacto (int, o float sin parte fraccionaria) entre
## [param minimum] y [param maximum].
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


## El entero de [param key] en [param data] si existe y cabe en [[param minimum], [param maximum]]; si no,
## [param fallback].
static func int_in(data: Dictionary, key: String, minimum: int, maximum: int, fallback: int) -> int:
	var value: Variant = data.get(key)
	return int(value) if is_int(value, minimum, maximum) else fallback


## El texto de [param key] en [param data], o [param fallback] si no es una cadena.
static func text_in(data: Dictionary, key: String, fallback: String = "") -> String:
	var value: Variant = data.get(key)
	return String(value) if typeof(value) == TYPE_STRING else fallback


## El diccionario de [param key] en [param data], o uno vacío si no lo es.
static func dict_in(data: Dictionary, key: String) -> Dictionary:
	var value: Variant = data.get(key)
	return value if value is Dictionary else {}


## La lista de [param key] en [param data], o una vacía si no lo es.
static func array_in(data: Dictionary, key: String) -> Array:
	var value: Variant = data.get(key)
	return value if value is Array else []


## Lee [param raw] como JSON sin registrar errores del motor (nunca [method JSON.parse_string]: escribe un
## ERROR ante un cuerpo vacío o roto). Devuelve [code]{"ok": bool, "data": Variant}[/code]: un cuerpo vacío es
## [code]ok[/code] con [code]data[/code] null; uno que no es UTF-8 o no es JSON, [code]ok[/code] false.
static func parse(raw: PackedByteArray) -> Dictionary:
	if raw.is_empty():
		return {"ok": true, "data": null}
	if not NetMessages.is_valid_utf8(raw, 0, raw.size()):
		return {"ok": false, "data": null}
	var json := JSON.new()
	if json.parse(raw.get_string_from_utf8()) != OK:
		return {"ok": false, "data": null}
	return {"ok": true, "data": json.data}
