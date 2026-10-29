extends TestCase
## Pruebas de la infraestructura de audio (ART-10): el diseño de buses, los volúmenes guardados
## ([AudioBuses]) y el reparto de voces del [AudioDirector] con sonidos sintéticos ([ToneFixture]):
## límite de voces por categoría con 64 sonidos, prioridad por distancia, descarte por lejanía,
## reutilización de las voces y variación con [AudioStreamRandomizer].

const SETTINGS_TEST_PATH: String = "user://test_audio_buses.cfg"

var _director: AudioDirector = null


func before_each() -> void:
	AudioBuses.reset_volumes()
	_director = AudioDirector.new()
	_director.load_volumes_on_ready = false
	tree.root.add_child(_director)


func after_each() -> void:
	if is_instance_valid(_director):
		_director.stop_all()
		tree.root.remove_child(_director)
		_director.free()
	_director = null
	AudioBuses.reset_volumes()
	if FileAccess.file_exists(SETTINGS_TEST_PATH):
		DirAccess.remove_absolute(SETTINGS_TEST_PATH)


# --- Buses y volúmenes ------------------------------------------------------------------------

func test_bus_layout_has_the_six_buses() -> void:
	assert_eq(AudioServer.bus_count, AudioBuses.ALL.size(), "seis buses")
	for index: int in AudioBuses.ALL.size():
		var bus: StringName = AudioBuses.ALL[index]
		assert_eq(AudioServer.get_bus_index(bus), index, "%s está en su sitio" % bus)
		assert_true(AudioBuses.has_bus(bus))
		if bus != AudioBuses.MASTER:
			assert_eq(AudioServer.get_bus_send(index), AudioBuses.MASTER,
					"%s manda a Master" % bus)
	var master: int = AudioServer.get_bus_index(AudioBuses.MASTER)
	assert_eq(AudioServer.get_bus_effect_count(master), 1, "Master lleva un efecto")
	assert_true(AudioServer.get_bus_effect(master, 0) is AudioEffectHardLimiter,
			"y es el limitador")
	assert_true(AudioServer.is_bus_effect_enabled(master, 0), "activo")
	assert_false(AudioBuses.has_bus(&"NoExiste"))


func test_every_category_goes_to_an_existing_bus() -> void:
	for category: int in AudioDirector.CATEGORY_BUSES:
		assert_true(AudioBuses.has_bus(AudioDirector.CATEGORY_BUSES[category]),
				"el bus de la categoría %d existe" % category)
		assert_true(AudioDirector.VOICE_LIMITS.has(category), "y tiene límite de voces")
		assert_true(AudioDirector.MAX_DISTANCES.has(category), "y distancia máxima")
	for player: AudioStreamPlayer3D in _director.get_players_3d(AudioDirector.Category.SFX):
		assert_eq(player.bus, AudioBuses.SFX, "los reproductores usan su bus")
	for player: AudioStreamPlayer in _director.get_players_ui():
		assert_eq(player.bus, AudioBuses.UI)


func test_volume_is_linear_and_zero_mutes() -> void:
	AudioBuses.set_volume(AudioBuses.SFX, 0.5)
	var index: int = AudioServer.get_bus_index(AudioBuses.SFX)
	assert_near(AudioServer.get_bus_volume_db(index), linear_to_db(0.5), 0.001)
	assert_near(AudioBuses.get_volume(AudioBuses.SFX), 0.5, 0.001)
	assert_false(AudioServer.is_bus_mute(index))
	AudioBuses.set_volume(AudioBuses.SFX, 0.0)
	assert_true(AudioServer.is_bus_mute(index), "con 0 el bus se silencia")
	assert_eq(AudioBuses.get_volume(AudioBuses.SFX), 0.0)
	AudioBuses.set_volume(AudioBuses.SFX, 7.0)
	assert_near(AudioBuses.get_volume(AudioBuses.SFX), 1.0, 0.001, "se limita a 1")
	assert_false(AudioServer.is_bus_mute(index), "y al subirlo se quita el silencio")
	# Un bus que no existe no hace nada (ni error).
	AudioBuses.set_volume(&"NoExiste", 0.3)
	assert_eq(AudioBuses.get_volume(&"NoExiste"), 0.0)


