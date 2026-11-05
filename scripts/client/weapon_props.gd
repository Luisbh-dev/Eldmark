class_name WeaponProps
extends RefCounted
## Weapons in the character's hands (ART-06): the sword (the own model of [SwordModel], with a fallback box
## if it does not load) and a flattened cylinder for the shield, hung from [BoneAttachment3D] on the
## skeleton's right and left hand. Client only. The shield is [b]only a placeholder[/b]
## until the final one arrives (RPG Weapons Pro); the swing arc does not come from the mesh but from the
## combat data. The blade, the guard, the disc and the bow cast shadows (the 6 mm string does not): the
## weapon also exists in the character's shadow.
## [br][br]
## The skeleton is Godot's humanoid ([code]RightHand[/code], [code]LeftHand[/code]). In the
## UAL clips the hand's local +Y axis points along the forearm toward the fingers; the blade goes out along +X and the
## shield is gripped with its disc perpendicular to Z, in front of the hand (toward -Z). If it does not
## fit when viewed, the offsets and rotations below are the only thing to touch.
## [br][br]
## [b]Provisional bow[/b] (phase 4, docs/habilidades.md, section 6.6): three thin cylinders in an arc (the
## two limbs and the grip) and a string, in the left hand (it hangs from the same [BoneAttachment3D] as
## the shield, as a second child; it is created the first time it is needed). [method show_weapon] shows the
## accessories of the weapon being carried (the bow, or the sword and shield) on remote players too: the
## active weapon comes from the weapon pair and the slot bit of its record (PRG-07 is visible).

## Names of the nodes that are created.
const SWORD_ATTACHMENT: StringName = &"SwordAttachment"
const SHIELD_ATTACHMENT: StringName = &"ShieldAttachment"
const SWORD_MESH: StringName = &"SwordPlaceholder"
## Node hanging from the hand with the sword model (the fallback box uses [constant SWORD_MESH]).
const SWORD_MODEL_NODE: StringName = &"Sword"
## Model node inside [constant SWORD_MODEL_NODE] (changed with [method set_sword_variant]) and of the
## swing trail ([SwordTrail]), which hangs from the same node.
const SWORD_MODEL_INSTANCE: StringName = &"SwordModel"
const SWORD_TRAIL_NODE: StringName = &"SwordTrail"
const SHIELD_MESH: StringName = &"ShieldPlaceholder"
## Hand bones.
const SWORD_BONE: StringName = &"RightHand"
const SHIELD_BONE: StringName = &"LeftHand"
## Sword: total length of the blade with the grip (m), width and thickness, and how far the
## grip sticks out behind the hand.
const SWORD_LENGTH: float = 0.95
const SWORD_WIDTH: float = 0.07
const SWORD_THICKNESS: float = 0.02
const SWORD_POMMEL_BACK: float = 0.12
## Grip of the sword model, in hand space: the model has its origin at the center of the
## grip and the blade along +Y, so it is rotated so the blade goes out along +X (like the box) and the
## center of the grip is brought to the palm, a little ahead of the wrist (toward the fingers, +Y).
const SWORD_GRIP_ROTATION_DEG: Vector3 = Vector3(0.0, 0.0, -90.0)
const SWORD_GRIP_OFFSET: Vector3 = Vector3(0.0, 0.07, 0.0)
## Roll of the model about its own axis (the blade's) within the grip, in degrees: with the blade exactly
## edge-on from behind (rest, game camera) it looks like a thread; a few degrees show some of the
## flat face. It does not affect the swing reach, which comes from the combat data and not from the mesh.
const SWORD_ROLL_DEG: float = 18.0
## Sword guard (cross box) and its position along the blade.
const GUARD_SIZE: Vector3 = Vector3(0.03, 0.025, 0.22)
const GUARD_OFFSET: float = 0.1
## Shield: radius and thickness of the disc (m) and how far it sits ahead of the hand (toward -Z).
const SHIELD_RADIUS: float = 0.26
const SHIELD_THICKNESS: float = 0.045
const SHIELD_FORWARD: float = 0.12
## Bow: node name, length of each limb and of the grip (m), thickness, curvature (degrees of each
## limb relative to the grip) and how far it sits ahead of the hand.
const BOW_MESH: StringName = &"BowPlaceholder"
const BOW_LIMB_LENGTH: float = 0.5
const BOW_GRIP_LENGTH: float = 0.16
const BOW_THICKNESS: float = 0.025
const BOW_BEND_DEG: float = 22.0
const BOW_FORWARD: float = 0.05
const BOW_COLOR: Color = Color(0.42, 0.27, 0.12, 1.0)
const STRING_COLOR: Color = Color(0.85, 0.82, 0.72, 1.0)
## Name (in the combat catalog) of the weapon that is shown as a bow.
const BOW_WEAPON: StringName = &"bow"
const STEEL_COLOR: Color = Color(0.72, 0.74, 0.8, 1.0)
const GUARD_COLOR: Color = Color(0.45, 0.33, 0.12, 1.0)
const SHIELD_COLOR: Color = Color(0.4, 0.26, 0.14, 1.0)


