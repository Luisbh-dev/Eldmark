extends TestCase
## Pruebas de la simulación de movimiento de PlayerCharacter.
##
## Cada prueba construye en código un mundo mínimo (suelo de 200 x 200 m en la capa 1, una rampa
## transitable de 25°, otra empinada de 55° y una plataforma de 1 m con bordes), instancia el
## personaje y llama a [method PlayerCharacter.simulate] en bucle con
## [code]delta = 1 / Engine.physics_ticks_per_second[/code], igual que harán el servidor y la
## predicción del cliente en la fase 2.
## [br][br]
## [b]Importante:[/b] move_and_slide() toma su delta del tick de física solo si se llama dentro
## de él ([method Engine.is_in_physics_frame]); fuera usa el delta de _process, que varía. Por eso
## cada prueba empieza con [method _begin] (que espera un paso de física) y no vuelve a esperar
## fotogramas entre llamadas a simulate(), salvo la que graba un tick por paso de física.
## [br][br]
## Las pruebas más importantes son las de repetición: restaurar un estado y repetir las mismas
## entradas debe reproducir exactamente la misma trayectoria desde cualquier tick, aunque el
## estado interno del CharacterBody3D (contacto con el suelo, normal del suelo) venga de otra
## situación. Es lo que hará la reconciliación de la fase 2 cada vez que llegue un estado del
## servidor.

## Cómo se "ensucia" el estado interno del CharacterBody3D antes de restaurar un estado.
enum Pollution {
	AIRBORNE, ## El cuerpo viene de estar cayendo en el aire (sin contacto con el suelo).
	GROUNDED, ## El cuerpo viene de estar apoyado en el suelo, en otro sitio.
}

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const WORLD_LAYER: int = 1
const FLAT_SPAWN: Vector3 = Vector3(0.0, 0.0, 0.0)
const RAMP_THICKNESS: float = 0.5
const RAMP_WIDTH: float = 10.0
## Centro del borde inferior de la rampa de 25°, que sube hacia -Z (ligeramente hundido para que
## no haya escalón con el suelo).
const RAMP_FOOT: Vector3 = Vector3(20.0, -0.02, 0.0)
const RAMP_ANGLE_DEG: float = 25.0
const RAMP_LENGTH: float = 12.0
const STEEP_RAMP_FOOT: Vector3 = Vector3(-20.0, -0.02, 0.0)
const STEEP_RAMP_ANGLE_DEG: float = 55.0
const STEEP_RAMP_LENGTH: float = 8.0
## Plataforma de 1 m de alto, lejos del resto, para caer por un borde.
const LEDGE_CENTER: Vector3 = Vector3(-40.0, 0.5, 30.0)
const LEDGE_SIZE: Vector3 = Vector3(10.0, 1.0, 10.0)
## Salida sobre la plataforma, a 9 m de su borde -Z.
const LEDGE_START: Vector3 = Vector3(-40.0, 1.0, 34.0)
## Salida del recorrido de la prueba de repetición: 6 m delante de la rampa de 25°.
const REPLAY_START: Vector3 = Vector3(20.0, 0.0, 6.0)
const REPLAY_TICKS: int = 180
## Tolerancia de las repeticiones en el mismo proceso. En la práctica son exactas bit a bit;
## cualquier estado oculto que no viaje en PlayerState (como la escala que acumulaba el nodo al
## girar) hace que la trayectoria se separe bastante más que esto.
const REPLAY_EPSILON: float = 1e-6
## Repeticiones que divergen que se describen en el mensaje de fallo (el resto solo se cuentan).
const MAX_REPORTED_REPLAYS: int = 3
## Zona despejada donde se ensucia el estado interno antes de restaurar.
const POLLUTION_SPOT: Vector3 = Vector3(0.0, 0.0, 60.0)
const REPLAY_HINT: String = (
	"Pista: tras set_state(), el estado interno de CharacterBody3D (is_on_floor(), normal del "
	+ "suelo) sigue siendo el de la última move_and_slide(); simulate() debe resincronizarlo con "
	+ "'grounded'. Y nada que influya en la colisión (como la escala del nodo) puede depender "
	+ "de la historia: todo debe salir de PlayerState."
)

var _world: Node3D
var _character: PlayerCharacter
var _dt: float = 1.0 / 60.0
var _next_tick: int = 1
var _jumped_count: int = 0
var _landed_count: int = 0


func before_each() -> void:
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	_world = Node3D.new()
	_world.name = "MovementTestWorld"
	tree.root.add_child(_world)
	_add_static_box("Floor", Vector3(200.0, 1.0, 200.0), Vector3(0.0, -0.5, 0.0), 0.0)
	_add_ramp("Ramp", RAMP_FOOT, RAMP_ANGLE_DEG, RAMP_LENGTH)
	_add_ramp("SteepRamp", STEEP_RAMP_FOOT, STEEP_RAMP_ANGLE_DEG, STEEP_RAMP_LENGTH)
	_add_static_box("Ledge", LEDGE_SIZE, LEDGE_CENTER, 0.0)

	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	if not assert_not_null(scene, "no se pudo cargar %s" % CHARACTER_SCENE_PATH):
		return
	var instance: Node = scene.instantiate()
	_character = instance as PlayerCharacter
	if not assert_not_null(_character,
			"la raíz de %s debe ser un PlayerCharacter" % CHARACTER_SCENE_PATH):
		if instance != null:
			instance.free()
		return
	_character.jumped.connect(_on_jumped)
	_character.landed.connect(_on_landed)
	_world.add_child(_character)
	# Dos ticks para que el espacio de física registre los cuerpos recién añadidos.
	await wait_physics_frames(2)


func after_each() -> void:
	if is_instance_valid(_world):
		# Se saca del árbol ya (los cuerpos salen del espacio de física) y se libera después.
		_world.get_parent().remove_child(_world)
		_world.queue_free()
	_world = null
	_character = null
	await wait_process_frames()


# --- Configuración ----------------------------------------------------------------------------

