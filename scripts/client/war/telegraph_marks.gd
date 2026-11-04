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
## [b]Reloj.[/b] El golpe cae en el tick del aviso más [code]impact_in_ticks[/code] (la carga) y lo esquiva la
## entrada del jugador para ese tick, que el cliente genera con su tick predicho; cuando llega el aviso, ese reloj ya
## va un RTT y el margen de [TickSync] por delante. Por eso la marca se llena con el tiempo predicho local
## ([method ClientPrediction.get_predicted_tick] menos uno más la fracción del tick, el instante en que el jugador ve
## su personaje, como [ProjectileWorld]): al llegar ya va por esa parte, está llena justo en el último tick en que
## salir aún evita el golpe y se quita cuando acaba la ventana activa del golpe ([member AttackTicks.active_ticks]).
## Un aviso que llega con su golpe ya pasado no se dibuja. Sin predicción en marcha (pruebas, espectador), cuenta el
## tiempo desde que llegó, con el delta de cada fotograma ([method advance]), y se quita
## [constant TAIL_SECONDS] s después del impacto (revisión de la fase 4, cliente).
## [br][br]
## [b]Solo lo que te puede dañar.[/b] El servidor avisa los golpes fuertes de todos los PNJ, también los de la
## guarnición y el capitán del reino dueño del fuerte; al defensor de ese reino no se le dibujan ([method threatens]:
## la regla de [FactionRules], la misma de los bots). Solo cliente.

## Altura sobre el origen (m) y vértices por vuelta de la malla.
const LIFT: float = 0.06
const SEGMENTS: int = 40
## Ángulo (grados) de un sector cuyo ataque no está en el catálogo.
const DEFAULT_SECTOR_DEGREES: float = 100.0
## Segundos que se queda la marca tras el impacto sin reloj predicho.
const TAIL_SECONDS: float = 0.35
## Ticks que sigue activo un golpe cuyo ataque no está en el catálogo (con reloj predicho).
const DEFAULT_ACTIVE_TICKS: int = 12
## Marcas a la vez como mucho (al llegar otra de más, se quita la más antigua).
const MAX_MARKS: int = 24
## Ámbar de [UIPalette.TELEGRAPH]: el color exclusivo del peligro de los PNJ, distinto del rojo del daño (UI-50).
const BASE_COLOR: Color = Color(UIPalette.TELEGRAPH.r, UIPalette.TELEGRAPH.g, UIPalette.TELEGRAPH.b, 0.26)
const FILL_COLOR: Color = Color(UIPalette.TELEGRAPH.r, UIPalette.TELEGRAPH.g, UIPalette.TELEGRAPH.b, 0.5)
const EDGE_COLOR: Color = Color(UIPalette.TELEGRAPH_EDGE.r, UIPalette.TELEGRAPH_EDGE.g,
		UIPalette.TELEGRAPH_EDGE.b, 0.92)

class Mark extends RefCounted:
	var node: Node3D = null
	var fill: MeshInstance3D = null
	var age: float = 0.0
	var impact_seconds: float = 0.0
	var npc_id: int = 0
	## Tick del servidor del aviso, ticks hasta el impacto y ticks que sigue activo el golpe tras él.
	var event_tick: int = 0
	var impact_ticks: int = 0
	var active_ticks: int = 0

## Reloj predicho local ([code]() -> float[/code], en ticks con fracción; negativo = sin reloj). Sin él, el del
## cliente enlazado. Es para las pruebas.
var clock: Callable = Callable()

var _marks: Array[Mark] = []
var _client: NetClient = null
var _base_material: StandardMaterial3D = null
var _fill_material: StandardMaterial3D = null
var _edge_material: StandardMaterial3D = null
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


## true si el PNJ [param npc_id] del aviso puede dañar al jugador de [param client]: [method FactionRules.can_damage]
## con el reino de su vista en el [RemoteWorld], el del jugador y la zona del WELCOME. Sin cliente, sin reino propio o
## sin el alta del PNJ (no se sabe de quién es), true: ante la duda, la marca se dibuja.
static func threatens(client: NetClient, npc_id: int) -> bool:
	if not is_instance_valid(client) or client.get_config() == null or client.get_remote_world() == null:
		return true
	var view: RemotePlayerView = client.get_remote_world().get_view(npc_id)
	if view == null:
		return true
	var welcome: NetMessages.Welcome = client.get_welcome()
	var zone_id: StringName = StringName(welcome.zone_id) if welcome != null else &""
	return FactionRules.can_damage(view.get_realm(), client.get_config().realm, zone_id)


