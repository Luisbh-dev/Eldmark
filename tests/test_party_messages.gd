extends TestCase
## Tests of the party messages (SOC-06, docs/social.md section 12.4): PARTY_INVITE, PARTY_KICK and
## PARTY_LEADER ([NetMessages.PartyTargetRequest]), PARTY_RESPONSE, PARTY_LEAVE, PARTY_INVITATION,
## PARTY_ROSTER and PARTY_STATUS, plus [PartyRules] and the [NetProtocol] constants. The offsets and
## sizes are the ones from the document, written by hand; the corrupt ones, those truncated at every
## length and the fuzz check that nothing logs engine errors and that no message exceeds
## [constant NetProtocol.MAX_PACKET_BYTES].

const FUZZ_BUFFERS: int = 6000
const FUZZ_SEED: int = 20261102


# --- Constants --------------------------------------------------------------------------------

func test_constants() -> void:
	assert_eq(NetProtocol.MSG_PARTY_INVITE, 0x48, "PARTY_INVITE")
	assert_eq(NetProtocol.MSG_PARTY_RESPONSE, 0x49, "PARTY_RESPONSE")
	assert_eq(NetProtocol.MSG_PARTY_LEAVE, 0x4A, "PARTY_LEAVE")
	assert_eq(NetProtocol.MSG_PARTY_KICK, 0x4B, "PARTY_KICK")
	assert_eq(NetProtocol.MSG_PARTY_LEADER, 0x4C, "PARTY_LEADER")
	assert_eq(NetProtocol.MSG_PARTY_INVITATION, 0x4D, "PARTY_INVITATION")
	assert_eq(NetProtocol.MSG_PARTY_ROSTER, 0x4E, "PARTY_ROSTER")
	assert_eq(NetProtocol.MSG_PARTY_STATUS, 0x4F, "PARTY_STATUS")
	assert_eq(NetProtocol.PARTY_MAX_SIZE, 5, "a party is 5")
	for message_type: int in range(0x48, 0x50):
		assert_eq(NetProtocol.channel_for_type(message_type), NetProtocol.CH_RELIABLE,
				"0x%02X goes over the reliable channel" % message_type)
		assert_true(SocialService.handles_type(message_type), "0x%02X belongs to the social service" % message_type)
	assert_true(NetProtocol.PROTOCOL_VERSION >= 5, "protocol 5")
	assert_eq(PartyRules.INVITE_TTL_TICKS, 60 * 60, "60 s")
	assert_eq(PartyRules.STATUS_INTERVAL_TICKS * 2, 60, "2 Hz")
	assert_eq(PartyRules.MAX_PENDING_PER_INVITER, 5, "5 pending")
	assert_eq(PartyRules.quantize_stamina(1000, 1000), 255, "full stamina")
	assert_eq(PartyRules.quantize_stamina(0, 1000), 0, "empty")
	assert_eq(PartyRules.quantize_stamina(500, 1000), 128, "at half")
	assert_eq(PartyRules.quantize_stamina(5, 0), 0, "without maximum")
	assert_near(PartyRules.stamina_fraction(255), 1.0, 1e-6, "fraction")
	assert_near(PartyRules.health_fraction(0), 0.0, 1e-6, "health")


# --- PartyTargetRequest and PartyResponse -----------------------------------------------------

func test_target_requests_layout_and_round_trip() -> void:
	for message_type: int in [NetProtocol.MSG_PARTY_INVITE, NetProtocol.MSG_PARTY_KICK,
			NetProtocol.MSG_PARTY_LEADER]:
		var request := NetMessages.PartyTargetRequest.make(message_type, "Álvaro")
		var bytes: PackedByteArray = request.encode()
		var name_size: int = "Álvaro".to_utf8_buffer().size()
		assert_eq(bytes.size(), 2 + name_size, "2 B + name")
		assert_eq(bytes[0], message_type, "u8 type")
		assert_eq(bytes[1], name_size, "u8 name_len")
		assert_eq(bytes.slice(2).get_string_from_utf8(), "Álvaro", "UTF-8 name")
		var decoded: NetMessages.PartyTargetRequest = NetMessages.PartyTargetRequest.decode(bytes)
		if assert_not_null(decoded, "it is decoded"):
			assert_eq(decoded.type, message_type, "type")
			assert_eq(decoded.target, "Álvaro", "name")
	# The name is trimmed to the limits without splitting characters.
	var long_request := NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_INVITE, "Ñ".repeat(40))
	var long_bytes: PackedByteArray = long_request.encode()
	assert_true(long_bytes.size() <= 2 + NetProtocol.MAX_NAME_BYTES, "at most 50 B")
	assert_eq(NetMessages.PartyTargetRequest.decode(long_bytes).target.length(), NetProtocol.MAX_NAME_CHARS,
			"24 characters")


