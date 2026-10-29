extends SceneTree
## Una batalla de asedio con jugadores falsos sobre el Vado Gris, en un solo proceso y sin red (GUE-15, GUE-17;
## docs/fuerte.md, sección 7). Es la prueba larga que no cabe en la suite (la versión corta es
## [code]tests/test_siege_zone.gd[/code]): [SiegeRunner] avanza el servidor deprisa y esta herramienta cuenta
## qué pasa y lo resume en español.
## [br][br]
## [b]Uso[/b], desde la raíz del proyecto (el [code]godot[/code] de consola):
## [codeblock]
## # Veinte de Vardheim capturan el fuerte neutral y veinte de Solmarch lo recapturan (con la captura a la
## # velocidad de verdad); registro de batalla y su resumen
## godot --headless --path . -s res://tools/war/siege_battle.gd -- --per-side=20 --battle-log=build/siege.jsonl
## # Los dos bandos a la vez durante 8 minutos de juego, sin acelerar la captura
## godot --headless --path . -s res://tools/war/siege_battle.gd -- --scenario=war --per-side=20 --minutes=8
## [/codeblock]
## [b]Opciones[/b] (después de [code]--[/code]):
## [br]- [code]--scenario=capture[/code] (por defecto): primero los de Vardheim, que capturan el fuerte neutral; cuando
## lo tienen, salen los de Solmarch, que lo recapturan (y los de Vardheim lo defienden). [code]--scenario=war[/code]:
## los dos bandos salen a la vez y la batalla dura [code]--minutes[/code].
## [br]- [code]--per-side=N[/code] bots por bando (por defecto 20). [code]--capture-speed=K[/code] multiplica la velocidad
## de captura (orden 11; por defecto 1, la de verdad). [code]--minutes=M[/code] minutos de juego como mucho (por
## defecto 10). [code]--battle-log=<ruta>[/code] registro de batalla JSON Lines ([BattleLog]) y, al acabar, su
## resumen ([BattleSummary]). [code]--seed=N[/code] semilla de los cerebros (por defecto 1000).
## [br][br]
## No hay PNJ en este paquete: cuando la puerta está rota y el fuerte guardado, la herramienta da por muerto al
## capitán ([code]fort_kill_captain[/code], como haría la consola). Termina con código 0 si el escenario
## [code]capture[/code] acaba con Solmarch como dueño y 1 si no.

const CHECK_TICKS: int = 30

var _options: Dictionary = {}


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var scenario: String = _option(args, "--scenario=", "capture")
	var per_side: int = _int_option(args, "--per-side=", 20)
	var capture_speed: int = clampi(_int_option(args, "--capture-speed=", 1), 1, 255)
	var minutes: int = _int_option(args, "--minutes=", 10)
	var rng_seed: int = _int_option(args, "--seed=", 1000)
	var battle_log: String = _option(args, "--battle-log=", "")
	if not battle_log.is_empty():
		battle_log = ProjectSettings.globalize_path(battle_log) if battle_log.begins_with("res://") else battle_log

	var runner := SiegeRunner.new()
	root.add_child(runner)
	var started_usec: int = Time.get_ticks_usec()
	if not await runner.start(root, battle_log, per_side * 2 + 16):
		printerr("No se pudo arrancar el servidor sobre el Vado Gris")
		quit(1)
		return
	if capture_speed > 1:
		runner.set_capture_speed(capture_speed)
	print("Asedio en el Vado Gris: %s, %d por bando, captura x%d, hasta %d min de juego (semilla %d)" % [
		scenario, per_side, capture_speed, minutes, rng_seed])

	var limit_ticks: int = minutes * 60 * SiegeRunner.TICK_RATE
	var captures: Array[Dictionary] = []
	var ok: bool = true
	match scenario:
		"war":
			runner.add_siege_bots(NetProtocol.Realm.VARDHEIM, per_side, rng_seed)
			runner.add_siege_bots(NetProtocol.Realm.SOLMARCH, per_side, rng_seed + 500)
			await _fight(runner, limit_ticks, captures, 0)
		_:
			runner.add_siege_bots(NetProtocol.Realm.VARDHEIM, per_side, rng_seed)
			await _fight(runner, limit_ticks, captures, NetProtocol.Realm.VARDHEIM)
			if runner.state().owner == NetProtocol.Realm.VARDHEIM:
				print("  -> Vardheim tiene el fuerte en el tick %d; salen los de Solmarch" % runner.tick())
				runner.add_siege_bots(NetProtocol.Realm.SOLMARCH, per_side, rng_seed + 500)
				await _fight(runner, limit_ticks, captures, NetProtocol.Realm.SOLMARCH)
			ok = runner.state().owner == NetProtocol.Realm.SOLMARCH

	var wall_seconds: float = float(Time.get_ticks_usec() - started_usec) / 1000000.0
	_report(runner, captures, wall_seconds)
	runner.finish()
	if not battle_log.is_empty():
		_print_battle_summary(battle_log)
	quit(0 if ok else 1)


