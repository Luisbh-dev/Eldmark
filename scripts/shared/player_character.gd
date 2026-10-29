class_name PlayerCharacter
extends CharacterBody3D
## Personaje jugable con movimiento determinista.
##
## Toda la simulación ocurre en [method simulate], que es una función determinista de
## (estado, entrada, delta). Quien controla el personaje la llama exactamente una vez por tick
## de física: ahora el controlador local; en la fase 2 también el servidor y la predicción y
## repetición del cliente. Este script no lee Input, ni el tiempo, ni números aleatorios, para
## que el servidor dedicado pueda cargarlo sin depender de nada del cliente.
## [br][br]
## El origen del nodo está en los pies. Capa de colisión 2 (personajes), máscara 1 (mundo).

## Se emite en el tick en el que el personaje salta (para animación y sonido futuros).
signal jumped
## Se emite en el tick en el que el personaje vuelve a tocar el suelo.
signal landed

## Capa de física de la geometría estática del mundo (capa 1).
const WORLD_COLLISION_LAYER: int = 1 << 0
## Capa de física de los personajes (capa 2).
const CHARACTER_COLLISION_LAYER: int = 1 << 1
## Capa de los bloqueos invisibles que solo paran a los personajes (capa 3): límites del área
## jugable, orillas profundas, pretiles de los puentes. La cámara y los disparos no la miran.
const PLAYER_BLOCKER_LAYER: int = 1 << 2
## Longitud mínima del deseo de movimiento para girar el personaje hacia la cámara.
const FACING_MIN_WISH: float = 0.1
## Velocidad del sondeo hacia arriba con el que se reinicia el estado de suelo tras set_state().
const _FLOOR_PROBE_SPEED: float = 0.01
## Por debajo de esta longitud el deseo de movimiento no tiene dirección.
const _MIN_WISH_DIRECTION: float = 0.001

## Velocidad al correr (m/s).
@export var run_speed: float = 5.0
## Velocidad al esprintar (m/s). Solo hacia delante; se empieza a esprintar en el suelo.
@export var sprint_speed: float = 7.5
## Multiplicador de velocidad al moverse hacia atrás.
@export var backward_multiplier: float = 0.65
## Multiplicador de velocidad cuando el movimiento es sobre todo lateral.
@export var strafe_multiplier: float = 0.9
## Aceleración horizontal en el suelo al ganar velocidad (m/s²).
@export var ground_acceleration: float = 45.0
## Deceleración horizontal en el suelo al perder velocidad o frenar (m/s²).
@export var ground_deceleration: float = 60.0
## Aceleración horizontal en el aire (m/s²). En el aire el impulso se conserva: este control
## sirve para girar y ganar velocidad, y para frenar solo sin entrada o en sentido contrario.
@export var air_acceleration: float = 6.0
## Gravedad (m/s²).
@export var gravity: float = 22.0
## Velocidad vertical inicial del salto (m/s).
@export var jump_velocity: float = 8.0
## Velocidad de giro del personaje hacia la dirección de la cámara (rad/s).
@export var turn_speed: float = 14.0
## Velocidad máxima de caída (m/s).
@export var terminal_velocity: float = 50.0
## Ticks (contando el de la pulsación) durante los que una pulsación de salto sigue valiendo si
## llega un poco antes de tocar el suelo (búfer de salto). 1 = sin búfer. Como mucho
## [constant PlayerState.MAX_JUMP_BUFFER_TICKS], porque viaja en el estado de red.
@export_range(1, 15) var jump_buffer_window: int = 6
## Ticks en el aire, tras dejar el suelo sin saltar (al caer por un borde), en los que todavía
## se puede saltar ("coyote time"). 0 = desactivado. Como mucho
## [constant PlayerState.MAX_COYOTE_TICKS], porque viaja en el estado de red.
@export_range(0, 7) var coyote_window: int = 6

## Orientación del personaje en radianes (misma convención que [member Node3D.rotation].y; 0 mira
## hacia -Z). Asignarla también gira el nodo.
## [br][br]
## Se redondea a float de 32 bits ([method PlayerState.to_f32]), la precisión con la que viaja en
## [method PlayerState.encode]. Sin el redondeo, el resultado de [code]atan2[/code] no sobreviviría
## a la ida y vuelta por la red y ninguna comparación exacta del estado pasaría.
## [br][br]
## La base del nodo se escribe directamente a partir del yaw. No se usa [member Node3D.rotation]
## porque Godot recalcula entonces la escala a partir de la base anterior y el redondeo la va
## alejando de 1 con cada giro; esa escala oculta cambia la cápsula de colisión y rompe la
## repetición determinista (reconciliación de la fase 2).
var yaw: float = 0.0:
	set(value):
		yaw = PlayerState.to_f32(value)
		basis = Basis(Vector3.UP, yaw)
