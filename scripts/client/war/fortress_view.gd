class_name FortressView
extends Node
## Vista de las fortalezas en el cliente (docs/fuerte.md, secciones 2 y 3.2; GUE-09, GUE-12 parte
## cliente). Recibe el ENTITY_SPAWN de cada estructura ([method on_spawn]) y sus OBJECT_STATE
## ([method on_object_state]), guarda la historia de cambios ([FortressTimeline]) y la aplica de dos
## maneras distintas:
## [br][br]
## [b]Interfaz y estandartes, en el tick de dibujo.[/b] [method advance] (lo llama [NetClient] en cada
## tick de física con el [code]render_tick[/code] del [InterpolationClock]) pone como estado
## [i]mostrado[/i] el vigente en ese instante. Cuando cambia: recolorea los estandartes
## ([code]Estandarte[/code], [code]EstandartePuertaN[/code] y [code]EstandartePuertaS[/code], el
## parámetro de instancia [code]faction_color[/code] con el color del dueño; los Huecos si es
## neutral), pone la pose de la puerta ([method FortGate.set_state]) y emite [signal state_changed].
## El progreso de la captura se evalúa con la fórmula en el instante pedido ([method get_progress]).
## [br][br]
## [b]Colisión de la puerta, en el tick simulado.[/b] [method before_simulate] es el gancho
## [member ClientPrediction.before_simulate]: antes de simular el tick [code]t[/code] (también en las
## repeticiones de la reconciliación) pone las capas de movimiento de la puerta que tenía ese tick
## ([method FortressTimeline.gate_layers_for_tick]: un cambio con [code]tick = s[/code] vale desde
## [code]s + 1[/code]). Así cliente y servidor simulan cada tick con la misma puerta y la
## reconciliación, que compara el estado byte a byte, no ve diferencias. Esas capas no las pisa la
## pose de dibujo: [method advance] las vuelve a poner tras cambiar la pose. Los cambios que tocan a
## la colisión (dueño y rotura de la puerta) tienen que llegar con el tick en el que cambiaron de
## verdad.
## [br][br]
## [b]Escena.[/b] La fortaleza de la escena es el nodo del grupo [constant FORTRESS_GROUP] cuya
## definición (metadato [code]definition[/code]) tiene el id del SPAWN. Se busca en la zona que se
## dio con [method set_zone] o, si no, en todo el árbol. Si la escena aún no está, la historia se
## guarda igual y el enlace se reintenta.
## [br][br]
## Solo cliente.

## Una fortaleza ya tiene estado en pantalla o ha cambiado el que se muestra. [param previous] es
## null la primera vez.
signal state_changed(net_id: int, state: FortressState, previous: FortressState)
## Llega el SPAWN de una fortaleza que no se conocía.
signal fortress_added(net_id: int)

## Grupo de las fortalezas de la zona y metadato de su definición. Son los de [code]Zones.FORTRESS_GROUP[/code]
## y [code]Zones.FORTRESS_DEFINITION_META[/code]; el código de red no nombra [code]Zones[/code] (solo
## [NetZones]) y una prueba comprueba que siguen iguales.
const FORTRESS_GROUP: StringName = &"fortresses"
const DEFINITION_META: StringName = &"definition"
## Nodos de estandarte de la escena de la fortaleza.
const BANNER_NODES: Array[StringName] = [&"Estandarte", &"EstandartePuertaN", &"EstandartePuertaS"]
const GATE_NODE: NodePath = ^"FortGate"
const CIRCLE_NODE: NodePath = ^"CaptureCircle"
## Propiedad de la malla del estandarte con el color de bando (parámetro de instancia del shader).
const FACTION_COLOR_PROPERTY: String = "instance_shader_parameters/faction_color"
## Carpeta de las definiciones, por si la escena no está para decir cuál es.
const DEFINITIONS_DIR: String = "res://data/fortresses"
## Cada cuántas llamadas a [method advance] se reintenta enlazar con la escena.
const REBIND_INTERVAL: int = 30


