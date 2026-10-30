extends SceneTree
## Escribe [code]tests/fixtures/progression/save_cases.json[/code] con [method SaveFixtures.to_json]: los casos de las
## comprobaciones del guardado (docs/progresion.md §13.3) que comparten la zona y el almacén de Go (progresion.md P7).
## Es la única forma de cambiar ese archivo: [code]tests/test_progression_fixtures.gd[/code] falla si no coincide con
## lo que genera [PlayerProgress].
## [br][br]
## [b]Uso[/b], desde la raíz del proyecto (el [code]godot[/code] de consola):
## [codeblock]
## godot --headless --path . -s res://tools/progression/write_fixtures.gd
## godot --headless --path . -s res://tools/progression/write_fixtures.gd -- --check
## [/codeblock]
## Con [code]--check[/code] no escribe nada: sale con código 0 si el archivo está al día y 1 si no.
## Sin él, escribe el archivo (si ha cambiado) y sale con 0, o con 1 si no puede escribirlo.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var check_only: bool = OS.get_cmdline_user_args().has("--check")
	var text: String = SaveFixtures.to_json()
	var path: String = SaveFixtures.OUTPUT_PATH
	var current: String = ""
	if FileAccess.file_exists(path):
		current = FileAccess.get_file_as_string(path)
	if current == text:
		print("%s está al día." % path)
		quit(0)
		return
	if check_only:
		printerr("%s no coincide con los casos: ejecuta tools/progression/write_fixtures.gd." % path)
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
