extends TestCase
## Pruebas de la máquina de acciones ([ActionMachine], docs/combate.md sección 3).
## [br][br]
## La primera mitad usa un [Driver] sin física: avanza la máquina tick a tick con botones
## guionizados y comprueba el tick exacto de cada fase, el combo, la carga, el búfer, la
## cancelación a esquiva, la parada, la resistencia, las entradas sustituidas y lo que impone el
## servidor. La segunda mitad (a partir de «Con física») mueve un [PlayerCharacter] real:
## recorrido de la esquiva, muros, bloqueo, avance de los ataques, velocidad de aterrizaje y la
## repetición determinista (set_state a mitad de una acción y mismas entradas = mismo encode()) en
## dos mundos de física separados.
## [br][br]
## Valores de la espada y el escudo (ticks): ligero 1 = 12 + 6 + 18 (ventana de combo [27, 36)),
## ligero 2 = 11 + 6 + 18, ligero 3 = 15 + 6 + 27, fuerte = 24 + 7 + 33 con carga 21..72, esquiva
## = 27 (invulnerable [3, 18), a ataque desde 18, cuesta 300).

const PRIMARY: int = PlayerInput.PRIMARY
const BLOCK: int = PlayerInput.BLOCK
const DODGE: int = PlayerInput.DODGE
const Action = CombatState.Action

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const WORLD_LAYER: int = PlayerCharacter.WORLD_COLLISION_LAYER
## Primer tick de las pruebas sin física (lejos de 0 para no rozar ventanas negativas).
const START_TICK: int = 1000

var _data: CombatTables
var _viewports: Array[SubViewport] = []
var _dt: float = 1.0 / 60.0


## Máquina sin física: un [CombatState] y un reloj, para guionizar entradas tick a tick.
class Driver:
	var c: CombatState
	var tick: int = START_TICK
	var grounded: bool = true
	var move: Vector2 = Vector2.ZERO
	var look_yaw: float = 0.0
	var out: ActionMachine.Output


	func _init() -> void:
		c = CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())


	## Avanza un tick con [param buttons] (y la marca de entrada sustituida si se pide) y devuelve
	## el movimiento permitido. El tick avanzado queda en [member tick].
	func step(buttons: int = 0, substituted: bool = false) -> ActionMachine.Output:
		tick += 1
		var input := PlayerInput.new()
		input.tick = tick
		input.buttons = buttons | (PlayerInput.SUBSTITUTED if substituted else 0)
		input.move = move
		input.look_yaw = look_yaw
		out = ActionMachine.step(c, input, grounded)
		return out


	## Fija la resistencia sin que la regeneración (que va antes de las entradas de cada tick)
	## la cambie.
	func set_stamina(value: int) -> void:
		c.stamina = value
		c.stamina_regen_tick = tick + 100000


	## [param count] ticks seguidos con los mismos botones.
	func hold(buttons: int, count: int, substituted: bool = false) -> void:
		for _i: int in count:
			step(buttons, substituted)


	## Avanza hasta que el siguiente [method step] sea el del tick [param target] (inclusive:
	## deja el estado listo para que [member tick] sea [code]target - 1[/code]).
	func idle_until_before(target: int) -> void:
		while tick < target - 1:
			step()


func before_each() -> void:
	_data = CombatCatalog.tables()
	_dt = 1.0 / float(Engine.physics_ticks_per_second)


func after_each() -> void:
	for viewport: SubViewport in _viewports:
		if is_instance_valid(viewport):
			if viewport.is_inside_tree():
				viewport.get_parent().remove_child(viewport)
			viewport.free()
	_viewports.clear()
	await wait_process_frames()


# --- Ataque ligero: fases ---------------------------------------------------------------------

func test_idle_does_nothing() -> void:
	var d := Driver.new()
	d.hold(0, 50)
	assert_eq(d.c.action, Action.NONE, "sin entrada no hay acción")
	assert_eq(d.c.stamina, 1000, "y la resistencia sigue llena")
	assert_eq(d.c.buffered, 0, "el búfer sigue vacío")
	var out: ActionMachine.Output = d.step()
	assert_eq(out.move_scale, 1.0, "movimiento normal")
	assert_eq(out.turn_rate, -1.0, "giro normal")
	assert_true(out.allow_jump and out.allow_sprint, "salto y esprint permitidos")
	assert_false(out.scaled_movement or out.forced_velocity or out.snap_yaw, "sin efectos")
	assert_eq(out.lunge_speed, 0.0, "sin avance")


func test_light_attack_phases_at_exact_ticks() -> void:
	var d := Driver.new()
	d.hold(0, 5)
	var p: int = d.tick + 1
	var light1: AttackTicks = _data.attack(_light_id(0))
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "PRIMARY en el suelo empieza el ligero")
	assert_eq(d.c.action_id, light1.id, "el primero del combo")
	assert_eq(d.c.action_tick, p, "action_tick es el tick de la pulsación")
	assert_eq(d.c.combo_step, 1, "combo_step apunta al siguiente")
	assert_eq(d.c.primary_held, 1, "primary_held cuenta desde el flanco")
	for rel: int in range(0, 38):
		if rel > 0:
			d.step()
		var tick: int = p + rel
		var phase: int = ActionMachine.phase(d.c, tick)
		if rel < 12:
			assert_eq(phase, ActionMachine.PHASE_WINDUP, "rel %d: anticipación" % rel)
			assert_false(ActionMachine.is_attack_active(d.c, tick), "rel %d: aún no golpea" % rel)
		elif rel < 18:
			assert_eq(phase, ActionMachine.PHASE_ACTIVE, "rel %d: golpe activo" % rel)
			assert_true(ActionMachine.is_attack_active(d.c, tick), "rel %d: golpea" % rel)
		elif rel < 36:
			assert_eq(phase, ActionMachine.PHASE_RECOVERY, "rel %d: recuperación" % rel)
			assert_false(ActionMachine.is_attack_active(d.c, tick), "rel %d: ya no golpea" % rel)
		if rel < 36:
			assert_eq(d.c.action, Action.LIGHT, "rel %d: sigue el ataque" % rel)
		else:
			assert_eq(d.c.action, Action.NONE, "rel %d: vuelve a NONE tras 36 ticks" % rel)
			assert_eq(ActionMachine.phase(d.c, tick), ActionMachine.PHASE_NONE, "sin fases")
	assert_eq(d.c.combo_step, 0, "sin enlace, el combo vuelve a empezar")
	assert_eq(d.c.stamina, 1000, "los ligeros no cuestan resistencia")


func test_light_attack_movement_per_phase() -> void:
	var d := Driver.new()
	var first: ActionMachine.Output = d.step(PRIMARY)
	assert_true(first.snap_yaw, "en el primer tick el yaw salta a la cámara")
	assert_true(first.scaled_movement, "el movimiento queda escalado")
	assert_near(first.move_scale, 0.3, 1e-9, "×0,3")
	assert_near(first.lunge_speed, 1.5, 1e-9, "avance de 1,5 m/s")
	assert_near(first.turn_rate, 6.0, 1e-9, "giro de 6 rad/s")
	assert_false(first.allow_jump, "no se salta atacando")
	assert_false(first.allow_sprint, "ni se esprinta")
	assert_false(first.forced_velocity, "la velocidad no se impone: acelera con normalidad")
	var second: ActionMachine.Output = d.step()
	assert_false(second.snap_yaw, "solo salta en el primer tick")
	assert_near(second.lunge_speed, 1.5, 1e-9, "sigue el avance en la anticipación")
	d.hold(0, 15)
	var active: ActionMachine.Output = d.step()
	assert_eq(d.tick - d.c.action_tick, 17, "último tick del golpe activo")
	assert_near(active.lunge_speed, 1.5, 1e-9, "y en el golpe activo")
	var recovery: ActionMachine.Output = d.step()
	assert_eq(d.tick - d.c.action_tick, 18, "primer tick de la recuperación")
	assert_eq(recovery.lunge_speed, 0.0, "en la recuperación ya no avanza")
	assert_eq(recovery.turn_rate, 0.0, "ni gira")
	assert_near(recovery.move_scale, 0.3, 1e-9, "pero se puede mover ×0,3")
	assert_false(recovery.allow_jump, "sin saltar")


# --- Combo ------------------------------------------------------------------------------------

func test_three_light_combo_with_link_window() -> void:
	var d := Driver.new()
	d.hold(0, 3)
	var p1: int = d.tick + 1
	d.step(PRIMARY)
	assert_eq(d.c.action_id, _light_id(0), "ligero 1")
	# Pulsación dentro de la ventana de combo [27, 36) del primero.
	d.hold(0, 29)
	d.step(PRIMARY)
	assert_eq(d.tick, p1 + 30, "pulsación 30 ticks después de empezar")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_LINK, "queda como enlace")
	for rel: int in range(31, 36):
		d.step()
		assert_eq(d.c.action_id, _light_id(0), "rel %d: el primero sigue" % rel)
	d.step()
	var p2: int = p1 + 36
	assert_eq(d.tick, p2, "el segundo empieza justo al acabar la recuperación")
	assert_eq(d.c.action, Action.LIGHT, "ligero")
	assert_eq(d.c.action_id, _light_id(1), "ligero 2")
	assert_eq(d.c.action_tick, p2, "action_tick del segundo")
	assert_eq(d.c.combo_step, 2, "el siguiente es el tercero")
	assert_eq(d.c.buffered, 0, "el enlace se consumió")
	assert_true(d.out.snap_yaw, "el yaw salta a la cámara también en un ligero enlazado")

	# El segundo dura 35 ticks, con ventana [26, 35).
	d.hold(0, 29)
	d.step(PRIMARY)
	assert_eq(d.tick, p2 + 30, "pulsación 30 ticks después de empezar el segundo")
	d.hold(0, 4)
	assert_eq(d.c.action_id, _light_id(1), "el segundo sigue hasta rel 34")
	d.step()
	var p3: int = p2 + 35
	assert_eq(d.tick, p3, "el tercero empieza a los 35 ticks")
	assert_eq(d.c.action_id, _light_id(2), "ligero 3")
	assert_eq(d.c.combo_step, 0, "tras el tercero el combo vuelve a empezar")

	# El tercero (48 ticks) no tiene ventana, pero una pulsación en sus últimos 8 ticks espera en
	# el búfer y arranca el combo de nuevo.
	d.hold(0, 44)
	d.step(PRIMARY)
	assert_eq(d.tick, p3 + 45, "pulsación en rel 45 del tercero")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "sin ventana, es una pulsación normal")
	d.hold(0, 2)
	assert_eq(d.c.action_id, _light_id(2), "rel 47: el tercero sigue")
	d.step()
	assert_eq(d.tick, p3 + 48, "el tercero acaba a los 48 ticks")
	assert_eq(d.c.action_id, _light_id(0), "y empieza el combo otra vez por el ligero 1")
	assert_eq(d.c.combo_step, 1, "y el siguiente es el 2")


