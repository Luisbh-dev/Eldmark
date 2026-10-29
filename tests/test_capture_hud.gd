extends TestCase
## Pruebas de la interfaz de captura del fuerte (UI-18, docs/fuerte.md sección 6) con estados falsos:
## el panel de captura ([CapturePanel]: dueño, fase, progreso, «disputado», presentes, puerta y cuándo
## se ve), los banners de guerra ([WarBanners]), la barra de jefe ([BossBar], [BossInfo]) y las marcas
## en el suelo de los ataques de los PNJ ([TelegraphMarks]). Sin servidor: un cliente falso da la
## posición, el combate y el tick, y los mensajes son sintéticos.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const FORT_SCENE_PATH: String = "res://scenes/world/props/fort/vado_gris_fort.tscn"
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const NET_ID: int = 900


## Cliente de red que no conecta con nada: da donde está el jugador, si combate y el tick.
class FakeClient extends NetClient:
	var fake_character: PlayerCharacter = null
	var fake_in_combat: bool = false
	var fake_tick: int = 0
	var fake_config: ClientConfig = ClientConfig.new()

	func get_character() -> PlayerCharacter:
		return fake_character

	func is_in_combat() -> bool:
		return fake_in_combat

	func get_estimated_server_tick() -> int:
		return fake_tick

	func get_config() -> ClientConfig:
		return fake_config


var _root: Node3D = null
var _def: FortressDefinition = null
var _nodes: Array[Node] = []


func before_each() -> void:
	_def = load(DEFINITION_PATH) as FortressDefinition
	_root = Node3D.new()
	_root.name = "CaptureHudTest"
	tree.root.add_child(_root)
	BossInfo.resolver = Callable()
	BossInfo.clear_cache()


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


func _state(values: Dictionary = {}) -> FortressState:
	var state := FortressState.initial(_def, 0)
	for field_id: int in values:
		FortressFields.set_value(state, field_id, int(values[field_id]))
	return state


# --- Panel de captura -------------------------------------------------------------------------

func test_a_neutral_garrisoned_fort_shows_no_owner_the_gate_and_no_capture() -> void:
	var panel: CapturePanel = _track(CapturePanel.new()) as CapturePanel
	panel.bind(null, null, VARDHEIM)
	panel.show_state(_state(), 0.0, "Fuerte del Vado Gris", 100)
	assert_eq(panel.get_title_text(), "Fuerte del Vado Gris")
	assert_eq(panel.get_owner_text(), "Sin dueño (los Huecos)")
	assert_eq(panel.get_owner_color(), RealmCatalog.color_of(RealmCatalog.HUECOS), "color de los Huecos")
	assert_eq(panel.get_phase_text(), CapturePanel.TEXT_GARRISONED)
	assert_false(panel.is_progress_shown(), "sin captura no hay barra de progreso")
	assert_false(panel.is_presence_shown(), "ni presentes con el círculo inactivo")
	assert_eq(panel.get_status_text(), "")
	assert_false(panel.is_attacked_shown())
	assert_true(panel.is_gate_shown())
	assert_eq(panel.get_gate_text(), "Puerta 9000 / 9000")
	assert_near(panel.get_gate_fraction(), 1.0, 1e-9)


func test_the_owner_has_its_color_and_the_phase_text_depends_on_who_looks() -> void:
	var panel: CapturePanel = _track(CapturePanel.new()) as CapturePanel
	panel.bind(null, null, VARDHEIM)
	var owned: FortressState = _state({FortressFields.OWNER: VARDHEIM})
	panel.show_state(owned, 0.0, "Fuerte", 0)
	assert_eq(panel.get_owner_text(), "Dueño: Vardheim")
	assert_eq(panel.get_owner_color(), RealmCatalog.color_of(RealmCatalog.VARDHEIM))
	assert_eq(panel.get_phase_text(), CapturePanel.TEXT_GARRISONED_OWN, "al dueño le toca defender")
	panel.bind(null, null, SOLMARCH)
	panel.show_state(owned, 0.0, "Fuerte", 0)
	assert_eq(panel.get_phase_text(), CapturePanel.TEXT_GARRISONED, "a un enemigo, no")
	var vulnerable: FortressState = _state({FortressFields.OWNER: VARDHEIM,
			FortressFields.PHASE: FortressState.Phase.VULNERABLE})
	panel.show_state(vulnerable, 0.0, "Fuerte", 0)
	assert_eq(panel.get_phase_text(), CapturePanel.TEXT_VULNERABLE)
	panel.bind(null, null, VARDHEIM)
	panel.show_state(vulnerable, 0.0, "Fuerte", 0)
	assert_eq(panel.get_phase_text(), CapturePanel.TEXT_VULNERABLE_OWN)
	panel.show_state(_state({FortressFields.OWNER: SOLMARCH, FortressFields.PHASE: FortressState.Phase.CONSOLIDATING}),
			0.0, "Fuerte", 0)
	assert_eq(panel.get_owner_text(), "Dueño: Solmarch")
	assert_eq(panel.get_phase_text(), CapturePanel.TEXT_CONSOLIDATING)


