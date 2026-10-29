class_name AuthProvider
extends RefCounted
## Identidad y reino de un cliente que se conecta (docs/red.md, secciones 3 y 12).
## [br][br]
## [ServerAuth] ya ha comprobado la versión, la huella de la simulación, el reino, el nombre, el
## cupo y el tope por IP; el proveedor decide solo si acepta la identidad que declara el HELLO.
## Esta clase es la base de [DevAuthProvider] (fase 2) y del futuro [code]TicketAuthProvider[/code]
## (fases 5 y 6, con el billete de traspaso). La base no autentica a nadie: rechaza con
## [constant NetProtocol.Result.TICKET], así que un proveedor sin implementar nunca deja pasar.


## Devuelve [constant NetProtocol.Result.OK] si acepta el HELLO o
## [constant NetProtocol.Result.TICKET] si no lo acepta (billete ausente, no válido o caducado).
func authenticate(_hello: NetMessages.Hello) -> int:
	return NetProtocol.Result.TICKET
