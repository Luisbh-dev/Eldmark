extends TestCase
## Pruebas del guion de combate de la demo del sandbox (CMB-06): [CombatDemoScript] pulsa los botones
## de modo que la máquina de acciones recorre de verdad el combo de tres ligeros, el fuerte cargado, el
## bloqueo y la esquiva, y las demos ([DemoInput] del circuito de pruebas y [RouteDemoInput] del Vado
## Gris) lo incluyen sin cambiar el resto de su recorrido.

const START_TICK: int = 1000
## Tiempo máximo de espera a la demo como proceso (la del circuito de pruebas dura unos 14 s; la prueba, menos de 30).
const PROCESS_MAX_WAIT_SECONDS: float = 25.0
const Action = CombatState.Action


## Recorre el guion con la máquina de acciones (sin física) y devuelve, en orden, los cambios de
## acción como [code][acción, id del ataque, tick relativo][/code], junto con el estado final.
func _run_script(script: CombatDemoScript) -> Array[Array]:
	var state: CombatState = CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())
	var changes: Array[Array] = []
	var last_key := Vector3i(-1, -1, -1)
	for t: int in script.get_length():
		var input := PlayerInput.new()
		input.tick = START_TICK + t
		input.buttons = script.buttons_at(t)
		ActionMachine.step(state, input, true)
		var key := Vector3i(state.action, state.action_id, state.action_tick)
		if key != last_key:
			last_key = key
			changes.append([state.action, state.action_id, t])
	return changes


func test_script_walks_the_combo_the_heavy_the_block_and_the_dodge() -> void:
	var script := CombatDemoScript.new()
	var changes: Array[Array] = _run_script(script)
	var lights: Array[int] = []
	var seen: Array[int] = []
	for change: Array in changes:
		var action: int = change[0]
		if action == Action.LIGHT:
			lights.append(int(change[1]))
		if action != Action.NONE:
			seen.append(action)
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.default_weapon_id())
	var combo: Array[int] = []
	combo.assign(weapon.light_ids)
	# Los tres primeros ligeros son el combo entero, en orden; el cuarto es la pulsación que se
	# convierte en la carga del fuerte.
	assert_eq(lights.slice(0, 3), combo, "el combo de tres ligeros encadena sin huecos")
	assert_true(seen.has(Action.CHARGE), "carga el fuerte")
	assert_true(seen.has(Action.HEAVY), "y lo lanza")
	assert_true(seen.has(Action.BLOCK), "bloquea")
	assert_true(seen.has(Action.DODGE), "y esquiva")
	assert_eq(seen.count(Action.HEAVY), 1, "un solo fuerte")
	assert_eq(seen.count(Action.DODGE), 1, "una sola esquiva")
	assert_false(seen.has(Action.STAGGER) or seen.has(Action.STUN) or seen.has(Action.DEAD),
			"sin controles ni muerte: nadie golpea en el sandbox")
	# Orden: ligeros, carga, fuerte, bloqueo, esquiva.
	assert_true(seen.find(Action.CHARGE) < seen.find(Action.HEAVY))
	assert_true(seen.find(Action.HEAVY) < seen.find(Action.BLOCK))
	assert_true(seen.find(Action.BLOCK) < seen.find(Action.DODGE))


func test_the_combo_links_each_hit_at_the_exact_end_of_the_previous_recovery() -> void:
	var script := CombatDemoScript.new()
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.default_weapon_id())
	var starts: Array[int] = []
	for change: Array in _run_script(script):
		if int(change[0]) == Action.LIGHT and starts.size() < 3:
			starts.append(int(change[2]))
	assert_eq(starts.size(), 3)
	var expected: int = 0
	for i: int in 3:
		assert_eq(starts[i], expected, "el golpe %d empieza en el tick %d" % [i + 1, expected])
		expected += CombatCatalog.attack(weapon.light_ids[i]).total_ticks


func test_heavy_is_charged_beyond_the_minimum_and_released() -> void:
	var script := CombatDemoScript.new()
	var heavy: AttackTicks = CombatCatalog.attack(
			CombatCatalog.weapon(CombatCatalog.default_weapon_id()).heavy_id)
	var state: CombatState = CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())
	var charge_ticks: int = 0
	for t: int in script.get_length():
		var input := PlayerInput.new()
		input.tick = START_TICK + t
		input.buttons = script.buttons_at(t)
		ActionMachine.step(state, input, true)
		if state.action == Action.HEAVY and charge_ticks == 0:
			charge_ticks = state.charge_ticks
	assert_true(charge_ticks >= heavy.charge_min_ticks, "carga al menos el mínimo (%d >= %d)"
			% [charge_ticks, heavy.charge_min_ticks])
	assert_true(charge_ticks < heavy.charge_max_ticks, "sin llegar a la carga máxima")
	assert_eq(state.stamina <= 1000 and state.stamina > 0, true, "y la resistencia no se agota")


func test_script_has_a_sensible_length_and_ends_idle() -> void:
	var script := CombatDemoScript.new()
	var length: int = script.get_length()
	assert_true(length > 200 and length < 420, "unos 5 s de combate (%d ticks)" % length)
	assert_eq(script.buttons_at(-1), 0, "antes del guion, nada")
	assert_eq(script.buttons_at(length), 0, "y después tampoco")
	assert_eq(script.buttons_at(length + 100), 0)
	assert_false(script.is_finished(length - 1))
	assert_true(script.is_finished(length))
	assert_true(script.get_dodge_tick() > script.get_heavy_release_tick())
	assert_eq(script.buttons_at(script.get_dodge_tick()), PlayerInput.DODGE)


