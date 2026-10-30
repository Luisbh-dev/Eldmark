extends TestCase
## Pruebas de [ClientConfig]: los argumentos de usuario del cliente en red (docs/red.md, 1.2), y de
## cómo [code]boot.gd[/code] los deja pasar sin avisos de «argumento desconocido».

const BootScript = preload("res://scripts/boot.gd")


func _parse(args: Array[String]) -> ClientConfig:
	return ClientConfig.from_args(PackedStringArray(args))


func test_defaults_without_arguments() -> void:
	var config: ClientConfig = _parse([])
	assert_eq(config.mode, ClientConfig.Mode.OFFLINE, "sin argumentos es el sandbox")
	assert_eq(config.address, "127.0.0.1")
	assert_eq(config.port, NetProtocol.DEFAULT_PORT)
	assert_eq(config.realm, NetProtocol.Realm.NONE)
	assert_eq(config.net_sim_spec, "")
	assert_eq(config.bot_seed, 1)
	assert_eq(config.bot_count, 0)
	assert_eq(config.bot_cheat, "")
	assert_eq(config.bot_brain, "", "sin cerebro elegido: el de paseo")
	assert_eq(config.quit_after_ticks, 0)
	assert_eq(config.report_path, "")
	assert_eq(config.state_log_path, "")
	assert_true(config.warnings.is_empty())
	assert_false(config.is_online())


func test_sandbox_arguments_do_not_change_the_mode() -> void:
	var config: ClientConfig = _parse(["--demo", "--zone=test_world", "--realm=solmarch",
			"--shots=/tmp/capturas", "--quit-after-demo"])
	assert_eq(config.mode, ClientConfig.Mode.OFFLINE)
	assert_eq(config.realm, NetProtocol.Realm.SOLMARCH, "--realm se lee también en el sandbox")
	assert_true(config.warnings.is_empty())


func test_connect_host_only() -> void:
	var config: ClientConfig = _parse(["--connect=example.org"])
	assert_eq(config.mode, ClientConfig.Mode.ONLINE)
	assert_eq(config.address, "example.org")
	assert_eq(config.port, NetProtocol.DEFAULT_PORT)
	assert_true(config.is_online())


func test_connect_host_and_port() -> void:
	var config: ClientConfig = _parse(["--connect=192.168.1.20:24700"])
	assert_eq(config.address, "192.168.1.20")
	assert_eq(config.port, 24700)
	assert_true(config.warnings.is_empty())


func test_connect_ipv6_forms() -> void:
	var bare: ClientConfig = _parse(["--connect=::1"])
	assert_eq(bare.address, "::1", "un IPv6 sin corchetes se toma entero")
	assert_eq(bare.port, NetProtocol.DEFAULT_PORT)
	var bracket: ClientConfig = _parse(["--connect=[::1]:24800"])
	assert_eq(bracket.address, "::1")
	assert_eq(bracket.port, 24800)
	var bracket_only: ClientConfig = _parse(["--connect=[fe80::1]"])
	assert_eq(bracket_only.address, "fe80::1")
	assert_eq(bracket_only.port, NetProtocol.DEFAULT_PORT)


func test_connect_with_bad_values_keeps_defaults_and_warns() -> void:
	var bad_port: ClientConfig = _parse(["--connect=host:99999"])
	assert_eq(bad_port.address, "host")
	assert_eq(bad_port.port, NetProtocol.DEFAULT_PORT)
	assert_eq(bad_port.warnings.size(), 1)
	var text_port: ClientConfig = _parse(["--connect=host:abc"])
	assert_eq(text_port.port, NetProtocol.DEFAULT_PORT)
	assert_eq(text_port.warnings.size(), 1)
	var empty: ClientConfig = _parse(["--connect="])
	assert_eq(empty.mode, ClientConfig.Mode.ONLINE, "el modo lo decide la presencia de la opción")
	assert_eq(empty.address, "127.0.0.1")
	assert_eq(empty.warnings.size(), 1)
	var unclosed: ClientConfig = _parse(["--connect=[::1"])
	assert_eq(unclosed.address, "127.0.0.1")
	assert_eq(unclosed.warnings.size(), 1)


