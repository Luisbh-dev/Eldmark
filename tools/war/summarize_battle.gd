extends SceneTree
## Summary of a battle log (GUE-17; docs/fuerte.md, section 7): reads the JSON Lines that the
## server writes with [code]--battle-log=<path>[/code] and extracts the time to capture, the deaths per route
## (bridge, ford, walkway) and the time to break the gate, to tune
## [code]data/fortresses/vado_gris.tres[/code] without touching code. The logic is in [BattleSummary].
## [br][br]
## [b]Usage[/b], from the project root (the console [code]godot[/code]):
## [codeblock]
## godot --headless --path . -s res://tools/war/summarize_battle.gd -- build/batalla.jsonl
## godot --headless --path . -s res://tools/war/summarize_battle.gd -- build/batalla.jsonl --json
## godot --headless --path . -s res://tools/war/summarize_battle.gd -- build/batalla.jsonl --out=build/resumen.json
## [/codeblock]
## Without [code]--json[/code] it prints the summary in Spanish; with it, the JSON. [code]--out=<path>[/code] also saves
## the JSON. The approach routes (to classify the deaths) are read from
## [code]data/routes/<zone>.tres[/code] if it exists. Exits with code 0, or 1 if there is no file.


func _initialize() -> void:
	var path: String = ""
	var as_json: bool = false
	var out_path: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--json":
			as_json = true
		elif arg.begins_with("--out="):
			out_path = arg.trim_prefix("--out=")
		elif not arg.begins_with("--") and path.is_empty():
			path = arg
	if path.is_empty() or not FileAccess.file_exists(path):
		push_error("Uso: summarize_battle.gd -- <registro.jsonl> [--json] [--out=<resumen.json>] "
				+ "(no existe '%s')" % path)
		quit(1)
		return
	var text: String = FileAccess.get_file_as_string(path)
	var zone_id: String = _zone_of(text)
	var routes: ApproachRoutes = null
	var routes_path: String = "res://data/routes/%s.tres" % zone_id
	if not zone_id.is_empty() and ResourceLoader.exists(routes_path):
		routes = load(routes_path) as ApproachRoutes
	var summary: Dictionary = BattleSummary.summarize(text, routes)
	if as_json:
		print(JSON.stringify(summary, "\t"))
	else:
		print(BattleSummary.format(summary))
	if not out_path.is_empty():
		var file: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(summary, "\t"))
			file.close()
	quit(0)


# The zone from the first line of the log (battle_start), or an empty string.
func _zone_of(text: String) -> String:
	var json := JSON.new()
	if json.parse(text.get_slice("\n", 0)) == OK and json.data is Dictionary:
		return String((json.data as Dictionary).get("zone", ""))
	return ""