func test_link_press_boundaries() -> void:
	# La pulsación enlaza desde 8 ticks antes de la ventana: el primero dura 36 y su ventana es
	# [27, 36), así que vale desde rel 19.
	for rel: int in [10, 18, 19, 20, 26, 27, 35]:
		var d := Driver.new()
		var p: int = d.tick + 1
		d.step(PRIMARY)
		d.hold(0, rel - 1)
		d.step(PRIMARY)
		d.hold(0, 35 - rel)
		assert_eq(d.tick, p + 35, "(rel %d) último tick del primer ataque" % rel)
		assert_eq(d.c.action_id, _light_id(0), "(rel %d) el primero sigue en su último tick" % rel)
		d.step()
		var chained: bool = rel >= 19
		if chained:
			assert_eq(d.c.action_id, _light_id(1), "(rel %d) dentro de la ventana enlaza el 2" % rel)
		else:
			assert_eq(d.c.action, Action.NONE, "(rel %d) fuera de la ventana no hay enlace" % rel)
			assert_eq(d.c.combo_step, 0, "(rel %d) y el combo vuelve a empezar" % rel)


func test_press_after_the_recovery_starts_a_new_combo() -> void:
	var d := Driver.new()
	d.step(PRIMARY)
	d.hold(0, 35)
	assert_eq(d.c.action, Action.LIGHT, "el primero sigue en su último tick de recuperación")
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "pulsar justo al acabar (fuera de la ventana)...")
	assert_eq(d.c.action_id, _light_id(0), "...empieza otra vez por el ligero 1")
	assert_eq(d.c.combo_step, 1, "con el segundo como siguiente")
	# Tras unos ticks quieto, igual.
	var e := Driver.new()
	e.step(PRIMARY)
	e.hold(0, 40)
	assert_eq(e.c.action, Action.NONE, "(otro) el primero acabó")
	e.step(PRIMARY)
	assert_eq(e.c.action_id, _light_id(0), "(otro) tras unos ticks quieto, ligero 1")


func test_holding_primary_after_the_combo_does_not_repeat_attacks() -> void:
	# Mantener el botón no encadena golpes: hace falta soltar y volver a pulsar.
	var d := Driver.new()
	d.step(PRIMARY)
	d.hold(PRIMARY, 7)
	assert_eq(d.c.action, Action.CHARGE, "tras 8 ticks pulsado se carga")
	d.hold(PRIMARY, 70)
	assert_eq(d.c.action, Action.HEAVY, "y se lanza el fuerte al llegar a la carga máxima")
	d.hold(PRIMARY, 100)
	assert_eq(d.c.action, Action.NONE, "con el botón aún pulsado, no empieza otro ataque")
	assert_eq(d.c.buffered, 0, "ni queda nada en el búfer")


# --- Carga del fuerte -------------------------------------------------------------------------

func test_holding_primary_8_ticks_starts_the_charge() -> void:
	var d := Driver.new()
	d.hold(0, 4)
	var p: int = d.tick + 1
	d.step(PRIMARY)
	for held: int in range(2, 8):
		d.step(PRIMARY)
		assert_eq(d.c.action, Action.LIGHT, "con %d ticks pulsado sigue el ligero" % held)
		assert_eq(d.c.primary_held, held, "primary_held = %d" % held)
	var out: ActionMachine.Output = d.step(PRIMARY)
	assert_eq(d.tick, p + 7, "el octavo tick pulsado")
	assert_eq(d.c.action, Action.CHARGE, "a los 8 ticks pulsado empieza la carga")
	assert_eq(d.c.action_id, _heavy_id(), "con el ataque fuerte")
	assert_eq(d.c.action_tick, p, "conserva el action_tick de la pulsación")
	assert_eq(d.c.primary_held, 8, "primary_held = 8")
	assert_true(out.snap_yaw, "el yaw salta a la cámara al empezar la carga")
	assert_near(out.move_scale, 0.4, 1e-9, "cargando se mueve ×0,4")
	assert_near(out.turn_rate, 4.0, 1e-9, "y gira a 4 rad/s")
	assert_eq(out.lunge_speed, 0.0, "sin avance")
	assert_false(out.allow_jump, "sin saltar")
	assert_false(out.allow_sprint, "ni esprintar")
	assert_eq(d.c.stamina, 1000, "cargar no gasta resistencia")
	assert_eq(ActionMachine.phase(d.c, d.tick), ActionMachine.PHASE_WINDUP, "la carga es la fase 0")
	var next: ActionMachine.Output = d.step(PRIMARY)
	assert_false(next.snap_yaw, "y solo salta una vez")


func test_a_short_press_stays_a_light_attack() -> void:
	var d := Driver.new()
	d.hold(PRIMARY, 7)
	d.step()
	assert_eq(d.c.action, Action.LIGHT, "7 ticks pulsado no bastan")
	assert_eq(d.c.action_id, _light_id(0), "es el ligero 1")
	assert_eq(d.c.primary_held, 0, "soltar borra la pulsación")
	d.hold(0, 40)
	assert_eq(d.c.action, Action.NONE, "y acaba como un ligero")


func test_releasing_before_the_minimum_launches_at_the_minimum() -> void:
	var d := Driver.new()
	var p: int = d.tick + 1
	d.hold(PRIMARY, 10)
	assert_eq(d.c.action, Action.CHARGE, "cargando")
	# Soltar con 10 ticks de carga (mínima 21): se espera.
	for rel: int in range(10, 21):
		d.step()
		assert_eq(d.tick, p + rel, "tick %d" % rel)
		assert_eq(d.c.action, Action.CHARGE, "rel %d: espera a la carga mínima" % rel)
		assert_eq(d.c.primary_held, 0, "rel %d: la pulsación ya no está viva" % rel)
	d.step()
	assert_eq(d.tick, p + 21, "se lanza al llegar a charge_min")
	assert_eq(d.c.action, Action.HEAVY, "HEAVY")
	assert_eq(d.c.action_id, _heavy_id(), "fuerte")
	assert_eq(d.c.action_tick, p + 21, "la anticipación empieza al lanzar")
	assert_eq(d.c.charge_ticks, 21, "carga de 21 ticks")
	assert_eq(d.c.stamina, 850, "el fuerte cuesta 150")
	assert_eq(d.c.stamina_regen_tick, p + 21 + 36, "y retrasa la regeneración 0,6 s")
	assert_true(d.out.snap_yaw, "el yaw salta a la cámara al lanzar")
	assert_true(ActionMachine.phase(d.c, d.tick) == ActionMachine.PHASE_WINDUP, "empieza la anticipación")


func test_releasing_after_the_minimum_launches_at_once() -> void:
	var d := Driver.new()
	var p: int = d.tick + 1
	d.hold(PRIMARY, 30)
	assert_eq(d.c.action, Action.CHARGE, "cargando 30 ticks")
	d.step()
	assert_eq(d.tick, p + 30, "al soltar")
	assert_eq(d.c.action, Action.HEAVY, "se lanza ya")
	assert_eq(d.c.charge_ticks, 30, "con 30 ticks de carga")
	assert_eq(d.c.action_tick, p + 30, "action_tick = tick del lanzamiento")


func test_heavy_attack_phases_at_exact_ticks() -> void:
	var d := Driver.new()
	d.hold(PRIMARY, 25)
	d.step()
	var launch: int = d.tick
	assert_eq(d.c.action, Action.HEAVY, "lanzado")
	for rel: int in range(1, 66):
		var out: ActionMachine.Output = d.step()
		var tick: int = launch + rel
		if rel < 24:
			assert_eq(ActionMachine.phase(d.c, tick), ActionMachine.PHASE_WINDUP, "rel %d" % rel)
			assert_near(out.lunge_speed, 2.5, 1e-9, "rel %d: avanza a 2,5 m/s" % rel)
		elif rel < 31:
			assert_eq(ActionMachine.phase(d.c, tick), ActionMachine.PHASE_ACTIVE, "rel %d" % rel)
			assert_true(ActionMachine.is_attack_active(d.c, tick), "rel %d: golpea" % rel)
		elif rel < 64:
			assert_eq(ActionMachine.phase(d.c, tick), ActionMachine.PHASE_RECOVERY, "rel %d" % rel)
			assert_eq(out.lunge_speed, 0.0, "rel %d: sin avance" % rel)
		if rel < 64:
			assert_eq(d.c.action, Action.HEAVY, "rel %d: sigue el fuerte" % rel)
		else:
			assert_eq(d.c.action, Action.NONE, "rel %d: acabó a los 64 ticks" % rel)
	assert_near(d.c.stamina, 850.0 + 3.0 * (66 - 36), 0.5, "tras el retardo vuelve a regenerar 3 por tick")


func test_charge_launches_automatically_at_the_maximum() -> void:
	var d := Driver.new()
	var p: int = d.tick + 1
	d.hold(PRIMARY, 72)
	assert_eq(d.tick, p + 71, "71 ticks desde la pulsación")
	assert_eq(d.c.action, Action.CHARGE, "aún cargando en el tick 71")
	d.step(PRIMARY)
	assert_eq(d.tick, p + 72, "tick 72")
	assert_eq(d.c.action, Action.HEAVY, "carga máxima: lanzamiento automático")
	assert_eq(d.c.charge_ticks, 72, "con la carga máxima")
	assert_eq(d.c.action_tick, p + 72, "action_tick = el lanzamiento")
	assert_eq(d.c.stamina, 850, "gasta 150")


func test_charge_does_not_regenerate_stamina() -> void:
	var d := Driver.new()
	ActionMachine.drain_stamina(d.c, 400, d.tick)
	assert_eq(d.c.stamina, 600, "tras gastar 400")
	d.hold(0, 40)
	var regenerated: int = d.c.stamina
	assert_true(regenerated > 600, "fuera de la carga regenera (%d)" % regenerated)
	d.hold(PRIMARY, 8)
	assert_eq(d.c.action, Action.CHARGE, "cargando")
	var charging: int = d.c.stamina
	assert_true(charging > regenerated, "mientras era un ligero sí regeneraba")
	d.hold(PRIMARY, 30)
	assert_eq(d.c.action, Action.CHARGE, "sigue cargando")
	assert_eq(d.c.stamina, charging, "cargando no regenera")


# --- Entradas sustituidas ---------------------------------------------------------------------

func test_substituted_inputs_do_not_turn_a_light_attack_into_a_charge() -> void:
	var d := Driver.new()
	d.step(PRIMARY)
	d.hold(PRIMARY, 10, true)
	assert_eq(d.c.action, Action.LIGHT, "con entradas repetidas, sigue el ligero")
	assert_eq(d.c.primary_held, 1, "las entradas sustituidas no suman a primary_held")
	d.hold(PRIMARY, 30, true)
	assert_eq(d.c.action, Action.NONE, "el ligero acaba (36 ticks)")
	assert_eq(d.c.buffered, 0, "sin nada pendiente")
	# Una entrada real después no ve un flanco (el botón sigue pulsado) ni cuenta 8 de golpe.
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.NONE, "no hay un flanco nuevo")


func test_substituted_inputs_freeze_the_charge() -> void:
	var d := Driver.new()
	d.hold(PRIMARY, 8)
	assert_eq(d.c.action, Action.CHARGE, "cargando")
	assert_eq(d.c.primary_held, 8, "ocho ticks reales")
	d.hold(PRIMARY, 120, true)
	assert_eq(d.c.action, Action.CHARGE, "120 ticks de entradas repetidas: no lanza al llegar a la máxima")
	assert_eq(d.c.primary_held, 8, "primary_held congelado")
	assert_eq(d.c.charge_ticks, 0, "y no se ha lanzado nada")
	assert_eq(d.c.stamina, 1000, "ni se ha gastado resistencia")
	# La primera entrada real lanza con la carga máxima (no más).
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.HEAVY, "con una entrada real, lanza")
	assert_eq(d.c.charge_ticks, 72, "con la carga máxima, no con los 130 ticks transcurridos")


