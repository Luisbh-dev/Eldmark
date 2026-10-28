extends TestCase
## Pruebas del registro de zonas ([Zones], compartido) y de las opciones de arranque
## [code]--zone=[/code] y [code]--realm=[/code] de [code]boot.gd[/code].
##
## Cada zona registrada debe cargar headless (como la cargará su servidor dedicado), tener
## puntos de aparición y responder a la elección por reino: el primero de ese reino o, si la zona
## no tiene puntos de ese reino, el primero de la zona.

const BootScript = preload("res://scripts/boot.gd")

const VADO_GRIS: StringName = &"vado_gris"
const TEST_WORLD: StringName = &"test_world"

var _zone: Node


func after_each() -> void:
	if is_instance_valid(_zone):
		_zone.get_parent().remove_child(_zone)
		_zone.queue_free()
	_zone = null
	await wait_process_frames()


func test_registry_lists_known_zones() -> void:
	assert_eq(Zones.DEFAULT_ZONE, VADO_GRIS, "la zona por defecto es el Vado Gris")
	assert_true(Zones.has_zone(Zones.DEFAULT_ZONE), "la zona por defecto está registrada")
	assert_eq(Zones.get_scene_path(VADO_GRIS), "res://scenes/world/zones/vado_gris/vado_gris.tscn",
			"escena del Vado Gris")
	assert_eq(Zones.get_scene_path(TEST_WORLD), "res://scenes/world/test_world.tscn",
			"escena del circuito de pruebas")
	assert_false(Zones.has_zone(&"atlantida"), "una zona inventada no existe")
	assert_eq(Zones.get_scene_path(&"atlantida"), "", "sin escena para una zona inventada")
	assert_eq(Zones.get_zone_ids(), [TEST_WORLD, VADO_GRIS] as Array[StringName],
			"identificadores ordenados")
	for zone_id: StringName in Zones.get_zone_ids():
		assert_true(ResourceLoader.exists(Zones.get_scene_path(zone_id)),
				"existe la escena de %s" % zone_id)
	assert_eq(Zones.DEFAULT_REALM, &"vardheim", "reino por defecto")
	assert_true(Zones.is_realm(&"solmarch"), "solmarch es un reino")
	assert_false(Zones.is_realm(&"mordor"), "un reino inventado no existe")


func test_every_zone_loads_headless_with_spawn_points() -> void:
	for zone_id: StringName in Zones.get_zone_ids():
		var scene: PackedScene = load(Zones.get_scene_path(zone_id)) as PackedScene
		if not assert_not_null(scene, "carga la escena de %s" % zone_id):
			continue
		_zone = scene.instantiate()
		tree.root.add_child(_zone)
		await wait_physics_frames(2)
		assert_false(Zones.get_spawn_points(_zone).is_empty(), "%s tiene puntos de aparición" % zone_id)
		var spawn: Node3D = Zones.find_spawn_point(_zone, Zones.DEFAULT_REALM)
		if assert_not_null(spawn, "%s da un punto de aparición" % zone_id):
			var hit: Dictionary = _raycast_down(_zone, spawn.global_position)
			assert_false(hit.is_empty(), "%s: hay suelo bajo %s" % [zone_id, spawn.name])
		_zone.get_parent().remove_child(_zone)
		_zone.queue_free()
		_zone = null
		await wait_process_frames()


