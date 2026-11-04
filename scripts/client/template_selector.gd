class_name TemplateSelector
extends VBoxContainer
## Loadout template selector (PRG-07, docs/habilidades.md, section 6.5): one button for each
## [EquipmentTemplate] the player can choose ([member EquipmentTemplate.selectable]) with its name, its
## weapons and its potion charges. It is on the death screen and the realm selection; pressing one emits
## [signal template_chosen] and whoever holds it sends the LOADOUT_SELECT
## ([method NetClient.send_loadout_select]) or stores it for when it connects
## ([member ClientConfig.loadout]). The template takes effect at the next spawn: the selector promises no
## more than that.
## [br][br]
## The ids come from the combat catalog in the order of their ids (by name: they are never fixed). Client
## only.

## The player has chosen template [param template_id] (combat catalog id).
signal template_chosen(template_id: int)

const BUTTON_MIN_WIDTH: float = 200.0
const TITLE_FONT_SIZE: int = 18
const NOTE_FONT_SIZE: int = 14
const NOTE_COLOR: Color = Color(0.78, 0.8, 0.86, 1.0)

var _title: Label = null
var _row: HBoxContainer = null
var _note: Label = null
var _group: ButtonGroup = ButtonGroup.new()
# template id -> its button.
var _buttons: Dictionary[int, Button] = {}
var _selected: int = 0


func _init() -> void:
	name = "Plantillas"
	add_theme_constant_override(&"separation", 6)
	_build()


## Ids of the templates on offer, in button order.
func get_template_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for id: int in _buttons:
		ids.append(id)
	return ids


## Selected template (0 if none: the default one).
func get_selected() -> int:
	return _selected


## Selects [param template_id] without emitting anything (0 or one that is not offered: the catalog's
## default, if it is offered).
func select(template_id: int) -> void:
	var id: int = template_id if _buttons.has(template_id) else CombatCatalog.default_template_id()
	_selected = id if _buttons.has(id) else 0
	for key: int in _buttons:
		_buttons[key].set_pressed_no_signal(key == _selected)


## Like pressing the button of [param template_id]: selects it and emits [signal template_chosen]. Returns
## false if it is not offered.
func choose(template_id: int) -> bool:
	if not _buttons.has(template_id):
		return false
	select(template_id)
	template_chosen.emit(template_id)
	return true


## The button of [param template_id] (null if it is not offered).
func get_button(template_id: int) -> Button:
	return _buttons.get(template_id)


## With [param focusable] false, the buttons do not take focus even on a click (the death screen, which is
## operated with the mouse and leaves Tab and Enter for the game); by default they take it, for keyboard
## navigation.
func set_buttons_focusable(focusable: bool) -> void:
	for button: Button in _buttons.values():
		button.focus_mode = Control.FOCUS_ALL if focusable else Control.FOCUS_NONE


func _build() -> void:
	_title = Label.new()
	_title.name = "Titulo"
	_title.text = CombatText.TEXT_TEMPLATE_TITLE
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override(&"font_size", TITLE_FONT_SIZE)
	add_child(_title)
	_row = HBoxContainer.new()
	_row.name = "Botones"
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.add_theme_constant_override(&"separation", 10)
	add_child(_row)
	for id: int in range(1, CombatCatalog.template_count() + 1):
		var template: EquipmentTemplate = CombatCatalog.template(id)
		if template == null or not template.selectable:
			continue
		var button := Button.new()
		button.name = String(template.id).capitalize().replace(" ", "")
		button.toggle_mode = true
		button.button_group = _group
		button.custom_minimum_size = Vector2(BUTTON_MIN_WIDTH, 0.0)
		button.text = "%s\n%s" % [CombatText.template_title(id), CombatText.template_summary(id)]
		button.tooltip_text = CombatText.template_summary(id)
		button.pressed.connect(_on_pressed.bind(id))
		_row.add_child(button)
		_buttons[id] = button
	_note = Label.new()
	_note.name = "Nota"
	_note.text = CombatText.TEXT_TEMPLATE_PENDING
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.add_theme_font_size_override(&"font_size", NOTE_FONT_SIZE)
	_note.add_theme_color_override(&"font_color", NOTE_COLOR)
	add_child(_note)
	select(CombatCatalog.default_template_id())


func _on_pressed(template_id: int) -> void:
	_selected = template_id
	template_chosen.emit(template_id)
