class_name StatusEffectDefinition
extends Resource
## Un efecto de estado con duración (docs/habilidades.md, sección 2.1): daño o curación en el tiempo,
## ralentizar, enraizar, más daño o menos mitigación. Tiempos en segundos; el catálogo los convierte
## a ticks.
## [br][br]
## Solo [member id], [member kind] y [member move_speed_scale] entran en la huella de predicción:
## ralentizar y enraizar viven en [CombatState] (las ranuras de efectos de movimiento, impuestas por
## el servidor) y cambian la velocidad que simulan cliente y servidor. El resto lo aplica el servidor.

## Clase de efecto.
enum Kind { DAMAGE_OVER_TIME, HEAL_OVER_TIME, SLOW, ROOT, DAMAGE_UP, MITIGATION_DOWN }
## Qué pasa al aplicar un efecto que ya está: renovar la duración, sumar una acumulación (hasta
## [member max_stacks]) o quedarse con el más fuerte.
enum Stacking { REFRESH, STACK, STRONGEST }

## Identificador único (el catálogo le asigna un ID u8 por orden alfabético).
@export var id: StringName
## [enum Kind].
@export var kind: int = Kind.DAMAGE_OVER_TIME
## Duración (s). Con pulsos, múltiplo exacto de [member pulse_every_s] en ticks.
@export var duration_s: float = 1.0
## [enum Stacking].
@export var stacking: int = Stacking.REFRESH
## Acumulaciones máximas (1-255).
@export var max_stacks: int = 1
## Predicho: escala de la velocidad en SLOW (0 < x <= 1, o > 1 si acelera); 0 en ROOT.
@export var move_speed_scale: float = 1.0
## Solo servidor: un pulso cada tantos segundos (daño o curación en el tiempo).
@export var pulse_every_s: float = 1.0
## Solo servidor: daño o curación de cada pulso por acumulación (0 = sin pulsos).
@export var pulse_amount: int = 0
## Solo servidor: tipo de daño de los pulsos ([enum DamageFormula.DamageType]).
@export var damage_type: int = 0
## Solo servidor: fracción de DAMAGE_UP (+) o de MITIGATION_DOWN (−).
@export var magnitude: float = 0.0
