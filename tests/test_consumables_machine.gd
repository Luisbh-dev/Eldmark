extends TestCase
## Consumables in the action machine (docs/abilities.md, sections 2.3, 3.3 and 7.3): charges,
## shared cooldown, commit when finishing the drink, exactly +400 from the stamina potion,
## it does not start without charges, interruption before the commit spends nothing and command 13.
## [br][br]
## Data: health potion 36 + 1 + 12 (R), stamina 24 + 1 + 12 (T), shared cooldown of
## 1200 ticks, movement ×0.4 without sprint or jump.

const Action = CombatState.Action
const POTION_1: int = PlayerInput.CONSUMABLE_1
const POTION_2: int = PlayerInput.CONSUMABLE_2


func test_drinking_commits_at_the_end_and_spends_one_charge() -> void:
	var health: AbilityTicks = _potion(0)
	assert_eq(health.name, &"potion_health", "potion 1 is the health one")
	assert_eq([health.cast_ticks, health.active_ticks, health.recovery_ticks], [36, 1, 12], "drinking 0.6 s")
	assert_eq(CombatCatalog.tables().consumable_cooldown_ticks, 1200, "20 s shared")
	var d := _driver(3, 2)
	var first: ActionMachine.Output = d.step(POTION_1)
	var p: int = d.tick
	assert_eq(d.c.action, Action.ABILITY, "drinks")
	assert_eq(d.c.action_id, health.id, "the health potion")
	assert_near(first.move_scale, 0.4, 1e-6, "×0,4")
	assert_false(first.allow_jump or first.allow_sprint, "without jump or sprint")
	assert_eq(ActionMachine.action_byte(d.c, p) >> 6, 3, "in the action byte, slot 3: drink")
	for rel: int in range(1, 36):
		d.step(POTION_1)
		assert_eq(d.c.charges_of(0), 3, "rel %d: it does not spend yet" % rel)
		assert_eq(d.c.consumable_ready_tick, 0, "rel %d: nor does it set the cooldown" % rel)
	d.step()
	assert_eq(d.tick, p + 36, "when finishing the drink")
	assert_eq(d.c.charges_of(0), 2, "spends a charge")
	assert_eq(d.c.charges_of(1), 2, "only from its own")
	assert_eq(d.c.consumable_ready_tick, p + 36 + 1200, "and sets the shared cooldown")
	assert_eq(d.c.ability_ready, PackedInt64Array([0, 0, 0, 0, 0, 0]), "without touching the weapons' ones")
	d.idle_until_before(p + 49)
	assert_eq(d.c.action, Action.ABILITY, "recovery")
	d.step()
	assert_eq(d.c.action, Action.NONE, "ends at 49 ticks")
	for slot: int in [ActionMachine.STATUS_SLOT_CONSUMABLE_1, ActionMachine.STATUS_SLOT_CONSUMABLE_2]:
		assert_eq(ActionMachine.ability_status(d.c, slot, d.tick), ActionMachine.AbilityStatus.COOLDOWN,
				"both potions on cooldown (slot %d)" % slot)


func test_the_shared_cooldown_blocks_both_potions() -> void:
	var d := _driver(3, 2)
	d.step(POTION_1)
	d.hold(0, 60)
	var ready: int = d.c.consumable_ready_tick
	d.step(POTION_2)
	assert_eq(d.c.action, Action.NONE, "the other potion also waits")
	d.hold(0, 8)
	assert_eq(d.c.buffered, 0, "and the press expires")
	d.idle_until_before(ready - 1)
	d.step(POTION_2)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_CONSUMABLE_2, "one tick earlier, to the buffer")
	d.step()
	assert_eq(d.c.action, Action.ABILITY, "it goes out right when the cooldown ends")
	assert_eq(d.c.action_tick, ready, "on that tick")
	assert_eq(d.c.action_id, _potion(1).id, "the stamina one")


