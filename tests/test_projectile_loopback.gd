extends TestCase
## Flechas de punta a punta con ENet real sobre 127.0.0.1 y red mala (H5; docs/habilidades.md, secciones 4.4 y
## 7.3; CMB-22): un [ZoneServer] con un [NetSim] de 150 ms de RTT y 30 ms de jitter, un arquero (bot con la
## plantilla del tirador, elegida con [code]--loadout[/code] antes de CLIENT_READY) y un objetivo que corre en
## lateral a 30 m, cada uno en su [SubViewport] con su propio mundo de física.
## [br][br]
## El arquero apunta como un bot ([method BotBrain.lead_look]: [method Ballistics.solve_lead] y
## [method AimRay.look_for]) a lo que dibuja del objetivo, con su velocidad dibujada, y suelta 20 tensados. El
## servidor vuela cada flecha contra las posiciones rebobinadas a lo que veía el arquero: al menos 18 deben
## acertar (HIT confirmado). [b]Control en la misma ejecución[/b], como en test_combat_loopback: la misma
## trayectoria de cada flecha (la del SPAWN, que es con la que vuela el servidor) contra la posición
## [i]presente[/i] del objetivo en cada tick (sin rebobinar) habría acertado menos de 10.
## [br][br]
## El objetivo corre en círculo alrededor del arquero (siempre de lado y siempre a 30 m, sin darse la vuelta en
## mitad de un vuelo).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
## 150 ms de RTT y 30 ms de jitter en el servidor (el criterio de CMB-22, como TEC-14).
const NET_SIM: String = "rtt=150,jitter=30,seed=5"
## Distancia (m) del objetivo al arquero y número de tensados.
const RANGE_M: float = 30.0
const SHOTS: int = 20
## Ticks que mantiene PRIMARY cada tensado (carga 30: 46,9 m/s) y ticks entre dos pulsaciones (la carga, los 22
## del tensado y un margen).
const DRAW_TICKS: int = 30
const CYCLE_TICKS: int = 56
## Mínimos del criterio y del control.
const MIN_CONFIRMED: int = 18
const MAX_CONTROL_HITS: int = 9
const WAIT_FRAMES: int = 900

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _clients: Array[NetClient] = []
var _viewports: Array[SubViewport] = []
# Disparos del arquero según el servidor: id del proyectil -> [p0, v0, spawn_tick].
var _shots: Dictionary[int, Array] = {}
var _shot_order: Array[int] = []
var _confirmed: int = 0
var _hits_by_shot_tick: Dictionary[int, int] = {}
# Control: id del proyectil -> true si habría tocado la posición presente; último tick comprobado de cada uno.
var _control_hit: Dictionary[int, bool] = {}
var _control_checked: Dictionary[int, int] = {}
var _archer_id: int = 0
var _target_id: int = 0


func before_each() -> void:
	_root = Node.new()
	_root.name = "ProjectileLoopback"
	tree.root.add_child(_root)
	_shots.clear()
	_shot_order.clear()
	_confirmed = 0
	_control_hit.clear()
	_control_checked.clear()


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


func _set_script(client: NetClient, script: Callable) -> void:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = script
	(client.get_meta(&"controller") as LocalPlayerController).set_bot(brain)


