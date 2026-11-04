extends TestCase
## Tests for the reading of the server's arguments ([ServerConfig.from_args], docs/red.md
## section 1.2).


func test_defaults_without_arguments() -> void:
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_eq(config.port, NetProtocol.DEFAULT_PORT, "default port")
	assert_eq(config.port, 24600, "24600")
	assert_eq(config.zone_id, NetZones.default_zone_id(), "default zone")
	assert_eq(config.max_players, 40, "players: Vado Gris's capacity (the measured per-battle limit)")
	assert_eq(config.max_connections_per_ip, 4, "connections per IP")
	assert_eq(config.idle_quit_seconds, 0, "no idle shutdown")
	assert_eq(config.quit_after_ticks, 0, "no shutdown by ticks")
	assert_eq(config.report_path, "", "no report")
	assert_eq(config.state_log_path, "", "no state log")
	assert_eq(config.net_sim_spec, "", "no network simulator")
	assert_eq(config.fake_players, 0, "no fake players")
	assert_false(config.debug_commands, "no debug commands")
	assert_false(config.dev_lock, "no lock file")


func test_server_flag_alone_keeps_defaults() -> void:
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray(["--server"]))
	assert_eq(config.port, 24600, "port")
	assert_eq(config.zone_id, NetZones.default_zone_id(), "zone")
	assert_false(config.debug_commands, "debug")


func test_all_options() -> void:
	var args := PackedStringArray([
		"--server", "--port=24700", "--zone=test_world", "--max-players=32", "--max-per-ip=2",
		"--idle-quit=30", "--fake-players=10", "--debug-commands", "--dev-lock",
		"--quit-after-ticks=900", "--report=build/report.json", "--state-log=build/state.csv",
		"--stop-file=build/parar.txt", "--net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1",
	])
	var config: ServerConfig = ServerConfig.from_args(args)
	assert_eq(config.port, 24700, "port")
	assert_eq(config.zone_id, "test_world", "zone_id")
	assert_eq(config.max_players, 32, "max_players")
	assert_eq(config.max_connections_per_ip, 2, "max_connections_per_ip")
	assert_eq(config.idle_quit_seconds, 30, "idle_quit_seconds")
	assert_eq(config.fake_players, 10, "fake_players")
	assert_true(config.debug_commands, "debug_commands")
	assert_true(config.dev_lock, "dev_lock")
	assert_eq(config.quit_after_ticks, 900, "quit_after_ticks")
	assert_eq(config.report_path, "build/report.json", "report_path")
	assert_eq(config.state_log_path, "build/state.csv", "state_log_path")
	assert_eq(config.stop_file_path, "build/parar.txt", "stop_file_path")
	assert_eq(config.net_sim_spec, "rtt=120,jitter=20,loss=5,dup=0,seed=1",
			"the simulator keeps the = signs of its specification")


func test_invalid_numbers_keep_the_default() -> void:
	var args := PackedStringArray([
		"--port=abc", "--max-players=0", "--max-per-ip=-1", "--idle-quit=x", "--fake-players=",
		"--quit-after-ticks=1.5",
	])
	var config: ServerConfig = ServerConfig.from_args(args)
	assert_eq(config.port, 24600, "non-numeric port")
	assert_eq(config.max_players, 40, "0 players is not valid: the zone's capacity")
	assert_eq(config.max_connections_per_ip, 4, "-1 connections is not valid")
	assert_eq(config.idle_quit_seconds, 0, "text in --idle-quit")
	assert_eq(config.fake_players, 0, "empty in --fake-players")
	assert_eq(config.quit_after_ticks, 0, "decimal in --quit-after-ticks")


func test_out_of_range_numbers_keep_the_default() -> void:
	for port_arg: String in ["--port=0", "--port=-5", "--port=65536", "--port=999999"]:
		var config: ServerConfig = ServerConfig.from_args(PackedStringArray([port_arg]))
		assert_eq(config.port, 24600, port_arg)
	assert_eq(ServerConfig.from_args(PackedStringArray(["--port=1"])).port, 1, "minimum port")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--port=65535"])).port, 65535,
			"maximum port")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--idle-quit=-3"])).idle_quit_seconds, 0,
			"negative idle time")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--fake-players=-3"])).fake_players, 0,
			"negative fake players")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--max-players=100000"])).max_players,
			40, "absurd cap")


