class_name BossInfo
extends RefCounted
## Qué PNJ son jefes, para la barra de jefe (UI-18, docs/fuerte.md secciones 2 y 4.2).
## [br][br]
## El ENTITY_SPAWN de un PNJ lleva su [code]npc_def_id[/code]: el índice (1..n, por orden alfabético del
## id) de su [code]NpcDefinition[/code] en [code]data/npcs/*.tres[/code] (el catálogo que llega con el
## paquete de PNJ, F4). Aquí se mira esa carpeta sin depender de la clase del catálogo: se ordenan los
## archivos por nombre (el id de cada definición es el archivo sin extensión), se carga el de la
## posición [code]npc_def_id[/code] y se lee su propiedad [code]is_boss[/code]. Sin la carpeta (hasta
## que lleguen los PNJ) no hay jefes.
## [br][br]
## Se puede sustituir la consulta con [member resolver] (pruebas, o quien tenga el catálogo a mano).
## Solo cliente.

## Carpeta de las definiciones de PNJ.
const NPC_DATA_DIR: String = "res://data/npcs"

## Si es válido, se usa en lugar de leer la carpeta: recibe el id de definición y devuelve un
## diccionario [code]{"is_boss": bool, "name": String}[/code] (o vacío si no existe).
static var resolver: Callable = Callable()

static var _directory_for_cache: String = ""
static var _cache: Dictionary[int, Dictionary] = {}
static var _ids: PackedStringArray = PackedStringArray()


## true si la definición de PNJ [param npc_def_id] es un jefe.
static func is_boss(npc_def_id: int) -> bool:
	return bool(lookup(npc_def_id).get("is_boss", false))


## Datos de la definición: [code]{"is_boss": bool, "name": String}[/code]; vacío si el id es 0 o no hay
## definición con ese número.
static func lookup(npc_def_id: int) -> Dictionary:
	if npc_def_id <= 0:
		return {}
	if resolver.is_valid():
		var answer: Variant = resolver.call(npc_def_id)
		return answer if typeof(answer) == TYPE_DICTIONARY else {}
	return _from_directory(NPC_DATA_DIR, npc_def_id)


## Ids de las definiciones (archivos [code].tres[/code] sin extensión) de [param file_names] en el
## orden del catálogo: alfabético. El primero es el número 1.
static func ids_in_order(file_names: PackedStringArray) -> PackedStringArray:
	var ids := PackedStringArray()
	for file_name: String in file_names:
		var clean: String = file_name.trim_suffix(".remap")
		if clean.ends_with(".tres"):
			ids.append(clean.get_basename())
	ids.sort()
	return ids


## Olvida lo leído de la carpeta (para que una prueba o una recarga vuelva a mirar).
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
