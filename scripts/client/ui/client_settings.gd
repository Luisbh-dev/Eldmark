class_name ClientSettings
extends RefCounted
## Player settings (UI-16): graphics, per-bus audio, camera and interface, stored in
## [code]user://settings.cfg[/code], applied live and at startup.
## [br][br]
## [b]Data.[/b] Each setting has a definition in [method get_schema]: identifier, tab, section and file
## key, English text ([code]msgid[/code]), default value and its type ([enum Kind]): a toggle, a list of
## allowed values or a range with a step. [method set_value] validates and normalizes (clamps to range,
## snaps to the step, rejects what is not in the list) and emits [signal changed] only if the value changes.
## [SettingsMenu] is built by reading this table.
## [br][br]
## [b]Text.[/b] The table stores [code]msgid[/code]s with their context and parameters, never formatted
## text, so the settings window follows a language change: [method label_text], [method item_text],
## [method tab_title] and [method format_value] translate through [L10n] when they are asked for.
## [br][br]
## [b]File.[/b] [method save] writes only the settings the player has touched ([method is_stored]) and
## preserves any other sections in the file; [method load] reads whatever is there and leaves the default
## value for whatever is missing or wrong (a hand-edited file with garbage breaks nothing). The volumes
## use the same keys as [AudioBuses].
## [br][br]
## [b]Application.[/b] [method apply_value] applies one setting to the engine and the scene and
## [method apply_all] applies them all; with [param stored_only] only those the player has saved, which is
## what happens at startup so that a client with no saved settings starts exactly as it always has (the
## project's window, vsync or antialiasing are not overridden with default values). Graphics: window mode,
## resolution, vsync, FPS limit, render scale, shadow quality (it also turns off shadow-casting lights if
## disabled), grass distance (the last LOD level of the grass [code]Terrain3DMeshAsset[/code]s) and
## antialiasing. Audio: [AudioBuses]. Camera: sensitivity, invert Y, field of view and default shoulder on
## every [CameraRig] (group [constant CameraRig.GROUP]). Interface: controls bound with
## [method bind_visibility] ([DamageNumbers], [Nameplates], the [HUD]'s help line) show or hide
## themselves and the hints ([HintToasts]) read [constant HINTS] when shown. The language ([constant
## LANGUAGE]) goes to [L10n]. It is not restorable: restoring a tab or everything leaves it alone, because
## a player who restores the defaults into a language they cannot read may not find the way back.
## [br][br]
## Window mode, resolution and vsync are not touched in headless mode (there is no window): their
## conversion tables ([method window_mode_for], [method vsync_mode_for], [method parse_resolution]) are
## pure functions exercised by the tests.
## [br][br]
## Client only.

## A setting changed value (also on restore). [param value] is already normalized.
signal changed(id: StringName, value: Variant)

## Setting types.
enum Kind { BOOL, CHOICE, RANGE }

const PATH: String = "user://settings.cfg"

# Tabs.
const TAB_GRAPHICS: StringName = &"graphics"
const TAB_AUDIO: StringName = &"audio"
const TAB_CAMERA: StringName = &"camera"
const TAB_INTERFACE: StringName = &"interface"
## Tabs in order.
const TABS: Array[StringName] = [TAB_GRAPHICS, TAB_AUDIO, TAB_CAMERA, TAB_INTERFACE]
## English title of each tab: a [code]msgid[/code] with the context [constant TAB_CONTEXT].
const TAB_NAMES: Dictionary = {  # l10n ctx=settings_tab
	TAB_GRAPHICS: "Graphics", TAB_AUDIO: "Audio", TAB_CAMERA: "Camera", TAB_INTERFACE: "Interface",
}
const TAB_CONTEXT: StringName = &"settings_tab"
## Values of [constant LANGUAGE]: follow the system (Spanish until UI-39), English or Spanish.
const LANGUAGE_AUTO: String = "auto"
const LANGUAGE_VALUES: Array[String] = [LANGUAGE_AUTO, "en", "es"]

