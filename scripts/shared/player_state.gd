class_name PlayerState
extends RefCounted
## Estado completo de simulación de un personaje.
##
## Restaurarlo con [method PlayerCharacter.set_state] y volver a aplicar las mismas entradas debe
## reproducir el mismo resultado (reconciliación de la fase 2).
## [br][br]
## Formato de red ([constant ENCODED_SIZE] bytes, little-endian):
## [codeblock]
## offset  tipo     campo
## 0       f32 x3   position
## 12      f32 x3   velocity
## 24      f32      yaw
## 28      u8       flags: bit 0 = grounded, bits 1-3 = coyote_ticks, bits 4-7 = jump_buffer_ticks
## 29      u16      prev_buttons
## 31      u32      last_input_tick
## [/codeblock]

## Tamaño en bytes de un estado codificado.
const ENCODED_SIZE: int = 35
## Valor máximo de [member coyote_ticks] (ocupa 3 bits de los flags).
const MAX_COYOTE_TICKS: int = 7
## Valor máximo de [member jump_buffer_ticks] (ocupa 4 bits de los flags).
const MAX_JUMP_BUFFER_TICKS: int = 15

const _FLAG_GROUNDED: int = 1 << 0
const _COYOTE_SHIFT: int = 1
const _JUMP_BUFFER_SHIFT: int = 4

## Posición global de los pies del personaje.
var position: Vector3 = Vector3.ZERO
## Velocidad en m/s.
var velocity: Vector3 = Vector3.ZERO
## Orientación en radianes (misma convención que [member Node3D.rotation].y).
var yaw: float = 0.0
## Si el personaje estaba en el suelo al terminar el último tick.
var grounded: bool = false
## Botones de la última entrada aplicada (para detectar flancos de subida, como el salto).
var prev_buttons: int = 0
## Tick de la última entrada aplicada.
var last_input_tick: int = 0
## Ticks en el aire que le quedan al personaje para poder saltar tras dejar el suelo sin saltar
## ("coyote time"). Entre 0 y [constant MAX_COYOTE_TICKS].
var coyote_ticks: int = 0
## Ticks que le quedan a una pulsación de salto guardada en el búfer (0 = ninguna pendiente).
## Entre 0 y [constant MAX_JUMP_BUFFER_TICKS].
var jump_buffer_ticks: int = 0


## Serializa el estado en [constant ENCODED_SIZE] bytes little-endian.
func encode() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(ENCODED_SIZE)
	bytes.encode_float(0, position.x)
	bytes.encode_float(4, position.y)
	bytes.encode_float(8, position.z)
	bytes.encode_float(12, velocity.x)
	bytes.encode_float(16, velocity.y)
	bytes.encode_float(20, velocity.z)
	bytes.encode_float(24, yaw)
	var flags: int = _FLAG_GROUNDED if grounded else 0
	flags |= clampi(coyote_ticks, 0, MAX_COYOTE_TICKS) << _COYOTE_SHIFT
	flags |= clampi(jump_buffer_ticks, 0, MAX_JUMP_BUFFER_TICKS) << _JUMP_BUFFER_SHIFT
	bytes.encode_u8(28, flags)
	bytes.encode_u16(29, prev_buttons & 0xFFFF)
	bytes.encode_u32(31, last_input_tick & 0xFFFFFFFF)
	return bytes


## Reconstruye un estado a partir de bytes. Devuelve null si el tamaño no es
## [constant ENCODED_SIZE].
static func decode(bytes: PackedByteArray) -> PlayerState:
	if bytes.size() != ENCODED_SIZE:
		return null
	var state := PlayerState.new()
	state.position = Vector3(bytes.decode_float(0), bytes.decode_float(4), bytes.decode_float(8))
	state.velocity = Vector3(bytes.decode_float(12), bytes.decode_float(16), bytes.decode_float(20))
	state.yaw = bytes.decode_float(24)
	var flags: int = bytes.decode_u8(28)
	state.grounded = (flags & _FLAG_GROUNDED) != 0
	state.coyote_ticks = (flags >> _COYOTE_SHIFT) & MAX_COYOTE_TICKS
	state.jump_buffer_ticks = (flags >> _JUMP_BUFFER_SHIFT) & MAX_JUMP_BUFFER_TICKS
	state.prev_buttons = bytes.decode_u16(29)
	state.last_input_tick = bytes.decode_u32(31)
	return state


## Copia exacta del estado.
func duplicate_state() -> PlayerState:
	var copy := PlayerState.new()
	copy.position = position
	copy.velocity = velocity
	copy.yaw = yaw
	copy.grounded = grounded
	copy.prev_buttons = prev_buttons
	copy.last_input_tick = last_input_tick
	copy.coyote_ticks = coyote_ticks
	copy.jump_buffer_ticks = jump_buffer_ticks
	return copy


## Devuelve true si ambos estados coinciden dentro de la tolerancia: posición y velocidad
## (distancia <= pos_epsilon), yaw (diferencia angular <= pos_epsilon, teniendo en cuenta la
## vuelta completa), grounded y los contadores de salto ([member coyote_ticks] y
## [member jump_buffer_ticks], que cambian lo que harán los ticks siguientes). Cualquier NaN
## hace que devuelva false.
func is_close_to(other: PlayerState, pos_epsilon: float = 0.01) -> bool:
	if other == null:
		return false
	# Se usa "not (x <= eps)" para que un NaN cuente como diferencia.
	if not (position.distance_to(other.position) <= pos_epsilon):
		return false
	if not (velocity.distance_to(other.velocity) <= pos_epsilon):
		return false
	if not (absf(angle_difference(yaw, other.yaw)) <= pos_epsilon):
		return false
	if coyote_ticks != other.coyote_ticks or jump_buffer_ticks != other.jump_buffer_ticks:
		return false
	return grounded == other.grounded


func _to_string() -> String:
	var text: String = "PlayerState(pos=%s, vel=%s, yaw=%.5f, grounded=%s, prev_buttons=%d, "
	text += "last_input_tick=%d, coyote=%d, jump_buffer=%d)"
	return text % [
		position, velocity, yaw, grounded, prev_buttons, last_input_tick, coyote_ticks,
		jump_buffer_ticks,
	]
