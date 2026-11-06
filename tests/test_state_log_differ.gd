extends TestCase
## Tests of [StateLogDiffer]: identical lines, last-bit float noise, larger differences and unpaired lines.

# Two 32-bit words in little endian: 1.0 and 2.0.
const BASE: String = "0000803f00000040"
# The first word one unit higher: the last bit of the float.
const NEXT_BIT: String = "0100803f00000040"
# The first word 8 units higher: drift.
const DRIFT: String = "0800803f00000040"
# The first word changed a lot.
const FAR: String = "0000c03f00000040"


func _log(entries: Array) -> String:
	var lines: PackedStringArray = PackedStringArray()
	for entry: Array in entries:
		lines.append("%d,%d,0,%s" % [entry[0], entry[1], entry[2]])
	return "\n".join(lines) + "\n"


func test_identical_logs() -> void:
	var text: String = _log([[1, 5, BASE], [2, 5, BASE]])
	var result: StateLogDiffer.Result = StateLogDiffer.compare_texts(text, text)
	assert_true(result.is_exact())
	assert_eq(result.compared, 2)
	assert_eq(result.identical, 2)
	assert_eq(result.first_difference_tick, -1)
	assert_eq(result.players_diverged, 0)


func test_last_bit_differences_are_counted_and_the_first_one_of_a_player_is_kept() -> void:
	var a: String = _log([[1, 5, BASE], [2, 5, BASE], [3, 5, BASE]])
	var b: String = _log([[1, 5, BASE], [2, 5, NEXT_BIT], [3, 5, BASE]])
	var result: StateLogDiffer.Result = StateLogDiffer.compare_texts(a, b)
	assert_true(result.is_comparable())
	assert_false(result.is_exact())
	assert_eq(result.last_bit, 1)
	assert_eq(result.drift, 0)
	assert_eq(result.first_difference_tick, 2)
	assert_eq(result.first_larger_tick, -1)
	assert_true(absf(result.last_bit_rate() - 1.0 / 3.0) < 0.0001)
	assert_eq(result.players_diverged, 1)
	assert_eq(result.players_diverged_by_last_bit, 1)
	assert_eq(result.first_divergences, ["net_id 5: tick 2, 1 ulps"] as Array[String])


func test_drift_and_larger_differences_are_told_apart() -> void:
	var a: String = _log([[1, 5, BASE], [2, 5, BASE], [3, 6, BASE]])
	var b: String = _log([[1, 5, DRIFT], [2, 5, FAR], [3, 6, BASE]])
	var result: StateLogDiffer.Result = StateLogDiffer.compare_texts(a, b)
	assert_eq(result.drift, 1)
	assert_eq(result.larger, 1)
	assert_eq(result.first_larger_tick, 2)
	assert_eq(result.players_total, 2)
	assert_eq(result.players_diverged, 1)
	assert_eq(result.players_diverged_by_last_bit, 0, "it started as a drift, not as a last bit")


func test_unpaired_lines_make_the_logs_not_comparable() -> void:
	var a: String = _log([[1, 5, BASE], [2, 5, BASE]])
	var b: String = _log([[1, 5, BASE], [2, 6, BASE]])
	var result: StateLogDiffer.Result = StateLogDiffer.compare_texts(a, b)
	assert_false(result.is_comparable())
	assert_eq(result.unpaired, 2)


func test_empty_or_missing_logs_are_an_error() -> void:
	assert_false(StateLogDiffer.compare_texts("", "x").error.is_empty())
	assert_false(StateLogDiffer.compare_files("user://nope_a.txt", "user://nope_b.txt").error.is_empty())
