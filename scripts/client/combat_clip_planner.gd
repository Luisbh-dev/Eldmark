class_name CombatClipPlanner
extends RefCounted
## Elige el clip y el instante de la animación de combate (ART-08). Es una función pura de la acción
## ([CombatState.Action]), su fase, el paso del combo y el tiempo transcurrido: no toca nodos, así que
## se prueba sin esqueleto. [CombatAnimationLayer] la llama en cada fotograma y el
## [CombatPoseModifier] pone la pose.
## [br][br]
## [b]Reescalado.[/b] Cada fase de un ataque ocupa [code]windup_ticks[/code], [code]active_ticks[/code] o
## [code]recovery_ticks[/code] ticks en los datos de combate. El tramo del clip asignado a esa fase
## ([CombatActionAnim]) se recorre exactamente en ese tiempo: [member Plan.speed] es la velocidad de
## reproducción (segundos de clip por segundo real) que lo consigue. Así el contacto de la hoja, que
## el clip marca con [member CombatActionAnim.contact_s], cae dentro de la ventana activa
## ([method contact_tick]).
## [br][br]
## Las acciones sin fases (esquiva, bloqueo, carga, controles, muerte) reproducen el primer tramo en la
## duración que dan los datos (la de la esquiva) o el propio recurso; con
## [member CombatActionAnim.hold_end] se quedan en la última pose y con [member CombatActionAnim.loop] se
## repiten.
## [br][br]
## [b]Fase 4[/b] (docs/habilidades.md, sección 6.6; provisional, pendiente del ojo del usuario): una
## habilidad se anima con la entrada de su nombre ([code]shield_bash[/code]...; con tres tramos se
## reescalan a su lanzamiento, activo y recuperación, como un ataque), una poción con
## [constant KEY_DRINK], el cambio de arma con [constant KEY_SWAP], derribado con [constant KEY_DOWNED]
## (quieto) o [constant KEY_DOWNED_CRAWL] (arrastrándose), levantar y rematar con [constant KEY_REVIVE] y
## [constant KEY_EXECUTE], y el levantarse tras ser levantado con [constant KEY_GET_UP]. Cada arma tiene su
## juego de clips ([method CombatAnimationLayer.clips_for]).

## Claves de las acciones que no son ataques (las de los ataques son sus nombres en el catálogo).
const KEY_CHARGE: StringName = &"charge"
const KEY_BLOCK: StringName = &"block"
const KEY_DODGE: StringName = &"dodge"
const KEY_STAGGER: StringName = &"stagger"
const KEY_STUN: StringName = &"stun"
const KEY_DEAD: StringName = &"dead"
const KEY_DRINK: StringName = &"drink"
const KEY_SWAP: StringName = &"swap"
const KEY_DOWNED: StringName = &"downed"
const KEY_DOWNED_CRAWL: StringName = &"downed_crawl"
const KEY_REVIVE: StringName = &"revive"
const KEY_EXECUTE: StringName = &"execute"
const KEY_GET_UP: StringName = &"get_up"


## Lo que debe verse en este instante.
class Plan:
	## Clave de la entrada ([member CombatActionAnim.key]).
	var key: StringName = &""
	## Clip «biblioteca/nombre».
	var animation: StringName = &""
	## Instante del clip (s).
	var time_s: float = 0.0
	## Segundos de clip por segundo real en el tramo actual (0 si el tramo es instantáneo).
	var speed: float = 0.0
	## Fase del ataque ([constant ActionMachine.PHASE_WINDUP]...), o [constant ActionMachine.PHASE_NONE].
	var phase: int = ActionMachine.PHASE_NONE
	var upper_body: bool = false
	var hold: bool = false
	var blend_in_s: float = 0.06
	var blend_out_s: float = 0.12
	## Tramo del clip que se está recorriendo y los segundos reales que le toca durar.
	var from_s: float = 0.0
	var to_s: float = 0.0
	var duration_s: float = 0.0


