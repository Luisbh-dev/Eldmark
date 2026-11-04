extends TestCase
## Tests for the item definitions ([ItemDefinition], [ItemDatabase]; docs/progression.md §2.1, §2.2 and
## §2.4, PRG-02): unique, well-formed ids, resources in text, the §2.1 consistency (the ARMOR one with
## [code]tests/fixtures/items/[/code], because [code]data/items/[/code] has no armours in phase 5),
## [code]ref_id[/code]s that exist, one object per weapon and consumable of the templates, alphabetical net ids and
## [method ItemDatabase.wire_hash] stable between two loads.

const ARMOR_FIXTURES: String = "res://tests/fixtures/items/armor"
const BROKEN_FIXTURES: String = "res://tests/fixtures/items/broken"
## What the error says for each broken object in [constant BROKEN_FIXTURES].
const BROKEN_EXPECTED: Dictionary[String, String] = {
	"armor_in_weapon_slot.tres": "una armadura va en una ranura de HEAD a FEET",
	"armor_without_slot.tres": "una armadura va en una ranura de HEAD a FEET",
	"armor_stackable.tres": "no se apila",
}
## The §2.4 objects: category, ref_id, stack, camp_refill and destroyable.
const PHASE_5_ITEMS: Dictionary[StringName, Array] = {
	&"bow_vado": [ItemDefinition.Category.WEAPON, &"bow", 1, 0, false],
	&"potion_health": [ItemDefinition.Category.CONSUMABLE, &"potion_health", 15, 3, true],
	&"potion_stamina": [ItemDefinition.Category.CONSUMABLE, &"potion_stamina", 15, 2, true],
	&"sword_shield_vado": [ItemDefinition.Category.WEAPON, &"sword_shield", 1, 0, false],
}


func test_data_has_no_errors() -> void:
	var db: ItemDatabase = ItemDatabase.build_from_directory(ItemDatabase.DATA_DIR)
	assert_eq(db.errors, PackedStringArray(), "data/items has no errors")
	assert_eq(ItemDatabase.shared().errors, PackedStringArray(), "nor does the shared database")
	assert_true(ItemDatabase.shared() == ItemDatabase.shared(), "shared() loads only once")
	assert_eq(db.all_ids(), [&"bow_vado", &"potion_health", &"potion_stamina", &"sword_shield_vado"],
			"the four §2.4 objects, in alphabetical order")


## Every resource in data/items/ and tests/fixtures/items/ is an ItemDefinition in text, with a well-formed id
## that is not repeated and is its file name, in its category's folder.
func test_ids_unique_formatted_and_resources_in_text() -> void:
	var id_regex := RegEx.new()
	id_regex.compile(ItemDefinition.ID_PATTERN)
	var seen: Dictionary[StringName, String] = {}
	var checked: int = 0
	for dir: String in [ItemDatabase.DATA_DIR, "res://tests/fixtures/items"]:
		for path: String in _files(dir):
			checked += 1
			assert_true(path.ends_with(".tres"), "%s is a .tres (no binaries)" % path)
			var text: String = FileAccess.get_file_as_string(path)
			assert_true(text.begins_with("[gd_resource"), "%s is in text format" % path)
			var definition: ItemDefinition = ResourceLoader.load(path) as ItemDefinition
			if not assert_not_null(definition, "%s is an ItemDefinition" % path):
				continue
			assert_true(id_regex.search(String(definition.id)) != null, "%s: the id '%s' is well-formed" % [
				path, definition.id])
			assert_false(seen.has(definition.id), "the id %s is not repeated (%s, %s)" % [definition.id,
					seen.get(definition.id, ""), path])
			seen[definition.id] = path
			if dir == ItemDatabase.DATA_DIR:
				assert_eq(path.get_file(), "%s.tres" % definition.id, "%s: the file is named after the id" % path)
				var category_name: String = String(ItemDefinition.Category.find_key(definition.category)).to_lower()
				assert_eq(path.get_base_dir().get_file(), category_name,
						"%s is in data/items/<category>/" % path)
	assert_true(checked >= 4 + 3 + BROKEN_EXPECTED.size(), "the data and the cases are reviewed (%d)" % checked)