func test_port_option_overrides_the_one_in_connect() -> void:
	var config: ClientConfig = _parse(["--connect=host:24700", "--port=24800"])
	assert_eq(config.port, 24800, "--port es más específico")
	var alone: ClientConfig = _parse(["--connect=host", "--port=24650"])
	assert_eq(alone.port, 24650)
	var invalid: ClientConfig = _parse(["--connect=host:24700", "--port=0"])
	assert_eq(invalid.port, 24700, "un --port no válido se ignora")
	assert_eq(invalid.warnings.size(), 1)


func test_bot_modes() -> void:
	var bot: ClientConfig = _parse(["--bot", "--connect=127.0.0.1", "--bot-seed=7"])
	assert_eq(bot.mode, ClientConfig.Mode.BOT, "--bot gana a --connect")
	assert_eq(bot.bot_seed, 7)
	assert_eq(bot.address, "127.0.0.1")
	var bare_bot: ClientConfig = _parse(["--bot"])
	assert_eq(bare_bot.mode, ClientConfig.Mode.BOT)
	var negative: ClientConfig = _parse(["--bot", "--bot-seed=-3"])
	assert_eq(negative.bot_seed, -3)
	var bad_seed: ClientConfig = _parse(["--bot", "--bot-seed=xyz"])
	assert_eq(bad_seed.bot_seed, 1)
	assert_eq(bad_seed.warnings.size(), 1)


func test_swarm_and_local_modes_and_priority() -> void:
	var swarm: ClientConfig = _parse(["--bots=32", "--connect=127.0.0.1"])
	assert_eq(swarm.mode, ClientConfig.Mode.SWARM)
	assert_eq(swarm.bot_count, 32)
	var swarm_over_bot: ClientConfig = _parse(["--bot", "--bots=4", "--connect=127.0.0.1"])
	assert_eq(swarm_over_bot.mode, ClientConfig.Mode.SWARM, "--bots > --bot")
	var local: ClientConfig = _parse(["--local", "--realm=askarra", "--name=Ana"])
	assert_eq(local.mode, ClientConfig.Mode.LOCAL)
	assert_eq(local.realm, NetProtocol.Realm.ASKARRA)
	assert_eq(local.display_name, "Ana")
	var local_over_connect: ClientConfig = _parse(["--connect=host", "--local"])
	assert_eq(local_over_connect.mode, ClientConfig.Mode.LOCAL, "--local > --connect")
	var bot_over_local: ClientConfig = _parse(["--local", "--bot"])
	assert_eq(bot_over_local.mode, ClientConfig.Mode.BOT, "--bot > --local")
	var zero: ClientConfig = _parse(["--bots=0", "--connect=host"])
	assert_eq(zero.mode, ClientConfig.Mode.ONLINE, "--bots=0 no es un enjambre")
	assert_eq(zero.warnings.size(), 1)


func test_realm_names() -> void:
	assert_eq(_parse(["--realm=vardheim"]).realm, NetProtocol.Realm.VARDHEIM)
	assert_eq(_parse(["--realm=Solmarch"]).realm, NetProtocol.Realm.SOLMARCH)
	assert_eq(_parse(["--realm=\"askarra\""]).realm, NetProtocol.Realm.ASKARRA)
	var unknown: ClientConfig = _parse(["--realm=eldrun"])
	assert_eq(unknown.realm, NetProtocol.Realm.NONE, "un reino desconocido es «ninguno»")
	assert_eq(unknown.warnings.size(), 1)


func test_name_default_and_explicit() -> void:
	var explicit: ClientConfig = _parse(["--connect=h", "--name=Bruno"])
	assert_eq(explicit.display_name, "Bruno")
	var quoted: ClientConfig = _parse(["--name=\"Ana Maria\""])
	assert_eq(quoted.display_name, "Ana Maria", "las comillas se quitan")
	for _i: int in 20:
		var generated: String = _parse(["--connect=h"]).display_name
		var regex := RegEx.new()
		regex.compile("^Jugador[a-z]{4}$")
		assert_true(regex.search(generated) != null, "nombre por defecto: %s" % generated)
	var blank: ClientConfig = _parse(["--name="])
	assert_true(blank.display_name.begins_with(ClientConfig.DEFAULT_NAME_PREFIX),
			"un --name vacío usa el nombre por defecto")


