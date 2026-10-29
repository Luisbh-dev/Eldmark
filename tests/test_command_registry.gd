extends TestCase
## Pruebas de [CommandRegistry] (docs/combate.md, sección 6; TEC-19): el registro único de los
## comandos de red (con ids fijos de [constant NetProtocol.DEBUG_COMMAND_IDS]) y de consola, la
## ejecución, los resultados y la auditoría de cada uso.

var _calls: Array[String] = []
var _sink: Array[String] = []


func _console_ok(ctx: CommandRegistry.Context) -> String:
	_calls.append("consola:%s" % ",".join(ctx.args))
	return "hecho"


func _console_noted(ctx: CommandRegistry.Context) -> String:
	ctx.note = "con nota"
	return "respuesta"


func _net_ok(ctx: CommandRegistry.Context) -> int:
	_calls.append("red:%d" % ctx.payload.size())
	return CommandRegistry.Result.OK


func _net_bad(ctx: CommandRegistry.Context) -> int:
	ctx.note = "datos mal"
	return CommandRegistry.Result.BAD_ARGUMENTS


func _net_refused(_ctx: CommandRegistry.Context) -> int:
	return CommandRegistry.Result.REFUSED


func _registry() -> CommandRegistry:
	var registry := CommandRegistry.new()
	registry.audit_sink = func(line: String) -> void: _sink.append(line)
	return registry


func _peer() -> ServerPeer:
	var peer := ServerPeer.new(4)
	peer.display_name = "Ana"
	return peer


func test_registers_console_and_network_commands() -> void:
	var registry: CommandRegistry = _registry()
	assert_true(registry.register(&"heal", "heal <jugador>", _console_ok, _net_ok))
	assert_true(registry.register(&"announce", "announce <texto>", _console_ok))
	assert_true(registry.has_command(&"heal"))
	assert_false(registry.has_command(&"kill"))
	assert_eq(registry.get_names(), PackedStringArray(["announce", "heal"]), "ordenados")
	assert_eq(registry.get_usage(&"heal"), "heal <jugador>")
	assert_eq(registry.get_usage(&"nada"), "")


func test_a_network_command_needs_a_fixed_id() -> void:
	var registry: CommandRegistry = _registry()
	allow_logged_errors()
	assert_false(registry.register(&"inventado", "x", _console_ok, _net_ok),
			"un comando de red sin id fijo en NetProtocol se rechaza")
	assert_false(registry.has_command(&"inventado"))
	assert_true(registry.register(&"inventado", "x", _console_ok),
			"como comando de consola sí se admite")
	assert_false(registry.register(&"inventado", "x", _console_ok), "un nombre repetido, no")
	assert_false(registry.register(&"vacio", "x", Callable()), "sin manejadores, no")


func test_missing_network_commands_lists_the_ids_without_a_handler() -> void:
	var registry: CommandRegistry = _registry()
	var all_names := PackedStringArray()
	for command_name: StringName in NetProtocol.DEBUG_COMMAND_IDS:
		all_names.append(String(command_name))
	all_names.sort()
	assert_eq(registry.missing_network_commands(), all_names, "al principio faltan todos")
	registry.register(&"teleport", "x", _console_ok, _net_ok)
	registry.register(&"heal", "x", _console_ok)
	var missing: PackedStringArray = registry.missing_network_commands()
	assert_false(missing.has("teleport"), "teleport ya tiene manejador de red")
	assert_true(missing.has("heal"), "heal solo tiene el de consola")
	assert_eq(missing.size(), all_names.size() - 1)


func test_ids_of_the_network_commands_are_fixed() -> void:
	# Los ids son parte del protocolo: no se reutilizan ni se reordenan.
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"teleport"], 1)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"heal"], 2)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"kill"], 3)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"stamina_inf"], 4)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"set_weapon"], 5)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"spawn_dummy"], 6)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"unstuck"], 7)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"fort_reset"], 8)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"fort_owner"], 9)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"fort_kill_captain"], 10)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"fort_capture_speed"], 11)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"npc_debug"], 12)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS.size(), 12)


