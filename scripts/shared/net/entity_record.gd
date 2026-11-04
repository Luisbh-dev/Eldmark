class_name EntityRecord
extends RefCounted
## Record of an entity in a SNAPSHOT: fixed size of [constant SIZE] bytes
## (docs/red.md, section 5.5 and docs/combate.md, section 6). Used for players and NPCs.
## [br][br]
## Format (little-endian):
## [codeblock]
## offset  type     field
## 0       u16      net_id
## 2       u64      position   20 bits per axis (see NetMath), bits 60-63 at 0
## 10      u16      yaw        [0, TAU) -> 0..65535
## 12      s16 x3   velocity   cm/s, saturated
## 18      u8       flags      bit 0 = grounded; bits 1-2 = teleport counter (mod 4);
##                             bit 3 = weapon slot 2 active (protocol 6)
## 19      u8       action     combat action and phase (0 = none)
## 20      u8       health_q   quantized health: 0 = dead, 1-255 = alive (see [method quantize_health])
## [/codeblock]
## The [member kind] does not travel in the record: it is given by the snapshot section.
## [br][br]
## Bit 3 of [member flags] ([constant FLAG_SECOND_SLOT], docs/habilidades.md, section 5.2) says which weapon
## a remote carries: with the weapon pair from its SPAWN or its LOADOUT, the one in slot 2 if it is set.
## It does not enter the server history ([StateHistory]), where bit 3 is the block bit: the history
## takes [code]flags & 0b111[/code] and adds its defensive flags.

## Size of an encoded record (bytes).
const SIZE: int = 21
const FLAG_GROUNDED: int = 1 << 0
const TELEPORT_SHIFT: int = 1
const TELEPORT_MASK: int = 0b11
## Bit 3 of [member flags]: the active weapon is the one in slot 2 (bit 0 of
## [member CombatState.combat_flags2]).
const FLAG_SECOND_SLOT: int = 1 << 3
## Bits of [member flags] shared by the lag compensation history (ground and teleport).
const HISTORY_FLAGS_MASK: int = 0b111
## [member health_q] of a dead entity.
const HEALTH_Q_DEAD: int = 0
## [member health_q] of an entity with full health (also the value for those that have no
## health yet).
const HEALTH_Q_FULL: int = 255

var net_id: int = 0
var kind: int = NetProtocol.EntityKind.PLAYER
var position: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var velocity: Vector3 = Vector3.ZERO
var flags: int = 0
var action: int = 0
## Quantized health ([method quantize_health]): 0 dead, 1-255 alive. 255 by default.
var health_q: int = HEALTH_Q_FULL


## Health quantized to one byte: 0 if [param health] is 0 (or less) and, otherwise,
## [code]clampi((health · 255 + max − 1) / max, 1, 255)[/code], that is, rounded up
## and never 0 while any health remains. A maximum health of 0 or less counts as dead.
@warning_ignore("integer_division")
static func quantize_health(health: int, max_health: int) -> int:
	if health <= 0 or max_health <= 0:
		return HEALTH_Q_DEAD
	return clampi((health * 255 + max_health - 1) / max_health, 1, 255)


## Fraction of health (0 to 1) that [param quantized] represents.
static func health_fraction(quantized: int) -> float:
	return clampf(float(quantized) / float(HEALTH_Q_FULL), 0.0, 1.0)


## Whether the entity was on the ground.
func is_grounded() -> bool:
	return (flags & FLAG_GROUNDED) != 0


## Teleport counter (0-3). If it changes between two samples, they are not interpolated.
func get_teleport_counter() -> int:
	return (flags >> TELEPORT_SHIFT) & TELEPORT_MASK


## Whether the entity's active weapon is the one in its slot 2 (bit [constant FLAG_SECOND_SLOT]).
func is_second_slot() -> bool:
	return (flags & FLAG_SECOND_SLOT) != 0


## Writes the (quantized) record into [param bytes] starting at [param offset]. If the buffer is
## too short, it grows it.
func encode_into(bytes: PackedByteArray, offset: int) -> void:
	_write(bytes, offset, net_id, position, yaw, velocity, flags, action, health_q)


## Reads a record of [constant SIZE] bytes from [param bytes] at [param offset] and sets its
## [param kind]. Returns null if they do not fit. Values come out already dequantized.
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


## Server: writes the record of [param character] directly into [param bytes], without creating
## any object. If the buffer is too short, it grows it. [param health_q] is the entity's
## quantized health ([method quantize_health]).
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


## Record (unquantized) from a [PlayerState], with the quantized health
## [param health_q] (full by default). The active slot ([constant FLAG_SECOND_SLOT]) comes from the
## state's [CombatState].
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


## Linear interpolation between [param a] and [param b] with [param t] in [0, 1]: lerp of position and
## velocity and [method @GlobalScope.lerp_angle] of the yaw (correct when crossing ±PI). The remaining
## fields (identifier, flags, action, health) are those of the nearest record. The caller decides
## beforehand whether it can interpolate (same teleport counter).
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
