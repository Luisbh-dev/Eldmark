extends TestCase
## Pruebas del protocolo de chat (SOC-03, docs/social.md sección 12): CHAT_SEND (C→S) y CHAT_MESSAGE
## (S→C) de [NetMessages], los canales ([ChatChannel]) y las constantes de [NetProtocol].
## [br][br]
## Como en test_net_messages.gd, los offsets y los tamaños son los del documento, escritos a mano a
## propósito: si el código y el documento se separan, estas pruebas fallan. Los mensajes corruptos, los
## truncados y el fuzz comprueban además que nada registra errores del motor (el ejecutor los cuenta
## como fallo) y que ningún mensaje pasa de [constant NetProtocol.MAX_PACKET_BYTES].

const FUZZ_BUFFERS: int = 6000
const FUZZ_SEED: int = 20261101


# --- Constantes y canales ---------------------------------------------------------------------

func test_protocol_constants() -> void:
	assert_true(NetProtocol.PROTOCOL_VERSION >= 5, "el chat sube el protocolo a la versión 5")
	assert_eq(NetProtocol.MSG_CHAT_SEND, 0x40, "CHAT_SEND es el 0x40")
	assert_eq(NetProtocol.MSG_CHAT_MESSAGE, 0x41, "CHAT_MESSAGE es el 0x41")
	for message_type: int in [NetProtocol.MSG_CHAT_SEND, NetProtocol.MSG_CHAT_MESSAGE]:
		assert_eq(NetProtocol.channel_for_type(message_type), NetProtocol.CH_RELIABLE,
				"0x%02X va por el canal fiable 3" % message_type)
	assert_eq(NetProtocol.CH_RELIABLE, 3, "el canal fiable es el 3")
	assert_eq(NetProtocol.transfer_mode(NetProtocol.CH_RELIABLE), MultiplayerPeer.TRANSFER_MODE_RELIABLE,
			"y es fiable")


func test_channel_ids_are_fixed() -> void:
	# Los ids viajan por la red: no se reordenan.
	assert_eq(ChatChannel.Id.SAY, 0, "decir")
	assert_eq(ChatChannel.Id.ZONE, 1, "zona")
	assert_eq(ChatChannel.Id.WHISPER, 2, "susurro")
	assert_eq(ChatChannel.Id.PARTY, 3, "grupo")
	assert_eq(ChatChannel.Id.RAID, 4, "banda")
	assert_eq(ChatChannel.Id.GUILD, 5, "gremio")
	assert_eq(ChatChannel.Id.REALM, 6, "reino")
	assert_eq(ChatChannel.Id.SYSTEM, 7, "sistema")
	assert_eq(ChatChannel.Id.GM, 8, "GM")
	assert_eq(ChatChannel.MAX_ID, 8, "el mayor id")
	assert_eq(ChatChannel.DISPLAY_NAMES.size(), ChatChannel.MAX_ID + 1, "un nombre por canal")
	assert_false(ChatChannel.is_valid(-1), "-1 no existe")
	assert_false(ChatChannel.is_valid(9), "9 no existe")
	assert_false(ChatChannel.is_client_sendable(ChatChannel.Id.SYSTEM), "el sistema no lo envía un cliente")
	for channel: int in [0, 1, 2, 3, 4, 5, 6, 8]:
		assert_true(ChatChannel.is_client_sendable(channel), "el cliente puede enviar el canal %d" % channel)
	assert_eq(ChatChannel.display_name(ChatChannel.Id.WHISPER), "Susurro", "nombre en español")
	assert_eq(ChatChannel.display_name(99), "Canal", "un id desconocido tiene nombre genérico")
	assert_true(ChatChannel.uses_public_rate(ChatChannel.Id.SAY), "decir gasta del ritmo común")
	assert_false(ChatChannel.uses_public_rate(ChatChannel.Id.WHISPER), "el susurro tiene el suyo")
	assert_true(ChatChannel.is_implemented(ChatChannel.Id.PARTY), "el grupo se reparte en la fase 4")
	assert_false(ChatChannel.is_implemented(ChatChannel.Id.GUILD), "el gremio no")


