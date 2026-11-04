class_name NpcDefinition
extends Resource
## Definition of an NPC type (docs/fuerte.md, section 4.2; MUN-07): the data the server needs to
## create it and for its brain ([code]HfsmBrain[/code]) to know how to behave. It lives in
## [code]data/npcs/<id>.tres[/code] (the [member id] is the file name without extension) and is listed by the
## [NpcCatalog], which gives each one a number 1..n in alphabetical order: it is the [code]npc_def_id[/code] of the
## ENTITY_SPAWN that the client uses to choose model, tabard and boss bar.
## [br][br]
## Shared because the zone nodes (the [code]NpcSpawner[/code]) name it. Durations are in
## seconds and distances in meters; the brain converts them to ticks.

## Identifier (the file name in [code]data/npcs/[/code] without extension).
@export var id: StringName = &""
## Name that players see.
@export var display_name: String = ""
## Maximum health.
@export_range(1, 65535) var max_health: int = 1000
## Weapon from the combat catalog ([code]data/combat/npc_*.tres[/code]): its light and heavy attacks, its
## block and its dodge.
@export var weapon_id: StringName = &"npc_hollow"
## true: does not die (health does not drop below 1). Dummies only.
@export var immortal: bool = false
## true: it is a boss (the client gives it a boss bar).
@export var is_boss: bool = false
## true: attacks enemies inside the safe zone of its own realm and can attack from it (the
## Gate Guardians, docs/combate.md 5). It only attacks enemies that are inside that zone.
@export var ignores_safe_area: bool = false

@export_group("Movimiento")
## Fraction of the run speed (5 m/s) when patrolling and returning.
@export_range(0.1, 1.0) var patrol_speed_scale: float = 0.45
## Fraction of the run speed when chasing.
@export_range(0.1, 1.0) var chase_speed_scale: float = 0.85
## true: sprints (7.5 m/s) if the target is far away.
@export var can_sprint: bool = false

@export_group("Percepción")
## Vision radius (m).
@export var perception_radius: float = 16.0
## Vision cone (degrees, total). 360 = sees all around.
@export_range(10.0, 360.0) var perception_cone_deg: float = 140.0
## Radius (m) within which it notices someone even if behind it or without a clear line of sight (hearing).
@export var awareness_radius: float = 4.0
## Beyond this distance (m) from the target, it gives it up for lost.
@export var lose_radius: float = 28.0
## Radius (m) of the group alert: on entering combat it warns those of the same group at this distance.
@export var alert_radius: float = 25.0
## Time (s) it takes to react after noticing someone (minimum and maximum; the randomness comes from its seed).
@export var reaction_s: Vector2 = Vector2(0.3, 0.7)

@export_group("Correa")
## Maximum distance (m) it strays from its post while chasing. Beyond that it returns, regenerated and immune.
@export var leash_radius: float = 32.0

@export_group("Combate")
## Probability (0 to 1) that an attack is the heavy (charged) one.
@export_range(0.0, 1.0) var heavy_chance: float = 0.2
## Probability (0 to 1) that, between two attacks, it raises its shield.
@export_range(0.0, 1.0) var block_chance: float = 0.12
## Duration (s) of the block (minimum and maximum).
@export var block_s: Vector2 = Vector2(0.6, 1.1)
## Pause (s) between one attack and the next (minimum and maximum).
@export var attack_gap_s: Vector2 = Vector2(0.5, 1.2)
## Every how many attacks it launches the special heavy attack (the Captain's unblockable strike); 0 = never.
@export_range(0, 20) var special_every: int = 0
## Distance (m) at which it circles the target when it has no attack token (3 to 4 m).
@export var circle_distance: float = 3.5

@export_group("Jefe")
## true: on entering combat it shouts and alerts the NPCs of its group.
@export var shouts: bool = false
## Definition of the reinforcements it calls when dropping below [member reinforcement_health_fraction] (empty = none).
@export var reinforcement_id: StringName = &""
## How many reinforcements it calls.
@export_range(0, 8) var reinforcement_count: int = 0
## Health fraction (0 to 1) below which it calls the reinforcements, only once.
@export_range(0.0, 1.0) var reinforcement_health_fraction: float = 0.5

@export_group("Guarnición")
## Definition that replaces it at the same post when the fort has an owner (the Hollow give way to the
## realm's guards, the Ford Captain to the realm's captain). Empty = nobody.
@export var garrison_id: StringName = &""

@export_group("Recompensas")
## XP each contributor receives when it dies: whoever did at least 10 % of the damage of the last 900 ticks
## (docs/progresion.md §6.2, PRG-13). 0 = none. It is paid by the server ([code]ProgressService.on_npc_killed[/code]).
@export_range(0, 100000) var xp_reward: int = 0
## Gold each contributor receives when it dies (reason NPC_KILL, docs/progresion.md §5.3). 0 = none.
@export_range(0, 100000) var gold_reward: int = 0
