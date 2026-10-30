extends TestCase
## Pruebas de las definiciones de objetos ([ItemDefinition], [ItemDatabase]; docs/progresion.md §2.1, §2.2 y
## §2.4, PRG-02): ids únicos y con formato, recursos en texto, la coherencia de §2.1 (la de ARMOR con
## [code]tests/fixtures/items/[/code], porque [code]data/items/[/code] no tiene armaduras en la fase 5),
## [code]ref_id[/code] que existen, un objeto por arma y consumible de las plantillas, net ids alfabéticos y
## [method ItemDatabase.wire_hash] estable entre dos cargas.

const ARMOR_FIXTURES: String = "res://tests/fixtures/items/armor"
const BROKEN_FIXTURES: String = "res://tests/fixtures/items/broken"
## Lo que dice el error de cada objeto roto de [constant BROKEN_FIXTURES].
const BROKEN_EXPECTED: Dictionary[String, String] = {
	"armor_in_weapon_slot.tres": "una armadura va en una ranura de HEAD a FEET",
	"armor_without_slot.tres": "una armadura va en una ranura de HEAD a FEET",
	"armor_stackable.tres": "no se apila",
}
## Los objetos de §2.4: categoría, ref_id, pila, camp_refill y destroyable.
const PHASE_5_ITEMS: Dictionary[StringName, Array] = {
	&"bow_vado": [ItemDefinition.Category.WEAPON, &"bow", 1, 0, false],
	&"potion_health": [ItemDefinition.Category.CONSUMABLE, &"potion_health", 15, 3, true],
	&"potion_stamina": [ItemDefinition.Category.CONSUMABLE, &"potion_stamina", 15, 2, true],
	&"sword_shield_vado": [ItemDefinition.Category.WEAPON, &"sword_shield", 1, 0, false],
}


func test_data_has_no_errors() -> void:
	var db: ItemDatabase = ItemDatabase.build_from_directory(ItemDatabase.DATA_DIR)
	assert_eq(db.errors, PackedStringArray(), "data/items no tiene errores")
	assert_eq(ItemDatabase.shared().errors, PackedStringArray(), "ni la base compartida")
	assert_true(ItemDatabase.shared() == ItemDatabase.shared(), "shared() carga una sola vez")
	assert_eq(db.all_ids(), [&"bow_vado", &"potion_health", &"potion_stamina", &"sword_shield_vado"],
			"los cuatro objetos de §2.4, en orden alfabético")


## Cada recurso de data/items/ y de tests/fixtures/items/ es una ItemDefinition en texto, con un id con
## formato que no se repite y que es su nombre de archivo, en la carpeta de su categoría.
func test_ids_unique_formatted_and_resources_in_text() -> void:
	var id_regex := RegEx.new()
	id_regex.compile(ItemDefinition.ID_PATTERN)
	var seen: Dictionary[StringName, String] = {}
	var checked: int = 0
	for dir: String in [ItemDatabase.DATA_DIR, "res://tests/fixtures/items"]:
		for path: String in _files(dir):
			checked += 1
			assert_true(path.ends_with(".tres"), "%s es un .tres (nada de binarios)" % path)
			var text: String = FileAccess.get_file_as_string(path)
			assert_true(text.begins_with("[gd_resource"), "%s está en formato texto" % path)
			var definition: ItemDefinition = ResourceLoader.load(path) as ItemDefinition
			if not assert_not_null(definition, "%s es una ItemDefinition" % path):
				continue
			assert_true(id_regex.search(String(definition.id)) != null, "%s: el id '%s' tiene formato" % [
				path, definition.id])
			assert_false(seen.has(definition.id), "el id %s no se repite (%s, %s)" % [definition.id,
					seen.get(definition.id, ""), path])
			seen[definition.id] = path
			if dir == ItemDatabase.DATA_DIR:
				assert_eq(path.get_file(), "%s.tres" % definition.id, "%s: el archivo se llama como el id" % path)
				var category_name: String = String(ItemDefinition.Category.find_key(definition.category)).to_lower()
				assert_eq(path.get_base_dir().get_file(), category_name,
						"%s está en data/items/<categoría>/" % path)
	assert_true(checked >= 4 + 3 + BROKEN_EXPECTED.size(), "se revisan los datos y los casos (%d)" % checked)


