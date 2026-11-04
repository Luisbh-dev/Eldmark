class_name CombatRules
extends Resource
## General combat rules (docs/combate.md, section 2), in
## [code]data/combat/combat_rules.tres[/code].
## [br][br]
## The "predicted" fields go into [method CombatCatalog.prediction_hash] because they change what
## client and server simulate; the rest are read only by the server.

# --- Predicted --------------------------------------------------------------------------------

## Maximum stamina (0-65535: it travels in a u16).
@export var stamina_max: int = 1000
## Stamina regenerated each tick (180/s with 3).
@export var stamina_regen_per_tick: int = 3
## Delay (s) after spending stamina before regenerating again.
@export var stamina_regen_delay_s: float = 0.6
## Regeneration per tick while exhausted.
@export var exhausted_regen_per_tick: int = 1
## Exhaustion ends once stamina exceeds this value.
@export var exhausted_exit_threshold: int = 300
## Ticks of PRIMARY held to go from a light attack to a heavy attack charge.
@export var hold_to_heavy_ticks: int = 8
## Ticks an unexecuted press waits in the buffer (at most 15: it takes 4 bits).
@export var input_buffer_ticks: int = 8
## Ticks of the parry window when block is pressed.
@export var parry_window_ticks: int = 6
## Ticks until another parry window can be opened.
@export var parry_cooldown_ticks: int = 30
## Duration (s) of the weapon swap (docs/habilidades.md, section 3).
@export var swap_s: float = 0.4
## Fraction of the run speed allowed during the weapon swap.
@export var swap_move_scale: float = 0.8
## Fraction of the run speed of a knocked down character (they crawl).
@export var downed_move_scale: float = 0.15
## Turn toward the camera (rad/s) of a knocked down character.
@export var downed_turn_rate: float = 3.0
## Duration (s) of reviving a knocked down ally.
@export var revive_s: float = 3.0
## Duration (s) of executing a knocked down enemy.
@export var execute_s: float = 1.0
## The two consumables (potions), in button order: CONSUMABLE_1 (R) and CONSUMABLE_2 (T). With
## none (test catalogs) there are no potions.
@export var consumables: Array[AbilityDefinition] = []
## Shared cooldown (s) of the consumables.
@export var consumable_cooldown_s: float = 20.0
## Canonical aiming (docs/habilidades.md, section 4.4): height of the camera pivot above the
## feet, lateral shoulder offset and vertical camera offset (the [code]h_offset[/code] and
## [code]v_offset[/code] of [code]camera_rig.tscn[/code]).
@export var aim_pivot_height: float = 1.6
@export var aim_shoulder_offset: float = 0.6
@export var aim_camera_v_offset: float = 0.1
## Range (m) of the crosshair ray when it hits nothing.
@export var aim_range_m: float = 150.0
## Angle (degrees) within which the arrow converges to the depth of the hostile closest to the
## crosshair.
@export var aim_converge_deg: float = 12.0
## Height (m) above the feet from which projectiles are released (the chest).
@export var muzzle_height: float = 1.4

# --- Server only ------------------------------------------------------------------------------

## Maximum health.
@export var health_max: int = 1000
## Health regeneration per second out of combat.
@export var health_regen_per_s: int = 20
## Seconds "in combat" after dealing or taking damage.
@export var in_combat_s: float = 10.0
## Seconds until respawning is possible.
@export var respawn_s: float = 10.0
## Seconds of protection after respawning.
@export var respawn_protection_s: float = 3.0
## Window (s) in which chained controls are counted.
@export var cc_chain_window_s: float = 3.0
## Immunity (s) to controls after chaining too many.
@export var cc_immunity_s: float = 2.0
## Landing speed (m/s) from which there is fall damage.
@export var fall_damage_threshold: float = 15.0
## Damage per m/s above the threshold.
@export var fall_damage_per_mps: int = 70
## Stagger (s) suffered by the attacker when parried.
@export var parry_stagger_s: float = 0.6
## Stun (s) after a guard break.
@export var guard_break_stun_s: float = 1.0
## Angle relative to the victim's yaw from which a hit counts as from behind.
@export var backstab_angle_deg: float = 120.0
## Damage multiplier for hits from behind.
@export var crit_multiplier: float = 1.5
## Damage multipliers against structures (a fort's gate, docs/fuerte.md, section 3.3),
## by damage type: slashing, piercing, blunt and elemental. Used only by the server.
@export var structure_slash_multiplier: float = 0.35
@export var structure_pierce_multiplier: float = 0.2
@export var structure_blunt_multiplier: float = 1.0
@export var structure_elemental_multiplier: float = 0.6
## Downed health (docs/habilidades.md, section 4.5).
@export var downed_health: int = 400
## Seconds a knocked down character takes to bleed out.
@export var downed_s: float = 20.0
## Health with which a knocked down character returns when revived.
@export var revived_health: int = 300
## Horizontal distance (m) at which reviving or executing begins.
@export var interact_range_m: float = 2.0
## Distance (m) at which reviving or executing is cut off.
@export var interact_keep_range_m: float = 2.5
## Total cone (degrees) of the block of a blocking channel (shield wall).
@export var ability_block_angle_deg: float = 180.0
## Stamina per point of damage that this block absorbs.
@export var ability_block_stamina_per_damage: float = 0.6
## Maximum live projectiles per shooter and per zone (when exceeded, the oldest goes).
@export var max_projectiles_per_shooter: int = 8
@export var max_projectiles_per_zone: int = 64
## Template a player who has not chosen spawns with (the squire).
@export var default_template: EquipmentTemplate


## Damage multiplier of type [param damage_type] ([enum DamageFormula.DamageType]) against
## a structure. 1 for an unknown type.
func structure_multiplier(damage_type: int) -> float:
	match damage_type:
		DamageFormula.DamageType.SLASH:
			return structure_slash_multiplier
		DamageFormula.DamageType.PIERCE:
			return structure_pierce_multiplier
		DamageFormula.DamageType.BLUNT:
			return structure_blunt_multiplier
		DamageFormula.DamageType.ELEMENTAL:
			return structure_elemental_multiplier
	return 1.0
