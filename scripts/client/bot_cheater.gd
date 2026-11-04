class_name BotCheater
extends RefCounted
## Cheating bot (docs/red.md, sections 12 and 16; TEC-46): the behavior of [code]--bot-cheat[/code].
## [br][br]
## [NetClient] queries it in two places: when building the HELLO ([method tamper_hello]) and, once
## per physics tick, after sending its honest batch of inputs ([method extra_packets]). The bot
## keeps playing clean underneath: what changes is the extra traffic this object adds. What should
## happen on the server with each mode ([constant MODES]):
## [codeblock]
## version  HELLO with another protocol version         -> REJECT VERSION, the bot never gets in
## future   batches with ticks far ahead                -> TOO_EARLY: discarded and counted, with
##          (beyond MAX_INPUT_LEAD_TICKS)                  no effect on anyone and no advantage
## dupes    different copies of the same inputs         -> the first copy wins: the honest one
## garbage  random packets on the input channel         -> warnings (malformed / unexpected type)
##          and on the reliable one                        and a kick NOTICE at 50 in 600 ticks
## flood    more packets per tick than the limiters     -> rate-excess warnings and a kick
##          allow
## rewind   fights (combat brain) but fakes the         -> the hit is not proven (more than 24 ticks
##          view_offset_q of all its inputs to 40          of rewind): no damage and the peer's
##          ticks                                          suspicion score rises with each hit
## reach    attacks an enemy from 5 m, with legitimate  -> no hit: the weapon's sector reaches
##          inputs                                         2.6 m (3 m with the capsule)
## rate     mashes PRIMARY (one edge every two ticks,   -> no faster than the combo in the data: the
##          the most that can be pressed)                  server's action machine sets the pace
## reuse    mashes ability 1 (the shield strike)        -> an ability on cooldown does not fire: one
##          stuck to the enemy, one edge every two ticks   hit every cooldown + cast ticks (CMB-19)
## potion   mashes both potions                         -> without charges or in the shared cooldown
##                                                         nothing is drunk: no extra healing or
##                                                         resistance
## interact mashes INTERACT away from everyone          -> it revives and finishes nobody
## [/codeblock]
## The combat modes ([constant COMBAT_MODES]: rewind, reach, rate and those from phase 4, reuse,
## potion and interact; docs/habilidades.md, section 4.7) send no extra traffic: the bot plays by
## the game's rules ([method make_brain]), with no possible suspicion, and the server must leave it
## without an advantage. The seeds come from the configuration ([member ClientConfig.bot_seed]), so
## what it sends is reproducible. This is client-only: the server does not know who is cheating, it only validates.

const MODE_VERSION: String = "version"
const MODE_FUTURE: String = "future"
const MODE_DUPES: String = "dupes"
const MODE_GARBAGE: String = "garbage"
const MODE_FLOOD: String = "flood"
const MODE_REWIND: String = "rewind"
const MODE_REACH: String = "reach"
const MODE_RATE: String = "rate"
const MODE_REUSE: String = "reuse"
const MODE_POTION: String = "potion"
const MODE_INTERACT: String = "interact"
## The supported modes of [code]--bot-cheat[/code].
const MODES: Array[String] = [MODE_VERSION, MODE_FUTURE, MODE_DUPES, MODE_GARBAGE, MODE_FLOOD,
		MODE_REWIND, MODE_REACH, MODE_RATE, MODE_REUSE, MODE_POTION, MODE_INTERACT]
## The modes that change how the bot plays (they have their own brain, [method make_brain]).
const COMBAT_MODES: Array[String] = [MODE_REWIND, MODE_REACH, MODE_RATE, MODE_REUSE, MODE_POTION,
		MODE_INTERACT]

## Protocol version that [constant MODE_VERSION] mode lies about.
const FAKE_PROTOCOL_VERSION: int = NetProtocol.PROTOCOL_VERSION + 1
## Ticks, in addition to [constant NetProtocol.MAX_INPUT_LEAD_TICKS], by which the batch of
## [constant MODE_FUTURE] mode is moved ahead (as a minimum; a random amount is added).
const FUTURE_MIN_EXTRA_TICKS: int = 10
const FUTURE_RANDOM_EXTRA_TICKS: int = 40
## Inputs in each extra batch of the [constant MODE_FUTURE] and [constant MODE_DUPES] modes.
const EXTRA_BATCH_INPUTS: int = 4
## Copies of the honest batch that [constant MODE_FLOOD] mode sends per tick (the limiter allows 2
## per tick with a burst of 30) and filler reliable packets.
const FLOOD_COPIES_PER_TICK: int = 8
const FLOOD_RELIABLE_PER_TICK: int = 2
## Size (in bytes) of the garbage: never 2 (valid CLIENT_READY and CLIENT_LEAVE) nor more than what
## fits in an unreliable packet.
const GARBAGE_MIN_BYTES: int = 3
const GARBAGE_MAX_BYTES: int = 120
## First byte of the filler packets of [constant MODE_FLOOD] mode: a type that nobody sends to the server.
const FLOOD_FILLER_TYPE: int = 0x7F
## Rewind ticks that [constant MODE_REWIND] mode claims to carry in all its inputs (the server's
## cap is [constant NetProtocol.MAX_REWIND_TICKS]).
const REWIND_VIEW_TICKS: int = 40
## Scale of [code]view_offset_q[/code] (ticks × 16).
const VIEW_OFFSET_SCALE: int = 16


