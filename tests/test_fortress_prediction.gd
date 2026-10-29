extends TestCase
## La puerta del fuerte en la predicción (docs/fuerte.md, sección 3.2): cliente y servidor simulan cada
## tick con la misma puerta, también cuando la puerta cambia de dueño a mitad de camino y también en
## las repeticiones de la reconciliación. Como en [code]test_prediction.gd[/code], el «servidor» y el
## cliente son dos mundos de física separados (dos [SubViewport]); cada uno con un suelo plano y una
## [FortGate]. El servidor cambia la puerta tras simular el tick [constant CHANGE_TICK] (paso 4b: vale
## desde el siguiente) y el cliente se entera por un OBJECT_STATE sintético a través de
## [FortressView], cuyo gancho [method FortressView.before_simulate] es el de [ClientPrediction].
## [br][br]
## El jugador es de Vardheim y corre hacia el este contra la puerta cerrada de un fuerte neutral; en el
## tick del cambio el fuerte pasa a ser suyo y la puerta se abre para él.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const GATE_SCENE_PATH: String = "res://scenes/world/props/fort/fort_gate.tscn"
const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const NET_ID: int = 900
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
## Hacia +X (hacia dentro del fuerte): yaw -90°.
const YAW_EAST: float = -PI * 0.5
const SPAWN_TICK: int = 10
const FIRST_REAL_TICK: int = 14
const SPAWN_POSITION: Vector3 = Vector3(-5.0, 0.0, 0.0)
## Tick (del servidor) tras el que el fuerte pasa a ser de Vardheim: el jugador lleva ya un buen rato
## parado contra la puerta.
const CHANGE_TICK: int = 150
## Ticks que se simulan en total (el servidor) y x a partir de la que se ha cruzado la puerta.
const TOTAL_TICKS: int = 260
const CROSSED_X: float = 2.0
## Ticks de retraso con los que llegan los estados del servidor y cadencia de los snapshots.
const STATE_DELAY_FRAMES: int = 6
const STATE_INTERVAL_TICKS: int = 2

var _server_viewport: SubViewport = null
var _client_viewport: SubViewport = null
var _server: PlayerCharacter = null
var _server_gate: FortGate = null
var _character: PlayerCharacter = null
var _client_gate: FortGate = null
var _controller: LocalPlayerController = null
var _smoother: CorrectionSmoother = null
var _prediction: ClientPrediction = null
var _view: FortressView = null
var _brain: EastBrain = null
var _model: ServerModel = null
var _def: FortressDefinition = null
var _dt: float = 1.0 / 60.0
var _frame_counter: int = 0
## Estados propios en camino hacia el cliente: {tick, state, due}.
var _pending_states: Array[Dictionary] = []
## Lo que vio el gancho: {tick, layers, replaying} por llamada.
var _hook_log: Array[Dictionary] = []


