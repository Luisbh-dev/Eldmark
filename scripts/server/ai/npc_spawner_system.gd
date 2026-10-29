class_name NpcSpawnerSystem
extends RefCounted
## Crea y retira los PNJ de los generadores ([NpcSpawner]) de la zona (docs/fuerte.md, sección 4.3; MUN-09 a
## MUN-12 y GUE-11) y lleva la navegación, el mundo de los cerebros y las fichas.
## [br][br]
## [b]Generadores.[/b] Cada [NpcSpawner] es un puesto con una condición: siempre ([constant NpcSpawner.Condition.ALWAYS],
## los Guardianes de la Puerta), mientras el fuerte es neutral (los Huecos y el Capitán del Vado) o mientras tiene
## dueño (la guarnición). Si un fuerte no tiene generadores propios del dueño, su guarnición sale de los mismos puestos
## de los Huecos y del Capitán, con la definición que cada una nombra en [member NpcDefinition.garrison_id] (guardias y
## capitán del reino dueño) y su misma ruta de patrulla. Un puesto con reaparición propia
## ([member NpcSpawner.respawn_s] mayor que 0) repone a su PNJ muerto en el tick exacto; uno sin ella lo repone la
## fortaleza ([signal FortressController.garrison_due], [signal FortressController.guards_respawn_due]) o la reaparición
## completa de los Huecos. Al pasar a inactivo, o al cambiar de dueño ([signal FortressController.defenders_retired]),
## se retira a los vivos.
## [br][br]
## [b]Fortaleza.[/b] Lee el estado con [method FortressController.get_fortress_state] y se lo cuenta con
## [method FortressController.register_captain] y [method FortressController.register_defender] (así el controlador sabe
## cuándo cae el capitán y cuándo se ataca a un defensor) y [method FortressController.set_guards_alive]. Los PNJ
## muertos avisan con [signal npc_died].
## [br][br]
## [b]Reaparición completa de los Huecos[/b] (MUN-10): con el fuerte neutral y faltando alguno de los Huecos o el
## Capitán, si no hay ningún jugador a menos de [constant FULL_RESPAWN_RADIUS] m del fuerte durante
## [constant FULL_RESPAWN_EMPTY_TICKS] ticks (2 min), vuelven todos (y el Capitán, si había caído).
## [br][br]
## [b]Tick.[/b] [method begin_tick] y los cerebros (paso 0), y [method step] (después del paso 4b: altas, retirada de
## cadáveres y depuración). Los avisos [code]TELEGRAPH[/code] de los ataques fuertes los manda el [ZoneServer]
## para todos los PNJ.

## Un PNJ ha muerto. [param spawner] es el generador del que salió (null en los refuerzos) y [param killer] el
## net_id de quien lo mató (0 = el entorno).
signal npc_died(net_id: int, spawner: Node, killer: int)
## Ha aparecido un PNJ de un generador.
signal npc_spawned(net_id: int, spawner: Node)

## Ticks que un cadáver sigue en el mundo antes de retirarse (5 s).
const CORPSE_TICKS: int = 300
## Ticks que se espera a la navegación antes de generar sin ella.
const NAVIGATION_WAIT_TICKS: int = 600
## Distancia (m) al fuerte a la que un jugador impide la reaparición completa, y ticks (2 min) que debe faltar.
const FULL_RESPAWN_RADIUS: float = 40.0
const FULL_RESPAWN_EMPTY_TICKS: int = 7200
## Cada cuántos ticks se comprueba la reaparición completa.
const FULL_RESPAWN_CHECK_TICKS: int = 6
## Cada cuántos ticks escribe la depuración de los PNJ, y radio (m) de los PNJ «cercanos».
const DEBUG_INTERVAL_TICKS: int = 60
const DEBUG_RADIUS: float = 60.0
## Distancia (m) a la que aparecen los refuerzos alrededor de quien los llama.
const REINFORCEMENT_RADIUS: float = 3.5

