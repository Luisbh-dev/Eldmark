class_name HfsmBrain
extends BotBrain
## Brain of a combat NPC: a hierarchical state machine (docs/fortress.md, section 4.2; MUN-07 and MUN-08).
## [br][br]
## [b]States[/b] ([enum State]): [code]REPOSO[/code] (standing still at its post) → [code]PATRULLA[/code] (walks the
## markers of its route, pausing at each one) → [code]ALERTA[/code] (has noticed an enemy: looks at it and reacts for
## a few tenths of a second) → [code]COMBATE[/code] (chases it, circles it and attacks) → [code]REGRESO[/code] (has
## lost it or strayed beyond its leash: returns to its post, [b]regenerated and immune[/b]).
## [br][br]
## [b]Thinks every [constant THINK_INTERVAL_TICKS] ticks[/b] (staggered by its net_id) using the state of the bodies
## after the previous tick (step 0 of the tick order, docs/fortress.md 1.7), and in between it repeats its plan: movement,
## heading and buttons. It produces one [PlayerInput] per tick that enters its [InputQueue] like a fake player's, so
## its body is a [PlayerCharacter] simulated with the same rules as players. Its only source of randomness is its
## seeded [RandomNumberGenerator]: with the same seeds and the same players it always does the same thing
## ([method get_state_log]).
## [br][br]
## [b]Perception[/b]: radius, cone and line of sight ([method NpcWorld.line_of_sight]); within the "hearing" radius
## ([member NpcDefinition.awareness_radius]) line of sight is enough. [b]Threat[/b]: the damage each enemy has dealt
## to it plus their proximity, with a boost for the current target so it does not switch constantly.
## [b]Leash[/b]: beyond [member NpcDefinition.leash_radius] from its post, it returns. [b]Tokens[/b]: it only attacks
## with an [AttackTokens] token (at most two NPCs at once against the same target); without one it circles at 3 or
## 4 m. [b]Group alert[/b]: on entering combat it warns its group members within [member NpcDefinition.alert_radius];
## a boss ([member NpcDefinition.shouts]) shouts and, when its health drops, calls reinforcements once per life
## (returning to its post regenerated does not re-arm the call; only [method rearm_reinforcements] does).
## [br][br]
## [b]Knocked down[/b] (docs/abilities.md, section 4.5; H3c): NPCs are never knocked down, but they finish off
## others. A hostile knocked-down player within [constant DOWNED_PRIORITY_RADIUS] m is the preferred target (ahead of
## the nearest standing one, also when noticed while resting or patrolling) and is attacked with the light attack
## (PRIMARY), without raising the shield or charging; it requests its [AttackTokens] token like any other target.
## [br][br]
## [b]Attacked from afar[/b] (phase 4 review): whoever hits it from beyond its lose radius (an archer at 33 m) raises
## its radius up to them, like a companion's warning, and it chases them; if it cannot reach them, the leash
## or getting stuck sends it to an immune return. Before, it would stand still without a target and heal every 3 s.

## States of the machine.
enum State { REST, PATROL, ALERT, COMBAT, RETURN }
## Which attack the NPC picks.
enum Attack { LIGHT, HEAVY, SPECIAL, BLOCK }

