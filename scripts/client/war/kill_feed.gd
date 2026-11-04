class_name KillFeed
extends Control
## Registro de bajas (UI-41, docs/fuerte.md sección 6): una línea por cada KILL de la zona, arriba a la
## derecha, que dura unos segundos y se apaga con un fundido: «Ana derrotó a Bruno con un golpe pesado (+2)».
## [br][br]
## Los KILL van a toda la zona en la fase 4, así que se ven también las bajas de quien no está cerca
## ([signal NetClient.combat_event] los entrega en su tick de dibujo). El evento solo trae ids: los nombres y
## los reinos (el color de cada nombre) salen del [PlayerDirectory] del cliente, que recuerda a todo el que
## se ha visto; quien nunca se ha visto sale como «Jugador N». Las bajas de PNJ solo cuentan si la víctima es
## un jefe ([BossInfo]); las del entorno ([code]killer = 0[/code]) salen como «Bruno cayó». Las líneas en las
## que intervienes (matas, mueres o asistes) llevan un fondo para encontrarlas.
## [br][br]
## Desde el protocolo 6 (docs/habilidades.md, sección 5.4) los DOWNED, que también van a toda la zona,
## dejan su línea: «Ana derribó a Bruno con una flecha lastrante» ([method show_downed]); el KILL que llega
## después (rematado o desangrado) deja la suya.
## [br][br]
## Medidas, colores y duraciones provisionales. Solo cliente.

## Líneas a la vez como mucho (al llegar otra, se quita la más antigua).
const MAX_ENTRIES: int = 6
## Segundos que dura una línea y cuántos de ellos son de fundido final.
const LIFETIME_SECONDS: float = 8.0
const FADE_SECONDS: float = 1.0
const FONT_SIZE: int = 16
const TOP_MARGIN: float = 16.0
const RIGHT_MARGIN: float = 16.0
const WIDTH: float = 520.0
const OWN_BACKGROUND: Color = Color(0.3, 0.17, 0.06, 0.78)
## Banda de las líneas ajenas y lado (px) del icono del arma.
const BAND_COLOR: Color = Color(0.03, 0.035, 0.05, 0.6)
const ICON_SIZE: float = 22.0
const TEXT_DEFEATED: String = " derrotó a "
const TEXT_DOWNED: String = " derribó a "
const TEXT_FELL: String = " cayó"
const TEXT_WITH: String = " con %s"
const TEXT_ASSISTS: String = " (+%d)"

## Papel del jugador local en una baja.
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


## Conecta el registro con los KILL de [param client] y con su directorio de nombres.
func bind(client: NetClient) -> void:
	_disconnect()
	_client = client
	_directory = client.get_directory() if is_instance_valid(client) else null
	_ensure_built()
	if is_instance_valid(_client):
		_client.combat_event.connect(_on_combat_event)


## Muestra la baja [param event] (un ENTITY_EVENT de tipo KILL). Devuelve el texto de la línea o vacío si no
## se muestra (no es un KILL o es la muerte de un PNJ que no es jefe).
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
		# Un ataque sin nombre (de un PNJ, por ejemplo) no añade nada a la línea.
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


## Muestra el derribo [param event] (un ENTITY_EVENT de tipo DOWNED). Devuelve el texto de la línea o vacío
## si no es un DOWNED.
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


## Las cuatro partes de una línea: quién mata (vacío si es el entorno), el verbo, la víctima y el final
## («con un tajo», «(+2)»). Unidas dan el texto.
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


## Qué papel tiene [param own_id] en [param event]: mata, muere, asiste o ninguno.
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


## Avanza [param delta] segundos: fundido final y retirada de las líneas que acaban.
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


## Quita todas las líneas.
func clear() -> void:
	while not _entries.is_empty():
		_remove_entry(0)


func get_entry_count() -> int:
	return _entries.size()


## Textos de las líneas, de la más antigua a la más nueva.
func get_texts() -> PackedStringArray:
	var texts := PackedStringArray()
	for entry: Dictionary in _entries:
		texts.append(String(entry["text"]))
	return texts


## Papel del jugador local en la línea [param index] ([constant ROLE_NONE] si no interviene).
func get_role(index: int) -> StringName:
	return _entries[index]["role"] if index >= 0 and index < _entries.size() else ROLE_NONE


func get_seconds_left(index: int) -> float:
	return float(_entries[index]["left"]) if index >= 0 and index < _entries.size() else 0.0


## Color con el que se pinta el nombre de [param net_id] (el de su reino; el blanco de la interfaz si no se
## conoce).
func get_name_color(net_id: int) -> Color:
	return _color_of(net_id)


# --- Interno ----------------------------------------------------------------------------------

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


## Icono del arma, la habilidad o el efecto de la fuente [param source] ([CombatSource]) para la línea de
## una baja; null si no tiene dibujo (un ataque de PNJ, el entorno), y entonces la línea usa el verbo.
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


# Una línea sobre su banda: el nombre de quien mata, el icono del arma (o el verbo si no lo hay), el nombre de la
# víctima y las asistencias. Las líneas del jugador local van con una banda más viva y un filo del color de acento.
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
		# Sin autor (el entorno): «Bruno cayó» y el final tal cual.
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
