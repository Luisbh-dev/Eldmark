class_name ProjectileLaunch
extends RefCounted
## El disparo de un ataque o una habilidad con proyectil en su compromiso (docs/habilidades.md, sección
## 4.4, pasos 2 y 3), compartido por el servidor ([code]ProjectileSystem[/code]) y la flecha predicha
## del cliente ([code]ProjectileWorld[/code], sección 6.2): para que las dos flechas sean la misma, los
## dos lados calculan aquí qué sale, con qué fuente y velocidad, en qué dirección y cuantizado cómo.
## [br][br]
## [b]Qué sale[/b] ([method from_state]): en el tick del compromiso ([method ActionMachine.is_commit_tick])
## de un LIGHT o HEAVY cuyo ataque lleva [member AttackTicks.projectile_id], o de una ABILITY con
## [member AbilityTicks.projectile_id]. La velocidad es [code]projectile_speed_mps ·
## lerp(1, charge_speed_scale, f)[/code] con la [code]f[/code] de la carga del daño (combate.md, sección
## 4.4; 0 sin carga ni en las habilidades).
## [br][br]
## [b]Dirección[/b] ([method launch]): rayo canónico de la cámara ([method AimRay.canonical]) con la
## entrada del tick, punto apuntado con la convergencia ([method AimRay.aim_point]) contra el mundo y las
## cápsulas hostiles que da quien llama (el servidor, rebobinadas; el cliente, tal como se dibujan), salida
## en el pecho ([method AimRay.muzzle]) y, en un abanico, la flecha [code]i[/code] girada en yaw
## [code](i − (n − 1) / 2) · projectile_spread_deg[/code] grados. Origen y velocidad se cuantizan como
## viajan en el SPAWN ([method Ballistics.quantize]): el servidor vuela con eso.
## [br][br]
## Compartido y determinista (sin reloj ni azar): no depende del cliente ni del servidor.

## Id del [ProjectileTicks] (0 = este compromiso no dispara).
var projectile_id: int = 0
## Fuente del disparo ([CombatSource]): la del ataque o la habilidad.
var source: int = 0
## Velocidad de salida (m/s), con la carga ya aplicada.
var speed: float = 0.0
## Proyectiles del disparo (1 a 5) y grados entre dos seguidos del abanico.
var count: int = 1
var spread_deg: float = 0.0
## Fracción de la carga ([code]f[/code], 0 a 1) con la que sale (0 sin carga).
var charge_fraction: float = 0.0


## El disparo que hace [param c] en el tick [param tick] si es el compromiso de un ataque o una habilidad
## con proyectil; null si no dispara.
static func from_state(c: CombatState, tick: int) -> ProjectileLaunch:
	if c == null or not ActionMachine.is_commit_tick(c, tick):
		return null
	match c.action:
		CombatState.Action.LIGHT, CombatState.Action.HEAVY:
			return for_attack(CombatCatalog.attack(c.action_id), c.charge_ticks)
		CombatState.Action.ABILITY:
			return for_ability(CombatCatalog.ability(c.action_id))
	return null


## El disparo del ataque [param attack] lanzado con [param charge_ticks] de carga (null si no dispara).
static func for_attack(attack: AttackTicks, charge_ticks: int) -> ProjectileLaunch:
	if attack == null or attack.projectile_id == 0:
		return null
	var launch := ProjectileLaunch.new()
	launch.projectile_id = attack.projectile_id
	launch.source = CombatSource.make(CombatSource.Kind.ATTACK, attack.id)
	launch.charge_fraction = charge_progress(charge_ticks, attack.charge_min_ticks, attack.charge_max_ticks)
	launch.speed = attack.projectile_speed_mps * lerpf(1.0, attack.charge_speed_scale, launch.charge_fraction)
	return launch


## El disparo de la habilidad [param ability] (null si no dispara).
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


## La [code]f[/code] de la carga (combate.md, sección 4.4): [code](charge − min) / (max − min)[/code]
## limitada a [0, 1]; 0 si el ataque no se carga.
static func charge_progress(charge_ticks: int, charge_min_ticks: int, charge_max_ticks: int) -> float:
	if charge_max_ticks <= charge_min_ticks:
		return 0.0
	return clampf(float(charge_ticks - charge_min_ticks) / float(charge_max_ticks - charge_min_ticks),
			0.0, 1.0)


## Origen y velocidad de cada proyectil del disparo ([code][p0, v0][/code] por índice del abanico, ya
## cuantizados) de un personaje con los pies en [param feet] y la vista [param look_yaw],
## [param look_pitch] y [param left_shoulder] de la entrada del tick. [param space] es el mundo
## ([constant HitShapes.LINE_OF_SIGHT_MASK]; null = sin mundo) y [param hostile_feet], los pies de los
## hostiles para la convergencia.
func launch(feet: Vector3, look_yaw: float, look_pitch: float, left_shoulder: bool,
		space: PhysicsDirectSpaceState3D, hostile_feet: PackedVector3Array) -> Array[PackedVector3Array]:
	var ray: Array = AimRay.canonical(feet, look_yaw, look_pitch, left_shoulder)
	var point: Vector3 = AimRay.aim_point(space, ray[0], ray[1], hostile_feet)
	return launch_toward(AimRay.muzzle(feet), point)


## Como [method launch], con el punto apuntado [param point] ya calculado y la salida en
## [param muzzle]. Una puntería degenerada (el punto en la boca) sale hacia delante en -Z.
func launch_toward(muzzle: Vector3, point: Vector3) -> Array[PackedVector3Array]:
	var direction: Vector3 = point - muzzle
	direction = direction.normalized() if not direction.is_zero_approx() else Vector3.FORWARD
	var shots: Array[PackedVector3Array] = []
	for index: int in count:
		var offset_deg: float = (float(index) - float(count - 1) * 0.5) * spread_deg
		var turned: Vector3 = direction.rotated(Vector3.UP, deg_to_rad(offset_deg)) \
				if offset_deg != 0.0 else direction
		var quantized: Array = Ballistics.quantize(muzzle, turned * speed)
		shots.append(PackedVector3Array([quantized[0], quantized[1]]))
	return shots
