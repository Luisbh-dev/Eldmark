extends TestCase
## Tests for [FrontMain] with the real scene and the fake platform ([FakePublicPlatform] as
## [member PlatformApi.request_hook]; docs/plataforma.md §13 and §15 P8): title → selection (and "Recordar correo"
## (remember email) without the password), the sanctioned account (export and delete), the new texts, entering with a ticket towards
## [OnlineMain] ([member ClientConfig.from_front]), the forced rename, waiting on [code]character_busy[/code],
## create, delete and restore, log out, the lost session, registration (it only logs in against a local
## platform) and the return from [OnlineMain] with the reason.

const FRONT_SCENE: String = "res://scenes/client/front_main.tscn"
const ONLINE_MAIN_SCENE: String = "res://scenes/client/online_main.tscn"
const SETTINGS_FILE: String = "test_front_main_settings.cfg"

var _front: FrontMain
var _online: OnlineMain
var _platform: FakePublicPlatform
var _online_configs: Array[ClientConfig] = []
var _quits: Array[int] = []
var _front_notices: Array[String] = []
var _saved: Dictionary = {}


func before_each() -> void:
	_saved = {
		"config": FrontMain.config, "session": FrontMain.session, "notice": FrontMain.return_notice,
		"hook": FrontMain.request_hook, "online": FrontMain.online_hook, "quit": FrontMain.quit_hook,
		"settings": FrontMain.settings_path, "export": FrontMain.export_dir, "online_config": OnlineMain.config,
		"front_hook": OnlineMain.front_hook, "interactive": OnlineMain.force_interactive,
		"online_quit": OnlineMain.quit_hook,
	}
	_online_configs.clear()
	_quits.clear()
	_front_notices.clear()
	_platform = FakePublicPlatform.new(tree)
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.TITLE
	config.platform_url = "http://127.0.0.1:24680"
	FrontMain.config = config
	FrontMain.session = null
	FrontMain.return_notice = ""
	FrontMain.request_hook = func(method: int, path: String, body: Variant) -> ApiResult:
		return await (_platform.hook(_front.get_api()) as Callable).call(method, path, body)
	FrontMain.online_hook = func(online_config: ClientConfig) -> void: _online_configs.append(online_config)
	FrontMain.quit_hook = func(code: int) -> void: _quits.append(code)
	FrontMain.settings_path = NetHarness.build_path(SETTINGS_FILE)
	FrontMain.export_dir = NetHarness.get_build_dir()
	DirAccess.remove_absolute(FrontMain.settings_path)


func after_each() -> void:
	for node: Node in [_front, _online]:
		if is_instance_valid(node):
			node.get_parent().remove_child(node)
			node.free()
	_front = null
	_online = null
	DirAccess.remove_absolute(FrontMain.settings_path)
	FrontMain.config = _saved["config"]
	FrontMain.session = _saved["session"]
	FrontMain.return_notice = _saved["notice"]
	FrontMain.request_hook = _saved["hook"]
	FrontMain.online_hook = _saved["online"]
	FrontMain.quit_hook = _saved["quit"]
	FrontMain.settings_path = _saved["settings"]
	FrontMain.export_dir = _saved["export"]
	OnlineMain.config = _saved["online_config"]
	OnlineMain.front_hook = _saved["front_hook"]
	OnlineMain.force_interactive = _saved["interactive"]
	OnlineMain.quit_hook = _saved["online_quit"]
	await wait_process_frames(2)


# --- Helpers ----------------------------------------------------------------------------------

func _mount() -> void:
	var packed: PackedScene = load(FRONT_SCENE) as PackedScene
	_front = packed.instantiate() as FrontMain
	tree.root.add_child(_front)


func _wait_until(condition: Callable, max_frames: int = 300) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await wait_process_frames()
	return condition.call()


