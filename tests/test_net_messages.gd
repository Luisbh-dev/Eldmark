extends TestCase
## Pruebas del paquete A de la fase 2 (docs/red.md, secciones 5, 6.1 y 16): formatos de los
## mensajes de red ([NetMessages]), cuantización ([NetMath], [EntityRecord]), constantes y
## utilidades ([NetProtocol], [NetZones]), el cerebro de los bots ([BotBrain]) y los cambios en
## [PlayerState] y [PlayerCharacter] (redondeo del yaw a f32, [code]equals_exact[/code] y
## [code]events_enabled[/code]).
## [br][br]
## Los offsets y tamaños de las pruebas son los del documento, escritos a mano a propósito: si el
## código y el documento se separan, estas pruebas fallan.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const WORLD_LAYER: int = 1
const FUZZ_BUFFERS: int = 10000
const FUZZ_SEED: int = 20260417
## Error máximo de la posición cuantizada (5 mm; la resolución es 1 cm) más el redondeo a f32 de
## los componentes de un [Vector3], que a 5 km es de 0,25 mm.
const POSITION_ERROR: float = 0.005 + 0.0003
## Error máximo del cuantizador en sí, en centímetros (medio paso).
const QUANTIZER_HALF_STEP: float = 0.5 + 1e-9

## Cabecera de un SNAPSHOT con estado propio: 13 B + estado + bloque extra + section_count.
const HEADER_WITH_STATE: int = 13 + PlayerState.ENCODED_SIZE + NetMessages.SNAPSHOT_EXTRA_SIZE + 1

var _world: Node3D
var _character: PlayerCharacter
var _dt: float = 1.0 / 60.0
var _next_tick: int = 1
var _jumped_count: int = 0
var _landed_count: int = 0


func after_each() -> void:
	if is_instance_valid(_world):
		_world.get_parent().remove_child(_world)
		_world.queue_free()
	_world = null
	_character = null
	await wait_process_frames()


# --- PlayerState y PlayerCharacter (6.1) ------------------------------------------------------

func test_to_f32_rounds_to_single_precision() -> void:
	assert_eq(PlayerState.to_f32(1.5), 1.5, "un valor exacto en f32 no cambia")
	assert_eq(PlayerState.to_f32(0.0), 0.0, "cero")
	assert_eq(PlayerState.to_f32(-3.25), -3.25, "negativo exacto")
	var rounded: float = PlayerState.to_f32(0.1)
	assert_true(rounded != 0.1, "0.1 no es exacto en f32")
	assert_near(rounded, 0.1, 1e-8, "queda muy cerca del original")
	assert_eq(PlayerState.to_f32(rounded), rounded, "es idempotente")
	assert_true(is_nan(PlayerState.to_f32(NAN)), "un NaN sigue siendo NaN")
	assert_true(is_inf(PlayerState.to_f32(1e300)), "lo que no cabe en f32 pasa a infinito")

	# Es exactamente lo que le pasa al yaw en PlayerState.encode()/decode().
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for _i: int in 200:
		var state := PlayerState.new()
		state.yaw = rng.randf_range(-PI, PI)
		assert_eq(PlayerState.decode(state.encode()).yaw, PlayerState.to_f32(state.yaw),
				"to_f32 coincide con la ida y vuelta de encode()")


func test_equals_exact_compares_encoded_bytes() -> void:
	var a := PlayerState.new()
	a.position = Vector3(1.5, 2.25, -3.0)
	a.velocity = Vector3(0.5, -1.0, 2.0)
	a.yaw = PlayerState.to_f32(1.2)
	a.grounded = true
	a.prev_buttons = PlayerInput.JUMP
	a.last_input_tick = 77
	a.coyote_ticks = 3
	a.jump_buffer_ticks = 4
	var b: PlayerState = a.duplicate_state()
	assert_true(a.equals_exact(b), "una copia es igual")
	assert_true(a.equals_exact(a), "igual a sí mismo")
	assert_false(a.equals_exact(null), "null nunca es igual")

	for field: String in ["position", "velocity", "yaw", "grounded", "prev_buttons",
			"last_input_tick", "coyote_ticks", "jump_buffer_ticks"]:
		var changed: PlayerState = a.duplicate_state()
		match field:
			"position":
				changed.position.x += 0.0001
			"velocity":
				changed.velocity.z += 0.001
			"yaw":
				changed.yaw += 0.0001
			"grounded":
				changed.grounded = false
			"prev_buttons":
				changed.prev_buttons = PlayerInput.PRIMARY
			"last_input_tick":
				changed.last_input_tick += 1
			"coyote_ticks":
				changed.coyote_ticks = 4
			"jump_buffer_ticks":
				changed.jump_buffer_ticks = 5
		assert_false(a.equals_exact(changed), "se detecta una diferencia en %s" % field)
	# is_close_to tolera lo que equals_exact no: es la diferencia que importa a la reconciliación.
	var nearly: PlayerState = a.duplicate_state()
	nearly.position += Vector3(0.001, 0.0, 0.0)
	assert_true(a.is_close_to(nearly), "is_close_to tolera 1 mm")
	assert_false(a.equals_exact(nearly), "equals_exact no")


func test_character_yaw_is_rounded_to_f32() -> void:
	if not await _make_world():
		return
	_character.yaw = 0.1
	assert_eq(_character.yaw, PlayerState.to_f32(0.1), "el setter redondea a f32")
	assert_true(_character.yaw != 0.1, "y por tanto cambia el valor de doble precisión")
	assert_true(_character.basis == Basis(Vector3.UP, _character.yaw),
			"la base sale del yaw ya redondeado")
	assert_eq(PlayerState.decode(_character.get_state().encode()).yaw, _character.yaw,
			"el yaw sobrevive exactamente a encode()/decode()")

	# Girando, el estado entero sobrevive a la ida y vuelta por la red bit a bit.
	await wait_physics_frames()
	_character.set_state(_state_at(Vector3(0.0, 0.05, 0.0), 0.0, false))
	for tick: int in 180:
		var look_yaw: float = sin(tick * 0.07) * 3.0
		_character.simulate(_make_input(Vector2(0.3, 1.0), look_yaw, 0), _dt)
		var state: PlayerState = _character.get_state()
		if not state.equals_exact(PlayerState.decode(state.encode())):
			fail("el estado del tick %d no sobrevive exactamente a la ida y vuelta" % tick)
			return
	assert_true(_character.grounded, "el personaje acabó en el suelo")


func test_events_enabled_controls_jumped_and_landed() -> void:
	if not await _make_world():
		return
	_character.jumped.connect(_on_jumped)
	_character.landed.connect(_on_landed)
	await wait_physics_frames()
	assert_true(_character.events_enabled, "los eventos están activados por defecto")

	# Con los eventos: caer emite landed.
	_character.set_state(_state_at(Vector3(0.0, 0.5, 0.0), 0.0, false))
	_step_until_grounded()
	assert_eq(_landed_count, 1, "con events_enabled aterrizar emite landed")
	assert_eq(_jumped_count, 0, "caer no emite jumped")

	# Misma secuencia con y sin eventos: el estado final es idéntico.
	var start: PlayerState = _state_at(Vector3(0.0, 0.0, 0.0), 0.0, true)
	var results: Array[PlayerState] = []
	var jumped_counts: Array[int] = []
	var landed_counts: Array[int] = []
	var apexes: Array[float] = []
	for enabled: bool in [false, true]:
		_character.events_enabled = enabled
		_character.set_state(start)
		_next_tick = 1
		_reset_counters()
		_step(Vector2.ZERO, 0.0, 0, 2)
		_step(Vector2(0.0, 1.0), 0.0, PlayerInput.JUMP)
		var apex: float = 0.0
		for _i: int in 90:
			_step(Vector2(0.0, 1.0), 0.0, 0)
			apex = maxf(apex, _character.global_position.y)
		results.append(_character.get_state())
		jumped_counts.append(_jumped_count)
		landed_counts.append(_landed_count)
		apexes.append(apex)
	_character.events_enabled = true
	assert_true(apexes[0] > 1.0 and apexes[1] > 1.0, "en los dos casos el personaje salta")
	assert_eq(jumped_counts[0], 0, "sin events_enabled no se emite jumped")
	assert_eq(landed_counts[0], 0, "sin events_enabled no se emite landed")
	assert_eq(jumped_counts[1], 1, "con events_enabled se emite jumped una vez")
	assert_eq(landed_counts[1], 1, "con events_enabled se emite landed una vez")
	assert_true(results[0].equals_exact(results[1]),
			"los eventos no cambian la simulación: %s frente a %s" % [results[0], results[1]])


# --- NetMath y EntityRecord -------------------------------------------------------------------

func test_position_quantization_in_five_km() -> void:
	assert_eq(NetMath.POSITION_BIAS, 524288, "sesgo de 2^19")
	assert_eq(NetMath.POSITION_MAX, 1048575, "máximo de 2^20 - 1")
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var worst: float = 0.0
	for _i: int in 2000:
		var position := Vector3(rng.randf_range(-5000.0, 5000.0), rng.randf_range(-5000.0, 5000.0),
				rng.randf_range(-5000.0, 5000.0))
		var packed: int = NetMath.pack_position(position)
		assert_eq(packed >> 60, 0, "los bits 60-63 quedan a 0")
		assert_true(packed >= 0, "el bit 63 nunca se usa")
		var error: float = NetMath.unpack_position(packed).distance_to(position)
		worst = maxf(worst, error)
		# En el cuantizador, el error es de medio centímetro como mucho.
		for axis: int in 3:
			var steps: int = ((packed >> (20 * axis)) & NetMath.POSITION_MAX) \
					- NetMath.POSITION_BIAS
			if absf(steps - position[axis] * 100.0) > QUANTIZER_HALF_STEP:
				fail("el eje %d de %s se cuantiza con más de 5 mm de error" % [axis, position])
				return
		var axis_error: Vector3 = (NetMath.unpack_position(packed) - position).abs()
		if axis_error.x > POSITION_ERROR or axis_error.y > POSITION_ERROR \
				or axis_error.z > POSITION_ERROR:
			fail("error de cuantización de %s mayor que 5 mm en %s" % [axis_error, position])
			return
	assert_true(worst > 0.0, "la cuantización no es exacta")

	# Disposición de los ejes: x en los bits 0-19, y en 20-39 y z en 40-59.
	var bias: int = 1 << 19
	var packed_axes: int = NetMath.pack_position(Vector3(1.0, 2.0, -3.0))
	assert_eq(packed_axes & 0xFFFFF, bias + 100, "x en los bits 0-19")
	assert_eq((packed_axes >> 20) & 0xFFFFF, bias + 200, "y en los bits 20-39")
	assert_eq((packed_axes >> 40) & 0xFFFFF, bias - 300, "z en los bits 40-59")
	assert_eq(NetMath.pack_position(Vector3.ZERO), bias | (bias << 20) | (bias << 40), "origen")
	assert_vec_near(NetMath.unpack_position(NetMath.pack_position(Vector3.ZERO)), Vector3.ZERO,
			0.0, "el origen es exacto")


func test_position_saturates_outside_range() -> void:
	# Los componentes de un Vector3 son f32: a 5 km no representan los milímetros.
	var top: float = 5242.87
	var bottom: float = -5242.88
	var tolerance: float = 5e-4
	var saturated: Vector3 = NetMath.unpack_position(NetMath.pack_position(
			Vector3(1.0e6, -1.0e6, 9999.0)))
	assert_near(saturated.x, top, tolerance, "x por encima del rango se satura arriba")
	assert_near(saturated.y, bottom, tolerance, "y por debajo del rango se satura abajo")
	assert_near(saturated.z, top, tolerance, "z por encima del rango se satura arriba")
	var infinite: Vector3 = NetMath.unpack_position(NetMath.pack_position(
			Vector3(INF, -INF, 0.0)))
	assert_near(infinite.x, top, tolerance, "+inf se satura")
	assert_near(infinite.y, bottom, tolerance, "-inf se satura")
	var broken: Vector3 = NetMath.unpack_position(NetMath.pack_position(Vector3(NAN, 1.0, NAN)))
	assert_vec_near(broken, Vector3(0.0, 1.0, 0.0), 1e-9, "un NaN cuenta como 0")
	assert_eq(NetMath.pack_position(Vector3(1.0e12, 1.0e12, 1.0e12)) >> 60, 0,
			"saturar nunca pisa los bits reservados")
	# Los bits reservados del paquete se ignoran al desempaquetar.
	var packed: int = NetMath.pack_position(Vector3(10.0, 20.0, 30.0))
	assert_vec_near(NetMath.unpack_position(packed | (0xF << 60)), Vector3(10.0, 20.0, 30.0),
			1e-9, "los bits 60-63 se ignoran")


func test_yaw_and_velocity_quantization() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for _i: int in 500:
		var yaw: float = rng.randf_range(-20.0, 20.0)
		var q: int = NetMath.quantize_yaw16(yaw)
		assert_true(q >= 0 and q <= 65535, "yaw cuantizado en 16 bits")
		var input := PlayerInput.new()
		input.look_yaw = yaw
		assert_eq(q, input.encode().decode_u16(6), "mismo yaw cuantizado que PlayerInput.look_yaw")
		var back: float = NetMath.dequantize_yaw16(q)
		assert_true(back >= 0.0 and back < TAU, "descuantizado en [0, TAU)")
		assert_true(absf(angle_difference(back, yaw)) <= TAU / 65536.0 / 2.0 + 1e-9,
				"error de yaw de media vuelta/65536 como mucho")
	assert_eq(NetMath.quantize_yaw16(0.0), 0, "yaw 0")
	assert_eq(NetMath.quantize_yaw16(TAU), 0, "TAU vuelve a 0")
	assert_eq(NetMath.quantize_yaw16(-0.0000001), 0, "un valor diminuto negativo redondea a 0")
	assert_eq(NetMath.quantize_yaw16(NAN), 0, "NaN da 0")
	assert_eq(NetMath.quantize_yaw16(INF), 0, "infinito da 0")
	assert_near(NetMath.dequantize_yaw16(32768), PI, 1e-9, "mitad de vuelta")

	assert_eq(NetMath.quantize_velocity(0.0), 0, "velocidad 0")
	assert_eq(NetMath.quantize_velocity(5.0), 500, "5 m/s son 500 cm/s")
	assert_eq(NetMath.quantize_velocity(-7.5), -750, "negativa")
	assert_eq(NetMath.quantize_velocity(400.0), 32767, "satura arriba a s16")
	assert_eq(NetMath.quantize_velocity(-400.0), -32768, "satura abajo a s16")
	assert_eq(NetMath.quantize_velocity(INF), 32767, "+inf satura")
	assert_eq(NetMath.quantize_velocity(-INF), -32768, "-inf satura")
	assert_eq(NetMath.quantize_velocity(NAN), 0, "NaN da 0")
	assert_near(NetMath.dequantize_velocity(32767), 327.67, 1e-9, "descuantizar el máximo")
	for _i: int in 200:
		var speed: float = rng.randf_range(-50.0, 50.0)
		var back: float = NetMath.dequantize_velocity(NetMath.quantize_velocity(speed))
		assert_near(back, speed, 0.005 + 1e-9, "error de velocidad de 5 mm/s como mucho")


func test_entity_record_roundtrip_and_layout() -> void:
	var record := EntityRecord.new()
	record.net_id = 0xABCD
	record.position = Vector3(-1234.567, 45.678, 4999.994)
	record.yaw = 5.5
	record.velocity = Vector3(7.5, -12.34, 400.0)
	record.flags = EntityRecord.FLAG_GROUNDED | (2 << EntityRecord.TELEPORT_SHIFT)
	record.action = 9
	assert_eq(record.health_q, EntityRecord.HEALTH_Q_FULL, "la vida cuantizada empieza llena")
	record.health_q = 137
	assert_eq(EntityRecord.SIZE, 21, "el registro es de 21 B")
	assert_true(record.is_grounded(), "grounded")
	assert_eq(record.get_teleport_counter(), 2, "contador de teletransporte")

	# Se escribe en mitad de un búfer más grande, sin tocar el resto.
	var bytes := PackedByteArray()
	bytes.resize(45)
	bytes.fill(0xEE)
	record.encode_into(bytes, 7)
	assert_eq(bytes.size(), 45, "no cambia el tamaño de un búfer que ya cabe")
	assert_eq(bytes[6], 0xEE, "no escribe antes del offset")
	assert_eq(bytes[28], 0xEE, "no escribe después de los 21 bytes")
	assert_eq(bytes.decode_u16(7), 0xABCD, "u16 net_id en +0")
	assert_eq(bytes.decode_u64(9), NetMath.pack_position(record.position), "u64 position en +2")
	assert_eq(bytes.decode_u16(17), NetMath.quantize_yaw16(5.5), "u16 yaw en +10")
	assert_eq(bytes.decode_s16(19), 750, "s16 velocity.x en +12")
	assert_eq(bytes.decode_s16(21), -1234, "s16 velocity.y en +14")
	assert_eq(bytes.decode_s16(23), 32767, "s16 velocity.z en +16, saturado")
	assert_eq(bytes.decode_u8(25), 0b101, "u8 flags en +18: grounded y contador 2")
	assert_eq(bytes.decode_u8(26), 9, "u8 action en +19")
	assert_eq(bytes.decode_u8(27), 137, "u8 health_q en +20")

	var decoded: EntityRecord = EntityRecord.decode_from(bytes, 7, NetProtocol.EntityKind.NPC)
	if not assert_not_null(decoded, "decode_from de 21 bytes"):
		return
	assert_eq(decoded.kind, NetProtocol.EntityKind.NPC, "el kind lo da quien decodifica")
	assert_eq(decoded.net_id, 0xABCD, "net_id")
	assert_vec_near(decoded.position, record.position, POSITION_ERROR * 2.0, "position")
	assert_true(absf(angle_difference(decoded.yaw, record.yaw)) < 6e-5, "yaw")
	assert_vec_near(decoded.velocity, Vector3(7.5, -12.34, 327.67), 1e-9, "velocity saturada")
	assert_eq(decoded.flags, record.flags, "flags")
	assert_eq(decoded.action, 9, "action")
	assert_eq(decoded.health_q, 137, "health_q")
	assert_null(EntityRecord.decode_from(bytes, 25, NetProtocol.EntityKind.PLAYER),
			"decode_from con menos de 21 bytes disponibles")
	assert_null(EntityRecord.decode_from(bytes, -1, NetProtocol.EntityKind.PLAYER),
			"offset negativo")

	# Un búfer vacío se amplía.
	var grown := PackedByteArray()
	record.encode_into(grown, 3)
	assert_eq(grown.size(), 24, "encode_into amplía el búfer")

	# La vida cuantizada se limita a un byte al escribirla.
	record.health_q = 999
	record.encode_into(grown, 3)
	assert_eq(grown.decode_u8(3 + 20), 255, "health_q > 255 se satura")
	record.health_q = -4
	record.encode_into(grown, 3)
	assert_eq(grown.decode_u8(3 + 20), 0, "health_q < 0 se queda en 0")


