class_name ServerMain
extends Node
## Root of a zone's dedicated server (docs/red.md, sections 1.2 to 1.4).
## [br][br]
## [code]boot.gd[/code] fills [member config] with [method ServerConfig.from_args] when started with [code]--server[/code]
## and switches to [code]scenes/server/server_main.tscn[/code]. Here:
## [br]- The section 1.3 settings are applied: [code]Engine.max_fps = 120[/code] (in headless, the main loop sleeps
## between iterations and each tick's time varied by about 10 ms; with 120 fps it drops to ~0.5 ms), no physics
## interpolation (nothing is drawn) and no automatic multiplayer polling ([method NetTransport.poll] is called by hand on
## every tick).
## [br]- The zone scene is loaded ([method NetZones.scene_path]); if its root is a [ZoneRoot] its visual parts are
## stripped ([method ZoneRoot.strip_for_server]) and the [code]Terrain3D[/code] is left with full collision and without
## its own processing, as fixed by [code]tests/test_terrain3d_headless.gd[/code].
## [br]- The [NetTransport] is created (with [member ServerConfig.net_sim_spec]) and the [ZoneServer], which opens the
## port, and the fake players of [code]--fake-players=N[/code]. With [code]--fake-layout=cluster[/code] they are all
## grouped at the same point (within 60 m of each other) and with [code]--fake-layout=spread[/code] they are spread
## across the zone; with [code]--fake-churn=<ticks>[/code] the oldest leaves and a new one enters every that many ticks
## (continuous joins and leaves).
## [br]- With [code]--fake-brain=combat[/code] the fake players fight ([constant BotBrain.Pattern.COMBAT]): they look for
## the nearest enemy, attack, block and dodge. A training dummy is placed at each [code]dummy_points[/code] marker of the
## zone (except with [code]--no-dummies[/code]) and with [code]--console[/code] the server reads commands from standard
## input ([CommandRegistry]); the [code]shutdown <s>[/code] countdown closes the process like
## [code]--quit-after-ticks[/code].
## [br]- With [code]--fake-brain=siege[/code] (GUE-15) the fakes besiege and defend the zone's fort
## ([constant BotBrain.Pattern.SIEGE]): they leave their camp, follow their realm's route to the gate, break it, capture
## the circle and defend it; the realm distribution is the usual one (in turns). With [code]--run-at=<tick>:<command>[/code]
## the server runs console commands at a given tick (for example [code]fort_kill_captain[/code], which opens the circle
## while there is no real captain).
## [br]- With [code]--max-realm-diff=N[/code] (N > 0, GUE-42) the auto-realm fakes (all except those of
## [code]--fake-layout=cluster[/code] without a combat brain, which go to the first realm) are fillers
## ([FillerKeeper]): they are distributed to the realm with the lowest total, withdrawn when people join the larger
## side and return when they leave, and they take no people's seats: with the server full only because of them, a person
## enters and a fake gives up their seat (GUE-43). The exact rule is in [FillerKeeper] and [RealmBalance]; the joins and
## leaves of people are reported to it by [ZoneServer] ([method ZoneServer.set_filler_keeper]).
## [br]- With [code]--dev-lock[/code], [code]user://dev_server.json[/code] is written (or the path of
## [code]--dev-lock-path[/code]; [code]{pid, port}[/code]) so that [code]--local[/code] reuses this server, and it is
## deleted on shutdown.
## [br]- It shuts down with [code]--quit-after-ticks[/code], [code]--idle-quit[/code] or the appearance of the
## [code]--stop-file[/code] file (checked every second): shutdown NOTICE to clients, [method ZoneServer.stop], a report
## if there is [code]--report[/code] and exit.
## [br]- [b]SIGTERM and SIGINT do not shut down in an orderly way[/b]: GDScript cannot catch them and the process dies
## instantly (no NOTICE, no final report, with the [code]--dev-lock[/code] lock left undeleted). That is why
## [code]--stop-file[/code] exists and, with [code]--report[/code], the report is rewritten every
## [constant ZoneServer.METRICS_LOG_TICKS] ticks (10 s): if the server is killed, the last mark's report remains (with
## [code]"closed": false[/code]).
## [br]- [b]With [code]--platform=<internal url>[/code][/b] (docs/plataforma.md §5.5 and §8): reads the zone's secrets
## ([method ZonePlatform.read_secrets]), starts the [ZonePlatform] (registration, [code]env[/code], fortresses and first
## block of ids) and waits for [signal ZonePlatform.startup_finished] before opening the port; clients enter with
## [TicketAuthProvider] and, once the port is open, [method ZonePlatform.go_live]. With a staging or production
## [code]env[/code], the development options make the zone exit with code 1, and [code]--max-realm-diff[/code] does not
## apply (the realm comes from the character). Every orderly shutdown (the five triggers: [code]--stop-file[/code],
## [code]--quit-after-ticks[/code], [code]--idle-quit[/code], the console's [code]shutdown[/code] and the maintenance
## announced by the heartbeat) goes through [method _shutdown] → [method ZoneServer.stop], which sends each character's
## final save and waits for the platform to answer it (docs/plataforma.md §7.2); then pending items go out and the
## instance deregisters. If the platform closes the instance ([signal ZoneServer.instance_closed]), the §6.1 shutdown
## ([method ZoneServer.close_instance]: the finals before kicking anyone) and the process exits with code 3 so that the
## orchestrator starts another.
## [br]- [b]With [code]--dtls-cert=<pem> --dtls-key=<pem>[/code][/b] (docs/plataforma.md §10.2, with or without a
## platform): loads the certificate and key ([ZoneDtls], in [member ServerConfig.dtls]) before loading the zone, opens
## the port over DTLS and, with the platform, sends the certificate and its CN in the registration. If one of the two is
## missing, they cannot be read, the certificate has no CN or the key is not its own, it exits with code 1.
## [br][br]
## The exit code is 0 on a normal shutdown, 1 if it cannot start (unknown zone, port in use, invalid DTLS certificate,
## platform that does not answer or does not admit the zone...) and 3 if the platform closed the instance.

