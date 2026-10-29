extends TestCase
## Pruebas de las pistas del juego (UI-42, docs/fuerte.md sección 6): el catálogo ([HintCatalog]), el
## registro de las que ya vio el jugador en user:// ([HintLog]) y su aparición ([HintToasts]: una sola vez
## por jugador, cola, tiempos, ajuste para desactivarlas y qué las dispara). Sin servidor: un cliente falso
## da el personaje y los avisos son sintéticos.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const FORT_SCENE_PATH: String = "res://scenes/world/props/fort/vado_gris_fort.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const NET_ID: int = 900
const TEST_FILE: String = "user://test_hints_%d.cfg"


## Cliente de red que no conecta con nada: da el personaje y el reino.
class FakeClient extends NetClient:
	var fake_character: PlayerCharacter = null
	var fake_config: ClientConfig = ClientConfig.new()

	func get_character() -> PlayerCharacter:
		return fake_character

	func get_config() -> ClientConfig:
		return fake_config


## Un panel de captura que se ve o no a voluntad.
class FakePanel extends CapturePanel:
	var fake_shown: bool = false

	func is_shown() -> bool:
		return fake_shown


var _root: Node3D = null
var _nodes: Array[Node] = []
var _files: PackedStringArray = PackedStringArray()
var _def: FortressDefinition = null


func before_each() -> void:
	_def = load(DEFINITION_PATH) as FortressDefinition
	_root = Node3D.new()
	_root.name = "HintsTest"
	tree.root.add_child(_root)


func after_each() -> void:
	for file: String in _files:
		DirAccess.remove_absolute(file)
	_files.clear()
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


func _temp_file() -> String:
	var path: String = TEST_FILE % (Time.get_ticks_usec() + _files.size())
	_files.append(ProjectSettings.globalize_path(path))
	return path


func _settings(enabled: bool = true) -> ClientSettings:
	var settings := ClientSettings.new()
	settings.set_value(ClientSettings.HINTS, enabled)
	return settings


func _make_client(position: Vector3 = Vector3.ZERO, realm: int = VARDHEIM) -> FakeClient:
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	client.fake_config.realm = realm
	var character: PlayerCharacter = _track((load(CHARACTER_SCENE_PATH) as PackedScene).instantiate(), _root) as PlayerCharacter
	character.global_position = position
	client.fake_character = character
	return client


func _make_toasts(client: FakeClient, hint_log: HintLog, settings: ClientSettings = null,
		view: FortressView = null, panel: CapturePanel = null) -> HintToasts:
	var toasts: HintToasts = _track(HintToasts.new()) as HintToasts
	toasts.bind(client, view, panel, settings if settings != null else _settings(), hint_log)
	return toasts


## Un registro en el que las dos pistas de bienvenida ya se han visto (para probar las demás sin ellas).
func _log_after_the_intro() -> HintLog:
	var hint_log: HintLog = HintLog.in_memory()
	hint_log.mark_shown(HintCatalog.COMBAT)
	hint_log.mark_shown(HintCatalog.CONTROLS)
	return hint_log


func _war(war_event: int) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.war(NET_ID, 100, war_event, VARDHEIM)


# --- Catálogo y registro ----------------------------------------------------------------------

func test_every_hint_has_a_spanish_text_and_an_order() -> void:
	assert_eq(HintCatalog.IDS.size(), HintCatalog.TEXTS.size(), "el orden cubre todo el catálogo")
	var seen: Dictionary = {}
	for id: StringName in HintCatalog.IDS:
		assert_false(seen.has(id), "id repetido %s" % id)
		seen[id] = true
		assert_true(HintCatalog.has_hint(id))
		var text: String = HintCatalog.text_of(id)
		assert_true(text.length() > 20 and text.length() < 160, "%s: texto corto y útil (%d)" % [id, text.length()])
		assert_true(text.ends_with("."), "%s acaba en punto" % id)
		assert_false(text.contains("{") or text.contains("}"), "%s no deja marcas sin sustituir: %s" % [id, text])
	assert_false(HintCatalog.has_hint(&"inventada"))
	assert_eq(HintCatalog.text_of(&"inventada"), "")


