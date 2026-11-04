extends TestCase
## Tests for the game hints (UI-42, docs/fuerte.md section 6): the catalogue ([HintCatalog]), the
## log of the ones the player has already seen in user:// ([HintLog]) and their appearance ([HintToasts]: only once
## per player, queue, timings, a setting to turn them off and what triggers them). No server: a fake client
## provides the character and the alerts are synthetic.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const FORT_SCENE_PATH: String = "res://scenes/world/props/fort/vado_gris_fort.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const NET_ID: int = 900
const TEST_FILE: String = "user://test_hints_%d.cfg"


## Network client that connects to nothing: provides the character and the realm.
class FakeClient extends NetClient:
	var fake_character: PlayerCharacter = null
	var fake_config: ClientConfig = ClientConfig.new()

	func get_character() -> PlayerCharacter:
		return fake_character

	func get_config() -> ClientConfig:
		return fake_config


## A capture panel that is shown or not at will.
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


## A log in which the two welcome hints have already been seen (to test the others without them).
func _log_after_the_intro() -> HintLog:
	var hint_log: HintLog = HintLog.in_memory()
	hint_log.mark_shown(HintCatalog.COMBAT)
	hint_log.mark_shown(HintCatalog.CONTROLS)
	return hint_log


func _war(war_event: int) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.war(NET_ID, 100, war_event, VARDHEIM)


# --- Catalogue and log ------------------------------------------------------------------------

func test_every_hint_has_a_spanish_text_and_an_order() -> void:
	assert_eq(HintCatalog.IDS.size(), HintCatalog.TEXTS.size(), "the order covers the whole catalogue")
	var seen: Dictionary = {}
	for id: StringName in HintCatalog.IDS:
		assert_false(seen.has(id), "repeated id %s" % id)
		seen[id] = true
		assert_true(HintCatalog.has_hint(id))
		var text: String = HintCatalog.text_of(id)
		assert_true(text.length() > 20 and text.length() < 160, "%s: short, useful text (%d)" % [id, text.length()])
		assert_true(text.ends_with("."), "%s ends with a full stop" % id)
		assert_false(text.contains("{") or text.contains("}"), "%s leaves no placeholders unreplaced: %s" % [id, text])
	assert_false(HintCatalog.has_hint(&"inventada"))
	assert_eq(HintCatalog.text_of(&"inventada"), "")


func test_the_texts_name_the_keys_the_player_really_has() -> void:
	InputBindings.ensure_defaults()
	assert_eq(HintCatalog.text_of(HintCatalog.CONTROLS),
			"Pulsa M para abrir el mapa, mantén Tab para ver el marcador y F10 para los ajustes. F1 muestra u oculta la línea de controles.")
	assert_true(HintCatalog.text_of(HintCatalog.COMBAT).contains("Ctrl esquiva"), "with dodge on Ctrl")
	# If the player remaps the map, the hint says so.
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
			"the new key shows in the text (%s)" % text)
	assert_eq(HintCatalog.resolve("sin marcas"), "sin marcas")


func test_the_log_remembers_what_was_shown_in_a_file_and_ignores_garbage() -> void:
	var path: String = _temp_file()
	var hint_log: HintLog = HintLog.load_from(path)
	assert_eq(hint_log.get_shown_count(), 0, "without a file, nothing seen")
	assert_true(hint_log.mark_shown(HintCatalog.CONTROLS), "the first time it is recorded")
	assert_false(hint_log.mark_shown(HintCatalog.CONTROLS), "the second time it is not")
	assert_true(hint_log.mark_shown(HintCatalog.TELEGRAPH))
	var again: HintLog = HintLog.load_from(path)
	assert_true(again.has_shown(HintCatalog.CONTROLS), "another session sees it as seen")
	assert_true(again.has_shown(HintCatalog.TELEGRAPH))
	assert_false(again.has_shown(HintCatalog.GATE_CLOSED))
	assert_eq(again.get_shown_count(), 2)
	# A file with garbage: unknown things and anything that is not "true" are ignored.
	var config := ConfigFile.new()
	config.set_value(HintLog.SECTION, "controls", true)
	config.set_value(HintLog.SECTION, "gate_closed", "sí")
	config.set_value(HintLog.SECTION, "no_existe", true)
	config.save(path)
	var dirty: HintLog = HintLog.load_from(path)
	assert_true(dirty.has_shown(HintCatalog.CONTROLS))
	assert_false(dirty.has_shown(HintCatalog.GATE_CLOSED), "a value that is not true does not count")
	assert_false(dirty.has_shown(&"no_existe"), "nor an unknown hint")
	dirty.reset()
	assert_eq(HintLog.load_from(path).get_shown_count(), 0, "resetting also empties the file")
	var garbage: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	garbage.store_string("esto no es un archivo de configuración [[[")
	garbage.close()
	assert_eq(HintLog.load_from(path).get_shown_count(), 0, "a broken file breaks nothing")