func test_quantize_health() -> void:
	# 0 = muerto; si no, techo de health · 255 / max con mínimo 1.
	assert_eq(EntityRecord.quantize_health(0, 1000), 0, "sin vida: 0")
	assert_eq(EntityRecord.quantize_health(-30, 1000), 0, "vida negativa: 0")
	assert_eq(EntityRecord.quantize_health(1000, 1000), 255, "vida llena: 255")
	assert_eq(EntityRecord.quantize_health(1500, 1000), 255, "por encima del máximo: 255")
	assert_eq(EntityRecord.quantize_health(1, 1000), 1, "con 1 de 1000 sigue vivo: 1")
	assert_eq(EntityRecord.quantize_health(500, 1000), 128, "mitad: 127,5 hacia arriba = 128")
	assert_eq(EntityRecord.quantize_health(100, 1000), 26, "10 %: 25,5 hacia arriba = 26")
	assert_eq(EntityRecord.quantize_health(750, 1000), 192, "75 %: 191,25 hacia arriba = 192")
	assert_eq(EntityRecord.quantize_health(997, 1000), 255, "997 de 1000: 254,2 hacia arriba = 255")
	assert_eq(EntityRecord.quantize_health(996, 1000), 254, "996 de 1000: 253,98 hacia arriba = 254")
	assert_eq(EntityRecord.quantize_health(255, 255), 255, "255 de 255")
	assert_eq(EntityRecord.quantize_health(5, 0), 0, "sin vida máxima cuenta como muerto")
	assert_eq(EntityRecord.quantize_health(65535, 65535), 255, "u16 máximo")
	# Nunca 0 mientras quede vida, y monótona.
	var previous: int = 0
	for health: int in range(0, 1001):
		var quantized: int = EntityRecord.quantize_health(health, 1000)
		assert_true(quantized >= previous, "monótona en %d" % health)
		assert_eq(quantized == 0, health == 0, "solo 0 cuando no queda vida (%d)" % health)
		previous = quantized
	assert_near(EntityRecord.health_fraction(255), 1.0, 1e-9, "fracción de 255")
	assert_near(EntityRecord.health_fraction(0), 0.0, 1e-9, "fracción de 0")
	assert_near(EntityRecord.health_fraction(51), 0.2, 1e-9, "fracción de 51")


func test_entity_record_from_state_and_character() -> void:
	if not await _make_world():
		return
	_character.global_position = Vector3(12.34, 5.67, -89.01)
	_character.yaw = 2.5
	_character.velocity = Vector3(3.0, -4.5, 6.25)
	_character.grounded = true
	var state: PlayerState = _character.get_state()

	var from_state: EntityRecord = EntityRecord.from_state(321, NetProtocol.EntityKind.PLAYER,
			state, 3)
	assert_eq(from_state.net_id, 321, "net_id")
	assert_eq(from_state.kind, NetProtocol.EntityKind.PLAYER, "kind")
	assert_vec_near(from_state.position, state.position, 0.0, "position")
	assert_eq(from_state.yaw, state.yaw, "yaw")
	assert_vec_near(from_state.velocity, state.velocity, 0.0, "velocity")
	assert_true(from_state.is_grounded(), "grounded")
	assert_eq(from_state.get_teleport_counter(), 3, "contador de teletransporte")
	assert_eq(EntityRecord.from_state(1, 1, state, 7).get_teleport_counter(), 3,
			"el contador es de 2 bits")
	assert_eq(from_state.health_q, EntityRecord.HEALTH_Q_FULL, "por defecto, la vida llena")
	assert_eq(EntityRecord.from_state(1, 1, state, 0, 77).health_q, 77, "from_state conserva health_q")

	# encode_character escribe lo mismo que from_state(...).encode_into(...).
	var expected := PackedByteArray()
	from_state.action = 4
	from_state.health_q = 200
	from_state.encode_into(expected, 5)
	var direct := PackedByteArray()
	direct.resize(26)
	EntityRecord.encode_character(direct, 5, 321, _character, 3, 4, 200)
	assert_eq(direct, expected, "encode_character coincide con from_state + encode_into")
	assert_eq(direct.decode_u8(5 + 20), 200, "health_q en +20")
	_character.grounded = false
	EntityRecord.encode_character(direct, 5, 321, _character, 6, 0, 0)
	assert_eq(direct.decode_u8(5 + 18), 0b100, "sin grounded y contador 6 mod 4 = 2")
	assert_eq(direct.decode_u8(5 + 20), 0, "health_q 0 = muerto")


func test_entity_record_interpolate() -> void:
	var a := EntityRecord.new()
	a.net_id = 5
	a.position = Vector3(0.0, 0.0, 0.0)
	a.velocity = Vector3(2.0, 0.0, 0.0)
	a.yaw = PI - 0.1
	a.flags = EntityRecord.FLAG_GROUNDED
	a.health_q = 200
	var b := EntityRecord.new()
	b.net_id = 5
	b.position = Vector3(10.0, 4.0, -2.0)
	b.velocity = Vector3(4.0, 0.0, 0.0)
	b.yaw = -PI + 0.1
	b.flags = 0
	b.health_q = 40
	var middle: EntityRecord = EntityRecord.interpolate(a, b, 0.5)
	assert_vec_near(middle.position, Vector3(5.0, 2.0, -1.0), 1e-9, "lerp de posición")
	assert_vec_near(middle.velocity, Vector3(3.0, 0.0, 0.0), 1e-9, "lerp de velocidad")
	assert_near(absf(angle_difference(middle.yaw, PI)), 0.0, 1e-9, "lerp_angle cruza ±PI")
	assert_eq(middle.net_id, 5, "net_id")
	assert_false(EntityRecord.interpolate(a, b, 0.75).is_grounded(), "flags del más cercano (b)")
	assert_true(EntityRecord.interpolate(a, b, 0.25).is_grounded(), "flags del más cercano (a)")
	assert_eq(EntityRecord.interpolate(a, b, 0.75).health_q, 40, "vida del más cercano (b)")
	assert_eq(EntityRecord.interpolate(a, b, 0.25).health_q, 200, "vida del más cercano (a)")
	assert_vec_near(EntityRecord.interpolate(a, b, 0.0).position, a.position, 1e-9, "t = 0")
	assert_vec_near(EntityRecord.interpolate(a, b, 1.0).position, b.position, 1e-9, "t = 1")


# --- NetProtocol ------------------------------------------------------------------------------

func test_protocol_constants_and_helpers() -> void:
	assert_eq(NetProtocol.PROTOCOL_VERSION, 7,
			"versión (4 el fuerte, 5 el chat y los grupos, 6 las habilidades, 7 la fase 5)")
	assert_eq(NetTransport.AUTH_TIMEOUT_SECONDS, 10.0, "auth_timeout de 10 s desde el protocolo 7")
	assert_eq(NetProtocol.MAGIC, 0x4D444C45, "magic")
	assert_eq(PackedByteArray([0x45, 0x4C, 0x44, 0x4D]).decode_u32(0), NetProtocol.MAGIC,
			"los bytes del magic leen «ELDM»")
	assert_eq(NetProtocol.VALID_BUTTONS, 0x1FFF, "botones válidos: bits 0-12 (protocolo 6)")
	assert_eq(NetProtocol.CUSTOM_CHANNELS, 3, "canales propios")
	assert_eq(NetProtocol.Realm.ASKARRA, 3, "códigos de reino")

	assert_eq(NetProtocol.channel_for_type(NetProtocol.MSG_INPUT_BATCH), NetProtocol.CH_INPUT,
			"canal de entradas")
	assert_eq(NetProtocol.channel_for_type(NetProtocol.MSG_SNAPSHOT), NetProtocol.CH_SNAPSHOT,
			"canal de snapshots")
	for msg_type: int in [NetProtocol.MSG_CLIENT_READY, NetProtocol.MSG_CLIENT_LEAVE,
			NetProtocol.MSG_DEBUG_COMMAND, NetProtocol.MSG_ENTITY_SPAWN,
			NetProtocol.MSG_ENTITY_DESPAWN, NetProtocol.MSG_OBJECT_STATE,
			NetProtocol.MSG_ENTITY_EVENT, NetProtocol.MSG_NOTICE, NetProtocol.MSG_HANDOFF,
			NetProtocol.MSG_UNSTUCK_REQUEST, NetProtocol.MSG_SCOREBOARD, NetProtocol.MSG_LOADOUT_SELECT,
			0x7F]:
		assert_eq(NetProtocol.channel_for_type(msg_type), NetProtocol.CH_RELIABLE,
				"el tipo 0x%02X va por el canal fiable" % msg_type)

	assert_eq(NetProtocol.transfer_mode(NetProtocol.CH_INPUT),
			MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, "modo de CH_INPUT")
	assert_eq(NetProtocol.transfer_mode(NetProtocol.CH_SNAPSHOT),
			MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, "modo de CH_SNAPSHOT")
	assert_eq(NetProtocol.transfer_mode(NetProtocol.CH_RELIABLE),
			MultiplayerPeer.TRANSFER_MODE_RELIABLE, "modo de CH_RELIABLE")
	assert_true(NetProtocol.is_unreliable_channel(NetProtocol.CH_INPUT), "CH_INPUT pierde paquetes")
	assert_true(NetProtocol.is_unreliable_channel(NetProtocol.CH_SNAPSHOT),
			"CH_SNAPSHOT pierde paquetes")
	assert_false(NetProtocol.is_unreliable_channel(NetProtocol.CH_RELIABLE), "CH_RELIABLE no")

	assert_eq(NetProtocol.realm_display_name(NetProtocol.Realm.VARDHEIM), "Vardheim", "Vardheim")
	assert_eq(NetProtocol.realm_display_name(NetProtocol.Realm.SOLMARCH), "Solmarch", "Solmarch")
	assert_eq(NetProtocol.realm_display_name(NetProtocol.Realm.ASKARRA), "Askarra", "Askarra")
	for result: int in range(0, 13):
		assert_false(NetProtocol.result_text(result).is_empty(), "texto del resultado %d" % result)
	assert_false(NetProtocol.result_text(99).is_empty(), "texto de un resultado desconocido")
	assert_true(NetProtocol.result_text(NetProtocol.Result.NAME)
			!= NetProtocol.result_text(NetProtocol.Result.FULL), "los motivos se distinguen")


func test_neutral_input_is_quantized() -> void:
	for yaw: float in [0.0, 1.2345, -2.5, 7.0, TAU]:
		var neutral: PlayerInput = NetProtocol.neutral_input(77, yaw)
		assert_eq(neutral.tick, 77, "tick")
		assert_eq(neutral.move, Vector2.ZERO, "sin movimiento")
		assert_eq(neutral.buttons, 0, "sin botones")
		assert_eq(neutral.look_pitch, 0.0, "pitch 0")
		assert_eq(neutral.look_yaw, NetMath.dequantize_yaw16(NetMath.quantize_yaw16(yaw)),
				"look_yaw es el yaw cuantizado")
		assert_true(_inputs_equal(neutral, neutral.quantized()), "ya está cuantizada")


func test_sim_hash_depends_on_simulation_parameters() -> void:
	if not await _make_world():
		return
	var hash_a: int = NetProtocol.compute_sim_hash(_character)
	assert_true(hash_a >= 0 and hash_a <= 0xFFFFFFFF, "es un u32")
	assert_eq(NetProtocol.compute_sim_hash(_character), hash_a, "es estable")

	var second: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() \
			as PlayerCharacter
	_world.add_child(second)
	assert_eq(NetProtocol.compute_sim_hash(second), hash_a, "dos instancias iguales dan lo mismo")

	# El estado de la simulación no cuenta; los parámetros, sí.
	second.yaw = 2.0
	second.grounded = true
	second.global_position = Vector3(3.0, 1.0, 2.0)
	assert_eq(NetProtocol.compute_sim_hash(second), hash_a, "el estado no entra en el hash")
	second.run_speed += 0.5
	assert_true(NetProtocol.compute_sim_hash(second) != hash_a,
			"un @export distinto cambia el hash")
	second.run_speed -= 0.5
	assert_eq(NetProtocol.compute_sim_hash(second), hash_a, "y al restaurarlo vuelve")
	second.floor_snap_length = 0.5
	assert_true(NetProtocol.compute_sim_hash(second) != hash_a,
			"un floor_* distinto cambia el hash")
	second.floor_snap_length = _character.floor_snap_length
	var collision: CollisionShape3D = second.get_node(^"Collision") as CollisionShape3D
	collision.position.y += 0.1
	assert_true(NetProtocol.compute_sim_hash(second) != hash_a,
			"la posición de la cápsula cambia el hash")
	second.get_parent().remove_child(second)
	second.free()


# --- NetZones ---------------------------------------------------------------------------------

func test_net_zones_uses_the_zone_registry() -> void:
	assert_eq(NetZones.default_zone_id(), "vado_gris", "la zona por defecto es el Vado Gris")
	assert_eq(NetZones.scene_path("vado_gris"), "res://scenes/world/zones/vado_gris/vado_gris.tscn",
			"ruta de la escena del Vado Gris")
	assert_eq(NetZones.scene_path("test_world"), "res://scenes/world/test_world.tscn",
			"ruta del circuito de pruebas")
	assert_eq(NetZones.scene_path("atlantida"), "", "una zona inventada no tiene escena")
	assert_eq(NetZones.scene_path(""), "", "sin id no hay escena")
	assert_true(NetZones.default_zone_id().length() <= NetProtocol.MAX_ZONE_ID_BYTES,
			"el id cabe en el WELCOME")
	assert_eq(NetZones.allowed_realms("vado_gris"),
			PackedInt32Array([NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH]),
			"el Vado Gris admite Vardheim y Solmarch (RealmCatalog)")
	assert_true(NetZones.allowed_realms("atlantida").is_empty(),
			"vacío = todos los reinos para zonas desconocidas")


func test_net_zones_realm_codes() -> void:
	assert_eq(NetZones.realm_from_name("vardheim"), NetProtocol.Realm.VARDHEIM, "vardheim")
	assert_eq(NetZones.realm_from_name("solmarch"), NetProtocol.Realm.SOLMARCH, "solmarch")
	assert_eq(NetZones.realm_from_name("askarra"), NetProtocol.Realm.ASKARRA, "askarra")
	assert_eq(NetZones.realm_from_name("  Solmarch "), NetProtocol.Realm.SOLMARCH,
			"sin distinguir mayúsculas ni espacios")
	assert_eq(NetZones.realm_from_name("\"ASKARRA\""), NetProtocol.Realm.ASKARRA, "con comillas")
	assert_eq(NetZones.realm_from_name("mordor"), NetProtocol.Realm.NONE, "reino inventado")
	assert_eq(NetZones.realm_from_name(""), NetProtocol.Realm.NONE, "vacío")
	for realm: int in [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH,
			NetProtocol.Realm.ASKARRA]:
		var zone_name: StringName = NetZones.realm_name(realm)
		assert_true(Zones.is_realm(zone_name), "realm_name(%d) es un reino de Zones" % realm)
		assert_eq(NetZones.realm_from_name(String(zone_name)), realm,
				"ida y vuelta del reino %d" % realm)
	assert_eq(NetZones.realm_name(NetProtocol.Realm.NONE), &"", "ningún reino")
	assert_eq(NetZones.realm_name(9), &"", "código inválido")
	assert_null(NetZones.find_spawn_point(null, NetProtocol.Realm.VARDHEIM),
			"sin zona no hay punto")


