extends TestCase
## Los clientes que asedian (GUE-15; docs/fuerte.md, sección 7) contra un servidor de verdad por ENet en
## 127.0.0.1:
## [br]- los [SwarmBot] de [code]--bots=N --bot-brain=siege[/code], que no cargan la zona ni simulan: llenan su
## [SiegeView] decodificando a mano el alta de la fortaleza y cada OBJECT_STATE, llegan a la puerta (el servidor
## simula sus pasos por el Vado Gris de verdad), la rompen, entran en el círculo y capturan el fuerte;
## [br]- el bot de [code]--bot --bot-brain=siege[/code] ([NetClient] que predice), cuyo [SiegeView] llena
## [FortressView] (ClientBotBrains).
## Para que dure segundos, la prueba recorta la vida de la puerta y coloca a los bots delante de ella: el viaje
## de campamento a puerta, con los dos caminos, lo mide [code]test_siege_zone[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const SWARM_SCENE: String = "res://scenes/client/bot_swarm.tscn"
const WAIT_FRAMES: int = 1200

var _root: Node
var _server_viewport: SubViewport
var _client_viewport: SubViewport
var _server: ZoneServer
var _swarm: BotSwarm
var _client: NetClient
var _port: int = 0
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_max_fps: int = 0


func before_each() -> void:
	_saved_config = BotSwarm.config
	_saved_hook = BotSwarm.quit_hook
	_saved_max_fps = Engine.max_fps
	BotSwarm.quit_hook = func(_code: int) -> void: pass
	_root = Node.new()
	_root.name = "SiegeClients"
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_swarm):
		_swarm.get_parent().remove_child(_swarm)
		_swarm.free()
	_swarm = null
	if is_instance_valid(_client_viewport):
		_client_viewport.free()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_client_viewport = null
	_server_viewport = null
	_server = null
	_client = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	BotSwarm.config = _saved_config
	BotSwarm.quit_hook = _saved_hook
	Engine.max_fps = _saved_max_fps
	await wait_process_frames(2)


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _state() -> FortressState:
	return _server.get_fortresses().get_fortress_state(_server.get_fortresses().get_fortress_ids()[0])


func test_swarm_bots_read_the_fort_from_object_states_break_the_gate_and_capture() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, NetZones.scene_path("vado_gris"))
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = "vado_gris"
	config.max_players = 8
	config.no_dummies = true
	# Sin los PNJ de F4: aquí se prueba solo cómo leen el fuerte los SwarmBot (con los Huecos en el patio
	# pelearían en el círculo en vez de quedarse); el asedio con PNJ es de F6b.
	config.no_npcs = true
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	if not assert_not_null(_server, "el servidor arranca sobre el Vado Gris"):
		return
	var client_config := ClientConfig.new()
	client_config.mode = ClientConfig.Mode.SWARM
	client_config.port = _port
	client_config.bot_count = 3
	client_config.bot_seed = 520
	client_config.realm = VARDHEIM
	client_config.bot_brain = ClientConfig.BOT_BRAIN_SIEGE
	BotSwarm.config = client_config
	_swarm = (load(SWARM_SCENE) as PackedScene).instantiate() as BotSwarm
	_root.add_child(_swarm)
	var all_in: bool = await _wait_until(func() -> bool: return _swarm.count_in_world() == 3)
	if not assert_true(all_in, "entran los tres (%d)" % _swarm.count_in_world()):
		return
	var bots: Array[SwarmBot] = _swarm.get_bots()
	# El alta de la fortaleza llega al entrar y llena el SiegeView (con los campos completos).
	var known: bool = await _wait_until(func() -> bool:
		for bot: SwarmBot in bots:
			if not bot.get_siege_view().known:
				return false
		return true)
	if not assert_true(known, "los tres conocen el fuerte por su ENTITY_SPAWN"):
		return
	for bot: SwarmBot in bots:
		var view: SiegeView = bot.get_siege_view()
		assert_eq(view.owner, 0, "neutral")
		assert_eq(view.gate_max, 9000, "con la vida de la puerta")
		assert_false(view.is_gate_broken())
		assert_true(view.circle_radius > 0.0, "y sabe dónde está (las rutas de la zona)")
		assert_eq(bot.get_brain().get_pattern(), BotBrain.Pattern.SIEGE)
		assert_true(bot.get_brain().has_siege())
	# La puerta se queda en 600 de vida (llega como OBJECT_STATE) y los bots empiezan en la explanada.
	_state().gate_health = 600
	var ground: float = _server.get_fortresses().get_gate(_server.get_fortresses().get_fortress_ids()[0]).global_position.y
	for i: int in 3:
		_server.teleport(bots[i].get_net_id(), Vector3(-25.0, ground + 0.4, -2.0 + 2.0 * float(i)))
	var broken: bool = await _wait_until(func() -> bool: return _state().is_gate_broken())
	if not assert_true(broken, "tres bots rompen la puerta a golpes (vida %d)" % _state().gate_health):
		return
	# El cliente se entera por un OBJECT_STATE y entra en el círculo.
	var told: bool = await _wait_until(func() -> bool: return bots[0].get_siege_view().is_gate_broken())
	assert_true(told, "el SiegeView de un bot sabe que la puerta está rota (solo por OBJECT_STATE)")
	var inside: bool = await _wait_until(func() -> bool: return _state().presence[VARDHEIM] == 3)
	if not assert_true(inside, "los tres entran en el círculo (%d)" % _state().presence[VARDHEIM]):
		return
	assert_eq(String(bots[0].get_stats()["siege_task"]), "HOLD", "y se quedan en él")
	assert_true(int(bots[0].get_stats()["object_states_applied"]) >= 2, "tras aplicar varios OBJECT_STATE")
	# Cae el capitán y capturan.
	_server.console_command("fort_capture_speed 30")
	assert_true(_server.console_command("fort_kill_captain").contains("ha muerto"))
	var captured: bool = await _wait_until(func() -> bool: return _state().owner == VARDHEIM)
	assert_true(captured, "Vardheim captura el fuerte (fase %d)" % _state().phase)
	var owner_told: bool = await _wait_until(func() -> bool: return bots[1].get_siege_view().owner == VARDHEIM)
	assert_true(owner_told, "y los bots saben que ahora es suyo")
	assert_eq(int(bots[2].get_stats()["malformed_packets"]), 0, "sin paquetes mal formados")