## Hangs the provisional sword and shield from [param skeleton] and returns the two
## [BoneAttachment3D] (sword, shield). If a hand is missing, that weapon is not created and the element is null.
## Does nothing (and returns nulls) if they were already in place.
static func install(skeleton: Skeleton3D) -> Array[BoneAttachment3D]:
	var result: Array[BoneAttachment3D] = [null, null]
	if skeleton == null:
		return result
	var existing_sword: BoneAttachment3D = skeleton.get_node_or_null(NodePath(SWORD_ATTACHMENT)) \
			as BoneAttachment3D
	if existing_sword != null:
		return result
	if skeleton.find_bone(SWORD_BONE) >= 0:
		result[0] = _attach(skeleton, SWORD_ATTACHMENT, SWORD_BONE, _make_sword_node())
	if skeleton.find_bone(SHIELD_BONE) >= 0:
		result[1] = _attach(skeleton, SHIELD_ATTACHMENT, SHIELD_BONE, _make_shield())
	return result


## Shows on [param skeleton] the accessories of weapon [param weapon_id] from the combat catalog: the bow
## (and nothing in the right hand) if it is the bow; the sword and shield with any other (NPCs' too).
## Creates the bow the first time. With no weapons installed ([method install]) it does nothing.
## Returns true if the bow is visible.
static func show_weapon(skeleton: Skeleton3D, weapon_id: int) -> bool:
	if skeleton == null:
		return false
	var sword: BoneAttachment3D = skeleton.get_node_or_null(NodePath(SWORD_ATTACHMENT)) as BoneAttachment3D
	var left: BoneAttachment3D = skeleton.get_node_or_null(NodePath(SHIELD_ATTACHMENT)) as BoneAttachment3D
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	var bow: bool = weapon != null and weapon.name == BOW_WEAPON
	if sword != null:
		sword.visible = not bow
	if left == null:
		return bow
	var shield: Node3D = left.get_node_or_null(NodePath(SHIELD_MESH)) as Node3D
	if shield != null:
		shield.visible = not bow
	var bow_node: Node3D = left.get_node_or_null(NodePath(BOW_MESH)) as Node3D
	if bow_node == null and bow:
		bow_node = _make_bow()
		left.add_child(bow_node)
	if bow_node != null:
		bow_node.visible = bow
	return bow


## Changes the sword of [param skeleton] to variant [param variant] of [SwordModel] ([code]base[/code] or the
## id of a realm: [code]vardheim[/code], [code]solmarch[/code], [code]askarra[/code]; anything else, the
## base) and tints its trail. It does nothing if it is already that variant, if the sword is not installed or if it is the fallback
## box. The grip does not change: it is the same for all four.
static func set_sword_variant(skeleton: Skeleton3D, variant: StringName) -> void:
	var root: Node3D = _sword_root(skeleton)
	if root == null:
		return
	var key: StringName = variant if SwordModel.MODELS.has(variant) else SwordModel.BASE
	var current: Node3D = root.get_node_or_null(NodePath(SWORD_MODEL_INSTANCE)) as Node3D
	if current == null or StringName(current.get_meta(&"variant", &"")) == key:
		return
	var model: Node3D = SwordModel.instantiate(key)
	if model == null:
		return
	model.name = SWORD_MODEL_INSTANCE
	model.set_meta(&"variant", key)
	model.rotation_degrees = Vector3(0.0, SWORD_ROLL_DEG, 0.0)
	root.remove_child(current)
	current.queue_free()
	root.add_child(model)
	var trail: SwordTrail = root.get_node_or_null(NodePath(SWORD_TRAIL_NODE)) as SwordTrail
	if trail != null:
		trail.bind(model)
		trail.set_tint(SwordTrail.color_for(key))


