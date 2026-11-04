extends TestCase
## Tests for the [CombatDirector] (docs/combate.md, sections 4.2 and 5) with hand-built fighters:
## applying a hit (damage, crits, heavy-attack charge, block, guard break, hitstop), the
## controls (stagger cuts a light attack but not a heavy one with poise, knockback, the root and its
## immunity), death (a single DEATH and KILL with assisters), the environment (fall, lethal volume,
## below y = -100), requested and automatic respawn with protection and the immortal dummy.
## [br][br]
## Since H3c (docs/habilidades.md, section 4.5) the killing blow of a player from another realm in an RVR zone
## knocks down instead of killing (test_downed): the death tests use an NPC attacker ([method _npc_duel]),
## against which one dies directly.
## [br][br]
## There is no network or server: the director receives the bodies and is called tick by tick with
## [method CombatDirector.process_tick].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const HUECOS: int = RealmCatalog.NEUTRAL_CODE
const ZONE_ID: StringName = &"test_world"
const S: int = 400
const HIT_CRITICAL: int = NetMessages.EntityEvent.HIT_FLAG_CRITICAL
const HIT_BLOCKED: int = NetMessages.EntityEvent.HIT_FLAG_BLOCKED
const HIT_PARRIED: int = NetMessages.EntityEvent.HIT_FLAG_PARRIED
const HIT_GUARD_BREAK: int = NetMessages.EntityEvent.HIT_FLAG_GUARD_BREAK
const HIT_LETHAL: int = NetMessages.EntityEvent.HIT_FLAG_LETHAL

var _viewport: SubViewport
var _world: Node3D
var _history: StateHistory
var _director: CombatDirector
var _events: Array[NetMessages.EntityEvent] = []
var _involved: Array[PackedInt32Array] = []


func before_each() -> void:
	_viewport = CombatFixture.make_world(tree.root)
	_world = NetHarness.get_world(_viewport)
	_history = StateHistory.new()
	_director = CombatDirector.new(_history, ZONE_ID, _world, SafeAreas.new(),
			CombatFixture.place, _pick_spawn)
	_events.clear()
	_involved.clear()
	_director.event_emitted.connect(func(event: NetMessages.EntityEvent,
			involved: PackedInt32Array) -> void:
		_events.append(event)
		_involved.append(involved))
	await wait_physics_frames(3)


func after_each() -> void:
	_director = null
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_world = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _pick_spawn(realm: int) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(100.0 + float(realm), 0.0, 100.0))


func _body(net_id: int, realm: int, position: Vector3, yaw: float) -> Combatant:
	var entity: NetEntity = CombatFixture.make_entity(_world, net_id, realm, position, yaw)
	_history.add_entity(net_id)
	return _director.add(entity, CombatFixture.make_queue(yaw), null)


## Like [method _body], but with the player's [param peer] (it can rewind).
func _body_with_peer(net_id: int, realm: int, position: Vector3, yaw: float,
		peer: ServerPeer) -> Combatant:
	var entity: NetEntity = CombatFixture.make_entity(_world, net_id, realm, position, yaw)
	_history.add_entity(net_id)
	return _director.add(entity, CombatFixture.make_queue(yaw), peer)


## Makes the real input of tick [param tick] (S by default) of [param attacker] carry that
## [param view_offset_q] and consumes it, as the server would.
func _set_view_offset(attacker: Combatant, view_offset_q: int, tick: int = S) -> void:
	attacker.queue.reset(tick - 1, NetProtocol.neutral_input(tick - 1, 0.0))
	attacker.queue.push(NetProtocol.neutral_input(tick, 0.0), view_offset_q, tick)
	attacker.queue.take(tick)


## Attacker from Vardheim at the origin facing -Z and a victim from Solmarch 1.5 m in front, facing it.
func _duel() -> Array[Combatant]:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	return [attacker, victim]


