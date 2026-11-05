class_name VitalsHud
extends Control
## Health and stamina bars at the bottom center of the screen (UI-10). They only display: they do not read the
## network or the simulation, the [HUD] feeds them with [method set_health] and [method set_stamina].
## [br][br]
## [b]Health[/b] (decided by the server, comes from the snapshot's extra block): a red bar with the
## value, and behind it a ghost segment of the recent loss (light) that waits
## [constant GHOST_HOLD_SECONDS] s and then shrinks down to the current health. When healing, the ghost
## follows the bar. In the sandbox without a network health does not exist and [method set_health_visible]
## hides it.
## [br][br]
## [b]Stamina[/b] (predicted, from [PlayerState]): a thin green bar (orange if exhausted)
## below the health one. It hides with a fade when full. When an action fails for
## lack of stamina (bit 1 of [member CombatState.combat_flags], which lasts one tick), the bar
## appears even if full and blinks red for [constant BLINK_SECONDS] s
## ([method notify_no_stamina]).
## [br][br]
## Time is driven by [method advance] ([method _process] calls it with each frame's
## delta); tests call it with exact steps.

## Seconds the ghost waits before shrinking, and its speed (fraction of the bar per s).
const GHOST_HOLD_SECONDS: float = 0.5
const GHOST_SHRINK_SPEED: float = 0.6
## Duration of the blink for lack of stamina and its frequency (Hz).
const BLINK_SECONDS: float = 0.6
const BLINK_HERTZ: float = 8.0
## Seconds with full stamina before the bar starts to hide, and fade speed
## (opacity per second).
const STAMINA_HIDE_DELAY: float = 0.8
const STAMINA_FADE_SPEED: float = 3.0
## Bar dimensions (px).
const BAR_WIDTH: float = 480.0
const HEALTH_HEIGHT: float = 20.0
const STAMINA_HEIGHT: float = 6.0
const BAR_GAP: float = 3.0
const FONT_SIZE: int = 13

const HEALTH_COLOR: Color = Color(0.78, 0.13, 0.15, 1.0)
const GHOST_COLOR: Color = Color(1.0, 0.82, 0.55, 0.85)
const BACK_COLOR: Color = Color(0.04, 0.04, 0.05, 0.65)
const BORDER_COLOR: Color = Color(0.0, 0.0, 0.0, 0.8)
const STAMINA_COLOR: Color = Color(0.58, 0.82, 0.3, 1.0)
const EXHAUSTED_COLOR: Color = Color(0.95, 0.5, 0.12, 1.0)
const BLINK_COLOR: Color = Color(1.0, 0.15, 0.1, 1.0)
const TEXT_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const HEALTH_SHINE: Color = Color(1.0, 1.0, 1.0, 0.13)
const TICK_COLOR: Color = Color(0.0, 0.0, 0.0, 0.38)
const FRAME_COLOR: Color = Color(0.5, 0.47, 0.42, 0.9)
## Opacity of the thin stamina bar when full and still (it never hides completely).
const STAMINA_IDLE_ALPHA: float = 0.5

var _health: int = 1000
var _max_health: int = 1000
var _health_visible: bool = true
var _ghost: float = 1.0
var _ghost_hold: float = 0.0
var _stamina: int = 1000
var _max_stamina: int = 1000
var _exhausted: bool = false
var _stamina_alpha: float = 0.0
var _full_time: float = 0.0
var _blink_left: float = 0.0
var _blink_clock: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	advance(delta)


## Current and maximum health (the server's). A loss leaves the ghost segment; a heal
## makes it equal to the bar.
func set_health(current: int, max_value: int) -> void:
	var previous: float = get_health_fraction()
	_max_health = maxi(max_value, 1)
	_health = clampi(current, 0, _max_health)
	var now: float = get_health_fraction()
	if now < previous - 0.0001:
		# A loss: the ghost stays where the bar was (or higher, if it was still
		# shrinking from another loss) and waits before shrinking.
		_ghost = maxf(_ghost, previous)
		_ghost_hold = GHOST_HOLD_SECONDS
	elif now >= _ghost:
		_ghost = now
	queue_redraw()


## Sets health without leaving a ghost (the first value that arrives, after respawning or on entering).
func snap_health(current: int, max_value: int) -> void:
	_max_health = maxi(max_value, 1)
	_health = clampi(current, 0, _max_health)
	_ghost = get_health_fraction()
	_ghost_hold = 0.0
	queue_redraw()


## Current and maximum stamina (the predicted one) and whether the character is exhausted.
func set_stamina(current: int, max_value: int, exhausted: bool = false) -> void:
	_max_stamina = maxi(max_value, 1)
	_stamina = clampi(current, 0, _max_stamina)
	_exhausted = exhausted
	queue_redraw()


## Shows or hides the health bar (without a network there is no health to show).
func set_health_visible(shown: bool) -> void:
	_health_visible = shown
	queue_redraw()


## An action has failed for lack of stamina: the bar appears and blinks red.
func notify_no_stamina() -> void:
	_blink_left = BLINK_SECONDS
	_blink_clock = 0.0
	_stamina_alpha = 1.0
	_full_time = 0.0
	queue_redraw()


