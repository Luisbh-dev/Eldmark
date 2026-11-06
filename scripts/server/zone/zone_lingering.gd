class_name ZoneLingering
extends RefCounted
## Bodies that stay in the world after their owner leaves in combat (GUE-41), and the /atascado (unstuck)
## command that moves a stuck player to a safe point (docs/combat.md, docs/fortress.md).
## [br][br]
## [b]What lives here[/b]: the decision to linger ([method _should_linger]), the linger itself
## ([method _start_lingering], [method _process_lingering]) and the unstuck channel ([method _request_unstuck],
## [method _process_unstuck], [method _teleport_unstuck], [method _nearest_safe_point]), with the
## [UnstuckTracker] accessors.
## [br][br]
## [b]Tick steps[/b]: [method _should_linger] and [method _start_lingering] are called by the removals step
## ([ZoneBodies]), [method _process_lingering] runs at the end of that same step and [method _process_unstuck]
## in the forts step, before the NPCs; all of them use the tick [code]s[/code] being simulated.
## [br][br]
## [b]Touch this file[/b] to change who lingers, for how long or how /atascado is interrupted.
## [br][br]
## It is a plain [RefCounted] owned by the [ZoneServer], which builds it in [code]_init[/code] and passes
## itself in. The state it works on stays reachable through [code]_z[/code]; the state that only this
## subsystem uses lives here. It never runs a step of the tick on its own: [method ZoneServer._physics_process]
## calls it at the point the tick order (documented in its header) requires. Moving code between the
## subsystems is a mechanical change, but moving a call to a different step of the tick is not: the order is
## normative (docs/networking.md, section 3).


## Uses of /atascado (unstuck) kept by the report (the most recent ones).
const MAX_LOGGED_UNSTUCK: int = 200

var _z: ZoneServer
# Name key -> net_id of whoever is channeling /atascado (unstuck).
var _unstuck_players: Dictionary[String, int] = {}


func _init(zone: ZoneServer) -> void:
	_z = zone


func get_unstuck() -> UnstuckTracker:
	return _z._unstuck


## The key of [param entity] in the [UnstuckTracker]: with the platform, [code]"character:<id>"[/code] (that of
## the saved [code]unstuck[/code] timer, docs/progression.md §8); without it, that of its name (rejoining with the
## same name does not skip the reuse cooldown).
func unstuck_key_of(entity: NetEntity) -> String:
	var character_id: int = _z._progress.character_id_of(entity.net_id) if _z._progress != null else 0
	if character_id > 0:
		return "character:%d" % character_id
	return NameRules.normalize_key(entity.display_name)


## Bodies that remain in the world after the removal of a player in combat (GUE-41).
func get_lingering_count() -> int:
	return _z._lingering.size()


## true if [param net_id] is the body of a player who left in combat and is waiting to be removed.
func is_lingering(net_id: int) -> bool:
	return _z._lingering.has(net_id)


# true if whoever leaves has dealt or received damage less than 10 s ago and is still alive: their body stays.
func _should_linger(entity: NetEntity, s: int) -> bool:
	if entity.kind != NetProtocol.EntityKind.PLAYER or _z._run_state != ZoneServer._RunState.RUNNING:
		return false
	var combatant: Combatant = _z._combat.get_combatant(entity.net_id)
	return combatant != null and combatant.is_alive() and combatant.is_in_combat(s)


# The body stays LINGER_TICKS ticks in the world with neutral inputs (still, no buttons), attackable, not
# counting in the circle and with its name reserved. It stops belonging to any peer.
func _start_lingering(entity: NetEntity, s: int) -> void:
	var net_id: int = entity.net_id
	var record: ZoneServer._PlayerRecord = _z._player_by_net.get(net_id)
	if record != null:
		record.close(s)
		_z._player_by_net.erase(net_id)
	var combatant: Combatant = _z._combat.get_combatant(net_id)
	if combatant != null:
		combatant.peer = null
	entity.owner_peer = 0
	_z._unstuck.cancel(unstuck_key_of(entity))
	_z._lingering[net_id] = s + _z.linger_ticks
	_z._lingering_total += 1


# Removes the bodies whose deadline has expired or that have been killed (their death was already credited like any
# other).
func _process_lingering(s: int) -> void:
	if _z._lingering.is_empty():
		return
	for net_id: int in _z._lingering.keys():
		var entity: NetEntity = _z._registry.get_entity(net_id)
		if entity == null:
			_z._lingering.erase(net_id)
			continue
		var combatant: Combatant = _z._combat.get_combatant(net_id)
		if s >= _z._lingering[net_id] or combatant == null or combatant.is_dead():
			_z._log("Se retira el cuerpo de %s (net_id %d)" % [entity.display_name, net_id])
			# Now its final save goes out (docs/platform.md §7.2: "when the body leaves").
			_z._zone_bodies._remove_player(entity, s, NetProtocol.DespawnReason.DISCONNECTED, true,
					_z._lingering_save_reasons.get(net_id, CharacterSaver.Reason.LOGOUT))


