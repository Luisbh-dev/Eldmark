extends TestCase
## Tests for the chat protocol (SOC-03, docs/social.md section 12): CHAT_SEND (C→S) and CHAT_MESSAGE
## (S→C) of [NetMessages], the channels ([ChatChannel]) and the [NetProtocol] constants.
## [br][br]
## As in test_net_messages.gd, the offsets and sizes are the ones in the document, written by hand on
## purpose: if the code and the document drift apart, these tests fail. Corrupt messages, truncated
## ones and the fuzz also check that nothing logs engine errors (the runner counts them as a failure)
## and that no message exceeds [constant NetProtocol.MAX_PACKET_BYTES].

const FUZZ_BUFFERS: int = 6000
const FUZZ_SEED: int = 20261101


# --- Constants and channels -------------------------------------------------------------------

func test_protocol_constants() -> void:
	assert_true(NetProtocol.PROTOCOL_VERSION >= 5, "chat bumps the protocol to version 5")
	assert_eq(NetProtocol.MSG_CHAT_SEND, 0x40, "CHAT_SEND is 0x40")
	assert_eq(NetProtocol.MSG_CHAT_MESSAGE, 0x41, "CHAT_MESSAGE is 0x41")
	for message_type: int in [NetProtocol.MSG_CHAT_SEND, NetProtocol.MSG_CHAT_MESSAGE]:
		assert_eq(NetProtocol.channel_for_type(message_type), NetProtocol.CH_RELIABLE,
				"0x%02X goes over reliable channel 3" % message_type)
	assert_eq(NetProtocol.CH_RELIABLE, 3, "the reliable channel is 3")
	assert_eq(NetProtocol.transfer_mode(NetProtocol.CH_RELIABLE), MultiplayerPeer.TRANSFER_MODE_RELIABLE,
			"and it is reliable")


func test_channel_ids_are_fixed() -> void:
	# The ids travel over the network: they are never reordered.
	assert_eq(ChatChannel.Id.SAY, 0, "say")
	assert_eq(ChatChannel.Id.ZONE, 1, "zone")
	assert_eq(ChatChannel.Id.WHISPER, 2, "whisper")
	assert_eq(ChatChannel.Id.PARTY, 3, "party")
	assert_eq(ChatChannel.Id.RAID, 4, "raid")
	assert_eq(ChatChannel.Id.GUILD, 5, "guild")
	assert_eq(ChatChannel.Id.REALM, 6, "realm")
	assert_eq(ChatChannel.Id.SYSTEM, 7, "system")
	assert_eq(ChatChannel.Id.GM, 8, "GM")
	assert_eq(ChatChannel.MAX_ID, 8, "the highest id")
	assert_eq(ChatChannel.DISPLAY_NAMES.size(), ChatChannel.MAX_ID + 1, "one name per channel")
	assert_false(ChatChannel.is_valid(-1), "-1 does not exist")
	assert_false(ChatChannel.is_valid(9), "9 does not exist")
	assert_false(ChatChannel.is_client_sendable(ChatChannel.Id.SYSTEM), "the system channel is not sent by a client")
	for channel: int in [0, 1, 2, 3, 4, 5, 6, 8]:
		assert_true(ChatChannel.is_client_sendable(channel), "the client can send channel %d" % channel)
	assert_eq(ChatChannel.display_name(ChatChannel.Id.WHISPER), "Susurro", "name in Spanish")
	assert_eq(ChatChannel.display_name(99), "Canal", "an unknown id has a generic name")
	assert_true(ChatChannel.uses_public_rate(ChatChannel.Id.SAY), "say uses the common rate")
	assert_false(ChatChannel.uses_public_rate(ChatChannel.Id.WHISPER), "whisper has its own")
	assert_true(ChatChannel.is_implemented(ChatChannel.Id.PARTY), "party is handled in phase 4")
	assert_false(ChatChannel.is_implemented(ChatChannel.Id.GUILD), "guild is not")


func test_text_limits_are_the_documented_ones() -> void:
	assert_eq(ChatText.MAX_CHARS, 255, "255 characters")
	assert_eq(ChatText.MAX_BYTES, 768, "768 B")


# --- CHAT_SEND --------------------------------------------------------------------------------