## §2.4: un objeto por arma y poción de la fase 4, de inicio, ligados al cogerlos, de nivel 1 y sin valor;
## las armas sin durabilidad ni destrucción y las pociones en pilas de 15 que el campamento repone a 3 y 2.
func test_phase_5_content() -> void:
	var db: ItemDatabase = ItemDatabase.shared()
	for id: StringName in PHASE_5_ITEMS:
		var definition: ItemDefinition = db.get_definition(id)
		if not assert_not_null(definition, "existe %s" % id):
			continue
		var expected: Array = PHASE_5_ITEMS[id]
		assert_eq(definition.category, expected[0], "%s: categoría" % id)
		assert_eq(definition.ref_id, expected[1], "%s: ref_id" % id)
		assert_eq(definition.max_stack, expected[2], "%s: pila" % id)
		assert_eq(definition.camp_refill, expected[3], "%s: camp_refill" % id)
		assert_eq(definition.destroyable, expected[4], "%s: destroyable" % id)
		assert_true(definition.starter, "%s: de inicio" % id)
		assert_eq(definition.bind_rule, ItemDefinition.BindRule.ON_PICKUP, "%s: ligado al cogerlo" % id)
		assert_eq(definition.required_level, 1, "%s: nivel 1" % id)
		assert_eq(definition.base_value, 0, "%s: sin valor" % id)
		assert_false(definition.has_durability, "%s: sin durabilidad" % id)
		assert_false(definition.display_name.is_empty(), "%s: con nombre" % id)
		assert_eq(definition.icon_path, "", "%s: sin icono hasta ART-12 (§16)" % id)
		assert_eq(definition.visual_paths, PackedStringArray(), "%s: sin escenas" % id)
		var expected_slot: int = ItemDefinition.EquipSlot.WEAPON \
				if definition.category == ItemDefinition.Category.WEAPON else ItemDefinition.EquipSlot.NONE
		assert_eq(definition.equip_slot, expected_slot, "%s: ranura" % id)


## Los ref_id existen: el de cada arma en CombatCatalog y el de cada consumible entre sus consumibles.
func test_ref_ids_exist() -> void:
	var db: ItemDatabase = ItemDatabase.shared()
	var consumable_names: Array[StringName] = []
	for ability_id: int in CombatCatalog.consumable_ids():
		consumable_names.append(CombatCatalog.ability(ability_id).name)
	for id: StringName in db.all_ids():
		var definition: ItemDefinition = db.get_definition(id)
		match definition.category:
			ItemDefinition.Category.WEAPON:
				assert_true(CombatCatalog.weapon_id(definition.ref_id) != 0, "%s: el arma %s existe" % [
					id, definition.ref_id])
			ItemDefinition.Category.CONSUMABLE:
				assert_true(consumable_names.has(definition.ref_id), "%s: %s es un consumible" % [
					id, definition.ref_id])
			_:
				fail("%s: la fase 5 solo tiene armas y consumibles" % id)


## Un objeto por arma de cada plantilla y por consumible (§2.5: el kit de inicio sale de ellos), y uno solo:
## for_ref y consumable_definition lo encuentran.
func test_one_item_per_template_weapon_and_consumable() -> void:
	var db: ItemDatabase = ItemDatabase.shared()
	var tables: CombatTables = CombatCatalog.tables()
	assert_true(tables.templates.size() >= 2, "hay plantillas (%d)" % tables.templates.size())
	for template: EquipmentTemplate in tables.templates:
		for weapon: WeaponDefinition in template.weapons:
			var item: ItemDefinition = db.for_ref(ItemDefinition.Category.WEAPON, weapon.id)
			if assert_not_null(item, "plantilla %s: hay un objeto para el arma %s" % [template.id, weapon.id]):
				assert_eq(item.ref_id, weapon.id, "y es el suyo")
				assert_eq(item.category, ItemDefinition.Category.WEAPON, "y es un arma")
	var consumable_ids: PackedInt32Array = CombatCatalog.consumable_ids()
	assert_eq(consumable_ids.size(), 2, "dos consumibles (R y T)")
	for index: int in range(consumable_ids.size()):
		var ability_name: StringName = CombatCatalog.ability(consumable_ids[index]).name
		var item: ItemDefinition = db.consumable_definition(index)
		if assert_not_null(item, "hay un objeto para el consumible %d" % index):
			assert_eq(item.ref_id, ability_name, "el del consumible %d es %s" % [index, ability_name])
			assert_true(db.for_ref(ItemDefinition.Category.CONSUMABLE, ability_name) == item, "for_ref da el mismo")
	assert_eq(db.consumable_definition(0).id, &"potion_health", "R: la poción de vida")
	assert_eq(db.consumable_definition(1).id, &"potion_stamina", "T: la de resistencia")
	assert_null(db.consumable_definition(2), "no hay un tercer consumible")
	assert_null(db.consumable_definition(-1), "ni uno negativo")
	assert_null(db.for_ref(ItemDefinition.Category.CONSUMABLE, &"sword_shield"), "un arma no es un consumible")
	assert_null(db.for_ref(ItemDefinition.Category.WEAPON, &"npc_hollow"), "las armas de PNJ no tienen objeto")
	assert_null(db.for_ref(ItemDefinition.Category.WEAPON, &""), "ref vacío")
	var by_ref: Dictionary[String, StringName] = {}
	for id: StringName in db.all_ids():
		var definition: ItemDefinition = db.get_definition(id)
		var key: String = "%d/%s" % [definition.category, definition.ref_id]
		assert_false(by_ref.has(key), "un solo objeto por ref_id en la fase 5 (%s y %s)" % [by_ref.get(key, ""), id])
		by_ref[key] = id


