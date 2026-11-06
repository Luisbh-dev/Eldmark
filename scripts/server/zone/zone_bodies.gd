class_name ZoneBodies
extends RefCounted
## Who is in the world: how a body (player, fake player, NPC, dummy) is created, announced and removed.
## [br][br]
## [b]What lives here[/b]: the public API that adds and removes fakes and NPCs ([method add_fake_player],
## [method remove_fake_player], [method retire_filler], [method add_npc], [method remove_npc],
## [method spawn_dummy], [method spawn_zone_dummies], [method spawn_captain_double]), the spawns step
## ([method _process_arrivals], [method _create_player], [method _create_body], [method _announce_arrival],
## [method _pick_spawn_point]), the removals step ([method _process_departures], [method _process_fake_departures],
## [method _remove_player]) and the cleanup at shutdown ([method _clear_players]).
## [br][br]
## [b]Tick steps[/b]: removals go before "simulate" and spawns after it, so the first simulation of a new
## player is that of tick [code]s + 1[/code] with no one-tick offset. Do not move a call between those two
## steps: it shifts every player by a tick and changes the state log.
## [br][br]
## [b]Touch this file[/b] to change what a new body starts with or what happens to it on leaving (the saves and
## the order [code]finish[/code] → [code]ScoreKeeper.forget[/code] → [code]on_departure[/code] are in
## [method _remove_player]).
## [br][br]
## [b]Fake players[/b] ([method add_fake_player]): network-less players whose inputs come from a
## [BotBrain] and go straight into their [InputQueue]; they serve for tests and load. With a
## [FillerKeeper] ([method set_filler_keeper], [code]--max-realm-diff[/code]) the filler bots follow the
## joins and leaves of people and do not take their slots: a HELLO that arrives with the server full only
## because of them gets in, one displaces one of theirs and it leaves when that person enters the world
## (GUE-43; docs/fortress.md, section 7). Combat and siege bots see their enemies (and the siege ones, the
## NPCs defending the fort) with their velocity and knockdown ([BotTarget]) and, since H5, fight with the
## phase 4 kit (docs/abilities.md, section 7.1): they read their combat state and health from the
## server and the combat ones revive knocked-down allies (the siege ones follow their plan). The siege
## ones also avoid the telegraphed strikes of NPCs and count their own in the rally (F6b).
## [br][br]
## It is a plain [RefCounted] owned by the [ZoneServer], which builds it in [code]_init[/code] and passes
## itself in. The state it works on stays reachable through [code]_z[/code]; the state that only this
## subsystem uses lives here. It never runs a step of the tick on its own: [method ZoneServer._physics_process]
## calls it at the point the tick order (documented in its header) requires. Moving code between the
## subsystems is a mechanical change, but moving a call to a different step of the tick is not: the order is
## normative (docs/networking.md, section 3).


## Character scene. On the server its [code]Visual[/code] node is freed.
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
## Name of the fake players ([method add_fake_player]) with their number: "Bot-01". The hyphen and the
## digits deliberately leave it outside [NameRules]: the client does not offer social actions to a name that
## does not satisfy them ([code]SocialTarget.is_social_target[/code]), because a fake has no connection and
## the server would answer "not connected" to the invitation or the whisper (docs/social.md, section 12.6).
const FAKE_NAME_FORMAT: String = "Bot-%02d"
## Length (m) of the ray used to find the ground under a dummy point.
const _GROUND_PROBE_UP: float = 4.0
const _GROUND_PROBE_DOWN: float = 12.0
## Length of the probe that decides whether a spawn point is on the ground.
const _PROBE_UP: float = 0.1
const _PROBE_DOWN: float = 0.3

var _z: ZoneServer
var _fake_counter: int = 0


func _init(zone: ZoneServer) -> void:
	_z = zone


