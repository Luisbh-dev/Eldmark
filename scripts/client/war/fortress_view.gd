class_name FortressView
extends Node
## View of the fortresses on the client (docs/fuerte.md, sections 2 and 3.2; GUE-09, GUE-12 client
## part). It receives the ENTITY_SPAWN of each structure ([method on_spawn]) and its OBJECT_STATE
## ([method on_object_state]), keeps the change history ([FortressTimeline]) and applies it in two
## different ways:
## [br][br]
## [b]Interface and banners, at the draw tick.[/b] [method advance] ([NetClient] calls it on every
## physics tick with the [code]render_tick[/code] of the [InterpolationClock]) sets as the
## [i]displayed[/i] state the one in force at that instant. When it changes: it recolors the banners
## ([code]Estandarte[/code], [code]EstandartePuertaN[/code] and [code]EstandartePuertaS[/code], the
## [code]faction_color[/code] instance parameter with the owner's color; the Hollow if
## neutral), sets the gate's pose ([method FortGate.set_state]) and emits [signal state_changed].
## Capture progress is evaluated with the formula at the requested instant ([method get_progress]).
## [br][br]
## [b]Gate collision, at the simulated tick.[/b] [method before_simulate] is the
## [member ClientPrediction.before_simulate] hook: before simulating tick [code]t[/code] (also during
## reconciliation replays) it sets the gate's movement layers that it had at that tick
## ([method FortressTimeline.gate_layers_for_tick]: a change with [code]tick = s[/code] takes effect from
## [code]s + 1[/code]). This way reconciliation replays simulate each tick with the same gate as the
## server. But the OBJECT_STATE arrives one trip later and the client runs ahead: the ticks from
## [code]s + 1[/code] to the predicted one at the moment of receipt were already simulated with the old gate, and if the player was touching it
## during them the snapshot does not match. That correction is expected and the replay fixes it; [NetClient] counts it as
## explained by the gate ([code]gate_diffs[/code]), not as a prediction failure. These layers are not overwritten by the
## draw pose: [method advance] sets them again after changing the pose. Changes that affect
## collision (owner and gate breakage) must arrive with the tick at which they actually
## changed.
## [br][br]
## [b]Scene.[/b] The scene's fortress is the node of group [constant FORTRESS_GROUP] whose
## definition ([code]definition[/code] metadata) has the SPAWN's id. It is searched for in the zone given
## with [method set_zone] or, failing that, in the whole tree. If the scene is not there yet, the history is
## stored anyway and linking is retried.
## [br][br]
## Client only.

## A fortress now has an on-screen state or the one being shown has changed. [param previous] is
## null the first time.
signal state_changed(net_id: int, state: FortressState, previous: FortressState)
## The SPAWN of a previously unknown fortress arrives.
signal fortress_added(net_id: int)

## Group of the zone's fortresses and metadata of its definition. They are those of [code]Zones.FORTRESS_GROUP[/code]
## and [code]Zones.FORTRESS_DEFINITION_META[/code]; the network code does not name [code]Zones[/code] (only
## [NetZones]) and a test checks that they remain the same.
const FORTRESS_GROUP: StringName = &"fortresses"
const DEFINITION_META: StringName = &"definition"
## Banner nodes of the fortress scene.
const BANNER_NODES: Array[StringName] = [&"Estandarte", &"EstandartePuertaN", &"EstandartePuertaS"]
const GATE_NODE: NodePath = ^"FortGate"
const CIRCLE_NODE: NodePath = ^"CaptureCircle"
## Property of the banner mesh with the faction color (shader instance parameter).
const FACTION_COLOR_PROPERTY: String = "instance_shader_parameters/faction_color"
## Emblem from the keep banner's atlas (instance parameter): 0 Vardheim, 1 Solmarch, 2 Askarra
## and 3 the neutral one (the gate masts do not have it).
const EMBLEM_PROPERTY: String = "instance_shader_parameters/emblem_index"
const NEUTRAL_EMBLEM: float = 3.0
## Folder of the definitions, in case the scene is not there to say which one it is.
const DEFINITIONS_DIR: String = "res://data/fortresses"
## Every how many calls to [method advance] linking with the scene is retried.
const REBIND_INTERVAL: int = 30


## A known fortress.
class Fortress extends RefCounted:
	var net_id: int = 0
	var definition_id: String = ""
	var timeline: FortressTimeline = null
	var node: Node3D = null
	var gate: FortGate = null
	var banners: Array[MeshInstance3D] = []
	## On-screen state (the one in force at the last draw tick) and the version of the history that
	## gave it; null until the first one is shown.
	var displayed: FortressState = null
	var banner_color: Color = Color.WHITE
	var has_banner_color: bool = false
	## Last movement layers set on the gate by the hook (-1 = none).
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


## Interpolation clock, for [method get_progress_now].
func setup(clock: InterpolationClock) -> void:
	_clock = clock


## Zone in which to look for the scene's fortresses (null = the whole tree). Retries linking those already
## known.
func set_zone(zone: Node) -> void:
	_zone = zone
	for fortress: Fortress in _fortresses.values():
		_bind(fortress)


