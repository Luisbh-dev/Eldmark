class_name ZoneLifecycle
extends RefCounted
## How the zone ends: the shutdown countdown, the maintenance announced by the platform and the drain that
## waits for the final saves (docs/platform.md §6.1, §7.2 and §12).
## [br][br]
## [b]What lives here[/b]: [method stop] (the orderly shutdown of the five triggers), [method close_instance]
## (the platform closed the instance), the drain ([method _wind_down], [method _begin_drain],
## [method _drain_stop], [method _finish_stop]), the countdown requested through the console
## ([method _check_shutdown_countdown]) and the maintenance windows of the heartbeat ([method _set_maintenance],
## [method _check_maintenance]).
## [br][br]
## [b]Tick steps[/b]: the countdown and the maintenance run after the NPC step and before the spawns (a
## countdown that ends stops the zone on that tick and the rest of the tick is skipped); the drain is the only
## thing the tick does while the zone is stopping (see [method ZoneServer._physics_process]).
## [br][br]
## [b]Touch this file[/b] to change how and when the server closes. The flush of the report and the closing of
## the logs ([method _finish_stop]) are written in the order the report relies on: the report is built from
## the state kept at stop.
## [br][br]
## It is a plain [RefCounted] owned by the [ZoneServer], which builds it in [code]_init[/code] and passes
## itself in. The state it works on stays reachable through [code]_z[/code]; the state that only this
## subsystem uses lives here. It never runs a step of the tick on its own: [method ZoneServer._physics_process]
## calls it at the point the tick order (documented in its header) requires. Moving code between the
## subsystems is a mechanical change, but moving a call to a different step of the tick is not: the order is
## normative (docs/networking.md, section 3).


## Ticks to wait, after [method stop], for the peers to leave before closing the transport.
const STOP_DRAIN_TICKS: int = 30
## Seconds before the platform maintenance at which a warning is given (docs/platform.md §7.2 and §12).
const MAINTENANCE_NOTICE_SECONDS: Array[int] = [600, 300, 60, 30, 10]
## Text of the default shutdown NOTICE.
const DEFAULT_SHUTDOWN_TEXT: String = "El servidor se está cerrando"
## Remaining seconds at which a shutdown countdown warns the players.
const SHUTDOWN_NOTICE_SECONDS: Array[int] = [60, 30, 10, 5, 4, 3, 2, 1]

var _z: ZoneServer
var _drain_ticks: int = 0
# Ticks of the wait for peers to leave (since the shutdown NOTICE).
var _peer_drain_ticks: int = 0
# §6.1 shutdown: the kick NOTICE goes out when the final saves already have an answer.
var _kick_after_saves: bool = false
# Maintenance announced by the heartbeat: its Unix time (0 = none), its text and the warnings already
# given (seconds of MAINTENANCE_NOTICE_SECONDS).
var _maintenance_at_unix: int = 0
var _maintenance_message: String = ""
var _maintenance_announced: Array[int] = []
# The last maintenance whose time has already arrived: the heartbeat may keep announcing it until the zone stops.
var _maintenance_fired_at_unix: int = 0


func _init(zone: ZoneServer) -> void:
	_z = zone


## Shuts the server down (the orderly shutdown of docs/platform.md §7.2, that of the five triggers): warns
## all clients with a shutdown NOTICE (code [constant NetProtocol.NoticeCode.SHUTDOWN]) with
## [param notice_text] (by default, a standard text), releases the peers in LOADING and cancels those in
## VERIFYING, requests the orderly disconnect of each peer, sends the final save of each body with a lease
## (also those that remain after an in-combat exit) and releases all characters. The report data is
## kept ([method write_report]). It finishes when the peers have left (or after
## [constant STOP_DRAIN_TICKS] ticks) and the platform has answered the saves and has nothing queued or in
## flight (or after [member save_drain_ticks]); [method is_stopped] says when.
func stop(notice_text: String = "") -> void:
	if _z._run_state != ZoneServer._RunState.RUNNING:
		return
	_z._log("Cerrando el servidor de la zona '%s' (tick %d)" % [_z._config.zone_id, _z._tick])
	_z._players_at_stop = _z._zone_sessions.get_player_count()
	# Whatever changed in the fortresses goes out before emptying the world (the instance stays live until the removal).
	if _z._fortress_persistence != null:
		_z._fortress_persistence.flush(_z._tick)
	if _z._transport != null:
		var notice := NetMessages.Notice.new()
		notice.code = NetProtocol.NoticeCode.SHUTDOWN
		notice.text = notice_text if not notice_text.is_empty() else DEFAULT_SHUTDOWN_TEXT
		var bytes: PackedByteArray = notice.encode()
		for peer_id: int in _z._zone_sessions.get_peer_ids():
			var peer: ServerPeer = _z._peers[peer_id]
			if peer.state == ServerPeer.State.LEAVING:
				continue
			_z._zone_sessions._leave_auth_states(peer)
			_z._transport.send(peer_id, NetProtocol.CH_RELIABLE, bytes)
			_z._transport.disconnect_after_flush(peer_id)
			peer.state = ServerPeer.State.LEAVING
		_z._transport.flush()
	_wind_down()
	_begin_drain(false)


