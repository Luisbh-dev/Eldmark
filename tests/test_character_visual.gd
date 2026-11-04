extends TestCase
## Tests of the animated humanoid (client only) and of the assets' import settings.
##
## - Character draw budget: surfaces, triangles and meshes that cast shadows.
##   Each visible surface is a draw call, plus one per shadow cut.
## - Feet that do not slide: with the stride measured on the installed model
##   ([member CharacterAnimator.clip_ground_speeds]), the tip of the planted foot barely moves
##   relative to the ground when jogging (5 m/s) and sprinting (7.5 m/s).
## - Backpedaling facing forward: when going backward the model keeps facing forward (it does not
##   turn around toward the camera) and the locomotion runs in reverse; sideways, the spine compensates.
## - Model textures imported as VRAM-compressed with mipmaps (docs/arte.md, 4.2).

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const MODELS_DIR: String = "res://assets/models"
## Humanoid budget (Ranger + head, hair and beard), at LOD 0.
const MAX_VISIBLE_SURFACES: int = 14
const MAX_VISIBLE_TRIANGLES: int = 33000
const MAX_SHADOW_CASTERS: int = 9
## Maximum speed (m/s) of the planted foot's tip relative to the ground.
const MAX_PLANTED_SLIDE: float = 0.25
const WARMUP_TICKS: int = 75
const RECORD_FRAMES: int = 150
const PLANTED_TOLERANCE: float = 0.02

var _world: Node3D
var _character: PlayerCharacter
var _visual: HumanoidVisual


func before_each() -> void:
	_world = Node3D.new()
	tree.root.add_child(_world)
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000.0, 1.0, 4000.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	floor_body.add_child(shape)
	_world.add_child(floor_body)
	_character = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_world.add_child(_character)
	_visual = HumanoidVisual.install(_character)
	await wait_physics_frames(2)


func after_each() -> void:
	if is_instance_valid(_world):
		_world.get_parent().remove_child(_world)
		_world.queue_free()
	_world = null
	await wait_process_frames()


func test_humanoid_draw_budget() -> void:
	if not assert_not_null(_visual, "the humanoid is installed"):
		return
	var surfaces: int = 0
	var triangles: int = 0
	var shadow_casters: int = 0
	var names: PackedStringArray = []
	for child: Node in _visual.get_skeleton().get_children():
		var mesh_instance: MeshInstance3D = child as MeshInstance3D
		if mesh_instance == null or not mesh_instance.visible or mesh_instance.mesh == null:
			continue
		var mesh: Mesh = mesh_instance.mesh
		surfaces += mesh.get_surface_count()
		for surface: int in mesh.get_surface_count():
			triangles += (mesh as ArrayMesh).surface_get_array_index_len(surface) / 3
		if mesh_instance.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			shadow_casters += 1
			names.append(String(mesh_instance.name))
	assert_true(surfaces > 0, "the humanoid has visible meshes")
	assert_true(surfaces <= MAX_VISIBLE_SURFACES, "visible surfaces: %d (maximum %d)" % [surfaces, MAX_VISIBLE_SURFACES])
	assert_true(triangles <= MAX_VISIBLE_TRIANGLES, "triangles: %d (maximum %d)" % [triangles, MAX_VISIBLE_TRIANGLES])
	assert_true(shadow_casters <= MAX_SHADOW_CASTERS,
			"meshes with shadow: %d (maximum %d): %s" % [shadow_casters, MAX_SHADOW_CASTERS, ", ".join(names)])
	for small: String in ["Eyes", "Eyebrows", "Hair_Beard"]:
		var node: MeshInstance3D = _visual.get_skeleton().get_node_or_null(NodePath(small)) as MeshInstance3D
		if node != null:
			assert_eq(node.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "%s casts no shadow" % small)


func test_planted_feet_do_not_slide_when_running() -> void:
	if not assert_not_null(_visual, "the humanoid is installed"):
		return
	var jog: float = await _planted_slide(0)
	var sprint: float = await _planted_slide(PlayerInput.SPRINT)
	assert_true(absf(jog) <= MAX_PLANTED_SLIDE, "when jogging, the planted foot slides %.2f m/s (maximum %.2f)" % [jog, MAX_PLANTED_SLIDE])
	assert_true(absf(sprint) <= MAX_PLANTED_SLIDE, "when sprinting, the planted foot slides %.2f m/s (maximum %.2f)" % [sprint, MAX_PLANTED_SLIDE])


