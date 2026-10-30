extends TestCase
## Pruebas de [RealmSelect] (docs/red.md, 1.2 y 17.5; TEC-45), con la escena instanciada sin pantalla:
## [br]- Los botones de los reinos que la zona no admite salen desactivados.
## [br]- «Entrar» solo se activa con reino, nombre y dirección válidos y emite [signal
## RealmSelect.realm_chosen] con los valores.
## [br]- Un nombre inválido (con el motivo en español de [NameRules]) o una dirección inválida lo
## bloquean.
## [br]- [OnlineMain] la muestra si falta el reino, entra con lo elegido y vuelve a ella, con el aviso,
## tras un rechazo o una desconexión.

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


# --- Ayudantes --------------------------------------------------------------------------------

func _make_screen(allowed: PackedInt32Array, default_name: String = "Ana",
		address: String = "127.0.0.1") -> RealmSelect:
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	_screen = packed.instantiate() as RealmSelect
	_root.add_child(_screen)
	_screen.setup(address, default_name, allowed)
	_screen.realm_chosen.connect(func(realm: int, chosen_address: String, display_name: String) -> void:
		_chosen.append({"realm": realm, "address": chosen_address, "name": display_name}))
	return _screen


## Escribe [param text] en el campo como lo haría el jugador (con la señal de texto cambiado).
func _type(edit: LineEdit, text: String) -> void:
	edit.text = text
	edit.text_changed.emit(text)


## Pulsa el botón del reino como lo haría el jugador.
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


# --- La escena --------------------------------------------------------------------------------

func test_the_scene_has_three_realm_buttons_and_the_form_in_spanish() -> void:
	_make_screen(PackedInt32Array())
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	assert_not_null(packed, "la escena existe")
	assert_eq(_screen.get_realm_button(VARDHEIM).text, "Vardheim")
	assert_eq(_screen.get_realm_button(SOLMARCH).text, "Solmarch")
	assert_eq(_screen.get_realm_button(ASKARRA).text, "Askarra")
	assert_null(_screen.get_realm_button(NetProtocol.Realm.NONE), "«ninguno» no es un botón")
	assert_eq(_screen.get_enter_button().text, "Entrar")
	assert_eq(_screen.get_address_edit().text, "127.0.0.1", "con la dirección que se le dio")
	assert_eq(_screen.get_name_edit().text, "Ana", "y el nombre")
	assert_true(_screen.get_address_edit().editable)
	assert_eq(_screen.get_selected_realm(), NetProtocol.Realm.NONE, "sin reino elegido")
	assert_true(_screen.get_enter_button().disabled, "no se puede entrar sin elegir reino")
	assert_eq(_screen.get_hint_text(), RealmSelect.TEXT_PICK_REALM)
	assert_eq(_screen.get_name_reason_text(), "", "el nombre es válido")


func test_realms_the_zone_does_not_admit_are_disabled() -> void:
	# El Vado Gris es la frontera entre Vardheim y Solmarch: Askarra no entra.
	_make_screen(NetZones.allowed_realms("vado_gris"))
	assert_false(_screen.get_realm_button(VARDHEIM).disabled)
	assert_false(_screen.get_realm_button(SOLMARCH).disabled)
	assert_true(_screen.get_realm_button(ASKARRA).disabled, "Askarra, desactivado")
	assert_false(_screen.is_realm_allowed(ASKARRA))
	_screen.select_realm(ASKARRA)
	assert_eq(_screen.get_selected_realm(), NetProtocol.Realm.NONE, "y no se puede elegir")
	assert_false(_screen.get_realm_button(ASKARRA).button_pressed)

	# Una zona que los admite a todos, o sin restricción registrada (lista vacía).
	_make_screen(NetZones.allowed_realms("test_world"))
	for realm: int in RealmSelect.REALMS:
		assert_false(_screen.get_realm_button(realm).disabled, "test_world admite el reino %d" % realm)
	_make_screen(NetZones.allowed_realms("zona_sin_restriccion"))
	for realm: int in RealmSelect.REALMS:
		assert_false(_screen.get_realm_button(realm).disabled)


