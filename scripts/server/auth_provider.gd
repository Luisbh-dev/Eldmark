class_name AuthProvider
extends RefCounted
## Identity and realm of a connecting client (docs/red.md, sections 3 and 12; docs/plataforma.md §5.2 and §14.3).
## [br][br]
## [ServerAuth] has already checked the version, the simulation fingerprint, the capacity and the per-IP cap (and, without
## tickets, the realm and the name); the provider decides whether to accept the identity the HELLO declares. This class is
## the base of [DevAuthProvider] (no platform) and of [TicketAuthProvider] (with the platform's ticket). The
## base authenticates nobody: it rejects with [constant NetProtocol.Result.TICKET], so an unimplemented provider
## never lets anyone through.
## [br][br]
## A provider may not decide on the spot: [method authenticate] returns [constant PENDING], the peer waits in
## [constant ServerPeer.State.VERIFYING] and the outcome arrives through [method take_completed] in the tick's "poll" step,
## after dispatching the [PlatformEvent]s ([method on_platform_event]).

## [method authenticate] does not decide yet: the outcome arrives through [method take_completed].
const PENDING: int = -1


## [constant NetProtocol.Result.OK], [constant PENDING] or the REJECT reason (by default
## [constant NetProtocol.Result.TICKET]: ticket missing, invalid or expired).
func authenticate(_peer_id: int, _hello: NetMessages.Hello) -> int:
	return NetProtocol.Result.TICKET


## Handles [param event] if it is its own (kind [code]claim[/code]) and returns true; otherwise, false.
func on_platform_event(_event: PlatformEvent) -> bool:
	return false


## The [constant PENDING] ones resolved since the last call, in order of arrival.
func take_completed() -> Array[AuthOutcome]:
	return []


## Peer [param peer_id] left while in [constant ServerPeer.State.VERIFYING] (or its deadline expired): if its claim
## arrives later, it is released.
func cancel(_peer_id: int) -> void:
	pass


## true if the identity comes from the ticket: [ServerAuth] does not look at the HELLO's realm or name (the claim's
## take precedence) and there is no REJECT NAME (docs/plataforma.md §5.4).
func uses_tickets() -> bool:
	return false