## true if [param net_id] is a known fortress.
func has_fortress(net_id: int) -> bool:
	return _fortresses.has(net_id)


## Network ids of the known fortresses, in order.
func get_fortress_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(_fortresses.keys())
	ids.sort()
	return ids


## First known fortress (0 if there is none): in Vado Gris, the only one.
func get_primary_id() -> int:
	var ids: Array[int] = get_fortress_ids()
	return ids[0] if not ids.is_empty() else 0


## ENTITY_SPAWN of a structure: creates the fortress (or, if it already existed, records its fields as one more
## change) and links it to its scene. Returns false if the message is not for a structure or
## carries no known fields.
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


## OBJECT_STATE of a known fortress: records the fields as a change at the message's tick. It is
## ignored (and counted) if the fortress is not known or carries no applicable fields.
func on_object_state(object_state: NetMessages.ObjectState) -> bool:
	if object_state == null:
		return false
	var fortress: Fortress = _fortresses.get(object_state.net_id)
	if fortress == null or fortress.timeline.apply_object_state(object_state) == 0:
		_ignored_states += 1
		return false
	return true


## Applies the state in force at draw tick [param render_tick] to the interface and the scene.
## With the clock not started (0 or less) it does nothing.
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


## Hook of [member ClientPrediction.before_simulate]: sets on each gate the movement layers
## it has at tick [param tick], which is about to be simulated.
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


## Movement layers of the gate of [param net_id] for the simulated tick [param tick], according to the history
## known now (-1 if the fortress is not known or has no state yet).
func get_gate_layers_for_tick(net_id: int, tick: int) -> int:
	var fortress: Fortress = _fortresses.get(net_id)
	if fortress == null or not fortress.timeline.has_state():
		return -1
	return fortress.timeline.gate_layers_for_tick(tick)


## Movement layers that the hook last set on the gate of [param net_id] (-1 if
## none).
func get_gate_movement_layers(net_id: int) -> int:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.movement_layers if fortress != null else -1


# --- Queries ----------------------------------------------------------------------------------

## On-screen state of the fortress (the one in force at the last draw tick), or null if none has been
## shown yet. It must not be modified.
func get_displayed_state(net_id: int) -> FortressState:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.displayed if fortress != null else null


## Latest known state, the newest that has arrived (it may be ahead of what is seen). Null
## if the fortress is not known.
func get_latest_state(net_id: int) -> FortressState:
	var fortress: Fortress = _fortresses.get(net_id)
	if fortress == null or not fortress.timeline.has_state():
		return null
	return fortress.timeline.state_at(fortress.timeline.get_latest_tick())


## History of the fortress (null if not known).
func get_timeline(net_id: int) -> FortressTimeline:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.timeline if fortress != null else null


## Definition of the fortress (null if not known).
func get_definition(net_id: int) -> FortressDefinition:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.timeline.get_definition() if fortress != null else null


## Id of the SPAWN's definition ("vado_gris_fort"); empty if not known.
func get_definition_id(net_id: int) -> String:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.definition_id if fortress != null else ""


## Capture progress (0 to [member FortressState.progress_max]) at [param render_time] (ticks with a
## fraction): the formula of the state in force at that instant. 0 if the fortress is not known.
func get_progress(net_id: int, render_time: float) -> int:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.timeline.progress_at(render_time) if fortress != null else 0


## Progress from 0 to 1 at [param render_time].
func get_progress_fraction(net_id: int, render_time: float) -> float:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.timeline.progress_fraction_at(render_time) if fortress != null else 0.0


## Draw instant right now (tick with a fraction), or 0 if the clock has not started.
func get_render_time_now() -> float:
	if _clock == null or _clock.get_render_tick() <= 0.0:
		return 0.0
	return _clock.get_render_tick() + Engine.get_physics_interpolation_fraction()


## Progress from 0 to 1 at the draw instant right now.
func get_progress_fraction_now(net_id: int) -> float:
	return get_progress_fraction(net_id, get_render_time_now())


## States of the fortresses by definition id, as [method RespawnRules.points_for] asks for them
## ([param tick]: the server tick whose state is wanted). A fortress without a state is not
## included.
func get_states_by_definition(tick: int) -> Dictionary:
	var states: Dictionary = {}
	for fortress: Fortress in _fortresses.values():
		if fortress.timeline.has_state():
			states[StringName(fortress.definition_id)] = fortress.timeline.state_at(tick)
	return states


## Interface name of each known fortress, by definition id (the respawn points inside a
## fort are named after it, [method RespawnPointList.options]).
func get_display_names() -> Dictionary:
	var names: Dictionary = {}
	for fortress: Fortress in _fortresses.values():
		var definition: FortressDefinition = fortress.timeline.get_definition()
		if definition != null and not definition.display_name.is_empty():
			names[StringName(fortress.definition_id)] = definition.display_name
	return names


## Position of the fortress node in the world ([constant Vector3.INF] if not linked).
func get_anchor_position(net_id: int) -> Vector3:
	var fortress: Fortress = _fortresses.get(net_id)
	if fortress == null or fortress.node == null or not is_instance_valid(fortress.node):
		return Vector3.INF
	return fortress.node.global_position if fortress.node.is_inside_tree() \
			else fortress.node.position


