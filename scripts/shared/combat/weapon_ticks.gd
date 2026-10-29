class_name WeaponTicks
extends RefCounted
## Una [WeaponDefinition] ya resuelta por [CombatCatalog]: ID u16, los IDs de sus ataques y su
## esquiva en ticks.

## ID u16 del catálogo (1..n por orden alfabético del nombre; 0 = ninguno).
var id: int = 0
## El [member WeaponDefinition.id] original.
var name: StringName = &""
## IDs de los golpes del combo ligero, en orden.
var light_ids: PackedInt32Array = PackedInt32Array()
var heavy_id: int = 0
var block_move_scale: float = 1.0
var block_turn_rate: float = 0.0
var dodge: DodgeTicks = null

# Solo servidor (no entran en la huella de predicción).
var block_angle_deg: float = 120.0
var block_mitigation: float = 1.0
var block_stamina_per_damage: float = 1.0


## Posición de [param attack_id] en el combo ligero (0..n-1), o -1 si no es un ligero del arma.
func light_index(attack_id: int) -> int:
	return light_ids.find(attack_id)
