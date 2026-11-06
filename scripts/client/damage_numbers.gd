class_name DamageNumbers
extends Control
## Floating damage numbers (UI-12). They are anchored at a point in the world (the victim's head),
## projected onto the screen with the camera and rise while fading. They are only created on
## receiving the event that confirms the hit ([CombatFeedback]); numbers are never predicted.
## [br][br]
## [b]Pool.[/b] There are at most [constant MAX_NUMBERS] labels, created as needed and
## reused; if all are in use, a new number recycles the oldest.
## [br][br]
## [b]Legibility (UI-12).[/b] Each number is born shifted to one side, alternating left and right and rising one
## step more the more numbers of the same victim are still alive, so "225" and "250" are not written on top of each
## other and read as "2250". It is born 40% larger and shrinks to its size in 80 ms. The critical has its own color and size
## (lemon yellow, larger, with "!"); death, white with a warm border and the largest size; and damage
## taken, a red unlike any of the dealt-damage ones.
## [br][br]
## [b]Grouping.[/b] Hits on the same target (and in the same direction: dealt or taken) that
## arrive within the [constant GROUP_WINDOW_SECONDS] s after the first one of a number are added to it,
## instead of stacking labels: the number grows larger and its life starts over.
## [br][br]
## [b]Reserved strips (R2).[/b] A number is never drawn over the notices of the middle of the screen (the war notice
## band and the boss bar): [member reserved_provider] returns their rectangles and [method avoid_rects] moves the number
## out of them, to a side or just below, never upward so that it does not jump across the strip as it rises.
## [br][br]
## Time is driven by [method advance] ([method _process] calls it with each frame's delta).

## Number variants (the same as those of [HitMarker]).
enum Kind { HIT, HEAVY, BLOCKED, KILL, PARRY }

## Labels created at most.
const MAX_NUMBERS: int = 24
## Window (s) from the first hit of a number during which another hit is added to it.
const GROUP_WINDOW_SECONDS: float = 0.3
## Life of a number (s) and the speed at which it rises (px/s).
const LIFETIME_SECONDS: float = 0.9
const RISE_SPEED: float = 70.0
## Base font size and growth with the accumulated damage (up to [constant MAX_FONT_SIZE]).
const BASE_FONT_SIZE: int = 24
const MAX_FONT_SIZE: int = 44
const FONT_SIZE_PER_100_DAMAGE: float = 6.0
## Height (m) above the feet at which a number is anchored.
const ANCHOR_HEIGHT: float = 2.15
const OUTLINE_SIZE: int = 5
## Colors per variant of the dealt hits. Cream, gold, bluish gray, bright gold and white: none is red.
const COLORS: Dictionary[int, Color] = {
	Kind.HIT: Color(1.0, 0.95, 0.75, 1.0),
	Kind.HEAVY: Color(1.0, 0.68, 0.2, 1.0),
	Kind.BLOCKED: Color(0.65, 0.77, 0.92, 1.0),
	Kind.KILL: Color(1.0, 1.0, 1.0, 1.0),
	Kind.PARRY: Color(1.0, 0.86, 0.35, 1.0),
}
## Color of the critical hit (lemon yellow) and of the death outline (warm).
const CRITICAL_COLOR: Color = Color(1.0, 0.92, 0.2, 1.0)
const KILL_OUTLINE_COLOR: Color = Color(0.85, 0.35, 0.05, 0.95)
## Color of the damage-taken numbers (a crimson red, darker than that of blood and of death).
const TAKEN_COLOR: Color = Color(0.95, 0.22, 0.24, 1.0)
const OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)
## Lateral spread at birth (px), vertical step per live number of the same victim (px), size it
## is born with (1 = no jump) and time (s) it takes to shrink to its size.
const SPREAD_PX: float = 34.0
const STACK_STEP_PX: float = 26.0
## Distance (m) at which two numbers of different victims count as close and are stacked, and maximum steps.
const NEAR_METERS: float = 1.5
const MAX_STACK_STEPS: int = 6
## Air (px) left around a reserved strip, and the shift (px) up to which going down is preferred to going sideways.
const RESERVED_MARGIN: float = 6.0
const SIDE_STEP_LIMIT: float = 40.0
const POP_SCALE: float = 1.4
const POP_SECONDS: float = 0.08

## false: no number is shown (player option).
var enabled: bool = true:
	set(value):
		enabled = value
		if not enabled:
			clear()

## Returns the screen rectangles ([Rect2], in this control's coordinates) that numbers must not cover. Optional.
var reserved_provider: Callable = Callable()

var _camera: Camera3D = null
var _pool: Array[Label] = []
var _active: Array[_Number] = []
var _spawned_total: int = 0


