class_name ZoneIntents
extends RefCounted
## What the zone does with each packet a client sends (docs/networking.md §3, §4 and §12): the dispatch by
## message type and the handlers of the intents: INPUT_BATCH, CLIENT_READY, CLIENT_LEAVE, RESPAWN_REQUEST and
## LOADOUT_SELECT. DEBUG_COMMAND and UNSTUCK_REQUEST go to [ZoneCommands]; the chat, party and inventory
## messages go to their own services.
## [br][br]
## [b]What lives here[/b]: [method _on_packet_received] (per-peer rate limiter, the state of the session
## decides which types are allowed, the strike for the unexpected ones), [method _handle_input_batch] (the
## inputs go into the player's [InputQueue]; the RTT window bounds the declared one) and the other handlers.
## None of them changes the simulation directly: the intents wait for the tick.
## [br][br]
## [b]Tick step[/b]: the poll (the first step). CLIENT_READY only queues the spawn; it happens in the spawns
## step, in [ZoneBodies].
## [br][br]
## [b]Touch this file[/b] to add a message type or change what is accepted from a client.
## [br][br]
## It is a plain [RefCounted] owned by the [ZoneServer], which builds it in [code]_init[/code] and passes
## itself in. The state it works on stays reachable through [code]_z[/code]; the state that only this
## subsystem uses lives here. It never runs a step of the tick on its own: [method ZoneServer._physics_process]
## calls it at the point the tick order (documented in its header) requires. Moving code between the
## subsystems is a mechanical change, but moving a call to a different step of the tick is not: the order is
## normative (docs/networking.md, section 3).


var _z: ZoneServer


func _init(zone: ZoneServer) -> void:
	_z = zone


func _on_packet_received(peer_id: int, bytes: PackedByteArray) -> void:
	var peer: ServerPeer = _z._peers.get(peer_id)
	if peer == null or _z._run_state != ZoneServer._RunState.RUNNING or bytes.is_empty():
		return
	if peer.state == ServerPeer.State.LEAVING:
		return
	var msg_type: int = NetMessages.peek_type(bytes)
	# Per-peer limiters: what exceeds them is discarded and adds a warning.
	var limiter: RateLimiter = peer.limiter_unreliable \
			if msg_type == NetProtocol.MSG_INPUT_BATCH else peer.limiter_reliable
	if not limiter.try_consume(_z._tick) or not peer.limiter_bytes.try_consume(_z._tick,
			float(bytes.size())):
		_z._zone_sessions._add_strike(peer, "exceso de ritmo")
		return
	if peer.state == ServerPeer.State.AUTHENTICATING or peer.state == ServerPeer.State.VERIFYING:
		_z._zone_sessions._add_strike(peer, "mensaje antes de autenticarse")
		return
	match msg_type:
		NetProtocol.MSG_INPUT_BATCH:
			_handle_input_batch(peer, bytes)
		NetProtocol.MSG_CLIENT_READY:
			_handle_client_ready(peer, bytes)
		NetProtocol.MSG_CLIENT_LEAVE:
			_handle_client_leave(peer, bytes)
		NetProtocol.MSG_DEBUG_COMMAND:
			_z._zone_commands._handle_debug_command(peer, bytes)
		NetProtocol.MSG_RESPAWN_REQUEST:
			_handle_respawn_request(peer, bytes)
		NetProtocol.MSG_UNSTUCK_REQUEST:
			_z._zone_commands._handle_unstuck_request(peer, bytes)
		NetProtocol.MSG_LOADOUT_SELECT:
			_handle_loadout_select(peer, bytes)
		NetProtocol.MSG_INVENTORY_REQUEST, NetProtocol.MSG_INVENTORY_SYNC_REQUEST:
			# The inventory (progression.md §4.2 and §4.6): RATE on arrival and the ProgressService.apply_pending queue.
			_z._progress.handle_packet(peer, bytes)
		_:
			# Chat and parties (0x40 to 0x4F) are handled by the social service.
			if not _z._social.handle_packet(peer, msg_type, bytes, _z._tick):
				_z._zone_sessions._add_strike(peer, "tipo de mensaje inesperado (0x%02X)" % msg_type)


