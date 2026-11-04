extends TestCase
## Tests for [FortressState] (docs/fortress.md, sections 1.3 to 1.5): every row of the decision table,
## the progress formula versus simulating tick by tick, the decays, the contest, the reset, the
## respawn of the captain and the guards, the gate and the fields that change.
## Everything is pure (no nodes), so thousands of ticks run instantly.

const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const VARDHEIM: int = 1
const SOLMARCH: int = 2
const ASKARRA: int = 3
## Ticks per second of the simulation.
const TPS: int = 60

var _def: FortressDefinition = null
var _state: FortressState = null
var _tick: int = 0


func before_each() -> void:
	_def = load(DEFINITION_PATH) as FortressDefinition
	assert_not_null(_def, "the Vado Gris definition loads")
	_tick = 100
	_state = FortressState.initial(_def, _tick)


# --- Initial state and speeds -----------------------------------------------------------------

func test_initial_state_is_a_neutral_garrisoned_fort() -> void:
	assert_eq(_state.owner, 0, "neutral")
	assert_eq(_state.phase, FortressState.Phase.GARRISONED)
	assert_eq(_state.phase_tick, 100)
	assert_true(_state.captain_alive, "the Ford Captain is alive")
	assert_eq(_state.gate_health, 9000)
	assert_eq(_state.gate_max, 9000)
	assert_eq(_state.progress_max, 21600, "30 s -> 1800 ticks -> 21 600")
	assert_eq(_state.capture_realm, 0)
	assert_eq(_state.capture_rate, 0)
	assert_eq(_state.progress_at(100.0), 0)
	assert_false(_state.contested)
	assert_eq(_state.presence, PackedInt32Array([0, 0, 0, 0]))
	assert_eq(_state.under_attack_until_tick, 0, "not attacked: respawning is allowed")
	assert_false(_state.is_circle_active())
	assert_false(_state.is_gate_broken())


func test_capture_rates_by_number_of_attackers() -> void:
	assert_eq(FortressState.rate_for_count(0), 0)
	assert_eq(FortressState.rate_for_count(1), 12)
	assert_eq(FortressState.rate_for_count(2), 16)
	assert_eq(FortressState.rate_for_count(3), 20)
	assert_eq(FortressState.rate_for_count(4), 24)
	assert_eq(FortressState.rate_for_count(9), 24, "cap: 4 or more")
	assert_eq(FortressState.rate_for_count(-1), 0)
	assert_eq(FortressState.EMPTY_DECAY_RATE, -4, "a third of the base speed")
	assert_eq(FortressState.FOREIGN_DECAY_RATE, -24)


# --- GARRISONED -------------------------------------------------------------------------------

func test_a_garrisoned_fort_ignores_the_circle() -> void:
	for _i: int in 1000:
		_tick += 1
		var events: PackedInt32Array = _state.advance(_def, _tick, _p(2, 0, 0))
		assert_true(events.is_empty())
	assert_eq(_state.phase, FortressState.Phase.GARRISONED, "with the captain alive it cannot be captured")
	assert_eq(_state.progress_at(float(_tick)), 0)
	assert_eq(_state.presence[VARDHEIM], 2, "but presence is kept for the interface")


func test_captain_death_makes_the_fort_vulnerable() -> void:
	var events: PackedInt32Array = _state.on_captain_died(_tick, SOLMARCH)
	assert_eq(events, PackedInt32Array([WarEvents.CAPTAIN_DOWN]))
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE)
	assert_eq(_state.phase_tick, _tick)
	assert_false(_state.captain_alive)
	assert_eq(_state.captain_respawn_tick, _tick + 300 * TPS, "respawns after 300 s")
	assert_true(_state.is_circle_active())
	# A second death does nothing.
	assert_true(_state.on_captain_died(_tick + 5, SOLMARCH).is_empty())
	assert_eq(_state.captain_respawn_tick, _tick + 300 * TPS)


func test_captain_death_outside_garrisoned_is_ignored() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_true(_state.on_captain_died(_tick, VARDHEIM).is_empty(), "while capturing there is no captain to kill")
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)


# --- VULNERABLE -------------------------------------------------------------------------------

func test_vulnerable_with_a_single_realm_starts_capturing() -> void:
	for count: int in [1, 2, 3, 4, 7]:
		before_each()
		_kill_captain()
		_tick += 10
		var events: PackedInt32Array = _state.advance(_def, _tick, _p(0, count, 0))
		assert_eq(events, PackedInt32Array([WarEvents.CAPTURE_STARTED]), "%d attackers" % count)
		assert_eq(_state.phase, FortressState.Phase.CAPTURING)
		assert_eq(_state.capture_realm, SOLMARCH)
		assert_eq(_state.capture_rate, FortressState.rate_for_count(count), "speed with %d" % count)
		assert_eq(_state.capture_start_tick, _tick, "the formula is anchored at this tick")
		assert_eq(_state.capture_progress_at_start, 0)
		assert_false(_state.contested)
		assert_eq(_state.event_realm(WarEvents.CAPTURE_STARTED), SOLMARCH, "the alert carries the capturer")


func test_vulnerable_without_attackers_stays_vulnerable() -> void:
	_kill_captain()
	for _i: int in 200:
		_tick += 1
		assert_true(_state.advance(_def, _tick, _p(0, 0, 0)).is_empty())
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE)
	assert_false(_state.contested)


