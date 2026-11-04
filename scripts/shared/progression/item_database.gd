class_name ItemDatabase
extends RefCounted
## The item definitions (docs/progresion.md §2.2, PRG-02): reads [code]data/items/[/code] (with
## subfolders) once, lazily like [CombatCatalog], tolerates the [code].tres.remap[/code] files of
## an exported project and logs its errors only once ([method shared]).
## [br][br]
## [b]Net id.[/b] 1..n in alphabetical order of [member ItemDefinition.id]; 0 = none. It changes
## when items are added: it only travels to the owner and is never stored (the database stores the
## [code]id[/code]).
## [b]Fingerprint.[/b] [method wire_hash], u32 of the SHA-256 of the sorted list
## [code](id, net_id, category, equip_slot, max_stack, has_durability)[/code]; it enters the
## [code]sim_hash[/code] (§12) so that a client with a different catalog does not misinterpret the
## net ids.
## [b]Lookups.[/b] [method for_ref] gives the item of a [CombatCatalog] weapon or consumable (in
## phase 5 there is one for each; two is an error) and [method consumable_definition], the
## consumable of each button.
## [br][br]
## [b]Consistency[/b] ([member errors], §2.1): ids with the right format and unique, non-empty
## name, enums in range, stack from 1 to 999 (1 if equippable or has durability), required level
## within the curve, non-negative value, [member ItemDefinition.camp_refill] that fits in a stack;
## WEAPON ⇒ WEAPON slot and [code]ref_id[/code] of a weapon in the combat catalog; ARMOR ⇒ slot
## from HEAD to FEET; CONSUMABLE ⇒ no slot and [code]ref_id[/code] of a consumable; the rest, no
## slot and no [code]ref_id[/code]; icon under [code]res://assets/icons/items/[/code] and scenes
## only on armor. Exported by [ProgressionRulesExport] ([code]items[/code] section). Shared: no
## clock, no randomness.

## Data folder.
const DATA_DIR: String = "res://data/items"
## Cap on definitions: the net id travels in a u16.
const MAX_DEFINITIONS: int = 0xFFFF
## Prefix of icons.
const ICON_PREFIX: String = "res://assets/icons/items/"
## Prefix of armor scenes.
const VISUAL_PREFIX: String = "res://assets/"

## Problems with the data (empty if everything is valid).
var errors: PackedStringArray = PackedStringArray()

# Definitions by net id − 1 (alphabetical order).
var _definitions: Array[ItemDefinition] = []
var _net_ids: Dictionary[StringName, int] = {}
# "category/ref_id" → definition.
var _by_ref: Dictionary[String, ItemDefinition] = {}
# Definition of each button's consumable (index of CombatCatalog.consumable_ids()).
var _consumables: Array[ItemDefinition] = []
var _wire_hash: int = 0

static var _shared: ItemDatabase = null


## The database of [constant DATA_DIR], loaded the first time it is requested. Its errors are
## logged with [code]push_error[/code] only once.
static func shared() -> ItemDatabase:
	if _shared == null:
		_shared = build_from_directory(DATA_DIR)
		for message: String in _shared.errors:
			push_error("[Eldmark] Base de objetos: %s" % message)
	return _shared


## Reads the [code].tres[/code] files in [param dir] and its subfolders and builds the database
## with [method build_from_definitions] and the shared combat catalog. A resource that fails to
## load or is not an [ItemDefinition] counts as an error. It logs no engine errors.
static func build_from_directory(dir: String) -> ItemDatabase:
	var load_errors := PackedStringArray()
	var definitions: Array[ItemDefinition] = []
	for path: String in _resource_paths(dir):
		var resource: Resource = ResourceLoader.load(path)
		if resource == null:
			load_errors.append("no se pudo cargar %s" % path)
		elif not (resource is ItemDefinition):
			load_errors.append("%s no es una ItemDefinition" % path)
		else:
			definitions.append(resource as ItemDefinition)
	var db: ItemDatabase = build_from_definitions(definitions)
	if not load_errors.is_empty():
		load_errors.append_array(db.errors)
		db.errors = load_errors
	return db


