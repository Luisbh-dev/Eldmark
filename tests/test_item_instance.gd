extends TestCase
## Tests for [ItemInstance] (docs/progression.md §2.1, §2.3 and §3.4, PRG-02): round trip of 1000 seeded random
## instances, in binary and in dictionary form (going through the JSON text, like the platform's
## record), and null in each §2.3 case with no engine errors (the runner fails the test if any
## is logged).

const ARMOR_FIXTURES: String = "res://tests/fixtures/items/armor"
const RANDOM_INSTANCES: int = 1000
const SEED: int = 20261030

var _db: ItemDatabase


func before_each() -> void:
	# The four objects from data/items and the test armours, which carry durability.
	var definitions: Array[ItemDefinition] = []
	for dir: String in [ItemDatabase.DATA_DIR.path_join("weapon"), ItemDatabase.DATA_DIR.path_join("consumable"),
			ARMOR_FIXTURES]:
		for file_name: String in DirAccess.get_files_at(dir):
			definitions.append(ResourceLoader.load(dir.path_join(file_name.trim_suffix(".remap"))) as ItemDefinition)
	_db = ItemDatabase.build_from_definitions(definitions)
	assert_eq(_db.errors, PackedStringArray(), "the test's base is valid")
	assert_eq(_db.all_ids().size(), 7, "four objects and three armours")


func test_round_trip_random_binary_and_dictionary() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var stream := PackedByteArray([0xAB, 0xCD, 0xEF])
	var items: Array[ItemInstance] = []
	var with_durability: int = 0
	var with_affixes: int = 0
	for i: int in range(RANDOM_INSTANCES):
		var item: ItemInstance = _random_instance(rng, i)
		if not assert_true(item.is_valid(_db), "instance %d is valid" % i):
			return
		items.append(item)
		with_durability += 1 if item.durability != ItemInstance.NO_DURABILITY else 0
		with_affixes += 1 if not item.affixes.is_empty() else 0
		var bytes: PackedByteArray = item.encode(_db)
		assert_eq(bytes.size(), ItemInstance.HEADER_SIZE + 2 * item.affixes.size(), "%d: 22 + 2·n B" % i)
		assert_eq(ItemInstance.encoded_size_at(bytes, 0), bytes.size(), "%d: encoded_size_at" % i)
		var decoded: ItemInstance = ItemInstance.decode(bytes, 0, _db)
		if not assert_true(item.equals(decoded), "%d: binary round trip" % i):
			return
		var entry: Dictionary = item.to_dictionary(i % 2, i % 30)
		var parsed: Variant = JSON.parse_string(JSON.stringify(entry))
		if not assert_eq(typeof(parsed), TYPE_DICTIONARY, "%d: the JSON is read back" % i):
			return
		var from_json: ItemInstance = ItemInstance.from_dictionary(parsed, _db)
		if not assert_true(item.equals(from_json), "%d: round trip through the JSON (%s)" % [i, entry]):
			return
		assert_true(item.equals(ItemInstance.from_dictionary(entry, _db)), "%d: and without going through the text" % i)
		stream.append_array(bytes)
	assert_true(with_durability > 100 and with_durability < 900, "with and without durability (%d)" % with_durability)
	assert_true(with_affixes > 100, "with affixes (%d)" % with_affixes)
	# All in a row in one buffer, walked with encoded_size_at from an offset that is not 0.
	var offset: int = 3
	for i: int in range(items.size()):
		var size: int = ItemInstance.encoded_size_at(stream, offset)
		if not assert_true(size >= ItemInstance.HEADER_SIZE, "size of number %d in the buffer" % i):
			return
		assert_true(items[i].equals(ItemInstance.decode(stream, offset, _db)), "number %d in the buffer" % i)
		offset += size
	assert_eq(offset, stream.size(), "the buffer is walked entirely")
	assert_eq(ItemInstance.encoded_size_at(stream, offset), -1, "and there is nothing after it")


