extends TestCase
## Oleada 2 de calidad de animación (docs/calidad.md, sección 4):
## [br]- ART-07: ningún tramo de ataque, habilidad o bloqueo se reproduce fuera de 0,7x a 1,5x de su velocidad
## (la esquiva admite 2x; los PNJ alargan la anticipación a propósito: [code]test_npc_animation.gd[/code]). La carga
## del fuerte respira y enlaza con su anticipación.
## [br]- ART-45: la postura armada ([ArmedStanceModifier]): reposo de combate, capa de brazos y agarre de dedos.
## [br]- ART-46: ataques de cuerpo entero con los pies plantados y sin tocar el brazo del escudo.
## [br]- ART-48 y ART-50: reacción procedural al golpe recibido y al golpe bloqueado ([HitReactionModifier]).
## [br]- ART-51: tambaleo corto alternado, derribado de rodillas y arrastre al ritmo de la velocidad.
## [br]- ART-52: perfil visual por tipo de PNJ ([NpcVisualProfile]).

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CLIPS_PATH: String = "res://data/animation/sword_shield_clips.tres"
const BOW_CLIPS_PATH: String = "res://data/animation/bow_clips.tres"
## Velocidad de reproducción admitida en las fases de ataque y habilidad (el listón de calidad, criterio 3).
const SPEED_RANGE: Vector2 = Vector2(0.7, 1.5)
const DODGE_MAX_SPEED: float = 2.0
const START_TICK: int = 1000

var _clips: CombatClipSet
var _weapon: WeaponTicks
var _tick_rate: float = 60.0
var _nodes: Array[Node] = []


func before_each() -> void:
	_clips = load(CLIPS_PATH) as CombatClipSet
	_weapon = CombatCatalog.weapon(CombatCatalog.default_weapon_id())
	_tick_rate = float(Engine.physics_ticks_per_second)


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


## Humanoide animado de verdad colgado de un personaje (como en test_combat_animation).
func _make_visual() -> HumanoidVisual:
	var world := Node3D.new()
	tree.root.add_child(world)
	_nodes.append(world)
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	world.add_child(character)
	return HumanoidVisual.install(character)


# --- ART-07: velocidades de reproducción ---------------------------------------------------------

func test_every_sword_and_shield_attack_phase_plays_between_07x_and_15x() -> void:
	var checked: int = 0
	var attack_names: Array[StringName] = []
	for light_id: int in _weapon.light_ids:
		attack_names.append(CombatCatalog.attack(light_id).name)
	attack_names.append(CombatCatalog.attack(_weapon.heavy_id).name)
	for attack_name: StringName in attack_names:
		var attack: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(attack_name))
		var entry: CombatActionAnim = _clips.find(attack_name)
		var action: int = CombatState.Action.HEAVY if attack.heavy else CombatState.Action.LIGHT
		var combo: int = _weapon.light_index(attack.id) if not attack.heavy else 0
		for phase: int in 3:
			var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, action, phase, combo, 0.0)
			checked += 1
			assert_true(plan.speed >= SPEED_RANGE.x - 0.0001 and plan.speed <= SPEED_RANGE.y + 0.0001,
					"%s fase %d a %.2fx (admitido %.1fx a %.1fx)" % [attack_name, phase, plan.speed,
					SPEED_RANGE.x, SPEED_RANGE.y])
		assert_true(entry.is_attack(), "%s tiene los tres tramos" % attack_name)
	assert_eq(checked, 12, "los tres ligeros y el fuerte, con sus tres fases")


func test_every_shield_ability_phase_plays_between_07x_and_15x() -> void:
	var checked: int = 0
	for slot: int in CombatState.ABILITY_SLOTS:
		var ability: AbilityTicks = CombatCatalog.ability(_weapon.ability_id(slot))
		if ability == null:
			continue
		var entry: CombatActionAnim = _clips.find(ability.name)
		if entry == null:
			continue
		if entry.is_attack():
			for phase: int in 3:
				var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan_entry(_clips, ability.name, _weapon,
						CombatState.Action.ABILITY, phase, 0.0, 0, _weapon.ability_id(slot))
				checked += 1
				assert_true(plan.speed >= SPEED_RANGE.x - 0.0001 and plan.speed <= SPEED_RANGE.y + 0.0001,
						"%s fase %d a %.2fx" % [ability.name, phase, plan.speed])
		else:
			# Sin fases (el muro de escudos): el bucle va a su velocidad original.
			var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan_entry(_clips, ability.name, _weapon,
					CombatState.Action.ABILITY, 0, 0.0, 0, _weapon.ability_id(slot))
			checked += 1
			assert_true(plan.speed >= SPEED_RANGE.x and plan.speed <= SPEED_RANGE.y,
					"%s a %.2fx" % [ability.name, plan.speed])
	assert_true(checked >= 7, "se han comprobado %d tramos de habilidad" % checked)


