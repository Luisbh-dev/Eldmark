class_name DownedSystem
extends RefCounted
## Knocked down, lifting and finishing off on the server (docs/abilities.md, section 4.5; CMB-28).
## [br][br]
## [b]When[/b] ([method should_down]): the health of a [b]player[/b] (fake ones too) reaches 0 from a
## hit, an arrow or a pulse whose author is a player of a hostile realm in an RvR zone. Otherwise, direct
## death (NPC, environment, dummy, PvE). Decided by the [CombatDirector] when applying the hit.
## [br][br]
## [b]Falling[/b] ([method down]): [method ActionMachine.impose_downed], health 0, downed health
## [member CombatRules.downed_health], author and source, effects cleared (without STATUS: DOWNED clears them on the
## client) and the DOWNED event to the whole zone. The hit's HIT carries bit 6 (set by the director).
## [br][br]
## [b]Step 7 of the tick[/b] ([method step], docs/abilities.md, section 4.1), by net_id:
## [br]1. [b]Bleeding out[/b]: downed health drops exactly in integers down to 0 over
## [member CombatTables.downed_ticks] (−1 every 3 ticks with 400 in 1200). At 0, death: killer is the last
## enemy that damaged it while already downed or, failing that, whoever downed it, with the source "bled out".
## [br]2. [b]New INTERACTs[/b]: an INTERACT edge on a real input (the buttons of [code]s[/code]
## against those of [code]s − 1[/code], kept by the [Combatant]) from someone alive, in NONE or BLOCK and on the
## ground, looks for the nearest downed player within [member CombatRules.interact_range_m] horizontally (height difference ≤
## [constant MAX_HEIGHT_DIFFERENCE], ties by net_id) with line of sight from the chest (feet + 1.4) to feet +
## 0.5 of the downed player: an ally whom nobody is lifting → REVIVE (INTERACT 1); an enemy with no safe zones in
## between → EXECUTE (INTERACT 4). [method ActionMachine.impose_interact] and [code]commit_state[/code].
## Starting to finish off removes respawn protection (like attacking): otherwise nobody could cut off the finishing of
## someone who has just respawned, because a protected player is no candidate for any hit (H5 review).
## [br]3. [b]Progress and end[/b]: at [code]s == start + duration[/code] it ends (checked before continuing: on
## that tick the simulation has already returned to NONE): lifting → [method ActionMachine.impose_revived] with
## [member CombatRules.revived_health] (INTERACT 3); finishing off → death with the source "execution". Before that, each
## tick it is cut (INTERACT 2 or 5, and [method ActionMachine.impose_interrupt] if still in the action) if
## whoever acts has left the action (released, dodged, had another imposed or was interrupted by a hit), the
## target is no longer downed or has taken damage on this tick, goes beyond
## [member CombatRules.interact_keep_range_m] or loses line of sight (a closed gate cuts it); an
## execution also if a safe zone ends up in between (the downed player drags themselves to their camp or the finisher
## enters theirs), and that is also checked on the final tick.
## [br][br]
## A downed player is neither alive nor dead ([method Combatant.is_downed]): it is a candidate for hits and for
## NPCs, receives no effects or pulses, does not count in the circle, neither heals nor respawns and its removal (leaving,
## disconnecting, the end of the body from GUE-41) is treated as a death ([method killer_of]).
## [br][br]
## It touches neither the network nor the clock: it announces with [signal event_emitted] (DOWNED and INTERACT) and requests deaths with
## [signal killed], which the [CombatDirector] applies (DEATH and KILL).

## A DOWNED or INTERACT event and the net_ids involved (the downed player and its author or whoever acts).
signal event_emitted(event: NetMessages.EntityEvent, involved: PackedInt32Array)
## A downed player dies bled out or finished off: [param killer_id] is the killer (0 = nobody) and [param source] the
## source ([constant CombatSource.BLEED_OUT] or [constant CombatSource.EXECUTE]). The [CombatDirector] kills them.
signal killed(victim: Combatant, killer_id: int, source: int, tick: int)

## Maximum height difference (m) between whoever acts and the downed player to start lifting or finishing them off, and to continue.
const MAX_HEIGHT_DIFFERENCE: float = 1.5
## Height above the downed player's feet that the line-of-sight ray reaches (they are on the ground).
const DOWNED_SIGHT_HEIGHT: float = 0.5

