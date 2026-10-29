class_name Nameplates
extends Control
## Placas de nombre y barra de vida sobre los jugadores remotos (UI-07, UI-13). Control 2D que cubre
## la pantalla del [HUD]: en cada fotograma proyecta con la cámara ([method Camera3D.unproject_position])
## la cabeza de cada remoto, en la posición interpolada con la que se le dibuja, y coloca una
## [Nameplate] de un pool.
## [br][br]
## [b]Qué se enseña[/b]:
## [br]- [b]Nunca el propio personaje[/b] (el [RemoteWorld] solo tiene a los demás).
## [br]- [b]Aliados[/b] (mismo reino): nombre con el color de su reino y barra de vida, hasta
## [constant ALLY_RANGE] m, con un fundido en los últimos metros.
## [br]- [b]Enemigos[/b]: el nombre solo cuando la retícula les apunta ([method
## CameraRig.get_aim_ray] contra su cápsula); la barra de vida mientras están bajo la retícula o
## los dañó un golpe en los últimos [constant DAMAGED_SECONDS] s ([method mark_damaged]).
## Sin ninguna de las dos, no hay placa.
## [br]- Los muertos ([code]health_q[/code] a 0) y los que no se están dibujando, nada.
## [br][br]
## [b]Oclusión.[/b] Un rayo de la cámara a la cabeza contra la capa del mundo ([method
## HitShapes.is_ray_clear]) oculta la placa de quien está detrás de un muro. Para no lanzar un rayo
## por jugador y fotograma, cada jugador repite su rayo cada [constant OCCLUSION_INTERVAL_FRAMES]
## fotogramas (escalonados) y mientras tanto se usa el último resultado.
## [br][br]
## El pool tiene [constant MAX_PLATES] placas: si hay más candidatas se enseñan las más cercanas.
## El tiempo lo lleva [method refresh] (el HUD lo llama desde [method _process]).

## Distancia máxima (m) a la que se ve la placa de un aliado y comienzo del fundido.
const ALLY_RANGE: float = 40.0
const ALLY_FADE_START: float = 30.0
## Distancia máxima (m) a la que se apunta a un enemigo con la retícula o se le enseña herido.
const ENEMY_RANGE: float = 70.0
## Color del nombre de los miembros del grupo (provisional, el mismo azul del canal de grupo del chat).
const PARTY_COLOR: Color = Color(0.4, 0.7, 1.0, 1.0)
## Segundos que un enemigo dañado conserva la barra de vida.
const DAMAGED_SECONDS: float = 5.0
## Placas del pool.
const MAX_PLATES: int = 32
## Fotogramas entre dos rayos de oclusión de un mismo jugador.
const OCCLUSION_INTERVAL_FRAMES: int = 6
## Dimensiones (m) de la cápsula contra la que se comprueba la retícula (algo más ancha que la
## real, para apuntar con holgura) y altura de la cabeza a la que se ancla la placa.
const AIM_RADIUS: float = 0.6
const AIM_HEIGHT: float = 1.9
const HEAD_HEIGHT: float = 2.05
## Margen (m) del rayo de oclusión: un impacto más cerca de la cabeza que esto no la tapa.
const OCCLUSION_MARGIN: float = 0.4

var _world: RemoteWorld = null
var _camera_rig: CameraRig = null
var _own_realm: int = NetProtocol.Realm.NONE
# Grupo del jugador local (SOC-08): sus miembros llevan el nombre con el color de grupo.
var _party: PartyState = null
var _plates: Array[Nameplate] = []
# net_id -> placa asignada en el último fotograma.
var _assigned: Dictionary[int, Nameplate] = {}
# net_id -> segundos (reloj interno) del último daño recibido.
var _damaged_at: Dictionary[int, float] = {}
# net_id -> el último resultado del rayo de oclusión.
var _occluded: Dictionary[int, bool] = {}
var _clock: float = 0.0
var _frame: int = 0
var _targeted_id: int = 0
var _ray_count: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Opción «Placas de nombre» de los ajustes del jugador.
	ClientSettings.bind_visibility(self, ClientSettings.NAMEPLATES)


func _process(delta: float) -> void:
	refresh(delta)


## Conecta las placas con los remotos ([param world]), la cámara ([param camera_rig]) y el reino
## del jugador local ([param own_realm], un [enum NetProtocol.Realm]): los de ese reino son aliados.
func setup(world: RemoteWorld, camera_rig: CameraRig, own_realm: int) -> void:
	_world = world
	_camera_rig = camera_rig
	_own_realm = own_realm
	_occluded.clear()
	_damaged_at.clear()


