class_name BotBrain
extends RefCounted
## Cerebro de un bot: genera entradas de jugador deterministas para las pruebas y la carga.
##
## Lo usan los bots del cliente (fase 2) y los jugadores falsos del servidor. Es una función de
## (semilla, secuencia de llamadas): no lee el reloj ni aleatoriedad global, solo su propio
## [RandomNumberGenerator]. Con la misma semilla y las mismas posiciones, produce siempre las mismas
## entradas.
## [br][br]
## Patrones ([enum Pattern]):
## [br]- [constant WANDER]: pasea. Cada 60-180 ticks cambia de dirección o se para un momento,
## a veces esprinta y salta de vez en cuando.
## [br]- [constant CIRCLE]: da vueltas alrededor de [code]home[/code] a media distancia del radio.
## [br]- [constant IDLE]: no hace nada (entradas neutras).
## [br]- [constant JUMPY]: como [constant WANDER], pero salta casi siempre que puede.
## [br]- [constant COMBAT]: busca al enemigo más cercano (lo da [method set_enemy_finder]), se
## acerca, ataca (ligeros en combo y, a veces, un fuerte cargado), y de vez en cuando bloquea o esquiva.
## Sin enemigo a la vista pasea como [constant WANDER] (sin saltar). Todo sale de su generador con
## semilla, así que con la misma semilla y las mismas posiciones hace siempre lo mismo.
## [br]- [constant SIEGE] (GUE-15, docs/fuerte.md sección 7): asedia o defiende un fuerte. Necesita un
## [SiegeView] y unas [ApproachRoutes] ([method set_siege]). Ver abajo.
## [br][br]
## Si el bot se aleja de [code]home[/code] más que el radio, vuelve hacia él hasta quedar dentro
## de [constant RETURN_RELEASE_FRACTION] del radio.
## [br][br]
## [b]Asedio ([constant SIEGE]).[/b] En cada tick elige, por este orden:
## [br]1. Si un enemigo (el que da [method set_enemy_finder], como en [constant COMBAT]) está a menos de
## [constant SIEGE_FIGHT_RANGE] y se puede alcanzar (no está tras una puerta que cierra el paso a su reino),
## pelea con él igual que [constant COMBAT]. Mientras el círculo no está activo, antes que a nadie busca a los PNJ
## que guardan el fuerte (los Huecos, el Capitán y la guarnición del dueño; [method set_defender_finder], F6b): el
## capitán tiene que caer para abrir el círculo. Si persiguiendo a alguien que está a más de
## [constant COMBAT_ENGAGE_DISTANCE] no se le acerca en [constant SIEGE_STUCK_TICKS] ticks (un muro, la pasarela),
## deja de perseguir durante [constant SIEGE_CHASE_GIVE_UP_TICKS] ticks y sigue con su plan.
## [br]2. [b]Marcha[/b]: sigue la ruta de su reino, [constant ApproachRoutes.BRIDGE] o
## [constant ApproachRoutes.FORD] (la elige con su generador al empezar y tras cada reaparición), hasta la
## explanada delante de la puerta, esprintando por los tramos largos si no hay enemigos cerca.
## [br]3. [b]Asalto[/b]: llegado a la explanada, si la puerta cierra el paso a su reino
## ([method SiegeView.is_gate_closed_for]) se acerca a ella y la golpea (ligeros en combo y algún fuerte).
## [br]4. [b]Círculo[/b]: con la puerta abierta para su reino (rota, o suya) entra en el círculo de captura y
## se queda dentro cerca del centro: los atacantes lo toman y el dueño lo defiende (la pasarela, que pide
## navegación, queda para los PNJ).
## [br]Si no avanza durante [constant SIEGE_STUCK_TICKS] mientras camina, primero prueba un salto y, si sigue
## igual, un desvío lateral. Un salto de posición de más de [constant SIEGE_TELEPORT_DISTANCE] metros en un
## tick (reaparición) reinicia la ruta.
## [br][b]Golpes avisados[/b] (F6b): antes que todo lo anterior, si está en la zona de un golpe avisado con
## TELEGRAPH (el imbloqueable del Capitán del Vado y los fuertes de los demás PNJ; los da
## [method set_threat_finder]), sale de ella en línea recta desde quien golpea, con una esquiva al empezar y
## esprintando, sin bloquear ([constant SiegeTask.EVADE]). Bloquear no frena el imbloqueable y salir es lo más simple
## que funciona con todos; no usa el generador, así que sigue siendo determinista.

## [constant SIEGE] va al final para no mover los valores de los demás patrones.
enum Pattern { WANDER, CIRCLE, IDLE, JUMPY, COMBAT, SIEGE }

## Qué hace un bot de [constant SIEGE] en este tick ([method get_siege_task]). [constant EVADE] (F6b, al final
## para no mover los demás): sale de la zona de un golpe avisado.
enum SiegeTask { NONE, FIGHT, MARCH, ASSAULT, HOLD, EVADE }

