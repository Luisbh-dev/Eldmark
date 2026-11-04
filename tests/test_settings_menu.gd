extends TestCase
## Tests for the settings window ([SettingsMenu], UI-16) and for [ClientServices], which opens it with F10
## and applies the settings live and at startup: the controls reflect and change the settings, restoring a
## tab and everything, saving on close, each value applied to the engine, the cameras, the lights and the
## audio, and the sandbox ([ClientMain]) with its F10.
## [br][br]
## The test's settings live in a temporary file and the engine and audio are restored when it finishes.

const TEST_PATH: String = "user://test_settings_menu.cfg"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const CLIENT_MAIN_SCENE: String = "res://scenes/client/client_main.tscn"

var _nodes: Array[Node] = []
var _settings: ClientSettings = null
## The confirmation dialog of the last [method _make_menu] with a dialog (null if it had none).
var _confirm: UIConfirmDialog = null
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
	_confirm = null
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
	_confirm = confirm
	menu.setup(_settings, confirm)
	return menu


func _press(key: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	tree.root.push_input(event)


# --- The window -------------------------------------------------------------------------------

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
		if not assert_not_null(control, "there is a control for %s" % id):
			continue
		match int(spec["kind"]):
			ClientSettings.Kind.BOOL:
				assert_true(control is CheckButton, "%s is a toggle" % id)
			ClientSettings.Kind.CHOICE:
				assert_true(control is OptionButton, "%s is a list" % id)
				assert_eq((control as OptionButton).item_count, (spec["labels"] as Array).size())
			_:
				assert_true(control is HSlider, "%s is a slider" % id)
				assert_eq((control as HSlider).min_value, float(spec["min"]))
				assert_eq((control as HSlider).max_value, float(spec["max"]))
				assert_not_null(menu.get_value_label(id), "with its value next to it")
		# The control lives on the page of its tab.
		var page: Node = menu.get_tabs().get_child(ClientSettings.TABS.find(spec["tab"]))
		assert_true(page.is_ancestor_of(control), "%s is in its tab" % id)
	assert_null(menu.get_control(&"no_existe"))
	assert_null(menu.get_value_label(ClientSettings.INVERT_Y), "a toggle has no value text")
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
	assert_true(resolution.disabled, "the resolution only applies in windowed mode")
	_settings.set_value(ClientSettings.WINDOW_MODE, ClientSettings.MODE_WINDOWED)
	assert_false(resolution.disabled, "and comes back when windowed is chosen")


func test_changing_a_control_changes_the_setting() -> void:
	var menu: SettingsMenu = _make_menu()
	var changed: Array[StringName] = []
	menu.setting_changed.connect(func(id: StringName) -> void: changed.append(id))
	(menu.get_control(ClientSettings.FOV) as HSlider).value = 88.0
	assert_eq(_settings.get_value(ClientSettings.FOV), 88.0)
	assert_eq(menu.get_value_label(ClientSettings.FOV).text, "88°")
	assert_true(_settings.is_stored(ClientSettings.FOV), "it stays as chosen by the player")
	(menu.get_control(ClientSettings.INVERT_Y) as CheckButton).button_pressed = true
	assert_eq(_settings.get_value(ClientSettings.INVERT_Y), true)
	var fps: OptionButton = menu.get_control(ClientSettings.FPS_LIMIT) as OptionButton
	fps.select(5)
	fps.item_selected.emit(5)
	assert_eq(_settings.get_value(ClientSettings.FPS_LIMIT), ClientSettings.FPS_LIMITS[5])
	var shoulder: OptionButton = menu.get_control(ClientSettings.DEFAULT_SHOULDER) as OptionButton
	shoulder.select(1)
	shoulder.item_selected.emit(1)
	assert_eq(_settings.get_value(ClientSettings.DEFAULT_SHOULDER), -1, "the second value is the left one")
	var sfx: StringName = ClientSettings.volume_id(AudioBuses.SFX)
	(menu.get_control(sfx) as HSlider).value = 0.4
	assert_near(float(_settings.get_value(sfx)), 0.4, 0.0001)
	assert_eq(changed, [ClientSettings.FOV, ClientSettings.INVERT_Y, ClientSettings.FPS_LIMIT,
			ClientSettings.DEFAULT_SHOULDER, sfx] as Array[StringName])
	# Changes made from outside are reflected in the control without emitting again.
	changed.clear()
	_settings.set_value(ClientSettings.FOV, 70.0)
	assert_eq((menu.get_control(ClientSettings.FOV) as HSlider).value, 70.0)
	assert_eq(menu.get_value_label(ClientSettings.FOV).text, "70°")
	assert_true(changed.is_empty(), "no notification loop")


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
		assert_true(_settings.get_value(spec["id"]) != spec["default"], "%s changed" % spec["id"])
	menu.show_tab(ClientSettings.TAB_CAMERA)
	menu.get_restore_tab_button().pressed.emit()
	for spec: Dictionary in ClientSettings.get_schema():
		var is_camera: bool = spec["tab"] == ClientSettings.TAB_CAMERA
		assert_eq(_settings.get_value(spec["id"]) == spec["default"], is_camera,
				"%s: only the camera tab goes back to its value" % spec["id"])
	assert_eq((menu.get_control(ClientSettings.FOV) as HSlider).value, 72.0, "and the controls too")
	assert_false((menu.get_control(ClientSettings.INVERT_Y) as CheckButton).button_pressed)
	menu.get_restore_all_button().pressed.emit()
	for spec: Dictionary in ClientSettings.get_schema():
		assert_eq(_settings.get_value(spec["id"]), spec["default"], "%s restored" % spec["id"])
		assert_false(_settings.is_stored(spec["id"]))
	assert_eq((menu.get_control(ClientSettings.RENDER_SCALE) as HSlider).value, 1.0)
	assert_eq(menu.get_value_label(ClientSettings.RENDER_SCALE).text, "100 %")


func test_restore_all_asks_before_when_there_is_a_dialog() -> void:
	var menu: SettingsMenu = _make_menu(true)
	_settings.set_value(ClientSettings.FOV, 99.0)
	var confirm: UIConfirmDialog = _confirm
	assert_not_null(confirm)
	menu.get_restore_all_button().pressed.emit()
	assert_true(confirm.is_open(), "asks first")
	assert_eq(confirm.get_confirm_button().theme_type_variation, &"DangerButton", "with the danger style")
	assert_eq(_settings.get_value(ClientSettings.FOV), 99.0, "and has not restored anything yet")
	confirm.cancel()
	assert_eq(_settings.get_value(ClientSettings.FOV), 99.0, "cancelling leaves it as it was")
	menu.get_restore_all_button().pressed.emit()
	confirm.confirm()
	assert_eq(_settings.get_value(ClientSettings.FOV), 72.0, "confirming restores")


func test_closing_the_menu_saves_the_settings() -> void:
	var menu: SettingsMenu = _make_menu()
	menu.open()
	(menu.get_control(ClientSettings.FOV) as HSlider).value = 91.0
	(menu.get_control(ClientSettings.NAMEPLATES) as CheckButton).button_pressed = false
	assert_false(FileAccess.file_exists(TEST_PATH), "it does not write on every change")
	menu.close()
	assert_true(FileAccess.file_exists(TEST_PATH), "on close, it saves")
	var back: ClientSettings = ClientSettings.load_from(TEST_PATH)
	assert_eq(back.get_value(ClientSettings.FOV), 91.0)
	assert_eq(back.get_value(ClientSettings.NAMEPLATES), false)
	assert_false(back.is_stored(ClientSettings.INVERT_Y), "and only what was touched")
	# Esc closes it and also saves.
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
	assert_not_null(focus_owner, "opening it gives focus to a setting")
	assert_true(menu.get_tabs().get_current_tab_control().is_ancestor_of(focus_owner),
			"the first one in the open tab")
	# Its buttons make a sound when pressed.
	menu.get_restore_tab_button().pressed.emit()
	assert_eq(UISounds.get_play_count(UISounds.CLICK), 1)


# --- ClientServices: F10, applying live and at startup -----------------------------------------

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
	assert_true(menu.is_open(), "F10 opens the settings")
	assert_true(rig.is_cursor_free(), "and releases the cursor")
	_press(KEY_F10)
	assert_false(menu.is_open(), "F10 again closes them")
	assert_false(rig.is_cursor_free(), "and recaptures the cursor")
	_press(KEY_F10)
	assert_true(menu.is_open())
	_press(KEY_ESCAPE)
	assert_false(menu.is_open(), "Esc too")
	assert_false(rig.is_cursor_free())
	assert_eq(menu.get_parent().get_parent(), services, "the window hangs from the services layer")
	assert_eq((menu.get_parent() as CanvasLayer).layer, ClientServices.UI_LAYER)
	assert_true(InputMap.has_action(&"open_settings"))
	assert_eq(UIKeyGlyph.label_for_action(&"open_settings"), "F10")


func test_cancelling_the_restore_dialog_keeps_the_cursor_free_for_the_open_settings() -> void:
	# T1: the "Restaurar todo" (Restore all) dialog and the settings window ask for the cursor at the same time.
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(rig)
	var services: ClientServices = _add(ClientServices.new()) as ClientServices
	var menu: SettingsMenu = services.get_settings_menu()
	var confirm: UIConfirmDialog = services.get_confirm_dialog()
	_press(KEY_F10)
	assert_true(menu.is_open())
	assert_true(rig.is_cursor_free())
	menu.restore_all()
	assert_true(confirm.is_open(), "asks first")
	assert_true(rig.is_cursor_free())
	confirm.cancel()
	assert_true(menu.is_open(), "the settings stay open")
	assert_true(rig.is_cursor_free(), "and with the mouse free so they can be used")
	menu.restore_all()
	confirm.confirm()
	assert_true(rig.is_cursor_free(), "also after confirming")
	_press(KEY_ESCAPE)
	assert_false(menu.is_open())
	assert_false(rig.is_cursor_free(), "when the settings are closed, the mouse goes back to the camera")


func test_changes_are_applied_live_through_the_menu() -> void:
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(rig)
	var services: ClientServices = _add(ClientServices.new()) as ClientServices
	var menu: SettingsMenu = services.get_settings_menu()
	menu.open()
	# Camera.
	(menu.get_control(ClientSettings.FOV) as HSlider).value = 90.0
	assert_eq(rig.get_fov(), 90.0, "the field of view is applied live")
	(menu.get_control(ClientSettings.MOUSE_SENSITIVITY) as HSlider).value = 2.0
	assert_near(rig.mouse_sensitivity, CameraRig.DEFAULT_MOUSE_SENSITIVITY * 2.0, 0.000001)
	(menu.get_control(ClientSettings.INVERT_Y) as CheckButton).button_pressed = true
	assert_true(rig.invert_y)
	var shoulder: OptionButton = menu.get_control(ClientSettings.DEFAULT_SHOULDER) as OptionButton
	shoulder.select(1)
	shoulder.item_selected.emit(1)
	assert_eq(rig.get_chosen_shoulder(), -1)
	# Graphics.
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
			"restoring is also applied live")
	# Restore all puts the engine back to its defaults.
	services.get_confirm_dialog().open("x", "y")
	services.get_confirm_dialog().cancel()
	menu.restore_all()
	assert_true(services.get_confirm_dialog().is_open(), "with confirmation on the client")
	services.get_confirm_dialog().confirm()
	assert_eq(rig.get_fov(), 72.0)
	assert_eq(Engine.max_fps, 0)
	assert_eq(tree.root.scaling_3d_scale, 1.0)
	assert_false(rig.invert_y)
	assert_eq(rig.get_chosen_shoulder(), 1)


