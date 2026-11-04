extends TestCase
## Tests for [RealmSelect] (docs/red.md, 1.2 and 17.5; TEC-45), with the scene instantiated without a screen:
## [br]- The buttons of the realms the zone does not admit come out disabled.
## [br]- "Entrar" (Enter) is only enabled with a valid realm, name and address, and emits [signal
## RealmSelect.realm_chosen] with the values.
## [br]- An invalid name (with the reason in Spanish from [NameRules]) or an invalid address blocks
## it.
## [br]- [OnlineMain] shows it if the realm is missing, enters with what was chosen and returns to it, with the notice,
## after a rejection or a disconnection.

const SCENE_PATH: String = "res://scenes/ui/realm_select.tscn"
const ONLINE_MAIN_SCENE: String = "res://scenes/client/online_main.tscn"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
const WAIT_FRAMES: int = 900

var _screen: RealmSelect
var _chosen: Array[Dictionary] = []
var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _port: int = 0
var _online: OnlineMain
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_interactive: bool = false
var _saved_max_fps: int = 0


func before_each() -> void:
	_saved_config = OnlineMain.config
	_saved_hook = OnlineMain.quit_hook
	_saved_interactive = OnlineMain.force_interactive
	_saved_max_fps = Engine.max_fps
	_root = Node.new()
	_root.name = "RealmSelectTest"
	tree.root.add_child(_root)
	_chosen.clear()


func after_each() -> void:
	if is_instance_valid(_online):
		_online.get_parent().remove_child(_online)
		_online.free()
	_online = null
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	_screen = null
	OnlineMain.config = _saved_config
	OnlineMain.quit_hook = _saved_hook
	OnlineMain.force_interactive = _saved_interactive
	Engine.max_fps = _saved_max_fps
	await wait_process_frames(2)


# --- Helpers ----------------------------------------------------------------------------------

func _make_screen(allowed: PackedInt32Array, default_name: String = "Ana",
		address: String = "127.0.0.1") -> RealmSelect:
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	_screen = packed.instantiate() as RealmSelect
	_root.add_child(_screen)
	_screen.setup(address, default_name, allowed)
	_screen.realm_chosen.connect(func(realm: int, chosen_address: String, display_name: String) -> void:
		_chosen.append({"realm": realm, "address": chosen_address, "name": display_name}))
	return _screen


## Types [param text] into the field as the player would (emitting the text-changed signal).
func _type(edit: LineEdit, text: String) -> void:
	edit.text = text
	edit.text_changed.emit(text)


## Presses the realm's button as the player would.
func _click_realm(realm: int) -> void:
	var button: Button = _screen.get_realm_button(realm)
	button.button_pressed = true
	button.pressed.emit()


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


# --- The scene --------------------------------------------------------------------------------

func test_the_scene_has_three_realm_buttons_and_the_form_in_spanish() -> void:
	_make_screen(PackedInt32Array())
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	assert_not_null(packed, "the scene exists")
	assert_eq(_screen.get_realm_button(VARDHEIM).text, "Vardheim")
	assert_eq(_screen.get_realm_button(SOLMARCH).text, "Solmarch")
	assert_eq(_screen.get_realm_button(ASKARRA).text, "Askarra")
	assert_null(_screen.get_realm_button(NetProtocol.Realm.NONE), "\"ninguno\" (none) is not a button")
	assert_eq(_screen.get_enter_button().text, "Entrar")
	assert_eq(_screen.get_address_edit().text, "127.0.0.1", "with the address it was given")
	assert_eq(_screen.get_name_edit().text, "Ana", "and the name")
	assert_true(_screen.get_address_edit().editable)
	assert_eq(_screen.get_selected_realm(), NetProtocol.Realm.NONE, "no realm chosen")
	assert_true(_screen.get_enter_button().disabled, "one cannot enter without choosing a realm")
	assert_eq(_screen.get_hint_text(), RealmSelect.TEXT_PICK_REALM)
	assert_eq(_screen.get_name_reason_text(), "", "the name is valid")


