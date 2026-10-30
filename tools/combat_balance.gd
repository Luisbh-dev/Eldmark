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
## segundos de medida del DPS contra el maniquí (por defecto 30), [code]--team-runs=N[/code] combates de cada
## tamaño de equipo (por defecto el mayor de N/3 y 5), [code]--reference[/code] (también los duelos sin habilidades),
## [code]--no-template-duels[/code] (sin los duelos con el tirador; la prueba en pequeño los salta por tiempo) y
## [code]--out=<ruta.json>[/code] (por defecto [code]build/combat_balance.json[/code]).
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
## 4 m hasta que uno cae: tiempo del primer golpe a la caída, quién gana, golpes, bloqueos y esquivas.
## [br]- [b]Equipos[/b]: 2 contra 2 y 5 contra 5 de bots de combate, hasta que un bando se queda sin nadie
## en pie (o pasan 60 s, con reapariciones de 10 s de por medio): tiempo hasta la primera baja y hasta
## el fin, y bajas por bando.
## [br][br]
## Entre jugadores de reinos enemigos el golpe mortal derriba (docs/habilidades.md, sección 4.5): la «muerte» de
## estas medidas es la caída, DOWNED o DEATH (lo que llegue antes), que es cuando el caído deja de pelear.
## [br][br]
## [b]Kits de la fase 4[/b] (H5; docs/habilidades.md, sección 2.4, y combate.md, sección 12.8):
## [br]- [b]Arco contra el maniquí[/b] a 10 m: disparo rápido repetido y tensado con la carga mínima y la máxima,
## apuntado como un bot ([method BotBrain.lead_look]); el DPS medido frente al calculado con los datos.
## [br]- [b]Alcances[/b]: el rápido y el tensado máximo contra el maniquí a 10, 30 y 50 m: aciertos, tiempo de vuelo
## (del compromiso al impacto) y cuánto hay que apuntar por encima del blanco.
## [br]- [b]Habilidades[/b]: un uso de cada una contra el maniquí (el abanico a 3 y a 10 m): daño, aciertos y DPS
## a reutilización.
## [br]- [b]Muro de escudos[/b]: uno y dos atacantes con el combo perfecto contra quien lo mantiene los 6 s:
## resistencia que le quitan y si le rompen la guardia.
## [br]- Los duelos y los equipos de bots de combate usan el kit ([BotBrain] con su estado de combate): espada contra
## espada (escuderos), y además, con las dos plantillas, tirador contra tirador, escudero contra tirador y 2 contra 2
## con un escudero y un tirador en cada bando; con [code]--reference[/code], también los duelos sin habilidades (el
## cerebro de la fase 3) para comparar.

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
## Distancia (m) del arquero al maniquí en la medida del DPS del arco.
const BOW_DPS_DISTANCE: float = 10.0
## Distancias (m) de la medida de alcances y disparos por distancia y tipo.
const BOW_RANGES: Array[float] = [10.0, 30.0, 50.0]
const RANGE_SHOTS: int = 5
## Distancia (m) entre quien mantiene el muro y sus atacantes.
const WALL_DISTANCE: float = 2.2
## Distancia (m) de partida de los duelos con un tirador.
const TEMPLATE_DUEL_DISTANCE: float = 20.0