## Guion del objetivo: corre (sin esprintar) en círculo de [constant RANGE_M] m alrededor del origen, con la
## tangente más una corrección hacia la circunferencia.
func _runner_script() -> Callable:
	return func(tick: int, position: Vector3, yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		var radial := Vector3(position.x, 0.0, position.z)
		var distance: float = radial.length()
		if distance < 0.01:
			input.look_yaw = yaw
			return input
		radial /= distance
		var tangent := Vector3(-radial.z, 0.0, radial.x)
		var heading: Vector3 = tangent + radial * clampf((RANGE_M - distance) * 0.5, -1.0, 1.0)
		input.look_yaw = fposmod(atan2(-heading.x, -heading.z), TAU)
		input.move = Vector2(0.0, 1.0)
		return input


## Guion del arquero: apunta en cada tick al objetivo que dibuja con el tiro adelantado de un tensado de
## [constant DRAW_TICKS] ticks; pulsa cada [constant CYCLE_TICKS] ticks y mantiene PRIMARY esos ticks, hasta
## [constant SHOTS] tensados. [param state] guarda el tick de la última pulsación, los disparos y si está armado.
func _archer_script(client: NetClient, target_id: int, state: Dictionary) -> Callable:
	var heavy: AttackTicks = CombatCatalog.attack(CombatCatalog.weapon(CombatCatalog.weapon_id(&"bow")).heavy_id)
	var speed: float = ProjectileLaunch.for_attack(heavy, DRAW_TICKS).speed
	var gravity: float = CombatCatalog.projectile(heavy.projectile_id).gravity
	return func(tick: int, position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = float(state["yaw"])
		input.look_pitch = float(state["pitch"])
		var view: RemotePlayerView = client.get_remote_world().get_view(target_id)
		if view == null or not view.is_drawn():
			return input
		var look: Vector2 = BotBrain.lead_look(position, view.get_drawn_position(), view.get_body().velocity,
				speed, gravity, false)
		input.look_yaw = look.x
		input.look_pitch = look.y
		state["yaw"] = look.x
		state["pitch"] = look.y
		var since: int = tick - int(state["press"])
		if since < DRAW_TICKS:
			input.buttons = PlayerInput.PRIMARY
		elif since >= CYCLE_TICKS and bool(state["armed"]) and int(state["shots"]) < SHOTS:
			state["press"] = tick
			state["shots"] = int(state["shots"]) + 1
			input.buttons = PlayerInput.PRIMARY
		return input


func _on_spawned(spawn: NetMessages.EntitySpawn, _recipients: PackedInt32Array) -> void:
	if spawn.owner_id != _archer_id:
		return
	_shots[spawn.net_id] = [spawn.origin, spawn.velocity, spawn.spawn_tick]
	_shot_order.append(spawn.net_id)
	_control_checked[spawn.net_id] = spawn.spawn_tick - 1


func _on_combat_event(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
	if event.event == NetMessages.EntityEvent.Kind.HIT and event.attacker == _archer_id \
			and event.net_id == _target_id and event.amount > 0:
		_confirmed += 1


## Control: cada segmento de las flechas del arquero contra la posición presente del objetivo (la del tick, sin
## rebobinar), tick a tick mientras el historial la tiene.
func _check_control() -> void:
	var arrow: ProjectileTicks = CombatCatalog.projectile(CombatCatalog.projectile_id(&"arrow"))
	var history: StateHistory = _server.get_history()
	for id: int in _shots:
		var shot: Array = _shots[id]
		var spawn_tick: int = shot[2]
		var last: int = mini(_server.get_tick(), spawn_tick + arrow.lifetime_ticks - 1)
		for k: int in range(_control_checked[id] + 1, last + 1):
			_control_checked[id] = k
			if _control_hit.get(id, false):
				continue
			var present: Vector3 = history.position_at(_target_id, k)
			if not present.is_finite():
				continue
			var n: int = k - spawn_tick
			var a: Vector3 = Ballistics.position(shot[0], shot[1], arrow.gravity, float(n))
			var b: Vector3 = Ballistics.position(shot[0], shot[1], arrow.gravity, float(n + 1))
			if a.y < -1.0:
				continue
			if HitShapes.segment_capsule_fraction(a, b, present, HitShapes.CAPSULE_RADIUS + arrow.radius_m,
					HitShapes.CAPSULE_HEIGHT) >= 0.0:
				_control_hit[id] = true


func test_twenty_drawn_shots_at_30_m_on_a_running_target_with_150_ms_of_rtt() -> void:
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = port
	config.zone_id = ZONE_ID
	config.max_players = 8
	config.net_sim_spec = NET_SIM
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	for entry: Array in [[VARDHEIM, 1, "marksman"], [SOLMARCH, 2, ""]]:
		var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
		_viewports.append(viewport)
		_clients.append(NetHarness.start_bot(viewport, port, entry[0], entry[1], "", "", "", entry[2]))
	if not assert_true(await _wait_until(_all_in_world), "entran el arquero y el objetivo"):
		return
	var archer: NetClient = _clients[0]
	var runner: NetClient = _clients[1]
	_archer_id = archer.get_net_id()
	_target_id = runner.get_net_id()
	# Sin plataforma, un personaje efímero con inventario (progresion.md §9.4, P5b): la plantilla elegida antes de
	# CLIENT_READY es su kit de inicio, con el arco en la ranura 1, y lo equipa su inventario (plantilla vigente 0).
	var archer_combatant: Combatant = _server.get_combat().get_combatant(_archer_id)
	assert_eq(archer_combatant.template_id, 0, "el equipo de su inventario")
	var archer_weapon: ItemInstance = _server.get_progress().get_player(_archer_id).record.inventory.get_item(
			InventoryState.ContainerId.EQUIPMENT, 0)
	assert_true(archer_weapon != null and archer_weapon.def_id == &"bow_vado",
			"la plantilla elegida antes de CLIENT_READY vale ya para la primera aparición: el kit del tirador")
	assert_eq(archer.get_character().combat.weapon_id, CombatCatalog.weapon_id(&"bow"), "con el arco en la mano")
	_server.get_combat().get_combatant(_target_id).immortal = true
	_server.get_combat().projectiles.spawned.connect(_on_spawned)
	_server.get_combat().event_emitted.connect(_on_combat_event)
	var state: Dictionary = {"press": -1000, "shots": 0, "armed": false, "yaw": 0.0, "pitch": 0.0}
	_set_script(archer, _archer_script(archer, _target_id, state))
	_set_script(runner, _runner_script())
	await wait_physics_frames(10)
	_server.teleport(_archer_id, Vector3(0.0, 0.05, 0.0))
	_server.teleport(_target_id, Vector3(0.0, 0.05, -RANGE_M))
	await wait_physics_frames(60)
	state["armed"] = true
	var done: bool = await _wait_until(func() -> bool:
		_check_control()
		return _shots.size() >= SHOTS and _server.get_tick() > int(_shots[_shot_order[SHOTS - 1]][2]) + 90,
			SHOTS * CYCLE_TICKS + 400)
	_check_control()
	var control: int = 0
	for id: int in _control_hit:
		if _control_hit[id]:
			control += 1
	var arrows: Dictionary = archer.get_projectile_world().get_stats()
	print("[flechas] %d tensados, %d confirmados, %d habrían acertado sin rebobinar; predichas %s" % [
			_shots.size(), _confirmed, control, arrows])
	if not assert_true(done, "el arquero suelta sus %d tensados (%d)" % [SHOTS, _shots.size()]):
		return
	assert_eq(_shots.size(), SHOTS, "ni uno más")
	assert_true(_confirmed >= MIN_CONFIRMED, "al menos %d de %d confirmados: %d" % [MIN_CONFIRMED, SHOTS,
			_confirmed])
	assert_true(control <= MAX_CONTROL_HITS,
			"contra la posición presente habrían acertado menos de 10: %d" % control)
	assert_eq(_server.get_combat().stats[&"rewind_rejected"], 0, "ningún rebobinado pasa del tope")
	var peer: ServerPeer = null
	for peer_id: int in _server.get_peer_ids():
		if _server.get_peer(peer_id).entity != null and _server.get_peer(peer_id).entity.net_id == _archer_id:
			peer = _server.get_peer(peer_id)
	if assert_not_null(peer):
		assert_eq(peer.suspicion_score, 0, "y ninguna sospecha")
	assert_true(int(arrows.get("substituted", 0)) >= SHOTS - 1,
			"las flechas predichas se sustituyen por las del servidor (%s)" % [arrows])
	assert_eq(int(arrows.get("rejected", -1)), 0, "ninguna predicha se queda sin la del servidor")
	assert_eq(archer.get_stats()["unexplained_diffs"], 0, "el arquero predice sin fallos")
