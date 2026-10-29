class_name WarHud
extends Control
## Interfaz de guerra del cliente en red (fase 4, docs/fuerte.md sección 6): reúne los elementos que
## solo tienen sentido con un servidor y un fuerte, y los conecta con el [NetClient]. El [HUD] lo crea
## en [method HUD.bind_net] y lo mantiene encima de las placas y por debajo de la pantalla de muerte.
## [br][br]
## Hijos (se crean en [method bind]):
## [br]- [CapturePanel] (UI-18): el estado del fuerte cuando se está cerca o se combate por él.
## [br]- [WarBanners] (UI-18, GUE-13): los avisos de guerra.
## [br]- [BossBar] (UI-18): la vida del jefe más cercano.
## [br]- [TelegraphMarks] (UI-18): las zonas de peligro de los ataques de los PNJ. Es un nodo 3D: como su
## padre es un control, Godot lo trata como raíz del mundo 3D del visor (sus posiciones son globales),
## y así vive y muere con esta interfaz sin colgar nada de la zona.
## [br]- [Compass] y [WorldMarkers] (UI-19): la brújula y los iconos del fuerte, los campamentos y los
## pasos, con el mapa horneado de la zona ([ZoneMapDefinition]) para los lugares fijos.
## [br][br]
## Todo cuelga del cliente de red; sin él (el sandbox) no existe. Solo cliente.

var _client: NetClient = null
var _capture_panel: CapturePanel = null
var _banners: WarBanners = null
var _boss_bar: BossBar = null
var _telegraph_marks: TelegraphMarks = null
var _compass: Compass = null
var _world_markers: WorldMarkers = null
var _camera_rig: CameraRig = null
var _map: ZoneMapDefinition = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(_delta: float) -> void:
	_update_compass()


## Crea los elementos y los conecta con [param client] y la cámara [param camera_rig] (la brújula y
## los marcadores la miran; puede ser null). Se puede llamar una vez.
func bind(client: NetClient, camera_rig: CameraRig = null) -> void:
	_client = client
	_camera_rig = camera_rig
	_map = _load_map(client)
	var view: FortressView = client.get_fortress_view()
	var own_realm: int = client.get_config().realm if client.get_config() != null \
			else NetProtocol.Realm.NONE
	_capture_panel = CapturePanel.new()
	_capture_panel.name = "CapturePanel"
	add_child(_capture_panel)
	_capture_panel.bind(view, client, own_realm)
	_banners = WarBanners.new()
	_banners.name = "WarBanners"
	add_child(_banners)
	_banners.bind(client, view)
	_boss_bar = BossBar.new()
	_boss_bar.name = "BossBar"
	add_child(_boss_bar)
	_boss_bar.bind(client)
	_world_markers = WorldMarkers.new()
	_world_markers.name = "WorldMarkers"
	add_child(_world_markers)
	_world_markers.bind(client, view, camera_rig, _map)
	_compass = Compass.new()
	_compass.name = "Compass"
	add_child(_compass)
	_telegraph_marks = TelegraphMarks.new()
	add_child(_telegraph_marks)
	_telegraph_marks.bind(client)


func get_capture_panel() -> CapturePanel:
	return _capture_panel


func get_banners() -> WarBanners:
	return _banners


func get_boss_bar() -> BossBar:
	return _boss_bar


func get_telegraph_marks() -> TelegraphMarks:
	return _telegraph_marks


func get_compass() -> Compass:
	return _compass


func get_world_markers() -> WorldMarkers:
	return _world_markers


## Mapa horneado de la zona (null si no tiene).
func get_map() -> ZoneMapDefinition:
	return _map


## Cada fotograma pone en la brújula hacia dónde mira la cámara y dónde está el jugador.
func _update_compass() -> void:
	if _compass == null or not is_instance_valid(_camera_rig) or not is_instance_valid(_client):
		return
	var character: PlayerCharacter = _client.get_character()
	if character == null or not is_instance_valid(character):
		return
	var here: Vector3 = character.global_position if character.is_inside_tree() else character.position
	_compass.update_view(_camera_rig.get_yaw(), here,
			MarkerSource.build(_map, _client.get_fortress_view()))


# El mapa horneado de la zona del WELCOME (la de por defecto si aún no hay).
func _load_map(client: NetClient) -> ZoneMapDefinition:
	var welcome: NetMessages.Welcome = client.get_welcome()
	var zone_id: String = welcome.zone_id if welcome != null else NetZones.default_zone_id()
	return ZoneMapDefinition.load_for_zone(StringName(zone_id))
