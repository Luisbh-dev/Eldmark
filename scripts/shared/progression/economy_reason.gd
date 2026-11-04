class_name EconomyReason
extends RefCounted
## Reasons for ledger entries and item events (docs/progresion.md §5.3, PRG-12): a fixed u8 that is
## never reused. From 1 to 63, [b]sources[/b] ([code]delta > 0[/code]); from 64 to 127,
## [b]sinks[/b] ([code]delta < 0[/code]); from 128 to 191, [b]internal[/b] (any sign). Those of
## later phases already have their number. The [code]reasons[/code] section of the exported rules
## ([ProgressionRulesExport]) comes from here, except the operation kinds
## ([code]EconomyOp.Kind[/code], server-side). Shared: no clock, no randomness.

# --- Sources ---------------------------------------------------------------------------------
const STARTER_KIT: int = 1
const CAMP_REFILL: int = 2
const PVP_KILL: int = 3
const PVP_ASSIST: int = 4
## Circle, gate, capture and defense.
const OBJECTIVE: int = 5
const NPC_KILL: int = 6
const GM_GRANT: int = 7
const LOOT: int = 8
const QUEST: int = 9
const VENDOR_SELL: int = 10
const TRADE_IN: int = 11
const MAIL_IN: int = 12
const CRAFT_OUTPUT: int = 13
# --- Sinks -----------------------------------------------------------------------------------
const PLAYER_DESTROY: int = 64
const CONSUME: int = 65
const GM_REMOVE: int = 66
const VENDOR_BUY: int = 67
const REPAIR: int = 68
const RESPEC: int = 69
const TRADE_OUT: int = 70
const MAIL_OUT: int = 71
const CRAFT_INPUT: int = 72
const QUARTERMASTER: int = 73
const MARKET_FEE: int = 74
# --- Internal --------------------------------------------------------------------------------
const REVERSAL: int = 128
const MIGRATION: int = 129

## Ranges of each kind of reason.
const SOURCE_MIN: int = 1
const SOURCE_MAX: int = 63
const SINK_MIN: int = 64
const SINK_MAX: int = 127
const INTERNAL_MIN: int = 128
const INTERNAL_MAX: int = 191

## All reasons by their lowercase name (the one in the exported rules).
const CODES: Dictionary[String, int] = {
	"starter_kit": STARTER_KIT, "camp_refill": CAMP_REFILL, "pvp_kill": PVP_KILL, "pvp_assist": PVP_ASSIST,
	"objective": OBJECTIVE, "npc_kill": NPC_KILL, "gm_grant": GM_GRANT, "loot": LOOT, "quest": QUEST,
	"vendor_sell": VENDOR_SELL, "trade_in": TRADE_IN, "mail_in": MAIL_IN, "craft_output": CRAFT_OUTPUT,
	"player_destroy": PLAYER_DESTROY, "consume": CONSUME, "gm_remove": GM_REMOVE, "vendor_buy": VENDOR_BUY,
	"repair": REPAIR, "respec": RESPEC, "trade_out": TRADE_OUT, "mail_out": MAIL_OUT,
	"craft_input": CRAFT_INPUT, "quartermaster": QUARTERMASTER, "market_fee": MARKET_FEE,
	"reversal": REVERSAL, "migration": MIGRATION,
}


## true if [param reason] is in the range of sources (1–63).
static func is_source(reason: int) -> bool:
	return reason >= SOURCE_MIN and reason <= SOURCE_MAX


## true if [param reason] is in the range of sinks (64–127).
static func is_sink(reason: int) -> bool:
	return reason >= SINK_MIN and reason <= SINK_MAX


## true if [param reason] is in the range of internal ones (128–191).
static func is_internal(reason: int) -> bool:
	return reason >= INTERNAL_MIN and reason <= INTERNAL_MAX


## true if [param reason] is one of the reasons in [constant CODES].
static func is_known(reason: int) -> bool:
	return CODES.values().has(reason)


## true if the sign of [param delta] matches the range of [param reason] (§5.2): positive for a
## source, negative for a sink and non-zero for an internal one. A reason outside the three ranges
## never matches.
static func sign_matches(reason: int, delta: int) -> bool:
	if is_source(reason):
		return delta > 0
	if is_sink(reason):
		return delta < 0
	if is_internal(reason):
		return delta != 0
	return false


## true if a merits entry with this reason raises realm points (I9: the in-game ones, 3 to 5).
static func gives_realm_points(reason: int) -> bool:
	return reason == PVP_KILL or reason == PVP_ASSIST or reason == OBJECTIVE


## Lowercase name of [param reason] ([code]starter_kit[/code]…), or empty if it does not exist.
static func name_of(reason: int) -> String:
	for reason_name: String in CODES:
		if CODES[reason_name] == reason:
			return reason_name
	return ""


## The three ranges as in the [code]reasons[/code] section of the exported rules.
static func ranges() -> Dictionary:
	return {
		"source": {"min": SOURCE_MIN, "max": SOURCE_MAX},
		"sink": {"min": SINK_MIN, "max": SINK_MAX},
		"internal": {"min": INTERNAL_MIN, "max": INTERNAL_MAX},
	}