## Like [method _duel], but the attacker is an NPC (from Vardheim): its killing blow kills without knocking down
## (docs/habilidades.md, section 4.5). With [param both_npcs] the victim is one too.
func _npc_duel(both_npcs: bool = false) -> Array[Combatant]:
	var duel: Array[Combatant] = _duel()
	duel[0].entity.kind = NetProtocol.EntityKind.NPC
	if both_npcs:
		duel[1].entity.kind = NetProtocol.EntityKind.NPC
	return duel


func _tick(s: int = S) -> void:
	_director.process_tick(s, _world.get_world_3d().direct_space_state)


func _events_of(kind: int) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _events:
		if event.event == kind:
			found.append(event)
	return found


func _light_id(index: int) -> int:
	return CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON)).light_ids[index]


func _combat_of(combatant: Combatant) -> CombatState:
	return combatant.get_character().combat


# --- Damage -----------------------------------------------------------------------------------

func test_light_hit_applies_damage_events_and_combat_state() -> void:
	var duel: Array[Combatant] = _duel()
	CombatFixture.start_light_active(duel[0], S)
	_tick()
	assert_eq(duel[1].health, 1000 - 90, "the light attack takes off 90")
	assert_eq(duel[0].health, 1000, "the attacker loses no health")
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if not assert_eq(hits.size(), 1, "one HIT"):
		return
	assert_eq(hits[0].net_id, 2, "tied to the victim")
	assert_eq(hits[0].attacker, 1)
	assert_eq(hits[0].amount, 90)
	assert_eq(hits[0].hit_flags, 0)
	assert_eq(hits[0].attack_id, _light_id(0))
	assert_eq(hits[0].damage_type, DamageFormula.DamageType.SLASH)
	assert_eq(hits[0].tick, S)
	assert_eq(_involved[0], PackedInt32Array([2, 1]), "victim and attacker are the involved ones")
	assert_true(duel[0].is_in_combat(S) and duel[1].is_in_combat(S), "both enter combat")
	assert_eq(duel[1].ledger.damage_by(1, S), 90, "the damage ledger records it")
	assert_eq(duel[1].last_enemy_id, 1)
	assert_eq(duel[1].entity.health, 910, "and publishes it for the snapshots")
	assert_true((duel[1].entity.status & NetMessages.STATUS_IN_COMBAT) != 0)
	assert_eq(duel[1].entity.health_q, EntityRecord.quantize_health(910, 1000))
	assert_eq(_combat_of(duel[1]).action, CombatState.Action.NONE, "a light attack does not stagger")


func test_back_hit_is_critical_and_charged_heavy_scales_damage() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), 0.0)
	CombatFixture.start_light_active(attacker, S)
	_tick()
	assert_eq(victim.health, 1000 - 135, "from behind: 90 × 1.5")
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	assert_eq(hits[0].hit_flags, HIT_CRITICAL, "marked as a crit")
	# Heavy attack at maximum charge: 180 × 1.7 (and from behind × 1.5).
	var heavy: AttackTicks = CombatCatalog.attack(CombatCatalog.weapon(
			_combat_of(attacker).weapon_id).heavy_id)
	victim.heal_full()
	CombatFixture.start_heavy_active(attacker, S + 100, heavy.charge_max_ticks)
	_director.process_tick(S + 100, _world.get_world_3d().direct_space_state)
	assert_eq(victim.health, 1000 - roundi(180.0 * 1.7 * 1.5), "maximum charge and from behind")
	# No extra charge: only the base damage.
	victim.heal_full()
	CombatFixture.start_heavy_active(attacker, S + 200, heavy.charge_min_ticks)
	_director.process_tick(S + 200, _world.get_world_3d().direct_space_state)
	assert_eq(victim.health, 1000 - roundi(180.0 * 1.5), "minimum charge: base × crit")


func test_no_friendly_fire_and_no_hit_out_of_reach() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var ally: Combatant = _body(2, VARDHEIM, Vector3(0.0, 0.0, -1.5), PI)
	_body(3, SOLMARCH, Vector3(0.0, 0.0, -6.0), PI)
	CombatFixture.start_light_active(attacker, S)
	_tick()
	assert_eq(ally.health, 1000, "no friendly fire")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 0)
	assert_false(attacker.is_in_combat(S), "without hits there is no combat")


