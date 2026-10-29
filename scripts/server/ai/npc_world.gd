class_name NpcWorld
extends RefCounted
## Lo que ve y puede hacer el cerebro de un PNJ en el servidor (docs/fuerte.md, sección 4.2): quién es un
## objetivo posible, si hay línea de visión, rutas de navegación, las fichas de ataque, los grupos de alerta y
## los avisos al sistema de generadores. Lo monta el [NpcSpawnerSystem] con las piezas del [ZoneServer] y se lo
## pasa a cada [HfsmBrain].
## [br][br]
## Todo se calcula con el estado «tras s − 1» porque los cerebros piensan en el paso 0 del tick
## (docs/fuerte.md, sección 1.7), antes de simular a nadie. La lista de posibles objetivos se arma una vez por tick
## y se reutiliza.

## Zona (para las reglas de hostilidad).
var zone_id: StringName = &""
var combat: CombatDirector = null
var safe_areas: SafeAreas = null
## Navegación (null = sin malla: los PNJ van en línea recta).
var navigation: NpcNavigation = null
var tokens: AttackTokens = AttackTokens.new()
## [code]() -> PhysicsDirectSpaceState3D[/code]: el espacio de física para la línea de visión.
var space_provider: Callable = Callable()
## [code](net_id: int, position: Vector3) -> void[/code]: teletransporta a un PNJ (el regreso atascado).
var teleporter: Callable = Callable()
## [code](brain: HfsmBrain, definition_id: StringName, count: int) -> int[/code]: crea refuerzos junto al
## PNJ y devuelve cuántos ha creado.
var reinforcer: Callable = Callable()
## Tick que se está pensando (el estado de los cuerpos es el de después del tick anterior).
var tick: int = 0

# Posibles objetivos de este tick: vivos, sin protección de reaparición y que no son maniquíes.
var _candidates: Array[Combatant] = []
var _candidates_tick: int = -1
# (bando del PNJ · 16 + bando del otro) -> si hay daño entre ellos en la zona.
var _hostile_cache: Dictionary[int, bool] = {}
# Grupo de alerta -> cerebros que lo forman.
var _groups: Dictionary[StringName, Array] = {}
var _results: Array[Combatant] = []
# Consultas hechas desde que existe (para medir).
var queries: int = 0
var line_of_sight_checks: int = 0


## Empieza el tick [param new_tick]: los posibles objetivos se vuelven a armar la primera vez que se pidan.
func begin_tick(new_tick: int) -> void:
	tick = new_tick


## El [Combatant] de [param net_id], o null.
func find_combatant(net_id: int) -> Combatant:
	return combat.get_combatant(net_id) if combat != null else null


## Los combatientes que un PNJ del bando [param realm] puede atacar a menos de [param radius] m (en horizontal)
## de [param position]: vivos, hostiles según [FactionRules], fuera de la protección de reaparición y que no
## son maniquíes. Quien está a salvo en la zona segura de su propio reino no cuenta (el resolutor no le haría
## daño); con [param ignores_safe_area] (los Guardianes) ocurre lo contrario: solo cuentan los que están dentro
## de la zona segura del reino del PNJ. El array es el mismo en cada llamada: hay que usarlo antes de pedir otro.
func query_targets(position: Vector3, radius: float, realm: int, ignores_safe_area: bool) -> Array[Combatant]:
	queries += 1
	_results.clear()
	if combat == null:
		return _results
	if _candidates_tick != tick:
		_rebuild_candidates()
	var radius_squared: float = radius * radius
	for candidate: Combatant in _candidates:
		var other: Vector3 = candidate.entity.get_position()
		var dx: float = other.x - position.x
		var dz: float = other.z - position.z
		if dx * dx + dz * dz > radius_squared:
			continue
		if not _is_hostile(realm, candidate.get_realm()):
			continue
		var in_own_camp: bool = safe_areas != null and safe_areas.contains_own(realm, other)
		if ignores_safe_area:
			if not in_own_camp:
				continue
		elif safe_areas != null and safe_areas.contains_own(candidate.get_realm(), other):
			continue
		_results.append(candidate)
	return _results


