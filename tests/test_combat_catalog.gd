extends TestCase
## Tests for [CombatCatalog] (docs/combate.md section 2; docs/abilities.md section 2.2): loading
## data/combat/, IDs of each space requested by name, repeated ids, validation of ranges and of the
## rules of section 2.2, conversion to ticks, baked curves (dodge and advances), synthesized hit
## of the abilities, footprint of the predicted part and the fast path of simulate().

const DATA_DIR: String = "res://data/combat"


func after_each() -> void:
	# Some tests build separate catalogs; the global one is not touched, but just in case.
	CombatCatalog.reload()


# --- Loading and IDs --------------------------------------------------------------------------

func test_data_directory_loads_without_errors() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	assert_eq(tables.errors, PackedStringArray(), "the data in data/combat/ is valid")
	assert_true(tables.is_valid(), "is_valid()")
	assert_eq(_names_starting_with(tables.attack_ids, "sword_").size(), 4, "4 sword attacks: heavy and three light")
	assert_eq(_names_starting_with(tables.weapon_ids, "sword_").size(), 1, "a player weapon: sword and shield")
	assert_eq(_names_starting_with(tables.attack_ids, "npc_").size(), 8, "8 NPC attacks (light and heavy for 4 weapons)")
	assert_eq(_names_starting_with(tables.weapon_ids, "npc_").size(), 4, "4 NPC weapons")
	assert_eq(_names_starting_with(tables.attack_ids, "bow_").size(), 2, "2 bow attacks: fast and drawn")
	assert_eq(_names_starting_with(tables.weapon_ids, "bow").size(), 1, "the bow")
	assert_eq(tables.attacks.size(), 14, "14 attacks in total")
	assert_eq(tables.weapons.size(), 6, "6 weapons in total")
	assert_eq(tables.abilities.size(), 8, "6 abilities (3 for sword and shield, 3 for bow) and 2 potions")
	assert_eq(tables.statuses.size(), 4, "4 effects: bleed, potion_regen, rooted and slowed")
	assert_eq(tables.projectiles.size(), 1, "one projectile: the arrow")
	assert_eq(tables.templates.size(), 2, "2 templates: squire and shooter")
	assert_not_null(tables.rules, "there are rules")


func test_global_catalog_matches_the_directory() -> void:
	CombatCatalog.reload()
	var tables: CombatTables = CombatCatalog.tables()
	assert_true(tables.is_valid(), "the global catalog loads fine")
	assert_eq(CombatCatalog.prediction_hash(),
			CombatCatalog.build_from_directory(DATA_DIR).prediction_hash,
			"the global footprint is that of reading the folder")
	assert_same(CombatCatalog.tables(), tables, "the tables are loaded only once (lazy)")
	assert_same(CombatCatalog.rules(), tables.rules, "rules()")


func test_ids_are_alphabetical_from_one() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	# The IDs come from the alphabetical order of the names: nothing can depend on a fixed number (the NPC
	# attacks and weapons, which start with npc_, go before the sword ones).
	var attack_names: Array[String] = _sorted_names(tables.attack_ids)
	for i: int in attack_names.size():
		assert_eq(tables.attack_ids[StringName(attack_names[i])], i + 1,
				"%s is attack number %d" % [attack_names[i], i + 1])
	var weapon_names: Array[String] = _sorted_names(tables.weapon_ids)
	for i: int in weapon_names.size():
		assert_eq(tables.weapon_ids[StringName(weapon_names[i])], i + 1,
				"%s is weapon number %d" % [weapon_names[i], i + 1])
	assert_true(tables.attack_ids[&"npc_captain_crush"] < tables.attack_ids[&"sword_heavy"],
			"the NPC attacks go before the sword ones")
	assert_eq(tables.attack_ids[&"sword_light_2"], tables.attack_ids[&"sword_light_1"] + 1, "sword_light_2")
	assert_eq(tables.attack_ids[&"sword_light_3"], tables.attack_ids[&"sword_light_2"] + 1, "sword_light_3")
	assert_eq(tables.attack_ids[&"sword_heavy"], tables.attack_ids[&"sword_light_1"] - 1, "sword_heavy goes first")
	assert_null(tables.attack(0), "ID 0 is \"none\" in the attacks")
	assert_null(tables.weapon(0), "and in the weapons")
	assert_null(tables.attack(tables.attacks.size() + 1), "an ID that does not exist")
	assert_null(tables.weapon(tables.weapons.size() + 1), "a weapon that does not exist")
	assert_null(tables.attack(-1), "a negative ID")
	for i: int in tables.attacks.size():
		assert_eq(tables.attacks[i].id, i + 1, "the attack at index %d carries ID %d" % [i, i + 1])
		assert_eq(tables.attack(i + 1), tables.attacks[i], "attack(%d)" % (i + 1))
	var light_one: int = tables.attack_ids[&"sword_light_1"]
	assert_eq(tables.attack(light_one).name, &"sword_light_1", "the name is preserved")
	assert_eq(CombatCatalog.attack_id(&"sword_light_2"), light_one + 1, "attack_id() by name")
	assert_eq(CombatCatalog.weapon_id(&"sword_shield"), tables.weapon_ids[&"sword_shield"], "weapon_id() by name")
	assert_eq(CombatCatalog.attack_id(&"no_existe"), 0, "a name that does not exist gives 0")
	assert_eq(CombatCatalog.default_weapon_id(), tables.weapon_ids[&"sword_shield"],
			"the default weapon is sword and shield")


