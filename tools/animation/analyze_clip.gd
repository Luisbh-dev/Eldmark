extends SceneTree
## Analyzes a UAL clip on the installed model to choose trim ranges: every [step] seconds
## it prints the hands' speed (m/s, in model space), their height and their forward advance,
## and the hip height. It serves to find where the strike is (the right hand's speed peak)
## and where the recovery ends.
## [br][br]
## Usage (without a window):
## [codeblock]
## godot --headless --path . -s res://tools/animation/analyze_clip.gd -- --clip=ual2/Sword_Regular_A [--step=0.05] [--bone=RightHand]
## [/codeblock]

const VISUAL_SCENE: String = "res://scenes/characters/visuals/humanoid_visual.tscn"
const LIBS: Dictionary = {
	"ual1": "res://assets/animations/ual1/UAL1_Standard.glb",
	"ual2": "res://assets/animations/ual2/UAL2_Standard.glb",
}


func _initialize() -> void:
	_run()


func _run() -> void:
	var clip_name: String = ""
	var step: float = 0.05
	var bones: PackedStringArray = ["RightHand", "LeftHand", "Head", "LeftFoot", "RightFoot"]
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--clip="):
			clip_name = arg.substr(7)
		elif arg.begins_with("--step="):
			step = float(arg.substr(7))
		elif arg.begins_with("--bones="):
			bones = arg.substr(8).split(",")
	await process_frame
	var visual: Node3D = (load(VISUAL_SCENE) as PackedScene).instantiate() as Node3D
	root.add_child(visual)
	await process_frame
	var animator: Node = visual.call(&"get_animator")
	animator.set_process(false)
	var skeleton: Skeleton3D = visual.call(&"get_skeleton")
	for modifier: Node in skeleton.get_children():
		if modifier is SkeletonModifier3D:
			(modifier as SkeletonModifier3D).active = false
	for one_clip: String in clip_name.split(","):
		_analyze(skeleton, one_clip, step, bones)
	quit(0)


func _analyze(skeleton: Skeleton3D, clip_name: String, step: float, bones: PackedStringArray) -> void:
	var slash: int = clip_name.find("/")
	var library: AnimationLibrary = load(LIBS[clip_name.substr(0, slash)]) as AnimationLibrary
	var animation: Animation = library.get_animation(StringName(clip_name.substr(slash + 1)))
	print("clip %s  %.3f s" % [clip_name, animation.length])
	var previous: Dictionary = {}
	var t: float = 0.0
	while t <= animation.length + 0.0001:
		_pose(skeleton, animation, minf(t, animation.length))
		var line: String = "t=%.3f" % t
		var hips: Vector3 = skeleton.get_bone_global_pose(skeleton.find_bone(&"Hips")).origin
		line += "  caderas y=%.2f" % hips.y
		for bone_name: String in bones:
			var bone: int = skeleton.find_bone(StringName(bone_name))
			var position: Vector3 = skeleton.get_bone_global_pose(bone).origin
			var speed: float = 0.0
			if previous.has(bone_name):
				speed = position.distance_to(previous[bone_name]) / step
			previous[bone_name] = position
			# The model faces +Z in the skeleton (it is turned 180 degrees in the scene): forward = +z.
			line += "  | %s v=%.1f y=%.2f z=%.2f x=%.2f" % [bone_name, speed, position.y, position.z, position.x]
		print(line)
		t += step


func _pose(skeleton: Skeleton3D, animation: Animation, time: float) -> void:
	for track: int in animation.get_track_count():
		var type: int = animation.track_get_type(track)
		var path: String = String(animation.track_get_path(track))
		var bone: int = skeleton.find_bone(path.substr(path.rfind(":") + 1))
		if bone < 0:
			continue
		if type == Animation.TYPE_ROTATION_3D:
			skeleton.set_bone_pose_rotation(bone, animation.rotation_track_interpolate(track, time))
		elif type == Animation.TYPE_POSITION_3D and skeleton.get_bone_name(bone) == "Hips":
			skeleton.set_bone_pose_position(bone, animation.position_track_interpolate(track, time))
	skeleton.force_update_all_bone_transforms()
