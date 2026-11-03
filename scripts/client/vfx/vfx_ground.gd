class_name VfxGround
extends RefCounted
## Color del polvo según el suelo que se pisa (ART-09, solo cliente): el polvo de una esquiva o un
## aterrizaje no es del reino sino del material del suelo.
## [br][br]
## [method color_at] lee el material del terreno bajo un punto: con un [code]Terrain3D[/code] mira el
## material pintado en ese punto (base, superposición y mezcla) y toma el color medio de su textura; sin
## él (un suelo liso, el servidor) devuelve el color de [param fallback_kind]. No depende de Terrain3D en
## compilación: usa solo las propiedades y métodos que expone, así que carga igual sin el addon.

# Color medio de la textura de cada id de material del terreno (se calcula una vez por terreno).
static var _cache: Dictionary[int, Color] = {}


## Color del polvo bajo [param position] (mundo). [param terrain] es el nodo Terrain3D de la zona (o null).
## [param assets] es el recurso de materiales del terreno ([code]Terrain3DAssets[/code]) si el nodo no lo
## enseña (el nodo puede devolver una lista vacía hasta que se inicializa): sin él se pregunta al nodo.
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


# Una tierra, una piedra o una hierba pintadas no son el color del polvo que levantan: se aclaran y
# desaturan hacia un polvo neutro.
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


# El material del terreno con ese id: se busca en la lista de texturas del recurso de assets por su
# propiedad id (el contador de texturas del recurso no es fiable hasta que el terreno se inicializa).
static func _find_asset(assets: Object, id: int) -> Object:
	var list: Array = assets.get(&"texture_list") as Array
	for entry: Variant in list:
		var asset: Object = entry as Object
		if asset != null and int(asset.get(&"id")) == id:
			return asset
	return null
