class_name ItemEvent
extends RefCounted
## An item event (docs/progression.md §3.3, §5.2 and §9.3, I4): the only thing that changes the
## total quantity of a definition. It is given by sources, sinks, reversal and migration (§5.3);
## moving, splitting, merging, swapping and equipping give none. It belongs to an operation
## ([code]EconomyOp[/code], server-side), which carries it in its [code]items[/code].
## [br][br]
## [b]JSON[/b] ([method to_dictionary], §9.3): [code]{"uid": "1027", "def_id": "potion_health",
## "count_delta": -1, "reason": 65}[/code], with [code]uid[/code] null in an aggregated event
## (CAMP_REFILL, CONSUME). Shared: no clock, no randomness.

## Keys of [method to_dictionary], in alphabetical order.
const DICTIONARY_KEYS: Array[String] = ["count_delta", "def_id", "reason", "uid"]
## Largest [member count_delta] in absolute value (the column is [code]int[/code]).
const MAX_COUNT_DELTA: int = 0x7FFFFFFF

## The instance it belongs to (kit, GM, player DESTROY); 0 = aggregated (null in JSON).
var uid: int = 0
var def_id: StringName = &""
## Units that come in (> 0) or go out (< 0); never 0.
var count_delta: int = 0
## Reason ([EconomyReason]); its sign matches [member count_delta].
var reason: int = 0


## An event with those values.
static func create(event_uid: int, event_def_id: StringName, delta: int, event_reason: int) -> ItemEvent:
	var event := ItemEvent.new()
	event.uid = event_uid
	event.def_id = event_def_id
	event.count_delta = delta
	event.reason = event_reason
	return event


## The [code]items[/code] entry of an operation (§9.3): [code]uid[/code] as a decimal string or
## null.
func to_dictionary() -> Dictionary:
	return {
		"uid": null if uid == 0 else ProgressJson.id_text(uid),
		"def_id": String(def_id),
		"count_delta": count_delta,
		"reason": reason,
	}


## Reads an entry from [method to_dictionary]; null if it does not fit: a missing or unknown key, a
## [code]uid[/code] that is neither null nor an id from 1 to 2^53 − 1 as a string, a
## [code]def_id[/code] without the format of [constant ItemDefinition.ID_PATTERN], a
## [code]count_delta[/code] of 0 or out of range, or a reason whose sign does not match
## ([method EconomyReason.sign_matches]). It does not check whether the definition exists: an old
## event may name one that is no longer there.
static func from_dictionary(data: Dictionary) -> ItemEvent:
	if data.size() != DICTIONARY_KEYS.size():
		return null
	for key: String in DICTIONARY_KEYS:
		if not data.has(key):
			return null
	var event_uid: int = 0
	if typeof(data["uid"]) != TYPE_NIL:
		if not ProgressJson.is_id(data["uid"], 1, ItemInstance.MAX_UID):
			return null
		event_uid = ProgressJson.id_value(data["uid"])
	var def_value: Variant = data["def_id"]
	if typeof(def_value) != TYPE_STRING and typeof(def_value) != TYPE_STRING_NAME:
		return null
	var id_regex := RegEx.new()
	id_regex.compile(ItemDefinition.ID_PATTERN)
	if id_regex.search(String(def_value)) == null:
		return null
	if not ProgressJson.is_int(data["count_delta"], -MAX_COUNT_DELTA, MAX_COUNT_DELTA) \
			or not ProgressJson.is_int(data["reason"], 1, 0xFF):
		return null
	var delta: int = int(data["count_delta"])
	var event_reason: int = int(data["reason"])
	if not EconomyReason.sign_matches(event_reason, delta):
		return null
	return create(event_uid, StringName(def_value), delta, event_reason)


## true if [param other] has the same values.
func equals(other: ItemEvent) -> bool:
	return other != null and uid == other.uid and def_id == other.def_id \
			and count_delta == other.count_delta and reason == other.reason


func _to_string() -> String:
	return "ItemEvent(uid=%d, %s, %+d, motivo %d)" % [uid, def_id, count_delta, reason]