## Si es false, [method simulate] no emite [signal jumped] ni [signal landed]. Se desactiva durante
## las repeticiones de la reconciliación y el avance neutro de la predicción del cliente, para no
## duplicar sonidos ni animaciones. No altera la simulación.
var events_enabled: bool = true
## Si el personaje estaba en el suelo al terminar el último tick. [method simulate] usa este valor
## (y no is_on_floor()) al empezar cada tick, para que un estado restaurado se comporte igual.
var grounded: bool = false
## Botones de la última entrada aplicada (para detectar flancos de subida).
var prev_buttons: int = 0
## Tick de la última entrada aplicada.
var last_input_tick: int = 0
## Ticks en el aire que quedan para poder saltar tras dejar el suelo sin saltar (coyote time).
var coyote_ticks: int = 0
## Ticks que le quedan a una pulsación de salto guardada en el búfer (0 = ninguna pendiente).
var jump_buffer_ticks: int = 0
## Estado de combate (docs/combate.md, sección 3): acción en curso, resistencia, controles...
## Entra en [method get_state] y [method set_state], y [method simulate] lo avanza con
## [method ActionMachine.step] al principio de cada tick.
var combat: CombatState = CombatState.initial(
		CombatCatalog.rules(), CombatCatalog.default_weapon_id())
## Velocidad de aterrizaje (m/s, positiva hacia abajo) medida justo antes de move_and_slide() en
## el tick en que [member grounded] pasa a true; 0 en los demás ticks. El servidor la usa para el
## daño por caída. No viaja en el estado: es una salida de [method simulate].
var last_landing_speed: float = 0.0

# Tras set_state(), el estado interno de CharacterBody3D (suelo, normal del suelo) puede
# corresponder a otro tick; se recalcula al principio de la siguiente simulación.
var _floor_contact_dirty: bool = false
var _warned_tick_context: bool = false


func _ready() -> void:
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.35
	floor_constant_speed = true
	floor_stop_on_slope = true
	collision_layer = CHARACTER_COLLISION_LAYER
	collision_mask = WORLD_COLLISION_LAYER | PLAYER_BLOCKER_LAYER
	# Respeta una rotación asignada antes de entrar en el árbol (por ejemplo, la del punto de
	# aparición) y deja la base del nodo limpia (solo yaw, escala 1).
	yaw = rotation.y