func test_character_configuration() -> void:
	if not await _begin():
		return
	assert_eq(_character.collision_layer, 2, "collision_layer (capa 2 = personajes)")
	assert_eq(_character.collision_mask, 1, "collision_mask (solo la capa 1, mundo estático)")
	assert_near(_character.floor_max_angle, deg_to_rad(46.0), 1e-4, "floor_max_angle")
	assert_near(_character.floor_snap_length, 0.35, 1e-4, "floor_snap_length")
	assert_true(_character.floor_constant_speed, "floor_constant_speed")
	assert_true(_character.floor_stop_on_slope, "floor_stop_on_slope")
	assert_true(_character.jump_buffer_window <= PlayerState.MAX_JUMP_BUFFER_TICKS,
			"jump_buffer_window cabe en el estado de red")
	assert_true(_character.coyote_window <= PlayerState.MAX_COYOTE_TICKS,
			"coyote_window cabe en el estado de red")

	var target: Node3D = _character.get_camera_target()
	if assert_not_null(target, "get_camera_target()"):
		assert_eq(target.name, "CameraTarget", "nombre del objetivo de cámara")
		assert_true(_character.is_ancestor_of(target), "CameraTarget debe ser hijo del personaje")
		assert_near(target.position.y, 1.6, 0.05, "CameraTarget a la altura de la cabeza")

	var collision: CollisionShape3D = _character.get_node_or_null(^"Collision") as CollisionShape3D
	if assert_not_null(collision, "nodo Collision (CollisionShape3D)"):
		var capsule: CapsuleShape3D = collision.shape as CapsuleShape3D
		if assert_not_null(capsule, "Collision debe usar un CapsuleShape3D"):
			assert_near(capsule.radius, 0.4, 1e-3, "radio de la cápsula")
			assert_near(capsule.height, 1.8, 1e-3, "altura de la cápsula")
		assert_near(collision.position.y, 0.9, 1e-3,
				"la cápsula empieza en el origen: origen en los pies")


# --- Caída, carrera y velocidades -------------------------------------------------------------

func test_falls_and_lands_from_one_meter() -> void:
	if not await _begin():
		return
	_place(Vector3(0.0, 1.0, 0.0), 0.0, false)
	_reset_counters()
	_step(Vector2.ZERO, 0.0)
	assert_false(_character.grounded, "tras el primer tick de caída no puede estar en el suelo")
	assert_true(_character.global_position.y < 1.0, "debe empezar a caer")

	var landed_tick: int = -1
	for tick: int in range(2, 91):
		_step(Vector2.ZERO, 0.0)
		if _character.grounded:
			landed_tick = tick
			break
	# Caída libre de 1 m: t = sqrt(2 / g), unos 18-19 ticks con g = 22.
	var expected_ticks: int = ceili(sqrt(2.0 / _character.gravity)
			* Engine.physics_ticks_per_second)
	assert_true(landed_tick >= expected_ticks - 4 and landed_tick <= expected_ticks + 6,
			"debe aterrizar hacia el tick %d (aterrizó en el %d)" % [expected_ticks, landed_tick])
	assert_near(_character.global_position.y, 0.0, 0.05,
			"aterriza con los pies sobre el suelo (y = 0)")
	assert_near(_character.velocity.y, 0.0, 0.01, "al aterrizar se anula la velocidad vertical")
	assert_eq(_landed_count, 1, "landed se emite una vez al aterrizar")
	assert_eq(_jumped_count, 0, "jumped no se emite al caer")

	# En reposo debe seguir en el suelo sin parpadeos de 'grounded'.
	for i: int in 60:
		_step(Vector2.ZERO, 0.0)
		if not _character.grounded:
			fail("en reposo sobre el suelo, 'grounded' pasó a false en el tick %d" % i)
			break
	assert_near(_character.global_position.y, 0.0, 0.05, "sigue a ras de suelo")
	assert_near(_character.get_horizontal_speed(), 0.0, 1e-4, "sin deriva horizontal en reposo")
	assert_eq(_landed_count, 1, "landed no se repite mientras sigue en el suelo")


func test_runs_forward_at_run_speed() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	var start: Vector3 = _character.global_position
	_step(Vector2(0.0, 1.0), 0.0, 0, 60)
	var velocity: Vector3 = _character.velocity
	assert_vec_near(Vector3(velocity.x, 0.0, velocity.z),
			Vector3(0.0, 0.0, -_character.run_speed), 0.05,
			"tras 60 ticks hacia delante con look_yaw 0 corre a run_speed hacia -Z")
	assert_near(_character.get_horizontal_speed(), _character.run_speed, 0.05,
			"get_horizontal_speed()")
	var moved: Vector3 = _character.global_position - start
	assert_true(moved.z < -0.85 * _character.run_speed,
			"en 1 s debe avanzar casi run_speed metros hacia -Z (avanzó %.3f)" % -moved.z)
	assert_true(moved.z > -_character.run_speed - 0.01,
			"en 1 s no puede avanzar más de run_speed metros (avanzó %.3f)" % -moved.z)
	assert_near(moved.x, 0.0, 0.01, "sin deriva lateral")
	assert_near(_character.global_position.y, 0.0, 0.05, "sigue a ras de suelo")
	assert_true(_character.grounded, "sigue en el suelo")


func test_movement_is_relative_to_look_yaw() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	# look_yaw = PI/2 mira hacia -X: "adelante" es -X.
	_step(Vector2(0.0, 1.0), PI / 2.0, 0, 60)
	assert_vec_near(_horizontal_velocity(), Vector3(-_character.run_speed, 0.0, 0.0), 0.05,
			"adelante con look_yaw PI/2 va hacia -X")
	_step(Vector2.ZERO, PI / 2.0, 0, 30)

	# Derecha con look_yaw 0 es +X, a velocidad lateral.
	_step(Vector2(1.0, 0.0), 0.0, 0, 60)
	assert_vec_near(_horizontal_velocity(),
			Vector3(_character.run_speed * _character.strafe_multiplier, 0.0, 0.0), 0.05,
			"derecha con look_yaw 0 va hacia +X a run_speed * strafe_multiplier")

	# Diagonal (1, 1): se limita a longitud 1 y no cuenta como lateral (|x| == |y|).
	_step(Vector2(1.0, 1.0), 0.0, 0, 60)
	assert_near(_character.get_horizontal_speed(), _character.run_speed, 0.05,
			"en diagonal la velocidad es run_speed (el deseo se limita a longitud 1)")
	assert_vec_near(_horizontal_velocity().normalized(), Vector3(1.0, 0.0, -1.0).normalized(),
			0.01, "la diagonal adelante-derecha va hacia (+X, -Z)")


