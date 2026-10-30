extends TestCase
## Pruebas de la fórmula de daño ([DamageFormula], docs/combate.md sección 4.4) con una tabla de
## casos calculados a mano: ligero, fuerte con carga mínima, media y máxima, crítico, bloqueo
## completo y parcial, bloqueo con resistencia insuficiente (paso proporcional y rotura de
## guardia), armadura y mínimo de 1. También el golpe por la espalda ([method
## DamageFormula.is_backstab]).
##
## Datos de los ataques (los valores iniciales de la espada, docs/combate.md sección 2):
## ligero 1 = 90, ligero 3 = 130, fuerte = 180 con carga de 21 a 72 ticks (0,35 s a 1,2 s) y ×1,7
## a carga máxima. Las cuentas están en cada caso.

const LIGHT_1: int = 90
const LIGHT_3: int = 130
const HEAVY: int = 180
const CHARGE_MIN: int = 21
const CHARGE_MAX: int = 72
const CHARGE_SCALE: float = 1.7
## Escudo de la espada: para todo el daño frontal, 1,0 de resistencia por punto absorbido.
const FULL_BLOCK: float = 1.0
const STAMINA_PER_DAMAGE: float = 1.0
const FULL_STAMINA: int = 1000


# --- Ataques sin defensa ----------------------------------------------------------------------

func test_light_attacks_do_base_damage() -> void:
	var result: DamageFormula.Result = _light(LIGHT_1)
	assert_eq(result.damage, 90, "ligero 1: 90")
	assert_eq(result.absorbed, 0, "sin bloqueo no se absorbe nada")
	assert_eq(result.stamina_cost, 0, "sin bloqueo no cuesta resistencia")
	assert_false(result.critical, "no es crítico")
	assert_false(result.guard_break, "ni rompe la guardia")
	assert_eq(_light(LIGHT_3).damage, 130, "ligero 3: 130")
	# Un ligero ignora la carga que se le pase.
	assert_eq(DamageFormula.compute(LIGHT_1, 50, 0, 0, 1.0, false, false, 0.0, 0.0, 0, 0).damage, 90,
			"un ligero no se escala por la carga")


func test_heavy_scales_with_charge() -> void:
	# carga = 1 + (1,7 - 1) · (ticks - 21) / (72 - 21).
	assert_eq(_heavy(21).damage, 180, "carga mínima (21 ticks): ×1 = 180")
	assert_eq(_heavy(8).damage, 180, "por debajo del mínimo: ×1 = 180")
	# 46 ticks: 1 + 0,7 · 25 / 51 = 1,343137 -> 180 · 1,343137 = 241,76 -> 242.
	assert_eq(_heavy(46).damage, 242, "carga media (46 ticks): 242")
	assert_eq(_heavy(72).damage, 306, "carga máxima (72 ticks): ×1,7 = 306")
	assert_eq(_heavy(200).damage, 306, "más allá del máximo no crece: 306")
	# Con una carga de 20 a 60 ticks, a mitad (40) el factor es 1,35: 180 · 1,35 = 243.
	assert_eq(DamageFormula.compute(HEAVY, 40, 20, 60, CHARGE_SCALE, false, false, 0.0, 0.0, 0,
			0).damage, 243, "carga justo a mitad de un rango limpio: 243")


func test_charge_factor() -> void:
	assert_near(DamageFormula.charge_factor(21, 21, 72, 1.7), 1.0, 1e-9, "mínimo")
	assert_near(DamageFormula.charge_factor(72, 21, 72, 1.7), 1.7, 1e-9, "máximo")
	assert_near(DamageFormula.charge_factor(40, 20, 60, 1.7), 1.35, 1e-9, "mitad")
	assert_near(DamageFormula.charge_factor(0, 21, 72, 1.7), 1.0, 1e-9, "por debajo")
	assert_near(DamageFormula.charge_factor(999, 21, 72, 1.7), 1.7, 1e-9, "por encima")
	assert_near(DamageFormula.charge_factor(30, 0, 0, 1.7), 1.0, 1e-9, "sin rango de carga")
	assert_near(DamageFormula.charge_factor(30, 60, 20, 1.7), 1.0, 1e-9, "rango invertido")