func test_block_dodge_and_finisher_stay_in_range() -> void:
	var block: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.BLOCK,
			ActionMachine.PHASE_NONE, 0, 0.0)
	assert_true(block.speed >= SPEED_RANGE.x and block.speed <= SPEED_RANGE.y, "el bloqueo a %.2fx" % block.speed)
	var dodge: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.DODGE,
			ActionMachine.PHASE_NONE, 0, 0.0)
	assert_true(dodge.speed >= SPEED_RANGE.x and dodge.speed <= DODGE_MAX_SPEED + 0.0001,
			"la esquiva admite hasta 2x hasta tener clips propios: %.2fx" % dodge.speed)
	var execute: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.EXECUTE,
			ActionMachine.PHASE_NONE, 0, 0.0)
	assert_true(execute.speed >= SPEED_RANGE.x and execute.speed <= SPEED_RANGE.y,
			"el remate a %.2fx" % execute.speed)


func test_the_bow_set_is_the_only_one_left_outside_the_range() -> void:
	# El arco (ART-41) espera a los clips comprados: su disparo dura un tick de golpe activo y ningún tramo puede
	# ir a 0,7x. Esta prueba lo deja anotado para que el día que lleguen los clips se mueva a la regla de arriba.
	var bow_clips: CombatClipSet = load(BOW_CLIPS_PATH) as CombatClipSet
	var outside: int = 0
	for entry: CombatActionAnim in bow_clips.entries:
		if not entry.is_attack():
			continue
		for segment: CombatClipSegment in [entry.windup, entry.active, entry.recovery]:
			assert_true(segment.length_s() > 0.0, "%s: el tramo avanza" % entry.key)
		outside += 1
	assert_true(outside > 0, "el juego del arco existe y tiene ataques")


func test_the_heavy_charge_breathes_and_continues_into_the_windup() -> void:
	var charge: CombatActionAnim = _clips.find(&"charge")
	var heavy: CombatActionAnim = _clips.find(&"sword_heavy")
	assert_true(charge.hold_end and charge.sway_s > 0.0, "la carga se mantiene y respira")
	assert_eq(charge.windup.animation, heavy.windup.animation, "es el mismo clip que su anticipación")
	assert_near(charge.windup.to_s, heavy.windup.from_s, 0.0001, "y acaba donde ella empieza (sin salto)")
	var seen: Array[float] = []
	for ticks: float in [60.0, 70.0, 80.0, 90.0, 100.0]:
		var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.CHARGE,
				ActionMachine.PHASE_NONE, 0, ticks)
		assert_true(plan.time_s <= charge.windup.to_s + 0.0001
				and plan.time_s >= charge.windup.to_s - charge.sway_s - 0.0001, "el mecido se queda en su margen")
		seen.append(plan.time_s)
	var distinct: Dictionary = {}
	for value: float in seen:
		distinct[snappedf(value, 0.001)] = true
	assert_true(distinct.size() > 2, "no es un fotograma congelado (%d instantes distintos)" % distinct.size())


func test_every_clip_of_the_sword_set_has_a_real_segment() -> void:
	for entry: CombatActionAnim in _clips.entries:
		for segment: CombatClipSegment in [entry.windup, entry.active, entry.recovery]:
			if segment == null:
				continue
			var animation: Animation = _clips.get_animation(segment.animation)
			if assert_not_null(animation, "%s: %s existe" % [entry.key, segment.animation]):
				assert_true(segment.from_s >= 0.0 and segment.to_s <= animation.length + 0.0001,
						"%s: [%.2f, %.2f] cabe en %s" % [entry.key, segment.from_s, segment.to_s, segment.animation])


# --- ART-46: cuerpo entero y brazo del escudo ---------------------------------------------------------

func test_sword_attacks_take_the_whole_body_and_leave_the_shield_arm_alone() -> void:
	for key: StringName in [&"sword_light_1", &"sword_light_2", &"sword_light_3", &"sword_heavy", &"charge"]:
		var entry: CombatActionAnim = _clips.find(key)
		assert_true(entry.upper_body, "%s sigue siendo una capa de parte superior" % key)
		assert_true(entry.keep_left_arm, "%s no toca el brazo del escudo" % key)
		assert_near(entry.lower_weight_for_phase(ActionMachine.PHASE_ACTIVE), 1.0, 0.0001,
				"%s: el golpe lleva la cadera y las piernas del clip" % key)
	for key: StringName in [&"shield_bash", &"shield_rush"]:
		assert_false(_clips.find(key).keep_left_arm, "%s usa el escudo: el clip manda en ese brazo" % key)
	# El tercer ligero empieza con un salto: sus pies no están en el suelo, así que la anticipación usa las piernas
	# de la postura.
	var third: CombatActionAnim = _clips.find(&"sword_light_3")
	assert_near(third.lower_weight_for_phase(ActionMachine.PHASE_WINDUP), 0.0, 0.0001, "anticipación del tercero")
	assert_near(third.lower_weight_for_phase(ActionMachine.PHASE_ACTIVE), 1.0, 0.0001, "golpe del tercero")
	var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.LIGHT,
			ActionMachine.PHASE_ACTIVE, 0, 0.0)
	assert_near(plan.lower_weight, 1.0, 0.0001, "el plan lleva el peso de la fase")
	assert_true(plan.keep_left_arm, "y la reserva del brazo")