## Lock file of [code]--dev-lock[/code] if [code]--dev-lock-path[/code] is not given.
const DEV_LOCK_PATH: String = "user://dev_server.json"
## Maximum frames per second of the server (section 1.3).
const MAX_FPS: int = 120
## Physics steps waited after loading the zone before opening the port and creating the fake players: collision bodies
## (the Terrain3D, above all) enter the physics space in the first steps.
const WARMUP_PHYSICS_FRAMES: int = 3
## Maximum physics steps waited, on shutdown, for clients to leave and the platform to answer the final saves (the 10 s
## [constant ZoneServer.SAVE_DRAIN_TICKS] and the peers' wait), and afterwards, each time, for pending items and the
## deregistration to go out.
const SHUTDOWN_MAX_FRAMES: int = 720
## Exit code when the platform closes the instance (docs/plataforma.md §6.1).
const EXIT_INSTANCE_CLOSED: int = 3
## Seed of the first fake player; each one adds its index.
const FAKE_SEED_BASE: int = 7000
## Radius (m) within which each fake player wanders around its spawn point. With [code]--fake-layout=cluster[/code] all
## wander around the same point, so none is more than 2 × FAKE_RADIUS = 50 m from another.
const FAKE_RADIUS: float = 25.0
## With [code]--fake-brain=combat --fake-layout=cluster[/code]: radius (m) of the ring in which they appear.
const FAKE_COMBAT_RING_RADIUS: float = 3.0
## How much (m per square root of the index) the combat fakes' ring radius grows: 128 fit in about 9 m.
const FAKE_COMBAT_RING_GROWTH: float = 0.5
## With [code]--fake-layout=spread[/code]: half the side (m) of the square, centered on the origin, across which the
## fake players are spread; height from which the ground is searched; and seed.
const FAKE_SPREAD_HALF_EXTENT: float = 900.0
const FAKE_SPREAD_PROBE_HEIGHT: float = 400.0
const FAKE_SPREAD_SEED: int = 4242
## With [code]--fake-archers[/code]: radians by which the archers that fire at the sky raise their aim (about 45° above
## the good shot: the arrows live their 2 s).
const FAKE_SKY_AIM_RAISE: float = 0.8
## Patterns of the fake players, distributed round-robin.
const FAKE_PATTERNS: Array[BotBrain.Pattern] = [
	BotBrain.Pattern.WANDER, BotBrain.Pattern.WANDER, BotBrain.Pattern.JUMPY,
	BotBrain.Pattern.CIRCLE,
]
## Text of the shutdown NOTICE.
const SHUTDOWN_TEXT: String = "El servidor se está cerrando"
## Every how many ticks the existence of the [code]--stop-file[/code] file is checked (1 s).
const STOP_FILE_CHECK_TICKS: int = 60

## Server configuration. Filled by [code]boot.gd[/code]; if null on startup, it is read from the user arguments.
static var config: ServerConfig