## Creates a network-less player of [param realm] (a code of [enum NetProtocol.Realm]): on each tick, before
## simulating, its input comes from [code]brain.next_input()[/code], quantized and with the corresponding tick,
## and goes straight into its [InputQueue]. It appears with the equipment template [param template_id] (0 = the
## default one; [code]--fake-loadout[/code]) and keeps it when respawning. On death it requests the respawn as
## soon as it can ([member Combatant.requests_respawn_on_death]), like a person pressing the button or a
## [code]SwarmBot[/code]: with waves, it respawns in the first one that applies to it. Returns its
## [code]net_id[/code], or -1 if the server is not running, is full ([member ServerConfig.max_players]) or no
## ids are left. It can be called between two ticks; the player appears with the state "after the last tick" and
## its first simulation is the next one.
func add_fake_player(brain: BotBrain, realm: int, template_id: int = 0) -> int:
	if _z._run_state != ZoneServer._RunState.RUNNING or brain == null:
		return -1
	if _z._zone_sessions._occupied_seats() >= _z._config.max_players:
		return -1
	_fake_counter += 1
	var entity: NetEntity = _create_player(FAKE_NAME_FORMAT % _fake_counter, realm, 0, _z._tick)
	if entity == null:
		return -1
	var combatant: Combatant = _z._combat.get_combatant(entity.net_id)
	_z._combat.equip_template(combatant, template_id)
	combatant.requests_respawn_on_death = true
	_z._fakes[entity.net_id] = brain
	var pattern: BotBrain.Pattern = brain.get_pattern()
	var fighter: bool = pattern == BotBrain.Pattern.COMBAT or pattern == BotBrain.Pattern.SIEGE
	if fighter and not brain.has_enemy_finder():
		brain.set_enemy_finder(_z._zone_bots._find_enemy_target.bind(entity.net_id))
	if fighter and not brain.has_combat_source():
		# The phase 4 kit (H5): the server's combat state after the last tick, the health and the knocked-down allies.
		brain.set_combat_source(_z._zone_bots._fake_combat_state.bind(entity.net_id))
		brain.set_health_source(_z._zone_bots._fake_health_fraction.bind(entity.net_id))
		brain.set_ally_finder(_z._zone_bots._find_downed_ally.bind(entity.net_id))
	if pattern == BotBrain.Pattern.SIEGE and not brain.has_siege():
		brain.set_siege(_z._zone_bots.get_siege_view(), _z._zone_bots.get_approach_routes(), realm)
	if pattern == BotBrain.Pattern.SIEGE and not brain.has_threat_finder():
		brain.set_threat_finder(_z._zone_bots._find_threats.bind(entity.net_id))
	if pattern == BotBrain.Pattern.SIEGE and not brain.has_defender_finder():
		brain.set_defender_finder(_z._zone_bots._find_enemy_target.bind(entity.net_id, true))
	if pattern == BotBrain.Pattern.SIEGE and not brain.has_ally_counter():
		brain.set_ally_counter(_z._zone_bots._count_allies.bind(entity.net_id))
	if pattern == BotBrain.Pattern.SIEGE and not brain.has_line_of_sight():
		# The kit's bow only fires if the arrow lands (the palisade, the closed gate, also its own).
		brain.set_line_of_sight(_z._zone_bots._bot_line_of_sight)
	var record: ZoneServer._PlayerRecord = _z._player_by_net[entity.net_id]
	record.is_fake = true
	_announce_arrival(entity, null, _z._tick)
	if combatant.template_id > 0:
		_z._combat.announce_loadout(combatant, _z._tick, true)
	_z._log("Alta de %s (jugador falso, net_id %d, %s); jugadores: %d" % [entity.display_name,
			entity.net_id, NetProtocol.realm_display_name(realm), _z._zone_sessions.get_player_count()])
	return entity.net_id


## Removes fake player [param net_id] at the start of the next tick: DESPAWN (reason 1) to whoever
## saw it and the id into quarantine, as if it had disconnected. Returns false if it is not a fake
## player (or is already leaving). Used for the joins and leaves of load tests. If it is knocked down, its removal is
## preceded by a death (DEATH and KILL), like that of anyone who leaves knocked down.
func remove_fake_player(net_id: int) -> bool:
	if _z._run_state != ZoneServer._RunState.RUNNING or not _z._fakes.has(net_id) or _z._fake_leaving.has(net_id):
		return false
	_z._fake_leaving.append(net_id)
	return true


