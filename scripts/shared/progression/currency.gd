class_name Currency
extends RefCounted
## The currencies (docs/progresion.md §5.1, PRG-12): [code]int64[/code] balances per character,
## never negative nor above [constant CAP]. The balance rules are in [CurrencyRules]; the
## [code]currencies[/code] section of the exported rules ([ProgressionRulesExport]) comes from
## here.
## [br][br]
## Realm points are not a currency: they rise with in-game merits (I9,
## [method EconomyReason.gives_realm_points]). Shared: no clock, no randomness.

## Code of each currency (in the database, in the ledger and on the wire, this number).
enum Code { GOLD = 1, MERITS = 2 }

## Cap of any balance: one billion. In GDScript, [code]^[/code] is XOR ([code]10^9[/code] would be
## 3).
const CAP: int = 1_000_000_000
## Size of a wallet indexed by code ([code]PackedInt64Array[/code]; index 0 is unused).
const WALLET_SIZE: int = 3
## Text id of each currency (the exported rules and the platform).
const IDS: Dictionary[int, String] = {Code.GOLD: "gold", Code.MERITS: "merits"}
## Spanish name of each currency (interface and notices).
const DISPLAY_NAMES: Dictionary[int, String] = {Code.GOLD: "Oro", Code.MERITS: "Méritos"}


## The codes of all currencies, in order.
static func codes() -> Array[int]:
	var result: Array[int] = []
	for code: int in IDS:
		result.append(code)
	result.sort()
	return result


## true if [param code] is the code of a currency.
static func is_valid(code: int) -> bool:
	return IDS.has(code)


## Text id of [param code] ([code]gold[/code], [code]merits[/code]), or empty if it does not exist.
static func id_of(code: int) -> String:
	return IDS.get(code, "")


## Code of the currency with id [param id], or 0 if it does not exist.
static func code_of(id: String) -> int:
	for code: int in IDS:
		if IDS[code] == id:
			return code
	return 0


## Balance cap of [param code] (the same for all in phase 5), or 0 if it does not exist.
static func cap_of(code: int) -> int:
	return CAP if is_valid(code) else 0


## Spanish name of [param code], or empty if it does not exist.
static func display_name(code: int) -> String:
	return DISPLAY_NAMES.get(code, "")