# --- Críticos ---------------------------------------------------------------------------------

func test_critical_multiplies_by_one_and_a_half() -> void:
	var result: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, true, false,
			0.0, 0.0, 0, 0)
	assert_eq(result.damage, 135, "ligero crítico: 90 · 1,5 = 135")
	assert_true(result.critical, "el resultado recuerda el crítico")
	var heavy_critical: DamageFormula.Result = DamageFormula.compute(HEAVY, CHARGE_MAX,
			CHARGE_MIN, CHARGE_MAX, CHARGE_SCALE, true, false, 0.0, 0.0, 0, 0)
	assert_eq(heavy_critical.damage, 459, "fuerte a carga máxima crítico: 306 · 1,5 = 459")
	# Un multiplicador propio.
	assert_eq(DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, true, false, 0.0, 0.0, 0, 0,
			2.0).damage, 180, "crítico ×2: 180")
	# Sin crítico el multiplicador no cuenta.
	assert_eq(DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, false, 0.0, 0.0, 0, 0,
			2.0).damage, 90, "sin crítico, ×1")


# --- Bloqueo ----------------------------------------------------------------------------------

func test_full_block_absorbs_everything() -> void:
	var result: DamageFormula.Result = _blocked(LIGHT_1, FULL_BLOCK, FULL_STAMINA)
	assert_eq(result.damage, 0, "bloqueo completo: no pasa daño (y el mínimo de 1 no aplica)")
	assert_eq(result.absorbed, 90, "el escudo absorbe los 90")
	assert_eq(result.stamina_cost, 90, "cuesta 90 de resistencia (1,0 por punto)")
	assert_false(result.guard_break, "con resistencia de sobra no se rompe la guardia")
	# El fuerte a carga máxima: 306 puntos, 306 de resistencia.
	var heavy: DamageFormula.Result = DamageFormula.compute(HEAVY, CHARGE_MAX, CHARGE_MIN,
			CHARGE_MAX, CHARGE_SCALE, false, true, FULL_BLOCK, STAMINA_PER_DAMAGE, FULL_STAMINA, 0)
	assert_eq(heavy.damage, 0, "fuerte cargado bloqueado: 0")
	assert_eq(heavy.absorbed, 306, "absorbe 306")
	assert_eq(heavy.stamina_cost, 306, "cuesta 306")
	assert_false(heavy.guard_break, "con 1000 de resistencia no se rompe")


func test_partial_mitigation_lets_damage_through() -> void:
	# Mitigación 0,8: absorbe 72 de 90, pasan 18; a 1,0 por punto cuesta 72.
	var result: DamageFormula.Result = _blocked(LIGHT_1, 0.8, FULL_STAMINA)
	assert_eq(result.damage, 18, "pasan 18")
	assert_eq(result.absorbed, 72, "se absorben 72")
	assert_eq(result.stamina_cost, 72, "cuesta 72")
	assert_false(result.guard_break, "no se rompe la guardia")
	# Con 2,0 de resistencia por punto absorbido: cuesta 144.
	var costly: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, true,
			0.8, 2.0, FULL_STAMINA, 0)
	assert_eq(costly.stamina_cost, 144, "2,0 por punto: 144")
	assert_eq(costly.damage, 18, "el daño que pasa no cambia")
	# Sin mitigación (0) un bloqueo no protege de nada y no cuesta nada.
	var none: DamageFormula.Result = _blocked(LIGHT_1, 0.0, FULL_STAMINA)
	assert_eq(none.damage, 90, "mitigación 0: pasa todo")
	assert_eq(none.stamina_cost, 0, "y no cuesta resistencia")