func test_realms_the_zone_does_not_admit_are_disabled() -> void:
	# Vado Gris is the border between Vardheim and Solmarch: Askarra does not get in.
	_make_screen(NetZones.allowed_realms("vado_gris"))
	assert_false(_screen.get_realm_button(VARDHEIM).disabled)
	assert_false(_screen.get_realm_button(SOLMARCH).disabled)
	assert_true(_screen.get_realm_button(ASKARRA).disabled, "Askarra, disabled")
	assert_false(_screen.is_realm_allowed(ASKARRA))
	_screen.select_realm(ASKARRA)
	assert_eq(_screen.get_selected_realm(), NetProtocol.Realm.NONE, "and it cannot be chosen")
	assert_false(_screen.get_realm_button(ASKARRA).button_pressed)

	# A zone that admits all of them, or with no registered restriction (empty list).
	_make_screen(NetZones.allowed_realms("test_world"))
	for realm: int in RealmSelect.REALMS:
		assert_false(_screen.get_realm_button(realm).disabled, "test_world admits realm %d" % realm)
	_make_screen(NetZones.allowed_realms("zona_sin_restriccion"))
	for realm: int in RealmSelect.REALMS:
		assert_false(_screen.get_realm_button(realm).disabled)


func test_setup_again_drops_a_realm_that_is_no_longer_allowed() -> void:
	_make_screen(PackedInt32Array())
	_click_realm(ASKARRA)
	assert_eq(_screen.get_selected_realm(), ASKARRA)
	_screen.setup("127.0.0.1", "Ana", PackedInt32Array([VARDHEIM, SOLMARCH]))
	assert_eq(_screen.get_selected_realm(), NetProtocol.Realm.NONE, "the choice is undone")
	assert_false(_screen.get_realm_button(ASKARRA).button_pressed)
	assert_true(_screen.get_enter_button().disabled)


# --- Choosing and entering --------------------------------------------------------------------

func test_choosing_a_realm_and_pressing_enter_emits_realm_chosen_with_the_values() -> void:
	_make_screen(NetZones.allowed_realms("vado_gris"), "Bruno", "play.eldmark.test:24700")
	_click_realm(SOLMARCH)
	assert_eq(_screen.get_selected_realm(), SOLMARCH)
	assert_true(_screen.get_realm_button(SOLMARCH).button_pressed)
	assert_false(_screen.get_realm_button(VARDHEIM).button_pressed, "only one at a time")
	assert_false(_screen.get_enter_button().disabled, "with a valid realm, name and address")
	assert_eq(_screen.get_hint_text(), "")

	_screen.get_enter_button().pressed.emit()
	assert_eq(_chosen.size(), 1, "emits realm_chosen once")
	assert_eq(_chosen[0], {"realm": SOLMARCH, "address": "play.eldmark.test:24700", "name": "Bruno"})

	# Changing realm before entering: the last one wins. The name is delivered without surplus spaces.
	_click_realm(VARDHEIM)
	_type(_screen.get_name_edit(), "  Álvaro ")
	assert_eq(_screen.get_name_reason_text(), "", "the spaces at the ends do not count")
	_screen.get_enter_button().pressed.emit()
	assert_eq(_chosen[1], {"realm": VARDHEIM, "address": "play.eldmark.test:24700", "name": "Álvaro"})


func test_enter_key_in_the_name_field_enters_only_when_everything_is_valid() -> void:
	_make_screen(PackedInt32Array())
	_screen.get_name_edit().text_submitted.emit("Ana")
	assert_true(_chosen.is_empty(), "with no realm chosen it does not enter")
	_click_realm(ASKARRA)
	_screen.get_name_edit().text_submitted.emit("Ana")
	assert_eq(_chosen.size(), 1)
	assert_eq(_chosen[0]["realm"], ASKARRA)


# --- Invalid name -----------------------------------------------------------------------------

