class_name OnlineMain
extends Node
## Raíz del cliente en red (docs/red.md, secciones 1.2, 3 y 17.5). El sandbox sin red sigue siendo
## [ClientMain]; esta escena es la de [code]--connect[/code] y [code]--bot[/code].
## [br][br]
## [code]boot.gd[/code] rellena [member config] con [method ClientConfig.from_args] y cambia a
## [code]scenes/client/online_main.tscn[/code]. El flujo:
## [codeblock]
## NetTransport + LocalPlayerController + NetClient.start()    "Conectando…"
## welcomed          carga la zona del WELCOME en un hilo (ResourceLoader.load_threaded_request),
##                   con la pantalla «Cargando…»; al terminar, la añade, espera unos pasos de
##                   física a que sus colisiones estén en el espacio de física (como el servidor)
##                   y llama a NetClient.notify_zone_ready()
## local_spawned     cámara, HUD y visual animado (en modo BOT, solo controller.set_bot())
## rejected /        aviso en español (en modo BOT: informe y salida con código 1)
## disconnected
## [/codeblock]
## [br][b]Ajustes.[/b] [code]multiplayer_poll = false[/code] (cada tick lo sondea [NetClient]) y, en
## headless, [code]Engine.max_fps = 120[/code] (sección 1.3).
## [br][br]
## [b]Modo BOT[/b]: sin cámara ni HUD. La entrada sale de un [BotBrain] (patrón de paseo, semilla
## [member ClientConfig.bot_seed], alrededor de su punto de aparición) y, en headless, la zona se
## carga sin lo visual ([method ZoneRoot.strip_for_server]), igual que en el servidor. Con
## [code]--quit-after-ticks=N[/code], tras N ticks de física locales (desde que arranca la sesión:
## cuentan la conexión y la carga) escribe el informe ([code]--report[/code]), sale de la zona con
## CLIENT_LEAVE y cierra con código 0; con 1 si fue rechazado o se desconectó antes. Los últimos
## [constant IDLE_TAIL_TICKS] ticks (un cuarto como mucho) el bot se queda quieto, para que las
## pruebas de convergencia comparen estados estacionarios.
## [br][br]
## [b]Elección de reino.[/b] TODO(TEC-45): aquí irá [code]RealmSelect[/code]. Mientras no exista, si
## falta [code]--realm[/code] se usa Vardheim y se avisa.
## [br][br]
## [b]Modo LOCAL[/b] ([code]--local[/code], sección 1.4): antes de conectar, si
## [code]user://dev_server.json[/code] describe un servidor vivo se usa su puerto; si no, se lanza uno
## ([LocalServerLauncher]) y se reintenta conectar durante [constant LocalServerLauncher.CONNECT_RETRY_MS]
## ms con un tiempo de espera corto de ENet (cada intento es una sesión nueva: [NetClient],
## transporte y controlador). Si el servidor que se creía vivo no contesta, se lanza uno entonces. El
## cliente nunca cierra el servidor: se apaga solo tras [constant LocalServerLauncher.IDLE_QUIT_SECONDS]
## s sin jugadores.

const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const WINDOW_TITLE: String = "Eldmark"
## Fotogramas por segundo máximos en headless (sección 1.3).
const MAX_FPS: int = 120
## Pasos de física que se esperan tras añadir la zona antes de avisar de que está lista: los
## cuerpos de colisión (el Terrain3D, sobre todo) entran en el espacio de física en los primeros
## pasos, y el servidor espera lo mismo antes de aceptar jugadores.
const WARMUP_PHYSICS_FRAMES: int = 3
## Reino por defecto mientras no hay RealmSelect.
const DEFAULT_REALM: int = NetProtocol.Realm.VARDHEIM
## Ticks como mucho que un bot se queda quieto antes de salir.
const IDLE_TAIL_TICKS: int = 90
## Radio (m) por el que pasea un bot alrededor de su punto de aparición.
const BOT_RADIUS: float = 30.0
## Ticks que se espera, tras salir de la zona, a que se cierre la conexión antes de cerrar.
const LEAVE_WAIT_TICKS: int = 30
## Ancho (píxeles de la ventana base) de la columna de texto de la pantalla de carga.
const OVERLAY_WIDTH: float = 900.0