## Duración mínima de un tramo de paseo (ticks).
const SEGMENT_MIN_TICKS: int = 60
## Duración máxima de un tramo de paseo (ticks).
const SEGMENT_MAX_TICKS: int = 180
## Probabilidad de que un tramo de paseo sea una parada.
const PAUSE_CHANCE: float = 0.2
## Probabilidad de que un tramo en marcha sea de esprint.
const SPRINT_CHANCE: float = 0.3
## Probabilidad de que un tramo en marcha lleve el movimiento ligeramente lateral.
const STRAFE_CHANCE: float = 0.25
## Separación entre saltos de un paseante (ticks, mínimo y máximo).
const WANDER_JUMP_GAP_TICKS: Vector2i = Vector2i(120, 420)
## Separación entre saltos de un [constant JUMPY] (ticks, mínimo y máximo).
const JUMPY_JUMP_GAP_TICKS: Vector2i = Vector2i(20, 60)
## Ticks que se mantiene pulsado el botón de salto (mínimo y máximo).
const JUMP_HOLD_TICKS: Vector2i = Vector2i(2, 5)
## Fracción del radio a la que el bot que volvía a casa se da por llegado.
const RETURN_RELEASE_FRACTION: float = 0.6
## Fracción del radio a la que gira un [constant CIRCLE].
const CIRCLE_RADIUS_FRACTION: float = 0.5
## Radio mínimo de la circunferencia de un [constant CIRCLE] (m).
const CIRCLE_MIN_RADIUS: float = 2.0
## [constant COMBAT]: distancia (m) a la que ve a un enemigo, a la que se detiene para golpear (el
## sector del arma llega a 2,6 m) y a partir de la cual esprinta para alcanzarlo.
const COMBAT_SIGHT_RANGE: float = 40.0
const COMBAT_ATTACK_DISTANCE: float = 1.8
const COMBAT_SPRINT_DISTANCE: float = 8.0
## [constant COMBAT]: a esta distancia empieza a pelear (ataca, bloquea o esquiva).
const COMBAT_ENGAGE_DISTANCE: float = 3.0
## [constant COMBAT]: ticks que se mantiene pulsado un toque de ataque.
const COMBAT_TAP_TICKS: int = 2
## [constant COMBAT]: ticks entre dos ataques (enlazan el combo: la ventana de enlace es el final de
## la recuperación) y entre una defensa y la siguiente decisión.
const COMBAT_ATTACK_GAP_TICKS: Vector2i = Vector2i(26, 34)
## [constant COMBAT]: probabilidades de cada decisión (el resto es un ligero) y duraciones de
## bloqueo y de carga del fuerte (ticks).
const COMBAT_BLOCK_CHANCE: float = 0.14
const COMBAT_DODGE_CHANCE: float = 0.10
const COMBAT_HEAVY_CHANCE: float = 0.12
const COMBAT_BLOCK_TICKS: Vector2i = Vector2i(30, 80)
const COMBAT_HEAVY_HOLD_TICKS: Vector2i = Vector2i(24, 50)
## [constant COMBAT]: ticks que se recuerda la posición del enemigo antes de volver a buscarlo.
const COMBAT_RETARGET_TICKS: int = 4
## [constant SIEGE]: distancia (m) a la que un enemigo le hace dejar su plan para pelear.
const SIEGE_FIGHT_RANGE: float = 12.0
## [constant SIEGE]: radio (m) en el que se da por alcanzado un punto de la ruta.
const SIEGE_WAYPOINT_RADIUS: float = 2.5
## [constant SIEGE]: distancia (m) a la puerta a la que se detiene para golpearla (el sector del arma
## llega a 2,6 m de él y la cara de la puerta está a 0,25 m de su centro).
const SIEGE_GATE_ATTACK_DISTANCE: float = 2.3
## [constant SIEGE]: dentro del círculo se coloca a esta fracción del radio del centro.
const SIEGE_CIRCLE_HOLD_FRACTION: float = 0.5
## [constant SIEGE]: para entrar en el fuerte se alinea con el eje de la puerta (a esta distancia lateral como
## mucho, en metros), delante de ella a [constant SIEGE_GATE_FRONT_DISTANCE], y la cruza hasta un punto a
## [constant SIEGE_GATE_EXIT_DISTANCE] dentro. Sin esto, al llegar al último punto de la ruta, que está de
## lado, el bot tiraba derecho al círculo y se estrellaba contra la empalizada.
const SIEGE_GATE_AXIS_TOLERANCE: float = 1.0
## [constant SIEGE]: medio ancho (m) del vano por el que cabe el bot (el vano mide 4 m; menos su radio). Pegado a la
## pared de la puerta pero más a un lado que esto, primero vuelve delante de la puerta.
const SIEGE_GATE_OPENING_HALF_WIDTH: float = 1.6
const SIEGE_GATE_FRONT_DISTANCE: float = 4.5
const SIEGE_GATE_EXIT_DISTANCE: float = 2.5
## [constant SIEGE]: radio (m) que usa si el [SiegeView] no sabe el del círculo.
const SIEGE_DEFAULT_CIRCLE_RADIUS: float = 5.0
## [constant SIEGE]: esprinta si falta más de esta distancia (m) y no hay enemigos a menos de la otra.
const SIEGE_SPRINT_DISTANCE: float = 9.0
const SIEGE_SPRINT_ENEMY_CLEARANCE: float = 25.0
## [constant SIEGE]: un salto de posición de más de esta distancia (m) en un tick es una reaparición.
const SIEGE_TELEPORT_DISTANCE: float = 5.0
## [constant SIEGE]: si está a más de esta distancia (m) del punto que persigue, busca el más cercano.
const SIEGE_LOST_DISTANCE: float = 70.0
## [constant SIEGE]: a menos de estos metros del círculo, y al otro lado de la puerta, ya está dentro del
## fuerte y no necesita la ruta (si el [SiegeView] no sabe el tamaño del recinto; si lo sabe, cuenta el recinto con
## [constant SIEGE_ENCLOSURE_MARGIN] de holgura: pegado a la empalizada por fuera no está dentro).
const SIEGE_INSIDE_RADIUS: float = 30.0
const SIEGE_ENCLOSURE_MARGIN: float = 0.5
## [constant SIEGE]: fuera del recinto pero a su lado o detrás (una persecución le sacó de la ruta), rodea la
## empalizada por sus esquinas, a esta distancia (m) de las paredes, hasta la pared de la puerta; da una esquina por
## alcanzada a [constant SIEGE_WAYPOINT_RADIUS].
const SIEGE_CORNER_MARGIN: float = 6.0
## [constant SIEGE]: ticks sin avanzar [constant SIEGE_STUCK_MIN_PROGRESS] metros tras los que se
## considera atascado; ticks que dura un salto o un desvío para desatascarse; cada cuántos ticks se pulsa
## el salto; y ángulo (rad) del desvío.
const SIEGE_STUCK_TICKS: int = 180
const SIEGE_STUCK_MIN_PROGRESS: float = 1.0
const SIEGE_JUMP_WINDOW_TICKS: int = 40
const SIEGE_JUMP_PULSE_TICKS: int = 20
const SIEGE_DETOUR_TICKS: int = 60
const SIEGE_DETOUR_ANGLE: float = 1.2
## [constant SIEGE]: margen (m) que añade al alcance de un golpe avisado y al borde de su semiplano para darse por
## dentro de su zona (el radio de la cápsula, 0,4 m, y algo más para no quedarse en el filo).
const SIEGE_THREAT_MARGIN: float = 1.0
## [constant SIEGE]: mientras sigue en la zona de un golpe avisado, cada cuántos ticks pulsa la esquiva (la primera,
## nada más verlo: 4,5 m en 0,45 s, que lo sacan del alcance del golpe del Capitán antes del impacto).
const SIEGE_EVADE_DODGE_TICKS: int = 15
## [constant SIEGE]: si persiguiendo a alguien que está a más de [constant COMBAT_ENGAGE_DISTANCE] no se acerca
## [constant SIEGE_STUCK_MIN_PROGRESS] metros en [constant SIEGE_STUCK_TICKS] ticks (está tras un muro, en la pasarela
## o huye más rápido), deja de perseguir a nadie que no esté a esa distancia durante estos ticks y sigue con su plan.
const SIEGE_CHASE_GIVE_UP_TICKS: int = 600

