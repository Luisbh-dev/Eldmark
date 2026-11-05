class_name TelegraphMarks
extends Node3D
## Ground marks for NPC attacks (UI-18, GUE: TELEGRAPH in docs/fuerte.md section 5). The
## server warns a few ticks before the hit ([signal NetClient.telegraph_received]: shape, origin,
## orientation, radius and ticks until impact) and here the danger zone is drawn on the ground:
## a translucent red circle or sector, with a more intense fill that grows from the center until
## it fills the shape exactly at impact, and that disappears right after.
## [br][br]
## [b]Provisional.[/b] It is a flat, unshaded mesh, [constant LIFT] m above the origin sent by the
## server (the NPC's feet): on sloped terrain it sinks or floats. A projected [Decal] would follow
## the relief, but it depends on the renderer; it is left for the art pass (ART-17). The sector angle comes from the
## attack in the combat catalog ([member HitShape.angle_deg]) and, if unknown, is
## [constant DEFAULT_SECTOR_DEGREES].
## [br][br]
## [b]Clock.[/b] The hit lands on the warning tick plus [code]impact_in_ticks[/code] (the windup) and the player's
## input for that tick dodges it; the client generates that input with its predicted tick. When the warning arrives, that clock is
## already ahead by one RTT plus the [TickSync] margin. That is why the mark fills with the local predicted time
## ([method ClientPrediction.get_predicted_tick] minus one plus the tick fraction, the instant at which the player sees
## their character, like [ProjectileWorld]): on arrival it is already that far along, it is full exactly on the last tick on which
## dodging still avoids the hit, and it is removed when the hit's active window ends ([member AttackTicks.active_ticks]).
## A warning that arrives with its hit already past is not drawn. With no prediction running (tests, spectator), it counts
## time from when it arrived, with each frame's delta ([method advance]), and is removed
## [constant TAIL_SECONDS] s after the impact (phase 4 review, client).
## [br][br]
## [b]Only what can hurt you.[/b] The server warns about the heavy hits of all NPCs, including those of the
## garrison and the captain of the realm that owns the fort; they are not drawn for a defender of that realm ([method threatens]:
## the [FactionRules] rule, the same one the bots use). Client only.

## Height above the origin (m) and vertices per turn of the mesh.
const LIFT: float = 0.06
const SEGMENTS: int = 40
## Angle (degrees) of a sector whose attack is not in the catalog.
const DEFAULT_SECTOR_DEGREES: float = 100.0
## Seconds the mark stays after impact when there is no predicted clock.
const TAIL_SECONDS: float = 0.35
## Ticks a hit stays active when its attack is not in the catalog (with a predicted clock).
const DEFAULT_ACTIVE_TICKS: int = 12
## Maximum marks at once (when one more arrives, the oldest is removed).
const MAX_MARKS: int = 24
## Amber of [UIPalette.TELEGRAPH]: the color reserved for NPC danger, distinct from the red of damage (UI-50).
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
	## Server tick of the warning, ticks until impact and ticks the hit stays active after it.
	var event_tick: int = 0
	var impact_ticks: int = 0
	var active_ticks: int = 0

## Local predicted clock ([code]() -> float[/code], in ticks with fraction; negative = no clock). Without it, the
## linked client's clock is used. It is for tests.
var clock: Callable = Callable()

var _marks: Array[Mark] = []
var _client: NetClient = null
var _base_material: StandardMaterial3D = null
var _fill_material: StandardMaterial3D = null
var _edge_material: StandardMaterial3D = null
var _added: int = 0


func _init() -> void:
	name = "TelegraphMarks"
	# The marks are placed in the world with global_position; the node itself does not move.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func _process(delta: float) -> void:
	advance(delta)


func _exit_tree() -> void:
	if is_instance_valid(_client) and _client.telegraph_received.is_connected(add_telegraph):
		_client.telegraph_received.disconnect(add_telegraph)


## Listens to the TELEGRAPHs of [param client].
func bind(client: NetClient) -> void:
	if is_instance_valid(_client) and _client.telegraph_received.is_connected(add_telegraph):
		_client.telegraph_received.disconnect(add_telegraph)
	_client = client
	if is_instance_valid(_client):
		_client.telegraph_received.connect(add_telegraph)


