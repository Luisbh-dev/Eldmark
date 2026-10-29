class_name ChatPeerState
extends RefCounted
## Estado social de una conexión (docs/social.md, secciones 5 y 12): los cubos de fichas de los ritmos de
## [ChatRouter] y [PartyManager], el último mensaje (para descartar repeticiones), los descartes recientes
## (para los avisos por inundar) y a quién ha susurrado hace poco.
## [br][br]
## Vive en el [ServerPeer], así que nace lleno con cada conexión y se va con ella: los ritmos son [b]por
## conexión[/b], no por jugador. Quien sale y vuelve a entrar recupera las ráfagas llenas (también los 5
## destinatarios nuevos de susurro), igual que los cubos del transporte y los avisos (docs/red.md, hallazgo
## S6). En la fase 4 no hay arreglo que valga: el cliente elige su nombre en cada conexión, así que guardar
## este estado por nombre no frena a nadie. Desde la fase 5 se guardará por personaje o cuenta (la del
## billete) unos minutos tras la baja (docs/social.md, 12.7). No lee ningún reloj: todo se mide en ticks del
## servidor.

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

## Contadores (informe): mensajes aceptados, repartidos (copias enviadas), descartados por ritmo, por
## repetición, por ser un texto vacío, rechazados por canal no disponible y por destinatario inexistente.
var accepted: int = 0
var delivered: int = 0
var discarded_rate: int = 0
var discarded_repeat: int = 0
var discarded_empty: int = 0
var rejected_channel: int = 0
var whisper_misses: int = 0


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
