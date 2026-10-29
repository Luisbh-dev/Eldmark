extends TestCase
## Pruebas de la ventana de ajustes ([SettingsMenu], UI-16) y de [ClientServices], que la abre con F10
## y aplica los ajustes en vivo y al arrancar: los controles reflejan y cambian los ajustes, restaurar
## pestaña y todo, guardado al cerrar, cada valor aplicado al motor, a las cámaras, a las luces y al
## audio, y el sandbox ([ClientMain]) con su F10.
## [br][br]
## Los ajustes de la prueba viven en un archivo temporal y se restauran el motor y el audio al terminar.

const TEST_PATH: String = "user://test_settings_menu.cfg"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const CLIENT_MAIN_SCENE: String = "res://scenes/client/client_main.tscn"

var _nodes: Array[Node] = []
var _settings: ClientSettings = null
var _saved_fps: int = 0
var _saved_scale: float = 1.0
var _saved_msaa: Viewport.MSAA = Viewport.MSAA_DISABLED
var _saved_screen_aa: Viewport.ScreenSpaceAA = Viewport.SCREEN_SPACE_AA_DISABLED
var _saved_client: Dictionary = {}


func before_each() -> void:
	InputBindings.ensure_defaults()
	UISounds.reset()
	_saved_fps = Engine.max_fps
	_saved_scale = tree.root.scaling_3d_scale
	_saved_msaa = tree.root.msaa_3d
	_saved_screen_aa = tree.root.screen_space_aa
	_saved_client = {"zone_id": ClientMain.zone_id, "realm": ClientMain.realm,
			"demo_mode": ClientMain.demo_mode, "shots_dir": ClientMain.shots_dir,
			"quit_after_demo": ClientMain.quit_after_demo}
	_remove_file()
	_settings = ClientSettings.load_from(TEST_PATH)
	ClientSettings.set_current(_settings)


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	Engine.max_fps = _saved_fps
	tree.root.scaling_3d_scale = _saved_scale
	tree.root.msaa_3d = _saved_msaa
	tree.root.screen_space_aa = _saved_screen_aa
	ClientSettings.apply_shadows(tree.root, ClientSettings.SHADOWS_HIGH)
	AudioBuses.reset_volumes()
	ClientSettings.set_current(null)
	_settings = null
	ClientMain.zone_id = _saved_client["zone_id"]
	ClientMain.realm = _saved_client["realm"]
	ClientMain.demo_mode = _saved_client["demo_mode"]
	ClientMain.shots_dir = _saved_client["shots_dir"]
	ClientMain.quit_after_demo = _saved_client["quit_after_demo"]
	UISounds.reset()
	_remove_file()
	await wait_process_frames(2)


func _remove_file() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(TEST_PATH)


func _add(node: Node) -> Node:
	tree.root.add_child(node)
	_nodes.append(node)
	return node


func _make_menu(with_confirm: bool = false) -> SettingsMenu:
	var menu: SettingsMenu = SettingsMenu.new()
	_add(menu)
	var confirm: UIConfirmDialog = null
	if with_confirm:
		confirm = _add(UIConfirmDialog.new()) as UIConfirmDialog
	menu.setup(_settings, confirm)
	return menu


