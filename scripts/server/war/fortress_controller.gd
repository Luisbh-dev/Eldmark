class_name FortressController
extends RefCounted
## Las fortalezas de una zona en el servidor (docs/fuerte.md, secciones 1.6, 1.7, 2 y 3; GUE-08,
## GUE-10, GUE-12 y GUE-13). Por cada nodo del grupo [code]fortresses[/code] con el metadato
## [code]definition[/code] crea una [NetEntity] [code]STRUCTURE[/code] con
## [constant NetEntity.FLAG_ALWAYS_RELEVANT] y lleva su [FortressState].
## [br][br]
## [b]Cada tick[/b] ([method step], paso 4b del orden del tick, después del combate): cada 6 ticks
## recuenta la presencia en el círculo ([FortressPresence]), avanza el estado ([method
## FortressState.advance], que corre cada tick para que las transiciones caigan en el tick exacto) y
## aplica sus efectos:
## [br]- el dueño y la rotura de la puerta pasan a las capas de colisión de los dos cuerpos de la
## puerta ([method FortGate.set_state]); el cambio vale [b]desde s + 1[/b], en el servidor y en el
## cliente;
## [br]- la puerta se repara al cambiar de dueño, con [code]fort_reset[/code] o tras
## [member FortressDefinition.gate_repair_after_s] sin daño, pero [b]no mientras un personaje solape el
## vano[/b]: el estado conserva la vida rota y la reparación se aplaza tick a tick hasta que quede libre;
## [br]- los avisos de guerra salen por [signal war_event_emitted] en el orden en que ocurren y el
## estado por [signal object_state_emitted] como OBJECT_STATE.
## [br][br]
## [b]OBJECT_STATE[/b]: como mucho uno por fortaleza cada 6 ticks, con los campos que han cambiado
## desde el último; [code]under_attack_until_tick[/code] solo si avanza al menos 60 ticks. Si lo que cambia
## es la colisión de la puerta (dueño o rotura) sale [b]en ese mismo tick[/b], sin esperar al intervalo:
## el cliente pone la capa de la puerta según el tick de cada cambio, y retrasarlo desfasaría la
## predicción (docs/fuerte.md, sección 3.2). El alta ([method NetEntity.encode_spawn]) lleva el estado
## completo.
## [br][br]
## [b]La puerta como blanco[/b] ([StructureTarget], docs/fuerte.md 3.3): los golpes los resuelve el
## [CombatResolver] y los aplica el [CombatDirector], que avisa con [signal CombatDirector.structure_hit]
## a [method on_structure_hit]; aquí se resta la vida, se avisa y se anota para el marcador.
## [br][br]
## [b]Interfaz con los PNJ (paquete F4)[/b]:
## [br]- [method get_fortress_state] da el [FortressState] vivo (dueño, fase, capitán, guardias...).
## [br]- [method on_captain_died] cuando muere el capitán (el de los Huecos o el del dueño), y
## [method set_guards_alive] con los guardias vivos. [method register_captain] y
## [method register_defender] dejan que el controlador lo note solo por los DEATH y HIT del combate.
## [br]- Las señales [signal defenders_retired] (se retiran los PNJ del dueño anterior o de los Huecos),
## [signal garrison_due] (aparece la guarnición y el capitán del dueño actual; [code]full[/code] es false
## si solo reaparece el capitán) y [signal guards_respawn_due] (toca reponer los guardias que faltan).
## Al arrancar, el fuerte es neutral y está guardado por los Huecos y su Capitán: no hay señal, el
## generador de PNJ lo lee de [method get_fortress_state].
## [br][br]
## [b]Guerra persistente[/b] (docs/plataforma.md §8, GUE-19): [method restore_state] pone el estado cargado de la
## plataforma al arrancar ([FortressPersistence]); en cada captura de verdad, la lista de quien estaba en el círculo
## (del reino captor, presente, vivo y conectado, sin personajes marcados con [member NetEntity.gm_forced]) suma
## [code]captures[/code] en el [ScoreKeeper] y sale por [signal fortress_captured]; y los del reino dueño presentes
## con el círculo activo suman [code]defend_ticks[/code]. [b]Cambio forzado[/b] (docs/progresion.md §6.2): lo que
## provoca un comando del fuerte ([code]fort_owner[/code], [code]fort_reset[/code], [code]fort_kill_captain[/code],
## una captura con [member FortressState.capture_rate_multiplier] distinto de 1) no suma capturas ni tiempo
## defendiendo y [method is_forced] lo dice a quien paga recompensas (progresion.md P5c). Las recompensas
## (progresion.md §6.2) salen de [signal fortress_captured] (la captura), [signal objective_time] (el tiempo en el
## círculo activo de un ciclo de verdad: los méritos de objetivo) y [method fortress_of_defender] (de qué fortaleza
## era el PNJ que muere).
## [br][br]
## No toca la red ni el reloj: avisa con señales y recibe de quien lo lleva ([ZoneServer]) los
## candidatos a la presencia, los cuerpos que pueden ocupar el vano y cómo matar al capitán.

