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
## # Lo mismo que la primera, pero con los PNJ de verdad (Huecos, Capitán del Vado y guarnición) y sin ayudas (F6b)
## godot --headless --path . -s res://tools/war/siege_battle.gd -- --npcs --per-side=20 --minutes=30
## [/codeblock]
## [b]Opciones[/b] (después de [code]--[/code]):
## [br]- [code]--scenario=capture[/code] (por defecto): primero los de Vardheim, que capturan el fuerte neutral; cuando
## lo tienen, salen los de Solmarch, que lo recapturan (y los de Vardheim lo defienden). [code]--scenario=war[/code]:
## los dos bandos salen a la vez y la batalla dura [code]--minutes[/code].
## [br]- [code]--per-side=N[/code] bots por bando (por defecto 20). [code]--capture-speed=K[/code] multiplica la velocidad
## de captura (orden 11; por defecto 1, la de verdad). [code]--minutes=M[/code] minutos de juego como mucho (por
## defecto 10). [code]--battle-log=<ruta>[/code] registro de batalla JSON Lines ([BattleLog]) y, al acabar, su
## resumen ([BattleSummary]). [code]--seed=N[/code] semilla de los cerebros (por defecto 1000).
## [br]- [code]--npcs[/code] (F6b): el servidor arranca con sus PNJ y la herramienta no ayuda en nada: los bots
## tienen que matar a los Huecos, al Capitán del Vado y a la guarnición del dueño. Sin ella (el asedio de F6a, sin
## PNJ), cuando la puerta está rota y el fuerte guardado, la herramienta da por muerto al capitán
## ([code]fort_kill_captain[/code], como haría la consola). [code]--npc-health=<id>:<vida>[/code] (repetible, con
## [code]--npcs[/code]) cambia la vida de una definición de [code]data/npcs/[/code] solo en esta batalla, para
## probar ajustes sin tocar los datos. [code]--verbose[/code] escribe el estado cada 10 s de juego.
## [br][br]
## El informe da, por fase, los hitos desde que salen sus bots: primer golpe a la puerta, puerta rota (y cuántas
## veces), capitán caído y captura. Termina con código 0 si el escenario [code]capture[/code] acaba con Solmarch
## como dueño y 1 si no.

const CHECK_TICKS: int = 30
## Cada cuántos ticks escribe el estado con [code]--verbose[/code].
const VERBOSE_TICKS: int = 600

var _with_npcs: bool = false
var _verbose: bool = false
# Tick en el que salen los bots de cada fase y el bando que la juega: {name, realm, tick}.
var _phases: Array[Dictionary] = []


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
	_with_npcs = args.has("--npcs")
	_verbose = args.has("--verbose")

	var runner := SiegeRunner.new()
	root.add_child(runner)
	var started_usec: int = Time.get_ticks_usec()
	if not await runner.start(root, battle_log, per_side * 2 + 16, _with_npcs):
		printerr("No se pudo arrancar el servidor sobre el Vado Gris")
		quit(1)
		return
	for arg: String in args:
		if not arg.begins_with("--npc-health="):
			continue
		var parts: PackedStringArray = arg.trim_prefix("--npc-health=").split(":")
		if parts.size() != 2 or not parts[1].is_valid_int() \
				or not runner.set_npc_health(StringName(parts[0]), parts[1].to_int()):
			printerr("--npc-health no válido (o sin --npcs): %s" % arg)
			quit(1)
			return
		print("  %s con %s de vida (solo en esta batalla)" % [parts[0], parts[1]])
	if capture_speed > 1:
		runner.set_capture_speed(capture_speed)
	print("Asedio en el Vado Gris: %s, %d por bando, captura x%d, hasta %d min de juego (semilla %d), %s" % [
		scenario, per_side, capture_speed, minutes, rng_seed,
		"con los PNJ de verdad y sin ayudas" if _with_npcs else "sin PNJ (fort_kill_captain al romper la puerta)"])

	var limit_ticks: int = minutes * 60 * SiegeRunner.TICK_RATE
	var captures: Array[Dictionary] = []
	var ok: bool = true
	match scenario:
		"war":
			_phases.append({"name": "Guerra", "realm": 0, "tick": runner.tick()})
			runner.add_siege_bots(NetProtocol.Realm.VARDHEIM, per_side, rng_seed)
			runner.add_siege_bots(NetProtocol.Realm.SOLMARCH, per_side, rng_seed + 500)
			await _fight(runner, limit_ticks, captures, 0)
		_:
			_phases.append({"name": "Captura del neutral", "realm": NetProtocol.Realm.VARDHEIM, "tick": runner.tick()})
			runner.add_siege_bots(NetProtocol.Realm.VARDHEIM, per_side, rng_seed)
			await _fight(runner, limit_ticks, captures, NetProtocol.Realm.VARDHEIM)
			if runner.state().owner == NetProtocol.Realm.VARDHEIM:
				print("  -> Vardheim tiene el fuerte en el tick %d; salen los de Solmarch" % runner.tick())
				_phases.append({"name": "Recaptura", "realm": NetProtocol.Realm.SOLMARCH, "tick": runner.tick()})
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
# [param limit_ticks] desde ahora. Sin PNJ mata al capitán cuando toca; apunta cada cambio de dueño.
func _fight(runner: SiegeRunner, limit_ticks: int, captures: Array[Dictionary], goal_owner: int) -> void:
	var state: FortressState = runner.state()
	var start_tick: int = runner.tick()
	var last_owner: int = state.owner
	while runner.tick() - start_tick < limit_ticks:
		await runner.advance(CHECK_TICKS)
		if _verbose and runner.tick() % VERBOSE_TICKS < CHECK_TICKS:
			_print_progress(runner)
		if not _with_npcs and state.phase == FortressState.Phase.GARRISONED and state.captain_alive \
				and state.is_gate_broken():
			runner.kill_captain()
		if state.owner != last_owner:
			last_owner = state.owner
			captures.append({"tick": runner.tick(), "owner": state.owner})
			print("  tick %d (%.0f s): el fuerte pasa a %s" % [runner.tick(), SiegeRunner.seconds(runner.tick()),
					WarEvents.realm_label(state.owner)])
			if goal_owner != 0 and state.owner == goal_owner:
				return


