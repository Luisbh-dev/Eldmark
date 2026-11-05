class_name CombatDirector
extends RefCounted
## A zone's combat on the server (docs/combat.md, sections 4.2 and 5): it keeps one
## [Combatant] per entity with a body and, once per tick, freezes, resolves, applies and publishes.
## [br][br]
## [method process_tick] is the tick's "combat" step (networking.md 8.1, after simulating all
## entities and before additions, history and snapshots), with steps 2 to 9 of the order in
## docs/abilities.md, section 4.1 (which completes docs/fortress.md, 1.7):
## [codeblock]
## 2 freeze      the current tick's sample of each entity (Combatant.freeze): position, turn, defense,
##               action, active hit (attack or ability), commitment and wall box
## 3 own         whoever is in their commitment, by net_id: the new projectiles of their attack or their
##               ability (ProjectileSystem.fire, with its SPAWN), the own effect (self_status) and the
##               own healing (HEAL) of their ability
## 4 resolve     CombatResolver.resolve: all the hits of attacks and abilities of the tick against the
##               frozen state and the history, and the gates; ProjectileSystem.resolve: the flight of all
##               live projectiles (also those of step 3) against the world, the gates, the shield
##               walls and the rewound characters, with the DESPAWNs of those that end
## 5 apply       by the attacker's net_id (first their hits, then their projectiles by id) and the
##               target's: damage (with the effects' modifiers), block stamina cost (the
##               wall's is the rules'), controls (with chain and immunity), effects on the target,
##               interruptions, hitstops and deaths, with their events
## 6 effects     StatusSystem.step: pulses (gathered before applying them) and expirations
## 7 downed      DownedSystem.step: bleeding out, new INTERACTs (lifting an ally, finishing off an
##               enemy) and the progress and end of lifting and finishing off
## 8 environment lethal volumes, fall damage, death below y = -100; requested respawns
##               (RESPAWN_REQUEST) and expired automatic ones, with the loadout template; the refill of
##               consumables at the camp (every 60 ticks)
## 9 publish     protection, regeneration and what the snapshots see (health, state, action)
## [/codeblock]
## A lethal hit from a player of another realm in an RvR zone does not kill a player: it leaves them knocked down
## ([DownedSystem], docs/abilities.md, section 4.5). A downed or dead entity in step 5 receives no further
## hits that tick.
## [br][br]
## [b]Templates[/b] (docs/abilities.md, section 4.6): [method equip_template] on spawn,
## [method _respawn] with the peer's pending one on each respawn, the camp refill and the commands
## 5 [code]set_weapon[/code] and 16 [code]refill[/code]; each change sends LOADOUT ([method announce_loadout]).
## Whoever has an inventory (docs/progression.md §4.1, §4.4 and §8, progression.md P5b) appears with their gear
## ([method equip_inventory]), respawns with it ([member loadout_source]) and replenishes their bag at the camp
## ([member camp_step]): their current template is 0.
## Any combat state the server imposes goes through
## [code]PlayerState.decode(PlayerState.encode())[/code] ([method commit_state]), the same rounding
## the client undergoes when reconciling.
## [br][br]
## It touches neither the network nor the clock: it announces events with [signal event_emitted] (the caller decides
## who they are sent to) and places bodies with the [Callable] [code]place[/code] that the server gives it.

## A combat event (HIT, DEATH, KILL, RESPAWN, STATUS, HEAL, LOADOUT, DOWNED or INTERACT) and the net_ids of
## the entities involved (victim, attacker, killer and assistants): their owners and anyone who has them as
## relevant receive it. LOADOUT goes out twice when weapons change (docs/abilities.md, section 5.4):
## with [param involved] = [code][jugador][/code] it is the owner's (with the charges) and with [param involved]
## empty, the public one (charges 0) for whoever has it as relevant.
signal event_emitted(event: NetMessages.EntityEvent, involved: PackedInt32Array)
## A hit has landed on a static target (a fort's gate) and removed [param amount] of
## health at tick [param tick]: its HIT has already been emitted. Picked up by the [FortressController].
signal structure_hit(target: StructureTarget, attacker: Combatant, amount: int, tick: int)

## Result of [method request_respawn].
enum RespawnRequestResult {
	## The request is recorded; it runs when the time comes.
	ACCEPTED,
	## Not dead (out of window).
	NOT_DEAD,
	## Dead, but still far from being able to respawn (out of window).
	TOO_EARLY,
}

## Below this height the character dies (falls out of the world).
const VOID_LIMIT_Y: float = -100.0
## How many ticks between consumable refills for whoever is at their realm's camp
## (docs/abilities.md, section 4.6).
const RECHARGE_INTERVAL_TICKS: int = 60
## [ServerMetrics] section for hit resolution (shape, line of sight and rewind).
const SECTION_RESOLVE: StringName = &"combat_resolve"
## [ServerMetrics] section for projectiles: shots (step 3) and flight (step 4); the budget is 1 ms
## with 64 players (docs/abilities.md, section 8).
const SECTION_PROJECTILES: StringName = &"combat_projectiles"
## Bits of [member NetMessages.EntityEvent.hit_flags] that the director sets.
const _HIT_CRITICAL: int = NetMessages.EntityEvent.HIT_FLAG_CRITICAL
const _HIT_BLOCKED: int = NetMessages.EntityEvent.HIT_FLAG_BLOCKED
const _HIT_PARRIED: int = NetMessages.EntityEvent.HIT_FLAG_PARRIED
const _HIT_GUARD_BREAK: int = NetMessages.EntityEvent.HIT_FLAG_GUARD_BREAK
const _HIT_LETHAL: int = NetMessages.EntityEvent.HIT_FLAG_LETHAL
const _HIT_INTERRUPTED: int = NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED
const _HIT_DOWNED: int = NetMessages.EntityEvent.HIT_FLAG_DOWNED

## Time limits in ticks (tests shorten them).
var timing: CombatTiming = CombatTiming.from_rules(CombatCatalog.rules())
var resolver: CombatResolver
## The zone's status effects (docs/abilities.md, section 4.3): their events go out through
## [signal event_emitted] and the director applies their damage pulses.
var status: StatusSystem = StatusSystem.new()
## The zone's projectiles (docs/abilities.md, section 4.4): their spawns and despawns go out through their signals
## [signal ProjectileSystem.spawned] and [signal ProjectileSystem.despawned]; the director
## applies their hits.
var projectiles: ProjectileSystem
## Knocked down, lifting and finishing off (docs/abilities.md, section 4.5): their events go out through
## [signal event_emitted] and the director applies their deaths.
var downed: DownedSystem = DownedSystem.new()
## Combat log file ([code]--combat-log[/code]); null = none.
var combat_log: FileAccess = null
## Server measurements (null = not measuring): the combat step measures hit resolution separately
## with rewind ([code]combat_resolve[/code]).
var metrics: ServerMetrics = null
## Counters for the run (for the report).
var stats: Dictionary[StringName, int] = {
	&"hits": 0, &"blocked": 0, &"parried": 0, &"guard_breaks": 0, &"invulnerable": 0,
	&"criticals": 0, &"rewind_rejected": 0, &"damage": 0, &"deaths": 0, &"kills": 0,
	&"respawns": 0, &"falls": 0, &"lethal_volumes": 0, &"voids": 0, &"events": 0,
	&"hit_tests": 0, &"resolve_us": 0, &"resolve_busy_ticks": 0, &"gate_hits": 0, &"gate_damage": 0,
	&"interrupts": 0, &"pulse_hits": 0, &"heals": 0, &"arrow_hits": 0, &"arrow_blocked": 0,
	&"wall_blocked": 0, &"projectile_us": 0, &"projectile_busy_ticks": 0, &"downed_hits": 0,
	&"recharges": 0, &"loadouts": 0,
}
## [code]() -> Dictionary[/code]: the live [FortressState]s by fortress id, to decide which respawn points
## are valid ([method RespawnRules.points_for]). Without this there are no fortresses.
var fortress_states: Callable = Callable()
## Inventory (docs/progression.md §4.1, §4.4 and §8; set by the [ZoneServer] with its [ProgressService]):
## [code](net_id: int) -> ProgressService.Loadout[/code], the gear that whoever has an inventory respawns with (null
## without one: the template, as always). With it, respawn looks at neither the template nor the peer's pending one.
var loadout_source: Callable = Callable()
## [code](entity: NetEntity, tick: int) -> void[/code]: CAMP_REFILL for whoever has an inventory ([method
## ProgressService.camp_step]); the camp refill calls it in place of the template's, with the same
## conditions (alive, out of combat and in their realm's safe zone) and the same cadence.
var camp_step: Callable = Callable()

