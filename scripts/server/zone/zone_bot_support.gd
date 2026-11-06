class_name ZoneBotSupport
extends RefCounted
## What the fake players (and the NPC brains that share their interface) see of the world: target, threat
## and ally caches, line of sight and the siege views (docs/fortress.md §7, docs/abilities.md §7.1).
## [br][br]
## [b]What lives here[/b]: the sources a [BotBrain] is given in [method ZoneServer.add_fake_player]
## ([method _find_enemy_target], [method _fake_combat_state], [method _fake_health_fraction],
## [method _find_downed_ally], [method _find_threats], [method _count_allies], [method _bot_line_of_sight]),
## the caches they read, rebuilt at most once per tick ([method _rebuild_target_cache],
## [method _rebuild_threats], [method _rebuild_ally_cache]) and the siege views of the fortresses with the
## approach routes of the zone ([method _refresh_siege_views], [method get_siege_view],
## [method get_approach_routes]).
## [br][br]
## [b]Tick step[/b]: the caches are filled lazily by the first brain that asks in a tick; the siege views are
## refreshed at the start of "simulate", once per tick, before any fake thinks.
## [br][br]
## [b]Touch this file[/b] to change how bots choose targets or what they know. The decisions themselves are in
## [BotBrain]; the rewards and the deaths are not here.
## [br][br]
## It is a plain [RefCounted] owned by the [ZoneServer], which builds it in [code]_init[/code] and passes
## itself in. The state it works on stays reachable through [code]_z[/code]; the state that only this
## subsystem uses lives here. It never runs a step of the tick on its own: [method ZoneServer._physics_process]
## calls it at the point the tick order (documented in its header) requires. Moving code between the
## subsystems is a mechanical change, but moving a call to a different step of the tick is not: the order is
## normative (docs/networking.md, section 3).


var _z: ZoneServer
# Cache of targets for the combat bots: tick of the last time, positions and ids per realm, and which
# realms are hostile to each other.
var _targets_tick: int = -1
var _targets_by_realm: Dictionary = {}
var _targets_ids_by_realm: Dictionary = {}
# Per realm, 1 if the target at the same index is an NPC (what the SIEGE fakes look for first).
var _targets_npc_by_realm: Dictionary = {}
# Fakes' kit (H5): the velocity of each target and whether it is knocked down, in the same order.
var _targets_velocity_by_realm: Dictionary = {}
var _targets_downed_by_realm: Dictionary = {}
var _hostile_cache: Dictionary = {}
# Siege of the fakes with the SIEGE brain (GUE-15): the view of each fortress, shared by all and updated
# every tick, and the approach routes of the zone (data/routes/<zone>.tres; null if there are none).
var _siege_views: Dictionary[StringName, SiegeView] = {}
var _siege_routes: ApproachRoutes = null
var _siege_routes_loaded: bool = false
# Telegraphed strikes (TELEGRAPH) that the SIEGE fakes avoid (F6b): tick of the list, the NPCs' strikes in
# progress and the realm of each striking NPC.
var _threats_tick: int = -1
var _threats: Array[BotBrain.Threat] = []
var _threat_realms: PackedInt32Array = PackedInt32Array()
# Living players per realm (positions and ids) with which the SIEGE fakes count their own at the rally
# point (GUE-44), and the tick of the list.
var _allies_tick: int = -1
var _allies_by_realm: Dictionary[int, PackedVector3Array] = {}
var _ally_ids_by_realm: Dictionary[int, PackedInt32Array] = {}


func _init(zone: ZoneServer) -> void:
	_z = zone


