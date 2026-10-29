class_name ServerMain
extends Node
## Raíz del servidor dedicado de una zona (docs/red.md, secciones 1.2 a 1.4).
## [br][br]
## [code]boot.gd[/code] rellena [member config] con [method ServerConfig.from_args] cuando se
## arranca con [code]--server[/code] y cambia a [code]scenes/server/server_main.tscn[/code]. Aquí:
## [br]- Se aplican los ajustes de la sección 1.3: [code]Engine.max_fps = 120[/code] (en headless, el
## bucle principal duerme entre iteraciones y la hora de cada tick variaba unos 10 ms; con 120 fps
## baja a ~0,5 ms), sin interpolación de física (no se dibuja) y sin sondeo automático del
## multijugador ([method NetTransport.poll] se llama a mano en cada tick).
## [br]- Se carga la escena de la zona ([method NetZones.scene_path]); si su raíz es un
## [ZoneRoot] se le quita lo visual ([method ZoneRoot.strip_for_server]) y el [code]Terrain3D[/code]
## queda con la colisión completa y sin proceso propio, como fija
## [code]tests/test_terrain3d_headless.gd[/code].
## [br]- Se crea el [NetTransport] (con [member ServerConfig.net_sim_spec]) y el [ZoneServer], que
## abre el puerto, y los jugadores falsos de [code]--fake-players=N[/code].
## [br]- Con [code]--dev-lock[/code] se escribe [code]user://dev_server.json[/code]
## ([code]{pid, port}[/code]) para que [code]--local[/code] reutilice este servidor, y se borra al
## cerrar.
## [br]- Se cierra con [code]--quit-after-ticks[/code] o [code]--idle-quit[/code]: NOTICE de cierre
## a los clientes, [method ZoneServer.stop], informe si hay [code]--report[/code] y salida.
## [br][br]
## El código de salida es 0 en un cierre normal y 1 si no puede arrancar (zona desconocida, puerto
## ocupado...).

## Archivo de bloqueo de [code]--dev-lock[/code].
const DEV_LOCK_PATH: String = "user://dev_server.json"
## Fotogramas por segundo máximos del servidor (sección 1.3).
const MAX_FPS: int = 120
## Pasos de física que se esperan tras cargar la zona antes de abrir el puerto y crear a los
## jugadores falsos: los cuerpos de colisión (el Terrain3D, sobre todo) entran en el espacio de
## física en los primeros pasos.
const WARMUP_PHYSICS_FRAMES: int = 3
## Pasos de física como mucho que se espera, al cerrar, a que los clientes se vayan.
const SHUTDOWN_MAX_FRAMES: int = 90
## Semilla del primer jugador falso; cada uno suma su índice.
const FAKE_SEED_BASE: int = 7000
## Radio (m) por el que pasea cada jugador falso alrededor de su punto de aparición.
const FAKE_RADIUS: float = 25.0
## Patrones de los jugadores falsos, repartidos en rueda.
const FAKE_PATTERNS: Array[BotBrain.Pattern] = [
	BotBrain.Pattern.WANDER, BotBrain.Pattern.WANDER, BotBrain.Pattern.JUMPY,
	BotBrain.Pattern.CIRCLE,
]
## Texto del NOTICE de cierre.
const SHUTDOWN_TEXT: String = "El servidor se está cerrando"

## Configuración del servidor. La rellena [code]boot.gd[/code]; si es null al arrancar, se lee de
## los argumentos de usuario.
static var config: ServerConfig

var _world: Node3D
var _transport: NetTransport
var _zone_server: ZoneServer
var _idle_ticks: int = 0
var _shutting_down: bool = false
var _lock_written: bool = false


