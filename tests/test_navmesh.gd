extends TestCase
## Pruebas de la malla de navegación horneada del Vado Gris (MUN-06, docs/fuerte.md sección 4.1,
## [code]tools/bake_navmesh.gd[/code]): carga de la malla guardada, rutas válidas desde cada
## GuardSpawn del fuerte a la pasarela, al vado y a los dos puentes, y que con la puerta cerrada
## (sin el enlace que crea el servidor) no hay salida del fuerte. Si cambia la geometría de la zona
## hay que volver a hornear la malla; estas pruebas fallan si la nueva geometría rompe una ruta.
## [br][br]
## Usa un mapa propio de [NavigationServer3D], como hará el servidor. Comprobado en Godot 4.7.2: la
## primera iteración del mapa (id 1) sale [b]vacía[/b] (las órdenes de la región se aplican después,
## y [code]map_force_update[/code] no lo evita) y las rutas buenas llegan unos pasos de física más
## tarde (iteración 2); por eso se espera a que el mapa dé un punto cercano de verdad
## ([method _wait_for_map]). Antes de la primera sincronización, consultar el mapa registra un error.

const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const NAVMESH_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris_navmesh.tres"
## El archivo de la malla no puede pasar de esto (docs/fuerte.md, 4.1).
const MAX_FILE_BYTES: int = 20 * 1024 * 1024
## Una ruta llega si acaba a menos de esto (m) del destino en horizontal y en vertical.
const REACH_XZ: float = 1.0
const REACH_Y: float = 1.5
## Puentes: centro en x = 0, z = ±62.
const BRIDGE_Z: float = 62.0
## Centro del vado.
const FORD: Vector2 = Vector2(-62.0, 0.0)
## Explanada delante de la puerta del fuerte (fuera, al oeste).
const GATE_OUTSIDE: Vector2 = Vector2(-30.0, 0.0)
## Medio lado de la empalizada (m), con un margen para el grosor de los troncos.
const FORT_HALF: float = 20.3
## Rutas de los bots de asedio, con la de la pasarela (GUE-45).
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
## Un tramo de la ruta de la pasarela es andable si la ruta de la malla entre sus extremos no es más larga que el tramo
## recto por este factor más este margen (m).
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
	if not assert_not_null(scene, "no se pudo cargar %s" % ZONE_SCENE_PATH) \
			or not assert_not_null(_navmesh, "no se pudo cargar %s" % NAVMESH_PATH):
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
	assert_true(await _wait_for_map(), "el mapa de navegación acaba de construirse")


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
	if not assert_not_null(_navmesh, "la malla se carga"):
		return
	assert_true(_navmesh.get_polygon_count() > 1000, "tiene polígonos (%d)" % _navmesh.get_polygon_count())
	assert_near(_navmesh.cell_size, 0.25, 0.051, "celda de 0,25 m (0,3 si el archivo salía de más de 20 MB)")
	assert_near(_navmesh.agent_radius, 0.4, 0.0001, "radio del personaje")
	assert_near(_navmesh.agent_height, 1.8, 0.0001, "altura del personaje")
	assert_true(FileAccess.get_file_as_bytes(NAVMESH_PATH).size() <= MAX_FILE_BYTES, "no pasa de 20 MB")
	var header: String = FileAccess.get_file_as_string(NAVMESH_PATH).substr(0, 40)
	assert_true(header.begins_with("[gd_resource"), "es texto (.tres), no binario")
	assert_true(NavigationServer3D.map_get_iteration_id(_map) > 0, "el mapa ya tiene una iteración")
	assert_eq(NavigationServer3D.map_get_regions(_map).size(), 1, "con la región de la malla")


func test_every_guard_spawn_reaches_the_walkway_the_ford_and_both_bridges() -> void:
	if not assert_not_null(_fort, "la zona debe instanciarse"):
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
	# Los puentes son de verdad el tablero (más alto que el cauce) y no el lecho.
	assert_true((outside["puente norte"] as Vector3).y > 4.0, "el destino del puente norte es el tablero")
	# La pasarela se alcanza por las rampas, sin salir del fuerte: no hace falta el enlace.
	_check_routes(walkway)
	# El vado y los puentes están fuera: solo se llega por el enlace de la puerta (que el servidor
	# crea por RID y activa según la puerta; aquí, uno como el suyo).
	_open_gate_link()
	assert_true(await _wait_until_reaches(_guard(1).global_position, outside["vado"]), "el enlace queda activo")
	_check_routes(outside)


