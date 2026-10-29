extends TestCase
## Pruebas de [SpawnPicker]: puntos de aparición por reino, rueda, yaw del punto y los
## respaldos (cualquier punto de la zona y, sin puntos, el origen). docs/red.md, sección 1.5.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA

var _world: Node3D


func after_each() -> void:
	if is_instance_valid(_world):
		if _world.is_inside_tree():
			_world.get_parent().remove_child(_world)
		_world.free()
	_world = null
	await wait_process_frames()


## Marcador en el grupo de aparición. [param realm] vacío = sin metadato.
func _add_point(parent: Node3D, point_name: String, position: Vector3, realm: String = "",
		yaw: float = 0.0) -> Marker3D:
	var marker := Marker3D.new()
	marker.name = point_name
	parent.add_child(marker)
	marker.position = position
	marker.rotation.y = yaw
	marker.add_to_group(Zones.SPAWN_GROUP)
	if not realm.is_empty():
		marker.set_meta(Zones.REALM_META, StringName(realm))
	return marker


func _make_world() -> void:
	_world = Node3D.new()
	_world.name = "ZonaDePrueba"
	tree.root.add_child(_world)


func _yaw_of(transform: Transform3D) -> float:
	var forward: Vector3 = -transform.basis.z
	return atan2(-forward.x, -forward.z)


## NetZones es el único contacto de la red con Zones: da los puntos de aparición (de un reino o de
## todos) y el nombre del grupo que los marca, que es el de Zones.
func test_net_zones_gives_the_spawn_points_and_their_group() -> void:
	_make_world()
	_add_point(_world, "V1", Vector3(0, 0, -10), "vardheim")
	_add_point(_world, "S1", Vector3(0, 0, 10), "solmarch")
	_add_point(_world, "V2", Vector3(5, 0, -10), "vardheim")
	_add_point(_world, "Libre", Vector3(9, 0, 9))
	assert_eq(NetZones.spawn_group(), Zones.SPAWN_GROUP)
	assert_eq(NetZones.get_spawn_points(_world).size(), 4, "sin reino, todos los de la zona")
	assert_eq(NetZones.get_spawn_points(_world, NetProtocol.Realm.NONE).size(), 4, "NONE es sin reino")
	var vardheim: Array[Node3D] = NetZones.get_spawn_points(_world, VARDHEIM)
	assert_eq(vardheim.size(), 2, "los de Vardheim")
	assert_eq(vardheim[0].name, &"V1")
	assert_eq(vardheim[1].name, &"V2", "en el orden de la escena")
	assert_eq(NetZones.get_spawn_points(_world, SOLMARCH).size(), 1)
	assert_true(NetZones.get_spawn_points(_world, ASKARRA).is_empty(), "un reino sin puntos, ninguno")
	assert_true(NetZones.get_spawn_points(null, VARDHEIM).is_empty(), "sin zona, ninguno")


func test_wheel_cycles_through_the_points_of_the_realm() -> void:
	_make_world()
	_add_point(_world, "V1", Vector3(0, 0, -10), "vardheim")
	_add_point(_world, "S1", Vector3(0, 0, 10), "solmarch")
	_add_point(_world, "V2", Vector3(5, 0, -10), "vardheim")
	_add_point(_world, "V3", Vector3(10, 0, -10), "vardheim")
	var picker := SpawnPicker.new(_world)
	var expected: Array[Vector3] = [
		Vector3(0, 0, -10), Vector3(5, 0, -10), Vector3(10, 0, -10),
		Vector3(0, 0, -10), Vector3(5, 0, -10),
	]
	for i: int in expected.size():
		assert_vec_near(picker.pick(VARDHEIM).origin, expected[i], 1e-5,
				"aparición %d de Vardheim" % i)


