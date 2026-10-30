extends TestCase
## Pruebas de [ProjectileWorld] (docs/habilidades.md, secciones 6.2 y 7.3, H4) sin servidor: los SPAWN y
## DESPAWN de las flechas son mensajes sintéticos, como en test_net_client.gd.
## [br]- La flecha predicha se sustituye por la del servidor (misma fuente e índice, tick a menos del búfer)
## sin saltos: el desfase visual decae en 6 ticks.
## [br]- Dos pasos de predicción en un mismo tick de física con el compromiso en el primero: la flecha sale
## (con [signal ClientPrediction.stepped]; mirar el estado una vez por tick de física la perdería).
## [br]- Un SPAWN de flecha propia con el jugador ya en el mundo pasa por [NetClient] al [ProjectileWorld]
## sin tocar al personaje local; sin pareja se dibuja la del servidor.
## [br]- La remota aparece en su [code]render_tick[/code] y se retira en [code]despawn_tick + f[/code] (en el
## muro) o en [code]despawn_tick[/code] si caduca.
## [br]- La propia se clava en el mundo, se oculta en la cápsula dibujada de un enemigo y, sin SPAWN, se
## retira en [code]rtt + 30[/code] ticks.

const OWN_ID: int = 5
const ENEMY_ID: int = 77
const ZONE: StringName = &"test_world"
const RTT_TICKS: int = 10
const SHOT_TICK: int = 200
## Muro (plano z = WALL_Z, de 1 m de grueso) delante del tirador, que mira hacia −Z.
const WALL_Z: float = -20.0

var _nodes: Array[Node] = []
var _pair: PredictionPair = null


func after_each() -> void:
	if _pair != null:
		_pair.free_worlds()
		_pair = null
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


# --- Montaje ------------------------------------------------------------------------------------

## Mundo de física propio (suelo y, si se pide, el muro) con un [ProjectileWorld] dentro y un [RemoteWorld]
## fuera del árbol. Hay que esperar un par de fotogramas de física antes de lanzar rayos.
func _make_world(with_wall: bool) -> ProjectileWorld:
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	tree.root.add_child(viewport)
	_nodes.append(viewport)
	_add_box(viewport, Vector3(0.0, -0.5, 0.0), Vector3(400.0, 1.0, 400.0))
	if with_wall:
		_add_box(viewport, Vector3(0.0, 5.0, WALL_Z), Vector3(40.0, 10.0, 1.0))
	var remote := RemoteWorld.new()
	remote.install_visuals = false
	remote.setup(InterpolationClock.new())
	_nodes.append(remote)
	var world := ProjectileWorld.new()
	world.install_visuals = false
	world.setup(InterpolationClock.new(), remote)
	viewport.add_child(world)
	world.set_local(OWN_ID, NetProtocol.Realm.VARDHEIM, ZONE, null, null, RTT_TICKS)
	return world


func _add_box(parent: Node, center: Vector3, box_size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = box_size
	shape.shape = box
	body.add_child(shape)
	body.position = center
	parent.add_child(body)


## Estado en el compromiso del disparo rápido del arco en [param tick] con los pies en [param feet].
func _quick_shot_state(tick: int, feet: Vector3) -> PlayerState:
	var quick: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"bow_quick"))
	var state := PlayerState.new()
	state.position = feet
	state.grounded = true
	state.combat = CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"bow"))
	state.combat.action = CombatState.Action.LIGHT
	state.combat.action_id = quick.id
	state.combat.action_tick = tick - quick.windup_ticks
	return state


func _look_input(tick: int, yaw: float = 0.0, pitch: float = 0.0) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	input.look_pitch = pitch
	return input


func _arrow_spawn(net_id: int, tick: int, owner: int, realm: int, source: int, p0: Vector3,
		v0: Vector3, index: int = 0) -> NetMessages.EntitySpawn:
	var quantized: Array = Ballistics.quantize(p0, v0)
	return NetMessages.EntitySpawn.for_projectile(net_id, tick, realm, owner,
			CombatCatalog.projectile_id(&"arrow"), source, index, false, quantized[0], quantized[1])


