class_name BotSwarm
extends Node
## Enjambre de clientes ligeros para las pruebas de carga (docs/red.md, secciones 14, 15 y 17.5;
## TEC-11): la raíz del modo [code]--bots=N[/code].
## [br][br]
## [code]boot.gd[/code] rellena [member config] con [method ClientConfig.from_args] y cambia a
## [code]scenes/client/bot_swarm.tscn[/code]. Crea [member ClientConfig.bot_count] [SwarmBot], uno cada
## [constant SPAWN_INTERVAL_TICKS] ticks (para no entrar todos en el mismo tick), cada uno con su
## [NetTransport] y su [SceneMultiplayer]. Los bots no cargan la zona ni simulan (ver [SwarmBot]), así
## que un proceso aguanta decenas de ellos.
## [br][br]
## Opciones ([ClientConfig]): [code]--bots=N --connect=<host>[:<puerto>] [--realm=<reino>]
## [--bot-seed=N] [--net-sim=…] [--quit-after-ticks=N] [--report=<ruta.json>][/code]. El bot [i]i[/i]
## se llama [code]NameRules.bot_name(bot_seed + i)[/code]: dos enjambres contra el mismo servidor
## necesitan semillas distintas (los nombres no se pueden repetir en una zona). Sin [code]--realm[/code]
## los bots se reparten entre Vardheim y Solmarch.
## [br][br]
## Con [code]--quit-after-ticks=N[/code], tras N ticks de física locales (desde que arranca el
## enjambre) los bots salen de la zona con CLIENT_LEAVE, se escribe el informe y se cierra con
## código 0 si todos los bots estaban jugando, y con 1 si alguno fue rechazado, se desconectó o no
## llegó a entrar.
## [br][br]
## [b]Informe[/b] ([method build_report]): [code]bots[/code] pedidos, creados, jugando, rechazados y
## desconectados; [code]totals[/code] (bytes de subida y de bajada de todos, snapshots, tamaño medio de
## snapshot, KB/s medios por cliente...) y [code]clients[/code], una ficha de [method SwarmBot.get_stats]
## por bot (bytes de subida y de bajada, snapshots recibidos y tamaño medio).

## Ticks entre la creación de un bot y la del siguiente.
const SPAWN_INTERVAL_TICKS: int = 5
## Ticks que se espera, tras pedir la salida de los bots, a que se cierren las conexiones.
const LEAVE_WAIT_TICKS: int = 30
## Fotogramas por segundo máximos en headless (sección 1.3).
const MAX_FPS: int = 120

## Configuración del enjambre. La rellena [code]boot.gd[/code]; si es null al arrancar, se lee de
## los argumentos de usuario.
static var config: ClientConfig
## Solo para pruebas: si es válido, el cierre llama a este gancho con el código de salida en lugar de
## cerrar el proceso.
static var quit_hook: Callable = Callable()

var _config: ClientConfig = null
var _bots: Array[SwarmBot] = []
var _created_ticks: Array[int] = []
var _tick: int = 0
var _running: bool = false
var _finishing: bool = false
var _finish_ticks: int = 0
var _quitting: bool = false
var _exit_code: int = 0


func _ready() -> void:
	if config == null:
		config = ClientConfig.from_args(OS.get_cmdline_user_args())
	_apply_settings()
	set_physics_process(false)
	start(config)


## Empieza el enjambre: crea el primer bot ya y uno más cada [constant SPAWN_INTERVAL_TICKS] ticks hasta
## [member ClientConfig.bot_count].
func start(p_config: ClientConfig) -> void:
	if _running or p_config == null:
		return
	_config = p_config
	for warning: String in _config.warnings:
		push_warning("[Eldmark] %s" % warning)
	if _config.bot_count <= 0:
		push_error("[Eldmark] El enjambre necesita --bots=N con N > 0")
		_quit(1)
		return
	print("[Eldmark] Enjambre: %d bots hacia %s:%d (uno cada %d ticks, semilla %d)" % [
		_config.bot_count, _config.address, _config.port, SPAWN_INTERVAL_TICKS, _config.bot_seed,
	])
	_running = true
	_spawn_bot()
	set_physics_process(true)


## Bots creados hasta ahora, por orden de creación.
func get_bots() -> Array[SwarmBot]:
	return _bots


## Ticks de física que lleva el enjambre.
func get_tick() -> int:
	return _tick


## Tick del enjambre en el que se creó el bot [param index].
func get_created_tick(index: int) -> int:
	return _created_ticks[index] if index >= 0 and index < _created_ticks.size() else -1


## Bots que ya juegan (tienen personaje en el servidor).
func count_in_world() -> int:
	var count: int = 0
	for bot: SwarmBot in _bots:
		if bot.is_in_world():
			count += 1
	return count


## Código con el que se cerrará (o se cerró) el proceso.
func get_exit_code() -> int:
	return _exit_code


## true cuando el enjambre ha terminado (informe escrito y cierre pedido).
func is_finished() -> bool:
	return _quitting