## Avanza la simulación un tick con la entrada dada. Determinista: no lee Input, tiempo,
## aleatoriedad ni estado global, solo los miembros de estado ([member yaw],
## [member grounded], [member prev_buttons], [member last_input_tick], [member coyote_ticks],
## [member jump_buffer_ticks], [member combat], la posición y [member CharacterBody3D.velocity]).
## [br][br]
## Al principio de cada tick avanza la máquina de acciones ([method ActionMachine.step]), que
## decide cuánto puede moverse, girar, saltar y esprintar el personaje durante un ataque, un
## bloqueo, una esquiva o un control; sin acción, el movimiento es el de siempre.
## [br][br]
## [b]Importante:[/b] move_and_slide() usa internamente el delta del tick de física, así que
## [param delta] debe ser exactamente [code]1.0 / Engine.physics_ticks_per_second[/code] y la
## llamada debe hacerse dentro del tick de física (desde _physics_process o tras
## [code]await get_tree().physics_frame[/code]). Fuera de él, move_and_slide() usaría el delta
## de _process y el resultado dejaría de ser determinista.
func simulate(input: PlayerInput, delta: float) -> void:
	_check_tick_context(delta)
	if _floor_contact_dirty:
		_resync_floor_contact()
	var was_grounded: bool = grounded

	# Máquina de acciones: ataques, bloqueo, esquiva, resistencia y controles. Decide cuánto puede
	# moverse el personaje este tick (sin acción, el movimiento es el de siempre).
	var action: ActionMachine.Output = ActionMachine.step(combat, input, was_grounded)

	# Dirección deseada en el plano horizontal, relativa al yaw de la cámara.
	var look_basis := Basis(Vector3.UP, input.look_yaw)
	var forward: Vector3 = look_basis * Vector3.FORWARD
	var right: Vector3 = look_basis * Vector3.RIGHT
	var wish: Vector3 = (right * input.move.x + forward * input.move.y).limit_length(1.0)
	var wish_length: float = wish.length()

	# Orientación: al moverse, el personaje gira hacia donde mira la cámara; durante una acción
	# lo decide ella (gira aunque esté quieto, salta a la cámara en el primer tick o no gira). El
	# yaw se asigna siempre (también parado) para que su setter reescriba la base del nodo por si
	# algo externo tocó la rotación o la escala.
	var new_yaw: float = yaw
	if action.snap_yaw:
		new_yaw = wrapf(input.look_yaw, -PI, PI)
	elif action.turn_rate >= 0.0:
		new_yaw = wrapf(rotate_toward(yaw, input.look_yaw, action.turn_rate * delta), -PI, PI)
	elif wish_length > FACING_MIN_WISH:
		new_yaw = wrapf(rotate_toward(yaw, input.look_yaw, turn_speed * delta), -PI, PI)
	yaw = new_yaw

	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	if action.forced_velocity:
		# Esquiva o empuje: la velocidad horizontal la impone la acción, sin aceleración.
		velocity.x = action.velocity.x
		velocity.z = action.velocity.z
	else:
		# Velocidad objetivo. El esprint solo empieza en el suelo; en el aire se conserva el
		# impulso que se traía (ver más abajo).
		var target_velocity: Vector3
		if action.scaled_movement:
			# Dentro de una acción: carrera reducida más el avance del ataque hacia donde mira el
			# personaje (ya girado este tick).
			target_velocity = wish * run_speed * action.move_scale
			if action.lunge_speed != 0.0:
				target_velocity += (Basis(Vector3.UP, yaw) * Vector3.FORWARD) * action.lunge_speed
		else:
			var speed: float = run_speed
			if action.allow_sprint and input.has(PlayerInput.SPRINT) and input.move.y > 0.5 \
					and grounded:
				speed = sprint_speed
			if input.move.y < 0.0:
				speed *= backward_multiplier
			if absf(input.move.x) > absf(input.move.y):
				speed *= strafe_multiplier
			target_velocity = wish * speed

		# Aceleración horizontal. En el suelo se usa la deceleración cuando el objetivo reduce la
		# velocidad en la dirección actual (frenar, soltar el esprint, girar o invertir el
		# sentido).
		var rate: float = air_acceleration
		if grounded:
			var slowing_down: bool = horizontal.dot(target_velocity) < horizontal.length_squared()
			rate = ground_deceleration if slowing_down else ground_acceleration
		elif wish_length > _MIN_WISH_DIRECTION and not (action.scaled_movement \
				and action.move_scale <= 0.0):
			# En el aire no se frena en la dirección deseada: un salto o una caída esprintando
			# mantienen su velocidad mientras se siga empujando hacia delante. El control aéreo
			# solo gira el movimiento o añade velocidad hasta el objetivo. No vale para una
			# acción que no deja moverse (muerto, aturdido o tambaleado sin empuje, con
			# move_scale 0): esas frenan, y el stick no las dirige.
			var wish_direction: Vector3 = wish / wish_length
			var carried_speed: float = horizontal.dot(wish_direction)
			if carried_speed > target_velocity.length():
				target_velocity = wish_direction * carried_speed
		horizontal = horizontal.move_toward(target_velocity, rate * delta)
		velocity.x = horizontal.x
		velocity.z = horizontal.z

	# Gravedad, con velocidad de caída limitada.
	if not grounded:
		velocity.y = maxf(velocity.y - gravity * delta, -terminal_velocity)

	# Salto: el flanco de subida del botón entra en el búfer y se salta si hay suelo o aún queda
	# coyote time. Así no se pierde un salto pulsado justo antes de aterrizar ni justo después
	# de caer por un borde, y mantener el botón no repite el salto. Las acciones que lo impiden
	# (ataque, esquiva, controles) lo dejan en el búfer.
	var just_pressed: int = input.buttons & ~prev_buttons
	jump_buffer_ticks = maxi(jump_buffer_ticks - 1, 0)
	if (just_pressed & PlayerInput.JUMP) != 0:
		jump_buffer_ticks = clampi(jump_buffer_window, 1, PlayerState.MAX_JUMP_BUFFER_TICKS)
	var jumped_now: bool = false
	if action.allow_jump and jump_buffer_ticks > 0 and (grounded or coyote_ticks > 0):
		velocity.y = jump_velocity
		jump_buffer_ticks = 0
		jumped_now = true
		if events_enabled:
			jumped.emit()

	# Velocidad de caída justo antes de que move_and_slide() la anule al aterrizar.
	var fall_speed: float = maxf(-velocity.y, 0.0)
	move_and_slide()

	grounded = is_on_floor()
	last_landing_speed = fall_speed if grounded and not was_grounded else 0.0
	if grounded and not was_grounded and events_enabled:
		landed.emit()
	# El coyote time se recarga mientras se pisa suelo (también en el tick en el que se deja) y
	# se consume en el aire. Saltar lo agota para que no haya un segundo salto en el aire.
	if jumped_now:
		coyote_ticks = 0
	elif grounded or was_grounded:
		coyote_ticks = clampi(coyote_window, 0, PlayerState.MAX_COYOTE_TICKS)
	else:
		coyote_ticks = maxi(coyote_ticks - 1, 0)
	# El bit de entrada sustituida no es un botón: no se guarda, para que el estado no dependa de
	# si la entrada llegó o se repitió.
	prev_buttons = input.buttons & ~PlayerInput.SUBSTITUTED
	last_input_tick = input.tick


