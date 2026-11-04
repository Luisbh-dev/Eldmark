class_name NetSim
extends RefCounted
## Network simulator for debugging: delay, jitter, loss and duplicates, all measured in ticks.
##
## [NetTransport] applies it on output and input (see docs/red.md, section 13), so
## setting it on one side simulates the full RTT; on both sides, it doubles it.
## [br][br]
## Rules:
## [br]- Delay per direction: [code]rtt/2 ± jitter[/code] (uniform), in rounded ticks, with the
## resolution of a 60 Hz tick (16.7 ms).
## [br]- Loss and duplicates: only on unreliable channels ([method
## NetProtocol.is_unreliable_channel]). Reliable ones and authentication are only delayed and
## keep FIFO order per (peer, channel): dropping packets at the application level would break
## ENet's reliability. Unreliable ones can arrive out of order because of jitter, as on a real
## network.
## [br]- Reproducible: it has its own seeded [RandomNumberGenerator]. The same configuration,
## the same seed and the same calls give the same sequence.
## [br][br]
## It does not read the clock: time is the tick passed by the caller.

## Duration of a physics tick in milliseconds (60 Hz).
const TICK_MS: float = 1000.0 / 60.0
## Value of [member NetSim.Packet.channel] for authentication messages (system channel).
const AUTH_CHANNEL: int = 0

# Bits of the (peer, channel) key for FIFO ordering.
const _CHANNEL_KEY_BITS: int = 3
const _CHANNEL_KEY_MASK: int = (1 << _CHANNEL_KEY_BITS) - 1


## A packet in transit through the simulator.
class Packet:
	var peer_id: int = 0
	var channel: int = 0
	var bytes: PackedByteArray = PackedByteArray()
	## true if it is an authentication message: it is only delayed, never lost or duplicated.
	var is_auth: bool = false
	## Tick at which it must be delivered. Filled in by [method NetSim.enqueue].
	var due_tick: int = 0
	## Order of arrival at the simulator (breaks ties between packets with the same [member due_tick]).
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
# Last scheduled delivery of each (peer, channel) with FIFO order.
var _last_due: Dictionary = {}


## Creates a simulator from the text of [code]--net-sim[/code]:
## [code]"rtt=120,jitter=20,loss=5,dup=0,seed=1"[/code] (ms, ms, %, %). Missing keys default to
## 0 (the seed, to 1) and unknown ones are ignored. [param seed_offset] is added to the seed (the
## transport uses 0 for output and 1 for input, so they do not coincide). Returns null
## if [param spec] is empty.
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


## Sets the parameters and resets the random generator with [param seed]. Negative values
## become 0 and percentages are clamped to 100. It does not touch packets already in the queue.
func configure(rtt_ms: int, jitter_ms: int, loss_percent: float, duplicate_percent: float,
		seed: int) -> void:
	_rtt_ms = maxi(rtt_ms, 0)
	_jitter_ms = maxi(jitter_ms, 0)
	_loss_percent = clampf(loss_percent, 0.0, 100.0)
	_duplicate_percent = clampf(duplicate_percent, 0.0, 100.0)
	_seed = seed
	_rng.seed = seed


## true if the simulator does anything (some parameter is greater than 0).
func is_enabled() -> bool:
	return _rtt_ms > 0 or _jitter_ms > 0 or _loss_percent > 0.0 or _duplicate_percent > 0.0


## Puts [param packet] in the queue at tick [param now_tick]. Sets its [member
## NetSim.Packet.due_tick]. If it is on an unreliable channel it can be lost (it does not enter the queue) or
## duplicated (one more copy enters, with its own delay). Reliable ones and authentication
## keep FIFO order per (peer, channel): they are never delivered before an earlier one.
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


## Takes from the queue the packets that come due at [param now_tick] or earlier, in delivery order
## (and, on ties, in arrival order).
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


## Takes from the queue everything it holds for [param peer_id], due or not, in delivery order, and
## forgets its FIFO order. Used by the transport before closing a peer's connection so that what
## was already sent goes out before the cut, or to discard it if the peer no longer exists.
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


## true if the queue holds any packet of [param peer_id].
func has_pending(peer_id: int) -> bool:
	for packet: NetSim.Packet in _pending:
		if packet.peer_id == peer_id:
			return true
	return false


## Number of packets in the queue.
func get_pending_count() -> int:
	return _pending.size()


## Maximum delay (ticks) it adds to a packet in one direction: [code]rtt/2 + jitter[/code]
## rounded as the draw does. With the simulator at a single end, the round trip
## takes at most double.
func get_max_delay_ticks() -> int:
	return maxi(roundi((float(_rtt_ms) * 0.5 + float(_jitter_ms)) / TICK_MS), 0)


## Description of the configuration, for the log and the debug overlay.
func describe() -> String:
	return "rtt=%d ms, jitter=%d ms, pérdida=%s%%, duplicados=%s%%, semilla=%d" % [
		_rtt_ms, _jitter_ms, _percent_text(_loss_percent), _percent_text(_duplicate_percent), _seed,
	]


# A percentage without useless decimals: "5", "1.5".
static func _percent_text(percent: float) -> String:
	if is_equal_approx(percent, roundf(percent)):
		return str(roundi(percent))
	return ("%.2f" % percent).rstrip("0").rstrip(".")


# Rolls an event with probability [param percent] (0-100). With 0 it does not consume the generator.
func _roll(percent: float) -> bool:
	if percent <= 0.0:
		return false
	return _rng.randf() * 100.0 < percent


# Delay of one direction in ticks: rtt/2 ± jitter (uniform), rounded and never negative.
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
