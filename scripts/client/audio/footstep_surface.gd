class_name FootstepSurface
extends RefCounted
## Surface stepped on at a point (ART-11, client only): decides which footstep plays. Two sources, in this order:
## [br]- The [code]surface[/code] metadata of the collider under the feet (or of its parent): a wooden bridge, a
## slab or the ford water set it in their scene with one of [constant CombatSoundBank.SURFACES].
## [br]- The painted material of [code]Terrain3D[/code] under that point ([method kind_of_texture_name] translates the texture
## name: "Losa de calzada" (road slab) is stone, "Hierba seca" (dry grass) is grass).
## [br]With neither of the two (a flat floor, a test), grass, which is what gets stepped on the most.

## Collider metadata.
const META_SURFACE: StringName = &"surface"
## Texture names (lowercase, without accents) that give each surface; the first one that matches wins.
const TEXTURE_KEYWORDS: Array = [
	[&"stone", ["roca", "losa", "piedra", "calzada", "muralla", "adoqu", "stone", "rock"]],
	[&"wood", ["madera", "tabla", "wood", "plank"]],
	[&"water", ["agua", "rio", "water"]],
	[&"dirt", ["tierra", "barro", "camino", "senda", "grava", "arena", "dirt", "mud", "gravel", "sand"]],
	[&"grass", ["hierba", "pasto", "grass"]],
]

static var _terrain: Object = null
static var _names: Dictionary = {}


## Surface under [param position] (world). [param context] is any node of the client tree (it gives the physics
## world and the scene in which the terrain is searched for).
static func kind_at(context: Node3D, position: Vector3) -> StringName:
	if context == null or not context.is_inside_tree():
		return CombatSoundBank.SURFACE_GRASS
	var hit_kind: StringName = _kind_from_collider(context, position)
	if hit_kind != &"":
		return hit_kind
	var terrain_kind: StringName = _kind_from_terrain(context, position)
	if terrain_kind != &"":
		return terrain_kind
	return CombatSoundBank.SURFACE_GRASS


## Surface given by the name of a terrain texture ([code]&""[/code] if it is not recognized).
static func kind_of_texture_name(texture_name: String) -> StringName:
	var lowered: String = _strip_accents(texture_name.to_lower())
	for entry: Array in TEXTURE_KEYWORDS:
		for keyword: String in entry[1]:
			if lowered.contains(keyword):
				return entry[0] as StringName
	return &""


## Forgets the terrain found (zone change, tests).
static func clear_cache() -> void:
	_terrain = null
	_names.clear()


static func _kind_from_collider(context: Node3D, position: Vector3) -> StringName:
	var space: PhysicsDirectSpaceState3D = context.get_world_3d().direct_space_state if context.get_world_3d() != null \
			else null
	if space == null:
		return &""
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			position + Vector3(0.0, 0.6, 0.0), position + Vector3(0.0, -0.8, 0.0))
	var result: Dictionary = space.intersect_ray(query)
	if result.is_empty():
		return &""
	var collider: Object = result.get("collider") as Object
	var node: Node = collider as Node
	while node != null:
		if node.has_meta(META_SURFACE):
			var value: StringName = StringName(String(node.get_meta(META_SURFACE)))
			return value if CombatSoundBank.SURFACES.has(value) else &""
		node = node.get_parent()
		# Only the collider and its parent: it does not climb the whole scene.
		if node == null or node == context.get_tree().current_scene:
			break
	return &""


## The Terrain3D node of the current scene (null if there is none or the extension does not exist). Shared by the footsteps and the dust
## ([VfxGround]).
static func terrain_for(context: Node) -> Object:
	if is_instance_valid(_terrain):
		return _terrain
	_terrain = null
	_names.clear()
	if context == null or not context.is_inside_tree() or not ClassDB.class_exists(&"Terrain3D"):
		return null
	var root: Node = context.get_tree().current_scene
	if root == null:
		return null
	var found: Array[Node] = root.find_children("*", "Terrain3D", true, false)
	if not found.is_empty():
		_terrain = found[0]
	return _terrain


static func _kind_from_terrain(context: Node3D, position: Vector3) -> StringName:
	if terrain_for(context) == null:
		return &""
	var data: Object = _terrain.get(&"data") as Object
	var assets: Object = _terrain.get(&"assets") as Object
	if data == null or assets == null:
		return &""
	var ids: Vector3 = data.call(&"get_texture_id", position)
	var id: int = int(ids.y) if ids.z > 0.5 else int(ids.x)
	if not _names.has(id):
		var texture_name: String = ""
		for entry: Variant in (assets.get(&"texture_list") as Array):
			var asset: Object = entry as Object
			if asset != null and int(asset.get(&"id")) == id:
				texture_name = String(asset.get(&"name"))
				break
		_names[id] = kind_of_texture_name(texture_name)
	return _names[id]


static func _strip_accents(text: String) -> String:
	return text.replace("á", "a").replace("é", "e").replace("í", "i").replace("ó", "o").replace("ú", "u") \
			.replace("ñ", "n")
