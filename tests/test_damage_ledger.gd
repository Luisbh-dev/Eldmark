extends TestCase
## Tests for the [DamageLedger] (docs/combate.md, section 5; GUE-05): the 900-tick window, the
## assist split (at least 10 % of the window's damage), the credit for the last kill and
## what does not count (the environment, self-harm and empty amounts).

const VICTIM: int = 5


func test_records_damage_inside_the_window_only() -> void:
	var ledger := DamageLedger.new(VICTIM)
	ledger.record(100, 1, 50)
	ledger.record(500, 2, 70)
	assert_eq(ledger.total_damage(500), 120, "the two hits within the window")
	assert_eq(ledger.damage_by(1, 500), 50)
	assert_eq(ledger.damage_by(2, 500), 70)
	# The hit at tick 100 leaves the window at 1000 (900 ticks later).
	assert_eq(ledger.total_damage(999), 120, "still inside: 999 - 100 = 899")
	assert_eq(ledger.total_damage(1000), 70, "outside: 1000 - 100 = 900")
	assert_eq(ledger.damage_by(1, 1000), 0)
	assert_eq(ledger.entry_count(1000), 1)
	assert_eq(ledger.total_damage(2000), 0, "all outside")


func test_ignores_the_environment_self_damage_and_empty_amounts() -> void:
	var ledger := DamageLedger.new(VICTIM)
	ledger.record(10, 0, 100)
	ledger.record(10, VICTIM, 100)
	ledger.record(10, 3, 0)
	ledger.record(10, 3, -5)
	assert_eq(ledger.total_damage(10), 0, "neither environment, nor self-harm, nor empty amounts")
	assert_eq(ledger.last_attacker(10), 0)
	ledger.record(10, 3, 5)
	assert_eq(ledger.total_damage(10), 5)


func test_assistants_need_ten_percent_of_the_damage_and_exclude_the_killer() -> void:
	var ledger := DamageLedger.new(VICTIM)
	ledger.record(10, 1, 600)
	ledger.record(20, 2, 300)
	ledger.record(30, 3, 99)
	ledger.record(40, 4, 1)
	# Total 1000: 10 % is 100. The 3 (99) does not make it; the 2 (300) does; the 4 (1) does not.
	assert_eq(ledger.get_assistants(1, 40), PackedInt32Array([2]), "the killer is 1")
	assert_eq(ledger.get_assistants(2, 40), PackedInt32Array([1]), "now the killer is 2")
	ledger.record(50, 3, 1)
	# Total 1001, 10 % is 100.1: the 3 reaches 100 (the exact limit is measured in integers: 100·100 ≥
	# 1001·10 is false).
	assert_eq(ledger.get_assistants(1, 50), PackedInt32Array([2]))
	ledger.record(60, 3, 1)
	# Total 1002; the 3 has 101; 10100 ≥ 10020.
	assert_eq(ledger.get_assistants(1, 60), PackedInt32Array([2, 3]), "by descending damage")


func test_assistants_ordered_by_damage_then_id() -> void:
	var ledger := DamageLedger.new(VICTIM)
	ledger.record(1, 9, 100)
	ledger.record(2, 7, 200)
	ledger.record(3, 8, 200)
	ledger.record(4, 1, 400)
	assert_eq(ledger.get_assistants(1, 4), PackedInt32Array([7, 8, 9]),
			"greater damage first and, at equal damage, lower id")


func test_ten_equal_attackers_are_all_assistants_and_eleven_none() -> void:
	var ledger := DamageLedger.new(VICTIM)
	for attacker_id: int in range(11, 21):
		ledger.record(attacker_id, attacker_id, 100)
	# Each did exactly 10 %: it is the maximum possible number of assisters.
	assert_eq(ledger.get_assistants(99, 30).size(), DamageLedger.MAX_ASSISTANTS, "ten assisters")
	ledger.record(31, 21, 100)
	assert_eq(ledger.get_assistants(99, 31).size(), 0, "with eleven none reaches 10 %")


func test_old_damage_does_not_count_for_assists() -> void:
	var ledger := DamageLedger.new(VICTIM)
	ledger.record(10, 2, 500)
	ledger.record(1000, 3, 100)
	# At tick 1000 the hit from the 10 has already left the window: only the 3's counts.
	assert_eq(ledger.get_assistants(1, 1000), PackedInt32Array([3]))
	assert_eq(ledger.last_attacker(1000), 3)


func test_last_attacker_and_forget_and_clear() -> void:
	var ledger := DamageLedger.new(VICTIM)
	ledger.record(10, 2, 10)
	ledger.record(20, 3, 10)
	assert_eq(ledger.last_attacker(20), 3, "the last to hit")
	ledger.forget_attacker(3)
	assert_eq(ledger.last_attacker(20), 2, "whoever left is forgotten")
	assert_eq(ledger.total_damage(20), 10)
	ledger.clear()
	assert_eq(ledger.total_damage(20), 0)
	assert_eq(ledger.last_attacker(20), 0)


func test_long_fight_keeps_the_ring_bounded() -> void:
	var ledger := DamageLedger.new(VICTIM)
	for tick: int in range(0, 6000):
		ledger.record(tick, 1 + tick % 3, 1)
	# Only the last 900 ticks count.
	assert_eq(ledger.total_damage(5999), 900)
	assert_eq(ledger.entry_count(5999), 900)
	assert_eq(ledger.damage_by(1, 5999) + ledger.damage_by(2, 5999) + ledger.damage_by(3, 5999), 900)
