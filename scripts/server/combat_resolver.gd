class_name CombatResolver
extends RefCounted
## Authoritative resolution of hits with hitbox rewind (docs/combate.md, section 4.3;
## CMB-09 and TEC-14).
## [br][br]
## [method resolve] is called once per tick, after simulating all entities and freezing
## them ([method Combatant.freeze]). For each attacker with an active hit it computes whom it
## hits, [b]without touching any combat state[/b] (it only records, on the attacker itself, whom it
## has already hit): all the hits of a tick are simultaneous and the caller applies them afterwards
## (in order of the attacker's and the target's net_id).
## [br][br]
## For each attacker:
## [br]1. [b]Rewind.[/b] [method InputQueue.get_rewind_params] gives [code]view_offset_q[/code] and
## the lead of the hit's input, [b]once per hit[/b] (on its first active tick: the
## rewind is fixed on the [Combatant] and the other active ticks reuse it, with
## [code]view_tick[/code] advancing with the tick). The cap [method allowed_rewind] comes from red.md,
## section 10, with the larger of [member ServerPeer.rtt_ticks] and [member ServerPeer.rtt_peak_ticks] (with
## jitter the minimum falls short for an honest player) and a lead bounded by the client's usual
## one plus its spread and by a maximum (each input's is chosen by the client). With more than
## [code]allowed + [/code][constant REWIND_REJECT_SLACK_TICKS] ticks the hit is not tested (the peer's
## suspicion score and a log line). Otherwise, [code]view_tick = clamp(s − view_offset_q / 16, s − allowed,
## s)[/code]: whatever exceeds the cap without reaching rejection is clipped (a delayed client frame). For
## retroactive defenses, it looks back at least [code]rtt_floor + 4 − 2[/code] ticks
## ([member ServerPeer.rtt_floor_ticks], ENet's RTT): asking for 0 does not escape them. Fake players
## and NPCs do not rewind ([code]view_tick = s[/code]).
## [br]2. [b]Samples.[/b] The attacker, always in its frozen state at [code]s[/code]. Each
## candidate at [code]view_tick[/code]: from the [StateHistory] if [code]view_tick ≤ s − 1[/code],
## interpolated between the track at [code]s − 1[/code] and the frozen state if it lies between [code]s − 1[/code] and
## [code]s[/code], or the frozen state if it is [code]s[/code]. Without a sample, the candidate is discarded.
## [br]3. [b]Candidates.[/b] Hostile according to [FactionRules], alive now and without the "dead" bit at
## [code]view_tick[/code], without respawn protection and with no safe zone in between (the victim
## in their realm's, or the attacker in theirs), at [code]s[/code]. A target already hit
## by this attack is not tested again. An invisible GM ([method Combatant.is_gm_invisible]) neither attacks nor is a
## candidate (docs/plataforma.md §9.1).
## [br]4. [b]Shape and line of sight.[/b] [method HitShapes.sector_hits_capsule] with the victim's
## sample and a ray against the current world.
## [br]5. [b]Defense[/b], in this order: invulnerable on some tick of
## [code][floor(defensa), s][/code] (no effect, [b]does not consume[/b] the hit), parry, block and
## impact, where [code]defensa[/code] is [code]view_tick[/code] or, if earlier, the instant
## imposed by the minimum for defense. Parry and block are checked on the sample of that instant and on
## the one at [code]s[/code], with the attacker within the defender's frontal cone; the old one does not count if
## the defender's frozen action is not BLOCK and started after that instant, whether it is NONE or not
## (docs/habilidades.md, section 4.2): whoever drops the shield to attack, drink or lift, or has it
## taken away by a control, stops being protected; whoever simply lowers it (NONE keeps the block's
## [code]action_tick[/code]) does not. The shield wall ([constant ActionMachine.DEFENSE_WIDE_BLOCK])
## blocks with the cone of [member CombatRules.ability_block_angle_deg] (and the director charges
## [member CombatRules.ability_block_stamina_per_damage]).
## [br][br]
## Ability hits ([member AbilityTicks.hit], the synthesized hit that [method Combatant.freeze] freezes)
## follow the same path as attacks, also against the gates.
## An impact, a block or a parry consumes the hit for that target (once per action).
## [br][br]
## Projectiles ([ProjectileSystem], docs/habilidades.md, section 4.4) use the resolver's same
## rewind ([method compute_rewind], which they fix per shot in whole ticks), hostility
## ([method is_hostile]), invulnerability ([method was_invulnerable]), per-sample blocking
## ([method blocks_sample] and [method dropped_guard_after]) and the gates ([member structure_targets]); their
## hits are [CombatResolver.Hit] with [member Hit.projectile] and the director applies them just like these.

