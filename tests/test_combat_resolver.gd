extends TestCase
## Tests for the [CombatResolver] (docs/combate.md, section 4.3) with hand-built scenarios in a
## [SubViewport]: fighters with their character, their input queue and their [Combatant], a
## hand-recorded [StateHistory] and the server without a network.
## [br][br]
## They cover shape and line of sight, defense with its precedence (frontal and rear block,
## hitstop window, dodge invulnerability with the whole window between
## [code]view_tick[/code] and [code]s[/code], the \"drop the shield and attack\" rule), one hit per
## action, the simultaneous exchange, rewind (a hit with the target where it was and rejection
## above the cap) and the candidates (realms, protection, safe zones, the dead).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
const ZONE_ID: StringName = &"test_world"
## Tick at which it resolves (far from 0 so there is history).
const S: int = 200
const PI_YAW: float = PI

var _viewport: SubViewport
var _world: Node3D
var _history: StateHistory
var _timing: CombatTiming
var _resolver: CombatResolver
var _fighters: Array[Combatant] = []


func before_each() -> void:
	_viewport = CombatFixture.make_world(tree.root)
	_world = NetHarness.get_world(_viewport)
	_history = StateHistory.new()
	_timing = CombatTiming.from_rules(CombatCatalog.rules())
	_resolver = CombatResolver.new(_history, ZONE_ID)
	_fighters.clear()
	# The collision bodies enter the physics space in the first steps.
	await wait_physics_frames(3)


func after_each() -> void:
	_fighters.clear()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_world = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _fighter(net_id: int, realm: int, position: Vector3, yaw: float,
		peer: ServerPeer = null) -> Combatant:
	var fighter: Combatant = CombatFixture.make_fighter(_world, net_id, realm, position, yaw,
			_timing, peer)
	_history.add_entity(net_id)
	_fighters.append(fighter)
	return fighter


## Attacker from Vardheim at the origin facing -Z, and a victim from Solmarch [param distance] meters
## in front of it, facing it.
func _duel(distance: float = 1.5) -> Array[Combatant]:
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -distance), PI_YAW)
	return [attacker, victim]


## Resolves tick [param s]. With [param fresh] (default) it forgets whom each attacker had already
## hit, to repeat the same attack with different positions.
func _resolve(s: int = S, fresh: bool = true) -> Array[CombatResolver.Hit]:
	for fighter: Combatant in _fighters:
		if fresh:
			fighter.forget_swing()
		fighter.freeze(s)
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	return _resolver.resolve(s, _fighters, space)


## Records the history of all fighters at ticks [param from] to [param to] (inclusive)
## with their current state.
func _record_all(from_tick: int, to_tick: int) -> void:
	for tick: int in range(from_tick, to_tick + 1):
		for fighter: Combatant in _fighters:
			CombatFixture.record(_history, fighter, tick)


## A peer with an RTT of 4 ticks and 6 of interpolation: rewind cap of 4 + 0 + 6 + 2 = 12.
func _lagged_peer() -> ServerPeer:
	var peer := ServerPeer.new(7)
	peer.rtt_ticks = 4
	peer.interp_delay_q = 48
	return peer


## Makes the real input of tick [param tick] (S by default) of the attacker carry that
## [param view_offset_q] and consumes it, as the server would.
func _set_view_offset(attacker: Combatant, view_offset_q: int, tick: int = S) -> void:
	attacker.queue.reset(tick - 1, NetProtocol.neutral_input(tick - 1, 0.0))
	attacker.queue.push(NetProtocol.neutral_input(tick, 0.0), view_offset_q, tick)
	attacker.queue.take(tick)


## Records the victim (net_id 2) blocking head-on at ticks S - 30 to [param last_block] and not
## blocking at the following ones up to S - 1, and the attacker standing still.
func _record_block_until(last_block: int) -> void:
	for tick: int in range(S - 30, S):
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		var flags: int = EntityRecord.FLAG_GROUNDED
		if tick <= last_block:
			flags |= ActionMachine.DEFENSE_BLOCKING
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI_YAW, flags)


## Attacker queue with real inputs for ticks [param from_tick] to S - 1 arrived with
## [param normal_lead] ticks of lead and the one for tick S with [param s_lead] and that
## [param view_offset_q]; all consumed, as the server would.
func _fill_queue(attacker: Combatant, from_tick: int, normal_lead: int, s_lead: int,
		view_offset_q: int) -> void:
	attacker.queue.reset(from_tick - 1, NetProtocol.neutral_input(from_tick - 1, 0.0))
	for tick: int in range(from_tick, S):
		attacker.queue.push(NetProtocol.neutral_input(tick, 0.0), 0, tick - normal_lead)
		attacker.queue.take(tick)
	attacker.queue.push(NetProtocol.neutral_input(S, 0.0), view_offset_q, S - s_lead)
	attacker.queue.take(S)