func _quick_source() -> int:
	return CombatSource.make(CombatSource.Kind.ATTACK, CombatCatalog.attack_id(&"bow_quick"))


# --- Pruebas ------------------------------------------------------------------------------------

func test_the_predicted_arrow_is_replaced_by_the_servers_without_a_jump() -> void:
	var world: ProjectileWorld = _make_world(false)
	await wait_physics_frames(2)
	var state: PlayerState = _quick_shot_state(SHOT_TICK, Vector3.ZERO)
	world.on_stepped(SHOT_TICK, _look_input(SHOT_TICK), state)
	assert_eq(world.get_stats()["predicted"], 1, "el compromiso del disparo rápido crea la flecha predicha")
	var predicted: ProjectileWorld.Arrow = world.get_arrows()[0]
	assert_eq(predicted.spawn_tick, SHOT_TICK)
	assert_eq(predicted.source, _quick_source(), "con la fuente del ataque")
	assert_false(predicted.confirmed)
	# La misma balística que calcula ProjectileLaunch, ya cuantizada como viaja.
	var launch: ProjectileLaunch = ProjectileLaunch.from_state(state.combat, SHOT_TICK)
	var shots: Array[PackedVector3Array] = launch.launch(Vector3.ZERO, 0.0, 0.0, false, null,
			PackedVector3Array())
	assert_vec_near(predicted.p0, shots[0][0], 0.0001, "sale del pecho")
	assert_vec_near(predicted.v0, shots[0][1], 0.0001, "hacia la mira a 45 m/s")
	assert_near(predicted.v0.length(), 45.0, 0.02)
	world.draw(SHOT_TICK + 3.0, 0.0)
	var before: Vector3 = predicted.drawn_position
	assert_vec_near(before, predicted.position_at(3.0), 0.0001, "se dibuja en el tiempo predicho")
	# El servidor la dispara dos ticks después (su entrada llegó más tarde) y algo desplazada.
	var server_p0: Vector3 = predicted.p0 + Vector3(0.06, 0.0, 0.0)
	world.on_spawn(_arrow_spawn(700, SHOT_TICK + 2, OWN_ID, NetProtocol.Realm.VARDHEIM, _quick_source(),
			server_p0, predicted.v0))
	assert_eq(world.get_stats()["substituted"], 1, "se empareja con la predicha")
	assert_eq(world.get_live_count(), 1, "y no hay dos flechas")
	var arrow: ProjectileWorld.Arrow = world.find_arrow(700)
	if not assert_not_null(arrow, "la predicha adopta el id del servidor"):
		return
	assert_true(arrow.confirmed)
	assert_eq(arrow.spawn_tick, SHOT_TICK + 2, "y su tick")
	world.draw(SHOT_TICK + 3.0, 0.0)
	assert_vec_near(arrow.drawn_position, before, 0.001, "en el instante de la sustitución no salta")
	world.draw(SHOT_TICK + 6.0, 0.0)
	assert_true(arrow.offset_at(SHOT_TICK + 6.0).length() > 0.0, "el desfase aún decae")
	world.draw(SHOT_TICK + 9.5, 0.0)
	assert_vec_near(arrow.drawn_position, arrow.position_at(9.5 - 2.0), 0.0001,
			"6 ticks después va por la trayectoria del servidor")
	# DESPAWN 5 (caducada): se retira en su tick.
	world.on_despawn(700, SHOT_TICK + 40, NetProtocol.DespawnReason.EXPIRED)
	world.draw(SHOT_TICK + 39.9, 0.0)
	assert_eq(world.get_live_count(), 1)
	world.draw(SHOT_TICK + 40.0, 0.0)
	assert_eq(world.get_live_count(), 0, "caducada, se retira en despawn_tick")


