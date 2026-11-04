class_name ProgressRecord
extends RefCounted
## A character's progress record (docs/progression.md §3.4, PRG-10): the [code]progress[/code] section of the claim
## (platform.md §6) and, without the read-only fields and with the journal, that of each save (§9.3). A single owner
## per field (§3.1): race and appearance, position, health, played time, level, inventory, currencies and CMB-30
## timers belong here.
## [br][br]
## [b]JSON[/b] ([code]progress_format[/code] 1): every id ([code]uid[/code], [code]seed[/code]) is a decimal string
## (platform.md §4.1) and the remaining integers are exact numbers ([ProgressJson]). [method to_claim_dictionary]
## gives the claim's shape, with the read-only fields ([code]race_id[/code], [code]appearance[/code],
## [code]starter_template_id[/code] and [code]location.saved_at_unix[/code]); [method to_dictionary], the save's,
## without them (S1 rejects them). [method from_dictionary] reads the claim's, strictly: on a missing or unknown key,
## a mismatched type or an out-of-range value it returns null without logging engine errors. The validity of the
## appearance for its race and realm is checked by [method ProgressService.prepare] (§7.2). Server only: no clock.

## [code]progress_format[/code]; equal to [constant ZonePlatform.RECORD_FORMAT] (checked by
## [code]test_progress_record[/code]).
const FORMAT: int = 1
## Keys of the save shape ([method to_dictionary]), in alphabetical order.
const SAVE_KEYS: Array[String] = ["active_weapon_slot", "bag_slots", "health", "items", "level", "location",
		"played_seconds", "progress_format", "realm_points", "starter_granted", "timers", "wallets", "xp_total"]
## Those that only go in the claim (§3.4).
const CLAIM_ONLY_KEYS: Array[String] = ["appearance", "race_id", "starter_template_id"]
## Keys of [member location] in a save.
const LOCATION_KEYS: Array[String] = ["channel", "in_combat", "x", "y", "yaw", "z", "zone_id"]
## The one that [member location] also carries in the claim ([code]Load[/code] sets it from [code]saved_at[/code]).
const LOCATION_CLAIM_KEY: String = "saved_at_unix"
## Maximum number of timers (S7).
const MAX_TIMERS: int = 16
## Format of a timer key (S7).
const TIMER_KEY_PATTERN: String = "^[a-z0-9_:]{1,48}$"
## Format of [code]race_id[/code], [code]starter_template_id[/code] and [code]location.zone_id[/code].
const TEXT_ID_PATTERN: String = "^[a-z0-9_]{1,64}$"
## Highest channel ([code]last_channel smallint[/code]).
const MAX_CHANNEL: int = 0x7FFF
## Appearance in base64: 8 B are 12 characters with a [code]=[/code] at the end and the last data char canonical.
const APPEARANCE_BASE64_PATTERN: String = "^[A-Za-z0-9+/]{10}[AEIMQUYcgkosw048]=$"

## Race ([code]race_vardheim[/code]…). Read-only: decided by the platform on creation.
var race_id: StringName = &""
## The 8 B of [CharacterAppearance] (§7.2). Read-only.
var appearance: PackedByteArray = PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])
## 1–40 and always [code]LevelCurve.level_for(xp_total)[/code] (I8).
var level: int = 1
var xp_total: int = 0
## They rise with gameplay merits and only fall when those are reverted (I9).
var realm_points: int = 0
## The loaded time plus the time played since registration.
var played_seconds: int = 0
## 30 and does not change in phase 5 (I12).
var bag_slots: int = InventoryState.BAG_SLOTS_DEFAULT
## The template chosen on creation (the first-entry kit, §2.5). Read-only.
var starter_template_id: StringName = &""
## Never goes back to false (I12).
var starter_granted: bool = false
## The record's (§8): 0 WEAPON_1, 1 WEAPON_2.
var active_weapon_slot: int = 0
## −1 = full (null in JSON).
var health: int = -1
## Empty = null (never entered). Otherwise: [code]zone_id[/code], [code]channel[/code], [code]x[/code],
## [code]y[/code], [code]z[/code], [code]yaw[/code], [code]in_combat[/code] and, only in the claim,
## [code]saved_at_unix[/code].
var location: Dictionary = {}
var inventory: InventoryState = InventoryState.new()
## Balance per currency code ([constant Currency.WALLET_SIZE]: index 0 is unused).
var wallets: PackedInt64Array = PackedInt64Array()
## Key → [code]ends_at_unix[/code] (CMB-30, §8).
var timers: Dictionary[String, int] = {}

