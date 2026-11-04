extends TestCase
## The fort gate with real physics (docs/fortress.md, section 3.1): the closed gate stops
## the characters of the realms that are not its owner and not those of its own, broken it stops nobody, and the
## camera and the line of sight of hits do not go through it in any case while it is intact.
## It uses a flat floor and the standalone gate scene (the plane x = 0, the 4 m doorway in z).

const GATE_SCENE: String = "res://scenes/world/props/fort/fort_gate.tscn"
const CHARACTER_SCENE: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE: String = "res://scenes/client/camera_rig.tscn"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
## Towards +X (from outside the fort to inside): yaw -90°.
const YAW_EAST: float = -PI * 0.5
## Ticks run (about 12 m at 5 m/s) and x from which the gate has been crossed.
const RUN_TICKS: int = 150
const CROSSED_X: float = 2.0
## Cap on the x of a character stopped by the gate (west face of the box minus the radius).
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


# --- Movement ---------------------------------------------------------------------------------

func test_a_neutral_gate_stops_the_three_realms_but_not_the_hollows() -> void:
	var crossed: Dictionary = await _run_all({VARDHEIM: -1.5, SOLMARCH: -0.5, ASKARRA: 0.5, 0: 1.5})
	assert_false(crossed[VARDHEIM], "a neutral fort stops Vardheim")
	assert_false(crossed[SOLMARCH], "and Solmarch")
	assert_false(crossed[ASKARRA], "and Askarra")
	assert_true(crossed[0], "the Hollow (without a realm layer) pass")


func test_a_realm_owned_gate_stops_its_enemies_and_lets_its_owner_through() -> void:
	_gate.set_state(VARDHEIM, false)
	await wait_physics_frames()
	var crossed: Dictionary = await _run_all({VARDHEIM: -1.0, SOLMARCH: 0.0, ASKARRA: 1.0})
	assert_true(crossed[VARDHEIM], "the owner crosses its closed gate")
	assert_false(crossed[SOLMARCH], "Solmarch does not")
	assert_false(crossed[ASKARRA], "Askarra does not")


func test_the_other_owner_flips_who_gets_through() -> void:
	_gate.set_state(SOLMARCH, false)
	await wait_physics_frames()
	var crossed: Dictionary = await _run_all({VARDHEIM: -1.0, SOLMARCH: 0.0})
	assert_false(crossed[VARDHEIM], "now Vardheim is the enemy")
	assert_true(crossed[SOLMARCH], "and Solmarch the owner")


func test_a_broken_gate_stops_nobody() -> void:
	_gate.set_state(VARDHEIM, true)
	await wait_physics_frames()
	var crossed: Dictionary = await _run_all({VARDHEIM: -1.5, SOLMARCH: -0.5, ASKARRA: 0.5, 0: 1.5})
	for realm: int in crossed:
		assert_true(crossed[realm], "broken, it lets realm %d through" % realm)


func test_a_character_without_a_realm_layer_walks_through_a_closed_gate() -> void:
	# The offline mode does not call set_realm_collision(): the gate does not stop it (nor the sight one).
	var crossed: Dictionary = await _run_all({-1: 0.0})
	assert_true(crossed[-1])


func test_changing_the_state_acts_on_the_next_tick() -> void:
	var character: PlayerCharacter = _spawn(SOLMARCH, 0.0)
	await wait_physics_frames()
	for _i: int in 60:
		_step(character)
		await wait_physics_frames()
	assert_true(character.global_position.x < STOPPED_X + 0.05, "stopped by the neutral gate (x = %.2f)" % character.global_position.x)
	# It becomes Solmarch's: the same character, without moving it, can now cross.
	_gate.set_state(SOLMARCH, false)
	for _i: int in 90:
		_step(character)
		await wait_physics_frames()
	assert_true(character.global_position.x > CROSSED_X, "crosses when it becomes its gate (x = %.2f)" % character.global_position.x)
	# An enemy that approaches again is stopped after repairing/changing owner.
	_gate.set_state(VARDHEIM, false)
	character.set_state(_state_at(Vector3(-4.0, 0.0, 0.5)))
	for _i: int in 90:
		_step(character)
		await wait_physics_frames()
	assert_true(character.global_position.x < STOPPED_X + 0.05, "and stopped again when the owner is Vardheim")


# --- Camera and line of sight -----------------------------------------------------------------

func test_the_camera_arm_does_not_cross_a_gate_even_for_its_owner() -> void:
	var mask: int = _camera_arm_mask()
	assert_true((mask & PlayerCharacter.STRUCTURE_LAYER) != 0, "the camera arm looks at layer 4")
	assert_true((mask & PlayerCharacter.WORLD_COLLISION_LAYER) != 0, "and the world's")
	assert_eq(mask & PlayerCharacter.PLAYER_BLOCKER_LAYER, 0, "but not the invisible blockers")
	for owner_realm: int in [0, VARDHEIM, SOLMARCH]:
		_gate.set_state(owner_realm, false)
		await wait_physics_frames(2)
		var hit_length: float = await _arm_length_through_the_gate(mask)
		assert_true(hit_length < 2.0, "owner %d: the camera stays on this side of the gate (%.2f m of 3.5)" % [owner_realm, hit_length])
	# With the earlier mask (only the world) it would go through: layer 4 is what stops it.
	var old_length: float = await _arm_length_through_the_gate(PlayerCharacter.WORLD_COLLISION_LAYER)
	assert_true(old_length > 3.4, "without layer 4 the arm would cross the gate (%.2f m)" % old_length)
	# Broken, the camera passes.
	_gate.set_state(VARDHEIM, true)
	await wait_physics_frames(2)
	var broken_length: float = await _arm_length_through_the_gate(mask)
	assert_true(broken_length > 3.4, "with the gate broken the arm is free (%.2f m)" % broken_length)


