extends TestCase
## Fading of other characters pressed against the camera (ART-53): [member HumanoidVisual.camera_fade] sets a
## visibility range with a fade on all the visual's meshes (also those of the pieces and weapons mounted
## later), removes it when turned off, and the [RemoteWorld] remotes have it on while the
## own visual does not.

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
	assert_false(meshes.is_empty(), "the visual has meshes")
	for mesh: MeshInstance3D in meshes:
		assert_eq(mesh.transparency, 0.0, "%s opaque" % mesh.name)


func _camera_at(distance: float, visual: HumanoidVisual) -> Camera3D:
	var camera := Camera3D.new()
	_world.add_child(camera)
	_nodes.append(camera)
	camera.global_position = visual.global_position + Vector3.UP * HumanoidVisual.CAMERA_FADE_CHEST_HEIGHT \
			+ Vector3(0.0, 0.0, distance)
	camera.make_current()
	return camera


func test_fade_for_distance_goes_from_solid_to_hidden() -> void:
	assert_eq(HumanoidVisual.fade_for_distance(HumanoidVisual.CAMERA_FADE_SOLID + 1.0), 0.0, "far away, opaque")
	assert_eq(HumanoidVisual.fade_for_distance(HumanoidVisual.CAMERA_FADE_HIDDEN - 0.1), 1.0, "right up close, invisible")
	var middle: float = HumanoidVisual.fade_for_distance((HumanoidVisual.CAMERA_FADE_SOLID + HumanoidVisual.CAMERA_FADE_HIDDEN) * 0.5)
	assert_near(middle, 0.5, 0.001, "halfway, half")


func test_camera_fade_gives_every_mesh_the_same_transparency() -> void:
	var visual: HumanoidVisual = _install()
	await wait_process_frames()
	_camera_at(0.8, visual)
	visual.camera_fade = true
	var expected: float = HumanoidVisual.fade_for_distance(0.8)
	assert_true(expected > 0.0 and expected < 1.0, "at 0.8 m it is half faded")
	var meshes: Array[MeshInstance3D] = _meshes(visual)
	assert_false(meshes.is_empty(), "the visual has meshes")
	# All of them, also the shield, the weapons and the boots, carry the same attenuation.
	for mesh: MeshInstance3D in meshes:
		assert_near(mesh.transparency, expected, 0.001, "%s with the visual's transparency" % mesh.name)


func test_camera_fade_reaches_the_weapons_and_the_parts_mounted_later() -> void:
	var visual: HumanoidVisual = _install()
	await wait_process_frames()
	_camera_at(0.8, visual)
	visual.camera_fade = true
	var expected: float = HumanoidVisual.fade_for_distance(0.8)
	var skeleton: Skeleton3D = visual.get_skeleton()
	var sword: Node = skeleton.get_node_or_null(NodePath(WeaponProps.SWORD_ATTACHMENT))
	if assert_not_null(sword, "the placeholder sword is attached"):
		for mesh: MeshInstance3D in _meshes(sword):
			assert_near(mesh.transparency, expected, 0.001, "the sword's mesh is attenuated")
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	if assert_not_null(catalog, "there is an appearance catalog") and catalog.heads.size() > 1:
		var other: PackedScene = load(catalog.heads[1].scene_path) as PackedScene
		visual.set_part(&"head", other)
		var head_meshes: Array[MeshInstance3D] = visual.get_part_meshes(&"head")
		assert_false(head_meshes.is_empty(), "the new head has meshes")
		for mesh: MeshInstance3D in head_meshes:
			assert_near(mesh.transparency, expected, 0.001, "%s mounted afterward is attenuated" % mesh.name)


func test_turning_camera_fade_off_clears_the_ranges() -> void:
	var visual: HumanoidVisual = _install()
	await wait_process_frames()
	_camera_at(0.8, visual)
	visual.camera_fade = true
	visual.camera_fade = false
	for mesh: MeshInstance3D in _meshes(visual):
		assert_eq(mesh.transparency, 0.0, "%s opaque" % mesh.name)


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
	if not assert_not_null(view, "the remote has a view"):
		return
	var remote_visual: HumanoidVisual = view.get_body().get_node_or_null(^"Visual/HumanoidVisual") as HumanoidVisual
	if not assert_not_null(remote_visual, "the remote carries the humanoid"):
		return
	await wait_process_frames()
	assert_true(remote_visual.camera_fade, "the remote fades next to the camera")
	var local_visual: HumanoidVisual = _install()
	await wait_process_frames()
	assert_false(local_visual.camera_fade, "the own visual carries no fade")
