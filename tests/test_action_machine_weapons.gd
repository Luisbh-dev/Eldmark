extends TestCase
## [method ActionMachine.set_weapons] (docs/progresion.md §4.1 y §8): pone las armas de las dos ranuras del
## equipo sin reiniciar nada más. Conserva cargas, [member CombatState.consumable_ready_tick], ranuras de
## movimiento y botones; reparte [member CombatState.ability_ready] por arma (las tres de la activa delante);
## con una acción en curso no hace nada. Con la máquina de verdad: desequipar y volver a equipar un arma con
## sus reutilizaciones guardadas no las reinicia, y el SWAP siguiente funciona desde lo que deja.

const Action = CombatState.Action
const SWAP: int = PlayerInput.SWAP_WEAPON
const ABILITY_1: int = PlayerInput.ABILITY_1
## Reutilizaciones guardadas de cada arma (ticks absolutos).
var _ready_1: PackedInt64Array = PackedInt64Array([1100, 1200, 1300])
var _ready_2: PackedInt64Array = PackedInt64Array([2100, 2200, 2300])


## Las dos ranuras con la 1 activa: armas, reutilizaciones por arma y el bit0 a 0; nada más cambia.
func test_sets_both_slots_without_touching_the_rest() -> void:
	var c: CombatState = _busy_state()
	c.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	var expected: CombatState = c.duplicate_state()
	expected.weapon_id = _bow()
	expected.alt_weapon_id = _sword()
	expected.ability_ready = PackedInt64Array([1100, 1200, 1300, 2100, 2200, 2300])
	expected.combat_flags2 &= ~CombatState.FLAG2_SECOND_SLOT
	ActionMachine.set_weapons(c, _bow(), _sword(), false, _ready_1, _ready_2)
	assert_true(c.equals(expected), "solo cambian las armas, las reutilizaciones y el bit0: %s" % c)
	assert_eq(c.consumable_charges, CombatState.pack_charges(4, 1), "las cargas, intactas")
	assert_eq(c.consumable_ready_tick, 5555, "la reutilización compartida de los consumibles, intacta")
	assert_eq(Array(c.move_effect_ids), [3, 0], "las ranuras de movimiento, intactas")
	assert_eq(Array(c.move_effect_until), [4321, 0], "con su fin")
	assert_eq(c.combat_flags & CombatState.FLAG_BLOCK_HELD, CombatState.FLAG_BLOCK_HELD, "los botones del tick anterior")
	assert_eq(c.combat_flags2 & CombatState.FLAG2_HELD_MASK, CombatState.FLAG2_SWAP_HELD | CombatState.FLAG2_ABILITY_2_HELD,
			"también los de combat_flags2")
	assert_false(c.is_second_slot(), "ranura 1 activa")


## Con la ranura 2 activa, el arma de la 2 va a weapon_id y sus reutilizaciones delante.
func test_second_slot_active_puts_its_weapon_and_cooldowns_first() -> void:
	var c: CombatState = _busy_state()
	var expected: CombatState = c.duplicate_state()
	expected.weapon_id = _bow()
	expected.alt_weapon_id = _sword()
	expected.ability_ready = PackedInt64Array([2100, 2200, 2300, 1100, 1200, 1300])
	expected.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	ActionMachine.set_weapons(c, _sword(), _bow(), true, _ready_1, _ready_2)
	assert_true(c.equals(expected), "la 2 activa: %s" % c)
	assert_true(c.is_second_slot(), "bit0 de combat_flags2")
	assert_eq(c.consumable_ready_tick, 5555, "sin tocar los consumibles")


## Con la ranura 1 vacía y la 2 activa, la 2 en la mano y nada en la otra (no hay SWAP).
func test_empty_first_slot_with_the_second_active() -> void:
	var c: CombatState = _busy_state()
	ActionMachine.set_weapons(c, 0, _bow(), true, PackedInt64Array(), _ready_2)
	assert_eq([c.weapon_id, c.alt_weapon_id], [_bow(), 0], "el arco en la mano, nada en la otra")
	assert_eq(c.ability_ready, PackedInt64Array([2100, 2200, 2300, 0, 0, 0]), "la otra mitad, a 0")
	assert_true(c.is_second_slot(), "ranura 2 activa")
	var d := MachineDriver.new(_sword())
	d.c.copy_from(c)
	d.c.action = Action.NONE
	d.step(SWAP)
	assert_eq(d.c.action, Action.NONE, "sin arma en la otra ranura, el SWAP se descarta")
	assert_eq(d.c.weapon_id, _bow(), "y sigue el arco")


