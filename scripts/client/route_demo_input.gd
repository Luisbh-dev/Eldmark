class_name RouteDemoInput
extends DemoInput
## Demo guionizada que recorre una ruta de una zona siguiendo puntos de paso.
##
## A diferencia de [DemoInput] (un guion fijo pensado para el circuito de pruebas), esta demo
## lee la posición del personaje en cada tick y corre en línea recta hacia el siguiente punto de
## paso, como [code]tools/terrain/verify_vado_gris_routes.gd[/code]; así no choca con la
## empalizada, los pretiles del puente o las tiendas aunque un golpe o una pendiente la desvíen.
## La vista gira hacia el rumbo con una velocidad limitada, para que la cámara no salte en las
## esquinas. Sigue siendo determinista: la entrada solo depende del tick y del estado simulado.
## [br][br]
## La ruta es una lista de pasos (quieto, ir a un punto, saltos, paso lateral, mirar a un punto,
## órbita de la cámara, combate) que se construye encadenando [method idle], [method go_to],
## [method jumps], [method strafe], [method face], [method orbit] y [method combat]. Con
## [code]mirror_z = true[/code] cada paso se refleja (z -> -z), que es como se pasa la ruta del
## norte (Vardheim) a la del sur (Solmarch) en una zona simétrica.
## [br][br]
## Hay que llamar a [method look_for] y [method next] una vez por tick y en orden (los dos con el
## mismo tick devuelven datos coherentes) y vincular el personaje con [method bind].

enum Kind { IDLE, GOTO, JUMPS, STRAFE, FACE, ORBIT, COMBAT }

## Distancia (m) a la que se da por alcanzado un punto de paso.
const REACH: float = 1.6
## Velocidad máxima de giro de la vista hacia el rumbo (grados por segundo).
const LOOK_TURN_DEGREES_PER_SECOND: float = 220.0
## Ticks de cada salto de [method jumps] y tick dentro de ese tramo en el que se pulsa.
const JUMP_SLOT_TICKS: int = 50
const JUMP_PRESS_OFFSET: int = 6
## Ticks sin acercarse al punto de paso antes de darlo por inalcanzable y pasar al siguiente.
const STUCK_TICKS: int = 150
## Margen de ticks de un tramo [method go_to] sobre el tiempo que debería tardar.
const GOTO_EXTRA_TICKS: int = 120
## Velocidades (m/s) para estimar la duración de los tramos (las de [PlayerCharacter]).
const ESTIMATE_RUN_SPEED: float = 5.0
const ESTIMATE_SPRINT_SPEED: float = 7.5


## Un paso de la ruta.
class Step:
	var kind: int = 0
	var label: String = ""
	## GOTO: punto de destino (x, z). FACE: punto al que mirar.
	var target: Vector2 = Vector2.ZERO
	var sprint: bool = false
	## Duración en ticks (en GOTO no se usa: se calcula al empezar el tramo).
	var ticks: int = 0
	## STRAFE: movimiento relativo a la vista (x = derecha, y = adelante).
	var move: Vector2 = Vector2.ZERO
	## GOTO: ticks desde el inicio del tramo en los que se pulsa saltar (-1: sin salto).
	var jump_after: int = -1
	## ORBIT y COMBAT: giro total de la vista (grados, positivo hacia la izquierda).
	var degrees: float = 0.0
	## COMBAT: guion de botones que se pulsa durante el paso.
	var combat: CombatDemoScript = null


## Refleja cada paso que se añade (z -> -z, lateral y órbita invertidos).
var mirror_z: bool = false

var _steps: Array[Step] = []
var _character: PlayerCharacter = null
var _index: int = 0
var _step_tick: int = 0
var _last_tick: int = -1
var _finished: bool = false
var _look_yaw: float = 0.0
var _look_pitch: float = deg_to_rad(BASE_PITCH_DEGREES)
var _move: Vector2 = Vector2.ZERO
var _buttons: int = 0
var _goto_budget: int = 0
var _best_distance: float = INF
var _since_progress: int = 0
var _orbit_start_yaw: float = 0.0
var _orbit_start_pitch: float = 0.0


