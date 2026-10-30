extends TestCase
## Pruebas de [ItemInstance] (docs/progresion.md §2.1, §2.3 y §3.4, PRG-02): ida y vuelta de 1000 instancias
## aleatorias con semilla, en binario y en diccionario (pasando por el texto JSON, como el registro de la
## plataforma), y null en cada caso de §2.3 sin errores del motor (el ejecutor falla la prueba si se
## registra alguno).

const ARMOR_FIXTURES: String = "res://tests/fixtures/items/armor"
const RANDOM_INSTANCES: int = 1000
const SEED: int = 20261030

var _db: ItemDatabase


func before_each() -> void:
	# Los cuatro objetos de data/items y las armaduras de prueba, que llevan durabilidad.
	var definitions: Array[ItemDefinition] = []
	for dir: String in [ItemDatabase.DATA_DIR.path_join("weapon"), ItemDatabase.DATA_DIR.path_join("consumable"),
			ARMOR_FIXTURES]:
		for file_name: String in DirAccess.get_files_at(dir):
			definitions.append(ResourceLoader.load(dir.path_join(file_name.trim_suffix(".remap"))) as ItemDefinition)
	_db = ItemDatabase.build_from_definitions(definitions)
	assert_eq(_db.errors, PackedStringArray(), "la base de la prueba vale")
	assert_eq(_db.all_ids().size(), 7, "cuatro objetos y tres armaduras")


func test_round_trip_random_binary_and_dictionary() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var stream := PackedByteArray([0xAB, 0xCD, 0xEF])
	var items: Array[ItemInstance] = []
	var with_durability: int = 0
	var with_affixes: int = 0
	for i: int in range(RANDOM_INSTANCES):
		var item: ItemInstance = _random_instance(rng, i)
		if not assert_true(item.is_valid(_db), "la instancia %d es válida" % i):
			return
		items.append(item)
		with_durability += 1 if item.durability != ItemInstance.NO_DURABILITY else 0
		with_affixes += 1 if not item.affixes.is_empty() else 0
		var bytes: PackedByteArray = item.encode(_db)
		assert_eq(bytes.size(), ItemInstance.HEADER_SIZE + 2 * item.affixes.size(), "%d: 22 + 2·n B" % i)
		assert_eq(ItemInstance.encoded_size_at(bytes, 0), bytes.size(), "%d: encoded_size_at" % i)
		var decoded: ItemInstance = ItemInstance.decode(bytes, 0, _db)
		if not assert_true(item.equals(decoded), "%d: ida y vuelta en binario" % i):
			return
		var entry: Dictionary = item.to_dictionary(i % 2, i % 30)
		var parsed: Variant = JSON.parse_string(JSON.stringify(entry))
		if not assert_eq(typeof(parsed), TYPE_DICTIONARY, "%d: el JSON se vuelve a leer" % i):
			return
		var from_json: ItemInstance = ItemInstance.from_dictionary(parsed, _db)
		if not assert_true(item.equals(from_json), "%d: ida y vuelta por el JSON (%s)" % [i, entry]):
			return
		assert_true(item.equals(ItemInstance.from_dictionary(entry, _db)), "%d: y sin pasar por el texto" % i)
		stream.append_array(bytes)
	assert_true(with_durability > 100 and with_durability < 900, "con y sin durabilidad (%d)" % with_durability)
	assert_true(with_affixes > 100, "con afijos (%d)" % with_affixes)
	# Todas seguidas en un búfer, recorridas con encoded_size_at desde un offset que no es 0.
	var offset: int = 3
	for i: int in range(items.size()):
		var size: int = ItemInstance.encoded_size_at(stream, offset)
		if not assert_true(size >= ItemInstance.HEADER_SIZE, "tamaño de la %d en el búfer" % i):
			return
		assert_true(items[i].equals(ItemInstance.decode(stream, offset, _db)), "la %d en el búfer" % i)
		offset += size
	assert_eq(offset, stream.size(), "el búfer se recorre entero")
	assert_eq(ItemInstance.encoded_size_at(stream, offset), -1, "y detrás no hay nada")


