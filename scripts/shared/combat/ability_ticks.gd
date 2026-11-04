class_name AbilityTicks
extends RefCounted
## An [AbilityDefinition] already converted to ticks by [CombatCatalog] (docs/abilities.md, section
## 2.2).
## [br][br]
## The windows are [code][from, to)[/code] intervals of ticks counted from the action's
## [code]action_tick[/code]: cast [code][0, cast_ticks)[/code], active (or
## channel) [code][cast_ticks, cast_ticks + active_ticks)[/code] and recovery up to
## [member total_ticks]. The commit (the cooldown, the charges, the projectile and the self effect)
## falls on tick [code]cast_ticks[/code].
## [br][br]
## [member hit] is a [b]synthesized[/b] [AttackTicks] with the ability's windows (windup =
## cast) and its server-only fields: the resolver tests an attack and an ability's hit
## the same way. Its [member AttackTicks.id] is the ability's source
## ([method CombatSource.make] with [constant CombatSource.Kind.ABILITY]) and is not in the attack
## table.

## Ticks in NONE, at minimum, between two uses that the action byte cannot tell apart (docs/abilities.md, section
## 5.5): two of the same slot, or two consumables, come out with the same byte (ABILITY, phase 0 and the same slot),
## and a remote sees the record every [constant NetProtocol.SNAPSHOT_INTERVAL_TICKS] ticks (or less often, with
## the snapshot's priority-based distribution). Three intervals: the [CombatCatalog] validation requires it of
## cooldowns and [method ActionMachine.impose_interrupt] leaves it as a margin after cutting a cast
## (H5 review).
const REARM_TICKS: int = 6

## Catalog u16 ID (1..n in alphabetical order of the name; 0 = none).
var id: int = 0
## The original [member AbilityDefinition.id].
var name: StringName = &""
## Weapon slot (0-2), or -1 if it is a consumable or no weapon carries it.
var slot: int = -1
## Weapon that carries it (0 if it is a consumable or none carries it).
var weapon_id: int = 0
## Index into [member CombatRules.consumables] (0-1), or -1 if it is not a consumable.
var consumable_index: int = -1

# Predicted (part of the fingerprint).
var cast_ticks: int = 0
var active_ticks: int = 0
var recovery_ticks: int = 0
## Cast + active + recovery.
var total_ticks: int = 0
## Cooldown (0 for consumables: they use [member CombatTables.consumable_cooldown_ticks]).
var cooldown_ticks: int = 0
var channel: bool = false
var channel_hold: bool = true
var channel_breaks_on_move: bool = false
## From which tick (relative to the action) it can be canceled into a dodge and into an attack (the -1s in the data
## are already the start of recovery).
var cancel_to_dodge_from_ticks: int = 0
var cancel_to_attack_from_ticks: int = 0
var move_speed_scale: float = 1.0
var turn_rate: float = 0.0
var lunge_speed: float = 0.0
var dash_distance_m: float = 0.0
## Advance window [from, to) relative to the action.
var dash_from_ticks: int = 0
var dash_to_ticks: int = 0
## 0 toward look_yaw, 1 backward, 2 following the movement.
var dash_direction: int = 0
## Speed (m/s) of the advance on each tick of its window (index = tick - action_tick - dash_from),
## in f32 and normalized so that the sum of [code]v / 60[/code] is [member dash_distance_m].
var dash_speeds: PackedFloat32Array = PackedFloat32Array()
var usable_in_air: bool = false
var stamina_restore: int = 0
var blocks: bool = false
## ID of the [ProjectileTicks] (0 = no projectile).
var projectile_id: int = 0
var projectile_count: int = 1
var projectile_spread_deg: float = 0.0
var projectile_speed_mps: float = 0.0

# Server only (not part of the fingerprint).
## The synthesized hit (it always exists; with no shape there is no melee hit).
var hit: AttackTicks = null
## ID of the self [StatusTicks] on commit (0 = none) and self healing.
var self_status_id: int = 0
var self_heal: int = 0
var interrupt_on_damage: bool = false
var wall_half_extents: Vector3 = Vector3.ZERO
var wall_forward_m: float = 0.7


## true if it is one of the consumables in [member CombatRules.consumables].
func is_consumable() -> bool:
	return consumable_index >= 0


## First tick (relative to the action) of the active phase: the commit tick.
func active_from() -> int:
	return cast_ticks


## First tick (relative to the action) after the active phase (exclusive).
func active_to() -> int:
	return cast_ticks + active_ticks


## Forced speed (m/s) of the advance at tick [param relative_tick] of the action (0 outside
## its window).
func dash_speed_at(relative_tick: int) -> float:
	var index: int = relative_tick - dash_from_ticks
	if index < 0 or index >= dash_speeds.size():
		return 0.0
	return dash_speeds[index]


## true if [param relative_tick] falls within the advance window.
func is_dashing(relative_tick: int) -> bool:
	return dash_distance_m > 0.0 and relative_tick >= dash_from_ticks \
			and relative_tick < dash_to_ticks