# The already compiled patterns (reading 120 items does not compile hundreds of RegExes).
static var _regexes: Dictionary[String, RegEx] = {}


func _init() -> void:
	wallets.resize(Currency.WALLET_SIZE)


## A newly created character with the default values (§3.3): level 1, nothing earned, an empty 30-slot bag, no
## position and full health. Race, appearance and template are left to be set (ephemeral ones, §9.4, take them from
## their realm and from LOADOUT_SELECT; [method FakeZonePlatform.claim_progress], from its arguments).
static func new_character() -> ProgressRecord:
	return ProgressRecord.new()


## The save shape (§9.3, without [code]ops[/code], which [method PlayerProgress.build_section] adds): without the
## read-only fields.
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


## The claim shape (§3.4): [method to_dictionary] with the read-only fields and, if there is a position,
## [code]location.saved_at_unix = saved_at_unix[/code]. The one used by tests and by [FakeZonePlatform].
func to_claim_dictionary(saved_at_unix: int) -> Dictionary:
	var data: Dictionary = to_dictionary()
	data["race_id"] = String(race_id)
	data["appearance"] = Marshalls.raw_to_base64(appearance)
	data["starter_template_id"] = String(starter_template_id)
	if data["location"] != null:
		(data["location"] as Dictionary)[LOCATION_CLAIM_KEY] = saved_at_unix
	return data


## Reads the claim shape (§3.4) with the definitions of [param db] (null = [method ItemDatabase.shared]); null if it
## does not fit: a missing or unknown key, an id that is not a decimal string (an id as a number is not valid) or that
## exceeds 2^53 − 1, an integer that is not exact or is out of range, an appearance that is not 8 B in base64, level
## and XP that do not satisfy I8 with [method LevelCurve.shared], a repeated or nonexistent currency, an item that
## cannot be read ([method ItemInstance.from_dictionary]) or does not fit where it is (container 0 or 1, bag slot
## below [code]bag_slots[/code], in equipment only weapons in slots 0 and 1), two items with the same [code]uid[/code]
## or in the same slot, or an invalid timer (key, repeated, more than 16).
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


## true if [param other] has the same values in every field (the inventory, item by item).
func equals(other: ProgressRecord) -> bool:
	return other != null and race_id == other.race_id and appearance == other.appearance and level == other.level \
			and xp_total == other.xp_total and realm_points == other.realm_points \
			and played_seconds == other.played_seconds and bag_slots == other.bag_slots \
			and starter_template_id == other.starter_template_id and starter_granted == other.starter_granted \
			and active_weapon_slot == other.active_weapon_slot and health == other.health \
			and location == other.location and wallets == other.wallets and timers == other.timers \
			and inventory.equals(other.inventory)


## An independent copy (the inventory too).
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


# --- Reading ----------------------------------------------------------------------------------

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


# The 8 B of an appearance in canonical base64; empty if it is not one (without passing invalid input through
# Marshalls, which would log an engine error).
static func _decode_appearance(value: Variant) -> PackedByteArray:
	if typeof(value) != TYPE_STRING or not _matches(APPEARANCE_BASE64_PATTERN, value):
		return PackedByteArray()
	var bytes: PackedByteArray = Marshalls.base64_to_raw(value)
	if bytes.size() != CharacterAppearance.ENCODED_SIZE or Marshalls.raw_to_base64(bytes) != value:
		return PackedByteArray()
	return bytes


# The position from the claim (with saved_at_unix); empty if invalid.
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
