class_name HumanoidVisual
extends Node3D
## Visual look of a humanoid (client only): modular model + animation.
##
## Root of [code]scenes/characters/visuals/humanoid_visual.tscn[/code]. It simulates nothing: it decorates a
## [PlayerCharacter] (expected chain: PlayerCharacter > Visual > HumanoidVisual) and its child
## [CharacterAnimator] reads the character's state every frame.
## [br][br]
## The base model ([code]Pivot/Model[/code]) is a Quaternius glTF with the common UAL skeleton already
## converted to Godot's humanoid profile ([code]%GeneralSkeleton[/code], see
## [code]assets/animations/rig/ual_humanoid_bone_map.tres[/code]). The pieces of
## [member part_scenes] (head, hair, beard...) are imported with the same BoneMap, so on
## startup their meshes are moved to that skeleton and share the pose: a single skeleton animates everything.
## [br][br]
## The model faces -Z like the [PlayerCharacter] (Quaternius glTFs face +Z, which is
## why [code]Model[/code] is rotated 180°). The origin is at the feet and it stands about 1.8 m tall.
## [br][br]
## [b]Pieces per slot[/b] (docs/progression.md §7.4, ART-19): the base model's meshes are the
## [code]body[/code] slot and those of [member part_scenes] are those of [member part_slots] ([code]head[/code],
## [code]hair[/code], [code]beard[/code]). [method set_part] and [method clear_part] change a slot without
## recreating the character: the node, the skeleton, the animator and the weapons stay; only the meshes of
## that slot are removed and those of the new scene are attached (setting the scene that is already there does nothing). [method set_tint]
## tints skin, hair (also beard and eyebrows) and eyes per material, also on pieces mounted later.
## Before [method _ready], changes are stored and applied on entering. Used by [AppearanceApplier].

## [b]Sound and effects of each character[/b] (ART-11, ART-09): footsteps come from the feet (the
## [constant FOOT_BONES] bones, with the surface from [FootstepSurface]), and the jump, the landing and the actions of
## remotes from the animator's signals; the heavy attack's charge aura hangs from the sword and the hitstop
## freezes the combat clip ([method start_hitstop]). It is all client-side and requested from [CombatAudio] and [CombatVfx] if
## they exist.
## [br][br]
## Scene of this visual (loaded in [method install]; not preloaded to avoid creating a
## scene -> script -> scene cycle).
const SCENE_PATH: String = "res://scenes/characters/visuals/humanoid_visual.tscn"
## Node of the [PlayerCharacter] that groups the visuals (the camera hides it when it gets close).
const VISUAL_NODE: NodePath = ^"Visual"
## Name of the single skeleton the BoneMap leaves on import ("Make Unique" option).
const SKELETON_NAME: String = "GeneralSkeleton"
## Hood meshes (shown with [member hood_visible]).
const HOOD_MESH_PREFIX: String = "Male_Ranger_Head_Hood"
## Long hair meshes that are hidden with a hood (eyebrows and beard stay).
const HAIR_MESH_PREFIXES: PackedStringArray = ["Hair_SimpleParted"]
## Small meshes that cast no shadow (in a 1.8 m shadow they cannot be told apart and each one
## costs a draw call per shadow split).
const NO_SHADOW_MESH_PREFIXES: PackedStringArray = [
	"Eyes", "Eyebrows", "Hair_Beard", "Male_Ranger_Body_Belt",
]

## Distance to the camera (m) below which another player's visual with [member camera_fade] is hidden
## entirely, and distance from which it is seen whole. Between the two it is dithered (ART-53).
const CAMERA_FADE_HIDDEN: float = 0.5
const CAMERA_FADE_SOLID: float = 1.2
## Height (m) above the feet of the point from which the distance to the camera is measured.
const CAMERA_FADE_CHEST_HEIGHT: float = 1.2

## Foot bones (Godot humanoid profile) from which footsteps come (ART-11): a step sounds when the foot
## touches the ground again, not at a fixed rhythm, so it matches what is seen.
const FOOT_BONES: Array[StringName] = [&"LeftFoot", &"RightFoot"]
## Height (m) above the lowest point the foot has had from which it counts as lifted, and below which
## it counts as planted.
const FOOT_LIFT_HEIGHT: float = 0.075
const FOOT_PLANT_HEIGHT: float = 0.035
## How much the recent minimum of each foot rises per second (m/s). It goes by time and not by frames, so that
## the step does not depend on FPS.
const FOOT_LOW_RATE: float = 0.24
## Horizontal speed (m/s) below which no footsteps sound (a pose change in place is not walking).
const STEP_MIN_SPEED: float = 0.6
## Scene of the heavy hit's charge aura.
const CHARGE_AURA_SCENE: String = "res://scenes/vfx/charge_aura.tscn"

