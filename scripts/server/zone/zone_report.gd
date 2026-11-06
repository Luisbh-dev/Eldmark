class_name ZoneReport
extends RefCounted
## What the zone reports about itself: the metrics line in the log and the JSON report written on exit
## (docs/networking.md §14 and §16).
## [br][br]
## [b]What lives here[/b]: [method _build_report] (the whole document, with the [code]build[/code] line),
## the sections it is made of ([method _combat_report], [method _npc_report], [method _war_report],
## [method _fortress_entries]), the metrics line ([method _log_metrics], every
## [constant ZoneServer.METRICS_LOG_TICKS] ticks) and the wire counters it reads from the transport
## ([method _sync_byte_counters]).
## [br][br]
## [b]Tick step[/b]: the last one, "metrics". It only reads state: it never changes the simulation, so the state
## log of a seeded run is the same with or without it.
## [br][br]
## [b]Touch this file[/b] to add a counter to the report or a field to the log line. The counters themselves
## stay where they are incremented; the report only reads them.
## [br][br]
## It is a plain [RefCounted] owned by the [ZoneServer], which builds it in [code]_init[/code] and passes
## itself in. The state it works on stays reachable through [code]_z[/code]; the state that only this
## subsystem uses lives here. It never runs a step of the tick on its own: [method ZoneServer._physics_process]
## calls it at the point the tick order (documented in its header) requires. Moving code between the
## subsystems is a mechanical change, but moving a call to a different step of the tick is not: the order is
## normative (docs/networking.md, section 3).


var _z: ZoneServer
var _synced_wire_in: int = 0
var _synced_wire_out: int = 0
var _log_last_wire_out: int = 0
var _log_last_wire_in: int = 0


func _init(zone: ZoneServer) -> void:
	_z = zone


## Writes the JSON report of the run to [param path] (missing directories are created).
## Keys:
## [codeblock]
## version, zone, port, ticks, tick_rate, sim_hash
## closed    false while the server is running (periodic report), true after stop()
## players   {current, at_stop, fake, peak, joined_total, left_total, archived}
## inputs    {consumed, substituted, late, too_early, substituted_percent}  (network players only)
## bytes     {wire_in, wire_out, app_in, app_out}  (cumulative; see NetTransport.get_byte_counters)
## strikes   {total, by_reason, kicks_total}
## kicks     [{tick, peer_id, net_id, name, reason}]  (the last max_logged_kicks)
## rejects   {reason: times}
## physics_errors, teleports, respawns
## simulate  {calls, total_us, avg_us, max_us}        µs of each PlayerCharacter.simulate()
## snapshots {sent, bytes, avg_bytes, max_bytes, build_us, avg_build_us}   build_us: building each
##           snapshot and queuing it (without the interest computation or the real ENet send)
## metrics   ServerMetrics.summary() (p50/p99/max of each section in µs, KB/s, players...)
## npcs      NpcSpawnerSystem.get_report(): posts, living NPCs, spawns, deaths, telegraphed heavy attacks,
##           attack tokens, computed routes...
## player_list  one record per player who has passed through the server (also those who left),
##           the last max_logged_players; of the earlier ones only the totals remain
##           (players.archived counts the summarized records)
## [/codeblock]
func write_report(path: String) -> Error:
	if path.is_empty():
		return ERR_INVALID_PARAMETER
	var directory: String = path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		var made: Error = DirAccess.make_dir_recursive_absolute(directory)
		if made != OK:
			return made
	# Written to a temporary file and renamed into place, so a server killed mid-write (SIGKILL,
	# docker stop) never leaves an empty or truncated report: readers see the old one or the new one.
	var temp_path: String = path + ".tmp"
	var file: FileAccess = FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(_build_report(), "\t"))
	file.close()
	var renamed: Error = DirAccess.rename_absolute(temp_path, path)
	if renamed != OK and FileAccess.file_exists(path):
		# Some platforms refuse to rename onto an existing file: replace it explicitly.
		DirAccess.remove_absolute(path)
		renamed = DirAccess.rename_absolute(temp_path, path)
	return renamed


# Accumulates the transport's ENet bytes into the metrics.
func _sync_byte_counters() -> void:
	if _z._transport == null or not is_instance_valid(_z._transport):
		return
	var counters: Dictionary = _z._transport.get_byte_counters()
	var wire_in: int = counters.get("wire_in", 0)
	var wire_out: int = counters.get("wire_out", 0)
	_z._metrics.add_counter(ServerMetrics.COUNTER_BYTES_IN, wire_in - _synced_wire_in)
	_z._metrics.add_counter(ServerMetrics.COUNTER_BYTES_OUT, wire_out - _synced_wire_out)
	_synced_wire_in = wire_in
	_synced_wire_out = wire_out