func test_net_zones_parses_arguments() -> void:
	assert_eq(NetZones.parse_zone_arg(PackedStringArray(["--zone=test_world"])), "test_world",
			"--zone=x")
	assert_eq(NetZones.parse_zone_arg(PackedStringArray(["--server", "--port=1", "--zone=vado_gris",
			"--realm=solmarch"])), "vado_gris", "entre otros argumentos")
	assert_eq(NetZones.parse_zone_arg(PackedStringArray(["--zone= \"Vado_Gris\" "])), "vado_gris",
			"sin comillas ni espacios y en minúsculas")
	assert_eq(NetZones.parse_zone_arg(PackedStringArray(["--server"])), "", "sin --zone")
	assert_eq(NetZones.parse_zone_arg(PackedStringArray()), "", "sin argumentos")
	assert_eq(NetZones.parse_zone_arg(PackedStringArray(["--zone="])), "", "--zone vacío")
	assert_eq(NetZones.parse_zone_arg(PackedStringArray(["--zones=x"])), "", "otro argumento")
	assert_eq(NetZones.parse_zone_arg(PackedStringArray(["--zone=atlantida"])), "atlantida",
			"no valida que exista")

	assert_eq(NetZones.parse_realm_arg(PackedStringArray(["--realm=solmarch"])),
			NetProtocol.Realm.SOLMARCH, "--realm=y")
	assert_eq(NetZones.parse_realm_arg(PackedStringArray(["--connect=127.0.0.1",
			"--realm=Askarra"])), NetProtocol.Realm.ASKARRA,
			"entre otros argumentos y con mayúsculas")
	assert_eq(NetZones.parse_realm_arg(PackedStringArray(["--connect=127.0.0.1"])),
			NetProtocol.Realm.NONE, "sin --realm")
	assert_eq(NetZones.parse_realm_arg(PackedStringArray()), NetProtocol.Realm.NONE,
			"sin argumentos")
	assert_eq(NetZones.parse_realm_arg(PackedStringArray(["--realm=mordor"])),
			NetProtocol.Realm.NONE, "reino desconocido")


# --- BotBrain ---------------------------------------------------------------------------------

func test_bot_brain_is_deterministic_with_seed() -> void:
	for pattern: BotBrain.Pattern in [BotBrain.Pattern.WANDER, BotBrain.Pattern.CIRCLE,
			BotBrain.Pattern.JUMPY]:
		var home := Vector3(10.0, 0.0, -5.0)
		var a := BotBrain.new(1234, pattern, home, 20.0)
		var b := BotBrain.new(1234, pattern, home, 20.0)
		var other := BotBrain.new(1235, pattern, home, 20.0)
		var position_a: Vector3 = home
		var position_b: Vector3 = home
		var position_other: Vector3 = home
		var differs: bool = false
		for tick: int in range(1, 1801):
			var input_a: PlayerInput = a.next_input(tick, position_a, 0.0)
			var input_b: PlayerInput = b.next_input(tick, position_b, 0.0)
			if not _inputs_equal(input_a, input_b):
				fail("patrón %d: la misma semilla dio entradas distintas en el tick %d: %s y %s"
						% [pattern, tick, input_a, input_b])
				return
			var input_other: PlayerInput = other.next_input(tick, position_other, 0.0)
			differs = differs or not _inputs_equal(input_a, input_other)
			position_a = _walk(position_a, input_a)
			position_b = _walk(position_b, input_b)
			position_other = _walk(position_other, input_other)
		assert_true(differs or pattern == BotBrain.Pattern.CIRCLE,
				"patrón %d: otra semilla da otra secuencia" % pattern)
		assert_vec_near(position_a, position_b, 0.0, "mismo recorrido")


func test_bot_brain_inputs_are_valid() -> void:
	var brain := BotBrain.new(9, BotBrain.Pattern.JUMPY, Vector3.ZERO, 15.0)
	var position: Vector3 = Vector3.ZERO
	for tick: int in range(1, 2001):
		var input: PlayerInput = brain.next_input(tick, position, 0.5)
		assert_eq(input.tick, tick, "el tick es el pedido")
		assert_true(input.move.length() <= 1.0 + 1e-6, "movimiento de longitud <= 1")
		assert_true(input.look_yaw >= 0.0 and input.look_yaw < TAU, "look_yaw en [0, TAU)")
		assert_eq(input.buttons & ~(PlayerInput.JUMP | PlayerInput.SPRINT), 0,
				"solo salta y esprinta")
		position = _walk(position, input)


func test_bot_brain_returns_home_when_outside_radius() -> void:
	var directions: Array[Vector3] = [
		Vector3(50.0, 0.0, 0.0), Vector3(-30.0, 3.0, 40.0), Vector3(0.0, 0.0, -80.0),
		Vector3(0.0, 0.0, 25.0), Vector3(17.0, 0.0, 17.0),
	]
	for pattern: BotBrain.Pattern in [BotBrain.Pattern.WANDER, BotBrain.Pattern.JUMPY,
			BotBrain.Pattern.CIRCLE]:
		for offset: Vector3 in directions:
			var home := Vector3(4.0, 0.0, -6.0)
			var brain := BotBrain.new(77, pattern, home, 10.0)
			var position: Vector3 = home + offset
			var input: PlayerInput = brain.next_input(5, position, 0.0)
			var forward: Vector3 = Basis(Vector3.UP, input.look_yaw) * Vector3.FORWARD
			var to_home: Vector3 = home - position
			to_home.y = 0.0
			assert_true(forward.dot(to_home.normalized()) > 0.999,
					"patrón %d desde %s: mira hacia home (%s)" % [pattern, offset, forward])
			assert_true(input.move.y > 0.9, "y avanza hacia delante")
			assert_near(input.move.x, 0.0, 1e-9, "sin movimiento lateral")


func test_bot_brain_stays_within_radius() -> void:
	for pattern: BotBrain.Pattern in [BotBrain.Pattern.WANDER, BotBrain.Pattern.JUMPY,
			BotBrain.Pattern.CIRCLE]:
		var home := Vector3(100.0, 0.0, 100.0)
		var radius: float = 12.0
		var brain := BotBrain.new(2024, pattern, home, radius)
		var position: Vector3 = home
		var farthest: float = 0.0
		for tick: int in range(1, 9001):
			position = _walk(position, brain.next_input(tick, position, 0.0))
			farthest = maxf(farthest, Vector2(position.x - home.x, position.z - home.z).length())
		assert_true(farthest <= radius + 1.0,
				"patrón %d: no se aleja más del radio (llegó a %.2f m)" % [pattern, farthest])
		assert_true(farthest > 2.0, "patrón %d: se mueve (llegó a %.2f m)" % [pattern, farthest])


func test_bot_brain_wander_changes_direction_and_jumps() -> void:
	var wander := BotBrain.new(31, BotBrain.Pattern.WANDER, Vector3.ZERO, 100000.0)
	var jumpy := BotBrain.new(31, BotBrain.Pattern.JUMPY, Vector3.ZERO, 100000.0)
	var change_ticks: Array[int] = []
	var previous_yaw: float = -1.0
	var sprint_ticks: int = 0
	var paused_ticks: int = 0
	var jump_presses: Array[int] = [0, 0]
	var previous_jump: Array[bool] = [false, false]
	var position: Vector3 = Vector3.ZERO
	for tick: int in range(1, 6001):
		var input: PlayerInput = wander.next_input(tick, position, 0.0)
		if input.look_yaw != previous_yaw:
			change_ticks.append(tick)
			previous_yaw = input.look_yaw
		if input.has(PlayerInput.SPRINT):
			sprint_ticks += 1
		if input.move == Vector2.ZERO:
			paused_ticks += 1
		var jumping: Array[bool] = [input.has(PlayerInput.JUMP),
				jumpy.next_input(tick, position, 0.0).has(PlayerInput.JUMP)]
		if input.has(PlayerInput.JUMP) and not previous_jump[0]:
			jump_presses[0] += 1
		if jumping[1] and not previous_jump[1]:
			jump_presses[1] += 1
		previous_jump[0] = input.has(PlayerInput.JUMP)
		previous_jump[1] = jumping[1]
		position = _walk(position, input)
	assert_true(change_ticks.size() >= 30,
			"cambia de dirección con frecuencia (%d veces)" % change_ticks.size())
	for i: int in range(1, change_ticks.size()):
		var gap: int = change_ticks[i] - change_ticks[i - 1]
		if gap < BotBrain.SEGMENT_MIN_TICKS or gap > BotBrain.SEGMENT_MAX_TICKS:
			fail("los cambios de dirección van cada 60-180 ticks (hubo uno de %d)" % gap)
			break
	assert_true(sprint_ticks > 0, "esprinta a veces")
	assert_true(sprint_ticks < 3000, "pero no siempre")
	assert_true(paused_ticks > 0, "a veces se para")
	assert_true(jump_presses[0] > 0, "salta a veces")
	assert_true(jump_presses[1] > jump_presses[0] * 3, "JUMPY salta mucho más (%d frente a %d)" % [
		jump_presses[1], jump_presses[0]])


func test_bot_brain_circle_goes_around_home() -> void:
	var home := Vector3(-20.0, 0.0, 30.0)
	var brain := BotBrain.new(5, BotBrain.Pattern.CIRCLE, home, 20.0)
	var position: Vector3 = home
	var swept: float = 0.0
	var previous_angle: float = 0.0
	var closest: float = INF
	var farthest: float = 0.0
	for tick: int in range(1, 3001):
		position = _walk(position, brain.next_input(tick, position, 1.0))
		var offset := Vector2(position.x - home.x, position.z - home.z)
		var angle: float = offset.angle()
		if tick > 400:
			swept += absf(angle_difference(previous_angle, angle))
			closest = minf(closest, offset.length())
			farthest = maxf(farthest, offset.length())
		previous_angle = angle
	assert_true(swept > TAU * 2.0, "da varias vueltas (%.1f rad)" % swept)
	assert_true(closest > 5.0 and farthest < 15.0,
			"gira a media distancia del radio (entre %.1f y %.1f m)" % [closest, farthest])


func test_bot_brain_idle_and_set_idle_from() -> void:
	var idle := BotBrain.new(1, BotBrain.Pattern.IDLE)
	for tick: int in range(1, 100):
		var input: PlayerInput = idle.next_input(tick, Vector3(5.0, 0.0, 5.0), 1.75)
		assert_eq(input.tick, tick, "tick")
		assert_eq(input.move, Vector2.ZERO, "IDLE no se mueve")
		assert_eq(input.buttons, 0, "IDLE no pulsa nada")
		assert_eq(input.look_yaw, 1.75, "IDLE mira al yaw actual")
		assert_eq(input.look_pitch, 0.0, "IDLE pitch 0")

	var brain := BotBrain.new(3, BotBrain.Pattern.WANDER, Vector3.ZERO, 50.0)
	brain.set_idle_from(300)
	var moved_before: bool = false
	var position: Vector3 = Vector3.ZERO
	for tick: int in range(1, 700):
		var input: PlayerInput = brain.next_input(tick, position, 0.25)
		if tick < 300:
			moved_before = moved_before or input.move != Vector2.ZERO
			position = _walk(position, input)
		else:
			if input.move != Vector2.ZERO or input.buttons != 0 or input.look_yaw != 0.25:
				fail("desde el tick 300 solo hay entradas neutras (tick %d: %s)" % [tick, input])
				return
	assert_true(moved_before, "antes del tick 300 se mueve")


# --- NetMessages: formatos --------------------------------------------------------------------

func test_peek_helpers() -> void:
	assert_eq(NetMessages.peek_type(PackedByteArray()), -1, "búfer vacío")
	assert_eq(NetMessages.peek_type(PackedByteArray([0x10, 1, 2])), 0x10, "byte 0")
	assert_eq(NetMessages.peek_type(NetMessages.ClientReady.new().encode()),
			NetProtocol.MSG_CLIENT_READY, "tipo de CLIENT_READY")
	assert_eq(NetMessages.peek_auth_result(PackedByteArray()), -1, "vacío no tiene magic")
	assert_eq(NetMessages.peek_auth_result(PackedByteArray([0x45, 0x4C, 0x44])), -1,
			"demasiado corto")
	assert_eq(NetMessages.peek_auth_result(_sample_hello().encode().slice(1)), -1, "sin magic")
	assert_eq(NetMessages.peek_auth_result(_sample_welcome().encode()), 0, "WELCOME es 0")
	var reject: NetMessages.Reject = _sample_reject()
	assert_eq(NetMessages.peek_auth_result(reject.encode()), NetProtocol.Result.REALM,
			"REJECT trae su motivo")
	assert_eq(NetMessages.peek_auth_result(PackedByteArray([0x45, 0x4C, 0x44, 0x4D, 5])), 5,
			"basta con 5 bytes")


func test_hello_roundtrip_and_layout() -> void:
	var hello: NetMessages.Hello = _sample_hello()
	var bytes: PackedByteArray = hello.encode()
	var name_bytes: PackedByteArray = hello.display_name.to_utf8_buffer()
	assert_true(name_bytes.size() > hello.display_name.length(),
			"el nombre de prueba tiene caracteres multibyte")
	var ticket_size: int = hello.ticket.size()
	assert_eq(bytes.size(), 23 + name_bytes.size() + ticket_size,
			"tamaño: 23 B + nombre + billete")
	assert_eq(bytes.decode_u32(0), 0x4D444C45, "u32 magic en 0")
	assert_eq(bytes.decode_u16(4), NetProtocol.PROTOCOL_VERSION, "u16 protocol_version en 4")
	assert_eq(bytes.decode_u32(6), 0xDEADBEEF, "u32 sim_hash en 6")
	assert_eq(bytes.decode_u8(10), NetProtocol.Realm.SOLMARCH, "u8 realm en 10")
	assert_eq(bytes.decode_u8(11), 1, "u8 flags en 11 (bit 0 = bot)")
	assert_eq(bytes.decode_u64(12), 0x0123456789ABCDEF, "u64 character_id en 12")
	assert_eq(bytes.decode_u8(20), name_bytes.size(), "u8 name_len en 20")
	assert_eq(bytes.slice(21, 21 + name_bytes.size()), name_bytes, "nombre UTF-8 en 21")
	var ticket_offset: int = 21 + name_bytes.size()
	assert_eq(bytes.decode_u16(ticket_offset), ticket_size, "u16 ticket_len en 21+n")
	assert_eq(bytes.slice(ticket_offset + 2), hello.ticket, "billete en 23+n")

	var decoded: NetMessages.Hello = NetMessages.Hello.decode(bytes)
	if not assert_not_null(decoded, "decode del HELLO"):
		return
	assert_eq(decoded.protocol_version, NetProtocol.PROTOCOL_VERSION, "protocol_version")
	assert_eq(decoded.sim_hash, 0xDEADBEEF, "sim_hash")
	assert_eq(decoded.realm, NetProtocol.Realm.SOLMARCH, "realm")
	assert_eq(decoded.flags, 1, "flags")
	assert_true(decoded.is_bot(), "bit de bot")
	assert_eq(decoded.character_id, 0x0123456789ABCDEF, "character_id")
	assert_eq(decoded.display_name, hello.display_name, "nombre con acentos")
	assert_eq(decoded.ticket, hello.ticket, "billete")

	# Mínimo: nombre y billete vacíos.
	var minimal := NetMessages.Hello.new()
	var minimal_bytes: PackedByteArray = minimal.encode()
	assert_eq(minimal_bytes.size(), 23, "HELLO mínimo de 23 B")
	var minimal_decoded: NetMessages.Hello = NetMessages.Hello.decode(minimal_bytes)
	if assert_not_null(minimal_decoded, "decode del HELLO mínimo"):
		assert_eq(minimal_decoded.display_name, "", "nombre vacío")
		assert_true(minimal_decoded.ticket.is_empty(), "sin billete")
		assert_false(minimal_decoded.is_bot(), "no es un bot")

	# Los textos largos se recortan a su máximo sin partir caracteres.
	var long_hello := NetMessages.Hello.new()
	long_hello.display_name = "ñ".repeat(40)
	long_hello.ticket.resize(300)
	var long_decoded: NetMessages.Hello = NetMessages.Hello.decode(long_hello.encode())
	if assert_not_null(long_decoded, "decode de un HELLO con textos largos"):
		assert_eq(long_decoded.display_name, "ñ".repeat(24), "48 B son 24 caracteres de 2 B")
		assert_eq(long_decoded.ticket.size(), NetProtocol.MAX_TICKET_BYTES,
				"billete recortado a 256")
	long_hello.display_name = "ñ".repeat(23) + "€"
	assert_eq(NetMessages.Hello.decode(long_hello.encode()).display_name, "ñ".repeat(23),
			"el carácter de 3 B que no cabe se descarta entero")


