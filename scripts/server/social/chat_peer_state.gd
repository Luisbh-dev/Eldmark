class_name ChatPeerState
extends RefCounted
## Estado social de una conexión (docs/social.md, secciones 5 y 12): los cubos de fichas de los ritmos de
## [ChatRouter] y [PartyManager], el último mensaje (para descartar repeticiones), los descartes recientes
## (para los avisos por inundar) y a quién ha susurrado hace poco.
## [br][br]
## Vive en el [ServerPeer] y nace lleno con cada conexión. Sin plataforma, los ritmos son [b]por conexión[/b]:
## quien sale y vuelve a entrar recupera las ráfagas llenas (también los 5 destinatarios nuevos de susurro), igual
## que los cubos del transporte y los avisos (docs/red.md, hallazgo S6); el cliente elige su nombre en cada
## conexión, así que guardarlo por nombre no frenaría a nadie. [b]Con plataforma[/b] (docs/plataforma.md §9.2, P7b)
## es [b]por personaje[/b]: [SocialService] lo conserva [constant ChatRouter.KNOWN_RECIPIENT_TICKS] ticks tras la
## baja y se lo devuelve si vuelve a entrar en esta instancia, así que salir y volver no rellena las ráfagas.
## [br][br]
## Con plataforma lleva también lo de la moderación de esa cuenta (§9.2 a §9.5): su cuenta, las que ignora (de la
## reclamación, más las que ignora en esta sesión), hasta cuándo está silenciada (reclamación, latido o una sanción
## de esta zona), el anillo de los últimos mensajes que ha recibido (la prueba de un reporte) y sus reportes
## recientes. No lee ningún reloj: los ritmos se miden en ticks del servidor y el silencio con la hora Unix que le
## pasa quien lo mira.

## Mensajes por tick de «hablar» (decir, zona, grupo...): 1 por segundo.
const PUBLIC_RATE_PER_TICK: float = 1.0 / 60.0
## Mensajes seguidos que admite el cubo de «hablar».
const PUBLIC_BURST: float = 5.0
## Mensajes por tick de susurro: 1 por segundo.
const WHISPER_RATE_PER_TICK: float = 1.0 / 60.0
const WHISPER_BURST: float = 3.0
## Destinatarios nuevos de susurro por tick: 5 por minuto.
const NEW_RECIPIENT_RATE_PER_TICK: float = 5.0 / 3600.0
const NEW_RECIPIENT_BURST: float = 5.0
## Invitaciones de grupo por tick (1 cada 2 s) y ráfaga (docs/social.md, sección 5).
const INVITE_RATE_PER_TICK: float = 1.0 / 120.0
const INVITE_BURST: float = 3.0
## Ventana (ticks) en la que se cuentan los descartes por ritmo, la misma que la de los avisos del peer
## ([constant ServerPeer.STRIKE_WINDOW_TICKS], 10 s).
const FLOOD_WINDOW_TICKS: int = 600
## Descartes gratis dentro de la ventana: pulsar Intro de más no suma avisos; a partir del siguiente, cada
## descarte suma uno.
const FLOOD_FREE_DISCARDS: int = 10


