extends TestCase
## Tests of [NpcCatalog] and of the NPC data (MUN-07, MUN-08; docs/fuerte.md 4.2): the ids 1..n in
## alphabetical order that the client uses, the definitions in [code]data/npcs/[/code], and that the NPC
## weapons in [code]data/combat/npc_*.tres[/code] have a readable anticipation (≥ 0.45 s for light ones,
## ≥ 0.70 s for heavy ones) and only the Captain's heavy blow is unblockable.

const LIGHT_MIN_WINDUP_S: float = 0.45
const HEAVY_MIN_WINDUP_S: float = 0.70


func before_each() -> void:
	NpcCatalog.reload()
	BossInfo.clear_cache()


func after_each() -> void:
	NpcCatalog.reload()
	BossInfo.clear_cache()


func test_the_data_directory_loads_without_errors() -> void:
	assert_eq(NpcCatalog.get_errors(), PackedStringArray(), "the data in data/npcs/ is valid")
	assert_eq(NpcCatalog.count(), 5, "Hollow, Ford Captain, guardian, realm captain and realm guard")


func test_ids_are_one_to_n_in_alphabetical_order_of_the_file_names() -> void:
	var files: PackedStringArray = DirAccess.get_files_at(NpcCatalog.DATA_DIR)
	var expected: PackedStringArray = NpcCatalog.ids_in_order(files)
	var ids: Array[StringName] = NpcCatalog.ids()
	assert_eq(ids.size(), expected.size(), "one definition per file")
	for index: int in expected.size():
		assert_eq(String(ids[index]), expected[index], "number %d is %s" % [index + 1, expected[index]])
		assert_eq(NpcCatalog.number_of(ids[index]), index + 1)
		var definition: NpcDefinition = NpcCatalog.get_by_number(index + 1)
		assert_not_null(definition)
		assert_eq(definition.id, ids[index], "the definition id is the file's")
		assert_true(NpcCatalog.get_definition(ids[index]) == definition, "get_definition() gives the same one")
	assert_null(NpcCatalog.get_by_number(0), "0 is \"no definition\"")
	assert_null(NpcCatalog.get_by_number(expected.size() + 1), "beyond the last one, nothing")
	assert_eq(NpcCatalog.number_of(&"no_existe"), 0)
	assert_null(NpcCatalog.get_definition(&"no_existe"))


func test_the_client_boss_info_resolves_the_same_numbers() -> void:
	for id: StringName in NpcCatalog.ids():
		var number: int = NpcCatalog.number_of(id)
		var info: Dictionary = BossInfo.lookup(number)
		assert_eq(info.get("name", ""), String(id), "BossInfo gives the same name for %d" % number)
		assert_eq(BossInfo.is_boss(number), NpcCatalog.get_definition(id).is_boss,
				"and the same is_boss for %s" % id)


func test_the_spawner_ids_of_the_zone_exist_in_the_catalog() -> void:
	for id: StringName in [&"hollow", &"ford_captain", &"gate_guardian", &"realm_guard", &"realm_captain"]:
		assert_not_null(NpcCatalog.get_definition(id), "%s exists" % id)


func test_every_definition_is_coherent() -> void:
	for id: StringName in NpcCatalog.ids():
		var definition: NpcDefinition = NpcCatalog.get_definition(id)
		assert_false(definition.display_name.is_empty(), "%s: has a name" % id)
		assert_true(definition.max_health > 0, "%s: has health" % id)
		assert_true(CombatCatalog.weapon_id(definition.weapon_id) > 0, "%s: its weapon exists" % id)
		assert_true(definition.leash_radius > definition.perception_radius * 0.5 or definition.ignores_safe_area,
				"%s: the leash allows chasing" % id)
		assert_true(definition.lose_radius >= definition.perception_radius * 0.5, "%s: consistent radii" % id)
		assert_true(definition.reaction_s.x <= definition.reaction_s.y, "%s: minimum reaction <= maximum" % id)
		assert_true(definition.attack_gap_s.x <= definition.attack_gap_s.y, "%s: minimum pauses <= maximum" % id)
		assert_true(definition.block_s.x <= definition.block_s.y, "%s: minimum block <= maximum" % id)
		if definition.garrison_id != &"":
			assert_not_null(NpcCatalog.get_definition(definition.garrison_id), "%s: the garrison exists" % id)
			assert_false(NpcCatalog.get_definition(definition.garrison_id).is_boss and not definition.is_boss,
					"%s: a common NPC is not replaced by a boss" % id)
		if definition.reinforcement_id != &"":
			assert_not_null(NpcCatalog.get_definition(definition.reinforcement_id), "%s: its reinforcements exist" % id)
			assert_true(definition.reinforcement_count > 0, "%s: calls someone" % id)


