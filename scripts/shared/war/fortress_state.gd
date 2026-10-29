class_name FortressState
extends RefCounted
## Estado de una fortaleza capturable y su máquina de estados (docs/fuerte.md, secciones 1.3 a 1.5).
## Puro, en ticks y sin nodos: lo avanza el servidor con [method advance] cada tick y el cliente lo
## reconstruye con los campos de OBJECT_STATE ([FortressFields]) y la fórmula de la captura
## ([method progress_at]).
## [br][br]
## [b]Fases[/b] ([enum Phase]): [code]GARRISONED[/code] (el capitán vive, el círculo está
## inactivo), [code]VULNERABLE[/code] (el capitán ha muerto y el círculo está activo),
## [code]CAPTURING[/code] (un reino captura) y [code]CONSOLIDATING[/code] (recién capturado:
## círculo inactivo hasta que llega la guarnición del nuevo dueño). El dueño [member owner] es 0
## mientras el fuerte es neutral (lo guardan los Huecos).
## [br][br]
## [b]Progreso en enteros[/b] (sección 1.3). El máximo es [member progress_max]
## (los ticks de captura por [constant PROGRESS_PER_CAPTURE_TICK]) y las velocidades, en unidades
## por tick, son [code]12 / 16 / 20 / 24[/code] con 1 / 2 / 3 / 4 o más atacantes
## ([method rate_for_count]), [constant EMPTY_DECAY_RATE] con el círculo vacío pasado el retardo y
## [constant FOREIGN_DECAY_RATE] cuando dentro solo hay quien no captura. La captura viaja como
## fórmula, [code]progress(t) = clamp(p0 + rate · (t − t0), 0, P)[/code] ([method progress_at]),
## que se vuelve a anclar ([code]p0[/code], [code]t0[/code] y [code]rate[/code]) cada vez que cambia
## la velocidad. Una velocidad nueva decidida en el tick [code]s[/code] vale desde [code]s[/code]:
## el progreso del tick [code]s + 1[/code] es el de [code]s[/code] más esa velocidad.
## [br][br]
## [b]Efectos que no son del estado[/b]: quien lo usa (el controlador del servidor) mira las
## diferencias tras cada llamada para crear o retirar PNJ, mover la colisión de la puerta, repetir
## avisos y mandar OBJECT_STATE ([method changed_fields_since]). Reparar la puerta con el vano
## ocupado se aplaza ahí: el estado solo cuenta la vida.
## [br][br]
## Compartido: no depende del cliente ni del servidor.

enum Phase { GARRISONED, VULNERABLE, CAPTURING, CONSOLIDATING }

## Unidades de progreso por cada tick de captura de la definición (30 s -> 1800 ticks -> 21 600).
const PROGRESS_PER_CAPTURE_TICK: int = 12
## Velocidad con el círculo vacío pasado el retardo (un tercio de la de un atacante).
const EMPTY_DECAY_RATE: int = -4
## Velocidad cuando dentro solo hay quien no captura (dueño u otro reino).
const FOREIGN_DECAY_RATE: int = -24
## Ticks mínimos entre dos avisos de «fuerte atacado» (60 s).
const ATTACK_NOTICE_INTERVAL_TICKS: int = 3600
## Ticks mínimos entre dos avisos de «captura disputada» (10 s).
const CONTESTED_NOTICE_INTERVAL_TICKS: int = 600
## Cada cuántos ticks recuenta la presencia el servidor (entre recuentos se mantiene la última).
const PRESENCE_RECOUNT_TICKS: int = 6
## Valor de los campos de tick que dicen «nunca» o «ninguno».
const NO_TICK: int = -1