func test_block_without_enough_stamina_breaks_guard_and_passes_proportionally() -> void:
	# Fuerte a carga máxima (306) con mitigación total y 1,0 por punto: la guardia necesita 306.
	# Con 100 de resistencia aguanta 100/306 del golpe: absorbe 100, pasan 206.
	var result: DamageFormula.Result = _blocked_heavy_max(100)
	assert_eq(result.absorbed, 100, "absorbe la parte que alcanza: 100")
	assert_eq(result.damage, 206, "pasan los otros 206")
	assert_eq(result.stamina_cost, 100, "gasta toda la resistencia que tenía")
	assert_true(result.guard_break, "rotura de guardia")
	# Justo la resistencia necesaria: aguanta.
	var exact: DamageFormula.Result = _blocked_heavy_max(306)
	assert_eq(exact.damage, 0, "306 de resistencia: aguanta entero")
	assert_eq(exact.stamina_cost, 306, "gasta 306")
	assert_false(exact.guard_break, "y no se rompe")
	# Una menos: la guardia cede y pasa 1 punto (mínimo 1 al quedar algo).
	var short: DamageFormula.Result = _blocked_heavy_max(305)
	assert_eq(short.absorbed, 305, "absorbe 305")
	assert_eq(short.damage, 1, "pasa 1")
	assert_eq(short.stamina_cost, 305, "gasta 305")
	assert_true(short.guard_break, "rotura de guardia por un punto")
	# Sin nada de resistencia el escudo no absorbe: pasa el golpe entero y la guardia se rompe.
	var empty: DamageFormula.Result = _blocked_heavy_max(0)
	assert_eq(empty.absorbed, 0, "sin resistencia no absorbe")
	assert_eq(empty.damage, 306, "pasa todo")
	assert_eq(empty.stamina_cost, 0, "no tiene nada que gastar")
	assert_true(empty.guard_break, "rotura de guardia")
	# Una resistencia negativa (no debería ocurrir) cuenta como 0.
	assert_eq(_blocked_heavy_max(-5).damage, 306, "resistencia negativa = 0")
	# Proporcional con mitigación parcial: ligero 90, mitigación 0,8 (72), 2,0 por punto (144),
	# 72 de resistencia: aguanta 72/144 = la mitad de los 72 -> absorbe 36, pasan 90 - 36 = 54.
	var partial: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, true,
			0.8, 2.0, 72, 0)
	assert_eq(partial.absorbed, 36, "mitigación parcial sin resistencia suficiente: absorbe 36")
	assert_eq(partial.damage, 54, "pasan 54")
	assert_eq(partial.stamina_cost, 72, "gasta las 72")
	assert_true(partial.guard_break, "rotura de guardia")


# --- Armadura y mínimo ------------------------------------------------------------------------

func test_armor_reduces_damage_that_passes() -> void:
	# final = daño · 1000 / (1000 + armadura).
	assert_eq(_armored(LIGHT_1, 0), 90, "armadura 0: 90")
	assert_eq(_armored(LIGHT_1, 1000), 45, "armadura 1000: la mitad = 45")
	assert_eq(_armored(LIGHT_1, 500), 60, "armadura 500: 90 · 1000 / 1500 = 60")
	assert_eq(_armored(LIGHT_1, 9000), 9, "armadura 9000: una décima parte = 9")
	# La armadura se aplica después del crítico y del bloqueo.
	# Ligero 3 crítico: 195; bloqueo 0,4 -> absorbe 78, quedan 117; armadura 300 -> 117 / 1,3 = 90.
	var combined: DamageFormula.Result = DamageFormula.compute(LIGHT_3, 0, 0, 0, 1.0, true, true,
			0.4, 1.5, FULL_STAMINA, 300)
	assert_eq(combined.damage, 90, "crítico + bloqueo parcial + armadura = 90")
	assert_eq(combined.absorbed, 78, "el escudo absorbe 78 (antes de la armadura)")
	assert_eq(combined.stamina_cost, 117, "78 · 1,5 = 117 de resistencia")
	assert_true(combined.critical, "y sigue siendo crítico")


