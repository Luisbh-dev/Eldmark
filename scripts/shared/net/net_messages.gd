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
## Tamaño del bloque extra propio de un SNAPSHOT (vida, vida máxima, estado y tick de
## reaparición), que va tras el estado propio.
const SNAPSHOT_EXTRA_SIZE: int = 9
## Tamaño de la cabecera de un SNAPSHOT con estado propio, con el estado, el bloque extra (que
## siempre acompaña al estado) y el byte de [code]section_count[/code].
const SNAPSHOT_HEADER_SIZE_WITH_STATE: int = \
		SNAPSHOT_HEADER_SIZE + PlayerState.ENCODED_SIZE + SNAPSHOT_EXTRA_SIZE
## Máximo de registros por sección (el contador es un u8).
const MAX_SECTION_RECORDS: int = 255
## Máximo de bytes del texto de un NOTICE.
const MAX_NOTICE_BYTES: int = 200
## Máximo de bytes del texto de un REJECT (el contador es un u8).
const MAX_REJECT_TEXT_BYTES: int = 255
## Máximo de bytes de datos de un DEBUG_COMMAND.
const MAX_DEBUG_PAYLOAD_BYTES: int = 64
## Máximo de campos de un OBJECT_STATE o del ENTITY_SPAWN de una estructura (el contador es un u8,
## pero la fase 4 no pasa de 17).
const MAX_OBJECT_FIELDS: int = 32
## Cabecera de un OBJECT_STATE: [code]u8 type, u16 net_id, u32 tick, u8 field_count[/code].
const OBJECT_STATE_HEADER_SIZE: int = 8
## Bytes que añade al ENTITY_SPAWN de un PNJ su [code]u16 npc_def_id[/code].
const NPC_SPAWN_TAIL_SIZE: int = 2
## Bytes del recuento por reino al final del WELCOME ([code]u8 × 3[/code]).
const WELCOME_REALM_COUNTS_SIZE: int = 3

## Bits de [code]status[/code] del bloque extra propio de un SNAPSHOT (y del estado compacto de un
## PARTY_STATUS).
const STATUS_IN_COMBAT: int = 1 << 0
const STATUS_PROTECTED: int = 1 << 1
const STATUS_DEAD: int = 1 << 2
## Derribado (protocolo 6; docs/habilidades.md, sección 5.2). Nunca va con [constant STATUS_DEAD]: un
## derribado no está muerto. Con él, la vida del bloque extra es la vida de derribado y la máxima, la de
## derribado de las reglas.
const STATUS_DOWNED: int = 1 << 3

## Bit 0 de los flags de un SNAPSHOT: trae el estado propio.
const FLAG_OWN_STATE: int = 1 << 0
## Bit 3 de los flags de un SNAPSHOT: trae el bloque extra propio. Va si y solo si va el estado
## propio (bit 0).
const FLAG_OWN_EXTRA: int = 1 << 3
## Desplazamiento y máscara del contador de teletransporte en los flags (2 bits).
const TELEPORT_SHIFT: int = 1
const TELEPORT_MASK: int = 0b11
## Cabecera de un INPUT_BATCH y tamaño de cada uno de sus registros.
const INPUT_BATCH_HEADER_SIZE: int = 11
const INPUT_RECORD_SIZE: int = 10
## Cabecera de un ENTITY_SPAWN, antes de los datos de la entidad.
const SPAWN_HEADER_SIZE: int = 10
## Bit 3 del [code]flags[/code] de la cabecera de un ENTITY_SPAWN (protocolo 7, docs/plataforma.md §5.4): el
## personaje es del personal del juego (moderador o más), para la etiqueta (SOC-14). No es el bit 3 de los
## [code]flags[/code] del registro del snapshot (la ranura 2 activa, de docs/habilidades.md).
const SPAWN_FLAG_STAFF: int = 1 << 3
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


## true si todos los caracteres de [param text] son ASCII imprimible (0x20-0x7E). Hay que comprobarlo
## antes de [method String.to_ascii_buffer], que registra un error del motor con otros caracteres.
static func is_printable_ascii_text(text: String) -> bool:
	for i: int in text.length():
		var code: int = text.unicode_at(i)
		if code < 0x20 or code > 0x7E:
			return false
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
## [method is_valid_utf8]. Ojo: [method PackedByteArray.get_string_from_utf8] se salta un BOM (EF BB BF) al
## principio, así que unos bytes no vacíos pueden leerse como una cadena vacía; quien exige un nombre lo
## comprueba después de leerlo.
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


## true si [param fields] se puede escribir en un OBJECT_STATE o en un ENTITY_SPAWN de estructura:
## de 1 a [constant MAX_OBJECT_FIELDS] campos, con tipo de valor conocido y sin ningún id repetido.
static func are_fields_encodable(fields: Array[ObjectField]) -> bool:
	if fields.size() < 1 or fields.size() > MAX_OBJECT_FIELDS:
		return false
	var seen: Dictionary = {}
	for field: ObjectField in fields:
		if field == null or ObjectField.size_of_type(field.value_type) == 0 \
				or seen.has(field.field_id):
			return false
		seen[field.field_id] = true
	return true


## Bytes que ocupan [param fields] ([code]2 + tamaño del valor[/code] cada uno).
static func fields_size(fields: Array[ObjectField]) -> int:
	var total: int = 0
	for field: ObjectField in fields:
		total += field.encoded_size()
	return total


## Escribe [param fields] en [param bytes] desde [param offset] (el búfer ya tiene el tamaño
## suficiente) y devuelve el offset siguiente.
static func write_fields(bytes: PackedByteArray, offset: int, fields: Array[ObjectField]) -> int:
	var cursor: int = offset
	for field: ObjectField in fields:
		cursor = field.write_to(bytes, cursor)
	return cursor


## Lee [param count] campos de [param bytes] desde [param offset] y los añade a [param out].
## Devuelve el offset siguiente, o -1 si un campo no cabe, tiene un tipo de valor desconocido o
## repite el id de otro. Un [code]field_id[/code] desconocido para quien lo lea se conserva (es
## quien lo interpreta quien lo salta). Nunca registra errores del motor.
static func read_fields(bytes: PackedByteArray, offset: int, count: int,
		out: Array[ObjectField]) -> int:
	var cursor: int = offset
	var seen: Dictionary = {}
	for _i: int in count:
		var field: ObjectField = ObjectField.read_from(bytes, cursor)
		if field == null or seen.has(field.field_id):
			return -1
		seen[field.field_id] = true
		out.append(field)
		cursor += field.encoded_size()
	return cursor


## Un campo de un OBJECT_STATE o del ENTITY_SPAWN de una estructura: [code]u8 field_id, u8
## value_type[/code] y el valor (docs/fuerte.md, sección 2). Los ids de campo los define quien
## replica el objeto ([FortressFields] para las fortalezas); aquí solo viajan.
class ObjectField:
	## Tipo del valor en el mensaje.
	enum ValueType { U8 = 1, U16 = 2, U32 = 3, S32 = 4 }

	## Cabecera de un campo: [code]u8 field_id, u8 value_type[/code].
	const HEADER_SIZE: int = 2

	var field_id: int = 0
	## [enum ValueType].
	var value_type: int = ValueType.U8
	var value: int = 0


	static func make(id: int, type: int, field_value: int) -> ObjectField:
		var field := ObjectField.new()
		field.field_id = id
		field.value_type = type
		field.value = field_value
		return field


	## Bytes del valor de un tipo ([param type]), o 0 si el tipo no existe.
	static func size_of_type(type: int) -> int:
		match type:
			ValueType.U8:
				return 1
			ValueType.U16:
				return 2
			ValueType.U32, ValueType.S32:
				return 4
		return 0


	## Bytes que ocupa el campo entero.
	func encoded_size() -> int:
		return HEADER_SIZE + size_of_type(value_type)


	## true si el tipo es conocido, el id cabe en un u8 y el valor cabe en el tipo.
	func is_valid() -> bool:
		if field_id < 0 or field_id > 0xFF:
			return false
		match value_type:
			ValueType.U8:
				return value >= 0 and value <= 0xFF
			ValueType.U16:
				return value >= 0 and value <= 0xFFFF
			ValueType.U32:
				return value >= 0 and value <= 0xFFFFFFFF
			ValueType.S32:
				return value >= -0x80000000 and value <= 0x7FFFFFFF
		return false


	## Escribe el campo en [param bytes] desde [param offset] (con sitio de sobra) y devuelve el
	## offset siguiente. Un valor que no cabe en su tipo se satura.
	func write_to(bytes: PackedByteArray, offset: int) -> int:
		bytes.encode_u8(offset, field_id & 0xFF)
		bytes.encode_u8(offset + 1, value_type)
		match value_type:
			ValueType.U8:
				bytes.encode_u8(offset + 2, clampi(value, 0, 0xFF))
			ValueType.U16:
				bytes.encode_u16(offset + 2, clampi(value, 0, 0xFFFF))
			ValueType.U32:
				bytes.encode_u32(offset + 2, clampi(value, 0, 0xFFFFFFFF))
			ValueType.S32:
				bytes.encode_s32(offset + 2, clampi(value, -0x80000000, 0x7FFFFFFF))
		return offset + encoded_size()


	## El campo que empieza en [param offset], o null si no cabe o su tipo de valor es desconocido.
	static func read_from(bytes: PackedByteArray, offset: int) -> ObjectField:
		if offset < 0 or offset + HEADER_SIZE > bytes.size():
			return null
		var type: int = bytes.decode_u8(offset + 1)
		var value_size: int = size_of_type(type)
		if value_size == 0 or offset + HEADER_SIZE + value_size > bytes.size():
			return null
		var field := ObjectField.new()
		field.field_id = bytes.decode_u8(offset)
		field.value_type = type
		match type:
			ValueType.U8:
				field.value = bytes.decode_u8(offset + 2)
			ValueType.U16:
				field.value = bytes.decode_u16(offset + 2)
			ValueType.U32:
				field.value = bytes.decode_u32(offset + 2)
			ValueType.S32:
				field.value = bytes.decode_s32(offset + 2)
		return field


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


