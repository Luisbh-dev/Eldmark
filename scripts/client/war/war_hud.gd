class_name WarHud
extends Control
## War interface of the networked client (phase 4, docs/fortress.md section 6): gathers the elements that
## only make sense with a server and a fort, and connects them to the [NetClient]. The [HUD] creates it
## in [method HUD.bind_net] and keeps it above the nameplates and below the death screen.
## [br][br]
## Children (created in [method bind]):
## [br]- [CapturePanel] (UI-18): the state of the fort when near it or fighting for it.
## [br]- [WarBanners] (UI-18, GUE-13): the war notices.
## [br]- [BossBar] (UI-18): the health of the nearest boss.
## [br]- [TelegraphMarks] (UI-18): the danger zones of NPC attacks. It is a 3D node: since its
## parent is a control, Godot treats it as the root of the viewport's 3D world (its positions are global),
## and so it lives and dies with this interface without hanging anything from the zone.
## [br]- [Compass] and [WorldMarkers] (UI-19): the compass and the icons of the fort, the camps and the
## passes, with the zone's baked map ([ZoneMapDefinition]) for the fixed places.
## [br]- [KillFeed] (UI-41): the zone's kill log, top right. The scoreboard table
## ([ScoreboardPanel], Tab) and the game hints ([HintToasts], UI-42) are mounted by the [HUD] above the death
## screen (this interface is dimmed with it).
## [br]- [Minimap] (UI-20): the circular minimap, bottom right. The full-screen map
## ([WorldMap]) is mounted by the [HUD], above the death screen, with the same baked map
## ([method get_map]).
## [br][br]
## Everything hangs from the network client; without it (the sandbox) it does not exist. Client only.

var _client: NetClient = null
var _capture_panel: CapturePanel = null
var _banners: WarBanners = null
var _boss_bar: BossBar = null
var _telegraph_marks: TelegraphMarks = null
var _compass: Compass = null
var _objective_line: ObjectiveLine = null
var _minimap: Minimap = null
var _kill_feed: KillFeed = null
var _world_markers: WorldMarkers = null
var _camera_rig: CameraRig = null
var _map: ZoneMapDefinition = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(_delta: float) -> void:
	_update_compass()


## Creates the elements and connects them to [param client] and the camera [param camera_rig] (the compass and
## the markers look at it; it can be null). It can be called once.
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
	_objective_line = ObjectiveLine.new()
	_objective_line.name = "ObjectiveLine"
	add_child(_objective_line)
	_objective_line.bind(client, view, _capture_panel)
	_kill_feed = KillFeed.new()
	_kill_feed.name = "KillFeed"
	add_child(_kill_feed)
	_kill_feed.bind(client)
	_minimap = Minimap.new()
	_minimap.name = "Minimap"
	add_child(_minimap)
	_minimap.bind(client, view, camera_rig, _map)
	_telegraph_marks = TelegraphMarks.new()
	add_child(_telegraph_marks)
	_telegraph_marks.bind(client)


## Screen rectangles (in the coordinates of this control) of the notices in the middle of the screen that floating
## damage numbers must not cover: the band of the war notice and the boss bar, when they are visible.
func get_reserved_rects() -> Array[Rect2]:
	var rects: Array[Rect2] = []
	var origin: Vector2 = global_position
	if is_instance_valid(_banners) and _banners.is_band_visible():
		var band: Rect2 = _banners.get_band().get_global_rect()
		rects.append(Rect2(band.position - origin, band.size))
	if is_instance_valid(_boss_bar):
		var bar: Rect2 = _boss_bar.get_bar_rect()
		if bar.size != Vector2.ZERO:
			rects.append(Rect2(bar.position - origin, bar.size))
	return rects


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


func get_objective_line() -> ObjectiveLine:
	return _objective_line


func get_world_markers() -> WorldMarkers:
	return _world_markers


func get_minimap() -> Minimap:
	return _minimap


func get_kill_feed() -> KillFeed:
	return _kill_feed


## Baked map of the zone (null if it has none).
func get_map() -> ZoneMapDefinition:
	return _map


## Every frame it tells the compass where the camera is facing and where the player is.
func _update_compass() -> void:
	if _compass == null or not is_instance_valid(_camera_rig) or not is_instance_valid(_client):
		return
	var character: PlayerCharacter = _client.get_character()
	if character == null or not is_instance_valid(character):
		return
	var here: Vector3 = character.global_position if character.is_inside_tree() else character.position
	_compass.update_view(_camera_rig.get_yaw(), here,
			MarkerSource.build(_map, _client.get_fortress_view()))


# The baked map of the WELCOME zone (the default one if there is none yet).
func _load_map(client: NetClient) -> ZoneMapDefinition:
	var welcome: NetMessages.Welcome = client.get_welcome()
	var zone_id: String = welcome.zone_id if welcome != null else NetZones.default_zone_id()
	return ZoneMapDefinition.load_for_zone(StringName(zone_id))
