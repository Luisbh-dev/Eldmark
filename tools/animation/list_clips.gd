extends SceneTree
## Lista los clips de UAL1 y UAL2 (nombre y duración) y, con --tracks=<clip>, los huesos que animan.
## Uso: godot --headless --path . -s res://tools/animation/list_clips.gd -- [--tracks=ual1/Sword_Idle]

const LIBS: Dictionary = {
	"ual1": "res://assets/animations/ual1/UAL1_Standard.glb",
	"ual2": "res://assets/animations/ual2/UAL2_Standard.glb",
}


func _initialize() -> void:
	var wanted: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--tracks="):
			wanted = arg.substr(9)
	for key: String in LIBS:
		var library: AnimationLibrary = load(LIBS[key]) as AnimationLibrary
		for clip: StringName in library.get_animation_list():
			var animation: Animation = library.get_animation(clip)
			if wanted == "":
				print("%s/%s  %.3f s  pistas %d" % [key, clip, animation.length, animation.get_track_count()])
			elif wanted == "%s/%s" % [key, clip]:
				for track: int in animation.get_track_count():
					print(String(animation.track_get_path(track)), " tipo ", animation.track_get_type(track))
	quit(0)
