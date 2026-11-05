class_name ProjectileSystem
extends RefCounted
## Server projectiles (docs/abilities.md, section 4.4; CMB-22): bow arrows, with data-driven ballistics
## ([ProjectileTicks]), hit rewind fixed for the whole flight and the shield wall's box.
## [br][br]
## [b]Firing[/b] ([method fire], tick step 3, by net_id): each projectile of the attack or ability that commits at
## [code]s[/code] leaves the chest ([method AimRay.muzzle]) towards the aimed point ([method AimRay.aim_point]) along
## the camera's canonical ray ([method AimRay.canonical] with the yaw, pitch and shoulder of the input simulated at
## [code]s[/code], [method InputQueue.get_applied]), with convergence at the depth of the hostile closest to the
## crosshair at [code]s − rewind[/code]. The fan rotates the direction in yaw. The origin and velocity are quantized as
## they travel in the ENTITY_SPAWN ([method Ballistics.quantize]) and the server flies with that. What leaves, its
## velocity, the fan and the quantization are those of [ProjectileLaunch], shared with the client's predicted arrow. The
## rewind ([method CombatResolver.compute_rewind]) is fixed once per shot, in whole ticks; if it is rejected, the
## arrow is [b]harmless[/b] (it flies and collides with the world, tests nobody), with suspicion + 1 and a log entry;
## so is that of someone who fires from their realm's safe zone. The projectile keeps a copy of the author (realm,
## whether a player, source, rewind, charge and bonus damage): damage never looks at the shooter's state again. [b]A shot
## is never rejected[/b]: with [member CombatRules.max_projectiles_per_shooter] alive for the shooter, their oldest one
## goes out, and with [member CombatRules.max_projectiles_per_zone] in the zone, the oldest of the zone (ties by id),
## with DESPAWN 5 on that tick.
## [br][br]
## [b]Flight[/b] ([method resolve], step 4, without touching combat state): on tick [code]k[/code], with
## [code]n = k − spawn_tick[/code], the segment [code][pos(n), pos(n + 1)][/code] of
## [method Ballistics.position] (on the firing tick, the first one) against the world and the doors
## ([constant HitShapes.LINE_OF_SIGHT_MASK]; the first segment with [code]hit_from_inside[/code]: from the doorway of
## the closed door it sticks into the origin), the boxes of the shield walls hostile to the shooter at [code]k[/code]
## (only to arrows arriving head-on) and the capsules (radius 0.4 + the projectile's) of the candidates at
## [code]k − rewind[/code] ([method StateHistory.position_at]), screened with their swept box
## ([method StateHistory.swept_box] plus the frozen position), computed once per tick. The smaller fraction wins. A
## character that is invulnerable in [code][k − defense_rewind, k][/code] does not stop it (it does not test it again);
## one blocking facing the arrow (the weapon's cone or the wall's width, in the sample of [code]k[/code] or of
## [code]k − defense_rewind[/code] if it still counts) blocks it; there is never a parry. The wall's box blocks on
## behalf of whoever holds it (no damage). The world sticks it; a door that the shooter can damage receives the hit.
## Without an impact, it expires at [code]n + 1 ≥ lifetime_ticks[/code] or below [constant VOID_LIMIT_Y] (DESPAWN 5).
## [br][br]
## It touches neither the network nor the clock: it reports spawns and despawns with [signal spawned] and
## [signal despawned] (the [ZoneServer] sends them to whoever has the shooter relevant, and to the shooter) and returns
## the hits for the [CombatDirector] to apply, since it is the one that knows about damage, controls and deaths.
## [br][br]
## [b]Cost[/b] (docs/abilities.md, section 8): the tick's candidates live in packed arrays (no objects per tick) and
## each arrow stores the end of its segment, which is the origin of the next (the same [method Ballistics.position] with
## the same [code]n[/code]): a flight tick is one ray against the world, one screening by boxes and, almost never, an
## exact test.

## Spawn of a projectile: the ENTITY_SPAWN of kind 3 and the net_ids involved (the shooter): its owner and whoever has
## it relevant receive it.
signal spawned(spawn: NetMessages.EntitySpawn, recipients: PackedInt32Array)
## Despawn of a projectile at tick [param tick] with reason [param reason] (4 impact, 5 expired or withdrawn) and the
## net_ids involved (the shooter). The [ZoneServer] sends it to whoever received its spawn.
signal despawned(projectile_id: int, tick: int, reason: int, recipients: PackedInt32Array)

## Below this height the projectile expires (it falls out of the world).
const VOID_LIMIT_Y: float = -100.0

