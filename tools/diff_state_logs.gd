extends SceneTree
## Compares two server state logs of the same seeded scenario that ran on different operating systems (TEC-12).
## [codeblock]
## godot --headless --path . -s res://tools/diff_state_logs.gd -- <log_a> <log_b> [--strict]
## [/codeblock]
## Exit code: 0 if the logs could be compared line by line (it reports how much they differ; different platforms
## are not bit-exact, see docs/networking.md section 14), 1 with [code]--strict[/code] if they are not identical or
## some line is only in one of them, 2 if the usage is wrong or a log cannot be read. The logic is in [StateLogDiffer].


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var strict: bool = args.has("--strict")
	var paths: PackedStringArray = PackedStringArray()
	for arg: String in args:
		if arg != "--strict":
			paths.append(arg)
	if paths.size() != 2:
		printerr("Usage: godot --headless --path . -s res://tools/diff_state_logs.gd -- <log_a> <log_b> [--strict]")
		quit(2)
		return
	var result: StateLogDiffer.Result = StateLogDiffer.compare_files(paths[0], paths[1])
	print(result.summary())
	if not result.error.is_empty():
		quit(2)
	elif not result.is_comparable() or (strict and not result.is_exact()):
		quit(1)
	else:
		quit(0)
