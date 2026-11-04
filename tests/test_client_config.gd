extends TestCase
## Tests for [ClientConfig]: the user arguments of the networked client (docs/red.md, 1.2), and how
## [code]boot.gd[/code] lets them through without \"unknown argument\" warnings. Since phase 5, also the
## account modes and their priority, the TITLE mode and [code]--dtls-*[/code] (docs/plataforma.md §5.5, §13.3 and §15 P8).

const BootScript = preload("res://scripts/boot.gd")


func _parse(args: Array[String]) -> ClientConfig:
	return ClientConfig.from_args(PackedStringArray(args))


func test_defaults_without_arguments() -> void:
	var config: ClientConfig = _parse([])
	assert_eq(config.mode, ClientConfig.Mode.OFFLINE, "with no arguments it is the sandbox")
	assert_eq(config.address, "127.0.0.1")
	assert_eq(config.port, NetProtocol.DEFAULT_PORT)
	assert_eq(config.realm, NetProtocol.Realm.NONE)
	assert_eq(config.net_sim_spec, "")
	assert_eq(config.bot_seed, 1)
	assert_eq(config.bot_count, 0)
	assert_eq(config.bot_cheat, "")
	assert_eq(config.bot_brain, "", "with no brain chosen: the walking one")
	assert_eq(config.quit_after_ticks, 0)
	assert_eq(config.report_path, "")
	assert_eq(config.state_log_path, "")
	assert_true(config.warnings.is_empty())
	assert_false(config.is_online())


func test_sandbox_arguments_do_not_change_the_mode() -> void:
	var config: ClientConfig = _parse(["--demo", "--zone=test_world", "--realm=solmarch",
			"--shots=/tmp/capturas", "--quit-after-demo"])
	assert_eq(config.mode, ClientConfig.Mode.OFFLINE)
	assert_eq(config.realm, NetProtocol.Realm.SOLMARCH, "--realm is also read in the sandbox")
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
	assert_eq(bare.address, "::1", "an IPv6 without brackets is taken whole")
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
	assert_eq(empty.mode, ClientConfig.Mode.ONLINE, "the mode is decided by the presence of the option")
	assert_eq(empty.address, "127.0.0.1")
	assert_eq(empty.warnings.size(), 1)
	var unclosed: ClientConfig = _parse(["--connect=[::1"])
	assert_eq(unclosed.address, "127.0.0.1")
	assert_eq(unclosed.warnings.size(), 1)


func test_port_option_overrides_the_one_in_connect() -> void:
	var config: ClientConfig = _parse(["--connect=host:24700", "--port=24800"])
	assert_eq(config.port, 24800, "--port is more specific")
	var alone: ClientConfig = _parse(["--connect=host", "--port=24650"])
	assert_eq(alone.port, 24650)
	var invalid: ClientConfig = _parse(["--connect=host:24700", "--port=0"])
	assert_eq(invalid.port, 24700, "an invalid --port is ignored")
	assert_eq(invalid.warnings.size(), 1)


func test_bot_modes() -> void:
	var bot: ClientConfig = _parse(["--bot", "--connect=127.0.0.1", "--bot-seed=7"])
	assert_eq(bot.mode, ClientConfig.Mode.BOT, "--bot wins over --connect")
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
	assert_eq(zero.mode, ClientConfig.Mode.ONLINE, "--bots=0 is not a swarm")
	assert_eq(zero.warnings.size(), 1)


func test_realm_names() -> void:
	assert_eq(_parse(["--realm=vardheim"]).realm, NetProtocol.Realm.VARDHEIM)
	assert_eq(_parse(["--realm=Solmarch"]).realm, NetProtocol.Realm.SOLMARCH)
	assert_eq(_parse(["--realm=\"askarra\""]).realm, NetProtocol.Realm.ASKARRA)
	var unknown: ClientConfig = _parse(["--realm=eldrun"])
	assert_eq(unknown.realm, NetProtocol.Realm.NONE, "an unknown realm is \"none\"")
	assert_eq(unknown.warnings.size(), 1)


func test_name_default_and_explicit() -> void:
	var explicit: ClientConfig = _parse(["--connect=h", "--name=Bruno"])
	assert_eq(explicit.display_name, "Bruno")
	var quoted: ClientConfig = _parse(["--name=\"Ana Maria\""])
	assert_eq(quoted.display_name, "Ana Maria", "the quotes are removed")
	for _i: int in 20:
		var generated: String = _parse(["--connect=h"]).display_name
		var regex := RegEx.new()
		regex.compile("^Jugador[a-z]{4}$")
		assert_true(regex.search(generated) != null, "default name: %s" % generated)
	var blank: ClientConfig = _parse(["--name="])
	assert_true(blank.display_name.begins_with(ClientConfig.DEFAULT_NAME_PREFIX),
			"an empty --name uses the default name")


