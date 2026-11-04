class_name FortressPersistence
extends RefCounted
## Persistent war in the zone (docs/platform.md §8, GUE-19): the record of each fortress on the
## platform ([code]fortresses.record[/code], schema 1) and the history of its events. It only exists
## with [code]--platform[/code]; it lives in [code]scripts/server/war/[/code] because it reads the
## platform clock ([method ZonePlatform.now_unix]), and [code]scripts/shared[/code] does not read it.
## [codeblock]
## {"schema": 1, "owner": 1, "phase": "consolidating", "phase_ends_at_unix": 1800000120,
##  "captain_alive": false, "captain_respawn_at_unix": null, "gate_health": 2600,
##  "capture_realm": 0, "capture_progress": 0, "last_reset_at_unix": 1799999000}
## [/codeblock]
## [b]Ticks and Unix time[/b] ([method unix_of], [method tick_until], [method tick_since]): a tick
## [code]t[/code] is written as [code]now_unix + ceili((t − tick) / 60.0)[/code]; on load, a deadline
## comes back as [code]tick + max(0, at − now_unix) · 60[/code] and the last reset, which is in the
## past, as [code]tick − max(0, now_unix − at) · 60[/code] (restarting the process does not restart
## the 30 min cycle). What has no deadline goes as null: [code]phase_ends_at_unix[/code] is the end
## of the consolidation or the captain's return in VULNERABLE, and
## [code]captain_respawn_at_unix[/code], that return.
## [br][br]
## [b]On startup[/b] ([method load_records], inside [method ZoneServer.start] and before opening the
## port): what the GET of [method ZonePlatform.start] brought is applied with
## [method FortressController.restore_state]. With no record (first startup), the initial state with
## no warning, and it is written as soon as the instance is live; with another [code]schema[/code]
## or one that is invalid, the initial state with a warning. CONSOLIDATING keeps owner and deadline;
## VULNERABLE, the captain's deadline; CAPTURING comes back with its capturer and progress, the
## circle empty and decaying (the machine of docs/fortress.md §1.5 only has progress in CAPTURING: if
## nobody comes back, at 0 it goes to VULNERABLE). Guards are not saved: the spawner replaces them.
## A damaged gate is repaired 5 min after startup.
## [br][br]
## [b]Saving[/b] ([method step], after the fortress step): on every owner, phase or cycle change (a
## reset) and, if something else changed (gate health, progress, captain deadline), every 60 s
## ([constant SAVE_INTERVAL_TICKS]); the orderly shutdown writes whatever remains
## ([method flush]). It only writes the [code]live[/code] instance ([method ZonePlatform.is_live]):
## an earlier change goes out once it becomes live. [method ZonePlatform.put_fortress] keeps one
## in-flight request per fortress with [code]expected_version[/code] and resends after
## [code]version_conflict[/code]; the responses arrive here as [code]fortress[/code] events.
## [br][br]
## [b]History[/b] ([method on_war_event]): notices 3 (capture started), 6 (captured) and 7 (reset) go
## to the [code]war[/code] batch ([code]{key, fortress_id, event, realm, at_unix}[/code]); the
## [code]key[/code] is set by [method ZonePlatform.enqueue_batch] and a resent batch duplicates
## nothing.

## Schema of the record.
const SCHEMA: int = 1
## How often (in ticks) a fortress is written when only minor things have changed (60 s).
const SAVE_INTERVAL_TICKS: int = 3600
## Name of each [enum FortressState.Phase] in the record.
const PHASE_NAMES: PackedStringArray = ["garrisoned", "vulnerable", "capturing", "consolidating"]
## War notices that go to the history (fortress_events).
const PERSISTED_WAR_EVENTS: Array[int] = [WarEvents.CAPTURE_STARTED, WarEvents.FORT_CAPTURED, WarEvents.FORT_RESET]
## Class of the history batch ([method ZonePlatform.enqueue_batch]).
const WAR_BATCH: StringName = &"war"
## The largest Unix time the platform accepts (9999-12-31).
const MAX_UNIX: int = 253402300799

## Zone log (a [Callable] with a text); without it, print. Warnings also go through [method push_warning].
var log_sink: Callable = Callable()

