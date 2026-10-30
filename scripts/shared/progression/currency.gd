class_name Currency
extends RefCounted
## Las monedas (docs/progresion.md §5.1, PRG-12): saldos [code]int64[/code] por personaje, nunca negativos ni
## por encima de [constant CAP]. Las reglas de los saldos están en [CurrencyRules]; la sección
## [code]currencies[/code] de las reglas exportadas ([ProgressionRulesExport]) sale de aquí.
## [br][br]
## Los puntos de reino no son una moneda: suben con los méritos de juego (I9,
## [method EconomyReason.gives_realm_points]). Compartido: sin reloj ni azar.

## Código de cada moneda (en la base de datos, en el libro y en el cable, este número).
enum Code { GOLD = 1, MERITS = 2 }

## Tope de cualquier saldo: mil millones. En GDScript, [code]^[/code] es XOR ([code]10^9[/code] valdría 3).
const CAP: int = 1_000_000_000
## Tamaño de un monedero indexado por código ([code]PackedInt64Array[/code]; el índice 0 no se usa).
const WALLET_SIZE: int = 3
## Id de texto de cada moneda (las reglas exportadas y la plataforma).
const IDS: Dictionary[int, String] = {Code.GOLD: "gold", Code.MERITS: "merits"}
## Nombre en español de cada moneda (interfaz y avisos).
const DISPLAY_NAMES: Dictionary[int, String] = {Code.GOLD: "Oro", Code.MERITS: "Méritos"}


## Los códigos de todas las monedas, en orden.
static func codes() -> Array[int]:
	var result: Array[int] = []
	for code: int in IDS:
		result.append(code)
	result.sort()
	return result


## true si [param code] es el código de una moneda.
static func is_valid(code: int) -> bool:
	return IDS.has(code)


## Id de texto de [param code] ([code]gold[/code], [code]merits[/code]), o vacío si no existe.
static func id_of(code: int) -> String:
	return IDS.get(code, "")


## Código de la moneda con id [param id], o 0 si no existe.
static func code_of(id: String) -> int:
	for code: int in IDS:
		if IDS[code] == id:
			return code
	return 0


## Tope del saldo de [param code] (el mismo para todas en la fase 5), o 0 si no existe.
static func cap_of(code: int) -> int:
	return CAP if is_valid(code) else 0


## Nombre en español de [param code], o vacío si no existe.
static func display_name(code: int) -> String:
	return DISPLAY_NAMES.get(code, "")
