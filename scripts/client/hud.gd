class_name HUD
extends CanvasLayer
## Player interface: crosshair, health and stamina, hit marker and damage numbers,
## damage direction arcs, low-health vignette, remote players' nameplates, death
## screen, debug panel and controls help.
## [br][br]
## Client only. It reads the state of the character, the camera and (online) the [NetClient] every
## frame, but never modifies the simulation. It is connected with [method bind] (sandbox and online
## client) and, online, with [method bind_net].
## [br][br]
## [b]Offline sandbox.[/b] Health does not exist: the health bar is hidden. Stamina does
## work (the simulation is local) and the combat feel distributor ([CombatFeedback]) follows
## the character's actions, but no event arrives.
## [br][br]
## [b]Online.[/b] Health comes from the extra block of the snapshot ([method NetClient.get_health]); the
## already timed combat events ([signal NetClient.combat_event]) are distributed by
## [CombatFeedback]. On death ("dead" state in the snapshot) the [DeathScreen] opens, which frees the
## cursor and dims the rest of the interface, and its button sends the RESPAWN_REQUEST with the chosen point;
## on respawn (own RESPAWN event or health again) it closes and everything returns to normal.
## [br][br]
## [b]Respawn and map (UI-21).[/b] The death screen list is the options valid right now
## ([method RespawnPointList.valid_options]: your camp and a calm fort of yours), it is updated while
## open (the fort may change hands) and each option sends the index of its marker among all
## those in the zone (docs/fuerte.md, section 5). "Elegir en el mapa" (choose on the map) (or M with the screen open) opens the
## [WorldMap] in respawn mode on top of it: clicking a valid point leaves it chosen in the list.
## [br][br]
## [b]Scoreboard (UI-41).[/b] While Tab is held, the [ScoreboardPanel] (the last child, above everything)
## shows the zone's table; the kill log ([KillFeed]) lives in the war interface.
## [br][br]
## [b]Hints (UI-42).[/b] Online, the [HintToasts] sit just above the death screen and undimmed (the
## respawn one belongs to that screen) and below the map and the scoreboard, which cover them: while either of them is
## open they wait ([member HintToasts.is_covered]). When the death screen closes, the respawn hint is
## withdrawn if it had not been read yet.
## [br][br]
## [b]Chat (SOC-05).[/b] Online, the [ChatBox] at the bottom left shows the messages of [signal
## NetClient.chat_received] and the NOTICEs; Enter opens its line and suspends movement and the camera while
## typing.
## [br][br]
## [b]Party (SOC-08).[/b] Online, the [PartyHud] on the left shows the invitation notice (with accept and decline
## by keyboard) and the frames of the party members; it handles the commands [code]/invitar[/code],
## [code]/salir[/code], [code]/expulsar[/code] and [code]/lider[/code] of the chat box and tells the nameplates
## who is in the party.
## [br][br]
## [b]Social menu (SOC-07).[/b] The [code]social_menu[/code] key opens the [SocialMenu] on the ally the
## reticle points at, within 20 m and in sight ([method open_social_menu]): invite to the party and whisper.
## [br][br]
## [b]Abilities (phase 4, docs/habilidades.md, section 6).[/b] Above health, the row of own effects
## ([StatusIcons] with the local player's [StatusTracker], against the estimated server tick) and, above that, the
## [ActionBar] (also in the sandbox: it reads the predicted state). At the top, the knocked-down notices
## ([DownedNotice]); on the death screen, the loadout selector, which sends the LOADOUT_SELECT. While drawing
## the bow, the camera narrows the field of view ([method CameraRig.set_aim_zoom]) and the reticle closes
## with the charge ([method Crosshair.set_tension]).
## [br][br]
## [b]Inventory and character (phase 5, docs/progresion.md §11, UI-26).[/b] Online, I opens the [InventoryWindow] (on the
## right) and C the [CharacterWindow] (on the left), with the client's [ClientInventory] and [ClientProgress]; they
## open together, free the cursor and you drag from one to the other. The split ([SplitDialog]) and destroy
## ([UIConfirmDialog]) dialogs go on top of both. Notices of a rejected request appear in the chat.
## With inventory (it arrives with the first INVENTORY_FULL), the death screen no longer shows the loadout selector:
## the respawn takes the weapons from the equipment (§2.5).