func test_sprint_is_faster_than_run() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_step(Vector2(0.0, 1.0), 0.0, PlayerInput.SPRINT, 60)
	assert_vec_near(_horizontal_velocity(), Vector3(0.0, 0.0, -_character.sprint_speed), 0.05,
			"esprintando hacia delante va a sprint_speed")
	assert_true(_character.sprint_speed > _character.run_speed + 1.0,
			"sprint_speed debe superar claramente a run_speed")

	# El esprint solo cuenta hacia delante: hacia atrás se ignora.
	_step(Vector2(0.0, -1.0), 0.0, PlayerInput.SPRINT, 90)
	assert_near(_character.get_horizontal_speed(),
			_character.run_speed * _character.backward_multiplier, 0.05,
			"hacia atrás el esprint no tiene efecto")

	# Ni en lateral puro.
	_step(Vector2(1.0, 0.0), 0.0, PlayerInput.SPRINT, 90)
	assert_near(_character.get_horizontal_speed(),
			_character.run_speed * _character.strafe_multiplier, 0.05,
			"en lateral el esprint no tiene efecto")


func test_backward_is_slower() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_step(Vector2(0.0, -1.0), 0.0, 0, 60)
	var expected: float = _character.run_speed * _character.backward_multiplier
	assert_vec_near(_horizontal_velocity(), Vector3(0.0, 0.0, expected), 0.05,
			"hacia atrás con look_yaw 0 va hacia +Z a run_speed * backward_multiplier")
	assert_true(_character.get_horizontal_speed() < _character.run_speed - 0.5,
			"hacia atrás es más lento que correr")


func test_stops_when_input_released() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_step(Vector2(0.0, 1.0), 0.0, 0, 60)
	_step(Vector2.ZERO, 0.0)
	assert_true(_character.get_horizontal_speed() > 0.5, "frena con deceleración, no en seco")
	_step(Vector2.ZERO, 0.0, 0, 14)
	assert_near(_character.get_horizontal_speed(), 0.0, 0.01,
			"en el suelo se para en menos de 15 ticks")
	var stopped_at: Vector3 = _character.global_position
	_step(Vector2.ZERO, 0.0, 0, 30)
	assert_vec_near(_character.global_position, stopped_at, 0.005, "parado no se desliza")


# --- Salto y aire -----------------------------------------------------------------------------

func test_jump_apex_and_landing() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_reset_counters()
	var ground_y: float = _character.global_position.y
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	assert_eq(_jumped_count, 1, "jumped se emite en el tick del salto")
	assert_near(_character.velocity.y, _character.jump_velocity, _character.gravity * _dt + 1e-3,
			"la velocidad vertical tras saltar es jump_velocity")
	assert_false(_character.grounded, "tras saltar ya no está en el suelo")

	var apex: float = _character.global_position.y
	var landed_tick: int = -1
	for tick: int in range(2, 121):
		_step(Vector2.ZERO, 0.0)
		apex = maxf(apex, _character.global_position.y)
		if _character.grounded:
			landed_tick = tick
			break
	var expected_apex: float = (_character.jump_velocity * _character.jump_velocity
			/ (2.0 * _character.gravity))
	assert_near(apex - ground_y, expected_apex, expected_apex * 0.08,
			"altura máxima del salto ≈ jump_velocity² / (2 · gravity)")
	var expected_air_ticks: int = roundi(2.0 * _character.jump_velocity / _character.gravity
			* Engine.physics_ticks_per_second)
	assert_true(landed_tick >= expected_air_ticks - 4 and landed_tick <= expected_air_ticks + 6,
			"debe aterrizar hacia el tick %d (aterrizó en el %d)" % [
				expected_air_ticks, landed_tick,
			])
	assert_eq(_landed_count, 1, "landed se emite una vez al aterrizar")
	assert_near(_character.global_position.y, ground_y, 0.05, "vuelve a ras de suelo")


func test_holding_jump_only_jumps_once() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_reset_counters()
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP, 150)
	assert_eq(_jumped_count, 1, "mantener el salto pulsado solo salta una vez (flanco de subida)")
	assert_eq(_landed_count, 1, "aterriza una vez")
	assert_true(_character.grounded, "acaba en el suelo aunque siga pulsado")
	_step(Vector2.ZERO, 0.0, 0)
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	assert_eq(_jumped_count, 2, "soltar y volver a pulsar salta otra vez")


func test_no_second_jump_in_the_air() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_reset_counters()
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	# Volver a pulsar enseguida (dentro de lo que duraría el coyote time) no salta otra vez.
	for _i: int in 4:
		_step(Vector2.ZERO, 0.0, 0)
		_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	assert_false(_character.grounded, "sigue en el aire")
	assert_eq(_jumped_count, 1, "en el aire no hay segundo salto (saltar agota el coyote time)")


func test_jump_pressed_just_before_landing_is_buffered() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	_step(Vector2.ZERO, 0.0, 0)
	var airborne: PlayerState = _character.get_state()
	# Tick (contando desde 'airborne') en el que vuelve a tocar el suelo sin pulsar nada.
	var landing_tick: int = 0
	while not _character.grounded and landing_tick < 120:
		_step(Vector2.ZERO, 0.0, 0)
		landing_tick += 1
	if not assert_true(_character.grounded, "el salto debe acabar en el suelo"):
		return

	# La pulsación vale durante jump_buffer_window ticks contando el suyo; el salto ocurre en el
	# primer tick en el suelo (landing_tick + 1).
	var window: int = _character.jump_buffer_window
	for early: int in [0, 1, window - 2, window, window + 3]:
		var press_tick: int = landing_tick - early
		var should_jump: bool = landing_tick + 1 - press_tick <= window - 1
		_character.set_state(airborne)
		_reset_counters()
		for tick: int in range(1, landing_tick + 8):
			# Se pulsa en press_tick y se mantiene: no hay más flancos de subida.
			_step(Vector2.ZERO, 0.0, PlayerInput.JUMP if tick >= press_tick else 0)
		var label: String = "salto pulsado %d ticks antes de tocar el suelo" % early
		if should_jump:
			assert_eq(_jumped_count, 1, "%s: debe saltar al aterrizar (búfer)" % label)
		else:
			assert_eq(_jumped_count, 0, "%s: demasiado pronto, no debe saltar" % label)