func test_two_realms_in_the_circle_keep_it_vulnerable_and_contested() -> void:
	_kill_captain()
	_tick += 1
	var events: PackedInt32Array = _state.advance(_def, _tick, _p(1, 1, 0))
	assert_eq(events, PackedInt32Array([WarEvents.CAPTURE_CONTESTED]), "it alerts when the contest begins")
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE)
	assert_true(_state.contested)
	assert_eq(_state.capture_rate, 0)
	# While it stays contested the alert is not repeated.
	for _i: int in 100:
		_tick += 1
		assert_true(_state.advance(_def, _tick, _p(1, 1, 0)).is_empty())
	# With a single flag, the capture starts.
	_tick += 1
	var start: PackedInt32Array = _state.advance(_def, _tick, _p(0, 1, 0))
	assert_eq(start, PackedInt32Array([WarEvents.CAPTURE_STARTED]))
	assert_false(_state.contested)
	assert_eq(_state.capture_realm, SOLMARCH)


func test_attackers_and_the_owner_together_are_contested() -> void:
	_set_owner(VARDHEIM)
	_kill_captain()
	_tick += 1
	var events: PackedInt32Array = _state.advance(_def, _tick, _p(1, 1, 0))
	assert_eq(events, PackedInt32Array([WarEvents.CAPTURE_CONTESTED]))
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE, "A and D: still vulnerable")
	assert_true(_state.contested)
	# The owner alone is not an attacker: it neither captures nor contests.
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	assert_false(_state.contested)
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE)
	assert_eq(_state.capture_realm, 0)
	# Solmarch only captures Vardheim's fort.
	_tick += 1
	_state.advance(_def, _tick, _p(0, 2, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_eq(_state.capture_realm, SOLMARCH)


func test_with_a_neutral_fort_every_realm_is_an_attacker() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	assert_eq(_state.capture_realm, VARDHEIM, "Vardheim captures the neutral fort")
	before_each()
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(0, 0, 1))
	assert_eq(_state.capture_realm, ASKARRA)


func test_the_disputed_notice_is_limited_to_one_every_ten_seconds() -> void:
	_kill_captain()
	# Enters and leaves the contest every 2 s for 40 s (10 entries): the alerts, at least 10 s apart.
	var notices: Array[int] = []
	var entries: int = 0
	var was_contested: bool = false
	for i: int in range(0, 40 * TPS):
		_tick += 1
		var contested_now: bool = (i / (2 * TPS)) % 2 == 0
		var events: PackedInt32Array = _state.advance(_def, _tick, _p(1, 1, 0) if contested_now else _p(0, 0, 0))
		if contested_now and not was_contested:
			entries += 1
		was_contested = contested_now
		if events.has(WarEvents.CAPTURE_CONTESTED):
			notices.append(_tick)
	assert_eq(entries, 10, "ten contest entries")
	assert_true(notices.size() >= 3 and notices.size() < entries, "alerts in 40 s: %d (fewer than the entries)" % notices.size())
	for i: int in range(1, notices.size()):
		assert_true(notices[i] - notices[i - 1] >= 10 * TPS, "alert %d: %d ticks since the previous one" % [i, notices[i] - notices[i - 1]])
	# With the same rule, two entries less than 10 s apart give a single alert.
	before_each()
	_kill_captain()
	var count: int = 0
	for i: int in 9 * TPS:
		_tick += 1
		var on: bool = (i % 60) < 30
		if _state.advance(_def, _tick, _p(1, 1, 0) if on else _p(0, 0, 0)).has(WarEvents.CAPTURE_CONTESTED):
			count += 1
	assert_eq(count, 1, "in 9 s, a single alert")


func test_the_captain_respawns_when_nobody_captures_in_time() -> void:
	_kill_captain()
	var respawn: int = _state.captain_respawn_tick
	_tick = respawn - 1
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE, "one tick earlier it is still vulnerable")
	assert_false(_state.captain_alive)
	_tick = respawn
	var events: PackedInt32Array = _state.advance(_def, _tick, _p(0, 0, 0))
	assert_true(events.is_empty())
	assert_eq(_state.phase, FortressState.Phase.GARRISONED, "when the deadline is met the captain respawns")
	assert_true(_state.captain_alive)
	assert_eq(_state.captain_respawn_tick, FortressState.NO_TICK)
	assert_eq(_state.phase_tick, respawn)
	assert_false(_state.is_circle_active())


func test_the_captain_can_be_brought_back_early_only_while_vulnerable() -> void:
	assert_false(_state.respawn_captain(_tick), "with the captain alive there is nothing to do")
	_kill_captain()
	_tick += 10
	assert_true(_state.respawn_captain(_tick), "full respawn of the Hollow")
	assert_eq(_state.phase, FortressState.Phase.GARRISONED)
	assert_true(_state.captain_alive)
	assert_eq(_state.captain_respawn_tick, FortressState.NO_TICK)
	assert_eq(_state.phase_tick, _tick)
	# While capturing it does not come back.
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_false(_state.respawn_captain(_tick + 1))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_false(_state.captain_alive)


