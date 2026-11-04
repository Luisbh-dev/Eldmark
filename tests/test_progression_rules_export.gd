extends TestCase
## Tests for the rules exported for the platform ([ProgressionRulesExport];
## docs/progresion.md §13.4, docs/plataforma.md §4.4): [method ProgressionRulesExport.build] is
## deterministic and the repository file, the one the Go platform embeds, matches it.
## It is the file's only test: each document adds the checks for its sections here.


func test_build_is_deterministic() -> void:
	var first: String = JSON.stringify(ProgressionRulesExport.build(), "\t", true)
	var second: String = JSON.stringify(ProgressionRulesExport.build(), "\t", true)
	assert_eq(second, first, "two calls to build() give the same result")
	assert_eq(ProgressionRulesExport.to_json(), first + "\n", "to_json is build() with a trailing newline")


func test_file_matches_build() -> void:
	var path: String = ProgressionRulesExport.OUTPUT_PATH
	assert_true(FileAccess.file_exists(path), "%s exists" % path)
	var text: String = FileAccess.get_file_as_string(path)
	assert_true(text == ProgressionRulesExport.to_json(),
			"%s is up to date (if not, run tools/progression/export_rules.gd and commit it)" % path)


func test_file_is_valid_json_with_sorted_keys() -> void:
	var json: JSON = JSON.new()
	assert_eq(json.parse(FileAccess.get_file_as_string(ProgressionRulesExport.OUTPUT_PATH)), OK, "valid JSON")
	var data: Dictionary = json.data
	var keys: Array = data.keys()
	var sorted: Array = keys.duplicate()
	sorted.sort()
	assert_eq(keys, sorted, "sorted keys")
	assert_true(data.has("protocol_version") and data.has("names"), "sections of plataforma.md")


func test_protocol_version_section() -> void:
	assert_eq(ProgressionRulesExport.build()["protocol_version"], NetProtocol.PROTOCOL_VERSION,
			"protocol_version is NetProtocol's")


func test_names_section() -> void:
	var names: Dictionary = ProgressionRulesExport.build()["names"]
	var expected_keys: Array = ["folded", "lower_letters", "max_length", "min_length", "reserved", "upper_letters"]
	var keys: Array = names.keys()
	keys.sort()
	assert_eq(keys, expected_keys, "the keys of the names section (plataforma.md §4.4)")
	assert_eq(names["min_length"], NameRules.MIN_LENGTH, "min_length")
	assert_eq(names["max_length"], NameRules.MAX_LENGTH, "max_length")
	assert_eq(names["upper_letters"], NameRules.UPPER_LETTERS, "upper_letters")
	assert_eq(names["lower_letters"], NameRules.LOWER_LETTERS, "lower_letters")
	assert_eq(String(names["upper_letters"]).length(), String(names["lower_letters"]).length(),
			"uppercase and lowercase in the same order")
	assert_eq(names["folded"], NameRules.FOLDED, "folded")
	assert_eq(Array(names["reserved"]), Array(NameRules.RESERVED), "reserved, as written")


# --- Sections of progresion.md (P3) ---------------------------------------------------------------

## The sections of progresion.md §13.4, all since P1 ([code]items[/code] and [code]starter_templates[/code]).
func test_progression_sections_present() -> void:
	var data: Dictionary = ProgressionRulesExport.build()
	for section: String in ["races", "appearance", "level_curve", "currencies", "reasons", "containers", "combat",
			"items", "starter_templates"]:
		assert_true(data.has(section), "section %s (progresion.md §13.4)" % section)
	var keys: Array = data.keys()
	keys.sort()
	assert_eq(keys, ["appearance", "combat", "containers", "currencies", "items", "level_curve", "names",
			"protocol_version", "races", "reasons", "starter_templates"], "no more and no fewer sections")


## The three races, in catalog order, with the realm as a code and the entire appearance rule.
func test_races_section() -> void:
	var races: Array = ProgressionRulesExport.build()["races"]
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	assert_eq(races.size(), catalog.races.size(), "one entry per race in the catalog")
	var expected_ids: Array = ["race_vardheim", "race_solmarch", "race_askarra"]
	var expected_realms: Array = [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH, NetProtocol.Realm.ASKARRA]
	for i: int in range(races.size()):
		var entry: Dictionary = races[i]
		var keys: Array = entry.keys()
		keys.sort()
		assert_eq(keys, ["allows_no_beard", "allows_no_hair", "beards", "bodies", "eye_colors", "hair_colors",
				"hairs", "heads", "id", "marks", "realm", "skin_tones"], "keys of races[%d]" % i)
		assert_eq(entry["id"], expected_ids[i],
				"races[%d] is %s (byte 0 is its position + 1)" % [i, expected_ids[i]])
		assert_eq(entry["realm"], expected_realms[i], "%s: realm in NetProtocol.Realm's code" % entry["id"])
		var race: RaceDefinition = catalog.races[i]
		assert_eq(entry["allows_no_hair"], race.allows_no_hair, "%s: allows_no_hair" % race.id)
		assert_eq(entry["allows_no_beard"], race.allows_no_beard, "%s: allows_no_beard" % race.id)
		for category: StringName in AppearanceCatalog.PART_CATEGORIES + AppearanceCatalog.COLOR_CATEGORIES:
			assert_eq(entry[String(category)], Array(race.allowed(category)), "%s: %s" % [race.id, category])


