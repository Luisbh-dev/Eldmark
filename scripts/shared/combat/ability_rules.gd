class_name AbilityRules
extends RefCounted
## Second half of the action machine (docs/abilities.md, sections 3.3 to 3.6): abilities,
## consumables, channels, weapon swap, revive and execute, knocked down and movement effects.
## [br][br]
## The machine is split into two files so it does not grow without bound (docs/abilities.md, section 8),
## but the entry point is still [method ActionMachine.step]: it is the only one that calls these functions,
## in its fixed order, and these use its internal helpers ([code]_to_none[/code],
## [code]_clear_link[/code], [code]_store_buffer[/code]...). Deterministic like the rest of the machine:
## no clock, no randomness and nothing read that does not travel in [PlayerState].
## [br][br]
## [b]Cooldowns.[/b] They are absolute ticks in [member CombatState.ability_ready] (indices 0-2, those of the
## active weapon; 3-5, those of the other one) and [member CombatState.consumable_ready_tick]. An ability
## without a channel sets its own at the commit (the first active tick); a channel, on the tick
## it ends, for whatever reason, if it got to commit ([method close_channel]). The bit
## [constant CombatState.FLAG2_NO_COOLDOWNS] (command 13) sets none and spends no charges.

## Result of trying to start an action: it cannot be done now (goes to the buffer), it started, or it is dropped
## (makes no sense: empty slot, no charges, no alternate weapon, advance while ROOTED...).
const RETRY: int = 0
const STARTED: int = 1
const DROPPED: int = 2

## Minimum length of the movement that breaks a channel with
## [member AbilityTicks.channel_breaks_on_move].
const CHANNEL_MOVE_BREAK: float = 0.1

const _NONE: int = CombatState.Action.NONE
const _LIGHT: int = CombatState.Action.LIGHT
const _HEAVY: int = CombatState.Action.HEAVY
const _CHARGE: int = CombatState.Action.CHARGE
const _BLOCK: int = CombatState.Action.BLOCK
const _DODGE: int = CombatState.Action.DODGE
const _ABILITY: int = CombatState.Action.ABILITY
const _SWAP: int = CombatState.Action.SWAP
const _DOWNED: int = CombatState.Action.DOWNED
const _REVIVE: int = CombatState.Action.REVIVE
const _EXECUTE: int = CombatState.Action.EXECUTE


# --- Queries ----------------------------------------------------------------------------------

## Button that holds [param ability]: ABILITY_1-3 according to its slot or CONSUMABLE_1-2 if it is a
## consumable (0 if it has none: no weapon carries it).
static func button_of(ability: AbilityTicks) -> int:
	if ability.is_consumable():
		return PlayerInput.CONSUMABLE_1 << ability.consumable_index
	if ability.slot >= 0:
		return PlayerInput.ABILITY_1 << ability.slot
	return 0


## Index into [member CombatState.ability_ready] of [param ability] in [param c]: its slot if it belongs to the
## active weapon, the slot + 3 if it belongs to the other one, and -1 if it belongs to neither (or is a
## consumable).
static func ready_index(c: CombatState, ability: AbilityTicks) -> int:
	if ability.slot < 0:
		return -1
	if ability.weapon_id == c.weapon_id:
		return ability.slot
	if ability.weapon_id == c.alt_weapon_id:
		return ability.slot + CombatState.ABILITY_SLOTS
	return -1


## true if command 13 has removed cooldowns and charge spending.
static func has_no_cooldowns(c: CombatState) -> bool:
	return (c.combat_flags2 & CombatState.FLAG2_NO_COOLDOWNS) != 0


## Phase of [param ability] [param relative] ticks after it started: 0 cast, 1 active or
## channel, 2 recovery (the PHASE_* constants of [ActionMachine]).
static func phase_of(ability: AbilityTicks, relative: int) -> int:
	if relative < ability.cast_ticks:
		return ActionMachine.PHASE_WINDUP
	if relative < ability.active_to():
		return ActionMachine.PHASE_ACTIVE
	return ActionMachine.PHASE_RECOVERY


## true if [param c] is in the channel of [param ability] and that channel blocks (the shield
## wall): from the end of the cast until its cap.
static func is_blocking_channel(c: CombatState, ability: AbilityTicks, tick: int) -> bool:
	if ability == null or c.action != _ABILITY or not ability.channel or not ability.blocks:
		return false
	var relative: int = tick - c.action_tick
	return relative >= ability.cast_ticks and relative < ability.active_to()


