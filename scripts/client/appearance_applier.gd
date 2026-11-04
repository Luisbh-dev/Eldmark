class_name AppearanceApplier
extends RefCounted
## Applies a [CharacterAppearance] to a [HumanoidVisual] (docs/progresion.md §7.4, ART-19): it
## mounts body, head, hair, beard and marks as Universal Base Characters glTF scenes with
## [method HumanoidVisual.set_part] (or removes them with [method HumanoidVisual.clear_part]) and
## tints skin, hair and eyes with [method HumanoidVisual.set_tint]. Changing a part does not
## recreate the character.
## [br][br]
## [method apply] does not validate: it sets what the indices say (one that does not exist in the
## catalog leaves that slot as it was). Validity is decided by [method resolve], which the client
## uses with the appearance from each player ENTITY_SPAWN: one that is not 8 B, that is all 0 or
## that does not pass [method CharacterAppearance.validate] for its realm is replaced by
## [method CharacterAppearance.default_for] of the realm's people (§7.3).
## [br][br]
## Scenes are paths in the catalog ([member AppearancePart.scene_path]): the server never loads
## them. Here they are loaded with [method ResourceLoader.load] (which caches them). Client only.

## [HumanoidVisual] tint channels for each color list in the catalog.
const SKIN_CHANNEL: StringName = &"skin"
const HAIR_CHANNEL: StringName = &"hair"
const EYES_CHANNEL: StringName = &"eyes"


## Sets on [param visual] the parts and colors of [param appearance] according to [param catalog]
## (null = [method AppearanceCatalog.shared]). Without hair, beard or marks (0) it removes that
## slot. It does nothing with a null visual or appearance.
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


## The appearance the client shows for the 8 B [param bytes] of a player of realm [param realm]
## ([enum NetProtocol.Realm] code): their own if valid for that realm's people and, if not
## (another size, all 0 because the zone has no progress, or it fails [method CharacterAppearance.validate]), the default one for that people. Null if the realm has no
## people in the catalog.
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


## [method resolve] and [method apply] in one go. Returns the applied appearance (null if there was none).
static func apply_bytes(visual: HumanoidVisual, bytes: PackedByteArray, realm: int,
		catalog: AppearanceCatalog = null) -> CharacterAppearance:
	if catalog == null:
		catalog = AppearanceCatalog.shared()
	var appearance: CharacterAppearance = resolve(bytes, realm, catalog)
	apply(visual, appearance, catalog)
	# The sword also belongs to the realm: its model and the color of its trail.
	if visual != null:
		visual.set_realm(realm)
	return appearance


## The scene of piece [param index] of [param parts] (null if it does not exist, has no scene or fails to load).
static func part_scene(parts: Array[AppearancePart], index: int) -> PackedScene:
	if index < 0 or index >= parts.size() or parts[index] == null:
		return null
	var path: String = parts[index].scene_path
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return ResourceLoader.load(path) as PackedScene


# --- Internal ------------------------------------------------------------------------------------

# A piece that is always present (body, head): an index that does not exist leaves whatever was there.
static func _set_part(visual: HumanoidVisual, slot: StringName, parts: Array[AppearancePart], index: int) -> void:
	var scene: PackedScene = part_scene(parts, index)
	if scene != null:
		visual.set_part(slot, scene)
	elif index >= 0 and index < parts.size():
		# The piece exists but has no mesh of its own (or is not in the repo yet): the slot is left empty.
		visual.clear_part(slot)


# Hair, beard or marks: 0 means "none"; otherwise, index + 1.
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
