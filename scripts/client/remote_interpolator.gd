class_name RemoteInterpolator
extends RefCounted
## Interpolación de un jugador remoto (docs/red.md, sección 7).
##
## Guarda las últimas [constant BUFFER_SIZE] muestras [code](tick, EntityRecord)[/code] ordenadas
## por tick, sin duplicados ni muestras más antiguas que la ventana, y [method sample] devuelve
## el registro que hay que dibujar en un instante dado (en ticks, con fracción):
## [br]- [b]Entre dos muestras[/b] con el mismo contador de teletransporte: [code]lerp[/code] de
## posición y velocidad, [code]lerp_angle[/code] del yaw (correcto al cruzar ±PI) y los flags
## (grounded) de la muestra más cercana.
## [br]- [b]Si el contador de teletransporte cambia[/b] entre las dos, no se interpola: se queda en
## la primera hasta que el instante alcanza la segunda.
## [br]- [b]Por detrás de la primera muestra[/b] se queda en ella.
## [br]- [b]Por delante de la última[/b] extrapola en horizontal con su velocidad hasta
## [constant MAX_EXTRAPOLATION_TICKS] ticks (100 ms) y después se queda quieto: extrapolar más
## engañaría al apuntar.
## [br][br]
## Los registros que se guardan no se modifican ni se copian: quien los empuja no debe tocarlos
## después. [method sample] siempre devuelve un registro nuevo.

## Muestras que se guardan.
const BUFFER_SIZE: int = 32
## Ticks máximos que se extrapola por delante de la última muestra.
const MAX_EXTRAPOLATION_TICKS: int = 6

var _ticks: PackedInt64Array = PackedInt64Array()
var _records: Array[EntityRecord] = []


## Guarda la muestra de [param tick]. Se descartan las repetidas (gana la primera) y las más
## antiguas que la ventana cuando el búfer está lleno. Las que llegan desordenadas se insertan en
## su sitio.
func push(tick: int, record: EntityRecord) -> void:
	if record == null:
		return
	var index: int = _ticks.size()
	while index > 0 and _ticks[index - 1] > tick:
		index -= 1
	if index > 0 and _ticks[index - 1] == tick:
		return
	if _ticks.size() >= BUFFER_SIZE:
		if index == 0:
			return
		_ticks.remove_at(0)
		_records.remove_at(0)
		index -= 1
	_ticks.insert(index, tick)
	_records.insert(index, record)


## Registro que se dibuja en el instante [param render_time] (ticks con fracción), o null si no
## hay muestras.
func sample(render_time: float) -> EntityRecord:
	var count: int = _ticks.size()
	if count == 0:
		return null
	if render_time <= float(_ticks[0]):
		return _copy(_records[0])
	var last: int = count - 1
	if render_time >= float(_ticks[last]):
		return _extrapolate(_records[last], render_time - float(_ticks[last]))

	# Última muestra con tick <= render_time; hay una siguiente porque render_time < la última.
	var a: int = last - 1
	while a > 0 and float(_ticks[a]) > render_time:
		a -= 1
	var from: EntityRecord = _records[a]
	var to: EntityRecord = _records[a + 1]
	if from.get_teleport_counter() != to.get_teleport_counter():
		return _copy(from)
	var span: float = float(_ticks[a + 1] - _ticks[a])
	var weight: float = clampf((render_time - float(_ticks[a])) / span, 0.0, 1.0)
	return EntityRecord.interpolate(from, to, weight)


## Tick de la muestra más nueva, o 0 si no hay ninguna.
func get_newest_tick() -> int:
	if _ticks.is_empty():
		return 0
	return _ticks[_ticks.size() - 1]


## Tick de la muestra más antigua, o 0 si no hay ninguna.
func get_oldest_tick() -> int:
	if _ticks.is_empty():
		return 0
	return _ticks[0]


## Número de muestras guardadas.
func get_sample_count() -> int:
	return _ticks.size()


## Descarta todas las muestras.
func clear() -> void:
	_ticks.clear()
	_records.clear()


# Extrapola en horizontal con la velocidad de la última muestra hasta MAX_EXTRAPOLATION_TICKS;
# pasado ese tiempo se queda quieto.
func _extrapolate(newest: EntityRecord, ticks_ahead: float) -> EntityRecord:
	var record: EntityRecord = _copy(newest)
	if ticks_ahead <= 0.0:
		return record
	var seconds: float = minf(ticks_ahead, float(MAX_EXTRAPOLATION_TICKS)) \
			/ float(Engine.physics_ticks_per_second)
	record.position += Vector3(newest.velocity.x, 0.0, newest.velocity.z) * seconds
	if ticks_ahead > float(MAX_EXTRAPOLATION_TICKS):
		record.velocity = Vector3.ZERO
	return record


static func _copy(source: EntityRecord) -> EntityRecord:
	var record := EntityRecord.new()
	record.net_id = source.net_id
	record.kind = source.kind
	record.position = source.position
	record.yaw = source.yaw
	record.velocity = source.velocity
	record.flags = source.flags
	record.action = source.action
	return record
