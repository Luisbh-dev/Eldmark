extends TestCase
## Tests for the client ([ClientMain]) starting in a real zone, headless.
##
## They check what [code]boot.gd[/code] does with [code]--zone=[/code] and [code]--realm=[/code]:
## that the character appears at the point of its realm, falls onto the Terrain3D terrain and stays
## there, that it carries the animated humanoid instead of the provisional capsule, and that the terrain
## receives the client camera (ZoneRoot). The shared scene player_character.tscn does not change:
## the visual is added only on the client.

const CLIENT_MAIN_SCENE: String = "res://scenes/client/client_main.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
## Physics ticks the client is allowed to run before checking the landing.
const SETTLE_TICKS: int = 45

var _client: ClientMain
var _saved: Dictionary = {}


func before_each() -> void:
	_saved = {
		"zone_id": ClientMain.zone_id, "realm": ClientMain.realm, "demo_mode": ClientMain.demo_mode,
		"shots_dir": ClientMain.shots_dir, "quit_after_demo": ClientMain.quit_after_demo,
	}


func after_each() -> void:
	if is_instance_valid(_client):
		_client.get_parent().remove_child(_client)
		_client.queue_free()
	_client = null
	ClientMain.zone_id = _saved["zone_id"]
	ClientMain.realm = _saved["realm"]
	ClientMain.demo_mode = _saved["demo_mode"]
	ClientMain.shots_dir = _saved["shots_dir"]
	ClientMain.quit_after_demo = _saved["quit_after_demo"]
	await wait_process_frames(2)


func test_vardheim_spawns_in_its_camp_and_lands() -> void:
	await _check_spawn_and_landing(&"vardheim")


func test_solmarch_spawns_in_its_camp_and_lands() -> void:
	await _check_spawn_and_landing(&"solmarch")


func test_client_uses_humanoid_visual_instead_of_capsule() -> void:
	_client = _start_client(&"vado_gris", &"vardheim")
	await wait_process_frames(2)
	var character: PlayerCharacter = _client.get_character()
	if not assert_not_null(character, "there is a character"):
		return
	var visual_root: Node3D = character.get_node_or_null(^"Visual") as Node3D
	if not assert_not_null(visual_root, "the character keeps its Visual node"):
		return
	var visual: HumanoidVisual = _client.get_visual()
	if not assert_not_null(visual, "the client installs the humanoid"):
		return
	assert_eq(visual.get_parent(), visual_root, "the humanoid hangs from Visual (the camera hides it up close)")
	assert_not_null(visual.get_skeleton(), "the humanoid has a skeleton")
	for child: Node in visual_root.get_children():
		assert_false(child is MeshInstance3D, "the provisional mesh %s is gone" % child.name)
	assert_eq(visual.get_animator().get_debug_state().is_empty(), false, "the animator works")
	# The shared scene stays lightweight: no humanoid or animations.
	var shared: Node = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate()
	assert_eq(_count_of_type(shared, "AnimationTree") + _count_of_type(shared, "Skeleton3D"), 0,
			"player_character.tscn carries no skeleton or animations (the server loads it)")
	shared.free()


func test_test_world_still_boots_at_its_first_spawn() -> void:
	_client = _start_client(&"test_world", &"solmarch")
	await wait_physics_frames(SETTLE_TICKS)
	var world: Node = _client.get_world()
	var character: PlayerCharacter = _client.get_character()
	if not (assert_not_null(world, "loads test_world") and assert_not_null(character, "there is a character")):
		return
	var first: Node3D = Zones.get_spawn_points(world)[0]
	var moved: Vector3 = character.global_position - first.global_position
	assert_true(Vector2(moved.x, moved.z).length() < 0.05, "it appears at the first point of test_world")
	assert_true(character.grounded, "it is on the ground")
	assert_not_null(_client.get_visual(), "it also carries the humanoid")


func _check_spawn_and_landing(realm: StringName) -> void:
	_client = _start_client(&"vado_gris", realm)
	await wait_physics_frames(SETTLE_TICKS)
	var world: Node = _client.get_world()
	var character: PlayerCharacter = _client.get_character()
	if not (assert_not_null(world, "loads Vado Gris") and assert_not_null(character, "there is a character")):
		return
	var spawn: Node3D = Zones.find_spawn_point(world, realm)
	if not assert_not_null(spawn, "there is a spawn point for %s" % realm):
		return
	assert_eq(Zones.get_spawn_realm(spawn), realm, "the point belongs to %s" % realm)
	var moved: Vector3 = character.global_position - spawn.global_position
	assert_true(Vector2(moved.x, moved.z).length() < 0.05,
			"%s appears at %s (deviation %.3f m)" % [realm, spawn.name, Vector2(moved.x, moved.z).length()])
	assert_near(wrapf(character.yaw - spawn.global_rotation.y, -PI, PI), 0.0, 0.01,
			"it faces where the spawn point faces (the fort)")
	assert_true(character.grounded, "%s: it is on the ground" % realm)
	var hit: Dictionary = _raycast_down(character)
	if assert_false(hit.is_empty(), "there is terrain under the character"):
		assert_near(character.global_position.y, (hit["position"] as Vector3).y, 0.1,
				"the feet are on the terrain")
		assert_true(hit["collider"] is Terrain3D, "the camp ground is the Terrain3D")
	# On the client, ZoneRoot gives the camera to the terrain and re-enables its processing.
	var terrain: Terrain3D = world.get_node_or_null(^"Terrain3D") as Terrain3D
	if assert_not_null(terrain, "the zone has Terrain3D"):
		assert_true(terrain.is_physics_processing(), "with a camera, the terrain processes again")
		assert_eq(terrain.get_camera(), _client.get_camera_rig().get_camera(),
				"the terrain follows the action camera")


func _start_client(zone_id: StringName, realm: StringName) -> ClientMain:
	ClientMain.zone_id = zone_id
	ClientMain.realm = realm
	ClientMain.demo_mode = false
	ClientMain.shots_dir = ""
	ClientMain.quit_after_demo = false
	var client: ClientMain = (load(CLIENT_MAIN_SCENE) as PackedScene).instantiate() as ClientMain
	tree.root.add_child(client)
	return client


func _raycast_down(character: PlayerCharacter) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = character.get_world_3d().direct_space_state
	var from: Vector3 = character.global_position + Vector3(0.0, 2.0, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.001, -10.0, 0.0), 1)
	return space.intersect_ray(query)


static func _count_of_type(node: Node, type_name: String) -> int:
	var count: int = 1 if node.is_class(type_name) else 0
	for child: Node in node.get_children():
		count += _count_of_type(child, type_name)
	return count
