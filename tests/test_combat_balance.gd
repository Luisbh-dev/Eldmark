extends TestCase
## The balance pass tool ([code]tools/combat_balance.gd[/code], CMB-29; docs/combate.md,
## section 12), which is launched by hand outside the runner.
## [br][br]
## [b]Smoke[/b]: the script loads and can be instantiated, so a syntax error in it breaks the
## suite and is not discovered when launching the full measurement.
## [br][br]
## [b]Process[/b]: a minimal pass (one duel, 2 s of DPS, 2 fights of each size, without the duels with the
## shooter) as a separate process that ends with code 0, no errors in its log and with the figures that are
## checked here against the catalog: the DPS measured against the dummy is the one that comes out of the [code].tres[/code], and
## blocking delays death. [b]Phase 4 kits[/b] (H5; docs/habilidades.md, sections 2.4 and 7.3): the
## bow's DPS is the calculated one (fast, minimum and maximum draw), the dummy at 10, 30 and 50 m receives all the arrows with
## the flight that ballistics dictates, one attacker does not break the shield wall in its 6 s and two do, close to
## the calculated time, and the 2 versus 2 with both templates has casualties.

const TOOL_PATH: String = "res://tools/combat_balance.gd"
## Maximum time to wait for the process (each test lasts less than 30 s).
const MAX_WAIT_SECONDS: float = 25.0

var _pids: Array[int] = []


func after_each() -> void:
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()
	await wait_process_frames()


# --- Smoke -------------------------------------------------------------------------------------

func test_balance_tool_script_loads_and_can_be_instantiated() -> void:
	var script: GDScript = load(TOOL_PATH) as GDScript
	if not assert_not_null(script, "%s loads (a syntax error would leave it null)" % TOOL_PATH):
		return
	assert_true(script.can_instantiate(), "and can be instantiated")
	assert_true(script.get_script_method_list().any(
			func(method: Dictionary) -> bool: return method["name"] == "_initialize"),
			"it is a command-line script (SceneTree._initialize)")


# --- Process ----------------------------------------------------------------------------------

func test_a_minimal_balance_run_matches_the_catalog_and_ends_without_errors() -> void:
	var log_name: String = "test_combat_balance"
	var out_path: String = NetHarness.build_path("%s.json" % log_name)
	DirAccess.remove_absolute(out_path)
	var pid: int = NetHarness.launch_script(TOOL_PATH, PackedStringArray([
		"--duels=1", "--seconds=2", "--team-runs=2", "--no-template-duels", "--out=%s" % out_path]), log_name)
	if not assert_true(pid > 0, "the process launches"):
		return
	_pids.append(pid)
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.1).timeout
	if not assert_false(OS.is_process_running(pid), "the tool finishes on its own in under %d s" \
			% int(MAX_WAIT_SECONDS)):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")
	assert_eq(NetHarness.error_lines(NetHarness.build_path("%s.log" % log_name)), PackedStringArray(),
			"no errors in the log")
	var result: Dictionary = NetHarness.read_report(out_path)
	if not assert_false(result.is_empty(), "it leaves its results JSON"):
		return

	# The DPS measured against the dummy is the one the data says.
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var combo_damage: int = 0
	var combo_ticks: int = 0
	for light_id: int in weapon.light_ids:
		var attack: AttackTicks = CombatCatalog.attack(light_id)
		combo_damage += attack.base_damage
		combo_ticks += attack.total_ticks
	var data: Dictionary = result.get("data", {})
	assert_eq(int((data.get("combo", {}) as Dictionary).get("damage", -1)), combo_damage,
			"the combo in the data table adds the damage of its three light attacks")
	assert_eq(int((data.get("combo", {}) as Dictionary).get("ticks", -1)), combo_ticks, "and its ticks")
	var dps: Dictionary = result.get("dps", {})
	for key: String in ["combo", "light_spam", "heavy_min", "heavy_max"]:
		var measured: Dictionary = dps.get(key, {})
		assert_true(int(measured.get("hits", 0)) > 0, "%s: hits the dummy" % key)
		assert_near(float(measured.get("dps", -1.0)), float(measured.get("expected_dps", -2.0)), 0.5,
				"%s: the measured DPS is the one calculated from the data" % key)
		# The DPS on its own always comes out equal to the calculated one (damage of whole cycles divided by their seconds):
		# what ties it to the data is that each hit lands on the tick it should.
		var hit_ticks: Array = measured.get("hit_ticks", [])
		assert_false(hit_ticks.is_empty(), "%s: the ticks of the hits are recorded" % key)
		assert_eq(hit_ticks, measured.get("expected_hit_ticks", []),
				"%s: each hit lands on the tick the data says" % key)

	# The perfect attacker kills one who does not defend and takes longer against one who blocks.
	var ideal: Dictionary = result.get("ideal", {})
	var still: Dictionary = ideal.get("quieta", {})
	var blocking: Dictionary = ideal.get("bloqueando", {})
	assert_eq(int(still.get("victim_health", -1)), 0, "the still victim dies")
	assert_eq(int(blocking.get("victim_health", -1)), 0, "the one that blocks also ends up dying")
	assert_true(float(blocking.get("ttk_s", 0.0)) > float(still.get("ttk_s", INF)),
			"blocking delays death (%s s versus %s s)" % [blocking.get("ttk_s"), still.get("ttk_s")])
	assert_true(float(blocking.get("guard_break_s", -1.0)) > 0.0, "and the guard ends up breaking")

	# Duels and teams: they are measured and do not stay in tables.
	var duels: Dictionary = result.get("duels", {})
	assert_eq(int(duels.get("duels", -1)), 1, "a duel")
	assert_eq(int(duels.get("decided", 0)) + int(duels.get("draws", 0)), 1, "decided or drawn")
	var teams: Dictionary = result.get("teams", {})
	for key: String in ["2v2", "5v5", "2v2_templates"]:
		var fights: Dictionary = teams.get(key, {})
		assert_true(int(fights.get("fights", 0)) >= 2, "%s: at least 2 fights" % key)
		assert_true(float(fights.get("deaths_per_fight", 0.0)) > 0.0, "%s: there are casualties" % key)
	_check_phase_4_kits(result)


