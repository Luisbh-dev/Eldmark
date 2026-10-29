class_name LowHealthVignette
extends TextureRect
## Viñeta roja en los bordes de la pantalla cuando queda poca vida (UI-10). La textura es un
## degradado radial transparente en el centro y rojo en los bordes, creado al arrancar (no hay
## ningún recurso binario); lo único que cambia es su opacidad:
## [br]- Por debajo de [constant START_FRACTION] de la vida, sube con una curva suave hasta
## [constant MAX_ALPHA] a [constant FULL_FRACTION].
## [br]- Late despacio ([constant PULSE_HERTZ]) mientras se mantiene, para que no sea una mancha fija.
## [br]- Cada golpe recibido añade un destello breve ([method flash]).

## Fracción de vida bajo la que empieza a verse y a la que llega al máximo.
const START_FRACTION: float = 0.35
const FULL_FRACTION: float = 0.08
## Opacidad máxima de la viñeta fija, del destello de un golpe y frecuencia del latido (Hz).
const MAX_ALPHA: float = 0.75
const FLASH_ALPHA: float = 0.45
const PULSE_HERTZ: float = 1.1
const PULSE_DEPTH: float = 0.18
## Segundos que tarda en apagarse el destello de un golpe.
const FLASH_SECONDS: float = 0.35
const EDGE_COLOR: Color = Color(0.75, 0.04, 0.04, 1.0)

var _health_fraction: float = 1.0
var _flash_left: float = 0.0
var _clock: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	texture = _make_texture()
	_apply()


func _process(delta: float) -> void:
	advance(delta)


## Fracción de vida (0 a 1) con la que se calcula la viñeta fija.
func set_health_fraction(fraction: float) -> void:
	_health_fraction = clampf(fraction, 0.0, 1.0)
	_apply()


## Destello breve al recibir un golpe, aunque la vida sea alta.
func flash() -> void:
	_flash_left = FLASH_SECONDS
	_apply()


## Avanza [param delta] segundos el latido y el destello.
func advance(delta: float) -> void:
	_clock += delta
	_flash_left = maxf(_flash_left - delta, 0.0)
	_apply()


## Opacidad de la viñeta fija según la vida, sin el latido: 0 por encima de
## [constant START_FRACTION] y [constant MAX_ALPHA] por debajo de [constant FULL_FRACTION].
func get_base_alpha() -> float:
	return MAX_ALPHA * smoothstep(START_FRACTION, FULL_FRACTION, _health_fraction)


## Opacidad total que se dibuja ahora (viñeta fija con latido más destello).
func get_alpha() -> float:
	var base: float = get_base_alpha()
	var pulse: float = 1.0 - PULSE_DEPTH + PULSE_DEPTH * sin(_clock * TAU * PULSE_HERTZ)
	var flash_alpha: float = FLASH_ALPHA * (_flash_left / FLASH_SECONDS)
	return clampf(maxf(base * pulse, flash_alpha), 0.0, 1.0)


func _apply() -> void:
	modulate.a = get_alpha()
	visible = modulate.a > 0.002


func _make_texture() -> Texture2D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	gradient.colors = PackedColorArray([
		Color(EDGE_COLOR, 0.0), Color(EDGE_COLOR, 0.0), Color(EDGE_COLOR, 1.0),
	])
	var texture_2d := GradientTexture2D.new()
	texture_2d.gradient = gradient
	texture_2d.fill = GradientTexture2D.FILL_RADIAL
	texture_2d.fill_from = Vector2(0.5, 0.5)
	texture_2d.fill_to = Vector2(1.0, 0.5)
	texture_2d.width = 256
	texture_2d.height = 256
	return texture_2d
