class_name ProgressionRules
extends RefCounted
## Reglas puras de la experiencia y los niveles (docs/progresion.md §6.3, PRG-13), compartidas por la
## zona (que reparte la XP) y la interfaz (que la muestra). Sin estado, reloj ni azar.
## [br][br]
## Un solo aporte puede subir varios niveles; en el tope no se acumula XP (I8): se aplica 0 y el
## total se queda en [code]curve.total_to(level_cap)[/code]. El nivel no cambia la simulación en la
## fase 5 (§0): solo se ve y desbloquea objetos por [code]required_level[/code].

## XP por cada mérito de PvP o de objetivo (§6.2).
const XP_PER_MERIT: int = 10


## Resultado de [method ProgressionRules.add_xp].
class XpResult:
	## Nivel tras el aporte.
	var level: int = 1
	## XP total tras el aporte.
	var xp_total: int = 0
	## Niveles ganados con este aporte (0 si no sube).
	var levels_gained: int = 0
	## XP que se ha sumado de verdad: menos que lo pedido si llega al tope, 0 en el tope.
	var applied: int = 0


## Suma [param amount] de XP a un personaje de nivel [param level] con [param xp_total] y devuelve el
## nivel, el total, los niveles ganados y lo aplicado. Un [param amount] de 0 o negativo no aplica nada
## (la XP solo baja con una operación GM o REVERSAL, que la resta y recalcula el nivel con
## [method LevelCurve.level_for]). Un total por encima del tope se lleva al tope (I8).
static func add_xp(curve: LevelCurve, level: int, xp_total: int, amount: int) -> XpResult:
	var result := XpResult.new()
	var cap_total: int = curve.total_to(curve.level_cap)
	var current: int = clampi(xp_total, 0, cap_total)
	result.applied = clampi(amount, 0, cap_total - current)
	result.xp_total = current + result.applied
	result.level = curve.level_for(result.xp_total)
	result.levels_gained = maxi(result.level - level, 0)
	return result


## Puntos de atributo sin gastar (§6.3): [code](level − 1) · attribute_points_per_level − spent[/code],
## nunca menos de 0. No se guardan: se derivan, así PRG-17 puede cambiar el reparto sin migrar.
static func attribute_points(curve: LevelCurve, level: int, spent: int) -> int:
	var earned: int = (clampi(level, 1, curve.level_cap) - 1) * curve.attribute_points_per_level
	return maxi(earned - spent, 0)
