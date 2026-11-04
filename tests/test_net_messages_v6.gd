extends TestCase
## Tests of protocol 6 (docs/abilities.md, section 5; package H2): the new buttons of
## [constant NetProtocol.VALID_BUTTONS], LOADOUT_SELECT, debug commands 13 to 16, the projectile
## ENTITY_SPAWN (32 B, without [code]is_yours[/code]) and the ENTITY_DESPAWN reasons 4 and 5,
## ENTITY_EVENTs 7 to 11 (STATUS, HEAL, LOADOUT, DOWNED, INTERACT), bits 5 and 6 of a HIT, the sources
## ([CombatSource]) in the 16-bit fields, bit 3 of the record flags (slot 2) and bit 3 of
## [code]status[/code] (knocked down) in the SNAPSHOT and the PARTY_STATUS.
## [br][br]
## As in test_net_messages.gd and test_net_messages_v3.gd, the offsets and sizes are the ones from the
## document, written by hand on purpose. The malformed messages and the fuzz also check that nothing
## logs engine errors (the runner counts them as a failure).

const FUZZ_BUFFERS: int = 8000
const FUZZ_SEED: int = 20261029 + 6


# --- Constants and channels -------------------------------------------------------------------

func test_protocol_6_constants_and_channels() -> void:
	assert_true(NetProtocol.PROTOCOL_VERSION >= 6, "abilities raise the protocol to version 6")
	assert_eq(NetProtocol.MSG_LOADOUT_SELECT, 0x07, "LOADOUT_SELECT is 0x07")
	assert_eq(NetProtocol.channel_for_type(NetProtocol.MSG_LOADOUT_SELECT), NetProtocol.CH_RELIABLE,
			"LOADOUT_SELECT goes over the reliable channel (3)")
	assert_eq(NetProtocol.DespawnReason.IMPACT, 4, "DESPAWN 4: impact")
	assert_eq(NetProtocol.DespawnReason.EXPIRED, 5, "DESPAWN 5: expired")
	assert_eq(NetProtocol.EntityKind.PROJECTILE, 3, "kind 3: projectile")
	# New events and bits, with their numbers from the document.
	assert_eq(NetMessages.EntityEvent.Kind.STATUS, 7, "STATUS")
	assert_eq(NetMessages.EntityEvent.Kind.HEAL, 8, "HEAL")
	assert_eq(NetMessages.EntityEvent.Kind.LOADOUT, 9, "LOADOUT")
	assert_eq(NetMessages.EntityEvent.Kind.DOWNED, 10, "DOWNED")
	assert_eq(NetMessages.EntityEvent.Kind.INTERACT, 11, "INTERACT")
	assert_eq(NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED, 1 << 5, "HIT: bit 5 interrupted")
	assert_eq(NetMessages.EntityEvent.HIT_FLAG_DOWNED, 1 << 6, "HIT: bit 6 knocks down")
	assert_eq(NetMessages.STATUS_DOWNED, 1 << 3, "status: bit 3 knocked down")
	assert_eq(EntityRecord.FLAG_SECOND_SLOT, 1 << 3, "record flags: bit 3 slot 2")
	assert_eq(EntityRecord.HISTORY_FLAGS_MASK, 0b111, "the history only takes bits 0-2 of the record")
	assert_eq(EntityRecord.FLAG_SECOND_SLOT & EntityRecord.HISTORY_FLAGS_MASK, 0,
			"the slot 2 bit does not go into the history (there bit 3 is the block)")
	assert_eq(EntityRecord.FLAG_SECOND_SLOT, ActionMachine.DEFENSE_BLOCKING,
			"that is why it has to be masked: it is the same bit as DEFENSE_BLOCKING")
	assert_eq(NetMessages.EntitySpawn.PROJECTILE_SIZE, 32, "projectile SPAWN: 32 B")


func test_valid_buttons_carry_the_new_buttons() -> void:
	assert_eq(NetProtocol.VALID_BUTTONS, (1 << 13) - 1, "bits 0-12")
	for button: int in [PlayerInput.SWAP_WEAPON, PlayerInput.AIM_LEFT, PlayerInput.CONSUMABLE_1,
			PlayerInput.CONSUMABLE_2, PlayerInput.INTERACT, PlayerInput.ABILITY_3]:
		assert_eq(button & NetProtocol.VALID_BUTTONS, button, "button 0x%04X is valid" % button)
	for reserved: int in [1 << 13, 1 << 14, PlayerInput.SUBSTITUTED]:
		assert_eq(reserved & NetProtocol.VALID_BUTTONS, 0, "bit 0x%04X is not a button" % reserved)
	# A batch with the new buttons arrives whole; bits 13-15 are left out.
	var batch := NetMessages.InputBatch.new()
	batch.newest_tick = 300
	var input := PlayerInput.new()
	input.tick = 300
	input.buttons = PlayerInput.SWAP_WEAPON | PlayerInput.AIM_LEFT | PlayerInput.CONSUMABLE_1 \
			| PlayerInput.CONSUMABLE_2 | PlayerInput.PRIMARY | (1 << 13) | (1 << 14) | PlayerInput.SUBSTITUTED
	batch.inputs.append(input)
	batch.view_offsets_q.append(0)
	var decoded: NetMessages.InputBatch = NetMessages.InputBatch.decode(batch.encode())
	if assert_not_null(decoded, "decode of the batch"):
		assert_eq(decoded.inputs[0].buttons, PlayerInput.SWAP_WEAPON | PlayerInput.AIM_LEFT
				| PlayerInput.CONSUMABLE_1 | PlayerInput.CONSUMABLE_2 | PlayerInput.PRIMARY,
				"Q, left shoulder, R, T and PRIMARY arrive; the reserved ones and the substituted mark do not")


# --- LOADOUT_SELECT and debug commands --------------------------------------------------------