## H5 review: the default capacity is the zone's. Vado Gris (the war zone) stays at the per-battle player
## limit measured with the phase 4 kit (docs/red.md, section 14); a zone without its own capacity,
## at 64; and --max-players always wins.
func test_the_zone_sets_the_default_capacity() -> void:
	assert_eq(NetZones.max_players("vado_gris"), 40, "Vado Gris has its own capacity")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--zone=vado_gris"])).max_players, 40, "and it is its server's")
	assert_eq(NetZones.max_players("test_world"), 0, "the test world has none")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--zone=test_world"])).max_players,
			ServerConfig.DEFAULT_MAX_PLAYERS, "without its own capacity, 64")
	assert_eq(ServerConfig.DEFAULT_MAX_PLAYERS, 64)
	assert_eq(ServerConfig.from_args(PackedStringArray(["--zone=atlantida"])).max_players, 64, "nor an unknown one")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--zone=vado_gris", "--max-players=64"])).max_players, 64,
			"--max-players overrides the zone's")
	assert_eq(ServerConfig.new().max_players, 64, "without reading arguments, 64")


func test_zone_argument_is_normalised_and_not_validated() -> void:
	var quoted: ServerConfig = ServerConfig.from_args(PackedStringArray(["--zone=\"Vado_Gris\""]))
	assert_eq(quoted.zone_id, "vado_gris", "without quotes and in lowercase")
	var unknown: ServerConfig = ServerConfig.from_args(PackedStringArray(["--zone=atlantida"]))
	assert_eq(unknown.zone_id, "atlantida",
			"a nonexistent zone is kept (ServerMain warns about it)")
	assert_eq(NetZones.scene_path(unknown.zone_id), "", "and it has no scene")
	var empty: ServerConfig = ServerConfig.from_args(PackedStringArray(["--zone="]))
	assert_eq(empty.zone_id, NetZones.default_zone_id(), "empty = default zone")


func test_paths_keep_case_and_lose_quotes() -> void:
	var args := PackedStringArray(["--report=\"Salida/Informe Final.json\"", "--state-log= x.csv "])
	var config: ServerConfig = ServerConfig.from_args(args)
	assert_eq(config.report_path, "Salida/Informe Final.json", "uppercase, spaces and quotes")
	assert_eq(config.state_log_path, "x.csv", "spaces around it")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--stop-file=\"Parar Ya.txt\""])).stop_file_path,
			"Parar Ya.txt", "--stop-file also keeps uppercase and spaces and strips the quotes")
	assert_eq(ServerConfig.new().stop_file_path, "", "without --stop-file, empty")


func test_first_occurrence_wins_and_unknown_arguments_are_ignored() -> void:
	var args := PackedStringArray([
		"--port=24800", "--port=24900", "--no-existe=1", "--connect=127.0.0.1", "ruido",
	])
	var config: ServerConfig = ServerConfig.from_args(args)
	assert_eq(config.port, 24800, "the first occurrence wins")
	assert_eq(config.max_players, 40, "the unknown changes nothing")


func test_flags_need_exact_name() -> void:
	var config: ServerConfig = ServerConfig.from_args(
			PackedStringArray(["--debug-commands=1", "--dev-lockx"]))
	assert_false(config.debug_commands, "--debug-commands=1 is not the flag")
	assert_false(config.dev_lock, "--dev-lockx is not the flag")


func test_dev_lock_path_option() -> void:
	var defaults: ServerConfig = ServerConfig.from_args(PackedStringArray(["--dev-lock"]))
	assert_eq(defaults.dev_lock_path, "", "without the option, the lock goes in the usual place")
	var custom: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--dev-lock", "--dev-lock-path=build\\123\\lock.json", "--dev-lock-path=otro.json"]))
	assert_eq(custom.dev_lock_path, "build/123/lock.json", "the first wins and the slashes are normalized")
	assert_true(custom.dev_lock)


func test_fake_player_layout_and_churn_options() -> void:
	var defaults: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_eq(defaults.fake_layout, "", "no spread: each fake player near its realm's camp")
	assert_eq(defaults.fake_churn_ticks, 0, "no continuous joins or leaves")
	var cluster: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--fake-players=64", "--fake-layout=Cluster", "--fake-churn=60"]))
	assert_eq(cluster.fake_layout, "cluster", "grouped (case-insensitive)")
	assert_eq(cluster.fake_churn_ticks, 60, "one join and one leave per second")
	var spread: ServerConfig = ServerConfig.from_args(PackedStringArray(["--fake-layout=spread"]))
	assert_eq(spread.fake_layout, "spread", "spread out")
	var invalid: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--fake-layout=circulo", "--fake-churn=-4"]))
	assert_eq(invalid.fake_layout, "", "an unknown spread is ignored")
	assert_eq(invalid.fake_churn_ticks, 0, "and a negative number too")


