class_name FrontMain
extends Node
## Root of the title screen with an account (docs/platform.md §13, UI-22 to UI-24): mounts the screens, talks to the platform
## ([PlatformApi] and [AccountFlow]) and keeps the [AccountSession] between scenes ([member session]).
## [codeblock]
## título ──Entrar──▶ (accept new texts) ──▶ selección ──Entrar──▶ OnlineMain with a ticket
##   │ Crear cuenta · ¿Has olvidado la contraseña?      │ Crear ──▶ creación ──▶ selección
##   └ Ajustes (F10) · Salir                            │ Borrar · Restaurar · Cerrar sesión ──▶ título
## OnlineMain: rejection or disconnection ──▶ selection with the reason (the session stays)
## [/codeblock]
## (The diagram shows the Spanish UI labels: title screen, "Entrar" = enter, character select, creation, and so on.)
## A suspended or banned account receives the privacy session and only sees [SanctionedPanel]. On entering,
## [method AccountFlow.enter] returns the [ClientConfig] with a ticket; [member ClientConfig.from_front] is set and
## control passes to [OnlineMain], which returns here with the reason in [member return_notice]. If refreshing the session is
## impossible ([signal PlatformApi.session_lost]) it returns to the title screen.
## [br][br]
## [ClientLauncher] opens it with [code]--title[/code], with [code]--platform=<url>[/code] or, in an export, with no
## arguments ([member config]). "Recordar correo" (Remember email) saves only the email in the
## [constant ACCOUNT_SECTION] section of [code]user://settings.cfg[/code]; never the password or the tokens. In
## development (platform on this machine: [method is_dev_platform]) creating an account logs in with what was typed
## (§13.2); outside it, no: with an email that already had an account that would reveal that it exists. Client only.

const ONLINE_MAIN_SCENE_PATH: String = "res://scenes/client/online_main.tscn"
const TITLE_SCENE_PATH: String = "res://scenes/ui/title_screen.tscn"
const REGISTER_SCENE_PATH: String = "res://scenes/ui/register_panel.tscn"
const TERMS_SCENE_PATH: String = "res://scenes/ui/terms_panel.tscn"
const SANCTIONED_SCENE_PATH: String = "res://scenes/ui/sanctioned_panel.tscn"
const SELECT_SCENE_PATH: String = "res://scenes/ui/character_select.tscn"
const CREATE_SCENE_PATH: String = "res://scenes/ui/character_create.tscn"
const RENAME_SCENE_PATH: String = "res://scenes/ui/rename_dialog.tscn"
const WINDOW_TITLE: String = "Eldmark"
## Layer of the screens (below the [ClientServices] windows).
const SCREEN_LAYER: int = 40
## Section and key of the remembered email in [code]user://settings.cfg[/code].
const ACCOUNT_SECTION: String = "account"
const EMAIL_KEY: String = "email"
const EXPORT_DEFAULT_NAME: String = "eldmark-datos.json"
const TEXT_SESSION_LOST: String = "Tu sesión ha caducado: vuelve a entrar"
const TEXT_CREATED: String = "Personaje creado"
const TEXT_DELETED: String = "Personaje borrado: puedes restaurarlo durante 7 días"
const TEXT_RESTORED: String = "Personaje restaurado"
const TEXT_RENAMED: String = "Nombre cambiado"
const TEXT_EXPORT_FAILED: String = "No se pudo guardar el archivo con tus datos"

## Configuration (filled in by [ClientLauncher]; if it is null on start-up, it is read from the arguments).
static var config: ClientConfig
## The account session, which survives scene changes (null or empty = no session).
static var session: AccountSession
## Reason with which [OnlineMain] returns to selection (shown once).
static var return_notice: String = ""
## Tests: the API's [member PlatformApi.request_hook].
static var request_hook: Callable = Callable()
## Tests: if valid, entering the world calls this hook with the [ClientConfig] instead of changing scene.
static var online_hook: Callable = Callable()
## Tests: if valid, "Salir" (Quit) calls this hook instead of closing the process.
static var quit_hook: Callable = Callable()
## File of the remembered email (the settings one; tests use another).
static var settings_path: String = ClientSettings.PATH
## Folder where the data export is saved (empty = Downloads or, if there is none, [code]user://[/code]).
static var export_dir: String = ""

var _api: PlatformApi = null
var _flow: AccountFlow = null
var _layer: CanvasLayer = null
var _title: TitleScreen = null
var _register: RegisterPanel = null
var _terms: TermsPanel = null
var _sanctioned: SanctionedPanel = null
var _select: CharacterSelect = null
var _create: CharacterCreate = null
var _rename: RenameDialog = null
var _screens: Array[FrontScreen] = []
var _current: FrontScreen = null
var _legal: Dictionary = {}
var _list: Dictionary = {}
var _entering: bool = false