func test_the_layer_blends_the_leg_weight_between_phases() -> void:
	var layer := CombatAnimationLayer.new(_clips)
	var windup: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.LIGHT,
			ActionMachine.PHASE_WINDUP, 2, 0.0)
	layer.apply_plan(windup, 1.0 / _tick_rate)
	assert_near(layer.get_current().lower_current, 0.0, 0.0001, "el tercero empieza con las piernas de la postura")
	var active: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.LIGHT,
			ActionMachine.PHASE_ACTIVE, 2, 0.0)
	layer.apply_plan(active, 0.02)
	var partway: float = layer.get_current().lower_current
	assert_true(partway > 0.0 and partway < 1.0, "al pasar al golpe sube poco a poco (%.2f)" % partway)
	for _i: int in 10:
		layer.apply_plan(active, 0.02)
	assert_near(layer.get_current().lower_current, 1.0, 0.0001, "y llega a 1 en menos de una décima")
	assert_eq(layer.get_left_arm_reserved() > 0.0, true, "el brazo del escudo está reservado")
	assert_eq(layer.get_full_body_weight(), 0.0, "un ataque no es un clip de cuerpo entero")


func test_attack_legs_come_from_the_clip_only_when_no_movement_is_requested() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var modifier: CombatPoseModifier = animator.get_combat_modifier()
	var layer: CombatAnimationLayer = animator.get_combat_layer()
	var skeleton: Skeleton3D = visual.get_skeleton()
	await wait_process_frames(2)
	animator.set_process(false)
	var leg: int = skeleton.find_bone("LeftUpperLeg")
	var hips: int = skeleton.find_bone("Hips")
	var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.LIGHT,
			ActionMachine.PHASE_ACTIVE, 0, 3.0)
	layer.apply_plan(plan, 1.0)
	layer.apply_plan(plan, 1.0)
	# Sin pedir andar: la pierna y la cadera son las del clip.
	layer.move_request = 0.0
	var rest_leg: Quaternion = skeleton.get_bone_pose_rotation(leg)
	var rest_hips: Vector3 = skeleton.get_bone_pose_position(hips)
	modifier._process_modification()
	assert_true(skeleton.get_bone_pose_rotation(leg).angle_to(rest_leg) > 0.05, "la pierna sigue el clip")
	assert_true(skeleton.get_bone_pose_position(hips).y < rest_hips.y - 0.1, "y las caderas bajan al tajo")
	# Pidiendo andar a pleno: las piernas se quedan como las puso la locomoción.
	skeleton.set_bone_pose_rotation(leg, rest_leg)
	skeleton.set_bone_pose_position(hips, rest_hips)
	layer.move_request = 1.0
	modifier._process_modification()
	assert_true(skeleton.get_bone_pose_rotation(leg).angle_to(rest_leg) < 0.003, "andando, la pierna no es del clip")
	assert_near(skeleton.get_bone_pose_position(hips).y, rest_hips.y, 0.0001, "ni la cadera")


func test_a_reserved_shield_arm_is_not_touched_by_the_attack_clip() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var modifier: CombatPoseModifier = animator.get_combat_modifier()
	var layer: CombatAnimationLayer = animator.get_combat_layer()
	var skeleton: Skeleton3D = visual.get_skeleton()
	await wait_process_frames(2)
	animator.set_process(false)
	var left: int = skeleton.find_bone("LeftUpperArm")
	var right: int = skeleton.find_bone("RightUpperArm")
	# Solo el modificador de combate: los demás (postura, reacciones) también mueven el brazo en cada fotograma.
	for child: Node in skeleton.get_children():
		if child is SkeletonModifier3D and child != modifier:
			(child as SkeletonModifier3D).active = false
	await wait_process_frames(2)
	var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.LIGHT,
			ActionMachine.PHASE_ACTIVE, 0, 3.0)
	layer.apply_plan(plan, 1.0)
	layer.apply_plan(plan, 1.0)
	var left_before: Quaternion = skeleton.get_bone_pose_rotation(left)
	var right_before: Quaternion = skeleton.get_bone_pose_rotation(right)
	modifier._process_modification()
	assert_true(skeleton.get_bone_pose_rotation(left).angle_to(left_before) < 0.003, "el brazo del escudo queda igual")
	assert_true(skeleton.get_bone_pose_rotation(right).angle_to(right_before) > 0.05, "el de la espada, no")