## How many ticks between thoughts.
const THINK_INTERVAL_TICKS: int = 6
## Distance (m) at which it considers a patrol point or its post reached.
const ARRIVE_DISTANCE: float = 1.2
## Distance (m) to an intermediate route point at which it moves on to the next one.
const WAYPOINT_DISTANCE: float = 0.8
## How many ticks between route recalculations, and how far the destination must move for it to recalculate sooner.
const REPATH_TICKS: int = 45
const REPATH_GOAL_DISTANCE: float = 1.5
## Below this horizontal distance (m) and this height difference it goes straight to the target, without a route.
const DIRECT_DISTANCE: float = 4.0
const DIRECT_MAX_HEIGHT: float = 1.2
## Getting stuck: if within [constant STUCK_CHECK_TICKS] ticks it advances less than [constant STUCK_MIN_MOVE] m while
## trying to move, the route is recalculated; after [constant MAX_STUCK] consecutive stucks it gives up (combat) or
## teleports (return).
const STUCK_CHECK_TICKS: int = 90
const STUCK_MIN_MOVE: float = 0.5
const MAX_STUCK: int = 3
## Ticks without seeing any valid target after which it considers combat lost (3 s).
const LOST_TARGET_TICKS: int = 180
## Cap on the return and its immunity (60 s): after that time it teleports to its post.
const RETURN_MAX_TICKS: int = 3600
## Pause (ticks, minimum and maximum) at a patrol point.
const PATROL_REST_TICKS: Vector2i = Vector2i(180, 420)
## Points added to the current target's threat (so it does not switch constantly).
const TARGET_STICKINESS: float = 60.0
## Weight of proximity in the threat (points per meter short of the vision radius).
const PROXIMITY_WEIGHT: float = 4.0
## Distance (m) beyond its reach below which it requests an attack token.
const TOKEN_REQUEST_MARGIN: float = 3.0
## Fraction of the run speed at which it advances while reacting during the alert (just enough, 0.1, for its body to
## turn toward the enemy: the character only turns when moving).
const ALERT_CREEP: float = 0.12
## How much closer than its reach (m) it stops when approaching to attack.
const APPROACH_MARGIN: float = 0.5
## Margin (m) around the circling distance before backing off (inside) or closing in (outside).
const CIRCLE_INNER_MARGIN: float = 0.4
const CIRCLE_OUTER_MARGIN: float = 0.5
## How many ticks between changes of the direction in which it circles (minimum and maximum).
const STRAFE_FLIP_TICKS: Vector2i = Vector2i(120, 300)
## Radius (m) of the alert of a boss that shouts.
const SHOUT_RADIUS: float = 60.0
## Distance (m, horizontal) at which a hostile knocked-down player is the preferred target (docs/abilities.md,
## section 4.5).
const DOWNED_PRIORITY_RADIUS: float = 6.0
## Minimum transitions kept by [method get_state_log]: on reaching double, it keeps the last
## [constant STATE_LOG_MAX] (a patrolling NPC changes state about 10 times a minute and lives for days).
const STATE_LOG_MAX: int = 256
## Margin (m) over the distance to whoever hit it from beyond its lose radius (an archer) by which its radius is
## raised to go after them.
const ATTACKER_RADIUS_MARGIN: float = 4.0

## The NPC's definition.
var definition: NpcDefinition = null
## Current state ([enum State]).
var state: int = State.REST
## Who created this brain (the spawner it belongs to), for the spawner system.
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
# Plan it repeats between thoughts.
var _look_yaw: float = 0.0
var _plan_move: Vector2 = Vector2.ZERO
var _plan_sprint: bool = false
var _press_buttons: int = 0
var _press_until: int = -1
# Timings.
var _last_think: int = -1
var _phase: int = 0
var _state_since: int = 0
var _rest_until: int = 0
var _alert_until: int = 0
var _target_id: int = 0
var _target_lost_since: int = -1
# Radius (m) beyond which it considers the target lost: the one from its definition, or the shout's if it was
# alerted from afar.
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
# Attack decided for the next turn ([enum Attack]; -1 = none yet).
var _planned: int = -1
# Route.
var _path: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
var _path_goal: Vector3 = Vector3.ZERO
var _path_tick: int = -1000
# Getting stuck.
var _stuck_reference: Vector3 = Vector3.ZERO
var _stuck_tick: int = 0
var _stuck_count: int = 0
var _wants_to_move: bool = false
# Last known state of the body.
var _position: Vector3 = Vector3.ZERO
var _distance_to_target: float = -1.0
var _state_log: Array[Vector2i] = []
var _think_count: int = 0


## [param rng_seed] sets this NPC's randomness (reactions, pauses, attacks).
func _init(rng_seed: int = 1) -> void:
	super(rng_seed, BotBrain.Pattern.IDLE)


## Name of the state [param value] in Spanish.
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


## Binds the brain to its body: the world ([param world]), the entity and its [Combatant], the post (position
## [param home] and heading [param home_yaw]), the patrol route (may be empty) and the alert group.
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


## Called when the NPC is removed from the world: it leaves its group and releases its tokens.
func unbind() -> void:
	if _world != null:
		_world.leave_group(_group, self)
		_world.tokens.release_all(_net_id)


## true while the NPC is alive.
func is_alive() -> bool:
	return _combatant != null and _combatant.is_alive()


## Position of the body at the last thought (the current one if bound).
func get_position() -> Vector3:
	return _entity.get_position() if _entity != null else _position


## net_id of the NPC.
func get_net_id() -> int:
	return _net_id


## net_id of the current target (0 = none).
func get_target_id() -> int:
	return _target_id


## Realm of the NPC (network code).
func get_realm() -> int:
	return _realm


## Alert group of the NPC.
func get_group() -> StringName:
	return _group


## Location of its post.
func get_home() -> Vector3:
	return _post


## The latest state transitions: [code]Vector2i(tick, estado)[/code] in order. This is what gets compared to
## verify that two runs with the same seed do the same thing. It is bounded: it keeps between
## [constant STATE_LOG_MAX] and double that (the oldest are discarded at once on reaching double; phase 4 review:
## it used to grow without limit over the NPC's whole life).
func get_state_log() -> Array[Vector2i]:
	return _state_log


