extends TestCase
## Pruebas del protocolo 6 (docs/habilidades.md, sección 5; paquete H2): los botones nuevos de
## [constant NetProtocol.VALID_BUTTONS], LOADOUT_SELECT, los comandos de depuración 13 a 16, el
## ENTITY_SPAWN de proyectiles (32 B, sin [code]is_yours[/code]) y los motivos de ENTITY_DESPAWN 4 y 5,
## los ENTITY_EVENT 7 a 11 (STATUS, HEAL, LOADOUT, DOWNED, INTERACT), los bits 5 y 6 de un HIT, las fuentes
## ([CombatSource]) en los campos de 16 bits, el bit 3 de los flags del registro (ranura 2) y el bit 3 de
## [code]status[/code] (derribado) en el SNAPSHOT y el PARTY_STATUS.
## [br][br]
## Como en test_net_messages.gd y test_net_messages_v3.gd, los offsets y tamaños son los del documento,
## escritos a mano a propósito. Los mensajes malformados y el fuzz comprueban además que nada registra
## errores del motor (el ejecutor los cuenta como fallo).

const FUZZ_BUFFERS: int = 8000
const FUZZ_SEED: int = 20261029 + 6


# --- Constantes y canales ---------------------------------------------------------------------

func test_protocol_6_constants_and_channels() -> void:
	assert_eq(NetProtocol.PROTOCOL_VERSION, 6, "las habilidades suben el protocolo a la versión 6")
	assert_eq(NetProtocol.MSG_LOADOUT_SELECT, 0x07, "LOADOUT_SELECT es el 0x07")
	assert_eq(NetProtocol.channel_for_type(NetProtocol.MSG_LOADOUT_SELECT), NetProtocol.CH_RELIABLE,
			"LOADOUT_SELECT va por el canal fiable (3)")
	assert_eq(NetProtocol.DespawnReason.IMPACT, 4, "DESPAWN 4: impacto")
	assert_eq(NetProtocol.DespawnReason.EXPIRED, 5, "DESPAWN 5: caducado")
	assert_eq(NetProtocol.EntityKind.PROJECTILE, 3, "kind 3: proyectil")
	# Eventos y bits nuevos, con sus números del documento.
	assert_eq(NetMessages.EntityEvent.Kind.STATUS, 7, "STATUS")
	assert_eq(NetMessages.EntityEvent.Kind.HEAL, 8, "HEAL")
	assert_eq(NetMessages.EntityEvent.Kind.LOADOUT, 9, "LOADOUT")
	assert_eq(NetMessages.EntityEvent.Kind.DOWNED, 10, "DOWNED")
	assert_eq(NetMessages.EntityEvent.Kind.INTERACT, 11, "INTERACT")
	assert_eq(NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED, 1 << 5, "HIT: bit 5 interrumpido")
	assert_eq(NetMessages.EntityEvent.HIT_FLAG_DOWNED, 1 << 6, "HIT: bit 6 derriba")
	assert_eq(NetMessages.STATUS_DOWNED, 1 << 3, "status: bit 3 derribado")
	assert_eq(EntityRecord.FLAG_SECOND_SLOT, 1 << 3, "flags del registro: bit 3 ranura 2")
	assert_eq(EntityRecord.HISTORY_FLAGS_MASK, 0b111, "el historial solo toma los bits 0-2 del registro")
	assert_eq(EntityRecord.FLAG_SECOND_SLOT & EntityRecord.HISTORY_FLAGS_MASK, 0,
			"el bit de la ranura 2 no entra en el historial (allí el bit 3 es el bloqueo)")
	assert_eq(EntityRecord.FLAG_SECOND_SLOT, ActionMachine.DEFENSE_BLOCKING,
			"por eso hay que enmascararlo: es el mismo bit que DEFENSE_BLOCKING")
	assert_eq(NetMessages.EntitySpawn.PROJECTILE_SIZE, 32, "SPAWN de proyectil: 32 B")


func test_valid_buttons_carry_the_new_buttons() -> void:
	assert_eq(NetProtocol.VALID_BUTTONS, (1 << 13) - 1, "bits 0-12")
	for button: int in [PlayerInput.SWAP_WEAPON, PlayerInput.AIM_LEFT, PlayerInput.CONSUMABLE_1,
			PlayerInput.CONSUMABLE_2, PlayerInput.INTERACT, PlayerInput.ABILITY_3]:
		assert_eq(button & NetProtocol.VALID_BUTTONS, button, "el botón 0x%04X es válido" % button)
	for reserved: int in [1 << 13, 1 << 14, PlayerInput.SUBSTITUTED]:
		assert_eq(reserved & NetProtocol.VALID_BUTTONS, 0, "el bit 0x%04X no es un botón" % reserved)
	# Un lote con los botones nuevos llega entero; los bits 13-15 se quedan fuera.
	var batch := NetMessages.InputBatch.new()
	batch.newest_tick = 300
	var input := PlayerInput.new()
	input.tick = 300
	input.buttons = PlayerInput.SWAP_WEAPON | PlayerInput.AIM_LEFT | PlayerInput.CONSUMABLE_1 \
			| PlayerInput.CONSUMABLE_2 | PlayerInput.PRIMARY | (1 << 13) | (1 << 14) | PlayerInput.SUBSTITUTED
	batch.inputs.append(input)
	batch.view_offsets_q.append(0)
	var decoded: NetMessages.InputBatch = NetMessages.InputBatch.decode(batch.encode())
	if assert_not_null(decoded, "decode del lote"):
		assert_eq(decoded.inputs[0].buttons, PlayerInput.SWAP_WEAPON | PlayerInput.AIM_LEFT
				| PlayerInput.CONSUMABLE_1 | PlayerInput.CONSUMABLE_2 | PlayerInput.PRIMARY,
				"Q, hombro izquierdo, R, T y PRIMARY llegan; los reservados y la marca de sustituida, no")