func test_two_prediction_steps_in_one_physics_tick_still_fire_the_arrow() -> void:
	var quick: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"bow_quick"))
	const PRESS_TICK: int = 40
	var commit: int = PRESS_TICK + quick.windup_ticks
	_pair = PredictionPair.new()
	var route := func(tick: int) -> PlayerInput:
		var input: PlayerInput = _look_input(tick)
		if tick == PRESS_TICK:
			input.buttons = PlayerInput.PRIMARY
		return input
	var combat: CombatState = CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"bow"),
			CombatCatalog.weapon_id(&"sword_shield"), CombatState.pack_charges(2, 3))
	await _pair.build(tree, route, combat)
	var world := ProjectileWorld.new()
	world.install_visuals = false
	_nodes.append(world)
	world.setup(InterpolationClock.new(), null)
	world.set_local(OWN_ID, NetProtocol.Realm.VARDHEIM, ZONE, _pair.client, _pair.prediction, RTT_TICKS)
	while _pair.prediction.get_predicted_tick() < commit - 1:
		await tree.physics_frame
		_pair.frame()
	assert_eq(_pair.predicted(PRESS_TICK).combat.action, CombatState.Action.LIGHT,
			"el toque empieza el disparo rápido")
	assert_eq(world.get_stats()["predicted"], 0, "aún no ha salido nada")
	# Un tick de física con dos pasos (TickSync recupera antelación): el compromiso cae en el primero.
	await tree.physics_frame
	_pair.frame()
	_pair.prediction.step()
	var last: PlayerState = _pair.predicted(_pair.prediction.get_predicted_tick())
	assert_eq(_pair.prediction.get_predicted_tick(), commit + 1)
	assert_false(ActionMachine.is_commit_tick(last.combat, commit + 1),
			"el estado al final del tick de física ya no es el compromiso (mirarlo así la perdería)")
	assert_eq(world.get_stats()["predicted"], 1, "pero la flecha sale, del paso de en medio")
	var arrow: ProjectileWorld.Arrow = world.get_arrows()[0]
	assert_eq(arrow.spawn_tick, commit, "en el tick del compromiso")
	assert_eq(arrow.source, _quick_source())
	assert_vec_near(arrow.p0, AimRay.muzzle(_pair.predicted(commit).position), 0.011,
			"desde el pecho del personaje en ese tick")
	world.set_local(OWN_ID, NetProtocol.Realm.VARDHEIM, ZONE, null, null, RTT_TICKS)


func test_an_own_arrow_spawn_with_the_player_in_the_world_reaches_the_projectile_world() -> void:
	var client := NetClient.new()
	tree.root.add_child(client)
	_nodes.append(client)
	# Jugador ya en el mundo (como tras su SPAWN propio).
	client._net_id = OWN_ID
	client._state = NetClient.State.IN_WORLD
	var world: ProjectileWorld = client.get_projectile_world()
	world.install_visuals = false
	world.set_local(OWN_ID, NetProtocol.Realm.VARDHEIM, ZONE, null, null, RTT_TICKS)
	var spawned: Array[NetMessages.EntitySpawn] = []
	client.projectile_spawned.connect(func(spawn: NetMessages.EntitySpawn) -> void: spawned.append(spawn))
	var state: PlayerState = _quick_shot_state(SHOT_TICK, Vector3.ZERO)
	world.on_stepped(SHOT_TICK, _look_input(SHOT_TICK), state)
	var predicted: ProjectileWorld.Arrow = world.get_arrows()[0]
	# El SPAWN de la flecha propia llega por la red: is_yours va a 0 y «propia» es el owner.
	var spawn: NetMessages.EntitySpawn = _arrow_spawn(901, SHOT_TICK + 1, OWN_ID,
			NetProtocol.Realm.VARDHEIM, _quick_source(), predicted.p0, predicted.v0)
	client._on_packet_received(NetClient.SERVER_PEER_ID, spawn.encode())
	assert_eq(spawned.size(), 1, "sale por su señal")
	assert_null(client.get_character(), "no crea ningún personaje local")
	assert_eq(client.get_state(), NetClient.State.IN_WORLD)
	assert_eq(world.get_stats()["substituted"], 1, "sustituye a la predicha")
	assert_eq(world.find_arrow(901), predicted)
	# Otra propia sin predicha (el cliente no llegó a predecirla): se dibuja la del servidor, en el tiempo
	# predicho.
	var orphan: NetMessages.EntitySpawn = _arrow_spawn(902, SHOT_TICK + 30, OWN_ID,
			NetProtocol.Realm.VARDHEIM, _quick_source(), Vector3(0.0, 1.4, 0.0), Vector3(0.0, 0.0, -45.0))
	client._on_packet_received(NetClient.SERVER_PEER_ID, orphan.encode())
	assert_eq(world.get_stats()["own_from_server"], 1)
	var own: ProjectileWorld.Arrow = world.find_arrow(902)
	assert_true(own.predicted and own.confirmed, "se dibuja como propia")
	world.draw(SHOT_TICK + 32.0, 50.0)
	assert_vec_near(own.drawn_position, own.position_at(2.0), 0.0001, "en el tiempo predicho, no en el de dibujo")
	# Su DESPAWN también llega al mundo de flechas.
	client._on_packet_received(NetClient.SERVER_PEER_ID,
			_despawn(902, SHOT_TICK + 31, NetProtocol.DespawnReason.EXPIRED).encode())
	world.draw(SHOT_TICK + 32.0, 50.0)
	assert_null(world.find_arrow(902), "y se retira")
	assert_eq(client.get_stats()["malformed_packets"], 0)


