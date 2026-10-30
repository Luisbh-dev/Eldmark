class_name DamageFormula
extends RefCounted
## Fórmula de daño del combate (docs/combate.md, sección 4.4): enteros, sin azar y sin estado.
## Solo la evalúa el servidor, pero es compartida para que las pruebas y las herramientas (el
## medidor de DPS, la interfaz de equilibrado) usen la misma.
## [br][br]
## [codeblock]
## bruto   = base × carga × crítico × damage_scale
## mitig.  = bruto × max(block_mitigation − mitigation_penalty, 0)    (solo si se bloquea)
## final   = roundi((bruto − mitig.) × 1000 / (1000 + armadura)), mínimo 1 si queda algo
## [/codeblock]
## [code]damage_scale[/code] y [code]mitigation_penalty[/code] son los modificadores de los efectos de
## estado (docs/habilidades.md, sección 4.3): [code]1 + Σ DAMAGE_UP[/code] del atacante y
## [code]Σ MITIGATION_DOWN[/code] de la víctima; sin efectos valen 1 y 0 y el resultado es el de
## siempre.
## Bloqueo: el defensor gasta [code]roundi(mitig. × block_stamina_per_damage)[/code] de
## resistencia. Si no le alcanza, el escudo solo absorbe la parte proporcional a la resistencia
## que tenía, el resto pasa como daño y hay rotura de guardia.

## Tipos de daño. En la fase 3 todos los ataques son [code]SLASH[/code] y las resistencias por
## tipo valen 0.
enum DamageType { SLASH, PIERCE, BLUNT, ELEMENTAL }

## Multiplicador de un golpe crítico por la espalda (el valor de
## [code]CombatRules.crit_multiplier[/code]).
const CRIT_MULTIPLIER: float = 1.5
## Ángulo (grados) respecto al yaw de la víctima a partir del cual el golpe es por la espalda
## (el valor de [code]CombatRules.backstab_angle_deg[/code]).
const BACKSTAB_ANGLE_DEG: float = 120.0
## Base de la armadura: con armadura A el daño se multiplica por 1000 / (1000 + A).
const ARMOR_BASE: int = 1000
## Resto de daño a partir del cual «queda algo» y se aplica el mínimo de 1.
const _MIN_REMAINING: float = 0.001
## Por debajo de esta distancia horizontal no hay dirección entre dos posiciones.
const _MIN_DIRECTION_LENGTH: float = 0.0001


## Resultado de [method compute].
class Result:
	## Daño que llega a la vida de la víctima (entero, ya con la armadura).
	var damage: int = 0
	## Daño bruto que ha absorbido el escudo (antes de la armadura). 0 si no se bloqueó.
	var absorbed: int = 0
	## Resistencia que gasta el defensor al bloquear. Nunca más de la que tenía.
	var stamina_cost: int = 0
	## Si el golpe era crítico (el que llama lo decide con [method is_backstab]).
	var critical: bool = false
	## true si el bloqueo no se sostuvo por falta de resistencia: el defensor queda aturdido.
	var guard_break: bool = false


## Factor de carga de un ataque fuerte: [code]lerp(1, charge_damage_scale, f)[/code] con
## [code]f = (charge_ticks − charge_min_ticks) / (charge_max_ticks − charge_min_ticks)[/code]
## limitado a [0, 1]. Vale 1 en un ataque sin carga ([code]charge_max_ticks <= charge_min_ticks[/code])
## y por debajo del mínimo de carga.
static func charge_factor(charge_ticks: int, charge_min_ticks: int, charge_max_ticks: int,
		charge_damage_scale: float) -> float:
	if charge_max_ticks <= charge_min_ticks:
		return 1.0
	var progress: float = clampf(float(charge_ticks - charge_min_ticks)
			/ float(charge_max_ticks - charge_min_ticks), 0.0, 1.0)
	return lerpf(1.0, charge_damage_scale, progress)


## Calcula el daño de un golpe.
## [br][br]
## [b]Firma elegida[/b] (el catálogo [code]AttackTicks[/code] lo escribe otro paquete): en lugar
## del ataque entran sus cuatro datos de daño sueltos, [param base_damage],
## [param charge_min_ticks], [param charge_max_ticks] y [param charge_damage_scale]. Con un ligero
## se pasan 0, 0 y 1.0. [param charge_ticks] es la carga con la que se lanzó el golpe.
## [br][br]
## [param critical] lo decide quien llama (normalmente con [method is_backstab]) y multiplica por
## [param crit_multiplier]. Con [param blocked], [param block_mitigation] (0 a 1) del bruto lo
## absorbe el escudo a cambio de [param block_stamina_per_damage] de resistencia por punto
## absorbido; [param defender_stamina] es la que tiene el defensor. [param armor] (0 o más) reduce
## el daño que pasa.
## [br][br]
## [param damage_scale] (0 o más) multiplica el bruto (más daño del atacante) y
## [param mitigation_penalty] baja la fracción que absorbe el bloqueo (menos mitigación de la
## víctima), sin pasar de 0.
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
			# needed > available >= 0: la guardia aguanta la parte proporcional y se rompe.
			absorbed = mitigated * float(available) / float(needed)
			result.stamina_cost = available
			result.guard_break = true
		result.absorbed = roundi(absorbed)
	var remaining: float = gross - absorbed
	if remaining > _MIN_REMAINING:
		var armor_scale: float = float(ARMOR_BASE) / float(ARMOR_BASE + maxi(armor, 0))
		result.damage = maxi(roundi(remaining * armor_scale), 1)
	return result


## true si [param attacker_pos] está por la espalda de la víctima: a más de
## [param angle_deg] grados (120° por defecto) del yaw del cuerpo de la víctima, medido en
## horizontal. Con el borde exacto no lo es. Un atacante justo encima de la víctima (sin dirección
## horizontal) no la golpea por la espalda.
static func is_backstab(attacker_pos: Vector3, victim_pos: Vector3, victim_yaw: float,
		angle_deg: float = BACKSTAB_ANGLE_DEG) -> bool:
	var offset := Vector2(attacker_pos.x - victim_pos.x, attacker_pos.z - victim_pos.z)
	var distance: float = offset.length()
	if distance < _MIN_DIRECTION_LENGTH:
		return false
	var forward: Vector3 = Basis(Vector3.UP, victim_yaw) * Vector3.FORWARD
	var cos_angle: float = (forward.x * offset.x + forward.z * offset.y) / distance
	return acos(clampf(cos_angle, -1.0, 1.0)) > deg_to_rad(angle_deg)


## true si [param damage_type] es físico (cortante, perforante o contundente): el escudo solo
## frena el daño físico (el elemental queda a criterio de quien resuelve el golpe).
static func is_physical(damage_type: int) -> bool:
	return damage_type == DamageType.SLASH or damage_type == DamageType.PIERCE \
			or damage_type == DamageType.BLUNT
