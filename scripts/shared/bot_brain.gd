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
## pelea con él igual que [constant COMBAT].
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
## [br][br]
## [b]Kit de la fase 4 (H5; docs/habilidades.md, sección 7.1).[/b] Si quien lleva el bot le da su estado de
## combate ([method set_combat_source]: el predicho en un cliente, el del servidor en un jugador falso), los
## patrones [constant COMBAT] y [constant SIEGE] pelean con todo el equipo: las habilidades del arma activa
## según para qué sirven por sus datos ([enum KitRole]: golpe corto, embestida para acercarse, muro que se
## mantiene pulsado mientras dura la canalización, salto atrás, disparo), el cambio de arma (al arco de lejos, a
## la espada de cerca), las pociones (vida por debajo de [constant KIT_HEALTH_POTION_BELOW] con
## [method set_health_source], resistencia por debajo de [constant KIT_STAMINA_POTION_BELOW]) y el arco: guarda
## la distancia, alterna disparos rápidos y tensados y apunta con el tiro adelantado ([method lead_look]:
## [method Ballistics.solve_lead] y [method AimRay.look_for]), con el bit [constant PlayerInput.AIM_LEFT] de su
## hombro (el izquierdo si la semilla es impar). Remata a un enemigo derribado (el buscador devuelve un
## [BotTarget]) y levanta a un aliado derribado ([method set_ally_finder]) manteniendo INTERACT. Solo pulsa lo
## que su estado deja usar ([method ActionMachine.ability_status]): el servidor decide igual, pero un bot
## honrado no machaca botones (eso es del tramposo, [BotCheatBrain]). Sin estado (o con [member use_kit] en
## false) pelea como en la fase 3, con la misma secuencia de entradas que antes.

## [constant SIEGE] va al final para no mover los valores de los demás patrones.
enum Pattern { WANDER, CIRCLE, IDLE, JUMPY, COMBAT, SIEGE }

## Qué hace un bot de [constant SIEGE] en este tick ([method get_siege_task]).
enum SiegeTask { NONE, FIGHT, MARCH, ASSAULT, HOLD }

