class_name RenameDialog
extends Control
## Forced rename (docs/platform.md §4.4, §9.5 and §13.2): when [code]enter[/code] responds
## [code]rename_required[/code] (a moderation sanction), a modal dialog asks for the new name, validated
## with [NameRules] as it is typed. "Cambiar" (Change) emits [signal rename_requested]; the platform
## responds and [FrontMain] closes the dialog or shows the reason ([method set_error]). The old name stays
## reserved for 30 days. Esc cancels. Client only.

## Pressed "Cambiar" (Change) with a valid name.
signal rename_requested(character_id: int, display_name: String)
## Canceled (button or Esc).
signal canceled

const TEXT_TITLE: String = "Cambia el nombre de tu personaje"
const TEXT_HELP: String = "La moderación ha pedido que «%s» cambie de nombre antes de volver a entrar."

var _help: Label = null
var _edit: LineEdit = null
var _reason: Label = null
var _confirm: Button = null
var _cancel: Button = null
var _character_id: int = 0
var _busy: bool = false


func _init() -> void:
	name = "RenameDialog"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = UIPalette.MODAL_DIM
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"WindowPanel"
	panel.custom_minimum_size = Vector2(460.0, 0.0)
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", FrontScreen.ROW_SEPARATION)
	panel.add_child(column)
	column.add_child(FrontScreen.make_label(TEXT_TITLE, &"HeaderLabel"))
	_help = FrontScreen.make_label("", &"DimLabel")
	_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_help)
	_edit = FrontScreen.make_line_edit("nombre nuevo", false, 32)
	_edit.name = "Nombre"
	column.add_child(_edit)
	_reason = FrontScreen.make_label("", &"ErrorLabel")
	_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_reason)
	_cancel = FrontScreen.make_button("Cancelar", 120.0, &"GhostButton")
	_confirm = FrontScreen.make_button("Cambiar", 160.0)
	_confirm.name = "Cambiar"
	FrontScreen.add_button_row(column, [_cancel], [_confirm])
	_edit.text_changed.connect(func(_text: String) -> void: _refresh())
	_edit.text_submitted.connect(func(_text: String) -> void: try_rename())
	_confirm.pressed.connect(try_rename)
	_cancel.pressed.connect(cancel)


func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		cancel()
		get_viewport().set_input_as_handled()


## Opens the dialog for character [param character_id], which is currently named [param current_name].
func open(character_id: int, current_name: String) -> void:
	_character_id = character_id
	_help.text = TEXT_HELP % current_name
	_edit.text = ""
	_busy = false
	visible = true
	_refresh()
	if is_inside_tree():
		_edit.grab_focus()


func close() -> void:
	visible = false
	_busy = false


func is_open() -> bool:
	return visible


func get_character_id() -> int:
	return _character_id


## Shows the reason the platform did not accept the name (and allows trying again).
func set_error(text: String) -> void:
	_busy = false
	_reason.text = text
	_confirm.disabled = not NameRules.is_valid(_edit.text.strip_edges())


func set_busy(busy: bool) -> void:
	_busy = busy
	_refresh()


## Emits [signal rename_requested] if the name is valid. Returns true if it emitted it.
func try_rename() -> bool:
	var display_name: String = _edit.text.strip_edges()
	if not visible or _busy or not NameRules.is_valid(display_name):
		return false
	rename_requested.emit(_character_id, display_name)
	return true


func cancel() -> void:
	if not visible:
		return
	close()
	canceled.emit()


func get_name_edit() -> LineEdit:
	return _edit


func get_reason_text() -> String:
	return _reason.text


func get_confirm_button() -> Button:
	return _confirm


func _refresh() -> void:
	var display_name: String = _edit.text.strip_edges()
	var reason: int = NameRules.validate(display_name)
	_reason.text = "" if display_name.is_empty() or reason == NameRules.Reason.OK else NameRules.reason_text(reason)
	_confirm.disabled = _busy or reason != NameRules.Reason.OK
