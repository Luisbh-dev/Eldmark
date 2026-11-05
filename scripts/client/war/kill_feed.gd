class_name KillFeed
extends Control
## Kill feed (UI-41, docs/fuerte.md section 6): one line for each KILL in the zone, at the top
## right, that lasts a few seconds and fades out: "Ana derrotó a Bruno con un golpe pesado (+2)" ("Ana defeated Bruno with a heavy strike (+2)").
## [br][br]
## KILLs go to the whole zone in phase 4, so kills by those who are not nearby are seen too
## ([signal NetClient.combat_event] delivers them at their draw tick). The event only carries ids: the names and
## the realms (the color of each name) come from the client's [PlayerDirectory], which remembers everyone
## who has been seen; someone never seen shows up as "Jugador N" ("Player N"). NPC kills only count if the victim is
## a boss ([BossInfo]); those by the environment ([code]killer = 0[/code]) show up as "Bruno cayó" ("Bruno fell"). Lines in
## which you take part (you kill, die or assist) carry a background so you can find them.
## [br][br]
## Since protocol 6 (docs/habilidades.md, section 5.4) the DOWNED events, which also go to the whole zone,
## leave their line: "Ana derribó a Bruno con una flecha lastrante" ("Ana knocked down Bruno with a weighted arrow") ([method show_downed]); the KILL that arrives
## afterward (finished off or bled out) leaves its own.
## [br][br]
## Provisional sizes, colors and durations. Client only.

## Lines at once at most (when another arrives, the oldest is removed).
const MAX_ENTRIES: int = 6
## Seconds a line lasts and how many of them are final fade.
const LIFETIME_SECONDS: float = 8.0
const FADE_SECONDS: float = 1.0
const FONT_SIZE: int = 16
const TOP_MARGIN: float = 16.0
const RIGHT_MARGIN: float = 16.0
const WIDTH: float = 520.0
const OWN_BACKGROUND: Color = Color(0.3, 0.17, 0.06, 0.78)
## Band of other people's lines and side (px) of the weapon icon.
const BAND_COLOR: Color = Color(0.03, 0.035, 0.05, 0.6)
const ICON_SIZE: float = 22.0
const TEXT_DEFEATED: String = " derrotó a "
const TEXT_DOWNED: String = " derribó a "
const TEXT_FELL: String = " cayó"
const TEXT_WITH: String = " con %s"
const TEXT_ASSISTS: String = " (+%d)"

## Role of the local player in a kill.
const ROLE_NONE: StringName = &""
const ROLE_KILLER: StringName = &"killer"
const ROLE_VICTIM: StringName = &"victim"
const ROLE_ASSIST: StringName = &"assist"

var _client: NetClient = null
var _directory: PlayerDirectory = null
var _column: VBoxContainer = null
var _entries: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ensure_built()


func _process(delta: float) -> void:
	advance(delta)


func _exit_tree() -> void:
	_disconnect()


## Connects the feed to the KILLs of [param client] and to its name directory.
func bind(client: NetClient) -> void:
	_disconnect()
	_client = client
	_directory = client.get_directory() if is_instance_valid(client) else null
	_ensure_built()
	if is_instance_valid(_client):
		_client.combat_event.connect(_on_combat_event)


## Shows the kill [param event] (an ENTITY_EVENT of type KILL). Returns the line's text or empty if it is
## not shown (it is not a KILL or it is the death of a non-boss NPC).
func show_kill(event: NetMessages.EntityEvent) -> String:
	if event == null or event.event != NetMessages.EntityEvent.Kind.KILL:
		return ""
	if _directory != null and _directory.kind_of(event.net_id) == NetProtocol.EntityKind.NPC \
			and not BossInfo.is_boss(_directory.npc_def_of(event.net_id)):
		return ""
	_ensure_built()
	var killer_name: String = _name_of(event.killer) if event.killer != 0 else ""
	var victim_name: String = _name_of(event.net_id)
	var attack_text: String = CombatText.attack_label(event.attack_id)
	if attack_text == CombatText.TEXT_UNKNOWN_ATTACK:
		# An unnamed attack (from an NPC, for example) adds nothing to the line.
		attack_text = ""
	var parts: PackedStringArray = line_parts(killer_name, victim_name, attack_text, event.assistants.size())
	var role: StringName = role_of(event, _own_id())
	var killer_color: Color = _color_of(event.killer)
	var victim_color: Color = _color_of(event.net_id)
	while _entries.size() >= MAX_ENTRIES:
		_remove_entry(0)
	var row: PanelContainer = _make_row(parts, killer_color, victim_color, role != ROLE_NONE,
			icon_for_source(event.attack_id), event.assistants.size())
	_column.add_child(row)
	var text: String = "".join(parts)
	_entries.append({"row": row, "left": LIFETIME_SECONDS, "text": text, "role": role,
			"killer": event.killer, "victim": event.net_id, "assistants": event.assistants.size()})
	return text


