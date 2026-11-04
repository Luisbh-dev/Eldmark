class_name UIHintBar
extends HBoxContainer
## Controls help line (UI-09): a row of "key + text" pairs with the real glyph of each action
## ([UIKeyGlyph]) instead of fixed text. The HUD uses it at the bottom of the screen.
## [br][br]
## Each hint is a dictionary [code]{"action": StringName, "text": String}[/code] and, optionally,
## [code]"glyph"[/code], a text that replaces the action's glyph ("Rueda" (Wheel) for zoom, which is two
## actions). [method set_hints] rebuilds the row; [method refresh] only rereads the keys
## ([method UIKeyGlyph.refresh_all] also reaches them).
## [br][br]
## Client only.

## HUD hints: the keys of the sandbox and of the networked client. Without "Soltar ratón" (Release mouse)
## (Esc) or "Depuración" (Debug) (F3): the line no longer exceeds a dozen shortcuts (UI-49).
const DEFAULT_HINTS: Array[Dictionary] = [
	{"action": &"free_cursor", "text": "Liberar cursor"},
	{"action": &"shoulder_swap", "text": "Cambiar hombro"},
	{"action": &"zoom_in", "text": "Zoom", "glyph": "Rueda"},
	{"action": &"open_settings", "text": "Ajustes"},
]
const SEPARATOR_TEXT: String = "·"

var _hints: Array[Dictionary] = []
var _glyphs: Array[UIKeyGlyph] = []
var _texts: Array[Label] = []


func _ready() -> void:
	alignment = BoxContainer.ALIGNMENT_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override(&"separation", 8)
	if _hints.is_empty():
		set_hints(DEFAULT_HINTS)


## Rebuilds the row with [param hints] (see the class documentation).
func set_hints(hints: Array[Dictionary]) -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	_glyphs.clear()
	_texts.clear()
	_hints = hints.duplicate()
	for index: int in _hints.size():
		var hint: Dictionary = _hints[index]
		if index > 0:
			add_child(_make_label(SEPARATOR_TEXT))
		var glyph: UIKeyGlyph = UIKeyGlyph.new()
		glyph.compact = true
		glyph.text_override = String(hint.get("glyph", ""))
		glyph.action = hint.get("action", &"")
		glyph.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		add_child(glyph)
		_glyphs.append(glyph)
		var label: Label = _make_label(String(hint.get("text", "")))
		add_child(label)
		_texts.append(label)


## Rereads the assigned keys.
func refresh() -> void:
	for glyph: UIKeyGlyph in _glyphs:
		glyph.refresh()


## Number of hints.
func get_hint_count() -> int:
	return _hints.size()


## Glyphs of the row, in order.
func get_glyphs() -> Array[UIKeyGlyph]:
	return _glyphs


## The row as plain text ("Alt: Liberar cursor · Esc: Soltar ratón..." (Alt: Free cursor · Esc: Release
## mouse...)), for tests and screen readers.
func get_plain_text() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for index: int in _glyphs.size():
		parts.append("%s: %s" % [_glyphs[index].get_label(), _texts[index].text])
	return " · ".join(parts)


func _make_label(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.theme_type_variation = &"HintLabel"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
