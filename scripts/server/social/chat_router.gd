class_name ChatRouter
extends RefCounted
## Enrutado del chat en el servidor de zona (SOC-04, docs/social.md, secciones 1, 2, 5 y 12).
## [br][br]
## Recibe cada CHAT_SEND ya autenticado ([method handle_send]), aplica los ritmos por conexión, lo sanea
## ([ChatText]) y lo reparte con un CHAT_MESSAGE solo a quien debe verlo. [b]Nunca envía a un cliente un texto
## de otro reino[/b]: la lista de destinatarios se filtra por reino al construirla (el cliente no puede
## pedir lo que el servidor no manda), y la prueba de aceptación mira los bytes recibidos, no lo que se
## pinta.
## [br][br]
## [b]Canales[/b] de la fase 4:
## [br]- [b]Decir[/b]: los del mismo reino a [constant SAY_RANGE] m del emisor (él incluido).
## [br]- [b]Zona[/b]: todos los del mismo reino presentes en el proceso (la zona y su copia son el proceso).
## [br]- [b]Susurro[/b]: un personaje del mismo reino de este proceso, por su nombre (sin distinguir
## mayúsculas ni tildes). Si no está, o es del otro reino, la respuesta es la misma, «no está conectado», y
## no se revela que existe. Lo reciben el destinatario y el propio emisor (su copia).
## [br]- [b]Grupo[/b]: los miembros de su grupo, vengan de donde vengan; los da [member party_members].
## [br]- Banda, gremio, reino y GM tienen id pero aún no se reparten: «Ese canal aún no está disponible»
## (en GM, «Comando desconocido», para no revelar que existe).
## [br][br]
## [b]Responder (/r).[/b] Lo resuelve el cliente: recuerda con quién habló por última vez y manda un
## susurro a ese nombre. El servidor no guarda «el último interlocutor» porque no hace falta (un susurro
## a un nombre que ya no está conectado da la respuesta de siempre) y así el protocolo no necesita un
## canal más.
## [br][br]
## [b]Ritmos[/b] (por conexión, [RateLimiter] en ticks, docs/social.md sección 5). Cada CHAT_SEND gasta
## primero una ficha de su cubo, [b]antes de sanear[/b] o de contestar nada: el saneado no es gratis y un
## texto que queda vacío, o un canal sin servicio, también cuestan. Decir, zona, grupo y los canales sin
## servicio comparten 1 mensaje por segundo con ráfaga de 5; el susurro, 1 por segundo con ráfaga de 3 y
## como mucho 5 destinatarios nuevos por minuto (quien ya habló contigo en los últimos
## [constant KNOWN_RECIPIENT_TICKS] ticks no cuenta como nuevo, y tú tampoco para él). Un texto igual al
## último aceptado en [constant REPEAT_WINDOW_TICKS] ticks se descarta si va al mismo sitio: los canales
## públicos comparten la comprobación y en un susurro cuenta el destinatario («ok» a dos personas pasa).
## Lo descartado avisa al jugador por el canal del sistema («Hablas demasiado rápido.» o «Ya has enviado
## ese mensaje.», como mucho un aviso por segundo); los [constant ChatPeerState.FLOOD_FREE_DISCARDS]
## primeros descartes de cada 10 s no suman nada y, a partir de ahí, cada uno suma un aviso del peer (50 en
## 600 ticks expulsan): pulsar Intro de más no expulsa a nadie, la inundación sostenida sí.
## [br][br]
## [b]Moderación[/b] (docs/plataforma.md §9.2 a §9.5, P7b). El canal GM lleva desde el protocolo 7 los comandos que
## atiende el servidor ([code]/gm …[/code], [code]/ignorar[/code], [code]/designorar[/code],
## [code]/reportar[/code]): con [member command_sink] puesto, el texto saneado va allí (tras gastar su ficha y sin la
## comprobación de repetición). Quien está silenciado ([member ChatPeerState.muted_until_unix]) no habla por ningún
## canal y recibe «Estás silenciado N min más.». Un receptor que ignora la cuenta del emisor no recibe su mensaje en
## ningún canal (en un susurro el emisor recibe su copia igual: no sabe que lo ignoran). Con
## [member keep_received], cada receptor apunta lo que recibe en su anillo (la prueba de un reporte) y, con
## [member log_sink], cada mensaje repartido de un personaje va al lote de chat de la plataforma.
## [br][br]
## No toca la red ni el reloj: recibe de quien lo monta ([SocialService]) tres [Callable]s ([code]peers_source
## () -> Array[ServerPeer][/code], [code]send_sink(peer_id: int, bytes: PackedByteArray)[/code] y
## [code]strike_sink(peer: ServerPeer, reason: String)[/code]) y el tick en cada llamada; la hora Unix (silencios y
## lote de chat), de [member clock_unix].

