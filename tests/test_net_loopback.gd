extends TestCase
## Integración de la red en un solo proceso, con ENet real sobre 127.0.0.1 (docs/red.md, sección 16,
## «Integración en un proceso»; hitos M2 y M3).
## [br][br]
## Un [ZoneServer] y varios [NetClient] bots, cada uno en su [SubViewport] con su propio mundo de
## física y su propio [NetTransport] (con su [SceneMultiplayer]). La zona es el suelo plano de
## [ZoneFixture], para que cada prueba dure menos de 30 s. Un método por escenario:
## [br]- a) handshake correcto, y REJECT por versión, reino y huella de la simulación;
## [br]- b) SPAWN y DESPAWN al conectar y desconectar (CLIENT_LEAVE y corte);
## [br]- c) sin simulador de red: 0 correcciones a partir del tick 60, y cada bot dibuja a los demás
## a menos de 0,5 m de [method StateHistory.sample] en su tick de dibujo;
## [br]- e) DEBUG_COMMAND de teletransporte: el cliente salta sin suavizado y queda exacto.
## [br]El escenario d (con [NetSim]: pérdida, jitter y retardo) lo añade el paquete de condiciones
## reales. El ejecutor falla ante cualquier error del motor, así que todas las pruebas comprueban
## también que no se envía nada antes de [signal NetTransport.peer_connected] ni se registra nada
## raro al conectar, rechazar o cortar.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
## Fotogramas de física como mucho que se espera a una condición (10 s).
const WAIT_FRAMES: int = 600

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _port: int = 0
var _clients: Array[NetClient] = []
var _client_viewports: Array[SubViewport] = []


func before_each() -> void:
	_root = Node.new()
	_root.name = "NetLoopback"
	tree.root.add_child(_root)


func after_each() -> void:
	# Primero los clientes (cierran su transporte), después el servidor.
	for viewport: SubViewport in _client_viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_client_viewports.clear()
	_clients.clear()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

## Servidor con la zona plana escuchando en un puerto libre. [param configure] recibe el
## [ServerConfig] antes de arrancar.
func _start_server(configure: Callable = Callable()) -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	if configure.is_valid():
		configure.call(config)
	_server = NetHarness.start_server(_server_viewport, config)
	# Los cuerpos de colisión entran en el espacio de física en los primeros pasos.
	await wait_physics_frames(3)


func _add_bot(realm: int, bot_seed: int, net_sim_spec: String = "") -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
	_client_viewports.append(viewport)
	var client: NetClient = NetHarness.start_bot(viewport, _port, realm, bot_seed, net_sim_spec)
	_clients.append(client)
	return client


## Espera, fotograma de física a fotograma de física, a que se cumpla [param condition].
func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _all_in_world() -> bool:
	for client: NetClient in _clients:
		if client.get_state() != NetClient.State.IN_WORLD:
			return false
	return true


## Cuántos remotos dibuja cada cliente.
func _all_see_the_others() -> bool:
	for client: NetClient in _clients:
		if client.get_remote_world().get_view_count() != _clients.size() - 1:
			return false
	return true


## Posición del servidor del jugador con ese net_id (infinita si no existe).
func _server_position(net_id: int) -> Vector3:
	var entity: NetEntity = _server.get_registry().get_entity(net_id)
	if entity == null:
		return Vector3(INF, INF, INF)
	return entity.get_position()


# --- a) Handshake -----------------------------------------------------------------------------