func test_welcome_roundtrip_and_layout() -> void:
	var welcome: NetMessages.Welcome = _sample_welcome()
	var bytes: PackedByteArray = welcome.encode()
	assert_eq(bytes.size(), 18 + "vado_gris".length() + 3,
			"tamaño: 18 B + id de zona + 3 B del recuento por reino")
	assert_eq(bytes.decode_u32(0), 0x4D444C45, "u32 magic en 0")
	assert_eq(bytes.decode_u8(4), 0, "u8 result en 4 (0 = aceptado)")
	assert_eq(bytes.decode_u16(5), NetProtocol.PROTOCOL_VERSION, "u16 protocol_version en 5")
	assert_eq(bytes.decode_u32(7), 123456, "u32 server_tick en 7")
	assert_eq(bytes.decode_u8(11), 60, "u8 tick_rate en 11")
	assert_eq(bytes.decode_u8(12), 2, "u8 snapshot_interval en 12")
	assert_eq(bytes.decode_u8(13), 8, "u8 max_input_batch en 13")
	assert_eq(bytes.decode_u8(14), 24, "u8 max_rewind_ticks en 14")
	assert_eq(bytes.decode_u8(15), NetProtocol.Realm.ASKARRA, "u8 realm en 15")
	assert_eq(bytes.decode_u8(16), 0, "u8 channel en 16")
	assert_eq(bytes.decode_u8(17), 9, "u8 zone_len en 17")
	assert_eq(bytes.slice(18, 18 + 9).get_string_from_ascii(), "vado_gris", "zone_id en 18")
	assert_eq(bytes.slice(18 + 9), PackedByteArray([4, 0, 255]), "u8 × 3 con el recuento por reino")

	var decoded: NetMessages.Welcome = NetMessages.Welcome.decode(bytes)
	if not assert_not_null(decoded, "decode del WELCOME"):
		return
	assert_eq(decoded.protocol_version, NetProtocol.PROTOCOL_VERSION, "protocol_version")
	assert_eq(decoded.server_tick, 123456, "server_tick")
	assert_eq(decoded.tick_rate, 60, "tick_rate")
	assert_eq(decoded.snapshot_interval, 2, "snapshot_interval")
	assert_eq(decoded.max_input_batch, 8, "max_input_batch")
	assert_eq(decoded.max_rewind_ticks, 24, "max_rewind_ticks")
	assert_eq(decoded.realm, NetProtocol.Realm.ASKARRA, "realm")
	assert_eq(decoded.channel, 0, "channel")
	assert_eq(decoded.zone_id, "vado_gris", "zone_id")
	assert_eq(decoded.realm_counts, PackedInt32Array([4, 0, 255]), "recuento por reino")
	assert_eq(decoded.get_realm_count(NetProtocol.Realm.VARDHEIM), 4, "Vardheim")
	assert_eq(decoded.get_realm_count(NetProtocol.Realm.SOLMARCH), 0, "Solmarch")
	assert_eq(decoded.get_realm_count(NetProtocol.Realm.ASKARRA), 255, "Askarra")
	assert_eq(decoded.get_realm_count(NetProtocol.Realm.NONE), 0, "sin reino")

	var defaults := NetMessages.Welcome.new()
	assert_eq(defaults.tick_rate, 60, "tick_rate por defecto")
	assert_eq(defaults.snapshot_interval, NetProtocol.SNAPSHOT_INTERVAL_TICKS,
			"intervalo por defecto")
	assert_eq(defaults.max_input_batch, NetProtocol.MAX_INPUTS_PER_BATCH, "lote por defecto")
	assert_eq(defaults.max_rewind_ticks, NetProtocol.MAX_REWIND_TICKS, "rebobinado por defecto")
	assert_eq(defaults.encode().size(), 21, "WELCOME con zona vacía: 18 B + el recuento")
	assert_eq(defaults.realm_counts, PackedInt32Array([0, 0, 0]), "recuento por defecto a 0")

	var long_zone := NetMessages.Welcome.new()
	long_zone.zone_id = "z".repeat(50)
	assert_eq(NetMessages.Welcome.decode(long_zone.encode()).zone_id.length(), 32,
			"el id de zona se recorta a 32 B")
	var tick_wrap := NetMessages.Welcome.new()
	tick_wrap.server_tick = 0xFFFFFFFF
	assert_eq(NetMessages.Welcome.decode(tick_wrap.encode()).server_tick, 0xFFFFFFFF,
			"tick u32 máximo")


func test_reject_roundtrip_and_layout() -> void:
	var reject: NetMessages.Reject = _sample_reject()
	var bytes: PackedByteArray = reject.encode()
	var text_bytes: PackedByteArray = reject.text.to_utf8_buffer()
	assert_eq(bytes.size(), 6 + text_bytes.size(), "tamaño: 6 B + texto")
	assert_eq(bytes.decode_u32(0), 0x4D444C45, "u32 magic en 0")
	assert_eq(bytes.decode_u8(4), 3, "u8 result en 4 (REALM = 3)")
	assert_eq(bytes.decode_u8(5), text_bytes.size(), "u8 text_len en 5")
	assert_eq(bytes.slice(6), text_bytes, "texto UTF-8 en 6")
	var decoded: NetMessages.Reject = NetMessages.Reject.decode(bytes)
	if assert_not_null(decoded, "decode del REJECT"):
		assert_eq(decoded.result, NetProtocol.Result.REALM, "result")
		assert_eq(decoded.text, reject.text, "texto en español")

	for result: int in range(1, 13):
		var each := NetMessages.Reject.new()
		each.result = result
		each.text = NetProtocol.result_text(result)
		var back: NetMessages.Reject = NetMessages.Reject.decode(each.encode())
		if assert_not_null(back, "REJECT con el motivo %d" % result):
			assert_eq(back.result, result, "motivo %d" % result)
			assert_eq(back.text, each.text, "texto del motivo %d" % result)
	var empty := NetMessages.Reject.new()
	assert_eq(empty.encode().size(), 6, "REJECT sin texto: 6 B")
	assert_eq(NetMessages.Reject.decode(empty.encode()).text, "", "texto vacío")


## Los REJECT del protocolo 7 (docs/plataforma.md §5.4): BUSY 10, UNAVAILABLE 11 y BANNED 12, con sus textos y,
## en BANNED, el que compone la plataforma (cortado en un carácter entero a 255 B).
func test_reject_10_to_12_of_protocol_7() -> void:
	assert_eq([NetProtocol.Result.BUSY, NetProtocol.Result.UNAVAILABLE, NetProtocol.Result.BANNED], [10, 11, 12],
			"códigos 10, 11 y 12")
	assert_eq(NetProtocol.result_text(NetProtocol.Result.BUSY),
			"Tu personaje sigue en el mundo: espera unos segundos", "texto de BUSY")
	assert_eq(NetProtocol.result_text(NetProtocol.Result.UNAVAILABLE),
			"El servicio de cuentas no responde: inténtalo más tarde", "texto de UNAVAILABLE")
	assert_eq(NetProtocol.result_text(NetProtocol.Result.BANNED), "Tu cuenta está suspendida",
			"texto de BANNED si falta el de la plataforma")
	var banned := NetMessages.Reject.new()
	banned.result = NetProtocol.Result.BANNED
	banned.text = "Tu cuenta está suspendida hasta el 3/11/2026 18:00 UTC: " + "ñ".repeat(200)
	var bytes: PackedByteArray = banned.encode()
	assert_eq(bytes.decode_u8(4), 12, "u8 result en 4")
	assert_true(bytes.size() <= 6 + 255, "el texto cabe en el u8 text_len")
	var back: NetMessages.Reject = NetMessages.Reject.decode(bytes)
	if assert_not_null(back, "decode del REJECT BANNED"):
		assert_eq(back.result, NetProtocol.Result.BANNED, "BANNED")
		assert_true(banned.text.begins_with(back.text) and back.text.ends_with("ñ"),
				"el texto se corta en un carácter entero")


func test_input_batch_roundtrip_and_layout() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 314
	for count: int in range(1, 9):
		var batch := NetMessages.InputBatch.new()
		batch.ack_snapshot_tick = 4000 + count
		batch.interp_delay_q = 90 + count
		batch.newest_tick = 1000 + count
		for i: int in count:
			batch.inputs.append(_random_input(rng, batch.newest_tick - count + 1 + i))
			batch.view_offsets_q.append(rng.randi_range(0, 65535))
		var bytes: PackedByteArray = batch.encode()
		assert_eq(bytes.size(), 11 + 10 * count, "tamaño: 11 + 10·n con n = %d" % count)
		assert_eq(bytes.decode_u8(0), 0x01, "u8 type en 0")
		assert_eq(bytes.decode_u32(1), 4000 + count, "u32 ack_snapshot_tick en 1")
		assert_eq(bytes.decode_u8(5), 90 + count, "u8 interp_delay_q en 5")
		assert_eq(bytes.decode_u32(6), 1000 + count, "u32 newest_tick en 6")
		assert_eq(bytes.decode_u8(10), count, "u8 count en 10")
		for i: int in count:
			var offset: int = 11 + 10 * i
			var full: PackedByteArray = batch.inputs[i].encode()
			assert_eq(bytes.decode_s8(offset), full.decode_s8(4), "s8 move.x en +0")
			assert_eq(bytes.decode_s8(offset + 1), full.decode_s8(5), "s8 move.y en +1")
			assert_eq(bytes.decode_u16(offset + 2), full.decode_u16(6), "u16 look_yaw en +2")
			assert_eq(bytes.decode_s16(offset + 4), full.decode_s16(8), "s16 look_pitch en +4")
			assert_eq(bytes.decode_u16(offset + 6), full.decode_u16(10), "u16 buttons en +6")
			assert_eq(bytes.decode_u16(offset + 8), batch.view_offsets_q[i],
					"u16 view_offset_q en +8")

		var decoded: NetMessages.InputBatch = NetMessages.InputBatch.decode(bytes)
		if not assert_not_null(decoded, "decode del lote de %d" % count):
			continue
		assert_eq(decoded.ack_snapshot_tick, 4000 + count, "ack_snapshot_tick")
		assert_eq(decoded.interp_delay_q, 90 + count, "interp_delay_q")
		assert_eq(decoded.newest_tick, 1000 + count, "newest_tick")
		assert_eq(decoded.inputs.size(), count, "número de entradas")
		assert_eq(decoded.view_offsets_q, batch.view_offsets_q, "view_offset_q de cada entrada")
		for i: int in count:
			var expected: PlayerInput = batch.inputs[i].quantized()
			expected.buttons &= NetProtocol.VALID_BUTTONS
			if not _inputs_equal(decoded.inputs[i], expected):
				fail("entrada %d de %d: se esperaba %s, se obtuvo %s" % [
					i, count, expected, decoded.inputs[i]])


func test_input_batch_decodes_quantized_inputs_with_button_mask() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2718
	var batch := NetMessages.InputBatch.new()
	batch.newest_tick = 600
	for i: int in 8:
		var input: PlayerInput = _random_input(rng, 593 + i)
		input.buttons = 0xFFFF if i == 0 else (rng.randi() & 0xFFFF)
		batch.inputs.append(input)
		batch.view_offsets_q.append(i * 16)
	var decoded: NetMessages.InputBatch = NetMessages.InputBatch.decode(batch.encode())
	if not assert_not_null(decoded, "decode del lote"):
		return
	for i: int in 8:
		var expected: PlayerInput = batch.inputs[i].quantized()
		expected.buttons &= NetProtocol.VALID_BUTTONS
		assert_true(_inputs_equal(decoded.inputs[i], expected),
				"la entrada %d es igual a quantized() con la máscara aplicada" % i)
		assert_eq(decoded.inputs[i].tick, 593 + i, "ticks seguidos: %d" % i)
		assert_eq(decoded.inputs[i].buttons & ~NetProtocol.VALID_BUTTONS, 0,
				"ningún botón inválido")
	assert_eq(decoded.inputs[0].buttons, NetProtocol.VALID_BUTTONS, "0xFFFF queda en 0x1FFF")

	# Un cliente tramposo escribe lo que quiere: el decode normaliza igual.
	var raw := PackedByteArray()
	raw.resize(21)
	raw.encode_u8(0, NetProtocol.MSG_INPUT_BATCH)
	raw.encode_u32(6, 50)
	raw.encode_u8(10, 1)
	raw.encode_s8(11, -128)    # move.x fuera de rango
	raw.encode_s8(12, 127)
	raw.encode_u16(13, 65535)
	raw.encode_s16(15, -32768) # pitch fuera de rango
	raw.encode_u16(17, 0xE000)
	raw.encode_u16(19, 0xFFFF)
	var cheat: NetMessages.InputBatch = NetMessages.InputBatch.decode(raw)
	if assert_not_null(cheat, "decode de un lote con valores extremos"):
		var input: PlayerInput = cheat.inputs[0]
		assert_true(input.move.length() <= 1.0 + 1e-6, "movimiento normalizado")
		assert_true(absf(input.look_pitch) <= PI / 2.0 + 1e-6, "pitch limitado")
		assert_true(input.look_yaw >= 0.0 and input.look_yaw < TAU, "yaw en [0, TAU)")
		assert_eq(input.buttons, 0, "0xE000 (bits 13-15) no tiene ningún botón válido")
		assert_eq(input.tick, 50, "tick")
		assert_eq(cheat.view_offsets_q[0], 65535, "view_offset_q máximo")


func test_input_batch_ticks_are_implicit_and_u32() -> void:
	# Un lote con huecos no se puede escribir.
	var gap := NetMessages.InputBatch.new()
	gap.newest_tick = 10
	for tick: int in [8, 10]:
		var input := PlayerInput.new()
		input.tick = tick
		gap.inputs.append(input)
	assert_true(gap.encode().is_empty(), "ticks con hueco: no se codifica")
	gap.inputs[0].tick = 9
	gap.inputs[1].tick = 9
	assert_true(gap.encode().is_empty(), "ticks repetidos: no se codifica")
	gap.inputs[0].tick = 9
	gap.inputs[1].tick = 10
	assert_eq(gap.encode().size(), 31, "con ticks seguidos sí")

	var empty := NetMessages.InputBatch.new()
	empty.newest_tick = 10
	assert_true(empty.encode().is_empty(), "un lote vacío no se codifica")
	var too_many := NetMessages.InputBatch.new()
	too_many.newest_tick = 20
	for i: int in 9:
		var input := PlayerInput.new()
		input.tick = 12 + i
		too_many.inputs.append(input)
	assert_true(too_many.encode().is_empty(), "más de 8 entradas no se codifican")
	var early := NetMessages.InputBatch.new()
	early.newest_tick = 1
	for i: int in 2:
		var input := PlayerInput.new()
		input.tick = i
		early.inputs.append(input)
	assert_true(early.encode().is_empty(), "newest_tick < count no se codifica")

	# Ticks en el borde del u32.
	var edge := NetMessages.InputBatch.new()
	edge.newest_tick = 0xFFFFFFFF
	edge.ack_snapshot_tick = 0xFFFFFFFE
	for i: int in 4:
		var input := PlayerInput.new()
		input.tick = 0xFFFFFFFC + i
		edge.inputs.append(input)
	var edge_decoded: NetMessages.InputBatch = NetMessages.InputBatch.decode(edge.encode())
	if assert_not_null(edge_decoded, "lote en el borde del u32"):
		assert_eq(edge_decoded.newest_tick, 0xFFFFFFFF, "newest_tick máximo")
		assert_eq(edge_decoded.ack_snapshot_tick, 0xFFFFFFFE, "ack máximo")
		for i: int in 4:
			assert_eq(edge_decoded.inputs[i].tick, 0xFFFFFFFC + i, "tick %d" % i)

	# view_offset_q fuera de rango y retardo de interpolación saturados.
	var clamped := NetMessages.InputBatch.new()
	clamped.newest_tick = 5
	clamped.interp_delay_q = 999
	var single := PlayerInput.new()
	single.tick = 5
	clamped.inputs.append(single)
	clamped.view_offsets_q.append(-4)
	var clamped_decoded: NetMessages.InputBatch = NetMessages.InputBatch.decode(clamped.encode())
	assert_eq(clamped_decoded.view_offsets_q[0], 0, "view_offset_q negativo queda en 0")
	assert_eq(clamped_decoded.interp_delay_q, 255, "interp_delay_q se satura a u8")
	clamped.view_offsets_q[0] = 70000
	assert_eq(NetMessages.InputBatch.decode(clamped.encode()).view_offsets_q[0], 65535,
			"view_offset_q se satura a u16")
	clamped.view_offsets_q.clear()
	assert_eq(NetMessages.InputBatch.decode(clamped.encode()).view_offsets_q[0], 0,
			"sin view_offset_q se escribe 0")


func test_input_batch_rejects_bad_counts() -> void:
	var valid: PackedByteArray = _sample_input_batch(3).encode()
	assert_not_null(NetMessages.InputBatch.decode(valid), "el lote de 3 es válido")
	var zero: PackedByteArray = valid.duplicate()
	zero.encode_u8(10, 0)
	assert_null(NetMessages.InputBatch.decode(zero), "count 0")
	assert_null(NetMessages.InputBatch.decode(zero.slice(0, 11)), "count 0 sin registros")
	var nine: PackedByteArray = _sample_input_batch(8).encode()
	nine.encode_u8(10, 9)
	nine.resize(11 + 90)
	assert_null(NetMessages.InputBatch.decode(nine), "count 9 aunque el tamaño cuadre")
	var lying: PackedByteArray = valid.duplicate()
	lying.encode_u8(10, 4)
	assert_null(NetMessages.InputBatch.decode(lying), "count que no cuadra con el tamaño")
	lying.encode_u8(10, 2)
	assert_null(NetMessages.InputBatch.decode(lying), "count menor que los registros que hay")
	var early: PackedByteArray = valid.duplicate()
	early.encode_u32(6, 2)
	assert_null(NetMessages.InputBatch.decode(early), "newest_tick < count")
	early.encode_u32(6, 3)
	assert_not_null(NetMessages.InputBatch.decode(early), "newest_tick == count es válido")
	var typed: PackedByteArray = valid.duplicate()
	typed.encode_u8(0, NetProtocol.MSG_SNAPSHOT)
	assert_null(NetMessages.InputBatch.decode(typed), "otro tipo")


