class_name CombatCatalog
extends RefCounted
## Catálogo de combate (docs/combate.md, sección 2; docs/habilidades.md, sección 2.2): lee los
## recursos de [code]data/combat/[/code] una sola vez (carga perezosa), asigna IDs estables,
## convierte las duraciones a ticks y hornea las curvas de la esquiva y de los avances.
## [br][br]
## [b]IDs.[/b] Ataques, armas, habilidades (y consumibles), efectos, proyectiles y plantillas tienen
## espacios de IDs separados: 1..n por orden alfabético de su [code]id[/code] y 0 = ninguno. Un
## [code]id[/code] repetido es un error. Efectos y plantillas caben en u8. Nadie escribe un ID a mano:
## se piden por nombre ([method attack_id], [method ability_id]...), porque los datos de otros paquetes
## (las armas [code]npc_*[/code] de los PNJ) desplazan los números.
## [br][br]
## [b]Ticks.[/b] Las duraciones de los [code].tres[/code] están en segundos y se convierten con
## [code]roundi(s * 60)[/code] ([method seconds_to_ticks]). Cada ventana es un intervalo
## [code][desde, hasta)[/code] de ticks contado desde el [code]action_tick[/code].
## [br][br]
## [b]Curvas.[/b] La de la esquiva y la del avance de una habilidad se hornean en una tabla de
## velocidades por tick (f32, como viajan las demás magnitudes de la simulación) normalizada para
## que la distancia total sea la del dato.
## [br][br]
## [b]Habilidades.[/b] Cada [AbilityTicks] sabe en qué arma y ranura está (o qué consumible es) y
## lleva un [AttackTicks] sintetizado con sus ventanas y sus campos de solo servidor
## ([member AbilityTicks.hit]).
## [br][br]
## [b]Huella.[/b] [method prediction_hash] resume todo lo que cambia lo que simulan cliente y
## servidor: todo campo marcado como predicho en docs/habilidades.md, sección 2.1 (fases, movimiento,
## costes, curvas horneadas, cancelaciones, bloqueo, habilidades, el id, el tipo y la escala de
## velocidad de los efectos, los proyectiles y los campos predichos de [CombatRules]); entra en
## [method NetProtocol.compute_sim_hash]. Daño, mitigación, críticos, controles, formas, pulsos, vida,
## derribado, interacción, muros, reaparición y plantillas no entran.

## Ticks de simulación por segundo en los que se expresan los datos.
const TICK_RATE: int = 60
## Carpeta de los datos de combate.
const DATA_DIR: String = "res://data/combat"
## Arma con la que aparece un personaje.
const DEFAULT_WEAPON: StringName = &"sword_shield"
## Prefijo de las armas de PNJ (una plantilla elegible no puede llevarlas).
const NPC_PREFIX: String = "npc_"
## Versión del formato de la huella (sube si cambia lo que entra en ella).
const _HASH_FORMAT: int = 2
const _MAX_STAMINA: int = 0xFFFF
const _MAX_BUFFER_TICKS: int = 15
const _MAX_CHARGE_TICKS: int = 255
const _MAX_DAMAGE_TYPE: int = 3
## IDs de 8 bits (efectos y plantillas).
const _MAX_U8_IDS: int = 255
## IDs de 16 bits (armas y proyectiles).
const _MAX_U16_IDS: int = 0xFFFF
## Máximo de habilidades por arma y de golpes del combo ligero.
const _MAX_ABILITIES: int = 3
const _MAX_LIGHT_COMBO: int = 3
## Máximo de proyectiles de un disparo.
const _MAX_PROJECTILE_COUNT: int = 5
## Velocidad máxima (m/s) de un proyectil: su velocidad viaja en s16 de cm/s.
const _MAX_PROJECTILE_SPEED: float = 327.67
## Dueño de una habilidad que no lleva ningún arma ni es un consumible.
const _NO_OWNER: Vector2i = Vector2i(0, -100)

# Tablas cargadas (null hasta el primer uso).
static var _tables: CombatTables = null
# Búfer de 4 bytes para redondear a f32 sin reservar memoria en cada llamada.
static var _f32_scratch: PackedByteArray = PackedByteArray([0, 0, 0, 0])


## Las tablas del catálogo de [constant DATA_DIR], cargadas la primera vez que se piden. Los
## problemas que encuentre se registran con [code]push_error[/code] una sola vez.
static func tables() -> CombatTables:
	if _tables == null:
		_tables = build_from_directory(DATA_DIR)
		for message: String in _tables.errors:
			push_error("[Eldmark] Catálogo de combate: %s" % message)
	return _tables


## Descarta las tablas cargadas; la siguiente consulta las lee de nuevo.
static func reload() -> void:
	_tables = null


## El ataque con ID [param id], o null.
static func attack(id: int) -> AttackTicks:
	return tables().attack(id)


## El arma con ID [param id], o null.
static func weapon(id: int) -> WeaponTicks:
	return tables().weapon(id)


## La habilidad (o el consumible) con ID [param id], o null.
static func ability(id: int) -> AbilityTicks:
	return tables().ability(id)


## El efecto de estado con ID [param id], o null.
static func status(id: int) -> StatusTicks:
	return tables().status(id)


## El proyectil con ID [param id], o null.
static func projectile(id: int) -> ProjectileTicks:
	return tables().projectile(id)


## La plantilla de equipo con ID [param id], o null.
static func template(id: int) -> EquipmentTemplate:
	return tables().template(id)


## Las reglas generales del combate.
static func rules() -> CombatRules:
	return tables().rules


## ID del ataque llamado [param name], o 0 si no existe.
static func attack_id(name: StringName) -> int:
	return tables().attack_ids.get(name, 0)


## ID del arma llamada [param name], o 0 si no existe.
static func weapon_id(name: StringName) -> int:
	return tables().weapon_ids.get(name, 0)


## ID de la habilidad (o del consumible) llamada [param name], o 0 si no existe.
static func ability_id(name: StringName) -> int:
	return tables().ability_ids.get(name, 0)


## ID del efecto de estado llamado [param name], o 0 si no existe.
static func status_id(name: StringName) -> int:
	return tables().status_ids.get(name, 0)


## ID del proyectil llamado [param name], o 0 si no existe.
static func projectile_id(name: StringName) -> int:
	return tables().projectile_ids.get(name, 0)


## ID de la plantilla llamada [param name], o 0 si no existe.
static func template_id(name: StringName) -> int:
	return tables().template_ids.get(name, 0)


## Número de plantillas (los IDs van de 1 a este número).
static func template_count() -> int:
	return tables().templates.size()


## IDs de las armas de la plantilla [param id] en orden de ranura (vacío si no existe).
static func template_weapons(id: int) -> PackedInt32Array:
	return tables().template_weapons(id)


## Cargas de la plantilla [param id] empaquetadas como [member CombatState.consumable_charges].
static func template_charges(id: int) -> int:
	return tables().template_charges_of(id)


## ID de la plantilla con la que aparece quien no ha elegido ([member CombatRules.default_template]).
static func default_template_id() -> int:
	return tables().default_template_id