var _history: StateHistory
var _zone_id: StringName
var _world: Node3D
var _place: Callable
var _pick_spawn: Callable
var _combatants: Dictionary[int, Combatant] = {}
var _sorted: Array[Combatant] = []
var _sorted_dirty: bool = false
# The zone's static list of respawn points (all of them, in scene order), read the
# first time.
var _all_respawn_points: Array[Node3D] = []
var _respawn_points_loaded: bool = false


## [param history] is the server's history, [param zone_id] the zone, [param world] its root
## (for the lethal volumes and the respawn points) and [param safe_areas] its safe zones.
## [param place] is
## [code](entity: NetEntity, position: Vector3, yaw: float) -> void] (places a body and raises its
## teleport counter) and [param pick_spawn] [code](realm: int) -> Transform3D] (a
## spawn point of the realm).
func _init(history: StateHistory, zone_id: StringName, world: Node3D, safe_areas: SafeAreas,
		place: Callable, pick_spawn: Callable) -> void:
	_history = history
	_zone_id = zone_id
	_world = world
	_place = place
	_pick_spawn = pick_spawn
	resolver = CombatResolver.new(history, zone_id, safe_areas)
	projectiles = ProjectileSystem.new(history, resolver)
	projectiles.status = status
	status.event_emitted.connect(_emit)
	status.pulse_damage.connect(_apply_pulse)
	downed.zone_id = zone_id
	downed.safe_areas = safe_areas
	downed.status = status
	downed.combatants = _combatants
	downed.event_emitted.connect(_on_downed_event)
	downed.killed.connect(_on_downed_killed)


## Rounds [param character]'s state the way the client would when reconciling (it goes through
## [code]encode/decode[/code]). It must be called after changing [member PlayerCharacter.combat] from
## outside the simulation.
static func commit_state(character: PlayerCharacter) -> void:
	character.set_state(PlayerState.decode(character.get_state().encode()))


# --- Additions and removals --------------------------------------------------------------------

## Registers the combat of [param entity] (with a node [PlayerCharacter]), its input queue
## and its peer (null if it is not a network player). It appears with maximum health.
func add(entity: NetEntity, queue: InputQueue, peer: ServerPeer) -> Combatant:
	var combatant := Combatant.new(entity, queue, peer, timing, CombatCatalog.rules().health_max)
	_combatants[entity.net_id] = combatant
	_sorted_dirty = true
	return combatant


## Removes [param net_id] at tick [param tick] and erases its trace from the others' damage logs (its id
## may be reused). Its arrows in the air go out with DESPAWN 5 and the effects it put on others are
## removed with STATUS 2, on that tick (docs/abilities.md, section 4.1).
func remove(net_id: int, tick: int) -> void:
	var leaving: Combatant = _combatants.get(net_id)
	if leaving == null:
		return
	_combatants.erase(net_id)
	_sorted_dirty = true
	downed.forget(net_id)
	projectiles.forget_owner(net_id, tick)
	leaving.effects.clear()
	status.forget_author(net_id, tick, get_sorted())
	for other: Combatant in _combatants.values():
		other.ledger.forget_attacker(net_id)
		if other.last_enemy_id == net_id:
			other.last_enemy_id = 0


## Removes everyone (server shutdown).
func clear() -> void:
	projectiles.clear()
	downed.clear()
	_combatants.clear()
	_sorted.clear()
	_sorted_dirty = false


## The combat of [param net_id], or null.
func get_combatant(net_id: int) -> Combatant:
	return _combatants.get(net_id)


## All combatants by ascending net_id (the array is replaced when the set changes).
func get_sorted() -> Array[Combatant]:
	if _sorted_dirty:
		var ids: Array[int] = []
		ids.assign(_combatants.keys())
		ids.sort()
		var rebuilt: Array[Combatant] = []
		for net_id: int in ids:
			rebuilt.append(_combatants[net_id])
		_sorted = rebuilt
		_sorted_dirty = false
	return _sorted


func size() -> int:
	return _combatants.size()


# --- The tick ----------------------------------------------------------------------------------

## The combat step of tick [param s] (steps 2 to 9 of docs/abilities.md, section 4.1): freezes,
## own commitment effects, resolves, applies, status effects, environment, respawns and
## publishing. [param space] is the world's physics space (line of sight).
func process_tick(s: int, space: PhysicsDirectSpaceState3D) -> void:
	var list: Array[Combatant] = get_sorted()
	if list.is_empty():
		return
	# Step 2: freeze.
	var committing: Array[Combatant] = []
	for combatant: Combatant in list:
		combatant.freeze(s)
		_count_swing(combatant)
		if combatant.frozen.commit:
			committing.append(combatant)
	projectiles.begin_tick(s, list)
	# Step 3: shots and own effects of whoever is in their commitment.
	if not committing.is_empty():
		_process_commits(s, committing, space)
	# Step 4: resolve the hits and the flight of the projectiles.
	if metrics != null:
		metrics.begin_section(SECTION_RESOLVE)
	var tests_before: int = resolver.tests
	var resolve_started: int = Time.get_ticks_usec()
	var hits: Array[CombatResolver.Hit] = resolver.resolve(s, list, space)
	if resolver.tests > tests_before:
		# Only ticks in which there was some hit to test count: that is what each check costs.
		stats[&"resolve_us"] += Time.get_ticks_usec() - resolve_started
		stats[&"resolve_busy_ticks"] += 1
	if metrics != null:
		metrics.end_section(SECTION_RESOLVE)
	stats[&"hit_tests"] = resolver.tests
	if projectiles.live_count() > 0 or projectiles.has_pending():
		if metrics != null:
			metrics.begin_section(SECTION_PROJECTILES)
		var flight_started: int = Time.get_ticks_usec()
		var arrow_hits: Array[CombatResolver.Hit] = projectiles.resolve(s, list, space)
		stats[&"projectile_us"] += Time.get_ticks_usec() - flight_started
		stats[&"projectile_busy_ticks"] += 1
		if metrics != null:
			metrics.end_section(SECTION_PROJECTILES)
		hits = ProjectileSystem.merge_by_attacker(hits, arrow_hits)
	# Step 5: apply, by the attacker's net_id (first their hits, then their projectiles by id) and the
	# target's.
	for hit: CombatResolver.Hit in hits:
		_apply_hit(hit, s)
	# Step 6: status effects (pulses and expirations).
	status.step(s, list)
	# Step 7: downed (bleeding out, new INTERACTs, lifting and finishing off).
	downed.step(s, list, space)
	# Step 8: environment, respawns and consumable refill at the camp.
	_process_environment(s, list)
	_process_respawns(s, list)
	_process_recharge(s, list)
	# Step 9: publish.
	var regen: int = CombatCatalog.rules().health_regen_per_s
	for combatant: Combatant in list:
		if combatant.is_protected(s) and _started_attack(combatant):
			# Attacking (or casting an ability) loses respawn protection.
			combatant.protected_until = s
		combatant.regenerate(s, regen)
		combatant.publish(s)


