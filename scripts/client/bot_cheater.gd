class_name BotCheater
extends RefCounted
## Bot tramposo (docs/red.md, secciones 12 y 16; TEC-46): el comportamiento de [code]--bot-cheat[/code].
## [br][br]
## [NetClient] lo consulta en dos sitios: al armar el HELLO ([method tamper_hello]) y, una vez por tick
## de física, después de enviar su lote de entradas honrado ([method extra_packets]). El bot sigue
## jugando limpio por debajo: lo que cambia es el tráfico de más que añade este objeto. Lo que debe
## pasar en el servidor con cada modo ([constant MODES]):
## [codeblock]
## version  HELLO con otra versión del protocolo        -> REJECT VERSION, el bot no llega a entrar
## future   lotes con ticks muy por delante             -> TOO_EARLY: se descartan y se cuentan, sin
##          (más allá de MAX_INPUT_LEAD_TICKS)             efecto en nadie y sin ventaja
## dupes    copias distintas de las mismas entradas     -> gana la primera copia: la honrada
## garbage  paquetes al azar por el canal de entradas   -> avisos (malformado / tipo inesperado) y
##          y por el fiable                                 NOTICE de expulsión a los 50 en 600 ticks
## flood    más paquetes por tick de los que permiten   -> avisos por exceso de ritmo y expulsión
##          los limitadores
## [/codeblock]
## Las semillas son de la configuración ([member ClientConfig.bot_seed]), así que lo que envía es
## reproducible. Esto es solo cliente: el servidor no sabe quién hace trampa, solo valida.

const MODE_VERSION: String = "version"
const MODE_FUTURE: String = "future"
const MODE_DUPES: String = "dupes"
const MODE_GARBAGE: String = "garbage"
const MODE_FLOOD: String = "flood"
## Los modos admitidos de [code]--bot-cheat[/code].
const MODES: Array[String] = [MODE_VERSION, MODE_FUTURE, MODE_DUPES, MODE_GARBAGE, MODE_FLOOD]

## Versión del protocolo que miente el modo [constant MODE_VERSION].
const FAKE_PROTOCOL_VERSION: int = NetProtocol.PROTOCOL_VERSION + 1
## Ticks, además de [constant NetProtocol.MAX_INPUT_LEAD_TICKS], a los que se adelanta el lote del
## modo [constant MODE_FUTURE] (como mínimo; se le suma un tramo al azar).
const FUTURE_MIN_EXTRA_TICKS: int = 10
const FUTURE_RANDOM_EXTRA_TICKS: int = 40
## Entradas de cada lote de más de los modos [constant MODE_FUTURE] y [constant MODE_DUPES].
const EXTRA_BATCH_INPUTS: int = 4
## Copias del lote honrado que envía por tick el modo [constant MODE_FLOOD] (el limitador admite 2
## por tick con una ráfaga de 30) y paquetes fiables de relleno.
const FLOOD_COPIES_PER_TICK: int = 8
const FLOOD_RELIABLE_PER_TICK: int = 2
## Tamaño (en bytes) de la basura: nunca 2 (CLIENT_READY y CLIENT_LEAVE válidos) ni más de lo que
## cabe en un paquete no fiable.
const GARBAGE_MIN_BYTES: int = 3
const GARBAGE_MAX_BYTES: int = 120
## Primer byte de los paquetes de relleno del modo [constant MODE_FLOOD]: un tipo que nadie envía al
## servidor.
const FLOOD_FILLER_TYPE: int = 0x7F


## Un paquete que el bot envía además de su lote honrado.
class Extra:
	extends RefCounted

	var channel: int = NetProtocol.CH_INPUT
	var bytes: PackedByteArray = PackedByteArray()


	func _init(p_channel: int, p_bytes: PackedByteArray) -> void:
		channel = p_channel
		bytes = p_bytes


var _mode: String = ""
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _packets: int = 0


## [param mode] debe ser uno de [constant MODES] (si no, el objeto no hace nada).
func _init(mode: String, rng_seed: int) -> void:
	_mode = mode.to_lower()
	_rng.seed = rng_seed


## true si [param mode] es uno de [constant MODES] (sin distinguir mayúsculas).
static func is_valid_mode(mode: String) -> bool:
	return MODES.has(mode.to_lower())


## Modo en curso.
func get_mode() -> String:
	return _mode


## Paquetes de más generados desde el principio.
func get_packets_generated() -> int:
	return _packets


