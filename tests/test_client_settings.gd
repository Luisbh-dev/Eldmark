extends TestCase
## Pruebas de los ajustes del jugador (UI-16): la tabla de ajustes, la validación, el archivo
## (ida y vuelta, tolerancia a basura, conservar el resto), las conversiones y la aplicación de cada
## valor al motor, al audio, a las cámaras, a las luces, a la hierba y a la interfaz.
## [br][br]
## Los ajustes de la ventana (modo, resolución y vsync) no se aplican en modo headless (no hay
## ventana): se prueban sus tablas de conversión. Todo lo que cambia estado global (FPS, escala,
## suavizado, sombras, volúmenes) se restaura al terminar cada prueba.

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


# Un valor válido y distinto del de fábrica para cada ajuste.
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
	# Un valor intermedio, para no probar solo los extremos.
	return snappedf(lerpf(candidate, default, 0.3), float(spec["step"]))


# --- La tabla ---------------------------------------------------------------------------------

func test_the_schema_covers_every_requested_setting() -> void:
	var ids: Array[StringName] = ClientSettings.get_ids()
	for id: StringName in [ClientSettings.WINDOW_MODE, ClientSettings.RESOLUTION,
			ClientSettings.VSYNC, ClientSettings.FPS_LIMIT, ClientSettings.RENDER_SCALE,
			ClientSettings.SHADOWS, ClientSettings.GRASS_DISTANCE, ClientSettings.ANTIALIASING,
			ClientSettings.MOUSE_SENSITIVITY, ClientSettings.INVERT_Y, ClientSettings.FOV,
			ClientSettings.DEFAULT_SHOULDER, ClientSettings.DAMAGE_NUMBERS,
			ClientSettings.NAMEPLATES, ClientSettings.HINTS]:
		assert_true(ids.has(id), "falta el ajuste %s" % id)
	for bus: StringName in AudioBuses.ALL:
		assert_true(ids.has(ClientSettings.volume_id(bus)), "falta el volumen de %s" % bus)
	assert_eq(ids.size(), 15 + AudioBuses.ALL.size())
	var seen_ids: Dictionary = {}
	var seen_keys: Dictionary = {}
	for spec: Dictionary in ClientSettings.get_schema():
		var id: StringName = spec["id"]
		assert_false(seen_ids.has(id), "id repetido %s" % id)
		seen_ids[id] = true
		var file_key: String = "%s/%s" % [spec["section"], spec["key"]]
		assert_false(seen_keys.has(file_key), "clave repetida %s" % file_key)
		seen_keys[file_key] = true
		assert_true(ClientSettings.TABS.has(spec["tab"]), "%s tiene una pestaña válida" % id)
		assert_false(String(spec["label"]).is_empty(), "%s tiene texto en español" % id)
		assert_eq(ClientSettings.normalize(spec, spec["default"]), spec["default"],
				"el valor por defecto de %s es válido" % id)
		match int(spec["kind"]):
			ClientSettings.Kind.CHOICE:
				assert_eq((spec["values"] as Array).size(), (spec["labels"] as Array).size())
				assert_true((spec["values"] as Array).has(spec["default"]))
			ClientSettings.Kind.RANGE:
				assert_true(float(spec["min"]) < float(spec["max"]))
				assert_true(float(spec["step"]) > 0.0)
	for tab: StringName in ClientSettings.TABS:
		assert_true(ClientSettings.TAB_NAMES.has(tab))
	# Las claves de audio son las mismas que las de AudioBuses.
	for bus: StringName in AudioBuses.ALL:
		var spec: Dictionary = ClientSettings.get_spec(ClientSettings.volume_id(bus))
		assert_eq(spec["section"], String(AudioBuses.SETTINGS_SECTION))
		assert_eq(spec["key"], AudioBuses.volume_key(bus))
		assert_eq(spec["default"], AudioBuses.default_volume(bus))
	assert_true(ClientSettings.get_spec(&"no_existe").is_empty())
	assert_null(ClientSettings.get_default(&"no_existe"))


