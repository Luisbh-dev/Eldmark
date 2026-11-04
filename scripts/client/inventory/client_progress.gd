class_name ClientProgress
extends RefCounted
## Coins, level and XP of the local player on the client (docs/progression.md §5, §6 and §12): the latest that
## WALLET_UPDATE and PROGRESS_UPDATE said, for the inventory window (gold and merits) and the character window (level,
## XP bar, realm and attribute points). It predicts nothing: it only stores what the server sends.
## [br][br]
## Until the first PROGRESS_UPDATE the level is that of the own SPAWN ([method set_spawn_level]) or 1. The level is
## also the [member InventoryOps.Context.level] of inventory requests. Client only.

## Something changed (a balance, the level or the XP).
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


## Balance of currency [param code] ([enum Currency.Code]); 0 if it has not arrived yet.
func get_balance(code: int) -> int:
	return _balances.get(code, 0)


## Character level (1 to [constant ProgressMessages.MAX_LEVEL]).
func get_level() -> int:
	return _level


## XP since the start of the level.
func get_xp_in_level() -> int:
	return _xp_in_level


## XP required by the next level (0 at the cap).
func get_xp_to_next() -> int:
	return _xp_to_next


## Fraction of the XP bar (0 to 1; full at the cap).
func get_xp_fraction() -> float:
	if _xp_to_next <= 0:
		return 1.0
	return clampf(float(_xp_in_level) / float(_xp_to_next), 0.0, 1.0)


func get_realm_points() -> int:
	return _realm_points


## Unspent attribute points.
func get_attribute_points() -> int:
	return _attribute_points


## What was gained in the last PROGRESS_UPDATE and its source ([enum ProgressMessages.XpSource]).
func get_last_gain() -> Vector2i:
	return Vector2i(_last_gained, _last_source)


## true since the first PROGRESS_UPDATE.
func has_progress() -> bool:
	return _has_progress


## true since the first WALLET_UPDATE.
func has_wallet() -> bool:
	return _has_wallet


## The level from the own SPAWN (0 = no progress): valid until the first PROGRESS_UPDATE.
func set_spawn_level(level: int) -> void:
	if _has_progress or level < 1 or level > ProgressMessages.MAX_LEVEL or level == _level:
		return
	_level = level
	changed.emit()


## A WALLET_UPDATE: the balance of its currency.
func on_wallet(update: ProgressMessages.WalletUpdate) -> void:
	if update == null:
		return
	_balances[update.currency] = update.balance
	_has_wallet = true
	changed.emit()


## A PROGRESS_UPDATE: level, XP within the level, realm and attribute points.
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


## An own LEVEL_UP: the level goes up right away (the accompanying PROGRESS_UPDATE brings the rest).
func on_level_up(level: int) -> void:
	if level <= _level or level > ProgressMessages.MAX_LEVEL:
		return
	_level = level
	changed.emit()


## Forgets everything (end of the session).
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