func test_an_in_memory_log_never_touches_the_disk() -> void:
	var memory: HintLog = HintLog.in_memory()
	assert_true(memory.mark_shown(HintCatalog.CONTROLS))
	assert_eq(memory.path, "")
	assert_eq(memory.save_file(), OK)
	assert_true(memory.has_shown(HintCatalog.CONTROLS))
	assert_eq(memory.load_file(), OK, "and reading it does not fail either (it ends up empty)")
	assert_eq(memory.get_shown_count(), 0)


func test_without_a_screen_the_players_log_is_only_in_memory() -> void:
	HintLog.set_current(null)
	var current: HintLog = HintLog.current()
	assert_eq(DisplayServer.get_name(), "headless", "the tests run without a screen")
	assert_eq(current.path, "", "and the player's log has no file: it leaves nothing in user://")
	assert_true(current.mark_shown(HintCatalog.COMBAT))
	assert_eq(HintLog.current(), current, "it is always the same")
	HintLog.set_current(HintLog.in_memory())


func test_the_setting_exists_on_by_default_and_in_the_interface_tab() -> void:
	var spec: Dictionary = ClientSettings.get_spec(ClientSettings.HINTS)
	assert_false(spec.is_empty(), "the setting exists")
	assert_eq(spec["default"], true, "enabled by default")
	assert_eq(spec["tab"], ClientSettings.TAB_INTERFACE)
	assert_eq(spec["label"], "Pistas del juego")
	assert_eq(int(spec["kind"]), ClientSettings.Kind.BOOL)


# --- Only once per player ---------------------------------------------------------------------

func test_a_hint_shows_once_per_player_even_across_sessions() -> void:
	var path: String = _temp_file()
	var first: HintToasts = _make_toasts(_make_client(), HintLog.load_from(path))
	assert_true(first.request(HintCatalog.TELEGRAPH), "the first time it is queued and shown")
	assert_eq(first.get_current_id(), HintCatalog.TELEGRAPH)
	assert_true(first.is_showing())
	assert_eq(first.get_current_text(), HintCatalog.text_of(HintCatalog.TELEGRAPH))
	assert_false(first.request(HintCatalog.TELEGRAPH), "it is not repeated while on screen")
	first.dismiss()
	assert_false(first.is_showing())
	assert_false(first.request(HintCatalog.TELEGRAPH), "nor afterwards")
	assert_eq(first.get_shown_total(), 1)
	var second: HintToasts = _make_toasts(_make_client(), HintLog.load_from(path))
	assert_false(second.request(HintCatalog.TELEGRAPH), "nor in another session of the same player (user://)")
	assert_eq(second.get_shown_total(), 0)
	assert_true(second.request(HintCatalog.GATE_CLOSED), "but the others are")
	assert_false(second.request(&"inventada"), "a hint that does not exist, no")