## Reino dueño (código de red; 0 = neutral, los Huecos).
var owner: int = 0
## Fase actual ([enum Phase]).
var phase: int = Phase.GARRISONED
## Tick en el que empezó la fase.
var phase_tick: int = 0
## true si el capitán (el del dueño o el de los Huecos) está vivo.
var captain_alive: bool = true
## Tick en el que reaparece el capitán en la fase VULNERABLE ([constant NO_TICK] si no hay).
var captain_respawn_tick: int = NO_TICK
## Guardias de la guarnición vivos (los cuenta quien los crea, con [method set_guards_alive]).
var guards_alive: int = 0
## Tick en el que reaparecen los guardias muertos ([constant NO_TICK] si no hay ninguno pendiente).
var guards_respawn_tick: int = NO_TICK
## Vida actual y máxima de la puerta.
var gate_health: int = 0
var gate_max: int = 0
## Tick del último golpe a la puerta ([constant NO_TICK] si no la han tocado desde la última
## reparación).
var gate_last_damage_tick: int = NO_TICK
## Reino que captura (0 si nadie).
var capture_realm: int = 0
## Fórmula de la captura: tick de anclaje, velocidad (unidades por tick, puede ser negativa) y
## progreso en ese tick.
var capture_start_tick: int = 0
var capture_rate: int = 0
var capture_progress_at_start: int = 0
## true si la captura (o el círculo) está disputada: dentro hay más de un bando.
var contested: bool = false
## Tick desde el que el círculo está vacío durante una captura ([constant NO_TICK] si no lo está).
var empty_since_tick: int = NO_TICK
## El fuerte cuenta como atacado hasta este tick (no se puede reaparecer en él).
var under_attack_until_tick: int = 0
## Último aviso de «fuerte atacado» y de «captura disputada» ([constant NO_TICK] si ninguno).
var last_attack_notice_tick: int = NO_TICK
var last_contested_notice_tick: int = NO_TICK
## Jugadores presentes en el círculo de cada reino (posiciones 0 a 3), para la interfaz.
var presence: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
## Progreso máximo de la captura ([constant PROGRESS_PER_CAPTURE_TICK] por los ticks de captura).
var progress_max: int = 0
## Tick del último reinicio a neutral (o de la creación), del que cuenta el reinicio periódico.
var last_reset_tick: int = 0
## Factor (1 = normal) por el que se multiplica la velocidad de captura positiva: es el comando de
## depuración [code]fort_capture_speed[/code]. No viaja por la red: el cliente solo ve la velocidad ya
## multiplicada en [member capture_rate]. El decaimiento no se multiplica.
var capture_rate_multiplier: int = 1

# Constantes de la definición en ticks, copiadas al crear el estado para que los métodos de la
# interfaz (que no reciben la definición) las tengan.
var _captain_respawn_ticks: int = 0
var _under_attack_ticks: int = 0
var _gate_repair_ticks: int = 0
# Mayor número de guardias que ha habido en la guarnición actual: los que faltan son los que
# reaparecen.
var _guards_expected: int = 0


## Estado de una fortaleza recién creada: neutral, guardada por los Huecos y su capitán, con la
## puerta entera y sin captura.
static func initial(def: FortressDefinition, tick: int) -> FortressState:
	var state := FortressState.new()
	state._configure(def)
	state.phase_tick = tick
	state.capture_start_tick = tick
	state.last_reset_tick = tick
	state.gate_health = def.gate_health
	state.gate_max = def.gate_health
	return state


## Velocidad de captura (unidades por tick) con [param count] atacantes dentro: 12, 16, 20 y 24 con
## 1, 2, 3 y 4 o más; 0 si no hay ninguno.
static func rate_for_count(count: int) -> int:
	match count:
		0:
			return 0
		1:
			return 12
		2:
			return 16
		3:
			return 20
	return 24 if count > 3 else 0


## Avanza al tick [param tick] con la presencia actual ([param presence_counts]: el recuento por
## reino, posiciones 0 a 3, de [method FortressPresence.count]). Se llama cada tick, para que las
## transiciones caigan en el tick exacto; el recuento se hace cada
## [constant PRESENCE_RECOUNT_TICKS] ticks y se repite entre medias. Devuelve los ids de
## [WarEvents] emitidos, en orden.
func advance(def: FortressDefinition, tick: int, presence_counts: PackedInt32Array) -> PackedInt32Array:
	_set_presence(presence_counts)
	var reset_ticks: int = def.reset_to_neutral_ticks()
	if reset_ticks > 0 and tick - last_reset_tick >= reset_ticks:
		return reset_to_neutral(def, tick)
	_arm_guards_timer(def, tick)
	match phase:
		Phase.VULNERABLE:
			return _advance_vulnerable(def, tick)
		Phase.CAPTURING:
			return _advance_capturing(def, tick)
		Phase.CONSOLIDATING:
			if tick - phase_tick >= def.consolidation_ticks():
				_enter_garrisoned(tick)
	return PackedInt32Array()