func _ready() -> void:
	if config == null:
		config = ClientConfig.from_args(OS.get_cmdline_user_args(), true)
	if config.platform_url.is_empty():
		config.platform_url = ClientConfig.default_platform_url()
	for warning: String in config.warnings:
		push_warning("[Eldmark] %s" % warning)
	get_window().title = WINDOW_TITLE
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	InputBindings.ensure_defaults()
	_api = PlatformApi.new()
	_api.base_url = config.platform_url
	_api.request_hook = request_hook
	if session != null:
		_api.session = session
	add_child(_api)
	_api.session_lost.connect(_on_session_lost)
	_flow = AccountFlow.new(_api)
	_flow.busy_waiting.connect(_on_busy_waiting)
	_build_screens()
	var notice: String = return_notice
	return_notice = ""
	if _api.session.is_active() and not _api.session.is_privacy():
		_open_select(notice)
	else:
		_open_title(notice)


func _exit_tree() -> void:
	if _flow != null:
		_flow.cancel_enter()


# --- Access (tests) -------------------------------------------------------------------------------

func get_api() -> PlatformApi:
	return _api


func get_flow() -> AccountFlow:
	return _flow


## The screen being shown.
func get_current_screen() -> FrontScreen:
	return _current


func get_title_screen() -> TitleScreen:
	return _title


func get_register_panel() -> RegisterPanel:
	return _register


func get_terms_panel() -> TermsPanel:
	return _terms


func get_sanctioned_panel() -> SanctionedPanel:
	return _sanctioned


func get_character_select() -> CharacterSelect:
	return _select


func get_character_create() -> CharacterCreate:
	return _create


func get_rename_dialog() -> RenameDialog:
	return _rename


## true if the platform is on this machine (development): creating an account logs in with what was typed.
func is_dev_platform() -> bool:
	return ClientConfig.is_loopback_host(ClientConfig.url_host(config.platform_url))


## The remembered email (empty if there is none).
static func remembered_email() -> String:
	var file := ConfigFile.new()
	if file.load(settings_path) != OK:
		return ""
	return str(file.get_value(ACCOUNT_SECTION, EMAIL_KEY, ""))


## Remembers [param email] (empty forgets it) without touching the rest of the settings file.
static func remember_email(email: String) -> void:
	var file := ConfigFile.new()
	file.load(settings_path)
	if email.is_empty():
		if file.has_section_key(ACCOUNT_SECTION, EMAIL_KEY):
			file.erase_section_key(ACCOUNT_SECTION, EMAIL_KEY)
	else:
		file.set_value(ACCOUNT_SECTION, EMAIL_KEY, email)
	if file.save(settings_path) != OK:
		push_warning("[Eldmark] No se pudo guardar el correo recordado en %s" % settings_path)


# --- Screens --------------------------------------------------------------------------------------

func _build_screens() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "Pantallas"
	_layer.layer = SCREEN_LAYER
	add_child(_layer)
	_title = _instantiate(TITLE_SCENE_PATH) as TitleScreen
	_register = _instantiate(REGISTER_SCENE_PATH) as RegisterPanel
	_terms = _instantiate(TERMS_SCENE_PATH) as TermsPanel
	_sanctioned = _instantiate(SANCTIONED_SCENE_PATH) as SanctionedPanel
	_select = _instantiate(SELECT_SCENE_PATH) as CharacterSelect
	_create = _instantiate(CREATE_SCENE_PATH) as CharacterCreate
	_screens = [_title, _register, _terms, _sanctioned, _select, _create]
	for screen: FrontScreen in _screens:
		screen.visible = false
		_layer.add_child(screen)
	var rename_scene: PackedScene = load(RENAME_SCENE_PATH) as PackedScene
	_rename = rename_scene.instantiate() as RenameDialog
	_layer.add_child(_rename)

	_title.set_remembered_email(remembered_email())
	_title.login_requested.connect(_on_login_requested)
	_title.register_requested.connect(_on_register_requested)
	_title.forgot_requested.connect(_on_forgot_requested)
	_title.settings_requested.connect(_on_settings_requested)
	_title.quit_requested.connect(_on_quit_requested)
	_register.submitted.connect(_on_register_submitted)
	_register.text_requested.connect(_on_text_requested.bind(_register))
	_register.canceled.connect(func() -> void: _show(_title))
	_terms.accepted.connect(_on_terms_accepted)
	_terms.text_requested.connect(_on_text_requested.bind(_terms))
	_terms.logout_requested.connect(_logout)
	_sanctioned.export_requested.connect(_on_export_requested)
	_sanctioned.deletion_requested.connect(_on_deletion_requested)
	_sanctioned.logout_requested.connect(_logout)
	_select.enter_requested.connect(_on_enter_requested)
	_select.create_requested.connect(_on_create_requested)
	_select.delete_requested.connect(_on_delete_requested)
	_select.restore_requested.connect(_on_restore_requested)
	_select.logout_requested.connect(_logout)
	_select.wait_canceled.connect(func() -> void: _flow.cancel_enter())
	_create.create_requested.connect(_on_create_submitted)
	_create.name_check_requested.connect(_on_name_check_requested)
	_create.canceled.connect(func() -> void: _show(_select))
	_rename.rename_requested.connect(_on_rename_requested)