func test_ids_do_not_depend_on_the_order_the_resources_come_in() -> void:
	var a: AttackDefinition = _attack(&"b_attack")
	var b: AttackDefinition = _attack(&"a_attack")
	var c: AttackDefinition = _attack(&"c_attack")
	var rules := CombatRules.new()
	var forward: Array[Resource] = [rules, a, b, c]
	var backward: Array[Resource] = [c, b, a, rules]
	var first: CombatTables = CombatCatalog.build_from_resources(forward)
	var second: CombatTables = CombatCatalog.build_from_resources(backward)
	assert_eq(first.attack_ids, second.attack_ids, "same IDs")
	assert_eq(first.attack_ids[&"a_attack"], 1, "a_attack first")
	assert_eq(first.attack_ids[&"b_attack"], 2, "b_attack second")
	assert_eq(first.attack_ids[&"c_attack"], 3, "c_attack third")
	assert_eq(first.prediction_hash, second.prediction_hash, "and the same footprint")


func test_duplicate_attack_id_is_an_error() -> void:
	var first: AttackDefinition = _attack(&"golpe")
	var second: AttackDefinition = _attack(&"golpe")
	var resources: Array[Resource] = [CombatRules.new(), first, second]
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	assert_false(tables.is_valid(), "a repeated id invalidates the catalog")
	assert_true(_has_error(tables.errors, "id de ataque repetido: golpe"), _errors_text(tables.errors))
	assert_eq(tables.attacks.size(), 1, "only one stays")


func test_the_same_attack_object_twice_is_not_a_duplicate() -> void:
	# An attack that hangs from a weapon and is also loose in the folder is the same object.
	var weapon: WeaponDefinition = _weapon(&"arma")
	var resources: Array[Resource] = [CombatRules.new(), weapon, weapon.heavy_attack,
			weapon.light_combo[0], weapon]
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	assert_eq(tables.errors, PackedStringArray(), "no errors")
	assert_eq(tables.attacks.size(), 4, "4 attacks, none counted twice")
	assert_eq(tables.weapons.size(), 1, "a single weapon")


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
			"a weapon without an id")


func test_missing_rules_is_an_error_but_defaults_exist() -> void:
	var resources: Array[Resource] = [_attack(&"x")]
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	assert_true(_has_error(tables.errors, "falta un recurso CombatRules"), _errors_text(tables.errors))
	assert_not_null(tables.rules, "even so there are default rules")
	var two: Array[Resource] = [CombatRules.new(), CombatRules.new()]
	assert_true(_has_error(CombatCatalog.build_from_resources(two).errors, "hay 2 recursos CombatRules"),
			"two rules")


func test_unknown_resources_are_ignored() -> void:
	var resources: Array[Resource] = [CombatRules.new(), HitShape.new(), DodgeDefinition.new(),
			Curve.new()]
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	assert_eq(tables.errors, PackedStringArray(), "the other resources are not a problem")
	assert_eq(tables.attacks.size(), 0, "there are no attacks")


# --- Range validation -------------------------------------------------------------------------

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
			"minimum greater than the maximum")
	heavy.charge_min_s = 0.35
	heavy.charge_max_s = 5.0
	assert_true(_has_error(CombatCatalog.build_from_resources(resources).errors, "la carga debe cumplir"),
			"the maximum charge does not fit in 255 ticks")
	heavy.charge_max_s = 1.2
	heavy.charge_damage_scale = 0.5
	assert_true(_has_error(CombatCatalog.build_from_resources(resources).errors, "charge_damage_scale"),
			"damage scale less than 1")


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


# --- Conversion to ticks ----------------------------------------------------------------------

func test_seconds_to_ticks_uses_fixed_rounding() -> void:
	assert_eq(CombatCatalog.TICK_RATE, 60, "60 ticks per second")
	assert_eq(CombatCatalog.seconds_to_ticks(0.0), 0, "0")
	assert_eq(CombatCatalog.seconds_to_ticks(0.1), 6, "0,1 s")
	assert_eq(CombatCatalog.seconds_to_ticks(0.2), 12, "0.2 s (12.000000000000002 in floating point)")
	assert_eq(CombatCatalog.seconds_to_ticks(0.18), 11, "0.18 s = 10.8 ticks rounds to 11")
	assert_eq(CombatCatalog.seconds_to_ticks(0.38), 23, "0.38 s = 22.8 ticks rounds to 23")
	assert_eq(CombatCatalog.seconds_to_ticks(0.12), 7, "0.12 s = 7.2 ticks rounds to 7")
	assert_eq(CombatCatalog.seconds_to_ticks(1.2), 72, "1,2 s")
	assert_eq(CombatCatalog.seconds_to_ticks(0.35), 21, "0,35 s")
	assert_eq(CombatCatalog.seconds_to_ticks(1.0 / 120.0), 1, "half a tick rounds up")