## Piece slots that [method set_part] accepts.
const PART_SLOTS: Array[StringName] = [&"body", &"head", &"hair", &"beard", &"marks"]
## Tint channels of [method set_tint] and the name prefix of the Universal Base
## Characters materials that each one tints (the skin material of the body and head, that of the hair, beard and
## eyebrows, and that of the eyes). # TODO(art): provisional until the skin and eye shaders of ART-20.
## Deliberately untyped: in Godot 4.7.2 a [code]const Dictionary[StringName, PackedStringArray][/code] written
## with array literals stores an [Array] with the type of [PackedStringArray] and iterating it reads garbage or crashes.
const TINT_MATERIAL_PREFIXES: Dictionary = {
	&"skin": ["MI_Regular_", "MI_Superhero_"],
	&"hair": ["MI_Hair"],
	&"eyes": ["MI_Eyes"],
}

## Extra pieces with the same skeleton (glTF scenes imported with the UAL BoneMap). Their meshes
## are moved to the base model's skeleton in [method _ready].
@export var part_scenes: Array[PackedScene] = []
## Slot of each scene in [member part_scenes], in the same order (any missing ones have no slot and cannot
## be changed with [method set_part]).
@export var part_slots: Array[StringName] = [&"head", &"hair", &"beard"]
## Shows the suit's hood. With a hood the hair is hidden so that it does not clip through it.
@export var hood_visible: bool = false:
	set(value):
		hood_visible = value
		if is_node_ready():
			_apply_hood()

## Fades the visual (a single transparency for all its meshes) when the camera is closer than [constant CAMERA_FADE_SOLID] m, and
## hides it closer than [constant CAMERA_FADE_HIDDEN] (ART-53). It is for other players' characters: there is no collision
## between characters, and a torso or a shield stuck to the camera filled half the screen in melees. The
## own character does not use it (the camera already hides its visual when approaching). It is applied with the engine's
## visibility ranges on all meshes, also those of the pieces and weapons mounted later.
@export var camera_fade: bool = false:
	set(value):
		camera_fade = value
		if is_node_ready():
			_apply_camera_fade()

@onready var _model: Node3D = $Pivot/Model

var _skeleton: Skeleton3D = null
# true if the camera_fade visibility ranges are set on the meshes.
var _camera_fade_applied: bool = false
var _fade_meshes: Array[MeshInstance3D] = []
var _fade_value: float = -1.0
# NPC visual profile set (ART-52) or null.
var _profile: NpcVisualProfile = null
# Sword variant requested before _ready (empty = none).
var _realm: int = 0
var _foot_ids: Array[int] = []
var _foot_low: Array[float] = []
var _foot_prev: Array[float] = []
var _foot_planted: Array[bool] = []
var _charge_aura: ChargeAura = null
var _pending_sword_variant: StringName = &""
# Slot -> its meshes (attached to the skeleton) and the path of the scene they came from.
var _part_meshes: Dictionary[StringName, Array] = {}
var _part_paths: Dictionary[StringName, String] = {}
# Changes requested before _ready (slot -> scene; null = remove).
var _pending_parts: Dictionary[StringName, PackedScene] = {}
# Channel -> color of [method set_tint].
var _tints: Dictionary[StringName, Color] = {}
# Base material + color -> tinted material, shared by all visuals (the colors are those of the
# catalog: few).
static var _tinted_materials: Dictionary[String, Material] = {}


## Attaches a new HumanoidVisual under the Visual node of [param character] and hides the
## placeholder meshes that were already there (the phase 1 capsule and visor). Meant to be called
## from the client right after instantiating the character, so that the shared scene
## [code]player_character.tscn[/code] (which the server will also load) does not drag models or
## animations along. Returns the created visual, or null if the scene could not be loaded.
static func install(character: PlayerCharacter) -> HumanoidVisual:
	var scene: PackedScene = load(SCENE_PATH) as PackedScene
	if scene == null or character == null:
		push_error("[HumanoidVisual] No se pudo instalar el visual (%s)" % SCENE_PATH)
		return null
	var visual_root: Node3D = character.get_node_or_null(VISUAL_NODE) as Node3D
	if visual_root == null:
		visual_root = Node3D.new()
		visual_root.name = String(VISUAL_NODE)
		character.add_child(visual_root)
	for child: Node in visual_root.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).visible = false
	var visual: HumanoidVisual = scene.instantiate() as HumanoidVisual
	visual_root.add_child(visual)
	visual.attach_to(character)
	return visual


