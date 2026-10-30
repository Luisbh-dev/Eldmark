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
## [br][br]
## [b]Banderas.[/b] Los flags de cada hueco son los bits 0-2 del registro de red (bit 0 suelo, bits 1-2
## contador de teletransporte; [constant EntityRecord.HISTORY_FLAGS_MASK]) más las banderas defensivas de
## [method ActionMachine.defense_flags] (bit 3 bloqueando, bit 4 ventana de parada, bit 5 invulnerable,
## bit 6 muerto, bit 7 bloqueo ancho del muro de escudos), que usa el [CombatResolver] para decidir si un
## golpe rebobinado se bloquea, se para o se esquiva. El bit 3 del registro de red (ranura de arma 2,
## docs/habilidades.md, sección 5.2) [b]no[/b] entra nunca: aquí el bit 3 es
## [constant ActionMachine.DEFENSE_BLOCKING]; quien graba enmascara los flags del registro.
## [br][br]
## [b]Proyectiles[/b] (docs/habilidades.md, sección 4.4): [method position_at] lee la posición de un tick
## exacto sin crear objetos (el rebobinado de los proyectiles es de ticks enteros) y cada pista mantiene al
## grabar [constant SWEPT_BLOCKS] cajas de [constant SWEPT_BLOCK_TICKS] ticks con las posiciones de los
## pies: [method swept_box] es su unión, la criba barata de los candidatos de una flecha.

## Ticks que recuerda cada pista. Potencia de 2 para indexar con una máscara.
const LENGTH_TICKS: int = 64
## Ticks de cada bloque de la caja barrida (potencia de 2: el bloque de un tick es
## [code]tick >> 3[/code]).
const SWEPT_BLOCK_TICKS: int = 8
## Bloques que guarda cada pista (potencia de 2): el del último tick grabado y los tres anteriores
## cubren al menos sus 25 ticks anteriores, más que el tope de rebobinado (24).
const SWEPT_BLOCKS: int = 4
const _SWEPT_BLOCK_SHIFT: int = 3

# net_id -> pista.
var _tracks: Dictionary[int, Track] = {}


## Resultado de [method sample]: posición, yaw y flags de la entidad en ese instante.
class Sample:
	var position: Vector3
	var yaw: float
	## Bits 0-2 del registro de red (bit 0 grounded; bits 1-2 contador de teletransporte) y bits 3-7
	## defensivos ([method ActionMachine.defense_flags]).
	var flags: int


## Pista de una entidad.
class Track:
	var positions: PackedVector3Array = PackedVector3Array()
	var yaws: PackedFloat32Array = PackedFloat32Array()
	var flags: PackedByteArray = PackedByteArray()
	# Tick que guarda cada hueco; -1 si está vacío. De 64 bits: los ticks del servidor son u32 y
	# pasan de 2^31 a los 414 días de proceso.
	var ticks: PackedInt64Array = PackedInt64Array()
	# Cajas barridas por bloques de SWEPT_BLOCK_TICKS ticks: el bloque que guarda cada hueco (-1 vacío)
	# y la esquina mínima y máxima de las posiciones grabadas en él.
	var block_ids: PackedInt64Array = PackedInt64Array()
	var block_min: PackedVector3Array = PackedVector3Array()
	var block_max: PackedVector3Array = PackedVector3Array()
	# Bloque del último tick grabado (-1 = ninguno) y la unión de las cajas de los bloques que cuentan (el
	# último y los SWEPT_BLOCKS - 1 anteriores), al día en cada grabación: swept_box no recorre nada.
	var last_block: int = -1
	var union_min: Vector3 = Vector3.ZERO
	var union_max: Vector3 = Vector3.ZERO


	func _init() -> void:
		positions.resize(LENGTH_TICKS)
		yaws.resize(LENGTH_TICKS)
		flags.resize(LENGTH_TICKS)
		ticks.resize(LENGTH_TICKS)
		ticks.fill(-1)
		block_ids.resize(SWEPT_BLOCKS)
		block_ids.fill(-1)
		block_min.resize(SWEPT_BLOCKS)
		block_max.resize(SWEPT_BLOCKS)


	# Escribe un hueco en el sitio y amplía la caja de su bloque. Va dentro de la pista (y no en
	# StateHistory) para que los arrays se modifiquen directamente y no a través de una copia temporal.
	func write(slot: int, tick: int, position: Vector3, yaw: float, flags_byte: int) -> void:
		positions[slot] = position
		yaws[slot] = yaw
		flags[slot] = flags_byte
		ticks[slot] = tick
		var block: int = tick >> _SWEPT_BLOCK_SHIFT
		var block_slot: int = block & (SWEPT_BLOCKS - 1)
		if block_ids[block_slot] != block:
			block_ids[block_slot] = block
			block_min[block_slot] = position
			block_max[block_slot] = position
		else:
			block_min[block_slot] = block_min[block_slot].min(position)
			block_max[block_slot] = block_max[block_slot].max(position)
		if block > last_block:
			# Bloque nuevo: la unión se rehace con él y los anteriores que aún cuentan (cada 8 ticks).
			last_block = block
			union_min = position
			union_max = position
			for other: int in SWEPT_BLOCKS:
				var other_block: int = block_ids[other]
				if other_block >= 0 and other_block < block and block - other_block < SWEPT_BLOCKS:
					union_min = union_min.min(block_min[other])
					union_max = union_max.max(block_max[other])
		elif last_block - block < SWEPT_BLOCKS:
			union_min = union_min.min(position)
			union_max = union_max.max(position)


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


## Flags de [param net_id] en el tick exacto [param tick], o -1 si ese tick no está grabado (la
## entidad no tiene pista, el tick es más viejo que el anillo o más nuevo que el último grabado).
func get_flags(net_id: int, tick: int) -> int:
	var track: Track = _tracks.get(net_id)
	if track == null or tick < 0:
		return -1
	var slot: int = tick & (LENGTH_TICKS - 1)
	if track.ticks[slot] != tick:
		return -1
	return track.flags[slot]


## Posición (los pies) de [param net_id] en el tick exacto [param tick], o [constant Vector3.INF] si ese
## tick no está grabado. No crea ningún objeto: es la lectura de los proyectiles, que rebobinan ticks
## enteros (docs/habilidades.md, sección 4.4).
func position_at(net_id: int, tick: int) -> Vector3:
	var track: Track = _tracks.get(net_id)
	if track == null or tick < 0:
		return Vector3.INF
	var slot: int = tick & (LENGTH_TICKS - 1)
	if track.ticks[slot] != tick:
		return Vector3.INF
	return track.positions[slot]


## Caja barrida de [param net_id]: la unión de las cajas de los [constant SWEPT_BLOCKS] bloques de
## [constant SWEPT_BLOCK_TICKS] ticks que acaban en el del último tick grabado (los más viejos no
## cuentan). Si ese tick es [code]s − 1[/code], cubre todas las posiciones grabadas de
## [code][s − 25, s − 1][/code] (y alguna más antigua). Son los pies: quien la usa la ensancha con la
## cápsula. Sin nada grabado, una caja de tamaño negativo ([code]size.x < 0[/code]).
func swept_box(net_id: int) -> AABB:
	var track: Track = _tracks.get(net_id)
	if track == null or track.last_block < 0:
		return AABB(Vector3.ZERO, -Vector3.ONE)
	return AABB(track.union_min, track.union_max - track.union_min)


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
