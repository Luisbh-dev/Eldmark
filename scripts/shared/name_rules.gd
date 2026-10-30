class_name NameRules
extends RefCounted
## Reglas de los nombres de personaje (SOC-01), compartidas por el cliente (que valida antes de
## conectar) y el servidor ([ServerAuth], que las aplica en el HELLO).
## [br][br]
## Un nombre válido tiene de [constant MIN_LENGTH] a [constant MAX_LENGTH] letras latinas
## (a-z, con las tildes áéíóú, la ü y la ñ), sin espacios ni dígitos ni signos, empieza por
## mayúscula y no es uno de los [constant RESERVED] (cargos del juego, reinos, lugares y PNJ de
## docs/mundo.md). El resto de las letras se admite tal como viene, en mayúscula o minúscula.
## [br][br]
## Para comparar nombres ([method normalize_key]) se pasa a minúsculas y se quitan las tildes, la
## diéresis y la eñe, de modo que «Álvaro», «alvaro» y «ALVARO» son el mismo nombre, y también
## «Peña» y «Pena» (si no, uno se haría pasar por el otro). Los susurros por nombre y la
## unicidad dentro de la zona usan esa clave.
## [br][br]
## Este es el límite del juego; el del protocolo (24 caracteres y 48 bytes en el HELLO,
## [constant NetProtocol.MAX_NAME_CHARS]) es más ancho y se mantiene como tope de lo que se
## acepta del cable. No depende de nada de [code]scripts/client/[/code] ni de
## [code]scripts/server/[/code].

## Motivo por el que un nombre no vale. [constant OK] (0) es un nombre válido.
## [constant TAKEN] no lo devuelve [method validate] (es una regla pura): lo asigna quien conoce
## a los jugadores conectados ([ServerAuth]).
enum Reason {
	OK = 0,
	TOO_SHORT = 1,
	TOO_LONG = 2,
	HAS_SPACE = 3,
	HAS_DIGIT = 4,
	INVALID_CHARACTER = 5,
	NOT_CAPITALIZED = 6,
	RESERVED = 7,
	TAKEN = 8,
}

## Letras mínimas y máximas de un nombre.
const MIN_LENGTH: int = 3
const MAX_LENGTH: int = 16

## Letras admitidas, en mayúscula y en minúscula (mismo orden en las dos cadenas).
const UPPER_LETTERS: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZÁÉÍÓÚÜÑ"
const LOWER_LETTERS: String = "abcdefghijklmnopqrstuvwxyzáéíóúüñ"
## Nombre por defecto de un jugador: este prefijo más [constant DEFAULT_SUFFIX_LETTERS] letras.
const DEFAULT_PREFIX: String = "Jugador"
## Prefijo de los nombres por defecto de los bots.
const BOT_PREFIX: String = "Bot"
const DEFAULT_SUFFIX_LETTERS: int = 4

## Nombres reservados (se comparan con [method normalize_key], así que da igual cómo se
## escriban aquí): cargos y avisos del juego, los reinos y bandos, y los lugares y PNJ principales
## de docs/mundo.md. No incluye nombres de pila que solo salen en un topónimo ( «Atalaya de
## Brenn», «Cantera de Odd»...).
const RESERVED: Array[String] = [
	# Cargos y voces del sistema.
	"GM", "Admin", "Administrador", "Administrator", "Moderador", "Moderator", "Mod",
	"Sistema", "System", "Servidor", "Server", "Soporte", "Support", "Staff", "Eldmark",
	# Reinos, el reino viejo y los Huecos.
	"Vardheim", "Solmarch", "Askarra", "Eld", "Eldrun", "Huecos", "Hueco",
	# Capitales y zonas de los reinos.
	"Isenholm", "Valcorin", "Kassar", "Hondal", "Skarven", "Grimfell", "Lirien", "Morvel",
	"Thal", "Ruhn", "Ossar",
	# Zona de guerra: castillos y la ciudadela.
	"Aldcor", "Grauholt", "Velmont", "Sarnath",
	# PNJ.
	"Capitán", "Guardia",
]

## Equivalencias para [method normalize_key] (ya en minúscula). Las exporta
## [ProgressionRulesExport] para la plataforma, que aplica la misma regla en Go.
const FOLDED: Dictionary = {
	"á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ü": "u", "ñ": "n",
}

## Código de cada motivo en la API de la plataforma (el [code]reason[/code] del 422
## [code]name_invalid[/code] y de [code]name-check[/code], docs/plataforma.md §4.1 y §4.4), por
## valor de [enum Reason]. Los casos compartidos con Go ([code]tests/fixtures/names/[/code]) los usan.
const REASON_CODES: Dictionary = {
	Reason.OK: "ok",
	Reason.TOO_SHORT: "too_short",
	Reason.TOO_LONG: "too_long",
	Reason.HAS_SPACE: "has_space",
	Reason.HAS_DIGIT: "has_digit",
	Reason.INVALID_CHARACTER: "invalid_character",
	Reason.NOT_CAPITALIZED: "not_capitalized",
	Reason.RESERVED: "reserved",
	Reason.TAKEN: "taken",
}


