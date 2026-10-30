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
	# Protocolo 6 (docs/habilidades.md, sección 5.1).
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"cooldowns_off"], 13)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"apply_status"], 14)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"down"], 15)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"refill"], 16)
	# Protocolo 7 (docs/progresion.md §10): los de GM de la progresión.
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"item_give"], 40)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"currency_add"], 41)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"level_set"], 42)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"xp_add"], 43)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS.size(), 20)


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


# --- Roles (docs/plataforma.md §9.1, P7b) ----------------------------------------------------------

func test_roles_are_ordered_and_a_command_declares_its_minimum() -> void:
	assert_eq(CommandRegistry.ROLES, ClaimedCharacter.ROLES, "los mismos roles que la reclamación")
	assert_true(CommandRegistry.role_allows(&"admin", &"gm"))
	assert_true(CommandRegistry.role_allows(&"gm", &"gm"))
	assert_false(CommandRegistry.role_allows(&"moderator", &"gm"))
	assert_false(CommandRegistry.role_allows(&"player", &"moderator"))
	assert_false(CommandRegistry.role_allows(&"inventado", &"player"), "un rol desconocido no llega a nada")
	var registry: CommandRegistry = _registry()
	assert_true(registry.register(&"heal", "heal <jugador>", _console_ok, _net_ok))
	assert_true(registry.register(&"kick", "kick <jugador>", _console_ok, Callable(), &"moderator"))
	assert_eq(registry.get_min_role(&"heal"), &"gm", "gm por defecto")
	assert_eq(registry.get_min_role(&"kick"), &"moderator")
	allow_logged_errors()
	assert_false(registry.register(&"announce", "x", _console_ok, Callable(), &"jefe"), "un rol que no existe")
	assert_eq(registry.get_names_for(&"moderator"), PackedStringArray(["kick"]))
	assert_eq(registry.get_names_for(&"gm"), PackedStringArray(["heal", "kick"]))
	assert_eq(registry.get_names_for(&"player"), PackedStringArray())


func test_a_network_command_with_a_role_needs_its_minimum() -> void:
	var registry: CommandRegistry = _registry()
	var entries: Array = []
	registry.audit_entry_sink = func(ctx: CommandRegistry.Context, command_name: StringName, result: String) -> void:
		entries.append([ctx.origin, ctx.role, command_name, result])
	registry.register(&"heal", "x", _console_ok, _net_ok)
	var peer: ServerPeer = _peer()
	assert_eq(registry.execute_network(peer, NetProtocol.DEBUG_HEAL, PackedByteArray(), &"player"),
			CommandRegistry.Result.FORBIDDEN, "un jugador no")
	assert_eq(registry.execute_network(peer, NetProtocol.DEBUG_HEAL, PackedByteArray(), &"moderator"),
			CommandRegistry.Result.FORBIDDEN, "un moderador tampoco")
	assert_eq(_calls, [] as Array[String], "no se ejecuta")
	assert_eq(registry.audit[0], "[auditoría] peer 4 (Ana): heal -> sin permiso (player; hace falta gm)")
	assert_eq(registry.execute_network(peer, NetProtocol.DEBUG_HEAL, PackedByteArray(), &"gm"),
			CommandRegistry.Result.OK)
	assert_eq(registry.execute_network(peer, NetProtocol.DEBUG_HEAL, PackedByteArray()), CommandRegistry.Result.OK,
			"sin rol (sin plataforma), como en la fase 4")
	assert_eq(_calls, ["red:0", "red:0"] as Array[String])
	assert_eq(entries, [[CommandRegistry.Origin.NETWORK, &"gm", &"heal", "ok"],
			[CommandRegistry.Origin.NETWORK, &"", &"heal", "ok"]], "solo lo ejecutado va a la auditoría de la plataforma")