## Configuración del cliente. La rellena [code]boot.gd[/code]; si es null al arrancar, se lee de los
## argumentos de usuario.
static var config: ClientConfig
## Solo para pruebas: si es válido, el cierre llama a este gancho con el código de salida en lugar de
## cerrar el proceso.
static var quit_hook: Callable = Callable()
## Solo para pruebas: archivo de bloqueo del servidor local que se consulta en modo LOCAL (así una
## prueba no toca el [constant LocalServerLauncher.LOCK_PATH] real).
static var lock_path: String = LocalServerLauncher.LOCK_PATH

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
var _brain: BotBrain = null
var _loading_path: String = ""
var _zone_id: String = ""
var _overlay_layer: CanvasLayer = null
var _overlay_label: Label = null
var _overlay_button: Button = null
var _idle_set: bool = false
var _finishing: bool = false
var _leave_wait_ticks: int = 0
var _quitting: bool = false
var _report_written: bool = false
var _exit_code: int = 0


func _ready() -> void:
	if config == null:
		config = ClientConfig.from_args(OS.get_cmdline_user_args())
	_apply_settings()
	for warning: String in config.warnings:
		push_warning("[Eldmark] %s" % warning)
	if config.realm == NetProtocol.Realm.NONE:
		# TODO(TEC-45): aquí se mostrará RealmSelect (tres botones, dirección y «Entrar»).
		push_warning("[Eldmark] Falta --realm=<reino>: se entra como %s"
				% NetProtocol.realm_display_name(DEFAULT_REALM))
		config.realm = DEFAULT_REALM
	set_process(false)
	set_physics_process(config.quit_after_ticks > 0)
	if not _is_bot():
		InputBindings.ensure_defaults()
		_create_overlay()

	_begin_session()


## Cliente de red.
func get_client() -> NetClient:
	return _client


## Zona cargada (null hasta que termina la carga).
func get_world() -> Node3D:
	return _world


## Cámara de acción (null en modo bot o antes de aparecer).
func get_camera_rig() -> CameraRig:
	return _camera_rig


## HUD (null en modo bot o antes de aparecer).
func get_hud() -> HUD:
	return _hud


## Cerebro del bot (null si no es un bot o aún no ha aparecido).
func get_bot_brain() -> BotBrain:
	return _brain


## Código con el que se cerrará (o se cerró) el proceso.
func get_exit_code() -> int:
	return _exit_code


# Carga de la zona en un hilo: se sondea el estado en cada fotograma.
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
	var quit_after: int = config.quit_after_ticks
	if quit_after <= 0:
		return
	if _brain != null and not _idle_set \
			and local_tick >= quit_after - clampi(quit_after / 4, 0, IDLE_TAIL_TICKS):
		_idle_set = true
		_brain.set_idle_from(_client.get_prediction().get_predicted_tick() + 1)
	if local_tick >= quit_after:
		_finish_session()


# --- Arranque ---------------------------------------------------------------------------------

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


# --- Sesión -----------------------------------------------------------------------------------

# Empieza una sesión: transporte, controlador, nodo de entidades y cliente de red, y la conexión. En
# modo LOCAL, antes se reutiliza o se lanza el servidor local.
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


# Quita los nodos de la sesión (el cliente cierra el transporte al salir del árbol). No se llama
# desde una señal del propio cliente: hay que diferirlo.
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


# --- Servidor local ---------------------------------------------------------------------------

# Modo LOCAL: reutiliza el servidor que describe el archivo de bloqueo si su proceso sigue vivo y, si
# no, lanza uno.
func _prepare_local_server() -> void:
	var running_port: int = LocalServerLauncher.get_running_port(lock_path)
	if running_port > 0:
		config.port = running_port
		_launcher = null
		print("[Eldmark] Servidor local ya en marcha (puerto %d): se reutiliza" % running_port)
		return
	_launch_local_server()


# Lanza el servidor local y abre la ventana de reintentos de conexión. Devuelve false si no pudo
# lanzarlo.
func _launch_local_server() -> bool:
	_launcher = LocalServerLauncher.new()
	var pid: int = _launcher.launch(config.port,
			LocalServerLauncher.forwarded_args(OS.get_cmdline_user_args()))
	if pid < 0:
		_launcher = null
		return false
	_local_deadline_msec = Time.get_ticks_msec() + LocalServerLauncher.CONNECT_RETRY_MS
	print("[Eldmark] Servidor local lanzado (pid %d, puerto %d, registro en %s)" % [pid,
			config.port, ProjectSettings.globalize_path(LocalServerLauncher.LOG_PATH)])
	return true


# true si una conexión fallida en modo LOCAL se debe reintentar: aún no hubo respuesta del servidor y
# queda tiempo (o hay que lanzar el servidor porque el del archivo de bloqueo no contestó).
func _should_retry_local() -> bool:
	if not _is_local() or _was_welcomed:
		return false
	if _launcher == null:
		return true
	return _launcher.is_server_alive() and Time.get_ticks_msec() < _local_deadline_msec


