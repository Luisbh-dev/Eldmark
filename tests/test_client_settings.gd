extends TestCase
## Tests for the player settings (UI-16): the settings table, validation, the file
## (round trip, tolerance to garbage, keeping the rest), the conversions and applying each
## value to the engine, the audio, the cameras, the lights, the grass and the interface.
## [br][br]
## The window settings (mode, resolution and vsync) are not applied in headless mode (there is no
## window): their conversion tables are tested. Everything that changes global state (FPS, scale,
## smoothing, shadows, volumes) is restored at the end of each test.

const TEST_PATH: String = "user://test_client_settings.cfg"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"

var _nodes: Array[Node] = []
var _saved_fps: int = 0
var _saved_scale: float = 1.0
var _saved_msaa: Viewport.MSAA = Viewport.MSAA_DISABLED
var _saved_screen_aa: Viewport.ScreenSpaceAA = Viewport.SCREEN_SPACE_AA_DISABLED


func before_each() -> void:
	_saved_fps = Engine.max_fps
	_saved_scale = tree.root.scaling_3d_scale
	_saved_msaa = tree.root.msaa_3d
	_saved_screen_aa = tree.root.screen_space_aa
	ClientSettings.set_current(null)
	_remove_file()


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
	_remove_file()


func _remove_file() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(TEST_PATH)


func _add(node: Node) -> Node:
	tree.root.add_child(node)
	_nodes.append(node)
	return node


# A valid value, different from the factory one, for each setting.
func _non_default(spec: Dictionary) -> Variant:
	match int(spec["kind"]):
		ClientSettings.Kind.BOOL:
			return not bool(spec["default"])
		ClientSettings.Kind.CHOICE:
			for candidate: Variant in spec["values"]:
				if candidate != spec["default"]:
					return candidate
			return spec["default"]
	var low: float = float(spec["min"])
	var high: float = float(spec["max"])
	var default: float = float(spec["default"])
	var candidate: float = low if absf(default - low) > absf(default - high) else high
	# An intermediate value, so as not to test only the extremes.
	return snappedf(lerpf(candidate, default, 0.3), float(spec["step"]))


# --- The table --------------------------------------------------------------------------------

func test_the_schema_covers_every_requested_setting() -> void:
	var ids: Array[StringName] = ClientSettings.get_ids()
	for id: StringName in [ClientSettings.WINDOW_MODE, ClientSettings.RESOLUTION,
			ClientSettings.VSYNC, ClientSettings.FPS_LIMIT, ClientSettings.RENDER_SCALE,
			ClientSettings.SHADOWS, ClientSettings.GRASS_DISTANCE, ClientSettings.ANTIALIASING,
			ClientSettings.MOUSE_SENSITIVITY, ClientSettings.INVERT_Y, ClientSettings.FOV,
			ClientSettings.DEFAULT_SHOULDER, ClientSettings.LANGUAGE, ClientSettings.DAMAGE_NUMBERS,
			ClientSettings.NAMEPLATES, ClientSettings.HINTS, ClientSettings.HELP_BAR]:
		assert_true(ids.has(id), "setting %s is missing" % id)
	for bus: StringName in AudioBuses.ALL:
		assert_true(ids.has(ClientSettings.volume_id(bus)), "the volume of %s is missing" % bus)
	assert_eq(ids.size(), 17 + AudioBuses.ALL.size())
	var seen_ids: Dictionary = {}
	var seen_keys: Dictionary = {}
	for spec: Dictionary in ClientSettings.get_schema():
		var id: StringName = spec["id"]
		assert_false(seen_ids.has(id), "repeated id %s" % id)
		seen_ids[id] = true
		var file_key: String = "%s/%s" % [spec["section"], spec["key"]]
		assert_false(seen_keys.has(file_key), "repeated key %s" % file_key)
		seen_keys[file_key] = true
		assert_true(ClientSettings.TABS.has(spec["tab"]), "%s has a valid tab" % id)
		assert_false(String(spec["label"]).is_empty(), "%s has a label (its msgid)" % id)
		assert_eq(ClientSettings.normalize(spec, spec["default"]), spec["default"],
				"the default value of %s is valid" % id)
		match int(spec["kind"]):
			ClientSettings.Kind.CHOICE:
				assert_eq((spec["values"] as Array).size(), (spec["labels"] as Array).size())
				assert_true((spec["values"] as Array).has(spec["default"]))
			ClientSettings.Kind.RANGE:
				assert_true(float(spec["min"]) < float(spec["max"]))
				assert_true(float(spec["step"]) > 0.0)
	for tab: StringName in ClientSettings.TABS:
		assert_true(ClientSettings.TAB_NAMES.has(tab))
	# The audio keys are the same as AudioBuses'.
	for bus: StringName in AudioBuses.ALL:
		var spec: Dictionary = ClientSettings.get_spec(ClientSettings.volume_id(bus))
		assert_eq(spec["section"], String(AudioBuses.SETTINGS_SECTION))
		assert_eq(spec["key"], AudioBuses.volume_key(bus))
		assert_eq(spec["default"], AudioBuses.default_volume(bus))
	assert_true(ClientSettings.get_spec(&"no_existe").is_empty())
	assert_null(ClientSettings.get_default(&"no_existe"))