## Demo de [param zone_id] para un jugador de [param realm]: la ruta de la zona si la tiene, el
## guion del circuito de pruebas en [code]test_world[/code] y, en cualquier otra zona, una vuelta
## de cámara sin moverse (no se conoce el terreno).
static func for_zone(zone_id: StringName, realm: StringName) -> DemoInput:
	match zone_id:
		&"test_world":
			return DemoInput.new()
		&"vado_gris":
			return vado_gris(realm)
	var fallback: RouteDemoInput = RouteDemoInput.new()
	fallback.idle(60).orbit(360.0, 240)
	return fallback


## Ruta del Vado Gris (ver docs/zonas/vado_gris.md): del campamento propio por la calzada, carrera
## con salto, cruce del puente propio, dos saltos en la ladera del fuerte, paso lateral, rodeo de
## la esquina de la empalizada hasta la explanada de la puerta (frente al vado) y, allí, el combate
## ([CombatDemoScript]: combo de 3 ligeros, un fuerte cargado, un bloqueo y una esquiva) mientras la
## cámara da una vuelta completa. Los puntos de paso son los de la ruta del puente de
## [code]verify_vado_gris_routes.gd[/code]; Solmarch recorre el reflejo de la de Vardheim.
static func vado_gris(realm: StringName) -> RouteDemoInput:
	var demo: RouteDemoInput = RouteDemoInput.new()
	demo.mirror_z = realm == &"solmarch"
	demo.idle(30, "quieto en el campamento")
	demo.go_to(-2.5, -132.0, false, -1, "salir del campamento")
	demo.go_to(0.0, -116.0, false, -1, "calzada")
	demo.go_to(0.0, -86.0, true, 40, "esprint con salto por la calzada")
	demo.go_to(0.0, -62.0, false, -1, "subir al puente")
	demo.go_to(0.0, -47.0, false, -1, "bajar del puente")
	demo.jumps(2, "dos saltos al pie del fuerte")
	demo.strafe(Vector2(1.0, 0.0), 60, "paso lateral")
	demo.go_to(-12.0, -35.0, false, -1, "ladera del fuerte")
	demo.go_to(-26.0, -26.0, true, -1, "esquina de la empalizada")
	demo.go_to(-29.0, -10.0, true, -1, "cara oeste de la empalizada")
	demo.go_to(-25.0, -2.0, false, -1, "explanada de la puerta")
	demo.face(-20.0, 0.0, 45, "mirar la puerta del fuerte")
	demo.combat(360.0, "combate con vuelta de cámara")
	return demo


# --- Construcción de la ruta ------------------------------------------------------------------

## Quieto [param ticks] ticks.
func idle(ticks: int, label: String = "quieto") -> RouteDemoInput:
	var step: Step = _new_step(Kind.IDLE, label)
	step.ticks = ticks
	return self


## Correr (o esprintar) en línea recta hasta (x, z). Con [param jump_after] >= 0 se salta ese
## número de ticks después de empezar el tramo.
func go_to(x: float, z: float, sprint: bool = false, jump_after: int = -1,
		label: String = "") -> RouteDemoInput:
	var step: Step = _new_step(Kind.GOTO, label if not label.is_empty() else "ir a (%.0f, %.0f)" % [x, z])
	step.target = Vector2(x, -z if mirror_z else z)
	step.sprint = sprint
	step.jump_after = jump_after
	return self


## [param count] saltos en el sitio.
func jumps(count: int, label: String = "saltos") -> RouteDemoInput:
	var step: Step = _new_step(Kind.JUMPS, label)
	step.ticks = count * JUMP_SLOT_TICKS
	return self


## Moverse [param ticks] ticks con [param move] relativo a la vista, sin girarla.
func strafe(move: Vector2, ticks: int, label: String = "paso lateral") -> RouteDemoInput:
	var step: Step = _new_step(Kind.STRAFE, label)
	step.move = Vector2(-move.x if mirror_z else move.x, move.y)
	step.ticks = ticks
	return self