# --- Actions from outside the simulation -------------------------------------------------------

## Kills [param combatant] now (debug command, fall...) with no author; also a downed one. It does
## nothing if already dead or a dummy. [param tick] is the tick at which the death is recorded.
func kill(combatant: Combatant, tick: int) -> void:
	if combatant.is_dead() or combatant.immortal:
		return
	_die(combatant, tick, 0, 0)


## Fully heals [param combatant] (debug command). Does not heal a dead or downed one.
func heal(combatant: Combatant) -> void:
	if combatant.is_alive():
		combatant.heal_full()


## Sets or removes [param combatant]'s infinite stamina (debug command).
func set_infinite_stamina(combatant: Combatant, enabled: bool) -> void:
	var character: PlayerCharacter = combatant.get_character()
	if enabled:
		character.combat.combat_flags |= CombatState.FLAG_INFINITE_STAMINA
	else:
		character.combat.combat_flags &= ~CombatState.FLAG_INFINITE_STAMINA
	commit_state(character)


## Removes or restores the cooldowns and charge spending of [param combatant] (command 13
## [code]cooldowns_off[/code]: bit 7 of [member CombatState.combat_flags2]).
func set_cooldowns_off(combatant: Combatant, enabled: bool) -> void:
	var character: PlayerCharacter = combatant.get_character()
	if enabled:
		character.combat.combat_flags2 |= CombatState.FLAG2_NO_COOLDOWNS
	else:
		character.combat.combat_flags2 &= ~CombatState.FLAG2_NO_COOLDOWNS
	commit_state(character)


## Applies to [param combatant] the catalog effect [param status_id] at tick [param tick], with no author,
## for [param duration_ticks] ticks (0 = the data's): command 14 [code]apply_status[/code].
## Returns false if the effect does not exist or it is not alive (dead or downed).
func apply_status(combatant: Combatant, status_id: int, tick: int, duration_ticks: int = 0) -> bool:
	if CombatCatalog.status(status_id) == null or not combatant.is_alive():
		return false
	return status.apply(combatant, status_id, 0, tick, duration_ticks)


## Sets the catalog weapon [param weapon_id] in slot 1 of [param combatant] (command 5
## [code]set_weapon[/code], docs/abilities.md, section 3.5): [method ActionMachine.set_loadout] with the one in
## slot 2 it had (none if it is the same) and its charges; on a living one, NONE first. With
## [param tick] ≥ 0 it sends LOADOUT to the owner and to whoever has it as relevant (a freshly created NPC does not
## need it: its SPAWN already carries the weapon). Returns false if the weapon does not exist or it is knocked down.
func set_weapon(combatant: Combatant, weapon_id: int, tick: int = -1) -> bool:
	if CombatCatalog.weapon(weapon_id) == null or combatant.is_downed():
		return false
	var character: PlayerCharacter = combatant.get_character()
	var combat: CombatState = character.combat
	var pair: PackedInt32Array = weapons_in_slot_order(combat)
	var second: int = pair[1] if pair[1] != weapon_id else 0
	ActionMachine.set_loadout(combat, weapon_id, second, combat.consumable_charges)
	commit_state(character)
	if tick >= 0:
		announce_loadout(combatant, tick, pair != weapons_in_slot_order(combat))
	return true


## The weapons of [param combat] in slot order: [code][ranura 1, ranura 2][/code] (0 = none).
static func weapons_in_slot_order(combat: CombatState) -> PackedInt32Array:
	if combat.is_second_slot():
		return PackedInt32Array([combat.alt_weapon_id, combat.weapon_id])
	return PackedInt32Array([combat.weapon_id, combat.alt_weapon_id])


## The template that applies for [param requested] (docs/abilities.md, section 4.6): itself if it exists; the
## default ([member CombatRules.default_template]) with 0 or one that does not exist. 0 if there is none.
static func resolve_template(requested: int) -> int:
	if requested > 0 and CombatCatalog.template(requested) != null:
		return requested
	return CombatCatalog.default_template_id()


## Equips [param combatant] with template [param template_id] (0 = the default) on first appearing
## ([method ActionMachine.set_loadout]: its weapons, the 1st active, and its charges). With [param tick] ≥ 0
## it sends LOADOUT ([method announce_loadout]); the [ZoneServer] sends it itself after the SPAWN. Returns the id of the
## template applied (0 if there is none).
func equip_template(combatant: Combatant, template_id: int, tick: int = -1) -> int:
	var resolved: int = resolve_template(template_id)
	if resolved <= 0:
		return 0
	var weapons: PackedInt32Array = CombatCatalog.template_weapons(resolved)
	if weapons.is_empty():
		return 0
	combatant.template_id = resolved
	var character: PlayerCharacter = combatant.get_character()
	ActionMachine.set_loadout(character.combat, weapons[0], weapons[1] if weapons.size() > 1 else 0,
			CombatCatalog.template_charges(resolved))
	commit_state(character)
	if tick >= 0:
		announce_loadout(combatant, tick, true)
	return resolved


## Equips [param combatant] with the gear from its inventory (docs/progression.md §8) on first appearing:
## [method ActionMachine.set_loadout] with [param weapon_1] and [param weapon_2] (the gear's slots 0 and 1; 0 =
## empty) and [param charges] and, with [param second_active], [method ActionMachine.set_weapons] with slot 1 active
## (no cooldowns). The current template becomes 0 ("the inventory's gear" in LOADOUT). With [param tick] ≥ 0
## it sends LOADOUT, like [method equip_template].
func equip_inventory(combatant: Combatant, weapon_1: int, weapon_2: int, second_active: bool, charges: int,
		tick: int = -1) -> void:
	combatant.template_id = 0
	var character: PlayerCharacter = combatant.get_character()
	ActionMachine.set_loadout(character.combat, weapon_1, weapon_2, charges)
	if second_active:
		ActionMachine.set_weapons(character.combat, weapon_1, weapon_2, true, PackedInt64Array(), PackedInt64Array())
	commit_state(character)
	if tick >= 0:
		announce_loadout(combatant, tick, true)


## LOADOUT of [param combatant] at [param tick] (docs/abilities.md, section 5.4): its template, its weapons
## in slot order and its charges to the owner; with [param public], also the same without charges to whoever has it
## as relevant (when weapons change).
func announce_loadout(combatant: Combatant, tick: int, public: bool) -> void:
	var combat: CombatState = combatant.get_character().combat
	var pair: PackedInt32Array = weapons_in_slot_order(combat)
	var player_id: int = combatant.get_id()
	stats[&"loadouts"] += 1
	_emit(NetMessages.EntityEvent.loadout(player_id, tick, combatant.template_id, pair[0], pair[1],
			combat.consumable_charges), _ids([player_id]))
	if public:
		_emit(NetMessages.EntityEvent.loadout(player_id, tick, combatant.template_id, pair[0], pair[1], 0),
				PackedInt32Array())


## Replenishes the consumable charges of [param combatant] to those of its template (command 16
## [code]refill[/code]): [method ActionMachine.set_charges], which does not touch weapon, cooldowns, slots or the
## action in progress, and LOADOUT to the owner. Returns false if not alive or it has no template.
func refill(combatant: Combatant, tick: int) -> bool:
	if not combatant.is_alive() or combatant.template_id <= 0:
		return false
	var character: PlayerCharacter = combatant.get_character()
	ActionMachine.set_charges(character.combat, CombatCatalog.template_charges(combatant.template_id))
	commit_state(character)
	announce_loadout(combatant, tick, false)
	return true


