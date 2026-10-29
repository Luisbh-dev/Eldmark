class_name StateHistory
extends RefCounted
## Historial de posiciones para la compensación de latencia (docs/red.md, sección 10).
## [br][br]
## Guarda, por entidad, una pista de [constant LENGTH_TICKS] ticks (~1 s) en arrays empaquetados:
## posición, yaw, flags y la etiqueta del tick de cada hueco, indexados por
## [code]tick % LENGTH_TICKS[/code]. La pista se crea al dar de alta la entidad y se escribe en
## el sitio cada tick, sin asignar memoria. Los valores se guardan sin cuantizar y se graban tras
## cada tick, haya interés o no.
## [br][br]
## [method sample] reconstruye cualquier instante (también entre dos ticks) para que la fase 3
## compruebe los golpes contra donde el atacante veía a su objetivo. Nunca se mueven cuerpos hacia
## atrás: se calcula con las muestras.

## Ticks que recuerda cada pista. Potencia de 2 para indexar con una máscara.
const LENGTH_TICKS: int = 64

# net_id -> pista.
var _tracks: Dictionary[int, Track] = {}


## Resultado de [method sample]: posición, yaw y flags de la entidad en ese instante.
class Sample:
	var position: Vector3
	var yaw: float
	## Los flags del registro de red: bit 0 grounded; bits 1-2 contador de teletransporte.
	var flags: int


## Pista de una entidad.
class Track:
	var positions: PackedVector3Array = PackedVector3Array()
	var yaws: PackedFloat32Array = PackedFloat32Array()
	var flags: PackedByteArray = PackedByteArray()
	# Tick que guarda cada hueco; -1 si está vacío. De 64 bits: los ticks del servidor son u32 y
	# pasan de 2^31 a los 414 días de proceso.
	var ticks: PackedInt64Array = PackedInt64Array()


	func _init() -> void:
		positions.resize(LENGTH_TICKS)
		yaws.resize(LENGTH_TICKS)
		flags.resize(LENGTH_TICKS)
		ticks.resize(LENGTH_TICKS)
		ticks.fill(-1)


	# Escribe un hueco en el sitio. Va dentro de la pista (y no en StateHistory) para que los
	# arrays se modifiquen directamente y no a través de una copia temporal.
	func write(slot: int, tick: int, position: Vector3, yaw: float, flags_byte: int) -> void:
		positions[slot] = position
		yaws[slot] = yaw
		flags[slot] = flags_byte
		ticks[slot] = tick


## Crea la pista de [param net_id] (vacía). Si ya existía, la borra.
func add_entity(net_id: int) -> void:
	_tracks[net_id] = Track.new()


## Borra la pista de [param net_id].
func forget(net_id: int) -> void:
	_tracks.erase(net_id)


## Anota el estado de [param net_id] tras simular [param tick]. Sobrescribe el hueco del tick
## [code]tick - LENGTH_TICKS[/code]. Si la entidad no tenía pista, se la crea. No hace nada con
## un tick negativo.
func record(tick: int, net_id: int, position: Vector3, yaw: float, flags: int) -> void:
	if tick < 0:
		return
	var track: Track = _tracks.get(net_id)
	if track == null:
		track = Track.new()
		_tracks[net_id] = track
	track.write(tick & (LENGTH_TICKS - 1), tick, position, yaw, flags & 0xFF)


## true si la pista de [param net_id] guarda exactamente el tick [param tick].
func has_tick(net_id: int, tick: int) -> bool:
	var track: Track = _tracks.get(net_id)
	return track != null and tick >= 0 and track.ticks[tick & (LENGTH_TICKS - 1)] == tick


## Estado de [param net_id] en el instante [param tick] (puede ser fraccionario): interpola
## linealmente entre los dos ticks que lo rodean (posición con lerp, yaw con lerp_angle y flags
## del más cercano). Si el contador de teletransporte cambia entre los dos, devuelve la muestra
## anterior sin interpolar. null si la entidad no tiene pista o el instante está fuera de lo
## grabado (más viejo que el anillo, o más nuevo que el último tick).
func sample(net_id: int, tick: float) -> StateHistory.Sample:
	var track: Track = _tracks.get(net_id)
	if track == null or not is_finite(tick) or tick < 0.0:
		return null
	var floor_tick: int = floori(tick)
	var fraction: float = tick - float(floor_tick)
	var slot_a: int = floor_tick & (LENGTH_TICKS - 1)
	if track.ticks[slot_a] != floor_tick:
		return null
	if fraction <= 0.0:
		return _make_sample(track, slot_a)
	var slot_b: int = (floor_tick + 1) & (LENGTH_TICKS - 1)
	if track.ticks[slot_b] != floor_tick + 1:
		return null
	var flags_a: int = track.flags[slot_a]
	var flags_b: int = track.flags[slot_b]
	if _teleport_counter(flags_a) != _teleport_counter(flags_b):
		return _make_sample(track, slot_a)
	var result := Sample.new()
	result.position = track.positions[slot_a].lerp(track.positions[slot_b], fraction)
	result.yaw = lerp_angle(track.yaws[slot_a], track.yaws[slot_b], fraction)
	result.flags = flags_a if fraction < 0.5 else flags_b
	return result


static func _make_sample(track: Track, slot: int) -> Sample:
	var result := Sample.new()
	result.position = track.positions[slot]
	result.yaw = track.yaws[slot]
	result.flags = track.flags[slot]
	return result


static func _teleport_counter(flags: int) -> int:
	return (flags >> EntityRecord.TELEPORT_SHIFT) & EntityRecord.TELEPORT_MASK