func test_a_handshake_brings_the_player_into_the_world() -> void:
	await _start_server()
	var client: NetClient = _add_bot(VARDHEIM, 1)
	var welcomes: Array[NetMessages.Welcome] = []
	client.welcomed.connect(func(welcome: NetMessages.Welcome) -> void: welcomes.append(welcome))
	var spawned: Array[PlayerCharacter] = []
	client.local_spawned.connect(func(character: PlayerCharacter) -> void:
		spawned.append(character))
	assert_true(await _wait_until(_all_in_world), "el bot entra en el mundo")
	assert_eq(welcomes.size(), 1, "welcomed se emite una vez")
	assert_eq(spawned.size(), 1, "local_spawned se emite una vez")
	assert_eq(welcomes[0].zone_id, ZONE_ID)
	assert_eq(welcomes[0].realm, VARDHEIM)
	assert_eq(welcomes[0].tick_rate, Engine.physics_ticks_per_second)
	assert_eq(_server.get_player_count(), 1)

	var net_id: int = client.get_net_id()
	assert_true(net_id > 0, "el SPAWN propio da el net_id")
	assert_not_null(_server.get_registry().get_entity(net_id), "y el servidor lo conoce")
	assert_true(client.get_character() == spawned[0])
	assert_true(client.get_prediction().is_started())
	assert_eq(client.get_prediction().get_first_real_tick(),
			client.get_spawn_tick() + client.get_rtt_ticks() + TickSync.MIN_TARGET + 1,
			"P0 = S + rtt + margen objetivo + 1")
	assert_false(client.get_controller().auto_step, "la predicción avanza el controlador")
	assert_true(client.get_rtt_ticks() >= 0 and client.get_rtt_ticks() <= 6,
			"el RTT medido en loopback es de pocos ticks (%d)" % client.get_rtt_ticks())
	# Aparece en un punto de su reino, mirando hacia donde mira el punto.
	var spawn_position: Vector3 = ZoneFixture.VARDHEIM_SPAWNS[0]
	assert_vec_near(client.get_character().global_position, spawn_position, 2.0)

	await wait_physics_frames(120)
	var stats: Dictionary = client.get_stats()
	assert_true(stats["snapshots"] > 30, "llegan snapshots: %d" % stats["snapshots"])
	assert_true(stats["matches"] > 20, "y coinciden con la predicción: %d" % stats["matches"])
	assert_eq(stats["malformed_packets"], 0)


func test_a_protocol_version_mismatch_is_rejected() -> void:
	await _start_server()
	var client: NetClient = _add_bot(VARDHEIM, 1)
	client.hello_hook = func(hello: NetMessages.Hello) -> void: hello.protocol_version += 1
	await _expect_rejection(client, NetProtocol.Result.VERSION)


func test_a_simulation_hash_mismatch_is_rejected() -> void:
	await _start_server()
	var client: NetClient = _add_bot(VARDHEIM, 1)
	client.hello_hook = func(hello: NetMessages.Hello) -> void: hello.sim_hash ^= 0x5A5A5A5A
	await _expect_rejection(client, NetProtocol.Result.SIM_HASH)


func test_a_missing_realm_is_rejected() -> void:
	await _start_server()
	var client: NetClient = _add_bot(NetProtocol.Realm.NONE, 1)
	await _expect_rejection(client, NetProtocol.Result.REALM)


## El cliente recibe el REJECT en español, ni entra en el mundo ni deja nada en el servidor, y
## después de rechazado no vuelve a avisar de desconexión.
func _expect_rejection(client: NetClient, expected_result: int) -> void:
	var rejections: Array[Dictionary] = []
	client.rejected.connect(func(result: int, text: String) -> void:
		rejections.append({"result": result, "text": text}))
	var disconnections: Array[String] = []
	client.disconnected.connect(func(text: String) -> void: disconnections.append(text))
	var welcomed: Array[bool] = []
	client.welcomed.connect(func(_welcome: NetMessages.Welcome) -> void: welcomed.append(true))
	assert_true(await _wait_until(func() -> bool: return not rejections.is_empty()),
			"llega el REJECT")
	if rejections.is_empty():
		return
	assert_eq(rejections[0]["result"], expected_result)
	assert_eq(rejections[0]["text"], NetProtocol.result_text(expected_result),
			"el texto está en español")
	assert_eq(client.get_state(), NetClient.State.CLOSED)
	assert_true(welcomed.is_empty(), "no hay WELCOME")
	assert_null(client.get_character(), "no hay personaje")
	await wait_physics_frames(60)
	assert_true(disconnections.is_empty(), "tras un REJECT no se avisa de desconexión")
	assert_eq(_server.get_player_count(), 0, "el servidor no deja a nadie dentro")
	assert_eq(rejections.size(), 1, "y el REJECT se avisa una sola vez")


# --- b) Altas y bajas -------------------------------------------------------------------------