func test_attack_ticks_for_the_sword() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	# [windup, active, recovery, combo window, cancel to dodge from]
	var expected: Dictionary[StringName, Array] = {
		&"sword_light_1": [12, 6, 18, 9, 24],
		&"sword_light_2": [11, 6, 18, 9, 23],
		&"sword_light_3": [15, 6, 27, 0, 30],
		&"sword_heavy": [24, 7, 33, 0, 42],
	}
	for attack_name: StringName in expected:
		var attack: AttackTicks = tables.attack(tables.attack_ids[attack_name])
		var want: Array = expected[attack_name]
		assert_eq(attack.windup_ticks, want[0], "%s: windup" % attack_name)
		assert_eq(attack.active_ticks, want[1], "%s: active hit" % attack_name)
		assert_eq(attack.recovery_ticks, want[2], "%s: recovery" % attack_name)
		assert_eq(attack.combo_window_ticks, want[3], "%s: combo window" % attack_name)
		assert_eq(attack.cancel_to_dodge_from_ticks, want[4], "%s: cancel to dodge" % attack_name)
		assert_eq(attack.total_ticks, want[0] + want[1] + want[2], "%s: total duration" % attack_name)
		assert_eq(attack.active_from(), want[0], "%s: active_from()" % attack_name)
		assert_eq(attack.active_to(), want[0] + want[1], "%s: active_to()" % attack_name)
		assert_eq(attack.combo_window_from(), attack.total_ticks - want[3],
				"%s: combo_window_from()" % attack_name)
	var heavy: AttackTicks = tables.attack(tables.attack_ids[&"sword_heavy"])
	assert_true(heavy.heavy, "the heavy one is heavy")
	assert_eq(heavy.charge_min_ticks, 21, "minimum charge 0.35 s")
	assert_eq(heavy.charge_max_ticks, 72, "maximum charge 1.2 s")
	assert_eq(heavy.stamina_cost, 150, "the heavy one costs 150")
	assert_near(heavy.charge_move_scale, 0.4, 1e-9, "movement while charging ×0.4")
	assert_near(heavy.move_speed_scale, 0.2, 1e-9, "hit movement ×0.2")
	assert_near(heavy.lunge_speed, 2.5, 1e-9, "advance 2.5 m/s")
	assert_true(heavy.hyper_armor, "poise")
	assert_eq(heavy.stagger_ticks, 30, "stagger 0.5 s")
	assert_near(heavy.knockback_speed, 4.0, 1e-9, "knockback 4 m/s")
	assert_near(heavy.charge_damage_scale, 1.7, 1e-9, "×1.7 at maximum charge")
	assert_eq(heavy.base_damage, 180, "damage 180")
	var light3: AttackTicks = tables.attack(tables.attack_ids[&"sword_light_3"])
	assert_eq(light3.stagger_ticks, 18, "the third light attack staggers 0.3 s")
	assert_eq(light3.base_damage, 130, "damage 130")
	for attack_name: StringName in expected:
		var attack: AttackTicks = tables.attack(tables.attack_ids[attack_name])
		assert_not_null(attack.shape, "%s has the shape of a hit" % attack_name)
		assert_near(attack.shape.range_m, 2.6, 1e-9, "%s: range 2.6 m" % attack_name)
		assert_near(attack.shape.angle_deg, 100.0, 1e-9, "%s: 100 degrees" % attack_name)
		assert_near(attack.turn_rate, 6.0, 1e-9, "%s: turn 6 rad/s" % attack_name)


func test_weapon_ticks_for_sword_and_shield() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	var weapon: WeaponTicks = tables.weapon(tables.weapon_ids[&"sword_shield"])
	assert_eq(weapon.name, &"sword_shield", "name")
	var light_one: int = tables.attack_ids[&"sword_light_1"]
	assert_eq(weapon.light_ids, PackedInt32Array([light_one, light_one + 1, light_one + 2]),
			"combo: light attacks 1, 2 and 3 in order")
	assert_eq(weapon.heavy_id, tables.attack_ids[&"sword_heavy"], "heavy")
	assert_eq(weapon.light_index(light_one + 1), 1, "light_index() of the second light attack")
	assert_eq(weapon.light_index(weapon.heavy_id), -1, "the heavy one is not a light attack")
	assert_near(weapon.block_move_scale, 0.5, 1e-9, "movement while blocking ×0.5")
	assert_near(weapon.block_turn_rate, 8.0, 1e-9, "turn while blocking 8 rad/s")
	assert_near(weapon.block_angle_deg, 120.0, 1e-9, "120-degree cone")
	assert_near(weapon.block_mitigation, 1.0, 1e-9, "for 100 %")
	var dodge: DodgeTicks = weapon.dodge
	assert_eq(dodge.duration_ticks, 27, "dodge of 0.45 s")
	assert_eq(dodge.invulnerable_from_ticks, 3, "invulnerable from 0.05 s")
	assert_eq(dodge.invulnerable_to_ticks, 18, "until 0.30 s (exclusive)")
	assert_eq(dodge.cancel_to_attack_from_ticks, 18, "to attack from 0.30 s")
	assert_eq(dodge.stamina_cost, 300, "300 of stamina cost")
	assert_near(dodge.distance_m, 4.5, 1e-9, "4,5 m")


func test_dodge_curve_is_baked_to_the_distance() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	var dodge: DodgeTicks = tables.weapon(tables.weapon_ids[&"sword_shield"]).dodge
	assert_eq(dodge.speeds.size(), dodge.duration_ticks, "one speed per tick")
	var distance: float = 0.0
	for speed: float in dodge.speeds:
		distance += speed / float(CombatCatalog.TICK_RATE)
		assert_true(speed >= 0.0, "no negative speed")
		assert_eq(speed, PlayerState.to_f32(speed), "each speed is exact in f32")
	assert_near(distance, 4.5, 1e-5, "the sum of v / 60 is the distance")
	assert_true(dodge.speeds[0] > dodge.speeds[dodge.speeds.size() - 1] * 5.0,
			"fast start: much quicker at the beginning than at the end")
	assert_eq(dodge.speed_at(0), dodge.speeds[0], "speed_at(0)")
	assert_eq(dodge.speed_at(1000), dodge.speeds[dodge.speeds.size() - 1], "beyond that it repeats the last one")
	assert_eq(dodge.speed_at(-1), 0.0, "before the start there is no speed")


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
		assert_near(speed, 6.0, 1e-5, "3 m in 0.5 s is 6 m/s on every tick")


# --- Footprint --------------------------------------------------------------------------------