## Un PNJ creado por el sistema.
class Member:
	extends RefCounted

	var net_id: int = 0
	var brain: HfsmBrain = null
	var entity: NetEntity = null
	var slot: Slot = null
	var fortress_id: StringName = &""
	var definition: NpcDefinition = null
	## Tick de la muerte (-1 = vivo).
	var death_tick: int = -1


## Un puesto: un generador y lo que ha creado.
class Slot:
	extends RefCounted

	var index: int = 0
	var marker: Node3D = null
	var fortress_id: StringName = &""
	## true: es el puesto de la guarnición del dueño, sacado del de un PNJ de los Huecos.
	var mirror: bool = false
	var active: bool = false
	var need_fill: bool = false
	var last_definition: StringName = &""
	var last_realm: int = -1
	## El estado vivo de su fortaleza (null si no cuelga de ninguna) y la clave (dueño y fase) con la que se
	## calculó [member wanted]: solo se vuelve a calcular cuando cambia.
	var state: FortressState = null
	var state_key: int = -1
	var wanted: Dictionary = {}
	var spawn_count: int = 0
	var members: Array[Member] = []
	## Ticks en los que reaparecen los que han muerto (solo con reaparición propia).
	var due: PackedInt32Array = PackedInt32Array()

	func live_count() -> int:
		var total: int = 0
		for member: Member in members:
			if member.death_tick < 0:
				total += 1
		return total

var _server: ZoneServer = null
var _world_node: Node3D = null
var _world: NpcWorld = null
var _navigation: NpcNavigation = null
var _fortresses: FortressController = null
var _slots: Array[Slot] = []
# Los que no salen de un puesto (los refuerzos del Capitán).
var _extras: Array[Member] = []
var _members_by_id: Dictionary[int, Member] = {}
# Estado de la puerta que se le dijo a la navegación: id -> [dueño, rota].
var _gate_applied: Dictionary[StringName, Vector2i] = {}
# Cola de lo que avisa el controlador de la fortaleza (se atiende en step()).
var _retired: Array[StringName] = []
var _garrison_requests: Array[Dictionary] = []
var _guard_requests: Array[StringName] = []
var _empty_ticks: Dictionary[StringName, int] = {}
var _waited_ticks: int = 0
var _spawn_total: int = 0
var _death_total: int = 0
var _removed_total: int = 0
var _reinforcements_total: int = 0
var _full_respawns: int = 0
var _debug_enabled: bool = false
var _debug_entity: NetEntity = null
## [code](line: String) -> void[/code]: el registro del servidor, para la depuración.
var log_sink: Callable = Callable()


# --- Montaje ----------------------------------------------------------------------------------

## Lee los generadores de [param world] (la raíz de la zona, en el árbol), monta la navegación (si la zona tiene
## malla) y se engancha al combate y a las fortalezas de [param server]. Devuelve cuántos puestos ha creado.
func setup(server: ZoneServer, world: Node3D, zone_id: String) -> int:
	_server = server
	_world_node = world
	_fortresses = server.get_fortresses()
	_world = NpcWorld.new()
	_world.zone_id = StringName(zone_id)
	_world.combat = server.get_combat()
	_world.safe_areas = server.get_safe_areas()
	_world.space_provider = Callable(server, "get_physics_space")
	_world.teleporter = Callable(server, "teleport")
	_world.reinforcer = Callable(self, "_spawn_reinforcements")
	_setup_navigation(zone_id)
	_world.navigation = _navigation
	_collect_slots()
	_world.combat.event_emitted.connect(_on_combat_event)
	if _fortresses != null:
		_fortresses.defenders_retired.connect(_on_defenders_retired)
		_fortresses.garrison_due.connect(_on_garrison_due)
		_fortresses.guards_respawn_due.connect(_on_guards_respawn_due)
	return _slots.size()


## Quita los PNJ, las fichas y la navegación (cierre del servidor).
func dispose() -> void:
	for member: Member in _members_by_id.values():
		if member.brain != null:
			member.brain.unbind()
	_members_by_id.clear()
	_slots.clear()
	_extras.clear()
	if _world != null:
		_world.clear()
	if _navigation != null:
		_navigation.dispose()
		_navigation = null


