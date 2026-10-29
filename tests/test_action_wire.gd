extends TestCase
## Pruebas del byte de acción del registro de red ([ActionWire]): es el de
## [method ActionMachine.action_byte] salvo en la esquiva, el tambaleo y el aturdimiento, que llevan
## en los bits 6-7 un contador de reinicio para que un remoto distinga dos acciones iguales y seguidas.

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
