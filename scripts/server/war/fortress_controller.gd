class_name FortressController
extends RefCounted
## The fortresses of a zone on the server (docs/fuerte.md, sections 1.6, 1.7, 2 and 3; GUE-08,
## GUE-10, GUE-12 and GUE-13). For each node of the [code]fortresses[/code] group with the
## [code]definition[/code] metadata it creates a [NetEntity] [code]STRUCTURE[/code] with
## [constant NetEntity.FLAG_ALWAYS_RELEVANT] and carries its [FortressState].
## [br][br]
## [b]Every tick[/b] ([method step], step 4b of the tick order, after combat): every 6 ticks it
## recounts the presence in the circle ([FortressPresence]), advances the state ([method
## FortressState.advance], which runs every tick so transitions land on the exact tick) and
## applies its effects:
## [br]- the owner and the broken state of the gate go to the collision layers of the gate's two
## bodies ([method FortGate.set_state]); the change applies [b]from s + 1[/b], on the server and on
## the client;
## [br]- the gate is repaired on an owner change, with [code]fort_reset[/code] or after
## [member FortressDefinition.gate_repair_after_s] without damage, but [b]not while a character
## overlaps the doorway[/b]: the state keeps the broken health and the repair is postponed tick by
## tick until it is clear;
## [br]- the war notices go out through [signal war_event_emitted] in the order they happen and the
## state goes out through [signal object_state_emitted] as OBJECT_STATE.
## [br][br]
## [b]OBJECT_STATE[/b]: at most one per fortress every 6 ticks, with the fields that changed since
## the last one; [code]under_attack_until_tick[/code] only if it advances at least 60 ticks. If what
## changes is the gate collision (owner or broken state) it goes out [b]on that same tick[/b],
## without waiting for the interval: the client sets the gate layer according to the tick of each
## change, and delaying it would desync the prediction (docs/fuerte.md, section 3.2). The spawn
## ([method NetEntity.encode_spawn]) carries the full state.
## [br][br]
## [b]The gate as a target[/b] ([StructureTarget], docs/fuerte.md 3.3): hits are resolved by the
## [CombatResolver] and applied by the [CombatDirector], which notifies [method on_structure_hit]
## through [signal CombatDirector.structure_hit]; here the health is subtracted, a notice is sent
## and the damage is recorded for the scoreboard.
## [br][br]
## [b]NPC interface (package F4)[/b]:
## [br]- [method get_fortress_state] gives the live [FortressState] (owner, phase, captain,
## guards...).
## [br]- [method on_captain_died] when the captain dies (the Hollow's or the owner's), and
## [method set_guards_alive] with the living guards. [method register_captain] and
## [method register_defender] let the controller notice it on its own from combat DEATH and HIT.
## [br]- The signals [signal defenders_retired] (the NPCs of the previous owner or of the Hollow
## are withdrawn), [signal garrison_due] (the garrison and the captain of the current owner appear;
## [code]full[/code] is false if only the captain respawns) and [signal guards_respawn_due] (time
## to replace the missing guards). On startup, the fort is neutral and guarded by the Hollow and
## its Captain: there is no signal, the NPC spawner reads it from [method get_fortress_state].
## [br][br]
## [b]Persistent war[/b] (docs/plataforma.md §8, GUE-19): [method restore_state] sets the state
## loaded from the platform on startup ([FortressPersistence]); on every real capture, the list of
## those who were in the circle (of the capturing realm, present, alive and connected, without
## characters flagged with [member NetEntity.gm_forced]) adds [code]captures[/code] in the
## [ScoreKeeper] and goes out through [signal fortress_captured]; and those of the owning realm
## present while the circle is active add [code]defend_ticks[/code]. [b]Forced change[/b]
## (docs/progresion.md §6.2): whatever a fort command causes ([code]fort_owner[/code],
## [code]fort_reset[/code], [code]fort_kill_captain[/code], a capture with
## [member FortressState.capture_rate_multiplier] other than 1) adds no captures or defending time,
## and [method is_forced] tells whoever pays out rewards (progresion.md P5c). The rewards
## (progresion.md §6.2) come from [signal fortress_captured] (the capture), [signal objective_time]
## (the time in the active circle of a real cycle: objective merits) and [method fortress_of_defender]
## (which fortress the dying NPC belonged to).
## [br][br]
## It does not touch the network or the clock: it notifies through signals and receives from whoever
## runs it ([ZoneServer]) the presence candidates, the bodies that may occupy the doorway and how
## to kill the captain.

## A war notice (ENTITY_EVENT [code]WAR[/code]) that must be sent to the whole zone.
signal war_event_emitted(event: NetMessages.EntityEvent)
## An OBJECT_STATE that must be sent to the whole zone.
signal object_state_emitted(object_state: NetMessages.ObjectState)
## The fortress changes hands or is reset: the defending NPCs that were there must be withdrawn.
signal defenders_retired(fortress_id: StringName, tick: int)
## The fortress is GARRISONED again: the garrison and the captain of [param owner_realm] must be
## spawned (the Hollow and the Ford Captain with the fort neutral). With [param full] false only
## the captain respawns (the garrison is still standing).
signal garrison_due(fortress_id: StringName, owner_realm: int, tick: int, full: bool)
## The respawn seconds of the missing guards have elapsed: they must be replaced and the change
## reported with [method set_guards_alive].
signal guards_respawn_due(fortress_id: StringName, tick: int)
## Someone hits the intact gate of the fortress for the first time (for telemetry).
signal gate_damage_started(fortress_id: StringName, tick: int)
## [param fortress_id] has passed to [param owner_realm] through a real (non-forced) capture at
## tick [param tick]: [param in_circle] is the list from docs/plataforma.md §8 (the net_ids of the
## capturing realm present, alive and connected in the circle at that tick, without
## [member NetEntity.gm_forced]), the same one that has already added [code]captures[/code] in the
## [ScoreKeeper]. A forced capture is not emitted (progresion.md §6.2): this is where
## [code]ProgressService.on_capture[/code] connects (progresion.md P5c).
signal fortress_captured(fortress_id: StringName, owner_realm: int, in_circle: PackedInt32Array, tick: int)
## [param ticks] more for [param net_id] in the active circle of [param fortress_id] (each recount,
## at tick [param tick]), in a real cycle and without [member NetEntity.gm_forced]: the time that
## gives objective merits (docs/progresion.md §6.2; [code]ProgressService.on_objective_ticks[/code]
## connects here, P5c). It counts all the realms present, like [code]circle_ticks[/code] of the
## scoreboard, but not in a forced cycle.
signal objective_time(fortress_id: StringName, net_id: int, ticks: int, tick: int)

