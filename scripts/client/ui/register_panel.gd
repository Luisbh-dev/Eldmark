class_name RegisterPanel
extends FrontScreen
## Crear cuenta (docs/plataforma.md §4.2, §11.4 y §13.2): correo, la contraseña dos veces (10 caracteres como
## mínimo), «Tengo 16 años o más», una casilla por cada texto legal (términos, privacidad y normas) con su enlace,
## que abre el texto en un panel con desplazamiento, y los dos consentimientos opcionales, desmarcados (informes de
## fallos y analítica). «Crear cuenta» solo se activa con todo eso y con las versiones vigentes de los textos
## ([method set_legal_versions], de [code]GET /v1/legal[/code]); entonces emite [signal submitted] con el cuerpo de
## [code]POST /v1/accounts[/code]. La respuesta es siempre la misma (§4.2): «Te hemos enviado un correo».
## [br][br]
## Esc vuelve al título. Solo cliente.

## Pulsó «Crear cuenta» con todo válido: [param body] es el cuerpo de [code]POST /v1/accounts[/code].
signal submitted(body: Dictionary)
## Pidió leer el texto [param kind] ([code]terms[/code], [code]privacy[/code] o [code]rules[/code]).
signal text_requested(kind: String)
## Pulsó «Volver» o Esc.
signal canceled

const KINDS: Array[String] = ["terms", "privacy", "rules"]
const KIND_TITLES: Dictionary = {"terms": "los términos de uso", "privacy": "la política de privacidad",
		"rules": "las normas de conducta"}
const MIN_PASSWORD: int = 10
const MAX_PASSWORD: int = 128
const TEXT_SHORT: String = "La contraseña necesita al menos 10 caracteres"
const TEXT_LONG: String = "La contraseña no puede pasar de 128 caracteres"
const TEXT_MISMATCH: String = "Las contraseñas no coinciden"
const TEXT_SAME_AS_EMAIL: String = "La contraseña no puede ser el correo"
const TEXT_EMAIL: String = "Escribe un correo válido"
const TEXT_AGE: String = "Marca que tienes 16 años o más"
const TEXT_ACCEPT: String = "Acepta los términos, la privacidad y las normas"
const TEXT_NO_LEGAL: String = "Cargando los textos legales…"
const TEXT_SENT: String = "Te hemos enviado un correo. Abre el enlace para verificar tu cuenta."

var _email_edit: LineEdit = null
var _password_edit: LineEdit = null
var _repeat_edit: LineEdit = null
var _age_check: CheckBox = null
var _accept_checks: Dictionary[String, CheckBox] = {}
var _crash_check: CheckBox = null
var _analytics_check: CheckBox = null
var _hint_label: Label = null
var _submit_button: Button = null
var _back_button: Button = null
var _text_title: Label = null
var _text_view: RichTextLabel = null
var _text_scroll: ScrollContainer = null
var _versions: Dictionary = {}


func _init() -> void:
	super()
	name = "RegisterPanel"
	var column: VBoxContainer = _make_panel("Crear cuenta", 620.0)
	_email_edit = make_line_edit("correo@ejemplo.com")
	_email_edit.name = "Correo"
	add_row(column, "Correo", _email_edit)
	_password_edit = make_line_edit("10 caracteres como mínimo", true, MAX_PASSWORD)
	_password_edit.name = "Contrasena"
	add_row(column, "Contraseña", _password_edit)
	_repeat_edit = make_line_edit("otra vez", true, MAX_PASSWORD)
	_repeat_edit.name = "Repetir"
	add_row(column, "Repite la contraseña", _repeat_edit)
	_age_check = CheckBox.new()
	_age_check.name = "Edad"
	_age_check.text = "Tengo 16 años o más"
	column.add_child(_age_check)
	for kind: String in KINDS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 8)
		var check := CheckBox.new()
		check.name = "Acepto_%s" % kind
		check.text = "Acepto %s" % KIND_TITLES[kind]
		check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(check)
		var link := make_button("Leer", 80.0, &"GhostButton")
		link.name = "Leer_%s" % kind
		link.pressed.connect(func() -> void: text_requested.emit(kind))
		row.add_child(link)
		column.add_child(row)
		_accept_checks[kind] = check
		check.toggled.connect(_on_toggled)
	_crash_check = CheckBox.new()
	_crash_check.name = "InformesFallos"
	_crash_check.text = "Enviar informes de fallos (opcional)"
	column.add_child(_crash_check)
	_analytics_check = CheckBox.new()
	_analytics_check.name = "Analitica"
	_analytics_check.text = "Compartir datos de uso anónimos (opcional)"
	column.add_child(_analytics_check)
	_text_title = make_label("", &"DimLabel")
	_text_title.visible = false
	column.add_child(_text_title)
	_text_scroll = ScrollContainer.new()
	_text_scroll.name = "Texto"
	_text_scroll.custom_minimum_size = Vector2(0.0, 220.0)
	_text_scroll.visible = false
	column.add_child(_text_scroll)
	_text_view = RichTextLabel.new()
	_text_view.fit_content = true
	_text_view.bbcode_enabled = false
	_text_view.selection_enabled = true
	_text_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_scroll.add_child(_text_view)
	_hint_label = make_label("", &"DimLabel")
	_hint_label.name = "Pista"
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_hint_label)
	_back_button = make_button("Volver", 120.0, &"GhostButton")
	_submit_button = make_button("Crear cuenta", 200.0)
	_submit_button.name = "Crear"
	add_button_row(column, [_back_button], [_submit_button])
	_busy_controls = [_email_edit, _password_edit, _repeat_edit, _back_button]
	for edit: LineEdit in [_email_edit, _password_edit, _repeat_edit]:
		edit.text_changed.connect(_on_text_changed)
	_repeat_edit.text_submitted.connect(func(_text: String) -> void: try_submit())
	_age_check.toggled.connect(_on_toggled)
	_submit_button.pressed.connect(try_submit)
	_back_button.pressed.connect(func() -> void: canceled.emit())
	_refresh_state()


