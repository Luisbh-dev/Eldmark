extends TestCase
## Tests for the scoreboard (Tab) and the kill feed (UI-41, docs/fuerte.md section 6): the table
## ([ScoreboardPanel]: order, names and realms from the directory, totals per realm, formats, pages, opening and
## closing with the key) and the feed lines ([KillFeed]: text, colors, local player's role,
## NPC, environment, fade and cap). Without a server: a fake client emits the events and the scoreboard pages
## are synthetic.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
const OWN_ID: int = 5
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"


## Network client that connects to nothing.
class FakeClient extends NetClient:
	var fake_config: ClientConfig = ClientConfig.new()

	func get_net_id() -> int:
		return OWN_ID

	func get_config() -> ClientConfig:
		return fake_config


var _root: Node = null
var _nodes: Array[Node] = []


func before_each() -> void:
	_root = Node.new()
	_root.name = "ScoreboardTest"
	tree.root.add_child(_root)
	BossInfo.resolver = Callable()
	BossInfo.clear_cache()
	InputBindings.ensure_defaults()


func after_each() -> void:
	BossInfo.resolver = Callable()
	BossInfo.clear_cache()
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


func _track(node: Node, parent: Node = null) -> Node:
	(parent if parent != null else _root).add_child(node)
	_nodes.append(node)
	return node


func _make_client() -> FakeClient:
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	client.fake_config.realm = VARDHEIM
	client.get_directory().remember(OWN_ID, "Yo", VARDHEIM)
	client.get_directory().remember(11, "Ana", VARDHEIM)
	client.get_directory().remember(12, "Bruno", SOLMARCH)
	client.get_directory().remember(13, "Carla", SOLMARCH)
	client.get_directory().remember(14, "Dani", ASKARRA)
	return client


func _rows() -> Array[NetMessages.ScoreRow]:
	var rows: Array[NetMessages.ScoreRow] = []
	rows.append(NetMessages.ScoreRow.make(11, 4, 2, 1, 1500, 75, 120))
	rows.append(NetMessages.ScoreRow.make(12, 9, 3, 0, 0, 0, 300))
	rows.append(NetMessages.ScoreRow.make(OWN_ID, 4, 1, 5, 12345, 3725, 90))
	rows.append(NetMessages.ScoreRow.make(13, 4, 1, 2, 0, 5, 10))
	rows.append(NetMessages.ScoreRow.make(99, 0, 0, 0, 0, 0, 0))
	return rows


## Publishes [param rows] on the client's scoreboard as they would arrive from the server (one or several pages).
func _publish(client: FakeClient, rows: Array[NetMessages.ScoreRow]) -> void:
	for page: NetMessages.Scoreboard in NetMessages.Scoreboard.split(rows):
		client._on_scoreboard(page.encode())


func _key_event(pressed: bool, shift: bool = false, ctrl: bool = false, alt: bool = false) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_TAB
	event.pressed = pressed
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	event.alt_pressed = alt
	return event


## A key [param keycode] pressed or released as the system would send it: it goes through [Input] (which holds the state
## of the actions) and reaches the window.
func _send_key(keycode: Key, pressed: bool, shift: bool = false) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.pressed = pressed
	event.shift_pressed = shift
	Input.parse_input_event(event)
	Input.flush_buffered_events()


# --- Data -------------------------------------------------------------------------------------

func test_the_rows_are_sorted_and_named_from_the_directory() -> void:
	var client: FakeClient = _make_client()
	var entries: Array[Dictionary] = ScoreboardPanel.build_entries(_rows(), client.get_directory(), OWN_ID)
	assert_eq(entries.size(), 5)
	var order: Array[int] = []
	for entry: Dictionary in entries:
		order.append(int(entry["net_id"]))
	assert_eq(order, [12, OWN_ID, 13, 11, 99] as Array[int],
			"most kills first; on a tie, fewer deaths and then more assists")
	assert_eq(entries[0]["name"], "Bruno")
	assert_eq(entries[0]["realm"], SOLMARCH)
	assert_false(bool(entries[0]["own"]))
	assert_true(bool(entries[1]["own"]), "the own row is marked")
	assert_eq(entries[4]["name"], "Jugador 99", "someone not yet seen shows up by their id")
	assert_eq(entries[4]["realm"], NetProtocol.Realm.NONE, "and with no realm")
	var without_directory: Array[Dictionary] = ScoreboardPanel.build_entries(_rows(), null, 0)
	assert_eq(without_directory[0]["name"], "Jugador 12", "without a directory, too")
	assert_false(bool(without_directory[1]["own"]), "and without an own id nobody is the own")


