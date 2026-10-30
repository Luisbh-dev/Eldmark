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
## abre el puerto, y los jugadores falsos de [code]--fake-players=N[/code]. Con
## [code]--fake-layout=cluster[/code] se agrupan todos en un mismo punto (a menos de 60 m unos de otros) y
## con [code]--fake-layout=spread[/code] se reparten por la zona; con [code]--fake-churn=<ticks>[/code]
## sale el más antiguo y entra uno nuevo cada tantos ticks (altas y bajas continuas).
## [br]- Con [code]--fake-brain=combat[/code] los jugadores falsos pelean ([constant BotBrain.Pattern.COMBAT]):
## buscan al enemigo más cercano, atacan, bloquean y esquivan. En cada marcador [code]dummy_points[/code]
## de la zona se coloca un maniquí de entrenamiento (salvo con [code]--no-dummies[/code]) y con
## [code]--console[/code] el servidor lee comandos de la entrada estándar ([CommandRegistry]); la cuenta
## atrás de [code]shutdown <s>[/code] cierra el proceso como [code]--quit-after-ticks[/code].
## [br]- Con [code]--fake-brain=siege[/code] (GUE-15) los falsos asedian y defienden el fuerte de la zona
## ([constant BotBrain.Pattern.SIEGE]): salen de su campamento, siguen la ruta de su reino hasta la puerta, la
## rompen, capturan el círculo y lo defienden; el reparto de reinos es el de siempre (por turnos). Con
## [code]--run-at=<tick>:<orden>[/code] el servidor ejecuta órdenes de la consola en un tick dado (por ejemplo
## [code]fort_kill_captain[/code], que abre el círculo mientras no hay capitán de verdad).
## [br]- Con [code]--max-realm-diff=N[/code] (N > 0, GUE-42) los falsos de reino automático (todos salvo los de
## [code]--fake-layout=cluster[/code] sin cerebro de combate, que van al primer reino) son de relleno
## ([FillerKeeper]): se reparten en el reino con menos total, se retiran cuando entran personas en el bando largo
## y vuelven cuando salen, y no ocupan plazas de personas: con el servidor lleno solo por ellos, una persona entra y
## un falso le cede su plaza (GUE-43). La regla exacta está en [FillerKeeper] y [RealmBalance]; las altas y bajas
## de personas se las cuenta [ZoneServer] ([method ZoneServer.set_filler_keeper]).
## [br]- Con [code]--dev-lock[/code] se escribe [code]user://dev_server.json[/code] (o la ruta de
## [code]--dev-lock-path[/code]; [code]{pid, port}[/code]) para que [code]--local[/code] reutilice este servidor, y se borra al
## cerrar.
## [br]- Se cierra con [code]--quit-after-ticks[/code], [code]--idle-quit[/code] o la aparición del
## archivo de [code]--stop-file[/code] (se mira cada segundo): NOTICE de cierre a los clientes,
## [method ZoneServer.stop], informe si hay [code]--report[/code] y salida.
## [br]- [b]SIGTERM y SIGINT no cierran de forma ordenada[/b]: GDScript no puede atraparlas y el
## proceso muere al instante (sin NOTICE, sin informe final, con el bloqueo de [code]--dev-lock[/code]
## sin borrar). Por eso existe [code]--stop-file[/code] y, con [code]--report[/code], el informe se
## reescribe cada [constant ZoneServer.METRICS_LOG_TICKS] ticks (10 s): si matan al servidor, queda
## el de la última marca (con [code]"closed": false[/code]).
## [br]- [b]Con [code]--platform=<url interna>[/code][/b] (docs/plataforma.md §5.5 y §8): lee los secretos de la
## zona ([method ZonePlatform.read_secrets]), arranca la [ZonePlatform] (registro, [code]env[/code], fortalezas y
## primer bloque de ids) y espera [signal ZonePlatform.startup_finished] antes de abrir el puerto; los clientes
## entran con [TicketAuthProvider] y, ya con el puerto abierto, [method ZonePlatform.go_live]. Con un
## [code]env[/code] de staging o production, las opciones de desarrollo hacen salir a la zona con código 1, y
## [code]--max-realm-diff[/code] no se aplica (el reino sale del personaje). Todo cierre ordenado (los cinco
## disparadores: [code]--stop-file[/code], [code]--quit-after-ticks[/code], [code]--idle-quit[/code], el
## [code]shutdown[/code] de la consola y el mantenimiento que anuncia el latido) pasa por [method _shutdown] →
## [method ZoneServer.stop], que manda el guardado final de cada personaje y espera a que la plataforma lo conteste
## (docs/plataforma.md §7.2); después sale lo pendiente y la baja de la instancia. Si la plataforma cierra la
## instancia ([signal ZoneServer.instance_closed]), el cierre de §6.1 ([method ZoneServer.close_instance]: los
## finales antes de echar a nadie) y el proceso sale con código 3 para que el orquestador arranque otra.
## [br][br]
## El código de salida es 0 en un cierre normal, 1 si no puede arrancar (zona desconocida, puerto
## ocupado, plataforma que no responde o que no admite la zona...) y 3 si la plataforma cerró la instancia.

