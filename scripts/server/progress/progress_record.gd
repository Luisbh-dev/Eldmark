class_name ProgressRecord
extends RefCounted
## El registro del progreso de un personaje (docs/progresion.md §3.4, PRG-10): la sección [code]progress[/code] de la
## reclamación (plataforma.md §6) y, sin los campos de solo lectura y con el diario, la de cada guardado (§9.3). Un
## solo dueño por campo (§3.1): raza y apariencia, posición, vida, tiempo jugado, nivel, inventario, monedas y
## temporizadores de CMB-30 son de aquí.
## [br][br]
## [b]JSON[/b] ([code]progress_format[/code] 1): todo id ([code]uid[/code], [code]seed[/code]) es una cadena decimal
## (plataforma.md §4.1) y el resto de enteros, números exactos ([ProgressJson]). [method to_claim_dictionary] da la
## forma de la reclamación, con los campos de solo lectura ([code]race_id[/code], [code]appearance[/code],
## [code]starter_template_id[/code] y [code]location.saved_at_unix[/code]); [method to_dictionary], la del
## guardado, sin ellos (S1 los rechaza). [method from_dictionary] lee la de la reclamación, estricta: ante una
## clave que falta o que no conoce, un tipo que no cuadra o un valor fuera de rango devuelve null sin registrar
## errores del motor. La validez de la apariencia para su raza y su reino la mira [method ProgressService.prepare]
## (§7.2). Solo servidor: sin reloj.

## [code]progress_format[/code]; igual a [constant ZonePlatform.RECORD_FORMAT] (lo comprueba
## [code]test_progress_record[/code]).
const FORMAT: int = 1
## Claves de la forma del guardado ([method to_dictionary]), en orden alfabético.
const SAVE_KEYS: Array[String] = ["active_weapon_slot", "bag_slots", "health", "items", "level", "location",
		"played_seconds", "progress_format", "realm_points", "starter_granted", "timers", "wallets", "xp_total"]
## Las que solo van en la reclamación (§3.4).
const CLAIM_ONLY_KEYS: Array[String] = ["appearance", "race_id", "starter_template_id"]
## Claves de [member location] en un guardado.
const LOCATION_KEYS: Array[String] = ["channel", "in_combat", "x", "y", "yaw", "z", "zone_id"]
## La que [member location] lleva además en la reclamación (la pone [code]Load[/code] desde [code]saved_at[/code]).
const LOCATION_CLAIM_KEY: String = "saved_at_unix"
## Temporizadores como mucho (S7).
const MAX_TIMERS: int = 16
## Formato de la clave de un temporizador (S7).
const TIMER_KEY_PATTERN: String = "^[a-z0-9_:]{1,48}$"
## Formato de [code]race_id[/code], [code]starter_template_id[/code] y [code]location.zone_id[/code].
const TEXT_ID_PATTERN: String = "^[a-z0-9_]{1,64}$"
## Mayor canal ([code]last_channel smallint[/code]).
const MAX_CHANNEL: int = 0x7FFF
## Apariencia en base64: 8 B son 12 caracteres con un [code]=[/code] al final y el último dato canónico.
const APPEARANCE_BASE64_PATTERN: String = "^[A-Za-z0-9+/]{10}[AEIMQUYcgkosw048]=$"

## Raza ([code]race_vardheim[/code]…). Solo lectura: la decide la plataforma al crear.
var race_id: StringName = &""
## Los 8 B de [CharacterAppearance] (§7.2). Solo lectura.
var appearance: PackedByteArray = PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])
## 1–40 y siempre [code]LevelCurve.level_for(xp_total)[/code] (I8).
var level: int = 1
var xp_total: int = 0
## Suben con los méritos de juego y solo bajan al revertirlos (I9).
var realm_points: int = 0
## El cargado más lo jugado desde el alta.
var played_seconds: int = 0
## 30 y no cambia en la fase 5 (I12).
var bag_slots: int = InventoryState.BAG_SLOTS_DEFAULT
## La plantilla elegida al crear (el kit de la primera entrada, §2.5). Solo lectura.
var starter_template_id: StringName = &""
## Nunca vuelve a false (I12).
var starter_granted: bool = false
## La del registro (§8): 0 WEAPON_1, 1 WEAPON_2.
var active_weapon_slot: int = 0
## −1 = llena (null en JSON).
var health: int = -1
## Vacío = null (nunca ha entrado). Si no: [code]zone_id[/code], [code]channel[/code], [code]x[/code],
## [code]y[/code], [code]z[/code], [code]yaw[/code], [code]in_combat[/code] y, solo en la reclamación,
## [code]saved_at_unix[/code].
var location: Dictionary = {}
var inventory: InventoryState = InventoryState.new()
## Saldo por código de moneda ([constant Currency.WALLET_SIZE]: el índice 0 no se usa).
var wallets: PackedInt64Array = PackedInt64Array()
## Clave → [code]ends_at_unix[/code] (CMB-30, §8).
var timers: Dictionary[String, int] = {}