## A LAN attacker (RTT of 2 ticks) that declares the maximum interpolation delay.
func _lan_cheater() -> ServerPeer:
	var peer := ServerPeer.new(9)
	peer.rtt_ticks = 2
	peer.rtt_peak_ticks = 2
	peer.interp_delay_q = NetProtocol.MAX_INTERP_DELAY_Q
	return peer


## A victim moving away head-on at 5 m/s: at 2.23 m from the attacker at S - 24 and at 4.23 m at S (the reach,
## with the capsule radius, is 3.0 m).
func _retreating_victim() -> Combatant:
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -4.23), PI_YAW)
	for tick: int in range(S - 30, S):
		var distance: float = 2.23 + float(tick - (S - 24)) * 5.0 / 60.0
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(0.0, 0.0, -distance), PI_YAW, EntityRecord.FLAG_GROUNDED)
	return victim


func _outcomes(hits: Array[CombatResolver.Hit]) -> Array[int]:
	var result: Array[int] = []
	for hit: CombatResolver.Hit in hits:
		result.append(hit.outcome)
	return result


# --- Shape and line of sight ------------------------------------------------------------------

func test_hit_inside_the_sector() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if not assert_eq(hits.size(), 1, "a hit"):
		return
	assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)
	assert_true(hits[0].attacker == duel[0] and hits[0].victim == duel[1], "de 1 a 2")
	assert_near(hits[0].view_tick, float(S), 1e-6, "without rewind")
	assert_near(hits[0].rewind, 0.0, 1e-6)
	assert_false(hits[0].critical, "head-on it is not a crit")
	assert_eq(hits[0].attack.id, CombatCatalog.attack_id(&"sword_light_1"))


func test_misses_outside_the_sector() -> void:
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0)
	CombatFixture.start_light_active(attacker, S)
	# Out of reach (2.6 + 0.4 of radius).
	var far: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -3.2), 0.0)
	assert_eq(_resolve().size(), 0, "at 3.2 m it does not reach")
	far.get_character().global_position = Vector3(0.0, 0.0, -2.9)
	assert_eq(_resolve().size(), 1, "at 2.9 m (reach plus radius) it does")
	# Behind the attacker.
	far.get_character().global_position = Vector3(0.0, 0.0, 1.5)
	assert_eq(_resolve().size(), 0, "behind its back no")
	# To the sides: 100° of arc, so 50° on each side plus what the capsule takes up.
	far.get_character().global_position = Vector3(1.5, 0.0, -0.3)
	assert_eq(_resolve().size(), 0, "almost sideways (79°) no")
	far.get_character().global_position = Vector3(1.0, 0.0, -1.0)
	assert_eq(_resolve().size(), 1, "at 45° yes")
	# Above: the sector heights are 0.2 to 2.0 m above the attacker's feet.
	far.get_character().global_position = Vector3(0.0, 2.5, -1.5)
	assert_eq(_resolve().size(), 0, "two and a half meters above no")


func test_a_wall_in_between_blocks_the_hit() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	var wall := StaticBody3D.new()
	wall.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	wall.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 3.0, 0.2)
	shape.shape = box
	shape.position = Vector3(0.0, 1.5, -0.8)
	wall.add_child(shape)
	_world.add_child(wall)
	await wait_physics_frames(2)
	assert_eq(_resolve().size(), 0, "behind a wall there is no hit")
	_world.remove_child(wall)
	wall.free()
	await wait_physics_frames(2)
	assert_eq(_resolve().size(), 1, "without the wall, yes")


func test_back_attack_is_critical() -> void:
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0)
	# The victim faces the same direction as the attacker: it turns its back to it.
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), 0.0)
	CombatFixture.start_light_active(attacker, S)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)
		assert_true(hits[0].critical, "from behind it is a crit")


# --- Defense ----------------------------------------------------------------------------------

func test_frontal_block_yes_and_back_block_no() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 30)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.BLOCKED, "the shield facing blocks")
	# With its back to the attacker the block cone does not cover it.
	duel[1].get_character().yaw = 0.0
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "from behind it does not block")
		assert_true(hits[0].critical, "and it is a crit")


func test_parry_inside_and_outside_the_window() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	var window: int = CombatCatalog.rules().parry_window_ticks
	CombatFixture.start_light_active(duel[0], S)
	# The parry window opened window - 1 ticks ago: the last tick of the window.
	CombatFixture.start_block(duel[1], S - window + 1, true)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.PARRIED, "inside the window, parry")
	# One tick later the window closed: it is now a normal block.
	CombatFixture.start_block(duel[1], S - window, true)
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.BLOCKED, "outside the window, block")


func test_invulnerable_dodge_has_no_effect_and_does_not_consume_the_swing() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	var dodge_ticks: DodgeTicks = CombatCatalog.weapon(duel[1].get_character().combat.weapon_id).dodge
	# The dodge started 10 ticks ago: tick S is within its invulnerable ticks.
	var start: int = S - dodge_ticks.invulnerable_from_ticks - 2
	CombatFixture.start_dodge(duel[1], start)
	assert_true(ActionMachine.is_invulnerable(duel[1].get_character().combat, S), "invulnerable at S")
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.INVULNERABLE)
	assert_false(duel[0].has_hit(2), "invulnerability does not consume the hit")
	# Once the invulnerability has passed, the same attack does land.
	CombatFixture.start_dodge(duel[1], S - dodge_ticks.invulnerable_to_ticks)
	assert_false(ActionMachine.is_invulnerable(duel[1].get_character().combat, S))
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "it lands at the end")


