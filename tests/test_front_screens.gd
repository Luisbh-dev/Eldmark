extends TestCase
## Pruebas de las pantallas de la cuenta con datos falsos (docs/plataforma.md §13.2 y §15 P8): el título (Entrar solo
## con correo y contraseña, el estado del servicio, el panel de recuperar), crear cuenta (la contraseña, la edad y
## los tres textos), los textos nuevos, la cuenta sancionada, la selección (nombres, huecos, Entrar desactivado sin
## personaje, borrar escribiendo el nombre, restaurar, teclado), la creación (reino fijado, apariencia, plantilla y
## nombre) y el renombrado. Las pantallas no llaman a la red: se comprueban sus señales.

var _screen: Control


func after_each() -> void:
	if is_instance_valid(_screen):
		_screen.get_parent().remove_child(_screen)
		_screen.free()
	_screen = null
	await wait_process_frames()


func _mount(screen: Control) -> void:
	_screen = screen
	tree.root.add_child(screen)


func _action(action: StringName) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	return event


func _character(id: String, display_name: String, realm: String, level: int, deleted: bool = false,
		appearance: PackedByteArray = PackedByteArray()) -> Dictionary:
	return {"character_id": id, "name": display_name, "realm": realm, "race_id": "race_%s" % realm,
			"appearance": Marshalls.raw_to_base64(appearance) if not appearance.is_empty() else null,
			"level": level, "last_zone_id": "vado_gris" if level > 1 else null, "played_seconds": 0,
			"created_at": 1800000000, "deleted_at": 1800000500 if deleted else null,
			"restore_until": 1800600000 if deleted else null, "must_rename": false}


# --- Título ---------------------------------------------------------------------------------------

func test_title_enters_only_with_email_and_password() -> void:
	var title := TitleScreen.new()
	_mount(title)
	var logins: Array[Array] = []
	title.login_requested.connect(func(email: String, password: String, remember: bool) -> void:
		logins.append([email, password, remember]))
	assert_true(title.get_enter_button().disabled, "sin nada escrito, Entrar desactivado")
	title.get_email_edit().text = "  ana@eldmark.test "
	title.get_email_edit().text_changed.emit(title.get_email_edit().text)
	assert_true(title.get_enter_button().disabled, "falta la contraseña")
	assert_false(title.try_login())
	title.get_password_edit().text = "secreto"
	title.get_password_edit().text_changed.emit("secreto")
	assert_false(title.get_enter_button().disabled)
	title.get_remember_check().button_pressed = true
	title.get_password_edit().text_submitted.emit("secreto")
	assert_eq(logins, [["ana@eldmark.test", "secreto", true]], "Intro entra, con el correo sin espacios")
	assert_true(title.get_password_edit().secret, "la contraseña no se ve")
	title.set_busy(true)
	assert_false(title.try_login(), "ocupado no vuelve a entrar")
	assert_true(title.get_enter_button().disabled)
	title.set_busy(false)
	title.clear_password()
	assert_true(title.get_enter_button().disabled, "sin contraseña otra vez")
	title.set_remembered_email("bea@eldmark.test")
	assert_eq(title.get_email_edit().text, "bea@eldmark.test")
	assert_true(title.get_remember_check().button_pressed)


