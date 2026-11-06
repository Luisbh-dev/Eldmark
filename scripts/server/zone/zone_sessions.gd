class_name ZoneSessions
extends RefCounted
## Connections of the zone: from the transport signal to the world and back (docs/networking.md §3 and §12,
## docs/platform.md §5.2 and §14.3).
## [br][br]
## [b]What lives here[/b]: the admission of a peer ([method _on_peer_authenticating], [method _on_auth_received],
## [method _welcome], [method _reject]); the platform poll of the tick ([method _poll_platform]: claims,
## heartbeat, fortress and moderation events, and the expired VERIFYING peers); the deadlines of the HELLO and
## of loading ([method _check_hello_timeouts], [method _check_loading_timeouts]); the seats of the zone (capacity,
## filler fakes, the per-IP cap: [method get_player_count], [method _occupied_seats], [method _make_room_for],
## [method _connections_from]); strikes, kicks and the cooldown that follows ([method _add_strike],
## [method _kick], [method _start_cooldown]); and the revocations that come from the platform
## ([method _revoke], [method _on_save_rejected]).
## [br][br]
## [b]Tick steps[/b]: the transport signals fire inside the poll (the first step of the tick), and so does
## [method _poll_platform]; the HELLO and loading deadlines run right after the tick counter advances, before
## the removals. Peers are only marked as leaving here ([method _mark_leaving]); the removal itself is the
## removals step, in [ZoneBodies].
## [br][br]
## [b]Touch this file[/b] to change who gets in, who is thrown out and with what message. The texts that the
## player sees (REJECT and NOTICE) are localized in L4 and are not changed by the split.
## [br][br]
## [b]Connection[/b] (section 3): the HELLO arrives through [signal NetTransport.auth_received] and is
## validated by [ServerAuth]; on success WELCOME is answered and [method NetTransport.complete_auth]
## (the peer moves to [constant ServerPeer.State.LOADING]) and, otherwise, REJECT and an orderly
## disconnect. Nothing is sent through [code]send[/code] until [signal NetTransport.peer_connected]
## arrives. The player appears at the end of the tick in which CLIENT_READY arrives.
## [br][br]
## [b]With the platform[/b] (docs/platform.md §5.2, [TicketAuthProvider] and [ZonePlatform]): a HELLO
## with a valid ticket leaves the peer in [constant ServerPeer.State.VERIFYING] (it counts toward capacity)
## while the platform claims it; on the 200, the zone checks that it admits its realm (REALM) and that
## there is room (FULL) and sends it the WELCOME with the realm and the character name, never those from
## the HELLO. A removal in VERIFYING cancels the wait (if the claim arrives later, it is released); one in
## LOADING releases the lease without saving.
## [br][br]
## [b]Security[/b] (section 12): per-peer limiters, warnings with a kick at 50 in 600 ticks (kick NOTICE
## and disconnect), a cap on connections per IP, unexpected message types according to the session state
## and debug commands only with [code]--debug-commands[/code].
## [br][br]
## It is a plain [RefCounted] owned by the [ZoneServer], which builds it in [code]_init[/code] and passes
## itself in. The state it works on stays reachable through [code]_z[/code]; the state that only this
## subsystem uses lives here. It never runs a step of the tick on its own: [method ZoneServer._physics_process]
## calls it at the point the tick order (documented in its header) requires. Moving code between the
## subsystems is a mechanical change, but moving a call to a different step of the tick is not: the order is
## normative (docs/networking.md, section 3).


## How many ticks between checks of the HELLO deadline.
const HELLO_CHECK_TICKS: int = 10
## Reason with which the expired VERIFYING deadline is logged.
const VERIFY_TIMEOUT_REASON: String = "la plataforma no ha contestado a tiempo"

var _z: ZoneServer
# Key ("ip:<group>" or "name:<normalized name>") -> tick until which it cannot rejoin.
var _kick_until: Dictionary[String, int] = {}


func _init(zone: ZoneServer) -> void:
	_z = zone


