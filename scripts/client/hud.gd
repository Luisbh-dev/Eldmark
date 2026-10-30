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
## [br][br]
## [b]Reaparición y mapa (UI-21).[/b] La lista de la pantalla de muerte son las opciones válidas ahora
## ([method RespawnPointList.valid_options]: tu campamento y un fuerte tuyo en calma), se actualiza mientras
## está abierta (el fuerte puede cambiar de manos) y cada opción envía el índice de su marcador entre todos
## los de la zona (docs/fuerte.md, sección 5). «Elegir en el mapa» (o M con la pantalla abierta) abre el
## [WorldMap] en modo de reaparición por encima de ella: pulsar un punto válido lo deja elegido en la lista.
## [br][br]
## [b]Marcador (UI-41).[/b] Mientras se mantiene Tab, el [ScoreboardPanel] (el último hijo, por encima de todo)
## enseña la tabla de la zona; el registro de bajas ([KillFeed]) vive en la interfaz de guerra.
## [br][br]
## [b]Chat (SOC-05).[/b] En red, la [ChatBox] abajo a la izquierda enseña los mensajes de [signal
## NetClient.chat_received] y los NOTICE; Intro abre su línea y suspende el movimiento y la cámara mientras se
## escribe.
## [br][br]
## [b]Grupo (SOC-08).[/b] En red, el [PartyHud] a la izquierda enseña el aviso de invitación (con aceptar y rechazar
## por teclado) y los marcos de los miembros del grupo; atiende los comandos [code]/invitar[/code],
## [code]/salir[/code], [code]/expulsar[/code] y [code]/lider[/code] de la caja de chat y avisa a las placas de nombre de
## quién es del grupo.
## [br][br]
## [b]Menú social (SOC-07).[/b] La tecla [code]social_menu[/code] abre el [SocialMenu] sobre el aliado al que apunta la
## retícula a 20 m o menos y a la vista ([method open_social_menu]): invitar al grupo y susurrar.
## [br][br]
## [b]Habilidades (fase 4, docs/habilidades.md, sección 6).[/b] Encima de la vida, la fila de efectos propios
## ([StatusIcons] con el [StatusTracker] del jugador local, contra el tick del servidor estimado) y, encima, la
## [ActionBar] (también en el sandbox: lee el estado predicho). Arriba, los avisos de derribado
## ([DownedNotice]); en la pantalla de muerte, el selector de plantilla, que manda el LOADOUT_SELECT. Tensando
## el arco, la cámara cierra el campo de visión ([method CameraRig.set_aim_zoom]) y la retícula se cierra
## con la carga ([method Crosshair.set_tension]).
## [br][br]
## [b]Inventario y personaje (fase 5, docs/progresion.md §11, UI-26).[/b] En red, I abre la [InventoryWindow] (a la
## derecha) y C la [CharacterWindow] (a la izquierda), con el [ClientInventory] y el [ClientProgress] del cliente; se
## abren a la vez, liberan el cursor y se arrastra de una a otra. Los diálogos de dividir ([SplitDialog]) y de
## destruir ([UIConfirmDialog]) van por encima de las dos. Los avisos de una petición rechazada salen en el chat.
## Con inventario (llega con el primer INVENTORY_FULL), la pantalla de muerte ya no enseña el selector de plantilla:
## la reaparición toma las armas del equipo (§2.5).