func test_each_realm_has_its_own_wheel() -> void:
	_make_world()
	_add_point(_world, "V1", Vector3(0, 0, -10), "vardheim")
	_add_point(_world, "V2", Vector3(5, 0, -10), "vardheim")
	_add_point(_world, "S1", Vector3(0, 0, 10), "solmarch")
	_add_point(_world, "S2", Vector3(5, 0, 10), "solmarch")
	var picker := SpawnPicker.new(_world)
	assert_vec_near(picker.pick(VARDHEIM).origin, Vector3(0, 0, -10), 1e-5, "V1")
	assert_vec_near(picker.pick(SOLMARCH).origin, Vector3(0, 0, 10), 1e-5, "S1")
	assert_vec_near(picker.pick(SOLMARCH).origin, Vector3(5, 0, 10), 1e-5, "S2")
	assert_vec_near(picker.pick(VARDHEIM).origin, Vector3(5, 0, -10), 1e-5,
			"las apariciones de Solmarch no mueven la rueda de Vardheim")
	assert_vec_near(picker.pick(SOLMARCH).origin, Vector3(0, 0, 10), 1e-5, "S1 otra vez")


func test_single_point_realm_always_gets_that_point() -> void:
	_make_world()
	_add_point(_world, "V1", Vector3(1, 2, 3), "vardheim")
	_add_point(_world, "S1", Vector3(-1, 2, -3), "solmarch")
	var picker := SpawnPicker.new(_world)
	for _i: int in 4:
		assert_vec_near(picker.pick(SOLMARCH).origin, Vector3(-1, 2, -3), 1e-5, "Solmarch")


func test_transform_carries_the_yaw_of_the_point() -> void:
	_make_world()
	var yaws: Array[float] = [0.0, 0.5, 1.0, -1.0, PI * 0.75, -2.5]
	for i: int in yaws.size():
		_add_point(_world, "V%d" % i, Vector3(float(i), 0, 0), "vardheim", yaws[i])
	var picker := SpawnPicker.new(_world)
	for i: int in yaws.size():
		var spawn: Transform3D = picker.pick(VARDHEIM)
		assert_near(absf(angle_difference(_yaw_of(spawn), yaws[i])), 0.0, 1e-5,
				"yaw del punto %d" % i)
		assert_true(spawn.basis.is_equal_approx(Basis(Vector3.UP, yaws[i])),
				"la base solo gira en Y (punto %d)" % i)


func test_yaw_uses_the_global_transform() -> void:
	_make_world()
	var pivot := Node3D.new()
	_world.add_child(pivot)
	pivot.position = Vector3(100, 0, 0)
	pivot.rotation.y = 1.0
	_add_point(pivot, "V1", Vector3(0, 0, -5), "vardheim", 0.5)
	var spawn: Transform3D = SpawnPicker.new(_world).pick(VARDHEIM)
	var expected_origin: Vector3 = pivot.global_transform * Vector3(0, 0, -5)
	assert_vec_near(spawn.origin, expected_origin, 1e-4, "posición global del punto")
	assert_near(absf(angle_difference(_yaw_of(spawn), 1.5)), 0.0, 1e-5,
			"el yaw suma el del padre")


func test_realm_without_points_falls_back_to_any_point() -> void:
	_make_world()
	_add_point(_world, "V1", Vector3(0, 0, -10), "vardheim")
	_add_point(_world, "S1", Vector3(0, 0, 10), "solmarch")
	_add_point(_world, "N1", Vector3(7, 0, 0))
	var picker := SpawnPicker.new(_world)
	# Askarra no tiene puntos aquí: rueda por todos los de la zona, en el orden de la escena.
	assert_vec_near(picker.pick(ASKARRA).origin, Vector3(0, 0, -10), 1e-5, "primero")
	assert_vec_near(picker.pick(ASKARRA).origin, Vector3(0, 0, 10), 1e-5, "segundo")
	assert_vec_near(picker.pick(ASKARRA).origin, Vector3(7, 0, 0), 1e-5, "tercero")
	assert_vec_near(picker.pick(ASKARRA).origin, Vector3(0, 0, -10), 1e-5, "y vuelta a empezar")
	assert_vec_near(picker.pick(NetProtocol.Realm.NONE).origin, Vector3(0, 0, -10), 1e-5,
			"sin reino también cae en cualquiera")
	assert_vec_near(picker.pick(99).origin, Vector3(0, 0, -10), 1e-5,
			"un código de reino desconocido también, con su propia rueda")


