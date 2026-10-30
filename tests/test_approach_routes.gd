extends TestCase
## Pruebas de las rutas de aproximación al fuerte (ApproachRoutes, data/routes/vado_gris.tres,
## docs/fuerte.md sección 7): el recurso compartido con los puntos del puente y del vado de cada
## reino. Recorrerlas de verdad con el personaje y medir su equidad lo hace
## tools/terrain/verify_vado_gris_routes.gd (tarda minutos; esta prueba solo comprueba los datos).

const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
## Punto de aparición de Vardheim y Solmarch que sirve de salida (primero de cada reino).
const SPAWN_REACH: float = 8.0
## Delante de la puerta del fuerte (cara oeste, x = -20).
const GATE_FRONT: Vector2 = Vector2(-20.0, 0.0)
const GATE_REACH: float = 8.0

var _routes: ApproachRoutes = null


func before_each() -> void:
	_routes = load(ROUTES_PATH) as ApproachRoutes
	assert_not_null(_routes, "se carga %s" % ROUTES_PATH)


func test_there_is_a_bridge_and_a_ford_route_for_each_realm() -> void:
	if _routes == null:
		return
	assert_eq(_routes.zone_id, &"vado_gris")
	assert_eq(_routes.get_route_ids(), [ApproachRoutes.BRIDGE, ApproachRoutes.FORD] as Array[StringName])
	for route: StringName in [ApproachRoutes.BRIDGE, ApproachRoutes.FORD]:
		for realm: StringName in [RealmCatalog.VARDHEIM, RealmCatalog.SOLMARCH]:
			assert_true(_routes.has_route(route, realm), "%s/%s existe" % [route, realm])
			assert_true(_routes.get_points(route, realm).size() >= 5, "%s/%s tiene puntos de paso" % [route, realm])
	assert_false(_routes.has_route(ApproachRoutes.BRIDGE, RealmCatalog.ASKARRA), "Askarra no entra en el Vado Gris")
	assert_true(_routes.get_points(&"nada", RealmCatalog.VARDHEIM).is_empty())
	assert_eq(ApproachRoutes.key_for(&"ford", &"solmarch"), "ford/solmarch")


func test_solmarch_routes_are_the_exact_mirror_of_vardheim() -> void:
	if _routes == null:
		return
	for route: StringName in _routes.get_route_ids():
		var north: PackedVector2Array = _routes.get_points(route, RealmCatalog.VARDHEIM)
		var south: PackedVector2Array = _routes.get_points(route, RealmCatalog.SOLMARCH)
		if not assert_eq(south.size(), north.size(), "%s: mismo número de puntos" % route):
			continue
		for i: int in north.size():
			assert_near(south[i].x, north[i].x, 0.0001, "%s %d: misma x" % [route, i])
			assert_near(south[i].y, -north[i].y, 0.0001, "%s %d: z reflejada" % [route, i])
		assert_near(_routes.get_length(route, RealmCatalog.SOLMARCH), _routes.get_length(route, RealmCatalog.VARDHEIM), 0.001,
				"%s: misma longitud" % route)


func test_each_route_goes_from_its_camp_to_the_front_of_the_gate() -> void:
	if _routes == null:
		return
	var path: String = Zones.get_scene_path(&"vado_gris")
	for realm: StringName in [RealmCatalog.VARDHEIM, RealmCatalog.SOLMARCH]:
		var side: float = -1.0 if realm == RealmCatalog.VARDHEIM else 1.0
		for route: StringName in _routes.get_route_ids():
			var points: PackedVector2Array = _routes.get_points(route, realm)
			# Sale del campamento de su reino (|z| > 100, de su lado) y acaba delante de la puerta.
			assert_true(points[0].y * side > 100.0, "%s/%s sale de su campamento" % [route, realm])
			assert_true(points[points.size() - 1].distance_to(GATE_FRONT) < GATE_REACH, "%s/%s acaba delante de la puerta" % [route, realm])
			for i: int in range(1, points.size()):
				assert_true(points[i].distance_to(points[i - 1]) > 1.0, "%s/%s: los puntos %d y %d no se repiten" % [route, realm, i - 1, i])
				assert_true(absf(points[i].x) < 150.0 and absf(points[i].y) < 150.0, "%s/%s: dentro del área jugable" % [route, realm])
	assert_false(path.is_empty())


func test_the_bridge_is_shorter_than_the_ford_and_passes_over_the_bridge() -> void:
	if _routes == null:
		return
	var bridge: float = _routes.get_length(ApproachRoutes.BRIDGE, RealmCatalog.VARDHEIM)
	var ford: float = _routes.get_length(ApproachRoutes.FORD, RealmCatalog.VARDHEIM)
	assert_true(bridge < ford, "el puente es la ruta directa (%.0f m frente a %.0f m)" % [bridge, ford])
	# El puente pasa por el centro del tablero (x = 0, z = -62) y el vado por su centro (x = -62, z = 0).
	var crosses_bridge: bool = false
	for point: Vector2 in _routes.get_points(ApproachRoutes.BRIDGE, RealmCatalog.VARDHEIM):
		if point.distance_to(Vector2(0.0, -62.0)) < 1.0:
			crosses_bridge = true
	assert_true(crosses_bridge, "la ruta del puente pasa por el puente norte")
	var crosses_ford: bool = false
	for point: Vector2 in _routes.get_points(ApproachRoutes.FORD, RealmCatalog.VARDHEIM):
		if point.distance_to(Vector2(-62.0, 0.0)) < 1.0:
			crosses_ford = true
	assert_true(crosses_ford, "la ruta del vado pasa por el vado")


