class_name NpcNavigation
extends RefCounted
## NPC navigation on the server (docs/fortress.md, section 4.1; MUN-06).
## [br][br]
## Creates its own [NavigationServer3D] map (with synchronous iterations: nothing from the scene's map, which
## the server does not have), gives it the region of the baked mesh ([code]tools/bake_navmesh.gd[/code], with the
## fort's gate [b]closed[/b]) and, for each gate, a link through the doorway created by RID. Afterwards it
## answers [method get_path] with the route of an agent of a given realm.
## [br][br]
## [b]Navigation layers.[/b] The region is on layer [constant REGION_LAYER] (all queries look at it). The gate's link
## is always active, but on the layer of the [b]owning[/b] realm ([method layer_of_realm]); each query filters with
## the layer of its realm ([method query_layers]), so an agent only crosses the link if the gate physically lets it
## through: the owner (and the Hollow, with the fort neutral, which have no realm layer in their collision mask) can,
## the others cannot. With the gate broken, the link is on everyone's layers. The filter is immediate (it does not
## wait for any map iteration).
## [br][br]
## [b]Waiting for the map.[/b] Verified in Godot 4.7.2: the first map iteration comes out empty (the region's
## commands are applied afterwards, even if synchronous) and good routes arrive a few physics steps later;
## querying the map before its first iteration logs an engine error. That is why [method poll] considers the map
## ready only when a test query returns a point of the mesh, and [method get_path] returns an empty route until then.
## Whoever runs it calls [method poll] on every tick until it returns true.
## [br][br]
## It frees its RIDs with [method dispose] (it must be called: an object that is destroyed in its destructor cannot
## call its own methods).

## Region layer: included by all queries.
const REGION_LAYER: int = 1
## Realm layers: the neutral side's (the Hollow) and each realm's (1 to 3) are bits 1 to 4.
const REALM_LAYER_SHIFT: int = 1
const REALM_LAYERS_MASK: int = 0b11110
## Points of a gate's link relative to its origin (center of the doorway at ground level, interior toward +X):
## 2.5 m inside and 3 m outside, clear of the gate's thickness and the agent's radius.
const GATE_INSIDE_OFFSET: Vector3 = Vector3(2.5, 0.0, 0.0)
const GATE_OUTSIDE_OFFSET: Vector3 = Vector3(-3.0, 0.0, 0.0)
## Distance (m) within which the test query must return the test vertex for the map to be considered ready.
const PROBE_TOLERANCE: float = 1.0
## A route reaches its destination if it ends within this distance (m) horizontally and vertically.
const REACH_XZ: float = 1.0
const REACH_Y: float = 1.5

## A link through a gate's doorway.
class GateLink:
	extends RefCounted

	var id: StringName = &""
	## Point on the inside and the outside, as requested (they are projected onto the mesh when the link is
	## created).
	var inside: Vector3 = Vector3.ZERO
	var outside: Vector3 = Vector3.ZERO
	var rid: RID = RID()
	var owner_realm: int = 0
	var broken: bool = false

var _map: RID = RID()
var _region: RID = RID()
var _links: Dictionary[StringName, GateLink] = {}
var _probe: Vector3 = Vector3.ZERO
var _ready: bool = false
var _params: NavigationPathQueryParameters3D = NavigationPathQueryParameters3D.new()
var _result: NavigationPathQueryResult3D = NavigationPathQueryResult3D.new()
var _paths_computed: int = 0


## Navigation layer of realm [param realm] (network code; 0 = neutral, the Hollow): a bit from 1 to 4.
static func layer_of_realm(realm: int) -> int:
	return 1 << (REALM_LAYER_SHIFT + clampi(realm, 0, 3))


## Layers an agent of realm [param realm] queries with: the region's and its realm's.
static func query_layers(realm: int) -> int:
	return REGION_LAYER | layer_of_realm(realm)


## true if route [param path] ends within [constant REACH_XZ] (horizontally) and [constant REACH_Y]
## (vertically) of [param target].
static func path_reaches(path: PackedVector3Array, target: Vector3) -> bool:
	if path.is_empty():
		return false
	var end: Vector3 = path[path.size() - 1]
	return Vector2(end.x - target.x, end.z - target.z).length() <= REACH_XZ \
			and absf(end.y - target.y) <= REACH_Y


## Creates the map and the region with the mesh [param navmesh] (at position [param region_transform]). Returns
## false if there is no mesh or it has no polygons. Can only be called once.
func setup(navmesh: NavigationMesh, region_transform: Transform3D = Transform3D.IDENTITY) -> bool:
	if _map.is_valid() or navmesh == null or navmesh.get_polygon_count() == 0 \
			or navmesh.get_vertices().is_empty():
		return false
	_probe = region_transform * navmesh.get_vertices()[0]
	_map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_cell_size(_map, navmesh.cell_size)
	NavigationServer3D.map_set_cell_height(_map, navmesh.cell_height)
	NavigationServer3D.map_set_up(_map, Vector3.UP)
	NavigationServer3D.map_set_use_async_iterations(_map, false)
	NavigationServer3D.map_set_active(_map, true)
	_region = NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(_region, _map)
	NavigationServer3D.region_set_navigation_layers(_region, REGION_LAYER)
	NavigationServer3D.region_set_navigation_mesh(_region, navmesh)
	NavigationServer3D.region_set_transform(_region, region_transform)
	NavigationServer3D.region_set_enabled(_region, true)
	return true


