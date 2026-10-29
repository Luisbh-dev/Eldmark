class_name DodgeTicks
extends RefCounted
## Una [DodgeDefinition] ya convertida a ticks por [CombatCatalog].
## [br][br]
## [member speeds] es la curva horneada: la velocidad (m/s) que se impone en cada tick de la
## esquiva (índice = tick - action_tick), redondeada a f32 y normalizada para que la suma de
## [code]speeds[i] / 60[/code] sea [member distance_m].

var duration_ticks: int = 0
## Ticks [desde, hasta) relativos al inicio de la esquiva en los que no se recibe daño.
var invulnerable_from_ticks: int = 0
var invulnerable_to_ticks: int = 0
var distance_m: float = 0.0
var stamina_cost: int = 0
## Tick (desde el inicio de la esquiva) a partir del cual se puede cancelar a ataque.
var cancel_to_attack_from_ticks: int = 0
var speeds: PackedFloat32Array = PackedFloat32Array()


## Velocidad impuesta (m/s) en el tick [param relative_tick] de la esquiva.
func speed_at(relative_tick: int) -> float:
	if relative_tick < 0 or speeds.is_empty():
		return 0.0
	return speeds[mini(relative_tick, speeds.size() - 1)]
