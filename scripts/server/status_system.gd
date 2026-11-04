class_name StatusSystem
extends RefCounted
## Server status effects (docs/abilities.md, section 4.3; CMB-20): bleed, heal over time, slow, root, bonus damage and
## reduced mitigation.
## [br][br]
## Each [Combatant] carries up to [constant MAX_EFFECTS] [StatusSystem.ActiveEffect] in [member Combatant.effects],
## sorted by effect id. One per effect: applying one that is already present renews it according to its
## [enum StatusEffectDefinition.Stacking]. A new one when there are already [constant MAX_EFFECTS] replaces the one that
## ends soonest.
## [br][br]
## [b]Applying[/b] ([method apply]) at [code]s[/code]: REFRESH extends the end to [code]s + D[/code] (the anchor does not
## change); STACK adds a stack (up to [member StatusTicks.max_stacks]) and extends the end; STRONGEST keeps the strongest
## and, if equal (the same effect always is: its data does not change), the latest end and the author of that end.
## REFRESH and STACK always pass to the latest author. A new one starts with [code]anchor = s[/code] and one stack. SLOW
## and ROOT also write their movement slot in [CombatState] ([method ActionMachine.impose_move_effect]), which is what
## changes the speed on the client and on the server. STATUS event 1.
## [br][br]
## [b]Exact pulses[/b] ([method step], tick step 6): at [code]anchor + k · P[/code] for [code]k = 1, 2…[/code] while
## [code]anchor + k · P ≤ until[/code]; without renewal they are [code]D / P[/code] (6 for bleed). First the pulses of
## everyone are gathered and then applied, by net_id of the affected one and effect id, skipping whoever is already dead
## or knocked down in this tick: a pulse that kills or knocks down midway does not change the list being walked. A damage
## pulse is applied by the [CombatDirector] ([signal pulse_damage]: HIT with the effect's source, it can kill and does not
## interrupt); a heal pulse heals without exceeding the maximum (HEAL). The last pulse and the expiry fall on the same
## tick: pulse first.
## [br][br]
## [b]Expiry[/b]: at [code]s ≥ until[/code] it is removed (STATUS 2). The movement slot is already emptied by the
## simulation on that same tick (its end is the same).
## [br][br]
## [b]Clearing[/b] ([method clear]): on death, on being knocked down and on respawn, all are removed without STATUS
## (DEATH, DOWNED and RESPAWN erase them on the client). When an entity is removed, its effects on others are removed
## with STATUS 2 ([method forget_author]).
## [br][br]
## It touches neither the network nor the clock: it reports with [signal event_emitted] (STATUS and HEAL) and
## [signal pulse_damage], which the [CombatDirector] forwards and applies.
## [br][br]
## [b]Cost.[/b] Each [Combatant] stores in [member Combatant.effects_due] the first tick at which something happens to it
## (a pulse or an expiry), and the system the lowest of all: [method step] walks nobody on a tick with no events and, on
## one with events, skips whoever has nothing. Each effect stores its [StatusTicks] so as not to look it up in the
## catalog.

## A STATUS or HEAL event and the net_ids involved (the affected one and the author).
signal event_emitted(event: NetMessages.EntityEvent, involved: PackedInt32Array)
## A damage-over-time pulse on [param target] from [param author_id] (0 = no author): [param amount] is
## [code]pulse_amount × stacks[/code], without modifiers. Applied by the [CombatDirector].
signal pulse_damage(target: Combatant, author_id: int, status: StatusTicks, amount: int, tick: int)

## Maximum active effects per entity.
const MAX_EFFECTS: int = 8

const _KIND_DOT: int = StatusEffectDefinition.Kind.DAMAGE_OVER_TIME
const _KIND_HOT: int = StatusEffectDefinition.Kind.HEAL_OVER_TIME
const _KIND_DAMAGE_UP: int = StatusEffectDefinition.Kind.DAMAGE_UP
const _KIND_MITIGATION_DOWN: int = StatusEffectDefinition.Kind.MITIGATION_DOWN

# First tick at which something may happen to any effect (the lowest effects_due; being lower than it should be only
# costs one extra walk, which recomputes it).
var _next_due: int = Combatant.NO_EFFECTS_DUE

## Counters for the run (for the server report).
var stats: Dictionary[StringName, int] = {
	&"status_applied": 0, &"status_removed": 0, &"pulses": 0, &"healed": 0,
}


## An active effect on a [Combatant].
class ActiveEffect:
	## Id of the [StatusTicks] in the catalog.
	var status_id: int = 0
	## net_id of whoever applied it (0 = no author: command 14). The last one to renew it (in STRONGEST, the one who set the
	## latest end).
	var source_id: int = 0
	## Tick from which pulses are counted (that of the first application).
	var anchor_tick: int = 0
	## Tick at which it ends (exclusive).
	var until_tick: int = 0
	var stacks: int = 1
	## Its data (they do not change while it lives).
	var status: StatusTicks = null


	## First tick after [param after] at which something happens to it: its next pulse or its expiry.
	func next_event_after(after: int) -> int:
		if status != null and status.has_pulses():
			var elapsed: int = maxi(after - anchor_tick, 0)
			@warning_ignore("integer_division")
			var pulse: int = anchor_tick + (elapsed / status.pulse_ticks + 1) * status.pulse_ticks
			if pulse <= until_tick:
				return pulse
		return maxi(until_tick, after + 1)


