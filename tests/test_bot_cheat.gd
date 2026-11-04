extends TestCase
## The cheating bot ([BotCheater], [code]--bot-cheat[/code]; docs/red.md, sections 12 and 16; TEC-46)
## against a real [ZoneServer] in the same process, with ENet over 127.0.0.1: an honest bot and a
## cheater, each in its own [SubViewport] with its own physics world. One method per mode:
## [br]- [code]version[/code]: REJECT VERSION and the cheater never gets in;
## [br]- [code]future[/code]: inputs outside the window are dropped and counted (TOO_EARLY), with no
## warnings and no effect: the server applies only the honest ones, so the cheater predicts without failures;
## [br]- [code]dupes[/code]: the first copy wins, the honest one: no prediction failures;
## [br]- [code]garbage[/code] and [code]flood[/code]: warnings, kick NOTICE and removal.
## [br]- [code]rewind[/code], [code]reach[/code] and [code]rate[/code] (combat, TEC-14): the bot fights
## a dummy with the game's rules, but with the view falsified to 40 ticks, from 5 m or mashing
## PRIMARY. None does extra damage: the excessive rewind is not tested and adds suspicion; from 5 m there is
## no hit; and mashing the button does not hit faster than the data's combo.
## [br]- [code]reuse[/code], [code]potion[/code] and [code]interact[/code] (phase 4; docs/habilidades.md, section 4.7):
## mashing an ability on cooldown gives one hit per cooldown; mashing the potions, one sip per
## shared cooldown and with charges; mashing INTERACT far from everyone neither revives nor finishes off anyone. No
## extra effect or suspicion.
## [br]In every mode the honest bot stays in the world, with no warnings or prediction failures, and the
## server logs no errors (the runner fails on any engine error).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const REPORT_FILE: String = "test_bot_cheat_report.json"
## Physics frames at most that a condition is waited for (10 s).
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


# --- Helpers --------------------------------------------------------------------------------

## Server with the flat zone, an honest bot and a cheater of the [param cheat] mode.
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


## Server-side record of the player with that net_id (empty if it does not exist).
func _server_record(net_id: int) -> Dictionary:
	var path: String = NetHarness.build_path(REPORT_FILE)
	assert_eq(_server.write_report(path), OK, "the server's report is written")
	var report: Dictionary = NetHarness.read_report(path)
	for entry: Dictionary in report.get("player_list", []):
		if int(entry.get("net_id", 0)) == net_id:
			return entry
	return {}


func _server_report() -> Dictionary:
	var path: String = NetHarness.build_path(REPORT_FILE)
	_server.write_report(path)
	return NetHarness.read_report(path)


## The honest bot carries on as if nothing happened: inside the world, no warnings and no prediction failures.
func _assert_honest_bot_untouched(min_matches: int = 50) -> void:
	assert_eq(_honest.get_state(), NetClient.State.IN_WORLD, "the honest bot is still in the world")
	var peer: ServerPeer = _server.get_peer(_peer_id_of(_honest.get_net_id()))
	if assert_not_null(peer, "and the server still has it"):
		assert_eq(peer.strikes_total, 0, "without any warning")
	var stats: Dictionary = _honest.get_stats()
	assert_eq(stats["unexplained_diffs"], 0, "without prediction failures: %s" % [stats])
	assert_true(stats["matches"] > min_matches,
			"and with many exact matches (%d)" % stats["matches"])
	assert_eq(stats["hard_resets"], 0, "nor hard resets")


## peer_id of the server-side player with that net_id (0 if it does not exist).
func _peer_id_of(net_id: int) -> int:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.entity != null and peer.entity.net_id == net_id:
			return peer_id
	return 0


# --- One method per mode -----------------------------------------------------------------------

func test_version_cheater_is_rejected_and_never_enters() -> void:
	await _start_scenario("version")
	var rejections: Array[Vector2i] = []
	var texts: Array[String] = []
	_cheater.rejected.connect(func(result: int, text: String) -> void:
		rejections.append(Vector2i(result, 0))
		texts.append(text))
	var honest_in: bool = await _wait_until(func() -> bool:
		return _honest.get_state() == NetClient.State.IN_WORLD)
	assert_true(honest_in, "the honest bot gets in")
	var rejected: bool = await _wait_until(func() -> bool: return not rejections.is_empty())
	if not assert_true(rejected, "the cheater receives a REJECT"):
		return
	assert_eq(rejections[0].x, NetProtocol.Result.VERSION, "for the protocol version")
	assert_eq(texts[0], NetProtocol.result_text(NetProtocol.Result.VERSION), "with its text in Spanish")
	assert_eq(_cheater.get_state(), NetClient.State.CLOSED, "and its session is closed")
	assert_null(_cheater.get_character(), "without ever getting a character")
	await wait_physics_frames(120)
	assert_eq(_server.get_player_count(), 1, "the server only has the honest one")
	assert_eq((_server_report().get("rejects", {}) as Dictionary).size(), 1, "and counts a rejection")
	_assert_honest_bot_untouched()


