extends TestCase
## Tests for the damage formula ([DamageFormula], docs/combate.md section 4.4) with a table of
## hand-computed cases: light, heavy with minimum, half and maximum charge, crit, full and
## partial block, block with insufficient stamina (proportional pass-through and guard
## break), armor and the minimum of 1. Also the hit from behind ([method
## DamageFormula.is_backstab]).
##
## Attack data (the initial values of the sword, docs/combate.md section 2):
## light 1 = 90, light 3 = 130, heavy = 180 with a charge of 21 to 72 ticks (0.35 s to 1.2 s) and ×1.7
## at maximum charge. The calculations are in each case.

const LIGHT_1: int = 90
const LIGHT_3: int = 130
const HEAVY: int = 180
const CHARGE_MIN: int = 21
const CHARGE_MAX: int = 72
const CHARGE_SCALE: float = 1.7
## Sword shield: stops all frontal damage, 1.0 stamina per point absorbed.
const FULL_BLOCK: float = 1.0
const STAMINA_PER_DAMAGE: float = 1.0
const FULL_STAMINA: int = 1000


# --- Attacks without defense ------------------------------------------------------------------

func test_light_attacks_do_base_damage() -> void:
	var result: DamageFormula.Result = _light(LIGHT_1)
	assert_eq(result.damage, 90, "light 1: 90")
	assert_eq(result.absorbed, 0, "without a block nothing is absorbed")
	assert_eq(result.stamina_cost, 0, "without a block it costs no stamina")
	assert_false(result.critical, "it is not a crit")
	assert_false(result.guard_break, "nor does it break the guard")
	assert_eq(_light(LIGHT_3).damage, 130, "light 3: 130")
	# A light attack ignores any charge passed to it.
	assert_eq(DamageFormula.compute(LIGHT_1, 50, 0, 0, 1.0, false, false, 0.0, 0.0, 0, 0).damage, 90,
			"a light attack is not scaled by charge")


func test_heavy_scales_with_charge() -> void:
	# charge = 1 + (1.7 - 1) · (ticks - 21) / (72 - 21).
	assert_eq(_heavy(21).damage, 180, "minimum charge (21 ticks): ×1 = 180")
	assert_eq(_heavy(8).damage, 180, "below the minimum: ×1 = 180")
	# 46 ticks: 1 + 0.7 · 25 / 51 = 1.343137 -> 180 · 1.343137 = 241.76 -> 242.
	assert_eq(_heavy(46).damage, 242, "half charge (46 ticks): 242")
	assert_eq(_heavy(72).damage, 306, "maximum charge (72 ticks): ×1.7 = 306")
	assert_eq(_heavy(200).damage, 306, "beyond the maximum it does not grow: 306")
	# With a charge of 20 to 60 ticks, at the middle (40) the factor is 1.35: 180 · 1.35 = 243.
	assert_eq(DamageFormula.compute(HEAVY, 40, 20, 60, CHARGE_SCALE, false, false, 0.0, 0.0, 0,
			0).damage, 243, "charge exactly at the middle of a clean range: 243")


func test_charge_factor() -> void:
	assert_near(DamageFormula.charge_factor(21, 21, 72, 1.7), 1.0, 1e-9, "minimum")
	assert_near(DamageFormula.charge_factor(72, 21, 72, 1.7), 1.7, 1e-9, "maximum")
	assert_near(DamageFormula.charge_factor(40, 20, 60, 1.7), 1.35, 1e-9, "middle")
	assert_near(DamageFormula.charge_factor(0, 21, 72, 1.7), 1.0, 1e-9, "below")
	assert_near(DamageFormula.charge_factor(999, 21, 72, 1.7), 1.7, 1e-9, "above")
	assert_near(DamageFormula.charge_factor(30, 0, 0, 1.7), 1.0, 1e-9, "no charge range")
	assert_near(DamageFormula.charge_factor(30, 60, 20, 1.7), 1.0, 1e-9, "inverted range")


# --- Crits ------------------------------------------------------------------------------------

func test_critical_multiplies_by_one_and_a_half() -> void:
	var result: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, true, false,
			0.0, 0.0, 0, 0)
	assert_eq(result.damage, 135, "crit light attack: 90 · 1.5 = 135")
	assert_true(result.critical, "the result remembers the crit")
	var heavy_critical: DamageFormula.Result = DamageFormula.compute(HEAVY, CHARGE_MAX,
			CHARGE_MIN, CHARGE_MAX, CHARGE_SCALE, true, false, 0.0, 0.0, 0, 0)
	assert_eq(heavy_critical.damage, 459, "crit heavy attack at maximum charge: 306 · 1.5 = 459")
	# A custom multiplier.
	assert_eq(DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, true, false, 0.0, 0.0, 0, 0,
			2.0).damage, 180, "crit ×2: 180")
	# Without a crit the multiplier does not count.
	assert_eq(DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, false, 0.0, 0.0, 0, 0,
			2.0).damage, 90, "without a crit, ×1")


