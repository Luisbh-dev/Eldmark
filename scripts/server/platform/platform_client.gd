class_name PlatformClient
extends Node
## The zone's HTTP client against the platform's internal API (docs/plataforma.md §6), inside
## [ZonePlatform]: threadless [HTTPRequest], a [member timeout_s] deadline per attempt, priority queues and the
## retries for each class of request. It never waits synchronously: it advances with the main loop.
## [br][br]
## [codeblock]
## priority    requests                                        retry
## 0 control   register, live, fortress GETs, first             register, live, GET and first block: 1, 2, 4…
##             block, heartbeat, removal                       s up to 60 s (STARTUP); heartbeat and removal: no
## 1 entry     claim, release                                  claim: no; release: like a save
## 2 player    saves, blocks, operation and ledger,             saves and blocks: the same body at 1, 2, 4,
##             reports, ignores, sanctions                     8 and 15 s, then every 15 s (STEADY); the rest, no
## 3 fortress  fortress PUT                                    every 2 s (FORTRESS)
## 4 batches   chat, audit, war                                2, 4, 8 and 16 s, then every 30 s (BATCH)
## [/codeblock]
## [b]Slots:[/b] one of its own for priority 0 and [constant SHARED_SLOTS] shared ones. Priorities 2 to 4
## take [constant MAX_LOW_PRIORITY_IN_FLIGHT] at most at once, so there are always two left for 1: a
## heartbeat does not wait behind slow saves and a claim goes out even if four are in flight. When a slot
## frees up, the request of highest priority goes out; within each priority, in arrival order (one
## waiting for its retry does not hold back those behind it).
## [br][br]
## [b]Retries:[/b] an attempt with no response (offline or deadline expired), a 5xx or a 401 are repeated with
## the same bytes according to their class; any other response is final and goes to [member Request.on_done]. An
## expired deadline is not a response: a save remains the same body until it has a final one (§7.3).
## [br][br]
## An attempt's transport is [method _perform]: this class's uses [HTTPRequest] and the tests' fake
## ([code]tests/fake_zone_platform.gd[/code]) answers without a network, with everything else the same.

## Retry classes.
enum Retry { NONE, STARTUP, STEADY, BATCH, FORTRESS }

const PRIORITY_CONTROL: int = 0
const PRIORITY_ENTRY: int = 1
const PRIORITY_PLAYER: int = 2
const PRIORITY_FORTRESS: int = 3
const PRIORITY_BATCH: int = 4
const PRIORITY_COUNT: int = 5
## Shared slots (plus the one of its own for priority 0).
const SHARED_SLOTS: int = 6
## Priority 2 to 4 requests in flight at once, at most.
const MAX_LOW_PRIORITY_IN_FLIGHT: int = 4
## Waits (s) before each retry of the STEADY and BATCH classes; the last one repeats.
const STEADY_DELAYS_S: Array[float] = [1.0, 2.0, 4.0, 8.0, 15.0]
const BATCH_DELAYS_S: Array[float] = [2.0, 4.0, 8.0, 16.0, 30.0]
## First STARTUP wait (doubles on each attempt) and the FORTRESS wait.
const STARTUP_FIRST_DELAY_S: float = 1.0
const FORTRESS_DELAY_S: float = 2.0
## Cap on a response body (the internal API does not exceed 1 MB, §6).
const MAX_RESPONSE_BYTES: int = 2 * 1024 * 1024


## A request: the bytes that are sent do not change between attempts.
class Request:
	extends RefCounted
	var method: HTTPClient.Method = HTTPClient.METHOD_GET
	## Path with its query, without the base ([code]/internal/v1/claims[/code]).
	var path: String = ""
	var body: PackedByteArray = PackedByteArray()
	var priority: int = PRIORITY_PLAYER
	## Class of the request (the [PlatformEvent]'s kind if it comes out as an event).
	var kind: StringName = &""
	var context: Variant = null
	var retry: int = Retry.NONE
	## Called with (this request, [PlatformEvent]) when there is a final response or no attempts remain.
	var on_done: Callable = Callable()
	## Attempts made.
	var attempts: int = 0
	## Does not go out before this instant (ms from [method Time.get_ticks_msec]).
	var not_before_msec: int = 0
	## STARTUP: not retried after this instant (ms); -1 = no limit.
	var deadline_msec: int = -1
	## Arrival order.
	var seq: int = 0
	## Slot in which it is in flight (-1 = queued).
	var slot: int = -1


## Base of the paths ([code]http://127.0.0.1:24681[/code], without a trailing slash).
var base_url: String = ""
## The zone's token ([code]Authorization: Bearer[/code]).
var token: String = ""
## Deadline of each attempt (s).
var timeout_s: float = 3.0
## Scale of the waits between retries (1 = those in the table; tests lower it).
var retry_scale: float = 1.0

var _queues: Array[Array] = []
## Slot 0: control's own; 1..SHARED_SLOTS: shared.
var _slots: Array[Request] = []
var _http: Array[HTTPRequest] = []
var _seq: int = 0
var _sent_attempts: int = 0


func _init() -> void:
	for _i: int in PRIORITY_COUNT:
		_queues.append([])
	_slots.resize(SHARED_SLOTS + 1)
	_http.resize(SHARED_SLOTS + 1)


func _process(_delta: float) -> void:
	pump()


## Queues [param request] and sends it as soon as there is a slot (it may go out right away, within this call).
func submit(request: Request) -> void:
	_seq += 1
	request.seq = _seq
	request.slot = -1
	_queues[clampi(request.priority, 0, PRIORITY_COUNT - 1)].append(request)
	pump()