## Ids of all known peers, sorted.
func get_peer_ids() -> PackedInt32Array:
	var ids := PackedInt32Array(_z._peers.keys())
	ids.sort()
	return ids


## Players that count toward capacity: the peers verifying their ticket with the platform (docs/platform.md
## §5.2: several simultaneous entries do not exceed max_players), the accepted ones (loading the zone or already
## inside) and the fake players. Those that have not yet sent the HELLO or are leaving (also fakes with a
## requested removal, which disappear at the start of the next tick) do not count. Filler fakes do count here, but
## yield their slot to people (see [method set_filler_keeper]): while a person loads the zone in the slot a fake
## set aside for them, both count (one too many), and the fake leaves when the person enters the world.
func get_player_count() -> int:
	var count: int = _z._fakes.size() - _z._fake_leaving.size()
	for peer: ServerPeer in _z._peers.values():
		if peer.state == ServerPeer.State.VERIFYING or peer.state == ServerPeer.State.LOADING \
				or peer.state == ServerPeer.State.IN_WORLD:
			count += 1
	return count


## People per realm (Vardheim, Solmarch, Askarra; see [RealmBalance]): the truly accepted clients, loading the
## zone or already inside (with [param in_world_only], only those already inside). Fake players and the bodies
## that remain after an in-combat removal do not count. [param excluded] is not counted (the one who just
## entered, for their WELCOME). It is the count of the WELCOME and of the REJECT 9 IMBALANCE.
func get_realm_counts(in_world_only: bool = false, excluded: ServerPeer = null) -> PackedInt32Array:
	var counts: PackedInt32Array = RealmBalance.empty_counts()
	for peer: ServerPeer in _z._peers.values():
		if peer == excluded:
			continue
		var counted: bool = peer.state == ServerPeer.State.IN_WORLD \
				or (not in_world_only and peer.state == ServerPeer.State.LOADING)
		if counted and peer.realm >= 1 and peer.realm <= RealmBalance.REALM_COUNT:
			counts[peer.realm - 1] += 1
	return counts


## Entries of the cooldown after kicks (in force or not yet purged). They are purged when the next kick is
## recorded, so the dictionary does not grow beyond the kicks of the last [constant KICK_COOLDOWN_TICKS] ticks.
func get_cooldown_count() -> int:
	return _kick_until.size()


## Names of the players present in the zone: the accepted peers (loading or already inside) and the fake
## players. [ServerAuth] rejects with NAME a HELLO whose name repeats any of them.
func get_connected_names() -> PackedStringArray:
	var names := PackedStringArray()
	for peer: ServerPeer in _z._peers.values():
		if peer.state == ServerPeer.State.LOADING or peer.state == ServerPeer.State.IN_WORLD:
			names.append(peer.display_name)
	for net_id: int in _z._fakes:
		var record: ZoneServer._PlayerRecord = _z._player_by_net.get(net_id)
		if record != null:
			names.append(record.display_name)
	# The name of whoever left in combat stays reserved while their body is in the world (GUE-41).
	for net_id: int in _z._lingering:
		var body: NetEntity = _z._registry.get_entity(net_id)
		if body != null:
			names.append(body.display_name)
	return names


## Kicks [param peer] with the NOTICE [param notice_text] and its final save (reason 5, [code]KICK[/code]), with
## the usual cooldown; [param reason] stays in the log and in the report (moderation, P7b).
func kick_peer(peer: ServerPeer, reason: String, notice_text: String) -> void:
	if _z._transport == null:
		peer.kicked = true
		_mark_leaving(peer)
		return
	_kick(peer, reason, true, notice_text)


# Peers that have spent too long loading the zone without sending CLIENT_READY.
func _check_loading_timeouts(s: int) -> void:
	if s % 60 != 0:
		return
	for peer: ServerPeer in _z._peers.values():
		if peer.state == ServerPeer.State.LOADING \
				and s - peer.loading_since_tick >= _z.loading_timeout_ticks:
			_kick(peer, "se agotó el tiempo de carga de la zona")