## IDs de los dos consumibles en orden de botón (CONSUMABLE_1 y CONSUMABLE_2; 0 si no hay).
static func consumable_ids() -> PackedInt32Array:
	return tables().consumable_ids


## ID del arma con la que aparece un personaje ([constant DEFAULT_WEAPON]).
static func default_weapon_id() -> int:
	return weapon_id(DEFAULT_WEAPON)


## Huella (u32) de todo lo predicho. Entra en [method NetProtocol.compute_sim_hash].
static func prediction_hash() -> int:
	return tables().prediction_hash


## Convierte segundos a ticks de simulación con el redondeo fijo del catálogo.
static func seconds_to_ticks(seconds: float) -> int:
	return roundi(seconds * TICK_RATE)


## Lee todos los [code].tres[/code] de [param dir_path] (sin entrar en subcarpetas) y construye las
## tablas. Un recurso que no se puede cargar cuenta como error.
static func build_from_directory(dir_path: String) -> CombatTables:
	var load_errors := PackedStringArray()
	var resources: Array[Resource] = []
	var files: PackedStringArray = DirAccess.get_files_at(dir_path)
	files.sort()
	var seen: Dictionary[String, bool] = {}
	for file_name: String in files:
		# En proyectos exportados los recursos aparecen como .tres.remap.
		var plain: String = file_name.trim_suffix(".remap")
		if not (plain.ends_with(".tres") or plain.ends_with(".res")) or seen.has(plain):
			continue
		seen[plain] = true
		var path: String = dir_path.path_join(plain)
		var resource: Resource = ResourceLoader.load(path)
		if resource == null:
			load_errors.append("no se pudo cargar %s" % path)
		else:
			resources.append(resource)
	var result: CombatTables = build_from_resources(resources)
	if not load_errors.is_empty():
		var all_errors := PackedStringArray(load_errors)
		all_errors.append_array(result.errors)
		result.errors = all_errors
	return result


## Construye las tablas a partir de recursos ya cargados: las [CombatRules], las
## [WeaponDefinition], los [AttackDefinition], las [AbilityDefinition], los
## [StatusEffectDefinition], los [ProjectileDefinition] y las [EquipmentTemplate] (sueltos o
## enlazados desde otro recurso; el mismo objeto nunca cuenta dos veces). Los demás recursos se
## ignoran. No registra errores en el motor: los deja en [member CombatTables.errors].
static func build_from_resources(resources: Array[Resource]) -> CombatTables:
	var tables_out := CombatTables.new()
	var errors := PackedStringArray()
	var rules_list: Array[Resource] = []
	var attack_defs: Array[Resource] = []
	var weapon_defs: Array[Resource] = []
	var ability_defs: Array[Resource] = []
	var status_defs: Array[Resource] = []
	var projectile_defs: Array[Resource] = []
	var template_defs: Array[Resource] = []
	for resource: Resource in resources:
		if resource is CombatRules:
			_add_unique(rules_list, resource)
		elif resource is AttackDefinition:
			_add_unique(attack_defs, resource)
		elif resource is WeaponDefinition:
			_add_unique(weapon_defs, resource)
		elif resource is AbilityDefinition:
			_add_unique(ability_defs, resource)
		elif resource is StatusEffectDefinition:
			_add_unique(status_defs, resource)
		elif resource is ProjectileDefinition:
			_add_unique(projectile_defs, resource)
		elif resource is EquipmentTemplate:
			_add_unique(template_defs, resource)

	# Reglas.
	if rules_list.is_empty():
		errors.append("falta un recurso CombatRules en %s" % DATA_DIR)
		tables_out.rules = CombatRules.new()
	else:
		if rules_list.size() > 1:
			errors.append("hay %d recursos CombatRules y solo puede haber uno" % rules_list.size())
		tables_out.rules = rules_list[0] as CombatRules
	var rules_value: CombatRules = tables_out.rules
	tables_out.regen_delay_ticks = seconds_to_ticks(rules_value.stamina_regen_delay_s)
	tables_out.swap_ticks = seconds_to_ticks(rules_value.swap_s)
	tables_out.revive_ticks = seconds_to_ticks(rules_value.revive_s)
	tables_out.execute_ticks = seconds_to_ticks(rules_value.execute_s)
	tables_out.consumable_cooldown_ticks = seconds_to_ticks(rules_value.consumable_cooldown_s)
	tables_out.downed_ticks = seconds_to_ticks(rules_value.downed_s)
	_validate_rules(rules_value, errors)

	# Recursos enlazados: plantillas -> armas -> ataques y habilidades -> efectos y proyectiles.
	for consumable: AbilityDefinition in rules_value.consumables:
		if consumable != null:
			_add_unique(ability_defs, consumable)
	if rules_value.default_template != null:
		_add_unique(template_defs, rules_value.default_template)
	for template_res: Resource in template_defs:
		for weapon_def: WeaponDefinition in (template_res as EquipmentTemplate).weapons:
			if weapon_def != null:
				_add_unique(weapon_defs, weapon_def)
	for weapon_res: Resource in weapon_defs:
		var weapon_def: WeaponDefinition = weapon_res as WeaponDefinition
		for attack_def: AttackDefinition in weapon_def.light_combo:
			if attack_def != null:
				_add_unique(attack_defs, attack_def)
		if weapon_def.heavy_attack != null:
			_add_unique(attack_defs, weapon_def.heavy_attack)
		for ability_def: AbilityDefinition in weapon_def.abilities:
			if ability_def != null:
				_add_unique(ability_defs, ability_def)
	for ability_res: Resource in ability_defs:
		var ability_def: AbilityDefinition = ability_res as AbilityDefinition
		_add_if_set(projectile_defs, ability_def.projectile)
		_add_if_set(status_defs, ability_def.target_status)
		_add_if_set(status_defs, ability_def.self_status)
	for attack_res: Resource in attack_defs:
		var attack_def: AttackDefinition = attack_res as AttackDefinition
		_add_if_set(projectile_defs, attack_def.projectile)
		_add_if_set(status_defs, attack_def.on_hit_status)

	# IDs: 1..n por orden alfabético en cada espacio; un id repetido es un error y el repetido se
	# descarta.
	var named_statuses: Array[Resource] = _sorted_unique(status_defs, "efecto", "un efecto", errors)
	var named_projectiles: Array[Resource] = _sorted_unique(projectile_defs, "proyectil",
			"un proyectil", errors)
	var named_attacks: Array[Resource] = _sorted_unique(attack_defs, "ataque", "un ataque", errors)
	var named_abilities: Array[Resource] = _sorted_unique(ability_defs, "habilidad",
			"una habilidad", errors)
	var named_weapons: Array[Resource] = _sorted_unique(weapon_defs, "arma", "un arma", errors)
	var named_templates: Array[Resource] = _sorted_unique(template_defs, "plantilla",
			"una plantilla", errors)
	_check_count(named_statuses.size(), _MAX_U8_IDS, "efectos", errors)
	_check_count(named_templates.size(), _MAX_U8_IDS, "plantillas", errors)
	_check_count(named_attacks.size(), CombatSource.MAX_ID, "ataques", errors)
	_check_count(named_abilities.size(), CombatSource.MAX_ID, "habilidades", errors)
	_check_count(named_weapons.size(), _MAX_U16_IDS, "armas", errors)
	_check_count(named_projectiles.size(), _MAX_U16_IDS, "proyectiles", errors)
	var status_by_def: Dictionary[Resource, int] = _ids_by_def(named_statuses,
			tables_out.status_ids)
	var projectile_by_def: Dictionary[Resource, int] = _ids_by_def(named_projectiles,
			tables_out.projectile_ids)
	var attack_by_def: Dictionary[Resource, int] = _ids_by_def(named_attacks, tables_out.attack_ids)
	var ability_by_def: Dictionary[Resource, int] = _ids_by_def(named_abilities,
			tables_out.ability_ids)
	var weapon_by_def: Dictionary[Resource, int] = _ids_by_def(named_weapons, tables_out.weapon_ids)
	var _template_by_def: Dictionary[Resource, int] = _ids_by_def(named_templates,
			tables_out.template_ids)

	# Conversión a ticks.
	for i: int in named_statuses.size():
		tables_out.statuses.append(_convert_status(named_statuses[i] as StatusEffectDefinition,
				i + 1, errors))
	for i: int in named_projectiles.size():
		tables_out.projectiles.append(_convert_projectile(
				named_projectiles[i] as ProjectileDefinition, i + 1, errors))
	for i: int in named_attacks.size():
		tables_out.attacks.append(_convert_attack(named_attacks[i] as AttackDefinition, i + 1,
				status_by_def, projectile_by_def, errors))

	# Dueños de las habilidades: un arma y una ranura, o un consumible; nunca dos.
	var owners: Dictionary[Resource, Vector2i] = {}
	for weapon_index: int in named_weapons.size():
		var weapon_def: WeaponDefinition = named_weapons[weapon_index] as WeaponDefinition
		for slot: int in weapon_def.abilities.size():
			var ability_def: AbilityDefinition = weapon_def.abilities[slot]
			if ability_def == null or slot >= _MAX_ABILITIES:
				continue
			_claim_ability(owners, ability_def, Vector2i(weapon_index + 1, slot), errors)
	for index: int in rules_value.consumables.size():
		var consumable: AbilityDefinition = rules_value.consumables[index]
		if consumable == null:
			continue
		if ability_by_def.has(consumable) and index < CombatState.CONSUMABLE_SLOTS:
			tables_out.consumable_ids[index] = ability_by_def[consumable]
		_claim_ability(owners, consumable, Vector2i(0, -1 - index), errors)
	for i: int in named_abilities.size():
		var ability_def: AbilityDefinition = named_abilities[i] as AbilityDefinition
		# Sin dueño (suelta en la carpeta): ni ranura ni consumible.
		tables_out.abilities.append(_convert_ability(ability_def, i + 1,
				owners.get(ability_def, _NO_OWNER), tables_out, status_by_def,
				projectile_by_def, errors))

	for i: int in named_weapons.size():
		tables_out.weapons.append(_convert_weapon(named_weapons[i] as WeaponDefinition, i + 1,
				attack_by_def, ability_by_def, rules_value, errors))

	for i: int in named_templates.size():
		var template_def: EquipmentTemplate = named_templates[i] as EquipmentTemplate
		tables_out.templates.append(template_def)
		var weapons: PackedInt32Array = _convert_template(template_def, weapon_by_def, errors)
		tables_out.template_weapon_ids.append(weapons)
		tables_out.template_charges.append(_template_charges(template_def, errors))
	if rules_value.default_template != null:
		tables_out.default_template_id = tables_out.template_ids.get(
				rules_value.default_template.id, 0)

	tables_out.errors = errors
	tables_out.prediction_hash = _compute_hash(tables_out)
	return tables_out


