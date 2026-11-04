class_name ApproachRoutes
extends Resource
## Approach routes to a fort (docs/fortress.md, section 7), as shared data: the waypoints (x, z) of
## each route and each realm, from its spawn point to the esplanade in front of the gate. They are
## followed by the siege bots ([code]BotBrain[/code], the siege pattern) and checked by
## [code]tools/terrain/verify_vado_gris_routes.gd[/code], which walks each one with the real
## character.
## [br][br]
## Vado Gris data in [code]data/routes/vado_gris.tres[/code], written by
## [code]tools/terrain/export_vado_gris_routes.gd[/code]: two routes, the [constant BRIDGE] (direct
## and narrow, over the realm's own bridge) and the [constant FORD] (wide and exposed, through the
## ford), for Vardheim and for Solmarch (the mirror z -> -z).
## [br][br]
## The points are 2D (horizontal plane): whoever follows them knows at what height the ground is,
## and bots that do not simulate (SwarmBot) walk in a straight line from one point to the next.
## [br][br]
## Since GUE-45 it also stores the fort's walkway ([member walkway_height], [member walkway_path]
## and [member walkway_ramps]) which the siege bots guarding it climb, with its calculations along
## its axis ([method walkway_offset], [method walkway_point], [method walkway_post]...).
## [br][br]
## Shared: depends on neither the client nor the server.

## Direct, narrow route: camp, own bridge, hillside, fort corner and gate.
const BRIDGE: StringName = &"bridge"
## Wide, exposed route: camp, plain on the west flank, village, ford and gate.
const FORD: StringName = &"ford"

## Zone the routes belong to.
@export var zone_id: StringName = &""
## Where the fort they lead to is, on the horizontal plane (x, z): the center of its gate opening,
## the center of its capture circle and the circle's radius. Bots that do not load the zone
## ([code]SwarmBot[/code]) have no other way to know it ([method SiegeView.set_places_from_routes]);
## the exporter writes them with the zone's constants and [code]test_siege_zone[/code] checks that
## they match the scene's markers. (0, 0) and 0 = unknown.
@export var gate_point: Vector2 = Vector2.ZERO
@export var circle_point: Vector2 = Vector2.ZERO
@export var circle_radius: float = 0.0
## Size of the fort's enclosure (F6b), measured from the gate: [code]x[/code] is the depth (from
## the gate to the opposite wall, along the gate's axis toward the circle) and [code]y[/code] the
## width (the gate in the middle of its wall). With it a bot knows whether it is inside the
## palisade or pressed against it on the outside ([method SiegeView.is_inside_enclosure]).
## (0, 0) = unknown.
@export var enclosure_size: Vector2 = Vector2.ZERO
## Waypoints (x, z) of each route and realm, with the key [code]"<route>/<realm>"[/code] (for
## example [code]"bridge/vardheim"[/code]); see [method key_for].
@export var points: Dictionary[String, PackedVector2Array] = {}
## Fort walkway (GUE-45): height (world y) of its floor. 0 = unknown and bots do not climb.
@export var walkway_height: float = 0.0
## Axis of the walkway (x, z), along which the bots guarding it walk: from the top of one ramp to
## the top of the other passing over the gate. The walkway is 2 m wide and has no inner railing:
## anyone straying from the axis by more than about 0.6 m falls into the courtyard.
@export var walkway_path: PackedVector2Array = PackedVector2Array()
## The walkway's ramps, each as an (x, z) route from the courtyard to its top: the courtyard points
## by which its foot is reached without hitting the tower, the foot aligned with the ramp and the
## top (the last point, over [member walkway_path]). They are checked by
## [code]tests/test_navmesh.gd[/code] with the NPC navigation mesh (MUN-06) and walked with the
## real character by [code]tools/terrain/verify_vado_gris_routes.gd[/code].
@export var walkway_ramps: Array[PackedVector2Array] = []


## Key of [member points] for route [param route] of realm [param realm] ([RealmCatalog] id, for
## example [code]&"vardheim"[/code]).
static func key_for(route: StringName, realm: StringName) -> String:
	return "%s/%s" % [route, realm]


## Stores the points of [param route] for [param realm].
func set_points(route: StringName, realm: StringName, route_points: PackedVector2Array) -> void:
	points[key_for(route, realm)] = route_points