## §2.4: one object per phase 4 weapon and potion, starter, bound on pickup, level 1 and valueless;
## weapons with no durability or destruction and potions in stacks of 15 that the camp replenishes to 3 and 2.
func test_phase_5_content() -> void:
	var db: ItemDatabase = ItemDatabase.shared()
	for id: StringName in PHASE_5_ITEMS:
		var definition: ItemDefinition = db.get_definition(id)
		if not assert_not_null(definition, "%s exists" % id):
			continue
		var expected: Array = PHASE_5_ITEMS[id]
		assert_eq(definition.category, expected[0], "%s: category" % id)
		assert_eq(definition.ref_id, expected[1], "%s: ref_id" % id)
		assert_eq(definition.max_stack, expected[2], "%s: stack" % id)
		assert_eq(definition.camp_refill, expected[3], "%s: camp_refill" % id)
		assert_eq(definition.destroyable, expected[4], "%s: destroyable" % id)
		assert_true(definition.starter, "%s: starter" % id)
		assert_eq(definition.bind_rule, ItemDefinition.BindRule.ON_PICKUP, "%s: bound on pickup" % id)
		assert_eq(definition.required_level, 1, "%s: level 1" % id)
		assert_eq(definition.base_value, 0, "%s: valueless" % id)
		assert_false(definition.has_durability, "%s: no durability" % id)
		assert_false(definition.display_name.is_empty(), "%s: with a name" % id)
		assert_eq(definition.icon_path, "", "%s: no icon until ART-12 (§16)" % id)
		assert_eq(definition.visual_paths, PackedStringArray(), "%s: no scenes" % id)
		var expected_slot: int = ItemDefinition.EquipSlot.WEAPON \
				if definition.category == ItemDefinition.Category.WEAPON else ItemDefinition.EquipSlot.NONE
		assert_eq(definition.equip_slot, expected_slot, "%s: slot" % id)


## The ref_ids exist: each weapon's in CombatCatalog and each consumable's among its consumables.
func test_ref_ids_exist() -> void:
	var db: ItemDatabase = ItemDatabase.shared()
	var consumable_names: Array[StringName] = []
	for ability_id: int in CombatCatalog.consumable_ids():
		consumable_names.append(CombatCatalog.ability(ability_id).name)
	for id: StringName in db.all_ids():
		var definition: ItemDefinition = db.get_definition(id)
		match definition.category:
			ItemDefinition.Category.WEAPON:
				assert_true(CombatCatalog.weapon_id(definition.ref_id) != 0, "%s: the weapon %s exists" % [
					id, definition.ref_id])
			ItemDefinition.Category.CONSUMABLE:
				assert_true(consumable_names.has(definition.ref_id), "%s: %s is a consumable" % [
					id, definition.ref_id])
			_:
				fail("%s: phase 5 only has weapons and consumables" % id)


## One object per weapon of each template and per consumable (§2.5: the starter kit is made from them), and only one:
## for_ref and consumable_definition find it.
func test_one_item_per_template_weapon_and_consumable() -> void:
	var db: ItemDatabase = ItemDatabase.shared()
	var tables: CombatTables = CombatCatalog.tables()
	assert_true(tables.templates.size() >= 2, "there are templates (%d)" % tables.templates.size())
	for template: EquipmentTemplate in tables.templates:
		for weapon: WeaponDefinition in template.weapons:
			var item: ItemDefinition = db.for_ref(ItemDefinition.Category.WEAPON, weapon.id)
			if assert_not_null(item, "template %s: there is an object for the weapon %s" % [template.id, weapon.id]):
				assert_eq(item.ref_id, weapon.id, "and it is its own")
				assert_eq(item.category, ItemDefinition.Category.WEAPON, "and it is a weapon")
	var consumable_ids: PackedInt32Array = CombatCatalog.consumable_ids()
	assert_eq(consumable_ids.size(), 2, "two consumables (R and T)")
	for index: int in range(consumable_ids.size()):
		var ability_name: StringName = CombatCatalog.ability(consumable_ids[index]).name
		var item: ItemDefinition = db.consumable_definition(index)
		if assert_not_null(item, "there is an object for consumable %d" % index):
			assert_eq(item.ref_id, ability_name, "the one for consumable %d is %s" % [index, ability_name])
			assert_true(db.for_ref(ItemDefinition.Category.CONSUMABLE, ability_name) == item, "for_ref gives the same one")
	assert_eq(db.consumable_definition(0).id, &"potion_health", "R: the health potion")
	assert_eq(db.consumable_definition(1).id, &"potion_stamina", "T: the stamina one")
	assert_null(db.consumable_definition(2), "there is no third consumable")
	assert_null(db.consumable_definition(-1), "nor a negative one")
	assert_null(db.for_ref(ItemDefinition.Category.CONSUMABLE, &"sword_shield"), "a weapon is not a consumable")
	assert_null(db.for_ref(ItemDefinition.Category.WEAPON, &"npc_hollow"), "NPC weapons have no object")
	assert_null(db.for_ref(ItemDefinition.Category.WEAPON, &""), "empty ref")
	var by_ref: Dictionary[String, StringName] = {}
	for id: StringName in db.all_ids():
		var definition: ItemDefinition = db.get_definition(id)
		var key: String = "%d/%s" % [definition.category, definition.ref_id]
		assert_false(by_ref.has(key), "only one object per ref_id in phase 5 (%s and %s)" % [by_ref.get(key, ""), id])
		by_ref[key] = id


