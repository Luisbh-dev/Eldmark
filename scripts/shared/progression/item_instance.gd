class_name ItemInstance
extends RefCounted
## A concrete item that someone owns (docs/progresion.md §2.1, PRG-02): a row of
## [code]item_instances[/code], with a [member uid] unique across the whole world and forever.
## What the item is lives in its [ItemDefinition] ([member def_id], in [ItemDatabase]).
## [br][br]
## [b]Binary[/b] ([method encode], version 1, §2.3), for the network (only toward the owner) and
## tests:
## [codeblock]
## offset  type      field
## 0       u8        format       1
## 1       u64       uid          1 … 2^53 − 1
## 9       u16       def          ItemDatabase net id (≥ 1)
## 11      u16       count        1 … max_stack
## 13      u16       durability   0–1000; 0xFFFF = no durability
## 15      u8        rarity       0–4
## 16      u8        flags        bit0 bound; the rest 0
## 17      u32       seed
## 21      u8        affix_count  0–6
## 22      n × u16   affixes
## [/codeblock]
## 22 + 2·n B, little endian like the rest of the protocol. [method decode] returns null for
## anything that does not fit and never logs engine errors (red.md §5.7).
## [br][br]
## [b]JSON[/b] ([method to_dictionary], an [code]items[/code] entry in §3.4): ids
## ([code]uid[/code], [code]seed[/code]) as a decimal string and durability null if it has none.
## Shared: no clock, no randomness.

## Binary format version.
const FORMAT: int = 1
## At most this many affixes (PRG-20).
const MAX_AFFIXES: int = 6
## [member durability] of an item without durability (NULL in the database and in JSON).
const NO_DURABILITY: int = -1
## Largest [member uid]: a JSON number carries it exactly (§3.4).
const MAX_UID: int = (1 << 53) - 1
## Maximum durability (per thousand).
const MAX_DURABILITY: int = 1000
## Maximum rarity: 0 common, 1 uncommon, 2 rare, 3 epic, 4 legendary.
const MAX_RARITY: int = 4
## Largest [member seed] (u32).
const MAX_SEED: int = 0xFFFFFFFF
## Largest affix id (u16).
const MAX_AFFIX_ID: int = 0xFFFF
## Size without affixes.
const HEADER_SIZE: int = 22
## Durability on the wire for an item without durability.
const WIRE_NO_DURABILITY: int = 0xFFFF
## Bound bit in [code]flags[/code].
const FLAG_BOUND: int = 0x01
## Keys of [method to_dictionary], in alphabetical order.
const DICTIONARY_KEYS: Array[String] = ["affixes", "bound", "container", "count", "def_id", "durability",
		"rarity", "seed", "slot", "uid"]

## 1 … [constant MAX_UID]; given by the zone's [code]IdAllocator[/code] (§4.5).
var uid: int = 0
var def_id: StringName = &""
## 1 … [member ItemDefinition.max_stack].
var count: int = 1
## 0–1000 if the definition has durability; otherwise [constant NO_DURABILITY].
var durability: int = NO_DURABILITY
## 0–4. Phase 5: always 0.
var rarity: int = 0
## Bound to the character.
var bound: bool = false
## u32 for the affixes (PRG-20); 0 = no affixes.
var seed: int = 0
## Up to [constant MAX_AFFIXES] u16 affix ids (PRG-20). Phase 5: empty.
var affixes: PackedInt32Array = PackedInt32Array()


## A new instance of [param definition] with [param count] units: full durability if it has any and
## bound if the rule is [code]ON_PICKUP[/code]; no rarity, seed or affixes.
static func create(new_uid: int, definition: ItemDefinition, new_count: int) -> ItemInstance:
	var item := ItemInstance.new()
	item.uid = new_uid
	item.def_id = definition.id
	item.count = new_count
	item.durability = MAX_DURABILITY if definition.has_durability else NO_DURABILITY
	item.bound = definition.bind_rule == ItemDefinition.BindRule.ON_PICKUP
	return item