## The bytes of a known instance, field by field (§2.3, little endian).
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
	assert_eq(bytes, expected, "format 1, uid, net id, quantity, durability, rarity, flags, seed and affixes")
	# Without durability: 0xFFFF on the wire.
	var potion: ItemInstance = ItemInstance.create(42, _db.get_definition(&"potion_health"), 15)
	var potion_bytes: PackedByteArray = potion.encode(_db)
	assert_eq(potion_bytes.size(), 22, "without affixes, 22 B")
	assert_eq(potion_bytes.decode_u16(13), 0xFFFF, "without durability, 0xFFFF")
	assert_eq(potion_bytes[16], 1, "bound on pickup")
	assert_eq(potion_bytes.decode_u16(9), _db.net_id_of(&"potion_health"), "its net id")


## Null in each §2.3 case, without logging engine errors.
func test_decode_rejects_each_case() -> void:
	var valid: PackedByteArray = _armor_bytes()
	assert_not_null(ItemInstance.decode(valid, 0, _db), "the base is read")
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
	# Truncated: every length below the full one, also without the affixes' bytes.
	for length: int in range(valid.size()):
		assert_null(ItemInstance.decode(valid.slice(0, length), 0, _db), "truncated to %d B → null" % length)
		assert_eq(ItemInstance.encoded_size_at(valid.slice(0, length), 0), -1, "encoded_size_at of %d B" % length)
	assert_null(ItemInstance.decode(valid, -1, _db), "negative offset")
	assert_null(ItemInstance.decode(valid, 1, _db), "shifted offset")
	assert_null(ItemInstance.decode(valid, valid.size(), _db), "offset at the end")
	assert_null(ItemInstance.decode(valid, 1 << 40, _db), "huge offset")
	assert_null(ItemInstance.decode(PackedByteArray(), 0, _db), "empty")
	assert_eq(ItemInstance.encoded_size_at(_with_affix_count(valid, 7), 0), -1, "7 affixes do not fit")
	assert_eq(ItemInstance.encoded_size_at(_patched(valid, 0, 1, 2), 0), -1, "another format is not measured")
	# An instance of 2^53 − 1, the largest uid, is valid.
	assert_not_null(ItemInstance.decode(_patched(valid, 1, 8, ItemInstance.MAX_UID), 0, _db), "uid 2^53 − 1 is valid")


## What is not valid is not encoded: an empty array, logging nothing.
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
		assert_false(item.is_valid(_db), "%s is not valid" % name)
		assert_eq(item.encode(_db), PackedByteArray(), "%s → empty" % name)
	var potion := ItemInstance.create(9, _db.get_definition(&"potion_stamina"), 2)
	potion.durability = 500
	assert_eq(potion.encode(_db), PackedByteArray(), "durability on an object that does not carry it → empty")


## The §3.4 entry as is.
func test_to_dictionary_is_section_3_4() -> void:
	var sword: ItemInstance = ItemInstance.create(1025, _db.get_definition(&"sword_shield_vado"), 1)
	assert_eq(sword.to_dictionary(1, 0), {"uid": "1025", "def_id": "sword_shield_vado", "container": 1, "slot": 0,
			"count": 1, "durability": null, "rarity": 0, "bound": true, "seed": "0", "affixes": []},
			"the sword from the §3.4 example")
	var potion: ItemInstance = ItemInstance.create(1027, _db.get_definition(&"potion_health"), 3)
	assert_eq(JSON.stringify(potion.to_dictionary(0, 1), "", true),
			"{\"affixes\":[],\"bound\":true,\"container\":0,\"count\":3,\"def_id\":\"potion_health\",\"durability\":null,"
			+ "\"rarity\":0,\"seed\":\"0\",\"slot\":1,\"uid\":\"1027\"}", "the potion, in the JSON text")
	var keys: Array = sword.to_dictionary(0, 0).keys()
	keys.sort()
	assert_eq(keys, Array(ItemInstance.DICTIONARY_KEYS), "the DICTIONARY_KEYS keys")
	var helm: ItemInstance = _armor()
	var entry: Dictionary = helm.to_dictionary(0, 7)
	assert_eq(entry["durability"], 750, "durability as a number")
	assert_eq(entry["uid"], "9007199254740991", "the largest uid, exact in the string")
	assert_eq(entry["seed"], "4294967295", "the u32 seed, as a string")
	assert_eq(entry["affixes"], [1, 65535], "affixes as a list")


