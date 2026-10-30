extends TestCase
## Pruebas de [ProgressRecord] (docs/progresion.md §3.4 y §15 P5a): el formato es el que declara la zona al
## registrarse, la ida y vuelta por [method ProgressRecord.to_claim_dictionary], [method JSON.stringify],
## [method JSON.parse_string] y [method ProgressRecord.from_dictionary] campo a campo (con posición y sin ella), los
## ids en cadena (un id como número no vale), los enteros reescritos como [code]820.0[/code], null ante cada clave
## que falta o que no conoce y cada valor fuera de rango, y [method ProgressRecord.to_dictionary] sin los campos de
## solo lectura.

const SAVED_AT: int = 1793282400
## La apariencia del ejemplo de §3.4 (válida para race_vardheim, §19.4).
const APPEARANCE_B64: String = "AQAAAQEDAgE="


# Un registro con todo: nivel 8 con 12345 de XP (I8), posición, vida, monedas, objetos en la bolsa y en el equipo
# y temporizadores. [param with_location]: con posición (y su saved_at_unix) o sin ella.
func _rich_record(with_location: bool = true) -> ProgressRecord:
	var db: ItemDatabase = ItemDatabase.shared()
	var record: ProgressRecord = ProgressRecord.new_character()
	record.race_id = &"race_vardheim"
	record.appearance = Marshalls.base64_to_raw(APPEARANCE_B64)
	record.starter_template_id = &"squire"
	record.starter_granted = true
	record.level = 8
	record.xp_total = 12345
	record.realm_points = 420
	record.played_seconds = 5400
	record.active_weapon_slot = 1
	record.health = 820
	if with_location:
		record.location = {"zone_id": "vado_gris", "channel": 0, "x": 12.5, "y": 0.0, "z": -40.25, "yaw": 1.5,
				"in_combat": false, ProgressRecord.LOCATION_CLAIM_KEY: SAVED_AT}
	record.wallets[Currency.Code.GOLD] = 150
	record.wallets[Currency.Code.MERITS] = 3200
	record.inventory.set_item(InventoryState.ContainerId.EQUIPMENT, 0,
			ItemInstance.create(1025, db.get_definition(&"sword_shield_vado"), 1))
	record.inventory.set_item(InventoryState.ContainerId.EQUIPMENT, 1,
			ItemInstance.create(1026, db.get_definition(&"bow_vado"), 1))
	record.inventory.set_item(InventoryState.ContainerId.BAG, 1,
			ItemInstance.create(1027, db.get_definition(&"potion_health"), 3))
	var unbound: ItemInstance = ItemInstance.create(1028, db.get_definition(&"potion_stamina"), 15)
	unbound.bound = false
	unbound.seed = 4294967295
	record.inventory.set_item(InventoryState.ContainerId.BAG, 29, unbound)
	record.timers["unstuck"] = SAVED_AT + 300
	record.timers["capture:vado_gris_fort"] = SAVED_AT + 1800
	return record


# La forma de la reclamación de [param record] tras pasar por el texto JSON, como llega a la zona.
func _through_json(record: ProgressRecord) -> Dictionary:
	var text: String = JSON.stringify(record.to_claim_dictionary(SAVED_AT))
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _assert_same(actual: ProgressRecord, expected: ProgressRecord, label: String) -> void:
	if not assert_not_null(actual, "%s: se lee" % label):
		return
	for field: String in ["race_id", "appearance", "level", "xp_total", "realm_points", "played_seconds",
			"bag_slots", "starter_template_id", "starter_granted", "active_weapon_slot", "health", "location",
			"wallets", "timers"]:
		assert_eq(actual.get(field), expected.get(field), "%s: %s" % [label, field])
	assert_true(actual.inventory.equals(expected.inventory), "%s: el inventario, objeto a objeto" % label)
	assert_true(actual.equals(expected), "%s: equals" % label)


func test_format_is_the_record_format_of_the_zone() -> void:
	assert_eq(ProgressRecord.FORMAT, ZonePlatform.RECORD_FORMAT, "progress_format = record_format del registro")
	assert_eq(ProgressRecord.new_character().to_dictionary()["progress_format"], ZonePlatform.RECORD_FORMAT,
			"y lo que sale en el guardado")


