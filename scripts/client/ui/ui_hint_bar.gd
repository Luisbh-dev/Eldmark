class_name UIHintBar
extends HBoxContainer
## Línea de ayuda de controles (UI-09): una fila de pares «tecla + texto» con el glifo real de cada
## acción ([UIKeyGlyph]) en lugar de texto fijo. La usa el HUD en la parte baja de la pantalla.
## [br][br]
## Cada pista es un diccionario [code]{"action": StringName, "text": String}[/code] y, opcionalmente,
## [code]"glyph"[/code], un texto que sustituye al glifo de la acción («Rueda» para el zoom, que son
## dos acciones). [method set_hints] reconstruye la fila; [method refresh] solo vuelve a leer las
## teclas ([method UIKeyGlyph.refresh_all] también las alcanza).
## [br][br]
## Solo cliente.

## Pistas del HUD: las teclas del sandbox y del cliente en red.
const DEFAULT_HINTS: Array[Dictionary] = [
	{"action": &"free_cursor", "text": "Liberar cursor"},
	{"action": &"toggle_cursor", "text": "Soltar ratón"},
	{"action": &"shoulder_swap", "text": "Cambiar hombro"},
	{"action": &"zoom_in", "text": "Zoom", "glyph": "Rueda"},
	{"action": &"toggle_debug", "text": "Depuración"},
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


## Rehace la fila con [param hints] (ver la documentación de la clase).
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


## Vuelve a leer las teclas asignadas.
func refresh() -> void:
	for glyph: UIKeyGlyph in _glyphs:
		glyph.refresh()


## Número de pistas.
func get_hint_count() -> int:
	return _hints.size()


## Glifos de la fila, en orden.
func get_glyphs() -> Array[UIKeyGlyph]:
	return _glyphs


## La fila como texto plano («Alt: Liberar cursor · Esc: Soltar ratón...»), para pruebas y
## lectores de pantalla.
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
