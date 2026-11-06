class_name BossBar
extends Control
## Boss bar (UI-18): the health of the nearest NPC with [code]is_boss[/code] (by the
## [code]npc_def_id[/code] of its ENTITY_SPAWN, see [BossInfo]) while it is within
## [constant RANGE] m and alive. At the top center, below the capture panel. Health comes from that NPC's
## drawn record ([method RemotePlayerView.get_drawn_health_q]), the same one the nameplates use.
## [br][br]
## With [method show_boss] it can be set by hand (tests). Provisional sizes and colors.
## Client only.

## Meters at which a boss's bar is visible.
const RANGE: float = 90.0
const BAR_WIDTH: float = 520.0
const TOP_OFFSET: float = 316.0
const FILL_COLOR: Color = UIPalette.BOSS

## Seconds that "fighting" lasts after each hit between the player and the boss.
const ENGAGE_SECONDS: float = 8.0

var _client: NetClient = null
var _clock: float = 0.0
# Boss net_id -> second (of the bar's clock) until which it is considered "fighting".
var _engaged: Dictionary[int, float] = {}
var _shown_id: int = 0
var _name_label: Label = null
var _bar: FractionBar = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ensure_built()
	visible = false


func _process(delta: float) -> void:
	_clock += delta
	refresh()


func _exit_tree() -> void:
	if is_instance_valid(_client) and _client.combat_event.is_connected(_on_combat_event):
		_client.combat_event.disconnect(_on_combat_event)


func bind(client: NetClient) -> void:
	if is_instance_valid(_client) and _client.combat_event.is_connected(_on_combat_event):
		_client.combat_event.disconnect(_on_combat_event)
	_client = client
	_engaged.clear()
	_ensure_built()
	if is_instance_valid(_client):
		_client.combat_event.connect(_on_combat_event)


## Marks as "fighting" with boss [param net_id] for [constant ENGAGE_SECONDS] s (a hit from the player
## to the boss or from the boss to the player). Until then the bar does not appear (UI-18).
func engage(net_id: int) -> void:
	_engaged[net_id] = _clock + ENGAGE_SECONDS


## true if the player is fighting boss [param net_id] right now.
func is_engaged(net_id: int) -> bool:
	return _engaged.has(net_id) and _clock <= float(_engaged[net_id])


# A hit between the local player and another entity opens the fight with it (it only counts if it is a boss).
func _on_combat_event(event: NetMessages.EntityEvent, _is_own: bool) -> void:
	if event.event != NetMessages.EntityEvent.Kind.HIT or not is_instance_valid(_client):
		return
	var own: int = _client.get_net_id()
	if own == 0:
		return
	if event.attacker == own:
		engage(event.net_id)
	elif event.net_id == own and event.attacker != 0:
		engage(event.attacker)


# Removes expired fights: without this, every hit on a new entity (respawning NPCs) would leave its entry behind.
func _purge_expired() -> void:
	for net_id: int in _engaged.keys():
		if _clock > float(_engaged[net_id]):
			_engaged.erase(net_id)


## Finds the nearest living boss within [constant RANGE] m that is being fought ([method is_engaged]) and
## shows it; if there is none, hides the bar.
func refresh() -> void:
	if not is_instance_valid(_client):
		_hide()
		return
	var character: PlayerCharacter = _client.get_character()
	if character == null or not is_instance_valid(character):
		_hide()
		return
	var here: Vector3 = character.global_position if character.is_inside_tree() else character.position
	_purge_expired()
	var best: RemotePlayerView = null
	var best_distance: float = RANGE
	for view: RemotePlayerView in _client.get_remote_world().get_views():
		if view.get_kind() != NetProtocol.EntityKind.NPC or not view.is_drawn() \
				or view.get_drawn_health_q() == EntityRecord.HEALTH_Q_DEAD \
				or not BossInfo.is_boss(view.get_npc_def_id()) or not is_engaged(view.get_net_id()):
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


## Shows the bar of boss [param net_id] with its name and health (0 to 1).
func show_boss(net_id: int, boss_name: String, health_fraction: float) -> void:
	_ensure_built()
	_shown_id = net_id
	_name_label.text = boss_name
	_bar.set_fraction(health_fraction)
	_bar.text = "%d %%" % roundi(clampf(health_fraction, 0.0, 1.0) * 100.0)
	visible = true


## Network id of the boss being shown (0 if none).
func get_shown_id() -> int:
	return _shown_id if visible else 0


func get_boss_name() -> String:
	return _name_label.text if _name_label != null else ""


func get_health_fraction() -> float:
	return _bar.get_fraction() if _bar != null else 0.0


## Screen rectangle taken by the name and the bar (empty while the bar is not visible).
func get_bar_rect() -> Rect2:
	if not visible or _bar == null or not is_inside_tree():
		return Rect2()
	return (_bar.get_parent() as Control).get_global_rect()


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
	_name_label.add_theme_font_override(&"font", UIFonts.title_bold())
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
