extends SceneTree
## Writes [code]platform/internal/gamedata/progression_rules.json[/code] with
## [method ProgressionRulesExport.build] (docs/progression.md §13.4, docs/platform.md §4.4). It is the
## only way to change that file: [code]tests/test_progression_rules_export.gd[/code] fails if it
## does not match the rules in the code.
## [br][br]
## [b]Usage[/b], from the project root (the console [code]godot[/code]):
## [codeblock]
## godot --headless --path . -s res://tools/progression/export_rules.gd
## godot --headless --path . -s res://tools/progression/export_rules.gd -- --check
## [/codeblock]
## With [code]--check[/code] it writes nothing: it exits with code 0 if the file is up to date and 1 if not.
## Without it, it writes the file (if it changed) and exits with 0, or with 1 if it cannot write it.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var check_only: bool = OS.get_cmdline_user_args().has("--check")
	var text: String = ProgressionRulesExport.to_json()
	var path: String = ProgressionRulesExport.OUTPUT_PATH
	var current: String = ""
	if FileAccess.file_exists(path):
		current = FileAccess.get_file_as_string(path)
	if current == text:
		print("%s está al día." % path)
		quit(0)
		return
	if check_only:
		printerr("%s no coincide con las reglas: ejecuta tools/progression/export_rules.gd." % path)
		quit(1)
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("No se puede escribir %s: %s" % [path, error_string(FileAccess.get_open_error())])
		quit(1)
		return
	file.store_string(text)
	file.close()
	print("Escrito %s." % path)
	quit(0)
