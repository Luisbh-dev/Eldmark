class_name CombatTables
extends RefCounted
## Everything [CombatCatalog] resolves from a set of combat resources: the rules, the
## attacks, weapons, abilities, effects, projectiles and templates already converted
## to ticks, their IDs, the problems found and the fingerprint of the predicted part.

## Combat rules (there are always some: the defaults if missing).
var rules: CombatRules = null
## Ticks of delay of stamina regeneration after spending (from the rules).
var regen_delay_ticks: int = 0
## Durations from the rules in ticks (docs/abilities.md, section 2.1).
var swap_ticks: int = 0
var revive_ticks: int = 0
var execute_ticks: int = 0
var consumable_cooldown_ticks: int = 0
var downed_ticks: int = 0
## Attacks by ID: ID [code]n[/code] is at index [code]n - 1[/code].
var attacks: Array[AttackTicks] = []
## Weapons by ID (index [code]id - 1[/code]).
var weapons: Array[WeaponTicks] = []
## Abilities and consumables by ID (index [code]id - 1[/code]).
var abilities: Array[AbilityTicks] = []
## Status effects by ID (index [code]id - 1[/code]; they fit in u8).
var statuses: Array[StatusTicks] = []
## Projectiles by ID (index [code]id - 1[/code]).
var projectiles: Array[ProjectileTicks] = []
## Equipment templates by ID (index [code]id - 1[/code]; they fit in u8).
var templates: Array[EquipmentTemplate] = []
## Weapons (IDs, in slot order) and packed charges ([member CombatState.consumable_charges])
## of each template, at the same index as [member templates].
var template_weapon_ids: Array[PackedInt32Array] = []
var template_charges: PackedInt32Array = PackedInt32Array()
var attack_ids: Dictionary[StringName, int] = {}
var weapon_ids: Dictionary[StringName, int] = {}
var ability_ids: Dictionary[StringName, int] = {}
var status_ids: Dictionary[StringName, int] = {}
var projectile_ids: Dictionary[StringName, int] = {}
var template_ids: Dictionary[StringName, int] = {}
## IDs of the abilities in [member CombatRules.consumables] in button order (always 2 values;
## 0 if there is none).
var consumable_ids: PackedInt32Array = PackedInt32Array([0, 0])
## ID of [member CombatRules.default_template] (0 if there is none).
var default_template_id: int = 0
## Problems found while loading and validating (empty if all is well).
var errors: PackedStringArray = PackedStringArray()
## Fingerprint of the predicted part (u32).
var prediction_hash: int = 0
## Query counters of [method weapon] and [method ability]: deterministic, only for the
## tests that check that the simulation's fast path looks nothing up in the catalog.
var weapon_lookups: int = 0
var ability_lookups: int = 0


## The attack with that ID, or null if it does not exist.
func attack(id: int) -> AttackTicks:
	if id < 1 or id > attacks.size():
		return null
	return attacks[id - 1]


## The weapon with that ID, or null if it does not exist.
func weapon(id: int) -> WeaponTicks:
	weapon_lookups += 1
	if id < 1 or id > weapons.size():
		return null
	return weapons[id - 1]


## The ability (or consumable) with that ID, or null if it does not exist.
func ability(id: int) -> AbilityTicks:
	ability_lookups += 1
	if id < 1 or id > abilities.size():
		return null
	return abilities[id - 1]


## The status effect with that ID, or null if it does not exist.
func status(id: int) -> StatusTicks:
	if id < 1 or id > statuses.size():
		return null
	return statuses[id - 1]


## The projectile with that ID, or null if it does not exist.
func projectile(id: int) -> ProjectileTicks:
	if id < 1 or id > projectiles.size():
		return null
	return projectiles[id - 1]


## The template with that ID, or null if it does not exist.
func template(id: int) -> EquipmentTemplate:
	if id < 1 or id > templates.size():
		return null
	return templates[id - 1]


## IDs of the weapons of template [param id] in slot order (empty if it does not exist).
func template_weapons(id: int) -> PackedInt32Array:
	if id < 1 or id > template_weapon_ids.size():
		return PackedInt32Array()
	return template_weapon_ids[id - 1]


## Packed charges of template [param id] (0 if it does not exist).
func template_charges_of(id: int) -> int:
	if id < 1 or id > template_charges.size():
		return 0
	return template_charges[id - 1]


## true if there were no problems while loading.
func is_valid() -> bool:
	return errors.is_empty()
