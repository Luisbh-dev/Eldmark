extends TestCase
## Pruebas de los mensajes de grupo (SOC-06, docs/social.md sección 12.4): PARTY_INVITE, PARTY_KICK y
## PARTY_LEADER ([NetMessages.PartyTargetRequest]), PARTY_RESPONSE, PARTY_LEAVE, PARTY_INVITATION, PARTY_ROSTER y
## PARTY_STATUS, más [PartyRules] y las constantes de [NetProtocol]. Los offsets y tamaños son los del
## documento, escritos a mano; los corruptos, los truncados en cada longitud y el fuzz comprueban que nada
## registra errores del motor y que ningún mensaje pasa de [constant NetProtocol.MAX_PACKET_BYTES].

const FUZZ_BUFFERS: int = 6000
const FUZZ_SEED: int = 20261102


# --- Constantes -------------------------------------------------------------------------------

func test_constants() -> void:
	assert_eq(NetProtocol.MSG_PARTY_INVITE, 0x48, "PARTY_INVITE")
	assert_eq(NetProtocol.MSG_PARTY_RESPONSE, 0x49, "PARTY_RESPONSE")
	assert_eq(NetProtocol.MSG_PARTY_LEAVE, 0x4A, "PARTY_LEAVE")
	assert_eq(NetProtocol.MSG_PARTY_KICK, 0x4B, "PARTY_KICK")
	assert_eq(NetProtocol.MSG_PARTY_LEADER, 0x4C, "PARTY_LEADER")
	assert_eq(NetProtocol.MSG_PARTY_INVITATION, 0x4D, "PARTY_INVITATION")
	assert_eq(NetProtocol.MSG_PARTY_ROSTER, 0x4E, "PARTY_ROSTER")
	assert_eq(NetProtocol.MSG_PARTY_STATUS, 0x4F, "PARTY_STATUS")
	assert_eq(NetProtocol.PARTY_MAX_SIZE, 5, "un grupo es de 5")
	for message_type: int in range(0x48, 0x50):
		assert_eq(NetProtocol.channel_for_type(message_type), NetProtocol.CH_RELIABLE,
				"0x%02X va por el canal fiable" % message_type)
		assert_true(SocialService.handles_type(message_type), "0x%02X es del servicio social" % message_type)
	assert_true(NetProtocol.PROTOCOL_VERSION >= 5, "protocolo 5")
	assert_eq(PartyRules.INVITE_TTL_TICKS, 60 * 60, "60 s")
	assert_eq(PartyRules.STATUS_INTERVAL_TICKS * 2, 60, "2 Hz")
	assert_eq(PartyRules.MAX_PENDING_PER_INVITER, 5, "5 pendientes")
	assert_eq(PartyRules.quantize_stamina(1000, 1000), 255, "resistencia llena")
	assert_eq(PartyRules.quantize_stamina(0, 1000), 0, "vacía")
	assert_eq(PartyRules.quantize_stamina(500, 1000), 128, "a la mitad")
	assert_eq(PartyRules.quantize_stamina(5, 0), 0, "sin máximo")
	assert_near(PartyRules.stamina_fraction(255), 1.0, 1e-6, "fracción")
	assert_near(PartyRules.health_fraction(0), 0.0, 1e-6, "vida")


# --- PartyTargetRequest y PartyResponse -------------------------------------------------------

func test_target_requests_layout_and_round_trip() -> void:
	for message_type: int in [NetProtocol.MSG_PARTY_INVITE, NetProtocol.MSG_PARTY_KICK,
			NetProtocol.MSG_PARTY_LEADER]:
		var request := NetMessages.PartyTargetRequest.make(message_type, "Álvaro")
		var bytes: PackedByteArray = request.encode()
		var name_size: int = "Álvaro".to_utf8_buffer().size()
		assert_eq(bytes.size(), 2 + name_size, "2 B + nombre")
		assert_eq(bytes[0], message_type, "u8 type")
		assert_eq(bytes[1], name_size, "u8 name_len")
		assert_eq(bytes.slice(2).get_string_from_utf8(), "Álvaro", "nombre en UTF-8")
		var decoded: NetMessages.PartyTargetRequest = NetMessages.PartyTargetRequest.decode(bytes)
		if assert_not_null(decoded, "se decodifica"):
			assert_eq(decoded.type, message_type, "tipo")
			assert_eq(decoded.target, "Álvaro", "nombre")
	# El nombre se recorta a los límites sin partir caracteres.
	var long_request := NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_INVITE, "Ñ".repeat(40))
	var long_bytes: PackedByteArray = long_request.encode()
	assert_true(long_bytes.size() <= 2 + NetProtocol.MAX_NAME_BYTES, "como mucho 50 B")
	assert_eq(NetMessages.PartyTargetRequest.decode(long_bytes).target.length(), NetProtocol.MAX_NAME_CHARS,
			"24 caracteres")


