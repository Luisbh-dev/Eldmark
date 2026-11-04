class_name OnlineMain
extends Node
## Root of the networked client (docs/networking.md, sections 1.2, 3 and 17.5). The offline sandbox is still
## [ClientMain]; this scene is the one for [code]--connect[/code] and [code]--bot[/code].
## [br][br]
## [ClientLauncher] (which [code]boot.gd[/code] mounts) fills in [member config] with
## [method ClientConfig.from_args] and switches to
## [code]scenes/client/online_main.tscn[/code]. The flow:
## [codeblock]
## NetTransport + LocalPlayerController + NetClient.start()    "Conectando…" (Connecting)
## welcomed          loads the WELCOME's zone in a thread (ResourceLoader.load_threaded_request),
##                   with the "Cargando…" (Loading) screen; when done, it adds it, waits a few
##                   physics steps for its collisions to be in the physics space (like the server)
##                   and calls NetClient.notify_zone_ready()
## local_spawned     camera, HUD and animated visual (in BOT mode, only controller.set_bot())
## rejected /        notice in Spanish (in BOT mode: report and exit with code 1)
## disconnected
## [/codeblock]
## [br][b]Settings.[/b] [code]multiplayer_poll = false[/code] (every tick it is polled by [NetClient]) and, in
## headless, [code]Engine.max_fps = 120[/code] (section 1.3).
## [br][br]
## [b]BOT mode[/b]: no camera or HUD. Input comes from a [BotBrain] ([ClientBotBrains]: stroll, or
## combat with [code]--bot-brain=combat[/code], seed [member ClientConfig.bot_seed], around its
## spawn point) and, in headless, the zone is
## loaded without visuals ([method ZoneRoot.strip_for_server]), just like on the server. With
## [code]--quit-after-ticks=N[/code], after N local physics ticks (counted from when the session starts:
## connection and loading count) it writes the report ([code]--report[/code]), leaves the zone with
## CLIENT_LEAVE and exits with code 0; with 1 if it was rejected or disconnected before. During the last
## [constant IDLE_TAIL_TICKS] ticks (a quarter at most) the bot stands still, so that
## convergence tests compare steady states. When dead, the bot asks to respawn (RESPAWN_REQUEST, on the
## first point of the list) as soon as the server allows it, like someone pressing the death screen's button or a
## [code]SwarmBot[/code]: that way it respawns in the wave it is due for and not at the 30 s of the automatic one.
## [br][br]
## [b]Scenario[/b] ([code]--bot-scenario=progress[/code], [BotProgressScenario], docs/progression.md §15 P8): on
## spawning, the bot stands still and runs the scenario; after each step it rewrites the report (with the key
## [code]scenario[/code], for whoever watches from outside while it plays). On finishing it exits with code 0 if there is no
## [code]--quit-after-ticks[/code] (with it, it continues until those ticks); if it fails, report and code 1.
## [br][br]
## [b]Realm choice.[/b] If a client with a window starts without [code]--realm[/code],
## [RealmSelect] is shown (realm, address and name, validated before connecting). It also returns to it,
## with the reason as a notice, after a rejection, a connection failure or a disconnection: the zone,
## camera, HUD and network session are removed and "Entrar" (Enter) starts a new session. A bot or a
## client without a screen (headless) has nobody to ask: it enters as Vardheim with a notice, and on
## a failure writes the report and exits with code 1.
## [br][br]
## [b]With an account[/b] (docs/platform.md §5.5 and §13). With a ticket ([method ClientConfig.has_ticket]) the realm and
## name are the character's and there is no realm choice. If the session comes from [FrontMain]
## ([member ClientConfig.from_front]), a rejection or a disconnection returns to character selection with the reason
## (the account session continues). A bot with [code]--platform[/code] first goes through the account path with
## [AccountFlow]: logs in with [code]--login[/code] and the password from [code]--password-file[/code], creates the
## character if missing ([code]--character[/code] or [method NameRules.bot_name] of the seed), asks for [code]enter[/code]
## and connects with the ticket. A failure on that path (credentials, [code]character_busy[/code] after 30 s,
## [code]zone_unavailable[/code]…) exits with code 1 and the [code]code[/code] in the report ([code]platform[/code]).
## [br][br]
## [b]LOCAL mode[/b] ([code]--local[/code], section 1.4): before connecting, if
## [code]user://dev_server.json[/code] describes a live server its port is used; if not, one is launched
## ([LocalServerLauncher]) and connecting is retried for [constant LocalServerLauncher.CONNECT_RETRY_MS]
## ms with a short ENet timeout (each attempt is a new session: [NetClient],
## transport and controller). If the server believed to be alive does not answer, one is launched then. The
## client never shuts the server down: it turns itself off after [constant LocalServerLauncher.IDLE_QUIT_SECONDS]
## s without players.