func test_a_capture_shows_the_bar_in_the_capturers_color_and_the_state_of_the_progress() -> void:
	var panel: CapturePanel = _track(CapturePanel.new()) as CapturePanel
	panel.bind(null, null, VARDHEIM)
	var capturing: FortressState = _state({FortressFields.PHASE: FortressState.Phase.CAPTURING,
			FortressFields.CAPTURE_REALM: SOLMARCH, FortressFields.CAPTURE_RATE: 24})
	panel.show_state(capturing, 0.5, "Fuerte", 0)
	assert_true(panel.is_progress_shown())
	assert_near(panel.get_progress_fraction(), 0.5, 1e-9)
	assert_eq(panel.get_progress_color(), RealmCatalog.color_of(RealmCatalog.SOLMARCH), "el color del captor")
	assert_eq(panel.get_progress_text(), "50 %")
	assert_eq(panel.get_phase_text(), "Solmarch captura el fuerte")
	assert_eq(panel.get_status_text(), "", "avanzando no hay etiqueta")
	capturing.capture_rate = 0
	panel.show_state(capturing, 0.5, "Fuerte", 0)
	assert_eq(panel.get_status_text(), CapturePanel.TEXT_FROZEN, "sin velocidad, congelado")
	capturing.capture_rate = -24
	panel.show_state(capturing, 0.4, "Fuerte", 0)
	assert_eq(panel.get_status_text(), CapturePanel.TEXT_RETREATING, "con velocidad negativa, retrocede")
	capturing.contested = true
	capturing.capture_rate = 0
	panel.show_state(capturing, 0.4, "Fuerte", 0)
	assert_eq(panel.get_status_text(), CapturePanel.TEXT_CONTESTED, "con varios bandos, disputado")
	# Pasa a otro captor y la barra cambia de color; sin captura se esconde.
	capturing.capture_realm = VARDHEIM
	panel.show_state(capturing, 0.1, "Fuerte", 0)
	assert_eq(panel.get_progress_color(), RealmCatalog.color_of(RealmCatalog.VARDHEIM))
	panel.show_state(_state({FortressFields.PHASE: FortressState.Phase.VULNERABLE}), 0.9, "Fuerte", 0)
	assert_false(panel.is_progress_shown(), "en VULNERABLE no hay barra")
	assert_eq(panel.get_progress_fraction(), 0.0)


func test_present_players_are_listed_per_realm_only_while_the_circle_is_active() -> void:
	var panel: CapturePanel = _track(CapturePanel.new()) as CapturePanel
	panel.bind(null, null, VARDHEIM)
	var vulnerable: FortressState = _state({FortressFields.PHASE: FortressState.Phase.VULNERABLE,
			FortressFields.PRESENCE_BASE + VARDHEIM: 2, FortressFields.PRESENCE_BASE + SOLMARCH: 1,
			FortressFields.CONTESTED: 1})
	panel.show_state(vulnerable, 0.0, "Fuerte", 0)
	assert_true(panel.is_presence_shown())
	assert_eq(panel.get_presence_text(VARDHEIM), "Vardheim 2")
	assert_eq(panel.get_presence_text(SOLMARCH), "Solmarch 1")
	assert_eq(panel.get_presence_color(VARDHEIM), RealmCatalog.color_of(RealmCatalog.VARDHEIM))
	assert_eq(panel.get_presence_color(SOLMARCH), RealmCatalog.color_of(RealmCatalog.SOLMARCH))
	assert_eq(panel.get_presence_text(ASKARRA), "", "Askarra no figura si no hay nadie ni es el reino propio")
	assert_eq(panel.get_status_text(), "Disputado", "con dos bandos dentro, disputado")
	vulnerable.presence[ASKARRA] = 3
	panel.show_state(vulnerable, 0.0, "Fuerte", 0)
	assert_eq(panel.get_presence_text(ASKARRA), "Askarra 3", "pero sí cuando entra alguien")
	panel.show_state(_state({FortressFields.PHASE: FortressState.Phase.CONSOLIDATING}), 0.0, "Fuerte", 0)
	assert_false(panel.is_presence_shown(), "consolidando, el círculo está inactivo")


