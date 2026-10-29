extends TestCase
## Pruebas de la lectura de los argumentos del servidor ([ServerConfig.from_args], docs/red.md
## sección 1.2).


func test_defaults_without_arguments() -> void:
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_eq(config.port, NetProtocol.DEFAULT_PORT, "puerto por defecto")
	assert_eq(config.port, 24600, "24600")
	assert_eq(config.zone_id, NetZones.default_zone_id(), "zona por defecto")
	assert_eq(config.max_players, 64, "jugadores")
	assert_eq(config.max_connections_per_ip, 4, "conexiones por IP")
	assert_eq(config.idle_quit_seconds, 0, "sin cierre por inactividad")
	assert_eq(config.quit_after_ticks, 0, "sin cierre por ticks")
	assert_eq(config.report_path, "", "sin informe")
	assert_eq(config.state_log_path, "", "sin registro de estado")
	assert_eq(config.net_sim_spec, "", "sin simulador de red")
	assert_eq(config.fake_players, 0, "sin jugadores falsos")
	assert_false(config.debug_commands, "sin comandos de depuración")
	assert_false(config.dev_lock, "sin archivo de bloqueo")


func test_server_flag_alone_keeps_defaults() -> void:
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray(["--server"]))
	assert_eq(config.port, 24600, "puerto")
	assert_eq(config.zone_id, NetZones.default_zone_id(), "zona")
	assert_false(config.debug_commands, "depuración")


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
			"el simulador conserva los = de su especificación")


func test_invalid_numbers_keep_the_default() -> void:
	var args := PackedStringArray([
		"--port=abc", "--max-players=0", "--max-per-ip=-1", "--idle-quit=x", "--fake-players=",
		"--quit-after-ticks=1.5",
	])
	var config: ServerConfig = ServerConfig.from_args(args)
	assert_eq(config.port, 24600, "puerto no numérico")
	assert_eq(config.max_players, 64, "0 jugadores no vale")
	assert_eq(config.max_connections_per_ip, 4, "-1 conexiones no vale")
	assert_eq(config.idle_quit_seconds, 0, "texto en --idle-quit")
	assert_eq(config.fake_players, 0, "vacío en --fake-players")
	assert_eq(config.quit_after_ticks, 0, "decimal en --quit-after-ticks")


func test_out_of_range_numbers_keep_the_default() -> void:
	for port_arg: String in ["--port=0", "--port=-5", "--port=65536", "--port=999999"]:
		var config: ServerConfig = ServerConfig.from_args(PackedStringArray([port_arg]))
		assert_eq(config.port, 24600, port_arg)
	assert_eq(ServerConfig.from_args(PackedStringArray(["--port=1"])).port, 1, "puerto mínimo")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--port=65535"])).port, 65535,
			"puerto máximo")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--idle-quit=-3"])).idle_quit_seconds, 0,
			"inactividad negativa")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--fake-players=-3"])).fake_players, 0,
			"jugadores falsos negativos")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--max-players=100000"])).max_players,
			64, "cupo absurdo")


func test_zone_argument_is_normalised_and_not_validated() -> void:
	var quoted: ServerConfig = ServerConfig.from_args(PackedStringArray(["--zone=\"Vado_Gris\""]))
	assert_eq(quoted.zone_id, "vado_gris", "sin comillas y en minúsculas")
	var unknown: ServerConfig = ServerConfig.from_args(PackedStringArray(["--zone=atlantida"]))
	assert_eq(unknown.zone_id, "atlantida",
			"una zona inexistente se conserva (lo avisa ServerMain)")
	assert_eq(NetZones.scene_path(unknown.zone_id), "", "y no tiene escena")
	var empty: ServerConfig = ServerConfig.from_args(PackedStringArray(["--zone="]))
	assert_eq(empty.zone_id, NetZones.default_zone_id(), "vacío = zona por defecto")


func test_paths_keep_case_and_lose_quotes() -> void:
	var args := PackedStringArray(["--report=\"Salida/Informe Final.json\"", "--state-log= x.csv "])
	var config: ServerConfig = ServerConfig.from_args(args)
	assert_eq(config.report_path, "Salida/Informe Final.json", "mayúsculas, espacios y comillas")
	assert_eq(config.state_log_path, "x.csv", "espacios alrededor")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--stop-file=\"Parar Ya.txt\""])).stop_file_path,
			"Parar Ya.txt", "--stop-file también conserva mayúsculas, espacios y quita las comillas")
	assert_eq(ServerConfig.new().stop_file_path, "", "sin --stop-file, vacío")


func test_first_occurrence_wins_and_unknown_arguments_are_ignored() -> void:
	var args := PackedStringArray([
		"--port=24800", "--port=24900", "--no-existe=1", "--connect=127.0.0.1", "ruido",
	])
	var config: ServerConfig = ServerConfig.from_args(args)
	assert_eq(config.port, 24800, "gana la primera ocurrencia")
	assert_eq(config.max_players, 64, "lo desconocido no cambia nada")


func test_flags_need_exact_name() -> void:
	var config: ServerConfig = ServerConfig.from_args(
			PackedStringArray(["--debug-commands=1", "--dev-lockx"]))
	assert_false(config.debug_commands, "--debug-commands=1 no es la bandera")
	assert_false(config.dev_lock, "--dev-lockx no es la bandera")


