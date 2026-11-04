class_name CharacterSaver
extends RefCounted
## When and how each character is saved to the platform (docs/platform.md §7.2, §7.3 and §14.3): checkpoint,
## critical events, final save and removal without saving, with one write in flight per character. It only
## exists with [code]--platform[/code]: without a platform nothing is saved (docs/progression.md §9.4).
## [br][br]
## [b]Sections[/b] ([method register_section]): each one sets a body key ([code]progress[/code] of
## [code]ProgressService[/code], progression.md P5a; [code]pvp[/code] of [code]ScoreKeeper[/code], P6) with three
## [Callable]s: [code]build(net_id, seq) -> Dictionary[/code] (once per [code]seq[/code]; [code]{}[/code] = cannot
## be built now), [code]acknowledge(net_id, seq)[/code] (after a 200 [code]applied[/code] or
## [code]duplicate[/code], only before [method finish]) and [code]is_dirty(net_id) -> bool[/code] (whether there is something to
## save at the checkpoint, only before [method finish]). They are built in the order they are registered.
## [b]Without any section there is nothing to save[/b]: the checkpoint is never dirty, a critical sends
## nothing and [method finish] releases the lease without saving, as platform.md P4 did (the platform requires
## [code]progress[/code], which arrives with progression.md P5a).
## [br][br]
## [b]Entries by [code]lease_id[/code][/b] (unique per claim), with two indexes: [code]character_id[/code] →
## current [code]lease_id[/code] and, until [method finish] or [method drop], [code]net_id[/code] → [code]lease_id[/code].
## Each response is matched by the [code]lease_id[/code] and [code]seq[/code] of its own request (the
## [code]context[/code] of [method ZonePlatform.save]), never by [code]character_id[/code] or by [code]net_id[/code]:
## a reused [code]net_id[/code] or the same character coming back with another claim do not receive the responses
## of the old entry.
## [br][br]
## [b]When[/b] ([method step], after "additions"): a marked critical goes out as soon as there is no other in flight; the
## checkpoint, every [code]interval_ticks[/code] in the character's phase ([code]tick % interval ==
## character_id % interval[/code]) if some section is dirty. While one is in flight, changes only mark; with its
## final response the next is built in that tick's [method step]. [method finish] builds the
## final one on the spot (with [code]release_lease[/code]) and, if one is in flight, waits behind it without being rebuilt.
## [br][br]
## [b]The envelope[/b] (§7.3) is built entirely by this class: [code]save_format[/code], [code]character_id[/code],
## [code]zone_instance_id[/code] and [code]lease_id[/code] (string ids), [code]seq[/code] (from 1 on each
## lease, rises by 1 on each body), [code]reason[/code], [code]release_lease[/code] and one key per section.
## It is serialized only once; [ZonePlatform]'s retries send those same bytes.
## [br][br]
## [b]Responses[/b] (the table of §7.3): 200 [code]applied[/code] or [code]duplicate[/code] → applied; any
## other 4xx (except 401) → final: before [method finish], [signal save_rejected] (the zone does the removal without
## saving: [method drop], expulsion with the body out at once…); after, it is only logged and, except for a
## [code]lease_lost[/code], that lease is released. A 409 [code]instance_*[/code] on a save (the
## platform of §6.1 does not give it: [code]instance_status[/code] says so) does not blame the player: the same body is
## resent up to [constant MAX_CLOSING_RESENDS] times, because the final saves of a closed instance are valid.

## Reason for the save ([code]reason[/code] of the envelope, §7.3).
enum Reason { CHECKPOINT = 1, CRITICAL = 2, LOGOUT = 3, SHUTDOWN = 4, KICK = 5 }

## A save of [param net_id] has received a final response that is not a 200 ([param code]:
## [code]lease_lost[/code], [code]invalid_save[/code], [code]stale_seq[/code], [code]http_403[/code]…) before
## [method finish]: the zone does the removal without saving of §7.2. After [method finish] it is not emitted.
signal save_rejected(net_id: int, character_id: int, code: String)