func test_hints_queue_one_at_a_time_with_a_pause_and_a_fade() -> void:
	var toasts: HintToasts = _make_toasts(_make_client(), HintLog.in_memory())
	toasts.request(HintCatalog.CONTROLS)
	toasts.request(HintCatalog.FORT_NEAR)
	toasts.request(HintCatalog.TELEGRAPH)
	assert_eq(toasts.get_current_id(), HintCatalog.CONTROLS, "the first one is shown")
	assert_eq(toasts.get_queued_ids(), [HintCatalog.FORT_NEAR, HintCatalog.TELEGRAPH] as Array[StringName],
			"the others wait in the order they were requested")
	assert_near(toasts.get_seconds_left(), HintToasts.SHOW_SECONDS, 1e-6)
	toasts.advance(HintToasts.SHOW_SECONDS - HintToasts.FADE_SECONDS * 0.5)
	assert_eq(toasts.get_current_id(), HintCatalog.CONTROLS, "in the final fade it is still visible")
	toasts.advance(HintToasts.FADE_SECONDS)
	assert_eq(toasts.get_current_id(), &"", "it ends")
	assert_false(toasts.is_showing())
	toasts.advance(HintToasts.GAP_SECONDS * 0.5)
	assert_eq(toasts.get_current_id(), &"", "and leaves a pause before the next one")
	toasts.advance(HintToasts.GAP_SECONDS * 0.6)
	assert_eq(toasts.get_current_id(), HintCatalog.FORT_NEAR, "then the next one is shown")
	assert_eq(toasts.get_shown_total(), 2)
	# One requested during the pause waits for it to finish.
	toasts.dismiss()
	assert_true(toasts.request(HintCatalog.CAPTAIN_DOWN))
	assert_eq(toasts.get_current_id(), &"", "during the pause it is not shown at once")
	toasts.advance(HintToasts.GAP_SECONDS + 0.1)
	assert_eq(toasts.get_current_id(), HintCatalog.TELEGRAPH, "the one that was already waiting goes first")


# --- The setting to turn them off -------------------------------------------------------------

func test_with_the_setting_off_nothing_shows_and_nothing_is_noted() -> void:
	var hint_log: HintLog = HintLog.in_memory()
	var settings: ClientSettings = _settings(false)
	var toasts: HintToasts = _make_toasts(_make_client(), hint_log, settings)
	assert_false(toasts.is_enabled())
	assert_false(toasts.request(HintCatalog.CONTROLS), "disabled, they are not requested")
	toasts.poll()
	assert_false(toasts.is_showing())
	assert_eq(hint_log.get_shown_count(), 0, "and none is recorded as seen")
	settings.set_value(ClientSettings.HINTS, true)
	assert_true(toasts.is_enabled())
	assert_true(toasts.request(HintCatalog.CONTROLS), "when re-enabled, they are shown")


func test_turning_the_setting_off_drops_the_queue_and_hides_the_current_one() -> void:
	var hint_log: HintLog = HintLog.in_memory()
	var settings: ClientSettings = _settings()
	var toasts: HintToasts = _make_toasts(_make_client(), hint_log, settings)
	toasts.request(HintCatalog.CONTROLS)
	toasts.request(HintCatalog.TELEGRAPH)
	assert_true(toasts.is_showing())
	settings.set_value(ClientSettings.HINTS, false)
	assert_false(toasts.is_showing(), "the visible one is removed")
	assert_true(toasts.get_queued_ids().is_empty(), "and the queue is emptied")
	assert_true(hint_log.has_shown(HintCatalog.CONTROLS), "the one that was already shown, seen")
	assert_false(hint_log.has_shown(HintCatalog.TELEGRAPH), "the one that was waiting, not recorded")
	settings.set_value(ClientSettings.HINTS, true)
	assert_true(toasts.request(HintCatalog.TELEGRAPH), "and it can still be shown")


# --- What triggers them -----------------------------------------------------------------------

