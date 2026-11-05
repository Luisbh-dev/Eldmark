extends TestCase
## Tests for [Combatant] (docs/combat.md, section 5): health, \"in combat\" state, protection,
## control chain with its immunity, regeneration, immortal dummy, death and respawn, the
## frozen sample and what is published on the entity for the snapshots.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM

var _viewport: SubViewport
var _world: Node3D
var _timing: CombatTiming


func before_each() -> void:
	_viewport = CombatFixture.make_world(tree.root)
	_world = NetHarness.get_world(_viewport)
	_timing = CombatTiming.from_rules(CombatCatalog.rules())
	await wait_physics_frames(2)


func after_each() -> void:
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_world = null
	await wait_process_frames()


func _fighter(position: Vector3 = Vector3.ZERO) -> Combatant:
	return CombatFixture.make_fighter(_world, 1, VARDHEIM, position, 0.0, _timing)


func test_timing_comes_from_the_rules_in_ticks() -> void:
	var rules: CombatRules = CombatCatalog.rules()
	assert_eq(_timing.in_combat, roundi(rules.in_combat_s * 60.0))
	assert_eq(_timing.in_combat, 600, "10 s")
	assert_eq(_timing.respawn, 600, "10 s")
	assert_eq(_timing.auto_respawn, 1800, "30 s")
	assert_eq(_timing.protection, 180, "3 s")
	assert_eq(_timing.cc_window, 180, "3 s")
	assert_eq(_timing.cc_immunity, 120, "2 s")
	assert_eq(_timing.parry_stagger, 36, "0,6 s")
	assert_eq(_timing.guard_break_stun, 60, "1 s")
	assert_eq(_timing.dummy_heal, 300, "5 s")


func test_starts_alive_with_full_health() -> void:
	var fighter: Combatant = _fighter()
	assert_eq(fighter.health, CombatCatalog.rules().health_max)
	assert_eq(fighter.max_health, fighter.health)
	assert_true(fighter.is_alive())
	assert_false(fighter.is_dead())
	assert_false(fighter.is_in_combat(0))
	assert_false(fighter.is_protected(0))
	assert_eq(fighter.status_bits(0), 0)
	assert_eq(fighter.get_id(), 1)
	assert_eq(fighter.get_realm(), VARDHEIM)


func test_take_damage_clamps_to_the_remaining_health() -> void:
	var fighter: Combatant = _fighter()
	assert_eq(fighter.take_damage(300, 10), 300)
	assert_eq(fighter.health, 700)
	assert_eq(fighter.last_damage_tick, 10)
	assert_eq(fighter.take_damage(5000, 11), 700, "only what is left is taken off")
	assert_eq(fighter.health, 0)
	assert_true(fighter.is_dead())
	assert_eq(fighter.take_damage(10, 12), 0, "a dead player takes no more damage")
	assert_eq(fighter.take_damage(-4, 12), 0)
	assert_eq(fighter.take_damage(0, 12), 0)


func test_immortal_dummy_never_goes_below_one() -> void:
	var fighter: Combatant = _fighter()
	fighter.immortal = true
	assert_eq(fighter.take_damage(999, 5), 999)
	assert_eq(fighter.health, 1)
	assert_eq(fighter.take_damage(500, 6), 0, "it is already at the minimum")
	assert_eq(fighter.health, 1)
	assert_true(fighter.is_alive())


func test_status_bits() -> void:
	var fighter: Combatant = _fighter()
	fighter.mark_combat(100)
	assert_true(fighter.is_in_combat(100))
	assert_true(fighter.is_in_combat(699), "600 ticks of combat")
	assert_false(fighter.is_in_combat(700))
	assert_eq(fighter.status_bits(100), NetMessages.STATUS_IN_COMBAT)
	fighter.protected_until = 200
	assert_eq(fighter.status_bits(150), NetMessages.STATUS_IN_COMBAT | NetMessages.STATUS_PROTECTED)
	assert_eq(fighter.status_bits(200), NetMessages.STATUS_IN_COMBAT, "protection until 200 exclusive")
	fighter.mark_dead(300, 7, 2)
	assert_eq(fighter.status_bits(300), NetMessages.STATUS_DEAD, "dead: only the death bit")
	# mark_combat does not shorten a longer combat.
	var other: Combatant = _fighter()
	other.mark_combat(100)
	other.mark_combat(50)
	assert_eq(other.in_combat_until, 700)


