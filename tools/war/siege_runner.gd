class_name SiegeRunner
extends Node
## A siege with fake players on the real zone (GUE-15, GUE-17; docs/fuerte.md, section 7), in a
## single process and with no network: loads Vado Gris with its Terrain3D, starts a [ZoneServer] and advances it "by hand",
## many ticks per physics frame ([member ticks_per_frame]), so that a battle of minutes of game time
## lasts seconds. It is used by [code]tools/war/siege_battle.gd[/code] (the command-line tool, which
## prints the report) and [code]tests/test_siege_zone.gd[/code] (a short version inside the suite).
## [br][br]
## It records what is needed to measure: when each bot reaches the gate and by which route, the war warnings and
## the player and NPC deaths. Without NPCs (the F6a siege), [method kill_captain] declares the captain dead like
## the [code]fort_kill_captain[/code] command and [method spawn_captain_double] places a mortal NPC in his place so that
## the bots kill him themselves. With them ([code]with_npcs[/code] in [method start], F6b) the real Hollow,
## Ford Captain and owner's garrison defend the fort, and [method set_npc_health] weakens them for
## short tests without touching [code]data/npcs/[/code]. The bots wait for their own in their camp and go in formation
## (GUE-44); [method set_rally] changes or removes that, and [member rally_departures] records each departure. A share goes up to the
## walkway (GUE-45); [method set_walkway_share] changes which share, and [method place_of] says where each dead has fallen.

## Siege zone.
const ZONE_ID: String = "vado_gris"
## At this distance (m) from the gate, horizontally, a bot is counted as having arrived.
const ARRIVAL_DISTANCE: float = 3.0
## Ticks advanced per physics frame.
const DEFAULT_TICKS_PER_FRAME: int = 40
## Ticks between two checks of the condition of [method advance_until].
const CHECK_TICKS: int = 30
## Ticks per second.
const TICK_RATE: int = 60

## Ticks advanced per physics frame.
var ticks_per_frame: int = DEFAULT_TICKS_PER_FRAME
## The zone server (null before [method start]).
var server: ZoneServer = null
var world: Node3D = null
## War warnings in the order they came out (each with its tick), player deaths
## ([code]{tick, net_id, realm, position}[/code]) and NPC deaths ([code]{tick, net_id, npc, position}[/code], with the id
## of its definition).
var war_events: Array[NetMessages.EntityEvent] = []
var deaths: Array[Dictionary] = []
var npc_deaths: Array[Dictionary] = []
## net_id -> {realm, route, tick} of each bot that has reached the gate.
var arrivals: Dictionary[int, Dictionary] = {}
## net_id -> realm of the siege fake players.
var bots: Dictionary[int, int] = {}
## Rally departures (GUE-44), in the order they happen: [code]{tick, net_id, realm, route}[/code] of each bot that
## leaves the rally point of its camp with its own (also if it did not have to wait because there were already enough).
var rally_departures: Array[Dictionary] = []

# net_id -> brain of each siege bot (to know which route it follows).
var _brains: Dictionary[int, BotBrain] = {}
var _remaining: int = 0
var _running: bool = false
# The rally imposed on the bots (set_rally; -1 = BotBrain's) and the last rally departure recorded
# for each bot.
var _rally_size: int = -1
var _rally_period: int = BotBrain.SIEGE_RALLY_PERIOD_TICKS
var _rally_seen: Dictionary[int, int] = {}
# The share of bots with the walkway role that is imposed (set_walkway_share; -1 = BotBrain's).
var _walkway_share: float = -1.0


## Loads the zone, starts the server and leaves it ready (without advancing). [param battle_log_path] enables the
## server's [code]--battle-log[/code]. Without [param with_npcs] the server starts with
## [code]--no-npcs[/code] (no Hollow, Captain or Guardians: the F6a siege, measured that way); with it, the zone's
## NPCs (F4) defend the fort (F6b). Returns false if it could not.
func start(parent: Node, battle_log_path: String = "", max_players: int = 256, with_npcs: bool = false) -> bool:
	var packed: PackedScene = load(NetZones.scene_path(ZONE_ID)) as PackedScene
	if packed == null:
		return false
	world = packed.instantiate() as Node3D
	parent.add_child(world)
	var zone_root: ZoneRoot = world as ZoneRoot
	if zone_root != null:
		zone_root.strip_for_server()
	server = ZoneServer.new()
	server.name = "ZoneServer"
	server.log_enabled = false
	parent.add_child(server)
	for _i: int in 4:
		await get_tree().physics_frame
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.max_players = max_players
	config.no_dummies = true
	config.no_npcs = not with_npcs
	config.battle_log_path = battle_log_path
	if server.start(config, world, null, DevAuthProvider.new()) != OK:
		return false
	server.set_physics_process(false)
	server.get_fortresses().war_event_emitted.connect(func(event: NetMessages.EntityEvent) -> void:
		war_events.append(event))
	server.get_combat().event_emitted.connect(_on_combat_event)
	server.tick_finished.connect(_on_tick_finished)
	return true