## Muere el capitán en el tick [param tick], a manos del reino [param killer_realm]. Si estaba
## guardando el fuerte, pasa a VULNERABLE (el círculo se activa y el capitán reaparecerá a los
## [member FortressDefinition.captain_respawn_s] si nadie captura) y devuelve
## [constant WarEvents.CAPTAIN_DOWN]; en cualquier otra fase no hace nada.
func on_captain_died(tick: int, _killer_realm: int) -> PackedInt32Array:
	var events := PackedInt32Array()
	if phase != Phase.GARRISONED or not captain_alive:
		return events
	captain_alive = false
	phase = Phase.VULNERABLE
	phase_tick = tick
	captain_respawn_tick = tick + _captain_respawn_ticks
	events.append(WarEvents.CAPTAIN_DOWN)
	return events


## El capitán vuelve antes de plazo: la «reaparición completa» de los Huecos (docs/fuerte.md, 4.3)
## incluye al Capitán del Vado cuando el fuerte sigue neutral y sin jugadores cerca. Solo hace algo en
## la fase VULNERABLE (no mientras alguien captura): vuelve a GARRISONED con el capitán vivo.
## Devuelve true si el capitán ha reaparecido.
func respawn_captain(tick: int) -> bool:
	if phase != Phase.VULNERABLE:
		return false
	_enter_garrisoned(tick)
	return true


## La puerta recibe [param amount] de daño del reino [param attacker_realm] en el tick [param tick].
## Resta vida (hasta 0), anota el golpe (la puerta se repara tras un rato sin daño y el fuerte
## cuenta como atacado) y devuelve los avisos: [constant WarEvents.UNDER_ATTACK] (como mucho uno
## por minuto) y [constant WarEvents.GATE_BROKEN] si este golpe la rompe. Una puerta ya rota o un
## daño que no es positivo no hacen nada.
func on_gate_damaged(tick: int, amount: int, attacker_realm: int) -> PackedInt32Array:
	var events := PackedInt32Array()
	if amount <= 0 or gate_health <= 0:
		return events
	gate_health = maxi(gate_health - amount, 0)
	gate_last_damage_tick = tick
	_mark_under_attack(tick)
	if claim_attack_notice(tick):
		events.append(WarEvents.UNDER_ATTACK)
	if gate_health == 0:
		events.append(WarEvents.GATE_BROKEN)
	return events


## Un defensor del fuerte recibe daño del reino [param attacker_realm] en el tick [param tick]: el
## fuerte cuenta como atacado durante [member FortressDefinition.under_attack_s] más. No devuelve
## avisos; quien quiera el de «fuerte atacado» lo pide con [method claim_attack_notice].
func on_defender_damaged(tick: int, _attacker_realm: int) -> void:
	_mark_under_attack(tick)


## Concede el aviso de «fuerte atacado» si pasó al menos un minuto desde el último, y lo anota.
## [method on_gate_damaged] ya lo usa para los golpes a la puerta; el controlador lo llama para los
## golpes a los defensores.
func claim_attack_notice(tick: int) -> bool:
	if last_attack_notice_tick != NO_TICK and tick - last_attack_notice_tick < ATTACK_NOTICE_INTERVAL_TICKS:
		return false
	last_attack_notice_tick = tick
	return true


## Dice cuántos guardias de la guarnición están vivos ([param count]). El mayor número que se
## indica es el de la guarnición completa; si faltan, [method advance] arma el tiempo de
## reaparición ([method guards_respawn_due]).
func set_guards_alive(count: int) -> void:
	guards_alive = maxi(count, 0)
	_guards_expected = maxi(_guards_expected, guards_alive)
	if guards_alive >= _guards_expected:
		guards_respawn_tick = NO_TICK


