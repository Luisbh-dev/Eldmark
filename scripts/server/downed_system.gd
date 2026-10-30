class_name DownedSystem
extends RefCounted
## Derribado, levantar y rematar en el servidor (docs/habilidades.md, sección 4.5; CMB-28).
## [br][br]
## [b]Cuándo[/b] ([method should_down]): la vida de un [b]jugador[/b] (también los falsos) llega a 0 por un
## golpe, una flecha o un pulso cuyo autor es un jugador de un reino hostil en una zona RVR. Si no, muerte
## directa (PNJ, entorno, maniquí, PvE). Lo decide el [CombatDirector] al aplicar el golpe.
## [br][br]
## [b]Caer[/b] ([method down]): [method ActionMachine.impose_downed], vida 0, vida de derribado
## [member CombatRules.downed_health], autor y fuente, efectos borrados (sin STATUS: DOWNED los borra en el
## cliente) y el evento DOWNED a toda la zona. El HIT del golpe lleva el bit 6 (lo pone el director).
## [br][br]
## [b]El paso 7 del tick[/b] ([method step], docs/habilidades.md, sección 4.1), por net_id:
## [br]1. [b]Desangrado[/b]: la vida de derribado baja de forma exacta en enteros hasta 0 en
## [member CombatTables.downed_ticks] (−1 cada 3 ticks con 400 en 1200). A 0, muerte: asesino el último
## enemigo que le hizo daño ya derribado o, si no, quien lo derribó, con la fuente «desangrado».
## [br]2. [b]INTERACT nuevos[/b]: un flanco de INTERACT en una entrada real (los botones de [code]s[/code]
## frente a los de [code]s − 1[/code], que guarda el [Combatant]) de alguien vivo, en NONE o BLOCK y en el
## suelo busca el derribado más cercano a [member CombatRules.interact_range_m] en horizontal (desnivel ≤
## [constant MAX_HEIGHT_DIFFERENCE], empate por net_id) con línea de visión del pecho (pies + 1,4) a pies +
## 0,5 del derribado: un aliado al que nadie levanta → REVIVE (INTERACT 1); un enemigo sin zonas seguras de
## por medio → EXECUTE (INTERACT 4). [method ActionMachine.impose_interact] y [code]commit_state[/code].
## [br]3. [b]Progreso y final[/b]: en [code]s == inicio + duración[/code] acaba (se mira antes que seguir: en
## ese tick la simulación ya ha vuelto a NONE): levantar → [method ActionMachine.impose_revived] con
## [member CombatRules.revived_health] (INTERACT 3); rematar → muerte con la fuente «remate». Antes, cada
## tick se corta (INTERACT 2 o 5, e [method ActionMachine.impose_interrupt] si aún está en la acción) si
## quien actúa ha dejado la acción (soltó, esquivó, le impusieron otra o le interrumpió un golpe), el
## objetivo ya no está derribado o ha recibido daño en este tick, pasa de
## [member CombatRules.interact_keep_range_m] o se pierde la línea de visión (la puerta cerrada la corta).
## [br][br]
## Un derribado no es ni vivo ni muerto ([method Combatant.is_downed]): es candidato de los golpes y de los
## PNJ, no recibe efectos ni pulsos, no cuenta en el círculo, no se cura ni reaparece y su baja (salir,
## desconectarse, el fin del cuerpo de GUE-41) es antes una muerte ([method killer_of]).
## [br][br]
## No toca la red ni el reloj: avisa con [signal event_emitted] (DOWNED e INTERACT) y pide las muertes con
## [signal killed], que aplica el [CombatDirector] (DEATH y KILL).

## Un evento DOWNED o INTERACT y los net_id implicados (el derribado y su autor o quien actúa).
signal event_emitted(event: NetMessages.EntityEvent, involved: PackedInt32Array)
## Un derribado muere desangrado o rematado: [param killer_id] es el asesino (0 = nadie) y [param source] la
## fuente ([constant CombatSource.BLEED_OUT] o [constant CombatSource.EXECUTE]). Lo mata el [CombatDirector].
signal killed(victim: Combatant, killer_id: int, source: int, tick: int)