func test_an_invalid_name_blocks_enter_and_shows_the_reason_in_spanish() -> void:
	_make_screen(PackedInt32Array())
	_click_realm(VARDHEIM)
	assert_false(_screen.get_enter_button().disabled)
	var cases: Array[Array] = [
		["ab", NameRules.Reason.TOO_SHORT],
		["Ana Perez", NameRules.Reason.HAS_SPACE],
		["Ana3", NameRules.Reason.HAS_DIGIT],
		["Ana_", NameRules.Reason.INVALID_CHARACTER],
		["ana", NameRules.Reason.NOT_CAPITALIZED],
		["Vardheim", NameRules.Reason.RESERVED],
		["Abcdefghijklmnopq", NameRules.Reason.TOO_LONG],
		["", NameRules.Reason.TOO_SHORT],
	]
	for entry: Array in cases:
		var text: String = entry[0]
		_type(_screen.get_name_edit(), text)
		assert_eq(_screen.get_name_reason_text(), NameRules.reason_text(entry[1]),
				"reason for \"%s\"" % text)
		assert_true(_screen.get_enter_button().disabled, "\"%s\" blocks Entrar (Enter)" % text)
		# Even if the press is forced (a signal emitted by hand), nothing goes out.
		_screen.get_enter_button().pressed.emit()
		_screen.get_name_edit().text_submitted.emit(text)
	assert_true(_chosen.is_empty(), "none of the above is sent")
	_type(_screen.get_name_edit(), "Ana")
	assert_eq(_screen.get_name_reason_text(), "", "with a valid name the reason disappears")
	assert_false(_screen.get_enter_button().disabled)
	_screen.get_enter_button().pressed.emit()
	assert_eq(_chosen.size(), 1)


func test_an_invalid_default_name_is_flagged_from_the_start() -> void:
	_make_screen(PackedInt32Array(), "Jugador-1234")
	_click_realm(VARDHEIM)
	assert_true(_screen.get_enter_button().disabled)
	assert_eq(_screen.get_name_reason_text(), NameRules.reason_text(NameRules.Reason.INVALID_CHARACTER))


# --- Address ----------------------------------------------------------------------------------

func test_an_invalid_address_blocks_enter() -> void:
	_make_screen(PackedInt32Array())
	_click_realm(SOLMARCH)
	for text: String in ["", "host:99999", "host:abc", "[::1", ":24600"]:
		_type(_screen.get_address_edit(), text)
		assert_true(_screen.get_enter_button().disabled, "\"%s\" is not an address" % text)
		assert_false(_screen.get_hint_text().is_empty(), "and it says why: \"%s\"" % text)
	for text: String in ["localhost", "10.0.0.5:24700", "[::1]:24800", "example.org"]:
		_type(_screen.get_address_edit(), text)
		assert_false(_screen.get_enter_button().disabled, "\"%s\" is" % text)
		assert_eq(_screen.get_hint_text(), "")


func test_the_address_is_ignored_when_it_cannot_be_edited() -> void:
	_make_screen(PackedInt32Array(), "Ana", "")
	_screen.set_address_editable(false)
	assert_false(_screen.get_address_edit().editable, "in local mode it is not touched")
	_click_realm(VARDHEIM)
	assert_false(_screen.get_enter_button().disabled, "and an empty address does not block")
	_screen.set_address_editable(true)
	assert_true(_screen.get_enter_button().disabled, "when edited, it counts again")


func test_notice_is_shown_and_cleared() -> void:
	_make_screen(PackedInt32Array())
	_screen.set_notice("Conexión rechazada: Ese nombre está reservado")
	assert_eq(_screen.get_notice_text(), "Conexión rechazada: Ese nombre está reservado")
	_screen.set_notice("")
	assert_eq(_screen.get_notice_text(), "")


func test_quit_button_emits_quit_requested() -> void:
	_make_screen(PackedInt32Array())
	var quits: Array[bool] = []
	_screen.quit_requested.connect(func() -> void: quits.append(true))
	_screen.get_quit_button().pressed.emit()
	assert_eq(quits.size(), 1)


# --- Count per realm (GUE-42) -----------------------------------------------------------------

