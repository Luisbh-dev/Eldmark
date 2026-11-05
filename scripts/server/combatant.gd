class_name Combatant
extends RefCounted
## What the server knows about the combat of an entity with a body (docs/combat.md, section 5): player,
## fake player or NPC. One per entity that can take damage.
## [br][br]
## It carries health (authoritative, not predicted: it is not in [PlayerState]), the "in combat" state, respawn
## protection, death and the respawn deadline, the chain of controls with its
## immunity, the [DamageLedger] and the last enemy that hit it (to credit falls). What does
## change the simulation (action, stamina, controls) lives in [member PlayerCharacter.combat] and
## travels in [PlayerState].
## [br][br]
## [member frozen] is the "current-tick sample" (docs/combat.md, 4.2): the entity's position, turn,
## defensive flags and action right after simulating the tick, which the
## [CombatResolver] uses so that all the hits of a tick are simultaneous. Since phase 4
## (docs/abilities.md, section 4.1, step 2) it also freezes the active hit (an attack or an ability's
## synthesized hit), if it is the commitment tick, and the shield wall's box.
## [br][br]
## [member effects] are its active status effects (carried by the [StatusSystem]).
## [br][br]
## [b]Knocked down[/b] (docs/abilities.md, section 4.5; carried by the [DownedSystem]): with health at 0 after a lethal
## hit from a hostile player in an RvR zone, the player is knocked down ([method is_downed]) with
## [member downed_health] of downed health. A downed player is neither alive nor dead: [method is_alive] is
## [code]health > 0[/code] (unchanged) and [method is_dead] is [code]health == 0[/code] and not downed. Whoever
## lifts or finishes off carries in [member interact_target] whom and since when.
## [br][br]
## [member template_id] is the current loadout template ([EquipmentTemplate]; 0 = none: NPCs and
## fighters assembled by hand in tests); the pending one, the one the player chose for their next
## spawn, lives in [member ServerPeer.pending_template_id].

## Frozen state of the entity after simulating tick [member tick]. It is a
## [StateHistory.Sample] (position, turn and flags) with the action in progress.
class Frozen:
	extends StateHistory.Sample

	## Tick after which it was frozen (-1 = never).
	var tick: int = -1
	## Defensive flags ([method ActionMachine.defense_flags]) of the tick.
	var defense: int = 0
	var action: int = 0
	var action_id: int = 0
	var action_tick: int = 0
	var weapon_id: int = 0
	## Charge with which the heavy attack in progress was launched.
	var charge_ticks: int = 0
	## The tick's active hit ([method ActionMachine.active_hit]): the attack in its active hit or the
	## ability's synthesized hit in its active phase or its channel ([member AbilityTicks.hit]);
	## null if there is none. Without a shape it tests no one.
	var hit: AttackTicks = null
	## There is an active hit ([member hit] is not null).
	var attack_active: bool = false
	## It is in the active hit of an attack or ability with poise
	## ([member AttackTicks.hyper_armor]).
	var hyper_armor: bool = false
	## The tick is the commitment's ([method ActionMachine.is_commit_tick]): the first active tick of a
	## LIGHT, a HEAVY or an ABILITY (projectiles and own effects come out).
	var commit: bool = false
	## Shield wall box (center and turn) while the blocking channel carries it
	## ([member AbilityTicks.wall_half_extents]); valid if [member wall_half_extents] is not zero.
	var wall: Transform3D = Transform3D.IDENTITY
	## Half-extents of [member wall] (zero = no wall).
	var wall_half_extents: Vector3 = Vector3.ZERO


## [member effects_due] with no effects: never.
const NO_EFFECTS_DUE: int = 0x7FFFFFFFFFFFFFFF
## [member last_buttons_tick] when no input has been seen yet.
const NO_BUTTONS_TICK: int = -1

