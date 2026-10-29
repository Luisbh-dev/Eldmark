class_name ChatText
extends RefCounted
## Texto de un mensaje de chat: límites y saneado (docs/social.md, secciones 5 y 12.2).
## [br][br]
## El servidor sanea todo texto antes de repartirlo ([method sanitize]) y el cliente aplica la misma
## función antes de enviar, de modo que lo que el jugador ve en su línea es lo que el servidor
## aceptará. El saneado quita, por este orden:
## [br]- lo que no se ve o sirve para falsear el texto: los controles (C0, DEL, C1), todo el formato
## invisible (categoría Cf de Unicode: anchura cero, marcas de dirección como U+200E o U+061C, el guion
## blando, las etiquetas U+E0000...), los separadores de línea y de párrafo, el uso privado, los no
## caracteres y los puntos de código sin asignar, los ignorables por defecto de Unicode (rellenos hangul,
## el unidor de grafemas, los selectores de variación salvo U+FE0F, que pide el emoji en color) y los
## caracteres de sustitución U+FFFC y U+FFFD; el tabulador, los saltos de línea, los espacios de Unicode
## y el blanco braille (U+2800) pasan a ser un espacio;
## [br]- la secuencia BBCode: todo lo que va entre corchetes, corchetes incluidos (un par anidado como
## [code][[b]b][/code] tampoco sobrevive), y cualquier corchete suelto;
## [br]- las marcas combinantes (categoría M) que no van tras una letra (al principio o tras un espacio)
## y las que pasan de [constant MAX_MARKS_PER_BASE] seguidas: una letra con cientos de marcas encima
## («zalgo») ocupa toda la caja de chat, y con unas 250 la maquetación de texto de Godot 4.7.2 se queda
## colgada en el cliente que la recibe;
## [br]- los espacios repetidos y los de los extremos.
## [br][br]
## Las categorías salen de las tablas de Unicode del motor (las [RegEx] de PCRE2 con [code]\p{…}[/code]),
## que son las mismas en el cliente y en el servidor porque los dos son el mismo binario. Cuesta lineal en
## la longitud del texto (sin repetir pasadas por cada nivel de corchetes) y casi todo corre en C++; un
## texto ASCII imprimible sin corchetes ni espacios de más sale enseguida tal cual.
## [br][br]
## Un texto vacío tras el saneado, o de más de [constant MAX_CHARS] caracteres, no vale
## ([method check]). Compartido: no depende del cliente ni del servidor.

## Caracteres como mucho de un mensaje.
const MAX_CHARS: int = 255
## Bytes en UTF-8 como mucho de un mensaje (255 letras de 3 bytes caben justas).
const MAX_BYTES: int = 768
## Marcas combinantes seguidas que se conservan sobre una misma letra (el hebreo con puntos y acentos o
## una sílaba tibetana usan hasta cuatro); el resto se quita.
const MAX_MARKS_PER_BASE: int = 4

## Motivo por el que un texto no vale. [constant OK] es un texto utilizable.
enum Problem { OK = 0, EMPTY = 1, TOO_LONG = 2 }

# Espacios (normales y de Unicode), saltos de línea y el blanco braille, que se juntan en uno solo.
const _SPACES: Array[int] = [
	0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004,
	0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x2800, 0x3000,
]
const _OPEN_BRACKET: int = 0x5B
const _CLOSE_BRACKET: int = 0x5D

# Lo que ya está limpio no casa: ASCII imprimible sin corchetes, sin espacios en los extremos ni dobles.
const _NEEDS_WORK_PATTERN: String = "[^\\x20-\\x5A\\x5C\\x5E-\\x7E]|^\\x20|\\x20$|\\x20\\x20"
# Los espacios que no son el normal (ver _SPACES).
const _OTHER_SPACES_PATTERN: String = \
		"[\\x09-\\x0D\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{202F}\\x{205F}\\x{2800}\\x{3000}]"
# Lo que se quita. Va después de cambiar los espacios, porque el tabulador y los saltos son Cc.
const _STRIPPED_PATTERN: String = \
		"(?!\\x{FE0F})[\\p{Cc}\\p{Cf}\\p{Co}\\p{Cs}\\p{Cn}\\p{Zl}\\p{Zp}\\p{DI}\\x{FFFC}\\x{FFFD}]"