## true if any movement effect slot roots (scale 0).
static func is_rooted(c: CombatState, data: CombatTables) -> bool:
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		var id: int = c.move_effect_ids[i]
		if id == 0:
			continue
		var status: StatusTicks = data.status(id)
		if status != null and _roots(status):
			return true
	return false


## true if the current action of [param c] lets an ability or a consumable start at [param t]:
## NONE, BLOCK, CHARGE (cancels the charge without spending it), DODGE from its
## [member DodgeTicks.cancel_to_attack_from_ticks], LIGHT and HEAVY in their recovery and ABILITY in its
## recovery or from its [member AbilityTicks.cancel_to_attack_from_ticks].
static func action_allows_ability(c: CombatState, data: CombatTables, weapon: WeaponTicks,
		t: int) -> bool:
	match c.action:
		_NONE, _BLOCK, _CHARGE:
			return true
		_DODGE:
			return weapon != null and t >= c.action_tick + weapon.dodge.cancel_to_attack_from_ticks
		_LIGHT, _HEAVY:
			var attack: AttackTicks = data.attack(c.action_id)
			return attack == null or t >= c.action_tick + attack.active_to()
		_ABILITY:
			var current: AbilityTicks = data.ability(c.action_id)
			return current == null or t - c.action_tick >= mini(current.active_to(),
					current.cancel_to_attack_from_ticks)
	return false


## State of the action bar slot [param slot] at [param tick] ([enum ActionMachine.AbilityStatus]):
## slots 0-2 are the active weapon's abilities and
## [constant ActionMachine.STATUS_SLOT_CONSUMABLE_1] and [constant ActionMachine.STATUS_SLOT_CONSUMABLE_2]
## the consumables. In order: EMPTY (nothing there), NO_CHARGES, COOLDOWN, BLOCKED (the current action
## does not let it start, an advance with ROOT or the wall exhausted) and READY. It does not look at the ground
## (it does not travel in [CombatState]).
static func status_of(c: CombatState, slot: int, tick: int) -> int:
	var data: CombatTables = CombatCatalog.tables()
	var ability: AbilityTicks = null
	var ready_tick: int = 0
	if slot >= 0 and slot < CombatState.ABILITY_SLOTS:
		var weapon: WeaponTicks = data.weapon(c.weapon_id)
		if weapon != null and weapon.ability_id(slot) != 0:
			ability = data.ability(weapon.ability_id(slot))
		ready_tick = c.ability_ready[slot]
	elif slot == ActionMachine.STATUS_SLOT_CONSUMABLE_1 \
			or slot == ActionMachine.STATUS_SLOT_CONSUMABLE_2:
		var index: int = slot - ActionMachine.STATUS_SLOT_CONSUMABLE_1
		if data.consumable_ids[index] != 0:
			ability = data.ability(data.consumable_ids[index])
		if ability != null and c.charges_of(index) <= 0:
			return ActionMachine.AbilityStatus.NO_CHARGES
		ready_tick = c.consumable_ready_tick
	if ability == null:
		return ActionMachine.AbilityStatus.EMPTY
	if tick < ready_tick and not has_no_cooldowns(c):
		return ActionMachine.AbilityStatus.COOLDOWN
	var weapon_now: WeaponTicks = data.weapon(c.weapon_id)
	if not action_allows_ability(c, data, weapon_now, tick) \
			or (ability.dash_distance_m > 0.0 and is_rooted(c, data)) \
			or (ability.blocks and ActionMachine._is_blocked_by_exhaustion(c)):
		return ActionMachine.AbilityStatus.BLOCKED
	return ActionMachine.AbilityStatus.READY


# --- Step 1: end of actions -------------------------------------------------------------------

## Rule 1 for ABILITY: it ends at [code]t >= action_tick + total[/code]; a channel, on reaching
## its cap ([code]action_tick + cast + active[/code]) and with its cooldown.
static func finish_ability(c: CombatState, data: CombatTables, t: int) -> void:
	var ability: AbilityTicks = data.ability(c.action_id)
	if ability == null:
		ActionMachine._to_none(c)
	elif ability.channel:
		if t >= c.action_tick + ability.active_to():
			close_channel(c, data, t, false)
			ActionMachine._to_none(c)
	elif t >= c.action_tick + ability.total_ticks:
		ActionMachine._to_none(c)


