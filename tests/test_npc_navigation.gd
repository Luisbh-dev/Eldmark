extends TestCase
## Pruebas de [NpcNavigation] (MUN-06, docs/fuerte.md sección 4.1) sobre la malla horneada del Vado Gris: el
## mapa propio espera a dar rutas de verdad, el enlace de la puerta está en la capa del reino dueño y cada
## consulta filtra con la capa del reino del agente (con el fuerte neutral solo cruzan los Huecos; con dueño,
## solo el dueño; con la puerta rota, todos), en los dos sentidos.

const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const NAVMESH_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris_navmesh.tres"
const FORTRESS: StringName = &"vado_gris_fort"
## Explanada delante de la puerta del fuerte (fuera, al oeste).
const GATE_OUTSIDE: Vector2 = Vector2(-30.0, 0.0)
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
const HUECOS: int = 0

var _zone: Node3D = null
var _fort: Node3D = null
var _nav: NpcNavigation = null


func before_each() -> void:
	var navmesh: NavigationMesh = load(NAVMESH_PATH) as NavigationMesh
	var scene: PackedScene = load(ZONE_SCENE_PATH) as PackedScene
	if not assert_not_null(scene, "no se pudo cargar %s" % ZONE_SCENE_PATH) \
			or not assert_not_null(navmesh, "no se pudo cargar %s" % NAVMESH_PATH):
		return
	_zone = scene.instantiate() as Node3D
	tree.root.add_child(_zone)
	_fort = _zone.get_node(^"Fuerte") as Node3D
	_nav = NpcNavigation.new()
	assert_true(_nav.setup(navmesh), "la navegación se monta con la malla")
	_nav.add_gate_link_at(FORTRESS, (_fort.get_node(^"FortGate") as Node3D).global_transform)


func after_each() -> void:
	if _nav != null:
		_nav.dispose()
	_nav = null
	if is_instance_valid(_zone):
		_zone.get_parent().remove_child(_zone)
		_zone.queue_free()
	_zone = null
	_fort = null
	await wait_process_frames()


## Espera (hasta 120 pasos de física) a que [method NpcNavigation.poll] dé el mapa por listo.
func _wait_until_ready() -> bool:
	for _i: int in 120:
		if _nav.poll():
			return true
		await wait_physics_frames()
	return false


## Espera (hasta 120 pasos de física) a que haya una ruta de [param from] a [param to] para [param realm] que
## llegue de verdad (las capas del enlace se aplican en la siguiente iteración del mapa).
func _wait_for_route(from: Vector3, to: Vector3, realm: int) -> bool:
	for _i: int in 120:
		if NpcNavigation.path_reaches(_nav.get_path(from, to, realm), to):
			return true
		await wait_physics_frames()
	return false


func _guard(index: int) -> Vector3:
	return (_fort.get_node(NodePath("GuardSpawn%d" % index)) as Node3D).global_position


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


## true si un agente de [param realm] llega de [param from] a [param to] según la ruta que da ahora.
func _reaches(from: Vector3, to: Vector3, realm: int) -> bool:
	return NpcNavigation.path_reaches(_nav.get_path(from, to, realm), to)


func test_the_layers_are_distinct_bits_and_every_query_includes_the_region() -> void:
	var seen: int = 0
	for realm: int in [HUECOS, VARDHEIM, SOLMARCH, ASKARRA]:
		var layer: int = NpcNavigation.layer_of_realm(realm)
		assert_eq(layer & (layer - 1), 0, "la capa del reino %d es un solo bit" % realm)
		assert_eq(seen & layer, 0, "y no se repite")
		seen |= layer
		assert_eq(layer & NpcNavigation.REGION_LAYER, 0, "ni es la de la región")
		assert_eq(NpcNavigation.query_layers(realm), NpcNavigation.REGION_LAYER | layer)
	assert_eq(seen, NpcNavigation.REALM_LAYERS_MASK, "las cuatro cubren la máscara de los reinos")


func test_there_are_no_routes_until_the_map_is_ready_and_asking_early_does_not_log_errors() -> void:
	assert_false(_nav.is_ready(), "recién montado no está listo")
	assert_true(_nav.get_path(_guard(1), _surface_at(GATE_OUTSIDE), VARDHEIM).is_empty(),
			"sin mapa listo no hay ruta (y no se consulta el servidor)")
	assert_eq(_nav.closest_point(_guard(1)), _guard(1), "ni punto cercano: devuelve el mismo")
	assert_true(await _wait_until_ready(), "el mapa acaba dando rutas de verdad")
	assert_true(_nav.is_ready())
	assert_true(_nav.poll(), "y sigue listo")
	var inside_path: PackedVector3Array = _nav.get_path(_guard(1), _guard(4), HUECOS)
	assert_false(inside_path.is_empty(), "ya hay ruta dentro del fuerte")
	assert_true(NpcNavigation.path_reaches(inside_path, _guard(4)), "y llega")
	assert_eq(_nav.get_paths_computed(), 1, "cuenta las rutas calculadas")