func _unhandled_key_input(event: InputEvent) -> void:
	if is_visible_in_tree() and event.is_action_pressed(&"ui_cancel"):
		canceled.emit()
		get_viewport().set_input_as_handled()


## Vacía el formulario (al abrirlo de nuevo) con [param email] en el correo.
func reset(email: String = "") -> void:
	_email_edit.text = email
	_password_edit.text = ""
	_repeat_edit.text = ""
	_age_check.button_pressed = false
	for kind: String in KINDS:
		_accept_checks[kind].button_pressed = false
	_crash_check.button_pressed = false
	_analytics_check.button_pressed = false
	_text_scroll.visible = false
	_text_title.visible = false
	set_notice("")
	_refresh_state()
	if is_inside_tree():
		_email_edit.grab_focus()


## Las versiones vigentes de los textos ([code]GET /v1/legal[/code]: [code]{terms: {version, sha256}, …}[/code]).
func set_legal_versions(legal: Dictionary) -> void:
	_versions = {}
	for kind: String in KINDS:
		var entry: Variant = legal.get(kind)
		if entry is Dictionary and ((entry as Dictionary).get("version") is float \
				or (entry as Dictionary).get("version") is int):
			_versions[kind] = int((entry as Dictionary).get("version"))
	_refresh_state()


## true si se conocen las versiones de los tres textos.
func has_legal_versions() -> bool:
	return _versions.size() == KINDS.size()


## Enseña el texto [param kind] ([param text], Markdown tal cual) en el panel con desplazamiento.
func show_text(kind: String, text: String) -> void:
	_text_title.text = "Texto de %s" % KIND_TITLES.get(kind, kind)
	_text_title.visible = true
	_text_view.text = text
	_text_scroll.visible = true
	_text_scroll.scroll_vertical = 0


## El texto que se enseña en el panel (vacío si ninguno).
func get_shown_text() -> String:
	return _text_view.text if _text_scroll.visible else ""


## El cuerpo de [code]POST /v1/accounts[/code] con lo escrito (§4.2).
func build_body() -> Dictionary:
	return {
		"email": _email_edit.text.strip_edges().to_lower(),
		"password": _password_edit.text,
		"age_confirmed": true,
		"accept": {"terms": _versions.get("terms", 0), "privacy": _versions.get("privacy", 0),
				"rules": _versions.get("rules", 0)},
		"consents": {"crash_reports": _crash_check.button_pressed, "analytics": _analytics_check.button_pressed},
	}


## Lo que falta para poder crear la cuenta (vacío si nada).
func missing_text() -> String:
	var email: String = _email_edit.text.strip_edges()
	if email.is_empty() or email.count("@") != 1 or email.begins_with("@") or email.ends_with("@"):
		return TEXT_EMAIL
	if _password_edit.text.length() < MIN_PASSWORD:
		return TEXT_SHORT
	if _password_edit.text.length() > MAX_PASSWORD:
		return TEXT_LONG
	if _password_edit.text.strip_edges().to_lower() == email.to_lower():
		return TEXT_SAME_AS_EMAIL
	if _repeat_edit.text != _password_edit.text:
		return TEXT_MISMATCH
	if not _age_check.button_pressed:
		return TEXT_AGE
	for kind: String in KINDS:
		if not _accept_checks[kind].button_pressed:
			return TEXT_ACCEPT
	if not has_legal_versions():
		return TEXT_NO_LEGAL
	return ""


## Emite [signal submitted] si todo vale. Devuelve true si lo emitió.
func try_submit() -> bool:
	if _busy or not missing_text().is_empty():
		return false
	submitted.emit(build_body())
	return true


func get_email_edit() -> LineEdit:
	return _email_edit


func get_password_edit() -> LineEdit:
	return _password_edit


func get_repeat_edit() -> LineEdit:
	return _repeat_edit


func get_age_check() -> CheckBox:
	return _age_check


func get_accept_check(kind: String) -> CheckBox:
	return _accept_checks.get(kind)


func get_consent_checks() -> Array[CheckBox]:
	return [_crash_check, _analytics_check]


func get_submit_button() -> Button:
	return _submit_button


func get_hint_text() -> String:
	return _hint_label.text


func _refresh_state() -> void:
	super()
	if _submit_button == null:
		return
	var missing: String = missing_text()
	_hint_label.text = missing
	_submit_button.disabled = _busy or not missing.is_empty()


func _on_text_changed(_text: String) -> void:
	_refresh_state()


func _on_toggled(_pressed: bool) -> void:
	_refresh_state()
