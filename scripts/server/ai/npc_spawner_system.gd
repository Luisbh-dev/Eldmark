class_name NpcSpawnerSystem
extends RefCounted
## Creates and removes the NPCs of the zone's spawners ([NpcSpawner]) (docs/fortress.md, section 4.3; MUN-09 to
## MUN-12 and GUE-11) and runs the navigation, the brains' world and the tokens.
## [br][br]
## [b]Spawners.[/b] Each [NpcSpawner] is a post with a condition: always ([constant NpcSpawner.Condition.ALWAYS],
## the Gate Guardians), while the fort is neutral (the Hollow and the Ford Captain) or while it has an
## owner (the garrison). If a fort has no spawners of its own for the owner, its garrison comes out of the same posts
## as the Hollow and the Captain, with the definition each one names in [member NpcDefinition.garrison_id] (guards and
## captain of the owning realm) and the same patrol route. A post with its own respawn
## ([member NpcSpawner.respawn_s] greater than 0) replenishes its dead NPC on the exact tick; one without it is
## replenished by the fortress ([signal FortressController.garrison_due], [signal FortressController.guards_respawn_due]) or by the full respawn
## of the Hollow. When it becomes inactive, or when the owner changes ([signal FortressController.defenders_retired]),
## the living are removed.
## [br][br]
## [b]Fortress.[/b] It reads the state with [method FortressController.get_fortress_state] and reports to it with
## [method FortressController.register_captain] and [method FortressController.register_defender] (so the controller knows
## when the captain falls and when a defender is attacked) and [method FortressController.set_guards_alive]. Dead NPCs
## report with [signal npc_died].
## [br][br]
## [b]Full respawn of the Hollow[/b] (MUN-10): with the fort neutral and some of the Hollow or the Captain missing,
## if no player is within [constant FULL_RESPAWN_RADIUS] m of the fort for
## [constant FULL_RESPAWN_EMPTY_TICKS] ticks (2 min), they all return (and the Captain, if he had fallen) as at creation:
## any reinforcements still alive are removed and the Captain who had not fallen gets his call back.
## [br][br]
## [b]Reinforcements[/b] (those the Captain calls, [member NpcDefinition.reinforcement_id]): they come from no post and
## leave only on dying, when the defenders are withdrawn (capture, reset) or with the full respawn. There are never more
## alive than the Captain calls in one go ([member NpcDefinition.reinforcement_count]) per fortress.
## [br][br]
## [b]Tick.[/b] [method begin_tick] and the brains (step 0), and [method step] (after step 4b: additions, corpse
## removal and debugging). The [code]TELEGRAPH[/code] warnings of heavy attacks are sent by the [ZoneServer]
## for all NPCs.

## An NPC has died. [param spawner] is the spawner it came from (null for reinforcements) and [param killer] the
## net_id of whoever killed it (0 = the environment).
signal npc_died(net_id: int, spawner: Node, killer: int)
## An NPC from a spawner has appeared.
signal npc_spawned(net_id: int, spawner: Node)

## Ticks a corpse stays in the world before being removed (5 s).
const CORPSE_TICKS: int = 300
## Ticks to wait for navigation before spawning without it.
const NAVIGATION_WAIT_TICKS: int = 600
## Distance (m) to the fort at which a player prevents the full respawn, and ticks (2 min) it must be absent.
const FULL_RESPAWN_RADIUS: float = 40.0
const FULL_RESPAWN_EMPTY_TICKS: int = 7200
## How many ticks between full-respawn checks.
const FULL_RESPAWN_CHECK_TICKS: int = 6
## How many ticks between NPC debug output writes, and radius (m) of the "nearby" NPCs.
const DEBUG_INTERVAL_TICKS: int = 60
const DEBUG_RADIUS: float = 60.0
## Distance (m) around the caller at which reinforcements appear.
const REINFORCEMENT_RADIUS: float = 3.5

## An NPC created by the system.
class Member:
	extends RefCounted

	var net_id: int = 0
	var brain: HfsmBrain = null
	var entity: NetEntity = null
	var slot: Slot = null
	var fortress_id: StringName = &""
	var definition: NpcDefinition = null
	## Tick of death (-1 = alive).
	var death_tick: int = -1


