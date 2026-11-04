extends TestCase
## How many of its own side a [code]--bot[/code] client bot sees near a point ([BotAllySight], the counter of
## the siege bots' rally, GUE-44), with a real [RemoteWorld] and synthetic messages: it counts
## remote players of its realm that are alive, already drawn and within the radius horizontally; not those of another realm, nor
## the dead, nor NPCs (not even those of its realm), nor those farther away or not yet drawn. Nor the
## knocked-down ones, like the server with the fake ones (review of the abilities integration).

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
	# Number 6 dies (its record arrives with health at 0).
	var dead := EntityRecord.from_state(6, NetProtocol.EntityKind.PLAYER, PlayerState.new(), 0)
	dead.position = center + Vector3(0.0, 0.0, -2.0)
	dead.health_q = EntityRecord.HEALTH_Q_DEAD
	var snapshot := NetMessages.Snapshot.new()
	snapshot.server_tick = 120
	snapshot.records = [dead] as Array[EntityRecord]
	_world.on_snapshot(snapshot)
	_world.draw(120.0, 0.016)
	assert_eq(BotAllySight.count_in(_world, V, center, 15.0), 2,
			"number 1 (at 5 m) and number 2 (at 10 m horizontally, higher up); not the Solmarch one, nor the NPC, nor the one at 16 m, nor the dead one, nor the one not yet drawn")
	assert_eq(BotAllySight.count_in(_world, S, center, 15.0), 1, "for a Solmarch one, its own")
	assert_eq(BotAllySight.count_in(_world, V, center, 6.0), 1, "with a 6 m radius, only number 1")
	_world.draw(200.0, 0.016)
	assert_eq(BotAllySight.count_in(_world, V, center, 15.0), 3, "number 7, once it is drawn")
	assert_eq(BotAllySight.count_in(null, V, center, 15.0), 0, "with no world, nobody")


func test_a_downed_ally_does_not_count() -> void:
	# A knocked-down character publishes its knocked-down health, which is never 0 (Combatant.publish): only its drawn action (DOWNED) says
	# it is not standing. The server does not count it (ZoneServer._rebuild_ally_cache, is_alive); neither does --bot.
	var center := Vector3(10.0, 0.0, -130.0)
	_spawn(1, NetProtocol.EntityKind.PLAYER, V, center + Vector3(3.0, 0.0, 0.0))
	_spawn(2, NetProtocol.EntityKind.PLAYER, V, center + Vector3(-3.0, 0.0, 0.0))
	var downed := EntityRecord.from_state(2, NetProtocol.EntityKind.PLAYER, PlayerState.new(), 0)
	downed.position = center + Vector3(-3.0, 0.0, 0.0)
	downed.action = CombatState.Action.DOWNED
	downed.health_q = EntityRecord.quantize_health(300, CombatCatalog.rules().downed_health)
	assert_true(downed.health_q != EntityRecord.HEALTH_Q_DEAD, "its published health is not that of a dead one")
	var snapshot := NetMessages.Snapshot.new()
	snapshot.server_tick = 120
	snapshot.records = [downed] as Array[EntityRecord]
	_world.on_snapshot(snapshot)
	_world.draw(120.0, 0.016)
	assert_eq(BotAllySight.count_in(_world, V, center, 15.0), 1, "number 1; not the knocked-down one")