func test_control_chain_third_control_does_not_enter() -> void:
	var fighter: Combatant = _fighter()
	assert_true(fighter.try_control(100), "the first one goes through")
	assert_true(fighter.try_control(150), "the second, within the window, goes through")
	assert_false(fighter.try_control(200), "the third does not go through")
	assert_eq(fighter.cc_immune_until, 200 + 120, "and opens 2 s of immunity")
	assert_false(fighter.try_control(300), "during the immunity nothing goes through")
	assert_false(fighter.try_control(319))
	# Once the immunity has passed, the chain starts anew.
	assert_true(fighter.try_control(320), "after the immunity it applies again")
	assert_true(fighter.try_control(330))
	assert_false(fighter.try_control(340), "the third again")


func test_control_chain_window_expires() -> void:
	var fighter: Combatant = _fighter()
	assert_true(fighter.try_control(100))
	assert_true(fighter.try_control(120))
	# 100 and 120 leave the 180-tick window at 280 and 300: at 290 only the second counts.
	assert_true(fighter.try_control(290), "the first has already expired: it goes through")
	assert_false(fighter.try_control(295), "the 120 one and the 290 one are still inside: the third does not")
	assert_eq(fighter.cc_immune_until, 295 + 120)


func test_health_regenerates_only_out_of_combat() -> void:
	var fighter: Combatant = _fighter()
	var per_second: int = CombatCatalog.rules().health_regen_per_s
	fighter.take_damage(500, 0)
	fighter.mark_combat(0)
	for tick: int in range(1, 599):
		fighter.regenerate(tick, per_second)
	assert_eq(fighter.health, 500, "in combat it does not regenerate")
	# Out of combat: 20 per second, that is, 20 points every 60 ticks.
	for tick: int in range(600, 600 + 60):
		fighter.regenerate(tick, per_second)
	assert_eq(fighter.health, 520, "one second, 20 points")
	for tick: int in range(660, 660 + 120):
		fighter.regenerate(tick, per_second)
	assert_eq(fighter.health, 560)
	# It does not exceed maximum health nor resurrect a dead player.
	for tick: int in range(1000, 1000 + 60 * 60):
		fighter.regenerate(tick, per_second)
	assert_eq(fighter.health, fighter.max_health)
	fighter.mark_dead(5000, 0, 0)
	fighter.regenerate(6000, per_second)
	assert_eq(fighter.health, 0, "a dead player does not regenerate")


func test_dummy_heals_fully_after_five_seconds_without_damage() -> void:
	var fighter: Combatant = _fighter()
	fighter.immortal = true
	fighter.take_damage(900, 100)
	fighter.mark_combat(100)
	fighter.regenerate(399, 20)
	assert_true(fighter.health < fighter.max_health, "at 299 ticks not yet")
	fighter.regenerate(400, 20)
	assert_eq(fighter.health, fighter.max_health, "at 300 ticks it heals fully")


