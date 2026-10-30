class_name ItemDatabase
extends RefCounted
## Las definiciones de objetos (docs/progresion.md §2.2, PRG-02): lee [code]data/items/[/code] (con
## subcarpetas) una vez, con carga perezosa como [CombatCatalog], tolera los [code].tres.remap[/code] de un
## proyecto exportado y registra sus errores una sola vez ([method shared]).
## [br][br]
## [b]Net id.[/b] 1..n por orden alfabético de [member ItemDefinition.id]; 0 = ninguno. Cambia al añadir
## objetos: solo viaja hacia el dueño y nunca se guarda (la base de datos guarda el [code]id[/code]).
## [b]Huella.[/b] [method wire_hash], u32 del SHA-256 de la lista ordenada
## [code](id, net_id, category, equip_slot, max_stack, has_durability)[/code]; entra en el
## [code]sim_hash[/code] (§12) para que un cliente con otro catálogo no interprete mal los net ids.
## [b]Búsquedas.[/b] [method for_ref] da el objeto de un arma o un consumible de [CombatCatalog] (en la fase 5
## hay uno por cada uno; dos son un error) y [method consumable_definition], el del consumible de cada botón.
## [br][br]
## [b]Coherencia[/b] ([member errors], §2.1): ids con formato y sin repetir, nombre no vacío, enumerados en
## rango, pila de 1 a 999 (1 si es equipable o lleva durabilidad), nivel requerido dentro de la curva, valor
## no negativo, [member ItemDefinition.camp_refill] que cabe en una pila; WEAPON ⇒ ranura WEAPON y
## [code]ref_id[/code] de un arma del catálogo de combate; ARMOR ⇒ ranura de HEAD a FEET; CONSUMABLE ⇒ sin
## ranura y [code]ref_id[/code] de un consumible; el resto, sin ranura ni [code]ref_id[/code]; icono bajo
## [code]res://assets/icons/items/[/code] y escenas solo en las armaduras. Lo exporta
## [ProgressionRulesExport] (sección [code]items[/code]). Compartido: sin reloj ni azar.

## Carpeta de los datos.
const DATA_DIR: String = "res://data/items"
## Tope de definiciones: el net id viaja en u16.
const MAX_DEFINITIONS: int = 0xFFFF
## Prefijo de los iconos.
const ICON_PREFIX: String = "res://assets/icons/items/"
## Prefijo de las escenas de las armaduras.
const VISUAL_PREFIX: String = "res://assets/"

## Problemas de los datos (vacío si todo vale).
var errors: PackedStringArray = PackedStringArray()

# Definiciones por net id − 1 (orden alfabético).
var _definitions: Array[ItemDefinition] = []
var _net_ids: Dictionary[StringName, int] = {}
# "categoría/ref_id" → definición.
var _by_ref: Dictionary[String, ItemDefinition] = {}
# Definición del consumible de cada botón (índice de CombatCatalog.consumable_ids()).
var _consumables: Array[ItemDefinition] = []
var _wire_hash: int = 0

static var _shared: ItemDatabase = null


## La base de [constant DATA_DIR], cargada la primera vez que se pide. Sus errores se registran con
## [code]push_error[/code] una sola vez.
static func shared() -> ItemDatabase:
	if _shared == null:
		_shared = build_from_directory(DATA_DIR)
		for message: String in _shared.errors:
			push_error("[Eldmark] Base de objetos: %s" % message)
	return _shared


## Lee los [code].tres[/code] de [param dir] y de sus subcarpetas y construye la base con
## [method build_from_definitions] y el catálogo de combate compartido. Un recurso que no se carga o que
## no es una [ItemDefinition] cuenta como error. No registra errores en el motor.
static func build_from_directory(dir: String) -> ItemDatabase:
	var load_errors := PackedStringArray()
	var definitions: Array[ItemDefinition] = []
	for path: String in _resource_paths(dir):
		var resource: Resource = ResourceLoader.load(path)
		if resource == null:
			load_errors.append("no se pudo cargar %s" % path)
		elif not (resource is ItemDefinition):
			load_errors.append("%s no es una ItemDefinition" % path)
		else:
			definitions.append(resource as ItemDefinition)
	var db: ItemDatabase = build_from_definitions(definitions)
	if not load_errors.is_empty():
		load_errors.append_array(db.errors)
		db.errors = load_errors
	return db


