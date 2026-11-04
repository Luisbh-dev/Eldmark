extends TestCase
## Tests of appearance ([CharacterAppearance], [AppearanceCatalog], [RaceDefinition];
## docs/progression.md §7, ART-19, PRG-14): round trip of the 8 B, the cases shared with Go
## ([code]tests/fixtures/progression/appearance_cases.json[/code], which [code]platform/internal/progress[/code]
## also reads), each rule of [method CharacterAppearance.validate], 100
## random valid appearances per race, the frozen order of [code]appearance_ids.txt[/code], the
## catalog's scenes and no racial stats.

## Cases shared with Go: [code][{case, realm, race_id, appearance, valid}][/code], with the realm as
## its code (1-3) and the appearance in base64, as in the API.
const SHARED_CASES_PATH: String = "res://tests/fixtures/progression/appearance_cases.json"
const RACES_DIR: String = "res://data/characters/races"


func _catalog() -> AppearanceCatalog:
	return AppearanceCatalog.shared()


## A valid Vardheim appearance (that of [method CharacterAppearance.default_for]).
func _vardheim() -> CharacterAppearance:
	return CharacterAppearance.default_for(_catalog(), _catalog().race_index(&"race_vardheim"))


func test_round_trip_of_8_bytes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 19
	for i: int in range(200):
		var bytes := PackedByteArray()
		for j: int in range(CharacterAppearance.ENCODED_SIZE):
			bytes.append(rng.randi_range(0, 255))
		var appearance: CharacterAppearance = CharacterAppearance.decode(bytes)
		assert_not_null(appearance, "any 8 B are read")
		assert_eq(appearance.encode(), bytes, "encode(decode(b)) = b")
		assert_true(appearance.equals(CharacterAppearance.decode(appearance.encode())), "decode(encode(a)) = a")
	var known := CharacterAppearance.new()
	known.race = 3
	known.body = 1
	known.head = 2
	known.hair = 4
	known.beard = 5
	known.skin = 6
	known.hair_color = 7
	known.eyes = 9
	known.marks = 12
	assert_eq(known.encode(), PackedByteArray([3, 1, 2, 4, 5, 6, 7, 0xC9]),
			"byte order and byte 7 (eyes low, marks high)")
	var decoded: CharacterAppearance = CharacterAppearance.decode(PackedByteArray([3, 1, 2, 4, 5, 6, 7, 0xC9]))
	assert_eq([decoded.race, decoded.body, decoded.head, decoded.hair, decoded.beard, decoded.skin,
			decoded.hair_color, decoded.eyes, decoded.marks], [3, 1, 2, 4, 5, 6, 7, 9, 12], "field by field")


func test_decode_rejects_other_sizes() -> void:
	for size: int in [0, 1, 7, 9, 16]:
		var bytes := PackedByteArray()
		bytes.resize(size)
		assert_null(CharacterAppearance.decode(bytes), "%d B is not an appearance" % size)


func test_shared_cases_with_go() -> void:
	var json := JSON.new()
	assert_eq(json.parse(FileAccess.get_file_as_string(SHARED_CASES_PATH)), OK, "%s is JSON" % SHARED_CASES_PATH)
	var cases: Array = json.data
	assert_true(cases.size() >= 30, "there are cases to check (%d)" % cases.size())
	var valid_count: int = 0
	for entry: Dictionary in cases:
		var keys: Array = entry.keys()
		keys.sort()
		assert_eq(keys, ["appearance", "case", "race_id", "realm", "valid"], "keys of case %s" % entry)
		var bytes: PackedByteArray = Marshalls.base64_to_raw(entry["appearance"])
		var appearance: CharacterAppearance = CharacterAppearance.decode(bytes)
		var valid: bool = appearance != null and appearance.validate(_catalog(), int(entry["realm"]),
				StringName(entry["race_id"]))
		assert_eq(valid, entry["valid"], "case \"%s\" (%s)" % [entry["case"], entry["appearance"]])
		if entry["valid"]:
			valid_count += 1
	assert_true(valid_count >= 5 and valid_count < cases.size(), "there are valid and invalid cases")