## Comprueba [param display_name] y devuelve [constant Reason.OK] (0) si vale o el primer motivo
## por el que no, en este orden: longitud, caracteres (en el orden en que aparecen), mayúscula
## inicial y reservados.
static func validate(display_name: String) -> int:
	var length: int = display_name.length()
	if length < MIN_LENGTH:
		return Reason.TOO_SHORT
	if length > MAX_LENGTH:
		return Reason.TOO_LONG
	for i: int in length:
		var letter: String = display_name[i]
		if UPPER_LETTERS.contains(letter) or LOWER_LETTERS.contains(letter):
			continue
		if letter == " ":
			return Reason.HAS_SPACE
		if letter >= "0" and letter <= "9":
			return Reason.HAS_DIGIT
		return Reason.INVALID_CHARACTER
	if not UPPER_LETTERS.contains(display_name[0]):
		return Reason.NOT_CAPITALIZED
	if is_reserved(display_name):
		return Reason.RESERVED
	return Reason.OK


## true si [param display_name] cumple todas las reglas ([method validate] devuelve 0).
static func is_valid(display_name: String) -> bool:
	return validate(display_name) == Reason.OK


## Texto en español, para el jugador, del motivo [param reason] (un valor de [enum Reason]).
static func reason_text(reason: int) -> String:
	match reason:
		Reason.OK:
			return "Nombre válido"
		Reason.TOO_SHORT:
			return "El nombre debe tener al menos %d letras" % MIN_LENGTH
		Reason.TOO_LONG:
			return "El nombre puede tener %d letras como máximo" % MAX_LENGTH
		Reason.HAS_SPACE:
			return "El nombre no puede llevar espacios"
		Reason.HAS_DIGIT:
			return "El nombre no puede llevar números"
		Reason.INVALID_CHARACTER:
			return "El nombre solo puede llevar letras (con tildes y ñ)"
		Reason.NOT_CAPITALIZED:
			return "El nombre debe empezar por mayúscula"
		Reason.RESERVED:
			return "Ese nombre está reservado"
		Reason.TAKEN:
			return "Ya hay un jugador conectado con ese nombre"
	return "Nombre no válido"


## Código en la API de la plataforma del motivo [param reason] ([constant REASON_CODES]), o
## [code]""[/code] si no es un valor de [enum Reason].
static func reason_code(reason: int) -> String:
	return REASON_CODES.get(reason, "")


## Motivo ([enum Reason]) de un código de la API de la plataforma ([code]"too_short"[/code]...), o
## -1 si no es ninguno.
static func reason_from_code(code: String) -> int:
	for reason: int in REASON_CODES:
		if REASON_CODES[reason] == code:
			return reason
	return -1


## Resumen de todas las reglas en una frase, para mostrarlo junto al campo del nombre o en el
## texto de un rechazo genérico.
static func rules_summary() -> String:
	return "de %d a %d letras, sin espacios ni números y empezando por mayúscula" % [
		MIN_LENGTH, MAX_LENGTH,
	]


## Clave para comparar nombres: minúsculas y sin tildes, diéresis ni eñe. Dos nombres son el
## mismo si tienen la misma clave. Con un texto que no es un nombre válido no falla: pasa a
## minúsculas lo que puede y deja el resto como está.
static func normalize_key(display_name: String) -> String:
	var lowered: String = display_name.to_lower()
	var key: String = ""
	for i: int in lowered.length():
		var letter: String = lowered[i]
		var folded: String = FOLDED.get(letter, letter)
		key += folded
	return key


## true si [param display_name] es, una vez normalizado, uno de los [constant RESERVED].
static func is_reserved(display_name: String) -> bool:
	var key: String = normalize_key(display_name)
	for reserved: String in RESERVED:
		if normalize_key(reserved) == key:
			return true
	return false


## Nombre por defecto de un jugador sin [code]--name[/code]: «Jugador» más cuatro letras sacadas
## de [param seed_value] ([code]0[/code] da «Jugadoraaaa», [code]1[/code] «Jugadoraaab»...). Siempre
## es un nombre válido, y semillas distintas dan nombres distintos hasta 26^4 (456 976).
## Determinista: no usa el reloj ni el azar global.
static func default_name(seed_value: int) -> String:
	return DEFAULT_PREFIX + _letters_suffix(seed_value)


## Nombre de un bot sin [code]--name[/code]: «Bot» más cuatro letras sacadas de [param seed_value]
## ([code]1[/code] da «Botaaab»). Válido y determinista, como [method default_name].
static func bot_name(seed_value: int) -> String:
	return BOT_PREFIX + _letters_suffix(seed_value)


static func _letters_suffix(seed_value: int) -> String:
	var combinations: int = 1
	for i: int in DEFAULT_SUFFIX_LETTERS:
		combinations *= 26
	var value: int = posmod(seed_value, combinations)
	var suffix: String = ""
	for i: int in DEFAULT_SUFFIX_LETTERS:
		suffix = LOWER_LETTERS[value % 26] + suffix
		value = int(value / 26.0)
	return suffix
