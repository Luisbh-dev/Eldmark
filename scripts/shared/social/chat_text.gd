class_name ChatText
extends RefCounted
## Texto de un mensaje de chat: límites y saneado (docs/social.md, sección 5).
## [br][br]
## El servidor sanea todo texto antes de repartirlo ([method sanitize]) y el cliente aplica la misma
## función antes de enviar, de modo que lo que el jugador ve en su línea es lo que el servidor
## aceptará. El saneado quita, por este orden:
## [br]- los caracteres de control (C0, DEL, C1) y los invisibles que sirven para falsear texto
## (anchura cero, marcas de dirección, separadores de línea); el tabulador y los saltos de línea pasan
## a ser un espacio;
## [br]- la secuencia BBCode: todo lo que va entre corchetes, corchetes incluidos (se repite hasta que
## no queda ninguno, así que un par anidado como [code][[b]b][/code] tampoco sobrevive) y cualquier
## corchete suelto;
## [br]- los espacios repetidos y los de los extremos (también los espacios Unicode: el sin ruptura, el
## ideográfico...).
## [br][br]
## Un texto vacío tras el saneado, o de más de [constant MAX_CHARS] caracteres, no vale
## ([method check]). Compartido: no depende del cliente ni del servidor.

## Caracteres como mucho de un mensaje.
const MAX_CHARS: int = 255
## Bytes en UTF-8 como mucho de un mensaje (255 letras de 3 bytes caben justas).
const MAX_BYTES: int = 768

## Motivo por el que un texto no vale. [constant OK] es un texto utilizable.
enum Problem { OK = 0, EMPTY = 1, TOO_LONG = 2 }

# Espacios (normales y de Unicode) que se juntan en uno solo, y saltos de línea.
const _SPACES: Array[int] = [
	0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004,
	0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000,
]
const _OPEN_BRACKET: int = 0x5B
const _CLOSE_BRACKET: int = 0x5D

static var _markup: RegEx = null


## Texto saneado de [param text]: sin caracteres de control ni BBCode y con los espacios arreglados.
## Cadena vacía si no queda nada o si pasa de [constant MAX_CHARS] caracteres ([method check] dice cuál
## de las dos).
static func sanitize(text: String) -> String:
	var cleaned: String = clean(text)
	if cleaned.length() > MAX_CHARS:
		return ""
	return cleaned


## [constant Problem.OK] si [param text] vale una vez saneado, [constant Problem.EMPTY] si queda vacío y
## [constant Problem.TOO_LONG] si el saneado pasa de [constant MAX_CHARS] caracteres.
static func check(text: String) -> int:
	var cleaned: String = clean(text)
	if cleaned.is_empty():
		return Problem.EMPTY
	if cleaned.length() > MAX_CHARS:
		return Problem.TOO_LONG
	return Problem.OK


## Mensaje en español, para el jugador, de un [enum Problem] (vacío si es [constant Problem.OK]).
static func problem_text(problem: int) -> String:
	match problem:
		Problem.EMPTY:
			return "El mensaje está vacío."
		Problem.TOO_LONG:
			return "El mensaje es demasiado largo (%d caracteres como máximo)." % MAX_CHARS
	return ""


## Como [method sanitize], pero sin comprobar la longitud máxima.
static func clean(text: String) -> String:
	return _collapse_spaces(_strip_markup(_strip_controls(text)))


## true si el carácter con código [param code] se trata como un espacio (normal, Unicode o un salto
## de línea).
static func is_space(code: int) -> bool:
	return _SPACES.has(code)


## true si el carácter con código [param code] se quita al sanear: control o invisible (no cuentan los
## espacios ni los saltos, que pasan a ser un espacio).
static func is_stripped_control(code: int) -> bool:
	if _SPACES.has(code):
		return false
	if code < 0x20 or code == 0x7F or (code >= 0x80 and code <= 0x9F):
		return true
	# Anchura cero, marcas de dirección, separadores de línea y de párrafo, formato invisible, la marca
	# de orden de bytes y los caracteres de sustitución.
	return (code >= 0x200B and code <= 0x200F) or (code >= 0x2028 and code <= 0x202E) \
			or (code >= 0x2060 and code <= 0x206F) or code == 0xFEFF or code == 0xFFFC \
			or code == 0xFFFD


# Quita los caracteres de control y deja los espacios como un espacio normal.
static func _strip_controls(text: String) -> String:
	var kept := PackedInt32Array()
	for i: int in text.length():
		var code: int = text.unicode_at(i)
		if is_stripped_control(code):
			continue
		kept.append(0x20 if _SPACES.has(code) else code)
	return _from_codes(kept)


# Quita lo que va entre corchetes (repitiéndolo hasta que no cambie) y los corchetes que queden.
static func _strip_markup(text: String) -> String:
	if _markup == null:
		_markup = RegEx.new()
		_markup.compile("\\[[^\\[\\]]*\\]")
	var current: String = text
	var previous: String = ""
	while previous != current:
		previous = current
		current = _markup.sub(current, "", true)
	var kept := PackedInt32Array()
	for i: int in current.length():
		var code: int = current.unicode_at(i)
		if code != _OPEN_BRACKET and code != _CLOSE_BRACKET:
			kept.append(code)
	return _from_codes(kept)


# Junta los espacios seguidos en uno y quita los de los extremos.
static func _collapse_spaces(text: String) -> String:
	var kept := PackedInt32Array()
	var pending_space: bool = false
	for i: int in text.length():
		var code: int = text.unicode_at(i)
		if _SPACES.has(code):
			pending_space = not kept.is_empty()
			continue
		if pending_space:
			kept.append(0x20)
			pending_space = false
		kept.append(code)
	return _from_codes(kept)


static func _from_codes(codes: PackedInt32Array) -> String:
	if codes.is_empty():
		return ""
	return codes.to_byte_array().get_string_from_utf32()