func test_invulnerability_is_found_even_when_the_whole_window_falls_between_view_tick_and_s() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_set_view_offset(attacker, 10 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	# History: the victim dodged between S - 8 and S - 3 (invulnerable for part of those ticks) and
	# now, at S, is no longer invulnerable nor was it at view_tick (S - 10).
	var dodge: DodgeTicks = CombatCatalog.weapon(victim.get_character().combat.weapon_id).dodge
	for tick: int in range(S - 12, S):
		var flags: int = EntityRecord.FLAG_GROUNDED
		var dodge_age: int = tick - (S - 8)
		if dodge_age >= dodge.invulnerable_from_ticks and dodge_age < dodge.invulnerable_from_ticks + 2:
			flags |= ActionMachine.DEFENSE_INVULNERABLE
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI_YAW, flags)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.INVULNERABLE,
				"the hit falls in the rewound invulnerable window")
		assert_near(hits[0].view_tick, float(S - 10), 1e-4)
		assert_near(hits[0].rewind, 10.0, 1e-4)
	assert_false(attacker.has_hit(2), "without consuming")


func test_releasing_the_shield_to_attack_removes_the_old_block() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_set_view_offset(attacker, 8 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	# At view_tick (S - 8) and the earlier ticks the victim was blocking; afterwards it dropped the shield and
	# started an attack at S - 3.
	for tick: int in range(S - 12, S):
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI_YAW,
				EntityRecord.FLAG_GROUNDED | ActionMachine.DEFENSE_BLOCKING)
	var state: CombatState = victim.get_character().combat
	state.action = CombatState.Action.LIGHT
	state.action_id = CombatCatalog.attack_id(&"sword_light_1")
	state.action_tick = S - 3
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT,
				"whoever drops the shield and attacks is no longer protected")
	# If instead it keeps blocking now, the view_tick block and the S one count.
	CombatFixture.start_block(victim, S - 20)
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.BLOCKED)
	# And if it was blocking at view_tick but is now idle, the view_tick block protects.
	state.action = CombatState.Action.NONE
	state.action_id = 0
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.BLOCKED,
				"the view_tick defender who no longer attacks keeps its block")


func test_a_dodge_started_after_view_tick_also_drops_the_old_block() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_set_view_offset(attacker, 8 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	for tick: int in range(S - 12, S):
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI_YAW,
				EntityRecord.FLAG_GROUNDED | ActionMachine.DEFENSE_BLOCKING)
	# Dodge started at S - 2: at S it is not yet invulnerable (the invulnerable ticks start later),
	# but the block from 8 ticks ago no longer counts.
	CombatFixture.start_dodge(victim, S - 2)
	var dodge: DodgeTicks = CombatCatalog.weapon(victim.get_character().combat.weapon_id).dodge
	if dodge.invulnerable_from_ticks <= 2:
		return
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)


## C2/R3: a control imposed after view_tick (stun, stagger) also lowers the shield: the
## rewound block sample no longer protects (nor punishes) someone who is stunned or staggering.
func test_a_defender_stunned_after_view_tick_loses_the_old_block() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_set_view_offset(attacker, 10 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	# It was blocking until S - 8; at S - 7 its guard was broken (stunned until S + 53, no stamina).
	_record_block_until(S - 8)
	var state: CombatState = victim.get_character().combat
	state.stamina = 0
	ActionMachine.impose_stun(state, S - 7, S + 53)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT,
				"stunned at s: the sample from 10 ticks ago does not count")


func test_a_defender_staggered_after_view_tick_loses_the_old_block() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_set_view_offset(attacker, 10 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	# It was blocking until S - 9, started a light attack at S - 8 and a hit left it staggering at S - 5.
	_record_block_until(S - 9)
	var state: CombatState = victim.get_character().combat
	state.action = CombatState.Action.LIGHT
	state.action_id = CombatCatalog.attack_id(&"sword_light_1")
	state.action_tick = S - 8
	ActionMachine.impose_stagger(state, S - 5, S + 13, Vector2.ZERO)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT,
				"staggering at s: it is not protected by its block from 10 ticks ago")


func test_a_defender_that_only_released_the_shield_keeps_the_old_block() -> void:
	# C2 control: dropping the shield without doing anything else (NONE at s) keeps the view_tick sample.
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_set_view_offset(attacker, 10 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	_record_block_until(S - 8)
	CombatFixture.start_block(victim, S - 30)
	victim.get_character().combat.action = CombatState.Action.NONE
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.BLOCKED,
				"it dropped the shield 7 ticks ago: what the attacker saw still holds")
	# And if it truly keeps blocking, too (the stun wears off when it ends).
	CombatFixture.start_block(victim, S - 30)
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.BLOCKED)