func test_minimum_one_damage_when_something_passes() -> void:
	# 1 de daño base con armadura 4000: 1 · 1000 / 5000 = 0,2 -> redondea a 0 -> mínimo 1.
	assert_eq(_armored(1, 4000), 1, "una décima o menos que pase sigue siendo 1")
	# Bloqueo casi completo: de 1 punto absorbe 0,9 y pasa 0,1 -> 1.
	assert_eq(_blocked(1, 0.9, FULL_STAMINA).damage, 1, "lo que pasa de un bloqueo casi total es 1")
	# Pero con un bloqueo total no queda nada y no hay mínimo.
	assert_eq(_blocked(1, 1.0, FULL_STAMINA).damage, 0, "bloqueo total de 1: 0")
	# Sin daño base no hay mínimo.
	assert_eq(_light(0).damage, 0, "un ataque sin daño no hace daño")
	# Una armadura enorme no divide por cero ni da negativos.
	assert_eq(_armored(LIGHT_1, 1000000), 1, "armadura enorme: 1")
	assert_eq(_armored(LIGHT_1, -2000), 90, "una armadura negativa cuenta como 0")


# --- Golpe por la espalda ---------------------------------------------------------------------

func test_is_backstab_angle() -> void:
	var victim := Vector3(3.0, 0.0, -2.0)
	# Víctima mirando a -Z (yaw 0). El atacante a 3 m con un ángulo respecto a su frente.
	assert_false(DamageFormula.is_backstab(victim + Vector3(0.0, 0.0, -3.0), victim, 0.0),
			"de frente")
	assert_false(DamageFormula.is_backstab(victim + Vector3(3.0, 0.0, 0.0), victim, 0.0),
			"de lado (90°)")
	assert_true(DamageFormula.is_backstab(victim + Vector3(0.0, 0.0, 3.0), victim, 0.0),
			"justo por la espalda (180°)")
	for side: float in [1.0, -1.0]:
		var inside: Vector3 = victim + _polar(3.0, side * deg_to_rad(120.0 - 0.05))
		var outside: Vector3 = victim + _polar(3.0, side * deg_to_rad(120.0 + 0.05))
		assert_false(DamageFormula.is_backstab(inside, victim, 0.0),
				"a 119,95° todavía no (lado %d)" % int(side))
		assert_true(DamageFormula.is_backstab(outside, victim, 0.0),
				"a 120,05° ya sí (lado %d)" % int(side))
	# Con la víctima mirando a otro sitio (yaw 90°: hacia -X) la espalda es +X.
	assert_true(DamageFormula.is_backstab(victim + Vector3(3.0, 0.0, 0.0), victim, PI * 0.5),
			"yaw 90°: el +X es la espalda")
	assert_false(DamageFormula.is_backstab(victim + Vector3(-3.0, 0.0, 0.0), victim, PI * 0.5),
			"yaw 90°: el -X es el frente")
	# La altura no cuenta; encima exactamente, tampoco.
	assert_true(DamageFormula.is_backstab(victim + Vector3(0.0, 6.0, 3.0), victim, 0.0),
			"atacante en lo alto pero por detrás")
	assert_false(DamageFormula.is_backstab(victim + Vector3(0.0, 6.0, 0.0), victim, 0.0),
			"justo encima: sin dirección, no es por la espalda")
	# Otro ángulo.
	assert_true(DamageFormula.is_backstab(victim + Vector3(3.0, 0.0, 0.0), victim, 0.0, 80.0),
			"con un umbral de 80°, el flanco (90°) cuenta")


func test_is_physical() -> void:
	assert_true(DamageFormula.is_physical(DamageFormula.DamageType.SLASH), "cortante")
	assert_true(DamageFormula.is_physical(DamageFormula.DamageType.PIERCE), "perforante")
	assert_true(DamageFormula.is_physical(DamageFormula.DamageType.BLUNT), "contundente")
	assert_false(DamageFormula.is_physical(DamageFormula.DamageType.ELEMENTAL), "elemental")


# --- Utilidades -------------------------------------------------------------------------------