const _IMPACT: int = NetProtocol.DespawnReason.IMPACT
const _EXPIRED: int = NetProtocol.DespawnReason.EXPIRED
# Classes of what a segment touches, in order of preference at the same fraction.
const _TOUCH_WORLD: int = 0
const _TOUCH_WALL: int = 1
const _TOUCH_CHARACTER: int = 2
# X sweep of the candidates: the left edge of each box in centimeters (shifted to be positive) above
# _SWEEP_INDEX_BITS bits with its index, sorted; boxes wider than _SWEEP_WIDE_M (a teleport in the last ticks) go
# separately and are always tested.
const _SWEEP_INDEX_BITS: int = 12
const _SWEEP_INDEX_MASK: int = (1 << _SWEEP_INDEX_BITS) - 1
const _SWEEP_OFFSET_CM: int = 1 << 30
const _SWEEP_WIDE_M: float = 12.0

## Registry that projectile ids come from ([method NetEntityRegistry.allocate_transient_id]). The [ZoneServer] sets
## the zone's; without it (tests), its own.
var registry: NetEntityRegistry = NetEntityRegistry.new()
## The zone's status effects, to copy the shooter's bonus damage when firing (null = no effects).
var status: StatusSystem = null
## Counters for the run (for the report).
var stats: Dictionary[StringName, int] = {
	&"projectiles_fired": 0, &"projectiles_harmless": 0, &"projectile_world_hits": 0,
	&"projectile_gate_hits": 0, &"projectile_wall_blocks": 0, &"projectile_character_hits": 0,
	&"projectile_invulnerable": 0, &"projectiles_expired": 0, &"projectiles_evicted": 0,
	&"projectiles_forgotten": 0, &"projectile_rewind_rejected": 0, &"projectile_segments": 0,
	&"projectile_capsule_tests": 0, &"projectile_peak": 0,
}

var _history: StateHistory
var _resolver: CombatResolver
# Live projectiles, in spawn order.
var _live: Array[Projectile] = []
# Hits rejected by rewind in this tick's shots (for the director's log).
var _rejected: Array[CombatResolver.Hit] = []
# Ray against the world, reused for each segment.
var _query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()
# The tick's combatants (begin_tick) and, computed once per tick and only if needed, their (alive) candidates in
# parallel arrays: the combatant, its id, its realm, whether it is open (neither protected nor in its realm's safe
# zone) and its swept box widened with the capsule; and the shield walls.
var _combatants: Array[Combatant] = []
var _prepared_tick: int = -1
var _candidate_count: int = 0
var _candidates: Array[Combatant] = []
var _candidate_ids: PackedInt32Array = PackedInt32Array()
var _candidate_realms: PackedInt32Array = PackedInt32Array()
var _candidate_open: PackedByteArray = PackedByteArray()
var _candidate_low: PackedVector3Array = PackedVector3Array()
var _candidate_high: PackedVector3Array = PackedVector3Array()
# The narrow candidates sorted by the left edge of their box (see _SWEEP_INDEX_BITS), the x width of the widest one
# among them, and the wide ones.
var _sweep: PackedInt64Array = PackedInt64Array()
var _sweep_width: float = 0.0
var _wide: PackedInt32Array = PackedInt32Array()
var _walls: Array[_Wall] = []


## What the projectiles of one shot (a fan) share: whether any has already hit something, to count one hit per shot.
class Shot:
	extends RefCounted
	var landed: bool = false


## A live projectile, with the copy of the author that it saved on leaving.
class Projectile:
	extends RefCounted
	## Network id (from the [NetEntityRegistry] space, without an entity).
	var id: int = 0
	## The shooter (for the counters and the damage log) and its net_id, realm and whether it is a player, copied on
	## leaving.
	var owner: Combatant = null
	var owner_id: int = 0
	var realm: int = 0
	var is_player: bool = false
	## Source of the attack or ability ([CombatSource]) and the hit with its damage, controls and effect on the target (the
	## attack or the ability's synthesized hit).
	var source: int = 0
	var attack: AttackTicks = null
	var definition: ProjectileTicks = null
	var volley_index: int = 0
	## Harmless: it flies and collides with the world, tests nobody.
	var harmless: bool = false
	## Ticks it looks back and those looked back for defenses (fixed on leaving).
	var rewind: int = 0
	var defense_rewind: int = 0
	## Charge it left with and the shooter's bonus damage at the shot.
	var charge_ticks: int = 0
	var damage_scale: float = 1.0
	var spawn_tick: int = 0
	## Quantized origin and velocity: those of the ENTITY_SPAWN.
	var origin: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var shot: Shot = null
	## Characters it does not test again (they were invulnerable when it touched them).
	var ignored: PackedInt32Array = PackedInt32Array()
	## Flight ticks at which the last tested segment ends, and its position: the origin of the next.
	var reached_ticks: int = 0
	var reached: Vector3 = Vector3.ZERO


	## Position after [param ticks] flight ticks (whole or fractional).
	func position_after(ticks: float) -> Vector3:
		return Ballistics.position(origin, velocity, definition.gravity, ticks)


	## Velocity (m/s) after [param ticks] flight ticks.
	func velocity_after(ticks: float) -> Vector3:
		return velocity - Vector3(0.0, definition.gravity * ticks / Ballistics.TICK_RATE, 0.0)