func test_future_cheater_has_no_effect_and_gains_nothing() -> void:
	await _start_scenario("future")
	assert_true(await _wait_until(_both_in_world), "both get in")
	await wait_physics_frames(300)
	_assert_honest_bot_untouched()
	var record: Dictionary = _server_record(_cheater.get_net_id())
	assert_true(int(record.get("too_early_inputs", 0)) > 200,
			"the server drops and counts the future inputs (%s)" % record.get("too_early_inputs"))
	assert_eq(int(record.get("strikes", -1)), 0, "but they are not a warning: excess lead time is a network matter")
	assert_false(bool(record.get("kicked", true)), "nor a kick")
	assert_eq(_cheater.get_state(), NetClient.State.IN_WORLD, "the cheater keeps playing")
	assert_true(_cheater.get_stats()["cheat_packets"] > 200, "and it really was sending future inputs")
	# No advantage: the server applies only the honest inputs, so its prediction does not fail.
	var stats: Dictionary = _cheater.get_stats()
	assert_eq(stats["unexplained_diffs"], 0, "the server and the cheater's prediction match: %s" % [stats])
	assert_true(stats["matches"] > 50, "with many exact matches")


func test_dupes_cheater_first_copy_wins() -> void:
	await _start_scenario("dupes")
	assert_true(await _wait_until(_both_in_world), "both get in")
	await wait_physics_frames(300)
	_assert_honest_bot_untouched()
	var record: Dictionary = _server_record(_cheater.get_net_id())
	assert_eq(int(record.get("strikes", -1)), 0, "distinct copies are not a warning")
	assert_false(bool(record.get("kicked", true)), "nor a kick")
	assert_true(_cheater.get_stats()["cheat_packets"] > 200, "but it did send them")
	var stats: Dictionary = _cheater.get_stats()
	assert_eq(stats["unexplained_diffs"], 0,
			"the first copy wins, the honest one: the prediction always hits: %s" % [stats])
	assert_true(stats["matches"] > 50, "with many exact matches")
	assert_eq(int(record.get("late_inputs", -1)), 0, "and no input arrives late")


func test_garbage_cheater_is_kicked() -> void:
	await _start_scenario("garbage")
	await _assert_cheater_is_kicked()


func test_flood_cheater_is_kicked() -> void:
	await _start_scenario("flood")
	await _assert_cheater_is_kicked()


## The garbage or flood cheater receives the kick NOTICE and is removed; the honest one
## sees its DESPAWN and notices nothing else.
func _assert_cheater_is_kicked() -> void:
	assert_true(await _wait_until(_both_in_world), "both get in")
	var cheater_id: int = _cheater.get_net_id()
	var notices: Array[String] = []
	_cheater.notice_received.connect(func(code: int, text: String) -> void:
		if code == NetProtocol.NoticeCode.KICK:
			notices.append(text))
	var kicked: bool = await _wait_until(func() -> bool:
		return _cheater.get_state() == NetClient.State.CLOSED)
	if not assert_true(kicked, "the cheater ends up disconnected"):
		return
	assert_eq(notices.size(), 1, "after a kick NOTICE")
	assert_true(notices[0].contains("Expulsado"), "in Spanish: %s" % notices[0])
	assert_true(_cheater.get_last_notice_text().contains("Expulsado"), "and it is the reason for the disconnection")
	var report: Dictionary = _server_report()
	var kicks: Array = report.get("kicks", [])
	if assert_eq(kicks.size(), 1, "the server logs a single kick"):
		assert_eq(int((kicks[0] as Dictionary).get("net_id", 0)), cheater_id, "the cheater's")
		assert_false(String((kicks[0] as Dictionary).get("reason", "")).is_empty(), "with its reason")
	assert_true((report.get("strikes", {}) as Dictionary).get("total", 0) >= 50,
			"after at least 50 warnings")
	var record: Dictionary = _server_record(cheater_id)
	assert_true(bool(record.get("kicked", false)), "the player's record marks it as kicked")
	await wait_physics_frames(60)
	assert_eq(_server.get_player_count(), 1, "only the honest one remains")
	assert_null(_server.get_registry().get_entity(cheater_id), "and the cheater's character disappeared")
	assert_eq(_honest.get_remote_world().get_view_count(), 0, "the honest one no longer sees it")
	_assert_honest_bot_untouched(20)


