extends TestCase
## Tests of the chat line parser ([ChatCommandParser], SOC-05, docs/social.md section 4): what
## is text and what is a command, the two forms of each command, that case and accents do not
## matter, incorrect usage and help. It is pure: text only.

const Kind = ChatCommandParser.Kind


func test_plain_text_and_empty_lines() -> void:
	var empty: ChatCommandParser.Command = ChatCommandParser.parse("")
	assert_eq(empty.kind, Kind.EMPTY, "empty")
	assert_eq(ChatCommandParser.parse("   \t ").kind, Kind.EMPTY, "only spaces")
	var text: ChatCommandParser.Command = ChatCommandParser.parse("  Hola a todos  ")
	assert_eq(text.kind, Kind.TEXT, "text without a command")
	assert_eq(text.text, "Hola a todos", "without the spaces at the ends")
	var slash_inside: ChatCommandParser.Command = ChatCommandParser.parse("hola /d mundo")
	assert_eq(slash_inside.kind, Kind.TEXT, "a slash that does not open the line is not a command")


func test_channel_commands_with_text_send_and_without_text_switch() -> void:
	var cases: Array[Array] = [
		["/d", ChatChannel.Id.SAY], ["/decir", ChatChannel.Id.SAY],
		["/z", ChatChannel.Id.ZONE], ["/zona", ChatChannel.Id.ZONE],
		["/g", ChatChannel.Id.PARTY], ["/grupo", ChatChannel.Id.PARTY],
	]
	for case: Array in cases:
		var sent: ChatCommandParser.Command = ChatCommandParser.parse("%s ¡Al fuerte!" % case[0])
		assert_eq(sent.kind, Kind.SEND, "%s with text sends" % case[0])
		assert_eq(sent.channel, case[1], "%s: channel" % case[0])
		assert_eq(sent.text, "¡Al fuerte!", "%s: text" % case[0])
		var switched: ChatCommandParser.Command = ChatCommandParser.parse(case[0])
		assert_eq(switched.kind, Kind.SET_CHANNEL, "%s without text changes the active channel" % case[0])
		assert_eq(switched.channel, case[1], "%s: active channel" % case[0])
		assert_eq(ChatCommandParser.parse(case[0] + "   ").kind, Kind.SET_CHANNEL,
				"%s with only spaces too" % case[0])


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
	assert_eq(sent.kind, Kind.SEND, "with name and text sends")
	assert_eq(sent.channel, ChatChannel.Id.WHISPER, "whisper channel")
	assert_eq(sent.target, "Álvaro", "the name as typed")
	assert_eq(sent.text, "nos vemos en el fuerte", "the rest is the text")
	var switched: ChatCommandParser.Command = ChatCommandParser.parse("/susurrar Bruno")
	assert_eq(switched.kind, Kind.SET_CHANNEL, "only the name changes the channel")
	assert_eq(switched.channel, ChatChannel.Id.WHISPER, "whisper channel")
	assert_eq(switched.target, "Bruno", "with its recipient")
	assert_eq(switched.text, "", "without text")
	var usage: ChatCommandParser.Command = ChatCommandParser.parse("/s")
	assert_eq(usage.kind, Kind.INVALID, "without a name")
	assert_eq(usage.error, "Uso: /s nombre [texto]", "with how to use it")
	var long_name: ChatCommandParser.Command = ChatCommandParser.parse("/s " + "a".repeat(17) + " hola")
	assert_eq(long_name.kind, Kind.INVALID, "a 17-letter name cannot exist")
	assert_eq(long_name.error, ChatCommandParser.TEXT_NAME_TOO_LONG, "with its reason")
	assert_eq(ChatCommandParser.parse("/s " + "a".repeat(16) + " hola").kind, Kind.SEND, "16 can")


func test_reply_has_optional_text() -> void:
	var with_text: ChatCommandParser.Command = ChatCommandParser.parse("/r de acuerdo")
	assert_eq(with_text.kind, Kind.REPLY, "/r with text")
	assert_eq(with_text.text, "de acuerdo", "text")
	assert_eq(with_text.channel, ChatChannel.Id.WHISPER, "is a whisper")
	var without: ChatCommandParser.Command = ChatCommandParser.parse("/responder")
	assert_eq(without.kind, Kind.REPLY, "/responder without text")
	assert_eq(without.text, "", "without text")


func test_party_commands() -> void:
	var invite: ChatCommandParser.Command = ChatCommandParser.parse("/invitar Ana")
	assert_eq(invite.kind, Kind.INVITE, "invite")
	assert_eq(invite.target, "Ana", "whom")
	var kick: ChatCommandParser.Command = ChatCommandParser.parse("/expulsar Bruno sobrante")
	assert_eq(kick.kind, Kind.KICK, "kick")
	assert_eq(kick.target, "Bruno", "only the first name")
	var leader: ChatCommandParser.Command = ChatCommandParser.parse("/lider Cora")
	assert_eq(leader.kind, Kind.LEADER, "leader")
	assert_eq(leader.target, "Cora", "whom")
	assert_eq(ChatCommandParser.parse("/salir").kind, Kind.LEAVE, "leave")
	for text: String in ["/invitar", "/expulsar", "/lider"]:
		var missing: ChatCommandParser.Command = ChatCommandParser.parse(text)
		assert_eq(missing.kind, Kind.INVALID, "%s without a name" % text)
		assert_true(missing.error.begins_with("Uso: "), "%s explains the usage" % text)
	assert_eq(ChatCommandParser.parse("/invitar " + "x".repeat(20)).kind, Kind.INVALID, "long name")


