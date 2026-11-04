class_name ActionMachine
extends RefCounted
## Combat action machine (docs/combate.md, section 3, and docs/habilidades.md, section 3):
## chained light attacks, charged heavy attack, block with parry, dodge, stamina,
## abilities, consumables, weapon swap, movement effects and what the server imposes
## (controls, death, knocked down, revive and execute). It is a deterministic function of
## ([CombatState], [PlayerInput], ground): no clock, no randomness and nothing read that does not travel in
## [PlayerState].
## [br][br]
## [method step] is called by [method PlayerCharacter.simulate] at the start of each tick, before
## movement, and returns in an [ActionMachine.Output] how the character must move that tick.
## The remaining static functions are queries (used by the server, the animator and the action
## bar) and the orders imposed by the server ([method impose_stagger]...).
## [br][br]
## [b]Order of each tick[/b] (with [code]t = input.tick[/code]; docs/habilidades.md, section 3.3): 0)
## fast path; 1) actions that end; 2) movement effects that expire; 3) stamina
## regeneration; 4) inputs: 4a ends by input (channel, revive and execute), 4b the buffer and 4c
## the new edges with priority DODGE > ABILITY_1 > ABILITY_2 > ABILITY_3 > CONSUMABLE_1 >
## CONSUMABLE_2 > PRIMARY > SWAP > BLOCK; 5) the commit of an ability or a consumable; 6) the
## [ActionMachine.Output]. Abilities, consumables, weapon swap, channels and movement effects
## live in [AbilityRules] (the machine split into two files); this one is still the
## entry point.
## [br][br]
## [b]Edges.[/b] They are derived from the bits [constant CombatState.FLAG_DODGE_HELD] and companions of
## [member CombatState.combat_flags] and from bits 1-6 of [member CombatState.combat_flags2] (the level
## of each button on the previous tick), so the signature of [method step] does not need
## [member PlayerCharacter.prev_buttons]. A substituted input ([constant PlayerInput.SUBSTITUTED])
## repeats the buttons and therefore creates no edges; furthermore it does not add to [member CombatState.primary_held],
## does not turn a light attack into a charge, does not fire the heavy attack on reaching maximum charge (the charge freezes
## for up to [member CombatRules.input_buffer_ticks] more ticks; if the silence continues, it is canceled), does not open
## parry windows, does not cut a channel for moving and does not release what is held (a
## channel, revive or execute). No loss invents an ability, a weapon swap or a
## potion.
## [br][br]
## [b]Buffer.[/b] One slot ([member CombatState.buffered]: type and ticks remaining): an edge that
## cannot be executed now takes it (the last press wins) and is executed on the first tick on which it
## can be, within [member CombatRules.input_buffer_ticks]; an edge that makes no sense (empty
## slot, no charges, no alternate weapon, [member WeaponTicks.can_block] false, advance with ROOT) is
## dropped.
## [br][br]
## [b]History.[/b] [method defense_flags] gives bits 3-7 of [StateHistory]; the byte the
## server records is [code](record flags & 0b111) | defense_flags[/code]
## ([constant EntityRecord.HISTORY_FLAGS_MASK]; masked by [code]ZoneServer._record_history[/code] and
## [method Combatant.freeze]): bit 3 of the network record (slot 2 active, docs/habilidades.md,
## section 5.2) never gets in, because in the history bit 3 is [constant DEFENSE_BLOCKING].

## How the character must move this tick (applied by [method PlayerCharacter.simulate]).
class Output:
	## Fraction of the run speed allowed ([code]wish * run_speed * move_scale[/code]).
	var move_scale: float = 1.0
	## Forward speed (m/s) added to the run speed.
	var lunge_speed: float = 0.0
	## Turn toward the camera (rad/s) even if the character is standing still; 0 = does not turn; -1 = the normal
	## turn of simulate() (only when moving).
	var turn_rate: float = -1.0
	## The yaw snaps to look_yaw this tick.
	var snap_yaw: bool = false
	## The horizontal speed is [member velocity] and is forced with no acceleration.
	var forced_velocity: bool = false
	var velocity: Vector3 = Vector3.ZERO
	var allow_jump: bool = true
	var allow_sprint: bool = true
	## true in every action except NONE: the target speed is
	## [code]wish * run_speed * move_scale[/code], without the multipliers for moving backward or
	## sideways nor sprint.
	var scaled_movement: bool = false
	## Movement effects (docs/habilidades.md, section 3.4): multiplies the non-forced target speed
	## in all actions (NONE and sprint included); the dodge, an ability's advance and the
	## knockback are not affected.
	var speed_factor: float = 1.0
	## Rooted (ROOT): no jump and, in the air, it brakes as with [code]move_scale[/code] 0.
	var rooted: bool = false


## State of an action bar slot ([method ability_status]).
enum AbilityStatus { READY, COOLDOWN, BLOCKED, EMPTY, NO_CHARGES }

## Phases of an attack or an ability ([method phase]).
const PHASE_WINDUP: int = 0
const PHASE_ACTIVE: int = 1
const PHASE_RECOVERY: int = 2
const PHASE_NONE: int = 3

## Bits of [method defense_flags] (they follow those of [StateHistory]: bit 0 ground, bits 1-2
## teleport).
const DEFENSE_BLOCKING: int = 1 << 3
const DEFENSE_PARRY: int = 1 << 4
const DEFENSE_INVULNERABLE: int = 1 << 5
const DEFENSE_DEAD: int = 1 << 6
## Wide block: the blocking channel (the shield wall) gives it together with
## [constant DEFENSE_BLOCKING]; the server then uses the cone and cost from the rules
## ([member CombatRules.ability_block_angle_deg]) instead of the weapon's.
const DEFENSE_WIDE_BLOCK: int = 1 << 7

## Slots of [method ability_status] for the two consumables (0-2 are the active weapon's
## abilities).
const STATUS_SLOT_CONSUMABLE_1: int = 3
const STATUS_SLOT_CONSUMABLE_2: int = 4

const _NONE: int = CombatState.Action.NONE
const _LIGHT: int = CombatState.Action.LIGHT
const _HEAVY: int = CombatState.Action.HEAVY
const _CHARGE: int = CombatState.Action.CHARGE
const _BLOCK: int = CombatState.Action.BLOCK
const _DODGE: int = CombatState.Action.DODGE
const _STAGGER: int = CombatState.Action.STAGGER
const _STUN: int = CombatState.Action.STUN
const _DEAD: int = CombatState.Action.DEAD
const _ABILITY: int = CombatState.Action.ABILITY
const _SWAP: int = CombatState.Action.SWAP
const _DOWNED: int = CombatState.Action.DOWNED
const _REVIVE: int = CombatState.Action.REVIVE
const _EXECUTE: int = CombatState.Action.EXECUTE

