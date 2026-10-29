class_name ServerPeer
extends RefCounted
## Estado que el servidor guarda de cada conexión (docs/red.md, secciones 3, 8, 11 y 12).
## [br][br]
## No toca la red: [code]ZoneServer[/code] lo rellena y lo consulta. Aquí viven los limitadores
## de ritmo, el contador de avisos (con la expulsión a los 50 en 600 ticks), el conjunto de
## entidades relevantes del peer y el acumulador de prioridad del [SnapshotBuilder].

## Fase de la sesión: autenticándose, cargando la zona (hasta CLIENT_READY), dentro del mundo
## o saliendo.
enum State { AUTHENTICATING, LOADING, IN_WORLD, LEAVING }

## Mensajes no fiables por tick que admite el limitador (120 por segundo) y ráfaga máxima.
const UNRELIABLE_RATE_PER_TICK: float = 2.0
const UNRELIABLE_BURST: float = 30.0
## Mensajes fiables por tick (10 por segundo) y ráfaga máxima.
const RELIABLE_RATE_PER_TICK: float = 10.0 / 60.0
const RELIABLE_BURST: float = 20.0
## Bytes por tick (16 KB/s) y ráfaga máxima (4 KB).
const BYTES_RATE_PER_TICK: float = 16.0 * 1024.0 / 60.0
const BYTES_BURST: float = 4.0 * 1024.0
## Avisos que provocan la expulsión y ventana de ticks en la que se cuentan.
const STRIKE_LIMIT: int = 50
const STRIKE_WINDOW_TICKS: int = 600

var peer_id: int
var state: State = State.AUTHENTICATING
var realm: int
var display_name: String
var remote_address: String
## Entidad del jugador (null hasta que entra en el mundo).
var entity: NetEntity
## Cola de entradas del jugador (null hasta que entra en el mundo).
var input_queue: InputQueue
## Entidades que este peer tiene por relevantes: net_id -> true. Lo mantiene el servidor con
## la [InterestPolicy] y lo lee el [SnapshotBuilder].
var relevant: Dictionary[int, bool] = {}
## Acumulador de prioridad por entidad relevante (net_id -> prioridad). Lo mantiene el
## [SnapshotBuilder]: sube en cada snapshot y vuelve a 0 al enviar la entidad.
var priority: Dictionary[int, float] = {}
## [code]server_tick[/code] del snapshot más nuevo que el cliente ha confirmado (0 = ninguno).
var ack_snapshot_tick: int = 0
## Retardo de interpolación declarado por el cliente (en ticks por 8).
var interp_delay_q: int = 0
## Mínimo de (s - ack_snapshot_tick) en los últimos 120 ticks.
var rtt_ticks: int = 0
## Tick en el que conectó y empezó a autenticarse (para el plazo del HELLO).
var connected_tick: int = 0
## Tick en el que empezó la carga de la zona (para el límite de CLIENT_READY).
var loading_since_tick: int = 0
var limiter_unreliable: RateLimiter
var limiter_reliable: RateLimiter
var limiter_bytes: RateLimiter
## Avisos sumados en total y motivo del último.
var strikes_total: int = 0
var last_strike_reason: String = ""
## Puntuación de sospecha del combate (docs/combate.md, 4.5): suma 1 por cada golpe cuyo rebobinado
## supera el tope y no se prueba. En la fase 3 solo se registra (informe y [code]--combat-log[/code]).
var suspicion_score: int = 0
## Golpes rechazados por rebobinado excesivo.
var rewind_rejects: int = 0
## Ataques que ha lanzado y de ellos cuántos han acertado (el ratio de acierto anómalo es una de las
## señales de sospecha futuras).
var swings: int = 0
var swings_landed: int = 0

# Anillo con los ticks de los últimos STRIKE_LIMIT avisos. El más antiguo de ellos está en
# _strike_head, que es también el hueco que se sobrescribe con el siguiente. De 64 bits: los ticks
# del servidor son u32 y pasan de 2^31 a los 414 días de proceso.
var _strike_ticks: PackedInt64Array = PackedInt64Array()
var _strike_head: int = 0


## Crea el peer con sus limitadores de ritmo de la sección 12.
func _init(id: int = 0) -> void:
	peer_id = id
	limiter_unreliable = RateLimiter.new(UNRELIABLE_RATE_PER_TICK, UNRELIABLE_BURST)
	limiter_reliable = RateLimiter.new(RELIABLE_RATE_PER_TICK, RELIABLE_BURST)
	limiter_bytes = RateLimiter.new(BYTES_RATE_PER_TICK, BYTES_BURST)
	_strike_ticks.resize(STRIKE_LIMIT)
	_strike_ticks.fill(-STRIKE_WINDOW_TICKS - 1)


## Da a los tres limitadores el crédito de [param missed_ticks] ticks que el servidor no ha
## simulado (un parón del proceso) en el tick [param now_tick]: lo que el cliente siguió enviando
## durante el parón llega junto y no debe contar como exceso de ritmo. El crédito dura hasta la
## siguiente recarga (ver [method RateLimiter.grant]).
func grant_stall_credit(now_tick: int, missed_ticks: int) -> void:
	if missed_ticks <= 0:
		return
	var ticks: float = float(missed_ticks)
	limiter_unreliable.grant(now_tick, UNRELIABLE_RATE_PER_TICK * ticks)
	limiter_reliable.grant(now_tick, RELIABLE_RATE_PER_TICK * ticks)
	limiter_bytes.grant(now_tick, BYTES_RATE_PER_TICK * ticks)


## Suma un aviso en el tick [param now_tick] por [param reason] (paquete malformado, tipo
## inesperado para el estado de la sesión o exceso de ritmo). Devuelve true si hay que expulsar
## al peer: [constant STRIKE_LIMIT] avisos dentro de los últimos [constant STRIKE_WINDOW_TICKS]
## ticks (un aviso del tick t cuenta hasta el tick t + 599).
func add_strike(now_tick: int, reason: String) -> bool:
	strikes_total += 1
	last_strike_reason = reason
	_strike_ticks[_strike_head] = now_tick
	_strike_head = (_strike_head + 1) % STRIKE_LIMIT
	# El hueco que toca ahora es el del aviso más antiguo de los últimos STRIKE_LIMIT.
	var oldest: int = _strike_ticks[_strike_head]
	return strikes_total >= STRIKE_LIMIT and now_tick - oldest < STRIKE_WINDOW_TICKS