func test_coyote_time_after_walking_off_a_ledge() -> void:
	if not await _begin() or not _settle(LEDGE_START):
		return
	# Camina hacia el borde -Z de la plataforma hasta dejar de pisarla.
	var walked: int = 0
	while _character.grounded and walked < 240:
		_step(Vector2(0.0, 1.0), 0.0, 0)
		walked += 1
	if not assert_false(_character.grounded, "debe salir de la plataforma por el borde"):
		return
	var left_ledge: PlayerState = _character.get_state()
	assert_true(left_ledge.position.y > 0.6, "acaba de dejar la plataforma de 1 m")

	# Se puede saltar durante coyote_window ticks en el aire; después ya no.
	var window: int = _character.coyote_window
	for delay: int in [1, 2, window, window + 2]:
		_character.set_state(left_ledge)
		_reset_counters()
		_step(Vector2(0.0, 1.0), 0.0, 0, delay - 1)
		_step(Vector2(0.0, 1.0), 0.0, PlayerInput.JUMP)
		var label: String = "salto pulsado en el tick %d en el aire" % delay
		if delay <= window:
			assert_eq(_jumped_count, 1, "%s: el coyote time debe permitirlo" % label)
			assert_near(_character.velocity.y, _character.jump_velocity, 1e-3,
					"%s: sale con jump_velocity" % label)
			# Y no deja un segundo salto en el aire.
			_step(Vector2(0.0, 1.0), 0.0, 0)
			_step(Vector2(0.0, 1.0), 0.0, PlayerInput.JUMP)
			assert_eq(_jumped_count, 1, "%s: tras el salto no hay otro en el aire" % label)
		else:
			assert_eq(_jumped_count, 0, "%s: el coyote time ya ha pasado" % label)


func test_sprint_jump_keeps_momentum() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	var sprint_jump: int = PlayerInput.SPRINT | PlayerInput.JUMP
	_step(Vector2(0.0, 1.0), 0.0, PlayerInput.SPRINT, 60)
	_reset_counters()
	_step(Vector2(0.0, 1.0), 0.0, sprint_jump)
	assert_eq(_jumped_count, 1, "salta esprintando")
	var slowest: float = _character.get_horizontal_speed()
	var air_ticks: int = 0
	while not _character.grounded and air_ticks < 120:
		_step(Vector2(0.0, 1.0), 0.0, sprint_jump)
		slowest = minf(slowest, _character.get_horizontal_speed())
		air_ticks += 1
	assert_true(air_ticks > 30, "el salto dura más de medio segundo (%d ticks)" % air_ticks)
	assert_near(slowest, _character.sprint_speed, 0.05,
			"en el aire conserva la velocidad del esprint (mínimo %.3f m/s)" % slowest)
	assert_near(_character.get_horizontal_speed(), _character.sprint_speed, 0.05,
			"aterriza a sprint_speed")

	# Soltar el esprint en el aire, siguiendo hacia delante, tampoco frena hasta aterrizar.
	_step(Vector2(0.0, 1.0), 0.0, PlayerInput.SPRINT, 5)
	_step(Vector2(0.0, 1.0), 0.0, sprint_jump)
	_step(Vector2(0.0, 1.0), 0.0, 0, 20)
	assert_false(_character.grounded, "sigue en el aire")
	assert_near(_character.get_horizontal_speed(), _character.sprint_speed, 0.05,
			"sin esprint en el aire mantiene el impulso que traía")


func test_running_off_a_ledge_while_sprinting_keeps_momentum() -> void:
	if not await _begin() or not _settle(LEDGE_START):
		return
	var walked: int = 0
	while _character.grounded and walked < 240:
		_step(Vector2(0.0, 1.0), 0.0, PlayerInput.SPRINT)
		walked += 1
	if not assert_false(_character.grounded, "debe salir de la plataforma por el borde"):
		return
	var slowest: float = _character.get_horizontal_speed()
	var air_ticks: int = 0
	while not _character.grounded and air_ticks < 120:
		_step(Vector2(0.0, 1.0), 0.0, PlayerInput.SPRINT)
		slowest = minf(slowest, _character.get_horizontal_speed())
		air_ticks += 1
	assert_true(_character.grounded, "aterriza al pie de la plataforma")
	assert_near(slowest, _character.sprint_speed, 0.05,
			"al caer por el borde conserva la velocidad del esprint (mínimo %.3f m/s)" % slowest)


func test_air_control_is_limited() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_step(Vector2(0.0, 1.0), 0.0, 0, 60)
	_step(Vector2(0.0, 1.0), 0.0, PlayerInput.JUMP)
	_step(Vector2.ZERO, 0.0, 0, 10)
	assert_false(_character.grounded, "sigue en el aire 10 ticks después de saltar")
	var speed: float = _character.get_horizontal_speed()
	# En el suelo se habría parado del todo; en el aire solo pierde un poco de velocidad.
	assert_true(speed > _character.run_speed - 1.5 and speed < _character.run_speed - 0.3,
			"sin entrada en el aire conserva casi toda la velocidad (%.3f m/s)" % speed)
	_step(Vector2(0.0, 1.0), 0.0, PlayerInput.SPRINT, 15)
	assert_false(_character.grounded, "sigue en el aire")
	assert_true(_character.get_horizontal_speed() <= _character.run_speed + 0.01,
			"en el aire el esprint no acelera por encima de run_speed (%.3f m/s)"
			% _character.get_horizontal_speed())