func test_target_requests_malformed_are_null() -> void:
	var valid: PackedByteArray = NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_KICK, "Ana").encode()
	assert_not_null(NetMessages.PartyTargetRequest.decode(valid), "el de partida vale")
	for cut: int in valid.size():
		assert_null(NetMessages.PartyTargetRequest.decode(valid.slice(0, cut)), "recortado a %d B" % cut)
	var longer: PackedByteArray = valid.duplicate()
	longer.append(0x61)
	assert_null(NetMessages.PartyTargetRequest.decode(longer), "un byte de más")
	for wrong_type: int in [0x40, 0x49, 0x4A, 0x4D, 0x4E, 0x00, 0xFF]:
		var wrong: PackedByteArray = valid.duplicate()
		wrong[0] = wrong_type
		assert_null(NetMessages.PartyTargetRequest.decode(wrong), "tipo 0x%02X" % wrong_type)
	assert_null(NetMessages.PartyTargetRequest.decode(PackedByteArray([0x48, 0])), "nombre vacío")
	var utf8: PackedByteArray = valid.duplicate()
	utf8[2] = 0xFF
	assert_null(NetMessages.PartyTargetRequest.decode(utf8), "UTF-8 inválido")
	var nul: PackedByteArray = valid.duplicate()
	nul[3] = 0
	assert_null(NetMessages.PartyTargetRequest.decode(nul), "byte nulo")
	var long_name := PackedByteArray([0x48, 49])
	for _i: int in 49:
		long_name.append(0x61)
	assert_null(NetMessages.PartyTargetRequest.decode(long_name), "49 B de nombre")
	var many_chars := PackedByteArray([0x48, 25])
	for _i: int in 25:
		many_chars.append(0x61)
	assert_null(NetMessages.PartyTargetRequest.decode(many_chars), "25 caracteres")


func test_response_layout_round_trip_and_malformed() -> void:
	var response := NetMessages.PartyResponse.new()
	response.accept = true
	response.inviter = "Ana"
	var bytes: PackedByteArray = response.encode()
	assert_eq(bytes, PackedByteArray([0x49, 1, 3, 0x41, 0x6E, 0x61]), "bytes a mano: tipo, accept, longitud y nombre")
	var decoded: NetMessages.PartyResponse = NetMessages.PartyResponse.decode(bytes)
	assert_true(decoded.accept, "aceptar")
	assert_eq(decoded.inviter, "Ana", "invitador")
	response.accept = false
	assert_false(NetMessages.PartyResponse.decode(response.encode()).accept, "rechazar")
	for cut: int in bytes.size():
		assert_null(NetMessages.PartyResponse.decode(bytes.slice(0, cut)), "recortado a %d B" % cut)
	var bad_accept: PackedByteArray = bytes.duplicate()
	bad_accept[1] = 2
	assert_null(NetMessages.PartyResponse.decode(bad_accept), "accept 2")
	assert_null(NetMessages.PartyResponse.decode(PackedByteArray([0x49, 1, 0])), "nombre vacío")
	var longer: PackedByteArray = bytes.duplicate()
	longer.append(0x61)
	assert_null(NetMessages.PartyResponse.decode(longer), "un byte de más")


func test_leave_is_one_byte() -> void:
	var bytes: PackedByteArray = NetMessages.PartyLeave.new().encode()
	assert_eq(bytes, PackedByteArray([0x4A]), "1 B")
	assert_not_null(NetMessages.PartyLeave.decode(bytes), "se decodifica")
	assert_null(NetMessages.PartyLeave.decode(PackedByteArray([0x4A, 0])), "2 B no")
	assert_null(NetMessages.PartyLeave.decode(PackedByteArray([0x4B])), "otro tipo")
	assert_null(NetMessages.PartyLeave.decode(PackedByteArray()), "vacío")


# --- PartyInvitation --------------------------------------------------------------------------