func test_loadout_select_layout_and_roundtrip() -> void:
	var marksman: int = CombatCatalog.template_id(&"marksman")
	assert_true(marksman > 0, "the shooter exists (id requested by name)")
	var select: NetMessages.LoadoutSelect = NetMessages.LoadoutSelect.make(marksman)
	var bytes: PackedByteArray = select.encode()
	assert_eq(bytes, PackedByteArray([0x07, marksman]), "LOADOUT_SELECT: u8 type 0x07 and u8 template_id")
	assert_eq(bytes.size(), 2, "2 B")
	var back: NetMessages.LoadoutSelect = NetMessages.LoadoutSelect.decode(bytes)
	if assert_not_null(back, "decode"):
		assert_eq(back.template_id, marksman, "template_id")
	# 0 is the default one and any u8 travels: whether it exists and can be chosen is up to the server.
	for id: int in [0, 1, 255]:
		var other: NetMessages.LoadoutSelect = NetMessages.LoadoutSelect.decode(
				NetMessages.LoadoutSelect.make(id).encode())
		if assert_not_null(other, "template_id %d" % id):
			assert_eq(other.template_id, id, "template_id %d" % id)
	assert_eq(NetMessages.LoadoutSelect.make(300).encode()[1], 300 & 0xFF, "modulo 256")
	assert_null(NetMessages.LoadoutSelect.decode(PackedByteArray([0x07])), "without id")
	assert_null(NetMessages.LoadoutSelect.decode(PackedByteArray([0x07, 1, 0])), "with one extra byte")
	assert_null(NetMessages.LoadoutSelect.decode(PackedByteArray([0x06, 1])), "another type")


func test_debug_commands_13_to_16_validate_their_data() -> void:
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"cooldowns_off"], 13, "13 cooldowns_off")
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"apply_status"], 14, "14 apply_status")
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"down"], 15, "15 down")
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"refill"], 16, "16 refill")
	# 13 cooldowns_off: 0 or 1.
	assert_eq(NetMessages.DebugCommand.cooldowns_off(true).encode(), PackedByteArray([0x04, 13, 1]), "enable")
	assert_eq(NetMessages.DebugCommand.cooldowns_off(false).encode(), PackedByteArray([0x04, 13, 0]), "disable")
	for value: int in [0, 1]:
		assert_not_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 13, value])), "%d is valid" % value)
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 13, 2])), "2 no")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 13])), "without data")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 13, 1, 0])), "with 2 B")
	# 14 apply_status: u8 status_id (1 to 255) and u16 ticks (0 = those of the data).
	var bleed: int = CombatCatalog.status_id(&"bleed")
	assert_true(bleed > 0, "bleeding exists (id requested by name)")
	var apply: NetMessages.DebugCommand = NetMessages.DebugCommand.apply_status(bleed, 600)
	var apply_bytes: PackedByteArray = apply.encode()
	assert_eq(apply_bytes.size(), 5, "apply_status: 5 B")
	assert_eq(apply_bytes.decode_u8(1), 14, "u8 command")
	assert_eq(apply_bytes.decode_u8(2), bleed, "u8 status_id at 2")
	assert_eq(apply_bytes.decode_u16(3), 600, "u16 ticks at 3")
	var apply_back: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(apply_bytes)
	if assert_not_null(apply_back, "decode of apply_status"):
		assert_eq(apply_back.get_status_id(), bleed, "get_status_id")
		assert_eq(apply_back.get_status_ticks(), 600, "get_status_ticks")
	var by_data: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(
			NetMessages.DebugCommand.apply_status(bleed).encode())
	if assert_not_null(by_data, "apply_status with the duration from the data"):
		assert_eq(by_data.get_status_ticks(), 0, "0 = the ticks from the data")
	assert_eq(NetMessages.DebugCommand.apply_status(bleed, 100000).encode().decode_u16(3), 0xFFFF,
			"the ticks saturate to u16")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 14, 0, 10, 0])), "status_id 0")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 14, 1, 10])), "without the second tick byte")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 14, 1, 10, 0, 0])), "with one extra byte")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 14])), "without data")
	assert_eq(NetMessages.DebugCommand.new().get_status_id(), 0, "get_status_id without data: 0")
	# 15 down and 16 refill: without data.
	for command_id: int in [NetProtocol.DEBUG_DOWN, NetProtocol.DEBUG_REFILL]:
		var simple: NetMessages.DebugCommand = NetMessages.DebugCommand.simple(command_id)
		assert_eq(simple.encode(), PackedByteArray([0x04, command_id]), "command %d without data" % command_id)
		assert_not_null(NetMessages.DebugCommand.decode(simple.encode()), "command %d" % command_id)
		assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, command_id, 0])),
				"command %d does not accept data" % command_id)


# --- Projectiles --------------------------------------------------------------------------------