## Result of a hit on a target.
enum Outcome {
	## Hits: full damage and the attack's controls.
	IMPACT,
	## Hits a raised shield: damage is mitigated and costs stamina.
	BLOCKED,
	## Parry: no damage and the attacker is left staggering.
	PARRIED,
	## The target was invulnerable: no effect and the attack stays alive.
	INVULNERABLE,
	## The requested rewind exceeds the cap: the attack is not tested (there is no target).
	REWIND_REJECTED,
	## Hits a static target (a fort's gate, [member Hit.structure]): no rewind,
	## no critical and no defense.
	STRUCTURE,
}

## Scale of [code]view_offset_q[/code] (ticks × 16).
const VIEW_OFFSET_Q_SCALE: int = 16
## Speed (m/s) with which the candidate search widens because of the rewind: the highest a character
## can have (dodge or push) with margin.
const _SEARCH_SPEED: float = 24.0
const _SEARCH_MARGIN: float = 0.25
## Minimum interpolation delay (ticks) assumed when computing the rewind cap.
const _MIN_INTERP_TICKS: int = 4
## Lead (ticks) that the rewind cap credits at most: what an honest client keeps
## with [code]TickSync[/code] (target margin of up to 4 plus 2 of window slack, plus 2). A client
## that gets further ahead does not raise the cap.
const _MAX_LEAD_CREDIT: int = 8
## How far a hit's input lead may exceed the client's usual one
## ([method InputQueue.get_typical_lead]): the spread of an honest player with jitter. More is an
## input deliberately sent ahead.
const _LEAD_SPREAD: int = 3
## Ticks above the cap ([method allowed_rewind]) that are [b]clipped[/b] to the cap instead of rejecting the hit
## (and adding suspicion): 1 of rounding plus 7 of a delayed client frame. With a hitch or low FPS the engine
## chains up to [code]physics/common/max_physics_steps_per_frame[/code] (8) physics steps in one frame; step
## k declares the view of the last drawn frame, k ticks older, and that frame's inputs arrive
## with less lead (the cap drops). Whoever declares too much stays at the cap, like an honest player: they gain nothing
## (phase 4 review, "cheats" lens; it used to be 1 and an honest player with a 70–150 ms hitch lost the hit or the
## arrow and added suspicion). The [code]rewind[/code] cheater (40 ticks) is still above 24 + 8.
const REWIND_REJECT_SLACK_TICKS: int = 8

## Static targets of the zone (the forts' gates, docs/fuerte.md 3.3): they are tested for each
## active attack after the players, without rewind (they do not move).
var structure_targets: Array[StructureTarget] = []
## Hits rejected for excessive rewind since the resolver came into existence.
var rewind_rejects: int = 0
## Shape and line-of-sight checks of an attack against a candidate (including the history sample)
## since the resolver came into existence: the unit of cost for the load tests.
var tests: int = 0

var _history: StateHistory
var _zone_id: StringName
var _safe_areas: SafeAreas
# (attacker's side · 16 + victim's side) -> whether there is damage between them in this zone.
var _hostile_cache: Dictionary = {}