func test_fall_speed_is_clamped_to_terminal_velocity() -> void:
	if not await _begin():
		return
	_place(Vector3(0.0, 150.0, 0.0), 0.0, false)
	var lowest_vertical_speed: float = 0.0
	for _i: int in 180:
		_step(Vector2.ZERO, 0.0)
		lowest_vertical_speed = minf(lowest_vertical_speed, _character.velocity.y)
	assert_false(_character.grounded, "tras 3 s de caída desde 150 m sigue en el aire")
	assert_true(lowest_vertical_speed >= -_character.terminal_velocity - 1e-3,
			"nunca cae más rápido que terminal_velocity (llegó a %.3f)" % lowest_vertical_speed)
	assert_near(_character.velocity.y, -_character.terminal_velocity, 1e-3,
			"alcanza terminal_velocity")


# --- Orientación ------------------------------------------------------------------------------

func test_facing_turns_toward_look_yaw() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN, PI / 2.0):
		return
	var max_turn: float = _character.turn_speed * _dt
	_step(Vector2(0.0, 1.0), 0.0)
	assert_near(absf(angle_difference(_character.yaw, PI / 2.0)), max_turn, 1e-3,
			"en un tick gira turn_speed * delta hacia la cámara")
	_step(Vector2(0.0, 1.0), 0.0, 0, 30)
	assert_near(absf(angle_difference(_character.yaw, 0.0)), 0.0, 1e-3,
			"acaba mirando hacia la cámara")
	assert_near(absf(angle_difference(_character.rotation.y, _character.yaw)), 0.0, 1e-4,
			"rotation.y = yaw")

	# Gira por el camino corto al cruzar ±PI (de 3.0 a -3.0 hay 0.28 rad, no 6.0).
	var state: PlayerState = _character.get_state()
	state.yaw = 3.0
	state.velocity = Vector3.ZERO
	_character.set_state(state)
	assert_near(absf(angle_difference(_character.rotation.y, 3.0)), 0.0, 1e-4,
			"set_state() actualiza rotation.y")
	_step(Vector2(0.0, 1.0), -3.0)
	var remaining: float = absf(angle_difference(_character.yaw, -3.0))
	assert_near(remaining, (TAU - 6.0) - max_turn, 1e-3,
			"gira por el camino corto cruzando ±PI (le faltan %.3f rad)" % remaining)
	_step(Vector2(0.0, 1.0), -3.0, 0, 5)
	assert_near(absf(angle_difference(_character.yaw, -3.0)), 0.0, 1e-3,
			"llega a -3.0 por el camino corto")


func test_facing_unchanged_when_idle() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN, 0.0):
		return
	# La cámara orbita alrededor del personaje parado: el personaje no gira.
	_step(Vector2.ZERO, 1.2, 0, 30)
	assert_near(absf(angle_difference(_character.yaw, 0.0)), 0.0, 1e-6, "parado no gira")
	# Un deseo de movimiento por debajo de 0.1 tampoco lo gira.
	_step(Vector2(0.05, 0.05), 1.2, 0, 30)
	assert_near(absf(angle_difference(_character.yaw, 0.0)), 0.0, 1e-6,
			"con un deseo < 0.1 no gira")


func test_turning_keeps_the_basis_a_pure_function_of_yaw() -> void:
	# Si la base del nodo acumulara escala al girar (como pasa al asignar 'rotation'), la cápsula
	# cambiaría de tamaño según la historia de giros y la repetición dejaría de ser exacta.
	if not await _begin() or not _settle(FLAT_SPAWN, 0.0):
		return
	for i: int in 1200:
		var look_yaw: float = wrapf(i * 0.37, -PI, PI)
		_step(Vector2(0.0, 1.0) if i % 3 != 0 else Vector2(0.6, 0.6), look_yaw)
		if i % 200 == 0:
			_step(Vector2.ZERO, look_yaw, 0, 20)
	_assert_basis_is_pure_yaw("tras 20 s girando")

	# Una escala o rotación externa se limpia en el siguiente tick. (Escala uniforme: Jolt no
	# admite escalas no uniformes en una cápsula y registraría un error.)
	_character.scale = Vector3.ONE * 1.02
	_character.rotation = Vector3(0.2, 1.0, 0.0)
	_step(Vector2.ZERO, 0.0)
	_assert_basis_is_pure_yaw("tras tocar la escala y la rotación desde fuera")


# --- Rampas -----------------------------------------------------------------------------------

func test_walkable_ramp_is_climbable() -> void:
	if not await _begin() or not _settle(RAMP_FOOT + Vector3(0.0, 0.02, 3.0)):
		return
	_step(Vector2(0.0, 1.0), 0.0, 0, 150)
	assert_true(_character.global_position.y > 2.0,
			"debe subir la rampa de %d° (altura %.2f m)" % [
				RAMP_ANGLE_DEG, _character.global_position.y,
			])
	assert_true(_character.grounded, "sigue apoyado en la rampa mientras sube")


func test_steep_ramp_is_not_climbable() -> void:
	if not await _begin() or not _settle(STEEP_RAMP_FOOT + Vector3(0.0, 0.02, 3.0)):
		return
	_step(Vector2(0.0, 1.0), 0.0, 0, 150)
	assert_true(_character.global_position.y < 0.5,
			"no puede subir una pendiente de %d° (llegó a %.2f m)" % [
				STEEP_RAMP_ANGLE_DEG, _character.global_position.y,
			])


# --- Estado -----------------------------------------------------------------------------------