func test_the_gate_health_bar_and_the_broken_gate() -> void:
	var panel: CapturePanel = _track(CapturePanel.new()) as CapturePanel
	panel.bind(null, null, VARDHEIM)
	panel.show_state(_state({FortressFields.GATE_HEALTH: 4500}), 0.0, "Fuerte", 0)
	assert_eq(panel.get_gate_text(), "Puerta 4500 / 9000")
	assert_near(panel.get_gate_fraction(), 0.5, 1e-9)
	var healthy_color: Color = panel.get_gate_color()
	panel.show_state(_state({FortressFields.GATE_HEALTH: 0}), 0.0, "Fuerte", 0)
	assert_eq(panel.get_gate_text(), "Puerta derribada")
	assert_eq(panel.get_gate_fraction(), 0.0)
	assert_true(panel.get_gate_color() != healthy_color, "la puerta rota cambia de color")
	panel.show_state(_state({FortressFields.GATE_MAX: 0, FortressFields.GATE_HEALTH: 0}), 0.0, "Fuerte", 0)
	assert_false(panel.is_gate_shown(), "sin puerta (vida máxima 0) no se enseña")


func test_the_attacked_mark_lasts_until_the_under_attack_tick() -> void:
	var panel: CapturePanel = _track(CapturePanel.new()) as CapturePanel
	panel.bind(null, null, VARDHEIM)
	var state: FortressState = _state({FortressFields.UNDER_ATTACK_UNTIL_TICK: 2000})
	panel.show_state(state, 0.0, "Fuerte", 1500)
	assert_true(panel.is_attacked_shown(), "mientras el tick del servidor no llega a under_attack_until")
	panel.show_state(state, 0.0, "Fuerte", 2000)
	assert_false(panel.is_attacked_shown(), "y deja de verse al alcanzarlo")
	panel.show_state(state, 0.0, "Fuerte", 0)
	assert_false(panel.is_attacked_shown(), "sin tick conocido no se enseña")


func test_the_panel_shows_near_the_fort_or_when_fighting_for_it() -> void:
	assert_true(CapturePanel.should_show(0.0, false))
	assert_true(CapturePanel.should_show(80.0, false), "a 80 m exactos se ve")
	assert_false(CapturePanel.should_show(80.5, false), "más lejos, no")
	assert_false(CapturePanel.should_show(150.0, false))
	assert_true(CapturePanel.should_show(150.0, true), "combatiendo se ve desde más lejos")
	assert_false(CapturePanel.should_show(CapturePanel.COMBAT_DISTANCE + 1.0, true))
	assert_false(CapturePanel.should_show(INF, true), "sin saber dónde está el fuerte, no")