# --- One hit per action ------------------------------------------------------------------------

func test_one_impact_per_action_and_target() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	assert_eq(_resolve(S, false).size(), 1, "the first active tick lands")
	var attack: AttackTicks = CombatCatalog.attack(duel[0].get_character().combat.action_id)
	# The other active ticks of the same attack do not hit again.
	for offset: int in range(1, attack.active_ticks):
		assert_eq(_resolve(S + offset, false).size(), 0, "active tick +%d: it already hit" % offset)
	# A new attack (another action_tick) does.
	CombatFixture.start_light_active(duel[0], S + 20, 1)
	assert_eq(_resolve(S + 20, false).size(), 1, "the next attack hits again")


func test_a_blocked_or_parried_swing_is_also_consumed() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 30)
	assert_eq(_resolve(S, false).size(), 1, "blocked")
	assert_eq(_resolve(S + 1, false).size(), 0,
			"a blocked hit is not repeated on the next tick")


func test_simultaneous_exchange_resolves_both_hits() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_light_active(duel[1], S)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if not assert_eq(hits.size(), 2, "the two hits of the same tick"):
		return
	assert_true(hits[0].attacker == duel[0] and hits[0].victim == duel[1], "first 1 -> 2")
	assert_true(hits[1].attacker == duel[1] and hits[1].victim == duel[0], "then 2 -> 1")
	assert_eq(_outcomes(hits), [CombatResolver.Outcome.IMPACT, CombatResolver.Outcome.IMPACT])


# --- Rewind -----------------------------------------------------------------------------------

func test_allowed_rewind_formula() -> void:
	assert_eq(CombatResolver.allowed_rewind(4, 0, 48), 12, "4 + 0 + 6 + 2")
	assert_eq(CombatResolver.allowed_rewind(0, 0, 0), 6, "interpolation rises to the minimum of 4")
	assert_eq(CombatResolver.allowed_rewind(2, 3, 200), 19, "2 + 3 + 12 (maximum) + 2")
	assert_eq(CombatResolver.allowed_rewind(30, 10, 96), NetProtocol.MAX_REWIND_TICKS, "cap of 24")
	assert_eq(CombatResolver.allowed_rewind(4, -3, 48), 12, "a negative lead counts as 0")
	# Phase 4 revision (cheats): interpolation is rounded up (truncated, it lost up to 7/8 of a tick
	# of an honest player's view).
	assert_eq(CombatResolver.allowed_rewind(4, 0, 41), 12, "4 + 0 + ceil(5.125) + 2")
	assert_eq(CombatResolver.allowed_rewind(4, 0, 47), 12, "4 + 0 + ceil(5.875) + 2")


func test_rewound_hit_lands_where_the_attacker_saw_the_target() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(4.2, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	# History: the victim was in front until S - 6 and moved sideways at 0.7 m per tick.
	for tick: int in range(S - 12, S):
		var x: float = maxf(0.0, float(tick - (S - 6))) * 0.7
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(x, 0.0, -1.5), PI_YAW, EntityRecord.FLAG_GROUNDED)
	_set_view_offset(attacker, 0)
	assert_eq(_resolve().size(), 0, "without rewind, the victim is already outside the arc")
	_set_view_offset(attacker, 6 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "with 6 ticks of rewind, it lands where it saw it"):
		assert_near(hits[0].view_tick, float(S - 6), 1e-4)
		assert_near(hits[0].rewind, 6.0, 1e-4)


func test_rewind_between_s_minus_one_and_s_interpolates() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	# The victim moves away head-on: it was at 2.5 m at S - 1 and is at 3.3 m now (the reach, with
	# the capsule radius, is 3.0 m). A quarter of a tick back it has covered 75 % (3.1 m:
	# outside); three quarters of a tick back, 25 % (2.7 m: inside).
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -3.3), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_history.record(S - 1, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
	_history.record(S - 1, 2, Vector3(0.0, 0.0, -2.5), PI_YAW, EntityRecord.FLAG_GROUNDED)
	_set_view_offset(attacker, 4)
	assert_eq(_resolve().size(), 0, "a quarter of a tick back (3.1 m) it is still outside")
	_set_view_offset(attacker, 12)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "three quarters of a tick back (2.7 m) it is inside"):
		assert_near(hits[0].view_tick, float(S) - 0.75, 1e-4)
		assert_near(hits[0].rewind, 0.75, 1e-4)