# Setting identifiers (the file key is the same, except for the volumes).
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
## Interface language: [code]auto[/code], [code]en[/code] or [code]es[/code] ([L10n]). Not restorable.
const LANGUAGE: StringName = &"language"
const DAMAGE_NUMBERS: StringName = &"damage_numbers"
const NAMEPLATES: StringName = &"nameplates"
## Game hints (UI-42): tips that appear only once per player ([HintToasts]).
const HINTS: StringName = &"hints"
## Help line with the keys, at the bottom center of the HUD (UI-49): hidden by default, F1 shows and hides it.
const HELP_BAR: StringName = &"help_bar"
## Camera settings, graphics settings that walk the scene, and interface settings.
const CAMERA_IDS: Array[StringName] = [MOUSE_SENSITIVITY, INVERT_Y, FOV, DEFAULT_SHOULDER]
const INTERFACE_IDS: Array[StringName] = [LANGUAGE, DAMAGE_NUMBERS, NAMEPLATES, HINTS, HELP_BAR]

## Window resolutions on offer (text "width x height" without spaces).
const RESOLUTIONS: Array[String] = ["1280x720", "1600x900", "1920x1080", "2560x1440"]
## FPS limits on offer (0 = no limit).
const FPS_LIMITS: Array[int] = [0, 30, 60, 90, 120, 144, 165, 240]
## Values of [constant WINDOW_MODE]: windowed, borderless fullscreen and exclusive fullscreen.
const MODE_WINDOWED: int = 0
const MODE_FULLSCREEN: int = 1
const MODE_EXCLUSIVE: int = 2
## Levels of [constant SHADOWS]: off, low, medium and high.
const SHADOWS_OFF: int = 0
const SHADOWS_HIGH: int = 3
## Values of [constant ANTIALIASING]: none, FXAA, MSAA 2x and MSAA 4x (the project's).
const AA_NONE: int = 0
const AA_FXAA: int = 1
const AA_MSAA_2X: int = 2
const AA_MSAA_4X: int = 3
## Metadata of a light with its original [member Light3D.shadow_enabled].
const LIGHT_SHADOW_META: StringName = &"client_settings_shadow_default"
const SUN_SPLITS_META: StringName = &"client_settings_sun_splits_default"
## Metadata of a grass resource with its original values.
const GRASS_META: StringName = &"client_settings_grass_default"
## A [code]Terrain3DMeshAsset[/code] is grass if its name starts like this.
const GRASS_ASSET_PREFIXES: Array[String] = ["Hierba", "Grass"]

## Where [method current] loads the settings from. The test runner points it to a temporary file so that no
## test reads or writes the developer's real settings.
static var default_path: String = PATH

static var _schema: Array[Dictionary] = []
static var _current: ClientSettings = null

## File where it is saved ([method save_if_dirty]); the one from [method load_from].
var path: String = PATH

var _values: Dictionary = {}
var _stored: Dictionary = {}
var _dirty: bool = false


# --- The settings table -----------------------------------------------------------------------

## Definition of all the settings, in the order the settings menu shows them. Each dictionary:
## [code]id[/code], [code]tab[/code], [code]section[/code], [code]key[/code] (file),
## [code]label[/code] (the [code]msgid[/code]; [code]label_ctx[/code] is its context), [code]kind[/code] ([enum Kind]), [code]default[/code] and, depending on
## the type, [code]values[/code] and [code]labels[/code] (list; [code]item_ctx[/code] and
## [code]item_params[/code] are the context and the parameters of the items, and [code]raw_items[/code] the
## indexes of items shown as they are) or [code]min[/code],
## [code]max[/code], [code]step[/code] and [code]format[/code] ([code]percent[/code], [code]multiplier[/code],
## [code]degrees[/code] or [code]meters[/code]). A setting with [code]restorable[/code] false is left alone by
## "restore tab" and "restore all".
static func get_schema() -> Array[Dictionary]:
	if _schema.is_empty():
		_schema = _build_schema()
	return _schema


## Identifiers of all the settings, in order.
static func get_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for spec: Dictionary in get_schema():
		ids.append(spec["id"])
	return ids


## Definition of setting [param id] (empty if it does not exist).
static func get_spec(id: StringName) -> Dictionary:
	for spec: Dictionary in get_schema():
		if spec["id"] == id:
			return spec
	return {}


## Identifier of the volume of bus [param bus] ([code]volume_sfx[/code]...).
static func volume_id(bus: StringName) -> StringName:
	return StringName(AudioBuses.volume_key(bus))


## Default value of setting [param id] (null if it does not exist).
static func get_default(id: StringName) -> Variant:
	return get_spec(id).get("default", null)


## Title of tab [param tab], translated.
static func tab_title(tab: StringName) -> String:
	return L10n.t(String(TAB_NAMES[tab]), TAB_CONTEXT)