func test_the_captain_falling_and_a_telegraph_trigger_their_hints() -> void:
	var client: FakeClient = _make_client()
	var toasts: HintToasts = _make_toasts(client, HintLog.in_memory())
	client.war_event.emit(_war(WarEvents.UNDER_ATTACK))
	assert_false(toasts.is_showing(), "other war alerts do not")
	client.war_event.emit(_war(WarEvents.CAPTAIN_DOWN))
	assert_eq(toasts.get_current_id(), HintCatalog.CAPTAIN_DOWN, "the fallen captain does")
	toasts.dismiss()
	toasts.advance(HintToasts.GAP_SECONDS + 0.1)
	client.telegraph_received.emit(NetMessages.EntityEvent.telegraph(31, 100, 7, 0, Vector3.ZERO, 0.0, 300, 30))
	assert_eq(toasts.get_current_id(), HintCatalog.TELEGRAPH, "and a TELEGRAPH")
	toasts.bind(null, null)
	client.war_event.emit(_war(WarEvents.CAPTAIN_DOWN))
	assert_eq(toasts.get_current_id(), HintCatalog.TELEGRAPH, "without a client it does not listen")


func test_polling_offers_the_controls_hint_once_in_the_world_and_the_fort_hint_near_the_fort() -> void:
	var client: FakeClient = _make_client()
	var panel: FakePanel = _track(FakePanel.new()) as FakePanel
	var toasts: HintToasts = _make_toasts(client, HintLog.in_memory(), null, null, panel)
	client.fake_character = null
	toasts.poll()
	assert_false(toasts.is_showing(), "without a character (not yet in the world) there is nothing")
	client.fake_character = _track((load(CHARACTER_SCENE_PATH) as PackedScene).instantiate(), _root) as PlayerCharacter
	toasts.poll()
	assert_eq(toasts.get_current_id(), HintCatalog.COMBAT, "once in the world, first the combat controls")
	assert_eq(toasts.get_queued_ids(), [HintCatalog.CONTROLS] as Array[StringName], "and then those of the map and the scoreboard")
	toasts.poll()
	assert_eq(toasts.get_queued_ids().size(), 1, "only once, even if looked at again")
	panel.fake_shown = true
	toasts.poll()
	assert_eq(toasts.get_queued_ids(), [HintCatalog.CONTROLS, HintCatalog.FORT_NEAR] as Array[StringName],
			"with the fort panel visible, the fort's one")


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
	assert_true(gate != Vector3.INF, "the gate is linked")
	var near: FakeClient = _make_client(gate + Vector3(0.0, 0.0, HintToasts.GATE_DISTANCE - 2.0), VARDHEIM)
	var toasts: HintToasts = _make_toasts(near, _log_after_the_intro(), null, view)
	toasts.poll()
	assert_eq(toasts.get_current_id(), HintCatalog.GATE_CLOSED, "closed to Vardheim and 13 m from the gate, it is shown")
	# Far away, no.
	var far: FakeClient = _make_client(gate + Vector3(0.0, 0.0, HintToasts.GATE_DISTANCE + 20.0), VARDHEIM)
	var far_toasts: HintToasts = _make_toasts(far, _log_after_the_intro(), null, view)
	far_toasts.poll()
	assert_eq(far_toasts.get_current_id(), &"", "a 35 m, no")
	# For its owner the gate is not closed.
	var owner_client: FakeClient = _make_client(gate + Vector3(0.0, 0.0, 3.0), SOLMARCH)
	var owner_toasts: HintToasts = _make_toasts(owner_client, _log_after_the_intro(), null, view)
	owner_toasts.poll()
	assert_eq(owner_toasts.get_current_id(), &"", "the owner is not told")


func test_a_broken_gate_or_a_neutral_fort_changes_who_it_is_closed_to() -> void:
	var broken_view: FortressView = _fort_view(SOLMARCH, true)
	var gate: Vector3 = broken_view.get_gate_position(NET_ID)
	var client: FakeClient = _make_client(gate + Vector3(0.0, 0.0, 3.0), VARDHEIM)
	var toasts: HintToasts = _make_toasts(client, _log_after_the_intro(), null, broken_view)
	toasts.poll()
	assert_eq(toasts.get_current_id(), &"", "knocked down, it is no longer closed")
	# With the fort neutral the gate is closed to all realms.
	var neutral_view: FortressView = _fort_view(RealmCatalog.NEUTRAL_CODE)
	var neutral_client: FakeClient = _make_client(neutral_view.get_gate_position(NET_ID) + Vector3(0.0, 0.0, 3.0), SOLMARCH)
	var neutral_toasts: HintToasts = _make_toasts(neutral_client, _log_after_the_intro(), null, neutral_view)
	neutral_toasts.poll()
	assert_eq(neutral_toasts.get_current_id(), HintCatalog.GATE_CLOSED, "neutral, closed to everyone")