func test_volumes_round_trip_through_the_file() -> void:
	AudioBuses.set_volume(AudioBuses.MASTER, 0.9)
	AudioBuses.set_volume(AudioBuses.MUSIC, 0.25)
	AudioBuses.set_volume(AudioBuses.SFX, 0.0)
	AudioBuses.set_volume(AudioBuses.AMBIENCE, 0.4)
	AudioBuses.set_volume(AudioBuses.UI, 0.6)
	AudioBuses.set_volume(AudioBuses.VOICES, 0.75)
	var expected: Dictionary = AudioBuses.get_volumes()
	assert_eq(AudioBuses.save_volumes(SETTINGS_TEST_PATH), OK)
	AudioBuses.reset_volumes()
	assert_near(AudioBuses.get_volume(AudioBuses.MUSIC), AudioBuses.default_volume(AudioBuses.MUSIC),
			0.001, "tras restaurar vuelven los de fábrica")
	var loaded: Dictionary = AudioBuses.load_volumes(SETTINGS_TEST_PATH)
	for bus: StringName in AudioBuses.ALL:
		assert_near(float(loaded[bus]), float(expected[bus]), 0.002, "%s tras cargar" % bus)
		assert_near(AudioBuses.get_volume(bus), float(expected[bus]), 0.002,
				"%s aplicado al bus" % bus)
	assert_true(AudioServer.is_bus_mute(AudioServer.get_bus_index(AudioBuses.SFX)),
			"el silencio también vuelve")


func test_saving_keeps_the_rest_of_the_file() -> void:
	var config: ConfigFile = ConfigFile.new()
	config.set_value("camera", "fov", 80.0)
	config.set_value("audio", "volume_music", 0.1)
	assert_eq(config.save(SETTINGS_TEST_PATH), OK)
	assert_eq(AudioBuses.save_volumes(SETTINGS_TEST_PATH), OK)
	var back: ConfigFile = ConfigFile.new()
	assert_eq(back.load(SETTINGS_TEST_PATH), OK)
	assert_eq(float(back.get_value("camera", "fov", 0.0)), 80.0, "la otra sección sigue")
	assert_near(float(back.get_value("audio", "volume_music", -1.0)),
			AudioBuses.default_volume(AudioBuses.MUSIC), 0.002, "y el volumen se sobrescribe")
	assert_true(back.has_section_key("audio", AudioBuses.volume_key(AudioBuses.VOICES)))


func test_missing_file_and_bad_values_use_the_defaults() -> void:
	AudioBuses.set_volume(AudioBuses.UI, 0.1)
	AudioBuses.load_volumes("user://no_existe_%d.cfg" % Time.get_ticks_usec())
	assert_near(AudioBuses.get_volume(AudioBuses.UI), AudioBuses.default_volume(AudioBuses.UI),
			0.001, "sin archivo, valores por defecto")
	var config: ConfigFile = ConfigFile.new()
	config.set_value("audio", AudioBuses.volume_key(AudioBuses.UI), "alto")
	config.set_value("audio", AudioBuses.volume_key(AudioBuses.SFX), 5.0)
	config.set_value("audio", AudioBuses.volume_key(AudioBuses.MUSIC), -3)
	assert_eq(config.save(SETTINGS_TEST_PATH), OK)
	AudioBuses.load_volumes(SETTINGS_TEST_PATH)
	assert_near(AudioBuses.get_volume(AudioBuses.UI), AudioBuses.default_volume(AudioBuses.UI),
			0.001, "un valor que no es número se ignora")
	assert_near(AudioBuses.get_volume(AudioBuses.SFX), 1.0, 0.001, "uno alto se limita")
	assert_eq(AudioBuses.get_volume(AudioBuses.MUSIC), 0.0, "uno negativo se limita a 0")


func test_names_and_keys() -> void:
	assert_eq(AudioBuses.display_name(AudioBuses.SFX), "Efectos")
	assert_eq(AudioBuses.display_name(&"Otro"), "Otro")
	assert_eq(AudioBuses.volume_key(AudioBuses.UI), "volume_ui")
	for bus: StringName in AudioBuses.ALL:
		assert_true(AudioBuses.DISPLAY_NAMES.has(bus), "%s tiene nombre en español" % bus)
		assert_true(AudioBuses.DEFAULT_VOLUMES.has(bus), "y volumen por defecto")


# --- Reparto de voces -------------------------------------------------------------------------

func test_synthetic_tone_is_a_valid_stream() -> void:
	var tone: AudioStreamWAV = ToneFixture.make_tone(440.0, 0.5)
	assert_near(tone.get_length(), 0.5, 0.01)
	assert_eq(tone.data.size(), 11025 * 2)


