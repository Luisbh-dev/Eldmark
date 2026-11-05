class_name WeaponDefinition
extends Resource
## An equippable weapon (docs/combat.md, section 2): its attacks, block, dodge and
## abilities (docs/abilities.md, section 2.1).

## Unique weapon identifier (the catalog assigns it a u16 ID in alphabetical order).
@export var id: StringName
## Light attack combo, in order (1 to 3 hits).
@export var light_combo: Array[AttackDefinition] = []
## Heavy attack (charged by holding the attack button).
@export var heavy_attack: AttackDefinition
## Total frontal cone of the block (degrees; server only).
@export var block_angle_deg: float = 120.0
## Fraction of frontal physical damage that the block stops (1.0 = all; server only).
@export var block_mitigation: float = 1.0
## Fraction of the run speed allowed while blocking.
@export var block_move_scale: float = 0.5
## Turn toward the camera (rad/s) while blocking.
@export var block_turn_rate: float = 8.0
## Stamina that each point of absorbed damage costs (server only).
@export var block_stamina_per_damage: float = 1.0
## The weapon's dodge.
@export var dodge: DodgeDefinition
## Abilities (0-3); the position is the slot (ABILITY_1-3).
@export var abilities: Array[AbilityDefinition] = []
## false: the weapon does not block (the bow); BLOCK does nothing.
@export var can_block: bool = true