## Shows the knock-down [param event] (an ENTITY_EVENT of type DOWNED). Returns the line's text or empty
## if it is not a DOWNED.
func show_downed(event: NetMessages.EntityEvent) -> String:
	if event == null or event.event != NetMessages.EntityEvent.Kind.DOWNED:
		return ""
	_ensure_built()
	var attacker_name: String = _name_of(event.attacker) if event.attacker != 0 else ""
	var victim_name: String = _name_of(event.net_id)
	var attack_text: String = CombatText.source_label(event.attack_id)
	if attack_text == CombatText.TEXT_UNKNOWN_ATTACK:
		attack_text = ""
	var parts: PackedStringArray = line_parts(attacker_name, victim_name, attack_text, 0)
	if not attacker_name.is_empty():
		parts[1] = TEXT_DOWNED
	var own: int = _own_id()
	var role: StringName = ROLE_NONE
	if own != 0 and event.attacker == own:
		role = ROLE_KILLER
	elif own != 0 and event.net_id == own:
		role = ROLE_VICTIM
	while _entries.size() >= MAX_ENTRIES:
		_remove_entry(0)
	var row: PanelContainer = _make_row(parts, _color_of(event.attacker), _color_of(event.net_id),
			role != ROLE_NONE, icon_for_source(event.attack_id))
	_column.add_child(row)
	var text: String = "".join(parts)
	_entries.append({"row": row, "left": LIFETIME_SECONDS, "text": text, "role": role,
			"killer": event.attacker, "victim": event.net_id, "assistants": 0})
	return text


## The four parts of a line: who kills (empty if it is the environment), the verb, the victim and the ending
## ("con un tajo" ("with a slash"), "(+2)"). Joined they give the text.
static func line_parts(killer_name: String, victim_name: String, attack_text: String,
		assistant_count: int) -> PackedStringArray:
	var tail: String = ""
	if not attack_text.is_empty():
		tail += TEXT_WITH % attack_text
	if assistant_count > 0:
		tail += TEXT_ASSISTS % assistant_count
	if killer_name.is_empty():
		return PackedStringArray(["", "", victim_name, TEXT_FELL + tail])
	return PackedStringArray([killer_name, TEXT_DEFEATED, victim_name, tail])


## What role [param own_id] has in [param event]: kills, dies, assists or none.
static func role_of(event: NetMessages.EntityEvent, own_id: int) -> StringName:
	if own_id == 0:
		return ROLE_NONE
	if event.killer == own_id:
		return ROLE_KILLER
	if event.net_id == own_id:
		return ROLE_VICTIM
	if event.assistants.has(own_id):
		return ROLE_ASSIST
	return ROLE_NONE


## Advances [param delta] seconds: final fade and removal of the lines that end.
func advance(delta: float) -> void:
	var index: int = _entries.size() - 1
	while index >= 0:
		var entry: Dictionary = _entries[index]
		entry["left"] = float(entry["left"]) - delta
		if float(entry["left"]) <= 0.0:
			_remove_entry(index)
		else:
			(entry["row"] as Control).modulate.a = clampf(float(entry["left"]) / FADE_SECONDS, 0.0, 1.0)
		index -= 1


## Removes all lines.
func clear() -> void:
	while not _entries.is_empty():
		_remove_entry(0)


func get_entry_count() -> int:
	return _entries.size()


## Texts of the lines, from oldest to newest.
func get_texts() -> PackedStringArray:
	var texts := PackedStringArray()
	for entry: Dictionary in _entries:
		texts.append(String(entry["text"]))
	return texts


## Role of the local player in line [param index] ([constant ROLE_NONE] if not involved).
func get_role(index: int) -> StringName:
	return _entries[index]["role"] if index >= 0 and index < _entries.size() else ROLE_NONE


func get_seconds_left(index: int) -> float:
	return float(_entries[index]["left"]) if index >= 0 and index < _entries.size() else 0.0


## Color the name of [param net_id] is painted with (its realm's; the interface's white if not
## known).
func get_name_color(net_id: int) -> Color:
	return _color_of(net_id)


# --- Internal ---------------------------------------------------------------------------------

func _on_combat_event(event: NetMessages.EntityEvent, _is_own: bool) -> void:
	if event.event == NetMessages.EntityEvent.Kind.DOWNED:
		show_downed(event)
	else:
		show_kill(event)


func _disconnect() -> void:
	if is_instance_valid(_client) and _client.combat_event.is_connected(_on_combat_event):
		_client.combat_event.disconnect(_on_combat_event)


func _own_id() -> int:
	return _client.get_net_id() if is_instance_valid(_client) else 0


