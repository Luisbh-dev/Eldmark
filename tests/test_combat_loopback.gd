extends TestCase
## Combat end to end with real ENet over 127.0.0.1, in a single process (docs/combate.md,
## sections 4 to 6; CMB-10): a [ZoneServer] and several bot [NetClient]s, each in its own
## [SubViewport] with its own physics world and its own [NetTransport].
## [br][br]
## One bot attacks another: the attacker, the victim and a third party receive the same HIT and the extra block
## of the victim's snapshots carries its lowered health. With real rewind: the real
## client's inputs carry its [code]view_offset_q[/code] and the server accepts them within the cap. The
## third scenario hits a dummy: everyone sees its health drop in the snapshot ledger.
## [br][br]
## The bots do not read the ENTITY_EVENTs (that belongs to the combat client): the test listens to the transport
## packets of each one.
## [br][br]
## [b]Rewind with a bad network[/b] (CMB-09, TEC-14; docs/combate.md, sections 4.3 and 4.5): the server
## carries a [NetSim] of 150 ms RTT and 30 ms jitter (the client's does not count towards the cap: networking.md,
## section 10) and two attackers hit a target running sideways. [SwingRecorder] stores, in each
## input the attacker generates, where it draws the target (its [code]render_tick[/code]) and, with its predicted
## state, computes which hits it [i]saw[/i] inside the arc; the server must confirm at least 95 %.
## With a [code]view_offset_q[/code] of 40 ticks against a still target, no hit goes through (cap of 24 plus the
## slack of 8 that is clamped without rejecting).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 600
## Server network simulator in the rewind tests: 150 ms RTT and 30 ms jitter per direction
## (the TEC-14 criterion), delay in both directions. With 200 ms 95 % is no longer reached: the cap of
## 24 ticks does not cover the margin of [TickSync] and interpolation (docs/networking.md, section 10).
const REWIND_NET_SIM: String = "rtt=150,jitter=30,seed=5"
## Distance (m) at which each attacker's target is and half-width (m) of its sideways run.
const REWIND_DISTANCE: float = 2.7
const REWIND_RUN_HALF_WIDTH: float = 3.6
## Ticks between two attacker presses (the light attack lasts 36) and how far ahead (ticks) of the target it
## aims (the active hit lands ~15 ticks after pressing).
const REWIND_CYCLE_TICKS: int = 48
const REWIND_LEAD_TICKS: float = 15.0
## Ticks since the press from which the attacker backs off (light attack recovery) and since
## which it returns to its place with free legs; maximum distance (m) to the target at which it presses and
## probability per tick of pressing when it has it within reach and the cycle has already passed.
const REWIND_RECOVERY_FROM: int = 20
const REWIND_FREE_FROM: int = 36
const REWIND_PRESS_DISTANCE: float = 3.0
const REWIND_PRESS_CHANCE: float = 0.07
## Measurement ticks of the 95 % test and minimum hits seen for the figure to mean anything.
const REWIND_MEASURED_TICKS: int = 900
const REWIND_MIN_SEEN_SWINGS: int = 16
## Fraction of the seen hits that the server must confirm.
const REWIND_MIN_CONFIRMED: float = 0.95
## Rewind ticks that the attacker of the cap test fakes: more than the cap of 24 and its slack
## ([constant CombatResolver.REWIND_REJECT_SLACK_TICKS]), which is clamped without rejecting (phase 4 revision: it was 30).
const CHEAT_VIEW_TICKS: int = 40

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _port: int = 0
var _clients: Array[NetClient] = []
var _client_viewports: Array[SubViewport] = []
var _listeners: Array[Listener] = []


## Listens to the packets that reach a client and stores the events and the last snapshot.
class Listener:
	extends RefCounted

	var events: Array[NetMessages.EntityEvent] = []
	var snapshots: Array[NetMessages.Snapshot] = []

	func _init(transport: NetTransport) -> void:
		transport.packet_received.connect(_on_packet)

	func _on_packet(_peer_id: int, bytes: PackedByteArray) -> void:
		match NetMessages.peek_type(bytes):
			NetProtocol.MSG_ENTITY_EVENT:
				var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
				if event != null:
					events.append(event)
			NetProtocol.MSG_SNAPSHOT:
				var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
				if snapshot != null:
					snapshots.append(snapshot)

	func hits() -> Array[NetMessages.EntityEvent]:
		var found: Array[NetMessages.EntityEvent] = []
		for event: NetMessages.EntityEvent in events:
			if event.event == NetMessages.EntityEvent.Kind.HIT:
				found.append(event)
		return found

	func last_snapshot() -> NetMessages.Snapshot:
		return snapshots[snapshots.size() - 1] if not snapshots.is_empty() else null