func test_title_status_news_and_the_recovery_panel() -> void:
	var title := TitleScreen.new()
	_mount(title)
	title.set_status({"status": "ok", "worlds": [{"world_id": 1, "name": "Eld", "status": "ok", "load": "low"}],
			"news": [{"title": "Pruebas cerradas", "body": "El sábado", "date": 1800000000}]})
	assert_eq(title.get_status_text(), "En línea · Eld")
	assert_true(TitleScreen.status_text({"status": "maintenance", "maintenance_at": 1800000000})
			.begins_with("En mantenimiento hasta las "))
	assert_eq(TitleScreen.status_text({"status": "maintenance", "maintenance_at": null}), "En mantenimiento")
	title.set_status({})
	assert_eq(title.get_status_text(), "Sin conexión con el servidor")
	var forgot: Array[String] = []
	title.forgot_requested.connect(func(email: String) -> void: forgot.append(email))
	title.get_email_edit().text = "ana@eldmark.test"
	title.open_forgot()
	assert_true(title.is_forgot_open())
	assert_eq(title.get_forgot_email_edit().text, "ana@eldmark.test", "con el correo escrito")
	title._unhandled_key_input(_action(&"ui_cancel"))
	assert_false(title.is_forgot_open(), "Esc cierra el panel")
	title.open_forgot()
	assert_true(title.try_forgot())
	assert_eq(forgot, ["ana@eldmark.test"])
	title.show_forgot_sent()
	assert_false(title.is_forgot_open())
	assert_eq(title.get_notice_text(), "Si existe una cuenta, te hemos enviado un enlace")


# --- Crear cuenta y textos --------------------------------------------------------------------------

func test_register_needs_the_password_the_age_and_the_three_texts() -> void:
	var register := RegisterPanel.new()
	_mount(register)
	var bodies: Array[Dictionary] = []
	register.submitted.connect(func(body: Dictionary) -> void: bodies.append(body))
	register.reset("Ana@Eldmark.test")
	assert_true(register.get_submit_button().disabled)
	var steps: Array[Callable] = [
		func() -> void: register.get_password_edit().text = "corta",
		func() -> void: register.get_password_edit().text = "una contraseña larga",
		func() -> void: register.get_repeat_edit().text = "una contraseña larga",
		func() -> void: register.get_age_check().button_pressed = true,
		func() -> void:
			for kind: String in RegisterPanel.KINDS:
				register.get_accept_check(kind).button_pressed = true,
		func() -> void: register.set_legal_versions({"terms": {"version": 1}, "privacy": {"version": 2.0},
				"rules": {"version": 1}}),
	]
	var hints: Array[String] = [RegisterPanel.TEXT_SHORT, RegisterPanel.TEXT_MISMATCH, RegisterPanel.TEXT_AGE,
			RegisterPanel.TEXT_ACCEPT, RegisterPanel.TEXT_NO_LEGAL, ""]
	for i: int in range(steps.size()):
		steps[i].call()
		register.get_password_edit().text_changed.emit(register.get_password_edit().text)
		assert_eq(register.get_hint_text(), hints[i], "paso %d" % i)
		assert_eq(register.get_submit_button().disabled, i < steps.size() - 1, "Crear cuenta en el paso %d" % i)
	for check: CheckBox in register.get_consent_checks():
		assert_false(check.button_pressed, "los consentimientos van desmarcados")
	assert_true(register.try_submit())
	if not assert_eq(bodies.size(), 1):
		return
	assert_eq(bodies[0], {"email": "ana@eldmark.test", "password": "una contraseña larga", "age_confirmed": true,
			"accept": {"terms": 1, "privacy": 2, "rules": 1},
			"consents": {"crash_reports": false, "analytics": false}}, "el cuerpo de POST /v1/accounts")
	register.get_password_edit().text = "ana@eldmark.test"
	register.get_repeat_edit().text = "ana@eldmark.test"
	register.get_password_edit().text_changed.emit("")
	assert_eq(register.get_hint_text(), RegisterPanel.TEXT_SAME_AS_EMAIL)
	var asked: Array[String] = []
	register.text_requested.connect(func(kind: String) -> void: asked.append(kind))
	(register.find_child("Leer_privacy", true, false) as Button).pressed.emit()
	assert_eq(asked, ["privacy"], "el enlace pide el texto")
	register.show_text("privacy", "# Privacidad")
	assert_eq(register.get_shown_text(), "# Privacidad")


