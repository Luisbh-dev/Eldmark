class_name ServerPeer
extends RefCounted
## State the server keeps for each connection (docs/networking.md, sections 3, 8, 11 and 12).
## [br][br]
## It does not touch the network: [code]ZoneServer[/code] fills and queries it. Here live the rate limiters, the strike
## counter (with a kick at 50 in 600 ticks), the peer's set of relevant entities and the [SnapshotBuilder]'s priority
## accumulator.

## Session phase: authenticating (until the HELLO), verifying the ticket (waiting for the platform's claim,
## docs/platform.md §5.2), loading the zone (until CLIENT_READY), inside the world or leaving.
enum State { AUTHENTICATING, VERIFYING, LOADING, IN_WORLD, LEAVING }

## Unreliable messages per tick that the limiter admits (120 per second) and maximum burst.
const UNRELIABLE_RATE_PER_TICK: float = 2.0
const UNRELIABLE_BURST: float = 30.0
## Reliable messages per tick (10 per second) and maximum burst.
const RELIABLE_RATE_PER_TICK: float = 10.0 / 60.0
const RELIABLE_BURST: float = 20.0
## Bytes per tick (16 KB/s) and maximum burst (4 KB).
const BYTES_RATE_PER_TICK: float = 16.0 * 1024.0 / 60.0
const BYTES_BURST: float = 4.0 * 1024.0
## Strikes that trigger a kick and tick window in which they are counted.
const STRIKE_LIMIT: int = 50
const STRIKE_WINDOW_TICKS: int = 600

var peer_id: int
var state: State = State.AUTHENTICATING
var realm: int
var display_name: String
var remote_address: String
## The player's entity (null until it enters the world).
var entity: NetEntity
## The player's input queue (null until it enters the world).
var input_queue: InputQueue
## Entities this peer considers relevant: net_id -> true. Maintained by the server with the [InterestPolicy] and read by
## the [SnapshotBuilder].
var relevant: Dictionary[int, bool] = {}
## Priority accumulator per relevant entity (net_id -> priority). Maintained by the [SnapshotBuilder]: it rises with
## each snapshot and returns to 0 when the entity is sent.
var priority: Dictionary[int, float] = {}
## [code]server_tick[/code] of the newest snapshot the client has acknowledged (0 = none).
var ack_snapshot_tick: int = 0
## Interpolation delay declared by the client (in ticks times 8).
var interp_delay_q: int = 0
## Minimum of (s - ack_snapshot_tick) over the last 120 ticks.
var rtt_ticks: int = 0
## Maximum of (s - ack_snapshot_tick) over the same 120 ticks, bounded just like [member rtt_ticks] by sources the client
## does not control. With jitter the minimum stays below the round trip of any given tick, and the rewind cap (docs/networking.md,
## section 10) must also cover the bad trips of an honest player: the [CombatResolver] uses the greater of the two.
var rtt_peak_ticks: int = 0
## Lower bound of the RTT in ticks that comes from sources the client does not control (ENet's RTT): an honest client
## never sees the world with less delay than this, even if it delays or advances its acks.
var rtt_floor_ticks: int = 0
## Tick at which it connected and began authenticating (for the HELLO deadline).
var connected_tick: int = 0
## Instant (ms of [code]Time.get_ticks_msec()[/code]) at which it connected: the 7 s deadline of VERIFYING runs in real
## time, because one in ticks went out of sync when the server lagged (docs/platform.md §5.2).
var connected_at_msec: int = 0
## The [code]character_id[/code] of the HELLO (0 without a ticket).
var character_id: int = 0
## With the platform, what the claim brought (from the WELCOME; null without a platform or before).
var claimed: ClaimedCharacter = null
## Leaves without the combat exit (GUE-41): the departure without a save of docs/platform.md §7.2 (a rejected save or a
## [code]revoked[/code] [code]lease_lost[/code]) removes the body at once.
var drop_body_at_once: bool = false
## Kicked by the zone: its final save carries reason 5 (docs/platform.md §7.3) instead of 3.
var kicked: bool = false
## Tick at which the zone load began (for the CLIENT_READY limit).
var loading_since_tick: int = 0
var limiter_unreliable: RateLimiter
var limiter_reliable: RateLimiter
var limiter_bytes: RateLimiter
## Rates and counters of this peer's chat ([ChatRouter], docs/social.md section 5).
var chat: ChatPeerState = ChatPeerState.new()
## Strikes added in total and the reason for the last one.
var strikes_total: int = 0
var last_strike_reason: String = ""
## Combat suspicion score (docs/combat.md, 4.5): adds 1 for each hit whose rewind exceeds the cap and is not tested. In
## phase 3 it is only logged (report and [code]--combat-log[/code]).
var suspicion_score: int = 0
## Hits rejected for excessive rewind.
var rewind_rejects: int = 0
## Attacks it has launched and how many of them have hit (an anomalous hit ratio is one of the future suspicion signals).
var swings: int = 0
var swings_landed: int = 0
## Pending equipment template (docs/abilities.md, section 4.6): the one requested with LOADOUT_SELECT for its next
## spawn (0 = the default; -1 = no request). Valid in LOADING and IN_WORLD; the server copies it to the [Combatant] when
## registering it and at each respawn, and sets it back to -1.
var pending_template_id: int = -1