## WELCOME (S→C, autenticación): 18 B + id de zona + 3 B con el recuento por reino.
## [br][br]
## Tras el id de zona van tres [code]u8[/code] con los jugadores de Vardheim, Solmarch y Askarra en
## la zona ([member realm_counts]), para que la selección de reino ofrezca el más corto (docs/fuerte.md,
## sección 7).
class Welcome:
	## Bytes sin el id de zona: la cabecera de 18 B y el recuento por reino.
	const MIN_SIZE: int = 18 + WELCOME_REALM_COUNTS_SIZE
	## Offset del id de zona.
	const ZONE_OFFSET: int = 18

	var protocol_version: int = NetProtocol.PROTOCOL_VERSION
	var server_tick: int = 0
	var tick_rate: int = 60
	var snapshot_interval: int = NetProtocol.SNAPSHOT_INTERVAL_TICKS
	var max_input_batch: int = NetProtocol.MAX_INPUTS_PER_BATCH
	var max_rewind_ticks: int = NetProtocol.MAX_REWIND_TICKS
	var realm: int = NetProtocol.Realm.NONE
	var channel: int = 0
	var zone_id: String = ""
	## Jugadores por reino en la zona: posición 0 = Vardheim, 1 = Solmarch, 2 = Askarra (un u8
	## cada una; saturan a 255).
	var realm_counts: PackedInt32Array = PackedInt32Array([0, 0, 0])


	## Jugadores del reino [param realm_code] ([enum NetProtocol.Realm], 1 a 3); 0 si el código no es
	## de un reino jugable.
	func get_realm_count(realm_code: int) -> int:
		var index: int = realm_code - 1
		if index < 0 or index >= realm_counts.size() or index >= WELCOME_REALM_COUNTS_SIZE:
			return 0
		return realm_counts[index]


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
			bytes[ZONE_OFFSET + i] = zone_bytes[i]
		var counts_offset: int = ZONE_OFFSET + zone_bytes.size()
		for i: int in WELCOME_REALM_COUNTS_SIZE:
			var count: int = realm_counts[i] if i < realm_counts.size() else 0
			bytes.encode_u8(counts_offset + i, clampi(count, 0, 0xFF))
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
		if not NetMessages.is_printable_ascii(bytes, ZONE_OFFSET, zone_len):
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
		welcome.zone_id = NetMessages.read_text(bytes, ZONE_OFFSET, zone_len)
		var counts_offset: int = ZONE_OFFSET + zone_len
		for i: int in WELCOME_REALM_COUNTS_SIZE:
			welcome.realm_counts[i] = bytes.decode_u8(counts_offset + i)
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
## [br][br]
## [method decode] valida los datos de los comandos con formato fijo: 1 [code]teleport[/code] exige
## 12 B; 7 [code]unstuck[/code], 8 [code]fort_reset[/code] y 10 [code]fort_kill_captain[/code], 0 B;
## 9 [code]fort_owner[/code], 1 B con el reino (0 a 3); 11 [code]fort_capture_speed[/code], 1 B con el
## factor (1 a 255); 12 [code]npc_debug[/code], 1 B (0 o 1). Desde el protocolo 6 (docs/habilidades.md,
## sección 5.1): 13 [code]cooldowns_off[/code], 1 B (0 o 1); 14 [code]apply_status[/code], 3 B
## ([code]u8 status_id[/code] de 1 a 255 y [code]u16[/code] ticks, 0 = los del dato); 15 [code]down[/code]
## y 16 [code]refill[/code], 0 B. Los comandos 2 a 6 los valida el servidor (hasta
## [constant NetMessages.MAX_DEBUG_PAYLOAD_BYTES]).
class DebugCommand:
	## Bytes de datos de un teletransporte (3 × f32).
	const TELEPORT_PAYLOAD_SIZE: int = 12
	## Bytes de datos de [constant NetProtocol.DEBUG_APPLY_STATUS]: [code]u8 status_id, u16 ticks[/code].
	const APPLY_STATUS_PAYLOAD_SIZE: int = 3
	## Reino más alto que admite [constant NetProtocol.DEBUG_FORT_OWNER].
	const MAX_FORT_OWNER_REALM: int = 3

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


	## Comando sin datos ([constant NetProtocol.DEBUG_UNSTUCK], [constant NetProtocol.DEBUG_FORT_RESET]
	## o [constant NetProtocol.DEBUG_FORT_KILL_CAPTAIN]; sirve para cualquier id).
	static func simple(command_id: int) -> DebugCommand:
		var debug_command := DebugCommand.new()
		debug_command.command = command_id
		return debug_command


	## Comando [constant NetProtocol.DEBUG_FORT_OWNER]: dar la fortaleza al reino [param realm_code].
	static func fort_owner(realm_code: int) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_FORT_OWNER)
		debug_command.payload = PackedByteArray([realm_code & 0xFF])
		return debug_command


	## Comando [constant NetProtocol.DEBUG_FORT_CAPTURE_SPEED]: multiplicar la captura por
	## [param factor] (de 1 a 255).
	static func fort_capture_speed(factor: int) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_FORT_CAPTURE_SPEED)
		debug_command.payload = PackedByteArray([factor & 0xFF])
		return debug_command


	## Comando [constant NetProtocol.DEBUG_NPC_DEBUG]: activar o apagar el registro de los PNJ.
	static func npc_debug(enabled: bool) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_NPC_DEBUG)
		debug_command.payload = PackedByteArray([1 if enabled else 0])
		return debug_command


	## Comando [constant NetProtocol.DEBUG_COOLDOWNS_OFF]: habilidades sin reutilización (o con ella otra
	## vez).
	static func cooldowns_off(enabled: bool) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_COOLDOWNS_OFF)
		debug_command.payload = PackedByteArray([1 if enabled else 0])
		return debug_command


	## Comando [constant NetProtocol.DEBUG_APPLY_STATUS]: aplicarse el efecto [param status_id] del catálogo
	## durante [param ticks] ticks (0 = la duración del dato; se satura a u16).
	static func apply_status(status_id: int, ticks: int = 0) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_APPLY_STATUS)
		debug_command.payload.resize(APPLY_STATUS_PAYLOAD_SIZE)
		debug_command.payload.encode_u8(0, status_id & 0xFF)
		debug_command.payload.encode_u16(1, clampi(ticks, 0, 0xFFFF))
		return debug_command


	## Id del efecto de un [constant NetProtocol.DEBUG_APPLY_STATUS] (0 si no trae sus datos).
	func get_status_id() -> int:
		return payload.decode_u8(0) if payload.size() == APPLY_STATUS_PAYLOAD_SIZE else 0


	## Ticks de un [constant NetProtocol.DEBUG_APPLY_STATUS] (0 = los del dato, o sin sus datos).
	func get_status_ticks() -> int:
		return payload.decode_u16(1) if payload.size() == APPLY_STATUS_PAYLOAD_SIZE else 0


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


	## Un teletransporte exige exactamente [constant TELEPORT_PAYLOAD_SIZE] bytes de datos y los
	## comandos 7 a 16 los de su formato (ver la descripción de la clase); los demás comandos
	## admiten hasta [constant NetMessages.MAX_DEBUG_PAYLOAD_BYTES].
	static func decode(bytes: PackedByteArray) -> DebugCommand:
		var size: int = bytes.size()
		if size < 2 or bytes[0] != NetProtocol.MSG_DEBUG_COMMAND:
			return null
		var data_size: int = size - 2
		if data_size > MAX_DEBUG_PAYLOAD_BYTES:
			return null
		if not _payload_is_valid(bytes[1], bytes.slice(2)):
			return null
		var debug_command := DebugCommand.new()
		debug_command.command = bytes[1]
		debug_command.payload = bytes.slice(2)
		return debug_command


	# Los comandos con formato fijo exigen sus datos; el resto de ids pasa tal cual (los valida quien
	# los ejecuta o los cuenta como desconocidos).
	static func _payload_is_valid(command_id: int, data: PackedByteArray) -> bool:
		match command_id:
			NetProtocol.DEBUG_TELEPORT:
				return data.size() == TELEPORT_PAYLOAD_SIZE
			NetProtocol.DEBUG_UNSTUCK, NetProtocol.DEBUG_FORT_RESET, \
					NetProtocol.DEBUG_FORT_KILL_CAPTAIN, NetProtocol.DEBUG_DOWN, NetProtocol.DEBUG_REFILL:
				return data.is_empty()
			NetProtocol.DEBUG_FORT_OWNER:
				return data.size() == 1 and data[0] <= MAX_FORT_OWNER_REALM
			NetProtocol.DEBUG_FORT_CAPTURE_SPEED:
				return data.size() == 1 and data[0] >= 1
			NetProtocol.DEBUG_NPC_DEBUG, NetProtocol.DEBUG_COOLDOWNS_OFF:
				return data.size() == 1 and data[0] <= 1
			NetProtocol.DEBUG_APPLY_STATUS:
				return data.size() == APPLY_STATUS_PAYLOAD_SIZE and data[0] >= 1
		return true


## SNAPSHOT (S→C, canal 2): cabecera de 14 B sin estado propio o, con él, de
## [constant SNAPSHOT_HEADER_SIZE_WITH_STATE] B (en los dos casos, con el byte de
## [code]section_count[/code]) y secciones de registros de [constant EntityRecord.SIZE] B.
## [br][br]
## Cabecera: [code]u8 type, u32 server_tick, u32 input_ack_tick, s8 input_margin,
## u16 substitutions, u8 flags[/code] (bit 0 = estado propio; bits 1-2 = contador de
## teletransporte propio; bit 3 = bloque extra propio) y, si bit 0, el [PlayerState] sin
## cuantizar ([constant PlayerState.ENCODED_SIZE] B) y el bloque extra propio de
## [constant SNAPSHOT_EXTRA_SIZE] B: [code]u16 health, u16 max_health, u8 status, u32
## respawn_tick[/code]. El bit 3 va si y solo si va el bit 0: [method decode] rechaza uno sin el
## otro. Después, [code]u8 section_count[/code] y, por sección, [code]u8 kind, u8 count[/code] y
## los registros. Solo hay registros de jugador ([constant NetProtocol.EntityKind.PLAYER]) y de
## PNJ ([constant NetProtocol.EntityKind.NPC]).
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
	## Bloque extra propio (solo con [member own_state]): vida del jugador propio.
	var health: int = 0
	## Bloque extra propio: vida máxima.
	var max_health: int = 0
	## Bloque extra propio: bits [constant NetMessages.STATUS_IN_COMBAT],
	## [constant NetMessages.STATUS_PROTECTED], [constant NetMessages.STATUS_DEAD] y
	## [constant NetMessages.STATUS_DOWNED].
	var status: int = 0
	## Bloque extra propio: tick en el que se puede pedir la reaparición (0 si está vivo).
	var respawn_tick: int = 0
	## Registros de las demás entidades, agrupados por sección en el orden del mensaje.
	var records: Array[EntityRecord] = []


	## true si el jugador propio está en combate (bit del bloque extra).
	func is_in_combat() -> bool:
		return (status & NetMessages.STATUS_IN_COMBAT) != 0


	## true si el jugador propio tiene la protección de reaparición.
	func is_protected() -> bool:
		return (status & NetMessages.STATUS_PROTECTED) != 0


	## true si el jugador propio está muerto.
	func is_dead() -> bool:
		return (status & NetMessages.STATUS_DEAD) != 0


	## true si el jugador propio está derribado: [member health] y [member max_health] son entonces la vida
	## de derribado y su máximo.
	func is_downed() -> bool:
		return (status & NetMessages.STATUS_DOWNED) != 0


	## Escribe la cabecera en [param bytes] sin crear ningún objeto y devuelve el offset donde
	## empieza [code]section_count[/code] (13 sin estado propio; con él, 13 más el estado y el
	## bloque extra). Amplía el búfer si es más corto que la cabecera y deja
	## [code]section_count[/code] a 0: quien construye el snapshot lo rellena después.
	## [param own_state_bytes] es [code]PlayerState.encode()[/code]
	## ([constant PlayerState.ENCODED_SIZE] B) o un búfer vacío si no hay estado propio. Con
	## estado propio se escribe también el bloque extra con [param health], [param max_health],
	## [param status] y [param respawn_tick]; sin él, esos cuatro se ignoran.
	static func write_header(bytes: PackedByteArray, server_tick: int, input_ack_tick: int,
			input_margin: int, substitutions: int, own_teleport: int,
			own_state_bytes: PackedByteArray, health: int = 0, max_health: int = 0,
			status: int = 0, respawn_tick: int = 0) -> int:
		var has_state: bool = own_state_bytes.size() == PlayerState.ENCODED_SIZE
		var extra_offset: int = 13 + PlayerState.ENCODED_SIZE
		var section_offset: int = 13
		if has_state:
			section_offset = extra_offset + SNAPSHOT_EXTRA_SIZE
		if bytes.size() < section_offset + 1:
			bytes.resize(section_offset + 1)
		bytes.encode_u8(0, NetProtocol.MSG_SNAPSHOT)
		bytes.encode_u32(1, server_tick & 0xFFFFFFFF)
		bytes.encode_u32(5, input_ack_tick & 0xFFFFFFFF)
		bytes.encode_s8(9, clampi(input_margin, -128, 127))
		bytes.encode_u16(10, substitutions & 0xFFFF)
		var flags: int = (own_teleport & TELEPORT_MASK) << TELEPORT_SHIFT
		if has_state:
			flags |= FLAG_OWN_STATE | FLAG_OWN_EXTRA
			for i: int in PlayerState.ENCODED_SIZE:
				bytes[13 + i] = own_state_bytes[i]
			bytes.encode_u16(extra_offset, clampi(health, 0, 0xFFFF))
			bytes.encode_u16(extra_offset + 2, clampi(max_health, 0, 0xFFFF))
			bytes.encode_u8(extra_offset + 4, status & 0xFF)
			bytes.encode_u32(extra_offset + 5, respawn_tick & 0xFFFFFFFF)
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
				substitutions, own_teleport, own_state_bytes, health, max_health, status,
				respawn_tick)
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


	## Devuelve null si el tamaño no cuadra, si el bit 3 de los flags (bloque extra) no coincide
	## con el bit 0 (estado propio) o si la vida es mayor que la máxima.
	static func decode(bytes: PackedByteArray) -> Snapshot:
		var size: int = bytes.size()
		if size < SNAPSHOT_HEADER_SIZE or bytes[0] != NetProtocol.MSG_SNAPSHOT:
			return null
		var flags: int = bytes.decode_u8(12)
		var has_state: bool = (flags & FLAG_OWN_STATE) != 0
		if has_state != ((flags & FLAG_OWN_EXTRA) != 0):
			return null
		var offset: int = 13
		var state: PlayerState = null
		var snapshot := Snapshot.new()
		if has_state:
			if size < SNAPSHOT_HEADER_SIZE_WITH_STATE:
				return null
			state = PlayerState.decode(bytes.slice(13, 13 + PlayerState.ENCODED_SIZE))
			offset += PlayerState.ENCODED_SIZE
			snapshot.health = bytes.decode_u16(offset)
			snapshot.max_health = bytes.decode_u16(offset + 2)
			snapshot.status = bytes.decode_u8(offset + 4)
			snapshot.respawn_tick = bytes.decode_u32(offset + 5)
			if snapshot.health > snapshot.max_health:
				return null
			offset += SNAPSHOT_EXTRA_SIZE
		var section_count: int = bytes.decode_u8(offset)
		offset += 1
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


