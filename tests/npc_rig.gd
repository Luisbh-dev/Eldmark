class_name NpcRig
extends RefCounted
## Setup for the NPC tests (package F4): a network-less [ZoneServer] on the real zone, Vado Gris
## (with its navigation mesh, its fort and its spawners), advanced quickly with a
## [FortressFixture.Stepper]. Tests request fake players with custom brains and watch what the NPCs
## do.

const ZONE_ID: String = "vado_gris"
const FORTRESS: StringName = &"vado_gris_fort"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH

var world: Node3D = null
var server: ZoneServer = null
var stepper: FortressFixture.Stepper = null
var tree: SceneTree = null
## The flat zone's [SubViewport] ([method start_flat]); null in the real zone.
var viewport: SubViewport = null
## The combat events since it started.
var events: Array[NetMessages.EntityEvent] = []


## Starts the server in [param zone_id]. [param configure] is
## [code](config: ServerConfig) -> void[/code] to change the configuration before starting. If
## [param manual] the server does not run on its own: [method advance] advances it.
func start(scene_tree: SceneTree, configure: Callable = Callable(), zone_id: String = ZONE_ID,
		manual: bool = true) -> void:
	tree = scene_tree
	var packed: PackedScene = load(NetZones.scene_path(zone_id)) as PackedScene
	world = packed.instantiate() as Node3D
	tree.root.add_child(world)
	var zone_root: ZoneRoot = world as ZoneRoot
	if zone_root != null:
		zone_root.strip_for_server()
	server = ZoneServer.new()
	server.name = "ZoneServer"
	server.log_enabled = false
	tree.root.add_child(server)
	await tree.physics_frame
	await tree.physics_frame
	await tree.physics_frame
	await tree.physics_frame
	var config := ServerConfig.new()
	config.zone_id = zone_id
	config.max_players = 64
	config.no_dummies = true
	if configure.is_valid():
		configure.call(config)
	var error: Error = server.start(config, world, null, DevAuthProvider.new())
	assert(error == OK)
	server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: events.append(event))
	if manual:
		server.set_physics_process(false)
		stepper = FortressFixture.Stepper.new()
		stepper.server = server
		tree.root.add_child(stepper)


## Like [method start] but on the flat zone of [ZoneFixture] (without its own navigation or fort)
## in a [SubViewport] with its physics world. [param build] is [code](world: Node3D) -> void[/code]
## to add a fort, spawners, safe areas or walls before starting the server.
func start_flat(scene_tree: SceneTree, build: Callable = Callable(), configure: Callable = Callable()) -> void:
	tree = scene_tree
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	tree.root.add_child(viewport)
	world = ZoneFixture.build_flat_zone(viewport)
	if build.is_valid():
		build.call(world)
	server = ZoneServer.new()
	server.name = "ZoneServer"
	server.log_enabled = false
	viewport.add_child(server)
	for _i: int in 3:
		await tree.physics_frame
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	config.max_players = 64
	config.no_dummies = true
	if configure.is_valid():
		configure.call(config)
	var error: Error = server.start(config, world, null, DevAuthProvider.new())
	assert(error == OK)
	server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: events.append(event))
	server.set_physics_process(false)
	stepper = FortressFixture.Stepper.new()
	stepper.server = server
	viewport.add_child(stepper)


## Adds to [param parent] an NPC spawner ([NpcSpawner]) at [param local_position] facing
## [param yaw]. [param properties] gives the rest of its fields ([code]max_alive[/code],
## [code]respawn_s[/code], [code]alert_group[/code], [code]condition[/code], [code]realm[/code],
## [code]patrol_route[/code]).
static func add_spawner(parent: Node3D, node_name: String, npc_id: StringName, local_position: Vector3,
		yaw: float = 0.0, properties: Dictionary = {}) -> NpcSpawner:
	var spawner := NpcSpawner.new()
	spawner.name = node_name
	spawner.npc_id = npc_id
	for key: StringName in properties:
		spawner.set(key, properties[key])
	parent.add_child(spawner)
	spawner.position = local_position
	spawner.rotation.y = yaw
	spawner.add_to_group(NpcSpawner.GROUP)
	return spawner


