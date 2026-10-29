class_name StatusSystem
extends RefCounted
## Efectos de estado del servidor (docs/habilidades.md, sección 4.3; CMB-20): sangrado, curación en el
## tiempo, ralentizar, enraizar, más daño y menos mitigación.
## [br][br]
## Cada [Combatant] lleva hasta [constant MAX_EFFECTS] [StatusSystem.ActiveEffect] en
## [member Combatant.effects], ordenados por id de efecto. Uno por efecto: aplicar uno que ya está lo
## renueva según su [enum StatusEffectDefinition.Stacking]. Uno nuevo cuando ya hay
## [constant MAX_EFFECTS] sustituye al que acaba antes.
## [br][br]
## [b]Aplicar[/b] ([method apply]) en [code]s[/code]: REFRESH alarga el fin a [code]s + D[/code] (el ancla
## no cambia); STACK suma una acumulación (hasta [member StatusTicks.max_stacks]) y alarga el fin; STRONGEST
## se queda con el más fuerte y, si es igual (un mismo efecto siempre lo es: sus datos no cambian), con
## el fin más tardío. Uno nuevo empieza con [code]anchor = s[/code] y una acumulación. SLOW y ROOT
## escriben además su ranura de movimiento en [CombatState] ([method ActionMachine.impose_move_effect]),
## que es lo que cambia la velocidad en el cliente y en el servidor. Evento STATUS 1.
## [br][br]
## [b]Pulsos exactos[/b] ([method step], paso 6 del tick): en [code]anchor + k · P[/code] para
## [code]k = 1, 2…[/code] mientras [code]anchor + k · P ≤ until[/code]; sin renovar son [code]D / P[/code]
## (6 en el sangrado). Primero se reúnen los pulsos de todos y después se aplican, por net_id del afectado
## e id del efecto, saltándose a quien ya esté muerto (o derribado, H3c) en este tick: un pulso que mata
## a mitad no cambia la lista que se recorre. Un pulso de daño lo aplica el [CombatDirector]
## ([signal pulse_damage]: HIT con la fuente del efecto, puede matar y no interrumpe); uno de curación cura
## sin pasar del máximo (HEAL). El último pulso y la caducidad caen en el mismo tick: primero el pulso.
## [br][br]
## [b]Caducidad[/b]: en [code]s ≥ until[/code] se quita (STATUS 2). La ranura de movimiento ya la vacía la
## simulación en ese mismo tick (su fin es el mismo).
## [br][br]
## [b]Limpieza[/b] ([method clear]): al morir, al quedar derribado y al reaparecer se quitan todos sin
## STATUS (DEATH, DOWNED y RESPAWN los borran en el cliente). Al darse de baja una entidad, sus efectos
## sobre los demás se quitan con STATUS 2 ([method forget_author]).
## [br][br]
## No toca la red ni el reloj: avisa con [signal event_emitted] (STATUS y HEAL) y
## [signal pulse_damage], que reenvía y aplica el [CombatDirector].
## [br][br]
## [b]Coste.[/b] Cada [Combatant] guarda en [member Combatant.effects_due] el primer tick en que le pasa algo
## (un pulso o una caducidad), y el sistema el menor de todos: [method step] no recorre a nadie en un tick
## sin sucesos y, en uno con sucesos, salta a quien no tiene nada. Cada efecto guarda su [StatusTicks] para
## no buscarlo en el catálogo.

## Un evento STATUS o HEAL y los net_id implicados (el afectado y el autor).
signal event_emitted(event: NetMessages.EntityEvent, involved: PackedInt32Array)
## Un pulso de daño en el tiempo sobre [param target] de [param author_id] (0 = sin autor):
## [param amount] es [code]pulse_amount × stacks[/code], sin modificadores. Lo aplica el [CombatDirector].
signal pulse_damage(target: Combatant, author_id: int, status: StatusTicks, amount: int, tick: int)

## Efectos activos por entidad como mucho.
const MAX_EFFECTS: int = 8

