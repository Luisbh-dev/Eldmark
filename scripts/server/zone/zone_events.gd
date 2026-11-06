class_name ZoneEvents
extends RefCounted
## What the zone does with the events of the combat and the war once they are resolved: the ENTITY_EVENT,
## ENTITY_SPAWN and ENTITY_DESPAWN messages of hits and projectiles, the rewards of a death, the level-up
## notice, the war notices and the scoreboard (docs/combat.md §6, docs/abilities.md §4.4, docs/progression.md
## §6.2, docs/fortress.md).
## [br][br]
## [b]What lives here[/b]: [method _on_combat_event], [method _on_projectile_spawned],
## [method _on_projectile_despawned] (who receives each message), [method _track_battle] (the battle log),
## [method _reward_kill], [method _reward_npc_death], [method _announce_level_up], [method _on_war_event],
## [method _on_object_state], [method _on_gate_damage_started] and [method _send_scoreboard].
## [br][br]
## [b]Tick steps[/b]: these are signal handlers of the [CombatDirector] and the [FortressController]; they run
## inside the "combat" and "forts" steps, never on their own. The scoreboard goes out in the snapshots step.
## [br][br]
## [b]Touch this file[/b] to change who is told about an event or what a death pays out.
## [br][br]
## It is a plain [RefCounted] owned by the [ZoneServer], which builds it in [code]_init[/code] and passes
## itself in. The state it works on stays reachable through [code]_z[/code]; the state that only this
## subsystem uses lives here. It never runs a step of the tick on its own: [method ZoneServer._physics_process]
## calls it at the point the tick order (documented in its header) requires. Moving code between the
## subsystems is a mechanical change, but moving a call to a different step of the tick is not: the order is
## normative (docs/networking.md, section 3).


## [ServerMetrics] section for sending the ENTITY_EVENT messages (inside the combat one).
const SECTION_COMBAT_EVENTS: StringName = &"combat_events"

var _z: ZoneServer


func _init(zone: ZoneServer) -> void:
	_z = zone


# A combat event: ENTITY_EVENT (reliable channel) to the owners of the entities involved
# (victim, attacker, killer and assistants) and to whoever has any of them as relevant. KILL and
# DOWNED go to the whole zone (everyone sees the kill feed, docs/fortress.md section 6, and
# docs/abilities.md, section 5.4). STATUS, HEAL and INTERACT go to the owners of those involved and to whoever
# has the affected one as relevant (not the author). LOADOUT ([signal CombatDirector.event_emitted]): the owner's
# ([param involved] with the player) only to them; the public one ([param involved] empty, charges 0) to whoever has
# the player as relevant, without the owner. Before sending it, it is recorded on the scoreboard and in the battle log.
func _on_combat_event(event: NetMessages.EntityEvent, involved: PackedInt32Array) -> void:
	_track_battle(event)
	if _z._transport == null or _z._world_peers.is_empty():
		return
	_z._metrics.begin_section(SECTION_COMBAT_EVENTS)
	var bytes: PackedByteArray = event.encode()
	var kind: int = event.event
	var to_everyone: bool = kind == NetMessages.EntityEvent.Kind.KILL \
			or kind == NetMessages.EntityEvent.Kind.DOWNED
	var seen_by: PackedInt32Array = involved
	if kind == NetMessages.EntityEvent.Kind.STATUS or kind == NetMessages.EntityEvent.Kind.HEAL \
			or kind == NetMessages.EntityEvent.Kind.INTERACT:
		seen_by = PackedInt32Array([event.net_id])
	elif kind == NetMessages.EntityEvent.Kind.LOADOUT:
		# The owner's is seen by nobody else; the public one, by whoever has them as relevant.
		seen_by = PackedInt32Array() if not involved.is_empty() else PackedInt32Array([event.net_id])
	for peer: ServerPeer in _z._world_peers:
		if kind == NetMessages.EntityEvent.Kind.LOADOUT and involved.is_empty() \
				and peer.entity.net_id == event.net_id:
			continue
		var receives: bool = to_everyone or involved.has(peer.entity.net_id)
		if not receives:
			for net_id: int in seen_by:
				if peer.relevant.get(net_id, false):
					receives = true
					break
		if receives:
			_z._transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
			_z._events_sent += 1
			_z._event_bytes_sent += bytes.size()
	_z._metrics.end_section(SECTION_COMBAT_EVENTS)