func test_the_counts_show_under_each_realm_and_the_shortest_is_recommended() -> void:
	_make_screen(PackedInt32Array())
	assert_false(_screen.has_realm_counts(), "without a WELCOME there is no count")
	assert_eq(_screen.get_count_text(VARDHEIM), "", "and nothing is shown")
	assert_eq(_screen.get_recommended_realm(), NetProtocol.Realm.NONE)
	_screen.set_realm_counts(PackedInt32Array([12, 3, 7]))
	assert_true(_screen.has_realm_counts())
	assert_eq(_screen.get_realm_count(SOLMARCH), 3)
	assert_eq(_screen.get_count_text(VARDHEIM), "12 jugadores")
	assert_eq(_screen.get_count_text(SOLMARCH), "3 jugadores · recomendado", "the one with the fewest, recommended")
	assert_eq(_screen.get_count_text(ASKARRA), "7 jugadores")
	assert_eq(_screen.get_recommended_realm(), SOLMARCH)
	_screen.set_realm_counts(PackedInt32Array([1, 0, 0]))
	assert_eq(_screen.get_count_text(VARDHEIM), "1 jugador", "in the singular")
	assert_eq(_screen.get_count_text(SOLMARCH), "Sin jugadores · recomendado", "and with nobody")
	assert_eq(_screen.get_recommended_realm(), SOLMARCH, "with a tie at the minimum, the first of the buttons")
	_screen.set_realm_counts(PackedInt32Array([5, 5, 5]))
	assert_eq(_screen.get_recommended_realm(), NetProtocol.Realm.NONE, "evened out, none stands out")
	assert_eq(_screen.get_count_text(SOLMARCH), "5 jugadores")
	_screen.set_realm_counts(PackedInt32Array([1, 2]))
	assert_false(_screen.has_realm_counts(), "a count of a different size is discarded")
	assert_eq(_screen.get_count_text(VARDHEIM), "")


func test_the_recommendation_only_counts_the_realms_the_zone_admits() -> void:
	_make_screen(PackedInt32Array([VARDHEIM, SOLMARCH]))
	_screen.set_realm_counts(PackedInt32Array([12, 9, 0]))
	assert_eq(_screen.get_recommended_realm(), SOLMARCH, "Askarra, empty, does not count: the zone does not admit it")
	assert_eq(_screen.get_count_text(ASKARRA), "Sin jugadores", "even if its count is shown")
	_make_screen(PackedInt32Array([SOLMARCH]))
	_screen.set_realm_counts(PackedInt32Array([12, 9, 0]))
	assert_eq(_screen.get_recommended_realm(), NetProtocol.Realm.NONE, "with a single admitted realm there is nothing to recommend")


func test_a_realm_rejected_for_imbalance_is_dropped_and_marked() -> void:
	_make_screen(PackedInt32Array())
	_type_name(_screen, "Ana")
	_screen.select_realm(VARDHEIM)
	assert_false(_screen.get_enter_button().disabled)
	_screen.set_rejected_realm(VARDHEIM)
	assert_eq(_screen.get_rejected_realm(), VARDHEIM)
	assert_eq(_screen.get_selected_realm(), NetProtocol.Realm.NONE, "the rejected realm is no longer chosen")
	assert_true(_screen.get_enter_button().disabled, "and another has to be chosen to enter")
	assert_eq(_screen.get_count_text(VARDHEIM), "Completo", "without a count, it is only marked")
	assert_eq(_screen.get_count_text(SOLMARCH), "")
	assert_true(_screen.get_realm_button(VARDHEIM).tooltip_text.contains("demasiados jugadores"))
	_screen.set_realm_counts(PackedInt32Array([30, 4, 6]))
	assert_eq(_screen.get_count_text(VARDHEIM), "30 jugadores · completo", "with a count, it says so next to the figure")
	assert_eq(_screen.get_count_text(SOLMARCH), "4 jugadores · recomendado")
	_screen.select_realm(SOLMARCH)
	assert_false(_screen.get_enter_button().disabled, "with another realm one can enter")
	_screen.set_rejected_realm(NetProtocol.Realm.NONE)
	assert_eq(_screen.get_count_text(VARDHEIM), "30 jugadores", "with the mark removed, it goes back to normal")


# --- In OnlineMain ----------------------------------------------------------------------------

func _start_server() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, NetZones.scene_path("test_world"))
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = "test_world"
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)


## OnlineMain as a client with a window (even though the tests are headless) and with no realm.
func _start_online_without_realm() -> void:
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.ONLINE
	config.address = "127.0.0.1"
	config.port = _port
	config.display_name = "Ana"
	OnlineMain.config = config
	OnlineMain.force_interactive = true
	OnlineMain.quit_hook = func(_code: int) -> void: pass
	var packed: PackedScene = load(ONLINE_MAIN_SCENE) as PackedScene
	_online = packed.instantiate() as OnlineMain
	tree.root.add_child(_online)


func _in_world() -> bool:
	return _online.get_client() != null \
			and _online.get_client().get_state() == NetClient.State.IN_WORLD