## Para qué usa el kit una habilidad, según sus datos ([method kit_role]): golpe corto con forma
## ([constant CLOSE]), avance hacia delante para acercarse ([constant GAP_CLOSER]), canalización que bloquea
## ([constant GUARD], el muro), avance hacia atrás ([constant ESCAPE]) o disparo ([constant SHOT]).
enum KitRole { NONE, CLOSE, GAP_CLOSER, GUARD, ESCAPE, SHOT }

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
## fuerte y no necesita la ruta.
const SIEGE_INSIDE_RADIUS: float = 30.0
## [constant SIEGE]: ticks sin avanzar [constant SIEGE_STUCK_MIN_PROGRESS] metros tras los que se
## considera atascado; ticks que dura un salto o un desvío para desatascarse; cada cuántos ticks se pulsa
## el salto; y ángulo (rad) del desvío.
const SIEGE_STUCK_TICKS: int = 180
const SIEGE_STUCK_MIN_PROGRESS: float = 1.0
const SIEGE_JUMP_WINDOW_TICKS: int = 40
const SIEGE_JUMP_PULSE_TICKS: int = 20
const SIEGE_DETOUR_TICKS: int = 60
const SIEGE_DETOUR_ANGLE: float = 1.2
## Kit: con el arco en la mano y el enemigo a menos de esta distancia (m) cambia a la espada si la lleva, y con la
## espada y el enemigo a más de la otra, al arco.
const KIT_SWAP_TO_MELEE_DISTANCE: float = 5.0
const KIT_SWAP_TO_RANGED_DISTANCE: float = 11.0
## Kit: distancias (m) entre las que se queda el arquero (se aleja por debajo y se acerca por encima).
const KIT_BOW_KEEP_MIN: float = 9.0
const KIT_BOW_KEEP_MAX: float = 26.0
## Kit: probabilidad de que un disparo sea tensado y ticks que mantiene PRIMARY (desde la pulsación; la carga
## del tensado va de 21 a 60).
const KIT_BOW_DRAWN_CHANCE: float = 0.45
const KIT_BOW_DRAW_TICKS: Vector2i = Vector2i(24, 60)
## Kit: probabilidad de usar una habilidad de disparo lista y distancia (m) por debajo de la cual el arquero
## salta atrás.
const KIT_SHOT_ABILITY_CHANCE: float = 0.3
const KIT_ESCAPE_DISTANCE: float = 5.0
## Kit: probabilidad de esquivar en una decisión del arquero con el enemigo cerca.
const KIT_BOW_DODGE_CHANCE: float = 0.08
## Kit: golpe corto (el de escudo) a esta distancia (m) como mucho y con esta probabilidad por decisión.
const KIT_CLOSE_DISTANCE: float = 2.2
const KIT_CLOSE_CHANCE: float = 0.22
## Kit: embestida para acercarse entre estas distancias (m) y con esta probabilidad por decisión.
const KIT_GAP_CLOSER_RANGE: Vector2 = Vector2(3.5, 7.0)
const KIT_GAP_CLOSER_CHANCE: float = 0.3
## Kit: probabilidad de levantar el muro en una decisión y ticks que mantiene su botón (la canalización acaba al
## soltarlo o en su tope).
const KIT_GUARD_CHANCE: float = 0.08
const KIT_GUARD_HOLD_TICKS: Vector2i = Vector2i(60, 200)
## Kit: bebe la poción de vida por debajo de esta fracción de vida y la de resistencia por debajo de esta
## fracción de resistencia.
const KIT_HEALTH_POTION_BELOW: float = 0.5
const KIT_STAMINA_POTION_BELOW: float = 0.3
## Kit: se acerca hasta esta distancia (m) de un derribado para levantarlo o rematarlo (el servidor llega a 2 m)
## y mantiene INTERACT lo que dura la acción más este margen (ticks).
const KIT_INTERACT_REACH: float = 1.3
const KIT_INTERACT_MARGIN_TICKS: int = 8
## Kit: busca aliados derribados hasta esta distancia (m) y solo va a levantarlos si no hay un enemigo más
## cerca que la otra.
const KIT_REVIVE_SEARCH: float = 15.0
const KIT_REVIVE_ENEMY_CLEARANCE: float = 6.0
## Kit: ticks entre dos decisiones de más tras acabar una acción, y lo que dura cada tramo lateral del arquero.
const KIT_DECISION_GAP_TICKS: Vector2i = Vector2i(4, 12)
const KIT_STRAFE_TICKS: Vector2i = Vector2i(40, 100)

# Cómo se desatasca un bot de asedio.
enum _Unstick { NONE, JUMP, DETOUR }
# Pitch máximo (rad) de la puntería del arco (por debajo de la vertical).
const _MAX_AIM_PITCH: float = 1.4

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

## Kit (H5): false lo apaga aunque haya estado de combate (el bot pelea como en la fase 3). Lo usan las medidas
## de referencia de [code]tools/combat_balance.gd[/code].
var use_kit: bool = true
## Kit, para las pruebas de carga ([code]--fake-archers[/code]): con el arco en la mano no cambia nunca a la espada
## (guarda la distancia y dispara), y con la espada vuelve al arco en cuanto puede.
var kit_ranged_only: bool = false
## Kit, para las pruebas de carga: radianes que sube la puntería del arco por encima del tiro bueno. Con un valor
## alto, las flechas van al cielo y viven sus 2 s (llenan el tope de la zona; docs/habilidades.md, sección 4.4).
var kit_aim_raise: float = 0.0
# Kit: de dónde saca su estado de combate, su vida y los aliados derribados.
var _combat_source: Callable = Callable()
var _health_source: Callable = Callable()
var _ally_finder: Callable = Callable()
# Kit: velocidad y derribo del enemigo que sigue (del BotTarget; cero y false con una posición sola).
var _enemy_velocity: Vector3 = Vector3.ZERO
var _enemy_downed: bool = false
# Kit: el aliado derribado más cercano (Vector3 o null) y cuándo se buscó.
var _ally_position: Variant = null
var _ally_checked_tick: int = -1000
# Kit: qué mantiene (&"" un toque o nada; &"execute", &"revive", &"guard", &"draw").
var _hold_kind: StringName = &""
# Kit: velocidad (m/s) y gravedad del disparo que apunta (0 = nada que apuntar).
var _aim_speed: float = 0.0
var _aim_gravity: float = 0.0
# Kit: hombro de la puntería (el izquierdo con semilla impar) y tramo lateral del arquero.
var _aim_left: bool = false
var _kit_strafe_sign: float = 1.0
var _kit_strafe_until: int = -1
# Kit: cuántas veces ha hecho cada cosa (get_kit_counts).
var _kit_counts: Dictionary[StringName, int] = {}