## Text of the label of [param spec] (the setting's name), translated.
static func label_text(spec: Dictionary) -> String:
	return L10n.t(String(spec["label"]), StringName(spec.get("label_ctx", &"")))


## Text of item [param index] of a list setting, translated and with its parameters filled in.
static func item_text(spec: Dictionary, index: int) -> String:
	var msgid: String = String((spec["labels"] as Array)[index])
	if (spec.get("raw_items", []) as Array).has(index):
		return msgid
	var ctx: StringName = StringName(spec.get("item_ctx", &""))
	var params_list: Array = spec.get("item_params", [])
	if index < params_list.size() and not (params_list[index] as Dictionary).is_empty():
		return L10n.tf(msgid, params_list[index], ctx)
	return L10n.t(msgid, ctx)


## Whether "restore tab" and "restore all" return setting [param id] to its default value.
static func is_restorable(id: StringName) -> bool:
	return bool(get_spec(id).get("restorable", true))


## Text of [param value] to show next to the control of [param id] ("75%", "x1.25", "90°", "60 m", "Off",
## "Yes"...), in the language in use. For lists, the value's label.
static func format_value(id: StringName, value: Variant) -> String:
	var spec: Dictionary = get_spec(id)
	if spec.is_empty():
		return str(value)
	match int(spec["kind"]):
		Kind.BOOL:
			return L10n.t("Yes" if bool(value) else "No", &"answer")
		Kind.CHOICE:
			var index: int = (spec["values"] as Array).find(value)
			return item_text(spec, index) if index >= 0 else str(value)
	var number: float = float(value)
	match String(spec.get("format", "")):
		"percent":
			return L10n.format_percent(number)
		"multiplier":
			return L10n.format_multiplier(number)
		"degrees":
			return L10n.format_unit("{value}°", str(roundi(number)))
		"meters":
			if number <= 0.0:
				return L10n.t("Off", &"grass_distance")
			return L10n.format_unit("{value} m", str(roundi(number)))
	return str(number)


