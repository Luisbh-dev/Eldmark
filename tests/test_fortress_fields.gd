extends TestCase
## Tests for [FortressFields] (docs/fortress.md, section 2): the OBJECT_STATE field ids, their
## value type and their reading and writing on a [FortressState].

const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"


func test_ids_and_names_follow_the_contract() -> void:
	var expected: Array[StringName] = [&"owner", &"phase", &"phase_tick", &"captain_alive", &"guards_alive",
			&"gate_health", &"gate_max", &"capture_realm", &"capture_start_tick", &"capture_rate",
			&"capture_progress_at_start", &"contested", &"under_attack_until_tick", &"presence_0",
			&"presence_1", &"presence_2", &"presence_3"]
	var ids: PackedInt32Array = FortressFields.all_ids()
	assert_eq(ids.size(), 17, "17 fields")
	for i: int in ids.size():
		assert_eq(ids[i], i + 1, "consecutive ids from 1")
		assert_eq(FortressFields.name_of(ids[i]), expected[i], "name of field %d" % ids[i])
		assert_true(FortressFields.is_known(ids[i]))
	assert_eq(FortressFields.OWNER, 1)
	assert_eq(FortressFields.UNDER_ATTACK_UNTIL_TICK, 13)
	assert_eq(FortressFields.PRESENCE_BASE, 14)
	assert_false(FortressFields.is_known(0))
	assert_false(FortressFields.is_known(18))
	assert_eq(FortressFields.name_of(99), &"")
	assert_eq(FortressFields.value_type(99), 0)


func test_value_types_match_the_message_format() -> void:
	assert_eq(FortressFields.ValueType.U8, 1)
	assert_eq(FortressFields.ValueType.U16, 2)
	assert_eq(FortressFields.ValueType.U32, 3)
	assert_eq(FortressFields.ValueType.S32, 4)
	for field_id: int in [FortressFields.OWNER, FortressFields.PHASE, FortressFields.CAPTAIN_ALIVE,
			FortressFields.GUARDS_ALIVE, FortressFields.CAPTURE_REALM, FortressFields.CONTESTED]:
		assert_eq(FortressFields.value_type(field_id), FortressFields.ValueType.U8, "field %d: u8" % field_id)
	for field_id: int in [FortressFields.PHASE_TICK, FortressFields.GATE_HEALTH, FortressFields.GATE_MAX,
			FortressFields.CAPTURE_START_TICK, FortressFields.CAPTURE_PROGRESS_AT_START,
			FortressFields.UNDER_ATTACK_UNTIL_TICK]:
		assert_eq(FortressFields.value_type(field_id), FortressFields.ValueType.U32, "field %d: u32" % field_id)
	assert_eq(FortressFields.value_type(FortressFields.CAPTURE_RATE), FortressFields.ValueType.S32, "the speed can be negative")
	for realm: int in 4:
		assert_eq(FortressFields.value_type(FortressFields.presence_field(realm)), FortressFields.ValueType.U8)
	assert_eq(FortressFields.value_size(FortressFields.ValueType.U8), 1)
	assert_eq(FortressFields.value_size(FortressFields.ValueType.U16), 2)
	assert_eq(FortressFields.value_size(FortressFields.ValueType.U32), 4)
	assert_eq(FortressFields.value_size(FortressFields.ValueType.S32), 4)
	assert_eq(FortressFields.value_size(0), 0)
	assert_eq(FortressFields.value_size(9), 0)


func test_presence_fields_by_realm() -> void:
	assert_eq(FortressFields.presence_field(0), 14)
	assert_eq(FortressFields.presence_field(1), 15)
	assert_eq(FortressFields.presence_field(3), 17)
	assert_eq(FortressFields.presence_field(4), -1)
	assert_eq(FortressFields.presence_field(-1), -1)


func test_fits_checks_the_range_of_each_type() -> void:
	assert_true(FortressFields.fits(FortressFields.OWNER, 0))
	assert_true(FortressFields.fits(FortressFields.OWNER, 255))
	assert_false(FortressFields.fits(FortressFields.OWNER, 256))
	assert_false(FortressFields.fits(FortressFields.OWNER, -1))
	assert_true(FortressFields.fits(FortressFields.GATE_HEALTH, 0xFFFFFFFF))
	assert_false(FortressFields.fits(FortressFields.GATE_HEALTH, 0x100000000))
	assert_false(FortressFields.fits(FortressFields.GATE_HEALTH, -1))
	assert_true(FortressFields.fits(FortressFields.CAPTURE_RATE, -24))
	assert_true(FortressFields.fits(FortressFields.CAPTURE_RATE, -0x80000000))
	assert_false(FortressFields.fits(FortressFields.CAPTURE_RATE, 0x80000000))
	assert_false(FortressFields.fits(99, 0), "an unknown field does not fit anything")


func test_get_and_set_round_trip_every_field() -> void:
	var def: FortressDefinition = load(DEFINITION_PATH) as FortressDefinition
	var source: FortressState = FortressState.initial(def, 500)
	source.owner = 2
	source.phase = FortressState.Phase.CAPTURING
	source.phase_tick = 700
	source.captain_alive = false
	source.guards_alive = 3
	source.gate_health = 4321
	source.capture_realm = 1
	source.capture_start_tick = 650
	source.capture_rate = -24
	source.capture_progress_at_start = 12345
	source.contested = true
	source.under_attack_until_tick = 9000
	source.presence = PackedInt32Array([0, 4, 2, 1])
	var target: FortressState = FortressState.initial(def, 0)
	for field_id: int in FortressFields.all_ids():
		assert_true(FortressFields.set_value(target, field_id, FortressFields.get_value(source, field_id)), "field %d" % field_id)
	assert_true(target.changed_fields_since(source).is_empty(), "the state copied field by field is identical")
	assert_eq(FortressFields.get_value(source, FortressFields.CAPTAIN_ALIVE), 0, "booleans travel as 0 or 1")
	assert_eq(FortressFields.get_value(source, FortressFields.CONTESTED), 1)
	assert_eq(FortressFields.get_value(source, FortressFields.CAPTURE_RATE), -24)
	assert_eq(FortressFields.get_value(source, FortressFields.PRESENCE_BASE + 1), 4)
	assert_eq(FortressFields.get_value(source, 99), 0, "an unknown field gives 0")


func test_set_value_rejects_unknown_fields_and_values_that_do_not_fit() -> void:
	var def: FortressDefinition = load(DEFINITION_PATH) as FortressDefinition
	var state: FortressState = FortressState.initial(def, 0)
	assert_false(FortressFields.set_value(state, 99, 1), "unknown id")
	assert_false(FortressFields.set_value(state, FortressFields.OWNER, 300), "does not fit in u8")
	assert_false(FortressFields.set_value(state, FortressFields.GATE_HEALTH, -5), "u32 is not negative")
	assert_eq(state.owner, 0, "nothing changed")
	assert_eq(state.gate_health, 9000)
	assert_true(FortressFields.set_value(state, FortressFields.CAPTURE_RATE, -4))
	assert_eq(state.capture_rate, -4)
