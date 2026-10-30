extends TestCase
## El arco en la máquina de acciones (docs/habilidades.md, secciones 0, 2.3 y 7.3): un toque es el
## disparo rápido (el ligero, combo de 1), mantener 8 ticks es el tensado (la carga del fuerte), las
## cargas mínima y máxima salen en sus ticks, BLOCK no hace nada y agotado no se tensa.
## [br][br]
## Datos: rápido 15 + 1 + 21 (37), tensado con carga de 21 a 60 ticks desde la pulsación y luego 3 + 1
## + 18, movimiento ×0,5 y giro 8.

const Action = CombatState.Action
const PRIMARY: int = PlayerInput.PRIMARY


func test_a_tap_is_the_quick_shot() -> void:
	var bow: WeaponTicks = CombatCatalog.weapon(_bow())
	var quick: AttackTicks = CombatCatalog.attack(bow.light_ids[0])
	assert_eq(quick.name, &"bow_quick", "el ligero es el disparo rápido")
	assert_eq(bow.light_ids.size(), 1, "combo de 1")
	var d := _driver()
	var first: ActionMachine.Output = d.step(PRIMARY)
	var p: int = d.tick
	assert_eq(d.c.action, Action.LIGHT, "un toque dispara")
	assert_eq(d.c.action_id, quick.id, "el rápido")
	assert_eq(d.c.combo_step, 0, "el combo de 1 vuelve al principio")
	assert_near(first.move_scale, 0.5, 1e-6, "×0,5")
	assert_near(first.turn_rate, 8.0, 1e-6, "giro 8")
	for rel: int in range(1, 37):
		d.step()
		assert_eq(ActionMachine.is_commit_tick(d.c, p + rel), rel == 15, "rel %d: la flecha sale en 15" % rel)
	assert_eq(d.c.action, Action.LIGHT, "dispara durante 37 ticks")
	d.step()
	assert_eq(d.c.action, Action.NONE, "y acaba")
	d.step(PRIMARY)
	assert_eq(d.c.action_id, quick.id, "el siguiente toque vuelve a ser el rápido")


func test_holding_eight_ticks_draws_the_bow() -> void:
	var d := _driver()
	d.hold(PRIMARY, 7)
	assert_eq(d.c.action, Action.LIGHT, "7 ticks: aún el rápido")
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.CHARGE, "a los 8, tensando")
	assert_eq(d.c.action_id, CombatCatalog.weapon(_bow()).heavy_id, "el tensado")
	assert_true(d.out.snap_yaw, "mira a la cámara")
	d.step(PRIMARY)
	assert_near(d.out.move_scale, 0.5, 1e-6, "tensando ×0,5")
	assert_near(d.out.turn_rate, 8.0, 1e-6, "giro 8")
	assert_eq(ActionMachine.phase(d.c, d.tick), ActionMachine.PHASE_WINDUP, "fase 0")
	assert_eq(ActionMachine.action_byte(d.c, d.tick), Action.CHARGE, "byte: CHARGE, fase 0, sin más")
	assert_eq(d.c.stamina, 1000, "tensar no cuesta resistencia")


func test_minimum_and_maximum_draw_launch_on_their_ticks() -> void:
	var drawn: AttackTicks = CombatCatalog.attack(CombatCatalog.weapon(_bow()).heavy_id)
	assert_eq([drawn.charge_min_ticks, drawn.charge_max_ticks], [21, 60], "carga 21-60")
	assert_eq([drawn.windup_ticks, drawn.active_ticks, drawn.recovery_ticks], [3, 1, 18], "3 + 1 + 18")
	# Soltar antes de la mínima: sale en la mínima.
	var short := _driver()
	short.step(PRIMARY)
	var p: int = short.tick
	short.hold(PRIMARY, 9)
	short.idle_until_before(p + 21)
	assert_eq(short.c.action, Action.CHARGE, "espera a la mínima")
	short.step()
	assert_eq(short.c.action, Action.HEAVY, "suelta en la mínima")
	assert_eq(short.c.action_tick, p + 21, "en el tick 21 desde la pulsación")
	assert_eq(short.c.charge_ticks, 21, "con 21 de carga")
	assert_true(ActionMachine.is_commit_tick(short.c, p + 21 + 3), "la flecha sale 3 ticks después")
	# Mantener: sale sola en la máxima.
	var full := _driver()
	full.step(PRIMARY)
	var q: int = full.tick
	full.idle_until_before(q + 60, PRIMARY)
	assert_eq(full.c.action, Action.CHARGE, "tensando hasta la máxima")
	full.step(PRIMARY)
	assert_eq(full.c.action, Action.HEAVY, "en la máxima se suelta sola")
	assert_eq(full.c.action_tick, q + 60, "en el tick 60")
	assert_eq(full.c.charge_ticks, 60, "con la carga máxima")


func test_block_does_nothing_with_the_bow() -> void:
	var d := _driver()
	d.hold(PlayerInput.BLOCK, 20)
	assert_eq(d.c.action, Action.NONE, "el arco no bloquea")
	assert_eq(d.c.parry_ready_tick, 0, "ni abre paradas")
	assert_eq(ActionMachine.defense_flags(d.c, d.tick), 0, "sin defensa")
	d.step(PlayerInput.BLOCK | PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "y el botón no estorba al disparo")


func test_exhausted_does_not_draw_but_still_shoots() -> void:
	var d := _driver()
	ActionMachine.drain_stamina(d.c, 5000, d.tick)
	assert_true(d.c.is_exhausted(), "agotado")
	d.hold(PRIMARY, 8)
	assert_eq(d.c.action, Action.LIGHT, "no tensa: sigue el disparo rápido")
	assert_true((d.c.combat_flags & CombatState.FLAG_NO_STAMINA) != 0, "y avisa a la interfaz")
	d.hold(PRIMARY, 40)
	assert_eq(d.c.action, Action.NONE, "el disparo rápido acabó")


func _bow() -> int:
	return CombatCatalog.weapon_id(&"bow")


func _driver() -> MachineDriver:
	return MachineDriver.new(_bow(), CombatCatalog.weapon_id(&"sword_shield"),
			CombatState.pack_charges(2, 3))