const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const NET_DEBUG_SCENE_PATH: String = "res://scenes/ui/net_debug_overlay.tscn"
const WINDOW_TITLE: String = "Eldmark"
## Maximum frames per second in headless (section 1.3).
const MAX_FPS: int = 120
## Physics steps to wait after adding the zone before reporting that it is ready: the
## collision bodies (Terrain3D, above all) enter the physics space during the first
## steps, and the server waits the same before accepting players.
const WARMUP_PHYSICS_FRAMES: int = 3
## Default realm while there is no RealmSelect.
const DEFAULT_REALM: int = NetProtocol.Realm.VARDHEIM
## Maximum ticks a bot stands still before exiting.
const IDLE_TAIL_TICKS: int = 90
## Radius (m) a bot strolls around its spawn point.
const BOT_RADIUS: float = 30.0
## Ticks to wait, after leaving the zone, for the connection to close before closing.
const LEAVE_WAIT_TICKS: int = 30
## How many local ticks a dead bot repeats its RESPAWN_REQUEST while it remains dead (1 s: after half an
## RTT the snapshot already shows it alive, and an extra request after respawning would be a server warning).
const BOT_RESPAWN_RETRY_TICKS: int = 60
## Width (base window pixels) of the text column of the loading screen.
const OVERLAY_WIDTH: float = 900.0
const REALM_SELECT_SCENE_PATH: String = "res://scenes/ui/realm_select.tscn"
## Scene of the title screen and character selection (return from a session with [member ClientConfig.from_front]).
const FRONT_MAIN_SCENE_PATH: String = "res://scenes/client/front_main.tscn"
## Layers of the realm choice screen (below the loading one, which is 100).
const REALM_SELECT_LAYER: int = 90

## Client configuration. Filled in by [ClientLauncher]; if it is null on start-up, it is read from the
## user arguments.
static var config: ClientConfig
## Tests only: if valid, closing calls this hook with the exit code instead of
## closing the process.
static var quit_hook: Callable = Callable()
## Tests only: lock file of the local server that is checked in LOCAL mode (so a
## test does not touch the real [constant LocalServerLauncher.LOCK_PATH]).
static var lock_path: String = LocalServerLauncher.LOCK_PATH
## Tests only: the client behaves like one with a window even if headless: it shows
## [RealmSelect] if the realm is missing and returns to it after a failure (in headless, without this, it enters as
## Vardheim and a failure closes the process with code 1).
static var force_interactive: bool = false
## Tests only: if valid, returning to [FrontMain] calls this hook with the reason instead of changing
## scene.
static var front_hook: Callable = Callable()
## Tests only: [member PlatformApi.request_hook] hook for the bot's account path.
static var account_request_hook: Callable = Callable()

var _transport: NetTransport = null
var _client: NetClient = null
var _launcher: LocalServerLauncher = null
var _local_deadline_msec: int = 0
var _was_welcomed: bool = false
var _controller: LocalPlayerController = null
var _entities: Node3D = null
var _world: Node3D = null
var _camera_rig: CameraRig = null
var _hud: HUD = null
var _net_debug: NetDebugOverlay = null
var _brain: BotBrain = null
var _loading_path: String = ""
var _zone_id: String = ""
var _overlay_layer: CanvasLayer = null
var _overlay_label: Label = null
var _overlay_button: Button = null
var _realm_layer: CanvasLayer = null
var _realm_select: RealmSelect = null
var _returning_to_menu: bool = false
# Per-realm count from the last WELCOME (empty before the first connection) and the realm the server rejected
# for imbalance on the last attempt (REJECT 9): RealmSelect shows it on returning (GUE-42).
var _last_realm_counts: PackedInt32Array = PackedInt32Array()
var _imbalanced_realm: int = NetProtocol.Realm.NONE
var _idle_set: bool = false
# Local tick of the bot's last respawn request.
var _bot_respawn_request_tick: int = -BOT_RESPAWN_RETRY_TICKS
var _finishing: bool = false
var _leave_wait_ticks: int = 0
var _quitting: bool = false
var _report_written: bool = false
var _exit_code: int = 0
# The bot's account path with --platform: the API and what goes into the report ("platform" key).
var _api: PlatformApi = null
var _account_report: Dictionary = {}
# The bot's scenario (--bot-scenario), from when it spawns.
var _scenario: BotProgressScenario = null


func _ready() -> void:
	if config == null:
		config = ClientConfig.from_args(OS.get_cmdline_user_args())
	_apply_settings()
	for warning: String in config.warnings:
		push_warning("[Eldmark] %s" % warning)
	set_process(false)
	set_physics_process(config.quit_after_ticks > 0 or _is_bot())
	if not _is_bot():
		InputBindings.ensure_defaults()
		_create_overlay()
	if _uses_account():
		_enter_with_account()
		return
	if config.realm == NetProtocol.Realm.NONE and not config.has_ticket():
		if _is_interactive():
			_show_realm_select("")
			return
		push_warning("[Eldmark] Falta --realm=<reino>: se entra como %s"
				% NetProtocol.realm_display_name(DEFAULT_REALM))
		config.realm = DEFAULT_REALM
	_begin_session()