# --- LOADOUT_SELECT y comandos de depuración --------------------------------------------------

func test_loadout_select_layout_and_roundtrip() -> void:
	var marksman: int = CombatCatalog.template_id(&"marksman")
	assert_true(marksman > 0, "el tirador existe (id pedido por nombre)")
	var select: NetMessages.LoadoutSelect = NetMessages.LoadoutSelect.make(marksman)
	var bytes: PackedByteArray = select.encode()
	assert_eq(bytes, PackedByteArray([0x07, marksman]), "LOADOUT_SELECT: u8 type 0x07 y u8 template_id")
	assert_eq(bytes.size(), 2, "2 B")
	var back: NetMessages.LoadoutSelect = NetMessages.LoadoutSelect.decode(bytes)
	if assert_not_null(back, "decode"):
		assert_eq(back.template_id, marksman, "template_id")
	# 0 es la de por defecto y cualquier u8 viaja: quien decide si existe y se puede elegir es el servidor.
	for id: int in [0, 1, 255]:
		var other: NetMessages.LoadoutSelect = NetMessages.LoadoutSelect.decode(
				NetMessages.LoadoutSelect.make(id).encode())
		if assert_not_null(other, "template_id %d" % id):
			assert_eq(other.template_id, id, "template_id %d" % id)
	assert_eq(NetMessages.LoadoutSelect.make(300).encode()[1], 300 & 0xFF, "módulo 256")
	assert_null(NetMessages.LoadoutSelect.decode(PackedByteArray([0x07])), "sin id")
	assert_null(NetMessages.LoadoutSelect.decode(PackedByteArray([0x07, 1, 0])), "con un byte de más")
	assert_null(NetMessages.LoadoutSelect.decode(PackedByteArray([0x06, 1])), "otro tipo")


func test_debug_commands_13_to_16_validate_their_data() -> void:
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"cooldowns_off"], 13, "13 cooldowns_off")
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"apply_status"], 14, "14 apply_status")
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"down"], 15, "15 down")
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"refill"], 16, "16 refill")
	# 13 cooldowns_off: 0 o 1.
	assert_eq(NetMessages.DebugCommand.cooldowns_off(true).encode(), PackedByteArray([0x04, 13, 1]), "activar")
	assert_eq(NetMessages.DebugCommand.cooldowns_off(false).encode(), PackedByteArray([0x04, 13, 0]), "apagar")
	for value: int in [0, 1]:
		assert_not_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 13, value])), "%d vale" % value)
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 13, 2])), "2 no")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 13])), "sin dato")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 13, 1, 0])), "con 2 B")
	# 14 apply_status: u8 status_id (1 a 255) y u16 ticks (0 = los del dato).
	var bleed: int = CombatCatalog.status_id(&"bleed")
	assert_true(bleed > 0, "el sangrado existe (id pedido por nombre)")
	var apply: NetMessages.DebugCommand = NetMessages.DebugCommand.apply_status(bleed, 600)
	var apply_bytes: PackedByteArray = apply.encode()
	assert_eq(apply_bytes.size(), 5, "apply_status: 5 B")
	assert_eq(apply_bytes.decode_u8(1), 14, "u8 command")
	assert_eq(apply_bytes.decode_u8(2), bleed, "u8 status_id en 2")
	assert_eq(apply_bytes.decode_u16(3), 600, "u16 ticks en 3")
	var apply_back: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(apply_bytes)
	if assert_not_null(apply_back, "decode de apply_status"):
		assert_eq(apply_back.get_status_id(), bleed, "get_status_id")
		assert_eq(apply_back.get_status_ticks(), 600, "get_status_ticks")
	var by_data: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(
			NetMessages.DebugCommand.apply_status(bleed).encode())
	if assert_not_null(by_data, "apply_status con la duración del dato"):
		assert_eq(by_data.get_status_ticks(), 0, "0 = los ticks del dato")
	assert_eq(NetMessages.DebugCommand.apply_status(bleed, 100000).encode().decode_u16(3), 0xFFFF,
			"los ticks se saturan a u16")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 14, 0, 10, 0])), "status_id 0")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 14, 1, 10])), "sin el segundo byte de ticks")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 14, 1, 10, 0, 0])), "con un byte de más")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 14])), "sin datos")
	assert_eq(NetMessages.DebugCommand.new().get_status_id(), 0, "get_status_id sin datos: 0")
	# 15 down y 16 refill: sin datos.
	for command_id: int in [NetProtocol.DEBUG_DOWN, NetProtocol.DEBUG_REFILL]:
		var simple: NetMessages.DebugCommand = NetMessages.DebugCommand.simple(command_id)
		assert_eq(simple.encode(), PackedByteArray([0x04, command_id]), "comando %d sin datos" % command_id)
		assert_not_null(NetMessages.DebugCommand.decode(simple.encode()), "comando %d" % command_id)
		assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, command_id, 0])),
				"el comando %d no admite datos" % command_id)


# --- Proyectiles --------------------------------------------------------------------------------

