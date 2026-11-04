extends TestCase
## Tests of the approach routes to the fort (ApproachRoutes, data/routes/vado_gris.tres,
## docs/fuerte.md section 7): the shared resource with the bridge and ford waypoints of each
## realm. Actually walking them with the character and measuring their fairness is done by
## tools/terrain/verify_vado_gris_routes.gd (it takes minutes; this test only checks the data).

const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
## Spawn point of Vardheim and Solmarch that serves as the starting point (first of each realm).
const SPAWN_REACH: float = 8.0
## In front of the fort's gate (west face, x = -20).
const GATE_FRONT: Vector2 = Vector2(-20.0, 0.0)
const GATE_REACH: float = 8.0

var _routes: ApproachRoutes = null


func before_each() -> void:
	_routes = load(ROUTES_PATH) as ApproachRoutes
	assert_not_null(_routes, "%s loads" % ROUTES_PATH)


func test_there_is_a_bridge_and_a_ford_route_for_each_realm() -> void:
	if _routes == null:
		return
	assert_eq(_routes.zone_id, &"vado_gris")
	assert_eq(_routes.get_route_ids(), [ApproachRoutes.BRIDGE, ApproachRoutes.FORD] as Array[StringName])
	for route: StringName in [ApproachRoutes.BRIDGE, ApproachRoutes.FORD]:
		for realm: StringName in [RealmCatalog.VARDHEIM, RealmCatalog.SOLMARCH]:
			assert_true(_routes.has_route(route, realm), "%s/%s exists" % [route, realm])
			assert_true(_routes.get_points(route, realm).size() >= 5, "%s/%s has waypoints" % [route, realm])
	assert_false(_routes.has_route(ApproachRoutes.BRIDGE, RealmCatalog.ASKARRA), "Askarra does not enter Vado Gris")
	assert_true(_routes.get_points(&"nada", RealmCatalog.VARDHEIM).is_empty())
	assert_eq(ApproachRoutes.key_for(&"ford", &"solmarch"), "ford/solmarch")


func test_solmarch_routes_are_the_exact_mirror_of_vardheim() -> void:
	if _routes == null:
		return
	for route: StringName in _routes.get_route_ids():
		var north: PackedVector2Array = _routes.get_points(route, RealmCatalog.VARDHEIM)
		var south: PackedVector2Array = _routes.get_points(route, RealmCatalog.SOLMARCH)
		if not assert_eq(south.size(), north.size(), "%s: same number of points" % route):
			continue
		for i: int in north.size():
			assert_near(south[i].x, north[i].x, 0.0001, "%s %d: same x" % [route, i])
			assert_near(south[i].y, -north[i].y, 0.0001, "%s %d: mirrored z" % [route, i])
		assert_near(_routes.get_length(route, RealmCatalog.SOLMARCH), _routes.get_length(route, RealmCatalog.VARDHEIM), 0.001,
				"%s: same length" % route)


func test_each_route_goes_from_its_camp_to_the_front_of_the_gate() -> void:
	if _routes == null:
		return
	var path: String = Zones.get_scene_path(&"vado_gris")
	for realm: StringName in [RealmCatalog.VARDHEIM, RealmCatalog.SOLMARCH]:
		var side: float = -1.0 if realm == RealmCatalog.VARDHEIM else 1.0
		for route: StringName in _routes.get_route_ids():
			var points: PackedVector2Array = _routes.get_points(route, realm)
			# It leaves from its realm's camp (|z| > 100, on its side) and ends in front of the gate.
			assert_true(points[0].y * side > 100.0, "%s/%s leaves from its camp" % [route, realm])
			assert_true(points[points.size() - 1].distance_to(GATE_FRONT) < GATE_REACH, "%s/%s ends in front of the gate" % [route, realm])
			for i: int in range(1, points.size()):
				assert_true(points[i].distance_to(points[i - 1]) > 1.0, "%s/%s: points %d and %d are not repeated" % [route, realm, i - 1, i])
				assert_true(absf(points[i].x) < 150.0 and absf(points[i].y) < 150.0, "%s/%s: inside the playable area" % [route, realm])
	assert_false(path.is_empty())


func test_the_bridge_is_shorter_than_the_ford_and_passes_over_the_bridge() -> void:
	if _routes == null:
		return
	var bridge: float = _routes.get_length(ApproachRoutes.BRIDGE, RealmCatalog.VARDHEIM)
	var ford: float = _routes.get_length(ApproachRoutes.FORD, RealmCatalog.VARDHEIM)
	assert_true(bridge < ford, "the bridge is the direct route (%.0f m versus %.0f m)" % [bridge, ford])
	# The bridge passes through the center of the board (x = 0, z = -62) and the ford through its center (x = -62, z = 0).
	var crosses_bridge: bool = false
	for point: Vector2 in _routes.get_points(ApproachRoutes.BRIDGE, RealmCatalog.VARDHEIM):
		if point.distance_to(Vector2(0.0, -62.0)) < 1.0:
			crosses_bridge = true
	assert_true(crosses_bridge, "the bridge route passes through the north bridge")
	var crosses_ford: bool = false
	for point: Vector2 in _routes.get_points(ApproachRoutes.FORD, RealmCatalog.VARDHEIM):
		if point.distance_to(Vector2(-62.0, 0.0)) < 1.0:
			crosses_ford = true
	assert_true(crosses_ford, "the ford route passes through the ford")