func test_defaults_match_what_the_project_already_does() -> void:
	# Los valores por defecto no cambian nada del cliente de antes (ventana, MSAA 4x del proyecto,
	# sensibilidad, campo de visión y hombro de la escena de la cámara).
	assert_eq(ClientSettings.get_default(ClientSettings.RESOLUTION), "1600x900")
	assert_eq(ClientSettings.get_default(ClientSettings.ANTIALIASING), ClientSettings.AA_MSAA_4X)
	assert_eq(ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d"),
			Viewport.MSAA_4X, "el proyecto usa MSAA 4x (msaa_3d=2 en project.godot)")
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
		assert_false(settings.is_stored(spec["id"]), "%s sin tocar" % spec["id"])
	assert_false(settings.is_dirty())
	assert_null(settings.get_value(&"no_existe"))


# --- Validación -------------------------------------------------------------------------------

func test_values_are_validated_and_normalized() -> void:
	var settings: ClientSettings = ClientSettings.new()
	# Rangos: se limitan y se ajustan al paso.
	assert_true(settings.set_value(ClientSettings.FOV, 500.0))
	assert_eq(settings.get_value(ClientSettings.FOV), 100.0, "limitado al máximo")
	settings.set_value(ClientSettings.FOV, -3)
	assert_eq(settings.get_value(ClientSettings.FOV), 60.0, "y al mínimo (un entero también vale)")
	settings.set_value(ClientSettings.FOV, 80.4)
	assert_eq(settings.get_value(ClientSettings.FOV), 80.0, "ajustado al paso de 1")
	settings.set_value(ClientSettings.RENDER_SCALE, 0.77)
	assert_near(float(settings.get_value(ClientSettings.RENDER_SCALE)), 0.75, 0.0001,
			"ajustado al paso de 0,05")
	assert_false(settings.set_value(ClientSettings.FOV, "ancho"), "un texto no es un número")
	assert_false(settings.set_value(ClientSettings.FOV, NAN), "NaN no vale")
	assert_false(settings.set_value(ClientSettings.FOV, null))
	assert_eq(settings.get_value(ClientSettings.FOV), 80.0, "lo rechazado no cambia nada")
	# Listas: solo sus valores.
	assert_true(settings.set_value(ClientSettings.FPS_LIMIT, 144))
	assert_eq(settings.get_value(ClientSettings.FPS_LIMIT), 144)
	assert_true(settings.set_value(ClientSettings.FPS_LIMIT, 60.0), "un decimal entero se acepta")
	assert_eq(typeof(settings.get_value(ClientSettings.FPS_LIMIT)), TYPE_INT)
	assert_false(settings.set_value(ClientSettings.FPS_LIMIT, 100), "100 no está en la lista")
	assert_false(settings.set_value(ClientSettings.FPS_LIMIT, "60"))
	assert_eq(settings.get_value(ClientSettings.FPS_LIMIT), 60)
	assert_true(settings.set_value(ClientSettings.RESOLUTION, "1920x1080"))
	assert_false(settings.set_value(ClientSettings.RESOLUTION, "800x600"))
	assert_false(settings.set_value(ClientSettings.RESOLUTION, 1080))
	assert_true(settings.set_value(ClientSettings.DEFAULT_SHOULDER, -1))
	assert_eq(settings.get_value(ClientSettings.DEFAULT_SHOULDER), -1)
	# Interruptores: un booleano (o 0 y 1).
	assert_true(settings.set_value(ClientSettings.INVERT_Y, true))
	assert_eq(settings.get_value(ClientSettings.INVERT_Y), true)
	assert_true(settings.set_value(ClientSettings.INVERT_Y, 0))
	assert_eq(settings.get_value(ClientSettings.INVERT_Y), false)
	assert_false(settings.set_value(ClientSettings.INVERT_Y, 2))
	assert_false(settings.set_value(ClientSettings.INVERT_Y, "sí"))
	assert_false(settings.set_value(&"no_existe", 1), "un ajuste que no existe")
	# Volúmenes: 0 a 1.
	var music: StringName = ClientSettings.volume_id(AudioBuses.MUSIC)
	settings.set_value(music, 3.0)
	assert_eq(settings.get_value(music), 1.0)
	settings.set_value(music, 0.123)
	assert_near(float(settings.get_value(music)), 0.10, 0.0001, "al paso de 0,05")


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
	assert_eq(seen.size(), 1, "el mismo valor no vuelve a avisar")
	settings.set_value(ClientSettings.FOV, 999.0)
	assert_eq(seen.size(), 2, "pero uno que se normaliza a otro sí")
	settings.set_value(ClientSettings.FOV, "mal")
	assert_eq(seen.size(), 2, "ni lo rechazado")
	settings.set_value(ClientSettings.FOV, 72.0)
	assert_true(settings.is_stored(ClientSettings.FOV), "fijarlo al valor de fábrica también es una elección")
	settings.reset(ClientSettings.FOV)
	assert_false(settings.is_stored(ClientSettings.FOV))
	assert_eq(settings.get_value(ClientSettings.FOV), 72.0)
	settings.reset(ClientSettings.FOV)
	settings.reset(&"no_existe")


