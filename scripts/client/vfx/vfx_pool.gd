class_name VfxPool
extends Node3D
## Grupo de reutilización de un [VfxEffect] (ART-09, solo cliente): crea [member size] copias de
## [member scene] una sola vez y las va relanzando. [method spawn] no instancia nada: toma una copia
## libre y la pone en el punto de contacto; si todas suenan, reinicia la más antigua en vez de crecer.
## [br][br]
## Un grupo por escena (chispa de metal, polvo...) y a tamaño suficiente para los golpes que caben en
## un instante de combate: 6 a 8 para los impactos, 2 a 3 para las paradas.

## Escena del efecto: la raíz tiene que ser un [VfxEffect].
@export var scene: PackedScene
## Copias que se crean.
@export_range(1, 64) var size: int = 6

var _items: Array[VfxEffect] = []
var _cursor: int = 0
# Tinte pedido con [method set_tint]; sin él, cada copia conserva el de su escena (la carne es roja).
var _tint: Color = Color.WHITE
var _has_tint: bool = false


func _ready() -> void:
	if scene != null and _items.is_empty():
		_fill()


## Crea las copias ahora (si el grupo se arma por código antes de entrar en el árbol).
func setup(effect_scene: PackedScene, copies: int) -> void:
	scene = effect_scene
	size = maxi(copies, 1)
	if _items.is_empty():
		_fill()


## Lanza una copia libre en [param position] con su eje +Z en [param normal] (ver
## [method VfxEffect.play_at]) y la devuelve. Devuelve null si el grupo no tiene escena.
func spawn(position: Vector3, normal: Vector3 = Vector3.UP) -> VfxEffect:
	var effect: VfxEffect = acquire()
	if effect == null:
		return null
	effect.play_at(position, normal)
	return effect


## Toma una copia libre SIN lanzarla (la más antigua si todas suenan), para efectos con su propia forma de
## lanzarse, como [method DustKick.play_dodge].
func acquire() -> VfxEffect:
	if _items.is_empty():
		if scene == null:
			return null
		_fill()
		if _items.is_empty():
			return null
	for offset: int in _items.size():
		var index: int = (_cursor + offset) % _items.size()
		if not _items[index].is_playing():
			_cursor = index + 1
			return _items[index]
	# Todas suenan: se reinicia la que lleva más tiempo (la siguiente del anillo).
	var oldest: VfxEffect = _items[_cursor % _items.size()]
	_cursor += 1
	oldest.reset()
	return oldest


## Tiñe todas las copias, también las que se creen después (los siguientes disparos salen de ese color).
func set_tint(value: Color) -> void:
	_tint = value
	_has_tint = true
	for item: VfxEffect in _items:
		item.tint = value


## Cuántas copias están sonando ahora.
func get_active_count() -> int:
	var active: int = 0
	for item: VfxEffect in _items:
		if item.is_playing():
			active += 1
	return active


## Apaga todas las copias de golpe.
func release_all() -> void:
	for item: VfxEffect in _items:
		item.reset()


func get_items() -> Array[VfxEffect]:
	return _items


func _fill() -> void:
	for index: int in size:
		var item: VfxEffect = scene.instantiate() as VfxEffect
		if item == null:
			push_error("[VfxPool] La escena %s no tiene un VfxEffect en la raíz" % scene.resource_path)
			return
		if _has_tint:
			item.tint = _tint
		add_child(item)
		_items.append(item)