## Withdraws filler fake [param net_id], which yields its slot to a person (GUE-42 and GUE-43; requested by
## [FillerKeeper]): like [method remove_fake_player], but its removal is never a death, not even if it is knocked
## down (only DESPAWN, no DEATH or KILL for whoever knocked it down): a person entering kills nobody (review of
## the abilities integration). Returns false if it is not a fake player (or is already leaving).
func retire_filler(net_id: int) -> bool:
	if not remove_fake_player(net_id):
		return false
	_z._fake_leaving_quietly[net_id] = true
	return true


## true if withdrawing fake player [param net_id] right now cuts nothing off: it is not knocked down nor reviving or
## finishing off anyone (dead and waiting to respawn, too). The [member FillerKeeper.calm_check] of the filler fakes.
func is_fake_calm(net_id: int) -> bool:
	var combatant: Combatant = _z._combat.get_combatant(net_id)
	return combatant == null or (not combatant.is_downed() and not combatant.is_interacting())


## Creates a humanoid NPC named [param display_name] on side [param realm] (0 = the Hollow, hostile to
## everyone) at [param position] facing [param yaw]: a [PlayerCharacter] simulated in the same loop as the
## players with the inputs of [param brain] (like those of a fake player), with health and recorded in the
## history. With [param immortal] it is a dummy: health does not drop below 1 and it heals fully after 5 s
## without damage. Returns its [code]net_id[/code], or -1 if the server is not running or no ids are left. With
## [param definition] (an [NpcDefinition]) the NPC takes from it its health, its weapon, whether it ignores safe
## zones and its catalog number (the [code]npc_def_id[/code] of the ENTITY_SPAWN).
func add_npc(brain: BotBrain, display_name: String, realm: int, position: Vector3, yaw: float,
		immortal: bool = false, definition: NpcDefinition = null) -> int:
	if _z._run_state != ZoneServer._RunState.RUNNING or brain == null:
		return -1
	var entity: NetEntity = _create_body(NetProtocol.EntityKind.NPC, display_name, realm, 0, _z._tick,
			position, yaw)
	if entity == null:
		return -1
	_z._npcs[entity.net_id] = brain
	var combatant: Combatant = _z._combat.get_combatant(entity.net_id)
	if definition != null:
		# Its definition rules: health, weapon, safe zone and the number the client sees (model and boss bar).
		entity.npc_def_id = NpcCatalog.number_of(definition.id)
		combatant.max_health = definition.max_health
		combatant.health = definition.max_health
		combatant.ignores_safe_area = definition.ignores_safe_area
		_z._combat.set_weapon(combatant, CombatCatalog.weapon_id(definition.weapon_id))
		entity.set_health_view(combatant.health, combatant.max_health, 0, 0)
		immortal = immortal or definition.immortal
	combatant.immortal = immortal
	if immortal:
		_z._dummies_created += 1
	_announce_arrival(entity, null, _z._tick)
	_z._log("Alta del PNJ %s (net_id %d)%s en %s" % [display_name, entity.net_id,
			", inmortal" if immortal else "", position])
	return entity.net_id


## Removes NPC [param net_id] (DESPAWN to whoever saw it). Returns false if it is not an NPC.
func remove_npc(net_id: int) -> bool:
	var entity: NetEntity = _z._registry.get_entity(net_id)
	if entity == null or not _z._npcs.has(net_id):
		return false
	_remove_player(entity, _z._tick, NetProtocol.DespawnReason.DISCONNECTED)
	return true


