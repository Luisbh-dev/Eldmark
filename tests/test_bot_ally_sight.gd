extends TestCase
## A cuántos de los suyos ve un bot del cliente de [code]--bot[/code] cerca de un punto ([BotAllySight], el contador de
## la reunión de los bots de asedio, GUE-44), con un [RemoteWorld] de verdad y mensajes sintéticos: cuenta a los
## jugadores remotos de su reino, vivos, ya dibujados y a menos del radio en horizontal; no a los de otro reino, ni a los
## muertos, ni a los PNJ (tampoco los de su reino), ni a los que están más lejos o aún no se dibujan.

const V: int = NetProtocol.Realm.VARDHEIM
const S: int = NetProtocol.Realm.SOLMARCH

var _world: RemoteWorld = null


func before_each() -> void:
	_world = RemoteWorld.new()
	_world.install_visuals = false
	_world.setup(InterpolationClock.new())
	tree.root.add_child(_world)


func after_each() -> void:
	if is_instance_valid(_world):
		tree.root.remove_child(_world)
		_world.free()
	_world = null
	await wait_process_frames()


func _spawn(net_id: int, kind: int, realm: int, position: Vector3, tick: int = 100) -> void:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = kind
	spawn.spawn_tick = tick
	spawn.realm = realm
	spawn.display_name = "Remoto"
	if kind == NetProtocol.EntityKind.NPC:
		spawn.npc_def_id = 3
	var state := PlayerState.new()
	state.position = position
	state.grounded = true
	spawn.state = state
	_world.on_spawn(spawn)


func test_it_counts_the_live_players_of_its_realm_within_the_radius() -> void:
	var center := Vector3(10.0, 0.0, -130.0)
	_spawn(1, NetProtocol.EntityKind.PLAYER, V, center + Vector3(3.0, 0.0, 4.0))
	_spawn(2, NetProtocol.EntityKind.PLAYER, V, center + Vector3(-10.0, 5.0, 0.0))
	_spawn(3, NetProtocol.EntityKind.PLAYER, S, center + Vector3(1.0, 0.0, 0.0))
	_spawn(4, NetProtocol.EntityKind.NPC, V, center + Vector3(0.0, 0.0, 1.0))
	_spawn(5, NetProtocol.EntityKind.PLAYER, V, center + Vector3(16.0, 0.0, 0.0))
	_spawn(6, NetProtocol.EntityKind.PLAYER, V, center + Vector3(0.0, 0.0, -2.0))
	_spawn(7, NetProtocol.EntityKind.PLAYER, V, center + Vector3(2.0, 0.0, 2.0), 200)
	# El 6 muere (su registro llega con la vida a 0).
	var dead := EntityRecord.from_state(6, NetProtocol.EntityKind.PLAYER, PlayerState.new(), 0)
	dead.position = center + Vector3(0.0, 0.0, -2.0)
	dead.health_q = EntityRecord.HEALTH_Q_DEAD
	var snapshot := NetMessages.Snapshot.new()
	snapshot.server_tick = 120
	snapshot.records = [dead] as Array[EntityRecord]
	_world.on_snapshot(snapshot)
	_world.draw(120.0, 0.016)
	assert_eq(BotAllySight.count_in(_world, V, center, 15.0), 2,
			"el 1 (a 5 m) y el 2 (a 10 m en horizontal, más arriba); no el de Solmarch, ni el PNJ, ni el de 16 m, ni el muerto, ni el que aún no se dibuja")
	assert_eq(BotAllySight.count_in(_world, S, center, 15.0), 1, "para uno de Solmarch, el suyo")
	assert_eq(BotAllySight.count_in(_world, V, center, 6.0), 1, "con un radio de 6 m, solo el 1")
	_world.draw(200.0, 0.016)
	assert_eq(BotAllySight.count_in(_world, V, center, 15.0), 3, "el 7, cuando ya se dibuja")
	assert_eq(BotAllySight.count_in(null, V, center, 15.0), 0, "sin mundo, nadie")
