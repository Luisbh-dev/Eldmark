class_name CombatCatalog
extends RefCounted
## Catálogo de combate (docs/combate.md, sección 2): lee los recursos de [code]data/combat/[/code]
## una sola vez (carga perezosa), asigna IDs u16 estables, convierte las duraciones a ticks y
## hornea la curva de la esquiva.
## [br][br]
## [b]IDs.[/b] Los ataques y las armas tienen espacios de IDs separados: 1..n por orden
## alfabético de su [code]id[/code] y 0 = ninguno. Un [code]id[/code] repetido es un error.
## [br][br]
## [b]Ticks.[/b] Las duraciones de los [code].tres[/code] están en segundos y se convierten con
## [code]roundi(s * 60)[/code] ([method seconds_to_ticks]). Cada ventana es un intervalo
## [code][desde, hasta)[/code] de ticks contado desde el [code]action_tick[/code].
## [br][br]
## [b]Esquiva.[/b] Su curva se hornea en una tabla de velocidades por tick (f32, como viajan las
## demás magnitudes de la simulación) normalizada para que la distancia total sea
## [member DodgeDefinition.distance_m].
## [br][br]
## [b]Huella.[/b] [method prediction_hash] resume solo lo que cambia lo que simulan cliente y
## servidor (fases, movimiento, costes, curva, cancelaciones, bloqueo y campos predichos de
## [CombatRules]); entra en [method NetProtocol.compute_sim_hash]. Daño, mitigación, críticos,
## controles, vida y reaparición no entran.

## Ticks de simulación por segundo en los que se expresan los datos.
const TICK_RATE: int = 60
## Carpeta de los datos de combate.
const DATA_DIR: String = "res://data/combat"
## Arma con la que aparece un personaje.
const DEFAULT_WEAPON: StringName = &"sword_shield"
## Versión del formato de la huella (sube si cambia lo que entra en ella).
const _HASH_FORMAT: int = 1
const _MAX_STAMINA: int = 0xFFFF
const _MAX_BUFFER_TICKS: int = 15
const _MAX_CHARGE_TICKS: int = 255
const _MAX_DAMAGE_TYPE: int = 3

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


## Las reglas generales del combate.
static func rules() -> CombatRules:
	return tables().rules


## ID del ataque llamado [param name], o 0 si no existe.
static func attack_id(name: StringName) -> int:
	return tables().attack_ids.get(name, 0)


## ID del arma llamada [param name], o 0 si no existe.
static func weapon_id(name: StringName) -> int:
	return tables().weapon_ids.get(name, 0)


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
## [WeaponDefinition] y los [AttackDefinition] (sueltos o enlazados desde un arma; el mismo objeto
## nunca cuenta dos veces). Los demás recursos se ignoran. No registra errores en el motor: los
## deja en [member CombatTables.errors].
static func build_from_resources(resources: Array[Resource]) -> CombatTables:
	var tables_out := CombatTables.new()
	var errors := PackedStringArray()
	var rules_list: Array[CombatRules] = []
	var attack_defs: Array[AttackDefinition] = []
	var weapon_defs: Array[WeaponDefinition] = []
	for resource: Resource in resources:
		if resource is CombatRules:
			if not rules_list.has(resource):
				rules_list.append(resource as CombatRules)
		elif resource is AttackDefinition:
			if not attack_defs.has(resource):
				attack_defs.append(resource as AttackDefinition)
		elif resource is WeaponDefinition:
			if not weapon_defs.has(resource):
				weapon_defs.append(resource as WeaponDefinition)
	for weapon_def: WeaponDefinition in weapon_defs:
		for attack_def: AttackDefinition in weapon_def.light_combo:
			if attack_def != null and not attack_defs.has(attack_def):
				attack_defs.append(attack_def)
		if weapon_def.heavy_attack != null and not attack_defs.has(weapon_def.heavy_attack):
			attack_defs.append(weapon_def.heavy_attack)

	# Reglas.
	if rules_list.is_empty():
		errors.append("falta un recurso CombatRules en %s" % DATA_DIR)
		tables_out.rules = CombatRules.new()
	else:
		if rules_list.size() > 1:
			errors.append("hay %d recursos CombatRules y solo puede haber uno" % rules_list.size())
		tables_out.rules = rules_list[0]
	_validate_rules(tables_out.rules, errors)

	# IDs: 1..n por orden alfabético; un id repetido es un error y el repetido se descarta.
	var named_attacks: Array[AttackDefinition] = _sorted_unique_attacks(attack_defs, errors)
	var attack_by_def: Dictionary[AttackDefinition, int] = {}
	for i: int in named_attacks.size():
		var definition: AttackDefinition = named_attacks[i]
		attack_by_def[definition] = i + 1
		tables_out.attack_ids[definition.id] = i + 1
		tables_out.attacks.append(_convert_attack(definition, i + 1, errors))
	var named_weapons: Array[WeaponDefinition] = _sorted_unique_weapons(weapon_defs, errors)
	for i: int in named_weapons.size():
		var weapon_def: WeaponDefinition = named_weapons[i]
		tables_out.weapon_ids[weapon_def.id] = i + 1
		tables_out.weapons.append(_convert_weapon(weapon_def, i + 1, attack_by_def,
				tables_out.rules, errors))

	tables_out.regen_delay_ticks = seconds_to_ticks(tables_out.rules.stamina_regen_delay_s)
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