# Peers that have been connected too long without sending the HELLO: each idle connection takes an ENet slot
# (max_players + 4) until the 5 s deadline of SceneMultiplayer expires, and reopening it costs one
# RTT. They are cut with their own much shorter deadline, without REJECT (there is nothing to answer).
func _check_hello_timeouts(s: int) -> void:
	if s % HELLO_CHECK_TICKS != 0:
		return
	for peer: ServerPeer in _z._peers.values():
		if peer.state == ServerPeer.State.AUTHENTICATING \
				and s - peer.connected_tick >= _z.hello_timeout_ticks:
			_z._rejects[ZoneServer.HELLO_TIMEOUT_REASON] = _z._rejects.get(ZoneServer.HELLO_TIMEOUT_REASON, 0) + 1
			_z._log("Conexión de %s (peer %d) cortada: %s" % [peer.remote_address, peer.peer_id,
					ZoneServer.HELLO_TIMEOUT_REASON])
			_z._transport.disconnect_after_flush(peer.peer_id)
			_mark_leaving(peer)


# A client has connected and starts authenticating: its HELLO is awaited.
func _on_peer_authenticating(peer_id: int) -> void:
	if _z._run_state != ZoneServer._RunState.RUNNING:
		return
	var peer := ServerPeer.new(peer_id)
	peer.remote_address = _z._transport.get_remote_address(peer_id)
	if _z.remote_address_override.is_valid():
		peer.remote_address = str(_z.remote_address_override.call(peer_id, peer.remote_address))
	peer.connected_tick = _z._tick
	peer.connected_at_msec = Time.get_ticks_msec()
	_z._peers[peer_id] = peer
	# Whoever was kicked recently does not get back in within an RTT with warnings at 0 and full buckets: their IP
	# receives a REJECT right on connecting (TOO_MANY_CONNECTIONS is reused so as not to bump PROTOCOL_VERSION).
	if _is_cooling_down(_cooldown_key_for_address(peer.remote_address)):
		_reject(peer, NetProtocol.Result.TOO_MANY_CONNECTIONS)
		return
	# The per-IP cap is applied already on connect, not only when the HELLO arrives: an IP that opens connections
	# without sending anything would take up all the ENet slots and legitimate clients would be left without a
	# response. Those that exceed the cap receive a REJECT and are cut.
	if _connections_from(peer) >= _z._config.max_connections_per_ip \
			and not ServerAuth.is_loopback(peer.remote_address):
		_reject(peer, NetProtocol.Result.TOO_MANY_CONNECTIONS)


# HELLO: it is validated and answered with WELCOME (and complete_auth) or REJECT (and orderly disconnect). With a ticket,
# the peer stays in VERIFYING until the platform answers the claim (_apply_auth_outcome).
func _on_auth_received(peer_id: int, bytes: PackedByteArray) -> void:
	var peer: ServerPeer = _z._peers.get(peer_id)
	if peer == null or _z._run_state != ZoneServer._RunState.RUNNING or peer.state == ServerPeer.State.LEAVING:
		return
	if peer.state != ServerPeer.State.AUTHENTICATING:
		_add_strike(peer, "mensaje de autenticación inesperado")
		return
	var hello: NetMessages.Hello = NetMessages.Hello.decode(bytes)
	var result: int = NetProtocol.Result.MALFORMED
	if hello != null:
		peer.character_id = hello.character_id if _z._auth.uses_tickets() else 0
		if _is_cooling_down(_cooldown_key_for_identity(peer.remote_address, hello.display_name,
				peer.character_id)):
			_reject(peer, NetProtocol.Result.TOO_MANY_CONNECTIONS)
			return
		result = _z._auth.validate(peer_id, hello, peer.remote_address, _occupied_seats(),
				_connections_from(peer), _filler_seats())
		if result == NetProtocol.Result.OK and not _make_room_for(peer, hello.realm, hello.display_name,
				_occupied_seats()):
			result = NetProtocol.Result.FULL
	if result == AuthProvider.PENDING:
		peer.state = ServerPeer.State.VERIFYING
		return
	if result != NetProtocol.Result.OK:
		var text: String = ""
		if result == NetProtocol.Result.TICKET and hello != null and hello.ticket.is_empty() \
				and _z._auth.uses_tickets():
			text = TicketAuthProvider.NO_TICKET_TEXT
		_reject(peer, result, text)
		return
	_welcome(peer, hello.realm, hello.display_name)