## Cada cuánto se refresca el texto del panel de depuración, en segundos.
## Refrescarlo cada frame hace que las cifras parpadeen y sean ilegibles.
const DEBUG_REFRESH_INTERVAL: float = 0.1
## Opacidad a la que se atenúa la interfaz de juego con la pantalla de muerte abierta.
const DEAD_DIM_ALPHA: float = 0.3
## Posición (px desde abajo, anclada al centro) de la barra de acciones y de la fila de efectos propios,
## por encima de la vida y la resistencia ([code]Vitals[/code] empieza a 118 px del borde).
const ACTION_BAR_RECT: Rect2 = Rect2(-320.0, -240.0, 640.0, 56.0)
const STATUS_ROW_RECT: Rect2 = Rect2(-200.0, -172.0, 400.0, 30.0)
## Aviso del menú social (SOC-07) cuando no hay a quién ofrecérselo. Es el único: un enemigo, un muerto, un jugador
## falso o alguien tras una pared dan el mismo que no apuntar a nadie, para no delatar lo que no se ve.
const TEXT_NO_SOCIAL_TARGET: String = "Apunta a un jugador de tu reino (a 20 m o menos) para ver sus acciones."
## Pistas de la línea de ayuda del cliente en red: las de siempre y, tras la depuración, el mapa y el marcador.
const NET_HINTS_EXTRA: Array[Dictionary] = [
	{"action": &"open_map", "text": "Mapa"},
	{"action": &"scoreboard", "text": "Marcador"},
	{"action": &"chat_open", "text": "Chat"},
	{"action": &"social_menu", "text": "Jugador"},
	{"action": &"open_inventory", "text": "Inventario"},
	{"action": &"open_character", "text": "Personaje"},
]
## Margen (px) de las ventanas de inventario y personaje con el borde de la pantalla.
const INVENTORY_WINDOW_MARGIN: int = 48

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
# Mapa a pantalla completa y marcador (por encima de la pantalla de muerte); null en el sandbox.
var _world_map: WorldMap = null
var _scoreboard: ScoreboardPanel = null
# Caja de chat (SOC-05); null en el sandbox.
var _chat: ChatBox = null
# Interfaz de grupo (SOC-08): invitación y marcos; null en el sandbox.
var _party_hud: PartyHud = null
# Menú social sobre el jugador bajo el punto de mira (SOC-07); null en el sandbox.
var _social_menu: SocialMenu = null
# Lo que enseña ahora la lista de reaparición de la pantalla de muerte (para saber si cambió).
var _death_signature: String = ""
# Fase 4: barra de acciones, efectos propios y avisos de derribado (los crea _ready, también en el sandbox).
var _action_bar: ActionBar = null
var _status_row: StatusIcons = null
var _downed_notice: DownedNotice = null
# Fase 5: ventanas de inventario y personaje y sus diálogos (null en el sandbox).
var _inventory_window: InventoryWindow = null
var _character_window: CharacterWindow = null
var _split_dialog: SplitDialog = null
var _destroy_dialog: UIConfirmDialog = null

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
	_death.map_requested.connect(_on_map_requested)
	_death.opened.connect(_hint_respawn_map)
	_death.opened.connect(_on_death_opened)
	_death.closed.connect(_on_death_closed)
	_death.get_template_selector().template_chosen.connect(_on_template_chosen)
	_setup_ability_hud()
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
		_action_bar.bind(character)
		_update_crosshair()
		_refresh_debug_text()


## Conecta la barra de acciones con el controlador del personaje local: una pulsación a destiempo hace
## parpadear su casilla (en red lo hace [method bind_net] con el del cliente).
func bind_controller(controller: LocalPlayerController) -> void:
	if is_node_ready():
		_action_bar.bind(_character, controller)


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
		_nameplates.set_client(_client)
		_action_bar.bind(_character, _client.get_controller())
		_downed_notice.set_own_id(_client.get_net_id())
		if not _client.combat_event.is_connected(_on_combat_event):
			_client.combat_event.connect(_on_combat_event)
		_setup_war_hud()
		_setup_world_map()
		_setup_scoreboard()
		_setup_chat()
		_setup_party()
		_setup_social_menu()
		_setup_inventory()
		var hints: Array[Dictionary] = UIHintBar.DEFAULT_HINTS.duplicate()
		hints.append_array(NET_HINTS_EXTRA)
		_hint.set_hints(hints)


func _process(delta: float) -> void:
	_update_death()
	_update_crosshair()
	_update_vitals()
	_update_ability_hud()
	_update_inventory_windows()
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
		_action_bar.notify_no_stamina()


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action(&"toggle_debug") and event.is_action_pressed(&"toggle_debug"):
		_debug_panel.visible = not _debug_panel.visible
		if _debug_panel.visible:
			_debug_refresh_left = 0.0
			_refresh_debug_text()
		get_viewport().set_input_as_handled()
	elif InputMap.has_action(&"social_menu") and event.is_action_pressed(&"social_menu"):
		if open_social_menu():
			get_viewport().set_input_as_handled()
	elif InputMap.has_action(&"open_inventory") and event.is_action_pressed(&"open_inventory"):
		if toggle_inventory_window():
			get_viewport().set_input_as_handled()
	elif InputMap.has_action(&"open_character") and event.is_action_pressed(&"open_character"):
		if toggle_character_window():
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


## Mapa a pantalla completa (null sin red).
func get_world_map() -> WorldMap:
	return _world_map


