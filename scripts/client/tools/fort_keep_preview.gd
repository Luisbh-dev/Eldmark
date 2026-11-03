class_name FortKeepPreview
extends Node3D
## Escena de vista previa del torreón nuevo del fuerte (ART-57, herramienta de desarrollo).
##
## Instancia el Vado Gris tal cual (hijo "Zona"), quita en la copia en memoria la torre y el asta
## antiguas del fuerte (sin tocar vado_gris.tscn ni sus generadores) y pone en su sitio
## [code]assets/models/environment/custom/fort_keep.glb[/code]: el mismo origen que la torre de
## 6 x 6 m, a ras de suelo del patio. El torreón se dibuja con los materiales de reino de
## [code]fort_keep/materials/<reino>/[/code] (realm_surface, mismo nombre que los materiales del
## glTF), con el LOD lejano a partir de [constant LOD_SWITCH_DISTANCE] y la colisión de baja
## resolución en la capa del mundo.
## [br][br]
## No se usa en el juego: nada en el servidor ni en las escenas del juego la referencia.

## Escena del glTF (el importador la convierte en una PackedScene).
const KEEP_SCENE_PATH: String = "res://assets/models/environment/custom/fort_keep.glb"
const MATERIAL_DIR: String = "res://assets/models/environment/custom/fort_keep/materials/"
## Distancia (m) a la que el LOD0 deja paso al LOD1.
const LOD_SWITCH_DISTANCE: float = 170.0

## Reino cuya paleta usa el torreón: eldrun (frontera, la del Vado Gris), vardheim o solmarch.
@export var realm: StringName = &"eldrun"
## Ruta (desde este nodo) del fuerte de la zona.
@export var fort_path: NodePath = ^"Zona/Fuerte"
## Quita la torre y el asta antiguas del fuerte.
@export var replace_old_keep: bool = true

var _keep: Node3D = null


func _ready() -> void:
	var fort: Node3D = get_node_or_null(fort_path) as Node3D
	if fort == null:
		push_warning("FortKeepPreview: no existe %s" % fort_path)
		return
	if replace_old_keep:
		for old_name: String in ["FortTower", "Estandarte"]:
			var old: Node = fort.get_node_or_null(old_name)
			if old != null:
				fort.remove_child(old)
				old.queue_free()
	var scene: PackedScene = load(KEEP_SCENE_PATH) as PackedScene
	if scene == null:
		push_warning("FortKeepPreview: no se pudo cargar %s" % KEEP_SCENE_PATH)
		return
	_keep = scene.instantiate() as Node3D
	_keep.name = "FortKeep"
	fort.add_child(_keep)
	apply_realm(realm)


## Devuelve el torreón instanciado (null si no se pudo montar).
func get_keep() -> Node3D:
	return _keep


## Cambia la paleta del torreón (sustituye los materiales del glTF por los del reino) y ajusta el
## LOD y la colisión.
func apply_realm(realm_name: StringName) -> void:
	realm = realm_name
	if _keep == null:
		return
	for node: Node in _keep.find_children("*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = node as MeshInstance3D
		for i: int in instance.mesh.get_surface_count():
			var source: Material = instance.mesh.surface_get_material(i)
			if source == null:
				continue
			var path: String = "%s%s/%s.tres" % [MATERIAL_DIR, realm_name, source.resource_name]
			if ResourceLoader.exists(path):
				instance.set_surface_override_material(i, load(path) as Material)
		if instance.name.begins_with("FortKeep_LOD0"):
			instance.visibility_range_end = LOD_SWITCH_DISTANCE
		elif instance.name.begins_with("FortKeep_LOD1"):
			instance.visibility_range_begin = LOD_SWITCH_DISTANCE
	for node: Node in _keep.find_children("*", "StaticBody3D", true, false):
		var body: StaticBody3D = node as StaticBody3D
		body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
		body.collision_mask = 0
