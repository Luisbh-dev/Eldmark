extends TestCase
## Pruebas del byte de acción del registro de red ([ActionWire]): es el de
## [method ActionMachine.action_byte] salvo en la esquiva, el tambaleo, el aturdimiento y el cambio de
## arma, que llevan en los bits 6-7 un contador de reinicio para que un remoto distinga dos acciones
## iguales y seguidas. Una habilidad lleva ahí su ranura (3 = un consumible) y su fase en los bits 4-5
## (docs/habilidades.md, sección 5.5): dos usos con el mismo byte dejan siempre
## [constant AbilityTicks.REARM_TICKS] ticks en NONE entre medias, también tras una interrupción.

const START_TICK: int = 1000

var _rules: CombatRules


func before_each() -> void:
	_rules = CombatCatalog.rules()


func _state() -> CombatState:
	return CombatState.initial(_rules, CombatCatalog.default_weapon_id())


func test_without_an_action_the_byte_is_the_plain_one() -> void:
	var wire := ActionWire.new()
	var state: CombatState = _state()
	assert_eq(wire.encode(state, START_TICK), 0x30, "sin acción vale 0x30, como siempre")
	assert_eq(ActionWire.step_of(0x30), 0)


func test_actions_other_than_dodge_and_controls_keep_the_plain_byte() -> void:
	var wire := ActionWire.new()
	var state: CombatState = _state()
	var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
	for light_index: int in 3:
		state.action = CombatState.Action.LIGHT
		state.action_id = weapon.light_ids[light_index]
		state.action_tick = START_TICK + light_index * 7
		var byte: int = wire.encode(state, START_TICK + light_index * 7 + 3)
		assert_eq(byte, ActionMachine.action_byte(state, START_TICK + light_index * 7 + 3),
				"el ligero %d lleva su paso del combo" % light_index)
		assert_eq(ActionWire.step_of(byte), light_index)
	for action: int in [CombatState.Action.HEAVY, CombatState.Action.CHARGE, CombatState.Action.BLOCK,
			CombatState.Action.DEAD]:
		state.action = action
		state.action_id = weapon.heavy_id if action == CombatState.Action.HEAVY else 0
		state.action_tick += 11
		var plain: int = ActionMachine.action_byte(state, state.action_tick + 2)
		assert_eq(wire.encode(state, state.action_tick + 2), plain, "acción %d sin cambios" % action)
		assert_eq(ActionWire.step_of(plain), 0)


func test_each_new_dodge_or_control_bumps_the_counter_and_staying_in_it_does_not() -> void:
	var wire := ActionWire.new()
	var state: CombatState = _state()
	state.action = CombatState.Action.DODGE
	state.action_tick = START_TICK
	var first: int = wire.encode(state, START_TICK)
	assert_eq(first & 0x3F, ActionMachine.action_byte(state, START_TICK) & 0x3F,
			"la acción y la fase no cambian")
	for rel: int in range(1, 27):
		assert_eq(ActionWire.step_of(wire.encode(state, START_TICK + rel)), ActionWire.step_of(first),
				"mientras dura la esquiva (+%d) el contador es el mismo" % rel)
	# Otra esquiva encadenada, en el tick en que acaba la primera.
	state.action_tick = START_TICK + 27
	var second: int = wire.encode(state, START_TICK + 27)
	assert_true(ActionWire.step_of(second) != ActionWire.step_of(first), "otra esquiva, otro contador")
	assert_eq(second & 0x3F, first & 0x3F, "con el mismo byte de acción y fase")
	# Un tambaleo, y otro cuyo inicio se separa un múltiplo de 4 ticks (el tick de inicio módulo 4 no
	# bastaría para distinguirlos).
	var seen: Array[int] = []
	for i: int in 6:
		ActionMachine.impose_stagger(state, START_TICK + 100 + i * 4, START_TICK + 140, Vector2.ZERO)
		seen.append(ActionWire.step_of(wire.encode(state, START_TICK + 100 + i * 4)))
		if i > 0:
			assert_true(seen[i] != seen[i - 1], "tambaleo %d: contador distinto del anterior" % i)
	ActionMachine.impose_stun(state, START_TICK + 130, START_TICK + 170)
	var stun: int = wire.encode(state, START_TICK + 130)
	assert_eq(stun & 15, CombatState.Action.STUN)
	assert_true(ActionWire.step_of(stun) != seen[5], "y el aturdimiento tras ellos")
	assert_true(wire.encode(state, START_TICK + 131) == stun, "pero sigue igual mientras dura")