func test_substituted_inputs_still_launch_after_a_real_release() -> void:
	# Soltar es una decisión real: si el lanzamiento cae en un tick sustituido, se hace igual.
	var d := Driver.new()
	d.hold(PRIMARY, 10)
	d.step()
	assert_eq(d.c.primary_held, 0, "soltado con una entrada real")
	d.hold(0, 20, true)
	assert_eq(d.c.action, Action.HEAVY, "el fuerte sale a los 21 ticks aunque lleguen entradas repetidas")


func test_substituted_inputs_do_not_open_parry_windows() -> void:
	var d := Driver.new()
	d.step(0, true)
	d.step(BLOCK, true)
	assert_eq(d.c.action, Action.BLOCK, "el bloqueo sí empieza")
	assert_eq(d.c.parry_ready_tick, 0, "pero no abre ventana de parada ni pone enfriamiento")
	assert_false(ActionMachine.is_parry_window(d.c, d.tick), "sin ventana de parada")
	# Con una entrada real equivalente sí se abre.
	var e := Driver.new()
	e.step(0)
	e.step(BLOCK)
	assert_true(ActionMachine.is_parry_window(e.c, e.tick), "con una entrada real, ventana de parada")


func test_a_substituted_input_during_the_press_only_delays_the_charge() -> void:
	# C1: una sola entrada sustituida entre los ticks p+1 y p+7 de la pulsación retrasa la carga un
	# tick (primary_held cuenta solo los ticks reales), pero no la anula para siempre.
	for lost: int in range(1, 8):
		var d := Driver.new()
		d.hold(0, 4)
		var p: int = d.tick + 1
		d.step(PRIMARY)
		for rel: int in range(1, 8):
			d.step(PRIMARY, rel == lost)
		assert_eq(d.tick, p + 7, "(perdida en p+%d) tick p+7" % lost)
		assert_eq(d.c.action, Action.LIGHT, "(perdida en p+%d) aún no hay 8 ticks reales" % lost)
		assert_eq(d.c.primary_held, 7, "(perdida en p+%d) siete ticks reales" % lost)
		var out: ActionMachine.Output = d.step(PRIMARY)
		assert_eq(d.tick, p + 8, "(perdida en p+%d) tick p+8" % lost)
		assert_eq(d.c.action, Action.CHARGE, "(perdida en p+%d) un tick más tarde, carga" % lost)
		assert_eq(d.c.primary_held, 8, "(perdida en p+%d) ocho ticks reales" % lost)
		assert_eq(d.c.action_tick, p, "(perdida en p+%d) conserva el action_tick" % lost)
		assert_true(out.snap_yaw, "(perdida en p+%d) el yaw salta al empezar la carga" % lost)
		d.hold(PRIMARY, 22)
		d.step()
		assert_eq(d.c.action, Action.HEAVY, "(perdida en p+%d) al soltar sale el fuerte" % lost)
		assert_eq(d.c.charge_ticks, 31, "(perdida en p+%d) con la carga desde la pulsación" % lost)
		assert_eq(d.c.stamina, 850, "(perdida en p+%d) y gasta 150" % lost)


func test_substituted_inputs_after_the_charge_started_change_nothing() -> void:
	# Perder una entrada con la carga ya empezada no la deshace (control de C1).
	var d := Driver.new()
	d.hold(PRIMARY, 8)
	assert_eq(d.c.action, Action.CHARGE, "cargando")
	d.step(PRIMARY, true)
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.CHARGE, "sigue la carga")
	assert_eq(d.c.primary_held, 9, "y solo cuentan los ticks reales")


func test_a_new_press_during_another_lights_windup_still_does_not_charge_it() -> void:
	# C1 no debe romper la regla de §3.3: la pulsación que llega con otro ligero ya en marcha no lo
	# convierte, aunque haya entradas sustituidas de por medio.
	for lost: int in [-1, 4, 6]:
		var d := Driver.new()
		var p: int = d.tick + 1
		d.step(PRIMARY)
		d.hold(0, 3)
		var second: int = d.tick + 1
		d.step(PRIMARY)
		assert_eq(second, p + 4, "segunda pulsación en p+4, con el ligero en la anticipación")
		for rel: int in range(1, 10):
			d.step(PRIMARY, rel == lost)
		assert_ne_int(d.c.action, Action.CHARGE,
				"(perdida %d) la pulsación nueva no convierte el ligero de otra" % lost)


func test_a_press_held_across_a_buffer_still_converts_the_light_it_starts() -> void:
	# Pulsación en el aire (al búfer) mantenida hasta aterrizar: el ligero que empieza al aterrizar
	# es de esa pulsación y se convierte en carga (control de C1).
	var d := Driver.new()
	d.grounded = false
	var p: int = d.tick + 1
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.NONE, "en el aire no se ataca")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "queda en el búfer")
	d.hold(PRIMARY, 2)
	d.grounded = true
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "al aterrizar empieza el ligero")
	assert_eq(d.c.action_tick, p + 3, "en el tick de aterrizaje")
	d.hold(PRIMARY, 4)
	assert_eq(d.c.primary_held, 8, "ocho ticks reales de pulsación")
	assert_eq(d.c.action, Action.CHARGE, "y el ligero de la pulsación se convierte")


func test_substituted_bit_is_not_a_button() -> void:
	var d := Driver.new()
	d.step(PlayerInput.SUBSTITUTED, true)
	assert_eq(d.c.action, Action.NONE, "el bit solo no hace nada")
	assert_eq(d.c.combat_flags & (CombatState.FLAG_DODGE_HELD | CombatState.FLAG_BLOCK_HELD
			| CombatState.FLAG_PRIMARY_HELD), 0, "ni cuenta como botón pulsado")
	assert_eq(PlayerInput.SUBSTITUTED & NetProtocol.VALID_BUTTONS, 0,
			"fuera de los botones válidos: el servidor lo descarta de lo que manda el cliente")


# --- Búfer ------------------------------------------------------------------------------------

func test_primary_buffer_holds_for_8_ticks() -> void:
	# Durante la esquiva solo se puede atacar desde el tick 18.
	for press_at: int in [9, 10, 17]:
		var d := Driver.new()
		var start: int = d.tick + 1
		d.step(DODGE)
		d.hold(0, press_at - 1)
		d.step(PRIMARY)
		assert_eq(d.tick, start + press_at, "(%d) pulsación" % press_at)
		assert_eq(d.c.action, Action.DODGE, "(%d) no se puede atacar todavía" % press_at)
		assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "(%d) va al búfer" % press_at)
		d.idle_until_before(start + 18)
		d.step()
		if press_at >= 10:
			assert_eq(d.c.action, Action.LIGHT, "(%d) el búfer ejecuta el ataque al poder" % press_at)
			assert_eq(d.c.action_tick, start + 18, "(%d) en el primer tick en que se puede" % press_at)
			assert_eq(d.c.buffered, 0, "(%d) y se vacía" % press_at)
		else:
			assert_eq(d.c.action, Action.DODGE, "(%d) 9 ticks de espera son demasiados" % press_at)
			assert_eq(d.c.buffered, 0, "(%d) el búfer caducó" % press_at)


func test_buffered_press_has_priority_over_new_inputs() -> void:
	# Un ataque guardado sale antes que una esquiva nueva del mismo tick.
	var d := Driver.new()
	var start: int = d.tick + 1
	d.step(DODGE)
	d.hold(0, 9)
	d.step(PRIMARY)
	d.idle_until_before(start + 18)
	d.step(DODGE)
	assert_eq(d.c.action, Action.LIGHT, "el ataque guardado ejecuta primero")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_DODGE, "y la esquiva nueva espera en el búfer")


func test_a_newer_press_replaces_the_buffered_one() -> void:
	var d := Driver.new()
	d.step(DODGE)
	d.step(PRIMARY)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "PRIMARY en el búfer")
	d.step()
	d.step(DODGE)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_DODGE, "la última pulsación sustituye a la anterior")
	assert_eq(d.c.buffered_ticks(), 8, "con sus 8 ticks")


func test_no_attack_or_dodge_in_the_air() -> void:
	var d := Driver.new()
	d.grounded = false
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.NONE, "no se ataca en el aire")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "la pulsación espera en el búfer")
	d.step(0)
	d.step(DODGE)
	assert_eq(d.c.action, Action.NONE, "no se esquiva en el aire")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_DODGE, "la esquiva espera en el búfer")
	d.step()
	d.step(BLOCK)
	assert_eq(d.c.action, Action.NONE, "ni se bloquea en el aire")
	# Al aterrizar a tiempo, lo guardado se ejecuta.
	d.grounded = true
	d.step(BLOCK)
	assert_eq(d.c.action, Action.DODGE, "al aterrizar, la esquiva guardada sale")
	assert_eq(d.c.stamina, 700, "y cuesta 300")
	assert_eq(d.c.parry_ready_tick, 0, "(el bloqueo que se mantenía no abrió ventana)")

	# Si no aterriza a tiempo, caduca.
	var e := Driver.new()
	e.grounded = false
	e.step(PRIMARY)
	e.hold(0, 9)
	e.grounded = true
	e.step()
	assert_eq(e.c.action, Action.NONE, "tras 9 ticks en el aire, la pulsación caducó")


func test_blocking_is_cancelled_when_leaving_the_ground() -> void:
	var d := Driver.new()
	d.step(BLOCK)
	assert_eq(d.c.action, Action.BLOCK, "bloqueando")
	var ready: int = d.c.parry_ready_tick
	d.grounded = false
	d.step(BLOCK)
	assert_eq(d.c.action, Action.NONE, "saltar o caer deja el bloqueo")
	d.grounded = true
	d.step(BLOCK)
	assert_eq(d.c.action, Action.BLOCK, "y al aterrizar con el botón pulsado, vuelve a bloquear")
	assert_eq(d.c.parry_ready_tick, ready, "sin parada nueva, porque no es un flanco")
	assert_false(ActionMachine.is_parry_window(d.c, d.tick), "ni ventana")


# --- Cancelación a esquiva --------------------------------------------------------------------

func test_dodge_cancels_an_attack_only_from_the_cancel_point() -> void:
	# El primer ligero se puede cancelar a esquiva desde rel 24. La pulsación vale 8 ticks.
	for press_rel: int in [5, 15, 16, 23, 24, 30]:
		var d := Driver.new()
		var p: int = d.tick + 1
		d.step(PRIMARY)
		d.hold(0, press_rel - 1)
		d.step(DODGE)
		assert_eq(d.tick, p + press_rel, "(%d) pulsación de esquiva" % press_rel)
		if press_rel >= 24:
			assert_eq(d.c.action, Action.DODGE, "(%d) desde el tick 24 cancela al instante" % press_rel)
			assert_eq(d.c.action_tick, p + press_rel, "(%d) action_tick" % press_rel)
			continue
		assert_eq(d.c.action, Action.LIGHT, "(%d) antes del tick 24 el ataque sigue" % press_rel)
		d.idle_until_before(p + 24)
		d.step()
		if press_rel >= 16:
			assert_eq(d.c.action, Action.DODGE, "(%d) la pulsación guardada cancela en el tick 24" % press_rel)
			assert_eq(d.c.action_tick, p + 24, "(%d) justo en el punto de cancelación" % press_rel)
			assert_eq(d.c.stamina, 700, "(%d) y gasta 300" % press_rel)
		else:
			assert_eq(d.c.action, Action.LIGHT, "(%d) la pulsación caducó antes" % press_rel)
			assert_eq(d.c.stamina, 1000, "(%d) sin gasto" % press_rel)