func _name_of(net_id: int) -> String:
	return _directory.name_of(net_id) if _directory != null else "Jugador %d" % net_id


func _color_of(net_id: int) -> Color:
	if _directory == null or net_id == 0 or not _directory.knows(net_id):
		return UIPalette.TEXT
	return UIPalette.faction_color_of_code(_directory.realm_of(net_id))


func _remove_entry(index: int) -> void:
	var row: Control = _entries[index]["row"]
	_entries.remove_at(index)
	if is_instance_valid(row):
		row.get_parent().remove_child(row)
		row.queue_free()


## Icon of the weapon, ability or effect of source [param source] ([CombatSource]) for a kill's
## line; null if it has no drawing (an NPC attack, the environment), and then the line uses the verb.
static func icon_for_source(source: int) -> Texture2D:
	if source == CombatSource.NONE:
		return null
	var id: int = CombatSource.id_of(source)
	match CombatSource.kind_of(source):
		CombatSource.Kind.ATTACK:
			var attack: AttackTicks = CombatCatalog.attack(id)
			if attack == null:
				return null
			var attack_name: String = String(attack.name)
			if attack_name.begins_with("sword_heavy"):
				return CombatIcons.named(&"sword_heavy")
			if attack_name.begins_with("sword"):
				return CombatIcons.named(&"sword_light")
			if attack_name.begins_with("bow") or attack_name.begins_with("arrow"):
				return CombatIcons.named(&"bow_quick")
		CombatSource.Kind.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(id)
			return CombatIcons.named(ability.name) if ability != null else null
		CombatSource.Kind.STATUS:
			var status: StatusTicks = CombatCatalog.status(id)
			return CombatIcons.named(status.name) if status != null else null
	return null


# A line over its band: the killer's name, the weapon icon (or the verb if there is none), the victim's
# name and the assists. The local player's lines get a more vivid band and an accent-colored edge.
func _make_row(parts: PackedStringArray, killer_color: Color, victim_color: Color,
		own: bool, icon: Texture2D = null, assist_count: int = 0) -> PanelContainer:
	var row := PanelContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_horizontal = Control.SIZE_SHRINK_END
	var style := StyleBoxFlat.new()
	style.bg_color = OWN_BACKGROUND if own else BAND_COLOR
	if own:
		style.border_color = UIPalette.ACCENT
		style.border_width_left = 3
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 2.0
	style.content_margin_bottom = 2.0
	style.set_corner_radius_all(3)
	row.add_theme_stylebox_override(&"panel", style)
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.alignment = BoxContainer.ALIGNMENT_END
	line.add_theme_constant_override(&"separation", 6)
	row.add_child(line)
	if parts[0].is_empty():
		# No author (the environment): "Bruno cayó" ("Bruno fell") and the ending as is.
		_add_label(line, parts[2], victim_color)
		_add_label(line, parts[3], UIPalette.TEXT_DIM)
		return row
	_add_label(line, parts[0], killer_color)
	if icon != null:
		var icon_rect := TextureRect.new()
		icon_rect.texture = icon
		icon_rect.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		line.add_child(icon_rect)
		if parts[1] == TEXT_DOWNED:
			# A knock-down (can be revived) does not read as a death: it keeps the verb after the icon.
			_add_label(line, parts[1].strip_edges(), UIPalette.TEXT_DIM)
		_add_label(line, parts[2], victim_color)
		if assist_count > 0:
			_add_label(line, TEXT_ASSISTS % assist_count, UIPalette.TEXT_DIM)
	else:
		_add_label(line, parts[1].strip_edges(), UIPalette.TEXT_DIM)
		_add_label(line, parts[2], victim_color)
		_add_label(line, parts[3], UIPalette.TEXT_DIM)
	return row


func _add_label(line: HBoxContainer, text: String, color: Color) -> void:
	if text.is_empty():
		return
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override(&"font", UIFonts.body_semibold())
	label.add_theme_font_size_override(&"font_size", FONT_SIZE)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_outline_color", UIPalette.OUTLINE)
	label.add_theme_constant_override(&"outline_size", 4)
	line.add_child(label)


func _ensure_built() -> void:
	if _column != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_column = VBoxContainer.new()
	_column.name = "Columna"
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.alignment = BoxContainer.ALIGNMENT_BEGIN
	_column.add_theme_constant_override(&"separation", 2)
	add_child(_column)
	_column.anchor_left = 1.0
	_column.anchor_right = 1.0
	_column.anchor_top = 0.0
	_column.anchor_bottom = 0.0
	_column.offset_left = -RIGHT_MARGIN - WIDTH
	_column.offset_right = -RIGHT_MARGIN
	_column.offset_top = TOP_MARGIN
	_column.offset_bottom = TOP_MARGIN
	_column.grow_vertical = Control.GROW_DIRECTION_END