func test_projectile_spawn_layout_and_roundtrip() -> void:
	var arrow: int = CombatCatalog.projectile_id(&"arrow")
	var volley: int = CombatSource.make(CombatSource.Kind.ABILITY, CombatCatalog.ability_id(&"bow_volley"))
	var p0 := Vector3(-123.456, 7.891, 4321.004)
	var v0 := Vector3(30.123, 4.567, -32.009)
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.for_projectile(0xBEEF, 765432,
			NetProtocol.Realm.SOLMARCH, 4242, arrow, volley, 2, true, p0, v0)
	# Even if someone marks it as "yours", a projectile never is in the message.
	spawn.is_yours = true
	var bytes: PackedByteArray = spawn.encode()
	assert_eq(bytes.size(), 32, "projectile ENTITY_SPAWN: 10 B of header and 22 B")
	assert_eq(bytes.decode_u8(0), 0x20, "u8 type at 0")
	assert_eq(bytes.decode_u16(1), 0xBEEF, "u16 net_id (the projectile) at 1")
	assert_eq(bytes.decode_u8(3), 3, "u8 kind at 3: PROJECTILE")
	assert_eq(bytes.decode_u32(4), 765432, "u32 spawn_tick (the one of the shot) at 4")
	assert_eq(bytes.decode_u8(8), NetProtocol.Realm.SOLMARCH, "u8 realm (the shooter's) at 8")
	assert_eq(bytes.decode_u8(9), 0, "u8 flags at 9: 0 (is_yours always 0; a projectile does not teleport)")
	assert_eq(bytes.decode_u16(10), 4242, "u16 owner at 10")
	assert_eq(bytes.decode_u16(12), arrow, "u16 projectile_def_id at 12")
	assert_eq(bytes.decode_u16(14), volley, "u16 source at 14")
	assert_eq(bytes.decode_u8(16), 2, "u8 volley_index at 16")
	assert_eq(bytes.decode_u8(17), 1, "u8 proj_flags at 17: harmless")
	assert_eq(bytes.decode_u64(18), NetMath.pack_position(p0), "u64 position at 18, like the record")
	assert_eq(bytes.decode_s16(26), 3012, "s16 velocity.x at 26 (cm/s)")
	assert_eq(bytes.decode_s16(28), 457, "s16 velocity.y at 28")
	assert_eq(bytes.decode_s16(30), -3201, "s16 velocity.z at 30")

	var back: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if not assert_not_null(back, "decode of the projectile SPAWN"):
		return
	assert_eq(back.kind, NetProtocol.EntityKind.PROJECTILE, "kind")
	assert_eq(back.net_id, 0xBEEF, "net_id")
	assert_eq(back.spawn_tick, 765432, "spawn_tick")
	assert_eq(back.realm, NetProtocol.Realm.SOLMARCH, "realm")
	assert_false(back.is_yours, "it is never yours")
	assert_eq(back.owner_id, 4242, "owner_id")
	assert_eq(back.projectile_def_id, arrow, "projectile_def_id")
	assert_eq(back.source, volley, "source")
	assert_eq(CombatSource.kind_of(back.source), CombatSource.Kind.ABILITY, "the source is an ability")
	assert_eq(back.volley_index, 2, "volley_index")
	assert_true(back.is_harmless(), "harmless")
	assert_null(back.state, "without PlayerState")
	# The ballistics that travel are exactly those of Ballistics.quantize: the server flies with them.
	var quantized: Array = Ballistics.quantize(p0, v0)
	assert_eq(back.origin, quantized[0] as Vector3, "origin = Ballistics.quantize (1 cm)")
	assert_eq(back.velocity, quantized[1] as Vector3, "velocity = Ballistics.quantize (1 cm/s)")
	assert_eq(back.encode(), bytes, "re-encoding gives the same bytes")
	var requantized: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(
			NetMessages.EntitySpawn.for_projectile(1, 2, 1, 3, arrow, 4, 0, false, back.origin,
			back.velocity).encode())
	if assert_not_null(requantized, "what is already quantized"):
		assert_eq(requantized.origin, back.origin, "does not move when quantized again")
		assert_eq(requantized.velocity, back.velocity, "nor does the velocity")
		assert_false(requantized.is_harmless(), "without the harmless bit")
		assert_eq(requantized.projectile_flags, 0, "proj_flags 0")

	# The extremes saturate: position at ±5.24 km and velocity at ±327.67 m/s.
	var extreme: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(
			NetMessages.EntitySpawn.for_projectile(0xFFFF, 0xFFFFFFFF, 3, 0xFFFF, 0xFFFF, 0xFFFF, 255, false,
			Vector3(1e6, -1e6, 0.0), Vector3(500.0, -500.0, NAN)).encode())
	if assert_not_null(extreme, "extremes"):
		assert_eq(extreme.spawn_tick, 0xFFFFFFFF, "maximum tick")
		assert_eq(extreme.volley_index, 255, "maximum volley_index")
		assert_near(extreme.origin.x, 5242.87, 0.01, "position saturated at the top")
		assert_near(extreme.origin.y, -5242.88, 0.01, "and at the bottom")
		assert_near(extreme.velocity.x, 327.67, 1e-4, "saturated velocity")
		assert_near(extreme.velocity.y, -327.68, 1e-4, "and at the bottom")
		assert_eq(extreme.velocity.z, 0.0, "a NaN travels as 0")


func test_projectile_spawn_rejects_malformed_bytes() -> void:
	var bytes: PackedByteArray = _projectile_spawn().encode()
	assert_not_null(NetMessages.EntitySpawn.decode(bytes), "the starting one is valid")
	var yours: PackedByteArray = bytes.duplicate()
	yours.encode_u8(9, 1)
	assert_null(NetMessages.EntitySpawn.decode(yours), "with the is_yours bit: a projectile is never yours")
	for header_flags: int in [2, 4, 6, 8, 0x80]:
		var flagged: PackedByteArray = bytes.duplicate()
		flagged.encode_u8(9, header_flags)
		assert_null(NetMessages.EntitySpawn.decode(flagged), "with the header flags at 0x%02X" % header_flags)
	for unknown_flag: int in [2, 4, 0x80]:
		var bad_flags: PackedByteArray = bytes.duplicate()
		bad_flags.encode_u8(17, unknown_flag)
		assert_null(NetMessages.EntitySpawn.decode(bad_flags), "proj_flags with bit 0x%02X" % unknown_flag)
	for length: int in [10, 11, 31, 33, 10 + PlayerState.ENCODED_SIZE + 1]:
		var resized: PackedByteArray = bytes.duplicate()
		resized.resize(length)
		assert_null(NetMessages.EntitySpawn.decode(resized), "a projectile of %d B" % length)
	# A player SPAWN with the kind changed to projectile is not read as a projectile, nor the other way around.
	var player := NetMessages.EntitySpawn.new()
	player.net_id = 9
	player.state = PlayerState.new()
	player.display_name = "Ana"
	var as_projectile: PackedByteArray = player.encode()
	as_projectile.encode_u8(3, NetProtocol.EntityKind.PROJECTILE)
	assert_null(NetMessages.EntitySpawn.decode(as_projectile), "a player relabeled as a projectile")
	var as_player: PackedByteArray = bytes.duplicate()
	as_player.encode_u8(3, NetProtocol.EntityKind.PLAYER)
	assert_null(NetMessages.EntitySpawn.decode(as_player), "a projectile relabeled as a player")
	as_player.encode_u8(3, NetProtocol.EntityKind.NPC)
	assert_null(NetMessages.EntitySpawn.decode(as_player), "nor as an NPC")
	as_player.encode_u8(3, NetProtocol.EntityKind.STRUCTURE)
	assert_null(NetMessages.EntitySpawn.decode(as_player), "nor as a structure")


func test_projectile_despawn_reasons() -> void:
	for reason: int in [NetProtocol.DespawnReason.IMPACT, NetProtocol.DespawnReason.EXPIRED]:
		var despawn := NetMessages.EntityDespawn.new()
		despawn.net_id = 0xBEEF
		despawn.despawn_tick = 765440
		despawn.reason = reason
		var bytes: PackedByteArray = despawn.encode()
		assert_eq(bytes.size(), 8, "ENTITY_DESPAWN: 8 B, unchanged")
		assert_eq(bytes.decode_u8(7), reason, "u8 reason at 7")
		var back: NetMessages.EntityDespawn = NetMessages.EntityDespawn.decode(bytes)
		if assert_not_null(back, "decode of the DESPAWN %d" % reason):
			assert_eq(back.reason, reason, "reason %d" % reason)
			assert_eq(back.despawn_tick, 765440, "despawn_tick: the impact tick")


