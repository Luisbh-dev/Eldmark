class_name EconomyOp
extends RefCounted
## An economic operation (docs/progression.md §3.3, §5.2 and §9.3, PRG-12): what is applied at once (I7) with
## its ledger entries ([LedgerEntry]) and its item events ([ItemEvent]). The zone keeps in the
## [PlayerProgress] journal those that a save has not yet confirmed; each body carries those not yet in any
## ([member save_seq] 0) and gives them their [code]seq[/code] (§9.2).
## [br][br]
## [b]JSON[/b] ([method to_dictionary], the [code]ops[/code] entry of §9.3): string ids
## ([code]op_id[/code], [code]actor_account_id[/code] and [code]ref_op_id[/code], the latter two null if absent), the
## [code]note[/code] null if empty and [code]detail[/code] as is. [member save_seq] does not travel. Server
## only: no clock (the time of [code]detail.at_unix[/code] is set by whoever creates the operation, with
## [method ZonePlatform.now_unix]).

## Operation types ([code]economy_ops.kind[/code], §5.3). The same numbers as
## [constant ProgressionRulesExport.OP_KINDS] (checked by [code]test_player_progress[/code]); 7 TRADE and 8 MAIL
## are from phase 6 and 9 to 15 are reserved.
enum Kind { PLAYER = 1, GAMEPLAY = 2, STARTER_KIT = 3, GM = 4, REVERSAL = 5, MIGRATION = 6 }

## Keys of [method to_dictionary], in alphabetical order.
const DICTIONARY_KEYS: Array[String] = ["actor_account_id", "detail", "items", "kind", "ledger", "note",
		"op_id", "ref_op_id"]
## Maximum length of [member note] (the column, §3.3).
const MAX_NOTE_LENGTH: int = 200
## Types that [method from_dictionary] accepts (1–15, §3.3).
const MAX_KIND: int = 15
## Reasons each type accepts in entries and events (S2 of §13.3).
const KIND_REASONS: Dictionary[int, Array] = {
	Kind.PLAYER: [EconomyReason.PLAYER_DESTROY],
	Kind.GAMEPLAY: [EconomyReason.CAMP_REFILL, EconomyReason.PVP_KILL, EconomyReason.PVP_ASSIST,
			EconomyReason.OBJECTIVE, EconomyReason.NPC_KILL, EconomyReason.CONSUME],
	Kind.STARTER_KIT: [EconomyReason.STARTER_KIT],
	Kind.GM: [EconomyReason.GM_GRANT, EconomyReason.GM_REMOVE],
	Kind.REVERSAL: [EconomyReason.REVERSAL],
	Kind.MIGRATION: [EconomyReason.MIGRATION],
}

## 1 … 2^53 − 1; from the same id block as the [code]uid[/code]s (§4.5).
var op_id: int = 0
## [enum Kind].
var kind: int = 0
## The GM's account in GM and REVERSAL; 0 (null) in the others and from the console.
var actor_account_id: int = 0
## The reverted operation (REVERSAL); 0 (null) in the others.
var ref_op_id: int = 0
## The written reason (GM, REVERSAL; "debug" via DEBUG_COMMAND); empty (null) in the others.
var note: String = ""
## The trail of §10 ([code]command[/code], [code]args[/code], [code]source[/code], [code]actor_character_id[/code],
## [code]at_unix[/code]…); empty in gameplay ones.
var detail: Dictionary = {}
var ledger: Array[LedgerEntry] = []
var items: Array[ItemEvent] = []
## The [code]seq[/code] of the body it went out in; 0 = not yet in any save (§9.2).
var save_seq: int = 0


## An operation of [param op_kind] with [param id], with no entries or events.
static func create(id: int, op_kind: int, actor: int = 0, op_note: String = "",
		op_detail: Dictionary = {}) -> EconomyOp:
	var op := EconomyOp.new()
	op.op_id = id
	op.kind = op_kind
	op.actor_account_id = actor
	op.note = op_note
	op.detail = op_detail.duplicate(true)
	return op


## true if it carries no entries or events.
func is_empty() -> bool:
	return ledger.is_empty() and items.is_empty()


## true if every entry and every event uses a reason of its type ([constant KIND_REASONS]) and, in GM and REVERSAL, the
## [member note] is not empty: what S2 (§13.3) requires of the shape of the operation.
func is_consistent() -> bool:
	var allowed: Array = KIND_REASONS.get(kind, [])
	if allowed.is_empty():
		return false
	for entry: LedgerEntry in ledger:
		if not allowed.has(entry.reason):
			return false
	for event: ItemEvent in items:
		if not allowed.has(event.reason):
			return false
	if (kind == Kind.GM or kind == Kind.REVERSAL) and note.strip_edges().is_empty():
		return false
	return true