## The shutdown of docs/platform.md §6.1, when the platform deems the instance lost, replaced or stopped
## ([param code]; [ServerMain] calls it with [signal instance_closed]): first the final save of everyone and the
## release of those in LOADING, without kicking anyone (the zone stops reading their inputs and giving rewards);
## those in VERIFYING receive REJECT UNAVAILABLE. Once the platform has answered the finals and nothing is
## pending (or after [member save_drain_ticks]), a kick NOTICE "El servidor de la zona se ha reiniciado:
## vuelve a entrar" (the zone server has restarted: rejoin) to everyone and disconnect: whoever rejoins right away
## loads their final save, not the previous one.
func close_instance(code: String) -> void:
	if _z._run_state != ZoneServer._RunState.RUNNING:
		return
	_z._log("La plataforma ha cerrado esta instancia (%s): guardados finales antes de echar a nadie (tick %d)"
			% [code, _z._tick])
	_z._players_at_stop = _z._zone_sessions.get_player_count()
	# The fortresses no longer belong to this instance: no records and no events.
	if _z._fortress_persistence != null:
		_z._fortress_persistence.close()
	if _z._transport != null:
		for peer_id: int in _z._zone_sessions.get_peer_ids():
			var peer: ServerPeer = _z._peers[peer_id]
			match peer.state:
				ServerPeer.State.AUTHENTICATING, ServerPeer.State.VERIFYING:
					_z._zone_sessions._reject(peer, NetProtocol.Result.UNAVAILABLE)
				ServerPeer.State.LOADING:
					_z._zone_sessions._leave_auth_states(peer)
		_z._transport.flush()
	_wind_down()
	_begin_drain(true)


## true when [method stop] or [method close_instance] have finished: the peers have left and the saves
## have an answer (or the wait ran out) and the transport is closed.
func is_stopped() -> bool:
	return _z._run_state == ZoneServer._RunState.STOPPED


## The Unix time of the maintenance announced by the heartbeat (0 = none).
func get_maintenance_at_unix() -> int:
	return _maintenance_at_unix


# Informational NOTICE to all players in the world. Returns how many receive it.
func _broadcast_notice(text: String) -> int:
	if _z._transport == null:
		return 0
	var notice := NetMessages.Notice.new()
	notice.code = NetProtocol.NoticeCode.INFO
	notice.text = text
	var bytes: PackedByteArray = notice.encode()
	for peer: ServerPeer in _z._world_peers:
		_z._transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
	return _z._world_peers.size()


# Countdown of a shutdown requested through the console: warnings at the indicated seconds and, on reaching 0,
# shutdown_requested.
func _check_shutdown_countdown(s: int) -> void:
	if _z._shutdown_tick < 0:
		return
	var remaining: int = _z._shutdown_tick - s
	if remaining <= 0:
		_z._shutdown_tick = -1
		_z._log("Cuenta atrás de cierre cumplida")
		_z.shutdown_requested.emit("cierre pedido desde la consola")
		return
	var rate: int = Engine.physics_ticks_per_second
	@warning_ignore("integer_division")
	var seconds_left: int = remaining / rate
	if remaining % rate == 0 and SHUTDOWN_NOTICE_SECONDS.has(seconds_left):
		_broadcast_notice("El servidor se cerrará en %d s" % seconds_left)


# The maintenance brought by the heartbeat (docs/platform.md §6 and §12): {at_unix, message} or null (none, or
# cancelled). A new at_unix restarts the warnings.
func _set_maintenance(value: Variant) -> void:
	var maintenance: Dictionary = value if value is Dictionary else {}
	if maintenance.is_empty() or not PlatformJson.is_int(maintenance.get("at_unix"), 1, PlatformJson.MAX_SAFE_INT):
		if _maintenance_at_unix > 0:
			_z._log("La plataforma ya no anuncia el mantenimiento")
			if not _maintenance_announced.is_empty():
				_broadcast_notice("Mantenimiento cancelado: el servidor sigue abierto")
		_maintenance_at_unix = 0
		_maintenance_message = ""
		_maintenance_announced.clear()
		return
	var at_unix: int = int(maintenance["at_unix"])
	if at_unix == _maintenance_fired_at_unix:
		return
	_maintenance_message = PlatformJson.text_in(maintenance, "message").left(200)
	if at_unix == _maintenance_at_unix:
		return
	_maintenance_at_unix = at_unix
	_maintenance_announced.clear()
	_z._log("La plataforma anuncia mantenimiento a las %s UTC (dentro de %d s)" % [
			Time.get_datetime_string_from_unix_time(at_unix, true), at_unix - _z._platform.now_unix()])


