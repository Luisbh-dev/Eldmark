class_name AudioDirector
extends Node
## Director de audio del cliente (ART-10): reparte los sonidos en pools de reproductores con un
## límite de voces por categoría y decide cuáles suenan cuando hay más peticiones que voces.
## [br][br]
## [b]Categorías[/b] ([enum Category]): efectos ([constant AudioBuses.SFX]), ambiente
## ([constant AudioBuses.AMBIENCE]) y voces ([constant AudioBuses.VOICES]) son posicionales, con un
## [AudioStreamPlayer3D] por voz ([method play_3d]); los sonidos de interfaz ([constant
## AudioBuses.UI]) no tienen posición y usan [AudioStreamPlayer] ([method play_ui]). Cada categoría
## manda a su bus, tiene un número fijo de voces ([constant VOICE_LIMITS]) y, las posicionales, una
## distancia máxima ([constant MAX_DISTANCES]) a partir de la cual el sonido ni se intenta.
## [br][br]
## [b]Prioridad[/b]: con todas las voces de la categoría ocupadas, un sonido nuevo roba la voz del
## más lejano al oyente si él está más cerca (a igual distancia, la del más antiguo); si no, se
## descarta. [param priority_bonus] (metros) hace pasar un sonido por más cercano de lo que está: los
## del propio jugador deberían llevar uno grande para no perderse nunca en una refriega.
## [br][br]
## [b]Variación[/b]: [method make_variation] monta un [AudioStreamRandomizer] con varios sonidos y
## variación de tono y volumen; [method play_3d] y [method play_ui] aceptan además un tono y un
## volumen propios.
## [br][br]
## [b]Volúmenes[/b]: [AudioBuses] los aplica y los guarda en [code]user://settings.cfg[/code]; el
## director los carga al entrar en el árbol ([member load_volumes_on_ready]).
## [br][br]
## Solo cliente. No es un autoload (el servidor dedicado no debe cargarlo): lo crea [ClientServices],
## un hijo de las escenas raíz del cliente, y [method get_instance] lo devuelve (null si no hay).

## Categorías de sonido. Cada una tiene su bus, su límite de voces y su tipo (3D o plano).
enum Category { SFX, AMBIENCE, VOICES, UI }

## Bus al que manda cada categoría.
const CATEGORY_BUSES: Dictionary = {
	Category.SFX: AudioBuses.SFX,
	Category.AMBIENCE: AudioBuses.AMBIENCE,
	Category.VOICES: AudioBuses.VOICES,
	Category.UI: AudioBuses.UI,
}
## Voces simultáneas por categoría (el tamaño de cada pool).
const VOICE_LIMITS: Dictionary = {
	Category.SFX: 24, Category.AMBIENCE: 12, Category.VOICES: 8, Category.UI: 6,
}
## Distancia (m) más allá de la cual un sonido posicional se descarta sin gastar una voz.
const MAX_DISTANCES: Dictionary = {
	Category.SFX: 70.0, Category.AMBIENCE: 140.0, Category.VOICES: 45.0, Category.UI: 0.0,
}
## Metros a los que un reproductor 3D suena a su volumen nominal (más lejos, atenúa).
const UNIT_SIZE: float = 8.0

## Cambian los contadores de [method get_stats] (llegó una petición).
signal stats_changed

## Si es true, al entrar en el árbol se cargan los volúmenes guardados. Las pruebas lo desactivan.
var load_volumes_on_ready: bool = true

static var _instance: AudioDirector = null

# Categoría -> Array[Voice].
var _pools: Dictionary = {}
var _listener: Node3D = null
var _serial: int = 0
var _stats: Dictionary = {"requested": 0, "started": 0, "stolen": 0, "culled": 0, "dropped": 0}


## Una voz del pool: un reproductor 3D o plano, con lo que hace falta para decidir si se roba.
class Voice extends RefCounted:
	var player_3d: AudioStreamPlayer3D = null
	var player_2d: AudioStreamPlayer = null
	## Prioridad con la que arrancó: cuanto menor, más importante (distancia menos bonus).
	var cost: float = 0.0
	## Número de arranque, para saber cuál es la más antigua.
	var serial: int = 0
	## Fotograma de proceso en el que arrancó (hasta que el motor lo refleja cuenta como ocupada).
	var started_frame: int = -1

	func is_busy() -> bool:
		if started_frame == Engine.get_process_frames():
			return true
		if player_3d != null:
			return player_3d.playing
		return player_2d != null and player_2d.playing

	func stop() -> void:
		started_frame = -1
		if player_3d != null:
			player_3d.stop()
		elif player_2d != null:
			player_2d.stop()