## Dibuja la zona de peligro de un TELEGRAPH. Una forma desconocida, un radio de 0, el golpe de quien no puede dañar al
## jugador ([method threatens]) o uno que ya ha pasado no dibujan nada. Devuelve true si se ha creado la marca.
func add_telegraph(event: NetMessages.EntityEvent) -> bool:
	if event == null or event.event != NetMessages.EntityEvent.Kind.TELEGRAPH or event.radius_cm <= 0:
		return false
	var angle: float = TAU
	if event.shape == NetMessages.EntityEvent.SHAPE_SECTOR:
		angle = deg_to_rad(sector_degrees(event.attack_id))
	elif event.shape != NetMessages.EntityEvent.SHAPE_CIRCLE:
		return false
	if is_instance_valid(_client) and not threatens(_client, event.net_id):
		return false
	var mark := Mark.new()
	mark.npc_id = event.net_id
	mark.event_tick = event.tick
	mark.impact_ticks = maxi(event.impact_in_ticks, 0)
	mark.active_ticks = active_ticks_of(event.attack_id)
	mark.impact_seconds = float(mark.impact_ticks) / float(Engine.physics_ticks_per_second)
	var now: float = get_clock_time()
	if now >= 0.0 and _is_over(mark, now):
		return false
	while _marks.size() >= MAX_MARKS:
		_remove(0)
	var radius: float = event.get_radius()
	var root := Node3D.new()
	root.name = "Marca%d" % _added
	var base := MeshInstance3D.new()
	base.name = "Zona"
	base.mesh = build_mesh(radius, angle, SEGMENTS)
	base.material_override = _get_base_material()
	base.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(base)
	var edge := MeshInstance3D.new()
	edge.name = "Borde"
	edge.mesh = build_edge_mesh(radius, angle, SEGMENTS)
	edge.material_override = _get_edge_material()
	edge.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	edge.position.y = 0.02
	root.add_child(edge)
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
	_set_fill_scale(mark, _progress_of(mark, now))
	_marks.append(mark)
	_added += 1
	return true


## Avanza [param delta] segundos: crece el relleno y se quitan las marcas que acaban. Con reloj predicho manda él (el
## delta solo cuenta sin reloj).
func advance(delta: float) -> void:
	var now: float = get_clock_time()
	var index: int = _marks.size() - 1
	while index >= 0:
		var mark: Mark = _marks[index]
		mark.age += delta
		if _is_over(mark, now):
			_remove(index)
		else:
			_set_fill_scale(mark, _progress_of(mark, now))
		index -= 1


## Instante del reloj predicho local en ticks con fracción ([member clock] o el de la predicción del cliente), o -1
## si no hay ninguno en marcha.
func get_clock_time() -> float:
	if clock.is_valid():
		return float(clock.call())
	if not is_instance_valid(_client):
		return -1.0
	var prediction: ClientPrediction = _client.get_prediction()
	if prediction == null or not prediction.is_started():
		return -1.0
	return float(prediction.get_predicted_tick() - 1) + Engine.get_physics_interpolation_fraction()


## Ticks que sigue activo tras el impacto el golpe del ataque [param attack_id] del catálogo
## ([constant DEFAULT_ACTIVE_TICKS] si no se conoce).
static func active_ticks_of(attack_id: int) -> int:
	var attack: AttackTicks = CombatCatalog.attack(attack_id)
	return attack.active_ticks if attack != null and attack.active_ticks > 0 else DEFAULT_ACTIVE_TICKS


## Fracción (0 a 1) que lleva el relleno de una marca con [param age] de edad y [param impact_seconds]
## hasta el impacto (en segundos o en ticks, las dos en la misma unidad): crece linealmente y se queda llena.
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


## Malla plana (y = 0) del borde de la misma zona que [method build_mesh]: una franja de [param width] m por
## el arco y, en un sector, también por sus dos lados rectos. Es lo que da el borde ámbar a la marca (UI-50).
static func build_edge_mesh(radius: float, angle: float, segments: int, width: float = 0.14) -> ArrayMesh:
	var steps: int = maxi(ceili(float(segments) * minf(angle, TAU) / TAU), 1)
	var start: float = -angle * 0.5
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var inner_radius: float = maxf(radius - width, 0.0)
	for i: int in steps + 1:
		var direction: float = start + angle * float(i) / float(steps)
		var radial := Vector3(sin(direction), 0.0, -cos(direction))
		vertices.append(radial * inner_radius)
		vertices.append(radial * radius)
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)
	for i: int in steps:
		var a: int = i * 2
		indices.append_array(PackedInt32Array([a, a + 3, a + 1, a, a + 2, a + 3]))
	if angle < TAU - 0.001:
		# Los dos lados rectos: un rectángulo del centro al arco, de [param width] de grosor.
		for side: int in 2:
			var direction: float = start if side == 0 else start + angle
			var radial := Vector3(sin(direction), 0.0, -cos(direction))
			var across := Vector3(radial.z, 0.0, -radial.x) * (width * 0.5)
			var base: int = vertices.size()
			vertices.append(-across)
			vertices.append(across)
			vertices.append(radial * radius + across)
			vertices.append(radial * radius - across)
			for _n: int in 4:
				normals.append(Vector3.UP)
			indices.append_array(PackedInt32Array([base, base + 2, base + 1, base, base + 3, base + 2]))
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


# Relleno de [param mark] en el instante [param now] del reloj predicho (negativo: sin reloj, por su edad).
func _progress_of(mark: Mark, now: float) -> float:
	if now < 0.0:
		return fill_progress(mark.age, mark.impact_seconds)
	return fill_progress(now - float(mark.event_tick), float(mark.impact_ticks))


# true si [param mark] ya ha acabado en el instante [param now] del reloj predicho (negativo: sin reloj, por su edad).
func _is_over(mark: Mark, now: float) -> bool:
	if now < 0.0:
		return mark.age >= mark.impact_seconds + TAIL_SECONDS
	return now - float(mark.event_tick) >= float(mark.impact_ticks + mark.active_ticks)


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


func _get_edge_material() -> StandardMaterial3D:
	if _edge_material == null:
		_edge_material = _make_material(EDGE_COLOR)
	return _edge_material


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	material.disable_receive_shadows = true
	return material