# --- Block, guard break and hitstop -----------------------------------------------------------

func test_block_mitigates_all_damage_and_costs_stamina() -> void:
	var duel: Array[Combatant] = _duel()
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 30)
	var stamina_before: int = _combat_of(duel[1]).stamina
	_tick()
	assert_eq(duel[1].health, 1000, "the shield stops all frontal physical damage")
	assert_eq(_combat_of(duel[1]).stamina, stamina_before - 90, "1 stamina per point absorbed")
	assert_eq(_combat_of(duel[1]).stamina_regen_tick, S + CombatCatalog.tables().regen_delay_ticks,
			"spending stamina delays its regeneration")
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].hit_flags, HIT_BLOCKED)
		assert_eq(hits[0].amount, 0)
	assert_eq(_combat_of(duel[1]).action, CombatState.Action.BLOCK, "still blocking")
	assert_true(duel[1].is_in_combat(S), "a block is also combat")


func test_guard_break_with_no_stamina_stuns_and_lets_the_rest_through() -> void:
	var duel: Array[Combatant] = _duel()
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 30)
	_combat_of(duel[1]).stamina = 20
	_tick()
	assert_eq(duel[1].health, 1000 - 70, "what the shield does not absorb goes through (90 - 20)")
	assert_eq(_combat_of(duel[1]).stamina, 0, "runs out of stamina")
	assert_true(_combat_of(duel[1]).is_exhausted(), "exhausted")
	assert_eq(_combat_of(duel[1]).action, CombatState.Action.STUN, "guard break: stunned")
	assert_eq(_combat_of(duel[1]).cc_until_tick, S + 60, "for 1 s")
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].hit_flags, HIT_BLOCKED | HIT_GUARD_BREAK)
		assert_eq(hits[0].amount, 70)


func test_a_guard_break_with_full_stamina_does_not_happen() -> void:
	var duel: Array[Combatant] = _duel()
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 30)
	_combat_of(duel[1]).stamina = 90
	_tick()
	assert_eq(_combat_of(duel[1]).action, CombatState.Action.BLOCK, "just enough")
	assert_eq(_combat_of(duel[1]).stamina, 0)


func test_parry_staggers_the_attacker_and_costs_nothing() -> void:
	var duel: Array[Combatant] = _duel()
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 2, true)
	var stamina_before: int = _combat_of(duel[1]).stamina
	_tick()
	assert_eq(duel[1].health, 1000, "no damage")
	assert_eq(_combat_of(duel[1]).stamina, stamina_before, "and no stamina spent")
	assert_eq(_combat_of(duel[0]).action, CombatState.Action.STAGGER, "the attacker staggers")
	assert_eq(_combat_of(duel[0]).cc_until_tick, S + 36, "0,6 s")
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].hit_flags, HIT_PARRIED)
		assert_eq(hits[0].amount, 0)
		assert_eq(hits[0].attacker, 1)


## R3 (the same bug as C2): two against one. B broke D's guard at S - 10 (stunned until S + 50,
## no stamina); A, with 20 ticks of rewind, hits it with a light attack with no control. The block from 20
## ticks ago cannot break its guard again or extend the stun.
func test_a_rewound_light_on_a_stunned_defender_is_a_plain_hit_and_does_not_extend_the_stun() -> void:
	var peer := ServerPeer.new(7)
	peer.rtt_ticks = 12
	peer.interp_delay_q = 48
	var attacker: Combatant = _body_with_peer(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var defender: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var allowed: int = CombatResolver.allowed_rewind(peer.rtt_ticks, 0, peer.interp_delay_q)
	assert_true(allowed >= 20, "the cap covers 20 ticks (%d)" % allowed)
	_set_view_offset(attacker, 20 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	for tick: int in range(S - 30, S):
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		var flags: int = EntityRecord.FLAG_GROUNDED
		if tick < S - 10:
			flags |= ActionMachine.DEFENSE_BLOCKING
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI, flags)
	var state: CombatState = _combat_of(defender)
	state.stamina = 0
	assert_true(defender.try_control(S - 10))
	ActionMachine.impose_stun(state, S - 10, S + 50)
	CombatFixture.start_light_active(attacker, S)
	_tick()
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1, "one HIT"):
		assert_eq(hits[0].hit_flags, 0, "neither blocked nor guard break")
		assert_eq(hits[0].amount, 90, "full damage")
	assert_eq(state.action, CombatState.Action.STUN, "still stunned")
	assert_eq(state.cc_until_tick, S + 50, "without extending the stun")
	assert_eq(defender.cc_chain.size(), 1, "and without spending another link of the control chain")
	assert_eq(defender.health, 1000 - 90)