var entity: NetEntity
## The entity's input queue (that of a network player, a fake player or an NPC).
var queue: InputQueue
## The player's peer (null for fakes and NPCs: they do not rewind).
var peer: ServerPeer
var timing: CombatTiming
var health: int = 0
var max_health: int = 0
## A dummy: health does not drop below 1, it does not die and it fully heals after [member CombatTiming.dummy_heal].
var immortal: bool = false
## A Gate Guardian: it can attack from the safe zone of its own realm and attacks the enemies
## inside it (docs/combat.md, section 5). Set by whoever creates the NPC, according to its [code]NpcDefinition[/code].
var ignores_safe_area: bool = false
var in_combat_until: int = 0
var protected_until: int = 0
## Tick of death (-1 if alive), first tick at which it can respawn if requested and tick at which it
## respawns on its own if not requested (both in a wave if the zone has them: [method CombatTiming.respawn_tick_for]
## and [method CombatTiming.auto_respawn_tick_for]).
var death_tick: int = -1
var respawn_tick: int = 0
var auto_respawn_tick: int = 0
## Respawn point requested with RESPAWN_REQUEST (-1 = no pending request).
var pending_respawn_point: int = -1
## Requests respawn on dying, at point 0 (if it is no longer valid for its realm, the first valid camp): it
## gets it as soon as [member respawn_tick] arrives, like someone who presses the death screen's button as soon as
## they can, or a [code]SwarmBot[/code]. Carried by the server's fake players
## ([method ZoneServer.add_fake_player]); without it, it would respawn through the automatic path.
var requests_respawn_on_death: bool = false
## Who dealt the lethal hit (0 = the environment) and with which attack.
var killer_id: int = 0
var death_attack_id: int = 0
## Last tick on which it took damage.
var last_damage_tick: int = -1
## Last enemy that hit it: net_id, tick and attack. Credits deaths by fall or volume.
var last_enemy_id: int = 0
var last_enemy_tick: int = -1
var last_enemy_attack_id: int = 0
## Controls received within the chain window (ticks) and the end of immunity.
var cc_chain: PackedInt64Array = PackedInt64Array()
var cc_immune_until: int = 0
var ledger: DamageLedger
var frozen: Frozen = Frozen.new()
## Active status effects (up to [constant StatusSystem.MAX_EFFECTS], by effect id). Carried by the
## [StatusSystem]: nobody else touches them.
var effects: Array[StatusSystem.ActiveEffect] = []
## First tick at which something happens to [member effects] (a pulse or an expiry); the [StatusSystem] does not look at
## the entity before. [constant NO_EFFECTS_DUE] if it carries none.
var effects_due: int = NO_EFFECTS_DUE
## Downed health (from [member CombatRules.downed_health] to 0) and the tick it fell (-1 = not downed).
var downed_health: int = 0
var downed_tick: int = -1
## Who knocked it down (0 = nobody: command 15) and with which source ([CombatSource]).
var downed_by: int = 0
var downed_source: int = 0
## Lifting or finishing off in progress by this entity (the one acting): the downed player's net_id (0 = none), the
## action ([constant CombatState.Action.REVIVE] or [constant CombatState.Action.EXECUTE]) and its start tick.
var interact_target: int = 0
var interact_action: int = 0
var interact_start: int = -1
## Buttons (without [constant PlayerInput.SUBSTITUTED]) of the input at tick [member last_buttons_tick]: with
## them the [DownedSystem] sees the INTERACT edge of the next input.
var last_buttons: int = 0
var last_buttons_tick: int = NO_BUTTONS_TICK
## Current loadout template (catalog id; 0 = none). The pending one is in
## [member ServerPeer.pending_template_id].
var template_id: int = 0
## Attack (by its start tick) being resolved, and whom it has already hit: one impact per
## action and target.
var swing_action_tick: int = -1
var swing_hits: Dictionary[int, bool] = {}
## The attack in progress has already hit something (impact, block or parry): counts as a hit once.
var swing_landed: bool = false
## Rewind of the attack in progress, fixed by the [CombatResolver] on its first active tick (the client
## does not change it on the following ones): [member swing_rewind_fixed] says whether it was already fixed, [member swing_rewind]
## is the ticks it looks back (NAN = the hit asked for more than allowed and is not tested) and
## [member swing_defense_rewind] the ones looked back at for parry, block and invulnerability
## (at least the minimum consistent with the measured RTT).
var swing_rewind_fixed: bool = false
var swing_rewind: float = 0.0
var swing_defense_rewind: float = 0.0
## Start tick of the attack whose rewind was rejected (so suspicion is counted only once).
var rejected_swing_tick: int = -1