func _instantiate(path: String) -> Node:
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		push_error("[Eldmark] No se pudo cargar la escena %s" % path)
		return null
	return scene.instantiate()


func _show(screen: FrontScreen) -> void:
	for other: FrontScreen in _screens:
		other.visible = other == screen
	_current = screen
	if screen == _title:
		_title.focus_first()


func _open_title(notice: String) -> void:
	_show(_title)
	_title.set_notice(notice)
	_load_status()


func _open_select(notice: String) -> void:
	_show(_select)
	_select.set_notice(notice)
	_load_characters()


func _open_terms(documents: Variant) -> void:
	var kinds := PackedStringArray()
	if documents is Array:
		for kind: Variant in documents:
			kinds.append(str(kind))
	_terms.set_documents(kinds)
	_show(_terms)


# --- Title ----------------------------------------------------------------------------------------

func _load_status() -> void:
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/status", null, false)
	if not is_inside_tree():
		return
	_title.set_status(result.data if result.ok else {})
	print("[Eldmark] Plataforma %s: %s" % [config.platform_url, _title.get_status_text()])
	if result.code == "client_outdated":
		_title.set_notice(PlatformErrors.text_for(result))


func _on_login_requested(email: String, password: String, remember: bool) -> void:
	remember_email(email.strip_edges().to_lower() if remember else "")
	_title.set_busy(true)
	_title.set_notice("")
	var result: ApiResult = await _flow.login(email, password)
	if not is_inside_tree():
		return
	_title.set_busy(false)
	_title.clear_password()
	if not result.ok:
		_title.set_notice(PlatformErrors.text_for(result))
		return
	await _after_login()


# After logging in: a sanctioned account goes to its screen; texts pending acceptance come first; otherwise, selection.
func _after_login() -> void:
	session = _api.session
	if _api.session.is_privacy():
		_sanctioned.set_restriction(_api.session.restriction)
		_show(_sanctioned)
		return
	var account: ApiResult = await _flow.fetch_account()
	if not is_inside_tree():
		return
	var pending: Variant = account.data.get("pending") if account.ok else null
	if pending is Dictionary and bool((pending as Dictionary).get("terms_required", false)):
		_open_terms((pending as Dictionary).get("documents", []))
		return
	_open_select("")


func _on_forgot_requested(email: String) -> void:
	_title.set_busy(true)
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_POST, "/v1/account/password-reset",
			{"email": email.strip_edges().to_lower()}, false)
	if not is_inside_tree():
		return
	_title.set_busy(false)
	if result.ok:
		_title.show_forgot_sent()
	else:
		_title.set_notice(PlatformErrors.text_for(result))


func _on_settings_requested() -> void:
	var services: ClientServices = get_node_or_null(ClientServices.NODE_NAME) as ClientServices
	if services != null:
		services.toggle_settings()


func _on_quit_requested() -> void:
	if quit_hook.is_valid():
		quit_hook.call(0)
		return
	get_tree().quit(0)


# --- Registration and texts -----------------------------------------------------------------------

func _on_register_requested() -> void:
	_register.reset(_title.get_email_edit().text.strip_edges())
	_show(_register)
	if _legal.is_empty():
		await _load_legal()
	_register.set_legal_versions(_legal)


func _load_legal() -> void:
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/legal", null, false)
	if result.ok:
		_legal = result.data
	elif is_inside_tree() and _current != null:
		_current.set_notice(PlatformErrors.text_for(result))


