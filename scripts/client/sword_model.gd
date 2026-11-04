class_name SwordModel
extends RefCounted
## La espada de armas de Eldmark (modelo propio, ver tools/blender/build_sword.py). Solo cliente.
## [br][br]
## Cuatro GLB con la misma hoja: [code]base[/code] y una variante por reino que cambia guarda, pomo
## y colores ([code]vardheim[/code]: lobo y cuero azul; [code]solmarch[/code]: guarda de sol,
## oro y cuero blanco; [code]askarra[/code]: bronce, cuero carmesí y pomo de yunque con brasa).
## [br][br]
## Convención del modelo: el origen es el centro de la empuñadura (donde cierra la mano), la hoja
## sale por +Y y mide unos 0,94 m desde ese punto (1,11 m en total con el pomo), el ancho va por X
## (los filos miran a +X y -X) y las caras planas de la hoja miran a +Z y -Z.
## [br][br]
## Cada GLB trae dos mallas, [code]Sword_LOD0[/code] (unos 2.700 triángulos) y [code]Sword_LOD1[/code]
## (unos 560, sin acanaladura ni vueltas de cuero modeladas). [method setup_lods] reparte cuál se ve
## con los rangos de visibilidad del motor.

const MODEL_DIR: String = "res://assets/models/weapons/"
const BASE: StringName = &"base"
## Variante -> ruta del GLB.
const MODELS: Dictionary[StringName, String] = {
	&"base": "res://assets/models/weapons/sword_base.glb",
	&"vardheim": "res://assets/models/weapons/sword_vardheim.glb",
	&"solmarch": "res://assets/models/weapons/sword_solmarch.glb",
	&"askarra": "res://assets/models/weapons/sword_askarra.glb",
}
## Nombres de las dos mallas dentro del GLB.
const LOD0_NAME: StringName = &"Sword_LOD0"
const LOD1_NAME: StringName = &"Sword_LOD1"
## Marcas vacías del modelo para la estela del golpe: el arranque del filo y la punta.
const TRAIL_BASE_NAME: StringName = &"TrailBase"
const TRAIL_TIP_NAME: StringName = &"TrailTip"
## Distancia (m) a la que la espada pasa del detalle completo al sencillo, y margen de histéresis.
const LOD_DISTANCE: float = 14.0
const LOD_MARGIN: float = 1.5
## Largo total del modelo (m) y distancia del centro de la empuñadura a la punta.
const TOTAL_LENGTH: float = 1.11
const GRIP_TO_TIP: float = 0.94


## Instancia el modelo de [param variant] (o el base si no existe) con los LOD ya repartidos, o
## devuelve null si el GLB no se puede cargar. No lo orienta: eso lo decide quien lo cuelga.
static func instantiate(variant: StringName = BASE, with_lods: bool = true) -> Node3D:
	var path: String = MODELS.get(variant, MODELS[BASE])
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		return null
	var root: Node3D = scene.instantiate() as Node3D
	if root == null:
		return null
	if with_lods:
		setup_lods(root)
	return root


## Reparte los rangos de visibilidad: el LOD0 hasta [constant LOD_DISTANCE] y el LOD1 desde ahí.
static func setup_lods(root: Node) -> void:
	var near: MeshInstance3D = root.find_child(LOD0_NAME, true, false) as MeshInstance3D
	var far: MeshInstance3D = root.find_child(LOD1_NAME, true, false) as MeshInstance3D
	if near != null:
		near.visibility_range_end = LOD_DISTANCE
		near.visibility_range_end_margin = LOD_MARGIN
	if far != null:
		far.visibility_range_begin = LOD_DISTANCE
		far.visibility_range_begin_margin = LOD_MARGIN


## Enseña solo el LOD [param level] (0 o 1), sin rangos de visibilidad: para las pruebas y las vistas
## previas.
static func show_only_lod(root: Node, level: int) -> void:
	var near: MeshInstance3D = root.find_child(LOD0_NAME, true, false) as MeshInstance3D
	var far: MeshInstance3D = root.find_child(LOD1_NAME, true, false) as MeshInstance3D
	for mesh: MeshInstance3D in [near, far]:
		if mesh != null:
			mesh.visibility_range_begin = 0.0
			mesh.visibility_range_end = 0.0
	if near != null:
		near.visible = level == 0
	if far != null:
		far.visible = level == 1


## Triángulos de la malla [param level] del modelo, o 0 si no está.
static func triangle_count(root: Node, level: int) -> int:
	var mesh_node: MeshInstance3D = root.find_child(LOD0_NAME if level == 0 else LOD1_NAME, true, false) \
			as MeshInstance3D
	if mesh_node == null or mesh_node.mesh == null:
		return 0
	var total: int = 0
	for surface: int in range(mesh_node.mesh.get_surface_count()):
		var arrays: Array = mesh_node.mesh.surface_get_arrays(surface)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		if indices.size() > 0:
			total += indices.size() / 3
		else:
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
			total += vertices.size() / 3
	return total
