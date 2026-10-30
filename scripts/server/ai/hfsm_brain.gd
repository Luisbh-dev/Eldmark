class_name HfsmBrain
extends BotBrain
## Cerebro de un PNJ de combate: máquina de estados jerárquica (docs/fuerte.md, sección 4.2; MUN-07 y MUN-08).
## [br][br]
## [b]Estados[/b] ([enum State]): [code]REPOSO[/code] (quieto en su puesto) → [code]PATRULLA[/code] (recorre los
## marcadores de su ruta, parándose en cada uno) → [code]ALERTA[/code] (ha notado a un enemigo: lo mira y reacciona
## unas décimas de segundo) → [code]COMBATE[/code] (lo persigue, lo rodea y ataca) → [code]REGRESO[/code] (lo ha
## perdido o se ha alejado más de su correa: vuelve a su puesto, [b]regenerado e inmune[/b]).
## [br][br]
## [b]Piensa cada [constant THINK_INTERVAL_TICKS] ticks[/b] (escalonado por su net_id) con el estado de los cuerpos
## tras el tick anterior (paso 0 del orden del tick, docs/fuerte.md 1.7), y entre medias repite su plan: movimiento,
## rumbo y botones. Produce una [PlayerInput] por tick que entra en su [InputQueue] como la de un jugador falso, así
## que su cuerpo es un [PlayerCharacter] simulado con las mismas reglas que los jugadores. Su única fuente de azar es
## su [RandomNumberGenerator] con semilla: con las mismas semillas y los mismos jugadores hace siempre lo mismo
## ([method get_state_log]).
## [br][br]
## [b]Percepción[/b]: radio, cono y línea de visión ([method NpcWorld.line_of_sight]); dentro del radio de
## «oído» ([member NpcDefinition.awareness_radius]) basta con la línea de visión. [b]Amenaza[/b]: el daño que le
## ha hecho cada enemigo más su cercanía, con un empujón al objetivo actual para no cambiar a cada rato.
## [b]Correa[/b]: más allá de [member NpcDefinition.leash_radius] de su puesto, regresa. [b]Fichas[/b]: solo ataca
## con una ficha de [AttackTokens] (como mucho dos PNJ a la vez contra el mismo objetivo); sin ella lo rodea a 3 o
## 4 m. [b]Alerta de grupo[/b]: al entrar en combate avisa a los de su grupo a [member NpcDefinition.alert_radius];
## un jefe ([member NpcDefinition.shouts]) grita y, al bajar de vida, llama refuerzos.
## [br][br]
## [b]Derribados[/b] (docs/habilidades.md, sección 4.5; H3c): los PNJ no quedan derribados, pero rematan. Un
## jugador derribado hostil a menos de [constant DOWNED_PRIORITY_RADIUS] m es el objetivo preferido (antes que el
## más cercano en pie, también al notarlo en reposo o patrulla) y se ataca con el ligero (PRIMARY), sin levantar el
## escudo ni cargar; pide su ficha de [AttackTokens] como cualquier objetivo.

## Estados de la máquina.
enum State { REST, PATROL, ALERT, COMBAT, RETURN }
## Qué ataque elige el PNJ.
enum Attack { LIGHT, HEAVY, SPECIAL, BLOCK }

