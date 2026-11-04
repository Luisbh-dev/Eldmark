class_name ProjectileWorld
extends Node3D
## The client's arrows (docs/abilities.md, section 6.2; CMB-22): the local player's own, predicted and
## replaced by the server's, and everyone else's, which arrive with their ballistics in an ENTITY_SPAWN
## of kind 3 and which the client flies on its own with [method Ballistics.position] (the snapshot does
## not carry them, section 5.3).
## [br][br]
## [b]Predicted.[/b] [ClientPrediction] emits [signal ClientPrediction.stepped] after [b]every[/b] step
## (one physics tick can produce two). On the step that is the commit of an attack or an ability with a
## projectile ([method ProjectileLaunch.from_state]), its arrows are created with that tick's input, the
## canonical ray ([AimRay]) against the local world and the capsules of the hostile remotes [b]as they
## are drawn[/b] (also for convergence) and the same quantization as the server
## ([method ProjectileLaunch.launch]). It is drawn at the predicted time (the local character's:
## [code]predicted tick − 1 + fraction[/code]); it stops in the world with its own ray (the first segment
## with [code]hit_from_inside[/code]) and is hidden when it touches an enemy's drawn capsule, with no
## number: the marker and the number arrive with the server's HIT, as in melee.
## [br][br]
## [b]Replacement.[/b] The SPAWN with our own [code]owner[/code] is paired with the predicted arrow of the
## same source and [code]volley_index[/code] whose tick differs by at most
## [member CombatRules.input_buffer_ticks]; its [code]p0[/code], [code]v0[/code] and [code]spawn_tick[/code]
## are adopted with a visual offset that decays over [constant OFFSET_DECAY_TICKS] ticks. With no match,
## the server's arrow is drawn (at the predicted time, like the player's own). A predicted arrow with no
## SPAWN when the server is already [member CombatRules.input_buffer_ticks] + [constant REJECT_EXTRA_TICKS]
## ticks ahead of its tick (the tick of the last snapshot, [method on_server_tick]) is removed: the server
## rejected it. It is measured against the server tick and not the RTT, which changes during the session
## (H5 review); with no snapshot yet, against the RTT of the input.
## [br][br]
## [b]Remotes.[/b] They appear when the draw tick reaches their [code]spawn_tick[/code] and are drawn at
## [code]pos(render_tick + fraction − spawn_tick)[/code]. With DESPAWN 4 (impact) they are removed at
## [code]despawn_tick + f[/code], where [code]f[/code] is the fraction of their own ray (world and drawn
## capsules of those hostile to the shooter's realm carried by the SPAWN) in the last segment, or 1 if it
## touches nothing: this way they reach the wall or the target. If the last segment is the first, with
## [code]hit_from_inside[/code], as on the server: an arrow leaving from inside the closed gate stays at
## its mouth. With DESPAWN 5 (expired), at [code]despawn_tick[/code]. The player's own arrow is removed
## with the same rule at its own time.
## [br][br]
## [NetClient] creates it, puts it in the zone with the [RemoteWorld] and passes it the steps and the
## messages. The tests call [method on_stepped], [method on_spawn], [method on_despawn] and [method draw]
## with exact instants. Client only.

## Ticks over which the visual offset decays when the predicted arrow is replaced by the server's.
const OFFSET_DECAY_TICKS: float = 6.0
## Extra ticks, on top of the RTT, to wait for a predicted arrow's SPAWN before considering it rejected.
const REJECT_EXTRA_TICKS: int = 30
## Extra ticks, beyond its lifetime, that a confirmed arrow is kept if its DESPAWN does not arrive.
const LIFETIME_GRACE_TICKS: int = 60
## Dimensions (m) of the placeholder arrow (a long box along the velocity).
const ARROW_LENGTH: float = 0.75
const ARROW_THICKNESS: float = 0.035
const ARROW_COLOR: Color = Color(0.55, 0.42, 0.25, 1.0)
## Maximum number of segments tested per arrow and draw (an arrow lives 120 ticks).
const MAX_SEGMENTS_PER_DRAW: int = 256