func test_line_of_sight_does_not_cross_a_gate() -> void:
	assert_true((HitShapes.LINE_OF_SIGHT_MASK & PlayerCharacter.STRUCTURE_LAYER) != 0, "the line of sight looks at layer 4")
	assert_true((HitShapes.LINE_OF_SIGHT_MASK & PlayerCharacter.WORLD_COLLISION_LAYER) != 0)
	assert_eq(HitShapes.LINE_OF_SIGHT_MASK & PlayerCharacter.PLAYER_BLOCKER_LAYER, 0)
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	var outside: Vector3 = Vector3(-4.0, 0.0, 0.5)
	var inside: Vector3 = Vector3(4.0, 0.0, 0.5)
	for owner_realm: int in [0, VARDHEIM, SOLMARCH]:
		_gate.set_state(owner_realm, false)
		await wait_physics_frames(2)
		assert_false(HitShapes.has_line_of_sight(space, outside, inside), "owner %d: one cannot see through the gate" % owner_realm)
		assert_false(HitShapes.has_line_of_sight(space, inside, outside), "nor the other way")
	# Beside it, without the gate in between, yes.
	assert_true(HitShapes.has_line_of_sight(space, Vector3(-4.0, 0.0, 6.0), Vector3(4.0, 0.0, 6.0)), "outside the doorway there is nothing")
	_gate.set_state(SOLMARCH, true)
	await wait_physics_frames(2)
	assert_true(HitShapes.has_line_of_sight(space, outside, inside), "broken, it can be seen through")


func test_whoever_stands_inside_a_closed_gate_neither_hits_out_nor_is_hit() -> void:
	# F6b: the owner crosses its closed gate, and whoever stays inside it (the chest inside the sight box)
	# hit outward without those outside being able to hit them: the ray that starts inside a box did not
	# see it. Now the gate stops the ray in both directions.
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	var in_the_gate: Vector3 = Vector3(0.1, 0.0, 0.5)
	var outside: Vector3 = Vector3(-1.8, 0.0, 0.5)
	var inside: Vector3 = Vector3(1.8, 0.0, 0.5)
	for owner_realm: int in [0, VARDHEIM]:
		_gate.set_state(owner_realm, false)
		await wait_physics_frames(2)
		assert_false(HitShapes.has_line_of_sight(space, in_the_gate, outside),
				"owner %d: from inside the gate one does not hit outward" % owner_realm)
		assert_false(HitShapes.has_line_of_sight(space, in_the_gate, inside), "nor inward")
		assert_false(HitShapes.has_line_of_sight(space, outside, in_the_gate), "nor is one hit from outside")
	_gate.set_state(VARDHEIM, true)
	await wait_physics_frames(2)
	assert_true(HitShapes.has_line_of_sight(space, in_the_gate, outside), "broken, the doorway is free")
	assert_true(HitShapes.has_line_of_sight(space, outside, in_the_gate))


# --- Helpers ----------------------------------------------------------------------------------

## Creates a character of realm [param realm] (-1 = without calling set_realm_collision) 6 m west of
## the gate, at the doorway's height [param z], facing east.
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


## Makes a character run east for each entry in [param realms] (realm -> z) and
## returns {realm: bool} with whether it crossed the gate.
func _run_all(realms: Dictionary) -> Dictionary:
	var characters: Dictionary = {}
	for realm: int in realms:
		characters[realm] = _spawn(realm, float(realms[realm]))
	await wait_physics_frames()
	for _i: int in RUN_TICKS:
		# A single step per physics tick and per character (all at once: they do not collide with each other).
		for realm: int in characters:
			_step(characters[realm])
		await wait_physics_frames()
	var crossed: Dictionary = {}
	for realm: int in characters:
		var character: PlayerCharacter = characters[realm]
		crossed[realm] = character.global_position.x > CROSSED_X
		if not crossed[realm]:
			assert_true(character.global_position.x < STOPPED_X + 0.1,
					"realm %d stays in front of the gate (x = %.2f)" % [realm, character.global_position.x])
	return crossed


## Collision mask of the camera's SpringArm3D, read from the scene (without instantiating its script).
func _camera_arm_mask() -> int:
	var state: SceneState = (load(CAMERA_RIG_SCENE) as PackedScene).get_state()
	for index: int in state.get_node_count():
		if state.get_node_name(index) != &"Arm":
			continue
		for property: int in state.get_node_property_count(index):
			if state.get_node_property_name(index, property) == "collision_mask":
				return int(state.get_node_property_value(index, property))
	fail("the camera scene does not have the arm with a mask")
	return 0


## Useful length of a camera arm (3.5 m, 20 cm sphere, like the scene's) starting from the
## head of someone inside the fort (x = 1.5) towards the west, through the gate's doorway.
func _arm_length_through_the_gate(mask: int) -> float:
	var arm := SpringArm3D.new()
	arm.collision_mask = mask
	var sphere := SphereShape3D.new()
	sphere.radius = 0.2
	arm.shape = sphere
	arm.spring_length = 3.5
	arm.margin = 0.15
	# The arm's local +Z axis points west (-X).
	arm.transform = Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(1.5, 1.6, 0.0))
	_world.add_child(arm)
	await wait_physics_frames(3)
	var length: float = arm.get_hit_length()
	_world.remove_child(arm)
	arm.free()
	return length