## Cada cuántos ticks piensa.
const THINK_INTERVAL_TICKS: int = 6
## Distancia (m) a la que da por llegado a un punto de patrulla o a su puesto.
const ARRIVE_DISTANCE: float = 1.2
## Distancia (m) a un punto intermedio de la ruta a la que pasa al siguiente.
const WAYPOINT_DISTANCE: float = 0.8
## Cada cuántos ticks recalcula la ruta, y cuánto debe moverse el destino para que la recalcule antes.
const REPATH_TICKS: int = 45
const REPATH_GOAL_DISTANCE: float = 1.5
## Por debajo de esta distancia (m) horizontal y de este desnivel va derecho al objetivo, sin ruta.
const DIRECT_DISTANCE: float = 4.0
const DIRECT_MAX_HEIGHT: float = 1.2
## Atasco: si en [constant STUCK_CHECK_TICKS] ticks avanza menos de [constant STUCK_MIN_MOVE] m queriendo moverse, se
## recalcula la ruta; tras [constant MAX_STUCK] atascos seguidos abandona (el combate) o se teletransporta (el regreso).
const STUCK_CHECK_TICKS: int = 90
const STUCK_MIN_MOVE: float = 0.5
const MAX_STUCK: int = 3
## Ticks sin ver a ningún objetivo válido tras los que da por perdido el combate (3 s).
const LOST_TARGET_TICKS: int = 180
## Tope del regreso y de su inmunidad (60 s): pasado ese tiempo se teletransporta a su puesto.
const RETURN_MAX_TICKS: int = 3600
## Parada (ticks, mínimo y máximo) en un punto de la patrulla.
const PATROL_REST_TICKS: Vector2i = Vector2i(180, 420)
## Puntos que se suman a la amenaza del objetivo actual (para no cambiar a cada rato).
const TARGET_STICKINESS: float = 60.0
## Peso de la cercanía en la amenaza (puntos por metro que falta para el radio de visión).
const PROXIMITY_WEIGHT: float = 4.0
## Distancia (m) por debajo de la cual pide una ficha de ataque, sobre su alcance.
const TOKEN_REQUEST_MARGIN: float = 3.0
## Fracción de la carrera con la que avanza mientras reacciona en la alerta (lo justo, 0,1, para que su cuerpo gire
## hacia el enemigo: el personaje solo gira al moverse).
const ALERT_CREEP: float = 0.12
## Cuánto más cerca que su alcance (m) se queda al acercarse para atacar.
const APPROACH_MARGIN: float = 0.5
## Margen (m) alrededor de la distancia de círculo antes de retroceder (por dentro) o de acercarse (por fuera).
const CIRCLE_INNER_MARGIN: float = 0.4
const CIRCLE_OUTER_MARGIN: float = 0.5
## Cada cuántos ticks puede cambiar el sentido en que rodea (mínimo y máximo).
const STRAFE_FLIP_TICKS: Vector2i = Vector2i(120, 300)
## Radio (m) de la alerta de un jefe que grita.
const SHOUT_RADIUS: float = 60.0
## Distancia (m, en horizontal) a la que un derribado hostil es el objetivo preferido (docs/habilidades.md,
## sección 4.5).
const DOWNED_PRIORITY_RADIUS: float = 6.0

## La definición del PNJ.
var definition: NpcDefinition = null
## Estado actual ([enum State]).
var state: int = State.REST
## Quién ha creado este cerebro (el generador al que pertenece), para el sistema de generadores.
var owner_slot: Variant = null

var _world: NpcWorld = null
var _entity: NetEntity = null
var _combatant: Combatant = null
var _net_id: int = 0
var _realm: int = 0
var _post: Vector3 = Vector3.ZERO
var _rest_yaw: float = 0.0
var _route: PackedVector3Array = PackedVector3Array()
var _route_index: int = 0
var _route_direction: int = 1
var _group: StringName = &""
var _light_reach: float = 2.4
var _heavy_reach: float = 2.6
# Plan que repite entre pensamientos.
var _look_yaw: float = 0.0
var _plan_move: Vector2 = Vector2.ZERO
var _plan_sprint: bool = false
var _press_buttons: int = 0
var _press_until: int = -1
# Tiempos.
var _last_think: int = -1
var _phase: int = 0
var _state_since: int = 0
var _rest_until: int = 0
var _alert_until: int = 0
var _target_id: int = 0
var _target_lost_since: int = -1
# Radio (m) más allá del cual da por perdido al objetivo: el de su definición, o el del grito si se lo han
# avisado desde lejos.
var _lose_radius: float = 28.0
var _combat_engaged: bool = false
var _next_attack_tick: int = 0
var _attacks_done: int = 0
var _was_attacking: bool = false
var _strafe_sign: float = 1.0
var _strafe_flip_tick: int = 0
var _shouted: bool = false
var _reinforced: bool = false
var _token_target: int = 0
# Ataque decidido para el siguiente turno ([enum Attack]; -1 = ninguno todavía).
var _planned: int = -1
# Ruta.
var _path: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
var _path_goal: Vector3 = Vector3.ZERO
var _path_tick: int = -1000
# Atasco.
var _stuck_reference: Vector3 = Vector3.ZERO
var _stuck_tick: int = 0
var _stuck_count: int = 0
var _wants_to_move: bool = false
# Último estado conocido del cuerpo.
var _position: Vector3 = Vector3.ZERO
var _distance_to_target: float = -1.0
var _state_log: Array[Vector2i] = []
var _think_count: int = 0