## Construye la base con [param definitions] (en cualquier orden), comprobando los [code]ref_id[/code] con
## [param combat] (null = [method CombatCatalog.tables]). Un id repetido se avisa y se queda el que llega
## antes en [param definitions]. No registra errores en el motor: quedan en [member errors].
static func build_from_definitions(definitions: Array[ItemDefinition],
		combat: CombatTables = null) -> ItemDatabase:
	if combat == null:
		combat = CombatCatalog.tables()
	var db := ItemDatabase.new()
	# Orden alfabético por id y, entre ids iguales, el de llegada (sort_custom no es estable).
	var order: Array[int] = []
	for i: int in range(definitions.size()):
		if definitions[i] != null:
			order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var id_a: String = String(definitions[a].id)
		var id_b: String = String(definitions[b].id)
		return id_a < id_b or (id_a == id_b and a < b))
	var sorted: Array[ItemDefinition] = []
	for i: int in order:
		sorted.append(definitions[i])
	var consumable_refs: Dictionary[StringName, int] = {}
	for index: int in range(combat.consumable_ids.size()):
		var ability: AbilityTicks = combat.ability(combat.consumable_ids[index])
		if ability != null:
			consumable_refs[ability.name] = index
	var id_regex := RegEx.new()
	id_regex.compile(ItemDefinition.ID_PATTERN)
	for definition: ItemDefinition in sorted:
		if db._net_ids.has(definition.id):
			db.errors.append("id de objeto repetido: %s" % definition.id)
			continue
		if id_regex.search(String(definition.id)) == null:
			db.errors.append("el id '%s' no tiene el formato %s" % [definition.id, ItemDefinition.ID_PATTERN])
		db._check_definition(definition, combat, consumable_refs)
		db._definitions.append(definition)
		db._net_ids[definition.id] = db._definitions.size()
		db._index_ref(definition)
	if db._definitions.size() > MAX_DEFINITIONS:
		db.errors.append("hay %d objetos y caben %d" % [db._definitions.size(), MAX_DEFINITIONS])
	db._consumables.resize(combat.consumable_ids.size())
	for ref: StringName in consumable_refs:
		db._consumables[consumable_refs[ref]] = db.for_ref(ItemDefinition.Category.CONSUMABLE, ref)
	db._wire_hash = db._compute_wire_hash()
	return db


## La definición con id [param id], o null.
func get_definition(id: StringName) -> ItemDefinition:
	var net_id: int = _net_ids.get(id, 0)
	return _definitions[net_id - 1] if net_id > 0 else null


## Net id de [param id] (1..n por orden alfabético), o 0 si no existe.
func net_id_of(id: StringName) -> int:
	return _net_ids.get(id, 0)


## La definición con net id [param net_id], o null (0 o fuera de rango).
func definition_by_net_id(net_id: int) -> ItemDefinition:
	if net_id < 1 or net_id > _definitions.size():
		return null
	return _definitions[net_id - 1]


## El objeto del arma ([code]Category.WEAPON[/code]) o del consumible ([code]Category.CONSUMABLE[/code])
## con id [param ref_id] en [CombatCatalog], o null.
func for_ref(category: int, ref_id: StringName) -> ItemDefinition:
	if ref_id == &"":
		return null
	return _by_ref.get(_ref_key(category, ref_id), null)


## El objeto del consumible [param index] de [method CombatCatalog.consumable_ids] (0 vida, R; 1
## resistencia, T), o null.
func consumable_definition(index: int) -> ItemDefinition:
	if index < 0 or index >= _consumables.size():
		return null
	return _consumables[index]


## Los ids de todas las definiciones, en orden de net id (alfabético).
func all_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for definition: ItemDefinition in _definitions:
		ids.append(definition.id)
	return ids


## Huella u32 de lo que da sentido a los net ids (§2.2): entra en el [code]sim_hash[/code].
func wire_hash() -> int:
	return _wire_hash


# --- Construcción ------------------------------------------------------------------------------

# Rutas de los recursos de [param dir] y sus subcarpetas, ordenadas (sin el .remap de un proyecto
# exportado, y una sola vez aunque estén los dos).
static func _resource_paths(dir: String) -> PackedStringArray:
	var paths := PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir):
		return paths
	for file_name: String in DirAccess.get_files_at(dir):
		var plain: String = file_name.trim_suffix(".remap")
		var path: String = dir.path_join(plain)
		if (plain.ends_with(".tres") or plain.ends_with(".res")) and not paths.has(path):
			paths.append(path)
	for sub_dir: String in DirAccess.get_directories_at(dir):
		paths.append_array(_resource_paths(dir.path_join(sub_dir)))
	paths.sort()
	return paths


