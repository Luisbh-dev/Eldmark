extends TestCase
## Detalles visuales del animador de combate que no tocan la simulación:
## [br]- ART-49: durante la esquiva el modelo mira hacia donde se viaja desde el primer fotograma y vuelve al acabar.
## [br]- ART-06: al cambiar de arma, los accesorios de las manos cambian a mitad del gesto y no en el primer
## fotograma.
## [br]- ART-06: la espada, el escudo y el arco proyectan sombra.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"

## Fotogramas de espera para que acabe el giro de entrada de la esquiva (0,08 s, con margen).
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


# --- Esquiva orientada (ART-49) ---------------------------------------------------------------

func test_the_model_faces_the_dodge_heading_from_the_first_frame() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	await wait_process_frames(3)
	assert_near(_offset_deg(animator), 0.0, 0.5, "parado, mira como la simulación")
	# Esquiva hacia atrás (rumbo a +Z, de espaldas a la mira): el modelo se da la vuelta de golpe.
	_start_dodge(character, PI)
	await wait_process_frames(1)
	var partial: float = absf(_offset_deg(animator))
	assert_true(partial < 170.0, "el giro de entrada no cabe en un fotograma (%.0f grados)" % partial)
	await wait_process_frames(DODGE_TURN_FRAMES)
	assert_near(absf(_offset_deg(animator)), 180.0, 1.0, "esquiva atrás: el modelo acaba mirando hacia atrás")
	assert_near(float(animator.get_debug_state()["spine_twist_deg"]), 0.0, 0.01,
			"y la columna no compensa el giro durante la voltereta")
	assert_true(bool(animator.get_debug_state()["dodging"]))
	# A la izquierda (rumbo -X: yaw +90 grados en la convención de rotation.y).
	character.combat.action = CombatState.Action.NONE
	await wait_process_frames(60)
	_start_dodge(character, PI * 0.5)
	await wait_process_frames(DODGE_TURN_FRAMES)
	assert_near(_offset_deg(animator), 90.0, 1.0, "esquiva a la izquierda: gira 90 grados")
	# A la derecha (rumbo +X).
	character.combat.action = CombatState.Action.NONE
	await wait_process_frames(60)
	_start_dodge(character, -PI * 0.5)
	await wait_process_frames(DODGE_TURN_FRAMES)
	assert_near(_offset_deg(animator), -90.0, 1.0, "esquiva a la derecha: gira -90 grados")
	# Hacia delante no gira.
	character.combat.action = CombatState.Action.NONE
	await wait_process_frames(60)
	_start_dodge(character, 0.0)
	await wait_process_frames(1)
	assert_near(_offset_deg(animator), 0.0, 1.0, "esquiva adelante: ya miraba hacia allí")


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
	assert_true(first > 100.0, "al acabar no se da la vuelta de golpe (%.0f grados)" % first)
	assert_false(bool(animator.get_debug_state()["dodging"]))
	await tree.create_timer(1.0).timeout
	assert_near(_offset_deg(animator), 0.0, 1.0, "y acaba mirando como la simulación")
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
	# Rueda hacia +X con la cámara (yaw 0) mirando a -Z: el modelo gira 90 grados a la derecha.
	character.velocity = Vector3(6.0, 0.0, 0.0)
	await wait_process_frames(DODGE_TURN_FRAMES)
	assert_near(_offset_deg(animator), -90.0, 1.0, "mira hacia la velocidad")


# --- Cambio de arma a mitad del gesto (ART-06) ------------------------------------------------

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
	# Empieza el cambio: el id ya es el del arco, pero las manos siguen igual durante la primera parte.
	holder[0] = bow_id
	action[0] = CombatState.Action.SWAP | (ActionMachine.PHASE_NONE << 4)
	await wait_process_frames(2)
	assert_eq(animator.get_shown_weapon(), sword_id, "en el primer fotograma del gesto no cambian")
	assert_true(sword.visible, "la espada sigue en la mano")
	# A mitad del gesto sí.
	var half: float = float(CombatCatalog.tables().swap_ticks) / float(Engine.physics_ticks_per_second) \
			* animator.swap_show_fraction
	await tree.create_timer(half + 0.15).timeout
	assert_eq(animator.get_shown_weapon(), bow_id, "a mitad del gesto aparece el arco")
	assert_false(sword.visible, "y la espada se guarda")


func test_the_props_change_at_once_when_it_is_not_a_swap() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	await wait_process_frames(3)
	character.combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	await wait_process_frames(2)
	assert_eq(animator.get_shown_weapon(), CombatCatalog.weapon_id(&"bow"), "sin gesto, cambian al instante")


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
	assert_eq(animator.get_shown_weapon(), bow_id, "si el gesto se corta, no se queda con el arma vieja")


# --- Sombras de las armas (ART-06) ------------------------------------------------------------

func test_the_weapons_cast_shadows() -> void:
	var visual: HumanoidVisual = _make_visual()
	if not assert_not_null(visual):
		return
	var skeleton: Skeleton3D = visual.get_skeleton()
	var sword: Node = skeleton.get_node(NodePath(WeaponProps.SWORD_ATTACHMENT))
	var left: Node = skeleton.get_node(NodePath(WeaponProps.SHIELD_ATTACHMENT))
	WeaponProps.show_weapon(skeleton, CombatCatalog.weapon_id(&"bow"))
	var meshes: Array[MeshInstance3D] = []
	for root: Node in [sword, left]:
		for mesh_node: Node in root.find_children("*", "MeshInstance3D", true, false):
			meshes.append(mesh_node as MeshInstance3D)
	assert_eq(meshes.size(), 7, "hoja, guarda, disco y las cuatro piezas del arco")
	var casting: int = 0
	for mesh: MeshInstance3D in meshes:
		if mesh.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			casting += 1
		elif mesh.name != &"Cuerda":
			assert_true(false, "%s debería proyectar sombra" % mesh.name)
	assert_eq(casting, 6, "todas las piezas menos la cuerda proyectan sombra")