# The box of a shield wall in this tick.
class _Wall:
	var holder: Combatant
	var realm: int = 0
	var box: Transform3D = Transform3D.IDENTITY
	var half_extents: Vector3 = Vector3.ZERO
	var forward: Vector3 = Vector3.FORWARD


# What a segment touches.
class _Touch:
	var fraction: float = 0.0
	var kind: int = 0
	## Index of the touched candidate (in the tick's arrays).
	var candidate: int = -1
	var wall: _Wall = null
	var structure: StructureTarget = null


## [param history] is the server's history and [param resolver] the zone's resolver (rewind, hostility, invulnerability,
## safe zones and doors).
func _init(history: StateHistory, resolver: CombatResolver) -> void:
	_history = history
	_resolver = resolver
	_query.collision_mask = HitShapes.LINE_OF_SIGHT_MASK


## Starts a tick with the zone's combatants [param combatants] (by net_id): their candidates and walls are computed the
## first time they are needed in the tick.
func begin_tick(_s: int, combatants: Array[Combatant]) -> void:
	_combatants = combatants
	_prepared_tick = -1


## Live projectiles.
func live_count() -> int:
	return _live.size()


## true if any shot of this tick has a hit to deliver in [method resolve] (the rejection of its rewind, for the log)
## even if no live projectile remains.
func has_pending() -> bool:
	return not _rejected.is_empty()


## The live projectiles, in spawn order (they must not be modified).
func get_live() -> Array[Projectile]:
	return _live


## The live projectile [param projectile_id], or null.
func get_projectile(projectile_id: int) -> Projectile:
	for projectile: Projectile in _live:
		if projectile.id == projectile_id:
			return projectile
	return null


# --- Firing -----------------------------------------------------------------------------------

## Fires the projectiles of the attack or ability of source [param source] ([CombatSource]) that [param shooter] commits
## at tick [param s] (already frozen), against the world [param space]. Does nothing if the source carries no
## projectile.
func fire(shooter: Combatant, source: int, s: int, space: PhysicsDirectSpaceState3D) -> void:
	# An invisible GM does not fire (docs/platform.md §9.1): it does no damage to anyone.
	if shooter.is_gm_invisible():
		return
	var frame: Combatant.Frozen = shooter.frozen
	# What leaves, at what velocity and in what fan: the same as the client's predicted arrow (ProjectileLaunch, shared).
	var attack: AttackTicks = null
	var launch: ProjectileLaunch = null
	var charge_ticks: int = 0
	match CombatSource.kind_of(source):
		CombatSource.Kind.ATTACK:
			attack = CombatCatalog.attack(CombatSource.id_of(source))
			if attack != null and attack.heavy:
				charge_ticks = frame.charge_ticks
			launch = ProjectileLaunch.for_attack(attack, charge_ticks)
		CombatSource.Kind.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(CombatSource.id_of(source))
			if ability != null:
				attack = ability.hit
				launch = ProjectileLaunch.for_ability(ability)
	if attack == null or launch == null:
		return
	var definition: ProjectileTicks = CombatCatalog.projectile(launch.projectile_id)
	if definition == null:
		return
	var rules: CombatRules = CombatCatalog.rules()
	# Rewind, fixed for the whole flight in whole ticks.
	var harmless: bool = false
	var rewind: int = 0
	var defense_rewind: int = 0
	var fixed: Vector2 = CombatResolver.compute_rewind(shooter, s)
	if is_nan(fixed.x):
		harmless = true
		_reject(shooter, attack, s)
	else:
		rewind = roundi(fixed.x)
		defense_rewind = maxi(roundi(fixed.y), rewind)
	if not shooter.ignores_safe_area \
			and _resolver.get_safe_areas().contains_own(shooter.get_realm(), frame.position):
		harmless = true
	# Aim with the input simulated at s (without it, the body's: character yaw, pitch 0).
	var input: PlayerInput = shooter.queue.get_applied(s) if shooter.queue != null else null
	var look_yaw: float = input.look_yaw if input != null else frame.yaw
	var look_pitch: float = input.look_pitch if input != null else 0.0
	var left: bool = input != null and input.has(PlayerInput.AIM_LEFT)
	var ray: Array = AimRay.canonical(frame.position, look_yaw, look_pitch, left)
	var camera: Vector3 = ray[0]
	var forward: Vector3 = ray[1]
	var feet := PackedVector3Array()
	if not harmless:
		_prepare(s)
		feet = _aim_candidates(shooter, camera, forward, s - rewind, s)
	var point: Vector3 = AimRay.aim_point(space, camera, forward, feet)
	var shots: Array[PackedVector3Array] = launch.launch_toward(AimRay.muzzle(frame.position), point,
			forward)
	var shot := Shot.new()
	var scale: float = status.damage_scale(shooter) if status != null else 1.0
	for index: int in shots.size():
		_make_room(shooter.get_id(), s, rules)
		var projectile_id: int = registry.allocate_transient_id(s)
		if projectile_id == 0:
			push_warning("[Eldmark] Sin ids libres para un proyectil")
			continue
		var projectile := Projectile.new()
		projectile.id = projectile_id
		projectile.owner = shooter
		projectile.owner_id = shooter.get_id()
		projectile.realm = shooter.get_realm()
		projectile.is_player = shooter.entity.kind == NetProtocol.EntityKind.PLAYER
		projectile.source = source
		projectile.attack = attack
		projectile.definition = definition
		projectile.volley_index = index
		projectile.harmless = harmless
		projectile.rewind = rewind
		projectile.defense_rewind = defense_rewind
		projectile.charge_ticks = charge_ticks
		projectile.damage_scale = scale
		projectile.spawn_tick = s
		projectile.origin = shots[index][0]
		projectile.velocity = shots[index][1]
		projectile.reached_ticks = 0
		projectile.reached = projectile.origin
		projectile.shot = shot
		_live.append(projectile)
		stats[&"projectiles_fired"] += 1
		if harmless:
			stats[&"projectiles_harmless"] += 1
		stats[&"projectile_peak"] = maxi(stats[&"projectile_peak"], _live.size())
		spawned.emit(NetMessages.EntitySpawn.for_projectile(projectile_id, s, projectile.realm,
				projectile.owner_id, definition.id, source, index, harmless, projectile.origin,
				projectile.velocity), PackedInt32Array([projectile.owner_id]))


