class_name CombatDemoScript
extends RefCounted
## Guion de combate de la demo del sandbox (CMB-06) y de la vista previa del animador de combate:
## el combo de tres golpes ligeros, un golpe fuerte cargado, un bloqueo y una esquiva, pulsados en el
## tick justo para que cada golpe enlace con el siguiente.
## [br][br]
## Todo sale de los datos de combate ([CombatCatalog]): las duraciones, la ventana de enlace del combo
## y la carga mínima del fuerte, así que el guion sigue valiendo si se ajustan los [code].tres[/code].
## Los ticks son relativos al principio del guion (el 0 es el primero). [method buttons_at] devuelve los
## botones de [PlayerInput] de cada tick.
## [br][br]
## Guion (la espera entre golpes es la mínima, salvo donde se dice):
## [br]1. Ligero 1, ligero 2 y ligero 3: se pulsa PRIMARY en medio de la ventana de enlace de cada uno.
## [br]2. Fuerte: PRIMARY mantenido ([constant HEAVY_EXTRA_HOLD_TICKS] ticks más allá de la carga mínima) y soltado.
## [br]3. Bloqueo: BLOCK mantenido [constant BLOCK_HOLD_TICKS] ticks.
## [br]4. Esquiva: DODGE sin dirección (hacia atrás).

## Ticks que se mantiene PRIMARY tras la carga mínima del fuerte.
const HEAVY_EXTRA_HOLD_TICKS: int = 28
## Ticks de bloqueo.
const BLOCK_HOLD_TICKS: int = 40
## Ticks que dura cada pulsación de PRIMARY del combo (menos que la carga: no la convierte).
const TAP_TICKS: int = 3
## Ticks de espera entre un tramo y el siguiente.
const GAP_TICKS: int = 8

# Tramos [desde, hasta) -> botones.
var _spans: Array[Vector3i] = []
var _length: int = 0
var _heavy_release_tick: int = 0
var _dodge_tick: int = 0


func _init() -> void:
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.default_weapon_id())
	var cursor: int = 0
	# Combo: el primer ligero se pulsa al empezar; cada uno de los demás empieza solo, al acabar la
	# recuperación del anterior, porque se pulsa PRIMARY dentro de su ventana de enlace (el último
	# tercio de la ventana).
	_spans.append(Vector3i(cursor, cursor + TAP_TICKS, PlayerInput.PRIMARY))
	for index: int in weapon.light_ids.size():
		var attack: AttackTicks = CombatCatalog.attack(weapon.light_ids[index])
		if index < weapon.light_ids.size() - 1:
			var press: int = cursor + attack.combo_window_from() + ceili(float(attack.combo_window_ticks) / 3.0)
			_spans.append(Vector3i(press, press + TAP_TICKS, PlayerInput.PRIMARY))
		cursor += attack.total_ticks
	cursor += GAP_TICKS
	# Fuerte cargado.
	var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
	var hold: int = heavy.charge_min_ticks + HEAVY_EXTRA_HOLD_TICKS
	_spans.append(Vector3i(cursor, cursor + hold, PlayerInput.PRIMARY))
	_heavy_release_tick = cursor + hold
	cursor += hold + heavy.total_ticks + GAP_TICKS
	# Bloqueo.
	_spans.append(Vector3i(cursor, cursor + BLOCK_HOLD_TICKS, PlayerInput.BLOCK))
	cursor += BLOCK_HOLD_TICKS + GAP_TICKS
	# Esquiva.
	_dodge_tick = cursor
	_spans.append(Vector3i(cursor, cursor + 1, PlayerInput.DODGE))
	cursor += weapon.dodge.duration_ticks + GAP_TICKS
	_length = cursor


## Botones de [PlayerInput] que se pulsan en el tick [param tick] del guion (0 fuera de él).
func buttons_at(tick: int) -> int:
	var buttons: int = 0
	for span: Vector3i in _spans:
		if tick >= span.x and tick < span.y:
			buttons |= span.z
	return buttons


## Ticks del guion entero.
func get_length() -> int:
	return _length


## Tick en el que se suelta el golpe fuerte (el primero tras la carga).
func get_heavy_release_tick() -> int:
	return _heavy_release_tick


## Tick en el que se pulsa la esquiva.
func get_dodge_tick() -> int:
	return _dodge_tick


## true cuando ya se ha ejecutado el último tick del guion.
func is_finished(tick: int) -> bool:
	return tick >= _length