## How often the debug panel text is refreshed, in seconds.
## Refreshing it every frame makes the figures flicker and become unreadable.
const DEBUG_REFRESH_INTERVAL: float = 0.1
## Opacity to which the game interface is dimmed with the death screen open.
const DEAD_DIM_ALPHA: float = 0.3
## Position (px from the bottom, anchored to the center) of the action bar and of the row of own effects,
## above the action bar (24 px from the edge); [code]Vitals[/code] goes right above it.
const ACTION_BAR_RECT: Rect2 = Rect2(-340.0, -76.0, 680.0, 52.0)
const STATUS_ROW_RECT: Rect2 = Rect2(-200.0, -160.0, 400.0, 30.0)
## Social menu notice (SOC-07) for when there is nobody to offer it to. It is the only one: an enemy, a dead player, a fake
## player or someone behind a wall give the same one as pointing at nobody, so as not to reveal what is not seen.
const TEXT_NO_SOCIAL_TARGET: String = "Apunta a un jugador de tu reino (a 20 m o menos) para ver sus acciones."
## Hints of the help line of the online client: the usual ones and, after debug, the map and the scoreboard.
const NET_HINTS_EXTRA: Array[Dictionary] = [
	{"action": &"open_map", "text": "Mapa"},
	{"action": &"scoreboard", "text": "Marcador"},
	{"action": &"chat_open", "text": "Chat"},
	{"action": &"social_menu", "text": "Jugador"},
	{"action": &"open_inventory", "text": "Inventario"},
	{"action": &"open_character", "text": "Personaje"},
]
## Margin (px) of the inventory and character windows from the screen edge.
const INVENTORY_WINDOW_MARGIN: int = 48

var _character: PlayerCharacter = null
var _camera_rig: CameraRig = null
var _client: NetClient = null
var _world: Node = null
var _feedback: CombatFeedback = null
# Combat audio and effects (ART-11, ART-09): connected to the combat feel distributor.
var _combat_audio: CombatAudio = null
var _combat_vfx: CombatVfx = null
var _debug_refresh_left: float = 0.0
var _health_initialized: bool = false
# Who killed you and with what (from the own DEATH), until it is used for the death screen.
var _death_killer_id: int = -1
var _death_attack_id: int = 0
# Server tick of the last own RESPAWN: an earlier snapshot cannot reopen the screen.
var _respawn_event_tick: int = 0
var _dimmed: bool = false
# War interface of the online client (fort, notices, boss...); null in the sandbox.
var _war_hud: WarHud = null
# Full-screen map and scoreboard (above the death screen); null in the sandbox.
var _world_map: WorldMap = null
var _scoreboard: ScoreboardPanel = null
# Game hints (UI-42), above the death screen; null in the sandbox.
var _hints: HintToasts = null
# Chat box (SOC-05); null in the sandbox.
var _chat: ChatBox = null
# Party interface (SOC-08): invitation and frames; null in the sandbox.
var _party_hud: PartyHud = null
# Social menu on the player under the crosshair (SOC-07); null in the sandbox.
var _social_menu: SocialMenu = null
# What the death screen's respawn list currently shows (to know whether it changed).
var _death_signature: String = ""
# Phase 4: action bar, own effects and knocked-down notices (created by _ready, also in the sandbox).
var _action_bar: ActionBar = null
var _status_row: StatusIcons = null
var _downed_notice: DownedNotice = null
# Phase 5: inventory and character windows and their dialogs (null in the sandbox).
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
	# The controls do not move, but this way the HUD is never affected by
	# physics interpolation.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# After the simulation (local controller or network prediction) has ticked: the
	# "no stamina" bit of combat_flags lasts a single tick and must be read while it is set.
	process_physics_priority = 100
	_vitals.set_health_visible(_client != null)
	# The controls help line starts hidden (UI-49): F1 and the Interface settings show it.
	ClientSettings.bind_visibility(_hint, ClientSettings.HELP_BAR, true)
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
	# So that the cursor is not left loose if the HUD disappears with the death screen open.
	if is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)


