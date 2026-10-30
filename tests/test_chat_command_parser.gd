extends TestCase
## Pruebas del analizador de la línea del chat ([ChatCommandParser], SOC-05, docs/social.md sección 4): qué
## es texto y qué es un comando, las dos formas de cada comando, que no importen las mayúsculas ni las
## tildes, los usos incorrectos y la ayuda. Es puro: solo texto.

const Kind = ChatCommandParser.Kind


func test_plain_text_and_empty_lines() -> void:
	var empty: ChatCommandParser.Command = ChatCommandParser.parse("")
	assert_eq(empty.kind, Kind.EMPTY, "vacío")
	assert_eq(ChatCommandParser.parse("   \t ").kind, Kind.EMPTY, "solo espacios")
	var text: ChatCommandParser.Command = ChatCommandParser.parse("  Hola a todos  ")
	assert_eq(text.kind, Kind.TEXT, "texto sin comando")
	assert_eq(text.text, "Hola a todos", "sin los espacios de los extremos")
	var slash_inside: ChatCommandParser.Command = ChatCommandParser.parse("hola /d mundo")
	assert_eq(slash_inside.kind, Kind.TEXT, "una barra que no abre la línea no es un comando")


func test_channel_commands_with_text_send_and_without_text_switch() -> void:
	var cases: Array[Array] = [
		["/d", ChatChannel.Id.SAY], ["/decir", ChatChannel.Id.SAY],
		["/z", ChatChannel.Id.ZONE], ["/zona", ChatChannel.Id.ZONE],
		["/g", ChatChannel.Id.PARTY], ["/grupo", ChatChannel.Id.PARTY],
	]
	for case: Array in cases:
		var sent: ChatCommandParser.Command = ChatCommandParser.parse("%s ¡Al fuerte!" % case[0])
		assert_eq(sent.kind, Kind.SEND, "%s con texto envía" % case[0])
		assert_eq(sent.channel, case[1], "%s: canal" % case[0])
		assert_eq(sent.text, "¡Al fuerte!", "%s: texto" % case[0])
		var switched: ChatCommandParser.Command = ChatCommandParser.parse(case[0])
		assert_eq(switched.kind, Kind.SET_CHANNEL, "%s sin texto cambia el canal activo" % case[0])
		assert_eq(switched.channel, case[1], "%s: canal activo" % case[0])
		assert_eq(ChatCommandParser.parse(case[0] + "   ").kind, Kind.SET_CHANNEL,
				"%s con solo espacios también" % case[0])


func test_commands_ignore_case_and_accents() -> void:
	for text: String in ["/D hola", "/DECIR hola", "/Decir hola", "/dECiR hola"]:
		var command: ChatCommandParser.Command = ChatCommandParser.parse(text)
		assert_eq(command.kind, Kind.SEND, text)
		assert_eq(command.channel, ChatChannel.Id.SAY, text)
	for text: String in ["/LIDER Ana", "/líder Ana", "/LÍDER Ana", "/Lider Ana"]:
		assert_eq(ChatCommandParser.parse(text).kind, Kind.LEADER, text)
	for text: String in ["/AYUDA", "/Ayuda", "/áyúdá"]:
		assert_eq(ChatCommandParser.parse(text).kind, Kind.HELP, text)
	assert_eq(ChatCommandParser.parse("/S Ana hola").kind, Kind.SEND, "/S")
	assert_eq(ChatCommandParser.parse("/SUSURRAR Ana hola").kind, Kind.SEND, "/SUSURRAR")


