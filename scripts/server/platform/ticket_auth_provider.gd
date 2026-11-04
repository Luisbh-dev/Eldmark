class_name TicketAuthProvider
extends AuthProvider
## Entry with the platform's ticket (docs/platform.md §5.2): [method authenticate] is synchronous and
## network-free; any failure is REJECT [constant NetProtocol.Result.TICKET] and nothing reaches the platform.
## [br][br]
## [codeblock]
## 0. fenced zone (no accepted heartbeat)                -> UNAVAILABLE
## 1. 52 B, version 1, known key_id, correct signature   -> otherwise TICKET (constant-time signature)
## 2. world_id, zone_key and channel of this zone        -> otherwise TICKET ("ticket from another zone")
## 3. issued_at ≤ now + 5 and now ≤ expires_at + 5       -> otherwise TICKET (now: the platform's clock)
## 4. character_id equal to the HELLO's                  -> otherwise TICKET
## 5. ticket_id not seen in the last 30 s                -> otherwise TICKET ("reused")
## [/codeblock]
## If it passes, it requests the claim ([method ZonePlatform.claim]) and returns [constant AuthProvider.PENDING]: the
## claim truly guarantees single use and takes the lease. Its response arrives as a
## [code]claim[/code] event ([method on_platform_event]) and becomes an [AuthOutcome]:
## [codeblock]
## 200                                         OK with the ClaimedCharacter (the zone checks realm, capacity and load)
## 409 ticket_invalid                          TICKET
## 409 character_busy                          BUSY
## 403 account_blocked                         BANNED with the body's message
## 409 instance_lost/replaced/stopped          UNAVAILABLE (and the shutdown of §6.1, via instance_closed)
## any other, offline                          UNAVAILABLE (a 4xx, with an alert in the log)
## [/codeblock]
## A 200 for a peer that is no longer waiting (it left, or its 7 s deadline expired) is released immediately.

## Clock margin when checking expiry (s).
const CLOCK_SKEW_S: int = 5
## How long an already-seen ticket_id is remembered (s).
const REUSE_WINDOW_S: int = 30
## REJECT TICKET for a HELLO without a ticket (§5.5).
const NO_TICKET_TEXT: String = "Entra desde el menú con tu cuenta"

## Reason for the last synchronous rejection (for the log and tests): "firma" (signature), "otra zona" (another zone), "caducado" (expired),
## "personaje" (character), "reutilizado" (reused), "cercada" (fenced) or "sin billete" (no ticket).
var last_rejection: String = ""
## The zone's log (a [Callable] with a text); without it, print.
var log_sink: Callable = Callable()

var _platform: ZonePlatform
var _world_id: int
var _zone_key: int
var _channel: int
var _keys: Dictionary[int, PackedByteArray] = {}
## ticket_id -> time (Unix) at which it was seen.
var _seen: Dictionary[int, int] = {}
## peer_id -> character_id of those waiting for their claim.
var _pending: Dictionary[int, int] = {}
var _completed: Array[AuthOutcome] = []


## [param keys]: the ticket's keys ([code]{key_id: key}[/code], from [method ZonePlatform.read_secrets]).
func _init(platform: ZonePlatform, world_id: int, zone_id: String, channel: int,
		keys: Dictionary[int, PackedByteArray]) -> void:
	_platform = platform
	_world_id = world_id
	_zone_key = HandoffTicket.zone_key_of(zone_id)
	_channel = channel
	_keys = keys


func uses_tickets() -> bool:
	return true