# Remainder of health regeneration (in points per second, cashed in every 60).
var _regen_carry: int = 0
# Builds the action byte of the network record, with the reset counter for dodges and controls.
var _action_wire: ActionWire = ActionWire.new()


## [param entity] must have a [PlayerCharacter] as its node. [param max_health] is the maximum health
## and it appears with it.
func _init(new_entity: NetEntity, new_queue: InputQueue, new_peer: ServerPeer,
		new_timing: CombatTiming, new_max_health: int) -> void:
	entity = new_entity
	queue = new_queue
	peer = new_peer
	timing = new_timing
	max_health = new_max_health
	health = new_max_health
	ledger = DamageLedger.new(new_entity.net_id)


## net_id of the entity.
func get_id() -> int:
	return entity.net_id


## Side code of the entity.
func get_realm() -> int:
	return entity.realm


func get_character() -> PlayerCharacter:
	return entity.get_character()


## true with health (neither dead nor downed).
func is_alive() -> bool:
	return health > 0


## true if dead: no health and not downed (docs/abilities.md, section 4.5). A downed player is neither
## alive nor dead.
func is_dead() -> bool:
	return health <= 0 and downed_tick < 0


## true while downed (docs/abilities.md, section 4.5).
func is_downed() -> bool:
	return downed_tick >= 0


## true while lifting or finishing off someone (carried by the [DownedSystem]).
func is_interacting() -> bool:
	return interact_target != 0


## true while the "in combat" state lasts (10 s after dealing or receiving damage).
func is_in_combat(tick: int) -> bool:
	return tick < in_combat_until


## true during respawn protection.
func is_protected(tick: int) -> bool:
	return tick < protected_until


## true if it is an invisible GM ([member NetEntity.gm_invisible], docs/platform.md §9.1): it neither deals nor takes damage,
## is nobody's target and does not interact with downed players.
func is_gm_invisible() -> bool:
	return entity != null and entity.gm_invisible


## State bits of the snapshot's extra block ([constant NetMessages.STATUS_IN_COMBAT]...). A downed player
## carries [constant NetMessages.STATUS_DOWNED] (never with [constant NetMessages.STATUS_DEAD]) and, if still in
## combat, [constant NetMessages.STATUS_IN_COMBAT].
func status_bits(tick: int) -> int:
	var bits: int = 0
	if is_downed():
		bits |= NetMessages.STATUS_DOWNED
		if is_in_combat(tick):
			bits |= NetMessages.STATUS_IN_COMBAT
	elif is_dead():
		bits |= NetMessages.STATUS_DEAD
	else:
		if is_in_combat(tick):
			bits |= NetMessages.STATUS_IN_COMBAT
		if is_protected(tick):
			bits |= NetMessages.STATUS_PROTECTED
	return bits


## Records that the entity dealt or received damage at [param tick]: "in combat" for another
## [member CombatTiming.in_combat] ticks.
func mark_combat(tick: int) -> void:
	in_combat_until = maxi(in_combat_until, tick + timing.in_combat)


## Freezes the entity after simulating tick [param tick] (the current-tick sample).
func freeze(tick: int) -> void:
	var character: PlayerCharacter = entity.get_character()
	var state: CombatState = character.combat
	var sample: Frozen = frozen
	sample.tick = tick
	sample.position = entity.get_position()
	sample.yaw = character.yaw
	sample.action = state.action
	sample.action_id = state.action_id
	sample.action_tick = state.action_tick
	sample.weapon_id = state.weapon_id
	sample.charge_ticks = state.charge_ticks
	sample.defense = ActionMachine.defense_flags(state, tick)
	# The history byte: bits 0-2 of the record (ground and teleport) and the defensive
	# flags; bit 3 of the record (slot 2) never enters (it is DEFENSE_BLOCKING here).
	sample.flags = (entity.teleport_counter & EntityRecord.TELEPORT_MASK) \
			<< EntityRecord.TELEPORT_SHIFT
	if character.grounded:
		sample.flags |= EntityRecord.FLAG_GROUNDED
	sample.flags = (sample.flags & EntityRecord.HISTORY_FLAGS_MASK) | sample.defense
	sample.hit = null
	sample.commit = false
	sample.wall_half_extents = Vector3.ZERO
	match state.action:
		CombatState.Action.LIGHT, CombatState.Action.HEAVY, CombatState.Action.ABILITY:
			sample.hit = ActionMachine.active_hit(state, tick)
			sample.commit = ActionMachine.is_commit_tick(state, tick)
			if (sample.defense & ActionMachine.DEFENSE_WIDE_BLOCK) != 0:
				_freeze_wall(sample, state, character.yaw)
	sample.attack_active = sample.hit != null
	sample.hyper_armor = sample.hit != null and sample.hit.hyper_armor


