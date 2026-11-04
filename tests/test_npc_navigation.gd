extends TestCase
## Tests of [NpcNavigation] (MUN-06, docs/fortress.md section 4.1) on the baked mesh of Vado Gris: the
## own map waits before giving real routes, the gate link is on the owning realm's layer and each
## query filters with the layer of the agent's realm (with the fort neutral only the Hollow cross;
## with an owner, only the owner; with the gate broken, everyone), in both directions.

const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const NAVMESH_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris_navmesh.tres"
const FORTRESS: StringName = &"vado_gris_fort"
## Esplanade in front of the fort gate (outside, to the west).
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
	if not assert_not_null(scene, "could not load %s" % ZONE_SCENE_PATH) \
			or not assert_not_null(navmesh, "could not load %s" % NAVMESH_PATH):
		return
	_zone = scene.instantiate() as Node3D
	tree.root.add_child(_zone)
	_fort = _zone.get_node(^"Fuerte") as Node3D
	_nav = NpcNavigation.new()
	assert_true(_nav.setup(navmesh), "the navigation is set up with the mesh")
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


## Waits (up to 120 physics steps) for [method NpcNavigation.poll] to report the map as ready.
func _wait_until_ready() -> bool:
	for _i: int in 120:
		if _nav.poll():
			return true
		await wait_physics_frames()
	return false


## Waits (up to 120 physics steps) for there to be a route from [param from] to [param to] for
## [param realm] that really gets there (the link layers are applied on the next map iteration).
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
		fail("there is no ground at %s" % point)
		return Vector3(point.x, 0.0, point.y)
	return hit["position"]


## true if an agent of [param realm] gets from [param from] to [param to] according to the route it
## gives now.
func _reaches(from: Vector3, to: Vector3, realm: int) -> bool:
	return NpcNavigation.path_reaches(_nav.get_path(from, to, realm), to)


func test_the_layers_are_distinct_bits_and_every_query_includes_the_region() -> void:
	var seen: int = 0
	for realm: int in [HUECOS, VARDHEIM, SOLMARCH, ASKARRA]:
		var layer: int = NpcNavigation.layer_of_realm(realm)
		assert_eq(layer & (layer - 1), 0, "the layer of realm %d is a single bit" % realm)
		assert_eq(seen & layer, 0, "and it is not repeated")
		seen |= layer
		assert_eq(layer & NpcNavigation.REGION_LAYER, 0, "nor is it the region's")
		assert_eq(NpcNavigation.query_layers(realm), NpcNavigation.REGION_LAYER | layer)
	assert_eq(seen, NpcNavigation.REALM_LAYERS_MASK, "the four cover the realm mask")


func test_there_are_no_routes_until_the_map_is_ready_and_asking_early_does_not_log_errors() -> void:
	assert_false(_nav.is_ready(), "freshly set up it is not ready")
	assert_true(_nav.get_path(_guard(1), _surface_at(GATE_OUTSIDE), VARDHEIM).is_empty(),
			"without a ready map there is no route (and the server is not queried)")
	assert_eq(_nav.closest_point(_guard(1)), _guard(1), "nor a nearby point: it returns the same one")
	assert_true(await _wait_until_ready(), "the map ends up giving real routes")
	assert_true(_nav.is_ready())
	assert_true(_nav.poll(), "and stays ready")
	var inside_path: PackedVector3Array = _nav.get_path(_guard(1), _guard(4), HUECOS)
	assert_false(inside_path.is_empty(), "there is already a route inside the fort")
	assert_true(NpcNavigation.path_reaches(inside_path, _guard(4)), "and it arrives")
	assert_eq(_nav.get_paths_computed(), 1, "counts the computed routes")


func test_a_neutral_fort_lets_only_the_hollows_through_its_gate_in_both_directions() -> void:
	assert_true(await _wait_until_ready())
	var outside: Vector3 = _surface_at(GATE_OUTSIDE)
	var yard: Vector3 = (_fort.get_node(^"CaptureCircle") as Node3D).global_position
	assert_eq(_nav.get_gate_layers(FORTRESS), NpcNavigation.layer_of_realm(HUECOS), "link on the neutral layer")
	assert_true(await _wait_for_route(_guard(1), outside, HUECOS), "the Hollow go out through the gate")
	assert_true(_reaches(outside, yard, HUECOS), "and come in")
	for realm: int in [VARDHEIM, SOLMARCH, ASKARRA]:
		assert_false(_reaches(_guard(1), outside, realm), "realm %d does not go out with the gate closed" % realm)
		assert_false(_reaches(outside, yard, realm), "nor come in")