## Advances the ghost, the blink and the stamina fade by [param delta] seconds.
func advance(delta: float) -> void:
	var now: float = get_health_fraction()
	if _ghost > now:
		var remaining: float = delta
		if _ghost_hold > 0.0:
			var held: float = minf(_ghost_hold, remaining)
			_ghost_hold -= held
			remaining -= held
		if remaining > 0.0:
			_ghost = maxf(now, _ghost - GHOST_SHRINK_SPEED * remaining)
	else:
		_ghost = now
	if _blink_left > 0.0:
		_blink_left = maxf(_blink_left - delta, 0.0)
		_blink_clock += delta
	var full: bool = _stamina >= _max_stamina and not _exhausted
	if full and _blink_left <= 0.0:
		_full_time += delta
		if _full_time >= STAMINA_HIDE_DELAY:
			_stamina_alpha = maxf(_stamina_alpha - STAMINA_FADE_SPEED * delta, 0.0)
	else:
		_full_time = 0.0
		_stamina_alpha = minf(_stamina_alpha + STAMINA_FADE_SPEED * 2.0 * delta, 1.0)
	queue_redraw()


# --- Reading (for tests and the HUD) ----------------------------------------------------------

func get_health() -> int:
	return _health


func get_max_health() -> int:
	return _max_health


## Health fraction (0 to 1).
func get_health_fraction() -> float:
	return float(_health) / float(_max_health)


## Fraction covered by the ghost segment (never less than health).
func get_ghost_fraction() -> float:
	return maxf(_ghost, get_health_fraction())


func is_health_visible() -> bool:
	return _health_visible


func get_stamina() -> int:
	return _stamina


func get_max_stamina() -> int:
	return _max_stamina


## Stamina fraction (0 to 1).
func get_stamina_fraction() -> float:
	return float(_stamina) / float(_max_stamina)


func is_exhausted() -> bool:
	return _exhausted


## Opacity of the stamina bar: 0 when hidden because it is full.
func get_stamina_alpha() -> float:
	return _stamina_alpha


## true while the stamina bar is visible (even if midway through the fade).
func is_stamina_visible() -> bool:
	return _stamina_alpha > 0.0


## true while it blinks for lack of stamina.
func is_blinking() -> bool:
	return _blink_left > 0.0


## Opacity stamina is drawn with: that of [method get_stamina_alpha] and, at minimum,
## [constant STAMINA_IDLE_ALPHA] (the thin bar never disappears: UI-55).
func get_drawn_stamina_alpha() -> float:
	return maxf(_stamina_alpha, STAMINA_IDLE_ALPHA)


func _draw() -> void:
	var left: float = (size.x - BAR_WIDTH) * 0.5
	var y: float = 0.0
	if _health_visible:
		_draw_health(Rect2(left, y, BAR_WIDTH, HEALTH_HEIGHT))
		y += HEALTH_HEIGHT + BAR_GAP
	_draw_stamina(Rect2(left, y, BAR_WIDTH, STAMINA_HEIGHT))


func _draw_health(rect: Rect2) -> void:
	draw_rect(rect, BACK_COLOR)
	var ghost_width: float = rect.size.x * get_ghost_fraction()
	draw_rect(Rect2(rect.position, Vector2(ghost_width, rect.size.y)), GHOST_COLOR)
	var health_width: float = rect.size.x * get_health_fraction()
	draw_rect(Rect2(rect.position, Vector2(health_width, rect.size.y)), HEALTH_COLOR)
	# A shine on the top half gives volume to the fill.
	draw_rect(Rect2(rect.position, Vector2(health_width, rect.size.y * 0.4)), HEALTH_SHINE)
	# Ticks every 10 %: let you read health by eye without looking at the number.
	for tenth: int in range(1, 10):
		var x: float = rect.position.x + rect.size.x * float(tenth) * 0.1
		draw_line(Vector2(x, rect.position.y + rect.size.y * 0.55), Vector2(x, rect.end.y),
				TICK_COLOR, 1.0)
	# Metal frame: dark outline and light edge on the inside.
	draw_rect(rect.grow(1.0), BORDER_COLOR, false, 2.0)
	draw_rect(rect, FRAME_COLOR, false, 1.0)
	var font: Font = UIFonts.body_semibold()
	var text: String = "%d / %d" % [_health, _max_health]
	var baseline: Vector2 = rect.position + Vector2(0.0, rect.size.y - 5.0)
	draw_string_outline(font, baseline, text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, FONT_SIZE, 3,
			UIPalette.OUTLINE)
	draw_string(font, baseline, text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, FONT_SIZE, TEXT_COLOR)


func _draw_stamina(rect: Rect2) -> void:
	var alpha: float = get_drawn_stamina_alpha()
	var back: Color = BACK_COLOR
	back.a *= alpha
	draw_rect(rect, back)
	var color: Color = EXHAUSTED_COLOR if _exhausted else STAMINA_COLOR
	color.a = alpha
	draw_rect(Rect2(rect.position, Vector2(rect.size.x * get_stamina_fraction(), rect.size.y)), color)
	var border: Color = BORDER_COLOR
	border.a *= alpha
	var width: float = 1.5
	if _blink_left > 0.0 and int(_blink_clock * BLINK_HERTZ * 2.0) % 2 == 0:
		border = BLINK_COLOR
		width = 3.0
		draw_rect(Rect2(rect.position, Vector2(rect.size.x, rect.size.y)), BLINK_COLOR * Color(1, 1, 1, 0.35))
	draw_rect(rect, border, false, width)