var _duels: int = 40
var _seconds: int = 30
var _out_path: String = ""
var _reference: bool = false
var _template_duels: bool = true
var _team_runs: int = 5
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
	_reference = args.has("--reference")
	_template_duels = not args.has("--no-template-duels")
	_team_runs = _int_option(args, "--team-runs=", maxi(_duels / 3, 5))
	if _out_path.is_empty():
		_out_path = ProjectSettings.globalize_path("res://build/combat_balance.json")
	var result: Dictionary = {}
	print("Eldmark · pasada de equilibrio (CMB-29; kits de la fase 4, H5): %d duelos, %d s de DPS" % [_duels,
			_seconds])
	result["data"] = _data_table()
	result["kit_data"] = _kit_data_table()
	print("")
	result["dps"] = await _measure_dps()
	result["bow"] = await _measure_bow_dps()
	result["ranges"] = await _measure_ranges()
	result["abilities"] = await _measure_abilities()
	result["wall"] = await _measure_wall()
	result["ideal"] = await _measure_ideal_ttk()
	result["duels"] = await _measure_duels()
	if _template_duels:
		result["template_duels"] = await _measure_template_duels()
	if _reference:
		result["duels_reference"] = await _measure_duels(false)
		result["duels_no_potions"] = await _measure_duels(true, [0, 0], "espada contra espada sin pociones",
				DUEL_DISTANCE, false)
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
	# Tick (relativo al inicio del ciclo) en que cae cada golpe según los datos: lo que duran los ataques
	# anteriores más la anticipación del suyo.
	var combo_hits: Array[int] = []
	var cycle: int = 0
	for index: int in weapon.light_ids.size():
		var attack: AttackTicks = CombatCatalog.attack(weapon.light_ids[index])
		combo_presses.append(Vector2i(maxi(cycle - LINK_LEAD_TICKS, 0) if index > 0 else 0, TAP_TICKS))
		combo_hits.append(cycle + attack.windup_ticks)
		cycle += attack.total_ticks
	var combo_cycle: int = cycle
	var light: AttackTicks = CombatCatalog.attack(weapon.light_ids[0])
	var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
	var scripts: Array[Dictionary] = [
		{"name": "combo de 3 ligeros", "key": "combo", "cycle": combo_cycle, "presses": combo_presses,
				"hits": combo_hits},
		{"name": "ligero 1 repetido", "key": "light_spam", "cycle": light.total_ticks,
				"presses": [Vector2i(0, TAP_TICKS)], "hits": [light.windup_ticks]},
		{"name": "fuerte, carga mínima", "key": "heavy_min", "heavy": true,
				"cycle": heavy.charge_min_ticks + heavy.windup_ticks + heavy.active_ticks + heavy.recovery_ticks,
				"presses": [Vector2i(0, heavy.charge_min_ticks)],
				"hits": [heavy.charge_min_ticks + heavy.windup_ticks]},
		{"name": "fuerte, carga máxima", "key": "heavy_max", "heavy": true,
				"cycle": heavy.charge_max_ticks + heavy.windup_ticks + heavy.active_ticks + heavy.recovery_ticks,
				"presses": [Vector2i(0, heavy.charge_max_ticks)],
				"hits": [heavy.charge_max_ticks + heavy.windup_ticks]},
	]
	var results: Dictionary = {}
	print("\nDPS contra el maniquí (%d s, ciclos completos; medido / calculado con los datos):" % _seconds)
	for entry: Dictionary in scripts:
		var measured: Dictionary = await _dps_of(entry)
		results[entry["key"]] = measured
		print("  %-22s %6.1f DPS medido, %6.1f calculado  (%d golpes, %d de daño en %d ciclos de %d ticks)" % [
			entry["name"], measured["dps"], measured["expected_dps"], measured["hits"], measured["damage"],
			measured["cycles"], entry["cycle"]])
		if measured["hit_ticks"] != measured["expected_hit_ticks"]:
			print("    ATENCION: los golpes caen en los ticks %s y los datos dicen %s" % [
				measured["hit_ticks"], measured["expected_hit_ticks"]])
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
	# Tick de cada golpe (relativo al inicio del guion) y el que le tocaba según los datos: con ellos se
	# comprueba que el enlace no pierde ticks. Dividir el daño entre los segundos de ciclos enteros da
	# siempre el DPS calculado, aunque cada ataque durase un tick más de lo que dicen los datos.
	var hit_ticks: Array[int] = []
	for event: NetMessages.EntityEvent in _events:
		if event.event == NetMessages.EntityEvent.Kind.HIT and event.attacker == attacker \
				and event.net_id == dummy and event.tick >= start and event.tick < end + 1:
			damage += event.amount
			hits += 1
			hit_ticks.append(event.tick - start)
	var expected_hit_ticks: Array[int] = []
	for cycle_index: int in cycles:
		for offset: int in entry["hits"]:
			expected_hit_ticks.append(cycle_index * cycle + offset)

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
		"hit_ticks": hit_ticks, "expected_hit_ticks": expected_hit_ticks,
		"dps": float(damage) / seconds,
		"expected_dps": float(expected_damage) / (float(cycle) / 60.0),
	}


# --- Kits de la fase 4: lo que dicen los datos (docs/habilidades.md, sección 2.4) ---------------

