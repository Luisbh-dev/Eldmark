extends SceneTree
## A siege battle with fake players on Vado Gris, in a single process and with no network (GUE-15, GUE-17;
## docs/fortress.md, section 7). It is the long test that does not fit in the suite (the short version is
## [code]tests/test_siege_zone.gd[/code]): [SiegeRunner] advances the server quickly and this tool counts
## what happens and summarises it in Spanish.
## [br][br]
## [b]Usage[/b], from the project root (the console [code]godot[/code]):
## [codeblock]
## # Twenty from Vardheim capture the neutral fort and twenty from Solmarch recapture it (with capture at the
## # real speed); battle log and its summary
## godot --headless --path . -s res://tools/war/siege_battle.gd -- --per-side=20 --battle-log=build/siege.jsonl
## # Both sides at once for 8 minutes of game time, without speeding up the capture
## godot --headless --path . -s res://tools/war/siege_battle.gd -- --scenario=war --per-side=20 --minutes=8
## # The same as the first, but with the real NPCs (the Hollow, the Ford Captain and the garrison) and without help (F6b)
## godot --headless --path . -s res://tools/war/siege_battle.gd -- --npcs --per-side=20 --minutes=30
## # Same, with the bots as before GUE-44 (no rally or formation), for comparison
## godot --headless --path . -s res://tools/war/siege_battle.gd -- --npcs --per-side=20 --minutes=30 --rally=0
## # Same, with nobody on the walkway (as before GUE-45), for comparison
## godot --headless --path . -s res://tools/war/siege_battle.gd -- --npcs --per-side=20 --minutes=30 --walkway=0
## [/codeblock]
## [b]Options[/b] (after [code]--[/code]):
## [br]- [code]--scenario=capture[/code] (default): first the Vardheim ones, who capture the neutral fort; when
## they hold it, the Solmarch ones go out and recapture it (and the Vardheim ones defend it). [code]--scenario=war[/code]:
## both sides go out at once and the battle lasts [code]--minutes[/code].
## [br]- [code]--per-side=N[/code] bots per side (default 20). [code]--capture-speed=K[/code] multiplies the capture
## speed (command 11; default 1, the real one). [code]--minutes=M[/code] minutes of game time at most (default
## 10). [code]--battle-log=<path>[/code] JSON Lines battle log ([BattleLog]) and, when done, its
## summary ([BattleSummary]). [code]--seed=N[/code] seed of the brains (default 1000).
## [br]- [code]--npcs[/code] (F6b): the server starts with its NPCs and the tool helps in no way: the bots
## have to kill the Hollow, the Ford Captain and the owner's garrison. Without it (the F6a siege, with no
## NPCs), when the gate is broken and the fort guarded, the tool declares the captain dead
## ([code]fort_kill_captain[/code], as the console would). [code]--npc-health=<id>:<health>[/code] (repeatable, with
## [code]--npcs[/code]) changes the health of a definition in [code]data/npcs/[/code] only in this battle, to
## test adjustments without touching the data. [code]--verbose[/code] writes the state every 10 s of game time.
## [br]- [code]--rally=N[/code] (GUE-44): the attackers leave their camp when there are N from their realm at the
## rally point (by default, [constant BotBrain.SIEGE_RALLY_GROUP_SIZE]); with 0 or 1 they neither wait nor go in formation, as
## before GUE-44 (useful for comparison). [code]--rally-period=S[/code]: seconds of each lap of the rally clock
## (default 30).
## [br]- [code]--walkway=F[/code] (GUE-45): the share of bots with the walkway role (by default
## [constant BotBrain.SIEGE_WALKWAY_SHARE]; the owner's ones guard it and the attackers walk it once on entering); with 0
## nobody goes up, as before GUE-45.
## [br][br]
## The report gives, per phase, the milestones since its bots leave: first hit on the gate, gate broken (and how many
## times), captain down and capture, and, per realm, the group departures from the rally (how many and of how many), and where
## the dead have fallen (with the classes of the battle summary: bridge, ford, esplanade and courtyard, walkway). It ends
## with code 0 if the [code]capture[/code] scenario ends with Solmarch as owner and 1 if not.

const CHECK_TICKS: int = 30
## How many ticks apart it writes the state with [code]--verbose[/code].
const VERBOSE_TICKS: int = 600

var _with_npcs: bool = false
var _verbose: bool = false
# Tick at which the bots of each phase leave and the side that plays it: {name, realm, tick}.
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
	var rally_size: int = _int_option(args, "--rally=", -1)
	var walkway_text: String = _option(args, "--walkway=", "")
	var rally_period_s: int = _int_option(args, "--rally-period=",
			roundi(float(BotBrain.SIEGE_RALLY_PERIOD_TICKS) / float(SiegeRunner.TICK_RATE)))

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
	if rally_size >= 0:
		runner.set_rally(rally_size, rally_period_s * SiegeRunner.TICK_RATE)
	if walkway_text.is_valid_float():
		runner.set_walkway_share(clampf(walkway_text.to_float(), 0.0, 1.0))
		print("  pasarela: %.2f de los bots" % clampf(walkway_text.to_float(), 0.0, 1.0))
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


# Advances until [param goal_owner] (0 = nobody: time runs out) holds the fort or
# [param limit_ticks] pass from now. Without NPCs it kills the captain when due; records each change of owner.
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


# A status line: phase, gate, presence, bots alive and health and state of the war NPCs (without the Guardians).
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