## A post: a spawner and what it has created.
class Slot:
	extends RefCounted

	var index: int = 0
	var marker: Node3D = null
	var fortress_id: StringName = &""
	## true: it is the owner's garrison post, derived from that of a Hollow NPC.
	var mirror: bool = false
	var active: bool = false
	var need_fill: bool = false
	var last_definition: StringName = &""
	var last_realm: int = -1
	## The live state of its fortress (null if it hangs from none) and the key (owner and phase) with which
	## [member wanted] was computed: it is only recomputed when it changes.
	var state: FortressState = null
	var state_key: int = -1
	var wanted: Dictionary = {}
	var spawn_count: int = 0
	var members: Array[Member] = []
	## Ticks at which the dead respawn (only with own respawn).
	var due: PackedInt32Array = PackedInt32Array()

	func live_count() -> int:
		var total: int = 0
		for member: Member in members:
			if member.death_tick < 0:
				total += 1
		return total

var _server: ZoneServer = null
var _world_node: Node3D = null
var _world: NpcWorld = null
var _navigation: NpcNavigation = null
var _fortresses: FortressController = null
var _slots: Array[Slot] = []
# Those that do not come from a post (the Captain's reinforcements).
var _extras: Array[Member] = []
var _members_by_id: Dictionary[int, Member] = {}
# State of the gate that navigation was told: id -> [owner, broken].
var _gate_applied: Dictionary[StringName, Vector2i] = {}
# Queue of what the fortress controller reports (handled in step()).
var _retired: Array[StringName] = []
var _garrison_requests: Array[Dictionary] = []
var _guard_requests: Array[StringName] = []
var _empty_ticks: Dictionary[StringName, int] = {}
var _waited_ticks: int = 0
var _spawn_total: int = 0
var _death_total: int = 0
var _removed_total: int = 0
var _reinforcements_total: int = 0
var _full_respawns: int = 0
var _debug_enabled: bool = false
# Definitions that replace the catalog's on this server (tests): id -> definition.
var _overrides: Dictionary[StringName, NpcDefinition] = {}
var _debug_entity: NetEntity = null
## [code](line: String) -> void[/code]: the server's log, for debugging.
var log_sink: Callable = Callable()


# --- Setup ------------------------------------------------------------------------------------

## Reads the spawners of [param world] (the zone's root, in the tree), sets up navigation (if the zone has a
## mesh) and hooks into the combat and fortresses of [param server]. Returns how many posts it created.
func setup(server: ZoneServer, world: Node3D, zone_id: String) -> int:
	_server = server
	_world_node = world
	_fortresses = server.get_fortresses()
	_world = NpcWorld.new()
	_world.zone_id = StringName(zone_id)
	_world.combat = server.get_combat()
	_world.safe_areas = server.get_safe_areas()
	_world.space_provider = Callable(server, "get_physics_space")
	_world.teleporter = Callable(server, "teleport")
	_world.reinforcer = Callable(self, "_spawn_reinforcements")
	_setup_navigation(zone_id)
	_world.navigation = _navigation
	_collect_slots()
	_world.combat.event_emitted.connect(_on_combat_event)
	if _fortresses != null:
		_fortresses.defenders_retired.connect(_on_defenders_retired)
		_fortresses.garrison_due.connect(_on_garrison_due)
		_fortresses.guards_respawn_due.connect(_on_guards_respawn_due)
	return _slots.size()


## Removes the NPCs, the tokens and the navigation (server shutdown).
func dispose() -> void:
	for member: Member in _members_by_id.values():
		if member.brain != null:
			member.brain.unbind()
	_members_by_id.clear()
	_slots.clear()
	_extras.clear()
	if _world != null:
		_world.clear()
	if _navigation != null:
		_navigation.dispose()
		_navigation = null


# --- Queries ----------------------------------------------------------------------------------

## Replaces, on this server, catalog definition [param id] with [param definition] (null removes the
## replacement) for NPCs created from now on: used by tests that need weaker NPCs without touching
## [code]data/npcs/[/code] or the catalog, which the whole process shares. [param definition] keeps the catalog's id and
## number (the SPAWN's [code]npc_def_id[/code] comes from [member NpcDefinition.id]).
func set_definition_override(id: StringName, definition: NpcDefinition) -> void:
	if definition == null:
		_overrides.erase(id)
	else:
		_overrides[id] = definition


