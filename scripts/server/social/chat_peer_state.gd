class_name ChatPeerState
extends RefCounted
## Estado de chat de una conexión (docs/social.md, secciones 5 y 12): los cubos de fichas de los ritmos de
## [ChatRouter], el último mensaje (para descartar repeticiones), cuántos se han descartado y a quién ha
## susurrado hace poco.
## [br][br]
## Vive en el [ServerPeer], así que nace lleno con cada conexión y se va con ella. No lee ningún reloj:
## todo se mide en ticks del servidor.

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

var limiter_public: RateLimiter = RateLimiter.new(PUBLIC_RATE_PER_TICK, PUBLIC_BURST)
var limiter_whisper: RateLimiter = RateLimiter.new(WHISPER_RATE_PER_TICK, WHISPER_BURST)
var limiter_new_recipients: RateLimiter = RateLimiter.new(NEW_RECIPIENT_RATE_PER_TICK,
		NEW_RECIPIENT_BURST)
## Último texto aceptado y tick en el que se aceptó (para el descarte de repeticiones).
var last_text: String = ""
var last_text_tick: int = -1
## Mensajes descartados por ritmo o por repetición en total (cada quinto suma un aviso del peer).
var discards: int = 0
## Tick del último aviso «Hablas demasiado rápido» que se le mandó (para no mandar uno por mensaje).
var last_warning_tick: int = -1
## Clave de comparación de su nombre ([method NameRules.normalize_key]), calculada la primera vez.
var name_key: String = ""
## Clave del nombre -> último tick en que susurró a ese personaje o él a este. Quien está aquí no cuenta
## como destinatario nuevo.
var known_recipients: Dictionary[String, int] = {}
## Último con quien se habló por susurro (nombre canónico), para el servidor y los informes.
var last_whisper_partner: String = ""

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
