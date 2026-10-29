class_name HUD
extends CanvasLayer
## Interfaz del jugador: punto de mira, vida y resistencia, marcador de impacto y números de daño,
## arcos de dirección del daño, viñeta de vida baja, placas de nombre de los remotos, pantalla de
## muerte, panel de depuración y ayuda de controles.
## [br][br]
## Solo cliente. Lee el estado del personaje, de la cámara y (en red) del [NetClient] cada
## fotograma, pero nunca modifica la simulación. Se conecta con [method bind] (sandbox y cliente en
## red) y, en red, con [method bind_net].
## [br][br]
## [b]Sandbox sin red.[/b] La vida no existe: la barra de vida se oculta. La resistencia sí
## funciona (la simulación es local) y el reparto de la sensación de combate ([CombatFeedback]) sigue
## las acciones del personaje, pero no llega ningún evento.
## [br][br]
## [b]En red.[/b] La vida sale del bloque extra del snapshot ([method NetClient.get_health]); los
## eventos de combate ya temporizados ([signal NetClient.combat_event]) los reparte
## [CombatFeedback]. Al morir (estado «muerto» del snapshot) se abre la [DeathScreen], que libera el
## cursor y atenúa el resto de la interfaz, y el botón envía el RESPAWN_REQUEST con el punto elegido;
## al reaparecer (evento RESPAWN propio o vida de nuevo) se cierra y todo vuelve a la normalidad.

## Cada cuánto se refresca el texto del panel de depuración, en segundos.
## Refrescarlo cada frame hace que las cifras parpadeen y sean ilegibles.
const DEBUG_REFRESH_INTERVAL: float = 0.1
## Opacidad a la que se atenúa la interfaz de juego con la pantalla de muerte abierta.
const DEAD_DIM_ALPHA: float = 0.3

var _character: PlayerCharacter = null
var _camera_rig: CameraRig = null
var _client: NetClient = null
var _world: Node = null
var _feedback: CombatFeedback = null
var _debug_refresh_left: float = 0.0
var _health_initialized: bool = false
# Quién te mató y con qué (del DEATH propio), hasta que se use para la pantalla de muerte.
var _death_killer_id: int = -1
var _death_attack_id: int = 0
# Tick del servidor del último RESPAWN propio: un snapshot anterior no puede reabrir la pantalla.
var _respawn_event_tick: int = 0
var _dimmed: bool = false
# Interfaz de guerra del cliente en red (fuerte, avisos, jefe...); null en el sandbox.
var _war_hud: WarHud = null

@onready var _nameplates: Nameplates = $Nameplates
@onready var _crosshair: Crosshair = $Crosshair
@onready var _vitals: VitalsHud = $Vitals
@onready var _vignette: LowHealthVignette = $Vignette
@onready var _indicator: DamageIndicator = $DamageIndicator
@onready var _numbers: DamageNumbers = $DamageNumbers
@onready var _marker: HitMarker = $HitMarker
@onready var _death: DeathScreen = $DeathScreen
@onready var _hint: UIHintBar = $HintLabel
@onready var _debug_panel: PanelContainer = $DebugPanel
@onready var _debug_label: Label = $DebugPanel/DebugLabel


func _ready() -> void:
	# Los controles no se mueven, pero así el HUD nunca se ve afectado por la
	# interpolación de físicas.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# Después de que la simulación (controlador local o predicción de red) haya dado el tick: el
	# bit «sin resistencia» de combat_flags dura un solo tick y hay que leerlo ya puesto.
	process_physics_priority = 100
	_vitals.set_health_visible(_client != null)
	_death.respawn_requested.connect(_on_respawn_requested)
	_death.opened.connect(_on_death_opened)
	_death.closed.connect(_on_death_closed)
	_update_crosshair()
	_refresh_debug_text()


func _exit_tree() -> void:
	# Que el cursor no se quede suelto si el HUD desaparece con la pantalla de muerte abierta.
	if is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)


## Conecta el HUD con el personaje local y la cámara. Se puede llamar antes o
## después de añadir el HUD al árbol.
func bind(character: PlayerCharacter, camera_rig: CameraRig) -> void:
	_character = character
	_camera_rig = camera_rig
	_debug_refresh_left = 0.0
	if is_node_ready():
		_vitals.set_health_visible(_client != null)
		_setup_feedback()
		_update_crosshair()
		_refresh_debug_text()


## Conecta el HUD con el cliente de red [param client] (la vida y los eventos de combate) y con la
## zona [param world] (los puntos de reaparición). Después de [method bind].
func bind_net(client: NetClient, world: Node) -> void:
	_client = client
	_world = world
	_health_initialized = false
	_respawn_event_tick = 0
	if is_node_ready():
		_vitals.set_health_visible(true)
		_setup_feedback()
		_nameplates.setup(_client.get_remote_world(), _camera_rig, _client.get_config().realm)
		_setup_war_hud()