func test_new_character_has_the_defaults() -> void:
	var record: ProgressRecord = ProgressRecord.new_character()
	assert_eq([record.level, record.xp_total, record.realm_points, record.played_seconds, record.bag_slots],
			[1, 0, 0, 0, 30], "nivel 1, nada ganado, bolsa de 30")
	assert_eq([record.starter_granted, record.active_weapon_slot, record.health], [false, 0, -1],
			"sin kit, WEAPON_1 y la vida llena")
	assert_true(record.location.is_empty() and record.timers.is_empty() and record.inventory.all_items().is_empty(),
			"sin posición, temporizadores ni objetos")
	assert_eq(record.wallets, PackedInt64Array([0, 0, 0]), "monedas a 0 (índice = moneda)")
	var data: Dictionary = record.to_dictionary()
	assert_eq([data["health"], data["location"]], [null, null], "health y location null en JSON")
	assert_eq(data["wallets"], [{"currency": 1, "balance": 0}, {"currency": 2, "balance": 0}],
			"un saldo por moneda, en orden")


func test_round_trip_through_json_with_location() -> void:
	var record: ProgressRecord = _rich_record(true)
	var data: Dictionary = _through_json(record)
	assert_eq(typeof(data["level"]), TYPE_FLOAT, "parse_string devuelve los números como float")
	_assert_same(ProgressRecord.from_dictionary(data, ItemDatabase.shared()), record, "con posición")


func test_round_trip_through_json_without_location() -> void:
	var record: ProgressRecord = _rich_record(false)
	var data: Dictionary = _through_json(record)
	assert_eq(data["location"], null, "location null")
	_assert_same(ProgressRecord.from_dictionary(data, ItemDatabase.shared()), record, "sin posición")
	var fresh: ProgressRecord = ProgressRecord.new_character()
	fresh.race_id = &"race_solmarch"
	fresh.appearance = CharacterAppearance.default_for(AppearanceCatalog.shared(),
			AppearanceCatalog.shared().race_index(&"race_solmarch")).encode()
	_assert_same(ProgressRecord.from_dictionary(_through_json(fresh), null), fresh, "un personaje recién creado")


func test_the_claim_example_of_the_document_reads() -> void:
	# El ejemplo de §3.4 tal cual (con los ids en cadena y los enteros como números).
	var text: String = '{"progress_format": 1, "race_id": "race_vardheim", "appearance": "AQAAAQEDAgE=", \
"starter_template_id": "squire", "starter_granted": true, "level": 8, "xp_total": 12345, "realm_points": 420, \
"played_seconds": 5400, "bag_slots": 30, "active_weapon_slot": 0, "health": 820, "location": {"zone_id": \
"vado_gris", "channel": 0, "x": 12.5, "y": 0.0, "z": -40.25, "yaw": 1.57, "in_combat": false, \
"saved_at_unix": 1793282400}, "wallets": [{"currency": 1, "balance": 150}, {"currency": 2, "balance": 3200}], \
"items": [{"uid": "1025", "def_id": "sword_shield_vado", "container": 1, "slot": 0, "count": 1, "durability": \
null, "rarity": 0, "bound": true, "seed": "0", "affixes": []}, {"uid": "1027", "def_id": "potion_health", \
"container": 0, "slot": 1, "count": 3, "durability": null, "rarity": 0, "bound": true, "seed": "0", \
"affixes": []}], "timers": [{"key": "unstuck", "ends_at_unix": 1793282700}]}'
	var record: ProgressRecord = ProgressRecord.from_dictionary(JSON.parse_string(text), null)
	if assert_not_null(record, "el ejemplo de §3.4 se lee"):
		assert_eq(record.inventory.get_item(InventoryState.ContainerId.BAG, 1).count, 3, "la poción en la bolsa")
		assert_eq(record.timers, {"unstuck": 1793282700}, "el temporizador")
		assert_eq(record.location["saved_at_unix"], 1793282400, "saved_at_unix")


func test_to_dictionary_has_no_read_only_fields() -> void:
	var data: Dictionary = _rich_record(true).to_dictionary()
	var keys: Array = data.keys()
	keys.sort()
	assert_eq(keys, Array(ProgressRecord.SAVE_KEYS), "las claves del guardado (§9.3)")
	for key: String in ProgressRecord.CLAIM_ONLY_KEYS:
		assert_false(data.has(key), "sin %s" % key)
	assert_false((data["location"] as Dictionary).has("saved_at_unix"), "location sin saved_at_unix")
	assert_eq(typeof((data["items"] as Array)[0]["uid"]), TYPE_STRING, "uid en cadena")
	assert_eq(data["timers"], [{"key": "capture:vado_gris_fort", "ends_at_unix": SAVED_AT + 1800},
			{"key": "unstuck", "ends_at_unix": SAVED_AT + 300}], "temporizadores por clave")
	var claim: Dictionary = _rich_record(true).to_claim_dictionary(SAVED_AT)
	assert_eq([claim["race_id"], claim["appearance"], claim["starter_template_id"]],
			["race_vardheim", APPEARANCE_B64, "squire"], "la reclamación los lleva")
	assert_eq(claim["location"]["saved_at_unix"], SAVED_AT, "y saved_at_unix")