func _ready() -> void:
	if config == null:
		config = ServerConfig.from_args(OS.get_cmdline_user_args())
	_apply_headless_settings()

	var scene_path: String = NetZones.scene_path(config.zone_id)
	if scene_path.is_empty():
		push_error("[Eldmark] Zona desconocida: '%s' (hay: %s)" % [config.zone_id,
				", ".join(Zones.get_zone_ids())])
		get_tree().quit(1)
		return
	print("[Eldmark] Servidor de zona: arrancando la zona '%s'" % config.zone_id)
	var packed: PackedScene = load(scene_path) as PackedScene
	_world = packed.instantiate() as Node3D if packed != null else null
	if _world == null:
		push_error("[Eldmark] No se pudo cargar la zona '%s' (%s)" % [config.zone_id, scene_path])
		get_tree().quit(1)
		return
	add_child(_world)
	var zone_root: ZoneRoot = _world as ZoneRoot
	if zone_root != null:
		var removed: int = zone_root.strip_for_server()
		print("[Eldmark] Zona '%s' cargada (%s): %d nodos solo visuales quitados"
				% [config.zone_id, scene_path, removed])
	else:
		print("[Eldmark] Zona '%s' cargada (%s)" % [config.zone_id, scene_path])
	_prepare_terrain(_world)

	# Los cuerpos de colisión entran en el espacio de física en los primeros pasos.
	for _i: int in WARMUP_PHYSICS_FRAMES:
		await get_tree().physics_frame

	_transport = NetTransport.new()
	_transport.name = "NetTransport"
	_transport.set_net_sim_spec(config.net_sim_spec)
	add_child(_transport)
	_zone_server = ZoneServer.new()
	_zone_server.name = "ZoneServer"
	add_child(_zone_server)
	var error: Error = _zone_server.start(config, _world, _transport, DevAuthProvider.new())
	if error != OK:
		push_error("[Eldmark] No se pudo abrir el puerto UDP %d (%s)" % [config.port,
				error_string(error)])
		get_tree().quit(1)
		return
	_zone_server.tick_finished.connect(_on_tick_finished)
	print("[Eldmark] Servidor de la zona '%s' escuchando en el puerto UDP %d (hasta %d jugadores, "
			% [config.zone_id, config.port, config.max_players]
			+ "%d ticks/s, huella de la simulación 0x%08X)"
			% [Engine.physics_ticks_per_second, _zone_server.get_sim_hash()])
	if not config.net_sim_spec.is_empty():
		print("[Eldmark] Simulador de red: %s" % config.net_sim_spec)
	if config.debug_commands:
		print("[Eldmark] Comandos de depuración activados (--debug-commands)")

	_spawn_fake_players()
	if config.dev_lock:
		var lock_error: Error = write_dev_lock(DEV_LOCK_PATH, OS.get_process_id(), config.port)
		if lock_error == OK:
			_lock_written = true
			print("[Eldmark] Archivo de bloqueo escrito: %s" % DEV_LOCK_PATH)
		else:
			push_warning("[Eldmark] No se pudo escribir %s (error %d)" % [DEV_LOCK_PATH,
					lock_error])


func _exit_tree() -> void:
	_remove_lock()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _zone_server != null and is_instance_valid(_zone_server):
			_zone_server.stop(SHUTDOWN_TEXT)
		_remove_lock()


# --- Lock de desarrollo -----------------------------------------------------------------------

## Escribe en [param path] el archivo de bloqueo [code]{"pid": …, "port": …}[/code] que lee
## [code]--local[/code] para reutilizar un servidor ya en marcha.
static func write_dev_lock(path: String, pid: int, port: int) -> Error:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({"pid": pid, "port": port}))
	file.close()
	return OK


## Borra el archivo de bloqueo de [param path] si es de [param pid] (no el de otro servidor).
## Devuelve true si lo ha borrado.
static func remove_dev_lock(path: String, pid: int) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) == OK and json.data is Dictionary:
		var data: Dictionary = json.data
		if int(data.get("pid", pid)) != pid:
			return false
	return DirAccess.remove_absolute(path) == OK


func _remove_lock() -> void:
	if not _lock_written:
		return
	_lock_written = false
	if remove_dev_lock(DEV_LOCK_PATH, OS.get_process_id()):
		print("[Eldmark] Archivo de bloqueo borrado: %s" % DEV_LOCK_PATH)


# --- Arranque ---------------------------------------------------------------------------------

# Ajustes de la sección 1.3.
func _apply_headless_settings() -> void:
	Engine.max_fps = MAX_FPS
	var tree: SceneTree = get_tree()
	tree.physics_interpolation = false
	tree.multiplayer_poll = false