func test_b_spawn_and_despawn_on_connect_leave_and_cut() -> void:
	await _start_server()
	var first: NetClient = _add_bot(VARDHEIM, 1)
	var second: NetClient = _add_bot(SOLMARCH, 2)
	assert_true(await _wait_until(_all_in_world), "los dos entran")
	assert_true(await _wait_until(_all_see_the_others), "y se ven")
	assert_eq(_server.get_player_count(), 2)
	var first_view: RemotePlayerView = first.get_remote_world().get_view(second.get_net_id())
	var second_view: RemotePlayerView = second.get_remote_world().get_view(first.get_net_id())
	assert_not_null(first_view, "el primero ve al segundo")
	assert_not_null(second_view, "y el segundo, al primero")
	if first_view == null or second_view == null:
		return
	assert_eq(first_view.get_display_name(), "Bot-2")
	assert_eq(second_view.get_display_name(), "Bot-1")
	assert_eq(first_view.get_realm(), SOLMARCH)
	assert_true(await _wait_until(func() -> bool: return first_view.get_body().visible),
			"y aparece en pantalla cuando el dibujo alcanza su alta")

	# Un tercero entra y sale con CLIENT_LEAVE.
	var third: NetClient = _add_bot(VARDHEIM, 3)
	var third_net_id: int = 0
	var third_text: Array[String] = []
	third.disconnected.connect(func(text: String) -> void: third_text.append(text))
	assert_true(await _wait_until(_all_in_world), "entra el tercero")
	third_net_id = third.get_net_id()
	assert_true(await _wait_until(_all_see_the_others), "y los tres se ven")
	assert_eq(_server.get_player_count(), 3)
	third.leave()
	assert_true(await _wait_until(func() -> bool: return _server.get_player_count() == 2),
			"el servidor da de baja a quien se va")
	assert_true(await _wait_until(func() -> bool:
		return first.get_remote_world().get_view(third_net_id) == null \
				and second.get_remote_world().get_view(third_net_id) == null),
			"y los demás lo quitan de pantalla cuando su tick de dibujo llega a la baja")
	assert_true(await _wait_until(func() -> bool: return not third_text.is_empty()),
			"el que se va recibe la desconexión")
	assert_eq(third.get_state(), NetClient.State.CLOSED)
	assert_eq(third_text[0], NetClient.TEXT_LEFT, "con un texto en español")

	# El segundo se cae sin avisar (corte): el servidor lo detecta al cerrar el socket.
	var second_net_id: int = second.get_net_id()
	_clients.erase(second)
	var second_viewport: SubViewport = _client_viewports[1]
	_client_viewports.erase(second_viewport)
	second_viewport.free()
	assert_true(await _wait_until(func() -> bool: return _server.get_player_count() == 1),
			"el servidor da de baja al que se cae")
	assert_true(await _wait_until(func() -> bool:
		return first.get_remote_world().get_view(second_net_id) == null),
			"y el que queda lo quita de pantalla")
	assert_eq(first.get_state(), NetClient.State.IN_WORLD, "el que queda sigue en el mundo")
	assert_eq(first.get_remote_world().get_view_count(), 0)


func test_b_a_dropped_server_is_reported_to_the_client() -> void:
	await _start_server()
	var client: NetClient = _add_bot(VARDHEIM, 1)
	var texts: Array[String] = []
	client.disconnected.connect(func(text: String) -> void: texts.append(text))
	assert_true(await _wait_until(_all_in_world))
	_server.stop("Mantenimiento")
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty()),
			"el cliente se entera del cierre")
	assert_eq(texts[0], "Mantenimiento", "con el texto del NOTICE del servidor")
	assert_eq(client.get_state(), NetClient.State.CLOSED)
	assert_eq(texts.size(), 1, "una sola vez")


# --- c) Sin simulador de red ------------------------------------------------------------------