func test_projectile_spawn_layout_and_roundtrip() -> void:
	var arrow: int = CombatCatalog.projectile_id(&"arrow")
	var volley: int = CombatSource.make(CombatSource.Kind.ABILITY, CombatCatalog.ability_id(&"bow_volley"))
	var p0 := Vector3(-123.456, 7.891, 4321.004)
	var v0 := Vector3(30.123, 4.567, -32.009)
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.for_projectile(0xBEEF, 765432,
			NetProtocol.Realm.SOLMARCH, 4242, arrow, volley, 2, true, p0, v0)
	# Aunque alguien lo marque como «tuyo», un proyectil nunca lo es en el mensaje.
	spawn.is_yours = true
	var bytes: PackedByteArray = spawn.encode()
	assert_eq(bytes.size(), 32, "ENTITY_SPAWN de proyectil: 10 B de cabecera y 22 B")
	assert_eq(bytes.decode_u8(0), 0x20, "u8 type en 0")
	assert_eq(bytes.decode_u16(1), 0xBEEF, "u16 net_id (el proyectil) en 1")
	assert_eq(bytes.decode_u8(3), 3, "u8 kind en 3: PROJECTILE")
	assert_eq(bytes.decode_u32(4), 765432, "u32 spawn_tick (el del disparo) en 4")
	assert_eq(bytes.decode_u8(8), NetProtocol.Realm.SOLMARCH, "u8 realm (el del tirador) en 8")
	assert_eq(bytes.decode_u8(9), 0, "u8 flags en 9: 0 (is_yours siempre 0; un proyectil no se teletransporta)")
	assert_eq(bytes.decode_u16(10), 4242, "u16 owner en 10")
	assert_eq(bytes.decode_u16(12), arrow, "u16 projectile_def_id en 12")
	assert_eq(bytes.decode_u16(14), volley, "u16 source en 14")
	assert_eq(bytes.decode_u8(16), 2, "u8 volley_index en 16")
	assert_eq(bytes.decode_u8(17), 1, "u8 proj_flags en 17: inofensiva")
	assert_eq(bytes.decode_u64(18), NetMath.pack_position(p0), "u64 position en 18, como el registro")
	assert_eq(bytes.decode_s16(26), 3012, "s16 velocity.x en 26 (cm/s)")
	assert_eq(bytes.decode_s16(28), 457, "s16 velocity.y en 28")
	assert_eq(bytes.decode_s16(30), -3201, "s16 velocity.z en 30")

	var back: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if not assert_not_null(back, "decode del SPAWN de proyectil"):
		return
	assert_eq(back.kind, NetProtocol.EntityKind.PROJECTILE, "kind")
	assert_eq(back.net_id, 0xBEEF, "net_id")
	assert_eq(back.spawn_tick, 765432, "spawn_tick")
	assert_eq(back.realm, NetProtocol.Realm.SOLMARCH, "realm")
	assert_false(back.is_yours, "nunca es tuyo")
	assert_eq(back.owner_id, 4242, "owner_id")
	assert_eq(back.projectile_def_id, arrow, "projectile_def_id")
	assert_eq(back.source, volley, "source")
	assert_eq(CombatSource.kind_of(back.source), CombatSource.Kind.ABILITY, "la fuente es una habilidad")
	assert_eq(back.volley_index, 2, "volley_index")
	assert_true(back.is_harmless(), "inofensiva")
	assert_null(back.state, "sin PlayerState")
	# La balística que viaja es exactamente la de Ballistics.quantize: el servidor vuela con ella.
	var quantized: Array = Ballistics.quantize(p0, v0)
	assert_eq(back.origin, quantized[0] as Vector3, "origin = Ballistics.quantize (1 cm)")
	assert_eq(back.velocity, quantized[1] as Vector3, "velocity = Ballistics.quantize (1 cm/s)")
	assert_eq(back.encode(), bytes, "recodificar da los mismos bytes")
	var requantized: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(
			NetMessages.EntitySpawn.for_projectile(1, 2, 1, 3, arrow, 4, 0, false, back.origin,
			back.velocity).encode())
	if assert_not_null(requantized, "lo ya cuantizado"):
		assert_eq(requantized.origin, back.origin, "no se mueve al volver a cuantizar")
		assert_eq(requantized.velocity, back.velocity, "ni la velocidad")
		assert_false(requantized.is_harmless(), "sin el bit de inofensiva")
		assert_eq(requantized.projectile_flags, 0, "proj_flags 0")

	# Los extremos se saturan: posición a ±5,24 km y velocidad a ±327,67 m/s.
	var extreme: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(
			NetMessages.EntitySpawn.for_projectile(0xFFFF, 0xFFFFFFFF, 3, 0xFFFF, 0xFFFF, 0xFFFF, 255, false,
			Vector3(1e6, -1e6, 0.0), Vector3(500.0, -500.0, NAN)).encode())
	if assert_not_null(extreme, "extremos"):
		assert_eq(extreme.spawn_tick, 0xFFFFFFFF, "tick máximo")
		assert_eq(extreme.volley_index, 255, "volley_index máximo")
		assert_near(extreme.origin.x, 5242.87, 0.01, "posición saturada por arriba")
		assert_near(extreme.origin.y, -5242.88, 0.01, "y por abajo")
		assert_near(extreme.velocity.x, 327.67, 1e-4, "velocidad saturada")
		assert_near(extreme.velocity.y, -327.68, 1e-4, "y por abajo")
		assert_eq(extreme.velocity.z, 0.0, "un NaN viaja como 0")