func test_a_remote_arrow_appears_at_its_render_tick_and_leaves_at_despawn_plus_fraction() -> void:
	var world: ProjectileWorld = _make_world(true)
	await wait_physics_frames(3)
	# A 40 m/s recorre 2/3 m por tick: el segmento 29 ([−19,33; −20,0]) cruza la cara del muro (z = −19,5)
	# a un cuarto.
	var p0 := Vector3(0.0, 1.4, 0.0)
	var v0 := Vector3(0.0, 0.0, -40.0)
	world.on_spawn(_arrow_spawn(801, 100, ENEMY_ID, NetProtocol.Realm.SOLMARCH, _quick_source(), p0, v0))
	assert_eq(world.get_stats()["remote"], 1)
	var arrow: ProjectileWorld.Arrow = world.find_arrow(801)
	assert_false(arrow.predicted, "una flecha ajena va en el tiempo de dibujo")
	world.draw(500.0, 99.5)
	assert_false(arrow.visible, "antes de su spawn_tick no se ve")
	world.draw(500.0, 100.25)
	assert_true(arrow.visible, "en su tick, sí")
	assert_vec_near(arrow.drawn_position, Ballistics.position(arrow.p0, arrow.v0, arrow.gravity, 0.25),
			0.0001, "en pos(render_tick + fracción − spawn_tick)")
	world.draw(500.0, 120.0)
	assert_true(arrow.drawn_position.z > WALL_Z, "vuela hacia el muro")
	# El servidor dice que dio en el muro en el tick 129 (segmento 29).
	world.on_despawn(801, 129, NetProtocol.DespawnReason.IMPACT)
	assert_near(arrow.end_n, 29.25, 0.01, "la fracción de su propio rayo en el último segmento")
	world.draw(500.0, 129.2)
	assert_eq(world.get_live_count(), 1, "todavía no ha llegado al muro")
	assert_near(arrow.drawn_position.z, -19.47, 0.02, "casi en la cara del muro")
	world.draw(500.0, 129.3)
	assert_eq(world.get_live_count(), 0, "se retira al llegar: despawn_tick + f")
	# Sin nada en el último segmento, f = 1; y una caducada se retira en su despawn_tick.
	world.on_spawn(_arrow_spawn(802, 200, ENEMY_ID, NetProtocol.Realm.SOLMARCH, _quick_source(),
			Vector3(0.0, 1.4, 0.0), Vector3(0.0, 5.0, 40.0)))
	world.on_despawn(802, 210, NetProtocol.DespawnReason.IMPACT)
	assert_near(world.find_arrow(802).end_n, 11.0, 0.0001, "sin nada que tocar, al final del segmento")
	world.on_spawn(_arrow_spawn(803, 200, ENEMY_ID, NetProtocol.Realm.SOLMARCH, _quick_source(),
			Vector3(0.0, 1.4, 0.0), Vector3(0.0, 5.0, 40.0)))
	world.on_despawn(803, 260, NetProtocol.DespawnReason.EXPIRED)
	world.draw(500.0, 259.9)
	assert_not_null(world.find_arrow(803))
	world.draw(500.0, 260.0)
	assert_null(world.find_arrow(803), "caducada: en despawn_tick")