## [param rng_seed] fija la secuencia. [param home] y [param radius] delimitan la zona por la
## que se mueve el bot (en el plano horizontal).
func _init(rng_seed: int, pattern: Pattern = Pattern.WANDER, home: Vector3 = Vector3.ZERO,
		radius: float = 30.0) -> void:
	_rng.seed = rng_seed
	_pattern = pattern
	_home = home
	_radius = maxf(radius, 1.0)
	_circle_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0
	# Sin sacar números del generador: la secuencia de los patrones de antes no cambia.
	_aim_left = posmod(rng_seed, 2) == 1


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


## Kit (H5): de dónde saca el bot su estado de combate, [code]() -> CombatState[/code] (null = no lo sabe): el
## de después del último tick simulado, con el que decide la entrada del siguiente (el predicho en un cliente, el
## del servidor en un jugador falso). Lo lee sin cambiarlo. Con él, [constant COMBAT] y [constant SIEGE] usan el
## kit (ver la documentación de la clase).
func set_combat_source(source: Callable) -> void:
	_combat_source = source


## true si el bot ya sabe de dónde sacar su estado de combate ([method set_combat_source]).
func has_combat_source() -> bool:
	return _combat_source.is_valid()


## Kit: de dónde saca su vida, [code]() -> float[/code] (fracción de 0 a 1). Sin ella, el bot no bebe la poción
## de vida.
func set_health_source(source: Callable) -> void:
	_health_source = source


## Kit: cómo encuentra aliados derribados, [code](position: Vector3) -> Variant[/code]: los pies (un
## [Vector3]) del más cercano a [param position], o null. Sin él, el bot no levanta a nadie.
func set_ally_finder(finder: Callable) -> void:
	_ally_finder = finder
	_ally_checked_tick = -1000


## Kit: cuántas veces ha hecho cada cosa desde que se creó: [code]ability_0[/code]..[code]ability_2[/code]
## (habilidades por ranura), [code]potion_0[/code] y [code]potion_1[/code], [code]swap[/code],
## [code]quick[/code] y [code]drawn[/code] (disparos del arco), [code]guard[/code] (muros levantados),
## [code]execute[/code] y [code]revive[/code] (INTERACT mantenido) y [code]dodge[/code]. Es una copia.
func get_kit_counts() -> Dictionary[StringName, int]:
	return _kit_counts.duplicate()


## Para qué usa el kit [param ability] ([enum KitRole]), por sus datos: una canalización que bloquea es
## [constant KitRole.GUARD]; un avance hacia atrás, [constant KitRole.ESCAPE] (aunque dispare); un disparo,
## [constant KitRole.SHOT]; un avance hacia delante, [constant KitRole.GAP_CLOSER]; un golpe con forma,
## [constant KitRole.CLOSE].
static func kit_role(ability: AbilityTicks) -> KitRole:
	if ability == null:
		return KitRole.NONE
	if ability.channel and ability.blocks:
		return KitRole.GUARD
	if ability.dash_distance_m > 0.0 and ability.dash_direction == 1:
		return KitRole.ESCAPE
	if ability.projectile_id != 0:
		return KitRole.SHOT
	if ability.dash_distance_m > 0.0:
		return KitRole.GAP_CLOSER
	if ability.hit != null and ability.hit.shape != null:
		return KitRole.CLOSE
	return KitRole.NONE


## true si el arma [param weapon_id] dispara con el ligero (el arco).
static func is_ranged_weapon(weapon_id: int) -> bool:
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	if weapon == null or weapon.light_ids.is_empty():
		return false
	var light: AttackTicks = CombatCatalog.attack(weapon.light_ids[0])
	return light != null and light.projectile_id != 0