func test_target_requests_malformed_are_null() -> void:
	var valid: PackedByteArray = NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_KICK, "Ana").encode()
	assert_not_null(NetMessages.PartyTargetRequest.decode(valid), "the starting one is valid")
	for cut: int in valid.size():
		assert_null(NetMessages.PartyTargetRequest.decode(valid.slice(0, cut)), "trimmed to %d B" % cut)
	var longer: PackedByteArray = valid.duplicate()
	longer.append(0x61)
	assert_null(NetMessages.PartyTargetRequest.decode(longer), "one extra byte")
	for wrong_type: int in [0x40, 0x49, 0x4A, 0x4D, 0x4E, 0x00, 0xFF]:
		var wrong: PackedByteArray = valid.duplicate()
		wrong[0] = wrong_type
		assert_null(NetMessages.PartyTargetRequest.decode(wrong), "type 0x%02X" % wrong_type)
	assert_null(NetMessages.PartyTargetRequest.decode(PackedByteArray([0x48, 0])), "empty name")
	# A lone UTF-8 BOM: three bytes that get_string_from_utf8 reads as an empty string.
	assert_null(NetMessages.PartyTargetRequest.decode(PackedByteArray([0x48, 3, 0xEF, 0xBB, 0xBF])),
			"name that reads as empty (only a BOM)")
	var bom_then_name: NetMessages.PartyTargetRequest = NetMessages.PartyTargetRequest.decode(
			PackedByteArray([0x48, 8, 0xEF, 0xBB, 0xBF, 0x42, 0x72, 0x75, 0x6E, 0x6F]))
	if assert_not_null(bom_then_name, "a BOM in front of a name does get decoded"):
		assert_eq(bom_then_name.target, "Bruno", "and stays in the name")
	var utf8: PackedByteArray = valid.duplicate()
	utf8[2] = 0xFF
	assert_null(NetMessages.PartyTargetRequest.decode(utf8), "invalid UTF-8")
	var nul: PackedByteArray = valid.duplicate()
	nul[3] = 0
	assert_null(NetMessages.PartyTargetRequest.decode(nul), "null byte")
	var long_name := PackedByteArray([0x48, 49])
	for _i: int in 49:
		long_name.append(0x61)
	assert_null(NetMessages.PartyTargetRequest.decode(long_name), "49 B of name")
	var many_chars := PackedByteArray([0x48, 25])
	for _i: int in 25:
		many_chars.append(0x61)
	assert_null(NetMessages.PartyTargetRequest.decode(many_chars), "25 characters")


func test_response_layout_round_trip_and_malformed() -> void:
	var response := NetMessages.PartyResponse.new()
	response.accept = true
	response.inviter = "Ana"
	var bytes: PackedByteArray = response.encode()
	assert_eq(bytes, PackedByteArray([0x49, 1, 3, 0x41, 0x6E, 0x61]), "bytes by hand: type, accept, length and name")
	var decoded: NetMessages.PartyResponse = NetMessages.PartyResponse.decode(bytes)
	assert_true(decoded.accept, "accept")
	assert_eq(decoded.inviter, "Ana", "inviter")
	response.accept = false
	assert_false(NetMessages.PartyResponse.decode(response.encode()).accept, "decline")
	for cut: int in bytes.size():
		assert_null(NetMessages.PartyResponse.decode(bytes.slice(0, cut)), "trimmed to %d B" % cut)
	var bad_accept: PackedByteArray = bytes.duplicate()
	bad_accept[1] = 2
	assert_null(NetMessages.PartyResponse.decode(bad_accept), "accept 2")
	assert_null(NetMessages.PartyResponse.decode(PackedByteArray([0x49, 1, 0])), "empty name")
	assert_null(NetMessages.PartyResponse.decode(PackedByteArray([0x49, 1, 3, 0xEF, 0xBB, 0xBF])),
			"name that reads as empty (only a BOM)")
	var longer: PackedByteArray = bytes.duplicate()
	longer.append(0x61)
	assert_null(NetMessages.PartyResponse.decode(longer), "one extra byte")