# The shield wall box of the blocking channel: in front of the feet by
# [member AbilityTicks.wall_forward_m], with its base on the ground and turned with the body.
static func _freeze_wall(sample: Frozen, state: CombatState, yaw: float) -> void:
	var ability: AbilityTicks = CombatCatalog.ability(state.action_id)
	if ability == null or ability.wall_half_extents == Vector3.ZERO:
		return
	var basis := Basis(Vector3.UP, yaw)
	sample.wall = Transform3D(basis, sample.position
			+ basis * Vector3(0.0, ability.wall_half_extents.y, -ability.wall_forward_m))
	sample.wall_half_extents = ability.wall_half_extents


## Removes up to [param amount] of health and returns what it actually removed. A dummy
## ([member immortal]) keeps at least 1 point. Does nothing if already dead. It does not touch the
## "in combat" state (whoever applies the hit marks it).
func take_damage(amount: int, tick: int) -> int:
	if amount <= 0 or health <= 0:
		return 0
	var floor_health: int = 1 if immortal else 0
	var applied: int = clampi(health - floor_health, 0, amount)
	health -= applied
	last_damage_tick = tick
	return applied


## Removes up to [param amount] of downed health and returns what it actually removed (no block or
## controls: whoever applies the hit decides). Does nothing if not downed. At 0, the caller kills it.
func take_downed_damage(amount: int, tick: int) -> int:
	if amount <= 0 or not is_downed():
		return 0
	var applied: int = mini(amount, downed_health)
	downed_health -= applied
	if applied > 0:
		last_damage_tick = tick
	return applied


## Leaves it downed at [param tick] by [param author_id] with source [param source] and [param health] of
## downed health. Normal health stays at 0. It does not touch its [CombatState]: the [DownedSystem] imposes it.
func mark_downed(tick: int, author_id: int, source: int, health_when_downed: int) -> void:
	health = 0
	downed_health = maxi(health_when_downed, 1)
	downed_tick = tick
	downed_by = author_id
	downed_source = source
	_regen_carry = 0


## Stops being downed (lifted, dead or on respawning): clears the downed health and its author.
func clear_downed() -> void:
	downed_health = 0
	downed_tick = -1
	downed_by = 0
	downed_source = 0


## Forgets the lifting or finishing off it was doing (called by the [DownedSystem] on completing or cutting it).
func clear_interaction() -> void:
	interact_target = 0
	interact_action = 0
	interact_start = -1


## Records the last enemy that hit it.
func note_enemy_hit(attacker_id: int, attack_id: int, tick: int) -> void:
	last_enemy_id = attacker_id
	last_enemy_attack_id = attack_id
	last_enemy_tick = tick


## true if [param tick] is within the last enemy's credit window (the same as
## "in combat").
func has_recent_enemy(tick: int) -> bool:
	return last_enemy_id != 0 and last_enemy_tick >= 0 and tick - last_enemy_tick < timing.in_combat


## Tries to impose a control (stagger, stun...) on it at [param tick]. Control chain
## (docs/combat.md, 4.4): those of the last [member CombatTiming.cc_window] ticks are counted; the
## third does not go through and opens [member CombatTiming.cc_immunity] ticks of immunity to controls.
## Returns false if the control does not go through.
func try_control(tick: int) -> bool:
	if tick < cc_immune_until:
		return false
	var kept := PackedInt64Array()
	for control_tick: int in cc_chain:
		if tick - control_tick < timing.cc_window:
			kept.append(control_tick)
	cc_chain = kept
	if cc_chain.size() >= 2:
		cc_immune_until = tick + timing.cc_immunity
		cc_chain.clear()
		return false
	cc_chain.append(tick)
	return true


