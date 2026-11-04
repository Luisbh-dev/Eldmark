class_name BossInfo
extends RefCounted
## Which NPCs are bosses, for the boss bar (UI-18, docs/fuerte.md sections 2 and 4.2).
## [br][br]
## An NPC's ENTITY_SPAWN carries its [code]npc_def_id[/code]: the index (1..n, in alphabetical order of the
## id) of its [code]NpcDefinition[/code] in [code]data/npcs/*.tres[/code] (the catalog that arrives with the
## NPC package, F4). Here that folder is inspected without depending on the catalog class: the files are
## sorted by name (each definition's id is the file without extension), the one at position
## [code]npc_def_id[/code] is loaded and its [code]is_boss[/code] property is read. Without the folder
## (until the NPCs arrive) there are no bosses.
## [br][br]
## The lookup can be replaced with [member resolver] (tests, or whoever has the catalog at hand).
## Client only.

## Folder of the NPC definitions.
const NPC_DATA_DIR: String = "res://data/npcs"

## If valid, it is used instead of reading the folder: it receives the definition id and returns a
## dictionary [code]{"is_boss": bool, "name": String}[/code] (or empty if it does not exist).
static var resolver: Callable = Callable()

static var _directory_for_cache: String = ""
static var _cache: Dictionary[int, Dictionary] = {}
static var _ids: PackedStringArray = PackedStringArray()


## true if NPC definition [param npc_def_id] is a boss.
static func is_boss(npc_def_id: int) -> bool:
	return bool(lookup(npc_def_id).get("is_boss", false))


## Data of the definition: [code]{"is_boss": bool, "name": String}[/code]; empty if the id is 0 or there is
## no definition with that number.
static func lookup(npc_def_id: int) -> Dictionary:
	if npc_def_id <= 0:
		return {}
	if resolver.is_valid():
		var answer: Variant = resolver.call(npc_def_id)
		return answer if typeof(answer) == TYPE_DICTIONARY else {}
	return _from_directory(NPC_DATA_DIR, npc_def_id)


## Ids of the definitions ([code].tres[/code] files without extension) of [param file_names] in catalog
## order: alphabetical. The first is number 1.
static func ids_in_order(file_names: PackedStringArray) -> PackedStringArray:
	var ids := PackedStringArray()
	for file_name: String in file_names:
		var clean: String = file_name.trim_suffix(".remap")
		if clean.ends_with(".tres"):
			ids.append(clean.get_basename())
	ids.sort()
	return ids


## Forgets what was read from the folder (so that a test or a reload looks again).
static func clear_cache() -> void:
	_cache.clear()
	_ids = PackedStringArray()
	_directory_for_cache = ""


static func _from_directory(directory: String, npc_def_id: int) -> Dictionary:
	if _directory_for_cache != directory:
		clear_cache()
		_directory_for_cache = directory
		_ids = ids_in_order(DirAccess.get_files_at(directory)) if DirAccess.dir_exists_absolute(directory) \
				else PackedStringArray()
	if _cache.has(npc_def_id):
		return _cache[npc_def_id]
	var found: Dictionary = {}
	if npc_def_id >= 1 and npc_def_id <= _ids.size():
		var path: String = "%s/%s.tres" % [directory, _ids[npc_def_id - 1]]
		var definition: Resource = load(path) as Resource if ResourceLoader.exists(path) else null
		if definition != null:
			found = {"is_boss": bool(definition.get(&"is_boss")), "name": _ids[npc_def_id - 1]}
	_cache[npc_def_id] = found
	return found