func test_net_ids_are_alphabetical() -> void:
	var db: ItemDatabase = ItemDatabase.shared()
	var ids: Array[StringName] = db.all_ids()
	var sorted: Array[StringName] = ids.duplicate()
	sorted.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	assert_eq(ids, sorted, "all_ids in alphabetical order")
	for i: int in range(ids.size()):
		assert_eq(db.net_id_of(ids[i]), i + 1, "%s has net id %d" % [ids[i], i + 1])
		assert_true(db.definition_by_net_id(i + 1) == db.get_definition(ids[i]), "and is found by it")
	assert_eq(db.net_id_of(&"no_existe"), 0, "an unknown id gives 0")
	assert_null(db.get_definition(&"no_existe"), "and no definition")
	assert_null(db.definition_by_net_id(0), "net id 0 is none")
	assert_null(db.definition_by_net_id(ids.size() + 1), "one past the last does not exist")
	assert_null(db.definition_by_net_id(-1), "nor a negative one")
	# With the test objects interleaved, the net ids shift and are still alphabetical.
	var mixed: ItemDatabase = _database_with_armor()
	var mixed_ids: Array[StringName] = mixed.all_ids()
	assert_eq(mixed_ids.size(), ids.size() + 3, "four objects and three armours")
	for i: int in range(mixed_ids.size()):
		assert_eq(mixed.net_id_of(mixed_ids[i]), i + 1, "net id of %s in the mixed base" % mixed_ids[i])
		if i > 0:
			assert_true(String(mixed_ids[i - 1]) < String(mixed_ids[i]), "alphabetical order")


## The fingerprint does not change between two loads, it changes with what gives the net ids meaning and not with anything else.
func test_wire_hash_is_stable() -> void:
	var first: ItemDatabase = ItemDatabase.build_from_directory(ItemDatabase.DATA_DIR)
	var second: ItemDatabase = ItemDatabase.build_from_directory(ItemDatabase.DATA_DIR)
	assert_eq(first.wire_hash(), second.wire_hash(), "two loads, the same fingerprint")
	assert_eq(first.wire_hash(), ItemDatabase.shared().wire_hash(), "that of the shared base")
	assert_true(first.wire_hash() >= 0 and first.wire_hash() <= 0xFFFFFFFF, "u32")
	var base: Array[ItemDefinition] = _definitions_in(ItemDatabase.DATA_DIR)
	var reordered: Array[ItemDefinition] = base.duplicate()
	reordered.reverse()
	assert_eq(ItemDatabase.build_from_definitions(reordered).wire_hash(), first.wire_hash(),
			"the order of arrival does not count")
	for change: Dictionary in [{"max_stack": 14}, {"has_durability": true}, {"category": ItemDefinition.Category.MISC},
			{"equip_slot": ItemDefinition.EquipSlot.HEAD}, {"id": &"potion_zzz"}]:
		assert_true(_hash_with_change(base, change) != first.wire_hash(), "changes with %s" % change)
	for change: Dictionary in [{"display_name": "Otra"}, {"camp_refill": 5}, {"base_value": 7},
			{"required_level": 3}, {"bind_rule": ItemDefinition.BindRule.NONE}]:
		assert_eq(_hash_with_change(base, change), first.wire_hash(), "does not change with %s" % change)
	assert_true(_database_with_armor().wire_hash() != first.wire_hash(), "one more object changes it")


