class_name LocalServerLauncher
extends RefCounted
## Launches (or reuses) the local server of [code]--local[/code] (docs/networking.md, section 1.4).
## [br][br]
## The server is another process of this same executable, started with [code]--dev-lock[/code]: on
## opening its port it writes [constant LOCK_PATH] ([code]{pid, port}[/code]) and deletes it on closing.
## A window launched with [code]--local[/code] reads that file ([method get_running_port]): if the
## process is still alive it connects to that server, and if not it launches it with [method launch] and retries
## connecting for [constant CONNECT_RETRY_MS] ms (with a short ENet timeout,
## [constant CONNECT_TIMEOUT_MS]). The server shuts itself down after [constant IDLE_QUIT_SECONDS] s
## with no players, so several windows share the same server, a client that crashes does not
## leave it orphaned and the client [b]never[/b] kills it: this class only launches a process.
## [br][br]
## A server is not detected by trying [code]bind[/code] on the port: on Windows, UDP address
## reuse makes that unreliable.
## [br][br]
## [b]Foreign processes.[/b] [method OS.is_process_running] only knows the processes launched by this
## same process (on Windows it looks at its internal table of child processes; on Linux and macOS, with another
## process's pid it also logs an engine error): a second [code]--local[/code] window never launched the
## first one's server. That is why [method is_process_alive] uses [code]/proc[/code] (or
## [code]kill -0[/code]) on Linux and macOS, and [code]tasklist[/code] on Windows for what are not its own
## children.

## Lock file written by the server with [code]--dev-lock[/code].
const LOCK_PATH: String = "user://dev_server.json"
## Local server log.
const LOG_PATH: String = "user://logs/dev_server.log"
## Seconds without players after which the local server shuts itself down.
const IDLE_QUIT_SECONDS: int = 30
## ENet timeout (ms) on each connection attempt to the freshly launched server.
const CONNECT_TIMEOUT_MS: int = 1000
## Total time (ms) it keeps retrying to connect after launching the server.
const CONNECT_RETRY_MS: int = 10000
## Options of [code]--local[/code] that are forwarded to the server being launched (the rest are the
## client's). If a server is already running they are ignored, because it is reused as is.
const FORWARDED_OPTIONS: Array[String] = ["--debug-commands"]
const FORWARDED_OPTION_PREFIXES: Array[String] = ["--zone=", "--fake-players=", "--max-players=",
		"--dev-lock-path="]
## Option that changes the local server's lock file (and, with it, its log).
const DEV_LOCK_PATH_OPTION: String = "--dev-lock-path="

## Maximum bytes read from [code]/proc/<pid>/cmdline[/code].
const COMMAND_LINE_MAX_BYTES: int = 65536

var _pid: int = -1


## Command-line arguments the local server is launched with on [param port]
## ([code]--headless --path <project> --log-file <log> -- --server --port=… --idle-quit=30
## --dev-lock[/code]) followed by [param extra_args]. In an export ([param exported], by
## default [code]OS.has_feature("template")[/code]) there is no [code]--path[/code]: the executable already
## carries the game. The server takes the first occurrence of each option, so the extras
## cannot change the fixed ones. If [param extra_args] has [code]--dev-lock-path=<path>[/code], the
## log goes next to that lock ([method log_path_for]).
static func build_args(port: int, extra_args: PackedStringArray,
		exported: bool = OS.has_feature("template")) -> PackedStringArray:
	var args := PackedStringArray(["--headless"])
	if not exported:
		args.append("--path")
		args.append(ProjectSettings.globalize_path("res://"))
	args.append("--log-file")
	args.append(log_path_for(_lock_path_in(extra_args)))
	args.append("--")
	args.append("--server")
	args.append("--port=%d" % port)
	args.append("--idle-quit=%d" % IDLE_QUIT_SECONDS)
	args.append("--dev-lock")
	args.append_array(extra_args)
	return args