## Same as [method install], but it also removes the placeholder meshes from the Visual node (the capsule
## and the visor of [code]player_character.tscn[/code]), which stay light for the server. If the
## visual does not load, it returns null and the capsule stays so that something is visible. Used by the sandbox
## ([ClientMain]), the local character of [OnlineMain] and the remotes of [RemoteWorld].
static func install_replacing_placeholder(character: PlayerCharacter) -> HumanoidVisual:
	var visual: HumanoidVisual = install(character)
	if visual == null:
		return null
	var visual_root: Node = visual.get_parent()
	for child: Node in visual_root.get_children():
		if child is MeshInstance3D:
			visual_root.remove_child(child)
			child.queue_free()
	return visual


func _ready() -> void:
	_skeleton = _find_skeleton(_model)
	if _skeleton == null:
		push_error("[HumanoidVisual] El modelo no tiene un Skeleton3D '%s'" % SKELETON_NAME)
		return
	# The base model's meshes are the "body" slot.
	var body_meshes: Array[MeshInstance3D] = []
	for child: Node in _skeleton.get_children():
		if child is MeshInstance3D:
			body_meshes.append(child as MeshInstance3D)
	_part_meshes[&"body"] = body_meshes
	_part_paths[&"body"] = _model.scene_file_path
	for index: int in range(part_scenes.size()):
		var slot: StringName = part_slots[index] if index < part_slots.size() else &""
		if slot != &"" and _pending_parts.has(slot):
			continue
		var meshes: Array[MeshInstance3D] = _attach_part(part_scenes[index])
		if slot != &"" and part_scenes[index] != null:
			_part_meshes[slot] = meshes
			_part_paths[slot] = part_scenes[index].resource_path
	for slot: StringName in _pending_parts:
		if _pending_parts[slot] == null:
			clear_part(slot)
		else:
			set_part(slot, _pending_parts[slot])
	_pending_parts.clear()
	_apply_hood()
	_apply_shadow_casting()
	_apply_tints()
	# Placeholder weapons in the hands (ART-06): until the final models arrive. The animator
	# reports the weapon being carried (the character's active one or the one in a remote's record) and its props are shown
	# (phase 4: the bow or the sword and shield).
	WeaponProps.install(_skeleton)
	if _pending_sword_variant != &"":
		WeaponProps.set_sword_variant(_skeleton, _pending_sword_variant)
	get_animator().weapon_shown.connect(_on_weapon_shown)
	# The sword trail follows the active phase of the hit, also that of remotes.
	get_animator().swing_active_changed.connect(_on_swing_active_changed)
	# Combat stance over locomotion (ART-45): the combat idle, the arm layer and the grip. It goes before
	# the combat pose, which overrides it when there is a hit or a dodge.
	var stance := ArmedStanceModifier.new()
	stance.name = "ArmedStance"
	_skeleton.add_child(stance)
	get_animator().set_stance_modifier(stance)
	get_animator().jumped_visual.connect(_on_jumped_visual)
	get_animator().touched_down.connect(_on_touched_down)
	get_animator().remote_action_started.connect(_on_remote_action_started)
	get_animator().charge_changed.connect(_on_charge_changed)
	_setup_feet()
	# Combat pose over locomotion (ART-08). It goes before the spine twist, which is
	# applied on top.
	var combat := CombatPoseModifier.new()
	combat.name = "CombatPose"
	_skeleton.add_child(combat)
	get_animator().set_combat_modifier(combat)
	# Procedural reactions to a received or blocked hit and shield at head height (ART-48, ART-50).
	var reaction := HitReactionModifier.new()
	reaction.name = "HitReaction"
	_skeleton.add_child(reaction)
	get_animator().set_reaction_modifier(reaction)
	# Spine twist toward the crosshair (driven by the animator).
	var spine := SpineTwistModifier.new()
	spine.name = "SpineTwist"
	_skeleton.add_child(spine)
	get_animator().set_spine_modifier(spine)
	# The weapons and modifiers are already attached: the visibility ranges reach them too.
	_apply_camera_fade()