# --- Combat modes: rewind, reach and rate -----------------------------------------------------

## Ticks the bots of the combat tests fight once placed.
const FIGHT_TICKS: int = 600
## Where the dummy is and at what distance (m) the bot under test starts.
const DUMMY_POSITION := Vector3(0.0, 0.0, -3.0)
const CHEATER_START := Vector3(0.0, 0.05, 3.0)
const CONTROL_START := Vector3(0.0, 0.05, -10.0)

## net_id of the attacker -> {"hits": hits on the dummy, "damage": announced damage} according to the server.
var _tally: Dictionary = {}
var _dummy_id: int = 0


## Server with a dummy facing +Z, the cheater of mode [param cheat] (Vardheim) placed 6 m from it and,
## if [param with_control], an honest bot with the combat brain (the same one the rewind mode uses) that
## attacks it from the other side.
## Waits for the bots to be in the world.
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
		# Same combat brain as the rewind cheater, but one that also sees the dummies, and the
		# real view.
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


## Horizontal distance (m) from the server-side character of [param client] to the dummy.
func _distance_to_dummy(client: NetClient) -> float:
	var bot: Vector3 = _server.get_registry().get_entity(client.get_net_id()).get_position()
	var dummy: Vector3 = _server.get_registry().get_entity(_dummy_id).get_position()
	return Vector2(bot.x - dummy.x, bot.z - dummy.z).length()


func test_rewind_cheater_deals_no_damage_and_its_suspicion_score_rises() -> void:
	if not assert_true(await _start_fight("rewind", true), "the fight starts"):
		return
	await wait_physics_frames(FIGHT_TICKS)
	var peer: ServerPeer = _server.get_peer(_peer_id_of(_cheater.get_net_id()))
	var control: ServerPeer = _server.get_peer(_peer_id_of(_honest.get_net_id()))
	print("[trampa rewind] golpes lanzados %d, rechazados %d, sospecha %d, daño %d; control: %d golpes, %d de daño" % [
			peer.swings, peer.rewind_rejects, peer.suspicion_score, _damage_of(_cheater), control.swings,
			_damage_of(_honest)])
	assert_true(peer.swings >= 4, "the cheater throws real hits (%d)" % peer.swings)
	assert_eq(_hits_of(_cheater), 0, "none of them damages the dummy")
	assert_eq(_damage_of(_cheater), 0)
	assert_true(peer.rewind_rejects >= 4, "the server rejects them because of the cap (%d)" % peer.rewind_rejects)
	assert_eq(peer.suspicion_score, peer.rewind_rejects, "and suspicion rises with each one")
	assert_eq(peer.strikes_total, 0, "without warnings: it is not an illegal packet")
	assert_eq(_cheater.get_state(), NetClient.State.IN_WORLD, "keeps playing")
	assert_eq(_cheater.get_stats()["cheat_packets"], 0, "sends no extra traffic")
	# The control: the same combat brain with the real view does hit and raises no suspicion.
	assert_true(control.swings >= 4, "the honest one attacks too (%d)" % control.swings)
	assert_true(_hits_of(_honest) >= 3, "and its hits do land (%d)" % _hits_of(_honest))
	assert_eq(control.suspicion_score, 0, "without suspicion")
	var report: Dictionary = _server_report()
	var suspicious: Array = (report.get("combat", {}) as Dictionary).get("suspicious", [])
	if assert_eq(suspicious.size(), 1, "the server's report points at only one"):
		assert_eq(int((suspicious[0] as Dictionary).get("net_id", 0)), _cheater.get_net_id(), "the cheater")
	_assert_client_untouched(_honest)