## Los bytes de una instancia conocida, campo a campo (§2.3, little endian).
func test_known_encoding() -> void:
	var item := ItemInstance.new()
	item.uid = 0x0001_0203_0405_0607
	item.def_id = &"test_iron_helm"
	item.count = 1
	item.durability = 750
	item.rarity = 3
	item.bound = true
	item.seed = 0xDEADBEEF
	item.affixes = PackedInt32Array([1, 0xFFFF])
	var bytes: PackedByteArray = item.encode(_db)
	var net_id: int = _db.net_id_of(&"test_iron_helm")
	var expected := PackedByteArray([
		1,
		0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00,
		net_id & 0xFF, net_id >> 8,
		1, 0,
		0xEE, 0x02,
		3,
		1,
		0xEF, 0xBE, 0xAD, 0xDE,
		2,
		1, 0, 0xFF, 0xFF,
	])
	assert_eq(bytes, expected, "formato 1, uid, net id, cantidad, durabilidad, rareza, flags, semilla y afijos")
	# Sin durabilidad: 0xFFFF en el cable.
	var potion: ItemInstance = ItemInstance.create(42, _db.get_definition(&"potion_health"), 15)
	var potion_bytes: PackedByteArray = potion.encode(_db)
	assert_eq(potion_bytes.size(), 22, "sin afijos, 22 B")
	assert_eq(potion_bytes.decode_u16(13), 0xFFFF, "sin durabilidad, 0xFFFF")
	assert_eq(potion_bytes[16], 1, "ligada al cogerla")
	assert_eq(potion_bytes.decode_u16(9), _db.net_id_of(&"potion_health"), "su net id")


## Null en cada caso de §2.3, sin registrar errores del motor.
func test_decode_rejects_each_case() -> void:
	var valid: PackedByteArray = _armor_bytes()
	assert_not_null(ItemInstance.decode(valid, 0, _db), "la base se lee")
	var cases: Dictionary[String, PackedByteArray] = {
		"formato 0": _patched(valid, 0, 1, 0),
		"formato 2": _patched(valid, 0, 1, 2),
		"uid 0": _patched(valid, 1, 8, 0),
		"uid 2^53": _patched(valid, 1, 8, 1 << 53),
		"uid 2^63 (negativo en int64)": _patched(valid, 1, 8, -(1 << 63)),
		"uid 2^64 − 1": _patched(valid, 1, 8, -1),
		"net id 0": _patched(valid, 9, 2, 0),
		"net id desconocido": _patched(valid, 9, 2, _db.all_ids().size() + 1),
		"net id 0xFFFF": _patched(valid, 9, 2, 0xFFFF),
		"cantidad 0": _patched(valid, 11, 2, 0),
		"cantidad 2 en una armadura": _patched(valid, 11, 2, 2),
		"durabilidad 1001": _patched(valid, 13, 2, 1001),
		"sin durabilidad en una armadura que la lleva": _patched(valid, 13, 2, 0xFFFF),
		"rareza 5": _patched(valid, 15, 1, 5),
		"flags 0x03 (un bit desconocido)": _patched(valid, 16, 1, 0x03),
		"flags 0x80": _patched(valid, 16, 1, 0x80),
		"7 afijos": _with_affix_count(valid, 7),
		"255 afijos": _with_affix_count(valid, 255),
	}
	var potion: PackedByteArray = ItemInstance.create(5, _db.get_definition(&"potion_health"), 3).encode(_db)
	cases["cantidad 16 en una pila de 15"] = _patched(potion, 11, 2, 16)
	cases["durabilidad 0 en un objeto que no la lleva"] = _patched(potion, 13, 2, 0)
	cases["durabilidad 1000 en un objeto que no la lleva"] = _patched(potion, 13, 2, 1000)
	for name: String in cases:
		assert_null(ItemInstance.decode(cases[name], 0, _db), "%s → null" % name)
	# Truncado: cada longitud por debajo de la entera, también sin los bytes de los afijos.
	for length: int in range(valid.size()):
		assert_null(ItemInstance.decode(valid.slice(0, length), 0, _db), "truncado a %d B → null" % length)
		assert_eq(ItemInstance.encoded_size_at(valid.slice(0, length), 0), -1, "encoded_size_at de %d B" % length)
	assert_null(ItemInstance.decode(valid, -1, _db), "offset negativo")
	assert_null(ItemInstance.decode(valid, 1, _db), "offset desplazado")
	assert_null(ItemInstance.decode(valid, valid.size(), _db), "offset al final")
	assert_null(ItemInstance.decode(valid, 1 << 40, _db), "offset enorme")
	assert_null(ItemInstance.decode(PackedByteArray(), 0, _db), "vacío")
	assert_eq(ItemInstance.encoded_size_at(_with_affix_count(valid, 7), 0), -1, "7 afijos no caben")
	assert_eq(ItemInstance.encoded_size_at(_patched(valid, 0, 1, 2), 0), -1, "otro formato no se mide")
	# Una instancia de 2^53 − 1, el mayor uid, sí vale.
	assert_not_null(ItemInstance.decode(_patched(valid, 1, 8, ItemInstance.MAX_UID), 0, _db), "uid 2^53 − 1 vale")