func test_text_limits_are_the_documented_ones() -> void:
	assert_eq(ChatText.MAX_CHARS, 255, "255 caracteres")
	assert_eq(ChatText.MAX_BYTES, 768, "768 B")


# --- CHAT_SEND --------------------------------------------------------------------------------

func test_chat_send_layout_matches_the_document() -> void:
	var message := NetMessages.ChatSend.new()
	message.channel = ChatChannel.Id.ZONE
	message.text = "Hola"
	var bytes: PackedByteArray = message.encode()
	assert_eq(bytes.size(), 5 + 4, "5 B de cabecera + 4 de texto")
	assert_eq(bytes[0], 0x40, "u8 type")
	assert_eq(bytes[1], 1, "u8 channel")
	assert_eq(bytes[2], 0, "u8 recipient_len")
	assert_eq(bytes.decode_u16(3), 4, "u16 text_len")
	assert_eq(bytes.slice(5).get_string_from_utf8(), "Hola", "texto en UTF-8 al final")

	var whisper := NetMessages.ChatSend.new()
	whisper.channel = ChatChannel.Id.WHISPER
	whisper.recipient = "Álvaro"
	whisper.text = "¿Vienes?"
	var whisper_bytes: PackedByteArray = whisper.encode()
	var recipient_size: int = "Álvaro".to_utf8_buffer().size()
	var text_size: int = "¿Vienes?".to_utf8_buffer().size()
	assert_eq(whisper_bytes.size(), 5 + recipient_size + text_size, "tamaño del susurro")
	assert_eq(whisper_bytes[1], 2, "canal 2")
	assert_eq(whisper_bytes[2], recipient_size, "longitud del destinatario en bytes")
	assert_eq(whisper_bytes.decode_u16(3), text_size, "longitud del texto en bytes")
	assert_eq(whisper_bytes.slice(5, 5 + recipient_size).get_string_from_utf8(), "Álvaro",
			"el destinatario va antes del texto")


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
		if not assert_not_null(decoded, "se decodifica (%s)" % [sample]):
			continue
		assert_eq(decoded.channel, sample[0], "canal")
		assert_eq(decoded.recipient, sample[1], "destinatario")
		assert_eq(decoded.text, sample[2], "texto")


func test_chat_send_text_limits() -> void:
	# 255 caracteres de 3 bytes: 765 B, dentro de los 768.
	var long_text: String = "€".repeat(255)
	assert_eq(long_text.to_utf8_buffer().size(), 765, "255 caracteres de 3 bytes son 765 B")
	var message := NetMessages.ChatSend.new()
	message.text = long_text
	var decoded: NetMessages.ChatSend = NetMessages.ChatSend.decode(message.encode())
	if assert_not_null(decoded, "255 caracteres caben"):
		assert_eq(decoded.text, long_text, "íntegro")

	# encode recorta: 300 letras llegan como 255.
	message.text = "a".repeat(300)
	var clipped: NetMessages.ChatSend = NetMessages.ChatSend.decode(message.encode())
	if assert_not_null(clipped, "un texto largo se recorta al codificar"):
		assert_eq(clipped.text.length(), 255, "255 caracteres")

	# Con emoji de 4 bytes manda el tope de bytes: 192 caben (768 B) y no se parte ninguno.
	message.text = "😀".repeat(255)
	var emoji_bytes: PackedByteArray = message.encode()
	assert_eq(emoji_bytes.size(), 5 + 768, "el recorte por bytes deja 768 B de texto")
	var emoji: NetMessages.ChatSend = NetMessages.ChatSend.decode(emoji_bytes)
	if assert_not_null(emoji, "el recorte por bytes no parte ningún carácter"):
		assert_eq(emoji.text, "😀".repeat(192), "192 emoji")

	# A mano: 256 caracteres, o 769 B, no se decodifican.
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.SAY, "", "a".repeat(256))),
			"256 caracteres")
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.SAY, "", "😀".repeat(193))),
			"193 emoji son 772 B")