func test_invitation_layout_round_trip_and_malformed() -> void:
	var invitation := NetMessages.PartyInvitation.new()
	invitation.state = NetMessages.PartyInvitation.State.OFFERED
	invitation.tick = 0x01020304
	invitation.inviter = "Ana"
	var bytes: PackedByteArray = invitation.encode()
	assert_eq(bytes.size(), 7 + 3, "7 B + nombre")
	assert_eq(bytes[0], 0x4D, "u8 type")
	assert_eq(bytes[1], 0, "u8 state")
	assert_eq(bytes.decode_u32(2), 0x01020304, "u32 tick")
	assert_eq(bytes[6], 3, "u8 name_len")
	assert_eq(bytes.slice(7).get_string_from_utf8(), "Ana", "nombre")
	for state: int in [0, 1, 2]:
		invitation.state = state
		var decoded: NetMessages.PartyInvitation = NetMessages.PartyInvitation.decode(invitation.encode())
		assert_eq(decoded.state, state, "estado %d" % state)
		assert_eq(decoded.tick, 0x01020304, "tick")
		assert_eq(decoded.inviter, "Ana", "invitador")
	for cut: int in bytes.size():
		assert_null(NetMessages.PartyInvitation.decode(bytes.slice(0, cut)), "recortado a %d B" % cut)
	var bad_state: PackedByteArray = bytes.duplicate()
	bad_state[1] = 3
	assert_null(NetMessages.PartyInvitation.decode(bad_state), "estado 3")
	var empty_name: PackedByteArray = bytes.slice(0, 6)
	empty_name.append(0)
	assert_null(NetMessages.PartyInvitation.decode(empty_name), "nombre vacío")
	var longer: PackedByteArray = bytes.duplicate()
	longer.append(0x61)
	assert_null(NetMessages.PartyInvitation.decode(longer), "un byte de más")


# --- PartyRoster ------------------------------------------------------------------------------

func _roster(count: int, leader: int) -> NetMessages.PartyRoster:
	var roster := NetMessages.PartyRoster.new()
	roster.leader_index = leader
	for i: int in count:
		roster.members.append(NetMessages.PartyRoster.Member.make(1000 + i, "Miembro%s" % char(97 + i)))
	return roster


func test_roster_layout_round_trip_and_maximum_size() -> void:
	var roster: NetMessages.PartyRoster = _roster(3, 1)
	var bytes: PackedByteArray = roster.encode()
	assert_eq(bytes[0], 0x4E, "u8 type")
	assert_eq(bytes[1], 3, "u8 count")
	assert_eq(bytes[2], 1, "u8 leader_index")
	assert_eq(bytes.decode_u16(3), 1000, "u16 net_id del primero")
	assert_eq(bytes[5], 8, "u8 name_len del primero")
	assert_eq(bytes.slice(6, 14).get_string_from_utf8(), "Miembroa", "su nombre")
	assert_eq(bytes.size(), 3 + 3 * (3 + 8), "3 B + 3 B y nombre por miembro")
	var decoded: NetMessages.PartyRoster = NetMessages.PartyRoster.decode(bytes)
	if assert_not_null(decoded, "se decodifica"):
		assert_eq(decoded.members.size(), 3, "tres")
		assert_eq(decoded.leader_index, 1, "líder")
		assert_eq(decoded.get_leader_id(), 1001, "net_id del líder")
		assert_eq(decoded.members[2].display_name, "Miembroc", "tercero")
		assert_eq(decoded.members[2].net_id, 1002, "net_id")
	# Vacía: ya no hay grupo.
	var empty_bytes: PackedByteArray = NetMessages.PartyRoster.new().encode()
	assert_eq(empty_bytes, PackedByteArray([0x4E, 0, 0]), "3 B")
	var empty: NetMessages.PartyRoster = NetMessages.PartyRoster.decode(empty_bytes)
	assert_true(empty.is_empty(), "vacía")
	assert_eq(empty.get_leader_id(), 0, "sin líder")
	# Máximo: cinco miembros con nombres de 48 B.
	var full := NetMessages.PartyRoster.new()
	for i: int in NetProtocol.PARTY_MAX_SIZE:
		full.members.append(NetMessages.PartyRoster.Member.make(i + 1, "Ñ".repeat(24)))
	var full_bytes: PackedByteArray = full.encode()
	assert_eq(full_bytes.size(), 3 + 5 * (3 + 48), "el máximo: 258 B")
	assert_true(full_bytes.size() <= NetProtocol.MAX_PACKET_BYTES, "cabe en un paquete")
	assert_not_null(NetMessages.PartyRoster.decode(full_bytes), "el máximo se decodifica")
	# Más de cinco: encode se queda con cinco.
	var over: NetMessages.PartyRoster = _roster(7, 0)
	assert_eq(NetMessages.PartyRoster.decode(over.encode()).members.size(), 5, "encode recorta a 5")