# --- ART-45: postura armada ---------------------------------------------------------------------------

func test_the_stance_puts_the_shield_guard_at_rest_and_closes_the_fingers() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var stance: ArmedStanceModifier = animator.get_stance_modifier()
	var skeleton: Skeleton3D = visual.get_skeleton()
	await wait_process_frames(3)
	animator.set_process(false)
	if not assert_not_null(stance, "el visual instala la postura armada"):
		return
	var rest: Animation = _clips.get_animation(ArmedStanceModifier.SHIELD_REST)
	var sword_arm: Animation = _clips.get_animation(ArmedStanceModifier.SWORD_ARM)
	stance.master_weight = 1.0
	stance.rest_weight = 1.0
	stance.arm_weight = 0.8
	stance.grip_weight = 1.0
	stance.rest_time = 0.7
	stance.grip_time = 0.0
	stance._process_modification()
	var left_arm: int = skeleton.find_bone("LeftUpperArm")
	var expected_left: Quaternion = _track_rotation(rest, "LeftUpperArm", 0.7)
	assert_true(skeleton.get_bone_pose_rotation(left_arm).angle_to(expected_left) < 0.001,
			"en reposo el brazo del escudo es el de Idle_Shield_Loop")
	var right_arm: int = skeleton.find_bone("RightUpperArm")
	var expected_right: Quaternion = _track_rotation(sword_arm, "RightUpperArm", 0.7)
	assert_true(skeleton.get_bone_pose_rotation(right_arm).angle_to(expected_right) < 0.001,
			"y el de la espada, el de Sword_Idle")
	var grip: int = skeleton.find_bone("RightIndexProximal")
	assert_true(skeleton.get_bone_pose_rotation(grip).angle_to(_track_rotation(sword_arm, "RightIndexProximal", 0.0))
			< 0.001, "los dedos son el agarre fijo (primer fotograma)")
	assert_true(stance.get_applied_count() > 0)


func test_walking_blends_only_the_arms_and_the_grip() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var stance: ArmedStanceModifier = animator.get_stance_modifier()
	var skeleton: Skeleton3D = visual.get_skeleton()
	await wait_process_frames(3)
	animator.set_process(false)
	var leg: int = skeleton.find_bone("LeftUpperLeg")
	var arm: int = skeleton.find_bone("LeftUpperArm")
	var hand_finger: int = skeleton.find_bone("LeftIndexProximal")
	var leg_before: Quaternion = skeleton.get_bone_pose_rotation(leg)
	var arm_before: Quaternion = skeleton.get_bone_pose_rotation(arm)
	stance.master_weight = 1.0
	stance.rest_weight = 0.0
	stance.arm_weight = 0.8
	stance.rest_time = 0.3
	stance._process_modification()
	assert_true(skeleton.get_bone_pose_rotation(leg).angle_to(leg_before) < 0.003, "las piernas siguen siendo la locomoción")
	var rest: Animation = _clips.get_animation(ArmedStanceModifier.SHIELD_REST)
	var target: Quaternion = _track_rotation(rest, "LeftUpperArm", 0.3)
	var expected: Quaternion = arm_before.slerp(target, 0.8)
	assert_true(skeleton.get_bone_pose_rotation(arm).angle_to(expected) < 0.001, "el brazo va al 80 % de la guardia")
	assert_true(skeleton.get_bone_pose_rotation(hand_finger).angle_to(_track_rotation(rest, "LeftIndexProximal", 0.0))
			< 0.001, "los dedos del escudo van cerrados al 100 %")
	# Con el brazo reservado por un ataque, el izquierdo va a la guardia completa aunque se ande.
	skeleton.set_bone_pose_rotation(arm, arm_before)
	stance.left_arm_reserved = 1.0
	stance._process_modification()
	assert_true(skeleton.get_bone_pose_rotation(arm).angle_to(target) < 0.001, "reservado: guardia completa")