## [param rng_seed] fija el azar de este PNJ (reacciones, paradas, ataques).
func _init(rng_seed: int = 1) -> void:
	super(rng_seed, BotBrain.Pattern.IDLE)


## Nombre del estado [param value] en español.
static func state_name(value: int) -> String:
	match value:
		State.PATROL:
			return "patrulla"
		State.ALERT:
			return "alerta"
		State.COMBAT:
			return "combate"
		State.RETURN:
			return "regreso"
	return "reposo"


## Enlaza el cerebro con su cuerpo: el mundo ([param world]), la entidad y su [Combatant], el puesto (posición
## [param home] y rumbo [param home_yaw]), la ruta de patrulla (puede estar vacía) y el grupo de alerta.
func bind(world: NpcWorld, entity: NetEntity, combatant: Combatant, new_definition: NpcDefinition,
		home: Vector3, home_yaw: float, route: PackedVector3Array = PackedVector3Array(),
		group: StringName = &"") -> void:
	_world = world
	_entity = entity
	_combatant = combatant
	definition = new_definition
	_net_id = entity.net_id
	_realm = entity.realm
	_phase = _net_id % THINK_INTERVAL_TICKS
	_post = home
	_rest_yaw = home_yaw
	_look_yaw = home_yaw
	_position = home
	_route = route
	_group = group
	_strafe_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0
	var weapon: WeaponTicks = CombatCatalog.weapon(combatant.get_character().combat.weapon_id)
	if weapon != null:
		var light: AttackTicks = CombatCatalog.attack(weapon.light_ids[0])
		var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
		if light != null and light.shape != null:
			_light_reach = light.shape.range_m
		if heavy != null and heavy.shape != null:
			_heavy_reach = heavy.shape.range_m
	if _world != null:
		_world.join_group(_group, self)


## Se llama al retirar el PNJ del mundo: sale de su grupo y suelta sus fichas.
func unbind() -> void:
	if _world != null:
		_world.leave_group(_group, self)
		_world.tokens.release_all(_net_id)


## true mientras el PNJ está vivo.
func is_alive() -> bool:
	return _combatant != null and _combatant.is_alive()


## Posición del cuerpo en el último pensamiento (la actual si está enlazado).
func get_position() -> Vector3:
	return _entity.get_position() if _entity != null else _position


## net_id del PNJ.
func get_net_id() -> int:
	return _net_id


## net_id del objetivo actual (0 = ninguno).
func get_target_id() -> int:
	return _target_id


## Reino del PNJ (código de red).
func get_realm() -> int:
	return _realm


## Grupo de alerta del PNJ.
func get_group() -> StringName:
	return _group


## Lugar de su puesto.
func get_home() -> Vector3:
	return _post


## Las transiciones de estado hasta ahora: [code]Vector2i(tick, estado)[/code] en orden. Es lo que se compara para
## comprobar que dos ejecuciones con la misma semilla hacen lo mismo.
func get_state_log() -> Array[Vector2i]:
	return _state_log


## Cuántos puntos tiene su ruta de patrulla (0 = se queda en su puesto).
func get_route_size() -> int:
	return _route.size()


## Cuántas veces ha pensado desde que existe.
func get_think_count() -> int:
	return _think_count


## Ruta que sigue ahora (puede estar vacía).
func get_path_points() -> PackedVector3Array:
	return _path


## Una línea para el registro de depuración (comando [code]npc_debug[/code]): estado, objetivo, distancia, ruta, vida y
## fichas.
func describe() -> String:
	var health: String = "%d/%d" % [_combatant.health, _combatant.max_health] if _combatant != null else "-"
	return "%s #%d [%s] estado=%s objetivo=%d dist=%.1f ruta=%d/%d vida=%s fichas=%s" % [
		definition.display_name if definition != null else "?", _net_id,
		NetProtocol.realm_display_name(_realm), state_name(state), _target_id,
		_distance_to_target, _path_index, _path.size(), health,
		"sí" if _token_target != 0 and _world.tokens.holds(_token_target, _net_id, _world.tick) else "no"]