func test_formatting_values_for_the_menu() -> void:
	assert_eq(ClientSettings.format_value(ClientSettings.RENDER_SCALE, 0.75), "75 %")
	assert_eq(ClientSettings.format_value(ClientSettings.MOUSE_SENSITIVITY, 1.25), "x1,25")
	assert_eq(ClientSettings.format_value(ClientSettings.FOV, 90.0), "90°")
	assert_eq(ClientSettings.format_value(ClientSettings.GRASS_DISTANCE, 60.0), "60 m")
	assert_eq(ClientSettings.format_value(ClientSettings.GRASS_DISTANCE, 0.0), "Desactivada")
	assert_eq(ClientSettings.format_value(ClientSettings.INVERT_Y, true), "Sí")
	assert_eq(ClientSettings.format_value(ClientSettings.INVERT_Y, false), "No")
	assert_eq(ClientSettings.format_value(ClientSettings.FPS_LIMIT, 0), "Sin límite")
	assert_eq(ClientSettings.format_value(ClientSettings.FPS_LIMIT, 144), "144 FPS")
	assert_eq(ClientSettings.format_value(ClientSettings.DEFAULT_SHOULDER, -1), "Izquierdo")
	assert_eq(ClientSettings.format_value(ClientSettings.RESOLUTION, "1920x1080"), "1920 x 1080")
	assert_eq(ClientSettings.format_value(&"no_existe", 5), "5")


# --- Archivo ----------------------------------------------------------------------------------

func test_settings_round_trip_through_the_file() -> void:
	var settings: ClientSettings = ClientSettings.new()
	var expected: Dictionary = {}
	for spec: Dictionary in ClientSettings.get_schema():
		var value: Variant = _non_default(spec)
		assert_true(settings.set_value(spec["id"], value), "se fija %s" % spec["id"])
		expected[spec["id"]] = settings.get_value(spec["id"])
		assert_true(expected[spec["id"]] != spec["default"], "%s ya no es el de fábrica" % spec["id"])
	assert_true(settings.is_dirty())
	assert_eq(settings.save_file(TEST_PATH), OK)
	assert_false(settings.is_dirty(), "tras guardar no queda nada pendiente")
	var loaded: ClientSettings = ClientSettings.load_from(TEST_PATH)
	assert_eq(loaded.path, TEST_PATH)
	assert_false(loaded.is_dirty())
	for spec: Dictionary in ClientSettings.get_schema():
		var id: StringName = spec["id"]
		assert_true(loaded.is_stored(id), "%s se guardó" % id)
		if typeof(expected[id]) == TYPE_FLOAT:
			assert_near(float(loaded.get_value(id)), float(expected[id]), 0.001, "%s tras cargar" % id)
		else:
			assert_eq(loaded.get_value(id), expected[id], "%s tras cargar" % id)
	# El archivo es un cfg de texto con una sección por grupo.
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(TEST_PATH), OK)
	for section: String in ["graphics", "audio", "camera", "interface"]:
		assert_true(config.has_section(section), "sección %s" % section)
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
	assert_eq(settings.get_value(ClientSettings.INVERT_Y), true, "lee lo que había")
	assert_eq(settings.get_value(ClientSettings.SHADOWS), 1)
	assert_true(settings.is_stored(ClientSettings.INVERT_Y))
	settings.set_value(ClientSettings.FOV, 85.0)
	settings.reset(ClientSettings.SHADOWS)
	assert_eq(settings.save_file(TEST_PATH), OK)
	var back: ConfigFile = ConfigFile.new()
	assert_eq(back.load(TEST_PATH), OK)
	assert_eq(back.get_value("otra_cosa", "dato"), 7, "lo ajeno se conserva")
	assert_eq(back.get_value("camera", "invert_y"), true)
	assert_eq(float(back.get_value("camera", "fov")), 85.0)
	assert_false(back.has_section_key("graphics", "shadows"), "un ajuste restaurado se quita")
	assert_false(back.has_section_key("camera", "mouse_sensitivity"), "y lo que no se tocó no se escribe")
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
	assert_eq(settings.get_value(ClientSettings.FPS_LIMIT), 0, "100 FPS no está en la lista")
	assert_eq(settings.get_value(ClientSettings.RESOLUTION), "1600x900")
	assert_eq(settings.get_value(ClientSettings.RENDER_SCALE), 0.5, "se limita al mínimo")
	assert_eq(settings.get_value(ClientSettings.GRASS_DISTANCE), 60.0, "un texto, el de fábrica")
	assert_eq(settings.get_value(ClientSettings.FOV), 100.0, "se limita al máximo")
	assert_eq(settings.get_value(ClientSettings.INVERT_Y), false)
	assert_eq(settings.get_value(ClientSettings.DEFAULT_SHOULDER), 1)
	assert_eq(settings.get_value(ClientSettings.NAMEPLATES), false, "y lo bueno sí se lee")
	assert_false(settings.is_stored(ClientSettings.FPS_LIMIT), "lo inválido no cuenta como del jugador")
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
	assert_eq(settings.save_file(TEST_PATH), OK, "y se puede guardar encima")
	assert_eq(ClientSettings.load_from(TEST_PATH).get_value(ClientSettings.FOV), 80.0)