func test_points_without_realm_are_not_assigned_to_a_realm() -> void:
	_make_world()
	_add_point(_world, "N1", Vector3(7, 0, 0))
	_add_point(_world, "V1", Vector3(0, 0, -10), "vardheim")
	var picker := SpawnPicker.new(_world)
	for _i: int in 3:
		assert_vec_near(picker.pick(VARDHEIM).origin, Vector3(0, 0, -10), 1e-5,
				"Vardheim solo usa su punto")


func test_zone_without_points_spawns_at_the_origin() -> void:
	_make_world()
	var picker := SpawnPicker.new(_world)
	for _i: int in 3:
		var spawn: Transform3D = picker.pick(VARDHEIM)
		assert_vec_near(spawn.origin, Vector3.ZERO, 1e-6, "origen")
		assert_true(spawn.basis.is_equal_approx(Basis.IDENTITY), "sin giro")


func test_null_world_spawns_at_the_origin() -> void:
	var spawn: Transform3D = SpawnPicker.new(null).pick(SOLMARCH)
	assert_vec_near(spawn.origin, Vector3.ZERO, 1e-6, "sin mundo, en el origen")


func test_world_outside_the_tree_spawns_at_the_origin() -> void:
	var detached := Node3D.new()
	var marker := Marker3D.new()
	detached.add_child(marker)
	marker.add_to_group(Zones.SPAWN_GROUP)
	marker.position = Vector3(3, 0, 3)
	var spawn: Transform3D = SpawnPicker.new(detached).pick(VARDHEIM)
	assert_vec_near(spawn.origin, Vector3.ZERO, 1e-6, "Zones exige la zona en el árbol")
	detached.free()


func test_points_of_other_zones_are_ignored() -> void:
	_make_world()
	_add_point(_world, "V1", Vector3(0, 0, -10), "vardheim")
	var other := Node3D.new()
	tree.root.add_child(other)
	_add_point(other, "VX", Vector3(99, 0, 99), "vardheim")
	var picker := SpawnPicker.new(_world)
	for _i: int in 3:
		assert_vec_near(picker.pick(VARDHEIM).origin, Vector3(0, 0, -10), 1e-5,
				"solo los puntos de esta zona")
	tree.root.remove_child(other)
	other.free()


func test_real_zone_gives_a_point_of_each_realm() -> void:
	var scene: PackedScene = load(NetZones.scene_path(NetZones.default_zone_id())) as PackedScene
	if not assert_not_null(scene, "se carga la zona por defecto"):
		return
	_world = scene.instantiate() as Node3D
	tree.root.add_child(_world)
	var picker := SpawnPicker.new(_world)
	var north: Array[Node3D] = Zones.get_spawn_points(_world, &"vardheim")
	var south: Array[Node3D] = Zones.get_spawn_points(_world, &"solmarch")
	if not (assert_false(north.is_empty(), "hay puntos de Vardheim")
			and assert_false(south.is_empty(), "hay puntos de Solmarch")):
		return
	for i: int in north.size() + 1:
		var spawn: Transform3D = picker.pick(VARDHEIM)
		var point: Node3D = north[i % north.size()]
		assert_vec_near(spawn.origin, point.global_position, 1e-4, "Vardheim, aparición %d" % i)
	assert_vec_near(picker.pick(SOLMARCH).origin, south[0].global_position, 1e-4,
			"Solmarch empieza por su primer punto")
	# Askarra no tiene frente en esta zona: cualquiera de los puntos de la zona.
	var fallback: Transform3D = picker.pick(ASKARRA)
	var all_points: Array[Node3D] = Zones.get_spawn_points(_world)
	var found: bool = false
	for point: Node3D in all_points:
		if point.global_position.distance_to(fallback.origin) < 1e-4:
			found = true
	assert_true(found, "el respaldo es un punto de la zona")
