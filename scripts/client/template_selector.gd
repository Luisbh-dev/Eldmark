class_name TemplateSelector
extends VBoxContainer
## Selector de plantilla de equipo (PRG-07, docs/habilidades.md, sección 6.5): un botón por cada
## [EquipmentTemplate] que el jugador puede elegir ([member EquipmentTemplate.selectable]) con su nombre,
## sus armas y sus cargas de pociones. Está en la pantalla de muerte y en la elección de reino; al pulsar
## uno emite [signal template_chosen] y quien lo tiene manda el LOADOUT_SELECT
## ([method NetClient.send_loadout_select]) o lo guarda para cuando conecte
## ([member ClientConfig.loadout]). La plantilla vale en la siguiente aparición: el selector no promete más.
## [br][br]
## Los ids salen del catálogo de combate en el orden de sus ids (por nombre: nunca son fijos). Solo
## cliente.

## El jugador ha elegido la plantilla [param template_id] (id del catálogo de combate).
signal template_chosen(template_id: int)

const BUTTON_MIN_WIDTH: float = 200.0
const TITLE_FONT_SIZE: int = 18
const NOTE_FONT_SIZE: int = 14
const NOTE_COLOR: Color = Color(0.78, 0.8, 0.86, 1.0)

var _title: Label = null
var _row: HBoxContainer = null
var _note: Label = null
var _group: ButtonGroup = ButtonGroup.new()
# id de plantilla -> su botón.
var _buttons: Dictionary[int, Button] = {}
var _selected: int = 0


func _init() -> void:
	name = "Plantillas"
	add_theme_constant_override(&"separation", 6)
	_build()


## Ids de las plantillas que se ofrecen, en el orden de los botones.
func get_template_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for id: int in _buttons:
		ids.append(id)
	return ids


## Plantilla marcada (0 si ninguna: la de por defecto).
func get_selected() -> int:
	return _selected


## Marca [param template_id] sin emitir nada (0 o una que no se ofrece: la de por defecto del catálogo, si
## se ofrece).
func select(template_id: int) -> void:
	var id: int = template_id if _buttons.has(template_id) else CombatCatalog.default_template_id()
	_selected = id if _buttons.has(id) else 0
	for key: int in _buttons:
		_buttons[key].set_pressed_no_signal(key == _selected)


## Como pulsar el botón de [param template_id]: lo marca y emite [signal template_chosen]. Devuelve false
## si no se ofrece.
func choose(template_id: int) -> bool:
	if not _buttons.has(template_id):
		return false
	select(template_id)
	template_chosen.emit(template_id)
	return true


## El botón de [param template_id] (null si no se ofrece).
func get_button(template_id: int) -> Button:
	return _buttons.get(template_id)


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