## A number on screen.
class _Number:
	var label: Label = null
	var target_id: int = 0
	var taken: bool = false
	var variant: int = 0
	var critical: bool = false
	var amount: int = 0
	var world_position: Vector3 = Vector3.ZERO
	var age: float = 0.0
	var group_age: float = 0.0
	var hits: int = 1
	var text_override: String = ""
	var offset: Vector2 = Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The "Números de daño" (damage numbers) option of the player settings.
	ClientSettings.bind_visibility(self, ClientSettings.DAMAGE_NUMBERS)


func _process(delta: float) -> void:
	advance(delta)


## Camera used to project the numbers into the world.
func set_camera(camera: Camera3D) -> void:
	_camera = camera


## Shows a number of [param amount] damage at [param world_position] (the feet point of
## the victim [param target_id]; it is raised by [constant ANCHOR_HEIGHT]). If [param taken] is true it is damage
## received by the local player. If there is a number of the same target and direction that has just come out
## (less than [constant GROUP_WINDOW_SECONDS] s ago), it is added to it and no other is created. Returns the
## label, or null with [member enabled] set to false.
func add_number(target_id: int, world_position: Vector3, amount: int, variant: int = Kind.HIT,
		taken: bool = false, critical: bool = false, text_override: String = "") -> Label:
	if not enabled:
		return null
	for number: _Number in _active:
		if number.target_id == target_id and number.taken == taken \
				and number.group_age <= GROUP_WINDOW_SECONDS:
			number.amount += amount
			number.hits += 1
			number.age = 0.0
			number.world_position = world_position
			number.critical = number.critical or critical
			number.variant = maxi(number.variant, variant)
			number.text_override = text_override
			_refresh(number)
			return number.label
	var created := _Number.new()
	created.label = _take_label()
	created.target_id = target_id
	created.taken = taken
	created.variant = variant if COLORS.has(variant) else Kind.HIT
	created.critical = critical
	created.amount = amount
	created.world_position = world_position
	created.text_override = text_override
	created.offset = _spread_offset(target_id, taken, world_position)
	_active.append(created)
	_spawned_total += 1
	_refresh(created)
	_place(created)
	return created.label


## Advances [param delta] seconds: ages the numbers, raises them and returns to the pool those that finish.
func advance(delta: float) -> void:
	if _active.is_empty():
		return
	var still: Array[_Number] = []
	for number: _Number in _active:
		number.age += delta
		number.group_age += delta
		if number.age >= LIFETIME_SECONDS:
			_release(number.label)
			continue
		still.append(number)
		_place(number)
	_active = still


## Removes all the numbers (the pool's labels are kept).
func clear() -> void:
	for number: _Number in _active:
		_release(number.label)
	_active.clear()


## Numbers on screen.
func get_active_count() -> int:
	return _active.size()


## Labels created (active and free): it never exceeds [constant MAX_NUMBERS].
func get_pool_size() -> int:
	return _pool.size()


## Numbers created since the start (not counting those that were added to another).
func get_spawned_count() -> int:
	return _spawned_total


## Text of the active number [param index] (0 = the oldest).
func get_number_text(index: int) -> String:
	return _active[index].label.text if index >= 0 and index < _active.size() else ""


## Accumulated damage of the active number [param index].
func get_number_amount(index: int) -> int:
	return _active[index].amount if index >= 0 and index < _active.size() else 0


## Hits added into the active number [param index].
func get_number_hits(index: int) -> int:
	return _active[index].hits if index >= 0 and index < _active.size() else 0


## Label of the active number [param index] (or null).
func get_number_label(index: int) -> Label:
	return _active[index].label if index >= 0 and index < _active.size() else null


# Free label from the pool, or a new one if the cap has not been reached; otherwise, that of the oldest
# number, which is recycled.
func _take_label() -> Label:
	for label: Label in _pool:
		if not label.visible:
			label.visible = true
			return label
	if _pool.size() < MAX_NUMBERS:
		var created: Label = _make_label()
		_pool.append(created)
		return created
	var oldest: _Number = _active[0]
	_active.remove_at(0)
	return oldest.label