# El arco, las habilidades y las pociones según el catálogo, con los DPS calculados de la hoja de §2.4.
func _kit_data_table() -> Dictionary:
	var table: Dictionary = {}
	var bow: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(&"bow"))
	var quick: AttackTicks = CombatCatalog.attack(bow.light_ids[0])
	var drawn: AttackTicks = CombatCatalog.attack(bow.heavy_id)
	var arrow: ProjectileTicks = CombatCatalog.projectile(quick.projectile_id)
	var drawn_max_damage: int = roundi(float(drawn.base_damage) * drawn.charge_damage_scale)
	table["quick"] = _cycle_row(quick.total_ticks, quick.base_damage)
	table["drawn_min"] = _cycle_row(drawn.charge_min_ticks + drawn.total_ticks, drawn.base_damage)
	table["drawn_max"] = _cycle_row(drawn.charge_max_ticks + drawn.total_ticks, drawn_max_damage)
	print("\nKits de la fase 4 (data/combat/; docs/habilidades.md, sección 2.4):")
	print("  arco: rápido %d ticks y %d de daño -> %.1f DPS; tensado mínimo %d ticks y %d -> %.1f; máximo %d ticks y %d -> %.1f" % [
		table["quick"]["ticks"], quick.base_damage, table["quick"]["dps"], table["drawn_min"]["ticks"],
		drawn.base_damage, table["drawn_min"]["dps"], table["drawn_max"]["ticks"], drawn_max_damage,
		table["drawn_max"]["dps"]])
	var abilities: Dictionary = {}
	for weapon_name: StringName in [&"sword_shield", &"bow"]:
		var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(weapon_name))
		for slot: int in CombatState.ABILITY_SLOTS:
			var ability: AbilityTicks = CombatCatalog.ability(weapon.ability_id(slot))
			if ability == null:
				continue
			var damage: int = ability.hit.base_damage * (ability.projectile_count if ability.projectile_id != 0 else 1) \
					if ability.hit != null else 0
			var cooldown_s: float = float(ability.cooldown_ticks) / 60.0
			abilities[String(ability.name)] = {"weapon": String(weapon_name), "slot": slot + 1,
					"ticks": ability.total_ticks, "cooldown_s": cooldown_s, "damage": damage,
					"dps_at_cooldown": float(damage) / cooldown_s if cooldown_s > 0.0 else 0.0}
			print("  %-18s ranura %d de %-12s %3d ticks, reutilización %4.1f s, daño %3d -> +%.1f DPS a reutilización" % [
				ability.name, slot + 1, weapon_name, ability.total_ticks, cooldown_s, damage,
				abilities[String(ability.name)]["dps_at_cooldown"]])
	table["abilities"] = abilities
	var regen: StatusTicks = CombatCatalog.status(CombatCatalog.status_id(&"potion_regen"))
	var potion_heal: int = regen.pulse_amount * (regen.duration_ticks / maxi(regen.pulse_ticks, 1))
	var potion_cooldown_s: float = float(CombatCatalog.tables().consumable_cooldown_ticks) / 60.0
	table["potion"] = {"heal": potion_heal, "cooldown_s": potion_cooldown_s,
			"heal_per_s": float(potion_heal) / potion_cooldown_s}
	print("  poción de vida: +%d cada %.0f s (%.1f de vida por segundo sostenido)" % [potion_heal, potion_cooldown_s,
			table["potion"]["heal_per_s"]])
	var rules: CombatRules = CombatCatalog.rules()
	var combo_dps: float = float(_data_combo_damage()) / (float(_data_combo_ticks()) / 60.0)
	var wall: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_wall"))
	var wall_s: float = float(wall.active_ticks) / 60.0
	table["wall"] = {"seconds": wall_s, "stamina_per_damage": rules.ability_block_stamina_per_damage,
			"one_attacker_stamina": combo_dps * wall_s * rules.ability_block_stamina_per_damage,
			"two_attackers_break_s": float(rules.stamina_max) / (2.0 * combo_dps * rules.ability_block_stamina_per_damage)}
	print("  muro: %.0f s a %.1f de resistencia por punto: un atacante (combo, %.1f DPS) le quita %.0f; dos lo rompen a los %.1f s" % [
		wall_s, rules.ability_block_stamina_per_damage, combo_dps, table["wall"]["one_attacker_stamina"],
		table["wall"]["two_attackers_break_s"]])
	var flights: Dictionary = {}
	for distance: float in BOW_RANGES:
		var row: Dictionary = {}
		for key: String in ["quick", "drawn_max"]:
			var speed: float = quick.projectile_speed_mps if key == "quick" \
					else drawn.projectile_speed_mps * drawn.charge_speed_scale
			var lead: Dictionary = _flat_shot(distance, speed, arrow.gravity)
			row[key] = lead
		flights["%d" % int(distance)] = row
		print("  a %2.0f m: rápido %.2f s de vuelo y %.2f m de caída; tensado máximo %.2f s y %.2f m" % [distance,
			row["quick"]["flight_s"], row["quick"]["drop_m"], row["drawn_max"]["flight_s"], row["drawn_max"]["drop_m"]])
	table["flights"] = flights
	return table


func _cycle_row(ticks: int, damage: int) -> Dictionary:
	return {"ticks": ticks, "damage": damage, "dps": float(damage) / (float(ticks) / 60.0)}


func _data_combo_damage() -> int:
	var damage: int = 0
	for light_id: int in CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON)).light_ids:
		damage += CombatCatalog.attack(light_id).base_damage
	return damage


func _data_combo_ticks() -> int:
	var ticks: int = 0
	for light_id: int in CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON)).light_ids:
		ticks += CombatCatalog.attack(light_id).total_ticks
	return ticks


# Un tiro sobre llano a [param distance] m (de la boca al centro de un blanco a la misma altura) a [param speed]
# m/s: tiempo de vuelo y caída que hay que compensar apuntando por encima ([method Ballistics.solve_lead]).
func _flat_shot(distance: float, speed: float, gravity: float) -> Dictionary:
	var origin := Vector3.ZERO
	var target := Vector3(0.0, 0.0, -distance)
	var direction: Vector3 = Ballistics.solve_lead(origin, target, Vector3.ZERO, speed, gravity)
	var flight: float = distance / (speed * Vector2(direction.x, direction.z).length())
	return {"flight_s": flight, "drop_m": 0.5 * gravity * flight * flight}