func test_chat_send_maximum_size_fits_in_one_packet() -> void:
	var message := NetMessages.ChatSend.new()
	message.channel = ChatChannel.Id.WHISPER
	message.recipient = "Ñ".repeat(NetProtocol.MAX_NAME_CHARS)
	message.text = "€".repeat(ChatText.MAX_CHARS)
	var bytes: PackedByteArray = message.encode()
	assert_true(bytes.size() <= NetProtocol.MAX_PACKET_BYTES, "cabe en 1200 B (%d)" % bytes.size())
	assert_true(bytes.size() <= 5 + NetProtocol.MAX_NAME_BYTES + ChatText.MAX_BYTES,
			"y en el máximo documentado de 821 B")
	assert_not_null(NetMessages.ChatSend.decode(bytes), "el máximo se decodifica")


func test_chat_send_malformed_is_null() -> void:
	var valid: PackedByteArray = _raw_send(ChatChannel.Id.WHISPER, "Ana", "Hola")
	assert_not_null(NetMessages.ChatSend.decode(valid), "el de partida vale")

	# Recortado en cualquier punto.
	for cut: int in valid.size():
		assert_null(NetMessages.ChatSend.decode(valid.slice(0, cut)), "recortado a %d B" % cut)
	# Con un byte de más.
	var longer: PackedByteArray = valid.duplicate()
	longer.append(0x61)
	assert_null(NetMessages.ChatSend.decode(longer), "un byte de más")
	assert_null(NetMessages.ChatSend.decode(PackedByteArray()), "vacío")

	# Tipo equivocado.
	var wrong_type: PackedByteArray = valid.duplicate()
	wrong_type[0] = NetProtocol.MSG_CHAT_MESSAGE
	assert_null(NetMessages.ChatSend.decode(wrong_type), "tipo de CHAT_MESSAGE")

	# Canales que un cliente no puede usar o que no existen.
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.SYSTEM, "", "Hola")),
			"el canal del sistema no lo envía un cliente")
	assert_null(NetMessages.ChatSend.decode(_raw_send(9, "", "Hola")), "canal 9")
	assert_null(NetMessages.ChatSend.decode(_raw_send(255, "", "Hola")), "canal 255")

	# Destinatario: obligatorio en un susurro y sobrante en los demás canales.
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.WHISPER, "", "Hola")),
			"un susurro sin destinatario")
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.SAY, "Ana", "Hola")),
			"un «decir» con destinatario")
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.WHISPER,
			"a".repeat(NetProtocol.MAX_NAME_CHARS + 1), "Hola")), "destinatario de 25 caracteres")
	assert_null(NetMessages.ChatSend.decode(_raw_send(ChatChannel.Id.WHISPER,
			"€".repeat(17), "Hola")), "destinatario de 51 B")

	# UTF-8 inválido y bytes nulos.
	var bad_utf8: PackedByteArray = _raw_send(ChatChannel.Id.SAY, "", "Hola")
	bad_utf8[5] = 0xFF
	assert_null(NetMessages.ChatSend.decode(bad_utf8), "UTF-8 inválido en el texto")
	var truncated_char: PackedByteArray = _raw_send(ChatChannel.Id.SAY, "", "ab")
	truncated_char[6] = 0xC3
	assert_null(NetMessages.ChatSend.decode(truncated_char), "carácter UTF-8 partido")
	var nul: PackedByteArray = _raw_send(ChatChannel.Id.SAY, "", "Hola")
	nul[7] = 0
	assert_null(NetMessages.ChatSend.decode(nul), "byte nulo en el texto")
	var bad_name: PackedByteArray = _raw_send(ChatChannel.Id.WHISPER, "Ana", "Hola")
	bad_name[5] = 0xFE
	assert_null(NetMessages.ChatSend.decode(bad_name), "UTF-8 inválido en el destinatario")

	# Longitudes que no cuadran con el tamaño.
	var wrong_text_len: PackedByteArray = valid.duplicate()
	wrong_text_len.encode_u16(3, 5)
	assert_null(NetMessages.ChatSend.decode(wrong_text_len), "text_len mayor que lo que hay")
	wrong_text_len.encode_u16(3, 3)
	assert_null(NetMessages.ChatSend.decode(wrong_text_len), "text_len menor que lo que hay")
	var huge_recipient: PackedByteArray = valid.duplicate()
	huge_recipient[2] = 200
	assert_null(NetMessages.ChatSend.decode(huge_recipient), "recipient_len de 200")


