extends Node
## Escena de arranque (escena principal del proyecto).
##
## Lee los argumentos de usuario de la línea de comandos (los que van después
## de [code]--[/code]) y decide en qué modo arranca el juego:
## [br]- [code]--server[/code]: servidor dedicado (pendiente, fase 2).
## [br]- [code]--demo[/code]: sandbox del cliente con entrada guionizada ([DemoInput]).
## [br]- [code]--shots=<carpeta absoluta>[/code]: durante la demo, guarda una captura
## PNG cada 90 ticks en esa carpeta ([code]shot_000.png[/code], ...).
## [br]- [code]--quit-after-demo[/code]: cierra el juego cuando termina la demo.
## [br]Sin argumentos (también en modo headless) arranca el sandbox del cliente.
## [br][br]Ejemplo:
## [code]godot --path . -- --demo --shots=C:/ruta/capturas --quit-after-demo[/code]

const CLIENT_MAIN_SCENE: String = "res://scenes/client/client_main.tscn"
const SERVER_ARG: String = "--server"
const DEMO_ARG: String = "--demo"
const SHOTS_ARG_PREFIX: String = "--shots="
const QUIT_AFTER_DEMO_ARG: String = "--quit-after-demo"


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has(SERVER_ARG):
		print("[Eldmark] Modo servidor: pendiente (fase 2)")
		get_tree().quit()
		return
	_start_client(args)


## Pasa las opciones a [ClientMain] mediante sus variables estáticas y cambia
## a la escena del cliente.
func _start_client(args: PackedStringArray) -> void:
	var demo_mode: bool = false
	var shots_dir: String = ""
	var quit_after_demo: bool = false

	for arg: String in args:
		if arg == DEMO_ARG:
			demo_mode = true
		elif arg.begins_with(SHOTS_ARG_PREFIX):
			shots_dir = arg.trim_prefix(SHOTS_ARG_PREFIX).strip_edges()
			shots_dir = shots_dir.trim_prefix("\"").trim_suffix("\"").replace("\\", "/")
		elif arg == QUIT_AFTER_DEMO_ARG:
			quit_after_demo = true
		else:
			push_warning("[Eldmark] Argumento desconocido: %s" % arg)

	if not demo_mode:
		var demo_only: String = "[Eldmark] %s solo tiene efecto junto con %s"
		if not shots_dir.is_empty():
			push_warning(demo_only % [SHOTS_ARG_PREFIX, DEMO_ARG])
		if quit_after_demo:
			push_warning(demo_only % [QUIT_AFTER_DEMO_ARG, DEMO_ARG])

	if DisplayServer.get_name() == "headless":
		print("[Eldmark] Sin pantalla (headless): arrancando el sandbox del cliente")

	ClientMain.demo_mode = demo_mode
	ClientMain.shots_dir = shots_dir
	ClientMain.quit_after_demo = quit_after_demo
	get_tree().change_scene_to_file.call_deferred(CLIENT_MAIN_SCENE)
