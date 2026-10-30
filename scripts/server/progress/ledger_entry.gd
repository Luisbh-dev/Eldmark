class_name LedgerEntry
extends RefCounted
## Un apunte del libro mayor (docs/progresion.md §5.2, PRG-12): un cambio de saldo de una moneda dentro de una
## operación ([EconomyOp]). El [code]seq[/code] de cada saldo lo pone la plataforma al guardar (§5.2): la zona no
## lo manda. Inmutable una vez en el diario (I6).
## [br][br]
## [b]JSON[/b] ([method to_dictionary], §9.3): [code]{"currency": 1, "delta": 2, "balance_after": 102,
## "reason": 6, "ref_kind": 2, "ref_id": "3021413298"}[/code], con [code]ref_id[/code] como cadena decimal (un id
## de 0 a 2^53 − 1). Solo servidor: sin reloj.

## A qué se refiere el apunte ([member ref_kind]).
enum RefKind { NONE = 0, CHARACTER = 1, NPC = 2, FORTRESS = 3, OP = 4 }

## Claves de [method to_dictionary], en orden alfabético.
const DICTIONARY_KEYS: Array[String] = ["balance_after", "currency", "delta", "reason", "ref_id", "ref_kind"]

## Código de [enum Currency.Code].
var currency: int = 0
## Cambio del saldo; nunca 0. Su signo cuadra con el rango de [member reason] (§5.2).
var delta: int = 0
## Saldo tras el apunte (0 … [constant Currency.CAP]).
var balance_after: int = 0
## Motivo ([EconomyReason]).
var reason: int = 0
## [enum RefKind]: 0 ninguna; 1 personaje (víctima PvP: su [code]character_id[/code]); 2 PNJ y 3 fortaleza (la
## huella u32 de su id de texto, [method HandoffTicket.zone_key_of]); 4 operación (la revertida).
var ref_kind: int = RefKind.NONE
var ref_id: int = 0


## Un apunte con esos valores.
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


## La entrada de [code]ledger[/code] de una operación (§9.3).
func to_dictionary() -> Dictionary:
	return {
		"currency": currency,
		"delta": delta,
		"balance_after": balance_after,
		"reason": reason,
		"ref_kind": ref_kind,
		"ref_id": ProgressJson.id_text(ref_id),
	}


## Lee una entrada de [method to_dictionary]; null si no cuadra: una clave que falta o que no conoce, una moneda
## que no existe, un [code]delta[/code] de 0 o de más que el tope, un saldo fuera de 0 … tope, un motivo cuyo signo
## no cuadra ([method EconomyReason.sign_matches]), un [code]ref_kind[/code] fuera de 0–4 o un
## [code]ref_id[/code] que no es un id en cadena (de 0 a 2^53 − 1). Los enteros admiten la forma
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


## true si [param other] tiene los mismos valores.
func equals(other: LedgerEntry) -> bool:
	return other != null and currency == other.currency and delta == other.delta \
			and balance_after == other.balance_after and reason == other.reason and ref_kind == other.ref_kind \
			and ref_id == other.ref_id


func _to_string() -> String:
	return "LedgerEntry(moneda %d, %+d → %d, motivo %d, ref %d:%d)" % [currency, delta, balance_after, reason,
			ref_kind, ref_id]