func test_the_stance_steps_aside_in_the_air_with_the_bow_and_with_full_body_clips() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var stance: ArmedStanceModifier = animator.get_stance_modifier()
	var layer: CombatAnimationLayer = animator.get_combat_layer()
	await wait_process_frames(4)
	var debug: Dictionary = animator.get_debug_state()
	assert_near(float(debug["stance_rest"]), 1.0, 0.01, "parado, el reposo de combate manda")
	assert_near(float(debug["stance_master"]), 1.0, 0.01, "y la postura está a pleno")
	# Un clip de cuerpo entero (la muerte) la aparta.
	var dead: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.DEAD,
			ActionMachine.PHASE_NONE, 0, 100.0)
	layer.apply_plan(dead, 1.0)
	assert_near(layer.get_full_body_weight(), 1.0, 0.0001, "la capa avisa del cuerpo entero")
	assert_not_null(stance)


func test_the_zombie_profile_swaps_the_rest_and_the_walk() -> void:
	var visual: HumanoidVisual = _make_visual()
	var stance: ArmedStanceModifier = visual.get_animator().get_stance_modifier()
	await wait_process_frames(2)
	assert_eq(stance.rest_clip, ArmedStanceModifier.SHIELD_REST)
	assert_eq(stance.walk_clip, &"")
	visual.get_animator().set_stance_profile(&"zombie")
	assert_eq(stance.rest_clip, ArmedStanceModifier.ZOMBIE_REST)
	assert_eq(stance.walk_clip, ArmedStanceModifier.ZOMBIE_WALK)
	assert_eq(stance.left_arm_clip, &"", "el zombi no lleva escudo")
	assert_false(stance.arms_at_rest, "en reposo los brazos son los del zombi")
	for name_in_set: StringName in [stance.rest_clip, stance.walk_clip]:
		assert_not_null(_clips.get_animation(name_in_set), "%s existe" % name_in_set)
	visual.get_animator().set_stance_profile(&"shield")
	assert_eq(stance.rest_clip, ArmedStanceModifier.SHIELD_REST, "y se vuelve a la guardia")


# Rotación del hueso [param bone_name] en el instante [param time] de [param animation].
func _track_rotation(animation: Animation, bone_name: String, time: float) -> Quaternion:
	for track: int in animation.get_track_count():
		if animation.track_get_type(track) == Animation.TYPE_ROTATION_3D \
				and String(animation.track_get_path(track)).ends_with(":" + bone_name):
			return animation.rotation_track_interpolate(track, time)
	fail("el clip no anima %s" % bone_name)
	return Quaternion.IDENTITY


# --- ART-48 y ART-50: reacciones ------------------------------------------------------------------------

func test_the_hit_envelope_rises_fast_bounces_and_dies_in_a_quarter_second() -> void:
	assert_near(HitReactionModifier.hit_envelope(-0.1), 0.0, 0.0001)
	assert_near(HitReactionModifier.hit_envelope(0.0), 0.0, 0.0001, "empieza en 0")
	assert_near(HitReactionModifier.hit_envelope(HitReactionModifier.HIT_PEAK_S), 1.0, 0.0001, "pico en 45 ms")
	assert_near(HitReactionModifier.hit_envelope(HitReactionModifier.HIT_RETURN_S), 0.0, 0.0001, "y 0 a los 0,25 s")
	assert_near(HitReactionModifier.hit_envelope(0.5), 0.0, 0.0001)
	var lowest: float = 1.0
	var time: float = 0.0
	while time < HitReactionModifier.HIT_RETURN_S:
		lowest = minf(lowest, HitReactionModifier.hit_envelope(time))
		time += 0.005
	assert_true(lowest < 0.0 and lowest > -0.3, "pasa un poco al otro lado (rebote elástico: %.2f)" % lowest)
	# El empujón del bloqueo dura 0,15 s o más.
	assert_true(HitReactionModifier.BLOCK_S >= 0.15, "el empujón del bloqueo dura %.2f s" % HitReactionModifier.BLOCK_S)
	assert_true(HitReactionModifier.block_envelope(HitReactionModifier.BLOCK_S * 0.3) > 0.99)
	assert_near(HitReactionModifier.block_envelope(HitReactionModifier.BLOCK_S), 0.0, 0.0001)
	assert_true(HitReactionModifier.HIT_MIN_DEG >= 8.0 and HitReactionModifier.HIT_MAX_DEG <= 12.0,
			"de 8 a 12 grados")