var _platform: ZonePlatform = null
var _controller: FortressController = null
var _closed: bool = false
var _tracked: Dictionary[StringName, _Tracked] = {}
var _stats: Dictionary[StringName, int] = {
	&"loaded": 0, &"initial": 0, &"discarded": 0, &"puts": 0, &"put_ok": 0, &"put_conflicts": 0,
	&"put_failed": 0, &"war_events": 0,
}


## What was written of a fortress: the part that goes out immediately if it changes (owner, phase and
## cycle) and the one that goes out every 60 s, in ticks (Unix time moves with the clock and does not
## say whether anything changed).
class _Tracked:
	extends RefCounted
	var major: Array = []
	var minor: Array = []
	var last_put_tick: int = 0
	## Write as soon as the instance is live (first startup, no record).
	var pending: bool = false


## A record read: the state, the end of a loaded consolidation and, if it is invalid, the reason.
class Loaded:
	extends RefCounted
	var state: FortressState = null
	var consolidation_ends_tick: int = FortressState.NO_TICK
	## Empty if the record is valid; otherwise, why (the state is then the initial one).
	var error: String = ""


func _init(platform: ZonePlatform, controller: FortressController) -> void:
	_platform = platform
	_controller = controller


# --- Conversion ---------------------------------------------------------------------------------

## The Unix time of tick [param t] seen from [param tick] with clock [param now_unix]:
## [code]now_unix + ceili((t − tick) / 60.0)[/code] (a deadline never goes out before its tick).
static func unix_of(t: int, tick: int, now_unix: int) -> int:
	return now_unix + ceili(float(t - tick) / float(CombatCatalog.TICK_RATE))


## The tick of a future deadline [param at_unix]: [code]tick + max(0, at − now_unix) · 60[/code].
static func tick_until(at_unix: int, tick: int, now_unix: int) -> int:
	return tick + maxi(0, at_unix - now_unix) * CombatCatalog.TICK_RATE


## The tick of a past instant [param at_unix]: [code]tick − max(0, now_unix − at) · 60[/code].
static func tick_since(at_unix: int, tick: int, now_unix: int) -> int:
	return tick - maxi(0, now_unix - at_unix) * CombatCatalog.TICK_RATE


## The record (schema 1) of [param state] at tick [param tick] with clock [param now_unix].
## [param consolidation_ends_tick] is the end of the consolidation if the controller carries it
## ([method FortressController.get_consolidation_end_tick]); without it, the phase start plus its
## duration.
static func to_record(state: FortressState, def: FortressDefinition, tick: int, now_unix: int,
		consolidation_ends_tick: int = FortressState.NO_TICK) -> Dictionary:
	var record: Dictionary = {
		"schema": SCHEMA, "owner": state.owner, "phase": PHASE_NAMES[state.phase], "phase_ends_at_unix": null,
		"captain_alive": state.captain_alive, "captain_respawn_at_unix": null, "gate_health": state.gate_health,
		"capture_realm": 0, "capture_progress": 0,
		"last_reset_at_unix": clampi(unix_of(state.last_reset_tick, tick, now_unix), 0, MAX_UNIX),
	}
	match state.phase:
		FortressState.Phase.CONSOLIDATING:
			var ends: int = consolidation_ends_tick if consolidation_ends_tick != FortressState.NO_TICK \
					else state.phase_tick + def.consolidation_ticks()
			record["phase_ends_at_unix"] = clampi(unix_of(ends, tick, now_unix), 0, MAX_UNIX)
		FortressState.Phase.VULNERABLE:
			if state.captain_respawn_tick != FortressState.NO_TICK:
				var back: int = clampi(unix_of(state.captain_respawn_tick, tick, now_unix), 0, MAX_UNIX)
				record["phase_ends_at_unix"] = back
				record["captain_respawn_at_unix"] = back
		FortressState.Phase.CAPTURING:
			record["capture_realm"] = state.capture_realm
			record["capture_progress"] = state.progress_at(tick)
	return record


