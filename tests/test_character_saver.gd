extends TestCase
## Tests of [CharacterSaver] with [FakeZonePlatform] (the JSON round trip of [PlatformClient], without network) and a
## [FakeSaveSection] (docs/platform.md §7.2, §7.3 and §15 P5): the checkpoint in its phase and only with something
## dirty, the critical one instantly (also right after track), a write in flight, the final one waiting behind
## the one in flight, the whole envelope, duplicate as applied, a section that cannot be built, no sections, the
## definitive responses before and after finish, a definitive 403 and 413, the instance_* 409s, a reused net_id
## with the previous one's final still in flight and the same character coming back while its final is being retried.
## There is no zone here: the test stands in for it (step, finish, drop on save_rejected).

const LEASE_A: String = "00000000-0000-4000-8000-00000000000a"
const LEASE_B: String = "00000000-0000-4000-8000-00000000000b"
const LEASE_C: String = "00000000-0000-4000-8000-00000000000c"
## A character_id above 2^53.
const BIG_CHARACTER_ID: int = 9007199254740993

var _platform: FakeZonePlatform = null
var _saver: CharacterSaver = null
var _section: FakeSaveSection = null
var _rejections: Array[Array] = []
var _tick: int = 0
## If false, the test does not do the removal on receiving save_rejected (CharacterSaver itself does).
var _drop_on_rejection: bool = true


func after_each() -> void:
	if is_instance_valid(_platform):
		_platform.get_parent().remove_child(_platform)
		_platform.free()
	_platform = null
	_saver = null
	_section = null
	_rejections.clear()
	_tick = 0
	_drop_on_rejection = true
	await wait_process_frames()


# --- Helpers --------------------------------------------------------------------------------

## The fake platform started and a CharacterSaver with [param interval_ticks] (and the fake section if
## [param with_section]).
func _start(interval_ticks: int = 120, with_section: bool = true) -> bool:
	_platform = FakeZonePlatform.new()
	_platform.name = "Platform"
	_platform.log_sink = func(_text: String) -> void: pass
	tree.root.add_child(_platform)
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	config.platform_url = "http://fake"
	var finished: Array = []
	_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	_platform.start(config, {"token": "token", "ticket_keys": {}})
	for _i: int in 120:
		if not finished.is_empty():
			break
		await wait_process_frames()
	if not assert_eq(finished, [[true, ""]], "the fake platform starts"):
		return false
	_platform.take_events()
	_saver = CharacterSaver.new(_platform, interval_ticks)
	_saver.log_sink = func(_text: String) -> void: pass
	_saver.save_rejected.connect(func(net_id: int, character_id: int, code: String) -> void:
		_rejections.append([net_id, character_id, code])
		if _drop_on_rejection:
			_saver.drop(net_id, code))
	if with_section:
		_section = FakeSaveSection.new()
		_section.tick_source = func() -> int: return _tick
		_section.attach(_saver)
	return true


## One zone tick: the saver takes its step with the next tick.
func _step() -> void:
	_tick += 1
	_saver.step(_tick)


## Frames with the event dispatch (the zone's "poll"), until [param condition] or [param max_ms].
func _pump_until(condition: Callable, max_ms: int = 3000) -> bool:
	var started: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < max_ms:
		if condition.call():
			return true
		await wait_process_frames()
		for event: PlatformEvent in _platform.take_events():
			_saver.on_platform_event(event)
	return condition.call()


func _pump_ms(ms: int) -> void:
	await _pump_until(func() -> bool: return false, ms)


func _saves() -> Array[Dictionary]:
	return _platform.sent(PlatformEvent.KIND_SAVE)


func _releases() -> Array[Dictionary]:
	return _platform.sent(ZonePlatform.KIND_RELEASE)


# --- Tests ----------------------------------------------------------------------------------