## Archivo de bloqueo de [code]--dev-lock[/code] si no se da [code]--dev-lock-path[/code].
const DEV_LOCK_PATH: String = "user://dev_server.json"
## Fotogramas por segundo máximos del servidor (sección 1.3).
const MAX_FPS: int = 120
## Pasos de física que se esperan tras cargar la zona antes de abrir el puerto y crear a los
## jugadores falsos: los cuerpos de colisión (el Terrain3D, sobre todo) entran en el espacio de
## física en los primeros pasos.
const WARMUP_PHYSICS_FRAMES: int = 3
## Pasos de física como mucho que se espera, al cerrar, a que los clientes se vayan y la plataforma conteste los
## guardados finales (el [constant ZoneServer.SAVE_DRAIN_TICKS] de 10 s y la espera de los peers), y después, cada
## vez, a que salga lo pendiente y la baja.
const SHUTDOWN_MAX_FRAMES: int = 720
## Código de salida cuando la plataforma cierra la instancia (docs/plataforma.md §6.1).
const EXIT_INSTANCE_CLOSED: int = 3
## Semilla del primer jugador falso; cada uno suma su índice.
const FAKE_SEED_BASE: int = 7000
## Radio (m) por el que pasea cada jugador falso alrededor de su punto de aparición. Con
## [code]--fake-layout=cluster[/code] todos pasean alrededor del mismo punto, así que ninguno está a
## más de 2 × FAKE_RADIUS = 50 m de otro.
const FAKE_RADIUS: float = 25.0
## Con [code]--fake-brain=combat --fake-layout=cluster[/code]: radio (m) del corro en el que aparecen.
const FAKE_COMBAT_RING_RADIUS: float = 3.0
## Cuánto crece (m por raíz del índice) el radio del corro de los falsos de combate: 128 caben en unos 9 m.
const FAKE_COMBAT_RING_GROWTH: float = 0.5
## Con [code]--fake-layout=spread[/code]: mitad del lado (m) del cuadrado, centrado en el origen, por
## el que se reparten los jugadores falsos; altura desde la que se busca el suelo; y semilla.
const FAKE_SPREAD_HALF_EXTENT: float = 900.0
const FAKE_SPREAD_PROBE_HEIGHT: float = 400.0
const FAKE_SPREAD_SEED: int = 4242
## Con [code]--fake-archers[/code]: radianes que suben la puntería los arqueros que disparan al cielo (unos 45°
## por encima del tiro bueno: las flechas viven sus 2 s).
const FAKE_SKY_AIM_RAISE: float = 0.8
## Patrones de los jugadores falsos, repartidos en rueda.
const FAKE_PATTERNS: Array[BotBrain.Pattern] = [
	BotBrain.Pattern.WANDER, BotBrain.Pattern.WANDER, BotBrain.Pattern.JUMPY,
	BotBrain.Pattern.CIRCLE,
]
## Texto del NOTICE de cierre.
const SHUTDOWN_TEXT: String = "El servidor se está cerrando"
## Cada cuántos ticks se mira si existe el archivo de [code]--stop-file[/code] (1 s).
const STOP_FILE_CHECK_TICKS: int = 60

