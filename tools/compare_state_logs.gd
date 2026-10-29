extends SceneTree
## Cruza el registro de estados del servidor con el de un bot y resume las coincidencias, las
## diferencias explicadas (el servidor sustituyó una entrada) y las que no (docs/red.md, sección 13).
## [br][br]
## Uso, desde la raíz del proyecto (el [code]godot[/code] de consola):
## [codeblock]
## godot --headless --path . -s res://tools/compare_state_logs.gd -- <log_servidor> <log_bot> [net_id]
## [/codeblock]
## Los registros salen de [code]--state-log=<ruta>[/code] en el servidor (una línea
## [code]tick,net_id,sustituida,estado[/code] por tick y jugador) y en el bot
## ([code]server_tick,predicho,servidor[/code] por snapshot). [code]net_id[/code] es el jugador del
## servidor que era ese bot (sale en el informe del bot, [code]--report[/code]); si falta, se deduce
## comparando el primer snapshot del bot con el registro del servidor. Con rutas dentro del proyecto,
## usa la extensión [code].txt[/code]: el importador de Godot convierte los [code].csv[/code] en
## traducciones. Las rutas relativas cuentan desde el directorio actual.
## [br][br]
## Código de salida: 0 si no hay diferencias sin explicar ni errores, 1 si las hay (o falta algún
## tick, o el estado propio de un snapshot no es el del servidor) y 2 si el uso es incorrecto o no se
## puede comparar (archivos que faltan, registro del bot vacío, jugador desconocido o ambiguo...). La
## lógica está en [StateLogComparer].


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