## Descartes por ritmo de un tipo de mensaje (el chat o las invitaciones): los
## [constant FLOOD_FREE_DISCARDS] primeros de cada [constant FLOOD_WINDOW_TICKS] ticks son gratis y, a partir
## de ahí, cada uno suma un aviso del peer. Así la inundación sostenida llega a los 50 avisos que expulsan
## aunque el transporte deje pasar 10 fiables por segundo sin avisos: medido con el chat, a partir de 6
## mensajes por segundo (en unos 13 s; a 10 por segundo, en 7 s). Por debajo no expulsa, pero el cubo ya
## deja a los demás en 1 mensaje por segundo.
class FloodWindow:
	extends RefCounted

	# Anillo con los ticks de los últimos FLOOD_FREE_DISCARDS descartes; el más antiguo está en _head.
	var _ticks: PackedInt64Array = PackedInt64Array()
	var _head: int = 0


	func _init() -> void:
		_ticks.resize(ChatPeerState.FLOOD_FREE_DISCARDS)
		_ticks.fill(-ChatPeerState.FLOOD_WINDOW_TICKS - 1)


	## Apunta un descarte en el tick [param now_tick]. Devuelve true si suma un aviso: ya había
	## [constant ChatPeerState.FLOOD_FREE_DISCARDS] descartes en los últimos
	## [constant ChatPeerState.FLOOD_WINDOW_TICKS] ticks.
	func note(now_tick: int) -> bool:
		var oldest: int = _ticks[_head]
		_ticks[_head] = now_tick
		_head = (_head + 1) % _ticks.size()
		return now_tick - oldest < ChatPeerState.FLOOD_WINDOW_TICKS


## Mensajes recibidos que guarda el anillo de cada receptor para la prueba de un reporte (docs/plataforma.md §9.4).
const RECEIVED_RING_SIZE: int = 100
## Silencio sin fin (la hora Unix que da la plataforma: 9999-12-31).
const MUTE_NO_END_UNIX: int = 253402300799


## Un mensaje que recibió este jugador, para la prueba de un reporte. Uno por mensaje repartido: lo comparten los
## anillos de todos los que lo recibieron.
class Received:
	extends RefCounted

	## Clave de comparación del nombre del emisor ([method NameRules.normalize_key]).
	var sender_key: String = ""
	var sender_name: String = ""
	## [enum ChatChannel.Id].
	var channel: int = 0
	var text: String = ""
	var sent_at_unix: int = 0
	var tick: int = 0


var limiter_public: RateLimiter = RateLimiter.new(PUBLIC_RATE_PER_TICK, PUBLIC_BURST)
var limiter_whisper: RateLimiter = RateLimiter.new(WHISPER_RATE_PER_TICK, WHISPER_BURST)
var limiter_new_recipients: RateLimiter = RateLimiter.new(NEW_RECIPIENT_RATE_PER_TICK,
		NEW_RECIPIENT_BURST)
## Cubo de las invitaciones de grupo que envía ([PartyManager]), las que se le han descartado por ritmo, sus
## descartes recientes y el tick del último aviso «Invitas demasiado rápido».
var limiter_invites: RateLimiter = RateLimiter.new(INVITE_RATE_PER_TICK, INVITE_BURST)
var invite_discards: int = 0
var invite_flood: FloodWindow = FloodWindow.new()
var last_invite_warning_tick: int = -1
## Último texto aceptado, a qué se mandó ([code]""[/code] en los canales públicos, que comparten la
## comprobación; [code]"w:"[/code] y la clave del nombre en un susurro) y tick en el que se aceptó (para el
## descarte de repeticiones).
var last_text: String = ""
var last_text_key: String = ""
var last_text_tick: int = -1
## Mensajes de chat descartados por ritmo o por repetición en total, y los recientes (avisos por inundar).
var discards: int = 0
var chat_flood: FloodWindow = FloodWindow.new()
## Tick del último aviso de chat descartado que se le mandó (para no mandar uno por mensaje).
var last_warning_tick: int = -1
## Clave de comparación de su nombre ([method NameRules.normalize_key]), calculada la primera vez.
var name_key: String = ""
## Clave del nombre -> último tick en que susurró a ese personaje o él a este. Quien está aquí no cuenta
## como destinatario nuevo. Se poda cada vez que este jugador susurra o le susurran, así que solo guarda a
## los interlocutores de los últimos [constant ChatRouter.KNOWN_RECIPIENT_TICKS] ticks.
var known_recipients: Dictionary[String, int] = {}