## ENTITY_SPAWN (S→C, canal 3): 10 B + datos según el tipo de entidad ([member kind]):
## [br]- [code]PLAYER[/code]: su [PlayerState] ([constant PlayerState.ENCODED_SIZE] B, el estado tras
## [member spawn_tick]), un `u8` con la longitud del nombre y el nombre (hasta 48 B).
## [br]- [code]NPC[/code]: lo mismo que un jugador y, tras el nombre, un [code]u16 npc_def_id[/code]
## ([member npc_def_id]).
## [br]- [code]STRUCTURE[/code]: [code]u8 def_len[/code], el id de la definición en ASCII
## ([member definition_id]), [code]u8 field_count[/code] y los campos completos ([member fields]); no
## lleva estado de jugador ni nombre. Sin repetir type, net_id ni tick: son los de la cabecera.
## [br]- [code]PROJECTILE[/code] (protocolo 6; docs/habilidades.md, sección 5.3): 22 B tras la cabecera,
## [constant PROJECTILE_SIZE] en total: [code]u16 owner, u16 projectile_def_id, u16 source, u8
## volley_index, u8 proj_flags, u64 position, s16 × 3 velocity[/code]. [member net_id] es el del
## proyectil, [member realm] el del tirador y [member spawn_tick] el tick del disparo. Los flags de la
## cabecera van a 0: [member is_yours] nunca (una flecha es «tuya» si [member owner_id] es tu
## [code]net_id[/code]) y sin contador de teletransporte (un proyectil no se teletransporta). La posición
## ([member origin]) va empaquetada como en el registro de entidad (1 cm) y la velocidad
## ([member velocity]) en cm/s: lo mismo que [method Ballistics.quantize].
class EntitySpawn:
	## Bytes de un ENTITY_SPAWN de proyectil: la cabecera y sus 22 B.
	const PROJECTILE_SIZE: int = SPAWN_HEADER_SIZE + 22
	## Bit 0 de [member projectile_flags]: la flecha es inofensiva (vuela y choca con el mundo, pero no
	## prueba personajes). El resto de bits van a 0.
	const PROJECTILE_FLAG_HARMLESS: int = 1 << 0
	## Bits de [member projectile_flags] que existen.
	const PROJECTILE_FLAGS_VALID: int = PROJECTILE_FLAG_HARMLESS

	var net_id: int = 0
	var kind: int = NetProtocol.EntityKind.PLAYER
	var spawn_tick: int = 0
	var realm: int = NetProtocol.Realm.NONE
	## Bit 0 de los flags: es el personaje del propio cliente.
	var is_yours: bool = false
	## Contador de teletransporte (mod 4).
	var teleport_counter: int = 0
	## Bit 3 de los flags ([constant NetMessages.SPAWN_FLAG_STAFF], protocolo 7): personal del juego. Solo en
	## jugadores y PNJ.
	var is_staff: bool = false
	var state: PlayerState = null
	var display_name: String = ""
	## NPC: id de su definición en el catálogo de PNJ ([code]NpcCatalog[/code], ids 1..n por orden
	## alfabético; 0 = sin definición). Va tras el nombre.
	var npc_def_id: int = 0
	## STRUCTURE: id ASCII de la definición (por ejemplo [code]vado_gris_fort[/code]), de 1 a
	## [constant NetProtocol.MAX_DEFINITION_ID_BYTES] caracteres.
	var definition_id: String = ""
	## STRUCTURE: los campos completos del objeto (de 1 a [constant NetMessages.MAX_OBJECT_FIELDS]).
	var fields: Array[ObjectField] = []
	## PROJECTILE: [code]net_id[/code] del tirador.
	var owner_id: int = 0
	## PROJECTILE: id de su [ProjectileDefinition] en el catálogo de combate.
	var projectile_def_id: int = 0
	## PROJECTILE: fuente del ataque o la habilidad que la disparó ([CombatSource]).
	var source: int = 0
	## PROJECTILE: posición dentro del disparo (0 a n − 1; el abanico lanza varias a la vez).
	var volley_index: int = 0
	## PROJECTILE: combinación de los [code]PROJECTILE_FLAG_*[/code].
	var projectile_flags: int = 0
	## PROJECTILE: origen del vuelo ([code]p0[/code] de [method Ballistics.position]); se cuantiza a 1 cm.
	var origin: Vector3 = Vector3.ZERO
	## PROJECTILE: velocidad de salida ([code]v0[/code], m/s); se cuantiza a 1 cm/s.
	var velocity: Vector3 = Vector3.ZERO


	## SPAWN de la fortaleza [param net_id] con [param state] completo: tipo STRUCTURE, reino 0 (manda
	## el campo [code]owner[/code]) y todos los campos de [FortressFields].
	static func for_fortress(net_id: int, spawn_tick: int, definition_id: String,
			state: FortressState) -> EntitySpawn:
		var spawn := EntitySpawn.new()
		spawn.net_id = net_id
		spawn.kind = NetProtocol.EntityKind.STRUCTURE
		spawn.spawn_tick = spawn_tick
		spawn.definition_id = definition_id
		spawn.fields = ObjectState.from_fortress(net_id, spawn_tick, state).fields
		return spawn


	## SPAWN del proyectil [param net_id] disparado en [param spawn_tick] por [param shooter_id] (del reino
	## [param shooter_realm]) desde [param p0] con velocidad [param v0]. [param p0] y [param v0] deberían
	## venir ya de [method Ballistics.quantize] (el servidor vuela con lo que viaja), aunque el mensaje los
	## cuantiza igual.
	static func for_projectile(net_id: int, spawn_tick: int, shooter_realm: int, shooter_id: int,
			definition: int, source_of_shot: int, index_in_volley: int, harmless: bool, p0: Vector3,
			v0: Vector3) -> EntitySpawn:
		var spawn := EntitySpawn.new()
		spawn.net_id = net_id
		spawn.kind = NetProtocol.EntityKind.PROJECTILE
		spawn.spawn_tick = spawn_tick
		spawn.realm = shooter_realm
		spawn.owner_id = shooter_id
		spawn.projectile_def_id = definition
		spawn.source = source_of_shot
		spawn.volley_index = index_in_volley
		spawn.projectile_flags = PROJECTILE_FLAG_HARMLESS if harmless else 0
		spawn.origin = p0
		spawn.velocity = v0
		return spawn


	## true si es un proyectil inofensivo (bit [constant PROJECTILE_FLAG_HARMLESS]).
	func is_harmless() -> bool:
		return (projectile_flags & PROJECTILE_FLAG_HARMLESS) != 0


	## Los campos de un SPAWN de estructura como un [ObjectState] del tick de alta, para aplicarlos
	## igual que los de un OBJECT_STATE.
	func to_object_state() -> ObjectState:
		var object_state := ObjectState.new()
		object_state.net_id = net_id
		object_state.tick = spawn_tick
		object_state.fields = fields.duplicate()
		return object_state


	## Un búfer vacío si [member kind] no es jugador, PNJ, proyectil ni estructura, o si una estructura no
	## tiene un id de definición válido o campos que se puedan escribir.
	func encode() -> PackedByteArray:
		if kind == NetProtocol.EntityKind.STRUCTURE:
			return _encode_structure()
		if kind == NetProtocol.EntityKind.PROJECTILE:
			return _encode_projectile()
		if kind != NetProtocol.EntityKind.PLAYER and kind != NetProtocol.EntityKind.NPC:
			return PackedByteArray()
		var state_bytes: PackedByteArray = (state if state != null else PlayerState.new()).encode()
		var name_bytes: PackedByteArray = NetMessages.utf8_limited(display_name,
				NetProtocol.MAX_NAME_BYTES)
		var bytes := PackedByteArray()
		var name_offset: int = SPAWN_HEADER_SIZE + PlayerState.ENCODED_SIZE
		var tail_size: int = _tail_size(kind)
		bytes.resize(name_offset + 1 + name_bytes.size() + tail_size)
		bytes.encode_u8(0, NetProtocol.MSG_ENTITY_SPAWN)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u8(3, kind)
		bytes.encode_u32(4, spawn_tick & 0xFFFFFFFF)
		bytes.encode_u8(8, realm & 0xFF)
		var flags: int = (teleport_counter & TELEPORT_MASK) << TELEPORT_SHIFT
		if is_yours:
			flags |= 1
		if is_staff:
			flags |= SPAWN_FLAG_STAFF
		bytes.encode_u8(9, flags)
		for i: int in PlayerState.ENCODED_SIZE:
			bytes[SPAWN_HEADER_SIZE + i] = state_bytes[i]
		bytes.encode_u8(name_offset, name_bytes.size())
		for i: int in name_bytes.size():
			bytes[name_offset + 1 + i] = name_bytes[i]
		if tail_size > 0:
			bytes.encode_u16(name_offset + 1 + name_bytes.size(), npc_def_id & 0xFFFF)
		return bytes


	## Devuelve null si el tipo no tiene formato, si el tamaño no cuadra con el que dicen las
	## longitudes, si un texto no es válido o, en una estructura, si el id de la definición no es
	## ASCII de 1 a 32 B, el contador de campos no está entre 1 y 32, un campo tiene un tipo de valor
	## desconocido o se repite un id. Un proyectil, si no ocupa exactamente [constant PROJECTILE_SIZE] B,
	## trae algún flag en la cabecera (el bit [code]is_yours[/code] o un contador de teletransporte) o un bit
	## de [code]proj_flags[/code] que no existe.
	static func decode(bytes: PackedByteArray) -> EntitySpawn:
		var size: int = bytes.size()
		var name_offset: int = SPAWN_HEADER_SIZE + PlayerState.ENCODED_SIZE
		if size >= SPAWN_HEADER_SIZE and bytes[0] == NetProtocol.MSG_ENTITY_SPAWN \
				and bytes[3] == NetProtocol.EntityKind.STRUCTURE:
			return _decode_structure(bytes)
		if size >= SPAWN_HEADER_SIZE and bytes[0] == NetProtocol.MSG_ENTITY_SPAWN \
				and bytes[3] == NetProtocol.EntityKind.PROJECTILE:
			return _decode_projectile(bytes)
		if size < name_offset + 1 or bytes[0] != NetProtocol.MSG_ENTITY_SPAWN:
			return null
		var kind_code: int = bytes[3]
		if kind_code != NetProtocol.EntityKind.PLAYER and kind_code != NetProtocol.EntityKind.NPC:
			return null
		var name_len: int = bytes[name_offset]
		var tail_size: int = _tail_size(kind_code)
		if name_len > NetProtocol.MAX_NAME_BYTES or size != name_offset + 1 + name_len + tail_size:
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
		spawn.is_staff = (flags & SPAWN_FLAG_STAFF) != 0
		spawn.state = PlayerState.decode(
				bytes.slice(SPAWN_HEADER_SIZE, name_offset))
		spawn.display_name = NetMessages.read_text(bytes, name_offset + 1, name_len)
		if tail_size > 0:
			spawn.npc_def_id = bytes.decode_u16(name_offset + 1 + name_len)
		return spawn


	# Bytes que van tras el nombre: el id de definición de un PNJ y nada en un jugador.
	static func _tail_size(entity_kind: int) -> int:
		return NetMessages.NPC_SPAWN_TAIL_SIZE if entity_kind == NetProtocol.EntityKind.NPC else 0


	# STRUCTURE: u8 def_len, id ASCII, u8 field_count y los campos, tras la cabecera.
	func _encode_structure() -> PackedByteArray:
		if definition_id.is_empty() or definition_id.length() > NetProtocol.MAX_DEFINITION_ID_BYTES \
				or not NetMessages.is_printable_ascii_text(definition_id) \
				or not NetMessages.are_fields_encodable(fields):
			return PackedByteArray()
		var definition_bytes: PackedByteArray = definition_id.to_ascii_buffer()
		var bytes := PackedByteArray()
		var fields_offset: int = SPAWN_HEADER_SIZE + 2 + definition_bytes.size()
		bytes.resize(fields_offset + NetMessages.fields_size(fields))
		bytes.encode_u8(0, NetProtocol.MSG_ENTITY_SPAWN)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u8(3, kind)
		bytes.encode_u32(4, spawn_tick & 0xFFFFFFFF)
		bytes.encode_u8(8, realm & 0xFF)
		var flags: int = (teleport_counter & TELEPORT_MASK) << TELEPORT_SHIFT
		if is_yours:
			flags |= 1
		bytes.encode_u8(9, flags)
		bytes.encode_u8(SPAWN_HEADER_SIZE, definition_bytes.size())
		for i: int in definition_bytes.size():
			bytes[SPAWN_HEADER_SIZE + 1 + i] = definition_bytes[i]
		bytes.encode_u8(fields_offset - 1, fields.size())
		NetMessages.write_fields(bytes, fields_offset, fields)
		return bytes


	# PROJECTILE: 22 B tras la cabecera; los flags de la cabecera, a 0 (ni is_yours ni teletransporte).
	func _encode_projectile() -> PackedByteArray:
		var bytes := PackedByteArray()
		bytes.resize(PROJECTILE_SIZE)
		bytes.encode_u8(0, NetProtocol.MSG_ENTITY_SPAWN)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u8(3, kind)
		bytes.encode_u32(4, spawn_tick & 0xFFFFFFFF)
		bytes.encode_u8(8, realm & 0xFF)
		bytes.encode_u8(9, 0)
		bytes.encode_u16(10, owner_id & 0xFFFF)
		bytes.encode_u16(12, projectile_def_id & 0xFFFF)
		bytes.encode_u16(14, source & 0xFFFF)
		bytes.encode_u8(16, volley_index & 0xFF)
		bytes.encode_u8(17, projectile_flags & PROJECTILE_FLAGS_VALID)
		bytes.encode_u64(18, NetMath.pack_position(origin))
		bytes.encode_s16(26, NetMath.quantize_velocity(velocity.x))
		bytes.encode_s16(28, NetMath.quantize_velocity(velocity.y))
		bytes.encode_s16(30, NetMath.quantize_velocity(velocity.z))
		return bytes


	static func _decode_projectile(bytes: PackedByteArray) -> EntitySpawn:
		if bytes.size() != PROJECTILE_SIZE:
			return null
		var flags_of_projectile: int = bytes[17]
		if bytes[9] != 0 or (flags_of_projectile & ~PROJECTILE_FLAGS_VALID) != 0:
			return null
		var spawn := EntitySpawn.new()
		spawn.net_id = bytes.decode_u16(1)
		spawn.kind = NetProtocol.EntityKind.PROJECTILE
		spawn.spawn_tick = bytes.decode_u32(4)
		spawn.realm = bytes[8]
		spawn.is_yours = false
		spawn.owner_id = bytes.decode_u16(10)
		spawn.projectile_def_id = bytes.decode_u16(12)
		spawn.source = bytes.decode_u16(14)
		spawn.volley_index = bytes[16]
		spawn.projectile_flags = flags_of_projectile
		spawn.origin = NetMath.unpack_position(bytes.decode_u64(18))
		spawn.velocity = Vector3(NetMath.dequantize_velocity(bytes.decode_s16(26)),
				NetMath.dequantize_velocity(bytes.decode_s16(28)),
				NetMath.dequantize_velocity(bytes.decode_s16(30)))
		return spawn


	static func _decode_structure(bytes: PackedByteArray) -> EntitySpawn:
		var size: int = bytes.size()
		if size < SPAWN_HEADER_SIZE + 1:
			return null
		var definition_len: int = bytes[SPAWN_HEADER_SIZE]
		var count_offset: int = SPAWN_HEADER_SIZE + 1 + definition_len
		if definition_len < 1 or definition_len > NetProtocol.MAX_DEFINITION_ID_BYTES \
				or size < count_offset + 1:
			return null
		if not NetMessages.is_printable_ascii(bytes, SPAWN_HEADER_SIZE + 1, definition_len):
			return null
		var field_count: int = bytes[count_offset]
		if field_count < 1 or field_count > NetMessages.MAX_OBJECT_FIELDS:
			return null
		var spawn := EntitySpawn.new()
		var end: int = NetMessages.read_fields(bytes, count_offset + 1, field_count, spawn.fields)
		if end != size:
			return null
		spawn.net_id = bytes.decode_u16(1)
		spawn.kind = NetProtocol.EntityKind.STRUCTURE
		spawn.spawn_tick = bytes.decode_u32(4)
		spawn.realm = bytes[8]
		var flags: int = bytes[9]
		spawn.is_yours = (flags & 1) != 0
		spawn.teleport_counter = (flags >> TELEPORT_SHIFT) & TELEPORT_MASK
		spawn.definition_id = NetMessages.read_text(bytes, SPAWN_HEADER_SIZE + 1, definition_len)
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


