class_name LowHealthVignette
extends TextureRect
## Red vignette at the screen edges (UI-10, UI-50). The texture is a radial gradient, transparent in the
## center and red only at the edge (the color starts at 84 % of the radius), created at start-up (there is no binary
## resource); the only thing that changes is its opacity:
## [br]- Below [constant START_FRACTION] of health, it rises along a smooth curve up to
## [constant MAX_ALPHA] at [constant FULL_FRACTION].
## [br]- It pulses slowly ([constant PULSE_HERTZ]) while it holds, so that it is not a fixed blotch.
## [br]- Each hit received adds a brief flash ([method flash]) [b]proportional to the damage[/b]: from
## [constant FLASH_MIN_ALPHA] to [constant FLASH_MAX_ALPHA] according to the fraction of maximum health it takes away (the maximum, from
## [constant FLASH_FULL_FRACTION]). A hit of 90 out of 1000 health covers a minimal fraction of the
## screen: before, it was a fixed 0.45 over half the screen, for any scratch.
## [br]- With [method set_suppressed] (the death screen, which already dims the world and the HUD) nothing is drawn.

## Health fraction below which it starts to show and at which it reaches the maximum.
const START_FRACTION: float = 0.35
const FULL_FRACTION: float = 0.08
## Maximum opacity of the fixed vignette and pulse frequency (Hz).
const MAX_ALPHA: float = 0.75
const PULSE_HERTZ: float = 1.1
const PULSE_DEPTH: float = 0.18
## Opacity of a hit's flash: from the minimum (a scratch) to the maximum (a hit of [constant FLASH_FULL_FRACTION] of
## health or more).
const FLASH_MIN_ALPHA: float = 0.10
const FLASH_MAX_ALPHA: float = 0.35
## Fraction of maximum health in a single hit at which the flash reaches [constant FLASH_MAX_ALPHA].
const FLASH_FULL_FRACTION: float = 0.25
## Maximum health assumed if it is not known (that of Vado Gris).
const DEFAULT_MAX_HEALTH: int = 1000
## Seconds a hit's flash takes to fade out.
const FLASH_SECONDS: float = 0.35
const EDGE_COLOR: Color = Color(0.75, 0.04, 0.04, 1.0)
## Texture gradient: radius (1 = the screen edge at half height or width) and opacity. Transparent up to
## 84 % of the radius; in the corners (radius greater than 1) it reaches opaque.
const GRADIENT_RADIUS: float = 1.25
const GRADIENT_STOPS: Array[Vector2] = [
	Vector2(0.0, 0.0), Vector2(0.84, 0.0), Vector2(0.95, 0.35), Vector2(1.05, 0.8), Vector2(1.25, 1.0),
]

var _health_fraction: float = 1.0
var _flash_left: float = 0.0
var _flash_peak: float = 0.0
var _suppressed: bool = false
var _clock: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	texture = _make_texture()
	_apply()


func _process(delta: float) -> void:
	advance(delta)


## Health fraction (0 to 1) used to compute the fixed vignette.
func set_health_fraction(fraction: float) -> void:
	_health_fraction = clampf(fraction, 0.0, 1.0)
	_apply()


## Turns off the whole vignette (the fixed one, the pulse and the flash) while true: the death screen. On turning it off any
## flash is forgotten.
func set_suppressed(suppressed: bool) -> void:
	_suppressed = suppressed
	if suppressed:
		_flash_left = 0.0
	_apply()


func is_suppressed() -> bool:
	return _suppressed


## Brief flash on receiving a hit of [param amount] damage against [param max_health] maximum health, even if health
## is high. Its opacity is proportional to the damage ([method flash_alpha_for]). With no arguments, that of a scratch.
func flash(amount: int = 0, max_health: int = DEFAULT_MAX_HEALTH) -> void:
	if _suppressed:
		return
	_flash_peak = flash_alpha_for(amount, max_health)
	_flash_left = FLASH_SECONDS
	_apply()


