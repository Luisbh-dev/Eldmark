extends SceneTree
## Helper process for the [LocalServerLauncher] tests (not a test: the runner only discovers
## [code]test_*.gd[/code]). Launched with [method NetHarness.launch_script], it does whatever its user
## arguments ask (those after [code]--[/code]); it ignores the ones it does not know, so a process
## launched with [code]--server --dev-lock[/code] acts as a fake local server (its command line is that
## of a real one).
## [br]- [code]--probe-alive=<pid>[/code]: writes to [code]--probe-out[/code]
## [code]{"alive": bool}[/code], which is what [method LocalServerLauncher.is_process_alive] answers for
## that pid from this process (which did not launch it).
## [br]- [code]--probe-spawn=<s>[/code]: launches another identical process that sleeps [code]<s>[/code]
## seconds and writes to [code]--probe-out[/code] [code]{"grandchild": pid}[/code]; the grandchild's
## log goes to [code]--probe-dir[/code].
## [br]- [code]--probe-sleep=<s>[/code]: waits [code]<s>[/code] seconds before exiting.

const SCRIPT_PATH: String = "res://tests/process_probe.gd"


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var result: Dictionary = {}
	var alive_text: String = _option(args, "--probe-alive=")
	if not alive_text.is_empty():
		result["alive"] = LocalServerLauncher.is_process_alive(alive_text.to_int())
	var spawn_text: String = _option(args, "--probe-spawn=")
	if not spawn_text.is_empty():
		result["grandchild"] = _spawn_sleeper(spawn_text.to_int(), _option(args, "--probe-dir="))
	var out_path: String = _option(args, "--probe-out=")
	if not out_path.is_empty():
		var file: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(result))
			file.close()
	var sleep_seconds: float = _option(args, "--probe-sleep=").to_float()
	if sleep_seconds > 0.0:
		create_timer(sleep_seconds).timeout.connect(func() -> void: quit(0))
	else:
		quit(0)


# Launches another process of this script that sleeps [param seconds] s and returns its pid (-1 on failure).
func _spawn_sleeper(seconds: int, log_dir: String) -> int:
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://")])
	if not log_dir.is_empty():
		args.append("--log-file")
		args.append(log_dir.path_join("process_probe_grandchild.log"))
	args.append_array(PackedStringArray(["-s", SCRIPT_PATH, "--", "--probe-sleep=%d" % seconds]))
	return OS.create_process(OS.get_executable_path(), args)


static func _option(args: PackedStringArray, prefix: String) -> String:
	for arg: String in args:
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix)
	return ""