func test_demo_input_adds_the_combat_after_the_approach_without_changing_the_route() -> void:
	var demo := DemoInput.new()
	var script := CombatDemoScript.new()
	assert_eq(demo.get_length(), DemoInput.APPROACH_END + script.get_length(),
			"el combate sustituye a la vuelta de cámara sola")
	# El recorrido anterior no pulsa ningún botón de combate.
	for tick: int in range(1, DemoInput.APPROACH_END + 1):
		var input: PlayerInput = demo.next(tick)
		assert_eq(input.buttons & (PlayerInput.PRIMARY | PlayerInput.BLOCK | PlayerInput.DODGE), 0,
				"tick %d: sin combate durante el recorrido" % tick)
	# Y en el combate pulsa lo que dice el guion.
	var pressed: int = 0
	for rel: int in script.get_length():
		var input: PlayerInput = demo.next(DemoInput.COMBAT_START + 1 + rel)
		assert_eq(input.buttons & (PlayerInput.PRIMARY | PlayerInput.BLOCK | PlayerInput.DODGE),
				script.buttons_at(rel), "tick %d del combate" % rel)
		if input.buttons != 0:
			pressed += 1
	assert_true(pressed > 50, "se pulsan botones durante el combate")
	var last: PlayerInput = demo.next(demo.get_length() + 10)
	assert_eq(last.buttons, 0, "tras la demo, en reposo")
	assert_true(demo.is_finished(demo.get_length()))
	# La cámara sigue dando la vuelta completa mientras dura el combate.
	var start_yaw: float = demo.look_for(DemoInput.COMBAT_START).x
	var turned: float = 0.0
	var previous: float = start_yaw
	for tick: int in range(DemoInput.COMBAT_START, demo.get_length() + 1):
		var yaw: float = demo.look_for(tick).x
		turned += absf(angle_difference(previous, yaw))
		previous = yaw
	assert_near(turned, TAU, 0.2, "una vuelta completa de cámara (%.2f rad)" % turned)


func test_route_demo_for_the_vado_gris_has_a_combat_step() -> void:
	for realm: StringName in [&"vardheim", &"solmarch"]:
		var demo: RouteDemoInput = RouteDemoInput.vado_gris(realm)
		var combat_steps: int = 0
		for step: RouteDemoInput.Step in demo._steps:
			if step.kind == RouteDemoInput.Kind.COMBAT:
				combat_steps += 1
				assert_not_null(step.combat, "el paso lleva su guion")
				assert_eq(step.ticks, step.combat.get_length())
				if realm == &"solmarch":
					assert_true(step.degrees < 0.0, "la vuelta de cámara se refleja en Solmarch")
		assert_eq(combat_steps, 1, "%s: un tramo de combate al final de la ruta" % realm)
		assert_eq(demo._steps[demo._steps.size() - 1].kind, RouteDemoInput.Kind.COMBAT)


func test_route_demo_presses_the_scripted_buttons_during_the_combat_step() -> void:
	var demo := RouteDemoInput.new()
	demo.combat(360.0, "combate de prueba")
	var character: PlayerCharacter = (load("res://scenes/characters/player_character.tscn") as PackedScene).instantiate() as PlayerCharacter
	tree.root.add_child(character)
	demo.bind(character)
	var script := CombatDemoScript.new()
	var mismatches: int = 0
	for rel: int in script.get_length():
		var input: PlayerInput = demo.next(rel + 1)
		if input.buttons != script.buttons_at(rel):
			mismatches += 1
	assert_eq(mismatches, 0, "cada tick pulsa lo del guion")
	demo.next(script.get_length() + 5)
	assert_true(demo.is_finished(script.get_length() + 5), "y acaba")
	tree.root.remove_child(character)
	character.free()


# --- Demo como proceso aparte -----------------------------------------------------------------

## La demo del circuito de pruebas en un cliente sin ventana ([code]--demo --quit-after-demo[/code]) termina
## sola con código 0 y sin errores, y el personaje recorre de verdad el combo, el fuerte cargado, el
## bloqueo y la esquiva (la línea «acciones de combate» sale de las acciones que vio el cliente).
func test_the_headless_demo_runs_the_combat_without_errors_and_quits_by_itself() -> void:
	var log_name: String = "test_combat_demo_process"
	var log_path: String = NetHarness.build_path("%s.log" % log_name)
	DirAccess.remove_absolute(log_path)
	var pid: int = NetHarness.launch_process(PackedStringArray([
		"--zone=test_world", "--demo", "--quit-after-demo"]), log_name)
	if not assert_true(pid > 0, "el proceso del cliente se lanza"):
		return
	var deadline: int = Time.get_ticks_msec() + int(PROCESS_MAX_WAIT_SECONDS * 1000.0)
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.1).timeout
	if OS.is_process_running(pid):
		OS.kill(pid)
		fail("la demo no terminó en %d s" % int(PROCESS_MAX_WAIT_SECONDS))
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "código de salida 0")
	assert_eq(NetHarness.error_lines(log_path), PackedStringArray(), "sin errores en el registro")
	var log_text: String = FileAccess.get_file_as_string(log_path)
	var length: int = DemoInput.new().get_length()
	assert_true(log_text.contains("Demo terminada (tick %d)" % length),
			"termina en el tick %d del guion" % length)
	assert_true(log_text.contains("Demo, acciones de combate: LIGHT x4, CHARGE x1, HEAVY x1, BLOCK x1, DODGE x1"),
			"y recorre el combo, la carga, el fuerte, el bloqueo y la esquiva")