## Lo que no vale no se codifica: un array vacío, sin registrar nada.
func test_encode_rejects_invalid_instances() -> void:
	var cases: Dictionary[String, Dictionary] = {
		"definición desconocida": {"def_id": &"no_existe"},
		"uid 0": {"uid": 0},
		"uid 2^53": {"uid": 1 << 53},
		"cantidad 0": {"count": 0},
		"cantidad 2 en una armadura": {"count": 2},
		"durabilidad −1 en una armadura": {"durability": -1},
		"durabilidad 1001": {"durability": 1001},
		"rareza 5": {"rarity": 5},
		"semilla 2^32": {"seed": 1 << 32},
		"semilla negativa": {"seed": -1},
		"7 afijos": {"affixes": PackedInt32Array([1, 2, 3, 4, 5, 6, 7])},
		"afijo 65536": {"affixes": PackedInt32Array([65536])},
		"afijo negativo": {"affixes": PackedInt32Array([-1])},
	}
	for name: String in cases:
		var item: ItemInstance = _armor()
		for field: String in cases[name]:
			item.set(field, cases[name][field])
		assert_false(item.is_valid(_db), "%s no es válida" % name)
		assert_eq(item.encode(_db), PackedByteArray(), "%s → vacío" % name)
	var potion := ItemInstance.create(9, _db.get_definition(&"potion_stamina"), 2)
	potion.durability = 500
	assert_eq(potion.encode(_db), PackedByteArray(), "durabilidad en un objeto que no la lleva → vacío")


## La entrada de §3.4 tal cual.
func test_to_dictionary_is_section_3_4() -> void:
	var sword: ItemInstance = ItemInstance.create(1025, _db.get_definition(&"sword_shield_vado"), 1)
	assert_eq(sword.to_dictionary(1, 0), {"uid": "1025", "def_id": "sword_shield_vado", "container": 1, "slot": 0,
			"count": 1, "durability": null, "rarity": 0, "bound": true, "seed": "0", "affixes": []},
			"la espada del ejemplo de §3.4")
	var potion: ItemInstance = ItemInstance.create(1027, _db.get_definition(&"potion_health"), 3)
	assert_eq(JSON.stringify(potion.to_dictionary(0, 1), "", true),
			"{\"affixes\":[],\"bound\":true,\"container\":0,\"count\":3,\"def_id\":\"potion_health\",\"durability\":null,"
			+ "\"rarity\":0,\"seed\":\"0\",\"slot\":1,\"uid\":\"1027\"}", "la poción, en el texto JSON")
	var keys: Array = sword.to_dictionary(0, 0).keys()
	keys.sort()
	assert_eq(keys, Array(ItemInstance.DICTIONARY_KEYS), "las claves de DICTIONARY_KEYS")
	var helm: ItemInstance = _armor()
	var entry: Dictionary = helm.to_dictionary(0, 7)
	assert_eq(entry["durability"], 750, "durabilidad como número")
	assert_eq(entry["uid"], "9007199254740991", "el mayor uid, exacto en la cadena")
	assert_eq(entry["seed"], "4294967295", "la semilla u32, como cadena")
	assert_eq(entry["affixes"], [1, 65535], "afijos como lista")


