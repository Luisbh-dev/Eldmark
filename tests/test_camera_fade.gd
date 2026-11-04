extends TestCase
## Difuminado de los personajes ajenos pegados a la cámara (ART-53): [member HumanoidVisual.camera_fade] pone un
## rango de visibilidad con fundido en todas las mallas del visual (también las de las piezas y las armas que se
## monten después), lo quita al apagarlo, y los remotos de [RemoteWorld] lo llevan encendido mientras que el
## visual propio no.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"

var _world: Node3D
var _nodes: Array[Node] = []


func before_each() -> void:
	_world = Node3D.new()
	tree.root.add_child(_world)


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			node.get_parent().remove_child(node)
			node.queue_free()
	_nodes.clear()
	if is_instance_valid(_world):
		_world.get_parent().remove_child(_world)
		_world.queue_free()
	_world = null
	await wait_process_frames()


func _install() -> HumanoidVisual:
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_world.add_child(character)
	return HumanoidVisual.install_replacing_placeholder(character)


func _meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		out.append_array(_meshes(child))
	return out


func test_the_visual_does_not_fade_by_default() -> void:
	var visual: HumanoidVisual = _install()
	await wait_process_frames()
	var meshes: Array[MeshInstance3D] = _meshes(visual)
	assert_false(meshes.is_empty(), "el visual tiene mallas")
	for mesh: MeshInstance3D in meshes:
		assert_eq(mesh.transparency, 0.0, "%s opaca" % mesh.name)


func _camera_at(distance: float, visual: HumanoidVisual) -> Camera3D:
	var camera := Camera3D.new()
	_world.add_child(camera)
	_nodes.append(camera)
	camera.global_position = visual.global_position + Vector3.UP * HumanoidVisual.CAMERA_FADE_CHEST_HEIGHT 			+ Vector3(0.0, 0.0, distance)
	camera.make_current()
	return camera


func test_fade_for_distance_goes_from_solid_to_hidden() -> void:
	assert_eq(HumanoidVisual.fade_for_distance(HumanoidVisual.CAMERA_FADE_SOLID + 1.0), 0.0, "lejos, opaco")
	assert_eq(HumanoidVisual.fade_for_distance(HumanoidVisual.CAMERA_FADE_HIDDEN - 0.1), 1.0, "pegado, invisible")
	var middle: float = HumanoidVisual.fade_for_distance((HumanoidVisual.CAMERA_FADE_SOLID + HumanoidVisual.CAMERA_FADE_HIDDEN) * 0.5)
	assert_near(middle, 0.5, 0.001, "a medio camino, mitad")


func test_camera_fade_gives_every_mesh_the_same_transparency() -> void:
	var visual: HumanoidVisual = _install()
	await wait_process_frames()
	_camera_at(0.8, visual)
	visual.camera_fade = true
	var expected: float = HumanoidVisual.fade_for_distance(0.8)
	assert_true(expected > 0.0 and expected < 1.0, "a 0,8 m está a medias")
	var meshes: Array[MeshInstance3D] = _meshes(visual)
	assert_false(meshes.is_empty(), "el visual tiene mallas")
	# Todas, también el escudo, las armas y las botas, llevan la misma atenuación.
	for mesh: MeshInstance3D in meshes:
		assert_near(mesh.transparency, expected, 0.001, "%s con la transparencia del visual" % mesh.name)


func test_camera_fade_reaches_the_weapons_and_the_parts_mounted_later() -> void:
	var visual: HumanoidVisual = _install()
	await wait_process_frames()
	_camera_at(0.8, visual)
	visual.camera_fade = true
	var expected: float = HumanoidVisual.fade_for_distance(0.8)
	var skeleton: Skeleton3D = visual.get_skeleton()
	var sword: Node = skeleton.get_node_or_null(NodePath(WeaponProps.SWORD_ATTACHMENT))
	if assert_not_null(sword, "la espada provisional está colgada"):
		for mesh: MeshInstance3D in _meshes(sword):
			assert_near(mesh.transparency, expected, 0.001, "la malla de la espada se atenúa")
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	if assert_not_null(catalog, "hay catálogo de apariencia") and catalog.heads.size() > 1:
		var other: PackedScene = load(catalog.heads[1].scene_path) as PackedScene
		visual.set_part(&"head", other)
		var head_meshes: Array[MeshInstance3D] = visual.get_part_meshes(&"head")
		assert_false(head_meshes.is_empty(), "la cabeza nueva tiene mallas")
		for mesh: MeshInstance3D in head_meshes:
			assert_near(mesh.transparency, expected, 0.001, "%s montada después se atenúa" % mesh.name)


func test_turning_camera_fade_off_clears_the_ranges() -> void:
	var visual: HumanoidVisual = _install()
	await wait_process_frames()
	_camera_at(0.8, visual)
	visual.camera_fade = true
	visual.camera_fade = false
	for mesh: MeshInstance3D in _meshes(visual):
		assert_eq(mesh.transparency, 0.0, "%s opaca" % mesh.name)


func test_remote_visuals_fade_but_the_local_one_does_not() -> void:
	var clock := InterpolationClock.new()
	var remote_world := RemoteWorld.new()
	remote_world.install_visuals = true
	remote_world.setup(clock)
	tree.root.add_child(remote_world)
	_nodes.append(remote_world)
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = 21
	spawn.kind = NetProtocol.EntityKind.PLAYER
	spawn.spawn_tick = 1
	spawn.realm = NetProtocol.Realm.VARDHEIM
	spawn.display_name = "Ana"
	var state := PlayerState.new()
	state.grounded = true
	spawn.state = state
	remote_world.on_spawn(spawn)
	var view: RemotePlayerView = remote_world.get_view(21)
	if not assert_not_null(view, "el remoto tiene vista"):
		return
	var remote_visual: HumanoidVisual = view.get_body().get_node_or_null(^"Visual/HumanoidVisual") as HumanoidVisual
	if not assert_not_null(remote_visual, "el remoto lleva el humanoide"):
		return
	await wait_process_frames()
	assert_true(remote_visual.camera_fade, "el remoto se difumina junto a la cámara")
	var local_visual: HumanoidVisual = _install()
	await wait_process_frames()
	assert_false(local_visual.camera_fade, "el visual propio no lleva el fundido")