## Builds the database with [param definitions] (in any order), checking the [code]ref_id[/code]s
## against [param combat] (null = [method CombatCatalog.tables]). A repeated id is reported and the
## one that comes first in [param definitions] is kept. It logs no engine errors: they stay in
## [member errors].
static func build_from_definitions(definitions: Array[ItemDefinition],
		combat: CombatTables = null) -> ItemDatabase:
	if combat == null:
		combat = CombatCatalog.tables()
	var db := ItemDatabase.new()
	# Alphabetical order by id and, among equal ids, arrival order (sort_custom is not stable).
	var order: Array[int] = []
	for i: int in range(definitions.size()):
		if definitions[i] != null:
			order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var id_a: String = String(definitions[a].id)
		var id_b: String = String(definitions[b].id)
		return id_a < id_b or (id_a == id_b and a < b))
	var sorted: Array[ItemDefinition] = []
	for i: int in order:
		sorted.append(definitions[i])
	var consumable_refs: Dictionary[StringName, int] = {}
	for index: int in range(combat.consumable_ids.size()):
		var ability: AbilityTicks = combat.ability(combat.consumable_ids[index])
		if ability != null:
			consumable_refs[ability.name] = index
	var id_regex := RegEx.new()
	id_regex.compile(ItemDefinition.ID_PATTERN)
	for definition: ItemDefinition in sorted:
		if db._net_ids.has(definition.id):
			db.errors.append("id de objeto repetido: %s" % definition.id)
			continue
		if id_regex.search(String(definition.id)) == null:
			db.errors.append("el id '%s' no tiene el formato %s" % [definition.id, ItemDefinition.ID_PATTERN])
		db._check_definition(definition, combat, consumable_refs)
		db._definitions.append(definition)
		db._net_ids[definition.id] = db._definitions.size()
		db._index_ref(definition)
	if db._definitions.size() > MAX_DEFINITIONS:
		db.errors.append("hay %d objetos y caben %d" % [db._definitions.size(), MAX_DEFINITIONS])
	db._consumables.resize(combat.consumable_ids.size())
	for ref: StringName in consumable_refs:
		db._consumables[consumable_refs[ref]] = db.for_ref(ItemDefinition.Category.CONSUMABLE, ref)
	db._wire_hash = db._compute_wire_hash()
	return db


## The definition with id [param id], or null.
func get_definition(id: StringName) -> ItemDefinition:
	var net_id: int = _net_ids.get(id, 0)
	return _definitions[net_id - 1] if net_id > 0 else null


## Net id of [param id] (1..n in alphabetical order), or 0 if it does not exist.
func net_id_of(id: StringName) -> int:
	return _net_ids.get(id, 0)


## The definition with net id [param net_id], or null (0 or out of range).
func definition_by_net_id(net_id: int) -> ItemDefinition:
	if net_id < 1 or net_id > _definitions.size():
		return null
	return _definitions[net_id - 1]


## The item of the weapon ([code]Category.WEAPON[/code]) or consumable
## ([code]Category.CONSUMABLE[/code]) with id [param ref_id] in [CombatCatalog], or null.
func for_ref(category: int, ref_id: StringName) -> ItemDefinition:
	if ref_id == &"":
		return null
	return _by_ref.get(_ref_key(category, ref_id), null)


## The item of consumable [param index] of [method CombatCatalog.consumable_ids] (0 health, R; 1
## stamina, T), or null.
func consumable_definition(index: int) -> ItemDefinition:
	if index < 0 or index >= _consumables.size():
		return null
	return _consumables[index]


## The ids of all definitions, in net id order (alphabetical).
func all_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for definition: ItemDefinition in _definitions:
		ids.append(definition.id)
	return ids


## u32 fingerprint of what gives the net ids meaning (§2.2): it enters the [code]sim_hash[/code].
func wire_hash() -> int:
	return _wire_hash


# --- Construction ------------------------------------------------------------------------------

# Paths of the resources in [param dir] and its subfolders, sorted (without the .remap of an
# exported project, and only once even if both are present).
static func _resource_paths(dir: String) -> PackedStringArray:
	var paths := PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir):
		return paths
	for file_name: String in DirAccess.get_files_at(dir):
		var plain: String = file_name.trim_suffix(".remap")
		var path: String = dir.path_join(plain)
		if (plain.ends_with(".tres") or plain.ends_with(".res")) and not paths.has(path):
			paths.append(path)
	for sub_dir: String in DirAccess.get_directories_at(dir):
		paths.append_array(_resource_paths(dir.path_join(sub_dir)))
	paths.sort()
	return paths