func test_prediction_hash_is_stable() -> void:
	var first: int = CombatCatalog.build_from_directory(DATA_DIR).prediction_hash
	var second: int = CombatCatalog.build_from_directory(DATA_DIR).prediction_hash
	assert_eq(first, second, "two loads give the same footprint")
	assert_true(first >= 0 and first <= 0xFFFFFFFF, "es un u32")
	assert_true(first != 0, "no es 0")
	CombatCatalog.reload()
	assert_eq(CombatCatalog.prediction_hash(), first, "after reloading, the same")


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
		assert_true(changed != base_hash, "changing \"%s\" must change the footprint" % what)


func test_prediction_hash_ignores_server_only_values() -> void:
	var base_hash: int = _hash_of("")
	var server_only: Array[String] = [
		"damage", "damage_type", "hyper_armor", "stagger", "knockback", "charge_damage",
		"shape", "block_mitigation", "block_angle", "block_cost", "health_max", "respawn",
		"crit", "fall_damage", "parry_stagger",
	]
	for what: String in server_only:
		var changed: int = _hash_of(what)
		assert_eq(changed, base_hash, "changing \"%s\" (server only) must not change the footprint" % what)


func test_prediction_hash_depends_on_the_id_assignment() -> void:
	# If a client numbers the attacks differently, the state's action_id would not match.
	var rules := CombatRules.new()
	var first: Array[Resource] = [rules, _attack(&"a"), _attack(&"b")]
	var second: Array[Resource] = [rules, _attack(&"a"), _attack(&"c")]
	assert_true(CombatCatalog.build_from_resources(first).prediction_hash
			!= CombatCatalog.build_from_resources(second).prediction_hash,
			"another attack name, another footprint")


func test_sim_hash_includes_the_combat_hash() -> void:
	# NetProtocol.compute_sim_hash carries the catalog footprint and the protocol version (2 was phase 3
	# combat; 3, its revision; 4, phase 4's fort; 5, chat and parties).
	assert_true(NetProtocol.PROTOCOL_VERSION >= 4, "the fort protocol is version 4 or later")
	var scene: PackedScene = load("res://scenes/characters/player_character.tscn") as PackedScene
	var character: PlayerCharacter = scene.instantiate() as PlayerCharacter
	tree.root.add_child(character)
	var with_data: int = NetProtocol.compute_sim_hash(character)
	assert_eq(NetProtocol.compute_sim_hash(character), with_data, "stable")
	character.queue_free()
	# With another catalog footprint, the sim_hash changes.
	var tables: CombatTables = CombatCatalog.tables()
	var saved_hash: int = tables.prediction_hash
	tables.prediction_hash = saved_hash ^ 0x1234
	var scene2: PackedScene = load("res://scenes/characters/player_character.tscn") as PackedScene
	var other: PlayerCharacter = scene2.instantiate() as PlayerCharacter
	tree.root.add_child(other)
	var changed: int = NetProtocol.compute_sim_hash(other)
	tables.prediction_hash = saved_hash
	other.queue_free()
	assert_true(changed != with_data, "another catalog footprint, another sim_hash")


# --- Phase 4: abilities, effects, projectiles and templates (docs/abilities.md, section 2) ---

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
			assert_eq(ids[StringName(names[i])], i + 1, "%s %s is number %d" % [space, names[i], i + 1])
	for i: int in tables.abilities.size():
		assert_eq(tables.abilities[i].id, i + 1, "the ability at index %d carries ID %d" % [i, i + 1])
	# By name, in the global catalog (nobody writes an ID by hand).
	CombatCatalog.reload()
	var global: CombatTables = CombatCatalog.tables()
	for ability_name: StringName in [&"shield_bash", &"shield_rush", &"shield_wall", &"bow_volley",
			&"bow_slowing_shot", &"bow_evasive_shot", &"potion_health", &"potion_stamina"]:
		var id: int = CombatCatalog.ability_id(ability_name)
		assert_true(id > 0, "ability_id(%s)" % ability_name)
		assert_eq(CombatCatalog.ability(id).name, ability_name, "ability(ability_id(%s))" % ability_name)
	for status_name: StringName in [&"slowed", &"potion_regen", &"bleed", &"rooted"]:
		var id: int = CombatCatalog.status_id(status_name)
		assert_true(id > 0 and id <= 255, "status_id(%s) fits in a u8" % status_name)
		assert_eq(CombatCatalog.status(id).name, status_name, "status(status_id(%s))" % status_name)
	assert_eq(CombatCatalog.projectile(CombatCatalog.projectile_id(&"arrow")).name, &"arrow", "the arrow")
	assert_eq(CombatCatalog.template(CombatCatalog.template_id(&"squire")).id, &"squire", "the squire")
	assert_eq(CombatCatalog.template(CombatCatalog.template_id(&"marksman")).id, &"marksman", "the shooter")
	assert_eq(CombatCatalog.template_count(), 2, "two templates")
	assert_eq(CombatCatalog.default_template_id(), CombatCatalog.template_id(&"squire"),
			"the default template is the squire")
	assert_eq(CombatCatalog.consumable_ids(), PackedInt32Array([
		CombatCatalog.ability_id(&"potion_health"), CombatCatalog.ability_id(&"potion_stamina"),
	]), "consumables in button order: health (R) and stamina (T)")
	for missing: int in [CombatCatalog.ability_id(&"no_existe"), CombatCatalog.status_id(&"no_existe"),
			CombatCatalog.projectile_id(&"no_existe"), CombatCatalog.template_id(&"no_existe")]:
		assert_eq(missing, 0, "a name that does not exist gives 0")
	assert_null(global.ability(0), "0 is \"none\" in the abilities")
	assert_null(global.status(0), "in the effects")
	assert_null(global.projectile(0), "in the projectiles")
	assert_null(global.template(0), "and in the templates")
	assert_null(global.ability(global.abilities.size() + 1), "an ability that does not exist")