## Vista [code](yaw, pitch)[/code] de un tirador con los pies en [param feet] y el hombro
## [param left_shoulder] para que una flecha de [param speed] m/s y [param gravity] m/s² dé en el centro de un
## blanco con los pies en [param target_feet] que va a [param target_velocity] m/s (docs/habilidades.md, sección
## 4.4): la dirección de [method Ballistics.solve_lead] desde la boca [code]O[/code], el punto
## [code]O + dir · |blanco − O|[/code] y el rayo canónico que pasa por él ([method AimRay.look_for]). El yaw queda
## en [0, TAU).
static func lead_look(feet: Vector3, target_feet: Vector3, target_velocity: Vector3, speed: float,
		gravity: float, left_shoulder: bool) -> Vector2:
	var center: Vector3 = target_feet + Vector3(0.0, AimRay.TARGET_CENTER_HEIGHT, 0.0)
	var muzzle: Vector3 = AimRay.muzzle(feet)
	var direction: Vector3 = Ballistics.solve_lead(muzzle, center, target_velocity, speed, gravity)
	var point: Vector3 = muzzle + direction * muzzle.distance_to(center)
	var look: Vector2 = AimRay.look_for(feet, point, left_shoulder)
	return Vector2(fposmod(look.x, TAU), look.y)


# Entrada del patrón COMBAT, o null si no hay enemigo a la vista (entonces pasea).
func _combat_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	_refresh_enemy(tick, position)
	var kit: CombatState = _kit_state()
	if kit != null:
		var reviving: PlayerInput = _revive_input(tick, position, yaw, kit)
		if reviving != null:
			return reviving
	if not _enemy_position is Vector3:
		_hold_until = -1
		return null
	var to_enemy: Vector3 = (_enemy_position as Vector3) - position
	to_enemy.y = 0.0
	var distance: float = to_enemy.length()
	if distance > COMBAT_SIGHT_RANGE:
		_hold_until = -1
		return null
	return _fight_input(tick, position, to_enemy, distance, yaw)


# Vuelve a buscar al enemigo más cercano cada COMBAT_RETARGET_TICKS ticks. El buscador puede devolver la
# posición (un Vector3) o un BotTarget (con la velocidad y el derribo, que usa el kit).
func _refresh_enemy(tick: int, position: Vector3) -> void:
	if tick - _enemy_checked_tick >= COMBAT_RETARGET_TICKS:
		_enemy_checked_tick = tick
		var found: Variant = _enemy_finder.call(position) if _enemy_finder.is_valid() else null
		_enemy_velocity = Vector3.ZERO
		_enemy_downed = false
		if found is BotTarget:
			var target: BotTarget = found as BotTarget
			_enemy_position = target.position
			_enemy_velocity = target.velocity
			_enemy_downed = target.downed
		else:
			_enemy_position = found


# Pelea con un enemigo que está a [param distance] metros en la dirección [param to_enemy]: mantiene el
# botón que tocaba, decide qué hacer a distancia de combate o se acerca. Con estado de combate, con el kit.
func _fight_input(tick: int, position: Vector3, to_enemy: Vector3, distance: float,
		yaw: float) -> PlayerInput:
	var kit: CombatState = _kit_state()
	if kit != null:
		return _kit_fight_input(tick, position, to_enemy, distance, yaw, kit)
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


# --- Kit (H5) -----------------------------------------------------------------------------------

# Estado de combate con el que decide el kit, o null si no hay (o el kit está apagado).
func _kit_state() -> CombatState:
	if not use_kit or not _combat_source.is_valid():
		return null
	return _combat_source.call() as CombatState


