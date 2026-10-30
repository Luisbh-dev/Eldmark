extends TestCase
## La herramienta de la pasada de equilibrio ([code]tools/combat_balance.gd[/code], CMB-29; docs/combate.md,
## sección 12), que se lanza a mano fuera del ejecutor.
## [br][br]
## [b]Humo[/b]: el script se carga y se puede instanciar, así que un error de sintaxis en él rompe la
## suite y no se descubre al lanzar la medida completa.
## [br][br]
## [b]Proceso[/b]: una pasada mínima (un duelo, 2 s de DPS, 2 combates de cada tamaño, sin los duelos con el
## tirador) como proceso aparte que termina con código 0, sin errores en su registro y con las cifras que se
## comprueban aquí contra el catálogo: el DPS medido contra el maniquí es el que salen de los [code].tres[/code], y
## bloquear retrasa la muerte. [b]Kits de la fase 4[/b] (H5; docs/habilidades.md, secciones 2.4 y 7.3): el DPS del
## arco es el calculado (rápido, tensado mínimo y máximo), el maniquí a 10, 30 y 50 m recibe todas las flechas con
## el vuelo que dice la balística, un atacante no rompe el muro de escudos en sus 6 s y dos sí, cerca de lo
## calculado, y el 2 contra 2 con las dos plantillas tiene bajas.

const TOOL_PATH: String = "res://tools/combat_balance.gd"
## Tiempo máximo de espera al proceso (cada prueba dura menos de 30 s).
const MAX_WAIT_SECONDS: float = 25.0

var _pids: Array[int] = []


func after_each() -> void:
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()
	await wait_process_frames()


# --- Humo -------------------------------------------------------------------------------------

func test_balance_tool_script_loads_and_can_be_instantiated() -> void:
	var script: GDScript = load(TOOL_PATH) as GDScript
	if not assert_not_null(script, "%s se carga (un error de sintaxis lo dejaría en null)" % TOOL_PATH):
		return
	assert_true(script.can_instantiate(), "y se puede instanciar")
	assert_true(script.get_script_method_list().any(
			func(method: Dictionary) -> bool: return method["name"] == "_initialize"),
			"es un script de línea de comandos (SceneTree._initialize)")


# --- Proceso ----------------------------------------------------------------------------------

func test_a_minimal_balance_run_matches_the_catalog_and_ends_without_errors() -> void:
	var log_name: String = "test_combat_balance"
	var out_path: String = NetHarness.build_path("%s.json" % log_name)
	DirAccess.remove_absolute(out_path)
	var pid: int = NetHarness.launch_script(TOOL_PATH, PackedStringArray([
		"--duels=1", "--seconds=2", "--team-runs=2", "--no-template-duels", "--out=%s" % out_path]), log_name)
	if not assert_true(pid > 0, "el proceso se lanza"):
		return
	_pids.append(pid)
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.1).timeout
	if not assert_false(OS.is_process_running(pid), "la herramienta termina sola en menos de %d s" \
			% int(MAX_WAIT_SECONDS)):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "código de salida 0")
	assert_eq(NetHarness.error_lines(NetHarness.build_path("%s.log" % log_name)), PackedStringArray(),
			"sin errores en el registro")
	var result: Dictionary = NetHarness.read_report(out_path)
	if not assert_false(result.is_empty(), "deja su JSON de resultados"):
		return

	# El DPS que mide contra el maniquí es el que dicen los datos.
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var combo_damage: int = 0
	var combo_ticks: int = 0
	for light_id: int in weapon.light_ids:
		var attack: AttackTicks = CombatCatalog.attack(light_id)
		combo_damage += attack.base_damage
		combo_ticks += attack.total_ticks
	var data: Dictionary = result.get("data", {})
	assert_eq(int((data.get("combo", {}) as Dictionary).get("damage", -1)), combo_damage,
			"el combo de la tabla de datos suma el daño de sus tres ligeros")
	assert_eq(int((data.get("combo", {}) as Dictionary).get("ticks", -1)), combo_ticks, "y sus ticks")
	var dps: Dictionary = result.get("dps", {})
	for key: String in ["combo", "light_spam", "heavy_min", "heavy_max"]:
		var measured: Dictionary = dps.get(key, {})
		assert_true(int(measured.get("hits", 0)) > 0, "%s: golpea al maniquí" % key)
		assert_near(float(measured.get("dps", -1.0)), float(measured.get("expected_dps", -2.0)), 0.5,
				"%s: el DPS medido es el calculado con los datos" % key)
		# El DPS por sí solo sale siempre igual al calculado (daño de ciclos enteros entre sus segundos):
		# lo que lo ata a los datos es que cada golpe caiga en el tick que le toca.
		var hit_ticks: Array = measured.get("hit_ticks", [])
		assert_false(hit_ticks.is_empty(), "%s: se anotan los ticks de los golpes" % key)
		assert_eq(hit_ticks, measured.get("expected_hit_ticks", []),
				"%s: cada golpe cae en el tick que dicen los datos" % key)

	# El atacante perfecto mata a quien no se defiende y tarda más contra quien bloquea.
	var ideal: Dictionary = result.get("ideal", {})
	var still: Dictionary = ideal.get("quieta", {})
	var blocking: Dictionary = ideal.get("bloqueando", {})
	assert_eq(int(still.get("victim_health", -1)), 0, "la víctima quieta muere")
	assert_eq(int(blocking.get("victim_health", -1)), 0, "la que bloquea también acaba muriendo")
	assert_true(float(blocking.get("ttk_s", 0.0)) > float(still.get("ttk_s", INF)),
			"bloquear retrasa la muerte (%s s contra %s s)" % [blocking.get("ttk_s"), still.get("ttk_s")])
	assert_true(float(blocking.get("guard_break_s", -1.0)) > 0.0, "y acaba rompiéndose la guardia")

	# Duelos y equipos: se miden y no se quedan en tablas.
	var duels: Dictionary = result.get("duels", {})
	assert_eq(int(duels.get("duels", -1)), 1, "un duelo")
	assert_eq(int(duels.get("decided", 0)) + int(duels.get("draws", 0)), 1, "decidido o empatado")
	var teams: Dictionary = result.get("teams", {})
	for key: String in ["2v2", "5v5", "2v2_templates"]:
		var fights: Dictionary = teams.get(key, {})
		assert_true(int(fights.get("fights", 0)) >= 2, "%s: al menos 2 combates" % key)
		assert_true(float(fights.get("deaths_per_fight", 0.0)) > 0.0, "%s: hay bajas" % key)
	_check_phase_4_kits(result)


