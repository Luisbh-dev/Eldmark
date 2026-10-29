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
## [b]Retardo.[/b] [code]clamp(2 · SNAPSHOT_INTERVAL_TICKS + 2 · jitter, 4, 12)[/code] ticks, es
## decir, de 67 a 200 ms. [method advance] lleva el tick de dibujo hacia
## [code]local_tick + max_offset - retardo[/code] a ritmo de 1 tick por tick de física, con una
## corrección de como mucho 0,05 ticks por tick (o con un salto, si el error pasa de 10 ticks).
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
## Si el tick de dibujo se aleja más de esto (ticks) del objetivo, salta a él.
const SNAP_TICKS: float = 10.0
## Fracción del error que se corrige en cada tick, y límite de esa corrección (ticks por tick).
const CORRECTION_GAIN: float = 0.1
const MAX_CORRECTION_PER_TICK: float = 0.05

## Muestras (tick local, offset) con offsets estrictamente decrecientes: la cola monótona cuyo
## primer elemento es el máximo de la ventana.
var _samples: Array[Vector2i] = []
var _max_offset: int = 0
var _jitter: float = 0.0
var _delay: float = MIN_DELAY_TICKS
var _render_tick: float = 0.0
var _started: bool = false


## Registra un snapshot: [param server_tick] es su tick y [param local_tick] el tick de física del
## cliente en el que se leyó el paquete. Se llama también con los snapshots desordenados.
func on_snapshot(server_tick: int, local_tick: int) -> void:
	var offset: int = server_tick - local_tick
	while not _samples.is_empty() and _samples[_samples.size() - 1].y <= offset:
		_samples.pop_back()
	_samples.append(Vector2i(local_tick, offset))
	while _samples[0].x <= local_tick - WINDOW_TICKS:
		_samples.pop_front()
	_max_offset = _samples[0].y

	_jitter += JITTER_ALPHA * (float(_max_offset - offset) - _jitter)
	if _jitter < JITTER_EPSILON:
		_jitter = 0.0
	_delay = clampf(2.0 * NetProtocol.SNAPSHOT_INTERVAL_TICKS + 2.0 * _jitter,
			MIN_DELAY_TICKS, MAX_DELAY_TICKS)


## Avanza el reloj un tick de física ([param local_tick] es el tick local actual) y devuelve el
## tick de dibujo. Hasta que llega el primer snapshot no hay con qué medir, así que no arranca y
## devuelve 0.
func advance(local_tick: int) -> float:
	if _samples.is_empty():
		return _render_tick
	var target: float = float(local_tick + _max_offset) - _delay
	if not _started or absf(target - _render_tick) > SNAP_TICKS:
		_render_tick = target
		_started = true
	else:
		_render_tick += 1.0 + clampf((target - _render_tick) * CORRECTION_GAIN,
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