## The state of [param record] (what the GET brings, already read as JSON) for [param def] at tick
## [param tick] with clock [param now_unix]. If it is invalid (not an object, another
## [code]schema[/code], a field that is missing or does not match), [member Loaded.error] says why
## and the state is the initial one.
static func from_record(record: Variant, def: FortressDefinition, tick: int, now_unix: int) -> Loaded:
	var loaded := Loaded.new()
	loaded.state = FortressState.initial(def, tick)
	if not record is Dictionary:
		loaded.error = "no es un objeto"
		return loaded
	var data: Dictionary = record
	var schema: int = PlatformJson.int_in(data, "schema", 0, PlatformJson.MAX_SAFE_INT, -1)
	if schema != SCHEMA:
		loaded.error = "esquema %s" % (str(schema) if schema >= 0 else "desconocido")
		return loaded
	var owner: int = PlatformJson.int_in(data, "owner", 0, 3, -1)
	var phase: int = PHASE_NAMES.find(PlatformJson.text_in(data, "phase"))
	var gate_health: int = PlatformJson.int_in(data, "gate_health", 0, PlatformJson.MAX_SAFE_INT, -1)
	var capture_realm: int = PlatformJson.int_in(data, "capture_realm", 0, 3, -1)
	var capture_progress: int = PlatformJson.int_in(data, "capture_progress", 0, PlatformJson.MAX_SAFE_INT, -1)
	var errors := PackedStringArray()
	if owner < 0:
		errors.append("owner")
	if phase < 0:
		errors.append("phase")
	if gate_health < 0:
		errors.append("gate_health")
	if capture_realm < 0:
		errors.append("capture_realm")
	if capture_progress < 0:
		errors.append("capture_progress")
	if not data.get("captain_alive") is bool:
		errors.append("captain_alive")
	for key: String in ["phase_ends_at_unix", "captain_respawn_at_unix", "last_reset_at_unix"]:
		if not _is_optional_unix(data.get(key)):
			errors.append(key)
	if errors.is_empty():
		if phase == FortressState.Phase.CONSOLIDATING and owner == RealmCatalog.NEUTRAL_CODE:
			errors.append("consolidating sin dueño")
		if phase == FortressState.Phase.CAPTURING and (capture_realm == RealmCatalog.NEUTRAL_CODE
				or capture_realm == owner):
			errors.append("capturing sin captor")
	if not errors.is_empty():
		loaded.error = "no valen: %s" % ", ".join(errors)
		return loaded
	var state: FortressState = loaded.state
	state.owner = owner
	state.gate_health = mini(gate_health, state.gate_max)
	if state.gate_health < state.gate_max:
		# The time of the last hit is not saved: the repair counts from startup.
		state.gate_last_damage_tick = tick
	var last_reset: Variant = data.get("last_reset_at_unix")
	if last_reset != null:
		state.last_reset_tick = tick_since(int(last_reset), tick, now_unix)
	var phase_ends: Variant = data.get("phase_ends_at_unix")
	var captain_back: Variant = data.get("captain_respawn_at_unix")
	match phase:
		FortressState.Phase.VULNERABLE:
			state.phase = FortressState.Phase.VULNERABLE
			state.captain_alive = false
			var back: Variant = captain_back if captain_back != null else phase_ends
			state.captain_respawn_tick = tick_until(int(back), tick, now_unix) if back != null \
					else tick + def.captain_respawn_ticks()
		FortressState.Phase.CAPTURING:
			# With its capturer and progress; the circle is empty, so it decays (docs/fortress.md §1.5).
			state.phase = FortressState.Phase.CAPTURING
			state.captain_alive = false
			state.capture_realm = capture_realm
			state.capture_start_tick = tick
			state.capture_rate = 0
			state.capture_progress_at_start = mini(capture_progress, state.progress_max)
			state.empty_since_tick = tick
		FortressState.Phase.CONSOLIDATING:
			state.phase = FortressState.Phase.CONSOLIDATING
			state.captain_alive = false
			loaded.consolidation_ends_tick = tick_until(int(phase_ends), tick, now_unix) if phase_ends != null \
					else tick + def.consolidation_ticks()
			# The start does not go below the load tick (OBJECT_STATE carries no negative ticks); the end is
			# carried by the controller (FortressController.restore_state).
			state.phase_tick = maxi(tick, loaded.consolidation_ends_tick - def.consolidation_ticks())
	return loaded


# null or an integer Unix time from 0 to MAX_UNIX.
static func _is_optional_unix(value: Variant) -> bool:
	return value == null or PlatformJson.is_int(value, 0, MAX_UNIX)


# --- Startup ------------------------------------------------------------------------------------