func test_c_three_bots_predict_exactly_and_see_each_other() -> void:
	await _start_server()
	var realms: Array[int] = [VARDHEIM, VARDHEIM, SOLMARCH]
	for i: int in 3:
		_add_bot(realms[i], i + 1)
	assert_true(await _wait_until(_all_in_world), "entran los tres")
	assert_true(await _wait_until(_all_see_the_others), "y se ven")

	# 600 ticks. En el tick 60 de cada cliente se apunta cuántas diferencias llevaba.
	var baseline: Dictionary[NetClient, int] = {}
	var worst_error: float = 0.0
	var samples: int = 0
	for frame: int in 600:
		await tree.physics_frame
		for client: NetClient in _clients:
			if not baseline.has(client) and client.get_local_tick() >= 60:
				baseline[client] = client.get_stats()["diffs"]
		if frame >= 120 and frame % 15 == 0:
			for client: NetClient in _clients:
				worst_error = maxf(worst_error, _drawing_error(client))
				samples += 1
	assert_true(samples > 0)
	assert_true(worst_error < 0.5, "los remotos se dibujan a menos de 0,5 m del historial del "
			+ "servidor (peor error: %.3f m)" % worst_error)
	for client: NetClient in _clients:
		var stats: Dictionary = client.get_stats()
		var name: String = client.get_config().display_name
		assert_eq(stats["diffs"] - baseline.get(client, 0), 0,
				"%s: 0 correcciones desde el tick 60 (%s)" % [name, stats])
		assert_eq(stats["unexplained_diffs"], 0, "%s: ninguna diferencia sin explicar" % name)
		assert_eq(stats["hard_resets"], 0, "%s: ningún reinicio duro" % name)
		assert_eq(stats["resyncs"], 0, "%s: ninguna resincronización" % name)
		assert_true(stats["matches"] > 200, "%s: coincide en casi todos los snapshots (%d)"
				% [name, stats["matches"]])
		assert_eq(stats["malformed_packets"], 0)
		assert_eq(client.get_remote_world().get_view_count(), 2, "%s ve a los otros dos" % name)
		assert_eq(stats["late_snapshots"], 0, "en loopback no hay snapshots desordenados")
		# El jugador local va por delante del servidor unos ticks, no más.
		var server_position: Vector3 = _server_position(client.get_net_id())
		assert_true(client.get_character().global_position.distance_to(server_position) < 3.0,
				"%s: sigue al servidor" % name)
	assert_true(_server.get_metrics().get_substituted_percent() < 5.0,
			"el servidor casi no sustituye entradas")


## Distancia entre donde dibuja [param viewer] a cada uno de los otros y la muestra de
## [method StateHistory.sample] en ese mismo tick de dibujo; el peor de ellos.
func _drawing_error(viewer: NetClient) -> float:
	var worst: float = 0.0
	var render_tick: float = viewer.get_remote_world().get_last_drawn_render_tick()
	for other: NetClient in _clients:
		if other == viewer:
			continue
		var view: RemotePlayerView = viewer.get_remote_world().get_view(other.get_net_id())
		var truth: StateHistory.Sample = _server.get_history().sample(other.get_net_id(),
				render_tick)
		if view == null or truth == null:
			return 1000.0
		worst = maxf(worst, view.get_drawn_position().distance_to(truth.position))
	return worst


func test_c_report_and_state_log_are_written() -> void:
	await _start_server()
	var report_path: String = ProjectSettings.globalize_path("res://build/test_loopback_report.json")
	var log_path: String = ProjectSettings.globalize_path("res://build/test_loopback_states.txt")
	DirAccess.remove_absolute(report_path)
	DirAccess.remove_absolute(log_path)
	var logged: NetClient = _add_bot(VARDHEIM, 5)
	# El registro se abre al escribir el primero, así que se puede pedir justo después de start().
	logged.get_config().state_log_path = log_path
	assert_true(await _wait_until(_all_in_world))
	await wait_physics_frames(120)
	assert_eq(logged.write_report(report_path), OK)
	var report: Dictionary = NetHarness.read_report(report_path)
	for key: String in ["matches", "diffs", "explained_diffs", "unexplained_diffs",
			"hard_resets", "resyncs", "tick_sync_adjustments", "substitutions", "final", "name",
			"snapshots_with_state", "state", "rtt_ticks"]:
		assert_true(report.has(key), "el informe tiene «%s»" % key)
	assert_eq(report.get("name"), "Bot-5")
	assert_eq(report.get("state"), "IN_WORLD")
	assert_true(int(report.get("matches", 0)) > 20)
	assert_eq(int(report.get("unexplained_diffs", -1)), 0)
	var final_state: Dictionary = report.get("final", {})
	assert_true(final_state.has("predicted_state") and final_state.has("server_state"),
			"con el estado final")
	assert_eq(String(final_state.get("predicted_state", "")).length(),
			PlayerState.ENCODED_SIZE * 2, "en hexadecimal")
	assert_true(bool(final_state.get("exact", false)), "el estado final coincide con el del servidor")
	# El registro tiene server_tick,predicho,servidor por cada snapshot con estado propio.
	var lines: PackedStringArray = FileAccess.get_file_as_string(log_path).split("\n", false)
	assert_true(lines.size() > 20, "una línea por snapshot (%d)" % lines.size())
	var matching: int = 0
	for line: String in lines:
		var parts: PackedStringArray = line.split(",")
		assert_eq(parts.size(), 3)
		if parts.size() == 3 and parts[1] == parts[2]:
			matching += 1
	assert_true(matching > lines.size() / 2, "casi todas con lo predicho igual a lo del servidor")