# --- ENTITY_EVENT 7 to 11 -----------------------------------------------------------------------

func test_status_event_layout_and_roundtrip() -> void:
	var slowed: int = CombatCatalog.status_id(&"slowed")
	var event: NetMessages.EntityEvent = NetMessages.EntityEvent.status(321, 123456, 654,
			NetMessages.EntityEvent.StatusOp.APPLIED, slowed, 2, 0xFFFFFFF0)
	var bytes: PackedByteArray = event.encode()
	assert_eq(bytes.size(), 18, "STATUS: 18 B")
	assert_eq(bytes.decode_u8(0), 0x23, "u8 type at 0")
	assert_eq(bytes.decode_u16(1), 321, "u16 net_id (the affected one) at 1")
	assert_eq(bytes.decode_u32(3), 123456, "u32 tick at 3")
	assert_eq(bytes.decode_u8(7), 7, "u8 event at 7: STATUS")
	assert_eq(bytes.decode_u8(8), 9, "u8 len at 8")
	assert_eq(bytes.decode_u16(9), 654, "u16 source_entity at 9")
	assert_eq(bytes.decode_u8(11), 1, "u8 op at 11: applied")
	assert_eq(bytes.decode_u8(12), slowed, "u8 status_id at 12")
	assert_eq(bytes.decode_u8(13), 2, "u8 stacks at 13")
	assert_eq(bytes.decode_u32(14), 0xFFFFFFF0, "u32 until_tick at 14")
	var back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
	if not assert_not_null(back, "decode of the STATUS"):
		return
	assert_eq(back.event, NetMessages.EntityEvent.Kind.STATUS, "event")
	assert_eq(back.net_id, 321, "net_id")
	assert_eq(back.source_entity, 654, "source_entity")
	assert_eq(back.op, NetMessages.EntityEvent.StatusOp.APPLIED, "op")
	assert_eq(back.status_id, slowed, "status_id")
	assert_eq(back.stacks, 2, "stacks")
	assert_eq(back.until_tick, 0xFFFFFFF0, "until_tick")
	assert_eq(back.get_source(), CombatSource.NONE, "a STATUS carries no source")
	assert_eq(back.encode(), bytes, "re-encoding gives the same bytes")
	# Removed: 0 stacks is valid; without an author, 0.
	var removed: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(NetMessages.EntityEvent.status(5, 6, 0,
			NetMessages.EntityEvent.StatusOp.REMOVED, slowed, 0, 100).encode())
	if assert_not_null(removed, "removed STATUS"):
		assert_eq(removed.op, NetMessages.EntityEvent.StatusOp.REMOVED, "op 2")
		assert_eq(removed.source_entity, 0, "without an author")
	# Stacks saturate to u8.
	var many: NetMessages.EntityEvent = NetMessages.EntityEvent.status(5, 6, 7,
			NetMessages.EntityEvent.StatusOp.APPLIED, slowed, 999, 100)
	assert_eq(many.encode().decode_u8(13), 255, "stacks saturated to 255")
	# op out of range and applied STATUS without stacks: null.
	for bad_op: int in [0, 3, 255]:
		var tampered: PackedByteArray = bytes.duplicate()
		tampered.encode_u8(11, bad_op)
		assert_null(NetMessages.EntityEvent.decode(tampered), "STATUS with op %d" % bad_op)
	var no_stacks: PackedByteArray = bytes.duplicate()
	no_stacks.encode_u8(13, 0)
	assert_null(NetMessages.EntityEvent.decode(no_stacks), "applied STATUS with 0 stacks")


func test_heal_loadout_and_downed_layouts() -> void:
	var regen: int = CombatSource.make(CombatSource.Kind.STATUS, CombatCatalog.status_id(&"potion_regen"))
	var heal: NetMessages.EntityEvent = NetMessages.EntityEvent.heal(40, 1000, 0, 50, regen)
	var heal_bytes: PackedByteArray = heal.encode()
	assert_eq(heal_bytes.size(), 15, "HEAL: 15 B")
	assert_eq(heal_bytes.decode_u8(7), 8, "u8 event: HEAL")
	assert_eq(heal_bytes.decode_u8(8), 6, "u8 len")
	assert_eq(heal_bytes.decode_u16(9), 0, "u16 healer at 9: 0 = self")
	assert_eq(heal_bytes.decode_u16(11), 50, "u16 amount at 11")
	assert_eq(heal_bytes.decode_u16(13), regen, "u16 source at 13")
	var heal_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(heal_bytes)
	if assert_not_null(heal_back, "decode of the HEAL"):
		assert_eq(heal_back.event, NetMessages.EntityEvent.Kind.HEAL, "event")
		assert_eq(heal_back.net_id, 40, "the healed one")
		assert_eq(heal_back.healer, 0, "healer")
		assert_eq(heal_back.amount, 50, "amount")
		assert_eq(heal_back.get_source(), regen, "the source is the effect")
		assert_eq(CombatSource.kind_of(heal_back.get_source()), CombatSource.Kind.STATUS, "STATUS class")
		assert_eq(heal_back.encode(), heal_bytes, "re-encoding gives the same bytes")
	assert_eq(NetMessages.EntityEvent.heal(1, 2, 3, 70000, 4).encode().decode_u16(11), 0xFFFF,
			"the healed health saturates to u16")
	assert_eq(NetMessages.EntityEvent.heal(1, 2, 3, -5, 4).encode().decode_u16(11), 0, "and does not go below 0")

	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow: int = CombatCatalog.weapon_id(&"bow")
	var marksman: int = CombatCatalog.template_id(&"marksman")
	var charges: int = CombatState.pack_charges(2, 3)
	var loadout: NetMessages.EntityEvent = NetMessages.EntityEvent.loadout(41, 1001, marksman, bow, sword,
			charges)
	var loadout_bytes: PackedByteArray = loadout.encode()
	assert_eq(loadout_bytes.size(), 15, "LOADOUT: 15 B")
	assert_eq(loadout_bytes.decode_u8(7), 9, "u8 event: LOADOUT")
	assert_eq(loadout_bytes.decode_u8(8), 6, "u8 len")
	assert_eq(loadout_bytes.decode_u8(9), marksman, "u8 template_id at 9")
	assert_eq(loadout_bytes.decode_u16(10), bow, "u16 weapon_1 at 10")
	assert_eq(loadout_bytes.decode_u16(12), sword, "u16 weapon_2 at 12")
	assert_eq(loadout_bytes.decode_u8(14), charges, "u8 charges at 14")
	var loadout_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(loadout_bytes)
	if assert_not_null(loadout_back, "decode of the LOADOUT"):
		assert_eq(loadout_back.template_id, marksman, "template_id")
		assert_eq(loadout_back.weapon_1, bow, "weapon_1")
		assert_eq(loadout_back.weapon_2, sword, "weapon_2")
		assert_eq(loadout_back.charges & 0x0F, 2, "charges of potion 1 (bits 0-3)")
		assert_eq(loadout_back.charges >> 4, 3, "charges of potion 2 (bits 4-7)")
		assert_eq(loadout_back.encode(), loadout_bytes, "re-encoding gives the same bytes")
	var others: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(
			NetMessages.EntityEvent.loadout(41, 1001, marksman, bow, 0, 0).encode())
	if assert_not_null(others, "someone else's LOADOUT, without a second weapon"):
		assert_eq(others.weapon_2, 0, "0 = none")
		assert_eq(others.charges, 0, "for whoever is not the owner, charges 0")

	var bash: int = CombatSource.make(CombatSource.Kind.ABILITY, CombatCatalog.ability_id(&"shield_bash"))
	var downed: NetMessages.EntityEvent = NetMessages.EntityEvent.downed(42, 1002, 77, bash)
	var downed_bytes: PackedByteArray = downed.encode()
	assert_eq(downed_bytes.size(), 13, "DOWNED: 13 B")
	assert_eq(downed_bytes.decode_u8(7), 10, "u8 event: DOWNED")
	assert_eq(downed_bytes.decode_u8(8), 4, "u8 len")
	assert_eq(downed_bytes.decode_u16(9), 77, "u16 attacker at 9")
	assert_eq(downed_bytes.decode_u16(11), bash, "u16 source at 11")
	var downed_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(downed_bytes)
	if assert_not_null(downed_back, "decode of the DOWNED"):
		assert_eq(downed_back.net_id, 42, "the knocked-down one")
		assert_eq(downed_back.attacker, 77, "attacker")
		assert_eq(downed_back.get_source(), bash, "the source is the ability")
		assert_eq(downed_back.encode(), downed_bytes, "re-encoding gives the same bytes")