func test_dirty_settings_are_saved_to_their_own_path() -> void:
	var settings: ClientSettings = ClientSettings.load_from(TEST_PATH)
	settings.save_if_dirty()
	assert_false(FileAccess.file_exists(TEST_PATH), "sin cambios no escribe nada")
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
	assert_not_null(ClientSettings.current(), "se vuelve a cargar al pedirlos")
	assert_true(ClientSettings.current() != custom)


# --- Restaurar --------------------------------------------------------------------------------

func test_restoring_a_tab_or_everything_goes_back_to_the_defaults() -> void:
	var settings: ClientSettings = ClientSettings.new()
	for spec: Dictionary in ClientSettings.get_schema():
		settings.set_value(spec["id"], _non_default(spec))
	var seen: Array[StringName] = []
	settings.changed.connect(func(id: StringName, _value: Variant) -> void: seen.append(id))
	settings.reset_tab(ClientSettings.TAB_CAMERA)
	assert_eq(seen.size(), ClientSettings.CAMERA_IDS.size(), "avisa de cada ajuste de la pestaña")
	for id: StringName in ClientSettings.CAMERA_IDS:
		assert_eq(settings.get_value(id), ClientSettings.get_default(id), "%s restaurado" % id)
		assert_false(settings.is_stored(id))
	assert_true(settings.get_value(ClientSettings.SHADOWS)
			!= ClientSettings.get_default(ClientSettings.SHADOWS), "las demás pestañas no se tocan")
	assert_true(settings.is_stored(ClientSettings.SHADOWS))
	seen.clear()
	settings.reset_all()
	assert_eq(seen.size(), ClientSettings.get_ids().size() - ClientSettings.CAMERA_IDS.size(),
			"avisa de los que cambian")
	for spec: Dictionary in ClientSettings.get_schema():
		assert_eq(settings.get_value(spec["id"]), spec["default"])
		assert_false(settings.is_stored(spec["id"]))


# --- Conversiones -----------------------------------------------------------------------------