## Ticks between two OBJECT_STATE messages of the same fortress.
const OBJECT_STATE_INTERVAL_TICKS: int = 6
## How far [code]under_attack_until_tick[/code] must advance to deserve an OBJECT_STATE.
const UNDER_ATTACK_MIN_ADVANCE_TICKS: int = 60
## Children of the fortress node used by the controller.
const CIRCLE_NODE: NodePath = ^"CaptureCircle"
const GATE_NODE: NodePath = ^"FortGate"
## Circle metadata with its radius, and the default radius if it is missing.
const CIRCLE_RADIUS_META: StringName = &"radius"
const DEFAULT_CIRCLE_RADIUS: float = 5.0

## Battle scoreboard (null = not kept): the controller adds the time in the circle and the damage to
## the gate.
var score_keeper: ScoreKeeper = null
## [code](tick: int) -> Array[PlayerCandidate][/code]: the players that may count in the circle
## (players only: NPCs do not count). Called every 6 ticks.
var candidates_source: Callable = Callable()
## [code]() -> PackedVector3Array[/code]: the feet of the characters (living players and NPCs) that
## may occupy the gate doorway. Only called when a repair is waiting.
var bodies_source: Callable = Callable()
## [code](net_id: int) -> bool[/code]: kills the registered captain NPC ([method register_captain]).
## If it is not valid (or returns false), [method kill_captain] declares the captain dead directly.
var captain_killer: Callable = Callable()

var _registry: NetEntityRegistry = null
var _sites: Array[Site] = []
var _sites_by_id: Dictionary[StringName, Site] = {}
var _sites_by_net_id: Dictionary[int, Site] = {}
# Tick of the next debug command (set in register_commands).
var _next_tick_source: Callable = Callable()


## A player candidate to count in the circle: the [FortressPresence.Candidate] data plus the network id.
class PlayerCandidate:
	extends FortressPresence.Candidate

	var net_id: int = 0
	## Flagged by a GM command ([member NetEntity.gm_forced]): counts in the presence, but does not enter
	## the capture list or add defending time.
	var gm_forced: bool = false


	static func make_player(player_id: int, realm_code: int, feet_position: Vector3,
			input_tick: int) -> PlayerCandidate:
		var candidate := PlayerCandidate.new()
		candidate.net_id = player_id
		candidate.realm = realm_code
		candidate.feet = feet_position
		candidate.last_input_tick = input_tick
		return candidate


## What the controller knows about a fortress.
class Site:
	extends RefCounted

	var id: StringName = &""
	var definition: FortressDefinition = null
	var node: Node3D = null
	var entity: NetEntity = null
	var state: FortressState = null
	var circle_center: Vector3 = Vector3.ZERO
	var circle_radius: float = DEFAULT_CIRCLE_RADIUS
	var gate: FortGate = null
	var target: StructureTarget = null
	# Presence from the last recount (kept between recounts).
	var presence: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
	# What the clients know (the fields sent) and when it was sent.
	var last_sent: FortressState = null
	var last_sent_tick: int = 0
	# Owner and broken state with which the last OBJECT_STATE was sent: the collision the clients see.
	var sent_owner: int = 0
	var sent_broken: bool = false
	# Owner and broken state that the gate layers currently have.
	var applied_owner: int = 0
	var applied_broken: bool = false
	# true while the repair of a broken gate waits for the doorway to be clear (only with a broken gate:
	# an intact one is repaired without waiting).
	var repair_pending: bool = false
	# Registered captain NPC (0 = none) and realm of whoever asked to kill it (-1 = nobody).
	var captain_net_id: int = 0
	var pending_killer_realm: int = -1
	# Registered defender NPCs: net_id -> true.
	var defenders: Dictionary[int, bool] = {}
	# The need to replace the guards has already been announced (until the next set_guards_alive).
	var guards_due_notified: bool = false
	# The first hit on the gate since its last repair has already been announced.
	var gate_damage_announced: bool = false
	# The current cycle comes from a fort command (progresion.md §6.2): fort_owner, fort_reset,
	# fort_kill_captain or fort_capture_speed other than 1. The next real change clears it: the
	# captain's death in combat, returning to GARRISONED on its own or the periodic reset.
	var forced: bool = false
	# End of the consolidation loaded from the platform ([constant FortressState.NO_TICK] if there is
	# none): the state does not store the end, but the start, which cannot be negative in OBJECT_STATE
	# (restore_state).
	var consolidation_ends_tick: int = FortressState.NO_TICK


# --- Fortress spawning --------------------------------------------------------------------------

## Creates the fortresses of [param world] (the nodes of the [code]fortresses[/code] group with their
## definition) with the state "after [param tick]". Each one requests its [NetEntity] from
## [param registry]. Returns how many it created.
func setup(world: Node3D, registry: NetEntityRegistry, tick: int) -> int:
	_registry = registry
	for node: Node3D in NetZones.get_fortress_nodes(world):
		var definition: FortressDefinition = _definition_of(node)
		if definition == null:
			push_warning("[Eldmark] La fortaleza '%s' no tiene una definición válida" % node.name)
			continue
		add_fortress(node, definition, tick)
	return _sites.size()