## Resultado de [method handle_send] y [method route], para las pruebas y los informes.
enum Result {
	## Repartido a quien correspondía.
	DELIVERED,
	## El mensaje no se decodificó, o el peer aún no está en el mundo, o es un canal que un cliente no usa:
	## suma un aviso.
	MALFORMED,
	## Descartado por ritmo.
	RATE_LIMITED,
	## Descartado por ser igual al anterior.
	REPEATED,
	## Texto vacío tras sanear: se descarta (ya ha gastado su ficha) sin avisar a nadie.
	EMPTY,
	## Canal sin servicio en la fase 4.
	UNAVAILABLE,
	## Susurro a alguien que no está (o a un enemigo), a uno mismo, o grupo sin grupo: se contesta al emisor.
	NO_TARGET,
	## Un comando del canal GM entregado a [member command_sink].
	COMMAND,
	## El emisor está silenciado: no sale nada y se le dice cuánto le queda.
	MUTED,
}

## Distancia (m) a la que llega «decir».
const SAY_RANGE: float = 30.0
## Ticks en los que un texto idéntico al anterior (al mismo sitio) se descarta (10 s).
const REPEAT_WINDOW_TICKS: int = 600
## Ticks mínimos entre dos avisos de mensaje descartado al mismo jugador (1 s). Las invitaciones de
## grupo ([PartyManager]) usan el mismo intervalo para «Invitas demasiado rápido.».
const WARNING_INTERVAL_TICKS: int = 60
## Ticks que un interlocutor de susurro deja de contar como «nuevo» (5 min).
const KNOWN_RECIPIENT_TICKS: int = 18000
## Motivo con el que se suman los avisos por inundar el chat.
const STRIKE_REASON_FLOOD: String = "exceso de mensajes de chat"
const STRIKE_REASON_MALFORMED: String = "mensaje de chat mal formado"
const STRIKE_REASON_NOT_IN_WORLD: String = "chat antes de entrar en el mundo"

const TEXT_TOO_FAST: String = "Hablas demasiado rápido."
const TEXT_REPEATED: String = "Ya has enviado ese mensaje."
const TEXT_UNAVAILABLE: String = "Ese canal aún no está disponible."
const TEXT_UNKNOWN_COMMAND: String = "Comando desconocido. Escribe /ayuda."
const TEXT_NOT_CONNECTED: String = "«%s» no está conectado."
const TEXT_SELF_WHISPER: String = "No puedes susurrarte a ti mismo."
const TEXT_NO_PARTY: String = "No estás en un grupo."
const TEXT_MUTED: String = "Estás silenciado %d min más."
const TEXT_MUTED_NO_END: String = "Estás silenciado sin fecha de fin."

## Quién da los miembros del grupo de un peer: [code](peer: ServerPeer) -> Array[ServerPeer][/code]. Sin
## él (o vacío) nadie tiene grupo y el canal de grupo contesta «No estás en un grupo.».
var party_members: Callable = Callable()
## Quién atiende los comandos del canal GM: [code](peer: ServerPeer, line: String, now_tick: int) -> void[/code]
## ([ModerationService]). Sin él, el canal GM contesta «Comando desconocido. Escribe /ayuda.» como en la fase 4.
var command_sink: Callable = Callable()
## Con plataforma: recibe la entrada del lote de chat de cada mensaje repartido de un personaje,
## [code](entry: Dictionary) -> void[/code] con [code]{channel, sender_character_id, target_character_id, text,
## sent_at_unix}[/code] (docs/plataforma.md §9.2; la [code]key[/code] la pone [ZonePlatform]).
var log_sink: Callable = Callable()
## La hora Unix, [code]() -> int[/code] (con plataforma, [method ZonePlatform.now_unix]).
var clock_unix: Callable = Callable()
## Si cada receptor apunta lo que recibe en su anillo ([method ChatPeerState.remember_received]).
var keep_received: bool = false