# Marcas sin letra delante.
const _BASELESS_MARKS_PATTERN: String = "(^|\\x20)\\p{M}+"
# Marcas seguidas de más (el número lo pone MAX_MARKS_PER_BASE).
const _EXTRA_MARKS_PATTERN: String = "(\\p{M}{%d})\\p{M}+"
const _REPEATED_SPACES_PATTERN: String = "\\x20{2,}"

static var _needs_work: RegEx = null
static var _other_spaces: RegEx = null
static var _stripped: RegEx = null
static var _baseless_marks: RegEx = null
static var _extra_marks: RegEx = null
static var _repeated_spaces: RegEx = null


## Texto saneado de [param text]: sin caracteres de control ni invisibles, sin BBCode, con las marcas
## combinantes acotadas y con los espacios arreglados. Cadena vacía si no queda nada o si pasa de
## [constant MAX_CHARS] caracteres ([method check] dice cuál de las dos).
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


## Como [method sanitize], pero sin comprobar la longitud máxima. Es idempotente: sanear dos veces da lo
## mismo que una.
static func clean(text: String) -> String:
	_ensure_patterns()
	if _needs_work.search(text) == null:
		return text
	var result: String = _other_spaces.sub(text, " ", true)
	result = _stripped.sub(result, "", true)
	result = _strip_markup(result)
	result = _baseless_marks.sub(result, "$1", true)
	result = _extra_marks.sub(result, "$1", true)
	return _repeated_spaces.sub(result, " ", true).strip_edges()


## true si el carácter con código [param code] se trata como un espacio (normal, Unicode, un salto de
## línea o el blanco braille).
static func is_space(code: int) -> bool:
	return _SPACES.has(code)


## true si el carácter con código [param code] se quita siempre al sanear: control, invisible, sin asignar
## o de uso privado (no cuentan los espacios ni los saltos, que pasan a ser un espacio, ni las marcas
## combinantes, que se quitan según dónde vayan).
static func is_stripped_control(code: int) -> bool:
	if code <= 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF):
		return true
	if is_space(code):
		return false
	_ensure_patterns()
	return _stripped.search(String.chr(code)) != null


static func _ensure_patterns() -> void:
	if _needs_work != null:
		return
	_needs_work = RegEx.create_from_string(_NEEDS_WORK_PATTERN)
	_other_spaces = RegEx.create_from_string(_OTHER_SPACES_PATTERN)
	_stripped = RegEx.create_from_string(_STRIPPED_PATTERN)
	_baseless_marks = RegEx.create_from_string(_BASELESS_MARKS_PATTERN)
	_extra_marks = RegEx.create_from_string(_EXTRA_MARKS_PATTERN % MAX_MARKS_PER_BASE)
	_repeated_spaces = RegEx.create_from_string(_REPEATED_SPACES_PATTERN)


# Quita lo que va entre corchetes y los corchetes sueltos, en una sola pasada: cada «]» cierra el último
# «[» abierto y se lleva todo lo que hay entre los dos (también los pares de dentro); un «]» sin abrir se
# quita solo, y de un «[» sin cerrar se quita el corchete y se queda lo que le sigue. Es lo mismo que
# quitar el par más interior una y otra vez hasta que no quede ninguno, pero lineal.
static func _strip_markup(text: String) -> String:
	if not (text.contains("[") or text.contains("]")):
		return text
	var codes: PackedInt32Array = text.to_utf32_buffer().to_int32_array()
	var kept := PackedInt32Array()
	kept.resize(codes.size())
	var size: int = 0
	# Posiciones (en kept) de los «[» aún abiertos, de menor a mayor.
	var open := PackedInt32Array()
	for code: int in codes:
		if code == _CLOSE_BRACKET:
			if not open.is_empty():
				size = open[open.size() - 1]
				open.resize(open.size() - 1)
			continue
		if code == _OPEN_BRACKET:
			open.append(size)
		kept[size] = code
		size += 1
	if size == 0:
		return ""
	# Los únicos «[» que quedan son los que no se cerraron (los cerrados se fueron con su contenido).
	return kept.slice(0, size).to_byte_array().get_string_from_utf32().replace("[", "")