# Spawn of a projectile (docs/abilities.md, section 4.4): ENTITY_SPAWN of kind 3 (reliable channel) to the
# shooter's owner and to whoever has them as relevant, at that moment. It records who received it to send them the removal.
func _on_projectile_spawned(spawn: NetMessages.EntitySpawn, involved: PackedInt32Array) -> void:
	if _z._transport == null or _z._world_peers.is_empty():
		return
	_z._metrics.begin_section(SECTION_COMBAT_EVENTS)
	var bytes: PackedByteArray = spawn.encode()
	var viewers := PackedInt32Array()
	for peer: ServerPeer in _z._world_peers:
		var receives: bool = involved.has(peer.entity.net_id)
		if not receives:
			for net_id: int in involved:
				if peer.relevant.get(net_id, false):
					receives = true
					break
		if receives:
			_z._transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
			viewers.append(peer.peer_id)
			_z._projectile_messages_sent += 1
			_z._projectile_bytes_sent += bytes.size()
	if not viewers.is_empty():
		_z._projectile_viewers[spawn.net_id] = viewers
	_z._metrics.end_section(SECTION_COMBAT_EVENTS)


# Removal of a projectile: ENTITY_DESPAWN (reason 4 impact or 5 expired) to those who received its spawn and are still
# in the world, even if they no longer have the shooter as relevant.
func _on_projectile_despawned(projectile_id: int, tick: int, reason: int,
		_involved: PackedInt32Array) -> void:
	var viewers: PackedInt32Array = _z._projectile_viewers.get(projectile_id, PackedInt32Array())
	_z._projectile_viewers.erase(projectile_id)
	if _z._transport == null or viewers.is_empty():
		return
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = projectile_id
	despawn.despawn_tick = tick
	despawn.reason = reason
	var bytes: PackedByteArray = despawn.encode()
	for peer_id: int in viewers:
		var peer: ServerPeer = _z._peers.get(peer_id)
		if peer == null or peer.state != ServerPeer.State.IN_WORLD:
			continue
		_z._transport.send(peer_id, NetProtocol.CH_RELIABLE, bytes)
		_z._projectile_messages_sent += 1
		_z._projectile_bytes_sent += bytes.size()


# Scoreboard and battle log: a death adds a death to the victim (if a player) and goes into the
# log; a KILL adds a kill to the killer and an assist to each assistant (if players). Respawning
# clears the GM command flag (gm_forced, docs/progression.md §6.2). Rewards (progression.md §6.2): an NPC's
# death pays its contributors and a player's KILL, the PvP merits.
func _track_battle(event: NetMessages.EntityEvent) -> void:
	match event.event:
		NetMessages.EntityEvent.Kind.RESPAWN:
			var respawned: NetEntity = _z._registry.get_entity(event.net_id)
			if respawned != null:
				respawned.gm_forced = false
		NetMessages.EntityEvent.Kind.DEATH:
			var victim: NetEntity = _z._registry.get_entity(event.net_id)
			if victim == null:
				return
			if victim.kind == NetProtocol.EntityKind.PLAYER:
				_z._scores.add_death(victim.net_id)
			elif victim.kind == NetProtocol.EntityKind.NPC:
				_reward_npc_death(victim, event.tick)
			if _z._battle_log != null:
				_z._battle_log.log_death(event.tick, victim,
						_z._registry.get_entity(event.killer) if event.killer != 0 else null,
						event.attack_id, victim.get_position())
		NetMessages.EntityEvent.Kind.KILL:
			if _z._is_player(event.killer):
				_z._scores.add_kill(event.killer)
			for assistant: int in event.assistants:
				if _z._is_player(assistant):
					_z._scores.add_assist(assistant)
			_reward_kill(event)


# The PvP merits of a KILL (progression.md §6.2; the scoreboard's provisional ones until PRG-09): those of the kill
# to the killer and those of the assist to each assistant. ProgressService only pays them with a persistent victim of
# another realm.
func _reward_kill(event: NetMessages.EntityEvent) -> void:
	if _z._progress == null or not _z._is_player(event.net_id):
		return
	_z._progress.on_merits(event.killer, ScoreKeeper.MERITS_PER_KILL, EconomyReason.PVP_KILL, event.net_id, event.tick)
	for assistant: int in event.assistants:
		_z._progress.on_merits(assistant, ScoreKeeper.MERITS_PER_ASSIST, EconomyReason.PVP_ASSIST, event.net_id,
				event.tick)