func test_small_client_messages() -> void:
	var ready := NetMessages.ClientReady.new()
	var ready_bytes: PackedByteArray = ready.encode()
	assert_eq(ready_bytes, PackedByteArray([0x02, 0]), "CLIENT_READY: type 0x02 y flags 0")
	assert_eq(NetMessages.ClientReady.decode(ready_bytes).flags, 0, "flags")
	ready.flags = 5
	assert_eq(NetMessages.ClientReady.decode(ready.encode()).flags, 5, "flags reservados")

	var leave := NetMessages.ClientLeave.new()
	assert_eq(leave.encode(), PackedByteArray([0x03, 0]), "CLIENT_LEAVE: type 0x03 y reason 0")
	leave.reason = 1
	var leave_bytes: PackedByteArray = leave.encode()
	assert_eq(leave_bytes, PackedByteArray([0x03, 1]), "reason 1 = error")
	assert_eq(NetMessages.ClientLeave.decode(leave_bytes).reason, 1, "reason")

	var teleport: NetMessages.DebugCommand = \
			NetMessages.DebugCommand.teleport(Vector3(1.5, -2.0, 300.25))
	var teleport_bytes: PackedByteArray = teleport.encode()
	assert_eq(teleport_bytes.size(), 14, "DEBUG_COMMAND teleport: 14 B")
	assert_eq(teleport_bytes.decode_u8(0), 0x04, "u8 type")
	assert_eq(teleport_bytes.decode_u8(1), 1, "u8 command = TELEPORT")
	assert_eq(teleport_bytes.decode_float(2), 1.5, "f32 x en 2")
	assert_eq(teleport_bytes.decode_float(6), -2.0, "f32 y en 6")
	assert_eq(teleport_bytes.decode_float(10), 300.25, "f32 z en 10")
	var teleport_decoded: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(teleport_bytes)
	if assert_not_null(teleport_decoded, "decode del teletransporte"):
		assert_eq(teleport_decoded.command, NetProtocol.DEBUG_TELEPORT, "command")
		assert_vec_near(teleport_decoded.get_teleport_position(), Vector3(1.5, -2.0, 300.25), 0.0,
				"posición")
	var other := NetMessages.DebugCommand.new()
	other.command = NetProtocol.DEBUG_SET_WEAPON
	other.payload = PackedByteArray([1, 2, 3])
	var other_decoded: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(other.encode())
	if assert_not_null(other_decoded, "decode de otro comando"):
		assert_eq(other_decoded.command, NetProtocol.DEBUG_SET_WEAPON, "command")
		assert_eq(other_decoded.payload, other.payload, "datos")
	assert_eq(NetMessages.DebugCommand.new().encode().size(), 2, "sin datos: 2 B")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 1, 0, 0, 0, 0])),
			"un teletransporte sin sus 12 B de datos")
	var huge := PackedByteArray([0x04, NetProtocol.DEBUG_SET_WEAPON])
	huge.resize(2 + 65)
	assert_null(NetMessages.DebugCommand.decode(huge), "datos de más de 64 B")


func test_snapshot_roundtrip_and_layout_with_own_state() -> void:
	var state_size: int = PlayerState.ENCODED_SIZE
	var extra_offset: int = 13 + state_size
	var section_offset: int = extra_offset + NetMessages.SNAPSHOT_EXTRA_SIZE
	var snapshot: NetMessages.Snapshot = _sample_snapshot(true, 3)
	var bytes: PackedByteArray = snapshot.encode()
	assert_eq(HEADER_WITH_STATE, section_offset + 1, "cabecera con estado propio y bloque extra")
	assert_eq(HEADER_WITH_STATE, NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE,
			"la constante de NetMessages coincide")
	assert_eq(bytes.size(), HEADER_WITH_STATE + 2 + 3 * EntityRecord.SIZE,
			"cabecera con estado propio y bloque extra + sección")
	assert_eq(bytes.decode_u8(0), 0x10, "u8 type en 0")
	assert_eq(bytes.decode_u32(1), 90001, "u32 server_tick en 1")
	assert_eq(bytes.decode_u32(5), 90000, "u32 input_ack_tick en 5")
	assert_eq(bytes.decode_s8(9), -3, "s8 input_margin en 9")
	assert_eq(bytes.decode_u16(10), 65535, "u16 substitutions en 10")
	assert_eq(bytes.decode_u8(12), 0b1101,
			"u8 flags en 12: bit 0 estado propio, contador 2 (bits 1-2) y bit 3 bloque extra")
	assert_eq(bytes.slice(13, extra_offset), snapshot.own_state.encode(),
			"estado propio sin cuantizar en 13")
	assert_eq(bytes.decode_u16(extra_offset), 845, "u16 health tras el estado propio")
	assert_eq(bytes.decode_u16(extra_offset + 2), 1000, "u16 max_health")
	assert_eq(bytes.decode_u8(extra_offset + 4), 0b101, "u8 status")
	assert_eq(bytes.decode_u32(extra_offset + 5), 123456, "u32 respawn_tick")
	assert_eq(bytes.decode_u8(section_offset), 1, "u8 section_count tras el bloque extra")
	assert_eq(bytes.decode_u8(section_offset + 1), NetProtocol.EntityKind.PLAYER,
			"u8 kind de la sección")
	assert_eq(bytes.decode_u8(section_offset + 2), 3, "u8 count de la sección")
	for i: int in 3:
		var offset: int = section_offset + 3 + EntityRecord.SIZE * i
		var record: EntityRecord = snapshot.records[i]
		assert_eq(bytes.decode_u16(offset), record.net_id, "u16 net_id en +0")
		assert_eq(bytes.decode_u64(offset + 2), NetMath.pack_position(record.position),
				"u64 position en +2")
		assert_eq(bytes.decode_u16(offset + 10), NetMath.quantize_yaw16(record.yaw),
				"u16 yaw en +10")
		assert_eq(bytes.decode_s16(offset + 12), NetMath.quantize_velocity(record.velocity.x),
				"s16 vx en +12")
		assert_eq(bytes.decode_s16(offset + 14), NetMath.quantize_velocity(record.velocity.y),
				"s16 vy en +14")
		assert_eq(bytes.decode_s16(offset + 16), NetMath.quantize_velocity(record.velocity.z),
				"s16 vz en +16")
		assert_eq(bytes.decode_u8(offset + 18), record.flags, "u8 flags en +18")
		assert_eq(bytes.decode_u8(offset + 19), record.action, "u8 action en +19")
		assert_eq(bytes.decode_u8(offset + 20), record.health_q, "u8 health_q en +20")

	var decoded: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
	if not assert_not_null(decoded, "decode del snapshot"):
		return
	assert_eq(decoded.server_tick, 90001, "server_tick")
	assert_eq(decoded.input_ack_tick, 90000, "input_ack_tick")
	assert_eq(decoded.input_margin, -3, "input_margin")
	assert_eq(decoded.substitutions, 65535, "substitutions")
	assert_eq(decoded.own_teleport, 2, "contador de teletransporte propio")
	if assert_not_null(decoded.own_state, "estado propio"):
		assert_true(decoded.own_state.equals_exact(snapshot.own_state),
				"el estado propio es exacto")
	assert_eq(decoded.health, 845, "health")
	assert_eq(decoded.max_health, 1000, "max_health")
	assert_eq(decoded.status, 0b101, "status")
	assert_eq(decoded.respawn_tick, 123456, "respawn_tick")
	assert_true(decoded.is_in_combat(), "bit 0: en combate")
	assert_false(decoded.is_protected(), "bit 1: sin protección")
	assert_true(decoded.is_dead(), "bit 2: muerto")
	assert_eq(decoded.records.size(), 3, "registros")
	for i: int in 3:
		var original: EntityRecord = snapshot.records[i]
		var back: EntityRecord = decoded.records[i]
		assert_eq(back.net_id, original.net_id, "net_id %d" % i)
		assert_eq(back.kind, NetProtocol.EntityKind.PLAYER, "kind %d" % i)
		assert_vec_near(back.position, original.position, POSITION_ERROR * 2.0, "position %d" % i)
		assert_true(absf(angle_difference(back.yaw, original.yaw)) < 6e-5, "yaw %d" % i)
		assert_eq(back.flags, original.flags, "flags %d" % i)
		assert_eq(back.action, original.action, "action %d" % i)
		assert_eq(back.health_q, original.health_q, "health_q %d" % i)
		for axis: int in 3:
			assert_near(back.velocity[axis], clampf(original.velocity[axis], -327.68, 327.67),
					0.005 + 1e-9, "velocity %d.%d" % [i, axis])


func test_snapshot_without_own_state_and_mixed_sections() -> void:
	var snapshot: NetMessages.Snapshot = _sample_snapshot(false, 0)
	snapshot.input_margin = NetProtocol.NO_MARGIN
	snapshot.own_teleport = 0
	var bytes: PackedByteArray = snapshot.encode()
	assert_eq(bytes.size(), 14, "14 B de cabecera sin estado propio, con section_count")
	assert_eq(bytes.decode_u8(12), 0, "flags a 0: tampoco hay bloque extra")
	assert_eq(bytes.decode_u8(13), 0, "u8 section_count en 13")
	assert_eq(bytes.decode_s8(9), -128, "sin datos de margen: -128")
	var decoded: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
	if assert_not_null(decoded, "decode de un snapshot sin registros"):
		assert_null(decoded.own_state, "sin estado propio")
		assert_eq(decoded.input_margin, NetProtocol.NO_MARGIN, "NO_MARGIN")
		assert_true(decoded.records.is_empty(), "sin registros")

	# Dos secciones: jugadores y PNJ.
	var record_size: int = EntityRecord.SIZE
	var mixed := NetMessages.Snapshot.new()
	mixed.server_tick = 5
	for i: int in 3:
		var record := EntityRecord.new()
		record.net_id = 10 + i
		record.kind = NetProtocol.EntityKind.PLAYER if i < 2 else NetProtocol.EntityKind.NPC
		record.position = Vector3(i, i, i)
		record.health_q = 100 + i
		mixed.records.append(record)
	var mixed_bytes: PackedByteArray = mixed.encode()
	assert_eq(mixed_bytes.size(), 14 + 2 + 2 * record_size + 2 + record_size, "dos secciones")
	assert_eq(mixed_bytes.decode_u8(13), 2, "section_count")
	assert_eq(mixed_bytes.decode_u8(14), NetProtocol.EntityKind.PLAYER,
			"kind de la primera sección")
	assert_eq(mixed_bytes.decode_u8(15), 2, "count de la primera sección")
	assert_eq(mixed_bytes.decode_u8(14 + 2 + 2 * record_size), NetProtocol.EntityKind.NPC,
			"kind de la segunda")
	var mixed_decoded: NetMessages.Snapshot = NetMessages.Snapshot.decode(mixed_bytes)
	if assert_not_null(mixed_decoded, "decode del snapshot con dos secciones"):
		assert_eq(mixed_decoded.records.size(), 3, "registros")
		assert_eq(mixed_decoded.records[1].kind, NetProtocol.EntityKind.PLAYER, "kind del segundo")
		assert_eq(mixed_decoded.records[2].kind, NetProtocol.EntityKind.NPC, "kind del tercero")
		assert_eq(mixed_decoded.records[2].net_id, 12, "net_id del PNJ")
		assert_eq(mixed_decoded.records[2].health_q, 102, "health_q del PNJ")

	# input_margin saturado, ticks u32 y contadores módulo.
	var wrap := NetMessages.Snapshot.new()
	wrap.server_tick = 0xFFFFFFFF
	wrap.input_ack_tick = 0xFFFFFFFF
	wrap.input_margin = 500
	wrap.substitutions = 70000
	wrap.own_teleport = 7
	wrap.own_state = PlayerState.new()
	var wrap_decoded: NetMessages.Snapshot = NetMessages.Snapshot.decode(wrap.encode())
	if assert_not_null(wrap_decoded, "decode de un snapshot en los bordes"):
		assert_eq(wrap_decoded.server_tick, 0xFFFFFFFF, "server_tick máximo")
		assert_eq(wrap_decoded.input_ack_tick, 0xFFFFFFFF, "input_ack_tick máximo")
		assert_eq(wrap_decoded.input_margin, 127, "input_margin saturado a s8")
		assert_eq(wrap_decoded.substitutions, 70000 & 0xFFFF, "substitutions módulo 65536")
		assert_eq(wrap_decoded.own_teleport, 3, "contador de teletransporte módulo 4")
	wrap.input_margin = -500
	assert_eq(NetMessages.Snapshot.decode(wrap.encode()).input_margin, -128, "input_margin mínimo")


func test_snapshot_write_header_matches_encode() -> void:
	var snapshot: NetMessages.Snapshot = _sample_snapshot(true, 2)
	var expected: PackedByteArray = snapshot.encode()
	var bytes := PackedByteArray()
	var offset: int = NetMessages.Snapshot.write_header(bytes, snapshot.server_tick,
			snapshot.input_ack_tick, snapshot.input_margin, snapshot.substitutions,
			snapshot.own_teleport, snapshot.own_state.encode(), snapshot.health,
			snapshot.max_health, snapshot.status, snapshot.respawn_tick)
	assert_eq(offset, HEADER_WITH_STATE - 1, "section_count empieza tras el estado y el bloque extra")
	assert_eq(bytes.size(), HEADER_WITH_STATE, "el búfer queda con la cabecera completa")
	assert_eq(bytes, expected.slice(0, HEADER_WITH_STATE - 1) + PackedByteArray([0]),
			"misma cabecera que encode()")

	# Sin los datos del bloque extra, se escribe a ceros (y es un snapshot válido).
	var bare := PackedByteArray()
	NetMessages.Snapshot.write_header(bare, 1, 2, 3, 4, 0, snapshot.own_state.encode())
	assert_eq(bare.decode_u8(12) & NetMessages.FLAG_OWN_EXTRA, NetMessages.FLAG_OWN_EXTRA,
			"el bloque extra acompaña siempre al estado propio")
	var bare_decoded: NetMessages.Snapshot = NetMessages.Snapshot.decode(bare)
	if assert_not_null(bare_decoded, "decode de la cabecera sin datos de vida"):
		assert_eq(bare_decoded.health, 0, "vida 0 por defecto")
		assert_eq(bare_decoded.max_health, 0, "vida máxima 0 por defecto")
		assert_eq(bare_decoded.status, 0, "estado 0 por defecto")
		assert_eq(bare_decoded.respawn_tick, 0, "reaparición 0 por defecto")

	var plain := PackedByteArray()
	var plain_offset: int = NetMessages.Snapshot.write_header(plain, 11, 22, -5, 33, 1,
			PackedByteArray(), 500, 1000, 7, 99)
	assert_eq(plain_offset, 13, "section_count empieza en 13 sin estado propio")
	assert_eq(plain.size(), 14, "cabecera de 14 B (los datos del bloque extra se ignoran)")
	assert_eq(plain.decode_u8(12), 0b010, "flags: solo el contador de teletransporte")

	# En un búfer ya grande no cambia el tamaño; el constructor rellena el resto.
	var big := PackedByteArray()
	big.resize(1200)
	big.fill(0xAA)
	var big_offset: int = NetMessages.Snapshot.write_header(big, 1, 2, 3, 4, 0, PackedByteArray())
	assert_eq(big_offset, 13, "offset")
	assert_eq(big.size(), 1200, "no se encoge ni se amplía un búfer que ya cabe")
	assert_eq(big.decode_u8(13), 0, "section_count a 0")
	assert_eq(big.decode_u8(14), 0xAA, "no toca lo que va después")


func test_snapshot_capacity_fits_in_one_packet() -> void:
	# Capacidad con estado propio, bloque extra y una sección: floor((1200 - cabecera - 2) / 21).
	var capacity: int = floori((NetProtocol.MAX_PACKET_BYTES - HEADER_WITH_STATE - 2)
			/ float(EntityRecord.SIZE))
	# Con el PlayerState de 111 B de la fase 4 (habilidades.md, 3.1): 13 + 111 + 9 + 1 = 134 B de
	# cabecera y floor((1200 - 136) / 21) = 50 registros (52 con los 69 B de la fase 3).
	if PlayerState.ENCODED_SIZE == 111:
		assert_eq(HEADER_WITH_STATE, 134, "cabecera de 134 B")
		assert_eq(capacity, 50, "capacidad del documento: 50 registros")
	var snapshot := NetMessages.Snapshot.new()
	snapshot.own_state = PlayerState.new()
	for i: int in capacity:
		var record := EntityRecord.new()
		record.net_id = 100 + i
		record.position = Vector3(i * 10.0, 1.0, -i * 3.0)
		snapshot.records.append(record)
	var bytes: PackedByteArray = snapshot.encode()
	assert_eq(bytes.size(), HEADER_WITH_STATE + 2 + capacity * EntityRecord.SIZE,
			"%d registros llenan el paquete" % capacity)
	assert_true(bytes.size() <= NetProtocol.MAX_PACKET_BYTES, "cabe en 1200 B")
	assert_true(bytes.size() + EntityRecord.SIZE > NetProtocol.MAX_PACKET_BYTES,
			"un registro más ya no cabe")
	var decoded: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
	if assert_not_null(decoded, "decode del snapshot lleno"):
		assert_eq(decoded.records.size(), capacity, "registros")
		assert_eq(decoded.records[capacity - 1].net_id, 100 + capacity - 1, "último registro")

	# Más de 255 registros de un tipo se reparten en varias secciones.
	var many := NetMessages.Snapshot.new()
	for i: int in 300:
		var record := EntityRecord.new()
		record.net_id = i
		many.records.append(record)
	var many_bytes: PackedByteArray = many.encode()
	assert_eq(many_bytes.decode_u8(13), 2, "300 registros: dos secciones")
	assert_eq(NetMessages.Snapshot.decode(many_bytes).records.size(), 300, "se decodifican los 300")