## Un aviso de guerra (ENTITY_EVENT [code]WAR[/code]) que hay que mandar a toda la zona.
signal war_event_emitted(event: NetMessages.EntityEvent)
## Un OBJECT_STATE que hay que mandar a toda la zona.
signal object_state_emitted(object_state: NetMessages.ObjectState)
## La fortaleza cambia de manos o se reinicia: hay que retirar a los PNJ defensores que había.
signal defenders_retired(fortress_id: StringName, tick: int)
## La fortaleza vuelve a estar GARRISONED: hay que hacer aparecer a la guarnición y al capitán de
## [param owner_realm] (los Huecos y el Capitán del Vado con el fuerte neutral). Con [param full] false
## solo reaparece el capitán (la guarnición sigue en pie).
signal garrison_due(fortress_id: StringName, owner_realm: int, tick: int, full: bool)
## Han pasado los segundos de reaparición de los guardias que faltan: hay que reponerlos y avisar con
## [method set_guards_alive].
signal guards_respawn_due(fortress_id: StringName, tick: int)
## Alguien golpea por primera vez la puerta entera de la fortaleza (para la telemetría).
signal gate_damage_started(fortress_id: StringName, tick: int)
## [param fortress_id] ha pasado a [param owner_realm] por una captura de verdad (no forzada) en el tick
## [param tick]: [param in_circle] es la lista de docs/plataforma.md §8 (los net_id del reino captor presentes, vivos
## y conectados en el círculo en ese tick, sin [member NetEntity.gm_forced]), la misma que ya ha sumado
## [code]captures[/code] en el [ScoreKeeper]. Una captura forzada no sale (progresion.md §6.2): aquí se conecta
## [code]ProgressService.on_capture[/code] (progresion.md P5c).
signal fortress_captured(fortress_id: StringName, owner_realm: int, in_circle: PackedInt32Array, tick: int)
## [param ticks] más de [param net_id] en el círculo activo de [param fortress_id] (cada recuento, en el tick
## [param tick]), de un ciclo de verdad y sin [member NetEntity.gm_forced]: el tiempo que da los méritos de objetivo
## (docs/progresion.md §6.2; aquí se conecta [code]ProgressService.on_objective_ticks[/code], P5c). Cuenta a todos los
## reinos presentes, como [code]circle_ticks[/code] del marcador, pero no en un ciclo forzado.
signal objective_time(fortress_id: StringName, net_id: int, ticks: int, tick: int)

## Ticks entre dos OBJECT_STATE de una misma fortaleza.
const OBJECT_STATE_INTERVAL_TICKS: int = 6
## Lo que debe avanzar [code]under_attack_until_tick[/code] para que merezca un OBJECT_STATE.
const UNDER_ATTACK_MIN_ADVANCE_TICKS: int = 60
## Hijos del nodo de la fortaleza que usa el controlador.
const CIRCLE_NODE: NodePath = ^"CaptureCircle"
const GATE_NODE: NodePath = ^"FortGate"
## Metadato del círculo con su radio y radio por defecto si falta.
const CIRCLE_RADIUS_META: StringName = &"radius"
const DEFAULT_CIRCLE_RADIUS: float = 5.0

## Marcador de la batalla (null = no se lleva): el controlador suma el tiempo en el círculo y el daño a
## la puerta.
var score_keeper: ScoreKeeper = null
## [code](tick: int) -> Array[PlayerCandidate][/code]: los jugadores que pueden contar en el círculo
## (solo jugadores: los PNJ no cuentan). Se llama cada 6 ticks.
var candidates_source: Callable = Callable()
## [code]() -> PackedVector3Array[/code]: los pies de los personajes (jugadores y PNJ vivos) que pueden
## ocupar el vano de la puerta. Solo se llama cuando hay una reparación en espera.
var bodies_source: Callable = Callable()
## [code](net_id: int) -> bool[/code]: mata al PNJ capitán registrado ([method register_captain]). Si
## no es válido (o devuelve false), [method kill_captain] da por muerto al capitán directamente.
var captain_killer: Callable = Callable()

var _registry: NetEntityRegistry = null
var _sites: Array[Site] = []
var _sites_by_id: Dictionary[StringName, Site] = {}
var _sites_by_net_id: Dictionary[int, Site] = {}
# Tick de la siguiente orden de depuración (se pone en register_commands).
var _next_tick_source: Callable = Callable()


## Un jugador candidato a contar en el círculo: lo de [FortressPresence.Candidate] más el id de red.
class PlayerCandidate:
	extends FortressPresence.Candidate

	var net_id: int = 0
	## Marcado por un comando de GM ([member NetEntity.gm_forced]): cuenta en la presencia, pero no entra en la
	## lista de capturas ni suma tiempo defendiendo.
	var gm_forced: bool = false


	static func make_player(player_id: int, realm_code: int, feet_position: Vector3,
			input_tick: int) -> PlayerCandidate:
		var candidate := PlayerCandidate.new()
		candidate.net_id = player_id
		candidate.realm = realm_code
		candidate.feet = feet_position
		candidate.last_input_tick = input_tick
		return candidate


## Lo que el controlador sabe de una fortaleza.
class Site:
	extends RefCounted

	var id: StringName = &""
	var definition: FortressDefinition = null
	var node: Node3D = null
	var entity: NetEntity = null
	var state: FortressState = null
	var circle_center: Vector3 = Vector3.ZERO
	var circle_radius: float = DEFAULT_CIRCLE_RADIUS
	var gate: FortGate = null
	var target: StructureTarget = null
	# Presencia del último recuento (se mantiene entre recuentos).
	var presence: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
	# Lo que los clientes saben (los campos enviados) y cuándo se envió.
	var last_sent: FortressState = null
	var last_sent_tick: int = 0
	# Dueño y rotura con los que se mandó el último OBJECT_STATE: la colisión que ven los clientes.
	var sent_owner: int = 0
	var sent_broken: bool = false
	# Dueño y rotura que tienen ahora las capas de la puerta.
	var applied_owner: int = 0
	var applied_broken: bool = false
	# true mientras una reparación espera a que el vano quede libre.
	var repair_pending: bool = false
	# PNJ capitán registrado (0 = ninguno) y reino de quien ha pedido matarlo (-1 = nadie).
	var captain_net_id: int = 0
	var pending_killer_realm: int = -1
	# PNJ defensores registrados: net_id -> true.
	var defenders: Dictionary[int, bool] = {}
	# Ya se avisó de que toca reponer los guardias (hasta el próximo set_guards_alive).
	var guards_due_notified: bool = false
	# Ya se avisó del primer golpe a la puerta desde su última reparación.
	var gate_damage_announced: bool = false
	# El ciclo actual viene de un comando del fuerte (progresion.md §6.2): fort_owner, fort_reset,
	# fort_kill_captain o fort_capture_speed distinto de 1. Lo quita el siguiente cambio de verdad: la muerte del
	# capitán en combate, la vuelta a GARRISONED por sí sola o el reinicio periódico.
	var forced: bool = false
	# Fin de la consolidación cargada de la plataforma ([constant FortressState.NO_TICK] si no hay): el estado no
	# guarda el fin, sino el inicio, que no puede ser negativo en OBJECT_STATE (restore_state).
	var consolidation_ends_tick: int = FortressState.NO_TICK