## Below this length the movement gives the dodge no direction (it dodges backward).
const _DODGE_MIN_MOVE: float = 0.1
## Buttons that take it off the fast path: the combat ones. AIM_LEFT (a level that only reads aiming),
## INTERACT (handled by the server), jump and sprint do not.
const _COMBAT_BUTTONS: int = (
	PlayerInput.DODGE | PlayerInput.PRIMARY | PlayerInput.BLOCK | PlayerInput.ABILITY_1
	| PlayerInput.ABILITY_2 | PlayerInput.ABILITY_3 | PlayerInput.SWAP_WEAPON
	| PlayerInput.CONSUMABLE_1 | PlayerInput.CONSUMABLE_2
)
const _HELD_FLAGS: int = (
	CombatState.FLAG_DODGE_HELD | CombatState.FLAG_BLOCK_HELD | CombatState.FLAG_PRIMARY_HELD
)

# Result of trying a dodge: it cannot be done now (goes to the buffer), it started, or it is dropped for
# lack of stamina (or for being rooted). The same values as AbilityRules.RETRY, STARTED and
# DROPPED.
const _DODGE_RETRY: int = 0
const _DODGE_STARTED: int = 1
const _DODGE_DROPPED: int = 2


## Advances the machine one tick with [param input] and returns how the character moves.
## [param grounded] is whether it was on the ground at the start of the tick.
static func step(c: CombatState, input: PlayerInput, grounded: bool) -> ActionMachine.Output:
	var out := Output.new()
	var data: CombatTables = CombatCatalog.tables()
	var t: int = input.tick

	# Button levels and edges (the SUBSTITUTED bit is not a button).
	var down: int = input.buttons & ~PlayerInput.SUBSTITUTED
	var previous: int = c.combat_flags
	var previous2: int = c.combat_flags2

	# Fast path, the one for almost every tick: no action, no combat buttons (neither pressed
	# nor just released), nothing pending and no movement effects. Only the
	# stamina can change when regenerating. It does not look up the weapon nor walk the ability slots.
	if c.action == _NONE and c.buffered == 0 and c.primary_held == 0 \
			and (down & _COMBAT_BUTTONS) == 0 \
			and (previous & (_HELD_FLAGS | CombatState.FLAG_NO_STAMINA)) == 0 \
			and (previous2 & CombatState.FLAG2_HELD_MASK) == 0 \
			and c.move_effect_ids[0] == 0 and c.move_effect_ids[1] == 0:
		if c.stamina < data.rules.stamina_max or (previous & CombatState.FLAG_EXHAUSTED) != 0:
			_regenerate(c, data, t)
		return out

	var weapon: WeaponTicks = data.weapon(c.weapon_id)
	var edges: int = 0
	var held_flags: int = 0
	if (down & PlayerInput.DODGE) != 0:
		held_flags |= CombatState.FLAG_DODGE_HELD
		if (previous & CombatState.FLAG_DODGE_HELD) == 0:
			edges |= PlayerInput.DODGE
	if (down & PlayerInput.PRIMARY) != 0:
		held_flags |= CombatState.FLAG_PRIMARY_HELD
		if (previous & CombatState.FLAG_PRIMARY_HELD) == 0:
			edges |= PlayerInput.PRIMARY
	if (down & PlayerInput.BLOCK) != 0:
		held_flags |= CombatState.FLAG_BLOCK_HELD
		if (previous & CombatState.FLAG_BLOCK_HELD) == 0:
			edges |= PlayerInput.BLOCK
	c.combat_flags = (previous & ~(_HELD_FLAGS | CombatState.FLAG_NO_STAMINA)) | held_flags
	var held2: int = 0
	held2 |= _level(down, PlayerInput.ABILITY_1, CombatState.FLAG2_ABILITY_1_HELD)
	held2 |= _level(down, PlayerInput.ABILITY_2, CombatState.FLAG2_ABILITY_2_HELD)
	held2 |= _level(down, PlayerInput.ABILITY_3, CombatState.FLAG2_ABILITY_3_HELD)
	held2 |= _level(down, PlayerInput.SWAP_WEAPON, CombatState.FLAG2_SWAP_HELD)
	held2 |= _level(down, PlayerInput.CONSUMABLE_1, CombatState.FLAG2_CONSUMABLE_1_HELD)
	held2 |= _level(down, PlayerInput.CONSUMABLE_2, CombatState.FLAG2_CONSUMABLE_2_HELD)
	edges |= _edge(held2, previous2, CombatState.FLAG2_ABILITY_1_HELD, PlayerInput.ABILITY_1)
	edges |= _edge(held2, previous2, CombatState.FLAG2_ABILITY_2_HELD, PlayerInput.ABILITY_2)
	edges |= _edge(held2, previous2, CombatState.FLAG2_ABILITY_3_HELD, PlayerInput.ABILITY_3)
	edges |= _edge(held2, previous2, CombatState.FLAG2_SWAP_HELD, PlayerInput.SWAP_WEAPON)
	edges |= _edge(held2, previous2, CombatState.FLAG2_CONSUMABLE_1_HELD, PlayerInput.CONSUMABLE_1)
	edges |= _edge(held2, previous2, CombatState.FLAG2_CONSUMABLE_2_HELD, PlayerInput.CONSUMABLE_2)
	c.combat_flags2 = (previous2 & ~CombatState.FLAG2_HELD_MASK) | held2

	_finish_expired(c, data, weapon, t)
	AbilityRules.expire_move_effects(c, t)
	_regenerate(c, data, t)
	if weapon != null:
		_run_inputs(c, out, input, data, weapon, grounded, down, edges)
	else:
		c.buffered = 0
		c.primary_held = 0
	AbilityRules.commit(c, data, t)
	if weapon != null and c.weapon_id != weapon.id:
		weapon = data.weapon(c.weapon_id)
	_fill_output(c, out, data, weapon, t)
	AbilityRules.apply_move_effects(c, out, data)
	return out


# --- Queries ----------------------------------------------------------------------------------