# Ataques con id, ordenados por id; si dos objetos distintos comparten id, se avisa y se queda el
# primero.
static func _sorted_unique_attacks(definitions: Array[AttackDefinition],
		errors: PackedStringArray) -> Array[AttackDefinition]:
	var sorted: Array[AttackDefinition] = []
	for definition: AttackDefinition in definitions:
		if definition.id == &"":
			errors.append("un ataque no tiene id")
		else:
			sorted.append(definition)
	sorted.sort_custom(func(a: AttackDefinition, b: AttackDefinition) -> bool:
		return String(a.id) < String(b.id))
	var unique: Array[AttackDefinition] = []
	for definition: AttackDefinition in sorted:
		if not unique.is_empty() and unique[unique.size() - 1].id == definition.id:
			errors.append("id de ataque repetido: %s" % definition.id)
			continue
		unique.append(definition)
	return unique


static func _sorted_unique_weapons(definitions: Array[WeaponDefinition],
		errors: PackedStringArray) -> Array[WeaponDefinition]:
	var sorted: Array[WeaponDefinition] = []
	for definition: WeaponDefinition in definitions:
		if definition.id == &"":
			errors.append("un arma no tiene id")
		else:
			sorted.append(definition)
	sorted.sort_custom(func(a: WeaponDefinition, b: WeaponDefinition) -> bool:
		return String(a.id) < String(b.id))
	var unique: Array[WeaponDefinition] = []
	for definition: WeaponDefinition in sorted:
		if not unique.is_empty() and unique[unique.size() - 1].id == definition.id:
			errors.append("id de arma repetido: %s" % definition.id)
			continue
		unique.append(definition)
	return unique


# --- Conversión a ticks -----------------------------------------------------------------------

static func _convert_attack(definition: AttackDefinition, id: int,
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
	ticks.shape = definition.shape
	ticks.base_damage = definition.base_damage
	ticks.damage_type = definition.damage_type
	ticks.hyper_armor = definition.hyper_armor
	ticks.stagger_ticks = seconds_to_ticks(definition.stagger_s)
	ticks.knockback_speed = definition.knockback_speed
	ticks.charge_damage_scale = definition.charge_damage_scale

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
	if definition.shape == null:
		errors.append("%s: falta la forma del golpe" % label)
	if definition.base_damage < 0:
		errors.append("%s: daño base negativo" % label)
	if definition.damage_type < 0 or definition.damage_type > _MAX_DAMAGE_TYPE:
		errors.append("%s: damage_type fuera de rango (0-%d)" % [label, _MAX_DAMAGE_TYPE])
	if definition.stagger_s < 0.0 or definition.knockback_speed < 0.0 \
			or definition.knockback_speed > 300.0:
		errors.append("%s: tambaleo o empuje fuera de rango" % label)
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
	return ticks


static func _convert_weapon(definition: WeaponDefinition, id: int,
		attack_by_def: Dictionary[AttackDefinition, int], rules_value: CombatRules,
		errors: PackedStringArray) -> WeaponTicks:
	var ticks := WeaponTicks.new()
	var label: String = "arma %s" % definition.id
	ticks.id = id
	ticks.name = definition.id
	ticks.block_move_scale = definition.block_move_scale
	ticks.block_turn_rate = definition.block_turn_rate
	ticks.block_angle_deg = definition.block_angle_deg
	ticks.block_mitigation = definition.block_mitigation
	ticks.block_stamina_per_damage = definition.block_stamina_per_damage

	if definition.light_combo.size() != 3:
		errors.append("%s: el combo ligero debe tener 3 golpes (tiene %d)" % [
			label, definition.light_combo.size(),
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
		errors.append("%s: la invulnerabilidad debe cumplir 0 <= desde <= hasta <= duración" % label)
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

	var count: int = maxi(ticks.duration_ticks, 0)
	var raw := PackedFloat64Array()
	raw.resize(count)
	var total: float = 0.0
	for i: int in count:
		var profile: float = 1.0
		if definition.speed_curve != null:
			profile = maxf(definition.speed_curve.sample((i + 0.5) / float(count)), 0.0)
		raw[i] = profile
		total += profile
	var scale: float = 0.0
	if total > 0.0:
		scale = definition.distance_m * TICK_RATE / total
	elif definition.distance_m > 0.0:
		errors.append("%s: la curva de la esquiva no tiene velocidad" % label)
	ticks.speeds.resize(count)
	for i: int in count:
		ticks.speeds[i] = _to_f32(raw[i] * scale)
	return ticks


# Redondea a float de 32 bits, la precisión con la que viajan las magnitudes de la simulación
# (igual que PlayerState.to_f32, sin depender de él).
static func _to_f32(value: float) -> float:
	_f32_scratch.encode_float(0, value)
	return _f32_scratch.decode_float(0)


# --- Huella -----------------------------------------------------------------------------------

# SHA-256 de todo lo que cambia la simulación de cliente y servidor, en un orden fijo: los 4
# primeros bytes como u32 (como NetProtocol.compute_sim_hash). Los valores solo del servidor
# (daño, formas, mitigación, controles...) no entran.
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
			attack_ticks.charge_turn_rate,
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
		])
	parts.append(weapons_part)
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(parts))
	return context.finish().decode_u32(0)