## true if the instance meets the §2.1 rules with the definitions of [param db] (null =
## [method ItemDatabase.shared]): the same that [method decode] requires, so whatever is valid is
## encoded and read back identically.
func is_valid(db: ItemDatabase = null) -> bool:
	if db == null:
		db = ItemDatabase.shared()
	var definition: ItemDefinition = db.get_definition(def_id)
	if definition == null or uid < 1 or uid > MAX_UID:
		return false
	if count < 1 or count > definition.max_stack:
		return false
	if definition.has_durability:
		if durability < 0 or durability > MAX_DURABILITY:
			return false
	elif durability != NO_DURABILITY:
		return false
	if rarity < 0 or rarity > MAX_RARITY or seed < 0 or seed > MAX_SEED or affixes.size() > MAX_AFFIXES:
		return false
	for affix: int in affixes:
		if affix < 0 or affix > MAX_AFFIX_ID:
			return false
	return true


## Encoded size: 22 + 2 · affixes.
func encoded_size() -> int:
	return HEADER_SIZE + 2 * affixes.size()


## The §2.3 binary with the net id from [param db] (null = [method ItemDatabase.shared]). An
## instance that fails [method is_valid] gives an empty array (logging nothing): whoever builds the
## message treats it as its own failure.
func encode(db: ItemDatabase = null) -> PackedByteArray:
	if db == null:
		db = ItemDatabase.shared()
	if not is_valid(db):
		return PackedByteArray()
	var bytes := PackedByteArray()
	bytes.resize(encoded_size())
	bytes[0] = FORMAT
	bytes.encode_u64(1, uid)
	bytes.encode_u16(9, db.net_id_of(def_id))
	bytes.encode_u16(11, count)
	bytes.encode_u16(13, WIRE_NO_DURABILITY if durability == NO_DURABILITY else durability)
	bytes[15] = rarity
	bytes[16] = FLAG_BOUND if bound else 0
	bytes.encode_u32(17, seed)
	bytes[21] = affixes.size()
	for i: int in range(affixes.size()):
		bytes.encode_u16(HEADER_SIZE + 2 * i, affixes[i])
	return bytes


## Reads an instance from [param bytes] starting at [param offset] with the definitions of
## [param db] (null = [method ItemDatabase.shared]). null if any byte is missing, the format is not
## 1, the uid is 0 or reaches 2^53, the net id does not exist, the count is 0 or exceeds the stack,
## the durability does not match [member ItemDefinition.has_durability], the rarity exceeds 4,
## there are unknown flag bits or more than 6 affixes. It never logs engine errors.
static func decode(bytes: PackedByteArray, offset: int, db: ItemDatabase = null) -> ItemInstance:
	if encoded_size_at(bytes, offset) < 0:
		return null
	if db == null:
		db = ItemDatabase.shared()
	# decode_u64 gives an int64: whatever exceeds 2^63 comes out negative and is also rejected.
	var new_uid: int = bytes.decode_u64(offset + 1)
	if new_uid < 1 or new_uid > MAX_UID:
		return null
	var definition: ItemDefinition = db.definition_by_net_id(bytes.decode_u16(offset + 9))
	if definition == null:
		return null
	var new_count: int = bytes.decode_u16(offset + 11)
	if new_count < 1 or new_count > definition.max_stack:
		return null
	var wire_durability: int = bytes.decode_u16(offset + 13)
	var new_durability: int = NO_DURABILITY
	if definition.has_durability:
		if wire_durability > MAX_DURABILITY:
			return null
		new_durability = wire_durability
	elif wire_durability != WIRE_NO_DURABILITY:
		return null
	var new_rarity: int = bytes[offset + 15]
	var flags: int = bytes[offset + 16]
	if new_rarity > MAX_RARITY or (flags & ~FLAG_BOUND) != 0:
		return null
	var item := ItemInstance.new()
	item.uid = new_uid
	item.def_id = definition.id
	item.count = new_count
	item.durability = new_durability
	item.rarity = new_rarity
	item.bound = (flags & FLAG_BOUND) != 0
	item.seed = bytes.decode_u32(offset + 17)
	var affix_count: int = bytes[offset + 21]
	item.affixes.resize(affix_count)
	for i: int in range(affix_count):
		item.affixes[i] = bytes.decode_u16(offset + HEADER_SIZE + 2 * i)
	return item