## Phase of the action at [param tick]: [constant PHASE_WINDUP] (windup, charge or cast),
## [constant PHASE_ACTIVE] (active hit, or the active phase or channel of an ability),
## [constant PHASE_RECOVERY] or [constant PHASE_NONE] (the action has no phases: also SWAP, DOWNED,
## REVIVE and EXECUTE).
static func phase(c: CombatState, tick: int) -> int:
	if c.action == _CHARGE:
		return PHASE_WINDUP
	if c.action == _ABILITY:
		var ability: AbilityTicks = CombatCatalog.ability(c.action_id)
		if ability == null:
			return PHASE_NONE
		return AbilityRules.phase_of(ability, tick - c.action_tick)
	if c.action != _LIGHT and c.action != _HEAVY:
		return PHASE_NONE
	var attack: AttackTicks = CombatCatalog.attack(c.action_id)
	if attack == null:
		return PHASE_NONE
	var relative: int = tick - c.action_tick
	if relative < attack.windup_ticks:
		return PHASE_WINDUP
	if relative < attack.active_to():
		return PHASE_ACTIVE
	return PHASE_RECOVERY


## true if an attack is in its active hit at [param tick] (only LIGHT and HEAVY; an
## ability's hit is given by [method active_hit]).
static func is_attack_active(c: CombatState, tick: int) -> bool:
	if c.action != _LIGHT and c.action != _HEAVY:
		return false
	return phase(c, tick) == PHASE_ACTIVE


## The hit that [param c] has active at [param tick]: the attack in its active hit or the
## synthesized hit ([member AbilityTicks.hit]) of the ability in its active phase or channel; null if there
## is none. With no shape ([member AttackTicks.shape] null) the hit tests nobody.
static func active_hit(c: CombatState, tick: int) -> AttackTicks:
	match c.action:
		_LIGHT, _HEAVY:
			var attack: AttackTicks = CombatCatalog.attack(c.action_id)
			if attack == null:
				return null
			var relative: int = tick - c.action_tick
			if relative >= attack.active_from() and relative < attack.active_to():
				return attack
		_ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(c.action_id)
			if ability == null:
				return null
			var relative_ability: int = tick - c.action_tick
			if relative_ability >= ability.active_from() and relative_ability < ability.active_to():
				return ability.hit
	return null


## true if [param tick] is the commit of the action: the first active tick of a LIGHT, a HEAVY or
## an ABILITY (when projectiles are released and cooldowns and charges are set).
static func is_commit_tick(c: CombatState, tick: int) -> bool:
	match c.action:
		_LIGHT, _HEAVY:
			var attack: AttackTicks = CombatCatalog.attack(c.action_id)
			return attack != null and tick - c.action_tick == attack.windup_ticks
		_ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(c.action_id)
			return ability != null and tick - c.action_tick == ability.cast_ticks
	return false


## State of action bar slot [param slot] at [param tick]: 0-2 the active
## weapon's abilities, [constant STATUS_SLOT_CONSUMABLE_1] and [constant STATUS_SLOT_CONSUMABLE_2] the
## consumables. Returns an [enum AbilityStatus] (see [method AbilityRules.status_of]).
static func ability_status(c: CombatState, slot: int, tick: int) -> int:
	return AbilityRules.status_of(c, slot, tick)


## true if the character is blocking (including the parry window and the blocking channel,
## the shield wall).
static func is_blocking(c: CombatState, tick: int) -> bool:
	if c.action == _ABILITY:
		return AbilityRules.is_blocking_channel(c, CombatCatalog.ability(c.action_id), tick)
	return c.action == _BLOCK


## true if [param tick] falls within the parry window opened when the block starts.
static func is_parry_window(c: CombatState, tick: int) -> bool:
	if c.action != _BLOCK:
		return false
	var rules: CombatRules = CombatCatalog.rules()
	var opened_at: int = c.parry_ready_tick - rules.parry_cooldown_ticks
	if c.action_tick != opened_at:
		return false
	var elapsed: int = tick - opened_at
	return elapsed >= 0 and elapsed < rules.parry_window_ticks


## true if [param tick] falls within the dodge's invulnerability ticks.
static func is_invulnerable(c: CombatState, tick: int) -> bool:
	if c.action != _DODGE:
		return false
	var weapon: WeaponTicks = CombatCatalog.weapon(c.weapon_id)
	if weapon == null:
		return false
	var relative: int = tick - c.action_tick
	return relative >= weapon.dodge.invulnerable_from_ticks \
			and relative < weapon.dodge.invulnerable_to_ticks


## Defensive flags of [param tick] for [StateHistory]: [constant DEFENSE_BLOCKING],
## [constant DEFENSE_PARRY], [constant DEFENSE_INVULNERABLE], [constant DEFENSE_DEAD] and
## [constant DEFENSE_WIDE_BLOCK] (with BLOCKING, in the blocking channel). A knocked down character has
## no defense.
static func defense_flags(c: CombatState, tick: int) -> int:
	var flags: int = 0
	if c.action == _BLOCK:
		flags |= DEFENSE_BLOCKING
		if is_parry_window(c, tick):
			flags |= DEFENSE_PARRY
	elif c.action == _DODGE:
		if is_invulnerable(c, tick):
			flags |= DEFENSE_INVULNERABLE
	elif c.action == _DEAD:
		flags |= DEFENSE_DEAD
	elif c.action == _ABILITY:
		if AbilityRules.is_blocking_channel(c, CombatCatalog.ability(c.action_id), tick):
			flags |= DEFENSE_BLOCKING | DEFENSE_WIDE_BLOCK
	return flags


## Action byte of the network record (docs/habilidades.md, section 5.5): bits 0-3 the action, 4-5
## the phase ([method phase]) and 6-7 the step of the light combo in progress or, in an ABILITY, its slot
## (0-2; 3 = a consumable). In the other actions, 0 ([ActionWire] puts the restart counter there
## for those that carry one).
static func action_byte(c: CombatState, tick: int) -> int:
	var step_bits: int = 0
	if c.action == _LIGHT:
		var weapon: WeaponTicks = CombatCatalog.weapon(c.weapon_id)
		if weapon != null:
			step_bits = clampi(weapon.light_index(c.action_id), 0, 2)
	elif c.action == _ABILITY:
		var ability: AbilityTicks = CombatCatalog.ability(c.action_id)
		if ability != null:
			step_bits = 3 if ability.is_consumable() else clampi(ability.slot, 0, 2)
	return (c.action & 15) | (phase(c, tick) << 4) | (step_bits << 6)


# --- What the server imposes ------------------------------------------------------------------
# All of them are followed by CombatDirector.commit_state (rounding by encode/decode). Those that change the
# action and cut a committed channel set its cooldown on that tick.

