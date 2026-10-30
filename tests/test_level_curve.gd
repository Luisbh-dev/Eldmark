extends TestCase
## Pruebas de la curva de niveles ([LevelCurve], [code]data/progression/level_curve.tres[/code]) y de la
## subida ([ProgressionRules]; docs/progresion.md §6, PRG-13): 39 valores crecientes, la tabla de §6.1,
## [code]level_for(total_to(n)) = n[/code], varias subidas con un solo aporte y el tope.


func _curve() -> LevelCurve:
	return LevelCurve.shared()


func test_resource_is_text_and_valid() -> void:
	var text: String = FileAccess.get_file_as_string(LevelCurve.PATH)
	assert_true(text.begins_with("[gd_resource"), "%s está en formato texto" % LevelCurve.PATH)
	var curve: LevelCurve = _curve()
	assert_eq(curve.resource_path, LevelCurve.PATH, "shared() carga el recurso del repositorio")
	assert_eq(curve.get_errors(), PackedStringArray(), "la curva no tiene errores")
	assert_eq(curve.level_cap, 40, "tope 40 (§6.1)")
	assert_eq(curve.attribute_points_per_level, 1, "un punto de atributo por nivel")


func test_39_increasing_values() -> void:
	var values: PackedInt32Array = _curve().xp_to_next
	assert_eq(values.size(), 39, "39 valores, del nivel 1 al 39")
	for i: int in range(1, values.size()):
		assert_true(values[i] > values[i - 1], "xp_to_next[%d] = %d > %d" % [i, values[i], values[i - 1]])


## La tabla de §6.1 y la fórmula con que se generó (el dato es la tabla: si se retoca una cifra a mano,
## esta comprobación de la fórmula se cambia con ella).
func test_table_of_the_document() -> void:
	var curve: LevelCurve = _curve()
	var expected: Dictionary[int, Array] = {1: [500, 500], 5: [1880, 5350], 10: [5550, 25060],
			20: [17180, 140320], 39: [51050, 783780]}
	for level: int in expected:
		assert_eq(curve.xp_for_next(level), expected[level][0], "XP del nivel %d al siguiente" % level)
		assert_eq(curve.total_to(level + 1), expected[level][1], "XP total para llegar al %d" % (level + 1))
	for level: int in range(1, 40):
		var generated: int = roundi((500.0 + 150.0 * pow(level - 1, 1.6)) / 10.0) * 10
		assert_eq(curve.xp_to_next[level - 1], generated, "nivel %d: la fórmula de §6.1" % level)


func test_level_for_total_to() -> void:
	var curve: LevelCurve = _curve()
	assert_eq(curve.total_to(1), 0, "el nivel 1 empieza en 0")
	assert_eq(curve.level_for(0), 1, "0 de XP es nivel 1")
	assert_eq(curve.level_for(-5), 1, "negativo, nivel 1")
	for level: int in range(1, 41):
		assert_eq(curve.level_for(curve.total_to(level)), level, "level_for(total_to(%d))" % level)
		if level > 1:
			assert_eq(curve.level_for(curve.total_to(level) - 1), level - 1,
					"un punto antes de llegar al %d se sigue en el %d" % [level, level - 1])
	assert_eq(curve.level_for(curve.total_to(40) + 1_000_000), 40, "por encima del tope, el tope")
	assert_eq(curve.total_to(41), curve.total_to(40), "total_to por encima del tope es el del tope")
	assert_eq(curve.total_to(0), 0, "total_to por debajo de 1 es 0")
	assert_eq(curve.xp_for_next(40), 0, "en el tope no hay siguiente")


