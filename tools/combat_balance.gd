extends SceneTree
## Primera pasada de equilibrio del combate (CMB-29; docs/combate.md, sección 12). Fuera del ejecutor de
## pruebas: monta un [ZoneServer] sin red sobre [code]test_world[/code] (jugadores falsos con cerebros a
## mano, ni clientes ni ENet) y mide con él lo que dicen los datos de [code]data/combat/[/code].
## [br][br]
## [b]Uso[/b], desde la raíz del proyecto (el [code]godot[/code] de consola):
## [codeblock]
## godot --headless --path . -s res://tools/combat_balance.gd
## godot --headless --path . -s res://tools/combat_balance.gd -- --duels=60 --seconds=30
## [/codeblock]
## [b]Opciones[/b]: [code]--duels=N[/code] duelos de bots de combate (por defecto 40), [code]--seconds=S[/code]
## segundos de medida del DPS contra el maniquí (por defecto 30) y [code]--out=<ruta.json>[/code] (por
## defecto [code]build/combat_balance.json[/code]).
## [br][br]
## El servidor se avanza a mano, un tick de 1/60 s cada vez y sin esperar al motor
## ([method _step]), así que la simulación va mucho más deprisa que el tiempo real y el resultado no
## depende de la máquina (no se usa [code]Engine.time_scale[/code]: escala el [code]delta[/code] de la
## física y distorsiona el movimiento).
## [br][br]
## [b]Qué mide[/b]:
## [br]- [b]DPS contra el maniquí[/b]: el combo de tres ligeros encadenado en su ventana, un ligero repetido
## sin enlazar y el fuerte con la carga mínima y con la máxima, cada uno durante los segundos de medida,
## frente al calculado con los datos ([method CombatCatalog]).
## [br]- [b]TTK ideal[/b]: tiempo desde el primer golpe hasta la muerte de un atacante perfecto (combo
## encadenado) contra alguien que no se defiende, y contra alguien que bloquea sin parar (hasta la rotura
## de guardia).
## [br]- [b]TTK entre iguales[/b]: duelos de dos bots de combate ([constant BotBrain.Pattern.COMBAT], que
## ataca, bloquea y esquiva con su semilla) de reinos enemigos, con las mismas armas, desde la distancia de
## 4 m hasta que uno muere: tiempo del primer golpe a la muerte, quién gana, golpes, bloqueos y esquivas.
## [br]- [b]Equipos[/b]: 2 contra 2 y 5 contra 5 de bots de combate, hasta que un bando se queda sin nadie
## en pie (o pasan 60 s, con reapariciones de 10 s de por medio): tiempo hasta la primera baja y hasta
## el fin, y bajas por bando.

## Zona de las mediciones (sin zonas seguras ni terreno).
const ZONE_ID: String = "test_world"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
## Posición del atacante, del maniquí y de los duelistas (m): el atacante mira a -Z.
const ATTACKER_HOME := Vector3(0.0, 0.1, 0.0)
const TARGET_POSITION := Vector3(0.0, 0.1, -2.2)
## Distancia (m) entre duelistas al empezar.
const DUEL_DISTANCE: float = 4.0
## Segundos simulados como mucho que dura un duelo antes de darlo por empatado.
const DUEL_TIMEOUT_SECONDS: float = 90.0
## Segundos simulados como mucho que dura un combate de equipos.
const TEAM_TIMEOUT_SECONDS: float = 60.0
## Semilla del primer duelista; cada duelo suma 2.
const DUEL_SEED_BASE: int = 5000
## Ticks de cada pulsación de un toque.
const TAP_TICKS: int = 2
## Ticks antes del final de un ligero en los que se pulsa para enlazar el siguiente (dentro de su ventana).
const LINK_LEAD_TICKS: int = 4

var _duels: int = 40
var _seconds: int = 30
var _out_path: String = ""
var _world: Node3D = null
var _server: ZoneServer = null
var _events: Array[NetMessages.EntityEvent] = []


