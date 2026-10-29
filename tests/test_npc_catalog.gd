extends TestCase
## Pruebas de [NpcCatalog] y de los datos de los PNJ (MUN-07, MUN-08; docs/fuerte.md 4.2): los ids 1..n por
## orden alfabético que usa el cliente, las definiciones de [code]data/npcs/[/code], y que las armas de PNJ
## de [code]data/combat/npc_*.tres[/code] tienen la anticipación legible (≥ 0,45 s los ligeros, ≥ 0,70 s los
## fuertes) y solo el golpe fuerte del Capitán es imbloqueable.

const LIGHT_MIN_WINDUP_S: float = 0.45
const HEAVY_MIN_WINDUP_S: float = 0.70


func before_each() -> void:
	NpcCatalog.reload()
	BossInfo.clear_cache()


func after_each() -> void:
	NpcCatalog.reload()
	BossInfo.clear_cache()


func test_the_data_directory_loads_without_errors() -> void:
	assert_eq(NpcCatalog.get_errors(), PackedStringArray(), "los datos de data/npcs/ son válidos")
	assert_eq(NpcCatalog.count(), 5, "hueco, capitán del Vado, guardián, capitán del reino y guardia del reino")


func test_ids_are_one_to_n_in_alphabetical_order_of_the_file_names() -> void:
	var files: PackedStringArray = DirAccess.get_files_at(NpcCatalog.DATA_DIR)
	var expected: PackedStringArray = NpcCatalog.ids_in_order(files)
	var ids: Array[StringName] = NpcCatalog.ids()
	assert_eq(ids.size(), expected.size(), "una definición por archivo")
	for index: int in expected.size():
		assert_eq(String(ids[index]), expected[index], "la número %d es %s" % [index + 1, expected[index]])
		assert_eq(NpcCatalog.number_of(ids[index]), index + 1)
		var definition: NpcDefinition = NpcCatalog.get_by_number(index + 1)
		assert_not_null(definition)
		assert_eq(definition.id, ids[index], "el id de la definición es el del archivo")
		assert_true(NpcCatalog.get_definition(ids[index]) == definition, "get_definition() da la misma")
	assert_null(NpcCatalog.get_by_number(0), "el 0 es «sin definición»")
	assert_null(NpcCatalog.get_by_number(expected.size() + 1), "más allá del último, nada")
	assert_eq(NpcCatalog.number_of(&"no_existe"), 0)
	assert_null(NpcCatalog.get_definition(&"no_existe"))


func test_the_client_boss_info_resolves_the_same_numbers() -> void:
	for id: StringName in NpcCatalog.ids():
		var number: int = NpcCatalog.number_of(id)
		var info: Dictionary = BossInfo.lookup(number)
		assert_eq(info.get("name", ""), String(id), "BossInfo da el mismo nombre para el %d" % number)
		assert_eq(BossInfo.is_boss(number), NpcCatalog.get_definition(id).is_boss,
				"y el mismo is_boss para %s" % id)


func test_the_spawner_ids_of_the_zone_exist_in_the_catalog() -> void:
	for id: StringName in [&"hollow", &"ford_captain", &"gate_guardian", &"realm_guard", &"realm_captain"]:
		assert_not_null(NpcCatalog.get_definition(id), "existe %s" % id)


func test_every_definition_is_coherent() -> void:
	for id: StringName in NpcCatalog.ids():
		var definition: NpcDefinition = NpcCatalog.get_definition(id)
		assert_false(definition.display_name.is_empty(), "%s: tiene nombre" % id)
		assert_true(definition.max_health > 0, "%s: tiene vida" % id)
		assert_true(CombatCatalog.weapon_id(definition.weapon_id) > 0, "%s: su arma existe" % id)
		assert_true(definition.leash_radius > definition.perception_radius * 0.5 or definition.ignores_safe_area,
				"%s: la correa deja perseguir" % id)
		assert_true(definition.lose_radius >= definition.perception_radius * 0.5, "%s: radios coherentes" % id)
		assert_true(definition.reaction_s.x <= definition.reaction_s.y, "%s: reacción mínima <= máxima" % id)
		assert_true(definition.attack_gap_s.x <= definition.attack_gap_s.y, "%s: pausas mínima <= máxima" % id)
		assert_true(definition.block_s.x <= definition.block_s.y, "%s: bloqueo mínimo <= máximo" % id)
		if definition.garrison_id != &"":
			assert_not_null(NpcCatalog.get_definition(definition.garrison_id), "%s: la guarnición existe" % id)
			assert_false(NpcCatalog.get_definition(definition.garrison_id).is_boss and not definition.is_boss,
					"%s: un PNJ común no se sustituye por un jefe" % id)
		if definition.reinforcement_id != &"":
			assert_not_null(NpcCatalog.get_definition(definition.reinforcement_id), "%s: sus refuerzos existen" % id)
			assert_true(definition.reinforcement_count > 0, "%s: llama a alguien" % id)


