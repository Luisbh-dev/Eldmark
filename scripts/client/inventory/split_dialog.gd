class_name SplitDialog
extends Control
## Diálogo de cantidad para dividir una pila (docs/progresion.md §11.2, UI-26): Mayúsculas + arrastrar abre este
## diálogo con un selector de 1 a la pila − 1 (por defecto, la mitad) y dos botones. Emite
## [signal confirmed] con la cantidad elegida o [signal canceled], y se cierra antes de emitir. Es modal, como
## [UIConfirmDialog]: un velo atenúa y bloquea el resto de la pantalla, Esc cancela e Intro en el selector
## confirma. Con [method bind_camera] libera el cursor mientras está abierto.
## [br][br]
## Solo cliente.

## El jugador eligió [param amount] unidades.
signal confirmed(amount: int)
## El jugador canceló (botón, Esc o [method cancel]).
signal canceled

const TITLE_TEXT: String = "Dividir pila"
const MESSAGE_TEXT: String = "¿Cuántas separas de %s ×%d?"
const CONFIRM_TEXT: String = "Dividir"
const CANCEL_TEXT: String = "Cancelar"
const MIN_WIDTH: float = 340.0

var _open: bool = false
var _camera_rig: CameraRig = null
var _title: Label = null
var _message: Label = null
var _spin: SpinBox = null
var _confirm_button: Button = null
var _cancel_button: Button = null


## La cantidad que propone el diálogo para una pila de [param stack]: la mitad hacia abajo, al menos 1.
static func default_amount(stack: int) -> int:
	return maxi(stack / 2, 1)


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = UIPalette.MODAL_DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.theme_type_variation = &"WindowPanel"
	panel.custom_minimum_size = Vector2(MIN_WIDTH, 0.0)
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 14)
	panel.add_child(column)
	_title = Label.new()
	_title.theme_type_variation = &"HeaderLabel"
	_title.text = TITLE_TEXT
	column.add_child(_title)
	_message = Label.new()
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_message)
	_spin = SpinBox.new()
	_spin.name = "Cantidad"
	_spin.step = 1.0
	_spin.rounded = true
	_spin.select_all_on_focus = true
	# Lo escrito cuenta al momento (sin esperar a Intro ni a perder el foco).
	_spin.update_on_text_changed = true
	_spin.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_spin.custom_minimum_size = Vector2(140.0, 0.0)
	_spin.get_line_edit().text_submitted.connect(func(_text: String) -> void: confirm())
	column.add_child(_spin)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override(&"separation", 10)
	column.add_child(buttons)
	_cancel_button = Button.new()
	_cancel_button.text = CANCEL_TEXT
	_cancel_button.pressed.connect(cancel)
	buttons.add_child(_cancel_button)
	_confirm_button = Button.new()
	_confirm_button.text = CONFIRM_TEXT
	_confirm_button.pressed.connect(confirm)
	buttons.add_child(_confirm_button)


func _exit_tree() -> void:
	if _open and is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)


func _input(event: InputEvent) -> void:
	if _open and event.is_action_pressed(&"ui_cancel"):
		cancel()
		get_viewport().set_input_as_handled()


## Abre el diálogo para la pila [param item_name] de [param stack] unidades (al menos 2): el selector va de 1 a
## [param stack] − 1 y empieza en la mitad.
func open(item_name: String, stack: int) -> void:
	var top: int = maxi(stack - 1, 1)
	_message.text = MESSAGE_TEXT % [item_name, stack]
	_spin.min_value = 1.0
	_spin.max_value = float(top)
	_spin.value = float(mini(default_amount(stack), top))
	var was_open: bool = _open
	_open = true
	visible = true
	if not was_open:
		if is_instance_valid(_camera_rig):
			_camera_rig.set_ui_cursor_release(true, self)
		UISounds.play(UISounds.OPEN)
	if is_inside_tree():
		_spin.get_line_edit().grab_focus()


## Enlaza el diálogo con la cámara: mientras está abierto el cursor queda libre.
func bind_camera(rig: CameraRig) -> void:
	if _open and is_instance_valid(_camera_rig) and _camera_rig != rig:
		_camera_rig.set_ui_cursor_release(false, self)
	_camera_rig = rig
	if _open and is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(true, self)


func is_open() -> bool:
	return _open


## La cantidad elegida ahora.
func get_amount() -> int:
	return int(_spin.value)


## Elige [param amount] (se recorta al rango).
func set_amount(amount: int) -> void:
	_spin.value = float(amount)


func get_spin_box() -> SpinBox:
	return _spin


func get_message_label() -> Label:
	return _message


func get_confirm_button() -> Button:
	return _confirm_button


func get_cancel_button() -> Button:
	return _cancel_button


## Confirma: cierra y emite [signal confirmed] con la cantidad elegida.
func confirm() -> void:
	if not _open:
		return
	var amount: int = get_amount()
	_close()
	UISounds.play(UISounds.CONFIRM)
	confirmed.emit(amount)


## Cancela: cierra y emite [signal canceled].
func cancel() -> void:
	if not _open:
		return
	_close()
	UISounds.play(UISounds.CANCEL)
	canceled.emit()


func _close() -> void:
	_open = false
	visible = false
	if is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)