# --- CHAT_MESSAGE -----------------------------------------------------------------------------

func test_chat_message_layout_matches_the_document() -> void:
	var message := NetMessages.ChatMessage.new()
	message.channel = ChatChannel.Id.SAY
	message.sender_realm = NetProtocol.Realm.SOLMARCH
	message.tick = 0x01020304
	message.sender = "Ana"
	message.text = "Hola"
	var bytes: PackedByteArray = message.encode()
	assert_eq(bytes.size(), 11 + 3 + 4, "11 B de cabecera + emisor + texto")
	assert_eq(bytes[0], 0x41, "u8 type")
	assert_eq(bytes[1], 0, "u8 channel")
	assert_eq(bytes[2], 2, "u8 sender_realm")
	assert_eq(bytes.decode_u32(3), 0x01020304, "u32 tick")
	assert_eq(bytes[7], 3, "u8 sender_len")
	assert_eq(bytes[8], 0, "u8 recipient_len")
	assert_eq(bytes.decode_u16(9), 4, "u16 text_len")
	assert_eq(bytes.slice(11, 14).get_string_from_utf8(), "Ana", "el emisor va primero")
	assert_eq(bytes.slice(14).get_string_from_utf8(), "Hola", "y el texto al final")

	message.channel = ChatChannel.Id.WHISPER
	message.recipient = "Bruno"
	var whisper_bytes: PackedByteArray = message.encode()
	assert_eq(whisper_bytes.size(), 11 + 3 + 5 + 4, "el destinatario va entre el emisor y el texto")
	assert_eq(whisper_bytes[8], 5, "recipient_len")
	assert_eq(whisper_bytes.slice(14, 19).get_string_from_utf8(), "Bruno", "destinatario")


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
		if not assert_not_null(decoded, "se decodifica (%s)" % [sample]):
			continue
		assert_eq(decoded.channel, sample["channel"], "canal")
		assert_eq(decoded.sender_realm, sample["realm"], "reino del emisor")
		assert_eq(decoded.tick, 123456, "tick")
		assert_eq(decoded.sender, sample["sender"], "emisor")
		assert_eq(decoded.recipient, sample["recipient"], "destinatario")
		assert_eq(decoded.text, sample["text"], "texto")


func test_chat_message_maximum_size_fits_in_one_packet() -> void:
	var message := NetMessages.ChatMessage.new()
	message.channel = ChatChannel.Id.WHISPER
	message.sender_realm = NetProtocol.Realm.ASKARRA
	message.tick = 0xFFFFFFFF
	message.sender = "Ñ".repeat(24)
	message.recipient = "Ñ".repeat(24)
	message.text = "€".repeat(ChatText.MAX_CHARS)
	var bytes: PackedByteArray = message.encode()
	assert_eq(bytes.size(), 11 + 48 + 48 + 765, "el máximo documentado")
	assert_true(bytes.size() <= NetProtocol.MAX_PACKET_BYTES, "cabe en 1200 B (%d)" % bytes.size())
	var decoded: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
	if assert_not_null(decoded, "el máximo se decodifica"):
		assert_eq(decoded.tick, 0xFFFFFFFF, "tick máximo")
		assert_eq(decoded.text.length(), ChatText.MAX_CHARS, "texto íntegro")