func test_online_main_shows_realm_select_when_the_realm_is_missing() -> void:
	await _start_server()
	_start_online_without_realm()
	var screen: RealmSelect = _online.get_realm_select()
	if not assert_not_null(screen, "the realm choice is shown"):
		return
	assert_null(_online.get_client(), "and there is no network session yet")
	assert_eq(_server.get_player_count(), 0)
	assert_true(screen.is_visible_in_tree())
	assert_eq(screen.get_address_edit().text, "127.0.0.1:%d" % _port,
			"with the address and port from the configuration")
	assert_eq(screen.get_name_edit().text, "Ana")
	assert_true(screen.get_enter_button().disabled)
	assert_true(screen.get_realm_button(ASKARRA).disabled, "the default zone (Vado Gris) does not admit Askarra")

	# Chooses Solmarch with another address port and enters.
	screen.get_address_edit().text = "127.0.0.1:%d" % _port
	screen.select_realm(SOLMARCH)
	assert_true(screen.try_enter())
	assert_eq(OnlineMain.config.realm, SOLMARCH, "the configuration picks up the realm")
	assert_eq(OnlineMain.config.address, "127.0.0.1")
	assert_eq(OnlineMain.config.port, _port)
	assert_false(screen.is_visible_in_tree(), "the screen is removed")
	assert_true(await _wait_until(_in_world), "and enters the world")
	assert_eq(_server.get_player_count(), 1)
	assert_eq(_online.get_client().get_welcome().realm, SOLMARCH)


func test_online_main_returns_to_realm_select_after_a_rejection_and_can_retry() -> void:
	await _start_server()
	# Another player already uses the name: the server rejects it.
	var holder: SubViewport = NetHarness.make_world_viewport(_root, "")
	var bot: NetClient = NetHarness.start_bot(holder, _port, VARDHEIM, 1)
	assert_true(await _wait_until(func() -> bool:
		return bot.get_state() == NetClient.State.IN_WORLD), "the other player enters")
	var taken_name: String = bot.get_config().display_name

	_start_online_without_realm()
	var screen: RealmSelect = _online.get_realm_select()
	screen.select_realm(VARDHEIM)
	_type_name(screen, taken_name)
	assert_true(screen.try_enter())
	var first_client: NetClient = _online.get_client()
	assert_not_null(first_client, "a session starts")
	assert_true(await _wait_until(func() -> bool:
		return _online.get_client() == null and screen.is_visible_in_tree()),
			"the rejection returns to the realm choice")
	assert_true(screen.get_notice_text().begins_with("Conexión rechazada: "),
			"with the reason (%s)" % screen.get_notice_text())
	assert_true(screen.get_notice_text().contains(NetProtocol.result_text(NetProtocol.Result.NAME)))
	assert_eq(screen.get_selected_realm(), VARDHEIM, "remembers the chosen realm")
	assert_eq(screen.get_name_edit().text, taken_name, "and the name, to correct it")
	assert_null(_online.get_world(), "no zone")
	assert_eq(_server.get_player_count(), 1, "the server only has the other player")

	# With another name, it enters.
	_type_name(screen, "Ana")
	assert_true(screen.try_enter())
	assert_true(await _wait_until(_in_world), "enters with the new name")
	assert_true(_online.get_client() != first_client, "in a new session")
	assert_eq(_server.get_player_count(), 2)
	assert_false(screen.is_visible_in_tree())


func test_a_rejection_for_imbalance_returns_with_the_text_the_counts_and_the_short_realm_chosen() -> void:
	await _start_server()
	_start_online_without_realm()
	var screen: RealmSelect = _online.get_realm_select()
	assert_false(screen.has_realm_counts(), "before the first connection there is no count")
	screen.select_realm(VARDHEIM)
	assert_true(screen.try_enter())
	var client: NetClient = _online.get_client()
	assert_not_null(client)
	# What was already known from a previous WELCOME and the REJECT 9 of this attempt (without server text).
	_online._last_realm_counts = PackedInt32Array([30, 4, 6])
	client.rejected.emit(NetProtocol.Result.IMBALANCE, "")
	assert_true(await _wait_until(func() -> bool:
		return _online.get_client() == null and screen.is_visible_in_tree()), "returns to the realm choice")
	assert_eq(screen.get_notice_text(), "Conexión rechazada: " + NetProtocol.result_text(NetProtocol.Result.IMBALANCE),
			"with the text of REJECT 9 (the client's if the server does not send it)")
	assert_eq(screen.get_rejected_realm(), VARDHEIM, "the rejected realm stays marked")
	assert_eq(screen.get_count_text(VARDHEIM), "30 jugadores · completo")
	assert_eq(screen.get_selected_realm(), SOLMARCH, "and the realm with the fewest players is offered")
	assert_eq(screen.get_count_text(SOLMARCH), "4 jugadores · recomendado")