func test_projectile_spawn_rejects_malformed_bytes() -> void:
	var bytes: PackedByteArray = _projectile_spawn().encode()
	assert_not_null(NetMessages.EntitySpawn.decode(bytes), "el de partida vale")
	var yours: PackedByteArray = bytes.duplicate()
	yours.encode_u8(9, 1)
	assert_null(NetMessages.EntitySpawn.decode(yours), "con el bit is_yours: un proyectil nunca es tuyo")
	for header_flags: int in [2, 4, 6, 8, 0x80]:
		var flagged: PackedByteArray = bytes.duplicate()
		flagged.encode_u8(9, header_flags)
		assert_null(NetMessages.EntitySpawn.decode(flagged), "con los flags de la cabecera a 0x%02X" % header_flags)
	for unknown_flag: int in [2, 4, 0x80]:
		var bad_flags: PackedByteArray = bytes.duplicate()
		bad_flags.encode_u8(17, unknown_flag)
		assert_null(NetMessages.EntitySpawn.decode(bad_flags), "proj_flags con el bit 0x%02X" % unknown_flag)
	for length: int in [10, 11, 31, 33, 10 + PlayerState.ENCODED_SIZE + 1]:
		var resized: PackedByteArray = bytes.duplicate()
		resized.resize(length)
		assert_null(NetMessages.EntitySpawn.decode(resized), "un proyectil de %d B" % length)
	# Un SPAWN de jugador con el kind cambiado a proyectil no se lee como proyectil, ni al revés.
	var player := NetMessages.EntitySpawn.new()
	player.net_id = 9
	player.state = PlayerState.new()
	player.display_name = "Ana"
	var as_projectile: PackedByteArray = player.encode()
	as_projectile.encode_u8(3, NetProtocol.EntityKind.PROJECTILE)
	assert_null(NetMessages.EntitySpawn.decode(as_projectile), "un jugador relabelado como proyectil")
	var as_player: PackedByteArray = bytes.duplicate()
	as_player.encode_u8(3, NetProtocol.EntityKind.PLAYER)
	assert_null(NetMessages.EntitySpawn.decode(as_player), "un proyectil relabelado como jugador")
	as_player.encode_u8(3, NetProtocol.EntityKind.NPC)
	assert_null(NetMessages.EntitySpawn.decode(as_player), "ni como PNJ")
	as_player.encode_u8(3, NetProtocol.EntityKind.STRUCTURE)
	assert_null(NetMessages.EntitySpawn.decode(as_player), "ni como estructura")


func test_projectile_despawn_reasons() -> void:
	for reason: int in [NetProtocol.DespawnReason.IMPACT, NetProtocol.DespawnReason.EXPIRED]:
		var despawn := NetMessages.EntityDespawn.new()
		despawn.net_id = 0xBEEF
		despawn.despawn_tick = 765440
		despawn.reason = reason
		var bytes: PackedByteArray = despawn.encode()
		assert_eq(bytes.size(), 8, "ENTITY_DESPAWN: 8 B, sin cambios")
		assert_eq(bytes.decode_u8(7), reason, "u8 reason en 7")
		var back: NetMessages.EntityDespawn = NetMessages.EntityDespawn.decode(bytes)
		if assert_not_null(back, "decode del DESPAWN %d" % reason):
			assert_eq(back.reason, reason, "motivo %d" % reason)
			assert_eq(back.despawn_tick, 765440, "despawn_tick: el tick del impacto")


# --- ENTITY_EVENT 7 a 11 ------------------------------------------------------------------------

func test_status_event_layout_and_roundtrip() -> void:
	var slowed: int = CombatCatalog.status_id(&"slowed")
	var event: NetMessages.EntityEvent = NetMessages.EntityEvent.status(321, 123456, 654,
			NetMessages.EntityEvent.StatusOp.APPLIED, slowed, 2, 0xFFFFFFF0)
	var bytes: PackedByteArray = event.encode()
	assert_eq(bytes.size(), 18, "STATUS: 18 B")
	assert_eq(bytes.decode_u8(0), 0x23, "u8 type en 0")
	assert_eq(bytes.decode_u16(1), 321, "u16 net_id (el afectado) en 1")
	assert_eq(bytes.decode_u32(3), 123456, "u32 tick en 3")
	assert_eq(bytes.decode_u8(7), 7, "u8 event en 7: STATUS")
	assert_eq(bytes.decode_u8(8), 9, "u8 len en 8")
	assert_eq(bytes.decode_u16(9), 654, "u16 source_entity en 9")
	assert_eq(bytes.decode_u8(11), 1, "u8 op en 11: aplicado")
	assert_eq(bytes.decode_u8(12), slowed, "u8 status_id en 12")
	assert_eq(bytes.decode_u8(13), 2, "u8 stacks en 13")
	assert_eq(bytes.decode_u32(14), 0xFFFFFFF0, "u32 until_tick en 14")
	var back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
	if not assert_not_null(back, "decode del STATUS"):
		return
	assert_eq(back.event, NetMessages.EntityEvent.Kind.STATUS, "event")
	assert_eq(back.net_id, 321, "net_id")
	assert_eq(back.source_entity, 654, "source_entity")
	assert_eq(back.op, NetMessages.EntityEvent.StatusOp.APPLIED, "op")
	assert_eq(back.status_id, slowed, "status_id")
	assert_eq(back.stacks, 2, "stacks")
	assert_eq(back.until_tick, 0xFFFFFFF0, "until_tick")
	assert_eq(back.get_source(), CombatSource.NONE, "un STATUS no lleva fuente")
	assert_eq(back.encode(), bytes, "recodificar da los mismos bytes")
	# Quitado: 0 acumulaciones vale; sin autor, 0.
	var removed: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(NetMessages.EntityEvent.status(5, 6, 0,
			NetMessages.EntityEvent.StatusOp.REMOVED, slowed, 0, 100).encode())
	if assert_not_null(removed, "STATUS quitado"):
		assert_eq(removed.op, NetMessages.EntityEvent.StatusOp.REMOVED, "op 2")
		assert_eq(removed.source_entity, 0, "sin autor")
	# Las acumulaciones se saturan a u8.
	var many: NetMessages.EntityEvent = NetMessages.EntityEvent.status(5, 6, 7,
			NetMessages.EntityEvent.StatusOp.APPLIED, slowed, 999, 100)
	assert_eq(many.encode().decode_u8(13), 255, "stacks saturadas a 255")
	# op fuera de rango y STATUS aplicado sin acumulaciones: null.
	for bad_op: int in [0, 3, 255]:
		var tampered: PackedByteArray = bytes.duplicate()
		tampered.encode_u8(11, bad_op)
		assert_null(NetMessages.EntityEvent.decode(tampered), "STATUS con op %d" % bad_op)
	var no_stacks: PackedByteArray = bytes.duplicate()
	no_stacks.encode_u8(13, 0)
	assert_null(NetMessages.EntityEvent.decode(no_stacks), "STATUS aplicado con 0 acumulaciones")