func test_combat_options() -> void:
	var defaults: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_eq(defaults.combat_log_path, "", "no combat log")
	assert_eq(defaults.fake_brain, "", "the fake players wander")
	assert_false(defaults.console, "no console")
	assert_false(defaults.no_dummies, "with dummies")
	assert_false(defaults.no_npcs, "with the NPCs from the spawners")
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--server", "--combat-log=build\\combate.txt", "--fake-brain=COMBAT", "--console",
		"--no-dummies", "--no-npcs",
	]))
	assert_eq(config.combat_log_path, "build/combate.txt", "path with normal slashes")
	assert_eq(config.fake_brain, ServerConfig.FAKE_BRAIN_COMBAT, "combat brain")
	assert_true(config.console)
	assert_true(config.no_dummies)
	assert_true(config.no_npcs, "--no-npcs turns off the NPC spawners")
	var wrong: ServerConfig = ServerConfig.from_args(PackedStringArray(["--fake-brain=volar"]))
	assert_eq(wrong.fake_brain, "", "an unknown brain is ignored")


func test_battle_log_option() -> void:
	var defaults: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_eq(defaults.battle_log_path, "", "no battle log")
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--server", "--battle-log=build\\batalla.jsonl"]))
	assert_eq(config.battle_log_path, "build/batalla.jsonl", "path with normal slashes")
	var empty: ServerConfig = ServerConfig.from_args(PackedStringArray(["--battle-log="]))
	assert_eq(empty.battle_log_path, "", "no path, no log")


func test_fake_center_option() -> void:
	var defaults: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_false(defaults.has_fake_center(), "no center: the combat ones gather at the camp")
	var centered: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--fake-players=54", "--fake-brain=combat", "--fake-layout=cluster", "--fake-center=0, -96.5"]))
	assert_true(centered.has_fake_center())
	assert_eq(centered.fake_center, Vector2(0.0, -96.5), "x y z, with spaces tolerated")
	for text: String in ["--fake-center=", "--fake-center=5", "--fake-center=1,2,3", "--fake-center=a,b",
			"--fake-center=1e9,0", "--fake-center=inf,0"]:
		var invalid: ServerConfig = ServerConfig.from_args(PackedStringArray([text]))
		assert_false(invalid.has_fake_center(), "%s is ignored" % text)


func test_max_realm_diff_option() -> void:
	var defaults: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_eq(defaults.max_realm_diff, 0, "by default, no limit")
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray(["--server", "--max-realm-diff=8"]))
	assert_eq(config.max_realm_diff, 8)
	assert_eq(ServerConfig.from_args(PackedStringArray(["--max-realm-diff=0"])).max_realm_diff, 0, "0 = no limit")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--max-realm-diff=-2"])).max_realm_diff, 0, "a negative is ignored")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--max-realm-diff=muchos"])).max_realm_diff, 0, "and a text too")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--max-realm-diff=99999"])).max_realm_diff, 0, "and an absurd one")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--max-realm-diff=3", "--max-realm-diff=9"])).max_realm_diff, 3,
			"the first wins")


func test_siege_fake_brain_option() -> void:
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray(["--fake-brain=Siege"]))
	assert_eq(config.fake_brain, ServerConfig.FAKE_BRAIN_SIEGE, "siege brain (case-insensitive)")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--fake-brain=combat"])).fake_brain,
			ServerConfig.FAKE_BRAIN_COMBAT, "the combat one stays the same")


func test_run_at_option_schedules_console_commands() -> void:
	assert_true(ServerConfig.from_args(PackedStringArray()).scheduled_commands.is_empty(), "no scheduled commands")
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--run-at=900:fort_kill_captain", "--run-at=1800:fort_capture_speed 30",
		"--run-at=\"60: announce hola\"",
		"--run-at=nada", "--run-at=-5:heal", "--run-at=x:heal", "--run-at=30:", "--run-at=:heal",
	]))
	assert_eq(config.scheduled_commands.size(), 3, "only the well-formed ones")
	assert_eq(config.scheduled_commands[0], {"tick": 900, "line": "fort_kill_captain"}, "tick and command")
	assert_eq(config.scheduled_commands[1], {"tick": 1800, "line": "fort_capture_speed 30"}, "with arguments")
	assert_eq(config.scheduled_commands[2], {"tick": 60, "line": "announce hola"}, "without quotes or spaces")