## What an attacker sees while playing and which hits it saw inside the arc (see the file
## documentation). Each input it generates stores where it draws the target at that moment; [method evaluate]
## (once per physics frame) crosses it with the state it predicted for that tick: if the hit was
## active and the drawn target falls in the sector, the attacker [i]saw[/i] that hit land. It also notes
## whether the target would have been inside with its [b]server position at that same tick[/b] (which
## would prove a server without rewind).
class SwingRecorder:
	extends RefCounted

	var client: NetClient
	var server: ZoneServer
	var target_id: int = 0
	## Input tick -> position with which it drew the target when generating it.
	var views: Dictionary[int, Vector3] = {}
	## action_tick of the hit -> {"seen": saw it inside the arc, "now": the target was inside on the
	## server without rewinding}.
	var swings: Dictionary[int, Dictionary] = {}

	func _init(p_client: NetClient, p_server: ZoneServer, p_target_id: int) -> void:
		client = p_client
		server = p_server
		target_id = p_target_id
		var controller: LocalPlayerController = client.get_meta(&"controller") as LocalPlayerController
		controller.input_generated.connect(_on_input_generated)

	func _on_input_generated(input: PlayerInput) -> void:
		var world: RemoteWorld = client.get_remote_world()
		var view: RemotePlayerView = world.get_view(target_id)
		if view == null or not view.is_drawn() or world.get_last_drawn_render_tick() <= 0.0:
			return
		views[input.tick] = view.get_drawn_position()

	## Crosses the generated inputs with the predicted state (only the ticks the server has already simulated,
	## so its history can be consulted).
	func evaluate() -> void:
		var prediction: ClientPrediction = client.get_prediction()
		var limit: int = mini(prediction.get_predicted_tick(), server.get_tick())
		var done: Array[int] = []
		for tick: int in views:
			if tick > limit:
				continue
			done.append(tick)
			var state: PlayerState = prediction.get_predicted_state(tick)
			if state == null or not ActionMachine.is_attack_active(state.combat, tick):
				continue
			var attack: AttackTicks = CombatCatalog.attack(state.combat.action_id)
			if attack == null or attack.shape == null:
				continue
			var swing: Dictionary = swings.get(state.combat.action_tick, {"seen": false, "now": false})
			if _inside(state, attack, views[tick]):
				swing["seen"] = true
			var current: StateHistory.Sample = server.get_history().sample(target_id, float(tick))
			if current != null and _inside(state, attack, current.position):
				swing["now"] = true
			swings[state.combat.action_tick] = swing
		for tick: int in done:
			views.erase(tick)

	func _inside(state: PlayerState, attack: AttackTicks, feet: Vector3) -> bool:
		return HitShapes.sector_hits_capsule(state.position, state.yaw, attack.shape, feet,
				HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT)

	## Hits it saw land.
	func seen_swings() -> Array[int]:
		var found: Array[int] = []
		for action_tick: int in swings:
			if swings[action_tick]["seen"]:
				found.append(action_tick)
		return found

	## Of those it saw land, how many would also have landed without rewinding.
	func seen_and_current() -> int:
		var count: int = 0
		for action_tick: int in swings:
			if swings[action_tick]["seen"] and swings[action_tick]["now"]:
				count += 1
		return count


func before_each() -> void:
	_root = Node.new()
	_root.name = "CombatLoopback"
	tree.root.add_child(_root)


func after_each() -> void:
	_listeners.clear()
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


# --- Helpers ----------------------------------------------------------------------------------

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
	await wait_physics_frames(3)


func _add_bot(realm: int, bot_seed: int) -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
	_client_viewports.append(viewport)
	var client: NetClient = NetHarness.start_bot(viewport, _port, realm, bot_seed)
	_clients.append(client)
	_listeners.append(Listener.new(client.get_meta(&"transport") as NetTransport))
	return client


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


## Changes what the bot does: [param script] is [code](tick, position, yaw) -> PlayerInput[/code].
func _set_script(client: NetClient, script: Callable) -> void:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = script
	(client.get_meta(&"controller") as LocalPlayerController).set_bot(brain)