func test_common_options() -> void:
	var config: ClientConfig = _parse([
		"--connect=127.0.0.1:24610", "--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1",
		"--bot-cheat=Garbage", "--quit-after-ticks=1500", "--report=build\\bot_1.json",
		"--state-log=build/bot_1.csv",
	])
	assert_eq(config.net_sim_spec, "rtt=120,jitter=20,loss=5,dup=0,seed=1")
	assert_eq(config.bot_cheat, "garbage", "the cheater mode is stored in lowercase")
	assert_eq(config.quit_after_ticks, 1500)
	assert_eq(config.report_path, "build/bot_1.json", "backslashes are normalized")
	assert_eq(config.state_log_path, "build/bot_1.csv")
	assert_true(config.warnings.is_empty())


func test_dev_lock_path_option() -> void:
	assert_eq(_parse(["--local"]).dev_lock_path, "", "without the option, the lock goes in the usual place")
	var config: ClientConfig = _parse(["--local", "--dev-lock-path=build\\123\\lock.json"])
	assert_eq(config.dev_lock_path, "build/123/lock.json", "backslashes are normalized")
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
	assert_eq(options["warnings"], PackedStringArray(), "no network argument is unknown")
	assert_eq(options["realm"], &"solmarch", "--realm is still read as before")
	assert_eq(options["zone"], Zones.DEFAULT_ZONE)
	assert_false(options["demo"])


func test_bot_brain_option_accepts_the_known_brains_and_warns_about_the_others() -> void:
	var combat: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bot", "--bot-brain=Combat"]))
	assert_eq(combat.bot_brain, "combat", "in lowercase")
	assert_eq(combat.warnings.size(), 0)
	var wander: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bot", "--bot-brain=wander"]))
	assert_eq(wander.bot_brain, "wander")
	var unknown: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bot", "--bot-brain=volar"]))
	assert_eq(unknown.bot_brain, "", "an unknown one is ignored")
	if assert_eq(unknown.warnings.size(), 1, "with a warning in Spanish"):
		assert_true(unknown.warnings[0].contains("volar") and unknown.warnings[0].contains("combat"))


func test_bot_scenario_option_accepts_progress_and_warns_about_the_others() -> void:
	var progress: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bot", "--bot-scenario=Progress"]))
	assert_eq(progress.bot_scenario, ClientConfig.BOT_SCENARIO_PROGRESS, "in lowercase")
	assert_eq(progress.warnings.size(), 0)
	assert_eq(ClientConfig.from_args(PackedStringArray(["--bot"])).bot_scenario, "", "without the option, none")
	var unknown: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bot", "--bot-scenario=volar"]))
	assert_eq(unknown.bot_scenario, "", "an unknown one is ignored")
	if assert_eq(unknown.warnings.size(), 1, "with a warning in Spanish"):
		assert_true(unknown.warnings[0].contains("volar") and unknown.warnings[0].contains("progress"))
	var options: Dictionary = BootScript.parse_client_options(PackedStringArray(["--bot-scenario=progress"]))
	assert_eq(options["warnings"], PackedStringArray(), "the sandbox treats it as a network argument")


func test_loadout_option_takes_a_selectable_template_by_name() -> void:
	var config: ClientConfig = _parse(["--bot", "--loadout=Marksman"])
	assert_eq(config.loadout, "marksman", "in lowercase")
	assert_true(config.warnings.is_empty())
	assert_eq(config.get_loadout_template_id(), CombatCatalog.template_id(&"marksman"))
	var unknown: ClientConfig = _parse(["--bot", "--loadout=rompefilas"])
	assert_eq(unknown.loadout, "", "a template that does not exist is ignored")
	assert_eq(unknown.get_loadout_template_id(), 0)
	if assert_eq(unknown.warnings.size(), 1, "with a warning"):
		assert_true(unknown.warnings[0].contains("rompefilas"))
	assert_eq(_parse([]).get_loadout_template_id(), 0, "without --loadout, the default one (nothing is requested)")
	assert_true(ClientConfig.is_selectable_template("squire"))
	assert_false(ClientConfig.is_selectable_template(""))


# --- Phase 5: account and platform (docs/plataforma.md §13.3) ---------------------------------