func test_fake_archers_option_for_load_tests() -> void:
	assert_eq(ServerConfig.from_args(PackedStringArray()).fake_archers_sky_percent, -1, "without the option, there are no pure archers")
	assert_false(ServerConfig.from_args(PackedStringArray()).is_sky_archer(0))
	var none: ServerConfig = ServerConfig.from_args(PackedStringArray(["--fake-archers=0"]))
	assert_eq(none.fake_archers_sky_percent, 0, "pure archers, none shooting at the sky")
	assert_false(none.is_sky_archer(0) or none.is_sky_archer(1))
	var half: ServerConfig = ServerConfig.from_args(PackedStringArray(["--fake-archers=50"]))
	assert_eq([half.is_sky_archer(0), half.is_sky_archer(1), half.is_sky_archer(2), half.is_sky_archer(3)],
			[false, true, false, true], "with 50, one in every two shoots at the sky")
	assert_true(ServerConfig.from_args(PackedStringArray(["--fake-archers=100"])).is_sky_archer(0), "with 100, all of them")
	for bad: String in ["--fake-archers=101", "--fake-archers=-3", "--fake-archers=muchos"]:
		assert_eq(ServerConfig.from_args(PackedStringArray([bad])).fake_archers_sky_percent, -1, "%s is not valid" % bad)


## The platform options (docs/plataforma.md §14.3): --platform, --world, --channel, --public-address,
## --save-interval, --replace, --dtls-cert and --dtls-key, and the development ones that, together with it, are only valid in dev and test.
func test_platform_options() -> void:
	var plain: ServerConfig = ServerConfig.from_args(PackedStringArray(["--server", "--port=24610"]))
	assert_false(plain.uses_platform(), "without --platform, no platform")
	assert_eq([plain.world_id, plain.channel, plain.save_interval_s, plain.replace], [1, 0, 60, false],
			"world 1, channel 0, 60 s and no --replace")
	assert_eq([plain.public_host(), plain.public_port()], ["127.0.0.1", 24610], "127.0.0.1 and its port")
	assert_eq(plain.platform_dev_options(), PackedStringArray(), "no development option")
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray(["--server", "--port=24610",
			"--platform=http://platform:24681", "--world=3", "--channel=2", "--public-address=203.0.113.5:24700",
			"--save-interval=5", "--replace", "--dtls-cert=/run/secrets/c.pem", "--dtls-key=/run/secrets/k.pem",
			"--debug-commands", "--fake-players=3", "--fake-churn=60", "--battle-log=b.jsonl",
			"--combat-log=c.txt", "--state-log=s.txt"]))
	assert_true(config.uses_platform(), "with --platform")
	assert_eq(config.platform_url, "http://platform:24681", "the internal URL")
	assert_eq([config.world_id, config.channel, config.save_interval_s, config.replace], [3, 2, 5, true],
			"world, channel, interval and --replace")
	assert_eq([config.public_host(), config.public_port()], ["203.0.113.5", 24700], "public host and port")
	assert_eq([config.dtls_cert_path, config.dtls_key_path], ["/run/secrets/c.pem", "/run/secrets/k.pem"], "DTLS")
	assert_eq(config.platform_dev_options(), PackedStringArray(["--debug-commands", "--fake-players",
			"--fake-churn", "--battle-log", "--combat-log", "--state-log"]), "the six development ones")
	var host_only: ServerConfig = ServerConfig.from_args(PackedStringArray(["--public-address=zona.eldmark.test"]))
	assert_eq([host_only.public_host(), host_only.public_port()], ["zona.eldmark.test", NetProtocol.DEFAULT_PORT],
			"without a port, the one from --port")
	var ipv6: ServerConfig = ServerConfig.from_args(PackedStringArray(["--public-address=[2001:db8::5]:24601"]))
	assert_eq([ipv6.public_host(), ipv6.public_port()], ["2001:db8::5", 24601], "IPv6 in square brackets")
	for bad: String in ["--world=0", "--world=70000", "--channel=256", "--channel=-1", "--save-interval=0"]:
		var parsed: ServerConfig = ServerConfig.from_args(PackedStringArray([bad]))
		assert_eq([parsed.world_id, parsed.channel, parsed.save_interval_s], [1, 0, 60], "%s is not valid" % bad)
	var bad_port: ServerConfig = ServerConfig.from_args(PackedStringArray(["--public-address=h:99999"]))
	assert_eq(bad_port.public_port(), NetProtocol.DEFAULT_PORT, "an out-of-range port, the one from --port")