func test_totals_per_realm_and_the_summary_lines() -> void:
	var client: FakeClient = _make_client()
	var entries: Array[Dictionary] = ScoreboardPanel.build_entries(_rows(), client.get_directory(), OWN_ID)
	var totals: Dictionary = ScoreboardPanel.realm_totals(entries)
	assert_eq(int(totals[VARDHEIM]["players"]), 2, "Vardheim: Ana and the own")
	assert_eq(int(totals[VARDHEIM]["kills"]), 8)
	assert_eq(int(totals[VARDHEIM]["gate_damage"]), 13845)
	assert_eq(int(totals[SOLMARCH]["players"]), 2)
	assert_eq(int(totals[SOLMARCH]["kills"]), 13)
	assert_eq(int(totals[NetProtocol.Realm.NONE]["players"]), 1, "the unknown player goes separately")
	assert_false(totals.has(ASKARRA), "Askarra has nobody in the rows")
	var lines: PackedStringArray = ScoreboardPanel.summary_lines(entries)
	assert_eq(lines.size(), 3, "Vardheim, Solmarch and those with no realm")
	assert_eq(lines[0], "Vardheim: 2 jugadores · 8 bajas")
	assert_eq(lines[1], "Solmarch: 2 jugadores · 13 bajas")
	assert_eq(lines[2], "Sin reino conocido: 1 jugador · 0 bajas")


func test_counts_and_times_are_formatted_in_spanish() -> void:
	assert_eq(ScoreboardPanel.format_count(0), "0")
	assert_eq(ScoreboardPanel.format_count(999), "999")
	assert_eq(ScoreboardPanel.format_count(1000), "1.000")
	assert_eq(ScoreboardPanel.format_count(12345), "12.345")
	assert_eq(ScoreboardPanel.format_count(1234567), "1.234.567")
	assert_eq(ScoreboardPanel.format_count(-4500), "-4.500")
	assert_eq(ScoreboardPanel.format_time(0), "0:00")
	assert_eq(ScoreboardPanel.format_time(75), "1:15")
	assert_eq(ScoreboardPanel.format_time(3725), "1:02:05")
	assert_eq(ScoreboardPanel.format_time(-3), "0:00")
	var entry: Dictionary = ScoreboardPanel.build_entries(_rows(), _make_client().get_directory(), OWN_ID)[1]
	assert_eq(ScoreboardPanel.cells_of(entry), PackedStringArray(["Yo", "Vardheim", "4", "1", "5", "12.345",
			"1:02:05", "90"]), "the eight columns of the own row")


# --- The table --------------------------------------------------------------------------------

func _make_panel(client: FakeClient) -> ScoreboardPanel:
	var panel: ScoreboardPanel = _track(ScoreboardPanel.new()) as ScoreboardPanel
	panel.bind(client)
	return panel


func test_the_panel_shows_the_last_complete_scoreboard_only_while_open() -> void:
	var client: FakeClient = _make_client()
	var panel: ScoreboardPanel = _make_panel(client)
	assert_false(panel.is_open() or panel.visible, "closed at the start")
	_publish(client, _rows())
	assert_eq(panel.get_row_count(), 0, "closed it does no work: nothing to paint")
	panel.open()
	assert_true(panel.is_open() and panel.visible)
	assert_eq(panel.get_row_count(), 5, "on opening it paints the latest scoreboard")
	assert_eq(panel.get_tree_row_count(), 5, "and the table has its five rows")
	assert_eq(panel.get_cells(0)[0], "Bruno")
	assert_true(panel.is_own_row(1), "the own row highlighted")
	assert_eq(panel.get_footer_text(), "5 jugadores · Se actualiza cada 2 s · mantén Tab")
	assert_eq(panel.get_summary_lines().size(), 3)
	# A new scoreboard while it is open is painted on its own.
	var more: Array[NetMessages.ScoreRow] = _rows()
	more.append(NetMessages.ScoreRow.make(14, 20, 0, 0, 0, 0, 0))
	_publish(client, more)
	assert_eq(panel.get_row_count(), 6)
	assert_eq(panel.get_cells(0)[0], "Dani", "with 20 kills, the first")
	panel.close()
	assert_false(panel.visible)
	_publish(client, _rows())
	assert_eq(panel.get_row_count(), 6, "closed, it is not rebuilt")
	panel.close()
	panel.open()
	assert_eq(panel.get_row_count(), 5, "but on reopening it shows the latest")