## null on a missing or unknown key, a mismatched type or an out-of-range value; integers
## rewritten as 820.0 are valid.
func test_from_dictionary_rejects_and_accepts() -> void:
	var base: Dictionary = _armor().to_dictionary(0, 3)
	assert_true(_armor().equals(ItemInstance.from_dictionary(base, _db)), "the base is read")
	var accepted: Dictionary[String, Dictionary] = {
		"enteros como float": {"count": 1.0, "durability": 750.0, "rarity": 3.0, "container": 0.0, "slot": 3.0,
				"affixes": [1.0, 65535.0]},
		"def_id como StringName": {"def_id": &"test_iron_helm"},
		"semilla 0": {"seed": "0"},
		"durabilidad 0": {"durability": 0},
		"contenedor y ranura altos (los mira quien lee el registro)": {"container": 3, "slot": 119},
	}
	for name: String in accepted:
		assert_not_null(ItemInstance.from_dictionary(_with(base, accepted[name]), _db), "%s is valid" % name)
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
		assert_null(ItemInstance.from_dictionary(missing, _db), "without %s → null" % key)
	var extra: Dictionary = base.duplicate()
	extra["parent_uid"] = "3"
	assert_null(ItemInstance.from_dictionary(extra, _db), "an unknown key → null")
	var potion: Dictionary = ItemInstance.create(77, _db.get_definition(&"potion_health"), 15).to_dictionary(0, 0)
	assert_not_null(ItemInstance.from_dictionary(potion, _db), "the potion is read")
	assert_null(ItemInstance.from_dictionary(_with(potion, {"durability": 0}), _db),
			"durability on an object that does not carry it → null")
	assert_null(ItemInstance.from_dictionary(_with(potion, {"count": 16}), _db), "more than the stack → null")


func test_create_duplicate_and_equals() -> void:
	var sword: ItemInstance = ItemInstance.create(7, _db.get_definition(&"sword_shield_vado"), 1)
	assert_eq([sword.uid, sword.def_id, sword.count, sword.durability, sword.rarity, sword.bound, sword.seed],
			[7, &"sword_shield_vado", 1, ItemInstance.NO_DURABILITY, 0, true, 0], "create: bound on pickup")
	assert_eq(sword.affixes, PackedInt32Array(), "without affixes")
	var helm: ItemInstance = ItemInstance.create(8, _db.get_definition(&"test_iron_helm"), 1)
	assert_eq(helm.durability, ItemInstance.MAX_DURABILITY, "with durability, full")
	assert_false(helm.bound, "bound on equip: not yet")
	var item: ItemInstance = _armor()
	var copy: ItemInstance = item.duplicate_instance()
	assert_true(item.equals(copy) and copy.equals(item), "the copy is equal")
	copy.affixes[0] = 2
	assert_eq(item.affixes[0], 1, "and its affixes are independent")
	assert_false(item.equals(null), "not equal to null")
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
		assert_false(item.equals(changed), "equals looks at %s" % field)


## Without a database the shared one is used.
func test_shared_database_by_default() -> void:
	var potion: ItemInstance = ItemInstance.create(3, ItemDatabase.shared().get_definition(&"potion_stamina"), 2)
	var bytes: PackedByteArray = potion.encode()
	assert_eq(bytes, potion.encode(ItemDatabase.shared()), "encode() uses ItemDatabase.shared()")
	assert_true(potion.equals(ItemInstance.decode(bytes, 0)), "decode too")
	assert_true(potion.equals(ItemInstance.from_dictionary(potion.to_dictionary(0, 0), null)), "and from_dictionary")


# --- Utilities ---------------------------------------------------------------------------------

# A random, valid instance: uid over its whole range (with the extremes), any definition, quantity
# up to the stack, durability if it has it, rarity, binding, u32 seed and 0 to 6 affixes.
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


# An armour with all fields far from 0: maximum uid, durability, rarity, seed and two affixes.
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


# A copy of [param bytes] with [param value] written in [param size] bytes from [param offset].
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


# A copy with [param count] affixes (as many bytes as needed, at 0).
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