## Desnivel máximo (m) entre quien actúa y el derribado para empezar a levantarlo o rematarlo, y para seguir.
const MAX_HEIGHT_DIFFERENCE: float = 1.5
## Altura sobre los pies del derribado a la que llega el rayo de la línea de visión (está en el suelo).
const DOWNED_SIGHT_HEIGHT: float = 0.5

const _NONE: int = CombatState.Action.NONE
const _BLOCK: int = CombatState.Action.BLOCK
const _REVIVE: int = CombatState.Action.REVIVE
const _EXECUTE: int = CombatState.Action.EXECUTE

## Zona (las reglas de hostilidad y el modo RVR) y sus zonas seguras (null = ninguna).
var zone_id: StringName = &""
var safe_areas: SafeAreas = null
## Los efectos de estado de la zona: se borran al caer.
var status: StatusSystem = null
## Los combatientes de la zona por net_id (el diccionario del [CombatDirector]: no es una copia).
var combatants: Dictionary[int, Combatant] = {}
## Contadores de la ejecución (para el informe del servidor).
var stats: Dictionary[StringName, int] = {
	&"downs": 0, &"revives": 0, &"executions": 0, &"bled_out": 0, &"interact_started": 0,
	&"interact_cut": 0,
}

# Derribados de la zona y quienes levantan o rematan, por net_id: sin ninguno, step() no recorre a nadie.
var _downed: Dictionary[int, Combatant] = {}
var _actors: Dictionary[int, Combatant] = {}
# (reino de quien actúa · 16 + reino del derribado) -> si son hostiles en esta zona.
var _hostile_cache: Dictionary[int, bool] = {}


## true si [param victim], que acaba de quedarse sin vida, queda derribado en vez de morir: es un jugador
## (no un PNJ ni un maniquí) y el autor del golpe es un jugador ([param author_is_player]) de un reino
## ([param author_realm]) hostil al suyo en una zona RVR. Contra PNJ, el entorno o los Huecos, muerte directa.
func should_down(victim: Combatant, author_realm: int, author_is_player: bool) -> bool:
	if victim == null or victim.immortal or not author_is_player:
		return false
	if victim.entity == null or victim.entity.kind != NetProtocol.EntityKind.PLAYER:
		return false
	var victim_realm: int = victim.get_realm()
	if not RealmCatalog.is_realm_code(author_realm) or not RealmCatalog.is_realm_code(victim_realm):
		return false
	return NetZones.is_rvr(String(zone_id)) and _is_hostile(author_realm, victim_realm)


## true si la zona admite el derribado entre reinos (es RVR).
func is_enabled() -> bool:
	return NetZones.is_rvr(String(zone_id))


## Deja derribado a [param victim] en el tick [param s] por [param author_id] (0 = nadie: el comando 15) con la
## fuente [param source]: DOWNED con la vida de derribado, sin efectos, y el evento DOWNED. No hace nada sobre
## alguien ya derribado o muerto.
func down(victim: Combatant, author_id: int, source: int, s: int) -> void:
	if victim == null or victim.is_downed() or victim.death_tick >= 0:
		return
	var character: PlayerCharacter = victim.get_character()
	victim.mark_downed(s, author_id, source, CombatCatalog.rules().downed_health)
	if status != null:
		status.clear(victim)
	if character != null:
		ActionMachine.impose_downed(character.combat, s)
		CombatDirector.commit_state(character)
	_downed[victim.get_id()] = victim
	stats[&"downs"] += 1
	event_emitted.emit(NetMessages.EntityEvent.downed(victim.get_id(), s, author_id, source),
			_involved(victim.get_id(), author_id))


