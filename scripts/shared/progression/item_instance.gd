class_name ItemInstance
extends RefCounted
## Un objeto concreto que alguien posee (docs/progresion.md §2.1, PRG-02): una fila de
## [code]item_instances[/code], con un [member uid] único en todo el mundo y para siempre. Lo que el objeto
## es está en su [ItemDefinition] ([member def_id], en [ItemDatabase]).
## [br][br]
## [b]Binario[/b] ([method encode], versión 1, §2.3), para la red (solo hacia el dueño) y las pruebas:
## [codeblock]
## offset  tipo      campo
## 0       u8        format       1
## 1       u64       uid          1 … 2^53 − 1
## 9       u16       def          net id de ItemDatabase (≥ 1)
## 11      u16       count        1 … max_stack
## 13      u16       durability   0–1000; 0xFFFF = sin durabilidad
## 15      u8        rarity       0–4
## 16      u8        flags        bit0 ligado; el resto a 0
## 17      u32       seed
## 21      u8        affix_count  0–6
## 22      n × u16   affixes
## [/codeblock]
## 22 + 2·n B, en little endian como el resto del protocolo. [method decode] devuelve null ante cualquier
## cosa que no cuadre y nunca registra errores del motor (red.md §5.7).
## [br][br]
## [b]JSON[/b] ([method to_dictionary], una entrada de [code]items[/code] en §3.4): los ids
## ([code]uid[/code], [code]seed[/code]) como cadena decimal y la durabilidad null si no tiene. Compartido:
## sin reloj ni azar.

## Versión del formato binario.
const FORMAT: int = 1
## Afijos como mucho (PRG-20).
const MAX_AFFIXES: int = 6
## [member durability] de un objeto sin durabilidad (NULL en la base de datos y en JSON).
const NO_DURABILITY: int = -1
## Mayor [member uid]: un número JSON lo lleva exacto (§3.4).
const MAX_UID: int = (1 << 53) - 1
## Durabilidad máxima (por mil).
const MAX_DURABILITY: int = 1000
## Rareza máxima: 0 común, 1 poco común, 2 rara, 3 épica, 4 legendaria.
const MAX_RARITY: int = 4
## Mayor [member seed] (u32).
const MAX_SEED: int = 0xFFFFFFFF
## Mayor id de afijo (u16).
const MAX_AFFIX_ID: int = 0xFFFF
## Tamaño sin afijos.
const HEADER_SIZE: int = 22
## Durabilidad en el cable de un objeto sin durabilidad.
const WIRE_NO_DURABILITY: int = 0xFFFF
## Bit de ligado en [code]flags[/code].
const FLAG_BOUND: int = 0x01
## Claves de [method to_dictionary], en orden alfabético.
const DICTIONARY_KEYS: Array[String] = ["affixes", "bound", "container", "count", "def_id", "durability",
		"rarity", "seed", "slot", "uid"]

## 1 … [constant MAX_UID]; lo da el [code]IdAllocator[/code] de la zona (§4.5).
var uid: int = 0
var def_id: StringName = &""
## 1 … [member ItemDefinition.max_stack].
var count: int = 1
## 0–1000 si la definición tiene durabilidad; si no, [constant NO_DURABILITY].
var durability: int = NO_DURABILITY
## 0–4. Fase 5: siempre 0.
var rarity: int = 0
## Ligado al personaje.
var bound: bool = false
## u32 de los afijos (PRG-20); 0 = sin afijos.
var seed: int = 0
## Hasta [constant MAX_AFFIXES] ids u16 de afijo (PRG-20). Fase 5: vacío.
var affixes: PackedInt32Array = PackedInt32Array()


## Una instancia nueva de [param definition] con [param count] unidades: durabilidad llena si la lleva
## y ligada si la regla es [code]ON_PICKUP[/code]; sin rareza, semilla ni afijos.
static func create(new_uid: int, definition: ItemDefinition, new_count: int) -> ItemInstance:
	var item := ItemInstance.new()
	item.uid = new_uid
	item.def_id = definition.id
	item.count = new_count
	item.durability = MAX_DURABILITY if definition.has_durability else NO_DURABILITY
	item.bound = definition.bind_rule == ItemDefinition.BindRule.ON_PICKUP
	return item


## true si la instancia cumple las reglas de §2.1 con las definiciones de [param db] (null =
## [method ItemDatabase.shared]): lo mismo que exige [method decode], así que lo que vale se codifica y se
## vuelve a leer igual.
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


## Tamaño codificado: 22 + 2 · afijos.
func encoded_size() -> int:
	return HEADER_SIZE + 2 * affixes.size()


## El binario de §2.3 con el net id de [param db] (null = [method ItemDatabase.shared]). Una instancia que
## no pasa [method is_valid] da un array vacío (sin registrar nada): quien construye el mensaje lo trata
## como un fallo suyo.
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


## Lee una instancia de [param bytes] desde [param offset] con las definiciones de [param db] (null =
## [method ItemDatabase.shared]). null si falta algún byte, el formato no es 1, el uid es 0 o llega a
## 2^53, el net id no existe, la cantidad es 0 o pasa de la pila, la durabilidad no cuadra con
## [member ItemDefinition.has_durability], la rareza pasa de 4, hay bits de flags desconocidos o más de 6
## afijos. Nunca registra errores del motor.
static func decode(bytes: PackedByteArray, offset: int, db: ItemDatabase = null) -> ItemInstance:
	if encoded_size_at(bytes, offset) < 0:
		return null
	if db == null:
		db = ItemDatabase.shared()
	# decode_u64 da un int64: lo que pasa de 2^63 sale negativo y también se rechaza.
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


## Tamaño de la instancia codificada que empieza en [param offset], o −1 si no cabe en [param bytes]: el
## offset está fuera, faltan bytes de la cabecera o de los afijos, el formato no es 1 o hay más de
## [constant MAX_AFFIXES] afijos. Sirve para recorrer una lista de instancias sin decodificarlas.
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


## Una entrada de [code]items[/code] del registro (§3.4), en [param container] y [param slot]: ids como
## cadena, durabilidad null si no tiene y afijos como lista de enteros.
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


## Lee una entrada de [method to_dictionary] con las definiciones de [param db] (null =
## [method ItemDatabase.shared]); null si no cuadra: una clave que falta o que no conoce, un tipo que no
## casa o un valor fuera de rango. Los ids ([code]uid[/code] de 1 a 2^53 − 1, [code]seed[/code] u32) son
## cadenas decimales; un id como número no vale. Los enteros admiten la forma [code]820.0[/code].
## [code]container[/code] y [code]slot[/code] deben ser enteros no negativos; su rango (que depende del
## contenedor y de [code]bag_slots[/code]) lo mira quien lee el registro.
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


## Una copia independiente (también los afijos).
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


## true si [param other] tiene los mismos valores en todos los campos.
func equals(other: ItemInstance) -> bool:
	return other != null and uid == other.uid and def_id == other.def_id and count == other.count \
			and durability == other.durability and rarity == other.rarity and bound == other.bound \
			and seed == other.seed and affixes == other.affixes