## Advances the pulse and the flash by [param delta] seconds.
func advance(delta: float) -> void:
	_clock += delta
	_flash_left = maxf(_flash_left - delta, 0.0)
	_apply()


## Initial opacity of the flash of a hit of [param amount] against [param max_health]: [constant FLASH_MIN_ALPHA] with no
## damage and [constant FLASH_MAX_ALPHA] with [constant FLASH_FULL_FRACTION] of maximum health or more, proportionally in
## between.
static func flash_alpha_for(amount: int, max_health: int) -> float:
	var fraction: float = float(maxi(amount, 0)) / float(maxi(max_health, 1)) / FLASH_FULL_FRACTION
	return lerpf(FLASH_MIN_ALPHA, FLASH_MAX_ALPHA, clampf(fraction, 0.0, 1.0))


## Opacity of the fixed vignette according to health, without the pulse: 0 above
## [constant START_FRACTION] and [constant MAX_ALPHA] below [constant FULL_FRACTION].
func get_base_alpha() -> float:
	return MAX_ALPHA * smoothstep(START_FRACTION, FULL_FRACTION, _health_fraction)


## Total opacity drawn now (fixed vignette with pulse plus flash); 0 if turned off.
func get_alpha() -> float:
	if _suppressed:
		return 0.0
	var base: float = get_base_alpha()
	var pulse: float = 1.0 - PULSE_DEPTH + PULSE_DEPTH * sin(_clock * TAU * PULSE_HERTZ)
	var flash_alpha: float = _flash_peak * (_flash_left / FLASH_SECONDS)
	return clampf(maxf(base * pulse, flash_alpha), 0.0, 1.0)


## How much of the screen the vignette covers with opacity [param alpha], from 0 to 1: the mean of the gradient's opacity times
## the vignette's (to measure how much a hit tints without taking a screenshot).
static func screen_coverage(alpha: float) -> float:
	# Numerical integral of the gradient over a square of side 2 (radius 1 = edge at half height or width).
	var steps: int = 64
	var total: float = 0.0
	for ix: int in steps:
		var x: float = (float(ix) + 0.5) / float(steps) * 2.0 - 1.0
		for iy: int in steps:
			var y: float = (float(iy) + 0.5) / float(steps) * 2.0 - 1.0
			total += gradient_alpha_at(Vector2(x, y).length())
	return alpha * total / float(steps * steps)


## Opacity (0 to 1) of the gradient at [param radius] from the center (1 = the screen edge at half height or width).
static func gradient_alpha_at(radius: float) -> float:
	var previous: Vector2 = GRADIENT_STOPS[0]
	if radius <= previous.x:
		return previous.y
	for index: int in range(1, GRADIENT_STOPS.size()):
		var stop: Vector2 = GRADIENT_STOPS[index]
		if radius <= stop.x:
			return lerpf(previous.y, stop.y, (radius - previous.x) / (stop.x - previous.x))
		previous = stop
	return previous.y


func _apply() -> void:
	modulate.a = get_alpha()
	visible = modulate.a > 0.002


func _make_texture() -> Texture2D:
	var gradient := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for stop: Vector2 in GRADIENT_STOPS:
		offsets.append(stop.x / GRADIENT_RADIUS)
		colors.append(Color(EDGE_COLOR, stop.y))
	gradient.offsets = offsets
	gradient.colors = colors
	var texture_2d := GradientTexture2D.new()
	texture_2d.gradient = gradient
	texture_2d.fill = GradientTexture2D.FILL_RADIAL
	texture_2d.fill_from = Vector2(0.5, 0.5)
	# Radius 1 (screen edge at half height) is half of the texture; the gradient continues up to 1.25.
	texture_2d.fill_to = Vector2(0.5 + 0.5 * GRADIENT_RADIUS, 0.5)
	texture_2d.width = 256
	texture_2d.height = 256
	return texture_2d