## R3, stagger variant: staggered by a hit from behind, the frontal hit of an attacker with
## lag does not \"block\" nor spare it the stagger of light attack 3.
func test_a_rewound_third_light_on_a_staggered_defender_staggers_him_again() -> void:
	var peer := ServerPeer.new(7)
	peer.rtt_ticks = 12
	peer.interp_delay_q = 48
	var attacker: Combatant = _body_with_peer(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var defender: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	_set_view_offset(attacker, 20 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	for tick: int in range(S - 30, S):
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		var flags: int = EntityRecord.FLAG_GROUNDED
		if tick < S - 10:
			flags |= ActionMachine.DEFENSE_BLOCKING
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI, flags)
	var state: CombatState = _combat_of(defender)
	assert_true(defender.try_control(S - 10))
	ActionMachine.impose_stagger(state, S - 10, S + 30, Vector2.ZERO)
	CombatFixture.start_light_active(attacker, S, 2)
	var stamina_before: int = state.stamina
	_tick()
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1, "one HIT"):
		assert_eq(hits[0].hit_flags, 0, "it is not a block")
		assert_eq(hits[0].amount, 130, "full damage of light attack 3")
	assert_eq(state.stamina, stamina_before, "and it does not spend its stamina")
	assert_eq(state.cc_until_tick, S + 18, "the stagger of light attack 3 applies again")


# --- Controls ---------------------------------------------------------------------------------