# The phase 4 kits: bow against the dummy, ranges and shield wall (docs/habilidades.md, section 2.4).
func _check_phase_4_kits(result: Dictionary) -> void:
	var bow: Dictionary = result.get("bow", {})
	for key: String in ["quick", "drawn_min", "drawn_max"]:
		var measured: Dictionary = bow.get(key, {})
		assert_true(int(measured.get("shots", 0)) > 0, "bow, %s: fires" % key)
		assert_eq(int(measured.get("hits", -1)), int(measured.get("shots", -2)), "bow, %s: all hit the dummy" % key)
		assert_near(float(measured.get("dps", -1.0)), float(measured.get("expected_dps", -2.0)), 0.5,
				"bow, %s: the measured DPS is the one calculated from the data" % key)
	var expected_bow: Dictionary = (result.get("kit_data", {}) as Dictionary)
	assert_near(float((expected_bow.get("quick", {}) as Dictionary).get("dps", 0.0)), 97.3, 0.05,
			"the fast shot from the sheet: 97.3")
	assert_near(float((expected_bow.get("drawn_min", {}) as Dictionary).get("dps", 0.0)), 125.6, 0.05)
	assert_near(float((expected_bow.get("drawn_max", {}) as Dictionary).get("dps", 0.0)), 131.7, 0.05)
	var ranges: Dictionary = result.get("ranges", {})
	var flights: Dictionary = expected_bow.get("flights", {})
	for distance: String in ["10", "30", "50"]:
		for key: String in ["quick", "drawn_max"]:
			var measured: Dictionary = (ranges.get(distance, {}) as Dictionary).get(key, {})
			assert_eq(int(measured.get("hits", -1)), 5, "at %s m, %s: all 5 arrows hit the dummy" % [distance, key])
			var flight: float = float(((flights.get(distance, {}) as Dictionary).get(key, {}) as Dictionary).get(
					"flight_s", -1.0))
			assert_near(float(measured.get("flight_s", -2.0)), flight, 0.05,
					"at %s m, %s: the flight is the ballistic one (%.2f s)" % [distance, key, flight])
	var wall: Dictionary = result.get("wall", {})
	var wall_data: Dictionary = expected_bow.get("wall", {})
	var one: Dictionary = wall.get("1", {})
	assert_false(bool(one.get("broken", true)), "one attacker does not break the shield wall")
	assert_near(float(one.get("stamina_spent", 0)), float(wall_data.get("one_attacker_stamina", -1000.0)), 60.0,
			"and takes off what was calculated (%s)" % one.get("stamina_spent"))
	var two: Dictionary = wall.get("2", {})
	assert_true(bool(two.get("broken", false)), "two do break it")
	assert_near(float(two.get("break_s", -1.0)), float(wall_data.get("two_attackers_break_s", -10.0)), 0.5,
			"close to the calculated time (%s s)" % two.get("break_s"))