## Connects the HUD to the local character and the camera. It can be called before or
## after adding the HUD to the tree.
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


## Connects the action bar to the local character's controller: a mistimed key press makes
## its slot blink (online, [method bind_net] does it with the client's).
func bind_controller(controller: LocalPlayerController) -> void:
	if is_node_ready():
		_action_bar.bind(_character, controller)


## Connects the HUD to the network client [param client] (health and combat events) and to the
## zone [param world] (the respawn points). After [method bind].
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
		_setup_hints()
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
	# The "no stamina" bit lasts a single physics tick: it is read at that rate so as not to lose it
	# between two frames.
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
	elif InputMap.has_action(&"toggle_help") and event.is_action_pressed(&"toggle_help"):
		toggle_help_line()
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


## Shows or hides the controls help line (F1) and remembers it in the Interface settings
## ([constant ClientSettings.HELP_BAR]). Returns whether it ends up visible.
func toggle_help_line() -> bool:
	var settings: ClientSettings = ClientSettings.current()
	settings.set_value(ClientSettings.HELP_BAR, not bool(settings.get_value(ClientSettings.HELP_BAR)))
	settings.save_if_dirty()
	return _hint.visible


## Controls help line at the bottom (hidden by default).
func get_help_line() -> UIHintBar:
	return _hint


## Shows or hides the debug panel without waiting for F3. The online client starts it hidden and
## F3 toggles it together with [NetDebugOverlay].
func set_debug_visible(visible_now: bool) -> void:
	_debug_panel.visible = visible_now
	if visible_now:
		_debug_refresh_left = 0.0
		_refresh_debug_text()


# --- Accessors (for tests and for whoever assembles the interface) ----------------------------

## Health and stamina bars.
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


## Name and health nameplates of the remotes.
func get_nameplates() -> Nameplates:
	return _nameplates


## War interface: capture panel, notices, boss bar... (null offline).
func get_war_hud() -> WarHud:
	return _war_hud


## Full-screen map (null offline).
func get_world_map() -> WorldMap:
	return _world_map


## Zone scoreboard, Tab (null offline).
func get_scoreboard() -> ScoreboardPanel:
	return _scoreboard


## Game hints (null offline).
func get_hints() -> HintToasts:
	return _hints


## Chat box (null offline).
func get_chat() -> ChatBox:
	return _chat


## Party interface: invitation notice and member frames (null offline).
func get_party_hud() -> PartyHud:
	return _party_hud


## Social menu of the player under the crosshair (null offline).
func get_social_menu() -> SocialMenu:
	return _social_menu


## Opens the social menu on the ally the reticle points at, within 20 m and in sight (SOC-07,
## [method SocialTarget.find]): invite to the party and whisper. Returns false, opening nothing, if there is another window or
## the chat line open, or if there is no such ally under the reticle; in that case it notifies in the chat with
## [constant TEXT_NO_SOCIAL_TARGET], the same notice whether it points at an enemy, a wall or the void.
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
	# The character's world (already in the tree) is the one of the walls that block the view.
	var space: PhysicsDirectSpaceState3D = character.get_world_3d().direct_space_state
	var view: RemotePlayerView = SocialTarget.find(_client.get_remote_world(), _camera_rig.get_aim_ray(),
			character.global_position, own_realm, space)
	if view == null or not _social_menu.open_for(view):
		if is_instance_valid(_chat):
			_chat.add_system_text(TEXT_NO_SOCIAL_TARGET)
		return false
	return true


## Inventory window, I (null offline).
func get_inventory_window() -> InventoryWindow:
	return _inventory_window


## Character window, C (null offline).
func get_character_window() -> CharacterWindow:
	return _character_window


## Dialog to split a stack (null offline).
func get_split_dialog() -> SplitDialog:
	return _split_dialog


## Dialog to confirm a destruction (null offline).
func get_destroy_dialog() -> UIConfirmDialog:
	return _destroy_dialog


## Opens or closes the inventory window. Returns false, doing nothing, when offline or with the death screen or the
## chat line open.
func toggle_inventory_window() -> bool:
	if not _can_toggle_inventory_windows():
		return false
	_inventory_window.toggle()
	return true