func test_64_sounds_never_exceed_the_voice_limit() -> void:
	var limit: int = _director.get_voice_limit(AudioDirector.Category.SFX)
	assert_eq(limit, AudioDirector.VOICE_LIMITS[AudioDirector.Category.SFX])
	var tone: AudioStreamWAV = ToneFixture.make_tone(330.0, 1.5)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 64
	var accepted: int = 0
	var max_seen_by_director: int = 0
	var max_seen_by_players: int = 0
	# 64 sonidos repartidos en 16 fotogramas, a distancias distintas.
	for burst: int in 16:
		for _i: int in 4:
			var distance: float = rng.randf_range(1.0, 60.0)
			var angle: float = rng.randf_range(0.0, TAU)
			var position: Vector3 = Vector3(cos(angle), 0.0, sin(angle)) * distance
			if _director.play_3d(AudioDirector.Category.SFX, tone, position):
				accepted += 1
		max_seen_by_director = maxi(max_seen_by_director,
				_director.get_active_voices(AudioDirector.Category.SFX))
		max_seen_by_players = maxi(max_seen_by_players, _count_playing_3d(AudioDirector.Category.SFX))
		await wait_process_frames(1)
		max_seen_by_players = maxi(max_seen_by_players, _count_playing_3d(AudioDirector.Category.SFX))
	var stats: Dictionary = _director.get_stats()
	assert_eq(stats["requested"], 64, "64 peticiones")
	assert_eq(stats["started"], accepted, "las aceptadas son las que arrancaron")
	assert_eq(int(stats["started"]) + int(stats["culled"]) + int(stats["dropped"]), 64,
			"cada petición acaba en una de las tres")
	assert_true(max_seen_by_director <= limit,
			"el director nunca cuenta más de %d voces (vio %d)" % [limit, max_seen_by_director])
	assert_true(max_seen_by_players <= limit,
			"ni los reproductores reales suenan a la vez más de %d (vio %d)"
			% [limit, max_seen_by_players])
	assert_eq(max_seen_by_director, limit, "el límite sí se alcanzó")
	assert_true(int(stats["stolen"]) > 0, "hubo voces cedidas a sonidos más cercanos")
	assert_true(_director.get_total_active_voices() <= limit,
			"las demás categorías no se han tocado")


func test_voices_are_released_when_the_sounds_end() -> void:
	var tone: AudioStreamWAV = ToneFixture.make_tone(500.0, 0.2)
	for i: int in 10:
		assert_true(_director.play_3d(AudioDirector.Category.SFX, tone,
				Vector3(float(i), 0.0, 3.0)), "sonido %d" % i)
	assert_eq(_director.get_active_voices(AudioDirector.Category.SFX), 10)
	var waited: float = 0.0
	while _director.get_active_voices(AudioDirector.Category.SFX) > 0 and waited < 3.0:
		await wait_process_frames(5)
		waited += 5.0 / 60.0
	assert_eq(_director.get_active_voices(AudioDirector.Category.SFX), 0,
			"terminan solos y liberan sus voces")
	assert_eq(_count_playing_3d(AudioDirector.Category.SFX), 0)
	assert_true(_director.play_3d(AudioDirector.Category.SFX, tone, Vector3(1.0, 0.0, 1.0)),
			"y se pueden reutilizar")


func test_closer_sound_steals_the_farthest_voice() -> void:
	var tone: AudioStreamWAV = ToneFixture.make_tone(400.0, 2.0)
	var limit: int = _director.get_voice_limit(AudioDirector.Category.SFX)
	for i: int in limit:
		assert_true(_director.play_3d(AudioDirector.Category.SFX, tone,
				Vector3(10.0 + float(i), 0.0, 0.0)), "llena el pool: %d" % i)
	assert_eq(_director.get_active_voices(AudioDirector.Category.SFX), limit)
	var farthest: Vector3 = Vector3(10.0 + float(limit - 1), 0.0, 0.0)
	assert_true(_director.play_3d(AudioDirector.Category.SFX, tone, Vector3(2.0, 0.0, 0.0)),
			"uno más cerca que todos se queda con una voz")
	assert_eq(_director.get_stats()["stolen"], 1)
	assert_eq(_director.get_active_voices(AudioDirector.Category.SFX), limit, "sigue el tope")
	var positions: Array[Vector3] = _playing_positions(AudioDirector.Category.SFX)
	assert_false(positions.has(farthest), "la voz cedida fue la del más lejano")
	assert_true(positions.has(Vector3(2.0, 0.0, 0.0)), "y el nuevo suena")
	assert_false(_director.play_3d(AudioDirector.Category.SFX, tone, Vector3(60.0, 0.0, 0.0)),
			"uno más lejos que todos se descarta")
	assert_eq(_director.get_stats()["dropped"], 1)
	assert_eq(_director.get_stats()["stolen"], 1, "sin robar nada")