## A result of [method resolve].
class Hit:
	var attacker: Combatant
	## null in [constant Outcome.REWIND_REJECTED] and in [constant Outcome.STRUCTURE].
	var victim: Combatant
	## The static target hit ([constant Outcome.STRUCTURE]); null in the others.
	var structure: StructureTarget = null
	var attack: AttackTicks
	var outcome: int = Outcome.IMPACT
	## Instant (in ticks, fractional) at which the attacker saw the target.
	var view_tick: float = 0.0
	## Ticks rewound ([code]s − view_tick[/code]).
	var rewind: float = 0.0
	## Hit from behind (only on impacts and blocks).
	var critical: bool = false
	## BLOCKED by a wide block (the shield wall, [constant ActionMachine.DEFENSE_WIDE_BLOCK]):
	## spends [member CombatRules.ability_block_stamina_per_damage] instead of the weapon's cost.
	var wide_block: bool = false
	## Hit by a projectile ([ProjectileSystem], docs/habilidades.md, section 4.4): its network id (0 = a
	## melee hit) and the author's copy it stored on launch (charge, extra damage, realm...): the
	## director does not look at the shooter's state again for damage.
	var projectile_id: int = 0
	var projectile: ProjectileSystem.Projectile = null
	## BLOCKED by [member victim]'s shield wall box (no damage: mitigation 1, and the wall's
	## cost); projectiles only.
	var wall: bool = false
	## Projectile velocity at impact (m/s); zero on a melee hit. Gives the direction of the
	## push.
	var direction: Vector3 = Vector3.ZERO


## [param history] is the server's position history, [param zone_id] the zone (for the
## hostility rules) and [param safe_areas] its safe zones (null = none).
func _init(history: StateHistory, zone_id: StringName, safe_areas: SafeAreas = null) -> void:
	_history = history
	_zone_id = zone_id
	_safe_areas = safe_areas if safe_areas != null else SafeAreas.new()


## Rewind cap in ticks (red.md, section 10): [code]min(24, rtt + lead + clamp(ceil(interp / 8),
## 4, 12) + 2)[/code], with the interpolation delay [param interp_delay_q] in eighths of a tick (rounded
## up: truncating lost up to 7/8 of a tick of an honest player's view; phase 4 review).
@warning_ignore("integer_division")
static func allowed_rewind(rtt_ticks: int, lead: int, interp_delay_q: int) -> int:
	var scale: int = NetProtocol.INTERP_DELAY_Q_SCALE
	var interpolation: int = clampi((maxi(interp_delay_q, 0) + scale - 1) / scale,
			_MIN_INTERP_TICKS, NetProtocol.MAX_INTERP_DELAY_TICKS)
	return mini(NetProtocol.MAX_REWIND_TICKS, rtt_ticks + maxi(lead, 0) + interpolation + 2)


## Resolves the active attacks of tick [param s] from [param combatants] (sorted by net_id, already
## frozen at [param s]) against the physics space [param space] (for line of sight).
## Returns the hits in order of the attacker's and the target's net_id.
func resolve(s: int, combatants: Array[Combatant],
		space: PhysicsDirectSpaceState3D) -> Array[Hit]:
	var hits: Array[Hit] = []
	var rules: CombatRules = CombatCatalog.rules()
	for attacker: Combatant in combatants:
		var attacker_frame: Combatant.Frozen = attacker.frozen
		# An invisible GM harms no one, not even the gates (docs/plataforma.md §9.1).
		if not attacker_frame.attack_active or attacker.is_dead() or attacker.is_gm_invisible():
			continue
		# The frozen active hit: an attack or an ability's synthesized hit. Without a shape (a
		# channel, a shot) there is no melee hit.
		var attack: AttackTicks = attacker_frame.hit
		if attack == null or attack.shape == null:
			continue
		attacker.track_swing(attacker_frame.action_tick)
		if not structure_targets.is_empty():
			_resolve_structures(attacker, attack, space, hits)
		var rewind: float = _swing_rewind(attacker, s)
		if is_nan(rewind):
			_reject(attacker, attack, s, hits)
			continue
		var view_tick: float = float(s) - rewind
		var defense_tick: float = float(s) - attacker.swing_defense_rewind
		var margin: float = _SEARCH_MARGIN + _SEARCH_SPEED * (float(s) - view_tick) \
				/ float(Engine.physics_ticks_per_second)
		var reach: float = attack.shape.range_m + HitShapes.CAPSULE_RADIUS + margin
		var reach_squared: float = reach * reach
		for victim: Combatant in combatants:
			if victim == attacker or attacker.has_hit(victim.get_id()):
				continue
			# Cheap checks first: almost all the others are out of reach.
			var victim_position: Vector3 = victim.frozen.position
			var dx: float = victim_position.x - attacker_frame.position.x
			var dz: float = victim_position.z - attacker_frame.position.z
			if dx * dx + dz * dz > reach_squared:
				continue
			if not _is_candidate(attacker, victim, s):
				continue
			var hit: Hit = _test(attacker, victim, attack, view_tick, defense_tick, s, space,
					rules)
			if hit != null:
				hits.append(hit)
	return hits


