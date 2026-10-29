class_name UnstuckTracker
extends RefCounted
## El comando /atascado (docs/fuerte.md, sección 5; MUN-41): lo que el servidor recuerda de cada
## jugador para decidir si puede usarlo. Una canalización de [constant CHANNEL_TICKS] (10 s) que se
## interrumpe si el jugador entra en combate (el daño la interrumpe) o muere, solo se puede empezar
## fuera de combate, y tras completarla hay [constant COOLDOWN_TICKS] (5 min) de reutilización. Una
## canalización interrumpida no gasta la reutilización.
## [br][br]
## Puro y sin red: [ZoneServer] llama a [method request] al recibir UNSTUCK_REQUEST, a [method update]
## cada tick por cada canalización viva y hace él el teletransporte cuando [method update] dice que se
## ha completado.

## Resultado de [method request].
enum RequestResult { STARTED, IN_COMBAT, COOLDOWN, ALREADY_CHANNELING, DEAD }
## Resultado de [method update].
enum UpdateResult { CHANNELING, INTERRUPTED, COMPLETED }

## Ticks de canalización (10 s).
const CHANNEL_TICKS: int = 600
## Ticks de reutilización tras completar (5 min).
const COOLDOWN_TICKS: int = 18000

# Clave del nombre del jugador -> tick en que acaba la canalización.
var _channel_end: Dictionary[String, int] = {}
# jugador (clave de su nombre) -> primer tick en que puede volver a usarlo.
var _ready_at: Dictionary[String, int] = {}
## Ticks de canalización y de reutilización de esta instancia ([constant CHANNEL_TICKS] y
## [constant COOLDOWN_TICKS] por defecto; las pruebas los acortan).
var channel_ticks: int = CHANNEL_TICKS
var cooldown_ticks: int = COOLDOWN_TICKS
## Canalizaciones completadas desde que existe el rastreador.
var completed_count: int = 0
## Canalizaciones interrumpidas.
var interrupted_count: int = 0


## [param player] (la clave de su nombre, para que volver a entrar no salte la reutilización) pide
## /atascado en el tick [param tick], estando [param alive] y [param in_combat]. Si procede, empieza la
## canalización ([constant RequestResult.STARTED]).
func request(player: String, tick: int, alive: bool, in_combat: bool) -> int:
	if not alive:
		return RequestResult.DEAD
	if _channel_end.has(player):
		return RequestResult.ALREADY_CHANNELING
	if in_combat:
		return RequestResult.IN_COMBAT
	if tick < _ready_at.get(player, 0):
		return RequestResult.COOLDOWN
	_channel_end[player] = tick + channel_ticks
	return RequestResult.STARTED


## Avanza la canalización de [param player] en el tick [param tick]: se interrumpe si ya no está vivo
## o ha entrado en combate, y se completa al llegar su tick final (entonces empieza la
## reutilización). Devuelve [constant UpdateResult.CHANNELING] si no hay canalización.
func update(player: String, tick: int, alive: bool, in_combat: bool) -> int:
	if not _channel_end.has(player):
		return UpdateResult.CHANNELING
	if not alive or in_combat:
		_channel_end.erase(player)
		interrupted_count += 1
		return UpdateResult.INTERRUPTED
	if tick >= _channel_end[player]:
		_channel_end.erase(player)
		_purge_expired(tick)
		_ready_at[player] = tick + cooldown_ticks
		completed_count += 1
		return UpdateResult.COMPLETED
	return UpdateResult.CHANNELING


## true si [param player] está canalizando.
func is_channeling(player: String) -> bool:
	return _channel_end.has(player)


## Claves de los jugadores que están canalizando, ordenadas.
func get_channeling() -> PackedStringArray:
	var keys := PackedStringArray(_channel_end.keys())
	keys.sort()
	return keys


## Ticks que faltan para que [param player] pueda volver a usarlo en [param tick] (0 si ya puede).
func cooldown_remaining(player: String, tick: int) -> int:
	return maxi(_ready_at.get(player, 0) - tick, 0)


## Ticks que le quedan a la canalización de [param player] en [param tick] (0 si no canaliza).
func channel_remaining(player: String, tick: int) -> int:
	return maxi(_channel_end.get(player, tick) - tick, 0)


## Cancela la canalización de [param player] sin contarla como interrumpida (se va del mundo). La
## reutilización se conserva: volver a entrar no la salta.
func cancel(player: String) -> void:
	_channel_end.erase(player)


# Olvida las reutilizaciones vencidas, para que el diccionario no crezca con cada nombre que lo usó.
func _purge_expired(tick: int) -> void:
	for key: String in _ready_at.keys():
		if _ready_at[key] <= tick:
			_ready_at.erase(key)