func authenticate(peer_id: int, hello: NetMessages.Hello) -> int:
	if _platform.is_fenced():
		return _rejected("cercada", NetProtocol.Result.UNAVAILABLE)
	if hello.ticket.is_empty():
		return _rejected("sin billete", NetProtocol.Result.TICKET)
	var ticket: HandoffTicket = HandoffTicket.decode(hello.ticket)
	if ticket == null or not ticket.verify(hello.ticket, _keys):
		return _rejected("firma", NetProtocol.Result.TICKET)
	if ticket.world_id != _world_id or ticket.zone_key != _zone_key or ticket.channel != _channel:
		return _rejected("otra zona", NetProtocol.Result.TICKET)
	var now: int = _platform.now_unix()
	if ticket.issued_at > now + CLOCK_SKEW_S or now > ticket.expires_at + CLOCK_SKEW_S:
		return _rejected("caducado", NetProtocol.Result.TICKET)
	if ticket.character_id != hello.character_id:
		return _rejected("personaje", NetProtocol.Result.TICKET)
	_forget_seen(now)
	if _seen.has(ticket.ticket_id):
		return _rejected("reutilizado", NetProtocol.Result.TICKET)
	_seen[ticket.ticket_id] = now
	_pending[peer_id] = ticket.character_id
	last_rejection = ""
	_platform.claim(peer_id, ticket)
	return PENDING


func on_platform_event(event: PlatformEvent) -> bool:
	if event.kind != PlatformEvent.KIND_CLAIM or not event.context is Dictionary:
		return false
	var context: Dictionary = event.context
	var peer_id: int = int(context.get("peer_id", 0))
	var character_id: int = int(context.get("character_id", 0))
	var waiting: bool = _pending.get(peer_id, -1) == character_id
	if waiting:
		_pending.erase(peer_id)
	if event.is_success():
		var claimed: ClaimedCharacter = ClaimedCharacter.from_claim(event.body_dict())
		if claimed == null or claimed.character_id != character_id:
			_log("Alerta: la reclamación del personaje %d trae un cuerpo que no se entiende; se libera"
					% character_id)
			var lease_id: String = PlatformJson.text_in(event.body_dict(), "lease_id")
			if not lease_id.is_empty():
				_platform.release(character_id, lease_id)
			if waiting:
				_completed.append(AuthOutcome.new(peer_id, NetProtocol.Result.UNAVAILABLE))
			return true
		if not waiting:
			# The peer left (or its deadline expired) before the response: the lease is not left dangling.
			_platform.release(claimed.character_id, claimed.lease_id)
			return true
		_completed.append(AuthOutcome.new(peer_id, NetProtocol.Result.OK, "", claimed))
		return true
	if not waiting:
		return true
	_completed.append(outcome_of_failure(peer_id, event))
	return true


## The [AuthOutcome] of a claim that was not a 200 (table in §5.2).
func outcome_of_failure(peer_id: int, event: PlatformEvent) -> AuthOutcome:
	if not event.transport_ok:
		return AuthOutcome.new(peer_id, NetProtocol.Result.UNAVAILABLE)
	match event.error_code:
		"ticket_invalid":
			return AuthOutcome.new(peer_id, NetProtocol.Result.TICKET)
		"character_busy":
			return AuthOutcome.new(peer_id, NetProtocol.Result.BUSY)
		"account_blocked":
			var error: Dictionary = event.error_dict()
			_log("Reclamación de una cuenta bloqueada (peer %d): %s hasta %s" % [peer_id,
					PlatformJson.text_in(error, "kind"), str(error.get("until_unix"))])
			return AuthOutcome.new(peer_id, NetProtocol.Result.BANNED, PlatformJson.text_in(error, "message"))
	if event.status >= 400 and event.status < 500 and not PlatformEvent.CLOSING_CODES.has(event.error_code):
		_log("Alerta: la reclamación (peer %d) recibe %s" % [peer_id, ZonePlatform.describe(event)])
	return AuthOutcome.new(peer_id, NetProtocol.Result.UNAVAILABLE)


func take_completed() -> Array[AuthOutcome]:
	var taken: Array[AuthOutcome] = _completed
	_completed = []
	return taken


func cancel(peer_id: int) -> void:
	_pending.erase(peer_id)


## Peers waiting for their claim (tests).
func pending_count() -> int:
	return _pending.size()


func _rejected(reason: String, result: int) -> int:
	last_rejection = reason
	return result


func _forget_seen(now: int) -> void:
	for ticket_id: int in _seen.keys():
		if now - _seen[ticket_id] > REUSE_WINDOW_S:
			_seen.erase(ticket_id)


func _log(text: String) -> void:
	if log_sink.is_valid():
		log_sink.call(text)
	else:
		print("[Eldmark] %s" % text)