## Marcador de la zona, Tab (null sin red).
func get_scoreboard() -> ScoreboardPanel:
	return _scoreboard


## Caja de chat (null sin red).
func get_chat() -> ChatBox:
	return _chat


## Interfaz de grupo: aviso de invitación y marcos de los miembros (null sin red).
func get_party_hud() -> PartyHud:
	return _party_hud


## Menú social del jugador bajo el punto de mira (null sin red).
func get_social_menu() -> SocialMenu:
	return _social_menu


## Abre el menú social sobre el aliado al que apunta la retícula, a 20 m o menos y a la vista (SOC-07,
## [method SocialTarget.find]): invitar al grupo y susurrar. Devuelve false, sin abrir nada, si hay otra ventana o
## la línea del chat abierta, o si no hay ningún aliado así bajo la retícula; en este caso avisa en el chat con
## [constant TEXT_NO_SOCIAL_TARGET], el mismo aviso apunte a un enemigo, a una pared o al vacío.
func open_social_menu() -> bool:
	if not is_instance_valid(_social_menu) or not is_instance_valid(_client) \
			or not is_instance_valid(_camera_rig) or _death.is_open():
		return false
	if _camera_rig.is_ui_holding_cursor() or (is_instance_valid(_chat) and _chat.is_open()):
		return false
	var character: PlayerCharacter = _client.get_character()
	if character == null or not is_instance_valid(character) or not character.is_inside_tree():
		return false
	var own_realm: int = _client.get_config().realm if _client.get_config() != null else NetProtocol.Realm.NONE
	# El mundo del personaje (ya en el árbol) es el de las paredes que tapan.
	var space: PhysicsDirectSpaceState3D = character.get_world_3d().direct_space_state
	var view: RemotePlayerView = SocialTarget.find(_client.get_remote_world(), _camera_rig.get_aim_ray(),
			character.global_position, own_realm, space)
	if view == null or not _social_menu.open_for(view):
		if is_instance_valid(_chat):
			_chat.add_system_text(TEXT_NO_SOCIAL_TARGET)
		return false
	return true


## Ventana de inventario, I (null sin red).
func get_inventory_window() -> InventoryWindow:
	return _inventory_window


## Ventana de personaje, C (null sin red).
func get_character_window() -> CharacterWindow:
	return _character_window


## Diálogo de dividir una pila (null sin red).
func get_split_dialog() -> SplitDialog:
	return _split_dialog


## Diálogo de confirmar una destrucción (null sin red).
func get_destroy_dialog() -> UIConfirmDialog:
	return _destroy_dialog


## Abre o cierra la ventana de inventario. Devuelve false, sin hacer nada, sin red o con la pantalla de muerte o la
## línea del chat abiertas.
func toggle_inventory_window() -> bool:
	if not _can_toggle_inventory_windows():
		return false
	_inventory_window.toggle()
	return true


## Abre o cierra la ventana de personaje (las mismas condiciones que [method toggle_inventory_window]).
func toggle_character_window() -> bool:
	if not _can_toggle_inventory_windows():
		return false
	_character_window.toggle()
	return true


## Barra de acciones (UI-11).
func get_action_bar() -> ActionBar:
	return _action_bar


## Fila de efectos propios sobre la vida (UI-45).
func get_status_row() -> StatusIcons:
	return _status_row


## Avisos de derribado.
func get_downed_notice() -> DownedNotice:
	return _downed_notice


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


# Crea (de nuevo, si ya había uno) el mapa a pantalla completa: el último hijo, por encima de la pantalla de
# muerte para poder elegir reaparición. Usa el mapa horneado que cargó la interfaz de guerra.
func _setup_world_map() -> void:
	if is_instance_valid(_world_map):
		remove_child(_world_map)
		_world_map.free()
	_world_map = WorldMap.new()
	_world_map.name = "WorldMap"
	add_child(_world_map)
	_world_map.bind(_client, _client.get_fortress_view(), _camera_rig,
			_war_hud.get_map() if is_instance_valid(_war_hud) else null, _world)
	_world_map.opened.connect(_on_map_opened)
	_world_map.respawn_option_chosen.connect(_on_map_option_chosen)