func test_the_texts_name_the_keys_the_player_really_has() -> void:
	InputBindings.ensure_defaults()
	assert_eq(HintCatalog.text_of(HintCatalog.CONTROLS),
			"Pulsa M para abrir el mapa, mantén Tab para ver el marcador y F10 para los ajustes.")
	assert_true(HintCatalog.text_of(HintCatalog.COMBAT).contains("Ctrl esquiva"), "con la esquiva en Ctrl")
	# Si el jugador reasigna el mapa, la pista lo dice.
	var saved: Array[InputEvent] = InputMap.action_get_events(&"open_map")
	InputMap.action_erase_events(&"open_map")
	var event := InputEventKey.new()
	event.physical_keycode = KEY_N
	InputMap.action_add_event(&"open_map", event)
	var text: String = HintCatalog.text_of(HintCatalog.CONTROLS)
	InputMap.action_erase_events(&"open_map")
	for old: InputEvent in saved:
		InputMap.action_add_event(&"open_map", old)
	assert_true(text.begins_with("Pulsa N ") or text.begins_with("Pulsa " + UIKeyGlyph.label_for_event(event) + " "),
			"la tecla nueva sale en el texto (%s)" % text)
	assert_eq(HintCatalog.resolve("sin marcas"), "sin marcas")


func test_the_log_remembers_what_was_shown_in_a_file_and_ignores_garbage() -> void:
	var path: String = _temp_file()
	var hint_log: HintLog = HintLog.load_from(path)
	assert_eq(hint_log.get_shown_count(), 0, "sin archivo, nada visto")
	assert_true(hint_log.mark_shown(HintCatalog.CONTROLS), "la primera vez se anota")
	assert_false(hint_log.mark_shown(HintCatalog.CONTROLS), "la segunda ya no")
	assert_true(hint_log.mark_shown(HintCatalog.TELEGRAPH))
	var again: HintLog = HintLog.load_from(path)
	assert_true(again.has_shown(HintCatalog.CONTROLS), "otra sesión lo ve como visto")
	assert_true(again.has_shown(HintCatalog.TELEGRAPH))
	assert_false(again.has_shown(HintCatalog.GATE_CLOSED))
	assert_eq(again.get_shown_count(), 2)
	# Un archivo con basura: lo desconocido y lo que no es «true» se ignora.
	var config := ConfigFile.new()
	config.set_value(HintLog.SECTION, "controls", true)
	config.set_value(HintLog.SECTION, "gate_closed", "sí")
	config.set_value(HintLog.SECTION, "no_existe", true)
	config.save(path)
	var dirty: HintLog = HintLog.load_from(path)
	assert_true(dirty.has_shown(HintCatalog.CONTROLS))
	assert_false(dirty.has_shown(HintCatalog.GATE_CLOSED), "un valor que no es true no cuenta")
	assert_false(dirty.has_shown(&"no_existe"), "ni una pista desconocida")
	dirty.reset()
	assert_eq(HintLog.load_from(path).get_shown_count(), 0, "restablecer vacía también el archivo")
	var garbage: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	garbage.store_string("esto no es un archivo de configuración [[[")
	garbage.close()
	assert_eq(HintLog.load_from(path).get_shown_count(), 0, "un archivo roto no rompe nada")


func test_an_in_memory_log_never_touches_the_disk() -> void:
	var memory: HintLog = HintLog.in_memory()
	assert_true(memory.mark_shown(HintCatalog.CONTROLS))
	assert_eq(memory.path, "")
	assert_eq(memory.save_file(), OK)
	assert_true(memory.has_shown(HintCatalog.CONTROLS))
	assert_eq(memory.load_file(), OK, "y leerlo tampoco falla (queda vacío)")
	assert_eq(memory.get_shown_count(), 0)


func test_without_a_screen_the_players_log_is_only_in_memory() -> void:
	HintLog.set_current(null)
	var current: HintLog = HintLog.current()
	assert_eq(DisplayServer.get_name(), "headless", "las pruebas van sin pantalla")
	assert_eq(current.path, "", "y el registro del jugador no tiene archivo: no deja nada en user://")
	assert_true(current.mark_shown(HintCatalog.COMBAT))
	assert_eq(HintLog.current(), current, "es siempre el mismo")
	HintLog.set_current(HintLog.in_memory())