func test_terms_panel_lists_the_changed_texts() -> void:
	var terms := TermsPanel.new()
	_mount(terms)
	terms.set_documents(PackedStringArray(["privacy"]))
	assert_eq(terms.get_documents(), PackedStringArray(["privacy"]))
	assert_not_null(terms.find_child("Leer_privacy", true, false))
	var accepted: Array[bool] = []
	var logouts: Array[bool] = []
	terms.accepted.connect(func() -> void: accepted.append(true))
	terms.logout_requested.connect(func() -> void: logouts.append(true))
	terms.get_accept_button().pressed.emit()
	terms._unhandled_key_input(_action(&"ui_cancel"))
	assert_eq(accepted, [true])
	assert_eq(logouts, [true], "Esc cierra sesión")


func test_sanctioned_account_only_exports_deletes_or_logs_out() -> void:
	var panel := SanctionedPanel.new()
	_mount(panel)
	panel.set_restriction({"code": "account_suspended", "until": 1800000000, "reason": "Insultos"})
	assert_true(panel.get_reason_text().begins_with("Cuenta suspendida hasta el "), panel.get_reason_text())
	assert_true(panel.get_reason_text().ends_with(": Insultos"))
	assert_true(panel.get_export_button().disabled, "sin contraseña no se descarga")
	assert_true(panel.get_delete_button().disabled)
	var exports: Array[String] = []
	var deletions: Array[String] = []
	panel.export_requested.connect(func(password: String) -> void: exports.append(password))
	panel.deletion_requested.connect(func(password: String) -> void: deletions.append(password))
	panel.get_password_edit().text = "secreto"
	panel.get_password_edit().text_changed.emit("secreto")
	assert_false(panel.get_export_button().disabled)
	panel.get_export_button().pressed.emit()
	assert_eq(exports, ["secreto"])
	panel.get_delete_button().pressed.emit()
	assert_true(panel.get_confirm_dialog().is_open(), "borrar pide confirmación")
	assert_true(deletions.is_empty())
	panel.get_confirm_dialog().confirm()
	assert_eq(deletions, ["secreto"])
	panel.show_deletion(1800000000)
	assert_true(panel.get_notice_text().begins_with("Tu cuenta se borrará el "))
	panel.set_restriction({"code": "account_banned", "until": null, "reason": "Trampas"})
	assert_eq(panel.get_reason_text(), "Cuenta expulsada: Trampas")


# --- Selección ------------------------------------------------------------------------------------

func _select_data() -> Dictionary:
	var appearance: CharacterAppearance = CharacterAppearance.default_for(AppearanceCatalog.shared(),
			AppearanceCatalog.shared().race_index(&"race_solmarch"))
	appearance.skin = 3
	return {"realm": "solmarch", "unlock_at": null, "slots": 6, "used": 3, "characters": [
		_character("11", "Anéira", "solmarch", 7, false, appearance.encode()),
		_character("12", "Bruno", "solmarch", 1),
		_character("13", "Ciro", "solmarch", 3, true),
	]}


func test_select_lists_the_characters_and_the_free_slots() -> void:
	var select := CharacterSelect.new()
	_mount(select)
	select.set_data(_select_data())
	assert_eq(select.get_character_count(), 3)
	var buttons: Array[Button] = select.get_entry_buttons()
	assert_true(buttons[0].text.begins_with("Anéira\nNivel 7 · Vado Gris"), buttons[0].text)
	assert_true(buttons[1].text.ends_with("Nivel 1 · Sin entrar aún"), buttons[1].text)
	assert_true(buttons[2].text.contains("Borrado · se puede restaurar hasta el "), buttons[2].text)
	assert_true(buttons[2].modulate.r < 1.0, "el borrado, en gris")
	assert_eq(select.get_slots_text(), "Huecos libres: 3 de 6", "los borrados en plazo ocupan hueco")
	assert_eq(select.get_selected_id(), 11, "elige el primero vivo")
	var shown: CharacterAppearance = select.get_figure().get_appearance()
	if assert_not_null(shown, "la figura enseña su apariencia"):
		assert_eq(shown.skin, 3, "la suya, no la de por defecto")
	select.select_index(1)
	assert_eq(select.get_figure().get_appearance().encode(), AccountFlow.default_appearance(&"solmarch"),
			"sin apariencia, la de por defecto de su pueblo")
	assert_false(select.get_enter_button().disabled)
	select.select_index(2)
	assert_true(select.is_selected_deleted())
	assert_true(select.get_enter_button().disabled, "un borrado no entra")
	assert_true(select.get_restore_button().visible)
	assert_false(select.get_delete_button().visible)
	var restores: Array[int] = []
	select.restore_requested.connect(func(id: int) -> void: restores.append(id))
	select.get_restore_button().pressed.emit()
	assert_eq(restores, [13])
	var full: Dictionary = _select_data()
	full["used"] = 6
	select.set_data(full)
	assert_true(select.get_create_button().disabled, "sin huecos no se crea")
	assert_eq(select.get_selected_id(), 13, "la elección se conserva al recargar")