## [code]save_format[/code] of the envelope (§7.1).
const SAVE_FORMAT: int = 1
## Resends of the same body after a 409 [code]instance_lost[/code], [code]instance_replaced[/code] or
## [code]instance_stopped[/code]; after that, final.
const MAX_CLOSING_RESENDS: int = 3
## Code of the removal without saving that does not release: the lease no longer belongs to this zone.
const LEASE_LOST: String = "lease_lost"

## Log (a [Callable] with a text); without it, print. Alerts also go through [method push_warning].
var log_sink: Callable = Callable()

var _platform: ZonePlatform = null
var _interval_ticks: int = 3600
var _sections: Array[_Section] = []
## lease_id -> entry.
var _entries: Dictionary[String, _Entry] = {}
## character_id -> lease_id of its most recent entry.
var _by_character: Dictionary[int, String] = {}
## net_id -> lease_id, until finish or drop.
var _by_net: Dictionary[int, String] = {}
## Phase (character_id % interval) -> lease_id of the bound entries: a tick's checkpoint only looks at
## its own.
var _by_phase: Dictionary[int, PackedStringArray] = {}
## lease_id of the bound entries with a marked critical or a postponed checkpoint: they are looked at on every step.
var _urgent: Dictionary[String, bool] = {}
var _stats: Dictionary[StringName, int] = {
	&"tracked": 0, &"sent": 0, &"bytes": 0, &"max_bytes": 0, &"applied": 0, &"duplicates": 0,
	&"rejected": 0, &"deferred": 0, &"finals": 0, &"finals_unbuilt": 0, &"dropped": 0, &"released": 0,
	&"resent": 0, &"stale_answers": 0, &"criticals": 0,
}
## Criticals marked by reason (logging and metrics only, progression.md §9.2).
var _criticals_by_reason: Dictionary[StringName, int] = {}


## A section of the body.
class _Section:
	extends RefCounted
	var name: StringName = &""
	var build: Callable = Callable()
	var acknowledge: Callable = Callable()
	var is_dirty: Callable = Callable()


## What is known about a lease (a claim) of this zone.
class _Entry:
	extends RefCounted
	var lease_id: String = ""
	var character_id: int = 0
	## The body that builds it; 0 after finish or drop (the entry no longer belongs to any net_id).
	var net_id: int = 0
	## Last seq used: that of the newest body built (0 = none).
	var seq: int = 0
	## What is in flight: its seq (0 = nothing), its bytes, whether it releases and its reason.
	var flying_seq: int = 0
	var flying_body: PackedByteArray = PackedByteArray()
	var flying_release: bool = false
	var closing_resends: int = 0
	## The final one waiting behind the one in flight (empty = none).
	var final_seq: int = 0
	var final_body: PackedByteArray = PackedByteArray()
	## Marked critical: goes out on the next step with nothing in flight.
	var critical: bool = false
	## A checkpoint that could not be built: tried again on the next step.
	var retry_checkpoint: bool = false
	## Upon having nothing in flight, release without saving (a final that could not be built, drop).
	var release_when_idle: bool = false
	## The lease no longer belongs to this zone: it is never released.
	var lease_lost: bool = false


## [param interval_ticks]: the ticks between checkpoints ([code]--save-interval[/code] times the ticks per
## second).
func _init(platform: ZonePlatform, interval_ticks: int = 3600) -> void:
	_platform = platform
	_interval_ticks = maxi(interval_ticks, 1)


## Registers section [param section] (the body key). One with the same name replaces the previous one.
func register_section(section: StringName, build: Callable, acknowledge: Callable, is_dirty: Callable) -> void:
	var entry := _Section.new()
	entry.name = section
	entry.build = build
	entry.acknowledge = acknowledge
	entry.is_dirty = is_dirty
	for i: int in _sections.size():
		if _sections[i].name == section:
			_sections[i] = entry
			return
	_sections.append(entry)