# Avanza hasta que [param goal_owner] (0 = ninguno: se agota el tiempo) tenga el fuerte o pasen
# [param limit_ticks] desde ahora. Mata al capitán cuando toca y apunta cada cambio de dueño.
func _fight(runner: SiegeRunner, limit_ticks: int, captures: Array[Dictionary], goal_owner: int) -> void:
	var state: FortressState = runner.state()
	var start_tick: int = runner.tick()
	var last_owner: int = state.owner
	while runner.tick() - start_tick < limit_ticks:
		await runner.advance(CHECK_TICKS)
		if state.phase == FortressState.Phase.GARRISONED and state.captain_alive and state.is_gate_broken():
			runner.kill_captain()
		if state.owner != last_owner:
			last_owner = state.owner
			captures.append({"tick": runner.tick(), "owner": state.owner})
			print("  tick %d (%.0f s): el fuerte pasa a %s" % [runner.tick(), SiegeRunner.seconds(runner.tick()),
					WarEvents.realm_label(state.owner)])
			if goal_owner != 0 and state.owner == goal_owner:
				return


func _report(runner: SiegeRunner, captures: Array[Dictionary], wall_seconds: float) -> void:
	print("\n== Informe ==")
	print("Ticks simulados: %d (%.0f s de juego) en %.1f s de reloj; jugadores: %d" % [runner.tick(),
			SiegeRunner.seconds(runner.tick()), wall_seconds, runner.bots.size()])
	for realm: int in [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH]:
		var arrivals: Dictionary = {}
		for net_id: int in runner.arrivals:
			var arrival: Dictionary = runner.arrivals[net_id]
			if int(arrival["realm"]) != realm:
				continue
			var route: String = String(arrival["route"])
			if not arrivals.has(route):
				arrivals[route] = []
			(arrivals[route] as Array).append(SiegeRunner.seconds(int(arrival["tick"])))
		var total: int = 0
		for net_id: int in runner.bots:
			if runner.bots[net_id] == realm:
				total += 1
		if total == 0:
			continue
		var parts := PackedStringArray()
		for route: String in arrivals:
			var seconds: Array = arrivals[route]
			seconds.sort()
			parts.append("%s: %d (de %.1f a %.1f s)" % [route, seconds.size(), seconds[0], seconds[seconds.size() - 1]])
		var arrived: int = 0
		for route: String in arrivals:
			arrived += (arrivals[route] as Array).size()
		print("%s: %d bots, %d llegan a la puerta alguna vez (%s)" % [WarEvents.realm_label(realm), total,
				arrived, ", ".join(parts)])
	var gate_hit: int = runner.tick_of_war(WarEvents.UNDER_ATTACK)
	var gate_broken: int = runner.tick_of_war(WarEvents.GATE_BROKEN)
	if gate_hit >= 0 and gate_broken >= 0:
		print("Puerta: primer golpe en %.1f s, rota en %.1f s (%.1f s después)" % [
			SiegeRunner.seconds(gate_hit), SiegeRunner.seconds(gate_broken),
			SiegeRunner.seconds(gate_broken - gate_hit)])
	print("Capturas: %d" % captures.size())
	for capture: Dictionary in captures:
		print("  %s en el tick %d (%.0f s)" % [WarEvents.realm_label(int(capture["owner"])), int(capture["tick"]),
				SiegeRunner.seconds(int(capture["tick"]))])
	var deaths: Dictionary = {}
	for death: Dictionary in runner.deaths:
		var realm_key: String = WarEvents.realm_label(int(death["realm"]))
		deaths[realm_key] = int(deaths.get(realm_key, 0)) + 1
	print("Muertes de jugadores: %d %s" % [runner.deaths.size(), deaths])
	var state: FortressState = runner.state()
	print("Estado final: dueño %s, fase %d, puerta %d/%d, presencia %s" % [WarEvents.realm_label(state.owner),
			state.phase, state.gate_health, state.gate_max, state.presence])
	var ids: Array[String] = []
	for war_id: int in runner.war_ids():
		ids.append(String(WarEvents.key_of(war_id)))
	print("Avisos de guerra: %s" % ", ".join(PackedStringArray(ids)))


func _print_battle_summary(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var routes: ApproachRoutes = load("res://data/routes/vado_gris.tres") as ApproachRoutes
	print("\n== Resumen del registro de batalla (%s) ==" % path)
	print(BattleSummary.format(BattleSummary.summarize(FileAccess.get_file_as_string(path), routes)))


func _option(args: PackedStringArray, prefix: String, fallback: String) -> String:
	for arg: String in args:
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix).strip_edges()
	return fallback


func _int_option(args: PackedStringArray, prefix: String, fallback: int) -> int:
	var text: String = _option(args, prefix, "")
	return text.to_int() if text.is_valid_int() else fallback