## null ante una clave que falta o desconocida, un tipo que no casa o un valor fuera de rango; los enteros
## reescritos como 820.0 valen.
func test_from_dictionary_rejects_and_accepts() -> void:
	var base: Dictionary = _armor().to_dictionary(0, 3)
	assert_true(_armor().equals(ItemInstance.from_dictionary(base, _db)), "la base se lee")
	var accepted: Dictionary[String, Dictionary] = {
		"enteros como float": {"count": 1.0, "durability": 750.0, "rarity": 3.0, "container": 0.0, "slot": 3.0,
				"affixes": [1.0, 65535.0]},
		"def_id como StringName": {"def_id": &"test_iron_helm"},
		"semilla 0": {"seed": "0"},
		"durabilidad 0": {"durability": 0},
		"contenedor y ranura altos (los mira quien lee el registro)": {"container": 3, "slot": 119},
	}
	for name: String in accepted:
		assert_not_null(ItemInstance.from_dictionary(_with(base, accepted[name]), _db), "%s vale" % name)
	var rejected: Dictionary[String, Dictionary] = {
		"uid como número": {"uid": 9007199254740991},
		"uid como float": {"uid": 1025.0},
		"uid 0": {"uid": "0"},
		"uid 2^53": {"uid": "9007199254740992"},
		"uid de 20 cifras": {"uid": "99999999999999999999"},
		"uid con signo": {"uid": "+5"},
		"uid negativo": {"uid": "-5"},
		"uid con ceros a la izquierda": {"uid": "007"},
		"uid con espacios": {"uid": " 5"},
		"uid con decimales": {"uid": "5.0"},
		"uid vacío": {"uid": ""},
		"uid hexadecimal": {"uid": "0x10"},
		"semilla 2^32": {"seed": "4294967296"},
		"semilla negativa": {"seed": "-1"},
		"semilla como número": {"seed": 0},
		"def_id desconocido": {"def_id": "no_existe"},
		"def_id como número": {"def_id": 3},
		"cantidad 0": {"count": 0},
		"cantidad 2 en una armadura": {"count": 2},
		"cantidad con decimales": {"count": 1.5},
		"cantidad como cadena": {"count": "1"},
		"durabilidad null en una armadura": {"durability": null},
		"durabilidad 1001": {"durability": 1001},
		"durabilidad negativa": {"durability": -1},
		"rareza 5": {"rarity": 5},
		"rareza null": {"rarity": null},
		"ligado como cadena": {"bound": "true"},
		"ligado como número": {"bound": 1},
		"7 afijos": {"affixes": [1, 2, 3, 4, 5, 6, 7]},
		"afijo 65536": {"affixes": [65536]},
		"afijo con decimales": {"affixes": [1.5]},
		"afijo como cadena": {"affixes": ["1"]},
		"afijos como diccionario": {"affixes": {}},
		"contenedor negativo": {"container": -1},
		"contenedor como cadena": {"container": "0"},
		"ranura con decimales": {"slot": 2.5},
		"ranura infinita": {"slot": INF},
		"ranura NaN": {"slot": NAN},
	}
	for name: String in rejected:
		assert_null(ItemInstance.from_dictionary(_with(base, rejected[name]), _db), "%s → null" % name)
	for key: String in ItemInstance.DICTIONARY_KEYS:
		var missing: Dictionary = base.duplicate()
		missing.erase(key)
		assert_null(ItemInstance.from_dictionary(missing, _db), "sin %s → null" % key)
	var extra: Dictionary = base.duplicate()
	extra["parent_uid"] = "3"
	assert_null(ItemInstance.from_dictionary(extra, _db), "una clave desconocida → null")
	var potion: Dictionary = ItemInstance.create(77, _db.get_definition(&"potion_health"), 15).to_dictionary(0, 0)
	assert_not_null(ItemInstance.from_dictionary(potion, _db), "la poción se lee")
	assert_null(ItemInstance.from_dictionary(_with(potion, {"durability": 0}), _db),
			"durabilidad en un objeto que no la lleva → null")
	assert_null(ItemInstance.from_dictionary(_with(potion, {"count": 16}), _db), "más que la pila → null")


func test_create_duplicate_and_equals() -> void:
	var sword: ItemInstance = ItemInstance.create(7, _db.get_definition(&"sword_shield_vado"), 1)
	assert_eq([sword.uid, sword.def_id, sword.count, sword.durability, sword.rarity, sword.bound, sword.seed],
			[7, &"sword_shield_vado", 1, ItemInstance.NO_DURABILITY, 0, true, 0], "create: ligada al cogerla")
	assert_eq(sword.affixes, PackedInt32Array(), "sin afijos")
	var helm: ItemInstance = ItemInstance.create(8, _db.get_definition(&"test_iron_helm"), 1)
	assert_eq(helm.durability, ItemInstance.MAX_DURABILITY, "con durabilidad, llena")
	assert_false(helm.bound, "ligada al equiparla: aún no")
	var item: ItemInstance = _armor()
	var copy: ItemInstance = item.duplicate_instance()
	assert_true(item.equals(copy) and copy.equals(item), "la copia es igual")
	copy.affixes[0] = 2
	assert_eq(item.affixes[0], 1, "y sus afijos son independientes")
	assert_false(item.equals(null), "no es igual a null")
	for field: String in ["uid", "def_id", "count", "durability", "rarity", "bound", "seed", "affixes"]:
		var changed: ItemInstance = item.duplicate_instance()
		match field:
			"def_id":
				changed.def_id = &"test_leather_boots"
			"bound":
				changed.bound = not changed.bound
			"affixes":
				changed.affixes.append(3)
			_:
				changed.set(field, int(changed.get(field)) - 1)
		assert_false(item.equals(changed), "equals mira %s" % field)