## When an ABILITY of [param c] is interrupted at [param tick] ([method ActionMachine.impose_interrupt]): the
## cooldown of its slot (or the shared one, if it is a consumable) becomes at least
## [code]tick + REARM_TICKS[/code] ([constant AbilityTicks.REARM_TICKS]). Without this, when cut off before the
## commit, another consumable (or the same slot) could start at [code]tick + 1[/code] with the same action
## byte, and a remote that does not sample that single NONE tick kept following the first one's clip. After the
## commit the cooldown is already larger and does not change.
static func rearm_after_interrupt(c: CombatState, tick: int) -> void:
	if c.action != _ABILITY:
		return
	var ability: AbilityTicks = CombatCatalog.tables().ability(c.action_id)
	if ability == null:
		return
	_rearm(c, ability, tick)


# The margin of [method rearm_after_interrupt] for [param ability] (the one of [param c]) from [param tick].
static func _rearm(c: CombatState, ability: AbilityTicks, tick: int) -> void:
	var ready: int = tick + AbilityTicks.REARM_TICKS
	if ability.is_consumable():
		c.consumable_ready_tick = maxi(c.consumable_ready_tick, ready)
		return
	var index: int = ready_index(c, ability)
	if index >= 0:
		c.ability_ready[index] = maxi(c.ability_ready[index], ready)


## If [param c] is in a committed channel, sets its cooldown to
## [code]tick + cooldown[/code] (rule 5): everything that ends or cuts it calls this, right before
## changing the action. [param after_step] is true if whoever cuts it does so after simulating
## [param tick] (the server when imposing another action: that tick's commit has already happened) and false
## if it is the machine itself, within the tick and before the commit: releasing or dodging on the same tick
## as the commit cancels it with no cooldown (releasing it leaves the margin of
## [constant AbilityTicks.REARM_TICKS]: [method end_by_input]).
static func close_channel(c: CombatState, data: CombatTables, tick: int, after_step: bool) -> void:
	if c.action != _ABILITY:
		return
	var ability: AbilityTicks = data.ability(c.action_id)
	if ability == null or not ability.channel:
		return
	var elapsed: int = tick - c.action_tick
	var committed: bool = elapsed >= ability.cast_ticks if after_step \
			else elapsed > ability.cast_ticks
	if not committed or has_no_cooldowns(c):
		return
	var index: int = ready_index(c, ability)
	if index >= 0:
		c.ability_ready[index] = tick + ability.cooldown_ticks


# --- Step 2: movement effects -----------------------------------------------------------------

## Rule 2: empties the movement effect slots that end at [param t] or earlier.
static func expire_move_effects(c: CombatState, t: int) -> void:
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		if c.move_effect_ids[i] != 0 and c.move_effect_until[i] <= t:
			c.move_effect_ids[i] = 0
			c.move_effect_until[i] = 0


# --- Step 4: inputs ---------------------------------------------------------------------------

## Rule 4a with a real input: a channel with [member AbilityTicks.channel_hold] ends if its
## button is not down and one with [member AbilityTicks.channel_breaks_on_move], if there is movement (only
## from the end of the cast); REVIVE and EXECUTE end without INTERACT. All go back to NONE. A
## channel that ends this way without committing (at the end of the cast) has no cooldown, but leaves
## the margin of [constant AbilityTicks.REARM_TICKS] in its slot, like an interruption: without it, another
## press on the next tick came out with the same action byte after a single NONE tick (phase 4
## review).
static func end_by_input(c: CombatState, input: PlayerInput, data: CombatTables, down: int) -> void:
	match c.action:
		_ABILITY:
			var ability: AbilityTicks = data.ability(c.action_id)
			if ability == null or not ability.channel \
					or input.tick - c.action_tick < ability.cast_ticks:
				return
			var released: bool = ability.channel_hold and (down & button_of(ability)) == 0
			var moved: bool = ability.channel_breaks_on_move \
					and input.move.length() >= CHANNEL_MOVE_BREAK
			if released or moved:
				if input.tick - c.action_tick <= ability.cast_ticks:
					_rearm(c, ability, input.tick)
				close_channel(c, data, input.tick, false)
				ActionMachine._to_none(c)
		_REVIVE, _EXECUTE:
			if (down & PlayerInput.INTERACT) == 0:
				ActionMachine._to_none(c)


## ABILITY_n (edge or buffer, [param from_buffer]): tries to start the ability in slot
## [param slot] of the active weapon. Returns [constant RETRY], [constant STARTED] or
## [constant DROPPED].
static func try_ability(c: CombatState, input: PlayerInput, data: CombatTables,
		weapon: WeaponTicks, grounded: bool, slot: int, down: int, from_buffer: bool) -> int:
	var id: int = weapon.ability_id(slot)
	if id == 0:
		return DROPPED
	var ability: AbilityTicks = data.ability(id)
	if ability == null:
		return DROPPED
	return _try_start(c, input, data, weapon, grounded, ability, c.ability_ready[slot], down,
			from_buffer)