func test_sword_and_shield_abilities_in_ticks() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	var sword_id: int = tables.weapon_ids[&"sword_shield"]
	var weapon: WeaponTicks = tables.weapon(sword_id)
	var bash_id: int = tables.ability_ids[&"shield_bash"]
	var rush_id: int = tables.ability_ids[&"shield_rush"]
	var wall_id: int = tables.ability_ids[&"shield_wall"]
	assert_eq(weapon.ability_ids, PackedInt32Array([bash_id, rush_id, wall_id]), "slots 1, 2 and 3")
	assert_eq(weapon.ability_id(1), rush_id, "ability_id(1)")
	assert_eq(weapon.ability_id(3), 0, "out of range, 0")
	assert_true(weapon.can_block, "sword and shield blocks")
	# [cast, active, recovery, cooldown, slot] (docs/abilities.md, 2.3).
	var expected: Dictionary[StringName, Array] = {
		&"shield_bash": [18, 6, 24, 720, 0],
		&"shield_rush": [9, 24, 21, 960, 1],
		&"shield_wall": [12, 360, 0, 1080, 2],
	}
	for ability_name: StringName in expected:
		var ability: AbilityTicks = tables.ability(tables.ability_ids[ability_name])
		var want: Array = expected[ability_name]
		assert_eq(ability.cast_ticks, want[0], "%s: cast" % ability_name)
		assert_eq(ability.active_ticks, want[1], "%s: active" % ability_name)
		assert_eq(ability.recovery_ticks, want[2], "%s: recovery" % ability_name)
		assert_eq(ability.cooldown_ticks, want[3], "%s: cooldown" % ability_name)
		assert_eq(ability.slot, want[4], "%s: slot" % ability_name)
		assert_eq(ability.total_ticks, want[0] + want[1] + want[2], "%s: duration" % ability_name)
		assert_eq(ability.weapon_id, sword_id, "%s: sword and shield carries it" % ability_name)
		assert_false(ability.is_consumable(), "%s: it is not a consumable" % ability_name)
		assert_true(ability.cooldown_ticks >= ability.total_ticks + AbilityTicks.REARM_TICKS,
				"%s: cooldown ≥ duration + the action byte margin" % ability_name)
	var bash: AbilityTicks = tables.ability(bash_id)
	assert_eq(bash.hit.stun_ticks, 48, "the shield bash stuns 0.8 s")
	assert_true(bash.hit.unblockable, "unblockable")
	assert_eq(bash.hit.base_damage, 60, "60 damage")
	assert_eq(bash.hit.damage_type, DamageFormula.DamageType.BLUNT, "blunt")
	assert_near(bash.hit.shape.range_m, 2.2, 1e-9, "2.2 m sector")
	assert_near(bash.hit.shape.angle_deg, 90.0, 1e-9, "of 90 degrees")
	assert_near(bash.lunge_speed, 1.0, 1e-9, "advance 1 m/s")
	assert_near(bash.move_speed_scale, 0.2, 1e-9, "movement ×0.2")
	var rush: AbilityTicks = tables.ability(rush_id)
	assert_eq(rush.dash_from_ticks, 9, "the charge advances from the commit")
	assert_eq(rush.dash_to_ticks, 33, "during the whole active phase")
	assert_eq(rush.dash_speeds.size(), 24, "one advance speed per tick")
	var distance: float = 0.0
	for speed: float in rush.dash_speeds:
		distance += speed / float(CombatCatalog.TICK_RATE)
		assert_near(speed, 15.0, 1e-4, "flat curve: 6 m in 0.4 s is 15 m/s")
		assert_eq(speed, PlayerState.to_f32(speed), "exact in f32")
	assert_near(distance, 6.0, 1e-4, "advance of 6 m")
	assert_eq(rush.dash_direction, 0, "towards look_yaw")
	assert_true(rush.is_dashing(9) and rush.is_dashing(32), "advances in [9, 33)")
	assert_false(rush.is_dashing(8) or rush.is_dashing(33), "and not outside")
	assert_eq(rush.dash_speed_at(9), rush.dash_speeds[0], "dash_speed_at(9)")
	assert_eq(rush.dash_speed_at(33), 0.0, "no speed outside the window")
	assert_true(rush.hit.hyper_armor, "poise during the active phase")
	assert_eq(rush.hit.stagger_ticks, 24, "stagger 0.4 s")
	assert_near(rush.hit.knockback_speed, 6.0, 1e-9, "knockback 6 m/s")
	assert_near(rush.hit.shape.range_m, 1.8, 1e-9, "1.8 m sector")
	assert_near(rush.hit.shape.angle_deg, 140.0, 1e-9, "of 140 degrees")
	var wall: AbilityTicks = tables.ability(wall_id)
	assert_true(wall.channel and wall.channel_hold and wall.blocks, "the wall is a channeled ability that blocks and is released")
	assert_false(wall.channel_breaks_on_move, "moving does not end it")
	assert_eq(wall.cancel_to_dodge_from_ticks, 12, "to dodge from the end of the cast")
	assert_eq(wall.cancel_to_attack_from_ticks, 372, "without recovery: -1 is the end")
	assert_near(wall.move_speed_scale, 0.3, 1e-9, "movement ×0.3")
	assert_near(wall.turn_rate, 4.0, 1e-9, "turn 4")
	assert_vec_near(wall.wall_half_extents, Vector3(1.3, 1.0, 0.15), 1e-6, "box of 2.6 × 2.0 × 0.3 m")
	assert_near(wall.wall_forward_m, 0.7, 1e-9, "0.7 m in front")
	assert_null(wall.hit.shape, "the wall does not hit")


