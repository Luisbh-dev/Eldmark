extends TestCase
## Pruebas de [CombatCatalog] (docs/combate.md sección 2; docs/habilidades.md sección 2.2): carga de
## data/combat/, IDs de cada espacio pedidos por nombre, ids repetidos, validación de rangos y de las
## reglas de la sección 2.2, conversión a ticks, curvas horneadas (esquiva y avances), golpe
## sintetizado de las habilidades, huella de la parte predicha y el camino rápido de simulate().

const DATA_DIR: String = "res://data/combat"


func after_each() -> void:
	# Algunas pruebas construyen catálogos aparte; el global no se toca, pero por si acaso.
	CombatCatalog.reload()


# --- Carga y IDs ------------------------------------------------------------------------------

func test_data_directory_loads_without_errors() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	assert_eq(tables.errors, PackedStringArray(), "los datos de data/combat/ son válidos")
	assert_true(tables.is_valid(), "is_valid()")
	assert_eq(_names_starting_with(tables.attack_ids, "sword_").size(), 4, "4 ataques de espada: fuerte y tres ligeros")
	assert_eq(_names_starting_with(tables.weapon_ids, "sword_").size(), 1, "un arma de jugador: espada y escudo")
	assert_eq(_names_starting_with(tables.attack_ids, "npc_").size(), 8, "8 ataques de PNJ (ligero y fuerte de 4 armas)")
	assert_eq(_names_starting_with(tables.weapon_ids, "npc_").size(), 4, "4 armas de PNJ")
	assert_eq(_names_starting_with(tables.attack_ids, "bow_").size(), 2, "2 ataques de arco: rápido y tensado")
	assert_eq(_names_starting_with(tables.weapon_ids, "bow").size(), 1, "el arco")
	assert_eq(tables.attacks.size(), 14, "14 ataques en total")
	assert_eq(tables.weapons.size(), 6, "6 armas en total")
	assert_eq(tables.abilities.size(), 8, "6 habilidades (3 de espada y escudo, 3 de arco) y 2 pociones")
	assert_eq(tables.statuses.size(), 4, "4 efectos: bleed, potion_regen, rooted y slowed")
	assert_eq(tables.projectiles.size(), 1, "un proyectil: la flecha")
	assert_eq(tables.templates.size(), 2, "2 plantillas: escudero y tirador")
	assert_not_null(tables.rules, "hay reglas")


func test_global_catalog_matches_the_directory() -> void:
	CombatCatalog.reload()
	var tables: CombatTables = CombatCatalog.tables()
	assert_true(tables.is_valid(), "el catálogo global carga bien")
	assert_eq(CombatCatalog.prediction_hash(),
			CombatCatalog.build_from_directory(DATA_DIR).prediction_hash,
			"la huella global es la de leer la carpeta")
	assert_same(CombatCatalog.tables(), tables, "las tablas se cargan una sola vez (perezosa)")
	assert_same(CombatCatalog.rules(), tables.rules, "rules()")


func test_ids_are_alphabetical_from_one() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	# Los IDs salen del orden alfabético de los nombres: nada puede depender de un número fijo (los ataques y
	# las armas de PNJ, que empiezan por npc_, van antes que los de la espada).
	var attack_names: Array[String] = _sorted_names(tables.attack_ids)
	for i: int in attack_names.size():
		assert_eq(tables.attack_ids[StringName(attack_names[i])], i + 1,
				"%s es el ataque número %d" % [attack_names[i], i + 1])
	var weapon_names: Array[String] = _sorted_names(tables.weapon_ids)
	for i: int in weapon_names.size():
		assert_eq(tables.weapon_ids[StringName(weapon_names[i])], i + 1,
				"%s es el arma número %d" % [weapon_names[i], i + 1])
	assert_true(tables.attack_ids[&"npc_captain_crush"] < tables.attack_ids[&"sword_heavy"],
			"los ataques de PNJ van antes que los de la espada")
	assert_eq(tables.attack_ids[&"sword_light_2"], tables.attack_ids[&"sword_light_1"] + 1, "sword_light_2")
	assert_eq(tables.attack_ids[&"sword_light_3"], tables.attack_ids[&"sword_light_2"] + 1, "sword_light_3")
	assert_eq(tables.attack_ids[&"sword_heavy"], tables.attack_ids[&"sword_light_1"] - 1, "sword_heavy va antes")
	assert_null(tables.attack(0), "el ID 0 es «ninguno» en los ataques")
	assert_null(tables.weapon(0), "y en las armas")
	assert_null(tables.attack(tables.attacks.size() + 1), "un ID que no existe")
	assert_null(tables.weapon(tables.weapons.size() + 1), "un arma que no existe")
	assert_null(tables.attack(-1), "un ID negativo")
	for i: int in tables.attacks.size():
		assert_eq(tables.attacks[i].id, i + 1, "el ataque en el índice %d lleva el ID %d" % [i, i + 1])
		assert_eq(tables.attack(i + 1), tables.attacks[i], "attack(%d)" % (i + 1))
	var light_one: int = tables.attack_ids[&"sword_light_1"]
	assert_eq(tables.attack(light_one).name, &"sword_light_1", "el nombre se conserva")
	assert_eq(CombatCatalog.attack_id(&"sword_light_2"), light_one + 1, "attack_id() por nombre")
	assert_eq(CombatCatalog.weapon_id(&"sword_shield"), tables.weapon_ids[&"sword_shield"], "weapon_id() por nombre")
	assert_eq(CombatCatalog.attack_id(&"no_existe"), 0, "un nombre que no existe da 0")
	assert_eq(CombatCatalog.default_weapon_id(), tables.weapon_ids[&"sword_shield"],
			"el arma por defecto es la espada y escudo")


func test_ids_do_not_depend_on_the_order_the_resources_come_in() -> void:
	var a: AttackDefinition = _attack(&"b_attack")
	var b: AttackDefinition = _attack(&"a_attack")
	var c: AttackDefinition = _attack(&"c_attack")
	var rules := CombatRules.new()
	var forward: Array[Resource] = [rules, a, b, c]
	var backward: Array[Resource] = [c, b, a, rules]
	var first: CombatTables = CombatCatalog.build_from_resources(forward)
	var second: CombatTables = CombatCatalog.build_from_resources(backward)
	assert_eq(first.attack_ids, second.attack_ids, "mismos IDs")
	assert_eq(first.attack_ids[&"a_attack"], 1, "a_attack primero")
	assert_eq(first.attack_ids[&"b_attack"], 2, "b_attack segundo")
	assert_eq(first.attack_ids[&"c_attack"], 3, "c_attack tercero")
	assert_eq(first.prediction_hash, second.prediction_hash, "y la misma huella")


func test_duplicate_attack_id_is_an_error() -> void:
	var first: AttackDefinition = _attack(&"golpe")
	var second: AttackDefinition = _attack(&"golpe")
	var resources: Array[Resource] = [CombatRules.new(), first, second]
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	assert_false(tables.is_valid(), "un id repetido invalida el catálogo")
	assert_true(_has_error(tables.errors, "id de ataque repetido: golpe"), _errors_text(tables.errors))
	assert_eq(tables.attacks.size(), 1, "solo se queda uno")


func test_the_same_attack_object_twice_is_not_a_duplicate() -> void:
	# Un ataque que cuelga de un arma y además está suelto en la carpeta es el mismo objeto.
	var weapon: WeaponDefinition = _weapon(&"arma")
	var resources: Array[Resource] = [CombatRules.new(), weapon, weapon.heavy_attack,
			weapon.light_combo[0], weapon]
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	assert_eq(tables.errors, PackedStringArray(), "sin errores")
	assert_eq(tables.attacks.size(), 4, "4 ataques, ninguno contado dos veces")
	assert_eq(tables.weapons.size(), 1, "una sola arma")


func test_duplicate_weapon_id_is_an_error() -> void:
	var resources: Array[Resource] = [CombatRules.new(), _weapon(&"arma", &"a"), _weapon(&"arma", &"b")]
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	assert_true(_has_error(tables.errors, "id de arma repetido: arma"), _errors_text(tables.errors))


func test_empty_ids_are_errors() -> void:
	var nameless: AttackDefinition = _attack(&"")
	var resources: Array[Resource] = [CombatRules.new(), nameless]
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	assert_true(_has_error(tables.errors, "un ataque no tiene id"), _errors_text(tables.errors))
	var weapon_nameless: WeaponDefinition = _weapon(&"")
	var weapons: Array[Resource] = [CombatRules.new(), weapon_nameless]
	assert_true(_has_error(CombatCatalog.build_from_resources(weapons).errors, "un arma no tiene id"),
			"un arma sin id")


func test_missing_rules_is_an_error_but_defaults_exist() -> void:
	var resources: Array[Resource] = [_attack(&"x")]
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	assert_true(_has_error(tables.errors, "falta un recurso CombatRules"), _errors_text(tables.errors))
	assert_not_null(tables.rules, "aun así hay unas reglas por defecto")
	var two: Array[Resource] = [CombatRules.new(), CombatRules.new()]
	assert_true(_has_error(CombatCatalog.build_from_resources(two).errors, "hay 2 recursos CombatRules"),
			"dos reglas")