func test_the_counter_wraps_and_fits_in_two_bits() -> void:
	var wire := ActionWire.new()
	var state: CombatState = _state()
	for i: int in 9:
		state.action = CombatState.Action.DODGE
		state.action_tick = START_TICK + i * 30
		var byte: int = wire.encode(state, state.action_tick)
		assert_true(byte >= 0 and byte <= 255, "cabe en un byte")
		assert_eq(ActionWire.step_of(byte), (i + 1) & 3, "sube de uno en uno módulo 4")


func test_an_ability_carries_its_slot_and_phase() -> void:
	var wire := ActionWire.new()
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	for slot: int in 3:
		var d := MachineDriver.new(sword)
		d.step(PlayerInput.ABILITY_1 << slot)
		var ability: AbilityTicks = CombatCatalog.ability(d.c.action_id)
		assert_eq(ability.slot, slot, "la habilidad de la ranura %d" % (slot + 1))
		var start: int = d.tick
		var phases: Dictionary[int, bool] = {}
		for rel: int in ability.total_ticks if not ability.channel else ability.cast_ticks + 20:
			var tick: int = start + rel
			var byte: int = wire.encode(d.c, tick)
			assert_eq(byte & 15, CombatState.Action.ABILITY, "ranura %d: ABILITY" % slot)
			assert_eq(ActionWire.step_of(byte), slot, "ranura %d en los bits 6-7" % slot)
			var phase: int = (byte >> 4) & 3
			assert_eq(phase, AbilityRules.phase_of(ability, rel), "ranura %d, rel %d: fase" % [slot, rel])
			phases[phase] = true
			d.step(PlayerInput.ABILITY_1 << slot)
		assert_true(phases.has(0) and phases.has(1), "ranura %d: lanzamiento y activo" % slot)
		assert_eq(phases.has(2), not ability.channel, "ranura %d: recuperación si no es canalizada" % slot)
	# Un consumible: ranura 3.
	var potion := MachineDriver.new(sword, 0, CombatState.pack_charges(1, 1))
	potion.step(PlayerInput.CONSUMABLE_2)
	var drink: int = wire.encode(potion.c, potion.tick)
	assert_eq(drink & 15, CombatState.Action.ABILITY, "beber es ABILITY")
	assert_eq(ActionWire.step_of(drink), 3, "con la ranura 3")
	assert_eq((drink >> 4) & 3, 0, "en su fase 0")
	assert_false(ActionWire.has_counter(CombatState.Action.ABILITY), "sin contador")


func test_swap_carries_a_counter_and_downed_revive_execute_do_not() -> void:
	assert_true(ActionWire.has_counter(CombatState.Action.SWAP), "el cambio de arma lleva contador")
	var wire := ActionWire.new()
	var state: CombatState = _state()
	state.action = CombatState.Action.SWAP
	state.action_tick = START_TICK
	var first: int = wire.encode(state, START_TICK)
	assert_eq(first & 0x3F, CombatState.Action.SWAP | (3 << 4), "SWAP sin fases")
	assert_eq(wire.encode(state, START_TICK + 10), first, "igual mientras dura")
	state.action_tick = START_TICK + 24
	var second: int = wire.encode(state, START_TICK + 24)
	assert_true(ActionWire.step_of(second) != ActionWire.step_of(first),
			"otro cambio encadenado desde el búfer: otro contador")
	for action: int in [CombatState.Action.DOWNED, CombatState.Action.REVIVE, CombatState.Action.EXECUTE]:
		assert_false(ActionWire.has_counter(action), "%d sin contador" % action)
		state.action = action
		state.action_tick = START_TICK + 100 + action
		assert_eq(wire.encode(state, START_TICK + 200), action | (3 << 4), "%d: fase 3 y bits 6-7 a 0" % action)
	# CHARGE con el arco: fase 0 y nada más.
	var bow := MachineDriver.new(CombatCatalog.weapon_id(&"bow"))
	bow.hold(PlayerInput.PRIMARY, 10)
	assert_eq(bow.c.action, CombatState.Action.CHARGE, "tensando")
	assert_eq(wire.encode(bow.c, bow.tick), CombatState.Action.CHARGE, "CHARGE, fase 0, bits 6-7 a 0")