func test_lookup_helpers() -> void:
	if _routes == null:
		return
	var by_code: PackedVector2Array = _routes.get_points_for_code(ApproachRoutes.FORD, NetProtocol.Realm.SOLMARCH)
	assert_eq(by_code, _routes.get_points(ApproachRoutes.FORD, RealmCatalog.SOLMARCH), "por código de red")
	assert_true(_routes.get_points_for_code(ApproachRoutes.FORD, 0).is_empty(), "los Huecos no tienen ruta")
	var points: PackedVector2Array = _routes.get_points(ApproachRoutes.BRIDGE, RealmCatalog.VARDHEIM)
	assert_eq(_routes.get_nearest_index(ApproachRoutes.BRIDGE, RealmCatalog.VARDHEIM, points[3] + Vector2(0.4, 0.3)), 3)
	assert_eq(_routes.get_nearest_index(&"nada", RealmCatalog.VARDHEIM, Vector2.ZERO), -1)
	var custom := ApproachRoutes.new()
	custom.set_points(&"a", &"vardheim", PackedVector2Array([Vector2(0, 0), Vector2(3, 4)]))
	assert_near(custom.get_length(&"a", &"vardheim"), 5.0, 0.0001)
	assert_eq(custom.get_route_ids(), [&"a"] as Array[StringName])


func test_the_walkway_goes_over_the_gate_from_ramp_to_ramp() -> void:
	# GUE-45: la pasarela del fuerte (su altura, su eje y las dos rampas) para los bots que la guardan.
	if _routes == null:
		return
	assert_true(_routes.has_walkway(), "las rutas conocen la pasarela")
	assert_near(_routes.walkway_height, 13.55, 0.001, "3,35 m sobre la meseta (10,2 m)")
	var path: PackedVector2Array = _routes.walkway_path
	assert_eq(path.size(), 4, "de la cima de la rampa norte a la de la sur, por las dos esquinas de la cara oeste")
	assert_near(_routes.walkway_length(), 25.77 + 37.54 + 25.77, 0.01)
	var post: Vector2 = _routes.walkway_post()
	assert_true(post.distance_to(Vector2(-18.77, 0.0)) < 0.01, "el puesto, encima de la puerta (%s)" % post)
	assert_true(post.distance_to(GATE_FRONT) < 1.5, "a 1,2 m de ella, por dentro de la empalizada")
	assert_eq(_routes.walkway_ramps.size(), 2, "dos rampas")
	for index: int in _routes.walkway_ramps.size():
		var ramp: PackedVector2Array = _routes.walkway_ramps[index]
		var top: Vector2 = ramp[ramp.size() - 1]
		assert_near(_routes.walkway_distance(top), 0.0, 0.001, "rampa %d: su cima está en el eje" % index)
		assert_true(ramp.size() >= 3, "rampa %d: puntos del patio, el pie y la cima" % index)
		var tower_free: bool = true
		for i: int in range(1, ramp.size()):
			# Ningún tramo cruza la torre (6 x 6 m en el centro del fuerte, con la cápsula).
			var a: Vector2 = ramp[i - 1]
			var b: Vector2 = ramp[i]
			for step: int in 21:
				var p: Vector2 = a.lerp(b, float(step) / 20.0)
				if absf(p.x) < 3.4 and absf(p.y) < 3.4:
					tower_free = false
		assert_true(tower_free, "rampa %d: sin chocar con la torre" % index)
		# Ni cruza el círculo de captura: quien sube a la pasarela no disputa la captura al pasar.
		var closest: float = INF
		for i: int in range(1, ramp.size()):
			var near: Vector2 = Geometry2D.get_closest_point_to_segment(_routes.circle_point, ramp[i - 1], ramp[i])
			closest = minf(closest, near.distance_to(_routes.circle_point))
		assert_true(closest > _routes.circle_radius + 1.0, "rampa %d: lejos del círculo (%.1f m de su centro)" % [index, closest])
	var north: PackedVector2Array = _routes.walkway_ramps[0]
	var south: PackedVector2Array = _routes.walkway_ramps[1]
	for i: int in north.size():
		assert_near(south[i].x, north[i].x, 0.0001, "la rampa sur es el reflejo de la norte")
		assert_near(south[i].y, -north[i].y, 0.0001)


func test_walkway_helpers() -> void:
	var routes := ApproachRoutes.new()
	assert_false(routes.has_walkway(), "sin datos no hay pasarela")
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
	assert_near(routes.walkway_offset(Vector2(-4.0, 0.5)), 4.0, 0.0001, "a lo largo del primer tramo")
	assert_near(routes.walkway_offset(Vector2(-8.5, 6.0)), 15.0, 0.0001, "y del segundo")
	assert_near(routes.walkway_distance(Vector2(-4.0, 0.5)), 0.5, 0.0001)
	assert_eq(routes.walkway_point(4.0), Vector2(-4.0, 0.0))
	assert_eq(routes.walkway_point(12.0), Vector2(-9.0, 3.0))
	assert_eq(routes.walkway_point(-3.0), Vector2(0.0, 0.0), "recortado al principio")
	assert_eq(routes.walkway_point(40.0), Vector2(-9.0, 8.0), "y al final")
	assert_eq(routes.walkway_post(), Vector2(-9.0, 4.0), "el punto del eje más cercano a la puerta")
