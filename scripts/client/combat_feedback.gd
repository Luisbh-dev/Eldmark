class_name CombatFeedback
extends Node
## Reparte la sensación de combate en el cliente (docs/combate.md, sección 8; UI-12, ART-09 básico,
## CMB-11). Recibe los ENTITY_EVENT [b]ya temporizados[/b] por [NetClient] ([signal
## NetClient.combat_event]: los propios al llegar, los ajenos en su tick de dibujo) y los reparte:
## [br]- [b]Golpes propios confirmados[/b] ([method handle_event], HIT con el jugador local de atacante):
## marcador de impacto ([HitMarker]) y número de daño ([DamageNumbers]) con su variante, y el
## [DpsMeter]. Un golpe no confirmado por el servidor no produce nada: no se predice.
## [br]- [b]Daño recibido[/b]: sacudida de cámara ([method CameraRig.add_shake]), número rojo y la
## señal [signal damage_taken] (de la que cuelgan los arcos de dirección del HUD).
## [br]- [b]Destello[/b] de la víctima: un [code]material_overlay[/code] blanco y aditivo de unos 80 ms que cae a cero
## (UI-50). A plena intensidad en los golpes en que interviene el jugador local y tenue en los ajenos.
## [br][br]
## [b]Temporización de la reacción de un remoto.[/b] Un evento propio llega nada más producirse en el
## servidor, pero los remotos se dibujan unos ticks por detrás (el retardo del [InterpolationClock]).
## Lo que es del jugador local (marcador, número, DPS, sacudida, HUD) se aplica al llegar; lo que se
## ve en el remoto (destello, placa de vida con [signal entity_damaged], sonido de su muerte o de la
## baja) espera en una [CombatEventQueue] propia a que su tick de dibujo alcance el [code]tick[/code]
## del evento, igual que los eventos ajenos. Sin cliente (el sandbox) no hay retardo y todo es
## inmediato.
## [br]
## [br]- [b]Ganchos de sonido[/b]: la señal [signal sound_requested] con el nombre del sonido y su
## posición. No hay audio todavía (ART-11): quien lo tenga, se conecta ahí.
## [br]- Muerte y reaparición propias: [signal local_died] y [signal local_respawned].
## [br][br]
## [b]Acciones propias sin señales.[/b] La simulación no emite señales de combate (las repeticiones de
## la reconciliación duplicarían o perderían efectos). En su lugar, tras cada tick de física se
## compara [code](action, action_id, action_tick)[/code] del estado mostrado con el último visto:
## si cambia, empieza otra acción ([signal action_changed]); y se sigue el barrido del arma, activo
## mientras dura el golpe ([signal swing_active_changed], gancho para la estela). Una corrección que
## repite ticks no cambia la clave, así que no duplica nada; y una que solo desplaza unos ticks el
## inicio de la misma acción (la entrada del flanco llegó tarde al servidor, que la sustituyó y empezó
## la esquiva un tick después) tampoco es una acción nueva. El desplazamiento admitido es el tamaño del
## búfer de entradas ([member CombatRules.input_buffer_ticks]), menos que la duración de la acción más
## corta (la esquiva dura 27 ticks), así que una segunda acción encadenada sí se distingue.
## [br][br]
## Las opciones del jugador son [member hit_markers_enabled], [member damage_numbers_enabled],
## [member camera_shake_enabled] y [member flash_enabled].

## Un golpe de este jugador confirmado por el servidor. [param kind] es un [enum HitMarker.Kind].
signal hit_confirmed(kind: int, amount: int, event: NetMessages.EntityEvent)
## El jugador local recibió [param amount] de daño del atacante [param attacker_id] (0 si no hay).
signal damage_taken(amount: int, attacker_id: int, event: NetMessages.EntityEvent)
## Un HIT con daño sobre [param net_id], sea quien sea (las placas enseñan su vida unos segundos). Si
## el evento es propio y la víctima un remoto, sale cuando se le dibuja en el tick del golpe.
signal entity_damaged(net_id: int)
## El jugador local mató a [param victim_id].
signal kill_confirmed(victim_id: int, event: NetMessages.EntityEvent)
## El jugador local ha muerto; [param killer_id] es 0 si fue el entorno.
signal local_died(killer_id: int, attack_id: int)
## El jugador local ha reaparecido en el punto [param point] en el tick [param tick] del servidor.
signal local_respawned(point: int, tick: int)
## La acción del personaje local ha cambiado ([param previous_action] es la anterior).
signal action_changed(action: int, attack_id: int, action_tick: int, previous_action: int)
## El golpe del arma pasa a estar activo (o deja de estarlo): lanza o corta la estela.
signal swing_active_changed(active: bool, attack_id: int)
## Gancho de sonido: [param sound] es uno de los [code]SOUND_*[/code] y [param world_position] dónde
## suena.
signal sound_requested(sound: StringName, world_position: Vector3)

