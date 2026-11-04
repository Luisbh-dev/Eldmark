extends TestCase
## The telegraphed hits that a client bot remembers ([BotThreatSight], F6b): each TELEGRAPH is a
## [BotBrain.Threat] with the origin, the turn and the reach of the telegraph, active until its impact plus the hit's active
## window; the same NPC replaces its previous telegraph and its DESPAWN forgets it. Other events do not count, nor (with
## the rule of whoever creates it) the telegraphs of NPCs that cannot damage the bot: [SwarmBot] only keeps those of enemy
## war NPCs and [ClientBotBrains] those of whoever [method BotThreatSight.is_hostile_view] deems hostile.


func _telegraph(npc_id: int, tick: int, origin: Vector3, yaw: float, radius_cm: int,
		impact_in: int) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.telegraph(npc_id, tick, 7, NetMessages.EntityEvent.SHAPE_SECTOR, origin, yaw,
			radius_cm, impact_in)


func test_a_telegraph_is_a_threat_until_its_impact_and_active_window() -> void:
	var sight := BotThreatSight.new()
	sight.note(_telegraph(40, 1000, Vector3(1.0, 2.0, 3.0), PI, 350, 60))
	var found: Array[BotBrain.Threat] = sight.find(1000)
	if not assert_eq(found.size(), 1, "active from the telegraph"):
		return
	assert_vec_near(found[0].origin, Vector3(1.0, 2.0, 3.0), 0.001, "with the telegraph's origin")
	assert_near(found[0].yaw, PI, 0.001, "its turn")
	assert_near(found[0].radius, 3.5, 0.001, "and its reach in meters")
	var last: int = 1000 + 60 + BotThreatSight.ACTIVE_TICKS
	assert_eq(sight.find(last).size(), 1, "continues until the impact plus the active window")
	assert_eq(sight.find(last + 1).size(), 0, "and afterward it does not")
	assert_eq(sight.size(), 0, "forgets it as it passes")


func test_the_same_npc_replaces_its_warning_and_a_despawn_forgets_it() -> void:
	var sight := BotThreatSight.new()
	sight.note(_telegraph(40, 1000, Vector3.ZERO, 0.0, 350, 60))
	sight.note(_telegraph(41, 1010, Vector3(5.0, 0.0, 0.0), 0.0, 260, 30))
	assert_eq(sight.find(1020).size(), 2, "two NPCs, two hits")
	sight.note(_telegraph(40, 1100, Vector3(9.0, 0.0, 0.0), 1.0, 350, 60))
	var found: Array[BotBrain.Threat] = sight.find(1100)
	assert_eq(found.size(), 1, "the other has already passed and the first has a new one")
	assert_vec_near(found[0].origin, Vector3(9.0, 0.0, 0.0), 0.001, "the new one replaces the previous one")
	sight.forget(40)
	assert_eq(sight.find(1100).size(), 0, "its DESPAWN forgets it")


func test_other_events_are_ignored() -> void:
	var sight := BotThreatSight.new()
	sight.note(NetMessages.EntityEvent.hit(5, 1000, 6, 90, 0, 0, 3))
	sight.note(NetMessages.EntityEvent.war(5, 1000, WarEvents.GATE_BROKEN, 1))
	sight.note(null)
	assert_eq(sight.find(1000).size(), 0)


func test_with_a_hostility_rule_it_keeps_only_the_hits_of_those_who_can_harm_it() -> void:
	# F6b review: the server telegraphs the forts of all NPCs, including those of the bot's own garrison, and the
	# server's fake ones only avoid those of a hostile realm; the client bots also dodged those of their own side.
	var hostile: Dictionary[int, bool] = {41: true}
	var sight := BotThreatSight.new(func(net_id: int) -> bool: return hostile.has(net_id))
	sight.note(_telegraph(40, 1000, Vector3.ZERO, 0.0, 350, 60))
	sight.note(_telegraph(41, 1000, Vector3(5.0, 0.0, 0.0), 0.0, 350, 60))
	var found: Array[BotBrain.Threat] = sight.find(1000)
	if not assert_eq(found.size(), 1, "only that of the NPC that can damage it"):
		return
	assert_vec_near(found[0].origin, Vector3(5.0, 0.0, 0.0), 0.001)


