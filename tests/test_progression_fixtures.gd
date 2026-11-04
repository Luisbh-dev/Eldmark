extends TestCase
## Tests for the shared cases of the save checks ([SaveFixtures],
## [code]tests/fixtures/progression/save_cases.json[/code]; docs/progression.md §13.3 and §15 P5a): the file in the
## repository matches what [code]tools/progression/write_fixtures.gd[/code] generates with [PlayerProgress], and the
## cases are well formed: at least one per check, valid steps read as a record with
## consistent operations, and S3 and S4 (repeated here as a reference) give what each case says.

const CHECKS: Array[String] = ["S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8"]
const APPLIED: String = "applied"


func _data() -> Dictionary:
	var json: JSON = JSON.new()
	if json.parse(FileAccess.get_file_as_string(SaveFixtures.OUTPUT_PATH)) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


func test_the_file_matches_the_generator() -> void:
	assert_true(FileAccess.file_exists(SaveFixtures.OUTPUT_PATH), "%s exists" % SaveFixtures.OUTPUT_PATH)
	var text: String = SaveFixtures.to_json()
	assert_eq(SaveFixtures.to_json(), text, "two calls give the same result")
	assert_true(FileAccess.get_file_as_string(SaveFixtures.OUTPUT_PATH) == text,
			"%s is up to date (if not, run tools/progression/write_fixtures.gd and commit it)" % SaveFixtures.OUTPUT_PATH)


func test_the_cases_are_well_formed() -> void:
	var data: Dictionary = _data()
	if not assert_false(data.is_empty(), "valid JSON"):
		return
	var keys: Array = data.keys()
	keys.sort()
	assert_eq(keys, ["about", "accounts", "cases", "characters", "format", "id_blocks", "instance_id", "now_unix",
			"world_id", "zone_id"], "the file's keys")
	assert_eq(int(data["format"]), SaveFixtures.FORMAT, "format")
	var characters: Dictionary = {}
	for character: Dictionary in data["characters"]:
		characters[character["character_id"]] = character
		var appearance := PackedByteArray(Marshalls.base64_to_raw(character["appearance"]))
		var decoded: CharacterAppearance = CharacterAppearance.decode(appearance)
		assert_true(decoded != null and decoded.validate(AppearanceCatalog.shared(), int(character["realm"]),
				StringName(character["race_id"])), "the appearance of character %s is valid" % character["character_id"])
	var names: Dictionary = {}
	var expected: Dictionary = {}
	for entry: Dictionary in data["cases"]:
		assert_false(names.has(entry["name"]), "unique name: %s" % entry["name"])
		names[entry["name"]] = true
		assert_false(String(entry["rule"]).is_empty(), "%s explains its rule" % entry["name"])
		for step: Dictionary in entry["steps"]:
			assert_true(characters.has(step["character_id"]), "%s: the character exists" % entry["name"])
			assert_true(step["expect"] == APPLIED or CHECKS.has(step["expect"]), "%s: expect" % entry["name"])
			expected[step["expect"]] = true
	for check: String in CHECKS:
		assert_true(expected.has(check), "at least one case of %s" % check)
	assert_true(expected.has(APPLIED), "and valid ones")
	assert_true(names.has("s5_swapped_definitions"), "with the two uids swapping their def_id (§13.3)")


## Each valid step is the save shape of a record that can be read (with the read-only fields added), its
## operations can be read and use reasons of their type, and it carries no read-only fields.
func test_valid_steps_read_as_records_with_consistent_ops() -> void:
	var data: Dictionary = _data()
	var characters: Dictionary = {}
	for character: Dictionary in data.get("characters", []):
		characters[character["character_id"]] = character
	var count: int = 0
	for entry: Dictionary in data.get("cases", []):
		for step: Dictionary in entry["steps"]:
			if step["expect"] != APPLIED:
				continue
			count += 1
			var progress: Dictionary = (step["progress"] as Dictionary).duplicate(true)
			var label: String = "%s (%s)" % [entry["name"], step["character_id"]]
			for key: String in ProgressRecord.CLAIM_ONLY_KEYS:
				assert_false(progress.has(key), "%s: without %s" % [label, key])
			var ops: Array = progress["ops"]
			progress.erase("ops")
			var character: Dictionary = characters[step["character_id"]]
			for key: String in ProgressRecord.CLAIM_ONLY_KEYS:
				progress[key] = character[key]
			if progress["location"] is Dictionary:
				progress["location"]["saved_at_unix"] = data["now_unix"]
			assert_not_null(ProgressRecord.from_dictionary(progress, null), "%s reads as a record" % label)
			for op_data: Dictionary in ops:
				var op: EconomyOp = EconomyOp.from_dictionary(op_data)
				assert_true(op != null and op.is_consistent(), "%s: operation %s can be read and adds up"
						% [label, op_data["op_id"]])
	assert_true(count >= 10, "there are valid steps (%d)" % count)


