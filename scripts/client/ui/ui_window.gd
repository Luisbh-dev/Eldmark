class_name UIWindow
extends PanelContainer
## UI window (UI-09): a panel with a title bar, a close button and a content column
## ([method get_content]) that opens and closes ([method open], [method close], [method toggle]). It is the
## base of the settings ([SettingsMenu]) and of the other windows.
## [br][br]
## [b]Cursor.[/b] While open, the mouse must be free: [method bind_camera] binds it to the [CameraRig],
## which frees the cursor when it opens and recaptures it when it closes (as the death screen does). Until
## the window manager exists (UI-03), each window does it this way.
## [br][br]
## [b]Esc[/b] closes it (handled in [method Node._input], before the camera sees it, so that Esc closes the
## window instead of toggling the cursor), unless [member close_on_cancel] is false. Opening it gives focus
## to the first focusable control of the content, so it can be operated with keyboard or gamepad.
## [br][br]
## The nodes are created in [method _init]: the content can be filled in before adding it to the tree. It
## starts closed (hidden). With [member centered] it centers itself in its parent.
## [br][br]
## Client only.

## It was opened or closed.
signal opened
signal closed

const CLOSE_TEXT: String = "✕"

## Title of the bar.
var window_title: String = "":
	set(value):
		window_title = value
		if _title_label != null:
			_title_label.text = value
## If true (the default), Esc closes it.
var close_on_cancel: bool = true
## If true (the default), it centers itself in its parent when entering the tree.
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
	# So the cursor does not stay loose if the window disappears while open.
	if _open and is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)


func _input(event: InputEvent) -> void:
	if _open and close_on_cancel and event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


## The column where the window's content goes.
func get_content() -> VBoxContainer:
	return _content


## The bar's close button.
func get_close_button() -> Button:
	return _close_button


## Binds the window to the camera: opening it frees the cursor and closing it returns it.
func bind_camera(rig: CameraRig) -> void:
	if _open and is_instance_valid(_camera_rig) and _camera_rig != rig:
		_camera_rig.set_ui_cursor_release(false, self)
	_camera_rig = rig
	if _open and is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(true, self)


func is_open() -> bool:
	return _open


## Opens the window (if it was not open): shows it, frees the cursor, plays a sound and focuses its content.
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


## Closes the window (if it was open).
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