func test_dodge_cancels_a_charge_and_a_block() -> void:
	var d := Driver.new()
	d.hold(PRIMARY, 12)
	assert_eq(d.c.action, Action.CHARGE, "cargando")
	d.step(DODGE)
	assert_eq(d.c.action, Action.DODGE, "se puede esquivar cargando")
	assert_eq(d.c.stamina, 700, "solo se paga la esquiva")
	var e := Driver.new()
	e.step(BLOCK)
	e.step(BLOCK | DODGE)
	assert_eq(e.c.action, Action.DODGE, "y bloqueando")


func test_attack_cancels_the_dodge_only_from_the_cancel_point() -> void:
	var d := Driver.new()
	var start: int = d.tick + 1
	d.step(DODGE)
	d.idle_until_before(start + 17)
	d.step(PRIMARY)
	assert_eq(d.tick, start + 17, "pulsación en el tick 17")
	assert_eq(d.c.action, Action.DODGE, "sigue la esquiva")
	d.step()
	assert_eq(d.tick, start + 18, "tick 18")
	assert_eq(d.c.action, Action.LIGHT, "se puede cancelar a ataque desde el tick 18")
	assert_eq(d.c.action_tick, start + 18, "el ataque empieza ahí")
	assert_eq(d.c.combo_step, 1, "es el ligero 1")
	# Directamente en el tick 18 también.
	var e := Driver.new()
	var s2: int = e.tick + 1
	e.step(DODGE)
	e.idle_until_before(s2 + 18)
	e.step(PRIMARY)
	assert_eq(e.c.action, Action.LIGHT, "pulsar justo en el tick 18 ataca al instante")


# --- Esquiva ----------------------------------------------------------------------------------

func test_dodge_phases_cost_and_invulnerability() -> void:
	var d := Driver.new()
	d.hold(0, 3)
	var start: int = d.tick + 1
	d.step(DODGE)
	assert_eq(d.c.action, Action.DODGE, "esquiva")
	assert_eq(d.c.action_tick, start, "action_tick")
	assert_eq(d.c.action_id, 0, "la esquiva no es un ataque")
	assert_eq(d.c.stamina, 700, "cuesta 300")
	assert_eq(d.c.stamina_regen_tick, start + 36, "y retrasa la regeneración 36 ticks")
	for rel: int in range(0, 29):
		if rel > 0:
			d.step()
		var tick: int = start + rel
		var invulnerable: bool = rel >= 3 and rel < 18
		if rel < 27:
			assert_eq(d.c.action, Action.DODGE, "rel %d: esquivando" % rel)
			assert_eq(ActionMachine.is_invulnerable(d.c, tick), invulnerable,
					"rel %d: invulnerable = %s" % [rel, invulnerable])
			assert_eq((ActionMachine.defense_flags(d.c, tick) & ActionMachine.DEFENSE_INVULNERABLE) != 0,
					invulnerable, "rel %d: bandera de invulnerabilidad" % rel)
			assert_false(d.out.allow_jump or d.out.allow_sprint, "rel %d: sin salto ni esprint" % rel)
		else:
			assert_eq(d.c.action, Action.NONE, "rel %d: acabó a los 27 ticks" % rel)
			assert_false(ActionMachine.is_invulnerable(d.c, tick), "rel %d: ya no" % rel)


func test_dodge_direction_is_relative_to_the_camera_and_saved() -> void:
	var cases: Array = [
		# [move, look_yaw, yaw esperado del movimiento, descripción]
		[Vector2(0.0, 1.0), 0.0, 0.0, "adelante"],
		[Vector2(1.0, 0.0), 0.0, -PI / 2.0, "a la derecha"],
		[Vector2(-1.0, 0.0), 0.0, PI / 2.0, "a la izquierda"],
		[Vector2(0.0, -1.0), 0.0, PI, "hacia atrás"],
		[Vector2.ZERO, 0.0, PI, "sin entrada: hacia atrás"],
		[Vector2(0.0, 1.0), 1.0, 1.0, "adelante con la cámara girada"],
		[Vector2(0.0, 0.0), 2.0, 2.0 + PI, "sin entrada con la cámara girada"],
		[Vector2(0.05, 0.05), 0.0, PI, "una entrada mínima cuenta como ninguna"],
		[Vector2(1.0, 1.0).normalized(), 0.5, 0.5 - PI / 4.0, "en diagonal"],
	]
	for case: Array in cases:
		var d := Driver.new()
		d.move = case[0]
		d.look_yaw = case[1]
		d.step(DODGE)
		assert_eq(d.c.action, Action.DODGE, "%s: esquiva" % case[3])
		var expected_steps: int = CombatState.quantize_yaw(case[2])
		assert_eq(d.c.action_dir, expected_steps, "%s: action_dir" % case[3])
		# Cambiar la entrada después no cambia la dirección guardada.
		var first_velocity: Vector3 = d.out.velocity
		assert_true(first_velocity.length() > 5.0, "%s: velocidad inicial impuesta" % case[3])
		d.move = Vector2(-1.0, 0.0)
		d.look_yaw = 3.0
		d.step()
		assert_eq(d.c.action_dir, expected_steps, "%s: la dirección no cambia" % case[3])
		assert_near(d.out.velocity.normalized().dot(first_velocity.normalized()), 1.0, 1e-6,
				"%s: sigue en la misma dirección" % case[3])
	# Orientación concreta: adelante es -Z y la derecha es +X cuando se mira a -Z.
	var forward := Driver.new()
	forward.move = Vector2(0.0, 1.0)
	assert_vec_near(forward.step(DODGE).velocity.normalized(), Vector3(0.0, 0.0, -1.0), 1e-4,
			"adelante = -Z")
	var right := Driver.new()
	right.move = Vector2(1.0, 0.0)
	assert_vec_near(right.step(DODGE).velocity.normalized(), Vector3(1.0, 0.0, 0.0), 1e-4,
			"derecha = +X")


func test_dodge_velocity_follows_the_baked_curve() -> void:
	var d := Driver.new()
	d.move = Vector2(0.0, 1.0)
	var curve: PackedFloat32Array = _data.weapon(1).dodge.speeds
	var start: int = d.tick + 1
	for rel: int in 27:
		var out: ActionMachine.Output = d.step(DODGE if rel == 0 else 0)
		assert_true(out.forced_velocity, "rel %d: velocidad impuesta" % rel)
		assert_near(out.velocity.length(), curve[rel], 1e-4, "rel %d: velocidad de la curva" % rel)
		assert_eq(out.velocity.y, 0.0, "rel %d: horizontal" % rel)
		assert_eq(out.turn_rate, 0.0, "rel %d: el cuerpo conserva su yaw" % rel)
	assert_eq(d.tick, start + 26, "último tick")
	assert_false(d.step().forced_velocity, "tras la esquiva ya no se impone nada")


func test_dodge_needs_stamina_and_does_not_work_exhausted() -> void:
	var d := Driver.new()
	d.set_stamina(299)
	var out: ActionMachine.Output = d.step(DODGE)
	assert_eq(d.c.action, Action.NONE, "con 299 de resistencia no hay esquiva")
	assert_true((d.c.combat_flags & CombatState.FLAG_NO_STAMINA) != 0, "se avisa a la interfaz")
	assert_eq(d.c.buffered, 0, "y la pulsación no se guarda")
	assert_eq(out.move_scale, 1.0, "sin efectos")
	d.step()
	assert_eq(d.c.combat_flags & CombatState.FLAG_NO_STAMINA, 0, "el aviso dura un tick")
	var e := Driver.new()
	e.set_stamina(300)
	e.step(DODGE)
	assert_eq(e.c.action, Action.DODGE, "con 300 sí")
	assert_eq(e.c.stamina, 0, "se queda en 0")
	assert_true(e.c.is_exhausted(), "llegar a 0 agota")


# --- Bloqueo y parada -------------------------------------------------------------------------

func test_block_enters_and_leaves_with_the_button() -> void:
	var d := Driver.new()
	d.hold(0, 3)
	var out: ActionMachine.Output = d.step(BLOCK)
	assert_eq(d.c.action, Action.BLOCK, "BLOCK pulsado desde NONE bloquea")
	assert_true(ActionMachine.is_blocking(d.c, d.tick), "is_blocking()")
	assert_near(out.move_scale, 0.5, 1e-9, "movimiento ×0,5")
	assert_near(out.turn_rate, 8.0, 1e-9, "giro de 8 rad/s")
	assert_true(out.allow_jump, "se puede saltar")
	assert_false(out.allow_sprint, "pero no esprintar")
	assert_true(out.scaled_movement, "movimiento escalado")
	d.hold(BLOCK, 20)
	assert_eq(d.c.action, Action.BLOCK, "mientras se mantiene")
	assert_true((ActionMachine.defense_flags(d.c, d.tick) & ActionMachine.DEFENSE_BLOCKING) != 0,
			"bandera de bloqueo")
	d.step()
	assert_eq(d.c.action, Action.NONE, "soltar BLOCK sale del bloqueo")
	assert_eq(ActionMachine.defense_flags(d.c, d.tick), 0, "sin banderas")


func test_parry_window_only_on_a_real_edge_and_with_cooldown() -> void:
	var d := Driver.new()
	d.hold(0, 5)
	var p: int = d.tick + 1
	d.step(BLOCK)
	assert_eq(d.c.parry_ready_tick, p + 30, "el enfriamiento llega a los 30 ticks")
	for rel: int in range(0, 12):
		if rel > 0:
			d.step(BLOCK)
		var in_window: bool = rel < 6
		assert_eq(ActionMachine.is_parry_window(d.c, p + rel), in_window,
				"rel %d: ventana de parada = %s" % [rel, in_window])
		assert_eq((ActionMachine.defense_flags(d.c, p + rel) & ActionMachine.DEFENSE_PARRY) != 0,
				in_window, "rel %d: bandera de parada" % rel)
	# Soltar y volver a pulsar antes de que acabe el enfriamiento: bloquea pero sin parada.
	d.step(0)
	assert_eq(d.c.action, Action.NONE, "soltado")
	d.step(BLOCK)
	assert_eq(d.c.action, Action.BLOCK, "vuelve a bloquear")
	assert_false(ActionMachine.is_parry_window(d.c, d.tick), "pero sin ventana de parada (enfriamiento)")
	assert_eq(d.c.parry_ready_tick, p + 30, "y el enfriamiento no se reinicia")
	# Pasado el enfriamiento, un flanco nuevo abre otra ventana.
	d.step(0)
	d.idle_until_before(p + 30)
	d.step(BLOCK)
	assert_eq(d.tick, p + 30, "justo cuando acaba el enfriamiento")
	assert_true(ActionMachine.is_parry_window(d.c, d.tick), "se abre otra ventana")
	assert_eq(d.c.parry_ready_tick, p + 60, "y un nuevo enfriamiento")