## Checkpoint with the test interval of 120 ticks: each character in its phase (character_id % 120), only
## with something dirty, and nothing while nothing changes.
func test_checkpoints_go_out_in_each_phase_only_when_dirty() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_saver.track(6, 100, LEASE_B, 0)
	_saver.track(7, 130, LEASE_C, 0)
	_section.set_kills(5, 1)
	_section.set_kills(6, 2)
	for _i: int in 41:
		_step()
	assert_eq(_saves().size(), 0, "nothing before its phase")
	_step()
	assert_eq(_section.build_ticks(5), [42], "42 at tick 42")
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 1)
	while _tick < 125:
		_step()
	assert_eq(_section.build_ticks(6), [100], "100 at tick 100")
	assert_eq(_section.build_ticks(7), [], "130 (phase 10) has nothing dirty")
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 2)
	while _tick < 170:
		_step()
	assert_eq(_section.build_ticks(5), [42], "confirmed and unchanged, 42 does not save again at 162")
	_section.set_kills(5, 3)
	while _tick < 290:
		_step()
	assert_eq(_section.build_ticks(5), [42, 282], "with a change, at its next phase (282)")
	var saves: Array[Dictionary] = _saves()
	assert_eq(saves.size(), 3, "three saves in total")
	assert_eq(saves.map(func(b: Dictionary) -> int: return int(b["reason"])), [1, 1, 1], "all with reason 1")
	assert_eq(saves.map(func(b: Dictionary) -> String: return String(b["character_id"])), ["42", "100", "42"],
			"in the order of their phases")


## A critical one goes out in the same step, even if the character is not in its phase; also one marked right after track.
func test_a_critical_goes_out_at_once_even_right_after_track() -> void:
	if not await _start(120):
		return
	_tick = 7
	_saver.track(5, 42, LEASE_A, _tick)
	_saver.mark_critical(5, &"starter_kit")
	_saver.step(_tick)
	assert_eq(_section.build_ticks(5), [7], "on the step of the registration tick")
	if not assert_eq(_saves().size(), 1, "goes out right away"):
		return
	assert_eq(int(_saves()[0]["reason"]), CharacterSaver.Reason.CRITICAL, "with reason 2")
	assert_eq(int(_saves()[0]["seq"]), 1, "seq 1")
	assert_eq(_saver.get_stats()["criticals_by_reason"], {"starter_kit": 1}, "the reason, in the metrics")


## One write in flight per character: what is marked while it flies goes out when the response arrives, on the next step,
## with the next seq; and the final one waits behind the one in flight, built at that moment, without being redone.
func test_one_write_in_flight_and_the_final_waits_behind_it() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, FakeZonePlatform.DEFAULT, 0.3)
	_saver.mark_critical(5, &"level_up")
	_step()
	_saver.mark_critical(5, &"gm")
	_step()
	_step()
	assert_eq(_section.builds.size(), 1, "one in flight: the second critical one waits")
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 1)
	assert_eq(_section.acknowledged, [[5, 1]], "the first, confirmed")
	assert_eq(_saves().size(), 1, "the second does not go out until the next step")
	_step()
	assert_eq(_saves().size(), 2, "goes out on the next step")
	assert_eq(int(_saves()[1]["seq"]), 2, "with seq 2")
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 2)
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, FakeZonePlatform.DEFAULT, 0.3)
	_section.set_kills(5, 9)
	_saver.mark_critical(5, &"capture")
	_step()
	_section.set_kills(5, 10)
	_saver.finish(5, CharacterSaver.Reason.LOGOUT)
	assert_eq(_section.builds.size(), 4, "the final one is built at that moment")
	assert_eq(_saves().size(), 3, "but waits behind the one in flight")
	assert_eq(_saver.pending_count(), 2, "one in flight and a final one waiting")
	await _pump_until(func() -> bool: return _saves().size() == 4)
	var final: Dictionary = _saves()[3]
	assert_eq([int(final["seq"]), int(final["reason"]), final["release_lease"]], [4, CharacterSaver.Reason.LOGOUT, true],
			"the final one: seq 4, reason 3 and release_lease")
	assert_eq(int(final["pvp"]["kills"]), 10, "with the snapshot from the moment of finish")
	assert_eq(_section.acknowledged, [[5, 1], [5, 2]], "after finish, the response of the one that was in flight confirms nothing")
	await _pump_until(func() -> bool: return _saver.entry_count() == 0)
	assert_eq(_saver.pending_count(), 0, "nothing pending")
	assert_eq(_releases().size(), 0, "the final one releases: no separate release")
	assert_eq(_section.builds.size(), 4, "the final one was not redone")