# --- Consultas --------------------------------------------------------------------------------

## El mundo que ven los cerebros (fichas, grupos, navegación).
func get_world() -> NpcWorld:
	return _world


## La navegación (null si la zona no tiene malla).
func get_navigation() -> NpcNavigation:
	return _navigation


## Número de puestos.
func get_slot_count() -> int:
	return _slots.size()


## Los generadores (nodos) de la zona, en el orden en que se crearon los puestos.
func get_spawners() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for slot: Slot in _slots:
		result.append(slot.marker)
	return result


## net_id de los PNJ vivos del generador [param spawner] (o de todos si es null), en el orden de aparición.
func get_alive_ids(spawner: Node = null) -> Array[int]:
	var ids: Array[int] = []
	for slot: Slot in _slots:
		if spawner != null and slot.marker != spawner:
			continue
		for member: Member in slot.members:
			if member.death_tick < 0:
				ids.append(member.net_id)
	if spawner == null:
		for member: Member in _extras:
			if member.death_tick < 0:
				ids.append(member.net_id)
	return ids


## net_id de todos los PNJ del sistema (vivos y cadáveres) que cuelgan del generador [param spawner].
func get_member_ids(spawner: Node) -> Array[int]:
	var ids: Array[int] = []
	for slot: Slot in _slots:
		if slot.marker == spawner:
			for member: Member in slot.members:
				ids.append(member.net_id)
	return ids


## El cerebro del PNJ [param net_id] (también el de un PNJ suelto que no sale de ningún generador), o null.
func get_brain(net_id: int) -> HfsmBrain:
	var member: Member = _members_by_id.get(net_id)
	if member != null:
		return member.brain
	return _server.get_npc_brain(net_id) as HfsmBrain if _server != null else null


## Cuántos PNJ del sistema hay vivos.
func get_alive_count() -> int:
	var total: int = 0
	for member: Member in _members_by_id.values():
		if member.death_tick < 0:
			total += 1
	return total


## true si el puesto del generador [param spawner] está activo ahora.
func is_active(spawner: Node) -> bool:
	for slot: Slot in _slots:
		if slot.marker == spawner:
			return slot.active
	return false


## true si la navegación está lista o la zona no tiene.
func is_ready() -> bool:
	return _navigation == null or _navigation.is_ready()


## Resumen para el informe del servidor.
func get_report() -> Dictionary:
	return {
		"slots": _slots.size(), "alive": get_alive_count(), "spawned": _spawn_total, "died": _death_total,
		"removed": _removed_total, "reinforcements": _reinforcements_total,
		"full_respawns": _full_respawns,
		"tokens": _world.tokens.get_stats() if _world != null else {},
		"paths": _navigation.get_paths_computed() if _navigation != null else 0,
		"navigation": _navigation != null and _navigation.is_ready(),
		"queries": _world.queries if _world != null else 0,
		"line_of_sight_checks": _world.line_of_sight_checks if _world != null else 0,
	}


# --- El tick ----------------------------------------------------------------------------------

## Paso 0 del tick [param tick]: los cerebros van a pensar con el estado tras el tick anterior.
func begin_tick(tick: int) -> void:
	if _world != null:
		_world.begin_tick(tick)


## Después del paso 4b del tick [param tick]: navegación, altas y retiradas, cadáveres, avisos de ataques fuertes y
## depuración.
func step(tick: int) -> void:
	if _world == null:
		return
	if _navigation != null and not _navigation.poll():
		_waited_ticks += 1
		if _waited_ticks < NAVIGATION_WAIT_TICKS:
			return
	_sync_gates()
	_process_requests(tick)
	for slot: Slot in _slots:
		_step_slot(slot, tick)
	_remove_corpses(tick)
	if tick % FULL_RESPAWN_CHECK_TICKS == 0:
		_check_full_respawns(tick)
	if _debug_enabled and tick % DEBUG_INTERVAL_TICKS == 0:
		_write_debug()