func test_ids_must_be_decimal_strings() -> void:
	var base: Dictionary = _through_json(_rich_record())
	assert_not_null(ProgressRecord.from_dictionary(base, null), "el de partida se lee")
	# [etiqueta, campo del primer objeto, valor]
	var cases: Array = [
		["uid como número", "uid", 1027],
		["uid como número con decimales", "uid", 1027.0],
		["seed como número", "seed", 0],
		["uid no entero", "uid", "12.5"],
		["uid con letras", "uid", "abc"],
		["uid con cero delante", "uid", "01027"],
		["uid con signo", "uid", "+1027"],
		["uid 0", "uid", "0"],
		["uid de 2^53", "uid", "9007199254740992"],
		["uid de 30 cifras", "uid", "123456789012345678901234567890"],
		["seed por encima de u32", "seed", "4294967296"],
	]
	for entry: Array in cases:
		var data: Dictionary = base.duplicate(true)
		data["items"][0][entry[1]] = entry[2]
		assert_null(ProgressRecord.from_dictionary(data, null), entry[0])
	var largest: Dictionary = base.duplicate(true)
	largest["items"][0]["uid"] = "9007199254740991"
	assert_not_null(ProgressRecord.from_dictionary(largest, null), "uid de 2^53 − 1 vale")


func test_integers_rewritten_as_floats_are_accepted() -> void:
	var data: Dictionary = _rich_record().to_claim_dictionary(SAVED_AT)
	data["level"] = 8.0
	data["health"] = 820.0
	data["items"][0]["count"] = 3.0
	data["items"][1]["slot"] = 29.0
	data["wallets"][0]["balance"] = 150.0
	data["timers"][0]["ends_at_unix"] = float(SAVED_AT + 1800)
	var record: ProgressRecord = ProgressRecord.from_dictionary(data, null)
	if assert_not_null(record, "820.0 vale donde va un entero"):
		assert_eq([record.level, record.health, record.wallets[1]], [8, 820, 150], "y se lee como entero")
		assert_eq(typeof(record.level), TYPE_INT, "int")
	data["health"] = 820.5
	assert_null(ProgressRecord.from_dictionary(data, null), "820.5 no")


func test_missing_unknown_and_out_of_range_values_are_null() -> void:
	var base: Dictionary = _through_json(_rich_record())
	# En base, items es [poción de vida (bolsa 1), poción de resistencia (bolsa 29), espada (equipo 0), arco (equipo
	# 1)]: el orden de InventoryState.occupied_slots.
	assert_eq(base["items"].map(func(i: Dictionary) -> String: return i["def_id"]),
			["potion_health", "potion_stamina", "sword_shield_vado", "bow_vado"], "el orden de los objetos")
	for key: String in base:
		var missing: Dictionary = base.duplicate(true)
		missing.erase(key)
		assert_null(ProgressRecord.from_dictionary(missing, null), "sin %s" % key)
	for label: String in BROKEN_CASES:
		var data: Dictionary = base.duplicate(true)
		_break(data, label)
		assert_null(ProgressRecord.from_dictionary(data, null), label)
	assert_not_null(ProgressRecord.from_dictionary(base, null), "el de partida sigue leyéndose")
	var sixteen: Dictionary = base.duplicate(true)
	for i: int in 14:
		sixteen["timers"].append({"key": "k%d" % i, "ends_at_unix": SAVED_AT})
	assert_not_null(ProgressRecord.from_dictionary(sixteen, null), "16 temporizadores valen")


const BROKEN_CASES: Array[String] = [
	"una clave de más", "ops en la reclamación", "progress_format 2", "nivel que no cuadra con la XP (I8)", "nivel 0",
	"nivel 41", "XP negativa", "XP por encima del tope", "puntos de reino negativos", "bag_slots 0", "bag_slots 121",
	"ranura activa 2", "starter_granted como número", "vida por encima del máximo", "vida negativa", "raza vacía",
	"raza con mayúsculas", "plantilla como número", "apariencia de 7 B", "apariencia de 9 B",
	"apariencia que no es base64", "apariencia en base64 no canónico", "apariencia como lista",
	"location sin saved_at_unix", "location con una clave de más", "location sin zona", "location con la x en texto",
	"location como lista", "canal negativo", "moneda repetida", "moneda que no existe", "saldo por encima del tope",
	"saldo negativo", "monedero con una clave de más", "objeto en el banco", "objeto fuera de la bolsa",
	"arma en la ranura 2 del equipo", "poción en el equipo", "dos objetos en la misma ranura",
	"el mismo uid dos veces", "un objeto que no existe", "pila por encima del máximo", "durabilidad en una poción",
	"items como objeto", "17 temporizadores", "temporizador con mayúsculas", "temporizador de 49 caracteres",
	"temporizador repetido", "temporizador sin fin",
]