func test_the_key_roles_have_the_agreed_traits() -> void:
	var hollow: NpcDefinition = NpcCatalog.get_definition(&"hollow")
	assert_false(hollow.is_boss)
	assert_false(hollow.ignores_safe_area)
	assert_near(hollow.alert_radius, 25.0, 1e-9, "the Hollow are alerted at 25 m")
	assert_eq(hollow.garrison_id, &"realm_guard", "with an owner, the Hollow give way to the realm guards")
	var captain: NpcDefinition = NpcCatalog.get_definition(&"ford_captain")
	assert_true(captain.is_boss, "the Ford Captain is a boss")
	assert_true(captain.shouts, "shouts")
	assert_eq(captain.reinforcement_id, &"hollow", "the reinforcements are Hollow")
	assert_eq(captain.reinforcement_count, 2, "two")
	assert_near(captain.reinforcement_health_fraction, 0.5, 1e-9, "at 50 % depleted health")
	assert_true(captain.special_every > 0, "throws the unblockable blow every few attacks")
	assert_eq(captain.garrison_id, &"realm_captain")
	var guardian: NpcDefinition = NpcCatalog.get_definition(&"gate_guardian")
	assert_true(guardian.ignores_safe_area, "the Gate Guardian ignores the safe zone")
	assert_false(guardian.is_boss)
	assert_true(NpcCatalog.get_definition(&"realm_captain").is_boss, "the realm captain is a boss")
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
			assert_true(light.windup_ticks >= light_min, "%s: the light attack %s telegraphs %d ticks (minimum %d)"
					% [weapon_name, light.name, light.windup_ticks, light_min])
			assert_false(light.heavy)
			assert_eq(light.stamina_cost, 0, "%s: the light attack costs no stamina" % weapon_name)
			assert_eq(light.combo_window_ticks, 0, "%s: no chaining: each attack is a decision" % weapon_name)
		var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
		assert_true(heavy.heavy)
		assert_true(heavy.windup_ticks >= heavy_min, "%s: the heavy attack %s telegraphs %d ticks (minimum %d)"
				% [weapon_name, heavy.name, heavy.windup_ticks, heavy_min])
		assert_true(heavy.charge_min_ticks >= 1 and heavy.charge_max_ticks >= heavy.charge_min_ticks,
				"%s: valid charge" % weapon_name)
		checked += 1
	assert_eq(checked, 4, "the four NPC weapons")


func test_only_the_captains_heavy_strike_is_unblockable() -> void:
	var unblockable: Array[StringName] = []
	for attack_name: StringName in CombatCatalog.tables().attack_ids:
		if CombatCatalog.attack(CombatCatalog.attack_id(attack_name)).unblockable:
			unblockable.append(attack_name)
	assert_eq(unblockable, [&"npc_captain_crush"] as Array[StringName])
	var crush: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"npc_captain_crush"))
	assert_true(crush.heavy and crush.hyper_armor, "it is a heavy attack with poise")
	assert_true(crush.windup_ticks >= CombatCatalog.seconds_to_ticks(1.0), "telegraphs a full second")


func test_the_unblockable_flag_is_server_only_and_does_not_change_the_prediction_hash() -> void:
	var with_flag: int = CombatCatalog.prediction_hash()
	var crush: AttackDefinition = load("res://data/combat/npc_captain_crush.tres") as AttackDefinition
	assert_true(crush.unblockable)
	crush.unblockable = false
	CombatCatalog.reload()
	var without_flag: int = CombatCatalog.prediction_hash()
	crush.unblockable = true
	CombatCatalog.reload()
	assert_eq(without_flag, with_flag, "unblockable is not part of what is predicted")


func test_catalog_numbers_do_not_collide_with_the_fixed_dummy_npc() -> void:
	# The training dummy has no definition: its npc_def_id is 0.
	assert_eq(NetEntity.new().npc_def_id, 0)
	for id: StringName in NpcCatalog.ids():
		assert_true(NpcCatalog.number_of(id) >= 1)