func test_a_contested_circle_does_not_stop_the_captain_respawning() -> void:
	_kill_captain()
	var respawn: int = _state.captain_respawn_tick
	_tick = respawn - 5
	_state.advance(_def, _tick, _p(1, 1, 0))
	assert_true(_state.contested)
	_tick = respawn
	_state.advance(_def, _tick, _p(1, 1, 0))
	assert_eq(_state.phase, FortressState.Phase.GARRISONED)
	assert_false(_state.contested, "and the contest ends with the circle")


# --- CAPTURING: progress and capture ----------------------------------------------------------

func test_a_capture_completes_at_the_exact_tick() -> void:
	# Ticks to capture = 21 600 / speed: 1800, 1350, 1080 and 900 with 1, 2, 3 and 4 or more.
	var expected_ticks: Dictionary = {1: 1800, 2: 1350, 3: 1080, 4: 900, 6: 900}
	for count: int in expected_ticks:
		before_each()
		_kill_captain()
		_tick += 1
		_state.advance(_def, _tick, _p(count, 0, 0))
		var start: int = _tick
		var captured_at: int = -1
		for _i: int in 3000:
			_tick += 1
			var events: PackedInt32Array = _state.advance(_def, _tick, _p(count, 0, 0))
			if events.has(WarEvents.FORT_CAPTURED):
				captured_at = _tick
				break
		assert_eq(captured_at - start, int(expected_ticks[count]), "%d attackers capture in %d ticks" % [count, expected_ticks[count]])


func test_capture_completion_makes_the_attacker_the_owner() -> void:
	# A hit on the gate and on the guards beforehand, to see that the capture resets it.
	_state.set_guards_alive(4)
	_kill_captain()
	_state.on_gate_damaged(_tick, 4000, VARDHEIM)
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	var events: PackedInt32Array = PackedInt32Array()
	while not events.has(WarEvents.FORT_CAPTURED):
		_tick += 1
		events = _state.advance(_def, _tick, _p(1, 0, 0))
	assert_eq(events, PackedInt32Array([WarEvents.FORT_CAPTURED]))
	assert_eq(_state.owner, VARDHEIM, "owner: the capturer")
	assert_eq(_state.phase, FortressState.Phase.CONSOLIDATING)
	assert_eq(_state.phase_tick, _tick)
	assert_eq(_state.gate_health, 9000, "gate repaired")
	assert_eq(_state.gate_last_damage_tick, FortressState.NO_TICK)
	assert_false(_state.captain_alive, "no captain until the garrison arrives")
	assert_eq(_state.guards_alive, 0, "the previous owner's NPCs withdraw")
	assert_eq(_state.capture_realm, 0)
	assert_eq(_state.capture_rate, 0)
	assert_false(_state.is_circle_active())
	assert_eq(_state.event_realm(WarEvents.FORT_CAPTURED), VARDHEIM, "the alert carries the new owner")


func test_the_captor_alone_keeps_the_formula_running() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(0, 1, 0))
	var start: int = _tick
	# One more teammate halfway: it is re-anchored with the progress of the moment and the new speed.
	_tick = start + 600
	_state.advance(_def, _tick, _p(0, 2, 0))
	assert_eq(_state.capture_rate, 16)
	assert_eq(_state.capture_progress_at_start, 600 * 12, "progress up to that point: 7200")
	assert_eq(_state.capture_start_tick, _tick)
	assert_eq(_state.progress_at(float(_tick + 100)), 600 * 12 + 100 * 16)


func test_contested_capture_freezes() -> void:
	_set_owner(SOLMARCH)
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(2, 0, 0))
	var frozen_at: int = _tick + 300
	_tick = frozen_at
	_state.advance(_def, _tick, _p(2, 0, 0))
	var progress: int = _state.progress_at(float(_tick))
	assert_eq(progress, 300 * 16)
	# The owner arrives: contested, speed 0.
	_tick += 10
	var events: PackedInt32Array = _state.advance(_def, _tick, _p(2, 1, 0))
	assert_eq(events, PackedInt32Array([WarEvents.CAPTURE_CONTESTED]))
	assert_true(_state.contested)
	assert_eq(_state.capture_rate, 0)
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	for _i: int in 500:
		_tick += 1
		_state.advance(_def, _tick, _p(2, 1, 0))
	assert_eq(_state.progress_at(float(_tick)), progress + 10 * 16, "frozen since the owner arrived")
	# Another realm also contests.
	before_each()
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	_tick += 100
	_state.advance(_def, _tick, _p(1, 1, 0))
	assert_true(_state.contested, "capturer and another realm")
	assert_eq(_state.capture_rate, 0)
	# The intruder leaves: it resumes.
	_tick += 50
	_state.advance(_def, _tick, _p(1, 0, 0))
	assert_false(_state.contested)
	assert_eq(_state.capture_rate, 12)


func test_foreign_players_without_the_captor_roll_the_capture_back_fast() -> void:
	_set_owner(SOLMARCH)
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(3, 0, 0))
	_tick += 400
	_state.advance(_def, _tick, _p(3, 0, 0))
	var progress: int = _state.progress_at(float(_tick))
	assert_eq(progress, 400 * 20, "three capturers: 20 per tick")
	# The capturers leave and only the owner remains: -24 per tick.
	_tick += 1
	_state.advance(_def, _tick, _p(0, 1, 0))
	assert_eq(_state.capture_rate, -24)
	assert_eq(_state.capture_progress_at_start, 400 * 20 + 20)
	_tick += 100
	_state.advance(_def, _tick, _p(0, 1, 0))
	assert_eq(_state.progress_at(float(_tick)), 400 * 20 + 20 - 100 * 24)
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)