func test_stored_settings_are_applied_on_start_and_defaults_are_not() -> void:
	# With nothing saved, starting up does not touch the engine.
	Engine.max_fps = 77
	tree.root.msaa_3d = Viewport.MSAA_8X
	var plain: ClientServices = _add(ClientServices.new()) as ClientServices
	assert_eq(Engine.max_fps, 77, "without saved settings the FPS limit is not overridden")
	assert_eq(tree.root.msaa_3d, Viewport.MSAA_8X, "nor the project's antialiasing")
	tree.root.remove_child(plain)
	_nodes.erase(plain)
	plain.free()
	# With saved settings, they are applied at startup.
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
	assert_eq(Engine.max_fps, 90, "the saved FPS limit is applied at startup")
	assert_eq(tree.root.screen_space_aa, Viewport.SCREEN_SPACE_AA_FXAA)
	assert_eq(tree.root.msaa_3d, Viewport.MSAA_DISABLED)
	assert_near(tree.root.scaling_3d_scale, 0.8, 0.0001)
	assert_near(AudioBuses.get_volume(AudioBuses.SFX), 0.5, 0.001, "the saved volume")
	assert_near(AudioBuses.get_volume(AudioBuses.MUSIC), AudioBuses.default_volume(AudioBuses.MUSIC),
			0.001, "and the rest, the factory ones")
	assert_eq(rig.get_fov(), 85.0, "a camera born later picks up the saved field of view")


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
	assert_false(light.shadow_enabled, "a light that enters with shadows disabled loses them")
	# Without that saved setting, lights are not touched.
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
	assert_true(FileAccess.file_exists(TEST_PATH), "on exit, pending changes are saved")
	tree.root.add_child(services)
	assert_eq(ClientSettings.load_from(TEST_PATH).get_value(ClientSettings.FOV), 77.0)


# --- The sandbox ------------------------------------------------------------------------------

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
	assert_not_null(services, "the sandbox mounts the client services")
	var rig: CameraRig = client.get_camera_rig()
	assert_not_null(rig)
	assert_eq(rig.get_fov(), 72.0, "without saved settings, the camera is the usual one")
	assert_false(rig.is_cursor_free())
	_press(KEY_F10)
	assert_true(services.get_settings_menu().is_open(), "F10 opens the settings in the sandbox")
	assert_true(rig.is_cursor_free())
	(services.get_settings_menu().get_control(ClientSettings.FOV) as HSlider).value = 80.0
	assert_eq(rig.get_fov(), 80.0, "and the changes reach the sandbox camera")
	_press(KEY_ESCAPE)
	assert_false(services.get_settings_menu().is_open())
	assert_false(rig.is_cursor_free(), "Esc closes it and the mouse goes back to the camera")
	assert_true(FileAccess.file_exists(TEST_PATH), "and it is saved")
