class_name ClientSettings
extends RefCounted
## Ajustes del jugador (UI-16): gráficos, audio por bus, cámara e interfaz, guardados en
## [code]user://settings.cfg[/code], aplicados en vivo y al arrancar.
## [br][br]
## [b]Datos.[/b] Cada ajuste tiene una definición en [method get_schema]: identificador, pestaña,
## sección y clave del archivo, texto en español, valor por defecto y su tipo ([enum Kind]): un
## interruptor, una lista de valores permitidos o un rango con paso. [method set_value] valida y
## normaliza (limita a rango, ajusta al paso, rechaza lo que no está en la lista) y emite
## [signal changed] solo si el valor cambia. [SettingsMenu] se construye leyendo esta tabla.
## [br][br]
## [b]Archivo.[/b] [method save] escribe solo los ajustes que el jugador ha tocado
## ([method is_stored]) y conserva las demás secciones que hubiera en el archivo; [method load] lee
## lo que haya y deja el valor por defecto en lo que falte o esté mal (un archivo a mano con basura no
## rompe nada). Los volúmenes usan las mismas claves que [AudioBuses].
## [br][br]
## [b]Aplicación.[/b] [method apply_value] aplica un ajuste al motor y a la escena y
## [method apply_all] los aplica todos; con [param stored_only] solo los que el jugador ha guardado,
## que es lo que se hace al arrancar para que el cliente sin ajustes guardados arranque exactamente
## igual que siempre (la ventana, el vsync o el suavizado del proyecto no se pisan con los valores
## por defecto). Gráficos: modo de ventana, resolución, vsync, límite de FPS, escala de render,
## calidad de sombras (también apaga las luces con sombras si se desactivan), distancia de la hierba
## (el último nivel de LOD de los [code]Terrain3DMeshAsset[/code] de hierba) y suavizado. Audio:
## [AudioBuses]. Cámara: sensibilidad, invertir Y, campo de visión y hombro por defecto en cada
## [CameraRig] (grupo [constant CameraRig.GROUP]). Interfaz: los controles enlazados con
## [method bind_visibility] ([DamageNumbers], [Nameplates], la línea de ayuda del [HUD]) se muestran u ocultan solos y las pistas
## ([HintToasts]) leen [constant HINTS] al mostrarse.
## [br][br]
## El modo de ventana, la resolución y el vsync no se tocan en modo headless (no hay ventana):
## sus tablas de conversión ([method window_mode_for], [method vsync_mode_for],
## [method parse_resolution]) son funciones puras que prueban las pruebas.
## [br][br]
## Solo cliente.

## Un ajuste cambió de valor (también al restaurar). [param value] ya está normalizado.
signal changed(id: StringName, value: Variant)

## Tipos de ajuste.
enum Kind { BOOL, CHOICE, RANGE }

const PATH: String = "user://settings.cfg"

# Pestañas.
const TAB_GRAPHICS: StringName = &"graphics"
const TAB_AUDIO: StringName = &"audio"
const TAB_CAMERA: StringName = &"camera"
const TAB_INTERFACE: StringName = &"interface"
## Pestañas en orden, con su texto en español.
const TABS: Array[StringName] = [TAB_GRAPHICS, TAB_AUDIO, TAB_CAMERA, TAB_INTERFACE]
const TAB_NAMES: Dictionary = {
	TAB_GRAPHICS: "Gráficos", TAB_AUDIO: "Audio", TAB_CAMERA: "Cámara", TAB_INTERFACE: "Interfaz",
}

# Identificadores de los ajustes (la clave del archivo es la misma, salvo los volúmenes).
const WINDOW_MODE: StringName = &"window_mode"
const RESOLUTION: StringName = &"resolution"
const VSYNC: StringName = &"vsync"
const FPS_LIMIT: StringName = &"fps_limit"
const RENDER_SCALE: StringName = &"render_scale"
const SHADOWS: StringName = &"shadows"
const GRASS_DISTANCE: StringName = &"grass_distance"
const ANTIALIASING: StringName = &"antialiasing"
const MOUSE_SENSITIVITY: StringName = &"mouse_sensitivity"
const INVERT_Y: StringName = &"invert_y"
const FOV: StringName = &"fov"
const DEFAULT_SHOULDER: StringName = &"default_shoulder"
const DAMAGE_NUMBERS: StringName = &"damage_numbers"
const NAMEPLATES: StringName = &"nameplates"
## Pistas del juego (UI-42): consejos que salen una sola vez por jugador ([HintToasts]).
const HINTS: StringName = &"hints"
## Línea de ayuda con las teclas, abajo en el centro del HUD (UI-49): oculta por defecto, F1 la muestra y la oculta.
const HELP_BAR: StringName = &"help_bar"
## Ajustes de cámara, de gráficos que recorren la escena y de interfaz.
const CAMERA_IDS: Array[StringName] = [MOUSE_SENSITIVITY, INVERT_Y, FOV, DEFAULT_SHOULDER]
const INTERFACE_IDS: Array[StringName] = [DAMAGE_NUMBERS, NAMEPLATES, HINTS, HELP_BAR]

