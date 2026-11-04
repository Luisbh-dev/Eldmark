class_name TitleScreen
extends FrontScreen
## Title screen (UI-22, docs/platform.md §13.2): "Eldmark", the service status and the news from
## [code]GET /v1/status[/code], and login: email, password, "Recordar correo" (Remember email) (only the
## email, in [code]user://settings.cfg[/code]; never the password), Enter, Create account, Forgot your
## password?, Settings and Quit. The password recovery panel asks for the email and always responds with
## the same thing (§4.3).
## [br][br]
## Keyboard: Enter logs in (or submits the open panel), Tab walks through the fields and Esc closes the
## panel. "Entrar" (Enter) is only enabled with email and password. Placeholder background (the fixed
## Vado Gris capture belongs to ART-21). Client only.

## Pressed "Entrar" (Enter) with everything filled in. [param remember]: save the email.
signal login_requested(email: String, password: String, remember: bool)
## Pressed "Crear cuenta" (Create account).
signal register_requested
## Submitted the password recovery panel with [param email].
signal forgot_requested(email: String)
## Pressed "Ajustes" (Settings).
signal settings_requested
## Pressed "Salir" (Quit).
signal quit_requested

const TEXT_TITLE: String = "Eldmark"
const TEXT_ONLINE: String = "En línea · %s"
const TEXT_MAINTENANCE: String = "En mantenimiento"
const TEXT_MAINTENANCE_UNTIL: String = "En mantenimiento hasta las %s"
const TEXT_OFFLINE: String = "Sin conexión con el servidor"
const TEXT_CHECKING: String = "Comprobando el servidor…"
const TEXT_FORGOT_HELP: String = "Escribe tu correo y te enviaremos un enlace para elegir otra contraseña."
const TEXT_FORGOT_SENT: String = "Si existe una cuenta, te hemos enviado un enlace"

var _status_label: Label = null
var _news: VBoxContainer = null
var _email_edit: LineEdit = null
var _password_edit: LineEdit = null
var _remember_check: CheckBox = null
var _enter_button: Button = null
var _register_button: Button = null
var _forgot_button: Button = null
var _settings_button: Button = null
var _quit_button: Button = null
var _login_box: VBoxContainer = null
var _forgot_box: VBoxContainer = null
var _forgot_email: LineEdit = null
var _forgot_send: Button = null
var _forgot_back: Button = null


func _init() -> void:
	super()
	name = "TitleScreen"
	var column: VBoxContainer = _make_panel("", 520.0)
	var title := make_label(TEXT_TITLE, &"TitleLabel")
	title.name = "Titulo"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override(&"font_size", 56)
	column.add_child(title)
	column.move_child(title, 0)
	_status_label = make_label(TEXT_CHECKING, &"DimLabel")
	_status_label.name = "Estado"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_status_label)
	column.move_child(_status_label, 1)
	_news = VBoxContainer.new()
	_news.name = "Noticias"
	_news.add_theme_constant_override(&"separation", 4)
	column.add_child(_news)
	column.add_child(HSeparator.new())

	_login_box = VBoxContainer.new()
	_login_box.name = "Sesion"
	_login_box.add_theme_constant_override(&"separation", ROW_SEPARATION)
	column.add_child(_login_box)
	_email_edit = make_line_edit("correo@ejemplo.com")
	_email_edit.name = "Correo"
	add_row(_login_box, "Correo", _email_edit)
	_password_edit = make_line_edit("contraseña", true, 128)
	_password_edit.name = "Contrasena"
	add_row(_login_box, "Contraseña", _password_edit)
	_remember_check = CheckBox.new()
	_remember_check.name = "Recordar"
	_remember_check.text = "Recordar correo"
	_login_box.add_child(_remember_check)
	_enter_button = make_button("Entrar", 200.0)
	_enter_button.name = "Entrar"
	_register_button = make_button("Crear cuenta", 160.0, &"GhostButton")
	_register_button.name = "CrearCuenta"
	add_button_row(_login_box, [_register_button], [_enter_button])
	_forgot_button = make_button("¿Has olvidado la contraseña?", 0.0, &"GhostButton")
	_forgot_button.name = "Olvidada"
	_login_box.add_child(_forgot_button)

	_forgot_box = VBoxContainer.new()
	_forgot_box.name = "Recuperar"
	_forgot_box.visible = false
	_forgot_box.add_theme_constant_override(&"separation", ROW_SEPARATION)
	column.add_child(_forgot_box)
	var help := make_label(TEXT_FORGOT_HELP, &"DimLabel")
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_forgot_box.add_child(help)
	_forgot_email = make_line_edit("correo@ejemplo.com")
	_forgot_email.name = "CorreoRecuperar"
	add_row(_forgot_box, "Correo", _forgot_email)
	_forgot_back = make_button("Volver", 120.0, &"GhostButton")
	_forgot_send = make_button("Enviar enlace", 180.0)
	add_button_row(_forgot_box, [_forgot_back], [_forgot_send])

	column.add_child(HSeparator.new())
	_settings_button = make_button("Ajustes", 140.0, &"GhostButton")
	_settings_button.name = "Ajustes"
	_quit_button = make_button("Salir", 140.0, &"GhostButton")
	_quit_button.name = "Salir"
	add_button_row(column, [_settings_button], [_quit_button])

	_busy_controls = [_email_edit, _password_edit, _enter_button, _register_button, _forgot_button, _forgot_send,
			_forgot_email]
	_email_edit.text_changed.connect(_on_text_changed)
	_password_edit.text_changed.connect(_on_text_changed)
	_email_edit.text_submitted.connect(_on_email_submitted)
	_password_edit.text_submitted.connect(func(_text: String) -> void: try_login())
	_enter_button.pressed.connect(try_login)
	_register_button.pressed.connect(func() -> void: register_requested.emit())
	_forgot_button.pressed.connect(open_forgot)
	_forgot_back.pressed.connect(close_forgot)
	_forgot_send.pressed.connect(try_forgot)
	_forgot_email.text_submitted.connect(func(_text: String) -> void: try_forgot())
	_settings_button.pressed.connect(func() -> void: settings_requested.emit())
	_quit_button.pressed.connect(func() -> void: quit_requested.emit())
	_refresh_state()