func _idle(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	return input


# --- Tests ------------------------------------------------------------------------------------

func test_a_bot_hits_another_and_attacker_victim_and_a_third_get_the_same_event() -> void:
	await _start_server()
	var attacker: NetClient = _add_bot(VARDHEIM, 1)
	var victim: NetClient = _add_bot(SOLMARCH, 2)
	var third: NetClient = _add_bot(VARDHEIM, 3)
	if not assert_true(await _wait_until(_all_in_world), "the three bots enter the world"):
		return
	await wait_physics_frames(30)
	var attacker_id: int = attacker.get_net_id()
	var victim_id: int = victim.get_net_id()
	# First their walk is removed (so they do not move), then they are placed.
	var press: int = _server.get_tick() + 150
	_set_script(attacker, func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = 0.0
		if tick >= press and tick < press + 2:
			input.buttons = PlayerInput.PRIMARY
		return input)
	_set_script(victim, func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI
		return input)
	_set_script(third, _idle)
	await wait_physics_frames(20)
	_server.teleport(attacker_id, Vector3(0.0, 0.05, 0.0))
	_server.teleport(victim_id, Vector3(0.0, 0.05, -1.5))
	_server.teleport(third.get_net_id(), Vector3(10.0, 0.05, 10.0))
	_server.get_registry().get_entity(victim_id).get_character().yaw = PI
	var delivered: bool = await _wait_until(func() -> bool:
		return not _listeners[0].hits().is_empty() and not _listeners[1].hits().is_empty() \
				and not _listeners[2].hits().is_empty())
	if not assert_true(delivered, "all three receive the HIT"):
		return
	var first: NetMessages.EntityEvent = _listeners[0].hits()[0]
	for index: int in [1, 2]:
		assert_eq(_listeners[index].hits()[0].encode(), first.encode(),
				"client %d receives the same HIT, byte for byte" % index)
	assert_eq(first.attacker, attacker_id, "from the attacker")
	assert_eq(first.net_id, victim_id, "to the victim")
	assert_eq(first.amount, 90, "a frontal light attack")
	assert_eq(first.attack_id, CombatCatalog.attack_id(&"sword_light_1"))
	assert_eq(first.hit_flags, 0)
	assert_eq(_listeners[0].hits().size(), 1, "and a single hit per attack")
	# A real client's rewind is not rejected: the inputs carry their view and fall within the cap.
	assert_eq(_server.get_combat().stats[&"rewind_rejected"], 0, "no excessive rewind")
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_eq(peer.suspicion_score, 0, "and no suspicion")
	# The victim's health drops in its extra block and in the ledger that the others see.
	await wait_physics_frames(12)
	var own: NetMessages.Snapshot = _listeners[1].last_snapshot()
	assert_not_null(own.own_state, "the snapshot carries its own state")
	assert_eq(own.health, 910, "the victim's extra block carries its health")
	assert_eq(own.max_health, 1000)
	assert_true(own.is_in_combat())
	var seen: EntityRecord = null
	for record: EntityRecord in _listeners[2].last_snapshot().records:
		if record.net_id == victim_id:
			seen = record
	if assert_not_null(seen, "the third party sees the victim"):
		assert_eq(seen.health_q, EntityRecord.quantize_health(910, 1000), "with its health in the ledger")
	assert_eq(_listeners[0].last_snapshot().health, 1000, "the attacker loses no health")
	# The sending of events has its measurement section and its bytes in the report (load tests).
	var sections: Dictionary = _server.get_metrics().summary()["sections"]
	assert_true(sections.has("combat_events"), "the event-sending section (%s)" % [sections.keys()])
	assert_true(sections.has("combat_resolve"))
	var report_path: String = NetHarness.build_path("test_combat_loopback_report.json")
	assert_eq(_server.write_report(report_path), OK)
	var combat_report: Dictionary = NetHarness.read_report(report_path).get("combat", {})
	assert_true(int(combat_report.get("event_bytes_sent", 0)) >= 3 * first.encode().size(),
			"at least three packets of that event")


func test_both_players_hit_the_dummy_and_every_snapshot_shows_its_health_drop() -> void:
	await _start_server()
	var first: NetClient = _add_bot(VARDHEIM, 1)
	var second: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _wait_until(_all_in_world)):
		return
	await wait_physics_frames(30)
	var dummy: int = _server.spawn_dummy(Vector3(0.0, 0.0, -1.5), PI)
	assert_true(dummy > 0, "the server places the dummy")
	var press: int = _server.get_tick() + 150
	for client: NetClient in [first, second]:
		_set_script(client, func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
			var input := PlayerInput.new()
			input.tick = tick
			input.look_yaw = 0.0
			if tick >= press and tick < press + 2:
				input.buttons = PlayerInput.PRIMARY
			return input)
	await wait_physics_frames(20)
	_server.teleport(first.get_net_id(), Vector3(0.0, 0.05, 0.0))
	_server.teleport(second.get_net_id(), Vector3(0.6, 0.05, 0.0))
	var done: bool = await _wait_until(func() -> bool:
		return _listeners[0].hits().size() >= 2 and _listeners[1].hits().size() >= 2)
	if not assert_true(done, "both hit the dummy and both see both hits"):
		return
	for listener: Listener in _listeners:
		for event: NetMessages.EntityEvent in listener.hits():
			assert_eq(event.net_id, dummy, "all hits are on the dummy")
	await wait_physics_frames(12)
	var combatant: Combatant = _server.get_combat().get_combatant(dummy)
	assert_eq(combatant.health, 1000 - 180, "two light attacks of 90")
	for listener: Listener in _listeners:
		var record: EntityRecord = null
		for candidate: EntityRecord in listener.last_snapshot().records:
			if candidate.net_id == dummy:
				record = candidate
		if assert_not_null(record, "each client receives the dummy's ledger") and record != null:
			assert_eq(record.kind, NetProtocol.EntityKind.NPC)
			assert_eq(record.health_q, EntityRecord.quantize_health(820, 1000), "with its health")
	assert_eq(_server.get_combat().stats[&"rewind_rejected"], 0)