# Los patrones ya compilados (una lectura de 120 objetos no compila cientos de RegEx).
static var _regexes: Dictionary[String, RegEx] = {}


func _init() -> void:
	wallets.resize(Currency.WALLET_SIZE)


## Un personaje recién creado con los valores por defecto (§3.3): nivel 1, nada ganado, la bolsa de 30 vacía, sin
## posición y con la vida llena. Raza, apariencia y plantilla quedan por poner (los efímeros, §9.4, las toman de su
## reino y de LOADOUT_SELECT; [method FakeZonePlatform.claim_progress], de sus argumentos).
static func new_character() -> ProgressRecord:
	return ProgressRecord.new()


## La forma del guardado (§9.3, sin [code]ops[/code], que añade [method PlayerProgress.build_section]): sin los
## campos de solo lectura.
func to_dictionary() -> Dictionary:
	var location_value: Variant = null
	if not location.is_empty():
		var copy: Dictionary = {}
		for key: String in LOCATION_KEYS:
			copy[key] = location.get(key)
		location_value = copy
	var wallet_list: Array = []
	for code: int in Currency.codes():
		wallet_list.append({"currency": code, "balance": wallets[code]})
	var item_list: Array = []
	for position: Vector2i in inventory.occupied_slots():
		item_list.append(inventory.get_item(position.x, position.y).to_dictionary(position.x, position.y))
	var timer_keys: Array[String] = []
	timer_keys.assign(timers.keys())
	timer_keys.sort()
	var timer_list: Array = []
	for key: String in timer_keys:
		timer_list.append({"key": key, "ends_at_unix": timers[key]})
	return {
		"progress_format": FORMAT,
		"level": level,
		"xp_total": xp_total,
		"realm_points": realm_points,
		"played_seconds": played_seconds,
		"bag_slots": bag_slots,
		"starter_granted": starter_granted,
		"active_weapon_slot": active_weapon_slot,
		"health": null if health < 0 else health,
		"location": location_value,
		"wallets": wallet_list,
		"items": item_list,
		"timers": timer_list,
	}


## La forma de la reclamación (§3.4): [method to_dictionary] con los campos de solo lectura y, si hay posición,
## [code]location.saved_at_unix = saved_at_unix[/code]. La de las pruebas y de [FakeZonePlatform].
func to_claim_dictionary(saved_at_unix: int) -> Dictionary:
	var data: Dictionary = to_dictionary()
	data["race_id"] = String(race_id)
	data["appearance"] = Marshalls.raw_to_base64(appearance)
	data["starter_template_id"] = String(starter_template_id)
	if data["location"] != null:
		(data["location"] as Dictionary)[LOCATION_CLAIM_KEY] = saved_at_unix
	return data


