class_name FortKeepPreview
extends Node3D
## Preview scene for the fort's new keep (ART-57, development tool).
##
## It instantiates Vado Gris as is (child "Zona"), removes in the in-memory copy the fort's old tower and
## flagpole (without touching vado_gris.tscn or its generators) and puts
## [code]assets/models/environment/custom/fort_keep.glb[/code] in their place: the same origin as the
## 6 x 6 m tower, at the courtyard's ground level. The keep is drawn with the realm materials from
## [code]fort_keep/materials/<realm>/[/code] (same name as the glTF materials), with three levels of
## detail (see [method apply_lods]) and the low-resolution collision on the world layer.
## [br][br]
## The glTF's [code]Estandarte[/code] node (banner) replaces the fort's marker of the same name: it
## exposes the per-instance parameters that the fort controller drives (see [method apply_banner]).
## [br][br]
## It is not used in the game: nothing on the server or in the game scenes references it.

## glTF scene (the importer turns it into a PackedScene).
const KEEP_SCENE_PATH: String = "res://assets/models/environment/custom/fort_keep.glb"
const MATERIAL_DIR: String = "res://assets/models/environment/custom/fort_keep/materials/"
## Level-of-detail switch distances (m): LOD0 up to the first, LOD1 up to the second, LOD2 beyond. With
## [constant LOD_FADE_MARGIN] of dither fade on each side. The first is short on purpose: at 30 and 60 m
## the modeled joints (2.4 cm) are subpixel and shimmer when moving (LOD1 shimmers half as much, see
## render_fort_keep_model.gd --shimmer).
const LOD1_DISTANCE: float = 50.0
const LOD2_DISTANCE: float = 250.0
const LOD_FADE_MARGIN: float = 10.0

## Faction color and emblem (atlas index) of each owner, from docs/mundo.md ("Colores de bando").
const FACTIONS: Dictionary = {
	&"vardheim": [Color("#7ec8e8"), 0.0],
	&"solmarch": [Color("#e9c341"), 1.0],
	&"askarra": [Color("#c3242f"), 2.0],
	&"neutral": [Color("#bdb6a6"), 3.0],
}

## Realm whose palette the keep uses: eldrun (frontier, Vado Gris's), vardheim, solmarch or askarra.
@export var realm: StringName = &"eldrun"
## Owner of the banner: vardheim, solmarch, askarra or neutral.
@export var banner_owner: StringName = &"neutral"
## Attacker that is capturing (empty = nobody) and capture progress (0 to 1).
@export var contest_owner: StringName = &""
@export_range(0.0, 1.0) var capture_progress: float = 0.0
## Path (from this node) of the zone's fort.
@export var fort_path: NodePath = ^"Zona/Fuerte"
## Removes the fort's old tower and flagpole.
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


## Returns the instantiated keep (null if it could not be assembled).
func get_keep() -> Node3D:
	return _keep


## Changes the keep's palette (replaces the glTF materials with the realm's) and adjusts the levels of
## detail and the collision.
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


## Replaces, in each mesh under [param keep], the glTF materials with the realm's (same material name:
## keep_stone, keep_trim, keep_cloth...).
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


## Visibility ranges of the three levels, with a 10 m dither fade: LOD0 (modeled ashlar blocks) up to
## 50 m, LOD1 (panels of cut-stone masonry) from 50 to 250 m and LOD2 (silhouette) beyond. The ranges
## are set by the game code: the glTF does not store them.
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


## Sets the owner, the attacker and the capture on the keep's [code]Estandarte[/code] node (banner): the
## same per-instance parameters that the fort controller will drive. [param owner_name] and
## [param contest_name] are keys of [constant FACTIONS] (empty = no attacker); the wind is set with
## [param wind] (0 = still).
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
