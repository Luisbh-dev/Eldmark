class_name EquipmentTemplate
extends Resource
## An equipment template (PRG-07; docs/abilities.md, section 2.1): the weapons and consumable
## charges a character spawns with. The server imposes it on spawn, so it is not part of
## the prediction fingerprint.

## Unique identifier (the catalog assigns it a u8 ID in alphabetical order).
@export var id: StringName
## false: only for tests and NPCs (a player cannot choose it).
@export var selectable: bool = true
## One or two weapons, in slot order (the first is the one active on spawn).
@export var weapons: Array[WeaponDefinition] = []
## Charges of each consumable in [member CombatRules.consumables] (two values, 0-15 each).
@export var consumable_charges: PackedInt32Array = PackedInt32Array([3, 2])