## Resoluciones de ventana que se ofrecen (texto «ancho x alto» sin espacios).
const RESOLUTIONS: Array[String] = ["1280x720", "1600x900", "1920x1080", "2560x1440"]
## Límites de FPS que se ofrecen (0 = sin límite).
const FPS_LIMITS: Array[int] = [0, 30, 60, 90, 120, 144, 165, 240]
## Valores de [constant WINDOW_MODE]: ventana, pantalla completa sin bordes y exclusiva.
const MODE_WINDOWED: int = 0
const MODE_FULLSCREEN: int = 1
const MODE_EXCLUSIVE: int = 2
## Niveles de [constant SHADOWS]: desactivadas, bajas, medias y altas.
const SHADOWS_OFF: int = 0
const SHADOWS_HIGH: int = 3
## Valores de [constant ANTIALIASING]: ninguno, FXAA, MSAA 2x y MSAA 4x (el del proyecto).
const AA_NONE: int = 0
const AA_FXAA: int = 1
const AA_MSAA_2X: int = 2
const AA_MSAA_4X: int = 3
## Metadato de una luz con su [member Light3D.shadow_enabled] original.
const LIGHT_SHADOW_META: StringName = &"client_settings_shadow_default"
## Metadato de un recurso de hierba con sus valores originales.
const GRASS_META: StringName = &"client_settings_grass_default"
## Un [code]Terrain3DMeshAsset[/code] es hierba si su nombre empieza así.
const GRASS_ASSET_PREFIXES: Array[String] = ["Hierba", "Grass"]

static var _schema: Array[Dictionary] = []
static var _current: ClientSettings = null

## Archivo donde se guarda ([method save_if_dirty]); el de [method load_from].
var path: String = PATH

var _values: Dictionary = {}
var _stored: Dictionary = {}
var _dirty: bool = false


# --- La tabla de ajustes ----------------------------------------------------------------------

## Definición de todos los ajustes, en el orden en que los muestran los ajustes. Cada diccionario:
## [code]id[/code], [code]tab[/code], [code]section[/code], [code]key[/code] (archivo),
## [code]label[/code] (español), [code]kind[/code] ([enum Kind]), [code]default[/code] y, según el tipo,
## [code]values[/code] y [code]labels[/code] (lista) o [code]min[/code], [code]max[/code],
## [code]step[/code] y [code]format[/code] ([code]percent[/code], [code]multiplier[/code],
## [code]degrees[/code] o [code]meters[/code]).
static func get_schema() -> Array[Dictionary]:
	if _schema.is_empty():
		_schema = _build_schema()
	return _schema


## Identificadores de todos los ajustes, en orden.
static func get_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for spec: Dictionary in get_schema():
		ids.append(spec["id"])
	return ids


## Definición del ajuste [param id] (vacía si no existe).
static func get_spec(id: StringName) -> Dictionary:
	for spec: Dictionary in get_schema():
		if spec["id"] == id:
			return spec
	return {}


## Identificador del volumen del bus [param bus] ([code]volume_sfx[/code]...).
static func volume_id(bus: StringName) -> StringName:
	return StringName(AudioBuses.volume_key(bus))


## Valor por defecto del ajuste [param id] (null si no existe).
static func get_default(id: StringName) -> Variant:
	return get_spec(id).get("default", null)


