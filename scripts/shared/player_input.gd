class_name PlayerInput
extends RefCounted
## Un tick de intención del jugador: exactamente lo que el cliente enviará al servidor
## en la fase 2.
##
## El cliente nunca envía posiciones ni resultados, solo esta intención. Antes de simular, el
## cliente debe usar [method quantized] para que la predicción local trabaje con los mismos
## valores que el servidor obtendrá con [method decode].
## [br][br]
## Formato de red ([constant ENCODED_SIZE] bytes, little-endian):
## [codeblock]
## offset  tipo  campo
## 0       u32   tick
## 4       s8    move.x   round(v * 127), longitud <= 1
## 5       s8    move.y
## 6       u16   look_yaw   [0, TAU) -> 0..65535 (65536 vuelve a 0)
## 8       s16   look_pitch pitch / (PI / 2) * 32767
## 10      u16   buttons
## [/codeblock]

const JUMP: int = 1 << 0
const SPRINT: int = 1 << 1
const DODGE: int = 1 << 2
const PRIMARY: int = 1 << 3
const BLOCK: int = 1 << 4
const ABILITY_1: int = 1 << 5
const ABILITY_2: int = 1 << 6
const ABILITY_3: int = 1 << 7
const INTERACT: int = 1 << 8
## Cambiar de arma (Q; docs/habilidades.md, sección 3.2).
const SWAP_WEAPON: int = 1 << 9
## Hombro izquierdo de la cámara: lo pone el cliente con el hombro efectivo de la cámara. Es un nivel,
## no una pulsación; solo lo lee la puntería de los proyectiles (docs/habilidades.md, sección 4.4).
const AIM_LEFT: int = 1 << 10
## Consumibles: poción de vida (R) y de resistencia (T).
const CONSUMABLE_1: int = 1 << 11
const CONSUMABLE_2: int = 1 << 12
## Bits 13-14 reservados.
## Marca de entrada sustituida (docs/combate.md, sección 3.2): no es un botón. La ponen la cola
## de entradas del servidor y la predicción del cliente en la entrada que repite la última
## aplicada cuando la real no ha llegado. Está fuera de
## [constant NetProtocol.VALID_BUTTONS], así que el cliente no puede ponerla: el servidor la
## descarta al decodificar. La máquina de acciones no cuenta ni lanza nada con ella, y
## [member PlayerCharacter.prev_buttons] nunca la guarda.
const SUBSTITUTED: int = 1 << 15

## Tamaño en bytes de una entrada codificada.
const ENCODED_SIZE: int = 12

const _MOVE_SCALE: int = 127
const _YAW_STEPS: int = 65536
const _PITCH_SCALE: int = 32767
const _HALF_PI: float = PI / 2.0

## Número de tick de simulación al que pertenece esta entrada (u32 en la red).
var tick: int = 0
## Movimiento deseado: x = derecha, y = adelante. Longitud <= 1.
var move: Vector2 = Vector2.ZERO
## Yaw de la cámara en radianes, misma convención que [member Node3D.rotation].y
## (0 mira hacia -Z). Tras cuantizar queda en [0, TAU).
var look_yaw: float = 0.0
## Pitch de la cámara en radianes; positivo mira hacia arriba. Se limita a [-PI/2, PI/2].
var look_pitch: float = 0.0
## Máscara de botones pulsados en este tick (constantes JUMP, SPRINT...).
var buttons: int = 0


## Devuelve true si el botón (una de las constantes de esta clase) está pulsado.
func has(button: int) -> bool:
	return (buttons & button) != 0


## Serializa la entrada en [constant ENCODED_SIZE] bytes little-endian.
func encode() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(ENCODED_SIZE)
	var move_q: Vector2i = _quantize_move(move)
	bytes.encode_u32(0, tick & 0xFFFFFFFF)
	bytes.encode_s8(4, move_q.x)
	bytes.encode_s8(5, move_q.y)
	bytes.encode_u16(6, _quantize_yaw(look_yaw))
	bytes.encode_s16(8, _quantize_pitch(look_pitch))
	bytes.encode_u16(10, buttons & 0xFFFF)
	return bytes