## Waypoints (x, z) of [param route] for [param realm]; empty if that route does not exist.
func get_points(route: StringName, realm: StringName) -> PackedVector2Array:
	return points.get(key_for(route, realm), PackedVector2Array())


## Same as [method get_points] with the realm's network code ([constant RealmCatalog.REALM_IDS]).
func get_points_for_code(route: StringName, realm_code: int) -> PackedVector2Array:
	return get_points(route, RealmCatalog.id_of_code(realm_code))


## true if the resource knows where the fort's gate and circle are.
func has_places() -> bool:
	return circle_radius > 0.0


## true if there is a route [param route] for [param realm].
func has_route(route: StringName, realm: StringName) -> bool:
	return points.has(key_for(route, realm))


## Ids of the routes that exist (without repeats), sorted.
func get_route_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for key: String in points:
		var route: StringName = StringName(key.get_slice("/", 0))
		if not ids.has(route):
			ids.append(route)
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return ids


## Length (m) of a straight route between its points; 0 if it does not exist.
func get_length(route: StringName, realm: StringName) -> float:
	var route_points: PackedVector2Array = get_points(route, realm)
	var length: float = 0.0
	for i: int in range(1, route_points.size()):
		length += route_points[i - 1].distance_to(route_points[i])
	return length


## true if the resource knows where the fort's walkway is and how to climb it (GUE-45).
func has_walkway() -> bool:
	return walkway_height != 0.0 and walkway_path.size() >= 2 and not walkway_ramps.is_empty()


## Length (m) of the walkway's axis.
func walkway_length() -> float:
	var length: float = 0.0
	for i: int in range(1, walkway_path.size()):
		length += walkway_path[i - 1].distance_to(walkway_path[i])
	return length


## Distance (m, in the plane) from [param point] (x, z) to the walkway's axis; INF without a
## walkway.
func walkway_distance(point: Vector2) -> float:
	if walkway_path.size() < 2:
		return INF
	return point.distance_to(walkway_point(walkway_offset(point)))


## Where [param point] (x, z) falls along the walkway's axis: the meters from its first point to the
## axis point nearest to it. 0 without a walkway.
func walkway_offset(point: Vector2) -> float:
	var best_distance: float = INF
	var best_offset: float = 0.0
	var walked: float = 0.0
	for i: int in range(1, walkway_path.size()):
		var a: Vector2 = walkway_path[i - 1]
		var b: Vector2 = walkway_path[i]
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(point, a, b)
		var distance: float = point.distance_to(closest)
		if distance < best_distance:
			best_distance = distance
			best_offset = walked + a.distance_to(closest)
		walked += a.distance_to(b)
	return best_offset


## The point (x, z) on the walkway's axis at [param offset] meters from its first point (clamped to
## its ends).
func walkway_point(offset: float) -> Vector2:
	if walkway_path.is_empty():
		return Vector2.ZERO
	var remaining: float = maxf(offset, 0.0)
	for i: int in range(1, walkway_path.size()):
		var length: float = walkway_path[i - 1].distance_to(walkway_path[i])
		if remaining <= length:
			return walkway_path[i - 1].lerp(walkway_path[i], remaining / length) if length > 0.0 else walkway_path[i]
		remaining -= length
	return walkway_path[walkway_path.size() - 1]


## The meters from the first point of the walkway's axis to each of its points (the first, 0).
func walkway_vertex_offsets() -> PackedFloat32Array:
	var offsets := PackedFloat32Array()
	var walked: float = 0.0
	for i: int in walkway_path.size():
		if i > 0:
			walked += walkway_path[i - 1].distance_to(walkway_path[i])
		offsets.append(walked)
	return offsets


## The walkway's post (x, z): the point on its axis nearest the gate, above it. Vector2.ZERO
## without a walkway or without a gate.
func walkway_post() -> Vector2:
	if walkway_path.size() < 2 or not has_places():
		return Vector2.ZERO
	return walkway_point(walkway_offset(gate_point))


## Index of the point of [param route] for [param realm] nearest to [param position] (x, z), or -1
## if there is no route. Used to resume the route from wherever one is.
func get_nearest_index(route: StringName, realm: StringName, position: Vector2) -> int:
	var route_points: PackedVector2Array = get_points(route, realm)
	var best: int = -1
	var best_distance: float = INF
	for i: int in route_points.size():
		var distance: float = route_points[i].distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best
