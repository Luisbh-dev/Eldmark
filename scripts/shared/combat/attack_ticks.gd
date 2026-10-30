class_name AttackTicks
extends RefCounted
## Un [AttackDefinition] ya convertido a ticks por [CombatCatalog] (docs/combate.md, sección 2).
## [br][br]
## Las ventanas son intervalos [code][desde, hasta)[/code] de ticks contados desde el
## [code]action_tick[/code] de la acción: anticipación [code][0, windup_ticks)[/code], golpe
## activo [code][windup_ticks, windup_ticks + active_ticks)[/code] y recuperación hasta
## [member total_ticks].

## ID u16 del catálogo (1..n por orden alfabético del nombre; 0 = ninguno). En el golpe sintetizado
## de una habilidad ([member AbilityTicks.hit]) es la fuente de la habilidad
## ([method CombatSource.make]).
var id: int = 0
## El [member AttackDefinition.id] original.
var name: StringName = &""
var heavy: bool = false
var windup_ticks: int = 0
var active_ticks: int = 0
var recovery_ticks: int = 0
## Duración total de la acción: anticipación + golpe activo + recuperación.
var total_ticks: int = 0
## Últimos ticks de la recuperación en los que una pulsación enlaza el siguiente ligero.
var combo_window_ticks: int = 0
## Tick (desde el inicio de la acción) a partir del cual se puede cancelar a esquiva.
var cancel_to_dodge_from_ticks: int = 0
var stamina_cost: int = 0
var lunge_speed: float = 0.0
var turn_rate: float = 0.0
var move_speed_scale: float = 1.0
## Solo fuertes: carga mínima y máxima en ticks desde el inicio de la acción.
var charge_min_ticks: int = 0
var charge_max_ticks: int = 0
var charge_move_scale: float = 1.0
var charge_turn_rate: float = 0.0
## ID del [ProjectileTicks] que sale en el primer tick activo (0 = ninguno).
var projectile_id: int = 0
## Velocidad de salida (m/s) y su multiplicador a carga máxima.
var projectile_speed_mps: float = 0.0
var charge_speed_scale: float = 1.0

# Solo servidor (no entran en la huella de predicción).
var shape: HitShape = null
var base_damage: int = 0
var damage_type: int = 0
var hyper_armor: bool = false
var unblockable: bool = false
var stagger_ticks: int = 0
var knockback_speed: float = 0.0
var charge_damage_scale: float = 1.0
var stun_ticks: int = 0
## ID del [StatusTicks] que aplica a quien golpea (0 = ninguno).
var on_hit_status_id: int = 0


## Primer tick (relativo a la acción) del golpe activo.
func active_from() -> int:
	return windup_ticks


## Primer tick (relativo a la acción) tras el golpe activo (exclusivo).
func active_to() -> int:
	return windup_ticks + active_ticks


## Primer tick (relativo a la acción) de la ventana de enlace del combo (hasta
## [member total_ticks]); igual a [member total_ticks] si no hay ventana.
func combo_window_from() -> int:
	return total_ticks - combo_window_ticks