# Pelea con el kit: mantiene lo que mantenía (apuntando, con el arco), decide cuando toca y, entre medias, se
# acerca, guarda la distancia o va a rematar.
func _kit_fight_input(tick: int, position: Vector3, to_enemy: Vector3, distance: float, yaw: float,
		state: CombatState) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_enemy, yaw)
	if state.action == CombatState.Action.DOWNED or state.action == CombatState.Action.DEAD:
		_hold_until = -1
		_hold_kind = &""
		return input
	var ranged: bool = is_ranged_weapon(state.weapon_id)
	# Un remate se deja si el objetivo ya no está derribado.
	if _hold_kind == &"execute" and not _enemy_downed:
		_hold_until = -1
	if tick >= _hold_until:
		_hold_kind = &""
		if tick >= _next_decision_tick:
			_decide_kit_action(tick, state, ranged, distance)
	if tick < _hold_until:
		input.buttons = _hold_buttons
		input.move = _hold_move
	elif _enemy_downed:
		if distance > KIT_INTERACT_REACH:
			input.move = Vector2(0.0, 1.0)
			if distance > COMBAT_SPRINT_DISTANCE:
				input.buttons |= PlayerInput.SPRINT
	elif ranged:
		_keep_bow_distance(input, tick, distance)
	elif distance > COMBAT_ATTACK_DISTANCE:
		input.move = Vector2(0.0, 1.0)
		if distance > COMBAT_SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	if ranged:
		_aim(input, position, tick, state)
	return input


# Decide qué hace el kit: rematar, beber, cambiar de arma o, según el arma, una habilidad, un disparo o lo de la
# fase 3. Lo que decide queda en _hold_* y _next_decision_tick.
func _decide_kit_action(tick: int, state: CombatState, ranged: bool, distance: float) -> void:
	_hold_move = Vector2.ZERO
	_hold_buttons = 0
	_aim_speed = 0.0
	var data: CombatTables = CombatCatalog.tables()
	if _enemy_downed:
		if distance <= KIT_INTERACT_REACH and _can_interact(state):
			_hold(tick, PlayerInput.INTERACT, data.execute_ticks + KIT_INTERACT_MARGIN_TICKS, &"execute")
			_count(&"execute")
		return
	if _health_fraction() < KIT_HEALTH_POTION_BELOW \
			and _slot_ready(state, ActionMachine.STATUS_SLOT_CONSUMABLE_1, tick):
		_tap_consumable(tick, 0)
		return
	if float(state.stamina) < KIT_STAMINA_POTION_BELOW * float(data.rules.stamina_max) \
			and _slot_ready(state, ActionMachine.STATUS_SLOT_CONSUMABLE_2, tick):
		_tap_consumable(tick, 1)
		return
	if state.alt_weapon_id != 0 and state.action == CombatState.Action.NONE:
		var alt_ranged: bool = is_ranged_weapon(state.alt_weapon_id)
		if (ranged and not alt_ranged and distance < KIT_SWAP_TO_MELEE_DISTANCE and not kit_ranged_only) \
				or (not ranged and alt_ranged and (distance > KIT_SWAP_TO_RANGED_DISTANCE or kit_ranged_only)):
			_tap(tick, PlayerInput.SWAP_WEAPON, data.swap_ticks + _gap())
			_count(&"swap")
			return
	if ranged:
		_decide_bow_action(tick, state, distance)
	else:
		_decide_melee_action(tick, state, distance)


# Cuerpo a cuerpo: embestida para acercarse, golpe corto de cerca, el muro o, si no, lo de la fase 3.
func _decide_melee_action(tick: int, state: CombatState, distance: float) -> void:
	var slots: Dictionary[int, int] = _ready_roles(state, tick)
	if slots.has(KitRole.GAP_CLOSER) and distance >= KIT_GAP_CLOSER_RANGE.x \
			and distance <= KIT_GAP_CLOSER_RANGE.y and _rng.randf() < KIT_GAP_CLOSER_CHANCE:
		_use_ability(tick, state, slots[KitRole.GAP_CLOSER])
		return
	if distance > COMBAT_ENGAGE_DISTANCE:
		return
	var roll: float = _rng.randf()
	if slots.has(KitRole.CLOSE) and distance <= KIT_CLOSE_DISTANCE and roll < KIT_CLOSE_CHANCE:
		_use_ability(tick, state, slots[KitRole.CLOSE])
	elif slots.has(KitRole.GUARD) and roll >= KIT_CLOSE_CHANCE \
			and roll < KIT_CLOSE_CHANCE + KIT_GUARD_CHANCE:
		_use_ability(tick, state, slots[KitRole.GUARD])
	else:
		_decide_combat_action(tick)
		if (_hold_buttons & PlayerInput.DODGE) != 0:
			_count(&"dodge")