# Rompe [param data] (la forma de la reclamación de _rich_record) como dice [param label].
func _break(data: Dictionary, label: String) -> void:
	var items: Array = data["items"]
	match label:
		"una clave de más":
			data["mood"] = 1
		"ops en la reclamación":
			data["ops"] = []
		"progress_format 2":
			data["progress_format"] = 2
		"nivel que no cuadra con la XP (I8)":
			data["level"] = 9
		"nivel 0":
			data["level"] = 0
		"nivel 41":
			data["level"] = 41
		"XP negativa":
			data["xp_total"] = -1
		"XP por encima del tope":
			data["xp_total"] = LevelCurve.shared().total_to(40) + 1
			data["level"] = 40
		"puntos de reino negativos":
			data["realm_points"] = -5
		"bag_slots 0":
			data["bag_slots"] = 0
		"bag_slots 121":
			data["bag_slots"] = 121
		"ranura activa 2":
			data["active_weapon_slot"] = 2
		"starter_granted como número":
			data["starter_granted"] = 1
		"vida por encima del máximo":
			data["health"] = CombatCatalog.rules().health_max + 1
		"vida negativa":
			data["health"] = -1
		"raza vacía":
			data["race_id"] = ""
		"raza con mayúsculas":
			data["race_id"] = "Race_Vardheim"
		"plantilla como número":
			data["starter_template_id"] = 3
		"apariencia de 7 B":
			data["appearance"] = Marshalls.raw_to_base64(PackedByteArray([1, 0, 0, 1, 1, 3, 2]))
		"apariencia de 9 B":
			data["appearance"] = Marshalls.raw_to_base64(PackedByteArray([1, 0, 0, 1, 1, 3, 2, 1, 0]))
		"apariencia que no es base64":
			data["appearance"] = "AQAAAQED*gE="
		"apariencia en base64 no canónico":
			data["appearance"] = "AQAAAQEDAgF="
		"apariencia como lista":
			data["appearance"] = [1, 0, 0, 1, 1, 3, 2, 1]
		"location sin saved_at_unix":
			(data["location"] as Dictionary).erase("saved_at_unix")
		"location con una clave de más":
			data["location"]["floor"] = 2
		"location sin zona":
			data["location"]["zone_id"] = ""
		"location con la x en texto":
			data["location"]["x"] = "12.5"
		"location como lista":
			data["location"] = []
		"canal negativo":
			data["location"]["channel"] = -1
		"moneda repetida":
			data["wallets"].append({"currency": 1, "balance": 3})
		"moneda que no existe":
			data["wallets"].append({"currency": 3, "balance": 3})
		"saldo por encima del tope":
			data["wallets"][0]["balance"] = Currency.CAP + 1
		"saldo negativo":
			data["wallets"][0]["balance"] = -1
		"monedero con una clave de más":
			data["wallets"][0]["last_seq"] = 4
		"objeto en el banco":
			items[0]["container"] = 2
		"objeto fuera de la bolsa":
			items[0]["slot"] = 30
		"arma en la ranura 2 del equipo":
			items[2]["slot"] = 2
		"poción en el equipo":
			items.remove_at(2)
			items[0]["container"] = 1
			items[0]["slot"] = 0
		"dos objetos en la misma ranura":
			items[1]["slot"] = 1
		"el mismo uid dos veces":
			items[3]["uid"] = items[0]["uid"]
		"un objeto que no existe":
			items[0]["def_id"] = "potion_mana"
		"pila por encima del máximo":
			items[0]["count"] = 16
		"durabilidad en una poción":
			items[0]["durability"] = 500
		"items como objeto":
			data["items"] = {}
		"17 temporizadores":
			for i: int in 15:
				data["timers"].append({"key": "k%d" % i, "ends_at_unix": SAVED_AT})
		"temporizador con mayúsculas":
			data["timers"][0]["key"] = "Unstuck"
		"temporizador de 49 caracteres":
			data["timers"][0]["key"] = "a".repeat(49)
		"temporizador repetido":
			data["timers"][1]["key"] = data["timers"][0]["key"]
		"temporizador sin fin":
			(data["timers"][0] as Dictionary).erase("ends_at_unix")
		_:
			fail("caso desconocido: %s" % label)