func test_bow_and_arrow_in_ticks() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	var bow_id: int = tables.weapon_ids[&"bow"]
	var bow: WeaponTicks = tables.weapon(bow_id)
	var arrow_id: int = tables.projectile_ids[&"arrow"]
	assert_eq(bow.light_ids, PackedInt32Array([tables.attack_ids[&"bow_quick"]]), "the light attack is the fast shot (combo of 1)")
	assert_eq(bow.heavy_id, tables.attack_ids[&"bow_drawn"], "the heavy one is the drawn shot")
	assert_false(bow.can_block, "the bow does not block")
	assert_eq(bow.dodge.duration_ticks, 27, "the sword's dodge")
	assert_eq(bow.ability_ids, PackedInt32Array([tables.ability_ids[&"bow_volley"],
			tables.ability_ids[&"bow_slowing_shot"], tables.ability_ids[&"bow_evasive_shot"]]),
			"fan, hobbling and back jump")
	var quick: AttackTicks = tables.attack(tables.attack_ids[&"bow_quick"])
	assert_eq([quick.windup_ticks, quick.active_ticks, quick.recovery_ticks], [15, 1, 21], "fast: 15 + 1 + 21")
	assert_eq(quick.total_ticks, 37, "37 ticks")
	assert_eq(quick.cancel_to_dodge_from_ticks, 16, "to dodge from 0.27 s")
	assert_eq(quick.projectile_id, arrow_id, "fires an arrow")
	assert_near(quick.projectile_speed_mps, 45.0, 1e-9, "a 45 m/s")
	assert_eq(quick.base_damage, 60, "60")
	assert_eq(quick.damage_type, DamageFormula.DamageType.PIERCE, "piercing")
	assert_null(quick.shape, "no shape: with a projectile it can be null")
	assert_near(quick.move_speed_scale, 0.5, 1e-9, "movement ×0.5")
	assert_near(quick.turn_rate, 8.0, 1e-9, "turn 8")
	var drawn: AttackTicks = tables.attack(tables.attack_ids[&"bow_drawn"])
	assert_true(drawn.heavy, "the drawn shot is a heavy one")
	assert_eq([drawn.windup_ticks, drawn.active_ticks, drawn.recovery_ticks], [3, 1, 18], "after release: 3 + 1 + 18")
	assert_eq([drawn.charge_min_ticks, drawn.charge_max_ticks], [21, 60], "charge 0.35-1.0 s")
	assert_near(drawn.projectile_speed_mps, 40.0, 1e-9, "40 m/s at minimum charge")
	assert_near(drawn.charge_speed_scale, 1.75, 1e-9, "70 m/s at maximum charge")
	assert_near(drawn.charge_damage_scale, 2.0, 1e-9, "90 → 180")
	assert_eq(drawn.stamina_cost, 0, "no stamina cost")
	assert_near(drawn.charge_move_scale, 0.5, 1e-9, "charge: movement ×0.5")
	assert_near(drawn.charge_turn_rate, 8.0, 1e-9, "charge: turn 8")
	# [cast, active, recovery, cooldown, speed, damage]
	var expected: Dictionary[StringName, Array] = {
		&"bow_volley": [18, 1, 24, 600, 45.0, 55],
		&"bow_slowing_shot": [21, 1, 18, 720, 55.0, 60],
		&"bow_evasive_shot": [18, 1, 15, 840, 50.0, 60],
	}
	for ability_name: StringName in expected:
		var ability: AbilityTicks = tables.ability(tables.ability_ids[ability_name])
		var want: Array = expected[ability_name]
		assert_eq([ability.cast_ticks, ability.active_ticks, ability.recovery_ticks], want.slice(0, 3),
				"%s: phases" % ability_name)
		assert_eq(ability.cooldown_ticks, want[3], "%s: cooldown" % ability_name)
		assert_near(ability.projectile_speed_mps, want[4], 1e-9, "%s: speed" % ability_name)
		assert_eq(ability.hit.base_damage, want[5], "%s: damage" % ability_name)
		assert_eq(ability.projectile_id, arrow_id, "%s: arrow" % ability_name)
		assert_eq(ability.hit.projectile_id, arrow_id, "%s: the synthesized hit carries the arrow" % ability_name)
		assert_eq(ability.weapon_id, bow_id, "%s: of the bow" % ability_name)
	var volley: AbilityTicks = tables.ability(tables.ability_ids[&"bow_volley"])
	assert_eq(volley.projectile_count, 3, "fan of 3 arrows")
	assert_near(volley.projectile_spread_deg, 7.0, 1e-9, "at ±7 degrees")
	var slowing: AbilityTicks = tables.ability(tables.ability_ids[&"bow_slowing_shot"])
	assert_eq(slowing.hit.on_hit_status_id, tables.status_ids[&"slowed"], "the hobbling one slows")
	var evasive: AbilityTicks = tables.ability(tables.ability_ids[&"bow_evasive_shot"])
	assert_eq([evasive.dash_from_ticks, evasive.dash_to_ticks, evasive.dash_direction], [0, 18, 1],
			"back jump in [0, 0.3 s)")
	var distance: float = 0.0
	for speed: float in evasive.dash_speeds:
		distance += speed / float(CombatCatalog.TICK_RATE)
	assert_near(distance, 4.0, 1e-4, "de 4 m")
	assert_true(evasive.dash_speeds[0] > evasive.dash_speeds[evasive.dash_speeds.size() - 1],
			"faster at the beginning")
	var arrow: ProjectileTicks = tables.projectile(arrow_id)
	assert_near(arrow.gravity, 6.0, 1e-9, "gravity 6 m/s²")
	assert_near(arrow.radius_m, 0.05, 1e-9, "radius 5 cm")
	assert_eq(arrow.lifetime_ticks, 120, "2 s of life")