## Knocks down [param combatant] at [param tick] as if an enemy had knocked it down, with no author (command 15
## [code]down[/code], docs/abilities.md, section 4.5): on bleeding out, DEATH without KILL. Returns false outside
## RvR zones, in its realm's safe zone, if it is not a living player or if it is a dummy.
func down(combatant: Combatant, tick: int) -> bool:
	if not downed.is_enabled() or not combatant.is_alive() or combatant.immortal \
			or combatant.entity.kind != NetProtocol.EntityKind.PLAYER:
		return false
	var safe: SafeAreas = resolver.get_safe_areas()
	if safe != null and safe.contains_own(combatant.get_realm(), combatant.entity.get_position()):
		return false
	downed.down(combatant, 0, CombatSource.NONE, tick)
	_log_line(tick, 0, combatant.get_id(), "down", float(tick), 0.0, "downed", 0)
	return true


## Kills at [param tick] a knocked-down player who leaves the zone (exit, disconnection, [code]--fake-churn[/code],
## end of the body from GUE-41; docs/abilities.md, section 4.5): DEATH and KILL with the killer from
## [method DownedSystem.killer_of] and the source "bleeding out". It does nothing if not knocked down.
func kill_downed(combatant: Combatant, tick: int) -> void:
	if combatant == null or not combatant.is_downed():
		return
	downed.stats[&"bled_out"] += 1
	_on_downed_killed(combatant, downed.killer_of(combatant), CombatSource.BLEED_OUT, tick)


## Records a respawn request from [param net_id] at point [param point_index] of the zone's static
## list ([method get_all_respawn_points]), requested when the server is about to simulate tick
## [param tick]. An index that is no longer valid for its realm is not an error: on respawning, the first valid
## camp is used (the client's state lags behind). Returns whether it is accepted or why it is out of
## window.
func request_respawn(net_id: int, point_index: int, tick: int) -> int:
	var combatant: Combatant = _combatants.get(net_id)
	if combatant == null or not combatant.is_dead():
		return RespawnRequestResult.NOT_DEAD
	if tick + CombatTiming.RESPAWN_REQUEST_SLACK_TICKS < combatant.respawn_tick:
		return RespawnRequestResult.TOO_EARLY
	combatant.pending_respawn_point = point_index
	return RespawnRequestResult.ACCEPTED


## Emits an event that does not come from combat proper (the [code]TELEGRAPH[/code] warning of an NPC's heavy
## attack) through the same channel as the others: [signal event_emitted], with [param involved] as recipients.
func emit_event(event: NetMessages.EntityEvent, involved: PackedInt32Array) -> void:
	_emit(event, involved)


## Sets the zone's static targets (the forts' gates): the resolver tests them for
## each active attack.
func set_structure_targets(targets: Array[StructureTarget]) -> void:
	resolver.structure_targets = targets


## All the zone's respawn points, in scene order ([method
## NetZones.get_all_respawn_points]): the [b]static[/b] list the index of
## RESPAWN_REQUEST and RESPAWN refers to. Which points are valid for a player is given by [method get_valid_respawn_points].
func get_all_respawn_points() -> Array[Node3D]:
	if not _respawn_points_loaded:
		_all_respawn_points = NetZones.get_all_respawn_points(_world)
		_respawn_points_loaded = true
	return _all_respawn_points


## Indices (of the static list) of the points where a player of realm
## [param realm] can respawn at tick [param tick] ([method RespawnRules.points_for]): their camp and the
## forts of their realm in GARRISONED that are not under attack.
func get_valid_respawn_points(realm: int, tick: int) -> PackedInt32Array:
	var states: Dictionary = {}
	if fortress_states.is_valid():
		states = fortress_states.call()
	return RespawnRules.points_for(realm, get_all_respawn_points(), states, tick)


# --- Applying the hits -------------------------------------------------------------------------

func _apply_hit(hit: CombatResolver.Hit, s: int) -> void:
	var attacker: Combatant = hit.attacker
	if hit.outcome == CombatResolver.Outcome.REWIND_REJECTED:
		stats[&"rewind_rejected"] += 1
		_log_hit(s, hit, "rewind_rejected", 0)
		return
	if hit.outcome == CombatResolver.Outcome.STRUCTURE:
		_apply_structure_hit(hit, s)
		return
	var victim: Combatant = hit.victim
	if hit.outcome == CombatResolver.Outcome.INVULNERABLE:
		stats[&"invulnerable"] += 1
		_log_hit(s, hit, "invulnerable", 0)
		return
	if victim.is_dead() or victim.downed_tick == s:
		# Died or was knocked down earlier in this same tick (another simultaneous hit): all were resolved
		# against the same state and its turn has passed (docs/abilities.md, section 4.1).
		return
	_note_landed(hit)
	attacker.mark_combat(s)
	victim.mark_combat(s)
	if victim.is_downed():
		_apply_downed_impact(hit, s)
		return
	if hit.outcome == CombatResolver.Outcome.PARRIED:
		_apply_parry(hit, s)
		return
	_apply_impact(hit, s)


# Hit on a fort's gate (docs/fortress.md, 3.3): formula damage (no critical or defense) times the
# structure multiplier of its damage type, minimum 1 if anything is left, not exceeding the health it has
# left. HIT with the fortress's net_id for the attacker (and whoever has it as relevant); the attacker
# becomes "in combat".
func _apply_structure_hit(hit: CombatResolver.Hit, s: int) -> void:
	var attacker: Combatant = hit.attacker
	var target: StructureTarget = hit.structure
	var attack: AttackTicks = hit.attack
	if not target.can_be_hit_by(attacker.get_realm()):
		# Another hit on this same tick broke it, or the fort changed hands.
		return
	var rules: CombatRules = CombatCatalog.rules()
	var result: DamageFormula.Result = DamageFormula.compute(attack.base_damage,
			_charge_of(hit), attack.charge_min_ticks, attack.charge_max_ticks,
			attack.charge_damage_scale, false, false, 0.0, 0.0, 0, 0, rules.crit_multiplier)
	var scaled: int = roundi(float(result.damage) * rules.structure_multiplier(attack.damage_type))
	if result.damage > 0:
		scaled = maxi(scaled, 1)
	var health_before: int = target.state.gate_health
	var applied: int = mini(scaled, health_before)
	if applied <= 0:
		return
	_note_landed(hit)
	attacker.mark_combat(s)
	stats[&"gate_hits"] += 1
	stats[&"gate_damage"] += applied
	var flags: int = _HIT_LETHAL if applied >= health_before else 0
	_emit(NetMessages.EntityEvent.hit(target.net_id, s, attacker.get_id(), applied,
			attack.damage_type, flags, attack.id), _ids([attacker.get_id()]))
	structure_hit.emit(target, attacker, applied, s)
	_log_hit(s, hit, "gate", applied)


# Parry: no damage and the attacker is left staggering.
func _apply_parry(hit: CombatResolver.Hit, s: int) -> void:
	var attacker: Combatant = hit.attacker
	var victim: Combatant = hit.victim
	stats[&"parried"] += 1
	if attacker.is_alive() and attacker.try_control(s):
		var character: PlayerCharacter = attacker.get_character()
		ActionMachine.impose_stagger(character.combat, s, s + timing.parry_stagger, Vector2.ZERO)
		commit_state(character)
	_emit(NetMessages.EntityEvent.hit(victim.get_id(), s, attacker.get_id(), 0,
			hit.attack.damage_type, _HIT_PARRIED, hit.attack.id),
			_ids([victim.get_id(), attacker.get_id()]))
	_log_hit(s, hit, "parried", 0)