func test_refresh_reads_the_fortress_view_and_the_player_position() -> void:
	var view: FortressView = _track(FortressView.new()) as FortressView
	var fort: Node3D = (load(FORT_SCENE_PATH) as PackedScene).instantiate() as Node3D
	fort.add_to_group(Zones.FORTRESS_GROUP)
	fort.set_meta(Zones.FORTRESS_DEFINITION_META, DEFINITION_PATH)
	_track(fort, _root)
	view.set_zone(_root)
	view.on_spawn(NetMessages.EntitySpawn.decode(NetMessages.EntitySpawn.for_fortress(NET_ID, 100,
			"vado_gris_fort", _state({FortressFields.OWNER: SOLMARCH})).encode()))
	view.advance(100.0)
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	var character: PlayerCharacter = _track((load(CHARACTER_SCENE_PATH) as PackedScene).instantiate(), _root) as PlayerCharacter
	client.fake_character = character
	var panel: CapturePanel = _track(CapturePanel.new()) as CapturePanel
	panel.bind(view, client, VARDHEIM)
	character.global_position = fort.global_position + Vector3(60.0, 0.0, 0.0)
	panel.refresh()
	assert_true(panel.is_shown(), "a 60 m del fuerte se ve")
	assert_eq(panel.get_owner_text(), "Dueño: Solmarch")
	assert_eq(panel.get_title_text(), "Fuerte del Vado Gris", "el nombre sale de la definición")
	character.global_position = fort.global_position + Vector3(120.0, 0.0, 0.0)
	panel.refresh()
	assert_false(panel.is_shown(), "a 120 m, no")
	client.fake_in_combat = true
	panel.refresh()
	assert_true(panel.is_shown(), "pero combatiendo, sí")
	client.fake_in_combat = false
	character.global_position = fort.global_position
	panel.refresh()
	assert_true(panel.is_shown())
	# La captura sigue la fórmula en el instante de dibujo: 12 por tick desde el 200.
	var change := NetMessages.ObjectState.new()
	change.net_id = NET_ID
	change.tick = 200
	change.add_field(FortressFields.PHASE, NetMessages.ObjectField.ValueType.U8, FortressState.Phase.CAPTURING)
	change.add_field(FortressFields.CAPTURE_REALM, NetMessages.ObjectField.ValueType.U8, VARDHEIM)
	change.add_field(FortressFields.CAPTURE_RATE, NetMessages.ObjectField.ValueType.S32, 12)
	change.add_field(FortressFields.CAPTURE_START_TICK, NetMessages.ObjectField.ValueType.U32, 200)
	view.on_object_state(NetMessages.ObjectState.decode(change.encode()))
	view.advance(200.0)
	panel.refresh()
	assert_true(panel.is_progress_shown(), "en cuanto se dibuja el 200, la barra")
	assert_eq(panel.get_phase_text(), "Vardheim captura el fuerte")
	# Sin vista, el panel se oculta.
	panel.bind(null, client, VARDHEIM)
	panel.refresh()
	assert_false(panel.is_shown())


# --- Banners de guerra ------------------------------------------------------------------------

func test_every_war_event_becomes_its_spanish_banner() -> void:
	var banners: WarBanners = _track(WarBanners.new()) as WarBanners
	var view: FortressView = _track(FortressView.new()) as FortressView
	view.on_spawn(NetMessages.EntitySpawn.decode(NetMessages.EntitySpawn.for_fortress(NET_ID, 100,
			"vado_gris_fort", _state()).encode()))
	banners.bind(null, view)
	var expected: Dictionary = {
		WarEvents.UNDER_ATTACK: "¡Vardheim ataca el Fuerte del Vado Gris!",
		WarEvents.CAPTAIN_DOWN: "¡El capitán del Fuerte del Vado Gris ha caído ante Vardheim!",
		WarEvents.CAPTURE_STARTED: "Vardheim empieza a capturar el Fuerte del Vado Gris.",
		WarEvents.CAPTURE_CONTESTED: "La captura del Fuerte del Vado Gris está disputada.",
		WarEvents.GATE_BROKEN: "¡Vardheim ha derribado la puerta del Fuerte del Vado Gris!",
		WarEvents.FORT_CAPTURED: "¡Vardheim ha capturado el Fuerte del Vado Gris!",
	}
	for war_event: int in expected:
		banners.clear()
		var shown: String = banners.show_war_event(NetMessages.EntityEvent.war(NET_ID, 10, war_event, VARDHEIM))
		assert_eq(shown, expected[war_event], "texto del aviso %d" % war_event)
		assert_eq(banners.get_texts(), PackedStringArray([expected[war_event]]))
	banners.clear()
	assert_eq(banners.show_war_event(NetMessages.EntityEvent.war(NET_ID, 10, WarEvents.FORT_RESET, 0)),
			"El Fuerte del Vado Gris ha vuelto a quedar sin dueño.")
	assert_eq(banners.show_war_event(null), "", "un aviso nulo no hace nada")
	var bogus := NetMessages.EntityEvent.new()
	bogus.event = NetMessages.EntityEvent.Kind.WAR
	bogus.war_event = 77
	assert_eq(banners.show_war_event(bogus), "", "ni un aviso desconocido")
	assert_eq(banners.get_banner_count(), 1)