var _peers_source: Callable
var _send_sink: Callable
var _strike_sink: Callable
var _routed: int = 0
var _delivered_copies: int = 0
var _ignored_copies: int = 0
var _logged: int = 0
var _results: Dictionary[int, int] = {}


func _init(peers_source: Callable, send_sink: Callable, strike_sink: Callable) -> void:
	_peers_source = peers_source
	_send_sink = send_sink
	_strike_sink = strike_sink


## Atiende un CHAT_SEND de [param peer] llegado en el tick [param now_tick]: lo decodifica y lo enruta.
## Un mensaje mal formado, o de quien aún no está en el mundo, suma un aviso. Devuelve el
## [enum Result].
func handle_send(peer: ServerPeer, bytes: PackedByteArray, now_tick: int) -> int:
	if peer.state != ServerPeer.State.IN_WORLD or peer.entity == null:
		_strike_sink.call(peer, STRIKE_REASON_NOT_IN_WORLD)
		return _count(Result.MALFORMED)
	var message: NetMessages.ChatSend = NetMessages.ChatSend.decode(bytes)
	if message == null:
		_strike_sink.call(peer, STRIKE_REASON_MALFORMED)
		return _count(Result.MALFORMED)
	return route(peer, message, now_tick)


## Enruta un mensaje ya decodificado de [param peer] (en el mundo). Ver la documentación de la clase.
func route(peer: ServerPeer, message: NetMessages.ChatSend, now_tick: int) -> int:
	var state: ChatPeerState = peer.chat
	# Ritmo antes que nada: ni el saneado ni las respuestas del sistema son gratis.
	var limiter: RateLimiter = state.limiter_whisper \
			if message.channel == ChatChannel.Id.WHISPER else state.limiter_public
	if not limiter.try_consume(now_tick):
		state.discarded_rate += 1
		_note_discard(peer, now_tick, TEXT_TOO_FAST)
		return _count(Result.RATE_LIMITED)
	if message.channel == ChatChannel.Id.GM and command_sink.is_valid():
		# Un comando para el servidor (docs/plataforma.md §9): ni repetición ni silencio, que no es chat.
		var line: String = ChatText.sanitize(message.text)
		if line.is_empty():
			state.discarded_empty += 1
			return _count(Result.EMPTY)
		command_sink.call(peer, line, now_tick)
		return _count(Result.COMMAND)
	if not ChatChannel.is_implemented(message.channel):
		state.rejected_channel += 1
		var text: String = TEXT_UNKNOWN_COMMAND if message.channel == ChatChannel.Id.GM \
				else TEXT_UNAVAILABLE
		send_system(peer, text, now_tick)
		return _count(Result.UNAVAILABLE)
	# Silenciado (docs/plataforma.md §9.5): no habla por ningún canal.
	var now_unix: int = _now_unix()
	if state.mute_remaining_s(now_unix) > 0:
		state.discarded_muted += 1
		send_system(peer, muted_text(state, now_unix), now_tick)
		return _count(Result.MUTED)
	var text_clean: String = ChatText.sanitize(message.text)
	if text_clean.is_empty():
		state.discarded_empty += 1
		return _count(Result.EMPTY)

	# Repetición: el mismo texto al mismo sitio (los canales públicos comparten clave).
	var repeat_key: String = _repeat_key(message)
	if text_clean == state.last_text and repeat_key == state.last_text_key \
			and now_tick - state.last_text_tick < REPEAT_WINDOW_TICKS:
		state.discarded_repeat += 1
		_note_discard(peer, now_tick, TEXT_REPEATED)
		return _count(Result.REPEATED)

	var result: int = Result.DELIVERED
	match message.channel:
		ChatChannel.Id.SAY:
			_deliver(peer, _say_recipients(peer), message.channel, null, text_clean, now_tick)
		ChatChannel.Id.ZONE:
			_deliver(peer, _zone_recipients(peer), message.channel, null, text_clean, now_tick)
		ChatChannel.Id.PARTY:
			result = _route_party(peer, text_clean, now_tick)
		ChatChannel.Id.WHISPER:
			result = _route_whisper(peer, message.recipient, text_clean, now_tick)
	if result == Result.DELIVERED:
		state.accepted += 1
		state.last_text = text_clean
		state.last_text_key = repeat_key
		state.last_text_tick = now_tick
	return _count(result)