# --- Block ------------------------------------------------------------------------------------

func test_full_block_absorbs_everything() -> void:
	var result: DamageFormula.Result = _blocked(LIGHT_1, FULL_BLOCK, FULL_STAMINA)
	assert_eq(result.damage, 0, "full block: no damage passes (and the minimum of 1 does not apply)")
	assert_eq(result.absorbed, 90, "the shield absorbs the 90")
	assert_eq(result.stamina_cost, 90, "costs 90 stamina (1.0 per point)")
	assert_false(result.guard_break, "with plenty of stamina the guard does not break")
	# The heavy attack at maximum charge: 306 points, 306 stamina.
	var heavy: DamageFormula.Result = DamageFormula.compute(HEAVY, CHARGE_MAX, CHARGE_MIN,
			CHARGE_MAX, CHARGE_SCALE, false, true, FULL_BLOCK, STAMINA_PER_DAMAGE, FULL_STAMINA, 0)
	assert_eq(heavy.damage, 0, "charged heavy attack blocked: 0")
	assert_eq(heavy.absorbed, 306, "absorbs 306")
	assert_eq(heavy.stamina_cost, 306, "costs 306")
	assert_false(heavy.guard_break, "with 1000 stamina it does not break")


func test_partial_mitigation_lets_damage_through() -> void:
	# Mitigation 0.8: absorbs 72 of 90, 18 pass through; at 1.0 per point it costs 72.
	var result: DamageFormula.Result = _blocked(LIGHT_1, 0.8, FULL_STAMINA)
	assert_eq(result.damage, 18, "18 pass through")
	assert_eq(result.absorbed, 72, "72 are absorbed")
	assert_eq(result.stamina_cost, 72, "costs 72")
	assert_false(result.guard_break, "the guard does not break")
	# With 2.0 stamina per point absorbed: it costs 144.
	var costly: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, true,
			0.8, 2.0, FULL_STAMINA, 0)
	assert_eq(costly.stamina_cost, 144, "2.0 per point: 144")
	assert_eq(costly.damage, 18, "the damage that passes does not change")
	# Without mitigation (0) a block protects from nothing and costs nothing.
	var none: DamageFormula.Result = _blocked(LIGHT_1, 0.0, FULL_STAMINA)
	assert_eq(none.damage, 90, "mitigation 0: everything passes")
	assert_eq(none.stamina_cost, 0, "and it costs no stamina")


func test_block_without_enough_stamina_breaks_guard_and_passes_proportionally() -> void:
	# Heavy attack at maximum charge (306) with full mitigation and 1.0 per point: the guard needs 306.
	# With 100 stamina it withstands 100/306 of the hit: absorbs 100, 206 pass through.
	var result: DamageFormula.Result = _blocked_heavy_max(100)
	assert_eq(result.absorbed, 100, "absorbs the part it can: 100")
	assert_eq(result.damage, 206, "the other 206 pass through")
	assert_eq(result.stamina_cost, 100, "spends all the stamina it had")
	assert_true(result.guard_break, "guard break")
	# Exactly the stamina needed: it holds.
	var exact: DamageFormula.Result = _blocked_heavy_max(306)
	assert_eq(exact.damage, 0, "306 stamina: it holds in full")
	assert_eq(exact.stamina_cost, 306, "spends 306")
	assert_false(exact.guard_break, "and does not break")
	# One less: the guard gives way and 1 point passes (minimum 1 when something is left).
	var short: DamageFormula.Result = _blocked_heavy_max(305)
	assert_eq(short.absorbed, 305, "absorbs 305")
	assert_eq(short.damage, 1, "1 passes")
	assert_eq(short.stamina_cost, 305, "spends 305")
	assert_true(short.guard_break, "guard break by one point")
	# With no stamina at all the shield does not absorb: the whole hit passes and the guard breaks.
	var empty: DamageFormula.Result = _blocked_heavy_max(0)
	assert_eq(empty.absorbed, 0, "without stamina it does not absorb")
	assert_eq(empty.damage, 306, "everything passes")
	assert_eq(empty.stamina_cost, 0, "it has nothing to spend")
	assert_true(empty.guard_break, "guard break")
	# A negative stamina (it should not happen) counts as 0.
	assert_eq(_blocked_heavy_max(-5).damage, 306, "negative stamina = 0")
	# Proportional with partial mitigation: light 90, mitigation 0.8 (72), 2.0 per point (144),
	# 72 stamina: it withstands 72/144 = half of the 72 -> absorbs 36, 90 - 36 = 54 pass through.
	var partial: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, true,
			0.8, 2.0, 72, 0)
	assert_eq(partial.absorbed, 36, "partial mitigation without enough stamina: absorbs 36")
	assert_eq(partial.damage, 54, "54 pass through")
	assert_eq(partial.stamina_cost, 72, "spends the 72")
	assert_true(partial.guard_break, "guard break")