func test_the_setting_exists_on_by_default_and_in_the_interface_tab() -> void:
	var spec: Dictionary = ClientSettings.get_spec(ClientSettings.HINTS)
	assert_false(spec.is_empty(), "el ajuste existe")
	assert_eq(spec["default"], true, "activado por defecto")
	assert_eq(spec["tab"], ClientSettings.TAB_INTERFACE)
	assert_eq(spec["label"], "Pistas del juego")
	assert_eq(int(spec["kind"]), ClientSettings.Kind.BOOL)


# --- Una sola vez por jugador -----------------------------------------------------------------

func test_a_hint_shows_once_per_player_even_across_sessions() -> void:
	var path: String = _temp_file()
	var first: HintToasts = _make_toasts(_make_client(), HintLog.load_from(path))
	assert_true(first.request(HintCatalog.TELEGRAPH), "la primera vez se pone en cola y sale")
	assert_eq(first.get_current_id(), HintCatalog.TELEGRAPH)
	assert_true(first.is_showing())
	assert_eq(first.get_current_text(), HintCatalog.text_of(HintCatalog.TELEGRAPH))
	assert_false(first.request(HintCatalog.TELEGRAPH), "no se repite mientras está en pantalla")
	first.dismiss()
	assert_false(first.is_showing())
	assert_false(first.request(HintCatalog.TELEGRAPH), "ni después")
	assert_eq(first.get_shown_total(), 1)
	var second: HintToasts = _make_toasts(_make_client(), HintLog.load_from(path))
	assert_false(second.request(HintCatalog.TELEGRAPH), "ni en otra sesión del mismo jugador (user://)")
	assert_eq(second.get_shown_total(), 0)
	assert_true(second.request(HintCatalog.GATE_CLOSED), "pero las demás sí")
	assert_false(second.request(&"inventada"), "una pista que no existe, no")


func test_hints_queue_one_at_a_time_with_a_pause_and_a_fade() -> void:
	var toasts: HintToasts = _make_toasts(_make_client(), HintLog.in_memory())
	toasts.request(HintCatalog.CONTROLS)
	toasts.request(HintCatalog.FORT_NEAR)
	toasts.request(HintCatalog.TELEGRAPH)
	assert_eq(toasts.get_current_id(), HintCatalog.CONTROLS, "sale la primera")
	assert_eq(toasts.get_queued_ids(), [HintCatalog.FORT_NEAR, HintCatalog.TELEGRAPH] as Array[StringName],
			"las otras esperan en el orden en que se pidieron")
	assert_near(toasts.get_seconds_left(), HintToasts.SHOW_SECONDS, 1e-6)
	toasts.advance(HintToasts.SHOW_SECONDS - HintToasts.FADE_SECONDS * 0.5)
	assert_eq(toasts.get_current_id(), HintCatalog.CONTROLS, "en el fundido final aún se ve")
	toasts.advance(HintToasts.FADE_SECONDS)
	assert_eq(toasts.get_current_id(), &"", "se acaba")
	assert_false(toasts.is_showing())
	toasts.advance(HintToasts.GAP_SECONDS * 0.5)
	assert_eq(toasts.get_current_id(), &"", "y deja una pausa antes de la siguiente")
	toasts.advance(HintToasts.GAP_SECONDS * 0.6)
	assert_eq(toasts.get_current_id(), HintCatalog.FORT_NEAR, "luego sale la siguiente")
	assert_eq(toasts.get_shown_total(), 2)
	# Una pedida durante la pausa espera a que acabe.
	toasts.dismiss()
	assert_true(toasts.request(HintCatalog.CAPTAIN_DOWN))
	assert_eq(toasts.get_current_id(), &"", "durante la pausa no sale al momento")
	toasts.advance(HintToasts.GAP_SECONDS + 0.1)
	assert_eq(toasts.get_current_id(), HintCatalog.TELEGRAPH, "la que ya esperaba va antes")


# --- El ajuste para desactivarlas -------------------------------------------------------------