func test_interact_event_layout_and_ops() -> void:
	var interact: NetMessages.EntityEvent = NetMessages.EntityEvent.interact(42, 2000, 55,
			NetMessages.EntityEvent.InteractOp.REVIVE, 2180)
	var bytes: PackedByteArray = interact.encode()
	assert_eq(bytes.size(), 16, "INTERACT: 16 B")
	assert_eq(bytes.decode_u16(1), 42, "u16 net_id: the knocked-down one")
	assert_eq(bytes.decode_u8(7), 11, "u8 event: INTERACT")
	assert_eq(bytes.decode_u8(8), 7, "u8 len")
	assert_eq(bytes.decode_u16(9), 55, "u16 actor at 9")
	assert_eq(bytes.decode_u8(11), 1, "u8 op at 11: raise")
	assert_eq(bytes.decode_u32(12), 2180, "u32 end_tick at 12")
	assert_eq(NetMessages.EntityEvent.InteractOp.REVIVE, 1, "1 raise")
	assert_eq(NetMessages.EntityEvent.InteractOp.REVIVE_CUT, 2, "2 raise interrupted")
	assert_eq(NetMessages.EntityEvent.InteractOp.REVIVED, 3, "3 raised")
	assert_eq(NetMessages.EntityEvent.InteractOp.EXECUTE, 4, "4 finish off")
	assert_eq(NetMessages.EntityEvent.InteractOp.EXECUTE_CUT, 5, "5 finish off interrupted")
	for op: int in range(1, 6):
		var back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(
				NetMessages.EntityEvent.interact(42, 2000, 55, op, 0xFFFFFFFF).encode())
		if assert_not_null(back, "INTERACT with op %d" % op):
			assert_eq(back.op, op, "op %d" % op)
			assert_eq(back.actor, 55, "actor")
			assert_eq(back.end_tick, 0xFFFFFFFF, "end_tick u32")
	for bad_op: int in [0, 6, 255]:
		var tampered: PackedByteArray = bytes.duplicate()
		tampered.encode_u8(11, bad_op)
		assert_null(NetMessages.EntityEvent.decode(tampered), "INTERACT with op %d" % bad_op)


func test_new_events_reject_inconsistent_lengths() -> void:
	for sample: NetMessages.EntityEvent in _new_events():
		var bytes: PackedByteArray = sample.encode()
		assert_not_null(NetMessages.EntityEvent.decode(bytes), "event %d is valid" % sample.event)
		for wrong_len: int in [0, bytes.decode_u8(8) - 1, bytes.decode_u8(8) + 1, 255]:
			var tampered: PackedByteArray = bytes.duplicate()
			tampered.encode_u8(8, wrong_len)
			assert_null(NetMessages.EntityEvent.decode(tampered),
					"event %d with declared len %d" % [sample.event, wrong_len])
		var resized: PackedByteArray = bytes.duplicate()
		resized.resize(bytes.size() + 1)
		resized.encode_u8(8, bytes.decode_u8(8) + 1)
		assert_null(NetMessages.EntityEvent.decode(resized),
				"event %d with consistent len and size but longer than its format" % sample.event)
		var shorter: PackedByteArray = bytes.slice(0, bytes.size() - 1)
		shorter.encode_u8(8, bytes.decode_u8(8) - 1)
		assert_null(NetMessages.EntityEvent.decode(shorter),
				"event %d shorter than its format" % sample.event)
	# 12 still does not exist.
	var unknown: PackedByteArray = _new_events()[0].encode()
	unknown.encode_u8(7, 12)
	assert_null(NetMessages.EntityEvent.decode(unknown), "event 12")


