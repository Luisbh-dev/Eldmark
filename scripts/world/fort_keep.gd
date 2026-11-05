class_name FortKeep
extends Node3D
## Keep of the Vado Gris fort (ART-57): the own model [code]fort_keep.glb[/code] in place,
## with the realm palette, the levels of detail and the low-resolution collision.
## [br][br]
## The scene [code]fort_keep.tscn[/code] hangs the glTF from this node. On entering the tree, the
## glTF materials are replaced by those of [code]fort_keep/materials/<realm>/[/code] (same
## material name), the visibility ranges of the three LODs are set (the glTF does not store them) and
## the static collision body moves to the world layer. The glTF's [code]Estandarte[/code] node
## carries the per-instance parameters (faction color, emblem, capture and wind) that the fortress
## view (FortressView) drives, just like those of the old mast.
## [br][br]
## On the server (headless) only the collision counts: there is nothing to draw.

## Folder of the keep's per-realm materials.
const MATERIAL_DIR: String = "res://assets/models/environment/custom/fort_keep/materials/"
## Distance (m) up to which LOD0 (modeled ashlar blocks) is drawn; from there to LOD2 goes LOD1 (panels
## of broken-up ashlar masonry) and beyond that, the silhouette. With [constant LOD_FADE_MARGIN] of dither fade.
## The first is short on purpose: at 30 and 60 m the modeled joints (2.4 cm) are subpixel and flicker
## when moving.
const LOD1_DISTANCE: float = 50.0
const LOD2_DISTANCE: float = 250.0
const LOD_FADE_MARGIN: float = 10.0

## Neutral banner (of the Hollow) it starts with: faction color and atlas emblem (3, the neutral one).
## The fort view changes them according to the owner. Without an initial value, the instance parameter
## does not exist for whoever looks it up.
const NEUTRAL_BANNER_COLOR: Color = Color("#bdb6a6")
const NEUTRAL_EMBLEM_INDEX: float = 3.0

## Realm whose palette the keep uses: eldrun (the frontier, that of Vado Gris), vardheim, solmarch or askarra.
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


## Replaces, on every mesh under [param keep], the glTF materials with those of the realm (same
## material name: keep_stone, keep_trim, keep_cloth...).
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


## Visibility ranges of the three levels of detail, with dither fade.
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