# Las reglas de §2.1 de una definición; los problemas van a errors.
func _check_definition(definition: ItemDefinition, combat: CombatTables,
		consumable_refs: Dictionary[StringName, int]) -> void:
	var label: String = "objeto %s" % definition.id
	if definition.display_name.strip_edges().is_empty():
		errors.append("%s: sin nombre" % label)
	if not ItemDefinition.Category.values().has(definition.category):
		errors.append("%s: categoría fuera de rango (%d)" % [label, definition.category])
	if not ItemDefinition.EquipSlot.values().has(definition.equip_slot):
		errors.append("%s: ranura fuera de rango (%d)" % [label, definition.equip_slot])
	if not ItemDefinition.BindRule.values().has(definition.bind_rule):
		errors.append("%s: regla de ligado fuera de rango (%d)" % [label, definition.bind_rule])
	if definition.max_stack < 1 or definition.max_stack > ItemDefinition.MAX_STACK:
		errors.append("%s: max_stack fuera de rango (1-%d): %d" % [label, ItemDefinition.MAX_STACK,
				definition.max_stack])
	if (definition.is_equipable() or definition.has_durability) and definition.max_stack != 1:
		errors.append("%s: un equipable o un objeto con durabilidad no se apila (max_stack 1)" % label)
	var level_cap: int = LevelCurve.shared().level_cap
	if definition.required_level < 1 or definition.required_level > level_cap:
		errors.append("%s: required_level fuera de rango (1-%d): %d" % [label, level_cap,
				definition.required_level])
	if definition.base_value < 0:
		errors.append("%s: base_value negativo" % label)
	if definition.camp_refill < 0 or definition.camp_refill > definition.max_stack:
		errors.append("%s: camp_refill debe caber en una pila (0-%d): %d" % [label, definition.max_stack,
				definition.camp_refill])
	match definition.category:
		ItemDefinition.Category.WEAPON:
			if definition.equip_slot != ItemDefinition.EquipSlot.WEAPON:
				errors.append("%s: un arma va en la ranura WEAPON" % label)
			if not combat.weapon_ids.has(definition.ref_id):
				errors.append("%s: el arma '%s' no está en el catálogo de combate" % [label, definition.ref_id])
		ItemDefinition.Category.ARMOR:
			if definition.equip_slot < ItemDefinition.EquipSlot.HEAD \
					or definition.equip_slot > ItemDefinition.EquipSlot.FEET:
				errors.append("%s: una armadura va en una ranura de HEAD a FEET" % label)
		ItemDefinition.Category.CONSUMABLE:
			if definition.equip_slot != ItemDefinition.EquipSlot.NONE:
				errors.append("%s: un consumible no se equipa" % label)
			if not consumable_refs.has(definition.ref_id):
				errors.append("%s: '%s' no es un consumible del catálogo de combate" % [label,
						definition.ref_id])
		_:
			if definition.equip_slot != ItemDefinition.EquipSlot.NONE:
				errors.append("%s: solo las armas y las armaduras se equipan" % label)
			if definition.ref_id != &"":
				errors.append("%s: solo las armas, las armaduras y los consumibles llevan ref_id" % label)
	if not definition.icon_path.is_empty() and not definition.icon_path.begins_with(ICON_PREFIX):
		errors.append("%s: el icono va en %s" % [label, ICON_PREFIX])
	if not definition.visual_paths.is_empty() and definition.category != ItemDefinition.Category.ARMOR:
		errors.append("%s: solo las armaduras llevan escenas (visual_paths)" % label)
	for path: String in definition.visual_paths:
		if not path.begins_with(VISUAL_PREFIX):
			errors.append("%s: la escena '%s' no está en %s" % [label, path, VISUAL_PREFIX])


# Anota el objeto de su arma o consumible; dos para el mismo son un error (en la fase 5 hay uno).
func _index_ref(definition: ItemDefinition) -> void:
	if definition.ref_id == &"" or (definition.category != ItemDefinition.Category.WEAPON
			and definition.category != ItemDefinition.Category.CONSUMABLE):
		return
	var key: String = _ref_key(definition.category, definition.ref_id)
	if _by_ref.has(key):
		errors.append("dos objetos para '%s': %s y %s" % [definition.ref_id, _by_ref[key].id, definition.id])
		return
	_by_ref[key] = definition


static func _ref_key(category: int, ref_id: StringName) -> String:
	return "%d/%s" % [category, ref_id]


# SHA-256 de la lista de §2.2 en orden de net id: los 4 primeros bytes como u32.
func _compute_wire_hash() -> int:
	var parts: Array = []
	for i: int in range(_definitions.size()):
		var definition: ItemDefinition = _definitions[i]
		parts.append([String(definition.id), i + 1, int(definition.category), int(definition.equip_slot),
				definition.max_stack, definition.has_durability])
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(parts))
	return context.finish().decode_u32(0)
