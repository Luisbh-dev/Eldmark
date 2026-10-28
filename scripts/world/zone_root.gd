class_name ZoneRoot
extends Node3D
## Raíz de una escena de zona (la carga igual el servidor dedicado que el cliente).
##
## Prepara el [Terrain3D] para los dos casos sin que la zona sepa en cuál está:
## [br]- Servidor (sin cámara): la colisión completa ([code]FULL_GAME[/code]) no necesita
## [code]_physics_process[/code], y sin cámara ese proceso registra un error en el primer tick
## ("Cannot find the active camera"). Por eso se desactiva en [method _ready].
## [br]- Cliente: en cuanto el viewport tiene una cámara activa, se le asigna al terreno y se
## reactiva su proceso, para que el clipmap la siga. Si la cámara cambia, se vuelve a asignar.
## [br][br]
## El servidor dedicado llama además a [method strip_for_server] después de añadir la zona al
## árbol: quita todo lo que solo se ve (mallas, luces, entorno, vegetación del instanciador) y
## deja colisiones y marcadores. No se hace al detectar headless porque las pruebas y el cliente
## sin ventana también corren headless y necesitan la zona entera.
## [br][br]
## Los puntos de aparición se consultan con [method get_spawn_points], que delega en [Zones]
## (una sola regla para cliente, servidor y pruebas). No depende de nada de
## [code]scripts/client/[/code].

## Ruta al nodo Terrain3D de la zona.
@export var terrain_path: NodePath = ^"Terrain3D"
## Identificador de la zona (por ahora solo informativo).
@export var zone_id: StringName = &""

var _terrain: Node3D
var _bound_camera: Node3D
var _stripped: bool = false


func _ready() -> void:
	_terrain = get_node_or_null(terrain_path) as Node3D
	if _terrain == null:
		set_process(false)
		return
	# Sin cámara, el primer _physics_process de Terrain3D registraría un error.
	_terrain.set_physics_process(false)


func _process(_delta: float) -> void:
	if _stripped:
		return
	var camera: Node3D = get_viewport().get_camera_3d()
	if camera == null or camera == _bound_camera:
		return
	_bound_camera = camera
	_terrain.call(&"set_camera", camera)
	_terrain.set_physics_process(true)


## Nodo Terrain3D de la zona (o null si no tiene).
func get_terrain() -> Node3D:
	return _terrain


## Puntos de aparición de la zona (ver [method Zones.get_spawn_points]); con [param realm] no
## vacío, solo los de ese reino.
func get_spawn_points(realm: StringName = &"") -> Array[Node3D]:
	return Zones.get_spawn_points(self, realm)


## true si ya se ha llamado a [method strip_for_server].
func is_stripped() -> bool:
	return _stripped


## Quita la capa visual para el servidor dedicado: libera las [GeometryInstance3D] (mallas,
## MultiMesh, partículas), las luces y el [WorldEnvironment], y vacía las instancias del
## instanciador de Terrain3D (hierba, árboles, rocas: su colisión va aparte, en la escena).
## Conserva los cuerpos y formas de colisión, el terreno (su colisión) y los marcadores.
## Devuelve cuántos nodos ha quitado. Solo debe llamarlo el servidor, una vez.
func strip_for_server() -> int:
	if _stripped:
		return 0
	_stripped = true
	set_process(false)
	var removed: Array[Node] = []
	_collect_visuals(self, removed)
	for node: Node in removed:
		node.get_parent().remove_child(node)
		node.free()
	if _terrain != null:
		var assets: Resource = _terrain.get(&"assets") as Resource
		var instancer: Object = _terrain.get(&"instancer")
		if assets != null and instancer != null:
			for mesh_id: int in int(assets.call(&"get_mesh_count")):
				instancer.call(&"clear_by_mesh", mesh_id)
	return removed.size()


## Nodos solo visuales bajo [param node] (sin bajar dentro de ellos ni del Terrain3D, cuyos
## hijos internos gestiona el propio terreno).
func _collect_visuals(node: Node, out: Array[Node]) -> void:
	for child: Node in node.get_children():
		if child is GeometryInstance3D or child is Light3D or child is WorldEnvironment:
			# Un cuerpo de colisión colgado de una malla se perdería: se respeta.
			if _has_collision_descendant(child):
				_collect_visuals(child, out)
			else:
				out.append(child)
		elif child == _terrain:
			continue
		else:
			_collect_visuals(child, out)


static func _has_collision_descendant(node: Node) -> bool:
	for child: Node in node.get_children():
		if child is CollisionObject3D or child is CollisionShape3D or _has_collision_descendant(child):
			return true
	return false
