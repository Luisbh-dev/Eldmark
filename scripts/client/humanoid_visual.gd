class_name HumanoidVisual
extends Node3D
## Aspecto visual de un humanoide (solo cliente): modelo modular + animación.
##
## Raíz de [code]scenes/characters/visuals/humanoid_visual.tscn[/code]. No simula nada: decora un
## [PlayerCharacter] (cadena esperada: PlayerCharacter > Visual > HumanoidVisual) y su
## [CharacterAnimator] hijo lee el estado del personaje cada fotograma.
## [br][br]
## El modelo base ([code]Pivot/Model[/code]) es un glTF de Quaternius con el esqueleto común UAL ya
## convertido al perfil humanoide de Godot ([code]%GeneralSkeleton[/code], ver
## [code]assets/animations/rig/ual_humanoid_bone_map.tres[/code]). Las piezas de
## [member part_scenes] (cabeza, pelo, barba...) se importan con el mismo BoneMap, así que al
## arrancar sus mallas se pasan a ese esqueleto y comparten la pose: un solo esqueleto anima todo.
## [br][br]
## El modelo mira hacia -Z como el [PlayerCharacter] (los glTF de Quaternius miran hacia +Z y por
## eso [code]Model[/code] va girado 180°). El origen está en los pies y mide unos 1,8 m.

## Escena de este visual (se carga en [method install]; no se precarga para no crear un ciclo
## escena -> script -> escena).
const SCENE_PATH: String = "res://scenes/characters/visuals/humanoid_visual.tscn"
## Nodo del [PlayerCharacter] que agrupa lo visual (la cámara lo oculta cuando se acerca).
const VISUAL_NODE: NodePath = ^"Visual"
## Nombre del esqueleto único que deja el BoneMap al importar (opción "Make Unique").
const SKELETON_NAME: String = "GeneralSkeleton"
## Mallas de capucha (se muestran con [member hood_visible]).
const HOOD_MESH_PREFIX: String = "Male_Ranger_Head_Hood"
## Mallas de pelo largo que se ocultan con capucha (las cejas y la barba se quedan).
const HAIR_MESH_PREFIXES: PackedStringArray = ["Hair_SimpleParted"]
## Mallas pequeñas que no proyectan sombra (en una sombra de 1,8 m no se distinguen y cada una
## cuesta una llamada de dibujo por corte de sombra).
const NO_SHADOW_MESH_PREFIXES: PackedStringArray = [
	"Eyes", "Eyebrows", "Hair_Beard", "Male_Ranger_Body_Belt",
]

## Piezas extra con el mismo esqueleto (escenas glTF importadas con el BoneMap UAL). Sus mallas
## se mueven al esqueleto del modelo base en [method _ready].
@export var part_scenes: Array[PackedScene] = []
## Muestra la capucha del traje. Con capucha se oculta el pelo para que no la atraviese.
@export var hood_visible: bool = false:
	set(value):
		hood_visible = value
		if is_node_ready():
			_apply_hood()

@onready var _model: Node3D = $Pivot/Model

var _skeleton: Skeleton3D = null


## Cuelga un HumanoidVisual nuevo bajo el nodo Visual de [param character] y oculta las mallas
## provisionales que ya hubiera ahí (la cápsula y el visor de la fase 1). Pensado para llamarse
## desde el cliente justo después de instanciar el personaje, para que la escena compartida
## [code]player_character.tscn[/code] (que también cargará el servidor) no arrastre modelos ni
## animaciones. Devuelve el visual creado, o null si no se pudo cargar la escena.
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


## Igual que [method install], pero además quita del nodo Visual las mallas provisionales (la cápsula
## y el visor de [code]player_character.tscn[/code]), que se quedan ligeras para el servidor. Si el
## visual no carga, devuelve null y la cápsula se queda para que se vea algo. Lo usan el sandbox
## ([ClientMain]), el personaje local de [OnlineMain] y los remotos de [RemoteWorld].
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
	for scene: PackedScene in part_scenes:
		_attach_part(scene)
	_apply_hood()
	_apply_shadow_casting()
	# Armas provisionales en las manos (ART-06): hasta que lleguen los modelos definitivos. El animador
	# avisa del arma que se lleva (la activa del personaje o la del registro de un remoto) y se enseñan
	# sus accesorios (fase 4: el arco o la espada y el escudo).
	WeaponProps.install(_skeleton)
	get_animator().weapon_shown.connect(_on_weapon_shown)
	# Pose de combate sobre la locomoción (ART-08). Va antes que el giro de la columna, que se
	# aplica encima.
	var combat := CombatPoseModifier.new()
	combat.name = "CombatPose"
	_skeleton.add_child(combat)
	get_animator().set_combat_modifier(combat)
	# Giro de la columna hacia el punto de mira (lo conduce el animador).
	var spine := SpineTwistModifier.new()
	spine.name = "SpineTwist"
	_skeleton.add_child(spine)
	get_animator().set_spine_modifier(spine)


func _on_weapon_shown(weapon_id: int) -> void:
	WeaponProps.show_weapon(_skeleton, weapon_id)


## Esqueleto que anima todas las mallas (perfil humanoide de Godot: Hips, Head, RightHand...).
## De él cuelgan las armas provisionales ([WeaponProps]) y los modificadores de pose.
func get_skeleton() -> Skeleton3D:
	return _skeleton


## Nodo que gira el animador para orientar el modelo (hijo directo de esta raíz).
func get_pivot() -> Node3D:
	return get_node(^"Pivot") as Node3D


## Animador que conduce el [AnimationTree] a partir del [PlayerCharacter].
func get_animator() -> CharacterAnimator:
	return get_node(^"CharacterAnimator") as CharacterAnimator


## Decora [param character]. Si no se llama, el animador busca el [PlayerCharacter] entre sus
## ancestros al entrar en el árbol. Se puede llamar antes de añadir el visual al árbol.
func attach_to(character: PlayerCharacter) -> void:
	get_animator().set_character(character)


## Pasa las mallas de una pieza al esqueleto del modelo base y descarta el resto de la pieza.
func _attach_part(scene: PackedScene) -> void:
	if scene == null:
		return
	var part: Node = scene.instantiate()
	var meshes: Array[MeshInstance3D] = []
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