## The names of the registered sections, in their order.
func section_names() -> Array[StringName]:
	var names: Array[StringName] = []
	for section: _Section in _sections:
		names.append(section.name)
	return names


## Ticks between checkpoints.
func interval_ticks() -> int:
	return _interval_ticks


## Starts saving body [param net_id] of character [param character_id] with the lease
## [param lease_id] (on creating the entity, before [code]ProgressService.on_arrival[/code], which may mark it
## critical: that critical goes out in this same tick's [method step]). An entry with another [code]lease_id[/code] of the
## same character (its final one is still being retried) is not touched.
func track(net_id: int, character_id: int, lease_id: String, tick: int) -> void:
	if net_id < 1 or character_id < 1 or lease_id.is_empty():
		_alert("track con datos que no valen (net_id %d, personaje %d, lease_id «%s»)" % [net_id, character_id,
				lease_id])
		return
	if _entries.has(lease_id):
		_alert("el arrendamiento %s del personaje %d ya tenía entrada: se ignora el segundo track" % [lease_id,
				character_id])
		return
	if _by_net.has(net_id):
		# The zone did not call finish or drop on the previous body with this net_id: it is released without saving.
		_alert("el net_id %d aún tenía entrada al llegar otro cuerpo: se suelta sin guardar" % net_id)
		drop(net_id, "net_id_reused")
	var entry := _Entry.new()
	entry.lease_id = lease_id
	entry.character_id = character_id
	entry.net_id = net_id
	_entries[lease_id] = entry
	_by_character[character_id] = lease_id
	_by_net[net_id] = lease_id
	var phase: int = character_id % _interval_ticks
	var bucket: PackedStringArray = _by_phase.get(phase, PackedStringArray())
	bucket.append(lease_id)
	_by_phase[phase] = bucket
	_stats[&"tracked"] += 1
	_log_line("Guardados: personaje %d (net_id %d) con el arrendamiento %s desde el tick %d" % [character_id, net_id,
			lease_id, tick])


## Marks body [param net_id] critical: its save goes out on the next [method step] with nothing in flight.
## [param reason] only goes to the log and metrics (progression.md §9.2).
func mark_critical(net_id: int, reason: StringName) -> void:
	var entry: _Entry = _attached(net_id)
	if entry == null:
		return
	entry.critical = true
	_urgent[entry.lease_id] = true
	_stats[&"criticals"] += 1
	_criticals_by_reason[reason] = _criticals_by_reason.get(reason, 0) + 1


## After "additions" on each tick (the snapshot is taken inside the tick): the marked criticals and the checkpoints
## due at [param tick], for bodies with nothing in flight. It only looks at those of [param tick]'s phase and the
## pending ones (criticals and postponed): with 64 bodies, almost always none.
func step(tick: int) -> void:
	var bucket: PackedStringArray = _by_phase.get(tick % _interval_ticks, PackedStringArray())
	if bucket.is_empty() and _urgent.is_empty():
		return
	var candidates: PackedStringArray = PackedStringArray(_urgent.keys())
	for lease_id: String in bucket:
		if not _urgent.has(lease_id):
			candidates.append(lease_id)
	for lease_id: String in candidates:
		var entry: _Entry = _entries.get(lease_id)
		if entry == null or entry.net_id == 0 or entry.flying_seq != 0:
			continue
		if entry.critical:
			_save_now(entry, Reason.CRITICAL)
		elif entry.retry_checkpoint or tick % _interval_ticks == entry.character_id % _interval_ticks:
			if _any_dirty(entry.net_id):
				_save_now(entry, Reason.CHECKPOINT)
			else:
				entry.retry_checkpoint = false
				_urgent.erase(entry.lease_id)


