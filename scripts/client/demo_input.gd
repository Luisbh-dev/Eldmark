class_name DemoInput
extends RefCounted
## Entrada guionizada y determinista para pruebas visuales automáticas.
##
## Es la demo del circuito de la fase 1 ([code]--zone=test_world[/code]); las zonas reales usan
## [RouteDemoInput], que sigue una ruta de puntos de paso.
## [br][br]Unos 10 s a 60 ticks/s. Cada tick devuelve siempre la misma entrada y la
## misma vista, sin leer dispositivos ni el reloj, así dos ejecuciones de la
## demo producen el mismo recorrido. Supone que el punto de aparición mira hacia
## -Z (yaw 0) con unos 15 m libres por delante y la zona de rampas después,
## delante a la derecha (en [code]test_world.tscn[/code], el pie de la rampa
## transitable está hacia (15, 0, -24.5)).
## [br][br]Guion (los ticks empiezan en 1):
## [br]1. Quieto 0,5 s.
## [br]2. Correr hacia delante 2 s.
## [br]3. Esprintar 1,5 s mientras la cámara gira despacio a la izquierda (así el
## desplazamiento lateral siguiente no choca con el pilar de (6, -20)).
## [br]4. Dos saltos en el sitio.
## [br]5. Desplazarse de lado a la derecha 1 s.
## [br]6. Girar hacia +X y correr hacia la zona de rampas.
## [br]7. Quieto mientras la cámara da una vuelta completa (360°) en 2 s.
## [br][br]Recorrido aproximado (x, z): (0, -9.8) al acabar de correr,
## (-2.9, -20.4) al acabar el sprint, (0.6, -22.9) tras el paso lateral y
## (8.7, -24.4) al final.

## Último tick (incluido) de cada fase.
const IDLE_END: int = 30
const RUN_END: int = 150
const SPRINT_END: int = 240
const JUMPS_END: int = 340
const STRAFE_END: int = 400
const APPROACH_END: int = 510
const ORBIT_END: int = 630

## Ticks en los que se empieza a pulsar el salto y cuánto se mantiene.
const JUMP_1_START: int = 246
const JUMP_2_START: int = 296
const JUMP_HOLD_TICKS: int = 6

## Vista (grados). Yaw positivo gira a la izquierda y negativo a la derecha;
## pitch negativo mira hacia abajo.
const BASE_PITCH_DEGREES: float = -10.0
const SPRINT_TURN_YAW_DEGREES: float = 30.0
const APPROACH_YAW_DEGREES: float = -90.0
const ORBIT_PITCH_DEGREES: float = -20.0
## Ticks que tarda la cámara en girar hacia las rampas al empezar la fase 6.
const APPROACH_TURN_TICKS: int = 30


## Entrada del tick [param tick]. Más allá del final devuelve una entrada en
## reposo con la última vista.
func next(tick: int) -> PlayerInput:
	var input: PlayerInput = PlayerInput.new()
	input.tick = tick
	var look: Vector2 = look_for(tick)
	input.look_yaw = look.x
	input.look_pitch = look.y

	if tick <= IDLE_END:
		pass
	elif tick <= RUN_END:
		input.move = Vector2(0.0, 1.0)
	elif tick <= SPRINT_END:
		input.move = Vector2(0.0, 1.0)
		input.buttons |= PlayerInput.SPRINT
	elif tick <= JUMPS_END:
		if _is_jump_held(tick):
			input.buttons |= PlayerInput.JUMP
	elif tick <= STRAFE_END:
		input.move = Vector2(1.0, 0.0)
	elif tick <= APPROACH_END:
		input.move = Vector2(0.0, 1.0)
	return input


## Vista de la cámara en el tick [param tick]: x = yaw, y = pitch (radianes,
## mismas convenciones que [PlayerInput]). El yaw se devuelve en [-PI, PI].
func look_for(tick: int) -> Vector2:
	var t: int = clampi(tick, 0, ORBIT_END)
	var yaw_degrees: float = 0.0
	var pitch_degrees: float = BASE_PITCH_DEGREES

	if t <= RUN_END:
		yaw_degrees = 0.0
	elif t <= SPRINT_END:
		# Giro lento y suave durante el sprint.
		var k: float = smoothstep(0.0, 1.0, _progress(t, RUN_END, SPRINT_END))
		yaw_degrees = lerpf(0.0, SPRINT_TURN_YAW_DEGREES, k)
	elif t <= STRAFE_END:
		yaw_degrees = SPRINT_TURN_YAW_DEGREES
	elif t <= APPROACH_END:
		var turn_end: int = STRAFE_END + APPROACH_TURN_TICKS
		var k: float = smoothstep(0.0, 1.0, _progress(t, STRAFE_END, turn_end))
		yaw_degrees = lerpf(SPRINT_TURN_YAW_DEGREES, APPROACH_YAW_DEGREES, k)
	else:
		# Órbita completa a velocidad constante; el pitch baja al principio para
		# ver el personaje algo desde arriba.
		var k: float = _progress(t, APPROACH_END, ORBIT_END)
		yaw_degrees = APPROACH_YAW_DEGREES + 360.0 * k
		var pitch_k: float = smoothstep(0.0, 1.0, minf(k * 4.0, 1.0))
		pitch_degrees = lerpf(BASE_PITCH_DEGREES, ORBIT_PITCH_DEGREES, pitch_k)

	return Vector2(wrapf(deg_to_rad(yaw_degrees), -PI, PI), deg_to_rad(pitch_degrees))


## Personaje que recorre la demo. Este guion es fijo y no lo necesita; las demos que siguen
## una ruta ([RouteDemoInput]) lo leen para orientarse hacia el siguiente punto de paso.
func bind(_character: PlayerCharacter) -> void:
	pass


## Número total de ticks del guion.
func get_length() -> int:
	return ORBIT_END


## true cuando ya se ha ejecutado el último tick del guion.
func is_finished(tick: int) -> bool:
	return tick >= get_length()


func _is_jump_held(tick: int) -> bool:
	return (tick >= JUMP_1_START and tick < JUMP_1_START + JUMP_HOLD_TICKS) \
			or (tick >= JUMP_2_START and tick < JUMP_2_START + JUMP_HOLD_TICKS)


## Avance en [0, 1] de [param tick] dentro de la fase que va de
## [param from_tick] (excluido) a [param to_tick] (incluido).
static func _progress(tick: int, from_tick: int, to_tick: int) -> float:
	return clampf(float(tick - from_tick) / float(to_tick - from_tick), 0.0, 1.0)