## An arrow.
class Arrow:
	## Network id (0 while it is only predicted).
	var net_id: int = 0
	var owner_id: int = 0
	## Shooter's realm (the SPAWN's; the local player's for the predicted one): who is hostile to the arrow.
	var realm: int = NetProtocol.Realm.NONE
	var source: int = 0
	var volley_index: int = 0
	var projectile_id: int = 0
	var gravity: float = 0.0
	var radius: float = 0.0
	var lifetime_ticks: int = 0
	var spawn_tick: int = 0
	var p0: Vector3 = Vector3.ZERO
	var v0: Vector3 = Vector3.ZERO
	var harmless: bool = false
	## true: drawn at the predicted time (the local player's).
	var predicted: bool = false
	## true: the server has sent it (SPAWN).
	var confirmed: bool = false
	## Predicted tick at which the predicted arrow was created (to consider it rejected).
	var created_tick: int = 0
	## Visual offset applied on replacement (added to the position and decaying) and the instant it was set.
	var offset: Vector3 = Vector3.ZERO
	var offset_time: float = 0.0
	## [code]n[/code] (flight ticks, with fraction) at which it sticks into the world or touches a drawn
	## capsule (-1 = not yet). First segment not yet tested.
	var stuck_n: float = -1.0
	var hidden_n: float = -1.0
	var checked_segments: int = 0
	## [code]n[/code] at which it is removed (-1 = no DESPAWN yet) and why.
	var end_n: float = -1.0
	var despawn_reason: int = 0
	## What was drawn in the last [method draw].
	var drawn_position: Vector3 = Vector3.ZERO
	var drawn_n: float = 0.0
	var visible: bool = false
	var node: MeshInstance3D = null

	## Position after [param n] flight ticks (without the offset).
	func position_at(n: float) -> Vector3:
		return Ballistics.position(p0, v0, gravity, n)

	## Velocity after [param n] flight ticks.
	func velocity_at(n: float) -> Vector3:
		return v0 + Vector3(0.0, -gravity * n / Ballistics.TICK_RATE, 0.0)

	## Visual offset at instant [param time].
	func offset_at(time: float) -> Vector3:
		if offset == Vector3.ZERO:
			return Vector3.ZERO
		return offset * clampf(1.0 - (time - offset_time) / OFFSET_DECAY_TICKS, 0.0, 1.0)


## true: each arrow gets its placeholder mesh. By default, only if there is a display (a headless bot
## only keeps count).
var install_visuals: bool = DisplayServer.get_name() != "headless"
## Tests only: if valid, gives the physics space of the local world (otherwise, this node's).
var space_override: PhysicsDirectSpaceState3D = null

var _clock: InterpolationClock = null
var _remote_world: RemoteWorld = null
var _prediction: ClientPrediction = null
var _character: PlayerCharacter = null
var _own_id: int = 0
var _own_realm: int = NetProtocol.Realm.NONE
var _zone_id: StringName = &""
var _rtt_ticks: int = 0
# Tick of the server's last snapshot (-1 = none yet): used to consider a predicted arrow rejected.
var _server_tick: int = -1
var _arrows: Array[Arrow] = []
var _last_own_time: float = 0.0
var _last_render_time: float = 0.0
var _mesh: BoxMesh = null
var _stats: Dictionary = {
	"predicted": 0, "substituted": 0, "own_from_server": 0, "remote": 0, "rejected": 0,
	"impacts": 0, "expired": 0, "stuck": 0, "hidden": 0,
}


func _init() -> void:
	name = "ProjectileWorld"
	# Placed every frame at its exact instant, like the remotes.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	process_priority = -5


## The remotes' draw clock and the remotes' world (their drawn capsules).
func setup(clock: InterpolationClock, remote_world: RemoteWorld) -> void:
	_clock = clock
	_remote_world = remote_world


## The local player: its network id, its realm and the zone (who is hostile, [FactionRules]), its
## character (the local physics world) and its prediction (the predicted time and
## [signal ClientPrediction.stepped], which it connects to), and the RTT in ticks (to consider a
## predicted arrow rejected while no snapshot has arrived).
func set_local(net_id: int, realm: int, zone_id: StringName, character: PlayerCharacter,
		prediction: ClientPrediction, rtt_ticks: int) -> void:
	if _prediction != null and _prediction.stepped.is_connected(on_stepped):
		_prediction.stepped.disconnect(on_stepped)
	_own_id = net_id
	_own_realm = realm
	_zone_id = zone_id
	_character = character
	_prediction = prediction
	_rtt_ticks = maxi(rtt_ticks, 0)
	_server_tick = -1
	if _prediction != null:
		_prediction.stepped.connect(on_stepped)