## Creates a training dummy (immortal NPC of the neutral side) at [param position] facing
## [param yaw], with mode [param mode] ([enum NpcBrain.Mode]). The position is lowered to the ground if there is
## one below. Returns its net_id, or -1 if there is no room ([constant MAX_DUMMIES]) or it cannot be created.
func spawn_dummy(position: Vector3, yaw: float, mode: int = NpcBrain.Mode.STILL) -> int:
	if get_dummy_count() >= ZoneServer.MAX_DUMMIES:
		return -1
	return add_npc(NpcBrain.new(mode), ZoneServer.DUMMY_NAME, RealmCatalog.NEUTRAL_CODE,
			_ground_position(position), yaw, true)


## Places a still dummy at each marker of the zone's [code]dummy_points[/code] group (one in
## the test world and one next to each camp of Vado Gris). Returns how many it created.
func spawn_zone_dummies() -> int:
	var created: int = 0
	for marker: Node3D in NetZones.get_dummy_points(_z._world):
		var transform: Transform3D = marker.global_transform
		if spawn_dummy(transform.origin, CombatDirector._yaw_of(transform)) > 0:
			created += 1
	return created


## Test double of the captain of [param fortress_id] while there is no NPC spawner: a mortal, still NPC
## at the fortress's [code]CaptainSpawn[/code], on the owner's side, registered as its
## captain ([method FortressController.register_captain]). On death (from a hit or with
## [code]fort_kill_captain[/code]) it opens the capture circle. Returns its net_id, or -1 if it cannot.
func spawn_captain_double(fortress_id: StringName) -> int:
	if _z._fortresses == null:
		return -1
	var node: Node3D = _z._fortresses.get_node_of(fortress_id)
	var state: FortressState = _z._fortresses.get_fortress_state(fortress_id)
	if node == null or state == null:
		return -1
	var marker: Node3D = node.get_node_or_null(^"CaptainSpawn") as Node3D
	var transform: Transform3D = marker.global_transform if marker != null else node.global_transform
	var net_id: int = add_npc(NpcBrain.new(NpcBrain.Mode.STILL), "Capitán (prueba)", state.owner,
			transform.origin, _z._yaw_of(transform))
	if net_id > 0:
		_z._fortresses.register_captain(fortress_id, net_id)
	return net_id


## Living dummies (immortal NPCs).
func get_dummy_count() -> int:
	var count: int = 0
	for net_id: int in _z._npcs:
		var combatant: Combatant = _z._combat.get_combatant(net_id)
		if combatant != null and combatant.immortal:
			count += 1
	return count


