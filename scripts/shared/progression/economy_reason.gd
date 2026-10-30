class_name EconomyReason
extends RefCounted
## Motivos de los apuntes del libro y de los eventos de objeto (docs/progresion.md §5.3, PRG-12): un u8
## fijo que nunca se reutiliza. Del 1 al 63, [b]fuentes[/b] ([code]delta > 0[/code]); del 64 al 127,
## [b]sumideros[/b] ([code]delta < 0[/code]); del 128 al 191, [b]internos[/b] (cualquier signo). Los de
## fases siguientes ya tienen su número. La sección [code]reasons[/code] de las reglas exportadas
## ([ProgressionRulesExport]) sale de aquí, salvo los tipos de operación ([code]EconomyOp.Kind[/code], del
## servidor). Compartido: sin reloj ni azar.

# --- Fuentes ---------------------------------------------------------------------------------
const STARTER_KIT: int = 1
const CAMP_REFILL: int = 2
const PVP_KILL: int = 3
const PVP_ASSIST: int = 4
## Círculo, puerta, captura y defensa.
const OBJECTIVE: int = 5
const NPC_KILL: int = 6
const GM_GRANT: int = 7
const LOOT: int = 8
const QUEST: int = 9
const VENDOR_SELL: int = 10
const TRADE_IN: int = 11
const MAIL_IN: int = 12
const CRAFT_OUTPUT: int = 13
# --- Sumideros -------------------------------------------------------------------------------
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
# --- Internos --------------------------------------------------------------------------------
const REVERSAL: int = 128
const MIGRATION: int = 129

## Rangos de cada tipo de motivo.
const SOURCE_MIN: int = 1
const SOURCE_MAX: int = 63
const SINK_MIN: int = 64
const SINK_MAX: int = 127
const INTERNAL_MIN: int = 128
const INTERNAL_MAX: int = 191

## Todos los motivos por su nombre en minúsculas (el de las reglas exportadas).
const CODES: Dictionary[String, int] = {
	"starter_kit": STARTER_KIT, "camp_refill": CAMP_REFILL, "pvp_kill": PVP_KILL, "pvp_assist": PVP_ASSIST,
	"objective": OBJECTIVE, "npc_kill": NPC_KILL, "gm_grant": GM_GRANT, "loot": LOOT, "quest": QUEST,
	"vendor_sell": VENDOR_SELL, "trade_in": TRADE_IN, "mail_in": MAIL_IN, "craft_output": CRAFT_OUTPUT,
	"player_destroy": PLAYER_DESTROY, "consume": CONSUME, "gm_remove": GM_REMOVE, "vendor_buy": VENDOR_BUY,
	"repair": REPAIR, "respec": RESPEC, "trade_out": TRADE_OUT, "mail_out": MAIL_OUT,
	"craft_input": CRAFT_INPUT, "quartermaster": QUARTERMASTER, "market_fee": MARKET_FEE,
	"reversal": REVERSAL, "migration": MIGRATION,
}


## true si [param reason] está en el rango de las fuentes (1–63).
static func is_source(reason: int) -> bool:
	return reason >= SOURCE_MIN and reason <= SOURCE_MAX


## true si [param reason] está en el rango de los sumideros (64–127).
static func is_sink(reason: int) -> bool:
	return reason >= SINK_MIN and reason <= SINK_MAX


## true si [param reason] está en el rango de los internos (128–191).
static func is_internal(reason: int) -> bool:
	return reason >= INTERNAL_MIN and reason <= INTERNAL_MAX


## true si [param reason] es uno de los motivos de [constant CODES].
static func is_known(reason: int) -> bool:
	return CODES.values().has(reason)


## true si el signo de [param delta] cuadra con el rango de [param reason] (§5.2): positivo en una fuente,
## negativo en un sumidero y distinto de 0 en un interno. Un motivo fuera de los tres rangos nunca cuadra.
static func sign_matches(reason: int, delta: int) -> bool:
	if is_source(reason):
		return delta > 0
	if is_sink(reason):
		return delta < 0
	if is_internal(reason):
		return delta != 0
	return false


## true si un apunte de méritos con este motivo sube los puntos de reino (I9: los de juego, del 3 al 5).
static func gives_realm_points(reason: int) -> bool:
	return reason == PVP_KILL or reason == PVP_ASSIST or reason == OBJECTIVE


## Nombre en minúsculas de [param reason] ([code]starter_kit[/code]…), o vacío si no existe.
static func name_of(reason: int) -> String:
	for reason_name: String in CODES:
		if CODES[reason_name] == reason:
			return reason_name
	return ""


## Los tres rangos como en la sección [code]reasons[/code] de las reglas exportadas.
static func ranges() -> Dictionary:
	return {
		"source": {"min": SOURCE_MIN, "max": SOURCE_MAX},
		"sink": {"min": SINK_MIN, "max": SINK_MAX},
		"internal": {"min": INTERNAL_MIN, "max": INTERNAL_MAX},
	}