func test_banners_take_the_realm_color_and_the_big_ones_last_longer() -> void:
	var banners: WarBanners = _track(WarBanners.new()) as WarBanners
	banners.show_war_event(NetMessages.EntityEvent.war(NET_ID, 10, WarEvents.CAPTURE_STARTED, SOLMARCH))
	banners.show_war_event(NetMessages.EntityEvent.war(NET_ID, 10, WarEvents.FORT_CAPTURED, VARDHEIM))
	banners.show_war_event(NetMessages.EntityEvent.war(NET_ID, 10, WarEvents.CAPTURE_CONTESTED, SOLMARCH))
	assert_eq(banners.get_banner_color(0), RealmCatalog.color_of(RealmCatalog.SOLMARCH), "el color del bando")
	assert_eq(banners.get_banner_color(1), RealmCatalog.color_of(RealmCatalog.VARDHEIM))
	assert_eq(banners.get_banner_color(2), UIPalette.WARNING, "la disputa no es de nadie")
	assert_false(banners.is_banner_big(0))
	assert_true(banners.is_banner_big(1), "un fuerte capturado es grande")
	assert_near(banners.get_banner_seconds_left(0), WarBanners.NORMAL_SECONDS, 1e-9)
	assert_near(banners.get_banner_seconds_left(1), WarBanners.BIG_SECONDS, 1e-9)
	banners.advance(WarBanners.NORMAL_SECONDS + 0.1)
	assert_eq(banners.get_banner_count(), 1, "el normal se va y el grande sigue")
	assert_true(banners.is_banner_big(0))
	banners.advance(WarBanners.BIG_SECONDS)
	assert_eq(banners.get_banner_count(), 0, "y luego también")


func test_banners_stack_up_to_three_and_the_oldest_leaves() -> void:
	var banners: WarBanners = _track(WarBanners.new()) as WarBanners
	for i: int in 5:
		banners.add_banner("Aviso %d" % i, Color.WHITE)
	assert_eq(banners.get_banner_count(), WarBanners.MAX_BANNERS)
	assert_eq(banners.get_texts(), PackedStringArray(["Aviso 2", "Aviso 3", "Aviso 4"]))
	banners.add_banner("", Color.WHITE)
	assert_eq(banners.get_banner_count(), 3, "un texto vacío no cuenta")
	# Fundido final.
	banners.advance(WarBanners.NORMAL_SECONDS - 0.5)
	var label: Label = banners.get_child(0).get_child(banners.get_child(0).get_child_count() - 1) as Label
	assert_near(label.modulate.a, 0.5, 1e-6, "en el último segundo se desvanece")


func test_banners_follow_the_clients_war_events() -> void:
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	var banners: WarBanners = _track(WarBanners.new()) as WarBanners
	banners.bind(client, null)
	client.war_event.emit(NetMessages.EntityEvent.war(NET_ID, 10, WarEvents.GATE_BROKEN, ASKARRA))
	assert_eq(banners.get_banner_count(), 1)
	assert_eq(banners.get_texts()[0], "¡Askarra ha derribado la puerta del Fuerte!", "sin vista, el nombre por defecto")
	banners.bind(null, null)
	client.war_event.emit(NetMessages.EntityEvent.war(NET_ID, 10, WarEvents.GATE_BROKEN, ASKARRA))
	assert_eq(banners.get_banner_count(), 1, "al desvincular deja de escuchar")


# --- Barra de jefe ----------------------------------------------------------------------------

func test_boss_ids_follow_the_alphabetical_order_of_the_npc_files() -> void:
	var ids: PackedStringArray = BossInfo.ids_in_order(PackedStringArray(
			["hollow.tres", "ford_captain.tres", "readme.txt", "gate_guardian.tres"]))
	assert_eq(ids, PackedStringArray(["ford_captain", "gate_guardian", "hollow"]),
			"ford_captain = 1, gate_guardian = 2, hollow = 3")
	assert_false(BossInfo.is_boss(0), "el id 0 es «sin definición»")
	assert_false(BossInfo.is_boss(1), "y sin carpeta de PNJ no hay jefes")
	BossInfo.resolver = func(npc_def_id: int) -> Dictionary:
		return {"is_boss": npc_def_id == 1, "name": "x"}
	assert_true(BossInfo.is_boss(1), "con un resolutor manda él")
	assert_false(BossInfo.is_boss(2))


