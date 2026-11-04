class_name ProgressionRules
extends RefCounted
## Pure rules for experience and levels (docs/progresion.md §6.3, PRG-13), shared by the zone
## (which hands out XP) and the interface (which displays it). No state, clock or randomness.
## [br][br]
## A single contribution can raise several levels; at the cap no XP accumulates (I8): 0 is applied
## and the total stays at [code]curve.total_to(level_cap)[/code]. Level does not change the
## simulation in phase 5 (§0): it is only displayed and unlocks items via [code]required_level[/code].

## XP per PvP or objective merit (§6.2).
const XP_PER_MERIT: int = 10


## Result of [method ProgressionRules.add_xp].
class XpResult:
	## Level after the contribution.
	var level: int = 1
	## Total XP after the contribution.
	var xp_total: int = 0
	## Levels gained with this contribution (0 if it does not rise).
	var levels_gained: int = 0
	## XP actually added: less than requested if it reaches the cap, 0 at the cap.
	var applied: int = 0


## Adds [param amount] XP to a character of level [param level] with [param xp_total] and returns
## the level, the total, the levels gained and what was applied. An [param amount] of 0 or negative
## applies nothing (XP only goes down with a GM or REVERSAL operation, which subtracts it and
## recomputes the level with [method LevelCurve.level_for]). A total above the cap is brought to
## the cap (I8).
static func add_xp(curve: LevelCurve, level: int, xp_total: int, amount: int) -> XpResult:
	var result := XpResult.new()
	var cap_total: int = curve.total_to(curve.level_cap)
	var current: int = clampi(xp_total, 0, cap_total)
	result.applied = clampi(amount, 0, cap_total - current)
	result.xp_total = current + result.applied
	result.level = curve.level_for(result.xp_total)
	result.levels_gained = maxi(result.level - level, 0)
	return result


## Unspent attribute points (§6.3): [code](level − 1) · attribute_points_per_level − spent[/code],
## never less than 0. They are not stored: they are derived, so PRG-17 can change the distribution
## without migrating.
static func attribute_points(curve: LevelCurve, level: int, spent: int) -> int:
	var earned: int = (clampi(level, 1, curve.level_cap) - 1) * curve.attribute_points_per_level
	return maxi(earned - spent, 0)