## Manda a [param peer] un mensaje del canal del sistema (lo que antes habría sido un NOTICE de chat).
func send_system(peer: ServerPeer, text: String, now_tick: int) -> void:
	var message := NetMessages.ChatMessage.new()
	message.channel = ChatChannel.Id.SYSTEM
	message.tick = now_tick
	message.text = text
	_send_sink.call(peer.peer_id, message.encode())


## El aviso del silencio de [param state] a la hora Unix [param now_unix]: los minutos que quedan, redondeados hacia
## arriba, o «sin fecha de fin».
static func muted_text(state: ChatPeerState, now_unix: int) -> String:
	if state.muted_until_unix >= ChatPeerState.MUTE_NO_END_UNIX:
		return TEXT_MUTED_NO_END
	return TEXT_MUTED % ceili(float(state.mute_remaining_s(now_unix)) / 60.0)


## Estadísticas para el informe: mensajes procesados, copias repartidas, copias que no salieron porque el receptor
## ignora al emisor, entradas del lote de chat y cuántos acabaron en cada [enum Result].
func get_stats() -> Dictionary:
	var by_result: Dictionary = {}
	for result: int in _results:
		by_result[Result.keys()[result].to_lower()] = _results[result]
	return {"routed": _routed, "delivered_copies": _delivered_copies, "ignored_copies": _ignored_copies,
			"logged": _logged, "results": by_result}


# --- Destinatarios ----------------------------------------------------------------------------

# Los del mismo reino a SAY_RANGE m del emisor (él incluido).
func _say_recipients(sender: ServerPeer) -> Array[ServerPeer]:
	var origin: Vector3 = sender.entity.get_position()
	var result: Array[ServerPeer] = []
	for other: ServerPeer in _world_peers():
		if other.realm == sender.realm and other.entity.get_position().distance_to(origin) <= SAY_RANGE:
			result.append(other)
	return result


# Todos los del mismo reino presentes en el proceso (él incluido).
func _zone_recipients(sender: ServerPeer) -> Array[ServerPeer]:
	var result: Array[ServerPeer] = []
	for other: ServerPeer in _world_peers():
		if other.realm == sender.realm:
			result.append(other)
	return result


func _route_party(sender: ServerPeer, text: String, now_tick: int) -> int:
	var members: Array[ServerPeer] = []
	if party_members.is_valid():
		var found: Variant = party_members.call(sender)
		for member: ServerPeer in found:
			# Un grupo es de un solo reino; la comprobación es la última defensa del filtro por reino.
			if member.realm == sender.realm and member.state == ServerPeer.State.IN_WORLD:
				members.append(member)
	if members.is_empty():
		send_system(sender, TEXT_NO_PARTY, now_tick)
		return Result.NO_TARGET
	_deliver(sender, members, ChatChannel.Id.PARTY, null, text, now_tick)
	return Result.DELIVERED


func _route_whisper(sender: ServerPeer, recipient_name: String, text: String, now_tick: int) -> int:
	var state: ChatPeerState = sender.chat
	var target: ServerPeer = SocialPeers.find_by_name(_world_peers(), recipient_name, sender.realm)
	if target == null:
		# Igual para quien no existe y para un enemigo: nada que delate cuál de los dos es. Se repite lo
		# que escribió el jugador, no el nombre canónico del otro.
		state.whisper_misses += 1
		var shown: String = ChatText.clean(recipient_name).substr(0, NetProtocol.MAX_NAME_CHARS)
		send_system(sender, TEXT_NOT_CONNECTED % shown, now_tick)
		return Result.NO_TARGET
	if target == sender:
		send_system(sender, TEXT_SELF_WHISPER, now_tick)
		return Result.NO_TARGET
	# Destinatarios nuevos: un interlocutor reciente no gasta del cubo.
	var key: String = SocialPeers.name_key_of(target)
	if not state.knows_recipient(key, now_tick, KNOWN_RECIPIENT_TICKS):
		if not state.limiter_new_recipients.try_consume(now_tick):
			state.discarded_rate += 1
			_note_discard(sender, now_tick, TEXT_TOO_FAST)
			return Result.RATE_LIMITED
	# Los dos lados se podan antes de apuntar: el diccionario de quien solo recibe susurros también se
	# queda en los interlocutores de los últimos KNOWN_RECIPIENT_TICKS ticks.
	state.forget_old_recipients(now_tick, KNOWN_RECIPIENT_TICKS)
	state.remember_recipient(key, now_tick)
	target.chat.forget_old_recipients(now_tick, KNOWN_RECIPIENT_TICKS)
	target.chat.remember_recipient(SocialPeers.name_key_of(sender), now_tick)
	# Si el destinatario ignora al emisor, solo sale la copia del emisor: no sabe que lo ignoran (§9.3).
	var copies: Array[ServerPeer] = [target, sender]
	_deliver(sender, copies, ChatChannel.Id.WHISPER, target, text, now_tick)
	return Result.DELIVERED