## System path of the log of the local server whose lock file is [param lock_path]:
## [constant LOG_PATH] if empty (the usual one) and, otherwise, the same file with extension
## [code].log[/code], so that a server with its own lock ([code]--dev-lock-path[/code]) does not
## write to the real local server's log.
static func log_path_for(lock_path: String) -> String:
	if lock_path.is_empty():
		return ProjectSettings.globalize_path(LOG_PATH)
	return ProjectSettings.globalize_path(lock_path.get_basename() + ".log")


## The options in [param user_args] (the client's user arguments) that are forwarded to the
## local server: [constant FORWARDED_OPTIONS] and [constant FORWARDED_OPTION_PREFIXES].
static func forwarded_args(user_args: PackedStringArray) -> PackedStringArray:
	var forwarded := PackedStringArray()
	for arg: String in user_args:
		var keep: bool = FORWARDED_OPTIONS.has(arg)
		for prefix: String in FORWARDED_OPTION_PREFIXES:
			keep = keep or arg.begins_with(prefix)
		if keep:
			forwarded.append(arg)
	return forwarded


## Contents of [param lock_path] as [code]{"pid": int, "port": int}[/code], or an empty dictionary
## if it does not exist or does not have that format.
static func read_lock(lock_path: String = LOCK_PATH) -> Dictionary:
	if not FileAccess.file_exists(lock_path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(lock_path)) != OK or not json.data is Dictionary:
		return {}
	var data: Dictionary = json.data
	if not (data.get("pid") is float or data.get("pid") is int) \
			or not (data.get("port") is float or data.get("port") is int):
		return {}
	return {"pid": int(data["pid"]), "port": int(data["port"])}


## Port of the local server that is running according to [param lock_path] (its process is still alive and is a
## server, [method is_dev_server_process]), or -1 if there is none.
static func get_running_port(lock_path: String = LOCK_PATH) -> int:
	var lock: Dictionary = read_lock(lock_path)
	if lock.is_empty():
		return -1
	var pid: int = int(lock["pid"])
	if not is_process_alive(pid) or not is_dev_server_process(pid):
		return -1
	var port: int = int(lock["port"])
	return port if port >= 1 and port <= 65535 else -1


## true if [param lock_path] describes a live server on [param port] (with [param port] at 0 or
## less, on any port). A lock from a process that no longer exists does not count.
static func find_running(port: int, lock_path: String = LOCK_PATH) -> bool:
	var running_port: int = get_running_port(lock_path)
	return running_port > 0 and (port <= 0 or running_port == port)


## true if process [param pid] exists. Unlike [method OS.is_process_running] it works with
## processes this one did not launch (the server was launched by another window) and does not log engine errors.
## On Windows it asks [code]tasklist[/code] ([method tasklist_args]).
static func is_process_alive(pid: int) -> bool:
	if pid <= 0:
		return false
	if pid == OS.get_process_id():
		return true
	match OS.get_name():
		"Windows":
			# OS.is_process_running works for own children; a server launched by another
			# window is only seen by tasklist.
			return OS.is_process_running(pid) or _is_alive_in_tasklist(pid)
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			return _is_alive_in_proc(pid)
		_:
			var output: Array = []
			return OS.execute("kill", PackedStringArray(["-0", str(pid)]), output, true) == 0


## true if [param args] (a process's command line, one argument per element) is that of a
## local server: it carries [code]--server[/code] and [code]--dev-lock[/code] as whole arguments.
static func command_line_is_dev_server(args: PackedStringArray) -> bool:
	return args.has("--server") and args.has("--dev-lock")


## true if another process's command line can be read ([code]/proc/<pid>/cmdline[/code]): only
## on Linux.
static func can_check_command_line() -> bool:
	return OS.get_name() == "Linux"


## true if process [param pid] looks like a server launched with [code]--dev-lock[/code]. A server
## that dies from a signal ([code]SIGTERM[/code] from systemd or docker stop, Ctrl+C) does not delete its lock,
## and if the system reuses its pid, the lock points to a live process that is not the server: there
## [code]--local[/code] would connect to nothing and waste an attempt. The command line is checked
## where possible ([method can_check_command_line]); elsewhere, or if it cannot be read, nothing is ruled out
## and it returns true.
static func is_dev_server_process(pid: int) -> bool:
	if not can_check_command_line():
		return true
	var args: PackedStringArray = _read_proc_command_line(pid)
	return args.is_empty() or command_line_is_dev_server(args)