## Cerebro a mano: en cada tick llama a [member script_fn] ([code](relative_tick: int, position: Vector3) ->
## PlayerInput[/code], con el tick contado desde [member start_tick]).
class ScriptedBrain:
	extends BotBrain

	var script_fn: Callable = Callable()
	## Tick en el que empieza el guion (hasta entonces, el tick relativo es negativo y el bot no hace nada).
	var start_tick: int = 1 << 40

	func next_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = yaw
		if script_fn.is_valid() and tick >= start_tick:
			var scripted: PlayerInput = script_fn.call(tick - start_tick, position)
			scripted.tick = tick
			return scripted
		return input


func _initialize() -> void:
	_run()


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	_duels = _int_option(args, "--duels=", _duels)
	_seconds = _int_option(args, "--seconds=", _seconds)
	_out_path = _option(args, "--out=", "")
	if _out_path.is_empty():
		_out_path = ProjectSettings.globalize_path("res://build/combat_balance.json")
	var result: Dictionary = {}
	print("Eldmark · primera pasada de equilibrio (CMB-29): %d duelos, %d s de DPS" % [_duels, _seconds])
	result["data"] = _data_table()
	print("")
	result["dps"] = await _measure_dps()
	result["ideal"] = await _measure_ideal_ttk()
	result["duels"] = await _measure_duels()
	result["teams"] = await _measure_teams()
	var directory: String = _out_path.get_base_dir()
	if not directory.is_empty():
		DirAccess.make_dir_recursive_absolute(directory)
	var file: FileAccess = FileAccess.open(_out_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(result, "\t"))
		file.close()
		print("Resultados en %s" % _out_path)
	quit(0)


# --- Lo que dicen los datos -------------------------------------------------------------------

# Duración, daño y coste de cada acción según el catálogo, y los DPS ideales que salen de ellos.
func _data_table() -> Dictionary:
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var rules: CombatRules = CombatCatalog.rules()
	var table: Dictionary = {}
	var combo_ticks: int = 0
	var combo_damage: int = 0
	var lines := PackedStringArray()
	for light_id: int in weapon.light_ids:
		var attack: AttackTicks = CombatCatalog.attack(light_id)
		combo_ticks += attack.total_ticks
		combo_damage += attack.base_damage
		lines.append("  %-14s %3d ticks (%.2f s)  daño %3d  primer golpe al tick %2d  resistencia %d" % [
			attack.name, attack.total_ticks, float(attack.total_ticks) / 60.0, attack.base_damage,
			attack.windup_ticks, attack.stamina_cost])
	var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
	var heavy_min_ticks: int = heavy.charge_min_ticks + heavy.windup_ticks + heavy.active_ticks \
			+ heavy.recovery_ticks
	var heavy_max_ticks: int = heavy.charge_max_ticks + heavy.windup_ticks + heavy.active_ticks \
			+ heavy.recovery_ticks
	var heavy_max_damage: int = roundi(float(heavy.base_damage) * heavy.charge_damage_scale)
	lines.append("  %-14s carga %d-%d ticks + %d de anticipación, %d activo y %d de recuperación; daño %d-%d; resistencia %d" % [
		heavy.name, heavy.charge_min_ticks, heavy.charge_max_ticks, heavy.windup_ticks,
		heavy.active_ticks, heavy.recovery_ticks, heavy.base_damage, heavy_max_damage, heavy.stamina_cost])
	table["combo"] = {"ticks": combo_ticks, "damage": combo_damage,
			"dps": float(combo_damage) / (float(combo_ticks) / 60.0)}
	table["heavy_min"] = {"ticks": heavy_min_ticks, "damage": heavy.base_damage,
			"dps": float(heavy.base_damage) / (float(heavy_min_ticks) / 60.0)}
	table["heavy_max"] = {"ticks": heavy_max_ticks, "damage": heavy_max_damage,
			"dps": float(heavy_max_damage) / (float(heavy_max_ticks) / 60.0)}
	var light_one: AttackTicks = CombatCatalog.attack(weapon.light_ids[0])
	table["light_spam"] = {"ticks": light_one.total_ticks, "damage": light_one.base_damage,
			"dps": float(light_one.base_damage) / (float(light_one.total_ticks) / 60.0)}
	table["ideal_ttk_combo_s"] = float(rules.health_max) / float(combo_damage) * float(combo_ticks) / 60.0
	table["ideal_ttk_heavy_max_s"] = float(rules.health_max) / float(heavy_max_damage) \
			* float(heavy_max_ticks) / 60.0
	print("Datos (data/combat/):")
	for line: String in lines:
		print(line)
	print("  combo de 3 ligeros: %d ticks (%.2f s), %d de daño -> %.1f DPS" % [combo_ticks,
			float(combo_ticks) / 60.0, combo_damage, table["combo"]["dps"]])
	print("  vida %d: TTK ideal con combo continuo %.2f s, con fuertes cargados al máximo %.2f s" % [
		rules.health_max, table["ideal_ttk_combo_s"], table["ideal_ttk_heavy_max_s"]])
	var dodge: DodgeTicks = weapon.dodge
	if dodge != null:
		table["dodge_stamina"] = dodge.stamina_cost
		table["dodges_from_full"] = int(float(rules.stamina_max) / float(maxi(dodge.stamina_cost, 1)))
		print("  esquiva: %d de resistencia (%d seguidas desde la resistencia llena), regenera %d/s tras %.1f s" % [
			dodge.stamina_cost, table["dodges_from_full"], rules.stamina_regen_per_tick * 60,
			rules.stamina_regen_delay_s])
	return table