func test_spawn_by_realm_in_vado_gris() -> void:
	_zone = (load(Zones.get_scene_path(VADO_GRIS)) as PackedScene).instantiate()
	tree.root.add_child(_zone)
	await wait_process_frames()
	var north: Node3D = Zones.find_spawn_point(_zone, &"vardheim")
	var south: Node3D = Zones.find_spawn_point(_zone, &"solmarch")
	if not (assert_not_null(north, "hay punto de Vardheim") and assert_not_null(south, "hay punto de Solmarch")):
		return
	assert_eq(Zones.get_spawn_realm(north), &"vardheim", "el punto de Vardheim es de Vardheim")
	assert_eq(Zones.get_spawn_realm(south), &"solmarch", "el punto de Solmarch es de Solmarch")
	assert_true(north.global_position.z < -100.0, "Vardheim aparece al norte (-Z)")
	assert_true(south.global_position.z > 100.0, "Solmarch aparece al sur (+Z)")
	assert_eq(north, Zones.get_spawn_points(_zone, &"vardheim")[0], "el primero de su reino")
	assert_eq(Zones.get_spawn_points(_zone, &"vardheim").size(), 4, "4 puntos de Vardheim")
	assert_eq(Zones.get_spawn_points(_zone, &"solmarch").size(), 4, "4 puntos de Solmarch")
	# Un reino sin puntos en esta zona (Askarra no tiene frente aquí) usa el primero de la zona.
	assert_eq(Zones.find_spawn_point(_zone, &"askarra"), Zones.get_spawn_points(_zone)[0],
			"sin puntos de ese reino se usa el primero de la zona")
	# Los puntos de otro nodo del árbol no cuentan.
	var outsider: Marker3D = Marker3D.new()
	outsider.add_to_group(Zones.SPAWN_GROUP)
	outsider.set_meta(Zones.REALM_META, &"askarra")
	tree.root.add_child(outsider)
	assert_eq(Zones.find_spawn_point(_zone, &"askarra"), Zones.get_spawn_points(_zone)[0],
			"un punto fuera de la zona no cuenta")
	outsider.queue_free()


func test_spawn_without_realms_falls_back_to_first() -> void:
	_zone = (load(Zones.get_scene_path(TEST_WORLD)) as PackedScene).instantiate()
	tree.root.add_child(_zone)
	await wait_process_frames()
	var spawns: Array[Node3D] = Zones.get_spawn_points(_zone)
	if not assert_false(spawns.is_empty(), "test_world tiene puntos de aparición"):
		return
	for realm: StringName in [&"vardheim", &"solmarch"]:
		assert_eq(Zones.find_spawn_point(_zone, realm), spawns[0],
				"%s: sin reinos en la zona se usa el primer punto" % realm)
	assert_null(Zones.find_spawn_point(null, &"vardheim"), "sin zona no hay punto")


func test_boot_parses_zone_and_realm() -> void:
	var defaults: Dictionary = BootScript.parse_client_options(PackedStringArray())
	assert_eq(defaults["zone"], Zones.DEFAULT_ZONE, "zona por defecto")
	assert_eq(defaults["realm"], Zones.DEFAULT_REALM, "reino por defecto")
	assert_false(defaults["demo"], "sin demo por defecto")
	assert_eq((defaults["warnings"] as PackedStringArray).size(), 0, "sin avisos")

	var options: Dictionary = BootScript.parse_client_options(PackedStringArray([
		"--zone=test_world", "--realm=Solmarch", "--demo",
		"--shots=\"C:\\capturas\\demo\"", "--quit-after-demo",
	]))
	assert_eq(options["zone"], TEST_WORLD, "--zone elige la zona")
	assert_eq(options["realm"], &"solmarch", "--realm elige el reino (sin distinguir mayúsculas)")
	assert_true(options["demo"], "--demo")
	assert_eq(options["shots_dir"], "C:/capturas/demo", "--shots sin comillas y con barras normales")
	assert_true(options["quit_after_demo"], "--quit-after-demo")
	assert_eq((options["warnings"] as PackedStringArray).size(), 0, "sin avisos")

	var wrong: Dictionary = BootScript.parse_client_options(PackedStringArray([
		"--zone=atlantida", "--realm=mordor", "--volar",
	]))
	assert_eq(wrong["zone"], Zones.DEFAULT_ZONE, "zona desconocida: la de por defecto")
	assert_eq(wrong["realm"], Zones.DEFAULT_REALM, "reino desconocido: el de por defecto")
	assert_eq((wrong["warnings"] as PackedStringArray).size(), 3, "un aviso por opción incorrecta")


func _raycast_down(zone: Node, point: Vector3) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = (zone as Node3D).get_world_3d().direct_space_state
	# Ligeramente inclinado: los rayos verticales pueden fallar contra HeightMapShape3D.
	var from: Vector3 = point + Vector3(0.0, 30.0, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.001, -60.0, 0.0), 1)
	return space.intersect_ray(query)
