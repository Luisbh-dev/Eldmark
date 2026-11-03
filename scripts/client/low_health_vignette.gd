class_name LowHealthVignette
extends TextureRect
## Viñeta roja en los bordes de la pantalla (UI-10, UI-50). La textura es un degradado radial transparente en el
## centro y rojo solo en el borde (el color empieza al 84 % del radio), creado al arrancar (no hay ningún recurso
## binario); lo único que cambia es su opacidad:
## [br]- Por debajo de [constant START_FRACTION] de la vida, sube con una curva suave hasta
## [constant MAX_ALPHA] a [constant FULL_FRACTION].
## [br]- Late despacio ([constant PULSE_HERTZ]) mientras se mantiene, para que no sea una mancha fija.
## [br]- Cada golpe recibido añade un destello breve ([method flash]) [b]proporcional al daño[/b]: de
## [constant FLASH_MIN_ALPHA] a [constant FLASH_MAX_ALPHA] según la fracción de la vida máxima que quita (el máximo, a
## partir de [constant FLASH_FULL_FRACTION]). Un golpe de 90 sobre 1000 de vida cubre una fracción mínima de la
## pantalla: antes era un 0,45 fijo sobre media pantalla, con cualquier rasguño.
## [br]- Con [method set_suppressed] (la pantalla de muerte, que ya atenúa el mundo y el HUD) no se dibuja nada.

## Fracción de vida bajo la que empieza a verse y a la que llega al máximo.
const START_FRACTION: float = 0.35
const FULL_FRACTION: float = 0.08
## Opacidad máxima de la viñeta fija y frecuencia del latido (Hz).
const MAX_ALPHA: float = 0.75
const PULSE_HERTZ: float = 1.1
const PULSE_DEPTH: float = 0.18
## Opacidad del destello de un golpe: del mínimo (un rasguño) al máximo (un golpe de [constant FLASH_FULL_FRACTION] de
## la vida o más).
const FLASH_MIN_ALPHA: float = 0.10
const FLASH_MAX_ALPHA: float = 0.35
## Fracción de la vida máxima de un solo golpe con la que el destello llega a [constant FLASH_MAX_ALPHA].
const FLASH_FULL_FRACTION: float = 0.25
## Vida máxima que se supone si no se conoce (la del Vado Gris).
const DEFAULT_MAX_HEALTH: int = 1000
## Segundos que tarda en apagarse el destello de un golpe.
const FLASH_SECONDS: float = 0.35
const EDGE_COLOR: Color = Color(0.75, 0.04, 0.04, 1.0)
## Degradado de la textura: radio (1 = el borde de la pantalla a media altura o anchura) y opacidad. Transparente hasta
## el 84 % del radio; en las esquinas (radio mayor que 1) llega a opaco.
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


## Fracción de vida (0 a 1) con la que se calcula la viñeta fija.
func set_health_fraction(fraction: float) -> void:
	_health_fraction = clampf(fraction, 0.0, 1.0)
	_apply()


## Apaga la viñeta entera (la fija, el latido y el destello) mientras sea true: la pantalla de muerte. Al apagarla se
## olvida el destello que hubiera.
func set_suppressed(suppressed: bool) -> void:
	_suppressed = suppressed
	if suppressed:
		_flash_left = 0.0
	_apply()


func is_suppressed() -> bool:
	return _suppressed


## Destello breve al recibir un golpe de [param amount] de daño sobre [param max_health] de vida máxima, aunque la vida
## sea alta. Su opacidad es proporcional al daño ([method flash_alpha_for]). Sin argumentos, el de un rasguño.
func flash(amount: int = 0, max_health: int = DEFAULT_MAX_HEALTH) -> void:
	if _suppressed:
		return
	_flash_peak = flash_alpha_for(amount, max_health)
	_flash_left = FLASH_SECONDS
	_apply()


## Avanza [param delta] segundos el latido y el destello.
func advance(delta: float) -> void:
	_clock += delta
	_flash_left = maxf(_flash_left - delta, 0.0)
	_apply()


## Opacidad inicial del destello de un golpe de [param amount] sobre [param max_health]: [constant FLASH_MIN_ALPHA] sin
## daño y [constant FLASH_MAX_ALPHA] con [constant FLASH_FULL_FRACTION] de la vida máxima o más, en proporción entre
## medias.
static func flash_alpha_for(amount: int, max_health: int) -> float:
	var fraction: float = float(maxi(amount, 0)) / float(maxi(max_health, 1)) / FLASH_FULL_FRACTION
	return lerpf(FLASH_MIN_ALPHA, FLASH_MAX_ALPHA, clampf(fraction, 0.0, 1.0))


## Opacidad de la viñeta fija según la vida, sin el latido: 0 por encima de
## [constant START_FRACTION] y [constant MAX_ALPHA] por debajo de [constant FULL_FRACTION].
func get_base_alpha() -> float:
	return MAX_ALPHA * smoothstep(START_FRACTION, FULL_FRACTION, _health_fraction)


## Opacidad total que se dibuja ahora (viñeta fija con latido más destello); 0 si está apagada.
func get_alpha() -> float:
	if _suppressed:
		return 0.0
	var base: float = get_base_alpha()
	var pulse: float = 1.0 - PULSE_DEPTH + PULSE_DEPTH * sin(_clock * TAU * PULSE_HERTZ)
	var flash_alpha: float = _flash_peak * (_flash_left / FLASH_SECONDS)
	return clampf(maxf(base * pulse, flash_alpha), 0.0, 1.0)


## Cuánta pantalla cubre la viñeta con opacidad [param alpha], de 0 a 1: la media de la opacidad del degradado por la
## de la viñeta (para medir lo que tiñe un golpe sin hacer una captura).
static func screen_coverage(alpha: float) -> float:
	# Integral numérica del degradado en un cuadrado de lado 2 (radio 1 = borde a media altura o anchura).
	var steps: int = 64
	var total: float = 0.0
	for ix: int in steps:
		var x: float = (float(ix) + 0.5) / float(steps) * 2.0 - 1.0
		for iy: int in steps:
			var y: float = (float(iy) + 0.5) / float(steps) * 2.0 - 1.0
			total += gradient_alpha_at(Vector2(x, y).length())
	return alpha * total / float(steps * steps)


## Opacidad (0 a 1) del degradado a [param radius] del centro (1 = el borde de la pantalla a media altura o anchura).
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
	# El radio 1 (borde de la pantalla a media altura) es la mitad de la textura; el degradado sigue hasta 1,25.
	texture_2d.fill_to = Vector2(0.5 + 0.5 * GRADIENT_RADIUS, 0.5)
	texture_2d.width = 256
	texture_2d.height = 256
	return texture_2d