const SOUND_SWING: StringName = &"swing"
const SOUND_DODGE: StringName = &"dodge"
const SOUND_HIT_DEALT: StringName = &"hit_dealt"
const SOUND_HIT_TAKEN: StringName = &"hit_taken"
const SOUND_BLOCK: StringName = &"block"
const SOUND_PARRY: StringName = &"parry"
const SOUND_KILL: StringName = &"kill"
const SOUND_DEATH: StringName = &"death"
const SOUND_RESPAWN: StringName = &"respawn"

## Duración (s) del destello de la víctima: breve, con la opacidad cayendo en línea recta hasta cero.
const FLASH_SECONDS: float = 0.08
## Destello blanco y aditivo (suma luz, no tiñe de rojo): su opacidad al empezar, a plena intensidad (golpes en los que
## interviene el jugador local) y la fracción de esa intensidad que tienen los golpes ajenos.
const FLASH_COLOR: Color = Color(1.0, 1.0, 1.0, 0.55)
const FLASH_OTHERS_INTENSITY: float = 0.45
## Sacudida de cámara al recibir daño: amplitud base y por fracción de vida máxima perdida (m),
## tope y duración (s). Un golpe bloqueado sacude la mitad.
const SHAKE_BASE: float = 0.03
const SHAKE_PER_HEALTH_FRACTION: float = 0.25
const SHAKE_MAX: float = 0.15
const SHAKE_SECONDS: float = 0.18
const BLOCKED_SHAKE_SCALE: float = 0.5
## Texto de los números de golpes parados y bloqueados sin daño.
const TEXT_PARRIED: String = "Parada"
const TEXT_BLOCKED: String = "Bloqueado"

## Opciones del jugador.
var hit_markers_enabled: bool = true:
	set(value):
		hit_markers_enabled = value
		if is_instance_valid(_marker):
			_marker.enabled = value
var damage_numbers_enabled: bool = true:
	set(value):
		damage_numbers_enabled = value
		if is_instance_valid(_numbers):
			_numbers.enabled = value
var camera_shake_enabled: bool = true
var flash_enabled: bool = true
## Solo para pruebas y el sandbox: si es válido se le pregunta primero dónde está una entidad
## (recibe el [code]net_id[/code] y devuelve su posición de dibujo, o [constant Vector3.INF]).
var position_resolver: Callable = Callable()

var _client: NetClient = null
var _camera_rig: CameraRig = null
var _character: PlayerCharacter = null
var _marker: HitMarker = null
var _numbers: DamageNumbers = null
var _dps: DpsMeter = DpsMeter.new()
var _own_net_id_override: int = 0
var _last_event_tick: int = 0
# Última clave (acción, ataque, tick de inicio) vista del personaje local y si el golpe estaba activo.
var _last_action_key: Vector3i = Vector3i(-1, -1, -1)
var _last_action: int = CombatState.Action.NONE
var _swing_active: bool = false
var _flash_meshes: Array[MeshInstance3D] = []
var _flash_left: Array[float] = []
# Material y opacidad inicial de cada destello en curso (en el orden de _flash_meshes).
var _flash_materials: Array[StandardMaterial3D] = []
var _flash_peaks: Array[float] = []
var _events_handled: int = 0
# Reacciones visuales de eventos propios sobre un remoto que esperan a su tick de dibujo.
var _deferred: CombatEventQueue = CombatEventQueue.new()


func _init() -> void:
	name = "CombatFeedback"
	# Después de que NetClient (y la predicción) o el controlador hayan simulado el tick.
	process_physics_priority = 100


