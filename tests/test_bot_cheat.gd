extends TestCase
## El bot tramposo ([BotCheater], [code]--bot-cheat[/code]; docs/red.md, secciones 12 y 16; TEC-46)
## contra un [ZoneServer] real en el mismo proceso, con ENet sobre 127.0.0.1: un bot honrado y un
## tramposo, cada uno en su [SubViewport] con su propio mundo de física. Un método por modo:
## [br]- [code]version[/code]: REJECT VERSION y el tramposo nunca entra;
## [br]- [code]future[/code]: las entradas fuera de la ventana se descartan y se cuentan (TOO_EARLY), sin
## avisos y sin efecto: el servidor aplica solo las honradas, así que el tramposo predice sin fallos;
## [br]- [code]dupes[/code]: gana la primera copia, la honrada: ningún fallo de predicción;
## [br]- [code]garbage[/code] y [code]flood[/code]: avisos, NOTICE de expulsión y baja.
## [br]En todos los modos el bot honrado sigue en el mundo, sin avisos ni fallos de predicción, y el
## servidor no registra errores (el ejecutor falla ante cualquier error del motor).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const REPORT_PATH: String = "res://build/test_bot_cheat_report.json"
## Fotogramas de física como mucho que se espera a una condición (10 s).
const WAIT_FRAMES: int = 600

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _port: int = 0
var _honest: NetClient
var _cheater: NetClient
var _viewports: Array[SubViewport] = []


func before_each() -> void:
	_root = Node.new()
	_root.name = "BotCheat"
	tree.root.add_child(_root)


func after_each() -> void:
	for viewport: SubViewport in _viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_viewports.clear()
	_honest = null
	_cheater = null
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

## Servidor con la zona plana, un bot honrado y un tramposo del modo [param cheat].
func _start_scenario(cheat: String) -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	_honest = _add_bot(VARDHEIM, 1, "")
	_cheater = _add_bot(SOLMARCH, 2, cheat)


func _add_bot(realm: int, bot_seed: int, cheat: String) -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
	_viewports.append(viewport)
	return NetHarness.start_bot(viewport, _port, realm, bot_seed, "", cheat)


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _both_in_world() -> bool:
	return _honest.get_state() == NetClient.State.IN_WORLD \
			and _cheater.get_state() == NetClient.State.IN_WORLD


## Ficha del servidor del jugador con ese net_id (vacía si no existe).
func _server_record(net_id: int) -> Dictionary:
	var path: String = ProjectSettings.globalize_path(REPORT_PATH)
	assert_eq(_server.write_report(path), OK, "se escribe el informe del servidor")
	var report: Dictionary = NetHarness.read_report(path)
	for entry: Dictionary in report.get("player_list", []):
		if int(entry.get("net_id", 0)) == net_id:
			return entry
	return {}


func _server_report() -> Dictionary:
	var path: String = ProjectSettings.globalize_path(REPORT_PATH)
	_server.write_report(path)
	return NetHarness.read_report(path)


## El bot honrado sigue como si nada: dentro del mundo, sin avisos y sin fallos de predicción.
func _assert_honest_bot_untouched(min_matches: int = 50) -> void:
	assert_eq(_honest.get_state(), NetClient.State.IN_WORLD, "el bot honrado sigue en el mundo")
	var peer: ServerPeer = _server.get_peer(_peer_id_of(_honest.get_net_id()))
	if assert_not_null(peer, "y el servidor lo sigue teniendo"):
		assert_eq(peer.strikes_total, 0, "sin ningún aviso")
	var stats: Dictionary = _honest.get_stats()
	assert_eq(stats["unexplained_diffs"], 0, "sin fallos de predicción: %s" % [stats])
	assert_true(stats["matches"] > min_matches,
			"y con muchas coincidencias exactas (%d)" % stats["matches"])
	assert_eq(stats["hard_resets"], 0, "ni reinicios duros")


## peer_id del servidor del jugador con ese net_id (0 si no existe).
func _peer_id_of(net_id: int) -> int:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.entity != null and peer.entity.net_id == net_id:
			return peer_id
	return 0


# --- Un método por modo -----------------------------------------------------------------------

func test_version_cheater_is_rejected_and_never_enters() -> void:
	await _start_scenario("version")
	var rejections: Array[Vector2i] = []
	var texts: Array[String] = []
	_cheater.rejected.connect(func(result: int, text: String) -> void:
		rejections.append(Vector2i(result, 0))
		texts.append(text))
	var honest_in: bool = await _wait_until(func() -> bool:
		return _honest.get_state() == NetClient.State.IN_WORLD)
	assert_true(honest_in, "el bot honrado entra")
	var rejected: bool = await _wait_until(func() -> bool: return not rejections.is_empty())
	if not assert_true(rejected, "el tramposo recibe un REJECT"):
		return
	assert_eq(rejections[0].x, NetProtocol.Result.VERSION, "por la versión del protocolo")
	assert_eq(texts[0], NetProtocol.result_text(NetProtocol.Result.VERSION), "con su texto en español")
	assert_eq(_cheater.get_state(), NetClient.State.CLOSED, "y su sesión se cierra")
	assert_null(_cheater.get_character(), "sin llegar a tener personaje")
	await wait_physics_frames(120)
	assert_eq(_server.get_player_count(), 1, "el servidor solo tiene al honrado")
	assert_eq((_server_report().get("rejects", {}) as Dictionary).size(), 1, "y cuenta un rechazo")
	_assert_honest_bot_untouched()


