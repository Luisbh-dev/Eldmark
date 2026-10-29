class_name InterpolationClock
extends RefCounted
## Reloj con el que el cliente dibuja a los jugadores remotos (docs/red.md, sección 4.3).
##
## Es independiente de [TickSync]: uno fija cuándo se simula y el otro qué instante se dibuja, así
## que no se pelean. Todo se mide en ticks enteros de física.
## [br][br]
## [b]Medida local.[/b] Con cada snapshot se calcula [code]offset = server_tick - local_tick[/code].
## [code]max_offset[/code] es el máximo de los últimos [constant WINDOW_TICKS] ticks locales (la
## muestra que menos se ha retrasado: un estimador robusto de la latencia mínima), y el jitter es
## la media exponencial (α = 0,1) de [code]max_offset - offset[/code].
## [br][br]
## [b]Escalón hacia abajo.[/b] Ese estimador solo vale si el reloj del servidor no retrocede respecto
## al del cliente. Si el servidor pierde ticks (un parón) o la latencia sube de forma sostenida, los
## offsets bajan de golpe: el máximo de 2 s recordaría los viejos y el tick de dibujo iría por delante
## de los datos. Cuando todo lo de los últimos [constant RECENT_TICKS] ticks queda más de
## [constant STEP_DOWN_TICKS] ticks por debajo de ese máximo, se olvida lo anterior.
## [br][br]
## [b]Retardo.[/b] [code]clamp(2 · SNAPSHOT_INTERVAL_TICKS + 2 · jitter, 4, 12)[/code] ticks, es
## decir, de 67 a 200 ms. [method advance] lleva el tick de dibujo hacia
## [code]local_tick + max_offset - retardo[/code] a ritmo de 1 tick por tick de física, con una
## corrección de como mucho 0,05 ticks por tick (o con un salto, si el error pasa de 10 ticks).
## [br][br]
## [b]Sin sesgo.[/b] El pseudocódigo de la sección 4.3 comparaba el objetivo de este tick con el
## tick de dibujo del anterior (antes de sumarle 1), y la corrección convergía a un tick de dibujo 1
## tick por delante del objetivo: el retardo efectivo era el retardo menos 1 tick, y con el mínimo
## de 4 ticks se extrapolaba más a menudo. Aquí se avanza primero 1 tick y se corrige después, así
## que el tick de dibujo converge justo al objetivo (decisión tomada de noche, ver
## docs/informe_noche.md).
## [br][br]
## Los remotos se dibujan en [code]_process[/code] en el instante
## [code]render_tick + Engine.get_physics_interpolation_fraction()[/code].

## Ventana (ticks locales) del máximo de offsets: 2 s a 60 ticks por segundo.
const WINDOW_TICKS: int = 120
## Peso de cada muestra en la media exponencial del jitter.
const JITTER_ALPHA: float = 0.1
## Por debajo de este jitter (ticks) se considera 0. Sin esto, la media exponencial nunca llega
## a 0 tras un bache y el margen objetivo de [TickSync] ([code]ceil(2 · jitter)[/code]) se
## quedaría para siempre un tick por encima.
const JITTER_EPSILON: float = 0.001
## Retardo mínimo y máximo (ticks).
const MIN_DELAY_TICKS: float = 4.0
const MAX_DELAY_TICKS: float = 12.0
## Escalón hacia abajo (hallazgo N3). Si el servidor pierde ticks, o la latencia sube de forma
## sostenida, los offsets bajan de golpe y se quedan abajo; el máximo de 120 ticks recordaría los
## viejos durante 2 s y el tick de dibujo iría por delante de los datos que existen (se
## extrapolaría 6 ticks y el remoto se quedaría quieto). Por eso, si el máximo de la ventana
## completa supera en más de [constant STEP_DOWN_TICKS] ticks al de los últimos
## [constant RECENT_TICKS] ticks locales, se descartan las muestras anteriores a esos últimos.
const RECENT_TICKS: int = 30
const STEP_DOWN_TICKS: int = 4
## Si el tick de dibujo se aleja más de esto (ticks) del objetivo, salta a él.
const SNAP_TICKS: float = 10.0
## Fracción del error que se corrige en cada tick, y límite de esa corrección (ticks por tick).
const CORRECTION_GAIN: float = 0.1
const MAX_CORRECTION_PER_TICK: float = 0.05

