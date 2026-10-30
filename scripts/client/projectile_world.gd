class_name ProjectileWorld
extends Node3D
## Las flechas del cliente (docs/habilidades.md, sección 6.2; CMB-22): la propia, predicha y sustituida
## por la del servidor, y las de los demás, que llegan con su balística en un ENTITY_SPAWN de kind 3 y el
## cliente vuela él solo con [method Ballistics.position] (el snapshot no las lleva, sección 5.3).
## [br][br]
## [b]Predicha.[/b] [ClientPrediction] emite [signal ClientPrediction.stepped] tras [b]cada[/b] paso
## (un tick de física puede dar dos); en el que es el compromiso de un ataque o una habilidad con
## proyectil ([method ProjectileLaunch.from_state]) se crean sus flechas con la entrada de ese tick, el
## rayo canónico ([AimRay]) contra el mundo local y las cápsulas de los remotos hostiles [b]tal como se
## dibujan[/b] (también para la convergencia) y la misma cuantización que el servidor
## ([method ProjectileLaunch.launch]). Se dibuja en el tiempo predicho (el del personaje local:
## [code]tick predicho − 1 + fracción[/code]); se para en el mundo con su propio rayo (el primer segmento
## con [code]hit_from_inside[/code]) y se oculta al tocar la cápsula dibujada de un enemigo, sin número:
## el marcador y el número llegan con el HIT del servidor, como en el cuerpo a cuerpo.
## [br][br]
## [b]Sustitución.[/b] El SPAWN con [code]owner[/code] propio se empareja con la predicha de la misma
## fuente y [code]volley_index[/code] cuyo tick difiera como mucho [member CombatRules.input_buffer_ticks];
## se adoptan su [code]p0[/code], [code]v0[/code] y [code]spawn_tick[/code] con un desfase visual que
## decae en [constant OFFSET_DECAY_TICKS] ticks. Sin pareja se dibuja la del servidor (en el tiempo
## predicho, como la propia). Una predicha sin SPAWN cuando el servidor ya va
## [member CombatRules.input_buffer_ticks] + [constant REJECT_EXTRA_TICKS] ticks por delante de su tick (el
## tick del último snapshot, [method on_server_tick]) se retira: el servidor la rechazó. Se mide con el tick del
## servidor y no con el RTT, que cambia durante la sesión (revisión de H5); sin ningún snapshot todavía, con el
## RTT de la entrada.
## [br][br]
## [b]Remotas.[/b] Aparecen cuando el tick de dibujo alcanza su [code]spawn_tick[/code] y se dibujan en
## [code]pos(render_tick + fracción − spawn_tick)[/code]. Con DESPAWN 4 (impacto) se retiran en
## [code]despawn_tick + f[/code], con [code]f[/code] la fracción de su propio rayo (mundo y cápsulas
## dibujadas de los hostiles al reino del tirador que trae el SPAWN) en el último segmento, o 1 si no toca
## nada: así llegan al muro o al blanco. Si el último es el primero, con [code]hit_from_inside[/code], como el
## servidor: la flecha que sale de dentro de la puerta cerrada se queda en su boca. Con DESPAWN 5
## (caducada), en [code]despawn_tick[/code]. La propia se retira con la misma regla en su tiempo.
## [br][br]
## [NetClient] la crea, la mete en la zona con el [RemoteWorld] y le pasa los pasos y los mensajes. Las
## pruebas llaman a [method on_stepped], [method on_spawn], [method on_despawn] y [method draw] con
## instantes exactos. Solo cliente.

## Ticks en los que decae el desfase visual al sustituir la predicha por la del servidor.
const OFFSET_DECAY_TICKS: float = 6.0
## Ticks de más, sobre el RTT, que se espera el SPAWN de una predicha antes de darla por rechazada.
const REJECT_EXTRA_TICKS: int = 30
## Ticks de más, sobre su vida, que se guarda una flecha confirmada si no llega su DESPAWN.
const LIFETIME_GRACE_TICKS: int = 60
## Medidas (m) de la flecha provisional (una caja larga a lo largo de la velocidad).
const ARROW_LENGTH: float = 0.75
const ARROW_THICKNESS: float = 0.035
const ARROW_COLOR: Color = Color(0.55, 0.42, 0.25, 1.0)
## Segmentos que se prueban como mucho por flecha y dibujo (una flecha vive 120 ticks).
const MAX_SEGMENTS_PER_DRAW: int = 256

