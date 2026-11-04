class_name AbilityDefinition
extends Resource
## A weapon ability or a consumable (docs/habilidades.md, section 2.1). All times are in seconds
## since the start of the action, and [CombatCatalog] converts them to ticks with
## [code]roundi(s * 60)[/code] on load.
## [br][br]
## Phases: cast [code][0, cast)[/code], active [code][cast, cast + active)[/code] and
## recovery up to the total. In a channel, the active phase is its cap and there is no recovery. The
## cooldown starts at the commit (the first active tick); for a channel, when it ends.
## [br][br]
## The "predicted" fields go into [method CombatCatalog.prediction_hash]; the "server-only" ones
## are used by the resolver (with them the catalog synthesizes an [AttackTicks], the ability's hit).

## Unique identifier (the catalog assigns it a u16 ID in alphabetical order).
@export var id: StringName

# --- Predicted --------------------------------------------------------------------------------

## Cast (s).
@export var cast_s: float = 0.0
## Active (s); in a channel, its cap.
@export var active_s: float = 0.1
## Recovery (s); 0 for channels.
@export var recovery_s: float = 0.3
## Cooldown (s); 0 for consumables (they use the shared one from [CombatRules]).
@export var cooldown_s: float = 10.0
## true: the active phase is a channel.
@export var channel: bool = false
## Channel: releasing its slot button ends it.
@export var channel_hold: bool = true
## Channel: moving ends it.
@export var channel_breaks_on_move: bool = false
## Moment (s since the start) from which it can be canceled into a dodge; -1 = from
## recovery.
@export var cancel_to_dodge_from_s: float = -1.0
## Moment (s since the start) from which it can be canceled into an attack; -1 = from
## recovery.
@export var cancel_to_attack_from_s: float = -1.0
## Fraction of the run speed allowed.
@export var move_speed_scale: float = 0.3
## Turn toward the camera (rad/s) during cast, active and channel.
@export var turn_rate: float = 6.0
## Forward speed (m/s) during cast and active.
@export var lunge_speed: float = 0.0
## Forced advance (m; 0 = none), baked like the dodge.
@export var dash_distance_m: float = 0.0
## Advance window [from, to) in s since the start of the action.
@export var dash_from_s: float = 0.0
@export var dash_to_s: float = 0.0
## Shape of the advance's speed profile (null = flat); normalized to [member dash_distance_m].
@export var dash_curve: Curve
## Advance direction: 0 toward look_yaw, 1 backward, 2 following the movement (like the dodge).
@export var dash_direction: int = 0
## Can be used in the air.
@export var usable_in_air: bool = false
## Stamina it restores on commit (stamina potion).
@export var stamina_restore: int = 0
## The channel blocks (shield wall).
@export var blocks: bool = false
## Projectile released at the commit (null = none).
@export var projectile: ProjectileDefinition
## Projectiles per shot (1-5) and angle between them (degrees).
@export var projectile_count: int = 1
@export var projectile_spread_deg: float = 0.0
## Projectile launch speed (m/s).
@export var projectile_speed_mps: float = 45.0

# --- Server only ------------------------------------------------------------------------------

## Shape of the hit on each active tick (null = no hit).
@export var shape: HitShape
@export var base_damage: int = 0
## Damage type ([enum DamageFormula.DamageType]).
@export var damage_type: int = 0
@export var stagger_s: float = 0.0
@export var stun_s: float = 0.0
@export var knockback_speed: float = 0.0
@export var hyper_armor: bool = false
@export var unblockable: bool = false
## Effect applied to whoever is hit (also by its projectile).
@export var target_status: StatusEffectDefinition
## Self effect and self healing, on commit.
@export var self_status: StatusEffectDefinition
@export var self_heal: int = 0
## A hit taken during the cast interrupts it (always true for consumables).
@export var interrupt_on_damage: bool = false
## Box that stops projectiles for the duration of the channel (half-extents in m; zero = none).
@export var wall_half_extents: Vector3 = Vector3.ZERO
## Distance (m) from the box center in front of the feet.
@export var wall_forward_m: float = 0.7