# --- Generadores ------------------------------------------------------------------------------

func _collect_slots() -> void:
	var neutral_by_fortress: Dictionary[StringName, Array] = {}
	var owner_spawner_fortresses: Dictionary[StringName, bool] = {}
	var spawners: Array[NpcSpawner] = []
	for node: Node3D in NetZones.get_npc_spawners(_world_node):
		var spawner: NpcSpawner = node as NpcSpawner
		if spawner != null:
			spawners.append(spawner)
	for spawner: NpcSpawner in spawners:
		var fortress_id: StringName = _fortress_id_of(spawner)
		_add_slot(spawner, fortress_id, false)
		if spawner.condition == NpcSpawner.Condition.FORT_OWNER:
			owner_spawner_fortresses[fortress_id] = true
		elif spawner.condition == NpcSpawner.Condition.FORT_NEUTRAL:
			var list: Array = neutral_by_fortress.get(fortress_id, [])
			list.append(spawner)
			neutral_by_fortress[fortress_id] = list
	# Sin generadores propios del dueño, su guarnición sale de los puestos de los Huecos.
	for fortress_id: StringName in neutral_by_fortress:
		if fortress_id.is_empty() or owner_spawner_fortresses.has(fortress_id):
			continue
		for spawner: NpcSpawner in neutral_by_fortress[fortress_id]:
			var base: NpcDefinition = NpcCatalog.get_definition(spawner.npc_id)
			if base != null and base.garrison_id != &"":
				_add_slot(spawner, fortress_id, true)


func _add_slot(spawner: NpcSpawner, fortress_id: StringName, mirror: bool) -> void:
	var slot := Slot.new()
	slot.index = _slots.size()
	slot.marker = spawner
	slot.fortress_id = fortress_id
	slot.mirror = mirror
	if _fortresses != null and not fortress_id.is_empty():
		slot.state = _fortresses.get_fortress_state(fortress_id)
	_slots.append(slot)


# Id de la fortaleza de la que cuelga el generador, o una cadena vacía.
func _fortress_id_of(spawner: NpcSpawner) -> StringName:
	if _fortresses == null:
		return &""
	var node: Node = spawner.get_fortress()
	if node == null:
		return &""
	for fortress_id: StringName in _fortresses.get_fortress_ids():
		if _fortresses.get_node_of(fortress_id) == node:
			return fortress_id
	return &""


# Lo que quiere el puesto ahora: si está activo, qué definición y de qué bando.
func _desired(slot: Slot) -> Dictionary:
	var spawner: NpcSpawner = slot.marker as NpcSpawner
	var state: FortressState = _fortresses.get_fortress_state(slot.fortress_id) \
			if _fortresses != null and not slot.fortress_id.is_empty() else null
	var definition_id: StringName = spawner.npc_id
	var realm: int = RealmCatalog.code_of(spawner.realm) if spawner.realm != &"" else RealmCatalog.NEUTRAL_CODE
	var active: bool = false
	if slot.mirror:
		var base: NpcDefinition = NpcCatalog.get_definition(spawner.npc_id)
		if state != null and base != null and state.owner != RealmCatalog.NEUTRAL_CODE \
				and state.phase != FortressState.Phase.CONSOLIDATING:
			active = true
			definition_id = base.garrison_id
			realm = state.owner
	else:
		match spawner.condition:
			NpcSpawner.Condition.ALWAYS:
				active = true
			NpcSpawner.Condition.FORT_NEUTRAL:
				active = state != null and state.owner == RealmCatalog.NEUTRAL_CODE
				realm = RealmCatalog.NEUTRAL_CODE if spawner.realm == &"" else realm
			NpcSpawner.Condition.FORT_OWNER:
				active = state != null and state.owner != RealmCatalog.NEUTRAL_CODE \
						and state.phase != FortressState.Phase.CONSOLIDATING
				if state != null:
					realm = state.owner
	return {"active": active, "definition": definition_id, "realm": realm}