# Impact, with or without block. An ability's hit ([member AbilityTicks.hit]) follows the same
# path as an attack (docs/abilities.md, section 4.2): its id is the ability's source. A
# projectile's (docs/abilities.md, section 4.4) too, with the charge and the extra damage it copied on launch; the
# shield wall's box blocks it on behalf of whoever holds it without damage (mitigation 1) and with the wall's cost.
func _apply_impact(hit: CombatResolver.Hit, s: int) -> void:
	var attacker: Combatant = hit.attacker
	var victim: Combatant = hit.victim
	var attack: AttackTicks = hit.attack
	var rules: CombatRules = CombatCatalog.rules()
	var blocked: bool = hit.outcome == CombatResolver.Outcome.BLOCKED
	var victim_character: PlayerCharacter = victim.get_character()
	var weapon: WeaponTicks = CombatCatalog.weapon(victim.frozen.weapon_id)
	var mitigation: float = 0.0
	var stamina_per_damage: float = 0.0
	if blocked:
		mitigation = 1.0 if hit.wall or weapon == null else weapon.block_mitigation
		# The shield wall spends what the rules say, not the weapon's.
		stamina_per_damage = rules.ability_block_stamina_per_damage if hit.wide_block or weapon == null \
				else weapon.block_stamina_per_damage
	var scale: float = hit.projectile.damage_scale if hit.projectile != null \
			else status.damage_scale(attacker)
	var result: DamageFormula.Result = DamageFormula.compute(attack.base_damage,
			_charge_of(hit), attack.charge_min_ticks, attack.charge_max_ticks,
			attack.charge_damage_scale, hit.critical, blocked, mitigation, stamina_per_damage,
			victim_character.combat.stamina, 0, rules.crit_multiplier,
			scale, status.mitigation_penalty(victim))
	var applied: int = victim.take_damage(result.damage, s)
	victim.ledger.record(s, attacker.get_id(), applied)
	victim.note_enemy_hit(attacker.get_id(), attack.id, s)
	var flags: int = 0
	if hit.critical:
		flags |= _HIT_CRITICAL
		stats[&"criticals"] += 1
	var changed: bool = false
	if blocked:
		flags |= _HIT_BLOCKED
		stats[&"blocked"] += 1
		if result.stamina_cost > 0:
			ActionMachine.drain_stamina(victim_character.combat, result.stamina_cost, s)
			changed = true
		if result.guard_break:
			flags |= _HIT_GUARD_BREAK
			stats[&"guard_breaks"] += 1
			if victim.is_alive() and victim.try_control(s):
				ActionMachine.impose_stun(victim_character.combat, s, s + timing.guard_break_stun)
				changed = true
	else:
		changed = _apply_hit_controls(hit, s)
	stats[&"hits"] += 1
	stats[&"damage"] += applied
	var lethal: bool = victim.is_dead()
	# A lethal hit from a player of another realm in an RvR zone knocks down (docs/abilities.md, section 4.5): the
	# arrow carries the author's copy (their realm and whether they are a player), even if the shooter is no longer standing.
	var downs: bool = lethal and downed.should_down(victim, _author_realm(hit), _author_is_player(hit))
	if downs:
		flags |= _HIT_DOWNED
	elif lethal:
		flags |= _HIT_LETHAL
	# An immortal dummy announces the full damage (the DPS meter counts it in full).
	var amount: int = result.damage if victim.immortal else applied
	# Interruption (docs/abilities.md, section 4.2): an impact with damage from a hostile cuts drinking, a marked
	# cast, lifting or finishing off, if the hit has not already imposed a control.
	if not lethal and not changed and hit.outcome == CombatResolver.Outcome.IMPACT and amount > 0 \
			and _interrupt(victim_character.combat, s):
		flags |= _HIT_INTERRUPTED
		changed = true
	_emit(NetMessages.EntityEvent.hit(victim.get_id(), s, attacker.get_id(), amount,
			attack.damage_type, flags, attack.id), _ids([victim.get_id(), attacker.get_id()]))
	_log_hit(s, hit, _impact_result(hit, blocked, flags), amount)
	if downs:
		downed.down(victim, attacker.get_id(), attack.id, s)
		_log_hit(s, hit, "downed", 0)
		return
	if lethal:
		_die(victim, s, attacker.get_id(), attack.id)
		return
	if changed:
		commit_state(victim_character)
	# The hit's effect on the target, only on an impact.
	if hit.outcome == CombatResolver.Outcome.IMPACT and attack.on_hit_status_id != 0:
		status.apply(victim, attack.on_hit_status_id, attacker.get_id(), s)


# Hit on a knocked-down player (docs/abilities.md, section 4.5): the formula damage (with the charge and the extra damage,
# no block possible) takes away its downed health; no controls, effects or interruptions. At 0, it dies: the
# killer is whoever finished it off with damage.
func _apply_downed_impact(hit: CombatResolver.Hit, s: int) -> void:
	var attacker: Combatant = hit.attacker
	var victim: Combatant = hit.victim
	var attack: AttackTicks = hit.attack
	var rules: CombatRules = CombatCatalog.rules()
	var scale: float = hit.projectile.damage_scale if hit.projectile != null \
			else status.damage_scale(attacker)
	var result: DamageFormula.Result = DamageFormula.compute(attack.base_damage, _charge_of(hit),
			attack.charge_min_ticks, attack.charge_max_ticks, attack.charge_damage_scale, hit.critical, false,
			0.0, 0.0, 0, 0, rules.crit_multiplier, scale, 0.0)
	var applied: int = victim.take_downed_damage(result.damage, s)
	victim.ledger.record(s, attacker.get_id(), applied)
	victim.note_enemy_hit(attacker.get_id(), attack.id, s)
	var flags: int = _HIT_CRITICAL if hit.critical else 0
	if hit.critical:
		stats[&"criticals"] += 1
	var lethal: bool = victim.downed_health <= 0
	if lethal:
		flags |= _HIT_LETHAL
	stats[&"hits"] += 1
	stats[&"downed_hits"] += 1
	stats[&"damage"] += applied
	_emit(NetMessages.EntityEvent.hit(victim.get_id(), s, attacker.get_id(), applied, attack.damage_type,
			flags, attack.id), _ids([victim.get_id(), attacker.get_id()]))
	_log_hit(s, hit, "arrow_hit" if hit.projectile != null else "hit", applied)
	if lethal:
		_die(victim, s, attacker.get_id(), attack.id)


# Realm of [param hit]'s author and whether they are a player: those of the projectile's copy or the attacker's.
static func _author_realm(hit: CombatResolver.Hit) -> int:
	return hit.projectile.realm if hit.projectile != null else hit.attacker.get_realm()


static func _author_is_player(hit: CombatResolver.Hit) -> bool:
	if hit.projectile != null:
		return hit.projectile.is_player
	return hit.attacker.entity != null and hit.attacker.entity.kind == NetProtocol.EntityKind.PLAYER


# Control from the hit, except with poise on the active hit and respecting the chain: stun if the
# hit carries it ([member AttackTicks.stun_ticks], the shield bash) and, if not, stagger and radial
# push. Returns true if it imposed the control (and the state must go through encode/decode).
func _apply_hit_controls(hit: CombatResolver.Hit, s: int) -> bool:
	var victim: Combatant = hit.victim
	var attack: AttackTicks = hit.attack
	if attack.stagger_ticks <= 0 and attack.stun_ticks <= 0:
		return false
	if victim.is_dead() or victim.frozen.hyper_armor:
		return false
	if not victim.try_control(s):
		return false
	var combat: CombatState = victim.get_character().combat
	if attack.stun_ticks > 0:
		ActionMachine.impose_stun(combat, s, s + attack.stun_ticks)
		return true
	var away := Vector2(victim.frozen.position.x - hit.attacker.frozen.position.x,
			victim.frozen.position.z - hit.attacker.frozen.position.z)
	if hit.projectile != null:
		# A projectile's pushes toward where it flies.
		away = Vector2(hit.direction.x, hit.direction.z)
	var knockback := Vector2.ZERO
	if attack.knockback_speed > 0.0 and away.length() > 0.0001:
		knockback = away.normalized() * attack.knockback_speed
	ActionMachine.impose_stagger(combat, s, s + attack.stagger_ticks, knockback)
	return true


