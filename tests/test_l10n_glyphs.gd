extends TestCase
## Glyph coverage of the interface fonts for the localized texts (docs/localization.md section 4.8).
## [br][br]
## Noto Sans (body), Cinzel (titles) and IM Fell English SC (map) must have every character of the Spanish
## catalog ([code]locale/es.po[/code], msgids and translations) and every character the pseudolocalization
## can produce; a text with a missing glyph would draw as a box. The fonts are loaded through [UIFonts], like
## the game does. A few symbols the client draws today are missing from the fonts whatever the language
## ([constant KNOWN_MISSING]); they stay on that documented list until they become icons (UI-39), and
## a test keeps the list honest.

const CATALOG_PATH: String = "res://locale/es.po"
## Symbols the client draws that these fonts lack, with where they are used. Not in the catalog: they come
## from code. UI-39 replaces them with icons and empties this list.
const KNOWN_MISSING: Dictionary = {
	"←": "UIKeyGlyph (arrow keys)", "↑": "UIKeyGlyph (arrow keys)", "→": "UIKeyGlyph (arrow keys)",
	"↓": "UIKeyGlyph (arrow keys)", "▶": "character_create.gd (appearance arrows)",
	"◀": "character_create.gd (appearance arrows)", "✕": "ui_window.gd (close button)",
}
## Characters of the extra punctuation every font is expected to cover, besides Latin-1.
const EXPECTED_PUNCTUATION: String = "‹›“”‘’…·×–—"


func _fonts() -> Dictionary:
	return {"body": UIFonts.body(), "title": UIFonts.title(), "map": UIFonts.map_label()}


# Every character used by the msgids and msgstrs of [param path], without escapes.
func _catalog_characters(path: String) -> Dictionary:
	var found: Dictionary = {}
	var in_text: bool = false
	for raw_line: String in FileAccess.get_file_as_string(path).split("\n"):
		var line: String = raw_line.strip_edges()
		var is_entry: bool = line.begins_with("msgid") or line.begins_with("msgstr") \
				or line.begins_with("msgid_plural")
		if not is_entry and not (in_text and line.begins_with("\"")):
			in_text = false
			continue
		in_text = true
		var first: int = line.find("\"")
		var last: int = line.rfind("\"")
		if first < 0 or last <= first:
			continue
		var text: String = line.substr(first + 1, last - first - 1)
		text = text.replace("\\n", "").replace("\\t", "").replace("\\\"", "\"").replace("\\\\", "\\")
		for i: int in text.length():
			found[text.unicode_at(i)] = true
	return found


func test_every_font_covers_latin_1_and_the_extra_punctuation() -> void:
	for font_name: String in _fonts():
		var font: Font = _fonts()[font_name]
		var missing: PackedStringArray = PackedStringArray()
		for code: int in range(0x20, 0x7F):
			if not font.has_char(code):
				missing.append("U+%04X" % code)
		for code: int in range(0xA1, 0x100):
			if not font.has_char(code):
				missing.append("U+%04X" % code)
		for i: int in EXPECTED_PUNCTUATION.length():
			if not font.has_char(EXPECTED_PUNCTUATION.unicode_at(i)):
				missing.append("U+%04X" % EXPECTED_PUNCTUATION.unicode_at(i))
		assert_true(missing.is_empty(), "%s is missing %s" % [font_name, ", ".join(missing)])


func test_the_spanish_catalog_only_uses_characters_the_fonts_have() -> void:
	var characters: Dictionary = _catalog_characters(CATALOG_PATH)
	assert_true(characters.size() > 40, "the catalog was read (%d distinct characters)" % characters.size())
	for font_name: String in _fonts():
		var font: Font = _fonts()[font_name]
		for code: int in characters:
			if code < 0x20:
				continue
			assert_true(font.has_char(code), "%s has no glyph for \"%s\" (U+%04X) used in %s" % [
					font_name, char(code), code, CATALOG_PATH])


func test_the_pseudolocalization_alphabet_is_covered() -> void:
	var characters: Array[int] = [L10n.PSEUDO_OPEN.unicode_at(0), L10n.PSEUDO_CLOSE.unicode_at(0),
			L10n.PSEUDO_FILL.unicode_at(0)]
	for letter: String in L10n.PSEUDO_MAP.values():
		characters.append(letter.unicode_at(0))
	for font_name: String in _fonts():
		var font: Font = _fonts()[font_name]
		for code: int in characters:
			assert_true(font.has_char(code), "%s has no glyph for \"%s\" (U+%04X) of the pseudo alphabet" % [
					font_name, char(code), code])


func test_the_known_missing_symbols_are_still_missing() -> void:
	for symbol: String in KNOWN_MISSING:
		for font_name: String in _fonts():
			var font: Font = _fonts()[font_name]
			assert_false(font.has_char(symbol.unicode_at(0)),
					"%s now has \"%s\" (%s): take it off KNOWN_MISSING" % [font_name, symbol, KNOWN_MISSING[symbol]])
	assert_false(UIFonts.map_label().has_char(0x2212), "the map font has no minus sign (U+2212)")


func test_no_catalog_text_uses_a_known_missing_symbol() -> void:
	var characters: Dictionary = _catalog_characters(CATALOG_PATH)
	for symbol: String in KNOWN_MISSING:
		assert_false(characters.has(symbol.unicode_at(0)), "the catalog uses %s, which the fonts lack" % symbol)