func test_lookup_helpers() -> void:
	if _routes == null:
		return
	var by_code: PackedVector2Array = _routes.get_points_for_code(ApproachRoutes.FORD, NetProtocol.Realm.SOLMARCH)
	assert_eq(by_code, _routes.get_points(ApproachRoutes.FORD, RealmCatalog.SOLMARCH), "by network code")
	assert_true(_routes.get_points_for_code(ApproachRoutes.FORD, 0).is_empty(), "the Hollow has no route")
	var points: PackedVector2Array = _routes.get_points(ApproachRoutes.BRIDGE, RealmCatalog.VARDHEIM)
	assert_eq(_routes.get_nearest_index(ApproachRoutes.BRIDGE, RealmCatalog.VARDHEIM, points[3] + Vector2(0.4, 0.3)), 3)
	assert_eq(_routes.get_nearest_index(&"nada", RealmCatalog.VARDHEIM, Vector2.ZERO), -1)
	var custom := ApproachRoutes.new()
	custom.set_points(&"a", &"vardheim", PackedVector2Array([Vector2(0, 0), Vector2(3, 4)]))
	assert_near(custom.get_length(&"a", &"vardheim"), 5.0, 0.0001)
	assert_eq(custom.get_route_ids(), [&"a"] as Array[StringName])


func test_the_walkway_goes_over_the_gate_from_ramp_to_ramp() -> void:
	# GUE-45: the fort's walkway (its height, its axis and the two ramps) for the bots that guard it.
	if _routes == null:
		return
	assert_true(_routes.has_walkway(), "the routes know the walkway")
	assert_near(_routes.walkway_height, 13.55, 0.001, "3.35 m above the plateau (10.2 m)")
	var path: PackedVector2Array = _routes.walkway_path
	assert_eq(path.size(), 4, "from the top of the north ramp to that of the south, through the two corners of the west face")
	assert_near(_routes.walkway_length(), 25.77 + 37.54 + 25.77, 0.01)
	var post: Vector2 = _routes.walkway_post()
	assert_true(post.distance_to(Vector2(-18.77, 0.0)) < 0.01, "the post, above the gate (%s)" % post)
	assert_true(post.distance_to(GATE_FRONT) < 1.5, "1.2 m from it, inside the palisade")
	assert_eq(_routes.walkway_ramps.size(), 2, "two ramps")
	for index: int in _routes.walkway_ramps.size():
		var ramp: PackedVector2Array = _routes.walkway_ramps[index]
		var top: Vector2 = ramp[ramp.size() - 1]
		assert_near(_routes.walkway_distance(top), 0.0, 0.001, "ramp %d: its top is on the axis" % index)
		assert_true(ramp.size() >= 3, "ramp %d: courtyard points, the foot and the top" % index)
		var tower_free: bool = true
		for i: int in range(1, ramp.size()):
			# No stretch crosses the tower (6 x 6 m at the fort's center, with the capsule).
			var a: Vector2 = ramp[i - 1]
			var b: Vector2 = ramp[i]
			for step: int in 21:
				var p: Vector2 = a.lerp(b, float(step) / 20.0)
				if absf(p.x) < 3.4 and absf(p.y) < 3.4:
					tower_free = false
		assert_true(tower_free, "ramp %d: without colliding with the tower" % index)
		# Nor does it cross the capture circle: whoever climbs the walkway does not contest the capture in passing.
		var closest: float = INF
		for i: int in range(1, ramp.size()):
			var near: Vector2 = Geometry2D.get_closest_point_to_segment(_routes.circle_point, ramp[i - 1], ramp[i])
			closest = minf(closest, near.distance_to(_routes.circle_point))
		assert_true(closest > _routes.circle_radius + 1.0, "ramp %d: far from the circle (%.1f m from its center)" % [index, closest])
	var north: PackedVector2Array = _routes.walkway_ramps[0]
	var south: PackedVector2Array = _routes.walkway_ramps[1]
	for i: int in north.size():
		assert_near(south[i].x, north[i].x, 0.0001, "the south ramp is the mirror of the north one")
		assert_near(south[i].y, -north[i].y, 0.0001)


func test_walkway_helpers() -> void:
	var routes := ApproachRoutes.new()
	assert_false(routes.has_walkway(), "with no data there is no walkway")
	assert_eq(routes.walkway_distance(Vector2.ZERO), INF)
	assert_eq(routes.walkway_post(), Vector2.ZERO)
	routes.gate_point = Vector2(-10.0, 4.0)
	routes.circle_point = Vector2(0.0, 4.0)
	routes.circle_radius = 3.0
	routes.walkway_height = 5.0
	routes.walkway_path = PackedVector2Array([Vector2(0.0, 0.0), Vector2(-9.0, 0.0), Vector2(-9.0, 8.0)])
	var ramps: Array[PackedVector2Array] = [PackedVector2Array([Vector2(2.0, 3.0), Vector2(0.0, 0.0)])]
	routes.walkway_ramps = ramps
	assert_true(routes.has_walkway())
	assert_near(routes.walkway_length(), 17.0, 0.0001)
	assert_eq(routes.walkway_vertex_offsets(), PackedFloat32Array([0.0, 9.0, 17.0]))
	assert_near(routes.walkway_offset(Vector2(-4.0, 0.5)), 4.0, 0.0001, "along the first stretch")
	assert_near(routes.walkway_offset(Vector2(-8.5, 6.0)), 15.0, 0.0001, "and the second")
	assert_near(routes.walkway_distance(Vector2(-4.0, 0.5)), 0.5, 0.0001)
	assert_eq(routes.walkway_point(4.0), Vector2(-4.0, 0.0))
	assert_eq(routes.walkway_point(12.0), Vector2(-9.0, 3.0))
	assert_eq(routes.walkway_point(-3.0), Vector2(0.0, 0.0), "trimmed at the start")
	assert_eq(routes.walkway_point(40.0), Vector2(-9.0, 8.0), "and at the end")
	assert_eq(routes.walkway_post(), Vector2(-9.0, 4.0), "the axis point closest to the gate")