func test_whisper_forms() -> void:
	var sent: ChatCommandParser.Command = ChatCommandParser.parse("/s Álvaro  nos vemos en el fuerte")
	assert_eq(sent.kind, Kind.SEND, "con nombre y texto envía")
	assert_eq(sent.channel, ChatChannel.Id.WHISPER, "canal de susurro")
	assert_eq(sent.target, "Álvaro", "el nombre tal como se escribió")
	assert_eq(sent.text, "nos vemos en el fuerte", "el resto es el texto")
	var switched: ChatCommandParser.Command = ChatCommandParser.parse("/susurrar Bruno")
	assert_eq(switched.kind, Kind.SET_CHANNEL, "solo el nombre cambia el canal")
	assert_eq(switched.channel, ChatChannel.Id.WHISPER, "canal de susurro")
	assert_eq(switched.target, "Bruno", "con su destinatario")
	assert_eq(switched.text, "", "sin texto")
	var usage: ChatCommandParser.Command = ChatCommandParser.parse("/s")
	assert_eq(usage.kind, Kind.INVALID, "sin nombre")
	assert_eq(usage.error, "Uso: /s nombre [texto]", "con cómo se usa")
	var long_name: ChatCommandParser.Command = ChatCommandParser.parse("/s " + "a".repeat(17) + " hola")
	assert_eq(long_name.kind, Kind.INVALID, "un nombre de 17 letras no puede existir")
	assert_eq(long_name.error, ChatCommandParser.TEXT_NAME_TOO_LONG, "con su motivo")
	assert_eq(ChatCommandParser.parse("/s " + "a".repeat(16) + " hola").kind, Kind.SEND, "16 sí")


func test_reply_has_optional_text() -> void:
	var with_text: ChatCommandParser.Command = ChatCommandParser.parse("/r de acuerdo")
	assert_eq(with_text.kind, Kind.REPLY, "/r con texto")
	assert_eq(with_text.text, "de acuerdo", "texto")
	assert_eq(with_text.channel, ChatChannel.Id.WHISPER, "es un susurro")
	var without: ChatCommandParser.Command = ChatCommandParser.parse("/responder")
	assert_eq(without.kind, Kind.REPLY, "/responder sin texto")
	assert_eq(without.text, "", "sin texto")


func test_party_commands() -> void:
	var invite: ChatCommandParser.Command = ChatCommandParser.parse("/invitar Ana")
	assert_eq(invite.kind, Kind.INVITE, "invitar")
	assert_eq(invite.target, "Ana", "a quién")
	var kick: ChatCommandParser.Command = ChatCommandParser.parse("/expulsar Bruno sobrante")
	assert_eq(kick.kind, Kind.KICK, "expulsar")
	assert_eq(kick.target, "Bruno", "solo el primer nombre")
	var leader: ChatCommandParser.Command = ChatCommandParser.parse("/lider Cora")
	assert_eq(leader.kind, Kind.LEADER, "líder")
	assert_eq(leader.target, "Cora", "a quién")
	assert_eq(ChatCommandParser.parse("/salir").kind, Kind.LEAVE, "salir")
	for text: String in ["/invitar", "/expulsar", "/lider"]:
		var missing: ChatCommandParser.Command = ChatCommandParser.parse(text)
		assert_eq(missing.kind, Kind.INVALID, "%s sin nombre" % text)
		assert_true(missing.error.begins_with("Uso: "), "%s explica el uso" % text)
	assert_eq(ChatCommandParser.parse("/invitar " + "x".repeat(20)).kind, Kind.INVALID, "nombre largo")


func test_unknown_commands() -> void:
	for text: String in ["/xyz", "/", "/ hola", "/banda hola", "/b hola", "/gremio x",
			"/reino x", "/comercio x", "/amigo Ana", "//d hola", "/d2 hola", "//gm hola", "/gmx hola"]:
		var command: ChatCommandParser.Command = ChatCommandParser.parse(text)
		assert_eq(command.kind, Kind.UNKNOWN, "«%s» es desconocido" % text)
	assert_eq(ChatCommandParser.TEXT_UNKNOWN, "Comando desconocido. Escribe /ayuda.", "el texto del backlog")