## Una fortaleza conocida.
class Fortress extends RefCounted:
	var net_id: int = 0
	var definition_id: String = ""
	var timeline: FortressTimeline = null
	var node: Node3D = null
	var gate: FortGate = null
	var banners: Array[MeshInstance3D] = []
	## Estado en pantalla (el vigente en el último tick de dibujo) y la versión de la historia que lo
	## dio; null hasta que se muestra el primero.
	var displayed: FortressState = null
	var banner_color: Color = Color.WHITE
	var has_banner_color: bool = false
	## Últimas capas de movimiento puestas a la puerta por el gancho (-1 = ninguna).
	var movement_layers: int = -1
	var spawn_tick: int = 0

var _clock: InterpolationClock = null
var _zone: Node = null
var _fortresses: Dictionary[int, Fortress] = {}
var _definitions_by_path: Dictionary[String, FortressDefinition] = {}
var _definitions_by_id: Dictionary[String, FortressDefinition] = {}
var _scanned_directory: bool = false
var _advance_calls: int = 0
var _ignored_states: int = 0
var _hook_calls: int = 0
var _gate_layer_changes: int = 0


func _init() -> void:
	name = "FortressView"


## Reloj de interpolación, para [method get_progress_now].
func setup(clock: InterpolationClock) -> void:
	_clock = clock


## Zona donde buscar las fortalezas de la escena (null = todo el árbol). Reintenta enlazar las que ya
## se conocen.
func set_zone(zone: Node) -> void:
	_zone = zone
	for fortress: Fortress in _fortresses.values():
		_bind(fortress)


## true si [param net_id] es una fortaleza conocida.
func has_fortress(net_id: int) -> bool:
	return _fortresses.has(net_id)


## Ids de red de las fortalezas conocidas, en orden.
func get_fortress_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(_fortresses.keys())
	ids.sort()
	return ids


## Primera fortaleza conocida (0 si no hay ninguna): en el Vado Gris, la única.
func get_primary_id() -> int:
	var ids: Array[int] = get_fortress_ids()
	return ids[0] if not ids.is_empty() else 0


## ENTITY_SPAWN de una estructura: crea la fortaleza (o, si ya existía, anota sus campos como un
## cambio más) y la enlaza con su escena. Devuelve false si el mensaje no es de una estructura o no
## trae campos conocidos.
func on_spawn(spawn: NetMessages.EntitySpawn) -> bool:
	if spawn == null or spawn.kind != NetProtocol.EntityKind.STRUCTURE:
		return false
	var fortress: Fortress = _fortresses.get(spawn.net_id)
	var created: bool = fortress == null
	if created:
		fortress = Fortress.new()
		fortress.net_id = spawn.net_id
		fortress.definition_id = spawn.definition_id
		fortress.spawn_tick = spawn.spawn_tick
		_bind_node(fortress)
		fortress.timeline = FortressTimeline.new(_definition_for(fortress))
		_fortresses[spawn.net_id] = fortress
	var applied: int = fortress.timeline.apply_object_state(spawn.to_object_state())
	_bind(fortress)
	if created:
		fortress_added.emit(spawn.net_id)
	return applied > 0


## OBJECT_STATE de una fortaleza conocida: anota los campos como un cambio del tick del mensaje. Se
## ignora (y se cuenta) si la fortaleza no se conoce o no trae campos aplicables.
func on_object_state(object_state: NetMessages.ObjectState) -> bool:
	if object_state == null:
		return false
	var fortress: Fortress = _fortresses.get(object_state.net_id)
	if fortress == null or fortress.timeline.apply_object_state(object_state) == 0:
		_ignored_states += 1
		return false
	return true


## Aplica a la interfaz y a la escena el estado vigente en el tick de dibujo [param render_tick].
## Con el reloj sin arrancar (0 o menos) no hace nada.
func advance(render_tick: float) -> void:
	_advance_calls += 1
	if render_tick <= 0.0:
		return
	for fortress: Fortress in _fortresses.values():
		if fortress.node == null and _advance_calls % REBIND_INTERVAL == 0:
			_bind(fortress)
		if not fortress.timeline.has_state():
			continue
		var state: FortressState = fortress.timeline.state_at(floori(render_tick))
		if state == fortress.displayed:
			continue
		var previous: FortressState = fortress.displayed
		fortress.displayed = state
		_apply_to_scene(fortress, state)
		state_changed.emit(fortress.net_id, state, previous)