## The definition [param id] this server uses: the replacement, if any, or the catalog's.
func get_definition(id: StringName) -> NpcDefinition:
	return _definition_of(id)


## The world the brains see (tokens, groups, navigation).
func get_world() -> NpcWorld:
	return _world


## The navigation (null if the zone has no mesh).
func get_navigation() -> NpcNavigation:
	return _navigation


## Number of posts.
func get_slot_count() -> int:
	return _slots.size()


## The zone's spawners (nodes), in the order in which the posts were created.
func get_spawners() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for slot: Slot in _slots:
		result.append(slot.marker)
	return result


## net_id of the living NPCs of spawner [param spawner] (or of all if null), in spawn order.
func get_alive_ids(spawner: Node = null) -> Array[int]:
	var ids: Array[int] = []
	for slot: Slot in _slots:
		if spawner != null and slot.marker != spawner:
			continue
		for member: Member in slot.members:
			if member.death_tick < 0:
				ids.append(member.net_id)
	if spawner == null:
		for member: Member in _extras:
			if member.death_tick < 0:
				ids.append(member.net_id)
	return ids


## net_id of all the system's NPCs (living and corpses) that hang from spawner [param spawner].
func get_member_ids(spawner: Node) -> Array[int]:
	var ids: Array[int] = []
	for slot: Slot in _slots:
		if slot.marker == spawner:
			for member: Member in slot.members:
				ids.append(member.net_id)
	return ids


## The brain of NPC [param net_id] (also that of a loose NPC that comes from no spawner), or null.
func get_brain(net_id: int) -> HfsmBrain:
	var member: Member = _members_by_id.get(net_id)
	if member != null:
		return member.brain
	return _server.get_npc_brain(net_id) as HfsmBrain if _server != null else null


## How many of the system's NPCs are alive.
func get_alive_count() -> int:
	var total: int = 0
	for member: Member in _members_by_id.values():
		if member.death_tick < 0:
			total += 1
	return total


## true if the post of spawner [param spawner] is active now.
func is_active(spawner: Node) -> bool:
	for slot: Slot in _slots:
		if slot.marker == spawner:
			return slot.active
	return false


## true if navigation is ready or the zone has none.
func is_ready() -> bool:
	return _navigation == null or _navigation.is_ready()


## Summary for the server report.
func get_report() -> Dictionary:
	return {
		"slots": _slots.size(), "alive": get_alive_count(), "spawned": _spawn_total, "died": _death_total,
		"removed": _removed_total, "reinforcements": _reinforcements_total,
		"full_respawns": _full_respawns,
		"tokens": _world.tokens.get_stats() if _world != null else {},
		"paths": _navigation.get_paths_computed() if _navigation != null else 0,
		"navigation": _navigation != null and _navigation.is_ready(),
		"queries": _world.queries if _world != null else 0,
		"line_of_sight_checks": _world.line_of_sight_checks if _world != null else 0,
	}


# --- The tick ---------------------------------------------------------------------------------

## Step 0 of tick [param tick]: the brains will think with the state after the previous tick.
func begin_tick(tick: int) -> void:
	if _world != null:
		_world.begin_tick(tick)


## After step 4b of tick [param tick]: navigation, additions and removals, corpses, heavy-attack warnings and
## debugging.
func step(tick: int) -> void:
	if _world == null:
		return
	if _navigation != null and not _navigation.poll():
		_waited_ticks += 1
		if _waited_ticks < NAVIGATION_WAIT_TICKS:
			return
	_sync_gates()
	_process_requests(tick)
	for slot: Slot in _slots:
		_step_slot(slot, tick)
	_remove_corpses(tick)
	if tick % FULL_RESPAWN_CHECK_TICKS == 0:
		_check_full_respawns(tick)
	if _debug_enabled and tick % DEBUG_INTERVAL_TICKS == 0:
		_write_debug()


# --- Spawners ---------------------------------------------------------------------------------