func test_stagger_cuts_a_light_but_not_a_hyper_armor_heavy() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var cut: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	# The third light attack staggers 0.3 s. The victim was in the windup of its own light attack.
	var state: CombatState = _combat_of(cut)
	state.action = CombatState.Action.LIGHT
	state.action_id = _light_id(0)
	state.action_tick = S - 3
	CombatFixture.start_light_active(attacker, S, 2)
	_tick()
	assert_eq(state.action, CombatState.Action.STAGGER, "the stagger cuts the light attack")
	assert_eq(state.cc_until_tick, S + 18, "0,3 s")
	assert_eq(cut.health, 1000 - 130, "and it takes the damage of light attack 3")

	# With a heavy attack in its active hit (poise) it is not interrupted, but the damage does go through.
	var armored: Combatant = _body(3, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	cut.get_character().global_position = Vector3(50.0, 0.0, 0.0)
	CombatFixture.start_heavy_active(armored, S + 100)
	CombatFixture.start_light_active(attacker, S + 100, 2)
	_director.process_tick(S + 100, _world.get_world_3d().direct_space_state)
	assert_eq(_combat_of(armored).action, CombatState.Action.HEAVY, "poise keeps it going")
	assert_eq(armored.health, 1000 - 130, "the damage goes through anyway")


func test_heavy_knockback_goes_away_from_the_attacker() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	CombatFixture.start_heavy_active(attacker, S)
	_tick()
	var state: CombatState = _combat_of(victim)
	assert_eq(state.action, CombatState.Action.STAGGER)
	assert_eq(state.cc_until_tick, S + 30, "0,5 s")
	assert_vec_near(state.knockback, Vector2(0.0, -4.0), 0.01, "4 m/s away from the attacker")


func test_third_control_in_the_window_does_not_enter_and_opens_immunity() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var state: CombatState = _combat_of(victim)
	var results: Array[bool] = []
	for hit_index: int in 4:
		var s: int = S + hit_index * 40
		state.action = CombatState.Action.NONE
		CombatFixture.start_light_active(attacker, s, 2)
		_director.process_tick(s, _world.get_world_3d().direct_space_state)
		results.append(state.action == CombatState.Action.STAGGER)
	assert_eq(results, [true, true, false, false] as Array[bool],
			"the first two go through; the third and fourth (immunity) do not")
	assert_eq(victim.health, 1000 - 4 * 130, "but the damage always goes through")
	assert_eq(victim.cc_immune_until, S + 80 + 120, "2 s of immunity from the third")
	# Once the immunity has passed, the control applies again.
	var later: int = S + 80 + 121
	state.action = CombatState.Action.NONE
	CombatFixture.start_light_active(attacker, later, 2)
	_director.process_tick(later, _world.get_world_3d().direct_space_state)
	assert_eq(state.action, CombatState.Action.STAGGER, "after the immunity it applies again")


# --- Death ------------------------------------------------------------------------------------

func test_lethal_hit_kills_once_with_death_and_kill_events() -> void:
	var duel: Array[Combatant] = _npc_duel()
	duel[1].health = 50
	CombatFixture.start_light_active(duel[0], S)
	_tick()
	assert_true(duel[1].is_dead())
	assert_eq(duel[1].death_tick, S)
	assert_eq(duel[1].respawn_tick, S + _director.timing.respawn)
	assert_eq(_combat_of(duel[1]).action, CombatState.Action.DEAD)
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].amount, 50, "only what was left")
		assert_eq(hits[0].hit_flags, HIT_LETHAL)
	var deaths: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.DEATH)
	if assert_eq(deaths.size(), 1, "one DEATH"):
		assert_eq(deaths[0].net_id, 2)
		assert_eq(deaths[0].killer, 1)
		assert_eq(deaths[0].attack_id, _light_id(0))
	var kills: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.KILL)
	if assert_eq(kills.size(), 1, "one KILL"):
		assert_eq(kills[0].net_id, 2)
		assert_eq(kills[0].killer, 1)
		assert_eq(kills[0].assistants.size(), 0)
	assert_eq(duel[1].entity.status, NetMessages.STATUS_DEAD)
	assert_eq(duel[1].entity.health_q, EntityRecord.HEALTH_Q_DEAD)
	assert_eq(duel[1].entity.respawn_tick, duel[1].respawn_tick)
	assert_eq(duel[1].killer_id, 1)
	# The following ticks repeat nothing: no more deaths or hits against the corpse.
	for offset: int in range(1, 20):
		_tick(S + offset)
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1, "a single DEATH")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.KILL).size(), 1, "a single KILL")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 1, "and no more hits")
	var stats: Dictionary[StringName, int] = _director.stats
	assert_eq(stats[&"deaths"], 1)
	assert_eq(stats[&"kills"], 1)


func test_kill_lists_the_assistants_of_the_damage_ledger() -> void:
	var duel: Array[Combatant] = _npc_duel()
	duel[1].health = 90
	# Before this hit: 600 from another attacker, 300 from a third and 5 from a fourth.
	duel[1].ledger.record(S - 100, 5, 600)
	duel[1].ledger.record(S - 50, 6, 300)
	duel[1].ledger.record(S - 20, 7, 5)
	CombatFixture.start_light_active(duel[0], S)
	_tick()
	var kills: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.KILL)
	if not assert_eq(kills.size(), 1):
		return
	assert_eq(kills[0].killer, 1)
	assert_eq(kills[0].assistants, PackedInt32Array([5, 6]),
			"those who did at least 10 % damage in the window assist, by descending damage")
	var kill_index: int = _events.find(kills[0])
	assert_eq(_involved[kill_index], PackedInt32Array([2, 1, 5, 6]),
			"the involved include the assisters")