# WELCOME and complete_auth: the peer moves to LOADING with [param realm] and [param display_name] (those of the HELLO
# without the platform; those of the claim with it).
func _welcome(peer: ServerPeer, realm: int, display_name: String) -> void:
	peer.state = ServerPeer.State.LOADING
	peer.realm = realm
	peer.display_name = display_name
	peer.loading_since_tick = _z._tick
	var welcome := NetMessages.Welcome.new()
	welcome.server_tick = _z._tick
	welcome.tick_rate = Engine.physics_ticks_per_second
	welcome.realm = realm
	welcome.channel = _z._config.channel
	welcome.zone_id = _z._config.zone_id
	welcome.realm_counts = get_realm_counts(false, peer)
	var error: Error = _z._transport.send_auth(peer.peer_id, welcome.encode())
	if error == OK:
		error = _z._transport.complete_auth(peer.peer_id)
	if error != OK:
		_mark_leaving(peer)


# "poll" step with the platform: the events, by kind and in arrival order (instance_closed last), the finals of the
# AuthProvider and the expired VERIFYING peers. While shutting down (STOPPING) only the responses to saves and claims
# count (those that arrive late are released): the heartbeat no longer kicks or warns.
func _poll_platform() -> void:
	var running: bool = _z._run_state == ZoneServer._RunState.RUNNING
	if _z._platform != null:
		var closed_code: String = ""
		for event: PlatformEvent in _z._platform.take_events():
			match event.kind:
				PlatformEvent.KIND_CLAIM:
					if _z._auth_provider != null:
						_z._auth_provider.on_platform_event(event)
				PlatformEvent.KIND_SAVE:
					if _z._saver != null:
						_z._saver.on_platform_event(event)
				PlatformEvent.KIND_HEARTBEAT:
					if running:
						_on_heartbeat_event(event)
				PlatformEvent.KIND_INSTANCE_CLOSED:
					closed_code = event.error_code
				PlatformEvent.KIND_ID_BLOCK, PlatformEvent.KIND_PROGRESS_OP, PlatformEvent.KIND_PROGRESS_LEDGER:
					if _z._progress != null:
						_z._progress.on_platform_event(event)
				PlatformEvent.KIND_FORTRESS:
					if _z._fortress_persistence != null:
						_z._fortress_persistence.on_platform_event(event)
				PlatformEvent.KIND_IGNORE, PlatformEvent.KIND_REPORT, PlatformEvent.KIND_SANCTION:
					if running:
						_z._moderation.on_platform_event(event)
		if not closed_code.is_empty():
			_z._log("La plataforma ha cerrado esta instancia (%s)" % closed_code)
			if running:
				_z.instance_closed.emit(closed_code)
	if _z._auth_provider != null:
		for outcome: AuthOutcome in _z._auth_provider.take_completed():
			_apply_auth_outcome(outcome)
	if running:
		_check_verify_timeouts()