## Siempre avanza hacia el este.
class EastBrain extends BotBrain:
	func _init() -> void:
		super(1, BotBrain.Pattern.IDLE)


	func next_input(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = YAW_EAST
		if tick >= FIRST_REAL_TICK:
			input.move = Vector2(0.0, 1.0)
		return input


## El servidor: aplica la entrada del tick o repite la última (la regla de sustitución de red.md, 8.2).
class ServerModel:
	var character: PlayerCharacter
	var dt: float = 1.0 / 60.0
	var tick: int = 0
	var inbox: Dictionary = {}
	var last_applied: PlayerInput = null
	var last_real_tick: int = 0
	var states: Dictionary = {}

	func start(new_character: PlayerCharacter, spawn_tick: int, spawn_state: PlayerState, delta: float) -> void:
		character = new_character
		dt = delta
		tick = spawn_tick
		last_applied = NetProtocol.neutral_input(spawn_tick, spawn_state.yaw)
		last_real_tick = spawn_tick
		character.set_state(spawn_state)
		character.reset_physics_interpolation()
		states[spawn_tick] = character.get_state()

	func receive(input: PlayerInput) -> void:
		if input.tick > tick and not inbox.has(input.tick):
			inbox[input.tick] = PlayerInput.decode(input.encode())

	func step() -> PlayerState:
		tick += 1
		var input: PlayerInput
		if inbox.has(tick):
			input = inbox[tick]
			inbox.erase(tick)
			last_real_tick = tick
		else:
			input = last_applied.duplicate_input()
			input.tick = tick
			input.buttons |= PlayerInput.SUBSTITUTED
			if tick - last_real_tick > NetProtocol.REPEAT_MOVE_TICKS:
				input.move = Vector2.ZERO
		last_applied = input
		character.simulate(input, dt)
		var state: PlayerState = character.get_state()
		states[tick] = state
		return state


func before_each() -> void:
	_def = load(DEFINITION_PATH) as FortressDefinition
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	_frame_counter = 0
	_pending_states.clear()
	_hook_log.clear()


func after_each() -> void:
	for node: Node in [_view, _server_viewport, _client_viewport]:
		if is_instance_valid(node):
			if node.is_inside_tree():
				node.get_parent().remove_child(node)
			node.free()
	_view = null
	_server_viewport = null
	_client_viewport = null
	_server = null
	_character = null
	_server_gate = null
	_client_gate = null
	_controller = null
	_smoother = null
	_prediction = null
	_brain = null
	_model = null
	await wait_process_frames()


func test_client_and_server_simulate_every_tick_with_the_same_gate() -> void:
	if not await _begin_session():
		return
	# El cliente sabe del cambio con antelación (el aviso llega cuando va por el tick 140): cada tick se
	# simula con la puerta que tuvo, sin una sola diferencia.
	var results: Array[Vector2i] = []
	var announced: bool = false
	for _frame: int in TOTAL_TICKS:
		await tree.physics_frame
		if not announced and _prediction.get_predicted_tick() >= CHANGE_TICK - 10:
			announced = true
			_view.on_object_state(_owner_change(CHANGE_TICK, VARDHEIM))
		_client_tick(results)
		var state: PlayerState = _server_tick()
		var predicted: PlayerState = _prediction.get_predicted_state(_model.tick)
		if not assert_not_null(predicted, "el anillo guarda el tick %d" % _model.tick):
			return
		if predicted.encode() != state.encode():
			fail("el estado predicho del tick %d difiere del del servidor.\n  predicho: %s\n  servidor: %s"
					% [_model.tick, predicted, state])
			return
	assert_true(announced)
	assert_true(_model.states[CHANGE_TICK].position.x < -0.3 and _model.states[CHANGE_TICK].position.x > -0.8,
			"hasta el cambio la puerta cerrada para al jugador contra ella (x = %.2f)"
			% _model.states[CHANGE_TICK].position.x)
	assert_true(_model.states[_model.tick].position.x > CROSSED_X,
			"y cuando el fuerte pasa a ser suyo cruza (x = %.2f)" % _model.states[_model.tick].position.x)
	assert_true(results.size() > 100, "llegaron estados del servidor (%d)" % results.size())
	for entry: Vector2i in results:
		if entry.y != ClientPrediction.Result.MATCH:
			fail("el estado del tick %d no coincidió (resultado %d)" % [entry.x, entry.y])
			return
	var stats: Dictionary = _prediction.get_stats()
	assert_eq(stats["corrections"], 0, "ninguna corrección")
	assert_eq(stats["replays"], 0, "ninguna repetición")
	assert_eq(stats["resimulated_ticks"], 0, "ningún tick vuelto a simular")
	# El gancho se llamó una vez por tick simulado con la capa de ese tick: neutral hasta el cambio
	# (inclusive) y de Vardheim desde el siguiente.
	var neutral: int = FortGate.layers_for(0, false)
	var owned: int = FortGate.layers_for(VARDHEIM, false)
	assert_true(neutral != owned)
	for entry: Dictionary in _hook_log:
		var expected: int = neutral if int(entry["tick"]) <= CHANGE_TICK else owned
		if int(entry["layers"]) != expected:
			fail("el tick %d se simuló con las capas %d y debía ser %d" % [entry["tick"], entry["layers"], expected])
			return
	assert_true(_hook_log.size() > TOTAL_TICKS - 20, "el gancho se llamó en (casi) cada tick (%d)" % _hook_log.size())


func test_a_late_notice_is_reconciled_and_the_replay_uses_the_gate_of_each_tick() -> void:
	if not await _begin_session():
		return
	# El aviso llega tarde: cuando el cliente ya ha simulado 12 ticks de más contra una puerta que ya se
	# había abierto en el servidor. La reconciliación repite esos ticks con la puerta que tuvo cada uno.
	var results: Array[Vector2i] = []
	var announced: bool = false
	var announced_at: int = 0
	for _frame: int in TOTAL_TICKS + 40:
		await tree.physics_frame
		if not announced and _prediction.get_predicted_tick() >= CHANGE_TICK + 12:
			announced = true
			announced_at = _prediction.get_predicted_tick()
			_view.on_object_state(_owner_change(CHANGE_TICK, VARDHEIM))
		_client_tick(results)
		_server_tick()
	assert_true(announced)
	var corrected: Array[Vector2i] = []
	for entry: Vector2i in results:
		if entry.y == ClientPrediction.Result.CORRECTED:
			corrected.append(entry)
	assert_true(corrected.size() >= 1, "el cliente se había equivocado de puerta: hay una corrección")
	var last_bad: int = 0
	for entry: Vector2i in results:
		if entry.y != ClientPrediction.Result.MATCH:
			last_bad = maxi(last_bad, entry.x)
	for entry: Vector2i in results:
		if entry.x > last_bad and entry.y != ClientPrediction.Result.MATCH:
			fail("tras la última corrección el estado del tick %d debería coincidir" % entry.x)
			return
	# Desde el tick de la última corrección el cliente es idéntico al servidor, bit a bit.
	for tick: int in range(last_bad, _model.tick + 1):
		var predicted: PlayerState = _prediction.get_predicted_state(tick)
		if predicted == null or predicted.encode() != (_model.states[tick] as PlayerState).encode():
			fail("el tick %d no quedó igual al servidor tras la reconciliación" % tick)
			return
	assert_true(_model.tick > last_bad + 10, "quedaron ticks por comprobar")
	assert_true(_model.states[_model.tick].position.x > CROSSED_X, "el servidor cruzó")
	assert_true(_prediction.get_predicted_state(_model.tick).position.x > CROSSED_X, "y el cliente también")
	# En las repeticiones posteriores al aviso, cada tick se simuló con la puerta que tenía: neutral hasta
	# el cambio y del dueño desde el siguiente. Antes del aviso, el cliente no podía saberlo y simuló todo
	# (también las repeticiones de entonces) con la puerta neutral.
	var neutral: int = FortGate.layers_for(0, false)
	var owned: int = FortGate.layers_for(VARDHEIM, false)
	var replayed: int = 0
	var simulated_wrong_before_notice: int = 0
	for entry: Dictionary in _hook_log:
		var tick: int = int(entry["tick"])
		var layers: int = int(entry["layers"])
		if bool(entry["replaying"]) and bool(entry["knows_change"]):
			replayed += 1
			var expected: int = neutral if tick <= CHANGE_TICK else owned
			if layers != expected:
				fail("la repetición del tick %d usó las capas %d y debía ser %d" % [tick, layers, expected])
				return
		elif tick > CHANGE_TICK and tick <= announced_at and layers == neutral:
			simulated_wrong_before_notice += 1
	assert_true(replayed > 0, "hubo ticks repetidos tras el aviso (%d)" % replayed)
	assert_true(simulated_wrong_before_notice >= 10,
			"antes del aviso se simuló con la puerta vieja (%d ticks)" % simulated_wrong_before_notice)


func test_without_the_hook_the_client_never_opens_the_gate_and_keeps_diverging() -> void:
	if not await _begin_session():
		return
	# Control: sin el gancho la puerta del cliente se queda como estaba (la «vieja») y la predicción no
	# converge, por mucho que el servidor corrija. Es lo que evita el gancho.
	_prediction.before_simulate = Callable()
	var results: Array[Vector2i] = []
	var announced: bool = false
	for _frame: int in TOTAL_TICKS:
		await tree.physics_frame
		if not announced and _prediction.get_predicted_tick() >= CHANGE_TICK - 10:
			announced = true
			_view.on_object_state(_owner_change(CHANGE_TICK, VARDHEIM))
		_client_tick(results)
		_server_tick()
	assert_true(_model.states[_model.tick].position.x > CROSSED_X, "el servidor cruza")
	var not_matching: int = 0
	for entry: Vector2i in results:
		if entry.y != ClientPrediction.Result.MATCH:
			not_matching += 1
	assert_true(not_matching >= 5, "sin el gancho el cliente discrepa del servidor una y otra vez (%d)" % not_matching)


func test_a_broken_gate_lets_everybody_through_in_the_same_tick() -> void:
	if not await _begin_session():
		return
	# La puerta se rompe (vida 0) en el tick 150: desde el 151 no tiene capas ni en el servidor ni en el
	# cliente.
	var results: Array[Vector2i] = []
	var announced: bool = false
	for _frame: int in TOTAL_TICKS:
		await tree.physics_frame
		if not announced and _prediction.get_predicted_tick() >= CHANGE_TICK - 10:
			announced = true
			_view.on_object_state(_broken_change(CHANGE_TICK))
		_client_tick(results)
		var state: PlayerState = _server_tick(true)
		var predicted: PlayerState = _prediction.get_predicted_state(_model.tick)
		if predicted == null or predicted.encode() != state.encode():
			fail("el tick %d difiere con la puerta rota" % _model.tick)
			return
	assert_true(_model.states[_model.tick].position.x > CROSSED_X, "cruza por la puerta rota")
	for entry: Dictionary in _hook_log:
		var expected: int = FortGate.layers_for(0, false) if int(entry["tick"]) <= CHANGE_TICK else 0
		if int(entry["layers"]) != expected:
			fail("el tick %d se simuló con las capas %d y debía ser %d" % [entry["tick"], entry["layers"], expected])
			return


# --- Montaje ----------------------------------------------------------------------------------

func _begin_session() -> bool:
	_server_viewport = _make_world("ServerWorld")
	_client_viewport = _make_world("ClientWorld")
	var character_scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	var gate_scene: PackedScene = load(GATE_SCENE_PATH) as PackedScene
	if not assert_not_null(character_scene) or not assert_not_null(gate_scene):
		return false
	_server_gate = gate_scene.instantiate() as FortGate
	_server_viewport.add_child(_server_gate)
	_server = character_scene.instantiate() as PlayerCharacter
	_server_viewport.add_child(_server)
	_server.set_realm_collision(VARDHEIM)
	# El cliente: la fortaleza de la escena (como la deja el generador) con la puerta dentro.
	var fort := Node3D.new()
	fort.name = "Fuerte"
	fort.add_to_group(Zones.FORTRESS_GROUP)
	fort.set_meta(Zones.FORTRESS_DEFINITION_META, DEFINITION_PATH)
	_client_viewport.add_child(fort)
	_client_gate = gate_scene.instantiate() as FortGate
	_client_gate.name = "FortGate"
	fort.add_child(_client_gate)
	_character = character_scene.instantiate() as PlayerCharacter
	_client_viewport.add_child(_character)
	_character.set_realm_collision(VARDHEIM)

	_brain = EastBrain.new()
	_controller = LocalPlayerController.new()
	_controller.name = "LocalPlayerController"
	_controller.auto_step = false
	_client_viewport.add_child(_controller)
	_controller.setup(_character, null)
	_controller.set_bot(_brain)
	var targets: Array[Node3D] = [_character.get_node(^"Visual") as Node3D, _character.get_camera_target()]
	_smoother = CorrectionSmoother.new()
	_smoother.setup(_character, targets)
	_prediction = ClientPrediction.new()
	_prediction.setup(_character, _controller, _smoother, _dt)

	_view = FortressView.new()
	tree.root.add_child(_view)
	_view.set_zone(_client_viewport)
	_view.on_spawn(NetMessages.EntitySpawn.decode(NetMessages.EntitySpawn.for_fortress(NET_ID, 1,
			"vado_gris_fort", FortressState.initial(_def, 1)).encode()))
	if not assert_true(_view.is_bound(NET_ID), "la vista del cliente encuentra su fuerte"):
		return false
	# El gancho de la predicción, con un registro de lo que ve en cada llamada.
	_prediction.before_simulate = func(tick: int) -> void:
		_view.before_simulate(tick)
		var known: FortressState = _view.get_latest_state(NET_ID)
		_hook_log.append({"tick": tick, "layers": _client_gate.collision_layer,
				"replaying": _prediction.is_replaying(), "knows_change": known != null and known.owner != 0})
	await wait_physics_frames(3)
	var spawn := PlayerState.new()
	spawn.position = SPAWN_POSITION
	spawn.yaw = YAW_EAST
	spawn.grounded = true
	spawn = PlayerState.decode(spawn.encode())
	_model = ServerModel.new()
	_model.start(_server, SPAWN_TICK, spawn, _dt)
	_prediction.start(SPAWN_TICK, spawn, FIRST_REAL_TICK)
	return true


func _make_world(world_name: String) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = world_name
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	tree.root.add_child(viewport)
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	floor_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	floor_body.add_child(shape)
	viewport.add_child(floor_body)
	return viewport


# --- Ticks ------------------------------------------------------------------------------------

# Un tick del cliente: llegan los estados que tocan, predice y manda la entrada.
func _client_tick(results: Array[Vector2i]) -> void:
	while not _pending_states.is_empty() and _pending_states[0]["due"] <= _frame_counter:
		var item: Dictionary = _pending_states.pop_front()
		var tick: int = item["tick"]
		results.append(Vector2i(tick, _prediction.on_server_state(tick, item["state"], false)))
	var input: PlayerInput = _prediction.step()
	_model.receive(input)
	_smoother.physics_step()
	_frame_counter += 1


# Un tick del servidor. Tras simularlo (paso 4b) aplica el cambio de la puerta: vale desde el siguiente.
func _server_tick(broken: bool = false) -> PlayerState:
	var state: PlayerState = _model.step()
	if _model.tick == CHANGE_TICK:
		if broken:
			_server_gate.set_state(0, true)
		else:
			_server_gate.set_state(VARDHEIM, false)
	if _model.tick % STATE_INTERVAL_TICKS == 0:
		_pending_states.append({
			"tick": _model.tick,
			"state": PlayerState.decode(state.encode()),
			"due": _frame_counter + STATE_DELAY_FRAMES,
		})
	return state


# OBJECT_STATE (pasado por la red) con el nuevo dueño: pasa a CONSOLIDATING como tras una captura.
func _owner_change(tick: int, owner_realm: int) -> NetMessages.ObjectState:
	var message := NetMessages.ObjectState.new()
	message.net_id = NET_ID
	message.tick = tick
	message.add_field(FortressFields.OWNER, NetMessages.ObjectField.ValueType.U8, owner_realm)
	message.add_field(FortressFields.PHASE, NetMessages.ObjectField.ValueType.U8, FortressState.Phase.CONSOLIDATING)
	return NetMessages.ObjectState.decode(message.encode())


func _broken_change(tick: int) -> NetMessages.ObjectState:
	var message := NetMessages.ObjectState.new()
	message.net_id = NET_ID
	message.tick = tick
	message.add_field(FortressFields.GATE_HEALTH, NetMessages.ObjectField.ValueType.U32, 0)
	return NetMessages.ObjectState.decode(message.encode())
