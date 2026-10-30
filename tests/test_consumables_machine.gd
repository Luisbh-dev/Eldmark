extends TestCase
## Consumibles en la máquina de acciones (docs/habilidades.md, secciones 2.3, 3.3 y 7.3): cargas,
## reutilización compartida, compromiso al acabar de beber, +400 exactos de la poción de resistencia,
## sin cargas no empieza, la interrupción antes del compromiso no gasta nada y el comando 13.
## [br][br]
## Datos: poción de vida 36 + 1 + 12 (R), de resistencia 24 + 1 + 12 (T), reutilización compartida de
## 1200 ticks, movimiento ×0,4 sin esprint ni salto.

const Action = CombatState.Action
const POTION_1: int = PlayerInput.CONSUMABLE_1
const POTION_2: int = PlayerInput.CONSUMABLE_2


func test_drinking_commits_at_the_end_and_spends_one_charge() -> void:
	var health: AbilityTicks = _potion(0)
	assert_eq(health.name, &"potion_health", "la poción 1 es la de vida")
	assert_eq([health.cast_ticks, health.active_ticks, health.recovery_ticks], [36, 1, 12], "beber 0,6 s")
	assert_eq(CombatCatalog.tables().consumable_cooldown_ticks, 1200, "20 s compartidos")
	var d := _driver(3, 2)
	var first: ActionMachine.Output = d.step(POTION_1)
	var p: int = d.tick
	assert_eq(d.c.action, Action.ABILITY, "bebe")
	assert_eq(d.c.action_id, health.id, "la poción de vida")
	assert_near(first.move_scale, 0.4, 1e-6, "×0,4")
	assert_false(first.allow_jump or first.allow_sprint, "sin salto ni esprint")
	assert_eq(ActionMachine.action_byte(d.c, p) >> 6, 3, "en el byte de acción, la ranura 3: beber")
	for rel: int in range(1, 36):
		d.step(POTION_1)
		assert_eq(d.c.charges_of(0), 3, "rel %d: aún no gasta" % rel)
		assert_eq(d.c.consumable_ready_tick, 0, "rel %d: ni fija la reutilización" % rel)
	d.step()
	assert_eq(d.tick, p + 36, "al acabar de beber")
	assert_eq(d.c.charges_of(0), 2, "gasta una carga")
	assert_eq(d.c.charges_of(1), 2, "solo de la suya")
	assert_eq(d.c.consumable_ready_tick, p + 36 + 1200, "y fija la reutilización compartida")
	assert_eq(d.c.ability_ready, PackedInt64Array([0, 0, 0, 0, 0, 0]), "sin tocar las de las armas")
	d.idle_until_before(p + 49)
	assert_eq(d.c.action, Action.ABILITY, "recuperación")
	d.step()
	assert_eq(d.c.action, Action.NONE, "acaba a los 49 ticks")
	for slot: int in [ActionMachine.STATUS_SLOT_CONSUMABLE_1, ActionMachine.STATUS_SLOT_CONSUMABLE_2]:
		assert_eq(ActionMachine.ability_status(d.c, slot, d.tick), ActionMachine.AbilityStatus.COOLDOWN,
				"las dos pociones en reutilización (casilla %d)" % slot)


func test_the_shared_cooldown_blocks_both_potions() -> void:
	var d := _driver(3, 2)
	d.step(POTION_1)
	d.hold(0, 60)
	var ready: int = d.c.consumable_ready_tick
	d.step(POTION_2)
	assert_eq(d.c.action, Action.NONE, "la otra poción también espera")
	d.hold(0, 8)
	assert_eq(d.c.buffered, 0, "y la pulsación caduca")
	d.idle_until_before(ready - 1)
	d.step(POTION_2)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_CONSUMABLE_2, "un tick antes, al búfer")
	d.step()
	assert_eq(d.c.action, Action.ABILITY, "sale justo al acabar la reutilización")
	assert_eq(d.c.action_tick, ready, "en ese tick")
	assert_eq(d.c.action_id, _potion(1).id, "la de resistencia")