# The outcome of a claim (table of §5.2). With OK, in order: (1) the zone admits the character's realm
# (REALM); (2) there is room (FULL); (3) ProgressService.prepare (progression.md §9.1: if the record cannot be read,
# UNAVAILABLE with "No se ha podido cargar el personaje" (the character could not be loaded) and an alert); (4) WELCOME
# with the realm and the character name. If any fails, REJECT and the lease is released.
func _apply_auth_outcome(outcome: AuthOutcome) -> void:
	var peer: ServerPeer = _z._peers.get(outcome.peer_id)
	if peer == null or peer.state != ServerPeer.State.VERIFYING:
		# It left on the same tick: the provider was no longer waiting for it, but just in case nothing is left hanging.
		if outcome.result == NetProtocol.Result.OK and outcome.claimed != null and _z._platform != null:
			_z._platform.release(outcome.claimed.character_id, outcome.claimed.lease_id)
		return
	if outcome.result != NetProtocol.Result.OK:
		_reject(peer, outcome.result, outcome.text)
		return
	var claimed: ClaimedCharacter = outcome.claimed
	var rejection: int = NetProtocol.Result.OK
	if not _z._auth.is_realm_allowed(claimed.realm):
		rejection = NetProtocol.Result.REALM
	else:
		# It already counts in _occupied_seats (VERIFYING): capacity is checked without it, as in ServerAuth.
		var others: int = _occupied_seats() - 1
		if others - _filler_seats() >= _z._config.max_players \
				or not _make_room_for(peer, claimed.realm, claimed.display_name, others):
			rejection = NetProtocol.Result.FULL
	if rejection != NetProtocol.Result.OK:
		_z._platform.release(claimed.character_id, claimed.lease_id)
		_reject(peer, rejection)
		return
	if not _z._progress.prepare(peer.peer_id, claimed):
		_z._log("Alerta: no se ha podido cargar el personaje %d (peer %d): se rechaza y se libera"
				% [claimed.character_id, peer.peer_id])
		_z._platform.release(claimed.character_id, claimed.lease_id)
		_reject(peer, NetProtocol.Result.UNAVAILABLE, ProgressService.PREPARE_FAILED_TEXT)
		return
	peer.claimed = claimed
	_welcome(peer, claimed.realm, claimed.display_name)
	if peer.state == ServerPeer.State.LOADING:
		_z._log("%s (personaje %d, cuenta %d, %s) entra con billete (peer %d)" % [claimed.display_name,
				claimed.character_id, claimed.account_id, claimed.role, peer.peer_id])


# Peers in VERIFYING for more than verify_timeout_ms (real time, since connecting): REJECT
# UNAVAILABLE. If the claim arrives later, the provider releases it.
func _check_verify_timeouts() -> void:
	var now: int = Time.get_ticks_msec()
	for peer: ServerPeer in _z._peers.values():
		if peer.state == ServerPeer.State.VERIFYING and now - peer.connected_at_msec >= _z.verify_timeout_ms:
			_z._log("Conexión de %s (peer %d): %s" % [peer.remote_address, peer.peer_id, VERIFY_TIMEOUT_REASON])
			_reject(peer, NetProtocol.Result.UNAVAILABLE)


# Heartbeat response: the revoked ones (§6) and maintenance (§12). Each revoked carries the lease_id; one that does not
# match the character's current lease in this zone kicks nobody. lease_lost is the removal without saving
# (without releasing: the lease is no longer the zone's); the others kick with the platform's text and a final save
# when the body leaves (in LOADING, release without saving). Mutes go to moderation (§9.5).
func _on_heartbeat_event(event: PlatformEvent) -> void:
	if not event.is_success():
		return
	_z._zone_lifecycle._set_maintenance(event.body_dict().get("maintenance"))
	_z._moderation.on_heartbeat(event)
	for value: Variant in PlatformJson.array_in(event.body_dict(), "revoked"):
		var revoked: Dictionary = value if value is Dictionary else {}
		var character_id: int = PlatformJson.id_of(revoked.get("character_id"))
		var lease_id: String = PlatformJson.text_in(revoked, "lease_id")
		var reason: String = PlatformJson.text_in(revoked, "reason")
		var text: String = PlatformJson.text_in(revoked, "text")
		if character_id < 1 or lease_id.is_empty():
			continue
		_revoke(character_id, lease_id, reason, text)


