class_name NetHarness
extends RefCounted
## Helpers for the network integration tests (docs/networking.md, sections 16 and 17.8).
## [br][br]
## A server ([ZoneServer]) and several clients ([NetClient]) fit in a single process if each one
## lives in its own [SubViewport] with [code]own_world_3d = true[/code] (separate physics spaces)
## and has its own [NetTransport] (each registers its [SceneMultiplayer] under its node's path).
## Tests with several processes use [method launch_process] and [method read_report].
## [br][br]
## [b]Two suites at once[/b] (two copies of the project, or two runs of the same one): each process
## starts looking for ports in its own slot ([method first_port_for]) and leaves its reports and
## logs in its own [code]build/<pid>/[/code] folder ([method get_build_dir]), so they neither
## overwrite nor read each other's files.

## First UDP port that is tried.
const FIRST_PORT: int = 24700
## Last port that is tried before going back to the first.
const LAST_PORT: int = 29000
## Number of port slots and ports per slot: each test process starts at the slot its pid assigns it
## ([method first_port_for]). 64 slots of 64 ports fit in the range.
const PORT_SLOT_COUNT: int = 64
const PORT_SLOT_SIZE: int = 64
## Folder for test reports and logs (one subdirectory per process).
const BUILD_DIR: String = "res://build"
## Radius (m) the bots wander within.
const BOT_RADIUS: float = 25.0
## Bytes that [method drain_pipes] reads at once from each pipe.
const DRAIN_BYTES: int = 4096

## Next port to be tried: this way two consecutive calls do not return the same one even if the
## first has not been opened yet.
static var _next_port: int = first_port_for(OS.get_process_id())
## The folders of dead processes under [constant BUILD_DIR] have already been deleted.
static var _stale_build_dirs_cleaned: bool = false


## First port that process [param pid] tries: its slot of [constant PORT_SLOT_SIZE] ports within
## [constant FIRST_PORT]..[constant LAST_PORT]. Two processes with different pids (unless they
## coincide modulo [constant PORT_SLOT_COUNT]) do not start at the same port, and between probing
## with [PacketPeerUDP] and actually opening the port seconds pass if it is a server loading a zone.
static func first_port_for(pid: int) -> int:
	return FIRST_PORT + (pid % PORT_SLOT_COUNT) * PORT_SLOT_SIZE


## The [code]build/<pid>/[/code] folder of this process (system path), created if it does not
## exist. The first time it is requested in a process, those of processes that no longer exist are
## deleted ([method clean_stale_build_dirs]).
static func get_build_dir() -> String:
	var base: String = ProjectSettings.globalize_path(BUILD_DIR)
	if not _stale_build_dirs_cleaned:
		_stale_build_dirs_cleaned = true
		clean_stale_build_dirs()
	var dir: String = base.path_join(str(OS.get_process_id()))
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


## System path of [param file_name] inside [method get_build_dir].
static func build_path(file_name: String) -> String:
	return get_build_dir().path_join(file_name)


## Deletes the [code]build/<number>/[/code] folders whose process no longer exists (those of
## another suite that is still running are not touched). Returns how many it deleted.
static func clean_stale_build_dirs() -> int:
	var base: String = ProjectSettings.globalize_path(BUILD_DIR)
	var removed: int = 0
	for folder: String in DirAccess.get_directories_at(base):
		if not folder.is_valid_int() or LocalServerLauncher.is_process_alive(folder.to_int()):
			continue
		_remove_recursive(base.path_join(folder))
		removed += 1
	return removed


## A free UDP port starting from [param start] (and from those already handed out).
static func free_udp_port(start: int = FIRST_PORT) -> int:
	var port: int = maxi(start, _next_port)
	for _i: int in LAST_PORT - FIRST_PORT:
		if port > LAST_PORT:
			port = FIRST_PORT
		# PacketPeerUDP does not share a port with anyone (a UDPServer would allow it), so it also detects
		# ports already open by an ENet server of another process.
		var probe := PacketPeerUDP.new()
		var error: Error = probe.bind(port)
		probe.close()
		if error == OK:
			_next_port = port + 1
			return port
		port += 1
	push_error("[NetHarness] No hay ningún puerto UDP libre")
	return -1


## A [SubViewport] with its own world (3D and physics) hung from [param parent], with the zone of
## [param world_scene_path] inside. With an empty path, the flat zone of [ZoneFixture]. The zone's
## root is stored in the viewport's [code]world[/code] metadata.
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


## Zone root of a viewport made with [method make_world_viewport].
static func get_world(viewport: SubViewport) -> Node3D:
	return viewport.get_meta(&"world", null) as Node3D


## Starts a [ZoneServer] listening on [member ServerConfig.port] inside [param viewport]: a
## [NetTransport] and the server, with [DevAuthProvider] and no registration. If the zone is a
## [ZoneRoot], its visuals are stripped as [code]ServerMain[/code] does. Returns null (and logs the
## error) if the port cannot be opened.
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


