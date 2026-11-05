class_name ProjectileLaunch
extends RefCounted
## The shot of an attack or an ability with a projectile at its commit (docs/abilities.md, section
## 4.4, steps 2 and 3), shared by the server ([code]ProjectileSystem[/code]) and the client's predicted
## arrow ([code]ProjectileWorld[/code], section 6.2): so that the two arrows are the same, both
## sides compute here what comes out, with what source and speed, in what direction and quantized how.
## [br][br]
## [b]What comes out[/b] ([method from_state]): on the commit tick ([method ActionMachine.is_commit_tick])
## of a LIGHT or HEAVY whose attack has [member AttackTicks.projectile_id], or of an ABILITY with
## [member AbilityTicks.projectile_id]. The speed is [code]projectile_speed_mps ·
## lerp(1, charge_speed_scale, f)[/code] with the [code]f[/code] of the damage charge (combat.md, section
## 4.4; 0 with no charge and in abilities).
## [br][br]
## [b]Direction[/b] ([method launch]): canonical camera ray ([method AimRay.canonical]) with the
## tick's input, point aimed with convergence ([method AimRay.aim_point]) against the world and the
## hostile capsules given by the caller (the server, rewound; the client, as they are drawn), muzzle
## at the chest ([method AimRay.muzzle]) and, in a fan, arrow [code]i[/code] rotated in yaw by
## [code](i − (n − 1) / 2) · projectile_spread_deg[/code] degrees. Origin and velocity are quantized as
## they travel in the SPAWN ([method Ballistics.quantize]): the server flies with that.
## [br][br]
## Shared and deterministic (no clock or randomness): it depends on neither the client nor the server.

## Below this distance (m) between the muzzle and the aimed point there is no direction: it fires along the
## camera ray.
const MIN_AIM_DISTANCE: float = 0.01

## Id of the [ProjectileTicks] (0 = this commit does not fire).
var projectile_id: int = 0
## Source of the shot ([CombatSource]): that of the attack or ability.
var source: int = 0
## Launch speed (m/s), with the charge already applied.
var speed: float = 0.0
## Projectiles in the shot (1 to 5) and degrees between two consecutive ones in the fan.
var count: int = 1
var spread_deg: float = 0.0
## Fraction of the charge ([code]f[/code], 0 to 1) with which it is released (0 with no charge).
var charge_fraction: float = 0.0


## The shot [param c] makes on tick [param tick] if it is the commit of an attack or ability
## with a projectile; null if it does not fire.
static func from_state(c: CombatState, tick: int) -> ProjectileLaunch:
	if c == null or not ActionMachine.is_commit_tick(c, tick):
		return null
	match c.action:
		CombatState.Action.LIGHT, CombatState.Action.HEAVY:
			return for_attack(CombatCatalog.attack(c.action_id), c.charge_ticks)
		CombatState.Action.ABILITY:
			return for_ability(CombatCatalog.ability(c.action_id))
	return null


## The shot of attack [param attack] released with [param charge_ticks] of charge (null if it does not fire).
## Only a heavy attack is charged: on a light attack the charge does not count.
static func for_attack(attack: AttackTicks, charge_ticks: int) -> ProjectileLaunch:
	if attack == null or attack.projectile_id == 0:
		return null
	var launch := ProjectileLaunch.new()
	launch.projectile_id = attack.projectile_id
	launch.source = CombatSource.make(CombatSource.Kind.ATTACK, attack.id)
	if attack.heavy:
		launch.charge_fraction = charge_progress(charge_ticks, attack.charge_min_ticks,
				attack.charge_max_ticks)
	launch.speed = attack.projectile_speed_mps * lerpf(1.0, attack.charge_speed_scale, launch.charge_fraction)
	return launch


## The shot of ability [param ability] (null if it does not fire).
static func for_ability(ability: AbilityTicks) -> ProjectileLaunch:
	if ability == null or ability.projectile_id == 0:
		return null
	var launch := ProjectileLaunch.new()
	launch.projectile_id = ability.projectile_id
	launch.source = CombatSource.make(CombatSource.Kind.ABILITY, ability.id)
	launch.speed = ability.projectile_speed_mps
	launch.count = clampi(ability.projectile_count, 1, 5)
	launch.spread_deg = ability.projectile_spread_deg
	return launch


## The [code]f[/code] of the charge (combat.md, section 4.4): [code](charge − min) / (max − min)[/code]
## clamped to [0, 1]; 0 if the attack is not charged.
static func charge_progress(charge_ticks: int, charge_min_ticks: int, charge_max_ticks: int) -> float:
	if charge_max_ticks <= charge_min_ticks:
		return 0.0
	return clampf(float(charge_ticks - charge_min_ticks) / float(charge_max_ticks - charge_min_ticks),
			0.0, 1.0)


## Origin and velocity of each projectile of the shot ([code][p0, v0][/code] per fan index, already
## quantized) of a character with feet at [param feet] and the view [param look_yaw],
## [param look_pitch] and [param left_shoulder] from the tick's input. [param space] is the world
## ([constant HitShapes.LINE_OF_SIGHT_MASK]; null = no world) and [param hostile_feet], the feet of the
## hostiles for convergence.
func launch(feet: Vector3, look_yaw: float, look_pitch: float, left_shoulder: bool,
		space: PhysicsDirectSpaceState3D, hostile_feet: PackedVector3Array) -> Array[PackedVector3Array]:
	var ray: Array = AimRay.canonical(feet, look_yaw, look_pitch, left_shoulder)
	var point: Vector3 = AimRay.aim_point(space, ray[0], ray[1], hostile_feet)
	return launch_toward(AimRay.muzzle(feet), point, ray[1])


## Like [method launch], with the aimed point [param point] already computed and the muzzle at
## [param muzzle]; the server ([method ProjectileSystem.fire]) calls here with its rewound candidates.
## A degenerate aim (the point less than [constant MIN_AIM_DISTANCE] from the muzzle) goes out along
## [param fallback], the camera ray's direction (unit vector).
func launch_toward(muzzle: Vector3, point: Vector3,
		fallback: Vector3 = Vector3.FORWARD) -> Array[PackedVector3Array]:
	var direction: Vector3 = point - muzzle
	direction = direction.normalized() if direction.length() > MIN_AIM_DISTANCE else fallback
	var shots: Array[PackedVector3Array] = []
	for index: int in count:
		var offset_deg: float = (float(index) - float(count - 1) * 0.5) * spread_deg
		var turned: Vector3 = direction.rotated(Vector3.UP, deg_to_rad(offset_deg)) \
				if offset_deg != 0.0 else direction
		var quantized: Array = Ballistics.quantize(muzzle, turned * speed)
		shots.append(PackedVector3Array([quantized[0], quantized[1]]))
	return shots