func test_setup_again_drops_a_realm_that_is_no_longer_allowed() -> void:
	_make_screen(PackedInt32Array())
	_click_realm(ASKARRA)
	assert_eq(_screen.get_selected_realm(), ASKARRA)
	_screen.setup("127.0.0.1", "Ana", PackedInt32Array([VARDHEIM, SOLMARCH]))
	assert_eq(_screen.get_selected_realm(), NetProtocol.Realm.NONE, "se deshace la elección")
	assert_false(_screen.get_realm_button(ASKARRA).button_pressed)
	assert_true(_screen.get_enter_button().disabled)


# --- Elegir y entrar --------------------------------------------------------------------------

func test_choosing_a_realm_and_pressing_enter_emits_realm_chosen_with_the_values() -> void:
	_make_screen(NetZones.allowed_realms("vado_gris"), "Bruno", "play.eldmark.test:24700")
	_click_realm(SOLMARCH)
	assert_eq(_screen.get_selected_realm(), SOLMARCH)
	assert_true(_screen.get_realm_button(SOLMARCH).button_pressed)
	assert_false(_screen.get_realm_button(VARDHEIM).button_pressed, "solo uno a la vez")
	assert_false(_screen.get_enter_button().disabled, "con reino, nombre y dirección válidos")
	assert_eq(_screen.get_hint_text(), "")

	_screen.get_enter_button().pressed.emit()
	assert_eq(_chosen.size(), 1, "emite realm_chosen una vez")
	assert_eq(_chosen[0], {"realm": SOLMARCH, "address": "play.eldmark.test:24700", "name": "Bruno"})

	# Cambiar de reino antes de entrar: el último manda. El nombre se entrega sin espacios sobrantes.
	_click_realm(VARDHEIM)
	_type(_screen.get_name_edit(), "  Álvaro ")
	assert_eq(_screen.get_name_reason_text(), "", "los espacios de los extremos no cuentan")
	_screen.get_enter_button().pressed.emit()
	assert_eq(_chosen[1], {"realm": VARDHEIM, "address": "play.eldmark.test:24700", "name": "Álvaro"})


func test_enter_key_in_the_name_field_enters_only_when_everything_is_valid() -> void:
	_make_screen(PackedInt32Array())
	_screen.get_name_edit().text_submitted.emit("Ana")
	assert_true(_chosen.is_empty(), "sin reino elegido no entra")
	_click_realm(ASKARRA)
	_screen.get_name_edit().text_submitted.emit("Ana")
	assert_eq(_chosen.size(), 1)
	assert_eq(_chosen[0]["realm"], ASKARRA)


# --- Nombre inválido --------------------------------------------------------------------------

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
				"motivo de «%s»" % text)
		assert_true(_screen.get_enter_button().disabled, "«%s» bloquea Entrar" % text)
		# Aunque se fuerce la pulsación (una señal emitida a mano), no sale nada.
		_screen.get_enter_button().pressed.emit()
		_screen.get_name_edit().text_submitted.emit(text)
	assert_true(_chosen.is_empty(), "nada de lo anterior se envía")
	_type(_screen.get_name_edit(), "Ana")
	assert_eq(_screen.get_name_reason_text(), "", "con un nombre válido el motivo desaparece")
	assert_false(_screen.get_enter_button().disabled)
	_screen.get_enter_button().pressed.emit()
	assert_eq(_chosen.size(), 1)


func test_an_invalid_default_name_is_flagged_from_the_start() -> void:
	_make_screen(PackedInt32Array(), "Jugador-1234")
	_click_realm(VARDHEIM)
	assert_true(_screen.get_enter_button().disabled)
	assert_eq(_screen.get_name_reason_text(), NameRules.reason_text(NameRules.Reason.INVALID_CHARACTER))


# --- Dirección --------------------------------------------------------------------------------

func test_an_invalid_address_blocks_enter() -> void:
	_make_screen(PackedInt32Array())
	_click_realm(SOLMARCH)
	for text: String in ["", "host:99999", "host:abc", "[::1", ":24600"]:
		_type(_screen.get_address_edit(), text)
		assert_true(_screen.get_enter_button().disabled, "«%s» no es una dirección" % text)
		assert_false(_screen.get_hint_text().is_empty(), "y se dice por qué: «%s»" % text)
	for text: String in ["localhost", "10.0.0.5:24700", "[::1]:24800", "example.org"]:
		_type(_screen.get_address_edit(), text)
		assert_false(_screen.get_enter_button().disabled, "«%s» sí" % text)
		assert_eq(_screen.get_hint_text(), "")