## true si en el tick [param tick] toca reponer los guardias que faltan: la fase es GARRISONED o
## VULNERABLE y ha pasado [member FortressDefinition.guard_respawn_s] desde que se notó que faltaban.
## Quien los crea llama después a [method set_guards_alive] con el total.
func guards_respawn_due(tick: int) -> bool:
	if phase != Phase.GARRISONED and phase != Phase.VULNERABLE:
		return false
	return guards_respawn_tick != NO_TICK and guards_alive < _guards_expected \
			and tick >= guards_respawn_tick


## Devuelve el fuerte a neutral en el tick [param tick] (reinicio periódico o comando
## [code]fort_reset[/code]): GARRISONED sin dueño, con los Huecos y el Capitán del Vado, la puerta
## entera y la captura a cero. Los jugadores que haya dentro no se mueven. Devuelve
## [constant WarEvents.FORT_RESET].
func reset_to_neutral(def: FortressDefinition, tick: int) -> PackedInt32Array:
	_configure(def)
	owner = 0
	phase = Phase.GARRISONED
	phase_tick = tick
	captain_alive = true
	captain_respawn_tick = NO_TICK
	guards_alive = 0
	guards_respawn_tick = NO_TICK
	_guards_expected = 0
	gate_health = def.gate_health
	gate_max = def.gate_health
	gate_last_damage_tick = NO_TICK
	_clear_capture(tick)
	under_attack_until_tick = tick
	last_attack_notice_tick = NO_TICK
	last_contested_notice_tick = NO_TICK
	last_reset_tick = tick
	return PackedInt32Array([WarEvents.FORT_RESET])


## Progreso de la captura (0 a [member progress_max]) en el tick [param tick] (puede ser
## fraccionario: el cliente lo evalúa en su tick de dibujo). Es la fórmula
## [code]clamp(p0 + rate · (t − t0), 0, P)[/code], redondeada hacia abajo.
func progress_at(tick: float) -> int:
	var value: float = float(capture_progress_at_start) + float(capture_rate) * (tick - float(capture_start_tick))
	return clampi(floori(value), 0, progress_max)


## Campos de [FortressFields] cuyo valor es distinto del de [param other], en orden de id. Es lo que
## va en un OBJECT_STATE tras avanzar el estado desde una copia ([method duplicate_state]).
func changed_fields_since(other: FortressState) -> PackedInt32Array:
	var changed := PackedInt32Array()
	for field_id: int in FortressFields.all_ids():
		if FortressFields.get_value(self, field_id) != FortressFields.get_value(other, field_id):
			changed.append(field_id)
	return changed


## Copia independiente (para comparar antes y después de avanzar, o para guardar la historia).
func duplicate_state() -> FortressState:
	var copy := FortressState.new()
	copy.copy_from(self)
	return copy


## Copia en este estado todo el de [param other].
func copy_from(other: FortressState) -> void:
	owner = other.owner
	phase = other.phase
	phase_tick = other.phase_tick
	captain_alive = other.captain_alive
	captain_respawn_tick = other.captain_respawn_tick
	guards_alive = other.guards_alive
	guards_respawn_tick = other.guards_respawn_tick
	gate_health = other.gate_health
	gate_max = other.gate_max
	gate_last_damage_tick = other.gate_last_damage_tick
	capture_realm = other.capture_realm
	capture_start_tick = other.capture_start_tick
	capture_rate = other.capture_rate
	capture_progress_at_start = other.capture_progress_at_start
	contested = other.contested
	empty_since_tick = other.empty_since_tick
	under_attack_until_tick = other.under_attack_until_tick
	last_attack_notice_tick = other.last_attack_notice_tick
	last_contested_notice_tick = other.last_contested_notice_tick
	presence = other.presence.duplicate()
	progress_max = other.progress_max
	last_reset_tick = other.last_reset_tick
	capture_rate_multiplier = other.capture_rate_multiplier
	_captain_respawn_ticks = other._captain_respawn_ticks
	_under_attack_ticks = other._under_attack_ticks
	_gate_repair_ticks = other._gate_repair_ticks
	_guards_expected = other._guards_expected


## true si el círculo de captura está activo (VULNERABLE o CAPTURING): solo entonces cuenta la
## presencia.
func is_circle_active() -> bool:
	return phase == Phase.VULNERABLE or phase == Phase.CAPTURING


## true si la puerta está rota (vida 0).
func is_gate_broken() -> bool:
	return gate_health <= 0