## Starts a bot ([NetClient] in [constant ClientConfig.Mode.BOT] mode) inside [param viewport] that
## connects to 127.0.0.1:[param port] as [param realm], with seed [param bot_seed] and, if given,
## the network simulator [param net_sim_spec], the cheat mode [param bot_cheat]
## ([BotCheater.MODES], [code]--bot-cheat[/code]) and the brain [param bot_brain]
## ([constant ClientConfig.BOT_BRAINS], [code]--bot-brain[/code]) and the loadout template
## [param loadout] ([code]--loadout[/code]: it goes out in a LOADOUT_SELECT right after the WELCOME
## arrives, before CLIENT_READY; empty = the default one). It does the same as [OnlineMain] in bot
## mode: it loads the zone (the viewport's, without visuals), gives that zone to its
## [FortressView] (so it links the forts of its own world and its hook moves its gate, not that of
## the server living in the same process), reports as soon as it authenticates and, on spawning,
## sets the [BotBrain] from [ClientBotBrains] on its controller (by default, one that wanders
## around the spawn point).
## [br][br]
## Metadata of the returned client: [code]controller[/code] ([LocalPlayerController]),
## [code]transport[/code] ([NetTransport]), [code]entities[/code] (the node that receives the local
## character and the [RemoteWorld]) and, after spawning, [code]bot_brain[/code] ([BotBrain]).
static func start_bot(viewport: SubViewport, port: int, realm: int, bot_seed: int,
		net_sim_spec: String = "", bot_cheat: String = "", bot_brain: String = "",
		loadout: String = "", configure: Callable = Callable()) -> NetClient:
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
	if get_world(viewport) != null:
		client.get_fortress_view().set_zone(get_world(viewport))
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
	config.bot_cheat = bot_cheat
	config.bot_brain = bot_brain
	config.loadout = loadout
	if configure.is_valid():
		# The rest of the configuration (for example, the zone's DTLS certificate and its name).
		configure.call(config)
	client.welcomed.connect(func(_welcome: NetMessages.Welcome) -> void:
		client.notify_zone_ready(entities))
	client.local_spawned.connect(func(character: PlayerCharacter) -> void:
		var brain: BotBrain = ClientBotBrains.make(client, config, character.global_position,
				BOT_RADIUS)
		controller.set_bot(brain)
		client.set_meta(&"bot_brain", brain))
	var error: Error = client.start(config, transport, controller)
	if error != OK:
		push_error("[NetHarness] El bot %d no pudo empezar a conectar (%s)"
				% [bot_seed, error_string(error)])
	return client


## Launches another process of this same executable, windowless and inside this project, with
## [param user_args] as user arguments (those after [code]--[/code]) and its Godot log in
## [code]build/<pid>/<log_name>.log[/code] ([method build_path]). Returns the pid, or -1 if it
## could not launch it. A client process gets [code]--locale=en[/code] (unless the caller passes its own), so
## the language of the machine or of its settings never reaches a test (docs/localization.md section 12.1);
## the server has no interface language and does not get it.
static func launch_process(user_args: PackedStringArray, log_name: String) -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray(["--headless", "--path", project_dir, "--log-file",
			build_path("%s.log" % log_name), "--"])
	args.append_array(user_args)
	if not user_args.has("--server"):
		var has_locale: bool = false
		for arg: String in user_args:
			has_locale = has_locale or arg.begins_with("--locale=")
		if not has_locale:
			args.append("--locale=en")
	return OS.create_process(OS.get_executable_path(), args)


## Like [method launch_process], but instead of the game it runs the script [param script_path]
## ([code]-s[/code]: a [SceneTree], like [code]tests/process_probe.gd[/code]). For auxiliary test
## processes that are neither the server nor a client.
static func launch_script(script_path: String, user_args: PackedStringArray, log_name: String) -> int:
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--log-file", build_path("%s.log" % log_name), "-s", script_path, "--"])
	args.append_array(user_args)
	return OS.create_process(OS.get_executable_path(), args)


## Reads and discards what a process launched with [method OS.execute_with_pipe] ([param process]
## is its dictionary) has written to its standard output and error. [b]It must be called while
## waiting for the process[/b]: on Windows those pipes have no buffer, so the child stalls on the
## first line it prints (without even writing its log) until the parent reads it. On Linux, with a
## 64 KB buffer, it is not needed but does no harm. The reads do not block.
static func drain_pipes(process: Dictionary) -> void:
	for key: String in ["stdio", "stderr"]:
		var pipe: FileAccess = process.get(key) as FileAccess
		if pipe == null or not pipe.is_open():
			continue
		while pipe.get_buffer(DRAIN_BYTES).size() == DRAIN_BYTES:
			pass


## Lines of the Godot log [param log_path] of another process that contain an engine or script
## error. The runner only captures errors from its own process: a test that launches processes has
## to look at the log of [b]each one[/b] (server, bots, the server launched by
## [code]--local[/code]...) so that an error in them makes the test fail.
static func error_lines(log_path: String) -> PackedStringArray:
	var found := PackedStringArray()
	for line: String in FileAccess.get_file_as_string(log_path).split("\n"):
		if line.contains("ERROR") or line.contains("SCRIPT ERROR"):
			found.append(line)
	return found


## JSON report written by a process (or [method NetClient.write_report]). An empty dictionary if
## the file does not exist or is not JSON.
static func read_report(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


static func _remove_recursive(path: String) -> void:
	for sub: String in DirAccess.get_directories_at(path):
		_remove_recursive(path.path_join(sub))
	for file_name: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)
