class_name FortKeepPreview
extends Node3D
## Escena de vista previa del torreón nuevo del fuerte (ART-57, herramienta de desarrollo).
##
## Instancia el Vado Gris tal cual (hijo "Zona"), quita en la copia en memoria la torre y el asta
## antiguas del fuerte (sin tocar vado_gris.tscn ni sus generadores) y pone en su sitio
## [code]assets/models/environment/custom/fort_keep.glb[/code]: el mismo origen que la torre de
## 6 x 6 m, a ras de suelo del patio. El torreón se dibuja con los materiales de reino de
## [code]fort_keep/materials/<reino>/[/code] (mismo nombre que los materiales del glTF), con tres
## niveles de detalle (ver [method apply_lods]) y la colisión de baja resolución en la capa del mundo.
## [br][br]
## El nodo [code]Estandarte[/code] del glTF sustituye al marcador del mismo nombre del fuerte: expone
## los parámetros por instancia que mueve el controlador del fuerte (ver [method apply_banner]).
## [br][br]
## No se usa en el juego: nada en el servidor ni en las escenas del juego la referencia.

## Escena del glTF (el importador la convierte en una PackedScene).
const KEEP_SCENE_PATH: String = "res://assets/models/environment/custom/fort_keep.glb"
const MATERIAL_DIR: String = "res://assets/models/environment/custom/fort_keep/materials/"
## Distancias (m) del cambio de nivel de detalle: LOD0 hasta la primera, LOD1 hasta la segunda, LOD2
## más allá. Con [constant LOD_FADE_MARGIN] de fundido (dither) a cada lado. La primera es corta a
## propósito: a 30 y 60 m las juntas modeladas (2,4 cm) son subpíxel y centellean al moverse (el
## LOD1 centellea la mitad, ver render_fort_keep_model.gd --shimmer).
const LOD1_DISTANCE: float = 50.0
const LOD2_DISTANCE: float = 250.0
const LOD_FADE_MARGIN: float = 10.0

## Color de bando y emblema (índice del atlas) de cada dueño, de docs/mundo.md ("Colores de bando").
const FACTIONS: Dictionary = {
	&"vardheim": [Color("#7ec8e8"), 0.0],
	&"solmarch": [Color("#e9c341"), 1.0],
	&"askarra": [Color("#c3242f"), 2.0],
	&"neutral": [Color("#bdb6a6"), 3.0],
}

## Reino cuya paleta usa el torreón: eldrun (frontera, la del Vado Gris), vardheim, solmarch o askarra.
@export var realm: StringName = &"eldrun"
## Dueño del estandarte: vardheim, solmarch, askarra o neutral.
@export var banner_owner: StringName = &"neutral"
## Atacante que está capturando (vacío = nadie) y avance de la captura (0 a 1).
@export var contest_owner: StringName = &""
@export_range(0.0, 1.0) var capture_progress: float = 0.0
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
	apply_banner(_keep, banner_owner, contest_owner, capture_progress)


## Devuelve el torreón instanciado (null si no se pudo montar).
func get_keep() -> Node3D:
	return _keep


## Cambia la paleta del torreón (sustituye los materiales del glTF por los del reino) y ajusta los
## niveles de detalle y la colisión.
func apply_realm(realm_name: StringName) -> void:
	realm = realm_name
	if _keep == null:
		return
	apply_materials(_keep, realm_name)
	apply_lods(_keep)
	for node: Node in _keep.find_children("*", "StaticBody3D", true, false):
		var body: StaticBody3D = node as StaticBody3D
		body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
		body.collision_mask = 0


## Sustituye, en cada malla bajo [param keep], los materiales del glTF por los del reino (mismo
## nombre de material: keep_stone, keep_trim, keep_cloth...).
static func apply_materials(keep: Node, realm_name: StringName) -> void:
	for node: Node in keep.find_children("*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = node as MeshInstance3D
		for i: int in instance.mesh.get_surface_count():
			var source: Material = instance.mesh.surface_get_material(i)
			if source == null:
				continue
			var path: String = "%s%s/%s.tres" % [MATERIAL_DIR, realm_name, source.resource_name]
			if ResourceLoader.exists(path):
				instance.set_surface_override_material(i, load(path) as Material)


## Rangos de visibilidad de los tres niveles, con fundido por dither de 10 m: LOD0 (sillares
## modelados) hasta 50 m, LOD1 (paños de sillería despiezada) de 50 a 250 m y LOD2 (silueta) más allá.
## Los rangos los pone el código del juego: el glTF no los guarda.
static func apply_lods(keep: Node) -> void:
	for node: Node in keep.find_children("FortKeep_LOD*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = node as MeshInstance3D
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		if instance.name.begins_with("FortKeep_LOD0"):
			instance.visibility_range_begin = 0.0
			instance.visibility_range_end = LOD1_DISTANCE
			instance.visibility_range_end_margin = LOD_FADE_MARGIN
		elif instance.name.begins_with("FortKeep_LOD1"):
			instance.visibility_range_begin = LOD1_DISTANCE
			instance.visibility_range_begin_margin = LOD_FADE_MARGIN
			instance.visibility_range_end = LOD2_DISTANCE
			instance.visibility_range_end_margin = LOD_FADE_MARGIN
		elif instance.name.begins_with("FortKeep_LOD2"):
			instance.visibility_range_begin = LOD2_DISTANCE
			instance.visibility_range_begin_margin = LOD_FADE_MARGIN


## Pone el dueño, el atacante y la captura en el nodo [code]Estandarte[/code] del torreón: los mismos
## parámetros por instancia que moverá el controlador del fuerte. [param owner_name] y
## [param contest_name] son claves de [constant FACTIONS] (vacío = sin atacante); el viento va con
## [param wind] (0 = quieto).
static func apply_banner(keep: Node, owner_name: StringName, contest_name: StringName, progress: float, wind: float = 1.0) -> void:
	var banner: GeometryInstance3D = keep.get_node_or_null("Estandarte") as GeometryInstance3D
	if banner == null:
		return
	var owner_data: Array = FACTIONS.get(owner_name, FACTIONS[&"neutral"])
	banner.set_instance_shader_parameter(&"faction_color", owner_data[0])
	banner.set_instance_shader_parameter(&"emblem_index", owner_data[1])
	var contest_data: Array = FACTIONS.get(contest_name, owner_data)
	banner.set_instance_shader_parameter(&"contest_color", contest_data[0])
	banner.set_instance_shader_parameter(&"capture_progress", progress if FACTIONS.has(contest_name) else 0.0)
	banner.set_instance_shader_parameter(&"wind_strength", wind)