# --- Arco contra el maniquí -------------------------------------------------------------------

# DPS del disparo rápido repetido y del tensado con la carga mínima y la máxima contra el maniquí a
# BOW_DPS_DISTANCE m, apuntado como un bot.
func _measure_bow_dps() -> Dictionary:
	var bow: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(&"bow"))
	var quick: AttackTicks = CombatCatalog.attack(bow.light_ids[0])
	var drawn: AttackTicks = CombatCatalog.attack(bow.heavy_id)
	var entries: Array[Dictionary] = [
		{"name": "disparo rápido repetido", "key": "quick", "attack": quick, "hold": TAP_TICKS, "charge": 0,
				"cycle": quick.total_ticks, "commit": quick.windup_ticks, "damage": quick.base_damage},
		{"name": "tensado, carga mínima", "key": "drawn_min", "attack": drawn, "hold": drawn.charge_min_ticks,
				"charge": drawn.charge_min_ticks, "cycle": drawn.charge_min_ticks + drawn.total_ticks,
				"commit": drawn.charge_min_ticks + drawn.windup_ticks, "damage": drawn.base_damage},
		{"name": "tensado, carga máxima", "key": "drawn_max", "attack": drawn, "hold": drawn.charge_max_ticks,
				"charge": drawn.charge_max_ticks, "cycle": drawn.charge_max_ticks + drawn.total_ticks,
				"commit": drawn.charge_max_ticks + drawn.windup_ticks,
				"damage": roundi(float(drawn.base_damage) * drawn.charge_damage_scale)},
	]
	var results: Dictionary = {}
	print("\nArco contra el maniquí a %.0f m (%d s, ciclos completos; medido / calculado con los datos):" % [
		BOW_DPS_DISTANCE, _seconds])
	for entry: Dictionary in entries:
		var cycles: int = maxi(int(float(_seconds * 60) / float(entry["cycle"])), 1)
		var measured: Dictionary = await _shots_at(entry, BOW_DPS_DISTANCE, cycles)
		var seconds: float = float(cycles * int(entry["cycle"])) / 60.0
		measured["dps"] = float(measured["damage"]) / seconds
		measured["expected_dps"] = float(entry["damage"]) / (float(entry["cycle"]) / 60.0)
		results[entry["key"]] = measured
		print("  %-24s %6.1f DPS medido, %6.1f calculado  (%d flechas, %d aciertos, %d de daño en %d ciclos de %d ticks)" % [
			entry["name"], measured["dps"], measured["expected_dps"], measured["shots"], measured["hits"],
			measured["damage"], cycles, entry["cycle"]])
	return results


# El rápido y el tensado máximo contra el maniquí a 10, 30 y 50 m: aciertos, vuelo medido y caída.
func _measure_ranges() -> Dictionary:
	var bow: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(&"bow"))
	var quick: AttackTicks = CombatCatalog.attack(bow.light_ids[0])
	var drawn: AttackTicks = CombatCatalog.attack(bow.heavy_id)
	var results: Dictionary = {}
	print("\nAlcances contra el maniquí (%d flechas por distancia):" % RANGE_SHOTS)
	for distance: float in BOW_RANGES:
		var row: Dictionary = {}
		for entry: Dictionary in [
			{"key": "quick", "attack": quick, "hold": TAP_TICKS, "charge": 0, "cycle": quick.total_ticks,
					"commit": quick.windup_ticks, "damage": quick.base_damage},
			{"key": "drawn_max", "attack": drawn, "hold": drawn.charge_max_ticks, "charge": drawn.charge_max_ticks,
					"cycle": drawn.charge_max_ticks + drawn.total_ticks,
					"commit": drawn.charge_max_ticks + drawn.windup_ticks,
					"damage": roundi(float(drawn.base_damage) * drawn.charge_damage_scale)},
		]:
			row[entry["key"]] = await _shots_at(entry, distance, RANGE_SHOTS)
		results["%d" % int(distance)] = row
		print("  a %2.0f m: rápido %d de %d (vuelo %.2f s, apunta %.2f m por encima); tensado máximo %d de %d (vuelo %.2f s, %.2f m)" % [
			distance, row["quick"]["hits"], row["quick"]["shots"], row["quick"]["flight_s"], row["quick"]["aim_above_m"],
			row["drawn_max"]["hits"], row["drawn_max"]["shots"], row["drawn_max"]["flight_s"],
			row["drawn_max"]["aim_above_m"]])
	return results