func test_unknown_resources_are_ignored() -> void:
	var resources: Array[Resource] = [CombatRules.new(), HitShape.new(), DodgeDefinition.new(),
			Curve.new()]
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	assert_eq(tables.errors, PackedStringArray(), "los demás recursos no son un problema")
	assert_eq(tables.attacks.size(), 0, "no hay ataques")


# --- Validación de rangos ---------------------------------------------------------------------

func test_attack_validation_detects_bad_values() -> void:
	var cases: Dictionary[String, String] = {
		"duraciones no pueden ser negativas": "negative",
		"dura 0 ticks": "zero",
		"ventana de combo debe caber": "combo",
		"cancel_to_dodge_from_s fuera": "cancel",
		"stamina_cost fuera de rango": "cost",
		"falta la forma del golpe": "shape",
		"daño base negativo": "damage",
		"damage_type fuera de rango": "type",
		"tambaleo o empuje fuera de rango": "knockback",
		"velocidad, giro o avance negativos": "speed",
	}
	for expected: String in cases:
		var attack: AttackDefinition = _attack(&"malo")
		_break_attack(attack, cases[expected])
		var resources: Array[Resource] = [CombatRules.new(), attack]
		var tables: CombatTables = CombatCatalog.build_from_resources(resources)
		assert_true(_has_error(tables.errors, expected), "«%s»: %s" % [expected, _errors_text(tables.errors)])


func test_heavy_attack_validation_checks_the_charge() -> void:
	var heavy: AttackDefinition = _heavy(&"fuerte")
	heavy.charge_min_s = 2.0
	heavy.charge_max_s = 1.0
	var resources: Array[Resource] = [CombatRules.new(), heavy]
	assert_true(_has_error(CombatCatalog.build_from_resources(resources).errors, "la carga debe cumplir"),
			"mínima mayor que la máxima")
	heavy.charge_min_s = 0.35
	heavy.charge_max_s = 5.0
	assert_true(_has_error(CombatCatalog.build_from_resources(resources).errors, "la carga debe cumplir"),
			"la carga máxima no cabe en 255 ticks")
	heavy.charge_max_s = 1.2
	heavy.charge_damage_scale = 0.5
	assert_true(_has_error(CombatCatalog.build_from_resources(resources).errors, "charge_damage_scale"),
			"escala de daño menor que 1")


func test_weapon_validation_detects_bad_values() -> void:
	var cases: Dictionary[String, String] = {
		"el combo ligero debe tener de 1 a 3 golpes": "combo",
		"falta el ataque fuerte": "heavy",
		"falta la esquiva": "dodge",
		"block_mitigation fuera de rango": "mitigation",
		"parámetros de bloqueo negativos": "negative",
	}
	for expected: String in cases:
		var weapon: WeaponDefinition = _weapon(&"arma")
		match cases[expected]:
			"combo":
				weapon.light_combo.clear()
			"heavy":
				weapon.heavy_attack = null
			"dodge":
				weapon.dodge = null
			"mitigation":
				weapon.block_mitigation = 1.5
			"negative":
				weapon.block_move_scale = -0.1
		var resources: Array[Resource] = [CombatRules.new(), weapon]
		var tables: CombatTables = CombatCatalog.build_from_resources(resources)
		assert_true(_has_error(tables.errors, expected), "«%s»: %s" % [expected, _errors_text(tables.errors)])


func test_dodge_validation_detects_bad_values() -> void:
	var cases: Dictionary[String, String] = {
		"la esquiva dura 0 ticks": "zero",
		"la invulnerabilidad debe cumplir": "invulnerable",
		"cancel_to_attack_from_s fuera": "cancel",
		"distancia de esquiva negativa": "distance",
		"coste de la esquiva fuera de rango": "cost",
		"falta la curva de velocidad": "curve",
	}
	for expected: String in cases:
		var weapon: WeaponDefinition = _weapon(&"arma")
		var dodge: DodgeDefinition = weapon.dodge
		match cases[expected]:
			"zero":
				dodge.duration_s = 0.0
			"invulnerable":
				dodge.invulnerable_to_s = 9.0
			"cancel":
				dodge.cancel_to_attack_from_s = 9.0
			"distance":
				dodge.distance_m = -1.0
			"cost":
				dodge.stamina_cost = 1001
			"curve":
				dodge.speed_curve = null
		var resources: Array[Resource] = [CombatRules.new(), weapon]
		var tables: CombatTables = CombatCatalog.build_from_resources(resources)
		assert_true(_has_error(tables.errors, expected), "«%s»: %s" % [expected, _errors_text(tables.errors)])


func test_rules_validation_detects_bad_values() -> void:
	var cases: Dictionary[String, String] = {
		"stamina_max fuera de rango": "max",
		"exhausted_exit_threshold": "threshold",
		"hold_to_heavy_ticks fuera de rango": "hold",
		"input_buffer_ticks fuera de rango": "buffer",
		"la ventana de parada no puede ser mayor": "parry",
		"la regeneración de resistencia no puede ser negativa": "regen",
	}
	for expected: String in cases:
		var rules := CombatRules.new()
		match cases[expected]:
			"max":
				rules.stamina_max = 70000
			"threshold":
				rules.exhausted_exit_threshold = 5000
			"hold":
				rules.hold_to_heavy_ticks = 0
			"buffer":
				rules.input_buffer_ticks = 16
			"parry":
				rules.parry_cooldown_ticks = 2
			"regen":
				rules.stamina_regen_per_tick = -1
		var resources: Array[Resource] = [rules]
		var tables: CombatTables = CombatCatalog.build_from_resources(resources)
		assert_true(_has_error(tables.errors, expected), "«%s»: %s" % [expected, _errors_text(tables.errors)])


# --- Conversión a ticks -----------------------------------------------------------------------

func test_seconds_to_ticks_uses_fixed_rounding() -> void:
	assert_eq(CombatCatalog.TICK_RATE, 60, "60 ticks por segundo")
	assert_eq(CombatCatalog.seconds_to_ticks(0.0), 0, "0")
	assert_eq(CombatCatalog.seconds_to_ticks(0.1), 6, "0,1 s")
	assert_eq(CombatCatalog.seconds_to_ticks(0.2), 12, "0,2 s (12.000000000000002 en coma flotante)")
	assert_eq(CombatCatalog.seconds_to_ticks(0.18), 11, "0,18 s = 10,8 ticks redondea a 11")
	assert_eq(CombatCatalog.seconds_to_ticks(0.38), 23, "0,38 s = 22,8 ticks redondea a 23")
	assert_eq(CombatCatalog.seconds_to_ticks(0.12), 7, "0,12 s = 7,2 ticks redondea a 7")
	assert_eq(CombatCatalog.seconds_to_ticks(1.2), 72, "1,2 s")
	assert_eq(CombatCatalog.seconds_to_ticks(0.35), 21, "0,35 s")
	assert_eq(CombatCatalog.seconds_to_ticks(1.0 / 120.0), 1, "medio tick redondea hacia arriba")