# Cómo se desatasca un bot de asedio.
enum _Unstick { NONE, JUMP, DETOUR }


## Un golpe avisado (TELEGRAPH, docs/fuerte.md sección 5) que un bot de [constant SIEGE] evita: un sector de
## alcance [member radius] con el vértice en [member origin] (los pies de quien golpea) y orientado según
## [member yaw] (la convención de [PlayerInput]: el yaw 0 mira hacia -Z). El aviso no dice el ángulo del sector, así
## que se toma el semiplano de delante: cubre de sobra los 120° del golpe del Capitán.
class Threat:
	extends RefCounted

	var origin: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var radius: float = 0.0


	func _init(new_origin: Vector3 = Vector3.ZERO, new_yaw: float = 0.0, new_radius: float = 0.0) -> void:
		origin = new_origin
		yaw = new_yaw
		radius = new_radius


	## true si [param position] está en la zona de peligro con [param margin] metros de más: a menos del alcance
	## más el margen (en horizontal) y no más de [param margin] por detrás de quien golpea.
	func covers(position: Vector3, margin: float) -> bool:
		var offset := Vector3(position.x - origin.x, 0.0, position.z - origin.z)
		if offset.length() > radius + margin:
			return false
		var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
		return offset.dot(forward) >= -margin

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _pattern: Pattern = Pattern.WANDER
var _home: Vector3 = Vector3.ZERO
var _radius: float = 30.0
var _idle_from: int = -1
var _started: bool = false
var _returning: bool = false
var _circle_sign: float = 1.0
# Tramo actual de paseo.
var _next_change_tick: int = 0
var _heading: float = 0.0
var _move: Vector2 = Vector2.ZERO
var _sprint: bool = false
# Salto: tick en el que empieza el siguiente y tick en el que se suelta el botón.
var _next_jump_tick: int = 0
var _jump_release_tick: int = -1
# COMBAT: quién busca al enemigo, el último visto, y qué botón se mantiene hasta cuándo.
var _enemy_finder: Callable = Callable()
var _enemy_position: Variant = null
var _enemy_checked_tick: int = -1000
var _hold_buttons: int = 0
var _hold_until: int = -1
var _hold_move: Vector2 = Vector2.ZERO
var _next_decision_tick: int = 0
# SIEGE: el fuerte, las rutas y el reino del bot; la ruta que sigue y por qué punto va.
var _siege: SiegeView = null
var _siege_routes: ApproachRoutes = null
var _siege_realm: int = 0
var _siege_route_id: StringName = &""
var _siege_route_chosen: bool = false
var _siege_route_points: PackedVector2Array = PackedVector2Array()
var _siege_route_index: int = 0
var _siege_task: SiegeTask = SiegeTask.NONE
# SIEGE: la última posición (para detectar una reaparición) y el estado del desatasco.
var _siege_last_position: Vector3 = Vector3.ZERO
var _siege_has_position: bool = false
var _siege_stuck_ref_position: Vector3 = Vector3.ZERO
var _siege_stuck_ref_tick: int = -1
var _siege_stuck_count: int = 0
var _siege_unstick: _Unstick = _Unstick.NONE
var _siege_unstick_start: int = 0
var _siege_unstick_until: int = -1
var _detour_sign: float = 1.0
# SIEGE: el botón mantenido apunta a la puerta (y no a un enemigo).
var _hold_aims_gate: bool = false
# SIEGE: quién da los golpes avisados que hay que evitar, y desde qué tick está saliendo de uno (-1 = no lo está).
var _siege_threat_finder: Callable = Callable()
var _siege_evade_since: int = -1
# SIEGE: quién da el PNJ defensor más cercano, el último visto y cuándo se miró.
var _siege_defender_finder: Callable = Callable()
var _siege_defender_position: Variant = null
var _siege_defender_checked_tick: int = -1000
# SIEGE: la persecución en curso (distancia y tick de referencia; -1 = ninguna) y hasta cuándo no persigue.
var _siege_chase_ref_distance: float = 0.0
var _siege_chase_ref_tick: int = -1
var _siege_chase_blocked_until: int = -1


## [param rng_seed] fija la secuencia. [param home] y [param radius] delimitan la zona por la
## que se mueve el bot (en el plano horizontal).
func _init(rng_seed: int, pattern: Pattern = Pattern.WANDER, home: Vector3 = Vector3.ZERO,
		radius: float = 30.0) -> void:
	_rng.seed = rng_seed
	_pattern = pattern
	_home = home
	_radius = maxf(radius, 1.0)
	_circle_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0


## Entrada sin cuantizar para [param tick] (la cuantiza quien llama). [param position] y
## [param yaw] son los actuales del personaje. Cambia de dirección cada 60-180 ticks, salta y
## esprinta a veces y vuelve hacia home si sale del radio.
func next_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if _pattern == Pattern.IDLE or (_idle_from >= 0 and tick >= _idle_from):
		input.look_yaw = yaw
		return input
	if _pattern == Pattern.COMBAT:
		var fighting: PlayerInput = _combat_input(tick, position, yaw)
		if fighting != null:
			return fighting
	elif _pattern == Pattern.SIEGE and _siege != null:
		return _siege_input(tick, position, yaw)
	if not _started:
		_started = true
		_next_change_tick = tick
		_schedule_jump(tick)

	var to_home: Vector3 = _home - position
	to_home.y = 0.0
	var distance: float = to_home.length()
	if distance > _radius:
		_returning = true
	elif distance < _radius * RETURN_RELEASE_FRACTION:
		_returning = false

	if _returning:
		input.look_yaw = _yaw_toward(to_home, yaw)
		input.move = Vector2(0.0, 1.0)
		# Un tramo nuevo al llegar, para no retomar un rumbo que lo vuelva a sacar del radio.
		_next_change_tick = tick
	elif _pattern == Pattern.CIRCLE:
		input.look_yaw = _circle_yaw(position, yaw)
		input.move = Vector2(0.0, 1.0)
	else:
		if tick >= _next_change_tick:
			_start_segment(tick)
		input.look_yaw = _heading
		input.move = _move
		if _sprint:
			input.buttons |= PlayerInput.SPRINT

	if _pattern == Pattern.WANDER or _pattern == Pattern.JUMPY:
		_update_jump(tick)
		if tick < _jump_release_tick:
			input.buttons |= PlayerInput.JUMP
	return input


