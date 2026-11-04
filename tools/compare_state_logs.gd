extends SceneTree
## Cross-checks the server's state log against a bot's and summarizes the matches, the
## explained differences (the server substituted an input) and the unexplained ones (docs/red.md, section 13).
## [br][br]
## Usage, from the project root (the console [code]godot[/code]):
## [codeblock]
## godot --headless --path . -s res://tools/compare_state_logs.gd -- <server_log> <bot_log> [net_id]
## [/codeblock]
## The logs come from [code]--state-log=<path>[/code] on the server (one line
## [code]tick,net_id,substituted,state[/code] per tick and player) and on the bot
## ([code]server_tick,predicted,server[/code] per snapshot). [code]net_id[/code] is the server player
## that this bot was (it appears in the bot's report, [code]--report[/code]); if missing, it is deduced
## by comparing the bot's first snapshot with the server's log. With paths inside the project,
## use the [code].txt[/code] extension: Godot's importer turns [code].csv[/code] files into
## translations. Relative paths count from the current directory.
## [br][br]
## Exit code: 0 if there are no unexplained differences or errors, 1 if there are (or a
## tick is missing, or a snapshot's own state is not the server's) and 2 if the usage is incorrect or it cannot
## be compared (missing files, empty bot log, unknown or ambiguous player...). The
## logic is in [StateLogComparer].


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 2 or args.size() > 3 or (args.size() == 3 and not args[2].is_valid_int()):
		printerr("Uso: godot --headless --path . -s res://tools/compare_state_logs.gd -- "
				+ "<log_servidor> <log_bot> [net_id]")
		quit(2)
		return
	var net_id: int = args[2].to_int() if args.size() == 3 else 0
	var result: StateLogComparer.Result = StateLogComparer.compare_files(args[0], args[1], net_id)
	print(result.summary())
	if not result.error.is_empty():
		quit(2)
	elif result.is_ok():
		quit(0)
	else:
		quit(1)