## Configuración del servidor. La rellena [code]boot.gd[/code]; si es null al arrancar, se lee de
## los argumentos de usuario.
static var config: ServerConfig

var _world: Node3D
var _transport: NetTransport
var _zone_server: ZoneServer
## La plataforma (null sin --platform).
var _platform: ZonePlatform = null
var _idle_ticks: int = 0
# Jugadores falsos vivos, del más antiguo al más nuevo (para las bajas de --fake-churn), cuántos se han
# creado en total (fija la semilla de cada cerebro), reinos de la zona con campamento y el azar del
# reparto --fake-layout=spread.
var _fake_ids: Array[int] = []
var _fake_created: int = 0
# Arqueros puros creados con --fake-archers (para repartir los que disparan al cielo).
var _fake_archers: int = 0
var _fake_realms: Array[int] = []
var _spread_rng: RandomNumberGenerator = RandomNumberGenerator.new()
# Los falsos de relleno de --max-realm-diff (null sin equilibrio).
var _fillers: FillerKeeper = null
# Órdenes de --run-at que ya se han ejecutado (mismo orden que config.scheduled_commands).
var _scheduled_done: Array[bool] = []
var _shutting_down: bool = false
var _lock_written: bool = false
var _lock_path: String = DEV_LOCK_PATH


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
	var provider: AuthProvider = DevAuthProvider.new()
	if config.uses_platform():
		var keys: Variant = await _start_platform()
		if keys == null:
			await _drain_platform()
			get_tree().quit(1)
			return
		provider = TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, keys)
	var error: Error = _zone_server.start(config, _world, _transport, provider, _platform)
	if error != OK:
		push_error("[Eldmark] No se pudo abrir el puerto UDP %d (%s)" % [config.port,
				error_string(error)])
		if _platform != null:
			_platform.deregister()
			await _drain_platform()
		get_tree().quit(1)
		return
	_zone_server.tick_finished.connect(_on_tick_finished)
	_zone_server.shutdown_requested.connect(_shutdown)
	_zone_server.instance_closed.connect(_on_instance_closed)
	if _platform != null:
		_platform.go_live()
	print("[Eldmark] Servidor de la zona '%s' escuchando en el puerto UDP %d (hasta %d jugadores, "
			% [config.zone_id, config.port, config.max_players]
			+ "%d ticks/s, huella de la simulación 0x%08X)"
			% [Engine.physics_ticks_per_second, _zone_server.get_sim_hash()])
	if not config.net_sim_spec.is_empty():
		print("[Eldmark] Simulador de red: %s" % config.net_sim_spec)
	if config.debug_commands:
		print("[Eldmark] Comandos de depuración activados (--debug-commands)")

	if _platform != null and config.max_realm_diff > 0:
		print("[Eldmark] Con la plataforma --max-realm-diff no se aplica: el reino sale del personaje")
	else:
		_setup_fillers()
	_spawn_fake_players()
	if not config.no_dummies:
		var dummies: int = _zone_server.spawn_zone_dummies()
		if dummies > 0:
			print("[Eldmark] Maniquíes de entrenamiento colocados: %d" % dummies)
	if config.console:
		if _zone_server.start_console():
			print("[Eldmark] Consola de la entrada estándar activada (escribe help)")
		else:
			push_warning("[Eldmark] No hay entrada estándar utilizable: la consola (--console) no se activa")
	_clear_stale_stop_file()
	if config.dev_lock:
		_lock_path = config.dev_lock_path if not config.dev_lock_path.is_empty() else DEV_LOCK_PATH
		var lock_error: Error = write_dev_lock(_lock_path, OS.get_process_id(), config.port)
		if lock_error == OK:
			_lock_written = true
			print("[Eldmark] Archivo de bloqueo escrito: %s" % _lock_path)
		else:
			push_warning("[Eldmark] No se pudo escribir %s (error %d)" % [_lock_path, lock_error])


