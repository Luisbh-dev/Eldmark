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
## [br]- [TelegraphMarks] (UI-18): las zonas de peligro de los ataques de los PNJ; es un nodo 3D y cuelga
## de la zona, no de este control.
## [br][br]
## Todo cuelga del cliente de red; sin él (el sandbox) no existe. Solo cliente.

var _client: NetClient = null
var _capture_panel: CapturePanel = null
var _banners: WarBanners = null
var _boss_bar: BossBar = null
var _telegraph_marks: TelegraphMarks = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _exit_tree() -> void:
	# Las marcas cuelgan de la zona: si esta interfaz desaparece antes, que no se queden allí.
	if is_instance_valid(_telegraph_marks) and _telegraph_marks.get_parent() != null:
		_telegraph_marks.get_parent().remove_child(_telegraph_marks)
		_telegraph_marks.free()
	_telegraph_marks = null


## Crea los elementos y los conecta con [param client] y la zona [param world]. Se puede llamar una vez.
func bind(client: NetClient, world: Node) -> void:
	_client = client
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
	var world_3d: Node3D = world as Node3D
	if world_3d != null:
		_telegraph_marks = TelegraphMarks.new()
		world_3d.add_child(_telegraph_marks)
		_telegraph_marks.bind(client)


func get_capture_panel() -> CapturePanel:
	return _capture_panel


func get_banners() -> WarBanners:
	return _banners


func get_boss_bar() -> BossBar:
	return _boss_bar


func get_telegraph_marks() -> TelegraphMarks:
	return _telegraph_marks