## Informe del enjambre (ver la documentación de la clase).
func build_report() -> Dictionary:
	var clients: Array[Dictionary] = []
	var in_world: int = 0
	var rejected: int = 0
	var disconnected: int = 0
	var up: int = 0
	var down: int = 0
	var snapshots: int = 0
	var snapshot_bytes: int = 0
	var max_snapshot_bytes: int = 0
	var seconds_up: float = 0.0
	var kb_up_sum: float = 0.0
	var kb_down_sum: float = 0.0
	var measured: int = 0
	var late_snapshots: int = 0
	var substitution_rises: int = 0
	for bot: SwarmBot in _bots:
		var stats: Dictionary = bot.get_stats()
		clients.append(stats)
		if bot.is_in_world() or bot.get_state() == SwarmBot.State.LEAVING \
				or (bot.get_state() == SwarmBot.State.CLOSED and int(stats["net_id"]) > 0):
			in_world += 1
		if bool(stats["rejected"]):
			rejected += 1
		elif bot.get_state() == SwarmBot.State.CLOSED and int(stats["net_id"]) == 0:
			disconnected += 1
		up += int(stats["bytes_up"])
		down += int(stats["bytes_down"])
		snapshots += int(stats["snapshots"])
		snapshot_bytes += int(stats["snapshot_bytes"])
		max_snapshot_bytes = maxi(max_snapshot_bytes, int(stats["max_snapshot_bytes"]))
		late_snapshots += int(stats["late_snapshots"])
		substitution_rises += int(stats["substitution_rises"])
		if int(stats["world_ticks"]) > 0:
			measured += 1
			kb_up_sum += float(stats["kb_up_per_s"])
			kb_down_sum += float(stats["kb_down_per_s"])
			seconds_up = maxf(seconds_up, float(stats["world_ticks"]) / float(Engine.physics_ticks_per_second))
	return {
		"version": 1,
		"mode": "SWARM",
		"address": _config.address if _config != null else "",
		"port": _config.port if _config != null else 0,
		"net_sim": _config.net_sim_spec if _config != null else "",
		"seed": _config.bot_seed if _config != null else 0,
		"ticks": _tick,
		"bots": {
			"requested": _config.bot_count if _config != null else 0,
			"created": _bots.size(),
			"played": in_world,
			"rejected": rejected,
			"disconnected": disconnected,
			"playing_now": count_in_world(),
		},
		"totals": {
			"bytes_up": up,
			"bytes_down": down,
			"snapshots": snapshots,
			"late_snapshots": late_snapshots,
			"snapshot_bytes": snapshot_bytes,
			"avg_snapshot_bytes": float(snapshot_bytes) / float(snapshots) if snapshots > 0 else 0.0,
			"max_snapshot_bytes": max_snapshot_bytes,
			"avg_kb_up_per_s": kb_up_sum / float(measured) if measured > 0 else 0.0,
			"avg_kb_down_per_s": kb_down_sum / float(measured) if measured > 0 else 0.0,
			"longest_session_s": seconds_up,
			"substitution_rises": substitution_rises,
		},
		"clients": clients,
	}


## Escribe el informe JSON en [param path] (los directorios que falten se crean).
func write_report(path: String) -> Error:
	if path.is_empty():
		return ERR_INVALID_PARAMETER
	var directory: String = path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		var made: Error = DirAccess.make_dir_recursive_absolute(directory)
		if made != OK:
			return made
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(build_report(), "\t"))
	file.close()
	return OK


# --- Bucle ------------------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if _quitting or not _running:
		return
	_tick += 1
	if _finishing:
		_finish_ticks += 1
		if _finish_ticks >= LEAVE_WAIT_TICKS or _all_closed():
			_finish()
		return
	if _bots.size() < _config.bot_count and _tick % SPAWN_INTERVAL_TICKS == 0:
		_spawn_bot()
	var quit_after: int = _config.quit_after_ticks
	if quit_after > 0 and _tick >= quit_after:
		_begin_finish()


func _spawn_bot() -> void:
	var bot := SwarmBot.new()
	add_child(bot)
	bot.setup(_bots.size(), _config)
	_bots.append(bot)
	_created_ticks.append(_tick)


# Fin normal: los bots salen de la zona y, cuando se han ido (o tras LEAVE_WAIT_TICKS), informe y cierre.
func _begin_finish() -> void:
	print("[Eldmark] Fin del enjambre: %d ticks locales (--quit-after-ticks), %d de %d bots jugando"
			% [_tick, count_in_world(), _bots.size()])
	_exit_code = 0 if count_in_world() == _config.bot_count else 1
	_write_report()
	_finishing = true
	_finish_ticks = 0
	for bot: SwarmBot in _bots:
		bot.leave()


func _all_closed() -> bool:
	for bot: SwarmBot in _bots:
		if bot.get_state() != SwarmBot.State.CLOSED:
			return false
	return true


func _finish() -> void:
	_quit(_exit_code)


func _write_report() -> void:
	if _config == null or _config.report_path.is_empty():
		return
	var error: Error = write_report(_config.report_path)
	if error == OK:
		print("[Eldmark] Informe del enjambre escrito en %s" % _config.report_path)
	else:
		push_warning("[Eldmark] No se pudo escribir el informe '%s' (error %d)"
				% [_config.report_path, error])


func _quit(code: int) -> void:
	if _quitting:
		return
	_quitting = true
	_exit_code = code
	if quit_hook.is_valid():
		quit_hook.call(code)
		return
	get_tree().quit(code)


func _apply_settings() -> void:
	get_tree().multiplayer_poll = false
	if DisplayServer.get_name() == "headless":
		Engine.max_fps = MAX_FPS