# [param cycles] disparos de [param entry] contra el maniquí a [param distance] m, cada uno pulsando PRIMARY
# entry.hold ticks al empezar su ciclo y apuntando con el tiro adelantado (blanco quieto: solo la caída). Devuelve
# flechas, aciertos, daño, ticks de cada golpe y el vuelo medio (del compromiso al golpe).
func _shots_at(entry: Dictionary, distance: float, cycles: int) -> Dictionary:
	await _start_server()
	var dummy: int = _server.spawn_dummy(Vector3(0.0, 0.1, -distance), PI)
	var brain := ScriptedBrain.new(1)
	var attacker: int = _server.add_fake_player(brain, VARDHEIM, CombatCatalog.template_id(&"marksman"))
	_server.teleport(attacker, ATTACKER_HOME)
	_step(20)
	var feet: Vector3 = _server.get_registry().get_entity(attacker).get_position()
	var dummy_feet: Vector3 = _server.get_registry().get_entity(dummy).get_position()
	var attack: AttackTicks = entry["attack"]
	var launch: ProjectileLaunch = ProjectileLaunch.for_attack(attack, int(entry["charge"]))
	var gravity: float = CombatCatalog.projectile(attack.projectile_id).gravity
	var look: Vector2 = BotBrain.lead_look(feet, dummy_feet, Vector3.ZERO, launch.speed, gravity, false)
	var cycle: int = entry["cycle"]
	var hold: int = entry["hold"]
	brain.script_fn = func(relative: int, _position: Vector3) -> PlayerInput:
		var input := PlayerInput.new()
		input.look_yaw = look.x
		input.look_pitch = look.y
		if relative >= 0 and relative < cycles * cycle and relative % cycle < hold:
			input.buttons = PlayerInput.PRIMARY
		return input
	var start: int = _server.get_tick() + 8
	brain.start_tick = start
	_events.clear()
	# Tick de salida de cada flecha del arquero y tick del golpe de cada una (por su id).
	var spawn_ticks: Dictionary[int, int] = {}
	var arrow_hits: Dictionary[int, int] = {}
	_server.get_combat().projectiles.spawned.connect(func(spawn: NetMessages.EntitySpawn,
			_recipients: PackedInt32Array) -> void:
		if spawn.owner_id == attacker:
			spawn_ticks[spawn.net_id] = spawn.spawn_tick)
	_server.get_combat().projectiles.despawned.connect(func(projectile_id: int, tick: int, reason: int,
			_recipients: PackedInt32Array) -> void:
		if spawn_ticks.has(projectile_id) and reason == NetProtocol.DespawnReason.IMPACT:
			arrow_hits[projectile_id] = tick)
	var end: int = start + cycles * cycle
	while _server.get_tick() < end + 150:
		_step(1)
	var hit_ticks: Array[int] = []
	var damage: int = 0
	for event: NetMessages.EntityEvent in _events:
		if event.event == NetMessages.EntityEvent.Kind.HIT and event.attacker == attacker and event.net_id == dummy:
			damage += event.amount
			hit_ticks.append(event.tick - start)
	# Vuelo: del tick de salida al del impacto de cada flecha que dio en el maniquí.
	var flight_total: float = 0.0
	for projectile_id: int in arrow_hits:
		flight_total += float(arrow_hits[projectile_id] - spawn_ticks[projectile_id]) / 60.0
	var shots: int = spawn_ticks.size()
	# Cuánto por encima del centro del blanco pasa el rayo de la mira a su distancia (la caída compensada).
	var ray: Array = AimRay.canonical(feet, look.x, look.y, false)
	var center: Vector3 = dummy_feet + Vector3(0.0, AimRay.TARGET_CENTER_HEIGHT, 0.0)
	var depth: float = ((center - Vector3(ray[0])).dot(Vector3(ray[1])))
	var aimed: Vector3 = Vector3(ray[0]) + Vector3(ray[1]) * depth
	await _stop_server()
	return {"shots": shots, "hits": hit_ticks.size(), "damage": damage, "hit_ticks": hit_ticks,
			"flight_s": flight_total / float(maxi(arrow_hits.size(), 1)), "aim_above_m": aimed.y - center.y,
			"speed": launch.speed}


# --- Habilidades contra el maniquí ------------------------------------------------------------

# Un uso de cada habilidad de espada y escudo y de arco contra el maniquí (el abanico a 3 y a 10 m): daño y aciertos
# frente a los datos, y el DPS que suma a reutilización.
func _measure_abilities() -> Dictionary:
	var results: Dictionary = {}
	print("\nHabilidades contra el maniquí (un uso de cada una):")
	for entry: Array in [[&"shield_bash", 1.6], [&"shield_rush", 5.0], [&"shield_wall", 2.0],
			[&"bow_volley", 2.0], [&"bow_volley", 3.0], [&"bow_volley", 10.0], [&"bow_slowing_shot", 10.0],
			[&"bow_evasive_shot", 10.0]]:
		var ability: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(entry[0]))
		var measured: Dictionary = await _ability_use(ability, float(entry[1]))
		var key: String = "%s_%d" % [entry[0], int(entry[1])]
		results[key] = measured
		print("  %-17s a %4.1f m: %d golpes, %3d de daño (los datos: %3d)%s; +%.1f DPS a reutilización (%.0f s)" % [
			ability.name, entry[1], measured["hits"], measured["damage"], measured["expected_damage"],
			", aturde %d ticks" % measured["stun_ticks"] if int(measured["stun_ticks"]) > 0 else "",
			measured["dps_at_cooldown"], float(ability.cooldown_ticks) / 60.0])
	return results


