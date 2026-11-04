class_name ProgressionRulesExport
extends RefCounted
## The game rules the Go platform needs, in a single file:
## [code]platform/internal/gamedata/progression_rules.json[/code] (docs/progresion.md §13.4,
## docs/plataforma.md §4.4). The platform embeds it with [code]//go:embed[/code] and uses it to
## validate the same things as the simulation: character names (with [NameRules]) and, with
## progresion.md, races, appearance, starter templates, items, level curve, currencies, reasons and
## containers.
## [br][br]
## [method build] is the only generator; [code]tools/progression/export_rules.gd[/code] writes the
## file and [code]tests/test_progression_rules_export.gd[/code] checks that the one in the
## repository matches [method build]. If a rule changes, it is re-exported and the new file is
## committed with the change.
## [br][br]
## Sections from docs/plataforma.md: [code]protocol_version[/code] (the default
## [code]ELDMARK_MIN_PROTOCOL[/code] in dev and test) and [code]names[/code]. From
## docs/progresion.md: [code]races[/code] and [code]appearance[/code] ([AppearanceCatalog]),
## [code]level_curve[/code] ([LevelCurve]), [code]currencies[/code] ([Currency]),
## [code]reasons[/code] ([EconomyReason] and [constant OP_KINDS]), [code]containers[/code]
## ([InventoryState]) and [code]combat[/code] ([CombatRules]), from P3 (P2 made them read from
## their classes without changing the file); [code]items[/code] ([ItemDatabase]) and
## [code]starter_templates[/code] (the selectable [EquipmentTemplate]s), from P1. No state, clock
## or randomness: two calls give the same result.

## Path of the file, relative to the project root.
const OUTPUT_PATH: String = "res://platform/internal/gamedata/progression_rules.json"

## Operation kinds ([code]economy_ops.kind[/code], server-side [code]EconomyOp.Kind[/code], §5.3);
## 9 to 15, reserved. [code]EconomyOp[/code] (progresion.md P5a) must give the same numbers.
const OP_KINDS: Dictionary = {
	"player": 1, "gameplay": 2, "starter_kit": 3, "gm": 4, "reversal": 5, "migration": 6, "trade": 7,
	"mail": 8,
}


## The exported rules, one key per section.
static func build() -> Dictionary:
	return {
		"protocol_version": NetProtocol.PROTOCOL_VERSION,
		"names": _names(),
		"races": _races(),
		"appearance": _appearance(),
		"level_curve": _level_curve(),
		"currencies": _currencies(),
		"reasons": _reasons(),
		"containers": _containers(),
		"combat": _combat(),
		"items": _items(),
		"starter_templates": _starter_templates(),
	}


## The text of the file: [method build] as JSON with sorted keys, tabs and a trailing newline.
static func to_json() -> String:
	return JSON.stringify(build(), "\t", true) + "\n"


## [code]names[/code] section: what [NameRules] needs for [method NameRules.validate] and
## [method NameRules.normalize_key]. [code]reserved[/code] goes exactly as written in
## [constant NameRules.RESERVED]: the platform normalizes it with the same rule.
static func _names() -> Dictionary:
	var folded: Dictionary = {}
	for letter: String in NameRules.FOLDED:
		folded[letter] = NameRules.FOLDED[letter]
	var reserved: Array[String] = []
	reserved.assign(NameRules.RESERVED)
	return {
		"min_length": NameRules.MIN_LENGTH,
		"max_length": NameRules.MAX_LENGTH,
		"upper_letters": NameRules.UPPER_LETTERS,
		"lower_letters": NameRules.LOWER_LETTERS,
		"folded": folded,
		"reserved": reserved,
	}


## [code]races[/code] section (§7.1, §7.2): the peoples in catalog order (the position is byte
## 0 − 1), with their realm as an [enum NetProtocol.Realm] code (1–3), the allowed indices of each
## list and [code]allows_no_hair[/code] and [code]allows_no_beard[/code].
static func _races() -> Array:
	var result: Array = []
	for race: RaceDefinition in AppearanceCatalog.shared().races:
		var entry: Dictionary = {
			"id": String(race.id),
			"realm": RealmCatalog.code_of(race.realm),
			"allows_no_hair": race.allows_no_hair,
			"allows_no_beard": race.allows_no_beard,
		}
		for category: StringName in AppearanceCatalog.PART_CATEGORIES + AppearanceCatalog.COLOR_CATEGORIES:
			entry[String(category)] = _ints(race.allowed(category))
		result.append(entry)
	return result