# --- e) Teletransporte de depuración ----------------------------------------------------------

func test_e_debug_teleport_jumps_without_smoothing_and_converges_exactly() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	var client: NetClient = _add_bot(VARDHEIM, 4)
	assert_true(await _wait_until(_all_in_world))
	await wait_physics_frames(90)
	var before: Dictionary = client.get_stats()
	assert_eq(before["diffs"], 0, "sin diferencias antes del teletransporte (%s)" % before)

	var target := Vector3(-60.0, 0.0, -40.0)
	var payload: PackedByteArray = NetMessages.DebugCommand.teleport(target).payload
	client.send_debug_command(NetProtocol.DEBUG_TELEPORT, payload)
	assert_true(await _wait_until(func() -> bool:
		return client.get_stats()["teleport_diffs"] > 0), "el cliente nota el teletransporte")
	var character: PlayerCharacter = client.get_character()
	var visual: Node3D = character.get_node(^"Visual") as Node3D
	assert_true(character.global_position.distance_to(target) < 3.0,
			"y salta al nuevo sitio (%s)" % character.global_position)
	assert_eq(visual.position, Vector3.ZERO, "sin suavizado: el visual no queda desplazado")
	assert_eq(client.get_stats()["unexplained_diffs"], 0, "el salto no es un fallo de predicción")

	# El bot sigue paseando (vuelve hacia su casa) y todo sigue coincidiendo.
	await wait_physics_frames(120)
	assert_eq(client.get_stats()["unexplained_diffs"], 0)
	assert_eq(client.get_stats()["hard_resets"], 0)
	assert_eq(client.get_stats()["teleport_diffs"], 1, "un solo teletransporte")

	# Quieto, queda exacto: el estado predicho es idéntico bit a bit al del servidor.
	var brain: BotBrain = client.get_meta(&"bot_brain") as BotBrain
	brain.set_idle_from(client.get_prediction().get_predicted_tick() + 1)
	await wait_physics_frames(90)
	var stats: Dictionary = client.get_stats()
	assert_true(stats["consecutive_matches"] >= 10, "converge y se queda coincidiendo (%d)"
			% stats["consecutive_matches"])
	var server_entity: NetEntity = _server.get_registry().get_entity(client.get_net_id())
	var server_state: PlayerState = server_entity.get_character().get_state()
	var predicted_state: PlayerState = client.get_prediction().get_predicted_state(
			stats["server_tick"])
	assert_not_null(predicted_state)
	if predicted_state != null:
		assert_true(client.get_last_server_state().equals_exact(predicted_state),
				"el último estado del servidor coincide exacto con el predicho")
	assert_vec_near(character.get_state().position, server_state.position, 0.0001,
			"quieto, cliente y servidor están en el mismo punto")
	assert_vec_near(server_state.velocity, Vector3.ZERO, 0.001)


func test_e_teleport_is_ignored_without_debug_commands() -> void:
	await _start_server()
	var client: NetClient = _add_bot(VARDHEIM, 4)
	assert_true(await _wait_until(_all_in_world))
	var start_position: Vector3 = client.get_character().global_position
	var payload: PackedByteArray = NetMessages.DebugCommand.teleport(Vector3(-60.0, 0.0, -40.0)) \
			.payload
	client.send_debug_command(NetProtocol.DEBUG_TELEPORT, payload)
	await wait_physics_frames(60)
	assert_eq(client.get_stats()["teleport_diffs"], 0)
	assert_true(client.get_character().global_position.distance_to(start_position) < 25.0,
			"el comando no tuvo efecto")
	assert_eq(client.get_state(), NetClient.State.IN_WORLD, "y el cliente sigue dentro")
