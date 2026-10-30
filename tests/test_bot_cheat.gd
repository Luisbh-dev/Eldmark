extends TestCase
## El bot tramposo ([BotCheater], [code]--bot-cheat[/code]; docs/red.md, secciones 12 y 16; TEC-46)
## contra un [ZoneServer] real en el mismo proceso, con ENet sobre 127.0.0.1: un bot honrado y un
## tramposo, cada uno en su [SubViewport] con su propio mundo de física. Un método por modo:
## [br]- [code]version[/code]: REJECT VERSION y el tramposo nunca entra;
## [br]- [code]future[/code]: las entradas fuera de la ventana se descartan y se cuentan (TOO_EARLY), sin
## avisos y sin efecto: el servidor aplica solo las honradas, así que el tramposo predice sin fallos;
## [br]- [code]dupes[/code]: gana la primera copia, la honrada: ningún fallo de predicción;
## [br]- [code]garbage[/code] y [code]flood[/code]: avisos, NOTICE de expulsión y baja.
## [br]- [code]rewind[/code], [code]reach[/code] y [code]rate[/code] (combate, TEC-14): el bot pelea contra
## un maniquí con las reglas del juego, pero con la vista falseada a 40 ticks, desde 5 m o machacando
## PRIMARY. Ninguno hace daño de más: el rebobinado excesivo no se prueba y suma sospecha; desde 5 m no
## hay golpe; y machacar el botón no pega más rápido que el combo de los datos.
## [br]- [code]reuse[/code], [code]potion[/code] e [code]interact[/code] (fase 4; docs/habilidades.md, sección 4.7):
## machacar una habilidad en reutilización da un golpe por reutilización; machacar las pociones, un trago por
## reutilización compartida y con cargas; machacar INTERACT lejos de todos no levanta ni remata a nadie. Ningún
## efecto de más ni sospecha.
## [br]En todos los modos el bot honrado sigue en el mundo, sin avisos ni fallos de predicción, y el
## servidor no registra errores (el ejecutor falla ante cualquier error del motor).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const REPORT_FILE: String = "test_bot_cheat_report.json"
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


func _add_bot(realm: int, bot_seed: int, cheat: String, brain: String = "") -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
	_viewports.append(viewport)
	return NetHarness.start_bot(viewport, _port, realm, bot_seed, "", cheat, brain)


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
	var path: String = NetHarness.build_path(REPORT_FILE)
	assert_eq(_server.write_report(path), OK, "se escribe el informe del servidor")
	var report: Dictionary = NetHarness.read_report(path)
	for entry: Dictionary in report.get("player_list", []):
		if int(entry.get("net_id", 0)) == net_id:
			return entry
	return {}


func _server_report() -> Dictionary:
	var path: String = NetHarness.build_path(REPORT_FILE)
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


# --- Modos de combate: rewind, reach y rate -----------------------------------------------------

## Ticks que pelean los bots de las pruebas de combate una vez colocados.
const FIGHT_TICKS: int = 600
## Dónde está el maniquí y a qué distancia (m) empieza el bot que se prueba.
const DUMMY_POSITION := Vector3(0.0, 0.0, -3.0)
const CHEATER_START := Vector3(0.0, 0.05, 3.0)
const CONTROL_START := Vector3(0.0, 0.05, -10.0)

## net_id del atacante -> {"hits": golpes al maniquí, "damage": daño anunciado} según el servidor.
var _tally: Dictionary = {}
var _dummy_id: int = 0


