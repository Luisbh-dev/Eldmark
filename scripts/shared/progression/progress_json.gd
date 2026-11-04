class_name ProgressJson
extends RefCounted
## Strict reading of the values in the progress JSON (docs/progression.md §3.4; platform.md §4.1),
## the same as the Go platform does with [code]jsonx.ID[/code] and [code]jsonx.Int[/code].
## [br][br]
## [b]Ids[/b] ([code]uid[/code], [code]op_id[/code], [code]seed[/code]…): a decimal string, digits
## only, with no sign, spaces or leading zeros. An unquoted number is not valid:
## [code]JSON.parse_string[/code] would read it as a [code]float[/code] and silently lose precision
## above 2^53.
## [b]Integers[/b] (quantities, codes, slots): an exact number ([code]v == floor(v)[/code]); Godot
## writes [code]820.0[/code] when re-serializing what it read, and that is valid. [b]Booleans[/b]:
## only [code]true[/code] and [code]false[/code].
## [br][br]
## The checks never log engine errors: a 30-digit id is rejected before calling
## [method String.to_int], which would complain on overflow. Shared: no clock, no randomness.

## The largest integer a JSON number carries exactly (2^53 − 1): the cap of all progress ids.
const MAX_SAFE_INT: int = (1 << 53) - 1
# Digits of MAX_SAFE_INT (9007199254740991).
const _MAX_ID_DIGITS: int = 16


## true if [param value] is an id: a canonical decimal string with an integer between
## [param minimum] and [param maximum] (at most [constant MAX_SAFE_INT]). It is read with
## [method id_value].
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


## The value of an id that has already passed [method is_id].
static func id_value(value: Variant) -> int:
	return String(value).to_int()


## An id as it travels in the JSON: its decimal value in a string.
static func id_text(number: int) -> String:
	return str(number)


## true if [param value] is an exact integer number (int, or float with no fractional part) between
## [param minimum] and [param maximum]. It is read with [code]int(value)[/code].
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


## true if [param value] is a JSON boolean.
static func is_bool(value: Variant) -> bool:
	return typeof(value) == TYPE_BOOL