func test_enter_is_disabled_without_a_character() -> void:
	var select := CharacterSelect.new()
	_mount(select)
	select.set_data({"realm": null, "unlock_at": null, "slots": 6, "used": 0, "characters": []})
	assert_eq(select.get_selected_index(), -1)
	assert_true(select.get_enter_button().disabled, "Entrar desactivado sin personaje")
	assert_true(select.get_delete_button().disabled)
	assert_false(select.get_create_button().disabled, "pero se puede crear")
	assert_false(select.try_enter())
	var entered: Array[int] = []
	select.enter_requested.connect(func(id: int) -> void: entered.append(id))
	select._unhandled_key_input(_action(&"ui_accept"))
	assert_true(entered.is_empty(), "Intro no hace nada")


func test_delete_needs_the_name_typed() -> void:
	var select := CharacterSelect.new()
	_mount(select)
	select.set_data(_select_data())
	var deletions: Array[Array] = []
	select.delete_requested.connect(func(id: int, typed: String) -> void: deletions.append([id, typed]))
	select.ask_delete()
	assert_true(select.is_delete_open())
	assert_true(select.get_delete_confirm_button().disabled, "sin escribir el nombre no se borra")
	for wrong: String in ["", "Anei", "Bruno"]:
		select.get_delete_edit().text = wrong
		select.get_delete_edit().text_changed.emit(wrong)
		assert_true(select.get_delete_confirm_button().disabled, "«%s» no es el nombre" % wrong)
		assert_false(select.confirm_delete())
	select.get_delete_edit().text = "aneira"
	select.get_delete_edit().text_changed.emit("aneira")
	assert_false(select.get_delete_confirm_button().disabled, "la clave de NameRules: sin tildes ni mayúsculas")
	select.get_delete_confirm_button().pressed.emit()
	assert_eq(deletions, [[11, "aneira"]], "se manda lo escrito, que la plataforma compara igual")
	assert_false(select.is_delete_open())
	select.select_index(2)
	select.ask_delete()
	assert_false(select.is_delete_open(), "un borrado no se vuelve a borrar")


func test_select_keyboard_and_waiting() -> void:
	var select := CharacterSelect.new()
	_mount(select)
	select.set_data(_select_data())
	var entered: Array[int] = []
	select.enter_requested.connect(func(id: int) -> void: entered.append(id))
	select._unhandled_key_input(_action(&"ui_down"))
	assert_eq(select.get_selected_id(), 12, "flecha abajo")
	select._unhandled_key_input(_action(&"ui_up"))
	assert_eq(select.get_selected_id(), 11, "flecha arriba")
	select._unhandled_key_input(_action(&"ui_accept"))
	assert_eq(entered, [11], "Intro entra")
	var delete_key := InputEventKey.new()
	delete_key.keycode = KEY_DELETE
	delete_key.pressed = true
	select._unhandled_key_input(delete_key)
	assert_true(select.is_delete_open(), "Supr borra")
	select._unhandled_key_input(_action(&"ui_cancel"))
	assert_false(select.is_delete_open(), "y Esc cierra la confirmación")
	select.show_waiting(27)
	assert_eq(select.get_waiting_text(), "Tu personaje está saliendo del mundo… (27 s)")
	select._unhandled_key_input(_action(&"ui_accept"))
	assert_eq(entered, [11], "mientras espera no se vuelve a entrar")
	select.show_waiting(-1)
	assert_false(select.is_waiting())
	select.set_busy(true)
	assert_true(select.get_enter_button().disabled and select.get_create_button().disabled)
	assert_true(select.get_logout_button().disabled)