## Función con la que los patrones [constant COMBAT] y [constant SIEGE] buscan enemigos:
## [code](position: Vector3) -> Variant[/code] devuelve la posición (un [Vector3]) del enemigo más
## cercano a [param position], o null si no hay ninguno. Sin ella, [constant COMBAT] pasea y
## [constant SIEGE] solo marcha, asalta y defiende.
func set_enemy_finder(finder: Callable) -> void:
	_enemy_finder = finder
	_enemy_checked_tick = -1000


## true si el patrón [constant COMBAT] o [constant SIEGE] ya tiene quién le busque enemigos.
func has_enemy_finder() -> bool:
	return _enemy_finder.is_valid()


## Patrón del bot.
func get_pattern() -> Pattern:
	return _pattern


## Desde [param tick] (incluido) solo devuelve entradas neutras: sin movimiento ni botones y
## mirando al yaw actual. Sirve para las pruebas de convergencia de la reconciliación.
func set_idle_from(tick: int) -> void:
	_idle_from = tick


## Da al patrón [constant SIEGE] el fuerte que asedia o defiende ([param view], que quien lo lleva mantiene
## al día y puede compartirse entre bots), las rutas de la zona ([param routes], null = va derecho a la
## puerta) y el reino del bot ([param realm], código de red). Reinicia la ruta.
func set_siege(view: SiegeView, routes: ApproachRoutes, realm: int) -> void:
	_siege = view
	_siege_routes = routes
	_siege_realm = realm
	_reset_route()


## Función con la que el patrón [constant SIEGE] se entera de los golpes avisados (TELEGRAPH) que hay que evitar:
## [code](position: Vector3) -> Array[/code] devuelve los [BotBrain.Threat] activos de quienes le pueden dañar
## (puede devolver también los lejanos: el cerebro mira si está dentro de cada uno). Sin ella no evita nada.
func set_threat_finder(finder: Callable) -> void:
	_siege_threat_finder = finder


## Función con la que el patrón [constant SIEGE] busca primero a los PNJ que defienden el fuerte (los Huecos, el
## Capitán y la guarnición del dueño): [code](position: Vector3) -> Variant[/code] devuelve la posición del PNJ enemigo
## vivo más cercano, o null. Mientras el círculo no está activo (el capitán vive), si hay uno a tiro pelea con él antes
## que con el enemigo de [method set_enemy_finder] (un jugador que le pegue no le aparta de él), y como el buscador da
## siempre el más cercano, sigue con el mismo hasta que muere o se aleja. Con el círculo activo, o sin ella, pelea con
## el más cercano de todos.
func set_defender_finder(finder: Callable) -> void:
	_siege_defender_finder = finder
	_siege_defender_checked_tick = -1000


## true si el patrón [constant SIEGE] ya tiene quién le busque los PNJ defensores.
func has_defender_finder() -> bool:
	return _siege_defender_finder.is_valid()


## true si el patrón [constant SIEGE] ya tiene quién le avise de los golpes.
func has_threat_finder() -> bool:
	return _siege_threat_finder.is_valid()


## true si el patrón [constant SIEGE] ya sabe qué fuerte asedia.
func has_siege() -> bool:
	return _siege != null


## El [SiegeView] del patrón [constant SIEGE] (null si no se le ha dado).
func get_siege_view() -> SiegeView:
	return _siege


## Ruta que sigue un bot de [constant SIEGE] ([constant ApproachRoutes.BRIDGE] o
## [constant ApproachRoutes.FORD]); vacía mientras no ha elegido ninguna o si no hay rutas.
func get_siege_route() -> StringName:
	return _siege_route_id


## Índice del punto de la ruta que persigue un bot de [constant SIEGE] (el tamaño de la ruta si ya la ha
## recorrido entera).
func get_siege_route_index() -> int:
	return _siege_route_index


## Lo que hizo un bot de [constant SIEGE] en el último tick.
func get_siege_task() -> SiegeTask:
	return _siege_task


# Entrada del patrón COMBAT, o null si no hay enemigo a la vista (entonces pasea).
func _combat_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	_refresh_enemy(tick, position)
	if not _enemy_position is Vector3:
		_hold_until = -1
		return null
	var to_enemy: Vector3 = (_enemy_position as Vector3) - position
	to_enemy.y = 0.0
	var distance: float = to_enemy.length()
	if distance > COMBAT_SIGHT_RANGE:
		_hold_until = -1
		return null
	return _fight_input(tick, to_enemy, distance, yaw)


# Vuelve a buscar al enemigo más cercano cada COMBAT_RETARGET_TICKS ticks.
func _refresh_enemy(tick: int, position: Vector3) -> void:
	if tick - _enemy_checked_tick >= COMBAT_RETARGET_TICKS:
		_enemy_checked_tick = tick
		_enemy_position = _enemy_finder.call(position) if _enemy_finder.is_valid() else null


# Pelea con un enemigo que está a [param distance] metros en la dirección [param to_enemy]: mantiene el
# botón que tocaba, decide qué hacer a distancia de combate o se acerca.
func _fight_input(tick: int, to_enemy: Vector3, distance: float, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_enemy, yaw)
	if tick < _hold_until:
		# Un botón mantenido (toque, bloqueo, carga del fuerte o esquiva).
		input.buttons = _hold_buttons
		input.move = _hold_move
		return input
	if distance <= COMBAT_ENGAGE_DISTANCE and tick >= _next_decision_tick:
		_decide_combat_action(tick)
		if tick < _hold_until:
			input.buttons = _hold_buttons
			input.move = _hold_move
			return input
	# Acercarse hasta la distancia de golpe.
	if distance > COMBAT_ATTACK_DISTANCE:
		input.move = Vector2(0.0, 1.0)
		if distance > COMBAT_SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	return input