## Clave de la entrada de [param action] con el arma [param weapon]: el nombre del ligero
## [param combo_index] (0 a 2) o del fuerte; en una ABILITY, el nombre de la habilidad
## [param ability_id] (o [constant KEY_DRINK] si es una poción); derribado, [constant KEY_DOWNED_CRAWL]
## si [param moving]; para el resto, la clave fija de la acción. Vacía si la acción no se anima (NONE).
static func key_for(weapon: WeaponTicks, action: int, combo_index: int, ability_id: int = 0,
		moving: bool = false) -> StringName:
	match action:
		CombatState.Action.LIGHT:
			if weapon == null or weapon.light_ids.is_empty():
				return &""
			var attack: AttackTicks = CombatCatalog.attack(
					weapon.light_ids[clampi(combo_index, 0, weapon.light_ids.size() - 1)])
			return attack.name if attack != null else &""
		CombatState.Action.HEAVY:
			var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id) if weapon != null else null
			return heavy.name if heavy != null else &""
		CombatState.Action.CHARGE:
			return KEY_CHARGE
		CombatState.Action.BLOCK:
			return KEY_BLOCK
		CombatState.Action.DODGE:
			return KEY_DODGE
		CombatState.Action.STAGGER:
			return KEY_STAGGER
		CombatState.Action.STUN:
			return KEY_STUN
		CombatState.Action.DEAD:
			return KEY_DEAD
		CombatState.Action.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(ability_id)
			if ability == null:
				return &""
			return KEY_DRINK if ability.is_consumable() else ability.name
		CombatState.Action.SWAP:
			return KEY_SWAP
		CombatState.Action.DOWNED:
			return KEY_DOWNED_CRAWL if moving else KEY_DOWNED
		CombatState.Action.REVIVE:
			return KEY_REVIVE
		CombatState.Action.EXECUTE:
			return KEY_EXECUTE
	return &""


## Habilidad del byte de acción de un remoto: la de la ranura [param slot] (0-2) del arma
## [param weapon], o la primera poción si [param slot] es 3 (los dos consumibles se animan igual).
static func ability_of_slot(weapon: WeaponTicks, slot: int) -> int:
	if slot == 3:
		var consumables: PackedInt32Array = CombatCatalog.consumable_ids()
		return consumables[0] if not consumables.is_empty() else 0
	return weapon.ability_id(slot) if weapon != null else 0


## El plan para [param action] en la fase [param phase] cuando lleva [param phase_elapsed_ticks]
## ticks (con fracción) en ella. [param combo_index] solo importa en los ligeros;
## [param control_ticks] es la duración del tambaleo o aturdimiento si se conoce (0 = la del
## recurso); [param ability_id], la habilidad de una ABILITY; [param moving], si un derribado se
## arrastra. Devuelve null si la acción no tiene animación (o no hay entrada para ella).
static func plan(clips: CombatClipSet, weapon: WeaponTicks, action: int, phase: int,
		combo_index: int, phase_elapsed_ticks: float, control_ticks: int = 0, ability_id: int = 0,
		moving: bool = false) -> Plan:
	if clips == null or action == CombatState.Action.NONE:
		return null
	var key: StringName = key_for(weapon, action, combo_index, ability_id, moving)
	if key.is_empty():
		return null
	return plan_entry(clips, key, weapon, action, phase, phase_elapsed_ticks, control_ticks, ability_id)


## El plan de la entrada [param key] (ya elegida) para [param action]: ver [method plan]. Lo usa también
## la capa para [constant KEY_GET_UP], que no es la clave de ninguna acción.
static func plan_entry(clips: CombatClipSet, key: StringName, weapon: WeaponTicks, action: int,
		phase: int, phase_elapsed_ticks: float, control_ticks: int = 0, ability_id: int = 0) -> Plan:
	if clips == null:
		return null
	var entry: CombatActionAnim = clips.find(key)
	if entry == null:
		return null
	var tick_rate: float = float(Engine.physics_ticks_per_second)
	var segment: CombatClipSegment
	var phase_ticks: float
	var used_phase: int = ActionMachine.PHASE_NONE
	var ability: AbilityTicks = CombatCatalog.ability(ability_id) \
			if action == CombatState.Action.ABILITY else null
	if entry.is_attack() and (action == CombatState.Action.LIGHT or action == CombatState.Action.HEAVY):
		var attack: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(key))
		if attack == null:
			return null
		used_phase = clampi(phase, ActionMachine.PHASE_WINDUP, ActionMachine.PHASE_RECOVERY)
		segment = entry.segment_for_phase(used_phase)
		phase_ticks = float(_phase_length_ticks(attack, used_phase))
	elif entry.is_attack() and ability != null:
		used_phase = clampi(phase, ActionMachine.PHASE_WINDUP, ActionMachine.PHASE_RECOVERY)
		segment = entry.segment_for_phase(used_phase)
		phase_ticks = float(_ability_phase_ticks(ability, used_phase))
	else:
		segment = entry.windup
		phase_ticks = _action_length_ticks(entry, weapon, action, control_ticks)
	if segment == null:
		return null
	var result := Plan.new()
	result.key = key
	result.animation = segment.animation
	result.phase = used_phase
	result.upper_body = entry.upper_body
	result.hold = entry.hold_end
	result.blend_in_s = entry.blend_in_s
	result.blend_out_s = entry.blend_out_s
	result.from_s = segment.from_s
	result.to_s = segment.to_s
	result.duration_s = phase_ticks / tick_rate
	var progress: float = 1.0
	if phase_ticks > 0.0:
		if entry.loop:
			progress = fposmod(phase_elapsed_ticks, phase_ticks) / phase_ticks
		else:
			progress = clampf(phase_elapsed_ticks / phase_ticks, 0.0, 1.0)
		result.speed = segment.length_s() / result.duration_s
	result.time_s = lerpf(segment.from_s, segment.to_s, progress)
	return result