# --- DPS contra el maniquí --------------------------------------------------------------------

# Mide el DPS de cuatro guiones de ataque contra un maniquí que se cura solo.
func _measure_dps() -> Dictionary:
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var combo_presses: Array[Vector2i] = []    # (tick relativo, ticks pulsado)
	var cycle: int = 0
	for index: int in weapon.light_ids.size():
		var attack: AttackTicks = CombatCatalog.attack(weapon.light_ids[index])
		combo_presses.append(Vector2i(maxi(cycle - LINK_LEAD_TICKS, 0) if index > 0 else 0, TAP_TICKS))
		cycle += attack.total_ticks
	var combo_cycle: int = cycle
	var light: AttackTicks = CombatCatalog.attack(weapon.light_ids[0])
	var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
	var scripts: Array[Dictionary] = [
		{"name": "combo de 3 ligeros", "key": "combo", "cycle": combo_cycle, "presses": combo_presses},
		{"name": "ligero 1 repetido", "key": "light_spam", "cycle": light.total_ticks,
				"presses": [Vector2i(0, TAP_TICKS)]},
		{"name": "fuerte, carga mínima", "key": "heavy_min", "heavy": true,
				"cycle": heavy.charge_min_ticks + heavy.windup_ticks + heavy.active_ticks + heavy.recovery_ticks,
				"presses": [Vector2i(0, heavy.charge_min_ticks)]},
		{"name": "fuerte, carga máxima", "key": "heavy_max", "heavy": true,
				"cycle": heavy.charge_max_ticks + heavy.windup_ticks + heavy.active_ticks + heavy.recovery_ticks,
				"presses": [Vector2i(0, heavy.charge_max_ticks)]},
	]
	var results: Dictionary = {}
	print("\nDPS contra el maniquí (%d s, ciclos completos; medido / calculado con los datos):" % _seconds)
	for entry: Dictionary in scripts:
		var measured: Dictionary = await _dps_of(entry)
		results[entry["key"]] = measured
		print("  %-22s %6.1f DPS medido, %6.1f calculado  (%d golpes, %d de daño en %d ciclos de %d ticks)" % [
			entry["name"], measured["dps"], measured["expected_dps"], measured["hits"], measured["damage"],
			measured["cycles"], entry["cycle"]])
	return results


