class_name EntityRecord
extends RefCounted
## Registro de una entidad en un SNAPSHOT: tamaño fijo de [constant SIZE] bytes
## (docs/red.md, sección 5.5). Sirve para jugadores y para PNJ.
## [br][br]
## Formato (little-endian):
## [codeblock]
## offset  tipo     campo
## 0       u16      net_id
## 2       u64      position   20 bits por eje (ver NetMath), bits 60-63 a 0
## 10      u16      yaw        [0, TAU) -> 0..65535
## 12      s16 x3   velocity   cm/s, saturado
## 18      u8       flags      bit 0 = grounded; bits 1-2 = contador de teletransporte (mod 4)
## 19      u8       action     0 en la fase 2
## [/codeblock]
## El [member kind] no viaja en el registro: lo da la sección del snapshot.

## Tamaño de un registro codificado (bytes).
const SIZE: int = 20
const FLAG_GROUNDED: int = 1 << 0
const TELEPORT_SHIFT: int = 1
const TELEPORT_MASK: int = 0b11

var net_id: int = 0
var kind: int = NetProtocol.EntityKind.PLAYER
var position: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var velocity: Vector3 = Vector3.ZERO
var flags: int = 0
var action: int = 0


## Si la entidad estaba en el suelo.
func is_grounded() -> bool:
	return (flags & FLAG_GROUNDED) != 0


## Contador de teletransporte (0-3). Si cambia entre dos muestras no se interpola entre ellas.
func get_teleport_counter() -> int:
	return (flags >> TELEPORT_SHIFT) & TELEPORT_MASK


## Escribe el registro (cuantizado) en [param bytes] a partir de [param offset]. Si el búfer es
## demasiado corto, lo amplía.
func encode_into(bytes: PackedByteArray, offset: int) -> void:
	_write(bytes, offset, net_id, position, yaw, velocity, flags, action)


## Lee un registro de [constant SIZE] bytes de [param bytes] en [param offset] y le pone
## [param kind]. Devuelve null si no caben. Los valores salen ya descuantizados.
static func decode_from(bytes: PackedByteArray, offset: int, kind: int) -> EntityRecord:
	if offset < 0 or offset + SIZE > bytes.size():
		return null
	var record := EntityRecord.new()
	record.net_id = bytes.decode_u16(offset)
	record.kind = kind
	record.position = NetMath.unpack_position(bytes.decode_u64(offset + 2))
	record.yaw = NetMath.dequantize_yaw16(bytes.decode_u16(offset + 10))
	record.velocity = Vector3(
		NetMath.dequantize_velocity(bytes.decode_s16(offset + 12)),
		NetMath.dequantize_velocity(bytes.decode_s16(offset + 14)),
		NetMath.dequantize_velocity(bytes.decode_s16(offset + 16))
	)
	record.flags = bytes.decode_u8(offset + 18)
	record.action = bytes.decode_u8(offset + 19)
	return record


## Servidor: escribe el registro de [param character] directamente en [param bytes], sin crear
## ningún objeto. Si el búfer es demasiado corto, lo amplía.
static func encode_character(bytes: PackedByteArray, offset: int, net_id: int,
		character: PlayerCharacter, teleport_counter: int, action: int) -> void:
	var character_position: Vector3 = \
			character.global_position if character.is_inside_tree() else character.position
	var character_flags: int = (teleport_counter & TELEPORT_MASK) << TELEPORT_SHIFT
	if character.grounded:
		character_flags |= FLAG_GROUNDED
	_write(bytes, offset, net_id, character_position, character.yaw, character.velocity,
			character_flags, action)


## Registro (sin cuantizar) a partir de un [PlayerState].
static func from_state(net_id: int, kind: int, state: PlayerState,
		teleport_counter: int) -> EntityRecord:
	var record := EntityRecord.new()
	record.net_id = net_id
	record.kind = kind
	record.position = state.position
	record.yaw = state.yaw
	record.velocity = state.velocity
	record.flags = (teleport_counter & TELEPORT_MASK) << TELEPORT_SHIFT
	if state.grounded:
		record.flags |= FLAG_GROUNDED
	return record


## Interpolación lineal entre [param a] y [param b] con [param t] en [0, 1]: lerp de posición y
## velocidad y [method @GlobalScope.lerp_angle] del yaw (correcto al cruzar ±PI). El resto de
## campos (identificador, flags, acción) son los del registro más cercano. Quien llama decide
## antes si puede interpolar (mismo contador de teletransporte).
static func interpolate(a: EntityRecord, b: EntityRecord, t: float) -> EntityRecord:
	var nearest: EntityRecord = a if t < 0.5 else b
	var record := EntityRecord.new()
	record.net_id = nearest.net_id
	record.kind = nearest.kind
	record.position = a.position.lerp(b.position, t)
	record.yaw = lerp_angle(a.yaw, b.yaw, t)
	record.velocity = a.velocity.lerp(b.velocity, t)
	record.flags = nearest.flags
	record.action = nearest.action
	return record


static func _write(bytes: PackedByteArray, offset: int, record_net_id: int,
		record_position: Vector3, record_yaw: float, record_velocity: Vector3, record_flags: int,
		record_action: int) -> void:
	if bytes.size() < offset + SIZE:
		bytes.resize(offset + SIZE)
	bytes.encode_u16(offset, record_net_id & 0xFFFF)
	bytes.encode_u64(offset + 2, NetMath.pack_position(record_position))
	bytes.encode_u16(offset + 10, NetMath.quantize_yaw16(record_yaw))
	bytes.encode_s16(offset + 12, NetMath.quantize_velocity(record_velocity.x))
	bytes.encode_s16(offset + 14, NetMath.quantize_velocity(record_velocity.y))
	bytes.encode_s16(offset + 16, NetMath.quantize_velocity(record_velocity.z))
	bytes.encode_u8(offset + 18, record_flags & 0xFF)
	bytes.encode_u8(offset + 19, record_action & 0xFF)