## A packet that the bot sends in addition to its honest batch.
class Extra:
	extends RefCounted

	var channel: int = NetProtocol.CH_INPUT
	var bytes: PackedByteArray = PackedByteArray()


	func _init(p_channel: int, p_bytes: PackedByteArray) -> void:
		channel = p_channel
		bytes = p_bytes


var _mode: String = ""
var _seed: int = 0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _packets: int = 0


## [param mode] must be one of [constant MODES] (otherwise, the object does nothing).
func _init(mode: String, rng_seed: int) -> void:
	_mode = mode.to_lower()
	_seed = rng_seed
	_rng.seed = rng_seed


## true if [param mode] is one of [constant MODES] (case-insensitive).
static func is_valid_mode(mode: String) -> bool:
	return MODES.has(mode.to_lower())


## Current mode.
func get_mode() -> String:
	return _mode


## Extra packets generated since the start.
func get_packets_generated() -> int:
	return _packets


## true if the mode changes how the bot plays ([constant COMBAT_MODES]).
func is_combat_mode() -> bool:
	return COMBAT_MODES.has(_mode)


## The brain a bot of a combat mode plays with, or null if the mode is a traffic one.
## [param enemy_finder] is [code](position: Vector3) -> Variant[/code] (see
## [method BotBrain.set_enemy_finder]). [constant MODE_REWIND] mode fights with the usual combat
## brain (the cheating part is the view it declares, [method tamper_batch]); [constant MODE_REACH], [constant MODE_RATE], [constant MODE_REUSE], [constant MODE_POTION] and [constant MODE_INTERACT] use [BotCheatBrain].
func make_brain(enemy_finder: Callable, home: Vector3, radius: float) -> BotBrain:
	var brain: BotBrain = null
	match _mode:
		MODE_REWIND:
			brain = BotBrain.new(_seed, BotBrain.Pattern.COMBAT, home, radius)
		MODE_REACH:
			brain = BotCheatBrain.new(_seed, BotCheatBrain.Style.REACH, home, radius)
		MODE_RATE:
			brain = BotCheatBrain.new(_seed, BotCheatBrain.Style.RATE, home, radius)
		MODE_REUSE:
			brain = BotCheatBrain.new(_seed, BotCheatBrain.Style.REUSE, home, radius)
		MODE_POTION:
			brain = BotCheatBrain.new(_seed, BotCheatBrain.Style.POTION, home, radius)
		MODE_INTERACT:
			brain = BotCheatBrain.new(_seed, BotCheatBrain.Style.INTERACT, home, radius)
	if brain != null:
		brain.set_enemy_finder(enemy_finder)
	return brain


## Tampers with the honest input batch before sending it. Only [constant MODE_REWIND] mode touches
## it: all its inputs claim that the bot saw the world [constant REWIND_VIEW_TICKS] ticks back.
func tamper_batch(batch: NetMessages.InputBatch) -> void:
	if _mode != MODE_REWIND:
		return
	for index: int in batch.view_offsets_q.size():
		batch.view_offsets_q[index] = REWIND_VIEW_TICKS * VIEW_OFFSET_SCALE


## Tampers with the HELLO about to be sent. Only [constant MODE_VERSION] mode touches it.
func tamper_hello(hello: NetMessages.Hello) -> void:
	if _mode == MODE_VERSION:
		hello.protocol_version = FAKE_PROTOCOL_VERSION


## Extra packets for this tick, to be sent right after the [param honest] batch (the one the bot
## just sent, already with its inputs and offsets). Order matters in [constant MODE_DUPES]: the
## different copies go after the honest one, and the first to arrive wins.
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


# A batch with ticks beyond the server's input window (sprinting ahead): the bot tries to get the
# server to keep them to apply later. They are discarded (TOO_EARLY).
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


# The same inputs as the honest batch (same ticks) but with other content: inverted movement,
# view turned half a turn and different buttons. If the server kept the last copy instead of the
# first, the bot would go the opposite way to what it predicts.
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


# Random bytes, of a size that cannot be a valid 2-byte message.
func _garbage() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(_rng.randi_range(GARBAGE_MIN_BYTES, GARBAGE_MAX_BYTES))
	for i: int in bytes.size():
		bytes[i] = _rng.randi_range(0, 255)
	return bytes

