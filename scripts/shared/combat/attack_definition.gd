class_name AttackDefinition
extends Resource
## A melee attack or a shot (docs/combat.md, section 2; docs/abilities.md, section
## 2.1). All times are in seconds and
## [CombatCatalog] converts them to ticks with [code]roundi(s * 60)[/code] on load.
## [br][br]
## The windows are counted from the start of the action ([code]action_tick[/code]): windup
## [code][0, windup)[/code], then the active hit and recovery. In the heavy attack, the
## windup starts when the charge is released.

## Unique attack identifier (the catalog assigns it a u16 ID in alphabetical order).
@export var id: StringName
## true for the heavy attack (it is charged by holding the button).
@export var heavy: bool = false
## Windup (s); for the heavy attack, after releasing the charge.
@export var windup_s: float = 0.2
## Active hit (s): the shape is tested on each tick.
@export var active_s: float = 0.1
## Recovery (s).
@export var recovery_s: float = 0.3
## Last seconds of the recovery in which a press links the next light attack.
@export var combo_window_s: float = 0.0
## Moment (s since the start of the action) from which it can be canceled into a dodge.
@export var cancel_to_dodge_from_s: float = 0.4
## Stamina cost (0-1000).
@export_range(0, 1000) var stamina_cost: int = 0
## Forward speed (m/s) during windup and active hit.
@export var lunge_speed: float = 0.0
## Turn toward the camera (rad/s) during windup and active hit.
@export var turn_rate: float = 6.0
## Fraction of the run speed allowed for the duration of the attack.
@export var move_speed_scale: float = 0.3
## Hit shape (server only). With [member projectile] it can be null: the attack fires on its
## first active tick.
@export var shape: HitShape
## Base damage (integer, server only).
@export var base_damage: int = 0
## Damage type (0 slashing, 1 piercing, 2 blunt, 3 elemental; server only).
@export var damage_type: int = 0
## true: during the active hit it is immune to stagger and knockback (server only).
@export var hyper_armor: bool = false
## true: the hit cannot be blocked or parried (it can only be avoided by dodging): the defender's block and parry
## do not stop it and they take full damage (server only; it is the Ford Captain's hit).
@export var unblockable: bool = false
## Stagger it causes (s; 0 = none; server only).
@export var stagger_s: float = 0.0
## Knockback it causes (m/s; 0 = none; server only).
@export var knockback_speed: float = 0.0
## Heavy attacks only: minimum charge (s), counted from the press.
@export var charge_min_s: float = 0.0
## Heavy attacks only: maximum charge (s), counted from the press.
@export var charge_max_s: float = 0.0
## Heavy attacks only: damage multiplier at maximum charge (linear from x1 at the minimum; server
## only).
@export var charge_damage_scale: float = 1.0
## Heavy attacks only: fraction of the run speed allowed while charging.
@export var charge_move_scale: float = 0.4
## Heavy attacks only: turn toward the camera (rad/s) while charging.
@export var charge_turn_rate: float = 4.0
## Projectile released on the first active tick (null = none; docs/abilities.md, section 4.4).
@export var projectile: ProjectileDefinition
## Projectile launch speed (m/s); for the heavy attack, at minimum charge.
@export var projectile_speed_mps: float = 45.0
## Heavy attacks with a projectile only: launch speed multiplier at maximum charge (linear from
## x1 at the minimum).
@export var charge_speed_scale: float = 1.0
## Stun it causes (s; 0 = none; server only).
@export var stun_s: float = 0.0
## Effect applied to whoever is hit (null = none; server only).
@export var on_hit_status: StatusEffectDefinition
