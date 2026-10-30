extends TestCase
## Pruebas de la apariencia ([CharacterAppearance], [AppearanceCatalog], [RaceDefinition];
## docs/progresion.md §7, ART-19, PRG-14): ida y vuelta de los 8 B, los casos compartidos con Go
## ([code]tests/fixtures/progression/appearance_cases.json[/code], que lee también
## [code]platform/internal/progress[/code]), cada regla de [method CharacterAppearance.validate], 100
## apariencias aleatorias válidas por raza, el orden congelado de [code]appearance_ids.txt[/code], las
## escenas del catálogo y ninguna estadística racial.

## Casos compartidos con Go: [code][{case, realm, race_id, appearance, valid}][/code], con el reino en
## su código (1–3) y la apariencia en base64, como en la API.
const SHARED_CASES_PATH: String = "res://tests/fixtures/progression/appearance_cases.json"
const RACES_DIR: String = "res://data/characters/races"


func _catalog() -> AppearanceCatalog:
	return AppearanceCatalog.shared()


## Una apariencia válida de Vardheim (la de [method CharacterAppearance.default_for]).
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
		assert_not_null(appearance, "8 B cualesquiera se leen")
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
			"orden de los bytes y el byte 7 (ojos abajo, marcas arriba)")
	var decoded: CharacterAppearance = CharacterAppearance.decode(PackedByteArray([3, 1, 2, 4, 5, 6, 7, 0xC9]))
	assert_eq([decoded.race, decoded.body, decoded.head, decoded.hair, decoded.beard, decoded.skin,
			decoded.hair_color, decoded.eyes, decoded.marks], [3, 1, 2, 4, 5, 6, 7, 9, 12], "campo a campo")


func test_decode_rejects_other_sizes() -> void:
	for size: int in [0, 1, 7, 9, 16]:
		var bytes := PackedByteArray()
		bytes.resize(size)
		assert_null(CharacterAppearance.decode(bytes), "%d B no es una apariencia" % size)


func test_shared_cases_with_go() -> void:
	var json := JSON.new()
	assert_eq(json.parse(FileAccess.get_file_as_string(SHARED_CASES_PATH)), OK, "%s es JSON" % SHARED_CASES_PATH)
	var cases: Array = json.data
	assert_true(cases.size() >= 30, "hay casos que comprobar (%d)" % cases.size())
	var valid_count: int = 0
	for entry: Dictionary in cases:
		var keys: Array = entry.keys()
		keys.sort()
		assert_eq(keys, ["appearance", "case", "race_id", "realm", "valid"], "claves del caso %s" % entry)
		var bytes: PackedByteArray = Marshalls.base64_to_raw(entry["appearance"])
		var appearance: CharacterAppearance = CharacterAppearance.decode(bytes)
		var valid: bool = appearance != null and appearance.validate(_catalog(), int(entry["realm"]),
				StringName(entry["race_id"]))
		assert_eq(valid, entry["valid"], "caso «%s» (%s)" % [entry["case"], entry["appearance"]])
		if entry["valid"]:
			valid_count += 1
	assert_true(valid_count >= 5 and valid_count < cases.size(), "hay casos válidos e inválidos")


func test_validate_rejects_each_index_out_of_range() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var base: CharacterAppearance = _vardheim()
	assert_true(base.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_vardheim"), "la base vale")
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
					"%s = %d está fuera de rango" % [field, value])


func test_validate_race_and_realm() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var vardheim: CharacterAppearance = _vardheim()
	assert_false(vardheim.validate(catalog, NetProtocol.Realm.SOLMARCH, &"race_vardheim"),
			"la raza de otro reino")
	assert_false(vardheim.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_solmarch"),
			"un byte 0 que no es el de race_id")
	assert_false(vardheim.validate(catalog, NetProtocol.Realm.NONE, &"race_vardheim"), "reino 0")
	assert_false(vardheim.validate(catalog, 7, &"race_vardheim"), "reino que no existe")
	assert_false(vardheim.validate(null, NetProtocol.Realm.VARDHEIM, &"race_vardheim"), "sin catálogo")
	var solmarch_index: int = catalog.race_index(&"race_solmarch")
	var solmarch: CharacterAppearance = CharacterAppearance.default_for(catalog, solmarch_index)
	assert_true(solmarch.validate(catalog, NetProtocol.Realm.SOLMARCH, &"race_solmarch"), "solmarch vale")
	solmarch.race = vardheim.race
	assert_false(solmarch.validate(catalog, NetProtocol.Realm.SOLMARCH, &"race_solmarch"),
			"el byte 0 de otra raza")