func test_priority_bonus_beats_distance() -> void:
	var tone: AudioStreamWAV = ToneFixture.make_tone(400.0, 2.0)
	var limit: int = _director.get_voice_limit(AudioDirector.Category.SFX)
	for i: int in limit:
		_director.play_3d(AudioDirector.Category.SFX, tone, Vector3(5.0 + float(i), 0.0, 0.0))
	assert_false(_director.play_3d(AudioDirector.Category.SFX, tone, Vector3(50.0, 0.0, 0.0)),
			"un sonido lejano sin bono se pierde")
	assert_true(_director.play_3d(AudioDirector.Category.SFX, tone, Vector3(50.0, 0.0, 0.0), 0.0,
			1.0, 1000.0), "pero con un bono grande (el del propio jugador) entra")
	assert_true(_playing_positions(AudioDirector.Category.SFX).has(Vector3(50.0, 0.0, 0.0)))
	# El del bono es ahora el más importante: ni uno cercano le roba la voz.
	for i: int in limit * 2:
		_director.play_3d(AudioDirector.Category.SFX, tone, Vector3(1.0, 0.0, float(i) * 0.01))
	assert_true(_playing_positions(AudioDirector.Category.SFX).has(Vector3(50.0, 0.0, 0.0)),
			"mantiene su voz")


func test_sounds_beyond_the_maximum_distance_are_culled() -> void:
	var tone: AudioStreamWAV = ToneFixture.make_tone(400.0, 0.5)
	var far: float = float(AudioDirector.MAX_DISTANCES[AudioDirector.Category.SFX]) + 1.0
	assert_false(_director.play_3d(AudioDirector.Category.SFX, tone, Vector3(far, 0.0, 0.0)))
	assert_eq(_director.get_stats()["culled"], 1)
	assert_eq(_director.get_active_voices(AudioDirector.Category.SFX), 0, "sin gastar voz")
	# El oyente se mueve: lo que estaba lejos ahora cae dentro.
	var listener: Node3D = Node3D.new()
	tree.root.add_child(listener)
	listener.global_position = Vector3(far, 0.0, 0.0)
	_director.set_listener(listener)
	assert_vec_near(_director.get_listener_position(), Vector3(far, 0.0, 0.0), 0.001)
	assert_true(_director.play_3d(AudioDirector.Category.SFX, tone, Vector3(far - 5.0, 0.0, 0.0)))
	_director.set_listener(null)
	tree.root.remove_child(listener)
	listener.free()
	assert_vec_near(_director.get_listener_position(), Vector3.ZERO, 0.001,
			"sin oyente ni cámara, el origen")


func test_categories_have_independent_pools() -> void:
	var tone: AudioStreamWAV = ToneFixture.make_tone(400.0, 2.0)
	for i: int in _director.get_voice_limit(AudioDirector.Category.SFX):
		_director.play_3d(AudioDirector.Category.SFX, tone, Vector3(3.0, 0.0, float(i)))
	assert_true(_director.play_3d(AudioDirector.Category.VOICES, tone, Vector3(4.0, 0.0, 0.0)),
			"las voces tienen las suyas aunque los efectos estén llenos")
	assert_true(_director.play_3d(AudioDirector.Category.AMBIENCE, tone, Vector3(40.0, 0.0, 0.0)))
	assert_true(_director.play_ui(tone))
	assert_eq(_director.get_active_voices(AudioDirector.Category.VOICES), 1)
	assert_eq(_director.get_active_voices(AudioDirector.Category.AMBIENCE), 1)
	assert_eq(_director.get_active_voices(AudioDirector.Category.UI), 1)
	assert_false(_director.play_3d(AudioDirector.Category.UI, tone, Vector3.ZERO),
			"la interfaz no es posicional")
	assert_false(_director.play_3d(AudioDirector.Category.SFX, null, Vector3.ZERO), "sin sonido")
	assert_false(_director.play_ui(null))
	_director.stop_all()
	assert_eq(_director.get_total_active_voices(), 0, "stop_all para todo")


