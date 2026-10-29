class_name ZoneMapDefinition
extends Resource
## Mapa horneado de una zona (UI-20, docs/fuerte.md sección 6): qué imagen es, qué trozo del mundo
## cubre y los lugares fijos que tiene. La imagen cenital la genera [code]tools/bake_zone_map.gd[/code]
## (sin GPU) y la guarda en [code]assets/maps/<zona>.png[/code] (por Git LFS) junto a este recurso en
## texto, [code]assets/maps/<zona>_map.tres[/code].
## [br][br]
## [b]Escala.[/b] La imagen es cuadrada o rectangular y tiene el norte (-Z) arriba y el este (+X) a la
## derecha: el píxel (0, 0) es la esquina noroeste, [member world_origin], y el píxel
## ([member image_size]) la esquina sureste, [code]world_origin + world_size[/code]. Un metro son
## [code]image_size / world_size[/code] píxeles. La altura no cuenta.
## [br][br]
## Solo cliente (y la herramienta).

## Dónde se guardan los mapas.
const MAP_DIR: String = "res://assets/maps"
const DEFINITION_SUFFIX: String = "_map.tres"
const IMAGE_SUFFIX: String = ".png"

## Zona a la que pertenece.
@export var zone_id: StringName = &""
## Ruta de la imagen.
@export var image_path: String = ""
## Esquina noroeste (x mínima, z mínima) del trozo de mundo que cubre, en metros.
@export var world_origin: Vector2 = Vector2.ZERO
## Tamaño en metros de ese trozo (x, z).
@export var world_size: Vector2 = Vector2(100.0, 100.0)
## Tamaño de la imagen en píxeles.
@export var image_size: Vector2i = Vector2i(1024, 1024)
## Lugares fijos de la zona.
@export var landmarks: Array[MapLandmark] = []


## Ruta del recurso del mapa de la zona [param zone_id].
static func definition_path(p_zone_id: StringName) -> String:
	return "%s/%s%s" % [MAP_DIR, String(p_zone_id), DEFINITION_SUFFIX]


## Ruta de la imagen del mapa de la zona [param zone_id].
static func image_path_for(p_zone_id: StringName) -> String:
	return "%s/%s%s" % [MAP_DIR, String(p_zone_id), IMAGE_SUFFIX]


## El mapa horneado de [param zone_id], o null si la zona no tiene.
static func load_for_zone(p_zone_id: StringName) -> ZoneMapDefinition:
	var path: String = definition_path(p_zone_id)
	if not ResourceLoader.exists(path):
		return null
	return load(path) as ZoneMapDefinition


## La imagen del mapa como textura, o null si todavía no está importada.
func load_texture() -> Texture2D:
	if image_path.is_empty() or not ResourceLoader.exists(image_path):
		return null
	return load(image_path) as Texture2D


## Píxeles por metro en x y z.
func pixels_per_meter() -> Vector2:
	return Vector2(float(image_size.x) / world_size.x, float(image_size.y) / world_size.y)


## Metros por píxel (en x; con la imagen proporcional al mundo es igual en z).
func meters_per_pixel() -> float:
	return world_size.x / float(image_size.x)


## Posición en la imagen (píxeles, con fracción) de un punto del mundo. Norte arriba.
func world_to_pixel(world: Vector3) -> Vector2:
	var scale_xy: Vector2 = pixels_per_meter()
	return Vector2((world.x - world_origin.x) * scale_xy.x, (world.z - world_origin.y) * scale_xy.y)


## Punto del mundo (y = 0) bajo un píxel de la imagen.
func pixel_to_world(pixel: Vector2) -> Vector3:
	var scale_xy: Vector2 = pixels_per_meter()
	return Vector3(pixel.x / scale_xy.x + world_origin.x, 0.0, pixel.y / scale_xy.y + world_origin.y)


## Posición normalizada (0 a 1 en cada eje) de un punto del mundo sobre el mapa.
func world_to_uv(world: Vector3) -> Vector2:
	return Vector2((world.x - world_origin.x) / world_size.x, (world.z - world_origin.y) / world_size.y)


## Punto del mundo (y = 0) en la posición normalizada [param uv].
func uv_to_world(uv: Vector2) -> Vector3:
	return Vector3(world_origin.x + uv.x * world_size.x, 0.0, world_origin.y + uv.y * world_size.y)


## true si [param world] cae dentro del trozo de mundo del mapa.
func contains(world: Vector3) -> bool:
	return world.x >= world_origin.x and world.x <= world_origin.x + world_size.x \
			and world.z >= world_origin.y and world.z <= world_origin.y + world_size.y


## Lugares fijos de tipo [param kind].
func get_landmarks(kind: StringName) -> Array[MapLandmark]:
	var found: Array[MapLandmark] = []
	for landmark: MapLandmark in landmarks:
		if landmark.kind == kind:
			found.append(landmark)
	return found
