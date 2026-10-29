class_name ClientPrediction
extends RefCounted
## Predicción del jugador local y reconciliación con el servidor (docs/red.md, sección 6).
##
## El cliente simula su propio personaje por delante del servidor con las mismas entradas
## cuantizadas que viajan por la red; guarda, por tick, la entrada y el estado resultante en dos
## anillos de [constant HISTORY_SIZE] huecos indexados por [code]tick % HISTORY_SIZE[/code] con el
## tick como etiqueta. Cuando llega el estado propio del servidor para un tick, se compara con el
## predicho para ese tick con [method PlayerState.equals_exact]:
## [br]- Si coincide, no hace falta nada.
## [br]- Si no, se restaura el estado del servidor y se vuelven a simular las entradas guardadas
## hasta el último tick predicho, con [member PlayerCharacter.events_enabled] en false. El cuerpo se
## corrige de golpe y la diferencia visible la reparte [CorrectionSmoother]; si el error pasa de
## [constant SNAP_DISTANCE] o hay un teletransporte, se salta directamente.
## [br][br]
## Todo lo que simula debe llamarse dentro del tick de física y con
## [code]delta = 1 / Engine.physics_ticks_per_second[/code] ([method PlayerCharacter.simulate]).

## Qué hizo [method on_server_state] con el estado recibido.
enum Result {
	## Estado repetido o más antiguo que el último reconciliado: no se hizo nada.
	IGNORED,
	## Coincidía exactamente con el predicho.
	MATCH,
	## Difería: se repitieron las entradas desde ese tick y el error fue al suavizador.
	CORRECTED,
	## Se restauró el estado sin comparar (llegó por delante de lo predicho o ya no está en el
	## anillo).
	HARD_RESET,
}

## Huecos de cada anillo (algo más de 4 s a 60 ticks por segundo).
const HISTORY_SIZE: int = 256
## Error (m) a partir del cual se salta directamente en lugar de suavizar.
const SNAP_DISTANCE: float = 3.0
## Las correcciones menores que esto (m) no se cuentan en las estadísticas.
const CORRECTION_REPORT_DISTANCE: float = 0.001

var _character: PlayerCharacter = null
var _controller: LocalPlayerController = null
var _smoother: CorrectionSmoother = null
var _dt: float = 1.0 / 60.0

var _started: bool = false
var _predicted_tick: int = 0
var _first_real_tick: int = 0
var _last_reconciled: int = 0
var _replaying: bool = false

# Anillos: la etiqueta de cada hueco es el tick que guarda (-1 = vacío).
var _input_ticks: PackedInt64Array = PackedInt64Array()
var _inputs: Array[PlayerInput] = []
var _state_ticks: PackedInt64Array = PackedInt64Array()
var _states: Array[PlayerState] = []

# Regla de sustitución del servidor durante una repetición (ver _input_or_substitute).
var _sub_last_applied: PlayerInput = null
var _sub_last_real_tick: int = 0

# Estadísticas (ver get_stats).
var _matches: int = 0
var _ignored: int = 0
var _replays: int = 0
var _corrections: int = 0
var _resimulated_ticks: int = 0
var _last_correction: float = 0.0
var _max_correction: float = 0.0
var _hard_resets: int = 0


func _init() -> void:
	_clear_rings()


## Conecta la predicción con el personaje local, su controlador (que genera las entradas con
## [method LocalPlayerController.build_input], con [code]auto_step = false[/code]) y el
## suavizador de correcciones. [param delta] es el paso fijo de física.
func setup(character: PlayerCharacter, controller: LocalPlayerController,
		smoother: CorrectionSmoother, delta: float) -> void:
	_character = character
	_controller = controller
	_smoother = smoother
	_dt = delta


## Arranca la predicción con el estado de aparición del servidor ([param spawn_state], el estado
## tras simular [param spawn_tick]). Hasta [param first_real_tick] (exclusive) avanza con entradas
## neutras, que es lo que el servidor sustituye mientras no le llega ninguna real, así que los dos
## estados coinciden bit a bit desde el primer tick.
func start(spawn_tick: int, spawn_state: PlayerState, first_real_tick: int) -> void:
	_clear_rings()
	_reset_stats()
	_replaying = false
	_character.set_state(spawn_state)
	_character.reset_physics_interpolation()
	if _smoother != null:
		_smoother.clear()
	_store(spawn_tick, null, spawn_state.duplicate_state())
	_predicted_tick = spawn_tick
	_first_real_tick = first_real_tick
	_last_reconciled = spawn_tick - 1

	# El servidor sustituye estos ticks (nunca le llega una entrada real): llevan la marca de
	# entrada sustituida, como las suyas.
	var neutral: PlayerInput = NetProtocol.neutral_input(0, spawn_state.yaw)
	neutral.buttons |= PlayerInput.SUBSTITUTED
	var events_were_enabled: bool = _character.events_enabled
	_character.events_enabled = false
	for tick: int in range(spawn_tick + 1, first_real_tick):
		var input: PlayerInput = neutral.duplicate_input()
		input.tick = tick
		_character.simulate(input, _dt)
		_store(tick, input, _character.get_state())
		_predicted_tick = tick
	_character.events_enabled = events_were_enabled
	_started = true