static func _build_schema() -> Array[Dictionary]:
	var schema: Array[Dictionary] = []
	schema.append(_choice(TAB_GRAPHICS, WINDOW_MODE, L10n.mark("Window mode"), MODE_WINDOWED,
			[MODE_WINDOWED, MODE_FULLSCREEN, MODE_EXCLUSIVE],
			[L10n.mark("Windowed"), L10n.mark("Borderless fullscreen"),
					L10n.mark("Exclusive fullscreen")]))
	var resolution_labels: Array = []
	var resolution_params: Array = []
	for text: String in RESOLUTIONS:
		var parts: PackedStringArray = text.split("x")
		resolution_labels.append(L10n.mark("{width} x {height}", &"resolution"))
		resolution_params.append({"width": parts[0], "height": parts[1]})
	var resolution: Dictionary = _choice(TAB_GRAPHICS, RESOLUTION, L10n.mark("Window resolution"),
			"1600x900", RESOLUTIONS, resolution_labels)
	resolution["item_ctx"] = &"resolution"
	resolution["item_params"] = resolution_params
	schema.append(resolution)
	var vsync: Dictionary = _choice(TAB_GRAPHICS, VSYNC, L10n.mark("Vertical sync"), 1, [0, 1, 2],
			[L10n.mark("Off", &"vsync"), L10n.mark("On", &"vsync"), L10n.mark("Adaptive", &"vsync")])
	vsync["item_ctx"] = &"vsync"
	schema.append(vsync)
	var fps_labels: Array = []
	var fps_params: Array = []
	for limit: int in FPS_LIMITS:
		fps_labels.append(L10n.mark("No limit", &"fps_limit") if limit == 0
				else L10n.mark("{fps} FPS", &"fps_limit"))
		fps_params.append({} if limit == 0 else {"fps": limit})
	var fps: Dictionary = _choice(TAB_GRAPHICS, FPS_LIMIT, L10n.mark("FPS limit"), 0, FPS_LIMITS,
			fps_labels)
	fps["item_ctx"] = &"fps_limit"
	fps["item_params"] = fps_params
	schema.append(fps)
	schema.append(_range(TAB_GRAPHICS, RENDER_SCALE, L10n.mark("Render scale"), 1.0, 0.5, 1.0, 0.05,
			"percent"))
	var shadows: Dictionary = _choice(TAB_GRAPHICS, SHADOWS, L10n.mark("Shadows"), SHADOWS_HIGH,
			[0, 1, 2, 3], [L10n.mark("Off", &"shadows"), L10n.mark("Low", &"shadows"),
					L10n.mark("Medium", &"shadows"), L10n.mark("High", &"shadows")])
	shadows["item_ctx"] = &"shadows"
	schema.append(shadows)
	schema.append(_range(TAB_GRAPHICS, GRASS_DISTANCE, L10n.mark("Grass distance"), 60.0, 0.0, 120.0,
			10.0, "meters"))
	var antialiasing: Dictionary = _choice(TAB_GRAPHICS, ANTIALIASING, L10n.mark("Antialiasing"),
			AA_MSAA_4X, [AA_NONE, AA_FXAA, AA_MSAA_2X, AA_MSAA_4X],
			[L10n.mark("None", &"antialiasing"), L10n.mark("FXAA", &"antialiasing"),
					L10n.mark("MSAA 2x", &"antialiasing"), L10n.mark("MSAA 4x", &"antialiasing")])
	antialiasing["item_ctx"] = &"antialiasing"
	schema.append(antialiasing)
	for bus: StringName in AudioBuses.ALL:
		var spec: Dictionary = _range(TAB_AUDIO, volume_id(bus), AudioBuses.volume_label(bus),
				AudioBuses.default_volume(bus), 0.0, 1.0, 0.05, "percent")
		spec["section"] = String(AudioBuses.SETTINGS_SECTION)
		spec["bus"] = bus
		schema.append(spec)
	schema.append(_range(TAB_CAMERA, MOUSE_SENSITIVITY, L10n.mark("Mouse sensitivity"), 1.0, 0.2, 3.0,
			0.05, "multiplier"))
	schema.append(_bool(TAB_CAMERA, INVERT_Y, L10n.mark("Invert vertical axis"), false))
	schema.append(_range(TAB_CAMERA, FOV, L10n.mark("Field of view"), 72.0, 60.0, 100.0, 1.0, "degrees"))
	var shoulder: Dictionary = _choice(TAB_CAMERA, DEFAULT_SHOULDER, L10n.mark("Default shoulder"), 1,
			[1, -1], [L10n.mark("Right", &"shoulder"), L10n.mark("Left", &"shoulder")])
	shoulder["item_ctx"] = &"shoulder"
	schema.append(shoulder)
	# The language options: "Español" and "English" are endonyms; the notes in the other two say what
	# "Automatic" means and that the English text is still incomplete, until the final review (UI-39).
	var language: Dictionary = _choice(TAB_INTERFACE, LANGUAGE, L10n.mark("Language"), LANGUAGE_AUTO,
			LANGUAGE_VALUES, [L10n.mark("Automatic (Spanish)", &"language"),
					L10n.mark("English (incomplete)", &"language"), "Español"])
	language["item_ctx"] = &"language"
	language["raw_items"] = [2]  # l10n-ignore: endonym, shown as it is in every language
	language["restorable"] = false
	schema.append(language)
	schema.append(_bool(TAB_INTERFACE, DAMAGE_NUMBERS, L10n.mark("Damage numbers"), true))
	schema.append(_bool(TAB_INTERFACE, NAMEPLATES, L10n.mark("Nameplates"), true))
	schema.append(_bool(TAB_INTERFACE, HINTS, L10n.mark("Game hints"), true))
	schema.append(_bool(TAB_INTERFACE, HELP_BAR, L10n.mark("Controls help line (F1)"), false))
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


# --- The setting in use ------------------------------------------------------------------------

## The client's settings: loaded from [member default_path] the first time they are requested.
static func current() -> ClientSettings:
	if _current == null:
		_current = load_from(default_path)
	return _current


## Replaces the settings in use (null forgets them and they are reloaded from [member default_path] when
## requested).
static func set_current(settings: ClientSettings) -> void:
	_current = settings


## Settings loaded from [param file_path] (default values if it does not exist or is malformed).
static func load_from(file_path: String) -> ClientSettings:
	var settings: ClientSettings = ClientSettings.new()
	settings.path = file_path
	settings.load_file(file_path)
	return settings


func _init() -> void:
	reset_all(false)
	_stored.clear()
	_dirty = false


# --- Values -----------------------------------------------------------------------------------

## Current value of setting [param id] (null if it does not exist).
func get_value(id: StringName) -> Variant:
	return _values.get(id, null)