## Stagger until [param until_tick] (exclusive) with a horizontal knockback (x, z) in m/s that decays
## linearly. Interrupts whatever the character was doing and clears the buffer, the press and the combo.
## The knockback is rounded to cm/s, just as when passing through [method PlayerState.encode]. It does nothing
## to a knocked down or dead character.
static func impose_stagger(c: CombatState, tick: int, until_tick: int, knockback: Vector2) -> void:
	if c.action == _DOWNED or c.action == _DEAD:
		return
	_leave_imposed(c, tick)
	c.action = _STAGGER
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = until_tick
	c.knockback = CombatState.quantize_knockback(knockback)


## Stun until [param until_tick] (exclusive): the character only brakes. It does nothing to a
## knocked down or dead character.
static func impose_stun(c: CombatState, tick: int, until_tick: int) -> void:
	if c.action == _DOWNED or c.action == _DEAD:
		return
	_leave_imposed(c, tick)
	c.action = _STUN
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = until_tick
	c.knockback = Vector2.ZERO


## Death: the character only brakes (gravity continues) until [method reset_for_respawn].
static func impose_death(c: CombatState, tick: int) -> void:
	_leave_imposed(c, tick)
	c.action = _DEAD
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = 0
	c.knockback = Vector2.ZERO


## Knocked down (docs/habilidades.md, section 4.5): DOWNED with [code]action_tick = tick[/code]; clears the
## buffer, the press, the combo and the movement slots. It crawls at
## [member CombatRules.downed_move_scale] and does not end on its own.
static func impose_downed(c: CombatState, tick: int) -> void:
	_leave_imposed(c, tick)
	c.action = _DOWNED
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = 0
	c.knockback = Vector2.ZERO
	clear_move_effects(c)


## Revived: NONE with [code]action_tick = tick[/code].
static func impose_revived(c: CombatState, tick: int) -> void:
	_leave_imposed(c, tick)
	c.action = _NONE
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = 0
	c.knockback = Vector2.ZERO


## Revive or execute ([param action] REVIVE or EXECUTE; any other does nothing) with
## [code]action_tick = tick[/code]. It ends on its own on reaching [member CombatTables.revive_ticks] or
## [member CombatTables.execute_ticks], with a real input without INTERACT or with a dodge.
static func impose_interact(c: CombatState, tick: int, action: int) -> void:
	if action != _REVIVE and action != _EXECUTE:
		return
	_leave_imposed(c, tick)
	c.action = action
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = 0
	c.knockback = Vector2.ZERO


## Interruption (docs/habilidades.md, section 4.2): NONE, cutting drinking, a marked cast,
## revive or execute, and keeping the [member CombatState.action_tick] of what it cuts (as when
## ending normally). Before the commit there is no cooldown or spending: only a margin of
## [constant AbilityTicks.REARM_TICKS] ticks before another consumable (or the same slot), so that a
## remote sees the NONE between the two (the action byte does not tell them apart; H5 review).
static func impose_interrupt(c: CombatState, tick: int) -> void:
	AbilityRules.rearm_after_interrupt(c, tick)
	_leave_imposed(c, tick)
	_to_none(c)


## Occupies a movement effect slot with [param effect_id] ([StatusTicks]) until
## [param until_tick] (exclusive): the same effect extends its slot ([code]until = max[/code]); otherwise
## a free slot; if there is none, it replaces the one that ends soonest.
static func impose_move_effect(c: CombatState, effect_id: int, until_tick: int) -> void:
	if effect_id <= 0:
		return
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		if c.move_effect_ids[i] == effect_id:
			c.move_effect_until[i] = maxi(c.move_effect_until[i], until_tick)
			return
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		if c.move_effect_ids[i] == 0:
			c.move_effect_ids[i] = effect_id
			c.move_effect_until[i] = until_tick
			return
	var earliest: int = 0
	for i: int in range(1, CombatState.MOVE_EFFECT_SLOTS):
		if c.move_effect_until[i] < c.move_effect_until[earliest]:
			earliest = i
	c.move_effect_ids[earliest] = effect_id
	c.move_effect_until[earliest] = until_tick


## Empties the movement effect slot occupied by [param effect_id] (if any holds it): the
## server removes it when the effect leaves early (its author drops out, or whoever
## carries it dies).
static func remove_move_effect(c: CombatState, effect_id: int) -> void:
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		if c.move_effect_ids[i] == effect_id:
			c.move_effect_ids[i] = 0
			c.move_effect_until[i] = 0


## Empties both movement effect slots.
static func clear_move_effects(c: CombatState) -> void:
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		c.move_effect_ids[i] = 0
		c.move_effect_until[i] = 0


## Sets all cooldowns to 0 (the six ability ones and the consumables' shared one).
static func reset_cooldowns(c: CombatState) -> void:
	c.ability_ready.fill(0)
	c.consumable_ready_tick = 0


## Changes [b]only[/b] the consumable charges (packed as
## [member CombatState.consumable_charges]): the camp refill and command 16 do not touch the weapon,
## cooldowns, slots or the current action.
static func set_charges(c: CombatState, charges: int) -> void:
	c.consumable_charges = charges & 0xFF


## Loadout on spawn (newly created or dead character): [param weapon_1] active,
## [param weapon_2] in the other slot (0 = none), cooldowns at 0, [param charges] and empty movement
## slots; keeps the pressed button bits. On a living character it first forces NONE
## (the current action could belong to another weapon) and clears buffer, press and combo.
static func set_loadout(c: CombatState, weapon_1: int, weapon_2: int, charges: int) -> void:
	if c.action != _DEAD:
		_clear_transient(c)
		if c.action != _NONE:
			_to_none(c)
			c.cc_until_tick = 0
			c.knockback = Vector2.ZERO
	c.weapon_id = weapon_1
	c.alt_weapon_id = weapon_2
	c.combat_flags2 &= ~CombatState.FLAG2_SECOND_SLOT
	reset_cooldowns(c)
	set_charges(c, charges)
	clear_move_effects(c)