func _process(delta: float) -> void:
	advance_flashes(delta)


func _physics_process(_delta: float) -> void:
	observe_action()
	deliver_due_reactions()


## Conecta el reparto con lo que hay en pantalla. Todo es opcional: sin [param client] (el sandbox)
## solo se sigue la acción del personaje; sin marcador, números o cámara, ese efecto se omite.
## Con cliente, los eventos llegan por [signal NetClient.combat_event].
func setup(client: NetClient, camera_rig: CameraRig, character: PlayerCharacter,
		marker: HitMarker, numbers: DamageNumbers) -> void:
	if is_instance_valid(_client) and _client.combat_event.is_connected(handle_event):
		_client.combat_event.disconnect(handle_event)
	_client = client
	_camera_rig = camera_rig
	_character = character
	_marker = marker
	_numbers = numbers
	if is_instance_valid(_marker):
		_marker.enabled = hit_markers_enabled
	if is_instance_valid(_numbers):
		_numbers.enabled = damage_numbers_enabled
		if is_instance_valid(_camera_rig):
			_numbers.set_camera(_camera_rig.get_camera())
	if is_instance_valid(_client) and not _client.combat_event.is_connected(handle_event):
		_client.combat_event.connect(handle_event)
	_last_action_key = Vector3i(-1, -1, -1)
	_swing_active = false
	_deferred.clear()


## Solo para pruebas y sandbox: el id de red del jugador local si no hay [NetClient].
func set_own_net_id(net_id: int) -> void:
	_own_net_id_override = net_id


## Id de red del jugador local (0 si no se sabe).
func get_own_net_id() -> int:
	if is_instance_valid(_client):
		return _client.get_net_id()
	return _own_net_id_override


func get_dps_meter() -> DpsMeter:
	return _dps


## Daño por segundo de los últimos 30 s (panel F3).
func get_dps() -> float:
	return _dps.get_dps(_now_tick())


## Daño de los golpes propios de los últimos 30 s.
func get_damage_in_window() -> int:
	return _dps.get_damage(_now_tick())


## Eventos repartidos desde que existe.
func get_events_handled() -> int:
	return _events_handled


## Reacciones visuales de eventos propios sobre un remoto que todavía esperan a su tick de dibujo.
func get_pending_reactions() -> int:
	return _deferred.size()


# --- Eventos ----------------------------------------------------------------------------------

## Reparte un evento ya temporizado ([signal NetClient.combat_event]). [param is_own] dice si el
## jugador local interviene; el reparto además comprueba los ids, así que sirve igual si falta.
func handle_event(event: NetMessages.EntityEvent, is_own: bool = false) -> void:
	if event == null:
		return
	_events_handled += 1
	_last_event_tick = maxi(_last_event_tick, event.tick)
	match event.event:
		NetMessages.EntityEvent.Kind.HIT:
			_on_hit(event, is_own)
		NetMessages.EntityEvent.Kind.DEATH:
			_on_death(event, is_own)
		NetMessages.EntityEvent.Kind.KILL:
			_on_kill(event, is_own)
		NetMessages.EntityEvent.Kind.RESPAWN:
			_on_respawn(event, is_own)


## Variante de marcador y de número para un HIT: muerte, bloqueado o parado, fuerte o normal.
func kind_of(event: NetMessages.EntityEvent) -> int:
	if event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_LETHAL):
		return HitMarker.Kind.KILL
	if event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED) \
			or event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED):
		return HitMarker.Kind.BLOCKED
	var attack: AttackTicks = CombatCatalog.attack(event.attack_id)
	if attack != null and attack.heavy:
		return HitMarker.Kind.HEAVY
	return HitMarker.Kind.HIT


## Nombre del jugador [param net_id] tal como lo ve este cliente ("" si no se le conoce).
func get_entity_name(net_id: int) -> String:
	if net_id == 0 or not is_instance_valid(_client):
		return ""
	var view: RemotePlayerView = _client.get_remote_world().get_view(net_id)
	return view.get_display_name() if view != null else ""


