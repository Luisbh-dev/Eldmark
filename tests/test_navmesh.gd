extends TestCase
## Tests for the baked navigation mesh of Vado Gris (MUN-06, docs/fortress.md section 4.1,
## [code]tools/bake_navmesh.gd[/code]): loading the saved mesh, valid paths from each
## GuardSpawn in the fort to the walkway, the ford and the two bridges, and that with the gate closed
## (without the link the server creates) there is no way out of the fort. If the zone's geometry changes
## the mesh must be baked again; these tests fail if the new geometry breaks a path.
## [br][br]
## It uses its own [NavigationServer3D] map, as the server will. Verified in Godot 4.7.2: the
## first iteration of the map (id 1) comes out [b]empty[/b] (the region's commands are applied afterwards,
## and [code]map_force_update[/code] does not avoid it) and good paths arrive a few physics steps
## later (iteration 2); that is why we wait until the map gives a genuinely nearby point
## ([method _wait_for_map]). Before the first synchronisation, querying the map logs an error.

const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const NAVMESH_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris_navmesh.tres"
## The mesh file cannot exceed this (docs/fortress.md, 4.1).
const MAX_FILE_BYTES: int = 20 * 1024 * 1024
## A path arrives if it ends less than this (m) from the destination horizontally and vertically.
const REACH_XZ: float = 1.0
const REACH_Y: float = 1.5
## Bridges: centre at x = 0, z = ±62.
const BRIDGE_Z: float = 62.0
## Centre of the ford.
const FORD: Vector2 = Vector2(-62.0, 0.0)
## Esplanade in front of the fort's gate (outside, to the west).
const GATE_OUTSIDE: Vector2 = Vector2(-30.0, 0.0)
## Half side of the palisade (m), with a margin for the thickness of the logs.
const FORT_HALF: float = 20.3
## Siege bot routes, with the walkway's (GUE-45).
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
## A leg of the walkway route is walkable if the mesh route between its ends is no longer than the straight
## leg by this factor plus this margin (m).
const WALKWAY_DETOUR_FACTOR: float = 1.2
const WALKWAY_DETOUR_MARGIN: float = 1.5

var _zone: Node3D = null
var _fort: Node3D = null
var _navmesh: NavigationMesh = null
var _map: RID
var _region: RID
var _link: RID


func before_each() -> void:
	_navmesh = load(NAVMESH_PATH) as NavigationMesh
	var scene: PackedScene = load(ZONE_SCENE_PATH) as PackedScene
	if not assert_not_null(scene, "could not load %s" % ZONE_SCENE_PATH) \
			or not assert_not_null(_navmesh, "could not load %s" % NAVMESH_PATH):
		return
	_zone = scene.instantiate() as Node3D
	tree.root.add_child(_zone)
	_fort = _zone.get_node(^"Fuerte") as Node3D
	_map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_cell_size(_map, _navmesh.cell_size)
	NavigationServer3D.map_set_cell_height(_map, _navmesh.cell_height)
	NavigationServer3D.map_set_up(_map, Vector3.UP)
	NavigationServer3D.map_set_active(_map, true)
	_region = NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(_region, _map)
	NavigationServer3D.region_set_navigation_mesh(_region, _navmesh)
	NavigationServer3D.region_set_transform(_region, Transform3D.IDENTITY)
	NavigationServer3D.region_set_enabled(_region, true)
	assert_true(await _wait_for_map(), "the navigation map has just been built")


func after_each() -> void:
	if _link.is_valid():
		NavigationServer3D.free_rid(_link)
		_link = RID()
	if _region.is_valid():
		NavigationServer3D.free_rid(_region)
	if _map.is_valid():
		NavigationServer3D.free_rid(_map)
	_region = RID()
	_map = RID()
	if is_instance_valid(_zone):
		_zone.get_parent().remove_child(_zone)
		_zone.queue_free()
	_zone = null
	_fort = null
	_navmesh = null
	await wait_process_frames()


