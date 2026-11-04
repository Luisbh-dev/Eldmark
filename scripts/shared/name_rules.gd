class_name NameRules
extends RefCounted
## Character name rules (SOC-01), shared by the client (which validates before
## connecting) and the server ([ServerAuth], which applies them in the HELLO).
## [br][br]
## A valid name has [constant MIN_LENGTH] to [constant MAX_LENGTH] Latin letters
## (a-z, with the accents áéíóú, ü and ñ), with no spaces, digits or symbols, starts with an
## uppercase letter and is not one of the [constant RESERVED] (game titles, realms, places and NPCs from
## docs/world.md). The rest of the letters are accepted as they come, uppercase or lowercase.
## [br][br]
## To compare names ([method normalize_key]) they are lowercased and the accents, the
## diaeresis and the eñe are removed, so that "Álvaro", "alvaro" and "ALVARO" are the same name, and also
## "Peña" and "Pena" (otherwise one could impersonate the other). Whispers by name and
## uniqueness within the zone use that key.
## [br][br]
## This is the game's limit; the protocol's (24 characters and 48 bytes in the HELLO,
## [constant NetProtocol.MAX_NAME_CHARS]) is wider and remains as the cap on what is
## accepted from the wire. It depends on nothing in [code]scripts/client/[/code] or
## [code]scripts/server/[/code].

## Reason a name is not valid. [constant OK] (0) is a valid name.
## [constant TAKEN] is not returned by [method validate] (it is a pure rule): it is assigned by whoever knows
## the connected players ([ServerAuth]).
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

## Minimum and maximum letters of a name.
const MIN_LENGTH: int = 3
const MAX_LENGTH: int = 16

## Accepted letters, uppercase and lowercase (same order in both strings).
const UPPER_LETTERS: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZÁÉÍÓÚÜÑ"
const LOWER_LETTERS: String = "abcdefghijklmnopqrstuvwxyzáéíóúüñ"
## Default name of a player: this prefix plus [constant DEFAULT_SUFFIX_LETTERS] letters.
const DEFAULT_PREFIX: String = "Jugador"
## Prefix of the default names of bots.
const BOT_PREFIX: String = "Bot"
const DEFAULT_SUFFIX_LETTERS: int = 4

## Reserved names (compared with [method normalize_key], so it does not matter how they are
## written here): game titles and notices, the realms and factions, and the main places and NPCs
## from docs/world.md. It does not include first names that only appear in a place name ("Atalaya de
## Brenn", "Cantera de Odd"...).
const RESERVED: Array[String] = [
	# System titles and voices.
	"GM", "Admin", "Administrador", "Administrator", "Moderador", "Moderator", "Mod",
	"Sistema", "System", "Servidor", "Server", "Soporte", "Support", "Staff", "Eldmark",
	# Realms, the old realm and the Hollow.
	"Vardheim", "Solmarch", "Askarra", "Eld", "Eldrun", "Huecos", "Hueco",
	# Capitals and zones of the realms.
	"Isenholm", "Valcorin", "Kassar", "Hondal", "Skarven", "Grimfell", "Lirien", "Morvel",
	"Thal", "Ruhn", "Ossar",
	# War zone: castles and the citadel.
	"Aldcor", "Grauholt", "Velmont", "Sarnath",
	# NPCs.
	"Capitán", "Guardia",
]

## Equivalences for [method normalize_key] (already lowercase). They are exported by
## [ProgressionRulesExport] for the platform, which applies the same rule in Go.
const FOLDED: Dictionary = {
	"á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ü": "u", "ñ": "n",
}

## Code of each reason in the platform API (the [code]reason[/code] of the 422
## [code]name_invalid[/code] and of [code]name-check[/code], docs/platform.md §4.1 and §4.4), by
## value of [enum Reason]. The cases shared with Go ([code]tests/fixtures/names/[/code]) use them.
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


## Checks [param display_name] and returns [constant Reason.OK] (0) if it is valid or the first reason
## why it is not, in this order: length, characters (in the order they appear), initial
## uppercase letter and reserved names.
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


## true if [param display_name] meets all the rules ([method validate] returns 0).
static func is_valid(display_name: String) -> bool:
	return validate(display_name) == Reason.OK


## Text in Spanish, for the player, of reason [param reason] (a value of [enum Reason]).
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


## Platform API code of reason [param reason] ([constant REASON_CODES]), or
## [code]""[/code] if it is not a value of [enum Reason].
static func reason_code(reason: int) -> String:
	return REASON_CODES.get(reason, "")


## Reason ([enum Reason]) of a platform API code ([code]"too_short"[/code]...), or
## -1 if it is none.
static func reason_from_code(code: String) -> int:
	for reason: int in REASON_CODES:
		if REASON_CODES[reason] == code:
			return reason
	return -1


## Summary of all the rules in one sentence, to show next to the name field or in the
## text of a generic rejection.
static func rules_summary() -> String:
	return "de %d a %d letras, sin espacios ni números y empezando por mayúscula" % [
		MIN_LENGTH, MAX_LENGTH,
	]


## Key to compare names: lowercase and without accents, diaeresis or eñe. Two names are the
## same if they have the same key. With text that is not a valid name it does not fail: it lowercases
## what it can and leaves the rest as is.
static func normalize_key(display_name: String) -> String:
	var lowered: String = display_name.to_lower()
	var key: String = ""
	for i: int in lowered.length():
		var letter: String = lowered[i]
		var folded: String = FOLDED.get(letter, letter)
		key += folded
	return key


## true if [param display_name] is, once normalized, one of the [constant RESERVED].
static func is_reserved(display_name: String) -> bool:
	var key: String = normalize_key(display_name)
	for reserved: String in RESERVED:
		if normalize_key(reserved) == key:
			return true
	return false


## Default name of a player without [code]--name[/code]: "Jugador" plus four letters taken
## from [param seed_value] ([code]0[/code] gives "Jugadoraaaa", [code]1[/code] "Jugadoraaab"...). It is always
## a valid name, and different seeds give different names up to 26^4 (456,976).
## Deterministic: it uses neither the clock nor global randomness.
static func default_name(seed_value: int) -> String:
	return DEFAULT_PREFIX + _letters_suffix(seed_value)


## Name of a bot without [code]--name[/code]: "Bot" plus four letters taken from [param seed_value]
## ([code]1[/code] gives "Botaaab"). Valid and deterministic, like [method default_name].
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
