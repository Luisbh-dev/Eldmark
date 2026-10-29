class_name LocalServerLauncher
extends RefCounted
## Lanza (o reutiliza) el servidor local de [code]--local[/code] (docs/red.md, sección 1.4).
## [br][br]
## El servidor es otro proceso de este mismo ejecutable, que arranca con [code]--dev-lock[/code]: al
## abrir su puerto escribe [constant LOCK_PATH] ([code]{pid, port}[/code]) y lo borra al cerrar.
## Una ventana lanzada con [code]--local[/code] lee ese archivo ([method get_running_port]): si el
## proceso sigue vivo se conecta a ese servidor, y si no lo lanza con [method launch] y reintenta
## conectar durante [constant CONNECT_RETRY_MS] ms (con un tiempo de espera corto de ENet,
## [constant CONNECT_TIMEOUT_MS]). El servidor se cierra solo tras [constant IDLE_QUIT_SECONDS] s
## sin jugadores, así que varias ventanas comparten el mismo servidor, un cliente que se cae no lo
## deja huérfano y el cliente [b]nunca[/b] lo mata: esta clase solo lanza un proceso.
## [br][br]
## No se detecta un servidor intentando [code]bind[/code] en el puerto: en Windows, la reutilización
## de direcciones UDP lo hace poco fiable.
## [br][br]
## [b]Procesos ajenos.[/b] [method OS.is_process_running] solo conoce los procesos que lanzó este
## mismo proceso: en Linux y macOS, con el pid de otro registra un error del motor y devuelve false.
## Por eso [method is_process_alive] usa [code]/proc[/code] (o [code]kill -0[/code]) fuera de
## Windows.

## Archivo de bloqueo que escribe el servidor con [code]--dev-lock[/code].
const LOCK_PATH: String = "user://dev_server.json"
## Registro del servidor local.
const LOG_PATH: String = "user://logs/dev_server.log"
## Segundos sin jugadores tras los que el servidor local se cierra solo.
const IDLE_QUIT_SECONDS: int = 30
## Tiempo de espera de ENet (ms) en cada intento de conexión con el servidor recién lanzado.
const CONNECT_TIMEOUT_MS: int = 1000
## Tiempo total (ms) que se reintenta conectar después de lanzar el servidor.
const CONNECT_RETRY_MS: int = 10000
## Opciones de [code]--local[/code] que se reenvían al servidor que se lanza (el resto son del
## cliente). Si ya hay un servidor en marcha se ignoran, porque se reutiliza tal cual.
const FORWARDED_OPTIONS: Array[String] = ["--debug-commands"]
const FORWARDED_OPTION_PREFIXES: Array[String] = ["--zone=", "--fake-players=", "--max-players="]

var _pid: int = -1


## Argumentos de línea de comandos con los que se lanza el servidor local en [param port]
## ([code]--headless --path <proyecto> --log-file <registro> -- --server --port=… --idle-quit=30
## --dev-lock[/code]) seguidos de [param extra_args]. En una exportación ([param exported], por
## defecto [code]OS.has_feature("template")[/code]) no hay [code]--path[/code]: el ejecutable ya
## lleva el juego. El servidor toma la primera aparición de cada opción, así que los extra no
## pueden cambiar las fijas.
static func build_args(port: int, extra_args: PackedStringArray,
		exported: bool = OS.has_feature("template")) -> PackedStringArray:
	var args := PackedStringArray(["--headless"])
	if not exported:
		args.append("--path")
		args.append(ProjectSettings.globalize_path("res://"))
	args.append("--log-file")
	args.append(ProjectSettings.globalize_path(LOG_PATH))
	args.append("--")
	args.append("--server")
	args.append("--port=%d" % port)
	args.append("--idle-quit=%d" % IDLE_QUIT_SECONDS)
	args.append("--dev-lock")
	args.append_array(extra_args)
	return args


## Las opciones de [param user_args] (los argumentos de usuario del cliente) que se reenvían al
## servidor local: [constant FORWARDED_OPTIONS] y [constant FORWARDED_OPTION_PREFIXES].
static func forwarded_args(user_args: PackedStringArray) -> PackedStringArray:
	var forwarded := PackedStringArray()
	for arg: String in user_args:
		var keep: bool = FORWARDED_OPTIONS.has(arg)
		for prefix: String in FORWARDED_OPTION_PREFIXES:
			keep = keep or arg.begins_with(prefix)
		if keep:
			forwarded.append(arg)
	return forwarded


## Contenido de [param lock_path] como [code]{"pid": int, "port": int}[/code], o un diccionario
## vacío si no existe o no tiene ese formato.
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


## Puerto del servidor local que hay en marcha según [param lock_path] (su proceso sigue vivo), o -1
## si no hay ninguno.
static func get_running_port(lock_path: String = LOCK_PATH) -> int:
	var lock: Dictionary = read_lock(lock_path)
	if lock.is_empty() or not is_process_alive(int(lock["pid"])):
		return -1
	var port: int = int(lock["port"])
	return port if port >= 1 and port <= 65535 else -1


## true si [param lock_path] describe un servidor vivo en [param port] (con [param port] a 0 o
## menos, en cualquier puerto). Un bloqueo de un proceso que ya no existe no cuenta.
static func find_running(port: int, lock_path: String = LOCK_PATH) -> bool:
	var running_port: int = get_running_port(lock_path)
	return running_port > 0 and (port <= 0 or running_port == port)


## true si el proceso [param pid] existe. A diferencia de [method OS.is_process_running] sirve con
## procesos que no lanzó este (el servidor lo lanzó otra ventana) y no registra errores del motor.
static func is_process_alive(pid: int) -> bool:
	if pid <= 0:
		return false
	if pid == OS.get_process_id():
		return true
	match OS.get_name():
		"Windows":
			return OS.is_process_running(pid)
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			return _is_alive_in_proc(pid)
		_:
			var output: Array = []
			return OS.execute("kill", PackedStringArray(["-0", str(pid)]), output, true) == 0


## Lanza el servidor local en [param port] con [method build_args] y devuelve su pid, o -1 si no
## pudo lanzarlo. [param extra_args] (por ejemplo [method forwarded_args]) se añade al final.
func launch(port: int, extra_args: PackedStringArray) -> int:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOG_PATH).get_base_dir())
	_pid = OS.create_process(OS.get_executable_path(), build_args(port, extra_args))
	return _pid


## Pid del servidor que lanzó [method launch] (-1 si no ha lanzado ninguno).
func get_pid() -> int:
	return _pid


## true si el servidor que lanzó [method launch] sigue vivo.
func is_server_alive() -> bool:
	return is_process_alive(_pid)


# En Linux, /proc/<pid>/stat existe mientras el proceso exista, también como zombi (ya terminado y
# sin recoger por su padre): "pid (nombre) estado ...", donde el nombre puede llevar paréntesis, así
# que el estado es la letra tras el último ')'.
static func _is_alive_in_proc(pid: int) -> bool:
	var stat_path: String = "/proc/%d/stat" % pid
	if not FileAccess.file_exists(stat_path):
		return false
	# Los archivos de /proc miden 0 bytes: se lee la línea, no el archivo entero.
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