# A shot with the rewind rejected: suspicion + 1 and a log line (the director receives it in resolve as
# REWIND_REJECTED).
func _reject(shooter: Combatant, attack: AttackTicks, s: int) -> void:
	_resolver.note_rewind_rejected(shooter)
	stats[&"projectile_rewind_rejected"] += 1
	var hit := CombatResolver.Hit.new()
	hit.attacker = shooter
	hit.attack = attack
	hit.outcome = CombatResolver.Outcome.REWIND_REJECTED
	if shooter.queue != null:
		var params: Vector2i = shooter.queue.get_rewind_params(s)
		hit.rewind = float(params.x) / float(CombatResolver.VIEW_OFFSET_Q_SCALE)
		hit.view_tick = float(s) - hit.rewind
	_rejected.append(hit)


# The feet, at tick [param view_tick], of [param shooter]'s hostiles whose swept box (as a sphere) touches the
# crosshair's convergence cone or its ray: those that can decide the aimed point, by net_id.
func _aim_candidates(shooter: Combatant, camera: Vector3, forward: Vector3, view_tick: int,
		s: int) -> PackedVector3Array:
	var rules: CombatRules = CombatCatalog.rules()
	var angle: float = deg_to_rad(rules.aim_converge_deg)
	var cone_cos: float = cos(angle)
	var cone_sin: float = sin(angle)
	var reach: float = rules.aim_range_m
	var realm: int = shooter.get_realm()
	var owner_id: int = shooter.get_id()
	var lows: PackedVector3Array = _candidate_low
	var highs: PackedVector3Array = _candidate_high
	var feet := PackedVector3Array()
	for index: int in _candidate_count:
		if _candidate_open[index] == 0 or _candidate_ids[index] == owner_id:
			continue
		var low: Vector3 = lows[index]
		var high: Vector3 = highs[index]
		var radius: float = (high - low).length() * 0.5
		var to_center: Vector3 = (low + high) * 0.5 - camera
		var depth: float = to_center.dot(forward)
		if depth <= -radius or depth - radius >= reach:
			continue
		# Distance from the sphere to the crosshair's cone (ahead): perpendicular · cos − depth · sin.
		var perpendicular: float = sqrt(maxf(to_center.length_squared() - depth * depth, 0.0))
		if perpendicular > radius and perpendicular * cone_cos - depth * cone_sin > radius:
			continue
		if not _resolver.is_hostile(realm, _candidate_realms[index]):
			continue
		var position: Vector3 = _position_of(_candidates[index], view_tick, s)
		if position.is_finite():
			feet.append(position)
	return feet


# With the shooter's cap or the zone's full, it withdraws the oldest projectile (the shooter's or the zone's; ties by
# id) with DESPAWN 5: the new shot is never rejected.
func _make_room(owner_id: int, s: int, rules: CombatRules) -> void:
	var own_count: int = 0
	var own_oldest: Projectile = null
	for projectile: Projectile in _live:
		if projectile.owner_id == owner_id:
			own_count += 1
			if own_oldest == null or _is_older(projectile, own_oldest):
				own_oldest = projectile
	if own_oldest != null and own_count >= rules.max_projectiles_per_shooter:
		_evict(own_oldest, s)
	if _live.size() >= rules.max_projectiles_per_zone and not _live.is_empty():
		var oldest: Projectile = _live[0]
		for projectile: Projectile in _live:
			if _is_older(projectile, oldest):
				oldest = projectile
		_evict(oldest, s)


static func _is_older(a: Projectile, b: Projectile) -> bool:
	return a.spawn_tick < b.spawn_tick or (a.spawn_tick == b.spawn_tick and a.id < b.id)


func _evict(projectile: Projectile, s: int) -> void:
	stats[&"projectiles_evicted"] += 1
	_live.erase(projectile)
	_end(projectile, s, _EXPIRED)