func test_heal_loadout_and_downed_layouts() -> void:
	var regen: int = CombatSource.make(CombatSource.Kind.STATUS, CombatCatalog.status_id(&"potion_regen"))
	var heal: NetMessages.EntityEvent = NetMessages.EntityEvent.heal(40, 1000, 0, 50, regen)
	var heal_bytes: PackedByteArray = heal.encode()
	assert_eq(heal_bytes.size(), 15, "HEAL: 15 B")
	assert_eq(heal_bytes.decode_u8(7), 8, "u8 event: HEAL")
	assert_eq(heal_bytes.decode_u8(8), 6, "u8 len")
	assert_eq(heal_bytes.decode_u16(9), 0, "u16 healer en 9: 0 = sí mismo")
	assert_eq(heal_bytes.decode_u16(11), 50, "u16 amount en 11")
	assert_eq(heal_bytes.decode_u16(13), regen, "u16 source en 13")
	var heal_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(heal_bytes)
	if assert_not_null(heal_back, "decode del HEAL"):
		assert_eq(heal_back.event, NetMessages.EntityEvent.Kind.HEAL, "event")
		assert_eq(heal_back.net_id, 40, "el curado")
		assert_eq(heal_back.healer, 0, "healer")
		assert_eq(heal_back.amount, 50, "amount")
		assert_eq(heal_back.get_source(), regen, "la fuente es el efecto")
		assert_eq(CombatSource.kind_of(heal_back.get_source()), CombatSource.Kind.STATUS, "clase STATUS")
		assert_eq(heal_back.encode(), heal_bytes, "recodificar da los mismos bytes")
	assert_eq(NetMessages.EntityEvent.heal(1, 2, 3, 70000, 4).encode().decode_u16(11), 0xFFFF,
			"la vida curada se satura a u16")
	assert_eq(NetMessages.EntityEvent.heal(1, 2, 3, -5, 4).encode().decode_u16(11), 0, "y no baja de 0")

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
	assert_eq(loadout_bytes.decode_u8(9), marksman, "u8 template_id en 9")
	assert_eq(loadout_bytes.decode_u16(10), bow, "u16 weapon_1 en 10")
	assert_eq(loadout_bytes.decode_u16(12), sword, "u16 weapon_2 en 12")
	assert_eq(loadout_bytes.decode_u8(14), charges, "u8 charges en 14")
	var loadout_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(loadout_bytes)
	if assert_not_null(loadout_back, "decode del LOADOUT"):
		assert_eq(loadout_back.template_id, marksman, "template_id")
		assert_eq(loadout_back.weapon_1, bow, "weapon_1")
		assert_eq(loadout_back.weapon_2, sword, "weapon_2")
		assert_eq(loadout_back.charges & 0x0F, 2, "cargas de la poción 1 (bits 0-3)")
		assert_eq(loadout_back.charges >> 4, 3, "cargas de la poción 2 (bits 4-7)")
		assert_eq(loadout_back.encode(), loadout_bytes, "recodificar da los mismos bytes")
	var others: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(
			NetMessages.EntityEvent.loadout(41, 1001, marksman, bow, 0, 0).encode())
	if assert_not_null(others, "LOADOUT ajeno, sin segunda arma"):
		assert_eq(others.weapon_2, 0, "0 = ninguna")
		assert_eq(others.charges, 0, "a quien no es el dueño, charges 0")

	var bash: int = CombatSource.make(CombatSource.Kind.ABILITY, CombatCatalog.ability_id(&"shield_bash"))
	var downed: NetMessages.EntityEvent = NetMessages.EntityEvent.downed(42, 1002, 77, bash)
	var downed_bytes: PackedByteArray = downed.encode()
	assert_eq(downed_bytes.size(), 13, "DOWNED: 13 B")
	assert_eq(downed_bytes.decode_u8(7), 10, "u8 event: DOWNED")
	assert_eq(downed_bytes.decode_u8(8), 4, "u8 len")
	assert_eq(downed_bytes.decode_u16(9), 77, "u16 attacker en 9")
	assert_eq(downed_bytes.decode_u16(11), bash, "u16 source en 11")
	var downed_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(downed_bytes)
	if assert_not_null(downed_back, "decode del DOWNED"):
		assert_eq(downed_back.net_id, 42, "el derribado")
		assert_eq(downed_back.attacker, 77, "attacker")
		assert_eq(downed_back.get_source(), bash, "la fuente es la habilidad")
		assert_eq(downed_back.encode(), downed_bytes, "recodificar da los mismos bytes")