func test_the_boss_bar_follows_the_nearest_living_boss_in_range() -> void:
	BossInfo.resolver = func(npc_def_id: int) -> Dictionary:
		return {"is_boss": npc_def_id == 1, "name": "jefe"} if npc_def_id > 0 else {}
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	client.get_remote_world().install_visuals = false
	var character: PlayerCharacter = _track((load(CHARACTER_SCENE_PATH) as PackedScene).instantiate(), _root) as PlayerCharacter
	character.global_position = Vector3(0.0, 0.0, 0.0)
	client.fake_character = character
	var bar: BossBar = _track(BossBar.new()) as BossBar
	bar.bind(client)
	bar.refresh()
	assert_false(bar.visible, "sin jefes cerca no hay barra")
	client.get_remote_world().on_spawn(_npc_spawn(31, "Capitán del Vado", 1, Vector3(20.0, 0.0, 0.0)))
	client.get_remote_world().on_spawn(_npc_spawn(32, "Hueco", 3, Vector3(5.0, 0.0, 0.0)))
	client.get_remote_world().on_spawn(_npc_spawn(33, "Otro jefe lejano", 1, Vector3(300.0, 0.0, 0.0)))
	client.get_remote_world().draw(200.0, 0.016)
	bar.refresh()
	assert_true(bar.visible, "con el Capitán a 20 m, barra")
	assert_eq(bar.get_shown_id(), 31, "el Hueco no es jefe y el otro está lejos")
	assert_eq(bar.get_boss_name(), "Capitán del Vado")
	assert_near(bar.get_health_fraction(), 1.0, 1e-9)
	# Pierde vida: llega un registro con la mitad.
	var record := EntityRecord.new()
	record.net_id = 31
	record.kind = NetProtocol.EntityKind.NPC
	record.position = Vector3(20.0, 0.0, 0.0)
	record.health_q = 128
	var view: RemotePlayerView = client.get_remote_world().get_view(31)
	view.push(210, record)
	client.get_remote_world().draw(210.0, 0.016)
	bar.refresh()
	assert_near(bar.get_health_fraction(), EntityRecord.health_fraction(128), 1e-6, "la vida del registro dibujado")
	# Muere: la barra se va.
	record.health_q = EntityRecord.HEALTH_Q_DEAD
	view.push(220, record)
	client.get_remote_world().draw(220.0, 0.016)
	bar.refresh()
	assert_false(bar.visible, "muerto, sin barra")
	assert_eq(bar.get_shown_id(), 0)


func _npc_spawn(net_id: int, display_name: String, npc_def_id: int, position: Vector3) -> NetMessages.EntitySpawn:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = NetProtocol.EntityKind.NPC
	spawn.spawn_tick = 100
	spawn.display_name = display_name
	spawn.npc_def_id = npc_def_id
	spawn.state = PlayerState.new()
	spawn.state.position = position
	return spawn


# --- Marcas de los ataques --------------------------------------------------------------------

func test_a_circle_telegraph_marks_the_ground_and_fills_until_the_impact() -> void:
	var marks: TelegraphMarks = _track(TelegraphMarks.new()) as TelegraphMarks
	var event: NetMessages.EntityEvent = NetMessages.EntityEvent.telegraph(901, 10, 3,
			NetMessages.EntityEvent.SHAPE_CIRCLE, Vector3(4.0, 2.0, -6.0), 0.5, 350, 60)
	assert_true(marks.add_telegraph(event))
	assert_eq(marks.get_mark_count(), 1)
	assert_eq(marks.get_mark_npc(0), 901)
	var node: Node3D = marks.get_mark_node(0)
	assert_vec_near(node.global_position, Vector3(4.0, 2.0 + TelegraphMarks.LIFT, -6.0), 1e-5, "en el origen del aviso")
	assert_near(node.rotation.y, 0.5, 1e-6, "con su orientación")
	var zone: MeshInstance3D = node.get_node(^"Zona") as MeshInstance3D
	var aabb: AABB = zone.mesh.get_aabb()
	assert_near(aabb.size.x, 7.0, 0.05, "un círculo de 3,5 m de radio")
	assert_near(aabb.size.z, 7.0, 0.05)
	assert_near(marks.get_mark_fill(0), 0.001, 1e-6, "al empezar el relleno es casi nada")
	marks.advance(0.5)
	assert_near(marks.get_mark_fill(0), 0.5, 1e-6, "a medio camino del impacto (60 ticks = 1 s), la mitad")
	marks.advance(0.5)
	assert_near(marks.get_mark_fill(0), 1.0, 1e-6, "y lleno en el impacto")
	marks.advance(TelegraphMarks.TAIL_SECONDS * 0.5)
	assert_eq(marks.get_mark_count(), 1, "se queda un instante tras el golpe")
	marks.advance(TelegraphMarks.TAIL_SECONDS)
	assert_eq(marks.get_mark_count(), 0, "y se quita")
	assert_eq(marks.get_child_count(), 0, "sin dejar nodos")


