extends TestCase
## Pruebas del cliente ([ClientMain]) arrancando en una zona real, headless.
##
## Comprueban lo que hace [code]boot.gd[/code] con [code]--zone=[/code] y [code]--realm=[/code]:
## que el personaje aparece en el punto de su reino, cae sobre el terreno de Terrain3D y se queda
## allí, que lleva el humanoide animado en lugar de la cápsula provisional, y que el terreno
## recibe la cámara del cliente (ZoneRoot). La escena compartida player_character.tscn no cambia:
## el visual se añade solo en el cliente.

const CLIENT_MAIN_SCENE: String = "res://scenes/client/client_main.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
## Ticks de física que se deja correr al cliente antes de comprobar el aterrizaje.
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
	if not assert_not_null(character, "hay personaje"):
		return
	var visual_root: Node3D = character.get_node_or_null(^"Visual") as Node3D
	if not assert_not_null(visual_root, "el personaje conserva su nodo Visual"):
		return
	var visual: HumanoidVisual = _client.get_visual()
	if not assert_not_null(visual, "el cliente instala el humanoide"):
		return
	assert_eq(visual.get_parent(), visual_root, "el humanoide cuelga de Visual (la cámara lo oculta de cerca)")
	assert_not_null(visual.get_skeleton(), "el humanoide tiene esqueleto")
	for child: Node in visual_root.get_children():
		assert_false(child is MeshInstance3D, "la malla provisional %s ya no está" % child.name)
	assert_eq(visual.get_animator().get_debug_state().is_empty(), false, "el animador funciona")
	# La escena compartida sigue siendo ligera: sin humanoide ni animaciones.
	var shared: Node = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate()
	assert_eq(_count_of_type(shared, "AnimationTree") + _count_of_type(shared, "Skeleton3D"), 0,
			"player_character.tscn no lleva esqueleto ni animaciones (la carga el servidor)")
	shared.free()


func test_test_world_still_boots_at_its_first_spawn() -> void:
	_client = _start_client(&"test_world", &"solmarch")
	await wait_physics_frames(SETTLE_TICKS)
	var world: Node = _client.get_world()
	var character: PlayerCharacter = _client.get_character()
	if not (assert_not_null(world, "carga test_world") and assert_not_null(character, "hay personaje")):
		return
	var first: Node3D = Zones.get_spawn_points(world)[0]
	var moved: Vector3 = character.global_position - first.global_position
	assert_true(Vector2(moved.x, moved.z).length() < 0.05, "aparece en el primer punto de test_world")
	assert_true(character.grounded, "está en el suelo")
	assert_not_null(_client.get_visual(), "también lleva el humanoide")


func _check_spawn_and_landing(realm: StringName) -> void:
	_client = _start_client(&"vado_gris", realm)
	await wait_physics_frames(SETTLE_TICKS)
	var world: Node = _client.get_world()
	var character: PlayerCharacter = _client.get_character()
	if not (assert_not_null(world, "carga el Vado Gris") and assert_not_null(character, "hay personaje")):
		return
	var spawn: Node3D = Zones.find_spawn_point(world, realm)
	if not assert_not_null(spawn, "hay punto de aparición de %s" % realm):
		return
	assert_eq(Zones.get_spawn_realm(spawn), realm, "el punto es de %s" % realm)
	var moved: Vector3 = character.global_position - spawn.global_position
	assert_true(Vector2(moved.x, moved.z).length() < 0.05,
			"%s aparece en %s (desviación %.3f m)" % [realm, spawn.name, Vector2(moved.x, moved.z).length()])
	assert_near(wrapf(character.yaw - spawn.global_rotation.y, -PI, PI), 0.0, 0.01,
			"mira hacia donde mira el punto de aparición (el fuerte)")
	assert_true(character.grounded, "%s: está en el suelo" % realm)
	var hit: Dictionary = _raycast_down(character)
	if assert_false(hit.is_empty(), "hay terreno bajo el personaje"):
		assert_near(character.global_position.y, (hit["position"] as Vector3).y, 0.1,
				"los pies quedan sobre el terreno")
		assert_true(hit["collider"] is Terrain3D, "el suelo del campamento es el Terrain3D")
	# En el cliente, ZoneRoot da la cámara al terreno y reactiva su proceso.
	var terrain: Terrain3D = world.get_node_or_null(^"Terrain3D") as Terrain3D
	if assert_not_null(terrain, "la zona tiene Terrain3D"):
		assert_true(terrain.is_physics_processing(), "con cámara, el terreno vuelve a procesar")
		assert_eq(terrain.get_camera(), _client.get_camera_rig().get_camera(),
				"el terreno sigue a la cámara de acción")


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