func test_an_own_arrow_sticks_in_the_wall_hides_in_an_enemy_and_is_retired_without_a_spawn() -> void:
	var world: ProjectileWorld = _make_world(true)
	await wait_physics_frames(3)
	# Al muro: mirando a −Z, la mira da en el muro y la flecha se clava en él.
	world.on_stepped(SHOT_TICK, _look_input(SHOT_TICK), _quick_shot_state(SHOT_TICK, Vector3.ZERO))
	var arrow: ProjectileWorld.Arrow = world.get_arrows()[0]
	world.draw(SHOT_TICK + 35.0, 0.0)
	assert_true(arrow.stuck_n > 0.0, "se clava en el muro con su propio rayo (n = %.2f)" % arrow.stuck_n)
	assert_near(arrow.drawn_position.z, WALL_Z + 0.5, 0.05, "en la cara del muro")
	world.draw(SHOT_TICK + 38.0, 0.0)
	assert_near(arrow.drawn_position.z, WALL_Z + 0.5, 0.05, "y ahí se queda")
	assert_eq(world.get_stats()["stuck"], 1)
	# Sin SPAWN en rtt + 30 ticks: el servidor la rechazó.
	world.draw(float(SHOT_TICK + RTT_TICKS + ProjectileWorld.REJECT_EXTRA_TICKS) + 0.5, 0.0)
	assert_eq(world.get_live_count(), 0, "una predicha sin SPAWN se retira")
	assert_eq(world.get_stats()["rejected"], 1)
	# A un enemigo dibujado a 10 m: la flecha se oculta al tocar su cápsula (sin número: lo da el HIT).
	var remote: RemoteWorld = world._remote_world
	remote.on_spawn(_enemy_spawn(ENEMY_ID, Vector3(0.0, 0.0, -10.0)))
	remote.draw(50.0, 0.0)
	assert_true(remote.get_view(ENEMY_ID).is_drawn())
	# La mira, sobre su centro (la cámara va 0,6 m a la derecha: mirar al frente pasaría a su lado).
	var look: Vector2 = AimRay.look_for(Vector3.ZERO, Vector3(0.0, 0.9, -10.0), false)
	world.on_stepped(SHOT_TICK + 100, _look_input(SHOT_TICK + 100, look.x, look.y),
			_quick_shot_state(SHOT_TICK + 100, Vector3.ZERO))
	var hidden: ProjectileWorld.Arrow = world.get_arrows()[0]
	world.draw(SHOT_TICK + 100.0 + 8.0, 0.0)
	assert_true(hidden.visible, "antes de llegar se ve")
	world.draw(SHOT_TICK + 100.0 + 16.0, 0.0)
	assert_false(hidden.visible, "al tocar la cápsula del enemigo se oculta")
	assert_true(hidden.hidden_n > 11.0 and hidden.hidden_n < 14.0,
			"a unos 9,6 m (n = %.2f)" % hidden.hidden_n)
	assert_eq(world.get_stats()["hidden"], 1)


func _enemy_spawn(net_id: int, feet: Vector3) -> NetMessages.EntitySpawn:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = NetProtocol.EntityKind.PLAYER
	spawn.spawn_tick = 10
	spawn.realm = NetProtocol.Realm.SOLMARCH
	spawn.display_name = "Bruno"
	var state := PlayerState.new()
	state.position = feet
	state.grounded = true
	spawn.state = state
	return spawn


func _despawn(net_id: int, tick: int, reason: int) -> NetMessages.EntityDespawn:
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = net_id
	despawn.despawn_tick = tick
	despawn.reason = reason
	return despawn
