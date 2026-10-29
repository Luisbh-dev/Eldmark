class_name InputQueue
extends RefCounted
## Cola de entradas de un jugador (docs/red.md, secciones 4.1, 8.2 y 12).
## [br][br]
## Anillo de [constant CAPACITY] huecos indexado por tick, con el tick como etiqueta. El servidor
## llama a [method push] con cada entrada que llega y a [method take] una vez por tick: la entrada
## del tick T se aplica exactamente en el tick T, y si no ha llegado se sustituye. Una entrada por
## jugador y tick: enviar más no hace correr más, y el servidor nunca espera a una entrada.
## [br][br]
## [b]La sustituta nunca inventa flancos.[/b] Repite la máscara completa de botones de la última
## entrada aplicada, así que un botón mantenido durante una pérdida (JUMP, PRIMARY, DODGE) no
## reaparece como pulsación nueva cuando llega la siguiente entrada real, porque
## [member PlayerCharacter.prev_buttons] ya lo contiene. Tras
## [constant NetProtocol.REPEAT_MOVE_TICKS] ticks sin entradas reales el movimiento pasa a 0 (un
## cliente que se ha ido en silencio se queda quieto) y los botones se conservan.
## [br][br]
## [b]La sustituta lleva [constant PlayerInput.SUBSTITUTED].[/b] La máquina de acciones del combate
## (docs/combate.md, sección 3.2) lo respeta: una entrada repetida no cuenta pulsación mantenida,
## no convierte un ligero en carga, no lanza el fuerte al llegar a la carga máxima y no abre
## ventanas de parada, de modo que ninguna pérdida de paquetes inventa un fuerte o una parada.

## Resultado de [method push].
enum PushResult {
	## Primera copia de una entrada dentro de la ventana: se guarda.
	ACCEPTED,
	## Copia redundante (o más antigua que lo ya consumido): se ignora.
	DUPLICATE,
	## Llegó tarde: ese tick ya se había sustituido. Se cuenta una vez y no se aplica.
	LATE,
	## Demasiado por delante del servidor: se descarta.
	TOO_EARLY,
}

## Ticks que mira [method get_typical_lead] hacia atrás (menos que [constant CAPACITY]: los huecos más
## viejos ya pueden estar sobrescritos).
const LEAD_WINDOW_TICKS: int = 60

## Huecos del anillo. Mayor que la ventana de aceptación
## ([constant NetProtocol.MAX_INPUT_LEAD_TICKS] + 1), así que dos ticks aceptados nunca comparten
## hueco.
const CAPACITY: int = 64

## Estado de un hueco del anillo.
enum SlotState { EMPTY, RECEIVED, CONSUMED_REAL, SUBSTITUTED, LATE_SEEN }

## Entradas que llegaron tarde (ese tick ya se había sustituido). Cada una cuenta una vez.
var late_count: int = 0
## Entradas descartadas por llegar demasiado por delante.
var too_early_count: int = 0
## Entradas sustituidas desde [method reset] (las que no llegaron a tiempo).
var substitutions_total: int = 0

var _slots: Array[Slot] = []
var _last_consumed: int = 0
var _last_real_tick: int = 0
var _last_applied: PlayerInput = PlayerInput.new()
# view_offset_q y antelación de la última entrada real consumida (para el rebobinado de un tick cuya
# entrada se sustituyó).
var _last_real_view_offset_q: int = 0
var _last_real_lead: int = 0
# Antelación mínima desde la última llamada a pop_min_lead(); _has_lead dice si hay datos.
var _min_lead: int = 0
var _has_lead: bool = false


## Un hueco del anillo.
class Slot:
	var tick: int = -1
	var state: int = SlotState.EMPTY
	var input: PlayerInput = null
	var view_offset_q: int = -1
	## Antelación con la que llegó la primera copia (tick de la entrada menos el que el servidor
	## simulaba a continuación); 0 en las sustituidas.
	var lead: int = 0


	func set_input(new_tick: int, new_state: int, new_input: PlayerInput,
			new_view_offset_q: int, new_lead: int = 0) -> void:
		tick = new_tick
		state = new_state
		input = new_input
		view_offset_q = new_view_offset_q
		lead = new_lead


