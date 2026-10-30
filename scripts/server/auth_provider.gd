class_name AuthProvider
extends RefCounted
## Identidad y reino de un cliente que se conecta (docs/red.md, secciones 3 y 12; docs/plataforma.md §5.2 y §14.3).
## [br][br]
## [ServerAuth] ya ha comprobado la versión, la huella de la simulación, el cupo y el tope por IP (y, sin
## billetes, el reino y el nombre); el proveedor decide si acepta la identidad que declara el HELLO. Esta clase es
## la base de [DevAuthProvider] (sin plataforma) y de [TicketAuthProvider] (con el billete de la plataforma). La
## base no autentica a nadie: rechaza con [constant NetProtocol.Result.TICKET], así que un proveedor sin
## implementar nunca deja pasar.
## [br][br]
## Un proveedor puede no decidir en el acto: [method authenticate] devuelve [constant PENDING], el peer espera en
## [constant ServerPeer.State.VERIFYING] y el final llega por [method take_completed] en el paso «poll» del tick,
## tras repartir los [PlatformEvent] ([method on_platform_event]).

## [method authenticate] no decide aún: el final llega por [method take_completed].
const PENDING: int = -1


## [constant NetProtocol.Result.OK], [constant PENDING] o el motivo del REJECT (por defecto
## [constant NetProtocol.Result.TICKET]: billete ausente, no válido o caducado).
func authenticate(_peer_id: int, _hello: NetMessages.Hello) -> int:
	return NetProtocol.Result.TICKET


## Atiende [param event] si es suyo (kind [code]claim[/code]) y devuelve true; si no, false.
func on_platform_event(_event: PlatformEvent) -> bool:
	return false


## Los [constant PENDING] resueltos desde la última llamada, en orden de llegada.
func take_completed() -> Array[AuthOutcome]:
	return []


## El peer [param peer_id] se fue en [constant ServerPeer.State.VERIFYING] (o venció su plazo): si su reclamación
## llega después, se libera.
func cancel(_peer_id: int) -> void:
	pass


## true si la identidad sale del billete: [ServerAuth] no mira el reino ni el nombre del HELLO (los de la
## reclamación mandan) y no hay REJECT NAME (docs/plataforma.md §5.4).
func uses_tickets() -> bool:
	return false
