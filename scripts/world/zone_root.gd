class_name ZoneRoot
extends Node3D
## Root of a zone scene (loaded the same way by the dedicated server and the client).
##
## It prepares the [Terrain3D] for both cases without the zone knowing which one it is in:
## [br]- Server (no camera): full collision ([code]FULL_GAME[/code]) does not need
## [code]_physics_process[/code], and with no camera that process logs an error on the first tick
## ("Cannot find the active camera"). That is why it is disabled in [method _ready].
## [br]- Client: as soon as the viewport has an active camera, it is assigned to the terrain and
## its processing is re-enabled, so that the clipmap follows it. If the camera changes, it is
## reassigned.
## [br][br]
## The dedicated server additionally calls [method strip_for_server] after adding the zone to the
## tree: it removes everything that is only seen (meshes, lights, environment, instancer
## vegetation) and leaves collisions and markers. This is not done on detecting headless because
## tests and the windowless client also run headless and need the whole zone.
## [br][br]
## Spawn points are queried with [method get_spawn_points], which delegates to [Zones] (one rule
## for client, server and tests). It does not depend on anything in
## [code]scripts/client/[/code].

## Path to the zone's Terrain3D node.
@export var terrain_path: NodePath = ^"Terrain3D"
## Identifier of the zone (informational only for now).
@export var zone_id: StringName = &""

var _terrain: Node3D
var _bound_camera: Node3D
var _stripped: bool = false


func _ready() -> void:
	_terrain = get_node_or_null(terrain_path) as Node3D
	if _terrain == null:
		set_process(false)
		return
	# Without a camera, Terrain3D's first _physics_process would log an error.
	_terrain.set_physics_process(false)


func _process(_delta: float) -> void:
	if _stripped:
		return
	var camera: Node3D = get_viewport().get_camera_3d()
	if camera == null or camera == _bound_camera:
		return
	_bound_camera = camera
	_terrain.call(&"set_camera", camera)
	_terrain.set_physics_process(true)


## The zone's Terrain3D node (or null if it has none).
func get_terrain() -> Node3D:
	return _terrain


## The zone's spawn points (see [method Zones.get_spawn_points]); with a non-empty [param realm],
## only those of that realm.
func get_spawn_points(realm: StringName = &"") -> Array[Node3D]:
	return Zones.get_spawn_points(self, realm)


## true if [method strip_for_server] has already been called.
func is_stripped() -> bool:
	return _stripped


## Strips the visual layer for the dedicated server: frees the [GeometryInstance3D]s (meshes,
## MultiMesh, particles), the lights and the [WorldEnvironment], and empties the Terrain3D
## instancer's instances (grass, trees, rocks: their collision goes separately, in the scene). It
## keeps the collision bodies and shapes, the terrain (its collision) and the markers. Returns how
## many nodes it removed. Only the server should call it, once.
func strip_for_server() -> int:
	if _stripped:
		return 0
	_stripped = true
	set_process(false)
	var removed: Array[Node] = []
	_collect_visuals(self, removed)
	for node: Node in removed:
		node.get_parent().remove_child(node)
		node.free()
	if _terrain != null:
		var assets: Resource = _terrain.get(&"assets") as Resource
		var instancer: Object = _terrain.get(&"instancer")
		if assets != null and instancer != null:
			for mesh_id: int in int(assets.call(&"get_mesh_count")):
				instancer.call(&"clear_by_mesh", mesh_id)
	return removed.size()


## Visual-only nodes under [param node] (without descending into them or into the Terrain3D, whose
## internal children the terrain itself manages).
func _collect_visuals(node: Node, out: Array[Node]) -> void:
	for child: Node in node.get_children():
		if child is GeometryInstance3D or child is Light3D or child is WorldEnvironment:
			# A collision body hanging from a mesh would be lost: it is preserved.
			if _has_collision_descendant(child):
				_collect_visuals(child, out)
			else:
				out.append(child)
		elif child == _terrain:
			continue
		else:
			_collect_visuals(child, out)


static func _has_collision_descendant(node: Node) -> bool:
	for child: Node in node.get_children():
		if child is CollisionObject3D or child is CollisionShape3D or _has_collision_descendant(child):
			return true
	return false