## Mounts FrontMain and logs in from the title to whichever screen applies.
func _login(remember: bool = false, password: String = "") -> void:
	_mount()
	var title: TitleScreen = _front.get_title_screen()
	assert_true(await _wait_until(func() -> bool: return title.get_status_text() == "En línea · Eld"),
			"the title shows the state: %s" % title.get_status_text())
	var typed: String = password if not password.is_empty() else _platform.password
	title.get_email_edit().text = _platform.email
	title.get_password_edit().text = typed
	title.get_password_edit().text_changed.emit(typed)
	title.get_remember_check().button_pressed = remember
	assert_true(title.try_login())


func _on_select() -> bool:
	return _front.get_current_screen() == _front.get_character_select() \
			and not _front.get_character_select().is_busy()


# --- Tests ------------------------------------------------------------------------------------

func test_login_reaches_the_selection_and_remembers_only_the_email() -> void:
	_platform.make_character("Anéira", "solmarch", 7)
	_platform.make_character("Bruno", "solmarch")
	await _login(true)
	assert_true(await _wait_until(_on_select), "after entering, the selection")
	var select: CharacterSelect = _front.get_character_select()
	assert_eq(select.get_character_count(), 2)
	assert_eq(select.get_selected_id(), AccountFlow.parse_id(_platform.characters[0]["character_id"]))
	assert_true(FrontMain.session != null and FrontMain.session.is_active(), "the session stays for other scenes")
	assert_eq(FrontMain.remembered_email(), _platform.email, "the remembered email")
	var stored: String = FileAccess.get_file_as_string(FrontMain.settings_path)
	assert_true(stored.contains("[account]"), stored)
	assert_false(stored.contains(_platform.password), "the password is never saved")
	assert_false(stored.contains("acceso-"), "nor the tokens")
	assert_eq(_front.get_title_screen().get_password_edit().text, "", "and the field is emptied")


func test_a_wrong_password_stays_on_the_title_with_its_text() -> void:
	await _login(false, "otra-distinta")
	var title: TitleScreen = _front.get_title_screen()
	assert_true(await _wait_until(func() -> bool: return not title.get_notice_text().is_empty()))
	assert_eq(title.get_notice_text(), "Correo o contraseña incorrectos")
	assert_eq(_front.get_current_screen(), title)
	assert_eq(FrontMain.remembered_email(), "", "without \"Recordar correo\" it is not saved")


func test_a_sanctioned_account_only_exports_deletes_or_logs_out() -> void:
	_platform.scope = "privacy"
	_platform.restriction = {"code": "account_banned", "until": null, "reason": "Trampas"}
	await _login()
	var panel: SanctionedPanel = _front.get_sanctioned_panel()
	assert_true(await _wait_until(func() -> bool: return _front.get_current_screen() == panel),
			"the privacy session goes to its screen")
	assert_eq(panel.get_reason_text(), "Cuenta expulsada: Trampas")
	assert_true(_platform.calls_to("/v1/worlds/").is_empty(), "without requesting characters")
	var export := ApiResult.success({"account": {}})
	export.text = "{\"account\": {}}"
	export.headers = PackedStringArray(["Content-Disposition: attachment; filename=\"eldmark-datos-2026-10-30.json\""])
	_platform.script_next("/v1/account/export", export)
	panel.get_password_edit().text = _platform.password
	panel.get_password_edit().text_changed.emit(_platform.password)
	panel.try_export()
	var expected: String = NetHarness.get_build_dir().path_join("eldmark-datos-2026-10-30.json")
	assert_true(await _wait_until(func() -> bool: return panel.get_notice_text().contains(expected)),
			"saved: %s" % panel.get_notice_text())
	assert_eq(FileAccess.get_file_as_string(expected), "{\"account\": {}}")
	assert_eq(_platform.calls_to("/v1/account/export")[0]["body"], {"password": _platform.password})
	DirAccess.remove_absolute(expected)
	_platform.script_next("/v1/account/deletion", ApiResult.success({"purge_at": 1800000000}, 202))
	panel.ask_deletion()
	panel.get_confirm_dialog().confirm()
	assert_true(await _wait_until(func() -> bool: return panel.get_notice_text().begins_with("Tu cuenta se borrará")))
	panel.get_logout_button().pressed.emit()
	assert_true(await _wait_until(func() -> bool: return _front.get_current_screen() == _front.get_title_screen()))
	assert_eq(_platform.calls_to("/v1/sessions/current", HTTPClient.METHOD_DELETE).size(), 1)
	assert_null(FrontMain.session)
	assert_eq(FrontMain.export_file_name("attachment; filename=\"../../etc/passwd\""), "eldmark-datos.json",
			"an odd file name does not escape the folder")


