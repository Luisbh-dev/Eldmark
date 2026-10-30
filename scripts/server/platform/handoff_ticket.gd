class_name HandoffTicket
extends RefCounted
## El billete de entrada de 52 B (docs/plataforma.md §5.1): solo identidad, firmado por la plataforma con
## HMAC-SHA256 truncado a 16 B y una clave con identificador. Va en el campo [code]ticket[/code] del HELLO.
## [br][br]
## [codeblock]
## offset  tipo  campo         notas
##  0      u8    version       1
##  1      u8    key_id        clave de ELDMARK_TICKET_KEYS (1–255)
##  2      u16   world_id
##  4      u64   ticket_id     aleatorio, bit 63 a 0 (en JSON, cadena)
## 12      u64   character_id  igual que HELLO.character_id
## 20      u32   zone_key      zone_key_of(id de la zona)
## 24      u8    channel
## 25      u8    realm         informativo: manda la reclamación
## 26      u8    arrival       0 = lo decide la zona; n ≥ 1 = punto n − 1 (fase 6)
## 27      u8    flags         bit0 entrada desde el menú; bit1 traspaso (fase 6)
## 28      u32   issued_at     Unix, s
## 32      u32   expires_at    issued_at + 10
## 36      16 B  mac           HMAC-SHA256(clave, bytes 0..35), 16 primeros bytes
## [/codeblock]
## Todo little-endian. Los vectores de prueba los genera la plataforma en Go
## ([code]tests/fixtures/tickets/handoff_ticket_vectors.json[/code]) y las dos partes dan lo mismo. La
## comprobación de la zona ([TicketAuthProvider]) usa [method decode], [method verify] y los campos.

const SIZE: int = 52
const VERSION: int = 1
## Bytes firmados (todo menos la firma).
const SIGNED_SIZE: int = 36
const MAC_SIZE: int = 16
## Bits de [member flags].
const FLAG_FROM_MENU: int = 1 << 0
const FLAG_HANDOFF: int = 1 << 1

var version: int = VERSION
var key_id: int = 0
var world_id: int = 0
var ticket_id: int = 0
var character_id: int = 0
var zone_key: int = 0
var channel: int = 0
var realm: int = 0
var arrival: int = 0
var flags: int = 0
var issued_at: int = 0
var expires_at: int = 0


## La huella u32 de [param zone_id]: los 4 primeros bytes, como u32 little-endian, del SHA-256 del id en ASCII.
## Es el [code]zone_key[/code] del billete y el [code]ref_id[/code] de PNJ y fortalezas en el libro
## (docs/progresion.md §5.2). [code]vado_gris[/code] da 0x19efc013.
static func zone_key_of(zone_id: String) -> int:
	# String.sha256_buffer() resume el UTF-8 del texto, que en un id ASCII son los mismos bytes.
	return zone_id.sha256_buffer().decode_u32(0)


## Lee los campos de [param bytes]; null si no son 52 B o la versión no es la 1. No mira la firma: para eso,
## [method verify].
static func decode(bytes: PackedByteArray) -> HandoffTicket:
	if bytes.size() != SIZE or bytes.decode_u8(0) != VERSION:
		return null
	var ticket := HandoffTicket.new()
	ticket.version = bytes.decode_u8(0)
	ticket.key_id = bytes.decode_u8(1)
	ticket.world_id = bytes.decode_u16(2)
	ticket.ticket_id = bytes.decode_u64(4)
	ticket.character_id = bytes.decode_u64(12)
	ticket.zone_key = bytes.decode_u32(20)
	ticket.channel = bytes.decode_u8(24)
	ticket.realm = bytes.decode_u8(25)
	ticket.arrival = bytes.decode_u8(26)
	ticket.flags = bytes.decode_u8(27)
	ticket.issued_at = bytes.decode_u32(28)
	ticket.expires_at = bytes.decode_u32(32)
	return ticket


## true si [param bytes] (los mismos 52 B de los que salió este billete) llevan la firma de la clave
## [member key_id] de [param keys] ([code]{key_id: 32 B o más}[/code]). La firma se compara en tiempo constante.
## Una clave desconocida o unos bytes de otro tamaño, false.
func verify(bytes: PackedByteArray, keys: Dictionary[int, PackedByteArray]) -> bool:
	if bytes.size() != SIZE or not keys.has(key_id) or bytes.decode_u8(1) != key_id:
		return false
	var key: PackedByteArray = keys[key_id]
	if key.is_empty():
		return false
	var expected: PackedByteArray = _mac(key, bytes.slice(0, SIGNED_SIZE))
	if expected.size() != MAC_SIZE:
		return false
	return Crypto.new().constant_time_compare(expected, bytes.slice(SIGNED_SIZE, SIZE))


## Los 52 B del billete firmados con [param key] (con el [member key_id] que tenga). Para las pruebas y el
## falso de la plataforma: en producción solo firma la plataforma.
func sign(key: PackedByteArray) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(SIGNED_SIZE)
	bytes.encode_u8(0, version & 0xFF)
	bytes.encode_u8(1, key_id & 0xFF)
	bytes.encode_u16(2, world_id & 0xFFFF)
	bytes.encode_u64(4, ticket_id)
	bytes.encode_u64(12, character_id)
	bytes.encode_u32(20, zone_key & 0xFFFFFFFF)
	bytes.encode_u8(24, channel & 0xFF)
	bytes.encode_u8(25, realm & 0xFF)
	bytes.encode_u8(26, arrival & 0xFF)
	bytes.encode_u8(27, flags & 0xFF)
	bytes.encode_u32(28, issued_at & 0xFFFFFFFF)
	bytes.encode_u32(32, expires_at & 0xFFFFFFFF)
	bytes.append_array(_mac(key, bytes))
	return bytes


# HMAC-SHA256(key, data), los 16 primeros bytes.
static func _mac(key: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	var context := HMACContext.new()
	if context.start(HashingContext.HASH_SHA256, key) != OK:
		return PackedByteArray()
	context.update(data)
	return context.finish().slice(0, MAC_SIZE)
