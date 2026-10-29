class_name WeaponTicks
extends RefCounted
## Una [WeaponDefinition] ya resuelta por [CombatCatalog]: ID u16, los IDs de sus ataques y de sus
## habilidades y su esquiva en ticks.

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
## IDs de las habilidades de las ranuras 0-2 (siempre 3 valores; 0 = ranura vacía).
var ability_ids: PackedInt32Array = PackedInt32Array([0, 0, 0])
## false: BLOCK no hace nada.
var can_block: bool = true

# Solo servidor (no entran en la huella de predicción).
var block_angle_deg: float = 120.0
var block_mitigation: float = 1.0
var block_stamina_per_damage: float = 1.0


## ID de la habilidad de la ranura [param slot] (0-2), o 0 si está vacía o fuera de rango.
func ability_id(slot: int) -> int:
	if slot < 0 or slot >= ability_ids.size():
		return 0
	return ability_ids[slot]


## Posición de [param attack_id] en el combo ligero (0..n-1), o -1 si no es un ligero del arma.
func light_index(attack_id: int) -> int:
	return light_ids.find(attack_id)
