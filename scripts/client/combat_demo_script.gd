class_name CombatDemoScript
extends RefCounted
## Combat script for the sandbox demo (CMB-06) and the combat animator preview:
## the three-hit light combo, a charged heavy attack, a block and a dodge, pressed on the
## exact tick so that each hit chains into the next.
## [br][br]
## Everything comes from the combat data ([CombatCatalog]): the durations, the combo chain window
## and the heavy attack's minimum charge, so the script remains valid if the [code].tres[/code] files are tuned.
## Ticks are relative to the start of the script (0 is the first). [method buttons_at] returns the
## [PlayerInput] buttons of each tick.
## [br][br]
## Script (the wait between hits is the minimum, except where stated):
## [br]1. Light 1, light 2 and light 3: PRIMARY is pressed in the middle of each one's chain window.
## [br]2. Heavy: PRIMARY held ([constant HEAVY_EXTRA_HOLD_TICKS] ticks beyond the minimum charge) and released.
## [br]3. Block: BLOCK held [constant BLOCK_HOLD_TICKS] ticks.
## [br]4. Dodge: DODGE with no direction (backwards).

## Ticks PRIMARY is held after the heavy attack's minimum charge.
const HEAVY_EXTRA_HOLD_TICKS: int = 12
## Block ticks.
const BLOCK_HOLD_TICKS: int = 30
## Ticks each PRIMARY press of the combo lasts (less than the charge: it does not turn it into one).
const TAP_TICKS: int = 3
## Ticks to wait between one segment and the next.
const GAP_TICKS: int = 5

# Segments [from, to) -> buttons.
var _spans: Array[Vector3i] = []
var _length: int = 0
var _heavy_release_tick: int = 0
var _dodge_tick: int = 0


func _init() -> void:
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.default_weapon_id())
	var cursor: int = 0
	# Combo: the first light attack is pressed at the start; each of the others starts by itself, when the
	# previous one's recovery ends, because PRIMARY is pressed within its chain window (the last
	# third of the window).
	_spans.append(Vector3i(cursor, cursor + TAP_TICKS, PlayerInput.PRIMARY))
	for index: int in weapon.light_ids.size():
		var attack: AttackTicks = CombatCatalog.attack(weapon.light_ids[index])
		if index < weapon.light_ids.size() - 1:
			var press: int = cursor + attack.combo_window_from() + ceili(float(attack.combo_window_ticks) / 3.0)
			_spans.append(Vector3i(press, press + TAP_TICKS, PlayerInput.PRIMARY))
		cursor += attack.total_ticks
	cursor += GAP_TICKS
	# Charged heavy attack.
	var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
	var hold: int = heavy.charge_min_ticks + HEAVY_EXTRA_HOLD_TICKS
	_spans.append(Vector3i(cursor, cursor + hold, PlayerInput.PRIMARY))
	_heavy_release_tick = cursor + hold
	cursor += hold + heavy.total_ticks + GAP_TICKS
	# Block.
	_spans.append(Vector3i(cursor, cursor + BLOCK_HOLD_TICKS, PlayerInput.BLOCK))
	cursor += BLOCK_HOLD_TICKS + GAP_TICKS
	# Dodge.
	_dodge_tick = cursor
	_spans.append(Vector3i(cursor, cursor + 1, PlayerInput.DODGE))
	cursor += weapon.dodge.duration_ticks + GAP_TICKS
	_length = cursor


## [PlayerInput] buttons pressed at tick [param tick] of the script (0 outside it).
func buttons_at(tick: int) -> int:
	var buttons: int = 0
	for span: Vector3i in _spans:
		if tick >= span.x and tick < span.y:
			buttons |= span.z
	return buttons


## Ticks of the whole script.
func get_length() -> int:
	return _length


## Tick at which the heavy attack is released (the first after the charge).
func get_heavy_release_tick() -> int:
	return _heavy_release_tick


## Tick at which the dodge is pressed.
func get_dodge_tick() -> int:
	return _dodge_tick


## true once the script's last tick has been executed.
func is_finished(tick: int) -> bool:
	return tick >= _length