func _exit_tree() -> void:
	_remove_lock()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _zone_server != null and is_instance_valid(_zone_server):
			_zone_server.stop(SHUTDOWN_TEXT)
		_remove_lock()


# --- Plataforma (docs/plataforma.md §8) ---------------------------------------------------------

# Lee los secretos y arranca la plataforma: registro, env, fortalezas y primer bloque. Devuelve las claves del
# billete, o null si la zona no puede arrancar (el motivo ya está en el registro).
func _start_platform() -> Variant:
	var secrets: Dictionary = ZonePlatform.read_secrets()
	var errors: PackedStringArray = secrets["errors"]
	if not errors.is_empty():
		for line: String in errors:
			push_error("[Eldmark] Secretos de la zona: %s" % line)
		return null
	_platform = ZonePlatform.new()
	_platform.name = "ZonePlatform"
	add_child(_platform)
	_platform.fatal_error.connect(_on_platform_fatal)
	print("[Eldmark] Plataforma: registrando la zona '%s' (mundo %d, canal %d) en %s"
			% [config.zone_id, config.world_id, config.channel, config.platform_url])
	_platform.start(config, secrets)
	var result: Array = await _platform.startup_finished
	if not bool(result[0]):
		push_error("[Eldmark] %s" % String(result[1]))
		return null
	print("[Eldmark] Plataforma lista (env %s, instancia %s)" % [_platform.env(), _platform.instance_id()])
	return secrets["ticket_keys"]


# Espera, como mucho SHUTDOWN_MAX_FRAMES pasos, a que la plataforma no tenga nada en cola ni en vuelo.
func _drain_platform() -> void:
	if _platform == null:
		return
	_platform.begin_flush()
	var waited: int = 0
	while not _platform.is_flushed() and waited < SHUTDOWN_MAX_FRAMES:
		await get_tree().physics_frame
		waited += 1


func _on_instance_closed(code: String) -> void:
	_shutdown("la plataforma ha cerrado la instancia (%s)" % code, EXIT_INSTANCE_CLOSED, code)


func _on_platform_fatal(error: String) -> void:
	push_error("[Eldmark] %s" % error)
	_shutdown(error, 1)


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
	if remove_dev_lock(_lock_path, OS.get_process_id()):
		print("[Eldmark] Archivo de bloqueo borrado: %s" % _lock_path)


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


# Jugadores falsos de --fake-players=N. Por defecto: reinos con puntos de aparición en la zona, en
# rueda; patrones en rueda; semillas distintas; cada uno pasea alrededor del primer punto de su reino.
# Con --fake-layout=cluster todos son del primer reino y pasean alrededor del mismo punto; con
# --fake-layout=spread cada uno pasea alrededor de un punto al azar del cuadrado de la zona.
func _spawn_fake_players() -> void:
	if config.fake_players <= 0:
		return
	_fake_realms = _fake_player_realms()
	_spread_rng.seed = FAKE_SPREAD_SEED
	var created: int = 0
	for _i: int in config.fake_players:
		if _add_fake_player() < 0:
			push_warning("[Eldmark] Solo se han creado %d de %d jugadores falsos (tope de %d jugadores)"
					% [created, config.fake_players, config.max_players])
			break
		created += 1
	print("[Eldmark] Jugadores falsos creados: %d%s" % [created,
			" (%s)" % config.fake_layout if not config.fake_layout.is_empty() else ""])