## La entrada del tick [param tick]. Piensa si le toca; si no, repite el plan.
func next_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	_position = position
	if _combatant == null or _combatant.is_dead():
		var idle := PlayerInput.new()
		idle.tick = tick
		idle.look_yaw = yaw
		return idle
	if _last_think < 0 or (tick % THINK_INTERVAL_TICKS == _phase and tick != _last_think):
		_think(tick, position, yaw)
		_last_think = tick
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _look_yaw
	input.move = _plan_move
	if _plan_sprint:
		input.buttons |= PlayerInput.SPRINT
	if tick < _press_until:
		input.buttons |= _press_buttons
	return input


## Un aviso de un compañero del grupo: hay un enemigo ([param target_id]). Solo lo atiende quien está en reposo o
## patrullando. Devuelve true si pasa a la alerta.
func receive_alert(target_id: int, tick: int) -> bool:
	if not is_alive() or (state != State.REST and state != State.PATROL):
		return false
	var target: Combatant = _world.find_combatant(target_id)
	if not _world.is_valid_target(target, _realm, definition.ignores_safe_area):
		return false
	_target_id = target_id
	_enter(State.ALERT, tick)
	_alert_until = tick + _reaction_ticks()
	# Se lo han dicho desde lejos: no lo ve, pero sabe dónde está.
	_lose_radius = maxf(definition.lose_radius, SHOUT_RADIUS)
	return true


# --- Pensamiento ------------------------------------------------------------------------------

func _think(tick: int, position: Vector3, yaw: float) -> void:
	_think_count += 1
	_world.tick = tick
	if _state_log.is_empty():
		_state_log.append(Vector2i(tick, state))
	_track_attack(tick)
	match state:
		State.REST:
			_think_rest(tick, position, yaw)
		State.PATROL:
			_think_patrol(tick, position, yaw)
		State.ALERT:
			_think_alert(tick, position, yaw)
		State.COMBAT:
			_think_combat(tick, position, yaw)
		State.RETURN:
			_think_return(tick, position, yaw)
	_check_stuck(tick, position)


func _think_rest(tick: int, position: Vector3, yaw: float) -> void:
	_plan_move = Vector2.ZERO
	_plan_sprint = false
	_look_yaw = _rest_yaw
	if _react_to_threat(tick, position, yaw):
		return
	if _route.size() >= 2 and tick >= _rest_until:
		_enter(State.PATROL, tick)


func _think_patrol(tick: int, position: Vector3, yaw: float) -> void:
	if _react_to_threat(tick, position, yaw):
		return
	var goal: Vector3 = _route[_route_index]
	if _horizontal_distance(position, goal) <= ARRIVE_DISTANCE:
		_advance_route()
		_rest_until = tick + _rng.randi_range(PATROL_REST_TICKS.x, PATROL_REST_TICKS.y)
		_rest_yaw = yaw
		_enter(State.REST, tick)
		return
	_walk_to(goal, position, tick, definition.patrol_speed_scale, false)


func _think_alert(tick: int, position: Vector3, yaw: float) -> void:
	_plan_move = Vector2(0.0, ALERT_CREEP)
	_plan_sprint = false
	var target: Combatant = _world.find_combatant(_target_id)
	var in_range: bool = target != null and _world.is_valid_target(target, _realm, definition.ignores_safe_area) \
			and _horizontal_distance(position, target.entity.get_position()) <= _lose_radius
	if not in_range:
		_lose_target(tick, position, yaw)
		return
	_look_yaw = _yaw_toward(target.entity.get_position() - position, yaw)
	if tick >= _alert_until:
		_enter(State.COMBAT, tick)
		_begin_engagement(tick, position)