func test_the_panel_waits_for_the_server_when_there_is_no_scoreboard_yet() -> void:
	var panel: ScoreboardPanel = _make_panel(_make_client())
	panel.open()
	assert_eq(panel.get_row_count(), 0)
	assert_eq(panel.get_footer_text(), ScoreboardPanel.TEXT_WAITING)
	assert_eq(panel.get_tree_row_count(), 0)


func test_a_scoreboard_in_several_pages_is_shown_whole() -> void:
	var client: FakeClient = _make_client()
	var panel: ScoreboardPanel = _make_panel(client)
	panel.open()
	var rows: Array[NetMessages.ScoreRow] = []
	for i: int in 150:
		rows.append(NetMessages.ScoreRow.make(1000 + i, i, 0, 0, 0, 0, 0))
	var pages: Array[NetMessages.Scoreboard] = NetMessages.Scoreboard.split(rows)
	assert_eq(pages.size(), 3, "150 rows are three pages")
	client._on_scoreboard(pages[0].encode())
	client._on_scoreboard(pages[1].encode())
	assert_eq(panel.get_row_count(), 0, "with two of three pages it is not published")
	client._on_scoreboard(pages[2].encode())
	assert_eq(panel.get_row_count(), 150)
	assert_eq(panel.get_tree_row_count(), 150)
	assert_eq(panel.get_cells(0)[0], "Jugador 1149", "sorted by kills: the last row has 149")
	assert_true(panel.get_footer_text().begins_with("150 jugadores"), "the footer counts the players")


func test_holding_tab_opens_the_panel_and_releasing_closes_it() -> void:
	var client: FakeClient = _make_client()
	var panel: ScoreboardPanel = _make_panel(client)
	panel._unhandled_input(_key_event(true))
	assert_true(panel.is_open(), "Tab pressed: open")
	panel._unhandled_input(_key_event(true))
	assert_true(panel.is_open(), "and keyboard repeat does not close it")
	panel._unhandled_input(_key_event(false))
	assert_false(panel.is_open(), "released: closed")
	panel.open()
	panel.propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_false(panel.is_open(), "and without window focus it closes too")


## Phase 4 review (client): Shift is sprint, Ctrl is dodge and Alt releases the cursor, so in the middle of
## combat Tab almost always arrives with one of them held. With exact modifier matching, while running it did not
## open and, if Tab was released with Shift held, the table stayed open covering the center of the screen.
func test_tab_opens_and_closes_with_the_combat_modifiers_held() -> void:
	var panel: ScoreboardPanel = _make_panel(_make_client())
	panel._unhandled_input(_key_event(true, true))
	assert_true(panel.is_open(), "while running (Shift+Tab) it opens")
	panel._unhandled_input(_key_event(false, true))
	assert_false(panel.is_open(), "and releasing Tab without releasing Shift closes it")
	panel._unhandled_input(_key_event(true, false, true))
	assert_true(panel.is_open(), "Ctrl+Tab (dodging) opens it")
	panel._unhandled_input(_key_event(false))
	assert_false(panel.is_open(), "and releasing Tab after Ctrl closes it")
	panel._unhandled_input(_key_event(true))
	assert_true(panel.is_open(), "Tab alone opens it")
	panel._unhandled_input(_key_event(false, true))
	assert_false(panel.is_open(), "and if you start running before releasing it, it closes too")
	panel._unhandled_input(_key_event(true, false, false, true))
	assert_true(panel.is_open(), "with Alt (cursor released) too")
	panel._unhandled_input(_key_event(false, false, false, true))
	assert_false(panel.is_open())


func test_the_real_keys_open_and_close_it_while_sprinting() -> void:
	var panel: ScoreboardPanel = _make_panel(_make_client())
	_send_key(KEY_SHIFT, true, true)
	_send_key(KEY_TAB, true, true)
	var opened: bool = panel.is_open()
	_send_key(KEY_TAB, false, true)
	var still_open: bool = panel.is_open()
	_send_key(KEY_SHIFT, false)
	await wait_process_frames(2)
	assert_true(opened, "with Shift held (running), Tab opens the scoreboard through the real input")
	assert_false(still_open, "and releasing Tab with Shift still held closes it")
	assert_false(panel.is_open() or panel.visible, "and it stays closed")