## The whole §7.3 envelope: string ids (character_id > 2^53), zone_instance_id, lease_id, seq, reason,
## release_lease and the section; retries send the same body.
func test_the_envelope_and_the_same_body_on_retries() -> void:
	if not await _start(120):
		return
	_saver.track(5, BIG_CHARACTER_ID, LEASE_A, 0)
	_section.set_kills(5, 4)
	_platform.script_next(PlatformEvent.KIND_SAVE, 0, null)
	_platform.script_next(PlatformEvent.KIND_SAVE, 503, FakeZonePlatform.error_body("db_unavailable"))
	_saver.mark_critical(5, &"gm")
	_step()
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 1)
	var saves: Array[Dictionary] = _saves()
	if not assert_eq(saves.size(), 3, "offline and 503: two retries"):
		return
	var body: Dictionary = saves[0]
	assert_eq(body.keys().size(), 8, "seven envelope fields and the section")
	assert_eq(int(body["save_format"]), 1, "save_format 1")
	assert_eq(body["character_id"], str(BIG_CHARACTER_ID), "character_id as a string, exact")
	assert_eq(body["zone_instance_id"], _platform.instance_id(), "zone_instance_id of the instance")
	assert_eq(body["lease_id"], LEASE_A, "lease_id")
	assert_eq([int(body["seq"]), int(body["reason"]), body["release_lease"]], [1, 2, false], "seq, reason and release")
	assert_eq(int(body["pvp"]["kills"]), 4, "the section")
	assert_eq(JSON.stringify(saves[1]), JSON.stringify(body), "the first retry, the same body")
	assert_eq(JSON.stringify(saves[2]), JSON.stringify(body), "and the second")
	assert_eq(_section.builds.size(), 1, "built only once")


## A 200 duplicate (a save that arrived and whose response was lost) counts as applied.
func test_duplicate_counts_as_applied() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, {"applied": false, "duplicate": true, "save_version": 3,
			"instance_status": "live"})
	_saver.mark_critical(5, &"gm")
	_step()
	await _pump_until(func() -> bool: return not _section.acknowledged.is_empty())
	assert_eq(_section.acknowledged, [[5, 1]], "confirms seq 1")
	assert_eq(_rejections.size(), 0, "no kick")
	_saver.mark_critical(5, &"gm")
	_step()
	assert_eq(int(_saves().back()["seq"]), 2, "the next one carries seq 2")
	assert_eq(_saver.get_stats()["duplicates"], 1, "counted as a duplicate")


## A section that returns {}: the save does not go out or spend a seq; the critical one stays marked and the checkpoint is
## attempted on the next step.
func test_a_section_that_cannot_build_defers_without_spending_seq() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_section.unbuildable[5] = true
	_saver.mark_critical(5, &"gm")
	_step()
	_step()
	assert_eq(_saves().size(), 0, "does not go out")
	assert_eq(_section.builds.size(), 2, "and is attempted on every step")
	_section.unbuildable.erase(5)
	_step()
	if assert_eq(_saves().size(), 1, "goes out as soon as it can"):
		assert_eq(int(_saves()[0]["seq"]), 1, "with seq 1: the failed attempts spent none")
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 1)
	_section.set_kills(5, 1)
	_section.unbuildable[5] = true
	while _tick < 42:
		_step()
	_section.unbuildable.erase(5)
	_step()
	assert_eq(_section.build_ticks(5), [3, 43], "42's checkpoint, postponed to 43")
	assert_eq(int(_saves().back()["seq"]), 2, "with seq 2")
	assert_eq(_saver.get_stats()["deferred"], 3, "three postponed")


## A final one that cannot be built: alert and release without saving (after finish the state no longer exists).
func test_a_final_that_cannot_be_built_releases_without_saving() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_section.unbuildable[5] = true
	_saver.finish(5, CharacterSaver.Reason.LOGOUT)
	await _pump_ms(150)
	assert_eq(_saves().size(), 0, "no save")
	assert_eq(_releases(), [{"zone_instance_id": _platform.instance_id(), "lease_id": LEASE_A}], "one release")
	assert_eq(_saver.entry_count(), 0, "the entry is closed")


## With no sections registered (until progression.md P5a) there is nothing to save: neither the checkpoint nor the critical one
## sends anything, and finish releases.
func test_without_sections_nothing_is_saved_and_finish_releases() -> void:
	if not await _start(120, false):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_saver.mark_critical(5, &"gm")
	while _tick < 130:
		_step()
	assert_eq(_saves().size(), 0, "nothing to save")
	_saver.finish(5, CharacterSaver.Reason.LOGOUT)
	await _pump_until(func() -> bool: return _releases().size() == 1)
	assert_eq(_releases(), [{"zone_instance_id": _platform.instance_id(), "lease_id": LEASE_A}], "finish releases")
	assert_eq(_saves().size(), 0, "without saving")