## progresion.md P5d: un comando puede pedir por la red otro rol que por /gm (los 40–43 y el 16: admin y gm).
func test_a_network_command_can_need_another_role_than_by_chat() -> void:
	var registry: CommandRegistry = _registry()
	assert_true(registry.register(&"item_give", "x", _console_ok, _net_ok, &"gm", &"admin"))
	allow_logged_errors()
	assert_false(registry.register(&"refill", "x", _console_ok, _net_ok, &"gm", &"jefe"), "un rol que no existe")
	assert_eq([registry.get_min_role(&"item_give"), registry.get_network_min_role(&"item_give")], [&"gm", &"admin"])
	var peer: ServerPeer = _peer()
	assert_eq(registry.execute_network(peer, NetProtocol.DEBUG_ITEM_GIVE, PackedByteArray(), &"gm"),
			CommandRegistry.Result.FORBIDDEN, "por la red, gm no llega")
	assert_eq(registry.audit[0], "[auditoría] peer 4 (Ana): item_give -> sin permiso (gm; hace falta admin)")
	assert_eq(registry.execute_network(peer, NetProtocol.DEBUG_ITEM_GIVE, PackedByteArray(), &"admin"),
			CommandRegistry.Result.OK)
	assert_true(registry.can_use(&"item_give", &"gm"), "por /gm basta gm")
	registry.register(&"heal", "x", _console_ok, _net_ok)
	assert_eq(registry.get_network_min_role(&"heal"), &"gm", "sin él, el de siempre")


func test_chat_commands_answer_unknown_without_the_role() -> void:
	var registry: CommandRegistry = _registry()
	var entries: Array = []
	registry.audit_entry_sink = func(ctx: CommandRegistry.Context, command_name: StringName, _result: String) -> void:
		entries.append([ctx.origin, ctx.peer.peer_id if ctx.peer != null else 0, ctx.args, command_name])
	registry.register(&"heal", "heal <jugador>", _console_ok, _net_ok)
	registry.register(&"kick", "kick <jugador> [motivo]", _console_ok, Callable(), &"moderator")
	registry.register(&"kill", "x", Callable(), _net_ok)
	var peer: ServerPeer = _peer()
	for line: String in ["heal Bea", "kick Bea", "volar", "", "ayuda", "kill"]:
		assert_eq(registry.execute_chat(peer, line, &"player"), CommandRegistry.TEXT_UNKNOWN, "«%s» sin rol" % line)
	assert_eq(registry.execute_chat(peer, "heal Bea", &"moderator"), CommandRegistry.TEXT_UNKNOWN,
			"un moderador no tiene los de gm")
	assert_eq(registry.execute_chat(peer, "KICK  Bea por spam", &"moderator"), "hecho", "sin distinguir mayúsculas")
	assert_eq(_calls, ["consola:Bea,por,spam"] as Array[String])
	assert_eq(registry.execute_chat(peer, "ayuda", &"moderator"), CommandRegistry.TEXT_CHAT_HELP % "kick")
	assert_eq(registry.execute_chat(peer, "", &"gm"), CommandRegistry.TEXT_CHAT_HELP % "heal, kick",
			"/gm solo da la ayuda de su rol")
	assert_eq(registry.execute_chat(peer, "ayuda kick", &"gm"), "Uso: /gm kick <jugador> [motivo]")
	assert_eq(registry.execute_chat(peer, "kill", &"admin"), CommandRegistry.TEXT_UNKNOWN,
			"uno solo de red no está en el chat")
	assert_eq(entries, [[CommandRegistry.Origin.CHAT, 4, PackedStringArray(["Bea", "por", "spam"]), &"kick"]],
			"solo lo ejecutado va a la auditoría de la plataforma")
	assert_true(registry.audit[registry.audit.size() - 1].begins_with("[auditoría] /gm peer 4 (Ana): kill"))
	# La consola no mira el rol.
	assert_eq(registry.execute_console("heal Bea"), "hecho")
	assert_eq(entries.back(), [CommandRegistry.Origin.CONSOLE, 0, PackedStringArray(["Bea"]), &"heal"])