func test_it_closes_by_itself_when_the_key_is_up_although_its_release_never_arrived() -> void:
	var panel: ScoreboardPanel = _make_panel(_make_client())
	# The press arrives, but the key is no longer pressed as far as Input is concerned (another node took the release).
	panel._unhandled_input(_key_event(true))
	assert_true(panel.is_open())
	await wait_process_frames(2)
	assert_false(panel.is_open(), "with Tab released, the safety net closes it")
	# Opened by code (without the key), it does not close on its own.
	panel.open()
	await wait_process_frames(2)
	assert_true(panel.is_open(), "opened without the key, it stays")
	panel.close()


# --- The kill feed ----------------------------------------------------------------------------

func _make_feed(client: FakeClient) -> KillFeed:
	var feed: KillFeed = _track(KillFeed.new()) as KillFeed
	feed.bind(client)
	return feed


func test_a_kill_becomes_a_line_with_killer_victim_attack_and_assists() -> void:
	var client: FakeClient = _make_client()
	var feed: KillFeed = _make_feed(client)
	var heavy: int = CombatCatalog.attack_id(&"sword_heavy")
	assert_eq(feed.show_kill(NetMessages.EntityEvent.kill(12, 500, 11, heavy, PackedInt32Array([13, 14]))),
			"Ana derrotó a Bruno con un golpe pesado (+2)")
	assert_eq(feed.show_kill(NetMessages.EntityEvent.kill(13, 510, 11, 0, PackedInt32Array())),
			"Ana derrotó a Carla", "with no known attack or assists, only the essentials")
	assert_eq(feed.show_kill(NetMessages.EntityEvent.kill(14, 520, 0, 0, PackedInt32Array())),
			"Dani cayó", "with no author (the environment), it fell")
	assert_eq(feed.show_kill(NetMessages.EntityEvent.kill(12, 530, 4242, 9999, PackedInt32Array())),
			"Jugador 4242 derrotó a Bruno", "an unknown killer shows up by their id and an unnamed attack is not mentioned")
	assert_eq(feed.get_entry_count(), 4)
	assert_eq(feed.show_kill(NetMessages.EntityEvent.hit(12, 1, 11, 10, 0, 0, 1)), "", "only the KILLs")
	assert_eq(feed.show_kill(null), "")
	assert_eq(feed.get_name_color(11), RealmCatalog.color_of(RealmCatalog.VARDHEIM), "the name, in the color of their realm")
	assert_eq(feed.get_name_color(12), RealmCatalog.color_of(RealmCatalog.SOLMARCH))
	assert_eq(feed.get_name_color(4242), UIPalette.TEXT, "with no known realm, the normal color")


func test_the_local_players_role_in_a_kill_is_marked() -> void:
	var client: FakeClient = _make_client()
	var feed: KillFeed = _make_feed(client)
	feed.show_kill(NetMessages.EntityEvent.kill(12, 500, OWN_ID, 0, PackedInt32Array()))
	feed.show_kill(NetMessages.EntityEvent.kill(OWN_ID, 510, 12, 0, PackedInt32Array()))
	feed.show_kill(NetMessages.EntityEvent.kill(13, 520, 11, 0, PackedInt32Array([OWN_ID])))
	feed.show_kill(NetMessages.EntityEvent.kill(14, 530, 11, 0, PackedInt32Array()))
	assert_eq(feed.get_role(0), KillFeed.ROLE_KILLER)
	assert_eq(feed.get_role(1), KillFeed.ROLE_VICTIM)
	assert_eq(feed.get_role(2), KillFeed.ROLE_ASSIST)
	assert_eq(feed.get_role(3), KillFeed.ROLE_NONE)
	assert_eq(feed.get_texts()[1], "Bruno derrotó a Yo")
	assert_eq(KillFeed.role_of(NetMessages.EntityEvent.kill(1, 1, OWN_ID, 0, PackedInt32Array()), 0), KillFeed.ROLE_NONE,
			"without an own id there is no role")