## Una flecha.
class Arrow:
	## Id de red (0 mientras es solo predicha).
	var net_id: int = 0
	var owner_id: int = 0
	## Reino del tirador (el del SPAWN; el del jugador local en la predicha): quién es hostil a la flecha.
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
	## true: se dibuja en el tiempo predicho (la del jugador local).
	var predicted: bool = false
	## true: el servidor la ha mandado (SPAWN).
	var confirmed: bool = false
	## Tick predicho en que se creó la predicha (para darla por rechazada).
	var created_tick: int = 0
	## Desfase visual al sustituirla (se suma a la posición y decae) y el instante en que se fijó.
	var offset: Vector3 = Vector3.ZERO
	var offset_time: float = 0.0
	## [code]n[/code] (ticks de vuelo, con fracción) en que se clava en el mundo o toca una cápsula
	## dibujada (-1 = aún no). Primer segmento aún sin probar.
	var stuck_n: float = -1.0
	var hidden_n: float = -1.0
	var checked_segments: int = 0
	## [code]n[/code] en que se retira (-1 = sin DESPAWN todavía) y por qué.
	var end_n: float = -1.0
	var despawn_reason: int = 0
	## Lo dibujado en el último [method draw].
	var drawn_position: Vector3 = Vector3.ZERO
	var drawn_n: float = 0.0
	var visible: bool = false
	var node: MeshInstance3D = null

	## Posición tras [param n] ticks de vuelo (sin el desfase).
	func position_at(n: float) -> Vector3:
		return Ballistics.position(p0, v0, gravity, n)

	## Velocidad tras [param n] ticks de vuelo.
	func velocity_at(n: float) -> Vector3:
		return v0 + Vector3(0.0, -gravity * n / Ballistics.TICK_RATE, 0.0)

	## Desfase visual en el instante [param time].
	func offset_at(time: float) -> Vector3:
		if offset == Vector3.ZERO:
			return Vector3.ZERO
		return offset * clampf(1.0 - (time - offset_time) / OFFSET_DECAY_TICKS, 0.0, 1.0)


## true: a cada flecha se le pone su malla provisional. Por defecto, solo si hay pantalla (un bot
## headless solo lleva la cuenta).
var install_visuals: bool = DisplayServer.get_name() != "headless"
## Solo pruebas: si es válido, da el espacio de física del mundo local (si no, el de este nodo).
var space_override: PhysicsDirectSpaceState3D = null

var _clock: InterpolationClock = null
var _remote_world: RemoteWorld = null
var _prediction: ClientPrediction = null
var _character: PlayerCharacter = null
var _own_id: int = 0
var _own_realm: int = NetProtocol.Realm.NONE
var _zone_id: StringName = &""
var _rtt_ticks: int = 0
# Tick del último snapshot del servidor (-1 = aún ninguno): para dar por rechazada una predicha.
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
	# Se coloca cada fotograma en su instante exacto, como los remotos.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	process_priority = -5


## Reloj de dibujo de los remotos y el mundo de los remotos (sus cápsulas dibujadas).
func setup(clock: InterpolationClock, remote_world: RemoteWorld) -> void:
	_clock = clock
	_remote_world = remote_world


## El jugador local: su id de red, su reino y la zona (quién es hostil, [FactionRules]), su personaje
## (el mundo de física local) y su predicción (el tiempo predicho y [signal ClientPrediction.stepped],
## que conecta), y el RTT en ticks (para dar por rechazada una predicha mientras no llegue ningún snapshot).
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


# --- Entradas -----------------------------------------------------------------------------------

## El tick [param tick] del snapshot más nuevo que ha llegado ([NetClient] lo pasa con cada uno): hasta dónde
## ha simulado ya el servidor. Una predicha cuyo tick se queda más de
## [member CombatRules.input_buffer_ticks] + [constant REJECT_EXTRA_TICKS] ticks por detrás sin SPAWN se
## retira (el SPAWN va por el canal fiable y puede llegar algo después que el snapshot de su tick).
func on_server_tick(tick: int) -> void:
	_server_tick = maxi(_server_tick, tick)


## Un paso de predicción ([signal ClientPrediction.stepped]): si [param tick] es el compromiso de un
## disparo, crea sus flechas predichas con la entrada [param input] y los pies de [param state].
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


## ENTITY_SPAWN de un proyectil ([signal NetClient.projectile_spawned]). Si es del jugador local, sustituye
## a su predicha (o se dibuja ella, sin pareja); si no, es una remota.
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