func test_a_sector_telegraph_uses_the_attack_angle_and_points_forward() -> void:
	var marks: TelegraphMarks = _track(TelegraphMarks.new()) as TelegraphMarks
	var known_id: int = CombatCatalog.attack_id(&"sword_light_1")
	assert_true(known_id > 0, "la prueba usa un ataque del catálogo")
	var degrees: float = TelegraphMarks.sector_degrees(known_id)
	assert_true(degrees > 0.0 and degrees < 360.0)
	assert_eq(TelegraphMarks.sector_degrees(60000), TelegraphMarks.DEFAULT_SECTOR_DEGREES, "un ataque desconocido, el ángulo por defecto")
	marks.add_telegraph(NetMessages.EntityEvent.telegraph(902, 10, known_id,
			NetMessages.EntityEvent.SHAPE_SECTOR, Vector3.ZERO, 0.0, 400, 30))
	var mesh: ArrayMesh = (marks.get_mark_node(0).get_node(^"Zona") as MeshInstance3D).mesh as ArrayMesh
	var aabb: AABB = mesh.get_aabb()
	assert_true(aabb.position.z < -3.9 and aabb.end.z <= 0.01, "el sector se extiende hacia -Z (delante con yaw 0)")
	var half: float = deg_to_rad(degrees) * 0.5
	var expected_width: float = 2.0 * 4.0 * sin(minf(half, PI * 0.5))
	assert_near(aabb.size.x, expected_width, 0.1, "y su anchura sale del ángulo del ataque")
	# Con el yaw del aviso gira entero.
	marks.add_telegraph(NetMessages.EntityEvent.telegraph(903, 10, known_id,
			NetMessages.EntityEvent.SHAPE_SECTOR, Vector3.ZERO, PI * 0.5, 400, 30))
	assert_near(marks.get_mark_node(1).rotation.y, PI * 0.5, 1e-6)


func test_telegraphs_with_no_radius_or_unknown_shape_draw_nothing_and_the_pool_is_capped() -> void:
	var marks: TelegraphMarks = _track(TelegraphMarks.new()) as TelegraphMarks
	assert_false(marks.add_telegraph(null))
	assert_false(marks.add_telegraph(NetMessages.EntityEvent.hit(1, 1, 2, 10, 0, 0, 1)), "solo los TELEGRAPH")
	assert_false(marks.add_telegraph(NetMessages.EntityEvent.telegraph(1, 10, 3,
			NetMessages.EntityEvent.SHAPE_CIRCLE, Vector3.ZERO, 0.0, 0, 30)), "radio 0")
	var odd: NetMessages.EntityEvent = NetMessages.EntityEvent.telegraph(1, 10, 3, 5, Vector3.ZERO, 0.0, 300, 30)
	assert_false(marks.add_telegraph(odd), "forma desconocida")
	for i: int in TelegraphMarks.MAX_MARKS + 6:
		marks.add_telegraph(NetMessages.EntityEvent.telegraph(i + 1, 10, 3,
				NetMessages.EntityEvent.SHAPE_CIRCLE, Vector3(float(i), 0.0, 0.0), 0.0, 300, 600))
	assert_eq(marks.get_mark_count(), TelegraphMarks.MAX_MARKS, "hay un tope")
	assert_eq(marks.get_child_count(), TelegraphMarks.MAX_MARKS, "y los nodos de las marcas viejas se liberan")
	assert_eq(marks.get_mark_npc(0), 7, "se quitan las más antiguas")
	marks.clear()
	assert_eq(marks.get_child_count(), 0)


