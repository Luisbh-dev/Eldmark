extends SceneTree
## Proceso auxiliar de las pruebas de [LocalServerLauncher] (no es una prueba: el ejecutor solo
## descubre [code]test_*.gd[/code]). Se lanza con [method NetHarness.launch_script] y hace lo que le
## piden sus argumentos de usuario (los que van tras [code]--[/code]); los que no conoce los ignora,
## así que un proceso lanzado con [code]--server --dev-lock[/code] hace de servidor local falso
## (su línea de comandos es la de uno de verdad).
## [br]- [code]--probe-alive=<pid>[/code]: escribe en [code]--probe-out[/code]
## [code]{"alive": bool}[/code], lo que contesta [method LocalServerLauncher.is_process_alive] para
## ese pid desde este proceso (que no lo lanzó).
## [br]- [code]--probe-spawn=<s>[/code]: lanza otro proceso igual que duerme [code]<s>[/code]
## segundos y escribe en [code]--probe-out[/code] [code]{"grandchild": pid}[/code]; el registro del
## nieto va a [code]--probe-dir[/code].
## [br]- [code]--probe-sleep=<s>[/code]: espera [code]<s>[/code] segundos antes de salir.

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


# Lanza otro proceso de este script que duerme [param seconds] s y devuelve su pid (-1 si falla).
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