const _NONE: int = CombatState.Action.NONE
const _BLOCK: int = CombatState.Action.BLOCK
const _REVIVE: int = CombatState.Action.REVIVE
const _EXECUTE: int = CombatState.Action.EXECUTE

## Zone (the hostility rules and RvR mode) and its safe zones (null = none).
var zone_id: StringName = &""
var safe_areas: SafeAreas = null
## The zone's status effects: cleared on falling.
var status: StatusSystem = null
## The zone's combatants by net_id (the [CombatDirector]'s dictionary: not a copy).
var combatants: Dictionary[int, Combatant] = {}
## Counters for the run (for the server report).
var stats: Dictionary[StringName, int] = {
	&"downs": 0, &"revives": 0, &"executions": 0, &"bled_out": 0, &"interact_started": 0,
	&"interact_cut": 0,
}

# Downed players of the zone and those who lift or finish off, by net_id: with none, step() iterates over nobody.
var _downed: Dictionary[int, Combatant] = {}
var _actors: Dictionary[int, Combatant] = {}
# (realm of whoever acts · 16 + realm of the downed player) -> whether they are hostile in this zone.
var _hostile_cache: Dictionary[int, bool] = {}


## true if [param victim], who has just run out of health, is knocked down instead of dying: it is a player
## (not an NPC or a dummy) and the hit's author is a player ([param author_is_player]) of a realm
## ([param author_realm]) hostile to its own in an RvR zone. Against NPCs, the environment or the Hollow, direct death.
func should_down(victim: Combatant, author_realm: int, author_is_player: bool) -> bool:
	if victim == null or victim.immortal or not author_is_player:
		return false
	if victim.entity == null or victim.entity.kind != NetProtocol.EntityKind.PLAYER:
		return false
	var victim_realm: int = victim.get_realm()
	if not RealmCatalog.is_realm_code(author_realm) or not RealmCatalog.is_realm_code(victim_realm):
		return false
	return NetZones.is_rvr(String(zone_id)) and _is_hostile(author_realm, victim_realm)


## true if the zone allows knocking down between realms (it is RvR).
func is_enabled() -> bool:
	return NetZones.is_rvr(String(zone_id))


## Leaves [param victim] downed at tick [param s] by [param author_id] (0 = nobody: command 15) with
## source [param source]: DOWNED with the downed health, no effects, and the DOWNED event. Does nothing on
## someone already downed or dead.
func down(victim: Combatant, author_id: int, source: int, s: int) -> void:
	if victim == null or victim.is_downed() or victim.death_tick >= 0:
		return
	var character: PlayerCharacter = victim.get_character()
	victim.mark_downed(s, author_id, source, CombatCatalog.rules().downed_health)
	if status != null:
		status.clear(victim)
	if character != null:
		ActionMachine.impose_downed(character.combat, s)
		CombatDirector.commit_state(character)
	_downed[victim.get_id()] = victim
	stats[&"downs"] += 1
	event_emitted.emit(NetMessages.EntityEvent.downed(victim.get_id(), s, author_id, source),
			_involved(victim.get_id(), author_id))


## Step 7 of tick [param s] (docs/abilities.md, section 4.1) over [param list] (by net_id):
## bleeding out, new INTERACTs and the progress and end of lifting and finishing off. [param space] is the world's
## physics space (line of sight; null = no world).
func step(s: int, list: Array[Combatant], space: PhysicsDirectSpaceState3D) -> void:
	if _downed.is_empty() and _actors.is_empty():
		return
	var tables: CombatTables = CombatCatalog.tables()
	# 1. Bleeding out.
	if not _downed.is_empty():
		for victim: Combatant in list:
			if not victim.is_downed():
				continue
			var loss: int = bleed_loss(s - victim.downed_tick, victim.downed_health, tables)
			if loss <= 0:
				continue
			victim.downed_health = maxi(victim.downed_health - loss, 0)
			if victim.downed_health == 0:
				stats[&"bled_out"] += 1
				killed.emit(victim, killer_of(victim), CombatSource.BLEED_OUT, s)
	# 2. New INTERACTs (there is a target only if some downed player remains).
	if not _downed.is_empty():
		for actor: Combatant in list:
			if _interact_pressed(actor, s):
				_try_start(actor, s, space, tables)
	# 3. Progress and end of what was already under way.
	if not _actors.is_empty():
		for actor: Combatant in list:
			if actor.interact_target != 0 and actor.interact_start != s:
				_progress(actor, s, space, tables)
	_prune()