func test_validate_no_hair_or_beard_only_if_allowed() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var vardheim: RaceDefinition = catalog.races[catalog.race_index(&"race_vardheim")]
	var solmarch: RaceDefinition = catalog.races[catalog.race_index(&"race_solmarch")]
	assert_false(vardheim.allows_no_hair or vardheim.allows_no_beard, "Vardheim no admite ir sin pelo ni barba")
	assert_true(solmarch.allows_no_hair and solmarch.allows_no_beard, "Solmarch admite las dos")
	var bald: CharacterAppearance = _vardheim()
	bald.hair = CharacterAppearance.NONE
	assert_false(bald.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_vardheim"), "sin pelo en Vardheim")
	var shaven: CharacterAppearance = _vardheim()
	shaven.beard = CharacterAppearance.NONE
	assert_false(shaven.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_vardheim"), "sin barba en Vardheim")
	var monk: CharacterAppearance = CharacterAppearance.default_for(catalog, catalog.race_index(&"race_solmarch"))
	monk.hair = CharacterAppearance.NONE
	monk.beard = CharacterAppearance.NONE
	assert_true(monk.validate(catalog, NetProtocol.Realm.SOLMARCH, &"race_solmarch"), "sin pelo ni barba en Solmarch")


## La regla de los cuerpos, con un catálogo de dos cuerpos (el del repositorio solo tiene uno, §16).
func test_validate_part_of_another_body() -> void:
	var catalog: AppearanceCatalog = _two_body_catalog()
	assert_eq(catalog.get_errors(), PackedStringArray(), "el catálogo de prueba vale")
	var appearance := CharacterAppearance.new()
	appearance.race = 1
	appearance.body = 0
	appearance.head = 0
	appearance.hair = 1
	appearance.beard = 1
	assert_true(appearance.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"), "cuerpo 0 con sus piezas")
	appearance.head = 1
	assert_false(appearance.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"),
			"una cabeza del cuerpo 1 con el cuerpo 0")
	appearance.body = 1
	appearance.beard = 0
	assert_true(appearance.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"),
			"cuerpo 1 con su cabeza, el pelo de todos y sin barba")
	appearance.beard = 1
	assert_false(appearance.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"),
			"una barba del cuerpo 0 con el cuerpo 1")
	appearance.beard = 0
	appearance.marks = 1
	assert_false(appearance.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"),
			"unas marcas del cuerpo 0 con el cuerpo 1")
	appearance.body = 0
	appearance.head = 0
	appearance.beard = 1
	assert_true(appearance.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"), "y con el cuerpo 0, sí")
	# Aleatorias del catálogo de prueba: siempre encajan.
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i: int in range(100):
		var random: CharacterAppearance = CharacterAppearance.random(catalog, 0, rng)
		assert_true(random.validate(catalog, NetProtocol.Realm.VARDHEIM, &"race_test"), "aleatoria %s" % random)


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
			assert_true(appearance.validate(catalog, realm, race.id), "%s: aleatoria %s" % [race.id, appearance])
			seen[Marshalls.raw_to_base64(appearance.encode())] = true
		assert_true(seen.size() > 10, "%s: variedad (%d distintas)" % [race.id, seen.size()])
		var fallback: CharacterAppearance = CharacterAppearance.default_for(catalog, race_index)
		assert_true(fallback.validate(catalog, realm, race.id), "%s: la apariencia por defecto vale" % race.id)
		assert_true(fallback.hair != CharacterAppearance.NONE, "%s: por defecto, con pelo" % race.id)
	assert_null(CharacterAppearance.random(catalog, -1, rng), "random de una raza que no existe")
	assert_null(CharacterAppearance.random(catalog, catalog.races.size(), rng), "ni por arriba")
	assert_null(CharacterAppearance.default_for(catalog, catalog.races.size()), "default_for tampoco")


## Una raza por reino, también Askarra (§7.1), con sus datos en data/characters/races/ y en el catálogo.
func test_one_race_per_realm() -> void:
	var catalog: AppearanceCatalog = _catalog()
	assert_eq(catalog.get_errors(), PackedStringArray(), "el catálogo no tiene errores")
	assert_eq(catalog.ids_of(&"races"), PackedStringArray(["race_vardheim", "race_solmarch", "race_askarra"]),
			"las tres razas, en este orden")
	for realm_id: StringName in RealmCatalog.REALM_IDS:
		var race: RaceDefinition = catalog.race_for_realm(realm_id)
		assert_not_null(race, "%s tiene raza" % realm_id)
		if race == null:
			continue
		assert_eq(race.id, StringName("race_%s" % realm_id), "la raza de %s es race_%s" % [realm_id, realm_id])
		assert_eq(race.resource_path, "%s/%s.tres" % [RACES_DIR, race.id], "%s está en su archivo" % race.id)
		assert_true(FileAccess.get_file_as_string(race.resource_path).begins_with("[gd_resource"),
				"%s en formato texto" % race.resource_path)
		assert_false(race.display_name.is_empty(), "%s tiene nombre" % race.id)
	var files: PackedStringArray = PackedStringArray()
	for file_name: String in DirAccess.get_files_at(RACES_DIR):
		if file_name.trim_suffix(".remap").ends_with(".tres"):
			files.append(file_name.trim_suffix(".remap").get_basename())
	files.sort()
	var listed: PackedStringArray = catalog.ids_of(&"races")
	listed.sort()
	assert_eq(files, listed, "cada archivo de %s está en el catálogo y al revés" % RACES_DIR)


func test_no_racial_stats() -> void:
	for race: RaceDefinition in _catalog().races:
		assert_true(race.stat_modifiers.is_empty(), "%s: stat_modifiers vacío (§0)" % race.id)
	var broken: AppearanceCatalog = _two_body_catalog()
	broken.races[0].stat_modifiers = {"health": 10}
	assert_true(" ".join(broken.get_errors()).contains("stat_modifiers"), "get_errors lo detecta")


## appearance_ids.txt es prefijo del catálogo: nada se reordena ni se borra.
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
		assert_eq(parts.size(), 3, "«categoría índice id»: %s" % line)
		if parts.size() != 3:
			continue
		var category := StringName(parts[0])
		assert_true(frozen.has(category), "categoría conocida: %s" % line)
		if not frozen.has(category):
			continue
		assert_eq(parts[1].to_int(), frozen[category].size(), "índices seguidos desde 0: %s" % line)
		frozen[category].append(parts[2])
		lines += 1
	assert_true(lines >= 10, "el archivo tiene ids (%d)" % lines)
	for category: StringName in AppearanceCatalog.CATEGORIES:
		var ids: PackedStringArray = catalog.ids_of(category)
		assert_true(ids.size() >= frozen[category].size(), "%s no ha perdido entradas" % category)
		assert_eq(ids.slice(0, frozen[category].size()), frozen[category],
				"%s empieza por lo congelado en appearance_ids.txt" % category)


## El catálogo solo nombra escenas que existen (§7.2, §16), como rutas: ni texturas, ni escenas, ni mallas
## cargadas en los recursos.
func test_catalog_names_only_existing_scenes() -> void:
	var catalog: AppearanceCatalog = _catalog()
	var named: int = 0
	for category: StringName in AppearanceCatalog.PART_CATEGORIES:
		for part: AppearancePart in catalog.entries(category):
			assert_false(part.display_name.is_empty(), "%s tiene nombre" % part.id)
			if part.scene_path.is_empty():
				continue
			named += 1
			assert_true(part.scene_path.begins_with("res://assets/"),
					"%s: %s está en assets/" % [part.id, part.scene_path])
			assert_true(ResourceLoader.exists(part.scene_path), "%s: existe %s" % [part.id, part.scene_path])
	assert_true(named >= 4, "cuerpo, cabeza, pelo y barba tienen escena (%d)" % named)
	for category: StringName in AppearanceCatalog.COLOR_CATEGORIES:
		for color: AppearanceColor in catalog.entries(category):
			assert_false(color.display_name.is_empty(), "%s tiene nombre" % color.id)
			if not color.texture_path.is_empty():
				assert_true(ResourceLoader.exists(color.texture_path), "%s: existe %s" % [color.id, color.texture_path])
	assert_true(catalog.eye_colors.size() <= 16 and catalog.marks.size() <= 15, "ojos y marcas caben en 4 bits")
	assert_true(FileAccess.get_file_as_string(AppearanceCatalog.PATH).begins_with("[gd_resource"),
			"el catálogo está en formato texto")


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
		assert_true(text.contains(expected), "get_errors detecta «%s»: %s" % [expected, text])


# --- Catálogo de prueba ---------------------------------------------------------------------------

## Dos cuerpos: la cabeza 0 y la barba y las marcas solo con el 0; la cabeza 1 solo con el 1; el pelo con
## los dos. Una raza de Vardheim que lo permite todo.
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