# A pulse gathered in step()'s first walk.
class _Pulse:
	var target: Combatant
	var status: StatusTicks
	var source_id: int = 0
	var stacks: int = 1


## Applies the catalog effect [param status_id] to [param target] at tick [param s], set by [param source_id] (0 = no
## author), for [param duration_ticks] ticks (0 = those of the data). Does nothing on a dead target, a knocked down one
## (docs/abilities.md, section 4.3) or with an effect that does not exist. Returns whether it was applied.
func apply(target: Combatant, status_id: int, source_id: int, s: int, duration_ticks: int = 0) -> bool:
	var status: StatusTicks = CombatCatalog.status(status_id)
	if status == null or target == null or not target.is_alive():
		return false
	var duration: int = duration_ticks if duration_ticks > 0 else status.duration_ticks
	if duration <= 0:
		return false
	var until: int = s + duration
	var effect: ActiveEffect = find(target, status_id)
	if effect == null:
		if target.effects.size() >= MAX_EFFECTS:
			_remove_at(target, _earliest_index(target), s, true)
		effect = ActiveEffect.new()
		effect.status_id = status_id
		effect.source_id = source_id
		effect.anchor_tick = s
		effect.until_tick = until
		effect.stacks = 1
		effect.status = status
		_insert_sorted(target, effect)
	else:
		match status.stacking:
			StatusEffectDefinition.Stacking.STACK:
				effect.stacks = mini(effect.stacks + 1, maxi(status.max_stacks, 1))
				effect.source_id = source_id
			StatusEffectDefinition.Stacking.STRONGEST:
				# The same effect is always equally strong (its data does not change): the latest end, and with it its author (the one
				# that sustains it; otherwise, the first one's removal would take away what another renewed: phase 4 review).
				if until > effect.until_tick:
					effect.source_id = source_id
			_:
				effect.source_id = source_id
		# The end never goes back (it only could with command 14's duration): so the movement slot, which also keeps the
		# latest, ends on the same tick as the effect.
		effect.until_tick = maxi(effect.until_tick, until)
	target.effects_due = mini(target.effects_due, effect.next_event_after(s))
	_next_due = mini(_next_due, target.effects_due)
	if status.is_movement():
		var character: PlayerCharacter = target.get_character()
		if character != null:
			ActionMachine.impose_move_effect(character.combat, status_id, effect.until_tick)
			CombatDirector.commit_state(character)
	stats[&"status_applied"] += 1
	_emit_status(target, s, effect, NetMessages.EntityEvent.StatusOp.APPLIED)
	return true


## Step 6 of tick [param s] (docs/abilities.md, section 4.1) over [param list] (by net_id): pulses and expiries.
func step(s: int, list: Array[Combatant]) -> void:
	if s < _next_due:
		return
	var due: Array[Combatant] = []
	for target: Combatant in list:
		if s >= target.effects_due:
			due.append(target)
	var pulses: Array[_Pulse] = []
	for target: Combatant in due:
		for effect: ActiveEffect in target.effects:
			var status: StatusTicks = effect.status
			if status == null or not status.has_pulses() or s > effect.until_tick:
				continue
			var elapsed: int = s - effect.anchor_tick
			if elapsed <= 0 or elapsed % status.pulse_ticks != 0:
				continue
			var pulse := _Pulse.new()
			pulse.target = target
			pulse.status = status
			pulse.source_id = effect.source_id
			pulse.stacks = effect.stacks
			pulses.append(pulse)
	for pulse: _Pulse in pulses:
		if not _takes_pulses(pulse.target):
			continue
		stats[&"pulses"] += 1
		var amount: int = pulse.status.pulse_amount * pulse.stacks
		if pulse.status.kind == _KIND_DOT:
			pulse_damage.emit(pulse.target, pulse.source_id, pulse.status, amount, s)
		elif pulse.status.kind == _KIND_HOT:
			heal(pulse.target, pulse.source_id, amount,
					CombatSource.make(CombatSource.Kind.STATUS, pulse.status.id), s)
	for target: Combatant in due:
		var index: int = 0
		var next_due: int = Combatant.NO_EFFECTS_DUE
		while index < target.effects.size():
			var effect: ActiveEffect = target.effects[index]
			if s >= effect.until_tick:
				# The movement slot was already emptied by this tick's simulation (it ends on the same one).
				_remove_at(target, index, s, true, false)
			else:
				next_due = mini(next_due, effect.next_event_after(s))
				index += 1
		target.effects_due = next_due
	_next_due = Combatant.NO_EFFECTS_DUE
	for target: Combatant in list:
		_next_due = mini(_next_due, target.effects_due)