## Variant of the sword currently visible on [param skeleton] ([constant SwordModel.BASE] if it is the usual
## one; an empty string if there is no model).
static func get_sword_variant(skeleton: Skeleton3D) -> StringName:
	var root: Node3D = _sword_root(skeleton)
	if root == null:
		return &""
	var current: Node3D = root.get_node_or_null(NodePath(SWORD_MODEL_INSTANCE)) as Node3D
	return StringName(current.get_meta(&"variant", &"")) if current != null else &""


## Starts or cuts the sword trail of [param skeleton] (the hit is active or has ended). It does nothing
## without a sword model.
static func set_swing_active(skeleton: Skeleton3D, active: bool, heavy: bool = false) -> void:
	var root: Node3D = _sword_root(skeleton)
	if root == null:
		return
	var trail: SwordTrail = root.get_node_or_null(NodePath(SWORD_TRAIL_NODE)) as SwordTrail
	if trail != null:
		trail.set_active(active, heavy)


## The sword node of [param skeleton] (the model root, whose +X or +Y axis follows the blade depending on the grip), or
## null if there is no sword. The charge aura hangs from it.
static func get_sword_node(skeleton: Skeleton3D) -> Node3D:
	return _sword_root(skeleton)


# The [constant SWORD_MODEL_NODE] node of the sword, or null (no sword installed or with the fallback box).
static func _sword_root(skeleton: Skeleton3D) -> Node3D:
	if skeleton == null:
		return null
	var attachment: Node = skeleton.get_node_or_null(NodePath(SWORD_ATTACHMENT))
	if attachment == null:
		return null
	return attachment.get_node_or_null(NodePath(SWORD_MODEL_NODE)) as Node3D


static func _attach(skeleton: Skeleton3D, node_name: StringName, bone: StringName,
		prop: Node3D) -> BoneAttachment3D:
	var attachment := BoneAttachment3D.new()
	attachment.name = node_name
	attachment.bone_name = bone
	# No physics interpolation: it follows the bone every frame.
	attachment.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	skeleton.add_child(attachment)
	attachment.add_child(prop)
	return attachment


# The real sword: the SwordModel model inside a node that places it in the hand. If the GLB does not
# load, the usual box.
static func _make_sword_node() -> Node3D:
	var model: Node3D = SwordModel.instantiate(SwordModel.BASE)
	if model == null:
		push_warning("[WeaponProps] No carga el modelo de la espada: se usa la caja de reserva")
		return _make_sword()
	var root := Node3D.new()
	root.name = SWORD_MODEL_NODE
	root.set_meta(&"placeholder", false)
	root.rotation_degrees = SWORD_GRIP_ROTATION_DEG
	root.position = SWORD_GRIP_OFFSET
	model.name = SWORD_MODEL_INSTANCE
	model.set_meta(&"variant", SwordModel.BASE)
	model.rotation_degrees = Vector3(0.0, SWORD_ROLL_DEG, 0.0)
	root.add_child(model)
	var trail := SwordTrail.new()
	trail.set_tint(SwordTrail.color_for(SwordModel.BASE))
	root.add_child(trail)
	trail.bind(model)
	return root


