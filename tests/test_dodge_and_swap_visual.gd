extends TestCase
## Visual details of the combat animator that do not touch the simulation:
## [br]- ART-49: during the dodge the model faces the direction of travel from the first frame and returns to normal at the end.
## [br]- ART-06: when switching weapons, the hand accessories change mid-gesture and not on the first
## frame.
## [br]- ART-06: the sword, the shield and the bow cast shadows.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"

## Waiting frames for the dodge's entry turn to finish (0.08 s, with margin).
const DODGE_TURN_FRAMES: int = 30

var _nodes: Array[Node] = []


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


## true if [param node] hangs from a [SwordTrail] below [param root].
static func _is_under_trail(node: Node, root: Node) -> bool:
	var current: Node = node
	while current != null and current != root:
		if current is SwordTrail:
			return true
		current = current.get_parent()
	return false


func _make_visual() -> HumanoidVisual:
	var world := Node3D.new()
	tree.root.add_child(world)
	_nodes.append(world)
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	world.add_child(character)
	return HumanoidVisual.install(character)


func _start_dodge(character: PlayerCharacter, heading: float) -> void:
	character.combat.action = CombatState.Action.DODGE
	character.combat.action_tick = character.last_input_tick
	character.combat.action_dir = CombatState.quantize_yaw(heading)


func _offset_deg(animator: CharacterAnimator) -> float:
	return float(animator.get_debug_state()["facing_offset_deg"])


# --- Oriented dodge (ART-49) ------------------------------------------------------------------

func test_the_model_faces_the_dodge_heading_from_the_first_frame() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	await wait_process_frames(3)
	assert_near(_offset_deg(animator), 0.0, 0.5, "standing still, it faces as the simulation does")
	# Dodge backwards (heading +Z, back to the crosshair): the model turns around at once.
	_start_dodge(character, PI)
	await wait_process_frames(1)
	var partial: float = absf(_offset_deg(animator))
	assert_true(partial < 170.0, "the entry turn does not fit in one frame (%.0f degrees)" % partial)
	await wait_process_frames(DODGE_TURN_FRAMES)
	assert_near(absf(_offset_deg(animator)), 180.0, 1.0, "dodge backwards: the model ends up facing backwards")
	assert_near(float(animator.get_debug_state()["spine_twist_deg"]), 0.0, 0.01,
			"and the spine does not compensate for the turn during the roll")
	assert_true(bool(animator.get_debug_state()["dodging"]))
	# To the left (heading -X: yaw +90 degrees in the rotation.y convention).
	character.combat.action = CombatState.Action.NONE
	await wait_process_frames(60)
	_start_dodge(character, PI * 0.5)
	await wait_process_frames(DODGE_TURN_FRAMES)
	assert_near(_offset_deg(animator), 90.0, 1.0, "dodge to the left: turns 90 degrees")
	# To the right (heading +X).
	character.combat.action = CombatState.Action.NONE
	await wait_process_frames(60)
	_start_dodge(character, -PI * 0.5)
	await wait_process_frames(DODGE_TURN_FRAMES)
	assert_near(_offset_deg(animator), -90.0, 1.0, "dodge to the right: turns -90 degrees")
	# Forward it does not turn.
	character.combat.action = CombatState.Action.NONE
	await wait_process_frames(60)
	_start_dodge(character, 0.0)
	await wait_process_frames(1)
	assert_near(_offset_deg(animator), 0.0, 1.0, "dodge forward: it was already facing that way")


func test_the_model_turns_back_smoothly_when_the_dodge_ends() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	await wait_process_frames(3)
	_start_dodge(character, PI)
	await wait_process_frames(DODGE_TURN_FRAMES)
	assert_near(absf(_offset_deg(animator)), 180.0, 1.0)
	character.combat.action = CombatState.Action.NONE
	await wait_process_frames(1)
	var first: float = absf(_offset_deg(animator))
	assert_true(first > 100.0, "at the end it does not turn around at once (%.0f degrees)" % first)
	assert_false(bool(animator.get_debug_state()["dodging"]))
	await tree.create_timer(1.0).timeout
	assert_near(_offset_deg(animator), 0.0, 1.0, "and it ends up facing as the simulation does")
	assert_near(float(animator.get_debug_state()["spine_twist_deg"]), 0.0, 0.5)


func test_a_remote_dodge_faces_its_velocity() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	var dodge_byte: int = CombatState.Action.DODGE | (ActionMachine.PHASE_NONE << 4)
	animator.set_remote_source(func() -> int: return dodge_byte, func() -> int: return character.combat.weapon_id)
	await wait_process_frames(2)
	# Rolls towards +X with the camera (yaw 0) facing -Z: the model turns 90 degrees to the right.
	character.velocity = Vector3(6.0, 0.0, 0.0)
	await wait_process_frames(DODGE_TURN_FRAMES)
	assert_near(_offset_deg(animator), -90.0, 1.0, "faces the velocity")