func _on_weapon_shown(weapon_id: int) -> void:
	WeaponProps.show_weapon(_skeleton, weapon_id)
	# An NPC with a visual profile (ART-52) changes the shield, color, eyes, scale and stance.
	apply_profile(NpcVisualProfile.for_weapon_id(weapon_id))
	# The bow is created the first time it is needed: its meshes also get faded.
	_apply_camera_fade()


## Applies the visual profile of an NPC type ([NpcVisualProfile], ART-52), or removes it with null: visual scale, color
## of the body meshes, eye glow, shield and weapon in the hands and the animator's stance. It is visual only: the
## character's capsule and the hitboxes do not change.
func apply_profile(profile: NpcVisualProfile) -> void:
	_profile = profile
	scale = Vector3.ONE * (profile.scale if profile != null else 1.0)
	if _skeleton != null:
		_apply_tints()
		_apply_profile_props()
	var animator: CharacterAnimator = get_animator()
	if animator != null:
		animator.set_stance_profile(profile.stance if profile != null else &"shield")


## Visual profile currently set (null if none).
func get_profile() -> NpcVisualProfile:
	return _profile


## The character receives a hit of [param amount] damage from [param attacker_direction] (world vector, from the
## victim toward the attacker), or blocks it with the shield if [param blocked]: procedural body reaction (ART-48,
## ART-50). See [method CharacterAnimator.react_to_hit].
func react_to_hit(attacker_direction: Vector3, amount: float = 0.0, blocked: bool = false) -> void:
	get_animator().react_to_hit(attacker_direction, amount, blocked)


# Shield and weapon in the hands according to the profile: no shield on the Hollow and a greater weapon on the Ford Captain.
func _apply_profile_props() -> void:
	var shield_node: Node3D = _skeleton.get_node_or_null(NodePath("%s/%s" % [WeaponProps.SHIELD_ATTACHMENT,
			WeaponProps.SHIELD_MESH])) as Node3D
	var sword_attachment: Node3D = _skeleton.get_node_or_null(NodePath(WeaponProps.SWORD_ATTACHMENT)) as Node3D
	var shown_bow: bool = get_animator().get_shown_weapon() >= 0 \
			and CombatCatalog.weapon(get_animator().get_shown_weapon()) != null \
			and CombatCatalog.weapon(get_animator().get_shown_weapon()).name == WeaponProps.BOW_WEAPON
	if shield_node != null and not shown_bow:
		shield_node.visible = _profile == null or _profile.shield
	if sword_attachment != null:
		sword_attachment.scale = Vector3.ONE * (_profile.weapon_scale if _profile != null else 1.0)


func _on_swing_active_changed(active: bool) -> void:
	WeaponProps.set_swing_active(_skeleton, active, get_animator().get_current_action() == CombatState.Action.HEAVY)


## Freezes this character's combat animation for [param seconds] (the hitstop of ART-09, visual only).
func start_hitstop(seconds: float) -> void:
	var layer: CombatAnimationLayer = get_animator().get_combat_layer()
	if layer != null:
		layer.start_hitstop(seconds)


## The [HumanoidVisual] that decorates [param body] (null if it has none).
static func of_body(body: Node) -> HumanoidVisual:
	if body == null:
		return null
	return body.get_node_or_null(NodePath(String(VISUAL_NODE) + "/HumanoidVisual")) as HumanoidVisual


# --- Sound and effects -------------------------------------------------------------------------

func _setup_feet() -> void:
	for bone_name: StringName in FOOT_BONES:
		var index: int = _skeleton.find_bone(bone_name)
		if index >= 0:
			_foot_ids.append(index)
			_foot_low.append(INF)
			_foot_prev.append(INF)
			_foot_planted.append(false)
	if not _foot_ids.is_empty():
		_skeleton.skeleton_updated.connect(_check_feet)


# A step sounds when a foot drops to its recent lowest point: the height of each foot is tracked in skeleton
# space and the minimum is noted, and the step is the "lifted" to "planted" edge with the foot going down.
func _check_feet() -> void:
	var animator: CharacterAnimator = get_animator()
	var character: PlayerCharacter = animator.get_character()
	if character == null or not is_inside_tree():
		return
	var moving: bool = character.grounded and character.get_horizontal_speed() > STEP_MIN_SPEED \
			and animator.get_current_action() != CombatState.Action.DODGE
	var step_delta: float = get_process_delta_time()
	for index: int in _foot_ids.size():
		var pose: Transform3D = _skeleton.get_bone_global_pose(_foot_ids[index])
		if _track_foot(index, pose.origin.y, step_delta) and moving:
			_play_step(_skeleton.global_transform * pose.origin, character)