# --- Reglas y validación ----------------------------------------------------------------------

static func _validate_rules(rules_value: CombatRules, errors: PackedStringArray) -> void:
	if rules_value.stamina_max < 1 or rules_value.stamina_max > _MAX_STAMINA:
		errors.append("stamina_max fuera de rango (1-%d): %d" % [
			_MAX_STAMINA, rules_value.stamina_max,
		])
	if rules_value.stamina_regen_per_tick < 0 or rules_value.exhausted_regen_per_tick < 0:
		errors.append("la regeneración de resistencia no puede ser negativa")
	if rules_value.stamina_regen_delay_s < 0.0:
		errors.append("stamina_regen_delay_s negativo")
	if rules_value.exhausted_exit_threshold < 0 \
			or rules_value.exhausted_exit_threshold >= rules_value.stamina_max:
		errors.append("exhausted_exit_threshold debe estar entre 0 y stamina_max")
	if rules_value.hold_to_heavy_ticks < 1 or rules_value.hold_to_heavy_ticks > 255:
		errors.append("hold_to_heavy_ticks fuera de rango (1-255)")
	if rules_value.input_buffer_ticks < 1 or rules_value.input_buffer_ticks > _MAX_BUFFER_TICKS:
		errors.append("input_buffer_ticks fuera de rango (1-%d)" % _MAX_BUFFER_TICKS)
	if rules_value.parry_window_ticks < 0 \
			or rules_value.parry_cooldown_ticks < rules_value.parry_window_ticks:
		errors.append("la ventana de parada no puede ser mayor que su enfriamiento")
	if rules_value.health_max < 1:
		errors.append("health_max debe ser positivo")
	if rules_value.structure_slash_multiplier < 0.0 or rules_value.structure_pierce_multiplier < 0.0 \
			or rules_value.structure_blunt_multiplier < 0.0 \
			or rules_value.structure_elemental_multiplier < 0.0:
		errors.append("los multiplicadores contra estructuras no pueden ser negativos")
	# Fase 4 (docs/habilidades.md, sección 2.1).
	if seconds_to_ticks(rules_value.swap_s) < 1:
		errors.append("swap_s debe durar al menos un tick")
	if seconds_to_ticks(rules_value.revive_s) < 1 or seconds_to_ticks(rules_value.execute_s) < 1:
		errors.append("revive_s y execute_s deben durar al menos un tick")
	if rules_value.swap_move_scale < 0.0 or rules_value.downed_move_scale < 0.0 \
			or rules_value.downed_turn_rate < 0.0:
		errors.append("movimiento o giro del cambio de arma o del derribado negativos")
	if rules_value.consumables.size() != 0 \
			and rules_value.consumables.size() != CombatState.CONSUMABLE_SLOTS:
		errors.append("consumables debe tener exactamente %d habilidades (tiene %d)" % [
			CombatState.CONSUMABLE_SLOTS, rules_value.consumables.size(),
		])
	for consumable: AbilityDefinition in rules_value.consumables:
		if consumable == null:
			errors.append("consumables tiene una habilidad vacía")
	if rules_value.consumable_cooldown_s < 0.0:
		errors.append("consumable_cooldown_s negativo")
	if rules_value.aim_pivot_height < 0.0 or rules_value.muzzle_height < 0.0 \
			or rules_value.aim_range_m <= 0.0 or rules_value.aim_converge_deg < 0.0 \
			or rules_value.aim_converge_deg > 90.0:
		errors.append("parámetros de puntería fuera de rango")
	if rules_value.downed_health < 1 or rules_value.revived_health < 1 \
			or rules_value.downed_s < 0.0:
		errors.append("vida o tiempo de derribado fuera de rango")
	if rules_value.interact_range_m < 0.0 \
			or rules_value.interact_keep_range_m < rules_value.interact_range_m:
		errors.append("interact_keep_range_m debe ser al menos interact_range_m")
	if rules_value.ability_block_angle_deg < 0.0 or rules_value.ability_block_angle_deg > 360.0 \
			or rules_value.ability_block_stamina_per_damage < 0.0:
		errors.append("bloqueo de las habilidades fuera de rango")
	if rules_value.max_projectiles_per_shooter < 1 \
			or rules_value.max_projectiles_per_zone < rules_value.max_projectiles_per_shooter:
		errors.append("topes de proyectiles fuera de rango (1 <= por tirador <= por zona)")


