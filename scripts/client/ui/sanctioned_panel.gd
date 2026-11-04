class_name SanctionedPanel
extends FrontScreen
## Sanctioned account (docs/platform.md §4.2 and §13.2): with the privacy session of a suspended or
## banned account, the reason and the end date, and only "Descargar mis datos" (Download my data)
## ([code]POST /v1/account/export[/code]), "Borrar la cuenta" (Delete the account)
## ([code]POST /v1/account/deletion[/code], with confirmation) and "Cerrar sesión" (Log out). The first
## two ask for the password (§4.3). This way exporting and requesting erasure do not depend on not being
## sanctioned (§11.2). Esc logs out. Client only.

## Pressed "Descargar mis datos" (Download my data) with the password typed.
signal export_requested(password: String)
## Confirmed "Borrar la cuenta" (Delete the account) with the password typed.
signal deletion_requested(password: String)
## Pressed "Cerrar sesión" (Log out) or Esc.
signal logout_requested

const TEXT_HELP: String = "Puedes descargar tus datos o pedir que se borre tu cuenta. Escribe tu contraseña para hacerlo."
const TEXT_CONFIRM_TITLE: String = "Borrar la cuenta"
const TEXT_CONFIRM: String = "Tu cuenta y tus personajes se borrarán dentro de 14 días. Hasta entonces puedes cancelarlo iniciando sesión. ¿Seguro?"
const TEXT_SAVED: String = "Datos guardados en %s"
const TEXT_DELETION: String = "Tu cuenta se borrará el %s"

var _reason_label: Label = null
var _password_edit: LineEdit = null
var _export_button: Button = null
var _delete_button: Button = null
var _logout_button: Button = null
var _confirm: UIConfirmDialog = null
var _restriction: Dictionary = {}


func _init() -> void:
	super()
	name = "SanctionedPanel"
	var column: VBoxContainer = _make_panel("Cuenta sancionada", 600.0)
	_reason_label = make_label("", &"WarningLabel")
	_reason_label.name = "Motivo"
	_reason_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_reason_label)
	var help := make_label(TEXT_HELP, &"DimLabel")
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(help)
	_password_edit = make_line_edit("contraseña", true, 128)
	_password_edit.name = "Contrasena"
	add_row(column, "Contraseña", _password_edit)
	_export_button = make_button("Descargar mis datos", 220.0)
	_export_button.name = "Descargar"
	_delete_button = make_button("Borrar la cuenta", 180.0, &"DangerButton")
	_delete_button.name = "Borrar"
	_logout_button = make_button("Cerrar sesión", 160.0, &"GhostButton")
	_logout_button.name = "CerrarSesion"
	add_button_row(column, [_export_button, _delete_button], [_logout_button])
	_confirm = UIConfirmDialog.new()
	_confirm.name = "Confirmar"
	add_child(_confirm)
	_busy_controls = [_password_edit, _logout_button]
	_password_edit.text_changed.connect(func(_text: String) -> void: _refresh_state())
	_export_button.pressed.connect(try_export)
	_delete_button.pressed.connect(ask_deletion)
	_logout_button.pressed.connect(func() -> void: logout_requested.emit())
	_confirm.confirmed.connect(_on_deletion_confirmed)
	_refresh_state()


func _unhandled_key_input(event: InputEvent) -> void:
	if is_visible_in_tree() and not _confirm.is_open() and event.is_action_pressed(&"ui_cancel"):
		logout_requested.emit()
		get_viewport().set_input_as_handled()


## The sanction ([code]{code, until, reason}[/code] from the privacy session).
func set_restriction(restriction: Dictionary) -> void:
	_restriction = restriction
	_reason_label.text = PlatformErrors.text_for(ApiResult.failure(403, str(restriction.get("code",
			"account_suspended")), "", restriction))
	_password_edit.text = ""
	set_notice("")
	_refresh_state()


func get_reason_text() -> String:
	return _reason_label.text


## Emits [signal export_requested] if there is a password. Returns true if it emitted it.
func try_export() -> bool:
	if _busy or _password_edit.text.is_empty():
		return false
	export_requested.emit(_password_edit.text)
	return true


## Opens the deletion confirmation (if there is a password).
func ask_deletion() -> void:
	if _busy or _password_edit.text.is_empty():
		return
	_confirm.open(TEXT_CONFIRM_TITLE, TEXT_CONFIRM, "Borrar", "Cancelar", true)


## The data is already at [param path].
func show_export_saved(path: String) -> void:
	set_notice(TEXT_SAVED % path, false)


## Deletion has been requested: the account will be purged at [param purge_at] (Unix).
func show_deletion(purge_at: int) -> void:
	set_notice(TEXT_DELETION % PlatformErrors.format_date(purge_at), false)


func get_password_edit() -> LineEdit:
	return _password_edit


func get_export_button() -> Button:
	return _export_button


func get_delete_button() -> Button:
	return _delete_button


func get_logout_button() -> Button:
	return _logout_button


func get_confirm_dialog() -> UIConfirmDialog:
	return _confirm


func _refresh_state() -> void:
	super()
	if _export_button == null:
		return
	var has_password: bool = not _password_edit.text.is_empty()
	_export_button.disabled = _busy or not has_password
	_delete_button.disabled = _busy or not has_password


func _on_deletion_confirmed() -> void:
	if not _password_edit.text.is_empty():
		deletion_requested.emit(_password_edit.text)
