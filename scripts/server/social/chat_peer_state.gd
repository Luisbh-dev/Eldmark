class_name ChatPeerState
extends RefCounted
## Social state of a connection (docs/social.md, sections 5 and 12): the token buckets for the rates of [ChatRouter] and
## [PartyManager], the last message (to discard repetitions), recent discards (for flooding strikes) and whom it has
## whispered to recently.
## [br][br]
## It lives in the [ServerPeer] and is born full with each connection. Without a platform, rates are [b]per
## connection[/b]: whoever leaves and re-enters recovers the bursts full (also the 5 new whisper recipients), just like
## the transport buckets and strikes (docs/red.md, finding S6); the client chooses its name on each connection, so
## storing it by name would stop nobody. [b]With a platform[/b] (docs/plataforma.md §9.2, P7b) it is [b]per
## character[/b]: [SocialService] keeps it for [constant ChatRouter.KNOWN_RECIPIENT_TICKS] ticks after departure and
## gives it back if the character re-enters this instance, so leaving and coming back does not refill the bursts.
## [br][br]
## With a platform it also carries that account's moderation data (§9.2 to §9.5): its account, those it ignores (from the
## claim, plus those it ignores in this session), until when it is muted (claim, heartbeat or a sanction from this zone),
## the ring of the last messages it received (the evidence for a report) and its recent reports. It reads no clock: rates
## are measured in server ticks and the mute with the Unix time passed by whoever checks it.

## Messages per tick for "talking" (say, zone, party...): 1 per second.
const PUBLIC_RATE_PER_TICK: float = 1.0 / 60.0
## Consecutive messages that the "talking" bucket admits.
const PUBLIC_BURST: float = 5.0
## Whisper messages per tick: 1 per second.
const WHISPER_RATE_PER_TICK: float = 1.0 / 60.0
const WHISPER_BURST: float = 3.0
## New whisper recipients per tick: 5 per minute.
const NEW_RECIPIENT_RATE_PER_TICK: float = 5.0 / 3600.0
const NEW_RECIPIENT_BURST: float = 5.0
## Party invitations per tick (1 every 2 s) and burst (docs/social.md, section 5).
const INVITE_RATE_PER_TICK: float = 1.0 / 120.0
const INVITE_BURST: float = 3.0
## Window (ticks) in which rate discards are counted, the same as the peer's strike window
## ([constant ServerPeer.STRIKE_WINDOW_TICKS], 10 s).
const FLOOD_WINDOW_TICKS: int = 600
## Free discards within the window: pressing Enter too many times adds no strikes; from the next one on, each discard
## adds one.
const FLOOD_FREE_DISCARDS: int = 10


## Rate discards of one message type (chat or invitations): the first [constant FLOOD_FREE_DISCARDS] in every
## [constant FLOOD_WINDOW_TICKS] ticks are free and, from there on, each one adds a strike to the peer. So sustained
## flooding reaches the 50 strikes that trigger a kick even though the transport lets 10 reliables per second through
## without strikes: measured with chat, from 6 messages per second (in about 13 s; at 10 per second, in 7 s). Below that
## it does not kick, but the bucket already leaves the rest at 1 message per second.
class FloodWindow:
	extends RefCounted

	# Ring with the ticks of the last FLOOD_FREE_DISCARDS discards; the oldest is at _head.
	var _ticks: PackedInt64Array = PackedInt64Array()
	var _head: int = 0


	func _init() -> void:
		_ticks.resize(ChatPeerState.FLOOD_FREE_DISCARDS)
		_ticks.fill(-ChatPeerState.FLOOD_WINDOW_TICKS - 1)


	## Records a discard at tick [param now_tick]. Returns true if it adds a strike: there were already
	## [constant ChatPeerState.FLOOD_FREE_DISCARDS] discards in the last [constant ChatPeerState.FLOOD_WINDOW_TICKS] ticks.
	func note(now_tick: int) -> bool:
		var oldest: int = _ticks[_head]
		_ticks[_head] = now_tick
		_head = (_head + 1) % _ticks.size()
		return now_tick - oldest < ChatPeerState.FLOOD_WINDOW_TICKS


## Received messages kept by each receiver's ring as evidence for a report (docs/plataforma.md §9.4).
const RECEIVED_RING_SIZE: int = 100
## Mute with no end (the Unix time given by the platform: 9999-12-31).
const MUTE_NO_END_UNIX: int = 253402300799


## A message this player received, as evidence for a report. One per delivered message: the rings of all who received
## it share it.
class Received:
	extends RefCounted

	## Comparison key of the sender's name ([method NameRules.normalize_key]).
	var sender_key: String = ""
	var sender_name: String = ""
	## [enum ChatChannel.Id].
	var channel: int = 0
	var text: String = ""
	var sent_at_unix: int = 0
	var tick: int = 0


var limiter_public: RateLimiter = RateLimiter.new(PUBLIC_RATE_PER_TICK, PUBLIC_BURST)
var limiter_whisper: RateLimiter = RateLimiter.new(WHISPER_RATE_PER_TICK, WHISPER_BURST)
var limiter_new_recipients: RateLimiter = RateLimiter.new(NEW_RECIPIENT_RATE_PER_TICK,
		NEW_RECIPIENT_BURST)