# Un guion de ataque repetido contra el maniquí durante _seconds segundos (ciclos enteros).
func _dps_of(entry: Dictionary) -> Dictionary:
	await _start_server()
	var cycle: int = entry["cycle"]
	var cycles: int = maxi(int(float(_seconds * 60) / float(cycle)), 1)
	var presses: Array = entry["presses"]
	var heavy: bool = entry.get("heavy", false)
	var brain := ScriptedBrain.new(1)
	brain.script_fn = func(relative: int, _position: Vector3) -> PlayerInput:
		var input := PlayerInput.new()
		input.look_yaw = 0.0
		var phase: int = relative % cycle if relative >= 0 else -1
		for press: Vector2i in presses:
			if phase >= press.x and phase < press.x + press.y:
				input.buttons = PlayerInput.PRIMARY
		return input
	var attacker: int = _server.add_fake_player(brain, VARDHEIM)
	var dummy: int = _server.spawn_dummy(TARGET_POSITION, PI)
	_server.teleport(attacker, ATTACKER_HOME)
	_step(4)
	# El guion empieza en un tick futuro; antes de cada ciclo se devuelve al atacante a su sitio (los
	# ataques avanzan). Se mide desde ese tick, en ciclos enteros.
	var start: int = _server.get_tick() + 8
	brain.start_tick = start
	var end: int = start + cycles * cycle
	_events.clear()
	while _server.get_tick() < end + cycle:
		var next_tick: int = _server.get_tick() + 1
		if next_tick >= start - 1 and (next_tick - (start - 1)) % cycle == 0:
			# Los ataques avanzan al atacante y el empuje del fuerte aleja al maniquí: se devuelve a los dos.
			_server.teleport(attacker, ATTACKER_HOME)
			_server.teleport(dummy, TARGET_POSITION)
		_step(1)
	var damage: int = 0
	var hits: int = 0
	for event: NetMessages.EntityEvent in _events:
		if event.event == NetMessages.EntityEvent.Kind.HIT and event.attacker == attacker \
				and event.net_id == dummy and event.tick >= start and event.tick < end + 1:
			damage += event.amount
			hits += 1

	var seconds: float = float(cycles * cycle) / 60.0
	var expected_damage: int = 0
	if heavy:
		var attack: AttackTicks = CombatCatalog.attack(CombatCatalog.weapon(
				CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON)).heavy_id)
		var held: int = (presses[0] as Vector2i).y
		var fraction: float = clampf(float(held - attack.charge_min_ticks)
				/ float(maxi(attack.charge_max_ticks - attack.charge_min_ticks, 1)), 0.0, 1.0)
		expected_damage = roundi(float(attack.base_damage) * lerpf(1.0, attack.charge_damage_scale, fraction))
	else:
		var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
		if presses.size() == 1:
			expected_damage = CombatCatalog.attack(weapon.light_ids[0]).base_damage
		else:
			for light_id: int in weapon.light_ids:
				expected_damage += CombatCatalog.attack(light_id).base_damage
	await _stop_server()
	return {
		"cycles": cycles, "cycle_ticks": cycle, "hits": hits, "damage": damage, "seconds": seconds,
		"dps": float(damage) / seconds,
		"expected_dps": float(expected_damage) / (float(cycle) / 60.0),
	}


# --- TTK ideal --------------------------------------------------------------------------------

# Tiempo del primer golpe a la muerte de un atacante perfecto (combo encadenado) contra una víctima
# quieta y contra una que bloquea sin parar (hasta la rotura de guardia).
func _measure_ideal_ttk() -> Dictionary:
	print("\nTTK ideal (combo encadenado, del primer golpe a la muerte):")
	var results: Dictionary = {}
	for mode: String in ["quieta", "bloqueando"]:
		var measured: Dictionary = await _ideal_ttk_against(mode)
		results[mode] = measured
		print("  contra una víctima %-11s %6.2f s hasta la muerte (%d golpes%s)" % [
			mode, measured["ttk_s"], measured["hits"],
			", rotura de guardia a los %.2f s" % measured["guard_break_s"] if measured["guard_break_s"] >= 0.0 else ""])
	return results


