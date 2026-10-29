extends TestCase
## La puerta del fuerte con física de verdad (docs/fuerte.md, sección 3.1): la puerta cerrada para
## a los personajes de los reinos que no son su dueño y no a los suyos, rota no para a nadie, y la
## cámara y la línea de visión de los golpes no la atraviesan en ningún caso mientras esté entera.
## Usa un suelo plano y la escena suelta de la puerta (el plano x = 0, el vano de 4 m en z).

const GATE_SCENE: String = "res://scenes/world/props/fort/fort_gate.tscn"
const CHARACTER_SCENE: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE: String = "res://scenes/client/camera_rig.tscn"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
## Hacia +X (de fuera del fuerte a dentro): yaw -90°.
const YAW_EAST: float = -PI * 0.5
## Ticks que se corren (unos 12 m a 5 m/s) y x a partir de la que se ha cruzado la puerta.
const RUN_TICKS: int = 150
const CROSSED_X: float = 2.0
## Tope de la x de un personaje parado por la puerta (cara oeste de la caja menos el radio).
const STOPPED_X: float = -0.4

var _world: Node3D = null
var _gate: FortGate = null
var _tick: int = 1


func before_each() -> void:
	_world = ZoneFixture.build_flat_zone(tree.root)
	_gate = (load(GATE_SCENE) as PackedScene).instantiate() as FortGate
	_world.add_child(_gate)
	_tick = 1
	await wait_physics_frames(2)


func after_each() -> void:
	if is_instance_valid(_world):
		_world.get_parent().remove_child(_world)
		_world.queue_free()
	_world = null
	_gate = null
	await wait_process_frames()


# --- Movimiento -------------------------------------------------------------------------------

func test_a_neutral_gate_stops_the_three_realms_but_not_the_hollows() -> void:
	var crossed: Dictionary = await _run_all({VARDHEIM: -1.5, SOLMARCH: -0.5, ASKARRA: 0.5, 0: 1.5})
	assert_false(crossed[VARDHEIM], "un fuerte neutral para a Vardheim")
	assert_false(crossed[SOLMARCH], "y a Solmarch")
	assert_false(crossed[ASKARRA], "y a Askarra")
	assert_true(crossed[0], "los Huecos (sin capa de reino) pasan")


func test_a_realm_owned_gate_stops_its_enemies_and_lets_its_owner_through() -> void:
	_gate.set_state(VARDHEIM, false)
	await wait_physics_frames()
	var crossed: Dictionary = await _run_all({VARDHEIM: -1.0, SOLMARCH: 0.0, ASKARRA: 1.0})
	assert_true(crossed[VARDHEIM], "el dueño cruza su puerta cerrada")
	assert_false(crossed[SOLMARCH], "Solmarch no")
	assert_false(crossed[ASKARRA], "Askarra no")


func test_the_other_owner_flips_who_gets_through() -> void:
	_gate.set_state(SOLMARCH, false)
	await wait_physics_frames()
	var crossed: Dictionary = await _run_all({VARDHEIM: -1.0, SOLMARCH: 0.0})
	assert_false(crossed[VARDHEIM], "ahora Vardheim es el enemigo")
	assert_true(crossed[SOLMARCH], "y Solmarch el dueño")


func test_a_broken_gate_stops_nobody() -> void:
	_gate.set_state(VARDHEIM, true)
	await wait_physics_frames()
	var crossed: Dictionary = await _run_all({VARDHEIM: -1.5, SOLMARCH: -0.5, ASKARRA: 0.5, 0: 1.5})
	for realm: int in crossed:
		assert_true(crossed[realm], "rota, deja pasar al reino %d" % realm)


func test_a_character_without_a_realm_layer_walks_through_a_closed_gate() -> void:
	# El modo sin red no llama a set_realm_collision(): la puerta no le para (ni la de vista).
	var crossed: Dictionary = await _run_all({-1: 0.0})
	assert_true(crossed[-1])