## Network client.
func get_client() -> NetClient:
	return _client


## Loaded zone (null until loading finishes).
func get_world() -> Node3D:
	return _world


## Action camera (null in bot mode or before spawning).
func get_camera_rig() -> CameraRig:
	return _camera_rig


## HUD (null in bot mode or before spawning).
func get_hud() -> HUD:
	return _hud


## Network debugging, F3 and F4 (null in bot mode or before spawning).
func get_net_debug() -> NetDebugOverlay:
	return _net_debug


## Realm choice screen (null if it has never been shown).
func get_realm_select() -> RealmSelect:
	return _realm_select


## The bot's brain (null if it is not a bot or has not spawned yet).
func get_bot_brain() -> BotBrain:
	return _brain


## Code with which the process will close (or closed).
func get_exit_code() -> int:
	return _exit_code


## The platform API of the bot with an account (null if it does not use it).
func get_platform_api() -> PlatformApi:
	return _api


## The bot's scenario ([code]--bot-scenario[/code]; null without it or before spawning).
func get_bot_scenario() -> BotProgressScenario:
	return _scenario


## What goes into the report under [code]platform[/code] (empty without an account): [code]code[/code] (empty if it got in),
## [code]status[/code], [code]message[/code], [code]character_id[/code] and [code]created[/code].
func get_account_report() -> Dictionary:
	return _account_report


# Zone loading in a thread: the status is polled every frame.
func _process(_delta: float) -> void:
	if _loading_path.is_empty():
		return
	var progress: Array = []
	var status: ResourceLoader.ThreadLoadStatus = \
			ResourceLoader.load_threaded_get_status(_loading_path, progress)
	match status:
		ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			var fraction: float = float(progress[0]) if not progress.is_empty() else 0.0
			_show_status("Cargando %s… %d %%" % [_zone_id, roundi(fraction * 100.0)])
		ResourceLoader.THREAD_LOAD_LOADED:
			var path: String = _loading_path
			_loading_path = ""
			set_process(false)
			_enter_zone(path)
		_:
			_loading_path = ""
			set_process(false)
			_fail("No se pudo cargar la zona «%s»" % _zone_id)
			_client.leave()


func _physics_process(_delta: float) -> void:
	if _quitting or _client == null:
		return
	var local_tick: int = _client.get_local_tick()
	if _finishing:
		_leave_wait_ticks += 1
		if _leave_wait_ticks >= LEAVE_WAIT_TICKS:
			_quit(0)
		return
	if _brain != null:
		_request_bot_respawn(local_tick)
	if _scenario != null and not _scenario.is_finished():
		_scenario.step()
		if _scenario.is_failed():
			_fail("Escenario %s: %s" % [BotProgressScenario.NAME, _scenario.get_error()])
			return
		if _scenario.is_done() and config.quit_after_ticks <= 0:
			_finish_session()
			return
	var quit_after: int = config.quit_after_ticks
	if quit_after <= 0:
		return
	if _brain != null and not _idle_set \
			and local_tick >= quit_after - clampi(quit_after / 4, 0, IDLE_TAIL_TICKS):
		_idle_set = true
		_brain.set_idle_from(_client.get_prediction().get_predicted_tick() + 1)
	if local_tick >= quit_after:
		_finish_session()


# A dead bot asks to respawn as soon as the server allows it (the estimated server tick, which runs half an RTT
# behind, has reached its respawn tick: the request arrives on time, never before) and repeats it every
# BOT_RESPAWN_RETRY_TICKS while it remains dead. Point 0: if it is not valid for its realm, the server uses the first
# valid camp.
func _request_bot_respawn(local_tick: int) -> void:
	if _client.get_state() != NetClient.State.IN_WORLD or not _client.is_dead():
		return
	var respawn_tick: int = _client.get_respawn_tick()
	if respawn_tick <= 0 or _client.get_estimated_server_tick() < respawn_tick:
		return
	if local_tick - _bot_respawn_request_tick < BOT_RESPAWN_RETRY_TICKS:
		return
	_bot_respawn_request_tick = local_tick
	_client.send_respawn_request(0)


# --- Start-up ---------------------------------------------------------------------------------

func _apply_settings() -> void:
	get_window().title = WINDOW_TITLE
	var tree: SceneTree = get_tree()
	tree.multiplayer_poll = false
	if DisplayServer.get_name() == "headless":
		Engine.max_fps = MAX_FPS


func _is_bot() -> bool:
	return config.mode == ClientConfig.Mode.BOT


func _is_local() -> bool:
	return config.mode == ClientConfig.Mode.LOCAL


# A bot with --platform that does not yet have a ticket: the account path first.
func _uses_account() -> bool:
	return _is_bot() and not config.platform_url.is_empty() and not config.has_ticket()


# --- Bot with an account (docs/platform.md §5.5 and §13.3) --------------------------------------

