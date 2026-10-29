class_name NetSim
extends RefCounted
## Simulador de red para depurar: retardo, jitter, pérdida y duplicados, todo medido en ticks.
##
## Lo aplica [NetTransport] a la salida y a la entrada (ver docs/red.md, sección 13), así que
## ponerlo en un solo lado simula el RTT completo; en los dos lados, lo duplica.
## [br][br]
## Reglas:
## [br]- Retardo por sentido: [code]rtt/2 ± jitter[/code] (uniforme), en ticks redondeados, con la
## resolución de un tick de 60 Hz (16,7 ms).
## [br]- Pérdida y duplicados: solo en los canales no fiables ([method
## NetProtocol.is_unreliable_channel]). Los fiables y la autenticación solo se retrasan y
## mantienen el orden FIFO por (peer, canal): tirar paquetes a nivel de aplicación rompería la
## fiabilidad de ENet. Los no fiables pueden llegar desordenados por el jitter, como en una red
## real.
## [br]- Reproducible: tiene su propio [RandomNumberGenerator] con semilla. Misma configuración,
## misma semilla y mismas llamadas dan la misma secuencia.
## [br][br]
## No lee el reloj: el tiempo es el tick que pasa quien llama.

## Duración de un tick de física en milisegundos (60 Hz).
const TICK_MS: float = 1000.0 / 60.0
## Valor de [member NetSim.Packet.channel] de los mensajes de autenticación (canal de sistema).
const AUTH_CHANNEL: int = 0

# Bits de la clave de (peer, canal) del orden FIFO.
const _CHANNEL_KEY_BITS: int = 3
const _CHANNEL_KEY_MASK: int = (1 << _CHANNEL_KEY_BITS) - 1


## Un paquete en tránsito por el simulador.
class Packet:
	var peer_id: int = 0
	var channel: int = 0
	var bytes: PackedByteArray = PackedByteArray()
	## true si es un mensaje de autenticación: solo se retrasa, nunca se pierde ni se duplica.
	var is_auth: bool = false
	## Tick en el que debe entregarse. Lo rellena [method NetSim.enqueue].
	var due_tick: int = 0
	## Orden de llegada al simulador (desempata los paquetes con el mismo [member due_tick]).
	var sequence: int = 0

	func _init(p_peer_id: int = 0, p_channel: int = 0,
			p_bytes: PackedByteArray = PackedByteArray(), p_is_auth: bool = false) -> void:
		peer_id = p_peer_id
		channel = p_channel
		bytes = p_bytes
		is_auth = p_is_auth


var _rtt_ms: int = 0
var _jitter_ms: int = 0
var _loss_percent: float = 0.0
var _duplicate_percent: float = 0.0
var _seed: int = 1
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _pending: Array[NetSim.Packet] = []
var _next_sequence: int = 0
# Última entrega planificada de cada (peer, canal) con orden FIFO.
var _last_due: Dictionary = {}


## Crea un simulador desde el texto de [code]--net-sim[/code]:
## [code]"rtt=120,jitter=20,loss=5,dup=0,seed=1"[/code] (ms, ms, %, %). Las claves que faltan valen
## 0 (la semilla, 1) y las desconocidas se ignoran. [param seed_offset] se suma a la semilla (el
## transporte usa 0 para la salida y 1 para la entrada, para que no coincidan). Devuelve null
## si [param spec] está vacío.
static func from_arg(spec: String, seed_offset: int = 0) -> NetSim:
	var text: String = spec.strip_edges()
	if text.is_empty():
		return null
	var rtt_ms: int = 0
	var jitter_ms: int = 0
	var loss_percent: float = 0.0
	var duplicate_percent: float = 0.0
	var seed_value: int = 1
	for part: String in text.split(",", false):
		var pair: PackedStringArray = part.split("=", false, 1)
		if pair.size() != 2:
			continue
		var key: String = pair[0].strip_edges().to_lower()
		var value: String = pair[1].strip_edges()
		if not value.is_valid_float():
			continue
		match key:
			"rtt":
				rtt_ms = value.to_int()
			"jitter":
				jitter_ms = value.to_int()
			"loss":
				loss_percent = value.to_float()
			"dup":
				duplicate_percent = value.to_float()
			"seed":
				seed_value = value.to_int()
	var sim := NetSim.new()
	sim.configure(rtt_ms, jitter_ms, loss_percent, duplicate_percent, seed_value + seed_offset)
	return sim


## Fija los parámetros y reinicia el generador aleatorio con [param seed]. Los valores negativos
## pasan a 0 y los porcentajes se limitan a 100. No toca los paquetes que ya están en cola.
func configure(rtt_ms: int, jitter_ms: int, loss_percent: float, duplicate_percent: float,
		seed: int) -> void:
	_rtt_ms = maxi(rtt_ms, 0)
	_jitter_ms = maxi(jitter_ms, 0)
	_loss_percent = clampf(loss_percent, 0.0, 100.0)
	_duplicate_percent = clampf(duplicate_percent, 0.0, 100.0)
	_seed = seed
	_rng.seed = seed