func test_the_key_roles_have_the_agreed_traits() -> void:
	var hollow: NpcDefinition = NpcCatalog.get_definition(&"hollow")
	assert_false(hollow.is_boss)
	assert_false(hollow.ignores_safe_area)
	assert_near(hollow.alert_radius, 25.0, 1e-9, "los Huecos se avisan a 25 m")
	assert_eq(hollow.garrison_id, &"realm_guard", "con dueño, los Huecos dan paso a los guardias del reino")
	var captain: NpcDefinition = NpcCatalog.get_definition(&"ford_captain")
	assert_true(captain.is_boss, "el Capitán del Vado es jefe")
	assert_true(captain.shouts, "grita")
	assert_eq(captain.reinforcement_id, &"hollow", "los refuerzos son Huecos")
	assert_eq(captain.reinforcement_count, 2, "dos")
	assert_near(captain.reinforcement_health_fraction, 0.5, 1e-9, "al 50 % de vida")
	assert_true(captain.special_every > 0, "lanza el golpe imbloqueable cada pocos ataques")
	assert_eq(captain.garrison_id, &"realm_captain")
	var guardian: NpcDefinition = NpcCatalog.get_definition(&"gate_guardian")
	assert_true(guardian.ignores_safe_area, "el Guardián de la Puerta ignora la zona segura")
	assert_false(guardian.is_boss)
	assert_true(NpcCatalog.get_definition(&"realm_captain").is_boss, "el capitán del reino es jefe")
	assert_false(NpcCatalog.get_definition(&"realm_guard").is_boss)


func test_npc_weapons_have_legible_windups() -> void:
	var checked: int = 0
	for weapon_name: StringName in CombatCatalog.tables().weapon_ids:
		if not String(weapon_name).begins_with("npc_"):
			continue
		var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(weapon_name))
		var light_min: int = CombatCatalog.seconds_to_ticks(LIGHT_MIN_WINDUP_S)
		var heavy_min: int = CombatCatalog.seconds_to_ticks(HEAVY_MIN_WINDUP_S)
		for light_id: int in weapon.light_ids:
			var light: AttackTicks = CombatCatalog.attack(light_id)
			assert_true(light.windup_ticks >= light_min, "%s: el ligero %s avisa %d ticks (mínimo %d)"
					% [weapon_name, light.name, light.windup_ticks, light_min])
			assert_false(light.heavy)
			assert_eq(light.stamina_cost, 0, "%s: el ligero no cuesta resistencia" % weapon_name)
			assert_eq(light.combo_window_ticks, 0, "%s: sin enlace: cada ataque es una decisión" % weapon_name)
		var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
		assert_true(heavy.heavy)
		assert_true(heavy.windup_ticks >= heavy_min, "%s: el fuerte %s avisa %d ticks (mínimo %d)"
				% [weapon_name, heavy.name, heavy.windup_ticks, heavy_min])
		assert_true(heavy.charge_min_ticks >= 1 and heavy.charge_max_ticks >= heavy.charge_min_ticks,
				"%s: carga válida" % weapon_name)
		checked += 1
	assert_eq(checked, 4, "las cuatro armas de PNJ")


func test_only_the_captains_heavy_strike_is_unblockable() -> void:
	var unblockable: Array[StringName] = []
	for attack_name: StringName in CombatCatalog.tables().attack_ids:
		if CombatCatalog.attack(CombatCatalog.attack_id(attack_name)).unblockable:
			unblockable.append(attack_name)
	assert_eq(unblockable, [&"npc_captain_crush"] as Array[StringName])
	var crush: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"npc_captain_crush"))
	assert_true(crush.heavy and crush.hyper_armor, "es un fuerte con entereza")
	assert_true(crush.windup_ticks >= CombatCatalog.seconds_to_ticks(1.0), "avisa un segundo entero")


func test_the_unblockable_flag_is_server_only_and_does_not_change_the_prediction_hash() -> void:
	var with_flag: int = CombatCatalog.prediction_hash()
	var crush: AttackDefinition = load("res://data/combat/npc_captain_crush.tres") as AttackDefinition
	assert_true(crush.unblockable)
	crush.unblockable = false
	CombatCatalog.reload()
	var without_flag: int = CombatCatalog.prediction_hash()
	crush.unblockable = true
	CombatCatalog.reload()
	assert_eq(without_flag, with_flag, "imbloqueable no es parte de lo predicho")


func test_catalog_numbers_do_not_collide_with_the_fixed_dummy_npc() -> void:
	# El maniquí de entrenamiento no tiene definición: su npc_def_id es 0.
	assert_eq(NetEntity.new().npc_def_id, 0)
	for id: StringName in NpcCatalog.ids():
		assert_true(NpcCatalog.number_of(id) >= 1)