# Elige qué hacer a distancia de combate: bloquear, esquivar, cargar un fuerte o dar un ligero.
func _decide_combat_action(tick: int) -> void:
	var roll: float = _rng.randf()
	_hold_move = Vector2.ZERO
	if roll < COMBAT_BLOCK_CHANCE:
		_hold_buttons = PlayerInput.BLOCK
		_hold_until = tick + _rng.randi_range(COMBAT_BLOCK_TICKS.x, COMBAT_BLOCK_TICKS.y)
		_next_decision_tick = _hold_until + 1
	elif roll < COMBAT_BLOCK_CHANCE + COMBAT_DODGE_CHANCE:
		# Esquiva hacia un lado o hacia atrás.
		_hold_buttons = PlayerInput.DODGE
		_hold_until = tick + 1
		_hold_move = Vector2(1.0 if _rng.randi() % 2 == 0 else -1.0, 0.0) if _rng.randf() < 0.7 \
				else Vector2(0.0, -1.0)
		_next_decision_tick = tick + _rng.randi_range(COMBAT_ATTACK_GAP_TICKS.x,
				COMBAT_ATTACK_GAP_TICKS.y)
	elif roll < COMBAT_BLOCK_CHANCE + COMBAT_DODGE_CHANCE + COMBAT_HEAVY_CHANCE:
		_start_heavy_attack(tick)
	else:
		_start_light_attack(tick)


# Un fuerte cargado: mantiene PRIMARY unos ticks y espera antes de la siguiente decisión.
func _start_heavy_attack(tick: int) -> void:
	_hold_buttons = PlayerInput.PRIMARY
	_hold_until = tick + _rng.randi_range(COMBAT_HEAVY_HOLD_TICKS.x, COMBAT_HEAVY_HOLD_TICKS.y)
	_next_decision_tick = _hold_until + _rng.randi_range(COMBAT_ATTACK_GAP_TICKS.x,
			COMBAT_ATTACK_GAP_TICKS.y)


# Un ligero: un toque corto de PRIMARY (los toques seguidos enlazan el combo).
func _start_light_attack(tick: int) -> void:
	_hold_buttons = PlayerInput.PRIMARY
	_hold_until = tick + COMBAT_TAP_TICKS
	_next_decision_tick = tick + _rng.randi_range(COMBAT_ATTACK_GAP_TICKS.x,
			COMBAT_ATTACK_GAP_TICKS.y)


# --- Asedio -------------------------------------------------------------------------------------

# Entrada del patrón SIEGE (siempre hay una).
func _siege_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	_note_siege_position(position)
	# 0. Fuera de la zona de un golpe avisado, sin bloquear ni acabar lo que tuviera entre manos.
	var threat: Threat = _siege_threat_covering(position)
	if threat != null:
		if _siege_task != SiegeTask.EVADE:
			_siege_evade_since = tick
		_siege_task = SiegeTask.EVADE
		_hold_until = -1
		_hold_aims_gate = false
		_reset_stuck(tick, position)
		return _siege_evade_input(tick, position, yaw, threat)
	# Un ataque a la puerta ya empezado (un toque o un fuerte cargado) se acaba.
	if _hold_aims_gate and tick < _hold_until:
		_siege_task = SiegeTask.ASSAULT
		return _gate_hold_input(tick, position, yaw)
	_hold_aims_gate = false

	# 1. Un PNJ defensor a tiro que se pueda alcanzar (lo que guarda el fuerte mientras el círculo no está activo) y,
	# si no hay, un enemigo cualquiera.
	if _siege_defender_finder.is_valid() and not _siege.is_circle_active():
		if tick - _siege_defender_checked_tick >= COMBAT_RETARGET_TICKS:
			_siege_defender_checked_tick = tick
			_siege_defender_position = _siege_defender_finder.call(position)
		var fighting_defender: PlayerInput = _siege_fight_if_in_range(tick, position, yaw,
				_siege_defender_position)
		if fighting_defender != null:
			return fighting_defender
	if _enemy_finder.is_valid():
		_refresh_enemy(tick, position)
		var fighting: PlayerInput = _siege_fight_if_in_range(tick, position, yaw, _enemy_position)
		if fighting != null:
			return fighting
	_hold_until = -1

	# 2. El plan: marchar, asaltar la puerta o quedarse en el círculo.
	_ensure_route(position)
	if _siege_inside_fort(position):
		_siege_route_index = _siege_route_points.size()
	if _siege_route_index < _siege_route_points.size():
		_siege_task = SiegeTask.MARCH
		return _march_input(tick, position, yaw)
	var corner: Variant = _siege_around_enclosure(position)
	if corner is Vector3:
		_siege_task = SiegeTask.MARCH
		var to_corner: Vector3 = (corner as Vector3) - position
		to_corner.y = 0.0
		return _walk_input(tick, position, yaw, to_corner, to_corner.length())
	if _siege.is_gate_closed_for(_siege_realm) and _siege_has_places():
		_siege_task = SiegeTask.ASSAULT
		return _assault_input(tick, position, yaw)
	_siege_task = SiegeTask.HOLD
	return _hold_circle_input(tick, position, yaw)


# Pelea con quien está en [param target] (una posición, o null) si está a menos de SIEGE_FIGHT_RANGE y se puede
# alcanzar; null si no. Persiguiendo sin acercarse (SIEGE_CHASE_GIVE_UP_TICKS), deja de perseguir un rato.
func _siege_fight_if_in_range(tick: int, position: Vector3, yaw: float, target: Variant) -> PlayerInput:
	if not target is Vector3:
		return null
	var to_enemy: Vector3 = (target as Vector3) - position
	to_enemy.y = 0.0
	var distance: float = to_enemy.length()
	if distance > SIEGE_FIGHT_RANGE or not _can_reach(position, target as Vector3):
		return null
	if distance > COMBAT_ENGAGE_DISTANCE and not _siege_keeps_chasing(tick, distance):
		return null
	_siege_task = SiegeTask.FIGHT
	_reset_stuck(tick, position)
	return _fight_input(tick, to_enemy, distance, yaw)


