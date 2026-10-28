extends SceneTree
## Guarda como recursos de texto (.tres) las mallas de las piezas de kit que usan las escenas de
## props (malla + colisión + material de reino) y los MultiMesh de las murallas.
##
## Uso, después de copy_vado_gris_assets.gd y de [code]godot --headless --path . --import[/code]:
## [codeblock]
## godot --headless --path . -s res://tools/assets/extract_kit_meshes.gd
## [/codeblock]
## Así las escenas referencian una malla concreta (y no un glTF entero con 116 piezas, como el
## Castle Wall Kit) y todo sigue en texto, como pide CLAUDE.md. Los materiales del glTF se
## sustituyen por uno gris sin texturas ([constant PLACEHOLDER_MATERIAL]): las escenas ponen
## siempre los de reino, y si se quedaran los del glTF sus texturas (rugosidad, ORM, colormap de
## Kenney) se cargarían en VRAM sin verse nunca. No se dejan vacíos porque un parámetro de
## instancia (faction_color) sobre una malla con una superficie sin material registra errores.

const CASTLE_WALL_SCENE: String = "res://assets/models/environment/castle_wall/castle_walls_kit.gltf"
const CASTLE_WALL_MESHES_DIR: String = "res://assets/models/environment/castle_wall/meshes"
## Solo las piezas que usan las escenas (el kit trae 116).
const CASTLE_WALL_NODES: PackedStringArray = [
	"Courtine_Wall", "Courtine_Door_Arch", "Courtine_Slits",
	"Wall_Wall", "Wall_Window_Arch", "Wall_Slits", "Wall_Floor", "Wall_Battlements",
	"Brattice_Wall_1", "Pillar",
	"DoorSticker_Gate_Arch", "DoorSticker_Door", "DoorSticker_Portcullis",
]
const VILLAGE_DIR: String = "res://assets/models/environment/village"
## Material por defecto de las mallas extraídas (gris, sin texturas).
const PLACEHOLDER_MATERIAL: String = "res://assets/materials/kit_placeholder.tres"
const KENNEY_DIR: String = "res://assets/models/blockout/kenney_castle"

var _failed: bool = false
var _placeholder: Material = null


func _initialize() -> void:
	var placeholder := StandardMaterial3D.new()
	placeholder.resource_name = "kit_placeholder"
	placeholder.albedo_color = Color(0.5, 0.5, 0.5)
	placeholder.roughness = 0.9
	if ResourceSaver.save(placeholder, PLACEHOLDER_MATERIAL) != OK:
		_fail("No se pudo guardar %s" % PLACEHOLDER_MATERIAL)
	_placeholder = load(PLACEHOLDER_MATERIAL) as Material
	_extract_from_scene(CASTLE_WALL_SCENE, CASTLE_WALL_NODES, CASTLE_WALL_MESHES_DIR)
	_extract_folder(VILLAGE_DIR, "gltf")
	_extract_folder(KENNEY_DIR, "glb")
	quit(1 if _failed else 0)


## Cada glTF/GLB de la carpeta tiene una sola malla: se guarda con el nombre del archivo.
func _extract_folder(dir: String, extension: String) -> void:
	var out_dir: String = dir.path_join("meshes")
	for file_name: String in DirAccess.get_files_at(dir):
		if file_name.get_extension() != extension:
			continue
		var scene: PackedScene = load(dir.path_join(file_name)) as PackedScene
		if scene == null:
			_fail("No se pudo cargar %s" % file_name)
			continue
		var root_node: Node = scene.instantiate()
		var mesh_instance: MeshInstance3D = _first_mesh_instance(root_node)
		if mesh_instance == null:
			_fail("%s no tiene MeshInstance3D" % file_name)
		else:
			_save_mesh(mesh_instance.mesh, out_dir.path_join(file_name.get_basename() + ".tres"))
		root_node.free()


func _extract_from_scene(scene_path: String, node_names: PackedStringArray, out_dir: String) -> void:
	var scene: PackedScene = load(scene_path) as PackedScene
	if scene == null:
		_fail("No se pudo cargar %s" % scene_path)
		return
	var root_node: Node = scene.instantiate()
	for node_name: String in node_names:
		var mesh_instance: MeshInstance3D = root_node.find_child(node_name, true, false) as MeshInstance3D
		if mesh_instance == null:
			_fail("%s no contiene %s" % [scene_path, node_name])
			continue
		_save_mesh(mesh_instance.mesh, out_dir.path_join(node_name.to_snake_case() + ".tres"))
	root_node.free()


func _save_mesh(mesh: Mesh, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var copy: Mesh = mesh.duplicate(true) as Mesh
	copy.resource_name = path.get_file().get_basename()
	for surface: int in copy.get_surface_count():
		copy.surface_set_material(surface, _placeholder)
	var error: Error = ResourceSaver.save(copy, path)
	if error != OK:
		_fail("No se pudo guardar %s (%s)" % [path, error_string(error)])
		return
	print("%s (%d superficies, %.1f KB)" % [path, copy.get_surface_count(),
			FileAccess.get_file_as_bytes(path).size() / 1024.0])


static func _first_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child: Node in node.get_children():
		var found: MeshInstance3D = _first_mesh_instance(child)
		if found != null:
			return found
	return null


func _fail(message: String) -> void:
	_failed = true
	printerr(message)