# --- Armor and minimum ------------------------------------------------------------------------

func test_armor_reduces_damage_that_passes() -> void:
	# final = damage · 1000 / (1000 + armor).
	assert_eq(_armored(LIGHT_1, 0), 90, "armor 0: 90")
	assert_eq(_armored(LIGHT_1, 1000), 45, "armor 1000: half = 45")
	assert_eq(_armored(LIGHT_1, 500), 60, "armor 500: 90 · 1000 / 1500 = 60")
	assert_eq(_armored(LIGHT_1, 9000), 9, "armor 9000: a tenth = 9")
	# Armor is applied after the crit and the block.
	# Crit light 3: 195; block 0.4 -> absorbs 78, 117 left; armor 300 -> 117 / 1.3 = 90.
	var combined: DamageFormula.Result = DamageFormula.compute(LIGHT_3, 0, 0, 0, 1.0, true, true,
			0.4, 1.5, FULL_STAMINA, 300)
	assert_eq(combined.damage, 90, "crit + partial block + armor = 90")
	assert_eq(combined.absorbed, 78, "the shield absorbs 78 (before the armor)")
	assert_eq(combined.stamina_cost, 117, "78 · 1.5 = 117 stamina")
	assert_true(combined.critical, "and it is still a crit")


func test_minimum_one_damage_when_something_passes() -> void:
	# 1 base damage with armor 4000: 1 · 1000 / 5000 = 0.2 -> rounds to 0 -> minimum 1.
	assert_eq(_armored(1, 4000), 1, "a tenth or less passing through is still 1")
	# Almost complete block: of 1 point it absorbs 0.9 and 0.1 passes -> 1.
	assert_eq(_blocked(1, 0.9, FULL_STAMINA).damage, 1, "what passes from an almost total block is 1")
	# But with a total block nothing is left and there is no minimum.
	assert_eq(_blocked(1, 1.0, FULL_STAMINA).damage, 0, "total block of 1: 0")
	# Without base damage there is no minimum.
	assert_eq(_light(0).damage, 0, "an attack without damage does no damage")
	# Huge armor neither divides by zero nor gives negatives.
	assert_eq(_armored(LIGHT_1, 1000000), 1, "huge armor: 1")
	assert_eq(_armored(LIGHT_1, -2000), 90, "negative armor counts as 0")


# --- Hit from behind --------------------------------------------------------------------------

func test_is_backstab_angle() -> void:
	var victim := Vector3(3.0, 0.0, -2.0)
	# Victim facing -Z (yaw 0). The attacker 3 m away at an angle to its front.
	assert_false(DamageFormula.is_backstab(victim + Vector3(0.0, 0.0, -3.0), victim, 0.0),
			"from the front")
	assert_false(DamageFormula.is_backstab(victim + Vector3(3.0, 0.0, 0.0), victim, 0.0),
			"from the side (90°)")
	assert_true(DamageFormula.is_backstab(victim + Vector3(0.0, 0.0, 3.0), victim, 0.0),
			"exactly from behind (180°)")
	for side: float in [1.0, -1.0]:
		var inside: Vector3 = victim + _polar(3.0, side * deg_to_rad(120.0 - 0.05))
		var outside: Vector3 = victim + _polar(3.0, side * deg_to_rad(120.0 + 0.05))
		assert_false(DamageFormula.is_backstab(inside, victim, 0.0),
				"at 119.95° not yet (side %d)" % int(side))
		assert_true(DamageFormula.is_backstab(outside, victim, 0.0),
				"at 120.05° it is (side %d)" % int(side))
	# With the victim facing elsewhere (yaw 90°: towards -X) the back is +X.
	assert_true(DamageFormula.is_backstab(victim + Vector3(3.0, 0.0, 0.0), victim, PI * 0.5),
			"yaw 90°: +X is the back")
	assert_false(DamageFormula.is_backstab(victim + Vector3(-3.0, 0.0, 0.0), victim, PI * 0.5),
			"yaw 90°: -X is the front")
	# Height does not count; exactly on top, neither.
	assert_true(DamageFormula.is_backstab(victim + Vector3(0.0, 6.0, 3.0), victim, 0.0),
			"attacker up high but behind")
	assert_false(DamageFormula.is_backstab(victim + Vector3(0.0, 6.0, 0.0), victim, 0.0),
			"exactly on top: no direction, it is not from behind")
	# Another angle.
	assert_true(DamageFormula.is_backstab(victim + Vector3(3.0, 0.0, 0.0), victim, 0.0, 80.0),
			"with a threshold of 80°, the flank (90°) counts")