# Spawns, with the state "after s", the peers whose CLIENT_READY arrived on this tick.
func _process_arrivals(s: int) -> void:
	if _z._pending_ready.is_empty():
		return
	var pending: Array[int] = _z._pending_ready.duplicate()
	_z._pending_ready.clear()
	for peer_id: int in pending:
		var peer: ServerPeer = _z._peers.get(peer_id)
		if peer == null or peer.state != ServerPeer.State.LOADING:
			continue
		var entity: NetEntity = _create_player(peer.display_name, peer.realm, peer_id, s)
		if entity == null:
			_z._zone_sessions._kick(peer, "no queda sitio en la zona", false)
			continue
		if peer.claimed != null:
			# From here the lease belongs to the body: it is saved (track before ProgressService.on_arrival, which
			# may mark it critical) and its final save goes out when it leaves (docs/platform.md §7.2).
			entity.is_staff = peer.claimed.is_staff()
			# The pvp totals from the claim: the base of its section (docs/platform.md §8).
			_z._scores.load_totals(entity.net_id, peer.claimed.pvp)
			if _z._saver != null:
				_z._saver.track(entity.net_id, peer.claimed.character_id, peer.claimed.lease_id, s)
		# Progress (progression.md §9.1 step 4): the prepared one or, without the platform, an ephemeral one is bound to
		# the body; the return-to-world rule, the first-entry kit (critical in this tick's step), level and appearance
		# for the SPAWN, and the equipment from its inventory instead of the template.
		var loadout: ProgressService.Loadout = _z._progress.on_arrival(entity, peer, s) if _z._progress != null else null
		peer.entity = entity
		peer.input_queue = _z._queues[entity.net_id]
		peer.state = ServerPeer.State.IN_WORLD
		var record: ZoneServer._PlayerRecord = _z._player_by_net[entity.net_id]
		record.peer = peer
		_z._world_peers.append(peer)
		# With the platform, chat is per character: it recovers the state if it left recently, and takes from the claim
		# its account, the players it ignores and its mute (docs/platform.md §9.2).
		_z._social.on_peer_joined(peer, s)
		# With an inventory, its equipment; otherwise, the pending template (LOADOUT_SELECT, also before CLIENT_READY) or
		# the default one: the SPAWN already goes out with its weapons and charges, and the LOADOUT after it.
		var combatant: Combatant = _z._combat.get_combatant(entity.net_id)
		if loadout != null:
			_z._combat.equip_inventory(combatant, loadout.weapon_1, loadout.weapon_2, loadout.second_active,
					loadout.charges)
		else:
			_z._combat.equip_template(combatant, maxi(peer.pending_template_id, 0))
		peer.pending_template_id = -1
		_announce_arrival(entity, peer, s)
		if combatant.template_id > 0 or loadout != null:
			_z._combat.announce_loadout(combatant, s, true)
		# INVENTORY_FULL, WALLET_UPDATE and PROGRESS_UPDATE after the own SPAWN (progression.md §9.1 step 5).
		if _z._progress != null:
			_z._progress.after_spawn(entity, peer, s)
		# The moderation notices the account has not seen (docs/platform.md §9.5).
		_z._moderation.on_arrival(peer)
		_z.player_joined.emit(peer_id, entity.net_id)
		if _z._filler_keeper != null:
			_z._filler_keeper.on_person_joined(peer.realm, peer_id)
		_z._log("Alta de %s (peer %d, net_id %d, %s) en %s; jugadores: %d" % [entity.display_name,
				peer_id, entity.net_id, NetProtocol.realm_display_name(peer.realm),
				entity.get_position(), _z._zone_sessions.get_player_count()])


# Creates the entity and the character of a player at a spawn point of their realm and gives it its
# combat. See _create_body.
func _create_player(display_name: String, realm: int, owner_peer: int, s: int) -> NetEntity:
	var spawn: Transform3D = _z._spawn_picker.pick(realm)
	var entity: NetEntity = _create_body(NetProtocol.EntityKind.PLAYER, display_name, realm,
			owner_peer, s, spawn.origin, _z._yaw_of(spawn))
	if entity == null:
		return null
	var queue: InputQueue = _z._queues[entity.net_id]

	var record := ZoneServer._PlayerRecord.new()
	record.net_id = entity.net_id
	record.peer_id = owner_peer
	record.display_name = display_name
	record.realm = realm
	record.joined_tick = s
	record.queue = queue
	record.entity = entity
	_z._player_by_net[entity.net_id] = record
	_z._player_log.append(record)
	_trim_player_log()
	_z._joined_total += 1
	_z._metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 1)
	_z._peak_players = maxi(_z._peak_players, _z._metrics.get_counter(ServerMetrics.COUNTER_PLAYERS))
	return entity


# Creates the entity of type [param kind] with its body (a PlayerCharacter) at [param spawn_origin]
# facing [param spawn_yaw], its input queue, its history track and its combat. The state is
# "the state after s", rounded by encode/decode; the queue starts with tick s already consumed and the
# neutral input as the last applied. null if no ids are left.
func _create_body(kind: int, display_name: String, realm: int, owner_peer: int, s: int,
		spawn_origin: Vector3, spawn_yaw: float) -> NetEntity:
	var entity: NetEntity = _z._registry.allocate(kind, s)
	if entity == null:
		return null
	entity.realm = realm
	entity.owner_peer = owner_peer
	entity.display_name = display_name

	var character: PlayerCharacter = _instantiate_character()
	character.name = ("Player%d" if kind == NetProtocol.EntityKind.PLAYER else "Npc%d") % entity.net_id
	_z._players_root.add_child(character)
	# After _ready() (which rewrites the mask): the closed gates of the forts stop the realms that are not
	# their owner. The client does the same with its local character.
	character.set_realm_collision(realm)
	var state := PlayerState.new()
	state.position = spawn_origin
	state.yaw = PlayerState.to_f32(spawn_yaw)
	state.grounded = _probe_grounded(spawn_origin)
	state.last_input_tick = s
	state = PlayerState.decode(state.encode())
	character.set_state(state)
	entity.node = character

	var queue := InputQueue.new()
	queue.reset(s, NetProtocol.neutral_input(s, state.yaw))
	_z._queues[entity.net_id] = queue
	_z._history.add_entity(entity.net_id)
	_z._combat.add(entity, queue, _z._peers.get(owner_peer))
	return entity