func test_attack_ticks_for_the_sword() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	# [anticipación, activo, recuperación, ventana de combo, cancelar a esquiva desde]
	var expected: Dictionary[StringName, Array] = {
		&"sword_light_1": [12, 6, 18, 9, 24],
		&"sword_light_2": [11, 6, 18, 9, 23],
		&"sword_light_3": [15, 6, 27, 0, 30],
		&"sword_heavy": [24, 7, 33, 0, 42],
	}
	for attack_name: StringName in expected:
		var attack: AttackTicks = tables.attack(tables.attack_ids[attack_name])
		var want: Array = expected[attack_name]
		assert_eq(attack.windup_ticks, want[0], "%s: anticipación" % attack_name)
		assert_eq(attack.active_ticks, want[1], "%s: golpe activo" % attack_name)
		assert_eq(attack.recovery_ticks, want[2], "%s: recuperación" % attack_name)
		assert_eq(attack.combo_window_ticks, want[3], "%s: ventana de combo" % attack_name)
		assert_eq(attack.cancel_to_dodge_from_ticks, want[4], "%s: cancelar a esquiva" % attack_name)
		assert_eq(attack.total_ticks, want[0] + want[1] + want[2], "%s: duración total" % attack_name)
		assert_eq(attack.active_from(), want[0], "%s: active_from()" % attack_name)
		assert_eq(attack.active_to(), want[0] + want[1], "%s: active_to()" % attack_name)
		assert_eq(attack.combo_window_from(), attack.total_ticks - want[3],
				"%s: combo_window_from()" % attack_name)
	var heavy: AttackTicks = tables.attack(tables.attack_ids[&"sword_heavy"])
	assert_true(heavy.heavy, "el fuerte es heavy")
	assert_eq(heavy.charge_min_ticks, 21, "carga mínima 0,35 s")
	assert_eq(heavy.charge_max_ticks, 72, "carga máxima 1,2 s")
	assert_eq(heavy.stamina_cost, 150, "el fuerte cuesta 150")
	assert_near(heavy.charge_move_scale, 0.4, 1e-9, "movimiento cargando ×0,4")
	assert_near(heavy.move_speed_scale, 0.2, 1e-9, "movimiento del golpe ×0,2")
	assert_near(heavy.lunge_speed, 2.5, 1e-9, "avance 2,5 m/s")
	assert_true(heavy.hyper_armor, "entereza")
	assert_eq(heavy.stagger_ticks, 30, "tambaleo 0,5 s")
	assert_near(heavy.knockback_speed, 4.0, 1e-9, "empuje 4 m/s")
	assert_near(heavy.charge_damage_scale, 1.7, 1e-9, "×1,7 a carga máxima")
	assert_eq(heavy.base_damage, 180, "daño 180")
	var light3: AttackTicks = tables.attack(tables.attack_ids[&"sword_light_3"])
	assert_eq(light3.stagger_ticks, 18, "el tercer ligero tambalea 0,3 s")
	assert_eq(light3.base_damage, 130, "daño 130")
	for attack_name: StringName in expected:
		var attack: AttackTicks = tables.attack(tables.attack_ids[attack_name])
		assert_not_null(attack.shape, "%s tiene forma de golpe" % attack_name)
		assert_near(attack.shape.range_m, 2.6, 1e-9, "%s: alcance 2,6 m" % attack_name)
		assert_near(attack.shape.angle_deg, 100.0, 1e-9, "%s: 100 grados" % attack_name)
		assert_near(attack.turn_rate, 6.0, 1e-9, "%s: giro 6 rad/s" % attack_name)


func test_weapon_ticks_for_sword_and_shield() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	var weapon: WeaponTicks = tables.weapon(tables.weapon_ids[&"sword_shield"])
	assert_eq(weapon.name, &"sword_shield", "nombre")
	var light_one: int = tables.attack_ids[&"sword_light_1"]
	assert_eq(weapon.light_ids, PackedInt32Array([light_one, light_one + 1, light_one + 2]),
			"combo: ligeros 1, 2 y 3 en orden")
	assert_eq(weapon.heavy_id, tables.attack_ids[&"sword_heavy"], "fuerte")
	assert_eq(weapon.light_index(light_one + 1), 1, "light_index() del segundo ligero")
	assert_eq(weapon.light_index(weapon.heavy_id), -1, "el fuerte no es un ligero")
	assert_near(weapon.block_move_scale, 0.5, 1e-9, "movimiento al bloquear ×0,5")
	assert_near(weapon.block_turn_rate, 8.0, 1e-9, "giro al bloquear 8 rad/s")
	assert_near(weapon.block_angle_deg, 120.0, 1e-9, "cono de 120 grados")
	assert_near(weapon.block_mitigation, 1.0, 1e-9, "para el 100 %")
	var dodge: DodgeTicks = weapon.dodge
	assert_eq(dodge.duration_ticks, 27, "esquiva de 0,45 s")
	assert_eq(dodge.invulnerable_from_ticks, 3, "invulnerable desde 0,05 s")
	assert_eq(dodge.invulnerable_to_ticks, 18, "hasta 0,30 s (exclusivo)")
	assert_eq(dodge.cancel_to_attack_from_ticks, 18, "a ataque desde 0,30 s")
	assert_eq(dodge.stamina_cost, 300, "300 de resistencia")
	assert_near(dodge.distance_m, 4.5, 1e-9, "4,5 m")


func test_dodge_curve_is_baked_to_the_distance() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	var dodge: DodgeTicks = tables.weapon(tables.weapon_ids[&"sword_shield"]).dodge
	assert_eq(dodge.speeds.size(), dodge.duration_ticks, "una velocidad por tick")
	var distance: float = 0.0
	for speed: float in dodge.speeds:
		distance += speed / float(CombatCatalog.TICK_RATE)
		assert_true(speed >= 0.0, "ninguna velocidad negativa")
		assert_eq(speed, PlayerState.to_f32(speed), "cada velocidad es exacta en f32")
	assert_near(distance, 4.5, 1e-5, "la suma de v / 60 es la distancia")
	assert_true(dodge.speeds[0] > dodge.speeds[dodge.speeds.size() - 1] * 5.0,
			"salida rápida: mucho más veloz al principio que al final")
	assert_eq(dodge.speed_at(0), dodge.speeds[0], "speed_at(0)")
	assert_eq(dodge.speed_at(1000), dodge.speeds[dodge.speeds.size() - 1], "más allá repite el último")
	assert_eq(dodge.speed_at(-1), 0.0, "antes del inicio no hay velocidad")


func test_a_flat_curve_gives_constant_speed() -> void:
	var weapon: WeaponDefinition = _weapon(&"arma")
	var flat := Curve.new()
	flat.add_point(Vector2(0.0, 1.0))
	flat.add_point(Vector2(1.0, 1.0))
	weapon.dodge.speed_curve = flat
	weapon.dodge.distance_m = 3.0
	weapon.dodge.duration_s = 0.5
	var resources: Array[Resource] = [CombatRules.new(), weapon]
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	var dodge: DodgeTicks = tables.weapon(1).dodge
	assert_eq(dodge.duration_ticks, 30, "0,5 s")
	for speed: float in dodge.speeds:
		assert_near(speed, 6.0, 1e-5, "3 m en 0,5 s son 6 m/s en todos los ticks")


# --- Huella -----------------------------------------------------------------------------------

func test_prediction_hash_is_stable() -> void:
	var first: int = CombatCatalog.build_from_directory(DATA_DIR).prediction_hash
	var second: int = CombatCatalog.build_from_directory(DATA_DIR).prediction_hash
	assert_eq(first, second, "dos cargas dan la misma huella")
	assert_true(first >= 0 and first <= 0xFFFFFFFF, "es un u32")
	assert_true(first != 0, "no es 0")
	CombatCatalog.reload()
	assert_eq(CombatCatalog.prediction_hash(), first, "tras recargar, igual")


func test_prediction_hash_changes_with_predicted_values() -> void:
	var base_hash: int = _hash_of("")
	var predicted: Array[String] = [
		"windup", "active", "recovery", "combo_window", "cancel_to_dodge", "heavy_cost", "lunge",
		"turn_rate", "move_scale", "charge_min", "charge_max", "charge_move", "charge_turn",
		"block_move", "block_turn", "dodge_duration", "dodge_invulnerable", "dodge_distance",
		"dodge_curve", "dodge_cost", "dodge_cancel", "stamina_max", "regen", "regen_delay",
		"exhausted_regen", "exhausted_exit", "hold_to_heavy", "buffer", "parry_window",
		"parry_cooldown",
	]
	for what: String in predicted:
		var changed: int = _hash_of(what)
		assert_true(changed != base_hash, "cambiar «%s» debe cambiar la huella" % what)


func test_prediction_hash_ignores_server_only_values() -> void:
	var base_hash: int = _hash_of("")
	var server_only: Array[String] = [
		"damage", "damage_type", "hyper_armor", "stagger", "knockback", "charge_damage",
		"shape", "block_mitigation", "block_angle", "block_cost", "health_max", "respawn",
		"crit", "fall_damage", "parry_stagger",
	]
	for what: String in server_only:
		var changed: int = _hash_of(what)
		assert_eq(changed, base_hash, "cambiar «%s» (solo servidor) no debe cambiar la huella" % what)


func test_prediction_hash_depends_on_the_id_assignment() -> void:
	# Si un cliente numera los ataques de otra forma, el action_id del estado no coincidiría.
	var rules := CombatRules.new()
	var first: Array[Resource] = [rules, _attack(&"a"), _attack(&"b")]
	var second: Array[Resource] = [rules, _attack(&"a"), _attack(&"c")]
	assert_true(CombatCatalog.build_from_resources(first).prediction_hash
			!= CombatCatalog.build_from_resources(second).prediction_hash,
			"otro nombre de ataque, otra huella")


func test_sim_hash_includes_the_combat_hash() -> void:
	# NetProtocol.compute_sim_hash lleva la huella del catálogo y la versión del protocolo (2 fue el
	# combate de la fase 3; 3, su revisión; 4, el fuerte de la fase 4; 5, el chat y los grupos).
	assert_true(NetProtocol.PROTOCOL_VERSION >= 4, "el protocolo del fuerte es la versión 4 o posterior")
	var scene: PackedScene = load("res://scenes/characters/player_character.tscn") as PackedScene
	var character: PlayerCharacter = scene.instantiate() as PlayerCharacter
	tree.root.add_child(character)
	var with_data: int = NetProtocol.compute_sim_hash(character)
	assert_eq(NetProtocol.compute_sim_hash(character), with_data, "estable")
	character.queue_free()
	# Con otra huella del catálogo, el sim_hash cambia.
	var tables: CombatTables = CombatCatalog.tables()
	var saved_hash: int = tables.prediction_hash
	tables.prediction_hash = saved_hash ^ 0x1234
	var scene2: PackedScene = load("res://scenes/characters/player_character.tscn") as PackedScene
	var other: PlayerCharacter = scene2.instantiate() as PlayerCharacter
	tree.root.add_child(other)
	var changed: int = NetProtocol.compute_sim_hash(other)
	tables.prediction_hash = saved_hash
	other.queue_free()
	assert_true(changed != with_data, "otra huella del catálogo, otro sim_hash")