func test_a_remote_npc_is_hostile_by_the_faction_rules_of_the_zone() -> void:
	var world := RemoteWorld.new()
	world.install_visuals = false
	world.setup(InterpolationClock.new())
	tree.root.add_child(world)
	world.on_spawn(_npc_spawn(40, NetProtocol.Realm.VARDHEIM))
	world.on_spawn(_npc_spawn(41, NetProtocol.Realm.SOLMARCH))
	world.on_spawn(_npc_spawn(42, RealmCatalog.NEUTRAL_CODE))
	var zone: StringName = &"vado_gris"
	var vardheim: int = NetProtocol.Realm.VARDHEIM
	assert_false(BotThreatSight.is_hostile_view(world, vardheim, zone, 40), "a guard of its realm does not damage it")
	assert_true(BotThreatSight.is_hostile_view(world, vardheim, zone, 41), "one from the other realm does")
	assert_true(BotThreatSight.is_hostile_view(world, vardheim, zone, 42), "and a neutral one (the Hollow, the Ford Captain)")
	assert_false(BotThreatSight.is_hostile_view(world, vardheim, zone, 99), "one with no registration does not count")
	assert_false(BotThreatSight.is_hostile_view(null, vardheim, zone, 41), "with no world, nothing")
	tree.root.remove_child(world)
	world.free()
	await wait_process_frames()


func test_a_swarm_bot_does_not_evade_the_hits_of_the_npcs_of_its_realm() -> void:
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.SWARM
	config.bot_count = 1
	config.bot_brain = ClientConfig.BOT_BRAIN_SIEGE
	config.realm = NetProtocol.Realm.VARDHEIM
	config.port = 1
	var bot := SwarmBot.new()
	tree.root.add_child(bot)
	bot.setup(0, config)
	var welcome := NetMessages.Welcome.new()
	welcome.realm = NetProtocol.Realm.VARDHEIM
	welcome.zone_id = "vado_gris"
	bot._welcome = welcome
	bot._predicted_tick = 1000
	# A Vardheim guard (its garrison) and a Hollow (neutral), with their real registrations.
	bot._on_packet_received(SwarmBot.SERVER_PEER_ID, _npc_spawn(40, NetProtocol.Realm.VARDHEIM).encode())
	bot._on_packet_received(SwarmBot.SERVER_PEER_ID, _npc_spawn(41, RealmCatalog.NEUTRAL_CODE).encode())
	bot._on_packet_received(SwarmBot.SERVER_PEER_ID, _telegraph(40, 1000, Vector3.ZERO, 0.0, 350, 60).encode())
	var own: int = bot._find_threats(Vector3.ZERO).size()
	bot._on_packet_received(SwarmBot.SERVER_PEER_ID,
			_telegraph(41, 1000, Vector3(3.0, 0.0, 0.0), 0.0, 350, 60).encode())
	var found: Array[BotBrain.Threat] = bot._find_threats(Vector3.ZERO)
	tree.root.remove_child(bot)
	bot.free()
	await wait_process_frames()
	assert_eq(own, 0, "the telegraphed hit of a guard of its realm is not a threat")
	if assert_eq(found.size(), 1, "the Hollow's is"):
		assert_vec_near(found[0].origin, Vector3(3.0, 0.0, 0.0), 0.001)


func _npc_spawn(net_id: int, realm: int) -> NetMessages.EntitySpawn:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = NetProtocol.EntityKind.NPC
	spawn.spawn_tick = 900
	spawn.realm = realm
	spawn.display_name = "Guardia"
	spawn.npc_def_id = 3
	spawn.state = PlayerState.new()
	return spawn