func test_validate_rejects_each_index_out_of_range() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var base: CharacterAppearance = _vardheim()
	assert_true(base.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_vardheim"), "the base is valid")
	var limits: Dictionary[StringName, int] = {
		&"race": catalog.races.size() + 1, &"body": catalog.bodies.size(), &"head": catalog.heads.size(),
		&"hair": catalog.hairs.size() + 1, &"beard": catalog.beards.size() + 1,
		&"skin": catalog.skin_tones.size(), &"hair_color": catalog.hair_colors.size(),
		&"eyes": catalog.eye_colors.size(), &"marks": catalog.marks.size() + 1,
	}
	for field: StringName in limits:
		for value: int in [limits[field], 255, -1]:
			var changed: CharacterAppearance = CharacterAppearance.decode(base.encode())
			changed.set(field, value)
			assert_false(changed.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_vardheim"),
					"%s = %d is out of range" % [field, value])


func test_validate_race_and_realm() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var vardheim: CharacterAppearance = _vardheim()
	assert_false(vardheim.validate(catalog, NetProtocol.Realm.SOLMARCH, &"race_vardheim"),
			"the race of another realm")
	assert_false(vardheim.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_solmarch"),
			"a byte 0 that is not race_id's")
	assert_false(vardheim.validate(catalog, NetProtocol.Realm.NONE, &"race_vardheim"), "realm 0")
	assert_false(vardheim.validate(catalog, 7, &"race_vardheim"), "a realm that does not exist")
	assert_false(vardheim.validate(null, NetProtocol.Realm.VARDHEIM, &"race_vardheim"), "without a catalog")
	var solmarch_index: int = catalog.race_index(&"race_solmarch")
	var solmarch: CharacterAppearance = CharacterAppearance.default_for(catalog, solmarch_index)
	assert_true(solmarch.validate(catalog, NetProtocol.Realm.SOLMARCH, &"race_solmarch"), "solmarch is valid")
	solmarch.race = vardheim.race
	assert_false(solmarch.validate(catalog, NetProtocol.Realm.SOLMARCH, &"race_solmarch"),
			"byte 0 of another race")


func test_validate_no_hair_or_beard_only_if_allowed() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var vardheim: RaceDefinition = catalog.races[catalog.race_index(&"race_vardheim")]
	var solmarch: RaceDefinition = catalog.races[catalog.race_index(&"race_solmarch")]
	assert_false(vardheim.allows_no_hair or vardheim.allows_no_beard, "Vardheim does not allow going without hair or beard")
	assert_true(solmarch.allows_no_hair and solmarch.allows_no_beard, "Solmarch allows both")
	var bald: CharacterAppearance = _vardheim()
	bald.hair = CharacterAppearance.NONE
	assert_false(bald.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_vardheim"), "no hair in Vardheim")
	var shaven: CharacterAppearance = _vardheim()
	shaven.beard = CharacterAppearance.NONE
	assert_false(shaven.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_vardheim"), "no beard in Vardheim")
	var monk: CharacterAppearance = CharacterAppearance.default_for(catalog, catalog.race_index(&"race_solmarch"))
	monk.hair = CharacterAppearance.NONE
	monk.beard = CharacterAppearance.NONE
	assert_true(monk.validate(catalog, NetProtocol.Realm.SOLMARCH, &"race_solmarch"), "no hair or beard in Solmarch")


## The body rule, with a two-body catalog (the repository's has only one, §16).
func test_validate_part_of_another_body() -> void:
	var catalog: AppearanceCatalog = _two_body_catalog()
	assert_eq(catalog.get_errors(), PackedStringArray(), "the test catalog is valid")
	var appearance := CharacterAppearance.new()
	appearance.race = 1
	appearance.body = 0
	appearance.head = 0
	appearance.hair = 1
	appearance.beard = 1
	assert_true(appearance.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"), "body 0 with its pieces")
	appearance.head = 1
	assert_false(appearance.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"),
			"a head of body 1 with body 0")
	appearance.body = 1
	appearance.beard = 0
	assert_true(appearance.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"),
			"body 1 with its head, everyone's hair and no beard")
	appearance.beard = 1
	assert_false(appearance.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"),
			"a beard of body 0 with body 1")
	appearance.beard = 0
	appearance.marks = 1
	assert_false(appearance.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"),
			"marks of body 0 with body 1")
	appearance.body = 0
	appearance.head = 0
	appearance.beard = 1
	assert_true(appearance.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"), "and with body 0, yes")
	# Random ones from the test catalog: they always fit.
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i: int in range(100):
		var random: CharacterAppearance = CharacterAppearance.random(catalog, 0, rng)
		assert_true(random.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"), "random %s" % random)


func test_100_random_valid_per_race() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	for race_index: int in range(catalog.races.size()):
		var race: RaceDefinition = catalog.races[race_index]
		var realm: int = RealmCatalog.code_of(race.realm)
		var seen: Dictionary[String, bool] = {}
		for i: int in range(100):
			var appearance: CharacterAppearance = CharacterAppearance.random(catalog, race_index, rng)
			assert_true(appearance.validate(catalog, realm, race.id), "%s: random %s" % [race.id, appearance])
			seen[Marshalls.raw_to_base64(appearance.encode())] = true
		assert_true(seen.size() > 10, "%s: variety (%d distinct)" % [race.id, seen.size()])
		var fallback: CharacterAppearance = CharacterAppearance.default_for(catalog, race_index)
		assert_true(fallback.validate(catalog, realm, race.id), "%s: the default appearance is valid" % race.id)
		assert_true(fallback.hair != CharacterAppearance.NONE, "%s: default, with hair" % race.id)
	assert_null(CharacterAppearance.random(catalog, -1, rng), "random of a race that does not exist")
	assert_null(CharacterAppearance.random(catalog, catalog.races.size(), rng), "nor above")
	assert_null(CharacterAppearance.default_for(catalog, catalog.races.size()), "default_for neither")


## One race per realm, Askarra too (§7.1), with its data in data/characters/races/ and in the catalog.
func test_one_race_per_realm() -> void:
	var catalog: AppearanceCatalog = _catalog()
	assert_eq(catalog.get_errors(), PackedStringArray(), "the catalog has no errors")
	assert_eq(catalog.ids_of(&"races"), PackedStringArray(["race_vardheim", "race_solmarch", "race_askarra"]),
			"the three races, in this order")
	for realm_id: StringName in RealmCatalog.REALM_IDS:
		var race: RaceDefinition = catalog.race_for_realm(realm_id)
		assert_not_null(race, "%s has a race" % realm_id)
		if race == null:
			continue
		assert_eq(race.id, StringName("race_%s" % realm_id), "the race of %s is race_%s" % [realm_id, realm_id])
		assert_eq(race.resource_path, "%s/%s.tres" % [RACES_DIR, race.id], "%s is in its file" % race.id)
		assert_true(FileAccess.get_file_as_string(race.resource_path).begins_with("[gd_resource"),
				"%s in text format" % race.resource_path)
		assert_false(race.display_name.is_empty(), "%s has a name" % race.id)
	var files: PackedStringArray = PackedStringArray()
	for file_name: String in DirAccess.get_files_at(RACES_DIR):
		if file_name.trim_suffix(".remap").ends_with(".tres"):
			files.append(file_name.trim_suffix(".remap").get_basename())
	files.sort()
	var listed: PackedStringArray = catalog.ids_of(&"races")
	listed.sort()
	assert_eq(files, listed, "each file of %s is in the catalog and vice versa" % RACES_DIR)


func test_no_racial_stats() -> void:
	for race: RaceDefinition in _catalog().races:
		assert_true(race.stat_modifiers.is_empty(), "%s: stat_modifiers empty (§0)" % race.id)
	var broken: AppearanceCatalog = _two_body_catalog()
	broken.races[0].stat_modifiers = {"health": 10}
	assert_true(" ".join(broken.get_errors()).contains("stat_modifiers"), "get_errors detects it")


## appearance_ids.txt is a prefix of the catalog: nothing is reordered or deleted.
func test_frozen_ids_are_a_prefix_of_the_catalog() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var frozen: Dictionary[StringName, PackedStringArray] = {}
	for category: StringName in AppearanceCatalog.CATEGORIES:
		frozen[category] = PackedStringArray()
	var lines: int = 0
	for raw_line: String in FileAccess.get_file_as_string(AppearanceCatalog.IDS_PATH).split("\n"):
		var line: String = raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts: PackedStringArray = line.split(" ", false)
		assert_eq(parts.size(), 3, "\"category index id\": %s" % line)
		if parts.size() != 3:
			continue
		var category := StringName(parts[0])
		assert_true(frozen.has(category), "known category: %s" % line)
		if not frozen.has(category):
			continue
		assert_eq(parts[1].to_int(), frozen[category].size(), "indices consecutive from 0: %s" % line)
		frozen[category].append(parts[2])
		lines += 1
	assert_true(lines >= 10, "the file has ids (%d)" % lines)
	for category: StringName in AppearanceCatalog.CATEGORIES:
		var ids: PackedStringArray = catalog.ids_of(category)
		assert_true(ids.size() >= frozen[category].size(), "%s has not lost entries" % category)
		assert_eq(ids.slice(0, frozen[category].size()), frozen[category],
				"%s starts with what is frozen in appearance_ids.txt" % category)


## The catalog only names scenes that exist (§7.2, §16), as paths: no textures, scenes or meshes
## loaded in the resources.
func test_catalog_names_only_existing_scenes() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var named: int = 0
	for category: StringName in AppearanceCatalog.PART_CATEGORIES:
		for part: AppearancePart in catalog.entries(category):
			assert_false(part.display_name.is_empty(), "%s has a name" % part.id)
			if part.scene_path.is_empty():
				continue
			named += 1
			assert_true(part.scene_path.begins_with("res://assets/"),
					"%s: %s is in assets/" % [part.id, part.scene_path])
			assert_true(ResourceLoader.exists(part.scene_path), "%s: %s exists" % [part.id, part.scene_path])
	assert_true(named >= 4, "body, head, hair and beard have a scene (%d)" % named)
	for category: StringName in AppearanceCatalog.COLOR_CATEGORIES:
		for color: AppearanceColor in catalog.entries(category):
			assert_false(color.display_name.is_empty(), "%s has a name" % color.id)
			if not color.texture_path.is_empty():
				assert_true(ResourceLoader.exists(color.texture_path), "%s: %s exists" % [color.id, color.texture_path])
	assert_true(catalog.eye_colors.size() <= 16 and catalog.marks.size() <= 15, "eyes and marks fit in 4 bits")
	assert_true(FileAccess.get_file_as_string(AppearanceCatalog.PATH).begins_with("[gd_resource"),
			"the catalog is in text format")


func test_catalog_errors_are_detected() -> void:
	var catalog: AppearanceCatalog = _two_body_catalog()
	catalog.heads[1].bodies = PackedInt32Array([5])
	catalog.races[0].hair_colors = PackedInt32Array([0, 0, 9])
	catalog.races[0].realm = &"huecos"
	var eyes: Array[AppearanceColor] = []
	for i: int in range(17):
		eyes.append(_color("eyes_%d" % i))
	catalog.eye_colors = eyes
	catalog.skin_tones[0].id = &"Piel Clara"
	var text: String = " | ".join(catalog.get_errors())
	for expected: String in ["el cuerpo 5 no existe", "hair_colors 0 está repetido", "hair_colors 9 no existe",
			"no es un reino jugable", "eye_colors tiene 17", "no tiene el formato"]:
		assert_true(text.contains(expected), "get_errors detects \"%s\": %s" % [expected, text])


# --- Test catalog ---------------------------------------------------------------------------

## Two bodies: head 0 and the beard and marks only with 0; head 1 only with 1; hair with
## both. A Vardheim race that allows everything.
func _two_body_catalog() -> AppearanceCatalog:
	var catalog := AppearanceCatalog.new()
	catalog.bodies = [_part("body_a", []), _part("body_b", [])]
	catalog.heads = [_part("head_a", [0]), _part("head_b", [1])]
	catalog.hairs = [_part("hair_any", [])]
	catalog.beards = [_part("beard_a", [0])]
	catalog.marks = [_part("marks_a", [0])]
	catalog.skin_tones = [_color("skin_a")]
	catalog.hair_colors = [_color("hair_a")]
	catalog.eye_colors = [_color("eyes_a")]
	var race := RaceDefinition.new()
	race.id = &"race_test"
	race.realm = RealmCatalog.VARDHEIM
	race.display_name = "Prueba"
	race.bodies = PackedInt32Array([0, 1])
	race.heads = PackedInt32Array([0, 1])
	race.hairs = PackedInt32Array([0])
	race.beards = PackedInt32Array([0])
	race.marks = PackedInt32Array([0])
	race.skin_tones = PackedInt32Array([0])
	race.hair_colors = PackedInt32Array([0])
	race.eye_colors = PackedInt32Array([0])
	race.allows_no_hair = false
	race.allows_no_beard = true
	catalog.races = [race]
	return catalog


func _part(id: String, bodies: Array) -> AppearancePart:
	var part := AppearancePart.new()
	part.id = StringName(id)
	part.display_name = id
	part.bodies = PackedInt32Array(bodies)
	return part


func _color(id: String) -> AppearanceColor:
	var color := AppearanceColor.new()
	color.id = StringName(id)
	color.display_name = id
	return color
