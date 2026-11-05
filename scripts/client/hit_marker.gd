class_name HitMarker
extends Control
## Hit marker around the crosshair (UI-12). Four diagonal marks that appear
## when the server confirms an own hit (ENTITY_EVENT) and quickly fade. It is never
## predicted: [CombatFeedback] only fires it on receiving the event.
## [br][br]
## Variants ([enum Kind]): normal hit (white), heavy hit (orange, larger), blocked (bluish gray,
## smaller and with the mark cut short), parry (gold, with a ring) and death (red, the largest, with a four-pointed
## cross). Quality (UI-12): the marks are thick (4 px, outlined), are born 40% larger and
## shrink into place in 70 ms, so they read even in the middle of a melee.

enum Kind { HIT, HEAVY, BLOCKED, KILL, PARRY }

## Duration (s) of the marker of each variant.
const DURATIONS: Dictionary[int, float] = {
	Kind.HIT: 0.22,
	Kind.HEAVY: 0.3,
	Kind.BLOCKED: 0.22,
	Kind.KILL: 0.5,
	Kind.PARRY: 0.32,
}
## Distance (px) from the center at which each mark starts and its length, per variant.
const INNER_RADIUS: Dictionary[int, float] = {
	Kind.HIT: 9.0,
	Kind.HEAVY: 11.0,
	Kind.BLOCKED: 9.0,
	Kind.KILL: 14.0,
	Kind.PARRY: 12.0,
}
const TICK_LENGTH: Dictionary[int, float] = {
	Kind.HIT: 10.0,
	Kind.HEAVY: 14.0,
	Kind.BLOCKED: 7.0,
	Kind.KILL: 18.0,
	Kind.PARRY: 12.0,
}
const COLORS: Dictionary[int, Color] = {
	Kind.HIT: Color(1.0, 1.0, 1.0, 1.0),
	Kind.HEAVY: Color(1.0, 0.72, 0.25, 1.0),
	Kind.BLOCKED: Color(0.62, 0.74, 0.9, 1.0),
	Kind.KILL: Color(1.0, 0.25, 0.2, 1.0),
	Kind.PARRY: Color(1.0, 0.86, 0.35, 1.0),
}
const OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.75)
## Thickness of the mark (px) and of the extra outline; it goes up on the variants that matter most.
const LINE_WIDTH: float = 4.0
const OUTLINE_EXTRA: float = 3.0
## How much larger the marker is born (1 = no jump) and how long the shrinking lasts (fraction of its life).
const POP_SCALE: float = 1.4
const POP_FRACTION: float = 0.3

## false: no marker is shown (player option).
var enabled: bool = true:
	set(value):
		enabled = value
		if not enabled:
			clear()

var _variant: int = Kind.HIT
var _time_left: float = 0.0
var _duration: float = 0.0
var _shown_count: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	advance(delta)


## Shows the marker of variant [param variant] (restarts any existing one). Does nothing if
## [member enabled] is false.
func show_marker(variant: int) -> void:
	if not enabled:
		return
	_variant = variant if DURATIONS.has(variant) else Kind.HIT
	_duration = DURATIONS[_variant]
	_time_left = _duration
	_shown_count += 1
	queue_redraw()


## Advances the fade by [param delta] seconds.
func advance(delta: float) -> void:
	if _time_left <= 0.0:
		return
	_time_left = maxf(_time_left - delta, 0.0)
	queue_redraw()


## Removes it instantly.
func clear() -> void:
	_time_left = 0.0
	queue_redraw()


## true while the marker is visible.
func is_active() -> bool:
	return _time_left > 0.0


## Variant of the last marker (or of the one being shown).
func get_variant() -> int:
	return _variant


## Current opacity (1 on appearing, 0 at the end).
func get_alpha() -> float:
	if _duration <= 0.0 or _time_left <= 0.0:
		return 0.0
	return clampf(_time_left / _duration, 0.0, 1.0)


## Times the marker has been shown since it exists (for tests).
func get_shown_count() -> int:
	return _shown_count


func _draw() -> void:
	if _time_left <= 0.0:
		return
	var alpha: float = get_alpha()
	var center: Vector2 = size * 0.5
	var color: Color = COLORS[_variant]
	color.a = alpha
	var outline: Color = OUTLINE_COLOR
	outline.a *= alpha
	var inner: float = INNER_RADIUS[_variant]
	var length: float = TICK_LENGTH[_variant]
	# Scale jump: born 40% larger and shrinks into place in the first stretch of its life.
	var age: float = 1.0 - alpha
	var pop: float = lerpf(POP_SCALE, 1.0, clampf(age / POP_FRACTION, 0.0, 1.0))
	var width: float = LINE_WIDTH + (1.5 if _variant == Kind.KILL or _variant == Kind.HEAVY else 0.0)
	# It shrinks toward the center as it fades.
	var pull: float = maxf(age - POP_FRACTION, 0.0) * 6.0
	for diagonal: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var direction: Vector2 = diagonal.normalized()
		var from: Vector2 = center + direction * (inner * pop - pull)
		var to: Vector2 = center + direction * ((inner + length) * pop - pull)
		if _variant == Kind.BLOCKED:
			# Blocked: the mark is cut to half.
			to = from + (to - from) * 0.55
		draw_line(from, to, outline, width + OUTLINE_EXTRA, true)
		draw_line(from, to, color, width, true)
	if _variant == Kind.PARRY:
		draw_arc(center, inner * pop - 4.0, 0.0, TAU, 28, outline, 2.0 + OUTLINE_EXTRA, true)
		draw_arc(center, inner * pop - 4.0, 0.0, TAU, 28, color, 2.0, true)
	elif _variant == Kind.KILL:
		for cross: Vector2 in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
			var start: Vector2 = center + cross * (inner * pop * 0.55)
			var finish: Vector2 = center + cross * (inner * pop * 0.55 + length * 0.7 * pop)
			draw_line(start, finish, outline, width + OUTLINE_EXTRA, true)
			draw_line(start, finish, color, width, true)
