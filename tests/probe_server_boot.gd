extends SceneTree
## Helper process for [code]test_architecture.gd[/code] (not a test: the runner only discovers
## [code]test_*.gd[/code]). Boots the project the way the main scene does: instantiates
## [code]res://scenes/boot.tscn[/code] with the user arguments (those after [code]--[/code]; with
## [code]--server[/code], the dedicated server of a zone), waits for the server to be running
## ([code]ZoneServer[/code] plus a few physics steps) and then reports, with lines starting with
## [code]LOADED <path>[/code], every script under [code]res://scripts/client/[/code] that ended up
## loaded in the process, and closes with [code]DONE total=<n> loaded=<n>[/code]. If the server does
## not start within [constant TIMEOUT_MSEC] ms, it writes [code]TIMEOUT[/code] and exits with code 2.
## [br][br]
## With [code]--probe-control=<path>[/code], after the report it loads that script and writes
## [code]CONTROL <path> true|false[/code] depending on whether it ended up in the cache: this way the
## test knows this detector really sees what gets loaded.

const BOOT_SCENE: String = "res://scenes/boot.tscn"
const CLIENT_DIR: String = "res://scripts/client"
const CONTROL_PREFIX: String = "--probe-control="
## Maximum wait (ms) for the server to start.
const TIMEOUT_MSEC: int = 20000
## Physics steps the server is left running once it is up.
const SETTLE_PHYSICS_FRAMES: int = 30

var _started_msec: int = 0
var _server_frame: int = -1


func _initialize() -> void:
	_started_msec = Time.get_ticks_msec()
	var boot: Node = (load(BOOT_SCENE) as PackedScene).instantiate()
	root.add_child(boot)
	current_scene = boot


func _process(_delta: float) -> bool:
	var scene: Node = current_scene
	if scene != null and scene.get_node_or_null(^"ZoneServer") != null:
		if _server_frame < 0:
			_server_frame = Engine.get_physics_frames()
		elif Engine.get_physics_frames() - _server_frame >= SETTLE_PHYSICS_FRAMES:
			_report()
			return true
	elif Time.get_ticks_msec() - _started_msec > TIMEOUT_MSEC:
		print("TIMEOUT")
		quit(2)
		return true
	return false


func _report() -> void:
	var scripts: PackedStringArray = _list_scripts(CLIENT_DIR)
	var loaded: int = 0
	for path: String in scripts:
		if ResourceLoader.has_cached(path):
			loaded += 1
			print("LOADED %s" % path)
	print("DONE total=%d loaded=%d" % [scripts.size(), loaded])
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(CONTROL_PREFIX):
			var control: String = arg.trim_prefix(CONTROL_PREFIX)
			load(control)
			print("CONTROL %s %s" % [control, str(ResourceLoader.has_cached(control)).to_lower()])
	quit(0)


func _list_scripts(dir_path: String) -> PackedStringArray:
	var found := PackedStringArray()
	for file_name: String in DirAccess.get_files_at(dir_path):
		if file_name.ends_with(".gd"):
			found.append(dir_path.path_join(file_name))
	for sub: String in DirAccess.get_directories_at(dir_path):
		found.append_array(_list_scripts(dir_path.path_join(sub)))
	return found