func test_marks_listen_to_the_clients_telegraphs() -> void:
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	var marks: TelegraphMarks = _track(TelegraphMarks.new()) as TelegraphMarks
	marks.bind(client)
	client.telegraph_received.emit(NetMessages.EntityEvent.telegraph(901, 10, 3,
			NetMessages.EntityEvent.SHAPE_CIRCLE, Vector3.ZERO, 0.0, 300, 30))
	assert_eq(marks.get_mark_count(), 1)
	_root.remove_child(marks)
	assert_false(client.telegraph_received.is_connected(marks.add_telegraph), "al salir del árbol deja de escuchar")
	_root.add_child(marks)


func test_mesh_builder_makes_a_fan_with_the_right_triangles() -> void:
	var circle: ArrayMesh = TelegraphMarks.build_mesh(2.0, TAU, 16)
	var arrays: Array = circle.surface_get_arrays(0)
	assert_eq((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size(), 16 * 3, "16 triángulos")
	assert_eq((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 17 + 1, "origen más 17 vértices de borde")
	var quarter: ArrayMesh = TelegraphMarks.build_mesh(2.0, PI * 0.5, 16)
	assert_eq((quarter.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size(), 4 * 3, "un cuarto: 4 triángulos")
	assert_near(TelegraphMarks.fill_progress(0.25, 1.0), 0.25, 1e-9)
	assert_eq(TelegraphMarks.fill_progress(5.0, 1.0), 1.0)
	assert_eq(TelegraphMarks.fill_progress(0.0, 0.0), 1.0, "un aviso sin demora está lleno")


# --- Montaje en el HUD ------------------------------------------------------------------------

func test_the_hud_mounts_the_war_interface_under_the_death_screen() -> void:
	var world: Node3D = _track(Node3D.new()) as Node3D
	var character: PlayerCharacter = _track((load(CHARACTER_SCENE_PATH) as PackedScene).instantiate(), world) as PlayerCharacter
	var rig: CameraRig = (load("res://scenes/client/camera_rig.tscn") as PackedScene).instantiate() as CameraRig
	rig.set_scripted_look(false)
	_track(rig)
	var hud: HUD = _track((load(HUD_SCENE_PATH) as PackedScene).instantiate()) as HUD
	hud.bind(character, rig)
	assert_null(hud.get_war_hud(), "el sandbox no tiene interfaz de guerra")
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	client.fake_config.realm = VARDHEIM
	client.fake_character = character
	hud.bind_net(client, world)
	var war: WarHud = hud.get_war_hud()
	if not assert_not_null(war, "con red, sí"):
		return
	assert_not_null(war.get_capture_panel())
	assert_not_null(war.get_banners())
	assert_not_null(war.get_boss_bar())
	assert_not_null(war.get_telegraph_marks())
	assert_eq(war.get_telegraph_marks().get_parent(), world, "las marcas cuelgan de la zona")
	assert_true(war.get_index() < hud.get_death_screen().get_index(), "por debajo de la pantalla de muerte")
	# Un aviso del cliente sale como banner y un TELEGRAPH como marca.
	client.war_event.emit(NetMessages.EntityEvent.war(NET_ID, 10, WarEvents.FORT_CAPTURED, SOLMARCH))
	assert_eq(war.get_banners().get_banner_count(), 1)
	client.telegraph_received.emit(NetMessages.EntityEvent.telegraph(901, 10, 3,
			NetMessages.EntityEvent.SHAPE_CIRCLE, Vector3.ZERO, 0.0, 300, 30))
	assert_eq(war.get_telegraph_marks().get_mark_count(), 1)
	# Una segunda llamada a bind_net rehace la interfaz sin duplicarla.
	hud.bind_net(client, world)
	assert_eq(hud.get_children().filter(func(child: Node) -> bool: return child is WarHud).size(), 1)
	assert_eq(world.get_children().filter(func(child: Node) -> bool: return child is TelegraphMarks).size(), 1,
			"ni las marcas del mundo")
	# Quitar el HUD no deja marcas en la zona.
	_nodes.erase(hud)
	hud.get_parent().remove_child(hud)
	hud.free()
	assert_eq(world.get_children().filter(func(child: Node) -> bool: return child is TelegraphMarks).size(), 0)