# Phase 4 revision (war): with waves, nobody respawns outside of one, not even through the automatic route.
func test_with_waves_both_the_requested_and_the_automatic_respawn_fall_on_a_wave() -> void:
	_timing.respawn_wave_ticks = 600
	assert_eq(_timing.respawn_tick_for(101), 1200, "requested: the first wave at 10 s or more")
	assert_eq(_timing.auto_respawn_tick_for(101), 2400, "automatic: the first wave at 30 s or more (not 1901)")
	assert_eq(_timing.auto_respawn_tick_for(600), 2400, "at exactly 30 s from a wave, in it")
	assert_eq(_timing.auto_respawn_tick_for(438), 2400)
	var fighter: Combatant = _fighter()
	fighter.mark_dead(101, 0, 0)
	assert_eq(fighter.respawn_tick, 1200)
	assert_eq(fighter.auto_respawn_tick, 2400)
	_timing.respawn_wave_ticks = 0
	assert_eq(_timing.auto_respawn_tick_for(101), 1901, "without waves, at exactly 30 s")


func test_a_combatant_that_asks_on_death_has_its_request_ready_for_its_respawn_tick() -> void:
	var fighter: Combatant = _fighter()
	fighter.requests_respawn_on_death = true
	fighter.mark_dead(100, 0, 0)
	assert_eq(fighter.pending_respawn_point, 0, "requests the first point on death")
	fighter.mark_respawned(800)
	assert_eq(fighter.pending_respawn_point, -1)
	fighter.mark_dead(900, 0, 0)
	assert_eq(fighter.pending_respawn_point, 0, "and on every death")


func test_death_and_respawn_bookkeeping() -> void:
	var fighter: Combatant = _fighter()
	fighter.take_damage(400, 5)
	fighter.note_enemy_hit(9, 3, 5)
	fighter.ledger.record(5, 9, 400)
	fighter.cc_chain.append(4)
	fighter.mark_dead(100, 9, 3)
	assert_true(fighter.is_dead())
	assert_eq(fighter.death_tick, 100)
	assert_eq(fighter.respawn_tick, 100 + _timing.respawn)
	assert_eq(fighter.auto_respawn_tick, 100 + _timing.auto_respawn, "without waves, the automatic one at 30 s")
	assert_eq(fighter.pending_respawn_point, -1, "without requesting anything")
	assert_eq(fighter.killer_id, 9)
	assert_eq(fighter.death_attack_id, 3)
	fighter.mark_respawned(800)
	assert_true(fighter.is_alive())
	assert_eq(fighter.health, fighter.max_health, "full health")
	assert_eq(fighter.death_tick, -1)
	assert_eq(fighter.respawn_tick, 0)
	assert_eq(fighter.auto_respawn_tick, 0)
	assert_eq(fighter.protected_until, 800 + _timing.protection, "3 s of protection")
	assert_true(fighter.is_protected(800 + 179))
	assert_false(fighter.is_protected(800 + 180))
	assert_eq(fighter.ledger.total_damage(800), 0, "the damage ledger is emptied")
	assert_eq(fighter.last_enemy_id, 0)
	assert_eq(fighter.cc_chain.size(), 0)


func test_recent_enemy_credit_window() -> void:
	var fighter: Combatant = _fighter()
	assert_false(fighter.has_recent_enemy(10))
	fighter.note_enemy_hit(4, 2, 100)
	assert_true(fighter.has_recent_enemy(100))
	assert_true(fighter.has_recent_enemy(699), "10 s")
	assert_false(fighter.has_recent_enemy(700))


func test_swing_tracking_one_hit_per_action() -> void:
	var fighter: Combatant = _fighter()
	fighter.track_swing(50)
	assert_false(fighter.has_hit(2))
	fighter.mark_hit(2)
	assert_true(fighter.has_hit(2))
	fighter.track_swing(50)
	assert_true(fighter.has_hit(2), "the same attack remembers whom it hit")
	fighter.track_swing(80)
	assert_false(fighter.has_hit(2), "a new attack forgets")