# --- Fase 4: habilidades, efectos, proyectiles y plantillas (docs/habilidades.md, sección 2) ---

func test_every_id_space_is_alphabetical_and_asked_by_name() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	var spaces: Dictionary[String, Dictionary] = {
		"habilidad": tables.ability_ids, "efecto": tables.status_ids,
		"proyectil": tables.projectile_ids, "plantilla": tables.template_ids,
	}
	for space: String in spaces:
		var ids: Dictionary = spaces[space]
		var names: Array[String] = _sorted_names(ids)
		for i: int in names.size():
			assert_eq(ids[StringName(names[i])], i + 1, "%s %s es la número %d" % [space, names[i], i + 1])
	for i: int in tables.abilities.size():
		assert_eq(tables.abilities[i].id, i + 1, "la habilidad del índice %d lleva el ID %d" % [i, i + 1])
	# Por nombre, en el catálogo global (nadie escribe un ID a mano).
	CombatCatalog.reload()
	var global: CombatTables = CombatCatalog.tables()
	for ability_name: StringName in [&"shield_bash", &"shield_rush", &"shield_wall", &"bow_volley",
			&"bow_slowing_shot", &"bow_evasive_shot", &"potion_health", &"potion_stamina"]:
		var id: int = CombatCatalog.ability_id(ability_name)
		assert_true(id > 0, "ability_id(%s)" % ability_name)
		assert_eq(CombatCatalog.ability(id).name, ability_name, "ability(ability_id(%s))" % ability_name)
	for status_name: StringName in [&"slowed", &"potion_regen", &"bleed", &"rooted"]:
		var id: int = CombatCatalog.status_id(status_name)
		assert_true(id > 0 and id <= 255, "status_id(%s) cabe en u8" % status_name)
		assert_eq(CombatCatalog.status(id).name, status_name, "status(status_id(%s))" % status_name)
	assert_eq(CombatCatalog.projectile(CombatCatalog.projectile_id(&"arrow")).name, &"arrow", "la flecha")
	assert_eq(CombatCatalog.template(CombatCatalog.template_id(&"squire")).id, &"squire", "el escudero")
	assert_eq(CombatCatalog.template(CombatCatalog.template_id(&"marksman")).id, &"marksman", "el tirador")
	assert_eq(CombatCatalog.template_count(), 2, "dos plantillas")
	assert_eq(CombatCatalog.default_template_id(), CombatCatalog.template_id(&"squire"),
			"la plantilla por defecto es el escudero")
	assert_eq(CombatCatalog.consumable_ids(), PackedInt32Array([
		CombatCatalog.ability_id(&"potion_health"), CombatCatalog.ability_id(&"potion_stamina"),
	]), "consumibles en orden de botón: vida (R) y resistencia (T)")
	for missing: int in [CombatCatalog.ability_id(&"no_existe"), CombatCatalog.status_id(&"no_existe"),
			CombatCatalog.projectile_id(&"no_existe"), CombatCatalog.template_id(&"no_existe")]:
		assert_eq(missing, 0, "un nombre que no existe da 0")
	assert_null(global.ability(0), "0 es «ninguna» en las habilidades")
	assert_null(global.status(0), "en los efectos")
	assert_null(global.projectile(0), "en los proyectiles")
	assert_null(global.template(0), "y en las plantillas")
	assert_null(global.ability(global.abilities.size() + 1), "una habilidad que no existe")


func test_sword_and_shield_abilities_in_ticks() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	var sword_id: int = tables.weapon_ids[&"sword_shield"]
	var weapon: WeaponTicks = tables.weapon(sword_id)
	var bash_id: int = tables.ability_ids[&"shield_bash"]
	var rush_id: int = tables.ability_ids[&"shield_rush"]
	var wall_id: int = tables.ability_ids[&"shield_wall"]
	assert_eq(weapon.ability_ids, PackedInt32Array([bash_id, rush_id, wall_id]), "ranuras 1, 2 y 3")
	assert_eq(weapon.ability_id(1), rush_id, "ability_id(1)")
	assert_eq(weapon.ability_id(3), 0, "fuera de rango, 0")
	assert_true(weapon.can_block, "la espada y escudo bloquea")
	# [lanzamiento, activo, recuperación, reutilización, ranura] (docs/habilidades.md, 2.3).
	var expected: Dictionary[StringName, Array] = {
		&"shield_bash": [18, 6, 24, 720, 0],
		&"shield_rush": [9, 24, 21, 960, 1],
		&"shield_wall": [12, 360, 0, 1080, 2],
	}
	for ability_name: StringName in expected:
		var ability: AbilityTicks = tables.ability(tables.ability_ids[ability_name])
		var want: Array = expected[ability_name]
		assert_eq(ability.cast_ticks, want[0], "%s: lanzamiento" % ability_name)
		assert_eq(ability.active_ticks, want[1], "%s: activo" % ability_name)
		assert_eq(ability.recovery_ticks, want[2], "%s: recuperación" % ability_name)
		assert_eq(ability.cooldown_ticks, want[3], "%s: reutilización" % ability_name)
		assert_eq(ability.slot, want[4], "%s: ranura" % ability_name)
		assert_eq(ability.total_ticks, want[0] + want[1] + want[2], "%s: duración" % ability_name)
		assert_eq(ability.weapon_id, sword_id, "%s: la lleva la espada y escudo" % ability_name)
		assert_false(ability.is_consumable(), "%s: no es un consumible" % ability_name)
		assert_true(ability.cooldown_ticks >= ability.total_ticks + 1, "%s: reutilización > duración" % ability_name)
	var bash: AbilityTicks = tables.ability(bash_id)
	assert_eq(bash.hit.stun_ticks, 48, "el golpe de escudo aturde 0,8 s")
	assert_true(bash.hit.unblockable, "imbloqueable")
	assert_eq(bash.hit.base_damage, 60, "60 de daño")
	assert_eq(bash.hit.damage_type, DamageFormula.DamageType.BLUNT, "contundente")
	assert_near(bash.hit.shape.range_m, 2.2, 1e-9, "sector de 2,2 m")
	assert_near(bash.hit.shape.angle_deg, 90.0, 1e-9, "de 90 grados")
	assert_near(bash.lunge_speed, 1.0, 1e-9, "avance 1 m/s")
	assert_near(bash.move_speed_scale, 0.2, 1e-9, "movimiento ×0,2")
	var rush: AbilityTicks = tables.ability(rush_id)
	assert_eq(rush.dash_from_ticks, 9, "la embestida avanza desde el compromiso")
	assert_eq(rush.dash_to_ticks, 33, "durante todo el activo")
	assert_eq(rush.dash_speeds.size(), 24, "una velocidad por tick del avance")
	var distance: float = 0.0
	for speed: float in rush.dash_speeds:
		distance += speed / float(CombatCatalog.TICK_RATE)
		assert_near(speed, 15.0, 1e-4, "curva plana: 6 m en 0,4 s son 15 m/s")
		assert_eq(speed, PlayerState.to_f32(speed), "exacta en f32")
	assert_near(distance, 6.0, 1e-4, "avance de 6 m")
	assert_eq(rush.dash_direction, 0, "hacia look_yaw")
	assert_true(rush.is_dashing(9) and rush.is_dashing(32), "avanza en [9, 33)")
	assert_false(rush.is_dashing(8) or rush.is_dashing(33), "y fuera no")
	assert_eq(rush.dash_speed_at(9), rush.dash_speeds[0], "dash_speed_at(9)")
	assert_eq(rush.dash_speed_at(33), 0.0, "sin velocidad fuera de la ventana")
	assert_true(rush.hit.hyper_armor, "entereza en el activo")
	assert_eq(rush.hit.stagger_ticks, 24, "tambaleo 0,4 s")
	assert_near(rush.hit.knockback_speed, 6.0, 1e-9, "empuje 6 m/s")
	assert_near(rush.hit.shape.range_m, 1.8, 1e-9, "sector de 1,8 m")
	assert_near(rush.hit.shape.angle_deg, 140.0, 1e-9, "de 140 grados")
	var wall: AbilityTicks = tables.ability(wall_id)
	assert_true(wall.channel and wall.channel_hold and wall.blocks, "el muro es una canalización que bloquea y se suelta")
	assert_false(wall.channel_breaks_on_move, "moverse no lo acaba")
	assert_eq(wall.cancel_to_dodge_from_ticks, 12, "a esquiva desde el fin del lanzamiento")
	assert_eq(wall.cancel_to_attack_from_ticks, 372, "sin recuperación: -1 es el final")
	assert_near(wall.move_speed_scale, 0.3, 1e-9, "movimiento ×0,3")
	assert_near(wall.turn_rate, 4.0, 1e-9, "giro 4")
	assert_vec_near(wall.wall_half_extents, Vector3(1.3, 1.0, 0.15), 1e-6, "caja de 2,6 × 2,0 × 0,3 m")
	assert_near(wall.wall_forward_m, 0.7, 1e-9, "a 0,7 m delante")
	assert_null(wall.hit.shape, "el muro no golpea")


