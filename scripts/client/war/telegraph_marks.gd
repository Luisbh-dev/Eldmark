class_name TelegraphMarks
extends Node3D
## Marcas en el suelo de los ataques de los PNJ (UI-18, GUE: TELEGRAPH de docs/fuerte.md sección 5). El
## servidor avisa unos ticks antes del golpe ([signal NetClient.telegraph_received]: forma, origen,
## orientación, radio y ticks hasta el impacto) y aquí se dibuja la zona de peligro sobre el suelo:
## un círculo o un sector rojo translúcido, con un relleno más intenso que crece desde el centro hasta
## llenarla justo en el impacto, y que desaparece enseguida después.
## [br][br]
## [b]Provisional.[/b] Es una malla plana sin sombreado, a [constant LIFT] m del origen que manda el
## servidor (los pies del PNJ): sobre terreno inclinado se hunde o flota. Un [Decal] proyectado seguiría
## el relieve, pero depende del renderizador; queda para el arte (ART-17). El ángulo del sector sale del
## ataque del catálogo de combate ([member HitShape.angle_deg]) y, si no se conoce, es
## [constant DEFAULT_SECTOR_DEGREES].
## [br][br]
## El tiempo lo lleva [method advance] (en [method _process], con el delta de cada fotograma). Solo
## cliente.

## Altura sobre el origen (m) y vértices por vuelta de la malla.
const LIFT: float = 0.06
const SEGMENTS: int = 40
## Ángulo (grados) de un sector cuyo ataque no está en el catálogo.
const DEFAULT_SECTOR_DEGREES: float = 100.0
## Segundos que se queda la marca tras el impacto.
const TAIL_SECONDS: float = 0.35
## Marcas a la vez como mucho (al llegar otra de más, se quita la más antigua).
const MAX_MARKS: int = 24
const BASE_COLOR: Color = Color(0.9, 0.18, 0.12, 0.28)
const FILL_COLOR: Color = Color(0.95, 0.2, 0.1, 0.5)

class Mark extends RefCounted:
	var node: Node3D = null
	var fill: MeshInstance3D = null
	var age: float = 0.0
	var impact_seconds: float = 0.0
	var npc_id: int = 0

var _marks: Array[Mark] = []
var _client: NetClient = null
var _base_material: StandardMaterial3D = null
var _fill_material: StandardMaterial3D = null
var _added: int = 0


func _init() -> void:
	name = "TelegraphMarks"
	# Las marcas se colocan en el mundo con global_position; el propio nodo no se mueve.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func _process(delta: float) -> void:
	advance(delta)


func _exit_tree() -> void:
	if is_instance_valid(_client) and _client.telegraph_received.is_connected(add_telegraph):
		_client.telegraph_received.disconnect(add_telegraph)


## Escucha los TELEGRAPH de [param client].
func bind(client: NetClient) -> void:
	if is_instance_valid(_client) and _client.telegraph_received.is_connected(add_telegraph):
		_client.telegraph_received.disconnect(add_telegraph)
	_client = client
	if is_instance_valid(_client):
		_client.telegraph_received.connect(add_telegraph)


## Dibuja la zona de peligro de un TELEGRAPH. Una forma desconocida o un radio de 0 no dibuja nada.
## Devuelve true si se ha creado la marca.
func add_telegraph(event: NetMessages.EntityEvent) -> bool:
	if event == null or event.event != NetMessages.EntityEvent.Kind.TELEGRAPH or event.radius_cm <= 0:
		return false
	var angle: float = TAU
	if event.shape == NetMessages.EntityEvent.SHAPE_SECTOR:
		angle = deg_to_rad(sector_degrees(event.attack_id))
	elif event.shape != NetMessages.EntityEvent.SHAPE_CIRCLE:
		return false
	while _marks.size() >= MAX_MARKS:
		_remove(0)
	var radius: float = event.get_radius()
	var mark := Mark.new()
	mark.npc_id = event.net_id
	mark.impact_seconds = float(maxi(event.impact_in_ticks, 0)) / float(Engine.physics_ticks_per_second)
	var root := Node3D.new()
	root.name = "Marca%d" % _added
	var base := MeshInstance3D.new()
	base.name = "Zona"
	base.mesh = build_mesh(radius, angle, SEGMENTS)
	base.material_override = _get_base_material()
	base.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(base)
	var fill := MeshInstance3D.new()
	fill.name = "Relleno"
	fill.mesh = base.mesh
	fill.material_override = _get_fill_material()
	fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fill.position.y = 0.01
	root.add_child(fill)
	mark.node = root
	mark.fill = fill
	add_child(root)
	var origin: Vector3 = event.position + Vector3(0.0, LIFT, 0.0)
	if root.is_inside_tree():
		root.global_position = origin
	else:
		root.position = origin
	root.rotation = Vector3(0.0, event.yaw, 0.0)
	_set_fill_scale(mark, 0.0)
	_marks.append(mark)
	_added += 1
	return true