## The siege view of fortress [param fortress_id] (empty = the first of the zone) used by fake players with the
## [constant BotBrain.Pattern.SIEGE] brain: it is created the first time it is requested, carries the gate and
## circle positions and is updated every tick with the live state of the fortress
## ([method SiegeView.update_from_state]). null if the zone has no fortresses.
func get_siege_view(fortress_id: StringName = &"") -> SiegeView:
	if _z._fortresses == null or not _z._fortresses.has_fortresses():
		return null
	var id: StringName = fortress_id if not fortress_id.is_empty() else _z._fortresses.get_fortress_ids()[0]
	var state: FortressState = _z._fortresses.get_fortress_state(id)
	if state == null:
		return null
	var view: SiegeView = _siege_views.get(id)
	if view == null:
		view = SiegeView.new()
		view.fortress_id = id
		var gate: FortGate = _z._fortresses.get_gate(id)
		var circle: Dictionary = _z._fortresses.get_circle(id)
		view.set_places(gate.global_position if gate != null else circle["center"], circle["center"],
				circle["radius"])
		var routes: ApproachRoutes = get_approach_routes()
		if routes != null:
			view.enclosure_size = routes.enclosure_size
		view.update_from_state(state)
		_siege_views[id] = view
	return view


## The approach routes of the zone (data/routes/<zone>.tres), or null if it has none.
func get_approach_routes() -> ApproachRoutes:
	if not _siege_routes_loaded:
		_siege_routes_loaded = true
		var path: String = "res://data/routes/%s.tres" % _z._config.zone_id
		if ResourceLoader.exists(path):
			_siege_routes = load(path) as ApproachRoutes
	return _siege_routes


# Updates the siege views with the live state of the fortresses (the one after the previous tick, like the NPC
# brains): what the fakes with a SIEGE brain see when deciding their input for tick s.
func _refresh_siege_views() -> void:
	for fortress_id: StringName in _siege_views:
		var state: FortressState = _z._fortresses.get_fortress_state(fortress_id)
		if state != null:
			_siege_views[fortress_id].update_from_state(state)


# The nearest living (or knocked-down) enemy to [param position] for fake player [param net_id] (the combat brain
# of BotBrain): a BotTarget with its feet, its velocity and whether it is knocked down (what the kit uses for the
# bow's lead shot and for finishing off, H5), or null if there is none that can attack or be attacked: dummies,
# protected ones and those in their realm's safe zone do not count, and whoever is in their realm's safe zone (or
# is not standing) does not attack. Targets are gathered once per tick and per realm (with many bots, each one
# only traverses the candidates of the realms hostile to it). With [param npcs_only], only NPCs (the defender finder
# of the SIEGE brain, F6b). "Nearest" with height weighted (BotBrain.target_distance_squared, GUE-45): the one on
# its own level before the one on the walkway.
func _find_enemy_target(position: Vector3, net_id: int, npcs_only: bool = false) -> Variant:
	var me: Combatant = _z._combat.get_combatant(net_id)
	if me == null or not me.is_alive() or _z._safe_areas.contains_own(me.get_realm(), position):
		return null
	if _targets_tick != _z._tick:
		_rebuild_target_cache()
	var best_realm: int = -1
	var best_index: int = -1
	var best_distance: float = INF
	for realm: int in _targets_by_realm:
		if not _is_hostile_realm(me.get_realm(), realm):
			continue
		var positions: PackedVector3Array = _targets_by_realm[realm]
		var npc_flags: PackedByteArray = _targets_npc_by_realm[realm]
		for index: int in positions.size():
			if _targets_ids_by_realm[realm][index] == net_id or (npcs_only and npc_flags[index] == 0):
				continue
			var distance: float = BotBrain.target_distance_squared(position, positions[index])
			if distance < best_distance:
				best_distance = distance
				best_realm = realm
				best_index = index
	if best_index < 0:
		return null
	return BotTarget.new(_targets_by_realm[best_realm][best_index],
			_targets_velocity_by_realm[best_realm][best_index],
			_targets_downed_by_realm[best_realm][best_index] != 0,
			_targets_ids_by_realm[best_realm][best_index])