func _revoke(character_id: int, lease_id: String, reason: String, text: String) -> void:
	var lease_lost: bool = reason == CharacterSaver.LEASE_LOST
	for peer: ServerPeer in _z._peers.values():
		if peer.claimed == null or peer.claimed.character_id != character_id \
				or peer.claimed.lease_id != lease_id:
			continue
		if peer.state != ServerPeer.State.LOADING and peer.state != ServerPeer.State.IN_WORLD:
			continue
		_z._log("La plataforma revoca a %s (personaje %d): %s" % [peer.display_name, character_id, reason])
		if lease_lost:
			# The removal without saving (§7.2): the lease is no longer this zone's, so it is neither released nor
			# saved, and the body leaves immediately (no in-combat exit).
			if peer.entity != null and _z._saver != null:
				_z._saver.drop(peer.entity.net_id, CharacterSaver.LEASE_LOST)
			peer.claimed = null
			peer.drop_body_at_once = true
		_kick(peer, reason, false, text if not text.is_empty() else "Tu sesión ha terminado: vuelve a entrar")
		return
	# A body that remains after an in-combat exit: with lease_lost it leaves now, without saving or release. With the
	# other reasons its owner already left: the final save goes out when it is withdrawn.
	if lease_lost and _z._saver != null:
		var net_id: int = _z._saver.net_id_of(character_id, lease_id)
		if net_id > 0 and _z._lingering.has(net_id):
			_z._log("La plataforma revoca el cuerpo que queda del personaje %d: lease_lost" % character_id)
			_z._saver.drop(net_id, CharacterSaver.LEASE_LOST)
			_z._lingering[net_id] = 0


# A save definitively rejected before its final (CharacterSaver.save_rejected, docs/platform.md
# §7.2 and §7.3): the removal without saving. (1) drop, which releases except with lease_lost; (2) NOTICE and kick with
# the body removed immediately, no in-combat exit (the one that remained after an in-combat exit is withdrawn now); (3)
# ScoreKeeper.forget and ProgressService.on_departure, on the body's removal, whose finish no longer does anything.
func _on_save_rejected(net_id: int, character_id: int, code: String) -> void:
	if _z._saver != null:
		_z._saver.drop(net_id, code)
	var text: String = ZoneServer.LEASE_LOST_TEXT if code == CharacterSaver.LEASE_LOST else ZoneServer.SAVE_REJECTED_TEXT
	var entity: NetEntity = _z._registry.get_entity(net_id)
	if entity == null:
		return
	if _z._lingering.has(net_id):
		_z._log("Se retira ya el cuerpo del personaje %d: su guardado se ha rechazado (%s)" % [character_id, code])
		_z._lingering[net_id] = 0
		return
	var peer: ServerPeer = _z._peers.get(entity.owner_peer)
	if peer == null or peer.entity != entity:
		return
	peer.drop_body_at_once = true
	if _z._transport != null:
		_kick(peer, "guardado rechazado (%s)" % code, false, text)
	else:
		_mark_leaving(peer)


# A peer that leaves VERIFYING or LOADING without reaching the world (§5.2): in VERIFYING the wait for its
# claim is cancelled; in LOADING its lease is released without saving and its prepared progress is discarded
# (ProgressService.cancel_prepared, progression.md §9.1 step 3).
func _leave_auth_states(peer: ServerPeer) -> void:
	match peer.state:
		ServerPeer.State.VERIFYING:
			if _z._auth_provider != null:
				_z._auth_provider.cancel(peer.peer_id)
		ServerPeer.State.LOADING:
			if _z._progress != null:
				_z._progress.cancel_prepared(peer.peer_id)
			if peer.claimed != null and _z._platform != null:
				_z._platform.release(peer.claimed.character_id, peer.claimed.lease_id)
				peer.claimed = null


# Authentication completed on both sides: it is now possible to send to this peer.
func _on_peer_connected(peer_id: int) -> void:
	var peer: ServerPeer = _z._peers.get(peer_id)
	if peer == null or peer.state != ServerPeer.State.LOADING:
		return
	_z._log("Conexión de %s (peer %d, %s, %s): cargando la zona" % [peer.display_name, peer_id,
			peer.remote_address, NetProtocol.realm_display_name(peer.realm)])