func _on_register_submitted(body: Dictionary) -> void:
	_register.set_busy(true)
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_POST, "/v1/accounts", body, false)
	if not is_inside_tree():
		return
	_register.set_busy(false)
	if not result.ok:
		_register.set_notice(PlatformErrors.text_for(result))
		return
	if is_dev_platform():
		# Development: the account is used right away (without verifying the email, §4.2).
		var login: ApiResult = await _flow.login(str(body.get("email", "")), str(body.get("password", "")))
		if not is_inside_tree():
			return
		if login.ok:
			await _after_login()
			return
	_show(_title)
	_title.get_email_edit().text = str(body.get("email", ""))
	_title.set_notice(RegisterPanel.TEXT_SENT, false)


func _on_text_requested(kind: String, screen: FrontScreen) -> void:
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, "/v1/legal/%s" % kind.uri_encode(), null,
			false)
	if not is_inside_tree():
		return
	if not result.ok:
		screen.set_notice(PlatformErrors.text_for(result))
		return
	if screen == _register:
		_register.show_text(kind, result.text)
	elif screen == _terms:
		_terms.show_text(kind, result.text)


func _on_terms_accepted() -> void:
	_terms.set_busy(true)
	if _legal.is_empty():
		await _load_legal()
	var body: Dictionary = {}
	for kind: String in RegisterPanel.KINDS:
		var entry: Variant = _legal.get(kind)
		body[kind] = int((entry as Dictionary).get("version", 0)) if entry is Dictionary else 0
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_POST, "/v1/account/accept", body, true)
	if not is_inside_tree():
		return
	_terms.set_busy(false)
	if not result.ok:
		_terms.set_notice(PlatformErrors.text_for(result))
		return
	_open_select("")


# --- Sanctioned account ---------------------------------------------------------------------------

func _on_export_requested(password: String) -> void:
	_sanctioned.set_busy(true)
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_POST, "/v1/account/export",
			{"password": password}, true)
	if not is_inside_tree():
		return
	_sanctioned.set_busy(false)
	if not result.ok:
		_sanctioned.set_notice(PlatformErrors.text_for(result))
		return
	var path: String = _save_export(result)
	if path.is_empty():
		_sanctioned.set_notice(TEXT_EXPORT_FAILED)
	else:
		_sanctioned.show_export_saved(path)


## Saves the export from [param result] and returns the path (empty if it could not be saved).
func _save_export(result: ApiResult) -> String:
	var directory: String = export_dir
	if directory.is_empty():
		directory = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
		if directory.is_empty() or not DirAccess.dir_exists_absolute(directory):
			directory = OS.get_user_data_dir()
	var path: String = directory.path_join(export_file_name(result.header("Content-Disposition")))
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(result.text)
	file.close()
	return path


## The file name from [code]Content-Disposition: attachment; filename="…"[/code], with only letters, digits,
## dot, hyphen and underscore ([constant EXPORT_DEFAULT_NAME] if it does not carry a valid one).
static func export_file_name(disposition: String) -> String:
	var start: int = disposition.find("filename=")
	if start < 0:
		return EXPORT_DEFAULT_NAME
	var value: String = disposition.substr(start + 9).get_slice(";", 0).strip_edges().trim_prefix("\"") \
			.trim_suffix("\"")
	var clean: String = ""
	for i: int in range(value.length()):
		var c: String = value[i]
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c in [".", "-", "_"]:
			clean += c
	if clean.is_empty() or clean.begins_with(".") or not clean.ends_with(".json"):
		return EXPORT_DEFAULT_NAME
	return clean


func _on_deletion_requested(password: String) -> void:
	_sanctioned.set_busy(true)
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_POST, "/v1/account/deletion",
			{"password": password}, true)
	if not is_inside_tree():
		return
	_sanctioned.set_busy(false)
	if not result.ok:
		_sanctioned.set_notice(PlatformErrors.text_for(result))
		return
	_sanctioned.show_deletion(result.int_of("purge_at", 0))


# --- Selection ------------------------------------------------------------------------------------

func _load_characters(select_id: int = 0) -> void:
	_select.set_busy(true)
	var result: ApiResult = await _flow.list_characters(config.world_id)
	if not is_inside_tree():
		return
	_select.set_busy(false)
	if not result.ok:
		_select.set_notice(PlatformErrors.text_for(result))
		return
	_list = result.data
	_select.set_data(result.data, select_id)