func test_hit_flags_5_and_6_and_sources_in_the_old_events() -> void:
	var flags: int = NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED | NetMessages.EntityEvent.HIT_FLAG_DOWNED \
			| NetMessages.EntityEvent.HIT_FLAG_LETHAL
	var arrow_shot: int = CombatSource.make(CombatSource.Kind.ATTACK, CombatCatalog.attack_id(&"bow_quick"))
	var hit: NetMessages.EntityEvent = NetMessages.EntityEvent.hit(321, 5, 654, 60,
			DamageFormula.DamageType.PIERCE, flags, arrow_shot)
	var bytes: PackedByteArray = hit.encode()
	assert_eq(bytes.size(), 17, "HIT: 17 B, size unchanged")
	assert_eq(bytes.decode_u8(14), 0b1110000, "u8 flags at 14: bits 4, 5 and 6")
	var back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
	if assert_not_null(back, "decode of the HIT"):
		assert_true(back.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED), "interrupted")
		assert_true(back.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_DOWNED), "knocks down")
		assert_false(back.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "not blocked")
		assert_eq(back.get_source(), arrow_shot, "the source")
	# Phase 3 attacks keep their number: the source of an attack is its id.
	var light: int = CombatCatalog.attack_id(&"sword_light_1")
	assert_eq(CombatSource.make(CombatSource.Kind.ATTACK, light), light, "source of an attack = its id")
	# Each source class survives every event that carries it.
	var sources: Array[int] = [
		CombatSource.NONE, light,
		CombatSource.make(CombatSource.Kind.ABILITY, CombatCatalog.ability_id(&"shield_rush")),
		CombatSource.make(CombatSource.Kind.STATUS, CombatCatalog.status_id(&"bleed")),
		CombatSource.EXECUTE, CombatSource.BLEED_OUT,
		CombatSource.make(CombatSource.Kind.ABILITY, CombatSource.MAX_ID),
	]
	for source: int in sources:
		var events: Array[NetMessages.EntityEvent] = [
			NetMessages.EntityEvent.hit(1, 2, 3, 4, 0, 0, source),
			NetMessages.EntityEvent.death(1, 2, 3, source),
			NetMessages.EntityEvent.kill(1, 2, 3, source, PackedInt32Array([9])),
			NetMessages.EntityEvent.heal(1, 2, 3, 4, source),
			NetMessages.EntityEvent.downed(1, 2, 3, source),
		]
		for event: NetMessages.EntityEvent in events:
			var event_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(event.encode())
			if assert_not_null(event_back, "event %d with source 0x%04X" % [event.event, source]):
				assert_eq(event_back.get_source(), source, "event %d: source 0x%04X" % [event.event, source])
				assert_eq(CombatSource.kind_of(event_back.get_source()), CombatSource.kind_of(source),
						"event %d: class" % event.event)
				assert_eq(CombatSource.id_of(event_back.get_source()), CombatSource.id_of(source),
						"event %d: id" % event.event)
	assert_eq(CombatSource.kind_of(CombatSource.EXECUTE), CombatSource.Kind.SPECIAL, "the finishing blow is special")


# --- Bits 3 of the record and of the status -----------------------------------------------------

func test_record_flag_bit_3_is_the_active_second_slot() -> void:
	var state := PlayerState.new()
	state.grounded = true
	state.combat.alt_weapon_id = CombatCatalog.weapon_id(&"bow")
	var first: EntityRecord = EntityRecord.from_state(7, NetProtocol.EntityKind.PLAYER, state, 2)
	assert_false(first.is_second_slot(), "with slot 1 active, bit 3 at 0")
	assert_eq(first.flags, EntityRecord.FLAG_GROUNDED | (2 << EntityRecord.TELEPORT_SHIFT), "ground and counter")
	state.combat.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	var second: EntityRecord = EntityRecord.from_state(7, NetProtocol.EntityKind.PLAYER, state, 2)
	assert_true(second.is_second_slot(), "with slot 2 active, bit 3 at 1")
	assert_true(second.is_grounded(), "the ground does not change")
	assert_eq(second.get_teleport_counter(), 2, "nor does the teleport counter")
	var bytes := PackedByteArray()
	second.encode_into(bytes, 0)
	assert_eq(bytes.decode_u8(18) & 0b1000, 0b1000, "u8 flags at 18: bit 3")
	var back: EntityRecord = EntityRecord.decode_from(bytes, 0, NetProtocol.EntityKind.PLAYER)
	if assert_not_null(back, "decode of the record"):
		assert_true(back.is_second_slot(), "bit 3 travels")
		assert_eq(back.flags & EntityRecord.HISTORY_FLAGS_MASK, second.flags & 0b111,
				"what the history takes does not carry bit 3")
	# The server writes the record directly from the character.
	var character := PlayerCharacter.new()
	character.grounded = true
	var direct := PackedByteArray()
	EntityRecord.encode_character(direct, 0, 7, character, 1, 0, 255)
	assert_eq(direct.decode_u8(18) & EntityRecord.FLAG_SECOND_SLOT, 0, "character with slot 1")
	character.combat.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	EntityRecord.encode_character(direct, 0, 7, character, 1, 0, 255)
	assert_eq(direct.decode_u8(18), EntityRecord.FLAG_SECOND_SLOT | EntityRecord.FLAG_GROUNDED
			| (1 << EntityRecord.TELEPORT_SHIFT), "character with slot 2: bit 3 with the ground and the counter")
	character.free()


func test_snapshot_status_bit_3_is_downed() -> void:
	var snapshot := NetMessages.Snapshot.new()
	snapshot.server_tick = 500
	snapshot.own_state = PlayerState.new()
	snapshot.health = 250
	snapshot.max_health = 400
	snapshot.status = NetMessages.STATUS_DOWNED | NetMessages.STATUS_IN_COMBAT
	var bytes: PackedByteArray = snapshot.encode()
	var extra_offset: int = 13 + PlayerState.ENCODED_SIZE
	assert_eq(extra_offset, 124, "the extra block starts at 124 with the 111 B state")
	assert_eq(bytes.decode_u16(extra_offset), 250, "u16 health: the knocked-down health")
	assert_eq(bytes.decode_u16(extra_offset + 2), 400, "u16 max_health: the knocked-down one")
	assert_eq(bytes.decode_u8(extra_offset + 4), 0b1001, "u8 status: bit 3 knocked down and bit 0 in combat")
	var back: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
	if assert_not_null(back, "decode"):
		assert_true(back.is_downed(), "knocked down")
		assert_false(back.is_dead(), "not dead")
		assert_true(back.is_in_combat(), "in combat")
		assert_eq(back.health, 250, "knocked-down health")
		assert_eq(back.max_health, 400, "knocked-down maximum")
	var dead := NetMessages.Snapshot.new()
	dead.own_state = PlayerState.new()
	dead.max_health = 1000
	dead.status = NetMessages.STATUS_DEAD
	var dead_back: NetMessages.Snapshot = NetMessages.Snapshot.decode(dead.encode())
	if assert_not_null(dead_back, "a dead one"):
		assert_false(dead_back.is_downed(), "a dead one is not knocked down")
		assert_true(dead_back.is_dead(), "is dead")