func test_chat_message_malformed_is_null() -> void:
	var valid: PackedByteArray = _raw_message(ChatChannel.Id.WHISPER, 1, "Ana", "Bruno", "Hola")
	assert_not_null(NetMessages.ChatMessage.decode(valid), "el de partida vale")
	for cut: int in valid.size():
		assert_null(NetMessages.ChatMessage.decode(valid.slice(0, cut)), "recortado a %d B" % cut)
	var longer: PackedByteArray = valid.duplicate()
	longer.append(0x61)
	assert_null(NetMessages.ChatMessage.decode(longer), "un byte de más")
	assert_null(NetMessages.ChatMessage.decode(PackedByteArray()), "vacío")

	var wrong_type: PackedByteArray = valid.duplicate()
	wrong_type[0] = NetProtocol.MSG_CHAT_SEND
	assert_null(NetMessages.ChatMessage.decode(wrong_type), "tipo de CHAT_SEND")
	assert_null(NetMessages.ChatMessage.decode(_raw_message(9, 1, "Ana", "", "Hola")), "canal 9")
	assert_null(NetMessages.ChatMessage.decode(_raw_message(ChatChannel.Id.SAY, 4, "Ana", "", "Hola")),
			"reino 4")
	# El sistema no tiene emisor ni destinatario; los demás canales sí tienen emisor.
	assert_null(NetMessages.ChatMessage.decode(_raw_message(ChatChannel.Id.SYSTEM, 0, "Ana", "", "Hola")),
			"un mensaje del sistema con emisor")
	assert_null(NetMessages.ChatMessage.decode(_raw_message(ChatChannel.Id.SAY, 1, "", "", "Hola")),
			"un «decir» sin emisor")
	assert_null(NetMessages.ChatMessage.decode(_raw_message(ChatChannel.Id.WHISPER, 1, "Ana", "", "Hola")),
			"un susurro sin destinatario")
	assert_null(NetMessages.ChatMessage.decode(_raw_message(ChatChannel.Id.ZONE, 1, "Ana", "Bruno", "Hola")),
			"un mensaje de zona con destinatario")
	# UTF-8 inválido en cada parte.
	for offset: int in [11, 14, 19]:
		var bad: PackedByteArray = valid.duplicate()
		bad[offset] = 0xFF
		assert_null(NetMessages.ChatMessage.decode(bad), "UTF-8 inválido en el byte %d" % offset)
	# Longitudes que no cuadran.
	var wrong_sender_len: PackedByteArray = valid.duplicate()
	wrong_sender_len[7] = 4
	assert_null(NetMessages.ChatMessage.decode(wrong_sender_len), "sender_len mayor")
	var wrong_text_len: PackedByteArray = valid.duplicate()
	wrong_text_len.encode_u16(9, 900)
	assert_null(NetMessages.ChatMessage.decode(wrong_text_len), "text_len de 900")
	assert_null(NetMessages.ChatMessage.decode(_raw_message(ChatChannel.Id.SAY, 1, "Ana", "",
			"a".repeat(256))), "256 caracteres")


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
			assert_true(send.text.length() <= ChatText.MAX_CHARS, "un texto decodificado cabe en 255")
			assert_true(ChatChannel.is_client_sendable(send.channel), "canal enviable")
		var message: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
		if message != null:
			decoded_count += 1
			assert_true(message.text.length() <= ChatText.MAX_CHARS, "un texto decodificado cabe en 255")
			assert_true(ChatChannel.is_valid(message.channel), "canal válido")
	assert_true(decoded_count > 50, "el fuzz llega hasta mensajes válidos (%d)" % decoded_count)


# --- Utilidades -------------------------------------------------------------------------------

# CHAT_SEND escrito a mano, sin pasar por encode(), para poder fabricar mensajes fuera de los límites.
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


# CHAT_MESSAGE escrito a mano.
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