func test_an_owned_fort_lets_only_its_owner_through() -> void:
	assert_true(await _wait_until_ready())
	var outside: Vector3 = _surface_at(GATE_OUTSIDE)
	var yard: Vector3 = (_fort.get_node(^"CaptureCircle") as Node3D).global_position
	_nav.set_gate_state(FORTRESS, VARDHEIM, false)
	assert_eq(_nav.get_gate_layers(FORTRESS), NpcNavigation.layer_of_realm(VARDHEIM))
	assert_true(await _wait_for_route(_guard(2), outside, VARDHEIM), "the owner goes out through its gate")
	assert_true(_reaches(outside, yard, VARDHEIM), "and comes back in")
	for realm: int in [HUECOS, SOLMARCH, ASKARRA]:
		assert_false(_reaches(_guard(2), outside, realm), "realm %d does not go out" % realm)
		assert_false(_reaches(outside, yard, realm), "nor come in")
	# It changes hands: it now belongs to Solmarch and the passage is reversed.
	_nav.set_gate_state(FORTRESS, SOLMARCH, false)
	assert_true(await _wait_for_route(_guard(2), outside, SOLMARCH), "the new owner passes")
	assert_false(_reaches(_guard(2), outside, VARDHEIM), "and the previous one no longer does")


func test_a_broken_gate_lets_everyone_through() -> void:
	assert_true(await _wait_until_ready())
	var outside: Vector3 = _surface_at(GATE_OUTSIDE)
	var yard: Vector3 = (_fort.get_node(^"CaptureCircle") as Node3D).global_position
	_nav.set_gate_state(FORTRESS, VARDHEIM, true)
	assert_eq(_nav.get_gate_layers(FORTRESS), NpcNavigation.REALM_LAYERS_MASK, "broken: everyone's layers")
	assert_true(await _wait_for_route(_guard(3), outside, SOLMARCH), "the enemies pass through the broken gate")
	for realm: int in [HUECOS, VARDHEIM, SOLMARCH, ASKARRA]:
		assert_true(_reaches(_guard(3), outside, realm), "realm %d goes out" % realm)
		assert_true(_reaches(outside, yard, realm), "and comes in")
	# Repaired: it closes again to the others.
	_nav.set_gate_state(FORTRESS, VARDHEIM, false)
	for _i: int in 3:
		await wait_physics_frames()
	assert_false(_reaches(_guard(3), outside, SOLMARCH), "repaired, the enemies are left outside again")


func test_state_set_before_the_map_is_ready_is_kept_for_the_links() -> void:
	_nav.set_gate_state(FORTRESS, ASKARRA, false)
	assert_true(await _wait_until_ready())
	assert_eq(_nav.get_gate_layers(FORTRESS), NpcNavigation.layer_of_realm(ASKARRA))
	assert_true(await _wait_for_route(_guard(1), _surface_at(GATE_OUTSIDE), ASKARRA), "Askarra crosses")
	assert_eq(_nav.get_gate_layers(&"no_existe"), 0, "a gate that does not exist has no layers")
	_nav.set_gate_state(&"no_existe", VARDHEIM, true)


func test_dispose_frees_the_server_objects_and_can_be_repeated() -> void:
	assert_true(await _wait_until_ready())
	var map: RID = _nav.get_map()
	assert_true(map.is_valid())
	_nav.dispose()
	assert_false(_nav.get_map().is_valid(), "the map is freed")
	assert_false(_nav.is_ready(), "and stops being ready")
	assert_true(_nav.get_path(_guard(1), _guard(2), HUECOS).is_empty(), "without routes")
	assert_false(_nav.poll(), "nor does it report the map as ready again")
	_nav.dispose()
	assert_false(_nav.setup(null), "without a mesh it is not set up")