func test_network_execution_results_and_audit() -> void:
	var registry: CommandRegistry = _registry()
	registry.register(&"heal", "x", _console_ok, _net_ok)
	registry.register(&"kill", "x", _console_ok, _net_bad)
	registry.register(&"stamina_inf", "x", _console_ok, _net_refused)
	var peer: ServerPeer = _peer()
	assert_eq(registry.execute_network(peer, NetProtocol.DEBUG_HEAL, PackedByteArray()),
			CommandRegistry.Result.OK)
	assert_eq(registry.execute_network(peer, NetProtocol.DEBUG_KILL, PackedByteArray([1, 2])),
			CommandRegistry.Result.BAD_ARGUMENTS)
	assert_eq(registry.execute_network(peer, NetProtocol.DEBUG_STAMINA_INF, PackedByteArray()),
			CommandRegistry.Result.REFUSED)
	assert_eq(registry.execute_network(peer, 99, PackedByteArray()), CommandRegistry.Result.UNKNOWN,
			"un id que no existe")
	assert_eq(registry.execute_network(peer, NetProtocol.DEBUG_SET_WEAPON, PackedByteArray()),
			CommandRegistry.Result.UNKNOWN, "un id con nombre pero sin manejador registrado")
	assert_eq(_calls, ["red:0"] as Array[String])
	assert_eq(registry.audit_total, 5, "los cinco usos, también los fallidos, quedan auditados")
	assert_eq(registry.audit.size(), 5)
	assert_eq(registry.audit[0], "[auditoría] peer 4 (Ana): heal -> ok")
	assert_eq(registry.audit[1], "[auditoría] peer 4 (Ana): kill [2 B] -> argumentos no válidos (datos mal)")
	assert_eq(registry.audit[2], "[auditoría] peer 4 (Ana): stamina_inf -> rechazado")
	assert_eq(registry.audit[3], "[auditoría] peer 4 (Ana): id 99 -> desconocido")
	assert_eq(_sink.size(), 5, "y cada línea va al registro del servidor")
	assert_eq(_sink[0], registry.audit[0])


func test_audit_names_the_entity_of_the_peer() -> void:
	var registry: CommandRegistry = _registry()
	registry.register(&"heal", "x", _console_ok, _net_ok)
	var peer: ServerPeer = _peer()
	peer.entity = NetEntity.new()
	peer.entity.net_id = 12
	registry.execute_network(peer, NetProtocol.DEBUG_HEAL, PackedByteArray())
	assert_eq(registry.audit[0], "[auditoría] peer 4 (Ana, net_id 12): heal -> ok")


func test_console_parsing_and_responses() -> void:
	var registry: CommandRegistry = _registry()
	registry.register(&"kick", "kick <jugador> [motivo]", _console_ok)
	registry.register(&"announce", "announce <texto>", _console_noted)
	assert_eq(registry.execute_console("kick Ana por tramposa"), "hecho")
	assert_eq(_calls, ["consola:Ana,por,tramposa"] as Array[String], "los argumentos separados")
	assert_eq(registry.execute_console("  /KICK   Bea  "), "hecho", "barra, mayúsculas y espacios")
	assert_eq(_calls[1], "consola:Bea")
	assert_eq(registry.execute_console("kick"), "hecho", "sin argumentos")
	assert_eq(_calls[2], "consola:")
	assert_eq(registry.execute_console("announce hola"), "respuesta")
	assert_eq(registry.execute_console(""), "", "una línea vacía no hace nada")
	assert_eq(registry.execute_console("   "), "")
	assert_true(registry.execute_console("help").begins_with("Comandos: announce, kick"))
	assert_true(registry.execute_console("volar alto").begins_with("Comando desconocido: volar"))
	# La auditoría: las vacías no cuentan; las desconocidas sí; la nota sustituye a la respuesta.
	assert_eq(registry.audit_total, 6)
	assert_eq(registry.audit[0], "[auditoría] consola: kick Ana por tramposa -> hecho")
	assert_eq(registry.audit[3], "[auditoría] consola: announce hola -> con nota")
	assert_eq(registry.audit[4], "[auditoría] consola: help")
	assert_eq(registry.audit[5], "[auditoría] consola: volar alto -> desconocido")


func test_a_command_with_only_a_network_handler_is_not_in_the_console() -> void:
	var registry: CommandRegistry = _registry()
	registry.register(&"heal", "x", Callable(), _net_ok)
	assert_true(registry.execute_console("heal Ana").begins_with("Comando desconocido"))


func test_audit_keeps_only_the_latest_entries() -> void:
	var registry: CommandRegistry = _registry()
	registry.register(&"kick", "x", _console_ok)
	for index: int in CommandRegistry.MAX_AUDIT_ENTRIES + 25:
		registry.execute_console("kick jugador%d" % index)
	assert_eq(registry.audit_total, CommandRegistry.MAX_AUDIT_ENTRIES + 25)
	assert_eq(registry.audit.size(), CommandRegistry.MAX_AUDIT_ENTRIES)
	assert_true(registry.audit[0].contains("jugador25"), "se pierden las más antiguas")
	assert_true(registry.audit[registry.audit.size() - 1].contains(
			"jugador%d" % (CommandRegistry.MAX_AUDIT_ENTRIES + 24)))