# --- Envío ------------------------------------------------------------------------------------

# CHAT_MESSAGE de [param sender] con [param text] ya saneado, a cada uno de [param recipients] que no ignore su
# cuenta ([param target]: el destinatario de un susurro, null en los demás canales). Con [member keep_received], cada
# receptor lo apunta en su anillo y, con [member log_sink], el mensaje va al lote de chat.
func _deliver(sender: ServerPeer, recipients: Array[ServerPeer], channel: int, target: ServerPeer,
		text: String, now_tick: int) -> void:
	var message := NetMessages.ChatMessage.new()
	message.channel = channel
	message.sender_realm = sender.realm
	message.tick = now_tick
	message.sender = sender.display_name
	message.recipient = target.display_name if target != null else ""
	message.text = text
	var bytes: PackedByteArray = message.encode()
	var now_unix: int = _now_unix() if keep_received or log_sink.is_valid() else 0
	var line: ChatPeerState.Received = null
	var copies: int = 0
	for peer: ServerPeer in recipients:
		if SocialPeers.ignores(peer, sender):
			_ignored_copies += 1
			continue
		_send_sink.call(peer.peer_id, bytes)
		copies += 1
		if keep_received and peer != sender:
			if line == null:
				line = ChatPeerState.Received.new()
				line.sender_key = SocialPeers.name_key_of(sender)
				line.sender_name = sender.display_name
				line.channel = channel
				line.text = text
				line.sent_at_unix = now_unix
				line.tick = now_tick
			peer.chat.remember_received(line)
	sender.chat.delivered += copies
	_delivered_copies += copies
	if log_sink.is_valid() and sender.claimed != null:
		var target_id: Variant = null
		if target != null and target.claimed != null:
			target_id = str(target.claimed.character_id)
		_logged += 1
		log_sink.call({"channel": channel, "sender_character_id": str(sender.claimed.character_id),
				"target_character_id": target_id, "text": text, "sent_at_unix": now_unix})


# Un mensaje descartado: [param warning] al jugador (como mucho un aviso por segundo) y, pasados los
# descartes gratis de la ventana, un aviso del peer.
func _note_discard(peer: ServerPeer, now_tick: int, warning: String) -> void:
	var state: ChatPeerState = peer.chat
	state.discards += 1
	if state.last_warning_tick < 0 or now_tick - state.last_warning_tick >= WARNING_INTERVAL_TICKS:
		state.last_warning_tick = now_tick
		send_system(peer, warning, now_tick)
	if state.chat_flood.note(now_tick):
		_strike_sink.call(peer, STRIKE_REASON_FLOOD)


# Dónde va un mensaje, para la repetición: los canales públicos comparten clave; un susurro, la del
# destinatario tal como se busca ([method SocialPeers.find_by_name]).
static func _repeat_key(message: NetMessages.ChatSend) -> String:
	if message.channel != ChatChannel.Id.WHISPER:
		return ""
	return "w:" + NameRules.normalize_key(message.recipient)


func _now_unix() -> int:
	if clock_unix.is_valid():
		return int(clock_unix.call())
	return int(Time.get_unix_time_from_system())


func _world_peers() -> Array[ServerPeer]:
	var peers: Array[ServerPeer] = _peers_source.call()
	return SocialPeers.in_world(peers)


func _count(result: int) -> int:
	_routed += 1
	_results[result] = _results.get(result, 0) + 1
	return result