# Keeps the report ring at max_logged_players records: removes the oldest of those of someone who has
# already left (those of whoever is still inside stay, even if the ring overflows) and summarizes it in totals.
func _trim_player_log() -> void:
	while _z._player_log.size() > _z.max_logged_players:
		var index: int = -1
		for i: int in _z._player_log.size():
			if _z._player_log[i].left_tick >= 0:
				index = i
				break
		if index < 0:
			return
		var record: ZoneServer._PlayerRecord = _z._player_log[index]
		_z._player_log.remove_at(index)
		_z._archived_players += 1
		if record.is_fake:
			_z._archived_fakes += 1
		else:
			_z._archived_inputs += record.inputs
			_z._archived_substituted += record.substituted
			_z._archived_late += record.late
			_z._archived_too_early += record.too_early


# Messages of a spawn (section 3): the own SPAWN, those of everything relevant to the newcomer and theirs
# for whoever considers them relevant. [param peer] is null for a fake player.
# A player's SPAWN carries their level only toward their realm (protocol 7, docs/progression.md §7.3): the
# newcomer's is encoded once per receiving realm (three variants at most) and those of the others toward them,
# with their realm.
func _announce_arrival(entity: NetEntity, peer: ServerPeer, s: int) -> void:
	var spawn_by_realm: Dictionary[int, PackedByteArray] = {}
	if peer != null:
		_z._send(peer, NetProtocol.CH_RELIABLE, entity.encode_spawn(s, true))
	for other: NetEntity in _z._registry.get_sorted():
		if other == entity:
			continue
		if peer != null and _z._is_relevant(entity, other, false):
			peer.relevant[other.net_id] = true
			_z._send(peer, NetProtocol.CH_RELIABLE, other.encode_spawn(s, false, entity.realm))
		var other_peer: ServerPeer = _z._peers.get(other.owner_peer)
		if other_peer != null and other_peer.state == ServerPeer.State.IN_WORLD \
				and _z._is_relevant(other, entity, false):
			other_peer.relevant[entity.net_id] = true
			if not spawn_by_realm.has(other.realm):
				spawn_by_realm[other.realm] = entity.encode_spawn(s, false, other.realm)
			_z._send(other_peer, NetProtocol.CH_RELIABLE, spawn_by_realm[other.realm])