# Un uso de [param ability] contra el maniquí a [param distance] m.
func _ability_use(ability: AbilityTicks, distance: float) -> Dictionary:
	await _start_server()
	var dummy: int = _server.spawn_dummy(Vector3(0.0, 0.1, -distance), PI)
	var brain := ScriptedBrain.new(1)
	var bow_ability: bool = ability.weapon_id == CombatCatalog.weapon_id(&"bow")
	var template: int = CombatCatalog.template_id(&"marksman") if bow_ability else 0
	var attacker: int = _server.add_fake_player(brain, VARDHEIM, template)
	_server.teleport(attacker, ATTACKER_HOME)
	_step(20)
	var feet: Vector3 = _server.get_registry().get_entity(attacker).get_position()
	var dummy_feet: Vector3 = _server.get_registry().get_entity(dummy).get_position()
	var look := Vector2.ZERO
	if ability.projectile_id != 0:
		look = BotBrain.lead_look(feet, dummy_feet, Vector3.ZERO, ability.projectile_speed_mps,
				CombatCatalog.projectile(ability.projectile_id).gravity, false)
	var button: int = [PlayerInput.ABILITY_1, PlayerInput.ABILITY_2, PlayerInput.ABILITY_3][ability.slot]
	var hold: int = ability.active_to() if ability.channel else TAP_TICKS
	brain.script_fn = func(relative: int, _position: Vector3) -> PlayerInput:
		var input := PlayerInput.new()
		input.look_yaw = look.x
		input.look_pitch = look.y
		if relative >= 0 and relative < hold:
			input.buttons = button
		return input
	var start: int = _server.get_tick() + 8
	brain.start_tick = start
	_events.clear()
	var stun_ticks: int = 0
	var dummy_character: PlayerCharacter = _server.get_registry().get_entity(dummy).get_character()
	while _server.get_tick() < start + ability.total_ticks + 150:
		_step(1)
		if dummy_character.combat.action == CombatState.Action.STUN:
			stun_ticks += 1
	var hits: int = 0
	var damage: int = 0
	for event: NetMessages.EntityEvent in _events:
		if event.event == NetMessages.EntityEvent.Kind.HIT and event.attacker == attacker and event.net_id == dummy:
			hits += 1
			damage += event.amount
	await _stop_server()
	var expected: int = ability.hit.base_damage * (ability.projectile_count if ability.projectile_id != 0 else 1) \
			if ability.hit != null and (ability.hit.shape != null or ability.projectile_id != 0) else 0
	return {"hits": hits, "damage": damage, "expected_damage": expected, "stun_ticks": stun_ticks,
			"dps_at_cooldown": float(damage) / (float(ability.cooldown_ticks) / 60.0)}


# --- Muro de escudos --------------------------------------------------------------------------

# Uno y dos atacantes con el combo perfecto contra quien mantiene el muro de escudos sus 6 s.
func _measure_wall() -> Dictionary:
	var results: Dictionary = {}
	print("\nMuro de escudos contra el combo perfecto (6 s de muro):")
	for attackers: int in [1, 2]:
		var measured: Dictionary = await _wall_against(attackers)
		results["%d" % attackers] = measured
		print("  %d contra 1: le quitan %d de resistencia en %.2f s de muro levantado, %d golpes bloqueados%s" % [attackers,
			measured["stamina_spent"], measured["wall_s"], measured["blocked"],
			"; rotura de guardia a los %.2f s" % measured["break_s"] if measured["broken"] else "; no lo rompen"])
	return results