func _ideal_ttk_against(mode: String) -> Dictionary:
	await _start_server()
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var presses: Array[int] = [0]
	var cycle: int = 0
	for index: int in weapon.light_ids.size():
		cycle += CombatCatalog.attack(weapon.light_ids[index]).total_ticks
		if index < weapon.light_ids.size() - 1:
			presses.append(cycle - LINK_LEAD_TICKS)
	var attacker_brain := ScriptedBrain.new(1)
	attacker_brain.script_fn = func(relative: int, _position: Vector3) -> PlayerInput:
		var input := PlayerInput.new()
		input.look_yaw = 0.0
		var phase: int = relative % cycle if relative >= 0 else -1
		for press: int in presses:
			if phase >= press and phase < press + TAP_TICKS:
				input.buttons = PlayerInput.PRIMARY
		return input
	var victim_brain := ScriptedBrain.new(2)
	victim_brain.script_fn = func(_relative: int, _position: Vector3) -> PlayerInput:
		var input := PlayerInput.new()
		input.look_yaw = PI
		if mode == "bloqueando":
			input.buttons = PlayerInput.BLOCK
		return input
	var attacker: int = _server.add_fake_player(attacker_brain, VARDHEIM)
	var victim: int = _server.add_fake_player(victim_brain, SOLMARCH)
	_server.teleport(attacker, ATTACKER_HOME)
	_server.teleport(victim, TARGET_POSITION)
	_server.get_registry().get_entity(victim).get_character().yaw = PI
	_step(4)
	var start: int = _server.get_tick() + 8
	attacker_brain.start_tick = start
	victim_brain.start_tick = start
	_events.clear()
	var first_hit: int = -1
	var death_tick: int = -1
	var guard_break_tick: int = -1
	var limit: int = start + 60 * 60
	while _server.get_tick() < limit and death_tick < 0:
		var next_tick: int = _server.get_tick() + 1
		if next_tick >= start - 1 and (next_tick - (start - 1)) % cycle == 0:
			_server.teleport(attacker, ATTACKER_HOME)
		_step(1)
		for event: NetMessages.EntityEvent in _events:
			if event.event == NetMessages.EntityEvent.Kind.HIT and event.net_id == victim:
				if first_hit < 0:
					first_hit = event.tick
				if (event.hit_flags & NetMessages.EntityEvent.HIT_FLAG_GUARD_BREAK) != 0 and guard_break_tick < 0:
					guard_break_tick = event.tick
			elif event.event == NetMessages.EntityEvent.Kind.DEATH and event.net_id == victim:
				death_tick = event.tick
		_events.clear()
		if _server.get_combat().get_combatant(victim).is_dead() and death_tick < 0:
			death_tick = _server.get_tick()
	var combatant: Combatant = _server.get_combat().get_combatant(victim)
	var result: Dictionary = {
		"ttk_s": float(death_tick - first_hit) / 60.0 if death_tick >= 0 and first_hit >= 0 else -1.0,
		"hits": int(_server.get_combat().stats[&"hits"]),
		"blocked": int(_server.get_combat().stats[&"blocked"]),
		"guard_break_s": float(guard_break_tick - first_hit) / 60.0 if guard_break_tick >= 0 else -1.0,
		"victim_health": combatant.health,
	}
	await _stop_server()
	return result


# --- Duelos de bots de combate -----------------------------------------------------------------