func test_a_neutral_fort_lets_only_the_hollows_through_its_gate_in_both_directions() -> void:
	assert_true(await _wait_until_ready())
	var outside: Vector3 = _surface_at(GATE_OUTSIDE)
	var yard: Vector3 = (_fort.get_node(^"CaptureCircle") as Node3D).global_position
	assert_eq(_nav.get_gate_layers(FORTRESS), NpcNavigation.layer_of_realm(HUECOS), "enlace en la capa neutral")
	assert_true(await _wait_for_route(_guard(1), outside, HUECOS), "los Huecos salen por la puerta")
	assert_true(_reaches(outside, yard, HUECOS), "y entran")
	for realm: int in [VARDHEIM, SOLMARCH, ASKARRA]:
		assert_false(_reaches(_guard(1), outside, realm), "el reino %d no sale con la puerta cerrada" % realm)
		assert_false(_reaches(outside, yard, realm), "ni entra")


func test_an_owned_fort_lets_only_its_owner_through() -> void:
	assert_true(await _wait_until_ready())
	var outside: Vector3 = _surface_at(GATE_OUTSIDE)
	var yard: Vector3 = (_fort.get_node(^"CaptureCircle") as Node3D).global_position
	_nav.set_gate_state(FORTRESS, VARDHEIM, false)
	assert_eq(_nav.get_gate_layers(FORTRESS), NpcNavigation.layer_of_realm(VARDHEIM))
	assert_true(await _wait_for_route(_guard(2), outside, VARDHEIM), "el dueño sale por su puerta")
	assert_true(_reaches(outside, yard, VARDHEIM), "y vuelve a entrar")
	for realm: int in [HUECOS, SOLMARCH, ASKARRA]:
		assert_false(_reaches(_guard(2), outside, realm), "el reino %d no sale" % realm)
		assert_false(_reaches(outside, yard, realm), "ni entra")
	# Cambia de manos: ahora es de Solmarch y el paso se invierte.
	_nav.set_gate_state(FORTRESS, SOLMARCH, false)
	assert_true(await _wait_for_route(_guard(2), outside, SOLMARCH), "el nuevo dueño pasa")
	assert_false(_reaches(_guard(2), outside, VARDHEIM), "y el anterior ya no")


func test_a_broken_gate_lets_everyone_through() -> void:
	assert_true(await _wait_until_ready())
	var outside: Vector3 = _surface_at(GATE_OUTSIDE)
	var yard: Vector3 = (_fort.get_node(^"CaptureCircle") as Node3D).global_position
	_nav.set_gate_state(FORTRESS, VARDHEIM, true)
	assert_eq(_nav.get_gate_layers(FORTRESS), NpcNavigation.REALM_LAYERS_MASK, "rota: las capas de todos")
	assert_true(await _wait_for_route(_guard(3), outside, SOLMARCH), "los enemigos pasan por la puerta rota")
	for realm: int in [HUECOS, VARDHEIM, SOLMARCH, ASKARRA]:
		assert_true(_reaches(_guard(3), outside, realm), "el reino %d sale" % realm)
		assert_true(_reaches(outside, yard, realm), "y entra")
	# Reparada: vuelve a cerrarse a los demás.
	_nav.set_gate_state(FORTRESS, VARDHEIM, false)
	for _i: int in 3:
		await wait_physics_frames()
	assert_false(_reaches(_guard(3), outside, SOLMARCH), "reparada, los enemigos vuelven a quedarse fuera")


func test_state_set_before_the_map_is_ready_is_kept_for_the_links() -> void:
	_nav.set_gate_state(FORTRESS, ASKARRA, false)
	assert_true(await _wait_until_ready())
	assert_eq(_nav.get_gate_layers(FORTRESS), NpcNavigation.layer_of_realm(ASKARRA))
	assert_true(await _wait_for_route(_guard(1), _surface_at(GATE_OUTSIDE), ASKARRA), "Askarra cruza")
	assert_eq(_nav.get_gate_layers(&"no_existe"), 0, "una puerta que no existe no tiene capas")
	_nav.set_gate_state(&"no_existe", VARDHEIM, true)


func test_dispose_frees_the_server_objects_and_can_be_repeated() -> void:
	assert_true(await _wait_until_ready())
	var map: RID = _nav.get_map()
	assert_true(map.is_valid())
	_nav.dispose()
	assert_false(_nav.get_map().is_valid(), "el mapa se libera")
	assert_false(_nav.is_ready(), "y deja de estar listo")
	assert_true(_nav.get_path(_guard(1), _guard(2), HUECOS).is_empty(), "sin rutas")
	assert_false(_nav.poll(), "ni vuelve a dar el mapa por listo")
	_nav.dispose()
	assert_false(_nav.setup(null), "sin malla no se monta")