func test_consumables_statuses_templates_and_rules_in_ticks() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	assert_eq(tables.consumable_cooldown_ticks, 1200, "shared cooldown of 20 s")
	assert_eq(tables.swap_ticks, 24, "weapon swap 0.4 s")
	assert_eq(tables.revive_ticks, 180, "revive 3 s")
	assert_eq(tables.execute_ticks, 60, "finish off 1 s")
	assert_eq(tables.downed_ticks, 1200, "bleed out 20 s")
	var health: AbilityTicks = tables.ability(tables.ability_ids[&"potion_health"])
	var stamina: AbilityTicks = tables.ability(tables.ability_ids[&"potion_stamina"])
	assert_eq([health.cast_ticks, health.active_ticks, health.recovery_ticks], [36, 1, 12], "drink health: 36 + 1 + 12")
	assert_eq([stamina.cast_ticks, stamina.active_ticks, stamina.recovery_ticks], [24, 1, 12], "drink stamina: 24 + 1 + 12")
	assert_eq([health.consumable_index, stamina.consumable_index], [0, 1], "R y T")
	assert_eq([health.slot, health.weapon_id], [-1, 0], "no slot or weapon")
	assert_true(health.is_consumable() and stamina.is_consumable(), "they are consumables")
	assert_eq(health.cooldown_ticks, 0, "they use the shared cooldown")
	assert_true(health.interrupt_on_damage and stamina.interrupt_on_damage, "a hit interrupts")
	assert_eq(health.self_status_id, tables.status_ids[&"potion_regen"], "the health one heals over time")
	assert_eq(stamina.stamina_restore, 400, "+400 stamina")
	assert_near(health.move_speed_scale, 0.4, 1e-9, "movement ×0.4")
	var slowed: StatusTicks = tables.status(tables.status_ids[&"slowed"])
	assert_eq(slowed.kind, StatusEffectDefinition.Kind.SLOW, "slowed slows")
	assert_near(slowed.move_speed_scale, 0.6, 1e-9, "×0,6")
	assert_eq(slowed.duration_ticks, 180, "3 s")
	assert_eq(slowed.stacking, StatusEffectDefinition.Stacking.STRONGEST, "the strongest wins")
	assert_true(slowed.is_movement() and slowed.is_harmful(), "movement and harmful")
	var regen: StatusTicks = tables.status(tables.status_ids[&"potion_regen"])
	assert_eq([regen.pulse_ticks, regen.pulse_amount, regen.duration_ticks], [30, 50, 180], "50 every 0.5 s for 3 s")
	assert_eq(regen.duration_ticks / regen.pulse_ticks, 6, "6 pulses")
	assert_false(regen.is_harmful(), "the healing is not harmful")
	var bleed: StatusTicks = tables.status(tables.status_ids[&"bleed"])
	assert_eq([bleed.pulse_ticks, bleed.pulse_amount, bleed.duration_ticks, bleed.max_stacks], [60, 15, 360, 3],
			"15 per stack every 1 s for 6 s, up to 3")
	assert_eq(bleed.stacking, StatusEffectDefinition.Stacking.STACK, "it stacks")
	assert_true(bleed.has_pulses() and not bleed.is_movement(), "pulses, no movement")
	var rooted: StatusTicks = tables.status(tables.status_ids[&"rooted"])
	assert_eq(rooted.kind, StatusEffectDefinition.Kind.ROOT, "rooted roots")
	assert_eq(rooted.move_speed_scale, 0.0, "scale 0")
	assert_eq(rooted.duration_ticks, 90, "1,5 s")
	var squire: int = tables.template_ids[&"squire"]
	var marksman: int = tables.template_ids[&"marksman"]
	assert_eq(tables.template_weapons(squire), PackedInt32Array([tables.weapon_ids[&"sword_shield"]]),
			"squire: sword and shield")
	assert_eq(tables.template_weapons(marksman), PackedInt32Array([tables.weapon_ids[&"bow"],
			tables.weapon_ids[&"sword_shield"]]), "shooter: bow and sword and shield")
	assert_eq(tables.template_charges_of(squire), CombatState.pack_charges(3, 2), "charges [3, 2]")
	assert_eq(tables.template_charges_of(marksman), CombatState.pack_charges(2, 3), "charges [2, 3]")
	assert_true(tables.template(squire).selectable and tables.template(marksman).selectable, "selectable")
	assert_eq(tables.default_template_id, squire, "by default, the squire")
	assert_eq(tables.template_weapons(0), PackedInt32Array(), "a template that does not exist has no weapons")
	assert_eq(tables.template_charges_of(99), 0, "nor charges")


func test_the_synthesized_hit_has_the_ability_windows_and_its_source() -> void:
	var tables: CombatTables = CombatCatalog.build_from_directory(DATA_DIR)
	for ability: AbilityTicks in tables.abilities:
		var hit: AttackTicks = ability.hit
		if not assert_not_null(hit, "%s has a synthesized hit" % ability.name):
			continue
		assert_eq(hit.id, CombatSource.make(CombatSource.Kind.ABILITY, ability.id), "%s: its id is the source" % ability.name)
		assert_eq(CombatSource.kind_of(hit.id), CombatSource.Kind.ABILITY, "%s: of ability" % ability.name)
		assert_eq(CombatSource.id_of(hit.id), ability.id, "%s: with its id" % ability.name)
		assert_eq(hit.name, ability.name, "%s: name" % ability.name)
		assert_eq(hit.windup_ticks, ability.cast_ticks, "%s: windup = cast" % ability.name)
		assert_eq(hit.active_ticks, ability.active_ticks, "%s: active" % ability.name)
		assert_eq(hit.recovery_ticks, ability.recovery_ticks, "%s: recovery" % ability.name)
		assert_eq(hit.total_ticks, ability.total_ticks, "%s: total" % ability.name)
		assert_eq(hit.active_from(), ability.active_from(), "%s: the hit starts at the commit" % ability.name)
		assert_false(tables.attacks.has(hit), "%s: it is not in the attack table" % ability.name)


