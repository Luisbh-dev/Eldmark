class_name ScoreboardPanel
extends Control
## Zone scoreboard (UI-41, docs/fuerte.md section 6): while Tab ([code]scoreboard[/code]) is held, a table
## is shown with one row per player (kills, deaths, assists, gate damage, time in the circle and merits),
## sorted by kills, and a summary per realm. The data is that of the last complete SCOREBOARD
## ([ScoreboardState], which the server sends every 2 s to the whole zone and which the client assembles
## from pages); each row's name and realm come from the [PlayerDirectory], because the message only carries
## ids.
## [br][br]
## [b]Known limitation.[/b] A player this client has never seen (always outside the interest radius) has no
## known name or realm: it appears as "Jugador N" (Player N), with no color. Fixing it is a protocol matter
## (names in the scoreboard or a player list message), not this interface's.
## [br][br]
## [b]The key.[/b] It opens when [code]scoreboard[/code] is pressed and closes when released, with any
## modifier held: Shift is sprint, Ctrl is dodge and Alt is release the cursor, so in the middle of combat
## Tab almost never arrives alone. If the release does not arrive (another node keeps it), it closes anyway
## as soon as [Input] sees the key released; when opened by code ([method open]) it does not close on its own.
## [br][br]
## The table is a [Tree] (fast and scrollable with hundreds of rows). The measurements, colors and texts
## are provisional. Client only.

const WIDTH: float = 900.0
const HEIGHT: float = 600.0
const FONT_SIZE: int = 15
const OWN_BACKGROUND: Color = Color(0.88, 0.51, 0.18, 0.3)

const TEXT_TITLE: String = "Marcador"
const TEXT_WAITING: String = "Esperando el marcador del servidor"
const TEXT_PLAYERS: String = "%d jugadores"
const TEXT_ONE_PLAYER: String = "1 jugador"
const TEXT_REFRESH: String = "Se actualiza cada 2 s · mantén %s"
const TEXT_REALM_SUMMARY: String = "%s: %s · %d bajas"
const TEXT_NO_REALM: String = "Sin reino conocido"

## Columns, in order, with their title.
const COLUMN_NAME: int = 0
const COLUMN_REALM: int = 1
const COLUMN_KILLS: int = 2
const COLUMN_DEATHS: int = 3
const COLUMN_ASSISTS: int = 4
const COLUMN_GATE: int = 5
const COLUMN_CIRCLE: int = 6
const COLUMN_MERITS: int = 7
const COLUMN_TITLES: PackedStringArray = ["Jugador", "Reino", "Bajas", "Muertes", "Asist.", "Daño a la puerta",
		"En el círculo", "Méritos"]
const COLUMN_MIN_WIDTHS: PackedInt32Array = [220, 100, 70, 80, 70, 130, 110, 90]

var _client: NetClient = null
var _state: ScoreboardState = null
var _directory: PlayerDirectory = null
var _open: bool = false
# true if the key opened it (and it closes when seeing the key released).
var _held_by_key: bool = false
var _shown_version: int = -1
var _entries: Array[Dictionary] = []
var _own_id: int = 0

var _frame: PanelContainer = null
var _summary: HBoxContainer = null
var _tree: Tree = null
var _footer: Label = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func _ready() -> void:
	_ensure_built()


func _process(_delta: float) -> void:
	# Safety net: opened with the key, it closes as soon as the key is released even if its release did not arrive.
	if _open and _held_by_key and InputMap.has_action(&"scoreboard") and not Input.is_action_pressed(&"scoreboard"):
		close()


func _exit_tree() -> void:
	if is_instance_valid(_client) and _client.scoreboard_updated.is_connected(_on_scoreboard_updated):
		_client.scoreboard_updated.disconnect(_on_scoreboard_updated)


func _notification(what: int) -> void:
	# With the window unfocused the key release will not arrive: it closes.
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _open:
		close()


func _unhandled_input(event: InputEvent) -> void:
	if not InputMap.has_action(&"scoreboard"):
		return
	# Without exact modifier matching: running (Shift) or dodging (Ctrl) also counts.
	if event.is_action_pressed(&"scoreboard"):
		open()
		_held_by_key = true
		get_viewport().set_input_as_handled()
	elif event.is_action_released(&"scoreboard"):
		close()


## Connects the scoreboard to the client: its data, the name directory and the own id.
func bind(client: NetClient) -> void:
	if is_instance_valid(_client) and _client.scoreboard_updated.is_connected(_on_scoreboard_updated):
		_client.scoreboard_updated.disconnect(_on_scoreboard_updated)
	_client = client
	_state = client.get_scoreboard() if is_instance_valid(client) else null
	_directory = client.get_directory() if is_instance_valid(client) else null
	_shown_version = -1
	_ensure_built()
	if is_instance_valid(_client):
		_client.scoreboard_updated.connect(_on_scoreboard_updated)
	if _open:
		refresh()


func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	refresh(true)


func close() -> void:
	if not _open:
		return
	_open = false
	_held_by_key = false
	visible = false