func test_bow_and_arrow_in_ticks() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	var bow_id: int = tables.weapon_ids[&"bow"]
	var bow: WeaponTicks = tables.weapon(bow_id)
	var arrow_id: int = tables.projectile_ids[&"arrow"]
	assert_eq(bow.light_ids, PackedInt32Array([tables.attack_ids[&"bow_quick"]]), "el ligero es el disparo rápido (combo de 1)")
	assert_eq(bow.heavy_id, tables.attack_ids[&"bow_drawn"], "el fuerte es el tensado")
	assert_false(bow.can_block, "el arco no bloquea")
	assert_eq(bow.dodge.duration_ticks, 27, "la esquiva de la espada")
	assert_eq(bow.ability_ids, PackedInt32Array([tables.ability_ids[&"bow_volley"],
			tables.ability_ids[&"bow_slowing_shot"], tables.ability_ids[&"bow_evasive_shot"]]),
			"abanico, lastrante y salto atrás")
	var quick: AttackTicks = tables.attack(tables.attack_ids[&"bow_quick"])
	assert_eq([quick.windup_ticks, quick.active_ticks, quick.recovery_ticks], [15, 1, 21], "rápido: 15 + 1 + 21")
	assert_eq(quick.total_ticks, 37, "37 ticks")
	assert_eq(quick.cancel_to_dodge_from_ticks, 16, "a esquiva desde 0,27 s")
	assert_eq(quick.projectile_id, arrow_id, "dispara una flecha")
	assert_near(quick.projectile_speed_mps, 45.0, 1e-9, "a 45 m/s")
	assert_eq(quick.base_damage, 60, "60")
	assert_eq(quick.damage_type, DamageFormula.DamageType.PIERCE, "perforante")
	assert_null(quick.shape, "sin forma: con proyectil puede ser nula")
	assert_near(quick.move_speed_scale, 0.5, 1e-9, "movimiento ×0,5")
	assert_near(quick.turn_rate, 8.0, 1e-9, "giro 8")
	var drawn: AttackTicks = tables.attack(tables.attack_ids[&"bow_drawn"])
	assert_true(drawn.heavy, "el tensado es un fuerte")
	assert_eq([drawn.windup_ticks, drawn.active_ticks, drawn.recovery_ticks], [3, 1, 18], "tras soltar: 3 + 1 + 18")
	assert_eq([drawn.charge_min_ticks, drawn.charge_max_ticks], [21, 60], "carga 0,35-1,0 s")
	assert_near(drawn.projectile_speed_mps, 40.0, 1e-9, "40 m/s a carga mínima")
	assert_near(drawn.charge_speed_scale, 1.75, 1e-9, "70 m/s a carga máxima")
	assert_near(drawn.charge_damage_scale, 2.0, 1e-9, "90 → 180")
	assert_eq(drawn.stamina_cost, 0, "sin resistencia")
	assert_near(drawn.charge_move_scale, 0.5, 1e-9, "carga: movimiento ×0,5")
	assert_near(drawn.charge_turn_rate, 8.0, 1e-9, "carga: giro 8")
	# [lanzamiento, activo, recuperación, reutilización, velocidad, daño]
	var expected: Dictionary[StringName, Array] = {
		&"bow_volley": [18, 1, 24, 600, 45.0, 55],
		&"bow_slowing_shot": [21, 1, 18, 720, 55.0, 60],
		&"bow_evasive_shot": [18, 1, 15, 840, 50.0, 60],
	}
	for ability_name: StringName in expected:
		var ability: AbilityTicks = tables.ability(tables.ability_ids[ability_name])
		var want: Array = expected[ability_name]
		assert_eq([ability.cast_ticks, ability.active_ticks, ability.recovery_ticks], want.slice(0, 3),
				"%s: fases" % ability_name)
		assert_eq(ability.cooldown_ticks, want[3], "%s: reutilización" % ability_name)
		assert_near(ability.projectile_speed_mps, want[4], 1e-9, "%s: velocidad" % ability_name)
		assert_eq(ability.hit.base_damage, want[5], "%s: daño" % ability_name)
		assert_eq(ability.projectile_id, arrow_id, "%s: flecha" % ability_name)
		assert_eq(ability.hit.projectile_id, arrow_id, "%s: el golpe sintetizado lleva la flecha" % ability_name)
		assert_eq(ability.weapon_id, bow_id, "%s: del arco" % ability_name)
	var volley: AbilityTicks = tables.ability(tables.ability_ids[&"bow_volley"])
	assert_eq(volley.projectile_count, 3, "abanico de 3 flechas")
	assert_near(volley.projectile_spread_deg, 7.0, 1e-9, "a ±7 grados")
	var slowing: AbilityTicks = tables.ability(tables.ability_ids[&"bow_slowing_shot"])
	assert_eq(slowing.hit.on_hit_status_id, tables.status_ids[&"slowed"], "la lastrante ralentiza")
	var evasive: AbilityTicks = tables.ability(tables.ability_ids[&"bow_evasive_shot"])
	assert_eq([evasive.dash_from_ticks, evasive.dash_to_ticks, evasive.dash_direction], [0, 18, 1],
			"salto atrás en [0, 0,3 s)")
	var distance: float = 0.0
	for speed: float in evasive.dash_speeds:
		distance += speed / float(CombatCatalog.TICK_RATE)
	assert_near(distance, 4.0, 1e-4, "de 4 m")
	assert_true(evasive.dash_speeds[0] > evasive.dash_speeds[evasive.dash_speeds.size() - 1],
			"más rápido al principio")
	var arrow: ProjectileTicks = tables.projectile(arrow_id)
	assert_near(arrow.gravity, 6.0, 1e-9, "gravedad 6 m/s²")
	assert_near(arrow.radius_m, 0.05, 1e-9, "radio 5 cm")
	assert_eq(arrow.lifetime_ticks, 120, "2 s de vida")