# The provisional sword: a long box for the blade with the grip, and another crossed one for the guard. The blade goes out
# along +X of the hand.
static func _make_sword() -> Node3D:
	var root := Node3D.new()
	root.name = SWORD_MESH
	root.set_meta(&"placeholder", true)
	var blade := MeshInstance3D.new()
	blade.name = "Hoja"
	var blade_mesh := BoxMesh.new()
	blade_mesh.size = Vector3(SWORD_LENGTH, SWORD_THICKNESS, SWORD_WIDTH)
	blade_mesh.material = _material(STEEL_COLOR, 0.9, 0.35)
	blade.mesh = blade_mesh
	blade.position = Vector3(SWORD_LENGTH * 0.5 - SWORD_POMMEL_BACK, 0.0, 0.0)
	blade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(blade)
	var guard := MeshInstance3D.new()
	guard.name = "Guarda"
	var guard_mesh := BoxMesh.new()
	guard_mesh.size = GUARD_SIZE
	guard_mesh.material = _material(GUARD_COLOR, 0.2, 0.6)
	guard.mesh = guard_mesh
	guard.position = Vector3(GUARD_OFFSET, 0.0, 0.0)
	guard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(guard)
	return root


# The shield: a flattened cylinder whose axis is Z, in front of the hand (toward -Z).
static func _make_shield() -> Node3D:
	var root := Node3D.new()
	root.name = SHIELD_MESH
	root.set_meta(&"placeholder", true)
	var disc := MeshInstance3D.new()
	disc.name = "Disco"
	var mesh := CylinderMesh.new()
	mesh.top_radius = SHIELD_RADIUS
	mesh.bottom_radius = SHIELD_RADIUS
	mesh.height = SHIELD_THICKNESS
	mesh.radial_segments = 20
	mesh.rings = 1
	mesh.material = _material(SHIELD_COLOR, 0.0, 0.8)
	disc.mesh = mesh
	# Godot's cylinder has its axis on Y: it is laid down so the axis is Z.
	disc.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	disc.position = Vector3(0.0, 0.0, -SHIELD_FORWARD)
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(disc)
	return root


# The bow: the straight grip along +X of the hand (pointing up with the arm extended) and a
# limb on each side, tilted back (+Z) to give the curve; the string joins the tips.
static func _make_bow() -> Node3D:
	var root := Node3D.new()
	root.name = BOW_MESH
	root.set_meta(&"placeholder", true)
	root.position = Vector3(0.0, 0.0, -BOW_FORWARD)
	var material: StandardMaterial3D = _material(BOW_COLOR, 0.0, 0.7)
	var grip := MeshInstance3D.new()
	grip.name = "Empunadura"
	grip.mesh = _bow_rod(BOW_GRIP_LENGTH, material)
	grip.rotation = Vector3(0.0, 0.0, PI * 0.5)
	grip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(grip)
	var bend: float = deg_to_rad(BOW_BEND_DEG)
	var tips: Array[Vector3] = []
	for side: float in [1.0, -1.0]:
		var limb := MeshInstance3D.new()
		limb.name = "Pala" if side > 0.0 else "PalaInferior"
		limb.mesh = _bow_rod(BOW_LIMB_LENGTH, material)
		var direction := Vector3(side * cos(bend), 0.0, sin(bend))
		var start := Vector3(side * BOW_GRIP_LENGTH * 0.5, 0.0, 0.0)
		limb.position = start + direction * BOW_LIMB_LENGTH * 0.5
		# The cylinder runs along Y: it is rotated to follow the direction of the limb.
		limb.basis = Basis(Quaternion(Vector3.UP, direction.normalized()))
		limb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		root.add_child(limb)
		tips.append(start + direction * BOW_LIMB_LENGTH)
	var string := MeshInstance3D.new()
	string.name = "Cuerda"
	var string_mesh := BoxMesh.new()
	string_mesh.size = Vector3(tips[0].distance_to(tips[1]), 0.006, 0.006)
	string_mesh.material = _material(STRING_COLOR, 0.0, 0.9)
	string.mesh = string_mesh
	string.position = (tips[0] + tips[1]) * 0.5
	string.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(string)
	return root


static func _bow_rod(length: float, material: StandardMaterial3D) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = BOW_THICKNESS * 0.5
	mesh.bottom_radius = BOW_THICKNESS * 0.5
	mesh.height = length
	mesh.radial_segments = 8
	mesh.rings = 1
	mesh.material = material
	return mesh


static func _material(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	return material