# Tests [param attacker]'s active attack against the static targets: shape (sector against box)
# and line of sight to the box, not counting the gate's own bodies. No rewind, no
# criticals or defense. Whoever is in their realm's safe zone does not attack (nor the gate).
func _resolve_structures(attacker: Combatant, attack: AttackTicks,
		space: PhysicsDirectSpaceState3D, hits: Array[Hit]) -> void:
	var frame: Combatant.Frozen = attacker.frozen
	if _safe_areas.contains_own(attacker.get_realm(), frame.position):
		return
	for target: StructureTarget in structure_targets:
		if attacker.has_hit(target.net_id) or not target.can_be_hit_by(attacker.get_realm()):
			continue
		tests += 1
		if not HitShapes.sector_hits_box(frame.position, frame.yaw, attack.shape, target.box,
				target.half_extents):
			continue
		var from: Vector3 = frame.position + Vector3(0.0, HitShapes.LINE_OF_SIGHT_FROM_HEIGHT, 0.0)
		if not _is_clear_to(space, from, target.closest_point(from), target.exclude):
			continue
		var hit := Hit.new()
		hit.attacker = attacker
		hit.attack = attack
		hit.structure = target
		hit.outcome = Outcome.STRUCTURE
		hit.view_tick = float(frame.tick)
		attacker.mark_hit(target.net_id)
		hits.append(hit)


# Line of sight from [param from] to [param to] against the world and structures, not counting the bodies in
# [param exclude] (the gate's own).
static func _is_clear_to(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3,
		exclude: Array[RID]) -> bool:
	if from.distance_squared_to(to) < 0.0001:
		return true
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to,
			HitShapes.LINE_OF_SIGHT_MASK, exclude)
	return space.intersect_ray(query).is_empty()


# Ticks the hit looks back, or NAN if it asks for more than allowed. It is fixed once, on the hit's first
# active tick, and the other active ticks reuse it (view_tick advances with them): the client
# can no longer change the rewind from one tick to the next to sweep the window or shed retroactive
# defenses with a 0. The cap credits the lead of the hit's input (with it an honest player is never
# above: their view is rtt + lead + interpolation), but bounded by the client's usual one
# plus its spread and by a maximum: each input's is chosen by the client. An attacker without a
# peer (fake player, NPC) does not rewind.
func _swing_rewind(attacker: Combatant, s: int) -> float:
	if attacker.peer == null or attacker.queue == null:
		return 0.0
	if attacker.swing_rewind_fixed:
		return attacker.swing_rewind
	var fixed: Vector2 = compute_rewind(attacker, s)
	attacker.swing_rewind_fixed = true
	attacker.swing_rewind = fixed.x
	attacker.swing_defense_rewind = fixed.y
	return fixed.x