## Center of the capture circle ([constant Vector3.INF] if not linked).
func get_circle_center(net_id: int) -> Vector3:
	var circle: Node3D = _marker(net_id, CIRCLE_NODE)
	if circle == null:
		return Vector3.INF
	return circle.global_position if circle.is_inside_tree() else circle.position


## Radius of the capture circle ([code]radius[/code] metadata of the marker; 0 if unknown).
func get_circle_radius(net_id: int) -> float:
	var circle: Node3D = _marker(net_id, CIRCLE_NODE)
	return float(circle.get_meta(&"radius", 0.0)) if circle != null else 0.0


## Center of the gate, at ground level ([constant Vector3.INF] if not linked).
func get_gate_position(net_id: int) -> Vector3:
	var fortress: Fortress = _fortresses.get(net_id)
	if fortress == null or fortress.gate == null or not is_instance_valid(fortress.gate):
		return Vector3.INF
	return fortress.gate.global_position if fortress.gate.is_inside_tree() \
			else fortress.gate.position


## The scene's gate (null if not linked).
func get_gate(net_id: int) -> FortGate:
	var fortress: Fortress = _fortresses.get(net_id)
	if fortress == null or fortress.gate == null or not is_instance_valid(fortress.gate):
		return null
	return fortress.gate


## Color the fortress's banners were last painted with (white, and
## [method has_banner_color] false, if they have not been painted yet).
func get_banner_color(net_id: int) -> Color:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress.banner_color if fortress != null else Color.WHITE


func has_banner_color(net_id: int) -> bool:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress != null and fortress.has_banner_color


## Linked banner meshes of the fortress.
func get_banners(net_id: int) -> Array[MeshInstance3D]:
	var fortress: Fortress = _fortresses.get(net_id)
	var banners: Array[MeshInstance3D] = []
	if fortress != null:
		banners.assign(fortress.banners)
	return banners


## true if the fortress is linked to its scene node.
func is_bound(net_id: int) -> bool:
	var fortress: Fortress = _fortresses.get(net_id)
	return fortress != null and fortress.node != null and is_instance_valid(fortress.node)


## Statistics: ignored OBJECT_STATEs, hook calls and layer changes made to the gate.
func get_stats() -> Dictionary:
	return {
		"fortresses": _fortresses.size(),
		"ignored_states": _ignored_states,
		"hook_calls": _hook_calls,
		"gate_layer_changes": _gate_layer_changes,
	}


# --- Internal ---------------------------------------------------------------------------------

func _marker(net_id: int, path: NodePath) -> Node3D:
	var fortress: Fortress = _fortresses.get(net_id)
	if fortress == null or fortress.node == null or not is_instance_valid(fortress.node):
		return null
	return fortress.node.get_node_or_null(path) as Node3D


# Links to the scene node (if not already linked) and looks for the gate and the banners.
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
	# If a state was already shown before linking, it is applied to what was just linked.
	if fortress.displayed != null:
		_apply_to_scene(fortress, fortress.displayed)


# Looks for the node of the fortress group whose definition has the SPAWN's id.
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
		# The keep banner (FortKeep) hangs from the keep's glTF, not from the fort's root, and is
		# itself the mesh; those of the masts are a node with the mesh inside.
		var banner: Node = root.get_node_or_null(NodePath(String(banner_name)))
		if banner == null:
			banner = root.find_child(String(banner_name), true, false)
		if banner == null:
			continue
		var candidates: Array[Node] = [banner]
		candidates.append_array(banner.find_children("*", "MeshInstance3D", true, false))
		for child: Node in candidates:
			var mesh: MeshInstance3D = child as MeshInstance3D
			if mesh != null and mesh.get(FACTION_COLOR_PROPERTY) != null:
				found.append(mesh)
	return found


# Definition of the fortress: the one the scene node's metadata names and, failing that, the one whose
# id is in the data folder; if that is not there either, a default one.
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


# The definition the node carries in its metadata: the [FortressDefinition] itself (test
# scenes) or the path to its .tres (the Vado Gris generator), as on the server.
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


# Banners in the owner's color and the gate with its pose (broken or whole). The movement layers
# are driven by prediction: they are set again after changing the pose.
func _apply_to_scene(fortress: Fortress, state: FortressState) -> void:
	var color: Color = UIPalette.faction_color_of_code(state.owner)
	fortress.banner_color = color
	fortress.has_banner_color = true
	for mesh: MeshInstance3D in fortress.banners:
		if is_instance_valid(mesh):
			mesh.set(FACTION_COLOR_PROPERTY, color)
			if mesh.get(EMBLEM_PROPERTY) != null:
				mesh.set(EMBLEM_PROPERTY, float(state.owner - 1) if state.owner >= 1 and state.owner <= 3 else NEUTRAL_EMBLEM)
	var gate: FortGate = fortress.gate
	if gate != null and is_instance_valid(gate):
		gate.set_state(state.owner, state.is_gate_broken())
		if fortress.movement_layers >= 0:
			gate.collision_layer = fortress.movement_layers