# Arco: salto atrás si el enemigo se acerca, alguna esquiva, una habilidad de disparo o un disparo (rápido o
# tensado).
func _decide_bow_action(tick: int, state: CombatState, distance: float) -> void:
	var data: CombatTables = CombatCatalog.tables()
	var weapon: WeaponTicks = data.weapon(state.weapon_id)
	var slots: Dictionary[int, int] = _ready_roles(state, tick)
	if slots.has(KitRole.ESCAPE) and distance < KIT_ESCAPE_DISTANCE:
		_use_ability(tick, state, slots[KitRole.ESCAPE])
		return
	if distance < KIT_ESCAPE_DISTANCE and _rng.randf() < KIT_BOW_DODGE_CHANCE:
		_hold_move = Vector2(0.0, -1.0)
		_tap(tick, PlayerInput.DODGE, (weapon.dodge.duration_ticks if weapon.dodge != null else 30) + _gap())
		_count(&"dodge")
		return
	var shots: Array[int] = _ready_shot_slots(state, tick)
	if not shots.is_empty() and _rng.randf() < KIT_SHOT_ABILITY_CHANCE:
		_use_ability(tick, state, shots[_rng.randi() % shots.size()])
		return
	var light: AttackTicks = data.attack(weapon.light_ids[0])
	var heavy: AttackTicks = data.attack(weapon.heavy_id)
	if heavy != null and not state.is_exhausted() and _rng.randf() < KIT_BOW_DRAWN_CHANCE:
		var held: int = _rng.randi_range(KIT_BOW_DRAW_TICKS.x, KIT_BOW_DRAW_TICKS.y)
		_hold(tick, PlayerInput.PRIMARY, held, &"draw")
		var launched: int = maxi(held, heavy.charge_min_ticks)
		_next_decision_tick = tick + launched + heavy.total_ticks + _gap()
		var launch: ProjectileLaunch = ProjectileLaunch.for_attack(heavy, mini(launched, heavy.charge_max_ticks))
		_set_aim(launch.speed if launch != null else heavy.projectile_speed_mps, heavy.projectile_id)
		_count(&"drawn")
		return
	_tap(tick, PlayerInput.PRIMARY, light.total_ticks + _gap())
	_set_aim(light.projectile_speed_mps, light.projectile_id)
	_count(&"quick")


# Usa la habilidad de la ranura [param slot] del arma activa: el muro se mantiene; el resto, un toque.
func _use_ability(tick: int, state: CombatState, slot: int) -> void:
	var data: CombatTables = CombatCatalog.tables()
	var ability: AbilityTicks = data.ability(data.weapon(state.weapon_id).ability_id(slot))
	var button: int = [PlayerInput.ABILITY_1, PlayerInput.ABILITY_2, PlayerInput.ABILITY_3][slot]
	if kit_role(ability) == KitRole.GUARD:
		var held: int = mini(_rng.randi_range(KIT_GUARD_HOLD_TICKS.x, KIT_GUARD_HOLD_TICKS.y),
				ability.active_to())
		_hold(tick, button, held, &"guard")
		_count(&"guard")
	else:
		_tap(tick, button, ability.total_ticks + _gap())
	if ability.projectile_id != 0:
		_set_aim(ability.projectile_speed_mps, ability.projectile_id)
	_count(StringName("ability_%d" % slot))


# Las habilidades listas del arma activa por su papel (la primera ranura de cada papel).
func _ready_roles(state: CombatState, tick: int) -> Dictionary[int, int]:
	var roles: Dictionary[int, int] = {}
	var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
	if weapon == null:
		return roles
	for slot: int in CombatState.ABILITY_SLOTS:
		if not _slot_ready(state, slot, tick):
			continue
		var role: int = kit_role(CombatCatalog.ability(weapon.ability_id(slot)))
		if role != KitRole.NONE and not roles.has(role):
			roles[role] = slot
	return roles


# Ranuras listas con una habilidad de disparo (sin el salto atrás, que es para huir).
func _ready_shot_slots(state: CombatState, tick: int) -> Array[int]:
	var found: Array[int] = []
	var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
	if weapon == null:
		return found
	for slot: int in CombatState.ABILITY_SLOTS:
		if _slot_ready(state, slot, tick) \
				and kit_role(CombatCatalog.ability(weapon.ability_id(slot))) == KitRole.SHOT:
			found.append(slot)
	return found