func test_a_block_that_starts_when_an_action_ends_has_no_parry_window() -> void:
	# Bloqueo mantenido durante una esquiva: al acabar entra en BLOCK sin flanco.
	var d := Driver.new()
	var start: int = d.tick + 1
	d.step(DODGE | BLOCK)
	assert_eq(d.c.action, Action.DODGE, "esquivando")
	d.idle_until_before(start + 26)
	d.hold(BLOCK, 1)
	d.step(BLOCK)
	assert_eq(d.tick, start + 27, "al acabar la esquiva")
	assert_eq(d.c.action, Action.BLOCK, "entra en BLOCK")
	assert_false(ActionMachine.is_parry_window(d.c, d.tick), "sin ventana de parada")
	assert_eq(d.c.parry_ready_tick, 0, "ni enfriamiento")
	# Y un ataque con BLOCK pulsado durante todo él, igual.
	var e := Driver.new()
	e.step(PRIMARY | BLOCK)
	assert_eq(e.c.action, Action.LIGHT, "el ataque tiene prioridad sobre el bloqueo")
	e.hold(BLOCK, 40)
	assert_eq(e.c.action, Action.BLOCK, "al acabar el ataque, bloquea")
	assert_eq(e.c.parry_ready_tick, 0, "sin parada")


func test_blocking_can_be_cancelled_by_an_attack() -> void:
	var d := Driver.new()
	d.step(BLOCK)
	d.hold(BLOCK, 5)
	d.step(BLOCK | PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "se puede atacar bloqueando")
	assert_eq(ActionMachine.defense_flags(d.c, d.tick), 0, "y atacar deja de proteger")


func test_block_does_not_start_while_exhausted() -> void:
	var d := Driver.new()
	ActionMachine.drain_stamina(d.c, 1000, d.tick)
	assert_true(d.c.is_exhausted(), "agotado")
	d.hold(BLOCK, 10)
	assert_eq(d.c.action, Action.NONE, "agotado no se bloquea")


# --- Resistencia ------------------------------------------------------------------------------

func test_stamina_regenerates_after_the_delay() -> void:
	var d := Driver.new()
	d.hold(0, 2)
	var x: int = d.tick
	ActionMachine.drain_stamina(d.c, 400, x)
	assert_eq(d.c.stamina, 600, "gasto de 400")
	assert_eq(d.c.stamina_regen_tick, x + 36, "retardo de 0,6 s = 36 ticks")
	for rel: int in range(1, 36):
		d.step()
		assert_eq(d.c.stamina, 600, "rel %d: aún en el retardo" % rel)
	d.step()
	assert_eq(d.tick, x + 36, "primer tick de regeneración")
	assert_eq(d.c.stamina, 603, "+3 por tick (180/s)")
	d.step()
	assert_eq(d.c.stamina, 606, "+3")
	d.hold(0, 200)
	assert_eq(d.c.stamina, 1000, "sin pasarse del máximo")
	# Un gasto nuevo durante el retardo lo reinicia.
	ActionMachine.drain_stamina(d.c, 100, d.tick)
	d.hold(0, 20)
	ActionMachine.drain_stamina(d.c, 100, d.tick)
	assert_eq(d.c.stamina_regen_tick, d.tick + 36, "cada gasto reinicia el retardo")


func test_stamina_does_not_regenerate_while_blocking_or_dodging() -> void:
	var d := Driver.new()
	ActionMachine.drain_stamina(d.c, 500, d.tick)
	d.hold(BLOCK, 100)
	assert_eq(d.c.action, Action.BLOCK, "bloqueando")
	assert_eq(d.c.stamina, 500, "bloquear no regenera")
	d.step()
	assert_eq(d.c.stamina, 500, "(soltar: el tick de salida aún pasa por BLOCK)")
	d.step()
	assert_eq(d.c.stamina, 503, "fuera del bloqueo vuelve a regenerar")
	# Esquivando: la regeneración (desbloqueada a mano) tampoco avanza.
	var e := Driver.new()
	e.step(DODGE)
	e.c.stamina_regen_tick = 0
	var before: int = e.c.stamina
	e.hold(0, 10)
	assert_eq(e.c.action, Action.DODGE, "esquivando")
	assert_eq(e.c.stamina, before, "esquivar no regenera")


func test_exhaustion_and_exit_by_threshold() -> void:
	var d := Driver.new()
	d.hold(0, 2)
	var x: int = d.tick
	ActionMachine.drain_stamina(d.c, 1000, x)
	assert_eq(d.c.stamina, 0, "a 0")
	assert_true(d.c.is_exhausted(), "agotado al llegar a 0")
	# Agotado: sin esquiva ni bloqueo; los ligeros sí.
	d.step(DODGE)
	assert_eq(d.c.action, Action.NONE, "sin esquiva")
	assert_true((d.c.combat_flags & CombatState.FLAG_NO_STAMINA) != 0, "con aviso")
	d.step(BLOCK)
	assert_eq(d.c.action, Action.NONE, "sin bloqueo")
	d.step(0)
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "un ligero se puede hacer agotado")
	d.hold(0, 40)
	# Regeneración lenta (1 por tick) desde el tick x + 36.
	assert_true(d.tick >= x + 36, "pasado el retardo")
	var base_tick: int = x + 35
	assert_eq(d.c.stamina, d.tick - base_tick, "1 por tick estando agotado")
	while d.tick < x + 335:
		d.step()
	assert_eq(d.c.stamina, 300, "300 en el tick x + 335")
	assert_true(d.c.is_exhausted(), "300 no supera el umbral")
	d.step()
	assert_eq(d.tick, x + 336, "tick x + 336")
	assert_eq(d.c.stamina, 301, "301")
	assert_false(d.c.is_exhausted(), "al superar 300 se sale del agotamiento")
	d.step()
	assert_eq(d.c.stamina, 304, "y vuelve a regenerar 3 por tick")
	d.hold(0, 2)
	d.step(DODGE)
	assert_eq(d.c.action, Action.DODGE, "ya se puede esquivar")


func test_heavy_charge_needs_stamina_and_no_exhaustion() -> void:
	var d := Driver.new()
	d.set_stamina(149)
	d.hold(PRIMARY, 12)
	assert_eq(d.c.action, Action.LIGHT, "con 149 de resistencia no se pasa a carga")
	var e := Driver.new()
	ActionMachine.drain_stamina(e.c, 1000, e.tick)
	e.set_stamina(200)
	assert_true(e.c.is_exhausted(), "agotado con 200")
	e.hold(PRIMARY, 12)
	assert_eq(e.c.action, Action.LIGHT, "agotado tampoco carga")
	var f := Driver.new()
	f.set_stamina(150)
	f.hold(PRIMARY, 8)
	assert_eq(f.c.action, Action.CHARGE, "con 150 justas sí")


func test_infinite_stamina_flag_spends_nothing() -> void:
	var d := Driver.new()
	d.c.combat_flags |= CombatState.FLAG_INFINITE_STAMINA
	d.set_stamina(10)
	d.step(DODGE)
	assert_eq(d.c.action, Action.DODGE, "con resistencia infinita se esquiva siempre")
	assert_eq(d.c.stamina, 10, "y no se gasta")
	ActionMachine.drain_stamina(d.c, 500, d.tick)
	assert_eq(d.c.stamina, 10, "ni drain_stamina")


# --- Lo que impone el servidor ----------------------------------------------------------------

func test_impose_stagger_with_linearly_decaying_knockback() -> void:
	var d := Driver.new()
	d.hold(0, 3)
	var s: int = d.tick
	ActionMachine.impose_stagger(d.c, s, s + 30, Vector2(4.0, -2.0))
	assert_eq(d.c.action, Action.STAGGER, "tambaleo")
	assert_eq(d.c.action_tick, s, "action_tick")
	assert_eq(d.c.cc_until_tick, s + 30, "cc_until_tick")
	assert_eq(d.c.knockback, Vector2(4.0, -2.0), "empuje")
	for rel: int in range(1, 30):
		var out: ActionMachine.Output = d.step()
		assert_eq(d.c.action, Action.STAGGER, "rel %d: tambaleándose" % rel)
		assert_true(out.forced_velocity, "rel %d: la velocidad se impone" % rel)
		var factor: float = (30.0 - rel) / 30.0
		assert_near(out.velocity.x, 4.0 * factor, 1e-5, "rel %d: x decae linealmente" % rel)
		assert_near(out.velocity.z, -2.0 * factor, 1e-5, "rel %d: z decae linealmente" % rel)
		assert_false(out.allow_jump or out.allow_sprint, "rel %d: sin salto ni esprint" % rel)
		assert_eq(out.turn_rate, 0.0, "rel %d: no gira" % rel)
	var after: ActionMachine.Output = d.step()
	assert_eq(d.tick, s + 30, "en cc_until_tick")
	assert_eq(d.c.action, Action.NONE, "termina en cc_until_tick")
	assert_false(after.forced_velocity, "y ya no impone nada")


func test_impose_stagger_without_knockback_just_brakes() -> void:
	var d := Driver.new()
	ActionMachine.impose_stagger(d.c, d.tick, d.tick + 20, Vector2.ZERO)
	var out: ActionMachine.Output = d.step()
	assert_false(out.forced_velocity, "sin empuje no se fuerza la velocidad")
	assert_eq(out.move_scale, 0.0, "el objetivo es parar")
	assert_false(out.allow_jump, "sin saltar")


func test_impose_stagger_quantizes_the_knockback() -> void:
	var d := Driver.new()
	ActionMachine.impose_stagger(d.c, d.tick, d.tick + 20, Vector2(1.2349, 0.0049))
	assert_eq(d.c.knockback, Vector2(1.23, 0.0), "se redondea a cm/s, como al pasar por la red")
	var round_trip: CombatState = _round_trip(d.c)
	assert_true(round_trip.equals(d.c), "y el estado sobrevive al encode()")
	assert_eq(round_trip.knockback, d.c.knockback, "con el mismo empuje exacto")


func test_impose_clears_buffer_held_and_combo() -> void:
	var d := Driver.new()
	d.step(PRIMARY)
	d.hold(0, 30)
	d.step(PRIMARY)
	assert_ne_int(d.c.combo_step, 0, "hay combo en curso")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_LINK, "y un enlace guardado")
	ActionMachine.impose_stagger(d.c, d.tick, d.tick + 20, Vector2.ZERO)
	assert_eq(d.c.buffered, 0, "el búfer se borra")
	assert_eq(d.c.primary_held, 0, "la pulsación se borra")
	assert_eq(d.c.combo_step, 0, "y el combo")
	assert_eq(d.c.action_id, 0, "y la acción deja de ser un ataque")
	# Cortar una carga: el botón sigue pulsado pero no hay ataque al acabar el control.
	var e := Driver.new()
	e.hold(PRIMARY, 12)
	assert_eq(e.c.action, Action.CHARGE, "cargando")
	ActionMachine.impose_stagger(e.c, e.tick, e.tick + 10, Vector2.ZERO)
	e.hold(PRIMARY, 30)
	assert_eq(e.c.action, Action.NONE, "tras el tambaleo no se reanuda ni se lanza nada")
	assert_eq(e.c.stamina, 1000, "y no se gastó resistencia")


func test_stagger_cuts_a_light_attack() -> void:
	var d := Driver.new()
	d.step(PRIMARY)
	d.hold(0, 10)
	assert_eq(d.c.action, Action.LIGHT, "atacando")
	ActionMachine.impose_stagger(d.c, d.tick, d.tick + 18, Vector2.ZERO)
	d.hold(0, 5)
	assert_eq(d.c.action, Action.STAGGER, "el tambaleo corta el golpe")
	assert_false(ActionMachine.is_attack_active(d.c, d.tick), "que ya no golpea")
	d.hold(0, 13)
	assert_eq(d.c.action, Action.NONE, "y al acabar vuelve a NONE")


