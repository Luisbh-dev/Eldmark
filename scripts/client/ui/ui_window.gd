class_name UIWindow
extends PanelContainer
## Ventana de la interfaz (UI-09): un panel con barra de título, botón de cerrar y una columna de
## contenido ([method get_content]) que se abre y se cierra ([method open], [method close],
## [method toggle]). Es la base de los ajustes ([SettingsMenu]) y de las demás ventanas.
## [br][br]
## [b]Cursor.[/b] Mientras está abierta el ratón tiene que estar libre: [method bind_camera] la
## enlaza con la [CameraRig], que libera el cursor al abrirla y lo recaptura al cerrarla (como hace
## la pantalla de muerte). Hasta que exista el gestor de ventanas (UI-03), cada ventana lo hace así.
## [br][br]
## [b]Esc[/b] la cierra (se atiende en [method Node._input], antes de que lo vea la cámara, para que
## Esc cierre la ventana en lugar de alternar el cursor), salvo con [member close_on_cancel] a false.
## Abrirla da el foco al primer control enfocable del contenido, así se maneja con teclado o mando.
## [br][br]
## Los nodos se crean en [method _init]: se puede llenar el contenido antes de añadirla al árbol.
## Empieza cerrada (oculta). Con [member centered] se centra sola en su padre.
## [br][br]
## Solo cliente.

## Se abrió o se cerró.
signal opened
signal closed

const CLOSE_TEXT: String = "✕"

## Título de la barra.
var window_title: String = "":
	set(value):
		window_title = value
		if _title_label != null:
			_title_label.text = value
## Si es true (por defecto), Esc la cierra.
var close_on_cancel: bool = true
## Si es true (por defecto), se centra en su padre al entrar en el árbol.
var centered: bool = true

var _open: bool = false
var _camera_rig: CameraRig = null
var _title_label: Label = null
var _close_button: Button = null
var _content: VBoxContainer = null


func _init() -> void:
	theme_type_variation = &"WindowPanel"
	visible = false
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 10)
	add_child(column)
	var header: HBoxContainer = HBoxContainer.new()
	column.add_child(header)
	_title_label = Label.new()
	_title_label.theme_type_variation = &"HeaderLabel"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.text = window_title
	header.add_child(_title_label)
	_close_button = Button.new()
	_close_button.theme_type_variation = &"GhostButton"
	_close_button.text = CLOSE_TEXT
	_close_button.focus_mode = Control.FOCUS_NONE
	_close_button.pressed.connect(close)
	header.add_child(_close_button)
	column.add_child(HSeparator.new())
	_content = VBoxContainer.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override(&"separation", 8)
	column.add_child(_content)


func _ready() -> void:
	if centered:
		grow_horizontal = Control.GROW_DIRECTION_BOTH
		grow_vertical = Control.GROW_DIRECTION_BOTH
		set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)


func _exit_tree() -> void:
	# Que el cursor no se quede suelto si la ventana desaparece abierta.
	if _open and is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)


func _input(event: InputEvent) -> void:
	if _open and close_on_cancel and event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


## La columna donde se pone el contenido de la ventana.
func get_content() -> VBoxContainer:
	return _content


## El botón de cerrar de la barra.
func get_close_button() -> Button:
	return _close_button


## Enlaza la ventana con la cámara: abrirla libera el cursor y cerrarla lo devuelve.
func bind_camera(rig: CameraRig) -> void:
	if _open and is_instance_valid(_camera_rig) and _camera_rig != rig:
		_camera_rig.set_ui_cursor_release(false, self)
	_camera_rig = rig
	if _open and is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(true, self)


func is_open() -> bool:
	return _open


## Abre la ventana (si no lo estaba): la muestra, libera el cursor, suena y enfoca su contenido.
func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	if is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(true, self)
	UISounds.play(UISounds.OPEN)
	UIFocus.focus_first(_content)
	opened.emit()


## Cierra la ventana (si estaba abierta).
func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	if is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)
	UISounds.play(UISounds.CLOSE)
	closed.emit()


func toggle() -> void:
	if _open:
		close()
	else:
		open()