## Lee la forma de la reclamación (§3.4) con las definiciones de [param db] (null = [method ItemDatabase.shared]);
## null si no cuadra: una clave que falta o que no conoce, un id que no es una cadena decimal (un id como número no
## vale) o que pasa de 2^53 − 1, un entero que no es exacto o se sale de su rango, una apariencia que no son 8 B en
## base64, nivel y XP que no cumplen I8 con [method LevelCurve.shared], una moneda repetida o que no existe, un
## objeto que no se lee ([method ItemInstance.from_dictionary]) o que no cabe donde está (contenedor 0 o 1, ranura
## de la bolsa por debajo de [code]bag_slots[/code], en el equipo solo armas en las ranuras 0 y 1), dos objetos con
## el mismo [code]uid[/code] o en la misma ranura, o un temporizador que no vale (clave, repetido, más de 16).
static func from_dictionary(data: Dictionary, db: ItemDatabase) -> ProgressRecord:
	if db == null:
		db = ItemDatabase.shared()
	if data.size() != SAVE_KEYS.size() + CLAIM_ONLY_KEYS.size():
		return null
	for key: String in SAVE_KEYS + CLAIM_ONLY_KEYS:
		if not data.has(key):
			return null
	var record := ProgressRecord.new()
	if not ProgressJson.is_int(data["progress_format"], FORMAT, FORMAT):
		return null
	if not _is_text_id(data["race_id"], false) or not _is_text_id(data["starter_template_id"], true):
		return null
	record.race_id = StringName(data["race_id"])
	record.starter_template_id = StringName(data["starter_template_id"])
	record.appearance = _decode_appearance(data["appearance"])
	if record.appearance.is_empty():
		return null
	var curve: LevelCurve = LevelCurve.shared()
	var cap_total: int = curve.total_to(curve.level_cap)
	if not ProgressJson.is_int(data["level"], 1, curve.level_cap) \
			or not ProgressJson.is_int(data["xp_total"], 0, cap_total) \
			or not ProgressJson.is_int(data["realm_points"], 0, ProgressJson.MAX_SAFE_INT) \
			or not ProgressJson.is_int(data["played_seconds"], 0, ProgressJson.MAX_SAFE_INT) \
			or not ProgressJson.is_int(data["bag_slots"], 1, InventoryState.BAG_SLOTS_MAX) \
			or not ProgressJson.is_int(data["active_weapon_slot"], 0, InventoryState.OPEN_EQUIPMENT_SLOTS - 1) \
			or not ProgressJson.is_bool(data["starter_granted"]):
		return null
	record.level = int(data["level"])
	record.xp_total = int(data["xp_total"])
	if curve.level_for(record.xp_total) != record.level:
		return null
	record.realm_points = int(data["realm_points"])
	record.played_seconds = int(data["played_seconds"])
	record.bag_slots = int(data["bag_slots"])
	record.active_weapon_slot = int(data["active_weapon_slot"])
	record.starter_granted = data["starter_granted"]
	if typeof(data["health"]) != TYPE_NIL:
		if not ProgressJson.is_int(data["health"], 0, CombatCatalog.rules().health_max):
			return null
		record.health = int(data["health"])
	if typeof(data["location"]) != TYPE_NIL:
		if typeof(data["location"]) != TYPE_DICTIONARY:
			return null
		record.location = _read_location(data["location"])
		if record.location.is_empty():
			return null
	if not _read_wallets(data["wallets"], record) or not _read_items(data["items"], record, db) \
			or not _read_timers(data["timers"], record):
		return null
	return record


## true si [param other] tiene los mismos valores en todos los campos (el inventario, objeto a objeto).
func equals(other: ProgressRecord) -> bool:
	return other != null and race_id == other.race_id and appearance == other.appearance and level == other.level \
			and xp_total == other.xp_total and realm_points == other.realm_points \
			and played_seconds == other.played_seconds and bag_slots == other.bag_slots \
			and starter_template_id == other.starter_template_id and starter_granted == other.starter_granted \
			and active_weapon_slot == other.active_weapon_slot and health == other.health \
			and location == other.location and wallets == other.wallets and timers == other.timers \
			and inventory.equals(other.inventory)


## Una copia independiente (también el inventario).
func duplicate_record() -> ProgressRecord:
	var copy := ProgressRecord.new()
	copy.race_id = race_id
	copy.appearance = appearance.duplicate()
	copy.level = level
	copy.xp_total = xp_total
	copy.realm_points = realm_points
	copy.played_seconds = played_seconds
	copy.bag_slots = bag_slots
	copy.starter_template_id = starter_template_id
	copy.starter_granted = starter_granted
	copy.active_weapon_slot = active_weapon_slot
	copy.health = health
	copy.location = location.duplicate(true)
	copy.inventory = inventory.duplicate_state()
	copy.wallets = wallets.duplicate()
	copy.timers = timers.duplicate()
	return copy


# --- Lectura ----------------------------------------------------------------------------------

static func _is_text_id(value: Variant, allow_empty: bool) -> bool:
	if typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
		return false
	var text: String = String(value)
	if text.is_empty():
		return allow_empty
	return _matches(TEXT_ID_PATTERN, text)


static func _matches(pattern: String, text: String) -> bool:
	var regex: RegEx = _regexes.get(pattern)
	if regex == null:
		regex = RegEx.new()
		regex.compile(pattern)
		_regexes[pattern] = regex
	return regex.search(text) != null