## Servidor con un maniquí que mira a +Z, el tramposo de [param cheat] (Vardheim) colocado a 6 m de él y,
## si [param with_control], un bot honrado con el cerebro de combate (el mismo que usa el modo rewind) que
## lo ataca desde el otro lado.
## Espera a que los bots estén en el mundo.
func _start_fight(cheat: String, with_control: bool) -> bool:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	_server.get_combat().event_emitted.connect(_on_combat_event)
	_cheater = _add_bot(VARDHEIM, 2, cheat)
	if with_control:
		_honest = _add_bot(VARDHEIM, 1, "")
	var in_world: bool = await _wait_until(func() -> bool:
		return _cheater.get_state() == NetClient.State.IN_WORLD \
				and (_honest == null or _honest.get_state() == NetClient.State.IN_WORLD))
	if not in_world:
		return false
	await wait_physics_frames(30)
	_dummy_id = _server.spawn_dummy(DUMMY_POSITION, PI)
	_server.teleport(_cheater.get_net_id(), CHEATER_START)
	if with_control:
		# Mismo cerebro de combate que el tramposo de rewind, pero que también ve a los maniquíes, y la
		# vista de verdad.
		var sight := BotEnemySight.new(_honest, true)
		var brain := BotBrain.new(1, BotBrain.Pattern.COMBAT, CONTROL_START, 30.0)
		brain.set_enemy_finder(func(position: Vector3) -> Variant: return sight.find(position))
		(_honest.get_meta(&"controller") as LocalPlayerController).set_bot(brain)
		_server.teleport(_honest.get_net_id(), CONTROL_START)
	return _dummy_id > 0