func _handle_input_batch(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.IN_WORLD:
		_z._zone_sessions._add_strike(peer, "entradas antes de entrar en el mundo")
		return
	var batch: NetMessages.InputBatch = NetMessages.InputBatch.decode(bytes)
	if batch == null:
		_z._zone_sessions._add_strike(peer, "lote de entradas mal formado")
		return
	# The client's interpolation delay does not exceed 12 ticks (× 8): more is a fake client.
	peer.interp_delay_q = mini(batch.interp_delay_q, NetProtocol.MAX_INTERP_DELAY_Q)
	if batch.interp_delay_q > NetProtocol.MAX_INTERP_DELAY_Q:
		_z._zone_sessions._add_strike(peer, "retardo de interpolación fuera de rango")
	# The ack cannot go ahead of the server nor go backward; with it the RTT is measured in ticks.
	if batch.ack_snapshot_tick > 0 and batch.ack_snapshot_tick <= _z._tick \
			and batch.ack_snapshot_tick >= peer.ack_snapshot_tick:
		peer.ack_snapshot_tick = batch.ack_snapshot_tick
		var window: ZoneServer._RttWindow = _z._rtt.get(peer.peer_id)
		if window == null:
			window = ZoneServer._RttWindow.new()
			_z._rtt[peer.peer_id] = window
		var next_tick: int = _z._tick + 1
		window.add(next_tick, next_tick - batch.ack_snapshot_tick)
		var plausible: int = _max_plausible_rtt_ticks(peer)
		peer.rtt_ticks = mini(maxi(window.get_min(next_tick), 0), plausible)
		peer.rtt_peak_ticks = mini(maxi(window.get_max(next_tick), peer.rtt_ticks), plausible)
	# Lower bound of the RTT: ENet's, which the client does not control (used by the rewind as a minimum).
	if _z._transport != null:
		peer.rtt_floor_ticks = floori(_z._transport.get_rtt_ms(peer.peer_id)
				* float(Engine.physics_ticks_per_second) / 1000.0)
	for i: int in batch.inputs.size():
		peer.input_queue.push(batch.inputs[i], batch.view_offsets_q[i], _z._tick + 1)


# Bound on the RTT in ticks that a client can declare with its acks. The ack is decided by the client: one
# that delayed its acks would pass for someone with lag and obtain the maximum phase 3 rewind.
# The bound comes from sources it does not control: ENet's RTT, the delay added by the server's own
# network simulator and a margin. (The client's --net-sim does not count: in production it would be
# faking lag; to test with lag, the server's is used.)
func _max_plausible_rtt_ticks(peer: ServerPeer) -> int:
	var enet_ticks: int = 0
	var sim_ticks: int = 0
	if _z._transport != null:
		enet_ticks = ceili(_z._transport.get_rtt_ms(peer.peer_id) \
				* float(Engine.physics_ticks_per_second) / 1000.0)
		sim_ticks = _z._transport.get_sim_round_trip_ticks()
	return enet_ticks + sim_ticks + ZoneServer.RTT_SLACK_TICKS


func _handle_client_ready(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.LOADING or _z._pending_ready.has(peer.peer_id):
		_z._zone_sessions._add_strike(peer, "CLIENT_READY inesperado")
		return
	if NetMessages.ClientReady.decode(bytes) == null:
		_z._zone_sessions._add_strike(peer, "CLIENT_READY mal formado")
		return
	_z._pending_ready.append(peer.peer_id)


func _handle_client_leave(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if NetMessages.ClientLeave.decode(bytes) == null:
		_z._zone_sessions._add_strike(peer, "CLIENT_LEAVE mal formado")
		return
	_z._transport.disconnect_after_flush(peer.peer_id)
	_z._zone_sessions._mark_leaving(peer)


# RESPAWN_REQUEST: a dead player asks to respawn at point point_index of the zone's static list
# (NetZones.get_all_respawn_points). Out of the window (alive, or long before being able to) is a warning; an index that
# is no longer valid (an enemy camp, a fort that has changed hands or is under attack) is not: the client's state is
# stale and the first valid camp of its realm is used.
func _handle_respawn_request(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.IN_WORLD:
		_z._zone_sessions._add_strike(peer, "petición de reaparición antes de entrar en el mundo")
		return
	var request: NetMessages.RespawnRequest = NetMessages.RespawnRequest.decode(bytes)
	if request == null:
		_z._zone_sessions._add_strike(peer, "petición de reaparición mal formada")
		return
	var result: int = _z._combat.request_respawn(peer.entity.net_id, request.point_index, _z._tick + 1)
	if result != CombatDirector.RespawnRequestResult.ACCEPTED:
		_z._zone_sessions._add_strike(peer, "petición de reaparición fuera de plazo")


# LOADOUT_SELECT (docs/abilities.md, sections 4.6 and 5.1): the template for the next spawn. Valid in
# LOADING (from the WELCOME, before CLIENT_READY) and IN_WORLD; it has already gone through the reliable limiter. 0 = the
# default one, with no warning; an id that does not exist or cannot be chosen counts a warning and changes nothing.
func _handle_loadout_select(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.LOADING and peer.state != ServerPeer.State.IN_WORLD:
		_z._zone_sessions._add_strike(peer, "LOADOUT_SELECT inesperado")
		return
	var select: NetMessages.LoadoutSelect = NetMessages.LoadoutSelect.decode(bytes)
	if select == null:
		_z._zone_sessions._add_strike(peer, "LOADOUT_SELECT mal formado")
		return
	if select.template_id != 0:
		var template: EquipmentTemplate = CombatCatalog.template(select.template_id)
		if template == null or not template.selectable:
			_z._zone_sessions._add_strike(peer, "plantilla de equipo no válida (%d)" % select.template_id)
			return
	# Whoever has an inventory already has their equipment: after the spawn nothing changes (progression.md §2.5).
	if peer.entity != null and _z._progress.has_inventory(peer.entity.net_id):
		return
	peer.pending_template_id = select.template_id