## CHAT_SEND (C→S, canal 3, protocolo 5): 5 B + destinatario + texto (docs/social.md, sección 12).
## El jugador quiere decir algo por un canal.
## [br][br]
## [code]u8 type, u8 channel, u8 recipient_len, u16 text_len[/code], el destinatario (UTF-8, solo en un
## susurro: el nombre del personaje tal como lo escribió el jugador) y el texto (UTF-8). El texto lleva
## como mucho [constant ChatText.MAX_CHARS] caracteres y [constant ChatText.MAX_BYTES] B; el servidor lo
## sanea ([ChatText]) antes de repartirlo. Un mensaje, con todo, ocupa 821 B como mucho.
## [br][br]
## [method decode] devuelve null si el tamaño no cuadra, el canal no existe o es el del sistema (que solo
## envía el servidor), un susurro no lleva destinatario o cualquier otro canal lo lleva, algún texto no es
## UTF-8 válido, el destinatario pasa de [constant NetProtocol.MAX_NAME_CHARS] caracteres o el texto de
## [constant ChatText.MAX_CHARS]. Un texto vacío sí se decodifica: es el servidor quien decide qué hacer.
class ChatSend:
	## Bytes de la cabecera, antes del destinatario y el texto.
	const HEADER_SIZE: int = 5

	## [enum ChatChannel.Id].
	var channel: int = ChatChannel.Id.SAY
	## Nombre del destinatario (solo en un susurro; vacío en los demás canales).
	var recipient: String = ""
	var text: String = ""


	## Los textos se recortan a sus límites sin partir ningún carácter.
	func encode() -> PackedByteArray:
		var recipient_bytes: PackedByteArray = NetMessages.utf8_limited(
				recipient.substr(0, NetProtocol.MAX_NAME_CHARS), NetProtocol.MAX_NAME_BYTES)
		var text_bytes: PackedByteArray = NetMessages.utf8_limited(
				text.substr(0, ChatText.MAX_CHARS), ChatText.MAX_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE + recipient_bytes.size() + text_bytes.size())
		bytes.encode_u8(0, NetProtocol.MSG_CHAT_SEND)
		bytes.encode_u8(1, channel & 0xFF)
		bytes.encode_u8(2, recipient_bytes.size())
		bytes.encode_u16(3, text_bytes.size())
		for i: int in recipient_bytes.size():
			bytes[HEADER_SIZE + i] = recipient_bytes[i]
		var text_offset: int = HEADER_SIZE + recipient_bytes.size()
		for i: int in text_bytes.size():
			bytes[text_offset + i] = text_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> ChatSend:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_CHAT_SEND:
			return null
		var channel_id: int = bytes[1]
		var recipient_len: int = bytes[2]
		var text_len: int = bytes.decode_u16(3)
		if not ChatChannel.is_client_sendable(channel_id):
			return null
		if recipient_len > NetProtocol.MAX_NAME_BYTES or text_len > ChatText.MAX_BYTES \
				or size != HEADER_SIZE + recipient_len + text_len:
			return null
		if (channel_id == ChatChannel.Id.WHISPER) != (recipient_len > 0):
			return null
		if not NetMessages.is_valid_utf8(bytes, HEADER_SIZE, recipient_len) \
				or not NetMessages.is_valid_utf8(bytes, HEADER_SIZE + recipient_len, text_len):
			return null
		var message := ChatSend.new()
		message.channel = channel_id
		message.recipient = NetMessages.read_text(bytes, HEADER_SIZE, recipient_len)
		message.text = NetMessages.read_text(bytes, HEADER_SIZE + recipient_len, text_len)
		if message.recipient.length() > NetProtocol.MAX_NAME_CHARS \
				or message.text.length() > ChatText.MAX_CHARS:
			return null
		# Un nombre que se lee vacío (solo un BOM UTF-8, que get_string_from_utf8 se salta) no es un nombre.
		if channel_id == ChatChannel.Id.WHISPER and message.recipient.is_empty():
			return null
		return message


## CHAT_MESSAGE (S→C, canal 3, protocolo 5): 11 B + emisor + destinatario + texto (docs/social.md,
## sección 12). Un mensaje de chat ya saneado y repartido por el servidor, solo a quien debe verlo.
## [br][br]
## [code]u8 type, u8 channel, u8 sender_realm, u32 tick, u8 sender_len, u8 recipient_len, u16
## text_len[/code], el emisor (UTF-8), el destinatario (UTF-8, solo en un susurro) y el texto (UTF-8).
## [member tick] es el tick del servidor al repartirlo. En un susurro lo reciben los dos: el destinatario
## lo lee como un susurro de [member sender] y el emisor como la copia del que ha enviado. El del canal del
## sistema no lleva emisor. Con todo, ocupa 875 B como mucho.
## [br][br]
## [method decode] devuelve null si el tamaño no cuadra, el canal o el reino no existen, un mensaje del
## sistema lleva emisor o destinatario, otro canal no lleva emisor, solo un susurro lleva destinatario, el
## texto no es UTF-8 válido o pasa de [constant ChatText.MAX_CHARS] caracteres.
class ChatMessage:
	## Bytes de la cabecera, antes de los nombres y el texto.
	const HEADER_SIZE: int = 11

	## [enum ChatChannel.Id].
	var channel: int = ChatChannel.Id.SAY
	## Reino del emisor ([enum NetProtocol.Realm]); 0 en los mensajes del sistema.
	var sender_realm: int = NetProtocol.Realm.NONE
	## Tick del servidor al repartirlo.
	var tick: int = 0
	## Nombre del emisor (vacío en el canal del sistema).
	var sender: String = ""
	## Nombre del destinatario (solo en un susurro).
	var recipient: String = ""
	var text: String = ""


	func encode() -> PackedByteArray:
		var sender_bytes: PackedByteArray = NetMessages.utf8_limited(sender, NetProtocol.MAX_NAME_BYTES)
		var recipient_bytes: PackedByteArray = NetMessages.utf8_limited(recipient,
				NetProtocol.MAX_NAME_BYTES)
		var text_bytes: PackedByteArray = NetMessages.utf8_limited(
				text.substr(0, ChatText.MAX_CHARS), ChatText.MAX_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE + sender_bytes.size() + recipient_bytes.size() + text_bytes.size())
		bytes.encode_u8(0, NetProtocol.MSG_CHAT_MESSAGE)
		bytes.encode_u8(1, channel & 0xFF)
		bytes.encode_u8(2, sender_realm & 0xFF)
		bytes.encode_u32(3, tick & 0xFFFFFFFF)
		bytes.encode_u8(7, sender_bytes.size())
		bytes.encode_u8(8, recipient_bytes.size())
		bytes.encode_u16(9, text_bytes.size())
		var offset: int = HEADER_SIZE
		for part: PackedByteArray in [sender_bytes, recipient_bytes, text_bytes]:
			for i: int in part.size():
				bytes[offset + i] = part[i]
			offset += part.size()
		return bytes


	static func decode(bytes: PackedByteArray) -> ChatMessage:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_CHAT_MESSAGE:
			return null
		var channel_id: int = bytes[1]
		var realm: int = bytes[2]
		var sender_len: int = bytes[7]
		var recipient_len: int = bytes[8]
		var text_len: int = bytes.decode_u16(9)
		if not ChatChannel.is_valid(channel_id) or realm > NetProtocol.Realm.ASKARRA:
			return null
		if sender_len > NetProtocol.MAX_NAME_BYTES or recipient_len > NetProtocol.MAX_NAME_BYTES \
				or text_len > ChatText.MAX_BYTES \
				or size != HEADER_SIZE + sender_len + recipient_len + text_len:
			return null
		if (channel_id == ChatChannel.Id.SYSTEM) != (sender_len == 0):
			return null
		if (channel_id == ChatChannel.Id.WHISPER) != (recipient_len > 0):
			return null
		var recipient_offset: int = HEADER_SIZE + sender_len
		var text_offset: int = recipient_offset + recipient_len
		if not NetMessages.is_valid_utf8(bytes, HEADER_SIZE, sender_len) \
				or not NetMessages.is_valid_utf8(bytes, recipient_offset, recipient_len) \
				or not NetMessages.is_valid_utf8(bytes, text_offset, text_len):
			return null
		var message := ChatMessage.new()
		message.channel = channel_id
		message.sender_realm = realm
		message.tick = bytes.decode_u32(3)
		message.sender = NetMessages.read_text(bytes, HEADER_SIZE, sender_len)
		message.recipient = NetMessages.read_text(bytes, recipient_offset, recipient_len)
		message.text = NetMessages.read_text(bytes, text_offset, text_len)
		if message.text.length() > ChatText.MAX_CHARS:
			return null
		if (channel_id != ChatChannel.Id.SYSTEM and message.sender.is_empty()) \
				or (channel_id == ChatChannel.Id.WHISPER and message.recipient.is_empty()):
			return null
		return message