func test_net_ids_are_alphabetical() -> void:
	var db: ItemDatabase = ItemDatabase.shared()
	var ids: Array[StringName] = db.all_ids()
	var sorted: Array[StringName] = ids.duplicate()
	sorted.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	assert_eq(ids, sorted, "all_ids en orden alfabético")
	for i: int in range(ids.size()):
		assert_eq(db.net_id_of(ids[i]), i + 1, "%s tiene el net id %d" % [ids[i], i + 1])
		assert_true(db.definition_by_net_id(i + 1) == db.get_definition(ids[i]), "y se encuentra por él")
	assert_eq(db.net_id_of(&"no_existe"), 0, "un id desconocido da 0")
	assert_null(db.get_definition(&"no_existe"), "y ninguna definición")
	assert_null(db.definition_by_net_id(0), "el net id 0 es ninguno")
	assert_null(db.definition_by_net_id(ids.size() + 1), "uno más allá del último no existe")
	assert_null(db.definition_by_net_id(-1), "ni uno negativo")
	# Con los objetos de prueba intercalados, los net ids se desplazan y siguen siendo alfabéticos.
	var mixed: ItemDatabase = _database_with_armor()
	var mixed_ids: Array[StringName] = mixed.all_ids()
	assert_eq(mixed_ids.size(), ids.size() + 3, "cuatro objetos y tres armaduras")
	for i: int in range(mixed_ids.size()):
		assert_eq(mixed.net_id_of(mixed_ids[i]), i + 1, "net id de %s en la base mezclada" % mixed_ids[i])
		if i > 0:
			assert_true(String(mixed_ids[i - 1]) < String(mixed_ids[i]), "orden alfabético")


## La huella no cambia entre dos cargas, cambia con lo que da sentido a los net ids y no con lo demás.
func test_wire_hash_is_stable() -> void:
	var first: ItemDatabase = ItemDatabase.build_from_directory(ItemDatabase.DATA_DIR)
	var second: ItemDatabase = ItemDatabase.build_from_directory(ItemDatabase.DATA_DIR)
	assert_eq(first.wire_hash(), second.wire_hash(), "dos cargas, la misma huella")
	assert_eq(first.wire_hash(), ItemDatabase.shared().wire_hash(), "la de la base compartida")
	assert_true(first.wire_hash() >= 0 and first.wire_hash() <= 0xFFFFFFFF, "u32")
	var base: Array[ItemDefinition] = _definitions_in(ItemDatabase.DATA_DIR)
	var reordered: Array[ItemDefinition] = base.duplicate()
	reordered.reverse()
	assert_eq(ItemDatabase.build_from_definitions(reordered).wire_hash(), first.wire_hash(),
			"el orden de llegada no cuenta")
	for change: Dictionary in [{"max_stack": 14}, {"has_durability": true}, {"category": ItemDefinition.Category.MISC},
			{"equip_slot": ItemDefinition.EquipSlot.HEAD}, {"id": &"potion_zzz"}]:
		assert_true(_hash_with_change(base, change) != first.wire_hash(), "cambia con %s" % change)
	for change: Dictionary in [{"display_name": "Otra"}, {"camp_refill": 5}, {"base_value": 7},
			{"required_level": 3}, {"bind_rule": ItemDefinition.BindRule.NONE}]:
		assert_eq(_hash_with_change(base, change), first.wire_hash(), "no cambia con %s" % change)
	assert_true(_database_with_armor().wire_hash() != first.wire_hash(), "un objeto más la cambia")