func test_impose_stun_and_inputs_during_control() -> void:
	var d := Driver.new()
	ActionMachine.impose_stun(d.c, d.tick, d.tick + 60)
	assert_eq(d.c.action, Action.STUN, "aturdido")
	assert_eq(d.c.knockback, Vector2.ZERO, "sin empuje")
	var out: ActionMachine.Output = d.step(PRIMARY | DODGE | BLOCK)
	assert_eq(d.c.action, Action.STUN, "las entradas no hacen nada")
	assert_eq(out.move_scale, 0.0, "solo frena")
	assert_false(out.forced_velocity, "sin velocidad impuesta")
	assert_false(out.allow_jump, "sin saltar")
	assert_eq(d.c.stamina, 1000, "y sin gastar")
	# Lo pulsado durante el control espera en el búfer unos ticks.
	assert_ne_int(d.c.buffered, 0, "lo pulsado durante el control queda guardado")
	d.hold(0, 59)
	assert_eq(d.c.action, Action.NONE, "el aturdimiento termina en cc_until_tick")
	assert_eq(d.c.buffered, 0, "y lo guardado caducó")


func test_impose_death_and_respawn() -> void:
	var d := Driver.new()
	d.step(PRIMARY)
	ActionMachine.drain_stamina(d.c, 300, d.tick)
	d.c.action_dir = 777
	ActionMachine.impose_death(d.c, d.tick)
	assert_eq(d.c.action, Action.DEAD, "muerto")
	assert_eq(d.c.action_id, 0, "sin ataque")
	assert_eq(ActionMachine.defense_flags(d.c, d.tick), ActionMachine.DEFENSE_DEAD, "bandera de muerto")
	var out: ActionMachine.Output = d.step(PRIMARY | DODGE | BLOCK)
	assert_eq(d.c.action, Action.DEAD, "los muertos no actúan")
	assert_eq(d.c.buffered, 0, "ni guardan pulsaciones")
	assert_eq(out.move_scale, 0.0, "frena")
	assert_false(out.allow_jump, "no salta")
	ActionMachine.reset_for_respawn(d.c, d.tick)
	assert_eq(d.c.action, Action.NONE, "reaparece sin acción")
	assert_eq(d.c.stamina, 1000, "con la resistencia llena")
	assert_eq(d.c.weapon_id, CombatCatalog.default_weapon_id(), "conserva el arma")
	assert_eq(d.c.cc_until_tick, 0, "sin control")
	assert_eq(d.c.knockback, Vector2.ZERO, "sin empuje")
	assert_eq(d.c.parry_ready_tick, 0, "sin enfriamiento de parada")
	assert_false(d.c.is_exhausted(), "sin agotamiento")
	# Los niveles de los botones se conservan: PRIMARY|DODGE|BLOCK siguen pulsados, sin flancos.
	d.step(PRIMARY | DODGE | BLOCK)
	assert_eq(d.c.action, Action.BLOCK, "con los botones aún pulsados no hay flancos: solo el bloqueo a nivel")
	assert_false(ActionMachine.is_parry_window(d.c, d.tick), "sin parada")


func test_drain_stamina() -> void:
	var d := Driver.new()
	ActionMachine.drain_stamina(d.c, 250, d.tick)
	assert_eq(d.c.stamina, 750, "resta")
	assert_eq(d.c.stamina_regen_tick, d.tick + 36, "y retrasa la regeneración")
	assert_false(d.c.is_exhausted(), "sin agotarse")
	ActionMachine.drain_stamina(d.c, 5000, d.tick)
	assert_eq(d.c.stamina, 0, "nunca baja de 0")
	assert_true(d.c.is_exhausted(), "y a 0 agota")
	var before: CombatState = d.c.duplicate_state()
	ActionMachine.drain_stamina(d.c, 0, d.tick + 5)
	ActionMachine.drain_stamina(d.c, -10, d.tick + 5)
	assert_true(d.c.equals(before), "un gasto de 0 o negativo no hace nada")


# --- Consultas --------------------------------------------------------------------------------

func test_action_byte() -> void:
	var d := Driver.new()
	assert_eq(ActionMachine.action_byte(d.c, d.tick), Action.NONE | (3 << 4),
			"NONE: sin fases = 3")
	var p: int = d.tick + 1
	d.step(PRIMARY)
	assert_eq(ActionMachine.action_byte(d.c, p), Action.LIGHT | (0 << 4) | (0 << 6),
			"primer ligero, anticipación")
	d.hold(0, 12)
	assert_eq(ActionMachine.action_byte(d.c, p + 12), Action.LIGHT | (1 << 4) | (0 << 6),
			"primer ligero, golpe activo")
	d.hold(0, 6)
	assert_eq(ActionMachine.action_byte(d.c, p + 18), Action.LIGHT | (2 << 4) | (0 << 6),
			"primer ligero, recuperación")
	# Segundo ligero.
	d.step(PRIMARY)
	d.idle_until_before(p + 36)
	d.step()
	assert_eq(d.c.action_id, _light_id(1), "segundo ligero")
	assert_eq(ActionMachine.action_byte(d.c, d.tick), Action.LIGHT | (0 << 4) | (1 << 6),
			"el paso del combo va en los bits 6-7")
	# Tercero.
	var e := Driver.new()
	e.step(PRIMARY)
	e.hold(0, 40)
	e.c.combo_step = 2
	e.step(PRIMARY)
	assert_eq(ActionMachine.action_byte(e.c, e.tick), Action.LIGHT | (0 << 4) | (2 << 6), "tercero")
	# Fuerte, bloqueo, esquiva.
	var f := Driver.new()
	f.hold(PRIMARY, 8)
	assert_eq(ActionMachine.action_byte(f.c, f.tick), Action.CHARGE | (0 << 4), "carga: fase 0")
	f.hold(PRIMARY, 14)
	f.step()
	assert_eq(f.c.action, Action.HEAVY, "lanzado")
	assert_eq(ActionMachine.action_byte(f.c, f.tick), Action.HEAVY | (0 << 4) | (0 << 6),
			"fuerte, anticipación (no usa el paso de combo)")
	var g := Driver.new()
	g.step(BLOCK)
	assert_eq(ActionMachine.action_byte(g.c, g.tick), Action.BLOCK | (3 << 4), "bloqueo: sin fases = 3")
	var h := Driver.new()
	h.step(DODGE)
	assert_eq(ActionMachine.action_byte(h.c, h.tick), Action.DODGE | (3 << 4), "esquiva: sin fases = 3")
	assert_true(ActionMachine.action_byte(h.c, h.tick) <= 255, "cabe en un byte")


func test_queries_use_the_catalog_of_the_weapon() -> void:
	var c := CombatState.new()
	c.weapon_id = 99
	c.action = Action.DODGE
	assert_false(ActionMachine.is_invulnerable(c, 5), "un arma que no existe no da invulnerabilidad")
	c.action = Action.LIGHT
	c.action_id = 99
	assert_eq(ActionMachine.phase(c, 5), ActionMachine.PHASE_NONE, "un ataque que no existe no tiene fases")
	assert_false(ActionMachine.is_attack_active(c, 5), "ni golpea")
	assert_eq(ActionMachine.action_byte(c, 5), Action.LIGHT | (3 << 4), "action_byte no falla")


func test_a_state_with_unknown_weapon_or_attack_does_not_crash() -> void:
	var d := Driver.new()
	d.c.weapon_id = 0
	d.hold(PRIMARY | DODGE | BLOCK, 5)
	assert_eq(d.c.action, Action.NONE, "sin arma no se ataca, esquiva ni bloquea")
	var e := Driver.new()
	e.c.action = Action.LIGHT
	e.c.action_id = 200
	e.c.action_tick = e.tick
	e.step()
	assert_eq(e.c.action, Action.NONE, "un ataque desconocido se descarta")


# --- Determinismo de la máquina sola ----------------------------------------------------------

func test_machine_replay_from_any_tick_gives_the_same_state() -> void:
	var inputs: Array[int] = _combat_buttons()
	var reference := Driver.new()
	reference.move = Vector2(0.2, 1.0)
	var states: Array[PackedByteArray] = []
	for i: int in inputs.size():
		states.append(_bytes(reference.c))
		reference.step(inputs[i] & 0xFFFF, (inputs[i] & PlayerInput.SUBSTITUTED) != 0)
	states.append(_bytes(reference.c))
	var actions_seen: Dictionary[int, bool] = {}
	for i: int in range(0, inputs.size(), 2):
		var replay := Driver.new()
		replay.move = Vector2(0.2, 1.0)
		replay.c = _round_trip(_state_from(states[i]))
		replay.tick = START_TICK + i
		for j: int in range(i, inputs.size()):
			replay.step(inputs[j] & 0xFFFF, (inputs[j] & PlayerInput.SUBSTITUTED) != 0)
			actions_seen[replay.c.action] = true
			if _bytes(replay.c) != states[j + 1]:
				fail("repetir desde el tick %d diverge en el %d:\n  esperado %s\n  obtenido %s" % [
					i, j, _state_from(states[j + 1]), replay.c,
				])
				return
	for action: int in [Action.LIGHT, Action.HEAVY, Action.CHARGE, Action.BLOCK, Action.DODGE]:
		assert_true(actions_seen.has(action), "el guion pasa por la acción %d" % action)


# --- Con física: movimiento -------------------------------------------------------------------

func test_dodge_travels_the_baked_distance_on_flat_ground() -> void:
	var rig: Dictionary = await _make_rig("Esquiva")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 10.0), 0.0)
	var directions: Array = [
		[Vector2(0.0, 1.0), Vector3(0.0, 0.0, -1.0), "adelante"],
		[Vector2(1.0, 0.0), Vector3(1.0, 0.0, 0.0), "derecha"],
		[Vector2(0.0, -1.0), Vector3(0.0, 0.0, 1.0), "atrás"],
		[Vector2.ZERO, Vector3(0.0, 0.0, 1.0), "sin entrada"],
	]
	for case: Array in directions:
		await _teleport(character, Vector3(0.0, 0.0, 10.0), 0.0)
		var start: Vector3 = character.global_position
		var yaw_before: float = character.yaw
		tick = await _next_tick(character, tick)
		var dodge := _input(tick, case[0], 0.0, DODGE)
		character.simulate(dodge, _dt)
		assert_eq(character.combat.action, Action.DODGE, "%s: esquiva" % case[2])
		for _i: int in 26:
			tick += 1
			character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
		for _i: int in 20:
			tick += 1
			character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
		assert_eq(character.combat.action, Action.NONE, "%s: la esquiva terminó" % case[2])
		var travelled: Vector3 = character.global_position - start
		assert_near(travelled.length(), 4.5, 0.05, "%s: recorre 4,5 m en suelo plano (%s)" % [case[2], travelled])
		assert_near(travelled.normalized().dot(case[1]), 1.0, 1e-3, "%s: en la dirección esperada" % case[2])
		assert_near(travelled.y, 0.0, 0.01, "%s: sin salirse del suelo" % case[2])
		assert_eq(character.yaw, yaw_before, "%s: el cuerpo conserva su yaw" % case[2])
		assert_true(character.get_horizontal_speed() < 0.01, "%s: acaba parado" % case[2])


