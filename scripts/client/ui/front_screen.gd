class_name FrontScreen
extends Control
## Base of the account screens of [FrontMain] (docs/plataforma.md §13.2): they fill the whole screen over a
## dark background, with the notice at the top ([method set_notice]) and the "busy" state
## ([method set_busy]) that disables the controls while a call to the platform is in flight. The controls
## are built in code, like [UIWindow] and [TemplateSelector]; their scene in [code]scenes/ui/[/code] is
## just the root with the script. The visuals are provisional (UI-02: theme, [code]WindowPanel[/code]; the
## background, logo and music belong to ART-21).
## [br][br]
## The screens do not call the network: they emit signals and [FrontMain] talks to the platform and
## returns the result to them. This way they are tested with fake data. Client only.

const BACKGROUND_COLOR: Color = Color(0.04, 0.045, 0.06, 1.0)
const PANEL_MIN_WIDTH: float = 560.0
const ROW_SEPARATION: int = 12
const LABEL_WIDTH: float = 150.0
const BUTTON_HEIGHT: float = 44.0

var _notice_label: Label = null
var _busy: bool = false
# Controls that are disabled while a call is in flight (the others stay as they are).
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


## Shows [param text] in the notice (as an error with [param is_error]; otherwise, as information). Empty
## removes it.
func set_notice(text: String, is_error: bool = true) -> void:
	if _notice_label == null:
		return
	_notice_label.text = text
	_notice_label.visible = not text.is_empty()
	_notice_label.theme_type_variation = &"ErrorLabel" if is_error else &"WarningLabel"


## The notice text.
func get_notice_text() -> String:
	return _notice_label.text if _notice_label != null else ""


## Disables (or re-enables) the controls while a call is in flight.
func set_busy(busy: bool) -> void:
	_busy = busy
	_refresh_state()


func is_busy() -> bool:
	return _busy


# Each screen recomputes here which buttons can be pressed (also called when the "busy" state changes).
func _refresh_state() -> void:
	for control: Control in _busy_controls:
		if control is BaseButton:
			(control as BaseButton).disabled = _busy
		elif control is LineEdit:
			(control as LineEdit).editable = not _busy


# A centered panel with its column and the notice on top. Returns the column.
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


## A label with theme variation [param variation].
static func make_label(text: String, variation: StringName = &"") -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = variation
	return label


## A button at least [param min_width] wide.
static func make_button(text: String, min_width: float = 140.0, variation: StringName = &"") -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(min_width, BUTTON_HEIGHT)
	button.theme_type_variation = variation
	return button


## A text field ([param secret] for passwords).
static func make_line_edit(placeholder: String, secret: bool = false, max_length: int = 254) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.secret = secret
	edit.max_length = max_length
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.select_all_on_focus = true
	return edit


## A "label: control" row inside [param parent].
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


## A row of buttons that share the width, with a gap between [param left] and [param right].
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