## Opens or closes the character window (the same conditions as [method toggle_inventory_window]).
func toggle_character_window() -> bool:
	if not _can_toggle_inventory_windows():
		return false
	_character_window.toggle()
	return true


## Action bar (UI-11).
func get_action_bar() -> ActionBar:
	return _action_bar


## Row of own effects above health (UI-45).
func get_status_row() -> StatusIcons:
	return _status_row


## Knocked-down notices.
func get_downed_notice() -> DownedNotice:
	return _downed_notice


## Combat feel distributor (null until [method bind]).
func get_feedback() -> CombatFeedback:
	return _feedback


## Combat audio (null until [method bind]).
func get_combat_audio() -> CombatAudio:
	return _combat_audio


## Hit effects (null until [method bind] or without a character).
func get_combat_vfx() -> CombatVfx:
	return _combat_vfx


## true while the game interface is dimmed by the death screen.
func is_dimmed() -> bool:
	return _dimmed


# --- Setup ------------------------------------------------------------------------------------

# Creates (once) the combat feel distributor and connects it to the character, the client and
# the on-screen elements; its signals feed the arcs, the vignette and the death screen.
func _setup_feedback() -> void:
	if _feedback == null:
		_feedback = CombatFeedback.new()
		add_child(_feedback)
		_feedback.damage_taken.connect(_on_damage_taken)
		_feedback.hit_confirmed.connect(_on_hit_confirmed)
		_feedback.entity_damaged.connect(_nameplates.mark_damaged)
		_feedback.local_died.connect(_on_local_died)
		_feedback.local_respawned.connect(_on_local_respawned)
	_feedback.setup(_client, _camera_rig, _character, _marker, _numbers)
	if _combat_audio == null:
		_combat_audio = CombatAudio.new()
		add_child(_combat_audio)
	_combat_audio.bind(_feedback)
	# The effects hang from the world (they use global coordinates): from the character, which is recreated with the zone.
	if is_instance_valid(_character) and (not is_instance_valid(_combat_vfx)
			or _combat_vfx.get_parent() != _character):
		if is_instance_valid(_combat_vfx):
			_combat_vfx.queue_free()
		_combat_vfx = CombatVfx.new()
		_character.add_child(_combat_vfx)
	if is_instance_valid(_combat_vfx):
		_combat_vfx.bind(_feedback)


# Creates (again, if there already was one) the war interface and connects it to the client. It goes below the
# death screen, which is the last child.
func _setup_war_hud() -> void:
	if is_instance_valid(_war_hud):
		remove_child(_war_hud)
		_war_hud.free()
	_war_hud = WarHud.new()
	_war_hud.name = "WarHud"
	add_child(_war_hud)
	move_child(_war_hud, _death.get_index())
	_war_hud.bind(_client, _camera_rig)


# Creates (again, if there already was one) the full-screen map: the last child, above the death
# screen so that respawn can be chosen. It uses the baked map that the war interface loaded.
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


# Creates (again, if there already was one) the zone scoreboard: the last child, above everything else.
func _setup_scoreboard() -> void:
	if is_instance_valid(_scoreboard):
		remove_child(_scoreboard)
		_scoreboard.free()
	_scoreboard = ScoreboardPanel.new()
	_scoreboard.name = "Scoreboard"
	add_child(_scoreboard)
	_scoreboard.bind(_client)


# Creates (again, if there already were some) the game hints: right above the death screen (undimmed: the
# respawn one belongs to that screen) and below the map and the scoreboard, which cover them while they are open.
func _setup_hints() -> void:
	if is_instance_valid(_hints):
		remove_child(_hints)
		_hints.free()
	_hints = HintToasts.new()
	_hints.name = "HintToasts"
	add_child(_hints)
	move_child(_hints, _death.get_index() + 1)
	_hints.bind(_client, _client.get_fortress_view(),
			_war_hud.get_capture_panel() if is_instance_valid(_war_hud) else null)
	_hints.is_covered = _hints_covered


# true if the map or the scoreboard cover the hints.
func _hints_covered() -> bool:
	return (is_instance_valid(_world_map) and _world_map.is_open()) \
			or (is_instance_valid(_scoreboard) and _scoreboard.is_open())