func _on_peer_disconnected(peer_id: int) -> void:
	var peer: ServerPeer = _z._peers.get(peer_id)
	if peer == null:
		return
	if _z._run_state == ZoneServer._RunState.STOPPING:
		_z._peers.erase(peer_id)
		return
	_mark_leaving(peer)


# The transport has discarded [param count] packets from this peer for not being part of the protocol (SYS that is not
# authentication before the HELLO; afterwards, anything that is not an application packet): a real client never
# sends them. Each adds a warning; at 50 it is kicked. With more than 50 at once there is no need to count them all.
func _on_packets_discarded(peer_id: int, count: int) -> void:
	var peer: ServerPeer = _z._peers.get(peer_id)
	if peer == null or _z._run_state != ZoneServer._RunState.RUNNING or peer.state == ServerPeer.State.LEAVING:
		return
	for _i: int in mini(count, ServerPeer.STRIKE_LIMIT):
		_add_strike(peer, ZoneServer.DISCARDED_REASON)
		if peer.state == ServerPeer.State.LEAVING:
			return


# Adds a warning and kicks the peer if it reaches the limit (50 in 600 ticks).
func _add_strike(peer: ServerPeer, reason: String) -> void:
	_z._strikes_total += 1
	_z._strike_reasons[reason] = _z._strike_reasons.get(reason, 0) + 1
	if peer.add_strike(_z._tick, reason):
		_kick(peer, reason)


# Kick NOTICE and orderly disconnect. The reason stays in the report. With [param cooldown], their IP (or,
# from loopback, their name or their character) cannot rejoin for kick_cooldown_ticks. With
# [param notice_text] the NOTICE carries that text as is (that of a platform revoked).
func _kick(peer: ServerPeer, reason: String, cooldown: bool = true, notice_text: String = "") -> void:
	if peer.state == ServerPeer.State.LEAVING:
		return
	if cooldown:
		_start_cooldown(peer)
	peer.kicked = true
	var notice := NetMessages.Notice.new()
	notice.code = NetProtocol.NoticeCode.KICK
	notice.text = notice_text if not notice_text.is_empty() else "Expulsado del servidor: %s" % reason
	_z._transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, notice.encode())
	_z._transport.disconnect_after_flush(peer.peer_id)
	var net_id: int = peer.entity.net_id if peer.entity != null else 0
	_z._kicks.append({
		"tick": _z._tick, "peer_id": peer.peer_id, "net_id": net_id, "name": peer.display_name,
		"reason": reason,
	})
	_z._kicks_total += 1
	while _z._kicks.size() > _z.max_logged_kicks:
		_z._kicks.pop_front()
	var record: ZoneServer._PlayerRecord = _z._player_by_net.get(net_id)
	if record != null:
		record.kicked = true
		record.kick_reason = reason
	_z._log("Expulsión de %s (peer %d): %s" % [peer.display_name, peer.peer_id, reason])
	_mark_leaving(peer)


# Records the cooldown of a kicked peer and purges the expired ones. By IP (IPv6, by /64) except
# from loopback, where there is no per-IP cap and the normalized name is used, if it had already been given (with a ticket, the
# character: character:<id>, docs/platform.md §5.4).
func _start_cooldown(peer: ServerPeer) -> void:
	var key: String = _cooldown_key_for_address(peer.remote_address)
	if key.is_empty():
		key = _cooldown_key_for_identity(peer.remote_address, peer.display_name, peer.character_id)
	if key.is_empty():
		return
	for old_key: String in _kick_until.keys():
		if _kick_until[old_key] <= _z._tick:
			_kick_until.erase(old_key)
	_kick_until[key] = _z._tick + _z.kick_cooldown_ticks


# Cooldown key by address, or empty if it is loopback or unknown.
func _cooldown_key_for_address(address: String) -> String:
	if address.is_empty() or ServerAuth.is_loopback(address):
		return ""
	return "ip:" + ServerAuth.address_group(address)


