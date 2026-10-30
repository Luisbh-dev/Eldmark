class_name NpcCatalog
extends RefCounted
## Catálogo de PNJ (docs/fuerte.md, sección 4.2): lee las [NpcDefinition] de [code]data/npcs/[/code] una sola vez
## (carga perezosa) y les da un número del 1 al n por orden alfabético del nombre del archivo (el id): el
## [code]npc_def_id[/code] que viaja en el ENTITY_SPAWN de un PNJ. El cliente lo resuelve con el mismo orden
## ([code]BossInfo[/code] ordena los nombres de la carpeta), así que añadir un archivo nuevo cambia los
## números de los que le siguen en el alfabeto: nada puede depender de un número fijo.
## [br][br]
## El 0 es «sin definición». Un archivo cuyo [member NpcDefinition.id] no es su nombre, un arma que no existe
## en el catálogo de combate o una sustitución de guarnición desconocida son errores
## ([method get_errors]), que el catálogo anota una vez en el registro.

## Carpeta de las definiciones.
const DATA_DIR: String = "res://data/npcs"

# Definiciones cargadas por orden (el índice 0 es la número 1), id -> número y errores; vacío hasta el primer uso.
static var _loaded: bool = false
static var _definitions: Array[NpcDefinition] = []
static var _numbers: Dictionary[StringName, int] = {}
static var _errors: PackedStringArray = PackedStringArray()


## Cuántas definiciones hay.
static func count() -> int:
	_ensure_loaded()
	return _definitions.size()


## Ids de las definiciones en el orden del catálogo: el primero es el número 1.
static func ids() -> Array[StringName]:
	_ensure_loaded()
	var result: Array[StringName] = []
	for definition: NpcDefinition in _definitions:
		result.append(definition.id)
	return result


## La definición [param id] (el nombre del archivo sin extensión), o null si no existe.
static func get_definition(id: StringName) -> NpcDefinition:
	_ensure_loaded()
	var number: int = _numbers.get(id, 0)
	return _definitions[number - 1] if number > 0 else null


## La definición número [param number] (1..n), o null.
static func get_by_number(number: int) -> NpcDefinition:
	_ensure_loaded()
	return _definitions[number - 1] if number >= 1 and number <= _definitions.size() else null


## Número (1..n) de la definición [param id]; 0 si no existe.
static func number_of(id: StringName) -> int:
	_ensure_loaded()
	return _numbers.get(id, 0)


## Errores encontrados al cargar la carpeta (vacío si todo está bien).
static func get_errors() -> PackedStringArray:
	_ensure_loaded()
	return _errors


## Descarta lo cargado; la siguiente consulta lee la carpeta de nuevo.
static func reload() -> void:
	_loaded = false
	_definitions = []
	_numbers = {}
	_errors = PackedStringArray()


## Nombres de archivo ([param file_names] de una carpeta) sin extensión, ordenados: el orden del catálogo.
## Es el mismo cálculo que hace [code]BossInfo[/code] en el cliente.
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
			# Se deja un hueco con una definición vacía para que los números sigan al orden alfabético.
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