func test_interface_sounds_respect_their_limit() -> void:
	var tone: AudioStreamWAV = ToneFixture.make_tone(880.0, 1.0)
	var limit: int = _director.get_voice_limit(AudioDirector.Category.UI)
	for _i: int in 20:
		_director.play_ui(tone)
		assert_true(_director.get_active_voices(AudioDirector.Category.UI) <= limit)
	assert_eq(_director.get_active_voices(AudioDirector.Category.UI), limit)
	var playing: int = 0
	for player: AudioStreamPlayer in _director.get_players_ui():
		if player.playing:
			playing += 1
	assert_eq(playing, limit, "los reproductores reales coinciden")
	assert_eq(_director.get_stats()["stolen"], 20 - limit, "a igual prioridad gana el nuevo")


func test_variation_randomizer() -> void:
	var first: AudioStreamWAV = ToneFixture.make_tone(300.0, 0.1)
	var second: AudioStreamWAV = ToneFixture.make_tone(360.0, 0.1)
	var streams: Array[AudioStream] = [first, second]
	var randomizer: AudioStreamRandomizer = AudioDirector.make_variation(streams, 0.1, 2.0)
	assert_eq(randomizer.streams_count, 2)
	assert_near(randomizer.random_pitch, 1.1, 0.0001)
	assert_near(randomizer.random_volume_offset_db, 2.0, 0.0001)
	assert_eq(randomizer.playback_mode, AudioStreamRandomizer.PLAYBACK_RANDOM_NO_REPEATS)
	assert_true(_director.play_3d(AudioDirector.Category.SFX, randomizer, Vector3(2.0, 0.0, 0.0)),
			"el director reproduce un randomizer como cualquier otro sonido")
	assert_eq(_director.get_active_voices(AudioDirector.Category.SFX), 1)
	var none: AudioStreamRandomizer = AudioDirector.make_variation([], -1.0, -1.0)
	assert_eq(none.streams_count, 0)
	assert_eq(none.random_pitch, 1.0, "sin variación negativa")
	assert_eq(none.random_volume_offset_db, 0.0)


func test_volume_and_pitch_reach_the_player() -> void:
	var tone: AudioStreamWAV = ToneFixture.make_tone(300.0, 1.0)
	assert_true(_director.play_3d(AudioDirector.Category.SFX, tone, Vector3(3.0, 0.0, 0.0), -6.0,
			1.25))
	var found: bool = false
	for player: AudioStreamPlayer3D in _director.get_players_3d(AudioDirector.Category.SFX):
		if player.playing:
			found = true
			assert_near(player.volume_db, -6.0, 0.001)
			assert_near(player.pitch_scale, 1.25, 0.001)
			assert_vec_near(player.global_position, Vector3(3.0, 0.0, 0.0), 0.001)
			assert_eq(player.stream, tone)
	assert_true(found, "alguna voz suena")


func test_singleton_follows_the_node_lifetime() -> void:
	assert_eq(AudioDirector.get_instance(), _director)
	var other: AudioDirector = AudioDirector.new()
	other.load_volumes_on_ready = false
	tree.root.add_child(other)
	assert_eq(AudioDirector.get_instance(), other, "el último en entrar manda")
	tree.root.remove_child(other)
	other.free()
	assert_null(AudioDirector.get_instance(), "sin director vivo, null")
	tree.root.remove_child(_director)
	tree.root.add_child(_director)
	assert_eq(AudioDirector.get_instance(), _director)


func test_client_services_install_once() -> void:
	var holder: Node = Node.new()
	tree.root.add_child(holder)
	var services: ClientServices = ClientServices.install(holder)
	assert_not_null(services)
	assert_eq(ClientServices.install(holder), services, "una sola vez")
	assert_not_null(services.get_audio(), "con su director de audio")
	assert_eq(services.get_audio().get_voice_limit(AudioDirector.Category.UI),
			AudioDirector.VOICE_LIMITS[AudioDirector.Category.UI])
	tree.root.remove_child(holder)
	holder.free()


# --- Utilidades -------------------------------------------------------------------------------

# Reproductores 3D de la categoría que suenan de verdad (el contador de la propia prueba).
func _count_playing_3d(category: AudioDirector.Category) -> int:
	var count: int = 0
	for player: AudioStreamPlayer3D in _director.get_players_3d(category):
		if player.playing:
			count += 1
	return count


# Posiciones de los reproductores 3D que suenan.
func _playing_positions(category: AudioDirector.Category) -> Array[Vector3]:
	var positions: Array[Vector3] = []
	for player: AudioStreamPlayer3D in _director.get_players_3d(category):
		if player.playing:
			positions.append(player.global_position)
	return positions
