class_name VfxGround
extends RefCounted
## Dust color according to the ground being stepped on (ART-09, client only): the dust of a dodge or a
## landing belongs not to the realm but to the ground material.
## [br][br]
## [method color_at] reads the terrain material under a point: with a [code]Terrain3D[/code] it looks at
## the material painted at that point (base, overlay and blend) and takes the mean color of its texture;
## without it (a plain floor, the server) it returns the color of [param fallback_kind]. It does not
## depend on Terrain3D at compile time: it uses only the properties and methods it exposes, so it loads
## the same without the addon.

# Mean color of the texture of each terrain material id (computed once per terrain).
static var _cache: Dictionary[int, Color] = {}


## Dust color under [param position] (world). [param terrain] is the zone's Terrain3D node (or null).
## [param assets] is the terrain's materials resource ([code]Terrain3DAssets[/code]) if the node does not
## expose it (the node may return an empty list until it is initialized): without it, the node is asked.
static func color_at(terrain: Object, position: Vector3, fallback_kind: StringName = &"dirt",
		assets: Object = null) -> Color:
	var fallback: Color = VfxPalette.ground(fallback_kind)
	if terrain == null:
		return fallback
	var data: Object = terrain.get(&"data") as Object
	if assets == null:
		assets = terrain.get(&"assets") as Object
	if data == null or assets == null:
		return fallback
	var ids: Vector3 = data.call(&"get_texture_id", position)
	var first: int = int(ids.x)
	var second: int = int(ids.y)
	var blend: float = clampf(ids.z, 0.0, 1.0)
	var color_a: Color = _asset_color(assets, first, fallback)
	var color_b: Color = _asset_color(assets, second, color_a)
	return _to_dust(color_a.lerp(color_b, blend))


# A painted soil, stone or grass is not the color of the dust it kicks up: it is lightened and
# desaturated toward a neutral dust.
static func _to_dust(ground_color: Color) -> Color:
	var neutral: Color = Color(0.74, 0.7, 0.64)
	var dusty: Color = ground_color.lerp(neutral, 0.4)
	return Color.from_hsv(dusty.h, dusty.s * 0.8, clampf(dusty.v * 1.05 + 0.03, 0.0, 0.7))


static func _asset_color(assets: Object, id: int, fallback: Color) -> Color:
	if _cache.has(id):
		return _cache[id]
	var asset: Object = _find_asset(assets, id)
	if asset == null:
		return fallback
	var texture: Texture2D = asset.get(&"albedo_texture") as Texture2D
	if texture == null:
		return fallback
	var image: Image = texture.get_image()
	if image == null or image.is_empty():
		return fallback
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGB8)
	image.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	var average: Color = image.get_pixel(0, 0)
	_cache[id] = average
	return average


# The terrain material with that id: it is looked up in the assets resource's texture list by its id
# property (the resource's texture counter is not reliable until the terrain is initialized).
static func _find_asset(assets: Object, id: int) -> Object:
	var list: Array = assets.get(&"texture_list") as Array
	for entry: Variant in list:
		var asset: Object = entry as Object
		if asset != null and int(asset.get(&"id")) == id:
			return asset
	return null