## Ticks (desde el inicio de la acción) en los que el clip llega a [member CombatActionAnim.contact_s]
## con el reescalado de [param attack]; -1 si la entrada no marca contacto o no es de ataque.
## Debe caer dentro de la ventana del golpe activo ([method AttackTicks.active_from] a
## [method AttackTicks.active_to]) con un tick de margen.
static func contact_tick(entry: CombatActionAnim, attack: AttackTicks) -> float:
	if entry == null or attack == null or not entry.is_attack() or entry.contact_s < 0.0:
		return -1.0
	var segment: CombatClipSegment = entry.active
	var length: float = segment.length_s()
	if length <= 0.0:
		return -1.0
	var progress: float = (entry.contact_s - segment.from_s) / length
	return float(attack.active_from()) + progress * float(attack.active_ticks)


## Tick (desde el inicio de la acción) en el que empieza la fase [param phase] de [param attack].
static func phase_start_ticks(attack: AttackTicks, phase: int) -> int:
	match phase:
		ActionMachine.PHASE_ACTIVE:
			return attack.windup_ticks
		ActionMachine.PHASE_RECOVERY:
			return attack.windup_ticks + attack.active_ticks
	return 0


## Tick (desde el inicio de la habilidad) en el que empieza la fase [param phase] de [param ability].
static func ability_phase_start_ticks(ability: AbilityTicks, phase: int) -> int:
	match phase:
		ActionMachine.PHASE_ACTIVE:
			return ability.cast_ticks
		ActionMachine.PHASE_RECOVERY:
			return ability.cast_ticks + ability.active_ticks
	return 0


static func _ability_phase_ticks(ability: AbilityTicks, phase: int) -> int:
	match phase:
		ActionMachine.PHASE_ACTIVE:
			return ability.active_ticks
		ActionMachine.PHASE_RECOVERY:
			return ability.recovery_ticks
	return ability.cast_ticks


static func _phase_length_ticks(attack: AttackTicks, phase: int) -> int:
	match phase:
		ActionMachine.PHASE_ACTIVE:
			return attack.active_ticks
		ActionMachine.PHASE_RECOVERY:
			return attack.recovery_ticks
	return attack.windup_ticks


# Duración (ticks) del tramo único de una acción sin fases: la esquiva dura lo que dice el arma, los
# controles lo que dura el control si se sabe; el resto, lo que dice el recurso.
static func _action_length_ticks(entry: CombatActionAnim, weapon: WeaponTicks, action: int,
		control_ticks: int) -> float:
	if action == CombatState.Action.DODGE and weapon != null and weapon.dodge != null:
		return float(weapon.dodge.duration_ticks)
	if (action == CombatState.Action.STAGGER or action == CombatState.Action.STUN) \
			and control_ticks > 0:
		return float(control_ticks)
	var data: CombatTables = CombatCatalog.tables()
	match action:
		CombatState.Action.SWAP:
			return float(data.swap_ticks)
		CombatState.Action.REVIVE:
			return float(data.revive_ticks)
		CombatState.Action.EXECUTE:
			return float(data.execute_ticks)
	return entry.duration_s * float(Engine.physics_ticks_per_second)