# Una persecución (alguien a [param distance] metros, más lejos que la distancia de pelea): false si hay que dejarla,
# porque lleva SIEGE_STUCK_TICKS sin acercarse o porque la dejó hace poco.
func _siege_keeps_chasing(tick: int, distance: float) -> bool:
	if tick < _siege_chase_blocked_until:
		return false
	if _siege_chase_ref_tick < 0 or tick - _siege_chase_ref_tick > SIEGE_STUCK_TICKS + COMBAT_RETARGET_TICKS:
		# Empieza (o vuelve a empezar tras un rato sin perseguir).
		_siege_chase_ref_tick = tick
		_siege_chase_ref_distance = distance
		return true
	if tick - _siege_chase_ref_tick < SIEGE_STUCK_TICKS:
		return true
	if _siege_chase_ref_distance - distance < SIEGE_STUCK_MIN_PROGRESS:
		_siege_chase_blocked_until = tick + SIEGE_CHASE_GIVE_UP_TICKS
		_siege_chase_ref_tick = -1
		return false
	_siege_chase_ref_tick = tick
	_siege_chase_ref_distance = distance
	return true


# Anota la posición y, si ha dado un salto (reaparición), reinicia la ruta y lo que recordaba.
func _note_siege_position(position: Vector3) -> void:
	if _siege_has_position and position.distance_to(_siege_last_position) > SIEGE_TELEPORT_DISTANCE:
		_reset_route()
		_hold_until = -1
		_hold_aims_gate = false
		_enemy_position = null
		_enemy_checked_tick = -1000
		_siege_defender_position = null
		_siege_defender_checked_tick = -1000
		_siege_chase_ref_tick = -1
		_siege_chase_blocked_until = -1
	_siege_has_position = true
	_siege_last_position = position


# El golpe avisado más cercano en cuya zona está [param position] (con [constant SIEGE_THREAT_MARGIN]), o null.
func _siege_threat_covering(position: Vector3) -> Threat:
	if not _siege_threat_finder.is_valid():
		return null
	var found: Variant = _siege_threat_finder.call(position)
	if not found is Array:
		return null
	var best: Threat = null
	var best_distance: float = INF
	for item: Variant in found:
		var candidate: Threat = item as Threat
		if candidate == null or not candidate.covers(position, SIEGE_THREAT_MARGIN):
			continue
		var distance: float = Vector2(position.x - candidate.origin.x, position.z - candidate.origin.z).length()
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best


# Salir de la zona de [param threat]: en línea recta desde quien golpea (hacia atrás de su golpe si está justo
# encima), con una esquiva al empezar (y otra cada SIEGE_EVADE_DODGE_TICKS si sigue dentro) y esprintando entre
# medias.
func _siege_evade_input(tick: int, position: Vector3, yaw: float, threat: Threat) -> PlayerInput:
	var away := Vector3(position.x - threat.origin.x, 0.0, position.z - threat.origin.z)
	if away.length_squared() < 0.01:
		away = Vector3(sin(threat.yaw), 0.0, cos(threat.yaw))
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(away, yaw)
	input.move = Vector2(0.0, 1.0)
	input.buttons |= PlayerInput.SPRINT
	if (tick - _siege_evade_since) % SIEGE_EVADE_DODGE_TICKS == 0:
		input.buttons |= PlayerInput.DODGE
	return input


func _reset_route() -> void:
	_siege_route_id = &""
	_siege_route_chosen = false
	_siege_route_points = PackedVector2Array()
	_siege_route_index = 0
	_siege_stuck_count = 0
	_siege_unstick = _Unstick.NONE
	_siege_unstick_until = -1
	_siege_stuck_ref_tick = -1


# Elige la ruta (con el generador del bot) si aún no tiene ninguna, y por qué punto empieza.
func _ensure_route(position: Vector3) -> void:
	if _siege_route_chosen:
		return
	_siege_route_chosen = true
	if _siege_routes == null:
		return
	var realm_id: StringName = RealmCatalog.id_of_code(_siege_realm)
	var candidates: Array[StringName] = []
	for route: StringName in _siege_routes.get_route_ids():
		if _siege_routes.has_route(route, realm_id):
			candidates.append(route)
	if candidates.is_empty():
		return
	_siege_route_id = candidates[_rng.randi() % candidates.size()]
	_siege_route_points = _siege_routes.get_points(_siege_route_id, realm_id)
	_siege_route_index = maxi(_siege_routes.get_nearest_index(_siege_route_id, realm_id,
			Vector2(position.x, position.z)), 0)


# Marcha: hacia el punto de la ruta que toca, esprintando si queda lejos y no hay enemigos cerca.
func _march_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var target: Vector2 = _siege_route_points[_siege_route_index]
	var to_target := Vector3(target.x - position.x, 0.0, target.y - position.z)
	var distance: float = to_target.length()
	if distance > SIEGE_LOST_DISTANCE:
		# Se ha ido muy lejos de la ruta (una pelea, una caída): retoma por el punto más cercano.
		_siege_route_index = maxi(_siege_routes.get_nearest_index(_siege_route_id,
				RealmCatalog.id_of_code(_siege_realm), Vector2(position.x, position.z)), 0)
		target = _siege_route_points[_siege_route_index]
		to_target = Vector3(target.x - position.x, 0.0, target.y - position.z)
		distance = to_target.length()
	if distance <= SIEGE_WAYPOINT_RADIUS:
		_siege_route_index += 1
	return _walk_input(tick, position, yaw, to_target, distance)


# Asalto: se acerca a la puerta y la golpea.
func _assault_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var to_gate: Vector3 = _siege.gate_position - position
	to_gate.y = 0.0
	var distance: float = to_gate.length()
	if distance > SIEGE_GATE_ATTACK_DISTANCE:
		return _walk_input(tick, position, yaw, to_gate, distance)
	_reset_stuck(tick, position)
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_gate, yaw)
	if tick >= _next_decision_tick:
		_hold_aims_gate = true
		if _rng.randf() < COMBAT_HEAVY_CHANCE:
			_start_heavy_attack(tick)
		else:
			_start_light_attack(tick)
		input.buttons = _hold_buttons
	return input