## PARTY_INVITE, PARTY_KICK y PARTY_LEADER (C→S, canal 3, protocolo 5): 2 B + nombre. Piden al servidor
## invitar a un jugador de tu reino, expulsar a un miembro del grupo o cederle el liderazgo
## (docs/social.md, sección 12.4).
## [br][br]
## [code]u8 type, u8 name_len[/code] y el nombre del jugador (UTF-8, de 1 a [constant NetProtocol.MAX_NAME_BYTES]
## B y [constant NetProtocol.MAX_NAME_CHARS] caracteres), tal como lo escribió quien manda: el servidor lo
## busca sin distinguir mayúsculas ni tildes. [member type] es el tipo de mensaje.
## [br][br]
## [method decode] devuelve null si el tipo no es uno de los tres, el tamaño no cuadra, el nombre está vacío
## o es demasiado largo, o no es UTF-8 válido.
class PartyTargetRequest:
	const HEADER_SIZE: int = 2

	## [constant NetProtocol.MSG_PARTY_INVITE], [constant NetProtocol.MSG_PARTY_KICK] o
	## [constant NetProtocol.MSG_PARTY_LEADER].
	var type: int = NetProtocol.MSG_PARTY_INVITE
	var target: String = ""


	static func make(message_type: int, target_name: String) -> PartyTargetRequest:
		var request := PartyTargetRequest.new()
		request.type = message_type
		request.target = target_name
		return request


	static func is_request_type(message_type: int) -> bool:
		return message_type == NetProtocol.MSG_PARTY_INVITE or message_type == NetProtocol.MSG_PARTY_KICK \
				or message_type == NetProtocol.MSG_PARTY_LEADER


	func encode() -> PackedByteArray:
		var name_bytes: PackedByteArray = NetMessages.utf8_limited(
				target.substr(0, NetProtocol.MAX_NAME_CHARS), NetProtocol.MAX_NAME_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE + name_bytes.size())
		bytes.encode_u8(0, type & 0xFF)
		bytes.encode_u8(1, name_bytes.size())
		for i: int in name_bytes.size():
			bytes[HEADER_SIZE + i] = name_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> PartyTargetRequest:
		var size: int = bytes.size()
		if size < HEADER_SIZE or not is_request_type(bytes[0]):
			return null
		var name_len: int = bytes[1]
		if name_len < 1 or name_len > NetProtocol.MAX_NAME_BYTES or size != HEADER_SIZE + name_len:
			return null
		if not NetMessages.is_valid_utf8(bytes, HEADER_SIZE, name_len):
			return null
		var request := PartyTargetRequest.new()
		request.type = bytes[0]
		request.target = NetMessages.read_text(bytes, HEADER_SIZE, name_len)
		if request.target.is_empty() or request.target.length() > NetProtocol.MAX_NAME_CHARS:
			return null
		return request


## PARTY_RESPONSE (C→S, canal 3, protocolo 5): 3 B + nombre. Acepta o rechaza la invitación de [member
## inviter] (docs/social.md, sección 12.4).
## [br][br]
## [code]u8 type, u8 accept, u8 name_len[/code] y el nombre de quien invitó. [member accept] es 1 (aceptar) o 0
## (rechazar). [method decode] devuelve null si el tamaño no cuadra, [code]accept[/code] no es 0 ni 1, el nombre
## está vacío o es demasiado largo, o no es UTF-8 válido.
class PartyResponse:
	const HEADER_SIZE: int = 3

	var accept: bool = false
	var inviter: String = ""


	func encode() -> PackedByteArray:
		var name_bytes: PackedByteArray = NetMessages.utf8_limited(
				inviter.substr(0, NetProtocol.MAX_NAME_CHARS), NetProtocol.MAX_NAME_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE + name_bytes.size())
		bytes.encode_u8(0, NetProtocol.MSG_PARTY_RESPONSE)
		bytes.encode_u8(1, 1 if accept else 0)
		bytes.encode_u8(2, name_bytes.size())
		for i: int in name_bytes.size():
			bytes[HEADER_SIZE + i] = name_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> PartyResponse:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_PARTY_RESPONSE or bytes[1] > 1:
			return null
		var name_len: int = bytes[2]
		if name_len < 1 or name_len > NetProtocol.MAX_NAME_BYTES or size != HEADER_SIZE + name_len:
			return null
		if not NetMessages.is_valid_utf8(bytes, HEADER_SIZE, name_len):
			return null
		var response := PartyResponse.new()
		response.accept = bytes[1] == 1
		response.inviter = NetMessages.read_text(bytes, HEADER_SIZE, name_len)
		if response.inviter.is_empty() or response.inviter.length() > NetProtocol.MAX_NAME_CHARS:
			return null
		return response


## PARTY_LEAVE (C→S, canal 3, protocolo 5): 1 B. El jugador sale de su grupo.
class PartyLeave:
	const SIZE: int = 1


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_PARTY_LEAVE])


	static func decode(bytes: PackedByteArray) -> PartyLeave:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_PARTY_LEAVE:
			return null
		return PartyLeave.new()


## PARTY_INVITATION (S→C, canal 3, protocolo 5): 7 B + nombre. Una invitación al grupo de [member inviter]:
## recién recibida, caducada o cancelada (docs/social.md, sección 12.4).
## [br][br]
## [code]u8 type, u8 state, u32 tick, u8 name_len[/code] y el nombre canónico de quien invitó. Con
## [constant State.OFFERED], [member tick] es el tick del servidor en el que caduca; con los demás estados,
## en el que dejó de valer. El cliente enseña el aviso con aceptar y rechazar mientras vale y lo quita con
## [constant State.EXPIRED] o [constant State.CANCELLED].
## [br][br]
## [method decode] devuelve null si el tamaño no cuadra, el estado no existe o el nombre está vacío, es demasiado
## largo o no es UTF-8 válido.
class PartyInvitation:
	const HEADER_SIZE: int = 7

	enum State {
		## Invitación nueva: el aviso se enseña hasta [member tick].
		OFFERED = 0,
		## Ha caducado (60 s sin responder).
		EXPIRED = 1,
		## Ya no vale: se ha respondido, o quien invitó ha salido o se ha ido.
		CANCELLED = 2,
	}

	var state: int = State.OFFERED
	var tick: int = 0
	var inviter: String = ""


	func encode() -> PackedByteArray:
		var name_bytes: PackedByteArray = NetMessages.utf8_limited(inviter, NetProtocol.MAX_NAME_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE + name_bytes.size())
		bytes.encode_u8(0, NetProtocol.MSG_PARTY_INVITATION)
		bytes.encode_u8(1, state & 0xFF)
		bytes.encode_u32(2, tick & 0xFFFFFFFF)
		bytes.encode_u8(6, name_bytes.size())
		for i: int in name_bytes.size():
			bytes[HEADER_SIZE + i] = name_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> PartyInvitation:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_PARTY_INVITATION or bytes[1] > State.CANCELLED:
			return null
		var name_len: int = bytes[6]
		if name_len < 1 or name_len > NetProtocol.MAX_NAME_BYTES or size != HEADER_SIZE + name_len:
			return null
		if not NetMessages.is_valid_utf8(bytes, HEADER_SIZE, name_len):
			return null
		var invitation := PartyInvitation.new()
		invitation.state = bytes[1]
		invitation.tick = bytes.decode_u32(2)
		invitation.inviter = NetMessages.read_text(bytes, HEADER_SIZE, name_len)
		if invitation.inviter.is_empty():
			return null
		return invitation


## PARTY_ROSTER (S→C, canal 3, protocolo 5): 3 B + 3 B y nombre por miembro (≤ 258 B). La lista de miembros del
## grupo del jugador, en el orden en que se unieron, con quién lleva el mando; el servidor la manda cada vez
## que cambia (entra o sale alguien, cambia el líder) y, con [member members] vacío, cuando el jugador deja de
## estar en un grupo (docs/social.md, sección 12.4).
## [br][br]
## [code]u8 type, u8 count, u8 leader_index[/code] (de 0 a [constant NetProtocol.PARTY_MAX_SIZE]) y, por
## miembro, [code]u16 net_id, u8 name_len[/code] y el nombre (UTF-8). [member leader_index] es la posición del
## líder en la lista (0 si no hay grupo).
## [br][br]
## [method decode] devuelve null si el tamaño no cuadra, hay más de [constant NetProtocol.PARTY_MAX_SIZE]
## miembros, el líder no es uno de ellos, un nombre está vacío o es demasiado largo o no es UTF-8 válido, o un
## net_id se repite.
class PartyRoster:
	const HEADER_SIZE: int = 3
	const MEMBER_HEADER_SIZE: int = 3

	## Un miembro: su id de red y su nombre.
	class Member:
		var net_id: int = 0
		var display_name: String = ""

		static func make(player_id: int, player_name: String) -> Member:
			var member := Member.new()
			member.net_id = player_id
			member.display_name = player_name
			return member

	var leader_index: int = 0
	var members: Array[Member] = []


	func is_empty() -> bool:
		return members.is_empty()


	## net_id del líder (0 si no hay grupo).
	func get_leader_id() -> int:
		if leader_index < 0 or leader_index >= members.size():
			return 0
		return members[leader_index].net_id


	func encode() -> PackedByteArray:
		var count: int = mini(members.size(), NetProtocol.PARTY_MAX_SIZE)
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE)
		bytes.encode_u8(0, NetProtocol.MSG_PARTY_ROSTER)
		bytes.encode_u8(1, count)
		bytes.encode_u8(2, leader_index & 0xFF)
		for i: int in count:
			var member: Member = members[i]
			var name_bytes: PackedByteArray = NetMessages.utf8_limited(member.display_name,
					NetProtocol.MAX_NAME_BYTES)
			var offset: int = bytes.size()
			bytes.resize(offset + MEMBER_HEADER_SIZE + name_bytes.size())
			bytes.encode_u16(offset, member.net_id & 0xFFFF)
			bytes.encode_u8(offset + 2, name_bytes.size())
			for k: int in name_bytes.size():
				bytes[offset + MEMBER_HEADER_SIZE + k] = name_bytes[k]
		return bytes


	static func decode(bytes: PackedByteArray) -> PartyRoster:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_PARTY_ROSTER:
			return null
		var count: int = bytes[1]
		var leader: int = bytes[2]
		if count > NetProtocol.PARTY_MAX_SIZE or (count == 0 and leader != 0) \
				or (count > 0 and leader >= count):
			return null
		var roster := PartyRoster.new()
		roster.leader_index = leader
		var offset: int = HEADER_SIZE
		var seen: Dictionary = {}
		for _i: int in count:
			if offset + MEMBER_HEADER_SIZE > size:
				return null
			var net_id: int = bytes.decode_u16(offset)
			var name_len: int = bytes[offset + 2]
			if name_len < 1 or name_len > NetProtocol.MAX_NAME_BYTES \
					or offset + MEMBER_HEADER_SIZE + name_len > size or seen.has(net_id):
				return null
			if not NetMessages.is_valid_utf8(bytes, offset + MEMBER_HEADER_SIZE, name_len):
				return null
			seen[net_id] = true
			var member_name: String = NetMessages.read_text(bytes, offset + MEMBER_HEADER_SIZE, name_len)
			if member_name.is_empty():
				return null
			roster.members.append(Member.make(net_id, member_name))
			offset += MEMBER_HEADER_SIZE + name_len
		if offset != size:
			return null
		return roster


## PARTY_STATUS (S→C, canal 3, protocolo 5): 2 B + 17 B por miembro (≤ 87 B). El estado compacto de los
## miembros del grupo, que el servidor manda a 2 Hz a todos los miembros aunque estén fuera del radio de
## interés de los demás (docs/social.md, sección 12.4; docs/red.md, sección 9).
## [br][br]
## [code]u8 type, u8 count[/code] y, por miembro, [code]u16 net_id, u8 health_q, u8 stamina_q, u8 status, f32 x,
## f32 y, f32 z[/code]. [member MemberStatus.health_q] es la vida cuantizada del registro del snapshot
## ([method EntityRecord.quantize_health]: 0 muerto, de 1 a 255 vivo), [member MemberStatus.stamina_q] la
## resistencia en 255 pasos y [member MemberStatus.status] los bits [constant STATUS_IN_COMBAT],
## [constant STATUS_PROTECTED], [constant STATUS_DEAD] y (protocolo 6) [constant STATUS_DOWNED].
## [br][br]
## [method decode] devuelve null si el tamaño no cuadra, hay más de [constant NetProtocol.PARTY_MAX_SIZE]
## miembros, un bit de estado es desconocido, una posición no es finita o un net_id se repite.
class PartyStatus:
	const HEADER_SIZE: int = 2
	const MEMBER_SIZE: int = 17
	## Bits de estado válidos.
	const VALID_STATUS: int = STATUS_IN_COMBAT | STATUS_PROTECTED | STATUS_DEAD | STATUS_DOWNED

	## El estado de un miembro.
	class MemberStatus:
		var net_id: int = 0
		var health_q: int = 0
		var stamina_q: int = 0
		var status: int = 0
		var position: Vector3 = Vector3.ZERO

		static func make(player_id: int, quantized_health: int, quantized_stamina: int,
				status_bits: int, world_position: Vector3) -> MemberStatus:
			var member := MemberStatus.new()
			member.net_id = player_id
			member.health_q = quantized_health
			member.stamina_q = quantized_stamina
			member.status = status_bits
			member.position = world_position
			return member

		func is_dead() -> bool:
			return (status & STATUS_DEAD) != 0

		func is_downed() -> bool:
			return (status & STATUS_DOWNED) != 0

	var members: Array[MemberStatus] = []


	func encoded_size() -> int:
		return HEADER_SIZE + MEMBER_SIZE * mini(members.size(), NetProtocol.PARTY_MAX_SIZE)


	func encode() -> PackedByteArray:
		var count: int = mini(members.size(), NetProtocol.PARTY_MAX_SIZE)
		var bytes := PackedByteArray()
		bytes.resize(encoded_size())
		bytes.encode_u8(0, NetProtocol.MSG_PARTY_STATUS)
		bytes.encode_u8(1, count)
		for i: int in count:
			var member: MemberStatus = members[i]
			var offset: int = HEADER_SIZE + MEMBER_SIZE * i
			bytes.encode_u16(offset, member.net_id & 0xFFFF)
			bytes.encode_u8(offset + 2, clampi(member.health_q, 0, 255))
			bytes.encode_u8(offset + 3, clampi(member.stamina_q, 0, 255))
			bytes.encode_u8(offset + 4, member.status & VALID_STATUS)
			bytes.encode_float(offset + 5, member.position.x)
			bytes.encode_float(offset + 9, member.position.y)
			bytes.encode_float(offset + 13, member.position.z)
		return bytes


	static func decode(bytes: PackedByteArray) -> PartyStatus:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_PARTY_STATUS:
			return null
		var count: int = bytes[1]
		if count > NetProtocol.PARTY_MAX_SIZE or size != HEADER_SIZE + MEMBER_SIZE * count:
			return null
		var status := PartyStatus.new()
		var seen: Dictionary = {}
		for i: int in count:
			var offset: int = HEADER_SIZE + MEMBER_SIZE * i
			var net_id: int = bytes.decode_u16(offset)
			var status_bits: int = bytes[offset + 4]
			var position := Vector3(bytes.decode_float(offset + 5), bytes.decode_float(offset + 9),
					bytes.decode_float(offset + 13))
			if (status_bits & ~VALID_STATUS) != 0 or not position.is_finite() or seen.has(net_id):
				return null
			seen[net_id] = true
			status.members.append(MemberStatus.make(net_id, bytes[offset + 2], bytes[offset + 3],
					status_bits, position))
		return status