# Los kits de la fase 4: arco contra el maniquí, alcances y muro de escudos (docs/habilidades.md, sección 2.4).
func _check_phase_4_kits(result: Dictionary) -> void:
	var bow: Dictionary = result.get("bow", {})
	for key: String in ["quick", "drawn_min", "drawn_max"]:
		var measured: Dictionary = bow.get(key, {})
		assert_true(int(measured.get("shots", 0)) > 0, "arco, %s: dispara" % key)
		assert_eq(int(measured.get("hits", -1)), int(measured.get("shots", -2)), "arco, %s: todas dan en el maniquí" % key)
		assert_near(float(measured.get("dps", -1.0)), float(measured.get("expected_dps", -2.0)), 0.5,
				"arco, %s: el DPS medido es el calculado con los datos" % key)
	var expected_bow: Dictionary = (result.get("kit_data", {}) as Dictionary)
	assert_near(float((expected_bow.get("quick", {}) as Dictionary).get("dps", 0.0)), 97.3, 0.05,
			"el disparo rápido de la hoja: 97,3")
	assert_near(float((expected_bow.get("drawn_min", {}) as Dictionary).get("dps", 0.0)), 125.6, 0.05)
	assert_near(float((expected_bow.get("drawn_max", {}) as Dictionary).get("dps", 0.0)), 131.7, 0.05)
	var ranges: Dictionary = result.get("ranges", {})
	var flights: Dictionary = expected_bow.get("flights", {})
	for distance: String in ["10", "30", "50"]:
		for key: String in ["quick", "drawn_max"]:
			var measured: Dictionary = (ranges.get(distance, {}) as Dictionary).get(key, {})
			assert_eq(int(measured.get("hits", -1)), 5, "a %s m, %s: las 5 flechas dan en el maniquí" % [distance, key])
			var flight: float = float(((flights.get(distance, {}) as Dictionary).get(key, {}) as Dictionary).get(
					"flight_s", -1.0))
			assert_near(float(measured.get("flight_s", -2.0)), flight, 0.05,
					"a %s m, %s: el vuelo es el de la balística (%.2f s)" % [distance, key, flight])
	var wall: Dictionary = result.get("wall", {})
	var wall_data: Dictionary = expected_bow.get("wall", {})
	var one: Dictionary = wall.get("1", {})
	assert_false(bool(one.get("broken", true)), "un atacante no rompe el muro de escudos")
	assert_near(float(one.get("stamina_spent", 0)), float(wall_data.get("one_attacker_stamina", -1000.0)), 60.0,
			"y le quita lo calculado (%s)" % one.get("stamina_spent"))
	var two: Dictionary = wall.get("2", {})
	assert_true(bool(two.get("broken", false)), "dos sí lo rompen")
	assert_near(float(two.get("break_s", -1.0)), float(wall_data.get("two_attackers_break_s", -10.0)), 0.5,
			"cerca de lo calculado (%s s)" % two.get("break_s"))
