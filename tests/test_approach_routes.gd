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