## What bleeding out removes on the tick that is [param elapsed] since the fall: downed health drops
## in exact integers down to 0 over [member CombatTables.downed_ticks] (with 400 in 1200, 1 every 3 ticks).
## [param remaining] bounds the result.
static func bleed_loss(elapsed: int, remaining: int, tables: CombatTables) -> int:
	var total_ticks: int = tables.downed_ticks
	var full: int = tables.rules.downed_health
	if elapsed <= 0 or total_ticks <= 0 or remaining <= 0:
		return 0
	@warning_ignore("integer_division")
	var now: int = elapsed * full / total_ticks
	@warning_ignore("integer_division")
	var before: int = (elapsed - 1) * full / total_ticks
	return mini(now - before, remaining)


## The killer of a downed player who dies without a hit (bleeding out, on leaving, the environment): the last enemy that
## damaged it while already downed or, failing that, whoever downed it; 0 if none remains in the zone.
func killer_of(victim: Combatant) -> int:
	if victim.last_enemy_id != 0 and victim.last_enemy_tick >= victim.downed_tick \
			and combatants.has(victim.last_enemy_id):
		return victim.last_enemy_id
	if victim.downed_by != 0 and combatants.has(victim.downed_by):
		return victim.downed_by
	return 0


## Stops tracking [param victim] as downed (it has died or respawned). Whoever was lifting or
## finishing it off is cut on the next step 7.
func release(victim: Combatant) -> void:
	if victim != null:
		_downed.erase(victim.get_id())


## On removing [param net_id]: stops tracking it as downed and as someone acting.
func forget(net_id: int) -> void:
	_downed.erase(net_id)
	_actors.erase(net_id)


## Downed players in the zone now.
func downed_count() -> int:
	return _downed.size()


## Those lifting or finishing off now.
func interacting_count() -> int:
	return _actors.size()


## Forgets everyone (server shutdown).
func clear() -> void:
	_downed.clear()
	_actors.clear()


# --- INTERACT --------------------------------------------------------------------------------------

# INTERACT edge of [param actor] on a real input of tick [param s] (the one that was simulated: real or
# substitute), against the previous tick's buttons. Updates the buttons the Combatant keeps.
func _interact_pressed(actor: Combatant, s: int) -> bool:
	var queue: InputQueue = actor.queue
	if queue == null:
		return false
	var input: PlayerInput = queue.get_applied(s)
	if input == null:
		return false
	var buttons: int = input.buttons & ~PlayerInput.SUBSTITUTED
	var previous: int = buttons
	if actor.last_buttons_tick == s - 1:
		previous = actor.last_buttons
	else:
		# With no downed players on the previous tick they were not stored: the queue provides them (otherwise there is no edge).
		var before: PlayerInput = queue.get_applied(s - 1)
		if before != null:
			previous = before.buttons & ~PlayerInput.SUBSTITUTED
	actor.last_buttons = buttons
	actor.last_buttons_tick = s
	var real: bool = (input.buttons & PlayerInput.SUBSTITUTED) == 0
	return real and (buttons & PlayerInput.INTERACT) != 0 and (previous & PlayerInput.INTERACT) == 0