## One tick of health regeneration: [param per_second] points per second, only out of combat
## and when not dead. The dummy heals fully when it has gone
## [member CombatTiming.dummy_heal] ticks without taking damage.
func regenerate(tick: int, per_second: int) -> void:
	if health <= 0 or health >= max_health:
		_regen_carry = 0
		return
	if immortal and last_damage_tick >= 0 and tick - last_damage_tick >= timing.dummy_heal:
		health = max_health
		return
	if tick < in_combat_until:
		return
	_regen_carry += per_second
	@warning_ignore("integer_division")
	var gained: int = _regen_carry / CombatCatalog.TICK_RATE
	_regen_carry -= gained * CombatCatalog.TICK_RATE
	if gained > 0:
		health = mini(health + gained, max_health)


## Heals up to [param amount] without exceeding the maximum (potions, healing over time) and returns what
## it actually healed. Does nothing on a dead entity.
func restore_health(amount: int) -> int:
	if amount <= 0 or health <= 0 or health >= max_health:
		return 0
	var restored: int = mini(amount, max_health - health)
	health += restored
	return restored


## Fully heals (debug command, respawn).
func heal_full() -> void:
	health = max_health
	_regen_carry = 0


## Marks death at [param tick]: health to 0, respawn deadlines (requested and automatic), the request of
## whoever asks for it on dying ([member requests_respawn_on_death]) and author. A downed player stops being so.
func mark_dead(tick: int, killer: int, attack_id: int) -> void:
	health = 0
	clear_downed()
	death_tick = tick
	respawn_tick = timing.respawn_tick_for(tick)
	auto_respawn_tick = timing.auto_respawn_tick_for(tick)
	pending_respawn_point = 0 if requests_respawn_on_death else -1
	killer_id = killer
	death_attack_id = attack_id


## Leaves the entity alive as on spawning: full health, protected for
## [member CombatTiming.protection] ticks from [param tick], out of combat and with an empty
## damage log.
func mark_respawned(tick: int) -> void:
	heal_full()
	clear_downed()
	clear_interaction()
	death_tick = -1
	respawn_tick = 0
	auto_respawn_tick = 0
	pending_respawn_point = -1
	killer_id = 0
	death_attack_id = 0
	protected_until = tick + timing.protection
	in_combat_until = 0
	last_enemy_id = 0
	last_enemy_tick = -1
	cc_chain.clear()
	cc_immune_until = 0
	last_damage_tick = -1
	ledger.clear()
	swing_action_tick = -1
	forget_swing()


## Starts tracking the attack that began at [param action_tick]; if it is a different one from the previous, forgets whom
## it had hit.
func track_swing(action_tick: int) -> void:
	if action_tick != swing_action_tick:
		swing_action_tick = action_tick
		forget_swing()


## Forgets what it knows about the attack in progress: whom it has already hit, whether it has landed and the rewind that was
## fixed on its first active tick.
func forget_swing() -> void:
	swing_hits.clear()
	swing_landed = false
	swing_rewind_fixed = false


## true if this attack has already hit (or been blocked or parried by) [param victim_id].
func has_hit(victim_id: int) -> bool:
	return swing_hits.has(victim_id)


func mark_hit(victim_id: int) -> void:
	swing_hits[victim_id] = true


## Updates what the snapshots see: health, state, respawn tick and the entity's action byte
## ([method NetEntity.set_health_view]). When downed, health is the downed health over
## [member CombatRules.downed_health] (docs/abilities.md, section 5.2): its quantized health is never 0.
func publish(tick: int) -> void:
	if is_downed():
		entity.set_health_view(downed_health, CombatCatalog.rules().downed_health, status_bits(tick), 0)
	else:
		entity.set_health_view(health, max_health, status_bits(tick),
				respawn_tick if health <= 0 else 0)
	var character: PlayerCharacter = entity.get_character()
	if character != null:
		entity.action = _action_wire.encode(character.combat, tick)