func test_future_cheater_has_no_effect_and_gains_nothing() -> void:
	await _start_scenario("future")
	assert_true(await _wait_until(_both_in_world), "entran los dos")
	await wait_physics_frames(300)
	_assert_honest_bot_untouched()
	var record: Dictionary = _server_record(_cheater.get_net_id())
	assert_true(int(record.get("too_early_inputs", 0)) > 200,
			"el servidor descarta y cuenta las entradas de futuro (%s)" % record.get("too_early_inputs"))
	assert_eq(int(record.get("strikes", -1)), 0, "pero no son un aviso: el exceso de antelación es de red")
	assert_false(bool(record.get("kicked", true)), "ni expulsión")
	assert_eq(_cheater.get_state(), NetClient.State.IN_WORLD, "el tramposo sigue jugando")
	assert_true(_cheater.get_stats()["cheat_packets"] > 200, "y de verdad mandaba entradas de futuro")
	# Sin ventaja: el servidor aplica solo las entradas honradas, así que su predicción no falla.
	var stats: Dictionary = _cheater.get_stats()
	assert_eq(stats["unexplained_diffs"], 0, "el servidor y la predicción del tramposo coinciden: %s" % [stats])
	assert_true(stats["matches"] > 50, "con muchas coincidencias exactas")


func test_dupes_cheater_first_copy_wins() -> void:
	await _start_scenario("dupes")
	assert_true(await _wait_until(_both_in_world), "entran los dos")
	await wait_physics_frames(300)
	_assert_honest_bot_untouched()
	var record: Dictionary = _server_record(_cheater.get_net_id())
	assert_eq(int(record.get("strikes", -1)), 0, "las copias distintas no son un aviso")
	assert_false(bool(record.get("kicked", true)), "ni expulsión")
	assert_true(_cheater.get_stats()["cheat_packets"] > 200, "pero sí las mandaba")
	var stats: Dictionary = _cheater.get_stats()
	assert_eq(stats["unexplained_diffs"], 0,
			"gana la primera copia, la honrada: la predicción acierta siempre: %s" % [stats])
	assert_true(stats["matches"] > 50, "con muchas coincidencias exactas")
	assert_eq(int(record.get("late_inputs", -1)), 0, "y ninguna entrada llega tarde")


func test_garbage_cheater_is_kicked() -> void:
	await _start_scenario("garbage")
	await _assert_cheater_is_kicked()


func test_flood_cheater_is_kicked() -> void:
	await _start_scenario("flood")
	await _assert_cheater_is_kicked()


## El tramposo de basura o de ráfagas recibe el NOTICE de expulsión y se le da de baja; el honrado
## ve su DESPAWN y no nota nada más.
func _assert_cheater_is_kicked() -> void:
	assert_true(await _wait_until(_both_in_world), "entran los dos")
	var cheater_id: int = _cheater.get_net_id()
	var notices: Array[String] = []
	_cheater.notice_received.connect(func(code: int, text: String) -> void:
		if code == NetProtocol.NoticeCode.KICK:
			notices.append(text))
	var kicked: bool = await _wait_until(func() -> bool:
		return _cheater.get_state() == NetClient.State.CLOSED)
	if not assert_true(kicked, "el tramposo acaba desconectado"):
		return
	assert_eq(notices.size(), 1, "tras un NOTICE de expulsión")
	assert_true(notices[0].contains("Expulsado"), "en español: %s" % notices[0])
	assert_true(_cheater.get_last_notice_text().contains("Expulsado"), "y es el motivo de la desconexión")
	var report: Dictionary = _server_report()
	var kicks: Array = report.get("kicks", [])
	if assert_eq(kicks.size(), 1, "el servidor registra una sola expulsión"):
		assert_eq(int((kicks[0] as Dictionary).get("net_id", 0)), cheater_id, "la del tramposo")
		assert_false(String((kicks[0] as Dictionary).get("reason", "")).is_empty(), "con su motivo")
	assert_true((report.get("strikes", {}) as Dictionary).get("total", 0) >= 50,
			"tras al menos 50 avisos")
	var record: Dictionary = _server_record(cheater_id)
	assert_true(bool(record.get("kicked", false)), "la ficha del jugador lo marca como expulsado")
	await wait_physics_frames(60)
	assert_eq(_server.get_player_count(), 1, "solo queda el honrado")
	assert_null(_server.get_registry().get_entity(cheater_id), "y el personaje del tramposo desapareció")
	assert_eq(_honest.get_remote_world().get_view_count(), 0, "el honrado ya no lo ve")
	_assert_honest_bot_untouched(20)