## true si en el tick [param tick] toca reparar la puerta: está dañada y pasó
## [member FortressDefinition.gate_repair_after_s] desde el último golpe. Quien la repara (no
## mientras alguien ocupe el vano) llama a [method repair_gate].
func gate_repair_due(tick: int) -> bool:
	return gate_health < gate_max and gate_last_damage_tick != NO_TICK \
			and tick - gate_last_damage_tick >= _gate_repair_ticks


## Repara la puerta del todo.
func repair_gate() -> void:
	gate_health = gate_max
	gate_last_damage_tick = NO_TICK


## Reino que acompaña al aviso [param event_id] en el ENTITY_EVENT: el captor en «captura iniciada»
## y «captura disputada», el dueño en «fuerte capturado», 0 en «fuerte reiniciado» y
## [param caller_realm] (el reino que dio el golpe o mató al capitán) en los demás.
func event_realm(event_id: int, caller_realm: int = 0) -> int:
	match event_id:
		WarEvents.CAPTURE_STARTED, WarEvents.CAPTURE_CONTESTED:
			return capture_realm
		WarEvents.FORT_CAPTURED:
			return owner
		WarEvents.FORT_RESET:
			return 0
	return caller_realm


# --- Interno ----------------------------------------------------------------------------------

# Copia de la definición lo que necesitan los métodos que no la reciben.
func _configure(def: FortressDefinition) -> void:
	progress_max = def.capture_ticks() * PROGRESS_PER_CAPTURE_TICK
	_captain_respawn_ticks = def.captain_respawn_ticks()
	_under_attack_ticks = def.under_attack_ticks()
	_gate_repair_ticks = def.gate_repair_after_ticks()


func _set_presence(counts: PackedInt32Array) -> void:
	for realm: int in FortressFields.PRESENCE_REALMS:
		presence[realm] = counts[realm] if realm < counts.size() else 0


func _presence_of(realm: int) -> int:
	return presence[realm] if realm >= 0 and realm < presence.size() else 0


# Reinos (códigos 1 a 3) con jugadores dentro que no son el dueño: los atacantes de la tabla.
func _attacker_realms() -> Array[int]:
	var attackers: Array[int] = []
	for realm: int in range(1, FortressFields.PRESENCE_REALMS):
		if realm != owner and presence[realm] > 0:
			attackers.append(realm)
	return attackers


# true si hay jugadores del dueño dentro (con el fuerte neutral, nunca).
func _owner_present() -> bool:
	return owner != 0 and _presence_of(owner) > 0


func _mark_under_attack(tick: int) -> void:
	under_attack_until_tick = maxi(under_attack_until_tick, tick + _under_attack_ticks)


# Arma el tiempo de reaparición de los guardias la primera vez que se nota que faltan.
func _arm_guards_timer(def: FortressDefinition, tick: int) -> void:
	if guards_respawn_tick == NO_TICK and guards_alive < _guards_expected \
			and (phase == Phase.GARRISONED or phase == Phase.VULNERABLE):
		guards_respawn_tick = tick + def.guard_respawn_ticks()


# Marca la disputa. Devuelve true si toca el aviso de «captura disputada»: solo al entrar en disputa
# (no mientras sigue) y con un mínimo de 10 s entre avisos.
func _contest(tick: int) -> bool:
	if contested:
		return false
	contested = true
	if last_contested_notice_tick == NO_TICK \
			or tick - last_contested_notice_tick >= CONTESTED_NOTICE_INTERVAL_TICKS:
		last_contested_notice_tick = tick
		return true
	return false


func _enter_garrisoned(tick: int) -> void:
	phase = Phase.GARRISONED
	phase_tick = tick
	captain_alive = true
	captain_respawn_tick = NO_TICK
	contested = false
	_clear_capture(tick)


func _clear_capture(tick: int) -> void:
	capture_realm = 0
	capture_start_tick = tick
	capture_rate = 0
	capture_progress_at_start = 0
	contested = false
	empty_since_tick = NO_TICK