# Creates (again, if there already was one) the chat box: below the death screen, which is the last child
# (and below the scoreboard and the map, which go on top of everything).
func _setup_chat() -> void:
	if is_instance_valid(_chat):
		remove_child(_chat)
		_chat.free()
	_chat = ChatBox.new()
	_chat.name = "Chat"
	add_child(_chat)
	move_child(_chat, _death.get_index())
	_chat.bind(_client, _camera_rig, _client.get_controller())


# Creates (again, if there already was one) the party interface: on the left, below the death screen, with
# the chat box's party commands connected to it and the nameplates told who is in the party.
func _setup_party() -> void:
	if is_instance_valid(_party_hud):
		remove_child(_party_hud)
		_party_hud.free()
	_party_hud = PartyHud.new()
	_party_hud.name = "Grupo"
	add_child(_party_hud)
	move_child(_party_hud, _death.get_index())
	# Y and N do not answer the invitation with another window open; the death screen (the HUD requests the cursor
	# for it) does allow answering.
	_party_hud.bind(_client, _camera_rig, self)
	if is_instance_valid(_chat):
		_chat.party_handler = Callable(_party_hud, "handle_command")
	_nameplates.set_party(_client.get_party())


# Creates (again, if there already was one) the social menu: above the chat and the party, and below the death
# screen and the scoreboard, which remains the last child.
func _setup_social_menu() -> void:
	if is_instance_valid(_social_menu):
		remove_child(_social_menu)
		_social_menu.free()
	_social_menu = SocialMenu.new()
	_social_menu.name = "MenuSocial"
	add_child(_social_menu)
	move_child(_social_menu, _death.get_index())
	_social_menu.setup(_client, _chat, _camera_rig)


# --- Inventory and character (phase 5) ----------------------------------------------------------

# Creates (again, if there already was one) the inventory and character windows and their dialogs, below the death
# screen (the dialogs above the windows), linked to the inventory, the progress and the camera.
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


# With the character window open, its figure carries the weapons from the character's state (those of the LOADOUT and the
# weapon swap, not those of the inventory's optimistic view).
func _update_inventory_windows() -> void:
	if is_instance_valid(_character_window) and _character_window.is_open() and is_instance_valid(_character):
		_character_window.set_weapons(_character.combat.weapon_id, _character.combat.alt_weapon_id)


# An inventory request that was not sent or that the server rejected: its notice, in the chat.
func _on_inventory_rejected(_result: int, text: String) -> void:
	if is_instance_valid(_chat) and not text.is_empty():
		_chat.add_system_text(text)


# --- Abilities (phase 4) -----------------------------------------------------------------------

# Creates the action bar, the row of own effects and the knocked-down notices, below the death
# screen.
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


# Adds [param control] anchored at the bottom center with rectangle [param rect] (offsets from that anchor),
# right below the death screen.
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


# Every frame: own effects, knocked-down notices and the bow aim.
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


# While drawing the bow: the camera narrows the field of view on reaching the minimum charge and the reticle
# closes with the charge (docs/habilidades.md, section 6.5). On any other action, nothing.
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


# Already timed combat events of the client: reviving, finishing off and knockdowns go to the notices.
func _on_combat_event(event: NetMessages.EntityEvent, _is_own: bool) -> void:
	_downed_notice.set_own_id(_client.get_net_id() if is_instance_valid(_client) else 0)
	_downed_notice.handle_event(event)


# Template chosen on the death screen: valid for this respawn.
func _on_template_chosen(template_id: int) -> void:
	if is_instance_valid(_client):
		_client.send_loadout_select(template_id)


func _entity_name(net_id: int) -> String:
	if is_instance_valid(_client) and _client.get_directory().knows(net_id):
		return _client.get_directory().name_of(net_id)
	return _feedback.get_entity_name(net_id) if _feedback != null else ""


# --- Health and stamina -----------------------------------------------------------------------

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
		# On the death screen, no vignette: it already dims the world and the HUD (UI-50).
		var dead: bool = _is_dead_now()
		_vignette.set_suppressed(dead)
		_vignette.set_health_fraction(1.0 if dead else float(health) / float(maxi(max_health, 1)))
	else:
		_vignette.set_health_fraction(1.0)