# Terrain3D como fija tests/test_terrain3d_headless.gd: colisión completa (la misma que usa el
# cliente, por el determinismo) y sin proceso propio, porque sin cámara su primer
# _physics_process registra un error. Se accede por nombre para no depender de la extensión al
# cargar el script.
func _prepare_terrain(root: Node) -> void:
	if not ClassDB.class_exists(&"Terrain3D"):
		return
	var full_game: int = 3
	if ClassDB.class_exists(&"Terrain3DCollision"):
		full_game = ClassDB.class_get_integer_constant(&"Terrain3DCollision", &"FULL_GAME")
	for node: Node in root.find_children("*", "Terrain3D", true, false):
		node.set_physics_process(false)
		if int(node.get(&"collision_mode")) != full_game:
			node.set(&"collision_mode", full_game)


# Jugadores falsos de --fake-players=N: reinos con puntos de aparición en la zona, en rueda;
# patrones en rueda; semillas distintas; cada uno pasea alrededor del primer punto de su reino.
func _spawn_fake_players() -> void:
	if config.fake_players <= 0:
		return
	var realms: Array[int] = _fake_player_realms()
	var created: int = 0
	for i: int in config.fake_players:
		var realm: int = realms[i % realms.size()]
		var brain := BotBrain.new(FAKE_SEED_BASE + i, FAKE_PATTERNS[i % FAKE_PATTERNS.size()],
				_home_of(realm), FAKE_RADIUS)
		if _zone_server.add_fake_player(brain, realm) < 0:
			push_warning("[Eldmark] Solo se han creado %d de %d jugadores falsos (tope de %d jugadores)"
					% [created, config.fake_players, config.max_players])
			break
		created += 1
	print("[Eldmark] Jugadores falsos creados: %d" % created)


# Reinos de la zona (los admitidos) que tienen algún punto de aparición; si ninguno lo tiene,
# Vardheim (el SpawnPicker usa entonces cualquier punto).
func _fake_player_realms() -> Array[int]:
	var allowed: PackedInt32Array = NetZones.allowed_realms(config.zone_id)
	var candidates: Array[int] = [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH,
			NetProtocol.Realm.ASKARRA]
	var realms: Array[int] = []
	for realm: int in candidates:
		if not allowed.is_empty() and not allowed.has(realm):
			continue
		if not Zones.get_spawn_points(_world, NetZones.realm_name(realm)).is_empty():
			realms.append(realm)
	if realms.is_empty():
		realms.append(NetProtocol.Realm.VARDHEIM)
	return realms


# Posición del primer punto de aparición del reino (o del primero de la zona, o el origen).
func _home_of(realm: int) -> Vector3:
	var point: Node3D = NetZones.find_spawn_point(_world, realm)
	return point.global_position if point != null else Vector3.ZERO


# --- Cierre -----------------------------------------------------------------------------------

func _on_tick_finished(tick: int) -> void:
	if _shutting_down:
		return
	if config.quit_after_ticks > 0 and tick >= config.quit_after_ticks:
		_shutdown("se han simulado %d ticks (--quit-after-ticks)" % tick)
		return
	if config.idle_quit_seconds > 0:
		if _zone_server.get_player_count() == 0:
			_idle_ticks += 1
		else:
			_idle_ticks = 0
		if _idle_ticks >= config.idle_quit_seconds * Engine.physics_ticks_per_second:
			_shutdown("%d s sin jugadores (--idle-quit)" % config.idle_quit_seconds)


# NOTICE de cierre y corte ordenado de los clientes (ZoneServer.stop), informe, y salida.
func _shutdown(reason: String) -> void:
	if _shutting_down:
		return
	_shutting_down = true
	print("[Eldmark] Cierre del servidor: %s" % reason)
	_zone_server.stop(SHUTDOWN_TEXT)
	var waited: int = 0
	while not _zone_server.is_stopped() and waited < SHUTDOWN_MAX_FRAMES:
		await get_tree().physics_frame
		waited += 1
	if not config.report_path.is_empty():
		var error: Error = _zone_server.write_report(config.report_path)
		if error == OK:
			print("[Eldmark] Informe escrito en %s" % config.report_path)
		else:
			push_warning("[Eldmark] No se pudo escribir el informe '%s' (error %d)"
					% [config.report_path, error])
	_remove_lock()
	print("[Eldmark] Servidor cerrado")
	get_tree().quit(0)