func _measure_duels() -> Dictionary:
	print("\nDuelos de bots de combate, espada contra espada, de %.0f m (%d duelos):" % [DUEL_DISTANCE, _duels])
	var ttks: Array[float] = []
	var wins: Array[int] = [0, 0]
	var draws: int = 0
	var hits: int = 0
	var blocked: int = 0
	var parried: int = 0
	var guard_breaks: int = 0
	var invulnerable: int = 0
	var damage: int = 0
	var dps_values: Array[float] = []
	var seconds_total: float = 0.0
	for index: int in _duels:
		var duel: Dictionary = await _duel(DUEL_SEED_BASE + 2 * index)
		hits += int(duel["hits"])
		blocked += int(duel["blocked"])
		parried += int(duel["parried"])
		guard_breaks += int(duel["guard_breaks"])
		invulnerable += int(duel["invulnerable"])
		damage += int(duel["damage"])
		seconds_total += float(duel["fight_s"])
		if int(duel["winner"]) < 0:
			draws += 1
		else:
			wins[int(duel["winner"])] += 1
			ttks.append(float(duel["ttk_s"]))
			dps_values.append(float(duel["winner_damage"]) / maxf(float(duel["ttk_s"]), 0.001))
	ttks.sort()
	dps_values.sort()
	var summary: Dictionary = {
		"duels": _duels, "decided": ttks.size(), "draws": draws, "wins_first": wins[0], "wins_second": wins[1],
		"ttk_min_s": ttks[0] if not ttks.is_empty() else -1.0,
		"ttk_p10_s": _percentile(ttks, 0.1), "ttk_median_s": _percentile(ttks, 0.5),
		"ttk_mean_s": _mean(ttks), "ttk_p90_s": _percentile(ttks, 0.9),
		"ttk_max_s": ttks[ttks.size() - 1] if not ttks.is_empty() else -1.0,
		"winner_dps_median": _percentile(dps_values, 0.5),
		"hits_per_duel": float(hits) / float(maxi(_duels, 1)),
		"blocked_per_duel": float(blocked) / float(maxi(_duels, 1)),
		"parried_per_duel": float(parried) / float(maxi(_duels, 1)),
		"guard_breaks_per_duel": float(guard_breaks) / float(maxi(_duels, 1)),
		"invulnerable_per_duel": float(invulnerable) / float(maxi(_duels, 1)),
		"damage_per_duel": float(damage) / float(maxi(_duels, 1)),
		"seconds_per_duel": seconds_total / float(maxi(_duels, 1)),
	}
	print("  decididos %d (empates por tiempo %d); gana el primero %d veces y el segundo %d" % [
		summary["decided"], draws, wins[0], wins[1]])
	print("  TTK del primer golpe a la muerte: mín %.1f s, p10 %.1f s, mediana %.1f s, media %.1f s, p90 %.1f s, máx %.1f s" % [
		summary["ttk_min_s"], summary["ttk_p10_s"], summary["ttk_median_s"], summary["ttk_mean_s"],
		summary["ttk_p90_s"], summary["ttk_max_s"]])
	print("  por duelo: %.1f golpes que hacen daño (%.0f de daño), %.1f bloqueados, %.1f paradas, %.1f roturas de guardia, %.1f esquivados" % [
		summary["hits_per_duel"], summary["damage_per_duel"], summary["blocked_per_duel"],
		summary["parried_per_duel"], summary["guard_breaks_per_duel"], summary["invulnerable_per_duel"]])
	print("  DPS mediano del ganador (daño que hace entre el primer golpe y la muerte): %.1f" % summary["winner_dps_median"])
	return summary


# Un duelo entre dos bots de combate con las semillas [param seed_first] y [param seed_first] + 1.
func _duel(seed_first: int) -> Dictionary:
	await _start_server()
	var first: int = _server.add_fake_player(BotBrain.new(seed_first, BotBrain.Pattern.COMBAT,
			Vector3.ZERO, 30.0), VARDHEIM)
	var second: int = _server.add_fake_player(BotBrain.new(seed_first + 1, BotBrain.Pattern.COMBAT,
			Vector3.ZERO, 30.0), SOLMARCH)
	_server.teleport(first, Vector3(-DUEL_DISTANCE / 2.0, 0.1, 0.0))
	_server.teleport(second, Vector3(DUEL_DISTANCE / 2.0, 0.1, 0.0))
	_server.get_registry().get_entity(first).get_character().yaw = -PI / 2.0
	_server.get_registry().get_entity(second).get_character().yaw = PI / 2.0
	_events.clear()
	var ids: Array[int] = [first, second]
	var first_hit: int = -1
	var death_tick: int = -1
	var winner: int = -1
	var damage_by: Array[int] = [0, 0]
	var start: int = _server.get_tick()
	var limit: int = start + int(DUEL_TIMEOUT_SECONDS * 60.0)
	while _server.get_tick() < limit and winner < 0:
		_step(1)
		for event: NetMessages.EntityEvent in _events:
			if event.event == NetMessages.EntityEvent.Kind.HIT and event.amount > 0:
				var side: int = ids.find(event.attacker)
				if side >= 0:
					damage_by[side] += event.amount
					if first_hit < 0:
						first_hit = event.tick
			elif event.event == NetMessages.EntityEvent.Kind.DEATH:
				var dead: int = ids.find(event.net_id)
				if dead >= 0 and winner < 0:
					winner = 1 - dead
					death_tick = event.tick
		_events.clear()
	var stats: Dictionary = _server.get_combat().stats
	var result: Dictionary = {
		"winner": winner,
		"ttk_s": float(death_tick - first_hit) / 60.0 if winner >= 0 and first_hit >= 0 else -1.0,
		"fight_s": float(_server.get_tick() - start) / 60.0,
		"hits": int(stats[&"hits"]) - int(stats[&"blocked"]),
		"blocked": int(stats[&"blocked"]),
		"parried": int(stats[&"parried"]),
		"guard_breaks": int(stats[&"guard_breaks"]),
		"invulnerable": int(stats[&"invulnerable"]),
		"damage": damage_by[0] + damage_by[1],
		"winner_damage": damage_by[maxi(winner, 0)],
	}
	await _stop_server()
	return result