func test_chat_send_layout_matches_the_document() -> void:
	var message := NetMessages.ChatSend.new()
	message.channel = ChatChannel.Id.ZONE
	message.text = "Hola"
	var bytes: PackedByteArray = message.encode()
	assert_eq(bytes.size(), 5 + 4, "5 B of header + 4 of text")
	assert_eq(bytes[0], 0x40, "u8 type")
	assert_eq(bytes[1], 1, "u8 channel")
	assert_eq(bytes[2], 0, "u8 recipient_len")
	assert_eq(bytes.decode_u16(3), 4, "u16 text_len")
	assert_eq(bytes.slice(5).get_string_from_utf8(), "Hola", "UTF-8 text at the end")

	var whisper := NetMessages.ChatSend.new()
	whisper.channel = ChatChannel.Id.WHISPER
	whisper.recipient = "Álvaro"
	whisper.text = "¿Vienes?"
	var whisper_bytes: PackedByteArray = whisper.encode()
	var recipient_size: int = "Álvaro".to_utf8_buffer().size()
	var text_size: int = "¿Vienes?".to_utf8_buffer().size()
	assert_eq(whisper_bytes.size(), 5 + recipient_size + text_size, "whisper size")
	assert_eq(whisper_bytes[1], 2, "channel 2")
	assert_eq(whisper_bytes[2], recipient_size, "recipient length in bytes")
	assert_eq(whisper_bytes.decode_u16(3), text_size, "text length in bytes")
	assert_eq(whisper_bytes.slice(5, 5 + recipient_size).get_string_from_utf8(), "Álvaro",
			"the recipient comes before the text")


func test_chat_send_round_trip() -> void:
	var samples: Array[Array] = [
		[ChatChannel.Id.SAY, "", "Hola, mundo"],
		[ChatChannel.Id.ZONE, "", "¿Alguien en el fuerte?"],
		[ChatChannel.Id.WHISPER, "Peña", "Ñandú, árbol y pingüino"],
		[ChatChannel.Id.PARTY, "", "Atacamos por la puerta"],
		[ChatChannel.Id.RAID, "", "x"],
		[ChatChannel.Id.GUILD, "", "Texto con emoji 😀 y símbolos ⚔"],
		[ChatChannel.Id.REALM, "", "a"],
		[ChatChannel.Id.GM, "", "Necesito ayuda"],
		[ChatChannel.Id.SAY, "", ""],
	]
	for sample: Array in samples:
		var message := NetMessages.ChatSend.new()
		message.channel = sample[0]
		message.recipient = sample[1]
		message.text = sample[2]
		var decoded: NetMessages.ChatSend = NetMessages.ChatSend.decode(message.encode())
		if not assert_not_null(decoded, "it decodes (%s)" % [sample]):
			continue
		assert_eq(decoded.channel, sample[0], "channel")
		assert_eq(decoded.recipient, sample[1], "recipient")
		assert_eq(decoded.text, sample[2], "text")


func test_chat_send_text_limits() -> void:
	# 255 characters of 3 bytes: 765 B, within the 768.
	var long_text: String = "€".repeat(255)
	assert_eq(long_text.to_utf8_buffer().size(), 765, "255 characters of 3 bytes are 765 B")
	var message := NetMessages.ChatSend.new()
	message.text = long_text
	var decoded: NetMessages.ChatSend = NetMessages.ChatSend.decode(message.encode())
	if assert_not_null(decoded, "255 characters fit"):
		assert_eq(decoded.text, long_text, "intact")

	# encode trims: 300 letters arrive as 255.
	message.text = "a".repeat(300)
	var clipped: NetMessages.ChatSend = NetMessages.ChatSend.decode(message.encode())
	if assert_not_null(clipped, "a long text is trimmed when encoding"):
		assert_eq(clipped.text.length(), 255, "255 characters")

	# With 4-byte emoji the byte cap rules: 192 fit (768 B) and none is split.
	message.text = "😀".repeat(255)
	var emoji_bytes: PackedByteArray = message.encode()
	assert_eq(emoji_bytes.size(), 5 + 768, "the byte trim leaves 768 B of text")
	var emoji: NetMessages.ChatSend = NetMessages.ChatSend.decode(emoji_bytes)
	if assert_not_null(emoji, "the byte trim does not split any character"):
		assert_eq(emoji.text, "😀".repeat(192), "192 emoji")

	# By hand: 256 characters, or 769 B, do not decode.
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.SAY, "", "a".repeat(256))),
			"256 characters")
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.SAY, "", "😀".repeat(193))),
			"193 emoji are 772 B")