func test_consumables_statuses_templates_and_rules_in_ticks() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	assert_eq(tables.consumable_cooldown_ticks, 1200, "reutilización compartida de 20 s")
	assert_eq(tables.swap_ticks, 24, "cambio de arma 0,4 s")
	assert_eq(tables.revive_ticks, 180, "levantar 3 s")
	assert_eq(tables.execute_ticks, 60, "rematar 1 s")
	assert_eq(tables.downed_ticks, 1200, "desangrarse 20 s")
	var health: AbilityTicks = tables.ability(tables.ability_ids[&"potion_health"])
	var stamina: AbilityTicks = tables.ability(tables.ability_ids[&"potion_stamina"])
	assert_eq([health.cast_ticks, health.active_ticks, health.recovery_ticks], [36, 1, 12], "beber vida: 36 + 1 + 12")
	assert_eq([stamina.cast_ticks, stamina.active_ticks, stamina.recovery_ticks], [24, 1, 12], "beber resistencia: 24 + 1 + 12")
	assert_eq([health.consumable_index, stamina.consumable_index], [0, 1], "R y T")
	assert_eq([health.slot, health.weapon_id], [-1, 0], "sin ranura ni arma")
	assert_true(health.is_consumable() and stamina.is_consumable(), "son consumibles")
	assert_eq(health.cooldown_ticks, 0, "usan la reutilización compartida")
	assert_true(health.interrupt_on_damage and stamina.interrupt_on_damage, "un golpe interrumpe")
	assert_eq(health.self_status_id, tables.status_ids[&"potion_regen"], "la de vida cura en el tiempo")
	assert_eq(stamina.stamina_restore, 400, "+400 de resistencia")
	assert_near(health.move_speed_scale, 0.4, 1e-9, "movimiento ×0,4")
	var slowed: StatusTicks = tables.status(tables.status_ids[&"slowed"])
	assert_eq(slowed.kind, StatusEffectDefinition.Kind.SLOW, "slowed ralentiza")
	assert_near(slowed.move_speed_scale, 0.6, 1e-9, "×0,6")
	assert_eq(slowed.duration_ticks, 180, "3 s")
	assert_eq(slowed.stacking, StatusEffectDefinition.Stacking.STRONGEST, "el más fuerte gana")
	assert_true(slowed.is_movement() and slowed.is_harmful(), "de movimiento y perjudicial")
	var regen: StatusTicks = tables.status(tables.status_ids[&"potion_regen"])
	assert_eq([regen.pulse_ticks, regen.pulse_amount, regen.duration_ticks], [30, 50, 180], "50 cada 0,5 s durante 3 s")
	assert_eq(regen.duration_ticks / regen.pulse_ticks, 6, "6 pulsos")
	assert_false(regen.is_harmful(), "la curación no perjudica")
	var bleed: StatusTicks = tables.status(tables.status_ids[&"bleed"])
	assert_eq([bleed.pulse_ticks, bleed.pulse_amount, bleed.duration_ticks, bleed.max_stacks], [60, 15, 360, 3],
			"15 por acumulación cada 1 s durante 6 s, hasta 3")
	assert_eq(bleed.stacking, StatusEffectDefinition.Stacking.STACK, "se acumula")
	assert_true(bleed.has_pulses() and not bleed.is_movement(), "pulsos, sin movimiento")
	var rooted: StatusTicks = tables.status(tables.status_ids[&"rooted"])
	assert_eq(rooted.kind, StatusEffectDefinition.Kind.ROOT, "rooted enraíza")
	assert_eq(rooted.move_speed_scale, 0.0, "escala 0")
	assert_eq(rooted.duration_ticks, 90, "1,5 s")
	var squire: int = tables.template_ids[&"squire"]
	var marksman: int = tables.template_ids[&"marksman"]
	assert_eq(tables.template_weapons(squire), PackedInt32Array([tables.weapon_ids[&"sword_shield"]]),
			"escudero: espada y escudo")
	assert_eq(tables.template_weapons(marksman), PackedInt32Array([tables.weapon_ids[&"bow"],
			tables.weapon_ids[&"sword_shield"]]), "tirador: arco y espada y escudo")
	assert_eq(tables.template_charges_of(squire), CombatState.pack_charges(3, 2), "cargas [3, 2]")
	assert_eq(tables.template_charges_of(marksman), CombatState.pack_charges(2, 3), "cargas [2, 3]")
	assert_true(tables.template(squire).selectable and tables.template(marksman).selectable, "elegibles")
	assert_eq(tables.default_template_id, squire, "por defecto, el escudero")
	assert_eq(tables.template_weapons(0), PackedInt32Array(), "una plantilla que no existe no tiene armas")
	assert_eq(tables.template_charges_of(99), 0, "ni cargas")


func test_the_synthesized_hit_has_the_ability_windows_and_its_source() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	for ability: AbilityTicks in tables.abilities:
		var hit: AttackTicks = ability.hit
		if not assert_not_null(hit, "%s tiene golpe sintetizado" % ability.name):
			continue
		assert_eq(hit.id, CombatSource.make(CombatSource.Kind.ABILITY, ability.id), "%s: su id es la fuente" % ability.name)
		assert_eq(CombatSource.kind_of(hit.id), CombatSource.Kind.ABILITY, "%s: de habilidad" % ability.name)
		assert_eq(CombatSource.id_of(hit.id), ability.id, "%s: con su id" % ability.name)
		assert_eq(hit.name, ability.name, "%s: nombre" % ability.name)
		assert_eq(hit.windup_ticks, ability.cast_ticks, "%s: anticipación = lanzamiento" % ability.name)
		assert_eq(hit.active_ticks, ability.active_ticks, "%s: activo" % ability.name)
		assert_eq(hit.recovery_ticks, ability.recovery_ticks, "%s: recuperación" % ability.name)
		assert_eq(hit.total_ticks, ability.total_ticks, "%s: total" % ability.name)
		assert_eq(hit.active_from(), ability.active_from(), "%s: el golpe empieza en el compromiso" % ability.name)
		assert_false(tables.attacks.has(hit), "%s: no está en la tabla de ataques" % ability.name)


func test_ability_validation_follows_section_2_2() -> void:
	var base: Array[Resource] = _ability_resources("")
	assert_eq(CombatCatalog.build_from_resources(base).errors, PackedStringArray(),
			"el catálogo de prueba es válido")
	var cases: Dictionary[String, String] = {
		"está en más de un arma": "two_weapons",
		"en los consumibles": "weapon_and_consumable",
		"la reutilización debe ser al menos la duración + 1": "cooldown",
		"una canalización no lleva recuperación": "channel_recovery",
		"un consumible no lleva reutilización propia": "consumable_cooldown",
		"la reutilización compartida debe ser mayor que su duración": "shared_cooldown",
		"un consumible lleva interrupt_on_damage": "consumable_interrupt",
		"consumables debe tener exactamente 2": "one_consumable",
		"la duración debe ser múltiplo exacto de los pulsos": "pulses",
		"ROOT lleva move_speed_scale 0": "root",
		"SLOW lleva move_speed_scale > 0": "slow",
		"la ventana del avance debe caber": "dash",
		"lifetime_ticks debe ser al menos 1": "lifetime",
		"projectile_count fuera de rango": "count",
		"es elegible y lleva el arma de PNJ": "npc_template",
		"debe llevar una o dos armas": "template_weapons",
		"cargas fuera de rango": "charges",
		"el combo ligero debe tener de 1 a 3 golpes": "combo",
		"tiene 4 habilidades y caben 3": "four_abilities",
		"el activo debe durar al menos un tick": "active",
		"id de habilidad repetido": "duplicate",
	}
	for expected: String in cases:
		var resources: Array[Resource] = _ability_resources(cases[expected])
		var tables: CombatTables = CombatCatalog.build_from_resources(resources)
		assert_true(_has_error(tables.errors, expected), "«%s»: %s" % [expected, _errors_text(tables.errors)])
	# Una plantilla que no es elegible sí puede llevar armas de PNJ (pruebas y PNJ).
	var npc_ok: Array[Resource] = _ability_resources("npc_template_hidden")
	assert_eq(CombatCatalog.build_from_resources(npc_ok).errors, PackedStringArray(),
			"selectable = false admite armas npc_*")
	# Con cast = 0 el compromiso es el primer tick y un combo de 1 golpe vale.
	var single: Array[Resource] = _ability_resources("single_light")
	assert_eq(CombatCatalog.build_from_resources(single).errors, PackedStringArray(), "combo de 1 golpe")


func test_status_and_template_ids_fit_in_a_byte() -> void:
	var resources: Array[Resource] = [CombatRules.new()]
	for i: int in 256:
		var effect := StatusEffectDefinition.new()
		effect.id = StringName("efecto_%03d" % i)
		resources.append(effect)
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	assert_true(_has_error(tables.errors, "hay 256 efectos y caben 255"), _errors_text(tables.errors))
	resources.pop_back()
	assert_eq(CombatCatalog.build_from_resources(resources).errors, PackedStringArray(), "255 sí caben")


func test_prediction_hash_covers_every_predicted_ability_field() -> void:
	var base_hash: int = CombatCatalog.build_from_resources(_ability_resources("")).prediction_hash
	var predicted: Array[String] = [
		"ability_cast", "ability_active", "ability_recovery", "ability_cooldown", "ability_channel",
		"ability_hold", "ability_breaks", "ability_cancel_dodge", "ability_cancel_attack",
		"ability_move", "ability_turn", "ability_lunge", "ability_dash", "ability_dash_window",
		"ability_dash_curve", "ability_dash_direction", "ability_air", "ability_stamina",
		"ability_blocks", "ability_projectile_count", "ability_spread", "ability_projectile_speed",
		"slot_order", "can_block", "swap", "swap_move", "downed_move_scale", "downed_turn_rate",
		"revive", "execute", "consumable_cooldown", "consumable_order", "aim_pivot", "aim_shoulder",
		"aim_v_offset", "aim_range", "aim_converge", "muzzle", "status_kind", "status_scale",
		"status_name", "arrow_gravity", "arrow_radius", "arrow_lifetime", "attack_projectile_speed",
		"attack_charge_speed", "attack_projectile",
	]
	for what: String in predicted:
		var changed: int = CombatCatalog.build_from_resources(_ability_resources(what)).prediction_hash
		assert_true(changed != base_hash, "cambiar «%s» debe cambiar la huella" % what)


func test_prediction_hash_ignores_server_only_ability_fields() -> void:
	var base_hash: int = CombatCatalog.build_from_resources(_ability_resources("")).prediction_hash
	var server_only: Array[String] = [
		"ability_damage", "ability_damage_type", "ability_shape", "ability_stagger", "ability_stun",
		"ability_knockback", "ability_hyper_armor", "ability_unblockable", "ability_target_status",
		"ability_self_heal", "ability_interrupt", "ability_wall", "status_duration", "status_pulse",
		"status_amount", "status_stacking", "status_magnitude", "downed_health", "downed_s",
		"revived_health", "interact_range", "ability_block", "max_projectiles", "template_charges",
		"template_selectable", "attack_stun", "attack_on_hit_status",
	]
	for what: String in server_only:
		var changed: int = CombatCatalog.build_from_resources(_ability_resources(what)).prediction_hash
		assert_eq(changed, base_hash, "cambiar «%s» (solo servidor) no debe cambiar la huella" % what)


