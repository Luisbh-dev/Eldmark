class_name CombatTiming
extends RefCounted
## Plazos del combate que solo usa el servidor, ya en ticks (docs/combate.md, sección 2). Salen de
## [CombatRules] (segundos en los [code].tres[/code]) con [code]roundi(s · 60)[/code], igual que el resto
## del catálogo.
## [br][br]
## Las pruebas acortan los plazos largos (reaparición, por ejemplo) cambiando estos campos en el
## [CombatTiming] que expone [method ZoneServer.get_combat_timing]; los valores por defecto son los
## de los datos.

## Segundos tras la muerte a los que la reaparición se hace sola si el jugador no la pide.
const AUTO_RESPAWN_S: float = 30.0
## Segundos sin recibir daño tras los que el maniquí de entrenamiento se cura del todo.
const DUMMY_HEAL_S: float = 5.0
## Ticks de adelanto con los que se admite un RESPAWN_REQUEST antes de [member Combatant.respawn_tick]:
## el cliente cuenta el tick del servidor por delante (lleva la antelación de sus entradas), así que
## su botón puede llegar un par de ticks antes de que el servidor lo permita. La petición queda
## pendiente hasta que llega el momento.
const RESPAWN_REQUEST_SLACK_TICKS: int = 12

## Ticks "en combate" tras dar o recibir daño.
var in_combat: int = 600
## Ticks desde la muerte hasta que se puede reaparecer.
var respawn: int = 600
## Ticks tras la muerte en los que la reaparición se hace sola (en el primer punto del reino).
var auto_respawn: int = 1800
## Ticks de protección tras reaparecer.
var protection: int = 180
## Ventana (ticks) en la que se cuentan los controles encadenados y ticks de inmunidad tras la cadena.
var cc_window: int = 180
var cc_immunity: int = 120
## Ticks de tambaleo del atacante parado y de aturdimiento tras una rotura de guardia.
var parry_stagger: int = 36
var guard_break_stun: int = 60
## Ticks sin daño tras los que se cura el maniquí.
var dummy_heal: int = 300


## Los plazos de [param rules] en ticks.
static func from_rules(rules: CombatRules) -> CombatTiming:
	var timing := CombatTiming.new()
	timing.in_combat = seconds_to_ticks(rules.in_combat_s)
	timing.respawn = seconds_to_ticks(rules.respawn_s)
	timing.auto_respawn = maxi(seconds_to_ticks(AUTO_RESPAWN_S), timing.respawn)
	timing.protection = seconds_to_ticks(rules.respawn_protection_s)
	timing.cc_window = seconds_to_ticks(rules.cc_chain_window_s)
	timing.cc_immunity = seconds_to_ticks(rules.cc_immunity_s)
	timing.parry_stagger = seconds_to_ticks(rules.parry_stagger_s)
	timing.guard_break_stun = seconds_to_ticks(rules.guard_break_stun_s)
	timing.dummy_heal = seconds_to_ticks(DUMMY_HEAL_S)
	return timing


## Segundos a ticks de simulación ([constant CombatCatalog.TICK_RATE] por segundo), redondeando.
static func seconds_to_ticks(seconds: float) -> int:
	return roundi(seconds * float(CombatCatalog.TICK_RATE))