# --- Flight ------------------------------------------------------------------------------------

## The flight of tick [param s] of all live projectiles (also those that have just left) against [param combatants] (by
## net_id, already frozen at [param s]) and the world [param space]. Returns the hits by shooter net_id and by projectile
## id (first, the shots of this tick with the rewind rejected) for the [CombatDirector] to apply; despawns (DESPAWN 4 and
## 5) have already gone out through [signal despawned].
func resolve(s: int, combatants: Array[Combatant],
		space: PhysicsDirectSpaceState3D) -> Array[CombatResolver.Hit]:
	var rejected: Array[CombatResolver.Hit] = _rejected
	_rejected = []
	if _live.is_empty():
		return rejected
	_combatants = combatants
	_prepare(s)
	var flying: Array[Projectile] = _live.duplicate()
	flying.sort_custom(func(a: Projectile, b: Projectile) -> bool:
		return a.owner_id < b.owner_id or (a.owner_id == b.owner_id and a.id < b.id))
	var hits: Array[CombatResolver.Hit] = []
	var ended: Array[Projectile] = []
	var reasons: PackedInt32Array = PackedInt32Array()
	for projectile: Projectile in flying:
		var reason: int = _fly(projectile, s, space, hits)
		if reason >= 0:
			ended.append(projectile)
			reasons.append(reason)
	for index: int in ended.size():
		_live.erase(ended[index])
		_end(ended[index], s, reasons[index])
	return merge_by_attacker(rejected, hits)


## Merges two hit lists sorted by attacker net_id without undoing their order: with the same attacker, those of
## [param first] come first. It is how the director joins melee hits and projectile hits (docs/abilities.md, section
## 4.1, step 5).
static func merge_by_attacker(first: Array[CombatResolver.Hit],
		second: Array[CombatResolver.Hit]) -> Array[CombatResolver.Hit]:
	if first.is_empty():
		return second
	if second.is_empty():
		return first
	var merged: Array[CombatResolver.Hit] = []
	var i: int = 0
	var j: int = 0
	while i < first.size() or j < second.size():
		if j >= second.size() or (i < first.size()
				and first[i].attacker.get_id() <= second[j].attacker.get_id()):
			merged.append(first[i])
			i += 1
		else:
			merged.append(second[j])
			j += 1
	return merged


# Flies [param projectile] one tick: tests its segment and leaves in [param hits] what it touches. Returns the reason
# for its despawn (4 impact, 5 expired) or -1 if it is still in the air.
func _fly(projectile: Projectile, s: int, space: PhysicsDirectSpaceState3D,
		hits: Array[CombatResolver.Hit]) -> int:
	var flown: int = s - projectile.spawn_tick
	# The end of the previous segment is the origin of this one: the same function with the same n.
	var from: Vector3 = projectile.reached if projectile.reached_ticks == flown \
			else projectile.position_after(float(flown))
	var to: Vector3 = projectile.position_after(float(flown + 1))
	projectile.reached_ticks = flown + 1
	projectile.reached = to
	stats[&"projectile_segments"] += 1
	var touches: Array[_Touch] = []
	var world: _Touch = _touch_world(space, from, to, flown == 0)
	if world != null:
		touches.append(world)
	if not projectile.harmless:
		if not _walls.is_empty():
			_touch_walls(projectile, from, to, touches)
		_touch_characters(projectile, from, to, s, touches)
	if touches.size() > 1:
		touches.sort_custom(func(a: _Touch, b: _Touch) -> bool:
			if a.fraction != b.fraction:
				return a.fraction < b.fraction
			if a.kind != b.kind:
				return a.kind < b.kind
			return a.candidate < b.candidate)
	for touch: _Touch in touches:
		if touch.kind == _TOUCH_WORLD:
			stats[&"projectile_world_hits"] += 1
			if touch.structure != null and not projectile.harmless \
					and touch.structure.can_be_hit_by(projectile.realm):
				stats[&"projectile_gate_hits"] += 1
				hits.append(_structure_hit(projectile, touch.structure, s))
			return _IMPACT
		if touch.kind == _TOUCH_WALL:
			stats[&"projectile_wall_blocks"] += 1
			var blocked: CombatResolver.Hit = _hit_on(projectile, touch.wall.holder, s, flown, touch)
			blocked.outcome = CombatResolver.Outcome.BLOCKED
			blocked.wide_block = true
			blocked.wall = true
			hits.append(blocked)
			return _IMPACT
		var victim: Combatant = _candidates[touch.candidate]
		var hit: CombatResolver.Hit = _hit_on(projectile, victim, s, flown, touch)
		if _resolver.was_invulnerable(victim, float(s - projectile.defense_rewind), s):
			# It keeps flying (what comes next in the same segment can still stop it) and does not test it again.
			stats[&"projectile_invulnerable"] += 1
			projectile.ignored.append(victim.get_id())
			hit.outcome = CombatResolver.Outcome.INVULNERABLE
			hits.append(hit)
			continue
		stats[&"projectile_character_hits"] += 1
		hit.outcome = _defense(projectile, victim, hit, s)
		hits.append(hit)
		return _IMPACT
	if flown + 1 >= projectile.definition.lifetime_ticks or to.y < VOID_LIMIT_Y:
		stats[&"projectiles_expired"] += 1
		return _EXPIRED
	return -1