func test_the_fast_path_of_simulate_does_not_look_up_the_catalog() -> void:
	# El camino rápido de ActionMachine.step (sin acción, sin botones de combate, nada pendiente)
	# no busca el arma ni recorre las ranuras de habilidades: lo cuentan los contadores de
	# CombatTables (el coste, el microbanco de tools/combat_balance.gd).
	CombatCatalog.reload()
	var tables: CombatTables = CombatCatalog.tables()
	var scene: PackedScene = load("res://scenes/characters/player_character.tscn") as PackedScene
	var character: PlayerCharacter = scene.instantiate() as PlayerCharacter
	tree.root.add_child(character)
	# Dentro de un tick de física, como la predicción cuando repite entradas.
	await wait_physics_frames(1)
	var weapons_before: int = tables.weapon_lookups
	var abilities_before: int = tables.ability_lookups
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	for tick: int in range(1, 61):
		var input := PlayerInput.new()
		input.tick = tick
		input.move = Vector2(0.0, 1.0) if tick % 3 != 0 else Vector2.ZERO
		input.look_yaw = tick * 0.01
		input.buttons = PlayerInput.SPRINT | PlayerInput.AIM_LEFT if tick % 2 == 0 else 0
		character.simulate(input.quantized(), dt)
	assert_eq(tables.weapon_lookups, weapons_before, "60 ticks quietos o corriendo: ninguna búsqueda de arma")
	assert_eq(tables.ability_lookups, abilities_before, "ni de habilidades")
	# Control: un botón de combate sí sale del camino rápido y busca el arma.
	var attack := PlayerInput.new()
	attack.tick = 61
	attack.buttons = PlayerInput.PRIMARY
	character.simulate(attack, dt)
	assert_true(tables.weapon_lookups > weapons_before, "PRIMARY sí busca el arma (el contador funciona)")
	character.queue_free()


# --- Utilidades -------------------------------------------------------------------------------

## Nombres (ordenados) de [param ids] (nombre -> ID).
func _sorted_names(ids: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for key: StringName in ids:
		names.append(String(key))
	names.sort()
	return names


## Los nombres de [param ids] que empiezan por [param prefix].
func _names_starting_with(ids: Dictionary, prefix: String) -> Array[String]:
	var names: Array[String] = []
	for name: String in _sorted_names(ids):
		if name.begins_with(prefix):
			names.append(name)
	return names


func _attack(attack_id: StringName) -> AttackDefinition:
	var attack := AttackDefinition.new()
	attack.id = attack_id
	attack.shape = HitShape.new()
	return attack


func _heavy(attack_id: StringName) -> AttackDefinition:
	var attack: AttackDefinition = _attack(attack_id)
	attack.heavy = true
	attack.charge_min_s = 0.35
	attack.charge_max_s = 1.2
	attack.charge_damage_scale = 1.7
	attack.stamina_cost = 150
	return attack


## Un arma completa y válida con ataques propios (los ids llevan [param suffix]).
func _weapon(weapon_id: StringName, suffix: StringName = &"") -> WeaponDefinition:
	var weapon := WeaponDefinition.new()
	weapon.id = weapon_id
	for i: int in 3:
		var light: AttackDefinition = _attack(StringName("luz_%d%s" % [i, suffix]))
		light.combo_window_s = 0.15
		weapon.light_combo.append(light)
	weapon.heavy_attack = _heavy(StringName("fuerte%s" % suffix))
	var dodge := DodgeDefinition.new()
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(0.4, 0.75))
	curve.add_point(Vector2(1.0, 0.05))
	dodge.speed_curve = curve
	weapon.dodge = dodge
	return weapon


## Huella de un arma de prueba tras aplicar el cambio [param what] (vacío = ninguno).
func _hash_of(what: String) -> int:
	var weapon: WeaponDefinition = _weapon(&"arma")
	var rules := CombatRules.new()
	var light: AttackDefinition = weapon.light_combo[0]
	var heavy: AttackDefinition = weapon.heavy_attack
	var dodge: DodgeDefinition = weapon.dodge
	match what:
		# Predichos.
		"windup": light.windup_s += 0.1
		"active": weapon.light_combo[1].active_s += 0.1
		"recovery": weapon.light_combo[2].recovery_s += 0.1
		"combo_window": light.combo_window_s = 0.2
		"cancel_to_dodge": light.cancel_to_dodge_from_s += 0.1
		"heavy_cost": heavy.stamina_cost += 10
		"lunge": light.lunge_speed += 0.5
		"turn_rate": light.turn_rate += 1.0
		"move_scale": light.move_speed_scale += 0.1
		"charge_min": heavy.charge_min_s += 0.1
		"charge_max": heavy.charge_max_s += 0.1
		"charge_move": heavy.charge_move_scale += 0.1
		"charge_turn": heavy.charge_turn_rate += 1.0
		"block_move": weapon.block_move_scale += 0.1
		"block_turn": weapon.block_turn_rate += 1.0
		"dodge_duration": dodge.duration_s += 0.1
		"dodge_invulnerable": dodge.invulnerable_to_s += 0.1
		"dodge_distance": dodge.distance_m += 1.0
		"dodge_curve": dodge.speed_curve.set_point_value(2, 1.0)
		"dodge_cost": dodge.stamina_cost += 10
		"dodge_cancel": dodge.cancel_to_attack_from_s += 0.1
		"stamina_max": rules.stamina_max = 900
		"regen": rules.stamina_regen_per_tick = 4
		"regen_delay": rules.stamina_regen_delay_s = 1.0
		"exhausted_regen": rules.exhausted_regen_per_tick = 2
		"exhausted_exit": rules.exhausted_exit_threshold = 200
		"hold_to_heavy": rules.hold_to_heavy_ticks = 9
		"buffer": rules.input_buffer_ticks = 7
		"parry_window": rules.parry_window_ticks = 5
		"parry_cooldown": rules.parry_cooldown_ticks = 31
		# Solo servidor.
		"damage": light.base_damage += 50
		"damage_type": light.damage_type = 2
		"hyper_armor": heavy.hyper_armor = not heavy.hyper_armor
		"stagger": heavy.stagger_s += 0.5
		"knockback": heavy.knockback_speed += 1.0
		"charge_damage": heavy.charge_damage_scale += 1.0
		"shape": light.shape.range_m += 1.0
		"block_mitigation": weapon.block_mitigation = 0.5
		"block_angle": weapon.block_angle_deg = 90.0
		"block_cost": weapon.block_stamina_per_damage = 2.0
		"health_max": rules.health_max = 2000
		"respawn": rules.respawn_s = 30.0
		"crit": rules.crit_multiplier = 2.0
		"fall_damage": rules.fall_damage_per_mps = 10
		"parry_stagger": rules.parry_stagger_s = 1.5
	var resources: Array[Resource] = [rules, weapon]
	return CombatCatalog.build_from_resources(resources).prediction_hash


## Estropea [param attack] según el caso de [method test_attack_validation_detects_bad_values].
func _break_attack(attack: AttackDefinition, what: String) -> void:
	match what:
		"negative":
			attack.windup_s = -0.1
		"zero":
			attack.windup_s = 0.0
			attack.active_s = 0.0
			attack.recovery_s = 0.0
		"combo":
			attack.combo_window_s = 5.0
		"cancel":
			attack.cancel_to_dodge_from_s = 9.0
		"cost":
			attack.stamina_cost = 1001
		"shape":
			attack.shape = null
		"damage":
			attack.base_damage = -1
		"type":
			attack.damage_type = 4
		"knockback":
			attack.knockback_speed = 400.0
		"speed":
			attack.move_speed_scale = -1.0


func _has_error(errors: PackedStringArray, fragment: String) -> bool:
	for message: String in errors:
		if message.contains(fragment):
			return true
	return false


func _errors_text(errors: PackedStringArray) -> String:
	return "errores: %s" % ["; ".join(errors)]


func assert_same(actual: Variant, expected: Variant, message: String = "") -> bool:
	return assert_true(is_same(actual, expected), message)


func _ability(ability_id: StringName) -> AbilityDefinition:
	var ability := AbilityDefinition.new()
	ability.id = ability_id
	ability.cast_s = 0.1
	ability.active_s = 0.1
	ability.recovery_s = 0.1
	ability.cooldown_s = 2.0
	return ability


func _potion(potion_id: StringName) -> AbilityDefinition:
	var potion: AbilityDefinition = _ability(potion_id)
	potion.cooldown_s = 0.0
	potion.interrupt_on_damage = true
	return potion