# Añade [param item] a [param list] si no estaba ya (el mismo objeto).
static func _add_unique(list: Array[Resource], item: Resource) -> void:
	if not list.has(item):
		list.append(item)


static func _add_if_set(list: Array[Resource], item: Resource) -> void:
	if item != null:
		_add_unique(list, item)


# Recursos con id (un StringName en la propiedad «id»), ordenados por id; si dos objetos distintos
# comparten id, se avisa y se queda el primero. [param kind] y [param article] dan nombre a los
# errores («id de ataque repetido», «un ataque no tiene id»).
static func _sorted_unique(definitions: Array[Resource], kind: String, article: String,
		errors: PackedStringArray) -> Array[Resource]:
	var sorted: Array[Resource] = []
	for definition: Resource in definitions:
		if StringName(definition.get("id")) == &"":
			errors.append("%s no tiene id" % article)
		else:
			sorted.append(definition)
	sorted.sort_custom(func(a: Resource, b: Resource) -> bool:
		return String(a.get("id")) < String(b.get("id")))
	var unique: Array[Resource] = []
	for definition: Resource in sorted:
		if not unique.is_empty() \
				and StringName(unique[unique.size() - 1].get("id")) == StringName(definition.get("id")):
			errors.append("id de %s repetido: %s" % [kind, definition.get("id")])
			continue
		unique.append(definition)
	return unique


# Asigna los IDs (1..n) de [param named] en [param ids_by_name] y devuelve el ID de cada objeto.
static func _ids_by_def(named: Array[Resource],
		ids_by_name: Dictionary[StringName, int]) -> Dictionary[Resource, int]:
	var by_def: Dictionary[Resource, int] = {}
	for i: int in named.size():
		by_def[named[i]] = i + 1
		ids_by_name[StringName(named[i].get("id"))] = i + 1
	return by_def


# ID de [param resource] en [param by_def], o 0 si es null o no está.
static func _id_of(by_def: Dictionary[Resource, int], resource: Resource) -> int:
	if resource == null:
		return 0
	return by_def.get(resource, 0)


static func _check_count(count: int, maximum: int, what: String, errors: PackedStringArray) -> void:
	if count > maximum:
		errors.append("hay %d %s y caben %d" % [count, what, maximum])


# Anota el dueño de una habilidad: (ID del arma, ranura) o (0, -1 - índice del consumible). Una
# habilidad solo puede estar en un arma y una ranura, o en los consumibles.
static func _claim_ability(owners: Dictionary[Resource, Vector2i], ability_def: AbilityDefinition,
		owner: Vector2i, errors: PackedStringArray) -> void:
	if owners.has(ability_def):
		errors.append("la habilidad %s está en más de un arma o ranura o en los consumibles"
				% ability_def.id)
		return
	owners[ability_def] = owner


# --- Conversión a ticks -----------------------------------------------------------------------

static func _convert_attack(definition: AttackDefinition, id: int,
		status_by_def: Dictionary[Resource, int], projectile_by_def: Dictionary[Resource, int],
		errors: PackedStringArray) -> AttackTicks:
	var ticks := AttackTicks.new()
	var label: String = "ataque %s" % definition.id
	ticks.id = id
	ticks.name = definition.id
	ticks.heavy = definition.heavy
	ticks.windup_ticks = seconds_to_ticks(definition.windup_s)
	ticks.active_ticks = seconds_to_ticks(definition.active_s)
	ticks.recovery_ticks = seconds_to_ticks(definition.recovery_s)
	ticks.total_ticks = ticks.windup_ticks + ticks.active_ticks + ticks.recovery_ticks
	ticks.combo_window_ticks = seconds_to_ticks(definition.combo_window_s)
	ticks.cancel_to_dodge_from_ticks = seconds_to_ticks(definition.cancel_to_dodge_from_s)
	ticks.stamina_cost = definition.stamina_cost
	ticks.lunge_speed = definition.lunge_speed
	ticks.turn_rate = definition.turn_rate
	ticks.move_speed_scale = definition.move_speed_scale
	ticks.charge_min_ticks = seconds_to_ticks(definition.charge_min_s)
	ticks.charge_max_ticks = seconds_to_ticks(definition.charge_max_s)
	ticks.charge_move_scale = definition.charge_move_scale
	ticks.charge_turn_rate = definition.charge_turn_rate
	ticks.projectile_id = _id_of(projectile_by_def, definition.projectile)
	ticks.projectile_speed_mps = definition.projectile_speed_mps
	ticks.charge_speed_scale = definition.charge_speed_scale
	ticks.shape = definition.shape
	ticks.base_damage = definition.base_damage
	ticks.damage_type = definition.damage_type
	ticks.hyper_armor = definition.hyper_armor
	ticks.unblockable = definition.unblockable
	ticks.stagger_ticks = seconds_to_ticks(definition.stagger_s)
	ticks.knockback_speed = definition.knockback_speed
	ticks.charge_damage_scale = definition.charge_damage_scale
	ticks.stun_ticks = seconds_to_ticks(definition.stun_s)
	ticks.on_hit_status_id = _id_of(status_by_def, definition.on_hit_status)

	if definition.windup_s < 0.0 or definition.active_s < 0.0 or definition.recovery_s < 0.0:
		errors.append("%s: las duraciones no pueden ser negativas" % label)
	if ticks.total_ticks < 1:
		errors.append("%s: dura 0 ticks" % label)
	if ticks.combo_window_ticks < 0 or ticks.combo_window_ticks > ticks.recovery_ticks:
		errors.append("%s: la ventana de combo debe caber en la recuperación" % label)
	if ticks.cancel_to_dodge_from_ticks < 0 or ticks.cancel_to_dodge_from_ticks > ticks.total_ticks:
		errors.append("%s: cancel_to_dodge_from_s fuera de la duración" % label)
	if definition.stamina_cost < 0 or definition.stamina_cost > 1000:
		errors.append("%s: stamina_cost fuera de rango (0-1000)" % label)
	if definition.move_speed_scale < 0.0 or definition.turn_rate < 0.0 \
			or definition.lunge_speed < 0.0:
		errors.append("%s: velocidad, giro o avance negativos" % label)
	if definition.shape == null and definition.projectile == null:
		errors.append("%s: falta la forma del golpe (o un proyectil)" % label)
	if definition.base_damage < 0:
		errors.append("%s: daño base negativo" % label)
	if definition.damage_type < 0 or definition.damage_type > _MAX_DAMAGE_TYPE:
		errors.append("%s: damage_type fuera de rango (0-%d)" % [label, _MAX_DAMAGE_TYPE])
	if definition.stagger_s < 0.0 or definition.knockback_speed < 0.0 \
			or definition.knockback_speed > 300.0:
		errors.append("%s: tambaleo o empuje fuera de rango" % label)
	if definition.stun_s < 0.0:
		errors.append("%s: aturdimiento negativo" % label)
	if definition.projectile != null:
		var top_speed: float = definition.projectile_speed_mps \
				* maxf(definition.charge_speed_scale, 1.0)
		if definition.projectile_speed_mps <= 0.0 or top_speed > _MAX_PROJECTILE_SPEED:
			errors.append("%s: velocidad del proyectil fuera de rango (0-%.2f m/s)" % [
				label, _MAX_PROJECTILE_SPEED,
			])
	if definition.heavy:
		if ticks.charge_min_ticks < 1 or ticks.charge_max_ticks < ticks.charge_min_ticks \
				or ticks.charge_max_ticks > _MAX_CHARGE_TICKS:
			errors.append("%s: la carga debe cumplir 0 < mínima <= máxima <= %d ticks" % [
				label, _MAX_CHARGE_TICKS,
			])
		if definition.charge_move_scale < 0.0 or definition.charge_turn_rate < 0.0:
			errors.append("%s: movimiento o giro de la carga negativos" % label)
		if definition.charge_damage_scale < 1.0:
			errors.append("%s: charge_damage_scale no puede ser menor que 1" % label)
		if definition.charge_speed_scale < 1.0:
			errors.append("%s: charge_speed_scale no puede ser menor que 1" % label)
	return ticks


