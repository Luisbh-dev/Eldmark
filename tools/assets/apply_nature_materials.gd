extends SceneTree
## Cambia, en los glTF del Stylized Nature, el material de la corteza (y de las hojas de los árboles
## retorcidos) por uno propio (ART-59).
##
## La corteza del pack es terracota y en el valle gris se veía salmón; las hojas de los retorcidos son
## rojas. Los materiales nuevos ([code]assets/materials/vegetation/bark_*.tres[/code] y
## [code]leaves_twisted.tres[/code], que genera tools/materials/build_realm_materials.gd) las llevan a
## un pardo grisáceo y a un verde oliva apagado. Se aplica como material
## externo en la importación del glTF ([code]_subresources[/code] del .import), así que no se toca el
## glTF ni se duplica ninguna malla, y sirve a todos los árboles que lo usen, también al
## instanciador de Terrain3D.
## [br][br]
## Uso (con el editor cerrado; después hay que volver a importar):
## [codeblock]
## godot --headless --path . -s res://tools/materials/build_realm_materials.gd
## godot --headless --path . -s res://tools/assets/apply_nature_materials.gd
## godot --headless --path . --import
## [/codeblock]
## Conserva el resto del .import (uid, rutas) y es idempotente.

const NATURE_DIR: String = "res://assets/models/environment/nature"
const VEGETATION_DIR: String = "res://assets/materials/vegetation"
## Nombre del material en el glTF -> material propio que lo sustituye.
const EXTERNAL_MATERIALS: Dictionary = {
	"Bark_NormalTree": VEGETATION_DIR + "/bark_tree.tres",
	"Bark_TwistedTree": VEGETATION_DIR + "/bark_twisted.tres",
	"Bark_DeadTree": VEGETATION_DIR + "/bark_dead.tres",
	"Leaves_TwistedTree": VEGETATION_DIR + "/leaves_twisted.tres",
}


func _initialize() -> void:
	var changed: int = 0
	var failed: bool = false
	for file_name: String in DirAccess.get_files_at(NATURE_DIR):
		if file_name.get_extension() != "gltf":
			continue
		var gltf_path: String = NATURE_DIR.path_join(file_name)
		var materials: Dictionary = _external_materials_of(gltf_path)
		if materials.is_empty():
			continue
		for path: String in materials.values():
			if not ResourceLoader.exists(path):
				printerr("Falta %s: ejecuta antes tools/materials/build_realm_materials.gd" % path)
				failed = true
		var import_path: String = gltf_path + ".import"
		var config := ConfigFile.new()
		if config.load(import_path) != OK:
			printerr("Falta %s: importa el proyecto antes (godot --headless --path . --import)" % import_path)
			failed = true
			continue
		var wanted: Dictionary = {"materials": {}}
		for material_name: String in materials:
			wanted["materials"][material_name] = {
				"use_external/enabled": true,
				"use_external/path": materials[material_name],
				"use_external/fallback_path": materials[material_name],
			}
		if config.get_value("params", "_subresources", {}) == wanted:
			continue
		config.set_value("params", "_subresources", wanted)
		if config.save(import_path) != OK:
			printerr("No se pudo escribir %s" % import_path)
			failed = true
			continue
		changed += 1
		print("%s: %s" % [file_name, ", ".join(materials.keys())])
	print("Importaciones cambiadas: %d" % changed)
	quit(1 if failed else 0)


## Materiales de [param gltf_path] que tienen sustituto: nombre -> ruta del material propio.
static func _external_materials_of(gltf_path: String) -> Dictionary:
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(gltf_path))
	var result: Dictionary = {}
	if typeof(json) != TYPE_DICTIONARY:
		return result
	for material: Dictionary in (json as Dictionary).get("materials", []):
		var material_name: String = material.get("name", "")
		if EXTERNAL_MATERIALS.has(material_name):
			result[material_name] = EXTERNAL_MATERIALS[material_name]
	return result