func _on_combat_event(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
	if event.event != NetMessages.EntityEvent.Kind.HIT or event.net_id != _dummy_id:
		return
	var entry: Dictionary = _tally.get(event.attacker, {"hits": 0, "damage": 0})
	entry["hits"] = int(entry["hits"]) + 1
	entry["damage"] = int(entry["damage"]) + event.amount
	_tally[event.attacker] = entry


func _hits_of(client: NetClient) -> int:
	return int((_tally.get(client.get_net_id(), {}) as Dictionary).get("hits", 0))


func _damage_of(client: NetClient) -> int:
	return int((_tally.get(client.get_net_id(), {}) as Dictionary).get("damage", 0))


## Distancia horizontal (m) del personaje del servidor de [param client] al maniquí.
func _distance_to_dummy(client: NetClient) -> float:
	var bot: Vector3 = _server.get_registry().get_entity(client.get_net_id()).get_position()
	var dummy: Vector3 = _server.get_registry().get_entity(_dummy_id).get_position()
	return Vector2(bot.x - dummy.x, bot.z - dummy.z).length()


func test_rewind_cheater_deals_no_damage_and_its_suspicion_score_rises() -> void:
	if not assert_true(await _start_fight("rewind", true), "arranca la pelea"):
		return
	await wait_physics_frames(FIGHT_TICKS)
	var peer: ServerPeer = _server.get_peer(_peer_id_of(_cheater.get_net_id()))
	var control: ServerPeer = _server.get_peer(_peer_id_of(_honest.get_net_id()))
	print("[trampa rewind] golpes lanzados %d, rechazados %d, sospecha %d, daño %d; control: %d golpes, %d de daño" % [
			peer.swings, peer.rewind_rejects, peer.suspicion_score, _damage_of(_cheater), control.swings,
			_damage_of(_honest)])
	assert_true(peer.swings >= 4, "el tramposo lanza golpes de verdad (%d)" % peer.swings)
	assert_eq(_hits_of(_cheater), 0, "ninguno le hace daño al maniquí")
	assert_eq(_damage_of(_cheater), 0)
	assert_true(peer.rewind_rejects >= 4, "el servidor los rechaza por el tope (%d)" % peer.rewind_rejects)
	assert_eq(peer.suspicion_score, peer.rewind_rejects, "y la sospecha sube con cada uno")
	assert_eq(peer.strikes_total, 0, "sin avisos: no es un paquete ilegal")
	assert_eq(_cheater.get_state(), NetClient.State.IN_WORLD, "sigue jugando")
	assert_eq(_cheater.get_stats()["cheat_packets"], 0, "no manda tráfico de más")
	# El control: el mismo cerebro de combate con la vista de verdad sí pega y no levanta sospechas.
	assert_true(control.swings >= 4, "el honrado también ataca (%d)" % control.swings)
	assert_true(_hits_of(_honest) >= 3, "y a él sí le entran los golpes (%d)" % _hits_of(_honest))
	assert_eq(control.suspicion_score, 0, "sin sospecha")
	var report: Dictionary = _server_report()
	var suspicious: Array = (report.get("combat", {}) as Dictionary).get("suspicious", [])
	if assert_eq(suspicious.size(), 1, "el informe del servidor señala a uno solo"):
		assert_eq(int((suspicious[0] as Dictionary).get("net_id", 0)), _cheater.get_net_id(), "al tramposo")
	_assert_client_untouched(_honest)


func test_reach_cheater_swinging_from_five_meters_never_connects() -> void:
	if not assert_true(await _start_fight("reach", false), "arranca la pelea"):
		return
	var closest: float = INF
	for _frame: int in FIGHT_TICKS:
		await tree.physics_frame
		closest = minf(closest, _distance_to_dummy(_cheater))
	var peer: ServerPeer = _server.get_peer(_peer_id_of(_cheater.get_net_id()))
	print("[trampa reach] golpes lanzados %d, aciertos %d, distancia mínima %.2f m" % [
			peer.swings, _hits_of(_cheater), closest])
	assert_true(peer.swings >= 5, "lanza golpes sin parar (%d)" % peer.swings)
	assert_eq(_hits_of(_cheater), 0, "ninguno conecta")
	assert_eq(_server.get_combat().stats[&"hits"], 0, "el servidor no registra ningún impacto")
	assert_eq(_damage_of(_cheater), 0)
	assert_true(closest > 4.0, "se mantiene lejos: la distancia mínima fue %.2f m" % closest)
	assert_eq(peer.suspicion_score, 0, "las entradas son legítimas: no hay nada que sospechar")
	assert_eq(peer.rewind_rejects, 0)
	assert_eq(peer.strikes_total, 0)
	assert_eq(_cheater.get_stats()["unexplained_diffs"], 0, "y su predicción no falla")


func test_rate_cheater_mashing_primary_cannot_hit_faster_than_the_combo() -> void:
	if not assert_true(await _start_fight("rate", false), "arranca la pelea"):
		return
	await wait_physics_frames(FIGHT_TICKS)
	var weapon: WeaponTicks = CombatCatalog.weapon(
			CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var combo_ticks: int = 0
	var combo_damage: int = 0
	for light_id: int in weapon.light_ids:
		var attack: AttackTicks = CombatCatalog.attack(light_id)
		combo_ticks += attack.total_ticks
		combo_damage += attack.base_damage
	# El combo más rápido que permiten los datos, más un golpe por el que empieza a mitad de ciclo.
	var most_hits: int = ceili(float(FIGHT_TICKS) * float(weapon.light_ids.size()) / float(combo_ticks)) + 1
	var peer: ServerPeer = _server.get_peer(_peer_id_of(_cheater.get_net_id()))
	print("[trampa rate] ataques lanzados %d, aciertos %d (tope %d), daño %d" % [
			peer.swings, _hits_of(_cheater), most_hits, _damage_of(_cheater)])
	assert_true(_hits_of(_cheater) >= 5, "pega (%d golpes)" % _hits_of(_cheater))
	assert_true(_hits_of(_cheater) <= most_hits,
			"pero no más que el combo: %d <= %d" % [_hits_of(_cheater), most_hits])
	var most_damage: int = (FIGHT_TICKS / combo_ticks + 1) * combo_damage
	assert_true(_damage_of(_cheater) <= most_damage,
			"ni más daño que el combo continuo: %d <= %d" % [_damage_of(_cheater), most_damage])
	assert_true(peer.swings <= most_hits + 2, "ni lanza más ataques que el combo permite (%d)" % peer.swings)
	assert_eq(peer.suspicion_score, 0, "machacar el botón no es un delito")
	assert_eq(peer.strikes_total, 0)
	assert_eq(_cheater.get_state(), NetClient.State.IN_WORLD)
	assert_eq(_cheater.get_stats()["unexplained_diffs"], 0, "y su predicción no falla")


## Un cliente de la prueba sin avisos ni fallos de predicción.
func _assert_client_untouched(client: NetClient) -> void:
	var stats: Dictionary = client.get_stats()
	assert_eq(stats["unexplained_diffs"], 0, "sin fallos de predicción: %s" % [stats])
	assert_eq(client.get_state(), NetClient.State.IN_WORLD)


# --- Modos de la fase 4: reuse, potion e interact (docs/habilidades.md, sección 4.7) -------------

## Ticks que pelea el tramposo de reutilización: más que una reutilización del golpe de escudo (738 = 720 + 18).
const REUSE_FIGHT_TICKS: int = 900
## Ticks que machaca las pociones el tramposo: más que la reutilización compartida (1200).
const POTION_TICKS: int = 1300


func test_reuse_cheater_mashing_an_ability_on_cooldown_gets_one_use_per_cooldown() -> void:
	if not assert_true(await _start_fight("reuse", false), "arranca la pelea"):
		return
	var bash: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_bash"))
	var bash_source: int = CombatSource.make(CombatSource.Kind.ABILITY, bash.id)
	var bash_hits: Array[int] = []
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
		if event.event == NetMessages.EntityEvent.Kind.HIT and event.attacker == _cheater.get_net_id() \
				and event.get_source() == bash_source:
			bash_hits.append(event.tick))
	await wait_physics_frames(REUSE_FIGHT_TICKS)
	var peer: ServerPeer = _server.get_peer(_peer_id_of(_cheater.get_net_id()))
	var period: int = bash.cooldown_ticks + bash.cast_ticks
	var most: int = ceili(float(REUSE_FIGHT_TICKS) / float(period))
	print("[trampa reuse] golpes de escudo %s (cada %d ticks como mucho %d), sospecha %d" % [bash_hits, period, most,
			peer.suspicion_score])
	assert_true(bash_hits.size() >= 1, "el golpe de escudo sale (%d)" % bash_hits.size())
	assert_true(bash_hits.size() <= most, "pero no más que su reutilización deja: %d <= %d" % [bash_hits.size(),
			most])
	for index: int in range(1, bash_hits.size()):
		assert_true(bash_hits[index] - bash_hits[index - 1] >= period,
				"dos golpes de escudo separados al menos %d ticks (%d)" % [period, bash_hits[index] - bash_hits[index - 1]])
	assert_eq(peer.suspicion_score, 0, "machacar el botón no es un delito")
	assert_eq(peer.strikes_total, 0)
	assert_eq(_cheater.get_state(), NetClient.State.IN_WORLD)
	assert_eq(_cheater.get_stats()["unexplained_diffs"], 0, "y su predicción no falla: la reutilización se predice")


## Dos tramposos de pociones a la vez (revisión de H5: con las 5 cargas de la plantilla, en 1300 ticks no se
## llega a 0 y «ninguna curación sin carga» no se ponía a prueba). El primero, con las cargas de su plantilla:
## dos tragos separados por la reutilización compartida. El segundo empieza con 1 carga de vida y 0 de
## resistencia: un trago de vida y ninguno más en toda la ventana, aunque la reutilización acaba dentro de ella.
func test_potion_cheater_drinks_only_with_charges_and_off_the_shared_cooldown() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	# Lo que bebe cada uno se cuenta desde que aparece: empieza a machacar en cuanto entra.
	var joined: Array[int] = []
	var healed: Dictionary[int, int] = {}
	var regens: Dictionary[int, int] = {}
	var regen_id: int = CombatCatalog.status_id(&"potion_regen")
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
		if not joined.has(event.net_id):
			return
		if event.event == NetMessages.EntityEvent.Kind.HEAL:
			healed[event.net_id] = healed.get(event.net_id, 0) + event.amount
		elif event.event == NetMessages.EntityEvent.Kind.STATUS and event.status_id == regen_id \
				and event.op == NetMessages.EntityEvent.StatusOp.APPLIED:
			regens[event.net_id] = regens.get(event.net_id, 0) + 1)
	var join_ticks: Dictionary[int, int] = {}
	_server.player_joined.connect(func(_peer_id: int, net_id: int) -> void:
		joined.append(net_id)
		join_ticks[net_id] = _server.get_tick()
		var combatant: Combatant = _server.get_combat().get_combatant(net_id)
		# Herido desde el principio, para que la poción de vida tenga algo que curar.
		combatant.take_damage(600, _server.get_tick())
		if joined.size() == 2:
			# El segundo: 1 de vida y 0 de resistencia, con su LOADOUT (el cliente lo explica, como el comando 16). Sin
			# plataforma es un personaje efímero con inventario (progresion.md §9.4, P5b) y sus cargas son las pociones de
			# su bolsa: se le quitan antes las que sobran.
			var progress: PlayerProgress = _server.get_progress().get_player(net_id)
			progress.lose_items(&"potion_health", progress.record.inventory.count_of(&"potion_health") - 1,
					EconomyReason.CONSUME)
			progress.lose_items(&"potion_stamina", progress.record.inventory.count_of(&"potion_stamina"),
					EconomyReason.CONSUME)
			var character: PlayerCharacter = combatant.get_character()
			ActionMachine.set_charges(character.combat, CombatState.pack_charges(1, 0))
			CombatDirector.commit_state(character)
			_server.get_combat().announce_loadout(combatant, _server.get_tick(), false))
	# Los tragos que empieza el estado del servidor de cada uno ((tick de inicio, id del consumible)), mirados en
	# cada tick desde que entra.
	var drinks: Dictionary[int, Array] = {}
	var poll := func() -> void:
		for net_id: int in joined:
			var entity: NetEntity = _server.get_registry().get_entity(net_id)
			if entity == null or entity.get_character() == null:
				continue
			var combat: CombatState = entity.get_character().combat
			if combat.action != CombatState.Action.ABILITY:
				continue
			var list: Array = drinks.get_or_add(net_id, [])
			if list.is_empty() or (list[list.size() - 1] as Vector2i).x != combat.action_tick:
				list.append(Vector2i(combat.action_tick, combat.action_id))
	_cheater = _add_bot(VARDHEIM, 2, "potion")
	if not assert_true(await _wait_until(func() -> bool:
			poll.call()
			return _cheater.get_state() == NetClient.State.IN_WORLD), "entra el primer tramposo"):
		return
	var limited: NetClient = _add_bot(VARDHEIM, 3, "potion")
	if not assert_true(await _wait_until(func() -> bool:
			poll.call()
			return limited.get_state() == NetClient.State.IN_WORLD), "y el segundo"):
		return
	var cheaters: Array[NetClient] = [_cheater, limited]
	for _frame: int in POTION_TICKS:
		await tree.physics_frame
		poll.call()
	var health_id: int = CombatCatalog.ability_id(&"potion_health")
	var cooldown: int = CombatCatalog.tables().consumable_cooldown_ticks
	for index: int in cheaters.size():
		var client: NetClient = cheaters[index]
		var net_id: int = client.get_net_id()
		var combat: CombatState = _server.get_registry().get_entity(net_id).get_character().combat
		var list: Array = drinks.get(net_id, [])
		var peer: ServerPeer = _server.get_peer(_peer_id_of(net_id))
		var most: int = ceili(float(_server.get_tick() - join_ticks.get(net_id, 0) + 1) / float(cooldown))
		print("[trampa potion] %s: tragos %s, cargas finales (%d, %d), curaciones %d, curado %d, sospecha %d" % [
				"plantilla" if index == 0 else "1 y 0", list, combat.charges_of(0), combat.charges_of(1),
				regens.get(net_id, 0), healed.get(net_id, 0), peer.suspicion_score])
		if index == 0:
			assert_true(list.size() >= 2, "con cargas, bebe dos veces en %d ticks (%d)" % [POTION_TICKS, list.size()])
			assert_true(list.size() <= most, "pero una vez por reutilización compartida: %d <= %d" % [list.size(), most])
			for i: int in range(1, list.size()):
				var previous: Vector2i = list[i - 1]
				var commit: int = previous.x + CombatCatalog.ability(previous.y).cast_ticks
				assert_true((list[i] as Vector2i).x >= commit + cooldown,
						"el trago %d espera a la reutilización compartida del anterior" % i)
		else:
			if assert_eq(list.size(), 1, "con 1 carga de vida y 0 de resistencia, un trago y ninguno más"):
				assert_eq((list[0] as Vector2i).y, health_id, "el de vida: la de resistencia no tiene cargas")
			assert_eq([combat.charges_of(0), combat.charges_of(1)], [0, 0], "sin cargas al final")
			assert_eq(regens.get(net_id, 0), 1, "una sola curación: ninguna sin su carga")
			assert_true(healed.get(net_id, 0) <= 300, "ni más vida que la de una poción (%d)" % healed.get(net_id, 0))
		assert_true(regens.get(net_id, 0) <= list.size(), "ninguna curación sin trago")
		assert_eq(peer.suspicion_score, 0)
		assert_eq(peer.strikes_total, 0)
		assert_eq(client.get_stats()["unexplained_diffs"], 0,
				"y su predicción no falla: cargas y reutilización se predicen")


