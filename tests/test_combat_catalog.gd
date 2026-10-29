extends TestCase
## Pruebas de [CombatCatalog] (docs/combate.md sección 2): carga de data/combat/, IDs, ids
## repetidos, validación de rangos, conversión a ticks, curva de la esquiva horneada y huella de
## la parte predicha.

const DATA_DIR: String = "res://data/combat"


func after_each() -> void:
	# Algunas pruebas construyen catálogos aparte; el global no se toca, pero por si acaso.
	CombatCatalog.reload()


# --- Carga y IDs ------------------------------------------------------------------------------

func test_data_directory_loads_without_errors() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	assert_eq(tables.errors, PackedStringArray(), "los datos de data/combat/ son válidos")
	assert_true(tables.is_valid(), "is_valid()")
	assert_eq(tables.attacks.size(), 4, "4 ataques: fuerte y tres ligeros")
	assert_eq(tables.weapons.size(), 1, "un arma: espada y escudo")
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
	assert_eq(tables.attack_ids[&"sword_heavy"], 1, "sword_heavy es el primero por orden alfabético")
	assert_eq(tables.attack_ids[&"sword_light_1"], 2, "sword_light_1")
	assert_eq(tables.attack_ids[&"sword_light_2"], 3, "sword_light_2")
	assert_eq(tables.attack_ids[&"sword_light_3"], 4, "sword_light_3")
	assert_eq(tables.weapon_ids[&"sword_shield"], 1, "el arma tiene el ID 1 (espacio propio)")
	assert_null(tables.attack(0), "el ID 0 es «ninguno» en los ataques")
	assert_null(tables.weapon(0), "y en las armas")
	assert_null(tables.attack(5), "un ID que no existe")
	assert_null(tables.weapon(2), "un arma que no existe")
	assert_null(tables.attack(-1), "un ID negativo")
	for i: int in tables.attacks.size():
		assert_eq(tables.attacks[i].id, i + 1, "el ataque en el índice %d lleva el ID %d" % [i, i + 1])
		assert_eq(tables.attack(i + 1), tables.attacks[i], "attack(%d)" % (i + 1))
	assert_eq(tables.attack(2).name, &"sword_light_1", "el nombre se conserva")
	assert_eq(CombatCatalog.attack_id(&"sword_light_2"), 3, "attack_id() por nombre")
	assert_eq(CombatCatalog.weapon_id(&"sword_shield"), 1, "weapon_id() por nombre")
	assert_eq(CombatCatalog.attack_id(&"no_existe"), 0, "un nombre que no existe da 0")
	assert_eq(CombatCatalog.default_weapon_id(), 1, "el arma por defecto es la espada y escudo")


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
		"el combo ligero debe tener 3 golpes": "combo",
		"falta el ataque fuerte": "heavy",
		"falta la esquiva": "dodge",
		"block_mitigation fuera de rango": "mitigation",
		"parámetros de bloqueo negativos": "negative",
	}
	for expected: String in cases:
		var weapon: WeaponDefinition = _weapon(&"arma")
		match cases[expected]:
			"combo":
				weapon.light_combo.pop_back()
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
	var weapon: WeaponTicks = tables.weapon(1)
	assert_eq(weapon.name, &"sword_shield", "nombre")
	assert_eq(weapon.light_ids, PackedInt32Array([2, 3, 4]), "combo: ligeros 1, 2 y 3 en orden")
	assert_eq(weapon.heavy_id, 1, "fuerte")
	assert_eq(weapon.light_index(3), 1, "light_index() del segundo ligero")
	assert_eq(weapon.light_index(1), -1, "el fuerte no es un ligero")
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
	var dodge: DodgeTicks = tables.weapon(1).dodge
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
	# NetProtocol.compute_sim_hash lleva la huella del catálogo y la versión 2 del protocolo.
	assert_eq(NetProtocol.PROTOCOL_VERSION, 2, "el protocolo del combate es la versión 2")
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


# --- Utilidades -------------------------------------------------------------------------------

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
