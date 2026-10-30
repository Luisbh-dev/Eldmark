class_name StatusIcons
extends HBoxContainer
## Fila de iconos de efectos de estado (UI-45, docs/habilidades.md, sección 6.4): la propia, sobre la
## barra de vida, y la pequeña de las placas de nombre (hasta 4, primero los perjudiciales). Cada icono
## enseña el efecto (cuadro provisional con su inicial, [CombatIcons]), los segundos que le quedan, las
## acumulaciones si hay más de una y un borde rojo si perjudica o verde si no; el tooltip da su nombre y
## qué hace.
## [br][br]
## No lee la red: quien la tiene le pasa con [method show_entries] los efectos de un [StatusTracker] y el
## tick con el que contar lo que queda (el del servidor estimado para el jugador local; el de dibujo en
## las placas). Un efecto que ya acabó en ese tick no sale. Los iconos se reutilizan (pool). Solo
## cliente.

## Lado (px) de cada icono de la fila propia y de la de las placas.
const ICON_SIZE: float = 30.0
const COMPACT_ICON_SIZE: float = 18.0
const BORDER_WIDTH: float = 2.0
const HARMFUL_BORDER: Color = Color(0.92, 0.22, 0.18, 1.0)
const BENEFICIAL_BORDER: Color = Color(0.35, 0.85, 0.4, 1.0)
const TEXT_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)
const SECONDS_FONT_SIZE: int = 12
const STACKS_FONT_SIZE: int = 12


## Un icono de efecto (se dibuja él solo; su [member Control.tooltip_text] es el del efecto).
class StatusIcon extends Control:
	var status_id: int = 0
	var stacks: int = 1
	var seconds_left: int = 0
	var harmful: bool = true
	var compact: bool = false
	var icon: Texture2D = null

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		focus_mode = Control.FOCUS_NONE

	## Texto de los segundos que quedan (vacío en las placas).
	func get_seconds_text() -> String:
		return "" if compact or seconds_left <= 0 else str(seconds_left)

	## Texto de las acumulaciones (vacío si hay una sola).
	func get_stacks_text() -> String:
		return str(stacks) if stacks > 1 else ""

	## Color del borde: rojo si perjudica, verde si no.
	func get_border_color() -> Color:
		return HARMFUL_BORDER if harmful else BENEFICIAL_BORDER

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		if icon != null:
			draw_texture_rect(icon, rect.grow(-BORDER_WIDTH), false)
		draw_rect(rect.grow(-BORDER_WIDTH * 0.5), get_border_color(), false, BORDER_WIDTH)
		var font: Font = ThemeDB.fallback_font
		var stacks_text: String = get_stacks_text()
		if not stacks_text.is_empty():
			var origin := Vector2(0.0, size.y - 3.0)
			draw_string_outline(font, origin, stacks_text, HORIZONTAL_ALIGNMENT_RIGHT, size.x - 3.0,
					STACKS_FONT_SIZE, 3, OUTLINE_COLOR)
			draw_string(font, origin, stacks_text, HORIZONTAL_ALIGNMENT_RIGHT, size.x - 3.0,
					STACKS_FONT_SIZE, TEXT_COLOR)
		var seconds_text: String = get_seconds_text()
		if not seconds_text.is_empty():
			var below := Vector2(0.0, size.y + float(SECONDS_FONT_SIZE))
			draw_string_outline(font, below, seconds_text, HORIZONTAL_ALIGNMENT_CENTER, size.x,
					SECONDS_FONT_SIZE, 3, OUTLINE_COLOR)
			draw_string(font, below, seconds_text, HORIZONTAL_ALIGNMENT_CENTER, size.x,
					SECONDS_FONT_SIZE, TEXT_COLOR)


## Iconos como mucho (las placas, 4).
@export var max_icons: int = 8
## Iconos pequeños sin segundos (las placas).
@export var compact: bool = false
## Primero los perjudiciales (las placas); si no, en el orden en que llegaron.
@export var harmful_first: bool = false

var _icons: Array[StatusIcon] = []
var _shown: int = 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override(&"separation", 3)


## Enseña los efectos de [param tracker] que siguen vivos en [param tick] (null o ninguno: la fila se
## vacía). Devuelve cuántos iconos enseña.
func show_tracker(tracker: StatusTracker, tick: int) -> int:
	if tracker == null:
		var none: Array[StatusTracker.Entry] = []
		return show_entries(none, tick)
	return show_entries(tracker.get_active(tick, harmful_first), tick)


## Enseña [param entries] (ya en orden; como mucho [member max_icons]) contando lo que les queda contra
## [param tick]. Los que ya acabaron no salen. Devuelve cuántos iconos enseña.
func show_entries(entries: Array[StatusTracker.Entry], tick: int) -> int:
	if entries.is_empty() and _shown == 0:
		return 0
	var used: int = 0
	var rate: float = float(Engine.physics_ticks_per_second)
	for entry: StatusTracker.Entry in entries:
		if used >= max_icons:
			break
		if entry.until_tick <= tick:
			continue
		var icon: StatusIcon = _icon_at(used)
		var seconds: int = ceili(float(entry.ticks_left(tick)) / rate)
		# Solo se toca lo que cambia: con 32 placas, esto va cada fotograma.
		if icon.status_id != entry.status_id or icon.stacks != entry.stacks \
				or icon.seconds_left != seconds or icon.compact != compact or not icon.visible:
			if icon.status_id != entry.status_id or icon.icon == null:
				icon.icon = CombatIcons.status_icon(entry.status_id)
				icon.harmful = entry.is_harmful()
			icon.status_id = entry.status_id
			icon.stacks = entry.stacks
			icon.seconds_left = seconds
			icon.compact = compact
			var side: float = COMPACT_ICON_SIZE if compact else ICON_SIZE
			icon.custom_minimum_size = Vector2(side, side)
			icon.tooltip_text = _tooltip_for(entry, seconds)
			icon.visible = true
			icon.queue_redraw()
		used += 1
	for index: int in range(used, _icons.size()):
		_icons[index].visible = false
	_shown = used
	return used


## Iconos que se ven.
func get_shown_count() -> int:
	return _shown


## El icono [param index] de los que se ven (null si no hay tantos).
func get_icon(index: int) -> StatusIcon:
	return _icons[index] if index >= 0 and index < _shown else null


## Iconos creados (pool): nunca más de [member max_icons].
func get_pool_size() -> int:
	return _icons.size()


func _icon_at(index: int) -> StatusIcon:
	while _icons.size() <= index:
		var icon := StatusIcon.new()
		icon.name = "Efecto%d" % _icons.size()
		add_child(icon)
		_icons.append(icon)
	return _icons[index]


static func _tooltip_for(entry: StatusTracker.Entry, seconds: int) -> String:
	var title: String = CombatText.status_title(entry.status_id)
	if entry.stacks > 1:
		title += " ×%d" % entry.stacks
	var lines: PackedStringArray = PackedStringArray([title])
	var description: String = CombatText.status_description(entry.status_id)
	if not description.is_empty():
		lines.append(description)
	lines.append("%d s" % seconds)
	return "\n".join(lines)
