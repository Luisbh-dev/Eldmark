class_name FrontScreen
extends Control
## Base de las pantallas de la cuenta de [FrontMain] (docs/plataforma.md §13.2): ocupan la pantalla entera sobre un
## fondo oscuro, con el aviso de arriba ([method set_notice]) y el estado «ocupado» ([method set_busy]) que
## desactiva los controles mientras vuela una llamada a la plataforma. Los controles se construyen en código, como
## [UIWindow] y [TemplateSelector]; su escena en [code]scenes/ui/[/code] es solo la raíz con el script. Lo visual es
## provisional (UI-02: tema, [code]WindowPanel[/code]; el fondo, el logotipo y la música son de ART-21).
## [br][br]
## Las pantallas no llaman a la red: emiten señales y [FrontMain] habla con la plataforma y les devuelve el
## resultado. Así se prueban con datos falsos. Solo cliente.

const BACKGROUND_COLOR: Color = Color(0.04, 0.045, 0.06, 1.0)
const PANEL_MIN_WIDTH: float = 560.0
const ROW_SEPARATION: int = 12
const LABEL_WIDTH: float = 150.0
const BUTTON_HEIGHT: float = 44.0

var _notice_label: Label = null
var _busy: bool = false
# Controles que se desactivan mientras vuela una llamada (los demás se quedan como estén).
var _busy_controls: Array[Control] = []


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var background := ColorRect.new()
	background.name = "Fondo"
	background.color = BACKGROUND_COLOR
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)


## Muestra [param text] en el aviso (como error con [param is_error]; si no, como información). Vacío lo quita.
func set_notice(text: String, is_error: bool = true) -> void:
	if _notice_label == null:
		return
	_notice_label.text = text
	_notice_label.visible = not text.is_empty()
	_notice_label.theme_type_variation = &"ErrorLabel" if is_error else &"WarningLabel"


## El texto del aviso.
func get_notice_text() -> String:
	return _notice_label.text if _notice_label != null else ""


## Desactiva (o vuelve a activar) los controles mientras vuela una llamada.
func set_busy(busy: bool) -> void:
	_busy = busy
	_refresh_state()


func is_busy() -> bool:
	return _busy


# Cada pantalla recalcula aquí qué botones se pueden pulsar (llamado también al cambiar el estado «ocupado»).
func _refresh_state() -> void:
	for control: Control in _busy_controls:
		if control is BaseButton:
			(control as BaseButton).disabled = _busy
		elif control is LineEdit:
			(control as LineEdit).editable = not _busy


# Un panel centrado con su columna y el aviso arriba. Devuelve la columna.
func _make_panel(title_text: String, min_width: float = PANEL_MIN_WIDTH) -> VBoxContainer:
	var center := CenterContainer.new()
	center.name = "Centro"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.theme_type_variation = &"WindowPanel"
	panel.custom_minimum_size = Vector2(min_width, 0.0)
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.name = "Columna"
	column.add_theme_constant_override(&"separation", ROW_SEPARATION)
	panel.add_child(column)
	if not title_text.is_empty():
		column.add_child(make_label(title_text, &"HeaderLabel"))
	_notice_label = make_label("", &"ErrorLabel")
	_notice_label.name = "Aviso"
	_notice_label.visible = false
	_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_notice_label)
	return column


## Una etiqueta con la variación de tema [param variation].
static func make_label(text: String, variation: StringName = &"") -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = variation
	return label


## Un botón de al menos [param min_width] de ancho.
static func make_button(text: String, min_width: float = 140.0, variation: StringName = &"") -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(min_width, BUTTON_HEIGHT)
	button.theme_type_variation = variation
	return button


## Un campo de texto ([param secret] para contraseñas).
static func make_line_edit(placeholder: String, secret: bool = false, max_length: int = 254) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.secret = secret
	edit.max_length = max_length
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.select_all_on_focus = true
	return edit


## Una fila «etiqueta: control» dentro de [param parent].
static func add_row(parent: Control, label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", ROW_SEPARATION)
	var label := make_label(label_text)
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	parent.add_child(row)
	return row


## Una fila de botones que se reparten el ancho, con un hueco entre [param left] y [param right].
static func add_button_row(parent: Control, left: Array[Button], right: Array[Button]) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", ROW_SEPARATION)
	for button: Button in left:
		row.add_child(button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	for button: Button in right:
		row.add_child(button)
	parent.add_child(row)
	return row