## Golpe ligero sin defensa ni armadura.
func test_status_modifiers_scale_the_damage_and_lower_the_mitigation() -> void:
	# docs/habilidades.md, sección 4.3: damage_scale = 1 + Σ DAMAGE_UP y mitigation_penalty = Σ
	# MITIGATION_DOWN; sin efectos, lo de siempre.
	var plain: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, false, 1.0,
			STAMINA_PER_DAMAGE, FULL_STAMINA, 0)
	var neutral: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, false, 1.0,
			STAMINA_PER_DAMAGE, FULL_STAMINA, 0, DamageFormula.CRIT_MULTIPLIER, 1.0, 0.0)
	assert_eq(neutral.damage, plain.damage, "con 1 y 0, el mismo daño")
	var stronger: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, true, false, 1.0,
			STAMINA_PER_DAMAGE, FULL_STAMINA, 0, DamageFormula.CRIT_MULTIPLIER, 1.2, 0.0)
	assert_eq(stronger.damage, roundi(LIGHT_1 * 1.5 * 1.2), "más daño: multiplica el bruto (con el crítico)")
	var blocked: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, true, 1.0,
			STAMINA_PER_DAMAGE, FULL_STAMINA, 0, DamageFormula.CRIT_MULTIPLIER, 1.0, 0.25)
	assert_eq(blocked.absorbed, roundi(LIGHT_1 * 0.75), "menos mitigación: el escudo absorbe un 25 % menos")
	assert_eq(blocked.damage, roundi(LIGHT_1 * 0.25), "y pasa el resto")
	assert_eq(blocked.stamina_cost, roundi(LIGHT_1 * 0.75 * STAMINA_PER_DAMAGE), "pagando solo lo absorbido")
	var floor_zero: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, true, 0.5,
			STAMINA_PER_DAMAGE, FULL_STAMINA, 0, DamageFormula.CRIT_MULTIPLIER, 1.0, 0.8)
	assert_eq(floor_zero.absorbed, 0, "la mitigación no baja de 0")
	assert_eq(floor_zero.damage, LIGHT_1, "y pasa todo")
	var negative: DamageFormula.Result = DamageFormula.compute(LIGHT_1, 0, 0, 0, 1.0, false, false, 1.0,
			STAMINA_PER_DAMAGE, FULL_STAMINA, 0, DamageFormula.CRIT_MULTIPLIER, -1.0, 0.0)
	assert_eq(negative.damage, 0, "un multiplicador negativo cuenta como 0")


func _light(base: int) -> DamageFormula.Result:
	return DamageFormula.compute(base, 0, 0, 0, 1.0, false, false, 0.0, 0.0, 0, 0)


## Golpe fuerte (180) con [param charge_ticks] de carga, sin defensa ni armadura.
func _heavy(charge_ticks: int) -> DamageFormula.Result:
	return DamageFormula.compute(HEAVY, charge_ticks, CHARGE_MIN, CHARGE_MAX, CHARGE_SCALE, false,
			false, 0.0, 0.0, 0, 0)


## Golpe ligero bloqueado con la [param mitigation] dada y 1,0 de resistencia por punto.
func _blocked(base: int, mitigation: float, stamina: int) -> DamageFormula.Result:
	return DamageFormula.compute(base, 0, 0, 0, 1.0, false, true, mitigation, STAMINA_PER_DAMAGE,
			stamina, 0)


## Fuerte a carga máxima (306) bloqueado del todo por un defensor con [param stamina].
func _blocked_heavy_max(stamina: int) -> DamageFormula.Result:
	return DamageFormula.compute(HEAVY, CHARGE_MAX, CHARGE_MIN, CHARGE_MAX, CHARGE_SCALE, false,
			true, FULL_BLOCK, STAMINA_PER_DAMAGE, stamina, 0)


## Daño final de un golpe sin bloqueo contra [param armor].
func _armored(base: int, armor: int) -> int:
	return DamageFormula.compute(base, 0, 0, 0, 1.0, false, false, 0.0, 0.0, 0, armor).damage


## Punto horizontal a [param distance] del origen girado [param angle] radianes desde -Z hacia
## +X (positivo) o -X (negativo).
func _polar(distance: float, angle: float) -> Vector3:
	return Vector3(distance * sin(angle), 0.0, -distance * cos(angle))