# Cooldown key by identity: only from loopback, which has no per-IP cap. With a ticket, the character
# ([param character_id] > 0); without it, the HELLO name.
func _cooldown_key_for_identity(address: String, display_name: String, character_id: int) -> String:
	if not ServerAuth.is_loopback(address):
		return ""
	if character_id > 0:
		return "character:%d" % character_id
	if display_name.is_empty():
		return ""
	return "name:" + NameRules.normalize_key(display_name)


func _is_cooling_down(key: String) -> bool:
	return not key.is_empty() and _kick_until.get(key, 0) > _z._tick


func _mark_leaving(peer: ServerPeer) -> void:
	if peer.state == ServerPeer.State.LEAVING:
		return
	_leave_auth_states(peer)
	peer.state = ServerPeer.State.LEAVING
	_z._leaving.append(peer.peer_id)


# REJECT and orderly disconnect: what is queued goes out before cutting. [param text] empty = that of
# NetProtocol.result_text (the report always counts by that, not by the custom text).
func _reject(peer: ServerPeer, result: int, text: String = "") -> void:
	var reject := NetMessages.Reject.new()
	reject.result = result
	reject.text = text if not text.is_empty() else NetProtocol.result_text(result)
	_z._transport.send_auth(peer.peer_id, reject.encode())
	_z._transport.disconnect_after_flush(peer.peer_id)
	var key: String = NetProtocol.result_text(result)
	_z._rejects[key] = _z._rejects.get(key, 0) + 1
	_z._log("Conexión rechazada de %s (peer %d): %s" % [peer.remote_address, peer.peer_id,
			reject.text])
	_mark_leaving(peer)


# Living filler fakes, without those with a requested removal (those no longer count in get_player_count).
func _live_fillers() -> int:
	if _z._filler_keeper == null:
		return 0
	var count: int = 0
	for net_id: int in _z._fakes:
		if _z._filler_keeper.is_filler(net_id) and not _z._fake_leaving.has(net_id):
			count += 1
	return count


# Slots the filler has set aside for people still loading the zone (GUE-43): at most one per living filler
# fake. Each one is one player too many until that person enters the world and their fake leaves.
func _reserved_seats() -> int:
	if _z._filler_keeper == null:
		return 0
	return mini(_z._filler_keeper.reserved_count(), _live_fillers())


# Slots occupied for capacity: the players of get_player_count() minus the filler fakes that have already set aside
# their slot for someone (they leave when that person enters).
func _occupied_seats() -> int:
	return get_player_count() - _reserved_seats()


# Filler fakes that can still yield their slot to a person (GUE-43): the living ones that have not already set it aside.
func _filler_seats() -> int:
	return maxi(_live_fillers() - _reserved_seats(), 0)


# An accepted HELLO with the server full only because of filler fakes: the keeper sets aside the slot of one, which
# leaves when the person enters the world (FillerKeeper.on_person_joined). false if there is no room (it should not
# happen: ServerAuth has already checked that the filler suffices). [param occupied] is the occupied slots not counting them.
func _make_room_for(peer: ServerPeer, realm: int, display_name: String, occupied: int) -> bool:
	if occupied < _z._config.max_players:
		return true
	if _z._filler_keeper == null or _filler_seats() <= 0:
		return false
	if not _z._filler_keeper.reserve_seat(peer.peer_id, realm):
		return false
	_z._log("Servidor lleno de relleno: un falso de relleno aparta su plaza a %s (peer %d, %s); se irá cuando entre"
			% [display_name, peer.peer_id, NetProtocol.realm_display_name(realm)])
	return true


# Open connections from the same IP as [param peer], not counting it (IPv6 ones are counted by
# /64 prefix, see ServerAuth.address_group).
func _connections_from(peer: ServerPeer) -> int:
	if peer.remote_address.is_empty():
		return 0
	var group: String = ServerAuth.address_group(peer.remote_address)
	var count: int = 0
	for other: ServerPeer in _z._peers.values():
		if other != peer and other.state != ServerPeer.State.LEAVING \
				and ServerAuth.address_group(other.remote_address) == group:
			count += 1
	return count