func test_the_saved_mesh_is_a_small_text_resource_with_the_agreed_parameters() -> void:
	if not assert_not_null(_navmesh, "the mesh loads"):
		return
	assert_true(_navmesh.get_polygon_count() > 1000, "it has polygons (%d)" % _navmesh.get_polygon_count())
	assert_near(_navmesh.cell_size, 0.25, 0.051, "0.25 m cell (0.3 if the file came out over 20 MB)")
	assert_near(_navmesh.agent_radius, 0.4, 0.0001, "character radius")
	assert_near(_navmesh.agent_height, 1.8, 0.0001, "character height")
	assert_true(FileAccess.get_file_as_bytes(NAVMESH_PATH).size() <= MAX_FILE_BYTES, "does not exceed 20 MB")
	var header: String = FileAccess.get_file_as_string(NAVMESH_PATH).substr(0, 40)
	assert_true(header.begins_with("[gd_resource"), "it is text (.tres), not binary")
	assert_true(NavigationServer3D.map_get_iteration_id(_map) > 0, "the map already has an iteration")
	assert_eq(NavigationServer3D.map_get_regions(_map).size(), 1, "with the mesh region")


func test_every_guard_spawn_reaches_the_walkway_the_ford_and_both_bridges() -> void:
	if not assert_not_null(_fort, "the zone must be instantiated"):
		return
	var walkway: Dictionary = {
		"pasarela norte": _fort.get_node(^"PatrolNorth2").global_position,
		"pasarela sur": _fort.get_node(^"PatrolSouth2").global_position,
		"pasarela oeste": _fort.get_node(^"PatrolNorth3").global_position,
	}
	var outside: Dictionary = {
		"vado": _surface_at(FORD),
		"puente norte": _surface_at(Vector2(0.0, -BRIDGE_Z)),
		"puente sur": _surface_at(Vector2(0.0, BRIDGE_Z)),
	}
	# The bridges are really the deck (higher than the channel) and not the bed.
	assert_true((outside["puente norte"] as Vector3).y > 4.0, "the north bridge's destination is the deck")
	# The walkway is reached by the ramps, without leaving the fort: the link is not needed.
	_check_routes(walkway)
	# The ford and the bridges are outside: they are only reached through the gate's link (which the server
	# creates by RID and activates depending on the gate; here, one like its own).
	_open_gate_link()
	assert_true(await _wait_until_reaches(_guard(1).global_position, outside["vado"]), "the link ends up active")
	_check_routes(outside)


func test_there_is_no_way_out_of_the_fort_with_the_gate_closed() -> void:
	if not assert_not_null(_fort, "the zone must be instantiated"):
		return
	var outside: Vector3 = _surface_at(GATE_OUTSIDE)
	for index: int in range(1, 5):
		var guard: Node3D = _guard(index)
		var path: PackedVector3Array = NavigationServer3D.map_get_path(_map, guard.global_position, outside, true)
		# With no path, the server returns the route to the nearest reachable point: inside.
		var end: Vector3 = path[path.size() - 1] if not path.is_empty() else guard.global_position
		assert_false(_reaches(end, outside), "GuardSpawn%d: does not reach the gate esplanade" % index)
		for point: Vector3 in path:
			var local: Vector3 = _fort.to_local(point)
			assert_true(absf(local.x) < FORT_HALF and absf(local.z) < FORT_HALF,
					"GuardSpawn%d: the route does not leave the fort (it passes through %s)" % [index, local.snapped(Vector3.ONE * 0.1)])
	# And the reverse: from the esplanade the courtyard is not reached.
	var yard: Vector3 = _fort.get_node(^"CaptureCircle").global_position
	var in_path: PackedVector3Array = NavigationServer3D.map_get_path(_map, outside, yard, true)
	var in_end: Vector3 = in_path[in_path.size() - 1] if not in_path.is_empty() else outside
	assert_false(_reaches(in_end, yard), "from outside the circle is not reached with the gate closed")


func test_each_camp_reaches_the_bridge_and_the_ford() -> void:
	if not assert_not_null(_fort, "the zone must be instantiated"):
		return
	var bridge_by_realm: Dictionary = {&"vardheim": Vector2(0.0, -BRIDGE_Z), &"solmarch": Vector2(0.0, BRIDGE_Z)}
	for realm: StringName in bridge_by_realm:
		var spawn: Node3D = Zones.get_spawn_points(_zone, realm)[0]
		for target_name: String in ["puente", "vado", "explanada"]:
			var target: Vector3
			match target_name:
				"puente":
					target = _surface_at(bridge_by_realm[realm])
				"vado":
					target = _surface_at(FORD)
				_:
					target = _surface_at(GATE_OUTSIDE)
			var path: PackedVector3Array = NavigationServer3D.map_get_path(_map, spawn.global_position, target, true)
			if assert_false(path.is_empty(), "%s -> %s: there is a route" % [realm, target_name]):
				assert_true(_reaches(path[path.size() - 1], target), "%s -> %s: it arrives" % [realm, target_name])