## Da a las placas el grupo del jugador local ([param party]): el nombre de sus miembros se pinta con
## [constant PARTY_COLOR] en lugar del color del reino (SOC-08). null lo quita.
func set_party(party: PartyState) -> void:
	_party = party


## El grupo que se ha dado a las placas ([method set_party]), o null.
func get_party() -> PartyState:
	return _party


## Apunta que [param net_id] recibió un golpe ahora: su barra de vida se ve [constant
## DAMAGED_SECONDS] s aunque no se le apunte.
func mark_damaged(net_id: int) -> void:
	_damaged_at[net_id] = _clock


## Actualiza las placas un fotograma de [param delta] segundos: elige qué remotos tienen placa, las
## coloca en la pantalla y devuelve al pool las que sobran.
func refresh(delta: float) -> void:
	_clock += delta
	_frame += 1
	_assigned.clear()
	_targeted_id = 0
	var camera: Camera3D = _camera_rig.get_camera() if is_instance_valid(_camera_rig) else null
	if _world == null or not is_instance_valid(_world) or camera == null \
			or not camera.is_inside_tree():
		_release_from(0)
		return
	var candidates: Array[Dictionary] = _collect_candidates(camera)
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance"]) < float(b["distance"]))
	var used: int = 0
	for candidate: Dictionary in candidates:
		if used >= MAX_PLATES:
			break
		var plate: Nameplate = _plate_at(used)
		_show(plate, candidate, camera)
		if plate.visible:
			_assigned[int(candidate["net_id"])] = plate
			used += 1
	_release_from(used)
	_forget_gone(candidates)


## Placas que se ven ahora.
func get_visible_count() -> int:
	return _assigned.size()


## La placa de [param net_id], o null si ahora no tiene.
func get_plate_for(net_id: int) -> Nameplate:
	return _assigned.get(net_id)


## Placas creadas (pool): nunca más de [constant MAX_PLATES].
func get_pool_size() -> int:
	return _plates.size()


## Remoto al que apunta la retícula ahora (0 si a ninguno).
func get_targeted_id() -> int:
	return _targeted_id


## Rayos de oclusión lanzados desde que existe (para comprobar que se espacian).
func get_ray_count() -> int:
	return _ray_count


## true si [param net_id] está dañado hace menos de [constant DAMAGED_SECONDS] s.
func was_damaged_recently(net_id: int) -> bool:
	return _damaged_at.has(net_id) and _clock - float(_damaged_at[net_id]) <= DAMAGED_SECONDS


# --- Candidatos -------------------------------------------------------------------------------

# Remotos que se están dibujando y están vivos, con su distancia a la cámara y sus datos.
func _collect_candidates(camera: Camera3D) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var eye: Vector3 = camera.global_position
	var aim: Dictionary = _camera_rig.get_aim_ray()
	var aim_enabled: bool = not _camera_rig.is_cursor_free()
	var best_aim_distance: float = INF
	for view: RemotePlayerView in _world.get_views():
		if not view.is_drawn() or view.get_drawn_health_q() == EntityRecord.HEALTH_Q_DEAD:
			continue
		var feet: Vector3 = view.get_drawn_position()
		var distance: float = eye.distance_to(feet + Vector3(0.0, 1.0, 0.0))
		var net_id: int = view.get_net_id()
		var ally: bool = _is_ally(view)
		var occluded: bool = _is_occluded(net_id, eye, feet + Vector3(0.0, HEAD_HEIGHT, 0.0),
				distance)
		var aimed: bool = false
		if aim_enabled and not occluded and not ally and distance <= ENEMY_RANGE:
			aimed = _is_aimed_at(aim, feet)
		if aimed:
			var along: float = (feet - Vector3(aim["origin"])).dot(Vector3(aim["direction"]))
			if along < best_aim_distance:
				best_aim_distance = along
				_targeted_id = net_id
		result.append({
			"view": view, "net_id": net_id, "distance": distance, "ally": ally,
			"occluded": occluded, "aimed": aimed, "feet": feet,
		})
	# Solo uno es «el apuntado»: el más cercano a lo largo del rayo.
	for candidate: Dictionary in result:
		candidate["aimed"] = int(candidate["net_id"]) == _targeted_id
	return result