## La regla de ARMOR con los objetos de prueba: los buenos no dan errores y cada roto da el suyo.
func test_armor_rule_with_fixtures() -> void:
	var armor: ItemDatabase = ItemDatabase.build_from_directory(ARMOR_FIXTURES)
	assert_eq(armor.errors, PackedStringArray(), "las armaduras de prueba valen")
	assert_eq(armor.all_ids().size(), 3, "tres armaduras")
	var helm: ItemDefinition = armor.get_definition(&"test_iron_helm")
	if assert_not_null(helm, "el yelmo"):
		assert_eq(helm.category, ItemDefinition.Category.ARMOR, "es una armadura")
		assert_true(helm.has_durability and helm.is_equipable(), "con durabilidad y equipable")
	assert_eq(_database_with_armor().errors, PackedStringArray(), "y mezcladas con data/items tampoco")
	var broken_files: PackedStringArray = _files(BROKEN_FIXTURES)
	assert_eq(broken_files.size(), BROKEN_EXPECTED.size(), "un caso por archivo roto")
	for path: String in broken_files:
		var expected: String = BROKEN_EXPECTED.get(path.get_file(), "")
		var definition: ItemDefinition = ResourceLoader.load(path) as ItemDefinition
		if not assert_not_null(definition, "%s se carga" % path) \
				or not assert_false(expected.is_empty(), "%s tiene su error esperado" % path):
			continue
		var errors: PackedStringArray = ItemDatabase.build_from_definitions([definition]).errors
		assert_eq(errors.size(), 1, "%s: un error (%s)" % [path.get_file(), errors])
		assert_true(errors.size() > 0 and errors[0].contains(expected), "%s: «%s»" % [path.get_file(), expected])
	var all_broken: ItemDatabase = ItemDatabase.build_from_directory(BROKEN_FIXTURES)
	assert_eq(all_broken.errors.size(), BROKEN_EXPECTED.size(), "la carpeta entera da uno por archivo")


## Cada regla de §2.1, una a una, sobre una copia de un objeto bueno.
func test_each_coherence_rule() -> void:
	var potion: ItemDefinition = ItemDatabase.shared().get_definition(&"potion_health")
	var sword: ItemDefinition = ItemDatabase.shared().get_definition(&"sword_shield_vado")
	var helm: ItemDefinition = ResourceLoader.load(ARMOR_FIXTURES.path_join("test_iron_helm.tres")) as ItemDefinition
	var cases: Array[Array] = [
		[sword, {"equip_slot": ItemDefinition.EquipSlot.NONE}, "un arma va en la ranura WEAPON"],
		[sword, {"equip_slot": ItemDefinition.EquipSlot.CHEST}, "un arma va en la ranura WEAPON"],
		[sword, {"ref_id": &"halberd"}, "no está en el catálogo de combate"],
		[sword, {"max_stack": 2}, "no se apila"],
		[potion, {"equip_slot": ItemDefinition.EquipSlot.WEAPON}, "un consumible no se equipa"],
		[potion, {"ref_id": &"potion_regen"}, "no es un consumible"],
		[potion, {"ref_id": &"sword_shield"}, "no es un consumible"],
		[potion, {"has_durability": true}, "no se apila"],
		[potion, {"max_stack": 1000}, "max_stack fuera de rango"],
		[potion, {"max_stack": 0}, "max_stack fuera de rango"],
		[potion, {"camp_refill": 16}, "camp_refill debe caber"],
		[potion, {"camp_refill": -1}, "camp_refill debe caber"],
		[potion, {"required_level": 41}, "required_level fuera de rango"],
		[potion, {"required_level": 0}, "required_level fuera de rango"],
		[potion, {"base_value": -1}, "base_value negativo"],
		[potion, {"display_name": "  "}, "sin nombre"],
		[potion, {"id": &"Potion"}, "no tiene el formato"],
		[potion, {"id": &"po"}, "no tiene el formato"],
		[potion, {"id": StringName("p".repeat(33))}, "no tiene el formato"],
		[potion, {"category": 0}, "categoría fuera de rango"],
		[potion, {"category": 7}, "categoría fuera de rango"],
		[potion, {"equip_slot": 7}, "ranura fuera de rango"],
		[potion, {"bind_rule": 3}, "regla de ligado fuera de rango"],
		[potion, {"icon_path": "res://data/potion.png"}, "el icono va en"],
		[potion, {"visual_paths": PackedStringArray(["res://assets/a.glb"])}, "solo las armaduras llevan escenas"],
		[helm, {"visual_paths": PackedStringArray(["res://data/a.glb"])}, "no está en res://assets/"],
		[potion, {"category": ItemDefinition.Category.MATERIAL, "ref_id": &"", "camp_refill": 0}, ""],
		[potion, {"category": ItemDefinition.Category.MATERIAL}, "solo las armas, las armaduras y los consumibles llevan ref_id"],
		[potion, {"category": ItemDefinition.Category.QUEST, "ref_id": &"", "equip_slot": ItemDefinition.EquipSlot.HANDS},
				"solo las armas y las armaduras se equipan"],
		[helm, {"icon_path": "res://assets/icons/items/test_iron_helm.png"}, ""],
	]
	for i: int in range(cases.size()):
		var copy: ItemDefinition = _changed(cases[i][0], cases[i][1])
		var expected: String = cases[i][2]
		var errors: PackedStringArray = ItemDatabase.build_from_definitions([copy]).errors
		if expected.is_empty():
			assert_eq(errors, PackedStringArray(), "caso %d: vale (%s)" % [i, cases[i][1]])
			continue
		var found: bool = false
		for message: String in errors:
			found = found or message.contains(expected)
		assert_true(found, "caso %d (%s): «%s» en %s" % [i, cases[i][1], expected, errors])
	# Ids repetidos y dos objetos para la misma arma.
	var twin: ItemDefinition = sword.duplicate() as ItemDefinition
	twin.display_name = "Otra espada"
	var db: ItemDatabase = ItemDatabase.build_from_definitions([sword, twin])
	assert_eq(db.errors, PackedStringArray(["id de objeto repetido: sword_shield_vado"]), "id repetido")
	assert_true(db.get_definition(&"sword_shield_vado") == sword, "se queda el primero que llega")
	var second_sword: ItemDefinition = sword.duplicate() as ItemDefinition
	second_sword.id = &"sword_shield_other"
	var doubled: ItemDatabase = ItemDatabase.build_from_definitions([sword, second_sword])
	assert_eq(doubled.errors.size(), 1, "dos objetos para la misma arma: un error")
	assert_true(doubled.errors.size() == 1 and doubled.errors[0].contains("dos objetos para 'sword_shield'"),
			"«dos objetos para 'sword_shield'»")
	assert_true(doubled.for_ref(ItemDefinition.Category.WEAPON, &"sword_shield") == second_sword,
			"for_ref da el primero por orden alfabético")


