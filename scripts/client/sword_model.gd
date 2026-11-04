class_name SwordModel
extends RefCounted
## Eldmark's weapon sword (our own model, see tools/blender/build_sword.py). Client only.
## [br][br]
## Four GLBs with the same blade: [code]base[/code] and one variant per realm that changes the guard,
## pommel and colors ([code]vardheim[/code]: wolf and blue leather; [code]solmarch[/code]: sun guard,
## gold and white leather; [code]askarra[/code]: bronze, crimson leather and an anvil pommel with an
## ember).
## [br][br]
## Model convention: the origin is the center of the grip (where the hand closes), the blade extends
## along +Y and measures about 0.94 m from that point (1.11 m in total with the pommel), the width runs
## along X (the edges face +X and -X) and the flat faces of the blade face +Z and -Z.
## [br][br]
## Each GLB has two meshes, [code]Sword_LOD0[/code] (about 2,700 triangles) and [code]Sword_LOD1[/code]
## (about 560, without the modeled fuller or leather wraps). [method setup_lods] distributes which one is
## seen using the engine's visibility ranges.

const MODEL_DIR: String = "res://assets/models/weapons/"
const BASE: StringName = &"base"
## Variant -> GLB path.
const MODELS: Dictionary[StringName, String] = {
	&"base": "res://assets/models/weapons/sword_base.glb",
	&"vardheim": "res://assets/models/weapons/sword_vardheim.glb",
	&"solmarch": "res://assets/models/weapons/sword_solmarch.glb",
	&"askarra": "res://assets/models/weapons/sword_askarra.glb",
}
## Names of the two meshes inside the GLB.
const LOD0_NAME: StringName = &"Sword_LOD0"
const LOD1_NAME: StringName = &"Sword_LOD1"
## Empty markers in the model for the hit trail: the start of the edge and the tip.
const TRAIL_BASE_NAME: StringName = &"TrailBase"
const TRAIL_TIP_NAME: StringName = &"TrailTip"
## Distance (m) at which the sword switches from full detail to the simple one, and the hysteresis margin.
const LOD_DISTANCE: float = 14.0
const LOD_MARGIN: float = 1.5
## Total length of the model (m) and distance from the grip's center to the tip.
const TOTAL_LENGTH: float = 1.11
const GRIP_TO_TIP: float = 0.94


## Instantiates the model of [param variant] (or the base one if it does not exist) with the LODs already
## distributed, or returns null if the GLB cannot be loaded. It does not orient it: that is up to whoever
## attaches it.
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


## Distributes the visibility ranges: LOD0 up to [constant LOD_DISTANCE] and LOD1 from there.
static func setup_lods(root: Node) -> void:
	var near: MeshInstance3D = root.find_child(LOD0_NAME, true, false) as MeshInstance3D
	var far: MeshInstance3D = root.find_child(LOD1_NAME, true, false) as MeshInstance3D
	if near != null:
		near.visibility_range_end = LOD_DISTANCE
		near.visibility_range_end_margin = LOD_MARGIN
	if far != null:
		far.visibility_range_begin = LOD_DISTANCE
		far.visibility_range_begin_margin = LOD_MARGIN


## Shows only LOD [param level] (0 or 1), without visibility ranges: for tests and previews.
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


## Triangles of the model's [param level] mesh, or 0 if it is not there.
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