func _think_combat(tick: int, position: Vector3, yaw: float) -> void:
	if _horizontal_distance(position, _post) > definition.leash_radius:
		_begin_return(tick)
		return
	var target: Combatant = _choose_target(tick, position)
	if target == null:
		_plan_sprint = false
		_plan_move = Vector2.ZERO
		if _target_lost_since < 0:
			_target_lost_since = tick
		if tick - _target_lost_since >= LOST_TARGET_TICKS:
			_lose_target(tick, position, yaw)
		return
	_target_lost_since = -1
	if target.get_id() != _target_id:
		_release_token()
		_target_id = target.get_id()
	var target_position: Vector3 = target.entity.get_position()
	var to_target: Vector3 = target_position - position
	to_target.y = 0.0
	var distance: float = to_target.length()
	_distance_to_target = distance
	_look_yaw = _yaw_toward(to_target, yaw)
	_maybe_call_reinforcements(tick)

	var action: int = _combatant.get_character().combat.action
	if _is_attack_action(action) or tick < _press_until:
		# En mitad de un ataque, un bloqueo o una carga: solo apunta, y renueva su ficha.
		_plan_move = Vector2.ZERO
		_plan_sprint = false
		if _token_target != 0:
			_world.tokens.renew(_token_target, _net_id, tick)
		return
	if action == CombatState.Action.STAGGER or action == CombatState.Action.STUN \
			or action == CombatState.Action.DODGE:
		_plan_move = Vector2.ZERO
		return

	var ready: bool = tick >= _next_attack_tick
	# A un derribado se le remata con el ligero: ni escudo ni carga.
	var finishing: bool = target.is_downed()
	if ready and not finishing and _planned_attack() == Attack.BLOCK:
		_start_block(tick)
		return
	var has_token: bool = false
	var heavy_next: bool = not finishing \
			and (_planned_attack() == Attack.HEAVY or _planned_attack() == Attack.SPECIAL)
	var reach: float = _heavy_reach if heavy_next else _light_reach
	if ready and distance <= reach + TOKEN_REQUEST_MARGIN:
		has_token = _world.tokens.try_claim(target.get_id(), _net_id, tick)
		if has_token:
			_token_target = target.get_id()
	if has_token:
		# El ataque gira al cuerpo hacia su rumbo en el primer tick (ver ActionMachine), así que basta con estar a
		# su alcance.
		if distance <= reach - 0.1:
			_start_attack(tick, heavy_next)
			return
		_close_in(target_position, position, tick, distance, reach)
		return
	_circle(target_position, position, tick, distance)


func _think_return(tick: int, position: Vector3, yaw: float) -> void:
	_plan_sprint = false
	if _horizontal_distance(position, _post) <= ARRIVE_DISTANCE:
		_arrive_home(tick, yaw)
		return
	if tick - _state_since >= RETURN_MAX_TICKS or _stuck_count >= MAX_STUCK:
		# No llega: vuelve de golpe.
		_world.teleport(_net_id, _post)
		_arrive_home(tick, yaw)
		return
	_walk_to(_post, position, tick, definition.chase_speed_scale, false)


# --- Transiciones -----------------------------------------------------------------------------

func _enter(new_state: int, tick: int) -> void:
	if state == State.COMBAT and new_state != State.COMBAT:
		_release_token()
		_combat_engaged = false
		_shouted = false
	state = new_state
	_state_since = tick
	_press_until = -1
	_press_buttons = 0
	_plan_move = Vector2.ZERO
	_plan_sprint = false
	_target_lost_since = -1
	_path = PackedVector3Array()
	_path_tick = -1000
	_stuck_count = 0
	_stuck_tick = tick
	_stuck_reference = _position
	_state_log.append(Vector2i(tick, new_state))


# Si ve a un enemigo (o le han hecho daño) pasa a la alerta; true si ha cambiado de estado.
func _react_to_threat(tick: int, position: Vector3, yaw: float) -> bool:
	var attacker: Combatant = _recent_attacker(tick)
	if attacker != null:
		_target_id = attacker.get_id()
		_lose_radius = definition.lose_radius
		_enter(State.COMBAT, tick)
		_begin_engagement(tick, position)
		return true
	var seen: Combatant = _scan(position, yaw)
	if seen == null:
		return false
	_target_id = seen.get_id()
	_lose_radius = definition.lose_radius
	_enter(State.ALERT, tick)
	_alert_until = tick + _reaction_ticks()
	_look_yaw = _yaw_toward(seen.entity.get_position() - position, yaw)
	return true


# El enemigo que le ha golpeado en el último segundo, si sigue siendo un objetivo válido.
func _recent_attacker(tick: int) -> Combatant:
	if _combatant.last_enemy_id == 0 or _combatant.last_enemy_tick < 0 \
			or tick - _combatant.last_enemy_tick > 60:
		return null
	var attacker: Combatant = _world.find_combatant(_combatant.last_enemy_id)
	if attacker != null and _world.is_valid_target(attacker, _realm, definition.ignores_safe_area):
		return attacker
	return null


