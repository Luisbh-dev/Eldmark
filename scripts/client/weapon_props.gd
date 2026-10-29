class_name WeaponProps
extends RefCounted
## Armas provisionales en las manos del personaje (ART-06): una caja para la espada y un cilindro
## aplanado para el escudo, colgados de [BoneAttachment3D] en la mano derecha e izquierda del
## esqueleto. Solo cliente y [b]solo un marcador de posición[/b] hasta que lleguen los modelos
## definitivos (espada del Fantasy Props MegaKit y escudo de RPG Weapons Pro); el arco del golpe no
## sale de la malla sino de los datos de combate.
## [br][br]
## El esqueleto es el humanoide de Godot ([code]RightHand[/code], [code]LeftHand[/code]). En los clips de
## UAL el eje local +Y de la mano apunta por el antebrazo hacia los dedos; la hoja sale por +X y el
## escudo se agarra con su disco perpendicular a Z, por delante de la mano (hacia -Z). Si al verlo
## no encaja, los desplazamientos y giros de más abajo son lo único que hay que tocar.

## Nombres de los nodos que se crean.
const SWORD_ATTACHMENT: StringName = &"SwordAttachment"
const SHIELD_ATTACHMENT: StringName = &"ShieldAttachment"
const SWORD_MESH: StringName = &"SwordPlaceholder"
const SHIELD_MESH: StringName = &"ShieldPlaceholder"
## Huesos de las manos.
const SWORD_BONE: StringName = &"RightHand"
const SHIELD_BONE: StringName = &"LeftHand"
## Espada: largo total de la hoja con la empuñadura (m), ancho y grosor, y cuánto sobresale la
## empuñadura por detrás de la mano.
const SWORD_LENGTH: float = 0.95
const SWORD_WIDTH: float = 0.07
const SWORD_THICKNESS: float = 0.02
const SWORD_POMMEL_BACK: float = 0.12
## Guarda de la espada (caja cruzada) y su posición a lo largo de la hoja.
const GUARD_SIZE: Vector3 = Vector3(0.03, 0.025, 0.22)
const GUARD_OFFSET: float = 0.1
## Escudo: radio y grosor del disco (m) y cuánto se adelanta de la mano (hacia -Z).
const SHIELD_RADIUS: float = 0.26
const SHIELD_THICKNESS: float = 0.045
const SHIELD_FORWARD: float = 0.12
const STEEL_COLOR: Color = Color(0.72, 0.74, 0.8, 1.0)
const GUARD_COLOR: Color = Color(0.45, 0.33, 0.12, 1.0)
const SHIELD_COLOR: Color = Color(0.4, 0.26, 0.14, 1.0)


## Cuelga la espada y el escudo provisionales de [param skeleton] y devuelve los dos
## [BoneAttachment3D] (espada, escudo). Si falta una mano, ese arma no se crea y el elemento es null.
## No hace nada (y devuelve nulos) si ya estaban puestos.
static func install(skeleton: Skeleton3D) -> Array[BoneAttachment3D]:
	var result: Array[BoneAttachment3D] = [null, null]
	if skeleton == null:
		return result
	var existing_sword: BoneAttachment3D = skeleton.get_node_or_null(NodePath(SWORD_ATTACHMENT)) \
			as BoneAttachment3D
	if existing_sword != null:
		return result
	if skeleton.find_bone(SWORD_BONE) >= 0:
		result[0] = _attach(skeleton, SWORD_ATTACHMENT, SWORD_BONE, _make_sword())
	if skeleton.find_bone(SHIELD_BONE) >= 0:
		result[1] = _attach(skeleton, SHIELD_ATTACHMENT, SHIELD_BONE, _make_shield())
	return result


static func _attach(skeleton: Skeleton3D, node_name: StringName, bone: StringName,
		prop: Node3D) -> BoneAttachment3D:
	var attachment := BoneAttachment3D.new()
	attachment.name = node_name
	attachment.bone_name = bone
	# Sin interpolación de física: sigue al hueso cada fotograma.
	attachment.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	skeleton.add_child(attachment)
	attachment.add_child(prop)
	return attachment


# La espada: una caja larga para la hoja con la empuñadura, y otra cruzada de guarda. La hoja sale
# por +X de la mano.
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
	blade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(blade)
	var guard := MeshInstance3D.new()
	guard.name = "Guarda"
	var guard_mesh := BoxMesh.new()
	guard_mesh.size = GUARD_SIZE
	guard_mesh.material = _material(GUARD_COLOR, 0.2, 0.6)
	guard.mesh = guard_mesh
	guard.position = Vector3(GUARD_OFFSET, 0.0, 0.0)
	guard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(guard)
	return root


# El escudo: un cilindro aplanado cuyo eje es Z, por delante de la mano (hacia -Z).
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
	# El cilindro de Godot tiene el eje en Y: se tumba para que el eje sea Z.
	disc.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	disc.position = Vector3(0.0, 0.0, -SHIELD_FORWARD)
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(disc)
	return root


static func _material(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	return material