# --- Creación -------------------------------------------------------------------------------------

func test_create_fixes_the_realm_of_the_account_and_askarra_is_coming_soon() -> void:
	var create := CharacterCreate.new()
	_mount(create)
	create.setup(&"solmarch")
	assert_eq(create.get_realm(), &"solmarch", "fijado al de la cuenta")
	assert_true(create.get_realm_button(&"vardheim").disabled)
	assert_true(create.get_realm_button(&"askarra").disabled)
	assert_true(create.get_realm_button(&"askarra").text.contains("Próximamente"))
	assert_true(create.get_realm_button(&"solmarch").text.contains("Valcorin"), "con su capital")
	assert_false(create.select_realm(&"vardheim"))
	create.setup(&"")
	assert_eq(create.get_realm(), &"", "una cuenta nueva elige")
	assert_false(create.get_realm_button(&"vardheim").disabled)
	assert_true(create.get_realm_button(&"askarra").disabled, "Askarra sigue sin abrir")
	assert_true(create.get_next_button().disabled, "sin reino no se avanza")
	assert_false(create.next())
	assert_true(create.select_realm(&"vardheim"))
	assert_true(create.next())
	assert_eq(create.get_step(), CharacterCreate.Step.APPEARANCE)


func test_create_appearance_stays_valid_for_the_people() -> void:
	var create := CharacterCreate.new()
	_mount(create)
	create.setup(&"")
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	for realm: StringName in [&"vardheim", &"solmarch"]:
		create.select_realm(realm)
		var code: int = RealmCatalog.code_of(realm)
		var race: StringName = AccountFlow.race_id_for(realm)
		assert_true(create.get_appearance().validate(catalog, code, race), "la de por defecto de %s" % realm)
		for field: StringName in CharacterCreate.FIELDS:
			for _i: int in range(4):
				create.cycle(field, 1)
				assert_true(create.get_appearance().validate(catalog, code, race),
						"%s tras cambiar %s: %s" % [realm, field, create.get_appearance()])
			create.cycle(field, -1)
			assert_true(create.get_appearance().validate(catalog, code, race))
		for _i: int in range(50):
			create.randomize_appearance()
			assert_true(create.get_appearance().validate(catalog, code, race), "aleatoria de %s" % realm)
		assert_true(create.get_figure().get_appearance().equals(create.get_appearance()), "la figura la enseña")
	create.select_realm(&"solmarch")
	assert_eq(create.options_for(&"hair")[0], CharacterAppearance.NONE, "Solmarch admite ir sin pelo")
	create.select_realm(&"vardheim")
	assert_false(create.options_for(&"hair").has(CharacterAppearance.NONE), "Vardheim no")
	create.cycle(&"hair", 1)
	assert_ne_text(create.get_field_text(&"skin"), "—")


func assert_ne_text(text: String, unwanted: String) -> void:
	assert_true(text != unwanted and not text.is_empty(), "«%s»" % text)