# Crea el siguiente jugador falso según --fake-layout. Con [param forced_realm] (un código de reino) es de ese
# reino; si no, el reino lo decide el servidor: por turnos o, con el equilibrio de reinos, el de menos total.
# Devuelve su net_id, o -1 si no cabe.
func _add_fake_player(forced_realm: int = 0) -> int:
	var index: int = _fake_created
	var combat: bool = config.fake_brain == ServerConfig.FAKE_BRAIN_COMBAT
	var siege: bool = config.fake_brain == ServerConfig.FAKE_BRAIN_SIEGE
	var realm: int = _fake_realms[index % _fake_realms.size()]
	if forced_realm > 0:
		realm = forced_realm
	elif _fillers != null:
		var balanced: int = _fillers.next_realm()
		if balanced > 0:
			realm = balanced
	var home: Vector3 = Vector3.ZERO
	# Dónde se coloca al aparecer (null = en su punto de aparición).
	var placed_at: Variant = null
	match config.fake_layout:
		ServerConfig.LAYOUT_CLUSTER:
			if combat:
				# Los de combate se reparten entre los reinos y se juntan en un corro alrededor del
				# punto del primero (o de --fake-center, fuera de las zonas seguras), para que se
				# encuentren enseguida. El corro crece con el número de falsos para que no se apilen.
				home = _home_of(_fake_realms[0])
				if config.has_fake_center():
					home = _ground_point(config.fake_center.x, config.fake_center.y, home)
				var ring: float = FAKE_COMBAT_RING_RADIUS + FAKE_COMBAT_RING_GROWTH * sqrt(float(index))
				placed_at = home + Vector3(cos(float(index) * 2.4), 0.0,
						sin(float(index) * 2.4)) * ring
			elif siege:
				# Los de asedio salen cada uno de su campamento: agruparlos en un solo punto no tendría sentido.
				home = _home_of(realm)
			else:
				realm = _fake_realms[0]
				home = _home_of(realm)
		ServerConfig.LAYOUT_SPREAD:
			home = _spread_point(_home_of(realm))
			placed_at = home
		_:
			home = _home_of(realm)
	var pattern: BotBrain.Pattern = FAKE_PATTERNS[index % FAKE_PATTERNS.size()]
	if combat:
		pattern = BotBrain.Pattern.COMBAT
	elif siege:
		# ZoneServer.add_fake_player le da el fuerte, las rutas y el buscador de enemigos.
		pattern = BotBrain.Pattern.SIEGE
	var brain := BotBrain.new(FAKE_SEED_BASE + index, pattern, home, FAKE_RADIUS)
	# --fake-loadout: la plantilla de equipo (docs/habilidades.md, sección 4.6).
	var template_id: int = config.fake_template_for(index)
	# --fake-archers (pruebas de carga, H5): los que llevan el arco en la mano son arqueros puros y una parte dispara
	# al cielo.
	var weapons: PackedInt32Array = CombatCatalog.template_weapons(template_id) if template_id > 0 \
			else PackedInt32Array()
	if config.fake_archers_sky_percent >= 0 and not weapons.is_empty() and BotBrain.is_ranged_weapon(weapons[0]):
		brain.kit_ranged_only = true
		if config.is_sky_archer(_fake_archers):
			brain.kit_aim_raise = FAKE_SKY_AIM_RAISE
		_fake_archers += 1
	var net_id: int = _zone_server.add_fake_player(brain, realm, template_id)
	if net_id < 0:
		return -1
	_fake_created += 1
	_fake_ids.append(net_id)
	if _fillers != null:
		_fillers.track(net_id, realm)
	if placed_at is Vector3:
		_zone_server.teleport(net_id, placed_at)
	return net_id


# Punto del suelo, al azar, del cuadrado de la zona. Si el rayo no encuentra suelo, devuelve
# [param fallback] (un punto de aparición).
func _spread_point(fallback: Vector3) -> Vector3:
	var x: float = _spread_rng.randf_range(-FAKE_SPREAD_HALF_EXTENT, FAKE_SPREAD_HALF_EXTENT)
	var z: float = _spread_rng.randf_range(-FAKE_SPREAD_HALF_EXTENT, FAKE_SPREAD_HALF_EXTENT)
	return _ground_point(x, z, fallback)


