class_name AppearanceCatalog
extends Resource
## Catálogo de la apariencia (docs/progresion.md §7.2, ART-19), en
## [code]data/characters/appearance_catalog.tres[/code]: los pueblos ([RaceDefinition]), las piezas
## ([AppearancePart]) y los colores ([AppearanceColor]) que indexan los 8 B de [CharacterAppearance].
## [br][br]
## Todas las listas son [b]solo de añadir[/b]: [code]data/characters/appearance_ids.txt[/code] congela el
## orden («categoría índice id» por línea) y la prueba exige que el catálogo empiece por esa lista. Nada
## se reordena ni se borra (una pieza se retira quitándola de las razas), así los 8 B guardados en la base
## de datos siguen valiendo tras cualquier parche. En la fase 5 solo lista piezas que existen en el repo
## (§16). Lo exporta [ProgressionRulesExport] (secciones [code]races[/code] y [code]appearance[/code]) para
## que la plataforma aplique la misma regla al crear el personaje. Compartido: sin reloj ni azar.

## Ruta del catálogo.
const PATH: String = "res://data/characters/appearance_catalog.tres"
## Orden congelado de las listas.
const IDS_PATH: String = "res://data/characters/appearance_ids.txt"
## Listas de piezas, en el orden de los 8 B.
const PART_CATEGORIES: Array[StringName] = [&"bodies", &"heads", &"hairs", &"beards", &"marks"]
## Listas de colores, en el orden de los 8 B.
const COLOR_CATEGORIES: Array[StringName] = [&"skin_tones", &"hair_colors", &"eye_colors"]
## Todas las listas, en el orden de [code]appearance_ids.txt[/code].
const CATEGORIES: Array[StringName] = [&"races", &"bodies", &"heads", &"hairs", &"beards", &"marks",
		&"skin_tones", &"hair_colors", &"eye_colors"]
## Tamaño máximo de cada lista para que su índice quepa en los 8 B: el byte 0 y el pelo y la barba van
## con +1; los ojos y las marcas comparten el byte 7 (4 bits cada uno, las marcas con +1).
const MAX_SIZES: Dictionary[StringName, int] = {
	&"races": 255, &"bodies": 256, &"heads": 256, &"hairs": 255, &"beards": 255, &"marks": 15,
	&"skin_tones": 256, &"hair_colors": 256, &"eye_colors": 16,
}
## Formato de los ids.
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


## El catálogo de [constant PATH], cargado una vez. Si no se puede cargar, registra el error y devuelve
## uno vacío (ninguna apariencia vale).
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


## Índice (desde 0) del pueblo [param race_id] en [member races]; −1 si no existe.
func race_index(race_id: StringName) -> int:
	for i: int in range(races.size()):
		if races[i] != null and races[i].id == race_id:
			return i
	return -1


## El pueblo de [param realm_id] (id de [RealmCatalog]) con el índice más bajo, o null. En la fase 5 hay
## uno por reino.
func race_for_realm(realm_id: StringName) -> RaceDefinition:
	for race: RaceDefinition in races:
		if race != null and race.realm == realm_id:
			return race
	return null


## La lista [param category] (una de [constant CATEGORIES]); vacía si no existe.
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


## Los ids de la lista [param category], en orden (un hueco nulo da una cadena vacía).
func ids_of(category: StringName) -> PackedStringArray:
	var result := PackedStringArray()
	for entry: Resource in entries(category):
		result.append(String(entry.get(&"id")) if entry != null else "")
	return result


## Errores de los datos (vacío si el catálogo vale): ids con formato y sin repetir en cada lista, tamaños
## que caben en los 8 B, al menos un cuerpo, una cabeza y un color de cada tipo, piezas con cuerpos que
## existen y, por pueblo, un reino jugable, índices que existen y sin repetir, listas sin las que no hay
## apariencia válida, [code]allows_no_*[/code] cuando no hay pelo o barba compatibles y ninguna
## estadística.
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


## Índices de [param allowed] que existen en [param parts] y encajan con [param body].
static func fitting_indices(allowed: PackedInt32Array, parts: Array[AppearancePart], body: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for index: int in allowed:
		if index >= 0 and index < parts.size() and parts[index] != null and parts[index].fits_body(body):
			result.append(index)
	return result