# --- Real view (phase 4 review, client) ---------------------------------------------------------

func test_a_hint_is_noted_only_after_it_has_been_on_screen_for_a_while() -> void:
	var hint_log: HintLog = HintLog.in_memory()
	var toasts: HintToasts = _make_toasts(_make_client(), hint_log)
	toasts.request(HintCatalog.CONTROLS)
	assert_eq(toasts.get_current_id(), HintCatalog.CONTROLS)
	assert_false(hint_log.has_shown(HintCatalog.CONTROLS), "on appearing it has not been read yet")
	toasts.advance(HintToasts.MIN_SEEN_SECONDS - 0.1)
	assert_false(hint_log.has_shown(HintCatalog.CONTROLS))
	toasts.advance(0.2)
	assert_true(hint_log.has_shown(HintCatalog.CONTROLS), "after %.0f s in view, yes" % HintToasts.MIN_SEEN_SECONDS)


func test_a_covered_hint_waits_and_one_covered_before_being_read_goes_back_to_the_queue() -> void:
	var hint_log: HintLog = HintLog.in_memory()
	var toasts: HintToasts = _make_toasts(_make_client(), hint_log)
	var covered: Array[bool] = [true]
	toasts.is_covered = func() -> bool: return covered[0]
	assert_true(toasts.request(HintCatalog.CONTROLS), "it is requested even if covered")
	assert_false(toasts.is_showing(), "but it is not shown while something covers it (the map, the scoreboard)")
	toasts.advance(HintToasts.SHOW_SECONDS * 2.0)
	assert_eq(toasts.get_queued_ids(), [HintCatalog.CONTROLS] as Array[StringName], "it waits in the queue")
	covered[0] = false
	toasts.advance(0.016)
	assert_eq(toasts.get_current_id(), HintCatalog.CONTROLS, "uncovered, it is shown")
	toasts.request(HintCatalog.FORT_NEAR)
	toasts.advance(1.0)
	covered[0] = true
	toasts.advance(0.016)
	assert_false(toasts.is_showing(), "covered shortly after appearing, it is removed")
	assert_eq(toasts.get_queued_ids(), [HintCatalog.CONTROLS, HintCatalog.FORT_NEAR] as Array[StringName],
			"and the first of the queue comes back")
	assert_false(hint_log.has_shown(HintCatalog.CONTROLS), "without being recorded")
	covered[0] = false
	toasts.advance(0.016)
	assert_eq(toasts.get_current_id(), HintCatalog.CONTROLS, "once uncovered it is shown again")
	toasts.advance(HintToasts.MIN_SEEN_SECONDS + 0.1)
	covered[0] = true
	toasts.advance(0.016)
	assert_true(hint_log.has_shown(HintCatalog.CONTROLS), "already read, covering removes it but it counts as seen")
	assert_eq(toasts.get_queued_ids(), [HintCatalog.FORT_NEAR] as Array[StringName], "and it does not return to the queue")


func test_withdrawing_a_hint_drops_it_without_noting_it() -> void:
	var hint_log: HintLog = HintLog.in_memory()
	var toasts: HintToasts = _make_toasts(_make_client(), hint_log)
	toasts.request(HintCatalog.RESPAWN_MAP)
	toasts.request(HintCatalog.CAPTAIN_DOWN)
	toasts.withdraw(HintCatalog.RESPAWN_MAP)
	assert_false(toasts.is_showing(), "the one that was visible is removed")
	assert_false(hint_log.has_shown(HintCatalog.RESPAWN_MAP), "without being recorded")
	toasts.withdraw(HintCatalog.CAPTAIN_DOWN)
	assert_true(toasts.get_queued_ids().is_empty(), "and the one that was waiting leaves the queue")
	assert_true(toasts.request(HintCatalog.RESPAWN_MAP), "it can be requested again")


