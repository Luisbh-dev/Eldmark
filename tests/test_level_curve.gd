extends TestCase
## Tests for the level curve ([LevelCurve], [code]data/progression/level_curve.tres[/code]) and for
## levelling up ([ProgressionRules]; docs/progression.md §6, PRG-13): 39 increasing values, the §6.1 table,
## [code]level_for(total_to(n)) = n[/code], several level-ups from a single contribution and the cap.


func _curve() -> LevelCurve:
	return LevelCurve.shared()


func test_resource_is_text_and_valid() -> void:
	var text: String = FileAccess.get_file_as_string(LevelCurve.PATH)
	assert_true(text.begins_with("[gd_resource"), "%s is in text format" % LevelCurve.PATH)
	var curve: LevelCurve = _curve()
	assert_eq(curve.resource_path, LevelCurve.PATH, "shared() loads the repository's resource")
	assert_eq(curve.get_errors(), PackedStringArray(), "the curve has no errors")
	assert_eq(curve.level_cap, 40, "cap 40 (§6.1)")
	assert_eq(curve.attribute_points_per_level, 1, "one attribute point per level")


func test_39_increasing_values() -> void:
	var values: PackedInt32Array = _curve().xp_to_next
	assert_eq(values.size(), 39, "39 values, from level 1 to 39")
	for i: int in range(1, values.size()):
		assert_true(values[i] > values[i - 1], "xp_to_next[%d] = %d > %d" % [i, values[i], values[i - 1]])


## The §6.1 table and the formula it was generated with (the data is the table: if a figure is touched up by hand,
## this formula check is changed along with it).
func test_table_of_the_document() -> void:
	var curve: LevelCurve = _curve()
	var expected: Dictionary[int, Array] = {1: [500, 500], 5: [1880, 5350], 10: [5550, 25060],
			20: [17180, 140320], 39: [51050, 783780]}
	for level: int in expected:
		assert_eq(curve.xp_for_next(level), expected[level][0], "XP from level %d to the next" % level)
		assert_eq(curve.total_to(level + 1), expected[level][1], "total XP to reach %d" % (level + 1))
	for level: int in range(1, 40):
		var generated: int = roundi((500.0 + 150.0 * pow(level - 1, 1.6)) / 10.0) * 10
		assert_eq(curve.xp_to_next[level - 1], generated, "level %d: the §6.1 formula" % level)


func test_level_for_total_to() -> void:
	var curve: LevelCurve = _curve()
	assert_eq(curve.total_to(1), 0, "level 1 starts at 0")
	assert_eq(curve.level_for(0), 1, "0 XP is level 1")
	assert_eq(curve.level_for(-5), 1, "negative, level 1")
	for level: int in range(1, 41):
		assert_eq(curve.level_for(curve.total_to(level)), level, "level_for(total_to(%d))" % level)
		if level > 1:
			assert_eq(curve.level_for(curve.total_to(level) - 1), level - 1,
					"one point before reaching %d it is still %d" % [level, level - 1])
	assert_eq(curve.level_for(curve.total_to(40) + 1_000_000), 40, "above the cap, the cap")
	assert_eq(curve.total_to(41), curve.total_to(40), "total_to above the cap is the cap's")
	assert_eq(curve.total_to(0), 0, "total_to below 1 is 0")
	assert_eq(curve.xp_for_next(40), 0, "at the cap there is no next")


func test_one_gain_several_levels() -> void:
	var curve: LevelCurve = _curve()
	# From 1 to 6 at once: exactly 5350 XP.
	var result: ProgressionRules.XpResult = ProgressionRules.add_xp(curve, 1, 0, 5350)
	assert_eq(result.level, 6, "5350 XP lead to level 6")
	assert_eq(result.levels_gained, 5, "five levels from a single contribution")
	assert_eq(result.applied, 5350, "all of it is applied")
	assert_eq(result.xp_total, 5350, "total")
	# Mid-level: 8 with 12345 (the §3.4 example) and 20000 more.
	assert_eq(curve.level_for(12345), 8, "12345 XP is level 8 (§3.4)")
	result = ProgressionRules.add_xp(curve, 8, 12345, 20000)
	assert_eq(result.xp_total, 32345, "sum")
	assert_eq(result.level, curve.level_for(32345), "recalculated level")
	assert_eq(result.levels_gained, result.level - 8, "levels gained")
	assert_true(result.levels_gained >= 2, "several level-ups (%d)" % result.levels_gained)
	# Without levelling up.
	result = ProgressionRules.add_xp(curve, 1, 0, 499)
	assert_eq([result.level, result.levels_gained, result.applied], [1, 0, 499], "499 does not rise from 1")


func test_cap() -> void:
	var curve: LevelCurve = _curve()
	var cap_total: int = curve.total_to(40)
	var result: ProgressionRules.XpResult = ProgressionRules.add_xp(curve, 40, cap_total, 500)
	assert_eq([result.level, result.xp_total, result.applied, result.levels_gained], [40, cap_total, 0, 0],
			"at the cap 0 is applied and the total stays")
	result = ProgressionRules.add_xp(curve, 39, cap_total - 100, 500)
	assert_eq([result.level, result.xp_total, result.applied, result.levels_gained], [40, cap_total, 100, 1],
			"near the cap only what is missing is applied")
	result = ProgressionRules.add_xp(curve, 1, 0, 10_000_000)
	assert_eq([result.level, result.xp_total, result.applied, result.levels_gained],
			[40, cap_total, cap_total, 39], "a huge contribution reaches the cap from 1")
	result = ProgressionRules.add_xp(curve, 40, cap_total + 999, 10)
	assert_eq([result.level, result.xp_total, result.applied], [40, cap_total, 0],
			"a total above the cap is brought to the cap (I8)")


func test_non_positive_gain_applies_nothing() -> void:
	var curve: LevelCurve = _curve()
	for amount: int in [0, -1, -100000]:
		var result: ProgressionRules.XpResult = ProgressionRules.add_xp(curve, 3, 1200, amount)
		assert_eq([result.level, result.xp_total, result.applied, result.levels_gained], [3, 1200, 0, 0],
				"add_xp(%d) changes nothing" % amount)


func test_attribute_points() -> void:
	var curve: LevelCurve = _curve()
	assert_eq(ProgressionRules.attribute_points(curve, 1, 0), 0, "level 1, none")
	assert_eq(ProgressionRules.attribute_points(curve, 10, 0), 9, "level 10, 9")
	assert_eq(ProgressionRules.attribute_points(curve, 10, 4), 5, "minus the spent ones")
	assert_eq(ProgressionRules.attribute_points(curve, 10, 20), 0, "never less than 0")
	assert_eq(ProgressionRules.attribute_points(curve, 99, 0), 39, "above the cap, those of the cap")
	assert_eq(ProgressionRules.XP_PER_MERIT, 10, "10 XP per merit (§6.2)")


func test_errors_of_a_broken_curve() -> void:
	var curve := LevelCurve.new()
	curve.level_cap = 4
	curve.xp_to_next = PackedInt32Array([100, 0])
	var errors: PackedStringArray = curve.get_errors()
	assert_eq(errors.size(), 2, "values are missing and there is a 0: %s" % [errors])
	# Without enough data it does not go past what is there.
	assert_eq(curve.level_for(1_000_000), 3, "with two steps it reaches 3")
	assert_eq(curve.total_to(4), 100, "total_to adds up only what is there")