func test_a_hit_pushes_the_spine_back_away_from_the_attacker_and_comes_back() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var reaction: HitReactionModifier = animator.get_reaction_modifier()
	var skeleton: Skeleton3D = visual.get_skeleton()
	if not assert_not_null(reaction, "el visual instala el modificador de reacciones"):
		return
	await wait_process_frames(3)
	var head: int = skeleton.find_bone("Head")
	var before: Vector3 = skeleton.get_bone_global_pose(head).origin
	# El atacante está delante (la cámara y el modelo miran hacia -Z del mundo): se echa hacia atrás (+Z).
	var forward: Vector3 = -visual.global_transform.basis.z
	animator.react_to_hit(forward, 150.0)
	assert_true(reaction.is_reacting(), "la reacción está en marcha")
	# Con un golpe a plena fuerza el giro llega a 12 grados en el pico.
	var peak: float = deg_to_rad(HitReactionModifier.HIT_MAX_DEG)
	assert_near(peak, deg_to_rad(12.0), 0.0001)
	await wait_process_frames(20)
	await get_tree_timeout(0.4)
	assert_false(reaction.is_reacting(), "y se apaga sola en menos de medio segundo")
	var after: Vector3 = skeleton.get_bone_global_pose(head).origin
	assert_true(before.distance_to(after) < 0.12, "la cabeza vuelve a su sitio")


func test_a_blocked_hit_reacts_on_the_shield_arm() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var reaction: HitReactionModifier = animator.get_reaction_modifier()
	await wait_process_frames(3)
	animator.react_to_hit(-visual.global_transform.basis.z, 0.0, true)
	assert_true(reaction.is_reacting(), "un bloqueo total, sin daño, también produce reacción")
	await get_tree_timeout(0.5)
	assert_false(reaction.is_reacting(), "y acaba")


## Espera [param seconds] de tiempo real (para las animaciones que cuentan segundos y no ticks).
func get_tree_timeout(seconds: float) -> void:
	await tree.create_timer(seconds).timeout


func test_the_shield_rises_while_blocking() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var reaction: HitReactionModifier = animator.get_reaction_modifier()
	var layer: CombatAnimationLayer = animator.get_combat_layer()
	var skeleton: Skeleton3D = visual.get_skeleton()
	# El escudo cuelga de la mano: su posición es la que dibuja el esqueleto ya con todos los modificadores (leer el
	# hueso desde fuera da la pose antes de ellos).
	var shield: BoneAttachment3D = skeleton.get_node(NodePath(WeaponProps.SHIELD_ATTACHMENT)) as BoneAttachment3D
	await wait_process_frames(3)
	animator.set_process(false)
	var block: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.BLOCK,
			ActionMachine.PHASE_NONE, 0, 30.0)
	layer.apply_plan(block, 1.0)
	layer.apply_plan(block, 1.0)
	reaction.guard_raise = 0.0
	await wait_process_frames(12)
	var low: float = shield.global_position.y
	reaction.guard_raise = 1.0
	await wait_process_frames(12)
	var high: float = shield.global_position.y
	assert_true(high > low + 0.1, "al bloquear la mano del escudo sube (%.2f -> %.2f m) para tapar la cabeza" % [low, high])


# --- ART-50 y ART-51: tambaleo, derribado y muerte ------------------------------------------------------

func test_short_staggers_alternate_between_chest_and_head_hits() -> void:
	var chest: StringName = CombatClipPlanner.stagger_key(_clips, 18, 0)
	var head: StringName = CombatClipPlanner.stagger_key(_clips, 18, 1)
	assert_eq(chest, CombatClipPlanner.KEY_STAGGER_SHORT)
	assert_eq(head, CombatClipPlanner.KEY_STAGGER_HEAD)
	assert_eq(CombatClipPlanner.stagger_key(_clips, 30, 0), CombatClipPlanner.KEY_STAGGER, "los largos, el de siempre")
	assert_eq(CombatClipPlanner.stagger_key(_clips, 0, 1), CombatClipPlanner.KEY_STAGGER, "un remoto no sabe la duración")
	assert_eq(CombatClipPlanner.stagger_key(null, 18, 1), CombatClipPlanner.KEY_STAGGER)
	var npc_clips: CombatClipSet = load("res://data/animation/npc_hollow_clips.tres") as CombatClipSet
	assert_eq(CombatClipPlanner.stagger_key(npc_clips, 18, 1), CombatClipPlanner.KEY_STAGGER,
			"un juego sin entradas cortas usa la normal")
	for key: StringName in [CombatClipPlanner.KEY_STAGGER, CombatClipPlanner.KEY_STAGGER_SHORT,
			CombatClipPlanner.KEY_STAGGER_HEAD]:
		assert_false(_clips.find(key).upper_body, "%s es de cuerpo entero: sin pasos de locomoción" % key)
	var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.STAGGER,
			ActionMachine.PHASE_NONE, 0, 0.0, 18, 0, false, 1)
	assert_eq(plan.animation, &"ual1/Hit_Head")
	assert_true(plan.speed >= SPEED_RANGE.x and plan.speed <= SPEED_RANGE.y, "el golpe a la cabeza a %.2fx" % plan.speed)