func _process(_delta: float) -> void:
	var fraction: float = Engine.get_physics_interpolation_fraction()
	var own_time: float = _last_own_time
	if _prediction != null and _prediction.is_started():
		own_time = float(_prediction.get_predicted_tick() - 1) + fraction
	var render_time: float = _last_render_time
	if _clock != null and _clock.get_render_tick() > 0.0:
		render_time = _clock.get_render_tick() + fraction
	draw(own_time, render_time)


# --- Inputs -------------------------------------------------------------------------------------

## Tick [param tick] of the newest snapshot that has arrived ([NetClient] passes it with each one): how
## far the server has already simulated. A predicted arrow whose tick falls more than
## [member CombatRules.input_buffer_ticks] + [constant REJECT_EXTRA_TICKS] ticks behind with no SPAWN is
## removed (the SPAWN travels over the reliable channel and may arrive slightly after the snapshot of its
## tick).
func on_server_tick(tick: int) -> void:
	_server_tick = maxi(_server_tick, tick)


## A prediction step ([signal ClientPrediction.stepped]): if [param tick] is the commit of a shot, it
## creates its predicted arrows with input [param input] and the feet of [param state].
func on_stepped(tick: int, input: PlayerInput, state: PlayerState) -> void:
	if state == null or input == null:
		return
	var launch: ProjectileLaunch = ProjectileLaunch.from_state(state.combat, tick)
	if launch == null:
		return
	var projectile: ProjectileTicks = CombatCatalog.projectile(launch.projectile_id)
	if projectile == null:
		return
	var shots: Array[PackedVector3Array] = launch.launch(state.position, input.look_yaw,
			input.look_pitch, (input.buttons & PlayerInput.AIM_LEFT) != 0, _space(),
			_hostile_feet(_own_id, _own_realm))
	for index: int in shots.size():
		var arrow := Arrow.new()
		arrow.owner_id = _own_id
		arrow.realm = _own_realm
		arrow.source = launch.source
		arrow.volley_index = index
		arrow.spawn_tick = tick
		arrow.created_tick = tick
		arrow.predicted = true
		_set_ballistics(arrow, launch.projectile_id, projectile, shots[index][0], shots[index][1])
		_add(arrow)
		_stats["predicted"] += 1


## ENTITY_SPAWN of a projectile ([signal NetClient.projectile_spawned]). If it is the local player's, it
## replaces its predicted arrow (or the server's is drawn, with no match); otherwise it is a remote.
func on_spawn(spawn: NetMessages.EntitySpawn) -> void:
	if spawn == null or spawn.kind != NetProtocol.EntityKind.PROJECTILE or find_arrow(spawn.net_id) != null:
		return
	var projectile: ProjectileTicks = CombatCatalog.projectile(spawn.projectile_def_id)
	if projectile == null:
		return
	if _own_id != 0 and spawn.owner_id == _own_id:
		var pair: Arrow = _find_pair(spawn)
		if pair != null:
			_substitute(pair, spawn, projectile)
			_stats["substituted"] += 1
			return
		var own := Arrow.new()
		_fill_from_spawn(own, spawn, projectile)
		own.predicted = true
		own.created_tick = spawn.spawn_tick
		_add(own)
		_stats["own_from_server"] += 1
		return
	var remote := Arrow.new()
	_fill_from_spawn(remote, spawn, projectile)
	_add(remote)
	_stats["remote"] += 1


## ENTITY_DESPAWN of a projectile ([signal NetClient.projectile_despawned]): sets when it is removed.
func on_despawn(projectile_id: int, tick: int, reason: int) -> void:
	var arrow: Arrow = find_arrow(projectile_id)
	if arrow == null:
		return
	var segment: int = maxi(tick - arrow.spawn_tick, 0)
	arrow.despawn_reason = reason
	if reason == NetProtocol.DespawnReason.IMPACT:
		# The first segment, with hit_from_inside (like the server and like the player's own arrow): otherwise,
		# one leaving from inside a body that is drawn does not see it and passes through it for a whole tick.
		arrow.end_n = float(segment) + _segment_fraction(arrow, segment, segment == 0)
		_stats["impacts"] += 1
	else:
		arrow.end_n = float(segment)
		_stats["expired"] += 1


