class_name LevelCurve
extends Resource
## Experience curve (docs/progresion.md §6.1, PRG-13), in
## [code]data/progression/level_curve.tres[/code]: the XP needed to go from each level to the
## next, up to the cap.
## [br][br]
## The data is the [member xp_to_next] table, not the formula it was generated with
## ([code]round((500 + 150 · (L − 1)^1.6) / 10) · 10[/code]): one figure can be tweaked by hand
## without changing the others. It is exported by [ProgressionRulesExport] ([code]level_curve[/code]
## section) and the platform uses it to check the level of each save (S6). Shared: no clock, no
## randomness.

## Path of the resource.
const PATH: String = "res://data/progression/level_curve.tres"

## Maximum level.
@export_range(2, 255) var level_cap: int = 40
## XP to go from level [code]i + 1[/code] to [code]i + 2[/code]: [code]level_cap − 1[/code] values.
@export var xp_to_next: PackedInt32Array = PackedInt32Array()
## Attribute points per level gained (PRG-17; in phase 5 they are shown but not spent).
@export_range(0, 100) var attribute_points_per_level: int = 1

static var _shared: LevelCurve = null


## The curve at [constant PATH], loaded once. If it cannot be loaded, it logs the error and returns
## an empty curve (everyone at level 1).
static func shared() -> LevelCurve:
	if _shared == null:
		_shared = ResourceLoader.load(PATH) as LevelCurve
		if _shared == null:
			push_error("[Eldmark] No se puede cargar la curva de niveles %s" % PATH)
			_shared = LevelCurve.new()
	return _shared


## Total XP needed to reach [param level] from 0: 0 for level 1 and, for the cap, what is needed to
## reach the cap. Outside [code]1..level_cap[/code], the nearest end.
func total_to(level: int) -> int:
	var steps: int = mini(clampi(level, 1, level_cap) - 1, xp_to_next.size())
	var total: int = 0
	for i: int in range(steps):
		total += xp_to_next[i]
	return total


## Level corresponding to [param xp_total] (I8): the highest level whose [method total_to] does not
## exceed it, between 1 and [member level_cap].
func level_for(xp_total: int) -> int:
	var level: int = 1
	var total: int = 0
	while level < level_cap and level - 1 < xp_to_next.size():
		total += xp_to_next[level - 1]
		if xp_total < total:
			break
		level += 1
	return level


## XP missing for the next level from the start of [param level]; 0 at the cap.
func xp_for_next(level: int) -> int:
	if level < 1 or level >= level_cap or level - 1 >= xp_to_next.size():
		return 0
	return xp_to_next[level - 1]


## Data errors (empty if the curve is valid): as many values as steps up to the cap, all greater
## than 0.
func get_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if xp_to_next.size() != level_cap - 1:
		errors.append("xp_to_next tiene %d valores y el tope %d pide %d" % [xp_to_next.size(), level_cap,
				level_cap - 1])
	for i: int in range(xp_to_next.size()):
		if xp_to_next[i] <= 0:
			errors.append("xp_to_next[%d] = %d no es mayor que 0" % [i, xp_to_next[i]])
	return errors
