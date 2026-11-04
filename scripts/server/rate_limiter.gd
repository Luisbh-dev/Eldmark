class_name RateLimiter
extends RefCounted
## Token bucket measured in ticks (docs/networking.md, section 12): the server uses it to limit what each peer can send.
## [br][br]
## The bucket starts full ([code]burst[/code] tokens) and recovers [code]rate_per_tick[/code] tokens for each tick that
## passes, without exceeding [code]burst[/code]. It reads no clock: the caller gives it the current tick, so it is
## reproducible in tests.

var _rate_per_tick: float
var _burst: float
var _tokens: float
## Tick of the last refill, or -1 before the first query.
var _last_tick: int = -1


## [param rate_per_tick] tokens recovered per tick; [param burst] bucket capacity (and initial tokens). Negative values
## are treated as 0.
func _init(rate_per_tick: float, burst: float) -> void:
	_rate_per_tick = maxf(rate_per_tick, 0.0)
	_burst = maxf(burst, 0.0)
	_tokens = _burst


## Tries to spend [param cost] tokens at tick [param now_tick]. Returns true if there were enough (and spends them) and
## false if not (and spends nothing). A cost greater than the bucket capacity is never granted. A tick earlier than the
## last one queried does not refill.
func try_consume(now_tick: int, cost: float = 1.0) -> bool:
	_refill(now_tick)
	if cost > _tokens:
		return false
	_tokens -= cost
	return true


## Grants [param extra] more tokens at tick [param now_tick], above capacity. It first refills up to [param now_tick]
## and then adds, so the credit is not lost in that same refill; the next refill (one tick later) limits the bucket to
## capacity again. It serves to compensate whoever queries when they themselves stopped advancing the tick (a server
## stall): what the client sent during the stall arrives together and is not a rate excess. A negative credit does
## nothing.
func grant(now_tick: int, extra: float) -> void:
	_refill(now_tick)
	_tokens += maxf(extra, 0.0)


## Tokens available at tick [param now_tick] (refill included, spending nothing).
func get_tokens(now_tick: int) -> float:
	_refill(now_tick)
	return _tokens


## Bucket capacity.
func get_burst() -> float:
	return _burst


func _refill(now_tick: int) -> void:
	if _last_tick < 0:
		_last_tick = now_tick
		return
	if now_tick > _last_tick:
		_tokens = minf(_burst, _tokens + _rate_per_tick * float(now_tick - _last_tick))
		_last_tick = now_tick