## Sets the weapons of the two loadout slots (docs/progresion.md §4.1) [b]without resetting anything else[/b]:
## [param weapon_1] and [param weapon_2] are those of slots 1 and 2 (0 = empty) and [param second_active] the
## active slot (bit0 of [member CombatState.combat_flags2]). [member CombatState.weapon_id] and
## [member CombatState.alt_weapon_id] follow the active one, [code]ability_ready[0..2][/code] gets the
## [code]ready_*[/code] of the active weapon and [code][3..5][/code] those of the other (absolute ticks, 3 values;
## missing ones, 0). With slot 1 empty and slot 2 active, [code]alt_weapon_id[/code] is 0 (no SWAP).
## It does not touch [member CombatState.consumable_ready_tick], the charges, the movement slots, the buttons or
## anything else. Only with [code]action[/code] NONE: otherwise it does nothing and logs the error (the inventory never
## calls it then: NOT_NOW). The server imposes it at the end of the tick, like [method set_loadout].
static func set_weapons(c: CombatState, weapon_1: int, weapon_2: int, second_active: bool,
		ready_1: PackedInt64Array, ready_2: PackedInt64Array) -> void:
	if c.action != _NONE:
		push_error("[Eldmark] set_weapons con la acción %d en curso: no cambia nada" % c.action)
		return
	var active_ready: PackedInt64Array = ready_2 if second_active else ready_1
	var other_ready: PackedInt64Array = ready_1 if second_active else ready_2
	c.weapon_id = weapon_2 if second_active else weapon_1
	c.alt_weapon_id = weapon_1 if second_active else weapon_2
	for i: int in CombatState.ABILITY_SLOTS:
		c.ability_ready[i] = active_ready[i] if i < active_ready.size() else 0
		c.ability_ready[i + CombatState.ABILITY_SLOTS] = other_ready[i] if i < other_ready.size() else 0
	if second_active:
		c.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	else:
		c.combat_flags2 &= ~CombatState.FLAG2_SECOND_SLOT


## Leaves combat as on first spawn (full stamina, no action, control,
## parry, cooldowns or movement effects) with the template's loadout: [param weapon_1]
## active, [param weapon_2] in the other slot and [param charges]. Keeps the button levels
## (bits 3-5 of [member CombatState.combat_flags] and 1-6 of [member CombatState.combat_flags2]); the
## debug commands (infinite stamina, no cooldowns) are not kept.
static func reset_for_respawn(c: CombatState, tick: int, weapon_1: int, weapon_2: int,
		charges: int) -> void:
	var rules: CombatRules = CombatCatalog.rules()
	var held: int = c.combat_flags & _HELD_FLAGS
	var held2: int = c.combat_flags2 & CombatState.FLAG2_HELD_MASK
	c.copy_from(CombatState.initial(rules, weapon_1, weapon_2, charges))
	c.action_tick = tick
	c.stamina_regen_tick = tick
	c.combat_flags = held
	c.combat_flags2 = held2


## Subtracts [param amount] of stamina (not going below 0), delays regeneration and, on reaching 0,
## triggers exhaustion. It does nothing with infinite stamina.
static func drain_stamina(c: CombatState, amount: int, tick: int) -> void:
	_spend(c, amount, tick, CombatCatalog.tables())


# Before imposing another action: a committed channel being cut sets its cooldown, and
# the buffer, the press and the combo are cleared.
static func _leave_imposed(c: CombatState, tick: int) -> void:
	AbilityRules.close_channel(c, CombatCatalog.tables(), tick, true)
	_clear_transient(c)


# --- End of actions and stamina ---------------------------------------------------------------

# Step 1: actions with a duration that have already finished go back to NONE. DOWNED and DEAD do not end
# on their own.
static func _finish_expired(c: CombatState, data: CombatTables, weapon: WeaponTicks,
		t: int) -> void:
	match c.action:
		_LIGHT, _HEAVY:
			var attack: AttackTicks = data.attack(c.action_id)
			if attack == null or t >= c.action_tick + attack.total_ticks:
				# Without a press that links (a stored PRIMARY or a link), the combo starts over.
				var kind: int = c.buffered_type()
				var linked: bool = c.action == _LIGHT and attack != null \
						and (kind == CombatState.BUFFER_PRIMARY or kind == CombatState.BUFFER_LINK)
				_to_none(c)
				if not linked:
					c.combo_step = 0
		_DODGE:
			if weapon == null or t >= c.action_tick + weapon.dodge.duration_ticks:
				_to_none(c)
		_STAGGER, _STUN:
			if t >= c.cc_until_tick:
				_to_none(c)
		_ABILITY:
			AbilityRules.finish_ability(c, data, t)
		_SWAP:
			if t >= c.action_tick + data.swap_ticks:
				_to_none(c)
		_REVIVE:
			if t >= c.action_tick + data.revive_ticks:
				_to_none(c)
		_EXECUTE:
			if t >= c.action_tick + data.execute_ticks:
				_to_none(c)


# Step 3: stamina regeneration (not in BLOCK, CHARGE, DODGE or in the channel that
# blocks).
static func _regenerate(c: CombatState, data: CombatTables, t: int) -> void:
	if t < c.stamina_regen_tick:
		return
	if c.action == _BLOCK or c.action == _CHARGE or c.action == _DODGE:
		return
	if c.action == _ABILITY \
			and AbilityRules.is_blocking_channel(c, data.ability(c.action_id), t):
		return
	var rules: CombatRules = data.rules
	var exhausted: bool = (c.combat_flags & CombatState.FLAG_EXHAUSTED) != 0
	if c.stamina < rules.stamina_max:
		var rate: int = rules.stamina_regen_per_tick
		if exhausted:
			rate = rules.exhausted_regen_per_tick
		c.stamina = mini(c.stamina + rate, rules.stamina_max)
	if exhausted and c.stamina > rules.exhausted_exit_threshold:
		c.combat_flags &= ~CombatState.FLAG_EXHAUSTED


static func _spend(c: CombatState, amount: int, t: int, data: CombatTables) -> void:
	if amount <= 0 or (c.combat_flags & CombatState.FLAG_INFINITE_STAMINA) != 0:
		return
	c.stamina = maxi(c.stamina - amount, 0)
	c.stamina_regen_tick = t + data.regen_delay_ticks
	if c.stamina == 0:
		c.combat_flags |= CombatState.FLAG_EXHAUSTED


# true if exhaustion prevents dodging, blocking, charging or the wall (infinite stamina
# ignores it).
static func _is_blocked_by_exhaustion(c: CombatState) -> bool:
	return (c.combat_flags & CombatState.FLAG_EXHAUSTED) != 0 \
			and (c.combat_flags & CombatState.FLAG_INFINITE_STAMINA) == 0


# true if [param cost] can be paid (infinite stamina always can).
static func _can_pay(c: CombatState, cost: int) -> bool:
	if (c.combat_flags & CombatState.FLAG_INFINITE_STAMINA) != 0:
		return true
	return c.stamina >= cost