## Before finish, a definitive response (invalid_save, stale_seq, seq_conflict, a 403, a 413, a 404, an unknown
## 409) emits save_rejected and the removal without a save releases once; lease_lost, without releasing. None is
## retried.
func test_definitive_answers_before_finish_reject_and_drop() -> void:
	if not await _start(120):
		return
	var cases: Array = [
		[400, "invalid_save", true], [409, "stale_seq", true], [409, "seq_conflict", true], [403, "forbidden", true],
		[413, "too_large", true], [404, "not_found", true], [409, "whatever", true], [409, "lease_lost", false],
	]
	var net_id: int = 10
	for entry: Array in cases:
		net_id += 1
		var lease_id: String = "00000000-0000-4000-8000-%012d" % net_id
		var extra: Dictionary = {"fields": {"check": "S4", "detail": "ranura repetida"}} \
				if entry[1] == "invalid_save" else {}
		_platform.script_next(PlatformEvent.KIND_SAVE, entry[0], FakeZonePlatform.error_body(entry[1], "", extra))
		_saver.track(net_id, net_id + 100, lease_id, _tick)
		_saver.mark_critical(net_id, &"gm")
		var saves_before: int = _saves().size()
		var releases_before: int = _releases().size()
		_step()
		await _pump_until(func() -> bool: return _rejections.size() == net_id - 10)
		if not assert_eq(_rejections.back(), [net_id, net_id + 100, entry[1]], "%d %s → save_rejected" % [entry[0],
				entry[1]]):
			return
		await _pump_ms(120)
		assert_eq(_saves().size(), saves_before + 1, "%s is not retried" % entry[1])
		var released: Array = _releases().slice(releases_before)
		if entry[2]:
			assert_eq(released, [{"zone_instance_id": _platform.instance_id(), "lease_id": lease_id}],
					"%s: released once" % entry[1])
		else:
			assert_eq(released.size(), 0, "lease_lost: without releasing")
		assert_false(_saver.is_tracked(net_id), "the entry is left untied")
	assert_eq(_saver.entry_count(), 0, "and closed")


## If the zone does not do the removal on receiving save_rejected, CharacterSaver does it itself: the entry is not left tied.
func test_a_rejection_without_a_drop_still_detaches() -> void:
	if not await _start(120):
		return
	_drop_on_rejection = false
	_platform.script_next(PlatformEvent.KIND_SAVE, 400, FakeZonePlatform.error_body("invalid_save"))
	_saver.track(5, 42, LEASE_A, 0)
	_saver.mark_critical(5, &"gm")
	_step()
	await _pump_until(func() -> bool: return not _rejections.is_empty())
	assert_false(_saver.is_tracked(5), "untied")
	await _pump_until(func() -> bool: return _releases().size() == 1)
	assert_eq(_releases().size(), 1, "and released")


## A 409 instance_lost on a save (the platform says it with instance_status; if it arrives anyway) does not blame the
## player: the same body is resent; after MAX_CLOSING_RESENDS, definitive.
func test_a_closing_code_on_a_save_resends_the_same_body() -> void:
	if not await _start(120):
		return
	_platform.script_next(PlatformEvent.KIND_SAVE, 409, FakeZonePlatform.error_body("instance_lost"))
	_saver.track(5, 42, LEASE_A, 0)
	_section.set_kills(5, 2)
	_saver.mark_critical(5, &"gm")
	_step()
	await _pump_until(func() -> bool: return _section.acknowledged.size() == 1)
	assert_eq(_saves().size(), 2, "resent once")
	assert_eq(JSON.stringify(_saves()[1]), JSON.stringify(_saves()[0]), "the same body")
	assert_eq(_rejections.size(), 0, "no kick")
	for _i: int in CharacterSaver.MAX_CLOSING_RESENDS + 1:
		_platform.script_next(PlatformEvent.KIND_SAVE, 409, FakeZonePlatform.error_body("instance_stopped"))
	_saver.mark_critical(5, &"gm")
	_step()
	await _pump_until(func() -> bool: return not _rejections.is_empty())
	assert_eq(_saves().size(), 2 + CharacterSaver.MAX_CLOSING_RESENDS + 1, "the resends have a cap")
	assert_eq(_rejections, [[5, 42, "instance_stopped"]], "and afterward it is definitive")