func test_snapshot_extra_block_rules() -> void:
	# Valores en los bordes del bloque extra.
	var snapshot: NetMessages.Snapshot = _sample_snapshot(true, 0)
	snapshot.health = 65535
	snapshot.max_health = 65535
	snapshot.status = 0xFF
	snapshot.respawn_tick = 0xFFFFFFFF
	var decoded: NetMessages.Snapshot = NetMessages.Snapshot.decode(snapshot.encode())
	if assert_not_null(decoded, "decode con el bloque extra en su máximo"):
		assert_eq(decoded.health, 65535, "u16 health máximo")
		assert_eq(decoded.max_health, 65535, "u16 max_health máximo")
		assert_eq(decoded.status, 0xFF, "u8 status máximo")
		assert_eq(decoded.respawn_tick, 0xFFFFFFFF, "u32 respawn_tick máximo")
	snapshot.health = 70000
	snapshot.max_health = 70000
	snapshot.respawn_tick = 0x1FFFFFFFF
	var saturated: NetMessages.Snapshot = NetMessages.Snapshot.decode(snapshot.encode())
	if assert_not_null(saturated, "decode con la vida fuera de rango"):
		assert_eq(saturated.health, 65535, "la vida se satura a u16")
		assert_eq(saturated.max_health, 65535, "la vida máxima se satura a u16")
		assert_eq(saturated.respawn_tick, 0xFFFFFFFF, "el tick se recorta a u32")
	snapshot.health = -5
	snapshot.max_health = 1000
	assert_eq(NetMessages.Snapshot.decode(snapshot.encode()).health, 0, "vida negativa = 0")

	# El bit 3 de los flags va si y solo si va el bit 0.
	var bytes: PackedByteArray = _sample_snapshot(true, 2).encode()
	assert_not_null(NetMessages.Snapshot.decode(bytes), "con los dos bits, válido")
	var extra_without_state: PackedByteArray = _sample_snapshot(false, 2).encode()
	extra_without_state.encode_u8(12, NetMessages.FLAG_OWN_EXTRA)
	assert_null(NetMessages.Snapshot.decode(extra_without_state),
			"bit 3 (bloque extra) sin bit 0 (estado propio)")
	var state_without_extra: PackedByteArray = bytes.duplicate()
	state_without_extra.encode_u8(12, bytes.decode_u8(12) & ~NetMessages.FLAG_OWN_EXTRA)
	assert_null(NetMessages.Snapshot.decode(state_without_extra),
			"bit 0 (estado propio) sin bit 3 (bloque extra)")
	# Con el bit 3 puesto y el estado propio sin bloque (cabecera de la fase 2), no cuadra.
	var old_layout: PackedByteArray = bytes.slice(0, 13 + PlayerState.ENCODED_SIZE)
	old_layout.append_array(bytes.slice(13 + PlayerState.ENCODED_SIZE
			+ NetMessages.SNAPSHOT_EXTRA_SIZE))
	assert_null(NetMessages.Snapshot.decode(old_layout), "sin los 9 B del bloque, no cuadra")

	# La vida no puede ser mayor que la máxima.
	var extra_offset: int = 13 + PlayerState.ENCODED_SIZE
	var too_healthy: PackedByteArray = bytes.duplicate()
	too_healthy.encode_u16(extra_offset, 1001)
	too_healthy.encode_u16(extra_offset + 2, 1000)
	assert_null(NetMessages.Snapshot.decode(too_healthy), "vida mayor que la máxima")
	too_healthy.encode_u16(extra_offset, 1000)
	assert_not_null(NetMessages.Snapshot.decode(too_healthy), "vida igual que la máxima")


func test_snapshot_positions_roundtrip_within_five_millimeters() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var snapshot := NetMessages.Snapshot.new()
	for i: int in 50:
		var record := EntityRecord.new()
		record.net_id = i
		record.position = Vector3(rng.randf_range(-5000.0, 5000.0),
				rng.randf_range(-5000.0, 5000.0), rng.randf_range(-5000.0, 5000.0))
		snapshot.records.append(record)
	var extreme := EntityRecord.new()
	extreme.net_id = 999
	extreme.position = Vector3(99999.0, -99999.0, 5242.871)
	snapshot.records.append(extreme)
	var decoded: NetMessages.Snapshot = NetMessages.Snapshot.decode(snapshot.encode())
	if not assert_not_null(decoded, "decode"):
		return
	for i: int in 50:
		var delta: Vector3 = (decoded.records[i].position - snapshot.records[i].position).abs()
		assert_true(maxf(delta.x, maxf(delta.y, delta.z)) <= POSITION_ERROR,
				"el error de la posición %d es de 5 mm como mucho (%s)" % [i, delta])
	assert_vec_near(decoded.records[50].position, Vector3(5242.87, -5242.88, 5242.87), 1e-3,
			"fuera de rango se satura")


func test_entity_spawn_roundtrip_and_layout() -> void:
	var spawn: NetMessages.EntitySpawn = _sample_spawn()
	var bytes: PackedByteArray = spawn.encode()
	var name_bytes: PackedByteArray = spawn.display_name.to_utf8_buffer()
	var name_offset: int = 10 + PlayerState.ENCODED_SIZE
	var tail_offset: int = name_offset + 1 + name_bytes.size()
	assert_eq(bytes.size(), tail_offset + 9, "tamaño: 10 B + estado + nombre + nivel y apariencia (v7)")
	assert_eq(bytes.decode_u8(0), 0x20, "u8 type en 0")
	assert_eq(bytes.decode_u16(1), 4242, "u16 net_id en 1")
	assert_eq(bytes.decode_u8(3), NetProtocol.EntityKind.PLAYER, "u8 kind en 3")
	assert_eq(bytes.decode_u32(4), 654321, "u32 spawn_tick en 4")
	assert_eq(bytes.decode_u8(8), NetProtocol.Realm.VARDHEIM, "u8 realm en 8")
	assert_eq(bytes.decode_u8(9), 0b011, "u8 flags en 9: tuyo y contador 1")
	assert_eq(bytes.slice(10, name_offset), spawn.state.encode(), "PlayerState en 10")
	assert_eq(bytes.decode_u8(name_offset), name_bytes.size(), "u8 name_len tras el estado")
	assert_eq(bytes.slice(name_offset + 1, tail_offset), name_bytes, "nombre tras la longitud")
	assert_eq(bytes.decode_u8(tail_offset), 12, "u8 level tras el nombre (v7)")
	assert_eq(bytes.slice(tail_offset + 1), spawn.appearance, "y los 8 B de la apariencia")

	var decoded: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if not assert_not_null(decoded, "decode del SPAWN"):
		return
	assert_eq(decoded.net_id, 4242, "net_id")
	assert_eq(decoded.kind, NetProtocol.EntityKind.PLAYER, "kind")
	assert_eq(decoded.spawn_tick, 654321, "spawn_tick")
	assert_eq(decoded.realm, NetProtocol.Realm.VARDHEIM, "realm")
	assert_true(decoded.is_yours, "is_yours")
	assert_eq(decoded.teleport_counter, 1, "teleport_counter")
	assert_eq(decoded.display_name, spawn.display_name, "nombre")
	assert_eq(decoded.level, 12, "nivel")
	assert_eq(decoded.appearance, spawn.appearance, "apariencia")
	if assert_not_null(decoded.state, "estado"):
		assert_true(decoded.state.equals_exact(spawn.state), "el estado es exacto")

	spawn.is_yours = false
	spawn.teleport_counter = 6
	spawn.display_name = ""
	var plain: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(spawn.encode())
	if assert_not_null(plain, "decode de un SPAWN ajeno sin nombre"):
		assert_false(plain.is_yours, "no es tuyo")
		assert_eq(plain.teleport_counter, 2, "contador módulo 4")
		assert_eq(spawn.encode().size(), name_offset + 1 + 9, "10 B + estado + 1 B sin nombre + 9 B (v7)")
	spawn.kind = NetProtocol.EntityKind.NPC
	assert_not_null(NetMessages.EntitySpawn.decode(spawn.encode()), "un PNJ reutiliza el formato")
	spawn.kind = NetProtocol.EntityKind.NONE
	assert_true(spawn.encode().is_empty(), "un tipo sin formato no se codifica")


## Bit 3 del flags de la cabecera del ENTITY_SPAWN (protocolo 7, docs/plataforma.md §5.4): personal del juego.
## No toca el bit «tuyo» ni el contador de teletransporte.
func test_entity_spawn_staff_bit() -> void:
	var spawn: NetMessages.EntitySpawn = _sample_spawn()
	assert_false(spawn.is_staff, "por defecto no")
	assert_eq(spawn.encode().decode_u8(9), 0b0011, "sin el bit 3")
	spawn.is_staff = true
	var bytes: PackedByteArray = spawn.encode()
	assert_eq(NetMessages.SPAWN_FLAG_STAFF, 1 << 3, "bit 3")
	assert_eq(bytes.decode_u8(9), 0b1011, "u8 flags en 9: personal, tuyo y contador 1")
	var decoded: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if assert_not_null(decoded, "decode con el bit 3"):
		assert_true(decoded.is_staff, "personal del juego")
		assert_true(decoded.is_yours, "sigue siendo tuyo")
		assert_eq(decoded.teleport_counter, 1, "y el contador intacto")
	spawn.is_yours = false
	spawn.teleport_counter = 3
	var other: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(spawn.encode())
	if assert_not_null(other, "un SPAWN ajeno con el bit 3"):
		assert_true(other.is_staff and not other.is_yours, "lo ven los demás")
		assert_eq(other.teleport_counter, 3, "contador 3")
	var entity := NetEntity.new()
	entity.kind = NetProtocol.EntityKind.PLAYER
	entity.display_name = "Aneira"
	entity.is_staff = true
	assert_true(NetMessages.EntitySpawn.decode(entity.encode_spawn(10, false)).is_staff,
			"NetEntity.is_staff llega al SPAWN")


func test_entity_despawn_and_notice() -> void:
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = 0xFFFE
	despawn.despawn_tick = 0xFFFFFFF0
	despawn.reason = NetProtocol.DespawnReason.DISCONNECTED
	var bytes: PackedByteArray = despawn.encode()
	assert_eq(bytes.size(), 8, "ENTITY_DESPAWN: 8 B")
	assert_eq(bytes.decode_u8(0), 0x21, "u8 type en 0")
	assert_eq(bytes.decode_u16(1), 0xFFFE, "u16 net_id en 1")
	assert_eq(bytes.decode_u32(3), 0xFFFFFFF0, "u32 despawn_tick en 3")
	assert_eq(bytes.decode_u8(7), 1, "u8 reason en 7")
	var back: NetMessages.EntityDespawn = NetMessages.EntityDespawn.decode(bytes)
	if assert_not_null(back, "decode del DESPAWN"):
		assert_eq(back.net_id, 0xFFFE, "net_id")
		assert_eq(back.despawn_tick, 0xFFFFFFF0, "despawn_tick")
		assert_eq(back.reason, NetProtocol.DespawnReason.DISCONNECTED, "reason")

	var notice := NetMessages.Notice.new()
	notice.code = NetProtocol.NoticeCode.KICK
	notice.text = "Has sido expulsado: demasiados avisos ñ"
	var notice_bytes: PackedByteArray = notice.encode()
	var text_bytes: PackedByteArray = notice.text.to_utf8_buffer()
	assert_eq(notice_bytes.size(), 3 + text_bytes.size(), "NOTICE: 3 B + texto")
	assert_eq(notice_bytes.decode_u8(0), 0x30, "u8 type en 0")
	assert_eq(notice_bytes.decode_u8(1), 1, "u8 code en 1")
	assert_eq(notice_bytes.decode_u8(2), text_bytes.size(), "u8 len en 2")
	assert_eq(notice_bytes.slice(3), text_bytes, "texto en 3")
	var notice_back: NetMessages.Notice = NetMessages.Notice.decode(notice_bytes)
	if assert_not_null(notice_back, "decode del NOTICE"):
		assert_eq(notice_back.code, NetProtocol.NoticeCode.KICK, "code")
		assert_eq(notice_back.text, notice.text, "texto")
	notice.text = "x".repeat(300)
	var long_back: NetMessages.Notice = NetMessages.Notice.decode(notice.encode())
	if assert_not_null(long_back, "decode de un NOTICE largo"):
		assert_eq(long_back.text.length(), 200, "el texto se recorta a 200 B")
	assert_eq(NetMessages.Notice.new().encode().size(), 3, "NOTICE sin texto: 3 B")


func test_entity_event_hit_layout_and_roundtrip() -> void:
	var hit: NetMessages.EntityEvent = _sample_hit()
	var bytes: PackedByteArray = hit.encode()
	assert_eq(bytes.size(), 17, "HIT: 17 B")
	assert_eq(bytes.decode_u8(0), 0x23, "u8 type en 0")
	assert_eq(bytes.decode_u16(1), 321, "u16 net_id (la víctima) en 1")
	assert_eq(bytes.decode_u32(3), 123456, "u32 tick en 3")
	assert_eq(bytes.decode_u8(7), 1, "u8 event en 7: HIT")
	assert_eq(bytes.decode_u8(8), 8, "u8 len en 8")
	assert_eq(bytes.decode_u16(9), 654, "u16 attacker en 9")
	assert_eq(bytes.decode_u16(11), 243, "u16 amount en 11")
	assert_eq(bytes.decode_u8(13), 2, "u8 damage_type en 13: contundente")
	assert_eq(bytes.decode_u8(14), 0b10001, "u8 flags en 14: crítico y mortal")
	assert_eq(bytes.decode_u16(15), 4, "u16 attack_id en 15")
	var back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
	if not assert_not_null(back, "decode del HIT"):
		return
	assert_eq(back.event, NetMessages.EntityEvent.Kind.HIT, "event")
	assert_eq(back.net_id, 321, "net_id")
	assert_eq(back.tick, 123456, "tick")
	assert_eq(back.attacker, 654, "attacker")
	assert_eq(back.amount, 243, "amount")
	assert_eq(back.damage_type, DamageFormula.DamageType.BLUNT, "damage_type")
	assert_eq(back.attack_id, 4, "attack_id")
	assert_true(back.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_CRITICAL), "crítico")
	assert_true(back.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_LETHAL), "mortal")
	assert_false(back.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "no bloqueado")
	assert_false(back.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED), "no parado")
	assert_false(back.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_GUARD_BREAK), "sin rotura")
	assert_eq(back.encode(), bytes, "recodificar da los mismos bytes")

	# Bordes: ticks y daño u16 saturado.
	var edge: NetMessages.EntityEvent = NetMessages.EntityEvent.hit(0xFFFF, 0xFFFFFFFF, 0xFFFF,
			70000, 255, 0xFF, 0xFFFF)
	var edge_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(edge.encode())
	if assert_not_null(edge_back, "decode de un HIT en los bordes"):
		assert_eq(edge_back.net_id, 0xFFFF, "net_id máximo")
		assert_eq(edge_back.tick, 0xFFFFFFFF, "tick máximo")
		assert_eq(edge_back.amount, 0xFFFF, "el daño se satura a u16")
		assert_eq(edge_back.damage_type, 255, "damage_type máximo")
		assert_eq(edge_back.hit_flags, 0xFF, "flags")
		assert_eq(edge_back.attack_id, 0xFFFF, "attack_id máximo")
	var negative: NetMessages.EntityEvent = NetMessages.EntityEvent.hit(1, 1, 1, -5, 0, 0, 0)
	assert_eq(NetMessages.EntityEvent.decode(negative.encode()).amount, 0, "daño negativo = 0")


func test_entity_event_death_kill_respawn_layout_and_roundtrip() -> void:
	var death: NetMessages.EntityEvent = _sample_death()
	var death_bytes: PackedByteArray = death.encode()
	assert_eq(death_bytes.size(), 13, "DEATH: 13 B")
	assert_eq(death_bytes.decode_u8(7), 2, "u8 event en 7: DEATH")
	assert_eq(death_bytes.decode_u8(8), 4, "u8 len en 8")
	assert_eq(death_bytes.decode_u16(9), 654, "u16 killer en 9")
	assert_eq(death_bytes.decode_u16(11), 4, "u16 attack_id en 11")
	var death_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(death_bytes)
	if assert_not_null(death_back, "decode del DEATH"):
		assert_eq(death_back.event, NetMessages.EntityEvent.Kind.DEATH, "event")
		assert_eq(death_back.net_id, 321, "net_id")
		assert_eq(death_back.tick, 123457, "tick")
		assert_eq(death_back.killer, 654, "killer")
		assert_eq(death_back.attack_id, 4, "attack_id")
	var environment: NetMessages.EntityEvent = NetMessages.EntityEvent.death(9, 10, 0, 0)
	assert_eq(NetMessages.EntityEvent.decode(environment.encode()).killer, 0,
			"killer 0 = el entorno")

	var kill: NetMessages.EntityEvent = _sample_kill()
	var kill_bytes: PackedByteArray = kill.encode()
	assert_eq(kill_bytes.size(), 14 + 2 * 2, "KILL con 2 asistentes: 14 + 2n B")
	assert_eq(kill_bytes.decode_u8(7), 3, "u8 event en 7: KILL")
	assert_eq(kill_bytes.decode_u8(8), 5 + 2 * 2, "u8 len en 8")
	assert_eq(kill_bytes.decode_u16(9), 654, "u16 killer en 9")
	assert_eq(kill_bytes.decode_u16(11), 4, "u16 attack_id en 11")
	assert_eq(kill_bytes.decode_u8(13), 2, "u8 n en 13")
	assert_eq(kill_bytes.decode_u16(14), 700, "primer asistente en 14")
	assert_eq(kill_bytes.decode_u16(16), 701, "segundo asistente en 16")
	var kill_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(kill_bytes)
	if assert_not_null(kill_back, "decode del KILL"):
		assert_eq(kill_back.event, NetMessages.EntityEvent.Kind.KILL, "event")
		assert_eq(kill_back.net_id, 321, "net_id (la víctima)")
		assert_eq(kill_back.killer, 654, "killer")
		assert_eq(kill_back.attack_id, 4, "attack_id")
		assert_eq(kill_back.assistants, PackedInt32Array([700, 701]), "asistentes")
	var lonely: NetMessages.EntityEvent = NetMessages.EntityEvent.kill(1, 2, 3, 4,
			PackedInt32Array())
	assert_eq(lonely.encode().size(), 14, "KILL sin asistentes: 14 B")
	assert_true(NetMessages.EntityEvent.decode(lonely.encode()).assistants.is_empty(),
			"sin asistentes")
	var crowd := PackedInt32Array()
	for i: int in 40:
		crowd.append(1000 + i)
	var crowd_event: NetMessages.EntityEvent = NetMessages.EntityEvent.kill(1, 2, 3, 4, crowd)
	var crowd_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(crowd_event.encode())
	if assert_not_null(crowd_back, "decode de un KILL con demasiados asistentes"):
		assert_eq(crowd_back.assistants.size(), NetMessages.EntityEvent.MAX_ASSISTANTS,
				"se recorta a %d asistentes" % NetMessages.EntityEvent.MAX_ASSISTANTS)
		assert_eq(crowd_back.assistants[0], 1000, "los primeros se conservan")

	var respawn: NetMessages.EntityEvent = _sample_respawn()
	var respawn_bytes: PackedByteArray = respawn.encode()
	assert_eq(respawn_bytes.size(), 10, "RESPAWN: 10 B")
	assert_eq(respawn_bytes.decode_u8(7), 4, "u8 event en 7: RESPAWN")
	assert_eq(respawn_bytes.decode_u8(8), 1, "u8 len en 8")
	assert_eq(respawn_bytes.decode_u8(9), 2, "u8 point en 9")
	var respawn_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(respawn_bytes)
	if assert_not_null(respawn_back, "decode del RESPAWN"):
		assert_eq(respawn_back.event, NetMessages.EntityEvent.Kind.RESPAWN, "event")
		assert_eq(respawn_back.net_id, 321, "net_id (quien reaparece)")
		assert_eq(respawn_back.tick, 124057, "tick")
		assert_eq(respawn_back.point, 2, "point")

	# Un evento que no existe no se codifica.
	var unknown := NetMessages.EntityEvent.new()
	unknown.event = 12
	assert_true(unknown.encode().is_empty(), "un evento desconocido (el 12; del 7 al 11 son del protocolo 6) no tiene formato")