# Crea (de nuevo, si ya había uno) el marcador de la zona: el último hijo, por encima de todo lo demás.
func _setup_scoreboard() -> void:
	if is_instance_valid(_scoreboard):
		remove_child(_scoreboard)
		_scoreboard.free()
	_scoreboard = ScoreboardPanel.new()
	_scoreboard.name = "Scoreboard"
	add_child(_scoreboard)
	_scoreboard.bind(_client)


# Crea (de nuevo, si ya había una) la caja de chat: por debajo de la pantalla de muerte, que es el último hijo
# (y del marcador y el mapa, que van encima de todo).
func _setup_chat() -> void:
	if is_instance_valid(_chat):
		remove_child(_chat)
		_chat.free()
	_chat = ChatBox.new()
	_chat.name = "Chat"
	add_child(_chat)
	move_child(_chat, _death.get_index())
	_chat.bind(_client, _camera_rig, _client.get_controller())


# Crea (de nuevo, si ya había una) la interfaz de grupo: a la izquierda, por debajo de la pantalla de muerte, con
# los comandos de grupo de la caja de chat conectados a ella y las placas de nombre avisadas de quién es del grupo.
func _setup_party() -> void:
	if is_instance_valid(_party_hud):
		remove_child(_party_hud)
		_party_hud.free()
	_party_hud = PartyHud.new()
	_party_hud.name = "Grupo"
	add_child(_party_hud)
	move_child(_party_hud, _death.get_index())
	# Y y N no responden a la invitación con otra ventana abierta; la pantalla de muerte (el HUD pide el cursor
	# por ella) sí deja responder.
	_party_hud.bind(_client, _camera_rig, self)
	if is_instance_valid(_chat):
		_chat.party_handler = Callable(_party_hud, "handle_command")
	_nameplates.set_party(_client.get_party())


# Crea (de nuevo, si ya había uno) el menú social: por encima del chat y del grupo, y por debajo de la pantalla
# de muerte y del marcador, que sigue siendo el último hijo.
func _setup_social_menu() -> void:
	if is_instance_valid(_social_menu):
		remove_child(_social_menu)
		_social_menu.free()
	_social_menu = SocialMenu.new()
	_social_menu.name = "MenuSocial"
	add_child(_social_menu)
	move_child(_social_menu, _death.get_index())
	_social_menu.setup(_client, _chat, _camera_rig)


# --- Inventario y personaje (fase 5) ---------------------------------------------------------------

# Crea (de nuevo, si ya había) las ventanas de inventario y personaje y sus diálogos, por debajo de la pantalla de
# muerte (los diálogos encima de las ventanas), enlazadas con el inventario, el progreso y la cámara.
func _setup_inventory() -> void:
	for node: Node in [_inventory_window, _character_window, _split_dialog, _destroy_dialog]:
		if is_instance_valid(node):
			remove_child(node)
			node.free()
	_character_window = CharacterWindow.new()
	_character_window.centered = false
	_add_below_death(_character_window)
	_character_window.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE,
			INVENTORY_WINDOW_MARGIN)
	_inventory_window = InventoryWindow.new()
	_inventory_window.centered = false
	_add_below_death(_inventory_window)
	_inventory_window.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_MINSIZE,
			INVENTORY_WINDOW_MARGIN)
	_split_dialog = SplitDialog.new()
	_split_dialog.name = "DividirPila"
	_add_below_death(_split_dialog)
	_destroy_dialog = UIConfirmDialog.new()
	_destroy_dialog.name = "DestruirObjeto"
	_add_below_death(_destroy_dialog)
	for item: Control in [_inventory_window, _character_window]:
		item.grow_vertical = Control.GROW_DIRECTION_BOTH
	_inventory_window.bind_camera(_camera_rig)
	_character_window.bind_camera(_camera_rig)
	_split_dialog.bind_camera(_camera_rig)
	_destroy_dialog.bind_camera(_camera_rig)
	var inventory: ClientInventory = _client.get_inventory()
	_inventory_window.bind(inventory, _client.get_progress(), _split_dialog, _destroy_dialog)
	_character_window.bind(inventory, _client.get_progress(), _inventory_window)
	var config: ClientConfig = _client.get_config()
	_character_window.set_identity(config.display_name if config != null else "",
			config.realm if config != null else NetProtocol.Realm.NONE, _client.get_own_appearance())
	if not inventory.request_rejected.is_connected(_on_inventory_rejected):
		inventory.request_rejected.connect(_on_inventory_rejected)


func _add_below_death(control: Control) -> void:
	add_child(control)
	move_child(control, _death.get_index())