# Closes the session of the peers that are leaving: DESPAWN (reason 1) to whoever had them as relevant, id
# into quarantine, character released and history track deleted.
func _process_departures(s: int) -> void:
	_z._zone_lingering._process_lingering(s)
	_process_fake_departures(s)
	if _z._leaving.is_empty():
		return
	var leaving: Array[int] = _z._leaving.duplicate()
	_z._leaving.clear()
	for peer_id: int in leaving:
		var peer: ServerPeer = _z._peers.get(peer_id)
		if peer == null:
			continue
		_z._peers.erase(peer_id)
		_z._rtt.erase(peer_id)
		_z._social.on_peer_left(peer, s)
		if peer.entity == null:
			# Leaves without having entered: if the filler had set aside a slot for them, it is released (GUE-43; no fake
			# had left).
			if _z._filler_keeper != null:
				_z._filler_keeper.release_seat(peer_id)
			continue
		var entity: NetEntity = peer.entity
		# Out of the list first of all: whatever comes out of their removal (the death of a knocked-down player) is no longer for them.
		_z._world_peers.erase(peer)
		var save_reason: int = CharacterSaver.Reason.KICK if peer.kicked else CharacterSaver.Reason.LOGOUT
		var lingers: bool = not peer.drop_body_at_once and _z._zone_lingering._should_linger(entity, s)
		if lingers:
			_z._zone_lingering._start_lingering(entity, s)
			_z._lingering_save_reasons[entity.net_id] = save_reason
		else:
			_remove_player(entity, s, NetProtocol.DespawnReason.DISCONNECTED, true, save_reason)
		_z._left_total += 1
		_z.player_left.emit(peer_id, entity.net_id)
		if _z._filler_keeper != null:
			_z._filler_keeper.on_person_left(peer.realm)
		var linger_note: String = ""
		if lingers:
			linger_note = "; su cuerpo se queda %.0f s por estar en combate" \
					% (float(_z.linger_ticks) / float(Engine.physics_ticks_per_second))
		_z._log("Baja de %s (peer %d, net_id %d); jugadores: %d%s" % [entity.display_name, peer_id,
				entity.net_id, _z._zone_sessions.get_player_count(), linger_note])


# Removals of fake players requested with remove_fake_player().
func _process_fake_departures(s: int) -> void:
	if _z._fake_leaving.is_empty():
		return
	var leaving: Array[int] = _z._fake_leaving.duplicate()
	var quietly: Dictionary[int, bool] = _z._fake_leaving_quietly.duplicate()
	_z._fake_leaving.clear()
	_z._fake_leaving_quietly.clear()
	for net_id: int in leaving:
		var entity: NetEntity = _z._registry.get_entity(net_id)
		if entity == null or not _z._fakes.has(net_id):
			continue
		_remove_player(entity, s, NetProtocol.DespawnReason.DISCONNECTED, not quietly.has(net_id))
		_z._left_total += 1
		if _z._filler_keeper != null:
			_z._filler_keeper.forget(net_id)
		_z._log("Baja de %s (jugador falso, net_id %d); jugadores: %d" % [entity.display_name, net_id,
				_z._zone_sessions.get_player_count()])


# Removes the player from the world: DESPAWN to whoever saw them, id into quarantine and character released.
# The removal of a knocked-down player (exit, disconnect, --fake-churn, end of the GUE-41 body) is preceded by a
# death on that tick: DEATH and KILL with whoever did them the last damage or knocked them down, and the
# "bled out" source (docs/abilities.md, 4.5). Without [param bleed] (the filler fake yielding its slot to a
# person, retire_filler), it does not: only the DESPAWN. With the platform, the "Exit" of docs/platform.md
# §7.2: the final save ([param save_reason]) before ScoreKeeper.forget; after a removal without saving (drop)
# that finish does nothing.
func _remove_player(entity: NetEntity, s: int, reason: int, bleed: bool = true,
		save_reason: int = CharacterSaver.Reason.LOGOUT) -> void:
	var net_id: int = entity.net_id
	var leaving: Combatant = _z._combat.get_combatant(net_id)
	if bleed and leaving != null and leaving.is_downed():
		_z._combat.kill_downed(leaving, s)
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = net_id
	despawn.despawn_tick = s
	despawn.reason = reason
	var bytes: PackedByteArray = despawn.encode()
	for other: ServerPeer in _z._world_peers:
		if other.entity == entity:
			continue
		if other.relevant.erase(net_id):
			_z._send(other, NetProtocol.CH_RELIABLE, bytes)
		other.priority.erase(net_id)
	var record: ZoneServer._PlayerRecord = _z._player_by_net.get(net_id)
	if record != null:
		record.close(s)
		_z._player_by_net.erase(net_id)
	if _z._saver != null:
		_z._saver.finish(net_id, save_reason)
	_z._queues.erase(net_id)
	_z._fakes.erase(net_id)
	_z._npcs.erase(net_id)
	_z._lingering.erase(net_id)
	_z._lingering_save_reasons.erase(net_id)
	_z._scores.forget(net_id)
	if _z._progress != null:
		_z._progress.on_departure(net_id)
	_z._combat.remove(net_id, s)
	_z._history.forget(net_id)
	_z._substituted_now.erase(net_id)
	var character: PlayerCharacter = entity.get_character()
	if character != null:
		if character.get_parent() != null:
			character.get_parent().remove_child(character)
		character.queue_free()
	entity.node = null
	_z._registry.release(net_id, s)
	if entity.kind == NetProtocol.EntityKind.PLAYER:
		_z._metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, -1)


