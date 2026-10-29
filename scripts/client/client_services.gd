class_name ClientServices
extends Node
## Servicios que todo cliente necesita y que no pertenecen a ninguna escena de juego: el
## [AudioDirector] (ART-10) y los ajustes del jugador (UI-16: [ClientSettings] y la ventana
## [SettingsMenu], que se abre con F10).
## [br][br]
## Es un nodo hijo de las escenas raíz del cliente ([code]client_main.tscn[/code] y
## [code]online_main.tscn[/code]), no un autoload ni algo que nombren sus scripts: el servidor
## dedicado carga los autoloads del proyecto y los scripts que [code]boot.gd[/code] nombra, y no debe
## cargar nada de esto. [method install] es la alternativa para montarlo a mano (pruebas,
## herramientas).
## [br][br]
## [b]Ajustes.[/b] Al entrar en el árbol carga los ajustes ([method ClientSettings.current]) y aplica
## los que el jugador ha guardado ([method ClientSettings.apply_all] con [code]stored_only[/code]):
## un cliente sin ajustes guardados arranca exactamente igual que antes. Después aplica en vivo cada
## cambio ([signal ClientSettings.changed]). Las luces y los terrenos que lleguen más tarde (la zona
## se carga después) reciben las sombras y la distancia de hierba del jugador al entrar en el árbol,
## pero solo si el jugador las ha fijado: sin ellos no cuesta nada. F10 ([code]open_settings[/code])
## abre y cierra la ventana; los ajustes se guardan al cerrarla y al salir.

## Capa de las ventanas de interfaz (por encima del HUD, por debajo del tooltip).
const UI_LAYER: int = 80
const NODE_NAME: String = "ClientServices"

var _audio: AudioDirector = null
var _settings: ClientSettings = null
var _layer: CanvasLayer = null
var _menu: SettingsMenu = null
var _confirm: UIConfirmDialog = null


## Cuelga los servicios de [param parent] (una sola vez: si ya están, devuelve los que había).
static func install(parent: Node) -> ClientServices:
	var existing: ClientServices = parent.get_node_or_null(NODE_NAME) as ClientServices
	if existing != null:
		return existing
	var services: ClientServices = ClientServices.new()
	services.name = NODE_NAME
	parent.add_child(services)
	return services


func _ready() -> void:
	_audio = AudioDirector.new()
	# Los volúmenes los gobiernan los ajustes: primero los de fábrica, después los del jugador.
	_audio.load_volumes_on_ready = false
	add_child(_audio)
	AudioBuses.reset_volumes()

	_layer = CanvasLayer.new()
	_layer.name = "WindowLayer"
	_layer.layer = UI_LAYER
	add_child(_layer)
	_confirm = UIConfirmDialog.new()
	_layer.add_child(_confirm)
	_menu = SettingsMenu.new()
	_layer.add_child(_menu)

	_settings = ClientSettings.current()
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


## El director de audio de este cliente.
func get_audio() -> AudioDirector:
	return _audio


## Los ajustes en uso.
func get_settings() -> ClientSettings:
	return _settings


## La ventana de ajustes.
func get_settings_menu() -> SettingsMenu:
	return _menu


## El diálogo de confirmación que comparten las ventanas (el de «Restaurar todo»).
func get_confirm_dialog() -> UIConfirmDialog:
	return _confirm


## Abre la ventana de ajustes si está cerrada y la cierra si está abierta. Antes la enlaza con la
## cámara de acción (si hay una) para que abrirla libere el cursor.
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


# Lo que entra en el árbol después del arranque (la zona): luces y terreno con los ajustes del jugador.
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