func test_new_texts_are_accepted_before_the_selection() -> void:
	_platform.terms_required = true
	_platform.make_character("Aneira")
	await _login()
	var terms: TermsPanel = _front.get_terms_panel()
	assert_true(await _wait_until(func() -> bool: return _front.get_current_screen() == terms))
	assert_eq(terms.get_documents(), PackedStringArray(["privacy"]))
	terms.text_requested.emit("privacy")
	assert_true(await _wait_until(func() -> bool: return _platform.calls_to("/v1/legal/privacy").size() == 1))
	terms.get_accept_button().pressed.emit()
	assert_true(await _wait_until(_on_select), "accepted, the selection")
	assert_eq(_platform.calls_to("/v1/account/accept")[0]["body"], {"terms": 1, "privacy": 2, "rules": 1},
			"with the current versions from /v1/legal")


func test_enter_goes_online_with_the_ticket_and_from_front() -> void:
	var character: Dictionary = _platform.make_character("Aneira", "solmarch")
	await _login()
	assert_true(await _wait_until(_on_select))
	_front.get_character_select().try_enter()
	assert_true(await _wait_until(func() -> bool: return not _online_configs.is_empty()), "switches to OnlineMain")
	var config: ClientConfig = _online_configs[0]
	assert_true(config.from_front, "with from_front: it comes back here after a rejection")
	assert_eq(config.mode, ClientConfig.Mode.ONLINE)
	assert_eq(config.ticket, _platform.ticket)
	assert_eq(config.character_id, AccountFlow.parse_id(character["character_id"]))
	assert_eq(config.realm, NetProtocol.Realm.SOLMARCH)
	assert_eq(config.display_name, "Aneira")
	assert_eq(OnlineMain.config, config, "the OnlineMain configuration")
	assert_true(FrontMain.session.is_active(), "the session remains so it can go back")


func test_rename_required_opens_the_rename_dialog() -> void:
	var character: Dictionary = _platform.make_character("Admin")
	character["must_rename"] = true
	await _login()
	assert_true(await _wait_until(_on_select))
	_front.get_character_select().try_enter()
	var dialog: RenameDialog = _front.get_rename_dialog()
	assert_true(await _wait_until(dialog.is_open), "rename_required opens the dialog")
	dialog.get_name_edit().text = "Brunilda"
	dialog.get_name_edit().text_changed.emit("Brunilda")
	assert_true(dialog.try_rename())
	assert_true(await _wait_until(func() -> bool: return not dialog.is_open() and _on_select()))
	assert_eq(_platform.calls_to("/v1/characters/%s/rename" % character["character_id"])[0]["body"],
			{"name": "Brunilda"})
	assert_eq(_front.get_character_select().get_notice_text(), "Nombre cambiado")
	assert_eq(_front.get_character_select().get_selected_character().get("name"), "Brunilda")
	assert_true(_online_configs.is_empty(), "it does not enter until Enter (\"Entrar\") is pressed again")


func test_a_busy_character_shows_the_countdown_and_then_enters() -> void:
	_platform.make_character("Aneira")
	_platform.busy_answers = 2
	await _login()
	assert_true(await _wait_until(_on_select))
	_front.get_flow().busy_retry_s = 0.2
	var select: CharacterSelect = _front.get_character_select()
	select.try_enter()
	assert_true(await _wait_until(select.is_waiting), "the countdown")
	assert_true(select.get_waiting_text().begins_with("Tu personaje está saliendo del mundo… ("),
			select.get_waiting_text())
	assert_true(await _wait_until(func() -> bool: return not _online_configs.is_empty()), "and it enters once free")
	assert_false(select.is_waiting())