## Size of the encoded instance starting at [param offset], or −1 if it does not fit in
## [param bytes]: the offset is outside, header or affix bytes are missing, the format is not 1 or
## there are more than [constant MAX_AFFIXES] affixes. Used to walk a list of instances without
## decoding them.
static func encoded_size_at(bytes: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + HEADER_SIZE > bytes.size() or bytes[offset] != FORMAT:
		return -1
	var affix_count: int = bytes[offset + 21]
	if affix_count > MAX_AFFIXES:
		return -1
	var size: int = HEADER_SIZE + 2 * affix_count
	if offset + size > bytes.size():
		return -1
	return size


## An [code]items[/code] entry of the log (§3.4), in [param container] and [param slot]: ids as
## strings, durability null if none and affixes as a list of integers.
func to_dictionary(container: int, slot: int) -> Dictionary:
	var affix_list: Array = []
	for affix: int in affixes:
		affix_list.append(affix)
	return {
		"uid": ProgressJson.id_text(uid),
		"def_id": String(def_id),
		"container": container,
		"slot": slot,
		"count": count,
		"durability": null if durability == NO_DURABILITY else durability,
		"rarity": rarity,
		"bound": bound,
		"seed": ProgressJson.id_text(seed),
		"affixes": affix_list,
	}


## Reads an entry from [method to_dictionary] with the definitions of [param db] (null =
## [method ItemDatabase.shared]); null if it does not fit: a missing or unknown key, a type that
## does not match or a value out of range. Ids ([code]uid[/code] from 1 to 2^53 − 1,
## [code]seed[/code] u32) are decimal strings; an id as a number is not valid. Integers accept the
## form [code]820.0[/code]. [code]container[/code] and [code]slot[/code] must be non-negative
## integers; their range (which depends on the container and on [code]bag_slots[/code]) is checked
## by whoever reads the log.
static func from_dictionary(data: Dictionary, db: ItemDatabase) -> ItemInstance:
	if db == null:
		db = ItemDatabase.shared()
	if data.size() != DICTIONARY_KEYS.size():
		return null
	for key: String in DICTIONARY_KEYS:
		if not data.has(key):
			return null
	var def_value: Variant = data["def_id"]
	if typeof(def_value) != TYPE_STRING and typeof(def_value) != TYPE_STRING_NAME:
		return null
	var definition: ItemDefinition = db.get_definition(StringName(def_value))
	if definition == null:
		return null
	if not ProgressJson.is_id(data["uid"], 1, MAX_UID) or not ProgressJson.is_id(data["seed"], 0, MAX_SEED):
		return null
	if not ProgressJson.is_int(data["container"], 0, 0xFFFF) or not ProgressJson.is_int(data["slot"], 0, 0xFFFF):
		return null
	if not ProgressJson.is_int(data["count"], 1, definition.max_stack):
		return null
	if not ProgressJson.is_int(data["rarity"], 0, MAX_RARITY) or not ProgressJson.is_bool(data["bound"]):
		return null
	var new_durability: int = NO_DURABILITY
	if definition.has_durability:
		if not ProgressJson.is_int(data["durability"], 0, MAX_DURABILITY):
			return null
		new_durability = int(data["durability"])
	elif typeof(data["durability"]) != TYPE_NIL:
		return null
	var affix_value: Variant = data["affixes"]
	if typeof(affix_value) != TYPE_ARRAY:
		return null
	var affix_list: Array = affix_value
	if affix_list.size() > MAX_AFFIXES:
		return null
	var item := ItemInstance.new()
	for affix: Variant in affix_list:
		if not ProgressJson.is_int(affix, 0, MAX_AFFIX_ID):
			return null
		item.affixes.append(int(affix))
	item.uid = ProgressJson.id_value(data["uid"])
	item.def_id = definition.id
	item.count = int(data["count"])
	item.durability = new_durability
	item.rarity = int(data["rarity"])
	item.bound = data["bound"]
	item.seed = ProgressJson.id_value(data["seed"])
	return item


## An independent copy (affixes too).
func duplicate_instance() -> ItemInstance:
	var copy := ItemInstance.new()
	copy.uid = uid
	copy.def_id = def_id
	copy.count = count
	copy.durability = durability
	copy.rarity = rarity
	copy.bound = bound
	copy.seed = seed
	copy.affixes = affixes.duplicate()
	return copy


## true if [param other] has the same values in all fields.
func equals(other: ItemInstance) -> bool:
	return other != null and uid == other.uid and def_id == other.def_id and count == other.count \
			and durability == other.durability and rarity == other.rarity and bound == other.bound \
			and seed == other.seed and affixes == other.affixes
