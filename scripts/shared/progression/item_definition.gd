class_name ItemDefinition
extends Resource
## What an item is (docs/progression.md §2.1, PRG-02): design data in
## [code]data/items/<category>/<id>.tres[/code], with a stable [member id] that the database
## stores. What someone owns is an [ItemInstance]; [ItemDatabase] indexes them and checks their
## consistency.
## [br][br]
## It has no property of type [Texture2D], [PackedScene] or [Mesh]: the icon and scenes go as text
## paths, which only the client reads (the server preset trims [code]assets/[/code] and the server
## must never try to load them). Shared: no clock, no randomness.

## Categories (in the database and in the exported rules, this number).
enum Category { WEAPON = 1, ARMOR = 2, CONSUMABLE = 3, MATERIAL = 4, QUEST = 5, MISC = 6 }
## Equipment slot. [code]WEAPON[/code] is valid for both weapon slots.
enum EquipSlot { NONE = 0, WEAPON = 1, HEAD = 2, CHEST = 3, HANDS = 4, LEGS = 5, FEET = 6 }
## When it becomes bound to the character.
enum BindRule { NONE = 0, ON_EQUIP = 1, ON_PICKUP = 2 }

## Format of the id: [code][a-z0-9_][/code], 3 to 32 characters.
const ID_PATTERN: String = "^[a-z0-9_]{3,32}$"
## Cap of a stack.
const MAX_STACK: int = 999

## Stable identifier: never reused or renamed (the database stores it).
@export var id: StringName
## Name in Spanish (non-empty).
@export var display_name: String = ""
## Description in Spanish.
@export_multiline var description: String = ""
@export var category: Category = Category.MISC
@export var equip_slot: EquipSlot = EquipSlot.NONE
## WEAPON: the [code]id[/code] of the weapon in [CombatCatalog]; CONSUMABLE: that of the consumable
## ([code]potion_health[/code], [code]potion_stamina[/code]); ARMOR: the PRG-06 armor (no content in
## phase 5); the rest, empty.
@export var ref_id: StringName
## 1 = not stackable; cap [constant MAX_STACK]. Equippables and those with durability, 1.
@export_range(1, 999) var max_stack: int = 1
## Level to equip or use it (1 up to the cap of [LevelCurve]).
@export_range(1, 40) var required_level: int = 1
## Value in gold (≥ 0): the basis of phase 6 prices.
@export var base_value: int = 0
@export var bind_rule: BindRule = BindRule.NONE
## false: the player cannot destroy it.
@export var destroyable: bool = true
## The instance carries durability (per thousand, 0–1000).
@export var has_durability: bool = false
## Starter item (docs/progression.md §2.5).
@export var starter: bool = false
## Total to which the camp replenishes this definition (§4.4); 0 = not replenished. Fits in one
## stack.
@export_range(0, 999) var camp_refill: int = 0
## Icon ([code]res://assets/icons/items/…[/code]); client-only. Empty: the slot draws the short
## name in the category's color.
@export var icon_path: String = ""
## Scene per body (PRG-05); client-only and armor-only. Empty in phase 5: weapons are shown by
## their [CombatCatalog] id.
@export var visual_paths: PackedStringArray = PackedStringArray()


## Can be put in equipment.
func is_equipable() -> bool:
	return equip_slot != EquipSlot.NONE