const _KIND_DOT: int = StatusEffectDefinition.Kind.DAMAGE_OVER_TIME
const _KIND_HOT: int = StatusEffectDefinition.Kind.HEAL_OVER_TIME
const _KIND_DAMAGE_UP: int = StatusEffectDefinition.Kind.DAMAGE_UP
const _KIND_MITIGATION_DOWN: int = StatusEffectDefinition.Kind.MITIGATION_DOWN

# Primer tick en que puede pasarle algo a algún efecto (el menor effects_due; más bajo de la cuenta solo
# cuesta un recorrido de más, que lo vuelve a calcular).
var _next_due: int = Combatant.NO_EFFECTS_DUE

## Contadores de la ejecución (para el informe del servidor).
var stats: Dictionary[StringName, int] = {
	&"status_applied": 0, &"status_removed": 0, &"pulses": 0, &"healed": 0,
}


## Un efecto activo en un [Combatant].
class ActiveEffect:
	## Id del [StatusTicks] en el catálogo.
	var status_id: int = 0
	## net_id de quien lo puso (0 = sin autor: el comando 14). El último que lo renovó.
	var source_id: int = 0
	## Tick desde el que se cuentan los pulsos (el de la primera aplicación).
	var anchor_tick: int = 0
	## Tick en que acaba (exclusivo).
	var until_tick: int = 0
	var stacks: int = 1
	## Sus datos (no cambian mientras vive).
	var status: StatusTicks = null


	## Primer tick posterior a [param after] en que le pasa algo: su siguiente pulso o su caducidad.
	func next_event_after(after: int) -> int:
		if status != null and status.has_pulses():
			var elapsed: int = maxi(after - anchor_tick, 0)
			@warning_ignore("integer_division")
			var pulse: int = anchor_tick + (elapsed / status.pulse_ticks + 1) * status.pulse_ticks
			if pulse <= until_tick:
				return pulse
		return maxi(until_tick, after + 1)


# Un pulso reunido en el primer recorrido de step().
class _Pulse:
	var target: Combatant
	var status: StatusTicks
	var source_id: int = 0
	var stacks: int = 1


## Aplica el efecto [param status_id] del catálogo a [param target] en el tick [param s], puesto por
## [param source_id] (0 = sin autor), durante [param duration_ticks] ticks (0 = los del dato). No hace nada
## sobre un muerto ni con un efecto que no existe. Devuelve si se ha aplicado.
func apply(target: Combatant, status_id: int, source_id: int, s: int, duration_ticks: int = 0) -> bool:
	var status: StatusTicks = CombatCatalog.status(status_id)
	if status == null or target == null or target.is_dead():
		return false
	var duration: int = duration_ticks if duration_ticks > 0 else status.duration_ticks
	if duration <= 0:
		return false
	var until: int = s + duration
	var effect: ActiveEffect = find(target, status_id)
	if effect == null:
		if target.effects.size() >= MAX_EFFECTS:
			_remove_at(target, _earliest_index(target), s, true)
		effect = ActiveEffect.new()
		effect.status_id = status_id
		effect.source_id = source_id
		effect.anchor_tick = s
		effect.until_tick = until
		effect.stacks = 1
		effect.status = status
		_insert_sorted(target, effect)
	else:
		match status.stacking:
			StatusEffectDefinition.Stacking.STACK:
				effect.stacks = mini(effect.stacks + 1, maxi(status.max_stacks, 1))
				effect.source_id = source_id
			StatusEffectDefinition.Stacking.STRONGEST:
				# Un mismo efecto siempre es igual de fuerte (sus datos no cambian): el fin más tardío.
				pass
			_:
				effect.source_id = source_id
		# El fin nunca retrocede (solo podría con la duración del comando 14): así la ranura de
		# movimiento, que también se queda con el más tardío, acaba en el mismo tick que el efecto.
		effect.until_tick = maxi(effect.until_tick, until)
	target.effects_due = mini(target.effects_due, effect.next_event_after(s))
	_next_due = mini(_next_due, target.effects_due)
	if status.is_movement():
		var character: PlayerCharacter = target.get_character()
		if character != null:
			ActionMachine.impose_move_effect(character.combat, status_id, effect.until_tick)
			CombatDirector.commit_state(character)
	stats[&"status_applied"] += 1
	_emit_status(target, s, effect, NetMessages.EntityEvent.StatusOp.APPLIED)
	return true