func test_leave_is_one_byte() -> void:
	var bytes: PackedByteArray = NetMessages.PartyLeave.new().encode()
	assert_eq(bytes, PackedByteArray([0x4A]), "1 B")
	assert_not_null(NetMessages.PartyLeave.decode(bytes), "it is decoded")
	assert_null(NetMessages.PartyLeave.decode(PackedByteArray([0x4A, 0])), "2 B no")
	assert_null(NetMessages.PartyLeave.decode(PackedByteArray([0x4B])), "another type")
	assert_null(NetMessages.PartyLeave.decode(PackedByteArray()), "empty")


# --- PartyInvitation --------------------------------------------------------------------------

func test_invitation_layout_round_trip_and_malformed() -> void:
	var invitation := NetMessages.PartyInvitation.new()
	invitation.state = NetMessages.PartyInvitation.State.OFFERED
	invitation.tick = 0x01020304
	invitation.inviter = "Ana"
	var bytes: PackedByteArray = invitation.encode()
	assert_eq(bytes.size(), 7 + 3, "7 B + name")
	assert_eq(bytes[0], 0x4D, "u8 type")
	assert_eq(bytes[1], 0, "u8 state")
	assert_eq(bytes.decode_u32(2), 0x01020304, "u32 tick")
	assert_eq(bytes[6], 3, "u8 name_len")
	assert_eq(bytes.slice(7).get_string_from_utf8(), "Ana", "nombre")
	for state: int in [0, 1, 2]:
		invitation.state = state
		var decoded: NetMessages.PartyInvitation = NetMessages.PartyInvitation.decode(invitation.encode())
		assert_eq(decoded.state, state, "state %d" % state)
		assert_eq(decoded.tick, 0x01020304, "tick")
		assert_eq(decoded.inviter, "Ana", "inviter")
	for cut: int in bytes.size():
		assert_null(NetMessages.PartyInvitation.decode(bytes.slice(0, cut)), "trimmed to %d B" % cut)
	var bad_state: PackedByteArray = bytes.duplicate()
	bad_state[1] = 3
	assert_null(NetMessages.PartyInvitation.decode(bad_state), "state 3")
	var empty_name: PackedByteArray = bytes.slice(0, 6)
	empty_name.append(0)
	assert_null(NetMessages.PartyInvitation.decode(empty_name), "empty name")
	var bom_name: PackedByteArray = bytes.slice(0, 6)
	bom_name.append_array(PackedByteArray([3, 0xEF, 0xBB, 0xBF]))
	assert_null(NetMessages.PartyInvitation.decode(bom_name), "name that reads as empty (only a BOM)")
	var longer: PackedByteArray = bytes.duplicate()
	longer.append(0x61)
	assert_null(NetMessages.PartyInvitation.decode(longer), "one extra byte")


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
	assert_eq(bytes.decode_u16(3), 1000, "u16 net_id of the first")
	assert_eq(bytes[5], 8, "u8 name_len of the first")
	assert_eq(bytes.slice(6, 14).get_string_from_utf8(), "Miembroa", "its name")
	assert_eq(bytes.size(), 3 + 3 * (3 + 8), "3 B + 3 B and name per member")
	var decoded: NetMessages.PartyRoster = NetMessages.PartyRoster.decode(bytes)
	if assert_not_null(decoded, "it is decoded"):
		assert_eq(decoded.members.size(), 3, "three")
		assert_eq(decoded.leader_index, 1, "leader")
		assert_eq(decoded.get_leader_id(), 1001, "net_id of the leader")
		assert_eq(decoded.members[2].display_name, "Miembroc", "third")
		assert_eq(decoded.members[2].net_id, 1002, "net_id")
	# Empty: there is no party anymore.
	var empty_bytes: PackedByteArray = NetMessages.PartyRoster.new().encode()
	assert_eq(empty_bytes, PackedByteArray([0x4E, 0, 0]), "3 B")
	var empty: NetMessages.PartyRoster = NetMessages.PartyRoster.decode(empty_bytes)
	assert_true(empty.is_empty(), "empty")
	assert_eq(empty.get_leader_id(), 0, "without a leader")
	# Maximum: five members with 48 B names.
	var full := NetMessages.PartyRoster.new()
	for i: int in NetProtocol.PARTY_MAX_SIZE:
		full.members.append(NetMessages.PartyRoster.Member.make(i + 1, "Ñ".repeat(24)))
	var full_bytes: PackedByteArray = full.encode()
	assert_eq(full_bytes.size(), 3 + 5 * (3 + 48), "the maximum: 258 B")
	assert_true(full_bytes.size() <= NetProtocol.MAX_PACKET_BYTES, "fits in a packet")
	assert_not_null(NetMessages.PartyRoster.decode(full_bytes), "the maximum is decoded")
	# More than five: encode keeps five.
	var over: NetMessages.PartyRoster = _roster(7, 0)
	assert_eq(NetMessages.PartyRoster.decode(over.encode()).members.size(), 5, "encode trims to 5")