# --- Inputs -----------------------------------------------------------------------------------

# Step 4: 4a ends by input, 4b the buffer and 4c the new edges by priority.
static func _run_inputs(c: CombatState, out: Output, input: PlayerInput,
		data: CombatTables, weapon: WeaponTicks, grounded: bool, down: int, edges: int) -> void:
	var t: int = input.tick
	var rules: CombatRules = data.rules
	var real: bool = (input.buttons & PlayerInput.SUBSTITUTED) == 0
	if c.action == _DEAD or c.action == _DOWNED:
		c.buffered = 0
		c.primary_held = 0
		return

	# 4a: releasing a channel's button (or moving, if the data says so) and releasing INTERACT.
	if real:
		AbilityRules.end_by_input(c, input, data, down)

	# 4b: the buffer, with priority over this tick's edges. A weapon swap from the buffer changes the
	# weapon already on this tick.
	_run_buffer(c, input, data, weapon, rules, grounded, down)
	if c.weapon_id != weapon.id:
		weapon = data.weapon(c.weapon_id)
		if weapon == null:
			return

	# 4c: DODGE > ABILITY_1 > ABILITY_2 > ABILITY_3 > CONSUMABLE_1 > CONSUMABLE_2 > PRIMARY > SWAP >
	# BLOCK. An edge that cannot be executed now goes to the buffer (the last press wins).
	if (edges & PlayerInput.DODGE) != 0:
		if _try_dodge(c, input, data, weapon, grounded) == _DODGE_RETRY:
			_store_buffer(c, rules, CombatState.BUFFER_DODGE)
	for slot: int in CombatState.ABILITY_SLOTS:
		if (edges & (PlayerInput.ABILITY_1 << slot)) != 0:
			if AbilityRules.try_ability(c, input, data, weapon, grounded, slot, down, false) \
					== AbilityRules.RETRY:
				_store_buffer(c, rules, CombatState.BUFFER_ABILITY_1 + slot)
	for index: int in CombatState.CONSUMABLE_SLOTS:
		if (edges & (PlayerInput.CONSUMABLE_1 << index)) != 0:
			if AbilityRules.try_consumable(c, input, data, weapon, grounded, index, down, false) \
					== AbilityRules.RETRY:
				_store_buffer(c, rules, CombatState.BUFFER_CONSUMABLE_1 + index)
	_run_primary(c, out, t, data, weapon, rules, grounded, real, down, edges)
	_run_charge(c, t, data, real, down)
	if (edges & PlayerInput.SWAP_WEAPON) != 0:
		var swap: int = AbilityRules.try_swap(c, data, weapon, t)
		if swap == AbilityRules.RETRY:
			_store_buffer(c, rules, CombatState.BUFFER_SWAP)
		elif swap == AbilityRules.STARTED:
			weapon = data.weapon(c.weapon_id)
			if weapon == null:
				return
	_run_block(c, t, rules, weapon, grounded, real, down, edges)


# Executes whatever was in the buffer on the first tick on which it can be; otherwise, subtracts a tick from it. The
# dispatch is by type (docs/habilidades.md, section 3.1).
static func _run_buffer(c: CombatState, input: PlayerInput, data: CombatTables,
		weapon: WeaponTicks, rules: CombatRules, grounded: bool, down: int) -> void:
	var kind: int = c.buffered_type()
	if kind == CombatState.BUFFER_NONE:
		return
	var remaining: int = c.buffered_ticks()
	var done: bool = false
	match kind:
		CombatState.BUFFER_DODGE:
			done = _try_dodge(c, input, data, weapon, grounded) != _DODGE_RETRY
		CombatState.BUFFER_PRIMARY, CombatState.BUFFER_LINK:
			done = _try_start_light(c, input.tick, data, weapon, grounded)
		CombatState.BUFFER_ABILITY_1, CombatState.BUFFER_ABILITY_2, CombatState.BUFFER_ABILITY_3:
			done = AbilityRules.try_ability(c, input, data, weapon, grounded,
					kind - CombatState.BUFFER_ABILITY_1, down, true) != AbilityRules.RETRY
		CombatState.BUFFER_SWAP:
			done = AbilityRules.try_swap(c, data, weapon, input.tick) != AbilityRules.RETRY
		CombatState.BUFFER_CONSUMABLE_1, CombatState.BUFFER_CONSUMABLE_2:
			done = AbilityRules.try_consumable(c, input, data, weapon, grounded,
					kind - CombatState.BUFFER_CONSUMABLE_1, down, true) != AbilityRules.RETRY
		_:
			done = true
	if done:
		c.buffered = 0
		return
	if kind == CombatState.BUFFER_LINK:
		# The link waits for the light attack to end; if there is no longer a light attack in progress (it ended without being able to
		# chain, or another action cut it) it becomes a normal stored press.
		if c.action != _LIGHT:
			_store_buffer(c, rules, CombatState.BUFFER_PRIMARY)
		return
	remaining -= 1
	if remaining <= 0:
		c.buffered = 0
		# A press that expires without having started anything, with the previous light attack already finished (the
		# link could not be executed, e.g. in the air), does not leave the combo half-done: the next
		# light attack is the first one again. With a light attack in progress, its own end decides. Applies to
		# any type (docs/habilidades.md, section 3.1): also a dodge or an ability that
		# replaced in the buffer the press that was linking.
		if c.action != _LIGHT:
			c.combo_step = 0
	else:
		c.buffered = CombatState.pack_buffer(kind, remaining)


static func _store_buffer(c: CombatState, rules: CombatRules, kind: int) -> void:
	c.buffered = CombatState.pack_buffer(kind, clampi(rules.input_buffer_ticks, 1, 15))