func _slot_ready(state: CombatState, slot: int, tick: int) -> bool:
	return ActionMachine.ability_status(state, slot, tick) == ActionMachine.AbilityStatus.READY


func _tap_consumable(tick: int, index: int) -> void:
	var ability: AbilityTicks = CombatCatalog.ability(CombatCatalog.consumable_ids()[index])
	_tap(tick, PlayerInput.CONSUMABLE_1 if index == 0 else PlayerInput.CONSUMABLE_2,
			(ability.total_ticks if ability != null else 60) + _gap())
	_count(StringName("potion_%d" % index))


# Un toque de [param button] y la siguiente decisión dentro de [param busy_ticks].
func _tap(tick: int, button: int, busy_ticks: int) -> void:
	_hold_buttons = button
	_hold_until = tick + COMBAT_TAP_TICKS
	_hold_kind = &""
	_next_decision_tick = tick + maxi(busy_ticks, COMBAT_TAP_TICKS)


# [param button] mantenido [param ticks] ticks ([param kind]: qué es) y la siguiente decisión al soltarlo.
func _hold(tick: int, button: int, ticks: int, kind: StringName) -> void:
	_hold_buttons = button
	_hold_until = tick + ticks
	_hold_kind = kind
	_next_decision_tick = _hold_until + 1


func _gap() -> int:
	return _rng.randi_range(KIT_DECISION_GAP_TICKS.x, KIT_DECISION_GAP_TICKS.y)


func _count(key: StringName) -> void:
	_kit_counts[key] = int(_kit_counts.get(key, 0)) + 1


# Velocidad y gravedad del disparo que se apunta.
func _set_aim(speed: float, projectile_id: int) -> void:
	_aim_speed = speed
	var projectile: ProjectileTicks = CombatCatalog.projectile(projectile_id)
	_aim_gravity = projectile.gravity if projectile != null else 0.0


# Apunta [param input] al enemigo con el tiro adelantado del disparo que toca (el rápido si no hay otro), con
# su posición extrapolada desde que se buscó.
func _aim(input: PlayerInput, position: Vector3, tick: int, state: CombatState) -> void:
	if not _enemy_position is Vector3:
		return
	if _aim_speed <= 0.0:
		var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
		var light: AttackTicks = CombatCatalog.attack(weapon.light_ids[0])
		_set_aim(light.projectile_speed_mps, light.projectile_id)
	var target: Vector3 = (_enemy_position as Vector3) \
			+ _enemy_velocity * (float(tick - _enemy_checked_tick) / Ballistics.TICK_RATE)
	var look: Vector2 = lead_look(position, target, _enemy_velocity, _aim_speed, _aim_gravity, _aim_left)
	input.look_yaw = look.x
	input.look_pitch = minf(look.y + kit_aim_raise, _MAX_AIM_PITCH)
	if _aim_left:
		input.buttons |= PlayerInput.AIM_LEFT


# El arquero se queda entre KIT_BOW_KEEP_MIN y KIT_BOW_KEEP_MAX del enemigo, moviéndose de lado entre medias.
func _keep_bow_distance(input: PlayerInput, tick: int, distance: float) -> void:
	if distance < KIT_BOW_KEEP_MIN:
		input.move = Vector2(0.0, -1.0)
	elif distance > KIT_BOW_KEEP_MAX:
		input.move = Vector2(0.0, 1.0)
		if distance > KIT_BOW_KEEP_MAX + COMBAT_SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	else:
		if tick >= _kit_strafe_until:
			_kit_strafe_until = tick + _rng.randi_range(KIT_STRAFE_TICKS.x, KIT_STRAFE_TICKS.y)
			_kit_strafe_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0
		input.move = Vector2(_kit_strafe_sign, 0.0)


func _can_interact(state: CombatState) -> bool:
	return state.action == CombatState.Action.NONE or state.action == CombatState.Action.BLOCK


func _health_fraction() -> float:
	return float(_health_source.call()) if _health_source.is_valid() else 1.0


