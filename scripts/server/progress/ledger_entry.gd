class_name LedgerEntry
extends RefCounted
## A ledger entry (docs/progresion.md §5.2, PRG-12): a balance change of one currency within an
## operation ([EconomyOp]). The [code]seq[/code] of each balance is set by the platform on saving (§5.2): the zone does not
## send it. Immutable once in the journal (I6).
## [br][br]
## [b]JSON[/b] ([method to_dictionary], §9.3): [code]{"currency": 1, "delta": 2, "balance_after": 102,
## "reason": 6, "ref_kind": 2, "ref_id": "3021413298"}[/code], with [code]ref_id[/code] as a decimal string (an id
## from 0 to 2^53 − 1). Server only: no clock.

## What the entry refers to ([member ref_kind]).
enum RefKind { NONE = 0, CHARACTER = 1, NPC = 2, FORTRESS = 3, OP = 4 }

## Keys of [method to_dictionary], in alphabetical order.
const DICTIONARY_KEYS: Array[String] = ["balance_after", "currency", "delta", "reason", "ref_id", "ref_kind"]

## Code of [enum Currency.Code].
var currency: int = 0
## Change in the balance; never 0. Its sign matches the range of [member reason] (§5.2).
var delta: int = 0
## Balance after the entry (0 … [constant Currency.CAP]).
var balance_after: int = 0
## Reason ([EconomyReason]).
var reason: int = 0
## [enum RefKind]: 0 none; 1 character (PvP victim: their [code]character_id[/code]); 2 NPC and 3 fortress (the
## u32 fingerprint of their text id, [method HandoffTicket.zone_key_of]); 4 operation (the reverted one).
var ref_kind: int = RefKind.NONE
var ref_id: int = 0


## An entry with those values.
static func create(entry_currency: int, entry_delta: int, entry_balance_after: int, entry_reason: int,
		entry_ref_kind: int = RefKind.NONE, entry_ref_id: int = 0) -> LedgerEntry:
	var entry := LedgerEntry.new()
	entry.currency = entry_currency
	entry.delta = entry_delta
	entry.balance_after = entry_balance_after
	entry.reason = entry_reason
	entry.ref_kind = entry_ref_kind
	entry.ref_id = entry_ref_id
	return entry


## The [code]ledger[/code] entry of an operation (§9.3).
func to_dictionary() -> Dictionary:
	return {
		"currency": currency,
		"delta": delta,
		"balance_after": balance_after,
		"reason": reason,
		"ref_kind": ref_kind,
		"ref_id": ProgressJson.id_text(ref_id),
	}


## Reads an entry from [method to_dictionary]; null if it does not fit: a key that is missing or unknown, a currency
## that does not exist, a [code]delta[/code] of 0 or larger than the cap, a balance outside 0 … cap, a reason whose sign
## does not match ([method EconomyReason.sign_matches]), a [code]ref_kind[/code] outside 0–4 or a
## [code]ref_id[/code] that is not a string id (from 0 to 2^53 − 1). Integers accept the form
## [code]820.0[/code].
static func from_dictionary(data: Dictionary) -> LedgerEntry:
	if data.size() != DICTIONARY_KEYS.size():
		return null
	for key: String in DICTIONARY_KEYS:
		if not data.has(key):
			return null
	if not ProgressJson.is_int(data["currency"], 1, 0xFF) or not Currency.is_valid(int(data["currency"])):
		return null
	if not ProgressJson.is_int(data["delta"], -Currency.CAP, Currency.CAP) \
			or not ProgressJson.is_int(data["balance_after"], 0, Currency.CAP) \
			or not ProgressJson.is_int(data["reason"], 1, 0xFF) \
			or not ProgressJson.is_int(data["ref_kind"], RefKind.NONE, RefKind.OP) \
			or not ProgressJson.is_id(data["ref_id"], 0):
		return null
	var entry_delta: int = int(data["delta"])
	var entry_reason: int = int(data["reason"])
	if not EconomyReason.sign_matches(entry_reason, entry_delta):
		return null
	return create(int(data["currency"]), entry_delta, int(data["balance_after"]), entry_reason,
			int(data["ref_kind"]), ProgressJson.id_value(data["ref_id"]))


## true if [param other] has the same values.
func equals(other: LedgerEntry) -> bool:
	return other != null and currency == other.currency and delta == other.delta \
			and balance_after == other.balance_after and reason == other.reason and ref_kind == other.ref_kind \
			and ref_id == other.ref_id


func _to_string() -> String:
	return "LedgerEntry(moneda %d, %+d → %d, motivo %d, ref %d:%d)" % [currency, delta, balance_after, reason,
			ref_kind, ref_id]
