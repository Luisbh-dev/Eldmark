class_name AbilityTicks
extends RefCounted
## Una [AbilityDefinition] ya convertida a ticks por [CombatCatalog] (docs/habilidades.md, sección
## 2.2).
## [br][br]
## Las ventanas son intervalos [code][desde, hasta)[/code] de ticks contados desde el
## [code]action_tick[/code] de la acción: lanzamiento [code][0, cast_ticks)[/code], activo (o
## canalización) [code][cast_ticks, cast_ticks + active_ticks)[/code] y recuperación hasta
## [member total_ticks]. El compromiso (la reutilización, las cargas, el proyectil y el efecto propio)
## cae en el tick [code]cast_ticks[/code].
## [br][br]
## [member hit] es un [AttackTicks] [b]sintetizado[/b] con las ventanas de la habilidad (anticipación =
## lanzamiento) y sus campos de solo servidor: el resolutor prueba igual un ataque que el golpe de
## una habilidad. Su [member AttackTicks.id] es la fuente de la habilidad
## ([method CombatSource.make] con [constant CombatSource.Kind.ABILITY]) y no está en la tabla de
## ataques.

## Ticks en NONE, como poco, entre dos usos que el byte de acción no distingue (docs/habilidades.md, sección
## 5.5): dos de la misma ranura, o dos consumibles, salen con el mismo byte (ABILITY, fase 0 y la misma ranura),
## y un remoto ve el registro cada [constant NetProtocol.SNAPSHOT_INTERVAL_TICKS] ticks (o menos a menudo, con
## el reparto por prioridad del snapshot). Tres intervalos: la validación de [CombatCatalog] lo exige a las
## reutilizaciones y [method ActionMachine.impose_interrupt] lo deja como margen tras cortar un lanzamiento
## (revisión de H5).
const REARM_TICKS: int = 6

## ID u16 del catálogo (1..n por orden alfabético del nombre; 0 = ninguna).
var id: int = 0
## El [member AbilityDefinition.id] original.
var name: StringName = &""
## Ranura del arma (0-2), o -1 si es un consumible o no la lleva ningún arma.
var slot: int = -1
## Arma que la lleva (0 si es un consumible o no la lleva ninguna).
var weapon_id: int = 0
## Índice en [member CombatRules.consumables] (0-1), o -1 si no es un consumible.
var consumable_index: int = -1

# Predichos (entran en la huella).
var cast_ticks: int = 0
var active_ticks: int = 0
var recovery_ticks: int = 0
## Lanzamiento + activo + recuperación.
var total_ticks: int = 0
## Reutilización (0 en los consumibles: usan [member CombatTables.consumable_cooldown_ticks]).
var cooldown_ticks: int = 0
var channel: bool = false
var channel_hold: bool = true
var channel_breaks_on_move: bool = false
## Desde qué tick (relativo a la acción) se puede cancelar a esquiva y a ataque (los -1 del dato ya
## son el inicio de la recuperación).
var cancel_to_dodge_from_ticks: int = 0
var cancel_to_attack_from_ticks: int = 0
var move_speed_scale: float = 1.0
var turn_rate: float = 0.0
var lunge_speed: float = 0.0
var dash_distance_m: float = 0.0
## Ventana del avance [desde, hasta) relativa a la acción.
var dash_from_ticks: int = 0
var dash_to_ticks: int = 0
## 0 hacia look_yaw, 1 hacia atrás, 2 según el movimiento.
var dash_direction: int = 0
## Velocidad (m/s) del avance en cada tick de su ventana (índice = tick - action_tick - dash_from),
## en f32 y normalizada para que la suma de [code]v / 60[/code] sea [member dash_distance_m].
var dash_speeds: PackedFloat32Array = PackedFloat32Array()
var usable_in_air: bool = false
var stamina_restore: int = 0
var blocks: bool = false
## ID del [ProjectileTicks] (0 = sin proyectil).
var projectile_id: int = 0
var projectile_count: int = 1
var projectile_spread_deg: float = 0.0
var projectile_speed_mps: float = 0.0

# Solo servidor (no entran en la huella).
## El golpe sintetizado (siempre existe; sin forma no hay golpe cuerpo a cuerpo).
var hit: AttackTicks = null
## ID del [StatusTicks] propio al comprometer (0 = ninguno) y curación propia.
var self_status_id: int = 0
var self_heal: int = 0
var interrupt_on_damage: bool = false
var wall_half_extents: Vector3 = Vector3.ZERO
var wall_forward_m: float = 0.7


## true si es uno de los consumibles de [member CombatRules.consumables].
func is_consumable() -> bool:
	return consumable_index >= 0


## Primer tick (relativo a la acción) del activo: el del compromiso.
func active_from() -> int:
	return cast_ticks


## Primer tick (relativo a la acción) tras el activo (exclusivo).
func active_to() -> int:
	return cast_ticks + active_ticks


## Velocidad impuesta (m/s) del avance en el tick [param relative_tick] de la acción (0 fuera de
## su ventana).
func dash_speed_at(relative_tick: int) -> float:
	var index: int = relative_tick - dash_from_ticks
	if index < 0 or index >= dash_speeds.size():
		return 0.0
	return dash_speeds[index]


## true si [param relative_tick] cae en la ventana del avance.
func is_dashing(relative_tick: int) -> bool:
	return dash_distance_m > 0.0 and relative_tick >= dash_from_ticks \
			and relative_tick < dash_to_ticks
