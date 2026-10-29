class_name EntityRecord
extends RefCounted
## Registro de una entidad en un SNAPSHOT: tamaño fijo de [constant SIZE] bytes
## (docs/red.md, sección 5.5 y docs/combate.md, sección 6). Sirve para jugadores y para PNJ.
## [br][br]
## Formato (little-endian):
## [codeblock]
## offset  tipo     campo
## 0       u16      net_id
## 2       u64      position   20 bits por eje (ver NetMath), bits 60-63 a 0
## 10      u16      yaw        [0, TAU) -> 0..65535
## 12      s16 x3   velocity   cm/s, saturado
## 18      u8       flags      bit 0 = grounded; bits 1-2 = contador de teletransporte (mod 4);
##                             bit 3 = ranura de arma 2 activa (protocolo 6)
## 19      u8       action     acción y fase del combate (0 = ninguna)
## 20      u8       health_q   vida cuantizada: 0 = muerto, 1-255 = viva (ver [method quantize_health])
## [/codeblock]
## El [member kind] no viaja en el registro: lo da la sección del snapshot.
## [br][br]
## El bit 3 de [member flags] ([constant FLAG_SECOND_SLOT], docs/habilidades.md, sección 5.2) dice qué arma
## lleva un remoto: con la pareja de armas de su SPAWN o de su LOADOUT, la de la ranura 2 si está puesto.
## No entra en el historial del servidor ([StateHistory]), donde el bit 3 es el de bloqueo: el historial
## toma [code]flags & 0b111[/code] y le suma sus banderas defensivas.

## Tamaño de un registro codificado (bytes).
const SIZE: int = 21
const FLAG_GROUNDED: int = 1 << 0
const TELEPORT_SHIFT: int = 1
const TELEPORT_MASK: int = 0b11
## Bit 3 de [member flags]: el arma activa es la de la ranura 2 (el bit 0 de
## [member CombatState.combat_flags2]).
const FLAG_SECOND_SLOT: int = 1 << 3
## Bits de [member flags] que comparte el historial de compensación de latencia (suelo y teletransporte).
const HISTORY_FLAGS_MASK: int = 0b111
## [member health_q] de una entidad muerta.
const HEALTH_Q_DEAD: int = 0
## [member health_q] de una entidad con la vida llena (también el valor de las que no tienen
## vida todavía).
const HEALTH_Q_FULL: int = 255

var net_id: int = 0
var kind: int = NetProtocol.EntityKind.PLAYER
var position: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var velocity: Vector3 = Vector3.ZERO
var flags: int = 0
var action: int = 0
## Vida cuantizada ([method quantize_health]): 0 muerto, 1-255 vivo. 255 por defecto.
var health_q: int = HEALTH_Q_FULL


## Vida cuantizada a un byte: 0 si [param health] es 0 (o menos) y, si no,
## [code]clampi((health · 255 + max − 1) / max, 1, 255)[/code], es decir, redondeada hacia arriba
## y nunca 0 mientras quede vida. Una vida máxima de 0 o menos cuenta como muerto.
@warning_ignore("integer_division")
static func quantize_health(health: int, max_health: int) -> int:
	if health <= 0 or max_health <= 0:
		return HEALTH_Q_DEAD
	return clampi((health * 255 + max_health - 1) / max_health, 1, 255)


## Fracción de vida (0 a 1) que representa [param quantized].
static func health_fraction(quantized: int) -> float:
	return clampf(float(quantized) / float(HEALTH_Q_FULL), 0.0, 1.0)


## Si la entidad estaba en el suelo.
func is_grounded() -> bool:
	return (flags & FLAG_GROUNDED) != 0


## Contador de teletransporte (0-3). Si cambia entre dos muestras no se interpola entre ellas.
func get_teleport_counter() -> int:
	return (flags >> TELEPORT_SHIFT) & TELEPORT_MASK


## Si el arma activa de la entidad es la de su ranura 2 (bit [constant FLAG_SECOND_SLOT]).
func is_second_slot() -> bool:
	return (flags & FLAG_SECOND_SLOT) != 0


## Escribe el registro (cuantizado) en [param bytes] a partir de [param offset]. Si el búfer es
## demasiado corto, lo amplía.
func encode_into(bytes: PackedByteArray, offset: int) -> void:
	_write(bytes, offset, net_id, position, yaw, velocity, flags, action, health_q)


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
	record.health_q = bytes.decode_u8(offset + 20)
	return record


## Servidor: escribe el registro de [param character] directamente en [param bytes], sin crear
## ningún objeto. Si el búfer es demasiado corto, lo amplía. [param health_q] es la vida
## cuantizada de la entidad ([method quantize_health]).
static func encode_character(bytes: PackedByteArray, offset: int, net_id: int,
		character: PlayerCharacter, teleport_counter: int, action: int,
		health_q: int) -> void:
	var character_position: Vector3 = \
			character.global_position if character.is_inside_tree() else character.position
	var character_flags: int = (teleport_counter & TELEPORT_MASK) << TELEPORT_SHIFT
	if character.grounded:
		character_flags |= FLAG_GROUNDED
	if character.combat != null and character.combat.is_second_slot():
		character_flags |= FLAG_SECOND_SLOT
	_write(bytes, offset, net_id, character_position, character.yaw, character.velocity,
			character_flags, action, health_q)


## Registro (sin cuantizar) a partir de un [PlayerState], con la vida cuantizada
## [param health_q] (llena por defecto). La ranura activa ([constant FLAG_SECOND_SLOT]) sale del
## [CombatState] del estado.
static func from_state(net_id: int, kind: int, state: PlayerState,
		teleport_counter: int, health_q: int = HEALTH_Q_FULL) -> EntityRecord:
	var record := EntityRecord.new()
	record.net_id = net_id
	record.kind = kind
	record.position = state.position
	record.yaw = state.yaw
	record.velocity = state.velocity
	record.flags = (teleport_counter & TELEPORT_MASK) << TELEPORT_SHIFT
	if state.grounded:
		record.flags |= FLAG_GROUNDED
	if state.combat != null and state.combat.is_second_slot():
		record.flags |= FLAG_SECOND_SLOT
	record.health_q = health_q
	return record


## Interpolación lineal entre [param a] y [param b] con [param t] en [0, 1]: lerp de posición y
## velocidad y [method @GlobalScope.lerp_angle] del yaw (correcto al cruzar ±PI). El resto de
## campos (identificador, flags, acción, vida) son los del registro más cercano. Quien llama decide
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
	record.health_q = nearest.health_q
	return record


static func _write(bytes: PackedByteArray, offset: int, record_net_id: int,
		record_position: Vector3, record_yaw: float, record_velocity: Vector3, record_flags: int,
		record_action: int, record_health_q: int) -> void:
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
	bytes.encode_u8(offset + 20, clampi(record_health_q, 0, 255))