## Requests queued or in flight; not counting those of class [param excluded_kind] if given.
func pending_count(excluded_kind: StringName = &"") -> int:
	var count: int = 0
	for queue: Array in _queues:
		for request: Request in queue:
			if request.kind != excluded_kind:
				count += 1
	for request: Request in _slots:
		if request != null and request.kind != excluded_kind:
			count += 1
	return count


## Requests in flight right now.
func in_flight_count() -> int:
	var count: int = 0
	for request: Request in _slots:
		if request != null:
			count += 1
	return count


## Attempts sent since it came into existence (metrics and tests).
func get_sent_attempts() -> int:
	return _sent_attempts


## Everything waiting for its retry goes out now (orderly shutdown, [method ZonePlatform.begin_flush]).
func hurry() -> void:
	for queue: Array in _queues:
		for request: Request in queue:
			request.not_before_msec = 0
	pump()


## Takes from the queues what can be sent now and puts it in the free slots.
func pump() -> void:
	var now: int = Time.get_ticks_msec()
	for slot: int in _slots.size():
		if _slots[slot] != null:
			continue
		var request: Request = _take_next(slot, now)
		if request == null:
			continue
		_start(slot, request)


# The next request for slot [param slot]: the own one (0) only carries control; the shared ones, the
# highest-priority one that is ready, with the cap for priorities 2 to 4.
func _take_next(slot: int, now: int) -> Request:
	var low_in_flight: int = 0
	for flying: Request in _slots:
		if flying != null and flying.priority >= PRIORITY_PLAYER:
			low_in_flight += 1
	var last_priority: int = PRIORITY_CONTROL if slot == 0 else PRIORITY_COUNT - 1
	for priority: int in range(0, last_priority + 1):
		if priority >= PRIORITY_PLAYER and low_in_flight >= MAX_LOW_PRIORITY_IN_FLIGHT:
			return null
		var queue: Array = _queues[priority]
		for i: int in queue.size():
			var request: Request = queue[i]
			if request.not_before_msec <= now:
				queue.remove_at(i)
				return request
	return null


func _start(slot: int, request: Request) -> void:
	_slots[slot] = request
	request.slot = slot
	request.attempts += 1
	_sent_attempts += 1
	_perform(request)


## An attempt's transport: it must end up calling [method _complete] with [param request] (never
## within this same call). This one uses one [HTTPRequest] per slot.
func _perform(request: Request) -> void:
	var http: HTTPRequest = _http[request.slot]
	if http == null:
		http = HTTPRequest.new()
		http.name = "Slot%d" % request.slot
		http.use_threads = false
		http.accept_gzip = false
		http.body_size_limit = MAX_RESPONSE_BYTES
		add_child(http)
		http.request_completed.connect(_on_http_completed.bind(request.slot))
		_http[request.slot] = http
	http.timeout = timeout_s
	var headers := PackedStringArray(["Authorization: Bearer %s" % token, "Accept: application/json"])
	if not request.body.is_empty():
		headers.append("Content-Type: application/json")
	var error: Error = http.request_raw(base_url + request.path, headers, request.method, request.body)
	if error != OK:
		# It did not go out (bad URL, no tree...): counts as an attempt with no response.
		_complete.call_deferred(request, false, 0, PackedByteArray())


func _on_http_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray,
		slot: int) -> void:
	var request: Request = _slots[slot]
	if request == null:
		return
	_complete(request, result == HTTPRequest.RESULT_SUCCESS, response_code, body)


## End of an attempt: the final response goes to [member Request.on_done]; otherwise, it is queued again with its
## wait (the same bytes).
func _complete(request: Request, transport_ok: bool, status: int, raw: PackedByteArray) -> void:
	if request.slot < 0 or request.slot >= _slots.size() or _slots[request.slot] != request:
		return
	_slots[request.slot] = null
	request.slot = -1
	var event: PlatformEvent = PlatformEvent.from_response(request.kind, request.context, transport_ok, status,
			raw)
	var now: int = Time.get_ticks_msec()
	var delay_s: float = _retry_delay_s(request, event, now)
	if delay_s >= 0.0:
		request.not_before_msec = now + int(delay_s * retry_scale * 1000.0)
		_requeue(request)
	elif request.on_done.is_valid():
		request.on_done.call(request, event)
	pump()


# Wait (s) before retrying, or -1 if the response is final or no attempts remain.
func _retry_delay_s(request: Request, event: PlatformEvent, now: int) -> float:
	if not is_retryable(event):
		return -1.0
	var index: int = request.attempts - 1
	match request.retry:
		Retry.STARTUP:
			var delay: float = STARTUP_FIRST_DELAY_S * pow(2.0, float(mini(index, 10)))
			if request.deadline_msec >= 0 and now + int(delay * retry_scale * 1000.0) > request.deadline_msec:
				return -1.0
			return delay
		Retry.STEADY:
			return STEADY_DELAYS_S[mini(index, STEADY_DELAYS_S.size() - 1)]
		Retry.BATCH:
			return BATCH_DELAYS_S[mini(index, BATCH_DELAYS_S.size() - 1)]
		Retry.FORTRESS:
			return FORTRESS_DELAY_S
	return -1.0


## true if [param event] is not a final response: no response, a 5xx or a 401 (§7.3).
static func is_retryable(event: PlatformEvent) -> bool:
	return not event.transport_ok or event.status >= 500 or event.status == 401


# Returns to the queue of its priority in its arrival order (it is older than those that arrived later).
func _requeue(request: Request) -> void:
	var queue: Array = _queues[clampi(request.priority, 0, PRIORITY_COUNT - 1)]
	var index: int = queue.size()
	for i: int in queue.size():
		if (queue[i] as Request).seq > request.seq:
			index = i
			break
	queue.insert(index, request)