var _world: Node3D
var _transport: NetTransport
var _zone_server: ZoneServer
## The platform (null without --platform).
var _platform: ZonePlatform = null
var _idle_ticks: int = 0
# Live fake players, from oldest to newest (for the --fake-churn leaves), how many have been created in total (sets
# each brain's seed), realms of the zone with a camp and the randomness of the --fake-layout=spread distribution.
var _fake_ids: Array[int] = []
var _fake_created: int = 0
# Pure archers created with --fake-archers (to distribute those that fire at the sky).
var _fake_archers: int = 0
var _fake_realms: Array[int] = []
var _spread_rng: RandomNumberGenerator = RandomNumberGenerator.new()
# The --max-realm-diff filler fakes (null without balancing).
var _fillers: FillerKeeper = null
# --run-at commands that have already been run (same order as config.scheduled_commands).
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
	if not _load_dtls():
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

	# Collision bodies enter the physics space in the first steps.
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
			+ "%d ticks/s, huella de la simulación 0x%08X%s)"
			% [Engine.physics_ticks_per_second, _zone_server.get_sim_hash(),
			", con DTLS" if config.dtls != null else ""])
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


# --- DTLS (docs/plataforma.md §10.2) ------------------------------------------------------------

# With --dtls-cert or --dtls-key, loads both into config.dtls (ZoneDtls). Returns false if the zone cannot start: one is
# missing, they cannot be read, the certificate has no CN or the key is not its own (the reason, in the log).
func _load_dtls() -> bool:
	if config.dtls != null or (config.dtls_cert_path.is_empty() and config.dtls_key_path.is_empty()):
		return true
	var dtls: ZoneDtls = ZoneDtls.load_files(config.dtls_cert_path, config.dtls_key_path)
	if not dtls.is_valid():
		push_error("[Eldmark] %s" % dtls.error)
		return false
	config.dtls = dtls
	print("[Eldmark] DTLS: certificado de «%s» (%s)" % [dtls.common_name, config.dtls_cert_path])
	return true


# --- Platform (docs/plataforma.md §8) ---------------------------------------------------------

# Reads the secrets and starts the platform: registration, env, fortresses and first block. Returns the ticket keys, or
# null if the zone cannot start (the reason is already in the log).
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


# Waits, for at most SHUTDOWN_MAX_FRAMES steps, until the platform has nothing queued or in flight.
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


# --- Development lock -----------------------------------------------------------------------

## Writes to [param path] the lock file [code]{"pid": …, "port": …}[/code] that [code]--local[/code] reads to reuse a
## server that is already running.
static func write_dev_lock(path: String, pid: int, port: int) -> Error:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({"pid": pid, "port": port}))
	file.close()
	return OK


## Deletes the lock file at [param path] if it belongs to [param pid] (not another server's). Returns true if it deleted
## it.
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


# --- Startup ---------------------------------------------------------------------------------

# Settings of section 1.3.
func _apply_headless_settings() -> void:
	Engine.max_fps = MAX_FPS
	var tree: SceneTree = get_tree()
	tree.physics_interpolation = false
	tree.multiplayer_poll = false


# Terrain3D as fixed by tests/test_terrain3d_headless.gd: full collision (the same the client uses, for determinism)
# and without its own processing, because without a camera its first _physics_process logs an error. It is accessed by
# name so as not to depend on the extension when loading the script.
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


# Fake players from --fake-players=N. By default: realms with spawn points in the zone, round-robin; patterns
# round-robin; different seeds; each one wanders around the first point of its realm. With --fake-layout=cluster all
# belong to the first realm and wander around the same point; with --fake-layout=spread each one wanders around a random
# point of the zone's square.
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


# Creates the next fake player according to --fake-layout. With [param forced_realm] (a realm code) it belongs to that
# realm; otherwise, the server decides the realm: in turns or, with realm balancing, the one with the lowest total.
# Returns its net_id, or -1 if it does not fit.
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
	# Where it is placed on appearing (null = at its spawn point).
	var placed_at: Variant = null
	match config.fake_layout:
		ServerConfig.LAYOUT_CLUSTER:
			if combat:
				# Combat ones are distributed among the realms and gather in a ring around the first one's point (or --fake-center,
				# outside safe zones), so that they meet right away. The ring grows with the number of fakes so that they do not pile up.
				home = _home_of(_fake_realms[0])
				if config.has_fake_center():
					home = _ground_point(config.fake_center.x, config.fake_center.y, home)
				var ring: float = FAKE_COMBAT_RING_RADIUS + FAKE_COMBAT_RING_GROWTH * sqrt(float(index))
				placed_at = home + Vector3(cos(float(index) * 2.4), 0.0,
						sin(float(index) * 2.4)) * ring
			elif siege:
				# Siege ones each leave from their own camp: grouping them at a single point would make no sense.
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
		# ZoneServer.add_fake_player gives it the fort, the routes and the enemy finder.
		pattern = BotBrain.Pattern.SIEGE
	var brain := BotBrain.new(FAKE_SEED_BASE + index, pattern, home, FAKE_RADIUS)
	# --fake-loadout: the equipment template (docs/habilidades.md, section 4.6).
	var template_id: int = config.fake_template_for(index)
	# --fake-archers (load tests, H5): those who carry the bow in hand are pure archers and some fire at the sky.
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