## Posición (pies) con la que se dibuja ahora a la entidad [param net_id]: el personaje local o la
## vista de un remoto. [constant Vector3.INF] si no se conoce (fuera de interés).
func get_entity_position(net_id: int) -> Vector3:
	if position_resolver.is_valid():
		var resolved: Vector3 = position_resolver.call(net_id)
		if resolved != Vector3.INF:
			return resolved
	var body: PlayerCharacter = _body_of(net_id)
	if body == null:
		return Vector3.INF
	return body.global_position if body.is_inside_tree() else body.position


func knows_entity(net_id: int) -> bool:
	return get_entity_position(net_id) != Vector3.INF


func _on_hit(event: NetMessages.EntityEvent, is_own: bool) -> void:
	var own_id: int = get_own_net_id()
	var attacker_is_me: bool = own_id != 0 and event.attacker == own_id
	var victim_is_me: bool = own_id != 0 and event.net_id == own_id
	var parried: bool = event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED)
	var blocked: bool = event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED)
	var kind: int = kind_of(event)
	var position: Vector3 = get_entity_position(event.net_id)
	if event.amount > 0 and not _defer_remote_reaction(event, is_own):
		_react_to_hit(event)
	if attacker_is_me:
		_dps.add_hit(event.tick, event.amount)
		if is_instance_valid(_marker):
			_marker.show_marker(kind)
		if is_instance_valid(_numbers) and position != Vector3.INF:
			_numbers.add_number(event.net_id, position, event.amount, kind, false,
					event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_CRITICAL),
					_text_for(event, parried, blocked))
		hit_confirmed.emit(kind, event.amount, event)
		_request_sound(SOUND_PARRY if parried else (SOUND_BLOCK if blocked else SOUND_HIT_DEALT),
				position)
	if victim_is_me:
		_shake_for(event.amount, blocked or parried)
		if is_instance_valid(_numbers) and position != Vector3.INF \
				and (event.amount > 0 or parried or blocked):
			_numbers.add_number(event.net_id, position, event.amount, kind, true,
					event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_CRITICAL),
					_text_for(event, parried, blocked))
		damage_taken.emit(event.amount, event.attacker, event)
		_request_sound(SOUND_PARRY if parried else (SOUND_BLOCK if blocked else SOUND_HIT_TAKEN),
				position)


func _on_death(event: NetMessages.EntityEvent, is_own: bool) -> void:
	var own_id: int = get_own_net_id()
	if not _defer_remote_reaction(event, is_own):
		_react_to_death(event)
	if own_id != 0 and event.net_id == own_id:
		local_died.emit(event.killer, event.attack_id)


func _on_kill(event: NetMessages.EntityEvent, is_own: bool) -> void:
	var own_id: int = get_own_net_id()
	if own_id != 0 and event.killer == own_id:
		kill_confirmed.emit(event.net_id, event)
		if not _defer_remote_reaction(event, is_own):
			_react_to_kill(event)


# Lo que se ve en la víctima de un HIT con daño: su placa enseña la vida y destella (a plena intensidad si el golpe
# es del jugador local o lo recibe él, tenue si es de otros).
func _react_to_hit(event: NetMessages.EntityEvent) -> void:
	entity_damaged.emit(event.net_id)
	var own_id: int = get_own_net_id()
	var involves_me: bool = own_id != 0 and (event.attacker == own_id or event.net_id == own_id)
	flash(event.net_id, 1.0 if involves_me else FLASH_OTHERS_INTENSITY)


func _react_to_death(event: NetMessages.EntityEvent) -> void:
	_request_sound(SOUND_DEATH, get_entity_position(event.net_id))


func _react_to_kill(event: NetMessages.EntityEvent) -> void:
	_request_sound(SOUND_KILL, get_entity_position(event.net_id))


