class_name FortKeep
extends Node3D
## Torreón del fuerte del Vado Gris (ART-57): el modelo propio [code]fort_keep.glb[/code] en su sitio,
## con la paleta de reino, los niveles de detalle y la colisión de baja resolución.
## [br][br]
## La escena [code]fort_keep.tscn[/code] cuelga el glTF de este nodo. Al entrar en el árbol se
## sustituyen los materiales del glTF por los de [code]fort_keep/materials/<reino>/[/code] (mismo
## nombre de material), se ponen los rangos de visibilidad de los tres LOD (el glTF no los guarda) y
## el cuerpo estático de colisión pasa a la capa del mundo. El nodo [code]Estandarte[/code] del glTF
## lleva los parámetros por instancia (color de bando, emblema, captura y viento) que mueve la vista
## de la fortaleza (FortressView) igual que los del mástil antiguo.
## [br][br]
## En el servidor (headless) solo cuenta la colisión: no hay nada que dibujar.

## Carpeta de los materiales por reino del torreón.
const MATERIAL_DIR: String = "res://assets/models/environment/custom/fort_keep/materials/"
## Distancia (m) hasta la que se dibuja el LOD0 (sillares modelados); de ahí al LOD2 va el LOD1 (paños
## de sillería despiezada) y más allá, la silueta. Con [constant LOD_FADE_MARGIN] de fundido por dither.
## La primera es corta a propósito: a 30 y 60 m las juntas modeladas (2,4 cm) son subpíxel y centellean
## al moverse.
const LOD1_DISTANCE: float = 50.0
const LOD2_DISTANCE: float = 250.0
const LOD_FADE_MARGIN: float = 10.0

## Estandarte neutral (de los Huecos) con el que empieza: color de bando y emblema del atlas (3, el neutral).
## La vista del fuerte los cambia según el dueño. Sin un valor inicial, el parámetro de instancia
## no existe para quien lo busca.
const NEUTRAL_BANNER_COLOR: Color = Color("#bdb6a6")
const NEUTRAL_EMBLEM_INDEX: float = 3.0

## Reino cuya paleta usa el torreón: eldrun (la frontera, la del Vado Gris), vardheim, solmarch o askarra.
@export var realm: StringName = &"eldrun"


func _ready() -> void:
	apply_materials(self, realm)
	apply_lods(self)
	var banner: GeometryInstance3D = find_child("Estandarte", true, false) as GeometryInstance3D
	if banner != null:
		banner.set_instance_shader_parameter(&"faction_color", NEUTRAL_BANNER_COLOR)
		banner.set_instance_shader_parameter(&"contest_color", NEUTRAL_BANNER_COLOR)
		banner.set_instance_shader_parameter(&"emblem_index", NEUTRAL_EMBLEM_INDEX)
		banner.set_instance_shader_parameter(&"capture_progress", 0.0)
		banner.set_instance_shader_parameter(&"wind_strength", 1.0)
	for node: Node in find_children("*", "StaticBody3D", true, false):
		var body: StaticBody3D = node as StaticBody3D
		body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
		body.collision_mask = 0


## Sustituye, en cada malla bajo [param keep], los materiales del glTF por los del reino (mismo nombre
## de material: keep_stone, keep_trim, keep_cloth...).
static func apply_materials(keep: Node, realm_name: StringName) -> void:
	for node: Node in keep.find_children("*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = node as MeshInstance3D
		if instance.mesh == null:
			continue
		for i: int in instance.mesh.get_surface_count():
			var source: Material = instance.mesh.surface_get_material(i)
			if source == null:
				continue
			var path: String = "%s%s/%s.tres" % [MATERIAL_DIR, realm_name, source.resource_name]
			if ResourceLoader.exists(path):
				instance.set_surface_override_material(i, load(path) as Material)


## Rangos de visibilidad de los tres niveles de detalle, con fundido por dither.
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