# Random ground point of the zone's square. If the ray finds no ground, returns [param fallback] (a spawn point).
func _spread_point(fallback: Vector3) -> Vector3:
	var x: float = _spread_rng.randf_range(-FAKE_SPREAD_HALF_EXTENT, FAKE_SPREAD_HALF_EXTENT)
	var z: float = _spread_rng.randf_range(-FAKE_SPREAD_HALF_EXTENT, FAKE_SPREAD_HALF_EXTENT)
	return _ground_point(x, z, fallback)


# Ground point under (x, z), slightly above. If the ray finds no ground, returns [param fallback].
func _ground_point(x: float, z: float, fallback: Vector3) -> Vector3:
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	# Slightly tilted ray: vertical ones can miss against HeightMapShape3D.
	var from := Vector3(x, FAKE_SPREAD_PROBE_HEIGHT, z)
	var query := PhysicsRayQueryParameters3D.create(from,
			from + Vector3(0.001, -2.0 * FAKE_SPREAD_PROBE_HEIGHT, 0.0),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return fallback
	return (hit["position"] as Vector3) + Vector3(0.0, 0.3, 0.0)


# Realms of the zone (the admitted ones) that have some spawn point; if none has one, Vardheim (the SpawnPicker then
# uses any point).
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
	# Fighting needs two hostile sides: if the zone does not assign points per realm, combat fakes are distributed among
	# the first two realms it admits.
	if config.fake_brain == ServerConfig.FAKE_BRAIN_COMBAT and realms.size() < 2:
		realms.clear()
		for realm: int in RealmCatalog.realm_codes():
			if allowed.is_empty() or allowed.has(realm):
				realms.append(realm)
			if realms.size() == 2:
				break
	return realms


# Position of the realm's first spawn point (or the zone's first, or the origin).
func _home_of(realm: int) -> Vector3:
	var point: Node3D = NetZones.find_spawn_point(_world, realm)
	return point.global_position if point != null else Vector3.ZERO


# --- Realm balance (GUE-42) -----------------------------------------------------------------

# true if all fakes go to the first realm (--fake-layout=cluster with the wandering brain): their realm is not
# automatic, so they are not fillers.
func _forces_first_realm() -> bool:
	return config.fake_layout == ServerConfig.LAYOUT_CLUSTER and config.fake_brain.is_empty()


# With --max-realm-diff and auto-realm fakes, prepares the fillers and hands them to the ZoneServer, which counts the
# joins and leaves of people for them and asks them for a seat when a person arrives with the server full (GUE-43).
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


# --- Shutdown ---------------------------------------------------------------------------------

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
		# If the server is killed (SIGTERM, SIGINT) there is no final report: this one remains.
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


# A stop file that already exists at startup is from a previous stop: it is deleted, or the new server would shut down
# in the first second.
func _clear_stale_stop_file() -> void:
	if not _stop_file_exists():
		return
	DirAccess.remove_absolute(config.stop_file_path)
	print("[Eldmark] Borrado el archivo de parada anterior: %s" % config.stop_file_path)


# --run-at=<tick>:<command>: runs with the server console each command whose tick has arrived (once).
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


# --fake-churn=<ticks>: at each multiple the oldest fake player leaves and, on the following tick (when its departure
# has been processed and there is room), a new one enters.
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


# Shutdown NOTICE, final saves and orderly cutoff of the clients (ZoneServer.stop; with [param closed_code], the
# instance shutdown of §6.1, ZoneServer.close_instance), report, and exit with [param exit_code]. With the platform,
# before exiting the pending items go out (saves and releases) and the instance deregisters.
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
		# The console thread is still waiting for a line from standard input and, on Linux, libc does not let the process exit
		# while the read holds the stdin lock.
		print("[Eldmark] La consola sigue leyendo la entrada estándar: el proceso termina al cerrarla "
				+ "(Ctrl+D) o al pulsar Intro")
	get_tree().quit(exit_code)