func _collect_slots() -> void:
	var neutral_by_fortress: Dictionary[StringName, Array] = {}
	var owner_spawner_fortresses: Dictionary[StringName, bool] = {}
	var spawners: Array[NpcSpawner] = []
	for node: Node3D in NetZones.get_npc_spawners(_world_node):
		var spawner: NpcSpawner = node as NpcSpawner
		if spawner != null:
			spawners.append(spawner)
	for spawner: NpcSpawner in spawners:
		var fortress_id: StringName = _fortress_id_of(spawner)
		_add_slot(spawner, fortress_id, false)
		if spawner.condition == NpcSpawner.Condition.FORT_OWNER:
			owner_spawner_fortresses[fortress_id] = true
		elif spawner.condition == NpcSpawner.Condition.FORT_NEUTRAL:
			var list: Array = neutral_by_fortress.get(fortress_id, [])
			list.append(spawner)
			neutral_by_fortress[fortress_id] = list
	# Without spawners of its own for the owner, its garrison comes out of the Hollow's posts.
	for fortress_id: StringName in neutral_by_fortress:
		if fortress_id.is_empty() or owner_spawner_fortresses.has(fortress_id):
			continue
		for spawner: NpcSpawner in neutral_by_fortress[fortress_id]:
			var base: NpcDefinition = _definition_of(spawner.npc_id)
			if base != null and base.garrison_id != &"":
				_add_slot(spawner, fortress_id, true)


func _add_slot(spawner: NpcSpawner, fortress_id: StringName, mirror: bool) -> void:
	var slot := Slot.new()
	slot.index = _slots.size()
	slot.marker = spawner
	slot.fortress_id = fortress_id
	slot.mirror = mirror
	if _fortresses != null and not fortress_id.is_empty():
		slot.state = _fortresses.get_fortress_state(fortress_id)
	_slots.append(slot)


# Id of the fortress the spawner hangs from, or an empty string.
func _fortress_id_of(spawner: NpcSpawner) -> StringName:
	if _fortresses == null:
		return &""
	var node: Node = spawner.get_fortress()
	if node == null:
		return &""
	for fortress_id: StringName in _fortresses.get_fortress_ids():
		if _fortresses.get_node_of(fortress_id) == node:
			return fortress_id
	return &""


# What the post wants now: whether it is active, which definition and which side.
func _desired(slot: Slot) -> Dictionary:
	var spawner: NpcSpawner = slot.marker as NpcSpawner
	var state: FortressState = _fortresses.get_fortress_state(slot.fortress_id) \
			if _fortresses != null and not slot.fortress_id.is_empty() else null
	var definition_id: StringName = spawner.npc_id
	var realm: int = RealmCatalog.code_of(spawner.realm) if spawner.realm != &"" else RealmCatalog.NEUTRAL_CODE
	var active: bool = false
	if slot.mirror:
		var base: NpcDefinition = _definition_of(spawner.npc_id)
		if state != null and base != null and state.owner != RealmCatalog.NEUTRAL_CODE \
				and state.phase != FortressState.Phase.CONSOLIDATING:
			active = true
			definition_id = base.garrison_id
			realm = state.owner
	else:
		match spawner.condition:
			NpcSpawner.Condition.ALWAYS:
				active = true
			NpcSpawner.Condition.FORT_NEUTRAL:
				active = state != null and state.owner == RealmCatalog.NEUTRAL_CODE
				realm = RealmCatalog.NEUTRAL_CODE if spawner.realm == &"" else realm
			NpcSpawner.Condition.FORT_OWNER:
				active = state != null and state.owner != RealmCatalog.NEUTRAL_CODE \
						and state.phase != FortressState.Phase.CONSOLIDATING
				if state != null:
					realm = state.owner
	return {"active": active, "definition": definition_id, "realm": realm}