func test_there_is_no_way_out_of_the_fort_with_the_gate_closed() -> void:
	if not assert_not_null(_fort, "la zona debe instanciarse"):
		return
	var outside: Vector3 = _surface_at(GATE_OUTSIDE)
	for index: int in range(1, 5):
		var guard: Node3D = _guard(index)
		var path: PackedVector3Array = NavigationServer3D.map_get_path(_map, guard.global_position, outside, true)
		# Sin camino, el servidor devuelve la ruta hasta el punto alcanzable más cercano: dentro.
		var end: Vector3 = path[path.size() - 1] if not path.is_empty() else guard.global_position
		assert_false(_reaches(end, outside), "GuardSpawn%d: no llega a la explanada de la puerta" % index)
		for point: Vector3 in path:
			var local: Vector3 = _fort.to_local(point)
			assert_true(absf(local.x) < FORT_HALF and absf(local.z) < FORT_HALF,
					"GuardSpawn%d: la ruta no sale del fuerte (pasa por %s)" % [index, local.snapped(Vector3.ONE * 0.1)])
	# Y la inversa: desde la explanada no se llega al patio.
	var yard: Vector3 = _fort.get_node(^"CaptureCircle").global_position
	var in_path: PackedVector3Array = NavigationServer3D.map_get_path(_map, outside, yard, true)
	var in_end: Vector3 = in_path[in_path.size() - 1] if not in_path.is_empty() else outside
	assert_false(_reaches(in_end, yard), "desde fuera no se llega al círculo con la puerta cerrada")


func test_each_camp_reaches_the_bridge_and_the_ford() -> void:
	if not assert_not_null(_fort, "la zona debe instanciarse"):
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
			if assert_false(path.is_empty(), "%s -> %s: hay ruta" % [realm, target_name]):
				assert_true(_reaches(path[path.size() - 1], target), "%s -> %s: llega" % [realm, target_name])


## No se llega al cauce profundo del río andando (lo cierran los bloqueos de la capa 3, que entran
## en el horneado; sin ellos hay ruta por el lecho): la malla puede cubrir el lecho, pero como isla
## a la que no lleva ninguna ruta desde los campamentos.
func test_the_deep_riverbed_is_not_reachable_on_foot() -> void:
	if not assert_not_null(_fort, "la zona debe instanciarse"):
		return
	var spawns: Array[Node3D] = [Zones.get_spawn_points(_zone, &"vardheim")[0], Zones.get_spawn_points(_zone, &"solmarch")[0]]
	for spawn: Node3D in spawns:
		for point: Vector2 in [Vector2(30.0, -62.0), Vector2(30.0, 62.0), Vector2(-45.0, -52.0), Vector2(-45.0, 52.0)]:
			var bed: Vector3 = _surface_at(point)
			var path: PackedVector3Array = NavigationServer3D.map_get_path(_map, spawn.global_position, bed, true)
			var end: Vector3 = path[path.size() - 1] if not path.is_empty() else spawn.global_position
			assert_false(_reaches(end, bed), "desde %s no se llega al cauce en %s (la ruta acaba en %s)"
					% [spawn.name, point, end.snapped(Vector3.ONE * 0.1)])
	# En cambio el vado, de grava y 0,3 m de agua, sí.
	var ford: Vector3 = _surface_at(FORD)
	var to_ford: PackedVector3Array = NavigationServer3D.map_get_path(_map, spawns[0].global_position, ford, true)
	assert_true(not to_ford.is_empty() and _reaches(to_ford[to_ford.size() - 1], ford), "el vado sí se alcanza")


## GUE-45: los bots de asedio suben a la pasarela por una ruta de puntos precalculada (las rampas y el eje de la pasarela
## de data/routes/vado_gris.tres), que siguen en línea recta. Cada tramo, del círculo al puesto encima de la puerta por
## cada rampa, tiene que ser andable según la malla de los PNJ (MUN-06): la ruta de la malla entre sus extremos llega y
## apenas es más larga que el tramo recto. Y la pasarela está a la altura que dicen los datos.
func test_the_walkway_route_of_the_bots_follows_the_navigation_mesh() -> void:
	if not assert_not_null(_fort, "la zona debe instanciarse"):
		return
	var routes: ApproachRoutes = load(ROUTES_PATH) as ApproachRoutes
	if not assert_true(routes != null and routes.has_walkway(), "las rutas conocen la pasarela"):
		return
	var post: Vector2 = routes.walkway_post()
	var yard: Vector3 = _fort.get_node(^"CaptureCircle").global_position
	assert_near(_surface_at(post).y, routes.walkway_height, 0.05, "la pasarela está a la altura de los datos")
	assert_near(routes.walkway_height - _surface_at(Vector2(yard.x, yard.z)).y, 3.35, 0.05, "3,35 m sobre el patio")
	var post_offset: float = routes.walkway_offset(post)
	var offsets: PackedFloat32Array = routes.walkway_vertex_offsets()
	for index: int in routes.walkway_ramps.size():
		var ramp: PackedVector2Array = routes.walkway_ramps[index]
		var stops: Array[Vector2] = [Vector2(yard.x, yard.z)]
		stops.append_array(Array(ramp))
		# Por el eje de la pasarela, de la cima de la rampa a las esquinas que hay hasta el puesto, y el puesto.
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
			if not assert_false(path.is_empty(), "rampa %d, tramo %d: hay ruta" % [index, i]):
				continue
			assert_true(_reaches(path[path.size() - 1], to), "rampa %d, tramo %d: llega a %s (acaba en %s)"
					% [index, i, to.snapped(Vector3.ONE * 0.1), path[path.size() - 1].snapped(Vector3.ONE * 0.1)])
			var length: float = 0.0
			for p: int in range(1, path.size()):
				length += path[p - 1].distance_to(path[p])
			var straight: float = from.distance_to(to)
			assert_true(length <= straight * WALKWAY_DETOUR_FACTOR + WALKWAY_DETOUR_MARGIN,
					"rampa %d, tramo %d (%s -> %s): la malla va casi en línea recta (%.1f m frente a %.1f)"
					% [index, i, stops[i - 1], stops[i], length, straight])