## S3 and S4 of §13.3, repeated here as a reference: valid steps satisfy them, those of S3 fail S3, those of S4
## pass S3 and fail S4, and those from S5 onward pass both. That way the label of each case is the first
## check that fails (at least among S3, S4 and the following ones).
func test_s3_and_s4_agree_with_each_case() -> void:
	var data: Dictionary = _data()
	for entry: Dictionary in data.get("cases", []):
		# One base per case and per character: balances, live items by uid and uids that have existed.
		var states: Dictionary = {}
		for step: Dictionary in entry["steps"]:
			var character: String = step["character_id"]
			if not states.has(character):
				states[character] = {"wallets": {1: 0, 2: 0}, "items": {}, "seen": {}}
			var state: Dictionary = states[character]
			var progress: Dictionary = step["progress"]
			var s3: bool = _s3(state, progress)
			var s4: bool = _s4(state, progress)
			var label: String = "%s, paso %s (%s)" % [entry["name"], step["expect"], character]
			match String(step["expect"]):
				APPLIED:
					assert_true(s3 and s4, "%s: satisfies S3 and S4" % label)
					_apply(state, progress)
				"S3":
					assert_false(s3, "%s: fails S3" % label)
				"S4":
					assert_true(s3, "%s: passes S3" % label)
					assert_false(s4, "%s: fails S4" % label)
				"S5", "S6", "S7", "S8":
					assert_true(s3 and s4, "%s: passes S3 and S4" % label)


# S3: per currency and in order, balance_after = previous + delta, in 0 … cap and with the sign of its reason; the last is
# the snapshot's balance; a currency without entries does not change.
func _s3(state: Dictionary, progress: Dictionary) -> bool:
	var balance: Dictionary = (state["wallets"] as Dictionary).duplicate()
	for op: Dictionary in progress["ops"]:
		for entry: Dictionary in op["ledger"]:
			var currency: int = int(entry["currency"])
			var after: int = int(balance.get(currency, 0)) + int(entry["delta"])
			if int(entry["balance_after"]) != after or after < 0 or after > Currency.CAP \
					or not EconomyReason.sign_matches(int(entry["reason"]), int(entry["delta"])):
				return false
			balance[currency] = after
	for wallet: Dictionary in progress["wallets"]:
		if int(wallet["balance"]) != int(balance.get(int(wallet["currency"]), 0)):
			return false
	return true


# S4: per definition, Σ alive in the base + Σ events = Σ of the snapshot; an event with uid and count_delta > 0 is for a uid
# that was not there (for this character); with count_delta < 0, for a live one.
func _s4(state: Dictionary, progress: Dictionary) -> bool:
	var totals: Dictionary = {}
	for item: Dictionary in (state["items"] as Dictionary).values():
		totals[item["def_id"]] = int(totals.get(item["def_id"], 0)) + int(item["count"])
	for op: Dictionary in progress["ops"]:
		for event: Dictionary in op["items"]:
			totals[event["def_id"]] = int(totals.get(event["def_id"], 0)) + int(event["count_delta"])
			if event["uid"] == null:
				continue
			if int(event["count_delta"]) > 0 and (state["seen"] as Dictionary).has(event["uid"]):
				return false
			if int(event["count_delta"]) < 0 and not (state["items"] as Dictionary).has(event["uid"]):
				return false
	var snapshot: Dictionary = {}
	for item: Dictionary in progress["items"]:
		snapshot[item["def_id"]] = int(snapshot.get(item["def_id"], 0)) + int(item["count"])
	for def_id: Variant in totals:
		if int(totals[def_id]) != int(snapshot.get(def_id, 0)):
			return false
	for def_id: Variant in snapshot:
		if not totals.has(def_id):
			return false
	return true


func _apply(state: Dictionary, progress: Dictionary) -> void:
	var wallets: Dictionary = {}
	for wallet: Dictionary in progress["wallets"]:
		wallets[int(wallet["currency"])] = int(wallet["balance"])
	state["wallets"] = wallets
	var items: Dictionary = {}
	for item: Dictionary in progress["items"]:
		items[item["uid"]] = item
		state["seen"][item["uid"]] = true
	state["items"] = items