# --- Alta de fortalezas --------------------------------------------------------------------------

## Crea las fortalezas de [param world] (los nodos del grupo [code]fortresses[/code] con su
## definición) con el estado «tras [param tick]». Cada una pide su [NetEntity] a [param registry].
## Devuelve cuántas ha creado.
func setup(world: Node3D, registry: NetEntityRegistry, tick: int) -> int:
	_registry = registry
	for node: Node3D in NetZones.get_fortress_nodes(world):
		var definition: FortressDefinition = _definition_of(node)
		if definition == null:
			push_warning("[Eldmark] La fortaleza '%s' no tiene una definición válida" % node.name)
			continue
		add_fortress(node, definition, tick)
	return _sites.size()


## Añade la fortaleza del nodo [param node] con la definición [param definition] (el nodo debe estar
## en el árbol: sus hijos [code]CaptureCircle[/code] y [code]FortGate[/code] dan el círculo y la
## puerta). Devuelve su id de red, o 0 si ya hay otra con ese id, el id no cabe en el protocolo o no
## queda ningún id de red.
func add_fortress(node: Node3D, definition: FortressDefinition, tick: int) -> int:
	var fortress_id: StringName = definition.id
	if _sites_by_id.has(fortress_id) or fortress_id.is_empty() \
			or fortress_id.length() > NetProtocol.MAX_DEFINITION_ID_BYTES \
			or not NetMessages.is_printable_ascii_text(String(fortress_id)):
		push_warning("[Eldmark] Fortaleza con un id no válido o repetido: '%s'" % fortress_id)
		return 0
	var entity: NetEntity = _registry.allocate(NetProtocol.EntityKind.STRUCTURE, tick)
	if entity == null:
		return 0
	var site := Site.new()
	site.id = fortress_id
	site.definition = definition
	site.node = node
	site.entity = entity
	site.state = FortressState.initial(definition, tick)
	site.last_sent = site.state.duplicate_state()
	site.last_sent_tick = tick
	var circle: Node3D = node.get_node_or_null(CIRCLE_NODE) as Node3D
	site.circle_center = circle.global_position if circle != null else node.global_position
	if circle != null:
		var radius: Variant = circle.get_meta(CIRCLE_RADIUS_META, DEFAULT_CIRCLE_RADIUS)
		if (typeof(radius) == TYPE_FLOAT or typeof(radius) == TYPE_INT) and float(radius) > 0.0:
			site.circle_radius = float(radius)
	site.gate = node.get_node_or_null(GATE_NODE) as FortGate
	if site.gate != null:
		site.gate.set_state(0, false)
		var target := StructureTarget.new()
		target.net_id = entity.net_id
		target.fortress_id = fortress_id
		target.state = site.state
		target.box = site.gate.get_hit_box()
		target.half_extents = site.gate.get_hit_half_extents()
		target.exclude = site.gate.get_body_rids()
		site.target = target
	entity.realm = RealmCatalog.NEUTRAL_CODE
	entity.flags = NetEntity.FLAG_ALWAYS_RELEVANT
	entity.display_name = definition.display_name
	entity.definition_id = String(fortress_id)
	entity.fortress_state = site.state
	_sites.append(site)
	_sites_by_id[fortress_id] = site
	_sites_by_net_id[entity.net_id] = site
	return entity.net_id


## Pone en [param fortress_id] el estado [param loaded] (el cargado de la plataforma al arrancar, docs/plataforma.md
## §8; [FortressPersistence]) en el tick [param tick], antes de que nadie lo vea: se copia en el estado vivo (la
## entidad y la puerta lo siguen), lo enviado se da por sabido (el alta lleva el estado entero) y las capas de la
## puerta pasan a su dueño y rotura. [param consolidation_ends_tick] es el fin de una consolidación cargada
## ([constant FortressState.NO_TICK] si no hay): el estado no puede llevar un inicio negativo, así que el fin lo
## guarda el controlador. Devuelve false si la fortaleza no existe.
func restore_state(fortress_id: StringName, loaded: FortressState, consolidation_ends_tick: int,
		tick: int) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null or loaded == null:
		return false
	site.state.copy_from(loaded)
	site.consolidation_ends_tick = consolidation_ends_tick \
			if loaded.phase == FortressState.Phase.CONSOLIDATING else FortressState.NO_TICK
	site.forced = false
	site.repair_pending = false
	site.gate_damage_announced = loaded.gate_health < loaded.gate_max
	site.presence = PackedInt32Array([0, 0, 0, 0])
	site.last_sent = site.state.duplicate_state()
	site.last_sent_tick = tick
	site.sent_owner = site.state.owner
	site.sent_broken = site.state.is_gate_broken()
	_sync_gate(site)
	return true


## Quita todas las fortalezas y libera sus entidades de red (cierre del servidor).
func clear() -> void:
	if _registry != null:
		for site: Site in _sites:
			_registry.release(site.entity.net_id, site.last_sent_tick)
	_sites.clear()
	_sites_by_id.clear()
	_sites_by_net_id.clear()


# --- Consultas -----------------------------------------------------------------------------------

## true si la zona tiene alguna fortaleza.
func has_fortresses() -> bool:
	return not _sites.is_empty()


## Ids de las fortalezas, en el orden de la escena.
func get_fortress_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for site: Site in _sites:
		ids.append(site.id)
	return ids


## El estado [b]vivo[/b] de la fortaleza [param fortress_id] (no una copia), o null si no existe.
func get_fortress_state(fortress_id: StringName) -> FortressState:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.state if site != null else null


## Estados vivos por id de fortaleza (la forma que pide [method RespawnRules.points_for]).
func get_states() -> Dictionary:
	var states: Dictionary = {}
	for site: Site in _sites:
		states[site.id] = site.state
	return states