# --- Equipos ----------------------------------------------------------------------------------

# 2 contra 2 y 5 contra 5 de bots de combate.
func _measure_teams() -> Dictionary:
	var results: Dictionary = {}
	var runs: int = maxi(_duels / 3, 5)
	print("\nEquipos de bots de combate, de %.0f m (%d combates de cada tamaño):" % [DUEL_DISTANCE, runs])
	for size: int in [2, 5]:
		var first_kills: Array[float] = []
		var ends: Array[float] = []
		var kills_per_fight: float = 0.0
		var unfinished: int = 0
		for index: int in runs:
			var fight: Dictionary = await _team_fight(size, DUEL_SEED_BASE + 1000 + 20 * index)
			if float(fight["first_kill_s"]) >= 0.0:
				first_kills.append(float(fight["first_kill_s"]))
			if float(fight["end_s"]) >= 0.0:
				ends.append(float(fight["end_s"]))
			else:
				unfinished += 1
			kills_per_fight += float(fight["deaths"])
		first_kills.sort()
		ends.sort()
		var summary: Dictionary = {
			"size": size, "fights": runs, "unfinished": unfinished,
			"first_kill_median_s": _percentile(first_kills, 0.5),
			"first_kill_p10_s": _percentile(first_kills, 0.1), "first_kill_p90_s": _percentile(first_kills, 0.9),
			"end_median_s": _percentile(ends, 0.5), "end_p10_s": _percentile(ends, 0.1),
			"end_p90_s": _percentile(ends, 0.9), "deaths_per_fight": kills_per_fight / float(runs),
		}
		results["%dv%d" % [size, size]] = summary
		print("  %d contra %d: primera baja a los %.1f s (p10 %.1f, p90 %.1f); un bando sin nadie en pie a los %.1f s (p10 %.1f, p90 %.1f; %d de %d sin acabar en %d s); %.1f bajas por combate" % [
			size, size, summary["first_kill_median_s"], summary["first_kill_p10_s"], summary["first_kill_p90_s"],
			summary["end_median_s"], summary["end_p10_s"], summary["end_p90_s"], unfinished, runs,
			TEAM_TIMEOUT_SECONDS, summary["deaths_per_fight"]])
	return results