## Heals [param amount] to [param target] without exceeding the maximum (on behalf of [param healer_id]; itself if it is
## its own net_id) with source [param source], and emits HEAL if it healed anything. Returns what was healed.
func heal(target: Combatant, healer_id: int, amount: int, source: int, s: int) -> int:
	if target == null or not target.is_alive():
		return 0
	var healed: int = target.restore_health(amount)
	if healed <= 0:
		return 0
	stats[&"healed"] += healed
	var healer: int = 0 if healer_id == target.get_id() else healer_id
	event_emitted.emit(NetMessages.EntityEvent.heal(target.get_id(), s, healer, healed, source),
			_involved(target.get_id(), healer))
	return healed


## Removes all effects from [param target] without events (on death, on being knocked down or on respawn: the client
## erases them with DEATH, DOWNED and RESPAWN) and empties its movement slots in [CombatState]. It does not pass the state
## through encode/decode: the caller does, having just imposed another action.
func clear(target: Combatant) -> void:
	if target == null or target.effects.is_empty():
		return
	var character: PlayerCharacter = target.get_character()
	for effect: ActiveEffect in target.effects:
		var status: StatusTicks = effect.status
		if character != null and status != null and status.is_movement():
			ActionMachine.remove_move_effect(character.combat, effect.status_id)
	stats[&"status_removed"] += target.effects.size()
	target.effects.clear()
	target.effects_due = Combatant.NO_EFFECTS_DUE


## When [param author_id] is removed at tick [param s]: removes with STATUS 2 the effects it applied to the others in
## [param list] (with their movement slots).
func forget_author(author_id: int, s: int, list: Array[Combatant]) -> void:
	if author_id <= 0:
		return
	for target: Combatant in list:
		if target.get_id() == author_id or target.effects.is_empty():
			continue
		var index: int = 0
		while index < target.effects.size():
			if target.effects[index].source_id == author_id:
				_remove_at(target, index, s, true)
			else:
				index += 1


## The effect [param status_id] of [param target], or null.
func find(target: Combatant, status_id: int) -> ActiveEffect:
	for effect: ActiveEffect in target.effects:
		if effect.status_id == status_id:
			return effect
	return null


## Damage multiplier of [param attacker]: [code]1 + Σ DAMAGE_UP[/code] (magnitude per stack).
func damage_scale(attacker: Combatant) -> float:
	if attacker == null or attacker.effects.is_empty():
		return 1.0
	return 1.0 + _sum_magnitude(attacker, _KIND_DAMAGE_UP)


## How much [param victim]'s block mitigation drops: [code]Σ MITIGATION_DOWN[/code] (in absolute value, per stack).
func mitigation_penalty(victim: Combatant) -> float:
	if victim == null or victim.effects.is_empty():
		return 0.0
	return _sum_magnitude(victim, _KIND_MITIGATION_DOWN)


# --- Internals ---------------------------------------------------------------------------------

# A pulse is not applied to whoever has already died or been knocked down in this tick (their effects were removed).
static func _takes_pulses(target: Combatant) -> bool:
	return target.is_alive()


func _sum_magnitude(combatant: Combatant, kind: int) -> float:
	var total: float = 0.0
	for effect: ActiveEffect in combatant.effects:
		var status: StatusTicks = effect.status
		if status != null and status.kind == kind:
			total += absf(status.magnitude) * float(effect.stacks)
	return total


# Removes effect [param index] from [param target]: with [param emit], STATUS 2; with [param clear_slot], also empties
# its movement slot (and passes the state through encode/decode).
func _remove_at(target: Combatant, index: int, s: int, emit: bool, clear_slot: bool = true) -> void:
	var effect: ActiveEffect = target.effects[index]
	target.effects.remove_at(index)
	stats[&"status_removed"] += 1
	if clear_slot:
		var status: StatusTicks = effect.status
		var character: PlayerCharacter = target.get_character()
		if status != null and status.is_movement() and character != null:
			ActionMachine.remove_move_effect(character.combat, effect.status_id)
			CombatDirector.commit_state(character)
	if emit:
		effect.until_tick = s
		_emit_status(target, s, effect, NetMessages.EntityEvent.StatusOp.REMOVED)


func _emit_status(target: Combatant, s: int, effect: ActiveEffect, operation: int) -> void:
	var stacks: int = effect.stacks if operation == NetMessages.EntityEvent.StatusOp.APPLIED else 0
	event_emitted.emit(NetMessages.EntityEvent.status(target.get_id(), s, effect.source_id, operation,
			effect.status_id, stacks, effect.until_tick), _involved(target.get_id(), effect.source_id))


static func _insert_sorted(target: Combatant, effect: ActiveEffect) -> void:
	var index: int = 0
	while index < target.effects.size() and target.effects[index].status_id < effect.status_id:
		index += 1
	target.effects.insert(index, effect)


# The one that ends soonest (tie: the lowest id).
static func _earliest_index(target: Combatant) -> int:
	var earliest: int = 0
	for index: int in range(1, target.effects.size()):
		if target.effects[index].until_tick < target.effects[earliest].until_tick:
			earliest = index
	return earliest


static func _involved(target_id: int, author_id: int) -> PackedInt32Array:
	var involved := PackedInt32Array([target_id])
	if author_id > 0 and author_id != target_id:
		involved.append(author_id)
	return involved
