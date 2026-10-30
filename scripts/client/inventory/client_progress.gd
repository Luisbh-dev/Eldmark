class_name ClientProgress
extends RefCounted
## Monedas, nivel y XP del jugador local en el cliente (docs/progresion.md §5, §6 y §12): lo último que dijeron
## WALLET_UPDATE y PROGRESS_UPDATE, para la ventana de inventario (oro y méritos) y la de personaje (nivel,
## barra de XP, puntos de reino y de atributo). No predice nada: solo guarda lo que manda el servidor.
## [br][br]
## Hasta el primer PROGRESS_UPDATE el nivel es el del SPAWN propio ([method set_spawn_level]) o 1. El nivel es
## también el de [member InventoryOps.Context.level] de las peticiones del inventario. Solo cliente.

## Cambió algo (un saldo, el nivel o la XP).
signal changed

var _balances: Dictionary[int, int] = {}
var _level: int = 1
var _xp_in_level: int = 0
var _xp_to_next: int = 0
var _realm_points: int = 0
var _attribute_points: int = 0
var _last_gained: int = 0
var _last_source: int = ProgressMessages.XpSource.STATE
var _has_progress: bool = false
var _has_wallet: bool = false


## Saldo de la moneda [param code] ([enum Currency.Code]); 0 si aún no llegó.
func get_balance(code: int) -> int:
	return _balances.get(code, 0)


## Nivel del personaje (1 a [constant ProgressMessages.MAX_LEVEL]).
func get_level() -> int:
	return _level


## XP desde el principio del nivel.
func get_xp_in_level() -> int:
	return _xp_in_level


## XP que pide el siguiente nivel (0 en el tope).
func get_xp_to_next() -> int:
	return _xp_to_next


## Fracción de la barra de XP (0 a 1; llena en el tope).
func get_xp_fraction() -> float:
	if _xp_to_next <= 0:
		return 1.0
	return clampf(float(_xp_in_level) / float(_xp_to_next), 0.0, 1.0)


func get_realm_points() -> int:
	return _realm_points


## Puntos de atributo sin gastar.
func get_attribute_points() -> int:
	return _attribute_points


## Lo ganado en el último PROGRESS_UPDATE y su fuente ([enum ProgressMessages.XpSource]).
func get_last_gain() -> Vector2i:
	return Vector2i(_last_gained, _last_source)


## true desde el primer PROGRESS_UPDATE.
func has_progress() -> bool:
	return _has_progress


## true desde el primer WALLET_UPDATE.
func has_wallet() -> bool:
	return _has_wallet


## El nivel del SPAWN propio (0 = sin progreso): vale hasta el primer PROGRESS_UPDATE.
func set_spawn_level(level: int) -> void:
	if _has_progress or level < 1 or level > ProgressMessages.MAX_LEVEL or level == _level:
		return
	_level = level
	changed.emit()


## Un WALLET_UPDATE: el saldo de su moneda.
func on_wallet(update: ProgressMessages.WalletUpdate) -> void:
	if update == null:
		return
	_balances[update.currency] = update.balance
	_has_wallet = true
	changed.emit()


## Un PROGRESS_UPDATE: nivel, XP del nivel, puntos de reino y de atributo.
func on_progress(update: ProgressMessages.ProgressUpdate) -> void:
	if update == null:
		return
	_level = update.level
	_xp_in_level = update.xp_in_level
	_xp_to_next = update.xp_to_next
	_realm_points = update.realm_points
	_attribute_points = update.attribute_points
	_last_gained = update.gained
	_last_source = update.source
	_has_progress = true
	changed.emit()


## Un LEVEL_UP propio: sube el nivel ya (el PROGRESS_UPDATE que lo acompaña trae el resto).
func on_level_up(level: int) -> void:
	if level <= _level or level > ProgressMessages.MAX_LEVEL:
		return
	_level = level
	changed.emit()


## Olvida todo (fin de la sesión).
func clear() -> void:
	_balances.clear()
	_level = 1
	_xp_in_level = 0
	_xp_to_next = 0
	_realm_points = 0
	_attribute_points = 0
	_last_gained = 0
	_last_source = ProgressMessages.XpSource.STATE
	_has_progress = false
	_has_wallet = false
	changed.emit()