## Falsea el HELLO que se va a enviar. Solo el modo [constant MODE_VERSION] lo toca.
func tamper_hello(hello: NetMessages.Hello) -> void:
	if _mode == MODE_VERSION:
		hello.protocol_version = FAKE_PROTOCOL_VERSION


## Paquetes de más de este tick, para enviarlos justo después del lote [param honest] (el que acaba
## de enviar el bot, ya con sus entradas y desfases). El orden importa en [constant MODE_DUPES]: las
## copias distintas van después de la honrada, y gana la primera que llega.
func extra_packets(honest: NetMessages.InputBatch) -> Array[Extra]:
	var packets: Array[Extra] = []
	match _mode:
		MODE_FUTURE:
			_add_future_batch(honest, packets)
		MODE_DUPES:
			_add_conflicting_copy(honest, packets)
		MODE_GARBAGE:
			packets.append(Extra.new(NetProtocol.CH_INPUT, _garbage()))
			packets.append(Extra.new(NetProtocol.CH_RELIABLE, _garbage()))
		MODE_FLOOD:
			var copy: PackedByteArray = honest.encode()
			for _i: int in FLOOD_COPIES_PER_TICK:
				packets.append(Extra.new(NetProtocol.CH_INPUT, copy))
			for i: int in FLOOD_RELIABLE_PER_TICK:
				packets.append(Extra.new(NetProtocol.CH_RELIABLE,
						PackedByteArray([FLOOD_FILLER_TYPE, i])))
	_packets += packets.size()
	return packets


# Un lote con ticks más allá de la ventana de entradas del servidor (esprintando hacia delante): el
# bot intenta que el servidor se las guarde para aplicarlas más adelante. Se descartan (TOO_EARLY).
func _add_future_batch(honest: NetMessages.InputBatch, packets: Array[Extra]) -> void:
	var shift: int = NetProtocol.MAX_INPUT_LEAD_TICKS + FUTURE_MIN_EXTRA_TICKS \
			+ _rng.randi_range(0, FUTURE_RANDOM_EXTRA_TICKS)
	var batch := NetMessages.InputBatch.new()
	batch.ack_snapshot_tick = honest.ack_snapshot_tick
	batch.interp_delay_q = honest.interp_delay_q
	batch.newest_tick = honest.newest_tick + shift
	var template: PlayerInput = honest.inputs[honest.inputs.size() - 1]
	for i: int in EXTRA_BATCH_INPUTS:
		var input: PlayerInput = template.duplicate_input()
		input.tick = batch.newest_tick - EXTRA_BATCH_INPUTS + 1 + i
		input.move = Vector2(0.0, 1.0)
		input.buttons = PlayerInput.SPRINT
		batch.inputs.append(input.quantized())
		batch.view_offsets_q.append(0)
	_append_batch(batch, packets)


# Las mismas entradas que el lote honrado (mismos ticks) pero con otro contenido: movimiento
# invertido, vista girada media vuelta y botones distintos. Si el servidor se quedara con la última
# copia en vez de con la primera, el bot iría al revés de lo que predice.
func _add_conflicting_copy(honest: NetMessages.InputBatch, packets: Array[Extra]) -> void:
	var batch := NetMessages.InputBatch.new()
	batch.ack_snapshot_tick = honest.ack_snapshot_tick
	batch.interp_delay_q = honest.interp_delay_q
	batch.newest_tick = honest.newest_tick
	for i: int in honest.inputs.size():
		var input: PlayerInput = honest.inputs[i].duplicate_input()
		input.move = -input.move if input.move != Vector2.ZERO else Vector2(0.0, -1.0)
		input.look_yaw = fposmod(input.look_yaw + PI, TAU)
		input.buttons = input.buttons ^ (PlayerInput.JUMP | PlayerInput.DODGE)
		batch.inputs.append(input.quantized())
		batch.view_offsets_q.append(honest.view_offsets_q[i])
	_append_batch(batch, packets)


func _append_batch(batch: NetMessages.InputBatch, packets: Array[Extra]) -> void:
	var bytes: PackedByteArray = batch.encode()
	if not bytes.is_empty():
		packets.append(Extra.new(NetProtocol.CH_INPUT, bytes))


# Bytes al azar, de un tamaño que no puede ser un mensaje de 2 bytes válido.
func _garbage() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(_rng.randi_range(GARBAGE_MIN_BYTES, GARBAGE_MAX_BYTES))
	for i: int in bytes.size():
		bytes[i] = _rng.randi_range(0, 255)
	return bytes