# --- Ayudantes --------------------------------------------------------------------------------

## Espera (hasta 120 pasos de física) a que el mapa esté construido: primero a la primera
## iteración, que es la única en la que se puede consultar sin error, y luego a que devuelva un punto
## de la malla (el campamento de Vardheim) en lugar del origen.
func _wait_for_map() -> bool:
	var sample: Vector3 = Vector3(0.0, 6.3, -138.0)
	for _i: int in 120:
		if NavigationServer3D.map_get_iteration_id(_map) > 0 \
				and NavigationServer3D.map_get_closest_point(_map, sample).y > 1.0:
			return true
		await wait_physics_frames()
	return false


## Comprueba que desde cada GuardSpawn hay una ruta que llega a cada destino de [param targets]
## (nombre -> posición).
func _check_routes(targets: Dictionary) -> void:
	for index: int in range(1, 5):
		var guard: Node3D = _guard(index)
		for target_name: String in targets:
			var target: Vector3 = targets[target_name]
			var path: PackedVector3Array = NavigationServer3D.map_get_path(_map, guard.global_position, target, true)
			if not assert_false(path.is_empty(), "GuardSpawn%d -> %s: hay ruta" % [index, target_name]):
				continue
			var end: Vector3 = path[path.size() - 1]
			assert_true(_reaches(end, target), "GuardSpawn%d -> %s: la ruta llega (acaba en %s, destino %s)"
					% [index, target_name, end.snapped(Vector3.ONE * 0.1), target.snapped(Vector3.ONE * 0.1)])


func _guard(index: int) -> Node3D:
	return _fort.get_node(NodePath("GuardSpawn%d" % index)) as Node3D


## Enlace de dos sentidos por el vano de la puerta (x = -20 en el fuerte), como el que crea el
## servidor: de un punto del patio, a 2 m de la puerta, a otro de la explanada, a 2,5 m fuera.
func _open_gate_link() -> void:
	_link = NavigationServer3D.link_create()
	NavigationServer3D.link_set_map(_link, _map)
	NavigationServer3D.link_set_start_position(_link, _surface_at(Vector2(-17.5, 0.0)))
	NavigationServer3D.link_set_end_position(_link, _surface_at(Vector2(-23.0, 0.0)))
	NavigationServer3D.link_set_bidirectional(_link, true)
	NavigationServer3D.link_set_enabled(_link, true)


## Espera (hasta 120 pasos de física) a que haya una ruta de [param from] que llegue a [param to].
func _wait_until_reaches(from: Vector3, to: Vector3) -> bool:
	for _i: int in 120:
		var path: PackedVector3Array = NavigationServer3D.map_get_path(_map, from, to, true)
		if not path.is_empty() and _reaches(path[path.size() - 1], to):
			return true
		await wait_physics_frames()
	return false


func _reaches(end: Vector3, target: Vector3) -> bool:
	return Vector2(end.x - target.x, end.z - target.z).length() <= REACH_XZ and absf(end.y - target.y) <= REACH_Y


## Primer suelo (capa del mundo) que se toca bajando desde arriba en ([param point].x, .y).
func _surface_at(point: Vector2) -> Vector3:
	var space: PhysicsDirectSpaceState3D = _zone.get_world_3d().direct_space_state
	var from: Vector3 = Vector3(point.x, 60.0, point.y)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.001, -120.0, 0.0),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		fail("no hay suelo en %s" % point)
		return Vector3(point.x, 0.0, point.y)
	return hit["position"]