# Starts lifting or finishing off the nearest valid downed player, if [param actor] can: alive, with no other
# interaction, in NONE or BLOCK and on the ground.
func _try_start(actor: Combatant, s: int, space: PhysicsDirectSpaceState3D, tables: CombatTables) -> void:
	var character: PlayerCharacter = actor.get_character()
	if character == null or not actor.is_alive() or actor.is_interacting():
		return
	var combat: CombatState = character.combat
	if (combat.action != _NONE and combat.action != _BLOCK) or not character.grounded:
		return
	var rules: CombatRules = tables.rules
	var feet: Vector3 = actor.entity.get_position()
	var range_squared: float = rules.interact_range_m * rules.interact_range_m
	var options: Array[Array] = []
	for target: Combatant in _downed.values():
		if target == actor or not target.is_downed():
			continue
		var other: Vector3 = target.entity.get_position()
		if absf(other.y - feet.y) > MAX_HEIGHT_DIFFERENCE:
			continue
		var distance_squared: float = _horizontal_distance_squared(feet, other)
		if distance_squared > range_squared:
			continue
		var action: int = _interaction_for(actor, target)
		if action != 0:
			options.append([distance_squared, target.get_id(), target, action])
	if options.is_empty():
		return
	options.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	for option: Array in options:
		var target: Combatant = option[2]
		if not _clear_line(space, feet, target.entity.get_position()):
			continue
		var action: int = option[3]
		if action == _EXECUTE:
			# Finishing off is attacking: removes respawn protection from this tick on (this tick's hits have already
			# been resolved; from the next one, the downed player's allies can cut it).
			actor.protected_until = mini(actor.protected_until, s)
		ActionMachine.impose_interact(combat, s, action)
		CombatDirector.commit_state(character)
		actor.interact_target = target.get_id()
		actor.interact_action = action
		actor.interact_start = s
		_actors[actor.get_id()] = actor
		stats[&"interact_started"] += 1
		var operation: int = NetMessages.EntityEvent.InteractOp.REVIVE if action == _REVIVE \
				else NetMessages.EntityEvent.InteractOp.EXECUTE
		event_emitted.emit(NetMessages.EntityEvent.interact(target.get_id(), s, actor.get_id(), operation,
				s + _duration(action, tables)), _involved(target.get_id(), actor.get_id()))
		return


# What [param actor] can do with the downed player [param target]: REVIVE an ally whom nobody is lifting,
# EXECUTE an enemy with no safe zones in between, or 0 (always 0 for an invisible GM).
func _interaction_for(actor: Combatant, target: Combatant) -> int:
	# An invisible GM neither lifts nor finishes off (docs/platform.md §9.1).
	if actor.is_gm_invisible():
		return 0
	if target.get_realm() == actor.get_realm():
		return 0 if _being_revived(target) else _REVIVE
	if not _is_hostile(actor.get_realm(), target.get_realm()):
		return 0
	return 0 if _safe_area_between(actor, target) else _EXECUTE


# true if there is a safe zone in between for finishing off: the downed player is in their realm's, or the finisher in
# theirs (unless they ignore it). Applies to starting, continuing and ending.
func _safe_area_between(actor: Combatant, target: Combatant) -> bool:
	if safe_areas == null:
		return false
	if safe_areas.contains_own(target.get_realm(), target.entity.get_position()):
		return true
	return not actor.ignores_safe_area \
			and safe_areas.contains_own(actor.get_realm(), actor.entity.get_position())


func _being_revived(target: Combatant) -> bool:
	for actor: Combatant in _actors.values():
		if actor.interact_target == target.get_id() and actor.interact_action == _REVIVE:
			return true
	return false


# One tick of an interaction in progress: it ends on its tick, or is cut if what it needs no longer holds.
func _progress(actor: Combatant, s: int, space: PhysicsDirectSpaceState3D, tables: CombatTables) -> void:
	var target: Combatant = combatants.get(actor.interact_target)
	var end_tick: int = actor.interact_start + _duration(actor.interact_action, tables)
	if s >= end_tick:
		# Ending is checked before continuing: on this tick the simulation has already returned to NONE.
		if s == end_tick and target != null and target.is_downed() and actor.is_alive() \
				and not (actor.interact_action == _EXECUTE and _safe_area_between(actor, target)):
			_complete(actor, target, s, tables)
		else:
			_cut(actor, s)
		return
	if not _keeps_going(actor, target, s, space, tables.rules):
		_cut(actor, s)


func _keeps_going(actor: Combatant, target: Combatant, s: int, space: PhysicsDirectSpaceState3D,
		rules: CombatRules) -> bool:
	var character: PlayerCharacter = actor.get_character()
	if character == null or not _still_in_action(actor, character.combat):
		return false
	if target == null or not target.is_downed() or target.last_damage_tick == s:
		return false
	if actor.interact_action == _EXECUTE and _safe_area_between(actor, target):
		# They have dragged themselves to their camp (or the finisher has entered theirs): they cannot be finished off there.
		return false
	var feet: Vector3 = actor.entity.get_position()
	var other: Vector3 = target.entity.get_position()
	if absf(other.y - feet.y) > MAX_HEIGHT_DIFFERENCE \
			or _horizontal_distance_squared(feet, other) > rules.interact_keep_range_m * rules.interact_keep_range_m:
		return false
	return _clear_line(space, feet, other)


