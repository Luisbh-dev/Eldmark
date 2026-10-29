class_name NetHarness
extends RefCounted
## Ayudantes de las pruebas de integración de red (docs/red.md, secciones 16 y 17.8).
## [br][br]
## Un servidor ([ZoneServer]) y varios clientes ([NetClient]) caben en un mismo proceso si cada uno
## vive en su propio [SubViewport] con [code]own_world_3d = true[/code] (espacios de física
## separados) y tiene su propio [NetTransport] (cada uno registra su [SceneMultiplayer] por la ruta
## de su nodo). Las pruebas con varios procesos usan [method launch_process] y
## [method read_report].

## Primer puerto UDP que se prueba.
const FIRST_PORT: int = 24700
## Último puerto que se prueba antes de volver al primero.
const LAST_PORT: int = 29000
## Radio (m) por el que pasean los bots.
const BOT_RADIUS: float = 25.0

## Siguiente puerto que se prueba: así dos llamadas seguidas no devuelven el mismo aunque el
## primero aún no se haya abierto.
static var _next_port: int = FIRST_PORT


## Un puerto UDP libre a partir de [param start] (y de los que ya se han dado).
static func free_udp_port(start: int = FIRST_PORT) -> int:
	var port: int = maxi(start, _next_port)
	for _i: int in LAST_PORT - FIRST_PORT:
		if port > LAST_PORT:
			port = FIRST_PORT
		# PacketPeerUDP no comparte puerto con nadie (un UDPServer sí lo permitiría), así que detecta
		# también los puertos que ya tiene abiertos un servidor ENet de otro proceso.
		var probe := PacketPeerUDP.new()
		var error: Error = probe.bind(port)
		probe.close()
		if error == OK:
			_next_port = port + 1
			return port
		port += 1
	push_error("[NetHarness] No hay ningún puerto UDP libre")
	return -1


## Un [SubViewport] con su propio mundo (3D y física) colgado de [param parent], con la zona de
## [param world_scene_path] dentro. Con la ruta vacía, la zona plana de [ZoneFixture]. La raíz de la
## zona queda en el metadato [code]world[/code] del viewport.
static func make_world_viewport(parent: Node, world_scene_path: String) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	parent.add_child(viewport)
	var world: Node3D = null
	if world_scene_path.is_empty():
		world = ZoneFixture.build_flat_zone(viewport)
	else:
		var packed: PackedScene = load(world_scene_path) as PackedScene
		world = packed.instantiate() as Node3D if packed != null else null
		if world == null:
			push_error("[NetHarness] No se pudo cargar la zona %s" % world_scene_path)
			return viewport
		viewport.add_child(world)
	viewport.set_meta(&"world", world)
	return viewport


## Raíz de la zona de un viewport hecho con [method make_world_viewport].
static func get_world(viewport: SubViewport) -> Node3D:
	return viewport.get_meta(&"world", null) as Node3D


## Arranca un [ZoneServer] escuchando en [member ServerConfig.port] dentro de [param viewport]: un
## [NetTransport] y el servidor, con [DevAuthProvider] y sin registro. Si la zona es una
## [ZoneRoot], se le quita lo visual como hace [code]ServerMain[/code]. Devuelve null (y registra el
## error) si no se puede abrir el puerto.
static func start_server(viewport: SubViewport, config: ServerConfig) -> ZoneServer:
	var world: Node3D = get_world(viewport)
	var zone_root: ZoneRoot = world as ZoneRoot
	if zone_root != null:
		zone_root.strip_for_server()
	var transport := NetTransport.new()
	transport.name = "ServerTransport"
	viewport.add_child(transport)
	var server := ZoneServer.new()
	server.name = "ZoneServer"
	server.log_enabled = false
	viewport.add_child(server)
	var error: Error = server.start(config, world, transport, DevAuthProvider.new())
	if error != OK:
		push_error("[NetHarness] No se pudo arrancar el servidor en el puerto %d (%s)"
				% [config.port, error_string(error)])
		return null
	return server


## Arranca un bot ([NetClient] en modo [constant ClientConfig.Mode.BOT]) dentro de [param viewport]
## que conecta con 127.0.0.1:[param port] como [param realm], con la semilla [param bot_seed] y,
## si se indica, el simulador de red [param net_sim_spec]. Hace lo mismo que [OnlineMain] en modo
## bot: carga la zona (la del viewport, sin lo visual), avisa en cuanto se autentica y, al aparecer,
## le pone a su controlador un [BotBrain] que pasea alrededor del punto de aparición.
## [br][br]
## Metadatos del cliente devuelto: [code]controller[/code] ([LocalPlayerController]),
## [code]transport[/code] ([NetTransport]), [code]entities[/code] (el nodo que recibe al personaje
## local y al [RemoteWorld]) y, tras aparecer, [code]bot_brain[/code] ([BotBrain]).
static func start_bot(viewport: SubViewport, port: int, realm: int, bot_seed: int,
		net_sim_spec: String = "") -> NetClient:
	var zone_root: ZoneRoot = get_world(viewport) as ZoneRoot
	if zone_root != null:
		zone_root.strip_for_server()
	var transport := NetTransport.new()
	transport.name = "ClientTransport"
	viewport.add_child(transport)
	var controller := LocalPlayerController.new()
	controller.name = "LocalPlayerController"
	viewport.add_child(controller)
	var entities := Node3D.new()
	entities.name = "Entities"
	viewport.add_child(entities)
	var client := NetClient.new()
	viewport.add_child(client)
	client.set_meta(&"controller", controller)
	client.set_meta(&"transport", transport)
	client.set_meta(&"entities", entities)

	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.BOT
	config.address = "127.0.0.1"
	config.port = port
	config.realm = realm
	config.display_name = NameRules.bot_name(bot_seed)
	config.bot_seed = bot_seed
	config.net_sim_spec = net_sim_spec
	client.welcomed.connect(func(_welcome: NetMessages.Welcome) -> void:
		client.notify_zone_ready(entities))
	client.local_spawned.connect(func(character: PlayerCharacter) -> void:
		var brain := BotBrain.new(bot_seed, BotBrain.Pattern.WANDER, character.global_position,
				BOT_RADIUS)
		controller.set_bot(brain)
		client.set_meta(&"bot_brain", brain))
	var error: Error = client.start(config, transport, controller)
	if error != OK:
		push_error("[NetHarness] El bot %d no pudo empezar a conectar (%s)"
				% [bot_seed, error_string(error)])
	return client


## Lanza otro proceso de este mismo ejecutable, sin ventana y dentro de este proyecto, con
## [param user_args] como argumentos de usuario (los que van tras [code]--[/code]) y su registro de
## Godot en [code]build/<log_name>.log[/code]. Devuelve el pid, o -1 si no pudo lanzarlo.
static func launch_process(user_args: PackedStringArray, log_name: String) -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var log_dir: String = project_dir.path_join("build")
	DirAccess.make_dir_recursive_absolute(log_dir)
	var args := PackedStringArray(["--headless", "--path", project_dir, "--log-file",
			log_dir.path_join("%s.log" % log_name), "--"])
	args.append_array(user_args)
	return OS.create_process(OS.get_executable_path(), args)


## Informe JSON escrito por un proceso (o [method NetClient.write_report]). Un diccionario vacío
## si el archivo no existe o no es JSON.
static func read_report(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return {}
	return json.data if json.data is Dictionary else {}