## CONSUMABLE_n (edge or buffer): tries to start consumable [param index] (0 or 1) of the rules.
## With no charges, or no consumable, it is dropped.
static func try_consumable(c: CombatState, input: PlayerInput, data: CombatTables,
		weapon: WeaponTicks, grounded: bool, index: int, down: int, from_buffer: bool) -> int:
	var id: int = data.consumable_ids[index]
	if id == 0 or c.charges_of(index) <= 0:
		return DROPPED
	var ability: AbilityTicks = data.ability(id)
	if ability == null:
		return DROPPED
	return _try_start(c, input, data, weapon, grounded, ability, c.consumable_ready_tick, down,
			from_buffer)


## SWAP (edge or buffer): with no weapon in the other slot it is dropped; from NONE, BLOCK, the recovery
## of LIGHT, HEAVY or ABILITY and DODGE from its [member DodgeTicks.cancel_to_attack_from_ticks],
## also in the air, it swaps the weapons and the two halves of the cooldowns on the first
## tick. Never in the middle of windup, active hit, charge, cast or channel: there, it goes to the buffer.
static func try_swap(c: CombatState, data: CombatTables, weapon: WeaponTicks, t: int) -> int:
	if c.alt_weapon_id == 0:
		return DROPPED
	var allowed: bool = false
	match c.action:
		_NONE, _BLOCK:
			allowed = true
		_LIGHT, _HEAVY:
			var attack: AttackTicks = data.attack(c.action_id)
			allowed = attack == null or t >= c.action_tick + attack.active_to()
		_ABILITY:
			var current: AbilityTicks = data.ability(c.action_id)
			allowed = current == null or t >= c.action_tick + current.active_to()
		_DODGE:
			allowed = weapon != null and t >= c.action_tick + weapon.dodge.cancel_to_attack_from_ticks
	if not allowed:
		return RETRY
	close_channel(c, data, t, false)
	ActionMachine._clear_link(c)
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
	c.action = _SWAP
	c.action_id = 0
	c.action_tick = t
	c.combo_step = 0
	c.charge_ticks = 0
	var active: int = c.weapon_id
	c.weapon_id = c.alt_weapon_id
	c.alt_weapon_id = active
	for i: int in CombatState.ABILITY_SLOTS:
		var ready: int = c.ability_ready[i]
		c.ability_ready[i] = c.ability_ready[i + CombatState.ABILITY_SLOTS]
		c.ability_ready[i + CombatState.ABILITY_SLOTS] = ready
	c.combat_flags2 ^= CombatState.FLAG2_SECOND_SLOT
	return STARTED


# What abilities and consumables have in common: drops, cooldown, current action and ground.
static func _try_start(c: CombatState, input: PlayerInput, data: CombatTables, weapon: WeaponTicks,
		grounded: bool, ability: AbilityTicks, ready_tick: int, down: int, from_buffer: bool) -> int:
	var t: int = input.tick
	if ability.dash_distance_m > 0.0 and is_rooted(c, data):
		return DROPPED
	if ability.blocks and ActionMachine._is_blocked_by_exhaustion(c):
		# Exhaustion prevents the wall, like BLOCK (docs/abilities.md, section 2.4).
		c.combat_flags |= CombatState.FLAG_NO_STAMINA
		return DROPPED
	if from_buffer and ability.channel and ability.channel_hold \
			and (down & button_of(ability)) == 0:
		# A channel that is held does not come out of the buffer with its button already released.
		return DROPPED
	if t < ready_tick and not has_no_cooldowns(c):
		return RETRY
	if not action_allows_ability(c, data, weapon, t):
		return RETRY
	if not grounded and not ability.usable_in_air:
		return RETRY
	close_channel(c, data, t, false)
	ActionMachine._clear_link(c)
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
	c.action = _ABILITY
	c.action_id = ability.id
	c.action_tick = t
	c.action_dir = CombatState.quantize_yaw(_dash_yaw(ability, input))
	c.combo_step = 0
	c.charge_ticks = 0
	return STARTED


# World yaw of the advance according to [member AbilityTicks.dash_direction]: toward the camera, backward or
# following the movement (like the dodge).
static func _dash_yaw(ability: AbilityTicks, input: PlayerInput) -> float:
	match ability.dash_direction:
		1:
			return input.look_yaw + PI
		2:
			return ActionMachine._dodge_yaw(input)
	return input.look_yaw