## Paso 6 del tick [param s] (docs/habilidades.md, sección 4.1) sobre [param list] (por net_id): pulsos y
## caducidades.
func step(s: int, list: Array[Combatant]) -> void:
	if s < _next_due:
		return
	var due: Array[Combatant] = []
	for target: Combatant in list:
		if s >= target.effects_due:
			due.append(target)
	var pulses: Array[_Pulse] = []
	for target: Combatant in due:
		for effect: ActiveEffect in target.effects:
			var status: StatusTicks = effect.status
			if status == null or not status.has_pulses() or s > effect.until_tick:
				continue
			var elapsed: int = s - effect.anchor_tick
			if elapsed <= 0 or elapsed % status.pulse_ticks != 0:
				continue
			var pulse := _Pulse.new()
			pulse.target = target
			pulse.status = status
			pulse.source_id = effect.source_id
			pulse.stacks = effect.stacks
			pulses.append(pulse)
	for pulse: _Pulse in pulses:
		if not _takes_pulses(pulse.target):
			continue
		stats[&"pulses"] += 1
		var amount: int = pulse.status.pulse_amount * pulse.stacks
		if pulse.status.kind == _KIND_DOT:
			pulse_damage.emit(pulse.target, pulse.source_id, pulse.status, amount, s)
		elif pulse.status.kind == _KIND_HOT:
			heal(pulse.target, pulse.source_id, amount,
					CombatSource.make(CombatSource.Kind.STATUS, pulse.status.id), s)
	for target: Combatant in due:
		var index: int = 0
		var next_due: int = Combatant.NO_EFFECTS_DUE
		while index < target.effects.size():
			var effect: ActiveEffect = target.effects[index]
			if s >= effect.until_tick:
				# La ranura de movimiento ya la vació la simulación de este tick (acaba en el mismo).
				_remove_at(target, index, s, true, false)
			else:
				next_due = mini(next_due, effect.next_event_after(s))
				index += 1
		target.effects_due = next_due
	_next_due = Combatant.NO_EFFECTS_DUE
	for target: Combatant in list:
		_next_due = mini(_next_due, target.effects_due)


## Cura [param amount] a [param target] sin pasar del máximo (de parte de [param healer_id]; él mismo
## si es su net_id) con la fuente [param source], y emite HEAL si ha curado algo. Devuelve lo curado.
func heal(target: Combatant, healer_id: int, amount: int, source: int, s: int) -> int:
	if target == null or target.is_dead():
		return 0
	var healed: int = target.restore_health(amount)
	if healed <= 0:
		return 0
	stats[&"healed"] += healed
	var healer: int = 0 if healer_id == target.get_id() else healer_id
	event_emitted.emit(NetMessages.EntityEvent.heal(target.get_id(), s, healer, healed, source),
			_involved(target.get_id(), healer))
	return healed


## Quita todos los efectos de [param target] sin eventos (al morir, al quedar derribado o al reaparecer:
## el cliente los borra con DEATH, DOWNED y RESPAWN) y vacía sus ranuras de movimiento en [CombatState].
## No pasa el estado por encode/decode: lo hace quien llama, que acaba de imponer otra acción.
func clear(target: Combatant) -> void:
	if target == null or target.effects.is_empty():
		return
	var character: PlayerCharacter = target.get_character()
	for effect: ActiveEffect in target.effects:
		var status: StatusTicks = effect.status
		if character != null and status != null and status.is_movement():
			ActionMachine.remove_move_effect(character.combat, effect.status_id)
	stats[&"status_removed"] += target.effects.size()
	target.effects.clear()
	target.effects_due = Combatant.NO_EFFECTS_DUE