# Releases all players (server shutdown), without sending DESPAWN. The final saves have already gone out
# (_wind_down).
func _clear_players() -> void:
	for entity: NetEntity in _z._registry.get_sorted().duplicate():
		if _z._progress != null:
			_z._progress.on_departure(entity.net_id)
		var character: PlayerCharacter = entity.get_character()
		if character != null:
			if character.get_parent() != null:
				character.get_parent().remove_child(character)
			character.queue_free()
		entity.node = null
		_z._registry.release(entity.net_id, _z._tick)
	_z._world_peers.clear()
	_z._queues.clear()
	_z._fakes.clear()
	_z._npcs.clear()
	_z._lingering.clear()
	_z._lingering_save_reasons.clear()
	_z._scores.clear()
	if _z._fortresses != null:
		_z._fortresses.clear()
	if _z._combat != null:
		_z._combat.clear()
	_z._projectile_viewers.clear()
	_z._player_by_net.clear()
	_z._substituted_now.clear()
	for peer: ServerPeer in _z._peers.values():
		peer.entity = null
		peer.input_queue = null
		peer.relevant.clear()
		peer.priority.clear()
	_z._metrics.add_counter(ServerMetrics.COUNTER_PLAYERS,
			-_z._metrics.get_counter(ServerMetrics.COUNTER_PLAYERS))


# A spawn point of the realm (to place whoever falls out of the world while dead).
func _pick_spawn_point(realm: int) -> Transform3D:
	return _z._spawn_picker.pick(realm)


# The ground under [param position]: the point where a ray from a few meters above touches the world, or
# [param position] if there is no ground below. The ray is slightly tilted: vertical ones can miss
# against HeightMapShape3D.
func _ground_position(position: Vector3) -> Vector3:
	var space: PhysicsDirectSpaceState3D = _z._players_root.get_world_3d().direct_space_state
	var from: Vector3 = position + Vector3(0.0, _GROUND_PROBE_UP, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from,
			from + Vector3(0.001, -(_GROUND_PROBE_UP + _GROUND_PROBE_DOWN), 0.0),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return position
	return (hit["position"] as Vector3) + Vector3(0.0, 0.05, 0.0)


# Kills the registered captain NPC (for fort_kill_captain). Returns false if it cannot.
func _kill_captain_npc(net_id: int) -> bool:
	var combatant: Combatant = _z._combat.get_combatant(net_id)
	if combatant == null or combatant.is_dead() or combatant.immortal:
		return false
	_z._combat.kill(combatant, _z._tick + 1)
	return true


# Server character: an instance of player_character.tscn without its Visual node (meshes), without its own
# process. Only ZoneServer simulates it.
func _instantiate_character() -> PlayerCharacter:
	var character: PlayerCharacter = PLAYER_SCENE.instantiate() as PlayerCharacter
	var visual: Node = character.get_node_or_null(^"Visual")
	if visual != null:
		character.remove_child(visual)
		visual.free()
	character.set_physics_process(false)
	character.set_process(false)
	character.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	return character


# true if there is ground right under [param position] (within what the character's ground snap
# reaches): the spawn state is then born with grounded = true. The ray is slightly tilted
# because vertical ones can miss against HeightMapShape3D.
func _probe_grounded(position: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = _z._players_root.get_world_3d().direct_space_state
	var from: Vector3 = position + Vector3(0.0, _PROBE_UP, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from,
			from + Vector3(0.001, -(_PROBE_UP + _PROBE_DOWN), 0.0),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	return not space.intersect_ray(query).is_empty()