## After finish, the definitive response of the one that was in flight is only logged: the final one that was waiting is discarded with it,
## it is released once and there is no save_rejected, acknowledge or is_dirty.
func test_after_finish_a_definitive_answer_only_logs_and_releases() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_platform.script_next(PlatformEvent.KIND_SAVE, 400, FakeZonePlatform.error_body("invalid_save"), 0.2)
	_saver.mark_critical(5, &"gm")
	_step()
	_saver.finish(5, CharacterSaver.Reason.SHUTDOWN)
	var calls: int = _section.calls_for(5)
	for _i: int in 5:
		_step()
	await _pump_until(func() -> bool: return _releases().size() == 1)
	await _pump_ms(150)
	assert_eq(_rejections.size(), 0, "no save_rejected after finish")
	assert_eq(_saves().size(), 1, "the final one is discarded with the one that was in flight")
	assert_eq(_releases(), [{"zone_instance_id": _platform.instance_id(), "lease_id": LEASE_A}], "one release")
	assert_eq(_section.calls_for(5), calls, "the section receives nothing more after finish")
	assert_eq(_saver.entry_count(), 0, "closed entry")


## A reused net_id with the previous one's final still in flight: the new body receives no acknowledge or
## save_rejected from the old entry, and a late invalid_save for the old one is only logged and releases its own.
func test_a_reused_net_id_does_not_get_the_old_answers() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	_platform.script_next(PlatformEvent.KIND_SAVE, 400, FakeZonePlatform.error_body("invalid_save"), 0.3)
	_saver.mark_critical(5, &"gm")
	_step()
	_saver.finish(5, CharacterSaver.Reason.LOGOUT)
	_saver.track(5, 43, LEASE_B, _tick)
	_saver.mark_critical(5, &"starter_kit")
	_step()
	assert_eq(_saves().size(), 2, "the new body saves in parallel (another lease)")
	assert_eq(String(_saves()[1]["lease_id"]), LEASE_B, "with its lease_id")
	assert_eq(int(_saves()[1]["seq"]), 1, "and its own seq")
	await _pump_until(func() -> bool: return _releases().size() == 1)
	await _pump_ms(120)
	assert_eq(_rejections.size(), 0, "the new one does not receive the old one's save_rejected")
	assert_eq(_section.acknowledged, [[5, 1]], "only the acknowledge of its own seq 1")
	assert_eq(_releases(), [{"zone_instance_id": _platform.instance_id(), "lease_id": LEASE_A}],
			"the old one releases its lease")
	assert_true(_saver.is_tracked(5), "the new one continues")
	assert_eq(_saver.lease_of(43), LEASE_B, "with its lease_id")


## The same character comes back to this instance (another claim) while its final, already applied, is retried: the
## old entry receives lease_lost and it is only logged (without releasing), and the new one is not kicked.
func test_the_same_character_back_while_its_applied_final_is_retried() -> void:
	if not await _start(120):
		return
	_saver.track(5, 42, LEASE_A, 0)
	# The platform applies the final one and releases, but its responses are lost; the retry arrives after the new
	# claim: lease_lost.
	_platform.script_next(PlatformEvent.KIND_SAVE, 0, null, 0.1)
	_platform.script_next(PlatformEvent.KIND_SAVE, 0, null, 0.1)
	_platform.script_next(PlatformEvent.KIND_SAVE, 409, FakeZonePlatform.error_body("lease_lost"), 0.3)
	_saver.finish(5, CharacterSaver.Reason.LOGOUT)
	_saver.track(8, 42, LEASE_B, _tick)
	assert_eq(_saver.lease_of(42), LEASE_B, "the character's index points to the new claim")
	await _pump_until(func() -> bool: return _saves().size() == 3)
	await _pump_until(func() -> bool: return _saver.entry_count() == 1)
	assert_eq(_rejections.size(), 0, "nobody receives save_rejected")
	assert_eq(_releases().size(), 0, "lease_lost does not release")
	assert_true(_saver.is_tracked(8), "the new entry continues")
	_section.set_kills(8, 1)
	_saver.mark_critical(8, &"gm")
	_step()
	await _pump_until(func() -> bool: return not _section.acknowledged.is_empty())
	assert_eq(_section.acknowledged, [[8, 1]], "and saves with its seq 1")
	assert_eq(String(_saves().back()["lease_id"]), LEASE_B, "with its lease")