func test_defaults_match_what_the_project_already_does() -> void:
	# The default values change nothing from the previous client (window, the project's MSAA 4x,
	# sensitivity, field of view and shoulder of the camera scene).
	assert_eq(ClientSettings.get_default(ClientSettings.RESOLUTION), "1600x900")
	assert_eq(ClientSettings.get_default(ClientSettings.ANTIALIASING), ClientSettings.AA_MSAA_4X)
	assert_eq(ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d"),
			Viewport.MSAA_4X, "the project uses MSAA 4x (msaa_3d=2 in project.godot)")
	assert_eq(ClientSettings.antialiasing_for(ClientSettings.AA_MSAA_4X)["msaa"],
			ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d"))
	assert_eq(ClientSettings.get_default(ClientSettings.MOUSE_SENSITIVITY), 1.0)
	assert_eq(ClientSettings.get_default(ClientSettings.FOV), 72.0)
	assert_eq(ClientSettings.get_default(ClientSettings.DEFAULT_SHOULDER), 1)
	assert_eq(ClientSettings.get_default(ClientSettings.SHADOWS), ClientSettings.SHADOWS_HIGH)
	assert_eq(ClientSettings.get_default(ClientSettings.GRASS_DISTANCE), 60.0)
	assert_eq(ClientSettings.get_default(ClientSettings.FPS_LIMIT), 0)
	var settings: ClientSettings = ClientSettings.new()
	for spec: Dictionary in ClientSettings.get_schema():
		assert_eq(settings.get_value(spec["id"]), spec["default"])
		assert_false(settings.is_stored(spec["id"]), "%s untouched" % spec["id"])
	assert_false(settings.is_dirty())
	assert_null(settings.get_value(&"no_existe"))


# --- Validation -------------------------------------------------------------------------------

func test_values_are_validated_and_normalized() -> void:
	var settings: ClientSettings = ClientSettings.new()
	# Ranges: they are clamped and snapped to the step.
	assert_true(settings.set_value(ClientSettings.FOV, 500.0))
	assert_eq(settings.get_value(ClientSettings.FOV), 100.0, "clamped to the maximum")
	settings.set_value(ClientSettings.FOV, -3)
	assert_eq(settings.get_value(ClientSettings.FOV), 60.0, "and to the minimum (an integer is also valid)")
	settings.set_value(ClientSettings.FOV, 80.4)
	assert_eq(settings.get_value(ClientSettings.FOV), 80.0, "snapped to the step of 1")
	settings.set_value(ClientSettings.RENDER_SCALE, 0.77)
	assert_near(float(settings.get_value(ClientSettings.RENDER_SCALE)), 0.75, 0.0001,
			"snapped to the step of 0.05")
	assert_false(settings.set_value(ClientSettings.FOV, "ancho"), "a text is not a number")
	assert_false(settings.set_value(ClientSettings.FOV, NAN), "NaN is not valid")
	assert_false(settings.set_value(ClientSettings.FOV, null))
	assert_eq(settings.get_value(ClientSettings.FOV), 80.0, "what is rejected changes nothing")
	# Lists: only their values.
	assert_true(settings.set_value(ClientSettings.FPS_LIMIT, 144))
	assert_eq(settings.get_value(ClientSettings.FPS_LIMIT), 144)
	assert_true(settings.set_value(ClientSettings.FPS_LIMIT, 60.0), "a whole decimal is accepted")
	assert_eq(typeof(settings.get_value(ClientSettings.FPS_LIMIT)), TYPE_INT)
	assert_false(settings.set_value(ClientSettings.FPS_LIMIT, 100), "100 is not in the list")
	assert_false(settings.set_value(ClientSettings.FPS_LIMIT, "60"))
	assert_eq(settings.get_value(ClientSettings.FPS_LIMIT), 60)
	assert_true(settings.set_value(ClientSettings.RESOLUTION, "1920x1080"))
	assert_false(settings.set_value(ClientSettings.RESOLUTION, "800x600"))
	assert_false(settings.set_value(ClientSettings.RESOLUTION, 1080))
	assert_true(settings.set_value(ClientSettings.DEFAULT_SHOULDER, -1))
	assert_eq(settings.get_value(ClientSettings.DEFAULT_SHOULDER), -1)
	# Switches: a boolean (or 0 and 1).
	assert_true(settings.set_value(ClientSettings.INVERT_Y, true))
	assert_eq(settings.get_value(ClientSettings.INVERT_Y), true)
	assert_true(settings.set_value(ClientSettings.INVERT_Y, 0))
	assert_eq(settings.get_value(ClientSettings.INVERT_Y), false)
	assert_false(settings.set_value(ClientSettings.INVERT_Y, 2))
	assert_false(settings.set_value(ClientSettings.INVERT_Y, "sí"))
	assert_false(settings.set_value(&"no_existe", 1), "a setting that does not exist")
	# Volumes: 0 to 1.
	var music: StringName = ClientSettings.volume_id(AudioBuses.MUSIC)
	settings.set_value(music, 3.0)
	assert_eq(settings.get_value(music), 1.0)
	settings.set_value(music, 0.123)
	assert_near(float(settings.get_value(music)), 0.10, 0.0001, "at a step of 0.05")


func test_changes_are_announced_once_and_marked_as_the_players() -> void:
	var settings: ClientSettings = ClientSettings.new()
	var seen: Array[Array] = []
	settings.changed.connect(func(id: StringName, value: Variant) -> void: seen.append([id, value]))
	assert_false(settings.is_stored(ClientSettings.FOV))
	settings.set_value(ClientSettings.FOV, 90.0)
	assert_eq(seen.size(), 1)
	assert_eq(seen[0][0], ClientSettings.FOV)
	assert_eq(seen[0][1], 90.0)
	assert_true(settings.is_stored(ClientSettings.FOV))
	assert_true(settings.is_dirty())
	settings.set_value(ClientSettings.FOV, 90.0)
	assert_eq(seen.size(), 1, "the same value does not notify again")
	settings.set_value(ClientSettings.FOV, 999.0)
	assert_eq(seen.size(), 2, "but one that normalizes to another does")
	settings.set_value(ClientSettings.FOV, "mal")
	assert_eq(seen.size(), 2, "nor what is rejected")
	settings.set_value(ClientSettings.FOV, 72.0)
	assert_true(settings.is_stored(ClientSettings.FOV), "setting it to the factory value is also a choice")
	settings.reset(ClientSettings.FOV)
	assert_false(settings.is_stored(ClientSettings.FOV))
	assert_eq(settings.get_value(ClientSettings.FOV), 72.0)
	settings.reset(ClientSettings.FOV)
	settings.reset(&"no_existe")


func test_formatting_values_for_the_menu() -> void:
	assert_eq(ClientSettings.format_value(ClientSettings.RENDER_SCALE, 0.75), "75%")
	assert_eq(ClientSettings.format_value(ClientSettings.MOUSE_SENSITIVITY, 1.25), "x1.25")
	assert_eq(ClientSettings.format_value(ClientSettings.FOV, 90.0), "90°")
	assert_eq(ClientSettings.format_value(ClientSettings.GRASS_DISTANCE, 60.0), "60 m")
	assert_eq(ClientSettings.format_value(ClientSettings.GRASS_DISTANCE, 0.0), "Off")
	assert_eq(ClientSettings.format_value(ClientSettings.INVERT_Y, true), "Yes")
	assert_eq(ClientSettings.format_value(ClientSettings.INVERT_Y, false), "No")
	assert_eq(ClientSettings.format_value(ClientSettings.FPS_LIMIT, 0), "No limit")
	assert_eq(ClientSettings.format_value(ClientSettings.FPS_LIMIT, 144), "144 FPS")
	assert_eq(ClientSettings.format_value(ClientSettings.DEFAULT_SHOULDER, -1), "Left")
	assert_eq(ClientSettings.format_value(ClientSettings.RESOLUTION, "1920x1080"), "1920 x 1080")
	assert_eq(ClientSettings.format_value(ClientSettings.LANGUAGE, "es"), "Español", "an endonym")
	assert_eq(ClientSettings.format_value(ClientSettings.LANGUAGE, "auto"), "Automatic (Spanish)")
	assert_eq(ClientSettings.format_value(&"no_existe", 5), "5")


func test_the_spanish_texts_of_the_menu_keep_the_decimal_comma_and_the_percent_space() -> void:
	with_locale("es")
	assert_eq(ClientSettings.format_value(ClientSettings.RENDER_SCALE, 0.75), "75 %")
	assert_eq(ClientSettings.format_value(ClientSettings.MOUSE_SENSITIVITY, 1.25), "x1,25")
	assert_eq(ClientSettings.format_value(ClientSettings.GRASS_DISTANCE, 0.0), "Desactivada")
	assert_eq(ClientSettings.format_value(ClientSettings.INVERT_Y, true), "Sí")
	assert_eq(ClientSettings.format_value(ClientSettings.FPS_LIMIT, 0), "Sin límite")
	assert_eq(ClientSettings.format_value(ClientSettings.DEFAULT_SHOULDER, -1), "Izquierdo")
	assert_eq(ClientSettings.format_value(ClientSettings.LANGUAGE, "auto"), "Automático (español)")
	var titles: Array[String] = []
	for tab: StringName in ClientSettings.TABS:
		titles.append(ClientSettings.tab_title(tab))
	assert_eq(titles, ["Gráficos", "Audio", "Cámara", "Interfaz"] as Array[String])


# --- File -------------------------------------------------------------------------------------

func test_settings_round_trip_through_the_file() -> void:
	var settings: ClientSettings = ClientSettings.new()
	var expected: Dictionary = {}
	for spec: Dictionary in ClientSettings.get_schema():
		var value: Variant = _non_default(spec)
		assert_true(settings.set_value(spec["id"], value), "%s is set" % spec["id"])
		expected[spec["id"]] = settings.get_value(spec["id"])
		assert_true(expected[spec["id"]] != spec["default"], "%s is no longer the factory one" % spec["id"])
	assert_true(settings.is_dirty())
	assert_eq(settings.save_file(TEST_PATH), OK)
	assert_false(settings.is_dirty(), "after saving nothing is left pending")
	var loaded: ClientSettings = ClientSettings.load_from(TEST_PATH)
	assert_eq(loaded.path, TEST_PATH)
	assert_false(loaded.is_dirty())
	for spec: Dictionary in ClientSettings.get_schema():
		var id: StringName = spec["id"]
		assert_true(loaded.is_stored(id), "%s was saved" % id)
		if typeof(expected[id]) == TYPE_FLOAT:
			assert_near(float(loaded.get_value(id)), float(expected[id]), 0.001, "%s after loading" % id)
		else:
			assert_eq(loaded.get_value(id), expected[id], "%s after loading" % id)
	# The file is a text cfg with one section per group.
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(TEST_PATH), OK)
	for section: String in ["graphics", "audio", "camera", "interface"]:
		assert_true(config.has_section(section), "section %s" % section)
	assert_true(config.has_section_key("graphics", "grass_distance"))
	assert_true(config.has_section_key("audio", "volume_sfx"))
	assert_true(config.has_section_key("camera", "mouse_sensitivity"))
	assert_true(config.has_section_key("interface", "damage_numbers"))