func _is_ally(view: RemotePlayerView) -> bool:
	return _own_realm != NetProtocol.Realm.NONE and view.get_realm() == _own_realm \
			and view.get_kind() == NetProtocol.EntityKind.PLAYER


func _is_aimed_at(aim: Dictionary, feet: Vector3) -> bool:
	var origin: Vector3 = aim["origin"]
	var direction: Vector3 = aim["direction"]
	return HitShapes.segment_hits_capsule(origin, origin + direction * ENEMY_RANGE, feet,
			AIM_RADIUS, AIM_HEIGHT)


# Oclusión con un rayo por jugador cada OCCLUSION_INTERVAL_FRAMES fotogramas (escalonados por id).
func _is_occluded(net_id: int, eye: Vector3, head: Vector3, distance: float) -> bool:
	var known: bool = _occluded.has(net_id)
	if known and (_frame + net_id) % OCCLUSION_INTERVAL_FRAMES != 0:
		return bool(_occluded[net_id])
	var space: PhysicsDirectSpaceState3D = get_viewport().get_world_3d().direct_space_state \
			if is_inside_tree() else null
	if space == null:
		_occluded[net_id] = false
		return false
	_ray_count += 1
	# Se corta antes de la cabeza para que el suelo o la pared que pisa el jugador no la tapen.
	var toward: Vector3 = (head - eye)
	var length: float = toward.length()
	var blocked: bool = false
	if length > OCCLUSION_MARGIN:
		var target: Vector3 = eye + toward * ((length - OCCLUSION_MARGIN) / length)
		blocked = not HitShapes.is_ray_clear(space, eye, target)
	_occluded[net_id] = blocked
	return blocked


# --- Placas -----------------------------------------------------------------------------------

# Decide qué enseña la placa de un candidato y la coloca; si no toca verla, la deja oculta.
func _show(plate: Nameplate, candidate: Dictionary, camera: Camera3D) -> void:
	var view: RemotePlayerView = candidate["view"]
	var net_id: int = candidate["net_id"]
	var distance: float = candidate["distance"]
	var ally: bool = candidate["ally"]
	var show_name: bool = false
	var show_bar: bool = false
	var alpha: float = 1.0
	if bool(candidate["occluded"]):
		plate.release()
		return
	if ally:
		if distance > ALLY_RANGE:
			plate.release()
			return
		show_name = true
		show_bar = true
		alpha = 1.0 - smoothstep(ALLY_FADE_START, ALLY_RANGE, distance)
	else:
		var aimed: bool = candidate["aimed"]
		var damaged: bool = was_damaged_recently(net_id) and distance <= ENEMY_RANGE
		if not aimed and not damaged:
			plate.release()
			return
		show_name = aimed
		show_bar = true
	var head: Vector3 = Vector3(candidate["feet"]) + Vector3(0.0, HEAD_HEIGHT, 0.0)
	if camera.is_position_behind(head):
		plate.release()
		return
	var fraction: float = EntityRecord.health_fraction(view.get_drawn_health_q())
	var realm_color: Color = RealmCatalog.color_of(RealmCatalog.id_of_code(view.get_realm()))
	if ally and _party != null and _party.has_member(net_id):
		realm_color = PARTY_COLOR
	plate.configure(net_id, view.get_display_name(), realm_color, show_name, show_bar, fraction,
			ally, alpha)
	plate.place(camera.unproject_position(head))
	plate.visible = true


func _plate_at(index: int) -> Nameplate:
	while _plates.size() <= index and _plates.size() < MAX_PLATES:
		var plate := Nameplate.new()
		plate.name = "Placa%d" % _plates.size()
		add_child(plate)
		_plates.append(plate)
	return _plates[index]


# Esconde las placas del pool desde el índice [param first] en adelante.
func _release_from(first: int) -> void:
	for i: int in range(first, _plates.size()):
		_plates[i].release()


# Olvida la oclusión y el daño de quien ya no está.
func _forget_gone(candidates: Array[Dictionary]) -> void:
	var present: Dictionary[int, bool] = {}
	for candidate: Dictionary in candidates:
		present[int(candidate["net_id"])] = true
	for net_id: int in _occluded.keys():
		if not present.has(net_id):
			_occluded.erase(net_id)
	for net_id: int in _damaged_at.keys():
		if _clock - float(_damaged_at[net_id]) > DAMAGED_SECONDS * 4.0:
			_damaged_at.erase(net_id)
