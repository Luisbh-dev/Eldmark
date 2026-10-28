extends Node
## Escena de arranque (escena principal del proyecto).
##
## Lee los argumentos de usuario de la línea de comandos (los que van después
## de [code]--[/code]) y decide en qué modo arranca el juego:
## [br]- [code]--server[/code]: servidor dedicado (pendiente, fase 2).
## [br]- [code]--zone=<id>[/code]: zona que se carga ([code]vado_gris[/code] por defecto,
## [code]test_world[/code] para el circuito de la fase 1). Ver [Zones].
## [br]- [code]--realm=<reino>[/code]: reino del jugador ([code]vardheim[/code] por defecto o
## [code]solmarch[/code]); decide en qué punto de aparición de la zona se empieza.
## [br]- [code]--demo[/code]: sandbox del cliente con entrada guionizada ([DemoInput]).
## [br]- [code]--shots=<carpeta absoluta>[/code]: durante la demo, guarda una captura
## PNG cada 90 ticks en esa carpeta ([code]shot_000.png[/code], ...) y, al terminar, una desde
## cada cámara de revisión de la zona ([code]zona_<nombre>.png[/code]).
## [br]- [code]--quit-after-demo[/code]: cierra el juego cuando termina la demo.
## [br]Sin argumentos (también en modo headless) arranca el cliente en el Vado Gris.
## [br][br]Ejemplo:
## [code]godot --path . -- --zone=vado_gris --realm=solmarch --demo --shots=C:/ruta/capturas --quit-after-demo[/code]

const CLIENT_MAIN_SCENE: String = "res://scenes/client/client_main.tscn"
const SERVER_ARG: String = "--server"
const DEMO_ARG: String = "--demo"
const SHOTS_ARG_PREFIX: String = "--shots="
const QUIT_AFTER_DEMO_ARG: String = "--quit-after-demo"
const ZONE_ARG_PREFIX: String = "--zone="
const REALM_ARG_PREFIX: String = "--realm="


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has(SERVER_ARG):
		print("[Eldmark] Modo servidor: pendiente (fase 2)")
		get_tree().quit()
		return
	_start_client(args)


## Interpreta los argumentos de usuario del cliente. Devuelve un diccionario con
## [code]zone[/code] y [code]realm[/code] ([StringName]), [code]demo[/code] y
## [code]quit_after_demo[/code] ([bool]), [code]shots_dir[/code] ([String]) y
## [code]warnings[/code] ([PackedStringArray], avisos para el usuario). Una zona o un reino
## desconocidos se sustituyen por los de por defecto, con aviso.
static func parse_client_options(args: PackedStringArray) -> Dictionary:
	var options: Dictionary = {
		"zone": Zones.DEFAULT_ZONE,
		"realm": Zones.DEFAULT_REALM,
		"demo": false,
		"shots_dir": "",
		"quit_after_demo": false,
	}
	var warnings: PackedStringArray = PackedStringArray()

	for arg: String in args:
		if arg == DEMO_ARG:
			options["demo"] = true
		elif arg.begins_with(SHOTS_ARG_PREFIX):
			options["shots_dir"] = _clean_path(arg.trim_prefix(SHOTS_ARG_PREFIX))
		elif arg == QUIT_AFTER_DEMO_ARG:
			options["quit_after_demo"] = true
		elif arg.begins_with(ZONE_ARG_PREFIX):
			var zone: StringName = StringName(_clean_value(arg.trim_prefix(ZONE_ARG_PREFIX)))
			if Zones.has_zone(zone):
				options["zone"] = zone
			else:
				warnings.append("Zona desconocida '%s' (hay: %s); se usa %s" % [zone,
						", ".join(Zones.get_zone_ids()), Zones.DEFAULT_ZONE])
		elif arg.begins_with(REALM_ARG_PREFIX):
			var realm: StringName = StringName(_clean_value(arg.trim_prefix(REALM_ARG_PREFIX)))
			if Zones.is_realm(realm):
				options["realm"] = realm
			else:
				warnings.append("Reino desconocido '%s' (hay: %s); se usa %s" % [realm,
						", ".join(Zones.REALMS), Zones.DEFAULT_REALM])
		else:
			warnings.append("Argumento desconocido: %s" % arg)

	if not options["demo"]:
		var demo_only: String = "%s solo tiene efecto junto con %s"
		if not String(options["shots_dir"]).is_empty():
			warnings.append(demo_only % [SHOTS_ARG_PREFIX, DEMO_ARG])
		if options["quit_after_demo"]:
			warnings.append(demo_only % [QUIT_AFTER_DEMO_ARG, DEMO_ARG])

	options["warnings"] = warnings
	return options


## Pasa las opciones a [ClientMain] mediante sus variables estáticas y cambia
## a la escena del cliente.
func _start_client(args: PackedStringArray) -> void:
	var options: Dictionary = parse_client_options(args)
	for warning: String in options["warnings"]:
		push_warning("[Eldmark] %s" % warning)

	if DisplayServer.get_name() == "headless":
		print("[Eldmark] Sin pantalla (headless): arrancando el cliente")

	ClientMain.zone_id = options["zone"]
	ClientMain.realm = options["realm"]
	ClientMain.demo_mode = options["demo"]
	ClientMain.shots_dir = options["shots_dir"]
	ClientMain.quit_after_demo = options["quit_after_demo"]
	get_tree().change_scene_to_file.call_deferred(CLIENT_MAIN_SCENE)


## Valor de una opción sin espacios ni comillas alrededor, en minúsculas.
static func _clean_value(value: String) -> String:
	return value.strip_edges().trim_prefix("\"").trim_suffix("\"").to_lower()


## Ruta de una opción sin espacios ni comillas alrededor y con barras normales.
static func _clean_path(value: String) -> String:
	return value.strip_edges().trim_prefix("\"").trim_suffix("\"").replace("\\", "/")