func _ready() -> void:
	focus_first()


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event.is_action_pressed(&"ui_cancel") and is_forgot_open():
		close_forgot()
		get_viewport().set_input_as_handled()


## Puts focus on the first empty field (the email, or the password if the email is remembered).
func focus_first() -> void:
	if not is_inside_tree():
		return
	if _email_edit.text.is_empty():
		_email_edit.grab_focus()
	else:
		_password_edit.grab_focus()


## The service status from [code]GET /v1/status[/code] ([param status]); empty = offline.
func set_status(status: Dictionary) -> void:
	for child: Node in _news.get_children():
		child.queue_free()
	if status.is_empty():
		_status_label.text = TEXT_OFFLINE
		return
	_status_label.text = status_text(status)
	var news: Variant = status.get("news", [])
	if news is Array:
		for entry: Variant in news:
			if entry is Dictionary:
				var item := make_label("%s · %s" % [str((entry as Dictionary).get("title", "")),
						str((entry as Dictionary).get("body", ""))], &"DimLabel")
				item.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				_news.add_child(item)


## The status text for [param status]: "En línea · Eld" (Online · Eld), "En mantenimiento hasta las 18:00"
## (Under maintenance until 18:00)...
static func status_text(status: Dictionary) -> String:
	if str(status.get("status", "")) == "maintenance":
		var until: Variant = status.get("maintenance_at")
		if until is float or until is int:
			return TEXT_MAINTENANCE_UNTIL % PlatformErrors.format_date(int(until)).get_slice(" ", 1)
		return TEXT_MAINTENANCE
	var world_name: String = "Eld"
	var worlds: Variant = status.get("worlds", [])
	if worlds is Array and not (worlds as Array).is_empty() and (worlds as Array)[0] is Dictionary:
		world_name = str(((worlds as Array)[0] as Dictionary).get("name", world_name))
	return TEXT_ONLINE % world_name


func get_status_text() -> String:
	return _status_label.text


## Fills in the remembered email (and checks "Recordar correo" (Remember email)).
func set_remembered_email(email: String) -> void:
	_email_edit.text = email
	_remember_check.button_pressed = not email.is_empty()
	_refresh_state()


## Clears the password (after a failure or when returning to the title).
func clear_password() -> void:
	_password_edit.text = ""
	_refresh_state()


## Emits [signal login_requested] if there is an email and password (what "Entrar" (Enter) and Enter do).
## Returns true if it emitted it.
func try_login() -> bool:
	if _busy or not _can_login():
		return false
	login_requested.emit(_email_edit.text.strip_edges(), _password_edit.text, _remember_check.button_pressed)
	return true


## Opens the password recovery panel (with the typed email).
func open_forgot() -> void:
	_forgot_email.text = _email_edit.text.strip_edges()
	_login_box.visible = false
	_forgot_box.visible = true
	set_notice("")
	if is_inside_tree():
		_forgot_email.grab_focus()


func close_forgot() -> void:
	_forgot_box.visible = false
	_login_box.visible = true
	focus_first()


func is_forgot_open() -> bool:
	return _forgot_box.visible


## Emits [signal forgot_requested] if an email has been typed. Returns true if it emitted it.
func try_forgot() -> bool:
	var email: String = _forgot_email.text.strip_edges()
	if _busy or email.is_empty():
		return false
	forgot_requested.emit(email)
	return true


## The platform has received the recovery request: the usual message and back to the login.
func show_forgot_sent() -> void:
	close_forgot()
	set_notice(TEXT_FORGOT_SENT, false)


func get_email_edit() -> LineEdit:
	return _email_edit


func get_password_edit() -> LineEdit:
	return _password_edit


func get_remember_check() -> CheckBox:
	return _remember_check


func get_enter_button() -> Button:
	return _enter_button


func get_register_button() -> Button:
	return _register_button


func get_forgot_email_edit() -> LineEdit:
	return _forgot_email


func _can_login() -> bool:
	return not _email_edit.text.strip_edges().is_empty() and not _password_edit.text.is_empty()


func _refresh_state() -> void:
	super()
	if _enter_button != null:
		_enter_button.disabled = _busy or not _can_login()


func _on_text_changed(_text: String) -> void:
	_refresh_state()


# Enter in the email field: moves to the password if it is empty; otherwise, logs in.
func _on_email_submitted(_text: String) -> void:
	if _password_edit.text.is_empty() and is_inside_tree():
		_password_edit.grab_focus()
	else:
		try_login()