# Maintenance warnings at 10, 5 and 1 min, at 30 s and at 10 s (those already past when announced are
# merged into one warning with what remains) and, at its time, the orderly shutdown (shutdown_requested), like the rest
# of the triggers. The time is the platform's (ZonePlatform.now_unix).
func _check_maintenance() -> void:
	if _maintenance_at_unix <= 0 or _z._platform == null:
		return
	var remaining: int = _maintenance_at_unix - _z._platform.now_unix()
	if remaining <= 0:
		_maintenance_fired_at_unix = _maintenance_at_unix
		_maintenance_at_unix = 0
		_maintenance_announced.clear()
		_z._log("Hora del mantenimiento de la plataforma: cierre ordenado")
		_z.shutdown_requested.emit("mantenimiento de la plataforma")
		return
	var due: bool = false
	for seconds: int in MAINTENANCE_NOTICE_SECONDS:
		if remaining <= seconds and not _maintenance_announced.has(seconds):
			_maintenance_announced.append(seconds)
			due = true
	if due:
		_broadcast_notice(_z.maintenance_notice_text(remaining, _maintenance_message))


# What stop() and close_instance() have in common: closes the report records, sends the final save of each body with a
# lease (with the SHUTDOWN reason) before emptying the world, closes the logs and asks the platform to
# push out whatever is pending (begin_flush).
func _wind_down() -> void:
	for record: ZoneServer._PlayerRecord in _z._player_by_net.values():
		record.close(_z._tick)
	_z._war_fortresses_at_stop = _z._zone_report._fortress_entries()
	if _z._saver != null:
		for net_id: int in _z._saver.tracked_net_ids():
			_z._saver.finish(net_id, CharacterSaver.Reason.SHUTDOWN)
	_z._zone_bodies._clear_players()
	_z._pending_ready.clear()
	_z._leaving.clear()
	_z._fake_leaving.clear()
	_z._fake_leaving_quietly.clear()
	_maintenance_at_unix = 0
	_maintenance_announced.clear()
	_z._shutdown_tick = -1
	_z._zone_report._sync_byte_counters()
	_z._close_state_log()
	_z._close_combat_log()
	_z._close_battle_log()
	if _z._console != null:
		_z._console.stop()
	_z._metrics.unregister_monitors()
	if _z._platform != null:
		_z._platform.begin_flush()


# Moves to STOPPING, or finishes right away if there are no peers and nothing pending on the platform. With [param kick_after_saves]
# (the §6.1 shutdown) the peers receive their kick NOTICE when the saves already have an answer.
func _begin_drain(kick_after_saves: bool) -> void:
	_drain_ticks = 0
	_peer_drain_ticks = 0
	_kick_after_saves = kick_after_saves
	if (_z._transport == null or _z._peers.is_empty()) and _saves_settled():
		_kick_after_saves = false
		_finish_stop()
	else:
		_z._run_state = ZoneServer._RunState.STOPPING


# true if the saves all have their definitive answer and the platform has nothing queued or in flight.
func _saves_settled() -> bool:
	return (_z._saver == null or _z._saver.pending_count() == 0) and (_z._platform == null or _z._platform.is_flushed())


# After stop() or close_instance(): keeps polling the network and the platform (the answers to the final saves and
# the claims that arrive late) until the saves are answered (or save_drain_ticks pass) and the
# peers have left (or STOP_DRAIN_TICKS pass since their NOTICE).
func _drain_stop() -> void:
	_drain_ticks += 1
	if _z._transport != null:
		_z._transport.poll(_z._tick + _drain_ticks)
	_z._zone_sessions._poll_platform()
	var saves_done: bool = _saves_settled() or _drain_ticks >= _z.save_drain_ticks
	if _kick_after_saves:
		if not saves_done:
			return
		_kick_after_saves = false
		_kick_everyone(ZoneServer.INSTANCE_CLOSED_TEXT)
	else:
		_peer_drain_ticks += 1
	if _z._transport != null:
		_z._transport.flush()
	if saves_done and (_z._peers.is_empty() or _peer_drain_ticks >= STOP_DRAIN_TICKS):
		if not _saves_settled():
			push_warning("[Eldmark] Cierre de la zona: la plataforma no ha contestado a tiempo (%d guardados sin respuesta)"
					% (_z._saver.pending_count() if _z._saver != null else 0))
		_finish_stop()


# Kick NOTICE with [param text] and orderly disconnect of all remaining peers (the §6.1 shutdown).
func _kick_everyone(text: String) -> void:
	if _z._transport == null:
		return
	for peer_id: int in _z._zone_sessions.get_peer_ids():
		var peer: ServerPeer = _z._peers[peer_id]
		if peer.state != ServerPeer.State.LEAVING:
			_z._zone_sessions._kick(peer, "la plataforma ha cerrado la instancia", false, text)
	_z._transport.flush()


func _finish_stop() -> void:
	_z._peers.clear()
	_z._disconnect_transport()
	if _z._transport != null and is_instance_valid(_z._transport):
		_z._zone_report._sync_byte_counters()
		_z._transport.close()
	_z._run_state = ZoneServer._RunState.STOPPED
	_z.set_physics_process(false)