# --- Drawing ------------------------------------------------------------------------------------

## Places all the arrows: the local player's at the predicted instant [param own_time] and the remote
## ones at the draw instant [param render_time] (ticks with fraction), and removes those that hit.
## [method _process] calls it with the clocks; the tests, with exact instants.
func draw(own_time: float, render_time: float) -> void:
	_last_own_time = own_time
	_last_render_time = render_time
	var kept: Array[Arrow] = []
	for arrow: Arrow in _arrows:
		if _should_retire(arrow, own_time, render_time):
			_free_node(arrow)
			continue
		_place(arrow, own_time if arrow.predicted else render_time)
		kept.append(arrow)
	_arrows = kept


## The live arrows.
func get_arrows() -> Array[Arrow]:
	return _arrows.duplicate()


## The arrow with network id [param net_id] (null if absent or only predicted).
func find_arrow(net_id: int) -> Arrow:
	if net_id == 0:
		return null
	for arrow: Arrow in _arrows:
		if arrow.net_id == net_id:
			return arrow
	return null


## The player's own arrows the server has not yet confirmed.
func get_unconfirmed() -> Array[Arrow]:
	var found: Array[Arrow] = []
	for arrow: Arrow in _arrows:
		if arrow.predicted and not arrow.confirmed:
			found.append(arrow)
	return found


func get_live_count() -> int:
	return _arrows.size()


## Counts since it was created: [code]predicted[/code] (predicted arrows created),
## [code]substituted[/code] (replaced by the server's), [code]own_from_server[/code] (own arrows with no
## match), [code]remote[/code], [code]rejected[/code] (predicted arrows removed without a SPAWN),
## [code]impacts[/code] and [code]expired[/code] (DESPAWN 4 and 5), [code]stuck[/code] and
## [code]hidden[/code] (own arrows stopped in the world or hidden in a capsule) and [code]live[/code].
func get_stats() -> Dictionary:
	var stats: Dictionary = _stats.duplicate()
	stats["live"] = _arrows.size()
	return stats


## Removes all the arrows.
func clear() -> void:
	for arrow: Arrow in _arrows:
		_free_node(arrow)
	_arrows.clear()
	_server_tick = -1


# --- Internal -----------------------------------------------------------------------------------

func _add(arrow: Arrow) -> void:
	_arrows.append(arrow)


func _set_ballistics(arrow: Arrow, projectile_id: int, projectile: ProjectileTicks, p0: Vector3,
		v0: Vector3) -> void:
	arrow.projectile_id = projectile_id
	arrow.gravity = projectile.gravity
	arrow.radius = projectile.radius_m
	arrow.lifetime_ticks = projectile.lifetime_ticks
	arrow.p0 = p0
	arrow.v0 = v0


func _fill_from_spawn(arrow: Arrow, spawn: NetMessages.EntitySpawn, projectile: ProjectileTicks) -> void:
	arrow.net_id = spawn.net_id
	arrow.owner_id = spawn.owner_id
	arrow.realm = spawn.realm
	arrow.source = spawn.source
	arrow.volley_index = spawn.volley_index
	arrow.spawn_tick = spawn.spawn_tick
	arrow.harmless = spawn.is_harmless()
	arrow.confirmed = true
	_set_ballistics(arrow, spawn.projectile_def_id, projectile, spawn.origin, spawn.velocity)


# The predicted arrow that corresponds to the player's own SPAWN [param spawn]: same source and fan
# index, unconfirmed and with a tick within input_buffer_ticks; the one with the closest tick.
func _find_pair(spawn: NetMessages.EntitySpawn) -> Arrow:
	var window: int = CombatCatalog.rules().input_buffer_ticks
	var best: Arrow = null
	for arrow: Arrow in _arrows:
		if not arrow.predicted or arrow.confirmed or arrow.source != spawn.source \
				or arrow.volley_index != spawn.volley_index:
			continue
		var gap: int = absi(arrow.spawn_tick - spawn.spawn_tick)
		if gap <= window and (best == null or gap < absi(best.spawn_tick - spawn.spawn_tick)):
			best = arrow
	return best