## Gancho de [member ClientPrediction.before_simulate]: pone a cada puerta las capas de movimiento
## que tiene en el tick [param tick] que se va a simular.
func before_simulate(tick: int) -> void:
	_hook_calls += 1
	for fortress: Fortress in _fortresses.values():
		var gate: FortGate = fortress.gate
		if gate == null or not is_instance_valid(gate):
			continue
		var layers: int = fortress.timeline.gate_layers_for_tick(tick)
		fortress.movement_layers = layers
		if gate.collision_layer != layers:
			gate.collision_layer = layers
			_gate_layer_changes += 1


## Capas de movimiento que el gancho puso por última vez a la puerta de [param net_id] (-1 si
## ninguna).
func get_gate_movement_layers(net_id: int) -> int:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.movement_layers if fortress != null else -1


# --- Consultas --------------------------------------------------------------------------------

## Estado en pantalla de la fortaleza (el vigente en el último tick de dibujo), o null si todavía no
## se ha mostrado ninguno. No se debe modificar.
func get_displayed_state(net_id: int) -> FortressState:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.displayed if fortress != null else null


## Último estado conocido, el más nuevo que ha llegado (puede ir por delante de lo que se ve). Null
## si no se conoce la fortaleza.
func get_latest_state(net_id: int) -> FortressState:
	var fortress: Fortress = _fortresses.get(net_id)
	if fortress == null or not fortress.timeline.has_state():
		return null
	return fortress.timeline.state_at(fortress.timeline.get_latest_tick())


## Historia de la fortaleza (null si no se conoce).
func get_timeline(net_id: int) -> FortressTimeline:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.timeline if fortress != null else null


## Definición de la fortaleza (null si no se conoce).
func get_definition(net_id: int) -> FortressDefinition:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.timeline.get_definition() if fortress != null else null


## Id de la definición del SPAWN («vado_gris_fort»); vacío si no se conoce.
func get_definition_id(net_id: int) -> String:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.definition_id if fortress != null else ""


## Progreso de la captura (0 a [member FortressState.progress_max]) en [param render_time] (ticks con
## fracción): la fórmula del estado vigente en ese instante. 0 si no se conoce la fortaleza.
func get_progress(net_id: int, render_time: float) -> int:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.timeline.progress_at(render_time) if fortress != null else 0


## Progreso de 0 a 1 en [param render_time].
func get_progress_fraction(net_id: int, render_time: float) -> float:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.timeline.progress_fraction_at(render_time) if fortress != null else 0.0


## Instante de dibujo de ahora (tick con fracción), o 0 si el reloj no ha arrancado.
func get_render_time_now() -> float:
	if _clock == null or _clock.get_render_tick() <= 0.0:
		return 0.0
	return _clock.get_render_tick() + Engine.get_physics_interpolation_fraction()


## Progreso de 0 a 1 en el instante de dibujo de ahora.
func get_progress_fraction_now(net_id: int) -> float:
	return get_progress_fraction(net_id, get_render_time_now())


## Estados de las fortalezas por id de definición, como los pide [method RespawnRules.points_for]
## ([param tick]: el tick del servidor del que se quiere el estado). Una fortaleza sin estado no
## figura.
func get_states_by_definition(tick: int) -> Dictionary:
	var states: Dictionary = {}
	for fortress: Fortress in _fortresses.values():
		if fortress.timeline.has_state():
			states[StringName(fortress.definition_id)] = fortress.timeline.state_at(tick)
	return states