# The world and doors on the segment [param from]-[param to]: the first collision (with [param from_inside], also one
# that starts inside a body, at its origin), or null.
func _touch_world(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3,
		from_inside: bool) -> _Touch:
	if space == null:
		return null
	var length: float = from.distance_to(to)
	if length <= 0.0:
		return null
	_query.from = from
	_query.to = to
	_query.hit_from_inside = from_inside
	var result: Dictionary = space.intersect_ray(_query)
	if result.is_empty():
		return null
	var touch := _Touch.new()
	touch.kind = _TOUCH_WORLD
	touch.fraction = clampf(from.distance_to(result["position"] as Vector3) / length, 0.0, 1.0)
	var rid: RID = result.get("rid", RID())
	for target: StructureTarget in _resolver.structure_targets:
		if target.exclude.has(rid):
			touch.structure = target
			break
	return touch


# The boxes of shield walls hostile to the shooter that the arrow crosses head-on (against the facing of whoever holds
# it): those arriving from behind do not stop it (the wall covers the front).
func _touch_walls(projectile: Projectile, from: Vector3, to: Vector3, touches: Array[_Touch]) -> void:
	var travel: Vector3 = to - from
	var radius: float = projectile.definition.radius_m
	for wall: _Wall in _walls:
		if wall.holder.get_id() == projectile.owner_id or travel.dot(wall.forward) >= 0.0 \
				or not _resolver.is_hostile(projectile.realm, wall.realm):
			continue
		var fraction: float = HitShapes.segment_box_fraction(from, to, wall.box,
				wall.half_extents + Vector3(radius, radius, radius))
		if fraction < 0.0:
			continue
		var touch := _Touch.new()
		touch.kind = _TOUCH_WALL
		touch.fraction = fraction
		touch.wall = wall
		touches.append(touch)


# The capsules of the candidates at [code]s − rewind[/code] that the segment touches, screened with their swept boxes:
# only boxes whose left edge falls in the x window that the segment can overlap (binary search in the tick's sweep)
# and the wide ones are examined.
func _touch_characters(projectile: Projectile, from: Vector3, to: Vector3, s: int,
		touches: Array[_Touch]) -> void:
	if _candidate_count == 0:
		return
	var radius: float = projectile.definition.radius_m
	var margin := Vector3(radius, radius, radius)
	var low: Vector3 = from.min(to) - margin
	var high: Vector3 = from.max(to) + margin
	var sweep: PackedInt64Array = _sweep
	var first: int = sweep.bsearch(_sweep_key(low.x - _sweep_width) << _SWEEP_INDEX_BITS, true)
	var last_key: int = _sweep_key(high.x) + 1
	for position: int in range(first, sweep.size()):
		var entry: int = sweep[position]
		if (entry >> _SWEEP_INDEX_BITS) > last_key:
			break
		_touch_candidate(projectile, entry & _SWEEP_INDEX_MASK, from, to, low, high, s, touches, true)
	for index: int in _wide:
		_touch_candidate(projectile, index, from, to, low, high, s, touches, true)


## For tests: the net_ids of the tick's candidates [param s] whose capsule touches the segment [param from]-[param to] of
## [param projectile], with the flight's screening (swept boxes and x sweep) or, with [param full_scan], testing every
## capsule without screening. The two must always match.
func touched_ids(projectile: Projectile, from: Vector3, to: Vector3, s: int,
		full_scan: bool = false) -> PackedInt32Array:
	_prepare(s)
	var touches: Array[_Touch] = []
	if full_scan:
		for index: int in _candidate_count:
			_touch_candidate(projectile, index, from, to, Vector3.ZERO, Vector3.ZERO, s, touches, false)
	else:
		_touch_characters(projectile, from, to, s, touches)
	var ids := PackedInt32Array()
	for touch: _Touch in touches:
		ids.append(_candidate_ids[touch.candidate])
	ids.sort()
	return ids


# Edge (m) in whole sweep centimeters, always positive and rounded down.
static func _sweep_key(x: float) -> int:
	return floori(x * 100.0) + _SWEEP_OFFSET_CM