## How many points its patrol route has (0 = stays at its post).
func get_route_size() -> int:
	return _route.size()


## How many times it has thought since it came into existence.
func get_think_count() -> int:
	return _think_count


## Route it is following now (may be empty).
func get_path_points() -> PackedVector3Array:
	return _path


## One line for the debug log ([code]npc_debug[/code] command): state, target, distance, route, health and
## tokens.
func describe() -> String:
	var health: String = "%d/%d" % [_combatant.health, _combatant.max_health] if _combatant != null else "-"
	return "%s #%d [%s] estado=%s objetivo=%d dist=%.1f ruta=%d/%d vida=%s fichas=%s" % [
		definition.display_name if definition != null else "?", _net_id,
		NetProtocol.realm_display_name(_realm), state_name(state), _target_id,
		_distance_to_target, _path_index, _path.size(), health,
		"sí" if _token_target != 0 and _world.tokens.holds(_token_target, _net_id, _world.tick) else "no"]


## The input for tick [param tick]. It thinks if it is its turn; otherwise it repeats the plan.
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


## true if it has already called its reinforcements in this life (or it is not due to call them until re-armed).
func has_called_reinforcements() -> bool:
	return _reinforced


## Gives back the reinforcement call: the full respawn of the Hollow (docs/fortress.md 4.3), which leaves the neutral
## fort as freshly created, re-arms it for the Ford Captain that is still alive.
func rearm_reinforcements() -> void:
	_reinforced = false


## A warning from a group companion: there is an enemy ([param target_id]). Only handled by one that is resting or
## patrolling. Returns true if it moves to the alert state.
func receive_alert(target_id: int, tick: int) -> bool:
	if not is_alive() or (state != State.REST and state != State.PATROL):
		return false
	var target: Combatant = _world.find_combatant(target_id)
	if not _world.is_valid_target(target, _realm, definition.ignores_safe_area):
		return false
	_target_id = target_id
	_enter(State.ALERT, tick)
	_alert_until = tick + _reaction_ticks()
	# It was told from afar: it does not see it, but it knows where it is.
	_lose_radius = maxf(definition.lose_radius, SHOUT_RADIUS)
	return true


# --- Thinking ---------------------------------------------------------------------------------

func _think(tick: int, position: Vector3, yaw: float) -> void:
	_think_count += 1
	_world.tick = tick
	if _state_log.is_empty():
		_log_state(tick, state)
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
	if target == null and _reach_for_attacker(tick, position):
		target = _choose_target(tick, position)
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
		# In the middle of an attack, a block or a charge: it only aims, and renews its token.
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
	# A knocked-down target is finished off with the light attack: no shield or charge.
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
		# The attack turns the body toward its heading on the first tick (see ActionMachine), so being within
		# reach is enough.
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
		# It does not arrive: it returns at once.
		_world.teleport(_net_id, _post)
		_arrive_home(tick, yaw)
		return
	_walk_to(_post, position, tick, definition.chase_speed_scale, false)


# --- Transitions ------------------------------------------------------------------------------

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
	_log_state(tick, new_state)


# Records a transition in the bounded log of [method get_state_log] (trims it in half on reaching double the
# cap, so it does not copy on every transition).
func _log_state(tick: int, value: int) -> void:
	_state_log.append(Vector2i(tick, value))
	if _state_log.size() >= STATE_LOG_MAX * 2:
		_state_log = _state_log.slice(_state_log.size() - STATE_LOG_MAX)


# If it sees an enemy (or has been damaged) it moves to the alert state; true if it changed state.
func _react_to_threat(tick: int, position: Vector3, yaw: float) -> bool:
	var attacker: Combatant = _recent_attacker(tick)
	if attacker != null:
		_target_id = attacker.get_id()
		_lose_radius = definition.lose_radius
		_reach_for_attacker(tick, position)
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


# The enemy that hit it in the last second, if it is still a valid target.
func _recent_attacker(tick: int) -> Combatant:
	if _combatant.last_enemy_id == 0 or _combatant.last_enemy_tick < 0 \
			or tick - _combatant.last_enemy_tick > 60:
		return null
	var attacker: Combatant = _world.find_combatant(_combatant.last_enemy_id)
	if attacker != null and _world.is_valid_target(attacker, _realm, definition.ignores_safe_area):
		return attacker
	return null