## Texto de [param value] para mostrarlo junto al control de [param id] («75 %», «x1,25», «90°»,
## «60 m», «Desactivada»...). Para las listas, la etiqueta del valor.
static func format_value(id: StringName, value: Variant) -> String:
	var spec: Dictionary = get_spec(id)
	if spec.is_empty():
		return str(value)
	match int(spec["kind"]):
		Kind.BOOL:
			return "Sí" if bool(value) else "No"
		Kind.CHOICE:
			var index: int = (spec["values"] as Array).find(value)
			return String(spec["labels"][index]) if index >= 0 else str(value)
	var number: float = float(value)
	match String(spec.get("format", "")):
		"percent":
			return "%d %%" % roundi(number * 100.0)
		"multiplier":
			return "x%s" % ("%.2f" % number).replace(".", ",")
		"degrees":
			return "%d°" % roundi(number)
		"meters":
			return "Desactivada" if number <= 0.0 else "%d m" % roundi(number)
	return str(number)


static func _build_schema() -> Array[Dictionary]:
	var schema: Array[Dictionary] = []
	schema.append(_choice(TAB_GRAPHICS, WINDOW_MODE, "Modo de ventana", MODE_WINDOWED,
			[MODE_WINDOWED, MODE_FULLSCREEN, MODE_EXCLUSIVE],
			["Ventana", "Pantalla completa sin bordes", "Pantalla completa exclusiva"]))
	var resolution_labels: Array = []
	for text: String in RESOLUTIONS:
		resolution_labels.append(text.replace("x", " x "))
	schema.append(_choice(TAB_GRAPHICS, RESOLUTION, "Resolución de la ventana", "1600x900",
			RESOLUTIONS, resolution_labels))
	schema.append(_choice(TAB_GRAPHICS, VSYNC, "Sincronía vertical", 1, [0, 1, 2],
			["Desactivada", "Activada", "Adaptativa"]))
	var fps_labels: Array = []
	for limit: int in FPS_LIMITS:
		fps_labels.append("Sin límite" if limit == 0 else "%d FPS" % limit)
	schema.append(_choice(TAB_GRAPHICS, FPS_LIMIT, "Límite de FPS", 0, FPS_LIMITS, fps_labels))
	schema.append(_range(TAB_GRAPHICS, RENDER_SCALE, "Escala de render", 1.0, 0.5, 1.0, 0.05,
			"percent"))
	schema.append(_choice(TAB_GRAPHICS, SHADOWS, "Sombras", SHADOWS_HIGH, [0, 1, 2, 3],
			["Desactivadas", "Bajas", "Medias", "Altas"]))
	schema.append(_range(TAB_GRAPHICS, GRASS_DISTANCE, "Distancia de la hierba", 60.0, 0.0, 120.0,
			10.0, "meters"))
	schema.append(_choice(TAB_GRAPHICS, ANTIALIASING, "Suavizado de bordes", AA_MSAA_4X,
			[AA_NONE, AA_FXAA, AA_MSAA_2X, AA_MSAA_4X],
			["Ninguno", "FXAA", "MSAA 2x", "MSAA 4x"]))
	for bus: StringName in AudioBuses.ALL:
		var spec: Dictionary = _range(TAB_AUDIO, volume_id(bus),
				"Volumen: %s" % AudioBuses.display_name(bus), AudioBuses.default_volume(bus), 0.0,
				1.0, 0.05, "percent")
		spec["section"] = String(AudioBuses.SETTINGS_SECTION)
		spec["bus"] = bus
		schema.append(spec)
	schema.append(_range(TAB_CAMERA, MOUSE_SENSITIVITY, "Sensibilidad del ratón", 1.0, 0.2, 3.0,
			0.05, "multiplier"))
	schema.append(_bool(TAB_CAMERA, INVERT_Y, "Invertir el eje vertical", false))
	schema.append(_range(TAB_CAMERA, FOV, "Campo de visión", 72.0, 60.0, 100.0, 1.0, "degrees"))
	schema.append(_choice(TAB_CAMERA, DEFAULT_SHOULDER, "Hombro por defecto", 1, [1, -1],
			["Derecho", "Izquierdo"]))
	schema.append(_bool(TAB_INTERFACE, DAMAGE_NUMBERS, "Números de daño", true))
	schema.append(_bool(TAB_INTERFACE, NAMEPLATES, "Placas de nombre", true))
	schema.append(_bool(TAB_INTERFACE, HINTS, "Pistas del juego", true))
	schema.append(_bool(TAB_INTERFACE, HELP_BAR, "Línea de ayuda de controles (F1)", false))
	return schema


static func _base(tab: StringName, id: StringName, label: String, kind: Kind,
		default: Variant) -> Dictionary:
	return {"id": id, "tab": tab, "section": String(tab), "key": String(id), "label": label,
			"kind": kind, "default": default}