func _step_slot(slot: Slot, tick: int) -> void:
	var key: int = slot.state.owner * 8 + slot.state.phase if slot.state != null else 0
	if key != slot.state_key or slot.wanted.is_empty():
		slot.state_key = key
		slot.wanted = _desired(slot)
	var wanted: Dictionary = slot.wanted
	var active: bool = wanted["active"]
	var changed: bool = active and slot.active and (slot.last_definition != wanted["definition"]
			or slot.last_realm != wanted["realm"])
	if slot.active and (not active or changed):
		_retire_slot(slot, tick)
	if active and (not slot.active or changed):
		slot.need_fill = true
	slot.active = active
	slot.last_definition = wanted["definition"]
	slot.last_realm = wanted["realm"]
	if not active:
		return
	if slot.need_fill:
		slot.need_fill = false
		_fill_slot(slot, tick)
	# Reaparición propia (en el tick exacto).
	var index: int = 0
	while index < slot.due.size():
		if slot.due[index] <= tick:
			slot.due.remove_at(index)
			if slot.live_count() < (slot.marker as NpcSpawner).max_alive:
				_spawn(slot, tick)
		else:
			index += 1


# Crea los PNJ que faltan hasta el máximo del puesto.
func _fill_slot(slot: Slot, tick: int) -> void:
	var spawner: NpcSpawner = slot.marker as NpcSpawner
	while slot.live_count() < spawner.max_alive:
		if _spawn(slot, tick) == null:
			break
	slot.due.clear()
	_update_guards(slot.fortress_id)


func _spawn(slot: Slot, tick: int) -> Member:
	var wanted: Dictionary = slot.wanted if not slot.wanted.is_empty() else _desired(slot)
	var definition: NpcDefinition = NpcCatalog.get_definition(wanted["definition"])
	if definition == null:
		push_warning("[Eldmark] El generador '%s' pide la definición de PNJ '%s', que no existe"
				% [slot.marker.name, wanted["definition"]])
		return null
	var spawner: NpcSpawner = slot.marker as NpcSpawner
	var transform: Transform3D = spawner.global_transform
	var yaw: float = _yaw_of(transform)
	var route: PackedVector3Array = NetZones.get_patrol_route(_world_node, spawner.patrol_route)
	var member: Member = _create_member(definition, wanted["realm"], transform.origin, yaw,
			slot.fortress_id, spawner.alert_group, route, (slot.index + 1) * 7919 + slot.spawn_count * 104729)
	if member == null:
		return null
	slot.spawn_count += 1
	member.slot = slot
	slot.members.append(member)
	npc_spawned.emit(member.net_id, spawner)
	return member


# Crea el PNJ de [param definition] y lo registra. null si el servidor no puede (sin ids, parado).
func _create_member(definition: NpcDefinition, realm: int, position: Vector3, yaw: float,
		fortress_id: StringName, group: StringName, route: PackedVector3Array, rng_seed: int) -> Member:
	var brain := HfsmBrain.new(rng_seed)
	var net_id: int = _server.add_npc(brain, definition.display_name, realm, position, yaw, false, definition)
	if net_id <= 0:
		return null
	var entity: NetEntity = _server.get_registry().get_entity(net_id)
	var combatant: Combatant = _server.get_combat().get_combatant(net_id)
	brain.bind(_world, entity, combatant, definition, position, yaw, route, group)
	var member := Member.new()
	member.net_id = net_id
	member.brain = brain
	member.entity = entity
	member.definition = definition
	member.fortress_id = fortress_id
	brain.owner_slot = member
	_members_by_id[net_id] = member
	_spawn_total += 1
	if _fortresses != null and not fortress_id.is_empty():
		if definition.is_boss:
			_fortresses.register_captain(fortress_id, net_id)
		else:
			_fortresses.register_defender(fortress_id, net_id)
	return member


# Retira a todos los PNJ del puesto (vivos y cadáveres).
func _retire_slot(slot: Slot, _tick: int) -> void:
	for member: Member in slot.members.duplicate():
		_remove_member(member)
	slot.members.clear()
	slot.due.clear()
	_update_guards(slot.fortress_id)