static func _convert_weapon(definition: WeaponDefinition, id: int,
		attack_by_def: Dictionary[Resource, int], ability_by_def: Dictionary[Resource, int],
		rules_value: CombatRules, errors: PackedStringArray) -> WeaponTicks:
	var ticks := WeaponTicks.new()
	var label: String = "arma %s" % definition.id
	ticks.id = id
	ticks.name = definition.id
	ticks.block_move_scale = definition.block_move_scale
	ticks.block_turn_rate = definition.block_turn_rate
	ticks.block_angle_deg = definition.block_angle_deg
	ticks.block_mitigation = definition.block_mitigation
	ticks.block_stamina_per_damage = definition.block_stamina_per_damage
	ticks.can_block = definition.can_block

	if definition.light_combo.size() < 1 or definition.light_combo.size() > _MAX_LIGHT_COMBO:
		errors.append("%s: el combo ligero debe tener de 1 a %d golpes (tiene %d)" % [
			label, _MAX_LIGHT_COMBO, definition.light_combo.size(),
		])
	for attack_def: AttackDefinition in definition.light_combo:
		if attack_def == null or not attack_by_def.has(attack_def):
			errors.append("%s: un golpe del combo no está en el catálogo" % label)
			ticks.light_ids.append(0)
			continue
		if attack_def.heavy:
			errors.append("%s: %s está en el combo ligero pero es un ataque fuerte" % [
				label, attack_def.id,
			])
		ticks.light_ids.append(attack_by_def[attack_def])
	if definition.heavy_attack == null or not attack_by_def.has(definition.heavy_attack):
		errors.append("%s: falta el ataque fuerte" % label)
	else:
		if not definition.heavy_attack.heavy:
			errors.append("%s: el ataque fuerte %s no tiene heavy = true" % [
				label, definition.heavy_attack.id,
			])
		ticks.heavy_id = attack_by_def[definition.heavy_attack]
		if definition.heavy_attack.stamina_cost > rules_value.stamina_max:
			errors.append("%s: el ataque fuerte cuesta más que la resistencia máxima" % label)

	ticks.ability_ids = PackedInt32Array([0, 0, 0])
	if definition.abilities.size() > _MAX_ABILITIES:
		errors.append("%s: tiene %d habilidades y caben %d" % [
			label, definition.abilities.size(), _MAX_ABILITIES,
		])
	for slot: int in mini(definition.abilities.size(), _MAX_ABILITIES):
		var ability_def: AbilityDefinition = definition.abilities[slot]
		if ability_def == null:
			continue
		if not ability_by_def.has(ability_def):
			errors.append("%s: la habilidad de la ranura %d no está en el catálogo" % [
				label, slot + 1,
			])
			continue
		ticks.ability_ids[slot] = ability_by_def[ability_def]

	if definition.block_mitigation < 0.0 or definition.block_mitigation > 1.0:
		errors.append("%s: block_mitigation fuera de rango (0-1)" % label)
	if definition.block_angle_deg < 0.0 or definition.block_angle_deg > 360.0:
		errors.append("%s: block_angle_deg fuera de rango (0-360)" % label)
	if definition.block_move_scale < 0.0 or definition.block_turn_rate < 0.0 \
			or definition.block_stamina_per_damage < 0.0:
		errors.append("%s: parámetros de bloqueo negativos" % label)

	if definition.dodge == null:
		errors.append("%s: falta la esquiva" % label)
		ticks.dodge = DodgeTicks.new()
	else:
		ticks.dodge = _bake_dodge(definition.dodge, label, rules_value, errors)
	return ticks


# Convierte la esquiva a ticks y hornea su curva: la velocidad de cada tick sale de la curva
# muestreada en el centro del tick y se escala para que la suma de v / 60 sea distance_m.
static func _bake_dodge(definition: DodgeDefinition, label: String, rules_value: CombatRules,
		errors: PackedStringArray) -> DodgeTicks:
	var ticks := DodgeTicks.new()
	ticks.duration_ticks = seconds_to_ticks(definition.duration_s)
	ticks.invulnerable_from_ticks = seconds_to_ticks(definition.invulnerable_from_s)
	ticks.invulnerable_to_ticks = seconds_to_ticks(definition.invulnerable_to_s)
	ticks.distance_m = definition.distance_m
	ticks.stamina_cost = definition.stamina_cost
	ticks.cancel_to_attack_from_ticks = seconds_to_ticks(definition.cancel_to_attack_from_s)

	if ticks.duration_ticks < 1:
		errors.append("%s: la esquiva dura 0 ticks" % label)
	if ticks.invulnerable_from_ticks < 0 \
			or ticks.invulnerable_to_ticks < ticks.invulnerable_from_ticks \
			or ticks.invulnerable_to_ticks > ticks.duration_ticks:
		errors.append("%s: la invulnerabilidad debe cumplir 0 <= desde <= hasta <= duración"
				% label)
	if ticks.cancel_to_attack_from_ticks < 0 \
			or ticks.cancel_to_attack_from_ticks > ticks.duration_ticks:
		errors.append("%s: cancel_to_attack_from_s fuera de la duración" % label)
	if definition.distance_m < 0.0:
		errors.append("%s: distancia de esquiva negativa" % label)
	if definition.stamina_cost < 0 or definition.stamina_cost > 1000 \
			or definition.stamina_cost > rules_value.stamina_max:
		errors.append("%s: coste de la esquiva fuera de rango" % label)
	if definition.speed_curve == null:
		errors.append("%s: falta la curva de velocidad de la esquiva" % label)
	elif definition.distance_m > 0.0 and maxi(ticks.duration_ticks, 0) > 0 \
			and _curve_total(definition.speed_curve, ticks.duration_ticks) <= 0.0:
		errors.append("%s: la curva de la esquiva no tiene velocidad" % label)
	ticks.speeds = _bake_curve(definition.speed_curve, maxi(ticks.duration_ticks, 0),
			definition.distance_m)
	return ticks