## Quieto [param ticks] ticks mientras la vista gira hacia (x, z).
func face(x: float, z: float, ticks: int, label: String = "mirar") -> RouteDemoInput:
	var step: Step = _new_step(Kind.FACE, label)
	step.target = Vector2(x, -z if mirror_z else z)
	step.ticks = ticks
	return self


## Quieto mientras la cámara gira [param degrees] grados en [param ticks] ticks, mirando algo
## más desde arriba.
func orbit(degrees: float, ticks: int, label: String = "vuelta de cámara") -> RouteDemoInput:
	var step: Step = _new_step(Kind.ORBIT, label)
	step.degrees = -degrees if mirror_z else degrees
	step.ticks = ticks
	return self


## Combate en el sitio ([CombatDemoScript]) mientras la cámara gira [param degrees] grados.
func combat(degrees: float, label: String = "combate") -> RouteDemoInput:
	var step: Step = _new_step(Kind.COMBAT, label)
	step.combat = CombatDemoScript.new()
	step.ticks = step.combat.get_length()
	step.degrees = -degrees if mirror_z else degrees
	return self


# --- API de DemoInput -------------------------------------------------------------------------

func bind(character: PlayerCharacter) -> void:
	_character = character
	if is_instance_valid(_character):
		_look_yaw = _character.yaw


func next(tick: int) -> PlayerInput:
	_update(tick)
	var input: PlayerInput = PlayerInput.new()
	input.tick = tick
	input.look_yaw = wrapf(_look_yaw, -PI, PI)
	input.look_pitch = _look_pitch
	input.move = _move
	input.buttons = _buttons
	return input


func look_for(tick: int) -> Vector2:
	_update(tick)
	return Vector2(wrapf(_look_yaw, -PI, PI), _look_pitch)


## Estimación de la duración en ticks (los tramos [method go_to] dependen del recorrido real).
func get_length() -> int:
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	var total: int = 0
	var position: Vector2 = Vector2.ZERO
	var has_position: bool = false
	if is_instance_valid(_character):
		position = Vector2(_character.global_position.x, _character.global_position.z)
		has_position = true
	for step: Step in _steps:
		if step.kind == Kind.GOTO:
			if has_position:
				var speed: float = ESTIMATE_SPRINT_SPEED if step.sprint else ESTIMATE_RUN_SPEED
				total += ceili(position.distance_to(step.target) / speed / dt)
			position = step.target
			has_position = true
		else:
			total += step.ticks
	return total


func is_finished(_tick: int) -> bool:
	return _finished


## Nombre del paso en curso (vacío al terminar).
func get_step_label() -> String:
	return _steps[_index].label if _index < _steps.size() else ""


# --- Ejecución --------------------------------------------------------------------------------

func _new_step(kind: int, label: String) -> Step:
	var step: Step = Step.new()
	step.kind = kind
	step.label = label
	_steps.append(step)
	return step


## Calcula la entrada del tick [param tick] (una sola vez por tick).
func _update(tick: int) -> void:
	if tick == _last_tick:
		return
	_last_tick = tick
	_move = Vector2.ZERO
	_buttons = 0
	if _finished:
		return
	if not is_instance_valid(_character):
		_finished = true
		return
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	while _index < _steps.size():
		if _step_tick == 0:
			_begin_step(_steps[_index], tick)
		if _run_step(_steps[_index], dt):
			_step_tick += 1
			return
		_index += 1
		_step_tick = 0
	_finished = true


func _begin_step(step: Step, tick: int) -> void:
	var p: Vector3 = _character.global_position
	print("[Eldmark] Demo, tick %d: %s (desde %.1f, %.1f, %.1f)" % [tick, step.label, p.x, p.y, p.z])
	if step.kind == Kind.GOTO:
		var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
		var speed: float = ESTIMATE_SPRINT_SPEED if step.sprint else ESTIMATE_RUN_SPEED
		var distance: float = Vector2(p.x, p.z).distance_to(step.target)
		_goto_budget = ceili(distance / speed / dt * 1.5) + GOTO_EXTRA_TICKS
		_best_distance = INF
		_since_progress = 0
	elif step.kind == Kind.ORBIT or step.kind == Kind.COMBAT:
		_orbit_start_yaw = _look_yaw
		_orbit_start_pitch = _look_pitch