func test_the_stamina_potion_restores_exactly_400_at_the_commit() -> void:
	var stamina_potion: AbilityTicks = _potion(1)
	assert_eq(stamina_potion.stamina_restore, 400, "+400")
	assert_eq(stamina_potion.cast_ticks, 24, "0,4 s")
	var d := _driver(3, 2)
	d.set_stamina(200)
	d.step(POTION_2)
	var p: int = d.tick
	d.idle_until_before(p + 24)
	assert_eq(d.c.stamina, 200, "beber no regenera ni restaura antes del compromiso")
	d.step()
	assert_eq(d.c.stamina, 600, "+400 exactos en el compromiso")
	assert_eq(d.c.charges_of(1), 1, "gasta la carga")
	d.hold(0, 20)
	assert_eq(d.c.stamina, 600, "una sola vez")
	# Sin pasar del máximo.
	var full := _driver(3, 2)
	full.set_stamina(900)
	full.step(POTION_2)
	full.hold(0, 24)
	assert_eq(full.c.stamina, 1000, "hasta el máximo")
	# Sale del agotamiento si supera el umbral.
	var tired := _driver(3, 2)
	ActionMachine.drain_stamina(tired.c, 5000, tired.tick)
	tired.c.stamina_regen_tick = tired.tick + 100000
	assert_true(tired.c.is_exhausted(), "agotado")
	tired.step(POTION_2)
	assert_eq(tired.c.action, Action.ABILITY, "el agotamiento no impide beber")
	tired.hold(0, 24)
	assert_eq(tired.c.stamina, 400, "+400")
	assert_false(tired.c.is_exhausted(), "y deja de estar agotado (400 > 300)")


func test_without_charges_nothing_starts() -> void:
	var d := _driver(0, 1)
	assert_eq(ActionMachine.ability_status(d.c, ActionMachine.STATUS_SLOT_CONSUMABLE_1, d.tick),
			ActionMachine.AbilityStatus.NO_CHARGES, "la casilla tachada")
	d.step(POTION_1)
	assert_eq(d.c.action, Action.NONE, "sin cargas no se bebe")
	assert_eq(d.c.buffered, 0, "y no se guarda")
	d.step(POTION_2)
	assert_eq(d.c.action, Action.ABILITY, "la otra sí tiene")
	d.hold(0, 40)
	assert_eq(d.c.charges_of(1), 0, "gastada la última")
	d.c.consumable_ready_tick = 0
	d.step(POTION_2)
	assert_eq(d.c.action, Action.NONE, "ya no quedan")


func test_an_interrupt_before_the_commit_spends_nothing() -> void:
	var d := _driver(3, 2)
	d.step(POTION_1)
	var p: int = d.tick
	d.hold(POTION_1, 20)
	ActionMachine.impose_interrupt(d.c, d.tick)
	assert_eq(d.c.action, Action.NONE, "interrumpido")
	assert_eq(d.c.action_tick, p, "conserva el action_tick de lo que corta")
	assert_eq(d.c.charges_of(0), 3, "no gasta la carga")
	assert_eq(d.c.consumable_ready_tick, d.tick + AbilityTicks.REARM_TICKS,
			"ni la reutilización: solo el margen para que un remoto vea el NONE (revisión de H5)")
	d.hold(POTION_1, 5)
	assert_eq(d.c.action, Action.NONE, "mantener no vuelve a beber")
	d.step()
	d.step(POTION_1)
	assert_eq(d.c.action, Action.ABILITY, "se puede volver a intentar")
	# Tras el compromiso, la carga ya está gastada.
	d.hold(0, 40)
	ActionMachine.impose_interrupt(d.c, d.tick)
	assert_eq(d.c.charges_of(0), 2, "tras el compromiso no se devuelve")


func test_no_cooldowns_flag_keeps_the_charges() -> void:
	var d := _driver(1, 0)
	d.c.combat_flags2 |= CombatState.FLAG2_NO_COOLDOWNS
	d.step(POTION_1)
	d.hold(0, 49)
	assert_eq(d.c.charges_of(0), 1, "con el bit 7 no se gastan cargas")
	assert_eq(d.c.consumable_ready_tick, 0, "ni hay reutilización")
	d.step(POTION_1)
	assert_eq(d.c.action, Action.ABILITY, "se vuelve a beber al momento")


func _driver(first: int, second: int) -> MachineDriver:
	return MachineDriver.new(CombatCatalog.weapon_id(&"sword_shield"), 0,
			CombatState.pack_charges(first, second))


func _potion(index: int) -> AbilityTicks:
	return CombatCatalog.ability(CombatCatalog.consumable_ids()[index])