## Los ready vacíos o cortos son 0; los que sobran no se miran.
func test_missing_ready_values_are_zero() -> void:
	var c: CombatState = _busy_state()
	ActionMachine.set_weapons(c, _sword(), _bow(), false, PackedInt64Array([7]), PackedInt64Array())
	assert_eq(c.ability_ready, PackedInt64Array([7, 0, 0, 0, 0, 0]), "vacío = 0")
	ActionMachine.set_weapons(c, _sword(), _bow(), false, PackedInt64Array([1, 2, 3, 4]),
			PackedInt64Array([5, 6, 7, 8]))
	assert_eq(c.ability_ready, PackedInt64Array([1, 2, 3, 5, 6, 7]), "tres por arma")
	ActionMachine.set_weapons(c, _sword(), 0, false, _ready_1, PackedInt64Array())
	assert_eq([c.weapon_id, c.alt_weapon_id], [_sword(), 0], "una sola arma")
	assert_eq(c.ability_ready, PackedInt64Array([1100, 1200, 1300, 0, 0, 0]), "y su mitad")


## Con una acción en curso (beber, cambiar, bloquear, golpear, muerto) no cambia nada y lo registra.
func test_does_nothing_during_an_action() -> void:
	allow_logged_errors()
	for action: int in [Action.ABILITY, Action.SWAP, Action.BLOCK, Action.LIGHT, Action.DEAD, Action.DOWNED]:
		var c: CombatState = _busy_state()
		c.action = action
		c.action_tick = 4000
		var before: CombatState = c.duplicate_state()
		ActionMachine.set_weapons(c, _bow(), 0, false, _ready_2, _ready_1)
		assert_true(c.equals(before), "con la acción %d no cambia nada" % action)


## Desequipar la espada (no activa) y volver a ponerla con sus reutilizaciones guardadas no las reinicia: al
## volver a ella con SWAP, el golpe de escudo sigue en reutilización con el mismo tick.
func test_unequip_and_equip_keep_each_weapons_cooldowns() -> void:
	var d := MachineDriver.new(_sword(), _bow(), CombatState.pack_charges(3, 2))
	d.step(ABILITY_1)
	d.hold(0, 60)
	var bash_ready: int = d.c.ability_ready[0]
	assert_true(bash_ready > d.tick, "golpe de escudo en reutilización")
	d.step(SWAP)
	d.hold(0, 30)
	assert_eq(d.c.action, Action.NONE, "con el arco y sin acción")
	assert_eq(d.c.ability_ready[3], bash_ready, "la del escudo, en la otra mitad")
	# Lo que haría PlayerProgress.stash_ready al quitar la espada de WEAPON_1.
	var stashed_sword: PackedInt64Array = d.c.ability_ready.slice(3, 6)
	var bow_ready: PackedInt64Array = d.c.ability_ready.slice(0, 3)
	ActionMachine.set_weapons(d.c, 0, _bow(), true, PackedInt64Array(), bow_ready)
	assert_eq([d.c.weapon_id, d.c.alt_weapon_id], [_bow(), 0], "sin espada")
	assert_eq(d.c.ability_ready.slice(3, 6), PackedInt64Array([0, 0, 0]), "su mitad, vacía")
	d.hold(0, 5)
	ActionMachine.set_weapons(d.c, _sword(), _bow(), true, stashed_sword, bow_ready)
	assert_eq(d.c.ability_ready[3], bash_ready, "vuelve con la reutilización guardada")
	d.step(SWAP)
	assert_eq([d.c.weapon_id, d.c.alt_weapon_id], [_sword(), _bow()], "el SWAP vuelve a la espada")
	assert_false(d.c.is_second_slot(), "ranura 1")
	assert_eq(d.c.ability_ready[0], bash_ready, "con su reutilización intacta")
	d.hold(0, 30)
	assert_eq(ActionMachine.ability_status(d.c, 0, d.tick + 1), ActionMachine.AbilityStatus.COOLDOWN,
			"el golpe de escudo sigue en reutilización")
	d.step(ABILITY_1)
	assert_ne_action(d, Action.ABILITY, "y no se puede usar antes de su tick")


## Un estado con todo lo que set_weapons no debe tocar: cargas, reutilización compartida, ranuras de
## movimiento, botones del tick anterior, resistencia y combo.
func _busy_state() -> CombatState:
	var c := CombatState.initial(CombatCatalog.rules(), _sword(), _bow(), CombatState.pack_charges(4, 1))
	c.consumable_ready_tick = 5555
	c.move_effect_ids[0] = 3
	c.move_effect_until[0] = 4321
	c.combat_flags = CombatState.FLAG_BLOCK_HELD
	c.combat_flags2 = CombatState.FLAG2_SWAP_HELD | CombatState.FLAG2_ABILITY_2_HELD
	c.stamina = 321
	c.stamina_regen_tick = 999
	c.parry_ready_tick = 777
	c.ability_ready = PackedInt64Array([9, 8, 7, 6, 5, 4])
	return c


func assert_ne_action(d: MachineDriver, action: int, message: String) -> void:
	assert_true(d.c.action != action, message)


func _sword() -> int:
	return CombatCatalog.weapon_id(&"sword_shield")


func _bow() -> int:
	return CombatCatalog.weapon_id(&"bow")