func test_player_spawn_carries_the_whole_v6_state() -> void:
	var state := PlayerState.new()
	state.position = Vector3(1.0, 2.0, 3.0)
	state.grounded = true
	var combat: CombatState = state.combat
	combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	combat.alt_weapon_id = CombatCatalog.weapon_id(&"sword_shield")
	combat.combat_flags2 = CombatState.FLAG2_SECOND_SLOT
	combat.ability_ready = PackedInt64Array([101, 102, 103, 104, 105, 0xFFFFFFFF])
	combat.consumable_ready_tick = 1234
	combat.consumable_charges = CombatState.pack_charges(2, 3)
	combat.move_effect_ids = PackedInt32Array([CombatCatalog.status_id(&"slowed"), 0])
	combat.move_effect_until = PackedInt64Array([9999, 0])
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = 12
	spawn.spawn_tick = 100
	spawn.is_yours = true
	spawn.state = state
	spawn.display_name = "Ana"
	var bytes: PackedByteArray = spawn.encode()
	assert_eq(bytes.size(), 10 + 111 + 1 + 3 + 9,
			"player SPAWN: 10 B + 111 B of state + name + 9 B of level and appearance (v7)")
	var back: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if assert_not_null(back, "decode") and assert_not_null(back.state, "with state"):
		assert_true(back.state.equals_exact(state), "the 111 B state arrives exact")
		assert_eq(back.state.combat.alt_weapon_id, combat.alt_weapon_id, "the weapon pair")
		assert_true(back.state.combat.is_second_slot(), "and the active slot")
		assert_true(EntityRecord.from_state(12, back.kind, back.state, 0).is_second_slot(),
				"the remote takes bit 3 from its first sample of the SPAWN")


# --- Malformed and fuzz -------------------------------------------------------------------------

func test_malformed_v6_messages_return_null() -> void:
	var samples: Array = _samples()
	var decoders: Array[Callable] = _all_decoders()
	for entry: Array in samples:
		var label: String = entry[0]
		var bytes: PackedByteArray = entry[1]
		var decoder: Callable = entry[2]
		assert_not_null(decoder.call(bytes), "%s: the valid message decodes" % label)
		for length: int in bytes.size():
			if decoder.call(bytes.slice(0, length)) != null:
				fail("%s truncated to %d of %d B should be null" % [label, length, bytes.size()])
				break
		for extra: int in [1, 2, 20]:
			var longer: PackedByteArray = bytes.duplicate()
			longer.resize(bytes.size() + extra)
			if decoder.call(longer) != null:
				fail("%s with %d B extra should be null" % [label, extra])
		var wrong: PackedByteArray = bytes.duplicate()
		wrong[0] = 0x7F
		assert_null(decoder.call(wrong), "%s with byte 0 changed" % label)
		for other: Callable in decoders:
			if other != decoder and other.call(bytes) != null:
				fail("%s was decoded by another decoder" % label)
	for decoder: Callable in decoders:
		assert_null(decoder.call(PackedByteArray()), "empty buffer")
		assert_null(decoder.call(PackedByteArray([0])), "a single null byte")


func test_fuzz_v6_decoders_never_error() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = FUZZ_SEED
	var decoders: Array[Callable] = _all_decoders()
	var samples: Array = _samples()
	var type_bytes: Array[int] = [NetProtocol.MSG_ENTITY_SPAWN, NetProtocol.MSG_ENTITY_DESPAWN,
			NetProtocol.MSG_ENTITY_EVENT, NetProtocol.MSG_LOADOUT_SELECT, NetProtocol.MSG_DEBUG_COMMAND,
			NetProtocol.MSG_SNAPSHOT, NetProtocol.MSG_PARTY_STATUS]
	var decoded_count: int = 0
	var mutated_decoded: int = 0
	for i: int in FUZZ_BUFFERS:
		var bytes := PackedByteArray()
		var mode: int = i % 4
		if mode == 0:
			var length: int = rng.randi_range(0, 40)
			if rng.randf() >= 0.6:
				length = rng.randi_range(0, 300)
			bytes.resize(length)
			for j: int in length:
				bytes[j] = rng.randi() & 0xFF
		elif mode == 1:
			# A known type followed by random bytes.
			var length: int = rng.randi_range(1, 60)
			bytes.resize(length)
			for j: int in length:
				bytes[j] = rng.randi() & 0xFF
			bytes[0] = type_bytes[rng.randi() % type_bytes.size()]
		elif mode == 2:
			# One of the example messages with a few bytes changed, trimmed or extended.
			bytes = (samples[rng.randi() % samples.size()][1] as PackedByteArray).duplicate()
			for _k: int in rng.randi_range(0, 3):
				bytes[rng.randi() % bytes.size()] = rng.randi() & 0xFF
			var roll: float = rng.randf()
			if roll < 0.2:
				bytes.resize(rng.randi_range(0, bytes.size()))
			elif roll < 0.3:
				bytes.append(rng.randi() & 0xFF)
		else:
			# A new ENTITY_EVENT or a projectile SPAWN with a correct header and the rest random.
			bytes = _random_v6_message(rng)
		for decoder: Callable in decoders:
			var result: Variant = decoder.call(bytes)
			if result == null:
				continue
			decoded_count += 1
			if mode >= 2:
				mutated_decoded += 1
			if result is NetMessages.EntityEvent:
				var event: NetMessages.EntityEvent = result
				match event.event:
					NetMessages.EntityEvent.Kind.STATUS:
						assert_true(event.op == 1 or event.op == 2, "a decoded STATUS carries op 1 or 2")
						assert_true(event.op == 2 or event.stacks > 0, "and an applied one, stacks")
					NetMessages.EntityEvent.Kind.INTERACT:
						assert_true(event.op >= 1 and event.op <= 5, "a decoded INTERACT carries op 1 to 5")
				if event.event >= NetMessages.EntityEvent.Kind.STATUS:
					assert_eq(event.encode(), bytes, "a decoded new ENTITY_EVENT re-encodes the same")
			elif result is NetMessages.EntitySpawn:
				var spawn: NetMessages.EntitySpawn = result
				if spawn.kind == NetProtocol.EntityKind.PROJECTILE:
					assert_false(spawn.is_yours, "a decoded projectile is never yours")
					assert_eq(spawn.projectile_flags & ~NetMessages.EntitySpawn.PROJECTILE_FLAGS_VALID, 0,
							"nor does it carry proj_flags bits that do not exist")
					# Bits 60-63 of the position mean nothing: what is read is what is compared.
					var again: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(spawn.encode())
					if assert_not_null(again, "a decoded projectile re-encodes"):
						assert_true(_same_projectile(spawn, again), "and reads back the same")
	assert_true(mutated_decoded > 100, "the fuzz reaches valid messages (%d)" % mutated_decoded)
	assert_true(decoded_count >= mutated_decoded, "consistent counters")