# Hornea [param curve] (null = plana) en [param count] velocidades (f32) cuya suma de v / 60 es
# [param distance]: cada tick muestrea la curva en su centro.
static func _bake_curve(curve: Curve, count: int, distance: float) -> PackedFloat32Array:
	var speeds := PackedFloat32Array()
	speeds.resize(count)
	var total: float = _curve_total(curve, count)
	var scale: float = 0.0
	if total > 0.0:
		scale = distance * TICK_RATE / total
	for i: int in count:
		speeds[i] = _to_f32(_curve_sample(curve, i, count) * scale)
	return speeds


static func _curve_total(curve: Curve, count: int) -> float:
	var total: float = 0.0
	for i: int in count:
		total += _curve_sample(curve, i, count)
	return total


static func _curve_sample(curve: Curve, index: int, count: int) -> float:
	if curve == null:
		return 1.0
	return maxf(curve.sample((index + 0.5) / float(count)), 0.0)


static func _convert_ability(definition: AbilityDefinition, id: int, owner: Vector2i,
		tables_in: CombatTables, status_by_def: Dictionary[Resource, int],
		projectile_by_def: Dictionary[Resource, int], errors: PackedStringArray) -> AbilityTicks:
	var ticks := AbilityTicks.new()
	var rules_value: CombatRules = tables_in.rules
	var label: String = "habilidad %s" % definition.id
	ticks.id = id
	ticks.name = definition.id
	if owner.y >= 0:
		ticks.weapon_id = owner.x
		ticks.slot = owner.y
	elif owner.y >= -CombatState.CONSUMABLE_SLOTS:
		ticks.consumable_index = -1 - owner.y
	ticks.cast_ticks = seconds_to_ticks(definition.cast_s)
	ticks.active_ticks = seconds_to_ticks(definition.active_s)
	ticks.recovery_ticks = seconds_to_ticks(definition.recovery_s)
	ticks.total_ticks = ticks.cast_ticks + ticks.active_ticks + ticks.recovery_ticks
	ticks.cooldown_ticks = seconds_to_ticks(definition.cooldown_s)
	ticks.channel = definition.channel
	ticks.channel_hold = definition.channel_hold
	ticks.channel_breaks_on_move = definition.channel_breaks_on_move
	var recovery_from: int = ticks.cast_ticks + ticks.active_ticks
	ticks.cancel_to_dodge_from_ticks = recovery_from
	if definition.cancel_to_dodge_from_s >= 0.0:
		ticks.cancel_to_dodge_from_ticks = seconds_to_ticks(definition.cancel_to_dodge_from_s)
	ticks.cancel_to_attack_from_ticks = recovery_from
	if definition.cancel_to_attack_from_s >= 0.0:
		ticks.cancel_to_attack_from_ticks = seconds_to_ticks(definition.cancel_to_attack_from_s)
	ticks.move_speed_scale = definition.move_speed_scale
	ticks.turn_rate = definition.turn_rate
	ticks.lunge_speed = definition.lunge_speed
	ticks.dash_distance_m = definition.dash_distance_m
	ticks.dash_direction = definition.dash_direction
	ticks.usable_in_air = definition.usable_in_air
	ticks.stamina_restore = definition.stamina_restore
	ticks.blocks = definition.blocks
	ticks.projectile_id = _id_of(projectile_by_def, definition.projectile)
	ticks.projectile_count = definition.projectile_count
	ticks.projectile_spread_deg = definition.projectile_spread_deg
	ticks.projectile_speed_mps = definition.projectile_speed_mps
	ticks.self_status_id = _id_of(status_by_def, definition.self_status)
	ticks.self_heal = definition.self_heal
	ticks.interrupt_on_damage = definition.interrupt_on_damage
	ticks.wall_half_extents = definition.wall_half_extents
	ticks.wall_forward_m = definition.wall_forward_m
	if definition.dash_distance_m > 0.0:
		ticks.dash_from_ticks = seconds_to_ticks(definition.dash_from_s)
		ticks.dash_to_ticks = seconds_to_ticks(definition.dash_to_s)
		ticks.dash_speeds = _bake_curve(definition.dash_curve,
				maxi(ticks.dash_to_ticks - ticks.dash_from_ticks, 0), definition.dash_distance_m)

	# Golpe sintetizado: las ventanas de la habilidad (anticipación = lanzamiento) y sus campos de
	# solo servidor; su id es la fuente de la habilidad.
	var hit := AttackTicks.new()
	hit.id = CombatSource.make(CombatSource.Kind.ABILITY, id)
	hit.name = definition.id
	hit.windup_ticks = ticks.cast_ticks
	hit.active_ticks = ticks.active_ticks
	hit.recovery_ticks = ticks.recovery_ticks
	hit.total_ticks = ticks.total_ticks
	hit.cancel_to_dodge_from_ticks = ticks.cancel_to_dodge_from_ticks
	hit.move_speed_scale = ticks.move_speed_scale
	hit.turn_rate = ticks.turn_rate
	hit.lunge_speed = ticks.lunge_speed
	hit.projectile_id = ticks.projectile_id
	hit.projectile_speed_mps = ticks.projectile_speed_mps
	hit.shape = definition.shape
	hit.base_damage = definition.base_damage
	hit.damage_type = definition.damage_type
	hit.hyper_armor = definition.hyper_armor
	hit.unblockable = definition.unblockable
	hit.stagger_ticks = seconds_to_ticks(definition.stagger_s)
	hit.stun_ticks = seconds_to_ticks(definition.stun_s)
	hit.knockback_speed = definition.knockback_speed
	hit.on_hit_status_id = _id_of(status_by_def, definition.target_status)
	ticks.hit = hit

	# Validación (docs/habilidades.md, sección 2.2).
	if definition.cast_s < 0.0 or definition.active_s < 0.0 or definition.recovery_s < 0.0 \
			or definition.cooldown_s < 0.0:
		errors.append("%s: las duraciones no pueden ser negativas" % label)
	if ticks.active_ticks < 1:
		errors.append("%s: el activo debe durar al menos un tick (el del compromiso)" % label)
	if ticks.channel and ticks.recovery_ticks != 0:
		errors.append("%s: una canalización no lleva recuperación" % label)
	if ticks.is_consumable():
		if ticks.cooldown_ticks != 0:
			errors.append("%s: un consumible no lleva reutilización propia (cooldown_s 0)" % label)
		if tables_in.consumable_cooldown_ticks < ticks.total_ticks + AbilityTicks.REARM_TICKS:
			errors.append("%s: la reutilización compartida debe ser al menos su duración + %d ticks"
					% [label, AbilityTicks.REARM_TICKS])
		if not definition.interrupt_on_damage:
			errors.append("%s: un consumible lleva interrupt_on_damage" % label)
	elif ticks.cooldown_ticks < ticks.total_ticks + AbilityTicks.REARM_TICKS:
		# Así dos usos seguidos de la misma ranura (o dos consumibles) dejan REARM_TICKS en NONE entre medias.
		errors.append("%s: la reutilización debe ser al menos la duración + %d ticks"
				% [label, AbilityTicks.REARM_TICKS])
	if ticks.cancel_to_dodge_from_ticks < 0 or ticks.cancel_to_dodge_from_ticks > ticks.total_ticks \
			or ticks.cancel_to_attack_from_ticks < 0 \
			or ticks.cancel_to_attack_from_ticks > ticks.total_ticks:
		errors.append("%s: cancelaciones fuera de la duración" % label)
	if definition.move_speed_scale < 0.0 or definition.turn_rate < 0.0 \
			or definition.lunge_speed < 0.0:
		errors.append("%s: velocidad, giro o avance negativos" % label)
	if definition.dash_distance_m < 0.0:
		errors.append("%s: distancia del avance negativa" % label)
	elif definition.dash_distance_m > 0.0 and (ticks.dash_from_ticks < 0 \
			or ticks.dash_to_ticks <= ticks.dash_from_ticks \
			or ticks.dash_to_ticks > ticks.total_ticks):
		errors.append("%s: la ventana del avance debe caber en la habilidad" % label)
	elif definition.dash_distance_m > 0.0 and _curve_total(definition.dash_curve,
			ticks.dash_to_ticks - ticks.dash_from_ticks) <= 0.0:
		errors.append("%s: la curva del avance no tiene velocidad" % label)
	if definition.dash_direction < 0 or definition.dash_direction > 2:
		errors.append("%s: dash_direction fuera de rango (0-2)" % label)
	if definition.stamina_restore < 0 or definition.stamina_restore > rules_value.stamina_max:
		errors.append("%s: stamina_restore fuera de rango" % label)
	if definition.projectile_count < 1 or definition.projectile_count > _MAX_PROJECTILE_COUNT:
		errors.append("%s: projectile_count fuera de rango (1-%d)" % [label, _MAX_PROJECTILE_COUNT])
	if definition.projectile_spread_deg < 0.0:
		errors.append("%s: projectile_spread_deg negativo" % label)
	if definition.projectile != null and (definition.projectile_speed_mps <= 0.0 \
			or definition.projectile_speed_mps > _MAX_PROJECTILE_SPEED):
		errors.append("%s: velocidad del proyectil fuera de rango (0-%.2f m/s)" % [
			label, _MAX_PROJECTILE_SPEED,
		])
	if definition.base_damage < 0 or definition.self_heal < 0:
		errors.append("%s: daño o curación negativos" % label)
	if definition.damage_type < 0 or definition.damage_type > _MAX_DAMAGE_TYPE:
		errors.append("%s: damage_type fuera de rango (0-%d)" % [label, _MAX_DAMAGE_TYPE])
	if definition.stagger_s < 0.0 or definition.knockback_speed < 0.0 \
			or definition.knockback_speed > 300.0:
		errors.append("%s: tambaleo o empuje fuera de rango" % label)
	if definition.stun_s < 0.0:
		errors.append("%s: aturdimiento negativo" % label)
	if definition.wall_half_extents.x < 0.0 or definition.wall_half_extents.y < 0.0 \
			or definition.wall_half_extents.z < 0.0:
		errors.append("%s: wall_half_extents negativo" % label)
	return ticks