func test_the_address_is_ignored_when_it_cannot_be_edited() -> void:
	_make_screen(PackedInt32Array(), "Ana", "")
	_screen.set_address_editable(false)
	assert_false(_screen.get_address_edit().editable, "en modo local no se toca")
	_click_realm(VARDHEIM)
	assert_false(_screen.get_enter_button().disabled, "y una dirección vacía no bloquea")
	_screen.set_address_editable(true)
	assert_true(_screen.get_enter_button().disabled, "al editarse, vuelve a contar")


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


# --- Recuento por reino (GUE-42) --------------------------------------------------------------

func test_the_counts_show_under_each_realm_and_the_shortest_is_recommended() -> void:
	_make_screen(PackedInt32Array())
	assert_false(_screen.has_realm_counts(), "sin WELCOME no hay recuento")
	assert_eq(_screen.get_count_text(VARDHEIM), "", "y no se enseña nada")
	assert_eq(_screen.get_recommended_realm(), NetProtocol.Realm.NONE)
	_screen.set_realm_counts(PackedInt32Array([12, 3, 7]))
	assert_true(_screen.has_realm_counts())
	assert_eq(_screen.get_realm_count(SOLMARCH), 3)
	assert_eq(_screen.get_count_text(VARDHEIM), "12 jugadores")
	assert_eq(_screen.get_count_text(SOLMARCH), "3 jugadores · recomendado", "el que tiene menos, recomendado")
	assert_eq(_screen.get_count_text(ASKARRA), "7 jugadores")
	assert_eq(_screen.get_recommended_realm(), SOLMARCH)
	_screen.set_realm_counts(PackedInt32Array([1, 0, 0]))
	assert_eq(_screen.get_count_text(VARDHEIM), "1 jugador", "en singular")
	assert_eq(_screen.get_count_text(SOLMARCH), "Sin jugadores · recomendado", "y sin nadie")
	assert_eq(_screen.get_recommended_realm(), SOLMARCH, "con empate en el mínimo, el primero de los botones")
	_screen.set_realm_counts(PackedInt32Array([5, 5, 5]))
	assert_eq(_screen.get_recommended_realm(), NetProtocol.Realm.NONE, "igualados, ninguno destaca")
	assert_eq(_screen.get_count_text(SOLMARCH), "5 jugadores")
	_screen.set_realm_counts(PackedInt32Array([1, 2]))
	assert_false(_screen.has_realm_counts(), "un recuento de otro tamaño se descarta")
	assert_eq(_screen.get_count_text(VARDHEIM), "")


func test_the_recommendation_only_counts_the_realms_the_zone_admits() -> void:
	_make_screen(PackedInt32Array([VARDHEIM, SOLMARCH]))
	_screen.set_realm_counts(PackedInt32Array([12, 9, 0]))
	assert_eq(_screen.get_recommended_realm(), SOLMARCH, "Askarra, vacío, no cuenta: la zona no lo admite")
	assert_eq(_screen.get_count_text(ASKARRA), "Sin jugadores", "aunque su recuento se enseñe")
	_make_screen(PackedInt32Array([SOLMARCH]))
	_screen.set_realm_counts(PackedInt32Array([12, 9, 0]))
	assert_eq(_screen.get_recommended_realm(), NetProtocol.Realm.NONE, "con un solo reino admitido no hay qué recomendar")