func test_dev_lock_path_option() -> void:
	var defaults: ServerConfig = ServerConfig.from_args(PackedStringArray(["--dev-lock"]))
	assert_eq(defaults.dev_lock_path, "", "sin la opción, el bloqueo va en el sitio de siempre")
	var custom: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--dev-lock", "--dev-lock-path=build\\123\\lock.json", "--dev-lock-path=otro.json"]))
	assert_eq(custom.dev_lock_path, "build/123/lock.json", "gana la primera y se normalizan las barras")
	assert_true(custom.dev_lock)


func test_fake_player_layout_and_churn_options() -> void:
	var defaults: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_eq(defaults.fake_layout, "", "sin reparto: cada falso cerca del campamento de su reino")
	assert_eq(defaults.fake_churn_ticks, 0, "sin altas ni bajas continuas")
	var cluster: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--fake-players=64", "--fake-layout=Cluster", "--fake-churn=60"]))
	assert_eq(cluster.fake_layout, "cluster", "agrupados (sin distinguir mayúsculas)")
	assert_eq(cluster.fake_churn_ticks, 60, "una alta y una baja por segundo")
	var spread: ServerConfig = ServerConfig.from_args(PackedStringArray(["--fake-layout=spread"]))
	assert_eq(spread.fake_layout, "spread", "repartidos")
	var invalid: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--fake-layout=circulo", "--fake-churn=-4"]))
	assert_eq(invalid.fake_layout, "", "un reparto desconocido se ignora")
	assert_eq(invalid.fake_churn_ticks, 0, "y un número negativo también")


func test_combat_options() -> void:
	var defaults: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_eq(defaults.combat_log_path, "", "sin registro de combate")
	assert_eq(defaults.fake_brain, "", "los falsos pasean")
	assert_false(defaults.console, "sin consola")
	assert_false(defaults.no_dummies, "con maniquíes")
	assert_false(defaults.no_npcs, "con los PNJ de los generadores")
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--server", "--combat-log=build\\combate.txt", "--fake-brain=COMBAT", "--console",
		"--no-dummies", "--no-npcs",
	]))
	assert_eq(config.combat_log_path, "build/combate.txt", "ruta con barras normales")
	assert_eq(config.fake_brain, ServerConfig.FAKE_BRAIN_COMBAT, "cerebro de combate")
	assert_true(config.console)
	assert_true(config.no_dummies)
	assert_true(config.no_npcs, "--no-npcs apaga los generadores de PNJ")
	var wrong: ServerConfig = ServerConfig.from_args(PackedStringArray(["--fake-brain=volar"]))
	assert_eq(wrong.fake_brain, "", "un cerebro desconocido se ignora")


func test_battle_log_option() -> void:
	var defaults: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_eq(defaults.battle_log_path, "", "sin registro de batalla")
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--server", "--battle-log=build\\batalla.jsonl"]))
	assert_eq(config.battle_log_path, "build/batalla.jsonl", "ruta con barras normales")
	var empty: ServerConfig = ServerConfig.from_args(PackedStringArray(["--battle-log="]))
	assert_eq(empty.battle_log_path, "", "sin ruta, sin registro")


func test_fake_center_option() -> void:
	var defaults: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_false(defaults.has_fake_center(), "sin centro: los de combate se juntan en el campamento")
	var centered: ServerConfig = ServerConfig.from_args(PackedStringArray([
		"--fake-players=54", "--fake-brain=combat", "--fake-layout=cluster", "--fake-center=0, -96.5"]))
	assert_true(centered.has_fake_center())
	assert_eq(centered.fake_center, Vector2(0.0, -96.5), "x y z, con espacios tolerados")
	for text: String in ["--fake-center=", "--fake-center=5", "--fake-center=1,2,3", "--fake-center=a,b",
			"--fake-center=1e9,0", "--fake-center=inf,0"]:
		var invalid: ServerConfig = ServerConfig.from_args(PackedStringArray([text]))
		assert_false(invalid.has_fake_center(), "%s se ignora" % text)


func test_max_realm_diff_option() -> void:
	var defaults: ServerConfig = ServerConfig.from_args(PackedStringArray())
	assert_eq(defaults.max_realm_diff, 0, "por defecto, sin límite")
	var config: ServerConfig = ServerConfig.from_args(PackedStringArray(["--server", "--max-realm-diff=8"]))
	assert_eq(config.max_realm_diff, 8)
	assert_eq(ServerConfig.from_args(PackedStringArray(["--max-realm-diff=0"])).max_realm_diff, 0, "0 = sin límite")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--max-realm-diff=-2"])).max_realm_diff, 0, "un negativo se ignora")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--max-realm-diff=muchos"])).max_realm_diff, 0, "y un texto también")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--max-realm-diff=99999"])).max_realm_diff, 0, "y uno absurdo")
	assert_eq(ServerConfig.from_args(PackedStringArray(["--max-realm-diff=3", "--max-realm-diff=9"])).max_realm_diff, 3,
			"gana la primera")