## true si [param candidate] sigue siendo un objetivo válido para un PNJ del bando [param realm]. Más barato que
## [method query_targets] cuando ya se sabe a quién se persigue.
func is_valid_target(candidate: Combatant, realm: int, ignores_safe_area: bool) -> bool:
	if candidate == null or candidate.is_dead() or candidate.is_protected(tick) or candidate.immortal:
		return false
	if not _is_hostile(realm, candidate.get_realm()):
		return false
	var position: Vector3 = candidate.entity.get_position()
	if ignores_safe_area:
		return safe_areas != null and safe_areas.contains_own(realm, position)
	return safe_areas == null or not safe_areas.contains_own(candidate.get_realm(), position)


## true si hay línea de visión entre los pies [param from_feet] y [param to_feet] (del pecho al centro del otro,
## contra el mundo y las estructuras).
func line_of_sight(from_feet: Vector3, to_feet: Vector3) -> bool:
	line_of_sight_checks += 1
	if not space_provider.is_valid():
		return true
	var space: PhysicsDirectSpaceState3D = space_provider.call()
	return space == null or HitShapes.has_line_of_sight(space, from_feet, to_feet)


## Ruta de [param from] a [param to] para un agente del bando [param realm] (vacía si no hay navegación lista).
func get_path(from: Vector3, to: Vector3, realm: int) -> PackedVector3Array:
	if navigation == null:
		return PackedVector3Array()
	return navigation.get_path(from, to, realm)


## true si la navegación está montada y da rutas de verdad.
func has_navigation() -> bool:
	return navigation != null and navigation.is_ready()


## Teletransporta al PNJ [param net_id] a [param position].
func teleport(net_id: int, position: Vector3) -> void:
	if teleporter.is_valid():
		teleporter.call(net_id, position)


## Pide refuerzos del tipo [param definition_id] ([param count]) junto a [param brain]. Devuelve cuántos se
## han creado.
func request_reinforcements(brain: HfsmBrain, definition_id: StringName, count: int) -> int:
	if reinforcer.is_valid():
		return int(reinforcer.call(brain, definition_id, count))
	return 0


# --- Grupos de alerta -------------------------------------------------------------------------------

## Mete a [param brain] en el grupo de alerta [param group].
func join_group(group: StringName, brain: HfsmBrain) -> void:
	if group.is_empty():
		return
	var members: Array = _groups.get(group, [])
	if not members.has(brain):
		members.append(brain)
	_groups[group] = members


## Saca a [param brain] de su grupo.
func leave_group(group: StringName, brain: HfsmBrain) -> void:
	var members: Array = _groups.get(group, [])
	members.erase(brain)
	if members.is_empty():
		_groups.erase(group)


## Cuántos miembros vivos tiene [param group] sin contar a [param except].
func count_alive_in_group(group: StringName, except: HfsmBrain) -> int:
	var total: int = 0
	for member: HfsmBrain in _groups.get(group, []):
		if member != except and member.is_alive():
			total += 1
	return total


## Avisa a los miembros del grupo [param group] que no están combatiendo y están a menos de [param radius] m de
## [param source] de que hay un enemigo ([param target_id]). Devuelve a cuántos ha avisado.
func alert_group(group: StringName, source: HfsmBrain, radius: float, target_id: int) -> int:
	var alerted: int = 0
	var origin: Vector3 = source.get_position()
	for member: HfsmBrain in _groups.get(group, []):
		if member == source or not member.is_alive():
			continue
		var offset: Vector3 = member.get_position() - origin
		offset.y = 0.0
		if offset.length() > radius:
			continue
		if member.receive_alert(target_id, tick):
			alerted += 1
	return alerted


## Quita los grupos y las fichas (al cerrar el servidor).
func clear() -> void:
	_groups.clear()
	tokens.clear()
	_candidates.clear()
	_candidates_tick = -1


func _rebuild_candidates() -> void:
	_candidates_tick = tick
	_candidates.clear()
	for candidate: Combatant in combat.get_sorted():
		if candidate.is_dead() or candidate.immortal or candidate.is_protected(tick):
			continue
		_candidates.append(candidate)


func _is_hostile(my_realm: int, other_realm: int) -> bool:
	var key: int = my_realm * 16 + other_realm
	if not _hostile_cache.has(key):
		_hostile_cache[key] = FactionRules.can_damage(my_realm, other_realm, zone_id)
	return _hostile_cache[key]