## Adds the fortress of node [param node] with definition [param definition] (the node must be in
## the tree: its [code]CaptureCircle[/code] and [code]FortGate[/code] children provide the circle and
## the gate). Returns its network id, or 0 if another one with that id already exists, the id does
## not fit in the protocol or no network id is left.
func add_fortress(node: Node3D, definition: FortressDefinition, tick: int) -> int:
	var fortress_id: StringName = definition.id
	if _sites_by_id.has(fortress_id) or fortress_id.is_empty() \
			or fortress_id.length() > NetProtocol.MAX_DEFINITION_ID_BYTES \
			or not NetMessages.is_printable_ascii_text(String(fortress_id)):
		push_warning("[Eldmark] Fortaleza con un id no válido o repetido: '%s'" % fortress_id)
		return 0
	var entity: NetEntity = _registry.allocate(NetProtocol.EntityKind.STRUCTURE, tick)
	if entity == null:
		return 0
	var site := Site.new()
	site.id = fortress_id
	site.definition = definition
	site.node = node
	site.entity = entity
	site.state = FortressState.initial(definition, tick)
	site.last_sent = site.state.duplicate_state()
	site.last_sent_tick = tick
	var circle: Node3D = node.get_node_or_null(CIRCLE_NODE) as Node3D
	site.circle_center = circle.global_position if circle != null else node.global_position
	if circle != null:
		var radius: Variant = circle.get_meta(CIRCLE_RADIUS_META, DEFAULT_CIRCLE_RADIUS)
		if (typeof(radius) == TYPE_FLOAT or typeof(radius) == TYPE_INT) and float(radius) > 0.0:
			site.circle_radius = float(radius)
	site.gate = node.get_node_or_null(GATE_NODE) as FortGate
	if site.gate != null:
		site.gate.set_state(0, false)
		var target := StructureTarget.new()
		target.net_id = entity.net_id
		target.fortress_id = fortress_id
		target.state = site.state
		target.box = site.gate.get_hit_box()
		target.half_extents = site.gate.get_hit_half_extents()
		target.exclude = site.gate.get_body_rids()
		site.target = target
	entity.realm = RealmCatalog.NEUTRAL_CODE
	entity.flags = NetEntity.FLAG_ALWAYS_RELEVANT
	entity.display_name = definition.display_name
	entity.definition_id = String(fortress_id)
	entity.fortress_state = site.state
	_sites.append(site)
	_sites_by_id[fortress_id] = site
	_sites_by_net_id[entity.net_id] = site
	return entity.net_id


## Sets [param loaded] as the state of [param fortress_id] (the one loaded from the platform on
## startup, docs/plataforma.md §8; [FortressPersistence]) at tick [param tick], before anyone sees
## it: it is copied into the live state (the entity and the gate follow it), what was sent is taken
## as known (the spawn carries the whole state) and the gate layers go to its owner and broken
## state. [param consolidation_ends_tick] is the end of a loaded consolidation
## ([constant FortressState.NO_TICK] if there is none): the state cannot carry a negative start, so
## the controller stores the end. Returns false if the fortress does not exist.
func restore_state(fortress_id: StringName, loaded: FortressState, consolidation_ends_tick: int,
		tick: int) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null or loaded == null:
		return false
	site.state.copy_from(loaded)
	site.consolidation_ends_tick = consolidation_ends_tick \
			if loaded.phase == FortressState.Phase.CONSOLIDATING else FortressState.NO_TICK
	site.forced = false
	site.repair_pending = false
	site.gate_damage_announced = loaded.gate_health < loaded.gate_max
	site.presence = PackedInt32Array([0, 0, 0, 0])
	site.last_sent = site.state.duplicate_state()
	site.last_sent_tick = tick
	site.sent_owner = site.state.owner
	site.sent_broken = site.state.is_gate_broken()
	_sync_gate(site)
	return true


## Removes all the fortresses and frees their network entities (server shutdown).
func clear() -> void:
	if _registry != null:
		for site: Site in _sites:
			_registry.release(site.entity.net_id, site.last_sent_tick)
	_sites.clear()
	_sites_by_id.clear()
	_sites_by_net_id.clear()


# --- Queries ------------------------------------------------------------------------------------

## true if the zone has any fortress.
func has_fortresses() -> bool:
	return not _sites.is_empty()


## Ids of the fortresses, in scene order.
func get_fortress_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for site: Site in _sites:
		ids.append(site.id)
	return ids


## The [b]live[/b] state of fortress [param fortress_id] (not a copy), or null if it does not exist.
func get_fortress_state(fortress_id: StringName) -> FortressState:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.state if site != null else null


## Live states by fortress id (the shape that [method RespawnRules.points_for] requires).
func get_states() -> Dictionary:
	var states: Dictionary = {}
	for site: Site in _sites:
		states[site.id] = site.state
	return states


## The network entity of fortress [param fortress_id], or null.
func get_entity(fortress_id: StringName) -> NetEntity:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.entity if site != null else null


## Network id of fortress [param fortress_id], or 0.
func get_net_id(fortress_id: StringName) -> int:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.entity.net_id if site != null else 0


## Id of the fortress with that network [param net_id], or an empty string.
func get_fortress_id_of(net_id: int) -> StringName:
	var site: Site = _sites_by_net_id.get(net_id)
	return site.id if site != null else &""


## Definition of fortress [param fortress_id], or null.
func get_definition(fortress_id: StringName) -> FortressDefinition:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.definition if site != null else null