func _init() -> void:
	_slots.resize(CAPACITY)
	for i: int in CAPACITY:
		_slots[i] = Slot.new()


## Deja la cola lista para un jugador que aparece tras simular el tick [param spawn_tick]: ese
## tick cuenta como consumido y [param neutral] (la entrada neutra del alta, ya cuantizada) es la
## última aplicada. Pone a 0 los contadores.
func reset(spawn_tick: int, neutral: PlayerInput) -> void:
	for slot: Slot in _slots:
		slot.set_input(-1, SlotState.EMPTY, null, -1)
	_last_consumed = spawn_tick
	_last_real_tick = spawn_tick
	_last_real_view_offset_q = 0
	_last_real_lead = 0
	_last_applied = neutral.duplicate_input()
	late_count = 0
	too_early_count = 0
	substitutions_total = 0
	_min_lead = 0
	_has_lead = false


## Guarda [param input] (con su [param view_offset_q]) si cae dentro de la ventana
## (último consumido, [param next_tick] + [constant NetProtocol.MAX_INPUT_LEAD_TICKS]].
## [param next_tick] es el tick que el servidor simulará a continuación.
## [br][br]
## Gana la primera copia de cada tick aunque la segunda sea distinta. La antelación solo se mide
## con la primera copia ([code]input.tick - next_tick[/code]: 0 es justo a tiempo, negativo es
## tarde); también la de las entradas demasiado tempranas, que se descartan pero cuentan para la
## medida (saturada a 127). Limita los botones a [constant NetProtocol.VALID_BUTTONS] (sobre el propio
## [param input]).
func push(input: PlayerInput, view_offset_q: int, next_tick: int) -> PushResult:
	var t: int = input.tick
	if t > next_tick + NetProtocol.MAX_INPUT_LEAD_TICKS or t > _last_consumed + CAPACITY:
		too_early_count += 1
		# La antelación también se anota (saturada a 127): si el servidor ha perdido ticks y el
		# cliente va muy por delante, es la única forma de que TickSync se entere y se retrase.
		_note_lead(t - next_tick)
		return PushResult.TOO_EARLY
	var slot: Slot = _slot(t)
	if t <= _last_consumed:
		if slot.tick == t and slot.state == SlotState.SUBSTITUTED:
			slot.state = SlotState.LATE_SEEN
			late_count += 1
			_note_lead(t - next_tick)
			return PushResult.LATE
		return PushResult.DUPLICATE
	if slot.tick == t and slot.state == SlotState.RECEIVED:
		return PushResult.DUPLICATE
	input.buttons &= NetProtocol.VALID_BUTTONS
	slot.set_input(t, SlotState.RECEIVED, input, view_offset_q, t - next_tick)
	_note_lead(t - next_tick)
	return PushResult.ACCEPTED


## La entrada que el servidor aplica en el tick [param tick]: la real si llegó y, si no, la
## sustituta (la última aplicada con este tick, con el bit [constant PlayerInput.SUBSTITUTED] y con
## el movimiento a 0 tras [constant NetProtocol.REPEAT_MOVE_TICKS] ticks sin entradas reales).
## Nunca devuelve null. Hay que llamarla con ticks seguidos.
func take(tick: int) -> PlayerInput:
	var slot: Slot = _slot(tick)
	var input: PlayerInput
	if slot.tick == tick and slot.state == SlotState.RECEIVED:
		input = slot.input
		slot.state = SlotState.CONSUMED_REAL
		_last_real_tick = tick
		_last_real_view_offset_q = slot.view_offset_q
		_last_real_lead = slot.lead
	else:
		input = _last_applied.duplicate_input()
		input.tick = tick
		input.buttons |= PlayerInput.SUBSTITUTED
		if tick - _last_real_tick > NetProtocol.REPEAT_MOVE_TICKS:
			input.move = Vector2.ZERO
		slot.set_input(tick, SlotState.SUBSTITUTED, input, -1)
		substitutions_total += 1
	_last_applied = input
	_last_consumed = tick
	return input