func test_a_kill_by_an_npc_is_credited_to_the_npc_and_allies_and_self_do_not_assist() -> void:
	var npc: Combatant = _body(7, HUECOS, Vector3.ZERO, 0.0)
	var victim: Combatant = _body(2, VARDHEIM, Vector3(0.0, 0.0, -1.5), PI)
	victim.health = 90
	# An ally of the victim (id 3) and the victim itself (id 2) cannot be listed as assisters.
	victim.ledger.record(S - 10, 3, 400)
	victim.ledger.record(S - 5, 2, 400)
	victim.ledger.record(S - 5, 9, 400)
	CombatFixture.start_light_active(npc, S)
	_tick()
	var kills: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.KILL)
	if not assert_eq(kills.size(), 1, "an NPC can kill"):
		return
	assert_eq(kills[0].killer, 7, "the KILL is the NPC's")
	assert_false(kills[0].assistants.has(2), "self-harm does not count")
	assert_true(kills[0].assistants.has(9), "whoever did damage assists")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH)[0].killer, 7)


func test_simultaneous_exchange_can_kill_both() -> void:
	var duel: Array[Combatant] = _npc_duel(true)
	duel[0].health = 50
	duel[1].health = 50
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_light_active(duel[1], S)
	_tick()
	assert_true(duel[0].is_dead() and duel[1].is_dead(), "the two hits of the same tick kill both")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 2)
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.KILL).size(), 2)


# --- Environment ------------------------------------------------------------------------------

func test_fall_damage_above_the_threshold_only() -> void:
	var body: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	body.get_character().last_landing_speed = 14.0
	_tick()
	assert_eq(body.health, 1000, "14 m/s (the 3 m walkway when jumping) does no damage")
	body.get_character().last_landing_speed = 15.0
	_tick(S + 1)
	assert_eq(body.health, 1000, "at the threshold neither")
	body.get_character().last_landing_speed = 23.0
	_tick(S + 2)
	assert_eq(body.health, 1000 - 560, "23 m/s (the 12 m tower): (23 - 15) × 70")
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1, "an environment HIT"):
		assert_eq(hits[0].attacker, 0)
		assert_eq(hits[0].amount, 560)
	assert_true(body.is_in_combat(S + 2), "taking damage puts you in combat")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 0)


func test_fall_death_is_credited_to_the_last_enemy_who_hit_within_ten_seconds() -> void:
	var victim: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	_body(2, SOLMARCH, Vector3(30.0, 0.0, 0.0), 0.0)
	victim.health = 400
	victim.note_enemy_hit(2, _light_id(1), S - 100)
	victim.ledger.record(S - 100, 2, 100)
	victim.get_character().last_landing_speed = 25.0
	_tick()
	assert_true(victim.is_dead(), "700 of fall damage with 400 health")
	var deaths: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.DEATH)
	if assert_eq(deaths.size(), 1):
		assert_eq(deaths[0].killer, 2, "credited to the enemy that hit it")
		assert_eq(deaths[0].attack_id, 0, "no attack: the environment killed it")
	var kills: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.KILL)
	if assert_eq(kills.size(), 1, "and there is a KILL for the enemy"):
		assert_eq(kills[0].killer, 2)
	# Without a recent enemy, the death is the environment's and there is no KILL.
	var lonely: Combatant = _body(3, VARDHEIM, Vector3(0.0, 0.0, 50.0), 0.0)
	lonely.health = 100
	lonely.note_enemy_hit(2, 1, S - 700)
	lonely.get_character().last_landing_speed = 25.0
	_tick(S + 1)
	assert_true(lonely.is_dead())
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH)[1].killer, 0, "more than 10 s ago: environment")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.KILL).size(), 1, "no KILL")


func test_falling_below_the_world_kills_and_moves_the_body_to_the_spawn_while_dead() -> void:
	var body: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	body.get_character().global_position = Vector3(0.0, -150.0, 0.0)
	_tick()
	assert_true(body.is_dead(), "dies")
	assert_eq(_combat_of(body).action, CombatState.Action.DEAD)
	assert_vec_near(body.entity.get_position(), Vector3(101.0, 0.0, 100.0), 1e-3,
			"and the body returns to its realm's spawn point")
	assert_eq(body.entity.teleport_counter, 1, "with teleport counter")
	assert_vec_near(body.get_character().velocity, Vector3.ZERO, 1e-6, "no velocity")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1)
	for offset: int in range(1, 10):
		_tick(S + offset)
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1, "a single DEATH")
	assert_eq(body.entity.teleport_counter, 1, "and it is not placed again")
	assert_eq(_director.stats[&"voids"], 1)


