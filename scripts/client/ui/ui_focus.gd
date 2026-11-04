class_name UIFocus
extends RefCounted
## Vecinos de foco navegables (UI-09): ayudas para que cualquier fila, columna o cuadrícula de
## controles (casillas, botones de una ventana) se pueda recorrer con teclado o mando sin tocar el
## ratón. La decisión del backlog es que el soporte de mando llegue después del lanzamiento, pero que
## los componentes lo tengan desde ahora para no rehacer todas las ventanas.
## [br][br]
## Cada función fija [member Control.focus_neighbor_left] y compañía de los controles dados con rutas
## relativas, así que hay que llamarlas cuando ya cuelgan del mismo árbol (o al menos del mismo
## padre) y volver a llamarlas si se reordenan. Con [param wrap] a true el último salta al primero
## (y al revés); con false los extremos no tienen vecino y el foco no sale de la fila.
## [br][br]
## Solo cliente.


## Hace los controles enfocables con teclado y mando ([constant Control.FOCUS_ALL]).
static func make_focusable(controls: Array[Control]) -> void:
	for control: Control in controls:
		control.focus_mode = Control.FOCUS_ALL


## Enlaza [param controls] en una fila: derecha e izquierda recorren la lista.
static func chain_horizontal(controls: Array[Control], wrap: bool = true) -> void:
	_chain(controls, wrap, SIDE_LEFT, SIDE_RIGHT)


## Enlaza [param controls] en una columna: abajo y arriba recorren la lista.
static func chain_vertical(controls: Array[Control], wrap: bool = true) -> void:
	_chain(controls, wrap, SIDE_TOP, SIDE_BOTTOM)


## Enlaza [param controls] en una cuadrícula de [param columns] columnas (en orden de lectura, de
## izquierda a derecha y de arriba abajo). Con [param wrap] los bordes dan la vuelta por su misma
## fila o columna; en la última fila incompleta, bajar desde una columna sin casilla debajo lleva al
## principio de esa columna.
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
				# La última casilla de esta columna.
				up = column + (rows - 1) * columns
				if up >= count:
					up -= columns
			if down < 0:
				down = column
		_set_neighbor(control, SIDE_LEFT, controls, left)
		_set_neighbor(control, SIDE_RIGHT, controls, right)
		_set_neighbor(control, SIDE_TOP, controls, up)
		_set_neighbor(control, SIDE_BOTTOM, controls, down)


## Primer control visible y enfocable bajo [param root] (en orden de árbol), o null.
static func find_first_focusable(root: Node) -> Control:
	for node: Node in root.find_children("*", "Control", true, false):
		var control: Control = node as Control
		if control.focus_mode == Control.FOCUS_ALL and control.is_visible_in_tree():
			return control
	return null


## Da el foco al primer control enfocable bajo [param root]. Devuelve ese control (null si no hay). El foco no abre su
## tooltip: lo pone el código al abrir una ventana, no el jugador al navegar ([method UITooltip.grab_focus_silently]).
static func focus_first(root: Node) -> Control:
	var control: Control = find_first_focusable(root)
	if control != null:
		UITooltip.grab_focus_silently(control)
	return control


## El control al que lleva el foco desde [param control] hacia [param side] ([constant SIDE_LEFT],
## [constant SIDE_RIGHT], [constant SIDE_TOP] o [constant SIDE_BOTTOM]) según el vecino fijado, o
## null si no tiene. Solo lee el vecino explícito, no el que el motor buscaría por posición.
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


# Fija (o quita, con un índice negativo) el vecino de [param side]. Un control es vecino de sí mismo
# solo si es el único de la lista, y entonces se deja sin vecino.
static func _set_neighbor(control: Control, side: Side, controls: Array[Control], index: int) -> void:
	if index < 0 or index >= controls.size() or controls[index] == control:
		control.set_focus_neighbor(side, NodePath())
		return
	control.set_focus_neighbor(side, control.get_path_to(controls[index]))