# Guarda la reacción visual de [param event] si es propio y le ocurre a un remoto al que todavía se
# dibuja antes del tick del evento (el servidor lo produjo hace [code]retardo[/code] ticks respecto a lo
# que se ve de él). Devuelve true si la ha guardado; entonces [method deliver_due_reactions] la aplica
# cuando el tick de dibujo alcance el del evento. Sin cliente (sandbox) o con la víctima propia no hay
# nada que esperar. Con el reloj sin arrancar (tick de dibujo 0) también espera: aún no se dibuja a nadie.
func _defer_remote_reaction(event: NetMessages.EntityEvent, is_own: bool) -> bool:
	if not is_own or not is_instance_valid(_client):
		return false
	var own_id: int = get_own_net_id()
	if own_id != 0 and event.net_id == own_id:
		return false
	var render_tick: float = _client.get_interpolation_clock().get_render_tick()
	if render_tick > 0.0 and render_tick >= float(event.tick):
		return false
	_deferred.push(event)
	return true


## Aplica las reacciones visuales de eventos propios sobre remotos cuyo tick ya ha alcanzado el tick
## de dibujo ([method _defer_remote_reaction]). Lo llama [method _physics_process] después de cada
## tick; las pruebas lo llaman a mano.
func deliver_due_reactions() -> void:
	if _deferred.size() == 0:
		return
	if not is_instance_valid(_client):
		_deferred.clear()
		return
	for event: NetMessages.EntityEvent in _deferred.pop_due(
			_client.get_interpolation_clock().get_render_tick()):
		match event.event:
			NetMessages.EntityEvent.Kind.HIT:
				_react_to_hit(event)
			NetMessages.EntityEvent.Kind.DEATH:
				_react_to_death(event)
			NetMessages.EntityEvent.Kind.KILL:
				_react_to_kill(event)


func _on_respawn(event: NetMessages.EntityEvent, is_own: bool) -> void:
	var own_id: int = get_own_net_id()
	_request_sound(SOUND_RESPAWN, get_entity_position(event.net_id))
	if is_own or (own_id != 0 and event.net_id == own_id):
		local_respawned.emit(event.point, event.tick)


# Texto del número: vacío (el daño) salvo en los golpes parados o bloqueados sin daño.
func _text_for(event: NetMessages.EntityEvent, parried: bool, blocked: bool) -> String:
	if parried:
		return TEXT_PARRIED
	if blocked and event.amount <= 0:
		return TEXT_BLOCKED
	return ""


func _shake_for(amount: int, softened: bool) -> void:
	if not camera_shake_enabled or not is_instance_valid(_camera_rig):
		return
	var max_health: float = float(maxi(_client.get_max_health(), 1)) \
			if is_instance_valid(_client) else 1000.0
	var strength: float = SHAKE_BASE + SHAKE_PER_HEALTH_FRACTION * float(amount) / max_health
	strength = minf(strength, SHAKE_MAX)
	if softened:
		strength *= BLOCKED_SHAKE_SCALE
	_camera_rig.add_shake(strength, SHAKE_SECONDS)


func _request_sound(sound: StringName, position: Vector3) -> void:
	sound_requested.emit(sound, position if position != Vector3.INF else Vector3.ZERO)


# --- Destello ---------------------------------------------------------------------------------

## Destello breve (material_overlay blanco y aditivo) sobre las mallas de la entidad [param net_id] con la fuerza
## [param intensity] (1 = plena, la de [constant FLASH_COLOR]). Sin efecto con [member flash_enabled] a false o si no se
## conoce su cuerpo.
func flash(net_id: int, intensity: float = 1.0) -> void:
	if not flash_enabled:
		return
	var body: PlayerCharacter = _body_of(net_id)
	if body == null:
		return
	var peak: float = FLASH_COLOR.a * clampf(intensity, 0.0, 1.0)
	var material: StandardMaterial3D = _make_flash_material(peak)
	for node: Node in body.find_children("*", "MeshInstance3D", true, false):
		var mesh: MeshInstance3D = node as MeshInstance3D
		if mesh == null or not mesh.visible:
			continue
		mesh.material_overlay = material
		var index: int = _flash_meshes.find(mesh)
		if index >= 0:
			_flash_left[index] = FLASH_SECONDS
			_flash_materials[index] = material
			_flash_peaks[index] = peak
		else:
			_flash_meshes.append(mesh)
			_flash_left.append(FLASH_SECONDS)
			_flash_materials.append(material)
			_flash_peaks.append(peak)


