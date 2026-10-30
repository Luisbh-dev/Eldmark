class_name DevAuthProvider
extends AuthProvider
## Proveedor sin plataforma (fase 2 y [code]--server[/code] sin [code]--platform[/code]): acepta en el acto el
## reino y el nombre que declara el cliente, sin cuentas ni billetes (docs/red.md, sección 12). Los personajes son
## efímeros y nada se guarda (docs/progresion.md §9.4). Con la plataforma, [TicketAuthProvider].


func authenticate(_peer_id: int, _hello: NetMessages.Hello) -> int:
	return NetProtocol.Result.OK