func test_dodge_does_not_pass_through_walls() -> void:
	var rig: Dictionary = await _make_rig("MuroEsquiva")
	var viewport: SubViewport = rig["viewport"]
	# Muro del mundo (capa 1) delante, a 3 m, y un bloqueo del jugador (capa 3) a la derecha.
	_add_box(viewport, Vector3(10.0, 4.0, 1.0), Vector3(0.0, 2.0, 7.0), WORLD_LAYER)
	_add_box(viewport, Vector3(1.0, 4.0, 10.0), Vector3(4.0, 2.0, 15.0),
			PlayerCharacter.PLAYER_BLOCKER_LAYER)
	await wait_physics_frames(2)
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 10.0), 0.0)
	tick = await _next_tick(character, tick)
	character.simulate(_input(tick, Vector2(0.0, 1.0), 0.0, DODGE), _dt)
	for _i: int in 45:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
	# El muro ocupa z de 6,5 a 7,5; la cápsula tiene 0,4 de radio.
	assert_true(character.global_position.z >= 7.5 + 0.35, "no atraviesa el muro del mundo (z = %s)"
			% character.global_position.z)
	assert_true(character.global_position.z < 9.0, "pero sí se acerca (z = %s)" % character.global_position.z)
	assert_near(character.global_position.x, 0.0, 0.05, "sin desviarse")

	await _teleport(character, Vector3(0.0, 0.0, 12.0), 0.0)
	tick = await _next_tick(character, tick)
	character.simulate(_input(tick, Vector2(1.0, 0.0), 0.0, DODGE), _dt)
	for _i: int in 45:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
	assert_true(character.global_position.x <= 3.5 - 0.35 + 0.01, "no atraviesa el bloqueo del jugador (x = %s)"
			% character.global_position.x)
	assert_true(character.global_position.x > 2.0, "pero llega hasta él (x = %s)" % character.global_position.x)


func test_blocking_slows_the_character() -> void:
	var rig: Dictionary = await _make_rig("Bloqueo")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	# Sin bloquear: velocidad de carrera.
	tick = await _next_tick(character, tick)
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0.0, 0), _dt)
	assert_near(character.get_horizontal_speed(), character.run_speed, 0.05, "corriendo")
	# Bloqueando, la mitad; y esprintar no sirve.
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0.0, BLOCK), _dt)
	assert_eq(character.combat.action, Action.BLOCK, "bloqueando")
	assert_near(character.get_horizontal_speed(), character.run_speed * 0.5, 0.05, "×0,5 al bloquear")
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0.0, BLOCK | PlayerInput.SPRINT), _dt)
	assert_near(character.get_horizontal_speed(), character.run_speed * 0.5, 0.05, "sin esprintar")
	# Hacia atrás y de lado: también ×0,5 de la carrera (la tabla no añade más multiplicadores).
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, -1.0), 0.0, BLOCK), _dt)
	assert_near(character.get_horizontal_speed(), character.run_speed * 0.5, 0.05, "hacia atrás")
	# Soltar: vuelve a correr.
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0.0, 0), _dt)
	assert_near(character.get_horizontal_speed(), character.run_speed, 0.05, "sin bloquear de nuevo")
	assert_eq(character.combat.action, Action.NONE, "ya no bloquea")


func test_attacks_turn_toward_the_camera_even_when_standing_still() -> void:
	var rig: Dictionary = await _make_rig("Giro")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	tick = await _next_tick(character, tick)
	# Sin atacar, quieto: el cuerpo no gira hacia la cámara.
	for _i: int in 5:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 1.5, 0), _dt)
	assert_near(character.yaw, 0.0, 1e-6, "parado, sin ataque, el yaw no cambia")
	# El ligero hace saltar el yaw a la cámara en su primer tick.
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 1.5, PRIMARY), _dt)
	assert_near(character.yaw, 1.5, 1e-3, "el yaw salta a look_yaw")
	assert_eq(character.yaw, PlayerState.to_f32(character.yaw), "y está redondeado a f32")
	# Mientras ataca sigue girando hacia la cámara a 6 rad/s.
	for _i: int in 6:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, -0.5, 0), _dt)
	assert_near(character.yaw, 1.5 - 6.0 * 6.0 / 60.0, 0.02, "gira a 6 rad/s hacia la nueva cámara")
	# En la recuperación (a partir del tick 18) ya no gira.
	for _i: int in 12:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 3.0, 0), _dt)
	var yaw_at_recovery: float = character.yaw
	assert_eq(ActionMachine.phase(character.combat, tick), ActionMachine.PHASE_RECOVERY, "recuperación")
	for _i: int in 6:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 3.0, 0), _dt)
	assert_eq(character.yaw, yaw_at_recovery, "no gira en la recuperación")


func test_light_attack_lunges_forward_and_stops_in_recovery() -> void:
	var rig: Dictionary = await _make_rig("Avance")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	tick = await _next_tick(character, tick)
	var start: Vector3 = character.global_position
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 0.0, PRIMARY), _dt)
	var speeds: Array[float] = []
	for _i: int in 17:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
		speeds.append(character.get_horizontal_speed())
	assert_near(speeds[speeds.size() - 1], 1.5, 0.01, "avanza a 1,5 m/s al final del golpe activo")
	var advanced: float = start.z - character.global_position.z
	assert_true(advanced > 0.35 and advanced < 0.5, "avanza unos 0,4 m en 18 ticks (%s)" % advanced)
	assert_near(character.global_position.x, start.x, 1e-4, "y hacia delante")
	for _i: int in 6:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
	assert_true(character.get_horizontal_speed() < 0.01, "en la recuperación se frena (%s)"
			% character.get_horizontal_speed())


func test_cannot_jump_while_attacking_or_dodging_but_can_while_blocking() -> void:
	var rig: Dictionary = await _make_rig("Salto")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	tick = await _next_tick(character, tick)
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 0.0, PRIMARY), _dt)
	for _i: int in 4:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, PlayerInput.JUMP), _dt)
	assert_true(character.grounded and character.velocity.y <= 0.001, "atacando no se salta")
	# Esperar a que acabe el ataque y la pulsación de salto guardada caduque.
	for _i: int in 50:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
	assert_eq(character.combat.action, Action.NONE, "el ataque acabó")
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 0.0, DODGE), _dt)
	for _i: int in 4:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, PlayerInput.JUMP), _dt)
	assert_eq(character.combat.action, Action.DODGE, "esquivando")
	assert_true(character.grounded and character.velocity.y <= 0.001, "esquivando no se salta")
	for _i: int in 60:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
	# Bloqueando sí se salta, y saltar deja el bloqueo.
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 0.0, BLOCK), _dt)
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 0.0, BLOCK | PlayerInput.JUMP), _dt)
	assert_true(character.velocity.y > 5.0, "bloqueando se puede saltar (vy = %s)" % character.velocity.y)
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 0.0, BLOCK), _dt)
	assert_eq(character.combat.action, Action.NONE, "y al estar en el aire se deja el bloqueo")


## Velocidad horizontal tras [param ticks] ticks en el aire (30 m de altura, 7,5 m/s hacia -Z) con una
## acción impuesta ([param kind]: "none", "death", "stun" o "stagger") y el movimiento [param move].
## Devuelve la velocidad y el estado codificado del final.
func _air_run(character: PlayerCharacter, kind: String, move: Vector2, ticks: int) -> Dictionary:
	await wait_physics_frames(1)
	var start := PlayerState.new()
	start.position = Vector3(0.0, 30.0, 40.0)
	start.velocity = Vector3(0.0, 0.0, -7.5)
	start.grounded = false
	character.set_state(PlayerState.decode(start.encode()))
	character.reset_physics_interpolation()
	var tick: int = START_TICK
	match kind:
		"death":
			ActionMachine.impose_death(character.combat, tick)
		"stun":
			ActionMachine.impose_stun(character.combat, tick, tick + 600)
		"stagger":
			ActionMachine.impose_stagger(character.combat, tick, tick + 600, Vector2.ZERO)
	character.set_state(PlayerState.decode(character.get_state().encode()))
	for _i: int in ticks:
		tick += 1
		character.simulate(_input(tick, move, 0.0, 0), _dt)
	return {
		"velocity": Vector2(character.velocity.x, character.velocity.z),
		"bytes": character.get_state().encode(),
		"grounded": character.grounded,
	}


func test_a_dead_stunned_or_staggered_body_in_the_air_brakes_and_cannot_be_steered() -> void:
	# C4: con move_scale 0 la velocidad objetivo es 0, pero la rama del aire conservaba el impulso
	# empujando hacia delante (o lo giraba en diagonal). Frenar es lo que dice §3.3 (DEAD, STUN y
	# STAGGER sin empuje «frenan»).
	var rig: Dictionary = await _make_rig("AireControlado")
	var character: PlayerCharacter = rig["character"]
	await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	for kind: String in ["death", "stun", "stagger"]:
		var rest: Dictionary = await _air_run(character, kind, Vector2.ZERO, 30)
		assert_false(rest["grounded"], "(%s) sigue en el aire" % kind)
		var rest_velocity: Vector2 = rest["velocity"]
		assert_true(rest_velocity.length() < 7.5 - 2.0, "(%s) sin entrada frena (%s)" % [kind,
				rest_velocity])
		for move: Vector2 in [Vector2(0.0, 1.0), Vector2(0.7, 0.7), Vector2(-1.0, 0.0)]:
			var steered: Dictionary = await _air_run(character, kind, move, 30)
			var velocity: Vector2 = steered["velocity"]
			assert_vec_near(velocity, rest_velocity, 1e-5,
					"(%s) con move=%s la velocidad es la misma que sin entrada" % [kind, move])
			assert_eq(steered["bytes"], rest["bytes"],
					"(%s) con move=%s el estado codificado es el mismo" % [kind, move])
		# Determinista: repetir la misma entrada da los mismos bytes.
		var again: Dictionary = await _air_run(character, kind, Vector2.ZERO, 30)
		assert_eq(again["bytes"], rest["bytes"], "(%s) repetible byte a byte" % kind)
	# Control: sin ninguna acción, empujar hacia delante conserva el impulso en el aire.
	var free_rest: Dictionary = await _air_run(character, "none", Vector2.ZERO, 30)
	var free_forward: Dictionary = await _air_run(character, "none", Vector2(0.0, 1.0), 30)
	var free_velocity: Vector2 = free_forward["velocity"]
	assert_near(free_velocity.length(), 7.5, 0.01, "sin acción, W conserva los 7,5 m/s")
	var brake_velocity: Vector2 = free_rest["velocity"]
	assert_true(brake_velocity.length() < 5.0, "y sin entrada frena (%s)" % brake_velocity)


func test_last_landing_speed_is_measured_before_move_and_slide() -> void:
	var rig: Dictionary = await _make_rig("Caida")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	assert_eq(character.last_landing_speed, 0.0, "en reposo es 0")
	await _teleport(character, Vector3(0.0, 3.0, 40.0), 0.0, false)
	tick = await _next_tick(character, tick)
	var landing_speeds: Array[float] = []
	var landing_ticks: int = 0
	for _i: int in 90:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
		if character.last_landing_speed != 0.0:
			landing_speeds.append(character.last_landing_speed)
			landing_ticks += 1
			assert_true(character.grounded, "solo es distinto de 0 en el tick en que se toca el suelo")
	assert_eq(landing_ticks, 1, "un solo tick de aterrizaje")
	if landing_speeds.size() == 1:
		# Caída libre de unos 3 m con 22 m/s²: ~11,5 m/s justo antes de tocar el suelo.
		assert_true(landing_speeds[0] > 10.0 and landing_speeds[0] < 12.5,
				"velocidad de aterrizaje de unos 11,5 m/s (%s)" % landing_speeds[0])
	assert_eq(character.last_landing_speed, 0.0, "y después vuelve a 0")
	# Correr por el suelo nunca la activa.
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0.0, 0), _dt)
		assert_eq(character.last_landing_speed, 0.0, "andando es 0")