## Body [param net_id] leaves (exit, expulsion or shutdown; [param reason] from [enum Reason]): the final save is
## built now, with [code]release_lease[/code], and goes out as soon as nothing else is in flight. It unbinds
## [code]net_id[/code]: whatever arrives afterwards no longer belongs to this body. On a [code]net_id[/code] with no entry (already
## went through [method drop], or was not a character) it does nothing. A final that cannot be built ([code]{}[/code]
## from a section) or with no sections: it is released without saving.
func finish(net_id: int, reason: int) -> void:
	var entry: _Entry = _attached(net_id)
	if entry == null:
		return
	var body := PackedByteArray()
	var seq: int = entry.seq + 1
	if not _sections.is_empty():
		body = _build_body(entry, seq, reason, true)
		if body.is_empty():
			_stats[&"finals_unbuilt"] += 1
			_alert("no se ha podido construir el guardado final del personaje %d: se libera sin guardar"
					% entry.character_id)
	_detach(entry)
	if body.is_empty():
		entry.release_when_idle = true
		_settle(entry)
		return
	entry.seq = seq
	_stats[&"finals"] += 1
	if entry.flying_seq != 0:
		entry.final_seq = seq
		entry.final_body = body
	else:
		_submit(entry, seq, body, true)


## Removal without saving of body [param net_id] (§7.2): unbinds the entry, discards the final save that was waiting and releases
## the lease except with [param code] [code]lease_lost[/code] (if a save is in flight, when its
## response arrives). On a [code]net_id[/code] with no entry, nothing.
func drop(net_id: int, code: String) -> void:
	var entry: _Entry = _attached(net_id)
	if entry == null:
		return
	_detach(entry)
	entry.final_seq = 0
	entry.final_body = PackedByteArray()
	if code == LEASE_LOST:
		entry.lease_lost = true
	entry.release_when_idle = true
	_stats[&"dropped"] += 1
	_log_line("Guardados: baja sin guardado del personaje %d (net_id %d): %s" % [entry.character_id, net_id, code])
	_settle(entry)


## Handles a response from [method ZonePlatform.save]. true if it was for a save (kind [code]save[/code]).
func on_platform_event(event: PlatformEvent) -> bool:
	if event.kind != PlatformEvent.KIND_SAVE:
		return false
	var context: Dictionary = event.context if event.context is Dictionary else {}
	var lease_id: String = String(context.get("lease_id", ""))
	var seq: int = int(context.get("seq", 0))
	var entry: _Entry = _entries.get(lease_id)
	if entry == null or entry.flying_seq == 0 or entry.flying_seq != seq:
		_stats[&"stale_answers"] += 1
		_log_line("Guardados: respuesta que no se esperaba (arrendamiento %s, seq %d): %s" % [lease_id, seq,
				ZonePlatform.describe(event)])
		return true
	var body: PackedByteArray = entry.flying_body
	var released: bool = entry.flying_release
	entry.flying_seq = 0
	entry.flying_body = PackedByteArray()
	entry.flying_release = false
	if event.is_success():
		_on_applied(entry, seq, released, event)
	elif PlatformClient.is_retryable(event) or (PlatformEvent.CLOSING_CODES.has(event.error_code)
			and entry.closing_resends < MAX_CLOSING_RESENDS):
		# It is not a response about the body: the same one, with the same seq.
		entry.closing_resends += 1
		_stats[&"resent"] += 1
		_submit(entry, seq, body, released, false)
	else:
		_on_definitive(entry, seq, event)
	return true


## Saves in flight plus final saves waiting behind them (the orderly shutdown waits for this to be 0).
func pending_count() -> int:
	var count: int = 0
	for entry: _Entry in _entries.values():
		if entry.flying_seq != 0:
			count += 1
		if not entry.final_body.is_empty():
			count += 1
	return count


## The net_ids with an entry (those that [method finish] or [method drop] have not yet unbound), sorted.
func tracked_net_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(_by_net.keys())
	ids.sort()
	return ids