## true if the NPC [param npc_id] of the warning can damage the player of [param client]: [method FactionRules.can_damage]
## with the realm of its view in the [RemoteWorld], the player's realm and the WELCOME zone. With no client, no own realm or
## no spawn record for the NPC (its owner is unknown), true: when in doubt, the mark is drawn.
static func threatens(client: NetClient, npc_id: int) -> bool:
	if not is_instance_valid(client) or client.get_config() == null or client.get_remote_world() == null:
		return true
	var view: RemotePlayerView = client.get_remote_world().get_view(npc_id)
	if view == null:
		return true
	var welcome: NetMessages.Welcome = client.get_welcome()
	var zone_id: StringName = StringName(welcome.zone_id) if welcome != null else &""
	return FactionRules.can_damage(view.get_realm(), client.get_config().realm, zone_id)


## Draws the danger zone of a TELEGRAPH. An unknown shape, a radius of 0, the hit of someone who cannot damage the
## player ([method threatens]) or one that has already passed draw nothing. Returns true if the mark was created.
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


## Advances [param delta] seconds: the fill grows and the marks that end are removed. With a predicted clock it rules (the
## delta only counts without a clock).
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


## Instant of the local predicted clock in ticks with fraction ([member clock] or the client's prediction), or -1
## if none is running.
func get_clock_time() -> float:
	if clock.is_valid():
		return float(clock.call())
	if not is_instance_valid(_client):
		return -1.0
	var prediction: ClientPrediction = _client.get_prediction()
	if prediction == null or not prediction.is_started():
		return -1.0
	return float(prediction.get_predicted_tick() - 1) + Engine.get_physics_interpolation_fraction()


## Ticks the hit of attack [param attack_id] from the catalog stays active after impact
## ([constant DEFAULT_ACTIVE_TICKS] if unknown).
static func active_ticks_of(attack_id: int) -> int:
	var attack: AttackTicks = CombatCatalog.attack(attack_id)
	return attack.active_ticks if attack != null and attack.active_ticks > 0 else DEFAULT_ACTIVE_TICKS


## Fraction (0 to 1) of the fill of a mark with age [param age] and [param impact_seconds]
## until impact (in seconds or in ticks, both in the same unit): it grows linearly and stays full.
static func fill_progress(age: float, impact_seconds: float) -> float:
	if impact_seconds <= 0.0:
		return 1.0
	return clampf(age / impact_seconds, 0.0, 1.0)


## Total angle (degrees) of the sector of attack [param attack_id] in the combat catalog, or
## [constant DEFAULT_SECTOR_DEGREES] if unknown.
static func sector_degrees(attack_id: int) -> float:
	var attack: AttackTicks = CombatCatalog.attack(attack_id)
	if attack != null and attack.shape != null and attack.shape.angle_deg > 0.0:
		return attack.shape.angle_deg
	return DEFAULT_SECTOR_DEGREES


## Flat mesh (y = 0) of a circle or sector of [param radius] m and [param angle] rad (TAU = full
## circle), centered on the -Z axis (the NPC's "forward" at yaw 0), with [param segments] vertices per
## full turn. It is a triangle fan from the origin.
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
		# Clockwise seen from above: the visible face looks toward +Y.
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


## Flat mesh (y = 0) of the edge of the same zone as [method build_mesh]: a strip [param width] m wide along
## the arc and, in a sector, also along its two straight sides. It gives the mark its amber edge (UI-50).
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
		# The two straight sides: a rectangle from the center to the arc, [param width] thick.
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


## Marks visible now.
func get_mark_count() -> int:
	return _marks.size()


## Marks created since it exists.
func get_added_count() -> int:
	return _added


## Network id of the NPC of mark [param index] (0 if it does not exist).
func get_mark_npc(index: int) -> int:
	return _marks[index].npc_id if index >= 0 and index < _marks.size() else 0


## Node of mark [param index] (null if it does not exist).
func get_mark_node(index: int) -> Node3D:
	return _marks[index].node if index >= 0 and index < _marks.size() else null


## Fill fraction of mark [param index] (0 to 1).
func get_mark_fill(index: int) -> float:
	if index < 0 or index >= _marks.size():
		return 0.0
	return _marks[index].fill.scale.x


func clear() -> void:
	while not _marks.is_empty():
		_remove(0)


# Fill of [param mark] at instant [param now] of the predicted clock (negative: no clock, by its age).
func _progress_of(mark: Mark, now: float) -> float:
	if now < 0.0:
		return fill_progress(mark.age, mark.impact_seconds)
	return fill_progress(now - float(mark.event_tick), float(mark.impact_ticks))


# true if [param mark] has already ended at instant [param now] of the predicted clock (negative: no clock, by its age).
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
