class_name ClientServices
extends Node
## Services every client needs that do not belong to any game scene: the
## [AudioDirector] (ART-10) and the player settings (UI-16: [ClientSettings] and the
## [SettingsMenu] window, opened with F10).
## [br][br]
## It is a child node of the client's root scenes ([code]client_main.tscn[/code] and
## [code]online_main.tscn[/code]), not an autoload or something its scripts name: the dedicated
## server loads the project's autoloads and the scripts that [code]boot.gd[/code] names (which names
## none of the client's), and must not load any of this. [method install] is the alternative for mounting it by hand (tests,
## tools).
## [br][br]
## [b]Settings.[/b] On entering the tree it loads the settings ([method ClientSettings.current]), applies the
## language ([L10n]) and then the ones the player has saved ([method ClientSettings.apply_all] with [code]stored_only[/code]):
## a client with no saved settings starts exactly as before. Afterwards it applies each
## change live ([signal ClientSettings.changed]). Lights and terrains that arrive later (the zone
## is loaded afterwards) receive the player's shadows and grass distance on entering the tree,
## but only if the player has set them: without them it costs nothing. F10 ([code]open_settings[/code])
## opens and closes the window; settings are saved when it is closed and on exit.

## Layer of the UI windows (above the HUD, below the tooltip).
const UI_LAYER: int = 80
const NODE_NAME: String = "ClientServices"

var _audio: AudioDirector = null
var _settings: ClientSettings = null
var _layer: CanvasLayer = null
var _menu: SettingsMenu = null
var _confirm: UIConfirmDialog = null


## Hangs the services from [param parent] (only once: if they are already there, returns the existing ones).
static func install(parent: Node) -> ClientServices:
	var existing: ClientServices = parent.get_node_or_null(NODE_NAME) as ClientServices
	if existing != null:
		return existing
	var services: ClientServices = ClientServices.new()
	services.name = NODE_NAME
	parent.add_child(services)
	return services


func _ready() -> void:
	# The language goes first, so that every screen built afterwards (this node is a child of the root
	# scene, and its _ready runs before the root's) starts in the player's language. A language forced with
	# --locale wins over the saved one (L10n ignores the setting while it is forced).
	_settings = ClientSettings.current()
	L10n.set_language(String(_settings.get_value(ClientSettings.LANGUAGE)))
	L10n.flush()

	_audio = AudioDirector.new()
	# Volumes are governed by the settings: first the factory ones, then the player's.
	_audio.load_volumes_on_ready = false
	add_child(_audio)
	AudioBuses.reset_volumes()

	_layer = CanvasLayer.new()
	_layer.name = "WindowLayer"
	_layer.layer = UI_LAYER
	add_child(_layer)
	_menu = SettingsMenu.new()
	_layer.add_child(_menu)
	# The dialog goes after the window so it draws over it: "Restore all" opens it from inside the window.
	_confirm = UIConfirmDialog.new()
	_layer.add_child(_confirm)

	_menu.setup(_settings, _confirm)
	_settings.apply_all(get_tree(), true)
	_settings.changed.connect(_on_setting_changed)
	get_tree().node_added.connect(_on_node_added)


func _exit_tree() -> void:
	if _settings != null:
		if _settings.changed.is_connected(_on_setting_changed):
			_settings.changed.disconnect(_on_setting_changed)
		_settings.save_if_dirty()
	if get_tree() != null and get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action(&"open_settings") and event.is_action_pressed(&"open_settings"):
		toggle_settings()
		get_viewport().set_input_as_handled()


## This client's audio director.
func get_audio() -> AudioDirector:
	return _audio


## The settings in use.
func get_settings() -> ClientSettings:
	return _settings


## The settings window.
func get_settings_menu() -> SettingsMenu:
	return _menu


## The confirmation dialog shared by the windows (the one for "Restore all").
func get_confirm_dialog() -> UIConfirmDialog:
	return _confirm


## Opens the settings window if it is closed and closes it if it is open. First it links it to the
## action camera (if there is one) so that opening it releases the cursor.
func toggle_settings() -> void:
	if _menu == null:
		return
	var rig: CameraRig = get_tree().get_first_node_in_group(CameraRig.GROUP) as CameraRig
	if rig != null:
		_menu.bind_camera(rig)
		_confirm.bind_camera(rig)
	_menu.toggle()


func _on_setting_changed(id: StringName, _value: Variant) -> void:
	_settings.apply_value(id, get_tree())


# What enters the tree after start-up (the zone): lights and terrain with the player's settings.
func _on_node_added(node: Node) -> void:
	if node is Light3D:
		if _settings.is_stored(ClientSettings.SHADOWS) \
				and int(_settings.get_value(ClientSettings.SHADOWS)) == ClientSettings.SHADOWS_OFF:
			ClientSettings.apply_light_shadow(node as Light3D, false)
	elif _settings.is_stored(ClientSettings.GRASS_DISTANCE) and node.is_class("Terrain3D"):
		_apply_grass.call_deferred()


func _apply_grass() -> void:
	if is_inside_tree():
		_settings.apply_value(ClientSettings.GRASS_DISTANCE, get_tree())
