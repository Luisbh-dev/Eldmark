extends TestCase
## Tests for the zone registry ([Zones], shared) and for the [code]--zone=[/code] and [code]--realm=[/code]
## startup options of [code]boot.gd[/code].
##
## Every registered zone must load headless (as its dedicated server will load it), have spawn
## points and respond to selection by realm: the first one of that realm or, if the zone
## has no points for that realm, the first one in the zone.

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
	assert_eq(Zones.DEFAULT_ZONE, VADO_GRIS, "the default zone is the Vado Gris")
	assert_true(Zones.has_zone(Zones.DEFAULT_ZONE), "the default zone is registered")
	assert_eq(Zones.get_scene_path(VADO_GRIS), "res://scenes/world/zones/vado_gris/vado_gris.tscn",
			"Vado Gris scene")
	assert_eq(Zones.get_scene_path(TEST_WORLD), "res://scenes/world/test_world.tscn",
			"test circuit scene")
	assert_false(Zones.has_zone(&"atlantida"), "an invented zone does not exist")
	assert_eq(Zones.get_scene_path(&"atlantida"), "", "no scene for an invented zone")
	assert_eq(Zones.get_zone_ids(), [TEST_WORLD, VADO_GRIS] as Array[StringName],
			"sorted identifiers")
	for zone_id: StringName in Zones.get_zone_ids():
		assert_true(ResourceLoader.exists(Zones.get_scene_path(zone_id)),
				"the scene for %s exists" % zone_id)
	assert_eq(Zones.DEFAULT_REALM, &"vardheim", "default realm")
	assert_true(Zones.is_realm(&"solmarch"), "solmarch is a realm")
	assert_false(Zones.is_realm(&"mordor"), "an invented realm does not exist")


func test_every_zone_loads_headless_with_spawn_points() -> void:
	for zone_id: StringName in Zones.get_zone_ids():
		var scene: PackedScene = load(Zones.get_scene_path(zone_id)) as PackedScene
		if not assert_not_null(scene, "the scene for %s loads" % zone_id):
			continue
		_zone = scene.instantiate()
		tree.root.add_child(_zone)
		await wait_physics_frames(2)
		assert_false(Zones.get_spawn_points(_zone).is_empty(), "%s has spawn points" % zone_id)
		var spawn: Node3D = Zones.find_spawn_point(_zone, Zones.DEFAULT_REALM)
		if assert_not_null(spawn, "%s gives a spawn point" % zone_id):
			var hit: Dictionary = _raycast_down(_zone, spawn.global_position)
			assert_false(hit.is_empty(), "%s: there is ground under %s" % [zone_id, spawn.name])
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
	if not (assert_not_null(north, "there is a Vardheim point") and assert_not_null(south, "there is a Solmarch point")):
		return
	assert_eq(Zones.get_spawn_realm(north), &"vardheim", "the Vardheim point belongs to Vardheim")
	assert_eq(Zones.get_spawn_realm(south), &"solmarch", "the Solmarch point belongs to Solmarch")
	assert_true(north.global_position.z < -100.0, "Vardheim spawns to the north (-Z)")
	assert_true(south.global_position.z > 100.0, "Solmarch spawns to the south (+Z)")
	assert_eq(north, Zones.get_spawn_points(_zone, &"vardheim")[0], "the first one of its realm")
	assert_eq(Zones.get_spawn_points(_zone, &"vardheim").size(), 4, "4 Vardheim points")
	assert_eq(Zones.get_spawn_points(_zone, &"solmarch").size(), 4, "4 Solmarch points")
	# A realm with no points in this zone (Askarra has no front here) uses the first one in the zone.
	assert_eq(Zones.find_spawn_point(_zone, &"askarra"), Zones.get_spawn_points(_zone)[0],
			"with no points for that realm, the first one in the zone is used")
	# Points from another node in the tree do not count.
	var outsider: Marker3D = Marker3D.new()
	outsider.add_to_group(Zones.SPAWN_GROUP)
	outsider.set_meta(Zones.REALM_META, &"askarra")
	tree.root.add_child(outsider)
	assert_eq(Zones.find_spawn_point(_zone, &"askarra"), Zones.get_spawn_points(_zone)[0],
			"a point outside the zone does not count")
	outsider.queue_free()


func test_spawn_without_realms_falls_back_to_first() -> void:
	_zone = (load(Zones.get_scene_path(TEST_WORLD)) as PackedScene).instantiate()
	tree.root.add_child(_zone)
	await wait_process_frames()
	var spawns: Array[Node3D] = Zones.get_spawn_points(_zone)
	if not assert_false(spawns.is_empty(), "test_world has spawn points"):
		return
	for realm: StringName in [&"vardheim", &"solmarch"]:
		assert_eq(Zones.find_spawn_point(_zone, realm), spawns[0],
				"%s: with no realms in the zone the first point is used" % realm)
	assert_null(Zones.find_spawn_point(null, &"vardheim"), "with no zone there is no point")


func test_boot_parses_zone_and_realm() -> void:
	var defaults: Dictionary = BootScript.parse_client_options(PackedStringArray())
	assert_eq(defaults["zone"], Zones.DEFAULT_ZONE, "default zone")
	assert_eq(defaults["realm"], Zones.DEFAULT_REALM, "default realm")
	assert_false(defaults["demo"], "no demo by default")
	assert_eq((defaults["warnings"] as PackedStringArray).size(), 0, "no warnings")

	var options: Dictionary = BootScript.parse_client_options(PackedStringArray([
		"--zone=test_world", "--realm=Solmarch", "--demo",
		"--shots=\"C:\\capturas\\demo\"", "--quit-after-demo",
	]))
	assert_eq(options["zone"], TEST_WORLD, "--zone picks the zone")
	assert_eq(options["realm"], &"solmarch", "--realm picks the realm (case-insensitive)")
	assert_true(options["demo"], "--demo")
	assert_eq(options["shots_dir"], "C:/capturas/demo", "--shots without quotes and with normal slashes")
	assert_true(options["quit_after_demo"], "--quit-after-demo")
	assert_eq((options["warnings"] as PackedStringArray).size(), 0, "no warnings")

	var wrong: Dictionary = BootScript.parse_client_options(PackedStringArray([
		"--zone=atlantida", "--realm=mordor", "--volar",
	]))
	assert_eq(wrong["zone"], Zones.DEFAULT_ZONE, "unknown zone: the default one")
	assert_eq(wrong["realm"], Zones.DEFAULT_REALM, "unknown realm: the default one")
	assert_eq((wrong["warnings"] as PackedStringArray).size(), 3, "one warning per incorrect option")


func _raycast_down(zone: Node, point: Vector3) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = (zone as Node3D).get_world_3d().direct_space_state
	# Slightly tilted: vertical rays can miss against HeightMapShape3D.
	var from: Vector3 = point + Vector3(0.0, 30.0, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.001, -60.0, 0.0), 1)
	return space.intersect_ray(query)