## The rewind of a hit or shot by [param attacker] that starts at [param s] (docs/combate.md,
## 4.3, step 2), without fixing it anywhere: [code]x[/code] is the ticks it looks back (clipped to the cap;
## NAN if it asks for more than [code]allowed + [/code][constant REWIND_REJECT_SLACK_TICKS]) and [code]y[/code] the ones
## looked back at for parry, block and invulnerability (at least the minimum consistent with the measured
## RTT, never more than the cap; 0 if rejected). An attacker without a peer (fake player, NPC) does not rewind:
## (0, 0). Used by hits ([method _swing_rewind], which fixes it on the [Combatant]) and by projectiles
## ([ProjectileSystem], which fixes it for the whole flight rounded to whole ticks).
static func compute_rewind(attacker: Combatant, s: int) -> Vector2:
	if attacker.peer == null or attacker.queue == null:
		return Vector2.ZERO
	var params: Vector2i = attacker.queue.get_rewind_params(s)
	var lead: int = mini(params.y, mini(attacker.queue.get_typical_lead(s) + _LEAD_SPREAD,
			_MAX_LEAD_CREDIT))
	var allowed: int = allowed_rewind(maxi(attacker.peer.rtt_ticks, attacker.peer.rtt_peak_ticks),
			lead, attacker.peer.interp_delay_q)
	var rewind: float = NAN
	if params.x <= (allowed + REWIND_REJECT_SLACK_TICKS) * VIEW_OFFSET_Q_SCALE:
		rewind = clampf(float(params.x) / float(VIEW_OFFSET_Q_SCALE), 0.0, float(allowed))
	if is_nan(rewind):
		return Vector2(NAN, 0.0)
	# For defense it looks back at least what an honest player with that RTT cannot avoid seeing
	# (ENet's RTT plus the minimum interpolation delay, minus 2 of slack), but never beyond
	# the cap.
	var minimum: float = minf(float(maxi(attacker.peer.rtt_floor_ticks + _MIN_INTERP_TICKS - 2, 0)),
			float(allowed))
	return Vector2(rewind, maxf(rewind, minimum))


## Records on [param attacker]'s peer a rejected rewind (suspicion + 1) and counts it in
## [member rewind_rejects]. Used by hits and shots.
func note_rewind_rejected(attacker: Combatant) -> void:
	rewind_rejects += 1
	if attacker.peer != null:
		attacker.peer.suspicion_score += 1
		attacker.peer.rewind_rejects += 1


# Records a hit rejected for excessive rewind: once per attack.
func _reject(attacker: Combatant, attack: AttackTicks, s: int, hits: Array[Hit]) -> void:
	if attacker.rejected_swing_tick == attacker.frozen.action_tick:
		return
	attacker.rejected_swing_tick = attacker.frozen.action_tick
	note_rewind_rejected(attacker)
	var hit := Hit.new()
	hit.attacker = attacker
	hit.attack = attack
	hit.outcome = Outcome.REWIND_REJECTED
	if attacker.peer != null and attacker.queue != null:
		var params: Vector2i = attacker.queue.get_rewind_params(s)
		hit.rewind = float(params.x) / float(VIEW_OFFSET_Q_SCALE)
		hit.view_tick = float(s) - hit.rewind
	hits.append(hit)


## The zone's safe zones (never null).
func get_safe_areas() -> SafeAreas:
	return _safe_areas


## Position history used by the resolver.
func get_history() -> StateHistory:
	return _history


# Candidate by rules: hostile, alive, unprotected and with no safe zone in between (an attacker with
# ignores_safe_area is not held back by that of its own realm).
func _is_candidate(attacker: Combatant, victim: Combatant, s: int) -> bool:
	if victim.is_dead() or victim.is_protected(s) or victim.is_gm_invisible():
		return false
	if not is_hostile(attacker.get_realm(), victim.get_realm()):
		return false
	if _safe_areas.contains_own(victim.get_realm(), victim.frozen.position):
		return false
	# A Gate Guardian (ignores_safe_area) does attack from the safe zone of its realm.
	if not attacker.ignores_safe_area \
			and _safe_areas.contains_own(attacker.get_realm(), attacker.frozen.position):
		return false
	return true


## The zone's [method FactionRules.can_damage], cached per pair of sides (the zone does not change).
func is_hostile(attacker_realm: int, victim_realm: int) -> bool:
	var key: int = attacker_realm * 16 + victim_realm
	if not _hostile_cache.has(key):
		_hostile_cache[key] = FactionRules.can_damage(attacker_realm, victim_realm, _zone_id)
	return _hostile_cache[key]


