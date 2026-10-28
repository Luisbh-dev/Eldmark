class_name NetMessages
extends RefCounted
## Mensajes del protocolo de red de la fase 2 y su serialización (docs/red.md, sección 5).
## [br][br]
## Cada clase interna tiene [code]encode() -> PackedByteArray[/code] y
## [code]static decode(bytes) -> <Clase>[/code], que devuelve null si el mensaje está malformado:
## tamaño, tipo, contadores o longitudes que no cuadran, bytes de sobra o texto que no es UTF-8
## válido. Los [code]decode[/code] comprueban los tamaños antes de leer, así que nunca registran
## errores del motor, ni siquiera con bytes aleatorios (el servidor decodifica lo que envían
## clientes que no son de fiar).
## [br][br]
## Todo es little-endian. Los tres primeros (HELLO, WELCOME y REJECT) son mensajes de
## autenticación: empiezan con el magic [constant NetProtocol.MAGIC]. El resto empieza con su
## tipo ([code]NetProtocol.MSG_*[/code]) y viaja por [code]send_bytes[/code].

## Tamaño de la cabecera de un SNAPSHOT sin estado propio, con el byte de
## [code]section_count[/code].
const SNAPSHOT_HEADER_SIZE: int = 14
## Tamaño de la cabecera de un SNAPSHOT con estado propio, con el byte de
## [code]section_count[/code].
const SNAPSHOT_HEADER_SIZE_WITH_STATE: int = SNAPSHOT_HEADER_SIZE + PlayerState.ENCODED_SIZE
## Máximo de registros por sección (el contador es un u8).
const MAX_SECTION_RECORDS: int = 255
## Máximo de bytes del texto de un NOTICE.
const MAX_NOTICE_BYTES: int = 200
## Máximo de bytes del texto de un REJECT (el contador es un u8).
const MAX_REJECT_TEXT_BYTES: int = 255
## Máximo de bytes de datos de un DEBUG_COMMAND.
const MAX_DEBUG_PAYLOAD_BYTES: int = 64

## Bit 0 de los flags de un SNAPSHOT: trae el estado propio.
const FLAG_OWN_STATE: int = 1 << 0
## Desplazamiento y máscara del contador de teletransporte en los flags (2 bits).
const TELEPORT_SHIFT: int = 1
const TELEPORT_MASK: int = 0b11
## Cabecera de un INPUT_BATCH y tamaño de cada uno de sus registros.
const INPUT_BATCH_HEADER_SIZE: int = 11
const INPUT_RECORD_SIZE: int = 10
## Cabecera de un ENTITY_SPAWN, antes de los datos de la entidad.
const SPAWN_HEADER_SIZE: int = 10
## Máximo de [code]view_offset_q[/code] (u16).
const MAX_VIEW_OFFSET_Q: int = 0xFFFF


## Tipo de un mensaje (su byte 0), o -1 si [param bytes] está vacío.
static func peek_type(bytes: PackedByteArray) -> int:
	return bytes[0] if bytes.size() > 0 else -1


## Resultado de un mensaje de autenticación: -1 si no empieza con el magic, 0 si es un WELCOME
## y un valor mayor que 0 ([enum NetProtocol.Result]) si es un REJECT.
static func peek_auth_result(bytes: PackedByteArray) -> int:
	if bytes.size() < 5 or bytes.decode_u32(0) != NetProtocol.MAGIC:
		return -1
	return bytes[4]


## true si los [param length] bytes desde [param offset] son UTF-8 válido y no contienen ningún
## byte nulo. [method String.get_string_from_utf8] registra un error con los bytes inválidos, así
## que los textos de la red se comprueban con esto antes de convertirlos.
static func is_valid_utf8(bytes: PackedByteArray, offset: int, length: int) -> bool:
	var end: int = offset + length
	if offset < 0 or length < 0 or end > bytes.size():
		return false
	var i: int = offset
	while i < end:
		var lead: int = bytes[i]
		if lead == 0:
			return false
		if lead < 0x80:
			i += 1
			continue
		var extra: int = 0
		var low: int = 0x80
		var high: int = 0xBF
		if lead >= 0xC2 and lead <= 0xDF:
			extra = 1
		elif lead == 0xE0:
			extra = 2
			low = 0xA0
		elif lead == 0xED:
			extra = 2
			high = 0x9F
		elif lead >= 0xE1 and lead <= 0xEF:
			extra = 2
		elif lead == 0xF0:
			extra = 3
			low = 0x90
		elif lead == 0xF4:
			extra = 3
			high = 0x8F
		elif lead >= 0xF1 and lead <= 0xF3:
			extra = 3
		else:
			return false
		if i + extra >= end:
			return false
		var second: int = bytes[i + 1]
		if second < low or second > high:
			return false
		for k: int in range(2, extra + 1):
			var continuation: int = bytes[i + k]
			if continuation < 0x80 or continuation > 0xBF:
				return false
		i += extra + 1
	return true