## Una carpeta con algo que no es una ItemDefinition, o que no existe.
func test_directory_errors() -> void:
	var stray: ItemDatabase = ItemDatabase.build_from_directory("res://data/progression")
	assert_eq(stray.errors.size(), 1, "la curva no es un objeto")
	assert_true(stray.errors.size() == 1 and stray.errors[0].contains("no es una ItemDefinition"), "lo dice")
	var missing: ItemDatabase = ItemDatabase.build_from_directory("res://data/no_existe")
	assert_eq(missing.all_ids().size(), 0, "una carpeta que no existe da una base vacía")
	assert_eq(missing.errors, PackedStringArray(), "sin errores")
	assert_eq(missing.wire_hash(), ItemDatabase.build_from_definitions([]).wire_hash(), "la huella de vacía")


# --- Utilidades --------------------------------------------------------------------------------

# Los .tres de [param dir] y sus subcarpetas, ordenados.
func _files(dir: String) -> PackedStringArray:
	var result := PackedStringArray()
	for file_name: String in DirAccess.get_files_at(dir):
		if not file_name.ends_with(".uid") and not file_name.ends_with(".import"):
			result.append(dir.path_join(file_name.trim_suffix(".remap")))
	for sub_dir: String in DirAccess.get_directories_at(dir):
		result.append_array(_files(dir.path_join(sub_dir)))
	result.sort()
	return result


func _definitions_in(dir: String) -> Array[ItemDefinition]:
	var definitions: Array[ItemDefinition] = []
	for path: String in _files(dir):
		definitions.append(ResourceLoader.load(path) as ItemDefinition)
	return definitions


func _database_with_armor() -> ItemDatabase:
	var definitions: Array[ItemDefinition] = _definitions_in(ItemDatabase.DATA_DIR)
	definitions.append_array(_definitions_in(ARMOR_FIXTURES))
	return ItemDatabase.build_from_definitions(definitions)


# Una copia de [param definition] con las propiedades de [param changes].
func _changed(definition: ItemDefinition, changes: Dictionary) -> ItemDefinition:
	var copy: ItemDefinition = definition.duplicate() as ItemDefinition
	for property: String in changes:
		copy.set(property, changes[property])
	return copy


# La huella de [param base] con [param changes] en una copia de su segundo objeto.
func _hash_with_change(base: Array[ItemDefinition], changes: Dictionary) -> int:
	var copies: Array[ItemDefinition] = []
	for definition: ItemDefinition in base:
		copies.append(definition)
	copies[1] = _changed(base[1], changes)
	return ItemDatabase.build_from_definitions(copies).wire_hash()