static func _bool(tab: StringName, id: StringName, label: String, default: bool) -> Dictionary:
	return _base(tab, id, label, Kind.BOOL, default)


static func _choice(tab: StringName, id: StringName, label: String, default: Variant, values: Array,
		labels: Array) -> Dictionary:
	var spec: Dictionary = _base(tab, id, label, Kind.CHOICE, default)
	spec["values"] = values
	spec["labels"] = labels
	return spec


static func _range(tab: StringName, id: StringName, label: String, default: float, minimum: float,
		maximum: float, step: float, format: String) -> Dictionary:
	var spec: Dictionary = _base(tab, id, label, Kind.RANGE, default)
	spec["min"] = minimum
	spec["max"] = maximum
	spec["step"] = step
	spec["format"] = format
	return spec


# --- El ajuste en uso --------------------------------------------------------------------------

## Los ajustes del cliente: se cargan de [constant PATH] la primera vez que se piden.
static func current() -> ClientSettings:
	if _current == null:
		_current = load_from(PATH)
	return _current


## Sustituye los ajustes en uso (null los olvida y se vuelven a cargar del archivo al pedirlos).
static func set_current(settings: ClientSettings) -> void:
	_current = settings


## Ajustes cargados de [param file_path] (valores por defecto si no existe o está mal).
static func load_from(file_path: String) -> ClientSettings:
	var settings: ClientSettings = ClientSettings.new()
	settings.path = file_path
	settings.load_file(file_path)
	return settings


func _init() -> void:
	reset_all(false)
	_stored.clear()
	_dirty = false


# --- Valores ----------------------------------------------------------------------------------

## Valor actual del ajuste [param id] (null si no existe).
func get_value(id: StringName) -> Variant:
	return _values.get(id, null)


## Fija el ajuste [param id] a [param value], normalizado. Devuelve false (sin cambiar nada) si el
## ajuste no existe o el valor no es válido. Marca el ajuste como del jugador ([method is_stored]) y
## emite [signal changed] si el valor cambió.
func set_value(id: StringName, value: Variant) -> bool:
	var spec: Dictionary = get_spec(id)
	if spec.is_empty():
		return false
	var normalized: Variant = normalize(spec, value)
	if normalized == null:
		return false
	var was_stored: bool = _stored.has(id)
	_stored[id] = true
	if not was_stored:
		_dirty = true
	if _values.get(id) != normalized:
		_values[id] = normalized
		_dirty = true
		changed.emit(id, normalized)
	return true


## true si el jugador ha fijado este ajuste (se guarda y se aplica al arrancar).
func is_stored(id: StringName) -> bool:
	return _stored.has(id)


## Vuelve [param id] a su valor por defecto y deja de contarlo como del jugador.
func reset(id: StringName) -> void:
	var spec: Dictionary = get_spec(id)
	if spec.is_empty():
		return
	if _stored.erase(id):
		_dirty = true
	var default: Variant = spec["default"]
	if _values.get(id) != default:
		_values[id] = default
		_dirty = true
		changed.emit(id, default)


## Vuelve a su valor por defecto todos los ajustes (o los de [param emit_changes] a false sin avisar:
## es lo que usa la construcción).
func reset_all(emit_changes: bool = true) -> void:
	for spec: Dictionary in get_schema():
		if emit_changes:
			reset(spec["id"])
		else:
			_values[spec["id"]] = spec["default"]
	if not emit_changes:
		_stored.clear()
	_dirty = true


## Vuelve a su valor por defecto los ajustes de la pestaña [param tab].
func reset_tab(tab: StringName) -> void:
	for spec: Dictionary in get_schema():
		if spec["tab"] == tab:
			reset(spec["id"])


## Todos los valores: id -> valor.
func to_dictionary() -> Dictionary:
	return _values.duplicate()


## true si hay cambios sin guardar.
func is_dirty() -> bool:
	return _dirty