# Una línea de estado: fase, puerta, presencia, bots vivos y vida y estado de los PNJ de guerra (sin los Guardianes).
func _print_progress(runner: SiegeRunner) -> void:
	var state: FortressState = runner.state()
	var npcs := PackedStringArray()
	var system: NpcSpawnerSystem = runner.server.get_npc_system()
	if system != null:
		for net_id: int in system.get_alive_ids():
			var brain: HfsmBrain = system.get_brain(net_id)
			var combatant: Combatant = runner.server.get_combat().get_combatant(net_id)
			if brain == null or combatant == null or brain.definition.ignores_safe_area:
				continue
			npcs.append("%s %d (%s)" % [brain.definition.id, combatant.health, HfsmBrain.state_name(brain.state)])
	print("  [%.0f s] fase %d, dueño %s, puerta %d, presencia %s, vivos V%d S%d; PNJ: %s" % [
		SiegeRunner.seconds(runner.tick()), state.phase, WarEvents.realm_label(state.owner), state.gate_health,
		state.presence, runner.alive_bots(NetProtocol.Realm.VARDHEIM), runner.alive_bots(NetProtocol.Realm.SOLMARCH),
		", ".join(npcs) if not npcs.is_empty() else "ninguno"])


# Los hitos de cada fase, contados desde que salen sus bots.
func _report_phases(runner: SiegeRunner) -> void:
	for index: int in _phases.size():
		var phase: Dictionary = _phases[index]
		var from_tick: int = int(phase["tick"])
		var to_tick: int = int(_phases[index + 1]["tick"]) if index + 1 < _phases.size() else runner.tick() + 1
		var parts := PackedStringArray()
		for milestone: Array in [[WarEvents.UNDER_ATTACK, "primer golpe"], [WarEvents.GATE_BROKEN, "puerta rota"],
				[WarEvents.CAPTAIN_DOWN, "capitán caído"], [WarEvents.FORT_CAPTURED, "captura"]]:
			var tick_of: int = runner.tick_of_war(int(milestone[0]), from_tick)
			if tick_of >= 0 and tick_of < to_tick:
				parts.append("%s a los %.1f s" % [milestone[1], SiegeRunner.seconds(tick_of - from_tick)])
			else:
				parts.append("%s: no" % milestone[1])
		var broken: int = runner.count_war(WarEvents.GATE_BROKEN, from_tick) \
				- runner.count_war(WarEvents.GATE_BROKEN, to_tick)
		print("%s (%s, desde el tick %d): %s; la puerta se rompe %d %s" % [phase["name"],
				WarEvents.realm_label(int(phase["realm"])), from_tick, ", ".join(parts), broken,
				"vez" if broken == 1 else "veces"])


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
	_report_phases(runner)
	print("Capturas: %d" % captures.size())
	for capture: Dictionary in captures:
		print("  %s en el tick %d (%.0f s)" % [WarEvents.realm_label(int(capture["owner"])), int(capture["tick"]),
				SiegeRunner.seconds(int(capture["tick"]))])
	var deaths: Dictionary = {}
	for death: Dictionary in runner.deaths:
		var realm_key: String = WarEvents.realm_label(int(death["realm"]))
		deaths[realm_key] = int(deaths.get(realm_key, 0)) + 1
	print("Muertes de jugadores: %d %s" % [runner.deaths.size(), deaths])
	if _with_npcs:
		var npc_deaths: Dictionary = {}
		for death: Dictionary in runner.npc_deaths:
			var key: String = String(death["npc"])
			npc_deaths[key] = int(npc_deaths.get(key, 0)) + 1
		print("Muertes de PNJ: %d %s" % [runner.npc_deaths.size(), npc_deaths])
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