func test_chat_send_maximum_size_fits_in_one_packet() -> void:
	var message := NetMessages.ChatSend.new()
	message.channel = ChatChannel.Id.WHISPER
	message.recipient = "Ñ".repeat(NetProtocol.MAX_NAME_CHARS)
	message.text = "€".repeat(ChatText.MAX_CHARS)
	var bytes: PackedByteArray = message.encode()
	assert_true(bytes.size() <= NetProtocol.MAX_PACKET_BYTES, "fits in 1200 B (%d)" % bytes.size())
	assert_true(bytes.size() <= 5 + NetProtocol.MAX_NAME_BYTES + ChatText.MAX_BYTES,
			"and in the documented maximum of 821 B")
	assert_not_null(NetMessages.ChatSend.decode(bytes), "the maximum decodes")


func test_chat_send_malformed_is_null() -> void:
	var valid: PackedByteArray = _raw_send(ChatChannel.Id.WHISPER, "Ana", "Hola")
	assert_not_null(NetMessages.ChatSend.decode(valid), "the baseline one is valid")

	# Truncated at any point.
	for cut: int in valid.size():
		assert_null(NetMessages.ChatSend.decode(valid.slice(0, cut)), "truncated to %d B" % cut)
	# With one extra byte.
	var longer: PackedByteArray = valid.duplicate()
	longer.append(0x61)
	assert_null(NetMessages.ChatSend.decode(longer), "one extra byte")
	assert_null(NetMessages.ChatSend.decode(PackedByteArray()), "empty")

	# Wrong type.
	var wrong_type: PackedByteArray = valid.duplicate()
	wrong_type[0] = NetProtocol.MSG_CHAT_MESSAGE
	assert_null(NetMessages.ChatSend.decode(wrong_type), "CHAT_MESSAGE type")

	# Channels that a client cannot use or that do not exist.
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.SYSTEM, "", "Hola")),
			"the system channel is not sent by a client")
	assert_null(NetMessages.ChatSend.decode(_raw_send(9, "", "Hola")), "channel 9")
	assert_null(NetMessages.ChatSend.decode(_raw_send(255, "", "Hola")), "channel 255")

	# Recipient: required in a whisper and surplus in the other channels.
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.WHISPER, "", "Hola")),
			"a whisper without a recipient")
	var bom_recipient: PackedByteArray = _raw_send(ChatChannel.Id.WHISPER, "", "hi")
	bom_recipient[2] = 3
	var bom := PackedByteArray([0xEF, 0xBB, 0xBF])
	var with_bom: PackedByteArray = bom_recipient.slice(0, 5)
	with_bom.append_array(bom)
	with_bom.append_array(bom_recipient.slice(5))
	assert_null(NetMessages.ChatSend.decode(with_bom), "a whisper whose recipient reads as empty (just a BOM)")
	var bom_text: PackedByteArray = _raw_send(ChatChannel.Id.SAY, "", "")
	bom_text.encode_u16(3, 3)
	bom_text.append_array(bom)
	assert_not_null(NetMessages.ChatSend.decode(bom_text), "a text that reads as empty does decode (the server discards it)")
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.SAY, "Ana", "Hola")),
			"a \"say\" with a recipient")
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.WHISPER,
			"a".repeat(NetProtocol.MAX_NAME_CHARS + 1), "Hola")), "recipient of 25 characters")
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.WHISPER,
			"€".repeat(17), "Hola")), "recipient of 51 B")

	# Invalid UTF-8 and null bytes.
	var bad_utf8: PackedByteArray = _raw_send(ChatChannel.Id.SAY, "", "Hola")
	bad_utf8[5] = 0xFF
	assert_null(NetMessages.ChatSend.decode(bad_utf8), "invalid UTF-8 in the text")
	var truncated_char: PackedByteArray = _raw_send(ChatChannel.Id.SAY, "", "ab")
	truncated_char[6] = 0xC3
	assert_null(NetMessages.ChatSend.decode(truncated_char), "split UTF-8 character")
	var nul: PackedByteArray = _raw_send(ChatChannel.Id.SAY, "", "Hola")
	nul[7] = 0
	assert_null(NetMessages.ChatSend.decode(nul), "null byte in the text")
	var bad_name: PackedByteArray = _raw_send(ChatChannel.Id.WHISPER, "Ana", "Hola")
	bad_name[5] = 0xFE
	assert_null(NetMessages.ChatSend.decode(bad_name), "invalid UTF-8 in the recipient")

	# Lengths that do not match the size.
	var wrong_text_len: PackedByteArray = valid.duplicate()
	wrong_text_len.encode_u16(3, 5)
	assert_null(NetMessages.ChatSend.decode(wrong_text_len), "text_len greater than what is there")
	wrong_text_len.encode_u16(3, 3)
	assert_null(NetMessages.ChatSend.decode(wrong_text_len), "text_len less than what is there")
	var huge_recipient: PackedByteArray = valid.duplicate()
	huge_recipient[2] = 200
	assert_null(NetMessages.ChatSend.decode(huge_recipient), "recipient_len of 200")