# The milestones of each phase, counted from when its bots leave.
func _report_phases(runner: SiegeRunner) -> void:
	for index: int in _phases.size():
		var phase: Dictionary = _phases[index]
		# The warnings of a phase are those after the tick at which its bots leave (they are added between two ticks) up to that of
		# the next phase included: the capture that ends it may fall right on that tick (GUE-44: with seed 4000,
		# the capture of the neutral fort showed up in the recapture, at 0 s).
		var from_tick: int = int(phase["tick"])
		var to_tick: int = int(_phases[index + 1]["tick"]) if index + 1 < _phases.size() else runner.tick()
		var parts := PackedStringArray()
		for milestone: Array in [[WarEvents.UNDER_ATTACK, "primer golpe"], [WarEvents.GATE_BROKEN, "puerta rota"],
				[WarEvents.CAPTAIN_DOWN, "capitán caído"], [WarEvents.FORT_CAPTURED, "captura"]]:
			var tick_of: int = runner.tick_of_war(int(milestone[0]), from_tick + 1)
			if tick_of >= 0 and tick_of <= to_tick:
				parts.append("%s a los %.1f s" % [milestone[1], SiegeRunner.seconds(tick_of - from_tick)])
			else:
				parts.append("%s: no" % milestone[1])
		var broken: int = runner.count_war(WarEvents.GATE_BROKEN, from_tick + 1) \
				- runner.count_war(WarEvents.GATE_BROKEN, to_tick + 1)
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
	_report_rally(runner)
	print("Capturas: %d" % captures.size())
	for capture: Dictionary in captures:
		print("  %s en el tick %d (%.0f s)" % [WarEvents.realm_label(int(capture["owner"])), int(capture["tick"]),
				SiegeRunner.seconds(int(capture["tick"]))])
	var deaths: Dictionary = {}
	for death: Dictionary in runner.deaths:
		var realm_key: String = WarEvents.realm_label(int(death["realm"]))
		deaths[realm_key] = int(deaths.get(realm_key, 0)) + 1
	print("Muertes de jugadores: %d %s" % [runner.deaths.size(), deaths])
	_report_places(runner, runner.deaths, "Dónde caen los jugadores")
	if _with_npcs:
		var npc_deaths: Dictionary = {}
		for death: Dictionary in runner.npc_deaths:
			var key: String = String(death["npc"])
			npc_deaths[key] = int(npc_deaths.get(key, 0)) + 1
		print("Muertes de PNJ: %d %s" % [runner.npc_deaths.size(), npc_deaths])
		_report_places(runner, runner.npc_deaths, "Dónde caen los PNJ")
	var state: FortressState = runner.state()
	print("Estado final: dueño %s, fase %d, puerta %d/%d, presencia %s" % [WarEvents.realm_label(state.owner),
			state.phase, state.gate_health, state.gate_max, state.presence])
	var ids: Array[String] = []
	for war_id: int in runner.war_ids():
		ids.append(String(WarEvents.key_of(war_id)))
	print("Avisos de guerra: %s" % ", ".join(PackedStringArray(ids)))


# Where the dead in [param list] have fallen (those of SiegeRunner, with their position), with the classes of the battle summary
# (GUE-17, GUE-45) and, on the walkway, which realm or which NPC they were.
func _report_places(runner: SiegeRunner, list: Array[Dictionary], title: String) -> void:
	var labels: Dictionary = {"bridge": "puente", "ford": "vado", "gate": "explanada y patio", "walkway": "pasarela",
			"other": "otros sitios"}
	var counts: Dictionary = {}
	var on_walkway: Dictionary = {}
	for death: Dictionary in list:
		var place: String = String(runner.place_of(death["position"]))
		counts[place] = int(counts.get(place, 0)) + 1
		if place == String(BattleSummary.WALKWAY):
			var who: String = String(death["npc"]) if death.has("npc") else WarEvents.realm_label(int(death["realm"]))
			on_walkway[who] = int(on_walkway.get(who, 0)) + 1
	var parts := PackedStringArray()
	for place: String in ["bridge", "ford", "gate", "walkway", "other"]:
		parts.append("%s %d" % [labels[place], int(counts.get(place, 0))])
	print("%s: %s%s" % [title, ", ".join(parts), "" if on_walkway.is_empty() else " (en la pasarela: %s)" % on_walkway])


# The group departures from the rally (GUE-44), per realm: how many groups, of how many, and whether any split between routes.
func _report_rally(runner: SiegeRunner) -> void:
	for realm: int in [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH]:
		# A group: the departures that fall less than 1 s after the previous one (those who arrive while the group is leaving, which is still
		# at the rally point, leave one tick later).
		var groups: Dictionary = {}
		var key: int = -1000
		var last_tick: int = -1000
		var departures: Array[Dictionary] = runner.rally_departures.duplicate()
		departures.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["tick"]) < int(b["tick"]))
		for departure: Dictionary in departures:
			if int(departure["realm"]) != realm:
				continue
			var tick_of: int = int(departure["tick"])
			if tick_of - last_tick > SiegeRunner.TICK_RATE:
				key = tick_of
				groups[key] = {"size": 0, "routes": {}}
			last_tick = tick_of
			groups[key]["size"] = int(groups[key]["size"]) + 1
			groups[key]["routes"][String(departure["route"])] = true
		if groups.is_empty():
			continue
		var sizes := PackedStringArray()
		var total: int = 0
		var smallest: int = 1 << 30
		var largest: int = 0
		var mixed: int = 0
		for group_key: int in groups:
			var size: int = int(groups[group_key]["size"])
			sizes.append("%d" % size)
			total += size
			smallest = mini(smallest, size)
			largest = maxi(largest, size)
			if (groups[group_key]["routes"] as Dictionary).size() > 1:
				mixed += 1
		print("Reunión de %s: %d salidas en grupo de %d a %d (media %.1f; %d con más de una ruta): %s" % [
				WarEvents.realm_label(realm), groups.size(), smallest, largest, float(total) / float(groups.size()),
				mixed, " ".join(sizes)])


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