func test_entity_event_rejects_inconsistent_lengths() -> void:
	# La longitud declarada tiene que cuadrar con el evento y con el tamaño real.
	for sample: NetMessages.EntityEvent in [_sample_hit(), _sample_death(), _sample_respawn()]:
		var bytes: PackedByteArray = sample.encode()
		for wrong_len: int in [0, bytes.decode_u8(8) - 1, bytes.decode_u8(8) + 1, 255]:
			var tampered: PackedByteArray = bytes.duplicate()
			tampered.encode_u8(8, wrong_len)
			assert_null(NetMessages.EntityEvent.decode(tampered),
					"evento %d con len %d declarado" % [sample.event, wrong_len])
		var resized: PackedByteArray = bytes.duplicate()
		resized.resize(bytes.size() + 1)
		resized.encode_u8(8, bytes.decode_u8(8) + 1)
		assert_null(NetMessages.EntityEvent.decode(resized),
				"evento %d con len y tamaño coherentes pero más largo que su formato" % sample.event)
	# KILL: n tiene que cuadrar con len.
	var kill_bytes: PackedByteArray = _sample_kill().encode()
	var bad_count: PackedByteArray = kill_bytes.duplicate()
	bad_count.encode_u8(13, 3)
	assert_null(NetMessages.EntityEvent.decode(bad_count), "n mayor que los asistentes que caben")
	bad_count.encode_u8(13, 1)
	assert_null(NetMessages.EntityEvent.decode(bad_count), "n menor que los asistentes")
	var short_kill: PackedByteArray = kill_bytes.slice(0, 13)
	short_kill.encode_u8(8, 4)
	assert_null(NetMessages.EntityEvent.decode(short_kill), "KILL sin su campo n")
	# Demasiados asistentes aunque cuadren las longitudes.
	var too_many := PackedByteArray()
	var too_many_count: int = NetMessages.EntityEvent.MAX_ASSISTANTS + 1
	too_many.resize(14 + 2 * too_many_count)
	too_many.encode_u8(0, NetProtocol.MSG_ENTITY_EVENT)
	too_many.encode_u8(7, NetMessages.EntityEvent.Kind.KILL)
	too_many.encode_u8(8, 5 + 2 * too_many_count)
	too_many.encode_u8(13, too_many_count)
	assert_null(NetMessages.EntityEvent.decode(too_many),
			"más de %d asistentes" % NetMessages.EntityEvent.MAX_ASSISTANTS)
	# Evento desconocido o cero (el 5 WAR y el 6 TELEGRAPH existen desde el protocolo 3; del 7 al 11, desde
	# el 6).
	for event_code: int in [0, 12, 255]:
		var unknown_bytes: PackedByteArray = _sample_respawn().encode()
		unknown_bytes.encode_u8(7, event_code)
		assert_null(NetMessages.EntityEvent.decode(unknown_bytes), "evento %d" % event_code)


func test_respawn_request_layout() -> void:
	var request: NetMessages.RespawnRequest = _sample_respawn_request()
	var bytes: PackedByteArray = request.encode()
	assert_eq(bytes, PackedByteArray([0x05, 3]), "RESPAWN_REQUEST: type 0x05 y point_index")
	var back: NetMessages.RespawnRequest = NetMessages.RespawnRequest.decode(bytes)
	if assert_not_null(back, "decode del RESPAWN_REQUEST"):
		assert_eq(back.point_index, 3, "point_index")
	request.point_index = 300
	assert_eq(request.encode()[1], 300 & 0xFF, "point_index módulo 256")
	assert_null(NetMessages.RespawnRequest.decode(PackedByteArray([0x05])), "sin índice")
	assert_null(NetMessages.RespawnRequest.decode(PackedByteArray([0x05, 1, 2])), "con un byte más")
	assert_null(NetMessages.RespawnRequest.decode(PackedByteArray([0x02, 1])), "otro tipo")


func test_new_message_channels_and_debug_command_ids() -> void:
	assert_eq(NetProtocol.MSG_RESPAWN_REQUEST, 0x05, "RESPAWN_REQUEST es el tipo 0x05")
	assert_eq(NetProtocol.MSG_ENTITY_EVENT, 0x23, "ENTITY_EVENT es el tipo 0x23")
	assert_eq(NetProtocol.channel_for_type(NetProtocol.MSG_ENTITY_EVENT), NetProtocol.CH_RELIABLE,
			"ENTITY_EVENT va por el canal fiable (3)")
	assert_eq(NetProtocol.channel_for_type(NetProtocol.MSG_RESPAWN_REQUEST),
			NetProtocol.CH_RELIABLE, "RESPAWN_REQUEST va por el canal fiable (3)")
	assert_eq(NetProtocol.channel_for_type(NetProtocol.MSG_INPUT_BATCH), NetProtocol.CH_INPUT,
			"las entradas no cambian")
	assert_eq(NetProtocol.channel_for_type(NetProtocol.MSG_SNAPSHOT), NetProtocol.CH_SNAPSHOT,
			"los snapshots no cambian")
	for message_type: int in [NetProtocol.MSG_ENTITY_EVENT, NetProtocol.MSG_RESPAWN_REQUEST]:
		assert_eq(NetProtocol.transfer_mode(NetProtocol.channel_for_type(message_type)),
				MultiplayerPeer.TRANSFER_MODE_RELIABLE, "0x%02X es fiable" % message_type)
		assert_false(NetProtocol.is_unreliable_channel(NetProtocol.channel_for_type(message_type)),
				"0x%02X no pierde paquetes" % message_type)

	# Ids fijos de los comandos de depuración (combate.md, sección 6).
	assert_eq(NetProtocol.DEBUG_TELEPORT, 1, "teleport")
	assert_eq(NetProtocol.DEBUG_HEAL, 2, "heal")
	assert_eq(NetProtocol.DEBUG_KILL, 3, "kill")
	assert_eq(NetProtocol.DEBUG_STAMINA_INF, 4, "stamina_inf")
	assert_eq(NetProtocol.DEBUG_SET_WEAPON, 5, "set_weapon")
	assert_eq(NetProtocol.DEBUG_SPAWN_DUMMY, 6, "spawn_dummy")
	assert_eq(NetProtocol.DEBUG_UNSTUCK, 7, "unstuck")
	assert_eq(NetProtocol.DEBUG_FORT_RESET, 8, "fort_reset")
	assert_eq(NetProtocol.DEBUG_FORT_OWNER, 9, "fort_owner")
	assert_eq(NetProtocol.DEBUG_FORT_KILL_CAPTAIN, 10, "fort_kill_captain")
	assert_eq(NetProtocol.DEBUG_FORT_CAPTURE_SPEED, 11, "fort_capture_speed")
	assert_eq(NetProtocol.DEBUG_NPC_DEBUG, 12, "npc_debug")
	assert_eq(NetProtocol.DEBUG_COOLDOWNS_OFF, 13, "cooldowns_off")
	assert_eq(NetProtocol.DEBUG_APPLY_STATUS, 14, "apply_status")
	assert_eq(NetProtocol.DEBUG_DOWN, 15, "down")
	assert_eq(NetProtocol.DEBUG_REFILL, 16, "refill")
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS.size(), 20, "dieciséis comandos y los cuatro de la progresión (v7)")
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"set_weapon"], 5, "tabla: set_weapon")
	var seen: Dictionary = {}
	for command_name: StringName in NetProtocol.DEBUG_COMMAND_IDS:
		var id: int = NetProtocol.DEBUG_COMMAND_IDS[command_name]
		assert_false(seen.has(id), "el id %d no se repite" % id)
		seen[id] = true
	# Los comandos nuevos viajan en un DEBUG_COMMAND como cualquier otro.
	for id: int in [NetProtocol.DEBUG_HEAL, NetProtocol.DEBUG_KILL, NetProtocol.DEBUG_STAMINA_INF,
			NetProtocol.DEBUG_SET_WEAPON, NetProtocol.DEBUG_SPAWN_DUMMY]:
		var command := NetMessages.DebugCommand.new()
		command.command = id
		command.payload = PackedByteArray([7])
		var back: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(command.encode())
		if assert_not_null(back, "DEBUG_COMMAND %d" % id):
			assert_eq(back.command, id, "command %d" % id)
			assert_eq(back.payload, command.payload, "datos de %d" % id)


# --- NetMessages: mensajes malformados --------------------------------------------------------

func test_malformed_messages_return_null() -> void:
	var samples: Array = _sample_messages()
	var decoders: Array[Callable] = _decoders()
	for entry: Array in samples:
		var label: String = entry[0]
		var bytes: PackedByteArray = entry[1]
		var decoder: Callable = entry[2]
		assert_not_null(decoder.call(bytes), "%s: el mensaje válido se decodifica" % label)
		# Truncado en cualquier punto.
		for length: int in bytes.size():
			if decoder.call(bytes.slice(0, length)) != null:
				fail("%s truncado a %d de %d B debería ser null" % [label, length, bytes.size()])
				break
		# Con bytes de sobra.
		for extra: int in [1, 2, 20]:
			var longer: PackedByteArray = bytes.duplicate()
			longer.resize(bytes.size() + extra)
			if decoder.call(longer) != null:
				fail("%s con %d B de sobra debería ser null" % [label, extra])
		# Tipo desconocido (o magic erróneo).
		var wrong: PackedByteArray = bytes.duplicate()
		wrong[0] = 0x7F
		assert_null(decoder.call(wrong), "%s con el byte 0 cambiado" % label)
		# Un mensaje solo lo decodifica su propio decodificador.
		for other: Array in samples:
			if other[2] != decoder and decoder.call(other[1]) != null:
				fail("%s decodificó bytes de %s" % [label, other[0]])
	# Un decodificador por tipo de mensaje (ENTITY_EVENT tiene cuatro ejemplos, uno por evento).
	var sample_decoders: Array[Callable] = []
	for entry: Array in samples:
		if not sample_decoders.has(entry[2]):
			sample_decoders.append(entry[2])
	assert_eq(decoders.size(), sample_decoders.size(),
			"hay un decodificador por tipo de mensaje de ejemplo")
	for decoder: Callable in decoders:
		assert_null(decoder.call(PackedByteArray()), "búfer vacío")
		assert_null(decoder.call(PackedByteArray([0])), "un solo byte nulo")