func test_backpedal_keeps_facing_forward() -> void:
	if not assert_not_null(_visual, "the humanoid is installed"):
		return
	var animator: CharacterAnimator = _visual.get_animator()
	await _run_ticks(Vector2(0.0, -1.0), 0, 90)
	var back: Dictionary = animator.get_debug_state()
	assert_true(bool(back["backpedal"]), "going backward it backpedals facing forward")
	assert_true(absf(float(back["facing_offset_deg"])) < 10.0,
			"going backward the model faces forward (turn %.0f°)" % float(back["facing_offset_deg"]))
	assert_true(float(back["locomotion_scale"]) < 0.0, "the locomotion runs in reverse")
	await _run_ticks(Vector2(1.0, 0.0), 0, 90)
	var side: Dictionary = animator.get_debug_state()
	assert_false(bool(side["backpedal"]), "sideways it does not backpedal")
	var offset: float = float(side["facing_offset_deg"])
	var twist: float = float(side["spine_twist_deg"])
	assert_true(absf(offset) > 60.0, "sideways the hips face where it runs (%.0f°)" % offset)
	assert_true(absf(offset + twist) < 25.0, "the spine brings the chest back toward the crosshair (%.0f° + %.0f°)" % [offset, twist])


func test_model_textures_are_vram_compressed_with_mipmaps() -> void:
	var checked: int = 0
	for png: String in _list_files(MODELS_DIR, "png"):
		var config := ConfigFile.new()
		if not assert_eq(config.load(png + ".import"), OK, "%s has .import" % png):
			continue
		checked += 1
		assert_eq(int(config.get_value("params", "compress/mode", -1)), 2, "%s: VRAM compressed" % png)
		assert_true(bool(config.get_value("params", "mipmaps/generate", false)), "%s: with mipmaps" % png)
		assert_eq(int(config.get_value("params", "detect_3d/compress_to", -1)), 0,
				"%s: without 3D detection (the editor does not rewrite it)" % png)
		if png.get_file().get_basename().to_lower().ends_with("_normal"):
			assert_eq(int(config.get_value("params", "compress/normal_map", -1)), 1, "%s: normal compression" % png)
	assert_true(checked > 30, "%d textures were checked" % checked)


## Runs forward (with [param buttons]) and returns the median of the speed (m/s, along the
## run) of the planted foot's tip relative to the ground: negative if it slides
## backward, positive if it gets ahead. So that the measurement does not depend on the frame rate, the
## animator and the animation tree are advanced by hand with the same step as the simulation.
func _planted_slide(buttons: int) -> float:
	var skeleton: Skeleton3D = _visual.get_skeleton()
	var animator: CharacterAnimator = _visual.get_animator()
	var animation_tree: AnimationTree = _visual.get_node(^"AnimationTree") as AnimationTree
	var bones: Array[int] = [skeleton.find_bone("LeftToes"), skeleton.find_bone("RightToes")]
	animator.set_process(false)
	animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	var samples: Array[Array] = [[], []]
	var tick: int = 1
	for f: int in WARMUP_TICKS + RECORD_FRAMES:
		await wait_physics_frames()
		_character.simulate(_input(tick, Vector2(0.0, 1.0), buttons), dt)
		tick += 1
		animator._process(dt)
		animation_tree.advance(dt)
		if f < WARMUP_TICKS:
			continue
		for k: int in 2:
			samples[k].append(skeleton.global_transform * skeleton.get_bone_global_pose(bones[k]).origin)
	var speeds: Array[float] = []
	for k: int in 2:
		var lowest: float = INF
		for p: Vector3 in samples[k]:
			lowest = minf(lowest, p.y)
		for j: int in range(1, samples[k].size()):
			var a: Vector3 = samples[k][j - 1]
			var b: Vector3 = samples[k][j]
			if a.y <= lowest + PLANTED_TOLERANCE and b.y <= lowest + PLANTED_TOLERANCE:
				# The character runs toward -Z (yaw 0).
				speeds.append(-(b.z - a.z) / dt)
	animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	animator.set_process(true)
	await _run_ticks(Vector2.ZERO, 0, 45)
	if not assert_true(speeds.size() >= 6, "foot plants were detected (%d samples)" % speeds.size()):
		return 0.0
	speeds.sort()
	return speeds[speeds.size() / 2]


## Simulates [param ticks] ticks, each within its own physics frame.
func _run_ticks(move: Vector2, buttons: int, ticks: int) -> void:
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	for t: int in ticks:
		await wait_physics_frames()
		_character.simulate(_input(t + 1, move, buttons), dt)
	await wait_process_frames()


func _input(tick: int, move: Vector2, buttons: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.move = move
	input.look_yaw = 0.0
	input.buttons = buttons
	return input.quantized()


func _list_files(dir: String, extension: String) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	for file_name: String in DirAccess.get_files_at(dir):
		if file_name.get_extension().to_lower() == extension:
			result.append(dir.path_join(file_name))
	for sub_dir: String in DirAccess.get_directories_at(dir):
		result.append_array(_list_files(dir.path_join(sub_dir), extension))
	return result
