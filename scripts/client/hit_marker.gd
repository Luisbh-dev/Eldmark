class_name HitMarker
extends Control
## Marcador de impacto alrededor del punto de mira (UI-12). Cuatro marcas en diagonal que aparecen
## cuando el servidor confirma un golpe propio (ENTITY_EVENT) y se desvanecen enseguida. Nunca se
## predice: [CombatFeedback] solo lo dispara al recibir el evento.
## [br][br]
## Variantes ([enum Kind]): golpe normal (blanco), golpe fuerte (naranja, más grande), bloqueado (gris azulado,
## más pequeño y con la marca cortada), parada (dorado, con un aro) y muerte (rojo, el mayor, con una cruz de
## cuatro puntas). Calidad (UI-12): las marcas son gruesas (4 px, con contorno), nacen un 40 % más grandes y se
## encogen al sitio en 70 ms, así que se leen incluso en mitad de una refriega.

enum Kind { HIT, HEAVY, BLOCKED, KILL, PARRY }

## Duración (s) del marcador de cada variante.
const DURATIONS: Dictionary[int, float] = {
	Kind.HIT: 0.22,
	Kind.HEAVY: 0.3,
	Kind.BLOCKED: 0.22,
	Kind.KILL: 0.5,
	Kind.PARRY: 0.32,
}
## Distancia (px) del centro a la que empieza cada marca y su longitud, por variante.
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
## Grosor de la marca (px) y del contorno extra; sube en las variantes que más importan.
const LINE_WIDTH: float = 4.0
const OUTLINE_EXTRA: float = 3.0
## Cuánto más grande nace el marcador (1 = sin salto) y cuánto dura (fracción de su vida) el encogimiento.
const POP_SCALE: float = 1.4
const POP_FRACTION: float = 0.3

## false: no se muestra ningún marcador (opción del jugador).
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


## Enseña el marcador de la variante [param variant] (reinicia el que hubiera). No hace nada si
## [member enabled] es false.
func show_marker(variant: int) -> void:
	if not enabled:
		return
	_variant = variant if DURATIONS.has(variant) else Kind.HIT
	_duration = DURATIONS[_variant]
	_time_left = _duration
	_shown_count += 1
	queue_redraw()


## Avanza [param delta] segundos el desvanecimiento.
func advance(delta: float) -> void:
	if _time_left <= 0.0:
		return
	_time_left = maxf(_time_left - delta, 0.0)
	queue_redraw()


## Lo quita al instante.
func clear() -> void:
	_time_left = 0.0
	queue_redraw()


## true mientras se ve el marcador.
func is_active() -> bool:
	return _time_left > 0.0


## Variante del último marcador (o del que se ve).
func get_variant() -> int:
	return _variant


## Opacidad actual (1 al aparecer, 0 al acabar).
func get_alpha() -> float:
	if _duration <= 0.0 or _time_left <= 0.0:
		return 0.0
	return clampf(_time_left / _duration, 0.0, 1.0)


## Veces que se ha enseñado el marcador desde que existe (para las pruebas).
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
	# Salto de escala: nace un 40 % más grande y se encoge a su sitio en el primer tramo de su vida.
	var age: float = 1.0 - alpha
	var pop: float = lerpf(POP_SCALE, 1.0, clampf(age / POP_FRACTION, 0.0, 1.0))
	var width: float = LINE_WIDTH + (1.5 if _variant == Kind.KILL or _variant == Kind.HEAVY else 0.0)
	# Se encoge hacia el centro al desvanecerse.
	var pull: float = maxf(age - POP_FRACTION, 0.0) * 6.0
	for diagonal: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var direction: Vector2 = diagonal.normalized()
		var from: Vector2 = center + direction * (inner * pop - pull)
		var to: Vector2 = center + direction * ((inner + length) * pop - pull)
		if _variant == Kind.BLOCKED:
			# Bloqueado: la marca queda cortada a la mitad.
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