# Adopts the server's ballistics with a visual offset that decays.
func _substitute(arrow: Arrow, spawn: NetMessages.EntitySpawn, projectile: ProjectileTicks) -> void:
	var time: float = _last_own_time
	var before: Vector3 = _visible_position(arrow, time)
	_fill_from_spawn(arrow, spawn, projectile)
	arrow.stuck_n = -1.0
	arrow.hidden_n = -1.0
	arrow.checked_segments = 0
	_advance_collision(arrow, time - float(arrow.spawn_tick))
	var after: Vector3 = _visible_position(arrow, time)
	arrow.offset = before - after if arrow.visible else Vector3.ZERO
	arrow.offset_time = time


# Position the arrow would have at instant [param time] (without the offset).
func _visible_position(arrow: Arrow, time: float) -> Vector3:
	var n: float = maxf(time - float(arrow.spawn_tick), 0.0)
	if arrow.stuck_n >= 0.0:
		n = minf(n, arrow.stuck_n)
	return arrow.position_at(n)


func _should_retire(arrow: Arrow, own_time: float, render_time: float) -> bool:
	var time: float = own_time if arrow.predicted else render_time
	var n: float = time - float(arrow.spawn_tick)
	if arrow.end_n >= 0.0 and n >= arrow.end_n:
		return true
	if arrow.predicted and not arrow.confirmed:
		if _is_rejected(arrow, own_time):
			_stats["rejected"] += 1
			return true
		return false
	return n >= float(arrow.lifetime_ticks + LIFETIME_GRACE_TICKS)


# A predicted arrow with no SPAWN: the server has already simulated its tick plus the input buffer and a
# margin without sending it (using the tick of the last snapshot, which tracks the current RTT; with no
# snapshots, the input's RTT), or its whole lifetime has already passed.
func _is_rejected(arrow: Arrow, own_time: float) -> bool:
	var waited: float = own_time - float(arrow.created_tick)
	if waited >= float(arrow.lifetime_ticks + LIFETIME_GRACE_TICKS):
		return true
	if _server_tick >= 0:
		return _server_tick - arrow.created_tick \
				> CombatCatalog.rules().input_buffer_ticks + REJECT_EXTRA_TICKS
	return waited > float(_rtt_ticks + REJECT_EXTRA_TICKS)


func _place(arrow: Arrow, time: float) -> void:
	var n: float = time - float(arrow.spawn_tick)
	if n < 0.0 and not arrow.predicted:
		# A remote one has not yet left at what is being drawn.
		arrow.visible = false
		arrow.drawn_n = n
		_sync_node(arrow)
		return
	n = maxf(n, 0.0)
	if arrow.predicted:
		_advance_collision(arrow, n)
	var shown_n: float = n
	if arrow.stuck_n >= 0.0:
		shown_n = minf(shown_n, arrow.stuck_n)
	arrow.visible = arrow.hidden_n < 0.0 or n < arrow.hidden_n
	arrow.drawn_n = shown_n
	arrow.drawn_position = arrow.position_at(shown_n) + arrow.offset_at(time)
	_sync_node(arrow)


# Tests the segments [pos(k), pos(k + 1)] the arrow has already started to travel against the local
# world and the drawn capsules of the hostiles: it sticks into the world or hides in a capsule.
func _advance_collision(arrow: Arrow, n: float) -> void:
	if arrow.stuck_n >= 0.0 or arrow.hidden_n >= 0.0:
		return
	var last: int = mini(floori(n), arrow.lifetime_ticks)
	var tested: int = 0
	while arrow.checked_segments <= last and tested < MAX_SEGMENTS_PER_DRAW:
		var k: int = arrow.checked_segments
		arrow.checked_segments += 1
		tested += 1
		var hit: Vector2 = _segment_hit(arrow, k, k == 0)
		if hit.x < 0.0:
			continue
		if hit.y > 0.5:
			arrow.hidden_n = float(k) + hit.x
			_stats["hidden"] += 1
		else:
			arrow.stuck_n = float(k) + hit.x
			_stats["stuck"] += 1
		return


# Fraction (0..1) of segment [param k] where the arrow touches something along its own ray, or 1 if it
# touches nothing.
func _segment_fraction(arrow: Arrow, k: int, from_inside: bool) -> float:
	var hit: Vector2 = _segment_hit(arrow, k, from_inside)
	return hit.x if hit.x >= 0.0 else 1.0


