class_name ChatText
extends RefCounted
## Text of a chat message: limits and sanitizing (docs/social.md, sections 5 and 12.2).
## [br][br]
## The server sanitizes all text before distributing it ([method sanitize]) and the client applies
## the same function before sending, so that what the player sees on their line is what the server
## will accept. Sanitizing removes, in this order:
## [br]- whatever is invisible or serves to falsify the text: controls (C0, DEL, C1), all invisible
## formatting (Unicode category Cf: zero width, direction marks such as U+200E or U+061C, the soft
## hyphen, the U+E0000... tags), line and paragraph separators, private use, noncharacters and
## unassigned code points, Unicode default ignorables (Hangul fillers, the grapheme joiner,
## variation selectors except U+FE0F, which requests the color emoji) and the replacement
## characters U+FFFC and U+FFFD; the tab, line breaks, Unicode spaces and the Braille blank
## (U+2800) become a space;
## [br]- the BBCode sequence: everything between square brackets, brackets included (a nested pair
## such as [code][[b]b][/code] does not survive either), and any stray bracket;
## [br]- combining marks (category M) that do not follow a letter (at the start or after a space)
## and those beyond [constant MAX_MARKS_PER_BASE] in a row: a letter with hundreds of marks on top
## ("zalgo") fills the whole chat box, and with about 250 Godot 4.7.2's text layout hangs on the
## client that receives it;
## [br]- repeated spaces and those at the ends;
## [br]- whatever exceeds [constant MAX_CODE_POINTS_PER_GRAPHEME] code points in a single grapheme
## (what is seen as one character): it bounds what attaches to the previous letter without being a
## mark, such as the Thai "ำ" (U+0E33) or the Lao one (U+0EB3), which at 128 in a row also hang the
## layout.
## [br][br]
## The categories come from the engine's Unicode tables (PCRE2 [RegEx] with [code]\p{…}[/code]),
## which are the same on client and server because both are the same binary. Cost is linear in the
## text length (no repeated passes per bracket nesting level) and almost everything runs in C++; a
## printable ASCII text with no brackets or extra spaces comes out immediately as is.
## [br][br]
## A text that is empty after sanitizing, or longer than [constant MAX_CHARS] characters, is not
## valid ([method check]). Shared: depends on neither the client nor the server.

## Maximum characters in a message.
const MAX_CHARS: int = 255
## Maximum UTF-8 bytes in a message (255 3-byte letters fit exactly).
const MAX_BYTES: int = 768
## Consecutive combining marks kept on the same letter (pointed and accented Hebrew or a Tibetan
## syllable use up to four); the rest are removed.
const MAX_MARKS_PER_BASE: int = 4
## Code points kept in a grapheme: the letter and its [constant MAX_MARKS_PER_BASE] marks. It also
## applies to what combines without being category M (Thai and Lao vowels, vowels and finals of
## old Hangul, skin tones).
const MAX_CODE_POINTS_PER_GRAPHEME: int = 1 + MAX_MARKS_PER_BASE

## Reason a text is not valid. [constant OK] is a usable text.
enum Problem { OK = 0, EMPTY = 1, TOO_LONG = 2 }

# Spaces (normal and Unicode), line breaks and the Braille blank, which collapse into a single one.
const _SPACES: Array[int] = [
	0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004,
	0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x2800, 0x3000,
]
const _OPEN_BRACKET: int = 0x5B
const _CLOSE_BRACKET: int = 0x5D

# What is already clean does not match: printable ASCII without brackets, with no spaces at the
# ends or doubled.
const _NEEDS_WORK_PATTERN: String = "[^\\x20-\\x5A\\x5C\\x5E-\\x7E]|^\\x20|\\x20$|\\x20\\x20"
# Spaces that are not the normal one (see _SPACES).
const _OTHER_SPACES_PATTERN: String = \
		"[\\x09-\\x0D\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{202F}\\x{205F}\\x{2800}\\x{3000}]"
# What is removed. It goes after replacing spaces, because the tab and line breaks are Cc.
const _STRIPPED_PATTERN: String = \
		"(?!\\x{FE0F})[\\p{Cc}\\p{Cf}\\p{Co}\\p{Cs}\\p{Cn}\\p{Zl}\\p{Zp}\\p{DI}\\x{FFFC}\\x{FFFD}]"