## The deep river channel cannot be reached on foot (it is closed by the layer 3 blockers, which go
## into the bake; without them there is a route along the bed): the mesh may cover the bed, but as an island
## that no route from the camps leads to.
func test_the_deep_riverbed_is_not_reachable_on_foot() -> void:
	if not assert_not_null(_fort, "the zone must be instantiated"):
		return
	var spawns: Array[Node3D] = [Zones.get_spawn_points(_zone, &"vardheim")[0], Zones.get_spawn_points(_zone, &"solmarch")[0]]
	for spawn: Node3D in spawns:
		for point: Vector2 in [Vector2(30.0, -62.0), Vector2(30.0, 62.0), Vector2(-45.0, -52.0), Vector2(-45.0, 52.0)]:
			var bed: Vector3 = _surface_at(point)
			var path: PackedVector3Array = NavigationServer3D.map_get_path(_map, spawn.global_position, bed, true)
			var end: Vector3 = path[path.size() - 1] if not path.is_empty() else spawn.global_position
			assert_false(_reaches(end, bed), "from %s the channel is not reached at %s (the route ends at %s)"
					% [spawn.name, point, end.snapped(Vector3.ONE * 0.1)])
	# In contrast the ford, of gravel and 0.3 m of water, is.
	var ford: Vector3 = _surface_at(FORD)
	var to_ford: PackedVector3Array = NavigationServer3D.map_get_path(_map, spawns[0].global_position, ford, true)
	assert_true(not to_ford.is_empty() and _reaches(to_ford[to_ford.size() - 1], ford), "the ford is reached")


## GUE-45: siege bots climb to the walkway along a precomputed route of points (the ramps and the walkway's axis
## from data/routes/vado_gris.tres), which they follow in a straight line. Each leg, from the circle to the post above the gate via
## each ramp, must be walkable according to the NPCs' mesh (MUN-06): the mesh route between its ends arrives and
## is barely longer than the straight leg. And the walkway is at the height the data states.
func test_the_walkway_route_of_the_bots_follows_the_navigation_mesh() -> void:
	if not assert_not_null(_fort, "the zone must be instantiated"):
		return
	var routes: ApproachRoutes = load(ROUTES_PATH) as ApproachRoutes
	if not assert_true(routes != null and routes.has_walkway(), "the routes know the walkway"):
		return
	var post: Vector2 = routes.walkway_post()
	var yard: Vector3 = _fort.get_node(^"CaptureCircle").global_position
	assert_near(_surface_at(post).y, routes.walkway_height, 0.05, "the walkway is at the height of the data")
	assert_near(routes.walkway_height - _surface_at(Vector2(yard.x, yard.z)).y, 3.35, 0.05, "3.35 m above the courtyard")
	var post_offset: float = routes.walkway_offset(post)
	var offsets: PackedFloat32Array = routes.walkway_vertex_offsets()
	for index: int in routes.walkway_ramps.size():
		var ramp: PackedVector2Array = routes.walkway_ramps[index]
		var stops: Array[Vector2] = [Vector2(yard.x, yard.z)]
		stops.append_array(Array(ramp))
		# Along the walkway's axis, from the top of the ramp to the corners up to the post, and the post.
		var top_offset: float = routes.walkway_offset(ramp[ramp.size() - 1])
		var corners: Array[Vector2] = []
		for vertex: int in offsets.size():
			if offsets[vertex] > minf(top_offset, post_offset) + 0.01 and offsets[vertex] < maxf(top_offset, post_offset) - 0.01:
				corners.append(routes.walkway_path[vertex])
		if top_offset > post_offset:
			corners.reverse()
		stops.append_array(corners)
		stops.append(post)
		for i: int in range(1, stops.size()):
			var from: Vector3 = _surface_at(stops[i - 1])
			var to: Vector3 = _surface_at(stops[i])
			var path: PackedVector3Array = NavigationServer3D.map_get_path(_map, from, to, true)
			if not assert_false(path.is_empty(), "ramp %d, leg %d: there is a route" % [index, i]):
				continue
			assert_true(_reaches(path[path.size() - 1], to), "ramp %d, leg %d: it reaches %s (ends at %s)"
					% [index, i, to.snapped(Vector3.ONE * 0.1), path[path.size() - 1].snapped(Vector3.ONE * 0.1)])
			var length: float = 0.0
			for p: int in range(1, path.size()):
				length += path[p - 1].distance_to(path[p])
			var straight: float = from.distance_to(to)
			assert_true(length <= straight * WALKWAY_DETOUR_FACTOR + WALKWAY_DETOUR_MARGIN,
					"ramp %d, leg %d (%s -> %s): the mesh goes almost in a straight line (%.1f m against %.1f)"
					% [index, i, stops[i - 1], stops[i], length, straight])