func is_open() -> bool:
	return _open


## Repaints the table if there is a new scoreboard (or always with [param force]). It only works while open.
func refresh(force: bool = false) -> void:
	if not _open:
		return
	_ensure_built()
	_own_id = _client.get_net_id() if is_instance_valid(_client) else 0
	var version: int = _state.version if _state != null else 0
	if not force and version == _shown_version:
		return
	_shown_version = version
	var rows: Array[NetMessages.ScoreRow] = []
	if _state != null:
		rows = _state.get_rows()
	_entries = build_entries(rows, _directory, _own_id)
	_fill_tree()
	_fill_summary()
	_footer.text = _footer_text()


# --- Data (pure) ------------------------------------------------------------------------------

## The rows of [param rows] ready to display, sorted ([method ScoreboardState.sort_rows]): each one
## [code]{net_id, name, realm, kills, deaths, assists, gate_damage, circle_seconds, merits, own}[/code].
static func build_entries(rows: Array[NetMessages.ScoreRow], directory: PlayerDirectory,
		own_id: int) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for row: NetMessages.ScoreRow in ScoreboardState.sort_rows(rows):
		entries.append({
			"net_id": row.net_id,
			"name": directory.name_of(row.net_id) if directory != null else "Jugador %d" % row.net_id,
			"realm": directory.realm_of(row.net_id) if directory != null else NetProtocol.Realm.NONE,
			"kills": row.kills, "deaths": row.deaths, "assists": row.assists,
			"gate_damage": row.gate_damage, "circle_seconds": row.circle_seconds, "merits": row.merits,
			"own": own_id != 0 and row.net_id == own_id,
		})
	return entries


## Totals per realm (network code; 0 = no known realm) of [param entries]:
## [code]{players, kills, deaths, assists, gate_damage, circle_seconds, merits}[/code].
static func realm_totals(entries: Array[Dictionary]) -> Dictionary:
	var totals: Dictionary = {}
	for entry: Dictionary in entries:
		var realm: int = int(entry["realm"])
		if not totals.has(realm):
			totals[realm] = {"players": 0, "kills": 0, "deaths": 0, "assists": 0, "gate_damage": 0,
					"circle_seconds": 0, "merits": 0}
		var total: Dictionary = totals[realm]
		total["players"] += 1
		for key: String in ["kills", "deaths", "assists", "gate_damage", "circle_seconds", "merits"]:
			total[key] += int(entry[key])
	return totals


## The cells of [param entry] as text, one per column.
static func cells_of(entry: Dictionary) -> PackedStringArray:
	var realm: int = int(entry["realm"])
	return PackedStringArray([
		String(entry["name"]),
		NetProtocol.realm_display_name(realm) if realm != NetProtocol.Realm.NONE else "-",
		format_count(int(entry["kills"])),
		format_count(int(entry["deaths"])),
		format_count(int(entry["assists"])),
		format_count(int(entry["gate_damage"])),
		format_time(int(entry["circle_seconds"])),
		format_count(int(entry["merits"])),
	])


## Number with thousands separators as periods ("12.345").
static func format_count(value: int) -> String:
	var digits: String = str(absi(value))
	var grouped: String = ""
	while digits.length() > 3:
		grouped = "." + digits.substr(digits.length() - 3) + grouped
		digits = digits.substr(0, digits.length() - 3)
	return ("-" if value < 0 else "") + digits + grouped


## Seconds as "m:ss" ("2:05"); with hours, "h:mm:ss".
@warning_ignore("integer_division")
static func format_time(seconds: int) -> String:
	var total: int = maxi(seconds, 0)
	if total >= 3600:
		return "%d:%02d:%02d" % [total / 3600, (total % 3600) / 60, total % 60]
	return "%d:%02d" % [total / 60, total % 60]


# --- Accessors (for the tests and for whoever assembles the interface) ------------------------

## Rows being shown (sorted).
func get_entries() -> Array[Dictionary]:
	return _entries.duplicate()


func get_row_count() -> int:
	return _entries.size()


## Cells of row [param index] as text (empty if it does not exist).
func get_cells(index: int) -> PackedStringArray:
	return cells_of(_entries[index]) if index >= 0 and index < _entries.size() else PackedStringArray()


func is_own_row(index: int) -> bool:
	return index >= 0 and index < _entries.size() and bool(_entries[index]["own"])


## Summary per realm (one line per realm with players), in realm order.
func get_summary_lines() -> PackedStringArray:
	return summary_lines(_entries)


static func summary_lines(entries: Array[Dictionary]) -> PackedStringArray:
	var lines := PackedStringArray()
	var totals: Dictionary = realm_totals(entries)
	for realm: int in [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH, NetProtocol.Realm.ASKARRA,
			NetProtocol.Realm.NONE]:
		if not totals.has(realm):
			continue
		var total: Dictionary = totals[realm]
		var players: String = TEXT_ONE_PLAYER if int(total["players"]) == 1 else TEXT_PLAYERS % int(total["players"])
		var realm_name: String = NetProtocol.realm_display_name(realm) if realm != NetProtocol.Realm.NONE \
				else TEXT_NO_REALM
		lines.append(TEXT_REALM_SUMMARY % [realm_name, players, int(total["kills"])])
	return lines