func test_rewind_beyond_the_cap_is_rejected_and_counts_suspicion() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	for tick: int in range(S - 30, S):
		for fighter: Combatant in _fighters:
			CombatFixture.record(_history, fighter, tick)
	var allowed: int = CombatResolver.allowed_rewind(peer.rtt_ticks, 0, peer.interp_delay_q)
	assert_eq(allowed, 12)
	var slack: int = CombatResolver.REWIND_REJECT_SLACK_TICKS
	# Up to allowed + slack it is accepted (capped): view_tick ends up at S - allowed.
	_set_view_offset(attacker, (allowed + slack) * CombatResolver.VIEW_OFFSET_Q_SCALE)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "allowed + slack is not rejected"):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)
		assert_near(hits[0].view_tick, float(S - allowed), 1e-4, "and is clamped to the cap")
	assert_eq(peer.suspicion_score, 0)
	# Above allowed + slack, the hit is not even tested.
	_set_view_offset(attacker, (allowed + slack) * CombatResolver.VIEW_OFFSET_Q_SCALE + 1)
	hits = _resolve()
	if assert_eq(hits.size(), 1, "a rejection entry"):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.REWIND_REJECTED)
		assert_null(hits[0].victim, "no target")
	assert_eq(peer.suspicion_score, 1, "adds to suspicion")
	assert_eq(peer.rewind_rejects, 1)
	assert_eq(_resolver.rewind_rejects, 1)
	# The same attack does not add again on the next active tick (the replacement inherits the request).
	attacker.queue.take(S + 1)
	hits = _resolve(S + 1, false)
	assert_eq(hits.size(), 0, "already rejected")
	assert_eq(peer.suspicion_score, 1, "it is counted once per attack")
	# With 40 ticks (the cheating bot from the document) as well.
	CombatFixture.start_light_active(attacker, S + 30)
	_set_view_offset(attacker, 40 * CombatResolver.VIEW_OFFSET_Q_SCALE, S + 30)
	hits = _resolve(S + 30)
	assert_eq(_outcomes(hits), [CombatResolver.Outcome.REWIND_REJECTED], "40 ticks of rewind")
	assert_eq(peer.suspicion_score, 2)


## Phase 4 revision (\"cheats\" lens): with a process hitch or low FPS, the client chains several physics
## steps in one frame and step k declares the view of the last drawn frame, k ticks older (and its
## inputs arrive with less lead). With the earlier cap + 1, the hit of an honest player that fell on the seventh of
## eight steps was rejected whole and added suspicion (the cause of the intermittent failure of the \"rate\" cheater in
## test_net_processes: s=647, vq=385 with a cap of 23). Now it is clamped to the cap, like one that over-declares.
func test_a_late_frame_of_an_honest_client_is_clamped_to_the_cap_not_rejected() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_record_all(S - 30, S - 1)
	var allowed: int = CombatResolver.allowed_rewind(peer.rtt_ticks, 0, peer.interp_delay_q)
	# The earlier one (allowed + 1) plus 7 physics steps of an 8-step frame.
	_set_view_offset(attacker, (allowed + 1 + 7) * CombatResolver.VIEW_OFFSET_Q_SCALE)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "the hit is tested"):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "and lands")
		assert_near(hits[0].rewind, float(allowed), 1e-4, "clamped to the cap")
	assert_eq(peer.suspicion_score, 0, "no suspicion")
	assert_eq(peer.rewind_rejects, 0)
	assert_eq(_resolver.rewind_rejects, 0)
	# The rewind that is used does not exceed the cap: whoever over-declares gains nothing.
	var fixed: Vector2 = CombatResolver.compute_rewind(attacker, S)
	assert_near(fixed.x, float(allowed), 1e-4, "compute_rewind (also the arrows') gives the cap")


