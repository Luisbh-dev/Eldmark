extends TestCase
## Pruebas del humanoide animado (solo cliente) y de los ajustes de importación de los assets.
##
## - Presupuesto de dibujo del personaje: superficies, triángulos y mallas que proyectan sombra.
##   Cada superficie visible es una llamada de dibujo, más una por corte de sombra.
## - Pies que no patinan: con la zancada medida sobre el modelo instalado
##   ([member CharacterAnimator.clip_ground_speeds]), la punta del pie apoyado apenas se mueve
##   respecto al suelo al trotar (5 m/s) y al esprintar (7,5 m/s).
## - Retroceso de cara: al ir hacia atrás el modelo sigue mirando hacia delante (no se da la
##   vuelta hacia la cámara) y la locomoción va al revés; de lado, la columna compensa.
## - Texturas de modelos importadas como VRAM comprimida con mipmaps (docs/arte.md, 4.2).

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const MODELS_DIR: String = "res://assets/models"
## Presupuesto del humanoide (Ranger + cabeza, pelo y barba), a LOD 0.
const MAX_VISIBLE_SURFACES: int = 14
const MAX_VISIBLE_TRIANGLES: int = 33000
const MAX_SHADOW_CASTERS: int = 9
## Velocidad máxima (m/s) de la punta del pie apoyado respecto al suelo.
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
	if not assert_not_null(_visual, "se instala el humanoide"):
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
	assert_true(surfaces > 0, "el humanoide tiene mallas visibles")
	assert_true(surfaces <= MAX_VISIBLE_SURFACES, "superficies visibles: %d (máximo %d)" % [surfaces, MAX_VISIBLE_SURFACES])
	assert_true(triangles <= MAX_VISIBLE_TRIANGLES, "triángulos: %d (máximo %d)" % [triangles, MAX_VISIBLE_TRIANGLES])
	assert_true(shadow_casters <= MAX_SHADOW_CASTERS,
			"mallas con sombra: %d (máximo %d): %s" % [shadow_casters, MAX_SHADOW_CASTERS, ", ".join(names)])
	for small: String in ["Eyes", "Eyebrows", "Hair_Beard"]:
		var node: MeshInstance3D = _visual.get_skeleton().get_node_or_null(NodePath(small)) as MeshInstance3D
		if node != null:
			assert_eq(node.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "%s no proyecta sombra" % small)


func test_planted_feet_do_not_slide_when_running() -> void:
	if not assert_not_null(_visual, "se instala el humanoide"):
		return
	var jog: float = await _planted_slide(0)
	var sprint: float = await _planted_slide(PlayerInput.SPRINT)
	assert_true(absf(jog) <= MAX_PLANTED_SLIDE, "trotando, el pie apoyado se desliza %.2f m/s (máximo %.2f)" % [jog, MAX_PLANTED_SLIDE])
	assert_true(absf(sprint) <= MAX_PLANTED_SLIDE, "esprintando, el pie apoyado se desliza %.2f m/s (máximo %.2f)" % [sprint, MAX_PLANTED_SLIDE])


func test_backpedal_keeps_facing_forward() -> void:
	if not assert_not_null(_visual, "se instala el humanoide"):
		return
	var animator: CharacterAnimator = _visual.get_animator()
	await _run_ticks(Vector2(0.0, -1.0), 0, 90)
	var back: Dictionary = animator.get_debug_state()
	assert_true(bool(back["backpedal"]), "hacia atrás retrocede de cara")
	assert_true(absf(float(back["facing_offset_deg"])) < 10.0,
			"hacia atrás el modelo mira hacia delante (giro %.0f°)" % float(back["facing_offset_deg"]))
	assert_true(float(back["locomotion_scale"]) < 0.0, "la locomoción va al revés")
	await _run_ticks(Vector2(1.0, 0.0), 0, 90)
	var side: Dictionary = animator.get_debug_state()
	assert_false(bool(side["backpedal"]), "de lado no retrocede")
	var offset: float = float(side["facing_offset_deg"])
	var twist: float = float(side["spine_twist_deg"])
	assert_true(absf(offset) > 60.0, "de lado las caderas miran hacia donde se corre (%.0f°)" % offset)
	assert_true(absf(offset + twist) < 25.0, "la columna devuelve el pecho hacia el punto de mira (%.0f° + %.0f°)" % [offset, twist])


func test_model_textures_are_vram_compressed_with_mipmaps() -> void:
	var checked: int = 0
	for png: String in _list_files(MODELS_DIR, "png"):
		var config := ConfigFile.new()
		if not assert_eq(config.load(png + ".import"), OK, "%s tiene .import" % png):
			continue
		checked += 1
		assert_eq(int(config.get_value("params", "compress/mode", -1)), 2, "%s: VRAM comprimida" % png)
		assert_true(bool(config.get_value("params", "mipmaps/generate", false)), "%s: con mipmaps" % png)
		assert_eq(int(config.get_value("params", "detect_3d/compress_to", -1)), 0,
				"%s: sin detección 3D (el editor no la reescribe)" % png)
		if png.get_file().get_basename().to_lower().ends_with("_normal"):
			assert_eq(int(config.get_value("params", "compress/normal_map", -1)), 1, "%s: compresión de normales" % png)
	assert_true(checked > 30, "se han comprobado %d texturas" % checked)


## Corre hacia delante (con [param buttons]) y devuelve la mediana de la velocidad (m/s, a lo
## largo de la carrera) de la punta del pie apoyado respecto al suelo: negativa si patina hacia
## atrás, positiva si se adelanta. Para que la medida no dependa del ritmo de fotogramas, el
## animador y el árbol de animación se avanzan a mano con el mismo paso que la simulación.
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
				# El personaje corre hacia -Z (yaw 0).
				speeds.append(-(b.z - a.z) / dt)
	animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	animator.set_process(true)
	await _run_ticks(Vector2.ZERO, 0, 45)
	if not assert_true(speeds.size() >= 6, "se han detectado apoyos (%d muestras)" % speeds.size()):
		return 0.0
	speeds.sort()
	return speeds[speeds.size() / 2]


## Simula [param ticks] ticks, cada uno dentro de su fotograma de física.
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