## Reconstruye una entrada a partir de bytes. Devuelve null si el tamaño no es
## [constant ENCODED_SIZE]. Los valores fuera de rango (por ejemplo, de un cliente
## malicioso) se normalizan, así que el resultado siempre cumple los invariantes.
## El yaw resultante está en [0, TAU).
static func decode(bytes: PackedByteArray) -> PlayerInput:
	if bytes.size() != ENCODED_SIZE:
		return null
	var input := PlayerInput.new()
	input.tick = bytes.decode_u32(0)
	var move_x: int = clampi(bytes.decode_s8(4), -_MOVE_SCALE, _MOVE_SCALE)
	var move_y: int = clampi(bytes.decode_s8(5), -_MOVE_SCALE, _MOVE_SCALE)
	if move_x * move_x + move_y * move_y > _MOVE_SCALE * _MOVE_SCALE:
		# Vector con longitud > 1: se recuantiza para que sea un valor canónico.
		var fixed: Vector2i = _quantize_move(Vector2(move_x, move_y) / float(_MOVE_SCALE))
		move_x = fixed.x
		move_y = fixed.y
	input.move = Vector2(move_x / float(_MOVE_SCALE), move_y / float(_MOVE_SCALE))
	input.look_yaw = bytes.decode_u16(6) / float(_YAW_STEPS) * TAU
	var pitch_q: int = clampi(bytes.decode_s16(8), -_PITCH_SCALE, _PITCH_SCALE)
	input.look_pitch = pitch_q / float(_PITCH_SCALE) * _HALF_PI
	input.buttons = bytes.decode_u16(10)
	return input


## Devuelve la entrada tal como la verá el servidor: equivale a decode(encode()).
## Es idempotente: quantized().quantized() es igual a quantized().
func quantized() -> PlayerInput:
	return decode(encode())


## Copia exacta (sin cuantizar).
func duplicate_input() -> PlayerInput:
	var copy := PlayerInput.new()
	copy.tick = tick
	copy.move = move
	copy.look_yaw = look_yaw
	copy.look_pitch = look_pitch
	copy.buttons = buttons
	return copy


func _to_string() -> String:
	return "PlayerInput(tick=%d, move=%s, look_yaw=%.5f, look_pitch=%.5f, buttons=%d)" % [
		tick, move, look_yaw, look_pitch, buttons,
	]


## Cuantiza el movimiento a enteros en [-127, 127] con longitud <= 127.
## Redondear puede dejar la longitud ligeramente por encima de 1; en ese caso se trunca hacia
## cero, lo que garantiza longitud <= 1 y que volver a cuantizar el resultado no lo cambie.
static func _quantize_move(value: Vector2) -> Vector2i:
	if not value.is_finite():
		return Vector2i.ZERO
	var clamped: Vector2 = value.limit_length(1.0)
	var qx: int = roundi(clamped.x * _MOVE_SCALE)
	var qy: int = roundi(clamped.y * _MOVE_SCALE)
	if qx * qx + qy * qy > _MOVE_SCALE * _MOVE_SCALE:
		qx = int(clamped.x * _MOVE_SCALE)
		qy = int(clamped.y * _MOVE_SCALE)
	return Vector2i(clampi(qx, -_MOVE_SCALE, _MOVE_SCALE), clampi(qy, -_MOVE_SCALE, _MOVE_SCALE))


## Envuelve el yaw a [0, TAU) y lo mapea a 0..65535 (65536 vuelve a 0).
static func _quantize_yaw(value: float) -> int:
	if not is_finite(value):
		return 0
	var wrapped: float = fposmod(value, TAU)
	return roundi(wrapped / TAU * _YAW_STEPS) % _YAW_STEPS


## Limita el pitch a [-PI/2, PI/2] y lo mapea a -32767..32767.
static func _quantize_pitch(value: float) -> int:
	if not is_finite(value):
		return 0
	var clamped: float = clampf(value, -_HALF_PI, _HALF_PI)
	return clampi(roundi(clamped / _HALF_PI * _PITCH_SCALE), -_PITCH_SCALE, _PITCH_SCALE)