## OBJECT_STATE (S→C, canal 3): 8 B + campos (docs/fuerte.md, sección 2). El estado replicado de un
## objeto que no es un jugador ni un PNJ, hoy el de una fortaleza.
## [br][br]
## [code]u8 type, u16 net_id, u32 tick, u8 field_count[/code] (de 1 a 32) y, por campo, [code]u8
## field_id, u8 value_type[/code] (1 u8, 2 u16, 3 u32, 4 s32) y el valor ([ObjectField]). [member tick]
## es el tick del servidor tras el que vale el estado. Un mensaje trae solo los campos que han
## cambiado; el estado completo viaja en el ENTITY_SPAWN de la estructura.
## [br][br]
## [method decode] devuelve null si el tamaño no cuadra, un [code]value_type[/code] es desconocido, el
## contador está fuera de 1 a 32 o se repite un campo. Un [code]field_id[/code] desconocido con un tipo
## válido se conserva: quien interpreta el objeto ([method apply_to_fortress]) lo salta, así que un
## servidor más nuevo puede añadir campos sin romper al cliente.
class ObjectState:
	## Id de red de la estructura.
	var net_id: int = 0
	## Tick del servidor tras el que vale el estado.
	var tick: int = 0
	var fields: Array[ObjectField] = []


	## Estado de la fortaleza [param state] con todos sus campos ([FortressFields.all_ids]).
	static func from_fortress(object_id: int, state_tick: int, state: FortressState) -> ObjectState:
		return from_fortress_fields(object_id, state_tick, state, FortressFields.all_ids())


	## Estado de la fortaleza [param state] con solo los campos [param field_ids].
	static func from_fortress_fields(object_id: int, state_tick: int, state: FortressState,
			field_ids: PackedInt32Array) -> ObjectState:
		var object_state := ObjectState.new()
		object_state.net_id = object_id
		object_state.tick = state_tick
		for field_id: int in field_ids:
			if not FortressFields.is_known(field_id):
				continue
			object_state.fields.append(ObjectField.make(field_id,
					FortressFields.value_type(field_id), FortressFields.get_value(state, field_id)))
		return object_state


	## Los campos de [param state] que han cambiado respecto a [param previous]
	## ([method FortressState.changed_fields_since]). Sin cambios, [member fields] queda vacío y
	## [method encode] devuelve un búfer vacío: no hay nada que mandar.
	static func from_fortress_changes(object_id: int, state_tick: int, state: FortressState,
			previous: FortressState) -> ObjectState:
		return from_fortress_fields(object_id, state_tick, state,
				state.changed_fields_since(previous))


	func add_field(field_id: int, type: int, field_value: int) -> void:
		fields.append(ObjectField.make(field_id, type, field_value))


	## El campo [param field_id], o null si el mensaje no lo trae.
	func get_field(field_id: int) -> ObjectField:
		for field: ObjectField in fields:
			if field.field_id == field_id:
				return field
		return null


	func has_field(field_id: int) -> bool:
		return get_field(field_id) != null


	## Valor del campo [param field_id], o [param default] si el mensaje no lo trae.
	func get_value(field_id: int, default: int = 0) -> int:
		var field: ObjectField = get_field(field_id)
		return field.value if field != null else default


	## Aplica los campos de [FortressFields] que trae el mensaje a [param state] y devuelve cuántos
	## ha aplicado. Salta los ids desconocidos (compatibilidad hacia delante) y los que traen otro
	## tipo de valor que el del campo.
	func apply_to_fortress(state: FortressState) -> int:
		var applied: int = 0
		for field: ObjectField in fields:
			if FortressFields.is_known(field.field_id) \
					and FortressFields.value_type(field.field_id) == field.value_type \
					and FortressFields.set_value(state, field.field_id, field.value):
				applied += 1
		return applied


	## true si todos los campos conocidos de [FortressFields] traen el tipo de valor que les
	## corresponde (los desconocidos no cuentan).
	func is_valid_for_fortress() -> bool:
		for field: ObjectField in fields:
			if FortressFields.is_known(field.field_id) \
					and FortressFields.value_type(field.field_id) != field.value_type:
				return false
		return true


	## Bytes que ocupa el mensaje.
	func encoded_size() -> int:
		return OBJECT_STATE_HEADER_SIZE + NetMessages.fields_size(fields)


	## Un búfer vacío si [member fields] no se puede escribir: sin campos, más de 32, con un tipo de
	## valor desconocido o con un id repetido.
	func encode() -> PackedByteArray:
		if not NetMessages.are_fields_encodable(fields):
			return PackedByteArray()
		var bytes := PackedByteArray()
		bytes.resize(encoded_size())
		bytes.encode_u8(0, NetProtocol.MSG_OBJECT_STATE)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u32(3, tick & 0xFFFFFFFF)
		bytes.encode_u8(7, fields.size())
		NetMessages.write_fields(bytes, OBJECT_STATE_HEADER_SIZE, fields)
		return bytes


	static func decode(bytes: PackedByteArray) -> ObjectState:
		var size: int = bytes.size()
		if size < OBJECT_STATE_HEADER_SIZE + ObjectField.HEADER_SIZE + 1 \
				or bytes[0] != NetProtocol.MSG_OBJECT_STATE:
			return null
		var field_count: int = bytes[7]
		if field_count < 1 or field_count > MAX_OBJECT_FIELDS:
			return null
		var object_state := ObjectState.new()
		var end: int = NetMessages.read_fields(bytes, OBJECT_STATE_HEADER_SIZE, field_count,
				object_state.fields)
		if end != size:
			return null
		object_state.net_id = bytes.decode_u16(1)
		object_state.tick = bytes.decode_u32(3)
		return object_state