# UNSTUCK_REQUEST or command 7: starts the channeling if applicable and tells the player how it went.
func _request_unstuck(peer: ServerPeer) -> int:
	var entity: NetEntity = peer.entity
	var combatant: Combatant = _z._combat.get_combatant(entity.net_id) if entity != null else null
	if combatant == null:
		return UnstuckTracker.RequestResult.DEAD
	var s: int = _z._tick + 1
	var key: String = unstuck_key_of(entity)
	var result: int = _z._unstuck.request(key, s, combatant.is_alive(), combatant.is_in_combat(s))
	var text: String = "/atascado: te llevaré al punto más cercano de tu reino en %.0f s si no " \
			% (float(_z._unstuck.channel_ticks) / float(Engine.physics_ticks_per_second)) \
			+ "entras en combate"
	match result:
		UnstuckTracker.RequestResult.STARTED:
			_unstuck_players[key] = entity.net_id
		UnstuckTracker.RequestResult.IN_COMBAT:
			text = "/atascado: no se puede usar en combate"
		UnstuckTracker.RequestResult.COOLDOWN:
			text = "/atascado: disponible de nuevo en %d s" % ceili(
					float(_z._unstuck.cooldown_remaining(key, s)) / 60.0)
		UnstuckTracker.RequestResult.ALREADY_CHANNELING:
			text = "/atascado: ya lo estás usando"
		UnstuckTracker.RequestResult.DEAD:
			text = "/atascado: no se puede usar estando muerto"
	_z._send_notice(peer, text)
	return result


# Advances the /atascado channelings: combat or death interrupts them and at the end the player is teleported.
func _process_unstuck(s: int) -> void:
	for key: String in _z._unstuck.get_channeling():
		var entity: NetEntity = _z._registry.get_entity(_unstuck_players.get(key, 0))
		var combatant: Combatant = _z._combat.get_combatant(entity.net_id) if entity != null else null
		if combatant == null:
			_z._unstuck.cancel(key)
			_unstuck_players.erase(key)
			continue
		var outcome: int = _z._unstuck.update(key, s, combatant.is_alive(), combatant.is_in_combat(s))
		if outcome == UnstuckTracker.UpdateResult.CHANNELING:
			continue
		_unstuck_players.erase(key)
		var peer: ServerPeer = _z._peers.get(entity.owner_peer)
		if outcome == UnstuckTracker.UpdateResult.INTERRUPTED:
			if peer != null:
				_z._send_notice(peer, "/atascado: interrumpido")
		else:
			_teleport_unstuck(entity, s)
			# With the platform, the reuse cooldown is saved as the unstuck timer (progression.md §8).
			_z._progress.set_timer(entity.net_id, ProgressService.TIMER_UNSTUCK, _z._unstuck.get_ready_at(key), s)
			if peer != null:
				_z._send_notice(peer, "/atascado: ya estás en un punto seguro de tu reino")


# Teleports [param entity] to the nearest valid respawn point of its realm (or, if there is none,
# to a spawn point) and records the use (zone, origin and destination position) to fix the map.
func _teleport_unstuck(entity: NetEntity, s: int) -> void:
	var from: Vector3 = entity.get_position()
	var destination: Transform3D = _nearest_safe_point(entity, s)
	_z._place(entity, destination.origin, CombatDirector._yaw_of(destination))
	_z._unstuck_uses += 1
	_z._unstuck_log.append({
		"tick": s, "net_id": entity.net_id, "name": entity.display_name, "zone": _z._config.zone_id,
		"from": [from.x, from.y, from.z],
		"to": [destination.origin.x, destination.origin.y, destination.origin.z],
	})
	while _z._unstuck_log.size() > MAX_LOGGED_UNSTUCK:
		_z._unstuck_log.pop_front()
	_z._log("/atascado: %s (net_id %d, zona %s) pasa de %s a %s" % [entity.display_name,
			entity.net_id, _z._config.zone_id, from, destination.origin])


# The respawn point that is valid for the realm of [param entity] nearest to it.
func _nearest_safe_point(entity: NetEntity, s: int) -> Transform3D:
	var points: Array[Node3D] = _z._combat.get_all_respawn_points()
	var position: Vector3 = entity.get_position()
	var best: Node3D = null
	var best_distance: float = INF
	for index: int in _z._combat.get_valid_respawn_points(entity.realm, s):
		var distance: float = points[index].global_position.distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best = points[index]
	if best == null:
		return _z._spawn_picker.pick(entity.realm)
	return best.global_transform