# An own hit confirmed: the world markers are left with only the target for a few seconds.
func _on_hit_confirmed(_kind: int, _amount: int, _event: NetMessages.EntityEvent) -> void:
	_notify_combat_to_markers()


func _notify_combat_to_markers() -> void:
	if is_instance_valid(_war_hud) and is_instance_valid(_war_hud.get_world_markers()):
		_war_hud.get_world_markers().notify_combat()


func _on_damage_taken(amount: int, attacker_id: int, _event: NetMessages.EntityEvent) -> void:
	_notify_combat_to_markers()
	# The red vignette warns of damage: a parry or a full block (amount 0) does not light it. Its opacity is
	# proportional to what the hit takes from maximum health (UI-50).
	if amount <= 0:
		return
	_vignette.flash(amount, _client.get_max_health() if is_instance_valid(_client) and _client.has_health()
			else LowHealthVignette.DEFAULT_MAX_HEALTH)
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


# --- Death and respawn ------------------------------------------------------------------------

# true if the server says the player is dead and the snapshot is not older than the last
# respawn (a stale snapshot could reopen the screen that was just closed).
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
	# The selected template is the one requested last time (or the default one). With inventory it is not shown: the
	# respawn takes the weapons from the equipment and LOADOUT_SELECT no longer changes anything (docs/progresion.md §2.5).
	if _client.get_config() != null:
		_death.get_template_selector().select(_client.get_config().get_loadout_template_id())
	_death.get_template_selector().visible = not _client.get_inventory().has_inventory()


# The respawn options valid for the player right now: their camp and a calm fort of theirs
# (RespawnRules, the same rule the server applies).
func _valid_respawn_options() -> Array[RespawnPointList.Option]:
	var empty: Array[RespawnPointList.Option] = []
	if not is_instance_valid(_world) or not is_instance_valid(_client) or _client.get_config() == null:
		return empty
	var view: FortressView = _client.get_fortress_view()
	var tick: int = _client.get_estimated_server_tick()
	return RespawnPointList.valid_options(_world, _client.get_config().realm,
			view.get_states_by_definition(tick), tick, view.get_display_names())


# Recomputes the options while the screen is open (a fort changes hands or enters
# combat) and rebuilds the list only if something changed; it keeps the chosen point.
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


# With the death screen open and more than one place to respawn, the map hint (only once).
func _hint_respawn_map() -> void:
	if is_instance_valid(_hints) and _death.get_point_count() > 1:
		_hints.request(HintCatalog.RESPAWN_MAP)


func _on_map_requested() -> void:
	if is_instance_valid(_world_map):
		_world_map.open(true)


# The map opens with the death screen in front (with M or with the button): it is for choosing respawn.
func _on_map_opened() -> void:
	if _death.is_open() and is_instance_valid(_world_map):
		_world_map.set_respawn_mode(true)


# A valid respawn point clicked on the map: it is left chosen in the list and we return to the screen.
func _on_map_option_chosen(option: RespawnPointList.Option) -> void:
	if not _death.is_open():
		return
	_refresh_respawn_options()
	_death.select_point_index(option.index_for(_client.get_net_id()))
	_world_map.close()


# "Te ha derrotado X con Y." (X defeated you with Y.) with what is known from the own DEATH.
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
	# The respawn hint is no longer relevant (if it had not been read, it returns on the next death).
	if is_instance_valid(_hints):
		_hints.withdraw(HintCatalog.RESPAWN_MAP)
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


# Dims (or restores) whatever is not the death screen.
func _set_dimmed(dim: bool) -> void:
	_dimmed = dim
	var alpha: float = DEAD_DIM_ALPHA if dim else 1.0
	for item: CanvasItem in [_vitals, _crosshair, _hint, _numbers, _marker, _indicator, _nameplates,
			_action_bar, _status_row]:
		item.modulate.a = alpha
	if is_instance_valid(_war_hud):
		_war_hud.modulate.a = alpha


## The crosshair only makes sense while the mouse controls the camera.
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