## [code]appearance[/code] section (§7.2): for each list of shaped parts (heads, hairstyles, beards
## and marks), their ids and compatible bodies (empty = all); for bodies and colors, how many there
## are. With this and [code]races[/code], Go applies the whole rule of
## [method CharacterAppearance.validate].
static func _appearance() -> Dictionary:
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var result: Dictionary = {
		"body_count": catalog.bodies.size(),
		"skin_tone_count": catalog.skin_tones.size(),
		"hair_color_count": catalog.hair_colors.size(),
		"eye_color_count": catalog.eye_colors.size(),
	}
	for category: StringName in [&"heads", &"hairs", &"beards", &"marks"]:
		var parts: Array = []
		for part: AppearancePart in catalog.entries(category):
			parts.append({"id": String(part.id), "bodies": _ints(part.bodies)})
		result[String(category)] = parts
	return result


## [code]level_curve[/code] section (§6.1): the table as is.
static func _level_curve() -> Dictionary:
	var curve: LevelCurve = LevelCurve.shared()
	return {
		"level_cap": curve.level_cap,
		"xp_to_next": _ints(curve.xp_to_next),
		"attribute_points_per_level": curve.attribute_points_per_level,
	}


## [code]currencies[/code] section (§5.1): code, id and cap of each currency ([Currency]).
static func _currencies() -> Array:
	var result: Array = []
	for code: int in Currency.codes():
		result.append({"code": code, "id": Currency.id_of(code), "cap": Currency.cap_of(code)})
	return result


## [code]reasons[/code] section (§5.3): ranges and reasons ([EconomyReason]) and operation kinds
## ([constant OP_KINDS]).
static func _reasons() -> Dictionary:
	var codes: Dictionary = {}
	for reason_name: String in EconomyReason.CODES:
		codes[reason_name] = EconomyReason.CODES[reason_name]
	return {
		"ranges": EconomyReason.ranges(),
		"codes": codes,
		"op_kinds": OP_KINDS.duplicate(),
	}


## [code]containers[/code] section (§4.1): the bag, equipment and the containers open in phase 5
## ([InventoryState]).
static func _containers() -> Dictionary:
	var open: Array = []
	for container: int in InventoryState.OPEN_CONTAINERS:
		open.append(container)
	return {
		"bag": {
			"code": InventoryState.ContainerId.BAG,
			"default_slots": InventoryState.BAG_SLOTS_DEFAULT,
			"max_slots": InventoryState.BAG_SLOTS_MAX,
		},
		"equipment": {
			"code": InventoryState.ContainerId.EQUIPMENT,
			"slots": InventoryState.EQUIPMENT_SLOTS,
			"open_slots": InventoryState.OPEN_EQUIPMENT_SLOTS,
		},
		"open": open,
	}


## [code]combat[/code] section: the maximum health, for the S6 check of [code]health[/code].
static func _combat() -> Dictionary:
	return {"health_max": CombatCatalog.rules().health_max}


## [code]items[/code] section (§2.1, §13.4): per definition, in net id order (alphabetical), what
## the platform checks in a save (S5): id, category and slot (the numbers from [ItemDefinition]),
## stack, durability and required level.
static func _items() -> Array:
	var db: ItemDatabase = ItemDatabase.shared()
	var result: Array = []
	for id: StringName in db.all_ids():
		var definition: ItemDefinition = db.get_definition(id)
		result.append({
			"id": String(definition.id),
			"category": int(definition.category),
			"equip_slot": int(definition.equip_slot),
			"max_stack": definition.max_stack,
			"has_durability": definition.has_durability,
			"required_level": definition.required_level,
		})
	return result


## [code]starter_templates[/code] section (§2.5, §13.4): the [EquipmentTemplate]s with
## [code]selectable = true[/code], in id order, with the items of their weapons in slot order
## ([method ItemDatabase.for_ref]; a weapon without an item comes out as an empty string, and the
## platform rejects the file). With them the platform validates [code]starter_template_id[/code]
## when creating the character.
static func _starter_templates() -> Array:
	var db: ItemDatabase = ItemDatabase.shared()
	var result: Array = []
	for template: EquipmentTemplate in CombatCatalog.tables().templates:
		if not template.selectable:
			continue
		var weapons: Array = []
		for weapon: WeaponDefinition in template.weapons:
			var item: ItemDefinition = db.for_ref(ItemDefinition.Category.WEAPON, weapon.id) if weapon != null else null
			weapons.append(String(item.id) if item != null else "")
		result.append({"id": String(template.id), "weapons": weapons})
	return result


## A [PackedInt32Array] as an [Array] of integers (JSON with whole numbers).
static func _ints(values: PackedInt32Array) -> Array:
	var result: Array = []
	for value: int in values:
		result.append(value)
	return result
