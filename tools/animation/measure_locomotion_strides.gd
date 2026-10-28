extends SceneTree
## Mide la velocidad sobre el suelo de los clips de locomoción del humanoide tal como se ven en
## el modelo instalado (Ranger con la cabeza Superhero, 1,84 m), para ajustar
## [member CharacterAnimator.clip_ground_speeds].
##
## Reproduce cada clip solo (el resto del BlendSpace a cero), en el sitio y a un ciclo por
## segundo, y mide la velocidad hacia atrás de las puntas de los pies (huesos LeftToes y
## RightToes) en el espacio del modelo mientras están apoyadas (a menos de 2 cm de su punto más
## bajo), en coordenadas del mundo con el modelo quieto en el origen. Esa velocidad es la zancada por ciclo; dividida entre la duración natural del clip da
## la velocidad sobre el suelo a velocidad de reproducción 1.
## [br][br]
## Uso (sin ventana; --fixed-fps hace la medida determinista):
## [codeblock]
## godot --headless --path . --fixed-fps 60 -s res://tools/animation/measure_locomotion_strides.gd
## [/codeblock]

const VISUAL_SCENE: String = "res://scenes/characters/visuals/humanoid_visual.tscn"
## Fotogramas que se dejan pasar antes de medir y fotogramas medidos (a 60 por segundo).
const WARMUP_FRAMES: int = 90
const RECORD_FRAMES: int = 240
## Altura sobre el punto más bajo por debajo de la cual el pie cuenta como apoyado (m).
const PLANTED_TOLERANCE: float = 0.02

var _visual: Node3D
var _tree: AnimationTree
var _skeleton: Skeleton3D


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	_visual = (load(VISUAL_SCENE) as PackedScene).instantiate() as Node3D
	root.add_child(_visual)
	await process_frame
	# Sin personaje el animador no toca el árbol: se conduce a mano.
	var animator: Node = _visual.call(&"get_animator")
	animator.set_process(false)
	_tree = _visual.get_node(^"AnimationTree") as AnimationTree
	_skeleton = _visual.call(&"get_skeleton")
	var blend_space: AnimationNodeBlendSpace1D = (_tree.tree_root as AnimationNodeBlendTree).get_node(&"locomotion") as AnimationNodeBlendSpace1D
	var results: Dictionary = {}
	for i: int in blend_space.get_blend_point_count():
		var node: AnimationNodeAnimation = blend_space.get_blend_point_node(i) as AnimationNodeAnimation
		var position: float = blend_space.get_blend_point_position(i)
		var stride: float = await _measure_stride(position)
		var clip_length: float = _tree.get_animation(node.animation).length
		var ground_speed: float = stride / clip_length
		results[node.animation] = ground_speed
		print("%-22s punto %.3f  zancada %.3f m/ciclo  duración %.3f s  -> %.3f m/s" % [node.animation,
				position, stride, clip_length, ground_speed])
	var lines: PackedStringArray = []
	for key: StringName in results:
		lines.append("\t&\"%s\": %.3f," % [key, results[key]])
	print("clip_ground_speeds = {\n%s\n}" % "\n".join(lines))
	quit(0)


## Zancada (m por ciclo) del clip que está en [param blend_position] del BlendSpace.
func _measure_stride(blend_position: float) -> float:
	_tree.set(&"parameters/move/blend_amount", 1.0)
	_tree.set(&"parameters/air/blend_amount", 0.0)
	_tree.set(&"parameters/land/blend_amount", 0.0)
	_tree.set(&"parameters/locomotion/blend_position", blend_position)
	_tree.set(&"parameters/locomotion_speed/scale", 1.0)
	for _i: int in WARMUP_FRAMES:
		await process_frame
	var bones: Array[int] = [_skeleton.find_bone("LeftToes"), _skeleton.find_bone("RightToes")]
	var samples: Array[Array] = [[], []]
	for _f: int in RECORD_FRAMES:
		await process_frame
		for k: int in 2:
			samples[k].append(_skeleton.global_transform * _skeleton.get_bone_global_pose(bones[k]).origin)
	var speeds: Array[float] = []
	var dt: float = 1.0 / 60.0
	for k: int in 2:
		var lowest: float = INF
		for p: Vector3 in samples[k]:
			lowest = minf(lowest, p.y)
		for j: int in range(1, samples[k].size()):
			var a: Vector3 = samples[k][j - 1]
			var b: Vector3 = samples[k][j]
			if a.y <= lowest + PLANTED_TOLERANCE and b.y <= lowest + PLANTED_TOLERANCE:
				# El modelo mira hacia -Z (como el PlayerCharacter): el pie apoyado va hacia +Z.
				speeds.append((b.z - a.z) / dt)
	speeds.sort()
	if speeds.is_empty():
		push_error("No se detectó ningún apoyo en el punto %.3f" % blend_position)
		return 0.0
	# Un ciclo por segundo: la velocidad del pie apoyado es la zancada por ciclo.
	return speeds[speeds.size() / 2]