## With jitter, the minimum RTT of the window ends up below the travel time of any given tick: an
## honest player whose view goes further back than the minimum covers must not be rejected nor
## suspicious. The cap uses the larger of the two (the maximum is already bounded by a source the client
## does not control).
func test_the_cap_covers_the_worst_round_trips_of_the_window_not_only_the_best() -> void:
	var peer: ServerPeer = _lagged_peer()
	peer.rtt_peak_ticks = 10
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	for tick: int in range(S - 30, S):
		for fighter: Combatant in _fighters:
			CombatFixture.record(_history, fighter, tick)
	# With the minimum (4) the cap would be 12 and 17 ticks would be rejected; with the maximum (10) it is 18.
	assert_eq(CombatResolver.allowed_rewind(peer.rtt_ticks, 0, peer.interp_delay_q), 12)
	_set_view_offset(attacker, 17 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "a view of 17 ticks goes through"):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)
		assert_near(hits[0].view_tick, float(S - 17), 1e-4, "without clamping")
	assert_eq(peer.suspicion_score, 0, "and adds no suspicion")
	# The cap is still a cap: 20 ticks are clamped to 18 and 27 exceed the slack (18 + 8).
	_set_view_offset(attacker, 20 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	hits = _resolve()
	if assert_eq(hits.size(), 1, "20 ticks"):
		assert_near(hits[0].view_tick, float(S - 18), 1e-4, "20 ticks are clamped to the cap of 18")
	_set_view_offset(attacker, 27 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	assert_eq(_outcomes(_resolve()), [CombatResolver.Outcome.REWIND_REJECTED], "27 ticks, no")
	assert_eq(peer.suspicion_score, 1)


## R1: the client does not pick the cap. A cheater with a LAN RTT sends only the inputs of its hit about
## 14 ticks before the others and declares the maximum interpolation delay: before, the cap rose to 24 for it
## (an honest player with the same ping has 12-16) and it could reach someone moving away. Now the lead of that
## input does not exceed the usual one plus 3, and the cap is 2 + 3 + 12 + 2 = 19.
func test_an_isolated_early_input_does_not_raise_the_rewind_cap() -> void:
	var peer: ServerPeer = _lan_cheater()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_retreating_victim()
	CombatFixture.start_light_active(attacker, S)
	_fill_queue(attacker, S - 20, 0, 14, 24 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	assert_eq(attacker.queue.get_rewind_params(S).y, 14, "the input of S arrived with 14 of lead")
	assert_eq(attacker.queue.get_typical_lead(S), 0, "and the usual is 0")
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "one result"):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "24 ticks go through clamped")
		assert_near(hits[0].view_tick, float(S - 19), 1e-4,
				"24 ticks of rewind with an RTT of 2: the cap is 19, not 24")
	assert_eq(peer.suspicion_score, 0, "within the cap's slack it adds no suspicion")
	# Above the slack (19 + 8), it is rejected and adds suspicion.
	_fill_queue(attacker, S - 20, 0, 14, 28 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.REWIND_REJECTED, "28 ticks, no")
	assert_eq(peer.suspicion_score, 1, "and adds suspicion")
	# An honest player with a lead of 3 on all its inputs loses nothing: the cap is still
	# rtt + lead + interpolation + 2 (2 + 3 + 12 + 2 = 19), and one more tick is clamped.
	_fill_queue(attacker, S - 20, 3, 3, 20 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "(honest) 20 = cap + 1 goes through")
		assert_near(hits[0].view_tick, float(S - 19), 1e-4, "(honest) clamped to the cap of 19")


func test_a_client_that_is_always_ahead_gets_at_most_the_lead_credit() -> void:
	# A client with all its inputs 14 ticks ahead does not raise the cap beyond the maximum lead
	# that the server credits (8): 2 + 8 + 6 + 2 = 18.
	var peer := ServerPeer.new(9)
	peer.rtt_ticks = 2
	peer.rtt_peak_ticks = 2
	peer.interp_delay_q = 48
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_retreating_victim()
	CombatFixture.start_light_active(attacker, S)
	_fill_queue(attacker, S - 20, 14, 14, 24 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_near(hits[0].view_tick, float(S - 18), 1e-4, "24 ticks with a cap of 18 are clamped to 18")
	_fill_queue(attacker, S - 20, 14, 14, 27 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.REWIND_REJECTED, "27 ticks exceed the slack (18 + 8)")
	_fill_queue(attacker, S - 20, 14, 14, 18 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "18 ticks go through")
		assert_near(hits[0].view_tick, float(S - 18), 1e-4)


## R1: the rewind is fixed at the first active tick of the hit and advances with it. Before, each active tick
## read its own view_offset_q and the cheater swept the window (0, 24, 0...).
func test_a_swing_keeps_the_rewind_of_its_first_active_tick() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	# The third one is only in reach at S - 5 (a flash in its track) and is now far away.
	_fighter(3, SOLMARCH, Vector3(0.0, 0.0, -5.0), PI_YAW)
	for tick: int in range(S - 30, S):
		var z: float = -2.0 if tick == S - 5 else -5.0
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI_YAW, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 3, Vector3(0.0, 0.0, z), PI_YAW, EntityRecord.FLAG_GROUNDED)
	CombatFixture.start_light_active(attacker, S)
	_set_view_offset(attacker, 6 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "at S only the second one lands"):
		assert_eq(hits[0].victim.get_id(), 2)
		assert_near(hits[0].view_tick, float(S - 6), 1e-4, "with 6 ticks of rewind")
	# On the next active tick the client asks for 0 (or 24): the hit keeps its 6 ticks, that is,
	# looking at S + 1 - 6 = S - 5, where the third one was in reach.
	for claimed: int in [0, 24, 3]:
		attacker.swing_hits.erase(3)
		_set_view_offset(attacker, claimed * CombatResolver.VIEW_OFFSET_Q_SCALE, S + 1)
		hits = _resolve(S + 1, false)
		if assert_eq(hits.size(), 1, "(asks %d) at S + 1 it hits the third one" % claimed):
			assert_eq(hits[0].victim.get_id(), 3)
			assert_near(hits[0].view_tick, float(S + 1 - 6), 1e-4,
					"(asks %d) with the rewind fixed at S: 6 ticks" % claimed)
	assert_eq(peer.suspicion_score, 0, "no suspicion")


func test_a_rejected_swing_stays_rejected_whatever_the_next_ticks_ask() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_set_view_offset(attacker, 40 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	assert_eq(_outcomes(_resolve()), [CombatResolver.Outcome.REWIND_REJECTED])
	# The next tick asks for a reasonable rewind: the hit stays rejected (a single notice).
	_set_view_offset(attacker, 0, S + 1)
	var hits: Array[CombatResolver.Hit] = _resolve(S + 1, false)
	assert_eq(hits.size(), 0, "the hit is not tested even though it now asks for 0")
	assert_eq(peer.suspicion_score, 1)


## R1: without rewind (view_offset_q = 0) one does not escape retroactive parries, blocks and
## invulnerabilities: the server imposes at least the rewind consistent with the RTT measured by ENet
## (rtt_floor_ticks + 4 - 2), for defense.
func test_offset_zero_does_not_escape_the_retroactive_parry() -> void:
	var peer: ServerPeer = _lagged_peer()
	peer.rtt_floor_ticks = 4
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	# The victim parried between S - 8 and S - 3 (6-tick window) and already lowered the shield at S.
	for tick: int in range(S - 12, S):
		var flags: int = EntityRecord.FLAG_GROUNDED
		if tick >= S - 8 and tick <= S - 3:
			flags |= ActionMachine.DEFENSE_BLOCKING | ActionMachine.DEFENSE_PARRY
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI_YAW, flags)
	_set_view_offset(attacker, 0)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.PARRIED,
				"with an RTT of 4 ticks the attacker cannot see the world without delay: S - 6 is parrying")
		assert_near(hits[0].view_tick, float(S), 1e-6, "the geometry stays at what it asked")
	# An honest player who asks for 6 ticks (its real view) gets the same.
	_set_view_offset(attacker, 6 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.PARRIED, "(6 ticks requested)")
	# Without a measured RTT (floor 0) the minimum is 2 ticks and the parry from 6 ago does not count.
	peer.rtt_floor_ticks = 0
	_set_view_offset(attacker, 0)
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "(no measured RTT)")