# The fakes' kit (H5): the combat state of fake player [param net_id] after the last tick (null if it is no longer
# there).
func _fake_combat_state(net_id: int) -> CombatState:
	var entity: NetEntity = _z._registry.get_entity(net_id)
	var character: PlayerCharacter = entity.get_character() if entity != null else null
	return character.combat if character != null else null


# The siege fakes' kit: the bow's line of fire (BotBrain.set_line_of_sight) in the server world.
func _bot_line_of_sight(from_feet: Vector3, to_feet: Vector3, left_shoulder: bool) -> bool:
	return BotBrain.bow_sight_clear(_z.get_physics_space(), from_feet, to_feet, left_shoulder)


# The fakes' kit: the health fraction of fake player [param net_id] (0 knocked down or dead).
func _fake_health_fraction(net_id: int) -> float:
	var combatant: Combatant = _z._combat.get_combatant(net_id)
	if combatant == null or combatant.max_health <= 0:
		return 1.0
	return float(combatant.health) / float(combatant.max_health)


# The fakes' kit: the feet of the knocked-down ally (a player of their realm) nearest to [param position] for fake
# player [param net_id], or null. With nobody knocked down in the zone it traverses no one.
func _find_downed_ally(position: Vector3, net_id: int) -> Variant:
	if _z._combat.downed.downed_count() == 0:
		return null
	var me: Combatant = _z._combat.get_combatant(net_id)
	if me == null or not me.is_alive():
		return null
	var best: Variant = null
	var best_distance: float = INF
	for other: Combatant in _z._combat.get_sorted():
		if other == me or not other.is_downed() or other.get_realm() != me.get_realm() \
				or not _z._is_player(other.get_id()):
			continue
		var feet: Vector3 = other.entity.get_position()
		var distance: float = position.distance_squared_to(feet)
		if distance < best_distance:
			best_distance = distance
			best = feet
	return best


# The telegraphed strikes (TELEGRAPH) in progress that can damage fake player [param net_id] (the SIEGE brain, F6b):
# the heavy attacks of NPCs of a hostile realm from when they start until their active window ends, with the NPC's
# position and heading at this moment (it turns and advances a little while charging) and the reach of the hit. The
# list is gathered once per tick.
func _find_threats(_position: Vector3, net_id: int) -> Array[BotBrain.Threat]:
	var found: Array[BotBrain.Threat] = []
	var me: Combatant = _z._combat.get_combatant(net_id)
	if me == null or me.is_dead():
		return found
	if _threats_tick != _z._tick:
		_rebuild_threats()
	for index: int in _threats.size():
		if _is_hostile_realm(_threat_realms[index], me.get_realm()):
			found.append(_threats[index])
	return found


# How many living players of the realm of fake player [param net_id], not counting itself, are within [param radius]
# meters horizontally of [param center] (the SIEGE brain's ally counter for the rally, GUE-44). People and fakes
# count, not NPCs nor the bodies of those who left in combat. Positions are gathered once per tick, so everyone waiting
# on the same tick sees the same count and leaves at once.
func _count_allies(center: Vector3, radius: float, net_id: int) -> int:
	var me: Combatant = _z._combat.get_combatant(net_id)
	if me == null:
		return 0
	if _allies_tick != _z._tick:
		_rebuild_ally_cache()
	var realm: int = me.get_realm()
	if not _allies_by_realm.has(realm):
		return 0
	var positions: PackedVector3Array = _allies_by_realm[realm]
	var ids: PackedInt32Array = _ally_ids_by_realm[realm]
	var limit: float = radius * radius
	var count: int = 0
	for index: int in positions.size():
		if ids[index] == net_id:
			continue
		var dx: float = positions[index].x - center.x
		var dz: float = positions[index].z - center.z
		if dx * dx + dz * dz <= limit:
			count += 1
	return count