# --- CHAT_MESSAGE -----------------------------------------------------------------------------

func test_chat_message_layout_matches_the_document() -> void:
	var message := NetMessages.ChatMessage.new()
	message.channel = ChatChannel.Id.SAY
	message.sender_realm = NetProtocol.Realm.SOLMARCH
	message.tick = 0x01020304
	message.sender = "Ana"
	message.text = "Hola"
	var bytes: PackedByteArray = message.encode()
	assert_eq(bytes.size(), 11 + 3 + 4, "11 B of header + sender + text")
	assert_eq(bytes[0], 0x41, "u8 type")
	assert_eq(bytes[1], 0, "u8 channel")
	assert_eq(bytes[2], 2, "u8 sender_realm")
	assert_eq(bytes.decode_u32(3), 0x01020304, "u32 tick")
	assert_eq(bytes[7], 3, "u8 sender_len")
	assert_eq(bytes[8], 0, "u8 recipient_len")
	assert_eq(bytes.decode_u16(9), 4, "u16 text_len")
	assert_eq(bytes.slice(11, 14).get_string_from_utf8(), "Ana", "the sender comes first")
	assert_eq(bytes.slice(14).get_string_from_utf8(), "Hola", "and the text at the end")

	message.channel = ChatChannel.Id.WHISPER
	message.recipient = "Bruno"
	var whisper_bytes: PackedByteArray = message.encode()
	assert_eq(whisper_bytes.size(), 11 + 3 + 5 + 4, "the recipient goes between the sender and the text")
	assert_eq(whisper_bytes[8], 5, "recipient_len")
	assert_eq(whisper_bytes.slice(14, 19).get_string_from_utf8(), "Bruno", "recipient")


func test_chat_message_round_trip() -> void:
	var samples: Array[Dictionary] = [
		{"channel": ChatChannel.Id.SAY, "realm": 1, "sender": "Ana", "recipient": "", "text": "Hola"},
		{"channel": ChatChannel.Id.ZONE, "realm": 2, "sender": "Peña", "recipient": "", "text": "¿Y el fuerte?"},
		{"channel": ChatChannel.Id.WHISPER, "realm": 3, "sender": "Álvaro", "recipient": "Bruno", "text": "Psst"},
		{"channel": ChatChannel.Id.PARTY, "realm": 1, "sender": "Ana", "recipient": "", "text": "Vamos"},
		{"channel": ChatChannel.Id.SYSTEM, "realm": 0, "sender": "", "recipient": "", "text": "Hablas demasiado rápido."},
		{"channel": ChatChannel.Id.GM, "realm": 0, "sender": "Moderador", "recipient": "", "text": "Aviso"},
		{"channel": ChatChannel.Id.SAY, "realm": 1, "sender": "Ana", "recipient": "", "text": ""},
	]
	for sample: Dictionary in samples:
		var message := NetMessages.ChatMessage.new()
		message.channel = sample["channel"]
		message.sender_realm = sample["realm"]
		message.tick = 123456
		message.sender = sample["sender"]
		message.recipient = sample["recipient"]
		message.text = sample["text"]
		var decoded: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(message.encode())
		if not assert_not_null(decoded, "it decodes (%s)" % [sample]):
			continue
		assert_eq(decoded.channel, sample["channel"], "channel")
		assert_eq(decoded.sender_realm, sample["realm"], "sender realm")
		assert_eq(decoded.tick, 123456, "tick")
		assert_eq(decoded.sender, sample["sender"], "sender")
		assert_eq(decoded.recipient, sample["recipient"], "recipient")
		assert_eq(decoded.text, sample["text"], "text")