## Server peer of the player with that net_id (null if it does not exist).
func _peer_of(net_id: int) -> ServerPeer:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.entity != null and peer.entity.net_id == net_id:
			return peer
	return null


## Attacker script: looks at the target it draws (leading by [param lead_ticks] to where it will be when
## the hit lands), presses PRIMARY (two ticks) if it has it within reach and has not pressed within a cycle,
## backs off during the light attack's recovery (what it advanced when throwing it) and between hits returns to its
## place. It presses with a probability per tick ([constant REWIND_PRESS_CHANCE], with the generator
## [code]rng[/code] of [param state]) so it does not always land in the same phase of the target's
## run. [param state] stores what it remembers between ticks ([code]last_press[/code]) and lets the
## test disarm it ([code]armed[/code]).
func _attacker_script(client: NetClient, target_id: int, home: Vector3, lead_ticks: float,
		state: Dictionary) -> Callable:
	return func(tick: int, position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = float(state.get("yaw", 0.0))
		var view: RemotePlayerView = client.get_remote_world().get_view(target_id)
		if view == null or not view.is_drawn():
			return input
		var velocity: Vector3 = view.get_body().velocity
		var aim: Vector3 = view.get_drawn_position() \
				+ Vector3(velocity.x, 0.0, velocity.z) * (lead_ticks / 60.0)
		var to_aim: Vector3 = aim - position
		to_aim.y = 0.0
		input.look_yaw = fposmod(atan2(-to_aim.x, -to_aim.z), TAU)
		state["yaw"] = input.look_yaw
		var since: int = tick - int(state["last_press"])
		if since < 2:
			input.buttons = PlayerInput.PRIMARY
		elif since >= REWIND_CYCLE_TICKS and bool(state.get("armed", true)) \
				and to_aim.length() < REWIND_PRESS_DISTANCE \
				and (state["rng"] as RandomNumberGenerator).randf() < REWIND_PRESS_CHANCE:
			state["last_press"] = tick
			input.buttons = PlayerInput.PRIMARY
		elif since >= REWIND_RECOVERY_FROM and since < REWIND_FREE_FROM:
			input.move = Vector2(0.0, -1.0)
		elif since >= REWIND_FREE_FROM:
			var forward := Vector3(-sin(input.look_yaw), 0.0, -cos(input.look_yaw))
			input.move = Vector2(0.0, clampf((home - position).dot(forward) * 6.0, -1.0, 1.0))
		return input


## Target script: runs across [constant REWIND_RUN_HALF_WIDTH] m on each side, back and forth
## ([param state] stores the direction in [code]dir[/code]).
func _runner_script(state: Dictionary) -> Callable:
	return func(tick: int, position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		if position.x > REWIND_RUN_HALF_WIDTH:
			state["dir"] = -1.0
		elif position.x < -REWIND_RUN_HALF_WIDTH:
			state["dir"] = 1.0
		input.look_yaw = fposmod(-PI / 2.0 * float(state["dir"]), TAU)
		input.move = Vector2(0.0, 1.0)
		input.buttons = PlayerInput.SPRINT
		return input


## Hits from [param recorder] that the server confirmed with a HIT on the target: the ones the attacker
## [param listener] saw arrive with a tick within the hit's duration.
func _confirmed(recorder: SwingRecorder, listener: Listener, attacker_id: int) -> int:
	var confirmed: int = 0
	for action_tick: int in recorder.seen_swings():
		var found: bool = false
		for hit: NetMessages.EntityEvent in listener.hits():
			if hit.attacker == attacker_id and hit.net_id == recorder.target_id \
					and hit.tick >= action_tick and hit.tick < action_tick + 36:
				found = true
				break
		if found:
			confirmed += 1
	return confirmed


## Server combat log (lines already split into columns), after closing it so it is flushed.
func _read_combat_log(path: String) -> Array[PackedStringArray]:
	_server.stop()
	var rows: Array[PackedStringArray] = []
	var lines: PackedStringArray = FileAccess.get_file_as_string(path).strip_edges().split("\n")
	for index: int in range(1, lines.size()):
		rows.append(lines[index].split(","))
	return rows


# --- Rewind with 150 ms RTT -------------------------------------------------------------------

func test_the_server_confirms_at_least_95_percent_of_the_hits_attackers_saw_on_a_lateral_target() -> void:
	var log_path: String = NetHarness.build_path("test_combat_loopback_rewind.csv")
	await _start_server(func(config: ServerConfig) -> void:
		config.net_sim_spec = REWIND_NET_SIM
		config.combat_log_path = log_path)
	var first: NetClient = _add_bot(VARDHEIM, 1)
	var second: NetClient = _add_bot(VARDHEIM, 2)
	var runner: NetClient = _add_bot(SOLMARCH, 3)
	if not assert_true(await _wait_until(_all_in_world, 900), "the three bots enter"):
		return
	await wait_physics_frames(30)
	var target_id: int = runner.get_net_id()
	_server.get_combat().get_combatant(target_id).immortal = true
	# The target runs along z = -REWIND_DISTANCE; one attacker looks at it from z = 0 and the other from the
	# opposite side of its run.
	var homes: Array[Vector3] = [Vector3(0.0, 0.05, 0.0),
			Vector3(0.0, 0.05, -2.0 * REWIND_DISTANCE)]
	var attackers: Array[NetClient] = [first, second]
	var script_states: Array[Dictionary] = []
	for index: int in 2:
		var rng := RandomNumberGenerator.new()
		rng.seed = 100 + index
		script_states.append({"last_press": -1000, "rng": rng})
		_set_script(attackers[index], _attacker_script(attackers[index], target_id, homes[index],
				REWIND_LEAD_TICKS, script_states[index]))
	_set_script(runner, _runner_script({"dir": 1.0}))
	await wait_physics_frames(10)
	_server.teleport(first.get_net_id(), homes[0])
	_server.teleport(second.get_net_id(), homes[1])
	_server.teleport(target_id, Vector3(-REWIND_RUN_HALF_WIDTH, 0.05, -REWIND_DISTANCE))
	await wait_physics_frames(90)

	var recorders: Array[SwingRecorder] = []
	for client: NetClient in attackers:
		recorders.append(SwingRecorder.new(client, _server, target_id))
	for _frame: int in REWIND_MEASURED_TICKS:
		await tree.physics_frame
		for recorder: SwingRecorder in recorders:
			recorder.evaluate()
	# They stop pressing and it waits for the HITs of the hits still in the air to arrive (the time
	# a light attack lasts plus the network delay).
	for state: Dictionary in script_states:
		state["armed"] = false
	for _frame: int in 80:
		await tree.physics_frame
		for recorder: SwingRecorder in recorders:
			recorder.evaluate()

	var seen: int = 0
	var confirmed: int = 0
	var current: int = 0
	for index: int in 2:
		seen += recorders[index].seen_swings().size()
		confirmed += _confirmed(recorders[index], _listeners[index], attackers[index].get_net_id())
		current += recorders[index].seen_and_current()
	print("[rebobinado] vistos %d, confirmados %d, habrían acertado sin rebobinar %d" % [
			seen, confirmed, current])
	assert_true(seen >= REWIND_MIN_SEEN_SWINGS,
			"the attackers see enough hits land for the figure to mean something (%d)" % seen)
	assert_true(float(confirmed) >= REWIND_MIN_CONFIRMED * float(seen),
			"the server confirms at least 95 %% of the seen hits: %d of %d" % [confirmed, seen])
	# Without rewind, some of them would have missed: the test discriminates.
	assert_true(float(current) <= 0.9 * float(seen),
			"without rewind, hits the attacker saw land would fail (%d of %d would land)"
			% [current, seen])
	assert_eq(_server.get_combat().stats[&"rewind_rejected"], 0, "no rewind exceeds the cap")
	for client: NetClient in attackers:
		assert_eq(_peer_of(client.get_net_id()).suspicion_score, 0, "and no suspicion")
		assert_eq(client.get_stats()["unexplained_diffs"], 0, "the attacker predicts without failures")
	var rows: Array[PackedStringArray] = _read_combat_log(log_path)
	var rewound: int = 0
	var rewind_total: float = 0.0
	for row: PackedStringArray in rows:
		if row[6] == "hit":
			rewound += 1
			rewind_total += row[5].to_float()
	assert_true(rewound >= confirmed, "the combat log records the hits (%d)" % rewound)
	var mean_rewind: float = rewind_total / float(maxi(rewound, 1))
	print("[rebobinado] rebobinado medio %.1f ticks en %d golpes" % [mean_rewind, rewound])
	assert_true(mean_rewind > 8.0 and mean_rewind <= float(NetProtocol.MAX_REWIND_TICKS),
			"it truly rewinds: %.1f ticks on average (cap %d)" % [mean_rewind,
			NetProtocol.MAX_REWIND_TICKS])


func test_a_view_offset_of_40_ticks_against_a_still_target_is_rejected_by_the_cap() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.net_sim_spec = REWIND_NET_SIM)
	var attacker: NetClient = _add_bot(VARDHEIM, 1)
	var target: NetClient = _add_bot(SOLMARCH, 2)
	if not assert_true(await _wait_until(_all_in_world, 900), "the two bots enter"):
		return
	await wait_physics_frames(30)
	var home := Vector3(0.0, 0.05, 0.0)
	var target_id: int = target.get_net_id()
	var script_rng := RandomNumberGenerator.new()
	script_rng.seed = 7
	var script_state: Dictionary = {"last_press": -1000, "rng": script_rng}
	_set_script(attacker, _attacker_script(attacker, target_id, home, 0.0, script_state))
	_set_script(target, func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI
		return input)
	await wait_physics_frames(10)
	_server.teleport(attacker.get_net_id(), home)
	_server.teleport(target_id, Vector3(0.0, 0.05, -REWIND_DISTANCE))
	_server.get_combat().get_combatant(target_id).immortal = true
	await wait_physics_frames(60)
	var peer: ServerPeer = _peer_of(attacker.get_net_id())

	# First, without cheating: three hits go through.
	assert_true(await _wait_until(func() -> bool: return _listeners[0].hits().size() >= 3, 600),
			"with the true view, the hits go through")
	assert_eq(peer.suspicion_score, 0)
	# Now the attacker fakes its view: 40 ticks back on all its inputs, more than the cap and its slack.
	script_state["armed"] = false
	await wait_physics_frames(REWIND_CYCLE_TICKS)
	var honest_hits: int = _listeners[0].hits().size()
	var health_before: int = _server.get_combat().get_combatant(target_id).health
	var swings_before: int = peer.swings
	attacker.batch_hook = func(batch: NetMessages.InputBatch) -> void:
		for index: int in batch.view_offsets_q.size():
			batch.view_offsets_q[index] = int(CHEAT_VIEW_TICKS * NetClient.VIEW_OFFSET_SCALE)
	script_state["armed"] = true
	assert_true(await _wait_until(func() -> bool: return peer.swings >= swings_before + 4, 600),
			"the cheater throws four more hits")
	await wait_physics_frames(60)
	assert_eq(_listeners[0].hits().size(), honest_hits, "none of the hits with the faked view goes through")
	assert_true(_server.get_combat().get_combatant(target_id).health >= health_before,
			"and the target loses no health")
	assert_true(_server.get_combat().stats[&"rewind_rejected"] >= 4,
			"the server rejects them because of the cap (%d)" % _server.get_combat().stats[&"rewind_rejected"])
	assert_eq(peer.rewind_rejects, _server.get_combat().stats[&"rewind_rejected"])
	assert_eq(peer.suspicion_score, peer.rewind_rejects, "and they add to its suspicion score")
	assert_eq(attacker.get_state(), NetClient.State.IN_WORLD, "it is not a network offense: it keeps playing")
	assert_eq(peer.strikes_total, 0, "no notices")
