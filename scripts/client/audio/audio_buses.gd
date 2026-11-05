class_name AudioBuses
extends RefCounted
## Client audio buses and their saved volumes (ART-10).
## [br][br]
## The layout is in [code]default_bus_layout.tres[/code] (the project root, which Godot loads on
## its own): [code]Master[/code] (with a limiter that prevents saturating the output) and, sending
## to it, [code]Music[/code], [code]SFX[/code], [code]Ambience[/code], [code]UI[/code] and
## [code]Voices[/code]. Identifiers are in English; [method volume_label] gives the English text of the
## volume setting of each bus, which the settings window translates when it shows it.
## [br][br]
## Volumes are linear (0 to 1, like a slider) and are converted to decibels when applied; at 0 the
## bus is fully muted. They are saved in the [code][audio][/code] section of
## [code]user://settings.cfg[/code] (the same one the UI-16 settings write), one
## [code]volume_<bus>[/code] key per bus. [method save_volumes] keeps the file's other sections.
## [br][br]
## Client only: the dedicated server loads nothing from [code]scripts/client/[/code] (nor, therefore,
## from [code]scripts/client/audio/[/code]); this is checked by [code]tests/test_architecture.gd[/code]
## with a process started with [code]--server[/code].

const MASTER: StringName = &"Master"
const MUSIC: StringName = &"Music"
const SFX: StringName = &"SFX"
const AMBIENCE: StringName = &"Ambience"
const UI: StringName = &"UI"
const VOICES: StringName = &"Voices"

## All the buses, in the bus layout's order.
const ALL: Array[StringName] = [MASTER, MUSIC, SFX, AMBIENCE, UI, VOICES]

## English text ([code]msgid[/code]) of the volume setting of each bus. They are whole labels, not a name
## to glue after "Volume: ", because the word order is not the same in every language.
const VOLUME_LABELS: Dictionary = {
	MASTER: "Master volume", MUSIC: "Music volume", SFX: "Effects volume",
	AMBIENCE: "Ambience volume", UI: "Interface volume", VOICES: "Voices volume",
}
## Default linear volume of each bus.
const DEFAULT_VOLUMES: Dictionary = {
	MASTER: 1.0, MUSIC: 0.7, SFX: 1.0, AMBIENCE: 0.8, UI: 0.8, VOICES: 1.0,
}

## File and section where the volumes are saved.
const SETTINGS_PATH: String = "user://settings.cfg"
const SETTINGS_SECTION: String = "audio"
## Linear volume below which the bus is muted.
const MUTE_THRESHOLD: float = 0.0001


## English text of the volume setting of [param bus] ("Effects volume"...), to translate with [L10n] when it
## is shown; the identifier itself if the bus is not known.
static func volume_label(bus: StringName) -> String:
	return L10n.mark(String(VOLUME_LABELS.get(bus, String(bus))))


## Key of the volume of [param bus] in the settings file ([code]volume_sfx[/code]...).
static func volume_key(bus: StringName) -> String:
	return "volume_%s" % String(bus).to_lower()


## true if the bus exists in the [AudioServer] (without the bus layout loaded, it does not).
static func has_bus(bus: StringName) -> bool:
	return AudioServer.get_bus_index(bus) >= 0


## Linear volume (0 to 1) of the bus; 0 if it is muted or does not exist.
static func get_volume(bus: StringName) -> float:
	var index: int = AudioServer.get_bus_index(bus)
	if index < 0 or AudioServer.is_bus_mute(index):
		return 0.0
	return db_to_linear(AudioServer.get_bus_volume_db(index))


## Applies the linear volume [param linear] (clamped to 0..1) to the bus. With a nearly zero value
## the bus is muted and left at -80 dB. It does nothing if the bus does not exist.
static func set_volume(bus: StringName, linear: float) -> void:
	var index: int = AudioServer.get_bus_index(bus)
	if index < 0:
		return
	var value: float = clampf(linear, 0.0, 1.0)
	if value < MUTE_THRESHOLD:
		AudioServer.set_bus_mute(index, true)
		AudioServer.set_bus_volume_db(index, -80.0)
	else:
		AudioServer.set_bus_mute(index, false)
		AudioServer.set_bus_volume_db(index, linear_to_db(value))


## Default linear volume of [param bus] (1 if it is not known).
static func default_volume(bus: StringName) -> float:
	return float(DEFAULT_VOLUMES.get(bus, 1.0))


## Returns all the buses to their default volume (without saving).
static func reset_volumes() -> void:
	for bus: StringName in ALL:
		set_volume(bus, default_volume(bus))


## Current linear volumes of all the buses: bus -> float.
static func get_volumes() -> Dictionary:
	var volumes: Dictionary = {}
	for bus: StringName in ALL:
		volumes[bus] = get_volume(bus)
	return volumes


## Reads the volumes from [param path] and applies them. Buses with no key in the file (or if the
## file does not exist or is malformed) stay at their default value. Returns the applied volumes.
static func load_volumes(path: String = SETTINGS_PATH) -> Dictionary:
	var config: ConfigFile = ConfigFile.new()
	var error: Error = config.load(path)
	for bus: StringName in ALL:
		var volume: float = default_volume(bus)
		if error == OK:
			var stored: Variant = config.get_value(SETTINGS_SECTION, volume_key(bus), volume)
			if typeof(stored) == TYPE_FLOAT or typeof(stored) == TYPE_INT:
				volume = clampf(float(stored), 0.0, 1.0)
		set_volume(bus, volume)
	return get_volumes()


## Saves the current volumes to [param path], keeping whatever else was in the file.
## Returns the error from [method ConfigFile.save] ([constant OK] if it went well).
static func save_volumes(path: String = SETTINGS_PATH) -> Error:
	var config: ConfigFile = ConfigFile.new()
	# If the file does not exist or is broken, it starts from scratch; a broken file is overwritten.
	config.load(path)
	for bus: StringName in ALL:
		config.set_value(SETTINGS_SECTION, volume_key(bus), snappedf(get_volume(bus), 0.001))
	return config.save(path)