## Closes the server and frees the zone.
func finish() -> void:
	if is_instance_valid(server):
		server.stop()
		if server.get_parent() != null:
			server.get_parent().remove_child(server)
		server.free()
	server = null
	if is_instance_valid(world):
		if world.get_parent() != null:
			world.get_parent().remove_child(world)
		world.queue_free()
	world = null


## Adds [param count] siege fake players of [param realm], with the seeds [param seed_base],
## [param seed_base] + 1... Returns their net_id.
func add_siege_bots(realm: int, count: int, seed_base: int) -> Array[int]:
	var ids: Array[int] = []
	for i: int in count:
		var brain := BotBrain.new(seed_base + i, BotBrain.Pattern.SIEGE)
		if _rally_size >= 0:
			brain.set_rally(_rally_size, _rally_period)
		if _walkway_share >= 0.0:
			brain.set_walkway_share(_walkway_share)
		var net_id: int = server.add_fake_player(brain, realm)
		if net_id > 0:
			bots[net_id] = realm
			_brains[net_id] = brain
			ids.append(net_id)
	return ids


## Changes the rally of the siege bots (GUE-44; [method BotBrain.set_rally]), those already there and those added later:
## they leave their camp when there are [param group_size] from their realm or at the next tick of the clock, which makes one lap
## every [param period_ticks] ticks. With [param group_size] 1 or less they do not wait (as before GUE-44).
func set_rally(group_size: int, period_ticks: int = BotBrain.SIEGE_RALLY_PERIOD_TICKS) -> void:
	_rally_size = group_size
	_rally_period = period_ticks
	for net_id: int in _brains:
		_brains[net_id].set_rally(group_size, period_ticks)


## Changes which share of the siege bots has the walkway role (GUE-45; [method BotBrain.set_walkway_share]),
## those already there and those added later. With 0 nobody goes up (as before GUE-45).
func set_walkway_share(share: float) -> void:
	_walkway_share = share
	for net_id: int in _brains:
		_brains[net_id].set_walkway_share(share)


## Where a dead player at [param position] has fallen, with the battle summary's classification
## ([method BattleSummary.classify_route]: [code]walkway[/code], [code]gate[/code], [code]bridge[/code],
## [code]ford[/code] or [code]other[/code]), using the fortress circle and the zone's routes.
func place_of(position: Vector3) -> StringName:
	var circle: Dictionary = server.get_fortresses().get_circle(fortress_id())
	var center: Vector3 = circle["center"]
	var fortress: Dictionary = {"circle": [center.x, center.y, center.z]}
	return BattleSummary.classify_route([position.x, position.y, position.z], fortress, server.get_approach_routes())


## The NPCs of definition [param npc_id] that appear from now on will have [param health] health (a copy of the
## definition with a different health, only on this server: [method NpcSpawnerSystem.set_definition_override]). It must be
## called right after [method start], before advancing, so that it already applies to the first ones. Returns false if
## the server has no NPCs or the definition does not exist.
func set_npc_health(npc_id: StringName, health: int) -> bool:
	var system: NpcSpawnerSystem = server.get_npc_system()
	var base: NpcDefinition = NpcCatalog.get_definition(npc_id)
	if system == null or base == null or health <= 0:
		return false
	var weaker: NpcDefinition = base.duplicate() as NpcDefinition
	weaker.max_health = health
	system.set_definition_override(npc_id, weaker)
	return true


## Places a mortal, motionless NPC in the captain's spot, registered as the captain (see
## [method ZoneServer.spawn_captain_double]). Returns its net_id.
func spawn_captain_double() -> int:
	return server.spawn_captain_double(fortress_id())


## Declares the captain dead with the console command [code]fort_kill_captain[/code]. Returns true if the
## fort was guarding him (GARRISONED phase with the captain alive).
func kill_captain() -> bool:
	return server.console_command("fort_kill_captain").contains("ha muerto")


## Multiplies the capture speed ([code]fort_capture_speed[/code]).
func set_capture_speed(factor: int) -> void:
	server.get_fortresses().set_capture_speed(fortress_id(), factor)


## Id of the zone's fortress.
func fortress_id() -> StringName:
	return server.get_fortresses().get_fortress_ids()[0]


## Live state of the fortress.
func state() -> FortressState:
	return server.get_fortresses().get_fortress_state(fortress_id())


