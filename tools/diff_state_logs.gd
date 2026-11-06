extends SceneTree
## Compares two server state logs of the same seeded scenario that ran on different operating systems (TEC-12).
## [codeblock]
## godot --headless --path . -s res://tools/diff_state_logs.gd -- <log_a> <log_b>
## [/codeblock]
## Exit code: 0 if there are only identical lines or last-bit differences, 1 if there are larger ones or unpaired
## lines, 2 if the usage is wrong or a log cannot be read. The logic is in [StateLogDiffer].


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 2:
		printerr("Usage: godot --headless --path . -s res://tools/diff_state_logs.gd -- <log_a> <log_b>")
		quit(2)
		return
	var result: StateLogDiffer.Result = StateLogDiffer.compare_files(args[0], args[1])
	print(result.summary())
	if not result.error.is_empty():
		quit(2)
	elif result.is_ok():
		quit(0)
	else:
		quit(1)