static func _convert_status(definition: StatusEffectDefinition, id: int,
		errors: PackedStringArray) -> StatusTicks:
	var ticks := StatusTicks.new()
	var label: String = "efecto %s" % definition.id
	ticks.id = id
	ticks.name = definition.id
	ticks.kind = definition.kind
	ticks.move_speed_scale = definition.move_speed_scale
	ticks.duration_ticks = seconds_to_ticks(definition.duration_s)
	ticks.stacking = definition.stacking
	ticks.max_stacks = definition.max_stacks
	ticks.pulse_ticks = seconds_to_ticks(definition.pulse_every_s)
	ticks.pulse_amount = definition.pulse_amount
	ticks.damage_type = definition.damage_type
	ticks.magnitude = definition.magnitude

	if definition.kind < 0 or definition.kind >= StatusEffectDefinition.Kind.size():
		errors.append("%s: kind fuera de rango" % label)
	if definition.stacking < 0 or definition.stacking >= StatusEffectDefinition.Stacking.size():
		errors.append("%s: stacking fuera de rango" % label)
	if definition.max_stacks < 1 or definition.max_stacks > 255:
		errors.append("%s: max_stacks fuera de rango (1-255)" % label)
	if ticks.duration_ticks < 1:
		errors.append("%s: dura 0 ticks" % label)
	if definition.kind == StatusEffectDefinition.Kind.ROOT and definition.move_speed_scale != 0.0:
		errors.append("%s: ROOT lleva move_speed_scale 0" % label)
	if definition.kind == StatusEffectDefinition.Kind.SLOW and definition.move_speed_scale <= 0.0:
		errors.append("%s: SLOW lleva move_speed_scale > 0" % label)
	if definition.pulse_amount < 0:
		errors.append("%s: pulse_amount negativo" % label)
	if ticks.has_pulses():
		if ticks.pulse_ticks < 1:
			errors.append("%s: los pulsos deben separarse al menos un tick" % label)
		elif ticks.duration_ticks % ticks.pulse_ticks != 0:
			errors.append("%s: la duración debe ser múltiplo exacto de los pulsos (%d y %d ticks)"
					% [label, ticks.duration_ticks, ticks.pulse_ticks])
	if definition.damage_type < 0 or definition.damage_type > _MAX_DAMAGE_TYPE:
		errors.append("%s: damage_type fuera de rango (0-%d)" % [label, _MAX_DAMAGE_TYPE])
	return ticks


static func _convert_projectile(definition: ProjectileDefinition, id: int,
		errors: PackedStringArray) -> ProjectileTicks:
	var ticks := ProjectileTicks.new()
	var label: String = "proyectil %s" % definition.id
	ticks.id = id
	ticks.name = definition.id
	ticks.gravity = definition.gravity
	ticks.radius_m = definition.radius_m
	ticks.lifetime_ticks = seconds_to_ticks(definition.lifetime_s)
	if ticks.lifetime_ticks < 1:
		errors.append("%s: lifetime_ticks debe ser al menos 1" % label)
	if definition.gravity < 0.0 or definition.radius_m < 0.0:
		errors.append("%s: gravedad o radio negativos" % label)
	return ticks