# Cuts what [param combat] is doing at [param s] if an impact interrupts it: phase 0 (the cast,
# [code][0, cast)[/code]) of a consumable or of an ability with [member AbilityTicks.interrupt_on_damage],
# REVIVE or EXECUTE. Not after the commitment: the charge and the healing are already applied. Returns true if
# it interrupted.
func _interrupt(combat: CombatState, s: int) -> bool:
	if not is_interruptible(combat, s):
		return false
	ActionMachine.impose_interrupt(combat, s)
	stats[&"interrupts"] += 1
	return true


## true if an impact with damage from a hostile would cut what [param combat] is doing at [param tick]
## (docs/abilities.md, section 4.2): the cast of a consumable or of an ability with
## [member AbilityTicks.interrupt_on_damage], lifting or finishing off.
static func is_interruptible(combat: CombatState, tick: int) -> bool:
	match combat.action:
		CombatState.Action.REVIVE, CombatState.Action.EXECUTE:
			return true
		CombatState.Action.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(combat.action_id)
			return ability != null and (ability.is_consumable() or ability.interrupt_on_damage) \
					and tick - combat.action_tick < ability.cast_ticks
	return false


# --- Status effects ----------------------------------------------------------------------------

# Step 3, on whoever is in their commitment ([param list], by net_id): an attack or an ability with a
# projectile fires (docs/abilities.md, section 4.4: [method ProjectileSystem.fire] against [param space]),
# and an ability's (the first active tick) puts on its own effect
# ([member AbilityTicks.self_status_id], the potion's healing) and heals [member AbilityTicks.self_heal].
# Once: the commitment falls in a single tick.
func _process_commits(s: int, list: Array[Combatant], space: PhysicsDirectSpaceState3D) -> void:
	for combatant: Combatant in list:
		var frame: Combatant.Frozen = combatant.frozen
		if not frame.commit or combatant.is_dead():
			continue
		if frame.action != CombatState.Action.ABILITY:
			# LIGHT or HEAVY: its active hit in the commitment is the attack itself.
			if frame.hit != null and frame.hit.projectile_id != 0:
				_fire(combatant, frame.hit.id, s, space)
			continue
		var ability: AbilityTicks = CombatCatalog.ability(frame.action_id)
		if ability == null:
			continue
		if ability.projectile_id != 0:
			_fire(combatant, ability.hit.id, s, space)
		if ability.self_status_id != 0:
			status.apply(combatant, ability.self_status_id, combatant.get_id(), s)
		if ability.self_heal > 0:
			if status.heal(combatant, combatant.get_id(), ability.self_heal,
					CombatSource.make(CombatSource.Kind.ABILITY, ability.id), s) > 0:
				stats[&"heals"] += 1


# The projectiles of [param shooter]'s source [param source], measured in the projectiles section.
func _fire(shooter: Combatant, source: int, s: int, space: PhysicsDirectSpaceState3D) -> void:
	if metrics != null:
		metrics.begin_section(SECTION_PROJECTILES)
	var started: int = Time.get_ticks_usec()
	projectiles.fire(shooter, source, s, space)
	stats[&"projectile_us"] += Time.get_ticks_usec() - started
	if metrics != null:
		metrics.end_section(SECTION_PROJECTILES)


# A damage-over-time pulse ([signal StatusSystem.pulse_damage]): HIT with the effect's source and the
# effect's author as attacker, no block or critical, with the author's extra damage. It can kill or, if the
# author is a player of another realm still in the zone, knock down; it does not interrupt or impose controls.
func _apply_pulse(target: Combatant, author_id: int, effect: StatusTicks, amount: int, s: int) -> void:
	if not target.is_alive() or target.is_gm_invisible():
		return
	var author: Combatant = _combatants.get(author_id) if author_id > 0 else null
	var rules: CombatRules = CombatCatalog.rules()
	var result: DamageFormula.Result = DamageFormula.compute(amount, 0, 0, 0, 1.0, false, false, 0.0,
			0.0, 0, 0, rules.crit_multiplier, status.damage_scale(author), 0.0)
	var applied: int = target.take_damage(result.damage, s)
	var source: int = CombatSource.make(CombatSource.Kind.STATUS, effect.id)
	var attacker_id: int = author.get_id() if author != null else 0
	target.mark_combat(s)
	if author != null and author != target:
		author.mark_combat(s)
		target.ledger.record(s, attacker_id, applied)
		target.note_enemy_hit(attacker_id, source, s)
	stats[&"pulse_hits"] += 1
	stats[&"damage"] += applied
	var lethal: bool = target.is_dead()
	var downs: bool = lethal and author != null and downed.should_down(target, author.get_realm(),
			author.entity.kind == NetProtocol.EntityKind.PLAYER)
	var flags: int = 0
	if downs:
		flags = _HIT_DOWNED
	elif lethal:
		flags = _HIT_LETHAL
	var shown: int = result.damage if target.immortal else applied
	_emit(NetMessages.EntityEvent.hit(target.get_id(), s, attacker_id, shown, effect.damage_type,
			flags, source), _ids([target.get_id(), attacker_id]))
	_log_line(s, attacker_id, target.get_id(), CombatSource.name_of(source), float(s), 0.0, "pulse",
			shown)
	if downs:
		downed.down(target, attacker_id, source, s)
		_log_line(s, attacker_id, target.get_id(), CombatSource.name_of(source), float(s), 0.0, "downed", 0)
	elif lethal:
		_die(target, s, attacker_id, source)


# --- Knocked down ------------------------------------------------------------------------------

# A DownedSystem event (DOWNED or INTERACT): to the combat log (lifted) and to the network.
func _on_downed_event(event: NetMessages.EntityEvent, involved: PackedInt32Array) -> void:
	if event.event == NetMessages.EntityEvent.Kind.INTERACT \
			and event.op == NetMessages.EntityEvent.InteractOp.REVIVED:
		_log_line(event.tick, event.actor, event.net_id, "levantar", float(event.tick), 0.0, "revived", 0)
	_emit(event, involved)


# A knocked-down player dies without a hit ([signal DownedSystem.killed]): bled out, finished off or on leaving.
func _on_downed_killed(victim: Combatant, killer_id: int, source: int, s: int) -> void:
	_log_line(s, killer_id, victim.get_id(), CombatSource.name_of(source), float(s), 0.0,
			"executed" if source == CombatSource.EXECUTE else "bled_out", 0)
	_die(victim, s, killer_id, source)


# --- Death -------------------------------------------------------------------------------------

# Death of [param victim] by [param killer_id] (0 = the environment) with [param attack_id]: DEAD
# action, a single DEATH and, if there is an author, a KILL with the assistants from the damage log. A knocked-down
# player stops being so.
func _die(victim: Combatant, s: int, killer_id: int, attack_id: int) -> void:
	if victim.immortal or victim.death_tick >= 0:
		return
	downed.release(victim)
	victim.mark_dead(s, killer_id, attack_id)
	var character: PlayerCharacter = victim.get_character()
	ActionMachine.impose_death(character.combat, s)
	# On dying, all its effects are removed, without STATUS: DEATH clears them on the client.
	status.clear(victim)
	commit_state(character)
	stats[&"deaths"] += 1
	var victim_id: int = victim.get_id()
	_emit(NetMessages.EntityEvent.death(victim_id, s, killer_id, attack_id),
			_ids([victim_id, killer_id]))
	if killer_id != 0:
		var assistants: PackedInt32Array = victim.ledger.get_assistants(killer_id, s)
		var involved: Array[int] = [victim_id, killer_id]
		for assistant: int in assistants:
			involved.append(assistant)
		stats[&"kills"] += 1
		_emit(NetMessages.EntityEvent.kill(victim_id, s, killer_id, attack_id, assistants),
				_ids(involved))