func test_interact_cheater_far_from_anyone_revives_and_executes_nobody() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	_cheater = _add_bot(VARDHEIM, 2, "interact")
	_honest = _add_bot(SOLMARCH, 1, "")
	if not assert_true(await _wait_until(_both_in_world), "entran los dos"):
		return
	await wait_physics_frames(30)
	# El honrado, enemigo, queda derribado a 4 m: más que el alcance de 2 m de rematar.
	_server.teleport(_cheater.get_net_id(), Vector3(0.0, 0.05, 0.0))
	_server.teleport(_honest.get_net_id(), Vector3(0.0, 0.05, -4.0))
	await wait_physics_frames(10)
	var honest: Combatant = _server.get_combat().get_combatant(_honest.get_net_id())
	assert_true(_server.get_combat().down(honest, _server.get_tick() + 1), "el honrado queda derribado")
	var interacts: Array[int] = [0]
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
		if event.event == NetMessages.EntityEvent.Kind.INTERACT:
			interacts[0] += 1)
	var actions: Dictionary[int, bool] = {}
	for _frame: int in 300:
		await tree.physics_frame
		actions[_server.get_registry().get_entity(_cheater.get_net_id()).get_character().combat.action] = true
	var downed: DownedSystem = _server.get_combat().downed
	var peer: ServerPeer = _server.get_peer(_peer_id_of(_cheater.get_net_id()))
	print("[trampa interact] INTERACT %d, empezados %d, acciones %s, sospecha %d" % [interacts[0],
			downed.stats[&"interact_started"], actions.keys(), peer.suspicion_score])
	assert_eq(interacts[0], 0, "ni levantar ni rematar: nadie a su alcance")
	assert_eq(downed.stats[&"interact_started"], 0)
	assert_false(actions.has(CombatState.Action.EXECUTE) or actions.has(CombatState.Action.REVIVE),
			"el tramposo nunca entra en REVIVE ni EXECUTE")
	assert_true(honest.is_downed(), "el derribado sigue derribado")
	assert_eq(peer.suspicion_score, 0)
	assert_eq(peer.strikes_total, 0)
	assert_eq(_cheater.get_stats()["unexplained_diffs"], 0, "y su predicción no falla")
	assert_eq(_honest.get_stats()["unexplained_diffs"], 0, "ni la del derribado")