## true una vez llamado [method start].
func is_started() -> bool:
	return _started


## Un paso de predicción: construye la entrada del siguiente tick con el controlador (ya
## cuantizada y con las pulsaciones acumuladas), simula el personaje, guarda entrada y estado y
## devuelve la entrada. Devuelve null si la predicción no ha arrancado.
func step() -> PlayerInput:
	if not _started:
		return null
	var tick: int = _predicted_tick + 1
	var input: PlayerInput = _controller.build_input(tick)
	_character.simulate(input, _dt)
	_store(tick, input, _character.get_state())
	_predicted_tick = tick
	return input


## Compara el estado propio que manda el servidor para [param server_tick] con el predicho y, si
## difieren, lo restaura y repite las entradas hasta el último tick predicho. [param teleported]
## indica que el contador de teletransporte cambió: entonces nunca se suaviza. Devuelve un
## [enum Result].
func on_server_state(server_tick: int, state: PlayerState, teleported: bool) -> int:
	if not _started or state == null or server_tick <= _last_reconciled:
		_ignored += 1
		return Result.IGNORED
	_last_reconciled = server_tick
	if server_tick > _predicted_tick or not _has_state(server_tick):
		hard_reset(server_tick, state)
		return Result.HARD_RESET
	if not teleported and _states[_slot(server_tick)].equals_exact(state):
		_matches += 1
		return Result.MATCH

	var before: Vector3 = _character.global_position
	_character.set_state(state)
	_states[_slot(server_tick)] = state.duplicate_state()
	_replay_from(server_tick)
	var error: Vector3 = before - _character.global_position
	if teleported or error.length() > SNAP_DISTANCE:
		if _smoother != null:
			_smoother.clear()
		_character.reset_physics_interpolation()
	elif not error.is_zero_approx() and _smoother != null:
		_smoother.add_offset(error)
	_replays += 1
	_record_correction(error.length())
	return Result.CORRECTED


## Restaura [param state] como el estado del tick [param tick] sin comparar y sin suavizar. Si
## [param tick] no es anterior al último predicho, pasa a ser el último predicho (así
## [TickSync] recupera la antelación); si lo es, se repiten las entradas hasta el último predicho.
## Siempre termina con el suavizador a cero y la interpolación de física reiniciada.
func hard_reset(tick: int, state: PlayerState) -> void:
	if not _started:
		return
	_last_reconciled = maxi(_last_reconciled, tick)
	_character.set_state(state)
	_store_state(tick, state.duplicate_state())
	if tick >= _predicted_tick:
		_predicted_tick = tick
	else:
		_replay_from(tick)
	if _smoother != null:
		_smoother.clear()
	_character.reset_physics_interpolation()
	_hard_resets += 1


## Último tick predicho (el del último [method step]).
func get_predicted_tick() -> int:
	return _predicted_tick


## Primer tick con entrada real (P0); los anteriores se predijeron con entrada neutra.
func get_first_real_tick() -> int:
	return _first_real_tick


## Entrada del tick [param tick], o null si ya no está en el anillo (o nunca hubo: el tick de
## aparición). Es el objeto guardado: no se debe modificar.
func get_input(tick: int) -> PlayerInput:
	var slot: int = _slot(tick)
	if _input_ticks[slot] != tick:
		return null
	return _inputs[slot]


## Estado predicho para [param tick], o null si ya no está en el anillo. Es el objeto guardado: no
## se debe modificar.
func get_predicted_state(tick: int) -> PlayerState:
	var slot: int = _slot(tick)
	if _state_ticks[slot] != tick:
		return null
	return _states[slot]


## true mientras se repiten entradas (reconciliación o [method hard_reset]).
func is_replaying() -> bool:
	return _replaying