func test_roster_malformed_is_null() -> void:
	var valid: PackedByteArray = _roster(3, 2).encode()
	assert_not_null(NetMessages.PartyRoster.decode(valid), "the starting one is valid")
	for cut: int in valid.size():
		assert_null(NetMessages.PartyRoster.decode(valid.slice(0, cut)), "trimmed to %d B" % cut)
	var longer: PackedByteArray = valid.duplicate()
	longer.append(0)
	assert_null(NetMessages.PartyRoster.decode(longer), "one extra byte")
	var six: PackedByteArray = valid.duplicate()
	six[1] = 6
	assert_null(NetMessages.PartyRoster.decode(six), "six members")
	var bad_leader: PackedByteArray = valid.duplicate()
	bad_leader[2] = 3
	assert_null(NetMessages.PartyRoster.decode(bad_leader), "leader outside the list")
	assert_null(NetMessages.PartyRoster.decode(PackedByteArray([0x4E, 0, 1])), "without members and with a leader")
	var empty_name: PackedByteArray = PackedByteArray([0x4E, 1, 0, 1, 0, 0])
	assert_null(NetMessages.PartyRoster.decode(empty_name), "empty name")
	assert_null(NetMessages.PartyRoster.decode(PackedByteArray([0x4E, 1, 0, 7, 0, 3, 0xEF, 0xBB, 0xBF])),
			"name that reads as empty (only a BOM)")
	var duplicate := PackedByteArray([0x4E, 2, 0, 7, 0, 1, 0x41, 7, 0, 1, 0x42])
	assert_null(NetMessages.PartyRoster.decode(duplicate), "repeated net_id")
	var utf8: PackedByteArray = valid.duplicate()
	utf8[6] = 0xFF
	assert_null(NetMessages.PartyRoster.decode(utf8), "invalid UTF-8")
	var long_name: PackedByteArray = PackedByteArray([0x4E, 1, 0, 1, 0, 49])
	for _i: int in 49:
		long_name.append(0x61)
	assert_null(NetMessages.PartyRoster.decode(long_name), "49 B name")


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
	assert_eq(bytes.size(), 2 + 17 * 2, "2 B + 17 B per member")
	assert_eq(bytes[0], 0x4F, "u8 type")
	assert_eq(bytes[1], 2, "u8 count")
	assert_eq(bytes.decode_u16(2), 2000, "u16 net_id")
	assert_eq(bytes[4], 255, "u8 health_q")
	assert_eq(bytes[5], 100, "u8 stamina_q")
	assert_eq(bytes[6], NetMessages.STATUS_IN_COMBAT, "u8 status")
	assert_near(bytes.decode_float(7), 0.0, 1e-6, "f32 x")
	assert_near(bytes.decode_float(11), 2.0, 1e-6, "f32 y")
	assert_near(bytes.decode_float(15), 0.0, 1e-6, "f32 z")
	assert_near(bytes.decode_float(2 + 17 + 5), 10.5, 1e-6, "f32 x of the second, 17 B further on")
	var decoded: NetMessages.PartyStatus = NetMessages.PartyStatus.decode(bytes)
	if not assert_not_null(decoded, "it is decoded"):
		return
	assert_eq(decoded.members.size(), 2, "two")
	assert_eq(decoded.members[1].net_id, 2001, "net_id of the second")
	assert_eq(decoded.members[1].health_q, 245, "health")
	assert_eq(decoded.members[1].stamina_q, 101, "stamina")
	assert_eq(decoded.members[1].status, 0, "state")
	assert_vec_near(decoded.members[1].position, Vector3(10.5, 2.0, -250.25), 1e-4, "position")
	var full: PackedByteArray = _status(NetProtocol.PARTY_MAX_SIZE).encode()
	assert_eq(full.size(), 2 + 17 * 5, "the maximum: 87 B")
	assert_true(full.size() <= NetProtocol.MAX_PACKET_BYTES, "fits in a packet")
	assert_eq(NetMessages.PartyStatus.decode(_status(7).encode()).members.size(), 5, "encode trims to 5")
	assert_true(NetMessages.PartyStatus.MemberStatus.make(1, 0, 0, NetMessages.STATUS_DEAD, Vector3.ZERO).is_dead(),
			"is_dead")