## Valor válido que representa [param value] para [param spec], o null si no vale: un interruptor
## admite un booleano (o 0 y 1); una lista, uno de sus valores (un número entero que llegue como
## decimal se acepta); un rango, un número que se limita al rango y se ajusta al paso.
static func normalize(spec: Dictionary, value: Variant) -> Variant:
	match int(spec["kind"]):
		Kind.BOOL:
			if typeof(value) == TYPE_BOOL:
				return value
			if typeof(value) == TYPE_INT and (int(value) == 0 or int(value) == 1):
				return int(value) == 1
			return null
		Kind.CHOICE:
			for candidate: Variant in spec["values"]:
				if typeof(candidate) == TYPE_STRING:
					if typeof(value) == TYPE_STRING and value == candidate:
						return candidate
				elif (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
						and is_equal_approx(float(value), float(candidate)):
					return candidate
			return null
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return null
	if not is_finite(float(value)):
		return null
	var number: float = clampf(float(value), float(spec["min"]), float(spec["max"]))
	var step: float = float(spec["step"])
	if step > 0.0:
		number = clampf(snappedf(number, step), float(spec["min"]), float(spec["max"]))
		# Sin el ruido de coma flotante de los pasos (0,7 y no 0,7000000000000001), para que el
		# valor por defecto vuelva a ser él mismo al normalizarlo.
		number = ("%.6f" % number).to_float()
	return number


# --- Archivo ----------------------------------------------------------------------------------

## Lee [param file_path]. Lo que falte o no sea válido queda a su valor por defecto. Devuelve el error
## de [method ConfigFile.load] ([constant ERR_FILE_NOT_FOUND] si el archivo no existe).
func load_file(file_path: String = PATH) -> Error:
	reset_all(false)
	_stored.clear()
	var config: ConfigFile = ConfigFile.new()
	var error: Error = config.load(file_path)
	if error == OK:
		for spec: Dictionary in get_schema():
			var section: String = spec["section"]
			var key: String = spec["key"]
			if not config.has_section_key(section, key):
				continue
			var normalized: Variant = normalize(spec, config.get_value(section, key))
			if normalized != null:
				_values[spec["id"]] = normalized
				_stored[spec["id"]] = true
	_dirty = false
	return error


## Guarda en [param file_path] los ajustes del jugador (los demás se quitan del archivo) y conserva el
## resto de lo que hubiera en él. Devuelve el error de [method ConfigFile.save].
func save_file(file_path: String = PATH) -> Error:
	var config: ConfigFile = ConfigFile.new()
	# Si el archivo no existe o está roto se empieza de cero.
	config.load(file_path)
	for spec: Dictionary in get_schema():
		var section: String = spec["section"]
		var key: String = spec["key"]
		if _stored.has(spec["id"]):
			var value: Variant = _values[spec["id"]]
			if typeof(value) == TYPE_FLOAT:
				value = snappedf(float(value), 0.001)
			config.set_value(section, key, value)
		elif config.has_section_key(section, key):
			config.erase_section_key(section, key)
	var error: Error = config.save(file_path)
	if error == OK:
		_dirty = false
	return error


## Guarda en [member path] si hay cambios sin guardar.
func save_if_dirty() -> void:
	if _dirty:
		save_file(path)


# --- Aplicación -------------------------------------------------------------------------------

## Aplica los ajustes al motor y a la escena de [param tree]. Con [param stored_only] solo los del
## jugador (lo que se hace al arrancar).
func apply_all(tree: SceneTree, stored_only: bool = false) -> void:
	for spec: Dictionary in get_schema():
		if stored_only and not _stored.has(spec["id"]):
			continue
		apply_value(spec["id"], tree)


## Aplica el ajuste [param id] con su valor actual.
func apply_value(id: StringName, tree: SceneTree) -> void:
	var value: Variant = _values.get(id)
	if value == null:
		return
	match id:
		WINDOW_MODE:
			_apply_window_mode(int(value))
		RESOLUTION:
			_apply_resolution(String(value))
		VSYNC:
			if not _is_headless():
				DisplayServer.window_set_vsync_mode(vsync_mode_for(int(value)))
		FPS_LIMIT:
			Engine.max_fps = int(value)
		RENDER_SCALE:
			tree.root.scaling_3d_scale = float(value)
		SHADOWS:
			apply_shadows(tree.root, int(value))
		GRASS_DISTANCE:
			apply_grass_distance(tree.root, float(value))
		ANTIALIASING:
			var profile: Dictionary = antialiasing_for(int(value))
			tree.root.msaa_3d = profile["msaa"]
			tree.root.screen_space_aa = profile["screen_space"]
		_:
			var spec: Dictionary = get_spec(id)
			if spec.has("bus"):
				AudioBuses.set_volume(spec["bus"], float(value))
			elif CAMERA_IDS.has(id):
				for node: Node in tree.get_nodes_in_group(CameraRig.GROUP):
					_apply_camera_value(node as CameraRig, id)
			# Los de interfaz los aplican solos los controles enlazados con bind_visibility().


## Aplica los ajustes de cámara a [param rig]. Con [param stored_only] solo los del jugador.
func apply_to_camera(rig: CameraRig, stored_only: bool = false) -> void:
	for id: StringName in CAMERA_IDS:
		if not stored_only or _stored.has(id):
			_apply_camera_value(rig, id)


func _apply_camera_value(rig: CameraRig, id: StringName) -> void:
	match id:
		MOUSE_SENSITIVITY:
			rig.mouse_sensitivity = CameraRig.DEFAULT_MOUSE_SENSITIVITY * float(_values[id])
		INVERT_Y:
			rig.invert_y = bool(_values[id])
		FOV:
			rig.set_fov(float(_values[id]))
		DEFAULT_SHOULDER:
			rig.set_default_shoulder(int(_values[id]))


## Muestra u oculta [param control] según el ajuste de interfaz [param id] ([constant DAMAGE_NUMBERS],
## [constant NAMEPLATES] o [constant HELP_BAR]): ahora, si el jugador lo ha fijado, y cada vez que cambie. Con
## [param apply_default] también ahora aunque el jugador no lo haya fijado (el valor por defecto manda: para lo que
## empieza oculto). Se desenlaza al salir del árbol.
static func bind_visibility(control: Control, id: StringName, apply_default: bool = false) -> void:
	var settings: ClientSettings = current()
	if apply_default or settings.is_stored(id):
		control.visible = bool(settings.get_value(id))
	var handler: Callable = func(changed_id: StringName, value: Variant) -> void:
		if changed_id == id and is_instance_valid(control):
			control.visible = bool(value)
	settings.changed.connect(handler)
	control.tree_exiting.connect(func() -> void:
		if settings.changed.is_connected(handler):
			settings.changed.disconnect(handler))


# --- Conversiones (funciones puras) ------------------------------------------------------------

## [enum DisplayServer.WindowMode] de un valor de [constant WINDOW_MODE].
static func window_mode_for(value: int) -> DisplayServer.WindowMode:
	match value:
		MODE_FULLSCREEN:
			return DisplayServer.WINDOW_MODE_FULLSCREEN
		MODE_EXCLUSIVE:
			return DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	return DisplayServer.WINDOW_MODE_WINDOWED


## [enum DisplayServer.VSyncMode] de un valor de [constant VSYNC] (0 desactivada, 1 activada, 2
## adaptativa).
static func vsync_mode_for(value: int) -> DisplayServer.VSyncMode:
	match value:
		0:
			return DisplayServer.VSYNC_DISABLED
		2:
			return DisplayServer.VSYNC_ADAPTIVE
	return DisplayServer.VSYNC_ENABLED


## Tamaño de una resolución «1600x900» ([constant Vector2i.ZERO] si el texto no vale).
static func parse_resolution(text: String) -> Vector2i:
	var parts: PackedStringArray = text.split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	var size: Vector2i = Vector2i(parts[0].to_int(), parts[1].to_int())
	return size if size.x > 0 and size.y > 0 else Vector2i.ZERO


## Suavizado de un valor de [constant ANTIALIASING]: [code]msaa[/code] ([enum Viewport.MSAA]) y
## [code]screen_space[/code] ([enum Viewport.ScreenSpaceAA]).
static func antialiasing_for(value: int) -> Dictionary:
	match value:
		AA_FXAA:
			return {"msaa": Viewport.MSAA_DISABLED, "screen_space": Viewport.SCREEN_SPACE_AA_FXAA}
		AA_MSAA_2X:
			return {"msaa": Viewport.MSAA_2X, "screen_space": Viewport.SCREEN_SPACE_AA_DISABLED}
		AA_MSAA_4X:
			return {"msaa": Viewport.MSAA_4X, "screen_space": Viewport.SCREEN_SPACE_AA_DISABLED}
	return {"msaa": Viewport.MSAA_DISABLED, "screen_space": Viewport.SCREEN_SPACE_AA_DISABLED}


## Perfil de sombras de un nivel de [constant SHADOWS]: [code]enabled[/code] (false solo el nivel 0),
## [code]atlas[/code] (lado, en píxeles, de los atlas de sombras) y [code]filter[/code]
## ([enum RenderingServer.ShadowQuality]). El nivel alto es lo que usa el proyecto por defecto.
static func shadow_profile_for(level: int) -> Dictionary:
	match level:
		0:
			return {"enabled": false, "atlas": 1024, "filter": RenderingServer.SHADOW_QUALITY_HARD}
		1:
			return {"enabled": true, "atlas": 1024, "filter": RenderingServer.SHADOW_QUALITY_HARD}
		2:
			return {"enabled": true, "atlas": 2048,
					"filter": RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW}
	return {"enabled": true, "atlas": 4096, "filter": RenderingServer.SHADOW_QUALITY_SOFT_LOW}


# --- Aplicación a la escena -------------------------------------------------------------------

## Aplica el nivel de sombras [param level] a los atlas del motor y a las luces bajo [param root].
static func apply_shadows(root: Node, level: int) -> void:
	var profile: Dictionary = shadow_profile_for(level)
	RenderingServer.directional_shadow_atlas_set_size(int(profile["atlas"]), true)
	RenderingServer.directional_soft_shadow_filter_set_quality(profile["filter"])
	RenderingServer.positional_soft_shadow_filter_set_quality(profile["filter"])
	if root is Viewport:
		(root as Viewport).positional_shadow_atlas_size = int(profile["atlas"])
	for node: Node in root.find_children("*", "Light3D", true, false):
		apply_light_shadow(node as Light3D, bool(profile["enabled"]))


## Enciende o apaga las sombras de [param light] respetando si en la escena las tenía: nunca las
## enciende si la escena las tenía apagadas.
static func apply_light_shadow(light: Light3D, enabled: bool) -> void:
	if not light.has_meta(LIGHT_SHADOW_META):
		light.set_meta(LIGHT_SHADOW_META, light.shadow_enabled)
	light.shadow_enabled = bool(light.get_meta(LIGHT_SHADOW_META)) and enabled


## Aplica la distancia de la hierba [param distance] (m; 0 la quita) a los [code]Terrain3D[/code]
## bajo [param root]. Devuelve cuántos recursos de hierba tocó.
static func apply_grass_distance(root: Node, distance: float) -> int:
	var touched: int = 0
	for node: Node in root.find_children("*", "Terrain3D", true, false):
		touched += apply_grass_to_assets(node.get("assets") as Object, distance)
	return touched


## Aplica [param distance] a los recursos de hierba de [param assets] (un
## [code]Terrain3DAssets[/code]): su último nivel de LOD pasa a esa distancia (la distancia a la que se
## dejan de ver) o, con 0, se desactivan. Guarda los valores originales para poder restaurarlos.
## Devuelve cuántos tocó.
static func apply_grass_to_assets(assets: Object, distance: float) -> int:
	if assets == null or not assets.has_method("get_mesh_count"):
		return 0
	var touched: int = 0
	for index: int in int(assets.call("get_mesh_count")):
		var asset: Object = assets.call("get_mesh_asset", index) as Object
		if asset == null or not _is_grass(String(asset.get("name"))):
			continue
		var range_property: String = "lod%d_range" % int(asset.get("last_lod"))
		if not asset.has_meta(GRASS_META):
			asset.set_meta(GRASS_META, {"enabled": asset.get("enabled"),
					"range": asset.get(range_property), "property": range_property})
		var original: Dictionary = asset.get_meta(GRASS_META)
		if distance <= 0.0:
			asset.set("enabled", false)
		else:
			asset.set("enabled", original["enabled"])
			asset.set(String(original["property"]), distance)
		touched += 1
	return touched


static func _is_grass(asset_name: String) -> bool:
	for prefix: String in GRASS_ASSET_PREFIXES:
		if asset_name.begins_with(prefix):
			return true
	return false


static func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


static func _apply_window_mode(value: int) -> void:
	if _is_headless():
		return
	if value == MODE_WINDOWED:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	DisplayServer.window_set_mode(window_mode_for(value))


static func _apply_resolution(text: String) -> void:
	if _is_headless():
		return
	var size: Vector2i = parse_resolution(text)
	if size == Vector2i.ZERO or DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	DisplayServer.window_set_size(size)
	var screen: int = DisplayServer.window_get_current_screen()
	var origin: Vector2i = DisplayServer.screen_get_position(screen)
	var free_space: Vector2i = DisplayServer.screen_get_size(screen) - size
	DisplayServer.window_set_position(origin + free_space / 2)