## Un catálogo de prueba completo de la fase 4 (reglas con dos pociones y una plantilla por defecto,
## un arma con un golpe con avance, un disparo y un muro, una flecha y dos efectos) tras aplicar el
## cambio [param what] (vacío = ninguno; los casos los usan las pruebas de validación y de huella).
func _ability_resources(what: String) -> Array[Resource]:
	var rules := CombatRules.new()
	var weapon: WeaponDefinition = _weapon(&"arma")
	var heavy: AttackDefinition = weapon.heavy_attack
	var arrow := ProjectileDefinition.new()
	arrow.id = &"flecha"
	var slow := StatusEffectDefinition.new()
	slow.id = &"lento"
	slow.kind = StatusEffectDefinition.Kind.SLOW
	slow.duration_s = 2.0
	slow.move_speed_scale = 0.5
	slow.stacking = StatusEffectDefinition.Stacking.STRONGEST
	var regen := StatusEffectDefinition.new()
	regen.id = &"cura"
	regen.kind = StatusEffectDefinition.Kind.HEAL_OVER_TIME
	regen.duration_s = 2.0
	regen.pulse_every_s = 0.5
	regen.pulse_amount = 10
	var strike: AbilityDefinition = _ability(&"golpe")
	strike.shape = HitShape.new()
	strike.base_damage = 40
	strike.stun_s = 0.5
	strike.dash_distance_m = 2.0
	strike.dash_from_s = 0.1
	strike.dash_to_s = 0.2
	var dash_curve := Curve.new()
	dash_curve.add_point(Vector2(0.0, 1.0))
	dash_curve.add_point(Vector2(1.0, 0.5))
	strike.dash_curve = dash_curve
	var shot: AbilityDefinition = _ability(&"disparo")
	shot.projectile = arrow
	shot.projectile_count = 2
	shot.projectile_spread_deg = 5.0
	shot.target_status = slow
	var wall: AbilityDefinition = _ability(&"muro")
	wall.channel = true
	wall.active_s = 2.0
	wall.recovery_s = 0.0
	wall.cooldown_s = 5.0
	wall.blocks = true
	wall.wall_half_extents = Vector3(1.0, 1.0, 0.1)
	weapon.abilities.assign([strike, shot, wall])
	heavy.projectile = arrow
	heavy.projectile_speed_mps = 30.0
	heavy.charge_speed_scale = 1.5
	var potion_a: AbilityDefinition = _potion(&"pocion_a")
	potion_a.self_status = regen
	var potion_b: AbilityDefinition = _potion(&"pocion_b")
	potion_b.stamina_restore = 100
	rules.consumables.assign([potion_a, potion_b])
	var template := EquipmentTemplate.new()
	template.id = &"plantilla"
	template.weapons.assign([weapon])
	template.consumable_charges = PackedInt32Array([2, 1])
	rules.default_template = template
	var resources: Array[Resource] = [rules, weapon, arrow, slow, regen]
	match what:
		# Validación (sección 2.2).
		"two_weapons":
			var other: WeaponDefinition = _weapon(&"otra", &"_b")
			other.abilities.assign([strike])
			resources.append(other)
		"weapon_and_consumable": rules.consumables.assign([potion_a, strike])
		"cooldown": strike.cooldown_s = 0.3
		"channel_recovery": wall.recovery_s = 0.1
		"consumable_cooldown": potion_a.cooldown_s = 1.0
		"shared_cooldown": rules.consumable_cooldown_s = 0.2
		"consumable_interrupt": potion_b.interrupt_on_damage = false
		"one_consumable": rules.consumables.assign([potion_a])
		"pulses": regen.duration_s = 2.2
		"root": slow.kind = StatusEffectDefinition.Kind.ROOT
		"slow": slow.move_speed_scale = 0.0
		"dash": strike.dash_to_s = 5.0
		"lifetime": arrow.lifetime_s = 0.0
		"count": shot.projectile_count = 6
		"npc_template": template.weapons.append(_weapon(&"npc_bicho", &"_n"))
		"npc_template_hidden":
			template.weapons.append(_weapon(&"npc_bicho", &"_n"))
			template.selectable = false
		"template_weapons": template.weapons.clear()
		"charges": template.consumable_charges = PackedInt32Array([16, 0])
		"combo": weapon.light_combo.clear()
		"four_abilities": weapon.abilities.append(_ability(&"cuarta"))
		"active": strike.active_s = 0.0
		"duplicate": shot.id = &"golpe"
		"single_light":
			weapon.light_combo.resize(1)
			strike.cast_s = 0.0
		# Huella: predichos.
		"ability_cast": strike.cast_s += 0.05
		"ability_active": shot.active_s += 0.05
		"ability_recovery": shot.recovery_s += 0.05
		"ability_cooldown": strike.cooldown_s += 1.0
		"ability_channel": wall.channel = false
		"ability_hold": wall.channel_hold = false
		"ability_breaks": wall.channel_breaks_on_move = true
		"ability_cancel_dodge": strike.cancel_to_dodge_from_s = 0.15
		"ability_cancel_attack": strike.cancel_to_attack_from_s = 0.15
		"ability_move": strike.move_speed_scale += 0.1
		"ability_turn": strike.turn_rate += 1.0
		"ability_lunge": strike.lunge_speed += 1.0
		"ability_dash": strike.dash_distance_m += 1.0
		"ability_dash_window": strike.dash_from_s = 0.05
		"ability_dash_curve": dash_curve.set_point_value(1, 0.2)
		"ability_dash_direction": strike.dash_direction = 2
		"ability_air": strike.usable_in_air = true
		"ability_stamina": potion_b.stamina_restore += 50
		"ability_blocks": wall.blocks = false
		"ability_projectile_count": shot.projectile_count = 3
		"ability_spread": shot.projectile_spread_deg += 1.0
		"ability_projectile_speed": shot.projectile_speed_mps += 5.0
		"slot_order": weapon.abilities.assign([shot, strike, wall])
		"can_block": weapon.can_block = false
		"swap": rules.swap_s = 0.5
		"swap_move": rules.swap_move_scale = 0.7
		"downed_move_scale": rules.downed_move_scale = 0.2
		"downed_turn_rate": rules.downed_turn_rate = 4.0
		"revive": rules.revive_s = 4.0
		"execute": rules.execute_s = 2.0
		"consumable_cooldown": rules.consumable_cooldown_s = 25.0
		"consumable_order": rules.consumables.assign([potion_b, potion_a])
		"aim_pivot": rules.aim_pivot_height = 1.7
		"aim_shoulder": rules.aim_shoulder_offset = 0.5
		"aim_v_offset": rules.aim_camera_v_offset = 0.2
		"aim_range": rules.aim_range_m = 120.0
		"aim_converge": rules.aim_converge_deg = 10.0
		"muzzle": rules.muzzle_height = 1.3
		"status_kind": regen.kind = StatusEffectDefinition.Kind.DAMAGE_OVER_TIME
		"status_scale": slow.move_speed_scale = 0.7
		"status_name": slow.id = &"lentitud"
		"arrow_gravity": arrow.gravity = 9.0
		"arrow_radius": arrow.radius_m = 0.1
		"arrow_lifetime": arrow.lifetime_s = 3.0
		"attack_projectile_speed": heavy.projectile_speed_mps += 5.0
		"attack_charge_speed": heavy.charge_speed_scale = 1.6
		"attack_projectile": weapon.light_combo[0].projectile = arrow
		# Huella: solo servidor.
		"ability_damage": strike.base_damage += 10
		"ability_damage_type": strike.damage_type = 1
		"ability_shape": strike.shape.range_m += 1.0
		"ability_stagger": strike.stagger_s = 0.3
		"ability_stun": strike.stun_s += 0.5
		"ability_knockback": strike.knockback_speed = 3.0
		"ability_hyper_armor": strike.hyper_armor = true
		"ability_unblockable": strike.unblockable = true
		"ability_target_status": shot.target_status = regen
		"ability_self_heal": potion_a.self_heal = 20
		"ability_interrupt": strike.interrupt_on_damage = true
		"ability_wall":
			wall.wall_half_extents = Vector3(2.0, 1.0, 0.2)
			wall.wall_forward_m = 1.0
		"status_duration": slow.duration_s = 3.0
		"status_pulse": regen.pulse_every_s = 0.25
		"status_amount": regen.pulse_amount = 20
		"status_stacking": slow.stacking = StatusEffectDefinition.Stacking.REFRESH
		"status_magnitude": regen.magnitude = 0.2
		"downed_health": rules.downed_health = 500
		"downed_s": rules.downed_s = 30.0
		"revived_health": rules.revived_health = 200
		"interact_range":
			rules.interact_range_m = 1.5
			rules.interact_keep_range_m = 2.0
		"ability_block":
			rules.ability_block_angle_deg = 160.0
			rules.ability_block_stamina_per_damage = 0.8
		"max_projectiles":
			rules.max_projectiles_per_shooter = 4
			rules.max_projectiles_per_zone = 32
		"template_charges": template.consumable_charges = PackedInt32Array([1, 1])
		"template_selectable": template.selectable = false
		"attack_stun": heavy.stun_s = 0.5
		"attack_on_hit_status": heavy.on_hit_status = slow
	return resources
