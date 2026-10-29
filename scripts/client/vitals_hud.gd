class_name VitalsHud
extends Control
## Barras de vida y resistencia abajo al centro de la pantalla (UI-10). Solo muestran: no leen la
## red ni la simulación, las alimenta el [HUD] con [method set_health] y [method set_stamina].
## [br][br]
## [b]Vida[/b] (la decide el servidor, sale del bloque extra del snapshot): barra roja con el
## valor, y detrás un tramo fantasma de la pérdida reciente (claro) que espera
## [constant GHOST_HOLD_SECONDS] s y luego se encoge hasta la vida actual. Al curarse, el fantasma
## sigue a la barra. En el sandbox sin red la vida no existe y [method set_health_visible]
## la oculta.
## [br][br]
## [b]Resistencia[/b] (predicha, de [PlayerState]): barra fina verde (naranja si está agotado)
## debajo de la de vida. Se oculta con un fundido cuando está llena. Cuando una acción falla por
## falta de resistencia (el bit 1 de [member CombatState.combat_flags], que dura un tick), la barra
## aparece aunque esté llena y parpadea en rojo durante [constant BLINK_SECONDS] s
## ([method notify_no_stamina]).
## [br][br]
## El tiempo lo lleva [method advance] ([method _process] lo llama con el delta de cada
## fotograma); las pruebas lo llaman con pasos exactos.

## Segundos que el fantasma espera antes de encogerse, y su velocidad (fracción de la barra por s).
const GHOST_HOLD_SECONDS: float = 0.5
const GHOST_SHRINK_SPEED: float = 0.6
## Duración del parpadeo por falta de resistencia y su frecuencia (Hz).
const BLINK_SECONDS: float = 0.6
const BLINK_HERTZ: float = 8.0
## Segundos con la resistencia llena antes de empezar a ocultar la barra y velocidad del fundido
## (opacidad por segundo).
const STAMINA_HIDE_DELAY: float = 0.8
const STAMINA_FADE_SPEED: float = 3.0
## Medidas de las barras (px).
const BAR_WIDTH: float = 380.0
const HEALTH_HEIGHT: float = 18.0
const STAMINA_HEIGHT: float = 9.0
const BAR_GAP: float = 5.0
const FONT_SIZE: int = 14

const HEALTH_COLOR: Color = Color(0.78, 0.13, 0.15, 1.0)
const GHOST_COLOR: Color = Color(1.0, 0.82, 0.55, 0.85)
const BACK_COLOR: Color = Color(0.04, 0.04, 0.05, 0.65)
const BORDER_COLOR: Color = Color(0.0, 0.0, 0.0, 0.8)
const STAMINA_COLOR: Color = Color(0.58, 0.82, 0.3, 1.0)
const EXHAUSTED_COLOR: Color = Color(0.95, 0.5, 0.12, 1.0)
const BLINK_COLOR: Color = Color(1.0, 0.15, 0.1, 1.0)
const TEXT_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)

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


## Vida actual y máxima (la del servidor). Una pérdida deja el tramo fantasma; una curación lo
## iguala a la barra.
func set_health(current: int, max_value: int) -> void:
	var previous: float = get_health_fraction()
	_max_health = maxi(max_value, 1)
	_health = clampi(current, 0, _max_health)
	var now: float = get_health_fraction()
	if now < previous - 0.0001:
		# Una pérdida: el fantasma se queda donde estaba la barra (o más arriba, si todavía
		# encogía otra pérdida) y espera antes de encogerse.
		_ghost = maxf(_ghost, previous)
		_ghost_hold = GHOST_HOLD_SECONDS
	elif now >= _ghost:
		_ghost = now
	queue_redraw()


## Fija la vida sin dejar fantasma (el primer valor que llega, tras reaparecer o al entrar).
func snap_health(current: int, max_value: int) -> void:
	_max_health = maxi(max_value, 1)
	_health = clampi(current, 0, _max_health)
	_ghost = get_health_fraction()
	_ghost_hold = 0.0
	queue_redraw()


## Resistencia actual y máxima (la predicha) y si el personaje está agotado.
func set_stamina(current: int, max_value: int, exhausted: bool = false) -> void:
	_max_stamina = maxi(max_value, 1)
	_stamina = clampi(current, 0, _max_stamina)
	_exhausted = exhausted
	queue_redraw()


## Muestra u oculta la barra de vida (sin red no hay vida que enseñar).
func set_health_visible(shown: bool) -> void:
	_health_visible = shown
	queue_redraw()


## Una acción ha fallado por falta de resistencia: la barra aparece y parpadea en rojo.
func notify_no_stamina() -> void:
	_blink_left = BLINK_SECONDS
	_blink_clock = 0.0
	_stamina_alpha = 1.0
	_full_time = 0.0
	queue_redraw()


## Avanza [param delta] segundos el fantasma, el parpadeo y el fundido de la resistencia.
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


# --- Lectura (para las pruebas y el HUD) ------------------------------------------------------

func get_health() -> int:
	return _health


func get_max_health() -> int:
	return _max_health


## Fracción de vida (0 a 1).
func get_health_fraction() -> float:
	return float(_health) / float(_max_health)


## Fracción que cubre el tramo fantasma (nunca menos que la vida).
func get_ghost_fraction() -> float:
	return maxf(_ghost, get_health_fraction())


func is_health_visible() -> bool:
	return _health_visible


func get_stamina() -> int:
	return _stamina


func get_max_stamina() -> int:
	return _max_stamina


## Fracción de resistencia (0 a 1).
func get_stamina_fraction() -> float:
	return float(_stamina) / float(_max_stamina)


func is_exhausted() -> bool:
	return _exhausted


## Opacidad de la barra de resistencia: 0 cuando está oculta por estar llena.
func get_stamina_alpha() -> float:
	return _stamina_alpha


## true mientras la barra de resistencia se ve (aunque sea a medias del fundido).
func is_stamina_visible() -> bool:
	return _stamina_alpha > 0.0


## true mientras parpadea por falta de resistencia.
func is_blinking() -> bool:
	return _blink_left > 0.0


func _draw() -> void:
	var left: float = (size.x - BAR_WIDTH) * 0.5
	var y: float = 0.0
	if _health_visible:
		_draw_health(Rect2(left, y, BAR_WIDTH, HEALTH_HEIGHT))
		y += HEALTH_HEIGHT + BAR_GAP
	if _stamina_alpha > 0.0:
		_draw_stamina(Rect2(left, y, BAR_WIDTH, STAMINA_HEIGHT))


func _draw_health(rect: Rect2) -> void:
	draw_rect(rect, BACK_COLOR)
	var ghost_width: float = rect.size.x * get_ghost_fraction()
	draw_rect(Rect2(rect.position, Vector2(ghost_width, rect.size.y)), GHOST_COLOR)
	var health_width: float = rect.size.x * get_health_fraction()
	draw_rect(Rect2(rect.position, Vector2(health_width, rect.size.y)), HEALTH_COLOR)
	draw_rect(rect, BORDER_COLOR, false, 1.5)
	var font: Font = ThemeDB.fallback_font
	var text: String = "%d / %d" % [_health, _max_health]
	draw_string(font, rect.position + Vector2(0.0, rect.size.y - 4.0), text,
			HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, FONT_SIZE, TEXT_COLOR)


func _draw_stamina(rect: Rect2) -> void:
	var alpha: float = _stamina_alpha
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