# Nueva sesión tras un intento fallido de conectar con el servidor local.
func _retry_local_connection() -> void:
	if _quitting or not is_instance_valid(_client):
		return
	if _launcher == null and not _launch_local_server():
		_fail("No se pudo lanzar el servidor local")
		return
	_free_session_nodes()
	_create_session_nodes()
	_start_client()


# --- Conexión y carga -------------------------------------------------------------------------

func _on_welcomed(welcome: NetMessages.Welcome) -> void:
	_was_welcomed = true
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


# La zona ya está cargada: se añade, se espera a que sus colisiones estén listas y se avisa.
func _enter_zone(path: String) -> void:
	var packed: PackedScene = ResourceLoader.load_threaded_get(path) as PackedScene
	_world = packed.instantiate() as Node3D if packed != null else null
	if _world == null:
		_fail("No se pudo cargar la zona «%s»" % _zone_id)
		_client.leave()
		return
	add_child(_world)
	_force_full_terrain_collision(_world)
	if _is_bot() and DisplayServer.get_name() == "headless":
		var zone_root: ZoneRoot = _world as ZoneRoot
		if zone_root != null:
			zone_root.strip_for_server()
	_show_status("Entrando en %s…" % _zone_id)
	for _i: int in WARMUP_PHYSICS_FRAMES:
		await get_tree().physics_frame
	if _client.get_state() != NetClient.State.WELCOMED:
		return
	print("[Eldmark] Zona '%s' lista" % _zone_id)
	_client.notify_zone_ready(_entities)


# Terrain3D con la colisión completa, la misma que fija el servidor (docs/red.md, 1.3 y 19): el
# modo dinámico depende de la cámara y podría cambiar el último bit de las consultas de Jolt. Se
# accede por nombre para no depender de la extensión al cargar el script.
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


# --- El personaje local aparece ---------------------------------------------------------------

func _on_local_spawned(character: PlayerCharacter) -> void:
	_hide_overlay()
	print("[Eldmark] Aparición en %s (net_id %d, tick %d, RTT %d ticks)" % [
		character.global_position, _client.get_net_id(), _client.get_spawn_tick(),
		_client.get_rtt_ticks(),
	])
	if _is_bot():
		_brain = BotBrain.new(config.bot_seed, BotBrain.Pattern.WANDER, character.global_position,
				BOT_RADIUS)
		_controller.set_bot(_brain)
		return

	# Aspecto visual: el humanoide animado sustituye a la cápsula provisional.
	if HumanoidVisual.install_replacing_placeholder(character) == null:
		push_warning("[Eldmark] Sin visual del humanoide: se usa la cápsula provisional")

	# Cámara de acción por encima del hombro, mirando hacia donde mira el personaje.
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


# --- Cierre -----------------------------------------------------------------------------------

# Fin normal de un cliente con --quit-after-ticks: informe, salida de la zona y cierre.
func _finish_session() -> void:
	print("[Eldmark] Fin de la sesión: %d ticks locales (--quit-after-ticks)"
			% _client.get_local_tick())
	if _client.get_state() != NetClient.State.IN_WORLD:
		# Se acabó el tiempo sin llegar a entrar en la zona: eso es un fallo, no un cierre normal.
		_fail("No se llegó a entrar en la zona (estado: %s)"
				% NetClient.State.keys()[_client.get_state()])
		return
	_finishing = true
	_leave_wait_ticks = 0
	_write_report()
	_client.leave()


# Fallo de conexión o carga. En modo bot (o sin pantalla) se escribe el informe y se cierra con
# código 1; con pantalla se muestra el aviso con un botón para salir.
# TODO(TEC-45): volver a RealmSelect en lugar de quedarse en este aviso.
func _fail(text: String) -> void:
	printerr("[Eldmark] %s" % text)
	_exit_code = 1
	if _is_bot() or DisplayServer.get_name() == "headless":
		_write_report()
		_quit(1)
		return
	if _camera_rig != null:
		_camera_rig.process_mode = Node.PROCESS_MODE_DISABLED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_message(text)


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


func _write_report() -> void:
	if _report_written or config.report_path.is_empty() or _client == null:
		return
	_report_written = true
	var error: Error = _client.write_report(config.report_path)
	if error == OK:
		print("[Eldmark] Informe escrito en %s" % config.report_path)
	else:
		push_warning("[Eldmark] No se pudo escribir el informe '%s' (error %d)"
				% [config.report_path, error])


# --- Pantalla de carga y avisos ---------------------------------------------------------------

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


## Carga e instancia una escena. Si [param expected] no es null, la raíz debe ser de ese tipo; si
## no lo es, se libera. Devuelve null (y registra el error) si falla.
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