# Un ataque a la puerta que sigue: PRIMARY pulsado mirando a la puerta.
func _gate_hold_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var to_gate: Vector3 = _siege.gate_position - position
	to_gate.y = 0.0
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_gate, yaw)
	input.buttons = _hold_buttons
	return input


# Círculo: hacia su centro y, dentro, quieto mirando a la puerta (por donde llegan los enemigos).
func _hold_circle_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	if not _siege_has_places():
		_reset_stuck(tick, position)
		var idle := PlayerInput.new()
		idle.tick = tick
		idle.look_yaw = yaw
		return idle
	var waypoint: Variant = _gate_waypoint(position)
	if waypoint is Vector3:
		var to_waypoint: Vector3 = (waypoint as Vector3) - position
		to_waypoint.y = 0.0
		return _walk_input(tick, position, yaw, to_waypoint, to_waypoint.length())
	var to_center: Vector3 = _siege.circle_center - position
	to_center.y = 0.0
	var distance: float = to_center.length()
	var circle_radius: float = _siege.circle_radius if _siege.circle_radius > 0.0 \
			else SIEGE_DEFAULT_CIRCLE_RADIUS
	if distance > circle_radius * SIEGE_CIRCLE_HOLD_FRACTION:
		return _walk_input(tick, position, yaw, to_center, distance)
	_reset_stuck(tick, position)
	var input := PlayerInput.new()
	input.tick = tick
	var to_gate: Vector3 = _siege.gate_position - position
	to_gate.y = 0.0
	input.look_yaw = _yaw_toward(to_gate, yaw)
	return input


# Para entrar en el fuerte desde fuera: el punto al que ir antes del círculo (delante de la puerta, alineado
# con su eje, y luego un poco dentro), o null si ya ha cruzado la puerta o no sabe dónde está.
func _gate_waypoint(position: Vector3) -> Variant:
	var inward: Vector3 = _siege_inward()
	if inward == Vector3.ZERO:
		return null
	var from_gate: Vector3 = position - _siege.gate_position
	from_gate.y = 0.0
	var along: float = from_gate.dot(inward)
	if along >= 0.5:
		return null
	var lateral: float = (from_gate - inward * along).length()
	if lateral > SIEGE_GATE_AXIS_TOLERANCE and (along < -2.0 or lateral > SIEGE_GATE_OPENING_HALF_WIDTH):
		return _siege.gate_position - inward * SIEGE_GATE_FRONT_DISTANCE
	return _siege.gate_position + inward * SIEGE_GATE_EXIT_DISTANCE


# Caminar hacia [param to_target] (a [param distance] metros): esprinta si queda lejos y no hay enemigos
# cerca, y se desatasca con un salto y, después, con un desvío.
func _walk_input(tick: int, position: Vector3, yaw: float, to_target: Vector3,
		distance: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_target, yaw)
	input.move = Vector2(0.0, 1.0)
	if distance > SIEGE_SPRINT_DISTANCE and _enemies_clear(position):
		input.buttons |= PlayerInput.SPRINT
	_apply_unstick(tick, position, input)
	return input


# true si el último enemigo que se vio está lejos (o no hay).
func _enemies_clear(position: Vector3) -> bool:
	if not _enemy_position is Vector3:
		return true
	return position.distance_to(_enemy_position as Vector3) > SIEGE_SPRINT_ENEMY_CLEARANCE


# Si lleva SIEGE_STUCK_TICKS caminando sin avanzar, prueba un salto y, si sigue igual, un desvío lateral
# (y vuelta a empezar); modifica [param input] mientras dura el intento.
func _apply_unstick(tick: int, position: Vector3, input: PlayerInput) -> void:
	if tick < _siege_unstick_until:
		match _siege_unstick:
			_Unstick.JUMP:
				if (tick - _siege_unstick_start) % SIEGE_JUMP_PULSE_TICKS < JUMP_HOLD_TICKS.x:
					input.buttons |= PlayerInput.JUMP
			_Unstick.DETOUR:
				input.look_yaw = fposmod(input.look_yaw + _detour_sign * SIEGE_DETOUR_ANGLE, TAU)
		return
	if _siege_stuck_ref_tick < 0 or _siege_unstick != _Unstick.NONE:
		# Un intento que acaba cuenta desde cero.
		_siege_unstick = _Unstick.NONE
		_siege_stuck_ref_position = position
		_siege_stuck_ref_tick = tick
		return
	if tick - _siege_stuck_ref_tick < SIEGE_STUCK_TICKS:
		return
	var moved: float = Vector2(position.x - _siege_stuck_ref_position.x,
			position.z - _siege_stuck_ref_position.z).length()
	_siege_stuck_ref_position = position
	_siege_stuck_ref_tick = tick
	if moved >= SIEGE_STUCK_MIN_PROGRESS:
		_siege_stuck_count = 0
		return
	_siege_stuck_count += 1
	_siege_unstick_start = tick
	if _siege_stuck_count % 2 == 1:
		_siege_unstick = _Unstick.JUMP
		_siege_unstick_until = tick + SIEGE_JUMP_WINDOW_TICKS
		if (tick - _siege_unstick_start) % SIEGE_JUMP_PULSE_TICKS < JUMP_HOLD_TICKS.x:
			input.buttons |= PlayerInput.JUMP
	else:
		_siege_unstick = _Unstick.DETOUR
		_siege_unstick_until = tick + SIEGE_DETOUR_TICKS
		_detour_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0
		input.look_yaw = fposmod(input.look_yaw + _detour_sign * SIEGE_DETOUR_ANGLE, TAU)


# Lo que no es caminar (pelear, golpear la puerta, esperar en el círculo) no es estar atascado.
func _reset_stuck(tick: int, position: Vector3) -> void:
	_siege_stuck_count = 0
	_siege_unstick = _Unstick.NONE
	_siege_unstick_until = -1
	_siege_stuck_ref_position = position
	_siege_stuck_ref_tick = tick


# true si hay posiciones de la puerta y del círculo (sin ellas el bot solo sigue su ruta).
func _siege_has_places() -> bool:
	return _siege.circle_radius > 0.0 or _siege.circle_center != Vector3.ZERO \
			or _siege.gate_position != Vector3.ZERO