# Metrics line every 10 s: tick duration, players, substituted inputs, bandwidth and, at the end, the NPCs
# simulated at that moment (the war ones and the dummies; GUE-16: the load with NPCs follows them throughout the
# battle).
func _log_metrics(s: int) -> void:
	_sync_byte_counters()
	var now_usec: int = Time.get_ticks_usec()
	var seconds: float = maxf(float(now_usec - _z._log_last_usec) / 1000000.0, 0.001)
	_z._log_last_usec = now_usec
	var kb_out: float = float(_synced_wire_out - _log_last_wire_out) / 1024.0 / seconds
	var kb_in: float = float(_synced_wire_in - _log_last_wire_in) / 1024.0 / seconds
	_log_last_wire_out = _synced_wire_out
	_log_last_wire_in = _synced_wire_in
	var sections := PackedStringArray()
	for section: StringName in ZoneServer.LOGGED_SECTIONS:
		sections.append("%s %d" % [section, _z._metrics.get_percentile_us(section, 0.99)])
	_z._log("Métricas (tick %d): %d jugadores, tick p50 %d µs / p99 %d µs / máx %d µs "
			% [s, _z._metrics.get_counter(ServerMetrics.COUNTER_PLAYERS),
			_z._metrics.get_percentile_us(ServerMetrics.SECTION_TICK, 0.5),
			_z._metrics.get_percentile_us(ServerMetrics.SECTION_TICK, 0.99),
			_z._metrics.get_max_us(ServerMetrics.SECTION_TICK)]
			+ "(p99 por sección: %s), entradas sustituidas %.2f %%, subida %.1f KB/s, "
			% [", ".join(sections), _z._metrics.get_substituted_percent(), kb_out]
			+ "bajada %.1f KB/s, %d PNJ" % [kb_in, _z._npcs.size()])


func _build_report() -> Dictionary:
	_sync_byte_counters()
	var network_bytes: Dictionary = {}
	if _z._transport != null and is_instance_valid(_z._transport):
		network_bytes = _z._transport.get_byte_counters()
	var player_list: Array[Dictionary] = []
	var inputs: int = _z._archived_inputs
	var substituted: int = _z._archived_substituted
	var late: int = _z._archived_late
	var too_early: int = _z._archived_too_early
	for record: ZoneServer._PlayerRecord in _z._player_log:
		player_list.append(record.to_dictionary())
		if not record.is_fake:
			inputs += record.inputs
			substituted += record.substituted
			late += record.late
			too_early += record.too_early
	var substituted_percent: float = 0.0
	if inputs > 0:
		substituted_percent = 100.0 * float(substituted) / float(inputs)
	return {
		"version": 1,
		"build": BuildInfo.build_id(),
		"zone": _z._config.zone_id if _z._config != null else "",
		"port": _z._config.port if _z._config != null else 0,
		"ticks": _z._tick,
		"tick_rate": Engine.physics_ticks_per_second,
		"sim_hash": _z._sim_hash,
		# Whether the port was opened over DTLS (docs/platform.md §10.2; the transport is already closed in the final report).
		"dtls": _z._config != null and _z._config.dtls != null and _z._transport != null,
		"closed": _z._run_state == ZoneServer._RunState.STOPPING or _z._run_state == ZoneServer._RunState.STOPPED,
		"players": {
			"current": _z._zone_sessions.get_player_count(),
			"at_stop": _z._players_at_stop,
			"fake": _count_fakes_in_log(),
			"peak": _z._peak_players,
			"joined_total": _z._joined_total,
			"left_total": _z._left_total,
			"archived": _z._archived_players,
		},
		"inputs": {
			"consumed": inputs,
			"substituted": substituted,
			"late": late,
			"too_early": too_early,
			"substituted_percent": substituted_percent,
		},
		"bytes": network_bytes,
		"strikes": {"total": _z._strikes_total, "by_reason": _z._strike_reasons,
				"kicks_total": _z._kicks_total},
		"kicks": _z._kicks,
		"rejects": _z._rejects,
		"physics_errors": _z._physics_errors,
		"teleports": _z._teleports,
		"respawns": _z._respawns + _combat_stat(&"respawns") + _combat_stat(&"voids"),
		"combat": _combat_report(),
		"war": _war_report(),
		"npcs": _npc_report(),
		"social": _z._social.get_stats() if _z._social != null else {},
		"moderation": _z._moderation.get_stats() if _z._moderation != null else {},
		"saves": _z._saver.get_stats() if _z._saver != null else {},
		"simulate": {
			"calls": _z._simulate_calls,
			"total_us": _z._simulate_usec_total,
			"avg_us": float(_z._simulate_usec_total) / float(_z._simulate_calls) \
					if _z._simulate_calls > 0 else 0.0,
			"max_us": _z._simulate_usec_max,
		},
		"snapshots": {
			"sent": _z._snapshots_sent,
			"bytes": _z._snapshot_bytes_total,
			"avg_bytes": float(_z._snapshot_bytes_total) / float(_z._snapshots_sent) \
					if _z._snapshots_sent > 0 else 0.0,
			"max_bytes": _z._snapshot_bytes_max,
			"build_us": _z._snapshot_build_usec,
			"avg_build_us": float(_z._snapshot_build_usec) / float(_z._snapshots_sent) \
					if _z._snapshots_sent > 0 else 0.0,
		},
		"metrics": _z._metrics.summary(),
		"player_list": player_list,
	}