## Estadísticas desde [method start]:
## [br]- [code]matches[/code]: estados del servidor que coincidían exactamente.
## [br]- [code]ignored[/code]: estados repetidos o antiguos que se ignoraron.
## [br]- [code]replays[/code]: veces que hubo que repetir entradas por una diferencia.
## [br]- [code]corrections[/code]: de ellas, las de más de [constant CORRECTION_REPORT_DISTANCE].
## [br]- [code]resimulated_ticks[/code]: ticks vueltos a simular (repeticiones y hard resets).
## [br]- [code]last_correction[/code] y [code]max_correction[/code] (m): última y mayor corrección de
## más de [constant CORRECTION_REPORT_DISTANCE].
## [br]- [code]hard_resets[/code]: veces que se restauró el estado sin comparar.
func get_stats() -> Dictionary:
	return {
		"matches": _matches,
		"ignored": _ignored,
		"replays": _replays,
		"corrections": _corrections,
		"resimulated_ticks": _resimulated_ticks,
		"last_correction": _last_correction,
		"max_correction": _max_correction,
		"hard_resets": _hard_resets,
	}


# Vuelve a simular los ticks (from_tick, último predicho] a partir del estado que ya tiene el
# personaje (el del tick from_tick). Sin eventos de salto ni aterrizaje, y guardando los estados
# nuevos en el anillo. Las entradas son las guardadas y, donde no hay, las sustitutas.
func _replay_from(from_tick: int) -> void:
	_replaying = true
	var events_were_enabled: bool = _character.events_enabled
	_character.events_enabled = false
	_begin_substitution(from_tick)
	for tick: int in range(from_tick + 1, _predicted_tick + 1):
		_character.simulate(_input_or_substitute(tick), _dt)
		_store_state(tick, _character.get_state())
	_character.events_enabled = events_were_enabled
	_replaying = false
	_resimulated_ticks += maxi(_predicted_tick - from_tick, 0)


# Prepara la regla de sustitución para una repetición que parte del estado de from_tick: la última
# entrada aplicada es la guardada para ese tick o, si ya no está, una neutra con los botones del
# estado (prev_buttons) y sin movimiento.
func _begin_substitution(from_tick: int) -> void:
	var known: PlayerInput = get_input(from_tick)
	if known != null:
		_sub_last_applied = known
		_sub_last_real_tick = from_tick
		return
	var base: PlayerInput = NetProtocol.neutral_input(from_tick, _character.yaw)
	base.buttons = _character.prev_buttons
	_sub_last_applied = base
	_sub_last_real_tick = from_tick - NetProtocol.REPEAT_MOVE_TICKS - 1


# La entrada guardada para el tick si su etiqueta coincide y, si no, la sustituta que aplicaría el
# servidor (docs/red.md, 8.2): repite la última aplicada con todos sus botones y la marca
# PlayerInput.SUBSTITUTED, y pone el movimiento a 0 si han pasado más de REPEAT_MOVE_TICKS ticks
# desde la última real. Solo hace falta tras un hard_reset (huecos en el anillo); en una
# reconciliación normal están todas.
func _input_or_substitute(tick: int) -> PlayerInput:
	var stored: PlayerInput = get_input(tick)
	if stored != null:
		_sub_last_applied = stored
		_sub_last_real_tick = tick
		return stored
	var input: PlayerInput = _sub_last_applied.duplicate_input()
	input.tick = tick
	input.buttons |= PlayerInput.SUBSTITUTED
	if tick - _sub_last_real_tick > NetProtocol.REPEAT_MOVE_TICKS:
		input.move = Vector2.ZERO
	_sub_last_applied = input
	return input


func _record_correction(distance: float) -> void:
	if distance <= CORRECTION_REPORT_DISTANCE:
		return
	_corrections += 1
	_last_correction = distance
	_max_correction = maxf(_max_correction, distance)


func _has_state(tick: int) -> bool:
	return _state_ticks[_slot(tick)] == tick


# Guarda la entrada (si no es null) y el estado de un tick. Un tick sin entrada (el de aparición)
# no pisa el hueco de la entrada: su etiqueta, de otro tick, hace que get_input() devuelva null.
func _store(tick: int, input: PlayerInput, state: PlayerState) -> void:
	var slot: int = _slot(tick)
	if input != null:
		_input_ticks[slot] = tick
		_inputs[slot] = input
	_state_ticks[slot] = tick
	_states[slot] = state


func _store_state(tick: int, state: PlayerState) -> void:
	_store(tick, null, state)


func _slot(tick: int) -> int:
	return posmod(tick, HISTORY_SIZE)


func _clear_rings() -> void:
	_input_ticks.resize(HISTORY_SIZE)
	_input_ticks.fill(-1)
	_state_ticks.resize(HISTORY_SIZE)
	_state_ticks.fill(-1)
	_inputs.clear()
	_inputs.resize(HISTORY_SIZE)
	_states.clear()
	_states.resize(HISTORY_SIZE)


func _reset_stats() -> void:
	_matches = 0
	_ignored = 0
	_replays = 0
	_corrections = 0
	_resimulated_ticks = 0
	_last_correction = 0.0
	_max_correction = 0.0
	_hard_resets = 0
