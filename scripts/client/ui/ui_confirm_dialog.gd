class_name UIConfirmDialog
extends Control
## Diálogo de confirmación modal (UI-09): un título, un mensaje y dos botones («Aceptar» y
## «Cancelar» por defecto) sobre un velo que atenúa y bloquea el resto de la pantalla. Emite
## [signal confirmed] o [signal canceled] y se cierra antes de emitir.
## [br][br]
## Esc cancela; los botones son enfocables y se recorren con izquierda y derecha ([UIFocus]); el foco
## no sale del diálogo. Para acciones destructivas ([param danger]) el botón de confirmar usa el estilo
## de peligro y el foco empieza en «Cancelar» (por defecto: un Intro de más no destruye nada).
## Suena por [UISounds] al abrirse, al confirmar y al cancelar.
## [br][br]
## Como las ventanas ([UIWindow]), libera el cursor mientras está abierto si se la enlaza con
## [method bind_camera].
## [br][br]
## Solo cliente.

## El jugador confirmó.
signal confirmed
## El jugador canceló (botón, Esc o [method cancel]).
signal canceled

const DEFAULT_CONFIRM_TEXT: String = "Aceptar"
const DEFAULT_CANCEL_TEXT: String = "Cancelar"
const MIN_WIDTH: float = 380.0

var _open: bool = false
var _camera_rig: CameraRig = null
var _title: Label = null
var _message: Label = null
var _confirm_button: Button = null
var _cancel_button: Button = null
var _focus_cancel: bool = true


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim: ColorRect = ColorRect.new()
	dim.name = "Dim"
	dim.color = UIPalette.MODAL_DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel: PanelContainer = PanelContainer.new()
	panel.name = "Panel"
	panel.theme_type_variation = &"WindowPanel"
	panel.custom_minimum_size = Vector2(MIN_WIDTH, 0.0)
	center.add_child(panel)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 14)
	panel.add_child(column)
	_title = Label.new()
	_title.theme_type_variation = &"HeaderLabel"
	column.add_child(_title)
	_message = Label.new()
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_message)
	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override(&"separation", 10)
	column.add_child(buttons)
	_cancel_button = Button.new()
	_cancel_button.focus_mode = Control.FOCUS_ALL
	_cancel_button.pressed.connect(cancel)
	buttons.add_child(_cancel_button)
	_confirm_button = Button.new()
	_confirm_button.focus_mode = Control.FOCUS_ALL
	_confirm_button.pressed.connect(confirm)
	buttons.add_child(_confirm_button)
	# El foco se queda dentro: izquierda y derecha cambian de botón y arriba y abajo no salen.
	var pair: Array[Control] = [_cancel_button, _confirm_button]
	UIFocus.chain_horizontal(pair)
	for button: Button in [_cancel_button, _confirm_button]:
		button.focus_neighbor_top = button.get_path_to(button)
		button.focus_neighbor_bottom = button.get_path_to(button)


func _exit_tree() -> void:
	if _open and is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)


func _input(event: InputEvent) -> void:
	if _open and event.is_action_pressed(&"ui_cancel"):
		cancel()
		get_viewport().set_input_as_handled()


## Abre el diálogo con [param title] y [param message]. [param danger] pone el botón de confirmar
## en el estilo de peligro y, con [param focus_cancel] (o siempre que sea peligroso), el foco empieza
## en «Cancelar».
func open(title: String, message: String, confirm_text: String = DEFAULT_CONFIRM_TEXT,
		cancel_text: String = DEFAULT_CANCEL_TEXT, danger: bool = false,
		focus_cancel: bool = true) -> void:
	_title.text = title
	_title.visible = not title.is_empty()
	_message.text = message
	_confirm_button.text = confirm_text
	_cancel_button.text = cancel_text
	_confirm_button.theme_type_variation = &"DangerButton" if danger else &""
	_focus_cancel = focus_cancel or danger
	var was_open: bool = _open
	_open = true
	visible = true
	if not was_open:
		if is_instance_valid(_camera_rig):
			_camera_rig.set_ui_cursor_release(true, self)
		UISounds.play(UISounds.OPEN)
	if is_inside_tree():
		(_cancel_button if _focus_cancel else _confirm_button).grab_focus()


## Enlaza el diálogo con la cámara: mientras está abierto el cursor queda libre.
func bind_camera(rig: CameraRig) -> void:
	if _open and is_instance_valid(_camera_rig) and _camera_rig != rig:
		_camera_rig.set_ui_cursor_release(false, self)
	_camera_rig = rig
	if _open and is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(true, self)


func is_open() -> bool:
	return _open


## El jugador confirma: cierra y emite [signal confirmed].
func confirm() -> void:
	if not _open:
		return
	_close()
	UISounds.play(UISounds.CONFIRM)
	confirmed.emit()


## El jugador cancela: cierra y emite [signal canceled].
func cancel() -> void:
	if not _open:
		return
	_close()
	UISounds.play(UISounds.CANCEL)
	canceled.emit()


func get_title_label() -> Label:
	return _title


func get_message_label() -> Label:
	return _message


func get_confirm_button() -> Button:
	return _confirm_button


func get_cancel_button() -> Button:
	return _cancel_button


func _close() -> void:
	_open = false
	visible = false
	if is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)