## Con plataforma: la cuenta del personaje (0 sin plataforma) y las cuentas que ignora (cuenta -> true): sus
## mensajes, susurros e invitaciones no le llegan (docs/plataforma.md §9.3).
var account_id: int = 0
var ignored_accounts: Dictionary[int, bool] = {}
## Las que ha ignorado en esta sesión, por la clave del nombre que escribió (para [code]/designorar[/code], que la
## plataforma contesta sin la cuenta).
var ignored_by_name: Dictionary[String, int] = {}
## Hora Unix hasta la que está silenciado (0 = no lo está; [constant MUTE_NO_END_UNIX] = sin fin).
var muted_until_unix: int = 0
## Instante ([code]Time.get_ticks_msec()[/code]) en que una sanción de esta zona cambió el silencio: un latido que
## salió antes no lo deshace (docs/plataforma.md §9.5).
var mute_changed_msec: int = -1
## Anillo de los últimos [constant RECEIVED_RING_SIZE] mensajes recibidos; el más antiguo está en
## [member received_head] cuando el anillo está lleno.
var received: Array[Received] = []
var received_head: int = 0
## Reportes recientes: clave del nombre -> tick del último a ese personaje, y los ticks de los de la última hora.
var reported_at: Dictionary[String, int] = {}
var report_ticks: PackedInt64Array = PackedInt64Array()

## Contadores (informe): mensajes aceptados, repartidos (copias enviadas), descartados por ritmo, por
## repetición, por ser un texto vacío, rechazados por canal no disponible y por destinatario inexistente, y los
## que no salieron por estar silenciado.
var accepted: int = 0
var delivered: int = 0
var discarded_rate: int = 0
var discarded_repeat: int = 0
var discarded_empty: int = 0
var rejected_channel: int = 0
var whisper_misses: int = 0
## Mensajes que no salieron porque estaba silenciado.
var discarded_muted: int = 0


## Recuerda a [param key] como interlocutor de un susurro en el tick [param now_tick].
func remember_recipient(key: String, now_tick: int) -> void:
	known_recipients[key] = now_tick


## true si [param key] susurró con este jugador, o al revés, en los últimos [param window_ticks] ticks
## hasta [param now_tick].
func knows_recipient(key: String, now_tick: int, window_ticks: int) -> bool:
	return known_recipients.has(key) and now_tick - known_recipients[key] < window_ticks


## Olvida a los interlocutores que ya no cuentan (más antiguos que [param window_ticks]), para que el
## diccionario no crezca sin límite.
func forget_old_recipients(now_tick: int, window_ticks: int) -> void:
	for key: String in known_recipients.keys():
		if now_tick - known_recipients[key] >= window_ticks:
			known_recipients.erase(key)


## true si ignora la cuenta [param other_account] (0 nunca: sin plataforma no hay cuentas).
func ignores_account(other_account: int) -> bool:
	return other_account > 0 and ignored_accounts.has(other_account)


## Segundos de silencio que le quedan a la hora Unix [param now_unix] (0 si no está silenciado).
func mute_remaining_s(now_unix: int) -> int:
	return maxi(muted_until_unix - now_unix, 0) if muted_until_unix > 0 else 0


## Apunta [param line] en el anillo de lo recibido.
func remember_received(line: Received) -> void:
	if received.size() < RECEIVED_RING_SIZE:
		received.append(line)
		return
	received[received_head] = line
	received_head = (received_head + 1) % RECEIVED_RING_SIZE


## Los mensajes de quien tiene la clave de nombre [param sender_key] recibidos desde el tick [param since_tick],
## del más antiguo al más reciente, los [param limit] últimos.
func received_from(sender_key: String, since_tick: int, limit: int) -> Array[Received]:
	var found: Array[Received] = []
	var count: int = received.size()
	for offset: int in count:
		var line: Received = received[(received_head + offset) % count] if count == RECEIVED_RING_SIZE \
				else received[offset]
		if line.sender_key == sender_key and line.tick >= since_tick:
			found.append(line)
	while found.size() > limit:
		found.pop_front()
	return found