func test_reach_cheater_swinging_from_five_meters_never_connects() -> void:
	if not assert_true(await _start_fight("reach", false), "the fight starts"):
		return
	var closest: float = INF
	for _frame: int in FIGHT_TICKS:
		await tree.physics_frame
		closest = minf(closest, _distance_to_dummy(_cheater))
	var peer: ServerPeer = _server.get_peer(_peer_id_of(_cheater.get_net_id()))
	print("[trampa reach] golpes lanzados %d, aciertos %d, distancia mínima %.2f m" % [
			peer.swings, _hits_of(_cheater), closest])
	assert_true(peer.swings >= 5, "throws hits nonstop (%d)" % peer.swings)
	assert_eq(_hits_of(_cheater), 0, "none connects")
	assert_eq(_server.get_combat().stats[&"hits"], 0, "the server records no impact")
	assert_eq(_damage_of(_cheater), 0)
	assert_true(closest > 4.0, "stays far away: the minimum distance was %.2f m" % closest)
	assert_eq(peer.suspicion_score, 0, "the inputs are legitimate: there is nothing to suspect")
	assert_eq(peer.rewind_rejects, 0)
	assert_eq(peer.strikes_total, 0)
	assert_eq(_cheater.get_stats()["unexplained_diffs"], 0, "and its prediction does not fail")


func test_rate_cheater_mashing_primary_cannot_hit_faster_than_the_combo() -> void:
	if not assert_true(await _start_fight("rate", false), "the fight starts"):
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
	# The fastest combo the data allows, plus one hit for starting mid-cycle.
	var most_hits: int = ceili(float(FIGHT_TICKS) * float(weapon.light_ids.size()) / float(combo_ticks)) + 1
	var peer: ServerPeer = _server.get_peer(_peer_id_of(_cheater.get_net_id()))
	print("[trampa rate] ataques lanzados %d, aciertos %d (tope %d), daño %d" % [
			peer.swings, _hits_of(_cheater), most_hits, _damage_of(_cheater)])
	assert_true(_hits_of(_cheater) >= 5, "hits (%d hits)" % _hits_of(_cheater))
	assert_true(_hits_of(_cheater) <= most_hits,
			"but no more than the combo: %d <= %d" % [_hits_of(_cheater), most_hits])
	var most_damage: int = (FIGHT_TICKS / combo_ticks + 1) * combo_damage
	assert_true(_damage_of(_cheater) <= most_damage,
			"nor more damage than the continuous combo: %d <= %d" % [_damage_of(_cheater), most_damage])
	assert_true(peer.swings <= most_hits + 2, "nor launches more attacks than the combo allows (%d)" % peer.swings)
	assert_eq(peer.suspicion_score, 0, "mashing the button is not an offense")
	assert_eq(peer.strikes_total, 0)
	assert_eq(_cheater.get_state(), NetClient.State.IN_WORLD)
	assert_eq(_cheater.get_stats()["unexplained_diffs"], 0, "and its prediction does not fail")


## A test client with no warnings or prediction failures.
func _assert_client_untouched(client: NetClient) -> void:
	var stats: Dictionary = client.get_stats()
	assert_eq(stats["unexplained_diffs"], 0, "without prediction failures: %s" % [stats])
	assert_eq(client.get_state(), NetClient.State.IN_WORLD)


# --- Phase 4 modes: reuse, potion and interact (docs/habilidades.md, section 4.7) -------------

## Ticks the reuse cheater fights: more than one shield bash cooldown (738 = 720 + 18).
const REUSE_FIGHT_TICKS: int = 900
## Ticks the potion cheater mashes the potions: more than the shared cooldown (1200).
const POTION_TICKS: int = 1300


func test_reuse_cheater_mashing_an_ability_on_cooldown_gets_one_use_per_cooldown() -> void:
	if not assert_true(await _start_fight("reuse", false), "the fight starts"):
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
	assert_true(bash_hits.size() >= 1, "the shield bash goes out (%d)" % bash_hits.size())
	assert_true(bash_hits.size() <= most, "but no more than its cooldown allows: %d <= %d" % [bash_hits.size(),
			most])
	for index: int in range(1, bash_hits.size()):
		assert_true(bash_hits[index] - bash_hits[index - 1] >= period,
				"two shield bashes separated by at least %d ticks (%d)" % [period, bash_hits[index] - bash_hits[index - 1]])
	assert_eq(peer.suspicion_score, 0, "mashing the button is not an offense")
	assert_eq(peer.strikes_total, 0)
	assert_eq(_cheater.get_state(), NetClient.State.IN_WORLD)
	assert_eq(_cheater.get_stats()["unexplained_diffs"], 0, "and its prediction does not fail: the cooldown is predicted")