func test_only_what_the_player_changed_is_written_and_the_rest_of_the_file_is_kept() -> void:
	var base: ConfigFile = ConfigFile.new()
	base.set_value("otra_cosa", "dato", 7)
	base.set_value("camera", "invert_y", true)
	base.set_value("graphics", "shadows", 1)
	assert_eq(base.save(TEST_PATH), OK)
	var settings: ClientSettings = ClientSettings.load_from(TEST_PATH)
	assert_eq(settings.get_value(ClientSettings.INVERT_Y), true, "reads what was there")
	assert_eq(settings.get_value(ClientSettings.SHADOWS), 1)
	assert_true(settings.is_stored(ClientSettings.INVERT_Y))
	settings.set_value(ClientSettings.FOV, 85.0)
	settings.reset(ClientSettings.SHADOWS)
	assert_eq(settings.save_file(TEST_PATH), OK)
	var back: ConfigFile = ConfigFile.new()
	assert_eq(back.load(TEST_PATH), OK)
	assert_eq(back.get_value("otra_cosa", "dato"), 7, "foreign content is preserved")
	assert_eq(back.get_value("camera", "invert_y"), true)
	assert_eq(float(back.get_value("camera", "fov")), 85.0)
	assert_false(back.has_section_key("graphics", "shadows"), "a restored setting is removed")
	assert_false(back.has_section_key("camera", "mouse_sensitivity"), "and what was not touched is not written")
	assert_false(back.has_section_key("audio", "volume_master"))