# Muestras (tick local, offset) con offsets estrictamente decrecientes: la cola monótona cuyo
# primer elemento es el máximo de la ventana. Dos arrays de 64 bits en paralelo: los ticks del
# servidor son u32 y el offset pasa de 2^31 a los 414 días de proceso (un Vector2i no cabe).
var _sample_ticks: PackedInt64Array = PackedInt64Array()
var _sample_offsets: PackedInt64Array = PackedInt64Array()
var _max_offset: int = 0
var _jitter: float = 0.0
var _delay: float = MIN_DELAY_TICKS
var _render_tick: float = 0.0
var _started: bool = false


## Registra un snapshot: [param server_tick] es su tick y [param local_tick] el tick de física del
## cliente en el que se leyó el paquete. Se llama también con los snapshots desordenados.
func on_snapshot(server_tick: int, local_tick: int) -> void:
	var offset: int = server_tick - local_tick
	while not _sample_ticks.is_empty() and _sample_offsets[_sample_offsets.size() - 1] <= offset:
		_sample_ticks.remove_at(_sample_ticks.size() - 1)
		_sample_offsets.remove_at(_sample_offsets.size() - 1)
	_sample_ticks.append(local_tick)
	_sample_offsets.append(offset)
	while _sample_ticks[0] <= local_tick - WINDOW_TICKS:
		_sample_ticks.remove_at(0)
		_sample_offsets.remove_at(0)
	_drop_samples_before_a_step_down(local_tick)
	_max_offset = _sample_offsets[0]

	_jitter += JITTER_ALPHA * (float(_max_offset - offset) - _jitter)
	if _jitter < JITTER_EPSILON:
		_jitter = 0.0
	_delay = clampf(2.0 * NetProtocol.SNAPSHOT_INTERVAL_TICKS + 2.0 * _jitter,
			MIN_DELAY_TICKS, MAX_DELAY_TICKS)


# Si todo lo de los últimos RECENT_TICKS ticks está más de STEP_DOWN_TICKS por debajo del máximo de
# la ventana, es un escalón sostenido y no un bache: se olvida lo anterior. La cola es monótona, así
# que la primera muestra reciente es el máximo de las recientes.
func _drop_samples_before_a_step_down(local_tick: int) -> void:
	var recent: int = 0
	while _sample_ticks[recent] <= local_tick - RECENT_TICKS:
		recent += 1
	if recent > 0 and _sample_offsets[0] - _sample_offsets[recent] > STEP_DOWN_TICKS:
		_sample_ticks = _sample_ticks.slice(recent)
		_sample_offsets = _sample_offsets.slice(recent)


## Avanza el reloj un tick de física ([param local_tick] es el tick local actual) y devuelve el
## tick de dibujo. Hasta que llega el primer snapshot no hay con qué medir, así que no arranca y
## devuelve 0.
func advance(local_tick: int) -> float:
	if _sample_ticks.is_empty():
		return _render_tick
	var target: float = float(local_tick + _max_offset) - _delay
	if not _started or absf(target - _render_tick) > SNAP_TICKS:
		_render_tick = target
		_started = true
	else:
		var advanced: float = _render_tick + 1.0
		_render_tick = advanced + clampf((target - advanced) * CORRECTION_GAIN,
				-MAX_CORRECTION_PER_TICK, MAX_CORRECTION_PER_TICK)
	return _render_tick


## Tick de dibujo (sin la fracción de interpolación de física) del último [method advance].
func get_render_tick() -> float:
	return _render_tick


## Retardo actual de dibujo (ticks) respecto al servidor.
func get_delay_ticks() -> float:
	return _delay


## Jitter de llegada de los snapshots (ticks).
func get_jitter_ticks() -> float:
	return _jitter