# Candidate [param index] against the segment [param from]-[param to] (with box [param low]-[param high], already
# widened with the projectile's radius; with [param check_box], first against its swept box).
func _touch_candidate(projectile: Projectile, index: int, from: Vector3, to: Vector3, low: Vector3,
		high: Vector3, s: int, touches: Array[_Touch], check_box: bool) -> void:
	if check_box:
		var box_low: Vector3 = _candidate_low[index]
		var box_high: Vector3 = _candidate_high[index]
		if low.x > box_high.x or high.x < box_low.x or low.z > box_high.z or high.z < box_low.z \
				or low.y > box_high.y or high.y < box_low.y:
			return
	var radius: float = projectile.definition.radius_m
	var view_tick: int = s - projectile.rewind
	var candidate_id: int = _candidate_ids[index]
	if _candidate_open[index] == 0 or candidate_id == projectile.owner_id \
			or projectile.ignored.has(candidate_id) \
			or not _resolver.is_hostile(projectile.realm, _candidate_realms[index]):
		return
	var combatant: Combatant = _candidates[index]
	var feet: Vector3 = _position_of(combatant, view_tick, s)
	if not feet.is_finite() or _was_dead(combatant, view_tick, s):
		return
	stats[&"projectile_capsule_tests"] += 1
	var fraction: float = HitShapes.segment_capsule_fraction(from, to, feet - Vector3(0.0, radius, 0.0),
			HitShapes.CAPSULE_RADIUS + radius, HitShapes.CAPSULE_HEIGHT + 2.0 * radius)
	if fraction < 0.0:
		return
	var touch := _Touch.new()
	touch.kind = _TOUCH_CHARACTER
	touch.fraction = fraction
	touch.candidate = index
	touches.append(touch)


# Feet of [param combatant] at tick [param tick] (the one frozen at [param s] or later; otherwise, the history), or
# [constant Vector3.INF] if unknown.
func _position_of(combatant: Combatant, tick: int, s: int) -> Vector3:
	if tick >= s:
		return combatant.frozen.position
	return _history.position_at(combatant.get_id(), tick)


# true if [param combatant] had the "dead" bit at tick [param tick].
func _was_dead(combatant: Combatant, tick: int, s: int) -> bool:
	var flags: int = combatant.frozen.defense if tick >= s else _history.get_flags(combatant.get_id(), tick)
	return flags >= 0 and (flags & ActionMachine.DEFENSE_DEAD) != 0


# Defense of [param victim] against the arrow: block facing it (the weapon's cone or, with the wall, the rules' width)
# in the sample of s or of s − defense_rewind if it still counts; never a parry.
func _defense(projectile: Projectile, victim: Combatant, hit: CombatResolver.Hit, s: int) -> int:
	var frame: Combatant.Frozen = victim.frozen
	var weapon: WeaponTicks = CombatCatalog.weapon(frame.weapon_id)
	var attack: AttackTicks = projectile.attack
	if weapon == null or attack.unblockable or not DamageFormula.is_physical(attack.damage_type):
		return CombatResolver.Outcome.IMPACT
	var rules: CombatRules = CombatCatalog.rules()
	var cone: float = weapon.block_angle_deg
	var wide_cone: float = rules.ability_block_angle_deg
	# Where the arrow comes from: a point behind the victim, against its velocity.
	var back := Vector3(-hit.direction.x, 0.0, -hit.direction.z)
	if CombatResolver.blocks_sample(frame, frame.defense, cone, wide_cone, frame.position + back):
		hit.wide_block = (frame.defense & ActionMachine.DEFENSE_WIDE_BLOCK) != 0
		return CombatResolver.Outcome.BLOCKED
	var old_tick: int = s - projectile.defense_rewind
	if old_tick < s and not CombatResolver.dropped_guard_after(frame, float(old_tick)):
		var old: StateHistory.Sample = _history.sample(victim.get_id(), float(old_tick))
		if old != null and CombatResolver.blocks_sample(old, old.flags, cone, wide_cone, old.position + back):
			hit.wide_block = (old.flags & ActionMachine.DEFENSE_WIDE_BLOCK) != 0
			return CombatResolver.Outcome.BLOCKED
	return CombatResolver.Outcome.IMPACT


# A hit of [param projectile] on [param victim] at tick [param s] (the result is set by the caller).
func _hit_on(projectile: Projectile, victim: Combatant, s: int, flown: int,
		touch: _Touch) -> CombatResolver.Hit:
	var hit: CombatResolver.Hit = _base_hit(projectile, s)
	hit.victim = victim
	hit.direction = projectile.velocity_after(float(flown) + touch.fraction)
	return hit


func _structure_hit(projectile: Projectile, target: StructureTarget, s: int) -> CombatResolver.Hit:
	var hit: CombatResolver.Hit = _base_hit(projectile, s)
	hit.structure = target
	hit.outcome = CombatResolver.Outcome.STRUCTURE
	hit.view_tick = float(s)
	hit.rewind = 0.0
	return hit


func _base_hit(projectile: Projectile, s: int) -> CombatResolver.Hit:
	var hit := CombatResolver.Hit.new()
	hit.attacker = projectile.owner
	hit.attack = projectile.attack
	hit.projectile_id = projectile.id
	hit.projectile = projectile
	hit.view_tick = float(s - projectile.rewind)
	hit.rewind = float(projectile.rewind)
	return hit


# --- Candidates and walls of the tick --------------------------------------------------------------