# IDs de las armas de una plantilla, en orden de ranura.
static func _convert_template(definition: EquipmentTemplate,
		weapon_by_def: Dictionary[Resource, int], errors: PackedStringArray) -> PackedInt32Array:
	var label: String = "plantilla %s" % definition.id
	var weapons := PackedInt32Array()
	if definition.weapons.size() < 1 or definition.weapons.size() > 2:
		errors.append("%s: debe llevar una o dos armas (lleva %d)" % [
			label, definition.weapons.size(),
		])
	for weapon_def: WeaponDefinition in definition.weapons:
		if weapon_def == null or not weapon_by_def.has(weapon_def):
			errors.append("%s: un arma no está en el catálogo" % label)
			continue
		if definition.selectable and String(weapon_def.id).begins_with(NPC_PREFIX):
			errors.append("%s: es elegible y lleva el arma de PNJ %s" % [label, weapon_def.id])
		weapons.append(weapon_by_def[weapon_def])
	return weapons


# Cargas de una plantilla empaquetadas como CombatState.consumable_charges.
static func _template_charges(definition: EquipmentTemplate, errors: PackedStringArray) -> int:
	var charges: PackedInt32Array = definition.consumable_charges
	if charges.size() != CombatState.CONSUMABLE_SLOTS:
		errors.append("plantilla %s: consumable_charges debe tener %d valores" % [
			definition.id, CombatState.CONSUMABLE_SLOTS,
		])
	for value: int in charges:
		if value < 0 or value > CombatState.MAX_CHARGES:
			errors.append("plantilla %s: cargas fuera de rango (0-%d)" % [
				definition.id, CombatState.MAX_CHARGES,
			])
	var first: int = charges[0] if charges.size() > 0 else 0
	var second: int = charges[1] if charges.size() > 1 else 0
	return CombatState.pack_charges(first, second)


# Redondea a float de 32 bits, la precisión con la que viajan las magnitudes de la simulación
# (igual que PlayerState.to_f32, sin depender de él).
static func _to_f32(value: float) -> float:
	_f32_scratch.encode_float(0, value)
	return _f32_scratch.decode_float(0)


# --- Huella -----------------------------------------------------------------------------------

# SHA-256 de todo lo que cambia la simulación de cliente y servidor, en un orden fijo: los 4
# primeros bytes como u32 (como NetProtocol.compute_sim_hash). Los valores solo del servidor
# (daño, formas, mitigación, controles, pulsos, derribado, muros...) y las plantillas no entran.
static func _compute_hash(tables_in: CombatTables) -> int:
	var rules_value: CombatRules = tables_in.rules
	var parts: Array = [
		_HASH_FORMAT, TICK_RATE,
		[
			rules_value.stamina_max, rules_value.stamina_regen_per_tick,
			tables_in.regen_delay_ticks, rules_value.exhausted_regen_per_tick,
			rules_value.exhausted_exit_threshold, rules_value.hold_to_heavy_ticks,
			rules_value.input_buffer_ticks, rules_value.parry_window_ticks,
			rules_value.parry_cooldown_ticks,
			tables_in.swap_ticks, rules_value.swap_move_scale, rules_value.downed_move_scale,
			rules_value.downed_turn_rate, tables_in.revive_ticks, tables_in.execute_ticks,
			tables_in.consumable_ids, tables_in.consumable_cooldown_ticks,
			rules_value.aim_pivot_height, rules_value.aim_shoulder_offset,
			rules_value.aim_camera_v_offset, rules_value.aim_range_m,
			rules_value.aim_converge_deg, rules_value.muzzle_height,
		],
	]
	var attacks_part: Array = []
	for attack_ticks: AttackTicks in tables_in.attacks:
		attacks_part.append([
			attack_ticks.id, String(attack_ticks.name), attack_ticks.heavy,
			attack_ticks.windup_ticks, attack_ticks.active_ticks, attack_ticks.recovery_ticks,
			attack_ticks.combo_window_ticks, attack_ticks.cancel_to_dodge_from_ticks,
			attack_ticks.stamina_cost, attack_ticks.lunge_speed, attack_ticks.turn_rate,
			attack_ticks.move_speed_scale, attack_ticks.charge_min_ticks,
			attack_ticks.charge_max_ticks, attack_ticks.charge_move_scale,
			attack_ticks.charge_turn_rate, attack_ticks.projectile_id,
			attack_ticks.projectile_speed_mps, attack_ticks.charge_speed_scale,
		])
	parts.append(attacks_part)
	var weapons_part: Array = []
	for weapon_ticks: WeaponTicks in tables_in.weapons:
		var dodge_ticks: DodgeTicks = weapon_ticks.dodge
		weapons_part.append([
			weapon_ticks.id, String(weapon_ticks.name), weapon_ticks.light_ids,
			weapon_ticks.heavy_id, weapon_ticks.block_move_scale, weapon_ticks.block_turn_rate,
			[
				dodge_ticks.duration_ticks, dodge_ticks.invulnerable_from_ticks,
				dodge_ticks.invulnerable_to_ticks, dodge_ticks.stamina_cost,
				dodge_ticks.cancel_to_attack_from_ticks, dodge_ticks.speeds,
			],
			weapon_ticks.ability_ids, weapon_ticks.can_block,
		])
	parts.append(weapons_part)
	var abilities_part: Array = []
	for ability_ticks: AbilityTicks in tables_in.abilities:
		abilities_part.append([
			ability_ticks.id, String(ability_ticks.name), ability_ticks.slot,
			ability_ticks.weapon_id, ability_ticks.consumable_index, ability_ticks.cast_ticks,
			ability_ticks.active_ticks, ability_ticks.recovery_ticks, ability_ticks.cooldown_ticks,
			ability_ticks.channel, ability_ticks.channel_hold, ability_ticks.channel_breaks_on_move,
			ability_ticks.cancel_to_dodge_from_ticks, ability_ticks.cancel_to_attack_from_ticks,
			ability_ticks.move_speed_scale, ability_ticks.turn_rate, ability_ticks.lunge_speed,
			ability_ticks.dash_distance_m, ability_ticks.dash_from_ticks,
			ability_ticks.dash_to_ticks, ability_ticks.dash_direction, ability_ticks.dash_speeds,
			ability_ticks.usable_in_air, ability_ticks.stamina_restore, ability_ticks.blocks,
			ability_ticks.projectile_id, ability_ticks.projectile_count,
			ability_ticks.projectile_spread_deg, ability_ticks.projectile_speed_mps,
		])
	parts.append(abilities_part)
	var statuses_part: Array = []
	for status_ticks: StatusTicks in tables_in.statuses:
		statuses_part.append([
			status_ticks.id, String(status_ticks.name), status_ticks.kind,
			status_ticks.move_speed_scale,
		])
	parts.append(statuses_part)
	var projectiles_part: Array = []
	for projectile_ticks: ProjectileTicks in tables_in.projectiles:
		projectiles_part.append([
			projectile_ticks.id, String(projectile_ticks.name), projectile_ticks.gravity,
			projectile_ticks.radius_m, projectile_ticks.lifetime_ticks,
		])
	parts.append(projectiles_part)
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(parts))
	return context.finish().decode_u32(0)