func _make_label() -> Label:
	var label := Label.new()
	label.name = "Numero%d" % _pool.size()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override(&"font_outline_color", OUTLINE_COLOR)
	label.add_theme_constant_override(&"outline_size", OUTLINE_SIZE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.pivot_offset = Vector2(40.0, 14.0)
	label.size = Vector2(80.0, 28.0)
	add_child(label)
	return label


func _release(label: Label) -> void:
	label.visible = false


# Where a number is born relative to the anchor: to one side (alternating) and one step higher for each live number of the
# same victim and direction, or of another victim less than [constant NEAR_METERS] away (they would be drawn on top of
# each other), so they do not overlap.
func _spread_offset(target_id: int, taken: bool, world_position: Vector3 = Vector3.ZERO) -> Vector2:
	var alive: int = 0
	for number: _Number in _active:
		if ((number.target_id == target_id and number.taken == taken)
				or number.world_position.distance_to(world_position) < NEAR_METERS):
			alive += 1
	var side: float = -1.0 if (_spawned_total % 2) == 0 else 1.0
	return Vector2(side * SPREAD_PX * (0.6 + 0.4 * float(alive % 3 + 1) / 3.0),
			-STACK_STEP_PX * float(mini(alive, MAX_STACK_STEPS)))


## Birth offset of the active number [param index] (for tests).
func get_number_offset(index: int) -> Vector2:
	return _active[index].offset if index >= 0 and index < _active.size() else Vector2.ZERO


# Text, size and color according to the accumulated damage and the variant.
func _refresh(number: _Number) -> void:
	var label: Label = number.label
	var text: String = number.text_override
	if text.is_empty():
		text = str(number.amount)
		if number.critical:
			text += "!"
	label.text = text
	var font_size: int = clampi(roundi(BASE_FONT_SIZE + FONT_SIZE_PER_100_DAMAGE
			* float(number.amount) / 100.0), BASE_FONT_SIZE, MAX_FONT_SIZE)
	if number.variant == Kind.HEAVY or number.critical:
		font_size = mini(font_size + 4, MAX_FONT_SIZE)
	var color: Color = TAKEN_COLOR if number.taken else COLORS[number.variant]
	if number.critical and not number.taken and number.variant != Kind.KILL:
		color = CRITICAL_COLOR
		font_size = mini(font_size + 4, MAX_FONT_SIZE + 4)
	if number.variant == Kind.KILL and not number.taken:
		font_size = MAX_FONT_SIZE
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_outline_color",
			KILL_OUTLINE_COLOR if number.variant == Kind.KILL and not number.taken else OUTLINE_COLOR)
	label.modulate.a = 1.0


# Places the label on screen: projects the anchor, raises it with age and fades it at the end.
func _place(number: _Number) -> void:
	var label: Label = number.label
	var fade: float = 1.0 - smoothstep(0.55, 1.0, number.age / LIFETIME_SECONDS)
	label.modulate.a = fade
	var anchor: Vector3 = number.world_position + Vector3(0.0, ANCHOR_HEIGHT, 0.0)
	var screen: Vector2 = size * 0.5
	if is_instance_valid(_camera) and _camera.is_inside_tree():
		if _camera.is_position_behind(anchor):
			label.modulate.a = 0.0
			return
		screen = _camera.unproject_position(anchor)
	screen.y -= number.age * RISE_SPEED
	var pop: float = lerpf(POP_SCALE, 1.0, clampf(number.age / POP_SECONDS, 0.0, 1.0))
	label.scale = Vector2.ONE * pop
	if reserved_provider.is_valid():
		# The stack is resolved after the avoidance, from the anchor: a displaced group keeps its spacing.
		var text_size: Vector2 = label.get_minimum_size() * pop
		var base := Rect2(screen + Vector2(number.offset.x, 0.0) - text_size * 0.5, text_size)
		var placed: Rect2 = place_stacked(base, -number.offset.y, reserved_provider.call() as Array)
		label.position = placed.position + text_size * 0.5 - label.size * 0.5
	else:
		screen += number.offset
		label.position = screen - label.size * 0.5


## Places [param base] (a number without its stack offset) out of the [param reserved] rectangles and then stacks it
## [param stack_px] away from the anchor. The stack grows upward, or downward when the number was pushed down under a
## strip, so the numbers of one target keep their spacing instead of piling on the strip's lower edge.
static func place_stacked(base: Rect2, stack_px: float, reserved: Array) -> Rect2:
	var moved: Rect2 = avoid_rects(base, reserved)
	var direction: float = 1.0 if moved.position.y > base.position.y + 0.5 else -1.0
	moved.position.y += direction * stack_px
	return avoid_rects(moved, reserved) if direction < 0.0 else moved


## Moves [param rect] (the text of a number) out of the [param reserved] rectangles it overlaps (with
## [constant RESERVED_MARGIN] px of air): the nearest of left, right and down. Never up: a number rises, and choosing
## "up" would make it jump across the strip. A rectangle that overlaps nothing is returned as it is.
static func avoid_rects(rect: Rect2, reserved: Array) -> Rect2:
	var moved: Rect2 = rect
	for entry: Variant in reserved:
		var strip: Rect2 = (entry as Rect2).grow(RESERVED_MARGIN)
		if not strip.intersects(moved):
			continue
		var to_left: float = moved.end.x - strip.position.x
		var to_right: float = strip.end.x - moved.position.x
		var to_down: float = strip.end.y - moved.position.y
		if to_down <= minf(to_left, to_right) or to_down <= SIDE_STEP_LIMIT:
			moved.position.y += to_down
		elif to_left <= to_right:
			moved.position.x -= to_left
		else:
			moved.position.x += to_right
	return moved