func test_one_gain_several_levels() -> void:
	var curve: LevelCurve = _curve()
	# Del 1 al 6 de golpe: 5350 de XP justos.
	var result: ProgressionRules.XpResult = ProgressionRules.add_xp(curve, 1, 0, 5350)
	assert_eq(result.level, 6, "5350 de XP llevan al nivel 6")
	assert_eq(result.levels_gained, 5, "cinco niveles con un solo aporte")
	assert_eq(result.applied, 5350, "se aplica todo")
	assert_eq(result.xp_total, 5350, "total")
	# A mitad de nivel: 8 con 12345 (el ejemplo de §3.4) y 20000 más.
	assert_eq(curve.level_for(12345), 8, "12345 de XP es nivel 8 (§3.4)")
	result = ProgressionRules.add_xp(curve, 8, 12345, 20000)
	assert_eq(result.xp_total, 32345, "suma")
	assert_eq(result.level, curve.level_for(32345), "nivel recalculado")
	assert_eq(result.levels_gained, result.level - 8, "niveles ganados")
	assert_true(result.levels_gained >= 2, "varias subidas (%d)" % result.levels_gained)
	# Sin subir.
	result = ProgressionRules.add_xp(curve, 1, 0, 499)
	assert_eq([result.level, result.levels_gained, result.applied], [1, 0, 499], "499 no sube del 1")


func test_cap() -> void:
	var curve: LevelCurve = _curve()
	var cap_total: int = curve.total_to(40)
	var result: ProgressionRules.XpResult = ProgressionRules.add_xp(curve, 40, cap_total, 500)
	assert_eq([result.level, result.xp_total, result.applied, result.levels_gained], [40, cap_total, 0, 0],
			"en el tope se aplica 0 y el total se queda")
	result = ProgressionRules.add_xp(curve, 39, cap_total - 100, 500)
	assert_eq([result.level, result.xp_total, result.applied, result.levels_gained], [40, cap_total, 100, 1],
			"cerca del tope se aplica solo lo que falta")
	result = ProgressionRules.add_xp(curve, 1, 0, 10_000_000)
	assert_eq([result.level, result.xp_total, result.applied, result.levels_gained],
			[40, cap_total, cap_total, 39], "un aporte enorme llega al tope desde el 1")
	result = ProgressionRules.add_xp(curve, 40, cap_total + 999, 10)
	assert_eq([result.level, result.xp_total, result.applied], [40, cap_total, 0],
			"un total por encima del tope se lleva al tope (I8)")


func test_non_positive_gain_applies_nothing() -> void:
	var curve: LevelCurve = _curve()
	for amount: int in [0, -1, -100000]:
		var result: ProgressionRules.XpResult = ProgressionRules.add_xp(curve, 3, 1200, amount)
		assert_eq([result.level, result.xp_total, result.applied, result.levels_gained], [3, 1200, 0, 0],
				"add_xp(%d) no cambia nada" % amount)


func test_attribute_points() -> void:
	var curve: LevelCurve = _curve()
	assert_eq(ProgressionRules.attribute_points(curve, 1, 0), 0, "nivel 1, ninguno")
	assert_eq(ProgressionRules.attribute_points(curve, 10, 0), 9, "nivel 10, 9")
	assert_eq(ProgressionRules.attribute_points(curve, 10, 4), 5, "menos los gastados")
	assert_eq(ProgressionRules.attribute_points(curve, 10, 20), 0, "nunca menos de 0")
	assert_eq(ProgressionRules.attribute_points(curve, 99, 0), 39, "por encima del tope, los del tope")
	assert_eq(ProgressionRules.XP_PER_MERIT, 10, "10 de XP por mérito (§6.2)")


func test_errors_of_a_broken_curve() -> void:
	var curve := LevelCurve.new()
	curve.level_cap = 4
	curve.xp_to_next = PackedInt32Array([100, 0])
	var errors: PackedStringArray = curve.get_errors()
	assert_eq(errors.size(), 2, "faltan valores y hay un 0: %s" % [errors])
	# Sin datos suficientes no se pasa de lo que hay.
	assert_eq(curve.level_for(1_000_000), 3, "con dos pasos se llega al 3")
	assert_eq(curve.total_to(4), 100, "total_to suma solo lo que hay")