func _step_slot(slot: Slot, tick: int) -> void:
	var key: int = slot.state.owner * 8 + slot.state.phase if slot.state != null else 0
	if key != slot.state_key or slot.wanted.is_empty():
		slot.state_key = key
		slot.wanted = _desired(slot)
	var wanted: Dictionary = slot.wanted
	var active: bool = wanted["active"]
	var changed: bool = active and slot.active and (slot.last_definition != wanted["definition"]
			or slot.last_realm != wanted["realm"])
	if slot.active and (not active or changed):
		_retire_slot(slot, tick)
	if active and (not slot.active or changed):
		slot.need_fill = true
	slot.active = active
	slot.last_definition = wanted["definition"]
	slot.last_realm = wanted["realm"]
	if not active:
		return
	if slot.need_fill:
		slot.need_fill = false
		_fill_slot(slot, tick)
	# Own respawn (on the exact tick).
	var index: int = 0
	while index < slot.due.size():
		if slot.due[index] <= tick:
			slot.due.remove_at(index)
			if slot.live_count() < (slot.marker as NpcSpawner).max_alive:
				_spawn(slot, tick)
		else:
			index += 1


# Creates the NPCs that are missing up to the post's maximum.
func _fill_slot(slot: Slot, tick: int) -> void:
	var spawner: NpcSpawner = slot.marker as NpcSpawner
	# With the captain fallen (a platform-loaded fort in VULNERABLE or CAPTURING, docs/platform.md §8) its
	# post stays empty: it returns with the garrison (garrison_due) or with the full respawn of the Hollow.
	if slot.state != null and not slot.state.captain_alive and _is_captain_slot(slot):
		slot.due.clear()
		return
	while slot.live_count() < spawner.max_alive:
		if _spawn(slot, tick) == null:
			break
	slot.due.clear()
	_update_guards(slot.fortress_id)


func _spawn(slot: Slot, tick: int) -> Member:
	var wanted: Dictionary = slot.wanted if not slot.wanted.is_empty() else _desired(slot)
	var definition: NpcDefinition = _definition_of(wanted["definition"])
	if definition == null:
		push_warning("[Eldmark] El generador '%s' pide la definición de PNJ '%s', que no existe"
				% [slot.marker.name, wanted["definition"]])
		return null
	var spawner: NpcSpawner = slot.marker as NpcSpawner
	var transform: Transform3D = spawner.global_transform
	var yaw: float = _yaw_of(transform)
	var route: PackedVector3Array = NetZones.get_patrol_route(_world_node, spawner.patrol_route)
	var member: Member = _create_member(definition, wanted["realm"], transform.origin, yaw,
			slot.fortress_id, spawner.alert_group, route, (slot.index + 1) * 7919 + slot.spawn_count * 104729)
	if member == null:
		return null
	slot.spawn_count += 1
	member.slot = slot
	slot.members.append(member)
	npc_spawned.emit(member.net_id, spawner)
	return member


# Creates the NPC of [param definition] and registers it. null if the server cannot (no ids, stopped).
func _create_member(definition: NpcDefinition, realm: int, position: Vector3, yaw: float,
		fortress_id: StringName, group: StringName, route: PackedVector3Array, rng_seed: int) -> Member:
	var brain := HfsmBrain.new(rng_seed)
	var net_id: int = _server.add_npc(brain, definition.display_name, realm, position, yaw, false, definition)
	if net_id <= 0:
		return null
	var entity: NetEntity = _server.get_registry().get_entity(net_id)
	var combatant: Combatant = _server.get_combat().get_combatant(net_id)
	brain.bind(_world, entity, combatant, definition, position, yaw, route, group)
	var member := Member.new()
	member.net_id = net_id
	member.brain = brain
	member.entity = entity
	member.definition = definition
	member.fortress_id = fortress_id
	brain.owner_slot = member
	_members_by_id[net_id] = member
	_spawn_total += 1
	if _fortresses != null and not fortress_id.is_empty():
		if definition.is_boss:
			_fortresses.register_captain(fortress_id, net_id)
		else:
			_fortresses.register_defender(fortress_id, net_id)
	return member


# Removes all of the post's NPCs (living and corpses).
func _retire_slot(slot: Slot, _tick: int) -> void:
	for member: Member in slot.members.duplicate():
		_remove_member(member)
	slot.members.clear()
	slot.due.clear()
	_update_guards(slot.fortress_id)


func _remove_member(member: Member) -> void:
	member.brain.unbind()
	_members_by_id.erase(member.net_id)
	if _fortresses != null and not member.fortress_id.is_empty():
		_fortresses.unregister_defender(member.fortress_id, member.net_id)
	_server.remove_npc(member.net_id)
	_removed_total += 1