## true if [param net_id] has an entry.
func is_tracked(net_id: int) -> bool:
	return _by_net.has(net_id)


## The net_id bound to lease [param lease_id] of character [param character_id], or 0.
func net_id_of(character_id: int, lease_id: String) -> int:
	var entry: _Entry = _entries.get(lease_id)
	if entry == null or entry.character_id != character_id:
		return 0
	return entry.net_id


## The lease_id of the most recent entry of [param character_id] (empty if it has none).
func lease_of(character_id: int) -> String:
	return _by_character.get(character_id, "")


## Live entries (with a body or with something pending).
func entry_count() -> int:
	return _entries.size()


## Counters for the report and the tests.
func get_stats() -> Dictionary:
	var stats: Dictionary = {}
	for key: StringName in _stats:
		stats[String(key)] = _stats[key]
	var reasons: Dictionary = {}
	for reason: StringName in _criticals_by_reason:
		reasons[String(reason)] = _criticals_by_reason[reason]
	stats["criticals_by_reason"] = reasons
	stats["pending"] = pending_count()
	stats["entries"] = _entries.size()
	stats["interval_ticks"] = _interval_ticks
	return stats


# --- Internals --------------------------------------------------------------------------------

# The entry bound to [param net_id], or null.
func _attached(net_id: int) -> _Entry:
	var lease_id: String = _by_net.get(net_id, "")
	if lease_id.is_empty():
		return null
	return _entries.get(lease_id)


func _detach(entry: _Entry) -> void:
	if entry.net_id != 0 and _by_net.get(entry.net_id, "") == entry.lease_id:
		_by_net.erase(entry.net_id)
		var phase: int = entry.character_id % _interval_ticks
		var bucket: PackedStringArray = _by_phase.get(phase, PackedStringArray())
		var index: int = bucket.find(entry.lease_id)
		if index >= 0:
			bucket.remove_at(index)
		if bucket.is_empty():
			_by_phase.erase(phase)
		else:
			_by_phase[phase] = bucket
	_urgent.erase(entry.lease_id)
	entry.net_id = 0
	entry.critical = false
	entry.retry_checkpoint = false


func _any_dirty(net_id: int) -> bool:
	for section: _Section in _sections:
		if section.is_dirty.is_valid() and bool(section.is_dirty.call(net_id)):
			return true
	return false


# Builds and sends a checkpoint or a critical. If some section cannot be built, it does not spend a seq: the
# critical stays marked and the checkpoint is retried on the next step.
func _save_now(entry: _Entry, reason: int) -> void:
	if _sections.is_empty():
		entry.critical = false
		entry.retry_checkpoint = false
		_urgent.erase(entry.lease_id)
		return
	var seq: int = entry.seq + 1
	var body: PackedByteArray = _build_body(entry, seq, reason, false)
	if body.is_empty():
		_stats[&"deferred"] += 1
		if reason == Reason.CHECKPOINT:
			entry.retry_checkpoint = true
			_urgent[entry.lease_id] = true
		return
	entry.seq = seq
	entry.critical = false
	entry.retry_checkpoint = false
	_urgent.erase(entry.lease_id)
	_submit(entry, seq, body, false)


# The whole envelope of §7.3, serialized once; empty if some section returns {} (the earlier ones have already been
# built: the only one that can return it, progress, is registered first and touches nothing when doing so).
func _build_body(entry: _Entry, seq: int, reason: int, release_lease: bool) -> PackedByteArray:
	var envelope: Dictionary = {
		"save_format": SAVE_FORMAT,
		"character_id": PlatformJson.id_text(entry.character_id),
		"zone_instance_id": _platform.instance_id() if _platform != null else "",
		"lease_id": entry.lease_id,
		"seq": seq,
		"reason": reason,
		"release_lease": release_lease,
	}
	for section: _Section in _sections:
		var built: Variant = section.build.call(entry.net_id, seq) if section.build.is_valid() else null
		if not built is Dictionary or (built as Dictionary).is_empty():
			return PackedByteArray()
		envelope[String(section.name)] = built
	return JSON.stringify(envelope).to_utf8_buffer()