func test_get_state_and_set_state_roundtrip() -> void:
	if not await _begin():
		return
	var state := PlayerState.new()
	state.position = Vector3(3.25, 1.5, -7.75)
	state.velocity = Vector3(3.0, -10.0, 4.0)
	state.yaw = 0.75
	state.grounded = false
	state.prev_buttons = PlayerInput.JUMP | PlayerInput.SPRINT
	state.last_input_tick = 1234
	state.coyote_ticks = 3
	state.jump_buffer_ticks = 5
	_character.set_state(state)

	assert_vec_near(_character.global_position, state.position, 1e-5,
			"set_state() coloca global_position")
	assert_vec_near(_character.velocity, state.velocity, 1e-5, "set_state() asigna velocity")
	assert_near(_character.yaw, 0.75, 1e-6, "set_state() asigna yaw")
	assert_near(_character.rotation.y, 0.75, 1e-5, "set_state() gira el nodo (rotation.y)")
	assert_false(_character.grounded, "set_state() asigna grounded")
	assert_eq(_character.prev_buttons, state.prev_buttons, "set_state() asigna prev_buttons")
	assert_eq(_character.last_input_tick, 1234, "set_state() asigna last_input_tick")
	assert_eq(_character.coyote_ticks, 3, "set_state() asigna coyote_ticks")
	assert_eq(_character.jump_buffer_ticks, 5, "set_state() asigna jump_buffer_ticks")
	assert_near(_character.get_horizontal_speed(), 5.0, 1e-4,
			"get_horizontal_speed() ignora la componente vertical")

	var read_back: PlayerState = _character.get_state()
	if not assert_not_null(read_back, "get_state()"):
		return
	assert_false(is_same(read_back, state), "get_state() devuelve un objeto nuevo")
	assert_vec_near(read_back.position, state.position, 1e-5, "get_state().position")
	assert_vec_near(read_back.velocity, state.velocity, 1e-5, "get_state().velocity")
	assert_near(read_back.yaw, 0.75, 1e-6, "get_state().yaw")
	assert_eq(read_back.grounded, false, "get_state().grounded")
	assert_eq(read_back.prev_buttons, state.prev_buttons, "get_state().prev_buttons")
	assert_eq(read_back.last_input_tick, 1234, "get_state().last_input_tick")
	assert_eq(read_back.coyote_ticks, 3, "get_state().coyote_ticks")
	assert_eq(read_back.jump_buffer_ticks, 5, "get_state().jump_buffer_ticks")

	# Ni el estado leído ni el restaurado quedan enlazados al personaje.
	read_back.position = Vector3(100.0, 100.0, 100.0)
	state.yaw = 2.0
	assert_vec_near(_character.global_position, Vector3(3.25, 1.5, -7.75), 1e-5,
			"modificar el estado devuelto no mueve al personaje")
	assert_near(_character.get_state().yaw, 0.75, 1e-6,
			"modificar el estado restaurado no cambia al personaje")


func test_simulate_records_tick_and_buttons() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	var input := PlayerInput.new()
	input.tick = 4242
	input.move = Vector2(0.0, 1.0)
	input.buttons = PlayerInput.SPRINT | PlayerInput.BLOCK
	_character.simulate(input.quantized(), _dt)
	var expected_buttons: int = PlayerInput.SPRINT | PlayerInput.BLOCK
	assert_eq(_character.last_input_tick, 4242, "last_input_tick = tick de la entrada aplicada")
	assert_eq(_character.prev_buttons, expected_buttons, "prev_buttons = botones aplicados")
	var state: PlayerState = _character.get_state()
	assert_eq(state.last_input_tick, 4242, "get_state().last_input_tick")
	assert_eq(state.prev_buttons, expected_buttons, "get_state().prev_buttons")


func test_set_state_restores_grounded_so_jump_works() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	var grounded_state: PlayerState = _character.get_state()
	assert_true(grounded_state.grounded, "estado de partida en el suelo")
	_pollute(Pollution.AIRBORNE)
	assert_false(_character.grounded, "tras ensuciar el estado está en el aire")

	_character.set_state(grounded_state)
	assert_true(_character.grounded, "set_state() restaura grounded")
	_reset_counters()
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	assert_eq(_jumped_count, 1, "saltar justo después de restaurar un estado en el suelo funciona")
	assert_near(_character.velocity.y, _character.jump_velocity, _character.gravity * _dt + 1e-3,
			"velocidad vertical del salto tras restaurar")
	assert_true(_character.global_position.y > grounded_state.position.y + 0.05, "despega")


func test_set_state_restores_prev_buttons_for_jump_edge() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	var state: PlayerState = _character.get_state()
	state.prev_buttons = PlayerInput.JUMP
	_character.set_state(state)
	_reset_counters()
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP, 5)
	assert_eq(_jumped_count, 0, "con JUMP ya pulsado en el estado restaurado, mantenerlo no salta")
	_step(Vector2.ZERO, 0.0, 0)
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	assert_eq(_jumped_count, 1, "soltar y volver a pulsar sí salta")


# --- Determinismo -----------------------------------------------------------------------------

func test_replay_determinism_after_restore() -> void:
	if not await _begin() or not _settle(REPLAY_START, 0.0):
		return
	var inputs: Array[PlayerInput] = _build_replay_inputs()
	var states: Array[PlayerState] = []
	var max_height: float = 0.0
	_reset_counters()
	for input: PlayerInput in inputs:
		states.append(_character.get_state())
		_character.simulate(input, _dt)
		max_height = maxf(max_height, _character.global_position.y)
	states.append(_character.get_state())

	# Comprobaciones del recorrido: si fallan, el escenario ya no prueba lo que debe.
	assert_true(max_height > 1.0,
			"el recorrido debe subir por la rampa (altura máxima %.2f m)" % max_height)
	assert_true(_jumped_count >= 2,
			"el recorrido debe incluir dos saltos (hubo %d)" % _jumped_count)
	assert_true(states[60].grounded, "en el tick 60 el personaje debe estar en el suelo")
	assert_true(_find_tick_just_before_landing(states) > 0,
			"el recorrido debe tener un tick en el aire, bajando y a punto de aterrizar")
	_assert_basis_is_pure_yaw("tras el recorrido con giros")

	_check_replays_from_every_tick(inputs, states, false, "estado restaurado en el mismo proceso")


