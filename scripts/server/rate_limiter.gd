class_name RateLimiter
extends RefCounted
## Cubo de fichas medido en ticks (docs/red.md, sección 12): el servidor limita con él lo que
## puede enviar cada peer.
## [br][br]
## El cubo empieza lleno ([code]burst[/code] fichas) y recupera [code]rate_per_tick[/code] fichas
## por cada tick que pasa, sin superar [code]burst[/code]. No lee ningún reloj: quien llama le da
## el tick actual, así que es reproducible en las pruebas.

var _rate_per_tick: float
var _burst: float
var _tokens: float
## Tick de la última recarga, o -1 antes de la primera consulta.
var _last_tick: int = -1


## [param rate_per_tick] fichas recuperadas por tick; [param burst] capacidad del cubo (y fichas
## iniciales). Valores negativos se tratan como 0.
func _init(rate_per_tick: float, burst: float) -> void:
	_rate_per_tick = maxf(rate_per_tick, 0.0)
	_burst = maxf(burst, 0.0)
	_tokens = _burst


## Intenta gastar [param cost] fichas en el tick [param now_tick]. Devuelve true si había
## suficientes (y las gasta) y false si no (y no gasta nada). Un coste mayor que la capacidad
## del cubo nunca se concede. Un tick anterior al último consultado no recarga.
func try_consume(now_tick: int, cost: float = 1.0) -> bool:
	_refill(now_tick)
	if cost > _tokens:
		return false
	_tokens -= cost
	return true


## Fichas disponibles en el tick [param now_tick] (recarga incluida, sin gastar nada).
func get_tokens(now_tick: int) -> float:
	_refill(now_tick)
	return _tokens


## Capacidad del cubo.
func get_burst() -> float:
	return _burst


func _refill(now_tick: int) -> void:
	if _last_tick < 0:
		_last_tick = now_tick
		return
	if now_tick > _last_tick:
		_tokens = minf(_burst, _tokens + _rate_per_tick * float(now_tick - _last_tick))
		_last_tick = now_tick