## true si el simulador hace algo (algún parámetro es mayor que 0).
func is_enabled() -> bool:
	return _rtt_ms > 0 or _jitter_ms > 0 or _loss_percent > 0.0 or _duplicate_percent > 0.0


## Mete [param packet] en la cola en el tick [param now_tick]. Fija su [member
## NetSim.Packet.due_tick]. Si es de un canal no fiable puede perderse (no entra en la cola) o
## duplicarse (entra una copia más, con su propio retardo). Los fiables y la autenticación
## mantienen el orden FIFO por (peer, canal): nunca se entregan antes que uno anterior.
func enqueue(packet: NetSim.Packet, now_tick: int) -> void:
	var unreliable: bool = not packet.is_auth and NetProtocol.is_unreliable_channel(packet.channel)
	if unreliable:
		if _roll(_loss_percent):
			return
		_schedule(packet, now_tick, false)
		if _roll(_duplicate_percent):
			var copy := NetSim.Packet.new(packet.peer_id, packet.channel, packet.bytes, false)
			_schedule(copy, now_tick, false)
	else:
		_schedule(packet, now_tick, true)


## Saca de la cola los paquetes que vencen en [param now_tick] o antes, por orden de entrega
## (y, a igualdad, de llegada).
func pop_due(now_tick: int) -> Array[NetSim.Packet]:
	var due: Array[NetSim.Packet] = []
	for packet: NetSim.Packet in _pending:
		if packet.due_tick <= now_tick:
			due.append(packet)
	if due.is_empty():
		return due
	var remaining: Array[NetSim.Packet] = []
	for packet: NetSim.Packet in _pending:
		if packet.due_tick > now_tick:
			remaining.append(packet)
	_pending = remaining
	due.sort_custom(_is_delivered_before)
	if _pending.is_empty():
		_last_due.clear()
	return due


## Saca de la cola todo lo que retiene para [param peer_id], venza o no, por orden de entrega, y
## olvida su orden FIFO. Lo usa el transporte antes de cerrar la conexión de un peer para que lo
## ya enviado salga antes del corte, o para descartarlo si el peer ya no existe.
func drain_peer(peer_id: int) -> Array[NetSim.Packet]:
	var drained: Array[NetSim.Packet] = []
	var remaining: Array[NetSim.Packet] = []
	for packet: NetSim.Packet in _pending:
		if packet.peer_id == peer_id:
			drained.append(packet)
		else:
			remaining.append(packet)
	_pending = remaining
	drained.sort_custom(_is_delivered_before)
	for channel: int in (_CHANNEL_KEY_MASK + 1):
		_last_due.erase(_fifo_key(peer_id, channel))
	return drained


## true si la cola retiene algún paquete de [param peer_id].
func has_pending(peer_id: int) -> bool:
	for packet: NetSim.Packet in _pending:
		if packet.peer_id == peer_id:
			return true
	return false


## Número de paquetes en la cola.
func get_pending_count() -> int:
	return _pending.size()


## Descripción de la configuración, para el registro y el overlay de depuración.
func describe() -> String:
	return "rtt=%d ms, jitter=%d ms, pérdida=%s%%, duplicados=%s%%, semilla=%d" % [
		_rtt_ms, _jitter_ms, _percent_text(_loss_percent), _percent_text(_duplicate_percent), _seed,
	]


# Un porcentaje sin decimales inútiles: «5», «1.5».
static func _percent_text(percent: float) -> String:
	if is_equal_approx(percent, roundf(percent)):
		return str(roundi(percent))
	return ("%.2f" % percent).rstrip("0").rstrip(".")


# Sortea un suceso con probabilidad [param percent] (0-100). Con 0 no consume el generador.
func _roll(percent: float) -> bool:
	if percent <= 0.0:
		return false
	return _rng.randf() * 100.0 < percent


# Retardo de un sentido en ticks: rtt/2 ± jitter (uniforme), redondeado y nunca negativo.
func _roll_delay_ticks() -> int:
	var delay_ms: float = _rtt_ms * 0.5
	if _jitter_ms > 0:
		delay_ms += _rng.randf_range(-_jitter_ms, _jitter_ms)
	return maxi(roundi(delay_ms / TICK_MS), 0)


func _schedule(packet: NetSim.Packet, now_tick: int, keep_order: bool) -> void:
	var due: int = now_tick + _roll_delay_ticks()
	if keep_order:
		var key: int = _fifo_key(packet.peer_id, AUTH_CHANNEL if packet.is_auth else packet.channel)
		due = maxi(due, int(_last_due.get(key, due)))
		_last_due[key] = due
	packet.due_tick = due
	packet.sequence = _next_sequence
	_next_sequence += 1
	_pending.append(packet)


func _fifo_key(peer_id: int, channel: int) -> int:
	return (peer_id << _CHANNEL_KEY_BITS) | (channel & _CHANNEL_KEY_MASK)


func _is_delivered_before(a: NetSim.Packet, b: NetSim.Packet) -> bool:
	if a.due_tick != b.due_tick:
		return a.due_tick < b.due_tick
	return a.sequence < b.sequence