# The §2.1 rules for a definition; problems go to errors.
func _check_definition(definition: ItemDefinition, combat: CombatTables,
		consumable_refs: Dictionary[StringName, int]) -> void:
	var label: String = "objeto %s" % definition.id
	if definition.display_name.strip_edges().is_empty():
		errors.append("%s: sin nombre" % label)
	if not ItemDefinition.Category.values().has(definition.category):
		errors.append("%s: categoría fuera de rango (%d)" % [label, definition.category])
	if not ItemDefinition.EquipSlot.values().has(definition.equip_slot):
		errors.append("%s: ranura fuera de rango (%d)" % [label, definition.equip_slot])
	if not ItemDefinition.BindRule.values().has(definition.bind_rule):
		errors.append("%s: regla de ligado fuera de rango (%d)" % [label, definition.bind_rule])
	if definition.max_stack < 1 or definition.max_stack > ItemDefinition.MAX_STACK:
		errors.append("%s: max_stack fuera de rango (1-%d): %d" % [label, ItemDefinition.MAX_STACK,
				definition.max_stack])
	if (definition.is_equipable() or definition.has_durability) and definition.max_stack != 1:
		errors.append("%s: un equipable o un objeto con durabilidad no se apila (max_stack 1)" % label)
	var level_cap: int = LevelCurve.shared().level_cap
	if definition.required_level < 1 or definition.required_level > level_cap:
		errors.append("%s: required_level fuera de rango (1-%d): %d" % [label, level_cap,
				definition.required_level])
	if definition.base_value < 0:
		errors.append("%s: base_value negativo" % label)
	if definition.camp_refill < 0 or definition.camp_refill > definition.max_stack:
		errors.append("%s: camp_refill debe caber en una pila (0-%d): %d" % [label, definition.max_stack,
				definition.camp_refill])
	match definition.category:
		ItemDefinition.Category.WEAPON:
			if definition.equip_slot != ItemDefinition.EquipSlot.WEAPON:
				errors.append("%s: un arma va en la ranura WEAPON" % label)
			if not combat.weapon_ids.has(definition.ref_id):
				errors.append("%s: el arma '%s' no está en el catálogo de combate" % [label, definition.ref_id])
		ItemDefinition.Category.ARMOR:
			if definition.equip_slot < ItemDefinition.EquipSlot.HEAD \
					or definition.equip_slot > ItemDefinition.EquipSlot.FEET:
				errors.append("%s: una armadura va en una ranura de HEAD a FEET" % label)
		ItemDefinition.Category.CONSUMABLE:
			if definition.equip_slot != ItemDefinition.EquipSlot.NONE:
				errors.append("%s: un consumible no se equipa" % label)
			if not consumable_refs.has(definition.ref_id):
				errors.append("%s: '%s' no es un consumible del catálogo de combate" % [label,
						definition.ref_id])
		_:
			if definition.equip_slot != ItemDefinition.EquipSlot.NONE:
				errors.append("%s: solo las armas y las armaduras se equipan" % label)
			if definition.ref_id != &"":
				errors.append("%s: solo las armas, las armaduras y los consumibles llevan ref_id" % label)
	if not definition.icon_path.is_empty() and not definition.icon_path.begins_with(ICON_PREFIX):
		errors.append("%s: el icono va en %s" % [label, ICON_PREFIX])
	if not definition.visual_paths.is_empty() and definition.category != ItemDefinition.Category.ARMOR:
		errors.append("%s: solo las armaduras llevan escenas (visual_paths)" % label)
	for path: String in definition.visual_paths:
		if not path.begins_with(VISUAL_PREFIX):
			errors.append("%s: la escena '%s' no está en %s" % [label, path, VISUAL_PREFIX])


# Records the item of its weapon or consumable; two for the same one is an error (in phase 5
# there is one).
func _index_ref(definition: ItemDefinition) -> void:
	if definition.ref_id == &"" or (definition.category != ItemDefinition.Category.WEAPON
			and definition.category != ItemDefinition.Category.CONSUMABLE):
		return
	var key: String = _ref_key(definition.category, definition.ref_id)
	if _by_ref.has(key):
		errors.append("dos objetos para '%s': %s y %s" % [definition.ref_id, _by_ref[key].id, definition.id])
		return
	_by_ref[key] = definition


static func _ref_key(category: int, ref_id: StringName) -> String:
	return "%d/%s" % [category, ref_id]


# SHA-256 of the §2.2 list in net id order: the first 4 bytes as a u32.
func _compute_wire_hash() -> int:
	var parts: Array = []
	for i: int in range(_definitions.size()):
		var definition: ItemDefinition = _definitions[i]
		parts.append([String(definition.id), i + 1, int(definition.category), int(definition.equip_slot),
				definition.max_stack, definition.has_durability])
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(parts))
	return context.finish().decode_u32(0)