func _process(delta: float) -> void:
	_update_death()
	_update_crosshair()
	_update_vitals()
	if is_instance_valid(_camera_rig):
		_indicator.set_camera_yaw(_camera_rig.get_yaw())
	if not _debug_panel.visible:
		return
	_debug_refresh_left -= delta
	if _debug_refresh_left <= 0.0:
		_debug_refresh_left = DEBUG_REFRESH_INTERVAL
		_refresh_debug_text()


func _physics_process(_delta: float) -> void:
	# El bit «sin resistencia» dura un solo tick de física: se lee a esa cadencia para no perderlo
	# entre dos fotogramas.
	if is_instance_valid(_character) and (_character.combat.combat_flags
			& CombatState.FLAG_NO_STAMINA) != 0:
		_vitals.notify_no_stamina()


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action(&"toggle_debug") and event.is_action_pressed(&"toggle_debug"):
		_debug_panel.visible = not _debug_panel.visible
		if _debug_panel.visible:
			_debug_refresh_left = 0.0
			_refresh_debug_text()
		get_viewport().set_input_as_handled()


## Muestra u oculta el panel de depuración sin esperar a F3. El cliente en red lo empieza oculto y
## F3 lo alterna junto con [NetDebugOverlay].
func set_debug_visible(visible_now: bool) -> void:
	_debug_panel.visible = visible_now
	if visible_now:
		_debug_refresh_left = 0.0
		_refresh_debug_text()


# --- Accesos (para las pruebas y para quien monta la interfaz) --------------------------------

## Barras de vida y resistencia.
func get_vitals() -> VitalsHud:
	return _vitals


func get_death_screen() -> DeathScreen:
	return _death


func get_damage_indicator() -> DamageIndicator:
	return _indicator


func get_vignette() -> LowHealthVignette:
	return _vignette


func get_hit_marker() -> HitMarker:
	return _marker


func get_damage_numbers() -> DamageNumbers:
	return _numbers


## Placas de nombre y vida de los remotos.
func get_nameplates() -> Nameplates:
	return _nameplates


## Interfaz de guerra: panel de captura, avisos, barra de jefe... (null sin red).
func get_war_hud() -> WarHud:
	return _war_hud


## Reparto de la sensación de combate (null hasta [method bind]).
func get_feedback() -> CombatFeedback:
	return _feedback


## true mientras la interfaz de juego está atenuada por la pantalla de muerte.
func is_dimmed() -> bool:
	return _dimmed


# --- Montaje ----------------------------------------------------------------------------------

# Crea (una vez) el reparto de la sensación de combate y lo conecta con el personaje, el cliente y
# los elementos de pantalla; sus señales alimentan los arcos, la viñeta y la pantalla de muerte.
func _setup_feedback() -> void:
	if _feedback == null:
		_feedback = CombatFeedback.new()
		add_child(_feedback)
		_feedback.damage_taken.connect(_on_damage_taken)
		_feedback.entity_damaged.connect(_nameplates.mark_damaged)
		_feedback.local_died.connect(_on_local_died)
		_feedback.local_respawned.connect(_on_local_respawned)
	_feedback.setup(_client, _camera_rig, _character, _marker, _numbers)


# Crea (de nuevo, si ya había una) la interfaz de guerra y la conecta con el cliente. Va por debajo de la
# pantalla de muerte, que es el último hijo.
func _setup_war_hud() -> void:
	if is_instance_valid(_war_hud):
		remove_child(_war_hud)
		_war_hud.free()
	_war_hud = WarHud.new()
	_war_hud.name = "WarHud"
	add_child(_war_hud)
	move_child(_war_hud, _death.get_index())
	_war_hud.bind(_client, _camera_rig)


# --- Vida y resistencia -----------------------------------------------------------------------

func _update_vitals() -> void:
	if is_instance_valid(_character):
		var combat: CombatState = _character.combat
		_vitals.set_stamina(combat.stamina, CombatCatalog.rules().stamina_max,
				combat.is_exhausted())
	if is_instance_valid(_client) and _client.has_health():
		var health: int = _client.get_health()
		var max_health: int = _client.get_max_health()
		if not _health_initialized or (_vitals.get_health() <= 0 and health > 0):
			_vitals.snap_health(health, max_health)
			_health_initialized = true
		else:
			_vitals.set_health(health, max_health)
		_vignette.set_health_fraction(0.0 if _is_dead_now() else float(health)
				/ float(maxi(max_health, 1)))
	else:
		_vignette.set_health_fraction(1.0)


func _on_damage_taken(amount: int, attacker_id: int, _event: NetMessages.EntityEvent) -> void:
	# La viñeta roja avisa de daño: una parada o un bloqueo completo (amount 0) no la enciende.
	if amount <= 0:
		return
	_vignette.flash()
	if not is_instance_valid(_character) or _feedback == null:
		return
	if attacker_id == 0 or not _feedback.knows_entity(attacker_id):
		return
	var from_position: Vector3 = _feedback.get_entity_position(_feedback.get_own_net_id())
	var attacker_position: Vector3 = _feedback.get_entity_position(attacker_id)
	if from_position == Vector3.INF or attacker_position == Vector3.INF:
		return
	var strength: float = clampf(float(amount) / 150.0, 0.35, 1.0)
	_indicator.add_hit(DamageIndicator.world_heading(from_position, attacker_position), strength)