func test_replay_from_decoded_network_state() -> void:
	# Como en la fase 2: el estado restaurado llega por la red (PlayerState.encode/decode).
	if not await _begin() or not _settle(REPLAY_START, 0.0):
		return
	var inputs: Array[PlayerInput] = _build_replay_inputs()
	var states: Array[PlayerState] = []
	for input: PlayerInput in inputs:
		states.append(_character.get_state())
		_character.simulate(input, _dt)
	states.append(_character.get_state())

	_check_replays_from_every_tick(inputs, states, true, "estado decodificado de la red")


func test_replay_matches_recording_across_physics_frames() -> void:
	# Como el controlador local: al jugar se simula un tick por paso de física, pero la
	# reconciliación repetirá muchos ticks dentro de un mismo paso. Ambos deben coincidir.
	if not await _begin() or not _settle(REPLAY_START, 0.0):
		return
	var start: PlayerState = _character.get_state()
	var inputs: Array[PlayerInput] = _build_replay_inputs()
	var recorded: Array[PlayerState] = []
	for input: PlayerInput in inputs:
		recorded.append(_character.get_state())
		await wait_physics_frames()
		_character.simulate(input, _dt)
	recorded.append(_character.get_state())
	_assert_basis_is_pure_yaw("tras grabar un tick por paso de física")

	_character.set_state(start)
	for i: int in inputs.size():
		_character.simulate(inputs[i], _dt)
		var actual: PlayerState = _character.get_state()
		if not actual.is_close_to(recorded[i + 1], REPLAY_EPSILON):
			fail("las mismas entradas en un solo paso de física divergen en el tick %d. %s" % [
				i, _describe_difference(actual, recorded[i + 1]),
			])
			break

	_check_replays_from_every_tick(inputs, recorded, false, "grabación tick a tick")


# --- Utilidades: mundo ------------------------------------------------------------------------

func _add_static_box(node_name: String, size: Vector3, center: Vector3, pitch: float) -> void:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = WORLD_LAYER
	body.collision_mask = 0
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	body.add_child(shape)
	body.position = center
	body.rotation = Vector3(pitch, 0.0, 0.0)
	_world.add_child(body)


## Rampa que sube hacia -Z con la inclinación dada. [param foot] es el centro de su borde
## superior más cercano (+Z), a ras de suelo.
func _add_ramp(node_name: String, foot: Vector3, angle_deg: float, length: float) -> void:
	var angle: float = deg_to_rad(angle_deg)
	var surface_normal := Vector3(0.0, cos(angle), sin(angle))
	var uphill := Vector3(0.0, sin(angle), -cos(angle))
	var center: Vector3 = (foot + uphill * (length * 0.5)
			- surface_normal * (RAMP_THICKNESS * 0.5))
	_add_static_box(node_name, Vector3(RAMP_WIDTH, RAMP_THICKNESS, length), center, angle)


# --- Utilidades: simulación -------------------------------------------------------------------

## Comprueba que el personaje existe y entra en un tick de física. Todas las pruebas que simulan
## empiezan con [code]if not await _begin(): return[/code].
func _begin() -> bool:
	if _character == null:
		fail("el personaje no se pudo instanciar (ver before_each)")
		return false
	await wait_physics_frames()
	return assert_true(Engine.is_in_physics_frame(),
			"simulate() debe llamarse dentro del tick de física para que move_and_slide() "
			+ "use su delta")


func _place(position: Vector3, yaw: float, grounded: bool,
		velocity: Vector3 = Vector3.ZERO) -> void:
	var state := PlayerState.new()
	state.position = position
	state.velocity = velocity
	state.yaw = yaw
	state.grounded = grounded
	_character.set_state(state)


## Coloca al personaje 5 cm por encima de [param position] y simula en reposo hasta que toca el
## suelo. Devuelve false (y registra un fallo) si no lo consigue.
func _settle(position: Vector3, yaw: float = 0.0) -> bool:
	_place(position + Vector3(0.0, 0.05, 0.0), yaw, false)
	for _i: int in 60:
		_step(Vector2.ZERO, yaw)
		if _character.grounded:
			_step(Vector2.ZERO, yaw, 0, 2)
			return assert_true(_character.grounded,
					"el personaje debe quedarse en el suelo tras posarse en %s" % position)
	fail("el personaje no llegó a posarse en el suelo en %s" % position)
	return false


func _make_input(move: Vector2, look_yaw: float, buttons: int = 0,
		look_pitch: float = 0.0) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = _next_tick
	_next_tick += 1
	input.move = move
	input.look_yaw = look_yaw
	input.look_pitch = look_pitch
	input.buttons = buttons
	# Igual que el controlador: se simula con la entrada tal como la verá el servidor.
	return input.quantized()


func _step(move: Vector2, look_yaw: float, buttons: int = 0, ticks: int = 1) -> void:
	for _i: int in ticks:
		_character.simulate(_make_input(move, look_yaw, buttons), _dt)


func _horizontal_velocity() -> Vector3:
	return Vector3(_character.velocity.x, 0.0, _character.velocity.z)


## La base del nodo debe ser exactamente la rotación del yaw, sin escala acumulada.
func _assert_basis_is_pure_yaw(context: String) -> void:
	var expected := Basis(Vector3.UP, _character.yaw)
	assert_true(_character.transform.basis == expected,
			"%s: la base del nodo debe salir solo del yaw (escala %s)" % [
				context, _character.transform.basis.get_scale(),
			])
	assert_true(_character.scale.is_equal_approx(Vector3.ONE),
			"%s: la escala del personaje debe ser 1 (es %s)" % [context, _character.scale])


func _reset_counters() -> void:
	_jumped_count = 0
	_landed_count = 0


func _on_jumped() -> void:
	_jumped_count += 1


func _on_landed() -> void:
	_landed_count += 1


# --- Utilidades: repetición -------------------------------------------------------------------