## The [code]ops[/code] entry of a save (§9.3).
func to_dictionary() -> Dictionary:
	var ledger_list: Array = []
	for entry: LedgerEntry in ledger:
		ledger_list.append(entry.to_dictionary())
	var item_list: Array = []
	for event: ItemEvent in items:
		item_list.append(event.to_dictionary())
	return {
		"op_id": ProgressJson.id_text(op_id),
		"kind": kind,
		"actor_account_id": null if actor_account_id == 0 else ProgressJson.id_text(actor_account_id),
		"ref_op_id": null if ref_op_id == 0 else ProgressJson.id_text(ref_op_id),
		"note": null if note.is_empty() else note,
		"detail": detail.duplicate(true),
		"ledger": ledger_list,
		"items": item_list,
	}


## Reads an entry from [method to_dictionary] (a save's, or the P5d operation route's without its extra
## fields); null if it does not fit: a key that is missing or unknown, an id that is not a decimal string from 1 to
## 2^53 − 1 ([code]actor_account_id[/code] and [code]ref_op_id[/code], also null), a type outside 1–15, a
## [code]note[/code] that is neither null nor text of up to 200 characters, a [code]detail[/code] that is not an object or
## an entry or event that cannot be read ([method LedgerEntry.from_dictionary], [method ItemEvent.from_dictionary]).
## It does not check that the reasons fit the type ([method is_consistent]): an old operation or one from a migration
## is read all the same.
static func from_dictionary(data: Dictionary) -> EconomyOp:
	if data.size() != DICTIONARY_KEYS.size():
		return null
	for key: String in DICTIONARY_KEYS:
		if not data.has(key):
			return null
	if not ProgressJson.is_id(data["op_id"]) or not ProgressJson.is_int(data["kind"], 1, MAX_KIND):
		return null
	var op := EconomyOp.new()
	op.op_id = ProgressJson.id_value(data["op_id"])
	op.kind = int(data["kind"])
	for key: String in ["actor_account_id", "ref_op_id"]:
		if typeof(data[key]) == TYPE_NIL:
			continue
		if not ProgressJson.is_id(data[key]):
			return null
		op.set(key, ProgressJson.id_value(data[key]))
	var note_value: Variant = data["note"]
	if typeof(note_value) != TYPE_NIL:
		if typeof(note_value) != TYPE_STRING or String(note_value).length() > MAX_NOTE_LENGTH:
			return null
		op.note = note_value
	if typeof(data["detail"]) != TYPE_DICTIONARY:
		return null
	op.detail = (data["detail"] as Dictionary).duplicate(true)
	if typeof(data["ledger"]) != TYPE_ARRAY or typeof(data["items"]) != TYPE_ARRAY:
		return null
	for value: Variant in data["ledger"]:
		if typeof(value) != TYPE_DICTIONARY:
			return null
		var entry: LedgerEntry = LedgerEntry.from_dictionary(value)
		if entry == null:
			return null
		op.ledger.append(entry)
	for value: Variant in data["items"]:
		if typeof(value) != TYPE_DICTIONARY:
			return null
		var event: ItemEvent = ItemEvent.from_dictionary(value)
		if event == null:
			return null
		op.items.append(event)
	return op


## true if [param other] has the same values (not looking at [member save_seq]).
func equals(other: EconomyOp) -> bool:
	if other == null or op_id != other.op_id or kind != other.kind or actor_account_id != other.actor_account_id \
			or ref_op_id != other.ref_op_id or note != other.note or detail != other.detail \
			or ledger.size() != other.ledger.size() or items.size() != other.items.size():
		return false
	for i: int in range(ledger.size()):
		if not ledger[i].equals(other.ledger[i]):
			return false
	for i: int in range(items.size()):
		if not items[i].equals(other.items[i]):
			return false
	return true


## Name of type [param op_kind] in lowercase (that of the exported rules), or empty.
static func kind_name(op_kind: int) -> String:
	for kind_key: String in Kind:
		if Kind[kind_key] == op_kind:
			return kind_key.to_lower()
	return ""


func _to_string() -> String:
	return "EconomyOp(%d, %s, %d apuntes, %d eventos, seq %d)" % [op_id, kind_name(kind), ledger.size(), items.size(),
			save_seq]