func _can_toggle_inventory_windows() -> bool:
	if not is_instance_valid(_inventory_window) or not is_instance_valid(_character_window) or _death.is_open():
		return false
	return not (is_instance_valid(_chat) and _chat.is_open())


# Con la ventana de personaje abierta, su figura lleva las armas del estado del personaje (las del LOADOUT y el
# cambio de arma, no las de la vista optimista del inventario).
func _update_inventory_windows() -> void:
	if is_instance_valid(_character_window) and _character_window.is_open() and is_instance_valid(_character):
		_character_window.set_weapons(_character.combat.weapon_id, _character.combat.alt_weapon_id)


# Una petición del inventario que no se envió o que el servidor rechazó: su aviso, en el chat.
func _on_inventory_rejected(_result: int, text: String) -> void:
	if is_instance_valid(_chat) and not text.is_empty():
		_chat.add_system_text(text)


# --- Habilidades (fase 4) ------------------------------------------------------------------------

# Crea la barra de acciones, la fila de efectos propios y los avisos de derribado, por debajo de la pantalla
# de muerte.
func _setup_ability_hud() -> void:
	_action_bar = ActionBar.new()
	_place_bottom(_action_bar, ACTION_BAR_RECT)
	_status_row = StatusIcons.new()
	_status_row.name = "EfectosPropios"
	_place_bottom(_status_row, STATUS_ROW_RECT)
	_downed_notice = DownedNotice.new()
	_downed_notice.name_of = _entity_name
	add_child(_downed_notice)
	move_child(_downed_notice, _death.get_index())
	_downed_notice.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if is_instance_valid(_character):
		_action_bar.bind(_character)


# Añade [param control] anclado abajo al centro con el rectángulo [param rect] (offsets desde ese ancla),
# justo por debajo de la pantalla de muerte.
func _place_bottom(control: Control, rect: Rect2) -> void:
	add_child(control)
	move_child(control, _death.get_index())
	control.anchor_left = 0.5
	control.anchor_right = 0.5
	control.anchor_top = 1.0
	control.anchor_bottom = 1.0
	control.offset_left = rect.position.x
	control.offset_right = rect.position.x + rect.size.x
	control.offset_top = rect.position.y
	control.offset_bottom = rect.position.y + rect.size.y
	control.grow_horizontal = Control.GROW_DIRECTION_BOTH
	control.grow_vertical = Control.GROW_DIRECTION_BEGIN


# Cada fotograma: efectos propios, avisos de derribado y la puntería del arco.
func _update_ability_hud() -> void:
	var online: bool = is_instance_valid(_client)
	var server_tick: int = _client.get_estimated_server_tick() if online else 0
	var tracker: StatusTracker = _client.get_status_tracker(_client.get_net_id()) if online else null
	_status_row.show_tracker(tracker, server_tick)
	if online:
		var downed: bool = _client.is_downed() and not _is_dead_now()
		var target: int = 0
		if not downed and not _client.is_dead() and is_instance_valid(_character) \
				and _client.get_config() != null:
			target = DownedNotice.find_downed_ally(_client.get_remote_world(),
					_character.global_position if _character.is_inside_tree() else _character.position,
					_client.get_config().realm)
		_downed_notice.update_view(downed, _client.get_health() if downed else 0, server_tick, target)
	_update_bow_aim()


# Tensando el arco: la cámara cierra el campo de visión al llegar a la carga mínima y la retícula se
# cierra con la carga (docs/habilidades.md, sección 6.5). En cualquier otra acción, nada.
func _update_bow_aim() -> void:
	var zoom: float = 0.0
	var tension: float = 0.0
	if is_instance_valid(_character):
		var combat: CombatState = _character.combat
		var weapon: WeaponTicks = CombatCatalog.weapon(combat.weapon_id)
		if combat.action == CombatState.Action.CHARGE and ActionBar.is_ranged(weapon):
			var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id)
			var held: int = _character.last_input_tick - combat.action_tick
			zoom = clampf(float(held) / float(maxi(heavy.charge_min_ticks, 1)), 0.0, 1.0)
			tension = ProjectileLaunch.charge_progress(held, heavy.charge_min_ticks, heavy.charge_max_ticks)
	_crosshair.set_tension(tension)
	if is_instance_valid(_camera_rig):
		_camera_rig.set_aim_zoom(zoom)