func _wall_against(attackers: int) -> Dictionary:
	await _start_server()
	var wall: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_wall"))
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var presses: Array[int] = [0]
	var cycle: int = 0
	for index: int in weapon.light_ids.size():
		cycle += CombatCatalog.attack(weapon.light_ids[index]).total_ticks
		if index < weapon.light_ids.size() - 1:
			presses.append(cycle - LINK_LEAD_TICKS)
	var holder_brain := ScriptedBrain.new(9)
	holder_brain.script_fn = func(relative: int, _position: Vector3) -> PlayerInput:
		var input := PlayerInput.new()
		input.look_yaw = PI
		if relative >= 0 and relative < wall.active_to() + 10:
			input.buttons = PlayerInput.ABILITY_3
		return input
	var holder: int = _server.add_fake_player(holder_brain, SOLMARCH)
	var holder_position := Vector3(0.0, 0.1, -WALL_DISTANCE)
	_server.teleport(holder, holder_position)
	_server.get_registry().get_entity(holder).get_character().yaw = PI
	var ids: Array[int] = []
	var homes: Array[Vector3] = []
	var brains: Array[ScriptedBrain] = []
	for index: int in attackers:
		var brain := ScriptedBrain.new(10 + index)
		brain.script_fn = func(relative: int, _position: Vector3) -> PlayerInput:
			var input := PlayerInput.new()
			input.look_yaw = 0.0
			var phase: int = relative % cycle if relative >= 0 else -1
			for press: int in presses:
				if phase >= press and phase < press + TAP_TICKS:
					input.buttons = PlayerInput.PRIMARY
			return input
		var id: int = _server.add_fake_player(brain, VARDHEIM)
		var home := Vector3(0.0 if attackers == 1 else (-0.7 if index == 0 else 0.7), 0.1, 0.0)
		_server.teleport(id, home)
		ids.append(id)
		homes.append(home)
		brains.append(brain)
	_step(4)
	var start: int = _server.get_tick() + 8
	holder_brain.start_tick = start
	# Los atacantes empiezan cuando el muro ya bloquea (fin del lanzamiento).
	for brain: ScriptedBrain in brains:
		brain.start_tick = start + wall.cast_ticks
	var character: PlayerCharacter = _server.get_registry().get_entity(holder).get_character()
	var min_stamina: int = character.combat.stamina
	var wall_ticks: int = 0
	var break_tick: int = -1
	var blocked: int = 0
	_events.clear()
	while _server.get_tick() < start + wall.active_to() + 20:
		var next_tick: int = _server.get_tick() + 1
		var relative: int = next_tick - (start + wall.cast_ticks)
		if relative >= 0 and relative % cycle == 0:
			for index: int in ids.size():
				_server.teleport(ids[index], homes[index])
		_step(1)
		var combat: CombatState = character.combat
		if combat.action == CombatState.Action.ABILITY and combat.action_id == wall.id \
				and _server.get_tick() >= combat.action_tick + wall.cast_ticks:
			wall_ticks += 1
		min_stamina = mini(min_stamina, combat.stamina)
		for event: NetMessages.EntityEvent in _events:
			if event.event == NetMessages.EntityEvent.Kind.HIT and event.net_id == holder:
				if (event.hit_flags & NetMessages.EntityEvent.HIT_FLAG_BLOCKED) != 0:
					blocked += 1
				if (event.hit_flags & NetMessages.EntityEvent.HIT_FLAG_GUARD_BREAK) != 0 and break_tick < 0:
					break_tick = event.tick
		_events.clear()
	var max_stamina: int = CombatCatalog.rules().stamina_max
	await _stop_server()
	return {"attackers": attackers, "stamina_spent": max_stamina - min_stamina, "wall_s": float(wall_ticks) / 60.0,
			"blocked": blocked, "broken": break_tick >= 0,
			"break_s": float(break_tick - (start + wall.cast_ticks)) / 60.0 if break_tick >= 0 else -1.0}


# --- Duelos con las dos plantillas -------------------------------------------------------------