func _begin_engagement(tick: int, position: Vector3) -> void:
	_combat_engaged = true
	_target_lost_since = -1
	_next_attack_tick = tick + _rng.randi_range(6, 18)
	if definition.shouts and not _shouted:
		_shouted = true
		if _world.count_alive_in_group(_group, self) > 0:
			_world.alert_group(_group, self, maxf(definition.alert_radius, SHOUT_RADIUS), _target_id)
	_world.alert_group(_group, self, definition.alert_radius, _target_id)
	_stuck_reference = position


func _begin_return(tick: int) -> void:
	_enter(State.RETURN, tick)
	_target_id = 0
	_world.tokens.release_all(_net_id)
	# Regreso inmune: nadie le hace daño hasta que llega (el tope es el del regreso).
	_combatant.protected_until = tick + RETURN_MAX_TICKS


func _arrive_home(tick: int, yaw: float) -> void:
	_combatant.heal_full()
	_combatant.protected_until = tick
	_target_id = 0
	_rest_yaw = yaw if _route.size() >= 2 else _rest_yaw
	_rest_until = tick + _rng.randi_range(PATROL_REST_TICKS.x, PATROL_REST_TICKS.y)
	_reinforced = false
	_enter(State.REST, tick)


# Pierde al objetivo: vuelve a su puesto si se ha desplazado, o se queda donde está. En los dos casos acaba
# regenerado (el combate se reinicia).
func _lose_target(tick: int, position: Vector3, yaw: float) -> void:
	_target_id = 0
	if _horizontal_distance(position, _post) > ARRIVE_DISTANCE * 2.0:
		_begin_return(tick)
	else:
		_arrive_home(tick, yaw)


func _advance_route() -> void:
	if _route.size() < 2:
		return
	var next_index: int = _route_index + _route_direction
	if next_index < 0 or next_index >= _route.size():
		_route_direction = -_route_direction
		next_index = _route_index + _route_direction
	_route_index = clampi(next_index, 0, _route.size() - 1)


# --- Percepción y amenaza ----------------------------------------------------------------------

# El enemigo más cercano que ve o nota (radio, cono y línea de visión), o null. Un derribado a menos de
# DOWNED_PRIORITY_RADIUS m va antes que cualquiera en pie.
func _scan(position: Vector3, yaw: float) -> Combatant:
	var radius: float = maxf(definition.perception_radius, definition.awareness_radius)
	var best: Combatant = null
	var best_distance: float = INF
	var best_downed: Combatant = null
	var best_downed_distance: float = INF
	for candidate: Combatant in _world.query_targets(position, radius, _realm, definition.ignores_safe_area):
		var other: Vector3 = candidate.entity.get_position()
		var distance: float = _horizontal_distance(position, other)
		var preferred: bool = candidate.is_downed() and distance <= DOWNED_PRIORITY_RADIUS
		if distance >= (best_downed_distance if preferred else best_distance):
			continue
		var noticed: bool = distance <= definition.awareness_radius
		if not noticed:
			if distance > definition.perception_radius \
					or not _in_cone(position, yaw, other, definition.perception_cone_deg):
				continue
		if not _world.line_of_sight(position, other):
			continue
		if preferred:
			best_downed = candidate
			best_downed_distance = distance
		else:
			best = candidate
			best_distance = distance
	return best_downed if best_downed != null else best


# El objetivo de mayor amenaza (daño recibido de cada enemigo más su cercanía) entre los que hay a menos de su
# radio de pérdida, o null si no hay ninguno. Un derribado a menos de DOWNED_PRIORITY_RADIUS m va antes (el más
# cercano; empate por net_id: la lista viene ordenada).
func _choose_target(tick: int, position: Vector3) -> Combatant:
	var best: Combatant = null
	var best_score: float = -INF
	var best_downed: Combatant = null
	var best_downed_distance: float = INF
	for candidate: Combatant in _world.query_targets(position, _lose_radius, _realm,
			definition.ignores_safe_area):
		var distance: float = _horizontal_distance(position, candidate.entity.get_position())
		if candidate.is_downed() and distance <= DOWNED_PRIORITY_RADIUS and distance < best_downed_distance:
			best_downed = candidate
			best_downed_distance = distance
		var score: float = float(_combatant.ledger.damage_by(candidate.get_id(), tick)) \
				+ (definition.perception_radius - distance) * PROXIMITY_WEIGHT
		if candidate.get_id() == _target_id:
			score += TARGET_STICKINESS
		if score > best_score:
			best_score = score
			best = candidate
	return best_downed if best_downed != null else best