func test_a_missing_or_nonsense_file_gives_the_defaults() -> void:
	var missing: ClientSettings = ClientSettings.new()
	assert_eq(missing.load_file("user://no_existe_%d.cfg" % Time.get_ticks_usec()), ERR_FILE_NOT_FOUND)
	for spec: Dictionary in ClientSettings.get_schema():
		assert_eq(missing.get_value(spec["id"]), spec["default"])
	var config: ConfigFile = ConfigFile.new()
	config.set_value("graphics", "fps_limit", 100)
	config.set_value("graphics", "resolution", 1080)
	config.set_value("graphics", "render_scale", 0.1)
	config.set_value("graphics", "grass_distance", "mucha")
	config.set_value("camera", "fov", 1000.0)
	config.set_value("camera", "invert_y", "sí")
	config.set_value("camera", "default_shoulder", 0)
	config.set_value("interface", "nameplates", false)
	config.set_value("graphics", "clave_inventada", 5)
	config.set_value("seccion_inventada", "x", 1)
	assert_eq(config.save(TEST_PATH), OK)
	var settings: ClientSettings = ClientSettings.load_from(TEST_PATH)
	assert_eq(settings.get_value(ClientSettings.FPS_LIMIT), 0, "100 FPS is not in the list")
	assert_eq(settings.get_value(ClientSettings.RESOLUTION), "1600x900")
	assert_eq(settings.get_value(ClientSettings.RENDER_SCALE), 0.5, "it is clamped to the minimum")
	assert_eq(settings.get_value(ClientSettings.GRASS_DISTANCE), 60.0, "a text, the factory one")
	assert_eq(settings.get_value(ClientSettings.FOV), 100.0, "it is clamped to the maximum")
	assert_eq(settings.get_value(ClientSettings.INVERT_Y), false)
	assert_eq(settings.get_value(ClientSettings.DEFAULT_SHOULDER), 1)
	assert_eq(settings.get_value(ClientSettings.NAMEPLATES), false, "and the good one is read")
	assert_false(settings.is_stored(ClientSettings.FPS_LIMIT), "what is invalid does not count as the player's")
	assert_true(settings.is_stored(ClientSettings.NAMEPLATES))
	assert_true(settings.is_stored(ClientSettings.FOV))


func test_a_file_that_is_not_a_config_gives_the_defaults() -> void:
	allow_logged_errors()
	var file: FileAccess = FileAccess.open(TEST_PATH, FileAccess.WRITE)
	file.store_string("esto no es [[[ un archivo = = de ajustes\n" + char(1) + char(2))
	file.close()
	var settings: ClientSettings = ClientSettings.load_from(TEST_PATH)
	for spec: Dictionary in ClientSettings.get_schema():
		assert_eq(settings.get_value(spec["id"]), spec["default"])
		assert_false(settings.is_stored(spec["id"]))
	settings.set_value(ClientSettings.FOV, 80.0)
	assert_eq(settings.save_file(TEST_PATH), OK, "and it can be saved over")
	assert_eq(ClientSettings.load_from(TEST_PATH).get_value(ClientSettings.FOV), 80.0)