func test_the_stamina_potion_restores_exactly_400_at_the_commit() -> void:
	var stamina_potion: AbilityTicks = _potion(1)
	assert_eq(stamina_potion.stamina_restore, 400, "+400")
	assert_eq(stamina_potion.cast_ticks, 24, "0,4 s")
	var d := _driver(3, 2)
	d.set_stamina(200)
	d.step(POTION_2)
	var p: int = d.tick
	d.idle_until_before(p + 24)
	assert_eq(d.c.stamina, 200, "drinking does not regenerate or restore before the commit")
	d.step()
	assert_eq(d.c.stamina, 600, "exactly +400 at the commit")
	assert_eq(d.c.charges_of(1), 1, "spends the charge")
	d.hold(0, 20)
	assert_eq(d.c.stamina, 600, "only once")
	# Without exceeding the maximum.
	var full := _driver(3, 2)
	full.set_stamina(900)
	full.step(POTION_2)
	full.hold(0, 24)
	assert_eq(full.c.stamina, 1000, "up to the maximum")
	# It leaves exhaustion if it exceeds the threshold.
	var tired := _driver(3, 2)
	ActionMachine.drain_stamina(tired.c, 5000, tired.tick)
	tired.c.stamina_regen_tick = tired.tick + 100000
	assert_true(tired.c.is_exhausted(), "exhausted")
	tired.step(POTION_2)
	assert_eq(tired.c.action, Action.ABILITY, "exhaustion does not prevent drinking")
	tired.hold(0, 24)
	assert_eq(tired.c.stamina, 400, "+400")
	assert_false(tired.c.is_exhausted(), "and it is no longer exhausted (400 > 300)")


func test_without_charges_nothing_starts() -> void:
	var d := _driver(0, 1)
	assert_eq(ActionMachine.ability_status(d.c, ActionMachine.STATUS_SLOT_CONSUMABLE_1, d.tick),
			ActionMachine.AbilityStatus.NO_CHARGES, "the crossed-out slot")
	d.step(POTION_1)
	assert_eq(d.c.action, Action.NONE, "without charges one does not drink")
	assert_eq(d.c.buffered, 0, "and it is not buffered")
	d.step(POTION_2)
	assert_eq(d.c.action, Action.ABILITY, "the other one does have")
	d.hold(0, 40)
	assert_eq(d.c.charges_of(1), 0, "the last one spent")
	d.c.consumable_ready_tick = 0
	d.step(POTION_2)
	assert_eq(d.c.action, Action.NONE, "none left")


func test_an_interrupt_before_the_commit_spends_nothing() -> void:
	var d := _driver(3, 2)
	d.step(POTION_1)
	var p: int = d.tick
	d.hold(POTION_1, 20)
	ActionMachine.impose_interrupt(d.c, d.tick)
	assert_eq(d.c.action, Action.NONE, "interrupted")
	assert_eq(d.c.action_tick, p, "keeps the action_tick of what it cuts")
	assert_eq(d.c.charges_of(0), 3, "does not spend the charge")
	assert_eq(d.c.consumable_ready_tick, d.tick + AbilityTicks.REARM_TICKS,
			"nor the cooldown: only the margin so a remote player sees the NONE (H5 revision)")
	d.hold(POTION_1, 5)
	assert_eq(d.c.action, Action.NONE, "holding does not drink again")
	d.step()
	d.step(POTION_1)
	assert_eq(d.c.action, Action.ABILITY, "it can be tried again")
	# After the commit, the charge is already spent.
	d.hold(0, 40)
	ActionMachine.impose_interrupt(d.c, d.tick)
	assert_eq(d.c.charges_of(0), 2, "after the commit it is not returned")


func test_no_cooldowns_flag_keeps_the_charges() -> void:
	var d := _driver(1, 0)
	d.c.combat_flags2 |= CombatState.FLAG2_NO_COOLDOWNS
	d.step(POTION_1)
	d.hold(0, 49)
	assert_eq(d.c.charges_of(0), 1, "with bit 7 no charges are spent")
	assert_eq(d.c.consumable_ready_tick, 0, "nor is there a cooldown")
	d.step(POTION_1)
	assert_eq(d.c.action, Action.ABILITY, "one drinks again immediately")


func _driver(first: int, second: int) -> MachineDriver:
	return MachineDriver.new(CombatCatalog.weapon_id(&"sword_shield"), 0,
			CombatState.pack_charges(first, second))


func _potion(index: int) -> AbilityTicks:
	return CombatCatalog.ability(CombatCatalog.consumable_ids()[index])
