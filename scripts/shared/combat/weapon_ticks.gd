class_name WeaponTicks
extends RefCounted
## A [WeaponDefinition] already resolved by [CombatCatalog]: u16 ID, the IDs of its attacks and
## abilities and its dodge in ticks.

## Catalog u16 ID (1..n in alphabetical order of the name; 0 = none).
var id: int = 0
## The original [member WeaponDefinition.id].
var name: StringName = &""
## IDs of the light combo hits, in order.
var light_ids: PackedInt32Array = PackedInt32Array()
var heavy_id: int = 0
var block_move_scale: float = 1.0
var block_turn_rate: float = 0.0
var dodge: DodgeTicks = null
## IDs of the abilities in slots 0-2 (always 3 values; 0 = empty slot).
var ability_ids: PackedInt32Array = PackedInt32Array([0, 0, 0])
## false: BLOCK does nothing.
var can_block: bool = true

# Server only (not part of the prediction fingerprint).
var block_angle_deg: float = 120.0
var block_mitigation: float = 1.0
var block_stamina_per_damage: float = 1.0


## ID of the ability in slot [param slot] (0-2), or 0 if it is empty or out of range.
func ability_id(slot: int) -> int:
	if slot < 0 or slot >= ability_ids.size():
		return 0
	return ability_ids[slot]


## Position of [param attack_id] in the light combo (0..n-1), or -1 if it is not one of the weapon's light attacks.
func light_index(attack_id: int) -> int:
	return light_ids.find(attack_id)