## Avanza [param delta] segundos: crece el relleno y se quitan las marcas que acaban.
func advance(delta: float) -> void:
	var index: int = _marks.size() - 1
	while index >= 0:
		var mark: Mark = _marks[index]
		mark.age += delta
		if mark.age >= mark.impact_seconds + TAIL_SECONDS:
			_remove(index)
		else:
			_set_fill_scale(mark, fill_progress(mark.age, mark.impact_seconds))
		index -= 1


## Fracción (0 a 1) que lleva el relleno de una marca con [param age] s de edad y [param impact_seconds]
## hasta el impacto: crece linealmente y se queda llena.
static func fill_progress(age: float, impact_seconds: float) -> float:
	if impact_seconds <= 0.0:
		return 1.0
	return clampf(age / impact_seconds, 0.0, 1.0)


## Ángulo total (grados) del sector del ataque [param attack_id] del catálogo de combate, o
## [constant DEFAULT_SECTOR_DEGREES] si no se conoce.
static func sector_degrees(attack_id: int) -> float:
	var attack: AttackTicks = CombatCatalog.attack(attack_id)
	if attack != null and attack.shape != null and attack.shape.angle_deg > 0.0:
		return attack.shape.angle_deg
	return DEFAULT_SECTOR_DEGREES


## Malla plana (y = 0) de un círculo o sector de [param radius] m y [param angle] rad (TAU = círculo
## entero), centrado en el eje -Z (el «delante» del PNJ con yaw 0), con [param segments] vértices por
## vuelta completa. Es un abanico de triángulos desde el origen.
static func build_mesh(radius: float, angle: float, segments: int) -> ArrayMesh:
	var steps: int = maxi(ceili(float(segments) * minf(angle, TAU) / TAU), 1)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	vertices.append(Vector3.ZERO)
	normals.append(Vector3.UP)
	var start: float = -angle * 0.5
	for i: int in steps + 1:
		var direction: float = start + angle * float(i) / float(steps)
		vertices.append(Vector3(sin(direction) * radius, 0.0, -cos(direction) * radius))
		normals.append(Vector3.UP)
	for i: int in steps:
		# Sentido horario visto desde arriba: la cara visible mira a +Y.
		indices.append(0)
		indices.append(i + 2)
		indices.append(i + 1)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Marcas que se ven ahora.
func get_mark_count() -> int:
	return _marks.size()


## Marcas creadas desde que existe.
func get_added_count() -> int:
	return _added


## Id de red del PNJ de la marca [param index] (0 si no existe).
func get_mark_npc(index: int) -> int:
	return _marks[index].npc_id if index >= 0 and index < _marks.size() else 0


## Nodo de la marca [param index] (null si no existe).
func get_mark_node(index: int) -> Node3D:
	return _marks[index].node if index >= 0 and index < _marks.size() else null


## Fracción de relleno de la marca [param index] (0 a 1).
func get_mark_fill(index: int) -> float:
	if index < 0 or index >= _marks.size():
		return 0.0
	return _marks[index].fill.scale.x


func clear() -> void:
	while not _marks.is_empty():
		_remove(0)


func _set_fill_scale(mark: Mark, fraction: float) -> void:
	var scale_value: float = maxf(fraction, 0.001)
	mark.fill.scale = Vector3(scale_value, 1.0, scale_value)


func _remove(index: int) -> void:
	var mark: Mark = _marks[index]
	_marks.remove_at(index)
	if is_instance_valid(mark.node):
		mark.node.get_parent().remove_child(mark.node)
		mark.node.free()


func _get_base_material() -> StandardMaterial3D:
	if _base_material == null:
		_base_material = _make_material(BASE_COLOR)
	return _base_material


func _get_fill_material() -> StandardMaterial3D:
	if _fill_material == null:
		_fill_material = _make_material(FILL_COLOR)
	return _fill_material


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	material.disable_receive_shadows = true
	return material