## Avanza el destello [param delta] segundos, baja su opacidad y quita el overlay a las mallas que ya acabaron.
func advance_flashes(delta: float) -> void:
	var index: int = _flash_meshes.size() - 1
	while index >= 0:
		_flash_left[index] -= delta
		var mesh: MeshInstance3D = _flash_meshes[index]
		if not is_instance_valid(mesh):
			_remove_flash(index)
		elif _flash_left[index] <= 0.0:
			mesh.material_overlay = null
			_remove_flash(index)
		else:
			_flash_materials[index].albedo_color.a = _flash_peaks[index] * (_flash_left[index] / FLASH_SECONDS)
		index -= 1


## Mallas que tienen ahora el destello puesto.
func get_flashing_count() -> int:
	return _flash_meshes.size()


## Opacidad actual del destello de la primera malla que lo tiene (0 si ninguna): para las pruebas.
func get_flash_alpha() -> float:
	return _flash_materials[0].albedo_color.a if not _flash_materials.is_empty() else 0.0


func _remove_flash(index: int) -> void:
	_flash_meshes.remove_at(index)
	_flash_left.remove_at(index)
	_flash_materials.remove_at(index)
	_flash_peaks.remove_at(index)


func _make_flash_material(alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(FLASH_COLOR.r, FLASH_COLOR.g, FLASH_COLOR.b, alpha)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.no_depth_test = false
	return material


func _exit_tree() -> void:
	# Que ninguna malla se quede teñida si el reparto desaparece a medias.
	for mesh: MeshInstance3D in _flash_meshes:
		if is_instance_valid(mesh):
			mesh.material_overlay = null
	_flash_meshes.clear()
	_flash_left.clear()
	_flash_materials.clear()
	_flash_peaks.clear()
	_deferred.clear()


# --- Acciones propias -------------------------------------------------------------------------

## Compara la clave de la acción del personaje local con la última vista y lanza las señales de lo
## que cambió. Lo llama [method _physics_process] después de cada tick; las pruebas lo llaman a
## mano.
func observe_action() -> void:
	var character: PlayerCharacter = _local_character()
	if character == null:
		return
	var state: CombatState = character.combat
	var key := Vector3i(state.action, state.action_id, state.action_tick)
	if key != _last_action_key:
		var first: bool = _last_action_key == Vector3i(-1, -1, -1)
		var previous: int = _last_action
		var shifted: bool = not first and _is_shifted_start(key, _last_action_key)
		_last_action_key = key
		_last_action = state.action
		if not first and not shifted:
			action_changed.emit(state.action, state.action_id, state.action_tick, previous)
			if state.action == CombatState.Action.DODGE:
				_request_sound(SOUND_DODGE, character.global_position)
	var active: bool = ActionMachine.is_attack_active(state, character.last_input_tick)
	if active != _swing_active:
		_swing_active = active
		swing_active_changed.emit(active, state.action_id if active else 0)
		if active:
			_request_sound(SOUND_SWING, character.global_position)


# true si [param key] es la misma acción que [param previous] con el inicio movido unos ticks (una
# corrección de la reconciliación), no otra acción: mismo tipo y mismo ataque, distinto de NONE.
func _is_shifted_start(key: Vector3i, previous: Vector3i) -> bool:
	return key.x != CombatState.Action.NONE and key.x == previous.x and key.y == previous.y \
			and absi(key.z - previous.z) <= CombatCatalog.rules().input_buffer_ticks


## true mientras el golpe del arma propia está activo.
func is_swing_active() -> bool:
	return _swing_active


# --- Ayudantes --------------------------------------------------------------------------------

func _now_tick() -> int:
	var estimated: int = _client.get_estimated_server_tick() if is_instance_valid(_client) else 0
	return maxi(estimated, _last_event_tick)


func _local_character() -> PlayerCharacter:
	if is_instance_valid(_character):
		return _character
	if is_instance_valid(_client):
		return _client.get_character()
	return null


func _body_of(net_id: int) -> PlayerCharacter:
	if net_id == 0:
		return null
	if net_id == get_own_net_id():
		return _local_character()
	if not is_instance_valid(_client):
		return null
	var view: RemotePlayerView = _client.get_remote_world().get_view(net_id)
	if view == null:
		return null
	var body: PlayerCharacter = view.get_body()
	return body if is_instance_valid(body) else null