func _combat_stat(stat: StringName) -> int:
	return _z._combat.stats.get(stat, 0) if _z._combat != null else 0


# Combat summary for the report: the director's counters, the events sent and the
# suspicion score per peer (only the suspicious ones).
func _combat_report() -> Dictionary:
	var suspicious: Array[Dictionary] = []
	for record: ZoneServer._PlayerRecord in _z._player_log:
		record.refresh()
		if record.suspicion > 0:
			suspicious.append({"net_id": record.net_id, "name": record.display_name,
					"suspicion": record.suspicion, "rewind_rejects": record.rewind_rejects})
	var report: Dictionary = {}
	if _z._combat != null:
		for stat: StringName in _z._combat.stats:
			report[String(stat)] = _z._combat.stats[stat]
		# Status effects (docs/abilities.md, 4.3): applied, removed, pulses and health healed.
		for stat: StringName in _z._combat.status.stats:
			report[String(stat)] = _z._combat.status.stats[stat]
		# Projectiles (docs/abilities.md, 4.4): shots, impacts, kills, culling and peak of living ones.
		for stat: StringName in _z._combat.projectiles.stats:
			report[String(stat)] = _z._combat.projectiles.stats[stat]
		report["projectiles_live"] = _z._combat.projectiles.live_count()
		# The knocked-down state (docs/abilities.md, 4.5): knockdowns, revives, finishers, bleed-outs and interactions.
		for stat: StringName in _z._combat.downed.stats:
			report[String(stat)] = _z._combat.downed.stats[stat]
		report["downed_now"] = _z._combat.downed.downed_count()
	report["projectile_messages_sent"] = _z._projectile_messages_sent
	report["projectile_bytes_sent"] = _z._projectile_bytes_sent
	report["events_sent"] = _z._events_sent
	report["event_bytes_sent"] = _z._event_bytes_sent
	report["dummies"] = _z._zone_bodies.get_dummy_count() if _z._combat != null else 0
	report["dummies_created"] = _z._dummies_created
	report["suspicious"] = suspicious
	return report


# NPC summary for the report: what the spawner system has and the heavy attack notices.
func _npc_report() -> Dictionary:
	var report: Dictionary = _z._npc_system.get_report() if _z._npc_system != null else {}
	report["npcs_now"] = _z._npcs.size()
	report["telegraphs"] = _z._telegraphs_sent
	return report


# War summary for the report: the state of each fortress, the scoreboard, the in-combat exits and the
# uses of /atascado (unstuck).
func _war_report() -> Dictionary:
	# After stop() the controller no longer has fortresses (they are freed with the players): the final report
	# carries their state at the moment of shutdown.
	var fortresses: Array[Dictionary] = _fortress_entries()
	if fortresses.is_empty():
		fortresses = _z._war_fortresses_at_stop
	return {
		"fortresses": fortresses,
		"persistence": _z._fortress_persistence.get_stats() if _z._fortress_persistence != null else {},
		"object_states_sent": _z._object_states_sent,
		"scoreboards_sent": _z._scoreboards_sent,
		"lingering_total": _z._lingering_total,
		"lingering_now": _z._lingering.size(),
		"unstuck": {
			"uses": _z._unstuck_uses,
			"completed": _z._unstuck.completed_count,
			"interrupted": _z._unstuck.interrupted_count,
			"log": _z._unstuck_log,
		},
	}


# The state of each live fortress for the report.
func _fortress_entries() -> Array[Dictionary]:
	var fortresses: Array[Dictionary] = []
	if _z._fortresses == null:
		return fortresses
	for fortress_id: StringName in _z._fortresses.get_fortress_ids():
		var state: FortressState = _z._fortresses.get_fortress_state(fortress_id)
		fortresses.append({
			"id": String(fortress_id), "owner": state.owner, "phase": state.phase,
			"gate_health": state.gate_health, "gate_max": state.gate_max,
			"captain_alive": state.captain_alive, "guards_alive": state.guards_alive,
		})
	return fortresses


func _count_fakes_in_log() -> int:
	var count: int = _z._archived_fakes
	for record: ZoneServer._PlayerRecord in _z._player_log:
		if record.is_fake:
			count += 1
	return count