## Devuelve una copia del estado de simulación actual.
func get_state() -> PlayerState:
	var state := PlayerState.new()
	state.position = global_position if is_inside_tree() else position
	state.velocity = velocity
	state.yaw = yaw
	state.grounded = grounded
	state.prev_buttons = prev_buttons
	state.last_input_tick = last_input_tick
	state.coyote_ticks = coyote_ticks
	state.jump_buffer_ticks = jump_buffer_ticks
	state.combat = combat.duplicate_state()
	return state


## Restaura un estado de simulación (posición global, velocidad, yaw y rotación, grounded,
## prev_buttons, last_input_tick, los contadores de salto y el estado de combate). No llama a
## reset_physics_interpolation(): decide quien llama.
func set_state(state: PlayerState) -> void:
	yaw = state.yaw
	if is_inside_tree():
		global_position = state.position
	else:
		position = state.position
	velocity = state.velocity
	grounded = state.grounded
	prev_buttons = state.prev_buttons
	last_input_tick = state.last_input_tick
	coyote_ticks = state.coyote_ticks
	jump_buffer_ticks = state.jump_buffer_ticks
	combat.copy_from(state.combat)
	_floor_contact_dirty = true


## Velocidad en el plano horizontal (m/s).
func get_horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


## Punto que sigue la cámara (a la altura de la cabeza).
func get_camera_target() -> Node3D:
	return $CameraTarget as Node3D


# move_and_slide() depende del estado de suelo que dejó la llamada anterior (para el snap al suelo
# y para no trepar paredes). Tras set_state() ese estado puede ser de otro tick, así que se rehace
# a partir de la posición y de "grounded" restauradas: un desplazamiento minúsculo hacia arriba
# (sin snap) reinicia el estado y, si el personaje estaba en el suelo, apply_floor_snap() recupera
# el contacto y la normal del suelo. La posición y la velocidad se dejan exactamente como estaban.
func _resync_floor_contact() -> void:
	if not is_inside_tree():
		return
	_floor_contact_dirty = false
	var saved_transform: Transform3D = global_transform
	var saved_velocity: Vector3 = velocity
	velocity = up_direction * _FLOOR_PROBE_SPEED
	move_and_slide()
	global_transform = saved_transform
	if grounded:
		apply_floor_snap()
		global_transform = saved_transform
	velocity = saved_velocity


# Diagnóstico: avisa una vez si simulate() se usa fuera del tick de física o con un delta
# distinto del de la física, porque entonces move_and_slide() no avanza lo mismo que el resto
# del paso. No afecta al resultado de la simulación.
func _check_tick_context(delta: float) -> void:
	if _warned_tick_context:
		return
	if not Engine.is_in_physics_frame():
		_warned_tick_context = true
		push_warning(
			"PlayerCharacter.simulate() se ha llamado fuera del tick de física; "
			+ "move_and_slide() usará el delta de _process y la simulación no será determinista."
		)
	elif not is_equal_approx(delta, get_physics_process_delta_time()):
		_warned_tick_context = true
		push_warning(
			"PlayerCharacter.simulate(): delta (%f) no coincide con el delta de física (%f) "
			% [delta, get_physics_process_delta_time()]
			+ "que usa move_and_slide()."
		)