func test_progress_zero_with_a_single_foreign_realm_hands_it_the_capture() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	_tick += 200
	_state.advance(_def, _tick, _p(1, 0, 0))
	# Solmarch (2 players) replaces Vardheim: Vardheim's capture falls back at 24 per tick.
	_tick += 1
	_state.advance(_def, _tick, _p(0, 2, 0))
	assert_eq(_state.capture_rate, -24)
	var progress: int = _state.progress_at(float(_tick))
	var swapped: PackedInt32Array = PackedInt32Array()
	var ticks_to_zero: int = 0
	while swapped.is_empty():
		_tick += 1
		ticks_to_zero += 1
		swapped = _state.advance(_def, _tick, _p(0, 2, 0))
		assert_true(ticks_to_zero < 1000)
	assert_eq(swapped, PackedInt32Array([WarEvents.CAPTURE_STARTED]), "the new capturer announces it")
	assert_eq(ticks_to_zero, ceili(float(progress) / 24.0), "when it reaches zero")
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_eq(_state.capture_realm, SOLMARCH)
	assert_eq(_state.capture_rate, 16, "with its player count")
	assert_eq(_state.capture_progress_at_start, 0)
	assert_eq(_state.capture_start_tick, _tick)


func test_progress_zero_without_an_attacker_goes_back_to_vulnerable() -> void:
	# Only the owner remains inside and the progress reaches zero.
	_set_owner(SOLMARCH)
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	_tick += 50
	_state.advance(_def, _tick, _p(1, 0, 0))
	var progress: int = _state.progress_at(float(_tick))
	_tick += 1
	_state.advance(_def, _tick, _p(0, 1, 0))
	var guard: int = 0
	while _state.phase == FortressState.Phase.CAPTURING and guard < 100:
		_tick += 1
		_state.advance(_def, _tick, _p(0, 1, 0))
		guard += 1
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE, "no attackers and at zero: VULNERABLE")
	assert_eq(_state.capture_realm, 0)
	assert_eq(_state.capture_rate, 0)
	assert_eq(_state.capture_progress_at_start, 0)
	assert_eq(_state.progress_at(float(_tick)), 0)
	assert_true(progress > 0)
	assert_eq(_state.captain_respawn_tick, _tick + 300 * TPS, "the captain has a new deadline")


func test_progress_zero_with_two_attackers_goes_back_to_vulnerable_contested() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	_tick += 20
	_state.advance(_def, _tick, _p(0, 1, 1))
	var guard: int = 0
	while _state.phase == FortressState.Phase.CAPTURING and guard < 100:
		_tick += 1
		_state.advance(_def, _tick, _p(0, 1, 1))
		guard += 1
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE, "two attackers at zero: nobody captures")
	_tick += 1
	_state.advance(_def, _tick, _p(0, 1, 1))
	assert_true(_state.contested, "and they keep contesting")
	assert_eq(_state.capture_realm, 0)


# --- CAPTURING: the empty circle --------------------------------------------------------------

func test_an_empty_circle_freezes_for_five_seconds_then_decays_slowly() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(0, 1, 0))
	_tick += 600
	_state.advance(_def, _tick, _p(0, 1, 0))
	var progress: int = _state.progress_at(float(_tick))
	assert_eq(progress, 600 * 12)
	# Everyone leaves: 5 s frozen.
	var empty_from: int = _tick + 1
	_tick = empty_from
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.empty_since_tick, empty_from)
	assert_eq(_state.capture_rate, 0, "frozen")
	assert_eq(_state.progress_at(float(_tick)), progress + 12, "the last tick with the capturer is added")
	var frozen: int = _state.progress_at(float(_tick))
	_tick = empty_from + 299
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.capture_rate, 0, "at 299 ticks it is still frozen")
	assert_eq(_state.progress_at(float(_tick)), frozen)
	_tick = empty_from + 300
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.capture_rate, -4, "at 5 s it starts to decay at -4 per tick")
	assert_eq(_state.progress_at(float(_tick + 100)), frozen - 400)
	# If someone comes back, it resumes and the empty-circle count is cleared.
	_tick += 10
	_state.advance(_def, _tick, _p(0, 1, 0))
	assert_eq(_state.empty_since_tick, FortressState.NO_TICK)
	assert_eq(_state.capture_rate, 12)


func test_an_empty_circle_decays_to_zero_and_the_fort_is_vulnerable_again() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	_tick += 60
	_state.advance(_def, _tick, _p(1, 0, 0))
	_tick += 1
	_state.advance(_def, _tick, _p(0, 0, 0))
	var guard: int = 0
	while _state.phase == FortressState.Phase.CAPTURING and guard < 5000:
		_tick += 1
		_state.advance(_def, _tick, _p(0, 0, 0))
		guard += 1
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE)
	assert_eq(_state.capture_realm, 0)
	assert_eq(_state.empty_since_tick, FortressState.NO_TICK)