func test_dirty_settings_are_saved_to_their_own_path() -> void:
	var settings: ClientSettings = ClientSettings.load_from(TEST_PATH)
	settings.save_if_dirty()
	assert_false(FileAccess.file_exists(TEST_PATH), "without changes nothing is written")
	settings.set_value(ClientSettings.INVERT_Y, true)
	settings.save_if_dirty()
	assert_true(FileAccess.file_exists(TEST_PATH))
	assert_eq(ClientSettings.load_from(TEST_PATH).get_value(ClientSettings.INVERT_Y), true)
	assert_false(settings.is_dirty())


func test_the_current_settings_can_be_replaced() -> void:
	var custom: ClientSettings = ClientSettings.new()
	ClientSettings.set_current(custom)
	assert_eq(ClientSettings.current(), custom)
	ClientSettings.set_current(null)
	assert_not_null(ClientSettings.current(), "it is reloaded when requested")
	assert_true(ClientSettings.current() != custom)


# --- Restore ----------------------------------------------------------------------------------

func test_restoring_a_tab_or_everything_goes_back_to_the_defaults() -> void:
	var settings: ClientSettings = ClientSettings.new()
	for spec: Dictionary in ClientSettings.get_schema():
		settings.set_value(spec["id"], _non_default(spec))
	var seen: Array[StringName] = []
	settings.changed.connect(func(id: StringName, _value: Variant) -> void: seen.append(id))
	settings.reset_tab(ClientSettings.TAB_CAMERA)
	assert_eq(seen.size(), ClientSettings.CAMERA_IDS.size(), "notifies about each setting of the tab")
	for id: StringName in ClientSettings.CAMERA_IDS:
		assert_eq(settings.get_value(id), ClientSettings.get_default(id), "%s restored" % id)
		assert_false(settings.is_stored(id))
	assert_true(settings.get_value(ClientSettings.SHADOWS)
			!= ClientSettings.get_default(ClientSettings.SHADOWS), "the other tabs are not touched")
	assert_true(settings.is_stored(ClientSettings.SHADOWS))
	seen.clear()
	settings.reset_all()
	assert_eq(seen.size(), ClientSettings.get_ids().size() - ClientSettings.CAMERA_IDS.size() - 1,
			"notifies about the ones that change, except the language")
	for spec: Dictionary in ClientSettings.get_schema():
		if spec["id"] == ClientSettings.LANGUAGE:
			assert_true(settings.is_stored(ClientSettings.LANGUAGE), "restoring leaves the language alone")
			assert_false(settings.get_value(ClientSettings.LANGUAGE) == spec["default"])
			continue
		assert_eq(settings.get_value(spec["id"]), spec["default"])
		assert_false(settings.is_stored(spec["id"]))


func test_the_language_is_automatic_by_default_and_is_not_restorable() -> void:
	var spec: Dictionary = ClientSettings.get_spec(ClientSettings.LANGUAGE)
	assert_eq(spec["default"], "auto")
	assert_eq(spec["tab"], ClientSettings.TAB_INTERFACE)
	assert_eq(ClientSettings.get_ids().find(ClientSettings.LANGUAGE),
			ClientSettings.get_ids().find(ClientSettings.DAMAGE_NUMBERS) - 1, "first row of the Interface tab")
	assert_false(ClientSettings.is_restorable(ClientSettings.LANGUAGE))
	assert_true(ClientSettings.is_restorable(ClientSettings.FOV))
	var settings: ClientSettings = ClientSettings.new()
	assert_true(settings.set_value(ClientSettings.LANGUAGE, "en"))
	assert_false(settings.set_value(ClientSettings.LANGUAGE, "fr"), "only auto, en and es")
	settings.reset_tab(ClientSettings.TAB_INTERFACE)
	assert_eq(settings.get_value(ClientSettings.LANGUAGE), "en", "restore tab leaves it alone")
	settings.reset_all()
	assert_eq(settings.get_value(ClientSettings.LANGUAGE), "en", "restore all too")
	assert_true(settings.is_stored(ClientSettings.LANGUAGE))
	settings.reset(ClientSettings.LANGUAGE)
	assert_eq(settings.get_value(ClientSettings.LANGUAGE), "auto", "asking for that setting by name still works")


# --- Conversions ------------------------------------------------------------------------------