## Applies [param records] (what the startup GET brought, [method ZonePlatform.fortress_records]:
## [code]{fortress_id, record, version}[/code]) at tick [param tick], before opening the port.
func load_records(records: Array[Dictionary], tick: int) -> void:
	var by_id: Dictionary[StringName, Dictionary] = {}
	for entry: Dictionary in records:
		by_id[StringName(entry.get("fortress_id", &""))] = entry
	var now: int = _platform.now_unix()
	for fortress_id: StringName in _controller.get_fortress_ids():
		var tracked := _Tracked.new()
		_tracked[fortress_id] = tracked
		if not by_id.has(fortress_id):
			# First startup: the initial state, with no warning; it is written as soon as the instance is live.
			tracked.pending = true
			_stats[&"initial"] += 1
			_log("Fortaleza %s sin registro en la plataforma: estado inicial" % fortress_id)
		else:
			var entry: Dictionary = by_id[fortress_id]
			var loaded: Loaded = from_record(entry.get("record"), _controller.get_definition(fortress_id), tick,
					now)
			if not loaded.error.is_empty():
				_stats[&"discarded"] += 1
				_warn("Aviso: el registro de la fortaleza %s (versión %d) no vale (%s): estado inicial"
						% [fortress_id, int(entry.get("version", 0)), loaded.error])
			else:
				_controller.restore_state(fortress_id, loaded.state, loaded.consolidation_ends_tick, tick)
				_stats[&"loaded"] += 1
				_log("Fortaleza %s cargada de la plataforma (versión %d): %s" % [fortress_id,
						int(entry.get("version", 0)), describe(_controller, fortress_id, tick)])
		_remember(fortress_id, tick)
	for fortress_id: StringName in by_id:
		if not _tracked.has(fortress_id):
			_log("La plataforma tiene un registro de la fortaleza %s, que esta zona no tiene" % fortress_id)


## A line with the state of [param fortress_id] for the log: owner, phase and the running deadline.
static func describe(controller: FortressController, fortress_id: StringName, tick: int) -> String:
	var state: FortressState = controller.get_fortress_state(fortress_id)
	if state == null:
		return "sin estado"
	var text: String = "dueño %s, fase %s" % [WarEvents.realm_label(state.owner), PHASE_NAMES[state.phase]]
	match state.phase:
		FortressState.Phase.CONSOLIDATING:
			text += "; consolida %d s más" % _seconds_until(controller.get_consolidation_end_tick(fortress_id), tick)
		FortressState.Phase.VULNERABLE:
			text += "; el capitán reaparece en %d s" % _seconds_until(state.captain_respawn_tick, tick)
		FortressState.Phase.CAPTURING:
			text += "; captura de %s al %d/%d" % [WarEvents.realm_label(state.capture_realm),
					state.progress_at(tick), state.progress_max]
	if state.gate_health < state.gate_max:
		text += "; puerta %d/%d" % [state.gate_health, state.gate_max]
	return text


static func _seconds_until(t: int, tick: int) -> int:
	return ceili(float(maxi(t - tick, 0)) / float(CombatCatalog.TICK_RATE))


# --- Saving -------------------------------------------------------------------------------------

## After the fortress step of tick [param s]: writes the one that changed owner, phase or cycle and,
## every 60 s, the one that changed in anything else. Nothing until the instance is live nor after
## [method close].
func step(s: int) -> void:
	if _closed or not _platform.is_live():
		return
	for fortress_id: StringName in _tracked:
		var tracked: _Tracked = _tracked[fortress_id]
		var state: FortressState = _controller.get_fortress_state(fortress_id)
		if state == null:
			continue
		if tracked.pending or _major(state) != tracked.major:
			_put(fortress_id, s)
		elif s - tracked.last_put_tick >= SAVE_INTERVAL_TICKS and _minor(fortress_id, state, s) != tracked.minor:
			_put(fortress_id, s)


## The orderly shutdown ([method ZoneServer.stop]): immediately writes every fortress with anything
## unwritten. Nothing if the instance is not live or has already been closed.
func flush(s: int) -> void:
	if _closed or not _platform.is_live():
		return
	for fortress_id: StringName in _tracked:
		var tracked: _Tracked = _tracked[fortress_id]
		var state: FortressState = _controller.get_fortress_state(fortress_id)
		if state == null:
			continue
		if tracked.pending or _major(state) != tracked.major or _minor(fortress_id, state, s) != tracked.minor:
			_put(fortress_id, s)