func test_account_defaults_without_arguments() -> void:
	var config: ClientConfig = _parse([])
	assert_eq(config.platform_url, "", "without a platform")
	assert_eq(config.login, "")
	assert_eq(config.password_file, "")
	assert_eq(config.character_name, "")
	assert_eq(config.world_id, 1)
	assert_false(config.title)
	assert_eq(config.dtls_cert_path, "")
	assert_eq(config.dtls_name, "")
	assert_eq(config.character_id, 0)
	assert_false(config.has_ticket())
	assert_false(config.has_dtls())
	assert_false(config.from_front)


func test_without_arguments_the_editor_opens_the_sandbox_and_an_export_the_title() -> void:
	assert_eq(ClientConfig.from_args(PackedStringArray()).mode, ClientConfig.Mode.OFFLINE, "editor: the sandbox")
	var exported: ClientConfig = ClientConfig.from_args(PackedStringArray(), true)
	assert_eq(exported.mode, ClientConfig.Mode.TITLE, "export: the title screen")
	assert_eq(exported.platform_url, ClientConfig.default_platform_url(), "against the project setting")
	assert_eq(ClientConfig.default_platform_url(), "http://127.0.0.1:24680",
			"the project's eldmark/platform/url setting")
	var sandbox_args: ClientConfig = ClientConfig.from_args(PackedStringArray(["--zone=test_world"]), true)
	assert_eq(sandbox_args.mode, ClientConfig.Mode.TITLE, "the sandbox options do not change that")


func test_title_and_platform_open_the_title() -> void:
	var title: ClientConfig = _parse(["--title"])
	assert_eq(title.mode, ClientConfig.Mode.TITLE)
	assert_true(title.title)
	assert_eq(title.platform_url, ClientConfig.DEFAULT_PLATFORM_URL, "without --platform, the project's one")
	var platform: ClientConfig = _parse(["--platform=https://cuentas.eldmark.example"])
	assert_eq(platform.mode, ClientConfig.Mode.TITLE, "--platform alone is also the title screen")
	assert_eq(platform.platform_url, "https://cuentas.eldmark.example")
	assert_true(platform.warnings.is_empty())
	var both: ClientConfig = _parse(["--title", "--platform=http://127.0.0.1:9000"])
	assert_eq(both.mode, ClientConfig.Mode.TITLE)
	assert_eq(both.platform_url, "http://127.0.0.1:9000")


func test_mode_priority_with_the_account_options() -> void:
	var with_platform: Callable = func(extra: Array) -> ClientConfig:
		var args := PackedStringArray(["--platform=http://127.0.0.1:24680", "--title"])
		for arg: Variant in extra:
			args.append(str(arg))
		return ClientConfig.from_args(args)
	var swarm: ClientConfig = with_platform.call(["--bots=4", "--bot", "--connect=h", "--local"])
	assert_eq(swarm.mode, ClientConfig.Mode.SWARM, "--bots wins over everything")
	var bot: ClientConfig = with_platform.call(["--bot", "--connect=h", "--local"])
	assert_eq(bot.mode, ClientConfig.Mode.BOT, "--bot > --connect/--local > --title/--platform")
	assert_eq(bot.platform_url, "http://127.0.0.1:24680", "and the bot keeps the platform")
	var local: ClientConfig = with_platform.call(["--local", "--connect=h"])
	assert_eq(local.mode, ClientConfig.Mode.LOCAL)
	var online: ClientConfig = with_platform.call(["--connect=h"])
	assert_eq(online.mode, ClientConfig.Mode.ONLINE, "--connect > --title/--platform")
	var exported_bot: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bot"]), true)
	assert_eq(exported_bot.mode, ClientConfig.Mode.BOT, "an export with a mode does not open the title screen")


func test_bot_account_options() -> void:
	var config: ClientConfig = _parse(["--bot", "--platform=http://localhost:24680", "--login=Bot1@Eldmark.test",
			"--password-file=build\\secretos\\bot.txt", "--character=Aneira", "--world=3", "--realm=solmarch"])
	assert_eq(config.mode, ClientConfig.Mode.BOT)
	assert_eq(config.platform_url, "http://localhost:24680")
	assert_eq(config.login, "Bot1@Eldmark.test", "the email as is (AccountFlow normalizes it)")
	assert_eq(config.password_file, "build/secretos/bot.txt", "forward slashes")
	assert_eq(config.character_name, "Aneira")
	assert_eq(config.world_id, 3)
	assert_eq(config.realm, NetProtocol.Realm.SOLMARCH)
	assert_true(config.warnings.is_empty(), "%s" % [config.warnings])
	var bad_world: ClientConfig = _parse(["--bot", "--world=0"])
	assert_eq(bad_world.world_id, 1, "an out-of-range world is ignored")
	assert_eq(bad_world.warnings.size(), 1)
	var huge_world: ClientConfig = _parse(["--bot", "--world=70000"])
	assert_eq(huge_world.world_id, 1, "the world fits in a u16")