## Valor de [code]input_ack_tick[/code] del snapshot: el mayor tick contiguo recibido a partir
## del último consumido o, si no hay ninguno, el último consumido. Nunca se atasca tras una
## entrada sustituida.
func get_ack_tick() -> int:
	var t: int = _last_consumed
	while t < _last_consumed + NetProtocol.MAX_INPUT_LEAD_TICKS:
		var slot: Slot = _slot(t + 1)
		if slot.tick != t + 1 or slot.state != SlotState.RECEIVED:
			break
		t += 1
	return t


## Antelación mínima de las primeras copias (y de las tardías) desde la llamada anterior, y la
## reinicia. [constant NetProtocol.NO_MARGIN] si no hay datos. Se satura a [-127, 127] para que
## -128 solo signifique «sin datos»; quien la escribe en el snapshot la satura de todos modos.
func pop_min_lead() -> int:
	if not _has_lead:
		return NetProtocol.NO_MARGIN
	var lead: int = _min_lead
	_has_lead = false
	return lead


## [code]view_offset_q[/code] de la entrada real del tick [param tick], o -1 si se sustituyó (o
## ya no está en el anillo). Lo usa el rebobinado de la fase 3.
func get_view_offset_q(tick: int) -> int:
	var slot: Slot = _slot(tick)
	if slot.tick != tick:
		return -1
	if slot.state == SlotState.RECEIVED or slot.state == SlotState.CONSUMED_REAL:
		return slot.view_offset_q
	return -1


## Parámetros del rebobinado de un golpe cuya entrada es del tick [param tick] (docs/combate.md,
## sección 4.3): un [Vector2i] con [code]x = view_offset_q[/code] y [code]y = lead[/code] (la
## antelación con la que llegó esa entrada). Si la entrada del tick era real son los suyos; si se
## sustituyó (o ya no está en el anillo), los de la última entrada real consumida; y
## [code](0, 0)[/code] si el jugador aún no ha enviado ninguna.
func get_rewind_params(tick: int) -> Vector2i:
	var slot: Slot = _slot(tick)
	if slot.tick == tick and (slot.state == SlotState.RECEIVED \
			or slot.state == SlotState.CONSUMED_REAL):
		return Vector2i(slot.view_offset_q, slot.lead)
	return Vector2i(_last_real_view_offset_q, _last_real_lead)


## Antelación [i]habitual[/i] del cliente: la mediana de las antelaciones de primera copia de las entradas
## reales (recibidas o ya consumidas) de los [constant LEAD_WINDOW_TICKS] ticks hasta [param tick], este
## incluido; la de la última entrada real si no hay ninguna. Las sustituidas no cuentan (no tienen
## antelación). El rebobinado (docs/combate.md, 4.3) la usa para acotar la antelación de la entrada de un
## golpe, que escoge el cliente: mandar solo las entradas de su golpe adelantadas no mueve la mediana.
func get_typical_lead(tick: int) -> int:
	var leads := PackedInt32Array()
	for age: int in LEAD_WINDOW_TICKS:
		var t: int = tick - age
		var slot: Slot = _slot(t)
		if slot.tick == t and (slot.state == SlotState.RECEIVED \
				or slot.state == SlotState.CONSUMED_REAL):
			leads.append(slot.lead)
	if leads.is_empty():
		return _last_real_lead
	leads.sort()
	@warning_ignore("integer_division")
	return leads[leads.size() / 2]


## Tick de la última entrada [b]real[/b] consumida (no sustituida ni repetida por el servidor); el del
## alta si todavía no ha llegado ninguna. La fortaleza lo usa para no contar en el círculo a quien lleva
## 60 s sin enviar entradas.
func get_last_real_tick() -> int:
	return _last_real_tick


## Último tick consumido con [method take] (o el del alta).
func get_last_consumed() -> int:
	return _last_consumed


func _slot(tick: int) -> Slot:
	return _slots[tick & (CAPACITY - 1)]


func _note_lead(lead: int) -> void:
	var saturated: int = clampi(lead, -127, 127)
	if not _has_lead or saturated < _min_lead:
		_min_lead = saturated
	_has_lead = true