# Eventos de combate ya temporizados del cliente: levantar, rematar y derribos van a los avisos.
func _on_combat_event(event: NetMessages.EntityEvent, _is_own: bool) -> void:
	_downed_notice.set_own_id(_client.get_net_id() if is_instance_valid(_client) else 0)
	_downed_notice.handle_event(event)


# Plantilla elegida en la pantalla de muerte: vale para esta reaparición.
func _on_template_chosen(template_id: int) -> void:
	if is_instance_valid(_client):
		_client.send_loadout_select(template_id)


func _entity_name(net_id: int) -> String:
	if is_instance_valid(_client) and _client.get_directory().knows(net_id):
		return _client.get_directory().name_of(net_id)
	return _feedback.get_entity_name(net_id) if _feedback != null else ""


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
		_refresh_respawn_options()


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
	var options: Array[RespawnPointList.Option] = _valid_respawn_options()
	_death.open(_death_cause_text(), _client.get_respawn_tick(), RespawnPointList.option_labels(options))
	var own_id: int = _client.get_net_id()
	_death.set_point_indices(RespawnPointList.option_indices(options, own_id))
	_death_signature = _options_signature(options, own_id)
	# La plantilla marcada es la que se pidió la última vez (o la de por defecto). Con inventario no se enseña: la
	# reaparición toma las armas del equipo y LOADOUT_SELECT ya no cambia nada (docs/progresion.md §2.5).
	if _client.get_config() != null:
		_death.get_template_selector().select(_client.get_config().get_loadout_template_id())
	_death.get_template_selector().visible = not _client.get_inventory().has_inventory()


# Las opciones de reaparición que valen ahora para el jugador: su campamento y un fuerte suyo en calma
# (RespawnRules, la misma regla que aplica el servidor).
func _valid_respawn_options() -> Array[RespawnPointList.Option]:
	var empty: Array[RespawnPointList.Option] = []
	if not is_instance_valid(_world) or not is_instance_valid(_client) or _client.get_config() == null:
		return empty
	var view: FortressView = _client.get_fortress_view()
	var tick: int = _client.get_estimated_server_tick()
	return RespawnPointList.valid_options(_world, _client.get_config().realm,
			view.get_states_by_definition(tick), tick, view.get_display_names())


# Vuelve a calcular las opciones mientras la pantalla está abierta (un fuerte cambia de manos o entra en
# combate) y rehace la lista solo si ha cambiado algo; conserva el punto elegido.
func _refresh_respawn_options() -> void:
	var options: Array[RespawnPointList.Option] = _valid_respawn_options()
	var own_id: int = _client.get_net_id()
	var signature: String = _options_signature(options, own_id)
	if signature == _death_signature:
		return
	_death_signature = signature
	_death.update_points(RespawnPointList.option_labels(options), RespawnPointList.option_indices(options, own_id))
	_hint_respawn_map()


static func _options_signature(options: Array[RespawnPointList.Option], spread_seed: int) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for option: RespawnPointList.Option in options:
		parts.append("%s=%d" % [option.label, option.index_for(spread_seed)])
	return "|".join(parts)


# Con la pantalla de muerte abierta y más de un sitio donde reaparecer, la pista del mapa (una sola vez).
func _hint_respawn_map() -> void:
	if is_instance_valid(_war_hud) and is_instance_valid(_war_hud.get_hints()) and _death.get_point_count() > 1:
		_war_hud.get_hints().request(HintCatalog.RESPAWN_MAP)


func _on_map_requested() -> void:
	if is_instance_valid(_world_map):
		_world_map.open(true)


# El mapa se abre con la pantalla de muerte delante (con M o con el botón): es para elegir reaparición.
func _on_map_opened() -> void:
	if _death.is_open() and is_instance_valid(_world_map):
		_world_map.set_respawn_mode(true)


# Un punto de reaparición válido pulsado en el mapa: queda elegido en la lista y se vuelve a la pantalla.
func _on_map_option_chosen(option: RespawnPointList.Option) -> void:
	if not _death.is_open():
		return
	_refresh_respawn_options()
	_death.select_point_index(option.index_for(_client.get_net_id()))
	_world_map.close()


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
	_death_signature = ""
	if is_instance_valid(_world_map) and _world_map.is_respawn_mode():
		_world_map.close()
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
	for item: CanvasItem in [_vitals, _crosshair, _hint, _numbers, _marker, _indicator, _nameplates,
			_action_bar, _status_row]:
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