# Death or damage from the environment: the author is the last enemy that hit within the last 10 s; for a downed player,
# the one from [method DownedSystem.killer_of] (whoever damaged them while already downed or whoever downed them).
func _credited_killer(victim: Combatant, s: int) -> int:
	if victim.is_downed():
		return downed.killer_of(victim)
	if not victim.has_recent_enemy(s):
		return 0
	var enemy: Combatant = _combatants.get(victim.last_enemy_id)
	return victim.last_enemy_id if enemy != null else 0


# --- Environment -------------------------------------------------------------------------------

func _process_environment(s: int, list: Array[Combatant]) -> void:
	var rules: CombatRules = CombatCatalog.rules()
	var volumes: Array[Node3D] = NetZones.get_lethal_volumes(_world)
	for combatant: Combatant in list:
		if combatant.is_dead() or combatant.immortal:
			continue
		var character: PlayerCharacter = combatant.get_character()
		# An invisible GM takes no damage (docs/platform.md §9.1): neither lethal volumes nor falls; the void does apply, which
		# only returns the body to the world.
		var invisible: bool = combatant.is_gm_invisible()
		if not invisible and _in_lethal_volume(character, volumes):
			stats[&"lethal_volumes"] += 1
			_die(combatant, s, _credited_killer(combatant, s), 0)
			continue
		var position: Vector3 = combatant.entity.get_position()
		if not position.is_finite() or position.y < VOID_LIMIT_Y:
			stats[&"voids"] += 1
			_die_in_the_void(combatant, s)
			continue
		var speed: float = character.last_landing_speed
		if not invisible and speed > rules.fall_damage_threshold:
			_apply_fall(combatant, s, roundi((speed - rules.fall_damage_threshold)
					* float(rules.fall_damage_per_mps)))


func _in_lethal_volume(character: PlayerCharacter, volumes: Array[Node3D]) -> bool:
	for node: Node3D in volumes:
		var area: Area3D = node as Area3D
		if area != null and area.monitoring and area.overlaps_body(character):
			return true
	return false


# Death below the world limit: DEAD and the body returns to a spawn point of its realm (with
# teleport counter) and stays there, with no velocity, until respawning.
func _die_in_the_void(combatant: Combatant, s: int) -> void:
	var killer: int = _credited_killer(combatant, s)
	var character: PlayerCharacter = combatant.get_character()
	downed.release(combatant)
	combatant.mark_dead(s, killer, 0)
	ActionMachine.impose_death(character.combat, s)
	status.clear(combatant)
	stats[&"deaths"] += 1
	var spawn: Transform3D = _pick_spawn.call(combatant.get_realm())
	_place.call(combatant.entity, spawn.origin, _yaw_of(spawn))
	var victim_id: int = combatant.get_id()
	_emit(NetMessages.EntityEvent.death(victim_id, s, killer, 0), _ids([victim_id, killer]))
	if killer != 0:
		var assistants: PackedInt32Array = combatant.ledger.get_assistants(killer, s)
		var involved: Array[int] = [victim_id, killer]
		for assistant: int in assistants:
			involved.append(assistant)
		stats[&"kills"] += 1
		_emit(NetMessages.EntityEvent.kill(victim_id, s, killer, 0, assistants), _ids(involved))


# Fall damage: environment HIT (attacker 0); if it kills, the death is credited to the last enemy. For a
# downed player it removes downed health (never knocks down: the fall is the environment's).
func _apply_fall(combatant: Combatant, s: int, damage: int) -> void:
	if damage <= 0:
		return
	var was_downed: bool = combatant.is_downed()
	var applied: int = combatant.take_downed_damage(damage, s) if was_downed \
			else combatant.take_damage(damage, s)
	combatant.mark_combat(s)
	stats[&"falls"] += 1
	stats[&"damage"] += applied
	var lethal: bool = combatant.downed_health <= 0 if was_downed else combatant.is_dead()
	_emit(NetMessages.EntityEvent.hit(combatant.get_id(), s, 0, applied, DamageFormula.DamageType.BLUNT,
			_HIT_LETHAL if lethal else 0, 0), _ids([combatant.get_id()]))
	if lethal:
		_die(combatant, s, _credited_killer(combatant, s), 0)


# --- Respawn -----------------------------------------------------------------------------------

func _process_respawns(s: int, list: Array[Combatant]) -> void:
	for combatant: Combatant in list:
		if combatant.is_alive() or combatant.death_tick < 0:
			continue
		# NPCs do not respawn on their own: their spawner replenishes them (NpcSpawnerSystem).
		if combatant.entity.kind == NetProtocol.EntityKind.NPC:
			continue
		var requested: bool = combatant.pending_respawn_point >= 0 and s >= combatant.respawn_tick
		# With waves, the automatic one also falls in a wave (Combatant.auto_respawn_tick).
		var automatic: bool = s >= combatant.auto_respawn_tick
		if requested or automatic:
			_respawn(combatant, combatant.pending_respawn_point if requested else 0, s)


# Respawns [param combatant] at point [param point_index] of the zone's static list: if it is no longer
# valid for its realm (a foreign camp, a fortress that changed hands, in combat or in another
# phase), at the first valid camp of its realm, without notice; and, if the zone has no points for its
# realm, at a spawn point. New combat state, full health, protection, teleport with
# counter and RESPAWN event.
func _respawn(combatant: Combatant, point_index: int, s: int) -> void:
	var points: Array[Node3D] = get_all_respawn_points()
	var valid: PackedInt32Array = get_valid_respawn_points(combatant.get_realm(), s)
	var index: int = point_index
	if not valid.has(index):
		index = _first_camp_point(valid, points)
	var position: Vector3
	var yaw: float
	if index < 0:
		var spawn: Transform3D = _pick_spawn.call(combatant.get_realm())
		position = spawn.origin
		yaw = _yaw_of(spawn)
		index = 0
	else:
		var transform: Transform3D = points[index].global_transform
		position = transform.origin
		yaw = _yaw_of(transform)
	var character: PlayerCharacter = combatant.get_character()
	var combat: CombatState = character.combat
	var before: PackedInt32Array = weapons_in_slot_order(combat)
	# Whoever has an inventory (docs/progression.md §8) respawns with their gear's weapons and their bag's charges,
	# without looking at templates: WEAPON_1 active or, if empty, 2 (set_weapons right after, without cooldowns).
	var loadout: ProgressService.Loadout = loadout_source.call(combatant.get_id()) \
			if loadout_source.is_valid() else null
	var weapons: PackedInt32Array = PackedInt32Array()
	if loadout != null:
		combatant.template_id = 0
		ActionMachine.reset_for_respawn(combat, s, loadout.weapon_1, loadout.weapon_2, loadout.charges)
		if loadout.second_active:
			ActionMachine.set_weapons(combat, loadout.weapon_1, loadout.weapon_2, true, PackedInt64Array(),
					PackedInt64Array())
	else:
		# The template (docs/abilities.md, section 4.6): the peer's pending one, if it chose another, becomes the
		# current one; it respawns with its weapons (slot 1 active) and its charges. Without a template (NPCs and
		# fighters assembled by hand) it respawns with the weapons and charges it had.
		if combatant.peer != null and combatant.peer.pending_template_id >= 0:
			combatant.template_id = resolve_template(combatant.peer.pending_template_id)
			combatant.peer.pending_template_id = -1
		weapons = CombatCatalog.template_weapons(combatant.template_id) \
				if combatant.template_id > 0 else PackedInt32Array()
		if weapons.is_empty():
			ActionMachine.reset_for_respawn(combat, s, before[0], before[1], combat.consumable_charges)
		else:
			ActionMachine.reset_for_respawn(combat, s, weapons[0], weapons[1] if weapons.size() > 1 else 0,
					CombatCatalog.template_charges(combatant.template_id))
	# None should remain now (they are removed on death), but respawning always starts clean.
	status.clear(combatant)
	combatant.mark_respawned(s)
	# _place passes the state (with combat already reset) through encode/decode.
	_place.call(combatant.entity, position, yaw)
	stats[&"respawns"] += 1
	_emit(NetMessages.EntityEvent.respawn(combatant.get_id(), s, index),
			_ids([combatant.get_id()]))
	if not weapons.is_empty() or loadout != null:
		announce_loadout(combatant, s, before != weapons_in_slot_order(character.combat))


