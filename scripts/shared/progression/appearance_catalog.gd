class_name AppearanceCatalog
extends Resource
## Appearance catalog (docs/progression.md §7.2, ART-19), in
## [code]data/characters/appearance_catalog.tres[/code]: the peoples ([RaceDefinition]), parts
## ([AppearancePart]) and colors ([AppearanceColor]) that index the 8 B of [CharacterAppearance].
## [br][br]
## All lists are [b]append-only[/b]: [code]data/characters/appearance_ids.txt[/code] freezes the
## order ("category index id" per line) and the test requires the catalog to start with that list.
## Nothing is reordered or deleted (a part is retired by removing it from the races), so the 8 B
## stored in the database remain valid after any patch. In phase 5 it only lists parts that exist
## in the repo (§16). [ProgressionRulesExport] exports it ([code]races[/code] and
## [code]appearance[/code] sections) so that the platform applies the same rule when creating the
## character. Shared: no clock, no randomness.

## Path of the catalog.
const PATH: String = "res://data/characters/appearance_catalog.tres"
## Frozen order of the lists.
const IDS_PATH: String = "res://data/characters/appearance_ids.txt"
## Part lists, in the order of the 8 B.
const PART_CATEGORIES: Array[StringName] = [&"bodies", &"heads", &"hairs", &"beards", &"marks"]
## Color lists, in the order of the 8 B.
const COLOR_CATEGORIES: Array[StringName] = [&"skin_tones", &"hair_colors", &"eye_colors"]
## All lists, in the order of [code]appearance_ids.txt[/code].
const CATEGORIES: Array[StringName] = [&"races", &"bodies", &"heads", &"hairs", &"beards", &"marks",
		&"skin_tones", &"hair_colors", &"eye_colors"]
## Maximum size of each list so that its index fits in the 8 B: byte 0 and hair and beard go with
## +1; eyes and marks share byte 7 (4 bits each, marks with +1).
const MAX_SIZES: Dictionary[StringName, int] = {
	&"races": 255, &"bodies": 256, &"heads": 256, &"hairs": 255, &"beards": 255, &"marks": 15,
	&"skin_tones": 256, &"hair_colors": 256, &"eye_colors": 16,
}
## Format of the ids.
const ID_PATTERN: String = "^[a-z0-9_]{1,32}$"

@export var races: Array[RaceDefinition] = []
@export var bodies: Array[AppearancePart] = []
@export var heads: Array[AppearancePart] = []
@export var hairs: Array[AppearancePart] = []
@export var beards: Array[AppearancePart] = []
@export var marks: Array[AppearancePart] = []
@export var skin_tones: Array[AppearanceColor] = []
@export var hair_colors: Array[AppearanceColor] = []
@export var eye_colors: Array[AppearanceColor] = []

static var _shared: AppearanceCatalog = null


## The catalog at [constant PATH], loaded once. If it cannot be loaded, it logs the error and
## returns an empty one (no appearance is valid).
static func shared() -> AppearanceCatalog:
	if _shared == null:
		_shared = ResourceLoader.load(PATH) as AppearanceCatalog
		if _shared == null:
			push_error("[Eldmark] No se puede cargar el catálogo de apariencia %s" % PATH)
			_shared = AppearanceCatalog.new()
		else:
			for message: String in _shared.get_errors():
				push_error("[Eldmark] Catálogo de apariencia: %s" % message)
	return _shared


## Index (from 0) of people [param race_id] in [member races]; −1 if it does not exist.
func race_index(race_id: StringName) -> int:
	for i: int in range(races.size()):
		if races[i] != null and races[i].id == race_id:
			return i
	return -1


## The people of [param realm_id] ([RealmCatalog] id) with the lowest index, or null. In phase 5
## there is one per realm.
func race_for_realm(realm_id: StringName) -> RaceDefinition:
	for race: RaceDefinition in races:
		if race != null and race.realm == realm_id:
			return race
	return null


## The list [param category] (one of [constant CATEGORIES]); empty if it does not exist.
func entries(category: StringName) -> Array:
	match category:
		&"races":
			return races
		&"bodies":
			return bodies
		&"heads":
			return heads
		&"hairs":
			return hairs
		&"beards":
			return beards
		&"marks":
			return marks
		&"skin_tones":
			return skin_tones
		&"hair_colors":
			return hair_colors
		&"eye_colors":
			return eye_colors
	return []