## Nombre para la interfaz de cada fortaleza conocida, por id de definición (los puntos de reaparición del
## interior de un fuerte se llaman como él, [method RespawnPointList.options]).
func get_display_names() -> Dictionary:
	var names: Dictionary = {}
	for fortress: Fortress in _fortresses.values():
		var definition: FortressDefinition = fortress.timeline.get_definition()
		if definition != null and not definition.display_name.is_empty():
			names[StringName(fortress.definition_id)] = definition.display_name
	return names


## Posición del nodo de la fortaleza en el mundo ([constant Vector3.INF] si no está enlazada).
func get_anchor_position(net_id: int) -> Vector3:
	var fortress: Fortress = _fortresses.get(net_id)
	if fortress == null or fortress.node == null or not is_instance_valid(fortress.node):
		return Vector3.INF
	return fortress.node.global_position if fortress.node.is_inside_tree() \
			else fortress.node.position


## Centro del círculo de captura ([constant Vector3.INF] si no está enlazada).
func get_circle_center(net_id: int) -> Vector3:
	var circle: Node3D = _marker(net_id, CIRCLE_NODE)
	if circle == null:
		return Vector3.INF
	return circle.global_position if circle.is_inside_tree() else circle.position


## Radio del círculo de captura (metadato [code]radius[/code] del marcador; 0 si no se sabe).
func get_circle_radius(net_id: int) -> float:
	var circle: Node3D = _marker(net_id, CIRCLE_NODE)
	return float(circle.get_meta(&"radius", 0.0)) if circle != null else 0.0


## Centro de la puerta, a ras de suelo ([constant Vector3.INF] si no está enlazada).
func get_gate_position(net_id: int) -> Vector3:
	var fortress: Fortress = _fortresses.get(net_id)
	if fortress == null or fortress.gate == null or not is_instance_valid(fortress.gate):
		return Vector3.INF
	return fortress.gate.global_position if fortress.gate.is_inside_tree() \
			else fortress.gate.position


## La puerta de la escena (null si no está enlazada).
func get_gate(net_id: int) -> FortGate:
	var fortress: Fortress = _fortresses.get(net_id)
	if fortress == null or fortress.gate == null or not is_instance_valid(fortress.gate):
		return null
	return fortress.gate


## Color con el que se pintaron por última vez los estandartes de la fortaleza (blanco, y
## [method has_banner_color] false, si aún no se han pintado).
func get_banner_color(net_id: int) -> Color:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.banner_color if fortress != null else Color.WHITE


func has_banner_color(net_id: int) -> bool:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress != null and fortress.has_banner_color


## Mallas de estandarte enlazadas de la fortaleza.
func get_banners(net_id: int) -> Array[MeshInstance3D]:
	var fortress: Fortress = _fortresses.get(net_id)
	var banners: Array[MeshInstance3D] = []
	if fortress != null:
		banners.assign(fortress.banners)
	return banners


## true si la fortaleza está enlazada con su nodo de la escena.
func is_bound(net_id: int) -> bool:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress != null and fortress.node != null and is_instance_valid(fortress.node)


## Estadísticas: OBJECT_STATE ignorados, llamadas al gancho y cambios de capa hechos a la puerta.
func get_stats() -> Dictionary:
	return {
		"fortresses": _fortresses.size(),
		"ignored_states": _ignored_states,
		"hook_calls": _hook_calls,
		"gate_layer_changes": _gate_layer_changes,
	}


# --- Interno ----------------------------------------------------------------------------------

func _marker(net_id: int, path: NodePath) -> Node3D:
	var fortress: Fortress = _fortresses.get(net_id)
	if fortress == null or fortress.node == null or not is_instance_valid(fortress.node):
		return null
	return fortress.node.get_node_or_null(path) as Node3D


# Enlaza con el nodo de la escena (si no lo estaba) y busca la puerta y los estandartes.
func _bind(fortress: Fortress) -> void:
	if fortress.node == null or not is_instance_valid(fortress.node):
		fortress.node = null
		_bind_node(fortress)
	if fortress.node == null:
		return
	if fortress.gate == null or not is_instance_valid(fortress.gate):
		fortress.gate = fortress.node.get_node_or_null(GATE_NODE) as FortGate
		fortress.movement_layers = -1
	if fortress.banners.is_empty():
		fortress.banners = _find_banners(fortress.node)
	# Si ya se mostró un estado antes de enlazar, se aplica a lo recién enlazado.
	if fortress.displayed != null:
		_apply_to_scene(fortress, fortress.displayed)


