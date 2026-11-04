class_name HitShape
extends Resource
## Shape of a melee hit: an annular sector with height in front of the attacker
## (docs/combate.md, section 2). The geometry that tests it against a capsule lives in
## [code]hit_shapes.gd[/code]; only the data is here.
## [br][br]
## It is server-only data: it is not part of [method CombatCatalog.prediction_hash].

## Maximum reach from the attacker's axis (m).
@export var range_m: float = 2.6
## Minimum reach (m); 0 = whole sector, no central hole.
@export var inner_m: float = 0.0
## Total angle of the sector (degrees), centered on the attacker's yaw.
@export var angle_deg: float = 100.0
## Minimum height of the hit above the attacker's feet (m).
@export var height_min: float = 0.2
## Maximum height of the hit above the attacker's feet (m).
@export var height_max: float = 2.0
