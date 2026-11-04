class_name PlatformJson
extends RefCounted
## Strict reading of the platform's internal API bodies in the zone (docs/plataforma.md §4.1 and §6),
## the same as Go does with [code]jsonx.ID[/code] and [code]jsonx.Int[/code].
## [br][br]
## [b]Ids[/b] ([code]character_id[/code], [code]account_id[/code], [code]ticket_id[/code], [code]first[/code] of
## a block…): a decimal string from 0 to 2^63 − 1, with no sign, spaces or leading zeros. A number without
## quotes is not valid: [JSON] would read it as a [code]float[/code] and lose precision above 2^53.
## [b]Integers[/b]: an exact number ([code]4[/code] or [code]4.0[/code]; Godot writes [code]4.0[/code] when
## re-serializing what it read). No check logs engine errors: a 30-digit id is
## rejected before calling [method String.to_int].

## The largest platform id (2^63 − 1).
const MAX_ID: int = 0x7FFFFFFFFFFFFFFF
## The largest integer a JSON number carries exactly (2^53 − 1).
const MAX_SAFE_INT: int = (1 << 53) - 1
const _MAX_ID_TEXT: String = "9223372036854775807"


## true if [param value] is a canonical id (a decimal string) between [param minimum] and 2^63 − 1.
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
	# With 19 digits the text is compared before converting: to_int() would complain on overflow.
	if text.length() == _MAX_ID_TEXT.length() and text > _MAX_ID_TEXT:
		return false
	return text.to_int() >= minimum


## The id of [param value], or -1 if it is not a canonical id of at least [param minimum].
static func id_of(value: Variant, minimum: int = 1) -> int:
	return String(value).to_int() if is_id(value, minimum) else -1


## An id as it travels in the JSON: its decimal value in a string.
static func id_text(number: int) -> String:
	return str(number)


## true if [param value] is an exact integer number (int, or float with no fractional part) between
## [param minimum] and [param maximum].
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


## The integer of [param key] in [param data] if it exists and fits in [[param minimum], [param maximum]]; otherwise,
## [param fallback].
static func int_in(data: Dictionary, key: String, minimum: int, maximum: int, fallback: int) -> int:
	var value: Variant = data.get(key)
	return int(value) if is_int(value, minimum, maximum) else fallback


## The text of [param key] in [param data], or [param fallback] if it is not a string.
static func text_in(data: Dictionary, key: String, fallback: String = "") -> String:
	var value: Variant = data.get(key)
	return String(value) if typeof(value) == TYPE_STRING else fallback


## The dictionary of [param key] in [param data], or an empty one if it is not one.
static func dict_in(data: Dictionary, key: String) -> Dictionary:
	var value: Variant = data.get(key)
	return value if value is Dictionary else {}


## The list of [param key] in [param data], or an empty one if it is not one.
static func array_in(data: Dictionary, key: String) -> Array:
	var value: Variant = data.get(key)
	return value if value is Array else []


## Reads [param raw] as JSON without logging engine errors (never [method JSON.parse_string]: it writes an
## ERROR on an empty or broken body). Returns [code]{"ok": bool, "data": Variant}[/code]: an empty body is
## [code]ok[/code] with [code]data[/code] null; one that is not UTF-8 or not JSON, [code]ok[/code] false.
static func parse(raw: PackedByteArray) -> Dictionary:
	if raw.is_empty():
		return {"ok": true, "data": null}
	if not NetMessages.is_valid_utf8(raw, 0, raw.size()):
		return {"ok": false, "data": null}
	var json := JSON.new()
	if json.parse(raw.get_string_from_utf8()) != OK:
		return {"ok": false, "data": null}
	return {"ok": true, "data": json.data}