## Ejecuta un tick del paso. Devuelve false si el paso ya había terminado (sin generar entrada).
func _run_step(step: Step, dt: float) -> bool:
	var p: Vector3 = _character.global_position
	var flat: Vector2 = Vector2(p.x, p.z)
	match step.kind:
		Kind.IDLE:
			return _step_tick < step.ticks
		Kind.GOTO:
			var to_target: Vector2 = step.target - flat
			var distance: float = to_target.length()
			if distance < REACH:
				return false
			if distance < _best_distance - 0.05:
				_best_distance = distance
				_since_progress = 0
			else:
				_since_progress += 1
			if _since_progress > STUCK_TICKS or _step_tick > _goto_budget:
				push_warning("[Eldmark] Demo: no se llega a '%s' (%s); se sigue con el siguiente paso"
						% [step.label, flat])
				return false
			var direction: Vector2 = to_target / distance
			_turn_look_toward(atan2(-direction.x, -direction.y), dt)
			_move = _world_to_move(direction)
			if step.sprint:
				_buttons |= PlayerInput.SPRINT
			if step.jump_after >= 0 and _step_tick >= step.jump_after \
					and _step_tick < step.jump_after + JUMP_HOLD_TICKS:
				_buttons |= PlayerInput.JUMP
			return true
		Kind.JUMPS:
			if _step_tick >= step.ticks:
				return false
			var slot_tick: int = _step_tick % JUMP_SLOT_TICKS
			if slot_tick >= JUMP_PRESS_OFFSET and slot_tick < JUMP_PRESS_OFFSET + JUMP_HOLD_TICKS:
				_buttons |= PlayerInput.JUMP
			return true
		Kind.STRAFE:
			if _step_tick >= step.ticks:
				return false
			_move = step.move
			return true
		Kind.FACE:
			if _step_tick >= step.ticks:
				return false
			var to_point: Vector2 = step.target - flat
			if to_point.length() > 0.01:
				_turn_look_toward(atan2(-to_point.x, -to_point.y), dt)
			return true
		Kind.ORBIT:
			if _step_tick >= step.ticks:
				return false
			var k: float = float(_step_tick + 1) / float(step.ticks)
			_look_yaw = _orbit_start_yaw + deg_to_rad(step.degrees) * k
			var pitch_k: float = smoothstep(0.0, 1.0, minf(k * 4.0, 1.0))
			_look_pitch = lerpf(_orbit_start_pitch, deg_to_rad(ORBIT_PITCH_DEGREES), pitch_k)
			return true
		Kind.COMBAT:
			if _step_tick >= step.ticks:
				return false
			_buttons |= step.combat.buttons_at(_step_tick)
			var combat_k: float = float(_step_tick + 1) / float(step.ticks)
			_look_yaw = _orbit_start_yaw + deg_to_rad(step.degrees) * combat_k
			var combat_pitch_k: float = smoothstep(0.0, 1.0, minf(combat_k * 4.0, 1.0))
			_look_pitch = lerpf(_orbit_start_pitch, deg_to_rad(ORBIT_PITCH_DEGREES), combat_pitch_k)
			return true
	return false


## Gira la vista hacia [param heading] (yaw) con la velocidad máxima de giro.
func _turn_look_toward(heading: float, dt: float) -> void:
	var max_step: float = deg_to_rad(LOOK_TURN_DEGREES_PER_SECOND) * dt
	_look_yaw = wrapf(rotate_toward(_look_yaw, heading, max_step), -PI, PI)


## Dirección del mundo (x, z) -> movimiento relativo a la vista (x = derecha, y = adelante),
## con las mismas convenciones que [method PlayerCharacter.simulate].
func _world_to_move(direction: Vector2) -> Vector2:
	var forward: Vector2 = Vector2(-sin(_look_yaw), -cos(_look_yaw))
	var right: Vector2 = Vector2(cos(_look_yaw), -sin(_look_yaw))
	return Vector2(direction.dot(right), direction.dot(forward)).limit_length(1.0)