func test_a_predicting_bot_with_the_siege_brain_follows_the_fort_through_fortress_view() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var server_world: Node3D = NetHarness.get_world(_server_viewport)
	FortressFixture.add_fortress(server_world, FortressFixture.make_definition())
	FortressFixture.add_respawn_points(server_world)
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = "test_world"
	config.max_players = 8
	config.no_dummies = true
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	if not assert_not_null(_server, "el servidor arranca"):
		return
	_client_viewport = NetHarness.make_world_viewport(_root, "")
	FortressFixture.add_fortress(NetHarness.get_world(_client_viewport), FortressFixture.make_definition())
	_client = NetHarness.start_bot(_client_viewport, _port, VARDHEIM, 9, "", "", ClientConfig.BOT_BRAIN_SIEGE)
	var in_world: bool = await _wait_until(func() -> bool:
		return _client.get_state() == NetClient.State.IN_WORLD and _client.has_meta(&"bot_brain"))
	if not assert_true(in_world, "el bot entra en el mundo"):
		return
	var brain: BotBrain = _client.get_meta(&"bot_brain") as BotBrain
	assert_eq(brain.get_pattern(), BotBrain.Pattern.SIEGE, "con el cerebro de asedio")
	assert_true(brain.has_siege() and brain.has_enemy_finder())
	var view: SiegeView = brain.get_siege_view()
	var fortress_known: bool = await _wait_until(func() -> bool: return view.known and view.circle_radius > 0.0)
	if not assert_true(fortress_known, "FortressView le da el estado y las posiciones del fuerte"):
		return
	assert_vec_near(view.gate_position, FortressFixture.gate_position(), 0.05, "la puerta de la escena del cliente")
	assert_vec_near(view.circle_center, FortressFixture.circle_center(), 0.05, "y el círculo")
	# Sin rutas para esta zona de pruebas, va derecho: se le coloca delante de la puerta de 200 de vida.
	_state().gate_health = 200
	var net_id: int = _client.get_net_id()
	_server.teleport(net_id, FortressFixture.gate_position() + Vector3(-5.0, 0.3, 0.0))
	var broken: bool = await _wait_until(func() -> bool: return _state().is_gate_broken())
	if not assert_true(broken, "el bot rompe la puerta (vida %d)" % _state().gate_health):
		return
	var told: bool = await _wait_until(func() -> bool: return view.is_gate_broken())
	assert_true(told, "y su SiegeView lo ve por la FortressView")
	var inside: bool = await _wait_until(func() -> bool: return _state().presence[VARDHEIM] == 1)
	assert_true(inside, "entra en el círculo cruzando la puerta rota")
	_server.console_command("fort_capture_speed 30")
	_server.console_command("fort_kill_captain")
	var captured: bool = await _wait_until(func() -> bool: return _state().owner == VARDHEIM)
	assert_true(captured, "y captura el fuerte")
	assert_eq(int(_client.get_stats()["malformed_packets"]), 0, "sin paquetes mal formados")
	assert_eq(int(_client.get_stats()["hard_resets"]), 0, "sin reinicios duros de la predicción")


func test_the_siege_brain_is_a_valid_bot_brain_option() -> void:
	var config: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bots=4", "--bot-brain=Siege"]))
	assert_eq(config.bot_brain, ClientConfig.BOT_BRAIN_SIEGE, "--bot-brain=siege (sin distinguir mayúsculas)")
	assert_eq(config.mode, ClientConfig.Mode.SWARM)
	assert_true(config.warnings.is_empty())
	var bot: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bot", "--bot-brain=siege"]))
	assert_eq(bot.bot_brain, ClientConfig.BOT_BRAIN_SIEGE)
	assert_eq(bot.mode, ClientConfig.Mode.BOT)
	var wrong: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bots=2", "--bot-brain=asediar"]))
	assert_eq(wrong.bot_brain, "", "un cerebro desconocido se ignora con un aviso")
	assert_false(wrong.warnings.is_empty())