func test_create_template_and_name_steps() -> void:
	var create := CharacterCreate.new()
	_mount(create)
	create.setup(&"vardheim")
	var bodies: Array[Dictionary] = []
	var checks: Array[String] = []
	var canceled: Array[bool] = []
	create.create_requested.connect(func(body: Dictionary) -> void: bodies.append(body))
	create.name_check_requested.connect(func(display_name: String) -> void: checks.append(display_name))
	create.canceled.connect(func() -> void: canceled.append(true))
	assert_true(create.next())
	assert_true(create.next(), "la apariencia por defecto vale")
	assert_eq(create.get_step(), CharacterCreate.Step.TEMPLATE)
	assert_eq(create.get_template_ids(), [&"marksman", &"squire"], "las plantillas de starter_templates")
	assert_eq(create.get_template(), &"marksman", "marcada la primera por id")
	assert_true(create.get_template_button(&"marksman").text.contains("Arco"), create.get_template_button(
			&"marksman").text)
	assert_true(create.select_template(&"squire"))
	assert_false(create.select_template(&"rompefilas"))
	assert_true(create.next())
	assert_eq(create.get_step(), CharacterCreate.Step.NAME)
	assert_true(create.get_create_button().disabled, "sin nombre no se crea")
	create.set_name_text("ana maria")
	assert_eq(create.get_name_reason_text(), NameRules.reason_text(NameRules.validate("ana maria")))
	assert_true(create.get_create_button().disabled)
	create.set_name_text("Aneira")
	assert_eq(create.get_name_reason_text(), "Comprobando el nombre…")
	create.flush_name_check()
	assert_eq(checks, ["Aneira"], "name-check tras 500 ms quieto")
	create.set_name_check("Aneira", false, "Ese nombre ya está en uso")
	assert_true(create.get_create_button().disabled, "ocupado no se crea")
	assert_eq(create.get_name_reason_text(), "Ese nombre ya está en uso")
	create.set_name_text("Aneiro")
	create.set_name_check("Aneira", true)
	assert_eq(create.get_name_reason_text(), "Comprobando el nombre…", "una respuesta vieja no cuenta")
	create.set_name_check("Aneiro", true)
	assert_eq(create.get_name_reason_text(), "Nombre libre")
	assert_false(create.get_create_button().disabled)
	assert_true(create.try_create())
	if assert_eq(bodies.size(), 1):
		var body: Dictionary = bodies[0]
		assert_eq(body["name"], "Aneiro")
		assert_eq(body["realm"], &"vardheim")
		assert_eq(body["race_id"], &"race_vardheim")
		assert_eq(body["starter_template_id"], &"squire")
		assert_eq((body["appearance"] as PackedByteArray).size(), 8)
	create.show_name_error("Ese nombre ya está en uso")
	assert_true(create.get_create_button().disabled, "un name_taken de la plataforma lo bloquea")
	create._unhandled_key_input(_action(&"ui_cancel"))
	assert_eq(create.get_step(), CharacterCreate.Step.TEMPLATE, "Esc vuelve un paso")
	create.back()
	create.back()
	assert_eq(create.get_step(), CharacterCreate.Step.REALM)
	assert_true(canceled.is_empty())
	create.back()
	assert_eq(canceled, [true], "en el primer paso, vuelve a la selección")


# --- Renombrar ------------------------------------------------------------------------------------

func test_rename_dialog_validates_the_new_name() -> void:
	var dialog := RenameDialog.new()
	_mount(dialog)
	var renames: Array[Array] = []
	dialog.rename_requested.connect(func(id: int, display_name: String) -> void: renames.append([id, display_name]))
	dialog.open(11, "Admin")
	assert_true(dialog.is_open())
	assert_true(dialog.get_confirm_button().disabled)
	dialog.get_name_edit().text = "Bo"
	dialog.get_name_edit().text_changed.emit("Bo")
	assert_eq(dialog.get_reason_text(), NameRules.reason_text(NameRules.Reason.TOO_SHORT))
	assert_false(dialog.try_rename())
	dialog.get_name_edit().text = "Brunilda"
	dialog.get_name_edit().text_changed.emit("Brunilda")
	assert_false(dialog.get_confirm_button().disabled)
	dialog.get_confirm_button().pressed.emit()
	assert_eq(renames, [[11, "Brunilda"]])
	dialog.set_error("Ese nombre ya está en uso")
	assert_eq(dialog.get_reason_text(), "Ese nombre ya está en uso")
	dialog.cancel()
	assert_false(dialog.is_open())