func test_roster_malformed_is_null() -> void:
	var valid: PackedByteArray = _roster(3, 2).encode()
	assert_not_null(NetMessages.PartyRoster.decode(valid), "el de partida vale")
	for cut: int in valid.size():
		assert_null(NetMessages.PartyRoster.decode(valid.slice(0, cut)), "recortado a %d B" % cut)
	var longer: PackedByteArray = valid.duplicate()
	longer.append(0)
	assert_null(NetMessages.PartyRoster.decode(longer), "un byte de más")
	var six: PackedByteArray = valid.duplicate()
	six[1] = 6
	assert_null(NetMessages.PartyRoster.decode(six), "seis miembros")
	var bad_leader: PackedByteArray = valid.duplicate()
	bad_leader[2] = 3
	assert_null(NetMessages.PartyRoster.decode(bad_leader), "líder fuera de la lista")
	assert_null(NetMessages.PartyRoster.decode(PackedByteArray([0x4E, 0, 1])), "sin miembros y con líder")
	var empty_name: PackedByteArray = PackedByteArray([0x4E, 1, 0, 1, 0, 0])
	assert_null(NetMessages.PartyRoster.decode(empty_name), "nombre vacío")
	var duplicate := PackedByteArray([0x4E, 2, 0, 7, 0, 1, 0x41, 7, 0, 1, 0x42])
	assert_null(NetMessages.PartyRoster.decode(duplicate), "net_id repetido")
	var utf8: PackedByteArray = valid.duplicate()
	utf8[6] = 0xFF
	assert_null(NetMessages.PartyRoster.decode(utf8), "UTF-8 inválido")
	var long_name: PackedByteArray = PackedByteArray([0x4E, 1, 0, 1, 0, 49])
	for _i: int in 49:
		long_name.append(0x61)
	assert_null(NetMessages.PartyRoster.decode(long_name), "nombre de 49 B")


# --- PartyStatus ------------------------------------------------------------------------------

func _status(count: int) -> NetMessages.PartyStatus:
	var status := NetMessages.PartyStatus.new()
	for i: int in count:
		status.members.append(NetMessages.PartyStatus.MemberStatus.make(2000 + i, 255 - i * 10, 100 + i,
				NetMessages.STATUS_IN_COMBAT if i % 2 == 0 else 0, Vector3(10.5 * i, 2.0, -250.25 * i)))
	return status


func test_status_layout_round_trip_and_size() -> void:
	var status: NetMessages.PartyStatus = _status(2)
	var bytes: PackedByteArray = status.encode()
	assert_eq(bytes.size(), 2 + 17 * 2, "2 B + 17 B por miembro")
	assert_eq(bytes[0], 0x4F, "u8 type")
	assert_eq(bytes[1], 2, "u8 count")
	assert_eq(bytes.decode_u16(2), 2000, "u16 net_id")
	assert_eq(bytes[4], 255, "u8 health_q")
	assert_eq(bytes[5], 100, "u8 stamina_q")
	assert_eq(bytes[6], NetMessages.STATUS_IN_COMBAT, "u8 status")
	assert_near(bytes.decode_float(7), 0.0, 1e-6, "f32 x")
	assert_near(bytes.decode_float(11), 2.0, 1e-6, "f32 y")
	assert_near(bytes.decode_float(15), 0.0, 1e-6, "f32 z")
	assert_near(bytes.decode_float(2 + 17 + 5), 10.5, 1e-6, "f32 x del segundo, 17 B más allá")
	var decoded: NetMessages.PartyStatus = NetMessages.PartyStatus.decode(bytes)
	if not assert_not_null(decoded, "se decodifica"):
		return
	assert_eq(decoded.members.size(), 2, "dos")
	assert_eq(decoded.members[1].net_id, 2001, "net_id del segundo")
	assert_eq(decoded.members[1].health_q, 245, "vida")
	assert_eq(decoded.members[1].stamina_q, 101, "resistencia")
	assert_eq(decoded.members[1].status, 0, "estado")
	assert_vec_near(decoded.members[1].position, Vector3(10.5, 2.0, -250.25), 1e-4, "posición")
	var full: PackedByteArray = _status(NetProtocol.PARTY_MAX_SIZE).encode()
	assert_eq(full.size(), 2 + 17 * 5, "el máximo: 87 B")
	assert_true(full.size() <= NetProtocol.MAX_PACKET_BYTES, "cabe en un paquete")
	assert_eq(NetMessages.PartyStatus.decode(_status(7).encode()).members.size(), 5, "encode recorta a 5")
	assert_true(NetMessages.PartyStatus.MemberStatus.make(1, 0, 0, NetMessages.STATUS_DEAD, Vector3.ZERO).is_dead(),
			"is_dead")