# Tracks the height [param height] of foot [param index] over [param step_delta] s and says whether it has just planted (the
# step). Separate from [method _check_feet] to test it with synthetic heights and frames.
func _track_foot(index: int, height: float, step_delta: float) -> bool:
	if _foot_low[index] == INF:
		_foot_low[index] = height
	else:
		_foot_low[index] = minf(_foot_low[index] + FOOT_LOW_RATE * step_delta, height)
	var above: float = height - _foot_low[index]
	var falling: bool = _foot_prev[index] != INF and height <= _foot_prev[index]
	_foot_prev[index] = height
	if above > FOOT_LIFT_HEIGHT:
		_foot_planted[index] = false
	elif above < FOOT_PLANT_HEIGHT and falling and not _foot_planted[index]:
		_foot_planted[index] = true
		return true
	return false


func _play_step(position: Vector3, character: PlayerCharacter) -> void:
	var audio: CombatAudio = CombatAudio.get_instance()
	if audio == null:
		return
	var run: float = maxf(character.run_speed, 0.001)
	audio.play_step(position, FootstepSurface.kind_at(self, position),
			clampf(character.get_horizontal_speed() / run, 0.0, 1.0), not get_animator().is_remote())


func _on_jumped_visual() -> void:
	var audio: CombatAudio = CombatAudio.get_instance()
	var character: PlayerCharacter = get_animator().get_character()
	if audio != null and character != null:
		audio.play_jump(character.global_position, FootstepSurface.kind_at(self, character.global_position),
				not get_animator().is_remote())


func _on_touched_down(strength: float) -> void:
	var character: PlayerCharacter = get_animator().get_character()
	if character == null:
		return
	var audio: CombatAudio = CombatAudio.get_instance()
	if audio != null:
		audio.play_land(character.global_position, FootstepSurface.kind_at(self, character.global_position),
				strength, not get_animator().is_remote())
	var vfx: CombatVfx = CombatVfx.get_instance()
	if vfx != null and strength >= 0.45:
		vfx.play_land_dust(character.global_position, strength)


# A new action of a remote: sweep, dodge or ability (the own ones are distributed by CombatFeedback).
func _on_remote_action_started(action: int, step: int) -> void:
	var character: PlayerCharacter = get_animator().get_character()
	if character == null:
		return
	var feet: Vector3 = character.global_position
	var chest: Vector3 = feet + Vector3(0.0, 1.2, 0.0)
	var heading: Vector3 = character.global_basis * Vector3.FORWARD
	var audio: CombatAudio = CombatAudio.get_instance()
	var vfx: CombatVfx = CombatVfx.get_instance()
	var weapon: WeaponTicks = CombatCatalog.weapon(get_animator().get_shown_weapon())
	match action:
		CombatState.Action.LIGHT, CombatState.Action.HEAVY:
			if audio == null:
				return
			var attack: AttackTicks = null
			if weapon != null:
				if action == CombatState.Action.HEAVY:
					attack = CombatCatalog.attack(weapon.heavy_id)
				elif step >= 0 and step < weapon.light_ids.size():
					attack = CombatCatalog.attack(weapon.light_ids[step])
			var tick_s: float = 1.0 / float(Engine.physics_ticks_per_second)
			audio.play_swing(chest, action == CombatState.Action.HEAVY,
					float(attack.windup_ticks) * tick_s if attack != null else 0.0,
					float(attack.active_ticks) * tick_s if attack != null else 0.0, false)
		CombatState.Action.DODGE:
			if audio != null:
				audio.play_dodge(feet + Vector3(0.0, 0.5, 0.0), false)
			if vfx != null:
				vfx.play_dodge_dust(feet, character.velocity)
		CombatState.Action.ABILITY:
			if vfx != null and weapon != null:
				var ability: AbilityTicks = CombatCatalog.ability(CombatClipPlanner.ability_of_slot(weapon, step))
				if ability != null:
					vfx.play_ability(ability.name, feet, heading, _realm)


# The heavy hit's charge aura: it lights up on starting to charge, grows with the charge, pulses on reaching the maximum
# and bursts on release (or goes out if cancelled).
func _on_charge_changed(active: bool, fraction: float) -> void:
	if active:
		if _charge_aura == null:
			var scene: PackedScene = load(CHARGE_AURA_SCENE) as PackedScene
			if scene == null:
				return
			_charge_aura = scene.instantiate() as ChargeAura
			add_child(_charge_aura)
			_charge_aura.set_weapon(_aura_mount())
			_charge_aura.set_realm(_realm)
		if not _charge_aura.is_playing():
			_charge_aura.play()
		_charge_aura.set_charge(fraction)
	elif _charge_aura != null and _charge_aura.is_playing():
		if get_animator().get_current_action() == CombatState.Action.HEAVY:
			_charge_aura.release()
		else:
			_charge_aura.stop()