# --- Weapon swap mid-gesture (ART-06) ---------------------------------------------------------

func test_the_props_change_in_the_middle_of_the_swap_gesture() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var animator: CharacterAnimator = visual.get_animator()
	var skeleton: Skeleton3D = visual.get_skeleton()
	var sword: BoneAttachment3D = skeleton.get_node(NodePath(WeaponProps.SWORD_ATTACHMENT)) as BoneAttachment3D
	var sword_id: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow_id: int = CombatCatalog.weapon_id(&"bow")
	var action: Array[int] = [CombatState.Action.NONE | (ActionMachine.PHASE_NONE << 4)]
	var holder: Array[int] = [sword_id]
	animator.set_remote_source(func() -> int: return action[0], func() -> int: return holder[0])
	await wait_process_frames(3)
	assert_eq(animator.get_shown_weapon(), sword_id)
	assert_true(sword.visible)
	# The swap starts: the id is already the bow's, but the hands stay the same during the first part.
	holder[0] = bow_id
	action[0] = CombatState.Action.SWAP | (ActionMachine.PHASE_NONE << 4)
	await wait_process_frames(2)
	assert_eq(animator.get_shown_weapon(), sword_id, "on the first frame of the gesture they do not change")
	assert_true(sword.visible, "the sword is still in hand")
	# Mid-gesture they do.
	var half: float = float(CombatCatalog.tables().swap_ticks) / float(Engine.physics_ticks_per_second) \
			* animator.swap_show_fraction
	await tree.create_timer(half + 0.15).timeout
	assert_eq(animator.get_shown_weapon(), bow_id, "mid-gesture the bow appears")
	assert_false(sword.visible, "and the sword is stowed")


func test_the_props_change_at_once_when_it_is_not_a_swap() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	await wait_process_frames(3)
	character.combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	await wait_process_frames(2)
	assert_eq(animator.get_shown_weapon(), CombatCatalog.weapon_id(&"bow"), "without a gesture, they change instantly")


func test_a_swap_that_ends_early_shows_the_new_weapon_at_once() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var animator: CharacterAnimator = visual.get_animator()
	var sword_id: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow_id: int = CombatCatalog.weapon_id(&"bow")
	var action: Array[int] = [CombatState.Action.SWAP | (ActionMachine.PHASE_NONE << 4)]
	var holder: Array[int] = [sword_id]
	animator.set_remote_source(func() -> int: return action[0], func() -> int: return holder[0])
	await wait_process_frames(3)
	holder[0] = bow_id
	await wait_process_frames(1)
	action[0] = CombatState.Action.NONE | (ActionMachine.PHASE_NONE << 4)
	await wait_process_frames(2)
	assert_eq(animator.get_shown_weapon(), bow_id, "if the gesture is cut off, it does not keep the old weapon")


# --- Weapon shadows (ART-06) ------------------------------------------------------------------

func test_the_weapons_cast_shadows() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var skeleton: Skeleton3D = visual.get_skeleton()
	var sword: Node = skeleton.get_node(NodePath(WeaponProps.SWORD_ATTACHMENT))
	var left: Node = skeleton.get_node(NodePath(WeaponProps.SHIELD_ATTACHMENT))
	WeaponProps.show_weapon(skeleton, CombatCatalog.weapon_id(&"bow"))
	# The sword trail (SwordTrail) is an effect: it must not cast a shadow. Everything else (the
	# sword, whether the own model or the fallback box, the shield disc and the bow) does, except the string.
	var meshes: Array[MeshInstance3D] = []
	var trail_meshes: int = 0
	for root: Node in [sword, left]:
		for mesh_node: Node in root.find_children("*", "MeshInstance3D", true, false):
			if _is_under_trail(mesh_node, root):
				trail_meshes += 1
				assert_eq((mesh_node as MeshInstance3D).cast_shadow,
						GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "the trail casts no shadow")
				continue
			meshes.append(mesh_node as MeshInstance3D)
	assert_true(meshes.size() >= 7, "sword, disc and the four bow pieces (%d meshes)" % meshes.size())
	var casting: int = 0
	for mesh: MeshInstance3D in meshes:
		if mesh.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			casting += 1
		elif mesh.name != &"Cuerda":
			assert_true(false, "%s should cast a shadow" % mesh.name)
	assert_eq(casting, meshes.size() - 1, "all the pieces except the string cast a shadow")
