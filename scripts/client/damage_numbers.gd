class_name DamageNumbers
extends Control
## Números de daño flotantes (UI-12). Se anclan en un punto del mundo (la cabeza de la víctima),
## se proyectan a la pantalla con la cámara y suben mientras se desvanecen. Solo se crean al
## recibir el evento que confirma el golpe ([CombatFeedback]); los números nunca se predicen.
## [br][br]
## [b]Pool.[/b] Hay como mucho [constant MAX_NUMBERS] etiquetas, que se crean al hacer falta y se
## reutilizan; si están todas en uso, un número nuevo recicla la más antigua.
## [br][br]
## [b]Agrupación.[/b] Los golpes sobre el mismo objetivo (y del mismo sentido: dados o recibidos) que
## llegan en los [constant GROUP_WINDOW_SECONDS] s siguientes al primero de un número se suman en él,
## en lugar de apilar etiquetas: el número se hace más grande y su vida vuelve a empezar.
## [br][br]
## El tiempo lo lleva [method advance] ([method _process] lo llama con el delta de cada fotograma).

## Variantes de los números (las mismas que las de [HitMarker]).
enum Kind { HIT, HEAVY, BLOCKED, KILL }

## Etiquetas que se crean como mucho.
const MAX_NUMBERS: int = 24
## Ventana (s) desde el primer golpe de un número en la que otro golpe se suma a él.
const GROUP_WINDOW_SECONDS: float = 0.3
## Vida de un número (s) y velocidad con la que sube (px/s).
const LIFETIME_SECONDS: float = 0.9
const RISE_SPEED: float = 70.0
## Tamaño de letra base y crecimiento con el daño acumulado (hasta [constant MAX_FONT_SIZE]).
const BASE_FONT_SIZE: int = 22
const MAX_FONT_SIZE: int = 40
const FONT_SIZE_PER_100_DAMAGE: float = 6.0
## Altura (m) sobre los pies a la que se ancla un número.
const ANCHOR_HEIGHT: float = 2.15
const OUTLINE_SIZE: int = 5
## Colores por variante de los golpes dados.
const COLORS: Dictionary[int, Color] = {
	Kind.HIT: Color(1.0, 0.95, 0.75, 1.0),
	Kind.HEAVY: Color(1.0, 0.68, 0.2, 1.0),
	Kind.BLOCKED: Color(0.65, 0.77, 0.92, 1.0),
	Kind.KILL: Color(1.0, 0.3, 0.25, 1.0),
}
## Color de los números de daño recibido.
const TAKEN_COLOR: Color = Color(1.0, 0.28, 0.28, 1.0)
const OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)

## false: no se muestra ningún número (opción del jugador).
var enabled: bool = true:
	set(value):
		enabled = value
		if not enabled:
			clear()

var _camera: Camera3D = null
var _pool: Array[Label] = []
var _active: Array[_Number] = []
var _spawned_total: int = 0


## Un número en pantalla.
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


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Opción «Números de daño» de los ajustes del jugador.
	ClientSettings.bind_visibility(self, ClientSettings.DAMAGE_NUMBERS)


func _process(delta: float) -> void:
	advance(delta)


## Cámara con la que se proyectan los números al mundo.
func set_camera(camera: Camera3D) -> void:
	_camera = camera


## Enseña un número de [param amount] de daño sobre [param world_position] (el punto de los pies de
## la víctima [param target_id]; se sube [constant ANCHOR_HEIGHT]). Si [param taken] es true es daño
## que recibe el jugador local. Si hay un número del mismo objetivo y sentido que acaba de salir
## (menos de [constant GROUP_WINDOW_SECONDS] s), se suma a él y no se crea otro. Devuelve la
## etiqueta, o null con [member enabled] a false.
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
	_active.append(created)
	_spawned_total += 1
	_refresh(created)
	_place(created)
	return created.label


## Avanza [param delta] segundos: envejece los números, los sube y devuelve al pool los que acaban.
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


## Quita todos los números (se conservan las etiquetas del pool).
func clear() -> void:
	for number: _Number in _active:
		_release(number.label)
	_active.clear()


## Números en pantalla.
func get_active_count() -> int:
	return _active.size()


## Etiquetas creadas (activas y libres): nunca pasa de [constant MAX_NUMBERS].
func get_pool_size() -> int:
	return _pool.size()


## Números creados desde el principio (sin contar los que se sumaron a otro).
func get_spawned_count() -> int:
	return _spawned_total


## Texto del número activo [param index] (0 = el más antiguo).
func get_number_text(index: int) -> String:
	return _active[index].label.text if index >= 0 and index < _active.size() else ""


## Daño acumulado del número activo [param index].
func get_number_amount(index: int) -> int:
	return _active[index].amount if index >= 0 and index < _active.size() else 0


## Golpes sumados en el número activo [param index].
func get_number_hits(index: int) -> int:
	return _active[index].hits if index >= 0 and index < _active.size() else 0


## Etiqueta del número activo [param index] (o null).
func get_number_label(index: int) -> Label:
	return _active[index].label if index >= 0 and index < _active.size() else null


# Etiqueta libre del pool, o una nueva si no se ha llegado al tope; si no, la del número más
# antiguo, que se recicla.
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


# Texto, tamaño y color según el daño acumulado y la variante.
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
	label.add_theme_font_size_override(&"font_size", font_size)
	var color: Color = TAKEN_COLOR if number.taken else COLORS[number.variant]
	label.add_theme_color_override(&"font_color", color)
	label.modulate.a = 1.0


# Coloca la etiqueta en la pantalla: proyecta el ancla, la sube con la edad y la desvanece al final.
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
	label.position = screen - label.size * 0.5