## Al darse de baja [param author_id] en el tick [param s]: quita con STATUS 2 los efectos que puso a los
## demás de [param list] (con sus ranuras de movimiento).
func forget_author(author_id: int, s: int, list: Array[Combatant]) -> void:
	if author_id <= 0:
		return
	for target: Combatant in list:
		if target.get_id() == author_id or target.effects.is_empty():
			continue
		var index: int = 0
		while index < target.effects.size():
			if target.effects[index].source_id == author_id:
				_remove_at(target, index, s, true)
			else:
				index += 1


## El efecto [param status_id] de [param target], o null.
func find(target: Combatant, status_id: int) -> ActiveEffect:
	for effect: ActiveEffect in target.effects:
		if effect.status_id == status_id:
			return effect
	return null


## Multiplicador de daño de [param attacker]: [code]1 + Σ DAMAGE_UP[/code] (magnitud por acumulación).
func damage_scale(attacker: Combatant) -> float:
	if attacker == null or attacker.effects.is_empty():
		return 1.0
	return 1.0 + _sum_magnitude(attacker, _KIND_DAMAGE_UP)


## Lo que baja la mitigación del bloqueo de [param victim]: [code]Σ MITIGATION_DOWN[/code] (en valor
## absoluto, por acumulación).
func mitigation_penalty(victim: Combatant) -> float:
	if victim == null or victim.effects.is_empty():
		return 0.0
	return _sum_magnitude(victim, _KIND_MITIGATION_DOWN)


# --- Internos ---------------------------------------------------------------------------------

# Un pulso no se aplica a quien ya ha muerto en este tick (H3c añade: ni a quien ha quedado derribado).
static func _takes_pulses(target: Combatant) -> bool:
	return not target.is_dead()


func _sum_magnitude(combatant: Combatant, kind: int) -> float:
	var total: float = 0.0
	for effect: ActiveEffect in combatant.effects:
		var status: StatusTicks = effect.status
		if status != null and status.kind == kind:
			total += absf(status.magnitude) * float(effect.stacks)
	return total


# Quita el efecto [param index] de [param target]: con [param emit], STATUS 2; con [param clear_slot],
# vacía también su ranura de movimiento (y pasa el estado por encode/decode).
func _remove_at(target: Combatant, index: int, s: int, emit: bool, clear_slot: bool = true) -> void:
	var effect: ActiveEffect = target.effects[index]
	target.effects.remove_at(index)
	stats[&"status_removed"] += 1
	if clear_slot:
		var status: StatusTicks = effect.status
		var character: PlayerCharacter = target.get_character()
		if status != null and status.is_movement() and character != null:
			ActionMachine.remove_move_effect(character.combat, effect.status_id)
			CombatDirector.commit_state(character)
	if emit:
		effect.until_tick = s
		_emit_status(target, s, effect, NetMessages.EntityEvent.StatusOp.REMOVED)


func _emit_status(target: Combatant, s: int, effect: ActiveEffect, operation: int) -> void:
	var stacks: int = effect.stacks if operation == NetMessages.EntityEvent.StatusOp.APPLIED else 0
	event_emitted.emit(NetMessages.EntityEvent.status(target.get_id(), s, effect.source_id, operation,
			effect.status_id, stacks, effect.until_tick), _involved(target.get_id(), effect.source_id))


static func _insert_sorted(target: Combatant, effect: ActiveEffect) -> void:
	var index: int = 0
	while index < target.effects.size() and target.effects[index].status_id < effect.status_id:
		index += 1
	target.effects.insert(index, effect)


# El que acaba antes (empate: el de menor id).
static func _earliest_index(target: Combatant) -> int:
	var earliest: int = 0
	for index: int in range(1, target.effects.size()):
		if target.effects[index].until_tick < target.effects[earliest].until_tick:
			earliest = index
	return earliest


static func _involved(target_id: int, author_id: int) -> PackedInt32Array:
	var involved := PackedInt32Array([target_id])
	if author_id > 0 and author_id != target_id:
		involved.append(author_id)
	return involved