func _in_cone(position: Vector3, yaw: float, other: Vector3, cone_deg: float) -> bool:
	if cone_deg >= 359.0:
		return true
	var to_other := Vector3(other.x - position.x, 0.0, other.z - position.z)
	if to_other.length_squared() < 0.0001:
		return true
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	return forward.angle_to(to_other) <= deg_to_rad(cone_deg) * 0.5


# --- Movimiento -------------------------------------------------------------------------------

# Camina hacia [param goal] por la ruta de navegación (o en línea recta si no hay malla o el destino está cerca y
# a su altura), con la fracción [param speed_scale] de la velocidad de carrera.
func _walk_to(goal: Vector3, position: Vector3, tick: int, speed_scale: float, sprint: bool) -> void:
	var direction: Vector3 = _steer(goal, position, tick)
	_look_yaw = _yaw_toward(direction, _look_yaw)
	_plan_move = Vector2(0.0, speed_scale)
	_plan_sprint = sprint
	_wants_to_move = true


func _steer(goal: Vector3, position: Vector3, tick: int) -> Vector3:
	var waypoint: Vector3 = goal
	var close: bool = _horizontal_distance(position, goal) < DIRECT_DISTANCE \
			and absf(goal.y - position.y) < DIRECT_MAX_HEIGHT
	if not close and _world.has_navigation():
		if _path.is_empty() or tick - _path_tick >= REPATH_TICKS \
				or _path_goal.distance_to(goal) > REPATH_GOAL_DISTANCE:
			_path = _world.get_path(position, goal, _realm)
			_path_goal = goal
			_path_tick = tick
			_path_index = 1 if _path.size() > 1 else 0
		while _path_index < _path.size() - 1 \
				and _horizontal_distance(position, _path[_path_index]) < WAYPOINT_DISTANCE:
			_path_index += 1
		if not _path.is_empty():
			waypoint = _path[mini(_path_index, _path.size() - 1)]
	var direction: Vector3 = waypoint - position
	direction.y = 0.0
	return direction


# Se acerca al objetivo hasta el alcance de su ataque.
func _close_in(target_position: Vector3, position: Vector3, tick: int, distance: float, reach: float) -> void:
	if distance <= reach - APPROACH_MARGIN:
		_plan_move = Vector2.ZERO
		_plan_sprint = false
		return
	_walk_to(target_position, position, tick, definition.chase_speed_scale,
			definition.can_sprint and distance > 8.0)


# Sin ficha: lo rodea a la distancia de círculo (3 a 4 m): se acerca si está lejos, retrocede si está encima y, a
# la distancia buena, da vueltas a su alrededor.
func _circle(target_position: Vector3, position: Vector3, tick: int, distance: float) -> void:
	_plan_sprint = false
	if tick >= _strafe_flip_tick:
		_strafe_sign = -_strafe_sign if _rng.randf() < 0.5 else _strafe_sign
		_strafe_flip_tick = tick + _rng.randi_range(STRAFE_FLIP_TICKS.x, STRAFE_FLIP_TICKS.y)
	var ring: float = definition.circle_distance
	var to_target: Vector3 = target_position - position
	to_target.y = 0.0
	if distance > ring + CIRCLE_OUTER_MARGIN:
		_walk_to(target_position, position, tick, definition.chase_speed_scale,
				definition.can_sprint and distance > 8.0)
		if distance < DIRECT_DISTANCE + ring:
			_look_yaw = _yaw_toward(to_target, _look_yaw)
		return
	_look_yaw = _yaw_toward(to_target, _look_yaw)
	_wants_to_move = true
	if distance < ring - CIRCLE_INNER_MARGIN:
		_plan_move = Vector2(0.0, -1.0)
	else:
		_plan_move = Vector2(_strafe_sign * 0.6, 0.0)


