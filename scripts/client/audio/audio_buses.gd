class_name AudioBuses
extends RefCounted
## Buses de audio del cliente y sus volúmenes guardados (ART-10).
## [br][br]
## La disposición está en [code]default_bus_layout.tres[/code] (la raíz del proyecto, que Godot
## carga solo): [code]Master[/code] (con un limitador que evita saturar la salida) y, enviando a él,
## [code]Music[/code], [code]SFX[/code], [code]Ambience[/code], [code]UI[/code] y [code]Voices[/code].
## Los identificadores son en inglés; [method display_name] da el nombre en español que ven los
## ajustes.
## [br][br]
## Los volúmenes son lineales (0 a 1, como un deslizador) y se convierten a decibelios al aplicarlos;
## con 0 el bus se silencia del todo. Se guardan en la sección [code][audio][/code] de
## [code]user://settings.cfg[/code] (la misma que escriben los ajustes de UI-16), una clave
## [code]volume_<bus>[/code] por bus. [method save_volumes] conserva el resto de secciones del
## archivo.
## [br][br]
## Solo cliente: el servidor dedicado no carga nada de [code]scripts/client/[/code] (ni, por tanto,
## de [code]scripts/client/audio/[/code]); lo comprueba [code]tests/test_architecture.gd[/code] con un
## proceso arrancado con [code]--server[/code].

const MASTER: StringName = &"Master"
const MUSIC: StringName = &"Music"
const SFX: StringName = &"SFX"
const AMBIENCE: StringName = &"Ambience"
const UI: StringName = &"UI"
const VOICES: StringName = &"Voices"

## Todos los buses, en el orden del diseño de buses.
const ALL: Array[StringName] = [MASTER, MUSIC, SFX, AMBIENCE, UI, VOICES]

## Nombre en español de cada bus (para los ajustes).
const DISPLAY_NAMES: Dictionary = {
	MASTER: "General", MUSIC: "Música", SFX: "Efectos", AMBIENCE: "Ambiente",
	UI: "Interfaz", VOICES: "Voces",
}
## Volumen lineal por defecto de cada bus.
const DEFAULT_VOLUMES: Dictionary = {
	MASTER: 1.0, MUSIC: 0.7, SFX: 1.0, AMBIENCE: 0.8, UI: 0.8, VOICES: 1.0,
}

## Archivo y sección donde se guardan los volúmenes.
const SETTINGS_PATH: String = "user://settings.cfg"
const SETTINGS_SECTION: String = "audio"
## Volumen lineal por debajo del cual el bus se silencia.
const MUTE_THRESHOLD: float = 0.0001


## Nombre en español de [param bus] («Efectos»...); el propio identificador si no se conoce.
static func display_name(bus: StringName) -> String:
	return DISPLAY_NAMES.get(bus, String(bus))


## Clave del volumen de [param bus] en el archivo de ajustes ([code]volume_sfx[/code]...).
static func volume_key(bus: StringName) -> String:
	return "volume_%s" % String(bus).to_lower()


## true si el bus existe en el [AudioServer] (sin el diseño de buses cargado, no).
static func has_bus(bus: StringName) -> bool:
	return AudioServer.get_bus_index(bus) >= 0


## Volumen lineal (0 a 1) del bus; 0 si está silenciado o no existe.
static func get_volume(bus: StringName) -> float:
	var index: int = AudioServer.get_bus_index(bus)
	if index < 0 or AudioServer.is_bus_mute(index):
		return 0.0
	return db_to_linear(AudioServer.get_bus_volume_db(index))


## Aplica el volumen lineal [param linear] (se limita a 0..1) al bus. Con un valor casi nulo el
## bus se silencia y se deja a -80 dB. No hace nada si el bus no existe.
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


## Volumen lineal por defecto de [param bus] (1 si no se conoce).
static func default_volume(bus: StringName) -> float:
	return float(DEFAULT_VOLUMES.get(bus, 1.0))


## Vuelve todos los buses a su volumen por defecto (sin guardar).
static func reset_volumes() -> void:
	for bus: StringName in ALL:
		set_volume(bus, default_volume(bus))


## Volúmenes lineales actuales de todos los buses: bus -> float.
static func get_volumes() -> Dictionary:
	var volumes: Dictionary = {}
	for bus: StringName in ALL:
		volumes[bus] = get_volume(bus)
	return volumes


## Lee los volúmenes de [param path] y los aplica. Los buses sin clave en el archivo (o si el
## archivo no existe o está mal) quedan a su valor por defecto. Devuelve los volúmenes aplicados.
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


## Guarda los volúmenes actuales en [param path], conservando lo demás que hubiera en el archivo.
## Devuelve el error de [method ConfigFile.save] ([constant OK] si fue bien).
static func save_volumes(path: String = SETTINGS_PATH) -> Error:
	var config: ConfigFile = ConfigFile.new()
	# Si el archivo no existe o está roto se empieza de cero; un archivo roto se sobrescribe.
	config.load(path)
	for bus: StringName in ALL:
		config.set_value(SETTINGS_SECTION, volume_key(bus), snappedf(get_volume(bus), 0.001))
	return config.save(path)