func test_common_options() -> void:
	var config: ClientConfig = _parse([
		"--connect=127.0.0.1:24610", "--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1",
		"--bot-cheat=Garbage", "--quit-after-ticks=1500", "--report=build\\bot_1.json",
		"--state-log=build/bot_1.csv",
	])
	assert_eq(config.net_sim_spec, "rtt=120,jitter=20,loss=5,dup=0,seed=1")
	assert_eq(config.bot_cheat, "garbage", "el modo del tramposo se guarda en minúsculas")
	assert_eq(config.quit_after_ticks, 1500)
	assert_eq(config.report_path, "build/bot_1.json", "las barras invertidas se normalizan")
	assert_eq(config.state_log_path, "build/bot_1.csv")
	assert_true(config.warnings.is_empty())


func test_dev_lock_path_option() -> void:
	assert_eq(_parse(["--local"]).dev_lock_path, "", "sin la opción, el bloqueo va en el sitio de siempre")
	var config: ClientConfig = _parse(["--local", "--dev-lock-path=build\\123\\lock.json"])
	assert_eq(config.dev_lock_path, "build/123/lock.json", "las barras invertidas se normalizan")
	assert_true(config.warnings.is_empty())


func test_invalid_numbers_are_ignored_with_a_warning() -> void:
	var config: ClientConfig = _parse(["--quit-after-ticks=-5", "--bots=abc", "--port=70000"])
	assert_eq(config.quit_after_ticks, 0)
	assert_eq(config.bot_count, 0)
	assert_eq(config.port, NetProtocol.DEFAULT_PORT)
	assert_eq(config.warnings.size(), 3)


func test_network_arguments_are_not_reported_as_unknown_by_boot() -> void:
	var options: Dictionary = BootScript.parse_client_options(PackedStringArray([
		"--connect=127.0.0.1:24600", "--bot", "--bots=3", "--local", "--realm=solmarch",
		"--name=Ana", "--port=24600", "--net-sim=rtt=100", "--bot-seed=2", "--bot-cheat=flood",
		"--quit-after-ticks=100", "--report=x.json", "--state-log=x.csv", "--loadout=marksman",
	]))
	assert_eq(options["warnings"], PackedStringArray(), "ningún argumento de red es desconocido")
	assert_eq(options["realm"], &"solmarch", "--realm se sigue leyendo como antes")
	assert_eq(options["zone"], Zones.DEFAULT_ZONE)
	assert_false(options["demo"])


func test_bot_brain_option_accepts_the_known_brains_and_warns_about_the_others() -> void:
	var combat: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bot", "--bot-brain=Combat"]))
	assert_eq(combat.bot_brain, "combat", "en minúsculas")
	assert_eq(combat.warnings.size(), 0)
	var wander: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bot", "--bot-brain=wander"]))
	assert_eq(wander.bot_brain, "wander")
	var unknown: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bot", "--bot-brain=volar"]))
	assert_eq(unknown.bot_brain, "", "uno desconocido se ignora")
	if assert_eq(unknown.warnings.size(), 1, "con un aviso en español"):
		assert_true(unknown.warnings[0].contains("volar") and unknown.warnings[0].contains("combat"))


func test_loadout_option_takes_a_selectable_template_by_name() -> void:
	var config: ClientConfig = _parse(["--bot", "--loadout=Marksman"])
	assert_eq(config.loadout, "marksman", "en minúsculas")
	assert_true(config.warnings.is_empty())
	assert_eq(config.get_loadout_template_id(), CombatCatalog.template_id(&"marksman"))
	var unknown: ClientConfig = _parse(["--bot", "--loadout=rompefilas"])
	assert_eq(unknown.loadout, "", "una plantilla que no existe se ignora")
	assert_eq(unknown.get_loadout_template_id(), 0)
	if assert_eq(unknown.warnings.size(), 1, "con un aviso"):
		assert_true(unknown.warnings[0].contains("rompefilas"))
	assert_eq(_parse([]).get_loadout_template_id(), 0, "sin --loadout, la de por defecto (no se pide nada)")
	assert_true(ClientConfig.is_selectable_template("squire"))
	assert_false(ClientConfig.is_selectable_template(""))
