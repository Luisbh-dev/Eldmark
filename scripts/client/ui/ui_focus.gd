class_name UIFocus
extends RefCounted
## Navigable focus neighbors (UI-09): helpers so that any row, column or grid of controls (slots, window
## buttons) can be traversed with keyboard or gamepad without touching the mouse. The backlog decision is
## that gamepad support comes after launch, but that the components have it from now on so as not to
## redo all the windows.
## [br][br]
## Each function sets [member Control.focus_neighbor_left] and its siblings on the given controls with
## relative paths, so they must be called when the controls already hang from the same tree (or at least
## the same parent) and called again if they are reordered. With [param wrap] true the last one jumps to
## the first (and vice versa); with false the ends have no neighbor and focus does not leave the row.
## [br][br]
## Client only.


## Makes the controls focusable with keyboard and gamepad ([constant Control.FOCUS_ALL]).
static func make_focusable(controls: Array[Control]) -> void:
	for control: Control in controls:
		control.focus_mode = Control.FOCUS_ALL


## Links [param controls] in a row: right and left traverse the list.
static func chain_horizontal(controls: Array[Control], wrap: bool = true) -> void:
	_chain(controls, wrap, SIDE_LEFT, SIDE_RIGHT)


## Links [param controls] in a column: down and up traverse the list.
static func chain_vertical(controls: Array[Control], wrap: bool = true) -> void:
	_chain(controls, wrap, SIDE_TOP, SIDE_BOTTOM)


## Links [param controls] in a grid of [param columns] columns (in reading order, left to right and top to
## bottom). With [param wrap] the edges wrap around within their own row or column; on the last, incomplete
## row, going down from a column with no slot below leads to the top of that column.
static func grid(controls: Array[Control], columns: int, wrap: bool = true) -> void:
	if columns <= 0 or controls.is_empty():
		return
	var count: int = controls.size()
	var rows: int = ceili(float(count) / float(columns))
	for index: int in count:
		var control: Control = controls[index]
		@warning_ignore("integer_division")
		var row: int = index / columns
		var column: int = index % columns
		var row_start: int = row * columns
		var row_end: int = mini(row_start + columns, count) - 1
		var left: int = index - 1 if column > 0 else (row_end if wrap else -1)
		var right: int = index + 1 if index < row_end else (row_start if wrap else -1)
		var up: int = index - columns if row > 0 else -1
		var down: int = index + columns if index + columns < count else -1
		if wrap:
			if up < 0:
				# The last slot of this column.
				up = column + (rows - 1) * columns
				if up >= count:
					up -= columns
			if down < 0:
				down = column
		_set_neighbor(control, SIDE_LEFT, controls, left)
		_set_neighbor(control, SIDE_RIGHT, controls, right)
		_set_neighbor(control, SIDE_TOP, controls, up)
		_set_neighbor(control, SIDE_BOTTOM, controls, down)


## First visible, focusable control under [param root] (in tree order), or null.
static func find_first_focusable(root: Node) -> Control:
	for node: Node in root.find_children("*", "Control", true, false):
		var control: Control = node as Control
		if control.focus_mode == Control.FOCUS_ALL and control.is_visible_in_tree():
			return control
	return null


## Gives focus to the first focusable control under [param root]. Returns that control (null if there is
## none). Focus does not open its tooltip: it is set by code when opening a window, not by the player when
## navigating ([method UITooltip.grab_focus_silently]).
static func focus_first(root: Node) -> Control:
	var control: Control = find_first_focusable(root)
	if control != null:
		UITooltip.grab_focus_silently(control)
	return control


## The control that focus moves to from [param control] toward [param side] ([constant SIDE_LEFT],
## [constant SIDE_RIGHT], [constant SIDE_TOP] or [constant SIDE_BOTTOM]) according to the set neighbor, or
## null if it has none. It only reads the explicit neighbor, not the one the engine would find by position.
static func get_neighbor(control: Control, side: Side) -> Control:
	var path: NodePath = control.get_focus_neighbor(side)
	if path.is_empty():
		return null
	return control.get_node_or_null(path) as Control


static func _chain(controls: Array[Control], wrap: bool, previous_side: Side, next_side: Side) -> void:
	var count: int = controls.size()
	for index: int in count:
		var previous: int = index - 1 if index > 0 else (count - 1 if wrap else -1)
		var next: int = index + 1 if index < count - 1 else (0 if wrap else -1)
		_set_neighbor(controls[index], previous_side, controls, previous)
		_set_neighbor(controls[index], next_side, controls, next)


# Sets (or removes, with a negative index) the neighbor on [param side]. A control is its own neighbor
# only if it is the only one in the list, and then it is left without a neighbor.
static func _set_neighbor(control: Control, side: Side, controls: Array[Control], index: int) -> void:
	if index < 0 or index >= controls.size() or controls[index] == control:
		control.set_focus_neighbor(side, NodePath())
		return
	control.set_focus_neighbor(side, control.get_path_to(controls[index]))
