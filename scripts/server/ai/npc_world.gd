class_name NpcWorld
extends RefCounted
## What an NPC's brain sees and can do on the server (docs/fortress.md, section 4.2): who is a possible
## target, whether there is line of sight, navigation routes, attack tokens, alert groups and
## warnings to the spawner system. It is assembled by the [NpcSpawnerSystem] from the [ZoneServer]'s pieces and handed
## to each [HfsmBrain].
## [br][br]
## Everything is computed with the state "after s − 1" because the brains think in step 0 of the tick
## (docs/fortress.md, section 1.7), before anyone is simulated. The list of possible targets is built once per tick
## and reused.

## Zone (for the hostility rules).
var zone_id: StringName = &""
var combat: CombatDirector = null
var safe_areas: SafeAreas = null
## Navigation (null = no mesh: NPCs go in a straight line).
var navigation: NpcNavigation = null
var tokens: AttackTokens = AttackTokens.new()
## [code]() -> PhysicsDirectSpaceState3D[/code]: the physics space for line of sight.
var space_provider: Callable = Callable()
## [code](net_id: int, position: Vector3) -> void[/code]: teleports an NPC (the stuck return).
var teleporter: Callable = Callable()
## [code](brain: HfsmBrain, definition_id: StringName, count: int) -> int[/code]: creates reinforcements next to the
## NPC and returns how many it created.
var reinforcer: Callable = Callable()
## Tick being thought about (the state of the bodies is that after the previous tick).
var tick: int = 0

# Possible targets for this tick: alive, without respawn protection and not dummies.
var _candidates: Array[Combatant] = []
var _candidates_tick: int = -1
# (NPC's side · 16 + the other's side) -> whether there is damage between them in the zone.
var _hostile_cache: Dictionary[int, bool] = {}
# Alert group -> brains that make it up.
var _groups: Dictionary[StringName, Array] = {}
var _results: Array[Combatant] = []
# Queries made since it came into existence (for measuring).
var queries: int = 0
var line_of_sight_checks: int = 0


## Starts tick [param new_tick]: the possible targets are rebuilt the first time they are requested.
func begin_tick(new_tick: int) -> void:
	tick = new_tick


## The [Combatant] of [param net_id], or null.
func find_combatant(net_id: int) -> Combatant:
	return combat.get_combatant(net_id) if combat != null else null


## The combatants that an NPC on side [param realm] can attack within [param radius] m (horizontally)
## of [param position]: alive, hostile according to [FactionRules], outside respawn protection and not
## dummies. Whoever is safe in their own realm's safe zone does not count (the resolver would not damage them);
## with [param ignores_safe_area] (the Guardians) the opposite happens: only those inside the NPC's realm's
## safe zone count. The array is the same on every call: use it before requesting another.
func query_targets(position: Vector3, radius: float, realm: int, ignores_safe_area: bool) -> Array[Combatant]:
	queries += 1
	_results.clear()
	if combat == null:
		return _results
	if _candidates_tick != tick:
		_rebuild_candidates()
	var radius_squared: float = radius * radius
	for candidate: Combatant in _candidates:
		var other: Vector3 = candidate.entity.get_position()
		var dx: float = other.x - position.x
		var dz: float = other.z - position.z
		if dx * dx + dz * dz > radius_squared:
			continue
		if not _is_hostile(realm, candidate.get_realm()):
			continue
		var in_own_camp: bool = safe_areas != null and safe_areas.contains_own(realm, other)
		if ignores_safe_area:
			if not in_own_camp:
				continue
		elif safe_areas != null and safe_areas.contains_own(candidate.get_realm(), other):
			continue
		_results.append(candidate)
	return _results