func test_with_the_setting_off_nothing_shows_and_nothing_is_noted() -> void:
	var hint_log: HintLog = HintLog.in_memory()
	var settings: ClientSettings = _settings(false)
	var toasts: HintToasts = _make_toasts(_make_client(), hint_log, settings)
	assert_false(toasts.is_enabled())
	assert_false(toasts.request(HintCatalog.CONTROLS), "desactivadas, no se piden")
	toasts.poll()
	assert_false(toasts.is_showing())
	assert_eq(hint_log.get_shown_count(), 0, "y no se anota ninguna como vista")
	settings.set_value(ClientSettings.HINTS, true)
	assert_true(toasts.is_enabled())
	assert_true(toasts.request(HintCatalog.CONTROLS), "al volver a activarlas, salen")


func test_turning_the_setting_off_drops_the_queue_and_hides_the_current_one() -> void:
	var hint_log: HintLog = HintLog.in_memory()
	var settings: ClientSettings = _settings()
	var toasts: HintToasts = _make_toasts(_make_client(), hint_log, settings)
	toasts.request(HintCatalog.CONTROLS)
	toasts.request(HintCatalog.TELEGRAPH)
	assert_true(toasts.is_showing())
	settings.set_value(ClientSettings.HINTS, false)
	assert_false(toasts.is_showing(), "se quita la que se ve")
	assert_true(toasts.get_queued_ids().is_empty(), "y se vacía la cola")
	assert_true(hint_log.has_shown(HintCatalog.CONTROLS), "la que ya salió, vista")
	assert_false(hint_log.has_shown(HintCatalog.TELEGRAPH), "la que esperaba, sin anotar")
	settings.set_value(ClientSettings.HINTS, true)
	assert_true(toasts.request(HintCatalog.TELEGRAPH), "y todavía puede salir")


# --- Qué las dispara --------------------------------------------------------------------------

func test_the_captain_falling_and_a_telegraph_trigger_their_hints() -> void:
	var client: FakeClient = _make_client()
	var toasts: HintToasts = _make_toasts(client, HintLog.in_memory())
	client.war_event.emit(_war(WarEvents.UNDER_ATTACK))
	assert_false(toasts.is_showing(), "otros avisos de guerra no")
	client.war_event.emit(_war(WarEvents.CAPTAIN_DOWN))
	assert_eq(toasts.get_current_id(), HintCatalog.CAPTAIN_DOWN, "el capitán caído sí")
	toasts.dismiss()
	toasts.advance(HintToasts.GAP_SECONDS + 0.1)
	client.telegraph_received.emit(NetMessages.EntityEvent.telegraph(31, 100, 7, 0, Vector3.ZERO, 0.0, 300, 30))
	assert_eq(toasts.get_current_id(), HintCatalog.TELEGRAPH, "y un TELEGRAPH")
	toasts.bind(null, null)
	client.war_event.emit(_war(WarEvents.CAPTAIN_DOWN))
	assert_eq(toasts.get_current_id(), HintCatalog.TELEGRAPH, "sin cliente no escucha")


func test_polling_offers_the_controls_hint_once_in_the_world_and_the_fort_hint_near_the_fort() -> void:
	var client: FakeClient = _make_client()
	var panel: FakePanel = _track(FakePanel.new()) as FakePanel
	var toasts: HintToasts = _make_toasts(client, HintLog.in_memory(), null, null, panel)
	client.fake_character = null
	toasts.poll()
	assert_false(toasts.is_showing(), "sin personaje (aún no está en el mundo) no hay nada")
	client.fake_character = _track((load(CHARACTER_SCENE_PATH) as PackedScene).instantiate(), _root) as PlayerCharacter
	toasts.poll()
	assert_eq(toasts.get_current_id(), HintCatalog.COMBAT, "ya en el mundo, primero los controles de combate")
	assert_eq(toasts.get_queued_ids(), [HintCatalog.CONTROLS] as Array[StringName], "y después los del mapa y el marcador")
	toasts.poll()
	assert_eq(toasts.get_queued_ids().size(), 1, "una sola vez, aunque se mire de nuevo")
	panel.fake_shown = true
	toasts.poll()
	assert_eq(toasts.get_queued_ids(), [HintCatalog.CONTROLS, HintCatalog.FORT_NEAR] as Array[StringName],
			"con el panel del fuerte visible, la del fuerte")


