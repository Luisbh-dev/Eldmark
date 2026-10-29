class_name NpcRig
extends RefCounted
## Montaje de las pruebas de los PNJ (paquete F4): un [ZoneServer] sin red sobre la zona de verdad, el Vado Gris
## (con su malla de navegación, su fuerte y sus generadores), que se avanza deprisa con un
## [FortressFixture.Stepper]. Las pruebas piden jugadores falsos con cerebros a medida y miran lo que hacen los PNJ.

const ZONE_ID: String = "vado_gris"
const FORTRESS: StringName = &"vado_gris_fort"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH

var world: Node3D = null
var server: ZoneServer = null
var stepper: FortressFixture.Stepper = null
var tree: SceneTree = null
## El [SubViewport] de la zona plana ([method start_flat]); null en la zona de verdad.
var viewport: SubViewport = null
## Los eventos de combate desde que arrancó.
var events: Array[NetMessages.EntityEvent] = []


## Arranca el servidor en [param zone_id]. [param configure] es [code](config: ServerConfig) -> void[/code]
## para cambiar la configuración antes de arrancar. Si [param manual] el servidor no corre solo: lo avanza
## [method advance].
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


## Como [method start] pero sobre la zona plana de [ZoneFixture] (sin navegación ni fortaleza propias) en un
## [SubViewport] con su mundo de física. [param build] es [code](world: Node3D) -> void[/code] para añadirle
## fortaleza, generadores, zonas seguras o muros antes de arrancar el servidor.
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


## Añade a [param parent] un generador de PNJ ([NpcSpawner]) en [param local_position] mirando a [param yaw].
## [param properties] da el resto de sus campos ([code]max_alive[/code], [code]respawn_s[/code],
## [code]alert_group[/code], [code]condition[/code], [code]realm[/code], [code]patrol_route[/code]).
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


## Añade a [param world] una zona segura de [param realm] (nombre del reino) en [param position].
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


## Añade a [param world] un muro de [param size] centrado en [param center] (capa del mundo).
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


## Avanza [param ticks] ticks del servidor (deprisa con el Stepper).
func advance(ticks: int) -> void:
	stepper.remaining += ticks
	while stepper.remaining > 0:
		await tree.physics_frame


## Avanza hasta que se cumpla [param condition] (cada [param step_ticks] ticks) o pasen [param max_ticks]. Devuelve
## si se cumplió.
func advance_until(condition: Callable, max_ticks: int, step_ticks: int = 6) -> bool:
	var elapsed: int = 0
	while elapsed < max_ticks:
		if condition.call():
			return true
		await advance(step_ticks)
		elapsed += step_ticks
	return bool(condition.call())


## Avanza hasta que la navegación esté lista y el sistema haya generado a los PNJ (o falla a los 900 ticks).
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


## Un jugador falso de [param realm] en [param position] (en el suelo), con [param brain] (quieto si es null).
func add_player(realm: int, position: Vector3, brain: BotBrain = null, yaw: float = 0.0) -> int:
	if brain == null:
		brain = CombatFixture.ScriptBrain.new(1)
	var net_id: int = server.add_fake_player(brain, realm)
	server.teleport(net_id, position)
	character(net_id).yaw = yaw
	return net_id


## net_id de los PNJ vivos cuya definición es [param definition_id].
func alive_of(definition_id: StringName) -> Array[int]:
	var found: Array[int] = []
	var number: int = NpcCatalog.number_of(definition_id)
	for net_id: int in npcs().get_alive_ids():
		if entity(net_id).npc_def_id == number:
			found.append(net_id)
	return found


## Los eventos de combate del tipo [param kind] ([enum NetMessages.EntityEvent.Kind]).
func events_of(kind: int) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in events:
		if event.event == kind:
			found.append(event)
	return found


## Suelta todo lo montado.
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