## Director vivo, o null si no hay (por ejemplo en el servidor o en una prueba sin él).
static func get_instance() -> AudioDirector:
	return _instance if is_instance_valid(_instance) else null


## Monta un [AudioStreamRandomizer] con [param streams]: cada reproducción elige uno sin repetir el
## anterior y varía el tono hasta [param pitch_range] por arriba y por abajo (0,08 = ±8 %) y el volumen
## hasta [param volume_range_db] decibelios.
static func make_variation(streams: Array[AudioStream], pitch_range: float = 0.08,
		volume_range_db: float = 1.5) -> AudioStreamRandomizer:
	var randomizer: AudioStreamRandomizer = AudioStreamRandomizer.new()
	randomizer.playback_mode = AudioStreamRandomizer.PLAYBACK_RANDOM_NO_REPEATS
	randomizer.random_pitch = 1.0 + maxf(pitch_range, 0.0)
	randomizer.random_volume_offset_db = maxf(volume_range_db, 0.0)
	for stream: AudioStream in streams:
		randomizer.add_stream(-1, stream)
	return randomizer


func _enter_tree() -> void:
	_instance = self


func _exit_tree() -> void:
	if _instance == self:
		_instance = null


func _ready() -> void:
	name = "AudioDirector"
	_build_pools()
	if load_volumes_on_ready:
		AudioBuses.load_volumes()


# --- Reproducción -----------------------------------------------------------------------------

## Reproduce [param stream] en [param position] (coordenadas globales) por la categoría posicional
## [param category] ([constant Category.SFX], [constant Category.AMBIENCE] o [constant
## Category.VOICES]). [param volume_db] y [param pitch_scale] son los del reproductor; [param
## priority_bonus] se resta (en metros) a la distancia al oyente al decidir quién se queda sin voz.
## Devuelve true si el sonido arrancó; false si se descartó (muy lejos, sin voces libres que robar o
## una categoría que no es posicional).
func play_3d(category: Category, stream: AudioStream, position: Vector3, volume_db: float = 0.0,
		pitch_scale: float = 1.0, priority_bonus: float = 0.0) -> bool:
	_stats["requested"] += 1
	if stream == null or category == Category.UI or not _pools.has(category):
		return _drop("dropped")
	var distance: float = get_listener_position().distance_to(position)
	if distance > float(MAX_DISTANCES[category]):
		return _drop("culled")
	var cost: float = distance - priority_bonus
	var voice: Voice = _acquire_voice(category, cost)
	if voice == null:
		return _drop("dropped")
	var player: AudioStreamPlayer3D = voice.player_3d
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = maxf(pitch_scale, 0.01)
	player.global_position = position
	_start(voice, cost)
	return true


## Reproduce [param stream] sin posición por la categoría de interfaz. [param priority_bonus] cuenta
## como metros igual que en [method play_3d] (a falta de distancia, solo desempata). Devuelve true si
## arrancó.
func play_ui(stream: AudioStream, volume_db: float = 0.0, pitch_scale: float = 1.0,
		priority_bonus: float = 0.0) -> bool:
	_stats["requested"] += 1
	if stream == null or not _pools.has(Category.UI):
		return _drop("dropped")
	var cost: float = -priority_bonus
	var voice: Voice = _acquire_voice(Category.UI, cost)
	if voice == null:
		return _drop("dropped")
	var player: AudioStreamPlayer = voice.player_2d
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = maxf(pitch_scale, 0.01)
	_start(voice, cost)
	return true


## Para todos los sonidos que están sonando.
func stop_all() -> void:
	for category: int in _pools:
		for voice: Voice in _pools[category]:
			voice.stop()


# --- Oyente -----------------------------------------------------------------------------------