func _fort_view(owner_realm: int, broken: bool = false) -> FortressView:
	var view: FortressView = _track(FortressView.new()) as FortressView
	var fort_node: Node3D = (load(FORT_SCENE_PATH) as PackedScene).instantiate() as Node3D
	fort_node.add_to_group(Zones.FORTRESS_GROUP)
	fort_node.set_meta(Zones.FORTRESS_DEFINITION_META, DEFINITION_PATH)
	_track(fort_node, _root)
	fort_node.global_position = Vector3(0.0, 10.2, 0.0)
	view.set_zone(_root)
	var state: FortressState = FortressState.initial(_def, 100)
	state.owner = owner_realm
	if broken:
		state.gate_health = 0
	view.on_spawn(NetMessages.EntitySpawn.decode(NetMessages.EntitySpawn.for_fortress(NET_ID, 100,
			String(_def.id), state).encode()))
	view.advance(100.0)
	return view


func test_a_gate_closed_for_your_realm_triggers_its_hint_only_when_you_are_close() -> void:
	var view: FortressView = _fort_view(SOLMARCH)
	var gate: Vector3 = view.get_gate_position(NET_ID)
	assert_true(gate != Vector3.INF, "la puerta está enlazada")
	var near: FakeClient = _make_client(gate + Vector3(0.0, 0.0, HintToasts.GATE_DISTANCE - 2.0), VARDHEIM)
	var toasts: HintToasts = _make_toasts(near, _log_after_the_intro(), null, view)
	toasts.poll()
	assert_eq(toasts.get_current_id(), HintCatalog.GATE_CLOSED, "cerrada para Vardheim y a 13 m de la puerta, sale")
	# Lejos, no.
	var far: FakeClient = _make_client(gate + Vector3(0.0, 0.0, HintToasts.GATE_DISTANCE + 20.0), VARDHEIM)
	var far_toasts: HintToasts = _make_toasts(far, _log_after_the_intro(), null, view)
	far_toasts.poll()
	assert_eq(far_toasts.get_current_id(), &"", "a 35 m, no")
	# Para su dueño la puerta no está cerrada.
	var owner_client: FakeClient = _make_client(gate + Vector3(0.0, 0.0, 3.0), SOLMARCH)
	var owner_toasts: HintToasts = _make_toasts(owner_client, _log_after_the_intro(), null, view)
	owner_toasts.poll()
	assert_eq(owner_toasts.get_current_id(), &"", "al dueño no se le dice")


func test_a_broken_gate_or_a_neutral_fort_changes_who_it_is_closed_to() -> void:
	var broken_view: FortressView = _fort_view(SOLMARCH, true)
	var gate: Vector3 = broken_view.get_gate_position(NET_ID)
	var client: FakeClient = _make_client(gate + Vector3(0.0, 0.0, 3.0), VARDHEIM)
	var toasts: HintToasts = _make_toasts(client, _log_after_the_intro(), null, broken_view)
	toasts.poll()
	assert_eq(toasts.get_current_id(), &"", "derribada, ya no está cerrada")
	# Con el fuerte neutral la puerta está cerrada para todos los reinos.
	var neutral_view: FortressView = _fort_view(RealmCatalog.NEUTRAL_CODE)
	var neutral_client: FakeClient = _make_client(neutral_view.get_gate_position(NET_ID) + Vector3(0.0, 0.0, 3.0), SOLMARCH)
	var neutral_toasts: HintToasts = _make_toasts(neutral_client, _log_after_the_intro(), null, neutral_view)
	neutral_toasts.poll()
	assert_eq(neutral_toasts.get_current_id(), HintCatalog.GATE_CLOSED, "neutral, cerrada para todos")


# --- El HUD ------------------------------------------------------------------------------------

func test_the_war_hud_mounts_the_hints() -> void:
	HintLog.set_current(HintLog.in_memory())
	var client: FakeClient = _make_client()
	var war: WarHud = _track(WarHud.new()) as WarHud
	war.bind(client, null)
	var toasts: HintToasts = war.get_hints()
	if not assert_not_null(toasts, "la interfaz de guerra monta las pistas"):
		return
	assert_true(toasts.is_enabled() == bool(ClientSettings.current().get_value(ClientSettings.HINTS)),
			"con los ajustes del jugador")
	assert_eq(HintLog.current().get_shown_count(), 0, "y el registro en memoria de las pruebas")
