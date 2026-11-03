class_name WeaponProps
extends RefCounted
## Armas en las manos del personaje (ART-06): la espada (el modelo propio de [SwordModel], con una caja
## de reserva si no carga) y un cilindro aplanado para el escudo, colgados de [BoneAttachment3D] en la
## mano derecha e izquierda del esqueleto. Solo cliente. El escudo es [b]solo un marcador de posición[/b]
## hasta que llegue el definitivo (RPG Weapons Pro); el arco del golpe no sale de la malla sino de los
## datos de combate.
## [br][br]
## El esqueleto es el humanoide de Godot ([code]RightHand[/code], [code]LeftHand[/code]). En los clips de
## UAL el eje local +Y de la mano apunta por el antebrazo hacia los dedos; la hoja sale por +X y el
## escudo se agarra con su disco perpendicular a Z, por delante de la mano (hacia -Z). Si al verlo
## no encaja, los desplazamientos y giros de más abajo son lo único que hay que tocar.
## [br][br]
## [b]Arco provisional[/b] (fase 4, docs/habilidades.md, sección 6.6): tres cilindros finos en arco (las
## dos palas y la empuñadura) y una cuerda, en la mano izquierda (cuelga del mismo [BoneAttachment3D] que
## el escudo, como segundo hijo; se crea la primera vez que hace falta). [method show_weapon] enseña los
## accesorios del arma que se lleva (el arco, o la espada y el escudo) también en los remotos: el arma
## activa sale de la pareja de armas y del bit de ranura de su registro (PRG-07 se ve).

## Nombres de los nodos que se crean.
const SWORD_ATTACHMENT: StringName = &"SwordAttachment"
const SHIELD_ATTACHMENT: StringName = &"ShieldAttachment"
const SWORD_MESH: StringName = &"SwordPlaceholder"
## Nodo que cuelga de la mano con el modelo de la espada (la caja de reserva usa [constant SWORD_MESH]).
const SWORD_MODEL_NODE: StringName = &"Sword"
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
## Agarre del modelo de la espada, en el espacio de la mano: el modelo tiene el origen en el centro de la
## empuñadura y la hoja por +Y, así que se gira para que la hoja salga por +X (como la caja) y se lleva
## el centro de la empuñadura a la palma, un poco por delante de la muñeca (hacia los dedos, +Y).
const SWORD_GRIP_ROTATION_DEG: Vector3 = Vector3(0.0, 0.0, -90.0)
const SWORD_GRIP_OFFSET: Vector3 = Vector3(0.0, 0.07, 0.0)
## Guarda de la espada (caja cruzada) y su posición a lo largo de la hoja.
const GUARD_SIZE: Vector3 = Vector3(0.03, 0.025, 0.22)
const GUARD_OFFSET: float = 0.1
## Escudo: radio y grosor del disco (m) y cuánto se adelanta de la mano (hacia -Z).
const SHIELD_RADIUS: float = 0.26
const SHIELD_THICKNESS: float = 0.045
const SHIELD_FORWARD: float = 0.12
## Arco: nombre del nodo, largo de cada pala y de la empuñadura (m), grosor, curvatura (grados de cada
## pala respecto a la empuñadura) y cuánto se adelanta de la mano.
const BOW_MESH: StringName = &"BowPlaceholder"
const BOW_LIMB_LENGTH: float = 0.5
const BOW_GRIP_LENGTH: float = 0.16
const BOW_THICKNESS: float = 0.025
const BOW_BEND_DEG: float = 22.0
const BOW_FORWARD: float = 0.05
const BOW_COLOR: Color = Color(0.42, 0.27, 0.12, 1.0)
const STRING_COLOR: Color = Color(0.85, 0.82, 0.72, 1.0)
## Nombre (en el catálogo de combate) del arma que se ve como arco.
const BOW_WEAPON: StringName = &"bow"
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
		result[0] = _attach(skeleton, SWORD_ATTACHMENT, SWORD_BONE, _make_sword_node())
	if skeleton.find_bone(SHIELD_BONE) >= 0:
		result[1] = _attach(skeleton, SHIELD_ATTACHMENT, SHIELD_BONE, _make_shield())
	return result


## Enseña en [param skeleton] los accesorios del arma [param weapon_id] del catálogo de combate: el arco
## (y nada en la mano derecha) si es el arco; la espada y el escudo con cualquier otra (las de los PNJ
## también). Crea el arco la primera vez. Sin las armas instaladas ([method install]) no hace nada.
## Devuelve true si se ve el arco.
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


# La espada de verdad: el modelo de SwordModel dentro de un nodo que lo coloca en la mano. Si el GLB no
# carga, la caja de siempre.
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
	root.add_child(model)
	return root


# La espada provisional: una caja larga para la hoja con la empuñadura, y otra cruzada de guarda. La hoja sale
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


# El arco: la empuñadura recta a lo largo de +X de la mano (hacia arriba con el brazo extendido) y una
# pala a cada lado, inclinadas hacia atrás (+Z) para dar la curva; la cuerda une las puntas.
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
	grip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
		# El cilindro va en Y: se gira para que siga la dirección de la pala.
		limb.basis = Basis(Quaternion(Vector3.UP, direction.normalized()))
		limb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