# Tries a dodge on the tick of [param input]. Returns _DODGE_STARTED if it started,
# _DODGE_RETRY if it cannot be done now (because of the current action or being in the air: it goes to the buffer) and
# _DODGE_DROPPED if it failed for lack of stamina or exhaustion (it is dropped and the
# UI is notified) or for being rooted (it is dropped without notice).
static func _try_dodge(c: CombatState, input: PlayerInput, data: CombatTables,
		weapon: WeaponTicks, grounded: bool) -> int:
	var t: int = input.tick
	var dodge: DodgeTicks = weapon.dodge
	var allowed: bool = false
	match c.action:
		_NONE, _BLOCK, _CHARGE, _REVIVE, _EXECUTE:
			allowed = true
		_LIGHT, _HEAVY:
			var attack: AttackTicks = data.attack(c.action_id)
			allowed = attack != null and t >= c.action_tick + attack.cancel_to_dodge_from_ticks
		_ABILITY:
			var ability: AbilityTicks = data.ability(c.action_id)
			allowed = ability == null or t >= c.action_tick + ability.cancel_to_dodge_from_ticks
	if (c.move_effect_ids[0] != 0 or c.move_effect_ids[1] != 0) \
			and AbilityRules.is_rooted(c, data):
		return _DODGE_DROPPED
	if not allowed or not grounded:
		return _DODGE_RETRY
	if _is_blocked_by_exhaustion(c) or not _can_pay(c, dodge.stamina_cost):
		c.combat_flags |= CombatState.FLAG_NO_STAMINA
		return _DODGE_DROPPED
	_spend(c, dodge.stamina_cost, t, data)
	# From a channel, it ends it (with its cooldown if it already committed).
	AbilityRules.close_channel(c, data, t, false)
	_clear_link(c)
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
	c.action = _DODGE
	c.action_id = 0
	c.action_tick = t
	c.combo_step = 0
	c.charge_ticks = 0
	c.action_dir = CombatState.quantize_yaw(_dodge_yaw(input))
	return _DODGE_STARTED


# World yaw toward which the dodge goes: the movement direction relative to the camera, or backward
# if there is no movement.
static func _dodge_yaw(input: PlayerInput) -> float:
	if input.move.length() < _DODGE_MIN_MOVE:
		return input.look_yaw + PI
	return input.look_yaw + atan2(-input.move.x, input.move.y)


# true if the character can start an attack now: on the ground and with no action, blocking, in the
# cancelable part of a dodge or in an ability's recovery (or from its
# cancel_to_attack_from).
static func _can_start_attack(c: CombatState, t: int, data: CombatTables, weapon: WeaponTicks,
		grounded: bool) -> bool:
	if not grounded:
		return false
	match c.action:
		_NONE, _BLOCK:
			return true
		_DODGE:
			return t >= c.action_tick + weapon.dodge.cancel_to_attack_from_ticks
		_ABILITY:
			var ability: AbilityTicks = data.ability(c.action_id)
			return ability == null or t - c.action_tick >= mini(ability.active_to(),
					ability.cancel_to_attack_from_ticks)
	return false


# Starts the next light attack of the combo if possible. Returns true if the press is
# consumed (the light attack started or was dropped for lack of stamina).
static func _try_start_light(c: CombatState, t: int, data: CombatTables,
		weapon: WeaponTicks, grounded: bool) -> bool:
	if not _can_start_attack(c, t, data, weapon, grounded):
		return false
	var count: int = weapon.light_ids.size()
	if count == 0:
		return true
	var index: int = clampi(c.combo_step, 0, count - 1)
	var attack: AttackTicks = data.attack(weapon.light_ids[index])
	if attack == null:
		return true
	if attack.stamina_cost > 0 and not _can_pay(c, attack.stamina_cost):
		c.combat_flags |= CombatState.FLAG_NO_STAMINA
		return true
	_spend(c, attack.stamina_cost, t, data)
	AbilityRules.close_channel(c, data, t, false)
	_clear_link(c)
	c.action = _LIGHT
	c.action_id = attack.id
	c.action_tick = t
	c.combo_step = (index + 1) % count
	c.charge_ticks = 0
	# It belongs to the live press if the button is still down (this tick's edge, or the buffer or link it
	# left): holding it turns it into a charge.
	if c.primary_held > 0 and (c.combat_flags & CombatState.FLAG_PRIMARY_HELD) != 0:
		c.combat_flags |= CombatState.FLAG_LIGHT_OF_PRESS
	else:
		c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
	return true


# PRIMARY: edge, held and released.
static func _run_primary(c: CombatState, out: Output, t: int, data: CombatTables,
		weapon: WeaponTicks, rules: CombatRules, grounded: bool, real: bool, down: int,
		edges: int) -> void:
	if (down & PlayerInput.PRIMARY) == 0:
		c.primary_held = 0
		c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
		return
	if (edges & PlayerInput.PRIMARY) != 0:
		# While charging, a new press (after releasing and waiting for the minimum charge) does
		# nothing: the charge is already decided.
		if c.action == _CHARGE:
			return
		c.primary_held = 1
		if not _try_start_light(c, t, data, weapon, grounded):
			_buffer_primary(c, t, data, rules)
		return
	if not real or c.primary_held == 0:
		return
	c.primary_held = mini(c.primary_held + 1, 255)
	if c.primary_held >= rules.hold_to_heavy_ticks and c.action == _LIGHT:
		_try_charge(c, out, t, data, weapon)


# Stores a PRIMARY press that cannot be executed now. Within a light attack's combo window
# (or up to input_buffer_ticks before it) it is a link, which waits for the
# recovery to end; in any other case it is a normal buffer press.
static func _buffer_primary(c: CombatState, t: int, data: CombatTables,
		rules: CombatRules) -> void:
	if c.action == _LIGHT:
		var attack: AttackTicks = data.attack(c.action_id)
		if attack != null and attack.combo_window_ticks > 0:
			var end: int = c.action_tick + attack.total_ticks
			if t >= end - attack.combo_window_ticks - rules.input_buffer_ticks:
				c.buffered = CombatState.BUFFER_LINK
				return
	_store_buffer(c, rules, CombatState.BUFFER_PRIMARY)


# Converts the light attack into a heavy attack charge if it is still in the windup, this press
# started it and there is stamina.
static func _try_charge(c: CombatState, out: Output, t: int, data: CombatTables,
		weapon: WeaponTicks) -> void:
	var attack: AttackTicks = data.attack(c.action_id)
	if attack == null or t - c.action_tick >= attack.windup_ticks:
		return
	# If the light attack started before the live press, it is not its own. (It is not deduced from primary_held: it only
	# counts real ticks, and with a substituted input in between t - primary_held + 1 stops being
	# the tick of the press.)
	if (c.combat_flags & CombatState.FLAG_LIGHT_OF_PRESS) == 0:
		return
	var heavy: AttackTicks = data.attack(weapon.heavy_id)
	if heavy == null:
		return
	if _is_blocked_by_exhaustion(c) or not _can_pay(c, heavy.stamina_cost):
		c.combat_flags |= CombatState.FLAG_NO_STAMINA
		return
	_clear_link(c)
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
	c.action = _CHARGE
	c.action_id = heavy.id
	c.charge_ticks = 0
	out.snap_yaw = true


