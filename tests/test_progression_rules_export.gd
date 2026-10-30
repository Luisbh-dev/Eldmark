extends TestCase
## Pruebas de las reglas exportadas para la plataforma ([ProgressionRulesExport];
## docs/progresion.md §13.4, docs/plataforma.md §4.4): [method ProgressionRulesExport.build] es
## determinista y el archivo del repositorio, el que incrusta la plataforma en Go, coincide con él.
## Es la única prueba del archivo: cada documento añade aquí las comprobaciones de sus secciones.


func test_build_is_deterministic() -> void:
	var first: String = JSON.stringify(ProgressionRulesExport.build(), "\t", true)
	var second: String = JSON.stringify(ProgressionRulesExport.build(), "\t", true)
	assert_eq(second, first, "dos llamadas a build() dan lo mismo")
	assert_eq(ProgressionRulesExport.to_json(), first + "\n", "to_json es build() con un salto final")


func test_file_matches_build() -> void:
	var path: String = ProgressionRulesExport.OUTPUT_PATH
	assert_true(FileAccess.file_exists(path), "existe %s" % path)
	var text: String = FileAccess.get_file_as_string(path)
	assert_true(text == ProgressionRulesExport.to_json(),
			"%s está al día (si no, ejecuta tools/progression/export_rules.gd y súbelo)" % path)


func test_file_is_valid_json_with_sorted_keys() -> void:
	var json: JSON = JSON.new()
	assert_eq(json.parse(FileAccess.get_file_as_string(ProgressionRulesExport.OUTPUT_PATH)), OK, "JSON válido")
	var data: Dictionary = json.data
	var keys: Array = data.keys()
	var sorted: Array = keys.duplicate()
	sorted.sort()
	assert_eq(keys, sorted, "claves ordenadas")
	assert_true(data.has("protocol_version") and data.has("names"), "secciones de plataforma.md")


func test_protocol_version_section() -> void:
	assert_eq(ProgressionRulesExport.build()["protocol_version"], NetProtocol.PROTOCOL_VERSION,
			"protocol_version es el de NetProtocol")


func test_names_section() -> void:
	var names: Dictionary = ProgressionRulesExport.build()["names"]
	var expected_keys: Array = ["folded", "lower_letters", "max_length", "min_length", "reserved", "upper_letters"]
	var keys: Array = names.keys()
	keys.sort()
	assert_eq(keys, expected_keys, "las claves de la sección names (plataforma.md §4.4)")
	assert_eq(names["min_length"], NameRules.MIN_LENGTH, "min_length")
	assert_eq(names["max_length"], NameRules.MAX_LENGTH, "max_length")
	assert_eq(names["upper_letters"], NameRules.UPPER_LETTERS, "upper_letters")
	assert_eq(names["lower_letters"], NameRules.LOWER_LETTERS, "lower_letters")
	assert_eq(String(names["upper_letters"]).length(), String(names["lower_letters"]).length(),
			"mayúsculas y minúsculas en el mismo orden")
	assert_eq(names["folded"], NameRules.FOLDED, "folded")
	assert_eq(Array(names["reserved"]), Array(NameRules.RESERVED), "reserved, como está escrito")


# --- Secciones de progresion.md (P3) --------------------------------------------------------------

## Las secciones de progresion.md §13.4, todas desde P1 ([code]items[/code] y [code]starter_templates[/code]).
func test_progression_sections_present() -> void:
	var data: Dictionary = ProgressionRulesExport.build()
	for section: String in ["races", "appearance", "level_curve", "currencies", "reasons", "containers", "combat",
			"items", "starter_templates"]:
		assert_true(data.has(section), "sección %s (progresion.md §13.4)" % section)
	var keys: Array = data.keys()
	keys.sort()
	assert_eq(keys, ["appearance", "combat", "containers", "currencies", "items", "level_curve", "names",
			"protocol_version", "races", "reasons", "starter_templates"], "ni más ni menos secciones")


## Las tres razas, en el orden del catálogo, con el reino en código y la regla entera de la apariencia.
func test_races_section() -> void:
	var races: Array = ProgressionRulesExport.build()["races"]
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	assert_eq(races.size(), catalog.races.size(), "una entrada por raza del catálogo")
	var expected_ids: Array = ["race_vardheim", "race_solmarch", "race_askarra"]
	var expected_realms: Array = [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH, NetProtocol.Realm.ASKARRA]
	for i: int in range(races.size()):
		var entry: Dictionary = races[i]
		var keys: Array = entry.keys()
		keys.sort()
		assert_eq(keys, ["allows_no_beard", "allows_no_hair", "beards", "bodies", "eye_colors", "hair_colors",
				"hairs", "heads", "id", "marks", "realm", "skin_tones"], "claves de races[%d]" % i)
		assert_eq(entry["id"], expected_ids[i],
				"races[%d] es %s (el byte 0 es su posición + 1)" % [i, expected_ids[i]])
		assert_eq(entry["realm"], expected_realms[i], "%s: reino en el código de NetProtocol.Realm" % entry["id"])
		var race: RaceDefinition = catalog.races[i]
		assert_eq(entry["allows_no_hair"], race.allows_no_hair, "%s: allows_no_hair" % race.id)
		assert_eq(entry["allows_no_beard"], race.allows_no_beard, "%s: allows_no_beard" % race.id)
		for category: StringName in AppearanceCatalog.PART_CATEGORIES + AppearanceCatalog.COLOR_CATEGORIES:
			assert_eq(entry[String(category)], Array(race.allowed(category)), "%s: %s" % [race.id, category])


