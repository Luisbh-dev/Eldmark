class_name Ballistics
extends RefCounted
## Projectile ballistics (docs/habilidades.md, section 4.4). Server and client call the
## same [method position], with [code]n[/code] integer (the server, on each tick) or fractional (the
## drawing), from the origin and velocity exactly as they travel in the ENTITY_SPAWN
## ([method quantize]): so both trajectories are the same. [method solve_lead] gives the
## lead shot for bots and NPCs.

## Simulation ticks per second.
const TICK_RATE: float = 60.0
## Fixed-point steps of [method solve_lead].
const _LEAD_ITERATIONS: int = 16


## Position of a projectile launched from [param p0] with velocity [param v0] (m/s) and gravity
## [param gravity] (m/s², downward) after [param ticks] ticks:
## [code]p0 + v0 · n/60 + (0, −½ · g · (n/60)², 0)[/code]. Each axis is computed in 64-bit floating
## point and rounded only once when building the [Vector3].
static func position(p0: Vector3, v0: Vector3, gravity: float, ticks: float) -> Vector3:
	var t: float = ticks / TICK_RATE
	var x: float = p0.x + v0.x * t
	var y: float = p0.y + v0.y * t - 0.5 * gravity * t * t
	var z: float = p0.z + v0.z * t
	return Vector3(x, y, z)


## [param p0] and [param v0] rounded as they travel in a projectile's ENTITY_SPAWN: position to
## 1 cm (20 bits per axis, like the entity record) and velocity to 1 cm/s (s16 per axis). The
## server flies with this, not with what it computed. Returns [code][p0, v0][/code].
static func quantize(p0: Vector3, v0: Vector3) -> Array:
	var position_q: Vector3 = NetMath.unpack_position(NetMath.pack_position(p0))
	var velocity_q := Vector3(
		NetMath.dequantize_velocity(NetMath.quantize_velocity(v0.x)),
		NetMath.dequantize_velocity(NetMath.quantize_velocity(v0.y)),
		NetMath.dequantize_velocity(NetMath.quantize_velocity(v0.z)),
	)
	return [position_q, velocity_q]


## Direction (unit) in which a projectile must be launched from [param origin], at [param speed] m/s and with
## [param gravity] m/s² downward, to reach a target that is at
## [param target] and moves at [param target_velocity] m/s: the lead shot for bots and NPCs.
## It looks for the flight time [code]T[/code] with
## [code]|target − origin + target_velocity · T + (0, ½ · g · T², 0)| = speed · T[/code] by
## fixed-point iteration (a fixed number of steps: deterministic), starting from the distance divided by
## the speed; it converges as long as the target is considerably slower than the projectile. With no velocity,
## or with the target at the origin, it returns the straight direction (or [constant Vector3.FORWARD]).
static func solve_lead(origin: Vector3, target: Vector3, target_velocity: Vector3, speed: float,
		gravity: float) -> Vector3:
	var offset: Vector3 = target - origin
	if speed <= 0.0 or offset.is_zero_approx():
		return offset.normalized() if not offset.is_zero_approx() else Vector3.FORWARD
	var time: float = offset.length() / speed
	var aim: Vector3 = offset
	for _i: int in _LEAD_ITERATIONS:
		aim = offset + target_velocity * time + Vector3(0.0, 0.5 * gravity * time * time, 0.0)
		time = aim.length() / speed
	aim = offset + target_velocity * time + Vector3(0.0, 0.5 * gravity * time * time, 0.0)
	return aim.normalized()