func _remove_member(member: Member) -> void:
	member.brain.unbind()
	_members_by_id.erase(member.net_id)
	if _fortresses != null and not member.fortress_id.is_empty():
		_fortresses.unregister_defender(member.fortress_id, member.net_id)
	_server.remove_npc(member.net_id)
	_removed_total += 1


# Dice a la fortaleza cuántos guardias de su guarnición (los que no son el capitán) hay vivos; solo tiene
# sentido con dueño.
func _update_guards(fortress_id: StringName) -> void:
	if _fortresses == null or fortress_id.is_empty():
		return
	var state: FortressState = _fortresses.get_fortress_state(fortress_id)
	if state == null or state.owner == RealmCatalog.NEUTRAL_CODE:
		return
	var alive: int = 0
	for slot: Slot in _slots:
		if slot.fortress_id != fortress_id or not slot.active:
			continue
		for member: Member in slot.members:
			if member.death_tick < 0 and not member.definition.is_boss:
				alive += 1
	_fortresses.set_guards_alive(fortress_id, alive)


func _remove_corpses(tick: int) -> void:
	for slot: Slot in _slots:
		_remove_corpses_of(slot.members, tick)
	_remove_corpses_of(_extras, tick)


func _remove_corpses_of(members: Array[Member], tick: int) -> void:
	var index: int = 0
	while index < members.size():
		var member: Member = members[index]
		if member.death_tick >= 0 and tick - member.death_tick >= CORPSE_TICKS:
			members.remove_at(index)
			_remove_member(member)
		else:
			index += 1


# --- Lo que cuenta el combate y la fortaleza -----------------------------------------------------