func test_server_commands_go_as_typed_and_gm_is_not_listed() -> void:
	# docs/plataforma.md §9 (P7b): los atiende el servidor; /gm sin rol contesta «Comando desconocido» desde allí.
	var gm: ChatCommandParser.Command = ChatCommandParser.parse("/GM silenciar Ana 30 insultos")
	assert_eq(gm.kind, Kind.SERVER, "/gm va al servidor")
	assert_eq(gm.text, "gm silenciar Ana 30 insultos", "la línea sin la barra, con el nombre en minúsculas")
	assert_eq(ChatCommandParser.parse("/gm").text, "gm", "/gm solo (la ayuda la da el servidor)")
	var ignore: ChatCommandParser.Command = ChatCommandParser.parse("/Ignorar  Bruno ")
	assert_eq([ignore.kind, ignore.target, ignore.text], [Kind.SERVER, "Bruno", "ignorar Bruno"], "ignorar")
	assert_eq(ChatCommandParser.parse("/designorar Bruno").text, "designorar Bruno", "designorar")
	var report: ChatCommandParser.Command = ChatCommandParser.parse("/reportar Bruno acoso me insulta")
	assert_eq([report.kind, report.text], [Kind.SERVER, "reportar Bruno acoso me insulta"], "reportar")
	for text: String in ["/ignorar", "/designorar", "/reportar"]:
		var missing: ChatCommandParser.Command = ChatCommandParser.parse(text)
		assert_eq(missing.kind, Kind.INVALID, "%s sin nombre" % text)
		assert_true(missing.error.begins_with("Uso: "), "%s explica el uso" % text)
	assert_eq(ChatCommandParser.parse("/ignorar " + "x".repeat(20)).kind, Kind.INVALID, "nombre largo")
	assert_true(ChatCommandParser.find_command("gm").is_empty(), "/gm no está en la tabla (ni en la ayuda)")
	for line: String in ChatCommandParser.help_lines(""):
		assert_false(line.contains("/gm"), "la ayuda no nombra /gm")


func test_help() -> void:
	var list: ChatCommandParser.Command = ChatCommandParser.parse("/ayuda")
	assert_eq(list.kind, Kind.HELP, "ayuda")
	assert_eq(list.topic, "", "sin comando: la lista")
	var detail: ChatCommandParser.Command = ChatCommandParser.parse("/ayuda /Susurrar")
	assert_eq(detail.topic, "susurrar", "el comando de la ayuda, sin barra ni mayúsculas")
	var lines: PackedStringArray = ChatCommandParser.help_lines("")
	assert_eq(lines.size(), ChatCommandParser.COMMANDS.size() + 1, "una línea por comando más el título")
	assert_eq(lines[0], ChatCommandParser.TEXT_HELP_TITLE, "título")
	for spec: Dictionary in ChatCommandParser.COMMANDS:
		var found: bool = false
		for line: String in lines:
			if line.contains(spec["usage"]):
				found = true
		assert_true(found, "la lista incluye %s" % spec["usage"])
	var whisper_help: PackedStringArray = ChatCommandParser.help_lines("s")
	assert_true(whisper_help[0].begins_with("/s nombre [texto]"), "el detalle empieza por el uso")
	assert_eq(whisper_help.size(), 2, "y dice los otros nombres")
	assert_true(whisper_help[1].contains("/susurrar"), "como /susurrar")
	assert_eq(ChatCommandParser.help_lines("/LÍDER")[0].begins_with("/lider nombre"), true,
			"también sin tildes ni mayúsculas")
	var none: PackedStringArray = ChatCommandParser.help_lines("nada")
	assert_eq(none, PackedStringArray([ChatCommandParser.TEXT_NO_HELP % "nada"]), "un comando que no existe")


func test_command_table_is_consistent() -> void:
	var seen: Dictionary = {}
	for spec: Dictionary in ChatCommandParser.COMMANDS:
		for command_name: String in spec["names"]:
			assert_false(seen.has(command_name), "el nombre «%s» no se repite" % command_name)
			seen[command_name] = true
			assert_eq(NameRules.normalize_key(command_name), command_name,
					"«%s» ya está sin mayúsculas ni tildes" % command_name)
			assert_false(ChatCommandParser.find_command(command_name).is_empty(), "«%s» se encuentra" % command_name)
			assert_false(ChatCommandParser.find_command("/" + command_name.to_upper()).is_empty(),
					"«/%s» en mayúsculas también" % command_name)
			var parsed: ChatCommandParser.Command = ChatCommandParser.parse("/%s Ana" % command_name)
			assert_true(parsed.kind != Kind.UNKNOWN, "«/%s» se reconoce" % command_name)
		assert_false(String(spec["help"]).is_empty(), "%s tiene ayuda" % spec["id"])
		assert_true(String(spec["usage"]).begins_with("/"), "%s tiene uso" % spec["id"])