## The ids of the list [param category], in order (a null gap yields an empty string).
func ids_of(category: StringName) -> PackedStringArray:
	var result := PackedStringArray()
	for entry: Resource in entries(category):
		result.append(String(entry.get(&"id")) if entry != null else "")
	return result


## Data errors (empty if the catalog is valid): ids with the right format and unique in each list,
## sizes that fit in the 8 B, at least one body, one head and one color of each kind, parts with
## bodies that exist and, per people, a playable realm, indices that exist and are unique, lists
## without which no valid appearance exists, [code]allows_no_*[/code] when there is no compatible
## hair or beard, and no stats.
func get_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	var id_regex := RegEx.new()
	id_regex.compile(ID_PATTERN)
	for category: StringName in CATEGORIES:
		var list: Array = entries(category)
		if list.size() > MAX_SIZES[category]:
			errors.append("%s tiene %d entradas y caben %d" % [category, list.size(), MAX_SIZES[category]])
		var seen: Dictionary[String, bool] = {}
		for i: int in range(list.size()):
			if list[i] == null:
				errors.append("%s[%d] está vacía" % [category, i])
				continue
			var id: String = String(list[i].get(&"id"))
			if id_regex.search(id) == null:
				errors.append("%s[%d]: el id '%s' no tiene el formato %s" % [category, i, id, ID_PATTERN])
			if seen.has(id):
				errors.append("%s: el id '%s' está repetido" % [category, id])
			seen[id] = true
	for category: StringName in [&"bodies", &"heads", &"skin_tones", &"hair_colors", &"eye_colors"]:
		if entries(category).is_empty():
			errors.append("%s está vacía: ninguna apariencia sería válida" % category)
	for category: StringName in PART_CATEGORIES:
		var parts: Array = entries(category)
		for i: int in range(parts.size()):
			var part: AppearancePart = parts[i]
			if part == null:
				continue
			for body: int in part.bodies:
				if body < 0 or body >= bodies.size():
					errors.append("%s[%d] ('%s'): el cuerpo %d no existe" % [category, i, part.id, body])
	for race: RaceDefinition in races:
		if race != null:
			errors.append_array(_race_errors(race))
	return errors


func _race_errors(race: RaceDefinition) -> PackedStringArray:
	var errors := PackedStringArray()
	var label: String = "race '%s'" % race.id
	if not RealmCatalog.is_realm(race.realm):
		errors.append("%s: el reino '%s' no es un reino jugable" % [label, race.realm])
	if not race.stat_modifiers.is_empty():
		errors.append("%s: stat_modifiers tiene que estar vacío (sin estadísticas raciales, §0)" % label)
	for category: StringName in PART_CATEGORIES + COLOR_CATEGORIES:
		var allowed: PackedInt32Array = race.allowed(category)
		var size: int = entries(category).size()
		var seen: Dictionary[int, bool] = {}
		for index: int in allowed:
			if index < 0 or index >= size:
				errors.append("%s: %s %d no existe" % [label, category, index])
			if seen.has(index):
				errors.append("%s: %s %d está repetido" % [label, category, index])
			seen[index] = true
	for category: StringName in [&"bodies", &"skin_tones", &"hair_colors", &"eye_colors"]:
		if race.allowed(category).is_empty():
			errors.append("%s: no permite ningún %s" % [label, category])
	for body: int in race.bodies:
		if body < 0 or body >= bodies.size():
			continue
		if fitting_indices(race.heads, heads, body).is_empty():
			errors.append("%s: ninguna cabeza encaja con el cuerpo %d" % [label, body])
		if not race.allows_no_hair and fitting_indices(race.hairs, hairs, body).is_empty():
			errors.append("%s: sin pelo compatible con el cuerpo %d, allows_no_hair tiene que ser true"
					% [label, body])
		if not race.allows_no_beard and fitting_indices(race.beards, beards, body).is_empty():
			errors.append("%s: sin barba compatible con el cuerpo %d, allows_no_beard tiene que ser true"
					% [label, body])
	return errors


## Indices of [param allowed] that exist in [param parts] and fit with [param body].
static func fitting_indices(allowed: PackedInt32Array, parts: Array[AppearancePart], body: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for index: int in allowed:
		if index >= 0 and index < parts.size() and parts[index] != null and parts[index].fits_body(body):
			result.append(index)
	return result