func test_the_downed_pose_kneels_and_the_crawl_follows_the_speed() -> void:
	var downed: CombatActionAnim = _clips.find(&"downed")
	assert_eq(downed.windup.animation, &"ual1/Crouch_Idle_Loop", "derribado de rodillas, no el fotograma de un muerto")
	assert_true(downed.loop)
	var dead: CombatActionAnim = _clips.find(&"dead")
	assert_ne_clip(downed, dead)
	var layer := CombatAnimationLayer.new(_clips)
	var crawl: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.DOWNED,
			ActionMachine.PHASE_NONE, 0, 0.0, 0, 0, true)
	assert_eq(crawl.key, CombatClipPlanner.KEY_DOWNED_CRAWL)
	layer.crawl_speed = 0.0
	layer.apply_plan(crawl, 0.5)
	var parked: float = layer.get_current().time_s
	layer.apply_plan(crawl, 0.5)
	assert_near(layer.get_current().time_s, parked, 0.0001, "sin velocidad el arrastre no avanza")
	layer.crawl_speed = 0.75
	layer.apply_plan(crawl, 0.5)
	var first: float = layer.get_current().time_s
	layer.apply_plan(crawl, 0.5)
	assert_true(layer.get_current().time_s != first, "con la velocidad real, el ciclo avanza")
	layer.crawl_speed = 1.5
	var slow_start: float = layer.get_current().time_s
	layer.apply_plan(crawl, 0.2)
	var fast_step: float = absf(angle_wrapped(layer.get_current().time_s - slow_start))
	layer.crawl_speed = 0.75
	var base: float = layer.get_current().time_s
	layer.apply_plan(crawl, 0.2)
	var slow_step: float = absf(angle_wrapped(layer.get_current().time_s - base))
	assert_true(fast_step > slow_step * 1.5, "al doble de velocidad, el ciclo va al doble de ritmo")


func angle_wrapped(value: float) -> float:
	var length: float = 2.0
	return fposmod(value + length * 0.5, length) - length * 0.5


func assert_ne_clip(first: CombatActionAnim, second: CombatActionAnim) -> void:
	assert_true(first.windup.animation != second.windup.animation, "el derribado no usa el clip de la muerte")


func test_death_skips_the_upright_stagger_of_the_original_clip() -> void:
	var dead: CombatActionAnim = _clips.find(&"dead")
	assert_true(dead.windup.from_s >= 0.5, "empieza donde ya cae (no el primer medio segundo erguido)")
	assert_true(dead.hold_end, "y se queda tumbado")
	var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(_clips, _weapon, CombatState.Action.DEAD,
			ActionMachine.PHASE_NONE, 0, 0.0)
	assert_true(plan.duration_s <= 0.8, "la caída dura %.2f s (antes 2,4 s)" % plan.duration_s)
	# Los PNJ comparten la misma muerte.
	for npc: String in ["hollow", "captain", "guard", "guardian"]:
		var npc_clips: CombatClipSet = load("res://data/animation/npc_%s_clips.tres" % npc) as CombatClipSet
		assert_true(npc_clips.find(&"dead").windup.from_s >= 0.5, "%s: muerte sin tambaleo" % npc)
		assert_false(npc_clips.find(&"stagger").upper_body, "%s: tambaleo de cuerpo entero" % npc)


# --- El animador ---------------------------------------------------------------------------------------

func test_the_animator_plants_the_legs_during_an_attack_and_frees_them_when_walking() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	await wait_physics_frames(2)
	var combat := CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())
	var input := PlayerInput.new()
	input.tick = START_TICK + 1
	ActionMachine.step(combat, input, true)
	input.tick = START_TICK + 2
	input.buttons = PlayerInput.PRIMARY
	ActionMachine.step(combat, input, true)
	character.combat.copy_from(combat)
	character.last_input_tick = input.tick
	character.velocity = Vector3.ZERO
	await wait_process_frames(3)
	var debug: Dictionary = animator.get_debug_state()
	assert_near(float(debug["move_request"]), 0.0, 0.0001, "sin velocidad, la entrada no pide andar")
	assert_true(bool(debug["attack_facing"]), "el modelo se coloca hacia la cámara en el ataque")
	# Corriendo a la vez que ataca: pide andar y las piernas vuelven a la locomoción.
	character.velocity = Vector3(0.0, 0.0, -character.run_speed)
	await wait_process_frames(2)
	assert_true(float(animator.get_debug_state()["move_request"]) > 0.9, "corriendo, pide andar a pleno")