func test_everybody_leaving_right_after_the_start_keeps_the_little_progress_and_decays() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	# They leave on the next tick: there is already 12 progress, so it keeps capturing frozen for 5 s and then decays
	# (12 / 4 = 3 ticks) until it returns to VULNERABLE.
	_tick += 1
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_eq(_state.progress_at(float(_tick)), 12)
	_tick += 5 * TPS
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.capture_rate, -4)
	_tick += 3
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE, "at zero and without attackers")


func test_a_capture_frozen_at_zero_with_nobody_inside_goes_back_to_vulnerable_at_once() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	# As if the capture had not advanced at all (e.g. the capturer and the owner arrived together and left).
	_state.capture_rate = 0
	_tick += 1
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE, "progress 0 and no attacker")
	assert_eq(_state.capture_realm, 0)


# --- The formula versus simulating tick by tick -----------------------------------------------

func test_the_formula_matches_a_tick_by_tick_simulation() -> void:
	# Scenario: the captain dies, Vardheim capturers enter in varying numbers, Solmarch arrives (contest and
	# then relief), the circle empties and in the end Vardheim captures.
	var script: Array[Array] = [
		[300, _p(0, 0, 0)], [900, _p(1, 0, 0)], [400, _p(3, 0, 0)], [200, _p(3, 1, 0)],
		[300, _p(0, 2, 0)], [100, _p(0, 0, 0)], [500, _p(0, 0, 0)], [2000, _p(2, 0, 0)],
		[300, _p(2, 0, 1)], [3000, _p(4, 0, 0)],
	]
	_kill_captain()
	var reference: int = 0
	var captured: bool = false
	var checks: int = 0
	var previous_captor: int = 0
	var last_rate: int = 0
	for step: Array in script:
		for _i: int in int(step[0]):
			_tick += 1
			# Full integration of the speed in force during the previous tick.
			reference = clampi(reference + last_rate, 0, _state.progress_max)
			var events: PackedInt32Array = _state.advance(_def, _tick, step[1])
			if _state.phase != FortressState.Phase.CAPTURING or _state.capture_realm != previous_captor:
				# The capture has been anchored anew from zero (new capturer, back to VULNERABLE, capture done).
				if events.has(WarEvents.FORT_CAPTURED):
					assert_eq(reference, _state.progress_max, "the capture completes on reaching the maximum")
				reference = _state.capture_progress_at_start
			previous_captor = _state.capture_realm if _state.phase == FortressState.Phase.CAPTURING else 0
			if _state.phase == FortressState.Phase.CAPTURING:
				assert_eq(_state.progress_at(float(_tick)), reference, "tick %d" % _tick)
				assert_eq(_state.progress_at(float(_tick) + 0.5), clampi(reference + floori(_state.capture_rate * 0.5), 0, _state.progress_max))
				checks += 1
			last_rate = _state.capture_rate if _state.phase == FortressState.Phase.CAPTURING else 0
			if _state.phase == FortressState.Phase.CONSOLIDATING:
				captured = true
				break
		if captured:
			break
	assert_true(captured, "the capture ends up completing")
	assert_true(checks > 3000, "%d ticks were checked" % checks)
	assert_eq(_state.owner, VARDHEIM)


func test_progress_formula_clamps_and_accepts_fractional_ticks() -> void:
	_state.capture_start_tick = 1000
	_state.capture_progress_at_start = 5000
	_state.capture_rate = 12
	assert_eq(_state.progress_at(1000.0), 5000)
	assert_eq(_state.progress_at(1010.0), 5120)
	assert_eq(_state.progress_at(1010.5), 5126, "fractional client tick, rounded down")
	assert_eq(_state.progress_at(999.0), 4988, "backwards too")
	assert_eq(_state.progress_at(100000.0), _state.progress_max, "cap at the maximum")
	_state.capture_rate = -24
	assert_eq(_state.progress_at(1100.0), 2600)
	assert_eq(_state.progress_at(5000.0), 0, "and at zero")
	_state.capture_rate = -4
	assert_eq(_state.progress_at(1000.9), 4996, "rounding down on the way down: 5000 - 3.6 = 4996.4")


# --- CONSOLIDATING ----------------------------------------------------------------------------

func test_consolidation_ends_with_the_new_garrison() -> void:
	_capture_by(VARDHEIM)
	var start: int = _state.phase_tick
	assert_eq(_state.phase, FortressState.Phase.CONSOLIDATING)
	# During consolidation the circle does not count.
	for _i: int in 600:
		_tick += 1
		assert_true(_state.advance(_def, _tick, _p(0, 5, 0)).is_empty())
	assert_eq(_state.phase, FortressState.Phase.CONSOLIDATING)
	assert_false(_state.contested)
	assert_eq(_state.capture_realm, 0)
	_tick = start + 120 * TPS - 1
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.CONSOLIDATING, "one tick earlier")
	_tick = start + 120 * TPS
	var events: PackedInt32Array = _state.advance(_def, _tick, _p(0, 0, 0))
	assert_true(events.is_empty())
	assert_eq(_state.phase, FortressState.Phase.GARRISONED, "after 2 min the garrison arrives")
	assert_true(_state.captain_alive, "with the new owner's captain")
	assert_eq(_state.owner, VARDHEIM)
	assert_eq(_state.phase_tick, _tick)


