class_name DamageFormula
extends RefCounted
## Combat damage formula (docs/combate.md, section 4.4): integers, no randomness and stateless.
## Only the server evaluates it, but it is shared so that tests and tools (the
## DPS meter, the balancing UI) use the same one.
## [br][br]
## [codeblock]
## raw     = base × charge × crit × damage_scale
## mitig.  = raw × max(block_mitigation − mitigation_penalty, 0)    (only if blocking)
## final   = roundi((raw − mitig.) × 1000 / (1000 + armor)), minimum 1 if anything is left
## [/codeblock]
## [code]damage_scale[/code] and [code]mitigation_penalty[/code] are the modifiers from status
## effects (docs/abilities.md, section 4.3): [code]1 + Σ DAMAGE_UP[/code] of the attacker and
## [code]Σ MITIGATION_DOWN[/code] of the victim; with no effects they are 1 and 0 and the result is the usual
## one.
## Block: the defender spends [code]roundi(mitig. × block_stamina_per_damage)[/code] of
## stamina. If it is not enough, the shield only absorbs the part proportional to the stamina
## it had, the rest goes through as damage and there is a guard break.

## Damage types. In phase 3 all attacks are [code]SLASH[/code] and the per-type
## resistances are 0.
enum DamageType { SLASH, PIERCE, BLUNT, ELEMENTAL }

## Multiplier of a critical hit from behind (the value of
## [code]CombatRules.crit_multiplier[/code]).
const CRIT_MULTIPLIER: float = 1.5
## Angle (degrees) relative to the victim's yaw from which the hit counts as from behind
## (the value of [code]CombatRules.backstab_angle_deg[/code]).
const BACKSTAB_ANGLE_DEG: float = 120.0
## Armor base: with armor A the damage is multiplied by 1000 / (1000 + A).
const ARMOR_BASE: int = 1000
## Remaining damage from which "something is left" and the minimum of 1 is applied.
const _MIN_REMAINING: float = 0.001
## Below this horizontal distance there is no direction between two positions.
const _MIN_DIRECTION_LENGTH: float = 0.0001


## Result of [method compute].
class Result:
	## Damage that reaches the victim's health (integer, with armor already applied).
	var damage: int = 0
	## Raw damage absorbed by the shield (before armor). 0 if it was not blocked.
	var absorbed: int = 0
	## Stamina the defender spends when blocking. Never more than they had.
	var stamina_cost: int = 0
	## Whether the hit was critical (the caller decides it with [method is_backstab]).
	var critical: bool = false
	## true if the block did not hold for lack of stamina: the defender is left stunned.
	var guard_break: bool = false


## Charge factor of a heavy attack: [code]lerp(1, charge_damage_scale, f)[/code] with
## [code]f = (charge_ticks − charge_min_ticks) / (charge_max_ticks − charge_min_ticks)[/code]
## clamped to [0, 1]. It is 1 for an attack with no charge ([code]charge_max_ticks <= charge_min_ticks[/code])
## and below the minimum charge.
static func charge_factor(charge_ticks: int, charge_min_ticks: int, charge_max_ticks: int,
		charge_damage_scale: float) -> float:
	if charge_max_ticks <= charge_min_ticks:
		return 1.0
	var progress: float = clampf(float(charge_ticks - charge_min_ticks)
			/ float(charge_max_ticks - charge_min_ticks), 0.0, 1.0)
	return lerpf(1.0, charge_damage_scale, progress)


## Computes the damage of a hit.
## [br][br]
## [b]Chosen signature[/b] (the [code]AttackTicks[/code] catalog is written by another package): instead
## of the attack, its four damage values come in separately: [param base_damage],
## [param charge_min_ticks], [param charge_max_ticks] and [param charge_damage_scale]. With a light attack
## 0, 0 and 1.0 are passed. [param charge_ticks] is the charge with which the hit was released.
## [br][br]
## [param critical] is decided by the caller (normally with [method is_backstab]) and multiplies by
## [param crit_multiplier]. With [param blocked], [param block_mitigation] (0 to 1) of the raw damage is
## absorbed by the shield in exchange for [param block_stamina_per_damage] of stamina per point
## absorbed; [param defender_stamina] is what the defender has. [param armor] (0 or more) reduces
## the damage that goes through.
## [br][br]
## [param damage_scale] (0 or more) multiplies the raw damage (more damage from the attacker) and
## [param mitigation_penalty] lowers the fraction absorbed by the block (less mitigation from the
## victim), without going below 0.
static func compute(base_damage: int, charge_ticks: int, charge_min_ticks: int,
		charge_max_ticks: int, charge_damage_scale: float, critical: bool, blocked: bool,
		block_mitigation: float, block_stamina_per_damage: float, defender_stamina: int,
		armor: int, crit_multiplier: float = CRIT_MULTIPLIER, damage_scale: float = 1.0,
		mitigation_penalty: float = 0.0) -> DamageFormula.Result:
	var result := Result.new()
	result.critical = critical
	var gross: float = float(base_damage) \
			* charge_factor(charge_ticks, charge_min_ticks, charge_max_ticks, charge_damage_scale)
	if critical:
		gross *= crit_multiplier
	gross *= maxf(damage_scale, 0.0)
	var absorbed: float = 0.0
	if blocked:
		var mitigation: float = clampf(block_mitigation - maxf(mitigation_penalty, 0.0), 0.0, 1.0)
		var mitigated: float = gross * mitigation
		var needed: int = roundi(mitigated * block_stamina_per_damage)
		var available: int = maxi(defender_stamina, 0)
		if available >= needed:
			absorbed = mitigated
			result.stamina_cost = needed
		else:
			# needed > available >= 0: the guard holds the proportional part and breaks.
			absorbed = mitigated * float(available) / float(needed)
			result.stamina_cost = available
			result.guard_break = true
		result.absorbed = roundi(absorbed)
	var remaining: float = gross - absorbed
	if remaining > _MIN_REMAINING:
		var armor_scale: float = float(ARMOR_BASE) / float(ARMOR_BASE + maxi(armor, 0))
		result.damage = maxi(roundi(remaining * armor_scale), 1)
	return result


## true if [param attacker_pos] is behind the victim: more than
## [param angle_deg] degrees (120° by default) from the victim's body yaw, measured
## horizontally. At the exact edge it is not. An attacker right above the victim (no horizontal
## direction) does not hit from behind.
static func is_backstab(attacker_pos: Vector3, victim_pos: Vector3, victim_yaw: float,
		angle_deg: float = BACKSTAB_ANGLE_DEG) -> bool:
	var offset := Vector2(attacker_pos.x - victim_pos.x, attacker_pos.z - victim_pos.z)
	var distance: float = offset.length()
	if distance < _MIN_DIRECTION_LENGTH:
		return false
	var forward: Vector3 = Basis(Vector3.UP, victim_yaw) * Vector3.FORWARD
	var cos_angle: float = (forward.x * offset.x + forward.z * offset.y) / distance
	return acos(clampf(cos_angle, -1.0, 1.0)) > deg_to_rad(angle_deg)


## true if [param damage_type] is physical (slashing, piercing or blunt): the shield only
## stops physical damage (elemental is left to the discretion of whoever resolves the hit).
static func is_physical(damage_type: int) -> bool:
	return damage_type == DamageType.SLASH or damage_type == DamageType.PIERCE \
			or damage_type == DamageType.BLUNT