func test_lethal_volume_kills_whoever_is_inside() -> void:
	var inside: Combatant = _body(1, VARDHEIM, Vector3(0.0, 0.0, 0.0), 0.0)
	var outside: Combatant = _body(2, SOLMARCH, Vector3(20.0, 0.0, 0.0), 0.0)
	var area := Area3D.new()
	area.name = "Lava"
	area.collision_layer = 0
	area.collision_mask = PlayerCharacter.CHARACTER_COLLISION_LAYER
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6.0, 4.0, 6.0)
	shape.shape = box
	shape.position = Vector3(0.0, 1.0, 0.0)
	area.add_child(shape)
	area.add_to_group(Zones.LETHAL_GROUP)
	_world.add_child(area)
	await wait_physics_frames(3)
	_tick()
	assert_true(inside.is_dead(), "inside the lethal volume it dies")
	assert_true(outside.is_alive(), "outside nothing happens to it")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1)
	assert_eq(_director.stats[&"lethal_volumes"], 1)


# --- Respawn ----------------------------------------------------------------------------------

func _kill_for_respawn(realm: int = VARDHEIM) -> Combatant:
	_director.timing.respawn = 30
	_director.timing.auto_respawn = 120
	_director.timing.protection = 50
	var body: Combatant = _body(1, realm, Vector3(5.0, 0.0, 5.0), 0.0)
	_director.kill(body, S)
	_events.clear()
	return body


func test_requested_respawn_waits_for_its_tick_and_uses_the_chosen_point() -> void:
	var body: Combatant = _kill_for_respawn()
	assert_true(body.is_dead())
	assert_eq(body.respawn_tick, S + 30)
	assert_eq(_director.request_respawn(1, 1, S + 1), CombatDirector.RespawnRequestResult.TOO_EARLY,
			"long before it can")
	assert_eq(_director.request_respawn(1, 1, S + 20), CombatDirector.RespawnRequestResult.ACCEPTED,
			"a little early it is accepted (the client counts the tick ahead)")
	for offset: int in range(1, 30):
		_tick(S + offset)
	assert_true(body.is_dead(), "it does not respawn before its tick")
	_tick(S + 30)
	assert_true(body.is_alive(), "it respawns at its tick")
	assert_eq(body.health, body.max_health, "with full health")
	assert_eq(_combat_of(body).action, CombatState.Action.NONE, "no action")
	assert_eq(_combat_of(body).stamina, CombatCatalog.rules().stamina_max, "and with full stamina")
	assert_vec_near(body.entity.get_position(), ZoneFixture.VARDHEIM_SPAWNS[1], 0.01,
			"at the second spawn point of its realm")
	assert_eq(body.entity.teleport_counter, 1, "with teleport counter")
	assert_true(body.is_protected(S + 30 + 49), "protected")
	assert_false(body.is_protected(S + 30 + 50), "for the configured protection time")
	assert_true((body.entity.status & NetMessages.STATUS_PROTECTED) != 0, "it is published in the state")
	assert_eq(body.entity.respawn_tick, 0)
	var respawns: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.RESPAWN)
	if assert_eq(respawns.size(), 1, "one RESPAWN"):
		assert_eq(respawns[0].point, 1)
		assert_eq(respawns[0].net_id, 1)
		assert_eq(respawns[0].tick, S + 30)


func test_respawn_request_when_alive_is_out_of_time_and_a_stale_index_uses_the_first_point() -> void:
	var body: Combatant = _body(1, VARDHEIM, Vector3(5.0, 0.0, 5.0), 0.0)
	assert_eq(_director.request_respawn(1, 0, S), CombatDirector.RespawnRequestResult.NOT_DEAD,
			"alive: out of time")
	assert_eq(_director.request_respawn(99, 0, S), CombatDirector.RespawnRequestResult.NOT_DEAD,
			"an unknown id too")
	_director.timing.respawn = 10
	_director.kill(body, S)
	assert_eq(_director.request_respawn(1, 77, S + 10), CombatDirector.RespawnRequestResult.ACCEPTED,
			"an index that is no longer valid is not an error")
	_tick(S + 10)
	assert_true(body.is_alive())
	assert_vec_near(body.entity.get_position(), ZoneFixture.VARDHEIM_SPAWNS[0], 0.01,
			"the first point of the realm is used")