# --- Step 5: commit ---------------------------------------------------------------------------

## Rule 5: on the first active tick ([code]t == action_tick + cast[/code]) of an ABILITY, a
## consumable spends a charge and sets the shared cooldown; an ability without a channel sets
## its own (the channel, when it ends); both restore [member AbilityTicks.stamina_restore] of
## stamina without exceeding the maximum.
static func commit(c: CombatState, data: CombatTables, t: int) -> void:
	if c.action != _ABILITY:
		return
	var ability: AbilityTicks = data.ability(c.action_id)
	if ability == null or t != c.action_tick + ability.cast_ticks:
		return
	if not has_no_cooldowns(c):
		if ability.is_consumable():
			var index: int = ability.consumable_index
			var left: int = maxi(c.charges_of(index) - 1, 0)
			var mask: int = CombatState.MAX_CHARGES << (4 * index)
			c.consumable_charges = (c.consumable_charges & ~mask) | (left << (4 * index))
			c.consumable_ready_tick = t + data.consumable_cooldown_ticks
		elif not ability.channel:
			var slot_index: int = ready_index(c, ability)
			if slot_index >= 0:
				c.ability_ready[slot_index] = t + ability.cooldown_ticks
	if ability.stamina_restore > 0:
		var rules: CombatRules = data.rules
		c.stamina = mini(c.stamina + ability.stamina_restore, rules.stamina_max)
		if c.is_exhausted() and c.stamina > rules.exhausted_exit_threshold:
			c.combat_flags &= ~CombatState.FLAG_EXHAUSTED


# --- Step 6: movement -------------------------------------------------------------------------

## Rule 6 (docs/abilities.md, section 3.4) for ABILITY, SWAP, DOWNED, REVIVE and EXECUTE.
static func fill_output(c: CombatState, out: ActionMachine.Output, data: CombatTables,
		t: int) -> void:
	match c.action:
		_ABILITY:
			var ability: AbilityTicks = data.ability(c.action_id)
			if ability == null:
				return
			_restrict(out, ability.move_speed_scale)
			var relative: int = t - c.action_tick
			if relative == 0:
				out.snap_yaw = true
			if ability.is_dashing(relative):
				# Forced advance, like the dodge: no acceleration and no turning.
				var heading: float = CombatState.dequantize_yaw(c.action_dir)
				var speed: float = ability.dash_speed_at(relative)
				out.forced_velocity = true
				out.velocity = Vector3(-sin(heading) * speed, 0.0, -cos(heading) * speed)
				out.move_scale = 0.0
				out.turn_rate = 0.0
			elif relative < ability.active_to():
				out.turn_rate = ability.turn_rate
				if not ability.channel or relative < ability.cast_ticks:
					out.lunge_speed = ability.lunge_speed
			else:
				out.turn_rate = 0.0
		_SWAP:
			_restrict(out, data.rules.swap_move_scale)
			out.turn_rate = -1.0
		_DOWNED:
			_restrict(out, data.rules.downed_move_scale)
			out.turn_rate = data.rules.downed_turn_rate
		_REVIVE, _EXECUTE:
			_restrict(out, 0.0)
			out.turn_rate = 0.0


## Movement effects: [member ActionMachine.Output.speed_factor] = (the smallest scale < 1 of the
## slots, or 1) × (the largest > 1, or 1), which [method PlayerCharacter.simulate] applies to the
## non-forced target speed; ROOT (scale 0) also sets [member ActionMachine.Output.rooted]: no jump and,
## in the air, it brakes.
static func apply_move_effects(c: CombatState, out: ActionMachine.Output, data: CombatTables) -> void:
	if c.move_effect_ids[0] == 0 and c.move_effect_ids[1] == 0:
		return
	var slowest: float = 1.0
	var fastest: float = 1.0
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		var id: int = c.move_effect_ids[i]
		if id == 0:
			continue
		var status: StatusTicks = data.status(id)
		if status == null:
			continue
		slowest = minf(slowest, status.move_speed_scale)
		fastest = maxf(fastest, status.move_speed_scale)
		if _roots(status):
			out.rooted = true
	out.speed_factor = maxf(slowest, 0.0) * fastest
	if out.rooted:
		out.allow_jump = false


static func _restrict(out: ActionMachine.Output, move_scale: float) -> void:
	out.scaled_movement = true
	out.move_scale = move_scale
	out.allow_jump = false
	out.allow_sprint = false


static func _roots(status: StatusTicks) -> bool:
	return status.kind == StatusEffectDefinition.Kind.ROOT or status.move_speed_scale <= 0.0