func test_status_malformed_is_null() -> void:
	var valid: PackedByteArray = _status(3).encode()
	assert_not_null(NetMessages.PartyStatus.decode(valid), "the starting one is valid")
	for cut: int in valid.size():
		assert_null(NetMessages.PartyStatus.decode(valid.slice(0, cut)), "trimmed to %d B" % cut)
	var longer: PackedByteArray = valid.duplicate()
	longer.append(0)
	assert_null(NetMessages.PartyStatus.decode(longer), "one extra byte")
	var six: PackedByteArray = valid.duplicate()
	six[1] = 6
	assert_null(NetMessages.PartyStatus.decode(six), "six members")
	var bad_status: PackedByteArray = valid.duplicate()
	bad_status[6] = 0b10000
	assert_null(NetMessages.PartyStatus.decode(bad_status), "an unknown status bit")
	# Bit 3 (knocked down) exists since protocol 6 (docs/habilidades.md, section 5.2).
	var downed: PackedByteArray = valid.duplicate()
	downed[6] = NetMessages.STATUS_DOWNED
	var downed_back: NetMessages.PartyStatus = NetMessages.PartyStatus.decode(downed)
	if assert_not_null(downed_back, "a knocked-down member"):
		assert_true(downed_back.members[0].is_downed(), "is_downed")
		assert_false(downed_back.members[0].is_dead(), "knocked down is not dead")
	var nan_position: PackedByteArray = valid.duplicate()
	nan_position.encode_float(7, NAN)
	assert_null(NetMessages.PartyStatus.decode(nan_position), "a NaN position")
	var infinite: PackedByteArray = valid.duplicate()
	infinite.encode_float(11, INF)
	assert_null(NetMessages.PartyStatus.decode(infinite), "an infinite position")
	var duplicate: PackedByteArray = valid.duplicate()
	duplicate.encode_u16(2 + 17, 2000)
	assert_null(NetMessages.PartyStatus.decode(duplicate), "repeated net_id")


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
					assert_true((result as NetMessages.PartyRoster).members.size() <= 5, "at most 5 members")
				elif result is NetMessages.PartyStatus:
					for member: NetMessages.PartyStatus.MemberStatus in (result as NetMessages.PartyStatus).members:
						assert_true(member.position.is_finite(), "finite positions")
	assert_true(decoded_count > 50, "the fuzz reaches valid messages (%d)" % decoded_count)
