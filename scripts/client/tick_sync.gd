class_name TickSync
extends RefCounted
## Antelación del cliente respecto al servidor (docs/red.md, sección 4.2).
##
## En cada tick de física el cliente pregunta a [method next_steps] cuántos pasos de predicción
## ([method ClientPrediction.step]) debe dar:
## [br]- 1: lo normal.
## [br]- 2: para adelantarse (paso doble).
## [br]- 0: para retrasarse (paso nulo, uno de cada dos ticks).
## [br]- N: resincronización dura hacia delante.
## [br][br]
## La realimentación sale del servidor: cada snapshot trae [code]input_margin[/code], la antelación
## mínima con la que llegaron las entradas desde el snapshot anterior (0 = justo a tiempo,
## negativo = tarde). Se guardan las últimas [constant WINDOW_SAMPLES] muestras y se usa su
## mínimo: si queda por debajo del margen objetivo ([method get_target_margin]) hay que
## adelantarse; si queda muy por encima, retrasarse poco a poco. Nunca se salta hacia atrás,
## porque regeneraría entradas ya enviadas y, como el servidor se queda con la primera copia,
## habría predicciones fallidas seguras.
## [br][br]
## Tras cada ajuste se descartan las muestras hasta que llega un snapshot cuyo
## [code]input_ack_tick[/code] demuestra que el servidor ya ha recibido entradas generadas después
## del ajuste: así se espera exactamente el retardo de la realimentación, sea cual sea el RTT, y no
## hay sobreimpulso.

## Muestras de margen que se guardan (~0,5 s a 30 snapshots por segundo).
const WINDOW_SAMPLES: int = 15
## Margen objetivo mínimo y máximo (ticks).
const MIN_TARGET: int = 1
const MAX_TARGET: int = 4
## Margen mínimo (ticks) a partir del cual se resincroniza de golpe hacia delante.
const RESYNC_BEHIND: int = -8
## Pasos máximos que se dan de golpe en una resincronización dura.
const MAX_RESYNC_STEPS: int = 30
## Ticks, tras el primero generado después de un ajuste, que debe haber recibido el servidor para
## que sus márgenes ya reflejen el ajuste.
const ACK_WAIT_TICKS: int = 2
## Cuánto debe superar el mínimo de la ventana al margen objetivo para empezar a retrasarse.
const SLOW_DOWN_THRESHOLD: int = 2

## Número de ajustes hechos desde [method start] (adelantos, retrasos y resincronizaciones).
var adjustments: int = 0

var _target: int = MIN_TARGET
var _window: Array[int] = []
## Pasos de más pendientes (positivo, adelantarse) o de menos (negativo, retrasarse).
var _debt: int = 0
var _slow_toggle: bool = false
var _ignore_until_ack: int = 0


## Empieza una sesión nueva y devuelve P0, el primer tick con entrada real:
## [code]spawn_tick + rtt_ticks + margen objetivo + 1[/code]. [param spawn_tick] es el tick del
## servidor en el que apareció el jugador y [param rtt_ticks] el RTT medido durante la conexión.
func start(spawn_tick: int, rtt_ticks: int) -> int:
	_window.clear()
	_debt = 0
	_slow_toggle = false
	_ignore_until_ack = 0
	adjustments = 0
	return spawn_tick + maxi(rtt_ticks, 0) + _target + 1


## Jitter de llegada de los snapshots (ticks; lo mide [InterpolationClock]). Fija el margen
## objetivo: [code]clamp(1 + ceil(2 · jitter), 1, 4)[/code].
func set_jitter(jitter_ticks: float) -> void:
	_target = clampi(1 + ceili(2.0 * maxf(jitter_ticks, 0.0)), MIN_TARGET, MAX_TARGET)


## Registra el margen de un snapshot nuevo. [param input_ack_tick] es el
## [code]input_ack_tick[/code] del snapshot; [param input_margin] su [code]input_margin[/code]
## ([constant NetProtocol.NO_MARGIN] si el servidor no tenía datos). Las muestras sin datos o
## demasiado antiguas (anteriores a un ajuste) se descartan.
func on_snapshot(input_ack_tick: int, input_margin: int) -> void:
	if input_margin == NetProtocol.NO_MARGIN or input_ack_tick < _ignore_until_ack:
		return
	_window.push_back(input_margin)
	if _window.size() > WINDOW_SAMPLES:
		_window.pop_front()


## Pasos de predicción que hay que dar en este tick de física. [param predicted_tick] es el último
## tick predicho (antes de dar los pasos de este tick). Nunca es negativo; como mucho es
## [constant MAX_RESYNC_STEPS].
func next_steps(predicted_tick: int) -> int:
	if _debt == 0 and not _window.is_empty():
		var low: int = _window_min()
		if low <= RESYNC_BEHIND:
			var jump: int = mini(_target - low, MAX_RESYNC_STEPS - 1)
			_after_adjust(predicted_tick + 1 + jump)
			return 1 + jump
		if low < _target:
			_debt = _target - low
		elif _window.size() == WINDOW_SAMPLES and low > _target + SLOW_DOWN_THRESHOLD:
			_debt = -(low - _target)
	if _debt > 0:
		_debt -= 1
		if _debt == 0:
			_after_adjust(predicted_tick + 2)
		return 2
	if _debt < 0:
		_slow_toggle = not _slow_toggle
		if not _slow_toggle:
			return 1
		_debt += 1
		if _debt == 0:
			_after_adjust(predicted_tick + 1)
		return 0
	return 1


## Margen objetivo actual (ticks), entre [constant MIN_TARGET] y [constant MAX_TARGET].
func get_target_margin() -> int:
	return _target


## Mínimo de la ventana de márgenes, o [constant NetProtocol.NO_MARGIN] si está vacía.
func get_window_min() -> int:
	if _window.is_empty():
		return NetProtocol.NO_MARGIN
	return _window_min()


func _window_min() -> int:
	var low: int = _window[0]
	for sample: int in _window:
		low = mini(low, sample)
	return low


func _after_adjust(first_new_tick: int) -> void:
	_window.clear()
	_ignore_until_ack = first_new_tick + ACK_WAIT_TICKS
	adjustments += 1
