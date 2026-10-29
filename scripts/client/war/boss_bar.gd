class_name BossBar
extends Control
## Barra de jefe (UI-18): la vida del PNJ con [code]is_boss[/code] más cercano (por el
## [code]npc_def_id[/code] de su ENTITY_SPAWN, ver [BossInfo]) mientras está a menos de
## [constant RANGE] m y vivo. Arriba al centro, bajo el panel de captura. La vida sale del registro
## dibujado de ese PNJ ([method RemotePlayerView.get_drawn_health_q]), la misma que usan las placas.
## [br][br]
## Con [method show_boss] se puede poner a mano (las pruebas). Medidas y colores provisionales.
## Solo cliente.

## Metros a los que se ve la barra de un jefe.
const RANGE: float = 90.0
const BAR_WIDTH: float = 520.0
const TOP_OFFSET: float = 118.0
const FILL_COLOR: Color = Color(0.72, 0.1, 0.12, 1.0)

var _client: NetClient = null
var _shown_id: int = 0
var _name_label: Label = null
var _bar: FractionBar = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ensure_built()
	visible = false


func _process(_delta: float) -> void:
	refresh()


func bind(client: NetClient) -> void:
	_client = client
	_ensure_built()


## Busca el jefe vivo más cercano a menos de [constant RANGE] m y lo muestra; si no hay, oculta la
## barra.
func refresh() -> void:
	if not is_instance_valid(_client):
		_hide()
		return
	var character: PlayerCharacter = _client.get_character()
	if character == null or not is_instance_valid(character):
		_hide()
		return
	var here: Vector3 = character.global_position if character.is_inside_tree() else character.position
	var best: RemotePlayerView = null
	var best_distance: float = RANGE
	for view: RemotePlayerView in _client.get_remote_world().get_views():
		if view.get_kind() != NetProtocol.EntityKind.NPC or not view.is_drawn() \
				or view.get_drawn_health_q() == EntityRecord.HEALTH_Q_DEAD \
				or not BossInfo.is_boss(view.get_npc_def_id()):
			continue
		var there: Vector3 = view.get_drawn_position()
		var distance: float = Vector2(there.x - here.x, there.z - here.z).length()
		if distance <= best_distance:
			best_distance = distance
			best = view
	if best == null:
		_hide()
		return
	show_boss(best.get_net_id(), best.get_display_name(),
			EntityRecord.health_fraction(best.get_drawn_health_q()))


## Muestra la barra del jefe [param net_id] con su nombre y su vida (0 a 1).
func show_boss(net_id: int, boss_name: String, health_fraction: float) -> void:
	_ensure_built()
	_shown_id = net_id
	_name_label.text = boss_name
	_bar.set_fraction(health_fraction)
	_bar.text = "%d %%" % roundi(clampf(health_fraction, 0.0, 1.0) * 100.0)
	visible = true


## Id de red del jefe que se muestra (0 si ninguno).
func get_shown_id() -> int:
	return _shown_id if visible else 0


func get_boss_name() -> String:
	return _name_label.text if _name_label != null else ""


func get_health_fraction() -> float:
	return _bar.get_fraction() if _bar != null else 0.0


func _hide() -> void:
	_shown_id = 0
	visible = false


func _ensure_built() -> void:
	if _bar != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	column.name = "Columna"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.anchor_left = 0.5
	column.anchor_right = 0.5
	column.offset_left = -BAR_WIDTH * 0.5
	column.offset_right = BAR_WIDTH * 0.5
	column.offset_top = TOP_OFFSET
	column.offset_bottom = TOP_OFFSET
	column.grow_vertical = Control.GROW_DIRECTION_END
	column.add_theme_constant_override(&"separation", 2)
	add_child(column)
	_name_label = Label.new()
	_name_label.name = "Nombre"
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_label.add_theme_font_size_override(&"font_size", 20)
	_name_label.add_theme_color_override(&"font_color", UIPalette.TITLE)
	_name_label.add_theme_color_override(&"font_outline_color", UIPalette.OUTLINE)
	_name_label.add_theme_constant_override(&"outline_size", 6)
	column.add_child(_name_label)
	_bar = FractionBar.new()
	_bar.name = "Vida"
	_bar.custom_minimum_size = Vector2(BAR_WIDTH, 20.0)
	_bar.fill_color = FILL_COLOR
	_bar.font_size = 14
	column.add_child(_bar)