func test_create_delete_and_restore_from_the_selection() -> void:
	_platform.make_character("Bruno", "solmarch")
	await _login()
	assert_true(await _wait_until(_on_select))
	var select: CharacterSelect = _front.get_character_select()
	select.get_create_button().pressed.emit()
	var create: CharacterCreate = _front.get_character_create()
	assert_eq(_front.get_current_screen(), create)
	assert_eq(create.get_realm(), &"solmarch", "the account's realm")
	assert_true(create.next() and create.next() and create.next())
	create.set_name_text("Bruno")
	create.flush_name_check()
	assert_true(await _wait_until(func() -> bool: return create.get_name_reason_text() == "Ese nombre ya está en uso"),
			"name-check: %s" % create.get_name_reason_text())
	create.set_name_text("Aneira")
	create.flush_name_check()
	assert_true(await _wait_until(func() -> bool: return create.get_name_reason_text() == "Nombre libre"))
	assert_true(create.try_create())
	assert_true(await _wait_until(func() -> bool: return _on_select() and select.get_character_count() == 2))
	assert_eq(select.get_selected_character().get("name"), "Aneira", "selects the new one")
	assert_eq(select.get_notice_text(), "Personaje creado")
	var body: Dictionary = _platform.calls_to("/v1/worlds/1/characters", HTTPClient.METHOD_POST)[0]["body"]
	assert_eq(body.get("realm"), "solmarch")
	assert_eq(body.get("race_id"), "race_solmarch")
	assert_eq(body.get("starter_template_id"), "marksman")
	assert_eq(AccountFlow.decode_base64(body.get("appearance")).size(), 8)
	var id: int = select.get_selected_id()
	select.ask_delete()
	select.get_delete_edit().text = "ANEIRA"
	select.get_delete_edit().text_changed.emit("ANEIRA")
	assert_true(select.confirm_delete())
	assert_true(await _wait_until(func() -> bool: return _on_select() and select.is_selected_deleted()))
	assert_eq(select.get_selected_id(), id, "still selected, now deleted")
	assert_eq(select.get_notice_text(), FrontMain.TEXT_DELETED)
	select.try_restore()
	assert_true(await _wait_until(func() -> bool: return _on_select() and not select.is_selected_deleted()))
	assert_eq(select.get_notice_text(), "Personaje restaurado")


func test_logout_and_a_lost_session_go_back_to_the_title() -> void:
	await _login()
	assert_true(await _wait_until(_on_select))
	_front.get_character_select().get_logout_button().pressed.emit()
	assert_true(await _wait_until(func() -> bool: return _front.get_current_screen() == _front.get_title_screen()))
	assert_null(FrontMain.session)
	assert_false(_front.get_api().session.is_active())
	_front.get_title_screen().get_password_edit().text = _platform.password
	_front.get_title_screen().get_password_edit().text_changed.emit(_platform.password)
	assert_true(_front.get_title_screen().try_login())
	assert_true(await _wait_until(_on_select))
	_front.get_api().session_lost.emit("unauthorized")
	assert_eq(_front.get_current_screen(), _front.get_title_screen())
	assert_eq(_front.get_title_screen().get_notice_text(), FrontMain.TEXT_SESSION_LOST)


