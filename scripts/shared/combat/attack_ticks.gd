class_name AttackTicks
extends RefCounted
## An [AttackDefinition] already converted to ticks by [CombatCatalog] (docs/combate.md, section 2).
## [br][br]
## The windows are [code][from, to)[/code] intervals of ticks counted from the action's
## [code]action_tick[/code]: windup [code][0, windup_ticks)[/code], active
## hit [code][windup_ticks, windup_ticks + active_ticks)[/code] and recovery up to
## [member total_ticks].

## Catalog u16 ID (1..n in alphabetical order of the name; 0 = none). In an ability's synthesized hit
## ([member AbilityTicks.hit]) it is the ability's source
## ([method CombatSource.make]).
var id: int = 0
## The original [member AttackDefinition.id].
var name: StringName = &""
var heavy: bool = false
var windup_ticks: int = 0
var active_ticks: int = 0
var recovery_ticks: int = 0
## Total duration of the action: windup + active hit + recovery.
var total_ticks: int = 0
## Last ticks of the recovery in which a press links the next light attack.
var combo_window_ticks: int = 0
## Tick (since the start of the action) from which it can be canceled into a dodge.
var cancel_to_dodge_from_ticks: int = 0
var stamina_cost: int = 0
var lunge_speed: float = 0.0
var turn_rate: float = 0.0
var move_speed_scale: float = 1.0
## Heavy attacks only: minimum and maximum charge in ticks since the start of the action.
var charge_min_ticks: int = 0
var charge_max_ticks: int = 0
var charge_move_scale: float = 1.0
var charge_turn_rate: float = 0.0
## ID of the [ProjectileTicks] released on the first active tick (0 = none).
var projectile_id: int = 0
## Launch speed (m/s) and its multiplier at maximum charge.
var projectile_speed_mps: float = 0.0
var charge_speed_scale: float = 1.0

# Server only (not part of the prediction fingerprint).
var shape: HitShape = null
var base_damage: int = 0
var damage_type: int = 0
var hyper_armor: bool = false
var unblockable: bool = false
var stagger_ticks: int = 0
var knockback_speed: float = 0.0
var charge_damage_scale: float = 1.0
var stun_ticks: int = 0
## ID of the [StatusTicks] it applies to whoever is hit (0 = none).
var on_hit_status_id: int = 0


## First tick (relative to the action) of the active hit.
func active_from() -> int:
	return windup_ticks


## First tick (relative to the action) after the active hit (exclusive).
func active_to() -> int:
	return windup_ticks + active_ticks


## First tick (relative to the action) of the combo link window (up to
## [member total_ticks]); equal to [member total_ticks] if there is no window.
func combo_window_from() -> int:
	return total_ticks - combo_window_ticks