# Fuera del recinto, al lado de una pared que no es la de la puerta o detrás del fuerte: la esquina a la que ir para
# rodearlo hacia la pared de la puerta (del lado en el que está), o null si está dentro, delante de la pared de la puerta
# o no se sabe el tamaño del recinto. Sin esto iba derecho al círculo y se quedaba pegado a la empalizada.
func _siege_around_enclosure(position: Vector3) -> Variant:
	if _siege.is_inside_enclosure(position, SIEGE_ENCLOSURE_MARGIN) != 0:
		return null
	var inward: Vector3 = _siege_inward()
	var across := Vector3(-inward.z, 0.0, inward.x)
	var offset: Vector3 = position - _siege.gate_position
	offset.y = 0.0
	var along: float = offset.dot(inward)
	var lateral: float = offset.dot(across)
	var half_width: float = _siege.enclosure_size.y * 0.5
	var beside: bool = absf(lateral) >= half_width - SIEGE_ENCLOSURE_MARGIN
	var behind: bool = along >= _siege.enclosure_size.x - SIEGE_ENCLOSURE_MARGIN
	if along < 0.0 or (not beside and not behind):
		# Delante de la pared de la puerta, o en su vano: de eso se ocupan la ruta y la puerta.
		return null
	var side: float = 1.0 if lateral >= 0.0 else -1.0
	var corner_lateral: float = side * (half_width + SIEGE_CORNER_MARGIN)
	var corner_along: float = -SIEGE_CORNER_MARGIN
	if along > _siege.enclosure_size.x and absf(lateral) < half_width + SIEGE_CORNER_MARGIN - SIEGE_WAYPOINT_RADIUS:
		# Detrás de la pared del fondo: primero la esquina de atrás de su lado.
		corner_along = _siege.enclosure_size.x + SIEGE_CORNER_MARGIN
	var target: Vector3 = _siege.gate_position + inward * corner_along + across * corner_lateral
	target.y = position.y
	return target


# true si [param position] está dentro del fuerte: dentro del recinto si el [SiegeView] sabe su tamaño y, si no, al
# otro lado de la puerta, mirando desde fuera, y cerca del círculo.
func _siege_inside_fort(position: Vector3) -> bool:
	if not _siege_has_places():
		return false
	var inward: Vector3 = _siege_inward()
	if inward == Vector3.ZERO:
		return false
	var enclosure: int = _siege.is_inside_enclosure(position, SIEGE_ENCLOSURE_MARGIN)
	if enclosure >= 0:
		return enclosure == 1
	var from_gate: Vector3 = position - _siege.gate_position
	from_gate.y = 0.0
	var from_circle: Vector3 = position - _siege.circle_center
	from_circle.y = 0.0
	return from_gate.dot(inward) > 0.0 and from_circle.length() <= SIEGE_INSIDE_RADIUS


# Dirección horizontal de la puerta hacia el círculo (hacia dentro del fuerte); cero si no se sabe.
func _siege_inward() -> Vector3:
	var inward: Vector3 = _siege.circle_center - _siege.gate_position
	inward.y = 0.0
	return inward.normalized() if inward.length_squared() > 0.0001 else Vector3.ZERO


# true si el bot puede llegar hasta [param target]: no está al otro lado de una puerta que le cierra el paso.
func _can_reach(position: Vector3, target: Vector3) -> bool:
	if not _siege.is_gate_closed_for(_siege_realm) or not _siege_has_places():
		return true
	var inward: Vector3 = _siege_inward()
	if inward == Vector3.ZERO:
		return true
	var mine: Vector3 = position - _siege.gate_position
	var theirs: Vector3 = target - _siege.gate_position
	mine.y = 0.0
	theirs.y = 0.0
	return (mine.dot(inward) > 0.0) == (theirs.dot(inward) > 0.0)


# --- Paseo --------------------------------------------------------------------------------------

# Elige el rumbo, la marcha y el esprint del siguiente tramo de paseo.
func _start_segment(tick: int) -> void:
	_next_change_tick = tick + _rng.randi_range(SEGMENT_MIN_TICKS, SEGMENT_MAX_TICKS)
	_heading = _rng.randf() * TAU
	_sprint = false
	if _rng.randf() < PAUSE_CHANCE:
		_move = Vector2.ZERO
		return
	_move = Vector2(0.0, 1.0)
	if _rng.randf() < STRAFE_CHANCE:
		_move = Vector2(_rng.randf_range(-0.7, 0.7), 1.0).limit_length(1.0)
	else:
		_sprint = _rng.randf() < SPRINT_CHANCE


# Pulsa el botón de salto cuando toca y programa el siguiente salto.
func _update_jump(tick: int) -> void:
	if tick < _next_jump_tick:
		return
	_jump_release_tick = tick + _rng.randi_range(JUMP_HOLD_TICKS.x, JUMP_HOLD_TICKS.y)
	_schedule_jump(_jump_release_tick)


func _schedule_jump(from_tick: int) -> void:
	var gap: Vector2i = JUMPY_JUMP_GAP_TICKS if _pattern == Pattern.JUMPY else WANDER_JUMP_GAP_TICKS
	_next_jump_tick = from_tick + _rng.randi_range(gap.x, gap.y)


# Yaw que mira hacia [param direction] (plano horizontal), con la convención de PlayerInput: el
# yaw 0 mira hacia -Z. Con una dirección nula conserva [param fallback].
func _yaw_toward(direction: Vector3, fallback: float) -> float:
	if direction.x * direction.x + direction.z * direction.z < 0.0001:
		return fallback
	return fposmod(atan2(-direction.x, -direction.z), TAU)


# Rumbo de una circunferencia alrededor de home: la tangente más una corrección radial que
# devuelve al bot a su circunferencia si se desvía.
func _circle_yaw(position: Vector3, fallback: float) -> float:
	var circle_radius: float = maxf(_radius * CIRCLE_RADIUS_FRACTION, CIRCLE_MIN_RADIUS)
	var offset: Vector3 = position - _home
	offset.y = 0.0
	var distance: float = offset.length()
	if distance < 0.01:
		return fallback
	var radial: Vector3 = offset / distance
	var tangent := Vector3(-radial.z, 0.0, radial.x) * _circle_sign
	var correction: float = clampf((circle_radius - distance) / circle_radius * 2.0, -1.0, 1.0)
	return _yaw_toward(tangent + radial * correction, fallback)