## La entidad de red de la fortaleza [param fortress_id], o null.
func get_entity(fortress_id: StringName) -> NetEntity:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.entity if site != null else null


## Id de red de la fortaleza [param fortress_id], o 0.
func get_net_id(fortress_id: StringName) -> int:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.entity.net_id if site != null else 0


## Id de la fortaleza con ese [param net_id] de red, o una cadena vacía.
func get_fortress_id_of(net_id: int) -> StringName:
	var site: Site = _sites_by_net_id.get(net_id)
	return site.id if site != null else &""


## Definición de la fortaleza [param fortress_id], o null.
func get_definition(fortress_id: StringName) -> FortressDefinition:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.definition if site != null else null


## Centro y radio del círculo de captura de [param fortress_id] (el centro es ZERO si no existe).
func get_circle(fortress_id: StringName) -> Dictionary:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return {"center": Vector3.ZERO, "radius": 0.0}
	return {"center": site.circle_center, "radius": site.circle_radius}


## Nodo de la fortaleza [param fortress_id] en la escena, o null.
func get_node_of(fortress_id: StringName) -> Node3D:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.node if site != null else null


## Puerta de la fortaleza [param fortress_id], o null si la escena no la tiene.
func get_gate(fortress_id: StringName) -> FortGate:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.gate if site != null else null


## Presencia (jugadores de cada reino) del último recuento de [param fortress_id].
func get_presence(fortress_id: StringName) -> PackedInt32Array:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.presence.duplicate() if site != null else PackedInt32Array([0, 0, 0, 0])


## Los blancos de golpes (las puertas) de la zona, para el [CombatResolver]. El array es el mismo
## durante toda la vida del controlador.
func get_structure_targets() -> Array[StructureTarget]:
	var targets: Array[StructureTarget] = []
	for site: Site in _sites:
		if site.target != null:
			targets.append(site.target)
	return targets


## true si hay una reparación de la puerta esperando a que el vano quede libre.
func is_repair_pending(fortress_id: StringName) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	return site != null and site.repair_pending


## true si el ciclo actual de [param fortress_id] lo ha provocado un comando del fuerte (progresion.md §6.2): un
## cambio de dueño o un reinicio por orden, el capitán muerto con [code]fort_kill_captain[/code] (y la captura que
## lo sigue) o una velocidad de captura distinta de 1. Lo que pasa en él no suma capturas ni tiempo defendiendo y
## no paga recompensas persistentes.
func is_forced(fortress_id: StringName) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	return site != null and (site.forced or site.state.capture_rate_multiplier != 1)


## Tick en el que termina la consolidación de [param fortress_id] (la cargada de la plataforma o la de su inicio más
## [method FortressDefinition.consolidation_ticks]); [constant FortressState.NO_TICK] si no está consolidando.
func get_consolidation_end_tick(fortress_id: StringName) -> int:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null or site.state.phase != FortressState.Phase.CONSOLIDATING:
		return FortressState.NO_TICK
	if site.consolidation_ends_tick != FortressState.NO_TICK:
		return site.consolidation_ends_tick
	return site.state.phase_tick + site.definition.consolidation_ticks()


## La fortaleza que defiende el PNJ [param net_id] (registrado con [method register_captain] o
## [method register_defender]); vacío si no defiende ninguna. Su muerte la lee aquí quien la paga (progresion.md P5c)
## antes de que el controlador lo olvide: el DEATH llega antes a la zona que a [method on_combat_event].
func fortress_of_defender(net_id: int) -> StringName:
	for site: Site in _sites:
		if site.defenders.has(net_id):
			return site.id
	return &""


## El PNJ capitán registrado de [param fortress_id] (0 = ninguno).
func get_captain_net_id(fortress_id: StringName) -> int:
	var site: Site = _sites_by_id.get(fortress_id)
	return site.captain_net_id if site != null else 0


## La fortaleza más cercana al punto [param position] (por su círculo), o una cadena vacía si no hay.
func get_nearest_fortress_id(position: Vector3) -> StringName:
	var best: StringName = &""
	var best_distance: float = INF
	for site: Site in _sites:
		var distance: float = site.circle_center.distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best = site.id
	return best


# --- Interfaz con los PNJ (F4) y con el combate ---------------------------------------------------

## Registra al PNJ [param net_id] como capitán de [param fortress_id] (y como defensor): cuando muere
## ([signal CombatDirector.event_emitted] con DEATH, vía [method on_combat_event]) el controlador
## llama a [method on_captain_died] con el reino de quien lo mató. Sustituye al anterior.
func register_captain(fortress_id: StringName, net_id: int) -> void:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return
	site.captain_net_id = net_id
	site.defenders[net_id] = true


## Registra al PNJ [param net_id] como defensor de [param fortress_id]: si recibe un golpe, el fuerte
## cuenta como atacado (no se puede reaparecer en él durante
## [member FortressDefinition.under_attack_s]) y sale el aviso de «fuerte atacado».
func register_defender(fortress_id: StringName, net_id: int) -> void:
	var site: Site = _sites_by_id.get(fortress_id)
	if site != null:
		site.defenders[net_id] = true


## Quita al PNJ [param net_id] de los defensores (y de capitán, si lo era).
func unregister_defender(fortress_id: StringName, net_id: int) -> void:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return
	site.defenders.erase(net_id)
	if site.captain_net_id == net_id:
		site.captain_net_id = 0


## Ha muerto el capitán de [param fortress_id] en el tick [param tick] a manos de [param killer_realm]
## (0 si nadie). Si guardaba el fuerte, pasa a VULNERABLE y sale el aviso de «capitán caído». Devuelve
## true si ha tenido efecto.
func on_captain_died(fortress_id: StringName, tick: int, killer_realm: int) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return false
	if not _captain_died(site, tick, killer_realm):
		return false
	site.forced = false
	return true


## Dice cuántos guardias de la guarnición de [param fortress_id] están vivos. Los que faltan
## reaparecen a los [member FortressDefinition.guard_respawn_s] ([signal guards_respawn_due]).
func set_guards_alive(fortress_id: StringName, count: int) -> void:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return
	site.state.set_guards_alive(count)
	site.guards_due_notified = false