## Fija el nodo que hace de oyente para repartir las voces por distancia (null: la cámara activa).
func set_listener(listener: Node3D) -> void:
	_listener = listener


## Posición del oyente: el nodo fijado con [method set_listener], si no la cámara activa del
## viewport y, si tampoco hay cámara, el origen.
func get_listener_position() -> Vector3:
	if is_instance_valid(_listener) and _listener.is_inside_tree():
		return _listener.global_position
	if is_inside_tree():
		var camera: Camera3D = get_viewport().get_camera_3d()
		if camera != null:
			return camera.global_position
	return Vector3.ZERO


# --- Lectura (para las pruebas y los ajustes) -------------------------------------------------

## Voces que suenan ahora en [param category].
func get_active_voices(category: Category) -> int:
	var count: int = 0
	for voice: Voice in _pools.get(category, []):
		if voice.is_busy():
			count += 1
	return count


## Voces que suenan ahora en todas las categorías.
func get_total_active_voices() -> int:
	var count: int = 0
	for category: int in _pools:
		count += get_active_voices(category as Category)
	return count


## Tamaño del pool de [param category] (su límite de voces).
func get_voice_limit(category: Category) -> int:
	return (_pools.get(category, []) as Array).size()


## Contadores desde el arranque: [code]requested[/code] (peticiones), [code]started[/code] (sonaron),
## [code]stolen[/code] (voces ocupadas cedidas a un sonido más importante), [code]culled[/code]
## (descartadas por distancia) y [code]dropped[/code] (descartadas por falta de voces). Cada petición
## acaba en started, culled o dropped; stolen cuenta además las voces cedidas.
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Reproductores 3D de [param category] (para las pruebas: contar a mano los que suenan).
func get_players_3d(category: Category) -> Array[AudioStreamPlayer3D]:
	var players: Array[AudioStreamPlayer3D] = []
	for voice: Voice in _pools.get(category, []):
		players.append(voice.player_3d)
	return players


## Reproductores planos de la categoría de interfaz.
func get_players_ui() -> Array[AudioStreamPlayer]:
	var players: Array[AudioStreamPlayer] = []
	for voice: Voice in _pools.get(Category.UI, []):
		players.append(voice.player_2d)
	return players


# --- Interno ----------------------------------------------------------------------------------

func _build_pools() -> void:
	for category: int in VOICE_LIMITS:
		var voices: Array[Voice] = []
		for index: int in int(VOICE_LIMITS[category]):
			var voice: Voice = Voice.new()
			if category == Category.UI:
				var flat: AudioStreamPlayer = AudioStreamPlayer.new()
				flat.name = "Ui%d" % index
				flat.bus = CATEGORY_BUSES[category]
				voice.player_2d = flat
				add_child(flat)
			else:
				var positional: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
				positional.name = "%s%d" % [String(CATEGORY_BUSES[category]), index]
				positional.bus = CATEGORY_BUSES[category]
				positional.max_distance = float(MAX_DISTANCES[category])
				positional.unit_size = UNIT_SIZE
				positional.max_polyphony = 1
				voice.player_3d = positional
				add_child(positional)
			voices.append(voice)
		_pools[category] = voices


# Una voz libre de la categoría o, si todas suenan, la del sonido menos importante cuando el nuevo
# (con coste [param cost]) lo es más. null si no hay ninguna que ceder.
func _acquire_voice(category: Category, cost: float) -> Voice:
	var victim: Voice = null
	for voice: Voice in _pools[category]:
		if not voice.is_busy():
			return voice
		if victim == null or voice.cost > victim.cost \
				or (voice.cost == victim.cost and voice.serial < victim.serial):
			victim = voice
	if victim == null or cost > victim.cost:
		return null
	victim.stop()
	_stats["stolen"] += 1
	return victim


func _start(voice: Voice, cost: float) -> void:
	_serial += 1
	voice.serial = _serial
	voice.cost = cost
	voice.started_frame = Engine.get_process_frames()
	if voice.player_3d != null:
		voice.player_3d.play()
	else:
		voice.player_2d.play()
	_stats["started"] += 1
	stats_changed.emit()


func _drop(counter: String) -> bool:
	_stats[counter] += 1
	stats_changed.emit()
	return false