## The platform has closed the instance (docs/platform.md §6.1): it no longer writes records or
## events (the one in charge now is another).
func close() -> void:
	_closed = true


func _put(fortress_id: StringName, s: int) -> void:
	var state: FortressState = _controller.get_fortress_state(fortress_id)
	var record: Dictionary = to_record(state, _controller.get_definition(fortress_id), s, _platform.now_unix(),
			_controller.get_consolidation_end_tick(fortress_id))
	_platform.put_fortress(fortress_id, record)
	_remember(fortress_id, s)
	_tracked[fortress_id].pending = false
	_stats[&"puts"] += 1


func _remember(fortress_id: StringName, s: int) -> void:
	var tracked: _Tracked = _tracked[fortress_id]
	var state: FortressState = _controller.get_fortress_state(fortress_id)
	tracked.major = _major(state)
	tracked.minor = _minor(fortress_id, state, s)
	tracked.last_put_tick = s


# What goes out immediately if it changes: owner, phase and cycle (the phase start and the last reset).
static func _major(state: FortressState) -> Array:
	return [state.owner, state.phase, state.phase_tick, state.last_reset_tick]


# What goes out every 60 s if it changes: the gate, the captain, the capture and the end of the
# consolidation.
func _minor(fortress_id: StringName, state: FortressState, s: int) -> Array:
	return [state.gate_health, state.captain_alive, state.captain_respawn_tick, state.capture_realm,
			state.progress_at(s) if state.phase == FortressState.Phase.CAPTURING else 0,
			_controller.get_consolidation_end_tick(fortress_id)]


# --- Responses and events -----------------------------------------------------------------------

## The response to a fortress PUT ([code]fortress[/code] event, docs/platform.md §14.3). The version
## and the resend after [code]version_conflict[/code] are handled by [ZonePlatform]; here they are
## counted and what is invalid is logged (a 403 is a fortress of another zone). Returns true if it
## was its own.
func on_platform_event(event: PlatformEvent) -> bool:
	if event.kind != PlatformEvent.KIND_FORTRESS:
		return false
	var context: Dictionary = event.context if event.context is Dictionary else {}
	var fortress_id: StringName = context.get("fortress_id", &"")
	if event.is_success():
		_stats[&"put_ok"] += 1
	elif event.status == 409 and event.error_code == "version_conflict":
		_stats[&"put_conflicts"] += 1
		var version: int = PlatformJson.int_in(event.error_dict(), "version", 0, PlatformJson.MAX_SAFE_INT, 0)
		_log("El registro de la fortaleza %s ha cambiado en la plataforma (versión %d): se reenvía el de esta instancia"
				% [fortress_id, version])
	elif not PlatformEvent.CLOSING_CODES.has(event.error_code):
		_stats[&"put_failed"] += 1
		_warn("Alerta: la plataforma no guarda la fortaleza %s: %s" % [fortress_id, ZonePlatform.describe(event)])
	return true


## A war notice ([signal FortressController.war_event_emitted]): those in [constant PERSISTED_WAR_EVENTS] go
## to the [code]war[/code] batch with the platform time.
func on_war_event(event: NetMessages.EntityEvent) -> void:
	if _closed or not PERSISTED_WAR_EVENTS.has(event.war_event):
		return
	var fortress_id: StringName = _controller.get_fortress_id_of(event.net_id)
	if fortress_id.is_empty():
		return
	_platform.enqueue_batch(WAR_BATCH, {"fortress_id": String(fortress_id), "event": event.war_event,
			"realm": event.war_realm, "at_unix": _platform.now_unix()})
	_stats[&"war_events"] += 1


## Counters for the report: records loaded, initial and discarded; PUTs sent, accepted, conflicted
## and rejected; events to the history.
func get_stats() -> Dictionary:
	var stats: Dictionary = {}
	for key: StringName in _stats:
		stats[String(key)] = _stats[key]
	return stats


func _log(text: String) -> void:
	if log_sink.is_valid():
		log_sink.call(text)
	else:
		print("[Eldmark] %s" % text)


func _warn(text: String) -> void:
	push_warning("[Eldmark] %s" % text)
	_log(text)
