extends SceneTree
## Resumen de un registro de batalla (GUE-17; docs/fuerte.md, sección 7): lee el JSON Lines que escribe el
## servidor con [code]--battle-log=<ruta>[/code] y saca el tiempo hasta la captura, las muertes por ruta
## (puente, vado, pasarela) y el tiempo hasta romper la puerta, para ajustar
## [code]data/fortresses/vado_gris.tres[/code] sin tocar código. La lógica está en [BattleSummary].
## [br][br]
## [b]Uso[/b], desde la raíz del proyecto (el [code]godot[/code] de consola):
## [codeblock]
## godot --headless --path . -s res://tools/war/summarize_battle.gd -- build/batalla.jsonl
## godot --headless --path . -s res://tools/war/summarize_battle.gd -- build/batalla.jsonl --json
## godot --headless --path . -s res://tools/war/summarize_battle.gd -- build/batalla.jsonl --out=build/resumen.json
## [/codeblock]
## Sin [code]--json[/code] imprime el resumen en español; con él, el JSON. [code]--out=<ruta>[/code] guarda
## además el JSON. Las rutas de aproximación (para clasificar las muertes) se leen de
## [code]data/routes/<zona>.tres[/code] si existe. Termina con código 0, o 1 si no hay archivo.


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


# La zona de la primera línea del registro (battle_start), o una cadena vacía.
func _zone_of(text: String) -> String:
	var json := JSON.new()
	if json.parse(text.get_slice("\n", 0)) == OK and json.data is Dictionary:
		return String((json.data as Dictionary).get("zone", ""))
	return ""