func test_chat_message_maximum_size_fits_in_one_packet() -> void:
	var message := NetMessages.ChatMessage.new()
	message.channel = ChatChannel.Id.WHISPER
	message.sender_realm = NetProtocol.Realm.ASKARRA
	message.tick = 0xFFFFFFFF
	message.sender = "Ñ".repeat(24)
	message.recipient = "Ñ".repeat(24)
	message.text = "€".repeat(ChatText.MAX_CHARS)
	var bytes: PackedByteArray = message.encode()
	assert_eq(bytes.size(), 11 + 48 + 48 + 765, "the documented maximum")
	assert_true(bytes.size() <= NetProtocol.MAX_PACKET_BYTES, "fits in 1200 B (%d)" % bytes.size())
	var decoded: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
	if assert_not_null(decoded, "the maximum decodes"):
		assert_eq(decoded.tick, 0xFFFFFFFF, "maximum tick")
		assert_eq(decoded.text.length(), ChatText.MAX_CHARS, "intact text")


func test_chat_message_malformed_is_null() -> void:
	var valid: PackedByteArray = _raw_message(ChatChannel.Id.WHISPER, 1, "Ana", "Bruno", "Hola")
	assert_not_null(NetMessages.ChatMessage.decode(valid), "the baseline one is valid")
	for cut: int in valid.size():
		assert_null(NetMessages.ChatMessage.decode(valid.slice(0, cut)), "truncated to %d B" % cut)
	var longer: PackedByteArray = valid.duplicate()
	longer.append(0x61)
	assert_null(NetMessages.ChatMessage.decode(longer), "one extra byte")
	assert_null(NetMessages.ChatMessage.decode(PackedByteArray()), "empty")

	var wrong_type: PackedByteArray = valid.duplicate()
	wrong_type[0] = NetProtocol.MSG_CHAT_SEND
	assert_null(NetMessages.ChatMessage.decode(wrong_type), "CHAT_SEND type")
	assert_null(NetMessages.ChatMessage.decode(_raw_message(9, 1, "Ana", "", "Hola")), "channel 9")
	assert_null(NetMessages.ChatMessage.decode(_raw_message(ChatChannel.Id.SAY, 4, "Ana", "", "Hola")),
			"realm 4")
	# System has no sender or recipient; the other channels do have a sender.
	assert_null(NetMessages.ChatMessage.decode(_raw_message(ChatChannel.Id.SYSTEM, 0, "Ana", "", "Hola")),
			"a system message with a sender")
	assert_null(NetMessages.ChatMessage.decode(_raw_message(ChatChannel.Id.SAY, 1, "", "", "Hola")),
			"a \"say\" without a sender")
	assert_null(NetMessages.ChatMessage.decode(_raw_message(ChatChannel.Id.WHISPER, 1, "Ana", "", "Hola")),
			"a whisper without a recipient")
	var bom: String = PackedByteArray([0xEF, 0xBB, 0xBF]).get_string_from_utf8()
	assert_eq(bom, "", "get_string_from_utf8 skips the BOM")
	var bom_sender: PackedByteArray = _raw_message(ChatChannel.Id.SAY, 1, "A", "", "Hola")
	bom_sender[7] = 3
	var bom_bytes := PackedByteArray([0xEF, 0xBB, 0xBF])
	var say_with_bom: PackedByteArray = bom_sender.slice(0, 11)
	say_with_bom.append_array(bom_bytes)
	say_with_bom.append_array(bom_sender.slice(12))
	assert_null(NetMessages.ChatMessage.decode(say_with_bom), "a \"say\" whose sender reads as empty (just a BOM)")
	var whisper_bom: PackedByteArray = _raw_message(ChatChannel.Id.WHISPER, 1, "Ana", "B", "Hola")
	whisper_bom[8] = 3
	var whisper_with_bom: PackedByteArray = whisper_bom.slice(0, 14)
	whisper_with_bom.append_array(bom_bytes)
	whisper_with_bom.append_array(whisper_bom.slice(15))
	assert_null(NetMessages.ChatMessage.decode(whisper_with_bom),
			"a whisper whose recipient reads as empty (just a BOM)")
	assert_null(NetMessages.ChatMessage.decode(_raw_message(ChatChannel.Id.ZONE, 1, "Ana", "Bruno", "Hola")),
			"a zone message with a recipient")
	# Invalid UTF-8 in each part.
	for offset: int in [11, 14, 19]:
		var bad: PackedByteArray = valid.duplicate()
		bad[offset] = 0xFF
		assert_null(NetMessages.ChatMessage.decode(bad), "invalid UTF-8 at byte %d" % offset)
	# Lengths that do not match.
	var wrong_sender_len: PackedByteArray = valid.duplicate()
	wrong_sender_len[7] = 4
	assert_null(NetMessages.ChatMessage.decode(wrong_sender_len), "greater sender_len")
	var wrong_text_len: PackedByteArray = valid.duplicate()
	wrong_text_len.encode_u16(9, 900)
	assert_null(NetMessages.ChatMessage.decode(wrong_text_len), "text_len of 900")
	assert_null(NetMessages.ChatMessage.decode(_raw_message(ChatChannel.Id.SAY, 1, "Ana", "",
			"a".repeat(256))), "256 characters")