# Logs in, ensures the character, asks for enter and connects with the ticket. Any failure closes with code 1.
func _enter_with_account() -> void:
	if config.login.is_empty() or config.password_file.is_empty():
		_fail_account("missing_login", 0,
				"El bot con --platform necesita --login=<correo> y --password-file=<ruta>")
		return
	var password: String = read_password_file(config.password_file)
	if password.is_empty():
		_fail_account("password_file", 0, "No se puede leer la contraseña de %s" % config.password_file)
		return
	_api = PlatformApi.new()
	_api.base_url = config.platform_url
	_api.request_hook = account_request_hook
	add_child(_api)
	var flow := AccountFlow.new(_api)
	var started_msec: int = Time.get_ticks_msec()
	print("[Eldmark] Iniciando sesión en %s como %s" % [config.platform_url, config.login])
	var login: ApiResult = await flow.login(config.login, password)
	if _quitting:
		return
	if not login.ok:
		_fail_account_result(login)
		return
	if flow.get_session().is_privacy():
		var restriction: Dictionary = flow.get_session().restriction
		var code: String = str(restriction.get("code", "account_suspended"))
		_fail_account(code, 403, PlatformErrors.text_for(ApiResult.failure(403, code, "", restriction)))
		return
	var character_name: String = config.character_name
	if character_name.is_empty():
		character_name = NameRules.bot_name(config.bot_seed)
	var realm_id: StringName = RealmCatalog.id_of_code(config.realm) \
			if RealmCatalog.is_realm_code(config.realm) else &""
	# --loadout is the character's starting template if it has to be created (docs/progression.md §2.5).
	var ensured: ApiResult = await flow.ensure_character(config.world_id, character_name, realm_id,
			StringName(config.loadout))
	if _quitting:
		return
	if not ensured.ok:
		_fail_account_result(ensured)
		return
	var character: Dictionary = ensured.data.get("character", {})
	var character_id: int = AccountFlow.parse_id(character.get("character_id"))
	_account_report = {"code": "", "status": 0, "message": "", "character_id": str(character_id),
			"created": bool(ensured.data.get("created", false))}
	var entered: ApiResult = await flow.enter(character_id, config)
	if _quitting:
		return
	if not entered.ok:
		_fail_account_result(entered)
		return
	config = entered.data["config"] as ClientConfig
	print("[Eldmark] Personaje %s (%s): billete para %s:%d en %d ms" % [config.display_name, character_id,
			config.address, config.port, Time.get_ticks_msec() - started_msec])
	_begin_session()