func _advance_vulnerable(_def: FortressDefinition, tick: int) -> PackedInt32Array:
	var events := PackedInt32Array()
	if captain_respawn_tick != NO_TICK and tick >= captain_respawn_tick:
		_enter_garrisoned(tick)
		return events
	var attackers: Array[int] = _attacker_realms()
	var owner_here: bool = _owner_present()
	if attackers.size() == 1 and not owner_here:
		contested = false
		_start_capture(tick, attackers[0])
		events.append(WarEvents.CAPTURE_STARTED)
	elif attackers.size() >= 2 or (attackers.size() == 1 and owner_here):
		if _contest(tick):
			events.append(WarEvents.CAPTURE_CONTESTED)
	else:
		contested = false
	return events


# Empieza (o cambia de captor) la captura del reino [param realm] con progreso 0.
func _start_capture(tick: int, realm: int) -> void:
	if phase != Phase.CAPTURING:
		phase = Phase.CAPTURING
		phase_tick = tick
	capture_realm = realm
	capture_start_tick = tick
	capture_progress_at_start = 0
	capture_rate = rate_for_count(_presence_of(realm)) * maxi(capture_rate_multiplier, 1)
	contested = false
	empty_since_tick = NO_TICK


func _advance_capturing(def: FortressDefinition, tick: int) -> PackedInt32Array:
	var events := PackedInt32Array()
	var progress: int = progress_at(tick)
	if progress >= progress_max:
		_complete_capture(tick)
		events.append(WarEvents.FORT_CAPTURED)
		return events

	var captors: int = _presence_of(capture_realm)
	var others: int = 0
	for realm: int in range(1, FortressFields.PRESENCE_REALMS):
		if realm != capture_realm:
			others += presence[realm]
	var new_rate: int = capture_rate
	if captors > 0 and others == 0:
		# Solo el captor: avanza según cuántos son.
		contested = false
		empty_since_tick = NO_TICK
		new_rate = rate_for_count(captors) * maxi(capture_rate_multiplier, 1)
	elif captors > 0:
		# El captor y alguien más (el dueño u otro reino): se congela.
		empty_since_tick = NO_TICK
		if _contest(tick):
			events.append(WarEvents.CAPTURE_CONTESTED)
		new_rate = 0
	elif others > 0:
		# Sin el captor y con otros dentro: la captura retrocede deprisa.
		contested = false
		empty_since_tick = NO_TICK
		new_rate = FOREIGN_DECAY_RATE
	else:
		# Nadie: tras el retardo, la captura decae despacio.
		contested = false
		if empty_since_tick == NO_TICK:
			empty_since_tick = tick
		new_rate = EMPTY_DECAY_RATE if tick - empty_since_tick >= def.decay_after_empty_ticks() else 0
	if new_rate != capture_rate:
		capture_progress_at_start = progress
		capture_start_tick = tick
		capture_rate = new_rate

	# Con la captura a cero y sin avanzar: el único reino que no es el dueño y está dentro la toma;
	# si no hay uno solo (nadie, o varios, o el dueño con él), vuelve a VULNERABLE.
	if progress <= 0 and new_rate <= 0:
		var attackers: Array[int] = _attacker_realms()
		if attackers.size() == 1 and not _owner_present():
			_start_capture(tick, attackers[0])
			events.append(WarEvents.CAPTURE_STARTED)
		else:
			_fall_back_to_vulnerable(tick)
	return events


# La captura se ha quedado en cero: el fuerte vuelve a VULNERABLE y el capitán tiene un nuevo plazo
# para reaparecer.
func _fall_back_to_vulnerable(tick: int) -> void:
	phase = Phase.VULNERABLE
	phase_tick = tick
	captain_respawn_tick = tick + _captain_respawn_ticks
	var was_contested: bool = contested
	_clear_capture(tick)
	contested = was_contested


# Captura completa: el captor es el nuevo dueño, la puerta se repara, se retiran los defensores del
# dueño anterior y empieza la consolidación.
func _complete_capture(tick: int) -> void:
	owner = capture_realm
	phase = Phase.CONSOLIDATING
	phase_tick = tick
	captain_alive = false
	captain_respawn_tick = NO_TICK
	guards_alive = 0
	guards_respawn_tick = NO_TICK
	_guards_expected = 0
	gate_health = gate_max
	gate_last_damage_tick = NO_TICK
	_clear_capture(tick)