## Launches the local server on [param port] with [method build_args] and returns its pid, or -1 if it
## could not launch it. [param extra_args] (for example [method forwarded_args]) is appended at the end.
func launch(port: int, extra_args: PackedStringArray) -> int:
	DirAccess.make_dir_recursive_absolute(log_path_for(_lock_path_in(extra_args)).get_base_dir())
	_pid = OS.create_process(OS.get_executable_path(), build_args(port, extra_args))
	return _pid


## Pid of the server launched by [method launch] (-1 if it has not launched any).
func get_pid() -> int:
	return _pid


## true if the server launched by [method launch] is still alive.
func is_server_alive() -> bool:
	return is_process_alive(_pid)


## [code]tasklist[/code] arguments that list only process [param pid], in CSV and without a header.
static func tasklist_args(pid: int) -> PackedStringArray:
	return PackedStringArray(["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"])


## true if the output of [code]tasklist[/code] ([method tasklist_args]) lists process [param pid]:
## a CSV row [code]"name.exe","pid","session","no.","memory"[/code] whose second column is the pid.
## With no matches, tasklist exits with 0 and writes a notice in the system language, which, not
## being a CSV row, does not count; that is why the column is read and the text is not searched for.
static func tasklist_lists_pid(output: String, pid: int) -> bool:
	for line: String in output.split("\n"):
		var columns: PackedStringArray = line.strip_edges().split("\",\"")
		if columns.size() >= 2 and columns[1].trim_prefix("\"").trim_suffix("\"") == str(pid):
			return true
	return false


# The value of the first --dev-lock-path= option in [param args], or an empty string.
static func _lock_path_in(args: PackedStringArray) -> String:
	for arg: String in args:
		if arg.begins_with(DEV_LOCK_PATH_OPTION):
			return arg.trim_prefix(DEV_LOCK_PATH_OPTION)
	return ""


# Command-line arguments of the process (/proc/<pid>/cmdline separates them with null bytes), or
# an empty array if they cannot be read (the process no longer exists, is a zombie or belongs to another user).
static func _read_proc_command_line(pid: int) -> PackedStringArray:
	var args := PackedStringArray()
	var path: String = "/proc/%d/cmdline" % pid
	if not FileAccess.file_exists(path):
		return args
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return args
	# Files in /proc are 0 bytes in size: a maximum size is requested, not the file's.
	var bytes: PackedByteArray = file.get_buffer(COMMAND_LINE_MAX_BYTES)
	file.close()
	var start: int = 0
	for i: int in bytes.size():
		if bytes[i] == 0:
			if i > start:
				args.append(bytes.slice(start, i).get_string_from_utf8())
			start = i + 1
	if start < bytes.size():
		args.append(bytes.slice(start).get_string_from_utf8())
	return args


# On Windows: asks tasklist for the pid (a terminated process does not appear in the list).
static func _is_alive_in_tasklist(pid: int) -> bool:
	var output: Array = []
	var exit_code: int = OS.execute("tasklist", tasklist_args(pid), output, false)
	return exit_code == 0 and not output.is_empty() and tasklist_lists_pid(String(output[0]), pid)


# On Linux, /proc/<pid>/stat exists as long as the process exists, also as a zombie (terminated and
# not reaped by its parent): "pid (name) state ...", where the name may contain parentheses, so
# the state is the letter after the last ')'.
static func _is_alive_in_proc(pid: int) -> bool:
	var stat_path: String = "/proc/%d/stat" % pid
	if not FileAccess.file_exists(stat_path):
		return false
	# Files in /proc are 0 bytes in size: the line is read, not the whole file.
	var file: FileAccess = FileAccess.open(stat_path, FileAccess.READ)
	if file == null:
		return false
	var text: String = file.get_line()
	file.close()
	var close: int = text.rfind(")")
	if close < 0 or close + 2 >= text.length():
		return true
	var state: String = text[close + 2]
	return state != "Z" and state != "X"