# Ends [param actor]'s interaction on [param target]: lifted (revived health, NONE and INTERACT 3)
# or finished off (death with the source "execution").
func _complete(actor: Combatant, target: Combatant, s: int, tables: CombatTables) -> void:
	var action: int = actor.interact_action
	var actor_id: int = actor.get_id()
	actor.clear_interaction()
	_actors.erase(actor_id)
	if action == _REVIVE:
		var character: PlayerCharacter = target.get_character()
		target.clear_downed()
		target.health = mini(tables.rules.revived_health, target.max_health)
		_downed.erase(target.get_id())
		if character != null:
			ActionMachine.impose_revived(character.combat, s)
			CombatDirector.commit_state(character)
		stats[&"revives"] += 1
		event_emitted.emit(NetMessages.EntityEvent.interact(target.get_id(), s, actor_id,
				NetMessages.EntityEvent.InteractOp.REVIVED, s), _involved(target.get_id(), actor_id))
		return
	stats[&"executions"] += 1
	killed.emit(target, actor_id, CombatSource.EXECUTE, s)


# Cuts [param actor]'s interaction: if still in the action, NONE keeping its action_tick
# (impose_interrupt); INTERACT 2 or 5.
func _cut(actor: Combatant, s: int) -> void:
	var target_id: int = actor.interact_target
	var action: int = actor.interact_action
	var character: PlayerCharacter = actor.get_character()
	if character != null and _still_in_action(actor, character.combat):
		ActionMachine.impose_interrupt(character.combat, s)
		CombatDirector.commit_state(character)
	actor.clear_interaction()
	_actors.erase(actor.get_id())
	stats[&"interact_cut"] += 1
	var operation: int = NetMessages.EntityEvent.InteractOp.REVIVE_CUT if action == _REVIVE \
			else NetMessages.EntityEvent.InteractOp.EXECUTE_CUT
	event_emitted.emit(NetMessages.EntityEvent.interact(target_id, s, actor.get_id(), operation, s),
			_involved(target_id, actor.get_id()))


static func _still_in_action(actor: Combatant, combat: CombatState) -> bool:
	return combat.action == actor.interact_action and combat.action_tick == actor.interact_start


static func _duration(action: int, tables: CombatTables) -> int:
	return tables.revive_ticks if action == _REVIVE else tables.execute_ticks


# Removes from the lists whoever is no longer there (dead, lifted, removed).
func _prune() -> void:
	for net_id: int in _downed.keys():
		var victim: Combatant = _downed[net_id]
		if not victim.is_downed() or not combatants.has(net_id):
			_downed.erase(net_id)
	for net_id: int in _actors.keys():
		if not combatants.has(net_id):
			_actors.erase(net_id)


# Line of sight from the actor's chest (feet + 1.4) to feet + 0.5 of the downed player, against the world and
# structures (a closed gate cuts it).
static func _clear_line(space: PhysicsDirectSpaceState3D, actor_feet: Vector3, target_feet: Vector3) -> bool:
	if space == null:
		return true
	return HitShapes.is_ray_clear(space, actor_feet + Vector3(0.0, HitShapes.LINE_OF_SIGHT_FROM_HEIGHT, 0.0),
			target_feet + Vector3(0.0, DOWNED_SIGHT_HEIGHT, 0.0))


static func _horizontal_distance_squared(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return dx * dx + dz * dz


func _is_hostile(my_realm: int, other_realm: int) -> bool:
	var key: int = my_realm * 16 + other_realm
	if not _hostile_cache.has(key):
		_hostile_cache[key] = FactionRules.can_damage(my_realm, other_realm, zone_id)
	return _hostile_cache[key]


static func _involved(first: int, second: int) -> PackedInt32Array:
	var involved := PackedInt32Array()
	if first > 0:
		involved.append(first)
	if second > 0 and second != first:
		involved.append(second)
	return involved