## The charge aura (null until it is first loaded).
func get_charge_aura() -> ChargeAura:
	return _charge_aura


# Sword node with the +X axis along the blade (from the base mark to the tip mark of the model) and the scale
# that fits the aura's glow (designed for a 1 m blade) to the real blade. Without marks, the sword node.
func _aura_mount() -> Node3D:
	var root: Node3D = WeaponProps.get_sword_node(_skeleton)
	if root == null:
		return null
	var existing: Node3D = root.get_node_or_null(^"AuraMount") as Node3D
	if existing != null:
		return existing
	var base_marker: Node3D = root.find_child(String(SwordModel.TRAIL_BASE_NAME), true, false) as Node3D
	var tip_marker: Node3D = root.find_child(String(SwordModel.TRAIL_TIP_NAME), true, false) as Node3D
	if base_marker == null or tip_marker == null:
		return root
	var to_root: Transform3D = root.global_transform.affine_inverse()
	var base: Vector3 = to_root * base_marker.global_position
	var tip: Vector3 = to_root * tip_marker.global_position
	var along: Vector3 = tip - base
	var length: float = along.length()
	if length < 0.01:
		return root
	var x_axis: Vector3 = along / length
	var helper: Vector3 = Vector3.UP if absf(x_axis.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var z_axis: Vector3 = x_axis.cross(helper).normalized()
	var y_axis: Vector3 = z_axis.cross(x_axis).normalized()
	var scale: float = length / ChargeAura.BLADE_LENGTH
	var mount := Node3D.new()
	mount.name = "AuraMount"
	mount.transform = Transform3D(Basis(x_axis, y_axis, z_axis).scaled(Vector3.ONE * scale),
			base - x_axis * ChargeAura.BLADE_BASE * scale)
	root.add_child(mount)
	return mount


## Sets the sword of realm [param realm] ([enum NetProtocol.Realm] code; any other, the base one):
## the model and the trail color. Before [method _ready] it is stored and applied on entering.
func set_realm(realm: int) -> void:
	_realm = realm
	if _charge_aura != null:
		_charge_aura.set_realm(realm)
	var variant: StringName = RealmCatalog.id_of_code(realm)
	if not SwordModel.MODELS.has(variant):
		variant = SwordModel.BASE
	if _skeleton == null:
		_pending_sword_variant = variant
		return
	WeaponProps.set_sword_variant(_skeleton, variant)


## Skeleton that animates all the meshes (Godot humanoid profile: Hips, Head, RightHand...).
## The placeholder weapons ([WeaponProps]) and the pose modifiers hang from it.
func get_skeleton() -> Skeleton3D:
	return _skeleton


## Node the animator rotates to orient the model (direct child of this root).
func get_pivot() -> Node3D:
	return get_node(^"Pivot") as Node3D


## Animator that drives the [AnimationTree] from the [PlayerCharacter].
func get_animator() -> CharacterAnimator:
	return get_node(^"CharacterAnimator") as CharacterAnimator


## Decorates [param character]. If not called, the animator looks for the [PlayerCharacter] among its
## ancestors on entering the tree. It can be called before adding the visual to the tree.
func attach_to(character: PlayerCharacter) -> void:
	get_animator().set_character(character)


## Puts in slot [param slot] (one of [constant PART_SLOTS]) the meshes of [param scene], a glTF piece
## imported with the UAL BoneMap, and removes those it had. It does not recreate the character: the node, the skeleton, the
## animator and the weapons stay, and if the slot already has that scene it does nothing. With [param scene] null it is
## [method clear_part]. The hood, shadows and tints are applied to the new meshes too.
func set_part(slot: StringName, scene: PackedScene) -> void:
	if not PART_SLOTS.has(slot):
		push_warning("[HumanoidVisual] Ranura de pieza desconocida: %s" % slot)
		return
	if scene == null:
		clear_part(slot)
		return
	if not is_node_ready():
		_pending_parts[slot] = scene
		return
	if _skeleton == null:
		return
	if _part_paths.get(slot, "") == scene.resource_path and not scene.resource_path.is_empty():
		return
	_free_part(slot)
	_part_meshes[slot] = _attach_part(scene)
	_part_paths[slot] = scene.resource_path
	_apply_hood()
	_apply_shadow_casting()
	_apply_tints()
	_apply_camera_fade()


## Removes the meshes of slot [param slot] (no hair, no beard...). Does nothing if it was already empty.
func clear_part(slot: StringName) -> void:
	if not PART_SLOTS.has(slot):
		push_warning("[HumanoidVisual] Ranura de pieza desconocida: %s" % slot)
		return
	if not is_node_ready():
		_pending_parts[slot] = null
		return
	_free_part(slot)


## The meshes of slot [param slot] (empty if it has none).
func get_part_meshes(slot: StringName) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for mesh: Variant in _part_meshes.get(slot, []):
		if is_instance_valid(mesh):
			result.append(mesh as MeshInstance3D)
	return result


## Scene path of slot [param slot] (empty if it has none).
func get_part_path(slot: StringName) -> String:
	return _part_paths.get(slot, "")


## Tints channel [param channel] ([code]skin[/code], [code]hair[/code] or [code]eyes[/code], the keys of
## [constant TINT_MATERIAL_PREFIXES]) with [param color]: the albedo of its materials, multiplied by its
## texture. It also applies to pieces mounted later.
func set_tint(channel: StringName, color: Color) -> void:
	if not TINT_MATERIAL_PREFIXES.has(channel):
		push_warning("[HumanoidVisual] Canal de tinte desconocido: %s" % channel)
		return
	_tints[channel] = color
	_apply_tints()


## Color of channel [param channel], or null if it has not been tinted.
func get_tint(channel: StringName) -> Variant:
	return _tints.get(channel)


## Removes all tints (each mesh returns to its material).
func clear_tints() -> void:
	_tints.clear()
	_apply_tints()


## Moves the meshes of a piece to the base model's skeleton, discards the rest of the piece and returns the
## attached meshes.
func _attach_part(scene: PackedScene) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	if scene == null:
		return meshes
	var part: Node = scene.instantiate()
	_collect_meshes(part, meshes)
	if meshes.is_empty():
		push_warning("[HumanoidVisual] La pieza %s no tiene mallas" % scene.resource_path)
	for mesh: MeshInstance3D in meshes:
		mesh.get_parent().remove_child(mesh)
		mesh.owner = null
		_skeleton.add_child(mesh)
		mesh.transform = Transform3D.IDENTITY
		mesh.skeleton = mesh.get_path_to(_skeleton)
		mesh.reset_physics_interpolation()
	part.free()
	return meshes


func _free_part(slot: StringName) -> void:
	for mesh: Variant in _part_meshes.get(slot, []):
		if is_instance_valid(mesh):
			var node: MeshInstance3D = mesh as MeshInstance3D
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.queue_free()
	_part_meshes.erase(slot)
	_part_paths.erase(slot)


# The materials of each mesh of the skeleton according to the tints: the tinted version of its base material for the channel or, with no
# tint, its own.
func _apply_tints() -> void:
	if _skeleton == null:
		return
	for child: Node in _skeleton.get_children():
		var mesh: MeshInstance3D = child as MeshInstance3D
		if mesh == null or mesh.mesh == null:
			continue
		for surface: int in range(mesh.mesh.get_surface_count()):
			var base: Material = mesh.mesh.surface_get_material(surface)
			var channel: StringName = _tint_channel_of(base)
			var result: Material = null
			if channel != &"" and _tints.has(channel):
				result = _tinted(base, _tints[channel])
			if _profile != null and _profile.changes_look():
				result = _profiled(result if result != null else base, _profile, channel == &"eyes")
			mesh.set_surface_override_material(surface, result)


static func _tint_channel_of(material: Material) -> StringName:
	if material == null or not (material is BaseMaterial3D):
		return &""
	for channel: StringName in TINT_MATERIAL_PREFIXES:
		for prefix: String in TINT_MATERIAL_PREFIXES[channel]:
			if material.resource_name.begins_with(prefix):
				return channel
	return &""


static func _tinted(base: Material, color: Color) -> Material:
	var key: String = "%d|%s" % [base.get_instance_id(), color.to_html()]
	var tinted: Material = _tinted_materials.get(key)
	if tinted == null:
		tinted = base.duplicate()
		(tinted as BaseMaterial3D).albedo_color = color
		_tinted_materials[key] = tinted
	return tinted


# Material of [param base] with the NPC profile's color (ART-52) and, on the eyes, its emissive glow. They are shared
# among all NPCs of the same profile.
static func _profiled(base: Material, profile: NpcVisualProfile, is_eye: bool) -> Material:
	if not (base is BaseMaterial3D):
		return base
	var key: String = "p|%d|%s|%s" % [base.get_instance_id(), profile.id, is_eye]
	var made: Material = _tinted_materials.get(key)
	if made != null:
		return made
	var source: BaseMaterial3D = base as BaseMaterial3D
	if is_eye:
		if profile.eye_energy <= 0.0:
			return base
		var glow: BaseMaterial3D = source.duplicate() as BaseMaterial3D
		glow.emission_enabled = true
		glow.emission = profile.eye_glow
		glow.emission_energy_multiplier = profile.eye_energy
		glow.albedo_color = profile.eye_glow
		made = glow
	elif source.albedo_texture != null and (profile.saturation < 1.0 or profile.tint != Color.WHITE):
		# With texture: desaturated and tinted by the recolor shader.
		var shader := Shader.new()
		shader.code = NpcVisualProfile.RECOLOR_SHADER
		var recolored := ShaderMaterial.new()
		recolored.shader = shader
		recolored.set_shader_parameter(&"albedo_tex", source.albedo_texture)
		recolored.set_shader_parameter(&"tint", source.albedo_color * profile.tint)
		recolored.set_shader_parameter(&"saturation", profile.saturation)
		made = recolored
	else:
		var tinted: BaseMaterial3D = source.duplicate() as BaseMaterial3D
		tinted.albedo_color = tinted.albedo_color * profile.tint
		made = tinted
	_tinted_materials[key] = made
	return made


func _apply_hood() -> void:
	if _skeleton == null:
		return
	for child: Node in _skeleton.get_children():
		var mesh: MeshInstance3D = child as MeshInstance3D
		if mesh == null:
			continue
		if mesh.name.begins_with(HOOD_MESH_PREFIX):
			mesh.visible = hood_visible
		else:
			for prefix: String in HAIR_MESH_PREFIXES:
				if mesh.name.begins_with(prefix):
					mesh.visible = not hood_visible


func _apply_shadow_casting() -> void:
	for child: Node in _skeleton.get_children():
		var mesh: MeshInstance3D = child as MeshInstance3D
		if mesh == null:
			continue
		for prefix: String in NO_SHADOW_MESH_PREFIXES:
			if mesh.name.begins_with(prefix):
				mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


# Sets (or removes) the camera fade on the visual's meshes: a single transparency by distance to the chest.
func _apply_camera_fade() -> void:
	if not camera_fade and not _camera_fade_applied:
		return
	_camera_fade_applied = camera_fade
	_fade_meshes.clear()
	_collect_meshes(self, _fade_meshes)
	set_process(camera_fade)
	# A single distance per visual (from the camera to the chest): all meshes, also the weapons, the shield and the
	# boots, fade equally (before, a visibility range per mesh left the feet and the shield opaque).
	_fade_value = -1.0
	if camera_fade:
		_update_camera_fade()
	else:
		for mesh: MeshInstance3D in _fade_meshes:
			mesh.transparency = 0.0
			mesh.visibility_range_begin = 0.0
			mesh.visibility_range_begin_margin = 0.0
			mesh.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED


func _process(_delta: float) -> void:
	if camera_fade:
		_update_camera_fade()


## Transparency (0 = opaque, 1 = invisible) of a visual with its chest [param distance] m from the camera.
static func fade_for_distance(distance: float) -> float:
	return clampf(inverse_lerp(CAMERA_FADE_SOLID, CAMERA_FADE_HIDDEN, distance), 0.0, 1.0)


## Transparency the meshes currently have from the camera fade (0 if none).
func get_camera_fade_value() -> float:
	return maxf(_fade_value, 0.0)


func _update_camera_fade() -> void:
	var camera: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return
	var chest: Vector3 = global_position + Vector3.UP * CAMERA_FADE_CHEST_HEIGHT
	var value: float = fade_for_distance(camera.global_position.distance_to(chest))
	if is_equal_approx(value, _fade_value):
		return
	_fade_value = value
	for mesh: MeshInstance3D in _fade_meshes:
		if is_instance_valid(mesh):
			mesh.transparency = value


static func _find_skeleton(root: Node) -> Skeleton3D:
	var found: Node = root.find_child(SKELETON_NAME, true, false)
	if found is Skeleton3D:
		return found as Skeleton3D
	return null


static func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		_collect_meshes(child, out)
