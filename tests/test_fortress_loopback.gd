extends TestCase
## Un cliente de verdad ([NetClient] en modo bot) ve el fuerte por ENet en 127.0.0.1 (paquete F3): el
## SPAWN de la fortaleza al entrar, los OBJECT_STATE y los avisos WAR de una captura completa (neutral ->
## Vardheim) que hacen jugadores falsos del servidor, y el marcador cada 2 s, sin un solo paquete mal
## formado. Complementa a [code]test_fortress_net.gd[/code], cuyos clientes hablan el protocolo a mano.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const FORTRESS: StringName = FortressFixture.FORTRESS_ID
const WAIT_FRAMES: int = 900

var _root: Node
var _server_viewport: SubViewport
var _client_viewport: SubViewport
var _server: ZoneServer
var _client: NetClient
var _port: int = 0


func before_each() -> void:
	_root = Node.new()
	_root.name = "FortressLoopback"
	tree.root.add_child(_root)


func after_each() -> void:
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
	await wait_process_frames()


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func test_a_bot_client_sees_a_full_capture_as_object_states_and_war_events() -> void:
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
	# El cliente carga la misma zona (con la fortaleza) y se conecta como bot de Solmarch.
	_client_viewport = NetHarness.make_world_viewport(_root, "")
	var client_world: Node3D = NetHarness.get_world(_client_viewport)
	FortressFixture.add_fortress(client_world, FortressFixture.make_definition())
	_client = NetHarness.start_bot(_client_viewport, _port, NetProtocol.Realm.SOLMARCH, 7)
	var in_world: bool = await _wait_until(func() -> bool:
		return _client.get_state() == NetClient.State.IN_WORLD)
	if not assert_true(in_world, "el bot entra en el mundo"):
		return
	var spawned: bool = await _wait_until(func() -> bool:
		return int(_client.get_stats()["structure_spawns"]) >= 1)
	assert_true(spawned, "recibe el SPAWN de la fortaleza al entrar")
	# La captura la hace un jugador falso de Vardheim, tras matar al capitán de los Huecos.
	_server.spawn_captain_double(FORTRESS)
	var attacker: int = _server.add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM)
	_server.teleport(attacker, FortressFixture.circle_center())
	await wait_physics_frames(20)
	_server.console_command("fort_kill_captain")
	var captured: bool = await _wait_until(func() -> bool:
		return _server.get_fortresses().get_fortress_state(FORTRESS).owner == VARDHEIM)
	assert_true(captured, "el fuerte pasa a Vardheim")
	var told: bool = await _wait_until(func() -> bool:
		return int(_client.get_stats()["war_events"]) >= 3)
	assert_true(told, "el cliente recibe los tres avisos de la captura")
	var stats: Dictionary = _client.get_stats()
	assert_eq(int(stats["war_events"]), 3, "capitán caído, captura iniciada y fuerte capturado")
	assert_true(int(stats["object_states"]) >= 3, "y los OBJECT_STATE de la presencia, la captura y el dueño")
	assert_eq(int(stats["structure_spawns"]), 1)
	assert_eq(int(stats["malformed_packets"]), 0, "ni un paquete mal formado")
	# El marcador llega cada 2 s.
	var board: bool = await _wait_until(func() -> bool:
		return int(_client.get_stats()["scoreboards"]) >= 2, 600)
	assert_true(board, "el marcador de la zona")
	assert_eq(int(_client.get_stats()["malformed_packets"]), 0)