func test_npc_kills_only_show_for_bosses() -> void:
	BossInfo.resolver = func(npc_def_id: int) -> Dictionary:
		return {"is_boss": npc_def_id == 1, "name": "x"} if npc_def_id > 0 else {}
	var client: FakeClient = _make_client()
	var feed: KillFeed = _make_feed(client)
	client.get_directory().remember(31, "Capitán del Vado", 0, NetProtocol.EntityKind.NPC, 1)
	client.get_directory().remember(32, "Hueco", 0, NetProtocol.EntityKind.NPC, 3)
	assert_eq(feed.show_kill(NetMessages.EntityEvent.kill(32, 500, 11, 0, PackedInt32Array())), "",
			"a Hollow one does not show")
	assert_eq(feed.show_kill(NetMessages.EntityEvent.kill(31, 510, 11, 0, PackedInt32Array([OWN_ID]))),
			"Ana derrotó a Capitán del Vado (+1)", "but the boss does")
	assert_eq(feed.get_entry_count(), 1)


func test_lines_fade_expire_and_the_oldest_leave_when_there_are_too_many() -> void:
	var client: FakeClient = _make_client()
	var feed: KillFeed = _make_feed(client)
	for i: int in KillFeed.MAX_ENTRIES + 2:
		feed.show_kill(NetMessages.EntityEvent.kill(12, 500 + i, 11, 0, PackedInt32Array()))
	assert_eq(feed.get_entry_count(), KillFeed.MAX_ENTRIES, "at most %d lines" % KillFeed.MAX_ENTRIES)
	assert_near(feed.get_seconds_left(0), KillFeed.LIFETIME_SECONDS, 1e-6)
	feed.advance(KillFeed.LIFETIME_SECONDS - KillFeed.FADE_SECONDS * 0.5)
	assert_eq(feed.get_entry_count(), KillFeed.MAX_ENTRIES, "in the final fade they are still visible")
	feed.advance(KillFeed.FADE_SECONDS)
	assert_eq(feed.get_entry_count(), 0, "and then they go away")
	feed.show_kill(NetMessages.EntityEvent.kill(12, 600, 11, 0, PackedInt32Array()))
	feed.clear()
	assert_eq(feed.get_entry_count(), 0)


func test_the_feed_follows_the_clients_combat_events() -> void:
	var client: FakeClient = _make_client()
	var feed: KillFeed = _make_feed(client)
	client.combat_event.emit(NetMessages.EntityEvent.kill(12, 500, 11, 0, PackedInt32Array()), false)
	client.combat_event.emit(NetMessages.EntityEvent.hit(12, 501, 11, 10, 0, 0, 1), false)
	client.combat_event.emit(NetMessages.EntityEvent.kill(OWN_ID, 502, 12, 0, PackedInt32Array()), true)
	assert_eq(feed.get_texts(), PackedStringArray(["Ana derrotó a Bruno", "Bruno derrotó a Yo"]),
			"the zone's KILLs and the own ones, and nothing else")
	feed.bind(null)
	assert_eq(feed.get_entry_count(), 2, "without a client what was there stays")
	client.combat_event.emit(NetMessages.EntityEvent.kill(12, 503, 11, 0, PackedInt32Array()), false)
	assert_eq(feed.get_entry_count(), 2, "and it no longer listens")


# --- Mounting in the HUD ----------------------------------------------------------------------

func test_the_hud_mounts_the_scoreboard_on_top_and_the_feed_in_the_war_interface() -> void:
	var client: FakeClient = _make_client()
	var character: PlayerCharacter = _track((load(CHARACTER_SCENE_PATH) as PackedScene).instantiate()) as PlayerCharacter
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	rig.set_scripted_look(false)
	_track(rig)
	var hud: HUD = (load(HUD_SCENE_PATH) as PackedScene).instantiate() as HUD
	_track(hud)
	hud.bind(character, rig)
	hud.bind_net(client, _root)
	var panel: ScoreboardPanel = hud.get_scoreboard()
	if not assert_not_null(panel, "the networked HUD has a scoreboard"):
		return
	assert_eq(panel.get_index(), hud.get_child_count() - 1, "the last child, above everything")
	assert_true(panel.get_index() > hud.get_world_map().get_index())
	assert_not_null(hud.get_war_hud().get_kill_feed(), "and the kill feed, in the war interface")
	_publish(client, _rows())
	panel.open()
	assert_eq(panel.get_row_count(), 5, "linked to the client's scoreboard")
	var sandbox: HUD = (load(HUD_SCENE_PATH) as PackedScene).instantiate() as HUD
	_track(sandbox)
	assert_null(sandbox.get_scoreboard(), "the sandbox has no scoreboard")