# Marks with no letter before them.
const _BASELESS_MARKS_PATTERN: String = "(^|\\x20)\\p{M}+"
# Excess consecutive marks (the number is set by MAX_MARKS_PER_BASE).
const _EXTRA_MARKS_PATTERN: String = "(\\p{M}{%d})\\p{M}+"
const _REPEATED_SPACES_PATTERN: String = "\\x20{2,}"
# Nothing that combines with what precedes it is below U+0300, so a grapheme of more than
# MAX_CODE_POINTS_PER_GRAPHEME code points has at least that many in a row above U+02FF: only
# then is the text walked grapheme by grapheme (Spanish with accents never gets there).
const _LONG_RUN_PATTERN: String = "[^\\x{0}-\\x{2FF}]{%d,}"
# A Unicode extended grapheme cluster (UAX #29).
const _GRAPHEME_PATTERN: String = "\\X"

static var _needs_work: RegEx = null
static var _other_spaces: RegEx = null
static var _stripped: RegEx = null
static var _baseless_marks: RegEx = null
static var _extra_marks: RegEx = null
static var _repeated_spaces: RegEx = null
static var _long_run: RegEx = null
static var _grapheme: RegEx = null


## Sanitized text of [param text]: without control or invisible characters, without BBCode, with
## bounded combining marks and with spaces fixed. Empty string if nothing is left or if it exceeds
## [constant MAX_CHARS] characters ([method check] says which of the two).
static func sanitize(text: String) -> String:
	var cleaned: String = clean(text)
	if cleaned.length() > MAX_CHARS:
		return ""
	return cleaned


## [constant Problem.OK] if [param text] is valid once sanitized, [constant Problem.EMPTY] if it is
## left empty and [constant Problem.TOO_LONG] if sanitizing exceeds [constant MAX_CHARS] characters.
static func check(text: String) -> int:
	var cleaned: String = clean(text)
	if cleaned.is_empty():
		return Problem.EMPTY
	if cleaned.length() > MAX_CHARS:
		return Problem.TOO_LONG
	return Problem.OK


## Message in Spanish, for the player, for a [enum Problem] (empty if it is [constant Problem.OK]).
static func problem_text(problem: int) -> String:
	match problem:
		Problem.EMPTY:
			return "El mensaje está vacío."
		Problem.TOO_LONG:
			return "El mensaje es demasiado largo (%d caracteres como máximo)." % MAX_CHARS
	return ""


## Like [method sanitize], but without checking the maximum length. It is idempotent: sanitizing
## twice gives the same as once.
static func clean(text: String) -> String:
	_ensure_patterns()
	if _needs_work.search(text) == null:
		return text
	var result: String = _other_spaces.sub(text, " ", true)
	result = _stripped.sub(result, "", true)
	result = _strip_markup(result)
	result = _baseless_marks.sub(result, "$1", true)
	result = _extra_marks.sub(result, "$1", true)
	return _cap_graphemes(_repeated_spaces.sub(result, " ", true).strip_edges())


## true if the character with code [param code] is treated as a space (normal, Unicode, a line
## break or the Braille blank).
static func is_space(code: int) -> bool:
	return _SPACES.has(code)


## true if the character with code [param code] is always removed when sanitizing: control,
## invisible, unassigned or private use (spaces and line breaks, which become a space, and
## combining marks, which are removed depending on where they are, do not count).
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
	_long_run = RegEx.create_from_string(_LONG_RUN_PATTERN % MAX_CODE_POINTS_PER_GRAPHEME)
	_grapheme = RegEx.create_from_string(_GRAPHEME_PATTERN)


# Removes what is between brackets and stray brackets, in a single pass: each "]" closes the last
# open "[" and takes everything between the two (inner pairs too); an unopened "]" is removed on
# its own, and for an unclosed "[" the bracket is removed and what follows it stays. It is the
# same as removing the innermost pair over and over until none is left, but linear.
static func _strip_markup(text: String) -> String:
	if not (text.contains("[") or text.contains("]")):
		return text
	var codes: PackedInt32Array = text.to_utf32_buffer().to_int32_array()
	var kept := PackedInt32Array()
	kept.resize(codes.size())
	var size: int = 0
	# Positions (in kept) of the still-open "[", from lowest to highest.
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
	# The only "[" left are those that were not closed (the closed ones left with their content).
	return kept.slice(0, size).to_byte_array().get_string_from_utf32().replace("[", "")


# Leaves each grapheme with its first MAX_CODE_POINTS_PER_GRAPHEME code points. It goes last: the
# previous steps do not lengthen any grapheme, so sanitizing twice still gives the same result.
static func _cap_graphemes(text: String) -> String:
	if _long_run.search(text) == null:
		return text
	var parts: PackedStringArray = PackedStringArray()
	for found: RegExMatch in _grapheme.search_all(text):
		parts.append(found.get_string().left(MAX_CODE_POINTS_PER_GRAPHEME))
	return "".join(parts)