## [param text] en UTF-8, recortado a [param max_bytes] sin partir ningún carácter.
static func utf8_limited(text: String, max_bytes: int) -> PackedByteArray:
	var bytes: PackedByteArray = text.to_utf8_buffer()
	if bytes.size() <= max_bytes:
		return bytes
	var cut: int = max_bytes
	while cut > 0 and (bytes[cut] & 0xC0) == 0x80:
		cut -= 1
	return bytes.slice(0, cut)


## Texto UTF-8 de [param length] bytes desde [param offset]. Hay que haberlo validado antes con
## [method is_valid_utf8].
static func read_text(bytes: PackedByteArray, offset: int, length: int) -> String:
	if length <= 0:
		return ""
	return bytes.slice(offset, offset + length).get_string_from_utf8()


## true si los [param length] bytes desde [param offset] son ASCII imprimible (0x20-0x7E), como
## los ids de zona.
static func is_printable_ascii(bytes: PackedByteArray, offset: int, length: int) -> bool:
	for i: int in range(offset, offset + length):
		var value: int = bytes[i]
		if value < 0x20 or value > 0x7E:
			return false
	return true


## HELLO (C→S, autenticación): 23 B + nombre + billete.
class Hello:
	## Bit 0 de [member flags]: el cliente es un bot.
	const FLAG_BOT: int = 1 << 0
	const MIN_SIZE: int = 23

	var protocol_version: int = NetProtocol.PROTOCOL_VERSION
	var sim_hash: int = 0
	var realm: int = NetProtocol.Realm.NONE
	var flags: int = 0
	var character_id: int = 0
	var display_name: String = ""
	var ticket: PackedByteArray = PackedByteArray()


	func is_bot() -> bool:
		return (flags & FLAG_BOT) != 0


	func encode() -> PackedByteArray:
		var name_bytes: PackedByteArray = NetMessages.utf8_limited(display_name,
				NetProtocol.MAX_NAME_BYTES)
		var ticket_size: int = mini(ticket.size(), NetProtocol.MAX_TICKET_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(MIN_SIZE + name_bytes.size() + ticket_size)
		bytes.encode_u32(0, NetProtocol.MAGIC)
		bytes.encode_u16(4, protocol_version & 0xFFFF)
		bytes.encode_u32(6, sim_hash & 0xFFFFFFFF)
		bytes.encode_u8(10, realm & 0xFF)
		bytes.encode_u8(11, flags & 0xFF)
		bytes.encode_u64(12, character_id)
		bytes.encode_u8(20, name_bytes.size())
		for i: int in name_bytes.size():
			bytes[21 + i] = name_bytes[i]
		var ticket_offset: int = 21 + name_bytes.size()
		bytes.encode_u16(ticket_offset, ticket_size)
		for i: int in ticket_size:
			bytes[ticket_offset + 2 + i] = ticket[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> Hello:
		var size: int = bytes.size()
		if size < MIN_SIZE or bytes.decode_u32(0) != NetProtocol.MAGIC:
			return null
		var name_len: int = bytes.decode_u8(20)
		if name_len > NetProtocol.MAX_NAME_BYTES or size < 23 + name_len:
			return null
		var ticket_offset: int = 21 + name_len
		var ticket_len: int = bytes.decode_u16(ticket_offset)
		if ticket_len > NetProtocol.MAX_TICKET_BYTES or size != 23 + name_len + ticket_len:
			return null
		if not NetMessages.is_valid_utf8(bytes, 21, name_len):
			return null
		var hello := Hello.new()
		hello.protocol_version = bytes.decode_u16(4)
		hello.sim_hash = bytes.decode_u32(6)
		hello.realm = bytes.decode_u8(10)
		hello.flags = bytes.decode_u8(11)
		hello.character_id = bytes.decode_u64(12)
		hello.display_name = NetMessages.read_text(bytes, 21, name_len)
		hello.ticket = bytes.slice(ticket_offset + 2, ticket_offset + 2 + ticket_len)
		return hello


## WELCOME (S→C, autenticación): 18 B + id de zona.
class Welcome:
	const MIN_SIZE: int = 18

	var protocol_version: int = NetProtocol.PROTOCOL_VERSION
	var server_tick: int = 0
	var tick_rate: int = 60
	var snapshot_interval: int = NetProtocol.SNAPSHOT_INTERVAL_TICKS
	var max_input_batch: int = NetProtocol.MAX_INPUTS_PER_BATCH
	var max_rewind_ticks: int = NetProtocol.MAX_REWIND_TICKS
	var realm: int = NetProtocol.Realm.NONE
	var channel: int = 0
	var zone_id: String = ""


	func encode() -> PackedByteArray:
		var zone_bytes: PackedByteArray = zone_id.to_ascii_buffer()
		if zone_bytes.size() > NetProtocol.MAX_ZONE_ID_BYTES:
			zone_bytes = zone_bytes.slice(0, NetProtocol.MAX_ZONE_ID_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(MIN_SIZE + zone_bytes.size())
		bytes.encode_u32(0, NetProtocol.MAGIC)
		bytes.encode_u8(4, NetProtocol.Result.OK)
		bytes.encode_u16(5, protocol_version & 0xFFFF)
		bytes.encode_u32(7, server_tick & 0xFFFFFFFF)
		bytes.encode_u8(11, tick_rate & 0xFF)
		bytes.encode_u8(12, snapshot_interval & 0xFF)
		bytes.encode_u8(13, max_input_batch & 0xFF)
		bytes.encode_u8(14, max_rewind_ticks & 0xFF)
		bytes.encode_u8(15, realm & 0xFF)
		bytes.encode_u8(16, channel & 0xFF)
		bytes.encode_u8(17, zone_bytes.size())
		for i: int in zone_bytes.size():
			bytes[18 + i] = zone_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> Welcome:
		var size: int = bytes.size()
		if size < MIN_SIZE or bytes.decode_u32(0) != NetProtocol.MAGIC:
			return null
		if bytes.decode_u8(4) != NetProtocol.Result.OK:
			return null
		var zone_len: int = bytes.decode_u8(17)
		if zone_len > NetProtocol.MAX_ZONE_ID_BYTES or size != MIN_SIZE + zone_len:
			return null
		if not NetMessages.is_printable_ascii(bytes, 18, zone_len):
			return null
		var welcome := Welcome.new()
		welcome.protocol_version = bytes.decode_u16(5)
		welcome.server_tick = bytes.decode_u32(7)
		welcome.tick_rate = bytes.decode_u8(11)
		welcome.snapshot_interval = bytes.decode_u8(12)
		welcome.max_input_batch = bytes.decode_u8(13)
		welcome.max_rewind_ticks = bytes.decode_u8(14)
		welcome.realm = bytes.decode_u8(15)
		welcome.channel = bytes.decode_u8(16)
		welcome.zone_id = NetMessages.read_text(bytes, 18, zone_len)
		return welcome


## REJECT (S→C, autenticación): 6 B + texto.
class Reject:
	const MIN_SIZE: int = 6

	## Motivo ([enum NetProtocol.Result]); no puede ser OK.
	var result: int = NetProtocol.Result.MALFORMED
	var text: String = ""


	func encode() -> PackedByteArray:
		var text_bytes: PackedByteArray = NetMessages.utf8_limited(text,
				MAX_REJECT_TEXT_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(MIN_SIZE + text_bytes.size())
		bytes.encode_u32(0, NetProtocol.MAGIC)
		bytes.encode_u8(4, result & 0xFF)
		bytes.encode_u8(5, text_bytes.size())
		for i: int in text_bytes.size():
			bytes[6 + i] = text_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> Reject:
		var size: int = bytes.size()
		if size < MIN_SIZE or bytes.decode_u32(0) != NetProtocol.MAGIC:
			return null
		var result_code: int = bytes.decode_u8(4)
		if result_code == NetProtocol.Result.OK:
			return null
		var text_len: int = bytes.decode_u8(5)
		if size != MIN_SIZE + text_len or not NetMessages.is_valid_utf8(bytes, 6, text_len):
			return null
		var reject := Reject.new()
		reject.result = result_code
		reject.text = NetMessages.read_text(bytes, 6, text_len)
		return reject


## INPUT_BATCH (C→S, canal 1): 11 + 10·n B (n de 1 a 8).
## [br][br]
## Los ticks de los registros no viajan: el registro [i]i[/i] es del tick
## [code]newest_tick - count + 1 + i[/code], así que un lote con huecos ni siquiera se puede
## escribir. [method encode] devuelve un búfer vacío si [member inputs] no cumple eso.
class InputBatch:
	## `server_tick` del snapshot más nuevo recibido (0 = ninguno).
	var ack_snapshot_tick: int = 0
	## Retardo de interpolación actual × 8, en ticks.
	var interp_delay_q: int = 0
	## Tick de la entrada más nueva.
	var newest_tick: int = 0
	## De la más antigua a la más nueva, con ticks seguidos que acaban en [member newest_tick].
	var inputs: Array[PlayerInput] = []
	## Mismo tamaño que [member inputs]: (tick - render_tick visto) × 16, entre 0 y 65535.
	var view_offsets_q: PackedInt32Array = PackedInt32Array()


	func encode() -> PackedByteArray:
		var count: int = inputs.size()
		if count < 1 or count > NetProtocol.MAX_INPUTS_PER_BATCH or newest_tick < count:
			return PackedByteArray()
		var first_tick: int = newest_tick - count + 1
		for i: int in count:
			if inputs[i].tick != first_tick + i:
				return PackedByteArray()
		var bytes := PackedByteArray()
		bytes.resize(INPUT_BATCH_HEADER_SIZE + INPUT_RECORD_SIZE * count)
		bytes.encode_u8(0, NetProtocol.MSG_INPUT_BATCH)
		bytes.encode_u32(1, ack_snapshot_tick & 0xFFFFFFFF)
		bytes.encode_u8(5, clampi(interp_delay_q, 0, 255))
		bytes.encode_u32(6, newest_tick & 0xFFFFFFFF)
		bytes.encode_u8(10, count)
		for i: int in count:
			var offset: int = INPUT_BATCH_HEADER_SIZE + INPUT_RECORD_SIZE * i
			# Los bytes 4-11 de PlayerInput.encode() (move, look_yaw, look_pitch y buttons) son
			# los 8 primeros del registro.
			bytes.encode_u64(offset, inputs[i].encode().decode_u64(4))
			var view_offset: int = view_offsets_q[i] if i < view_offsets_q.size() else 0
			bytes.encode_u16(offset + 8, clampi(view_offset, 0, MAX_VIEW_OFFSET_Q))
		return bytes


	## Las entradas salen de [method PlayerInput.decode] (que normaliza los valores fuera de
	## rango) con los botones limitados a [constant NetProtocol.VALID_BUTTONS]. Exige
	## [code]count[/code] de 1 a 8, un tamaño exacto de [code]11 + 10 · count[/code] y
	## [code]newest_tick >= count[/code].
	static func decode(bytes: PackedByteArray) -> InputBatch:
		var size: int = bytes.size()
		if size < INPUT_BATCH_HEADER_SIZE + INPUT_RECORD_SIZE:
			return null
		if bytes[0] != NetProtocol.MSG_INPUT_BATCH:
			return null
		var count: int = bytes.decode_u8(10)
		if count < 1 or count > NetProtocol.MAX_INPUTS_PER_BATCH:
			return null
		if size != INPUT_BATCH_HEADER_SIZE + INPUT_RECORD_SIZE * count:
			return null
		var newest: int = bytes.decode_u32(6)
		if newest < count:
			return null
		var batch := InputBatch.new()
		batch.ack_snapshot_tick = bytes.decode_u32(1)
		batch.interp_delay_q = bytes.decode_u8(5)
		batch.newest_tick = newest
		batch.view_offsets_q.resize(count)
		# Los 12 B de PlayerInput.decode: el tick delante y los 8 primeros bytes del registro.
		var scratch := PackedByteArray()
		scratch.resize(PlayerInput.ENCODED_SIZE)
		for i: int in count:
			var offset: int = INPUT_BATCH_HEADER_SIZE + INPUT_RECORD_SIZE * i
			scratch.encode_u32(0, newest - count + 1 + i)
			scratch.encode_u64(4, bytes.decode_u64(offset))
			var input: PlayerInput = PlayerInput.decode(scratch)
			input.buttons &= NetProtocol.VALID_BUTTONS
			batch.inputs.append(input)
			batch.view_offsets_q[i] = bytes.decode_u16(offset + 8)
		return batch


## CLIENT_READY (C→S, canal 3): 2 B.
class ClientReady:
	## Reservado (0).
	var flags: int = 0


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_CLIENT_READY, flags & 0xFF])


	static func decode(bytes: PackedByteArray) -> ClientReady:
		if bytes.size() != 2 or bytes[0] != NetProtocol.MSG_CLIENT_READY:
			return null
		var ready := ClientReady.new()
		ready.flags = bytes[1]
		return ready


## CLIENT_LEAVE (C→S, canal 3): 2 B.
class ClientLeave:
	const REASON_QUIT: int = 0
	const REASON_ERROR: int = 1

	## 0 salir, 1 error.
	var reason: int = REASON_QUIT


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_CLIENT_LEAVE, reason & 0xFF])


	static func decode(bytes: PackedByteArray) -> ClientLeave:
		if bytes.size() != 2 or bytes[0] != NetProtocol.MSG_CLIENT_LEAVE:
			return null
		var leave := ClientLeave.new()
		leave.reason = bytes[1]
		return leave