func test_ability_validation_follows_section_2_2() -> void:
	var base: Array[Resource] = _ability_resources("")
	assert_eq(CombatCatalog.build_from_resources(base).errors, PackedStringArray(),
			"the test catalog is valid")
	var cases: Dictionary[String, String] = {
		"está en más de un arma": "two_weapons",
		"en los consumibles": "weapon_and_consumable",
		"la reutilización debe ser al menos la duración + 6 ticks": "cooldown",
		"la reutilización debe ser al menos la duración +": "cooldown_rearm",
		"una canalización no lleva recuperación": "channel_recovery",
		"un consumible no lleva reutilización propia": "consumable_cooldown",
		"la reutilización compartida debe ser al menos su duración + 6 ticks": "shared_cooldown",
		"la reutilización compartida debe ser al menos su duración +": "shared_cooldown_rearm",
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
	# A template that is not selectable can carry NPC weapons (tests and NPCs).
	var npc_ok: Array[Resource] = _ability_resources("npc_template_hidden")
	assert_eq(CombatCatalog.build_from_resources(npc_ok).errors, PackedStringArray(),
			"selectable = false allows npc_* weapons")
	# With cast = 0 the commit is the first tick and a 1-hit combo is valid.
	var single: Array[Resource] = _ability_resources("single_light")
	assert_eq(CombatCatalog.build_from_resources(single).errors, PackedStringArray(), "1-hit combo")


func test_status_and_template_ids_fit_in_a_byte() -> void:
	var resources: Array[Resource] = [CombatRules.new()]
	for i: int in 256:
		var effect := StatusEffectDefinition.new()
		effect.id = StringName("efecto_%03d" % i)
		resources.append(effect)
	var tables: CombatTables = CombatCatalog.build_from_resources(resources)
	assert_true(_has_error(tables.errors, "hay 256 efectos y caben 255"), _errors_text(tables.errors))
	resources.pop_back()
	assert_eq(CombatCatalog.build_from_resources(resources).errors, PackedStringArray(), "255 do fit")


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
		assert_true(changed != base_hash, "changing \"%s\" must change the footprint" % what)


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
		assert_eq(changed, base_hash, "changing \"%s\" (server only) must not change the footprint" % what)


func test_the_fast_path_of_simulate_does_not_look_up_the_catalog() -> void:
	# The fast path of ActionMachine.step (no action, no combat buttons, nothing pending)
	# does not look up the weapon or walk the ability slots: the CombatTables counters
	# count it (the cost, the micro-bench in tools/combat_balance.gd).
	CombatCatalog.reload()
	var tables: CombatTables = CombatCatalog.tables()
	var scene: PackedScene = load("res://scenes/characters/player_character.tscn") as PackedScene
	var character: PlayerCharacter = scene.instantiate() as PlayerCharacter
	tree.root.add_child(character)
	# Inside one physics tick, like prediction when it replays inputs.
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
	assert_eq(tables.weapon_lookups, weapons_before, "60 ticks idle or running: no weapon lookup")
	assert_eq(tables.ability_lookups, abilities_before, "nor of abilities")
	# Control: a combat button does leave the fast path and looks up the weapon.
	var attack := PlayerInput.new()
	attack.tick = 61
	attack.buttons = PlayerInput.PRIMARY
	character.simulate(attack, dt)
	assert_true(tables.weapon_lookups > weapons_before, "PRIMARY does look up the weapon (the counter works)")
	character.queue_free()


# --- Utilities --------------------------------------------------------------------------------

## Names (sorted) of [param ids] (name -> ID).
func _sorted_names(ids: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for key: StringName in ids:
		names.append(String(key))
	names.sort()
	return names


## The names in [param ids] that start with [param prefix].
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


## A complete, valid weapon with its own attacks (the ids carry [param suffix]).
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


## Footprint of a test weapon after applying the change [param what] (empty = none).
func _hash_of(what: String) -> int:
	var weapon: WeaponDefinition = _weapon(&"arma")
	var rules := CombatRules.new()
	var light: AttackDefinition = weapon.light_combo[0]
	var heavy: AttackDefinition = weapon.heavy_attack
	var dodge: DodgeDefinition = weapon.dodge
	match what:
		# Predicted.
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
		# Server only.
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


## Breaks [param attack] according to the case in [method test_attack_validation_detects_bad_values].
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


## A complete phase 4 test catalog (rules with two potions and a default template,
## a weapon with an advancing hit, a shot and a wall, an arrow and two effects) after applying the
## change [param what] (empty = none; the cases are used by the validation and footprint tests).
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
		# Validation (section 2.2).
		"two_weapons":
			var other: WeaponDefinition = _weapon(&"otra", &"_b")
			other.abilities.assign([strike])
			resources.append(other)
		"weapon_and_consumable": rules.consumables.assign([potion_a, strike])
		"cooldown": strike.cooldown_s = 0.3
		# Duration + 1 tick is no longer enough: the action byte requires REARM_TICKS in NONE between two uses.
		"cooldown_rearm": strike.cooldown_s = 0.3 + float(AbilityTicks.REARM_TICKS - 1) / 60.0
		"channel_recovery": wall.recovery_s = 0.1
		"consumable_cooldown": potion_a.cooldown_s = 1.0
		"shared_cooldown": rules.consumable_cooldown_s = 0.2
		"shared_cooldown_rearm": rules.consumable_cooldown_s = 0.3 + float(AbilityTicks.REARM_TICKS - 1) / 60.0
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
		# Footprint: predicted.
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
		# Footprint: server only.
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