func test_conversion_tables() -> void:
	assert_eq(ClientSettings.window_mode_for(ClientSettings.MODE_WINDOWED), DisplayServer.WINDOW_MODE_WINDOWED)
	assert_eq(ClientSettings.window_mode_for(ClientSettings.MODE_FULLSCREEN), DisplayServer.WINDOW_MODE_FULLSCREEN)
	assert_eq(ClientSettings.window_mode_for(ClientSettings.MODE_EXCLUSIVE),
			DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	assert_eq(ClientSettings.window_mode_for(99), DisplayServer.WINDOW_MODE_WINDOWED, "lo raro, ventana")
	assert_eq(ClientSettings.vsync_mode_for(0), DisplayServer.VSYNC_DISABLED)
	assert_eq(ClientSettings.vsync_mode_for(1), DisplayServer.VSYNC_ENABLED)
	assert_eq(ClientSettings.vsync_mode_for(2), DisplayServer.VSYNC_ADAPTIVE)
	assert_eq(ClientSettings.parse_resolution("1920x1080"), Vector2i(1920, 1080))
	for text: String in ClientSettings.RESOLUTIONS:
		assert_true(ClientSettings.parse_resolution(text) != Vector2i.ZERO, "%s se entiende" % text)
	for bad: String in ["", "1920", "1920x", "x1080", "axb", "0x0", "-5x10", "1x2x3"]:
		assert_eq(ClientSettings.parse_resolution(bad), Vector2i.ZERO, "«%s» no es una resolución" % bad)
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
		assert_eq(bool(profile["enabled"]), level > 0, "solo el nivel 0 apaga las sombras")
		assert_true(int(profile["atlas"]) >= previous_atlas, "el atlas no encoge con la calidad")
		previous_atlas = int(profile["atlas"])
	assert_eq(ClientSettings.shadow_profile_for(3)["atlas"], 4096, "el alto es el del proyecto")


# --- Aplicación -------------------------------------------------------------------------------

func test_the_frame_limit_the_render_scale_and_the_antialiasing_are_applied() -> void:
	var settings: ClientSettings = ClientSettings.new()
	settings.set_value(ClientSettings.FPS_LIMIT, 60)
	settings.apply_value(ClientSettings.FPS_LIMIT, tree)
	assert_eq(Engine.max_fps, 60)
	settings.set_value(ClientSettings.FPS_LIMIT, 0)
	settings.apply_value(ClientSettings.FPS_LIMIT, tree)
	assert_eq(Engine.max_fps, 0, "sin límite")
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
	# La ventana no se toca sin pantalla (y no da errores).
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
	assert_false(on_light.shadow_enabled, "sombras desactivadas: la luz las pierde")
	assert_false(off_light.shadow_enabled)
	for level: int in [1, 2, 3]:
		settings.set_value(ClientSettings.SHADOWS, level)
		settings.apply_value(ClientSettings.SHADOWS, tree)
		assert_true(on_light.shadow_enabled, "nivel %d: vuelven las sombras" % level)
		assert_false(off_light.shadow_enabled, "y la que no las tenía en la escena no las gana (nivel %d)" % level)
	assert_eq(tree.root.positional_shadow_atlas_size, 4096)
	settings.set_value(ClientSettings.SHADOWS, 1)
	settings.apply_value(ClientSettings.SHADOWS, tree)
	assert_eq(tree.root.positional_shadow_atlas_size, 1024)
	# Una luz nueva con las sombras apagadas.
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
	assert_eq(ClientSettings.apply_grass_to_assets(assets, 30.0), 2, "toca solo las dos hierbas")
	assert_eq(short_grass.lod0_range, 30.0)
	assert_eq(dry_grass.lod0_range, 30.0)
	assert_eq(pine.lod0_range, 340.0, "el pino no")
	assert_true(short_grass.enabled)
	ClientSettings.apply_grass_to_assets(assets, 0.0)
	assert_false(short_grass.enabled, "con 0 la hierba se quita")
	assert_false(dry_grass.enabled)
	assert_true(pine.enabled)
	ClientSettings.apply_grass_to_assets(assets, 120.0)
	assert_true(short_grass.enabled, "y vuelve")
	assert_eq(short_grass.lod0_range, 120.0)
	ClientSettings.apply_grass_to_assets(assets, 60.0)
	assert_eq(short_grass.lod0_range, 60.0, "al valor de fábrica, el de la escena")
	assert_eq(ClientSettings.apply_grass_to_assets(null, 30.0), 0)
	var not_assets: Node = Node.new()
	assert_eq(ClientSettings.apply_grass_to_assets(not_assets, 30.0), 0, "algo que no son assets")
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
	assert_true(grass.size() >= 2, "el Vado Gris tiene hierba")
	assert_false(trees.is_empty())
	var tree_range: float = trees[0].lod0_range
	var settings: ClientSettings = ClientSettings.new()
	settings.set_value(ClientSettings.GRASS_DISTANCE, 20.0)
	settings.apply_value(ClientSettings.GRASS_DISTANCE, tree)
	for asset: Terrain3DMeshAsset in grass:
		assert_eq(asset.lod0_range, 20.0, "%s a 20 m" % asset.name)
	assert_eq(trees[0].lod0_range, tree_range, "los árboles no se tocan")
	settings.set_value(ClientSettings.GRASS_DISTANCE, 0.0)
	settings.apply_value(ClientSettings.GRASS_DISTANCE, tree)
	for asset: Terrain3DMeshAsset in grass:
		assert_false(asset.enabled)
	settings.reset(ClientSettings.GRASS_DISTANCE)
	settings.apply_value(ClientSettings.GRASS_DISTANCE, tree)
	for asset: Terrain3DMeshAsset in grass:
		assert_true(asset.enabled, "restaurada")
		assert_eq(asset.lod0_range, 60.0, "con la distancia de la escena")


func test_volumes_are_applied_to_the_buses() -> void:
	var settings: ClientSettings = ClientSettings.new()
	var sfx: StringName = ClientSettings.volume_id(AudioBuses.SFX)
	settings.set_value(sfx, 0.5)
	settings.apply_value(sfx, tree)
	assert_near(AudioBuses.get_volume(AudioBuses.SFX), 0.5, 0.001)
	settings.set_value(sfx, 0.0)
	settings.apply_value(sfx, tree)
	assert_true(AudioServer.is_bus_mute(AudioServer.get_bus_index(AudioBuses.SFX)), "con 0, silenciado")
	settings.set_value(ClientSettings.volume_id(AudioBuses.MASTER), 0.25)
	settings.apply_all(tree)
	assert_near(AudioBuses.get_volume(AudioBuses.MASTER), 0.25, 0.001)
	assert_near(AudioBuses.get_volume(AudioBuses.MUSIC), AudioBuses.default_volume(AudioBuses.MUSIC),
			0.001, "apply_all aplica también los de fábrica")


func test_camera_settings_are_applied_to_every_rig() -> void:
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	var other: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	ClientSettings.set_current(ClientSettings.new())
	_add(rig)
	_add(other)
	assert_true(rig.is_in_group(CameraRig.GROUP), "la cámara se apunta al grupo")
	assert_eq(rig.mouse_sensitivity, CameraRig.DEFAULT_MOUSE_SENSITIVITY, "sin ajustes, como siempre")
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
	assert_eq(other.get_chosen_shoulder(), -1, "apply_to_camera solo toca la que se le da")
	# Una cámara nueva toma lo que el jugador tenía guardado (y solo eso).
	var saved: ClientSettings = ClientSettings.new()
	saved.set_value(ClientSettings.FOV, 65.0)
	ClientSettings.set_current(saved)
	var late: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(late)
	assert_eq(late.get_fov(), 65.0, "lo guardado se aplica al crearse")
	assert_eq(late.mouse_sensitivity, CameraRig.DEFAULT_MOUSE_SENSITIVITY, "y lo que no, no se toca")


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
	assert_eq(rig.get_chosen_shoulder(), -1, "cualquier negativo es el izquierdo")


func test_interface_settings_show_and_hide_their_controls() -> void:
	var settings: ClientSettings = ClientSettings.new()
	ClientSettings.set_current(settings)
	var numbers: Control = _add(Control.new()) as Control
	var plates: Control = _add(Control.new()) as Control
	ClientSettings.bind_visibility(numbers, ClientSettings.DAMAGE_NUMBERS)
	ClientSettings.bind_visibility(plates, ClientSettings.NAMEPLATES)
	assert_true(numbers.visible, "sin ajustes guardados, como estaba")
	settings.set_value(ClientSettings.DAMAGE_NUMBERS, false)
	assert_false(numbers.visible, "se oculta en vivo")
	assert_true(plates.visible, "y la otra no")
	settings.set_value(ClientSettings.DAMAGE_NUMBERS, true)
	assert_true(numbers.visible)
	settings.set_value(ClientSettings.NAMEPLATES, false)
	assert_false(plates.visible)
	# Un control que nace con el ajuste ya guardado nace oculto.
	var late: Control = _add(Control.new()) as Control
	ClientSettings.bind_visibility(late, ClientSettings.NAMEPLATES)
	assert_false(late.visible, "lo guardado se aplica al arrancar")
	# Un control liberado ya no se toca (ni da errores).
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
	assert_false(hud.get_damage_numbers().visible, "los números de daño del HUD se ocultan")
	assert_false(hud.get_nameplates().visible, "y las placas")
	settings.reset_all()
	assert_true(hud.get_damage_numbers().visible)
	assert_true(hud.get_nameplates().visible)