## Adds to [param world] a safe area of [param realm] (realm name) at [param position].
static func add_safe_area(world_node: Node3D, realm_name: StringName, position: Vector3,
		radius: float = 24.0) -> Marker3D:
	var marker := Marker3D.new()
	marker.name = "Campamento_%s" % realm_name
	world_node.add_child(marker)
	marker.position = position
	marker.add_to_group(&"safe_areas")
	marker.set_meta(&"realm", realm_name)
	marker.set_meta(&"radius", radius)
	return marker


## Adds to [param world] a wall of [param size] centered at [param center] (world layer).
static func add_wall(world_node: Node3D, center: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Muro"
	body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	world_node.add_child(body)
	body.position = center
	return body


## Advances [param ticks] server ticks (quickly with the Stepper).
func advance(ticks: int) -> void:
	stepper.remaining += ticks
	while stepper.remaining > 0:
		await tree.physics_frame


## Advances until [param condition] is met (every [param step_ticks] ticks) or [param max_ticks]
## pass. Returns whether it was met.
func advance_until(condition: Callable, max_ticks: int, step_ticks: int = 6) -> bool:
	var elapsed: int = 0
	while elapsed < max_ticks:
		if condition.call():
			return true
		await advance(step_ticks)
		elapsed += step_ticks
	return bool(condition.call())


## Advances until navigation is ready and the system has spawned the NPCs (or fails after 900
## ticks).
func advance_until_populated(max_ticks: int = 900) -> bool:
	return await advance_until(func() -> bool:
		return server.get_npc_system() != null and server.get_npc_system().is_ready() \
				and server.get_npc_system().get_alive_count() > 0, max_ticks, 2)


func npcs() -> NpcSpawnerSystem:
	return server.get_npc_system()


func combatant(net_id: int) -> Combatant:
	return server.get_combat().get_combatant(net_id)


func entity(net_id: int) -> NetEntity:
	return server.get_registry().get_entity(net_id)


func character(net_id: int) -> PlayerCharacter:
	return entity(net_id).get_character()


func state() -> FortressState:
	return server.get_fortresses().get_fortress_state(FORTRESS)


func fort_node() -> Node3D:
	return server.get_fortresses().get_node_of(FORTRESS)


## A fake player of [param realm] at [param position] (on the ground), with [param brain] (idle if
## null).
func add_player(realm: int, position: Vector3, brain: BotBrain = null, yaw: float = 0.0) -> int:
	if brain == null:
		brain = CombatFixture.ScriptBrain.new(1)
	var net_id: int = server.add_fake_player(brain, realm)
	server.teleport(net_id, position)
	character(net_id).yaw = yaw
	return net_id


## net_id of the living NPCs whose definition is [param definition_id].
func alive_of(definition_id: StringName) -> Array[int]:
	var found: Array[int] = []
	var number: int = NpcCatalog.number_of(definition_id)
	for net_id: int in npcs().get_alive_ids():
		if entity(net_id).npc_def_id == number:
			found.append(net_id)
	return found


## The combat events of type [param kind] ([enum NetMessages.EntityEvent.Kind]).
func events_of(kind: int) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in events:
		if event.event == kind:
			found.append(event)
	return found


## Releases everything that was set up.
func stop() -> void:
	if is_instance_valid(stepper):
		stepper.get_parent().remove_child(stepper)
		stepper.free()
	if is_instance_valid(server):
		server.get_parent().remove_child(server)
		server.free()
	if is_instance_valid(viewport):
		viewport.get_parent().remove_child(viewport)
		viewport.free()
	elif is_instance_valid(world):
		world.get_parent().remove_child(world)
		world.queue_free()
	stepper = null
	server = null
	world = null
	viewport = null
	if tree != null:
		await tree.process_frame