## Two potion cheaters at once (H5 review: with the template's 5 charges, in 1300 ticks it does not
## reach 0 and "no heal without a charge" was not being tested). The first, with its template's charges:
## two sips separated by the shared cooldown. The second starts with 1 health charge and 0 stamina:
## one health sip and no more in the whole window, even though the cooldown ends within it.
func test_potion_cheater_drinks_only_with_charges_and_off_the_shared_cooldown() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	# What each one drinks is counted from when it appears: it starts mashing as soon as it enters.
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
		# Wounded from the start, so the health potion has something to heal.
		combatant.take_damage(600, _server.get_tick())
		if joined.size() == 2:
			# The second: 1 health and 0 stamina, with its LOADOUT (the client explains it, like command 16). Without a
			# platform it is an ephemeral character with an inventory (progresion.md §9.4, P5b) and its charges are the potions in
			# its bag: the surplus ones are removed first.
			var progress: PlayerProgress = _server.get_progress().get_player(net_id)
			progress.lose_items(&"potion_health", progress.record.inventory.count_of(&"potion_health") - 1,
					EconomyReason.CONSUME)
			progress.lose_items(&"potion_stamina", progress.record.inventory.count_of(&"potion_stamina"),
					EconomyReason.CONSUME)
			var character: PlayerCharacter = combatant.get_character()
			ActionMachine.set_charges(character.combat, CombatState.pack_charges(1, 0))
			CombatDirector.commit_state(character)
			_server.get_combat().announce_loadout(combatant, _server.get_tick(), false))
	# The sips that each one's server state starts ((start tick, consumable id)), looked at on
	# every tick since it enters.
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
			return _cheater.get_state() == NetClient.State.IN_WORLD), "the first cheater gets in"):
		return
	var limited: NetClient = _add_bot(VARDHEIM, 3, "potion")
	if not assert_true(await _wait_until(func() -> bool:
			poll.call()
			return limited.get_state() == NetClient.State.IN_WORLD), "and the second"):
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
			assert_true(list.size() >= 2, "with charges, it drinks twice in %d ticks (%d)" % [POTION_TICKS, list.size()])
			assert_true(list.size() <= most, "but once per shared cooldown: %d <= %d" % [list.size(), most])
			for i: int in range(1, list.size()):
				var previous: Vector2i = list[i - 1]
				var commit: int = previous.x + CombatCatalog.ability(previous.y).cast_ticks
				assert_true((list[i] as Vector2i).x >= commit + cooldown,
						"sip %d waits for the previous one's shared cooldown" % i)
		else:
			if assert_eq(list.size(), 1, "with 1 health charge and 0 stamina, one sip and no more"):
				assert_eq((list[0] as Vector2i).y, health_id, "the health one: the stamina one has no charges")
			assert_eq([combat.charges_of(0), combat.charges_of(1)], [0, 0], "no charges left at the end")
			assert_eq(regens.get(net_id, 0), 1, "a single heal: none without its charge")
			assert_true(healed.get(net_id, 0) <= 300, "nor more health than one potion's (%d)" % healed.get(net_id, 0))
		assert_true(regens.get(net_id, 0) <= list.size(), "no heal without a sip")
		assert_eq(peer.suspicion_score, 0)
		assert_eq(peer.strikes_total, 0)
		assert_eq(client.get_stats()["unexplained_diffs"], 0,
				"and its prediction does not fail: charges and cooldown are predicted")


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
	if not assert_true(await _wait_until(_both_in_world), "both get in"):
		return
	await wait_physics_frames(30)
	# The honest one, an enemy, ends up knocked down at 4 m: farther than the 2 m finishing reach.
	_server.teleport(_cheater.get_net_id(), Vector3(0.0, 0.05, 0.0))
	_server.teleport(_honest.get_net_id(), Vector3(0.0, 0.05, -4.0))
	await wait_physics_frames(10)
	var honest: Combatant = _server.get_combat().get_combatant(_honest.get_net_id())
	assert_true(_server.get_combat().down(honest, _server.get_tick() + 1), "the honest one ends up knocked down")
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
	assert_eq(interacts[0], 0, "neither reviving nor finishing off: no one within its reach")
	assert_eq(downed.stats[&"interact_started"], 0)
	assert_false(actions.has(CombatState.Action.EXECUTE) or actions.has(CombatState.Action.REVIVE),
			"the cheater never enters REVIVE or EXECUTE")
	assert_true(honest.is_downed(), "the knocked-down one is still knocked down")
	assert_eq(peer.suspicion_score, 0)
	assert_eq(peer.strikes_total, 0)
	assert_eq(_cheater.get_stats()["unexplained_diffs"], 0, "and its prediction does not fail")
	assert_eq(_honest.get_stats()["unexplained_diffs"], 0, "nor the knocked-down one's")