# Charge: releases the heavy attack on release (waiting for the minimum charge) or on reaching the maximum.
static func _run_charge(c: CombatState, t: int, data: CombatTables, real: bool,
		down: int) -> void:
	if c.action != _CHARGE:
		return
	var heavy: AttackTicks = data.attack(c.action_id)
	if heavy == null:
		_to_none(c)
		return
	var charge: int = t - c.action_tick
	var live: bool = (down & PlayerInput.PRIMARY) != 0 and c.primary_held > 0
	if live:
		if real and charge >= heavy.charge_max_ticks:
			_launch_heavy(c, t, heavy, data)
		elif not real and charge >= heavy.charge_max_ticks + data.rules.input_buffer_ticks:
			# The client has been silent for more than the input buffer with the charge at maximum: it is canceled
			# without releasing or spending. Otherwise, a client that stops sending (with the connection alive)
			# would hold the charged heavy attack as long as it wanted and release it instantly.
			_to_none(c)
	elif charge >= heavy.charge_min_ticks:
		_launch_heavy(c, t, heavy, data)


static func _launch_heavy(c: CombatState, t: int, heavy: AttackTicks, data: CombatTables) -> void:
	if not _can_pay(c, heavy.stamina_cost):
		c.combat_flags |= CombatState.FLAG_NO_STAMINA
		_to_none(c)
		return
	_spend(c, heavy.stamina_cost, t, data)
	c.charge_ticks = clampi(t - c.action_tick, 0, heavy.charge_max_ticks)
	c.action = _HEAVY
	c.action_id = heavy.id
	c.action_tick = t
	c.combo_step = 0


# BLOCK: level-based. Starts from NONE (also when another action ends with the button pressed); only a
# real edge opens the parry window, and only if the cooldown has passed. With a weapon that does not
# block (the bow), it does nothing.
static func _run_block(c: CombatState, t: int, rules: CombatRules, weapon: WeaponTicks,
		grounded: bool, real: bool, down: int, edges: int) -> void:
	var block_down: bool = (down & PlayerInput.BLOCK) != 0
	if c.action == _BLOCK:
		if not block_down or not grounded or not weapon.can_block:
			_to_none(c)
		return
	if c.action != _NONE or not block_down or not grounded or not weapon.can_block:
		return
	if _is_blocked_by_exhaustion(c):
		return
	c.action = _BLOCK
	c.action_id = 0
	c.action_tick = t
	if (edges & PlayerInput.BLOCK) != 0 and real and t >= c.parry_ready_tick \
			and rules.parry_window_ticks > 0:
		c.parry_ready_tick = t + rules.parry_cooldown_ticks


# --- Allowed movement -------------------------------------------------------------------------

# Step 6: the movement table from docs/combate.md, section 3.3, extended in docs/habilidades.md,
# section 3.4, for the current action.
static func _fill_output(c: CombatState, out: Output, data: CombatTables,
		weapon: WeaponTicks, t: int) -> void:
	match c.action:
		_LIGHT, _HEAVY:
			var attack: AttackTicks = data.attack(c.action_id)
			if attack == null:
				return
			out.scaled_movement = true
			out.move_scale = attack.move_speed_scale
			out.allow_jump = false
			out.allow_sprint = false
			var relative: int = t - c.action_tick
			if relative < attack.active_to():
				out.lunge_speed = attack.lunge_speed
				out.turn_rate = attack.turn_rate
				if relative == 0:
					out.snap_yaw = true
			else:
				out.turn_rate = 0.0
		_CHARGE:
			var heavy: AttackTicks = data.attack(c.action_id)
			if heavy == null:
				return
			out.scaled_movement = true
			out.move_scale = heavy.charge_move_scale
			out.turn_rate = heavy.charge_turn_rate
			out.allow_jump = false
			out.allow_sprint = false
		_BLOCK:
			if weapon == null:
				return
			out.scaled_movement = true
			out.move_scale = weapon.block_move_scale
			out.turn_rate = weapon.block_turn_rate
			out.allow_sprint = false
		_DODGE:
			if weapon == null:
				return
			var heading: float = CombatState.dequantize_yaw(c.action_dir)
			var speed: float = weapon.dodge.speed_at(t - c.action_tick)
			out.scaled_movement = true
			out.forced_velocity = true
			out.velocity = Vector3(-sin(heading) * speed, 0.0, -cos(heading) * speed)
			out.move_scale = 0.0
			out.turn_rate = 0.0
			out.allow_jump = false
			out.allow_sprint = false
		_STAGGER:
			out.scaled_movement = true
			out.move_scale = 0.0
			out.turn_rate = 0.0
			out.allow_jump = false
			out.allow_sprint = false
			var duration: int = c.cc_until_tick - c.action_tick
			if duration > 0 and c.knockback != Vector2.ZERO:
				var factor: float = clampf((c.cc_until_tick - t) / float(duration), 0.0, 1.0)
				out.forced_velocity = true
				out.velocity = Vector3(c.knockback.x * factor, 0.0, c.knockback.y * factor)
		_STUN, _DEAD:
			out.scaled_movement = true
			out.move_scale = 0.0
			out.turn_rate = 0.0
			out.allow_jump = false
			out.allow_sprint = false
		_ABILITY, _SWAP, _DOWNED, _REVIVE, _EXECUTE:
			AbilityRules.fill_output(c, out, data, t)


# --- Utilities --------------------------------------------------------------------------------

# Bit of [param flag] if [param button] is down in [param down].
static func _level(down: int, button: int, flag: int) -> int:
	return flag if (down & button) != 0 else 0


# [param button] if bit [param flag] is in [param held] and was not in [param previous].
static func _edge(held: int, previous: int, flag: int, button: int) -> int:
	return button if (held & flag) != 0 and (previous & flag) == 0 else 0


# Goes back to NONE keeping the action_tick of what ends (the old block sample uses it:
# docs/habilidades.md, section 4.2).
static func _to_none(c: CombatState) -> void:
	c.action = _NONE
	c.action_id = 0
	c.charge_ticks = 0
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS


# Clears a pending combo link: it no longer makes sense once another action starts.
static func _clear_link(c: CombatState) -> void:
	if c.buffered_type() == CombatState.BUFFER_LINK:
		c.buffered = 0


static func _clear_transient(c: CombatState) -> void:
	c.buffered = 0
	c.primary_held = 0
	c.combo_step = 0
	c.charge_ticks = 0
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