func test_the_new_owner_can_be_recaptured_after_the_garrison_is_beaten() -> void:
	_capture_by(VARDHEIM)
	_tick += 120 * TPS
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.GARRISONED)
	_tick += 5
	assert_true(_state.on_captain_died(_tick, SOLMARCH).has(WarEvents.CAPTAIN_DOWN))
	_tick += 5
	_state.advance(_def, _tick, _p(0, 1, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_eq(_state.capture_realm, SOLMARCH)
	_tick += 5
	_state.advance(_def, _tick, _p(1, 1, 0))
	assert_true(_state.contested, "the new owner contests")


# --- Reset ------------------------------------------------------------------------------------

func test_reset_to_neutral_from_any_phase() -> void:
	_capture_by(VARDHEIM)
	_state.on_gate_damaged(_tick, 5000, SOLMARCH)
	_state.set_guards_alive(4)
	_tick += 7
	var events: PackedInt32Array = _state.reset_to_neutral(_def, _tick)
	assert_eq(events, PackedInt32Array([WarEvents.FORT_RESET]))
	assert_eq(_state.owner, 0)
	assert_eq(_state.phase, FortressState.Phase.GARRISONED)
	assert_eq(_state.phase_tick, _tick)
	assert_true(_state.captain_alive, "the Ford Captain")
	assert_eq(_state.gate_health, 9000, "full gate")
	assert_eq(_state.capture_realm, 0)
	assert_eq(_state.progress_at(float(_tick)), 0)
	assert_eq(_state.guards_alive, 0)
	assert_eq(_state.under_attack_until_tick, _tick, "no longer attacked")
	assert_eq(_state.last_attack_notice_tick, FortressState.NO_TICK)
	assert_eq(_state.event_realm(WarEvents.FORT_RESET, VARDHEIM), 0, "the reset alert carries realm 0")
	# From the capture in progress, with players inside (they do not move: only the state changes).
	before_each()
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(2, 0, 0))
	_tick += 100
	_state.advance(_def, _tick, _p(2, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	_state.reset_to_neutral(_def, _tick)
	assert_eq(_state.phase, FortressState.Phase.GARRISONED)
	assert_eq(_state.presence[VARDHEIM], 2, "presence is kept")
	_tick += 1
	_state.advance(_def, _tick, _p(2, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.GARRISONED, "with the captain alive it is not captured again")


func test_the_periodic_reset_returns_the_fort_to_neutral_after_30_minutes() -> void:
	_capture_by(VARDHEIM)
	var created: int = 100
	var reset_at: int = created + 1800 * TPS
	_tick = reset_at - 1
	assert_true(_state.advance(_def, _tick, _p(0, 0, 0)).is_empty())
	assert_eq(_state.owner, VARDHEIM, "one tick earlier it is still theirs")
	_tick = reset_at
	var events: PackedInt32Array = _state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(events, PackedInt32Array([WarEvents.FORT_RESET]))
	assert_eq(_state.owner, 0)
	assert_eq(_state.last_reset_tick, reset_at)
	# The next reset, another 30 minutes later.
	_tick = reset_at + 1800 * TPS - 1
	assert_true(_state.advance(_def, _tick, _p(0, 0, 0)).is_empty())
	_tick += 1
	assert_eq(_state.advance(_def, _tick, _p(0, 0, 0)), PackedInt32Array([WarEvents.FORT_RESET]))


func test_without_a_reset_period_the_fort_never_resets_itself() -> void:
	var def: FortressDefinition = _def.duplicate() as FortressDefinition
	def.reset_to_neutral_s = 0.0
	var state: FortressState = FortressState.initial(def, 0)
	state.owner = VARDHEIM
	assert_true(state.advance(def, 10000000, _p(0, 0, 0)).is_empty())
	assert_eq(state.owner, VARDHEIM)


# --- The gate ---------------------------------------------------------------------------------

func test_gate_damage_notices_and_breaking() -> void:
	var events: PackedInt32Array = _state.on_gate_damaged(1000, 2000, SOLMARCH)
	assert_eq(events, PackedInt32Array([WarEvents.UNDER_ATTACK]), "first hit: attack alert")
	assert_eq(_state.gate_health, 7000)
	assert_eq(_state.gate_last_damage_tick, 1000)
	assert_eq(_state.under_attack_until_tick, 1000 + 30 * TPS, "attacked for 30 s")
	assert_eq(_state.event_realm(WarEvents.UNDER_ATTACK, SOLMARCH), SOLMARCH, "the alert carries the attacker")
	# Another hit 10 s later: no alert (at most one per minute) but the "attacked" status is extended.
	assert_true(_state.on_gate_damaged(1600, 1000, SOLMARCH).is_empty())
	assert_eq(_state.under_attack_until_tick, 1600 + 1800)
	# After the minute, another alert.
	assert_eq(_state.on_gate_damaged(1000 + 3600, 1000, VARDHEIM), PackedInt32Array([WarEvents.UNDER_ATTACK]))
	# The hit that breaks it gives the broken-gate alert (and the attack one if due).
	_state.gate_health = 800
	var broken: PackedInt32Array = _state.on_gate_damaged(9000, 5000, SOLMARCH)
	assert_true(broken.has(WarEvents.GATE_BROKEN))
	assert_eq(_state.gate_health, 0)
	assert_true(_state.is_gate_broken())
	# Once broken, it no longer takes damage or raises alerts.
	assert_true(_state.on_gate_damaged(9001, 100, SOLMARCH).is_empty())
	assert_eq(_state.gate_last_damage_tick, 9000)
	# Non-positive damage: nothing.
	var healthy: FortressState = FortressState.initial(_def, 0)
	assert_true(healthy.on_gate_damaged(5, 0, VARDHEIM).is_empty())
	assert_true(healthy.on_gate_damaged(5, -30, VARDHEIM).is_empty())
	assert_eq(healthy.gate_health, 9000)


func test_gate_break_notice_only_when_it_breaks_in_that_hit() -> void:
	var events: PackedInt32Array = _state.on_gate_damaged(500, 20000, VARDHEIM)
	assert_eq(events, PackedInt32Array([WarEvents.UNDER_ATTACK, WarEvents.GATE_BROKEN]), "attack and break at once")
	assert_eq(_state.gate_health, 0, "health does not go below 0")


func test_gate_repair_after_five_minutes_without_damage() -> void:
	assert_false(_state.gate_repair_due(100000), "an intact gate is not repaired")
	_state.on_gate_damaged(1000, 3000, SOLMARCH)
	assert_false(_state.gate_repair_due(1000 + 300 * TPS - 1))
	assert_true(_state.gate_repair_due(1000 + 300 * TPS), "after 5 min without damage")
	# One more hit postpones it another 5 min.
	_state.on_gate_damaged(5000, 100, SOLMARCH)
	assert_false(_state.gate_repair_due(1000 + 300 * TPS))
	assert_true(_state.gate_repair_due(5000 + 300 * TPS))
	_state.repair_gate()
	assert_eq(_state.gate_health, 9000)
	assert_false(_state.gate_repair_due(900000))


func test_defender_damage_marks_the_fort_as_attacked() -> void:
	_state.on_defender_damaged(2000, SOLMARCH)
	assert_eq(_state.under_attack_until_tick, 2000 + 1800)
	_state.on_defender_damaged(2100, SOLMARCH)
	assert_eq(_state.under_attack_until_tick, 2100 + 1800)
	# An old hit (another event thread) does not shorten the deadline.
	_state.on_defender_damaged(2050, SOLMARCH)
	assert_eq(_state.under_attack_until_tick, 2100 + 1800)
	# The "attacked" alert from defenders is granted once per minute.
	assert_true(_state.claim_attack_notice(2100))
	assert_false(_state.claim_attack_notice(2100 + 3599))
	assert_true(_state.claim_attack_notice(2100 + 3600))


# --- Guards -----------------------------------------------------------------------------------

func test_dead_guards_respawn_after_180_seconds() -> void:
	_set_owner(VARDHEIM)
	_state.set_guards_alive(4)
	assert_false(_state.guards_respawn_due(_tick + 100000), "with the full garrison there is nothing to replenish")
	_tick += 50
	_state.set_guards_alive(3)
	_state.advance(_def, _tick + 1, _p(0, 0, 0))
	var due_at: int = _tick + 1 + 180 * TPS
	assert_eq(_state.guards_respawn_tick, due_at, "it is armed on noticing one is missing")
	assert_false(_state.guards_respawn_due(due_at - 1))
	assert_true(_state.guards_respawn_due(due_at))
	# It is replenished: the count is cleared.
	_state.set_guards_alive(4)
	assert_eq(_state.guards_respawn_tick, FortressState.NO_TICK)
	assert_false(_state.guards_respawn_due(due_at + 10))
	# Another dead one later arms a new count without touching the previous one while there are still gaps.
	_state.set_guards_alive(2)
	_state.advance(_def, due_at + 100, _p(0, 0, 0))
	_state.set_guards_alive(1)
	_state.advance(_def, due_at + 200, _p(0, 0, 0))
	assert_eq(_state.guards_respawn_tick, due_at + 100 + 180 * TPS, "the count continues from the first one that fell")


func test_guards_only_respawn_in_garrisoned_and_vulnerable() -> void:
	_set_owner(VARDHEIM)
	_state.set_guards_alive(4)
	_state.set_guards_alive(2)
	_tick += 1
	_state.advance(_def, _tick, _p(0, 0, 0))
	var due_at: int = _state.guards_respawn_tick
	assert_true(_state.guards_respawn_due(due_at), "GARRISONED")
	_kill_captain()
	assert_true(_state.guards_respawn_due(due_at), "VULNERABLE")
	_tick = due_at - 10
	_state.advance(_def, _tick, _p(0, 0, 3))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_false(_state.guards_respawn_due(due_at + 10), "CAPTURING: no")


func test_capture_removes_the_previous_garrison() -> void:
	_set_owner(VARDHEIM)
	_state.set_guards_alive(4)
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(0, 1, 0))
	while _state.phase != FortressState.Phase.CONSOLIDATING:
		_tick += 1
		_state.advance(_def, _tick, _p(0, 1, 0))
	assert_eq(_state.owner, SOLMARCH)
	assert_eq(_state.guards_alive, 0)
	assert_eq(_state.guards_respawn_tick, FortressState.NO_TICK)
	assert_false(_state.guards_respawn_due(_tick + 100000), "no garrison is expected")
	_state.set_guards_alive(4)
	assert_eq(_state.guards_alive, 4)


# --- Presence, fields and copies --------------------------------------------------------------

func test_presence_is_stored_for_the_interface_and_short_arrays_are_padded() -> void:
	_state.advance(_def, 101, PackedInt32Array([0, 3, 5, 1]))
	assert_eq(_state.presence, PackedInt32Array([0, 3, 5, 1]))
	_state.advance(_def, 102, PackedInt32Array([0, 2]))
	assert_eq(_state.presence, PackedInt32Array([0, 2, 0, 0]), "the missing realms, at zero")
	_state.advance(_def, 103, PackedInt32Array())
	assert_eq(_state.presence, PackedInt32Array([0, 0, 0, 0]))
	# It does not keep the same array it is given.
	var counts: PackedInt32Array = PackedInt32Array([0, 1, 0, 0])
	_state.advance(_def, 104, counts)
	counts[1] = 9
	assert_eq(_state.presence[VARDHEIM], 1)


func test_changed_fields_since_lists_exactly_what_changed() -> void:
	var before: FortressState = _state.duplicate_state()
	assert_true(_state.changed_fields_since(before).is_empty(), "no changes, nothing")
	_tick += 10
	_kill_captain()
	var changed: PackedInt32Array = _state.changed_fields_since(before)
	assert_eq(changed, PackedInt32Array([FortressFields.PHASE, FortressFields.PHASE_TICK, FortressFields.CAPTAIN_ALIVE]))
	before = _state.duplicate_state()
	_tick += 5
	_state.advance(_def, _tick, _p(0, 3, 0))
	changed = _state.changed_fields_since(before)
	assert_true(changed.has(FortressFields.PHASE), "switches to CAPTURING")
	assert_true(changed.has(FortressFields.CAPTURE_REALM))
	assert_true(changed.has(FortressFields.CAPTURE_RATE))
	assert_true(changed.has(FortressFields.CAPTURE_START_TICK))
	assert_true(changed.has(FortressFields.PRESENCE_BASE + SOLMARCH), "and Solmarch's presence")
	assert_false(changed.has(FortressFields.OWNER))
	assert_false(changed.has(FortressFields.GATE_HEALTH))
	# Applying the changed fields to the old copy reproduces the new state: this is what the client does.
	for field_id: int in changed:
		assert_true(FortressFields.set_value(before, field_id, FortressFields.get_value(_state, field_id)))
	assert_eq(before.changed_fields_since(_state), PackedInt32Array(), "the client ends up equal to the server")


func test_duplicate_state_is_independent() -> void:
	_kill_captain()
	_state.set_guards_alive(4)
	var copy: FortressState = _state.duplicate_state()
	_tick += 1
	_state.advance(_def, _tick, _p(2, 0, 0))
	_state.on_gate_damaged(_tick, 1000, VARDHEIM)
	assert_eq(copy.phase, FortressState.Phase.VULNERABLE)
	assert_eq(copy.gate_health, 9000)
	assert_eq(copy.presence, PackedInt32Array([0, 0, 0, 0]))
	assert_eq(copy.progress_max, _state.progress_max)
	# The copy keeps working like the original (it keeps the definition's timings).
	assert_eq(copy.on_gate_damaged(10, 100, VARDHEIM), PackedInt32Array([WarEvents.UNDER_ATTACK]))
	assert_eq(copy.under_attack_until_tick, 10 + 1800)


func test_every_decision_is_a_pure_function_of_state_and_presence() -> void:
	# Two states that receive the same thing end up identical, tick by tick.
	var a: FortressState = FortressState.initial(_def, 0)
	var b: FortressState = FortressState.initial(_def, 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	a.on_captain_died(10, VARDHEIM)
	b.on_captain_died(10, VARDHEIM)
	for tick: int in range(11, 6000):
		if tick % 6 == 0 or tick % 6 == 1:
			var counts: PackedInt32Array = _p(rng.randi_range(0, 2), rng.randi_range(0, 2), rng.randi_range(0, 1))
			a.advance(_def, tick, counts)
			b.advance(_def, tick, counts)
		else:
			a.advance(_def, tick, a.presence)
			b.advance(_def, tick, b.presence)
		assert_true(a.changed_fields_since(b).is_empty(), "tick %d" % tick)
		if not a.changed_fields_since(b).is_empty():
			break


# --- Helpers ----------------------------------------------------------------------------------

## Presence count [Vardheim, Solmarch, Askarra].
func _p(vardheim: int, solmarch: int, askarra: int) -> PackedInt32Array:
	return PackedInt32Array([0, vardheim, solmarch, askarra])


## The fort becomes [param realm]'s without a capture (to test the owner).
func _set_owner(realm: int) -> void:
	_state.owner = realm


func _kill_captain() -> void:
	_state.on_captain_died(_tick, SOLMARCH)


## Kills the captain and captures the fort with 4 players of [param realm]; leaves the state at CONSOLIDATING.
func _capture_by(realm: int) -> void:
	_kill_captain()
	var presence: PackedInt32Array = _p(4 if realm == VARDHEIM else 0, 4 if realm == SOLMARCH else 0, 4 if realm == ASKARRA else 0)
	var guard: int = 0
	while _state.phase != FortressState.Phase.CONSOLIDATING and guard < 5000:
		_tick += 1
		_state.advance(_def, _tick, presence)
		guard += 1
	assert_eq(_state.phase, FortressState.Phase.CONSOLIDATING, "the fort is captured")