# Gathers, per realm, the positions of living players (people and fakes) on this tick. A knocked-down one (H3c) is not
# alive: it does not count in the rally nor as one of their own fighting at the fort. The same as the client bots
# (BotAllySight for --bot, SwarmBot.is_standing_record for --bots), which see it through its drawn action, DOWNED: its
# published health is not 0 (Combatant.publish gives it as that of the knocked-down).
func _rebuild_ally_cache() -> void:
	_allies_tick = _z._tick
	_allies_by_realm.clear()
	_ally_ids_by_realm.clear()
	for other: Combatant in _z._combat.get_sorted():
		if not other.is_alive() or other.entity.kind != NetProtocol.EntityKind.PLAYER or _z._lingering.has(other.get_id()) \
				or other.is_gm_invisible():
			continue
		var realm: int = other.get_realm()
		if not _allies_by_realm.has(realm):
			_allies_by_realm[realm] = PackedVector3Array()
			_ally_ids_by_realm[realm] = PackedInt32Array()
		_allies_by_realm[realm].append(other.entity.get_position())
		_ally_ids_by_realm[realm].append(other.get_id())


# Gathers the telegraphed heavy attacks of NPCs that are still in progress after the last tick (those announced by
# _emit_npc_telegraphs).
func _rebuild_threats() -> void:
	_threats_tick = _z._tick
	_threats.clear()
	_threat_realms.clear()
	for net_id: int in _z._npcs:
		var entity: NetEntity = _z._registry.get_entity(net_id)
		var character: PlayerCharacter = entity.get_character() if entity != null else null
		if character == null:
			continue
		var state: CombatState = character.combat
		if state.action != CombatState.Action.HEAVY:
			continue
		var attack: AttackTicks = CombatCatalog.attack(state.action_id)
		if attack == null or attack.shape == null \
				or _z._tick - state.action_tick > attack.windup_ticks + attack.active_ticks:
			continue
		_threats.append(BotBrain.Threat.new(entity.get_position(), character.yaw, attack.shape.range_m))
		_threat_realms.append(entity.realm)


# Gathers, per realm, the positions of whoever can be a combat bot's target on this tick.
func _rebuild_target_cache() -> void:
	_targets_tick = _z._tick
	_targets_by_realm.clear()
	_targets_ids_by_realm.clear()
	_targets_npc_by_realm.clear()
	_targets_velocity_by_realm.clear()
	_targets_downed_by_realm.clear()
	for other: Combatant in _z._combat.get_sorted():
		if other.is_dead() or other.immortal or other.is_protected(_z._tick) or other.is_gm_invisible():
			continue
		var other_position: Vector3 = other.entity.get_position()
		if _z._safe_areas.contains_own(other.get_realm(), other_position):
			continue
		var realm: int = other.get_realm()
		if not _targets_by_realm.has(realm):
			_targets_by_realm[realm] = PackedVector3Array()
			_targets_ids_by_realm[realm] = PackedInt32Array()
			_targets_npc_by_realm[realm] = PackedByteArray()
			_targets_velocity_by_realm[realm] = PackedVector3Array()
			_targets_downed_by_realm[realm] = PackedByteArray()
		var character: PlayerCharacter = other.entity.get_character()
		_targets_by_realm[realm].append(other_position)
		_targets_ids_by_realm[realm].append(other.get_id())
		_targets_npc_by_realm[realm].append(1 if _z._npcs.has(other.get_id()) else 0)
		_targets_velocity_by_realm[realm].append(character.velocity if character != null else Vector3.ZERO)
		_targets_downed_by_realm[realm].append(1 if other.is_downed() else 0)


# true if a bot of [param my_realm] can damage one of [param other_realm] in this zone.
func _is_hostile_realm(my_realm: int, other_realm: int) -> bool:
	var key: int = my_realm * 16 + other_realm
	if not _hostile_cache.has(key):
		_hostile_cache[key] = FactionRules.can_damage(my_realm, other_realm,
				StringName(_z._config.zone_id))
	return _hostile_cache[key]