# Tests an attack against a candidate. null if it does not reach it.
func _test(attacker: Combatant, victim: Combatant, attack: AttackTicks, view_tick: float,
		defense_tick: float, s: int, space: PhysicsDirectSpaceState3D, rules: CombatRules) -> Hit:
	var attacker_frame: Combatant.Frozen = attacker.frozen
	tests += 1
	var sample: StateHistory.Sample = _sample(victim, view_tick, s)
	if sample == null or (sample.flags & ActionMachine.DEFENSE_DEAD) != 0:
		return null
	if not HitShapes.sector_hits_capsule(attacker_frame.position, attacker_frame.yaw,
			attack.shape, sample.position, HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT):
		return null
	if not HitShapes.has_line_of_sight(space, attacker_frame.position, sample.position):
		return null

	var hit := Hit.new()
	hit.attacker = attacker
	hit.victim = victim
	hit.attack = attack
	hit.view_tick = view_tick
	hit.rewind = float(s) - view_tick
	hit.outcome = _defense(attacker, victim, attack, view_tick, defense_tick, s, sample, rules, hit)
	if hit.outcome == Outcome.IMPACT or hit.outcome == Outcome.BLOCKED:
		hit.critical = DamageFormula.is_backstab(attacker_frame.position, sample.position,
				sample.yaw, rules.backstab_angle_deg)
	if hit.outcome != Outcome.INVULNERABLE:
		attacker.mark_hit(victim.get_id())
	return hit


# Defense precedence (docs/combate.md, 4.3, step 6). [param defense_tick] is the oldest
# instant looked at for retroactive defenses: view_tick, or earlier if the server imposes a
# minimum rewind (the client does not escape them by asking for 0). A shield wall block marks
# [member Hit.wide_block] on [param hit].
func _defense(attacker: Combatant, victim: Combatant, attack: AttackTicks, view_tick: float,
		defense_tick: float, s: int, sample: StateHistory.Sample, rules: CombatRules, hit: Hit) -> int:
	var old_tick: float = minf(view_tick, defense_tick)
	if was_invulnerable(victim, old_tick, s):
		return Outcome.INVULNERABLE
	var victim_frame: Combatant.Frozen = victim.frozen
	var weapon: WeaponTicks = CombatCatalog.weapon(victim_frame.weapon_id)
	# An unblockable hit (the Ford Captain's) can only be avoided by dodging it: neither parry nor
	# block stops it.
	if weapon == null or attack.unblockable:
		return Outcome.IMPACT
	var attacker_position: Vector3 = attacker.frozen.position
	var cone: float = weapon.block_angle_deg
	# The old sample only counts if the defender has not lowered the shield afterwards: neither by their own attack
	# or dodge nor because a control was imposed on them.
	var old_sample: StateHistory.Sample = sample
	if old_tick < view_tick:
		old_sample = _sample(victim, old_tick, s)
	var old_counts: bool = old_sample != null and old_tick < float(s) \
			and not dropped_guard_after(victim_frame, old_tick)
	# Parry (only against melee hits: all those this resolver tests).
	if _defends(victim_frame, old_sample, old_counts, ActionMachine.DEFENSE_PARRY, cone,
			attacker_position):
		return Outcome.PARRIED
	# Block: the shield only stops physical damage. The shield wall's is wide: its cone is the one from
	# the rules, on the sample that carries it.
	if not DamageFormula.is_physical(attack.damage_type):
		return Outcome.IMPACT
	var wide_cone: float = rules.ability_block_angle_deg
	if blocks_sample(victim_frame, victim_frame.defense, cone, wide_cone, attacker_position):
		hit.wide_block = (victim_frame.defense & ActionMachine.DEFENSE_WIDE_BLOCK) != 0
		return Outcome.BLOCKED
	if old_counts and blocks_sample(old_sample, old_sample.flags, cone, wide_cone, attacker_position):
		hit.wide_block = (old_sample.flags & ActionMachine.DEFENSE_WIDE_BLOCK) != 0
		return Outcome.BLOCKED
	return Outcome.IMPACT