# Levantar a un aliado derribado (patrón COMBAT con kit): sigue manteniendo INTERACT si ya lo hacía; si hay un
# aliado derribado cerca y ningún enemigo en pie encima, va hacia él y mantiene INTERACT. null si no toca.
func _revive_input(tick: int, position: Vector3, yaw: float, state: CombatState) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	if _hold_kind == &"revive":
		if tick < _hold_until:
			input.buttons = _hold_buttons
			return input
		_hold_kind = &""
	if not _ally_finder.is_valid() or state.action == CombatState.Action.DOWNED \
			or state.action == CombatState.Action.DEAD:
		return null
	if tick - _ally_checked_tick >= COMBAT_RETARGET_TICKS:
		_ally_checked_tick = tick
		_ally_position = _ally_finder.call(position)
	if not _ally_position is Vector3:
		return null
	var to_ally: Vector3 = (_ally_position as Vector3) - position
	to_ally.y = 0.0
	var distance: float = to_ally.length()
	if distance > KIT_REVIVE_SEARCH or tick < _hold_until:
		return null
	if _enemy_position is Vector3 and not _enemy_downed \
			and position.distance_to(_enemy_position as Vector3) < KIT_REVIVE_ENEMY_CLEARANCE:
		return null
	input.look_yaw = _yaw_toward(to_ally, yaw)
	if distance <= KIT_INTERACT_REACH:
		if _can_interact(state):
			_hold(tick, PlayerInput.INTERACT,
					CombatCatalog.tables().revive_ticks + KIT_INTERACT_MARGIN_TICKS, &"revive")
			_count(&"revive")
			input.buttons = PlayerInput.INTERACT
		return input
	input.move = Vector2(0.0, 1.0)
	if distance > COMBAT_SPRINT_DISTANCE:
		input.buttons |= PlayerInput.SPRINT
	return input


# --- Asedio -------------------------------------------------------------------------------------

# Entrada del patrón SIEGE (siempre hay una).
func _siege_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	_note_siege_position(position)
	# Un ataque a la puerta ya empezado (un toque o un fuerte cargado) se acaba.
	if _hold_aims_gate and tick < _hold_until:
		_siege_task = SiegeTask.ASSAULT
		return _gate_hold_input(tick, position, yaw)
	_hold_aims_gate = false

	# 1. Un enemigo a tiro que se pueda alcanzar.
	if _enemy_finder.is_valid():
		_refresh_enemy(tick, position)
		if _enemy_position is Vector3:
			var to_enemy: Vector3 = (_enemy_position as Vector3) - position
			to_enemy.y = 0.0
			var distance: float = to_enemy.length()
			if distance <= SIEGE_FIGHT_RANGE and _can_reach(position, _enemy_position as Vector3):
				_siege_task = SiegeTask.FIGHT
				_reset_stuck(tick, position)
				return _fight_input(tick, position, to_enemy, distance, yaw)
	_hold_until = -1

	# 2. El plan: marchar, asaltar la puerta o quedarse en el círculo.
	_ensure_route(position)
	if _siege_inside_fort(position):
		_siege_route_index = _siege_route_points.size()
	if _siege_route_index < _siege_route_points.size():
		_siege_task = SiegeTask.MARCH
		return _march_input(tick, position, yaw)
	if _siege.is_gate_closed_for(_siege_realm) and _siege_has_places():
		_siege_task = SiegeTask.ASSAULT
		return _assault_input(tick, position, yaw)
	_siege_task = SiegeTask.HOLD
	return _hold_circle_input(tick, position, yaw)


# Anota la posición y, si ha dado un salto (reaparición), reinicia la ruta y lo que recordaba.
func _note_siege_position(position: Vector3) -> void:
	if _siege_has_position and position.distance_to(_siege_last_position) > SIEGE_TELEPORT_DISTANCE:
		_reset_route()
		_hold_until = -1
		_hold_aims_gate = false
		_enemy_position = null
		_enemy_checked_tick = -1000
	_siege_has_position = true
	_siege_last_position = position


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
	if lateral > SIEGE_GATE_AXIS_TOLERANCE and along < -2.0:
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


# true si [param position] está dentro del fuerte: al otro lado de la puerta, mirando desde fuera, y cerca
# del círculo.
func _siege_inside_fort(position: Vector3) -> bool:
	if not _siege_has_places():
		return false
	var inward: Vector3 = _siege_inward()
	if inward == Vector3.ZERO:
		return false
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