func test_appearance_section() -> void:
	var appearance: Dictionary = ProgressionRulesExport.build()["appearance"]
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	assert_eq(appearance["body_count"], catalog.bodies.size(), "cuerpos")
	assert_eq(appearance["skin_tone_count"], catalog.skin_tones.size(), "tonos de piel")
	assert_eq(appearance["hair_color_count"], catalog.hair_colors.size(), "colores de pelo")
	assert_eq(appearance["eye_color_count"], catalog.eye_colors.size(), "colores de ojos")
	for category: StringName in [&"heads", &"hairs", &"beards", &"marks"]:
		var parts: Array = appearance[String(category)]
		var catalog_parts: Array = catalog.entries(category)
		assert_eq(parts.size(), catalog_parts.size(), "%s: una entrada por pieza" % category)
		for i: int in range(mini(parts.size(), catalog_parts.size())):
			assert_eq(parts[i], {"id": String(catalog_parts[i].id), "bodies": Array(catalog_parts[i].bodies)},
					"%s[%d]: id y cuerpos compatibles" % [category, i])


func test_level_curve_section() -> void:
	var curve: Dictionary = ProgressionRulesExport.build()["level_curve"]
	assert_eq(curve["level_cap"], 40, "tope 40")
	assert_eq(Array(curve["xp_to_next"]), Array(LevelCurve.shared().xp_to_next), "la tabla de la curva")
	assert_eq(curve["xp_to_next"].size(), 39, "39 valores")
	assert_eq(curve["attribute_points_per_level"], 1, "un punto por nivel")


## Topes de las monedas, rangos de los motivos y tipos de operación de §5.1 y §5.3.
func test_currencies_reasons_containers_combat() -> void:
	var data: Dictionary = ProgressionRulesExport.build()
	assert_eq(data["currencies"], [{"code": 1, "id": "gold", "cap": 1000000000},
			{"code": 2, "id": "merits", "cap": 1000000000}], "oro y méritos con tope de mil millones")
	var reasons: Dictionary = data["reasons"]
	assert_eq(reasons["ranges"], {"source": {"min": 1, "max": 63}, "sink": {"min": 64, "max": 127},
			"internal": {"min": 128, "max": 191}}, "rangos de §5.3")
	var codes: Dictionary = reasons["codes"]
	var by_code: Dictionary = {}
	for reason: String in codes:
		var code: int = codes[reason]
		assert_false(by_code.has(code), "el código %d no se repite (%s, %s)" % [code, reason, by_code.get(code, "")])
		by_code[code] = reason
		assert_true((code >= 1 and code <= 191), "%s: %d está en algún rango" % [reason, code])
	assert_eq([codes["starter_kit"], codes["camp_refill"], codes["pvp_kill"], codes["npc_kill"], codes["gm_grant"],
			codes["player_destroy"], codes["consume"], codes["gm_remove"], codes["reversal"], codes["migration"]],
			[1, 2, 3, 6, 7, 64, 65, 66, 128, 129], "los motivos de la fase 5")
	assert_eq(reasons["op_kinds"], {"player": 1, "gameplay": 2, "starter_kit": 3, "gm": 4, "reversal": 5,
			"migration": 6, "trade": 7, "mail": 8}, "tipos de operación")
	assert_eq(data["containers"], {"bag": {"code": 0, "default_slots": 30, "max_slots": 120},
			"equipment": {"code": 1, "slots": 7, "open_slots": 2}, "open": [0, 1]}, "contenedores de §4.1")
	assert_eq(data["combat"], {"health_max": CombatCatalog.rules().health_max}, "vida máxima de CombatRules")


# --- Secciones de progresion.md (P1) --------------------------------------------------------------

## Una entrada por definición de ItemDatabase, en orden de net id, con lo que mira S5.
func test_items_section() -> void:
	var items: Array = ProgressionRulesExport.build()["items"]
	var db: ItemDatabase = ItemDatabase.shared()
	var ids: Array[StringName] = db.all_ids()
	assert_eq(items.size(), ids.size(), "una entrada por objeto")
	for i: int in range(mini(items.size(), ids.size())):
		var definition: ItemDefinition = db.get_definition(ids[i])
		assert_eq(items[i], {"id": String(definition.id), "category": int(definition.category),
				"equip_slot": int(definition.equip_slot), "max_stack": definition.max_stack,
				"has_durability": definition.has_durability, "required_level": definition.required_level},
				"items[%d] es %s (net id %d)" % [i, ids[i], i + 1])
	assert_eq(items[0]["id"], "bow_vado", "el arco primero (alfabético)")
	assert_eq(items[1], {"id": "potion_health", "category": 3, "equip_slot": 0, "max_stack": 15,
			"has_durability": false, "required_level": 1}, "la poción de vida con los números de §2.1")


## Las plantillas elegibles (hoy marksman y squire) con los objetos de sus armas en orden de ranura.
func test_starter_templates_section() -> void:
	var templates: Array = ProgressionRulesExport.build()["starter_templates"]
	assert_eq(templates, [{"id": "marksman", "weapons": ["bow_vado", "sword_shield_vado"]},
			{"id": "squire", "weapons": ["sword_shield_vado"]}], "marksman y squire con sus armas")
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
					"%s: %s es un arma de ItemDatabase" % [entry["id"], item_id])
	assert_eq(exported, selectable, "todas las elegibles y solo ellas")