# --- Ataques ----------------------------------------------------------------------------------

func _is_attack_action(action: int) -> bool:
	return action == CombatState.Action.LIGHT or action == CombatState.Action.HEAVY \
			or action == CombatState.Action.CHARGE


# Lleva la cuenta de si está atacando: al acabar, suelta la ficha y programa la pausa hasta el siguiente.
func _track_attack(tick: int) -> void:
	var attacking: bool = _is_attack_action(_combatant.get_character().combat.action)
	if attacking:
		_was_attacking = true
		return
	if _was_attacking:
		_was_attacking = false
		_release_token()
		_next_attack_tick = tick + _gap_ticks()


func _release_token() -> void:
	if _token_target != 0:
		_world.tokens.release(_token_target, _net_id)
		_token_target = 0


func _gap_ticks() -> int:
	return roundi(_rng.randf_range(definition.attack_gap_s.x, definition.attack_gap_s.y) * 60.0)


func _reaction_ticks() -> int:
	return roundi(_rng.randf_range(definition.reaction_s.x, definition.reaction_s.y) * 60.0)


# El siguiente ataque que ha decidido ([enum Attack]): el especial cada [member NpcDefinition.special_every]
# ataques; si no, una tirada entre levantar el escudo, el fuerte y el ligero con las probabilidades de su
# definición. Se decide una sola vez y se recuerda hasta que lo hace, para que todo el acercamiento hable del
# mismo ataque (y la tirada no se repita en cada pensamiento).
func _planned_attack() -> int:
	if _planned < 0:
		if definition.special_every > 0 and (_attacks_done + 1) % definition.special_every == 0:
			_planned = Attack.SPECIAL
		else:
			var roll: float = _rng.randf()
			if roll < definition.block_chance:
				_planned = Attack.BLOCK
			elif roll < definition.block_chance + definition.heavy_chance:
				_planned = Attack.HEAVY
			else:
				_planned = Attack.LIGHT
	return _planned


func _start_attack(tick: int, heavy: bool) -> void:
	var weapon: WeaponTicks = CombatCatalog.weapon(_combatant.get_character().combat.weapon_id)
	_press_buttons = PlayerInput.PRIMARY
	if heavy and weapon != null:
		var heavy_attack: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
		# Mantener el botón convierte el ligero en la carga del fuerte; al soltarlo (o al llegar a la carga
		# mínima) lo lanza.
		_press_until = tick + heavy_attack.charge_min_ticks + 1
	else:
		_press_until = tick + 2
	_attacks_done += 1
	_planned = -1
	_plan_move = Vector2.ZERO
	_plan_sprint = false


# En lugar de atacar, levanta el escudo un rato.
func _start_block(tick: int) -> void:
	var duration: int = roundi(_rng.randf_range(definition.block_s.x, definition.block_s.y) * 60.0)
	_press_buttons = PlayerInput.BLOCK
	_press_until = tick + duration
	_next_attack_tick = tick + duration + _gap_ticks()
	_planned = -1
	_plan_move = Vector2.ZERO
	_plan_sprint = false


# Al bajar de la fracción de vida de su definición llama a los refuerzos, una sola vez y solo si quedan compañeros
# vivos en su grupo.
func _maybe_call_reinforcements(_tick: int) -> void:
	if _reinforced or definition.reinforcement_id == &"" or definition.reinforcement_count <= 0:
		return
	if float(_combatant.health) > float(_combatant.max_health) * definition.reinforcement_health_fraction:
		return
	_reinforced = true
	if _world.count_alive_in_group(_group, self) <= 0:
		return
	_world.request_reinforcements(self, definition.reinforcement_id, definition.reinforcement_count)


# --- Atasco -----------------------------------------------------------------------------------

func _check_stuck(tick: int, position: Vector3) -> void:
	if tick - _stuck_tick < STUCK_CHECK_TICKS:
		return
	var moved: float = _horizontal_distance(position, _stuck_reference)
	if _wants_to_move and moved < STUCK_MIN_MOVE:
		_stuck_count += 1
		_path_tick = -1000
		if _stuck_count >= MAX_STUCK and state == State.COMBAT:
			_begin_return(tick)
	else:
		_stuck_count = 0
	_stuck_reference = position
	_stuck_tick = tick
	_wants_to_move = false


static func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