func test_automatic_respawn_after_the_long_wait_in_the_first_point() -> void:
	var body: Combatant = _kill_for_respawn(SOLMARCH)
	for offset: int in range(1, 120):
		_tick(S + offset)
	assert_true(body.is_dead(), "without requesting it, it does not respawn before 30 s")
	_tick(S + 120)
	assert_true(body.is_alive(), "respawns on its own")
	assert_vec_near(body.entity.get_position(), ZoneFixture.SOLMARCH_SPAWN, 0.01)
	assert_eq(_director.stats[&"respawns"], 1)


func test_protection_blocks_hits_and_is_lost_when_attacking() -> void:
	var attacker: Combatant = _body(5, VARDHEIM, Vector3(40.0, 0.0, 0.0), 0.0)
	var body: Combatant = _kill_for_respawn(SOLMARCH)
	_director.request_respawn(1, 0, S + 20)
	_tick(S + 30)
	assert_true(body.is_protected(S + 30))
	# A hit against the newly respawned one does nothing.
	attacker.get_character().global_position = body.entity.get_position() + Vector3(0.0, 0.0, 1.5)
	attacker.get_character().yaw = 0.0
	CombatFixture.start_light_active(attacker, S + 31)
	_director.process_tick(S + 31, _world.get_world_3d().direct_space_state)
	assert_eq(body.health, body.max_health, "protection prevents the damage")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 0)
	# Starting an attack loses the protection.
	_combat_of(body).action = CombatState.Action.LIGHT
	_combat_of(body).action_id = _light_id(0)
	_combat_of(body).action_tick = S + 32
	_director.process_tick(S + 32, _world.get_world_3d().direct_space_state)
	assert_false(body.is_protected(S + 33), "attacking loses the protection")
	assert_eq(body.entity.status & NetMessages.STATUS_PROTECTED, 0)


# --- Dummy ------------------------------------------------------------------------------------

func test_immortal_dummy_never_dies_and_heals_after_five_seconds() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var dummy: Combatant = _body(2, HUECOS, Vector3(0.0, 0.0, -1.5), PI)
	dummy.immortal = true
	dummy.health = 40
	CombatFixture.start_light_active(attacker, S)
	_tick()
	assert_eq(dummy.health, 1, "it does not go below 1")
	assert_true(dummy.is_alive())
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].amount, 90, "the hit announces the whole damage")
		assert_eq(hits[0].hit_flags & HIT_LETHAL, 0, "and it is not lethal")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 0, "no DEATH")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.KILL).size(), 0, "nor KILL")
	# More hits, with different attacks: it stays standing.
	for index: int in 5:
		CombatFixture.start_light_active(attacker, S + 20 * (index + 1), 2)
		_director.process_tick(S + 20 * (index + 1), _world.get_world_3d().direct_space_state)
	assert_true(dummy.is_alive())
	var last_hit: int = S + 100
	_director.process_tick(last_hit + 299, _world.get_world_3d().direct_space_state)
	assert_true(dummy.health < dummy.max_health, "at 299 ticks it has not healed yet")
	_director.process_tick(last_hit + 300, _world.get_world_3d().direct_space_state)
	assert_eq(dummy.health, dummy.max_health, "at 5 s without damage it heals fully")
	var kill_command_target: Combatant = dummy
	_director.kill(kill_command_target, S + 500)
	assert_true(dummy.is_alive(), "not even the kill command can take down a dummy")


func test_publish_keeps_the_action_byte_of_the_record() -> void:
	var duel: Array[Combatant] = _duel()
	CombatFixture.start_block(duel[1], S - 30)
	_tick()
	assert_eq(duel[1].entity.action & 15, CombatState.Action.BLOCK, "the ledger carries the action")
	assert_eq(duel[0].entity.action, ActionMachine.action_byte(_combat_of(duel[0]), S))