# Busca el nodo del grupo de fortalezas cuya definición tiene el id del SPAWN.
func _bind_node(fortress: Fortress) -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var restrict_to_zone: bool = _zone != null and is_instance_valid(_zone) and _zone.is_inside_tree()
	for node: Node in tree.get_nodes_in_group(FORTRESS_GROUP):
		var candidate: Node3D = node as Node3D
		if candidate == null or (restrict_to_zone and not _zone.is_ancestor_of(candidate)):
			continue
		var definition: FortressDefinition = _definition_from_meta(candidate)
		if definition != null and String(definition.id) == fortress.definition_id:
			fortress.node = candidate
			return


func _find_banners(root: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	for banner_name: StringName in BANNER_NODES:
		var banner: Node = root.get_node_or_null(NodePath(String(banner_name)))
		if banner == null:
			continue
		for child: Node in banner.find_children("*", "MeshInstance3D", true, false):
			var mesh: MeshInstance3D = child as MeshInstance3D
			if mesh != null and mesh.get(FACTION_COLOR_PROPERTY) != null:
				found.append(mesh)
	return found


# Definición de la fortaleza: la que dice el metadato del nodo de la escena y, si no, la que tiene su
# id en la carpeta de datos; si tampoco está, una por defecto.
func _definition_for(fortress: Fortress) -> FortressDefinition:
	if fortress.node != null:
		var from_scene: FortressDefinition = _definition_from_meta(fortress.node)
		if from_scene != null:
			return from_scene
	_scan_definitions()
	var known: FortressDefinition = _definitions_by_id.get(fortress.definition_id)
	if known != null:
		return known
	var fallback := FortressDefinition.new()
	fallback.id = StringName(fortress.definition_id)
	return fallback


# La definición que lleva el nodo en el metadato: la propia [FortressDefinition] (las escenas de
# prueba) o la ruta de su .tres (el generador del Vado Gris), como en el servidor.
func _definition_from_meta(node: Node) -> FortressDefinition:
	var value: Variant = node.get_meta(DEFINITION_META, null)
	if value is FortressDefinition:
		var definition: FortressDefinition = value as FortressDefinition
		_definitions_by_id[String(definition.id)] = definition
		return definition
	if value is String or value is StringName:
		return _load_definition(String(value))
	return null


func _load_definition(path: String) -> FortressDefinition:
	if path.is_empty():
		return null
	if _definitions_by_path.has(path):
		return _definitions_by_path[path]
	var definition: FortressDefinition = load(path) as FortressDefinition if ResourceLoader.exists(path) else null
	if definition != null:
		_definitions_by_path[path] = definition
		_definitions_by_id[String(definition.id)] = definition
	return definition


func _scan_definitions() -> void:
	if _scanned_directory:
		return
	_scanned_directory = true
	for file_name: String in DirAccess.get_files_at(DEFINITIONS_DIR):
		if file_name.ends_with(".tres"):
			_load_definition("%s/%s" % [DEFINITIONS_DIR, file_name])


# Estandartes con el color del dueño y la puerta con su pose (rota o entera). Las capas de movimiento
# las manda la predicción: se vuelven a poner tras cambiar la pose.
func _apply_to_scene(fortress: Fortress, state: FortressState) -> void:
	var color: Color = UIPalette.faction_color_of_code(state.owner)
	fortress.banner_color = color
	fortress.has_banner_color = true
	for mesh: MeshInstance3D in fortress.banners:
		if is_instance_valid(mesh):
			mesh.set(FACTION_COLOR_PROPERTY, color)
	var gate: FortGate = fortress.gate
	if gate != null and is_instance_valid(gate):
		gate.set_state(state.owner, state.is_gate_broken())
		if fortress.movement_layers >= 0:
			gate.collision_layer = fortress.movement_layers