## The password from file [param path] (the first line, without the trailing newline); empty if it cannot be read.
static func read_password_file(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	var line: String = text.get_slice("\n", 0).trim_suffix("\r")
	return line


func _fail_account_result(result: ApiResult) -> void:
	_fail_account(result.code, result.status, PlatformErrors.text_for(result))


func _fail_account(code: String, status: int, text: String) -> void:
	_account_report["code"] = code
	_account_report["status"] = status
	_account_report["message"] = text
	_fail("Cuenta: %s (%s)" % [text, code])


# --- Session ----------------------------------------------------------------------------------

# Starts a session: transport, controller, entities node and network client, and the connection. In
# LOCAL mode, the local server is reused or launched first.
func _begin_session() -> void:
	_was_welcomed = false
	if _is_local():
		_prepare_local_server()
	_create_session_nodes()
	print("[Eldmark] Conectando con %s:%d como %s (%s)%s" % [config.address, config.port,
			config.display_name, NetProtocol.realm_display_name(config.realm),
			" [bot, semilla %d]" % config.bot_seed if _is_bot() else ""])
	_show_status("Conectando con %s:%d…" % [config.address, config.port])
	_start_client()


func _create_session_nodes() -> void:
	_transport = NetTransport.new()
	_transport.name = "NetTransport"
	add_child(_transport)
	_controller = LocalPlayerController.new()
	_controller.name = "LocalPlayerController"
	add_child(_controller)
	_entities = Node3D.new()
	_entities.name = "Entities"
	add_child(_entities)
	_client = NetClient.new()
	if not _account_report.is_empty():
		_client.report_extra = {"platform": _account_report}
	add_child(_client)
	_client.welcomed.connect(_on_welcomed)
	_client.rejected.connect(_on_rejected)
	_client.local_spawned.connect(_on_local_spawned)
	_client.disconnected.connect(_on_disconnected)
	_client.notice_received.connect(_on_notice)
	if _is_local():
		_client.connect_timeout_ms = LocalServerLauncher.CONNECT_TIMEOUT_MS


func _start_client() -> void:
	var error: Error = _client.start(config, _transport, _controller)
	if error != OK:
		_fail("No se pudo iniciar la conexión (%s)" % error_string(error))


# Removes the session's nodes (the client closes the transport on leaving the tree). It is not called
# from a signal of the client itself: it must be deferred.
func _free_session_nodes() -> void:
	for node: Node in [_client, _transport, _controller, _entities]:
		if is_instance_valid(node):
			if node.get_parent() == self:
				remove_child(node)
			node.free()
	_client = null
	_transport = null
	_controller = null
	_entities = null


# --- Local server -----------------------------------------------------------------------------

# LOCAL mode: reuses the server described by the lock file if its process is still alive and, if
# not, launches one.
func _prepare_local_server() -> void:
	var running_port: int = LocalServerLauncher.get_running_port(_effective_lock_path())
	if running_port > 0:
		config.port = running_port
		_launcher = null
		print("[Eldmark] Servidor local ya en marcha (puerto %d): se reutiliza" % running_port)
		return
	_launch_local_server()


# Lock file of the local server: that of --dev-lock-path and, if not given, [member lock_path].
func _effective_lock_path() -> String:
	return config.dev_lock_path if not config.dev_lock_path.is_empty() else lock_path


# Launches the local server and opens the connection retry window. Returns false if it could not
# launch it.
func _launch_local_server() -> bool:
	_launcher = LocalServerLauncher.new()
	var pid: int = _launcher.launch(config.port,
			LocalServerLauncher.forwarded_args(OS.get_cmdline_user_args()))
	if pid < 0:
		_launcher = null
		return false
	_local_deadline_msec = Time.get_ticks_msec() + LocalServerLauncher.CONNECT_RETRY_MS
	print("[Eldmark] Servidor local lanzado (pid %d, puerto %d, registro en %s)" % [pid,
			config.port, LocalServerLauncher.log_path_for(config.dev_lock_path)])
	return true


# true if a failed connection in LOCAL mode should be retried: there has been no response from the server yet and
# there is time left (or the server must be launched because the one in the lock file did not answer).
func _should_retry_local() -> bool:
	if not _is_local() or _was_welcomed:
		return false
	if _launcher == null:
		return true
	return _launcher.is_server_alive() and Time.get_ticks_msec() < _local_deadline_msec


# New session after a failed attempt to connect to the local server.
func _retry_local_connection() -> void:
	if _quitting or not is_instance_valid(_client):
		return
	if _launcher == null and not _launch_local_server():
		_fail("No se pudo lanzar el servidor local")
		return
	_free_session_nodes()
	_create_session_nodes()
	_start_client()


# --- Connection and loading -------------------------------------------------------------------

func _on_welcomed(welcome: NetMessages.Welcome) -> void:
	_was_welcomed = true
	_last_realm_counts = welcome.realm_counts.duplicate()
	_imbalanced_realm = NetProtocol.Realm.NONE
	_zone_id = welcome.zone_id
	var path: String = NetZones.scene_path(welcome.zone_id)
	if path.is_empty():
		_fail("El servidor usa una zona que este cliente no conoce: «%s»" % welcome.zone_id)
		_client.leave()
		return
	print("[Eldmark] Conectado. Zona del servidor: %s (%s)" % [welcome.zone_id, path])
	var error: Error = ResourceLoader.load_threaded_request(path, "PackedScene")
	if error != OK:
		_fail("No se pudo empezar a cargar la zona «%s» (%s)" % [welcome.zone_id,
				error_string(error)])
		_client.leave()
		return
	_loading_path = path
	_show_status("Cargando %s…" % welcome.zone_id)
	set_process(true)


# The zone is already loaded: it is added, we wait for its collisions to be ready and a notice is sent.
func _enter_zone(path: String) -> void:
	var packed: PackedScene = ResourceLoader.load_threaded_get(path) as PackedScene
	_world = packed.instantiate() as Node3D if packed != null else null
	if _world == null:
		_fail("No se pudo cargar la zona «%s»" % _zone_id)
		_client.leave()
		return
	add_child(_world)
	# The scene's fortresses (banners and gate) are found by FortressView in this zone.
	_client.get_fortress_view().set_zone(_world)
	_force_full_terrain_collision(_world)
	if _is_bot() and DisplayServer.get_name() == "headless":
		var zone_root: ZoneRoot = _world as ZoneRoot
		if zone_root != null:
			zone_root.strip_for_server()
	_show_status("Entrando en %s…" % _zone_id)
	for _i: int in WARMUP_PHYSICS_FRAMES:
		await get_tree().physics_frame
	if not is_instance_valid(_client) or _client.get_state() != NetClient.State.WELCOMED:
		return
	print("[Eldmark] Zona '%s' lista" % _zone_id)
	_client.notify_zone_ready(_entities)


# Terrain3D with full collision, the same one the server fixes (docs/networking.md, 1.3 and 19): the
# dynamic mode depends on the camera and could change the last bit of Jolt's queries. It is
# accessed by name so as not to depend on the extension when loading the script.
func _force_full_terrain_collision(root: Node) -> void:
	if not ClassDB.class_exists(&"Terrain3D"):
		return
	var full_game: int = 3
	if ClassDB.class_exists(&"Terrain3DCollision"):
		full_game = ClassDB.class_get_integer_constant(&"Terrain3DCollision", &"FULL_GAME")
	for node: Node in root.find_children("*", "Terrain3D", true, false):
		if int(node.get(&"collision_mode")) != full_game:
			node.set(&"collision_mode", full_game)


func _on_rejected(result: int, text: String) -> void:
	_was_welcomed = true
	# Without text from the server, the one this client knows for the reason (also that of REJECT 9).
	if text.is_empty():
		text = NetProtocol.result_text(result)
	# A realm rejected for imbalance is remembered so as to offer another when returning to the choice.
	_imbalanced_realm = config.realm if result == NetProtocol.Result.IMBALANCE else NetProtocol.Realm.NONE
	push_warning("[Eldmark] Conexión rechazada (%d): %s" % [result, text])
	_fail("Conexión rechazada: %s" % text)


func _on_disconnected(text: String) -> void:
	if _quitting:
		return
	if _finishing:
		print("[Eldmark] Sesión cerrada: %s" % text)
		_quit(0)
		return
	if _should_retry_local():
		print("[Eldmark] %s; se reintenta (servidor local)" % text)
		_retry_local_connection.call_deferred()
		return
	if _is_local() and not _was_welcomed:
		text = "No se pudo conectar con el servidor local. Revisa %s" \
				% ProjectSettings.globalize_path(LocalServerLauncher.LOG_PATH)
	if _client.get_last_notice_text().is_empty():
		push_warning("[Eldmark] Desconectado: %s" % text)
	else:
		print("[Eldmark] Desconectado: %s" % text)
	_fail(text)


func _on_notice(code: int, text: String) -> void:
	print("[Eldmark] Aviso del servidor (%d): %s" % [code, text])


# --- The local character spawns ---------------------------------------------------------------

func _on_local_spawned(character: PlayerCharacter) -> void:
	_hide_overlay()
	print("[Eldmark] Aparición en %s (net_id %d, tick %d, RTT %d ticks)" % [
		character.global_position, _client.get_net_id(), _client.get_spawn_tick(),
		_client.get_rtt_ticks(),
	])
	if _is_bot():
		_brain = ClientBotBrains.make(_client, config, character.global_position, BOT_RADIUS)
		_controller.set_bot(_brain)
		if config.bot_scenario == ClientConfig.BOT_SCENARIO_PROGRESS and _scenario == null:
			# The scenario does not walk: the bot stands still (equipping requires no action and being out of combat).
			_brain.set_idle_from(_client.get_prediction().get_predicted_tick() + 1)
			_idle_set = true
			_scenario = BotProgressScenario.new(_client)
			_scenario.phase_completed.connect(_on_scenario_phase)
			print("[Eldmark] Escenario %s: empieza" % BotProgressScenario.NAME)
		return

	# Visual look: the animated humanoid replaces the provisional capsule, with the appearance from the own SPAWN (that
	# of its people by default if invalid or the zone has no progress; docs/progression.md §7.3).
	var visual: HumanoidVisual = HumanoidVisual.install_replacing_placeholder(character)
	if visual == null:
		push_warning("[Eldmark] Sin visual del humanoide: se usa la cápsula provisional")
	else:
		AppearanceApplier.apply_bytes(visual, _client.get_own_appearance(), config.realm)

	# Over-the-shoulder action camera, facing where the character faces.
	_camera_rig = _instantiate_scene(CAMERA_RIG_SCENE_PATH, CameraRig) as CameraRig
	if _camera_rig != null:
		add_child(_camera_rig)
		_camera_rig.set_target(character.get_camera_target(), character)
		_camera_rig.set_hide_when_close(character.get_node_or_null(^"Visual") as Node3D)
		_camera_rig.set_look(character.yaw, 0.0)
	_controller.setup(character, _camera_rig)

	_hud = _instantiate_scene(HUD_SCENE_PATH, HUD) as HUD
	if _hud != null:
		add_child(_hud)
		_hud.bind(character, _camera_rig)
		_hud.bind_net(_client, _world)
		# On the network, the HUD's debug panel starts hidden: F3 toggles it together with the network one.
		_hud.set_debug_visible(false)

	# Network debugging (F3 and F4). It does not mark F3 as handled: the HUD receives it too.
	_net_debug = _instantiate_scene(NET_DEBUG_SCENE_PATH, NetDebugOverlay) as NetDebugOverlay
	if _net_debug != null:
		add_child(_net_debug)
		_net_debug.bind(_client)


# --- Realm choice -----------------------------------------------------------------------------

# true if someone is there who can choose: it is not a bot and there is a screen (or it is a test).
func _is_interactive() -> bool:
	return not _is_bot() and (force_interactive or DisplayServer.get_name() != "headless")


# Shows RealmSelect with the notice [param notice] (empty = none). Without a network session: whatever there was
# is removed first.
func _show_realm_select(notice: String) -> void:
	_hide_overlay()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _realm_select == null:
		var scene: PackedScene = load(REALM_SELECT_SCENE_PATH) as PackedScene
		_realm_select = scene.instantiate() as RealmSelect if scene != null else null
		if _realm_select == null:
			push_error("[Eldmark] No se pudo cargar la escena %s" % REALM_SELECT_SCENE_PATH)
			_show_message(notice if not notice.is_empty() else "No se pudo mostrar la elección de reino")
			return
		_realm_layer = CanvasLayer.new()
		_realm_layer.name = "RealmSelectLayer"
		_realm_layer.layer = REALM_SELECT_LAYER
		add_child(_realm_layer)
		_realm_layer.add_child(_realm_select)
		_realm_select.realm_chosen.connect(_on_realm_chosen)
		_realm_select.quit_requested.connect(_on_quit_requested)
	# The realm that can be chosen depends on the zone; before connecting only the one requested with --zone
	# is known or, failing that, the default one (the server rejects whatever it does not admit).
	var zone_id: String = NetZones.parse_zone_arg(OS.get_cmdline_user_args())
	if zone_id.is_empty():
		zone_id = NetZones.default_zone_id()
	_realm_select.setup(_address_text(), config.display_name, NetZones.allowed_realms(zone_id))
	_realm_select.set_address_editable(not _is_local())
	_realm_select.set_realm_counts(_last_realm_counts)
	_realm_select.set_rejected_realm(_imbalanced_realm)
	_realm_select.set_selected_template(config.get_loadout_template_id())
	if _imbalanced_realm == NetProtocol.Realm.NONE:
		_realm_select.select_realm(config.realm)
	else:
		# Rejected for imbalance: the realm with the fewest players is offered (if known).
		_realm_select.select_realm(_realm_select.get_recommended_realm())
	_realm_select.set_notice(notice)
	_realm_layer.visible = true
	_returning_to_menu = false


# Address from config as it is typed in the field: "host" or "host:port" (IPv6 in brackets).
func _address_text() -> String:
	var host: String = "[%s]" % config.address if config.address.contains(":") else config.address
	return host if config.port == NetProtocol.DEFAULT_PORT else "%s:%d" % [host, config.port]


func _on_realm_chosen(realm: int, address: String, display_name: String) -> void:
	if not _is_local():
		var parsed: Dictionary = ClientConfig.parse_address(address)
		if not String(parsed["error"]).is_empty():
			_realm_select.set_notice(String(parsed["error"]))
			return
		config.address = parsed["host"]
		config.port = int(parsed["port"]) if int(parsed["port"]) > 0 else NetProtocol.DEFAULT_PORT
	config.realm = realm
	config.display_name = display_name
	# Choosing a realm means entering without an account: never with an old ticket.
	config.ticket = PackedByteArray()
	config.character_id = 0
	# The chosen template goes out in a LOADOUT_SELECT as soon as the WELCOME arrives (NetClient); the default
	# one does not need to be requested.
	var template_id: int = _realm_select.get_selected_template()
	var template: EquipmentTemplate = CombatCatalog.template(template_id)
	config.loadout = String(template.id) \
			if template != null and template_id != CombatCatalog.default_template_id() else ""
	_realm_layer.visible = false
	_begin_session()


func _on_quit_requested() -> void:
	if quit_hook.is_valid():
		quit_hook.call(0)
		return
	get_tree().quit(0)


# Returns to the realm choice after a failure: removes the zone, the camera, the HUD and the network session.
func _return_to_realm_select(notice: String) -> void:
	if _quitting:
		return
	_loading_path = ""
	set_process(false)
	for node: Node in [_net_debug, _hud, _camera_rig, _world]:
		if is_instance_valid(node):
			node.get_parent().remove_child(node)
			node.free()
	_net_debug = null
	_hud = null
	_camera_rig = null
	_world = null
	_free_session_nodes()
	_brain = null
	_idle_set = false
	_bot_respawn_request_tick = -BOT_RESPAWN_RETRY_TICKS
	_finishing = false
	_leave_wait_ticks = 0
	_was_welcomed = false
	_show_realm_select(notice)


# --- Shutdown ---------------------------------------------------------------------------------

# Normal end of a client with --quit-after-ticks: report, leaving the zone and shutdown.
func _finish_session() -> void:
	print("[Eldmark] Fin de la sesión: %d ticks locales (--quit-after-ticks)"
			% _client.get_local_tick())
	if _client.get_state() != NetClient.State.IN_WORLD:
		# Time ran out without entering the zone: that is a failure, not a normal shutdown.
		_fail("No se llegó a entrar en la zona (estado: %s)"
				% NetClient.State.keys()[_client.get_state()])
		return
	_finishing = true
	_leave_wait_ticks = 0
	_write_report()
	_client.leave()


# Connection or loading failure. In bot mode (or without a screen) the report is written and it closes with
# code 1; with a screen it returns to the realm choice with the reason as a notice.
func _fail(text: String) -> void:
	printerr("[Eldmark] %s" % text)
	if not _is_interactive():
		_exit_code = 1
		_write_report()
		_quit(1)
		return
	if _returning_to_menu:
		return
	_returning_to_menu = true
	if config.from_front:
		# The session came from character selection: it returns there with the reason (the account continues).
		_return_to_front.call_deferred(text)
		return
	# It is almost always called from a client signal, which cannot be freed at that moment.
	_return_to_realm_select.call_deferred(text)


# Returns to FrontMain (character selection) with [param notice] as a notice.
func _return_to_front(notice: String) -> void:
	if _quitting:
		return
	_loading_path = ""
	set_process(false)
	FrontMain.return_notice = notice
	if front_hook.is_valid():
		front_hook.call(notice)
		return
	get_tree().change_scene_to_file(FRONT_MAIN_SCENE_PATH)


func _quit(code: int) -> void:
	if _quitting:
		return
	_quitting = true
	if code != 0:
		_exit_code = code
	_write_report()
	if quit_hook.is_valid():
		quit_hook.call(code)
		return
	get_tree().quit(code)


# A scenario step finished: to the log and the report (rewritten whole, without waiting for it to be written out: the final one comes out
# the same on exit).
func _on_scenario_phase(phase: String) -> void:
	print("[Eldmark] Escenario %s: %s" % [BotProgressScenario.NAME, phase])
	if config.report_path.is_empty() or _client == null or _report_written:
		return
	_client.report_extra["scenario"] = _scenario.to_report()
	var error: Error = _client.write_report(config.report_path)
	if error != OK:
		push_warning("[Eldmark] No se pudo escribir el informe '%s' (error %d)" % [config.report_path, error])


func _write_report() -> void:
	if _report_written or config.report_path.is_empty():
		return
	if _scenario != null and _client != null:
		_client.report_extra["scenario"] = _scenario.to_report()
	if _client == null:
		# The bot with an account that never got to connect: only the account part.
		if not _account_report.is_empty():
			_report_written = true
			_write_account_report()
		return
	_report_written = true
	var error: Error = _client.write_report(config.report_path)
	if error == OK:
		print("[Eldmark] Informe escrito en %s" % config.report_path)
	else:
		push_warning("[Eldmark] No se pudo escribir el informe '%s' (error %d)"
				% [config.report_path, error])


# Report of a bot with an account that never got to connect to the zone.
func _write_account_report() -> void:
	var report: Dictionary = {
		"version": 1, "name": config.character_name, "mode": ClientConfig.Mode.keys()[config.mode],
		"state": "ACCOUNT", "rejected": false, "platform": _account_report,
	}
	var directory: String = config.report_path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var file: FileAccess = FileAccess.open(config.report_path, FileAccess.WRITE)
	if file == null:
		push_warning("[Eldmark] No se pudo escribir el informe '%s'" % config.report_path)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("[Eldmark] Informe escrito en %s" % config.report_path)


# --- Loading screen and notices ---------------------------------------------------------------

func _create_overlay() -> void:
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "Overlay"
	_overlay_layer.layer = 100
	add_child(_overlay_layer)
	var background := ColorRect.new()
	background.name = "Fondo"
	background.color = Color(0.05, 0.05, 0.07, 1.0)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_layer.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.name = "Centro"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_layer.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(OVERLAY_WIDTH, 0.0)
	column.add_theme_constant_override(&"separation", 24)
	center.add_child(column)
	_overlay_label = Label.new()
	_overlay_label.name = "Mensaje"
	_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_overlay_label.add_theme_font_size_override(&"font_size", 28)
	column.add_child(_overlay_label)
	_overlay_button = Button.new()
	_overlay_button.name = "Salir"
	_overlay_button.text = "Salir"
	_overlay_button.visible = false
	_overlay_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_overlay_button.custom_minimum_size = Vector2(160.0, 44.0)
	_overlay_button.pressed.connect(func() -> void: get_tree().quit(_exit_code))
	column.add_child(_overlay_button)


func _show_status(text: String) -> void:
	if _overlay_label == null:
		return
	_overlay_layer.visible = true
	_overlay_label.text = text
	_overlay_button.visible = false


func _show_message(text: String) -> void:
	_show_status(text)
	if _overlay_button != null:
		_overlay_button.visible = true


func _hide_overlay() -> void:
	if _overlay_layer != null:
		_overlay_layer.visible = false


## Loads and instantiates a scene. If [param expected] is not null, the root must be of that type; if
## it is not, it is freed. Returns null (and logs the error) on failure.
func _instantiate_scene(path: String, expected: Script = null) -> Node:
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		push_error("[Eldmark] No se pudo cargar la escena %s" % path)
		return null
	var instance: Node = scene.instantiate()
	if expected != null and not is_instance_of(instance, expected):
		push_error("[Eldmark] La raíz de %s no es un %s" % [path, expected.get_global_name()])
		instance.free()
		return null
	return instance