# --- Helpers ----------------------------------------------------------------------------------

## Waits (up to 120 physics steps) for the map to be built: first for the first
## iteration, which is the only one in which it can be queried without error, and then for it to return a point
## of the mesh (Vardheim's camp) instead of the origin.
func _wait_for_map() -> bool:
	var sample: Vector3 = Vector3(0.0, 6.3, -138.0)
	for _i: int in 120:
		if NavigationServer3D.map_get_iteration_id(_map) > 0 \
				and NavigationServer3D.map_get_closest_point(_map, sample).y > 1.0:
			return true
		await wait_physics_frames()
	return false


## Checks that from each GuardSpawn there is a route that reaches each destination in [param targets]
## (name -> position).
func _check_routes(targets: Dictionary) -> void:
	for index: int in range(1, 5):
		var guard: Node3D = _guard(index)
		for target_name: String in targets:
			var target: Vector3 = targets[target_name]
			var path: PackedVector3Array = NavigationServer3D.map_get_path(_map, guard.global_position, target, true)
			if not assert_false(path.is_empty(), "GuardSpawn%d -> %s: there is a route" % [index, target_name]):
				continue
			var end: Vector3 = path[path.size() - 1]
			assert_true(_reaches(end, target), "GuardSpawn%d -> %s: the route arrives (ends at %s, destination %s)"
					% [index, target_name, end.snapped(Vector3.ONE * 0.1), target.snapped(Vector3.ONE * 0.1)])


func _guard(index: int) -> Node3D:
	return _fort.get_node(NodePath("GuardSpawn%d" % index)) as Node3D


## Two-way link through the gate's doorway (x = -20 in the fort), like the one the
## server creates: from a courtyard point, 2 m from the gate, to another on the esplanade, 2.5 m outside.
func _open_gate_link() -> void:
	_link = NavigationServer3D.link_create()
	NavigationServer3D.link_set_map(_link, _map)
	NavigationServer3D.link_set_start_position(_link, _surface_at(Vector2(-17.5, 0.0)))
	NavigationServer3D.link_set_end_position(_link, _surface_at(Vector2(-23.0, 0.0)))
	NavigationServer3D.link_set_bidirectional(_link, true)
	NavigationServer3D.link_set_enabled(_link, true)


## Waits (up to 120 physics steps) for there to be a route from [param from] that reaches [param to].
func _wait_until_reaches(from: Vector3, to: Vector3) -> bool:
	for _i: int in 120:
		var path: PackedVector3Array = NavigationServer3D.map_get_path(_map, from, to, true)
		if not path.is_empty() and _reaches(path[path.size() - 1], to):
			return true
		await wait_physics_frames()
	return false


func _reaches(end: Vector3, target: Vector3) -> bool:
	return Vector2(end.x - target.x, end.z - target.z).length() <= REACH_XZ and absf(end.y - target.y) <= REACH_Y


## First floor (world layer) hit when going down from above at ([param point].x, .y).
func _surface_at(point: Vector2) -> Vector3:
	var space: PhysicsDirectSpaceState3D = _zone.get_world_3d().direct_space_state
	var from: Vector3 = Vector3(point.x, 60.0, point.y)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.001, -120.0, 0.0),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		fail("there is no floor at %s" % point)
		return Vector3(point.x, 0.0, point.y)
	return hit["position"]
