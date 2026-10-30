class_name AppearanceApplier
extends RefCounted
## Aplica una [CharacterAppearance] a un [HumanoidVisual] (docs/progresion.md §7.4, ART-19): monta cuerpo,
## cabeza, pelo, barba y marcas como escenas glTF de Universal Base Characters con
## [method HumanoidVisual.set_part] (o las quita con [method HumanoidVisual.clear_part]) y tiñe piel, pelo y
## ojos con [method HumanoidVisual.set_tint]. Cambiar una pieza no recrea el personaje.
## [br][br]
## [method apply] no valida: pone lo que dicen los índices (uno que no existe en el catálogo deja esa ranura
## como estaba). La validez la decide [method resolve], que el cliente usa con la apariencia de cada
## ENTITY_SPAWN de jugador: una que no son 8 B, que va a 0 o que no pasa [method CharacterAppearance.validate]
## para su reino se sustituye por [method CharacterAppearance.default_for] del pueblo del reino (§7.3).
## [br][br]
## Las escenas van como rutas en el catálogo ([member AppearancePart.scene_path]): el servidor nunca las carga.
## Aquí se cargan con [method ResourceLoader.load] (que las guarda en caché). Solo cliente.

## Canales de tinte de [HumanoidVisual] de cada lista de colores del catálogo.
const SKIN_CHANNEL: StringName = &"skin"
const HAIR_CHANNEL: StringName = &"hair"
const EYES_CHANNEL: StringName = &"eyes"


## Pone en [param visual] las piezas y los colores de [param appearance] según [param catalog] (null =
## [method AppearanceCatalog.shared]). Sin pelo, barba o marcas (0) quita esa ranura. No hace nada con un
## visual o una apariencia nulos.
static func apply(visual: HumanoidVisual, appearance: CharacterAppearance,
		catalog: AppearanceCatalog = null) -> void:
	if visual == null or appearance == null:
		return
	if catalog == null:
		catalog = AppearanceCatalog.shared()
	_set_part(visual, &"body", catalog.bodies, appearance.body)
	_set_part(visual, &"head", catalog.heads, appearance.head)
	_set_optional_part(visual, &"hair", catalog.hairs, appearance.hair)
	_set_optional_part(visual, &"beard", catalog.beards, appearance.beard)
	_set_optional_part(visual, &"marks", catalog.marks, appearance.marks)
	_tint(visual, SKIN_CHANNEL, catalog.skin_tones, appearance.skin)
	_tint(visual, HAIR_CHANNEL, catalog.hair_colors, appearance.hair_color)
	_tint(visual, EYES_CHANNEL, catalog.eye_colors, appearance.eyes)


## La apariencia que el cliente enseña para los 8 B [param bytes] de un jugador del reino [param realm] (código
## de [enum NetProtocol.Realm]): la suya si vale para el pueblo de ese reino y, si no (otro tamaño, todo a 0
## porque la zona no tiene progreso, o no pasa [method CharacterAppearance.validate]), la de por defecto de ese
## pueblo. Null si el reino no tiene pueblo en el catálogo.
static func resolve(bytes: PackedByteArray, realm: int, catalog: AppearanceCatalog = null) -> CharacterAppearance:
	if catalog == null:
		catalog = AppearanceCatalog.shared()
	var race: RaceDefinition = catalog.race_for_realm(RealmCatalog.id_of_code(realm))
	if race == null:
		return null
	var appearance: CharacterAppearance = CharacterAppearance.decode(bytes)
	if appearance != null and appearance.validate(catalog, realm, race.id):
		return appearance
	return CharacterAppearance.default_for(catalog, catalog.race_index(race.id))


## [method resolve] y [method apply] de una vez. Devuelve la apariencia aplicada (null si no había).
static func apply_bytes(visual: HumanoidVisual, bytes: PackedByteArray, realm: int,
		catalog: AppearanceCatalog = null) -> CharacterAppearance:
	if catalog == null:
		catalog = AppearanceCatalog.shared()
	var appearance: CharacterAppearance = resolve(bytes, realm, catalog)
	apply(visual, appearance, catalog)
	return appearance


## La escena de la pieza [param index] de [param parts] (null si no existe, no tiene escena o no se carga).
static func part_scene(parts: Array[AppearancePart], index: int) -> PackedScene:
	if index < 0 or index >= parts.size() or parts[index] == null:
		return null
	var path: String = parts[index].scene_path
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return ResourceLoader.load(path) as PackedScene


# --- Interno ------------------------------------------------------------------------------------

# Una pieza que siempre está (cuerpo, cabeza): un índice que no existe deja la que hubiera.
static func _set_part(visual: HumanoidVisual, slot: StringName, parts: Array[AppearancePart], index: int) -> void:
	var scene: PackedScene = part_scene(parts, index)
	if scene != null:
		visual.set_part(slot, scene)
	elif index >= 0 and index < parts.size():
		# La pieza existe pero no tiene malla propia (o aún no está en el repo): la ranura se queda vacía.
		visual.clear_part(slot)


# Pelo, barba o marcas: 0 es «sin»; si no, índice + 1.
static func _set_optional_part(visual: HumanoidVisual, slot: StringName, parts: Array[AppearancePart],
		value: int) -> void:
	if value == CharacterAppearance.NONE:
		visual.clear_part(slot)
		return
	if value - 1 >= parts.size():
		return
	var scene: PackedScene = part_scene(parts, value - 1)
	if scene != null:
		visual.set_part(slot, scene)
	else:
		visual.clear_part(slot)


static func _tint(visual: HumanoidVisual, channel: StringName, colors: Array[AppearanceColor], index: int) -> void:
	if index >= 0 and index < colors.size() and colors[index] != null:
		visual.set_tint(channel, colors[index].color)