func test_registration_logs_in_only_against_a_local_platform() -> void:
	_platform.make_character("Aneira")
	_mount()
	assert_true(_front.is_dev_platform())
	_front.get_title_screen().register_requested.emit()
	var register: RegisterPanel = _front.get_register_panel()
	assert_eq(_front.get_current_screen(), register)
	assert_true(await _wait_until(register.has_legal_versions), "with the versions from /v1/legal")
	register.get_email_edit().text = _platform.email
	register.get_password_edit().text = _platform.password
	register.get_repeat_edit().text = _platform.password
	register.get_age_check().button_pressed = true
	for kind: String in RegisterPanel.KINDS:
		register.get_accept_check(kind).button_pressed = true
	assert_true(register.try_submit(), register.get_hint_text())
	assert_true(await _wait_until(_on_select), "in development, it logs in with what was typed")
	assert_eq(_platform.calls_to("/v1/sessions", HTTPClient.METHOD_POST).size(), 1)
	_front.get_parent().remove_child(_front)
	_front.free()
	FrontMain.session = null
	FrontMain.config.platform_url = "https://cuentas.eldmark.example"
	_platform.calls.clear()
	_mount()
	assert_false(_front.is_dev_platform())
	_front.get_title_screen().register_requested.emit()
	register = _front.get_register_panel()
	assert_true(await _wait_until(register.has_legal_versions))
	register.get_email_edit().text = _platform.email
	register.get_password_edit().text = _platform.password
	register.get_repeat_edit().text = _platform.password
	register.get_age_check().button_pressed = true
	for kind: String in RegisterPanel.KINDS:
		register.get_accept_check(kind).button_pressed = true
	assert_true(register.try_submit())
	var title: TitleScreen = _front.get_title_screen()
	assert_true(await _wait_until(func() -> bool: return _front.get_current_screen() == title))
	assert_eq(title.get_notice_text(), RegisterPanel.TEXT_SENT)
	assert_true(_platform.calls_to("/v1/sessions").is_empty(),
			"off this machine it does not log in: it would reveal whether the email already had an account")


func test_coming_back_from_the_world_shows_the_reason_on_the_selection() -> void:
	_platform.make_character("Aneira")
	FrontMain.session = AccountSession.from_login({"access_token": "acceso-1", "access_expires_in": 900,
			"refresh_token": "refresco-1", "refresh_expires_in": 43200, "scope": "game"}, Time.get_ticks_msec())
	FrontMain.return_notice = "Conexión rechazada: Tu personaje sigue en el mundo: espera unos segundos"
	_mount()
	assert_eq(_front.get_current_screen(), _front.get_character_select(), "with a session, straight to the selection")
	assert_eq(_front.get_character_select().get_notice_text(), "Conexión rechazada: Tu personaje sigue en el mundo: espera unos segundos")
	assert_eq(FrontMain.return_notice, "", "the reason is shown once")
	assert_true(await _wait_until(func() -> bool: return _front.get_character_select().get_character_count() == 1))


func test_online_main_from_front_returns_to_the_selection_with_the_reason() -> void:
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.ONLINE
	config.address = "127.0.0.1"
	config.port = NetHarness.free_udp_port()
	config.realm = NetProtocol.Realm.VARDHEIM
	config.display_name = "Aneira"
	config.character_id = 5
	config.ticket = PackedByteArray(range(52))
	config.from_front = true
	OnlineMain.config = config
	OnlineMain.force_interactive = true
	OnlineMain.quit_hook = func(code: int) -> void: _quits.append(code)
	OnlineMain.front_hook = func(notice: String) -> void: _front_notices.append(notice)
	var packed: PackedScene = load(ONLINE_MAIN_SCENE) as PackedScene
	_online = packed.instantiate() as OnlineMain
	_online.get_node(^"ClientServices").free()
	tree.root.add_child(_online)
	assert_null(_online.get_realm_select(), "with a ticket there is no realm choice")
	assert_true(await _wait_until(func() -> bool: return not _front_notices.is_empty(), 1500),
			"a failure goes back to FrontMain")
	assert_true(_front_notices[0].begins_with("No se pudo conectar con el servidor"), _front_notices[0])
	assert_eq(FrontMain.return_notice, _front_notices[0], "with the reason for the selection")
	assert_null(_online.get_realm_select(), "and never to the realm choice")
	assert_true(_quits.is_empty(), "without closing the process")