func test_changing_the_state_acts_on_the_next_tick() -> void:
	var character: PlayerCharacter = _spawn(SOLMARCH, 0.0)
	await wait_physics_frames()
	for _i: int in 60:
		_step(character)
		await wait_physics_frames()
	assert_true(character.global_position.x < STOPPED_X + 0.05, "parado por la puerta neutral (x = %.2f)" % character.global_position.x)
	# Pasa a ser de Solmarch: el mismo personaje, sin moverlo, ya puede cruzar.
	_gate.set_state(SOLMARCH, false)
	for _i: int in 90:
		_step(character)
		await wait_physics_frames()
	assert_true(character.global_position.x > CROSSED_X, "cruza al pasar a ser su puerta (x = %.2f)" % character.global_position.x)
	# Un enemigo que se acerca de nuevo es parado tras reparar/cambiar de dueño.
	_gate.set_state(VARDHEIM, false)
	character.set_state(_state_at(Vector3(-4.0, 0.0, 0.5)))
	for _i: int in 90:
		_step(character)
		await wait_physics_frames()
	assert_true(character.global_position.x < STOPPED_X + 0.05, "y otra vez parado cuando el dueño es Vardheim")


# --- Cámara y línea de visión -----------------------------------------------------------------

func test_the_camera_arm_does_not_cross_a_gate_even_for_its_owner() -> void:
	var mask: int = _camera_arm_mask()
	assert_true((mask & PlayerCharacter.STRUCTURE_LAYER) != 0, "el brazo de la cámara mira la capa 4")
	assert_true((mask & PlayerCharacter.WORLD_COLLISION_LAYER) != 0, "y la del mundo")
	assert_eq(mask & PlayerCharacter.PLAYER_BLOCKER_LAYER, 0, "pero no los bloqueos invisibles")
	for owner_realm: int in [0, VARDHEIM, SOLMARCH]:
		_gate.set_state(owner_realm, false)
		await wait_physics_frames(2)
		var hit_length: float = await _arm_length_through_the_gate(mask)
		assert_true(hit_length < 2.0, "dueño %d: la cámara se queda a este lado de la puerta (%.2f m de 3,5)" % [owner_realm, hit_length])
	# Con la máscara de antes (solo el mundo) la atravesaría: la capa 4 es lo que la frena.
	var old_length: float = await _arm_length_through_the_gate(PlayerCharacter.WORLD_COLLISION_LAYER)
	assert_true(old_length > 3.4, "sin la capa 4 el brazo cruzaría la puerta (%.2f m)" % old_length)
	# Rota, la cámara pasa.
	_gate.set_state(VARDHEIM, true)
	await wait_physics_frames(2)
	var broken_length: float = await _arm_length_through_the_gate(mask)
	assert_true(broken_length > 3.4, "con la puerta rota el brazo está libre (%.2f m)" % broken_length)


func test_line_of_sight_does_not_cross_a_gate() -> void:
	assert_true((HitShapes.LINE_OF_SIGHT_MASK & PlayerCharacter.STRUCTURE_LAYER) != 0, "la línea de visión mira la capa 4")
	assert_true((HitShapes.LINE_OF_SIGHT_MASK & PlayerCharacter.WORLD_COLLISION_LAYER) != 0)
	assert_eq(HitShapes.LINE_OF_SIGHT_MASK & PlayerCharacter.PLAYER_BLOCKER_LAYER, 0)
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	var outside: Vector3 = Vector3(-4.0, 0.0, 0.5)
	var inside: Vector3 = Vector3(4.0, 0.0, 0.5)
	for owner_realm: int in [0, VARDHEIM, SOLMARCH]:
		_gate.set_state(owner_realm, false)
		await wait_physics_frames(2)
		assert_false(HitShapes.has_line_of_sight(space, outside, inside), "dueño %d: no se ve a través de la puerta" % owner_realm)
		assert_false(HitShapes.has_line_of_sight(space, inside, outside), "ni en el otro sentido")
	# A su lado, sin la puerta en medio, sí.
	assert_true(HitShapes.has_line_of_sight(space, Vector3(-4.0, 0.0, 6.0), Vector3(4.0, 0.0, 6.0)), "fuera del vano no hay nada")
	_gate.set_state(SOLMARCH, true)
	await wait_physics_frames(2)
	assert_true(HitShapes.has_line_of_sight(space, outside, inside), "rota, se ve a su través")