## The ARMOR rule with the test objects: the good ones give no errors and each broken one gives its own.
func test_armor_rule_with_fixtures() -> void:
	var armor: ItemDatabase = ItemDatabase.build_from_directory(ARMOR_FIXTURES)
	assert_eq(armor.errors, PackedStringArray(), "the test armours are valid")
	assert_eq(armor.all_ids().size(), 3, "three armours")
	var helm: ItemDefinition = armor.get_definition(&"test_iron_helm")
	if assert_not_null(helm, "the helmet"):
		assert_eq(helm.category, ItemDefinition.Category.ARMOR, "is an armour")
		assert_true(helm.has_durability and helm.is_equipable(), "with durability and equippable")
	assert_eq(_database_with_armor().errors, PackedStringArray(), "and mixed with data/items neither")
	var broken_files: PackedStringArray = _files(BROKEN_FIXTURES)
	assert_eq(broken_files.size(), BROKEN_EXPECTED.size(), "one case per broken file")
	for path: String in broken_files:
		var expected: String = BROKEN_EXPECTED.get(path.get_file(), "")
		var definition: ItemDefinition = ResourceLoader.load(path) as ItemDefinition
		if not assert_not_null(definition, "%s loads" % path) \
				or not assert_false(expected.is_empty(), "%s has its expected error" % path):
			continue
		var errors: PackedStringArray = ItemDatabase.build_from_definitions([definition]).errors
		assert_eq(errors.size(), 1, "%s: one error (%s)" % [path.get_file(), errors])
		assert_true(errors.size() > 0 and errors[0].contains(expected), "%s: «%s»" % [path.get_file(), expected])
	var all_broken: ItemDatabase = ItemDatabase.build_from_directory(BROKEN_FIXTURES)
	assert_eq(all_broken.errors.size(), BROKEN_EXPECTED.size(), "the whole folder gives one per file")


## Each §2.1 rule, one by one, on a copy of a good object.
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
			assert_eq(errors, PackedStringArray(), "case %d: valid (%s)" % [i, cases[i][1]])
			continue
		var found: bool = false
		for message: String in errors:
			found = found or message.contains(expected)
		assert_true(found, "case %d (%s): \"%s\" in %s" % [i, cases[i][1], expected, errors])
	# Repeated ids and two objects for the same weapon.
	var twin: ItemDefinition = sword.duplicate() as ItemDefinition
	twin.display_name = "Otra espada"
	var db: ItemDatabase = ItemDatabase.build_from_definitions([sword, twin])
	assert_eq(db.errors, PackedStringArray(["id de objeto repetido: sword_shield_vado"]), "repeated id")
	assert_true(db.get_definition(&"sword_shield_vado") == sword, "the first to arrive stays")
	var second_sword: ItemDefinition = sword.duplicate() as ItemDefinition
	second_sword.id = &"sword_shield_other"
	var doubled: ItemDatabase = ItemDatabase.build_from_definitions([sword, second_sword])
	assert_eq(doubled.errors.size(), 1, "two objects for the same weapon: an error")
	assert_true(doubled.errors.size() == 1 and doubled.errors[0].contains("dos objetos para 'sword_shield'"),
			"\"dos objetos para 'sword_shield'\" (two objects for it)")
	assert_true(doubled.for_ref(ItemDefinition.Category.WEAPON, &"sword_shield") == second_sword,
			"for_ref gives the first in alphabetical order")


## A folder with something that is not an ItemDefinition, or that does not exist.
func test_directory_errors() -> void:
	var stray: ItemDatabase = ItemDatabase.build_from_directory("res://data/progression")
	assert_eq(stray.errors.size(), 1, "the curve is not an object")
	assert_true(stray.errors.size() == 1 and stray.errors[0].contains("no es una ItemDefinition"), "it says so")
	var missing: ItemDatabase = ItemDatabase.build_from_directory("res://data/no_existe")
	assert_eq(missing.all_ids().size(), 0, "a folder that does not exist gives an empty base")
	assert_eq(missing.errors, PackedStringArray(), "no errors")
	assert_eq(missing.wire_hash(), ItemDatabase.build_from_definitions([]).wire_hash(), "the empty fingerprint")


# --- Utilities ---------------------------------------------------------------------------------

# The .tres files in [param dir] and its subfolders, sorted.
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


# A copy of [param definition] with the properties from [param changes].
func _changed(definition: ItemDefinition, changes: Dictionary) -> ItemDefinition:
	var copy: ItemDefinition = definition.duplicate() as ItemDefinition
	for property: String in changes:
		copy.set(property, changes[property])
	return copy


# The fingerprint of [param base] with [param changes] on a copy of its second object.
func _hash_with_change(base: Array[ItemDefinition], changes: Dictionary) -> int:
	var copies: Array[ItemDefinition] = []
	for definition: ItemDefinition in base:
		copies.append(definition)
	copies[1] = _changed(base[1], changes)
	return ItemDatabase.build_from_definitions(copies).wire_hash()