func test_appearance_section() -> void:
	var appearance: Dictionary = ProgressionRulesExport.build()["appearance"]
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	assert_eq(appearance["body_count"], catalog.bodies.size(), "bodies")
	assert_eq(appearance["skin_tone_count"], catalog.skin_tones.size(), "skin tones")
	assert_eq(appearance["hair_color_count"], catalog.hair_colors.size(), "hair colors")
	assert_eq(appearance["eye_color_count"], catalog.eye_colors.size(), "eye colors")
	for category: StringName in [&"heads", &"hairs", &"beards", &"marks"]:
		var parts: Array = appearance[String(category)]
		var catalog_parts: Array = catalog.entries(category)
		assert_eq(parts.size(), catalog_parts.size(), "%s: one entry per piece" % category)
		for i: int in range(mini(parts.size(), catalog_parts.size())):
			assert_eq(parts[i], {"id": String(catalog_parts[i].id), "bodies": Array(catalog_parts[i].bodies)},
					"%s[%d]: id and compatible bodies" % [category, i])


func test_level_curve_section() -> void:
	var curve: Dictionary = ProgressionRulesExport.build()["level_curve"]
	assert_eq(curve["level_cap"], 40, "cap 40")
	assert_eq(Array(curve["xp_to_next"]), Array(LevelCurve.shared().xp_to_next), "the curve's table")
	assert_eq(curve["xp_to_next"].size(), 39, "39 values")
	assert_eq(curve["attribute_points_per_level"], 1, "one point per level")


## Currency caps, reason ranges and operation types from §5.1 and §5.3.
func test_currencies_reasons_containers_combat() -> void:
	var data: Dictionary = ProgressionRulesExport.build()
	assert_eq(data["currencies"], [{"code": 1, "id": "gold", "cap": 1000000000},
			{"code": 2, "id": "merits", "cap": 1000000000}], "gold and merits capped at a billion")
	var reasons: Dictionary = data["reasons"]
	assert_eq(reasons["ranges"], {"source": {"min": 1, "max": 63}, "sink": {"min": 64, "max": 127},
			"internal": {"min": 128, "max": 191}}, "ranges from §5.3")
	var codes: Dictionary = reasons["codes"]
	var by_code: Dictionary = {}
	for reason: String in codes:
		var code: int = codes[reason]
		assert_false(by_code.has(code), "code %d is not repeated (%s, %s)" % [code, reason, by_code.get(code, "")])
		by_code[code] = reason
		assert_true((code >= 1 and code <= 191), "%s: %d is in some range" % [reason, code])
	assert_eq([codes["starter_kit"], codes["camp_refill"], codes["pvp_kill"], codes["npc_kill"], codes["gm_grant"],
			codes["player_destroy"], codes["consume"], codes["gm_remove"], codes["reversal"], codes["migration"]],
			[1, 2, 3, 6, 7, 64, 65, 66, 128, 129], "the phase 5 reasons")
	assert_eq(reasons["op_kinds"], {"player": 1, "gameplay": 2, "starter_kit": 3, "gm": 4, "reversal": 5,
			"migration": 6, "trade": 7, "mail": 8}, "operation types")
	assert_eq(data["containers"], {"bag": {"code": 0, "default_slots": 30, "max_slots": 120},
			"equipment": {"code": 1, "slots": 7, "open_slots": 2}, "open": [0, 1]}, "containers from §4.1")
	assert_eq(data["combat"], {"health_max": CombatCatalog.rules().health_max}, "CombatRules' maximum health")


# --- Sections of progresion.md (P1) ---------------------------------------------------------------

## One entry per ItemDatabase definition, in net id order, with what S5 looks at.
func test_items_section() -> void:
	var items: Array = ProgressionRulesExport.build()["items"]
	var db: ItemDatabase = ItemDatabase.shared()
	var ids: Array[StringName] = db.all_ids()
	assert_eq(items.size(), ids.size(), "one entry per item")
	for i: int in range(mini(items.size(), ids.size())):
		var definition: ItemDefinition = db.get_definition(ids[i])
		assert_eq(items[i], {"id": String(definition.id), "category": int(definition.category),
				"equip_slot": int(definition.equip_slot), "max_stack": definition.max_stack,
				"has_durability": definition.has_durability, "required_level": definition.required_level},
				"items[%d] is %s (net id %d)" % [i, ids[i], i + 1])
	assert_eq(items[0]["id"], "bow_vado", "the bow first (alphabetical)")
	assert_eq(items[1], {"id": "potion_health", "category": 3, "equip_slot": 0, "max_stack": 15,
			"has_durability": false, "required_level": 1}, "the health potion with the numbers from §2.1")


## The selectable templates (today marksman and squire) with their weapon items in slot order.
func test_starter_templates_section() -> void:
	var templates: Array = ProgressionRulesExport.build()["starter_templates"]
	assert_eq(templates, [{"id": "marksman", "weapons": ["bow_vado", "sword_shield_vado"]},
			{"id": "squire", "weapons": ["sword_shield_vado"]}], "marksman and squire with their weapons")
	var selectable: Array[String] = []
	for template: EquipmentTemplate in CombatCatalog.tables().templates:
		if template.selectable:
			selectable.append(String(template.id))
	var exported: Array[String] = []
	for entry: Dictionary in templates:
		exported.append(String(entry["id"]))
		for item_id: String in entry["weapons"]:
			var item: ItemDefinition = ItemDatabase.shared().get_definition(StringName(item_id))
			assert_true(item != null and item.category == ItemDefinition.Category.WEAPON,
					"%s: %s is an ItemDatabase weapon" % [entry["id"], item_id])
	assert_eq(exported, selectable, "all the selectable ones and only those")