func test_interact_event_layout_and_ops() -> void:
	var interact: NetMessages.EntityEvent = NetMessages.EntityEvent.interact(42, 2000, 55,
			NetMessages.EntityEvent.InteractOp.REVIVE, 2180)
	var bytes: PackedByteArray = interact.encode()
	assert_eq(bytes.size(), 16, "INTERACT: 16 B")
	assert_eq(bytes.decode_u16(1), 42, "u16 net_id: el derribado")
	assert_eq(bytes.decode_u8(7), 11, "u8 event: INTERACT")
	assert_eq(bytes.decode_u8(8), 7, "u8 len")
	assert_eq(bytes.decode_u16(9), 55, "u16 actor en 9")
	assert_eq(bytes.decode_u8(11), 1, "u8 op en 11: levantar")
	assert_eq(bytes.decode_u32(12), 2180, "u32 end_tick en 12")
	assert_eq(NetMessages.EntityEvent.InteractOp.REVIVE, 1, "1 levantar")
	assert_eq(NetMessages.EntityEvent.InteractOp.REVIVE_CUT, 2, "2 levantar cortado")
	assert_eq(NetMessages.EntityEvent.InteractOp.REVIVED, 3, "3 levantado")
	assert_eq(NetMessages.EntityEvent.InteractOp.EXECUTE, 4, "4 rematar")
	assert_eq(NetMessages.EntityEvent.InteractOp.EXECUTE_CUT, 5, "5 rematar cortado")
	for op: int in range(1, 6):
		var back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(
				NetMessages.EntityEvent.interact(42, 2000, 55, op, 0xFFFFFFFF).encode())
		if assert_not_null(back, "INTERACT con op %d" % op):
			assert_eq(back.op, op, "op %d" % op)
			assert_eq(back.actor, 55, "actor")
			assert_eq(back.end_tick, 0xFFFFFFFF, "end_tick u32")
	for bad_op: int in [0, 6, 255]:
		var tampered: PackedByteArray = bytes.duplicate()
		tampered.encode_u8(11, bad_op)
		assert_null(NetMessages.EntityEvent.decode(tampered), "INTERACT con op %d" % bad_op)


func test_new_events_reject_inconsistent_lengths() -> void:
	for sample: NetMessages.EntityEvent in _new_events():
		var bytes: PackedByteArray = sample.encode()
		assert_not_null(NetMessages.EntityEvent.decode(bytes), "el evento %d vale" % sample.event)
		for wrong_len: int in [0, bytes.decode_u8(8) - 1, bytes.decode_u8(8) + 1, 255]:
			var tampered: PackedByteArray = bytes.duplicate()
			tampered.encode_u8(8, wrong_len)
			assert_null(NetMessages.EntityEvent.decode(tampered),
					"evento %d con len %d declarado" % [sample.event, wrong_len])
		var resized: PackedByteArray = bytes.duplicate()
		resized.resize(bytes.size() + 1)
		resized.encode_u8(8, bytes.decode_u8(8) + 1)
		assert_null(NetMessages.EntityEvent.decode(resized),
				"evento %d con len y tamaño coherentes pero más largo que su formato" % sample.event)
		var shorter: PackedByteArray = bytes.slice(0, bytes.size() - 1)
		shorter.encode_u8(8, bytes.decode_u8(8) - 1)
		assert_null(NetMessages.EntityEvent.decode(shorter),
				"evento %d más corto que su formato" % sample.event)
	# El 12 sigue sin existir.
	var unknown: PackedByteArray = _new_events()[0].encode()
	unknown.encode_u8(7, 12)
	assert_null(NetMessages.EntityEvent.decode(unknown), "evento 12")


func test_hit_flags_5_and_6_and_sources_in_the_old_events() -> void:
	var flags: int = NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED | NetMessages.EntityEvent.HIT_FLAG_DOWNED \
			| NetMessages.EntityEvent.HIT_FLAG_LETHAL
	var arrow_shot: int = CombatSource.make(CombatSource.Kind.ATTACK, CombatCatalog.attack_id(&"bow_quick"))
	var hit: NetMessages.EntityEvent = NetMessages.EntityEvent.hit(321, 5, 654, 60,
			DamageFormula.DamageType.PIERCE, flags, arrow_shot)
	var bytes: PackedByteArray = hit.encode()
	assert_eq(bytes.size(), 17, "HIT: 17 B, sin cambios de tamaño")
	assert_eq(bytes.decode_u8(14), 0b1110000, "u8 flags en 14: bits 4, 5 y 6")
	var back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
	if assert_not_null(back, "decode del HIT"):
		assert_true(back.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED), "interrumpido")
		assert_true(back.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_DOWNED), "derriba")
		assert_false(back.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "no bloqueado")
		assert_eq(back.get_source(), arrow_shot, "la fuente")
	# Los ataques de la fase 3 conservan su número: la fuente de un ataque es su id.
	var light: int = CombatCatalog.attack_id(&"sword_light_1")
	assert_eq(CombatSource.make(CombatSource.Kind.ATTACK, light), light, "fuente de un ataque = su id")
	# Cada clase de fuente sobrevive a cada evento que la lleva.
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
			if assert_not_null(event_back, "evento %d con la fuente 0x%04X" % [event.event, source]):
				assert_eq(event_back.get_source(), source, "evento %d: fuente 0x%04X" % [event.event, source])
				assert_eq(CombatSource.kind_of(event_back.get_source()), CombatSource.kind_of(source),
						"evento %d: clase" % event.event)
				assert_eq(CombatSource.id_of(event_back.get_source()), CombatSource.id_of(source),
						"evento %d: id" % event.event)
	assert_eq(CombatSource.kind_of(CombatSource.EXECUTE), CombatSource.Kind.SPECIAL, "el remate es especial")


