class_name UnstuckTracker
extends RefCounted
## The /atascado (/stuck) command (docs/fortress.md, section 5; MUN-41): what the server remembers of each player to decide
## whether they can use it. A channel of [constant CHANNEL_TICKS] (10 s) that is interrupted if the player enters combat
## (damage interrupts it) or dies, can only be started out of combat, and after completing it there is a
## [constant COOLDOWN_TICKS] (5 min) cooldown. An interrupted channel does not spend the cooldown.
## [br][br]
## Pure and network-free: [ZoneServer] calls [method request] on receiving UNSTUCK_REQUEST, [method update] every tick for
## each live channel and does the teleport itself when [method update] says it has completed.

## Result of [method request].
enum RequestResult { STARTED, IN_COMBAT, COOLDOWN, ALREADY_CHANNELING, DEAD }
## Result of [method update].
enum UpdateResult { CHANNELING, INTERRUPTED, COMPLETED }

## Channel ticks (10 s).
const CHANNEL_TICKS: int = 600
## Cooldown ticks after completing (5 min).
const COOLDOWN_TICKS: int = 18000

# Player name key -> tick at which the channel ends.
var _channel_end: Dictionary[String, int] = {}
# player (name key) -> first tick at which they can use it again.
var _ready_at: Dictionary[String, int] = {}
## Channel and cooldown ticks of this instance ([constant CHANNEL_TICKS] and [constant COOLDOWN_TICKS] by default; tests
## shorten them).
var channel_ticks: int = CHANNEL_TICKS
var cooldown_ticks: int = COOLDOWN_TICKS
## Channels completed since the tracker has existed.
var completed_count: int = 0
## Interrupted channels.
var interrupted_count: int = 0


## [param player] (their name key, so that re-entering does not skip the cooldown; with the platform,
## [code]"character:<id>"[/code], docs/progression.md §8) requests /atascado at tick [param tick], while [param alive] and
## [param in_combat]. If it applies, the channel starts ([constant RequestResult.STARTED]).
func request(player: String, tick: int, alive: bool, in_combat: bool) -> int:
	if not alive:
		return RequestResult.DEAD
	if _channel_end.has(player):
		return RequestResult.ALREADY_CHANNELING
	if in_combat:
		return RequestResult.IN_COMBAT
	if tick < _ready_at.get(player, 0):
		return RequestResult.COOLDOWN
	_channel_end[player] = tick + channel_ticks
	return RequestResult.STARTED


## Advances the channel of [param player] at tick [param tick]: it is interrupted if they are no longer alive or have
## entered combat, and completes on reaching its final tick (then the cooldown starts). Returns
## [constant UpdateResult.CHANNELING] if there is no channel.
func update(player: String, tick: int, alive: bool, in_combat: bool) -> int:
	if not _channel_end.has(player):
		return UpdateResult.CHANNELING
	if not alive or in_combat:
		_channel_end.erase(player)
		interrupted_count += 1
		return UpdateResult.INTERRUPTED
	if tick >= _channel_end[player]:
		_channel_end.erase(player)
		_purge_expired(tick)
		_ready_at[player] = tick + cooldown_ticks
		completed_count += 1
		return UpdateResult.COMPLETED
	return UpdateResult.CHANNELING


## true if [param player] is channeling.
func is_channeling(player: String) -> bool:
	return _channel_end.has(player)


## Keys of the players that are channeling, sorted.
func get_channeling() -> PackedStringArray:
	var keys := PackedStringArray(_channel_end.keys())
	keys.sort()
	return keys


## Ticks left until [param player] can use it again at [param tick] (0 if they already can).
func cooldown_remaining(player: String, tick: int) -> int:
	return maxi(_ready_at.get(player, 0) - tick, 0)


## Ticks left in the channel of [param player] at [param tick] (0 if not channeling).
func channel_remaining(player: String, tick: int) -> int:
	return maxi(_channel_end.get(player, tick) - tick, 0)


## Cancels the channel of [param player] without counting it as interrupted (they leave the world). The cooldown is
## kept: re-entering does not skip it.
func cancel(player: String) -> void:
	_channel_end.erase(player)


## First tick at which [param player] can use it again (0 if they never used it or it already expired and was
## forgotten). With the platform, progress stores it as the [code]unstuck[/code] timer (docs/progression.md §8).
func get_ready_at(player: String) -> int:
	return _ready_at.get(player, 0)


## Sets the cooldown of [param player] until tick [param tick] (restored by registration from the saved timer,
## docs/progression.md §8); with 0 or less, removes it.
func set_ready_at(player: String, tick: int) -> void:
	if tick <= 0:
		_ready_at.erase(player)
	else:
		_ready_at[player] = tick


# Forgets expired cooldowns, so that the dictionary does not grow with every name that used it.
func _purge_expired(tick: int) -> void:
	for key: String in _ready_at.keys():
		if _ready_at[key] <= tick:
			_ready_at.erase(key)