## Paso 7 del tick [param s] (docs/habilidades.md, sección 4.1) sobre [param list] (por net_id):
## desangrado, INTERACT nuevos y el progreso y el final de levantar y rematar. [param space] es el espacio de
## física del mundo (línea de visión; null = sin mundo).
func step(s: int, list: Array[Combatant], space: PhysicsDirectSpaceState3D) -> void:
	if _downed.is_empty() and _actors.is_empty():
		return
	var tables: CombatTables = CombatCatalog.tables()
	# 1. Desangrado.
	if not _downed.is_empty():
		for victim: Combatant in list:
			if not victim.is_downed():
				continue
			var loss: int = bleed_loss(s - victim.downed_tick, victim.downed_health, tables)
			if loss <= 0:
				continue
			victim.downed_health = maxi(victim.downed_health - loss, 0)
			if victim.downed_health == 0:
				stats[&"bled_out"] += 1
				killed.emit(victim, killer_of(victim), CombatSource.BLEED_OUT, s)
	# 2. INTERACT nuevos (solo hay a quién si queda algún derribado).
	if not _downed.is_empty():
		for actor: Combatant in list:
			if _interact_pressed(actor, s):
				_try_start(actor, s, space, tables)
	# 3. Progreso y final de lo que ya estaba en marcha.
	if not _actors.is_empty():
		for actor: Combatant in list:
			if actor.interact_target != 0 and actor.interact_start != s:
				_progress(actor, s, space, tables)
	_prune()


## Lo que quita el desangrado en el tick que hace [param elapsed] desde la caída: la vida de derribado baja
## en enteros de forma exacta hasta 0 en [member CombatTables.downed_ticks] (con 400 en 1200, 1 cada 3 ticks).
## [param remaining] acota el resultado.
static func bleed_loss(elapsed: int, remaining: int, tables: CombatTables) -> int:
	var total_ticks: int = tables.downed_ticks
	var full: int = tables.rules.downed_health
	if elapsed <= 0 or total_ticks <= 0 or remaining <= 0:
		return 0
	@warning_ignore("integer_division")
	var now: int = elapsed * full / total_ticks
	@warning_ignore("integer_division")
	var before: int = (elapsed - 1) * full / total_ticks
	return mini(now - before, remaining)


## El asesino de un derribado que muere sin golpe (desangrado, al salir, el entorno): el último enemigo que le
## hizo daño ya derribado o, si no, quien lo derribó; 0 si ninguno sigue en la zona.
func killer_of(victim: Combatant) -> int:
	if victim.last_enemy_id != 0 and victim.last_enemy_tick >= victim.downed_tick \
			and combatants.has(victim.last_enemy_id):
		return victim.last_enemy_id
	if victim.downed_by != 0 and combatants.has(victim.downed_by):
		return victim.downed_by
	return 0


## Deja de seguir a [param victim] como derribado (ha muerto o ha reaparecido). Quien lo levantaba o
## remataba se corta en el siguiente paso 7.
func release(victim: Combatant) -> void:
	if victim != null:
		_downed.erase(victim.get_id())


## Al dar de baja a [param net_id]: deja de seguirlo como derribado y como quien actúa.
func forget(net_id: int) -> void:
	_downed.erase(net_id)
	_actors.erase(net_id)


## Derribados de la zona ahora.
func downed_count() -> int:
	return _downed.size()


## Quien levanta o remata ahora.
func interacting_count() -> int:
	return _actors.size()


## Olvida a todos (cierre del servidor).
func clear() -> void:
	_downed.clear()
	_actors.clear()


# --- INTERACT --------------------------------------------------------------------------------------

# Flanco de INTERACT de [param actor] en una entrada real del tick [param s] (la que se simuló: real o
# sustituta), frente a los botones del tick anterior. Pone al día los botones que guarda el Combatant.
func _interact_pressed(actor: Combatant, s: int) -> bool:
	var queue: InputQueue = actor.queue
	if queue == null:
		return false
	var input: PlayerInput = queue.get_applied(s)
	if input == null:
		return false
	var buttons: int = input.buttons & ~PlayerInput.SUBSTITUTED
	var previous: int = buttons
	if actor.last_buttons_tick == s - 1:
		previous = actor.last_buttons
	else:
		# Sin derribados en el tick anterior no se guardaron: los da la cola (si no, no hay flanco).
		var before: PlayerInput = queue.get_applied(s - 1)
		if before != null:
			previous = before.buttons & ~PlayerInput.SUBSTITUTED
	actor.last_buttons = buttons
	actor.last_buttons_tick = s
	var real: bool = (input.buttons & PlayerInput.SUBSTITUTED) == 0
	return real and (buttons & PlayerInput.INTERACT) != 0 and (previous & PlayerInput.INTERACT) == 0