func _on_combat_event(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
	if event.event != NetMessages.EntityEvent.Kind.DEATH:
		return
	var member: Member = _members_by_id.get(event.net_id)
	if member == null or member.death_tick >= 0:
		return
	member.death_tick = event.tick
	member.brain.unbind()
	_death_total += 1
	var slot: Slot = member.slot
	if slot != null:
		var spawner: NpcSpawner = slot.marker as NpcSpawner
		var ticks: int = spawner.get_respawn_ticks()
		if ticks > 0:
			slot.due.append(event.tick + ticks)
		_update_guards(slot.fortress_id)
	npc_died.emit(member.net_id, slot.marker if slot != null else null, event.killer)


func _on_defenders_retired(fortress_id: StringName, _tick: int) -> void:
	_retired.append(fortress_id)


func _on_garrison_due(fortress_id: StringName, _owner_realm: int, _tick: int, full: bool) -> void:
	_garrison_requests.append({"fortress": fortress_id, "full": full})


func _on_guards_respawn_due(fortress_id: StringName, _tick: int) -> void:
	_guard_requests.append(fortress_id)


# Atiende lo que ha avisado el controlador en este tick.
func _process_requests(tick: int) -> void:
	for fortress_id: StringName in _retired:
		for slot: Slot in _slots:
			if slot.fortress_id == fortress_id and slot.active:
				_retire_slot(slot, tick)
				slot.need_fill = true
		for member: Member in _extras.duplicate():
			if member.fortress_id == fortress_id:
				_extras.erase(member)
				_remove_member(member)
	_retired.clear()
	for request: Dictionary in _garrison_requests:
		for slot: Slot in _slots:
			if slot.fortress_id != request["fortress"]:
				continue
			var captain_slot: bool = _is_captain_slot(slot)
			if request["full"] or captain_slot:
				slot.need_fill = true
	_garrison_requests.clear()
	for fortress_id: StringName in _guard_requests:
		for slot: Slot in _slots:
			if slot.fortress_id == fortress_id and slot.active and not _is_captain_slot(slot):
				slot.need_fill = true
	_guard_requests.clear()


# true si el puesto es el del capitán (su definición es un jefe).
func _is_captain_slot(slot: Slot) -> bool:
	var definition: NpcDefinition = NpcCatalog.get_definition(_desired(slot)["definition"])
	return definition != null and definition.is_boss


# --- Reaparición completa de los Huecos -----------------------------------------------------------

func _check_full_respawns(tick: int) -> void:
	if _fortresses == null:
		return
	for fortress_id: StringName in _fortresses.get_fortress_ids():
		var state: FortressState = _fortresses.get_fortress_state(fortress_id)
		if state == null or state.owner != RealmCatalog.NEUTRAL_CODE:
			_empty_ticks.erase(fortress_id)
			continue
		if not _neutral_garrison_incomplete(fortress_id, state):
			_empty_ticks.erase(fortress_id)
			continue
		var center: Vector3 = _fortresses.get_circle(fortress_id)["center"]
		if _player_within(center, FULL_RESPAWN_RADIUS):
			_empty_ticks[fortress_id] = 0
			continue
		var empty: int = int(_empty_ticks.get(fortress_id, 0)) + FULL_RESPAWN_CHECK_TICKS
		_empty_ticks[fortress_id] = empty
		if empty >= FULL_RESPAWN_EMPTY_TICKS:
			_empty_ticks[fortress_id] = 0
			_full_respawn(fortress_id, state, tick)


# true si al fuerte neutral le falta alguno de los Huecos o el Capitán.
func _neutral_garrison_incomplete(fortress_id: StringName, state: FortressState) -> bool:
	if not state.captain_alive:
		return true
	for slot: Slot in _slots:
		if slot.fortress_id != fortress_id or slot.mirror or not slot.active:
			continue
		if slot.live_count() < (slot.marker as NpcSpawner).max_alive:
			return true
	return false


func _player_within(center: Vector3, radius: float) -> bool:
	var radius_squared: float = radius * radius
	for entity: NetEntity in _server.get_registry().get_sorted():
		if entity.kind != NetProtocol.EntityKind.PLAYER:
			continue
		var offset: Vector3 = entity.get_position() - center
		if offset.x * offset.x + offset.z * offset.z <= radius_squared:
			return true
	return false


## Hace volver a todos los Huecos y al Capitán del Vado de [param fortress_id] (si el fuerte es neutral). Lo hace
## solo la regla de los 2 min sin jugadores cerca; está público para las pruebas y las órdenes de administración.
func force_full_respawn(fortress_id: StringName, tick: int) -> bool:
	var state: FortressState = _fortresses.get_fortress_state(fortress_id) if _fortresses != null else null
	if state == null or state.owner != RealmCatalog.NEUTRAL_CODE:
		return false
	_full_respawn(fortress_id, state, tick)
	return true


func _full_respawn(fortress_id: StringName, state: FortressState, tick: int) -> void:
	_full_respawns += 1
	# El Capitán vuelve con la fortaleza: su estado pasa de VULNERABLE a GARRISONED.
	state.respawn_captain(tick)
	for slot: Slot in _slots:
		if slot.fortress_id == fortress_id and not slot.mirror and slot.active:
			slot.need_fill = true


# --- Refuerzos y avisos ----------------------------------------------------------------------------

# Crea [param count] PNJ de [param definition_id] alrededor de [param caller], ya en alerta con su objetivo. Devuelve
# cuántos ha creado.
func _spawn_reinforcements(caller: HfsmBrain, definition_id: StringName, count: int) -> int:
	var definition: NpcDefinition = NpcCatalog.get_definition(definition_id)
	if definition == null:
		return 0
	var origin: Vector3 = caller.get_position()
	var created: int = 0
	for index: int in count:
		var angle: float = TAU * float(index) / float(maxi(count, 1)) + 0.5
		var position: Vector3 = origin + Vector3(cos(angle), 0.0, sin(angle)) * REINFORCEMENT_RADIUS
		var member: Member = _create_member(definition, caller.get_realm(), position, angle + PI,
				_member_fortress(caller), caller.get_group(), PackedVector3Array(),
				900001 + _reinforcements_total * 7919)
		if member == null:
			continue
		_extras.append(member)
		_reinforcements_total += 1
		created += 1
		member.brain.receive_alert(caller.get_target_id(), _world.tick)
	return created


func _member_fortress(brain: HfsmBrain) -> StringName:
	var member: Member = brain.owner_slot as Member
	return member.fortress_id if member != null else &""


# --- Navegación -------------------------------------------------------------------------------

func _setup_navigation(zone_id: String) -> void:
	var path: String = NetZones.navmesh_path(zone_id)
	if path.is_empty():
		return
	var navmesh: NavigationMesh = ResourceLoader.load(path) as NavigationMesh
	if navmesh == null:
		push_warning("[Eldmark] No se pudo cargar la malla de navegación %s" % path)
		return
	var navigation := NpcNavigation.new()
	if not navigation.setup(navmesh):
		return
	_navigation = navigation
	if _fortresses == null:
		return
	for fortress_id: StringName in _fortresses.get_fortress_ids():
		var gate: Node3D = _fortresses.get_gate(fortress_id)
		if gate != null:
			_navigation.add_gate_link_at(fortress_id, gate.global_transform)


# Pone en la navegación el dueño y la rotura de cada puerta (solo cuando cambian).
func _sync_gates() -> void:
	if _navigation == null or _fortresses == null:
		return
	for fortress_id: StringName in _fortresses.get_fortress_ids():
		var state: FortressState = _fortresses.get_fortress_state(fortress_id)
		var applied := Vector2i(state.owner, 1 if state.is_gate_broken() else 0)
		if _gate_applied.get(fortress_id, Vector2i(-1, -1)) != applied:
			_gate_applied[fortress_id] = applied
			_navigation.set_gate_state(fortress_id, state.owner, state.is_gate_broken())


# --- Depuración ---------------------------------------------------------------------------------

## Registra los comandos de los PNJ en [param commands]: [code]npc_debug[/code] (id fijo 12).
func register_commands(commands: CommandRegistry) -> void:
	commands.register(&"npc_debug", "npc_debug [on|off]", _console_debug, _net_debug)


func _net_debug(ctx: CommandRegistry.Context) -> int:
	if ctx.payload.size() != 1 or ctx.payload[0] > 1:
		return CommandRegistry.Result.BAD_ARGUMENTS
	_debug_enabled = ctx.payload[0] == 1
	_debug_entity = ctx.peer.entity if ctx.peer != null and _debug_enabled else null
	ctx.note = "activado" if _debug_enabled else "apagado"
	return CommandRegistry.Result.OK


func _console_debug(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() > 1:
		return "Uso: npc_debug [on|off]"
	if ctx.args.is_empty():
		_debug_enabled = not _debug_enabled
	else:
		var text: String = ctx.args[0].to_lower()
		if text != "on" and text != "off":
			return "Uso: npc_debug [on|off]"
		_debug_enabled = text == "on"
	_debug_entity = null
	return "Depuración de PNJ %s" % ("activada" if _debug_enabled else "apagada")


## true si la depuración de los PNJ está encendida.
func is_debug_enabled() -> bool:
	return _debug_enabled


# Una línea por PNJ con cerebro de combate (los cercanos a quien lo pidió, o todos) con su estado, objetivo y ruta.
func _write_debug() -> void:
	if not log_sink.is_valid():
		return
	var center: Vector3 = Vector3.ZERO
	var filtered: bool = _debug_entity != null and is_instance_valid(_debug_entity.node)
	if filtered:
		center = _debug_entity.get_position()
	for net_id: int in _server.get_npc_ids():
		var brain: HfsmBrain = _server.get_npc_brain(net_id) as HfsmBrain
		if brain == null or not brain.is_alive():
			continue
		if filtered and brain.get_position().distance_to(center) > DEBUG_RADIUS:
			continue
		log_sink.call("PNJ " + brain.describe())


static func _yaw_of(transform: Transform3D) -> float:
	var forward: Vector3 = -transform.basis.z
	return atan2(-forward.x, -forward.z)