## Revisión de H5: cortada la poción de vida en su lanzamiento (NONE en s), un flanco de la de resistencia en
## s + 1 empezaba otra ABILITY con el mismo byte (fase 0, ranura 3) que en s − 1. Un remoto ve el registro cada
## SNAPSHOT_INTERVAL_TICKS ticks: el que no muestreaba s veía el mismo byte y el clip de beber seguía sin
## reiniciarse. Ahora la interrupción deja REARM_TICKS ticks de margen y el NONE se ve con cualquier muestreo.
func test_after_an_interrupted_drink_the_next_one_waits_until_a_remote_can_see_none() -> void:
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var d := MachineDriver.new(sword, 0, CombatState.pack_charges(3, 2))
	var wire := ActionWire.new()
	d.step(PlayerInput.CONSUMABLE_1)
	d.hold(PlayerInput.CONSUMABLE_1, 10)
	var before: int = wire.encode(d.c, d.tick)
	assert_eq([before & 15, (before >> 4) & 3, ActionWire.step_of(before)], [CombatState.Action.ABILITY, 0, 3],
			"en s − 1 bebe la de vida: ABILITY, fase 0, ranura 3")
	d.step(PlayerInput.CONSUMABLE_1)
	var s: int = d.tick
	ActionMachine.impose_interrupt(d.c, s)
	assert_eq(wire.encode(d.c, s), 0x30, "en s, NONE")
	assert_eq(d.c.charges_of(0), 3, "sin gastar la carga")
	var bytes: Array[int] = [0x30]
	var started: int = -1
	for rel: int in range(1, AbilityTicks.REARM_TICKS + 4):
		# Un flanco de la otra poción en s + 1 (otro botón, sin soltar nada), y se mantiene.
		d.step(PlayerInput.CONSUMABLE_2)
		var byte: int = wire.encode(d.c, d.tick)
		if started < 0 and d.c.action == CombatState.Action.ABILITY:
			started = d.tick
		if started < 0:
			bytes.append(byte)
	assert_true(bytes.size() > 1 and bytes[1] != before,
			"en s + 1 ya no sale el byte de s − 1 (antes: el mismo, y has_counter(ABILITY) es false)")
	assert_eq(started, s + AbilityTicks.REARM_TICKS, "la de resistencia empieza al acabar el margen (del búfer)")
	assert_eq(d.c.action_id, CombatCatalog.ability_id(&"potion_stamina"))
	assert_eq(bytes.size(), AbilityTicks.REARM_TICKS, "NONE de s a s + REARM_TICKS − 1")
	for byte: int in bytes:
		assert_eq(byte, 0x30, "todo NONE")
	assert_true(AbilityTicks.REARM_TICKS >= 3 * NetProtocol.SNAPSHOT_INTERVAL_TICKS,
			"más de un intervalo de snapshot: cualquier muestreo ve el NONE")
	# Una habilidad cortada en su lanzamiento deja el mismo margen en su ranura.
	var bash := MachineDriver.new(sword)
	bash.step(PlayerInput.ABILITY_1)
	var ability: AbilityTicks = CombatCatalog.ability(bash.c.action_id)
	bash.step()
	ActionMachine.impose_interrupt(bash.c, bash.tick)
	assert_eq(bash.c.ability_ready[ability.slot], bash.tick + AbilityTicks.REARM_TICKS,
			"la ranura de %s, con el margen" % ability.name)
	# Tras el compromiso la reutilización ya es mayor y no cambia.
	var late := MachineDriver.new(sword, 0, CombatState.pack_charges(3, 2))
	late.step(PlayerInput.CONSUMABLE_1)
	late.hold(0, CombatCatalog.ability(late.c.action_id).cast_ticks + 2)
	var committed: int = late.c.consumable_ready_tick
	assert_true(committed > late.tick + AbilityTicks.REARM_TICKS, "comprometida, ya tiene su reutilización")
	ActionMachine.impose_interrupt(late.c, late.tick)
	assert_eq(late.c.consumable_ready_tick, committed, "y la interrupción no la toca")