# --- Muerte y reaparición ---------------------------------------------------------------------

# true si el servidor dice que el jugador está muerto y el snapshot no es anterior a la última
# reaparición (un snapshot atrasado podría reabrir la pantalla recién cerrada).
func _is_dead_now() -> bool:
	if not is_instance_valid(_client) or not _client.is_dead():
		return false
	return _client.get_last_snapshot_tick() >= _respawn_event_tick


func _update_death() -> void:
	var dead: bool = _is_dead_now()
	if dead and not _death.is_open():
		_open_death_screen()
	elif not dead and _death.is_open():
		_death.close()
	if _death.is_open() and is_instance_valid(_client):
		_death.update_countdown(_client.get_estimated_server_tick())


func _on_local_died(killer_id: int, attack_id: int) -> void:
	_death_killer_id = killer_id
	_death_attack_id = attack_id
	if _death.is_open():
		_death.set_cause_text(_death_cause_text())


func _on_local_respawned(_point: int, tick: int) -> void:
	_respawn_event_tick = maxi(_respawn_event_tick, tick)
	_death_killer_id = -1
	_death.close()


func _open_death_screen() -> void:
	var points: Array[Node3D] = []
	if is_instance_valid(_world) and is_instance_valid(_client):
		points = RespawnPointList.list(_world, _client.get_config().realm)
	_death.open(_death_cause_text(), _client.get_respawn_tick(), RespawnPointList.labels(points))


# «Te ha derrotado X con Y.» con lo que se sabe del DEATH propio.
func _death_cause_text() -> String:
	if _death_killer_id < 0:
		return CombatText.TEXT_FALLEN
	var killer_name: String = _feedback.get_entity_name(_death_killer_id) if _feedback != null else ""
	return CombatText.death_text(_death_killer_id, killer_name, _death_attack_id)


func _on_death_opened() -> void:
	_set_dimmed(true)
	if is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(true, self)


func _on_death_closed() -> void:
	_set_dimmed(false)
	if is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)
	_death_killer_id = -1
	_numbers.clear()
	_indicator.clear()
	if is_instance_valid(_client) and _client.has_health():
		_vitals.snap_health(_client.get_health(), _client.get_max_health())


func _on_respawn_requested(point_index: int) -> void:
	if is_instance_valid(_client):
		_client.send_respawn_request(point_index)


# Atenúa (o restaura) lo que no es la pantalla de muerte.
func _set_dimmed(dim: bool) -> void:
	_dimmed = dim
	var alpha: float = DEAD_DIM_ALPHA if dim else 1.0
	for item: CanvasItem in [_vitals, _crosshair, _hint, _numbers, _marker, _indicator, _nameplates]:
		item.modulate.a = alpha
	if is_instance_valid(_war_hud):
		_war_hud.modulate.a = alpha


## El punto de mira solo tiene sentido mientras el ratón controla la cámara.
func _update_crosshair() -> void:
	var cursor_free: bool = is_instance_valid(_camera_rig) and _camera_rig.is_cursor_free()
	_crosshair.visible = not cursor_free


func _refresh_debug_text() -> void:
	var fps: int = roundi(Engine.get_frames_per_second())
	if not is_instance_valid(_character):
		_debug_label.text = "FPS: %d\nSin personaje vinculado" % fps
		return
	var pos: Vector3 = _character.global_position
	var yaw_degrees: float = rad_to_deg(wrapf(_character.yaw, -PI, PI))
	var combat: CombatState = _character.combat
	var stamina_max: int = CombatCatalog.rules().stamina_max
	var lines: PackedStringArray = [
		"FPS: %d" % fps,
		"Posición: (%7.2f, %7.2f, %7.2f)" % [pos.x, pos.y, pos.z],
		"Velocidad horizontal: %5.2f m/s" % _character.get_horizontal_speed(),
		"En suelo: %s" % ("sí" if _character.grounded else "no"),
		"Orientación (yaw): %6.1f°" % yaw_degrees,
		"Resistencia: %d / %d%s" % [combat.stamina, stamina_max,
				" (agotado)" if combat.is_exhausted() else ""],
	]
	if is_instance_valid(_client) and _client.has_health():
		lines.append("Vida: %d / %d" % [_client.get_health(), _client.get_max_health()])
	if _feedback != null and is_instance_valid(_client):
		lines.append("DPS (30 s): %.1f · daño %d" % [_feedback.get_dps(),
				_feedback.get_damage_in_window()])
	_debug_label.text = "\n".join(lines)