func test_status_malformed_is_null() -> void:
	var valid: PackedByteArray = _status(3).encode()
	assert_not_null(NetMessages.PartyStatus.decode(valid), "el de partida vale")
	for cut: int in valid.size():
		assert_null(NetMessages.PartyStatus.decode(valid.slice(0, cut)), "recortado a %d B" % cut)
	var longer: PackedByteArray = valid.duplicate()
	longer.append(0)
	assert_null(NetMessages.PartyStatus.decode(longer), "un byte de más")
	var six: PackedByteArray = valid.duplicate()
	six[1] = 6
	assert_null(NetMessages.PartyStatus.decode(six), "seis miembros")
	var bad_status: PackedByteArray = valid.duplicate()
	bad_status[6] = 0b1000
	assert_null(NetMessages.PartyStatus.decode(bad_status), "un bit de estado desconocido")
	var nan_position: PackedByteArray = valid.duplicate()
	nan_position.encode_float(7, NAN)
	assert_null(NetMessages.PartyStatus.decode(nan_position), "una posición NaN")
	var infinite: PackedByteArray = valid.duplicate()
	infinite.encode_float(11, INF)
	assert_null(NetMessages.PartyStatus.decode(infinite), "una posición infinita")
	var duplicate: PackedByteArray = valid.duplicate()
	duplicate.encode_u16(2 + 17, 2000)
	assert_null(NetMessages.PartyStatus.decode(duplicate), "net_id repetido")


# --- Fuzz -------------------------------------------------------------------------------------

func test_fuzz_random_buffers_never_error() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = FUZZ_SEED
	var samples: Array[PackedByteArray] = [
		NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_INVITE, "Ana").encode(),
		NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_KICK, "Bruno").encode(),
		NetMessages.PartyLeave.new().encode(),
		_roster(4, 2).encode(),
		_status(4).encode(),
		PackedByteArray([0x49, 1, 3, 0x41, 0x6E, 0x61]),
	]
	var invitation := NetMessages.PartyInvitation.new()
	invitation.inviter = "Ana"
	samples.append(invitation.encode())
	var decoders: Array[Callable] = [NetMessages.PartyTargetRequest.decode, NetMessages.PartyResponse.decode,
			NetMessages.PartyLeave.decode, NetMessages.PartyInvitation.decode, NetMessages.PartyRoster.decode,
			NetMessages.PartyStatus.decode]
	var decoded_count: int = 0
	for i: int in FUZZ_BUFFERS:
		var bytes := PackedByteArray()
		var mode: int = i % 3
		if mode == 0:
			bytes.resize(rng.randi_range(0, 60 if rng.randf() < 0.7 else 1300))
			for j: int in bytes.size():
				bytes[j] = rng.randi() & 0xFF
		elif mode == 1:
			bytes.resize(rng.randi_range(1, 120))
			for j: int in bytes.size():
				bytes[j] = rng.randi() & 0xFF
			bytes[0] = 0x48 + rng.randi() % 8
		else:
			bytes = samples[rng.randi() % samples.size()].duplicate()
			for _k: int in rng.randi_range(0, 3):
				bytes[rng.randi() % bytes.size()] = rng.randi() & 0xFF
			var roll: float = rng.randf()
			if roll < 0.2:
				bytes.resize(rng.randi_range(0, bytes.size()))
			elif roll < 0.3:
				bytes.append(rng.randi() & 0xFF)
		for decoder: Callable in decoders:
			var result: Variant = decoder.call(bytes)
			if result != null:
				decoded_count += 1
				if result is NetMessages.PartyRoster:
					assert_true((result as NetMessages.PartyRoster).members.size() <= 5, "a lo sumo 5 miembros")
				elif result is NetMessages.PartyStatus:
					for member: NetMessages.PartyStatus.MemberStatus in (result as NetMessages.PartyStatus).members:
						assert_true(member.position.is_finite(), "posiciones finitas")
	assert_true(decoded_count > 50, "el fuzz llega hasta mensajes válidos (%d)" % decoded_count)