## Advances [param ticks] server ticks.
func advance(ticks: int) -> void:
	_remaining += ticks
	_running = true
	while _remaining > 0:
		await get_tree().physics_frame
	_running = false


## Advances until [param condition] is true (checked every [constant CHECK_TICKS] ticks) or
## [param max_ticks] pass. Returns the ticks it advanced, or -1 if it was not met.
func advance_until(condition: Callable, max_ticks: int) -> int:
	var advanced: int = 0
	while advanced < max_ticks:
		if bool(condition.call()):
			return advanced
		var chunk: int = mini(CHECK_TICKS, max_ticks - advanced)
		await advance(chunk)
		advanced += chunk
	return advanced if bool(condition.call()) else -1


## Server tick.
func tick() -> int:
	return server.get_tick()


## The war warnings (ids of [WarEvents]) in the order they came out.
func war_ids() -> Array[int]:
	var ids: Array[int] = []
	for event: NetMessages.EntityEvent in war_events:
		ids.append(event.war_event)
	return ids


## Tick of the first war warning [param war_event] from tick [param from_tick] (-1 if it has not come out).
func tick_of_war(war_event: int, from_tick: int = 0) -> int:
	for event: NetMessages.EntityEvent in war_events:
		if event.war_event == war_event and event.tick >= from_tick:
			return event.tick
	return -1


## How many times the war warning [param war_event] has come out since tick [param from_tick].
func count_war(war_event: int, from_tick: int = 0) -> int:
	var count: int = 0
	for event: NetMessages.EntityEvent in war_events:
		if event.war_event == war_event and event.tick >= from_tick:
			count += 1
	return count


## The brain of siege bot [param net_id] (null if it is not one of its own).
func get_brain(net_id: int) -> BotBrain:
	return _brains.get(net_id)


## How many bots of [param realm] are still alive.
func alive_bots(realm: int) -> int:
	var count: int = 0
	for net_id: int in bots:
		if bots[net_id] != realm:
			continue
		var combatant: Combatant = server.get_combat().get_combatant(net_id)
		if combatant != null and combatant.is_alive():
			count += 1
	return count


## Seconds of game time that [param ticks] amounts to.
static func seconds(ticks: int) -> float:
	return float(ticks) / float(TICK_RATE)


func _physics_process(delta: float) -> void:
	if not _running or server == null:
		return
	var count: int = mini(_remaining, ticks_per_frame)
	for _i: int in count:
		server._physics_process(delta)
	_remaining -= count


# Records the deaths of players (with the victim's realm and location) and of war NPCs (with their definition).
func _on_combat_event(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
	if event.event != NetMessages.EntityEvent.Kind.DEATH:
		return
	var victim: NetEntity = server.get_registry().get_entity(event.net_id)
	if victim != null and victim.kind == NetProtocol.EntityKind.NPC and victim.npc_def_id > 0:
		var definition: NpcDefinition = NpcCatalog.get_by_number(victim.npc_def_id)
		npc_deaths.append({"tick": event.tick, "net_id": event.net_id,
				"npc": definition.id if definition != null else &"", "position": victim.get_position()})
		return
	if victim == null or victim.kind != NetProtocol.EntityKind.PLAYER:
		return
	deaths.append({"tick": event.tick, "net_id": event.net_id, "realm": victim.realm,
			"position": victim.get_position()})


# At the end of each tick, records who leaves the rally and who has just reached the gate and by which route.
func _on_tick_finished(tick_now: int) -> void:
	_note_rally_departures()
	var gate: FortGate = server.get_fortresses().get_gate(fortress_id())
	if gate == null:
		return
	var gate_point := Vector2(gate.global_position.x, gate.global_position.z)
	for net_id: int in bots:
		if arrivals.has(net_id):
			continue
		var entity: NetEntity = server.get_registry().get_entity(net_id)
		if entity == null:
			continue
		var position: Vector3 = entity.get_position()
		if Vector2(position.x, position.z).distance_to(gate_point) <= ARRIVAL_DISTANCE:
			arrivals[net_id] = {"realm": bots[net_id], "route": _route_of(net_id), "tick": tick_now}


# The bots that have just left the rally point (GUE-44).
func _note_rally_departures() -> void:
	for net_id: int in _brains:
		var left: int = _brains[net_id].get_last_rally_departure()
		if left >= 0 and left != _rally_seen.get(net_id, -1):
			_rally_seen[net_id] = left
			rally_departures.append({"tick": left, "net_id": net_id, "realm": bots.get(net_id, 0),
					"route": _route_of(net_id)})


# The route that bot [param net_id] follows (the brain chooses it at the start).
func _route_of(net_id: int) -> StringName:
	var brain: BotBrain = _brains.get(net_id)
	return brain.get_siege_route() if brain != null else &""
