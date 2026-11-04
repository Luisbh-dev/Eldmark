class_name CombatFixture
extends RefCounted
## Helpers for the server combat tests: hand-assembled fighters (character, entity, input queue and
## [Combatant]) in a [SubViewport] with its own physics world, and bot brains that run an input
## script.

## Character scene (the server removes its Visual node).
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")


## A [SubViewport] with its own world (3D and physics), the flat zone of [ZoneFixture] and the test
## zone's spawn points. Returns the viewport; the zone is the [code]world[/code] metadata.
static func make_world(parent: Node) -> SubViewport:
	return NetHarness.make_world_viewport(parent, "")


## Server character: the player scene without its Visual node and without its own processing,
## hung from [param parent] at [param position] facing [param yaw].
static func make_character(parent: Node3D, position: Vector3, yaw: float) -> PlayerCharacter:
	var character: PlayerCharacter = PLAYER_SCENE.instantiate() as PlayerCharacter
	var visual: Node = character.get_node_or_null(^"Visual")
	if visual != null:
		character.remove_child(visual)
		visual.free()
	character.set_physics_process(false)
	character.set_process(false)
	character.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	parent.add_child(character)
	var state := PlayerState.new()
	state.position = position
	state.yaw = PlayerState.to_f32(yaw)
	state.grounded = true
	character.set_state(PlayerState.decode(state.encode()))
	return character


## A network entity ([param net_id], [param realm]) with its character at [param position] facing
## [param yaw].
static func make_entity(parent: Node3D, net_id: int, realm: int, position: Vector3,
		yaw: float) -> NetEntity:
	var entity := NetEntity.new()
	entity.net_id = net_id
	entity.kind = NetProtocol.EntityKind.PLAYER
	entity.realm = realm
	entity.display_name = "Luchador%d" % net_id
	entity.node = make_character(parent, position, yaw)
	return entity


## An input queue ready for an entity that spawns facing [param yaw].
static func make_queue(yaw: float) -> InputQueue:
	var queue := InputQueue.new()
	queue.reset(0, NetProtocol.neutral_input(0, yaw))
	return queue


## A hand-built fighter: [Combatant] with its entity ([param net_id], [param realm]), its
## character at [param position] facing [param yaw] and its input queue. [param peer] can be null
## (no rewind).
static func make_fighter(parent: Node3D, net_id: int, realm: int, position: Vector3, yaw: float,
		timing: CombatTiming, peer: ServerPeer = null) -> Combatant:
	var entity: NetEntity = make_entity(parent, net_id, realm, position, yaw)
	return Combatant.new(entity, make_queue(yaw), peer, timing, CombatCatalog.rules().health_max)


## What the server does when placing a body ([code]ZoneServer._place[/code]): velocity 0, state
## passed through encode/decode and teleport counter +1. It serves as the [CombatDirector]'s
## [code]place[/code] in tests.
static func place(entity: NetEntity, position: Vector3, yaw: float) -> void:
	var character: PlayerCharacter = entity.get_character()
	var state: PlayerState = character.get_state()
	state.position = position
	state.velocity = Vector3.ZERO
	state.yaw = PlayerState.to_f32(yaw)
	state.grounded = true
	state.coyote_ticks = 0
	state.jump_buffer_ticks = 0
	character.set_state(PlayerState.decode(state.encode()))
	entity.teleport_counter = (entity.teleport_counter + 1) & EntityRecord.TELEPORT_MASK


## Puts the fighter on the first tick of the active hit of light attack [param light_index] (0 to
## 2) at tick [param s].
static func start_light_active(fighter: Combatant, s: int, light_index: int = 0) -> void:
	var weapon: WeaponTicks = CombatCatalog.weapon(fighter.get_character().combat.weapon_id)
	var attack: AttackTicks = CombatCatalog.attack(weapon.light_ids[light_index])
	var state: CombatState = fighter.get_character().combat
	state.action = CombatState.Action.LIGHT
	state.action_id = attack.id
	state.action_tick = s - attack.windup_ticks


## Puts the fighter on the first tick of the active hit of the heavy attack at tick [param s],
## launched with [param charge_ticks] of charge.
static func start_heavy_active(fighter: Combatant, s: int, charge_ticks: int = 0) -> void:
	var weapon: WeaponTicks = CombatCatalog.weapon(fighter.get_character().combat.weapon_id)
	var attack: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
	var state: CombatState = fighter.get_character().combat
	state.action = CombatState.Action.HEAVY
	state.action_id = attack.id
	state.action_tick = s - attack.windup_ticks
	state.charge_ticks = charge_ticks


## Puts the fighter blocking since tick [param since]. With [param parry_open] it opens the parry
## window on that same tick (it leaves it as the action machine does after a BLOCK rising edge).
static func start_block(fighter: Combatant, since: int, parry_open: bool = false) -> void:
	var state: CombatState = fighter.get_character().combat
	state.action = CombatState.Action.BLOCK
	state.action_id = 0
	state.action_tick = since
	if parry_open:
		state.parry_ready_tick = since + CombatCatalog.rules().parry_cooldown_ticks


## Puts the fighter dodging since tick [param since].
static func start_dodge(fighter: Combatant, since: int) -> void:
	var state: CombatState = fighter.get_character().combat
	state.action = CombatState.Action.DODGE
	state.action_id = 0
	state.action_tick = since


## Records in [param history] the fighter's state after tick [param tick], with its defensive flags
## computed for that tick (what the server would do in [code]_record_history[/code]).
static func record(history: StateHistory, fighter: Combatant, tick: int) -> void:
	var character: PlayerCharacter = fighter.get_character()
	var flags: int = (fighter.entity.teleport_counter & EntityRecord.TELEPORT_MASK) \
			<< EntityRecord.TELEPORT_SHIFT
	if character.grounded:
		flags |= EntityRecord.FLAG_GROUNDED
	flags = (flags & EntityRecord.HISTORY_FLAGS_MASK) | ActionMachine.defense_flags(character.combat, tick)
	history.record(tick, fighter.get_id(), fighter.entity.get_position(), character.yaw, flags)


## Bot brain that runs a script: on each tick it calls [member script]
## ([code](tick: int, position: Vector3, yaw: float) -> PlayerInput[/code]) and, if there is no
## script, does nothing.
class ScriptBrain:
	extends BotBrain

	var script_fn: Callable = Callable()


	func next_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
		if script_fn.is_valid():
			return script_fn.call(tick, position, yaw)
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = yaw
		return input