## ENTITY_DESPAWN de un proyectil ([signal NetClient.projectile_despawned]): fija cuándo se retira.
func on_despawn(projectile_id: int, tick: int, reason: int) -> void:
	var arrow: Arrow = find_arrow(projectile_id)
	if arrow == null:
		return
	var segment: int = maxi(tick - arrow.spawn_tick, 0)
	arrow.despawn_reason = reason
	if reason == NetProtocol.DespawnReason.IMPACT:
		# El primer segmento, con hit_from_inside (como el servidor y como la propia): si no, la que sale de dentro
		# de un cuerpo de vista no lo ve y lo atraviesa un tick entero.
		arrow.end_n = float(segment) + _segment_fraction(arrow, segment, segment == 0)
		_stats["impacts"] += 1
	else:
		arrow.end_n = float(segment)
		_stats["expired"] += 1


# --- Dibujo -------------------------------------------------------------------------------------

## Coloca todas las flechas: las del jugador local en el instante predicho [param own_time] y las
## remotas en el de dibujo [param render_time] (ticks con fracción), y retira las que tocan.
## [method _process] lo llama con los relojes; las pruebas, con instantes exactos.
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


## Las flechas vivas.
func get_arrows() -> Array[Arrow]:
	return _arrows.duplicate()


## La flecha de id de red [param net_id] (null si no está o es solo predicha).
func find_arrow(net_id: int) -> Arrow:
	if net_id == 0:
		return null
	for arrow: Arrow in _arrows:
		if arrow.net_id == net_id:
			return arrow
	return null


## Las flechas propias que aún no ha confirmado el servidor.
func get_unconfirmed() -> Array[Arrow]:
	var found: Array[Arrow] = []
	for arrow: Arrow in _arrows:
		if arrow.predicted and not arrow.confirmed:
			found.append(arrow)
	return found


func get_live_count() -> int:
	return _arrows.size()


## Cuentas desde que existe: [code]predicted[/code] (flechas predichas creadas),
## [code]substituted[/code] (sustituidas por la del servidor), [code]own_from_server[/code] (propias sin
## pareja), [code]remote[/code], [code]rejected[/code] (predichas retiradas sin SPAWN), [code]impacts[/code]
## y [code]expired[/code] (DESPAWN 4 y 5), [code]stuck[/code] y [code]hidden[/code] (propias paradas en el
## mundo u ocultas en una cápsula) y [code]live[/code].
func get_stats() -> Dictionary:
	var stats: Dictionary = _stats.duplicate()
	stats["live"] = _arrows.size()
	return stats


## Quita todas las flechas.
func clear() -> void:
	for arrow: Arrow in _arrows:
		_free_node(arrow)
	_arrows.clear()
	_server_tick = -1


# --- Interno ------------------------------------------------------------------------------------

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


# La predicha que corresponde al SPAWN propio [param spawn]: misma fuente e índice del abanico, sin
# confirmar y con el tick a menos de input_buffer_ticks; la de tick más cercano.
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


# Adopta la balística del servidor con un desfase visual que decae.
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


# Posición que tendría la flecha en el instante [param time] (sin el desfase).
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


# Una predicha sin SPAWN: el servidor ya ha simulado su tick más el búfer de entradas y un margen sin mandarlo
# (con el tick del último snapshot, que sigue al RTT de ahora; sin snapshots, el RTT de la entrada), o ya ha
# pasado su vida entera.
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
		# Una remota aún no ha salido en lo que se dibuja.
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


# Prueba los segmentos [pos(k), pos(k + 1)] que la flecha ya ha empezado a recorrer contra el mundo
# local y las cápsulas dibujadas de los hostiles: se clava en el mundo o se oculta en una cápsula.
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


# Fracción (0..1) del segmento [param k] donde la flecha toca algo por su propio rayo, o 1 si no toca.
func _segment_fraction(arrow: Arrow, k: int, from_inside: bool) -> float:
	var hit: Vector2 = _segment_hit(arrow, k, from_inside)
	return hit.x if hit.x >= 0.0 else 1.0


# El primer choque del segmento [param k]: x = fracción (-1 si nada), y = 1 si es una cápsula de un
# hostil dibujado y 0 si es el mundo.
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


# Pies de los remotos que se dibujan, vivos y hostiles al reino [param shooter_realm] del tirador
# [param shooter_id], tal como se ven ahora. El reino es el de la flecha (el del SPAWN), no el de la vista del
# tirador: esa puede no estar (salió del interés con su flecha en el aire) y el reino 0 es el de los Huecos,
# hostiles a todos (revisión de H5).
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
	# Una flecha remota también puede dar al jugador local (se ve llegar a él).
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