# --- Bits 3 del registro y del estado -----------------------------------------------------------

func test_record_flag_bit_3_is_the_active_second_slot() -> void:
	var state := PlayerState.new()
	state.grounded = true
	state.combat.alt_weapon_id = CombatCatalog.weapon_id(&"bow")
	var first: EntityRecord = EntityRecord.from_state(7, NetProtocol.EntityKind.PLAYER, state, 2)
	assert_false(first.is_second_slot(), "con la ranura 1 activa, bit 3 a 0")
	assert_eq(first.flags, EntityRecord.FLAG_GROUNDED | (2 << EntityRecord.TELEPORT_SHIFT), "suelo y contador")
	state.combat.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	var second: EntityRecord = EntityRecord.from_state(7, NetProtocol.EntityKind.PLAYER, state, 2)
	assert_true(second.is_second_slot(), "con la ranura 2 activa, bit 3 a 1")
	assert_true(second.is_grounded(), "el suelo no cambia")
	assert_eq(second.get_teleport_counter(), 2, "ni el contador de teletransporte")
	var bytes := PackedByteArray()
	second.encode_into(bytes, 0)
	assert_eq(bytes.decode_u8(18) & 0b1000, 0b1000, "u8 flags en 18: bit 3")
	var back: EntityRecord = EntityRecord.decode_from(bytes, 0, NetProtocol.EntityKind.PLAYER)
	if assert_not_null(back, "decode del registro"):
		assert_true(back.is_second_slot(), "el bit 3 viaja")
		assert_eq(back.flags & EntityRecord.HISTORY_FLAGS_MASK, second.flags & 0b111,
				"lo que toma el historial no lleva el bit 3")
	# El servidor escribe el registro directamente desde el personaje.
	var character := PlayerCharacter.new()
	character.grounded = true
	var direct := PackedByteArray()
	EntityRecord.encode_character(direct, 0, 7, character, 1, 0, 255)
	assert_eq(direct.decode_u8(18) & EntityRecord.FLAG_SECOND_SLOT, 0, "personaje con la ranura 1")
	character.combat.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	EntityRecord.encode_character(direct, 0, 7, character, 1, 0, 255)
	assert_eq(direct.decode_u8(18), EntityRecord.FLAG_SECOND_SLOT | EntityRecord.FLAG_GROUNDED
			| (1 << EntityRecord.TELEPORT_SHIFT), "personaje con la ranura 2: bit 3 con el suelo y el contador")
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
	assert_eq(extra_offset, 124, "el bloque extra empieza en 124 con el estado de 111 B")
	assert_eq(bytes.decode_u16(extra_offset), 250, "u16 health: la vida de derribado")
	assert_eq(bytes.decode_u16(extra_offset + 2), 400, "u16 max_health: la de derribado")
	assert_eq(bytes.decode_u8(extra_offset + 4), 0b1001, "u8 status: bit 3 derribado y bit 0 en combate")
	var back: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
	if assert_not_null(back, "decode"):
		assert_true(back.is_downed(), "derribado")
		assert_false(back.is_dead(), "no muerto")
		assert_true(back.is_in_combat(), "en combate")
		assert_eq(back.health, 250, "vida de derribado")
		assert_eq(back.max_health, 400, "máximo de derribado")
	var dead := NetMessages.Snapshot.new()
	dead.own_state = PlayerState.new()
	dead.max_health = 1000
	dead.status = NetMessages.STATUS_DEAD
	var dead_back: NetMessages.Snapshot = NetMessages.Snapshot.decode(dead.encode())
	if assert_not_null(dead_back, "un muerto"):
		assert_false(dead_back.is_downed(), "un muerto no está derribado")
		assert_true(dead_back.is_dead(), "está muerto")


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
	assert_eq(bytes.size(), 10 + 111 + 1 + 3, "SPAWN de jugador: 10 B + 111 B de estado + nombre")
	var back: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if assert_not_null(back, "decode") and assert_not_null(back.state, "con estado"):
		assert_true(back.state.equals_exact(state), "el estado de 111 B llega exacto")
		assert_eq(back.state.combat.alt_weapon_id, combat.alt_weapon_id, "la pareja de armas")
		assert_true(back.state.combat.is_second_slot(), "y la ranura activa")
		assert_true(EntityRecord.from_state(12, back.kind, back.state, 0).is_second_slot(),
				"el remoto saca el bit 3 de su primera muestra del SPAWN")


# --- Malformados y fuzz -------------------------------------------------------------------------

