extends SceneTree
## Proceso auxiliar de [code]test_architecture.gd[/code] (no es una prueba: el ejecutor solo descubre
## [code]test_*.gd[/code]). Arranca el proyecto como lo hace la escena principal: instancia
## [code]res://scenes/boot.tscn[/code] con los argumentos de usuario (los que van tras [code]--[/code];
## con [code]--server[/code], el servidor dedicado de una zona), espera a que el servidor esté en marcha
## ([code]ZoneServer[/code] más unos pasos de física) y entonces informa, con líneas que empiezan por
## [code]LOADED <ruta>[/code], de cada script de [code]res://scripts/client/[/code] que ha quedado
## cargado en el proceso, y cierra con [code]DONE total=<n> loaded=<n>[/code]. Si el servidor no
## arranca en [constant TIMEOUT_MSEC] ms, escribe [code]TIMEOUT[/code] y sale con código 2.
## [br][br]
## Con [code]--probe-control=<ruta>[/code], tras el informe carga ese script y escribe
## [code]CONTROL <ruta> true|false[/code] según haya quedado en la caché: así la prueba sabe que este
## detector ve de verdad lo que se carga.

const BOOT_SCENE: String = "res://scenes/boot.tscn"
const CLIENT_DIR: String = "res://scripts/client"
const CONTROL_PREFIX: String = "--probe-control="
## Espera máxima (ms) a que arranque el servidor.
const TIMEOUT_MSEC: int = 20000
## Pasos de física que se dejan correr al servidor una vez en marcha.
const SETTLE_PHYSICS_FRAMES: int = 30

var _started_msec: int = 0
var _server_frame: int = -1


func _initialize() -> void:
	_started_msec = Time.get_ticks_msec()
	var boot: Node = (load(BOOT_SCENE) as PackedScene).instantiate()
	root.add_child(boot)
	current_scene = boot


func _process(_delta: float) -> bool:
	var scene: Node = current_scene
	if scene != null and scene.get_node_or_null(^"ZoneServer") != null:
		if _server_frame < 0:
			_server_frame = Engine.get_physics_frames()
		elif Engine.get_physics_frames() - _server_frame >= SETTLE_PHYSICS_FRAMES:
			_report()
			return true
	elif Time.get_ticks_msec() - _started_msec > TIMEOUT_MSEC:
		print("TIMEOUT")
		quit(2)
		return true
	return false


func _report() -> void:
	var scripts: PackedStringArray = _list_scripts(CLIENT_DIR)
	var loaded: int = 0
	for path: String in scripts:
		if ResourceLoader.has_cached(path):
			loaded += 1
			print("LOADED %s" % path)
	print("DONE total=%d loaded=%d" % [scripts.size(), loaded])
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(CONTROL_PREFIX):
			var control: String = arg.trim_prefix(CONTROL_PREFIX)
			load(control)
			print("CONTROL %s %s" % [control, str(ResourceLoader.has_cached(control)).to_lower()])
	quit(0)


func _list_scripts(dir_path: String) -> PackedStringArray:
	var found := PackedStringArray()
	for file_name: String in DirAccess.get_files_at(dir_path):
		if file_name.ends_with(".gd"):
			found.append(dir_path.path_join(file_name))
	for sub: String in DirAccess.get_directories_at(dir_path):
		found.append_array(_list_scripts(dir_path.path_join(sub)))
	return found