func test_a_realm_rejected_for_imbalance_is_dropped_and_marked() -> void:
	_make_screen(PackedInt32Array())
	_type_name(_screen, "Ana")
	_screen.select_realm(VARDHEIM)
	assert_false(_screen.get_enter_button().disabled)
	_screen.set_rejected_realm(VARDHEIM)
	assert_eq(_screen.get_rejected_realm(), VARDHEIM)
	assert_eq(_screen.get_selected_realm(), NetProtocol.Realm.NONE, "el reino rechazado deja de estar elegido")
	assert_true(_screen.get_enter_button().disabled, "y hay que elegir otro para entrar")
	assert_eq(_screen.get_count_text(VARDHEIM), "Completo", "sin recuento, solo se marca")
	assert_eq(_screen.get_count_text(SOLMARCH), "")
	assert_true(_screen.get_realm_button(VARDHEIM).tooltip_text.contains("demasiados jugadores"))
	_screen.set_realm_counts(PackedInt32Array([30, 4, 6]))
	assert_eq(_screen.get_count_text(VARDHEIM), "30 jugadores · completo", "con recuento, lo dice junto a la cifra")
	assert_eq(_screen.get_count_text(SOLMARCH), "4 jugadores · recomendado")
	_screen.select_realm(SOLMARCH)
	assert_false(_screen.get_enter_button().disabled, "con otro reino se puede entrar")
	_screen.set_rejected_realm(NetProtocol.Realm.NONE)
	assert_eq(_screen.get_count_text(VARDHEIM), "30 jugadores", "quitada la marca, vuelve a lo normal")


# --- En OnlineMain ----------------------------------------------------------------------------

func _start_server() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, NetZones.scene_path("test_world"))
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = "test_world"
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)


## OnlineMain como cliente con ventana (aunque las pruebas sean headless) y sin reino.
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
	if not assert_not_null(screen, "se muestra la elección de reino"):
		return
	assert_null(_online.get_client(), "y todavía no hay sesión de red")
	assert_eq(_server.get_player_count(), 0)
	assert_true(screen.is_visible_in_tree())
	assert_eq(screen.get_address_edit().text, "127.0.0.1:%d" % _port,
			"con la dirección y el puerto de la configuración")
	assert_eq(screen.get_name_edit().text, "Ana")
	assert_true(screen.get_enter_button().disabled)
	assert_true(screen.get_realm_button(ASKARRA).disabled, "la zona por defecto (Vado Gris) no admite Askarra")

	# Elige Solmarch con otro puerto de dirección y entra.
	screen.get_address_edit().text = "127.0.0.1:%d" % _port
	screen.select_realm(SOLMARCH)
	assert_true(screen.try_enter())
	assert_eq(OnlineMain.config.realm, SOLMARCH, "la configuración recoge el reino")
	assert_eq(OnlineMain.config.address, "127.0.0.1")
	assert_eq(OnlineMain.config.port, _port)
	assert_false(screen.is_visible_in_tree(), "la pantalla se quita")
	assert_true(await _wait_until(_in_world), "y entra en el mundo")
	assert_eq(_server.get_player_count(), 1)
	assert_eq(_online.get_client().get_welcome().realm, SOLMARCH)


func test_online_main_returns_to_realm_select_after_a_rejection_and_can_retry() -> void:
	await _start_server()
	# Otro jugador ya usa el nombre: el servidor lo rechaza.
	var holder: SubViewport = NetHarness.make_world_viewport(_root, "")
	var bot: NetClient = NetHarness.start_bot(holder, _port, VARDHEIM, 1)
	assert_true(await _wait_until(func() -> bool:
		return bot.get_state() == NetClient.State.IN_WORLD), "el otro jugador entra")
	var taken_name: String = bot.get_config().display_name

	_start_online_without_realm()
	var screen: RealmSelect = _online.get_realm_select()
	screen.select_realm(VARDHEIM)
	_type_name(screen, taken_name)
	assert_true(screen.try_enter())
	var first_client: NetClient = _online.get_client()
	assert_not_null(first_client, "empieza una sesión")
	assert_true(await _wait_until(func() -> bool:
		return _online.get_client() == null and screen.is_visible_in_tree()),
			"el rechazo devuelve a la elección de reino")
	assert_true(screen.get_notice_text().begins_with("Conexión rechazada: "),
			"con el motivo (%s)" % screen.get_notice_text())
	assert_true(screen.get_notice_text().contains(NetProtocol.result_text(NetProtocol.Result.NAME)))
	assert_eq(screen.get_selected_realm(), VARDHEIM, "recuerda el reino elegido")
	assert_eq(screen.get_name_edit().text, taken_name, "y el nombre, para corregirlo")
	assert_null(_online.get_world(), "sin zona")
	assert_eq(_server.get_player_count(), 1, "el servidor solo tiene al otro jugador")

	# Con otro nombre, entra.
	_type_name(screen, "Ana")
	assert_true(screen.try_enter())
	assert_true(await _wait_until(_in_world), "entra con el nombre nuevo")
	assert_true(_online.get_client() != first_client, "en una sesión nueva")
	assert_eq(_server.get_player_count(), 2)
	assert_false(screen.is_visible_in_tree())