## Sets setting [param id] to [param value], normalized. Returns false (changing nothing) if the setting
## does not exist or the value is not valid. Marks the setting as the player's ([method is_stored]) and
## emits [signal changed] if the value changed.
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


## true if the player has set this setting (it is saved and applied at startup).
func is_stored(id: StringName) -> bool:
	return _stored.has(id)


## Returns [param id] to its default value and stops counting it as the player's.
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


## Returns all the settings to their default value (or, with [param emit_changes] false, without
## notifying: this is what construction uses).
func reset_all(emit_changes: bool = true) -> void:
	for spec: Dictionary in get_schema():
		if emit_changes:
			if bool(spec.get("restorable", true)):
				reset(spec["id"])
		else:
			_values[spec["id"]] = spec["default"]
	if not emit_changes:
		_stored.clear()
	_dirty = true


## Returns the settings of tab [param tab] to their default value.
func reset_tab(tab: StringName) -> void:
	for spec: Dictionary in get_schema():
		if spec["tab"] == tab and bool(spec.get("restorable", true)):
			reset(spec["id"])


## All the values: id -> value.
func to_dictionary() -> Dictionary:
	return _values.duplicate()


## true if there are unsaved changes.
func is_dirty() -> bool:
	return _dirty


## Valid value that [param value] represents for [param spec], or null if it is not valid: a toggle
## accepts a boolean (or 0 and 1); a list, one of its values (an integer number that arrives as a float
## is accepted); a range, a number that is clamped to the range and snapped to the step.
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
		# Without the floating-point noise of the steps (0.7 and not 0.7000000000000001), so that the default
		# value is itself again when normalized.
		number = ("%.6f" % number).to_float()
	return number


# --- File -------------------------------------------------------------------------------------

## Reads [param file_path]. Whatever is missing or invalid stays at its default value. Returns the error
## of [method ConfigFile.load] ([constant ERR_FILE_NOT_FOUND] if the file does not exist).
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


## Saves the player's settings to [param file_path] (the others are removed from the file) and preserves
## the rest of what was in it. Returns the error of [method ConfigFile.save].
func save_file(file_path: String = PATH) -> Error:
	var config: ConfigFile = ConfigFile.new()
	# If the file does not exist or is broken, start from scratch.
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


## Saves to [member path] if there are unsaved changes.
func save_if_dirty() -> void:
	if _dirty:
		save_file(path)


# --- Application ------------------------------------------------------------------------------

## Applies the settings to the engine and to the scene of [param tree]. With [param stored_only] only the
## player's (what happens at startup).
func apply_all(tree: SceneTree, stored_only: bool = false) -> void:
	for spec: Dictionary in get_schema():
		if stored_only and not _stored.has(spec["id"]):
			continue
		apply_value(spec["id"], tree)


## Applies setting [param id] with its current value.
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
		LANGUAGE:
			# Deferred to the end of the frame: the usual caller is the language selector itself.
			L10n.set_language(String(value))
		_:
			var spec: Dictionary = get_spec(id)
			if spec.has("bus"):
				AudioBuses.set_volume(spec["bus"], float(value))
			elif CAMERA_IDS.has(id):
				for node: Node in tree.get_nodes_in_group(CameraRig.GROUP):
					_apply_camera_value(node as CameraRig, id)
			# The interface ones are applied by the controls bound with bind_visibility().


## Applies the camera settings to [param rig]. With [param stored_only] only the player's.
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


## Shows or hides [param control] according to the interface setting [param id]
## ([constant DAMAGE_NUMBERS], [constant NAMEPLATES] or [constant HELP_BAR]): now, if the player has set
## it, and every time it changes. With [param apply_default] also now even if the player has not set it
## (the default value rules: for what starts hidden). It unbinds when leaving the tree.
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


# --- Conversions (pure functions) --------------------------------------------------------------

## [enum DisplayServer.WindowMode] for a [constant WINDOW_MODE] value.
static func window_mode_for(value: int) -> DisplayServer.WindowMode:
	match value:
		MODE_FULLSCREEN:
			return DisplayServer.WINDOW_MODE_FULLSCREEN
		MODE_EXCLUSIVE:
			return DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	return DisplayServer.WINDOW_MODE_WINDOWED