func test_offset_zero_does_not_escape_the_retroactive_invulnerability() -> void:
	var peer: ServerPeer = _lagged_peer()
	peer.rtt_floor_ticks = 4
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	# The victim was invulnerable at S - 5 and S - 4 (a dodge) and at S it no longer is.
	for tick: int in range(S - 12, S):
		var flags: int = EntityRecord.FLAG_GROUNDED
		if tick == S - 5 or tick == S - 4:
			flags |= ActionMachine.DEFENSE_INVULNERABLE
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI_YAW, flags)
	_set_view_offset(attacker, 0)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.INVULNERABLE,
				"the invulnerability from 5 ticks ago counts even if it asks for 0")
	assert_false(attacker.has_hit(2), "and does not consume the hit")


func test_substituted_input_uses_the_last_real_rewind() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	for tick: int in range(S - 30, S):
		for fighter: Combatant in _fighters:
			CombatFixture.record(_history, fighter, tick)
	# The last real input (tick S - 1) asked for 5 ticks; the one for tick S was substituted.
	_set_view_offset(attacker, 5 * CombatResolver.VIEW_OFFSET_Q_SCALE, S - 1)
	attacker.queue.take(S)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_near(hits[0].view_tick, float(S - 5), 1e-4, "the replacement inherits the rewind")


func test_fakes_and_npcs_never_rewind() -> void:
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_near(hits[0].view_tick, float(S), 1e-6)


