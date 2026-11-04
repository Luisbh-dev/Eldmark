class_name HintLog
extends RefCounted
## Which game hints (UI-42, [HintCatalog]) the player has already seen, so that each shows only once per
## player. It is saved to [code]user://hints.cfg[/code] (a [ConfigFile], section [code]shown[/code], one
## key per hint) every time one is recorded: they are few and sparse. An unreadable file or one with
## garbage breaks nothing: anything that is not a known hint marked as seen is ignored.
## [br][br]
## [method in_memory] gives a log that does not touch the disk. It is the one [method current] uses in
## headless mode (the tests and the clients of test processes are not a player and must not leave a file
## in [code]user://[/code]). Client only.

const PATH: String = "user://hints.cfg"
const SECTION: String = "shown"

static var _current: HintLog = null

## File where it is saved; empty = in memory only.
var path: String = ""

var _shown: Dictionary[StringName, bool] = {}


## The player's log: loaded from [constant PATH] the first time it is requested (without a display, an
## in-memory one).
static func current() -> HintLog:
	if _current == null:
		_current = in_memory() if DisplayServer.get_name() == "headless" else load_from(PATH)
	return _current


## Replaces the log in use (null forgets it and it is reloaded when requested).
static func set_current(hint_log: HintLog) -> void:
	_current = hint_log


## An empty log that is not saved to any file.
static func in_memory() -> HintLog:
	return HintLog.new()


## The log saved in [param file_path] (empty if it does not exist or is malformed).
static func load_from(file_path: String) -> HintLog:
	var hint_log := HintLog.new()
	hint_log.path = file_path
	hint_log.load_file()
	return hint_log


## true if hint [param id] has already been shown at some point.
func has_shown(id: StringName) -> bool:
	return _shown.has(id)


## Records that [param id] has been shown and saves. Returns false if it was already recorded.
func mark_shown(id: StringName) -> bool:
	if _shown.has(id):
		return false
	_shown[id] = true
	save_file()
	return true


## Forgets everything seen (and saves): the hints show again.
func reset() -> void:
	_shown.clear()
	save_file()


## How many hints have been seen.
func get_shown_count() -> int:
	return _shown.size()


## Reads [member path] (if set). Returns the error of [method ConfigFile.load].
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


## Saves to [member path] (does nothing if empty). Returns the error of [method ConfigFile.save].
func save_file() -> Error:
	if path.is_empty():
		return OK
	var config := ConfigFile.new()
	for id: StringName in _shown:
		config.set_value(SECTION, String(id), true)
	return config.save(path)