## true if the sample [param sample] (with its flags [param flags]) blocks the attacker at
## [param attacker_position]: blocking and with the attacker in its cone, the weapon's ([param cone]) or, with
## the wide block, [param wide_cone]. A projectile passes as attacker a point behind the victim in
## the direction it comes from.
static func blocks_sample(sample: StateHistory.Sample, flags: int, cone: float, wide_cone: float,
		attacker_position: Vector3) -> bool:
	if (flags & ActionMachine.DEFENSE_BLOCKING) == 0:
		return false
	var used: float = wide_cone if (flags & ActionMachine.DEFENSE_WIDE_BLOCK) != 0 else cone
	return HitShapes.is_in_front(sample.position, sample.yaw, attacker_position, used)


# true if the defender has flag [param flag] at s (frozen sample) or at view_tick
# (rewound sample, if it counts), with the attacker within the frontal cone in that sample.
func _defends(victim_frame: Combatant.Frozen, sample: StateHistory.Sample, old_counts: bool,
		flag: int, cone: float, attacker_position: Vector3) -> bool:
	if (victim_frame.defense & flag) != 0 and HitShapes.is_in_front(victim_frame.position,
			victim_frame.yaw, attacker_position, cone):
		return true
	return old_counts and (sample.flags & flag) != 0 and HitShapes.is_in_front(sample.position,
			sample.yaw, attacker_position, cone)


## true if the view_tick sample no longer counts (docs/habilidades.md, section 4.2): the defender's frozen
## action is not BLOCK and started after view_tick, whether it is NONE or not. An attack, a charge, a dodge,
## an ability, drinking, lifting or a control (stagger, stun, death) lower the shield; and
## so does returning to NONE from them, because NONE keeps the action_tick of what ends (_to_none,
## impose_interrupt). Simply lowering the shield (NONE with the block's action_tick) or continuing to block
## does not count: there the view_tick sample is still what the attacker saw.
static func dropped_guard_after(victim_frame: Combatant.Frozen, view_tick: float) -> bool:
	if float(victim_frame.action_tick) <= view_tick:
		return false
	return victim_frame.action != CombatState.Action.BLOCK


## true if the target was invulnerable on some tick of [code][floor(view_tick), s][/code] (the frozen
## sample at [code]s[/code] and the history).
func was_invulnerable(victim: Combatant, view_tick: float, s: int) -> bool:
	if (victim.frozen.defense & ActionMachine.DEFENSE_INVULNERABLE) != 0:
		return true
	for tick: int in range(floori(view_tick), s):
		var flags: int = _history.get_flags(victim.get_id(), tick)
		if flags >= 0 and (flags & ActionMachine.DEFENSE_INVULNERABLE) != 0:
			return true
	return false


# State of the target at instant view_tick, or null if unknown.
func _sample(victim: Combatant, view_tick: float, s: int) -> StateHistory.Sample:
	var frame: Combatant.Frozen = victim.frozen
	if view_tick >= float(s):
		return frame
	if view_tick <= float(s - 1):
		return _history.sample(victim.get_id(), view_tick)
	# Between s − 1 and s: interpolation between the track at s − 1 and the frozen state.
	var previous: StateHistory.Sample = _history.sample(victim.get_id(), float(s - 1))
	if previous == null:
		return null
	if _teleport_counter(previous.flags) != _teleport_counter(frame.flags):
		return previous
	var fraction: float = view_tick - float(s - 1)
	var result := StateHistory.Sample.new()
	result.position = previous.position.lerp(frame.position, fraction)
	result.yaw = lerp_angle(previous.yaw, frame.yaw, fraction)
	result.flags = previous.flags if fraction < 0.5 else frame.flags
	return result


static func _teleport_counter(flags: int) -> int:
	return (flags >> EntityRecord.TELEPORT_SHIFT) & EntityRecord.TELEPORT_MASK
