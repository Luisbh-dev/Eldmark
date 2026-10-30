extends TestCase
## Pruebas de los casos compartidos de las comprobaciones del guardado ([SaveFixtures],
## [code]tests/fixtures/progression/save_cases.json[/code]; docs/progresion.md §13.3 y §15 P5a): el archivo del
## repositorio coincide con lo que genera [code]tools/progression/write_fixtures.gd[/code] con [PlayerProgress], y los
## casos están bien formados: al menos uno por comprobación, los pasos válidos se leen como un registro con
## operaciones coherentes, y S3 y S4 (repetidas aquí como referencia) dan lo que dice cada caso.

const CHECKS: Array[String] = ["S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8"]
const APPLIED: String = "applied"


func _data() -> Dictionary:
	var json: JSON = JSON.new()
	if json.parse(FileAccess.get_file_as_string(SaveFixtures.OUTPUT_PATH)) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


func test_the_file_matches_the_generator() -> void:
	assert_true(FileAccess.file_exists(SaveFixtures.OUTPUT_PATH), "existe %s" % SaveFixtures.OUTPUT_PATH)
	var text: String = SaveFixtures.to_json()
	assert_eq(SaveFixtures.to_json(), text, "dos llamadas dan lo mismo")
	assert_true(FileAccess.get_file_as_string(SaveFixtures.OUTPUT_PATH) == text,
			"%s está al día (si no, ejecuta tools/progression/write_fixtures.gd y súbelo)" % SaveFixtures.OUTPUT_PATH)


func test_the_cases_are_well_formed() -> void:
	var data: Dictionary = _data()
	if not assert_false(data.is_empty(), "JSON válido"):
		return
	var keys: Array = data.keys()
	keys.sort()
	assert_eq(keys, ["about", "accounts", "cases", "characters", "format", "id_blocks", "instance_id", "now_unix",
			"world_id", "zone_id"], "las claves del archivo")
	assert_eq(int(data["format"]), SaveFixtures.FORMAT, "formato")
	var characters: Dictionary = {}
	for character: Dictionary in data["characters"]:
		characters[character["character_id"]] = character
		var appearance := PackedByteArray(Marshalls.base64_to_raw(character["appearance"]))
		var decoded: CharacterAppearance = CharacterAppearance.decode(appearance)
		assert_true(decoded != null and decoded.validate(AppearanceCatalog.shared(), int(character["realm"]),
				StringName(character["race_id"])), "la apariencia del personaje %s vale" % character["character_id"])
	var names: Dictionary = {}
	var expected: Dictionary = {}
	for entry: Dictionary in data["cases"]:
		assert_false(names.has(entry["name"]), "nombre único: %s" % entry["name"])
		names[entry["name"]] = true
		assert_false(String(entry["rule"]).is_empty(), "%s explica su regla" % entry["name"])
		for step: Dictionary in entry["steps"]:
			assert_true(characters.has(step["character_id"]), "%s: el personaje existe" % entry["name"])
			assert_true(step["expect"] == APPLIED or CHECKS.has(step["expect"]), "%s: expect" % entry["name"])
			expected[step["expect"]] = true
	for check: String in CHECKS:
		assert_true(expected.has(check), "al menos un caso de %s" % check)
	assert_true(expected.has(APPLIED), "y válidos")
	assert_true(names.has("s5_swapped_definitions"), "con los dos uids que se cambian el def_id (§13.3)")


## Cada paso válido es la forma del guardado de un registro que se lee (con los campos de solo lectura añadidos), sus
## operaciones se leen y usan motivos de su tipo, y no lleva campos de solo lectura.
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
				assert_false(progress.has(key), "%s: sin %s" % [label, key])
			var ops: Array = progress["ops"]
			progress.erase("ops")
			var character: Dictionary = characters[step["character_id"]]
			for key: String in ProgressRecord.CLAIM_ONLY_KEYS:
				progress[key] = character[key]
			if progress["location"] is Dictionary:
				progress["location"]["saved_at_unix"] = data["now_unix"]
			assert_not_null(ProgressRecord.from_dictionary(progress, null), "%s se lee como registro" % label)
			for op_data: Dictionary in ops:
				var op: EconomyOp = EconomyOp.from_dictionary(op_data)
				assert_true(op != null and op.is_consistent(), "%s: la operación %s se lee y cuadra"
						% [label, op_data["op_id"]])
	assert_true(count >= 10, "hay pasos válidos (%d)" % count)


## S3 y S4 de §13.3, repetidas aquí como referencia: los pasos válidos las cumplen, los de S3 fallan S3, los de S4
## pasan S3 y fallan S4, y los de S5 en adelante pasan las dos. Así la etiqueta de cada caso es la primera
## comprobación que falla (al menos entre S3, S4 y las siguientes).
func test_s3_and_s4_agree_with_each_case() -> void:
	var data: Dictionary = _data()
	for entry: Dictionary in data.get("cases", []):
		# Una base por caso y por personaje: saldos, objetos vivos por uid y uids que han existido.
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
					assert_true(s3 and s4, "%s: cumple S3 y S4" % label)
					_apply(state, progress)
				"S3":
					assert_false(s3, "%s: falla S3" % label)
				"S4":
					assert_true(s3, "%s: pasa S3" % label)
					assert_false(s4, "%s: falla S4" % label)
				"S5", "S6", "S7", "S8":
					assert_true(s3 and s4, "%s: pasa S3 y S4" % label)


# S3: por moneda y en orden, balance_after = anterior + delta, en 0 … tope y con el signo de su motivo; el último es
# el saldo de la foto; una moneda sin apuntes no cambia.
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


# S4: por definición, Σ vivas en la base + Σ eventos = Σ de la foto; un evento con uid y count_delta > 0 es de un uid
# que no estaba (para este personaje); con count_delta < 0, de uno vivo.
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