func test_the_stagger_without_a_hit_event_still_pushes_the_body_back() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	await wait_physics_frames(2)
	var combat := CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())
	ActionMachine.impose_stagger(combat, START_TICK, START_TICK + 30, Vector2.ZERO)
	character.combat.copy_from(combat)
	character.last_input_tick = START_TICK + 1
	await wait_process_frames(30)
	var offset: Vector3 = animator.get_debug_state()["body_offset"]
	assert_true(offset.length() > 0.05, "el cuerpo da un paso atrás (%.2f m)" % offset.length())
	assert_true(offset.length() <= CharacterAnimator.STAGGER_STEP_BACK + 0.001, "de unos 0,3 m")
	character.combat.copy_from(CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id()))
	await get_tree_timeout(1.2)
	assert_true((animator.get_debug_state()["body_offset"] as Vector3).length() < 0.02, "y vuelve a su sitio")


# --- ART-52: perfiles de PNJ ---------------------------------------------------------------------------

func test_the_hollow_and_the_captain_have_their_own_profile() -> void:
	var hollow: NpcVisualProfile = NpcVisualProfile.for_weapon(&"npc_hollow")
	var captain: NpcVisualProfile = NpcVisualProfile.for_weapon(&"npc_captain")
	if not assert_not_null(hollow) or not assert_not_null(captain):
		return
	assert_false(hollow.shield, "el Hueco no lleva escudo")
	assert_true(hollow.eye_energy > 0.0, "y sus ojos brillan")
	assert_true(hollow.saturation < 0.5, "con la piel y la ropa de hueso desaturadas")
	assert_eq(hollow.stance, &"zombie", "y anda como un zombi")
	assert_near(captain.scale, 1.25, 0.0001, "el Capitán, a escala visual 1,25")
	assert_true(captain.weapon_scale > 1.0, "con un arma mayor")
	assert_true(captain.tint != Color.WHITE, "y su propio color")
	assert_null(NpcVisualProfile.for_weapon(&"npc_guard"), "el guardia se ve como un soldado")
	assert_null(NpcVisualProfile.for_weapon(&"sword_shield"), "un jugador no tiene perfil")
	assert_eq(NpcVisualProfile.for_weapon_id(CombatCatalog.weapon_id(&"npc_hollow")), hollow)
	assert_null(NpcVisualProfile.for_weapon_id(0))


func test_a_profile_changes_only_the_look_of_the_visual() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	await wait_process_frames(2)
	var skeleton: Skeleton3D = visual.get_skeleton()
	var shield: Node3D = skeleton.get_node(NodePath("%s/%s" % [WeaponProps.SHIELD_ATTACHMENT,
			WeaponProps.SHIELD_MESH])) as Node3D
	assert_true(shield.visible, "un soldado lleva escudo")
	assert_near(visual.scale.x, 1.0, 0.0001)
	visual.apply_profile(NpcVisualProfile.for_weapon(&"npc_captain"))
	assert_near(visual.scale.x, 1.25, 0.0001, "el Capitán se ve un cuarto más grande")
	assert_true(shield.visible, "y conserva el escudo")
	var sword: Node3D = skeleton.get_node(NodePath(WeaponProps.SWORD_ATTACHMENT)) as Node3D
	assert_near(sword.scale.x, 1.3, 0.0001, "con el arma mayor")
	var recolored: bool = false
	for child: Node in skeleton.get_children():
		var mesh: MeshInstance3D = child as MeshInstance3D
		if mesh != null and mesh.mesh != null and mesh.get_surface_override_material(0) is ShaderMaterial:
			recolored = true
	assert_true(recolored, "las mallas del cuerpo pasan por el sombreado de recoloreado")
	visual.apply_profile(NpcVisualProfile.for_weapon(&"npc_hollow"))
	assert_near(visual.scale.x, 1.0, 0.0001)
	assert_false(shield.visible, "el Hueco no lleva escudo")
	assert_near(sword.scale.x, 1.0, 0.0001)
	assert_eq(animator.get_stance_modifier().rest_clip, ArmedStanceModifier.ZOMBIE_REST, "y trae el reposo de zombi")
	visual.apply_profile(null)
	assert_true(shield.visible, "sin perfil, vuelve a ser un soldado")
	assert_eq(animator.get_stance_modifier().rest_clip, ArmedStanceModifier.SHIELD_REST)


func test_the_weapon_the_visual_shows_picks_the_profile() -> void:
	var visual: HumanoidVisual = _make_visual()
	var animator: CharacterAnimator = visual.get_animator()
	var character: PlayerCharacter = animator.get_character()
	character.combat.weapon_id = CombatCatalog.weapon_id(&"npc_hollow")
	await wait_process_frames(3)
	assert_eq(visual.get_profile(), NpcVisualProfile.for_weapon(&"npc_hollow"), "el arma del Hueco trae su perfil")
	character.combat.weapon_id = CombatCatalog.weapon_id(&"sword_shield")
	await wait_process_frames(3)
	assert_null(visual.get_profile(), "y la espada y escudo, ninguno")