func test_a_target_that_did_not_exist_at_view_tick_is_discarded() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	# The victim only has history since S - 2, and the attacker asks to look 6 ticks back.
	for tick: int in range(S - 2, S):
		for fighter: Combatant in _fighters:
			CombatFixture.record(_history, fighter, tick)
	_set_view_offset(attacker, 6 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	assert_eq(_resolve().size(), 0, "without a sample there is no hit")


# --- Candidates -------------------------------------------------------------------------------

func test_allies_are_never_hit_and_realms_need_an_rvr_zone() -> void:
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0)
	var ally: Combatant = _fighter(2, VARDHEIM, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	assert_eq(_resolve().size(), 0, "no friendly fire")
	ally.entity.realm = ASKARRA
	assert_eq(_resolve().size(), 1, "an enemy realm in an RVR zone")
	# In a safe zone the realms do not damage each other.
	var safe_zone := CombatResolver.new(_history, &"zona_segura_inventada")
	for fighter: Combatant in _fighters:
		fighter.freeze(S)
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	assert_eq(safe_zone.resolve(S, _fighters, space).size(), 0, "SAFE zone: no damage between realms")
	# A Hollow (neutral faction) is hostile to everyone.
	attacker.forget_swing()
	ally.entity.realm = RealmCatalog.NEUTRAL_CODE
	assert_eq(safe_zone.resolve(S, _fighters, space).size(), 1, "the Hollow are hostile")


func test_dead_and_protected_targets_are_not_candidates() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	duel[1].protected_until = S + 10
	assert_eq(_resolve().size(), 0, "protected by respawn")
	duel[1].protected_until = S
	assert_eq(_resolve().size(), 1, "the protection ends at its end tick")
	duel[1].health = 0
	assert_eq(_resolve().size(), 0, "a dead player takes no hits")


func test_an_invisible_gm_neither_hits_nor_is_hit() -> void:
	# docs/platform.md §9.1 (P7b): the Combatant of an invisible GM neither deals nor takes damage.
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	duel[1].entity.gm_invisible = true
	assert_true(duel[1].is_gm_invisible())
	assert_eq(_resolve().size(), 0, "the invisible one is not a candidate")
	duel[1].entity.gm_invisible = false
	duel[0].entity.gm_invisible = true
	assert_eq(_resolve().size(), 0, "and does not hit")
	duel[0].entity.gm_invisible = false
	assert_eq(_resolve().size(), 1, "visible, the hit goes through again")


func test_target_dead_at_view_tick_is_discarded() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	for tick: int in range(S - 12, S):
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI_YAW,
				EntityRecord.FLAG_GROUNDED | ActionMachine.DEFENSE_DEAD)
	_set_view_offset(attacker, 4 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	assert_eq(victim.is_alive(), true)
	assert_eq(_resolve().size(), 0, "it was dead at view_tick: it is no longer a target")


func _safe_area_resolver() -> void:
	var safe := SafeAreas.new()
	safe.add(Vector3.ZERO, 24.0, VARDHEIM)
	_resolver = CombatResolver.new(_history, ZONE_ID, safe)


func test_safe_area_protects_a_victim_of_its_realm() -> void:
	_safe_area_resolver()
	var attacker: Combatant = _fighter(1, SOLMARCH, Vector3(10.0, 0.0, 0.0), 0.0)
	_fighter(2, VARDHEIM, Vector3(10.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	assert_eq(_resolve().size(), 0, "the Vardheim victim inside its safe zone takes no damage")


func test_safe_area_does_not_let_its_realm_attack_from_inside() -> void:
	_safe_area_resolver()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3(10.0, 0.0, 0.0), 0.0)
	_fighter(2, SOLMARCH, Vector3(10.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	assert_eq(_resolve().size(), 0, "one cannot attack from inside one's safe zone")


func test_an_intruder_inside_a_safe_area_can_be_hit_from_outside() -> void:
	_safe_area_resolver()
	# The Vardheim attacker is 25 m from the center (outside) and the Solmarch intruder 23 m (inside).
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3(0.0, 0.0, 25.0), 0.0)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, 23.0), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "the intruder inside the enemy safe zone can be damaged"):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)


func test_safe_area_of_another_realm_does_not_protect() -> void:
	_safe_area_resolver()
	# Inside Vardheim's safe zone, a Solmarch and an Askarra hit each other with no problem.
	var attacker: Combatant = _fighter(1, SOLMARCH, Vector3(10.0, 0.0, 0.0), 0.0)
	_fighter(2, ASKARRA, Vector3(10.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	assert_eq(_resolve().size(), 1, "the safe zone only protects its realm")


# --- Unblockable hit and Gate Guardians (phase 4) ---------------------------------------------

## Puts the attacker with the Captain's weapon, in the active hit of its unblockable heavy attack.
func _captain_crush(attacker: Combatant) -> void:
	attacker.get_character().combat.weapon_id = CombatCatalog.weapon_id(&"npc_captain")
	CombatFixture.start_heavy_active(attacker, S)
	assert_true(CombatCatalog.attack(attacker.get_character().combat.action_id).unblockable,
			"the Captain's heavy attack is unblockable")


func test_an_unblockable_swing_goes_through_a_block() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	_captain_crush(duel[0])
	CombatFixture.start_block(duel[1], S - 30)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "the shield does not stop it")


func test_an_unblockable_swing_goes_through_a_parry_window_too() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	_captain_crush(duel[0])
	CombatFixture.start_block(duel[1], S, true)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "nor does the parry")


func test_an_unblockable_swing_is_still_dodged_by_an_invulnerable_dodge() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	_captain_crush(duel[0])
	CombatFixture.start_dodge(duel[1], S - 10)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.INVULNERABLE, "dodging it does work")


func test_a_normal_swing_of_the_same_weapon_is_still_blocked() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	duel[0].get_character().combat.weapon_id = CombatCatalog.weapon_id(&"npc_captain")
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 30)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.BLOCKED, "the Captain's sweep can be blocked")


func test_a_gate_guardian_attacks_from_inside_the_safe_area_of_its_realm() -> void:
	_safe_area_resolver()
	var guardian: Combatant = _fighter(1, VARDHEIM, Vector3(10.0, 0.0, 0.0), 0.0)
	_fighter(2, SOLMARCH, Vector3(10.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(guardian, S)
	assert_eq(_resolve().size(), 0, "without the flag, it does not attack from inside its safe zone")
	guardian.ignores_safe_area = true
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "with ignores_safe_area it does"):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)


func test_a_gate_guardian_still_cannot_hit_a_victim_inside_its_own_safe_area() -> void:
	_safe_area_resolver()
	var guardian: Combatant = _fighter(1, SOLMARCH, Vector3(10.0, 0.0, 0.0), 0.0)
	guardian.ignores_safe_area = true
	_fighter(2, VARDHEIM, Vector3(10.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(guardian, S)
	assert_eq(_resolve().size(), 0, "whoever is safe in their safe zone still takes no damage")
