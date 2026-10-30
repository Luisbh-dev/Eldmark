class_name TicketAuthProvider
extends AuthProvider
## La entrada con el billete de la plataforma (docs/plataforma.md §5.2): [method authenticate] es síncrono y sin
## red; cualquier fallo es REJECT [constant NetProtocol.Result.TICKET] y nada llega a la plataforma.
## [br][br]
## [codeblock]
## 0. zona cercada (sin latido aceptado)                -> UNAVAILABLE
## 1. 52 B, versión 1, key_id conocido, firma correcta  -> TICKET si no (firma en tiempo constante)
## 2. world_id, zone_key y channel de esta zona          -> TICKET si no («billete de otra zona»)
## 3. issued_at ≤ ahora + 5 y ahora ≤ expires_at + 5     -> TICKET si no (ahora: el reloj de la plataforma)
## 4. character_id igual al del HELLO                     -> TICKET si no
## 5. ticket_id no visto en los últimos 30 s              -> TICKET si no («reutilizado»)
## [/codeblock]
## Si pasa, pide la reclamación ([method ZonePlatform.claim]) y devuelve [constant AuthProvider.PENDING]: la
## reclamación garantiza de verdad el un solo uso y toma el arrendamiento. Su respuesta llega como evento
## [code]claim[/code] ([method on_platform_event]) y se convierte en un [AuthOutcome]:
## [codeblock]
## 200                                         OK con el ClaimedCharacter (la zona mira reino, cupo y carga)
## 409 ticket_invalid                          TICKET
## 409 character_busy                          BUSY
## 403 account_blocked                         BANNED con el message del cuerpo
## 409 instance_lost/replaced/stopped          UNAVAILABLE (y el cierre de §6.1, por instance_closed)
## cualquier otra, sin conexión                UNAVAILABLE (un 4xx, con alerta en el registro)
## [/codeblock]
## Un 200 de un peer que ya no espera (se fue, o venció su plazo de 7 s) se libera en el acto.

## Margen del reloj al mirar la caducidad (s).
const CLOCK_SKEW_S: int = 5
## Cuánto se recuerda un ticket_id ya visto (s).
const REUSE_WINDOW_S: int = 30
## REJECT TICKET de un HELLO sin billete (§5.5).
const NO_TICKET_TEXT: String = "Entra desde el menú con tu cuenta"

## Motivo del último rechazo síncrono (para el registro y las pruebas): «firma», «otra zona», «caducado»,
## «personaje», «reutilizado», «cercada» o «sin billete».
var last_rejection: String = ""
## Registro de la zona (un [Callable] con un texto); sin él, print.
var log_sink: Callable = Callable()

var _platform: ZonePlatform
var _world_id: int
var _zone_key: int
var _channel: int
var _keys: Dictionary[int, PackedByteArray] = {}
## ticket_id -> hora (Unix) en que se vio.
var _seen: Dictionary[int, int] = {}
## peer_id -> character_id de los que esperan su reclamación.
var _pending: Dictionary[int, int] = {}
var _completed: Array[AuthOutcome] = []


## [param keys]: las claves del billete ([code]{key_id: clave}[/code], de [method ZonePlatform.read_secrets]).
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
			# El peer se fue (o venció su plazo) antes de la respuesta: el arrendamiento no se queda colgado.
			_platform.release(claimed.character_id, claimed.lease_id)
			return true
		_completed.append(AuthOutcome.new(peer_id, NetProtocol.Result.OK, "", claimed))
		return true
	if not waiting:
		return true
	_completed.append(outcome_of_failure(peer_id, event))
	return true


## El [AuthOutcome] de una reclamación que no fue un 200 (tabla de §5.2).
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


## Peers que esperan su reclamación (pruebas).
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