func get_footer_text() -> String:
	return _footer.text if _footer != null else ""


## The table (for whoever wants to look inside).
func get_tree_control() -> Tree:
	return _tree


## Table rows already painted.
func get_tree_row_count() -> int:
	if _tree == null or _tree.get_root() == null:
		return 0
	return _tree.get_root().get_child_count()


# --- Internal ---------------------------------------------------------------------------------

func _on_scoreboard_updated(_scoreboard: ScoreboardState) -> void:
	if _open:
		refresh()


func _footer_text() -> String:
	if _entries.is_empty():
		return TEXT_WAITING
	var players: String = TEXT_ONE_PLAYER if _entries.size() == 1 else TEXT_PLAYERS % _entries.size()
	var key: String = UIKeyGlyph.label_for_action(&"scoreboard") if InputMap.has_action(&"scoreboard") else "Tab"
	return "%s · %s" % [players, TEXT_REFRESH % key]


func _fill_tree() -> void:
	_tree.clear()
	var root: TreeItem = _tree.create_item()
	for entry: Dictionary in _entries:
		var item: TreeItem = _tree.create_item(root)
		var cells: PackedStringArray = cells_of(entry)
		var realm_color: Color = UIPalette.faction_color_of_code(int(entry["realm"])) \
				if int(entry["realm"]) != NetProtocol.Realm.NONE else UIPalette.TEXT
		for column: int in cells.size():
			item.set_text(column, cells[column])
			item.set_selectable(column, false)
			if column >= COLUMN_KILLS:
				item.set_text_alignment(column, HORIZONTAL_ALIGNMENT_RIGHT)
			item.set_custom_color(column, realm_color if column <= COLUMN_REALM else UIPalette.TEXT)
			if bool(entry["own"]):
				item.set_custom_bg_color(column, OWN_BACKGROUND)


func _fill_summary() -> void:
	for child: Node in _summary.get_children():
		_summary.remove_child(child)
		child.queue_free()
	var totals: Dictionary = realm_totals(_entries)
	for realm: int in [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH, NetProtocol.Realm.ASKARRA,
			NetProtocol.Realm.NONE]:
		if not totals.has(realm):
			continue
		var label := Label.new()
		label.text = summary_lines(_entries_of_realm(realm))[0]
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_size_override(&"font_size", FONT_SIZE)
		label.add_theme_color_override(&"font_color", UIPalette.faction_color_of_code(realm)
				if realm != NetProtocol.Realm.NONE else UIPalette.TEXT_DIM)
		_summary.add_child(label)


func _entries_of_realm(realm: int) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for entry: Dictionary in _entries:
		if int(entry["realm"]) == realm:
			found.append(entry)
	return found


func _ensure_built() -> void:
	if _frame != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.name = "Centro"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame = PanelContainer.new()
	_frame.name = "Marco"
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.custom_minimum_size = Vector2(WIDTH, HEIGHT)
	var style := StyleBoxFlat.new()
	style.bg_color = UIPalette.WINDOW_BG
	style.border_color = UIPalette.BORDER_LIGHT
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(16.0)
	_frame.add_theme_stylebox_override(&"panel", style)
	center.add_child(_frame)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 10)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.add_child(column)
	var title := Label.new()
	title.name = "Titulo"
	title.text = TEXT_TITLE
	title.add_theme_font_size_override(&"font_size", 26)
	title.add_theme_color_override(&"font_color", UIPalette.TITLE)
	column.add_child(title)
	_summary = HBoxContainer.new()
	_summary.name = "Resumen"
	_summary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_summary.add_theme_constant_override(&"separation", 24)
	column.add_child(_summary)
	_tree = Tree.new()
	_tree.name = "Tabla"
	_tree.columns = COLUMN_TITLES.size()
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.focus_mode = Control.FOCUS_NONE
	_tree.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.add_theme_font_size_override(&"font_size", FONT_SIZE)
	_tree.add_theme_font_size_override(&"title_button_font_size", FONT_SIZE)
	for column_index: int in COLUMN_TITLES.size():
		_tree.set_column_title(column_index, COLUMN_TITLES[column_index])
		_tree.set_column_custom_minimum_width(column_index, COLUMN_MIN_WIDTHS[column_index])
		_tree.set_column_expand(column_index, column_index == COLUMN_NAME)
		if column_index >= COLUMN_KILLS:
			_tree.set_column_title_alignment(column_index, HORIZONTAL_ALIGNMENT_RIGHT)
	column.add_child(_tree)
	_footer = Label.new()
	_footer.name = "Pie"
	_footer.add_theme_font_size_override(&"font_size", FONT_SIZE - 1)
	_footer.add_theme_color_override(&"font_color", UIPalette.TEXT_DIM)
	column.add_child(_footer)