## [enum DisplayServer.VSyncMode] for a [constant VSYNC] value (0 disabled, 1 enabled, 2 adaptive).
static func vsync_mode_for(value: int) -> DisplayServer.VSyncMode:
	match value:
		0:
			return DisplayServer.VSYNC_DISABLED
		2:
			return DisplayServer.VSYNC_ADAPTIVE
	return DisplayServer.VSYNC_ENABLED


## Size of a resolution "1600x900" ([constant Vector2i.ZERO] if the text is not valid).
static func parse_resolution(text: String) -> Vector2i:
	var parts: PackedStringArray = text.split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	var size: Vector2i = Vector2i(parts[0].to_int(), parts[1].to_int())
	return size if size.x > 0 and size.y > 0 else Vector2i.ZERO


## Antialiasing for an [constant ANTIALIASING] value: [code]msaa[/code] ([enum Viewport.MSAA]) and
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


## Shadow profile for a [constant SHADOWS] level: [code]enabled[/code] (false only for level 0),
## [code]atlas[/code] (side, in pixels, of the shadow atlases) and [code]filter[/code]
## ([enum RenderingServer.ShadowQuality]). The high level is what the project uses by default.
static func shadow_profile_for(level: int) -> Dictionary:
	match level:
		0:
			return {"enabled": false, "atlas": 1024, "filter": RenderingServer.SHADOW_QUALITY_HARD, "splits": 2}
		1:
			return {"enabled": true, "atlas": 1024, "filter": RenderingServer.SHADOW_QUALITY_HARD, "splits": 2}
		2:
			return {"enabled": true, "atlas": 2048,
					"filter": RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW, "splits": 2}
	return {"enabled": true, "atlas": 4096, "filter": RenderingServer.SHADOW_QUALITY_SOFT_LOW, "splits": 4}


# --- Application to the scene -----------------------------------------------------------------

## Applies shadow level [param level] to the engine's atlases and to the lights under [param root].
static func apply_shadows(root: Node, level: int) -> void:
	var profile: Dictionary = shadow_profile_for(level)
	RenderingServer.directional_shadow_atlas_set_size(int(profile["atlas"]), true)
	RenderingServer.directional_soft_shadow_filter_set_quality(profile["filter"])
	RenderingServer.positional_soft_shadow_filter_set_quality(profile["filter"])
	if root is Viewport:
		(root as Viewport).positional_shadow_atlas_size = int(profile["atlas"])
	for node: Node in root.find_children("*", "Light3D", true, false):
		apply_light_shadow(node as Light3D, bool(profile["enabled"]))
		if node is DirectionalLight3D:
			apply_sun_splits(node as DirectionalLight3D, int(profile["splits"]))


## Sun shadow splits: the low and medium levels use 2 splits and 120 m at most (fewer draw calls); the
## high one, whatever the scene has. Stores the scene's original value so it can be restored.
static func apply_sun_splits(sun: DirectionalLight3D, splits: int) -> void:
	if not sun.has_meta(SUN_SPLITS_META):
		sun.set_meta(SUN_SPLITS_META, [sun.directional_shadow_mode, sun.directional_shadow_max_distance])
	var original: Array = sun.get_meta(SUN_SPLITS_META)
	if splits >= 4:
		sun.directional_shadow_mode = int(original[0]) as DirectionalLight3D.ShadowMode
		sun.directional_shadow_max_distance = float(original[1])
	else:
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		sun.directional_shadow_max_distance = minf(float(original[1]), 120.0)


## Turns the shadows of [param light] on or off, respecting whether the scene had them: it never turns
## them on if the scene had them off.
static func apply_light_shadow(light: Light3D, enabled: bool) -> void:
	if not light.has_meta(LIGHT_SHADOW_META):
		light.set_meta(LIGHT_SHADOW_META, light.shadow_enabled)
	light.shadow_enabled = bool(light.get_meta(LIGHT_SHADOW_META)) and enabled


## Applies the grass distance [param distance] (m; 0 removes it) to the [code]Terrain3D[/code] nodes
## under [param root]. Returns how many grass resources it touched.
static func apply_grass_distance(root: Node, distance: float) -> int:
	var touched: int = 0
	for node: Node in root.find_children("*", "Terrain3D", true, false):
		touched += apply_grass_to_assets(node.get("assets") as Object, distance)
	return touched


## Applies [param distance] to the grass resources of [param assets] (a [code]Terrain3DAssets[/code]):
## their last LOD level is set to that distance (the distance at which they stop being seen) or, with 0,
## they are disabled. Stores the original values so they can be restored. Returns how many it touched.
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