## Bucket of the party invitations it sends ([PartyManager]), those discarded from it by rate, its recent discards and
## the tick of the last "Invitas demasiado rápido" (too many invitations too fast) warning.
var limiter_invites: RateLimiter = RateLimiter.new(INVITE_RATE_PER_TICK, INVITE_BURST)
var invite_discards: int = 0
var invite_flood: FloodWindow = FloodWindow.new()
var last_invite_warning_tick: int = -1
## Last accepted text, where it was sent ([code]""[/code] in public channels, which share the check; [code]"w:"[/code]
## and the name key in a whisper) and tick at which it was accepted (for discarding repetitions).
var last_text: String = ""
var last_text_key: String = ""
var last_text_tick: int = -1
## Chat messages discarded by rate or repetition in total, and the recent ones (flooding strikes).
var discards: int = 0
var chat_flood: FloodWindow = FloodWindow.new()
## Tick of the last discarded-chat warning sent to it (so as not to send one per message).
var last_warning_tick: int = -1
## Comparison key of its name ([method NameRules.normalize_key]), computed the first time.
var name_key: String = ""
## Name key -> last tick at which it whispered to that character or that character to it. Whoever is here does not count
## as a new recipient. Pruned every time this player whispers or is whispered to, so it only keeps the conversation
## partners of the last [constant ChatRouter.KNOWN_RECIPIENT_TICKS] ticks.
var known_recipients: Dictionary[String, int] = {}

## With a platform: the character's account (0 without a platform) and the accounts it ignores (account -> true): their
## messages, whispers and invitations do not reach it (docs/plataforma.md §9.3).
var account_id: int = 0
var ignored_accounts: Dictionary[int, bool] = {}
## Those it has ignored in this session, by the key of the name it typed (for [code]/designorar[/code] (unignore), which
## the platform answers without the account).
var ignored_by_name: Dictionary[String, int] = {}
## Unix time until which it is muted (0 = not muted; [constant MUTE_NO_END_UNIX] = no end).
var muted_until_unix: int = 0
## Instant ([code]Time.get_ticks_msec()[/code]) at which a sanction from this zone changed the mute: a heartbeat that
## went out earlier does not undo it (docs/plataforma.md §9.5).
var mute_changed_msec: int = -1
## Ring of the last [constant RECEIVED_RING_SIZE] received messages; the oldest is at [member received_head] when the
## ring is full.
var received: Array[Received] = []
var received_head: int = 0
## Recent reports: name key -> tick of the last one against that character, and the ticks of those in the last hour.
var reported_at: Dictionary[String, int] = {}
var report_ticks: PackedInt64Array = PackedInt64Array()

## Counters (report): messages accepted, delivered (copies sent), discarded by rate, by repetition, for being empty
## text, rejected for unavailable channel and for nonexistent recipient, and those that did not go out because the
## sender is muted.
var accepted: int = 0
var delivered: int = 0
var discarded_rate: int = 0
var discarded_repeat: int = 0
var discarded_empty: int = 0
var rejected_channel: int = 0
var whisper_misses: int = 0
## Messages that did not go out because the sender was muted.
var discarded_muted: int = 0


## Remembers [param key] as a whisper conversation partner at tick [param now_tick].
func remember_recipient(key: String, now_tick: int) -> void:
	known_recipients[key] = now_tick


## true if [param key] whispered with this player, or the other way round, in the last [param window_ticks] ticks up to
## [param now_tick].
func knows_recipient(key: String, now_tick: int, window_ticks: int) -> bool:
	return known_recipients.has(key) and now_tick - known_recipients[key] < window_ticks


## Forgets the conversation partners that no longer count (older than [param window_ticks]), so that the dictionary does
## not grow without limit.
func forget_old_recipients(now_tick: int, window_ticks: int) -> void:
	for key: String in known_recipients.keys():
		if now_tick - known_recipients[key] >= window_ticks:
			known_recipients.erase(key)


## true if it ignores the account [param other_account] (0 never: without a platform there are no accounts).
func ignores_account(other_account: int) -> bool:
	return other_account > 0 and ignored_accounts.has(other_account)


## Seconds of mute it has left at Unix time [param now_unix] (0 if not muted).
func mute_remaining_s(now_unix: int) -> int:
	return maxi(muted_until_unix - now_unix, 0) if muted_until_unix > 0 else 0


## Records [param line] in the ring of received messages.
func remember_received(line: Received) -> void:
	if received.size() < RECEIVED_RING_SIZE:
		received.append(line)
		return
	received[received_head] = line
	received_head = (received_head + 1) % RECEIVED_RING_SIZE


## The messages from whoever has the name key [param sender_key] received since tick [param since_tick], from oldest to
## most recent, the last [param limit] ones.
func received_from(sender_key: String, since_tick: int, limit: int) -> Array[Received]:
	var found: Array[Received] = []
	var count: int = received.size()
	for offset: int in count:
		var line: Received = received[(received_head + offset) % count] if count == RECEIVED_RING_SIZE \
				else received[offset]
		if line.sender_key == sender_key and line.tick >= since_tick:
			found.append(line)
	while found.size() > limit:
		found.pop_front()
	return found