## Adds the link through the doorway of gate [param id]: from [param inside] (inside the fort) to
## [param outside], in both directions. Its endpoints are projected onto the mesh when the map is ready
## (it cannot be queried before). The link starts on the Hollow's layer (neutral fort, gate intact).
func add_gate_link(id: StringName, inside: Vector3, outside: Vector3) -> void:
	if not _map.is_valid() or _links.has(id):
		return
	var link := GateLink.new()
	link.id = id
	link.inside = inside
	link.outside = outside
	_links[id] = link
	if _ready:
		_create_link(link)


## Like [method add_gate_link] for a gate whose origin is at [param gate_transform] (the center of the doorway at
## ground level, with the fort's interior toward +X): [constant GATE_INSIDE_OFFSET] and
## [constant GATE_OUTSIDE_OFFSET] give the two endpoints.
func add_gate_link_at(id: StringName, gate_transform: Transform3D) -> void:
	add_gate_link(id, gate_transform * GATE_INSIDE_OFFSET, gate_transform * GATE_OUTSIDE_OFFSET)


## Sets the state of gate [param id]: fort owner (0 = neutral) and whether it is broken. The link moves to
## the owner's layer (to everyone's if broken); the query filter lets only those agents through. Can be
## called before the map is ready.
func set_gate_state(id: StringName, owner_realm: int, broken: bool) -> void:
	var link: GateLink = _links.get(id)
	if link == null:
		return
	link.owner_realm = owner_realm
	link.broken = broken
	if link.rid.is_valid():
		NavigationServer3D.link_set_navigation_layers(link.rid, _link_layers(link))


## Navigation layers that the link of gate [param id] has now (0 if it does not exist).
func get_gate_layers(id: StringName) -> int:
	var link: GateLink = _links.get(id)
	return _link_layers(link) if link != null else 0


## Checks whether the map already gives real routes (a test query returns a point of the mesh) and, the
## first time it does, creates the gate links. Returns true if it is ready. Cheap: it queries
## nothing before the map's first iteration (it would log an engine error).
func poll() -> bool:
	if _ready:
		return true
	if not _map.is_valid() or NavigationServer3D.map_get_iteration_id(_map) == 0:
		return false
	if NavigationServer3D.map_get_closest_point(_map, _probe).distance_to(_probe) > PROBE_TOLERANCE:
		return false
	_ready = true
	for link: GateLink in _links.values():
		_create_link(link)
	return true


## true if the map has already accepted a test query ([method poll]).
func is_ready() -> bool:
	return _ready


## Route from [param from] to [param to] for an agent of realm [param realm] (network code; 0 = Hollow): the
## list of route points, or empty if the map is not ready yet. If there is no path, it ends at the reachable
## point closest to the destination ([method path_reaches] says whether it truly arrives).
func get_path(from: Vector3, to: Vector3, realm: int) -> PackedVector3Array:
	if not _ready:
		return PackedVector3Array()
	_params.map = _map
	_params.start_position = from
	_params.target_position = to
	_params.navigation_layers = query_layers(realm)
	_paths_computed += 1
	NavigationServer3D.query_path(_params, _result)
	return _result.path


## The mesh point closest to [param position], or the position itself if the map is not ready.
func closest_point(position: Vector3) -> Vector3:
	if not _ready:
		return position
	return NavigationServer3D.map_get_closest_point(_map, position)


## Routes computed since it came into existence (for measuring).
func get_paths_computed() -> int:
	return _paths_computed


## The navigation map (RID), for anyone who needs finer queries; invalid before [method setup].
func get_map() -> RID:
	return _map


## Frees each gate's link, the region and the map. Can be called more than once.
func dispose() -> void:
	for link: GateLink in _links.values():
		if link.rid.is_valid():
			NavigationServer3D.free_rid(link.rid)
			link.rid = RID()
	_links.clear()
	if _region.is_valid():
		NavigationServer3D.free_rid(_region)
		_region = RID()
	if _map.is_valid():
		NavigationServer3D.free_rid(_map)
		_map = RID()
	_ready = false


func _create_link(link: GateLink) -> void:
	link.rid = NavigationServer3D.link_create()
	NavigationServer3D.link_set_map(link.rid, _map)
	NavigationServer3D.link_set_start_position(link.rid,
			NavigationServer3D.map_get_closest_point(_map, link.inside))
	NavigationServer3D.link_set_end_position(link.rid,
			NavigationServer3D.map_get_closest_point(_map, link.outside))
	NavigationServer3D.link_set_bidirectional(link.rid, true)
	NavigationServer3D.link_set_navigation_layers(link.rid, _link_layers(link))
	NavigationServer3D.link_set_enabled(link.rid, true)


# Layers of the link: all realms' if the gate is broken; otherwise, the owner's.
func _link_layers(link: GateLink) -> int:
	return REALM_LAYERS_MASK if link.broken else layer_of_realm(link.owner_realm)