# Punto del suelo bajo (x, z), un poco por encima. Si el rayo no encuentra suelo, devuelve
# [param fallback].
func _ground_point(x: float, z: float, fallback: Vector3) -> Vector3:
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	# Rayo ligeramente inclinado: los verticales pueden fallar contra HeightMapShape3D.
	var from := Vector3(x, FAKE_SPREAD_PROBE_HEIGHT, z)
	var query := PhysicsRayQueryParameters3D.create(from,
			from + Vector3(0.001, -2.0 * FAKE_SPREAD_PROBE_HEIGHT, 0.0),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return fallback
	return (hit["position"] as Vector3) + Vector3(0.0, 0.3, 0.0)


# Reinos de la zona (los admitidos) que tienen algún punto de aparición; si ninguno lo tiene,
# Vardheim (el SpawnPicker usa entonces cualquier punto).
func _fake_player_realms() -> Array[int]:
	var allowed: PackedInt32Array = NetZones.allowed_realms(config.zone_id)
	var realms: Array[int] = []
	for realm: int in RealmCatalog.realm_codes():
		if not allowed.is_empty() and not allowed.has(realm):
			continue
		if not Zones.get_spawn_points(_world, NetZones.realm_name(realm)).is_empty():
			realms.append(realm)
	if realms.is_empty():
		realms.append(NetProtocol.Realm.VARDHEIM)
	# Para pelear hacen falta dos bandos hostiles: si la zona no reparte puntos por reino, los de
	# combate se reparten entre los dos primeros reinos que admite.
	if config.fake_brain == ServerConfig.FAKE_BRAIN_COMBAT and realms.size() < 2:
		realms.clear()
		for realm: int in RealmCatalog.realm_codes():
			if allowed.is_empty() or allowed.has(realm):
				realms.append(realm)
			if realms.size() == 2:
				break
	return realms


# Posición del primer punto de aparición del reino (o del primero de la zona, o el origen).
func _home_of(realm: int) -> Vector3:
	var point: Node3D = NetZones.find_spawn_point(_world, realm)
	return point.global_position if point != null else Vector3.ZERO


# --- Equilibrio de reinos (GUE-42) -----------------------------------------------------------------

# true si todos los falsos van al primer reino (--fake-layout=cluster con el cerebro de paseo): su reino no es
# automático, así que no son de relleno.
func _forces_first_realm() -> bool:
	return config.fake_layout == ServerConfig.LAYOUT_CLUSTER and config.fake_brain.is_empty()


# Con --max-realm-diff y falsos de reino automático, prepara a los de relleno y se los da al ZoneServer, que les
# cuenta las altas y bajas de personas y les pide plaza cuando llega una persona con el servidor lleno (GUE-43).
func _setup_fillers() -> void:
	if config.max_realm_diff <= 0 or config.fake_players <= 0 or _forces_first_realm():
		return
	_fillers = FillerKeeper.new(NetZones.allowed_realms(config.zone_id), config.fake_players,
			_zone_server.get_realm_counts.bind(true))
	_fillers.creator = func(realm: int) -> int: return _add_fake_player(realm)
	_fillers.remover = func(net_id: int) -> void:
		_fake_ids.erase(net_id)
		_zone_server.retire_filler(net_id)
	_fillers.calm_check = _zone_server.is_fake_calm
	_zone_server.set_filler_keeper(_fillers)
	print("[Eldmark] Equilibrio de reinos: diferencia máxima de %d personas; los falsos rellenan el bando corto"
			% config.max_realm_diff)


# --- Cierre -----------------------------------------------------------------------------------

func _on_tick_finished(tick: int) -> void:
	if _shutting_down:
		return
	if config.quit_after_ticks > 0 and tick >= config.quit_after_ticks:
		_shutdown("se han simulado %d ticks (--quit-after-ticks)" % tick)
		return
	if tick % STOP_FILE_CHECK_TICKS == 0 and _stop_file_exists():
		_shutdown("apareció el archivo de parada %s (--stop-file)" % config.stop_file_path)
		return
	if not config.report_path.is_empty() and tick % ZoneServer.METRICS_LOG_TICKS == 0:
		# Si matan al servidor (SIGTERM, SIGINT) no hay informe final: queda este.
		_zone_server.write_report(config.report_path)
	_run_scheduled_commands(tick)
	_churn_fake_players(tick)
	if config.idle_quit_seconds > 0:
		if _zone_server.get_player_count() == 0:
			_idle_ticks += 1
		else:
			_idle_ticks = 0
		if _idle_ticks >= config.idle_quit_seconds * Engine.physics_ticks_per_second:
			_shutdown("%d s sin jugadores (--idle-quit)" % config.idle_quit_seconds)


func _stop_file_exists() -> bool:
	return not config.stop_file_path.is_empty() and FileAccess.file_exists(config.stop_file_path)


# Un archivo de parada que ya existe al arrancar es de una parada anterior: se borra, o el servidor
# nuevo se cerraría en el primer segundo.
func _clear_stale_stop_file() -> void:
	if not _stop_file_exists():
		return
	DirAccess.remove_absolute(config.stop_file_path)
	print("[Eldmark] Borrado el archivo de parada anterior: %s" % config.stop_file_path)


# --run-at=<tick>:<orden>: ejecuta con la consola del servidor cada orden cuyo tick ya ha llegado (una vez).
func _run_scheduled_commands(tick: int) -> void:
	if config.scheduled_commands.is_empty():
		return
	if _scheduled_done.size() != config.scheduled_commands.size():
		_scheduled_done.resize(config.scheduled_commands.size())
	for i: int in config.scheduled_commands.size():
		var entry: Dictionary = config.scheduled_commands[i]
		if _scheduled_done[i] or tick < int(entry["tick"]):
			continue
		_scheduled_done[i] = true
		var answer: String = _zone_server.console_command(String(entry["line"]))
		print("[Eldmark] --run-at (tick %d): %s -> %s" % [tick, entry["line"], answer])


# --fake-churn=<ticks>: en cada múltiplo sale el jugador falso más antiguo y, en el tick siguiente
# (cuando su baja ya se ha procesado y hay sitio), entra uno nuevo.
func _churn_fake_players(tick: int) -> void:
	if config.fake_churn_ticks <= 0 or _fake_realms.is_empty():
		return
	if tick % config.fake_churn_ticks == 0 and not _fake_ids.is_empty():
		var leaving: int = _fake_ids.pop_front()
		if _fillers != null:
			_fillers.forget(leaving)
		_zone_server.remove_fake_player(leaving)
	elif tick % config.fake_churn_ticks == 1 and _fake_ids.size() < config.fake_players:
		_add_fake_player()


# NOTICE de cierre, guardados finales y corte ordenado de los clientes (ZoneServer.stop; con
# [param closed_code], el cierre de la instancia de §6.1, ZoneServer.close_instance), informe, y salida con
# [param exit_code]. Con la plataforma, antes de salir sale lo pendiente (guardados y liberaciones) y la baja.
func _shutdown(reason: String, exit_code: int = 0, closed_code: String = "") -> void:
	if _shutting_down:
		return
	_shutting_down = true
	print("[Eldmark] Cierre del servidor: %s" % reason)
	if closed_code.is_empty():
		_zone_server.stop(SHUTDOWN_TEXT)
	else:
		_zone_server.close_instance(closed_code)
	var waited: int = 0
	while not _zone_server.is_stopped() and waited < SHUTDOWN_MAX_FRAMES:
		await get_tree().physics_frame
		waited += 1
	if _platform != null:
		await _drain_platform()
		_platform.deregister()
		await _drain_platform()
	if not config.report_path.is_empty():
		var error: Error = _zone_server.write_report(config.report_path)
		if error == OK:
			print("[Eldmark] Informe escrito en %s" % config.report_path)
		else:
			push_warning("[Eldmark] No se pudo escribir el informe '%s' (error %d)"
					% [config.report_path, error])
	_remove_lock()
	if _stop_file_exists():
		DirAccess.remove_absolute(config.stop_file_path)
	print("[Eldmark] Servidor cerrado")
	var console: ServerConsole = _zone_server.get_console()
	if console != null and console.is_reading():
		# El hilo de la consola sigue esperando una línea de la entrada estándar y, en Linux, libc no
		# deja salir al proceso mientras la lectura tenga cogido el bloqueo de stdin.
		print("[Eldmark] La consola sigue leyendo la entrada estándar: el proceso termina al cerrarla "
				+ "(Ctrl+D) o al pulsar Intro")
	get_tree().quit(exit_code)