func _on_enter_requested(character_id: int) -> void:
	if _entering:
		return
	_entering = true
	_select.set_busy(true)
	_select.set_notice("")
	var result: ApiResult = await _flow.enter(character_id, config)
	if not is_inside_tree():
		return
	_entering = false
	_select.show_waiting(-1)
	_select.set_busy(false)
	if result.ok:
		var online_config: ClientConfig = result.data["config"] as ClientConfig
		online_config.from_front = true
		session = _api.session
		_go_online(online_config)
		return
	match result.code:
		"rename_required":
			_rename.open(character_id, str(_select.get_selected_character().get("name", "")))
		"terms_required":
			_open_terms(result.data.get("documents", []))
		_:
			_select.set_notice(PlatformErrors.text_for(result))


func _go_online(online_config: ClientConfig) -> void:
	OnlineMain.config = online_config
	if online_hook.is_valid():
		online_hook.call(online_config)
		return
	get_tree().change_scene_to_file(ONLINE_MAIN_SCENE_PATH)


func _on_busy_waiting(seconds_left: int) -> void:
	if is_instance_valid(_select):
		_select.show_waiting(seconds_left)


func _on_create_requested() -> void:
	var realm: StringName = StringName(str(_list.get("realm", ""))) if _list.get("realm") is String else &""
	if realm.is_empty():
		realm = _api.session.realm_in(config.world_id)
	_create.setup(realm)
	_show(_create)


func _on_delete_requested(character_id: int, confirm_name: String) -> void:
	_select.set_busy(true)
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_DELETE, "/v1/characters/%d" % character_id,
			{"confirm_name": confirm_name}, true)
	if not is_inside_tree():
		return
	_select.set_busy(false)
	if not result.ok:
		_select.set_notice(PlatformErrors.text_for(result))
		return
	await _load_characters(character_id)
	_select.set_notice(TEXT_DELETED, false)


func _on_restore_requested(character_id: int) -> void:
	_select.set_busy(true)
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_POST, "/v1/characters/%d/restore" % character_id,
			null, true)
	if not is_inside_tree():
		return
	_select.set_busy(false)
	if not result.ok:
		_select.set_notice(PlatformErrors.text_for(result))
		return
	await _load_characters(character_id)
	_select.set_notice(TEXT_RESTORED, false)


func _on_rename_requested(character_id: int, display_name: String) -> void:
	_rename.set_busy(true)
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_POST, "/v1/characters/%d/rename" % character_id,
			{"name": display_name}, true)
	if not is_inside_tree():
		return
	if not result.ok:
		_rename.set_error(PlatformErrors.text_for(result))
		return
	_rename.close()
	await _load_characters(character_id)
	_select.set_notice(TEXT_RENAMED, false)


# --- Creation -------------------------------------------------------------------------------------

func _on_name_check_requested(display_name: String) -> void:
	var path: String = "/v1/worlds/%d/name-check?name=%s" % [config.world_id, display_name.uri_encode()]
	var result: ApiResult = await _api.call_api(HTTPClient.METHOD_GET, path, null, true)
	if not is_inside_tree() or not result.ok:
		return
	var available: bool = bool(result.data.get("available", false))
	var reason_text: String = ""
	if not available:
		var code: String = str(result.data.get("code", "name_taken"))
		reason_text = PlatformErrors.text_for(ApiResult.failure(409 if code == "name_taken" else 422, code, "",
				{"reason": result.data.get("reason", "")}))
	_create.set_name_check(display_name, available, reason_text)


func _on_create_submitted(body: Dictionary) -> void:
	_create.set_busy(true)
	_create.set_notice("")
	var appearance: PackedByteArray = body.get("appearance", PackedByteArray())
	var result: ApiResult = await _flow.create_character(config.world_id, str(body.get("name", "")),
			StringName(str(body.get("realm", ""))), StringName(str(body.get("race_id", ""))), appearance,
			StringName(str(body.get("starter_template_id", ""))))
	if not is_inside_tree():
		return
	_create.set_busy(false)
	if not result.ok:
		var text: String = PlatformErrors.text_for(result)
		if result.code in ["name_taken", "name_invalid"]:
			_create.show_name_error(text)
		else:
			_create.set_notice(text)
		return
	var character: Variant = result.data.get("character", {})
	var created_id: int = AccountFlow.parse_id((character as Dictionary).get("character_id")) \
			if character is Dictionary else 0
	_show(_select)
	await _load_characters(created_id)
	_select.set_notice(TEXT_CREATED, false)


# --- Session --------------------------------------------------------------------------------------

func _logout() -> void:
	_flow.cancel_enter()
	await _flow.logout()
	session = null
	if not is_inside_tree():
		return
	_title.clear_password()
	_open_title("")


func _on_session_lost(_code: String) -> void:
	session = null
	_flow.cancel_enter()
	_rename.close()
	_open_title(TEXT_SESSION_LOST)