func test_whoever_stands_inside_a_closed_gate_neither_hits_out_nor_is_hit() -> void:
	# F6b: el dueño cruza su puerta cerrada, y quien se queda dentro de ella (el pecho dentro de la caja de vista)
	# golpeaba hacia fuera sin que los de fuera le pudieran golpear: el rayo que sale de dentro de una caja no la
	# veía. Ahora la puerta para el rayo en los dos sentidos.
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	var in_the_gate: Vector3 = Vector3(0.1, 0.0, 0.5)
	var outside: Vector3 = Vector3(-1.8, 0.0, 0.5)
	var inside: Vector3 = Vector3(1.8, 0.0, 0.5)
	for owner_realm: int in [0, VARDHEIM]:
		_gate.set_state(owner_realm, false)
		await wait_physics_frames(2)
		assert_false(HitShapes.has_line_of_sight(space, in_the_gate, outside),
				"dueño %d: desde dentro de la puerta no se golpea hacia fuera" % owner_realm)
		assert_false(HitShapes.has_line_of_sight(space, in_the_gate, inside), "ni hacia dentro")
		assert_false(HitShapes.has_line_of_sight(space, outside, in_the_gate), "ni le golpean desde fuera")
	_gate.set_state(VARDHEIM, true)
	await wait_physics_frames(2)
	assert_true(HitShapes.has_line_of_sight(space, in_the_gate, outside), "rota, el vano está libre")
	assert_true(HitShapes.has_line_of_sight(space, outside, in_the_gate))


# --- Ayudantes --------------------------------------------------------------------------------

## Crea un personaje del reino [param realm] (-1 = sin llamar a set_realm_collision) a 6 m al oeste de
## la puerta, a la altura [param z] del vano, mirando al este.
func _spawn(realm: int, z: float) -> PlayerCharacter:
	var character: PlayerCharacter = (load(CHARACTER_SCENE) as PackedScene).instantiate() as PlayerCharacter
	_world.add_child(character)
	if realm >= 0:
		character.set_realm_collision(realm)
	character.set_state(_state_at(Vector3(-6.0, 0.0, z)))
	return character


func _state_at(position: Vector3) -> PlayerState:
	var state := PlayerState.new()
	state.position = position
	state.yaw = YAW_EAST
	state.grounded = true
	return state


func _step(character: PlayerCharacter) -> void:
	var input := PlayerInput.new()
	input.tick = _tick
	input.move = Vector2(0.0, 1.0)
	input.look_yaw = YAW_EAST
	_tick += 1
	character.simulate(input.quantized(), 1.0 / float(Engine.physics_ticks_per_second))


## Pone a correr hacia el este un personaje por cada entrada de [param realms] (reino -> z) y
## devuelve {reino: bool} con si ha cruzado la puerta.
func _run_all(realms: Dictionary) -> Dictionary:
	var characters: Dictionary = {}
	for realm: int in realms:
		characters[realm] = _spawn(realm, float(realms[realm]))
	await wait_physics_frames()
	for _i: int in RUN_TICKS:
		# Un solo paso por tick de física y por personaje (todos a la vez: no chocan entre sí).
		for realm: int in characters:
			_step(characters[realm])
		await wait_physics_frames()
	var crossed: Dictionary = {}
	for realm: int in characters:
		var character: PlayerCharacter = characters[realm]
		crossed[realm] = character.global_position.x > CROSSED_X
		if not crossed[realm]:
			assert_true(character.global_position.x < STOPPED_X + 0.1,
					"el reino %d se queda delante de la puerta (x = %.2f)" % [realm, character.global_position.x])
	return crossed


## Máscara de colisión del SpringArm3D de la cámara, leída de la escena (sin instanciar su script).
func _camera_arm_mask() -> int:
	var state: SceneState = (load(CAMERA_RIG_SCENE) as PackedScene).get_state()
	for index: int in state.get_node_count():
		if state.get_node_name(index) != &"Arm":
			continue
		for property: int in state.get_node_property_count(index):
			if state.get_node_property_name(index, property) == "collision_mask":
				return int(state.get_node_property_value(index, property))
	fail("la escena de la cámara no tiene el brazo con máscara")
	return 0


## Longitud útil de un brazo de cámara (3,5 m, esfera de 20 cm, como el de la escena) que sale de la
## cabeza de alguien dentro del fuerte (x = 1,5) hacia el oeste, a través del vano de la puerta.
func _arm_length_through_the_gate(mask: int) -> float:
	var arm := SpringArm3D.new()
	arm.collision_mask = mask
	var sphere := SphereShape3D.new()
	sphere.radius = 0.2
	arm.shape = sphere
	arm.spring_length = 3.5
	arm.margin = 0.15
	# El eje +Z local del brazo apunta hacia el oeste (-X).
	arm.transform = Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(1.5, 1.6, 0.0))
	_world.add_child(arm)
	await wait_physics_frames(3)
	var length: float = arm.get_hit_length()
	_world.remove_child(arm)
	arm.free()
	return length
