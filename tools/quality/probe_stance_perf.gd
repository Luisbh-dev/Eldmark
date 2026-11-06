extends SceneTree
## Measures the cost of [ArmedStanceModifier] (C12): builds N animated visuals, then times only the stance's
## [code]_process_modification[/code] over many frames in three situations (standing, walking, attacking with the
## shield arm reserved).
## [codeblock]
## godot --headless --path . -s res://tools/quality/probe_stance_perf.gd -- --count=40 --iterations=300
## [/codeblock]

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var count: int = 40
	var iterations: int = 300
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--count="):
			count = int(arg.get_slice("=", 1))
		elif arg.begins_with("--iterations="):
			iterations = int(arg.get_slice("=", 1))
	await process_frame
	await process_frame
	var world := Node3D.new()
	root.add_child(world)
	var stances: Array[ArmedStanceModifier] = []
	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	for index: int in count:
		var character: PlayerCharacter = scene.instantiate() as PlayerCharacter
		world.add_child(character)
		var visual: HumanoidVisual = HumanoidVisual.install(character)
		stances.append(visual.get_animator().get_stance_modifier())
		visual.get_animator().set_process(false)
	for _frame: int in 3:
		await process_frame
	var cases: Array[Dictionary] = [
		{"name": "standing", "rest": 1.0, "arms": 0.8, "reserved": 0.0},
		{"name": "walking", "rest": 0.3, "arms": 0.8, "reserved": 0.0},
		{"name": "attacking", "rest": 0.0, "arms": 0.8, "reserved": 1.0},
	]
	for case: Dictionary in cases:
		for stance: ArmedStanceModifier in stances:
			stance.master_weight = 1.0
			stance.rest_weight = float(case["rest"])
			stance.arm_weight = float(case["arms"])
			stance.left_arm_reserved = float(case["reserved"])
			stance.grip_weight = 1.0
		for stance: ArmedStanceModifier in stances:
			stance._process_modification()
		var start: int = Time.get_ticks_usec()
		for iteration: int in iterations:
			for stance: ArmedStanceModifier in stances:
				stance.rest_time = float(iteration) * 0.016
				stance._process_modification()
		var total_us: float = float(Time.get_ticks_usec() - start)
		print("[stance-perf] %-10s %d visuals: %.3f ms per frame (%.1f us per visual)" % [case["name"], count,
				total_us / float(iterations) / 1000.0, total_us / float(iterations * count)])
	quit(0)