## Center and radius of the capture circle of [param fortress_id] (the center is ZERO if it does not
## exist).
func get_circle(fortress_id: StringName) -> Dictionary:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return {"center": Vector3.ZERO, "radius": 0.0}
	return {"center": site.circle_center, "radius": site.circle_radius}


## Node of fortress [param fortress_id] in the scene, or null.
func get_node_of(fortress_id: StringName) -> Node3D:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.node if site != null else null


## Gate of fortress [param fortress_id], or null if the scene does not have one.
func get_gate(fortress_id: StringName) -> FortGate:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.gate if site != null else null


## Presence (players of each realm) from the last recount of [param fortress_id].
func get_presence(fortress_id: StringName) -> PackedInt32Array:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.presence.duplicate() if site != null else PackedInt32Array([0, 0, 0, 0])


## The hit targets (the gates) of the zone, for the [CombatResolver]. The array is the same for the
## whole life of the controller.
func get_structure_targets() -> Array[StructureTarget]:
	var targets: Array[StructureTarget] = []
	for site: Site in _sites:
		if site.target != null:
			targets.append(site.target)
	return targets


## true if a repair of the broken gate is waiting for the doorway to be clear.
func is_repair_pending(fortress_id: StringName) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	return site != null and site.repair_pending


## true if the current cycle of [param fortress_id] was caused by a fort command (progresion.md
## §6.2): an owner change or a reset by command, the captain killed with
## [code]fort_kill_captain[/code] (and the capture that follows it) or a capture speed other than 1.
## What happens in it adds no captures or defending time and pays no persistent rewards.
func is_forced(fortress_id: StringName) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	return site != null and (site.forced or site.state.capture_rate_multiplier != 1)


## Tick at which the consolidation of [param fortress_id] ends (the one loaded from the platform or
## the one from its start plus [method FortressDefinition.consolidation_ticks]);
## [constant FortressState.NO_TICK] if it is not consolidating.
func get_consolidation_end_tick(fortress_id: StringName) -> int:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null or site.state.phase != FortressState.Phase.CONSOLIDATING:
		return FortressState.NO_TICK
	if site.consolidation_ends_tick != FortressState.NO_TICK:
		return site.consolidation_ends_tick
	return site.state.phase_tick + site.definition.consolidation_ticks()


## The fortress defended by NPC [param net_id] (registered with [method register_captain] or
## [method register_defender]); empty if it defends none. Whoever pays out its death reads it here
## (progresion.md P5c) before the controller forgets it: the DEATH reaches the zone before
## [method on_combat_event].
func fortress_of_defender(net_id: int) -> StringName:
	for site: Site in _sites:
		if site.defenders.has(net_id):
			return site.id
	return &""


## The registered captain NPC of [param fortress_id] (0 = none).
func get_captain_net_id(fortress_id: StringName) -> int:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.captain_net_id if site != null else 0


## The fortress nearest to point [param position] (by its circle), or an empty string if there is none.
func get_nearest_fortress_id(position: Vector3) -> StringName:
	var best: StringName = &""
	var best_distance: float = INF
	for site: Site in _sites:
		var distance: float = site.circle_center.distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best = site.id
	return best


# --- Interface with NPCs (F4) and with combat ---------------------------------------------------

## Registers NPC [param net_id] as captain of [param fortress_id] (and as a defender): when it dies
## ([signal CombatDirector.event_emitted] with DEATH, via [method on_combat_event]) the controller
## calls [method on_captain_died] with the realm of whoever killed it. Replaces the previous one.
func register_captain(fortress_id: StringName, net_id: int) -> void:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return
	site.captain_net_id = net_id
	site.defenders[net_id] = true


## Registers NPC [param net_id] as a defender of [param fortress_id]: if it is hit, the fort counts
## as attacked (one cannot respawn in it during [member FortressDefinition.under_attack_s]) and the
## "fort under attack" notice goes out.
func register_defender(fortress_id: StringName, net_id: int) -> void:
	var site: Site = _sites_by_id.get(fortress_id)
	if site != null:
		site.defenders[net_id] = true


## Removes NPC [param net_id] from the defenders (and from captain, if it was one).
func unregister_defender(fortress_id: StringName, net_id: int) -> void:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return
	site.defenders.erase(net_id)
	if site.captain_net_id == net_id:
		site.captain_net_id = 0


## The captain of [param fortress_id] has died at tick [param tick] at the hands of
## [param killer_realm] (0 if nobody). If it was guarding the fort, it becomes VULNERABLE and the
## "captain fallen" notice goes out. Returns true if it had any effect.
func on_captain_died(fortress_id: StringName, tick: int, killer_realm: int) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return false
	if not _captain_died(site, tick, killer_realm):
		return false
	site.forced = false
	return true


## Says how many guards of the garrison of [param fortress_id] are alive. The missing ones respawn
## after [member FortressDefinition.guard_respawn_s] ([signal guards_respawn_due]).
func set_guards_alive(fortress_id: StringName, count: int) -> void:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return
	site.state.set_guards_alive(count)
	site.guards_due_notified = false


## A hit has landed on the gate ([signal CombatDirector.structure_hit]): it subtracts [param amount]
## of health at tick [param tick], the "fort under attack" notice goes out (at most one per minute)
## and the "gate broken" one if it breaks it, and the damage counts for the scoreboard of
## [param attacker]. A hit that removes health cancels any pending repair: the next one comes after
## the no-damage period counted from it.
func on_structure_hit(target: StructureTarget, attacker: Combatant, amount: int, tick: int) -> void:
	var site: Site = _sites_by_net_id.get(target.net_id)
	if site == null or amount <= 0:
		return
	var first_damage: bool = not site.gate_damage_announced
	var health_before: int = site.state.gate_health
	var events: PackedInt32Array = site.state.on_gate_damaged(tick, amount, attacker.get_realm())
	if site.state.gate_health < health_before:
		site.repair_pending = false
	if first_damage:
		site.gate_damage_announced = true
		gate_damage_started.emit(site.id, tick)
	if score_keeper != null:
		score_keeper.add_gate_damage(attacker.get_id(), amount)
	_emit_war(site, tick, events, attacker.get_realm())


