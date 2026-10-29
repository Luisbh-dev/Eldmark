class_name HintLog
extends RefCounted
## Qué pistas del juego (UI-42, [HintCatalog]) ha visto ya el jugador, para que cada una salga una sola vez
## por jugador. Se guarda en [code]user://hints.cfg[/code] (un [ConfigFile], sección [code]shown[/code], una
## clave por pista) cada vez que se anota una: son pocas y sueltas. Un archivo ilegible o con basura no rompe
## nada: se ignora lo que no sea una pista conocida marcada como vista.
## [br][br]
## [method in_memory] da un registro que no toca el disco (el ejecutor de pruebas lo pone como el de por
## defecto para que montar la interfaz no escriba en [code]user://[/code]). Solo cliente.

const PATH: String = "user://hints.cfg"
const SECTION: String = "shown"

static var _current: HintLog = null

## Archivo donde se guarda; vacío = solo en memoria.
var path: String = ""

var _shown: Dictionary[StringName, bool] = {}


## El registro del jugador: se carga de [constant PATH] la primera vez que se pide.
static func current() -> HintLog:
	if _current == null:
		_current = load_from(PATH)
	return _current


## Sustituye el registro en uso (null lo olvida y se vuelve a cargar al pedirlo).
static func set_current(hint_log: HintLog) -> void:
	_current = hint_log


## Un registro vacío que no se guarda en ningún archivo.
static func in_memory() -> HintLog:
	return HintLog.new()


## El registro guardado en [param file_path] (vacío si no existe o está mal).
static func load_from(file_path: String) -> HintLog:
	var hint_log := HintLog.new()
	hint_log.path = file_path
	hint_log.load_file()
	return hint_log


## true si la pista [param id] ya se ha mostrado alguna vez.
func has_shown(id: StringName) -> bool:
	return _shown.has(id)


## Anota que se ha mostrado [param id] y guarda. Devuelve false si ya estaba anotada.
func mark_shown(id: StringName) -> bool:
	if _shown.has(id):
		return false
	_shown[id] = true
	save_file()
	return true


## Olvida todo lo visto (y guarda): las pistas vuelven a salir.
func reset() -> void:
	_shown.clear()
	save_file()


## Cuántas pistas se han visto.
func get_shown_count() -> int:
	return _shown.size()


## Lee [member path] (si lo hay). Devuelve el error de [method ConfigFile.load].
func load_file() -> Error:
	_shown.clear()
	if path.is_empty():
		return OK
	var config := ConfigFile.new()
	var error: Error = config.load(path)
	if error != OK:
		return error
	if config.has_section(SECTION):
		for key: String in config.get_section_keys(SECTION):
			var value: Variant = config.get_value(SECTION, key, false)
			if HintCatalog.has_hint(StringName(key)) and typeof(value) == TYPE_BOOL and bool(value):
				_shown[StringName(key)] = true
	return OK


## Guarda en [member path] (no hace nada si está vacío). Devuelve el error de [method ConfigFile.save].
func save_file() -> Error:
	if path.is_empty():
		return OK
	var config := ConfigFile.new()
	for id: StringName in _shown:
		config.set_value(SECTION, String(id), true)
	return config.save(path)