# If whoever hit it a moment ago ([method _recent_attacker]) is beyond its lose radius, it raises the radius up to
# them (with [constant ATTACKER_RADIUS_MARGIN]), like a companion's warning: an archer cannot wear it down without
# it going after them. Returns true if it raised it.
func _reach_for_attacker(tick: int, position: Vector3) -> bool:
	var attacker: Combatant = _recent_attacker(tick)
	if attacker == null:
		return false
	var distance: float = _horizontal_distance(position, attacker.entity.get_position())
	if distance < _lose_radius:
		return false
	_lose_radius = distance + ATTACKER_RADIUS_MARGIN
	return true


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
	# Immune return: nobody can damage it until it arrives (the cap is the return's).
	_combatant.protected_until = tick + RETURN_MAX_TICKS


func _arrive_home(tick: int, yaw: float) -> void:
	_combatant.heal_full()
	_combatant.protected_until = tick
	_target_id = 0
	_rest_yaw = yaw if _route.size() >= 2 else _rest_yaw
	_rest_until = tick + _rng.randi_range(PATROL_REST_TICKS.x, PATROL_REST_TICKS.y)
	# The reinforcement call is not re-armed: it is one per life (phase 4 review). If it were re-armed here, every
	# failed assault that takes half its health would add two more Hollow to the garrison.
	_enter(State.REST, tick)


# Loses the target: returns to its post if it has moved away, or stays where it is. In both cases it ends up
# regenerated (combat resets).
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


# --- Perception and threat ---------------------------------------------------------------------

# The nearest enemy it sees or notices (radius, cone and line of sight), or null. A knocked-down one within
# DOWNED_PRIORITY_RADIUS m comes before any standing one.
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


# The highest-threat target (damage received from each enemy plus their proximity) among those within its lose
# radius, or null if there are none. A knocked-down one within DOWNED_PRIORITY_RADIUS m comes first (the nearest;
# ties broken by net_id: the list comes sorted).
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


# --- Movement ---------------------------------------------------------------------------------

# Walks toward [param goal] along the navigation route (or in a straight line if there is no mesh or the destination
# is near and at its height), at the fraction [param speed_scale] of run speed.
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


# Closes in on the target up to the reach of its attack.
func _close_in(target_position: Vector3, position: Vector3, tick: int, distance: float, reach: float) -> void:
	if distance <= reach - APPROACH_MARGIN:
		_plan_move = Vector2.ZERO
		_plan_sprint = false
		return
	_walk_to(target_position, position, tick, definition.chase_speed_scale,
			definition.can_sprint and distance > 8.0)


# Without a token: circles it at the circling distance (3 to 4 m): it closes in if far, backs off if too close and,
# at the right distance, walks circles around it.
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


# --- Attacks ----------------------------------------------------------------------------------

func _is_attack_action(action: int) -> bool:
	return action == CombatState.Action.LIGHT or action == CombatState.Action.HEAVY \
			or action == CombatState.Action.CHARGE


# Keeps track of whether it is attacking: when done, it releases the token and schedules the pause before the next one.
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


# The next attack it has decided on ([enum Attack]): the special every [member NpcDefinition.special_every]
# attacks; otherwise, a roll between raising the shield, the heavy and the light attack with the probabilities of its
# definition. It is decided only once and remembered until it carries it out, so that the whole approach is about the
# same attack (and the roll is not repeated on every thought).
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
		# Holding the button turns the light attack into the heavy attack's charge; on release (or on reaching the minimum
		# charge) it launches it.
		_press_until = tick + heavy_attack.charge_min_ticks + 1
	else:
		_press_until = tick + 2
	_attacks_done += 1
	_planned = -1
	_plan_move = Vector2.ZERO
	_plan_sprint = false


# Instead of attacking, it raises the shield for a while.
func _start_block(tick: int) -> void:
	var duration: int = roundi(_rng.randf_range(definition.block_s.x, definition.block_s.y) * 60.0)
	_press_buttons = PlayerInput.BLOCK
	_press_until = tick + duration
	_next_attack_tick = tick + duration + _gap_ticks()
	_planned = -1
	_plan_move = Vector2.ZERO
	_plan_sprint = false


# When it drops below the health fraction of its definition it calls reinforcements, only once per life and only if
# living companions remain in its group (the spawner does not allow more living than it calls: NpcSpawnerSystem).
func _maybe_call_reinforcements(_tick: int) -> void:
	if _reinforced or definition.reinforcement_id == &"" or definition.reinforcement_count <= 0:
		return
	if float(_combatant.health) > float(_combatant.max_health) * definition.reinforcement_health_fraction:
		return
	_reinforced = true
	if _world.count_alive_in_group(_group, self) <= 0:
		return
	_world.request_reinforcements(self, definition.reinforcement_id, definition.reinforcement_count)


# --- Getting stuck ----------------------------------------------------------------------------

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