# Tells the fortress how many guards of its garrison (those that are not the captain) are alive; it only makes
# sense with an owner.
func _update_guards(fortress_id: StringName) -> void:
	if _fortresses == null or fortress_id.is_empty():
		return
	var state: FortressState = _fortresses.get_fortress_state(fortress_id)
	if state == null or state.owner == RealmCatalog.NEUTRAL_CODE:
		return
	var alive: int = 0
	for slot: Slot in _slots:
		if slot.fortress_id != fortress_id or not slot.active:
			continue
		for member: Member in slot.members:
			if member.death_tick < 0 and not member.definition.is_boss:
				alive += 1
	_fortresses.set_guards_alive(fortress_id, alive)


func _remove_corpses(tick: int) -> void:
	for slot: Slot in _slots:
		_remove_corpses_of(slot.members, tick)
	_remove_corpses_of(_extras, tick)


func _remove_corpses_of(members: Array[Member], tick: int) -> void:
	var index: int = 0
	while index < members.size():
		var member: Member = members[index]
		if member.death_tick >= 0 and tick - member.death_tick >= CORPSE_TICKS:
			members.remove_at(index)
			_remove_member(member)
		else:
			index += 1


# --- What combat and the fortress report -----------------------------------------------------

func _on_combat_event(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
	if event.event != NetMessages.EntityEvent.Kind.DEATH:
		return
	var member: Member = _members_by_id.get(event.net_id)
	if member == null or member.death_tick >= 0:
		return
	member.death_tick = event.tick
	member.brain.unbind()
	_death_total += 1
	var slot: Slot = member.slot
	if slot != null:
		var spawner: NpcSpawner = slot.marker as NpcSpawner
		var ticks: int = spawner.get_respawn_ticks()
		if ticks > 0:
			slot.due.append(event.tick + ticks)
		_update_guards(slot.fortress_id)
	npc_died.emit(member.net_id, slot.marker if slot != null else null, event.killer)


func _on_defenders_retired(fortress_id: StringName, _tick: int) -> void:
	_retired.append(fortress_id)


func _on_garrison_due(fortress_id: StringName, _owner_realm: int, _tick: int, full: bool) -> void:
	_garrison_requests.append({"fortress": fortress_id, "full": full})


func _on_guards_respawn_due(fortress_id: StringName, _tick: int) -> void:
	_guard_requests.append(fortress_id)


# Handles what the controller reported on this tick.
func _process_requests(tick: int) -> void:
	for fortress_id: StringName in _retired:
		for slot: Slot in _slots:
			if slot.fortress_id == fortress_id and slot.active:
				_retire_slot(slot, tick)
				slot.need_fill = true
		_retire_extras(fortress_id)
	_retired.clear()
	for request: Dictionary in _garrison_requests:
		for slot: Slot in _slots:
			if slot.fortress_id != request["fortress"]:
				continue
			var captain_slot: bool = _is_captain_slot(slot)
			if request["full"] or captain_slot:
				slot.need_fill = true
	_garrison_requests.clear()
	for fortress_id: StringName in _guard_requests:
		for slot: Slot in _slots:
			if slot.fortress_id == fortress_id and slot.active and not _is_captain_slot(slot):
				slot.need_fill = true
	_guard_requests.clear()


# true if the post is the captain's (its definition is a boss).
func _is_captain_slot(slot: Slot) -> bool:
	var definition: NpcDefinition = _definition_of(_desired(slot)["definition"])
	return definition != null and definition.is_boss


# --- Full respawn of the Hollow -----------------------------------------------------------------

func _check_full_respawns(tick: int) -> void:
	if _fortresses == null:
		return
	for fortress_id: StringName in _fortresses.get_fortress_ids():
		var state: FortressState = _fortresses.get_fortress_state(fortress_id)
		if state == null or state.owner != RealmCatalog.NEUTRAL_CODE:
			_empty_ticks.erase(fortress_id)
			continue
		if not _neutral_garrison_incomplete(fortress_id, state):
			_empty_ticks.erase(fortress_id)
			continue
		var center: Vector3 = _fortresses.get_circle(fortress_id)["center"]
		if _player_within(center, FULL_RESPAWN_RADIUS):
			_empty_ticks[fortress_id] = 0
			continue
		var empty: int = int(_empty_ticks.get(fortress_id, 0)) + FULL_RESPAWN_CHECK_TICKS
		_empty_ticks[fortress_id] = empty
		if empty >= FULL_RESPAWN_EMPTY_TICKS:
			_empty_ticks[fortress_id] = 0
			_full_respawn(fortress_id, state, tick)


# true if the neutral fort is missing some of the Hollow or the Captain.
func _neutral_garrison_incomplete(fortress_id: StringName, state: FortressState) -> bool:
	if not state.captain_alive:
		return true
	for slot: Slot in _slots:
		if slot.fortress_id != fortress_id or slot.mirror or not slot.active:
			continue
		if slot.live_count() < (slot.marker as NpcSpawner).max_alive:
			return true
	return false


func _player_within(center: Vector3, radius: float) -> bool:
	var radius_squared: float = radius * radius
	for entity: NetEntity in _server.get_registry().get_sorted():
		if entity.kind != NetProtocol.EntityKind.PLAYER:
			continue
		var offset: Vector3 = entity.get_position() - center
		if offset.x * offset.x + offset.z * offset.z <= radius_squared:
			return true
	return false


## Brings back all the Hollow and the Ford Captain of [param fortress_id] (if the fort is neutral). Normally only
## the 2-minute rule with no players nearby does it; it is public for tests and admin commands.
func force_full_respawn(fortress_id: StringName, tick: int) -> bool:
	var state: FortressState = _fortresses.get_fortress_state(fortress_id) if _fortresses != null else null
	if state == null or state.owner != RealmCatalog.NEUTRAL_CODE:
		return false
	_full_respawn(fortress_id, state, tick)
	return true


func _full_respawn(fortress_id: StringName, state: FortressState, tick: int) -> void:
	_full_respawns += 1
	# The Captain returns with the fortress: its state goes from VULNERABLE to GARRISONED.
	state.respawn_captain(tick)
	for slot: Slot in _slots:
		if slot.fortress_id == fortress_id and not slot.mirror and slot.active:
			slot.need_fill = true
			# The Captain who is still alive can call his reinforcements again, like a freshly created one.
			for member: Member in slot.members:
				if member.death_tick < 0 and member.definition.is_boss:
					member.brain.rearm_reinforcements()
	# They return "whole": without any reinforcements that remained.
	_retire_extras(fortress_id)


# Removes the reinforcements of [param fortress_id] (living and corpses).
func _retire_extras(fortress_id: StringName) -> void:
	for member: Member in _extras.duplicate():
		if member.fortress_id == fortress_id:
			_extras.erase(member)
			_remove_member(member)


# Living reinforcements of [param fortress_id].
func _alive_extras_of(fortress_id: StringName) -> int:
	var total: int = 0
	for member: Member in _extras:
		if member.fortress_id == fortress_id and member.death_tick < 0:
			total += 1
	return total


# --- Reinforcements and warnings ----------------------------------------------------------------

# Creates [param count] NPCs of [param definition_id] around [param caller], already alerted with their target, minus
# the reinforcements of its fortress that are still alive (there are never more than [param count] at once: those of
# a previous Captain count). Returns how many it created.
func _spawn_reinforcements(caller: HfsmBrain, definition_id: StringName, count: int) -> int:
	var definition: NpcDefinition = _definition_of(definition_id)
	if definition == null:
		return 0
	var origin: Vector3 = caller.get_position()
	var fortress_id: StringName = _member_fortress(caller)
	var wanted: int = count - _alive_extras_of(fortress_id)
	var created: int = 0
	for index: int in maxi(wanted, 0):
		var angle: float = TAU * float(index) / float(maxi(count, 1)) + 0.5
		var position: Vector3 = origin + Vector3(cos(angle), 0.0, sin(angle)) * REINFORCEMENT_RADIUS
		var member: Member = _create_member(definition, caller.get_realm(), position, angle + PI,
				fortress_id, caller.get_group(), PackedVector3Array(),
				900001 + _reinforcements_total * 7919)
		if member == null:
			continue
		_extras.append(member)
		_reinforcements_total += 1
		created += 1
		member.brain.receive_alert(caller.get_target_id(), _world.tick)
	return created


func _definition_of(id: StringName) -> NpcDefinition:
	var override: NpcDefinition = _overrides.get(id)
	return override if override != null else NpcCatalog.get_definition(id)


func _member_fortress(brain: HfsmBrain) -> StringName:
	var member: Member = brain.owner_slot as Member
	return member.fortress_id if member != null else &""


# --- Navigation -------------------------------------------------------------------------------

func _setup_navigation(zone_id: String) -> void:
	var path: String = NetZones.navmesh_path(zone_id)
	if path.is_empty():
		return
	var navmesh: NavigationMesh = ResourceLoader.load(path) as NavigationMesh
	if navmesh == null:
		push_warning("[Eldmark] No se pudo cargar la malla de navegación %s" % path)
		return
	var navigation := NpcNavigation.new()
	if not navigation.setup(navmesh):
		return
	_navigation = navigation
	if _fortresses == null:
		return
	for fortress_id: StringName in _fortresses.get_fortress_ids():
		var gate: Node3D = _fortresses.get_gate(fortress_id)
		if gate != null:
			_navigation.add_gate_link_at(fortress_id, gate.global_transform)


# Sets the owner and breakage of each gate in navigation (only when they change).
func _sync_gates() -> void:
	if _navigation == null or _fortresses == null:
		return
	for fortress_id: StringName in _fortresses.get_fortress_ids():
		var state: FortressState = _fortresses.get_fortress_state(fortress_id)
		var applied := Vector2i(state.owner, 1 if state.is_gate_broken() else 0)
		if _gate_applied.get(fortress_id, Vector2i(-1, -1)) != applied:
			_gate_applied[fortress_id] = applied
			_navigation.set_gate_state(fortress_id, state.owner, state.is_gate_broken())


# --- Debugging ----------------------------------------------------------------------------------

## Registers the NPC commands in [param commands]: [code]npc_debug[/code] (fixed id 12).
func register_commands(commands: CommandRegistry) -> void:
	commands.register(&"npc_debug", "npc_debug [on|off]", _console_debug, _net_debug)


func _net_debug(ctx: CommandRegistry.Context) -> int:
	if ctx.payload.size() != 1 or ctx.payload[0] > 1:
		return CommandRegistry.Result.BAD_ARGUMENTS
	_debug_enabled = ctx.payload[0] == 1
	_debug_entity = ctx.peer.entity if ctx.peer != null and _debug_enabled else null
	ctx.note = "activado" if _debug_enabled else "apagado"
	return CommandRegistry.Result.OK


func _console_debug(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() > 1:
		return "Uso: npc_debug [on|off]"
	if ctx.args.is_empty():
		_debug_enabled = not _debug_enabled
	else:
		var text: String = ctx.args[0].to_lower()
		if text != "on" and text != "off":
			return "Uso: npc_debug [on|off]"
		_debug_enabled = text == "on"
	_debug_entity = null
	return "Depuración de PNJ %s" % ("activada" if _debug_enabled else "apagada")


## true if NPC debugging is on.
func is_debug_enabled() -> bool:
	return _debug_enabled


# One line per NPC with a combat brain (those near whoever requested it, or all) with its state, target and route.
func _write_debug() -> void:
	if not log_sink.is_valid():
		return
	var center: Vector3 = Vector3.ZERO
	var filtered: bool = _debug_entity != null and is_instance_valid(_debug_entity.node)
	if filtered:
		center = _debug_entity.get_position()
	for net_id: int in _server.get_npc_ids():
		var brain: HfsmBrain = _server.get_npc_brain(net_id) as HfsmBrain
		if brain == null or not brain.is_alive():
			continue
		if filtered and brain.get_position().distance_to(center) > DEBUG_RADIUS:
			continue
		log_sink.call("PNJ " + brain.describe())


static func _yaw_of(transform: Transform3D) -> float:
	var forward: Vector3 = -transform.basis.z
	return atan2(-forward.x, -forward.z)
