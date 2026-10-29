class_name CombatFixture
extends RefCounted
## Ayudantes de las pruebas del combate del servidor: luchadores montados a mano (personaje,
## entidad, cola de entradas y [Combatant]) en un [SubViewport] con su propio mundo de física, y
## cerebros de bot que ejecutan un guion de entradas.

## Escena del personaje (el servidor le quita el nodo Visual).
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")


## Un [SubViewport] con su propio mundo (3D y física), la zona plana de [ZoneFixture] y los puntos de
## aparición de la zona de pruebas. Devuelve el viewport; la zona es el metadato [code]world[/code].
static func make_world(parent: Node) -> SubViewport:
	return NetHarness.make_world_viewport(parent, "")


## Personaje del servidor: la escena del jugador sin su nodo Visual y sin proceso propio, colgado de
## [param parent] en [param position] mirando a [param yaw].
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


## Un luchador a mano: [Combatant] con su entidad ([param net_id], [param realm]), su personaje en
## [param position] mirando a [param yaw] y su cola de entradas. [param peer] puede ser null (sin
## rebobinado).
static func make_fighter(parent: Node3D, net_id: int, realm: int, position: Vector3, yaw: float,
		timing: CombatTiming, peer: ServerPeer = null) -> Combatant:
	var entity := NetEntity.new()
	entity.net_id = net_id
	entity.kind = NetProtocol.EntityKind.PLAYER
	entity.realm = realm
	entity.display_name = "Luchador%d" % net_id
	entity.node = make_character(parent, position, yaw)
	var queue := InputQueue.new()
	queue.reset(0, NetProtocol.neutral_input(0, yaw))
	return Combatant.new(entity, queue, peer, timing, CombatCatalog.rules().health_max)


## Pone al luchador en el primer tick del golpe activo del ligero [param light_index] (0 a 2) en el
## tick [param s].
static func start_light_active(fighter: Combatant, s: int, light_index: int = 0) -> void:
	var weapon: WeaponTicks = CombatCatalog.weapon(fighter.get_character().combat.weapon_id)
	var attack: AttackTicks = CombatCatalog.attack(weapon.light_ids[light_index])
	var state: CombatState = fighter.get_character().combat
	state.action = CombatState.Action.LIGHT
	state.action_id = attack.id
	state.action_tick = s - attack.windup_ticks


## Pone al luchador en el primer tick del golpe activo del fuerte en el tick [param s], lanzado con
## [param charge_ticks] de carga.
static func start_heavy_active(fighter: Combatant, s: int, charge_ticks: int = 0) -> void:
	var weapon: WeaponTicks = CombatCatalog.weapon(fighter.get_character().combat.weapon_id)
	var attack: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
	var state: CombatState = fighter.get_character().combat
	state.action = CombatState.Action.HEAVY
	state.action_id = attack.id
	state.action_tick = s - attack.windup_ticks
	state.charge_ticks = charge_ticks


## Pone al luchador bloqueando desde el tick [param since]. Con [param parry_open] abre la ventana
## de parada en ese mismo tick (la deja como la máquina de acciones tras un flanco de BLOCK).
static func start_block(fighter: Combatant, since: int, parry_open: bool = false) -> void:
	var state: CombatState = fighter.get_character().combat
	state.action = CombatState.Action.BLOCK
	state.action_id = 0
	state.action_tick = since
	if parry_open:
		state.parry_ready_tick = since + CombatCatalog.rules().parry_cooldown_ticks


## Pone al luchador esquivando desde el tick [param since].
static func start_dodge(fighter: Combatant, since: int) -> void:
	var state: CombatState = fighter.get_character().combat
	state.action = CombatState.Action.DODGE
	state.action_id = 0
	state.action_tick = since


## Graba en [param history] el estado del luchador tras el tick [param tick], con sus banderas
## defensivas calculadas para ese tick (lo que haría el servidor en [code]_record_history[/code]).
static func record(history: StateHistory, fighter: Combatant, tick: int) -> void:
	var character: PlayerCharacter = fighter.get_character()
	var flags: int = (fighter.entity.teleport_counter & EntityRecord.TELEPORT_MASK) \
			<< EntityRecord.TELEPORT_SHIFT
	if character.grounded:
		flags |= EntityRecord.FLAG_GROUNDED
	flags |= ActionMachine.defense_flags(character.combat, tick)
	history.record(tick, fighter.get_id(), fighter.entity.get_position(), character.yaw, flags)


## Cerebro de bot que ejecuta un guion: en cada tick llama a [member script]
## ([code](tick: int, position: Vector3, yaw: float) -> PlayerInput[/code]) y, si no hay guion,
## no hace nada.
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