func _submit(entry: _Entry, seq: int, body: PackedByteArray, release_lease: bool, first: bool = true) -> void:
	entry.flying_seq = seq
	entry.flying_body = body
	entry.flying_release = release_lease
	if first:
		entry.closing_resends = 0
		_stats[&"sent"] += 1
		_stats[&"bytes"] += body.size()
		_stats[&"max_bytes"] = maxi(_stats[&"max_bytes"], body.size())
	if _platform != null:
		_platform.save(entry.character_id, entry.lease_id, body, release_lease,
				{"lease_id": entry.lease_id, "seq": seq})


func _on_applied(entry: _Entry, seq: int, released: bool, event: PlatformEvent) -> void:
	_stats[&"applied"] += 1
	if bool(event.body_dict().get("duplicate", false)):
		_stats[&"duplicates"] += 1
	if entry.net_id != 0:
		for section: _Section in _sections:
			if section.acknowledge.is_valid():
				section.acknowledge.call(entry.net_id, seq)
	if not entry.final_body.is_empty():
		var final_seq: int = entry.final_seq
		var final_body: PackedByteArray = entry.final_body
		entry.final_seq = 0
		entry.final_body = PackedByteArray()
		_submit(entry, final_seq, final_body, true)
		return
	if released:
		# The applied final save already released the lease on the platform.
		entry.release_when_idle = false
		_forget(entry)
		return
	_settle(entry)


func _on_definitive(entry: _Entry, seq: int, event: PlatformEvent) -> void:
	var code: String = event.error_code if not event.error_code.is_empty() else "http_%d" % event.status
	_stats[&"rejected"] += 1
	var detail: String = ""
	var fields: Dictionary = PlatformJson.dict_in(event.error_dict(), "fields")
	if not fields.is_empty():
		detail = " (%s: %s)" % [PlatformJson.text_in(fields, "check"), PlatformJson.text_in(fields, "detail")]
	_alert("el guardado del personaje %d (arrendamiento %s, seq %d) recibe %s%s" % [entry.character_id,
			entry.lease_id, seq, ZonePlatform.describe(event), detail])
	if code == LEASE_LOST:
		entry.lease_lost = true
	# The final save that was waiting is discarded along with it: it carried only what this one does not.
	entry.final_seq = 0
	entry.final_body = PackedByteArray()
	if entry.net_id != 0:
		var net_id: int = entry.net_id
		save_rejected.emit(net_id, entry.character_id, code)
		# If nobody has done the removal, it does it here: the entry does not stay bound to a body that is not saving.
		if _attached(net_id) == entry:
			drop(net_id, code)
		return
	entry.release_when_idle = true
	_settle(entry)


# An unbound entry with nothing in flight or waiting is closed: it releases if due (never after a lease_lost).
func _settle(entry: _Entry) -> void:
	if entry.net_id != 0 or entry.flying_seq != 0 or not entry.final_body.is_empty():
		return
	if entry.release_when_idle and not entry.lease_lost and _platform != null:
		_stats[&"released"] += 1
		_platform.release(entry.character_id, entry.lease_id)
	_forget(entry)


func _forget(entry: _Entry) -> void:
	_entries.erase(entry.lease_id)
	if _by_character.get(entry.character_id, "") == entry.lease_id:
		_by_character.erase(entry.character_id)


func _alert(text: String) -> void:
	push_warning("[Eldmark] Guardados: alerta: %s" % text)
	_log_line("Guardados: alerta: %s" % text)


func _log_line(text: String) -> void:
	if log_sink.is_valid():
		log_sink.call(text)
	else:
		print("[Eldmark] %s" % text)