# Tirador contra tirador y escudero contra tirador, desde 20 m (el arco tiene sitio).
func _measure_template_duels() -> Dictionary:
	var marksman: int = CombatCatalog.template_id(&"marksman")
	return {
		"marksman_vs_marksman": await _measure_duels(true, [marksman, marksman], "tirador contra tirador",
				TEMPLATE_DUEL_DISTANCE),
		"squire_vs_marksman": await _measure_duels(true, [0, marksman], "escudero contra tirador",
				TEMPLATE_DUEL_DISTANCE),
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
			elif _is_fall(event) and event.net_id == victim and death_tick < 0:
				death_tick = event.tick
		_events.clear()
		var fallen: Combatant = _server.get_combat().get_combatant(victim)
		if (fallen.is_dead() or fallen.is_downed()) and death_tick < 0:
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

# Duelos de bots de combate: con el kit o sin él ([param kit]), con las plantillas [param templates] (0 = el
# escudero) y desde [param distance] metros.
func _measure_duels(kit: bool = true, templates: Array[int] = [0, 0], label: String = "espada contra espada",
		distance: float = DUEL_DISTANCE, potions: bool = true) -> Dictionary:
	print("\nDuelos de bots de combate, %s%s, de %.0f m (%d duelos):" % [label,
			" con el kit" if kit else ", sin habilidades (referencia de la fase 3)", distance, _duels])
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
		var duel: Dictionary = await _duel(DUEL_SEED_BASE + 2 * index, kit, templates, distance, potions)
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


# Un duelo entre dos bots de combate con las semillas [param seed_first] y [param seed_first] + 1, con el kit o
# sin él ([param kit]) y con las plantillas [param templates] (0 = la de por defecto, el escudero).
func _duel(seed_first: int, kit: bool = true, templates: Array[int] = [0, 0],
		distance: float = DUEL_DISTANCE, potions: bool = true) -> Dictionary:
	await _start_server()
	var brains: Array[BotBrain] = [BotBrain.new(seed_first, BotBrain.Pattern.COMBAT, Vector3.ZERO, 30.0),
			BotBrain.new(seed_first + 1, BotBrain.Pattern.COMBAT, Vector3.ZERO, 30.0)]
	for brain: BotBrain in brains:
		brain.use_kit = kit
	var first: int = _server.add_fake_player(brains[0], VARDHEIM, templates[0])
	var second: int = _server.add_fake_player(brains[1], SOLMARCH, templates[1])
	if not potions:
		# Sin cargas: lo que aportan las pociones al TTK, por diferencia (solo en esta medida de referencia).
		for net_id: int in [first, second]:
			ActionMachine.set_charges(_server.get_registry().get_entity(net_id).get_character().combat, 0)
	_server.teleport(first, Vector3(-distance / 2.0, 0.1, 0.0))
	_server.teleport(second, Vector3(distance / 2.0, 0.1, 0.0))
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
			elif _is_fall(event):
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
	var runs: int = maxi(_team_runs, 1)
	print("\nEquipos de bots de combate, de %.0f m (%d combates de cada tamaño):" % [DUEL_DISTANCE, runs])
	# 2 y 5 escuderos por bando y, con las dos plantillas, 2 contra 2 con un escudero y un tirador en cada uno.
	for setup: Array in [[2, false], [5, false], [2, true]]:
		var size: int = setup[0]
		var mixed: bool = setup[1]
		var first_kills: Array[float] = []
		var ends: Array[float] = []
		var kills_per_fight: float = 0.0
		var unfinished: int = 0
		for index: int in runs:
			var fight: Dictionary = await _team_fight(size, DUEL_SEED_BASE + 1000 + 20 * index, mixed)
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
		results["%dv%d%s" % [size, size, "_templates" if mixed else ""]] = summary
		print("  %d contra %d%s: primera baja a los %.1f s (p10 %.1f, p90 %.1f); un bando sin nadie en pie a los %.1f s (p10 %.1f, p90 %.1f; %d de %d sin acabar en %d s); %.1f bajas por combate" % [
			size, size, " (escudero y tirador en cada bando)" if mixed else "", summary["first_kill_median_s"],
			summary["first_kill_p10_s"], summary["first_kill_p90_s"],
			summary["end_median_s"], summary["end_p10_s"], summary["end_p90_s"], unfinished, runs,
			TEAM_TIMEOUT_SECONDS, summary["deaths_per_fight"]])
	return results


# Un combate de [param size] contra [param size]: Vardheim a un lado y Solmarch al otro, en fila. Con
# [param mixed], los impares de cada bando llevan la plantilla del tirador (si no, todos el escudero).
func _team_fight(size: int, seed_first: int, mixed: bool = false) -> Dictionary:
	await _start_server()
	var marksman: int = CombatCatalog.template_id(&"marksman")
	var teams: Array[Array] = [[], []]
	for side: int in 2:
		for member: int in size:
			var realm: int = VARDHEIM if side == 0 else SOLMARCH
			var net_id: int = _server.add_fake_player(BotBrain.new(seed_first + 2 * member + side,
					BotBrain.Pattern.COMBAT, Vector3.ZERO, 30.0), realm,
					marksman if mixed and member % 2 == 1 else 0)
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
	# Quién sigue en pie: un derribado que luego muere solo cae una vez.
	var standing: Dictionary[int, bool] = {}
	for side: int in 2:
		for net_id: int in teams[side]:
			standing[net_id] = true
	var limit: int = start + int(TEAM_TIMEOUT_SECONDS * 60.0)
	while _server.get_tick() < limit and end_tick < 0:
		_step(1)
		for event: NetMessages.EntityEvent in _events:
			if event.event == NetMessages.EntityEvent.Kind.HIT and event.amount > 0 and first_hit < 0:
				first_hit = event.tick
			elif _is_fall(event) and standing.get(event.net_id, false):
				standing[event.net_id] = false
				for side: int in 2:
					if teams[side].has(event.net_id):
						alive[side] -= 1
						deaths += 1
						if first_kill < 0:
							first_kill = event.tick
						if alive[side] <= 0 and end_tick < 0:
							end_tick = event.tick
			elif event.event == NetMessages.EntityEvent.Kind.RESPAWN and standing.has(event.net_id):
				standing[event.net_id] = true
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


# true si [param event] es una caída: un derribo o una muerte (docs/habilidades.md, sección 4.5).
static func _is_fall(event: NetMessages.EntityEvent) -> bool:
	return event.event == NetMessages.EntityEvent.Kind.DEATH or event.event == NetMessages.EntityEvent.Kind.DOWNED


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