## true if [param candidate] is still a valid target for an NPC on side [param realm]. Cheaper than
## [method query_targets] when you already know whom you are chasing.
func is_valid_target(candidate: Combatant, realm: int, ignores_safe_area: bool) -> bool:
	if candidate == null or candidate.is_dead() or candidate.is_protected(tick) or candidate.immortal \
			or candidate.is_gm_invisible():
		return false
	if not _is_hostile(realm, candidate.get_realm()):
		return false
	var position: Vector3 = candidate.entity.get_position()
	if ignores_safe_area:
		return safe_areas != null and safe_areas.contains_own(realm, position)
	return safe_areas == null or not safe_areas.contains_own(candidate.get_realm(), position)


## true if there is line of sight between the feet [param from_feet] and [param to_feet] (from the chest to the
## other's center, against the world and structures).
func line_of_sight(from_feet: Vector3, to_feet: Vector3) -> bool:
	line_of_sight_checks += 1
	if not space_provider.is_valid():
		return true
	var space: PhysicsDirectSpaceState3D = space_provider.call()
	return space == null or HitShapes.has_line_of_sight(space, from_feet, to_feet)


## Route from [param from] to [param to] for an agent on side [param realm] (empty if there is no navigation ready).
func get_path(from: Vector3, to: Vector3, realm: int) -> PackedVector3Array:
	if navigation == null:
		return PackedVector3Array()
	return navigation.get_path(from, to, realm)


## true if navigation is set up and gives real routes.
func has_navigation() -> bool:
	return navigation != null and navigation.is_ready()


## Teleports NPC [param net_id] to [param position].
func teleport(net_id: int, position: Vector3) -> void:
	if teleporter.is_valid():
		teleporter.call(net_id, position)


## Requests reinforcements of type [param definition_id] ([param count]) next to [param brain]. Returns how many
## were created.
func request_reinforcements(brain: HfsmBrain, definition_id: StringName, count: int) -> int:
	if reinforcer.is_valid():
		return int(reinforcer.call(brain, definition_id, count))
	return 0


# --- Alert groups -------------------------------------------------------------------------------

## Puts [param brain] in alert group [param group].
func join_group(group: StringName, brain: HfsmBrain) -> void:
	if group.is_empty():
		return
	var members: Array = _groups.get(group, [])
	if not members.has(brain):
		members.append(brain)
	_groups[group] = members


## Takes [param brain] out of its group.
func leave_group(group: StringName, brain: HfsmBrain) -> void:
	var members: Array = _groups.get(group, [])
	members.erase(brain)
	if members.is_empty():
		_groups.erase(group)


## How many living members [param group] has, not counting [param except].
func count_alive_in_group(group: StringName, except: HfsmBrain) -> int:
	var total: int = 0
	for member: HfsmBrain in _groups.get(group, []):
		if member != except and member.is_alive():
			total += 1
	return total


## Warns the members of group [param group] that are not fighting and are within [param radius] m of
## [param source] that there is an enemy ([param target_id]). Returns how many it warned.
func alert_group(group: StringName, source: HfsmBrain, radius: float, target_id: int) -> int:
	var alerted: int = 0
	var origin: Vector3 = source.get_position()
	for member: HfsmBrain in _groups.get(group, []):
		if member == source or not member.is_alive():
			continue
		var offset: Vector3 = member.get_position() - origin
		offset.y = 0.0
		if offset.length() > radius:
			continue
		if member.receive_alert(target_id, tick):
			alerted += 1
	return alerted


## Removes the groups and tokens (on server shutdown).
func clear() -> void:
	_groups.clear()
	tokens.clear()
	_candidates.clear()
	_candidates_tick = -1


func _rebuild_candidates() -> void:
	_candidates_tick = tick
	_candidates.clear()
	for candidate: Combatant in combat.get_sorted():
		# An invisible GM is not a target for NPCs (docs/platform.md §9.1).
		if candidate.is_dead() or candidate.immortal or candidate.is_protected(tick) or candidate.is_gm_invisible():
			continue
		_candidates.append(candidate)


func _is_hostile(my_realm: int, other_realm: int) -> bool:
	var key: int = my_realm * 16 + other_realm
	if not _hostile_cache.has(key):
		_hostile_cache[key] = FactionRules.can_damage(my_realm, other_realm, zone_id)
	return _hostile_cache[key]