func test_malformed_lengths_and_counters_return_null() -> void:
	# HELLO: name_len > 48, ticket_len > 256 y longitudes que no cuadran.
	var hello_bytes: PackedByteArray = _sample_hello().encode()
	var name_len: int = hello_bytes.decode_u8(20)
	var bad_name: PackedByteArray = hello_bytes.duplicate()
	bad_name.encode_u8(20, name_len + 1)
	assert_null(NetMessages.Hello.decode(bad_name), "name_len más largo que el mensaje")
	bad_name.encode_u8(20, 49)
	assert_null(NetMessages.Hello.decode(bad_name), "name_len > 48")
	var bad_ticket: PackedByteArray = hello_bytes.duplicate()
	bad_ticket.encode_u16(21 + name_len, 6)
	assert_null(NetMessages.Hello.decode(bad_ticket), "ticket_len que no cuadra")
	var huge_ticket := NetMessages.Hello.new().encode()
	huge_ticket.resize(23 + 257)
	huge_ticket.encode_u16(21, 257)
	assert_null(NetMessages.Hello.decode(huge_ticket), "ticket_len > 256")
	var no_magic: PackedByteArray = hello_bytes.duplicate()
	no_magic.encode_u32(0, 0x12345678)
	assert_null(NetMessages.Hello.decode(no_magic), "magic erróneo")

	# WELCOME y REJECT.
	var welcome_bytes: PackedByteArray = _sample_welcome().encode()
	var rejected_result: PackedByteArray = welcome_bytes.duplicate()
	rejected_result.encode_u8(4, 2)
	assert_null(NetMessages.Welcome.decode(rejected_result), "un WELCOME con result != 0")
	var bad_zone: PackedByteArray = welcome_bytes.duplicate()
	bad_zone.encode_u8(17, 33)
	bad_zone.resize(18 + 33)
	assert_null(NetMessages.Welcome.decode(bad_zone), "zone_len > 32")
	bad_zone = welcome_bytes.duplicate()
	bad_zone.encode_u8(17, 4)
	assert_null(NetMessages.Welcome.decode(bad_zone), "zone_len que no cuadra")
	bad_zone = welcome_bytes.duplicate()
	bad_zone[20] = 0xC3
	assert_null(NetMessages.Welcome.decode(bad_zone), "id de zona que no es ASCII")
	var reject_bytes: PackedByteArray = _sample_reject().encode()
	var accepted: PackedByteArray = reject_bytes.duplicate()
	accepted.encode_u8(4, 0)
	assert_null(NetMessages.Reject.decode(accepted), "un REJECT con result 0")
	var bad_text: PackedByteArray = reject_bytes.duplicate()
	bad_text.encode_u8(5, reject_bytes.decode_u8(5) - 1)
	assert_null(NetMessages.Reject.decode(bad_text), "text_len que no cuadra")

	# Textos que no son UTF-8 válido o llevan un byte nulo.
	for invalid: PackedByteArray in [PackedByteArray([0xFF]), PackedByteArray([0xC3]),
			PackedByteArray([0xC3, 0x28]), PackedByteArray([0xE2, 0x82]),
			PackedByteArray([0x41, 0x00]),
			PackedByteArray([0xED, 0xA0, 0x80]), PackedByteArray([0xC0, 0x80]),
			PackedByteArray([0xF5, 0x80, 0x80, 0x80])]:
		var notice_bytes := PackedByteArray([NetProtocol.MSG_NOTICE, 0, invalid.size()])
		notice_bytes.append_array(invalid)
		assert_null(NetMessages.Notice.decode(notice_bytes), "NOTICE con %s" % invalid)
		var named: PackedByteArray = hello_bytes.slice(0, 20)
		named.append(invalid.size())
		named.append_array(invalid)
		named.append_array(PackedByteArray([0, 0]))
		assert_null(NetMessages.Hello.decode(named), "HELLO con el nombre %s" % invalid)
	var valid_text := PackedByteArray([NetProtocol.MSG_NOTICE, 0, 7, 0x61, 0xC3, 0xB1,
			0xE2, 0x82, 0xAC, 0x7A])
	var valid_notice: NetMessages.Notice = NetMessages.Notice.decode(valid_text)
	if assert_not_null(valid_notice, "NOTICE con UTF-8 de 1, 2 y 3 bytes"):
		assert_eq(valid_notice.text, "añ€z", "texto")
	var long_notice := PackedByteArray([NetProtocol.MSG_NOTICE, 0, 201])
	long_notice.resize(3 + 201)
	long_notice.fill(0x61)
	long_notice.encode_u8(0, NetProtocol.MSG_NOTICE)
	long_notice.encode_u8(1, 0)
	long_notice.encode_u8(2, 201)
	assert_null(NetMessages.Notice.decode(long_notice), "NOTICE de más de 200 B")

	# SNAPSHOT: secciones que no cuadran.
	var with_state: PackedByteArray = _sample_snapshot(true, 3).encode()
	var without_state: PackedByteArray = _sample_snapshot(false, 3).encode()
	var bad_count: PackedByteArray = without_state.duplicate()
	bad_count.encode_u8(15, 4)
	assert_null(NetMessages.Snapshot.decode(bad_count), "count de sección mayor que los registros")
	bad_count.encode_u8(15, 2)
	assert_null(NetMessages.Snapshot.decode(bad_count), "count de sección menor que los registros")
	var bad_kind: PackedByteArray = without_state.duplicate()
	bad_kind.encode_u8(14, 9)
	assert_null(NetMessages.Snapshot.decode(bad_kind), "tipo de sección desconocido")
	bad_kind.encode_u8(14, NetProtocol.EntityKind.PROJECTILE)
	assert_null(NetMessages.Snapshot.decode(bad_kind), "los proyectiles no van en el snapshot (protocolo 6)")
	var bad_sections: PackedByteArray = without_state.duplicate()
	bad_sections.encode_u8(13, 2)
	assert_null(NetMessages.Snapshot.decode(bad_sections), "section_count mayor que las secciones")
	bad_sections.encode_u8(13, 0)
	assert_null(NetMessages.Snapshot.decode(bad_sections), "section_count 0 con registros detrás")
	var flag_without_state: PackedByteArray = without_state.duplicate()
	flag_without_state.encode_u8(12, 1)
	assert_null(NetMessages.Snapshot.decode(flag_without_state),
			"bit de estado propio sin el estado")
	assert_null(NetMessages.Snapshot.decode(with_state.slice(0, 40)),
			"truncado dentro del estado propio")
	assert_null(NetMessages.Snapshot.decode(with_state.slice(0, 13 + PlayerState.ENCODED_SIZE + 4)),
			"truncado dentro del bloque extra")
	assert_null(NetMessages.Snapshot.decode(with_state.slice(0, HEADER_WITH_STATE - 1)),
			"sin section_count")

	# SPAWN.
	var spawn_bytes: PackedByteArray = _sample_spawn().encode()
	var spawn_name_offset: int = 10 + PlayerState.ENCODED_SIZE
	var bad_spawn: PackedByteArray = spawn_bytes.duplicate()
	bad_spawn.encode_u8(spawn_name_offset, spawn_bytes.decode_u8(spawn_name_offset) + 1)
	assert_null(NetMessages.EntitySpawn.decode(bad_spawn), "name_len que no cuadra")
	bad_spawn.encode_u8(spawn_name_offset, 49)
	assert_null(NetMessages.EntitySpawn.decode(bad_spawn), "name_len > 48")
	bad_spawn = spawn_bytes.duplicate()
	bad_spawn.encode_u8(3, NetProtocol.EntityKind.STRUCTURE)
	assert_null(NetMessages.EntitySpawn.decode(bad_spawn), "kind sin formato en la fase 2")
	bad_spawn.encode_u8(3, 0)
	assert_null(NetMessages.EntitySpawn.decode(bad_spawn), "kind NONE")

	# Tipos reservados: nadie los decodifica todavía. (OBJECT_STATE ya no lo es: sus pruebas están en
	# test_net_messages_v3.gd.)
	for reserved: int in [NetProtocol.MSG_HANDOFF]:
		var bytes := PackedByteArray([reserved, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
		for decoder: Callable in _decoders():
			assert_null(decoder.call(bytes), "tipo reservado 0x%02X" % reserved)


func test_fuzz_random_buffers_never_error() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = FUZZ_SEED
	var decoders: Array[Callable] = _decoders()
	var samples: Array = _sample_messages()
	var type_bytes: Array[int] = [NetProtocol.MSG_INPUT_BATCH, NetProtocol.MSG_CLIENT_READY,
			NetProtocol.MSG_CLIENT_LEAVE, NetProtocol.MSG_DEBUG_COMMAND, NetProtocol.MSG_SNAPSHOT,
			NetProtocol.MSG_ENTITY_SPAWN, NetProtocol.MSG_ENTITY_DESPAWN, NetProtocol.MSG_NOTICE,
			NetProtocol.MSG_ENTITY_EVENT, NetProtocol.MSG_RESPAWN_REQUEST, NetProtocol.MSG_LOADOUT_SELECT]
	var decoded_count: int = 0
	var mutated_decoded: int = 0
	for i: int in FUZZ_BUFFERS:
		var bytes := PackedByteArray()
		var mode: int = i % 4
		if mode == 0:
			# Bytes totalmente aleatorios, de tamaño variable (a menudo pequeño).
			var length: int = rng.randi_range(0, 40)
			if rng.randf() >= 0.6:
				length = rng.randi_range(0, 1300)
			bytes.resize(length)
			for j: int in length:
				bytes[j] = rng.randi() & 0xFF
		elif mode == 1:
			# Un tipo de mensaje válido seguido de bytes aleatorios.
			var length: int = rng.randi_range(1, 120)
			bytes.resize(length)
			for j: int in length:
				bytes[j] = rng.randi() & 0xFF
			bytes[0] = type_bytes[rng.randi() % type_bytes.size()]
		elif mode == 2:
			# Autenticación: el magic seguido de bytes aleatorios.
			var length: int = rng.randi_range(4, 90)
			bytes.resize(length)
			for j: int in length:
				bytes[j] = rng.randi() & 0xFF
			bytes.encode_u32(0, NetProtocol.MAGIC)
			if length > 4 and rng.randf() < 0.5:
				bytes[4] = 0 if rng.randf() < 0.5 else rng.randi_range(1, 9)
		else:
			# Un mensaje válido con algunos bytes cambiados, recortado o ampliado.
			bytes = (samples[rng.randi() % samples.size()][1] as PackedByteArray).duplicate()
			for _k: int in rng.randi_range(0, 3):
				bytes[rng.randi() % bytes.size()] = rng.randi() & 0xFF
			var roll: float = rng.randf()
			if roll < 0.2:
				bytes.resize(rng.randi_range(0, bytes.size()))
			elif roll < 0.3:
				bytes.append(rng.randi() & 0xFF)
		for decoder: Callable in decoders:
			var result: Variant = decoder.call(bytes)
			if result != null:
				decoded_count += 1
				if mode == 3:
					mutated_decoded += 1
				if result is NetMessages.InputBatch:
					var batch: NetMessages.InputBatch = result
					assert_true(batch.inputs.size() >= 1 and batch.inputs.size() <= 8,
							"un lote decodificado tiene de 1 a 8 entradas")
					for input: PlayerInput in batch.inputs:
						assert_eq(input.buttons & ~NetProtocol.VALID_BUTTONS, 0,
								"botones enmascarados")
						assert_true(input.move.length() <= 1.0 + 1e-6, "movimiento acotado")
	assert_true(mutated_decoded > 100,
			"el fuzz llega hasta mensajes válidos (%d)" % mutated_decoded)
	assert_true(decoded_count >= mutated_decoded, "contadores coherentes")


# --- Utilidades -------------------------------------------------------------------------------

func _decoders() -> Array[Callable]:
	var result: Array[Callable] = [
		NetMessages.Hello.decode, NetMessages.Welcome.decode, NetMessages.Reject.decode,
		NetMessages.InputBatch.decode, NetMessages.ClientReady.decode,
		NetMessages.ClientLeave.decode, NetMessages.DebugCommand.decode,
		NetMessages.Snapshot.decode, NetMessages.EntitySpawn.decode,
		NetMessages.EntityDespawn.decode, NetMessages.Notice.decode,
		NetMessages.EntityEvent.decode, NetMessages.RespawnRequest.decode,
		NetMessages.LoadoutSelect.decode,
	]
	return result


## [etiqueta, bytes válidos, decodificador] de un mensaje de cada tipo (con los del protocolo 6:
## LOADOUT_SELECT, el SPAWN de un proyectil, los ENTITY_EVENT 7 a 11 y un comando de depuración nuevo).
func _sample_messages() -> Array:
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = 77
	despawn.despawn_tick = 1000
	var notice := NetMessages.Notice.new()
	notice.text = "Servidor cerrándose"
	return [
		["HELLO", _sample_hello().encode(), NetMessages.Hello.decode],
		["WELCOME", _sample_welcome().encode(), NetMessages.Welcome.decode],
		["REJECT", _sample_reject().encode(), NetMessages.Reject.decode],
		["INPUT_BATCH", _sample_input_batch(5).encode(), NetMessages.InputBatch.decode],
		["CLIENT_READY", NetMessages.ClientReady.new().encode(), NetMessages.ClientReady.decode],
		["CLIENT_LEAVE", NetMessages.ClientLeave.new().encode(), NetMessages.ClientLeave.decode],
		["DEBUG_COMMAND", NetMessages.DebugCommand.teleport(Vector3(1, 2, 3)).encode(),
				NetMessages.DebugCommand.decode],
		["SNAPSHOT", _sample_snapshot(true, 4).encode(), NetMessages.Snapshot.decode],
		["ENTITY_SPAWN", _sample_spawn().encode(), NetMessages.EntitySpawn.decode],
		["ENTITY_DESPAWN", despawn.encode(), NetMessages.EntityDespawn.decode],
		["NOTICE", notice.encode(), NetMessages.Notice.decode],
		["ENTITY_EVENT HIT", _sample_hit().encode(), NetMessages.EntityEvent.decode],
		["ENTITY_EVENT DEATH", _sample_death().encode(), NetMessages.EntityEvent.decode],
		["ENTITY_EVENT KILL", _sample_kill().encode(), NetMessages.EntityEvent.decode],
		["ENTITY_EVENT RESPAWN", _sample_respawn().encode(), NetMessages.EntityEvent.decode],
		["RESPAWN_REQUEST", _sample_respawn_request().encode(),
				NetMessages.RespawnRequest.decode],
		["LOADOUT_SELECT", NetMessages.LoadoutSelect.make(1).encode(), NetMessages.LoadoutSelect.decode],
		["ENTITY_SPAWN PROJECTILE", NetMessages.EntitySpawn.for_projectile(901, 5000, 1, 4242, 1, 2, 0,
				false, Vector3(1.0, 2.0, 3.0), Vector3(40.0, 1.0, -5.0)).encode(),
				NetMessages.EntitySpawn.decode],
		["DEBUG_COMMAND apply_status", NetMessages.DebugCommand.apply_status(2, 300).encode(),
				NetMessages.DebugCommand.decode],
		["ENTITY_EVENT STATUS", NetMessages.EntityEvent.status(321, 9, 654,
				NetMessages.EntityEvent.StatusOp.APPLIED, 3, 1, 400).encode(), NetMessages.EntityEvent.decode],
		["ENTITY_EVENT HEAL", NetMessages.EntityEvent.heal(321, 9, 0, 50, 0x8002).encode(),
				NetMessages.EntityEvent.decode],
		["ENTITY_EVENT LOADOUT", NetMessages.EntityEvent.loadout(321, 9, 2, 3, 1, 0x23).encode(),
				NetMessages.EntityEvent.decode],
		["ENTITY_EVENT DOWNED", NetMessages.EntityEvent.downed(321, 9, 654, 0x4001).encode(),
				NetMessages.EntityEvent.decode],
		["ENTITY_EVENT INTERACT", NetMessages.EntityEvent.interact(321, 9, 655,
				NetMessages.EntityEvent.InteractOp.REVIVE, 189).encode(), NetMessages.EntityEvent.decode],
	]


func _sample_hello() -> NetMessages.Hello:
	var hello := NetMessages.Hello.new()
	hello.sim_hash = 0xDEADBEEF
	hello.realm = NetProtocol.Realm.SOLMARCH
	hello.flags = NetMessages.Hello.FLAG_BOT
	hello.character_id = 0x0123456789ABCDEF
	hello.display_name = "Ñandú-Ana"
	hello.ticket = PackedByteArray([1, 2, 3, 4, 5])
	return hello


func _sample_welcome() -> NetMessages.Welcome:
	var welcome := NetMessages.Welcome.new()
	welcome.server_tick = 123456
	welcome.realm = NetProtocol.Realm.ASKARRA
	welcome.zone_id = "vado_gris"
	welcome.realm_counts = PackedInt32Array([4, 0, 300])
	return welcome


func _sample_reject() -> NetMessages.Reject:
	var reject := NetMessages.Reject.new()
	reject.result = NetProtocol.Result.REALM
	reject.text = NetProtocol.result_text(NetProtocol.Result.REALM)
	return reject


func _sample_input_batch(count: int) -> NetMessages.InputBatch:
	var rng := RandomNumberGenerator.new()
	rng.seed = count
	var batch := NetMessages.InputBatch.new()
	batch.ack_snapshot_tick = 500
	batch.interp_delay_q = 40
	batch.newest_tick = 600
	for i: int in count:
		batch.inputs.append(_random_input(rng, 600 - count + 1 + i))
		batch.view_offsets_q.append(i * 20)
	return batch


func _sample_snapshot(with_state: bool, record_count: int) -> NetMessages.Snapshot:
	var snapshot := NetMessages.Snapshot.new()
	snapshot.server_tick = 90001
	snapshot.input_ack_tick = 90000
	snapshot.input_margin = -3
	snapshot.substitutions = 65535
	snapshot.own_teleport = 2
	if with_state:
		var state := PlayerState.new()
		state.position = Vector3(10.5, 0.25, -30.125)
		state.velocity = Vector3(1.0, -2.0, 3.5)
		state.yaw = PlayerState.to_f32(1.5)
		state.grounded = true
		state.prev_buttons = PlayerInput.SPRINT
		state.last_input_tick = 90001
		state.coyote_ticks = 2
		state.jump_buffer_ticks = 5
		snapshot.own_state = state
		snapshot.health = 845
		snapshot.max_health = 1000
		snapshot.status = NetMessages.STATUS_IN_COMBAT | NetMessages.STATUS_DEAD
		snapshot.respawn_tick = 123456
	var positions: Array[Vector3] = [
		Vector3(-1234.567, 45.678, 4999.994), Vector3(0.0, 0.0, 0.0),
		Vector3(5242.0, -5000.0, 17.77), Vector3(1.0, 2.0, 3.0),
	]
	for i: int in record_count:
		var record := EntityRecord.new()
		record.net_id = 3 + i * 100
		record.position = positions[i % positions.size()]
		record.yaw = 0.7 * i
		record.velocity = Vector3(5.0 - i, -3.0 * i, 400.0 if i == 1 else 0.5)
		record.flags = EntityRecord.FLAG_GROUNDED
		if i % 2 == 1:
			record.flags = 3 << EntityRecord.TELEPORT_SHIFT
		record.action = i
		record.health_q = 255 - 40 * i
		snapshot.records.append(record)
	return snapshot


func _sample_hit() -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.hit(321, 123456, 654, 243, DamageFormula.DamageType.BLUNT,
			NetMessages.EntityEvent.HIT_FLAG_CRITICAL | NetMessages.EntityEvent.HIT_FLAG_LETHAL, 4)


func _sample_death() -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.death(321, 123457, 654, 4)


func _sample_kill() -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.kill(321, 123457, 654, 4, PackedInt32Array([700, 701]))


func _sample_respawn() -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.respawn(321, 124057, 2)


func _sample_respawn_request() -> NetMessages.RespawnRequest:
	var request := NetMessages.RespawnRequest.new()
	request.point_index = 3
	return request


func _sample_spawn() -> NetMessages.EntitySpawn:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = 4242
	spawn.spawn_tick = 654321
	spawn.realm = NetProtocol.Realm.VARDHEIM
	spawn.is_yours = true
	spawn.teleport_counter = 1
	var state := PlayerState.new()
	state.position = Vector3(2.0, 0.0, -4.5)
	state.yaw = PlayerState.to_f32(3.0)
	state.grounded = true
	state.last_input_tick = 654321
	spawn.state = state
	spawn.display_name = "Brunhilda ñ"
	spawn.level = 12
	spawn.appearance = PackedByteArray([1, 0, 0, 1, 1, 3, 2, 1])
	return spawn


func _random_input(rng: RandomNumberGenerator, tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.move = Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)).limit_length(1.0)
	input.look_yaw = rng.randf_range(-10.0, 10.0)
	input.look_pitch = rng.randf_range(-PI / 2.0, PI / 2.0)
	input.buttons = rng.randi() & 0xFFFF
	return input


func _inputs_equal(a: PlayerInput, b: PlayerInput) -> bool:
	return a.tick == b.tick and a.move == b.move and a.look_yaw == b.look_yaw \
			and a.look_pitch == b.look_pitch and a.buttons == b.buttons


## Mueve un punto como lo haría el personaje, sin colisiones: 5 m/s (7,5 al esprintar hacia
## delante) en la dirección que dan [code]look_yaw[/code] y [code]move[/code].
func _walk(position: Vector3, input: PlayerInput) -> Vector3:
	var look_basis := Basis(Vector3.UP, input.look_yaw)
	var wish: Vector3 = (look_basis * Vector3.RIGHT * input.move.x \
			+ look_basis * Vector3.FORWARD * input.move.y).limit_length(1.0)
	var speed: float = 5.0
	if input.has(PlayerInput.SPRINT) and input.move.y > 0.5:
		speed = 7.5
	return position + wish * speed / 60.0


# --- Mundo con un personaje -------------------------------------------------------------------

## Suelo plano de 200 x 200 m con un [PlayerCharacter] en el origen.
func _make_world() -> bool:
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	_world = Node3D.new()
	_world.name = "NetMessagesTestWorld"
	tree.root.add_child(_world)
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = WORLD_LAYER
	floor_body.collision_mask = 0
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	var shape := CollisionShape3D.new()
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	_world.add_child(floor_body)

	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	if not assert_not_null(scene, "no se pudo cargar %s" % CHARACTER_SCENE_PATH):
		return false
	_character = scene.instantiate() as PlayerCharacter
	if not assert_not_null(_character,
			"la raíz de %s es un PlayerCharacter" % CHARACTER_SCENE_PATH):
		return false
	_world.add_child(_character)
	await wait_physics_frames(2)
	return true


func _state_at(position: Vector3, yaw: float, grounded: bool) -> PlayerState:
	var state := PlayerState.new()
	state.position = position
	state.yaw = yaw
	state.grounded = grounded
	return state


func _make_input(move: Vector2, look_yaw: float, buttons: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = _next_tick
	_next_tick += 1
	input.move = move
	input.look_yaw = look_yaw
	input.buttons = buttons
	return input.quantized()


func _step(move: Vector2, look_yaw: float, buttons: int, ticks: int = 1) -> void:
	for _i: int in ticks:
		_character.simulate(_make_input(move, look_yaw, buttons), _dt)


func _step_until_grounded() -> void:
	for _i: int in 120:
		_step(Vector2.ZERO, 0.0, 0)
		if _character.grounded:
			return
	fail("el personaje no llegó a tocar el suelo")


func _reset_counters() -> void:
	_jumped_count = 0
	_landed_count = 0


func _on_jumped() -> void:
	_jumped_count += 1


func _on_landed() -> void:
	_landed_count += 1
