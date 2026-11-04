class_name DevAuthProvider
extends AuthProvider
## Provider without a platform (phase 2 and [code]--server[/code] without [code]--platform[/code]): it immediately accepts the
## realm and name the client declares, with no accounts or tickets (docs/red.md, section 12). Characters are
## ephemeral and nothing is saved (docs/progresion.md §9.4). With the platform, [TicketAuthProvider].


func authenticate(_peer_id: int, _hello: NetMessages.Hello) -> int:
	return NetProtocol.Result.OK
