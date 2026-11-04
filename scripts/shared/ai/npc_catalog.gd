class_name NpcCatalog
extends RefCounted
## NPC catalog (docs/fortress.md, section 4.2): reads the [NpcDefinition] files from [code]data/npcs/[/code] only once
## (lazy loading) and gives them a number from 1 to n in alphabetical order of the file name (the id): the
## [code]npc_def_id[/code] that travels in the ENTITY_SPAWN of an NPC. The client resolves it with the same order
## ([code]BossInfo[/code] sorts the folder's names), so adding a new file changes the
## numbers of those that follow it alphabetically: nothing may depend on a fixed number.
## [br][br]
## 0 means "no definition". A file whose [member NpcDefinition.id] is not its name, a weapon that does not exist
## in the combat catalog or an unknown garrison substitution are errors
## ([method get_errors]), which the catalog logs once.

## Folder of the definitions.
const DATA_DIR: String = "res://data/npcs"

# Definitions loaded in order (index 0 is number 1), id -> number and errors; empty until first use.
static var _loaded: bool = false
static var _definitions: Array[NpcDefinition] = []
static var _numbers: Dictionary[StringName, int] = {}
static var _errors: PackedStringArray = PackedStringArray()


## How many definitions there are.
static func count() -> int:
	_ensure_loaded()
	return _definitions.size()


## Ids of the definitions in catalog order: the first is number 1.
static func ids() -> Array[StringName]:
	_ensure_loaded()
	var result: Array[StringName] = []
	for definition: NpcDefinition in _definitions:
		result.append(definition.id)
	return result


## Definition [param id] (the file name without extension), or null if it does not exist.
static func get_definition(id: StringName) -> NpcDefinition:
	_ensure_loaded()
	var number: int = _numbers.get(id, 0)
	return _definitions[number - 1] if number > 0 else null


## Definition number [param number] (1..n), or null.
static func get_by_number(number: int) -> NpcDefinition:
	_ensure_loaded()
	return _definitions[number - 1] if number >= 1 and number <= _definitions.size() else null


## Number (1..n) of definition [param id]; 0 if it does not exist.
static func number_of(id: StringName) -> int:
	_ensure_loaded()
	return _numbers.get(id, 0)


## Errors found while loading the folder (empty if all is well).
static func get_errors() -> PackedStringArray:
	_ensure_loaded()
	return _errors


## Discards what was loaded; the next query reads the folder again.
static func reload() -> void:
	_loaded = false
	_definitions = []
	_numbers = {}
	_errors = PackedStringArray()


## File names ([param file_names] of a folder) without extension, sorted: the catalog order.
## It is the same computation that [code]BossInfo[/code] does on the client.
static func ids_in_order(file_names: PackedStringArray) -> PackedStringArray:
	var result := PackedStringArray()
	for file_name: String in file_names:
		var clean: String = file_name.trim_suffix(".remap")
		if clean.ends_with(".tres"):
			result.append(clean.get_basename())
	result.sort()
	return result


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_definitions = []
	_numbers = {}
	_errors = PackedStringArray()
	if not DirAccess.dir_exists_absolute(DATA_DIR):
		return
	for file_id: String in ids_in_order(DirAccess.get_files_at(DATA_DIR)):
		var path: String = "%s/%s.tres" % [DATA_DIR, file_id]
		var definition: NpcDefinition = ResourceLoader.load(path) as NpcDefinition
		if definition == null:
			_errors.append("%s no es una NpcDefinition" % path)
			# A gap is left with an empty definition so that the numbers follow alphabetical order.
			definition = NpcDefinition.new()
			definition.id = StringName(file_id)
		elif String(definition.id) != file_id:
			_errors.append("%s: el id '%s' no es el nombre del archivo" % [path, definition.id])
		_definitions.append(definition)
		_numbers[StringName(file_id)] = _definitions.size()
	for definition: NpcDefinition in _definitions:
		_validate(definition)
	for message: String in _errors:
		push_error("[Eldmark] Catálogo de PNJ: %s" % message)


static func _validate(definition: NpcDefinition) -> void:
	if CombatCatalog.weapon_id(definition.weapon_id) == 0:
		_errors.append("%s: el arma '%s' no está en el catálogo de combate" % [definition.id, definition.weapon_id])
	if definition.garrison_id != &"" and not _numbers.has(definition.garrison_id):
		_errors.append("%s: la guarnición '%s' no existe" % [definition.id, definition.garrison_id])
	if definition.reinforcement_id != &"" and not _numbers.has(definition.reinforcement_id):
		_errors.append("%s: los refuerzos '%s' no existen" % [definition.id, definition.reinforcement_id])
	if definition.xp_reward < 0 or definition.gold_reward < 0:
		_errors.append("%s: recompensa negativa (XP %d, oro %d)" % [definition.id, definition.xp_reward,
				definition.gold_reward])