## 180 ticks variados: carrera, esprint en diagonal girando la cámara, subida por la rampa, salto
## mantenido sobre la pendiente, lateral, marcha atrás bajando, reposo y un segundo salto con
## esprint en el aire.
func _build_replay_inputs() -> Array[PlayerInput]:
	var inputs: Array[PlayerInput] = []
	for i: int in REPLAY_TICKS:
		var move: Vector2 = Vector2.ZERO
		var look_yaw: float = 0.0
		var buttons: int = 0
		if i < 25:
			move = Vector2(0.0, 1.0)
		elif i < 55:
			move = Vector2(0.3, 1.0)
			look_yaw = lerpf(0.0, 0.15, (i - 25) / 30.0)
			buttons = PlayerInput.SPRINT
		elif i < 60:
			move = Vector2(0.0, 1.0)
			look_yaw = 0.1
			buttons = PlayerInput.SPRINT
		elif i < 80:
			move = Vector2(0.0, 1.0)
			look_yaw = 0.1
		elif i < 100:
			move = Vector2(0.0, 1.0)
			look_yaw = 0.1
			buttons = PlayerInput.JUMP
		elif i < 115:
			move = Vector2(-1.0, 0.3)
			look_yaw = 0.3
		elif i < 135:
			move = Vector2(0.0, -1.0)
			look_yaw = lerpf(0.3, -0.4, (i - 115) / 20.0)
		elif i < 145:
			look_yaw = -0.4
		elif i < 148:
			move = Vector2(0.5, 0.5)
			look_yaw = -0.4
			buttons = PlayerInput.JUMP
		else:
			move = Vector2(0.7, 0.7)
			look_yaw = -0.4
			buttons = PlayerInput.SPRINT
		inputs.append(_make_input(move, look_yaw, buttons, 0.2))
	return inputs


## Repite el recorrido desde cada uno de sus ticks, con las dos formas de ensuciar el estado
## interno, y registra un único fallo con las primeras repeticiones que divergen. Si
## [param through_network] es true, el estado restaurado pasa antes por encode()/decode().
func _check_replays_from_every_tick(inputs: Array[PlayerInput], states: Array[PlayerState],
		through_network: bool, label: String) -> void:
	var problems: PackedStringArray = PackedStringArray()
	var replays: int = 0
	for pollution: Pollution in [Pollution.AIRBORNE, Pollution.GROUNDED]:
		for from_tick: int in inputs.size():
			replays += 1
			var problem: String = _replay_from(inputs, states, from_tick, pollution,
					through_network)
			if not problem.is_empty():
				problems.append(problem)
	var shown: PackedStringArray = problems.slice(0, MAX_REPORTED_REPLAYS)
	assert_true(problems.is_empty(), "%s: %d de %d repeticiones divergen.\n      %s\n      %s" % [
		label, problems.size(), replays, "\n      ".join(shown), REPLAY_HINT,
	])


## Restaura el estado del tick [param from_tick] después de ensuciar el estado interno del
## CharacterBody3D y repite las mismas entradas hasta el final. Cada tick repetido debe
## coincidir con el original (no solo el estado final). Devuelve una descripción de la primera
## diferencia, o una cadena vacía si todo coincide.
func _replay_from(inputs: Array[PlayerInput], states: Array[PlayerState], from_tick: int,
		pollution: Pollution, through_network: bool) -> String:
	var context: String = "desde el tick %d (estado interno previo: %s)" % [
		from_tick, "en el aire" if pollution == Pollution.AIRBORNE else "en el suelo",
	]
	var restored: PlayerState = states[from_tick]
	if through_network:
		restored = PlayerState.decode(restored.encode())
		if restored == null:
			return "%s: PlayerState.decode() devolvió null" % context
	_pollute(pollution)
	_character.set_state(restored)
	for i: int in range(from_tick, inputs.size()):
		_character.simulate(inputs[i], _dt)
		var actual: PlayerState = _character.get_state()
		var expected: PlayerState = states[i + 1]
		if not actual.is_close_to(expected, REPLAY_EPSILON):
			return "%s: diverge en el tick %d. %s" % [
				context, i, _describe_difference(actual, expected),
			]
	var final_state: PlayerState = _character.get_state()
	var original_final: PlayerState = states[inputs.size()]
	if final_state.prev_buttons != original_final.prev_buttons:
		return "%s: prev_buttons final %d (esperado %d)" % [
			context, final_state.prev_buttons, original_final.prev_buttons,
		]
	if final_state.last_input_tick != original_final.last_input_tick:
		return "%s: last_input_tick final %d (esperado %d)" % [
			context, final_state.last_input_tick, original_final.last_input_tick,
		]
	return ""


## Deja el estado interno del CharacterBody3D en una situación distinta a la que se va a
## restaurar, como ocurre en la fase 2 cuando la predicción ya ha avanzado con otras entradas.
func _pollute(pollution: Pollution) -> void:
	if pollution == Pollution.AIRBORNE:
		_place(POLLUTION_SPOT + Vector3(0.0, 20.0, 0.0), 2.5, false, Vector3(3.0, 0.0, -2.0))
		_step(Vector2(0.5, 1.0), 2.5, PlayerInput.SPRINT, 3)
	else:
		_place(POLLUTION_SPOT + Vector3(0.0, 0.05, 0.0), -2.0, false)
		_step(Vector2(-1.0, 0.0), -2.0, 0, 30)
		assert_true(_character.grounded,
				"al ensuciar el estado en el suelo, el personaje debe estar apoyado")


## Tick (índice en [param states]) dos ticks antes de un aterrizaje posterior al tick 60: el
## personaje está en el aire, bajando y a pocos centímetros del suelo (al alcance del snap).
func _find_tick_just_before_landing(states: Array[PlayerState]) -> int:
	for landing: int in range(63, states.size()):
		var candidate: PlayerState = states[landing - 2]
		if (states[landing].grounded and not states[landing - 1].grounded
				and not candidate.grounded and candidate.velocity.y < 0.0):
			return landing - 2
	return -1


func _describe_difference(actual: PlayerState, expected: PlayerState) -> String:
	var text: String = "Δposición %.7f, Δvelocidad %.7f, Δyaw %.7f, grounded %s (esperado %s)"
	text = text % [
		actual.position.distance_to(expected.position),
		actual.velocity.distance_to(expected.velocity),
		absf(angle_difference(actual.yaw, expected.yaw)),
		actual.grounded, expected.grounded,
	]
	return "%s\n        obtenido: %s\n        esperado: %s" % [text, actual, expected]