# Empieza a levantar o rematar al derribado más cercano que valga, si [param actor] puede: vivo, sin otra
# interacción, en NONE o BLOCK y en el suelo.
func _try_start(actor: Combatant, s: int, space: PhysicsDirectSpaceState3D, tables: CombatTables) -> void:
	var character: PlayerCharacter = actor.get_character()
	if character == null or not actor.is_alive() or actor.is_interacting():
		return
	var combat: CombatState = character.combat
	if (combat.action != _NONE and combat.action != _BLOCK) or not character.grounded:
		return
	var rules: CombatRules = tables.rules
	var feet: Vector3 = actor.entity.get_position()
	var range_squared: float = rules.interact_range_m * rules.interact_range_m
	var options: Array[Array] = []
	for target: Combatant in _downed.values():
		if target == actor or not target.is_downed():
			continue
		var other: Vector3 = target.entity.get_position()
		if absf(other.y - feet.y) > MAX_HEIGHT_DIFFERENCE:
			continue
		var distance_squared: float = _horizontal_distance_squared(feet, other)
		if distance_squared > range_squared:
			continue
		var action: int = _interaction_for(actor, target)
		if action != 0:
			options.append([distance_squared, target.get_id(), target, action])
	if options.is_empty():
		return
	options.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	for option: Array in options:
		var target: Combatant = option[2]
		if not _clear_line(space, feet, target.entity.get_position()):
			continue
		var action: int = option[3]
		ActionMachine.impose_interact(combat, s, action)
		CombatDirector.commit_state(character)
		actor.interact_target = target.get_id()
		actor.interact_action = action
		actor.interact_start = s
		_actors[actor.get_id()] = actor
		stats[&"interact_started"] += 1
		var operation: int = NetMessages.EntityEvent.InteractOp.REVIVE if action == _REVIVE \
				else NetMessages.EntityEvent.InteractOp.EXECUTE
		event_emitted.emit(NetMessages.EntityEvent.interact(target.get_id(), s, actor.get_id(), operation,
				s + _duration(action, tables)), _involved(target.get_id(), actor.get_id()))
		return


# Qué puede hacer [param actor] con el derribado [param target]: REVIVE a un aliado al que nadie levanta,
# EXECUTE a un enemigo sin zonas seguras de por medio, o 0.
func _interaction_for(actor: Combatant, target: Combatant) -> int:
	if target.get_realm() == actor.get_realm():
		return 0 if _being_revived(target) else _REVIVE
	if not _is_hostile(actor.get_realm(), target.get_realm()):
		return 0
	if safe_areas != null:
		if safe_areas.contains_own(target.get_realm(), target.entity.get_position()):
			return 0
		if not actor.ignores_safe_area \
				and safe_areas.contains_own(actor.get_realm(), actor.entity.get_position()):
			return 0
	return _EXECUTE


func _being_revived(target: Combatant) -> bool:
	for actor: Combatant in _actors.values():
		if actor.interact_target == target.get_id() and actor.interact_action == _REVIVE:
			return true
	return false


# Un tick de una interacción en marcha: acaba en su tick, o se corta si ya no se cumple lo que hace falta.
func _progress(actor: Combatant, s: int, space: PhysicsDirectSpaceState3D, tables: CombatTables) -> void:
	var target: Combatant = combatants.get(actor.interact_target)
	var end_tick: int = actor.interact_start + _duration(actor.interact_action, tables)
	if s >= end_tick:
		# Acabar se mira antes que seguir: en este tick la simulación ya ha vuelto a NONE.
		if s == end_tick and target != null and target.is_downed() and actor.is_alive():
			_complete(actor, target, s, tables)
		else:
			_cut(actor, s)
		return
	if not _keeps_going(actor, target, s, space, tables.rules):
		_cut(actor, s)


func _keeps_going(actor: Combatant, target: Combatant, s: int, space: PhysicsDirectSpaceState3D,
		rules: CombatRules) -> bool:
	var character: PlayerCharacter = actor.get_character()
	if character == null or not _still_in_action(actor, character.combat):
		return false
	if target == null or not target.is_downed() or target.last_damage_tick == s:
		return false
	var feet: Vector3 = actor.entity.get_position()
	var other: Vector3 = target.entity.get_position()
	if absf(other.y - feet.y) > MAX_HEIGHT_DIFFERENCE \
			or _horizontal_distance_squared(feet, other) > rules.interact_keep_range_m * rules.interact_keep_range_m:
		return false
	return _clear_line(space, feet, other)