func test_the_rewind_of_a_swing_is_kept_until_a_new_swing_or_forget_swing() -> void:
	var fighter: Combatant = _fighter()
	fighter.track_swing(50)
	assert_false(fighter.swing_rewind_fixed, "a new attack has no fixed rewind")
	fighter.swing_rewind_fixed = true
	fighter.swing_rewind = 7.0
	fighter.swing_defense_rewind = 9.0
	fighter.track_swing(50)
	assert_true(fighter.swing_rewind_fixed, "the same attack keeps the fixed rewind")
	assert_eq(fighter.swing_rewind, 7.0)
	fighter.forget_swing()
	assert_false(fighter.swing_rewind_fixed, "forget_swing forgets it (and whom it hit)")
	fighter.swing_rewind_fixed = true
	fighter.track_swing(80)
	assert_false(fighter.swing_rewind_fixed, "a new attack forgets it")
	fighter.swing_rewind_fixed = true
	fighter.mark_respawned(100)
	assert_false(fighter.swing_rewind_fixed, "and so does respawning")


func test_freeze_captures_the_state_after_simulating() -> void:
	var fighter: Combatant = _fighter(Vector3(3.0, 0.0, -4.0))
	var state: CombatState = fighter.get_character().combat
	CombatFixture.start_light_active(fighter, 100)
	fighter.entity.teleport_counter = 2
	fighter.freeze(100)
	var frozen: Combatant.Frozen = fighter.frozen
	assert_eq(frozen.tick, 100)
	assert_vec_near(frozen.position, Vector3(3.0, 0.0, -4.0), 1e-4)
	assert_near(frozen.yaw, 0.0, 1e-6)
	assert_eq(frozen.action, CombatState.Action.LIGHT)
	assert_eq(frozen.action_id, state.action_id)
	assert_eq(frozen.action_tick, state.action_tick)
	assert_true(frozen.attack_active, "on the first tick of the active hit")
	assert_false(frozen.hyper_armor, "a light attack has no poise")
	assert_eq((frozen.flags >> EntityRecord.TELEPORT_SHIFT) & EntityRecord.TELEPORT_MASK, 2,
			"the flags carry the teleport counter")
	# A heavy attack in its active hit has poise.
	CombatFixture.start_heavy_active(fighter, 200, 20)
	fighter.freeze(200)
	assert_true(frozen.attack_active)
	assert_true(frozen.hyper_armor, "the heavy attack has poise in the active hit")
	assert_eq(frozen.charge_ticks, 20)
	# Not yet during the windup.
	fighter.freeze(200 - 5)
	assert_false(frozen.attack_active, "during the windup it does not hit yet")
	assert_false(frozen.hyper_armor)
	# When blocking it carries the flag.
	fighter.get_character().combat.action = CombatState.Action.BLOCK
	fighter.get_character().combat.action_tick = 150
	fighter.freeze(200)
	assert_eq(frozen.defense & ActionMachine.DEFENSE_BLOCKING, ActionMachine.DEFENSE_BLOCKING)
	assert_eq(frozen.flags & ActionMachine.DEFENSE_BLOCKING, ActionMachine.DEFENSE_BLOCKING)


func test_publish_updates_the_entity_view() -> void:
	var fighter: Combatant = _fighter()
	fighter.take_damage(250, 3)
	fighter.mark_combat(3)
	fighter.protected_until = 100
	fighter.publish(50)
	var entity: NetEntity = fighter.entity
	assert_eq(entity.health, 750)
	assert_eq(entity.max_health, 1000)
	assert_eq(entity.status, NetMessages.STATUS_IN_COMBAT | NetMessages.STATUS_PROTECTED)
	assert_eq(entity.respawn_tick, 0, "alive: 0")
	assert_eq(entity.health_q, EntityRecord.quantize_health(750, 1000))
	assert_eq(entity.action, ActionMachine.action_byte(fighter.get_character().combat, 50))
	fighter.mark_dead(60, 0, 0)
	fighter.publish(60)
	assert_eq(entity.health, 0)
	assert_eq(entity.health_q, EntityRecord.HEALTH_Q_DEAD)
	assert_eq(entity.status, NetMessages.STATUS_DEAD)
	assert_eq(entity.respawn_tick, fighter.respawn_tick, "dead: the respawn tick")