# --- Utilities --------------------------------------------------------------------------------

func _same_projectile(a: NetMessages.EntitySpawn, b: NetMessages.EntitySpawn) -> bool:
	return a.net_id == b.net_id and a.spawn_tick == b.spawn_tick and a.realm == b.realm \
			and a.owner_id == b.owner_id and a.projectile_def_id == b.projectile_def_id and a.source == b.source \
			and a.volley_index == b.volley_index and a.projectile_flags == b.projectile_flags \
			and a.origin == b.origin and a.velocity == b.velocity


func _projectile_spawn() -> NetMessages.EntitySpawn:
	return NetMessages.EntitySpawn.for_projectile(900, 5000, NetProtocol.Realm.VARDHEIM, 12,
			CombatCatalog.projectile_id(&"arrow"), CombatCatalog.attack_id(&"bow_quick"), 0, false,
			Vector3(10.0, 1.4, -3.0), Vector3(0.0, 2.0, 44.9))


## An example of each new event (7 to 11).
func _new_events() -> Array[NetMessages.EntityEvent]:
	var events: Array[NetMessages.EntityEvent] = [
		NetMessages.EntityEvent.status(1, 2, 3, NetMessages.EntityEvent.StatusOp.APPLIED, 4, 1, 300),
		NetMessages.EntityEvent.heal(1, 2, 0, 50, 0x8001),
		NetMessages.EntityEvent.loadout(1, 2, 2, 3, 4, 0x32),
		NetMessages.EntityEvent.downed(1, 2, 3, 0x4002),
		NetMessages.EntityEvent.interact(1, 2, 3, NetMessages.EntityEvent.InteractOp.EXECUTE, 62),
	]
	return events


## [label, valid bytes, decoder] of each new message and of others whose decoder shares a type
## with them.
func _samples() -> Array:
	var player := NetMessages.EntitySpawn.new()
	player.net_id = 9
	player.state = PlayerState.new()
	player.display_name = "Ana"
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = 900
	despawn.despawn_tick = 5040
	despawn.reason = NetProtocol.DespawnReason.IMPACT
	var downed_party := NetMessages.PartyStatus.new()
	downed_party.members.append(NetMessages.PartyStatus.MemberStatus.make(4, 100, 30,
			NetMessages.STATUS_DOWNED, Vector3(1.0, 0.0, 2.0)))
	var downed_snapshot := NetMessages.Snapshot.new()
	downed_snapshot.own_state = PlayerState.new()
	downed_snapshot.health = 399
	downed_snapshot.max_health = 400
	downed_snapshot.status = NetMessages.STATUS_DOWNED
	var result: Array = [
		["LOADOUT_SELECT", NetMessages.LoadoutSelect.make(2).encode(), NetMessages.LoadoutSelect.decode],
		["ENTITY_SPAWN PROJECTILE", _projectile_spawn().encode(), NetMessages.EntitySpawn.decode],
		["ENTITY_SPAWN PLAYER", player.encode(), NetMessages.EntitySpawn.decode],
		["ENTITY_DESPAWN IMPACT", despawn.encode(), NetMessages.EntityDespawn.decode],
		["DEBUG_COMMAND apply_status", NetMessages.DebugCommand.apply_status(3, 120).encode(),
				NetMessages.DebugCommand.decode],
		["DEBUG_COMMAND cooldowns_off", NetMessages.DebugCommand.cooldowns_off(true).encode(),
				NetMessages.DebugCommand.decode],
		["PARTY_STATUS derribado", downed_party.encode(), NetMessages.PartyStatus.decode],
		["SNAPSHOT derribado", downed_snapshot.encode(), NetMessages.Snapshot.decode],
		["ENTITY_EVENT HIT", NetMessages.EntityEvent.hit(1, 2, 3, 4, 0, 0x60, 0x4001).encode(),
				NetMessages.EntityEvent.decode],
	]
	for event: NetMessages.EntityEvent in _new_events():
		result.append(["ENTITY_EVENT %d" % event.event, event.encode(), NetMessages.EntityEvent.decode])
	return result


func _all_decoders() -> Array[Callable]:
	var result: Array[Callable] = [
		NetMessages.Hello.decode, NetMessages.Welcome.decode, NetMessages.Reject.decode,
		NetMessages.InputBatch.decode, NetMessages.ClientReady.decode,
		NetMessages.ClientLeave.decode, NetMessages.DebugCommand.decode,
		NetMessages.Snapshot.decode, NetMessages.EntitySpawn.decode,
		NetMessages.EntityDespawn.decode, NetMessages.Notice.decode,
		NetMessages.EntityEvent.decode, NetMessages.RespawnRequest.decode,
		NetMessages.ObjectState.decode, NetMessages.UnstuckRequest.decode,
		NetMessages.Scoreboard.decode, NetMessages.LoadoutSelect.decode,
		NetMessages.PartyStatus.decode,
	]
	return result


# One of the new ENTITY_EVENTs with its correct size and length and random data, or a 32 B
# projectile SPAWN with a correct header and the rest random.
func _random_v6_message(rng: RandomNumberGenerator) -> PackedByteArray:
	var bytes := PackedByteArray()
	if rng.randf() < 0.5:
		bytes.resize(NetMessages.EntitySpawn.PROJECTILE_SIZE)
		for j: int in bytes.size():
			bytes[j] = rng.randi() & 0xFF
		bytes[0] = NetProtocol.MSG_ENTITY_SPAWN
		bytes[3] = NetProtocol.EntityKind.PROJECTILE
		if rng.randf() < 0.7:
			bytes[9] = 0
		if rng.randf() < 0.7:
			bytes[17] &= 1
		return bytes
	var sample: NetMessages.EntityEvent = _new_events()[rng.randi() % 5]
	bytes = sample.encode()
	for j: int in range(9, bytes.size()):
		bytes[j] = rng.randi() & 0xFF
	return bytes