## Sin base de datos se usa la compartida.
func test_shared_database_by_default() -> void:
	var potion: ItemInstance = ItemInstance.create(3, ItemDatabase.shared().get_definition(&"potion_stamina"), 2)
	var bytes: PackedByteArray = potion.encode()
	assert_eq(bytes, potion.encode(ItemDatabase.shared()), "encode() usa ItemDatabase.shared()")
	assert_true(potion.equals(ItemInstance.decode(bytes, 0)), "decode también")
	assert_true(potion.equals(ItemInstance.from_dictionary(potion.to_dictionary(0, 0), null)), "y from_dictionary")


# --- Utilidades --------------------------------------------------------------------------------

# Una instancia aleatoria y válida: uid en todo su rango (con los extremos), cualquier definición, cantidad
# hasta la pila, durabilidad si la lleva, rareza, ligado, semilla u32 y de 0 a 6 afijos.
func _random_instance(rng: RandomNumberGenerator, index: int) -> ItemInstance:
	var ids: Array[StringName] = _db.all_ids()
	var definition: ItemDefinition = _db.get_definition(ids[rng.randi_range(0, ids.size() - 1)])
	var item := ItemInstance.new()
	match index:
		0:
			item.uid = 1
		1:
			item.uid = ItemInstance.MAX_UID
		_:
			item.uid = (rng.randi() << 21 | (rng.randi() & 0x1FFFFF)) % ItemInstance.MAX_UID + 1
	item.def_id = definition.id
	item.count = rng.randi_range(1, definition.max_stack)
	item.durability = rng.randi_range(0, ItemInstance.MAX_DURABILITY) if definition.has_durability \
			else ItemInstance.NO_DURABILITY
	item.rarity = rng.randi_range(0, ItemInstance.MAX_RARITY)
	item.bound = rng.randi() % 2 == 0
	item.seed = 0xFFFFFFFF if index == 2 else rng.randi()
	for _i: int in range(rng.randi_range(0, ItemInstance.MAX_AFFIXES) if rng.randi() % 3 == 0 else 0):
		item.affixes.append(rng.randi_range(0, ItemInstance.MAX_AFFIX_ID))
	return item


# Una armadura con todos los campos lejos de 0: uid máximo, durabilidad, rareza, semilla y dos afijos.
func _armor() -> ItemInstance:
	var item := ItemInstance.new()
	item.uid = ItemInstance.MAX_UID
	item.def_id = &"test_iron_helm"
	item.count = 1
	item.durability = 750
	item.rarity = 3
	item.bound = true
	item.seed = 0xFFFFFFFF
	item.affixes = PackedInt32Array([1, 0xFFFF])
	return item


func _armor_bytes() -> PackedByteArray:
	return _armor().encode(_db)


# Una copia de [param bytes] con [param value] escrito en [param size] bytes desde [param offset].
func _patched(bytes: PackedByteArray, offset: int, size: int, value: int) -> PackedByteArray:
	var copy: PackedByteArray = bytes.duplicate()
	match size:
		1:
			copy[offset] = value & 0xFF
		2:
			copy.encode_u16(offset, value & 0xFFFF)
		8:
			copy.encode_s64(offset, value)
	return copy


# Una copia con [param count] afijos (los bytes que hagan falta, a 0).
func _with_affix_count(bytes: PackedByteArray, count: int) -> PackedByteArray:
	var copy: PackedByteArray = bytes.slice(0, ItemInstance.HEADER_SIZE)
	copy[21] = count
	copy.resize(ItemInstance.HEADER_SIZE + 2 * count)
	return copy


func _with(entry: Dictionary, changes: Dictionary) -> Dictionary:
	var copy: Dictionary = entry.duplicate(true)
	for key: String in changes:
		copy[key] = changes[key]
	return copy