## Un golpe ha dado en la puerta ([signal CombatDirector.structure_hit]): le resta [param amount] de
## vida en el tick [param tick], sale el aviso de «fuerte atacado» (como mucho uno por minuto) y el de
## «puerta rota» si la rompe, y el daño cuenta para el marcador de [param attacker].
func on_structure_hit(target: StructureTarget, attacker: Combatant, amount: int, tick: int) -> void:
	var site: Site = _sites_by_net_id.get(target.net_id)
	if site == null or amount <= 0:
		return
	var first_damage: bool = not site.gate_damage_announced
	var events: PackedInt32Array = site.state.on_gate_damaged(tick, amount, attacker.get_realm())
	if first_damage:
		site.gate_damage_announced = true
		gate_damage_started.emit(site.id, tick)
	if score_keeper != null:
		score_keeper.add_gate_damage(attacker.get_id(), amount)
	_emit_war(site, tick, events, attacker.get_realm())


## Un evento del combate ([signal CombatDirector.event_emitted]): la muerte del capitán registrado
## abre el círculo y un golpe a un defensor registrado marca el fuerte como atacado.
func on_combat_event(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
	if _sites.is_empty():
		return
	if event.event == NetMessages.EntityEvent.Kind.HIT:
		_on_defender_hit(event)
	elif event.event == NetMessages.EntityEvent.Kind.DEATH:
		_on_death(event)


# --- Órdenes de administración -------------------------------------------------------------------

## Devuelve [param fortress_id] a neutral en el tick [param tick] ([code]fort_reset[/code]): Huecos y
## Capitán del Vado, puerta llena (cuando el vano esté libre) y captura a cero. Los jugadores que haya
## dentro no se mueven. Devuelve false si la fortaleza no existe.
func reset_fortress(fortress_id: StringName, tick: int) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return false
	var health_before: int = site.state.gate_health
	var last_damage_before: int = site.state.gate_last_damage_tick
	var events: PackedInt32Array = site.state.reset_to_neutral(site.definition, tick)
	site.forced = true
	site.consolidation_ends_tick = FortressState.NO_TICK
	_after_hard_reset(site, tick, events, health_before, last_damage_before)
	return true


## Da la fortaleza [param fortress_id] al reino [param realm] (0 a 3; 0 = neutral) en el tick
## [param tick] ([code]fort_owner[/code]): GARRISONED con la guarnición y el capitán de ese reino, puerta
## llena y sin captura. Con un reino sale el aviso de «fuerte capturado» y con 0 el de «reiniciado».
func set_owner(fortress_id: StringName, realm: int, tick: int) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null or realm < 0 or realm > 3:
		return false
	var health_before: int = site.state.gate_health
	var last_damage_before: int = site.state.gate_last_damage_tick
	var events: PackedInt32Array = site.state.reset_to_neutral(site.definition, tick)
	site.state.owner = realm
	site.forced = true
	site.consolidation_ends_tick = FortressState.NO_TICK
	if realm != RealmCatalog.NEUTRAL_CODE:
		events = PackedInt32Array([WarEvents.FORT_CAPTURED])
	_after_hard_reset(site, tick, events, health_before, last_damage_before)
	return true


## Mata al capitán de [param fortress_id] en el tick [param tick] a manos de [param killer_realm]
## ([code]fort_kill_captain[/code]). Si hay un PNJ capitán registrado, lo mata
## ([member captain_killer]) y su muerte llega por [method on_combat_event]; si no, da por muerto al
## capitán directamente. Devuelve true si la fortaleza estaba guardada por su capitán.
func kill_captain(fortress_id: StringName, tick: int, killer_realm: int) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null:
		return false
	var state: FortressState = site.state
	if state.phase != FortressState.Phase.GARRISONED or not state.captain_alive:
		return false
	# Forzado antes de matar: la muerte sale en esta misma llamada y quien la paga (progresion.md P5c) ya la ve así.
	var was_forced: bool = site.forced
	site.forced = true
	if site.captain_net_id != 0 and captain_killer.is_valid():
		site.pending_killer_realm = killer_realm
		if bool(captain_killer.call(site.captain_net_id)):
			return true
		site.pending_killer_realm = -1
	if not _captain_died(site, tick, killer_realm):
		site.forced = was_forced
		return false
	return true


## Multiplica por [param factor] (1 a 255) la velocidad de captura de [param fortress_id]
## ([code]fort_capture_speed[/code]); el decaimiento no cambia.
func set_capture_speed(fortress_id: StringName, factor: int) -> bool:
	var site: Site = _sites_by_id.get(fortress_id)
	if site == null or factor < 1 or factor > 255:
		return false
	site.state.capture_rate_multiplier = factor
	if factor != 1:
		site.forced = true
	return true


# --- El tick -------------------------------------------------------------------------------------

## Paso 4b del tick [param s]: recuento de la presencia (cada 6 ticks), avance del estado de cada
## fortaleza, efectos y OBJECT_STATE.
func step(s: int) -> void:
	if _sites.is_empty():
		return
	var recount: bool = s % FortressState.PRESENCE_RECOUNT_TICKS == 0
	var candidates: Array = []
	if recount and candidates_source.is_valid():
		candidates = candidates_source.call(s)
	for site: Site in _sites:
		if recount:
			_recount(site, candidates, s)
		_step_site(site, s)


func _step_site(site: Site, s: int) -> void:
	var state: FortressState = site.state
	var previous_owner: int = state.owner
	var previous_phase: int = state.phase
	var health_before: int = state.gate_health
	var last_damage_before: int = state.gate_last_damage_tick
	if site.consolidation_ends_tick != FortressState.NO_TICK:
		if state.phase != FortressState.Phase.CONSOLIDATING:
			site.consolidation_ends_tick = FortressState.NO_TICK
		elif s >= site.consolidation_ends_tick:
			# La consolidación cargada termina en su tick: advance la cierra con este inicio (que solo vive aquí).
			state.phase_tick = s - site.definition.consolidation_ticks()
			site.consolidation_ends_tick = FortressState.NO_TICK
	var events: PackedInt32Array = state.advance(site.definition, s, site.presence)
	_note_transitions(site, s, events, previous_owner, previous_phase)
	if events.has(WarEvents.FORT_CAPTURED):
		_on_captured(site, s)
	_emit_war(site, s, events, RealmCatalog.NEUTRAL_CODE)
	_hold_repair_if_blocked(site, health_before, last_damage_before)
	_repair_if_due(site, s)
	if state.guards_respawn_due(s) and not site.guards_due_notified:
		site.guards_due_notified = true
		guards_respawn_due.emit(site.id, s)
	_sync_gate(site)
	_flush_object_state(site, s)


# Recuenta quién está en el círculo de [param site] (solo cuenta con el círculo activo para el
# marcador) con los candidatos de este tick.
func _recount(site: Site, candidates: Array, s: int) -> void:
	var counts := PackedInt32Array([0, 0, 0, 0])
	var active: bool = site.state.is_circle_active()
	var owner: int = site.state.owner
	var forced: bool = is_forced(site.id)
	var defending: bool = active and owner != RealmCatalog.NEUTRAL_CODE and not forced
	for candidate: FortressPresence.Candidate in candidates:
		if not FortressPresence.is_present(site.definition, site.circle_center, site.circle_radius,
				candidate, s):
			continue
		counts[candidate.realm] += 1
		var player: PlayerCandidate = candidate as PlayerCandidate
		if not active or player == null:
			continue
		if score_keeper != null:
			score_keeper.add_circle_ticks(player.net_id, FortressState.PRESENCE_RECOUNT_TICKS)
			# El tiempo defendiendo (docs/plataforma.md §8): solo el reino dueño, y no en un ciclo forzado.
			if defending and candidate.realm == owner and not player.gm_forced:
				score_keeper.add_defend_ticks(player.net_id, FortressState.PRESENCE_RECOUNT_TICKS)
		# Los méritos de objetivo (progresion.md §6.2): no en un ciclo forzado ni a un marcado por un comando de GM.
		if not forced and not player.gm_forced:
			objective_time.emit(site.id, player.net_id, FortressState.PRESENCE_RECOUNT_TICKS, s)
	site.presence = counts


# Captura de verdad en el tick [param s] (advance ha dado FORT_CAPTURED): si no es forzada, la lista de quien
# estaba en el círculo suma una captura a cada uno y sale por fortress_captured (docs/plataforma.md §8). La lista se
# calcula una vez, con los candidatos de este tick.
func _on_captured(site: Site, s: int) -> void:
	if is_forced(site.id):
		# El dueño nuevo sale de un cambio forzado: el ciclo lo sigue siendo hasta que llegue su guarnición.
		site.forced = true
		return
	var owner: int = site.state.owner
	var in_circle := PackedInt32Array()
	if candidates_source.is_valid():
		for candidate: FortressPresence.Candidate in candidates_source.call(s):
			var player: PlayerCandidate = candidate as PlayerCandidate
			if player == null or player.realm != owner or player.gm_forced:
				continue
			if FortressPresence.is_present(site.definition, site.circle_center, site.circle_radius, player, s):
				in_circle.append(player.net_id)
	in_circle.sort()
	if score_keeper != null:
		for net_id: int in in_circle:
			score_keeper.add_capture(net_id)
	fortress_captured.emit(site.id, owner, in_circle, s)


# Efectos de los cambios de fase y de dueño que ha hecho advance(): retirar a los PNJ, hacer aparecer
# la guarnición.
func _note_transitions(site: Site, tick: int, events: PackedInt32Array, previous_owner: int,
		previous_phase: int) -> void:
	var state: FortressState = site.state
	if events.has(WarEvents.FORT_RESET):
		# El reinicio periódico es un cambio de verdad: empieza un ciclo sin forzar.
		site.forced = false
		_retire_defenders(site, tick)
		site.gate_damage_announced = false
		garrison_due.emit(site.id, state.owner, tick, true)
		return
	if state.owner != previous_owner:
		_retire_defenders(site, tick)
		site.gate_damage_announced = false
	if previous_phase != FortressState.Phase.GARRISONED \
			and state.phase == FortressState.Phase.GARRISONED:
		site.forced = false
		garrison_due.emit(site.id, state.owner, tick,
				previous_phase == FortressState.Phase.CONSOLIDATING)


func _retire_defenders(site: Site, tick: int) -> void:
	site.defenders.clear()
	site.captain_net_id = 0
	site.pending_killer_realm = -1
	site.guards_due_notified = false
	defenders_retired.emit(site.id, tick)


# Tras un reinicio o un cambio de dueño por orden: avisos, PNJ y reparación (que espera si hay
# alguien en el vano).
func _after_hard_reset(site: Site, tick: int, events: PackedInt32Array, health_before: int,
		last_damage_before: int) -> void:
	_retire_defenders(site, tick)
	site.gate_damage_announced = false
	garrison_due.emit(site.id, site.state.owner, tick, true)
	_emit_war(site, tick, events, RealmCatalog.NEUTRAL_CODE)
	_hold_repair_if_blocked(site, health_before, last_damage_before)


func _captain_died(site: Site, tick: int, killer_realm: int) -> bool:
	var events: PackedInt32Array = site.state.on_captain_died(tick, killer_realm)
	site.captain_net_id = 0
	site.pending_killer_realm = -1
	_emit_war(site, tick, events, killer_realm)
	return not events.is_empty()


func _emit_war(site: Site, tick: int, events: PackedInt32Array, caller_realm: int) -> void:
	for war_event: int in events:
		war_event_emitted.emit(NetMessages.EntityEvent.war(site.entity.net_id, tick, war_event,
				site.state.event_realm(war_event, caller_realm)))


# Un golpe a un defensor registrado marca el fuerte como atacado y puede dar el aviso.
func _on_defender_hit(event: NetMessages.EntityEvent) -> void:
	var attacker: NetEntity = _registry.get_entity(event.attacker) if _registry != null else null
	if attacker == null:
		return
	for site: Site in _sites:
		if not site.defenders.has(event.net_id):
			continue
		site.state.on_defender_damaged(event.tick, attacker.realm)
		if site.state.claim_attack_notice(event.tick):
			_emit_war(site, event.tick, PackedInt32Array([WarEvents.UNDER_ATTACK]), attacker.realm)
		return


func _on_death(event: NetMessages.EntityEvent) -> void:
	for site: Site in _sites:
		if not site.defenders.has(event.net_id):
			continue
		site.defenders.erase(event.net_id)
		if site.captain_net_id == event.net_id:
			# Con fort_kill_captain, pending_killer_realm ya está puesto y kill_captain marca el ciclo como forzado;
			# una muerte en combate es un cambio de verdad.
			var by_command: bool = site.pending_killer_realm >= 0
			var killer_realm: int = site.pending_killer_realm
			if event.killer != 0 and _registry != null:
				var killer: NetEntity = _registry.get_entity(event.killer)
				if killer != null:
					killer_realm = killer.realm
			if _captain_died(site, event.tick, maxi(killer_realm, 0)) and not by_command:
				site.forced = false
		return


# --- La puerta -----------------------------------------------------------------------------------

# Si una reparación que ha hecho el estado (captura, reinicio) deja a alguien en el vano, se
# deshace: la puerta sigue rota y la reparación espera.
func _hold_repair_if_blocked(site: Site, health_before: int, last_damage_before: int) -> void:
	var state: FortressState = site.state
	if state.gate_health > health_before and _is_gate_blocked(site):
		state.gate_health = health_before
		state.gate_last_damage_tick = last_damage_before
		site.repair_pending = true


# Repara la puerta si toca (tras 5 min sin daño o una reparación aplazada) y el vano está libre.
func _repair_if_due(site: Site, tick: int) -> void:
	var state: FortressState = site.state
	if not site.repair_pending and not state.gate_repair_due(tick):
		return
	if _is_gate_blocked(site):
		site.repair_pending = true
		return
	if state.gate_health < state.gate_max:
		state.repair_gate()
	site.repair_pending = false
	site.gate_damage_announced = false


# true si algún personaje solapa el vano de la puerta (la caja de la puerta cerrada).
func _is_gate_blocked(site: Site) -> bool:
	if site.target == null or not bodies_source.is_valid():
		return false
	var bodies: PackedVector3Array = bodies_source.call()
	for feet: Vector3 in bodies:
		if HitShapes.capsule_overlaps_box(feet, HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT,
				site.target.box, site.target.half_extents):
			return true
	return false


# Pone las capas de la puerta según el dueño y la rotura de ahora: valen desde el tick siguiente.
func _sync_gate(site: Site) -> void:
	if site.gate == null:
		return
	var broken: bool = site.state.is_gate_broken()
	if site.applied_owner != site.state.owner or site.applied_broken != broken:
		site.applied_owner = site.state.owner
		site.applied_broken = broken
		site.gate.set_state(site.applied_owner, broken)


# --- OBJECT_STATE --------------------------------------------------------------------------------

func _flush_object_state(site: Site, tick: int) -> void:
	var state: FortressState = site.state
	var broken: bool = state.is_gate_broken()
	var collision_changed: bool = site.sent_owner != state.owner or site.sent_broken != broken
	var due: bool = tick - site.last_sent_tick >= OBJECT_STATE_INTERVAL_TICKS
	if not due and not collision_changed:
		return
	var changed: PackedInt32Array = _fields_to_send(site)
	if changed.is_empty():
		return
	site.last_sent_tick = tick
	var object_state: NetMessages.ObjectState = NetMessages.ObjectState.from_fortress_fields(
			site.entity.net_id, tick, state, changed)
	for field_id: int in changed:
		FortressFields.set_value(site.last_sent, field_id, FortressFields.get_value(state, field_id))
	site.sent_owner = state.owner
	site.sent_broken = broken
	object_state_emitted.emit(object_state)


# Campos que han cambiado desde el último envío, sin el aviso de ataque si apenas ha avanzado.
func _fields_to_send(site: Site) -> PackedInt32Array:
	var changed: PackedInt32Array = site.state.changed_fields_since(site.last_sent)
	var index: int = changed.find(FortressFields.UNDER_ATTACK_UNTIL_TICK)
	if index >= 0:
		var advance: int = site.state.under_attack_until_tick - site.last_sent.under_attack_until_tick
		if advance > 0 and advance < UNDER_ATTACK_MIN_ADVANCE_TICKS:
			changed.remove_at(index)
	return changed


# --- Comandos de depuración -----------------------------------------------------------------------

## Registra en [param commands] los comandos de la fortaleza, con sus ids fijos de red (8
## [code]fort_reset[/code], 9 [code]fort_owner[/code], 10 [code]fort_kill_captain[/code], 11
## [code]fort_capture_speed[/code]) y su versión de consola. [param next_tick] es
## [code]() -> int[/code]: el tick que va a simular el servidor (en el que cae la orden).
## [br]Los de red actúan sobre la fortaleza más cercana al que los envía; los de consola, sobre la que
## se nombra al final o, si no, sobre la primera.
func register_commands(commands: CommandRegistry, next_tick: Callable) -> void:
	_next_tick_source = next_tick
	commands.register(&"fort_reset", "fort_reset [fortaleza]", _console_reset, _net_reset)
	commands.register(&"fort_owner", "fort_owner <vardheim|solmarch|askarra|neutral> [fortaleza]",
			_console_owner, _net_owner)
	commands.register(&"fort_kill_captain", "fort_kill_captain [fortaleza]",
			_console_kill_captain, _net_kill_captain)
	commands.register(&"fort_capture_speed", "fort_capture_speed <1-255> [fortaleza]",
			_console_capture_speed, _net_capture_speed)


func _command_tick() -> int:
	return int(_next_tick_source.call()) if _next_tick_source.is_valid() else 0


# La fortaleza más cercana a quien envía un comando de red, o una cadena vacía.
func _fortress_of_sender(ctx: CommandRegistry.Context) -> StringName:
	if ctx.peer == null or ctx.peer.entity == null:
		return &""
	return get_nearest_fortress_id(ctx.peer.entity.get_position())


func _sender_realm(ctx: CommandRegistry.Context) -> int:
	return ctx.peer.entity.realm if ctx.peer != null and ctx.peer.entity != null else 0


# La fortaleza nombrada en el argumento [param index] de la consola o la primera.
func _fortress_from_args(ctx: CommandRegistry.Context, index: int) -> StringName:
	if ctx.args.size() > index:
		var named: StringName = StringName(ctx.args[index])
		return named if _sites_by_id.has(named) else &""
	return _sites[0].id if not _sites.is_empty() else &""


func _net_reset(ctx: CommandRegistry.Context) -> int:
	if not ctx.payload.is_empty():
		return CommandRegistry.Result.BAD_ARGUMENTS
	var fortress_id: StringName = _fortress_of_sender(ctx)
	if fortress_id.is_empty() or not reset_fortress(fortress_id, _command_tick()):
		return CommandRegistry.Result.REFUSED
	ctx.note = String(fortress_id)
	return CommandRegistry.Result.OK


func _net_owner(ctx: CommandRegistry.Context) -> int:
	if ctx.payload.size() != 1 or ctx.payload[0] > 3:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var fortress_id: StringName = _fortress_of_sender(ctx)
	if fortress_id.is_empty() or not set_owner(fortress_id, ctx.payload[0], _command_tick()):
		return CommandRegistry.Result.REFUSED
	ctx.note = "%s -> %s" % [fortress_id, NetProtocol.realm_display_name(ctx.payload[0])]
	return CommandRegistry.Result.OK


func _net_kill_captain(ctx: CommandRegistry.Context) -> int:
	if not ctx.payload.is_empty():
		return CommandRegistry.Result.BAD_ARGUMENTS
	var fortress_id: StringName = _fortress_of_sender(ctx)
	if fortress_id.is_empty() \
			or not kill_captain(fortress_id, _command_tick(), _sender_realm(ctx)):
		return CommandRegistry.Result.REFUSED
	ctx.note = String(fortress_id)
	return CommandRegistry.Result.OK


func _net_capture_speed(ctx: CommandRegistry.Context) -> int:
	if ctx.payload.size() != 1 or ctx.payload[0] < 1:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var fortress_id: StringName = _fortress_of_sender(ctx)
	if fortress_id.is_empty() or not set_capture_speed(fortress_id, ctx.payload[0]):
		return CommandRegistry.Result.REFUSED
	ctx.note = "%s x%d" % [fortress_id, ctx.payload[0]]
	return CommandRegistry.Result.OK


func _console_reset(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() > 1:
		return "Uso: fort_reset [fortaleza]"
	var fortress_id: StringName = _fortress_from_args(ctx, 0)
	if fortress_id.is_empty():
		return "No hay ninguna fortaleza «%s»" % (ctx.args[0] if not ctx.args.is_empty() else "")
	reset_fortress(fortress_id, _command_tick())
	return "%s vuelve a ser neutral" % fortress_id


func _console_owner(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty() or ctx.args.size() > 2:
		return "Uso: fort_owner <vardheim|solmarch|askarra|neutral> [fortaleza]"
	var realm: int = _realm_from_text(ctx.args[0])
	if realm < 0:
		return "Reino desconocido: %s (vardheim, solmarch, askarra o neutral)" % ctx.args[0]
	var fortress_id: StringName = _fortress_from_args(ctx, 1)
	if fortress_id.is_empty():
		return "No hay ninguna fortaleza «%s»" % (ctx.args[1] if ctx.args.size() > 1 else "")
	set_owner(fortress_id, realm, _command_tick())
	return "%s es ahora de %s" % [fortress_id, WarEvents.realm_label(realm)]


func _console_kill_captain(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() > 1:
		return "Uso: fort_kill_captain [fortaleza]"
	var fortress_id: StringName = _fortress_from_args(ctx, 0)
	if fortress_id.is_empty():
		return "No hay ninguna fortaleza «%s»" % (ctx.args[0] if not ctx.args.is_empty() else "")
	if not kill_captain(fortress_id, _command_tick(), RealmCatalog.NEUTRAL_CODE):
		return "El capitán de %s no está guardando el fuerte" % fortress_id
	return "El capitán de %s ha muerto" % fortress_id


func _console_capture_speed(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty() or ctx.args.size() > 2 or not ctx.args[0].is_valid_int():
		return "Uso: fort_capture_speed <1-255> [fortaleza]"
	var factor: int = ctx.args[0].to_int()
	var fortress_id: StringName = _fortress_from_args(ctx, 1)
	if fortress_id.is_empty():
		return "No hay ninguna fortaleza «%s»" % (ctx.args[1] if ctx.args.size() > 1 else "")
	if not set_capture_speed(fortress_id, factor):
		return "El factor debe estar entre 1 y 255"
	return "Captura de %s a x%d" % [fortress_id, factor]


# Código de reino de un texto («vardheim», «neutral», «0»...), o -1.
static func _realm_from_text(text: String) -> int:
	var clean: String = text.strip_edges().to_lower()
	if clean == "neutral" or clean == "huecos" or clean == "0":
		return RealmCatalog.NEUTRAL_CODE
	if clean.is_valid_int():
		var code: int = clean.to_int()
		return code if code >= 1 and code <= 3 else -1
	var realm: int = NetZones.realm_from_name(clean)
	return realm if realm != NetProtocol.Realm.NONE else -1


# --- Auxiliares ----------------------------------------------------------------------------------

# La definición del nodo: la propia [FortressDefinition] o la ruta de su .tres.
static func _definition_of(node: Node3D) -> FortressDefinition:
	var value: Variant = node.get_meta(NetZones.fortress_definition_meta(), null)
	if value is FortressDefinition:
		return value as FortressDefinition
	if value is String or value is StringName:
		var path: String = String(value)
		if ResourceLoader.exists(path):
			return load(path) as FortressDefinition
	return null