# Ring with the ticks of the last STRIKE_LIMIT strikes. The oldest of them is at _strike_head, which is also the slot
# overwritten by the next one. 64-bit: server ticks are u32 and exceed 2^31 after 414 days of process uptime.
var _strike_ticks: PackedInt64Array = PackedInt64Array()
var _strike_head: int = 0


## Creates the peer with its section 12 rate limiters.
func _init(id: int = 0) -> void:
	peer_id = id
	limiter_unreliable = RateLimiter.new(UNRELIABLE_RATE_PER_TICK, UNRELIABLE_BURST)
	limiter_reliable = RateLimiter.new(RELIABLE_RATE_PER_TICK, RELIABLE_BURST)
	limiter_bytes = RateLimiter.new(BYTES_RATE_PER_TICK, BYTES_BURST)
	_strike_ticks.resize(STRIKE_LIMIT)
	_strike_ticks.fill(-STRIKE_WINDOW_TICKS - 1)


## Gives the three limiters the credit of [param missed_ticks] ticks that the server did not simulate (a process stall)
## at tick [param now_tick]: what the client kept sending during the stall arrives together and must not count as a rate
## excess. The credit lasts until the next refill (see [method RateLimiter.grant]).
func grant_stall_credit(now_tick: int, missed_ticks: int) -> void:
	if missed_ticks <= 0:
		return
	var ticks: float = float(missed_ticks)
	limiter_unreliable.grant(now_tick, UNRELIABLE_RATE_PER_TICK * ticks)
	limiter_reliable.grant(now_tick, RELIABLE_RATE_PER_TICK * ticks)
	limiter_bytes.grant(now_tick, BYTES_RATE_PER_TICK * ticks)


## Adds a strike at tick [param now_tick] for [param reason] (malformed packet, unexpected type for the session state or
## rate excess). Returns true if the peer must be kicked: [constant STRIKE_LIMIT] strikes within the last
## [constant STRIKE_WINDOW_TICKS] ticks (a strike from tick t counts until tick t + 599).
func add_strike(now_tick: int, reason: String) -> bool:
	strikes_total += 1
	last_strike_reason = reason
	_strike_ticks[_strike_head] = now_tick
	_strike_head = (_strike_head + 1) % STRIKE_LIMIT
	# The slot to use now is that of the oldest strike among the last STRIKE_LIMIT.
	var oldest: int = _strike_ticks[_strike_head]
	return strikes_total >= STRIKE_LIMIT and now_tick - oldest < STRIKE_WINDOW_TICKS