# Los 8 B de una apariencia en base64 canónico; vacío si no lo es (sin pasar por Marshalls con lo que no vale, que
# registraría un error del motor).
static func _decode_appearance(value: Variant) -> PackedByteArray:
	if typeof(value) != TYPE_STRING or not _matches(APPEARANCE_BASE64_PATTERN, value):
		return PackedByteArray()
	var bytes: PackedByteArray = Marshalls.base64_to_raw(value)
	if bytes.size() != CharacterAppearance.ENCODED_SIZE or Marshalls.raw_to_base64(bytes) != value:
		return PackedByteArray()
	return bytes


# La posición de la reclamación (con saved_at_unix); vacía si no vale.
static func _read_location(data: Dictionary) -> Dictionary:
	if data.size() != LOCATION_KEYS.size() + 1 or not data.has(LOCATION_CLAIM_KEY):
		return {}
	for key: String in LOCATION_KEYS:
		if not data.has(key):
			return {}
	if not _is_text_id(data["zone_id"], false) or not ProgressJson.is_int(data["channel"], 0, MAX_CHANNEL) \
			or not ProgressJson.is_bool(data["in_combat"]) \
			or not ProgressJson.is_int(data[LOCATION_CLAIM_KEY], 0, ProgressJson.MAX_SAFE_INT):
		return {}
	var result: Dictionary = {
		"zone_id": String(data["zone_id"]),
		"channel": int(data["channel"]),
		"in_combat": bool(data["in_combat"]),
		LOCATION_CLAIM_KEY: int(data[LOCATION_CLAIM_KEY]),
	}
	for key: String in ["x", "y", "z", "yaw"]:
		var number: Variant = data[key]
		if typeof(number) != TYPE_FLOAT and typeof(number) != TYPE_INT:
			return {}
		if not is_finite(float(number)):
			return {}
		result[key] = float(number)
	return result


static func _read_wallets(value: Variant, record: ProgressRecord) -> bool:
	if typeof(value) != TYPE_ARRAY:
		return false
	var seen: Dictionary[int, bool] = {}
	for entry: Variant in value:
		if typeof(entry) != TYPE_DICTIONARY:
			return false
		var wallet: Dictionary = entry
		if wallet.size() != 2 or not wallet.has("currency") or not wallet.has("balance"):
			return false
		if not ProgressJson.is_int(wallet["currency"], 1, Currency.WALLET_SIZE - 1) \
				or not ProgressJson.is_int(wallet["balance"], 0, Currency.CAP):
			return false
		var code: int = int(wallet["currency"])
		if not Currency.is_valid(code) or seen.has(code):
			return false
		seen[code] = true
		record.wallets[code] = int(wallet["balance"])
	return true


static func _read_items(value: Variant, record: ProgressRecord, db: ItemDatabase) -> bool:
	if typeof(value) != TYPE_ARRAY:
		return false
	var state := InventoryState.new(record.bag_slots)
	var uids: Dictionary[int, bool] = {}
	for entry: Variant in value:
		if typeof(entry) != TYPE_DICTIONARY:
			return false
		var item: ItemInstance = ItemInstance.from_dictionary(entry, db)
		if item == null or uids.has(item.uid):
			return false
		uids[item.uid] = true
		var container: int = int((entry as Dictionary)["container"])
		var slot: int = int((entry as Dictionary)["slot"])
		if not InventoryState.OPEN_CONTAINERS.has(container) or not state.has_slot(container, slot) \
				or state.get_item(container, slot) != null:
			return false
		if container == InventoryState.ContainerId.EQUIPMENT and (slot >= InventoryState.OPEN_EQUIPMENT_SLOTS
				or not InventoryOps.fits_slot(db.get_definition(item.def_id), slot)):
			return false
		state.set_item(container, slot, item)
	record.inventory = state
	return true


static func _read_timers(value: Variant, record: ProgressRecord) -> bool:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() > MAX_TIMERS:
		return false
	for entry: Variant in value:
		if typeof(entry) != TYPE_DICTIONARY:
			return false
		var timer: Dictionary = entry
		if timer.size() != 2 or not timer.has("key") or not timer.has("ends_at_unix"):
			return false
		if typeof(timer["key"]) != TYPE_STRING or not _matches(TIMER_KEY_PATTERN, timer["key"]) \
				or record.timers.has(timer["key"]) \
				or not ProgressJson.is_int(timer["ends_at_unix"], 0, ProgressJson.MAX_SAFE_INT):
			return false
		record.timers[String(timer["key"])] = int(timer["ends_at_unix"])
	return true