func test_unknown_commands() -> void:
	for text: String in ["/xyz", "/", "/ hola", "/banda hola", "/b hola", "/gremio x",
			"/reino x", "/comercio x", "/amigo Ana", "//d hola", "/d2 hola", "//gm hola", "/gmx hola"]:
		var command: ChatCommandParser.Command = ChatCommandParser.parse(text)
		assert_eq(command.kind, Kind.UNKNOWN, "\"%s\" is unknown" % text)
	assert_eq(ChatCommandParser.TEXT_UNKNOWN, "Comando desconocido. Escribe /ayuda.", "the backlog text")


func test_server_commands_go_as_typed_and_gm_is_not_listed() -> void:
	# docs/plataforma.md §9 (P7b): the server handles them; /gm without the role answers "Comando desconocido" (unknown command) from there.
	var gm: ChatCommandParser.Command = ChatCommandParser.parse("/GM silenciar Ana 30 insultos")
	assert_eq(gm.kind, Kind.SERVER, "/gm goes to the server")
	assert_eq(gm.text, "gm silenciar Ana 30 insultos", "the line without the slash, with the name in lowercase")
	assert_eq(ChatCommandParser.parse("/gm").text, "gm", "/gm alone (the help is given by the server)")
	var ignore: ChatCommandParser.Command = ChatCommandParser.parse("/Ignorar  Bruno ")
	assert_eq([ignore.kind, ignore.target, ignore.text], [Kind.SERVER, "Bruno", "ignorar Bruno"], "ignore")
	assert_eq(ChatCommandParser.parse("/designorar Bruno").text, "designorar Bruno", "unignore")
	var report: ChatCommandParser.Command = ChatCommandParser.parse("/reportar Bruno acoso me insulta")
	assert_eq([report.kind, report.text], [Kind.SERVER, "reportar Bruno acoso me insulta"], "report")
	for text: String in ["/ignorar", "/designorar", "/reportar"]:
		var missing: ChatCommandParser.Command = ChatCommandParser.parse(text)
		assert_eq(missing.kind, Kind.INVALID, "%s without a name" % text)
		assert_true(missing.error.begins_with("Uso: "), "%s explains the usage" % text)
	assert_eq(ChatCommandParser.parse("/ignorar " + "x".repeat(20)).kind, Kind.INVALID, "long name")
	assert_true(ChatCommandParser.find_command("gm").is_empty(), "/gm is not in the table (nor in the help)")
	for line: String in ChatCommandParser.help_lines(""):
		assert_false(line.contains("/gm"), "the help does not name /gm")


func test_help() -> void:
	var list: ChatCommandParser.Command = ChatCommandParser.parse("/ayuda")
	assert_eq(list.kind, Kind.HELP, "help")
	assert_eq(list.topic, "", "no command: the list")
	var detail: ChatCommandParser.Command = ChatCommandParser.parse("/ayuda /Susurrar")
	assert_eq(detail.topic, "susurrar", "the command from the help, without slash or capitals")
	var lines: PackedStringArray = ChatCommandParser.help_lines("")
	assert_eq(lines.size(), ChatCommandParser.COMMANDS.size() + 1, "one line per command plus the title")
	assert_eq(lines[0], ChatCommandParser.TEXT_HELP_TITLE, "title")
	for spec: Dictionary in ChatCommandParser.COMMANDS:
		var found: bool = false
		for line: String in lines:
			if line.contains(spec["usage"]):
				found = true
		assert_true(found, "the list includes %s" % spec["usage"])
	var whisper_help: PackedStringArray = ChatCommandParser.help_lines("s")
	assert_true(whisper_help[0].begins_with("/s nombre [texto]"), "the detail starts with the usage")
	assert_eq(whisper_help.size(), 2, "and gives the other names")
	assert_true(whisper_help[1].contains("/susurrar"), "like /susurrar")
	assert_eq(ChatCommandParser.help_lines("/LÍDER")[0].begins_with("/lider nombre"), true,
			"also without accents or capitals")
	var none: PackedStringArray = ChatCommandParser.help_lines("nada")
	assert_eq(none, PackedStringArray([ChatCommandParser.TEXT_NO_HELP % "nada"]), "a command that does not exist")


func test_command_table_is_consistent() -> void:
	var seen: Dictionary = {}
	for spec: Dictionary in ChatCommandParser.COMMANDS:
		for command_name: String in spec["names"]:
			assert_false(seen.has(command_name), "the name \"%s\" is not repeated" % command_name)
			seen[command_name] = true
			assert_eq(NameRules.normalize_key(command_name), command_name,
					"\"%s\" is already without capitals or accents" % command_name)
			assert_false(ChatCommandParser.find_command(command_name).is_empty(), "\"%s\" is found" % command_name)
			assert_false(ChatCommandParser.find_command("/" + command_name.to_upper()).is_empty(),
					"\"/%s\" in capitals too" % command_name)
			var parsed: ChatCommandParser.Command = ChatCommandParser.parse("/%s Ana" % command_name)
			assert_true(parsed.kind != Kind.UNKNOWN, "\"/%s\" is recognized" % command_name)
		assert_false(String(spec["help"]).is_empty(), "%s has help" % spec["id"])
		assert_true(String(spec["usage"]).begins_with("/"), "%s has usage" % spec["id"])