func test_a_rejection_for_another_reason_keeps_the_realm_and_shows_no_mark() -> void:
	await _start_server()
	_start_online_without_realm()
	var screen: RealmSelect = _online.get_realm_select()
	screen.select_realm(SOLMARCH)
	assert_true(screen.try_enter())
	_online.get_client().rejected.emit(NetProtocol.Result.FULL, "Servidor lleno")
	assert_true(await _wait_until(func() -> bool:
		return _online.get_client() == null and screen.is_visible_in_tree()))
	assert_eq(screen.get_notice_text(), "Conexión rechazada: Servidor lleno")
	assert_eq(screen.get_rejected_realm(), NetProtocol.Realm.NONE)
	assert_eq(screen.get_selected_realm(), SOLMARCH, "the chosen realm is remembered")


func test_online_main_returns_to_realm_select_after_a_disconnection() -> void:
	await _start_server()
	_start_online_without_realm()
	var screen: RealmSelect = _online.get_realm_select()
	screen.select_realm(VARDHEIM)
	assert_true(screen.try_enter())
	assert_true(await _wait_until(_in_world), "enters")
	assert_not_null(_online.get_camera_rig(), "with camera")
	assert_not_null(_online.get_hud(), "and HUD")
	_server.stop("Mantenimiento")
	assert_true(await _wait_until(func() -> bool:
		return _online.get_client() == null and screen.is_visible_in_tree()),
			"the server shutdown returns to the realm choice")
	assert_eq(screen.get_notice_text(), "Mantenimiento", "with the server's notice")
	assert_null(_online.get_world(), "the zone is removed")
	assert_null(_online.get_camera_rig(), "the camera")
	assert_null(_online.get_hud(), "and the HUD")
	assert_eq(Input.mouse_mode, Input.MOUSE_MODE_VISIBLE, "and the cursor comes back")
	assert_false(screen.get_enter_button().disabled, "it can be tried again")


func test_online_main_without_a_window_keeps_entering_as_vardheim() -> void:
	await _start_server()
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.ONLINE
	config.port = _port
	config.display_name = "Ana"
	OnlineMain.config = config
	OnlineMain.force_interactive = false
	OnlineMain.quit_hook = func(_code: int) -> void: pass
	var packed: PackedScene = load(ONLINE_MAIN_SCENE) as PackedScene
	_online = packed.instantiate() as OnlineMain
	tree.root.add_child(_online)
	assert_null(_online.get_realm_select(), "without a screen there is no one to ask")
	assert_eq(config.realm, NetProtocol.Realm.VARDHEIM, "enters as Vardheim, with a notice")
	assert_true(await _wait_until(_in_world))


func _type_name(screen: RealmSelect, text: String) -> void:
	_type(screen.get_name_edit(), text)


func test_the_template_selector_is_in_the_form_and_remembers_the_choice() -> void:
	_make_screen(PackedInt32Array())
	var selector: TemplateSelector = _screen.get_template_selector()
	if not assert_not_null(selector, "the realm choice has the template selector"):
		return
	assert_eq(_screen.get_selected_template(), CombatCatalog.default_template_id(), "by default, the squire")
	var marksman: int = CombatCatalog.template_id(&"marksman")
	_screen.set_selected_template(marksman)
	assert_eq(_screen.get_selected_template(), marksman)
	assert_true(selector.get_button(marksman).button_pressed, "its button is marked")
	selector.get_button(CombatCatalog.template_id(&"squire")).pressed.emit()
	assert_eq(_screen.get_selected_template(), CombatCatalog.template_id(&"squire"), "pressing another one changes it")