## DEBUG_COMMAND (C→S, canal 3): 2 B + datos. El servidor solo lo acepta con
## [code]--debug-commands[/code].
class DebugCommand:
	## Bytes de datos de un teletransporte (3 × f32).
	const TELEPORT_PAYLOAD_SIZE: int = 12

	var command: int = 0
	var payload: PackedByteArray = PackedByteArray()


	## Comando de teletransporte a [param position] (14 B).
	static func teleport(position: Vector3) -> DebugCommand:
		var debug_command := DebugCommand.new()
		debug_command.command = NetProtocol.DEBUG_TELEPORT
		debug_command.payload.resize(TELEPORT_PAYLOAD_SIZE)
		debug_command.payload.encode_float(0, position.x)
		debug_command.payload.encode_float(4, position.y)
		debug_command.payload.encode_float(8, position.z)
		return debug_command


	## Posición de un comando de teletransporte ([constant NetProtocol.DEBUG_TELEPORT]).
	func get_teleport_position() -> Vector3:
		if payload.size() < TELEPORT_PAYLOAD_SIZE:
			return Vector3.ZERO
		return Vector3(payload.decode_float(0), payload.decode_float(4), payload.decode_float(8))


	func encode() -> PackedByteArray:
		var data_size: int = mini(payload.size(), MAX_DEBUG_PAYLOAD_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(2 + data_size)
		bytes.encode_u8(0, NetProtocol.MSG_DEBUG_COMMAND)
		bytes.encode_u8(1, command & 0xFF)
		for i: int in data_size:
			bytes[2 + i] = payload[i]
		return bytes


	## Un teletransporte exige exactamente [constant TELEPORT_PAYLOAD_SIZE] bytes de datos; los
	## demás comandos admiten hasta [constant NetMessages.MAX_DEBUG_PAYLOAD_BYTES].
	static func decode(bytes: PackedByteArray) -> DebugCommand:
		var size: int = bytes.size()
		if size < 2 or bytes[0] != NetProtocol.MSG_DEBUG_COMMAND:
			return null
		var data_size: int = size - 2
		if data_size > MAX_DEBUG_PAYLOAD_BYTES:
			return null
		if bytes[1] == NetProtocol.DEBUG_TELEPORT and data_size != TELEPORT_PAYLOAD_SIZE:
			return null
		var debug_command := DebugCommand.new()
		debug_command.command = bytes[1]
		debug_command.payload = bytes.slice(2)
		return debug_command


## SNAPSHOT (S→C, canal 2): cabecera de 49 B con estado propio o de 14 B sin él (en los dos
## casos, con el byte de [code]section_count[/code]) y secciones de registros de
## [constant EntityRecord.SIZE] B.
## [br][br]
## Cabecera: [code]u8 type, u32 server_tick, u32 input_ack_tick, s8 input_margin,
## u16 substitutions, u8 flags[/code] (bit 0 = estado propio; bits 1-2 = contador de
## teletransporte propio) y, si bit 0, el [PlayerState] sin cuantizar (35 B). Después,
## [code]u8 section_count[/code] y, por sección, [code]u8 kind, u8 count[/code] y los registros.
## Solo hay registros de jugador ([constant NetProtocol.EntityKind.PLAYER]) y de PNJ
## ([constant NetProtocol.EntityKind.NPC]) en la fase 2.
class Snapshot:
	var server_tick: int = 0
	var input_ack_tick: int = 0
	## Antelación mínima de las entradas desde el snapshot anterior, en [-127, 127]; -128 si no
	## hay datos.
	var input_margin: int = NetProtocol.NO_MARGIN
	## Entradas sustituidas, acumuladas (mod 65536).
	var substitutions: int = 0
	## Contador de teletransporte del jugador propio (mod 4).
	var own_teleport: int = 0
	## Estado propio del jugador, o null si el snapshot no lo trae.
	var own_state: PlayerState = null
	## Registros de las demás entidades, agrupados por sección en el orden del mensaje.
	var records: Array[EntityRecord] = []


	## Escribe la cabecera en [param bytes] sin crear ningún objeto y devuelve el offset donde
	## empieza [code]section_count[/code] (13 sin estado propio, 48 con él). Amplía el búfer si
	## es más corto que la cabecera y deja [code]section_count[/code] a 0: quien construye el
	## snapshot lo rellena después. [param own_state_bytes] es [code]PlayerState.encode()[/code]
	## ([constant PlayerState.ENCODED_SIZE] B) o un búfer vacío si no hay estado propio.
	static func write_header(bytes: PackedByteArray, server_tick: int, input_ack_tick: int,
			input_margin: int, substitutions: int, own_teleport: int,
			own_state_bytes: PackedByteArray) -> int:
		var has_state: bool = own_state_bytes.size() == PlayerState.ENCODED_SIZE
		var section_offset: int = 13 + (PlayerState.ENCODED_SIZE if has_state else 0)
		if bytes.size() < section_offset + 1:
			bytes.resize(section_offset + 1)
		bytes.encode_u8(0, NetProtocol.MSG_SNAPSHOT)
		bytes.encode_u32(1, server_tick & 0xFFFFFFFF)
		bytes.encode_u32(5, input_ack_tick & 0xFFFFFFFF)
		bytes.encode_s8(9, clampi(input_margin, -128, 127))
		bytes.encode_u16(10, substitutions & 0xFFFF)
		var flags: int = (own_teleport & TELEPORT_MASK) << TELEPORT_SHIFT
		if has_state:
			flags |= FLAG_OWN_STATE
			for i: int in PlayerState.ENCODED_SIZE:
				bytes[13 + i] = own_state_bytes[i]
		bytes.encode_u8(12, flags)
		bytes.encode_u8(section_offset, 0)
		return section_offset


	## Agrupa [member records] por [code]kind[/code] (en orden de aparición) en secciones de 255
	## registros como mucho. No limita el tamaño: quien lo construye respeta
	## [constant NetProtocol.MAX_PACKET_BYTES].
	func encode() -> PackedByteArray:
		var own_state_bytes: PackedByteArray = PackedByteArray()
		if own_state != null:
			own_state_bytes = own_state.encode()
		var by_kind: Dictionary = {}
		for record: EntityRecord in records:
			if not by_kind.has(record.kind):
				by_kind[record.kind] = []
			(by_kind[record.kind] as Array).append(record)
		var section_count: int = 0
		var total_size: int = SNAPSHOT_HEADER_SIZE_WITH_STATE \
				if own_state != null else SNAPSHOT_HEADER_SIZE
		for kind: int in by_kind:
			var group_size: int = (by_kind[kind] as Array).size()
			var group_sections: int = ceili(group_size / float(MAX_SECTION_RECORDS))
			section_count += group_sections
			total_size += 2 * group_sections + EntityRecord.SIZE * group_size
		var bytes := PackedByteArray()
		bytes.resize(total_size)
		var offset: int = write_header(bytes, server_tick, input_ack_tick, input_margin,
				substitutions, own_teleport, own_state_bytes)
		bytes.encode_u8(offset, mini(section_count, 255))
		offset += 1
		for kind: int in by_kind:
			var group: Array = by_kind[kind]
			var written: int = 0
			while written < group.size():
				var chunk: int = mini(group.size() - written, MAX_SECTION_RECORDS)
				bytes.encode_u8(offset, kind & 0xFF)
				bytes.encode_u8(offset + 1, chunk)
				offset += 2
				for i: int in chunk:
					(group[written + i] as EntityRecord).encode_into(bytes, offset)
					offset += EntityRecord.SIZE
				written += chunk
		return bytes


	static func decode(bytes: PackedByteArray) -> Snapshot:
		var size: int = bytes.size()
		if size < SNAPSHOT_HEADER_SIZE or bytes[0] != NetProtocol.MSG_SNAPSHOT:
			return null
		var flags: int = bytes.decode_u8(12)
		var offset: int = 13
		var state: PlayerState = null
		if (flags & FLAG_OWN_STATE) != 0:
			if size < SNAPSHOT_HEADER_SIZE_WITH_STATE:
				return null
			state = PlayerState.decode(bytes.slice(13, 13 + PlayerState.ENCODED_SIZE))
			offset += PlayerState.ENCODED_SIZE
		var section_count: int = bytes.decode_u8(offset)
		offset += 1
		var snapshot := Snapshot.new()
		snapshot.server_tick = bytes.decode_u32(1)
		snapshot.input_ack_tick = bytes.decode_u32(5)
		snapshot.input_margin = bytes.decode_s8(9)
		snapshot.substitutions = bytes.decode_u16(10)
		snapshot.own_teleport = (flags >> TELEPORT_SHIFT) & TELEPORT_MASK
		snapshot.own_state = state
		for _section: int in section_count:
			if offset + 2 > size:
				return null
			var kind: int = bytes[offset]
			var count: int = bytes[offset + 1]
			offset += 2
			if kind != NetProtocol.EntityKind.PLAYER and kind != NetProtocol.EntityKind.NPC:
				return null
			if offset + count * EntityRecord.SIZE > size:
				return null
			for _i: int in count:
				snapshot.records.append(EntityRecord.decode_from(bytes, offset, kind))
				offset += EntityRecord.SIZE
		if offset != size:
			return null
		return snapshot


## ENTITY_SPAWN (S→C, canal 3): 10 B + datos. Para un jugador o un PNJ, los datos son su
## [PlayerState] (35 B, el estado tras [member spawn_tick]), un `u8` con la longitud del nombre
## y el nombre (hasta 48 B).
class EntitySpawn:
	var net_id: int = 0
	var kind: int = NetProtocol.EntityKind.PLAYER
	var spawn_tick: int = 0
	var realm: int = NetProtocol.Realm.NONE
	## Bit 0 de los flags: es el personaje del propio cliente.
	var is_yours: bool = false
	## Contador de teletransporte (mod 4).
	var teleport_counter: int = 0
	var state: PlayerState = null
	var display_name: String = ""


	## Un búfer vacío si [member kind] no es jugador ni PNJ (no hay otros formatos en la fase 2).
	func encode() -> PackedByteArray:
		if kind != NetProtocol.EntityKind.PLAYER and kind != NetProtocol.EntityKind.NPC:
			return PackedByteArray()
		var state_bytes: PackedByteArray = (state if state != null else PlayerState.new()).encode()
		var name_bytes: PackedByteArray = NetMessages.utf8_limited(display_name,
				NetProtocol.MAX_NAME_BYTES)
		var bytes := PackedByteArray()
		var name_offset: int = SPAWN_HEADER_SIZE + PlayerState.ENCODED_SIZE
		bytes.resize(name_offset + 1 + name_bytes.size())
		bytes.encode_u8(0, NetProtocol.MSG_ENTITY_SPAWN)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u8(3, kind)
		bytes.encode_u32(4, spawn_tick & 0xFFFFFFFF)
		bytes.encode_u8(8, realm & 0xFF)
		var flags: int = (teleport_counter & TELEPORT_MASK) << TELEPORT_SHIFT
		if is_yours:
			flags |= 1
		bytes.encode_u8(9, flags)
		for i: int in PlayerState.ENCODED_SIZE:
			bytes[SPAWN_HEADER_SIZE + i] = state_bytes[i]
		bytes.encode_u8(name_offset, name_bytes.size())
		for i: int in name_bytes.size():
			bytes[name_offset + 1 + i] = name_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> EntitySpawn:
		var size: int = bytes.size()
		var name_offset: int = SPAWN_HEADER_SIZE + PlayerState.ENCODED_SIZE
		if size < name_offset + 1 or bytes[0] != NetProtocol.MSG_ENTITY_SPAWN:
			return null
		var kind_code: int = bytes[3]
		if kind_code != NetProtocol.EntityKind.PLAYER and kind_code != NetProtocol.EntityKind.NPC:
			return null
		var name_len: int = bytes[name_offset]
		if name_len > NetProtocol.MAX_NAME_BYTES or size != name_offset + 1 + name_len:
			return null
		if not NetMessages.is_valid_utf8(bytes, name_offset + 1, name_len):
			return null
		var spawn := EntitySpawn.new()
		spawn.net_id = bytes.decode_u16(1)
		spawn.kind = kind_code
		spawn.spawn_tick = bytes.decode_u32(4)
		spawn.realm = bytes[8]
		var flags: int = bytes[9]
		spawn.is_yours = (flags & 1) != 0
		spawn.teleport_counter = (flags >> TELEPORT_SHIFT) & TELEPORT_MASK
		spawn.state = PlayerState.decode(
				bytes.slice(SPAWN_HEADER_SIZE, name_offset))
		spawn.display_name = NetMessages.read_text(bytes, name_offset + 1, name_len)
		return spawn


## ENTITY_DESPAWN (S→C, canal 3): 8 B.
class EntityDespawn:
	const SIZE: int = 8

	var net_id: int = 0
	## El cliente quita la entidad cuando su `render_tick` llega a este tick.
	var despawn_tick: int = 0
	## [enum NetProtocol.DespawnReason].
	var reason: int = NetProtocol.DespawnReason.OUT_OF_INTEREST


	func encode() -> PackedByteArray:
		var bytes := PackedByteArray()
		bytes.resize(SIZE)
		bytes.encode_u8(0, NetProtocol.MSG_ENTITY_DESPAWN)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u32(3, despawn_tick & 0xFFFFFFFF)
		bytes.encode_u8(7, reason & 0xFF)
		return bytes


	static func decode(bytes: PackedByteArray) -> EntityDespawn:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_ENTITY_DESPAWN:
			return null
		var despawn := EntityDespawn.new()
		despawn.net_id = bytes.decode_u16(1)
		despawn.despawn_tick = bytes.decode_u32(3)
		despawn.reason = bytes[7]
		return despawn


## NOTICE (S→C, canal 3): 3 B + texto (hasta 200 B).
class Notice:
	const MIN_SIZE: int = 3

	## [enum NetProtocol.NoticeCode].
	var code: int = NetProtocol.NoticeCode.INFO
	var text: String = ""


	func encode() -> PackedByteArray:
		var text_bytes: PackedByteArray = NetMessages.utf8_limited(text, MAX_NOTICE_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(MIN_SIZE + text_bytes.size())
		bytes.encode_u8(0, NetProtocol.MSG_NOTICE)
		bytes.encode_u8(1, code & 0xFF)
		bytes.encode_u8(2, text_bytes.size())
		for i: int in text_bytes.size():
			bytes[3 + i] = text_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> Notice:
		var size: int = bytes.size()
		if size < MIN_SIZE or bytes[0] != NetProtocol.MSG_NOTICE:
			return null
		var text_len: int = bytes[2]
		if text_len > MAX_NOTICE_BYTES or size != MIN_SIZE + text_len:
			return null
		if not NetMessages.is_valid_utf8(bytes, 3, text_len):
			return null
		var notice := Notice.new()
		notice.code = bytes[1]
		notice.text = NetMessages.read_text(bytes, 3, text_len)
		return notice