# Un combate de [param size] contra [param size]: Vardheim a un lado y Solmarch al otro, en fila.
func _team_fight(size: int, seed_first: int) -> Dictionary:
	await _start_server()
	var teams: Array[Array] = [[], []]
	for side: int in 2:
		for member: int in size:
			var realm: int = VARDHEIM if side == 0 else SOLMARCH
			var net_id: int = _server.add_fake_player(BotBrain.new(seed_first + 2 * member + side,
					BotBrain.Pattern.COMBAT, Vector3.ZERO, 30.0), realm)
			var z: float = (float(member) - float(size - 1) / 2.0) * 1.5
			var x: float = -DUEL_DISTANCE / 2.0 if side == 0 else DUEL_DISTANCE / 2.0
			_server.teleport(net_id, Vector3(x, 0.1, z))
			_server.get_registry().get_entity(net_id).get_character().yaw = \
					-PI / 2.0 if side == 0 else PI / 2.0
			teams[side].append(net_id)
	_events.clear()
	var alive: Array[int] = [size, size]
	var start: int = _server.get_tick()
	var first_kill: int = -1
	var first_hit: int = -1
	var end_tick: int = -1
	var deaths: int = 0
	var limit: int = start + int(TEAM_TIMEOUT_SECONDS * 60.0)
	while _server.get_tick() < limit and end_tick < 0:
		_step(1)
		for event: NetMessages.EntityEvent in _events:
			if event.event == NetMessages.EntityEvent.Kind.HIT and event.amount > 0 and first_hit < 0:
				first_hit = event.tick
			elif event.event == NetMessages.EntityEvent.Kind.DEATH:
				for side: int in 2:
					if teams[side].has(event.net_id):
						alive[side] -= 1
						deaths += 1
						if first_kill < 0:
							first_kill = event.tick
						if alive[side] <= 0 and end_tick < 0:
							end_tick = event.tick
			elif event.event == NetMessages.EntityEvent.Kind.RESPAWN:
				for side: int in 2:
					if teams[side].has(event.net_id):
						alive[side] += 1
		_events.clear()
	var result: Dictionary = {
		"first_kill_s": float(first_kill - first_hit) / 60.0 if first_kill >= 0 and first_hit >= 0 else -1.0,
		"end_s": float(end_tick - first_hit) / 60.0 if end_tick >= 0 and first_hit >= 0 else -1.0,
		"deaths": deaths,
	}
	await _stop_server()
	return result


# --- Servidor ---------------------------------------------------------------------------------

# Un servidor sin red sobre test_world (sin lo visual, como el dedicado).
func _start_server() -> void:
	var packed: PackedScene = load(NetZones.scene_path(ZONE_ID)) as PackedScene
	_world = packed.instantiate() as Node3D
	root.add_child(_world)
	var zone_root: ZoneRoot = _world as ZoneRoot
	if zone_root != null:
		zone_root.strip_for_server()
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	root.add_child(_server)
	for _i: int in 3:
		await physics_frame
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.max_players = 16
	config.no_dummies = true
	var error: Error = _server.start(config, _world, null, DevAuthProvider.new())
	if error != OK:
		push_error("No se pudo arrancar el servidor (%s)" % error_string(error))
		quit(1)
		return
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: _events.append(event))
	# A partir de aquí el servidor se avanza a mano.
	_server.set_physics_process(false)
	_events.clear()


func _stop_server() -> void:
	if is_instance_valid(_server):
		_server.stop()
		root.remove_child(_server)
		_server.free()
	if is_instance_valid(_world):
		root.remove_child(_world)
		_world.free()
	_server = null
	_world = null
	await process_frame


# Avanza el servidor [param count] ticks de 1/60 s, uno detrás de otro y sin esperar al motor.
func _step(count: int) -> void:
	for _i: int in count:
		_server._physics_process(1.0 / 60.0)


# --- Ayudas -----------------------------------------------------------------------------------

func _percentile(sorted_values: Array[float], fraction: float) -> float:
	if sorted_values.is_empty():
		return -1.0
	var rank: int = clampi(ceili(fraction * float(sorted_values.size())) - 1, 0, sorted_values.size() - 1)
	return sorted_values[rank]


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return -1.0
	var total: float = 0.0
	for value: float in values:
		total += value
	return total / float(values.size())


func _option(args: PackedStringArray, prefix: String, fallback: String) -> String:
	for arg: String in args:
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix).strip_edges()
	return fallback


func _int_option(args: PackedStringArray, prefix: String, fallback: int) -> int:
	var text: String = _option(args, prefix, "")
	return text.to_int() if text.is_valid_int() else fallback
