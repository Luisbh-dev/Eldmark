class_name StatusIcons
extends HBoxContainer
## Row of status effect icons (UI-45, docs/abilities.md, section 6.4): the player's own, above the
## health bar, and the small one on nameplates (up to 4, harmful ones first). Each icon
## shows the effect (provisional square with its initial, [CombatIcons]), the seconds remaining, the
## stacks if there is more than one and a red border if it is harmful or green if not; the tooltip gives its name and
## what it does.
## [br][br]
## It does not read the network: whoever owns it passes it the effects of a [StatusTracker] with [method show_entries] and the
## tick to count the remaining time against (the estimated server tick for the local player; the draw tick on
## nameplates). An effect that has already ended at that tick is not shown. Icons are reused (pool). Client
## only.

## Side (px) of each icon in the player's own row and in the nameplates' row.
const ICON_SIZE: float = 30.0
const COMPACT_ICON_SIZE: float = 18.0
const BORDER_WIDTH: float = 2.0
## Pixels left for the drawing inside the border (the small variants of [CombatIcons]).
const NORMAL_PIXELS: int = 26
const COMPACT_PIXELS: int = 14
const HARMFUL_BORDER: Color = Color(0.92, 0.22, 0.18, 1.0)
const BENEFICIAL_BORDER: Color = Color(0.35, 0.85, 0.4, 1.0)
const TEXT_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)
const SECONDS_FONT_SIZE: int = 12
const STACKS_FONT_SIZE: int = 12


## An effect icon (it draws itself; its [member Control.tooltip_text] is the effect's).
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

	## Text of the seconds remaining (empty on nameplates).
	func get_seconds_text() -> String:
		return "" if compact or seconds_left <= 0 else str(seconds_left)

	## Text of the stacks (empty if there is only one).
	func get_stacks_text() -> String:
		return str(stacks) if stacks > 1 else ""

	## Border color: red if harmful, green if not.
	func get_border_color() -> Color:
		return HARMFUL_BORDER if harmful else BENEFICIAL_BORDER

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		if icon != null:
			draw_texture_rect(icon, rect.grow(-BORDER_WIDTH), false)
		draw_rect(rect.grow(-BORDER_WIDTH * 0.5), get_border_color(), false, BORDER_WIDTH)
		var font: Font = UIFonts.body_semibold()
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


## At most this many icons (nameplates, 4).
@export var max_icons: int = 8
## Small icons without seconds (nameplates).
@export var compact: bool = false
## Harmful ones first (nameplates); otherwise in the order they arrived.
@export var harmful_first: bool = false

var _icons: Array[StatusIcon] = []
var _shown: int = 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override(&"separation", 3)


## Shows the effects of [param tracker] that are still alive at [param tick] (null or none: the row is
## emptied). Returns how many icons it shows.
func show_tracker(tracker: StatusTracker, tick: int) -> int:
	if tracker == null:
		var none: Array[StatusTracker.Entry] = []
		return show_entries(none, tick)
	return show_entries(tracker.get_active(tick, harmful_first), tick)


## Shows [param entries] (already in order; at most [member max_icons]) counting what remains of them against
## [param tick]. Those that have already ended are not shown. Returns how many icons it shows.
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
		# Only what changes is touched: with 32 plates, this runs every frame.
		if icon.status_id != entry.status_id or icon.stacks != entry.stacks \
				or icon.seconds_left != seconds or icon.compact != compact or not icon.visible:
			# The small variant of each status is drawn to the exact size of the icon.
			icon.icon = CombatIcons.status_icon(entry.status_id,
					COMPACT_PIXELS if compact else NORMAL_PIXELS)
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


## Icons that are visible.
func get_shown_count() -> int:
	return _shown


## Icon [param index] of those that are visible (null if there are not that many).
func get_icon(index: int) -> StatusIcon:
	return _icons[index] if index >= 0 and index < _shown else null


## Icons created (pool): never more than [member max_icons].
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