# Computes once per tick the candidates (alive, with their swept box widened with the capsule) and the shield walls of
# [member _combatants] (only of those without protection and outside their realm's safe zone), in the tick's arrays
# (without creating objects except the walls).
func _prepare(s: int) -> void:
	if _prepared_tick == s:
		return
	_prepared_tick = s
	_walls = []
	var safe_areas: SafeAreas = _resolver.get_safe_areas()
	var check_safe: bool = safe_areas.size() > 0
	var reach := Vector3(HitShapes.CAPSULE_RADIUS, 0.0, HitShapes.CAPSULE_RADIUS)
	var top := Vector3(HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT, HitShapes.CAPSULE_RADIUS)
	var total: int = _combatants.size()
	if _candidate_ids.size() < total:
		_candidates.resize(total)
		_candidate_ids.resize(total)
		_candidate_realms.resize(total)
		_candidate_open.resize(total)
		_candidate_low.resize(total)
		_candidate_high.resize(total)
	var count: int = 0
	for combatant: Combatant in _combatants:
		# An invisible GM is not a target: an arrow passes through it (docs/platform.md §9.1).
		if combatant.is_dead() or combatant.is_gm_invisible():
			continue
		var frame: Combatant.Frozen = combatant.frozen
		var net_id: int = combatant.get_id()
		var realm: int = combatant.get_realm()
		var open: bool = not combatant.is_protected(s) \
				and not (check_safe and safe_areas.contains_own(realm, frame.position))
		var low: Vector3 = frame.position
		var high: Vector3 = frame.position
		var box: AABB = _history.swept_box(net_id)
		if box.size.x >= 0.0:
			low = low.min(box.position)
			high = high.max(box.end)
		_candidates[count] = combatant
		_candidate_ids[count] = net_id
		_candidate_realms[count] = realm
		_candidate_open[count] = 1 if open else 0
		_candidate_low[count] = low - reach
		_candidate_high[count] = high + top
		count += 1
		# Only the wall of whoever is "open": that of someone with protection or in their realm's safe zone does not stop
		# arrows (they pass as through their capsule), so it spends no stamina, their guard is not broken, and they do not end
		# up in combat inside their camp (docs/combat.md §5).
		if open and frame.wall_half_extents != Vector3.ZERO:
			var wall := _Wall.new()
			wall.holder = combatant
			wall.realm = realm
			wall.box = frame.wall
			wall.half_extents = frame.wall_half_extents
			wall.forward = frame.wall.basis * Vector3.FORWARD
			_walls.append(wall)
	_candidate_count = count
	# No dangling references to whoever is no longer there.
	for index: int in range(count, _candidates.size()):
		_candidates[index] = null
	# The x sweep: the narrow ones sorted by their left edge; the wide ones, separately.
	_sweep.resize(count)
	_wide.clear()
	_sweep_width = 0.0
	var narrow: int = 0
	for index: int in count:
		var width: float = _candidate_high[index].x - _candidate_low[index].x
		if not (width <= _SWEEP_WIDE_M) or index > _SWEEP_INDEX_MASK:
			_wide.append(index)
			continue
		_sweep_width = maxf(_sweep_width, width)
		_sweep[narrow] = (_sweep_key(_candidate_low[index].x) << _SWEEP_INDEX_BITS) | index
		narrow += 1
	_sweep.resize(narrow)
	_sweep.sort()
	# Rounding the edge to centimeters (downwards) never leaves a box out: the window is opened one centimeter wider.
	_sweep_width += 0.01


# --- Despawns ------------------------------------------------------------------------------------

## Withdraws at tick [param s], with DESPAWN 5, all live projectiles of [param owner_id] (the shooter is removed:
## departure, [code]--fake-churn[/code], a withdrawn NPC).
func forget_owner(owner_id: int, s: int) -> void:
	var leaving: Array[Projectile] = []
	for projectile: Projectile in _live:
		if projectile.owner_id == owner_id:
			leaving.append(projectile)
	for projectile: Projectile in leaving:
		stats[&"projectiles_forgotten"] += 1
		_live.erase(projectile)
		_end(projectile, s, _EXPIRED)
	# Neither the tick's candidates nor the walls hold on to whoever leaves anymore.
	_prepared_tick = -1


## Removes all projectiles without notice (server shutdown).
func clear() -> void:
	for projectile: Projectile in _live:
		registry.release_transient_id(projectile.id, projectile.spawn_tick)
	_live.clear()
	_rejected.clear()
	_combatants = []
	_candidates.clear()
	_candidate_ids.clear()
	_candidate_realms.clear()
	_candidate_open.clear()
	_candidate_low.clear()
	_candidate_high.clear()
	_candidate_count = 0
	_sweep.clear()
	_wide.clear()
	_walls = []
	_prepared_tick = -1


# Despawn of [param projectile] (already out of the list): DESPAWN and its id to quarantine.
func _end(projectile: Projectile, s: int, reason: int) -> void:
	registry.release_transient_id(projectile.id, s)
	despawned.emit(projectile.id, s, reason, PackedInt32Array([projectile.owner_id]))