# The first collision of segment [param k]: x = fraction (-1 if nothing), y = 1 if it is the capsule of
# a drawn hostile and 0 if it is the world.
func _segment_hit(arrow: Arrow, k: int, from_inside: bool) -> Vector2:
	var a: Vector3 = arrow.position_at(float(k))
	var b: Vector3 = arrow.position_at(float(k + 1))
	var best: float = INF
	var kind: float = 0.0
	var space: PhysicsDirectSpaceState3D = _space()
	if space != null and not a.is_equal_approx(b):
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(a, b,
				HitShapes.LINE_OF_SIGHT_MASK)
		query.hit_from_inside = from_inside
		var result: Dictionary = space.intersect_ray(query)
		if not result.is_empty():
			best = clampf(a.distance_to(result["position"] as Vector3) / a.distance_to(b), 0.0, 1.0)
	for feet: Vector3 in _hostile_feet(arrow.owner_id, arrow.realm):
		var fraction: float = HitShapes.segment_capsule_fraction(a, b, feet,
				HitShapes.CAPSULE_RADIUS + arrow.radius, HitShapes.CAPSULE_HEIGHT)
		if fraction >= 0.0 and fraction < best:
			best = fraction
			kind = 1.0
	return Vector2(best if best < INF else -1.0, kind)


# Feet of the remotes that are drawn, alive and hostile to the shooter's realm [param shooter_realm]
# ([param shooter_id]), as they look right now. The realm is the arrow's (the SPAWN's), not that of the
# shooter's view: that one may be missing (it left interest with its arrow in the air) and realm 0 is
# the Hollow's, hostile to everyone (H5 review).
func _hostile_feet(shooter_id: int, shooter_realm: int) -> PackedVector3Array:
	var feet := PackedVector3Array()
	if _remote_world == null or not is_instance_valid(_remote_world):
		return feet
	var own_shooter: bool = shooter_id == 0 or shooter_id == _own_id
	for view: RemotePlayerView in _remote_world.get_views():
		if view.get_net_id() == shooter_id or not view.is_drawn() \
				or view.get_drawn_health_q() == EntityRecord.HEALTH_Q_DEAD:
			continue
		if not FactionRules.can_damage(shooter_realm, view.get_realm(), _zone_id):
			continue
		feet.append(view.get_drawn_position())
	# A remote arrow can also hit the local player (it is seen arriving at them).
	if not own_shooter and is_instance_valid(_character) \
			and FactionRules.can_damage(shooter_realm, _own_realm, _zone_id):
		feet.append(_character.global_position if _character.is_inside_tree() else _character.position)
	return feet


func _space() -> PhysicsDirectSpaceState3D:
	if space_override != null:
		return space_override
	if is_instance_valid(_character) and _character.is_inside_tree():
		return _character.get_world_3d().direct_space_state
	if is_inside_tree():
		return get_world_3d().direct_space_state
	return null


func _sync_node(arrow: Arrow) -> void:
	if not install_visuals or not is_inside_tree():
		return
	if arrow.node == null:
		arrow.node = MeshInstance3D.new()
		arrow.node.name = "Flecha%d" % arrow.net_id if arrow.net_id != 0 else "FlechaPredicha"
		arrow.node.mesh = _arrow_mesh()
		arrow.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		arrow.node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(arrow.node)
	arrow.node.visible = arrow.visible
	if not arrow.visible:
		return
	var velocity: Vector3 = arrow.velocity_at(arrow.drawn_n)
	var forward: Vector3 = velocity.normalized() if not velocity.is_zero_approx() else Vector3.FORWARD
	var up: Vector3 = Vector3.UP if absf(forward.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	arrow.node.global_transform = Transform3D(Basis.looking_at(forward, up), arrow.drawn_position)


func _free_node(arrow: Arrow) -> void:
	if arrow.node != null and is_instance_valid(arrow.node):
		if arrow.node.get_parent() != null:
			arrow.node.get_parent().remove_child(arrow.node)
		arrow.node.queue_free()
	arrow.node = null


func _arrow_mesh() -> BoxMesh:
	if _mesh == null:
		_mesh = BoxMesh.new()
		_mesh.size = Vector3(ARROW_THICKNESS, ARROW_THICKNESS, ARROW_LENGTH)
		var material := StandardMaterial3D.new()
		material.albedo_color = ARROW_COLOR
		material.roughness = 0.8
		_mesh.material = material
	return _mesh