func test_dtls_options() -> void:
	var config: ClientConfig = _parse(["--bot", "--connect=127.0.0.1", "--dtls-cert=build\\zona.pem",
			"--dtls-name=vado-gris.eldmark"])
	assert_eq(config.dtls_cert_path, "build/zona.pem")
	assert_eq(config.dtls_name, "vado-gris.eldmark")
	assert_true(config.has_dtls())
	assert_true(config.warnings.is_empty())
	var without_name: ClientConfig = _parse(["--connect=127.0.0.1", "--dtls-cert=zona.pem"])
	assert_true(without_name.has_dtls())
	assert_eq(without_name.warnings.size(), 1, "--dtls-cert without --dtls-name warns")
	var pem_only := ClientConfig.new()
	pem_only.dtls_cert_pem = "-----BEGIN CERTIFICATE-----"
	assert_true(pem_only.has_dtls(), "the enter PEM is also DTLS")


func test_platform_url_rules() -> void:
	assert_eq(ClientConfig.platform_url_error("https://cuentas.eldmark.example"), "")
	assert_eq(ClientConfig.platform_url_error("https://cuentas.eldmark.example:8443/base"), "")
	assert_eq(ClientConfig.platform_url_error("http://127.0.0.1:24680"), "", "http:// to this machine is valid")
	assert_eq(ClientConfig.platform_url_error("http://localhost:24680"), "")
	assert_eq(ClientConfig.platform_url_error("http://[::1]:24680"), "")
	assert_eq(ClientConfig.platform_url_error("http://127.8.9.10"), "", "all of 127.0.0.0/8")
	assert_false(ClientConfig.platform_url_error("http://cuentas.eldmark.example").is_empty(),
			"http:// off this machine is not")
	assert_false(ClientConfig.platform_url_error("http://127.0.0.1.example.org").is_empty(),
			"a name that starts with 127. is not loopback")
	assert_false(ClientConfig.platform_url_error("ftp://cuentas.eldmark.example").is_empty())
	assert_false(ClientConfig.platform_url_error("cuentas.eldmark.example").is_empty())
	assert_false(ClientConfig.platform_url_error("https://").is_empty())
	assert_false(ClientConfig.platform_url_error("").is_empty())
	assert_eq(ClientConfig.url_host("https://usuario@cuentas.example:443/v1?x=1"), "cuentas.example")
	assert_eq(ClientConfig.url_host("http://[::1]:24680/"), "::1")
	var insecure: ClientConfig = _parse(["--platform=http://cuentas.eldmark.example"])
	assert_eq(insecure.platform_url, "http://cuentas.eldmark.example",
			"an invalid URL is kept: whoever uses it fails with its reason")
	assert_eq(insecure.warnings.size(), 1, "and a warning is issued")
	var empty: ClientConfig = _parse(["--platform="])
	assert_eq(empty.warnings.size(), 1, "an empty --platform warns")


func test_duplicate_config_copies_everything_independently() -> void:
	var config: ClientConfig = _parse(["--bot", "--platform=http://127.0.0.1:24680", "--login=a@b.c",
			"--report=build/r.json", "--bot-seed=5", "--world=2"])
	config.ticket = PackedByteArray([1, 2, 3])
	config.warnings.append("aviso")
	var copy: ClientConfig = config.duplicate_config()
	assert_eq(copy.mode, ClientConfig.Mode.BOT)
	assert_eq(copy.platform_url, config.platform_url)
	assert_eq(copy.login, "a@b.c")
	assert_eq(copy.report_path, "build/r.json")
	assert_eq(copy.bot_seed, 5)
	assert_eq(copy.world_id, 2)
	assert_eq(copy.ticket, PackedByteArray([1, 2, 3]))
	copy.ticket.append(4)
	copy.warnings.append("otro")
	assert_eq(config.ticket.size(), 3, "the copy's ticket is not the same")
	assert_eq(config.warnings.size(), 1, "nor the warnings")


func test_account_arguments_are_not_reported_as_unknown_by_boot() -> void:
	var options: Dictionary = BootScript.parse_client_options(PackedStringArray([
		"--title", "--platform=http://127.0.0.1:24680", "--login=a@b.c", "--password-file=p.txt",
		"--character=Aneira", "--world=1", "--dtls-cert=zona.pem", "--dtls-name=zona",
	]))
	assert_eq(options["warnings"], PackedStringArray(), "no account argument is unknown")