func test_character_state_includes_the_combat() -> void:
	var rig: Dictionary = await _make_rig("Estado")
	var character: PlayerCharacter = rig["character"]
	await wait_physics_frames(1)
	assert_true(character.combat.equals(CombatState.initial(CombatCatalog.rules(),
			CombatCatalog.default_weapon_id())), "el personaje empieza con el combate inicial")
	character.combat.stamina = 321
	character.combat.action = Action.BLOCK
	var state: PlayerState = character.get_state()
	assert_eq(state.combat.stamina, 321, "get_state() lleva el combate")
	character.combat.stamina = 5
	assert_eq(state.combat.stamina, 321, "y es una copia, no un alias")
	character.set_state(state)
	assert_eq(character.combat.stamina, 321, "set_state() lo restaura")
	assert_eq(character.combat.action, Action.BLOCK, "con la acción")
	state.combat.stamina = 7
	assert_eq(character.combat.stamina, 321, "sin compartir el objeto")


func test_prev_buttons_never_keeps_the_substituted_bit() -> void:
	var rig: Dictionary = await _make_rig("Sustituida")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	tick = await _next_tick(character, tick)
	var input := _input(tick, Vector2.ZERO, 0.0, BLOCK | PlayerInput.SUBSTITUTED)
	character.simulate(input, _dt)
	assert_eq(character.prev_buttons, BLOCK, "prev_buttons no guarda el bit 15")
	assert_eq(character.get_state().prev_buttons & PlayerInput.SUBSTITUTED, 0, "ni el estado")
	assert_eq(character.get_state().encode().decode_u16(29), BLOCK, "ni lo que viaja por la red")


# --- Con física: repetición determinista ------------------------------------------------------

func test_replay_from_mid_action_gives_the_same_encoded_state() -> void:
	# El guion pasa por combo, esquiva, bloqueo, carga del fuerte, entradas repetidas y un
	# tambaleo impuesto. Se graba en un mundo y se repite desde muchos ticks en otro distinto.
	var inputs: Array[PlayerInput] = _combat_script()
	var recorder: Dictionary = await _make_rig("Grabacion")
	var replayer: Dictionary = await _make_rig("Repeticion")
	var origin: Vector3 = Vector3(0.0, 0.0, 40.0)
	var first: PlayerCharacter = recorder["character"]
	var second: PlayerCharacter = replayer["character"]
	await _settle(first, origin, 0.0)
	await _settle(second, origin, 0.0)
	var start_state: PlayerState = PlayerState.decode(first.get_state().encode())
	var states: Array[PlayerState] = []
	var actions_seen: Dictionary[int, bool] = {}
	first.set_state(start_state)
	for i: int in inputs.size():
		states.append(PlayerState.decode(first.get_state().encode()))
		first.simulate(inputs[i], _dt)
		_apply_imposition(first, inputs[i].tick)
		actions_seen[first.combat.action] = true
	states.append(PlayerState.decode(first.get_state().encode()))
	for action: int in [Action.LIGHT, Action.HEAVY, Action.CHARGE, Action.BLOCK, Action.DODGE,
			Action.STAGGER]:
		assert_true(actions_seen.has(action), "el guion pasa por la acción %d" % action)
	assert_true(states[inputs.size()].position.distance_to(origin) > 3.0, "y el personaje se mueve")

	var mismatches: PackedStringArray = PackedStringArray()
	var replays: int = 0
	for from_tick: int in range(0, inputs.size(), 3):
		replays += 1
		second.set_state(states[from_tick])
		for i: int in range(from_tick, inputs.size()):
			second.simulate(inputs[i], _dt)
			_apply_imposition(second, inputs[i].tick)
			var expected: PackedByteArray = states[i + 1].encode()
			var actual: PackedByteArray = second.get_state().encode()
			if actual != expected:
				mismatches.append("desde %d diverge en %d: %s (esperado %s)" % [
					from_tick, i, second.get_state(), states[i + 1],
				])
				break
	assert_true(replays > 50, "se repitió desde %d ticks" % replays)
	assert_true(mismatches.is_empty(), "%d repeticiones divergen:\n  %s" % [
		mismatches.size(), "\n  ".join(mismatches.slice(0, 3)),
	])


func test_replay_from_mid_action_in_the_same_world() -> void:
	# Lo mismo en un solo mundo y pasando el estado por la red en cada punto de partida.
	var inputs: Array[PlayerInput] = _combat_script()
	var rig: Dictionary = await _make_rig("Mismo")
	var character: PlayerCharacter = rig["character"]
	var origin: Vector3 = Vector3(0.0, 0.0, 40.0)
	await _settle(character, origin, 0.0)
	var start_state: PlayerState = PlayerState.decode(character.get_state().encode())
	var states: Array[PlayerState] = []
	character.set_state(start_state)
	for i: int in inputs.size():
		states.append(PlayerState.decode(character.get_state().encode()))
		character.simulate(inputs[i], _dt)
		_apply_imposition(character, inputs[i].tick)
	states.append(PlayerState.decode(character.get_state().encode()))
	var bad: int = 0
	for from_tick: int in range(1, inputs.size(), 7):
		character.set_state(states[from_tick])
		for i: int in range(from_tick, inputs.size()):
			character.simulate(inputs[i], _dt)
			_apply_imposition(character, inputs[i].tick)
			if character.get_state().encode() != states[i + 1].encode():
				bad += 1
				break
	assert_eq(bad, 0, "ninguna repetición diverge")


# --- Utilidades -------------------------------------------------------------------------------

func _light_id(index: int) -> int:
	return _data.weapon(1).light_ids[index]


func _heavy_id() -> int:
	return _data.weapon(1).heavy_id


func assert_ne_int(actual: int, unexpected: int, message: String = "") -> bool:
	return assert_true(actual != unexpected, "%s (valor %d)" % [message, actual])


func _bytes(c: CombatState) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(CombatState.ENCODED_SIZE)
	c.encode_into(bytes, 0)
	return bytes


func _state_from(bytes: PackedByteArray) -> CombatState:
	return CombatState.decode_from(bytes, 0)


func _round_trip(c: CombatState) -> CombatState:
	return _state_from(_bytes(c))


## Botones guionizados (con la marca de sustitución en el bit 15) que recorren todas las
## acciones: combo de tres, esquiva, bloqueo con parada, carga del fuerte y un tramo de entradas
## repetidas.
func _combat_buttons() -> Array[int]:
	var buttons: Array[int] = []
	var sub: int = PlayerInput.SUBSTITUTED
	_append_ticks(buttons, 0, 10)
	# Combo: tres pulsaciones dentro de las ventanas.
	_append_ticks(buttons, PRIMARY, 1)
	_append_ticks(buttons, 0, 29)
	_append_ticks(buttons, PRIMARY, 1)
	_append_ticks(buttons, 0, 33)
	_append_ticks(buttons, PRIMARY, 1)
	_append_ticks(buttons, 0, 60)
	# Esquiva y ataque cancelando la esquiva.
	_append_ticks(buttons, DODGE, 1)
	_append_ticks(buttons, 0, 17)
	_append_ticks(buttons, PRIMARY, 1)
	_append_ticks(buttons, 0, 50)
	# Bloqueo con parada, soltar y volver a pulsar.
	_append_ticks(buttons, BLOCK, 20)
	_append_ticks(buttons, 0, 3)
	_append_ticks(buttons, BLOCK, 20)
	_append_ticks(buttons, 0, 10)
	# Carga del fuerte soltando antes de la mínima.
	_append_ticks(buttons, PRIMARY, 12)
	_append_ticks(buttons, 0, 80)
	# Carga con entradas repetidas en medio y esquiva en plena carga.
	_append_ticks(buttons, PRIMARY, 10)
	_append_ticks(buttons, PRIMARY | sub, 20)
	_append_ticks(buttons, PRIMARY, 15)
	_append_ticks(buttons, PRIMARY | DODGE, 1)
	_append_ticks(buttons, 0, 60)
	# Carga máxima con lanzamiento automático.
	_append_ticks(buttons, PRIMARY, 90)
	_append_ticks(buttons, 0, 40)
	return buttons


func _append_ticks(buttons: Array[int], mask: int, count: int) -> void:
	for _i: int in count:
		buttons.append(mask)


## El mismo guion como entradas cuantizadas (con movimiento y cámara) para el personaje real.
func _combat_script() -> Array[PlayerInput]:
	var buttons: Array[int] = _combat_buttons()
	var inputs: Array[PlayerInput] = []
	for i: int in buttons.size():
		var input := PlayerInput.new()
		input.tick = START_TICK + i
		input.buttons = buttons[i]
		input.move = Vector2(0.3, 1.0).limit_length(1.0) if i % 90 < 60 else Vector2.ZERO
		input.look_yaw = 0.35 * sin(float(i) / 40.0) + (0.5 if i > 300 else 0.0)
		inputs.append(input.quantized())
	return inputs


## Tambaleo impuesto por el servidor en un tick del guion (como lo haría tras un golpe).
func _apply_imposition(character: PlayerCharacter, tick: int) -> void:
	if tick == START_TICK + 290:
		ActionMachine.impose_stagger(character.combat, tick, tick + 25, Vector2(3.0, -2.0))
		character.set_state(PlayerState.decode(character.get_state().encode()))


## Un mundo de física propio con un suelo, y un personaje dentro. Devuelve
## {viewport, character}.
func _make_rig(rig_name: String) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.name = rig_name
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	tree.root.add_child(viewport)
	_viewports.append(viewport)
	_add_box(viewport, Vector3(400.0, 1.0, 400.0), Vector3(0.0, -0.5, 0.0), WORLD_LAYER)
	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	var character: PlayerCharacter = scene.instantiate() as PlayerCharacter
	viewport.add_child(character)
	await wait_physics_frames(2)
	return {"viewport": viewport, "character": character}


func _add_box(parent: Node, size: Vector3, center: Vector3, layer: int) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = center
	parent.add_child(body)


## Coloca al personaje y lo deja asentado en el suelo. Devuelve el último tick simulado.
func _settle(character: PlayerCharacter, position: Vector3, yaw: float) -> int:
	await _teleport(character, position, yaw)
	return START_TICK - 1


## Siguiente tick de una prueba con física: espera a estar dentro del paso de física.
func _next_tick(_character: PlayerCharacter, tick: int) -> int:
	await wait_physics_frames(1)
	return tick + 1


func _teleport(character: PlayerCharacter, position: Vector3, yaw: float,
		grounded: bool = true) -> void:
	await wait_physics_frames(1)
	var state := PlayerState.new()
	state.position = position
	state.yaw = yaw
	state.grounded = grounded
	character.set_state(PlayerState.decode(state.encode()))
	character.reset_physics_interpolation()
	for i: int in 3:
		character.simulate(_input(START_TICK - 4 + i, Vector2.ZERO, yaw, 0), _dt)


func _input(tick: int, move: Vector2, look_yaw: float, buttons: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.move = move
	input.look_yaw = look_yaw
	input.buttons = buttons
	return input.quantized()