func test_conversion_tables() -> void:
	assert_eq(ClientSettings.window_mode_for(ClientSettings.MODE_WINDOWED), DisplayServer.WINDOW_MODE_WINDOWED)
	assert_eq(ClientSettings.window_mode_for(ClientSettings.MODE_FULLSCREEN), DisplayServer.WINDOW_MODE_FULLSCREEN)
	assert_eq(ClientSettings.window_mode_for(ClientSettings.MODE_EXCLUSIVE),
			DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	assert_eq(ClientSettings.window_mode_for(99), DisplayServer.WINDOW_MODE_WINDOWED, "the odd one, window")
	assert_eq(ClientSettings.vsync_mode_for(0), DisplayServer.VSYNC_DISABLED)
	assert_eq(ClientSettings.vsync_mode_for(1), DisplayServer.VSYNC_ENABLED)
	assert_eq(ClientSettings.vsync_mode_for(2), DisplayServer.VSYNC_ADAPTIVE)
	assert_eq(ClientSettings.parse_resolution("1920x1080"), Vector2i(1920, 1080))
	for text: String in ClientSettings.RESOLUTIONS:
		assert_true(ClientSettings.parse_resolution(text) != Vector2i.ZERO, "%s is understood" % text)
	for bad: String in ["", "1920", "1920x", "x1080", "axb", "0x0", "-5x10", "1x2x3"]:
		assert_eq(ClientSettings.parse_resolution(bad), Vector2i.ZERO, "\"%s\" is not a resolution" % bad)
	assert_eq(ClientSettings.antialiasing_for(ClientSettings.AA_NONE)["msaa"], Viewport.MSAA_DISABLED)
	assert_eq(ClientSettings.antialiasing_for(ClientSettings.AA_NONE)["screen_space"],
			Viewport.SCREEN_SPACE_AA_DISABLED)
	assert_eq(ClientSettings.antialiasing_for(ClientSettings.AA_FXAA)["screen_space"],
			Viewport.SCREEN_SPACE_AA_FXAA)
	assert_eq(ClientSettings.antialiasing_for(ClientSettings.AA_FXAA)["msaa"], Viewport.MSAA_DISABLED)
	assert_eq(ClientSettings.antialiasing_for(ClientSettings.AA_MSAA_2X)["msaa"], Viewport.MSAA_2X)
	assert_eq(ClientSettings.antialiasing_for(ClientSettings.AA_MSAA_4X)["msaa"], Viewport.MSAA_4X)
	var previous_atlas: int = 0
	for level: int in 4:
		var profile: Dictionary = ClientSettings.shadow_profile_for(level)
		assert_eq(bool(profile["enabled"]), level > 0, "only level 0 turns the shadows off")
		assert_true(int(profile["atlas"]) >= previous_atlas, "the atlas does not shrink with quality")
		previous_atlas = int(profile["atlas"])
	assert_eq(ClientSettings.shadow_profile_for(3)["atlas"], 4096, "the height is the project's")


# --- Application ------------------------------------------------------------------------------

func test_the_frame_limit_the_render_scale_and_the_antialiasing_are_applied() -> void:
	var settings: ClientSettings = ClientSettings.new()
	settings.set_value(ClientSettings.FPS_LIMIT, 60)
	settings.apply_value(ClientSettings.FPS_LIMIT, tree)
	assert_eq(Engine.max_fps, 60)
	settings.set_value(ClientSettings.FPS_LIMIT, 0)
	settings.apply_value(ClientSettings.FPS_LIMIT, tree)
	assert_eq(Engine.max_fps, 0, "no limit")
	settings.set_value(ClientSettings.RENDER_SCALE, 0.75)
	settings.apply_value(ClientSettings.RENDER_SCALE, tree)
	assert_near(tree.root.scaling_3d_scale, 0.75, 0.0001)
	settings.set_value(ClientSettings.ANTIALIASING, ClientSettings.AA_MSAA_4X)
	settings.apply_value(ClientSettings.ANTIALIASING, tree)
	assert_eq(tree.root.msaa_3d, Viewport.MSAA_4X)
	assert_eq(tree.root.screen_space_aa, Viewport.SCREEN_SPACE_AA_DISABLED)
	settings.set_value(ClientSettings.ANTIALIASING, ClientSettings.AA_FXAA)
	settings.apply_value(ClientSettings.ANTIALIASING, tree)
	assert_eq(tree.root.msaa_3d, Viewport.MSAA_DISABLED)
	assert_eq(tree.root.screen_space_aa, Viewport.SCREEN_SPACE_AA_FXAA)
	settings.set_value(ClientSettings.ANTIALIASING, ClientSettings.AA_NONE)
	settings.apply_value(ClientSettings.ANTIALIASING, tree)
	assert_eq(tree.root.msaa_3d, Viewport.MSAA_DISABLED)
	assert_eq(tree.root.screen_space_aa, Viewport.SCREEN_SPACE_AA_DISABLED)
	# The window is not touched without a screen (and gives no errors).
	for id: StringName in [ClientSettings.WINDOW_MODE, ClientSettings.RESOLUTION, ClientSettings.VSYNC]:
		settings.apply_value(id, tree)


func test_shadow_levels_are_applied_to_the_lights() -> void:
	var on_light: DirectionalLight3D = DirectionalLight3D.new()
	on_light.shadow_enabled = true
	var off_light: OmniLight3D = OmniLight3D.new()
	off_light.shadow_enabled = false
	var root: Node3D = Node3D.new()
	root.add_child(on_light)
	root.add_child(off_light)
	_add(root)
	var settings: ClientSettings = ClientSettings.new()
	settings.set_value(ClientSettings.SHADOWS, ClientSettings.SHADOWS_OFF)
	settings.apply_value(ClientSettings.SHADOWS, tree)
	assert_false(on_light.shadow_enabled, "shadows off: the light loses them")
	assert_false(off_light.shadow_enabled)
	for level: int in [1, 2, 3]:
		settings.set_value(ClientSettings.SHADOWS, level)
		settings.apply_value(ClientSettings.SHADOWS, tree)
		assert_true(on_light.shadow_enabled, "level %d: the shadows come back" % level)
		assert_false(off_light.shadow_enabled, "and the one that did not have them in the scene does not gain them (level %d)" % level)
	assert_eq(tree.root.positional_shadow_atlas_size, 4096)
	settings.set_value(ClientSettings.SHADOWS, 1)
	settings.apply_value(ClientSettings.SHADOWS, tree)
	assert_eq(tree.root.positional_shadow_atlas_size, 1024)
	# A new light with the shadows off.
	var late: DirectionalLight3D = DirectionalLight3D.new()
	late.shadow_enabled = true
	root.add_child(late)
	ClientSettings.apply_light_shadow(late, false)
	assert_false(late.shadow_enabled)
	ClientSettings.apply_light_shadow(late, true)
	assert_true(late.shadow_enabled)


func test_grass_distance_changes_only_the_grass_assets() -> void:
	var assets: Terrain3DAssets = Terrain3DAssets.new()
	var short_grass: Terrain3DMeshAsset = _mesh_asset("Hierba corta", 60.0)
	var dry_grass: Terrain3DMeshAsset = _mesh_asset("Hierba seca", 60.0)
	var pine: Terrain3DMeshAsset = _mesh_asset("Pino 1", 340.0)
	assets.set_mesh_asset(0, short_grass)
	assets.set_mesh_asset(1, dry_grass)
	assets.set_mesh_asset(2, pine)
	assert_eq(ClientSettings.apply_grass_to_assets(assets, 30.0), 2, "touches only the two grasses")
	assert_eq(short_grass.lod0_range, 30.0)
	assert_eq(dry_grass.lod0_range, 30.0)
	assert_eq(pine.lod0_range, 340.0, "the pine does not")
	assert_true(short_grass.enabled)
	ClientSettings.apply_grass_to_assets(assets, 0.0)
	assert_false(short_grass.enabled, "with 0 the grass is removed")
	assert_false(dry_grass.enabled)
	assert_true(pine.enabled)
	ClientSettings.apply_grass_to_assets(assets, 120.0)
	assert_true(short_grass.enabled, "and comes back")
	assert_eq(short_grass.lod0_range, 120.0)
	ClientSettings.apply_grass_to_assets(assets, 60.0)
	assert_eq(short_grass.lod0_range, 60.0, "at the factory value, the scene's")
	assert_eq(ClientSettings.apply_grass_to_assets(null, 30.0), 0)
	var not_assets: Node = Node.new()
	assert_eq(ClientSettings.apply_grass_to_assets(not_assets, 30.0), 0, "something that is not assets")
	not_assets.free()


func _mesh_asset(asset_name: String, lod_range: float) -> Terrain3DMeshAsset:
	var asset: Terrain3DMeshAsset = Terrain3DMeshAsset.new()
	asset.name = asset_name
	asset.last_lod = 0
	asset.lod0_range = lod_range
	return asset


func test_grass_distance_reaches_the_terrain_of_a_zone() -> void:
	var zone: Node3D = (load(ZONE_SCENE_PATH) as PackedScene).instantiate() as Node3D
	_add(zone)
	await wait_physics_frames(2)
	var terrain: Terrain3D = zone.get_node(^"Terrain3D") as Terrain3D
	var grass: Array[Terrain3DMeshAsset] = []
	var trees: Array[Terrain3DMeshAsset] = []
	for index: int in terrain.assets.get_mesh_count():
		var asset: Terrain3DMeshAsset = terrain.assets.get_mesh_asset(index)
		if asset.name.begins_with("Hierba"):
			grass.append(asset)
		elif asset.name.begins_with("Pino"):
			trees.append(asset)
	assert_true(grass.size() >= 2, "Vado Gris has grass")
	assert_false(trees.is_empty())
	var tree_range: float = trees[0].lod0_range
	var settings: ClientSettings = ClientSettings.new()
	settings.set_value(ClientSettings.GRASS_DISTANCE, 20.0)
	settings.apply_value(ClientSettings.GRASS_DISTANCE, tree)
	for asset: Terrain3DMeshAsset in grass:
		assert_eq(asset.lod0_range, 20.0, "%s a 20 m" % asset.name)
	assert_eq(trees[0].lod0_range, tree_range, "the trees are not touched")
	settings.set_value(ClientSettings.GRASS_DISTANCE, 0.0)
	settings.apply_value(ClientSettings.GRASS_DISTANCE, tree)
	for asset: Terrain3DMeshAsset in grass:
		assert_false(asset.enabled)
	settings.reset(ClientSettings.GRASS_DISTANCE)
	settings.apply_value(ClientSettings.GRASS_DISTANCE, tree)
	for asset: Terrain3DMeshAsset in grass:
		assert_true(asset.enabled, "restored")
		assert_eq(asset.lod0_range, 60.0, "with the scene's distance")


func test_volumes_are_applied_to_the_buses() -> void:
	var settings: ClientSettings = ClientSettings.new()
	var sfx: StringName = ClientSettings.volume_id(AudioBuses.SFX)
	settings.set_value(sfx, 0.5)
	settings.apply_value(sfx, tree)
	assert_near(AudioBuses.get_volume(AudioBuses.SFX), 0.5, 0.001)
	settings.set_value(sfx, 0.0)
	settings.apply_value(sfx, tree)
	assert_true(AudioServer.is_bus_mute(AudioServer.get_bus_index(AudioBuses.SFX)), "with 0, muted")
	settings.set_value(ClientSettings.volume_id(AudioBuses.MASTER), 0.25)
	settings.apply_all(tree)
	assert_near(AudioBuses.get_volume(AudioBuses.MASTER), 0.25, 0.001)
	assert_near(AudioBuses.get_volume(AudioBuses.MUSIC), AudioBuses.default_volume(AudioBuses.MUSIC),
			0.001, "apply_all also applies the factory ones")


func test_camera_settings_are_applied_to_every_rig() -> void:
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	var other: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	ClientSettings.set_current(ClientSettings.new())
	_add(rig)
	_add(other)
	assert_true(rig.is_in_group(CameraRig.GROUP), "the camera registers itself in the group")
	assert_eq(rig.mouse_sensitivity, CameraRig.DEFAULT_MOUSE_SENSITIVITY, "without settings, as always")
	assert_eq(rig.get_fov(), 72.0)
	assert_eq(rig.get_chosen_shoulder(), 1)
	assert_false(rig.invert_y)
	var settings: ClientSettings = ClientSettings.new()
	settings.set_value(ClientSettings.MOUSE_SENSITIVITY, 2.0)
	settings.set_value(ClientSettings.INVERT_Y, true)
	settings.set_value(ClientSettings.FOV, 90.0)
	settings.set_value(ClientSettings.DEFAULT_SHOULDER, -1)
	for id: StringName in ClientSettings.CAMERA_IDS:
		settings.apply_value(id, tree)
	for each: CameraRig in [rig, other]:
		assert_near(each.mouse_sensitivity, CameraRig.DEFAULT_MOUSE_SENSITIVITY * 2.0, 0.000001)
		assert_true(each.invert_y)
		assert_eq(each.get_fov(), 90.0)
		assert_eq(each.get_camera().fov, 90.0)
		assert_eq(each.get_chosen_shoulder(), -1)
	settings.set_value(ClientSettings.DEFAULT_SHOULDER, 1)
	settings.apply_to_camera(rig)
	assert_eq(rig.get_chosen_shoulder(), 1)
	assert_eq(other.get_chosen_shoulder(), -1, "apply_to_camera only touches the one it is given")
	# A new camera takes what the player had saved (and only that).
	var saved: ClientSettings = ClientSettings.new()
	saved.set_value(ClientSettings.FOV, 65.0)
	ClientSettings.set_current(saved)
	var late: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(late)
	assert_eq(late.get_fov(), 65.0, "what was saved is applied on creation")
	assert_eq(late.mouse_sensitivity, CameraRig.DEFAULT_MOUSE_SENSITIVITY, "and what was not, is not touched")


func test_the_camera_rig_api_for_the_settings() -> void:
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	ClientSettings.set_current(ClientSettings.new())
	_add(rig)
	rig.set_fov(80.0)
	assert_eq(rig.get_fov(), 80.0)
	rig.set_default_shoulder(-1)
	assert_eq(rig.get_chosen_shoulder(), -1)
	rig.set_default_shoulder(1)
	assert_eq(rig.get_chosen_shoulder(), 1)
	rig.set_default_shoulder(-5)
	assert_eq(rig.get_chosen_shoulder(), -1, "any negative is the left one")


func test_interface_settings_show_and_hide_their_controls() -> void:
	var settings: ClientSettings = ClientSettings.new()
	ClientSettings.set_current(settings)
	var numbers: Control = _add(Control.new()) as Control
	var plates: Control = _add(Control.new()) as Control
	ClientSettings.bind_visibility(numbers, ClientSettings.DAMAGE_NUMBERS)
	ClientSettings.bind_visibility(plates, ClientSettings.NAMEPLATES)
	assert_true(numbers.visible, "without saved settings, as it was")
	settings.set_value(ClientSettings.DAMAGE_NUMBERS, false)
	assert_false(numbers.visible, "it is hidden live")
	assert_true(plates.visible, "and the other one is not")
	settings.set_value(ClientSettings.DAMAGE_NUMBERS, true)
	assert_true(numbers.visible)
	settings.set_value(ClientSettings.NAMEPLATES, false)
	assert_false(plates.visible)
	# A control that is born with the setting already saved is born hidden.
	var late: Control = _add(Control.new()) as Control
	ClientSettings.bind_visibility(late, ClientSettings.NAMEPLATES)
	assert_false(late.visible, "what was saved is applied at startup")
	# A freed control is no longer touched (and gives no errors).
	tree.root.remove_child(plates)
	_nodes.erase(plates)
	plates.free()
	settings.set_value(ClientSettings.NAMEPLATES, true)
	assert_true(numbers.visible)


func test_the_real_hud_nodes_follow_the_interface_settings() -> void:
	var settings: ClientSettings = ClientSettings.new()
	ClientSettings.set_current(settings)
	var hud: HUD = (load("res://scenes/ui/hud.tscn") as PackedScene).instantiate() as HUD
	_add(hud)
	assert_true(hud.get_damage_numbers().visible)
	assert_true(hud.get_nameplates().visible)
	settings.set_value(ClientSettings.DAMAGE_NUMBERS, false)
	settings.set_value(ClientSettings.NAMEPLATES, false)
	assert_false(hud.get_damage_numbers().visible, "the HUD damage numbers are hidden")
	assert_false(hud.get_nameplates().visible, "and the nameplates")
	settings.reset_all()
	assert_true(hud.get_damage_numbers().visible)
	assert_true(hud.get_nameplates().visible)