# Acaba la interacción de [param actor] sobre [param target]: levantado (vida de levantado, NONE e INTERACT 3)
# o rematado (muerte con la fuente «remate»).
func _complete(actor: Combatant, target: Combatant, s: int, tables: CombatTables) -> void:
	var action: int = actor.interact_action
	var actor_id: int = actor.get_id()
	actor.clear_interaction()
	_actors.erase(actor_id)
	if action == _REVIVE:
		var character: PlayerCharacter = target.get_character()
		target.clear_downed()
		target.health = mini(tables.rules.revived_health, target.max_health)
		_downed.erase(target.get_id())
		if character != null:
			ActionMachine.impose_revived(character.combat, s)
			CombatDirector.commit_state(character)
		stats[&"revives"] += 1
		event_emitted.emit(NetMessages.EntityEvent.interact(target.get_id(), s, actor_id,
				NetMessages.EntityEvent.InteractOp.REVIVED, s), _involved(target.get_id(), actor_id))
		return
	stats[&"executions"] += 1
	killed.emit(target, actor_id, CombatSource.EXECUTE, s)


# Corta la interacción de [param actor]: si sigue en la acción, NONE conservando su action_tick
# (impose_interrupt); INTERACT 2 o 5.
func _cut(actor: Combatant, s: int) -> void:
	var target_id: int = actor.interact_target
	var action: int = actor.interact_action
	var character: PlayerCharacter = actor.get_character()
	if character != null and _still_in_action(actor, character.combat):
		ActionMachine.impose_interrupt(character.combat, s)
		CombatDirector.commit_state(character)
	actor.clear_interaction()
	_actors.erase(actor.get_id())
	stats[&"interact_cut"] += 1
	var operation: int = NetMessages.EntityEvent.InteractOp.REVIVE_CUT if action == _REVIVE \
			else NetMessages.EntityEvent.InteractOp.EXECUTE_CUT
	event_emitted.emit(NetMessages.EntityEvent.interact(target_id, s, actor.get_id(), operation, s),
			_involved(target_id, actor.get_id()))


static func _still_in_action(actor: Combatant, combat: CombatState) -> bool:
	return combat.action == actor.interact_action and combat.action_tick == actor.interact_start


static func _duration(action: int, tables: CombatTables) -> int:
	return tables.revive_ticks if action == _REVIVE else tables.execute_ticks


# Quita de las listas a quien ya no está (muerto, levantado, dado de baja).
func _prune() -> void:
	for net_id: int in _downed.keys():
		var victim: Combatant = _downed[net_id]
		if not victim.is_downed() or not combatants.has(net_id):
			_downed.erase(net_id)
	for net_id: int in _actors.keys():
		if not combatants.has(net_id):
			_actors.erase(net_id)


# Línea de visión del pecho de quien actúa (pies + 1,4) a pies + 0,5 del derribado, contra el mundo y las
# estructuras (la puerta cerrada la corta).
static func _clear_line(space: PhysicsDirectSpaceState3D, actor_feet: Vector3, target_feet: Vector3) -> bool:
	if space == null:
		return true
	return HitShapes.is_ray_clear(space, actor_feet + Vector3(0.0, HitShapes.LINE_OF_SIGHT_FROM_HEIGHT, 0.0),
			target_feet + Vector3(0.0, DOWNED_SIGHT_HEIGHT, 0.0))


static func _horizontal_distance_squared(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return dx * dx + dz * dz


func _is_hostile(my_realm: int, other_realm: int) -> bool:
	var key: int = my_realm * 16 + other_realm
	if not _hostile_cache.has(key):
		_hostile_cache[key] = FactionRules.can_damage(my_realm, other_realm, zone_id)
	return _hostile_cache[key]


static func _involved(first: int, second: int) -> PackedInt32Array:
	var involved := PackedInt32Array()
	if first > 0:
		involved.append(first)
	if second > 0 and second != first:
		involved.append(second)
	return involved