# The reward of an NPC that dies at tick [param s] (progression.md §6.2) to those who did at least 10 % of the
# damage in the window. It is checked on its DEATH, which arrives here before FortressController: the defender is
# still registered and the forced-change flag is that of its death (fort_kill_captain sets it before killing). A
# defender of a fortress in a forced cycle pays nothing.
func _reward_npc_death(victim: NetEntity, s: int) -> void:
	if _z._progress == null:
		return
	var definition: NpcDefinition = _npc_definition_of(victim)
	if definition == null or (definition.xp_reward <= 0 and definition.gold_reward <= 0):
		return
	var fortress_id: StringName = _z._fortresses.fortress_of_defender(victim.net_id) if _z._fortresses != null else &""
	if not fortress_id.is_empty() and _z._fortresses.is_forced(fortress_id):
		return
	var combatant: Combatant = _z._combat.get_combatant(victim.net_id)
	if combatant != null:
		_z._progress.on_npc_killed(definition, combatant.ledger.contributors(s), s)


# The definition of NPC [param entity] (that of the spawner system, which may override the catalog's in tests), or
# null if it has none.
func _npc_definition_of(entity: NetEntity) -> NpcDefinition:
	var definition: NpcDefinition = NpcCatalog.get_by_number(entity.npc_def_id) if entity.npc_def_id > 0 else null
	if definition != null and _z._npc_system != null:
		definition = _z._npc_system.get_definition(definition.id)
	return definition


# ENTITY_EVENT LEVEL_UP of [param net_id], who goes up to [param level] at tick [param s] (progression.md §6.3): to the
# owner and to those of their realm who have them as relevant, for the effect; it does not reach the enemy.
func _announce_level_up(net_id: int, level: int, s: int) -> void:
	var entity: NetEntity = _z._registry.get_entity(net_id)
	if entity == null or _z._transport == null or _z._world_peers.is_empty():
		return
	var bytes: PackedByteArray = NetMessages.EntityEvent.level_up(net_id, s, level).encode()
	for peer: ServerPeer in _z._world_peers:
		if peer.entity == entity or (peer.entity.realm == entity.realm and peer.relevant.get(net_id, false)):
			_z._transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
			_z._events_sent += 1
			_z._event_bytes_sent += bytes.size()


# A war notice to the whole zone (ENTITY_EVENT WAR) and to the battle log.
func _on_war_event(event: NetMessages.EntityEvent) -> void:
	if _z._battle_log != null:
		var fortress_id: StringName = _z._fortresses.get_fortress_id_of(event.net_id)
		_z._battle_log.log_war(event.tick, event.war_event, event.war_realm, fortress_id,
				_z._fortresses.get_circle(fortress_id)["center"])
	if _z._transport == null or _z._world_peers.is_empty():
		return
	var bytes: PackedByteArray = event.encode()
	for peer: ServerPeer in _z._world_peers:
		_z._transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
		_z._events_sent += 1
		_z._event_bytes_sent += bytes.size()


# The OBJECT_STATE of a fortress to the whole zone (reliable channel).
func _on_object_state(object_state: NetMessages.ObjectState) -> void:
	_z._object_states_sent += 1
	if _z._transport == null or _z._world_peers.is_empty():
		return
	var bytes: PackedByteArray = object_state.encode()
	if bytes.is_empty():
		return
	for peer: ServerPeer in _z._world_peers:
		_z._transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)


func _on_gate_damage_started(fortress_id: StringName, tick: int) -> void:
	if _z._battle_log == null:
		return
	var gate: FortGate = _z._fortresses.get_gate(fortress_id)
	_z._battle_log.log_gate_damage_started(tick, fortress_id,
			gate.global_position if gate != null else Vector3.ZERO)


# The zone scoreboard to all players (pages of at most 66 rows).
func _send_scoreboard() -> void:
	if _z._transport == null or _z._world_peers.is_empty():
		return
	var ids: Array[int] = []
	for entity: NetEntity in _z._registry.get_sorted():
		# An invisible GM does not appear on the scoreboard (docs/platform.md §9.1).
		if entity.kind == NetProtocol.EntityKind.PLAYER and not entity.gm_invisible:
			ids.append(entity.net_id)
	var rows: Array[NetMessages.ScoreRow] = _z._scores.build_rows(ids)
	for page: NetMessages.Scoreboard in NetMessages.Scoreboard.split(rows):
		var bytes: PackedByteArray = page.encode()
		for peer: ServerPeer in _z._world_peers:
			_z._transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
	_z._scoreboards_sent += 1