# --- Fuzz -------------------------------------------------------------------------------------

func test_fuzz_random_buffers_never_error() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = FUZZ_SEED
	var samples: Array[PackedByteArray] = [
		_raw_send(ChatChannel.Id.SAY, "", "Hola"),
		_raw_send(ChatChannel.Id.WHISPER, "Ana", "Psst, ¿vienes?"),
		_raw_message(ChatChannel.Id.ZONE, 2, "Peña", "", "Texto de zona"),
		_raw_message(ChatChannel.Id.WHISPER, 1, "Ana", "Bruno", "Hola"),
		_raw_message(ChatChannel.Id.SYSTEM, 0, "", "", "Aviso"),
	]
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
			bytes[0] = NetProtocol.MSG_CHAT_SEND if rng.randf() < 0.5 else NetProtocol.MSG_CHAT_MESSAGE
		else:
			bytes = samples[rng.randi() % samples.size()].duplicate()
			for _k: int in rng.randi_range(0, 3):
				bytes[rng.randi() % bytes.size()] = rng.randi() & 0xFF
			var roll: float = rng.randf()
			if roll < 0.2:
				bytes.resize(rng.randi_range(0, bytes.size()))
			elif roll < 0.3:
				bytes.append(rng.randi() & 0xFF)
		var send: NetMessages.ChatSend = NetMessages.ChatSend.decode(bytes)
		if send != null:
			decoded_count += 1
			assert_true(send.text.length() <= ChatText.MAX_CHARS, "a decoded text fits in 255")
			assert_true(ChatChannel.is_client_sendable(send.channel), "sendable channel")
		var message: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
		if message != null:
			decoded_count += 1
			assert_true(message.text.length() <= ChatText.MAX_CHARS, "a decoded text fits in 255")
			assert_true(ChatChannel.is_valid(message.channel), "valid channel")
	assert_true(decoded_count > 50, "the fuzz reaches valid messages (%d)" % decoded_count)


# --- Utilities --------------------------------------------------------------------------------

# CHAT_SEND written by hand, without going through encode(), so out-of-bounds messages can be crafted.
func _raw_send(channel: int, recipient: String, text: String) -> PackedByteArray:
	var recipient_bytes: PackedByteArray = recipient.to_utf8_buffer()
	var text_bytes: PackedByteArray = text.to_utf8_buffer()
	var bytes := PackedByteArray()
	bytes.resize(5)
	bytes[0] = 0x40
	bytes[1] = channel
	bytes[2] = recipient_bytes.size()
	bytes.encode_u16(3, text_bytes.size())
	bytes.append_array(recipient_bytes)
	bytes.append_array(text_bytes)
	return bytes


# CHAT_MESSAGE written by hand.
func _raw_message(channel: int, realm: int, sender: String, recipient: String,
		text: String) -> PackedByteArray:
	var sender_bytes: PackedByteArray = sender.to_utf8_buffer()
	var recipient_bytes: PackedByteArray = recipient.to_utf8_buffer()
	var text_bytes: PackedByteArray = text.to_utf8_buffer()
	var bytes := PackedByteArray()
	bytes.resize(11)
	bytes[0] = 0x41
	bytes[1] = channel
	bytes[2] = realm
	bytes.encode_u32(3, 99)
	bytes[7] = sender_bytes.size()
	bytes[8] = recipient_bytes.size()
	bytes.encode_u16(9, text_bytes.size())
	bytes.append_array(sender_bytes)
	bytes.append_array(recipient_bytes)
	bytes.append_array(text_bytes)
	return bytes