## ENTITY_EVENT (S→C, canal 3): 9 B + datos según el evento (docs/combate.md, sección 6).
## [br][br]
## [code]u8 type, u16 net_id, u32 tick, u8 event, u8 len[/code] y [code]len[/code] bytes de
## datos. [member net_id] es la entidad a la que se ata el evento: la víctima en HIT, DEATH y
## KILL, y la entidad que reaparece en RESPAWN. [member tick] es el tick del servidor en que
## ocurrió.
## [br]- [code]HIT[/code] (17 B): [code]u16 attacker, u16 amount, u8 damage_type, u8 flags,
## u16 attack_id[/code]. Los flags son los [code]HIT_FLAG_*[/code].
## [br]- [code]DEATH[/code] (13 B): [code]u16 killer, u16 attack_id[/code] (killer 0 = el
## entorno).
## [br]- [code]KILL[/code] (14 + 2n B): [code]u16 killer, u16 attack_id, u8 n[/code] y
## [code]n × u16[/code] asistentes.
## [br]- [code]RESPAWN[/code] (10 B): [code]u8 point[/code].
## [br]- [code]WAR[/code] (11 B, docs/fuerte.md sección 5): [code]u8 war_event, u8 realm[/code].
## [member net_id] es la fortaleza; [member war_event] es un id de [WarEvents] y [member war_realm]
## el reino que lo acompaña ([method FortressState.event_realm]). Va a toda la zona y se aplica en el
## tick de dibujo.
## [br]- [code]TELEGRAPH[/code] (26 B): [code]u16 attack_id, u8 shape, u64 position, u16 yaw, u16
## radius_cm, u16 impact_in_ticks[/code]. [member net_id] es el PNJ que prepara el ataque, [member
## shape] 0 círculo o 1 sector, [member position] el origen (empaquetado como en el registro de
## entidad) y [member impact_in_ticks] los ticks que faltan para el golpe. Es un aviso: se aplica al
## llegar.
## [br][br]
## Desde el protocolo 6 (docs/habilidades.md, sección 5.4) el [code]attack_id[/code] de HIT, DEATH, KILL y
## TELEGRAPH es una [b]fuente[/b] ([CombatSource]: clase en los bits 14-15, id en 0-13; los ataques de la
## fase 3 conservan su número), y hay cinco eventos más:
## [br]- [code]STATUS[/code] (18 B): [code]u16 source_entity, u8 op, u8 status_id, u8 stacks, u32
## until_tick[/code]. [member net_id] es el afectado, [member source_entity] quien lo puso (0 = sin autor),
## [member op] 1 aplicado o renovado y 2 quitado ([enum StatusOp]) y [member until_tick] el fin (exclusivo).
## [br]- [code]HEAL[/code] (15 B): [code]u16 healer, u16 amount, u16 source[/code]. [member net_id] es el
## curado, [member healer] quien cura (0 = él mismo) y la fuente va en [member attack_id].
## [br]- [code]LOADOUT[/code] (15 B): [code]u8 template_id, u16 weapon_1, u16 weapon_2, u8 charges[/code].
## [member net_id] es el jugador; las armas, en orden de ranura (0 = ninguna); [member charges], las de las
## dos pociones (bits 0-3 y 4-7; 0 para quien no es el dueño).
## [br]- [code]DOWNED[/code] (13 B): [code]u16 attacker, u16 source[/code]. [member net_id] es el derribado;
## la fuente va en [member attack_id].
## [br]- [code]INTERACT[/code] (16 B): [code]u16 actor, u8 op, u32 end_tick[/code]. [member net_id] es el
## derribado, [member actor] quien lo levanta o lo remata, [member op] uno de [enum InteractOp] y
## [member end_tick] el tick en que acabaría.
## [br][br]
## Con [method hit], [method death], [method kill], [method respawn], [method war], [method telegraph],
## [method status], [method heal], [method loadout], [method downed] e [method interact] se crean ya
## rellenos.
class EntityEvent:
	## Evento ([member event]).
	enum Kind { HIT = 1, DEATH = 2, KILL = 3, RESPAWN = 4, WAR = 5, TELEGRAPH = 6, STATUS = 7, HEAL = 8,
			LOADOUT = 9, DOWNED = 10, INTERACT = 11 }
	## [member op] de un STATUS.
	enum StatusOp { APPLIED = 1, REMOVED = 2 }
	## [member op] de un INTERACT: empieza a levantar, levantar cortado, levantado, empieza a rematar y
	## rematar cortado.
	enum InteractOp { REVIVE = 1, REVIVE_CUT = 2, REVIVED = 3, EXECUTE = 4, EXECUTE_CUT = 5 }

	## Bytes de la cabecera, antes de los datos.
	const HEADER_SIZE: int = 9
	const HIT_DATA_SIZE: int = 8
	const DEATH_DATA_SIZE: int = 4
	const KILL_MIN_DATA_SIZE: int = 5
	const RESPAWN_DATA_SIZE: int = 1
	const WAR_DATA_SIZE: int = 2
	const TELEGRAPH_DATA_SIZE: int = 17
	const STATUS_DATA_SIZE: int = 9
	const HEAL_DATA_SIZE: int = 6
	const LOADOUT_DATA_SIZE: int = 6
	const DOWNED_DATA_SIZE: int = 4
	const INTERACT_DATA_SIZE: int = 7
	## Forma de un TELEGRAPH ([member shape]).
	const SHAPE_CIRCLE: int = 0
	const SHAPE_SECTOR: int = 1
	## Reino más alto que acompaña a un WAR (los códigos de [enum NetProtocol.Realm]).
	const MAX_WAR_REALM: int = 3
	## Máximo de asistentes de un KILL (cada uno hizo al menos el 10 % del daño, así que nunca
	## son más de 10).
	const MAX_ASSISTANTS: int = 16

	## Bits de [member hit_flags] de un HIT.
	const HIT_FLAG_CRITICAL: int = 1 << 0
	const HIT_FLAG_BLOCKED: int = 1 << 1
	const HIT_FLAG_PARRIED: int = 1 << 2
	const HIT_FLAG_GUARD_BREAK: int = 1 << 3
	const HIT_FLAG_LETHAL: int = 1 << 4
	## El golpe ha interrumpido a la víctima: beber, un lanzamiento marcado, levantar o rematar (protocolo
	## 6).
	const HIT_FLAG_INTERRUPTED: int = 1 << 5
	## El golpe ha derribado a la víctima (protocolo 6).
	const HIT_FLAG_DOWNED: int = 1 << 6

	## Entidad a la que se ata el evento (la víctima, o quien reaparece).
	var net_id: int = 0
	## Tick del servidor en que ocurrió.
	var tick: int = 0
	## [enum Kind].
	var event: int = Kind.HIT
	## HIT y DOWNED: net_id del atacante.
	var attacker: int = 0
	## HIT: daño que llegó a la vida (ya con bloqueo y armadura). HEAL: vida curada.
	var amount: int = 0
	## HIT: [enum DamageFormula.DamageType].
	var damage_type: int = 0
	## HIT: combinación de los [code]HIT_FLAG_*[/code].
	var hit_flags: int = 0
	## HIT, DEATH, KILL, TELEGRAPH, HEAL y DOWNED: la fuente ([CombatSource]); en un ataque, su id del
	## catálogo (el nombre es el de la fase 3, cuando solo había ataques).
	var attack_id: int = 0
	## DEATH y KILL: net_id de quien dio el golpe de gracia (0 = el entorno).
	var killer: int = 0
	## KILL: net_id de los asistentes.
	var assistants: PackedInt32Array = PackedInt32Array()
	## RESPAWN: índice del punto de reaparición.
	var point: int = 0
	## WAR: id de [WarEvents] ([constant WarEvents.FIRST] a [constant WarEvents.LAST]).
	var war_event: int = 0
	## WAR: código de reino que acompaña al aviso (0 = los Huecos / ninguno).
	var war_realm: int = 0
	## TELEGRAPH: [constant SHAPE_CIRCLE] o [constant SHAPE_SECTOR]. El id del ataque va en
	## [member attack_id].
	var shape: int = SHAPE_CIRCLE
	## TELEGRAPH: origen de la zona de peligro (cuantizado a 1 cm al codificar).
	var position: Vector3 = Vector3.ZERO
	## TELEGRAPH: giro de la zona, en radianes (se cuantiza a 16 bits).
	var yaw: float = 0.0
	## TELEGRAPH: radio (alcance) de la zona, en centímetros.
	var radius_cm: int = 0
	## TELEGRAPH: ticks que faltan hasta el impacto.
	var impact_in_ticks: int = 0
	## STATUS: net_id de quien puso el efecto (0 = sin autor).
	var source_entity: int = 0
	## STATUS ([enum StatusOp]) e INTERACT ([enum InteractOp]).
	var op: int = 0
	## STATUS: id del efecto en el catálogo de combate (1 a 255).
	var status_id: int = 0
	## STATUS: acumulaciones (al menos 1 si se aplica; 0 al quitarlo).
	var stacks: int = 0
	## STATUS: tick en que acaba (exclusivo).
	var until_tick: int = 0
	## HEAL: net_id de quien cura (0 = el propio curado).
	var healer: int = 0
	## LOADOUT: id de la plantilla de equipo.
	var template_id: int = 0
	## LOADOUT: armas en orden de ranura (0 = ninguna).
	var weapon_1: int = 0
	var weapon_2: int = 0
	## LOADOUT: cargas de las dos pociones (bits 0-3 y 4-7); 0 si no es el dueño quien lo recibe.
	var charges: int = 0
	## INTERACT: net_id de quien levanta o remata.
	var actor: int = 0
	## INTERACT: tick en que acabaría levantar o rematar.
	var end_tick: int = 0


	static func hit(victim_id: int, event_tick: int, attacker_id: int, damage: int,
			type_of_damage: int, flags: int, id_of_attack: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.HIT
		created.net_id = victim_id
		created.tick = event_tick
		created.attacker = attacker_id
		created.amount = damage
		created.damage_type = type_of_damage
		created.hit_flags = flags
		created.attack_id = id_of_attack
		return created


	static func death(victim_id: int, event_tick: int, killer_id: int,
			id_of_attack: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.DEATH
		created.net_id = victim_id
		created.tick = event_tick
		created.killer = killer_id
		created.attack_id = id_of_attack
		return created


	static func kill(victim_id: int, event_tick: int, killer_id: int, id_of_attack: int,
			assistant_ids: PackedInt32Array) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.KILL
		created.net_id = victim_id
		created.tick = event_tick
		created.killer = killer_id
		created.attack_id = id_of_attack
		created.assistants = assistant_ids
		return created


	static func respawn(entity_id: int, event_tick: int, point_index: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.RESPAWN
		created.net_id = entity_id
		created.tick = event_tick
		created.point = point_index
		return created


	## Aviso de guerra de la fortaleza [param fortress_id]: [param war_event_id] es un id de
	## [WarEvents] y [param realm_code] el reino que lo acompaña.
	static func war(fortress_id: int, event_tick: int, war_event_id: int,
			realm_code: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.WAR
		created.net_id = fortress_id
		created.tick = event_tick
		created.war_event = war_event_id
		created.war_realm = realm_code
		return created


	## Aviso del ataque [param id_of_attack] que prepara el PNJ [param npc_id].
	static func telegraph(npc_id: int, event_tick: int, id_of_attack: int, area_shape: int,
			origin: Vector3, area_yaw: float, area_radius_cm: int,
			ticks_to_impact: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.TELEGRAPH
		created.net_id = npc_id
		created.tick = event_tick
		created.attack_id = id_of_attack
		created.shape = area_shape
		created.position = origin
		created.yaw = area_yaw
		created.radius_cm = area_radius_cm
		created.impact_in_ticks = ticks_to_impact
		return created


	## Efecto [param id_of_status] aplicado o renovado ([constant StatusOp.APPLIED]) o quitado
	## ([constant StatusOp.REMOVED]) en [param target_id] por [param author_id] (0 = sin autor).
	static func status(target_id: int, event_tick: int, author_id: int, operation: int,
			id_of_status: int, stack_count: int, ends_at: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.STATUS
		created.net_id = target_id
		created.tick = event_tick
		created.source_entity = author_id
		created.op = operation
		created.status_id = id_of_status
		created.stacks = stack_count
		created.until_tick = ends_at
		return created


	## [param healed_amount] de vida curada a [param target_id] por [param healer_id] (0 = sí mismo) con la
	## fuente [param source].
	static func heal(target_id: int, event_tick: int, healer_id: int, healed_amount: int,
			source: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.HEAL
		created.net_id = target_id
		created.tick = event_tick
		created.healer = healer_id
		created.amount = healed_amount
		created.attack_id = source
		return created


	## Equipo de [param player_id]: la plantilla, sus armas en orden de ranura y las cargas de las pociones
	## (0 para quien no es el dueño).
	static func loadout(player_id: int, event_tick: int, id_of_template: int, first_weapon: int,
			second_weapon: int, consumable_charges: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.LOADOUT
		created.net_id = player_id
		created.tick = event_tick
		created.template_id = id_of_template
		created.weapon_1 = first_weapon
		created.weapon_2 = second_weapon
		created.charges = consumable_charges
		return created


	## [param victim_id] queda derribado por [param attacker_id] con la fuente [param source].
	static func downed(victim_id: int, event_tick: int, attacker_id: int, source: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.DOWNED
		created.net_id = victim_id
		created.tick = event_tick
		created.attacker = attacker_id
		created.attack_id = source
		return created


	## [param actor_id] empieza a levantar o a rematar al derribado [param downed_id], se le corta o acaba
	## ([param operation], de [enum InteractOp]); [param ends_at] es el tick en que acabaría.
	static func interact(downed_id: int, event_tick: int, actor_id: int, operation: int,
			ends_at: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.INTERACT
		created.net_id = downed_id
		created.tick = event_tick
		created.actor = actor_id
		created.op = operation
		created.end_tick = ends_at
		return created


	## La fuente del evento ([CombatSource]): el [member attack_id] de un HIT, DEATH, KILL, TELEGRAPH, HEAL o
	## DOWNED; 0 en los demás.
	func get_source() -> int:
		match event:
			Kind.HIT, Kind.DEATH, Kind.KILL, Kind.TELEGRAPH, Kind.HEAL, Kind.DOWNED:
				return attack_id
		return CombatSource.NONE


	## Radio de un TELEGRAPH en metros.
	func get_radius() -> float:
		return radius_cm / 100.0


	## true si [member hit_flags] tiene el bit [param flag] (un [code]HIT_FLAG_*[/code]).
	func has_hit_flag(flag: int) -> bool:
		return (hit_flags & flag) != 0


	## Bytes de datos que ocupa el evento, o -1 si [member event] no es un [enum Kind].
	func data_size() -> int:
		match event:
			Kind.HIT:
				return HIT_DATA_SIZE
			Kind.DEATH:
				return DEATH_DATA_SIZE
			Kind.KILL:
				return KILL_MIN_DATA_SIZE + 2 * mini(assistants.size(), MAX_ASSISTANTS)
			Kind.RESPAWN:
				return RESPAWN_DATA_SIZE
			Kind.WAR:
				return WAR_DATA_SIZE
			Kind.TELEGRAPH:
				return TELEGRAPH_DATA_SIZE
			Kind.STATUS:
				return STATUS_DATA_SIZE
			Kind.HEAL:
				return HEAL_DATA_SIZE
			Kind.LOADOUT:
				return LOADOUT_DATA_SIZE
			Kind.DOWNED:
				return DOWNED_DATA_SIZE
			Kind.INTERACT:
				return INTERACT_DATA_SIZE
		return -1


	## Un búfer vacío si [member event] no es un [enum Kind]. Un KILL con más de
	## [constant MAX_ASSISTANTS] asistentes se recorta.
	func encode() -> PackedByteArray:
		var size_of_data: int = data_size()
		if size_of_data < 0:
			return PackedByteArray()
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE + size_of_data)
		bytes.encode_u8(0, NetProtocol.MSG_ENTITY_EVENT)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u32(3, tick & 0xFFFFFFFF)
		bytes.encode_u8(7, event)
		bytes.encode_u8(8, size_of_data)
		match event:
			Kind.HIT:
				bytes.encode_u16(9, attacker & 0xFFFF)
				bytes.encode_u16(11, clampi(amount, 0, 0xFFFF))
				bytes.encode_u8(13, damage_type & 0xFF)
				bytes.encode_u8(14, hit_flags & 0xFF)
				bytes.encode_u16(15, attack_id & 0xFFFF)
			Kind.DEATH:
				bytes.encode_u16(9, killer & 0xFFFF)
				bytes.encode_u16(11, attack_id & 0xFFFF)
			Kind.KILL:
				var count: int = mini(assistants.size(), MAX_ASSISTANTS)
				bytes.encode_u16(9, killer & 0xFFFF)
				bytes.encode_u16(11, attack_id & 0xFFFF)
				bytes.encode_u8(13, count)
				for i: int in count:
					bytes.encode_u16(14 + 2 * i, assistants[i] & 0xFFFF)
			Kind.RESPAWN:
				bytes.encode_u8(9, point & 0xFF)
			Kind.WAR:
				bytes.encode_u8(9, war_event & 0xFF)
				bytes.encode_u8(10, war_realm & 0xFF)
			Kind.TELEGRAPH:
				bytes.encode_u16(9, attack_id & 0xFFFF)
				bytes.encode_u8(11, shape & 0xFF)
				bytes.encode_u64(12, NetMath.pack_position(position))
				bytes.encode_u16(20, NetMath.quantize_yaw16(yaw))
				bytes.encode_u16(22, clampi(radius_cm, 0, 0xFFFF))
				bytes.encode_u16(24, clampi(impact_in_ticks, 0, 0xFFFF))
			Kind.STATUS:
				bytes.encode_u16(9, source_entity & 0xFFFF)
				bytes.encode_u8(11, op & 0xFF)
				bytes.encode_u8(12, status_id & 0xFF)
				bytes.encode_u8(13, clampi(stacks, 0, 0xFF))
				bytes.encode_u32(14, until_tick & 0xFFFFFFFF)
			Kind.HEAL:
				bytes.encode_u16(9, healer & 0xFFFF)
				bytes.encode_u16(11, clampi(amount, 0, 0xFFFF))
				bytes.encode_u16(13, attack_id & 0xFFFF)
			Kind.LOADOUT:
				bytes.encode_u8(9, template_id & 0xFF)
				bytes.encode_u16(10, weapon_1 & 0xFFFF)
				bytes.encode_u16(12, weapon_2 & 0xFFFF)
				bytes.encode_u8(14, charges & 0xFF)
			Kind.DOWNED:
				bytes.encode_u16(9, attacker & 0xFFFF)
				bytes.encode_u16(11, attack_id & 0xFFFF)
			Kind.INTERACT:
				bytes.encode_u16(9, actor & 0xFFFF)
				bytes.encode_u8(11, op & 0xFF)
				bytes.encode_u32(12, end_tick & 0xFFFFFFFF)
		return bytes


	## Devuelve null si el tipo, el evento, la longitud declarada o el tamaño total no cuadran
	## (HIT 8 B de datos, DEATH 4, RESPAWN 1, WAR 2, TELEGRAPH 17, KILL 5 + 2n con el n declarado y n
	## a lo sumo [constant MAX_ASSISTANTS], STATUS 9, HEAL 6, LOADOUT 6, DOWNED 4 e INTERACT 7), si un WAR
	## trae un aviso que no es de [WarEvents] o un reino mayor que 3, si un TELEGRAPH trae una forma que no
	## es 0 ni 1, si un STATUS o un INTERACT traen un [member op] que no existe o si un STATUS aplicado
	## trae 0 acumulaciones.
	static func decode(bytes: PackedByteArray) -> EntityEvent:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_ENTITY_EVENT:
			return null
		var event_code: int = bytes[7]
		var declared: int = bytes[8]
		if size != HEADER_SIZE + declared:
			return null
		var parsed := EntityEvent.new()
		parsed.net_id = bytes.decode_u16(1)
		parsed.tick = bytes.decode_u32(3)
		parsed.event = event_code
		match event_code:
			Kind.HIT:
				if declared != HIT_DATA_SIZE:
					return null
				parsed.attacker = bytes.decode_u16(9)
				parsed.amount = bytes.decode_u16(11)
				parsed.damage_type = bytes.decode_u8(13)
				parsed.hit_flags = bytes.decode_u8(14)
				parsed.attack_id = bytes.decode_u16(15)
			Kind.DEATH:
				if declared != DEATH_DATA_SIZE:
					return null
				parsed.killer = bytes.decode_u16(9)
				parsed.attack_id = bytes.decode_u16(11)
			Kind.KILL:
				if declared < KILL_MIN_DATA_SIZE:
					return null
				var count: int = bytes.decode_u8(13)
				if count > MAX_ASSISTANTS or declared != KILL_MIN_DATA_SIZE + 2 * count:
					return null
				parsed.killer = bytes.decode_u16(9)
				parsed.attack_id = bytes.decode_u16(11)
				for i: int in count:
					parsed.assistants.append(bytes.decode_u16(14 + 2 * i))
			Kind.RESPAWN:
				if declared != RESPAWN_DATA_SIZE:
					return null
				parsed.point = bytes.decode_u8(9)
			Kind.WAR:
				if declared != WAR_DATA_SIZE:
					return null
				parsed.war_event = bytes.decode_u8(9)
				parsed.war_realm = bytes.decode_u8(10)
				if not WarEvents.is_valid(parsed.war_event) or parsed.war_realm > MAX_WAR_REALM:
					return null
			Kind.TELEGRAPH:
				if declared != TELEGRAPH_DATA_SIZE:
					return null
				parsed.attack_id = bytes.decode_u16(9)
				parsed.shape = bytes.decode_u8(11)
				if parsed.shape != SHAPE_CIRCLE and parsed.shape != SHAPE_SECTOR:
					return null
				parsed.position = NetMath.unpack_position(bytes.decode_u64(12))
				parsed.yaw = NetMath.dequantize_yaw16(bytes.decode_u16(20))
				parsed.radius_cm = bytes.decode_u16(22)
				parsed.impact_in_ticks = bytes.decode_u16(24)
			Kind.STATUS:
				if declared != STATUS_DATA_SIZE:
					return null
				parsed.source_entity = bytes.decode_u16(9)
				parsed.op = bytes.decode_u8(11)
				parsed.status_id = bytes.decode_u8(12)
				parsed.stacks = bytes.decode_u8(13)
				parsed.until_tick = bytes.decode_u32(14)
				if parsed.op != StatusOp.APPLIED and parsed.op != StatusOp.REMOVED:
					return null
				if parsed.op == StatusOp.APPLIED and parsed.stacks == 0:
					return null
			Kind.HEAL:
				if declared != HEAL_DATA_SIZE:
					return null
				parsed.healer = bytes.decode_u16(9)
				parsed.amount = bytes.decode_u16(11)
				parsed.attack_id = bytes.decode_u16(13)
			Kind.LOADOUT:
				if declared != LOADOUT_DATA_SIZE:
					return null
				parsed.template_id = bytes.decode_u8(9)
				parsed.weapon_1 = bytes.decode_u16(10)
				parsed.weapon_2 = bytes.decode_u16(12)
				parsed.charges = bytes.decode_u8(14)
			Kind.DOWNED:
				if declared != DOWNED_DATA_SIZE:
					return null
				parsed.attacker = bytes.decode_u16(9)
				parsed.attack_id = bytes.decode_u16(11)
			Kind.INTERACT:
				if declared != INTERACT_DATA_SIZE:
					return null
				parsed.actor = bytes.decode_u16(9)
				parsed.op = bytes.decode_u8(11)
				parsed.end_tick = bytes.decode_u32(12)
				if parsed.op < InteractOp.REVIVE or parsed.op > InteractOp.EXECUTE_CUT:
					return null
			_:
				return null
		return parsed


## RESPAWN_REQUEST (C→S, canal 3): 2 B. El jugador muerto pide reaparecer en el punto
## [member point_index] de la lista de puntos de su reino (docs/combate.md, sección 5). Fuera de
## plazo o con un índice inválido el servidor cuenta un aviso.
class RespawnRequest:
	const SIZE: int = 2

	var point_index: int = 0


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_RESPAWN_REQUEST, point_index & 0xFF])


	static func decode(bytes: PackedByteArray) -> RespawnRequest:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_RESPAWN_REQUEST:
			return null
		var request := RespawnRequest.new()
		request.point_index = bytes[1]
		return request


## UNSTUCK_REQUEST (C→S, canal 3): 1 B. El jugador pide /atascado (docs/fuerte.md, sección 5): es un
## mensaje propio y vale sin [code]--debug-commands[/code]. El servidor decide si procede (fuera de
## combate, 5 min de reutilización...).
class UnstuckRequest:
	const SIZE: int = 1


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_UNSTUCK_REQUEST])


	static func decode(bytes: PackedByteArray) -> UnstuckRequest:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_UNSTUCK_REQUEST:
			return null
		return UnstuckRequest.new()


## LOADOUT_SELECT (C→S, canal 3, protocolo 6): 2 B, [code]u8 type, u8 template_id[/code]. La plantilla de
## equipo que el jugador quiere para su siguiente aparición (docs/habilidades.md, secciones 4.6 y 5.1). Vale
## desde el WELCOME, también antes de CLIENT_READY. [member template_id] es un id del catálogo de combate
## ([method CombatCatalog.template_id]) o 0, la de por defecto; el servidor cuenta un aviso si no existe o
## no se puede elegir. [method decode] solo comprueba el tamaño y el tipo.
class LoadoutSelect:
	const SIZE: int = 2

	var template_id: int = 0


	static func make(id_of_template: int) -> LoadoutSelect:
		var select := LoadoutSelect.new()
		select.template_id = id_of_template
		return select


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_LOADOUT_SELECT, template_id & 0xFF])


	static func decode(bytes: PackedByteArray) -> LoadoutSelect:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_LOADOUT_SELECT:
			return null
		return LoadoutSelect.make(bytes[1])


## Una fila del marcador: lo que cuenta de un jugador (docs/fuerte.md, sección 6), 18 B.
## [code]u16 net_id, u16 kills, u16 deaths, u16 assists, u32 gate_damage, u16 circle_seconds, u32
## merits[/code]. Los contadores saturan a su máximo al codificar.
class ScoreRow:
	const SIZE: int = 18

	var net_id: int = 0
	## Bajas.
	var kills: int = 0
	## Muertes.
	var deaths: int = 0
	## Asistencias.
	var assists: int = 0
	## Daño hecho a la puerta de la fortaleza.
	var gate_damage: int = 0
	## Segundos pasados dentro del círculo de captura.
	var circle_seconds: int = 0
	## Méritos.
	var merits: int = 0


	static func make(player_id: int, kill_count: int, death_count: int, assist_count: int,
			damage_to_gate: int, seconds_in_circle: int, merit_points: int) -> ScoreRow:
		var row := ScoreRow.new()
		row.net_id = player_id
		row.kills = kill_count
		row.deaths = death_count
		row.assists = assist_count
		row.gate_damage = damage_to_gate
		row.circle_seconds = seconds_in_circle
		row.merits = merit_points
		return row


	func write_to(bytes: PackedByteArray, offset: int) -> void:
		bytes.encode_u16(offset, net_id & 0xFFFF)
		bytes.encode_u16(offset + 2, clampi(kills, 0, 0xFFFF))
		bytes.encode_u16(offset + 4, clampi(deaths, 0, 0xFFFF))
		bytes.encode_u16(offset + 6, clampi(assists, 0, 0xFFFF))
		bytes.encode_u32(offset + 8, clampi(gate_damage, 0, 0xFFFFFFFF))
		bytes.encode_u16(offset + 12, clampi(circle_seconds, 0, 0xFFFF))
		bytes.encode_u32(offset + 14, clampi(merits, 0, 0xFFFFFFFF))


	static func read_from(bytes: PackedByteArray, offset: int) -> ScoreRow:
		var row := ScoreRow.new()
		row.net_id = bytes.decode_u16(offset)
		row.kills = bytes.decode_u16(offset + 2)
		row.deaths = bytes.decode_u16(offset + 4)
		row.assists = bytes.decode_u16(offset + 6)
		row.gate_damage = bytes.decode_u32(offset + 8)
		row.circle_seconds = bytes.decode_u16(offset + 12)
		row.merits = bytes.decode_u32(offset + 14)
		return row


## SCOREBOARD (S→C, canal 3): 4 B + 18 B por fila (docs/fuerte.md, sección 6). El marcador de la zona,
## cada 2 s a todos los jugadores.
## [br][br]
## [code]u8 type, u8 page_index, u8 page_count, u8 row_count[/code] y [code]row_count[/code] filas
## ([ScoreRow]). Una página no pasa de [constant MAX_ROWS] filas (el mensaje cabe en
## [constant NetProtocol.MAX_PACKET_BYTES]); con más jugadores el marcador se parte en varias páginas
## ([method split]), que el cliente junta por [member page_index] de [member page_count].
class Scoreboard:
	## Cabecera: type, página, total de páginas y filas.
	const HEADER_SIZE: int = 4
	## Filas por página: ⌊(1200 − 4) / 18⌋ = 66, un mensaje de 1192 B.
	const MAX_ROWS: int = 66
	## Máximo de páginas (el total es un u8).
	const MAX_PAGES: int = 255

	## Índice de esta página, desde 0.
	var page_index: int = 0
	## Total de páginas del marcador (de 1 a 255).
	var page_count: int = 1
	var rows: Array[ScoreRow] = []


	## Parte [param all_rows] en páginas de hasta [constant MAX_ROWS] filas, en orden. Con ninguna
	## fila devuelve una sola página vacía (el cliente vacía el marcador). Lo que pase de
	## [constant MAX_PAGES] páginas se descarta.
	static func split(all_rows: Array[ScoreRow]) -> Array[Scoreboard]:
		var pages: Array[Scoreboard] = []
		var total: int = clampi(ceili(all_rows.size() / float(MAX_ROWS)), 1, MAX_PAGES)
		for page: int in total:
			var board := Scoreboard.new()
			board.page_index = page
			board.page_count = total
			var first: int = page * MAX_ROWS
			for i: int in range(first, mini(first + MAX_ROWS, all_rows.size())):
				board.rows.append(all_rows[i])
			pages.append(board)
		return pages


	## Bytes que ocupa el mensaje.
	func encoded_size() -> int:
		return HEADER_SIZE + ScoreRow.SIZE * rows.size()


	## Un búfer vacío si hay más de [constant MAX_ROWS] filas o la página no es válida (el total fuera
	## de 1 a 255 o [member page_index] no menor que él): quien manda usa [method split].
	func encode() -> PackedByteArray:
		if rows.size() > MAX_ROWS or page_count < 1 or page_count > MAX_PAGES \
				or page_index < 0 or page_index >= page_count:
			return PackedByteArray()
		var bytes := PackedByteArray()
		bytes.resize(encoded_size())
		bytes.encode_u8(0, NetProtocol.MSG_SCOREBOARD)
		bytes.encode_u8(1, page_index)
		bytes.encode_u8(2, page_count)
		bytes.encode_u8(3, rows.size())
		for i: int in rows.size():
			rows[i].write_to(bytes, HEADER_SIZE + ScoreRow.SIZE * i)
		return bytes


	## Devuelve null si el tamaño no es exactamente el de la cabecera más [code]row_count[/code]
	## filas, si hay más de [constant MAX_ROWS], si el total de páginas es 0 o si el índice no es
	## menor que el total.
	static func decode(bytes: PackedByteArray) -> Scoreboard:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_SCOREBOARD:
			return null
		var board := Scoreboard.new()
		board.page_index = bytes[1]
		board.page_count = bytes[2]
		var row_count: int = bytes[3]
		if board.page_count < 1 or board.page_index >= board.page_count or row_count > MAX_ROWS:
			return null
		if size != HEADER_SIZE + ScoreRow.SIZE * row_count:
			return null
		for i: int in row_count:
			board.rows.append(ScoreRow.read_from(bytes, HEADER_SIZE + ScoreRow.SIZE * i))
		return board
