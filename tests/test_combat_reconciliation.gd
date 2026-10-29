extends TestCase
## La reconciliación en una refriega con red mala (TEC-15; docs/combate.md, secciones 1 y 3.4): cuatro
## bots de combate ([code]--bot-brain=combat[/code], dos por reino) pelean entre sí con ENet real sobre
## 127.0.0.1 y un [NetSim] de 120 ms de RTT, 20 ms de jitter y un 5 % de pérdida en cada uno.
## [br][br]
## El servidor impone estados que el cliente no predice (tambaleo, aturdimiento, empuje, muerte,
## reaparición, la resistencia que gasta un golpe bloqueado). Cada uno de ellos obliga a corregir la
## predicción del que lo sufre, y esa corrección es [i]esperada[/i]: la tiene que explicar el
## [NetClient] (un evento de combate propio en esos ticks), no contarse como un fallo de predicción. Lo
## que se comprueba:
## [br]- hay correcciones (la refriega de verdad cambia el estado) y todas están explicadas por una
## entrada sustituida, un teletransporte o un evento de combate propio;
## [br]- ningún reinicio duro ni resincronización de [TickSync] por culpa del combate;
## [br]- al quedarse quietos, el estado predicho para el último tick del servidor es idéntico bit a bit
## al del servidor (convergencia).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900
## Simulador de red de cada bot (la semilla se suma al índice del bot para que no pierdan lo mismo).
const NET_SIM: String = "rtt=120,jitter=20,loss=5,seed=%d"
## Ticks que pelean y ticks quietos del final (más que lo que tarda en acabar la acción en curso y en
## llegar el último snapshot).
const FIGHT_TICKS: int = 900
const IDLE_TICKS: int = 180

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _clients: Array[NetClient] = []
var _viewports: Array[SubViewport] = []


func before_each() -> void:
	_root = Node.new()
	_root.name = "CombatReconciliation"
	tree.root.add_child(_root)


func after_each() -> void:
	for viewport: SubViewport in _viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_viewports.clear()
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


# --- Prueba -----------------------------------------------------------------------------------

func test_a_brawl_of_combat_bots_over_a_bad_network_is_explained_and_converges() -> void:
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = port
	config.zone_id = ZONE_ID
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	var realms: Array[int] = [VARDHEIM, SOLMARCH, VARDHEIM, SOLMARCH, VARDHEIM, SOLMARCH]
	for index: int in realms.size():
		var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
		_viewports.append(viewport)
		_clients.append(NetHarness.start_bot(viewport, port, realms[index], index + 1,
				NET_SIM % (7 * (index + 1)), "", ClientConfig.BOT_BRAIN_COMBAT))
	if not assert_true(await _wait_until(_all_in_world), "entran los cuatro bots"):
		return
	await wait_physics_frames(60)
	# Corro: dos contra dos, a un par de metros.
	var spots: Array[Vector3] = [Vector3(-2.0, 0.05, 0.0), Vector3(2.0, 0.05, 0.0),
			Vector3(-2.0, 0.05, 3.0), Vector3(2.0, 0.05, 3.0), Vector3(-2.0, 0.05, 6.0),
			Vector3(2.0, 0.05, 6.0)]
	for index: int in _clients.size():
		_server.teleport(_clients[index].get_net_id(), spots[index])
	await wait_physics_frames(FIGHT_TICKS)

	var combat: Dictionary = _server.get_combat().stats
	print("[refriega] golpes %d, bloqueados %d, paradas %d, rotura de guardia %d, muertes %d, eventos %d" % [
			combat[&"hits"], combat[&"blocked"], combat[&"parried"], combat[&"guard_breaks"],
			combat[&"deaths"], combat[&"events"]])
	assert_true(combat[&"hits"] >= 10, "de verdad se pelean (%d golpes)" % combat[&"hits"])
	for client: NetClient in _clients:
		var stats: Dictionary = client.get_stats()
		print("[refriega] %s: diffs %d, explicadas %d, de combate %d, sin explicar %d, correcciones %d, "
				% [client.get_config().display_name, stats["diffs"], stats["explained_diffs"],
				stats.get("combat_diffs", -1), stats["unexplained_diffs"], stats["corrections"]]
				+ "reinicios duros %d, resincronizaciones %d, sustituciones %d" % [stats["hard_resets"],
				stats["resyncs"], stats["substitutions_total"]])

	# Quietos: se espera a que acabe lo que tuvieran en marcha y a que el servidor y el cliente coincidan.
	for client: NetClient in _clients:
		var brain: BotBrain = client.get_meta(&"bot_brain") as BotBrain
		brain.set_idle_from(client.get_prediction().get_predicted_tick() + 1)
	await wait_physics_frames(IDLE_TICKS)

	var any_combat_correction: bool = false
	for client: NetClient in _clients:
		var name: String = client.get_config().display_name
		var stats: Dictionary = client.get_stats()
		assert_eq(client.get_state(), NetClient.State.IN_WORLD, "%s: sigue en el mundo" % name)
		assert_eq(stats["unexplained_diffs"], 0,
				"%s: toda corrección la explica una sustitución, un teletransporte o el combate: %s"
				% [name, stats])
		assert_eq(stats["hard_resets"], 0, "%s: ningún reinicio duro" % name)
		assert_eq(stats["resyncs"], 0, "%s: ninguna resincronización" % name)
		if int(stats.get("combat_diffs", 0)) > 0:
			any_combat_correction = true
		var server_state: PlayerState = client.get_last_server_state()
		var predicted: PlayerState = client.get_prediction().get_predicted_state(client.get_last_snapshot_tick())
		if assert_not_null(server_state, "%s: recibió su estado" % name) \
				and assert_not_null(predicted, "%s: guarda lo que predijo" % name):
			assert_true(predicted.equals_exact(server_state),
					"%s: convergencia exacta con el servidor al quedarse quieto" % name)
	assert_true(any_combat_correction, "alguna corrección la causó un golpe (el combate se explica a sí mismo)")