func _telegraph(npc_id: int, origin: Vector3, impact_ticks: int = 60) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.telegraph(npc_id, 100, 7, NetMessages.EntityEvent.SHAPE_CIRCLE, origin, 0.0, 300,
			impact_ticks)


func _npc(client: FakeClient, net_id: int, realm: int, feet: Vector3) -> void:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = NetProtocol.EntityKind.NPC
	spawn.spawn_tick = 100
	spawn.realm = realm
	spawn.display_name = "PNJ %d" % net_id
	spawn.state = PlayerState.new()
	spawn.state.position = feet
	client.get_remote_world().on_spawn(spawn)


func test_the_telegraph_hint_needs_a_hostile_mark_near_the_player_and_still_on_the_ground() -> void:
	var client: FakeClient = _make_client(Vector3.ZERO, VARDHEIM)
	client.get_remote_world().install_visuals = false
	_npc(client, 41, VARDHEIM, Vector3(2.0, 0.0, 0.0))
	_npc(client, 42, RealmCatalog.NEUTRAL_CODE, Vector3(3.0, 0.0, 0.0))
	var toasts: HintToasts = _make_toasts(client, _log_after_the_intro())
	client.telegraph_received.emit(_telegraph(41, Vector3(2.0, 0.0, 0.0)))
	assert_false(toasts.is_showing(), "a hit from a guard of your realm cannot damage you: it is not \"an enemy attack\"")
	client.telegraph_received.emit(_telegraph(42, Vector3(200.0, 0.0, 0.0)))
	assert_false(toasts.is_showing(), "a marker at 200 m is not visible: it is not explained")
	assert_true(toasts.get_queued_ids().is_empty())
	client.telegraph_received.emit(_telegraph(42, Vector3(3.0, 0.0, 0.0)))
	assert_eq(toasts.get_current_id(), HintCatalog.TELEGRAPH, "a Hollow that hits beside you, yes")
	# If it has to wait in the queue, it expires with the marker.
	var later: HintToasts = _make_toasts(client, _log_after_the_intro())
	later.request(HintCatalog.FORT_NEAR)
	client.telegraph_received.emit(_telegraph(42, Vector3(3.0, 0.0, 0.0), 30))
	assert_eq(later.get_queued_ids(), [HintCatalog.TELEGRAPH] as Array[StringName], "queued behind the fort's one")
	later.advance(HintToasts.SHOW_SECONDS)
	later.advance(HintToasts.GAP_SECONDS + 0.1)
	assert_false(later.is_showing(), "when its turn comes the marker is gone: it is discarded")
	assert_true(later.get_queued_ids().is_empty())
	assert_false(later.get_shown_total() > 1, "only the fort's one was shown")


# --- The HUD -----------------------------------------------------------------------------------

func test_the_hud_mounts_the_hints_above_the_death_screen() -> void:
	HintLog.set_current(HintLog.in_memory())
	var client: FakeClient = _make_client()
	var rig: CameraRig = (load("res://scenes/client/camera_rig.tscn") as PackedScene).instantiate() as CameraRig
	rig.set_scripted_look(false)
	_track(rig)
	var hud: HUD = (load("res://scenes/ui/hud.tscn") as PackedScene).instantiate() as HUD
	_track(hud)
	hud.bind(client.fake_character, rig)
	hud.bind_net(client, _root)
	var toasts: HintToasts = hud.get_hints()
	if not assert_not_null(toasts, "the networked HUD mounts the hints"):
		return
	assert_eq(toasts.get_parent(), hud, "outside the war interface (which fades when dying)")
	assert_true(toasts.get_index() > hud.get_death_screen().get_index(), "and above the death screen")
	assert_true(toasts.is_enabled() == bool(ClientSettings.current().get_value(ClientSettings.HINTS)),
			"with the player's settings")
	assert_eq(HintLog.current().get_shown_count(), 0, "and the in-memory log of the tests")
	hud.bind_net(client, _root)
	assert_eq(hud.get_children().filter(func(child: Node) -> bool: return child is HintToasts).size(), 1,
			"a second call to bind_net does not duplicate them")