# Consumable refill (docs/abilities.md, section 4.6), every RECHARGE_INTERVAL_TICKS: whoever is alive,
# out of combat, in their realm's safe zone and with fewer charges than their template recovers them all
# ([method ActionMachine.set_charges]: weapon, cooldowns, slots and action in progress do not change) and their
# owner receives LOADOUT. For whoever has an inventory, with the same conditions and the same cadence, their bag's
# CAMP_REFILL ([member camp_step], docs/progression.md §4.4) instead of the template.
func _process_recharge(s: int, list: Array[Combatant]) -> void:
	if s % RECHARGE_INTERVAL_TICKS != 0:
		return
	var safe: SafeAreas = resolver.get_safe_areas()
	if safe == null:
		return
	for combatant: Combatant in list:
		if not combatant.is_alive() or combatant.is_in_combat(s):
			continue
		if combatant.template_id <= 0:
			# Without a template: whoever has an inventory replenishes their bag (camp_step does nothing without one).
			if camp_step.is_valid() and combatant.entity.kind == NetProtocol.EntityKind.PLAYER \
					and safe.contains_own(combatant.get_realm(), combatant.entity.get_position()):
				camp_step.call(combatant.entity, s)
			continue
		var full: int = CombatCatalog.template_charges(combatant.template_id)
		var combat: CombatState = combatant.get_character().combat
		if not _lacks_charges(combat, full):
			continue
		if not safe.contains_own(combatant.get_realm(), combatant.entity.get_position()):
			continue
		ActionMachine.set_charges(combat, full)
		commit_state(combatant.get_character())
		stats[&"recharges"] += 1
		announce_loadout(combatant, s, false)


# true if any potion of [param combat] has fewer charges than in [param full] (packed).
static func _lacks_charges(combat: CombatState, full: int) -> bool:
	for index: int in CombatState.CONSUMABLE_SLOTS:
		if combat.charges_of(index) < (full >> (4 * index)) & CombatState.MAX_CHARGES:
			return true
	return false


# The first valid point that is a camp (carries the realm metadata), or -1 if there is none.
static func _first_camp_point(valid: PackedInt32Array, points: Array[Node3D]) -> int:
	for index: int in valid:
		if points[index].has_meta(NetZones.realm_meta()):
			return index
	return -1


# --- Utilities ---------------------------------------------------------------------------------

# Counts as a launched attack the tick on which a light attack, a heavy attack or an ability that hits starts
# (with a shape or projectile): its hits also count in _note_landed.
func _count_swing(combatant: Combatant) -> void:
	var frame: Combatant.Frozen = combatant.frozen
	if combatant.peer == null or frame.action_tick != frame.tick:
		return
	match frame.action:
		CombatState.Action.LIGHT, CombatState.Action.HEAVY:
			combatant.peer.swings += 1
		CombatState.Action.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(frame.action_id)
			if ability != null and (ability.hit.shape != null or ability.projectile_id != 0):
				combatant.peer.swings += 1


# A hit has landed, been blocked or parried: it counts as a peer hit once per attack (projectiles,
# once per shot: those of a fan share their [ProjectileSystem.Shot]).
func _note_landed(hit: CombatResolver.Hit) -> void:
	var attacker: Combatant = hit.attacker
	if hit.projectile != null:
		if attacker.peer != null and not hit.projectile.shot.landed:
			attacker.peer.swings_landed += 1
		hit.projectile.shot.landed = true
		return
	if attacker.peer != null and not attacker.swing_landed:
		attacker.peer.swings_landed += 1
	attacker.swing_landed = true


# Charge with which the hit was launched: the one the projectile copied on launch or the current attack's.
static func _charge_of(hit: CombatResolver.Hit) -> int:
	return hit.projectile.charge_ticks if hit.projectile != null else hit.attacker.frozen.charge_ticks


# Combat log result of an impact or a block: those of projectiles (docs/abilities.md,
# section 4.7) are arrow_hit, arrow_blocked and wall_blocked; melee ones, hit, blocked and
# guard_break. It counts the projectile ones.
func _impact_result(hit: CombatResolver.Hit, blocked: bool, flags: int) -> String:
	if hit.projectile != null:
		if hit.wall:
			stats[&"wall_blocked"] += 1
			return "wall_blocked"
		if blocked:
			stats[&"arrow_blocked"] += 1
			return "arrow_blocked"
		stats[&"arrow_hits"] += 1
		return "arrow_hit"
	if (flags & _HIT_GUARD_BREAK) != 0:
		return "guard_break"
	return "blocked" if blocked else "hit"


# What removes respawn protection: an attack (or its charge) and an ability that is not a
# consumable (docs/abilities.md, section 4.2). Drinking, SWAP and REVIVE do not remove it; EXECUTE has it removed by
# DownedSystem on the tick it starts (H5 review).
func _started_attack(combatant: Combatant) -> bool:
	var frame: Combatant.Frozen = combatant.frozen
	match frame.action:
		CombatState.Action.LIGHT, CombatState.Action.HEAVY, CombatState.Action.CHARGE:
			return true
		CombatState.Action.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(frame.action_id)
			return ability != null and not ability.is_consumable()
	return false


func _emit(event: NetMessages.EntityEvent, involved: PackedInt32Array) -> void:
	stats[&"events"] += 1
	event_emitted.emit(event, involved)


static func _ids(ids: Array[int]) -> PackedInt32Array:
	var result := PackedInt32Array()
	for net_id: int in ids:
		if net_id > 0 and not result.has(net_id):
			result.append(net_id)
	return result


# Yaw (Node3D.rotation.y convention) a basis faces toward.
static func _yaw_of(transform: Transform3D) -> float:
	var forward: Vector3 = -transform.basis.z
	return atan2(-forward.x, -forward.z)


# One line of the combat log for a resolved hit: tick, attacker, target, source (the attack's or
# ability's name), view_tick, rewind, result and damage.
func _log_hit(s: int, hit: CombatResolver.Hit, result: String, damage: int) -> void:
	if combat_log == null:
		return
	var target_id: int = 0
	if hit.victim != null:
		target_id = hit.victim.get_id()
	elif hit.structure != null:
		target_id = hit.structure.net_id
	_log_line(s, hit.attacker.get_id(), target_id, String(hit.attack.name), hit.view_tick, hit.rewind,
			result, damage)


# One line of the combat log ([code]--combat-log[/code]): the "attack" column carries the source's name
# ([method CombatSource.name_of]: attack, ability, effect...). Phase 4 results: pulse (an effect's
# damage pulse); arrow_hit, arrow_blocked, wall_blocked (H3b); downed (after the line of the hit
# that knocks down, or of command 15), executed (the finisher and the finished) , bled_out (the killer and the
# bled-out player) and revived (whoever lifts and the lifted) (H3c).
func _log_line(s: int, attacker_id: int, target_id: int, source_name: String, view_tick: float,
		rewind: float, result: String, damage: int) -> void:
	if combat_log == null:
		return
	combat_log.store_line("%d,%d,%d,%s,%.2f,%.2f,%s,%d" % [s, attacker_id, target_id, source_name,
			view_tick, rewind, result, damage])