func test_malformed_v6_messages_return_null() -> void:
	var samples: Array = _samples()
	var decoders: Array[Callable] = _all_decoders()
	for entry: Array in samples:
		var label: String = entry[0]
		var bytes: PackedByteArray = entry[1]
		var decoder: Callable = entry[2]
		assert_not_null(decoder.call(bytes), "%s: el mensaje válido se decodifica" % label)
		for length: int in bytes.size():
			if decoder.call(bytes.slice(0, length)) != null:
				fail("%s truncado a %d de %d B debería ser null" % [label, length, bytes.size()])
				break
		for extra: int in [1, 2, 20]:
			var longer: PackedByteArray = bytes.duplicate()
			longer.resize(bytes.size() + extra)
			if decoder.call(longer) != null:
				fail("%s con %d B de sobra debería ser null" % [label, extra])
		var wrong: PackedByteArray = bytes.duplicate()
		wrong[0] = 0x7F
		assert_null(decoder.call(wrong), "%s con el byte 0 cambiado" % label)
		for other: Callable in decoders:
			if other != decoder and other.call(bytes) != null:
				fail("%s lo decodificó otro decodificador" % label)
	for decoder: Callable in decoders:
		assert_null(decoder.call(PackedByteArray()), "búfer vacío")
		assert_null(decoder.call(PackedByteArray([0])), "un solo byte nulo")


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
			# Un tipo conocido seguido de bytes al azar.
			var length: int = rng.randi_range(1, 60)
			bytes.resize(length)
			for j: int in length:
				bytes[j] = rng.randi() & 0xFF
			bytes[0] = type_bytes[rng.randi() % type_bytes.size()]
		elif mode == 2:
			# Un mensaje de los ejemplos con unos pocos bytes cambiados, recortado o ampliado.
			bytes = (samples[rng.randi() % samples.size()][1] as PackedByteArray).duplicate()
			for _k: int in rng.randi_range(0, 3):
				bytes[rng.randi() % bytes.size()] = rng.randi() & 0xFF
			var roll: float = rng.randf()
			if roll < 0.2:
				bytes.resize(rng.randi_range(0, bytes.size()))
			elif roll < 0.3:
				bytes.append(rng.randi() & 0xFF)
		else:
			# Un ENTITY_EVENT nuevo o un SPAWN de proyectil con la cabecera bien y el resto al azar.
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
						assert_true(event.op == 1 or event.op == 2, "un STATUS decodificado trae op 1 o 2")
						assert_true(event.op == 2 or event.stacks > 0, "y uno aplicado, acumulaciones")
					NetMessages.EntityEvent.Kind.INTERACT:
						assert_true(event.op >= 1 and event.op <= 5, "un INTERACT decodificado trae op 1 a 5")
				if event.event >= NetMessages.EntityEvent.Kind.STATUS:
					assert_eq(event.encode(), bytes, "un ENTITY_EVENT nuevo decodificado se recodifica igual")
			elif result is NetMessages.EntitySpawn:
				var spawn: NetMessages.EntitySpawn = result
				if spawn.kind == NetProtocol.EntityKind.PROJECTILE:
					assert_false(spawn.is_yours, "un proyectil decodificado nunca es tuyo")
					assert_eq(spawn.projectile_flags & ~NetMessages.EntitySpawn.PROJECTILE_FLAGS_VALID, 0,
							"ni trae bits de proj_flags que no existen")
					# Los bits 60-63 de la posición no significan nada: se compara lo que se lee.
					var again: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(spawn.encode())
					if assert_not_null(again, "un proyectil decodificado se recodifica"):
						assert_true(_same_projectile(spawn, again), "y se vuelve a leer igual")
	assert_true(mutated_decoded > 100, "el fuzz llega hasta mensajes válidos (%d)" % mutated_decoded)
	assert_true(decoded_count >= mutated_decoded, "contadores coherentes")


# --- Utilidades -------------------------------------------------------------------------------

func _same_projectile(a: NetMessages.EntitySpawn, b: NetMessages.EntitySpawn) -> bool:
	return a.net_id == b.net_id and a.spawn_tick == b.spawn_tick and a.realm == b.realm \
			and a.owner_id == b.owner_id and a.projectile_def_id == b.projectile_def_id and a.source == b.source \
			and a.volley_index == b.volley_index and a.projectile_flags == b.projectile_flags \
			and a.origin == b.origin and a.velocity == b.velocity


func _projectile_spawn() -> NetMessages.EntitySpawn:
	return NetMessages.EntitySpawn.for_projectile(900, 5000, NetProtocol.Realm.VARDHEIM, 12,
			CombatCatalog.projectile_id(&"arrow"), CombatCatalog.attack_id(&"bow_quick"), 0, false,
			Vector3(10.0, 1.4, -3.0), Vector3(0.0, 2.0, 44.9))


## Un ejemplo de cada evento nuevo (7 a 11).
func _new_events() -> Array[NetMessages.EntityEvent]:
	var events: Array[NetMessages.EntityEvent] = [
		NetMessages.EntityEvent.status(1, 2, 3, NetMessages.EntityEvent.StatusOp.APPLIED, 4, 1, 300),
		NetMessages.EntityEvent.heal(1, 2, 0, 50, 0x8001),
		NetMessages.EntityEvent.loadout(1, 2, 2, 3, 4, 0x32),
		NetMessages.EntityEvent.downed(1, 2, 3, 0x4002),
		NetMessages.EntityEvent.interact(1, 2, 3, NetMessages.EntityEvent.InteractOp.EXECUTE, 62),
	]
	return events


## [etiqueta, bytes válidos, decodificador] de cada mensaje nuevo y de otros cuyo decodificador comparte
## tipo con ellos.
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


# Un ENTITY_EVENT de los nuevos con su tamaño y longitud correctos y datos al azar, o un SPAWN de
# proyectil de 32 B con la cabecera bien y el resto al azar.
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