func test_a_rejection_for_imbalance_returns_with_the_text_the_counts_and_the_short_realm_chosen() -> void:
	await _start_server()
	_start_online_without_realm()
	var screen: RealmSelect = _online.get_realm_select()
	assert_false(screen.has_realm_counts(), "antes de la primera conexión no hay recuento")
	screen.select_realm(VARDHEIM)
	assert_true(screen.try_enter())
	var client: NetClient = _online.get_client()
	assert_not_null(client)
	# Lo que ya se supo de un WELCOME anterior y el REJECT 9 de este intento (sin texto del servidor).
	_online._last_realm_counts = PackedInt32Array([30, 4, 6])
	client.rejected.emit(NetProtocol.Result.IMBALANCE, "")
	assert_true(await _wait_until(func() -> bool:
		return _online.get_client() == null and screen.is_visible_in_tree()), "vuelve a la elección de reino")
	assert_eq(screen.get_notice_text(), "Conexión rechazada: " + NetProtocol.result_text(NetProtocol.Result.IMBALANCE),
			"con el texto del REJECT 9 (el del cliente si el servidor no lo manda)")
	assert_eq(screen.get_rejected_realm(), VARDHEIM, "el reino rechazado queda marcado")
	assert_eq(screen.get_count_text(VARDHEIM), "30 jugadores · completo")
	assert_eq(screen.get_selected_realm(), SOLMARCH, "y se ofrece el reino con menos jugadores")
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
	assert_eq(screen.get_selected_realm(), SOLMARCH, "se recuerda el reino elegido")


func test_online_main_returns_to_realm_select_after_a_disconnection() -> void:
	await _start_server()
	_start_online_without_realm()
	var screen: RealmSelect = _online.get_realm_select()
	screen.select_realm(VARDHEIM)
	assert_true(screen.try_enter())
	assert_true(await _wait_until(_in_world), "entra")
	assert_not_null(_online.get_camera_rig(), "con cámara")
	assert_not_null(_online.get_hud(), "y HUD")
	_server.stop("Mantenimiento")
	assert_true(await _wait_until(func() -> bool:
		return _online.get_client() == null and screen.is_visible_in_tree()),
			"el cierre del servidor devuelve a la elección de reino")
	assert_eq(screen.get_notice_text(), "Mantenimiento", "con el aviso del servidor")
	assert_null(_online.get_world(), "se quita la zona")
	assert_null(_online.get_camera_rig(), "la cámara")
	assert_null(_online.get_hud(), "y el HUD")
	assert_eq(Input.mouse_mode, Input.MOUSE_MODE_VISIBLE, "y el cursor vuelve")
	assert_false(screen.get_enter_button().disabled, "se puede volver a intentar")


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
	assert_null(_online.get_realm_select(), "sin pantalla no hay a quién preguntar")
	assert_eq(config.realm, NetProtocol.Realm.VARDHEIM, "se entra como Vardheim, con un aviso")
	assert_true(await _wait_until(_in_world))


func _type_name(screen: RealmSelect, text: String) -> void:
	_type(screen.get_name_edit(), text)


func test_the_template_selector_is_in_the_form_and_remembers_the_choice() -> void:
	_make_screen(PackedInt32Array())
	var selector: TemplateSelector = _screen.get_template_selector()
	if not assert_not_null(selector, "la elección de reino tiene el selector de plantilla"):
		return
	assert_eq(_screen.get_selected_template(), CombatCatalog.default_template_id(), "por defecto, el escudero")
	var marksman: int = CombatCatalog.template_id(&"marksman")
	_screen.set_selected_template(marksman)
	assert_eq(_screen.get_selected_template(), marksman)
	assert_true(selector.get_button(marksman).button_pressed, "su botón queda marcado")
	selector.get_button(CombatCatalog.template_id(&"squire")).pressed.emit()
	assert_eq(_screen.get_selected_template(), CombatCatalog.template_id(&"squire"), "pulsar otro lo cambia")