func _press(key: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	tree.root.push_input(event)


# --- La ventana -------------------------------------------------------------------------------

func test_the_menu_has_a_tab_per_group_and_a_control_per_setting() -> void:
	var menu: SettingsMenu = _make_menu()
	assert_eq(menu.window_title, "Ajustes")
	assert_eq(menu.get_tabs().get_tab_count(), 4)
	var names: Array[String] = []
	for index: int in 4:
		names.append(menu.get_tabs().get_tab_title(index))
	assert_eq(names, ["Gráficos", "Audio", "Cámara", "Interfaz"] as Array[String])
	for spec: Dictionary in ClientSettings.get_schema():
		var id: StringName = spec["id"]
		var control: Control = menu.get_control(id)
		if not assert_not_null(control, "hay un control para %s" % id):
			continue
		match int(spec["kind"]):
			ClientSettings.Kind.BOOL:
				assert_true(control is CheckButton, "%s es un interruptor" % id)
			ClientSettings.Kind.CHOICE:
				assert_true(control is OptionButton, "%s es una lista" % id)
				assert_eq((control as OptionButton).item_count, (spec["labels"] as Array).size())
			_:
				assert_true(control is HSlider, "%s es un deslizador" % id)
				assert_eq((control as HSlider).min_value, float(spec["min"]))
				assert_eq((control as HSlider).max_value, float(spec["max"]))
				assert_not_null(menu.get_value_label(id), "con su valor al lado")
		# El control vive en la página de su pestaña.
		var page: Node = menu.get_tabs().get_child(ClientSettings.TABS.find(spec["tab"]))
		assert_true(page.is_ancestor_of(control), "%s está en su pestaña" % id)
	assert_null(menu.get_control(&"no_existe"))
	assert_null(menu.get_value_label(ClientSettings.INVERT_Y), "un interruptor no tiene texto de valor")
	assert_eq(menu.get_current_tab_id(), ClientSettings.TAB_GRAPHICS)
	menu.show_tab(ClientSettings.TAB_AUDIO)
	assert_eq(menu.get_current_tab_id(), ClientSettings.TAB_AUDIO)
	menu.show_tab(&"inventada")
	assert_eq(menu.get_current_tab_id(), ClientSettings.TAB_AUDIO)
	assert_eq(menu.get_settings(), _settings)


func test_the_controls_start_at_the_current_values() -> void:
	_settings.set_value(ClientSettings.FOV, 95.0)
	_settings.set_value(ClientSettings.INVERT_Y, true)
	_settings.set_value(ClientSettings.FPS_LIMIT, 144)
	_settings.set_value(ClientSettings.WINDOW_MODE, ClientSettings.MODE_FULLSCREEN)
	_settings.set_value(ClientSettings.volume_id(AudioBuses.MUSIC), 0.25)
	var menu: SettingsMenu = _make_menu()
	assert_eq((menu.get_control(ClientSettings.FOV) as HSlider).value, 95.0)
	assert_eq(menu.get_value_label(ClientSettings.FOV).text, "95°")
	assert_true((menu.get_control(ClientSettings.INVERT_Y) as CheckButton).button_pressed)
	var fps: OptionButton = menu.get_control(ClientSettings.FPS_LIMIT) as OptionButton
	assert_eq(fps.get_item_text(fps.selected), "144 FPS")
	var music: HSlider = menu.get_control(ClientSettings.volume_id(AudioBuses.MUSIC)) as HSlider
	assert_near(music.value, 0.25, 0.0001)
	assert_eq(menu.get_value_label(ClientSettings.volume_id(AudioBuses.MUSIC)).text, "25 %")
	var resolution: OptionButton = menu.get_control(ClientSettings.RESOLUTION) as OptionButton
	assert_true(resolution.disabled, "la resolución solo vale en modo ventana")
	_settings.set_value(ClientSettings.WINDOW_MODE, ClientSettings.MODE_WINDOWED)
	assert_false(resolution.disabled, "y vuelve al elegir ventana")


func test_changing_a_control_changes_the_setting() -> void:
	var menu: SettingsMenu = _make_menu()
	var changed: Array[StringName] = []
	menu.setting_changed.connect(func(id: StringName) -> void: changed.append(id))
	(menu.get_control(ClientSettings.FOV) as HSlider).value = 88.0
	assert_eq(_settings.get_value(ClientSettings.FOV), 88.0)
	assert_eq(menu.get_value_label(ClientSettings.FOV).text, "88°")
	assert_true(_settings.is_stored(ClientSettings.FOV), "queda como elegido por el jugador")
	(menu.get_control(ClientSettings.INVERT_Y) as CheckButton).button_pressed = true
	assert_eq(_settings.get_value(ClientSettings.INVERT_Y), true)
	var fps: OptionButton = menu.get_control(ClientSettings.FPS_LIMIT) as OptionButton
	fps.select(5)
	fps.item_selected.emit(5)
	assert_eq(_settings.get_value(ClientSettings.FPS_LIMIT), ClientSettings.FPS_LIMITS[5])
	var shoulder: OptionButton = menu.get_control(ClientSettings.DEFAULT_SHOULDER) as OptionButton
	shoulder.select(1)
	shoulder.item_selected.emit(1)
	assert_eq(_settings.get_value(ClientSettings.DEFAULT_SHOULDER), -1, "el segundo valor es el izquierdo")
	var sfx: StringName = ClientSettings.volume_id(AudioBuses.SFX)
	(menu.get_control(sfx) as HSlider).value = 0.4
	assert_near(float(_settings.get_value(sfx)), 0.4, 0.0001)
	assert_eq(changed, [ClientSettings.FOV, ClientSettings.INVERT_Y, ClientSettings.FPS_LIMIT,
			ClientSettings.DEFAULT_SHOULDER, sfx] as Array[StringName])
	# Cambios hechos desde fuera se reflejan en el control sin volver a emitir.
	changed.clear()
	_settings.set_value(ClientSettings.FOV, 70.0)
	assert_eq((menu.get_control(ClientSettings.FOV) as HSlider).value, 70.0)
	assert_eq(menu.get_value_label(ClientSettings.FOV).text, "70°")
	assert_true(changed.is_empty(), "sin bucle de avisos")


func test_restore_tab_and_restore_all() -> void:
	var menu: SettingsMenu = _make_menu()
	for spec: Dictionary in ClientSettings.get_schema():
		var id: StringName = spec["id"]
		match int(spec["kind"]):
			ClientSettings.Kind.BOOL:
				(menu.get_control(id) as CheckButton).button_pressed = not bool(spec["default"])
			ClientSettings.Kind.RANGE:
				(menu.get_control(id) as HSlider).value = float(spec["min"]) \
						if float(spec["default"]) > float(spec["min"]) else float(spec["max"])
			_:
				var option: OptionButton = menu.get_control(id) as OptionButton
				var index: int = 0 if (spec["values"] as Array)[0] != spec["default"] else 1
				option.select(index)
				option.item_selected.emit(index)
	for spec: Dictionary in ClientSettings.get_schema():
		assert_true(_settings.get_value(spec["id"]) != spec["default"], "%s cambiado" % spec["id"])
	menu.show_tab(ClientSettings.TAB_CAMERA)
	menu.get_restore_tab_button().pressed.emit()
	for spec: Dictionary in ClientSettings.get_schema():
		var is_camera: bool = spec["tab"] == ClientSettings.TAB_CAMERA
		assert_eq(_settings.get_value(spec["id"]) == spec["default"], is_camera,
				"%s: solo la pestaña de cámara vuelve a su valor" % spec["id"])
	assert_eq((menu.get_control(ClientSettings.FOV) as HSlider).value, 72.0, "y los controles también")
	assert_false((menu.get_control(ClientSettings.INVERT_Y) as CheckButton).button_pressed)
	menu.get_restore_all_button().pressed.emit()
	for spec: Dictionary in ClientSettings.get_schema():
		assert_eq(_settings.get_value(spec["id"]), spec["default"], "%s restaurado" % spec["id"])
		assert_false(_settings.is_stored(spec["id"]))
	assert_eq((menu.get_control(ClientSettings.RENDER_SCALE) as HSlider).value, 1.0)
	assert_eq(menu.get_value_label(ClientSettings.RENDER_SCALE).text, "100 %")


func test_restore_all_asks_before_when_there_is_a_dialog() -> void:
	var menu: SettingsMenu = _make_menu(true)
	_settings.set_value(ClientSettings.FOV, 99.0)
	var confirm: UIConfirmDialog = menu.get_parent().get_child(1) as UIConfirmDialog
	assert_not_null(confirm)
	menu.get_restore_all_button().pressed.emit()
	assert_true(confirm.is_open(), "pregunta antes")
	assert_eq(confirm.get_confirm_button().theme_type_variation, &"DangerButton", "con el estilo de peligro")
	assert_eq(_settings.get_value(ClientSettings.FOV), 99.0, "y todavía no ha restaurado nada")
	confirm.cancel()
	assert_eq(_settings.get_value(ClientSettings.FOV), 99.0, "cancelar lo deja como estaba")
	menu.get_restore_all_button().pressed.emit()
	confirm.confirm()
	assert_eq(_settings.get_value(ClientSettings.FOV), 72.0, "confirmar restaura")


func test_closing_the_menu_saves_the_settings() -> void:
	var menu: SettingsMenu = _make_menu()
	menu.open()
	(menu.get_control(ClientSettings.FOV) as HSlider).value = 91.0
	(menu.get_control(ClientSettings.NAMEPLATES) as CheckButton).button_pressed = false
	assert_false(FileAccess.file_exists(TEST_PATH), "no escribe en cada cambio")
	menu.close()
	assert_true(FileAccess.file_exists(TEST_PATH), "al cerrar, guarda")
	var back: ClientSettings = ClientSettings.load_from(TEST_PATH)
	assert_eq(back.get_value(ClientSettings.FOV), 91.0)
	assert_eq(back.get_value(ClientSettings.NAMEPLATES), false)
	assert_false(back.is_stored(ClientSettings.INVERT_Y), "y solo lo que se tocó")
	# Esc la cierra y también guarda.
	menu.open()
	(menu.get_control(ClientSettings.INVERT_Y) as CheckButton).button_pressed = true
	_press(KEY_ESCAPE)
	assert_false(menu.is_open())
	assert_eq(ClientSettings.load_from(TEST_PATH).get_value(ClientSettings.INVERT_Y), true)


func test_opening_refreshes_the_controls_and_sounds() -> void:
	var menu: SettingsMenu = _make_menu()
	_settings.set_value(ClientSettings.FOV, 64.0)
	menu.open()
	assert_eq((menu.get_control(ClientSettings.FOV) as HSlider).value, 64.0)
	assert_eq(UISounds.get_play_count(UISounds.OPEN), 1)
	assert_true(menu.visible)
	var focus_owner: Control = menu.get_viewport().gui_get_focus_owner()
	assert_not_null(focus_owner, "abrirla da el foco a un ajuste")
	assert_true(menu.get_tabs().get_current_tab_control().is_ancestor_of(focus_owner),
			"el primero de la pestaña abierta")
	# Sus botones suenan al pulsarlos.
	menu.get_restore_tab_button().pressed.emit()
	assert_eq(UISounds.get_play_count(UISounds.CLICK), 1)


# --- ClientServices: F10, aplicar en vivo y al arrancar ----------------------------------------

func test_f10_opens_and_closes_the_settings_and_frees_the_cursor() -> void:
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(rig)
	var services: ClientServices = _add(ClientServices.new()) as ClientServices
	var menu: SettingsMenu = services.get_settings_menu()
	assert_not_null(menu)
	assert_eq(services.get_settings(), _settings)
	assert_false(menu.is_open())
	assert_false(rig.is_cursor_free())
	_press(KEY_F10)
	assert_true(menu.is_open(), "F10 abre los ajustes")
	assert_true(rig.is_cursor_free(), "y libera el cursor")
	_press(KEY_F10)
	assert_false(menu.is_open(), "F10 otra vez los cierra")
	assert_false(rig.is_cursor_free(), "y recaptura el cursor")
	_press(KEY_F10)
	assert_true(menu.is_open())
	_press(KEY_ESCAPE)
	assert_false(menu.is_open(), "Esc también")
	assert_false(rig.is_cursor_free())
	assert_eq(menu.get_parent().get_parent(), services, "la ventana cuelga de la capa de los servicios")
	assert_eq((menu.get_parent() as CanvasLayer).layer, ClientServices.UI_LAYER)
	assert_true(InputMap.has_action(&"open_settings"))
	assert_eq(UIKeyGlyph.label_for_action(&"open_settings"), "F10")


func test_cancelling_the_restore_dialog_keeps_the_cursor_free_for_the_open_settings() -> void:
	# T1: el diálogo de «Restaurar todo» y la ventana de ajustes piden el cursor a la vez.
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(rig)
	var services: ClientServices = _add(ClientServices.new()) as ClientServices
	var menu: SettingsMenu = services.get_settings_menu()
	var confirm: UIConfirmDialog = services.get_confirm_dialog()
	_press(KEY_F10)
	assert_true(menu.is_open())
	assert_true(rig.is_cursor_free())
	menu.restore_all()
	assert_true(confirm.is_open(), "pregunta antes")
	assert_true(rig.is_cursor_free())
	confirm.cancel()
	assert_true(menu.is_open(), "los ajustes siguen abiertos")
	assert_true(rig.is_cursor_free(), "y con el ratón libre para poder usarlos")
	menu.restore_all()
	confirm.confirm()
	assert_true(rig.is_cursor_free(), "también tras confirmar")
	_press(KEY_ESCAPE)
	assert_false(menu.is_open())
	assert_false(rig.is_cursor_free(), "al cerrar los ajustes, el ratón vuelve a la cámara")


func test_changes_are_applied_live_through_the_menu() -> void:
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(rig)
	var services: ClientServices = _add(ClientServices.new()) as ClientServices
	var menu: SettingsMenu = services.get_settings_menu()
	menu.open()
	# Cámara.
	(menu.get_control(ClientSettings.FOV) as HSlider).value = 90.0
	assert_eq(rig.get_fov(), 90.0, "el campo de visión se aplica en vivo")
	(menu.get_control(ClientSettings.MOUSE_SENSITIVITY) as HSlider).value = 2.0
	assert_near(rig.mouse_sensitivity, CameraRig.DEFAULT_MOUSE_SENSITIVITY * 2.0, 0.000001)
	(menu.get_control(ClientSettings.INVERT_Y) as CheckButton).button_pressed = true
	assert_true(rig.invert_y)
	var shoulder: OptionButton = menu.get_control(ClientSettings.DEFAULT_SHOULDER) as OptionButton
	shoulder.select(1)
	shoulder.item_selected.emit(1)
	assert_eq(rig.get_chosen_shoulder(), -1)
	# Gráficos.
	var fps: OptionButton = menu.get_control(ClientSettings.FPS_LIMIT) as OptionButton
	fps.select(2)
	fps.item_selected.emit(2)
	assert_eq(Engine.max_fps, 60)
	(menu.get_control(ClientSettings.RENDER_SCALE) as HSlider).value = 0.6
	assert_near(tree.root.scaling_3d_scale, 0.6, 0.0001)
	var antialiasing: OptionButton = menu.get_control(ClientSettings.ANTIALIASING) as OptionButton
	antialiasing.select(1)
	antialiasing.item_selected.emit(1)
	assert_eq(tree.root.screen_space_aa, Viewport.SCREEN_SPACE_AA_FXAA)
	# Audio.
	(menu.get_control(ClientSettings.volume_id(AudioBuses.UI)) as HSlider).value = 0.35
	assert_near(AudioBuses.get_volume(AudioBuses.UI), 0.35, 0.001)
	menu.show_tab(ClientSettings.TAB_AUDIO)
	menu.get_restore_tab_button().pressed.emit()
	assert_near(AudioBuses.get_volume(AudioBuses.UI), AudioBuses.default_volume(AudioBuses.UI), 0.001,
			"restaurar también se aplica en vivo")
	# Restaurar todo vuelve el motor a lo de siempre.
	services.get_confirm_dialog().open("x", "y")
	services.get_confirm_dialog().cancel()
	menu.restore_all()
	assert_true(services.get_confirm_dialog().is_open(), "con confirmación en el cliente")
	services.get_confirm_dialog().confirm()
	assert_eq(rig.get_fov(), 72.0)
	assert_eq(Engine.max_fps, 0)
	assert_eq(tree.root.scaling_3d_scale, 1.0)
	assert_false(rig.invert_y)
	assert_eq(rig.get_chosen_shoulder(), 1)


func test_stored_settings_are_applied_on_start_and_defaults_are_not() -> void:
	# Sin nada guardado, arrancar no toca el motor.
	Engine.max_fps = 77
	tree.root.msaa_3d = Viewport.MSAA_8X
	var plain: ClientServices = _add(ClientServices.new()) as ClientServices
	assert_eq(Engine.max_fps, 77, "sin ajustes guardados no se pisa el límite de FPS")
	assert_eq(tree.root.msaa_3d, Viewport.MSAA_8X, "ni el suavizado del proyecto")
	tree.root.remove_child(plain)
	_nodes.erase(plain)
	plain.free()
	# Con ajustes guardados, se aplican al arrancar.
	var config: ConfigFile = ConfigFile.new()
	config.set_value("graphics", "fps_limit", 90)
	config.set_value("graphics", "antialiasing", 1)
	config.set_value("graphics", "render_scale", 0.8)
	config.set_value("audio", "volume_sfx", 0.5)
	config.set_value("camera", "fov", 85.0)
	assert_eq(config.save(TEST_PATH), OK)
	_settings = ClientSettings.load_from(TEST_PATH)
	ClientSettings.set_current(_settings)
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(ClientServices.new())
	_add(rig)
	assert_eq(Engine.max_fps, 90, "el límite de FPS guardado se aplica al arrancar")
	assert_eq(tree.root.screen_space_aa, Viewport.SCREEN_SPACE_AA_FXAA)
	assert_eq(tree.root.msaa_3d, Viewport.MSAA_DISABLED)
	assert_near(tree.root.scaling_3d_scale, 0.8, 0.0001)
	assert_near(AudioBuses.get_volume(AudioBuses.SFX), 0.5, 0.001, "el volumen guardado")
	assert_near(AudioBuses.get_volume(AudioBuses.MUSIC), AudioBuses.default_volume(AudioBuses.MUSIC),
			0.001, "y los demás, los de fábrica")
	assert_eq(rig.get_fov(), 85.0, "una cámara que nace después recoge el campo de visión guardado")


func test_lights_that_arrive_later_get_the_players_shadow_setting() -> void:
	var config: ConfigFile = ConfigFile.new()
	config.set_value("graphics", "shadows", 0)
	assert_eq(config.save(TEST_PATH), OK)
	_settings = ClientSettings.load_from(TEST_PATH)
	ClientSettings.set_current(_settings)
	_add(ClientServices.new())
	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.shadow_enabled = true
	_add(light)
	assert_false(light.shadow_enabled, "una luz que entra con las sombras desactivadas las pierde")
	# Sin ese ajuste guardado, las luces no se tocan.
	_settings.reset(ClientSettings.SHADOWS)
	var other: DirectionalLight3D = DirectionalLight3D.new()
	other.shadow_enabled = true
	_add(other)
	assert_true(other.shadow_enabled)


func test_services_save_unsaved_changes_when_leaving() -> void:
	var services: ClientServices = _add(ClientServices.new()) as ClientServices
	_settings.set_value(ClientSettings.FOV, 77.0)
	assert_false(FileAccess.file_exists(TEST_PATH))
	tree.root.remove_child(services)
	assert_true(FileAccess.file_exists(TEST_PATH), "al salir se guardan los cambios pendientes")
	tree.root.add_child(services)
	assert_eq(ClientSettings.load_from(TEST_PATH).get_value(ClientSettings.FOV), 77.0)


# --- El sandbox -------------------------------------------------------------------------------

func test_the_offline_sandbox_opens_the_settings_with_f10() -> void:
	ClientMain.zone_id = &"test_world"
	ClientMain.realm = &"vardheim"
	ClientMain.demo_mode = false
	ClientMain.shots_dir = ""
	ClientMain.quit_after_demo = false
	var client: ClientMain = (load(CLIENT_MAIN_SCENE) as PackedScene).instantiate() as ClientMain
	_add(client)
	await wait_physics_frames(3)
	var services: ClientServices = client.get_node(^"ClientServices") as ClientServices
	assert_not_null(services, "el sandbox monta los servicios del cliente")
	var rig: CameraRig = client.get_camera_rig()
	assert_not_null(rig)
	assert_eq(rig.get_fov(), 72.0, "sin ajustes guardados, la cámara es la de siempre")
	assert_false(rig.is_cursor_free())
	_press(KEY_F10)
	assert_true(services.get_settings_menu().is_open(), "F10 abre los ajustes en el sandbox")
	assert_true(rig.is_cursor_free())
	(services.get_settings_menu().get_control(ClientSettings.FOV) as HSlider).value = 80.0
	assert_eq(rig.get_fov(), 80.0, "y los cambios llegan a la cámara del sandbox")
	_press(KEY_ESCAPE)
	assert_false(services.get_settings_menu().is_open())
	assert_false(rig.is_cursor_free(), "Esc la cierra y el ratón vuelve a la cámara")
	assert_true(FileAccess.file_exists(TEST_PATH), "y se guarda")
