class_name ProgressionRulesExport
extends RefCounted
## Las reglas del juego que necesita la plataforma en Go, en un solo archivo:
## [code]platform/internal/gamedata/progression_rules.json[/code] (docs/progresion.md §13.4,
## docs/plataforma.md §4.4). La plataforma lo incrusta con [code]//go:embed[/code] y valida con él lo
## mismo que la simulación: los nombres de personaje (con [NameRules]) y, con progresion.md, razas,
## apariencia, plantillas de inicio, objetos, curva de niveles, monedas, motivos y contenedores.
## [br][br]
## [method build] es el único generador; [code]tools/progression/export_rules.gd[/code] escribe el
## archivo y [code]tests/test_progression_rules_export.gd[/code] comprueba que el del repositorio
## coincide con [method build]. Si una regla cambia, se vuelve a exportar y el archivo nuevo se sube
## con el cambio.
## [br][br]
## Secciones de docs/plataforma.md: [code]protocol_version[/code] (el
## [code]ELDMARK_MIN_PROTOCOL[/code] por defecto en dev y test) y [code]names[/code]. De
## docs/progresion.md: [code]races[/code] y [code]appearance[/code] ([AppearanceCatalog]),
## [code]level_curve[/code] ([LevelCurve]), [code]currencies[/code], [code]reasons[/code],
## [code]containers[/code] y [code]combat[/code] ([CombatRules]), de P3; [code]items[/code]
## ([ItemDatabase]) y [code]starter_templates[/code] (las [EquipmentTemplate] elegibles), de P1.
## Sin estado, reloj ni azar: dos llamadas dan lo mismo.

## Ruta del archivo, relativa a la raíz del proyecto.
const OUTPUT_PATH: String = "res://platform/internal/gamedata/progression_rules.json"

## Monedas (§5.1): código → id y tope. Hasta que progresion.md P2 cree [code]Currency[/code]; entonces
## [method _currencies] lee de ahí ([code]Currency.Code[/code], [code]Currency.CAP[/code]) y el archivo
## no cambia.
const CURRENCIES: Array[Dictionary] = [
	{"code": 1, "id": "gold", "cap": 1_000_000_000},
	{"code": 2, "id": "merits", "cap": 1_000_000_000},
]
## Rangos de los motivos (§5.3): fuentes ([code]delta > 0[/code]), sumideros ([code]delta < 0[/code]) e
## internos (cualquier signo). Los lee [code]EconomyReason[/code] de progresion.md P2.
const REASON_RANGES: Dictionary = {
	"source": {"min": 1, "max": 63},
	"sink": {"min": 64, "max": 127},
	"internal": {"min": 128, "max": 191},
}
## Motivos (§5.3), fijos: nunca se reutilizan. Los de fases siguientes ya tienen su número.
const REASON_CODES: Dictionary = {
	"starter_kit": 1, "camp_refill": 2, "pvp_kill": 3, "pvp_assist": 4, "objective": 5, "npc_kill": 6,
	"gm_grant": 7, "loot": 8, "quest": 9, "vendor_sell": 10, "trade_in": 11, "mail_in": 12,
	"craft_output": 13,
	"player_destroy": 64, "consume": 65, "gm_remove": 66, "vendor_buy": 67, "repair": 68, "respec": 69,
	"trade_out": 70, "mail_out": 71, "craft_input": 72, "quartermaster": 73, "market_fee": 74,
	"reversal": 128, "migration": 129,
}
## Tipos de operación ([code]economy_ops.kind[/code], [code]EconomyOp.Kind[/code] del servidor, §5.3);
## del 9 al 15, reservados. [code]EconomyOp[/code] (progresion.md P5a) tiene que dar los mismos números.
const OP_KINDS: Dictionary = {
	"player": 1, "gameplay": 2, "starter_kit": 3, "gm": 4, "reversal": 5, "migration": 6, "trade": 7,
	"mail": 8,
}
## Contenedores y ranuras (§4.1). Hasta que progresion.md P2 cree [code]InventoryState[/code]; entonces
## [method _containers] lee sus constantes y el archivo no cambia.
const CONTAINERS: Dictionary = {
	"bag": {"code": 0, "default_slots": 30, "max_slots": 120},
	"equipment": {"code": 1, "slots": 7, "open_slots": 2},
	"open": [0, 1],
}


## Las reglas exportadas, una clave por sección.
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


## El texto del archivo: [method build] en JSON con las claves ordenadas, tabuladores y un salto de
## línea al final.
static func to_json() -> String:
	return JSON.stringify(build(), "\t", true) + "\n"


## Sección [code]names[/code]: lo que [NameRules] necesita para [method NameRules.validate] y
## [method NameRules.normalize_key]. [code]reserved[/code] va tal como está escrito en
## [constant NameRules.RESERVED]: la plataforma lo normaliza con la misma regla.
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


## Sección [code]races[/code] (§7.1, §7.2): los pueblos en el orden del catálogo (la posición es el byte
## 0 − 1), con su reino en el código de [enum NetProtocol.Realm] (1–3), los índices permitidos de cada
## lista y [code]allows_no_hair[/code] y [code]allows_no_beard[/code].
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


## Sección [code]appearance[/code] (§7.2): de cada lista de piezas con forma (cabezas, peinados, barbas y
## marcas), sus ids y cuerpos compatibles (vacío = todos); de los cuerpos y los colores, cuántos hay. Con
## esto y [code]races[/code], Go aplica la regla entera de [method CharacterAppearance.validate].
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


## Sección [code]level_curve[/code] (§6.1): la tabla tal cual.
static func _level_curve() -> Dictionary:
	var curve: LevelCurve = LevelCurve.shared()
	return {
		"level_cap": curve.level_cap,
		"xp_to_next": _ints(curve.xp_to_next),
		"attribute_points_per_level": curve.attribute_points_per_level,
	}


## Sección [code]currencies[/code] (§5.1): código, id y tope de cada moneda.
static func _currencies() -> Array:
	return CURRENCIES.duplicate(true)


## Sección [code]reasons[/code] (§5.3): rangos, motivos y tipos de operación.
static func _reasons() -> Dictionary:
	return {
		"ranges": REASON_RANGES.duplicate(true),
		"codes": REASON_CODES.duplicate(),
		"op_kinds": OP_KINDS.duplicate(),
	}


## Sección [code]containers[/code] (§4.1): la bolsa, el equipo y los contenedores abiertos en la fase 5.
static func _containers() -> Dictionary:
	return CONTAINERS.duplicate(true)


## Sección [code]combat[/code]: la vida máxima, para la comprobación S6 de [code]health[/code].
static func _combat() -> Dictionary:
	return {"health_max": CombatCatalog.rules().health_max}


## Sección [code]items[/code] (§2.1, §13.4): por definición, en orden de net id (alfabético), lo que la
## plataforma comprueba en un guardado (S5): id, categoría y ranura (los números de [ItemDefinition]), pila,
## durabilidad y nivel requerido.
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


## Sección [code]starter_templates[/code] (§2.5, §13.4): las [EquipmentTemplate] con
## [code]selectable = true[/code], en el orden de su id, con los objetos de sus armas en orden de ranura
## ([method ItemDatabase.for_ref]; un arma sin objeto sale como cadena vacía, y la plataforma rechaza el
## archivo). Con ellas la plataforma valida [code]starter_template_id[/code] al crear el personaje.
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


## Un [PackedInt32Array] como [Array] de enteros (JSON con números enteros).
static func _ints(values: PackedInt32Array) -> Array:
	var result: Array = []
	for value: int in values:
		result.append(value)
	return result