func test_is_physical() -> void:
	assert_true(DamageFormula.is_physical(DamageFormula.DamageType.SLASH), "slashing")
	assert_true(DamageFormula.is_physical(DamageFormula.DamageType.PIERCE), "piercing")
	assert_true(DamageFormula.is_physical(DamageFormula.DamageType.BLUNT), "blunt")
	assert_false(DamageFormula.is_physical(DamageFormula.DamageType.ELEMENTAL), "elemental")


# --- Utilities --------------------------------------------------------------------------------

## Light hit with no defense or armor.
func test_status_modifiers_scale_the_damage_and_lower_the_mitigation() -> void:
	# docs/habilidades.md, section 4.3: damage_scale = 1 + Σ DAMAGE_UP and mitigation_penalty = Σ
	# MITIGATION_DOWN; without effects, the usual.
	var plain: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, false, 1.0,
			STAMINA_PER_DAMAGE, FULL_STAMINA, 0)
	var neutral: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, false, 1.0,
			STAMINA_PER_DAMAGE, FULL_STAMINA, 0, DamageFormula.CRIT_MULTIPLIER, 1.0, 0.0)
	assert_eq(neutral.damage, plain.damage, "with 1 and 0, the same damage")
	var stronger: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, true, false, 1.0,
			STAMINA_PER_DAMAGE, FULL_STAMINA, 0, DamageFormula.CRIT_MULTIPLIER, 1.2, 0.0)
	assert_eq(stronger.damage, roundi(LIGHT_1 * 1.5 * 1.2), "more damage: multiplies the gross (with the crit)")
	var blocked: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, true, 1.0,
			STAMINA_PER_DAMAGE, FULL_STAMINA, 0, DamageFormula.CRIT_MULTIPLIER, 1.0, 0.25)
	assert_eq(blocked.absorbed, roundi(LIGHT_1 * 0.75), "less mitigation: the shield absorbs 25 % mitigation points less")
	assert_eq(blocked.damage, roundi(LIGHT_1 * 0.25), "and the rest passes through")
	assert_eq(blocked.stamina_cost, roundi(LIGHT_1 * 0.75 * STAMINA_PER_DAMAGE), "paying only what is absorbed")
	var floor_zero: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, true, 0.5,
			STAMINA_PER_DAMAGE, FULL_STAMINA, 0, DamageFormula.CRIT_MULTIPLIER, 1.0, 0.8)
	assert_eq(floor_zero.absorbed, 0, "mitigation does not go below 0")
	assert_eq(floor_zero.damage, LIGHT_1, "and everything passes")
	var negative: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, false, 1.0,
			STAMINA_PER_DAMAGE, FULL_STAMINA, 0, DamageFormula.CRIT_MULTIPLIER, -1.0, 0.0)
	assert_eq(negative.damage, 0, "a negative multiplier counts as 0")


func _light(base: int) -> DamageFormula.Result:
	return DamageFormula.compute(base, 0, 0, 0, 1.0, false, false, 0.0, 0.0, 0, 0)


## Heavy hit (180) with [param charge_ticks] of charge, with no defense or armor.
func _heavy(charge_ticks: int) -> DamageFormula.Result:
	return DamageFormula.compute(HEAVY, charge_ticks, CHARGE_MIN, CHARGE_MAX, CHARGE_SCALE, false,
			false, 0.0, 0.0, 0, 0)


## Blocked light hit with the given [param mitigation] and 1.0 stamina per point.
func _blocked(base: int, mitigation: float, stamina: int) -> DamageFormula.Result:
	return DamageFormula.compute(base, 0, 0, 0, 1.0, false, true, mitigation, STAMINA_PER_DAMAGE,
			stamina, 0)


## Heavy attack at maximum charge (306) fully blocked by a defender with [param stamina].
func _blocked_heavy_max(stamina: int) -> DamageFormula.Result:
	return DamageFormula.compute(HEAVY, CHARGE_MAX, CHARGE_MIN, CHARGE_MAX, CHARGE_SCALE, false,
			true, FULL_BLOCK, STAMINA_PER_DAMAGE, stamina, 0)


## Final damage of an unblocked hit against [param armor].
func _armored(base: int, armor: int) -> int:
	return DamageFormula.compute(base, 0, 0, 0, 1.0, false, false, 0.0, 0.0, 0, armor).damage


## Horizontal point at [param distance] from the origin rotated [param angle] radians from -Z towards
## +X (positive) or -X (negative).
func _polar(distance: float, angle: float) -> Vector3:
	return Vector3(distance * sin(angle), 0.0, -distance * cos(angle))
