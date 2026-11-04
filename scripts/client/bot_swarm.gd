class_name BotSwarm
extends Node
## Swarm of lightweight clients for load tests (docs/networking.md, sections 14, 15 and 17.5; TEC-11):
## the root of the [code]--bots=N[/code] mode.
## [br][br]
## [ClientLauncher] (which [code]boot.gd[/code] mounts) fills in [member config] with
## [method ClientConfig.from_args] and switches to
## [code]scenes/client/bot_swarm.tscn[/code]. It creates [member ClientConfig.bot_count] [SwarmBot]s,
## one every [constant SPAWN_INTERVAL_TICKS] ticks (so they do not all enter on the same tick),
## each with its own [NetTransport] and [SceneMultiplayer]. The bots do not load the zone or
## simulate (see [SwarmBot]), so a single process can sustain dozens of them.
## [br][br]
## Options ([ClientConfig]): [code]--bots=N --connect=<host>[:<puerto>] [--realm=<reino>]
## [--bot-seed=N] [--bot-brain=combat] [--net-sim=…] [--quit-after-ticks=N] [--quit-at-server-tick=N]
## [--dtls-cert=<pem> --dtls-name=<cn>] [--report=<ruta.json>][/code]. With [code]--platform[/code]
## it does not start: it exits with code 1 and a clear error (docs/platform.md §5.5). With
## [code]--dtls-cert[/code] (a zone with [code]--dtls-cert --dtls-key[/code], §10.2) each
## [SwarmBot] connects over DTLS with that pinned certificate and that name; without
## [code]--dtls-name[/code] or with a certificate that cannot be read it exits with code 1 (never in
## cleartext). Bot [i]i[/i]
## is named [code]NameRules.bot_name(bot_seed + i)[/code]: two swarms against the same server
## need different seeds (names cannot repeat within a zone). Without [code]--realm[/code]
## the bots are split between Vardheim and Solmarch.
## [br][br]
## With [code]--quit-after-ticks=N[/code], after N local physics ticks (from when the swarm
## starts) the bots leave the zone with CLIENT_LEAVE, the report is written and the process closes
## with code 0 if all the bots were playing, and with 1 if any was rejected, disconnected or never
## got in. With [code]--quit-at-server-tick=N[/code] it does the same as soon as any of its bots
## receives a snapshot of server tick N (or later): a loaded server runs slower than real time, and
## the load test needs the bots to stay in until a server tick, not until a clock instant
## ([code]tools/load_test.gd[/code]). Both can go together: it exits with whichever is met first.
## [br][br]
## [b]Report[/b] ([method build_report]): [code]bots[/code] requested, created, playing, rejected
## and disconnected; [code]totals[/code] (upload and download bytes of all, snapshots, average
## snapshot size, average KB/s per client...) and [code]clients[/code], a [method SwarmBot.get_stats] record per bot (upload and download bytes, snapshots received and average size).

## Ticks between the creation of one bot and the next.
const SPAWN_INTERVAL_TICKS: int = 5
## Ticks waited, after requesting the bots' departure, for the connections to close.
const LEAVE_WAIT_TICKS: int = 30
## Maximum frames per second in headless mode (section 1.3).
const MAX_FPS: int = 120
## Error for [code]--bots[/code] with [code]--platform[/code].
const TEXT_NO_PLATFORM: String = "--bots no admite --platform: el enjambre solo va contra zonas sin plataforma (para entrar con cuenta, --bot --platform=<url> --login=<correo> --password-file=<ruta>)"
## Error for [code]--dtls-cert[/code] without [code]--dtls-name[/code] or with a certificate that cannot be read.
const TEXT_BAD_DTLS: String = "DTLS: el enjambre necesita --dtls-cert=<pem> legible y --dtls-name=<cn> (el nombre del certificado de la zona); no conecta en claro"

## Swarm configuration. It is filled in by [ClientLauncher]; if it is null at startup, it is read
## from the user arguments.
static var config: ClientConfig
## For tests only: if valid, shutdown calls this hook with the exit code instead of closing the process.
static var quit_hook: Callable = Callable()

var _config: ClientConfig = null
# The zone's pinned certificate (--dtls-cert and --dtls-name), the same for all the bots; null = cleartext.
var _dtls: TLSOptions = null
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


## Starts the swarm: it creates the first bot right away and one more every [constant SPAWN_INTERVAL_TICKS] ticks up to [member ClientConfig.bot_count].
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
	if not _config.platform_url.is_empty():
		# The swarm's bots have no account: only against zones without a platform (docs/platform.md §5.5).
		printerr("[Eldmark] %s" % TEXT_NO_PLATFORM)
		_quit(1)
		return
	if _config.has_dtls():
		# A single pinned certificate for all the bots; without it, it does not connect in cleartext (docs/platform.md §10.2).
		_dtls = NetClient.dtls_options(_config) if not _config.dtls_name.is_empty() else null
		if _dtls == null:
			printerr("[Eldmark] %s" % TEXT_BAD_DTLS)
			_quit(1)
			return
	print("[Eldmark] Enjambre: %d bots hacia %s:%d (uno cada %d ticks, semilla %d%s)" % [
		_config.bot_count, _config.address, _config.port, SPAWN_INTERVAL_TICKS, _config.bot_seed,
		", DTLS con «%s»" % _config.dtls_name if _dtls != null else "",
	])
	_running = true
	_spawn_bot()
	set_physics_process(true)


## Bots created so far, in creation order.
func get_bots() -> Array[SwarmBot]:
	return _bots


## Physics ticks the swarm has run.
func get_tick() -> int:
	return _tick


## Swarm tick at which bot [param index] was created.
func get_created_tick(index: int) -> int:
	return _created_ticks[index] if index >= 0 and index < _created_ticks.size() else -1


## Bots that are already playing (they have a character on the server).
func count_in_world() -> int:
	var count: int = 0
	for bot: SwarmBot in _bots:
		if bot.is_in_world():
			count += 1
	return count


## Code with which the process will close (or closed).
func get_exit_code() -> int:
	return _exit_code


## true when the swarm has finished (report written and shutdown requested).
func is_finished() -> bool:
	return _quitting


## Swarm report (see the class documentation).
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
		"dtls": _dtls != null,
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


## Writes the JSON report to [param path] (missing directories are created).
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


# --- Loop -------------------------------------------------------------------------------------

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
		_begin_finish("--quit-after-ticks")
		return
	var quit_at: int = _config.quit_at_server_tick
	if quit_at > 0 and newest_server_tick() >= quit_at:
		_begin_finish("--quit-at-server-tick")


## The most recent server tick that any of its bots has seen in a snapshot (0 if none has received one).
func newest_server_tick() -> int:
	var newest: int = 0
	for bot: SwarmBot in _bots:
		newest = maxi(newest, bot.get_newest_server_tick())
	return newest


func _spawn_bot() -> void:
	var bot := SwarmBot.new()
	add_child(bot)
	bot.setup(_bots.size(), _config, _dtls)
	_bots.append(bot)
	_created_ticks.append(_tick)


# Normal ending: the bots leave the zone and, once they are gone (or after LEAVE_WAIT_TICKS),
# report and shutdown. [param reason] is the option that decided it.
func _begin_finish(reason: String) -> void:
	print("[Eldmark] Fin del enjambre: %d ticks locales, tick %d del servidor (%s), %d de %d bots jugando"
			% [_tick, newest_server_tick(), reason, count_in_world(), _bots.size()])
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