## A combat event ([signal CombatDirector.event_emitted]): the death of the registered captain opens
## the circle and a hit on a registered defender marks the fort as attacked.
func on_combat_event(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
	if _sites.is_empty():
		return
	if event.event == NetMessages.EntityEvent.Kind.HIT:
		_on_defender_hit(event)
	elif event.event == NetMessages.EntityEvent.Kind.DEATH:
		_on_death(event)


# --- Administration commands --------------------------------------------------------------------

## Returns [param fortress_id] to neutral at tick [param tick] ([code]fort_reset[/code]): Hollow and
## Ford Captain, full gate (when the doorway is clear) and capture at zero. Players inside are not
## moved. Returns false if the fortress does not exist.
func reset_fortress(fortress_id: StringName, tick: int) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return false
	var health_before: int = site.state.gate_health
	var last_damage_before: int = site.state.gate_last_damage_tick
	var events: PackedInt32Array = site.state.reset_to_neutral(site.definition, tick)
	site.forced = true
	site.consolidation_ends_tick = FortressState.NO_TICK
	_after_hard_reset(site, tick, events, health_before, last_damage_before)
	return true


## Gives fortress [param fortress_id] to realm [param realm] (0 to 3; 0 = neutral) at tick
## [param tick] ([code]fort_owner[/code]): GARRISONED with the garrison and captain of that realm,
## full gate and no capture. With a realm the "fort captured" notice goes out and with 0 the "reset"
## one.
func set_owner(fortress_id: StringName, realm: int, tick: int) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null or realm < 0 or realm > 3:
		return false
	var health_before: int = site.state.gate_health
	var last_damage_before: int = site.state.gate_last_damage_tick
	var events: PackedInt32Array = site.state.reset_to_neutral(site.definition, tick)
	site.state.owner = realm
	site.forced = true
	site.consolidation_ends_tick = FortressState.NO_TICK
	if realm != RealmCatalog.NEUTRAL_CODE:
		events = PackedInt32Array([WarEvents.FORT_CAPTURED])
	_after_hard_reset(site, tick, events, health_before, last_damage_before)
	return true


## Kills the captain of [param fortress_id] at tick [param tick] at the hands of
## [param killer_realm] ([code]fort_kill_captain[/code]). If there is a registered captain NPC, it
## kills it ([member captain_killer]) and its death arrives through [method on_combat_event]; if
## not, it declares the captain dead directly. Returns true if the fortress was guarded by its
## captain.
func kill_captain(fortress_id: StringName, tick: int, killer_realm: int) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return false
	var state: FortressState = site.state
	if state.phase != FortressState.Phase.GARRISONED or not state.captain_alive:
		return false
	# Forced before killing: the death goes out in this very call and whoever pays it out (progresion.md
	# P5c) already sees it that way.
	var was_forced: bool = site.forced
	site.forced = true
	if site.captain_net_id != 0 and captain_killer.is_valid():
		site.pending_killer_realm = killer_realm
		if bool(captain_killer.call(site.captain_net_id)):
			return true
		site.pending_killer_realm = -1
	if not _captain_died(site, tick, killer_realm):
		site.forced = was_forced
		return false
	return true


## Multiplies the capture speed of [param fortress_id] by [param factor] (1 to 255)
## ([code]fort_capture_speed[/code]); decay does not change.
func set_capture_speed(fortress_id: StringName, factor: int) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null or factor < 1 or factor > 255:
		return false
	site.state.capture_rate_multiplier = factor
	if factor != 1:
		site.forced = true
	return true


# --- The tick -----------------------------------------------------------------------------------

## Step 4b of tick [param s]: presence recount (every 6 ticks), state advance of each fortress,
## effects and OBJECT_STATE.
func step(s: int) -> void:
	if _sites.is_empty():
		return
	var recount: bool = s % FortressState.PRESENCE_RECOUNT_TICKS == 0
	var candidates: Array = []
	if recount and candidates_source.is_valid():
		candidates = candidates_source.call(s)
	for site: Site in _sites:
		if recount:
			_recount(site, candidates, s)
		_step_site(site, s)


func _step_site(site: Site, s: int) -> void:
	var state: FortressState = site.state
	var previous_owner: int = state.owner
	var previous_phase: int = state.phase
	var health_before: int = state.gate_health
	var last_damage_before: int = state.gate_last_damage_tick
	if site.consolidation_ends_tick != FortressState.NO_TICK:
		if state.phase != FortressState.Phase.CONSOLIDATING:
			site.consolidation_ends_tick = FortressState.NO_TICK
		elif s >= site.consolidation_ends_tick:
			# The loaded consolidation ends at its tick: advance closes it with this start (which only lives here).
			state.phase_tick = s - site.definition.consolidation_ticks()
			site.consolidation_ends_tick = FortressState.NO_TICK
	var events: PackedInt32Array = state.advance(site.definition, s, site.presence)
	_note_transitions(site, s, events, previous_owner, previous_phase)
	if events.has(WarEvents.FORT_CAPTURED):
		_on_captured(site, s)
	_emit_war(site, s, events, RealmCatalog.NEUTRAL_CODE)
	_hold_repair_if_blocked(site, health_before, last_damage_before)
	_repair_if_due(site, s)
	if state.guards_respawn_due(s) and not site.guards_due_notified:
		site.guards_due_notified = true
		guards_respawn_due.emit(site.id, s)
	_sync_gate(site)
	_flush_object_state(site, s)


# Recounts who is in the circle of [param site] (only counts with the circle active for the
# scoreboard) with the candidates of this tick.
func _recount(site: Site, candidates: Array, s: int) -> void:
	var counts := PackedInt32Array([0, 0, 0, 0])
	var active: bool = site.state.is_circle_active()
	var owner: int = site.state.owner
	var forced: bool = is_forced(site.id)
	var defending: bool = active and owner != RealmCatalog.NEUTRAL_CODE and not forced
	for candidate: FortressPresence.Candidate in candidates:
		if not FortressPresence.is_present(site.definition, site.circle_center, site.circle_radius,
				candidate, s):
			continue
		counts[candidate.realm] += 1
		var player: PlayerCandidate = candidate as PlayerCandidate
		if not active or player == null:
			continue
		if score_keeper != null:
			score_keeper.add_circle_ticks(player.net_id, FortressState.PRESENCE_RECOUNT_TICKS)
			# Defending time (docs/plataforma.md §8): only the owning realm, and not in a forced cycle.
			if defending and candidate.realm == owner and not player.gm_forced:
				score_keeper.add_defend_ticks(player.net_id, FortressState.PRESENCE_RECOUNT_TICKS)
		# Objective merits (progresion.md §6.2): not in a forced cycle nor for someone flagged by a GM command.
		if not forced and not player.gm_forced:
			objective_time.emit(site.id, player.net_id, FortressState.PRESENCE_RECOUNT_TICKS, s)
	site.presence = counts


# Real capture at tick [param s] (advance gave FORT_CAPTURED): if it is not forced, the list of those
# who were in the circle adds a capture to each one and goes out through fortress_captured
# (docs/plataforma.md §8). The list is computed once, with the candidates of this tick.
func _on_captured(site: Site, s: int) -> void:
	if is_forced(site.id):
		# The new owner comes from a forced change: the cycle remains so until its garrison arrives.
		site.forced = true
		return
	var owner: int = site.state.owner
	var in_circle := PackedInt32Array()
	if candidates_source.is_valid():
		for candidate: FortressPresence.Candidate in candidates_source.call(s):
			var player: PlayerCandidate = candidate as PlayerCandidate
			if player == null or player.realm != owner or player.gm_forced:
				continue
			if FortressPresence.is_present(site.definition, site.circle_center, site.circle_radius, player, s):
				in_circle.append(player.net_id)
	in_circle.sort()
	if score_keeper != null:
		for net_id: int in in_circle:
			score_keeper.add_capture(net_id)
	fortress_captured.emit(site.id, owner, in_circle, s)


# Effects of the phase and owner changes made by advance(): withdraw the NPCs, spawn the garrison.
func _note_transitions(site: Site, tick: int, events: PackedInt32Array, previous_owner: int,
		previous_phase: int) -> void:
	var state: FortressState = site.state
	if events.has(WarEvents.FORT_RESET):
		# The periodic reset is a real change: it starts an unforced cycle.
		site.forced = false
		_retire_defenders(site, tick)
		site.gate_damage_announced = false
		garrison_due.emit(site.id, state.owner, tick, true)
		return
	if state.owner != previous_owner:
		_retire_defenders(site, tick)
		site.gate_damage_announced = false
	if previous_phase != FortressState.Phase.GARRISONED \
			and state.phase == FortressState.Phase.GARRISONED:
		site.forced = false
		garrison_due.emit(site.id, state.owner, tick,
				previous_phase == FortressState.Phase.CONSOLIDATING)


func _retire_defenders(site: Site, tick: int) -> void:
	site.defenders.clear()
	site.captain_net_id = 0
	site.pending_killer_realm = -1
	site.guards_due_notified = false
	defenders_retired.emit(site.id, tick)


# After a reset or an owner change by command: notices, NPCs and repair (which waits if someone is
# in the doorway).
func _after_hard_reset(site: Site, tick: int, events: PackedInt32Array, health_before: int,
		last_damage_before: int) -> void:
	_retire_defenders(site, tick)
	site.gate_damage_announced = false
	garrison_due.emit(site.id, site.state.owner, tick, true)
	_emit_war(site, tick, events, RealmCatalog.NEUTRAL_CODE)
	_hold_repair_if_blocked(site, health_before, last_damage_before)


func _captain_died(site: Site, tick: int, killer_realm: int) -> bool:
	var events: PackedInt32Array = site.state.on_captain_died(tick, killer_realm)
	site.captain_net_id = 0
	site.pending_killer_realm = -1
	_emit_war(site, tick, events, killer_realm)
	return not events.is_empty()


func _emit_war(site: Site, tick: int, events: PackedInt32Array, caller_realm: int) -> void:
	for war_event: int in events:
		war_event_emitted.emit(NetMessages.EntityEvent.war(site.entity.net_id, tick, war_event,
				site.state.event_realm(war_event, caller_realm)))


# A hit on a registered defender marks the fort as attacked and may give the notice.
func _on_defender_hit(event: NetMessages.EntityEvent) -> void:
	var attacker: NetEntity = _registry.get_entity(event.attacker) if _registry != null else null
	if attacker == null:
		return
	for site: Site in _sites:
		if not site.defenders.has(event.net_id):
			continue
		site.state.on_defender_damaged(event.tick, attacker.realm)
		if site.state.claim_attack_notice(event.tick):
			_emit_war(site, event.tick, PackedInt32Array([WarEvents.UNDER_ATTACK]), attacker.realm)
		return


func _on_death(event: NetMessages.EntityEvent) -> void:
	for site: Site in _sites:
		if not site.defenders.has(event.net_id):
			continue
		site.defenders.erase(event.net_id)
		if site.captain_net_id == event.net_id:
			# With fort_kill_captain, pending_killer_realm is already set and kill_captain marks the cycle as
			# forced; a death in combat is a real change.
			var by_command: bool = site.pending_killer_realm >= 0
			var killer_realm: int = site.pending_killer_realm
			if event.killer != 0 and _registry != null:
				var killer: NetEntity = _registry.get_entity(event.killer)
				if killer != null:
					killer_realm = killer.realm
			if _captain_died(site, event.tick, maxi(killer_realm, 0)) and not by_command:
				site.forced = false
		return


# --- The gate -----------------------------------------------------------------------------------

# If a repair made by the state (capture, reset) closes a gate that was broken with someone in the
# doorway, it is undone: the gate stays broken and the repair waits. An intact gate (damaged or
# not) stays repaired: closing it does not change its collision, so there is nobody to trap.
func _hold_repair_if_blocked(site: Site, health_before: int, last_damage_before: int) -> void:
	var state: FortressState = site.state
	if health_before <= 0 and state.gate_health > health_before and _is_gate_blocked(site):
		state.gate_health = health_before
		state.gate_last_damage_tick = last_damage_before
		site.repair_pending = true


# Repairs the gate when due (after 5 min without damage or a postponed repair). Only the broken one
# waits for the doorway to be clear: an intact one is repaired immediately. A broken one takes no
# damage, so what waits does not go stale (and a hit on an intact one cancels what is pending:
# on_structure_hit).
func _repair_if_due(site: Site, tick: int) -> void:
	var state: FortressState = site.state
	if not site.repair_pending and not state.gate_repair_due(tick):
		return
	if state.is_gate_broken() and _is_gate_blocked(site):
		site.repair_pending = true
		return
	if state.gate_health < state.gate_max:
		state.repair_gate()
	site.repair_pending = false
	site.gate_damage_announced = false


# true if any character overlaps the gate doorway (the box of the closed gate).
func _is_gate_blocked(site: Site) -> bool:
	if site.target == null or not bodies_source.is_valid():
		return false
	var bodies: PackedVector3Array = bodies_source.call()
	for feet: Vector3 in bodies:
		if HitShapes.capsule_overlaps_box(feet, HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT,
				site.target.box, site.target.half_extents):
			return true
	return false


# Sets the gate layers according to the current owner and broken state: they apply from the next tick.
func _sync_gate(site: Site) -> void:
	if site.gate == null:
		return
	var broken: bool = site.state.is_gate_broken()
	if site.applied_owner != site.state.owner or site.applied_broken != broken:
		site.applied_owner = site.state.owner
		site.applied_broken = broken
		site.gate.set_state(site.applied_owner, broken)


# --- OBJECT_STATE -------------------------------------------------------------------------------

func _flush_object_state(site: Site, tick: int) -> void:
	var state: FortressState = site.state
	var broken: bool = state.is_gate_broken()
	var collision_changed: bool = site.sent_owner != state.owner or site.sent_broken != broken
	var due: bool = tick - site.last_sent_tick >= OBJECT_STATE_INTERVAL_TICKS
	if not due and not collision_changed:
		return
	var changed: PackedInt32Array = _fields_to_send(site)
	if changed.is_empty():
		return
	site.last_sent_tick = tick
	var object_state: NetMessages.ObjectState = NetMessages.ObjectState.from_fortress_fields(
			site.entity.net_id, tick, state, changed)
	for field_id: int in changed:
		FortressFields.set_value(site.last_sent, field_id, FortressFields.get_value(state, field_id))
	site.sent_owner = state.owner
	site.sent_broken = broken
	object_state_emitted.emit(object_state)


# Fields that changed since the last send, without the attack notice if it has barely advanced.
func _fields_to_send(site: Site) -> PackedInt32Array:
	var changed: PackedInt32Array = site.state.changed_fields_since(site.last_sent)
	var index: int = changed.find(FortressFields.UNDER_ATTACK_UNTIL_TICK)
	if index >= 0:
		var advance: int = site.state.under_attack_until_tick - site.last_sent.under_attack_until_tick
		if advance > 0 and advance < UNDER_ATTACK_MIN_ADVANCE_TICKS:
			changed.remove_at(index)
	return changed


# --- Debug commands -----------------------------------------------------------------------------

## Registers in [param commands] the fortress commands, with their fixed network ids (8
## [code]fort_reset[/code], 9 [code]fort_owner[/code], 10 [code]fort_kill_captain[/code], 11
## [code]fort_capture_speed[/code]) and their console version. [param next_tick] is
## [code]() -> int[/code]: the tick the server is about to simulate (the one the command falls on).
## [br]The network ones act on the fortress nearest to the sender; the console ones, on the one
## named at the end or, failing that, on the first.
func register_commands(commands: CommandRegistry, next_tick: Callable) -> void:
	_next_tick_source = next_tick
	commands.register(&"fort_reset", "fort_reset [fortaleza]", _console_reset, _net_reset)
	commands.register(&"fort_owner", "fort_owner <vardheim|solmarch|askarra|neutral> [fortaleza]",
			_console_owner, _net_owner)
	commands.register(&"fort_kill_captain", "fort_kill_captain [fortaleza]",
			_console_kill_captain, _net_kill_captain)
	commands.register(&"fort_capture_speed", "fort_capture_speed <1-255> [fortaleza]",
			_console_capture_speed, _net_capture_speed)


func _command_tick() -> int:
	return int(_next_tick_source.call()) if _next_tick_source.is_valid() else 0


# The fortress nearest to whoever sends a network command, or an empty string.
func _fortress_of_sender(ctx: CommandRegistry.Context) -> StringName:
	if ctx.peer == null or ctx.peer.entity == null:
		return &""
	return get_nearest_fortress_id(ctx.peer.entity.get_position())


func _sender_realm(ctx: CommandRegistry.Context) -> int:
	return ctx.peer.entity.realm if ctx.peer != null and ctx.peer.entity != null else 0


# The fortress named in console argument [param index] or the first one.
func _fortress_from_args(ctx: CommandRegistry.Context, index: int) -> StringName:
	if ctx.args.size() > index:
		var named: StringName = StringName(ctx.args[index])
		return named if _sites_by_id.has(named) else &""
	return _sites[0].id if not _sites.is_empty() else &""


func _net_reset(ctx: CommandRegistry.Context) -> int:
	if not ctx.payload.is_empty():
		return CommandRegistry.Result.BAD_ARGUMENTS
	var fortress_id: StringName = _fortress_of_sender(ctx)
	if fortress_id.is_empty() or not reset_fortress(fortress_id, _command_tick()):
		return CommandRegistry.Result.REFUSED
	ctx.note = String(fortress_id)
	return CommandRegistry.Result.OK


func _net_owner(ctx: CommandRegistry.Context) -> int:
	if ctx.payload.size() != 1 or ctx.payload[0] > 3:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var fortress_id: StringName = _fortress_of_sender(ctx)
	if fortress_id.is_empty() or not set_owner(fortress_id, ctx.payload[0], _command_tick()):
		return CommandRegistry.Result.REFUSED
	ctx.note = "%s -> %s" % [fortress_id, NetProtocol.realm_display_name(ctx.payload[0])]
	return CommandRegistry.Result.OK


func _net_kill_captain(ctx: CommandRegistry.Context) -> int:
	if not ctx.payload.is_empty():
		return CommandRegistry.Result.BAD_ARGUMENTS
	var fortress_id: StringName = _fortress_of_sender(ctx)
	if fortress_id.is_empty() \
			or not kill_captain(fortress_id, _command_tick(), _sender_realm(ctx)):
		return CommandRegistry.Result.REFUSED
	ctx.note = String(fortress_id)
	return CommandRegistry.Result.OK


func _net_capture_speed(ctx: CommandRegistry.Context) -> int:
	if ctx.payload.size() != 1 or ctx.payload[0] < 1:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var fortress_id: StringName = _fortress_of_sender(ctx)
	if fortress_id.is_empty() or not set_capture_speed(fortress_id, ctx.payload[0]):
		return CommandRegistry.Result.REFUSED
	ctx.note = "%s x%d" % [fortress_id, ctx.payload[0]]
	return CommandRegistry.Result.OK


func _console_reset(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() > 1:
		return "Uso: fort_reset [fortaleza]"
	var fortress_id: StringName = _fortress_from_args(ctx, 0)
	if fortress_id.is_empty():
		return "No hay ninguna fortaleza «%s»" % (ctx.args[0] if not ctx.args.is_empty() else "")
	reset_fortress(fortress_id, _command_tick())
	return "%s vuelve a ser neutral" % fortress_id


func _console_owner(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty() or ctx.args.size() > 2:
		return "Uso: fort_owner <vardheim|solmarch|askarra|neutral> [fortaleza]"
	var realm: int = _realm_from_text(ctx.args[0])
	if realm < 0:
		return "Reino desconocido: %s (vardheim, solmarch, askarra o neutral)" % ctx.args[0]
	var fortress_id: StringName = _fortress_from_args(ctx, 1)
	if fortress_id.is_empty():
		return "No hay ninguna fortaleza «%s»" % (ctx.args[1] if ctx.args.size() > 1 else "")
	set_owner(fortress_id, realm, _command_tick())
	return "%s es ahora de %s" % [fortress_id, WarEvents.realm_label(realm)]


func _console_kill_captain(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() > 1:
		return "Uso: fort_kill_captain [fortaleza]"
	var fortress_id: StringName = _fortress_from_args(ctx, 0)
	if fortress_id.is_empty():
		return "No hay ninguna fortaleza «%s»" % (ctx.args[0] if not ctx.args.is_empty() else "")
	if not kill_captain(fortress_id, _command_tick(), RealmCatalog.NEUTRAL_CODE):
		return "El capitán de %s no está guardando el fuerte" % fortress_id
	return "El capitán de %s ha muerto" % fortress_id


func _console_capture_speed(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty() or ctx.args.size() > 2 or not ctx.args[0].is_valid_int():
		return "Uso: fort_capture_speed <1-255> [fortaleza]"
	var factor: int = ctx.args[0].to_int()
	var fortress_id: StringName = _fortress_from_args(ctx, 1)
	if fortress_id.is_empty():
		return "No hay ninguna fortaleza «%s»" % (ctx.args[1] if ctx.args.size() > 1 else "")
	if not set_capture_speed(fortress_id, factor):
		return "El factor debe estar entre 1 y 255"
	return "Captura de %s a x%d" % [fortress_id, factor]


# Realm code from a text ("vardheim", "neutral", "0"...), or -1.
static func _realm_from_text(text: String) -> int:
	var clean: String = text.strip_edges().to_lower()
	if clean == "neutral" or clean == "huecos" or clean == "0":
		return RealmCatalog.NEUTRAL_CODE
	if clean.is_valid_int():
		var code: int = clean.to_int()
		return code if code >= 1 and code <= 3 else -1
	var realm: int = NetZones.realm_from_name(clean)
	return realm if realm != NetProtocol.Realm.NONE else -1


# --- Helpers ------------------------------------------------------------------------------------

# The definition of the node: the [FortressDefinition] itself or the path of its .tres.
static func _definition_of(node: Node3D) -> FortressDefinition:
	var value: Variant = node.get_meta(NetZones.fortress_definition_meta(), null)
	if value is FortressDefinition:
		return value as FortressDefinition
	if value is String or value is StringName:
		var path: String = String(value)
		if ResourceLoader.exists(path):
			return load(path) as FortressDefinition
	return null
