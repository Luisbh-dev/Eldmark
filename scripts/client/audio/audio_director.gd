class_name AudioDirector
extends Node
## Client audio director (ART-10): distributes sounds across pools of players with a voice limit
## per category and decides which ones play when there are more requests than voices.
## [br][br]
## [b]Categories[/b] ([enum Category]): effects ([constant AudioBuses.SFX]), ambience
## ([constant AudioBuses.AMBIENCE]) and voices ([constant AudioBuses.VOICES]) are positional, with
## one [AudioStreamPlayer3D] per voice ([method play_3d]); interface sounds ([constant
## AudioBuses.UI]) have no position and use [AudioStreamPlayer] ([method play_ui]). Each category
## sends to its bus, has a fixed number of voices ([constant VOICE_LIMITS]) and, for the
## positional ones, a maximum distance ([constant MAX_DISTANCES]) beyond which the sound is not
## even attempted.
## [br][br]
## [b]Priority[/b]: with all the category's voices busy, a new sound steals the voice of the one
## farthest from the listener if it is closer (at equal distance, the oldest one's); otherwise it
## is discarded. [param priority_bonus] (meters) makes a sound pass for closer than it is: the
## player's own sounds should carry a large one so they are never lost in a melee.
## [br][br]
## [b]Variation[/b]: [method make_variation] builds an [AudioStreamRandomizer] with several sounds
## and pitch and volume variation; [method play_3d] and [method play_ui] also accept their own
## pitch and volume.
## [br][br]
## [b]Volumes[/b]: [AudioBuses] applies and saves them in [code]user://settings.cfg[/code]; the
## director loads them on entering the tree ([member load_volumes_on_ready]).
## [br][br]
## Client only. It is not an autoload (the dedicated server must not load it): it is created by
## [ClientServices], a child of the client's root scenes, and [method get_instance] returns it
## (null if there is none).

## Sound categories. Each has its bus, its voice limit and its type (3D or flat).
enum Category { SFX, AMBIENCE, VOICES, UI }

## Bus that each category sends to.
const CATEGORY_BUSES: Dictionary = {
	Category.SFX: AudioBuses.SFX,
	Category.AMBIENCE: AudioBuses.AMBIENCE,
	Category.VOICES: AudioBuses.VOICES,
	Category.UI: AudioBuses.UI,
}
## Simultaneous voices per category (the size of each pool).
const VOICE_LIMITS: Dictionary = {
	Category.SFX: 24, Category.AMBIENCE: 12, Category.VOICES: 8, Category.UI: 6,
}
## Distance (m) beyond which a positional sound is discarded without spending a voice.
const MAX_DISTANCES: Dictionary = {
	Category.SFX: 70.0, Category.AMBIENCE: 140.0, Category.VOICES: 45.0, Category.UI: 0.0,
}
## Meters at which a 3D player sounds at its nominal volume (farther away, it attenuates).
const UNIT_SIZE: float = 8.0

## The counters of [method get_stats] change (a request arrived).
signal stats_changed

## If true, the saved volumes are loaded on entering the tree. Tests disable it.
var load_volumes_on_ready: bool = true

static var _instance: AudioDirector = null

# Category -> Array[Voice].
var _pools: Dictionary = {}
var _listener: Node3D = null
var _serial: int = 0
var _stats: Dictionary = {"requested": 0, "started": 0, "stolen": 0, "culled": 0, "dropped": 0}


## A pool voice: a 3D or flat player, with what is needed to decide whether it is stolen.
class Voice extends RefCounted:
	var player_3d: AudioStreamPlayer3D = null
	var player_2d: AudioStreamPlayer = null
	## Priority it started with: the lower, the more important (distance minus bonus).
	var cost: float = 0.0
	## Start number, to know which is the oldest.
	var serial: int = 0
	## Process frame at which it started (until the engine reflects it, it counts as busy).
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


## Live director, or null if there is none (for example on the server or in a test without it).
static func get_instance() -> AudioDirector:
	return _instance if is_instance_valid(_instance) else null


## Builds an [AudioStreamRandomizer] with [param streams]: each playback picks one without
## repeating the previous one and varies the pitch up to [param pitch_range] above and below (0.08
## = ±8 %) and the volume up to [param volume_range_db] decibels.
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


# --- Playback ---------------------------------------------------------------------------------

## Plays [param stream] at [param position] (global coordinates) through the positional category
## [param category] ([constant Category.SFX], [constant Category.AMBIENCE] or [constant
## Category.VOICES]). [param volume_db] and [param pitch_scale] are the player's own; [param
## priority_bonus] is subtracted (in meters) from the distance to the listener when deciding who
## loses a voice. Returns true if the sound started; false if it was discarded (too far away, no
## free voices to steal, or a category that is not positional).
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


## Plays [param stream] with no position through the interface category. [param priority_bonus]
## counts as meters just as in [method play_3d] (lacking a distance, it only breaks ties). Returns
## true if it started.
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


## Stops all sounds that are playing.
func stop_all() -> void:
	for category: int in _pools:
		for voice: Voice in _pools[category]:
			voice.stop()


# --- Listener ---------------------------------------------------------------------------------

## Sets the node that acts as the listener for distributing voices by distance (null: the active camera).
func set_listener(listener: Node3D) -> void:
	_listener = listener


## Listener position: the node set with [method set_listener], otherwise the viewport's active
## camera and, if there is no camera either, the origin.
func get_listener_position() -> Vector3:
	if is_instance_valid(_listener) and _listener.is_inside_tree():
		return _listener.global_position
	if is_inside_tree():
		var camera: Camera3D = get_viewport().get_camera_3d()
		if camera != null:
			return camera.global_position
	return Vector3.ZERO


# --- Reading (for tests and settings) ---------------------------------------------------------

## Voices currently playing in [param category].
func get_active_voices(category: Category) -> int:
	var count: int = 0
	for voice: Voice in _pools.get(category, []):
		if voice.is_busy():
			count += 1
	return count


## Voices currently playing across all categories.
func get_total_active_voices() -> int:
	var count: int = 0
	for category: int in _pools:
		count += get_active_voices(category as Category)
	return count


## Size of the pool of [param category] (its voice limit).
func get_voice_limit(category: Category) -> int:
	return (_pools.get(category, []) as Array).size()


## Counters since startup: [code]requested[/code] (requests), [code]started[/code] (played),
## [code]stolen[/code] (busy voices given up to a more important sound), [code]culled[/code]
## (discarded by distance) and [code]dropped[/code] (discarded for lack of voices). Each request
## ends up in started, culled or dropped; stolen also counts the voices given up.
func get_stats() -> Dictionary:
	return _stats.duplicate()


## 3D players of [param category] (for tests: counting by hand which ones are playing).
func get_players_3d(category: Category) -> Array[AudioStreamPlayer3D]:
	var players: Array[AudioStreamPlayer3D] = []
	for voice: Voice in _pools.get(category, []):
		players.append(voice.player_3d)
	return players


## Flat players of the interface category.
func get_players_ui() -> Array[AudioStreamPlayer]:
	var players: Array[AudioStreamPlayer] = []
	for voice: Voice in _pools.get(Category.UI, []):
		players.append(voice.player_2d)
	return players


# --- Internal ---------------------------------------------------------------------------------

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


# A free voice of the category or, if all are playing, that of the least important sound when
# the new one (with cost [param cost]) is more important. null if there is none to give up.
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
