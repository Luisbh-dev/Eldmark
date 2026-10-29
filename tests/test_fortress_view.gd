extends TestCase
## Pruebas de la vista del fuerte en el cliente (docs/fuerte.md, secciones 2 y 3.2; paquete F5):
## [FortressTimeline] (historia de cambios, tick de validez, fórmula del progreso) y [FortressView]
## (interfaz y estandartes en el tick de dibujo, capas de la puerta por tick simulado). Los mensajes
## son sintéticos: el cliente no necesita un servidor para esto.

const FORT_SCENE_PATH: String = "res://scenes/world/props/fort/vado_gris_fort.tscn"
const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const FORTRESS_ID: String = "vado_gris_fort"
const NET_ID: int = 900
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA

var _def: FortressDefinition = null
var _zone: Node3D = null
var _fort: Node3D = null
var _view: FortressView = null


func before_each() -> void:
	_def = load(DEFINITION_PATH) as FortressDefinition


func after_each() -> void:
	for node: Node in [_view, _zone]:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.queue_free()
	_view = null
	_zone = null
	_fort = null
	await wait_process_frames()


# --- FortressTimeline -------------------------------------------------------------------------

func test_a_state_is_valid_after_the_tick_of_its_message() -> void:
	var timeline := FortressTimeline.new(_def)
	assert_false(timeline.has_state(), "sin mensajes no hay estado")
	assert_eq(timeline.state_at(500).owner, 0, "y el estado por defecto es el neutral")
	timeline.apply_object_state(_spawn_message(100))
	timeline.apply_object_state(_change(200, {FortressFields.OWNER: VARDHEIM}))
	timeline.apply_object_state(_change(300, {FortressFields.OWNER: SOLMARCH}))
	assert_eq(timeline.get_entry_count(), 3)
	assert_eq(timeline.state_at(100).owner, 0, "tras el tick del SPAWN, el estado del SPAWN")
	assert_eq(timeline.state_at(199).owner, 0, "hasta el tick anterior al cambio, el viejo")
	assert_eq(timeline.state_at(200).owner, VARDHEIM, "tras el tick del cambio, el nuevo")
	assert_eq(timeline.state_at(299).owner, VARDHEIM)
	assert_eq(timeline.state_at(300).owner, SOLMARCH)
	assert_eq(timeline.state_at(99999).owner, SOLMARCH, "después del último, el último")
	assert_eq(timeline.state_at(10).owner, 0, "antes del primero se asume el primero (el SPAWN es completo)")
	assert_eq(timeline.change_tick_at(250), 200)
	assert_eq(timeline.get_latest_tick(), 300)


func test_a_change_sticks_to_the_fields_it_carried() -> void:
	var timeline := FortressTimeline.new(_def)
	var full: FortressState = _state_with({FortressFields.GATE_HEALTH: 4000, FortressFields.PHASE: 1})
	timeline.apply_object_state(NetMessages.ObjectState.from_fortress(NET_ID, 100, full))
	timeline.apply_object_state(_change(160, {FortressFields.OWNER: SOLMARCH}))
	var later: FortressState = timeline.state_at(200)
	assert_eq(later.owner, SOLMARCH, "el campo que cambió")
	assert_eq(later.gate_health, 4000, "los demás siguen como estaban")
	assert_eq(later.phase, 1)
	assert_eq(timeline.state_at(150).owner, 0, "y el estado anterior no se toca")


func test_gate_layers_change_from_the_tick_after_the_change() -> void:
	var timeline := FortressTimeline.new(_def)
	timeline.apply_object_state(_spawn_message(50))
	timeline.apply_object_state(_change(100, {FortressFields.OWNER: VARDHEIM}))
	timeline.apply_object_state(_change(200, {FortressFields.GATE_HEALTH: 0}))
	timeline.apply_object_state(_change(300, {FortressFields.GATE_HEALTH: 9000}))
	var neutral: int = FortGate.layers_for(0, false)
	var vardheim: int = FortGate.layers_for(VARDHEIM, false)
	assert_true(neutral != vardheim, "la prueba distingue las dos puertas")
	assert_eq(timeline.gate_layers_for_tick(100), neutral, "el tick 100 se simula aún con la puerta neutral")
	assert_eq(timeline.gate_layers_for_tick(101), vardheim, "y el 101 ya con la del nuevo dueño")
	assert_eq(timeline.gate_layers_for_tick(200), vardheim, "el tick 200 todavía con la puerta entera")
	assert_eq(timeline.gate_layers_for_tick(201), 0, "rota desde el 201: sin capas")
	assert_eq(timeline.gate_layers_for_tick(300), 0, "reparada, pero no hasta el siguiente tick")
	assert_eq(timeline.gate_layers_for_tick(301), vardheim, "el 301 vuelve a cerrar para los enemigos")
	assert_eq(timeline.gate_layers_for_tick(1), neutral, "y antes de todo, la del primer estado conocido")


func test_unknown_fields_and_wrong_types_are_skipped() -> void:
	var timeline := FortressTimeline.new(_def)
	var changes := NetMessages.ObjectState.new()
	changes.net_id = NET_ID
	changes.tick = 100
	changes.add_field(250, NetMessages.ObjectField.ValueType.U16, 7)
	changes.add_field(FortressFields.OWNER, NetMessages.ObjectField.ValueType.U32, 2)
	assert_eq(timeline.apply_object_state(changes), 0, "ni un id desconocido ni un tipo equivocado cuentan")
	assert_false(timeline.has_state(), "y si no se aplica nada no se anota nada")
	changes.add_field(FortressFields.GATE_HEALTH, NetMessages.ObjectField.ValueType.U32, 1234)
	assert_eq(timeline.apply_object_state(changes), 1, "solo el campo bueno")
	assert_eq(timeline.state_at(100).gate_health, 1234)
	assert_eq(timeline.state_at(100).owner, 0, "el de tipo equivocado no se aplicó")
	assert_eq(timeline.apply_object_state(null), 0)


func test_a_message_out_of_order_is_inserted_and_the_next_states_are_rebuilt() -> void:
	var timeline := FortressTimeline.new(_def)
	timeline.apply_object_state(_spawn_message(100))
	timeline.apply_object_state(_change(300, {FortressFields.GATE_HEALTH: 100}))
	# Llega tarde un cambio del tick 200: el de 300 tiene que verlo.
	timeline.apply_object_state(_change(200, {FortressFields.OWNER: SOLMARCH}))
	assert_eq(timeline.get_entry_count(), 3)
	assert_eq(timeline.state_at(250).owner, SOLMARCH)
	assert_eq(timeline.state_at(250).gate_health, 9000, "en 250 la puerta sigue entera")
	assert_eq(timeline.state_at(300).owner, SOLMARCH, "el cambio de 300 hereda el dueño del de 200")
	assert_eq(timeline.state_at(300).gate_health, 100)
	# Dos mensajes con el mismo tick se acumulan en el orden en que llegaron.
	timeline.apply_object_state(_change(300, {FortressFields.GATE_HEALTH: 50}))
	assert_eq(timeline.state_at(300).gate_health, 50)
	assert_eq(timeline.state_at(300).owner, SOLMARCH)


func test_old_changes_are_pruned_but_a_base_stays() -> void:
	var timeline := FortressTimeline.new(_def)
	timeline.apply_object_state(_spawn_message(0))
	timeline.apply_object_state(_change(10, {FortressFields.OWNER: VARDHEIM}))
	for i: int in 700:
		timeline.apply_object_state(_change(20 + i * 6, {FortressFields.GATE_HEALTH: 8000 - i}))
	assert_true(timeline.get_entry_count() <= FortressTimeline.MAX_ENTRIES, "hay un tope de cambios")
	assert_true(timeline.get_oldest_tick() > 10, "lo más viejo se podó")
	assert_eq(timeline.state_at(timeline.get_oldest_tick()).owner, VARDHEIM,
			"la base conserva lo acumulado (el dueño del cambio podado)")
	assert_eq(timeline.state_at(1).owner, VARDHEIM, "y una consulta anterior a la base da la base")
	var count: int = timeline.get_entry_count()
	assert_eq(timeline.apply_object_state(_change(5, {FortressFields.OWNER: SOLMARCH})), 0,
			"un mensaje anterior a la base podada se ignora")
	assert_eq(timeline.get_entry_count(), count)
	# La poda por tiempo: un cambio mucho más nuevo se lleva los viejos.
	timeline.apply_object_state(_change(100000, {FortressFields.OWNER: ASKARRA}))
	assert_eq(timeline.get_entry_count(), 2,
			"quedan el cambio nuevo y, de base, el último anterior a los últimos %d ticks"
			% FortressTimeline.RETAIN_TICKS)
	assert_eq(timeline.state_at(99999).owner, VARDHEIM, "la base sigue valiendo hasta el cambio nuevo")
	assert_eq(timeline.state_at(100001).owner, ASKARRA)


func test_progress_follows_the_capture_formula() -> void:
	var timeline := FortressTimeline.new(_def)
	var maximum: int = FortressState.initial(_def, 0).progress_max
	assert_eq(maximum, 21600, "30 s de captura: 1800 ticks · 12")
	timeline.apply_object_state(_spawn_message(50))
	assert_eq(timeline.progress_at(60.0), 0, "sin captura el progreso es 0")
	# Un atacante: 12 por tick desde el 100.
	timeline.apply_object_state(_change(100, {FortressFields.PHASE: FortressState.Phase.CAPTURING,
			FortressFields.CAPTURE_REALM: VARDHEIM, FortressFields.CAPTURE_START_TICK: 100,
			FortressFields.CAPTURE_RATE: 12, FortressFields.CAPTURE_PROGRESS_AT_START: 0}))
	assert_eq(timeline.progress_at(100.0), 0)
	assert_eq(timeline.progress_at(160.0), 720, "60 ticks · 12")
	assert_eq(timeline.progress_at(160.5), 726, "con fracción de tick")
	assert_eq(timeline.progress_at(100.0 + 1799.0), 21588)
	assert_eq(timeline.progress_at(100.0 + 1800.0), maximum, "a los 30 s, el máximo")
	assert_eq(timeline.progress_at(100.0 + 5000.0), maximum, "y no pasa de ahí")
	assert_near(timeline.progress_fraction_at(160.0), 720.0 / 21600.0, 1e-9)
	# Se disputa en el 300 (el progreso en ese tick pasa a ser el ancla) y se congela.
	timeline.apply_object_state(_change(300, {FortressFields.CAPTURE_START_TICK: 300,
			FortressFields.CAPTURE_RATE: 0, FortressFields.CAPTURE_PROGRESS_AT_START: 2400,
			FortressFields.CONTESTED: 1}))
	assert_eq(timeline.progress_at(299.0), 2388, "antes del 300 sigue la fórmula vieja")
	assert_eq(timeline.progress_at(300.0), 2400)
	assert_eq(timeline.progress_at(900.0), 2400, "congelado")
	# Decae despacio (−4 por tick) y llega a 0 sin pasar de ahí.
	timeline.apply_object_state(_change(1000, {FortressFields.CAPTURE_START_TICK: 1000,
			FortressFields.CAPTURE_RATE: -4}))
	assert_eq(timeline.progress_at(1100.0), 2000, "−4 por tick durante 100 ticks")
	assert_eq(timeline.progress_at(5000.0), 0, "el progreso no baja de 0")


# --- FortressView: interfaz en el tick de dibujo ----------------------------------------------

func test_the_view_applies_a_state_when_the_render_tick_reaches_it() -> void:
	await _build_view()
	var changes: Array[Dictionary] = []
	_view.state_changed.connect(func(net_id: int, state: FortressState, previous: FortressState) -> void:
		changes.append({"net_id": net_id, "owner": state.owner, "had_previous": previous != null}))
	_view.on_spawn(_spawn_for_fortress(100))
	assert_true(_view.has_fortress(NET_ID), "el SPAWN crea la fortaleza")
	assert_true(_view.is_bound(NET_ID), "y la enlaza con el nodo de la escena")
	assert_null(_view.get_displayed_state(NET_ID), "aún no se ha dibujado ningún tick")
	_view.advance(0.0)
	assert_null(_view.get_displayed_state(NET_ID), "con el reloj sin arrancar no se aplica nada")
	_view.advance(100.0)
	assert_eq(_view.get_displayed_state(NET_ID).owner, 0, "con el SPAWN en pantalla")
	assert_eq(changes.size(), 1, "la primera vez se emite el estado")
	assert_false(changes[0]["had_previous"])
	# Llega un cambio del tick 160: no se ve hasta que el tick de dibujo lo alcanza.
	assert_true(_view.on_object_state(_change(160, {FortressFields.OWNER: VARDHEIM,
			FortressFields.PHASE: FortressState.Phase.CONSOLIDATING})))
	assert_eq(_view.get_latest_state(NET_ID).owner, VARDHEIM, "lo último conocido ya es el nuevo")
	_view.advance(130.0)
	_view.advance(159.9)
	assert_eq(_view.get_displayed_state(NET_ID).owner, 0, "en 159,9 se sigue viendo el viejo")
	assert_eq(changes.size(), 1, "y no hay señal")
	_view.advance(160.0)
	assert_eq(_view.get_displayed_state(NET_ID).owner, VARDHEIM, "en 160 se aplica")
	assert_eq(changes.size(), 2, "con una señal")
	assert_true(changes[1]["had_previous"])
	_view.advance(161.0)
	_view.advance(400.0)
	assert_eq(changes.size(), 2, "sin cambios nuevos no se repite la señal")


func test_banners_take_the_owner_color_in_the_draw_tick() -> void:
	await _build_view()
	var neutral_color: Color = RealmCatalog.color_of(RealmCatalog.HUECOS)
	_view.on_spawn(_spawn_for_fortress(100))
	assert_true(_view.get_banners(NET_ID).size() >= 3, "estandarte de la torre y los dos de la puerta (%d)"
			% _view.get_banners(NET_ID).size())
	_view.advance(100.0)
	assert_true(_view.has_banner_color(NET_ID))
	assert_true(_banner_colors_are(neutral_color), "neutral: gris hueso de los Huecos")
	_view.on_object_state(_change(200, {FortressFields.OWNER: VARDHEIM}))
	_view.advance(199.0)
	assert_true(_banner_colors_are(neutral_color), "antes del tick 200 los estandartes siguen neutrales")
	_view.advance(200.0)
	assert_true(_banner_colors_are(RealmCatalog.color_of(RealmCatalog.VARDHEIM)),
			"en el 200 pasan al azul de Vardheim (faction_color)")
	assert_eq(_view.get_banner_color(NET_ID), RealmCatalog.color_of(RealmCatalog.VARDHEIM))
	_view.on_object_state(_change(300, {FortressFields.OWNER: SOLMARCH}))
	_view.advance(300.0)
	assert_true(_banner_colors_are(RealmCatalog.color_of(RealmCatalog.SOLMARCH)), "y luego al oro de Solmarch")
	_view.on_object_state(_change(400, {FortressFields.OWNER: 0}))
	_view.advance(400.0)
	assert_true(_banner_colors_are(neutral_color), "y de nuevo neutral tras un reinicio")


func test_the_gate_pose_follows_the_draw_tick_and_the_movement_layers_follow_the_hook() -> void:
	await _build_view()
	var gate: FortGate = _view.get_gate(NET_ID)
	if not assert_null(gate, "antes del SPAWN la vista no conoce la puerta"):
		return
	_view.on_spawn(_spawn_for_fortress(100))
	gate = _view.get_gate(NET_ID)
	if not assert_not_null(gate, "con el SPAWN enlaza la puerta de la escena"):
		return
	_view.on_object_state(_change(200, {FortressFields.OWNER: VARDHEIM}))
	_view.on_object_state(_change(300, {FortressFields.GATE_HEALTH: 0}))
	var neutral: int = FortGate.layers_for(0, false)
	var vardheim: int = FortGate.layers_for(VARDHEIM, false)
	# La predicción va por delante del dibujo: simula el tick 250 mientras se dibuja el 150.
	_view.advance(150.0)
	_view.before_simulate(250)
	assert_eq(gate.collision_layer, vardheim, "la colisión es la del tick simulado (250), no la del dibujo")
	assert_eq(gate.get_owner_realm(), 0, "mientras la pose sigue la del tick de dibujo (150)")
	assert_false(gate.is_broken())
	# Al dibujar el 200 cambia la pose, pero la colisión que puso la predicción no se pisa.
	_view.advance(200.0)
	assert_eq(gate.get_owner_realm(), VARDHEIM, "la pose pasa a la del dueño nuevo")
	assert_eq(gate.collision_layer, vardheim, "y la colisión sigue siendo la del último tick simulado")
	# El gancho también va hacia atrás (repeticiones de la reconciliación).
	_view.before_simulate(150)
	assert_eq(gate.collision_layer, neutral, "simulando el 150 la puerta era neutral")
	_view.before_simulate(301)
	assert_eq(gate.collision_layer, 0, "y desde el 301 está rota: sin capas")
	_view.advance(300.0)
	assert_true(gate.is_broken(), "al dibujar el 300 las hojas cuelgan")
	assert_eq(gate.collision_layer, 0, "sin tocar la colisión del tick simulado")
	assert_eq(_view.get_gate_movement_layers(NET_ID), 0)
	assert_true(int(_view.get_stats()["hook_calls"]) == 3, "tres llamadas al gancho")


func test_a_view_that_finds_its_scene_late_binds_and_paints_then() -> void:
	await _build_view(false)
	_view.on_spawn(_spawn_for_fortress(100))
	_view.on_object_state(_change(150, {FortressFields.OWNER: SOLMARCH}))
	assert_false(_view.is_bound(NET_ID), "sin zona cargada no hay nodo")
	_view.before_simulate(200)
	_view.advance(160.0)
	assert_eq(_view.get_displayed_state(NET_ID).owner, SOLMARCH, "el estado se sigue guardando y mostrando")
	assert_false(_view.has_banner_color(NET_ID) and _view.is_bound(NET_ID))
	# Aparece la zona (se carga después del SPAWN).
	_add_zone()
	_view.set_zone(_zone)
	assert_true(_view.is_bound(NET_ID), "al darle la zona enlaza")
	assert_true(_banner_colors_are(RealmCatalog.color_of(RealmCatalog.SOLMARCH)),
			"y pinta lo que ya se estaba mostrando")
	assert_eq(_view.get_gate(NET_ID).get_owner_realm(), SOLMARCH, "también la puerta")
	_view.before_simulate(200)
	assert_eq(_view.get_gate(NET_ID).collision_layer, FortGate.layers_for(SOLMARCH, false))


func test_the_group_and_metadata_names_match_the_zone_registry() -> void:
	# El código de red no nombra Zones: FortressView repite estos nombres y aquí se comprueba que son los mismos.
	assert_eq(FortressView.FORTRESS_GROUP, Zones.FORTRESS_GROUP)
	assert_eq(FortressView.DEFINITION_META, Zones.FORTRESS_DEFINITION_META)
	assert_eq(RespawnPointList.GROUP, Zones.RESPAWN_GROUP)


func test_scene_geometry_is_available_for_the_hud() -> void:
	await _build_view()
	assert_eq(_view.get_circle_center(NET_ID), Vector3.INF, "sin SPAWN no hay nada que consultar")
	_view.on_spawn(_spawn_for_fortress(100))
	assert_near(_view.get_circle_radius(NET_ID), 5.0, 1e-6, "el radio sale del marcador, 5 m")
	var circle: Node3D = _fort.get_node(^"CaptureCircle") as Node3D
	assert_vec_near(_view.get_circle_center(NET_ID), circle.global_position, 1e-6)
	assert_vec_near(_view.get_gate_position(NET_ID), _fort.get_node(^"FortGate").global_position, 1e-6)
	assert_vec_near(_view.get_anchor_position(NET_ID), _fort.global_position, 1e-6)
	assert_eq(String(_view.get_definition_id(NET_ID)), FORTRESS_ID)
	assert_eq(_view.get_definition(NET_ID).id, &"vado_gris_fort", "la definición sale del metadato de la escena")
	assert_eq(_view.get_primary_id(), NET_ID)


func test_unknown_structures_and_empty_messages_are_ignored() -> void:
	await _build_view()
	assert_false(_view.on_object_state(_change(100, {FortressFields.OWNER: VARDHEIM})),
			"un OBJECT_STATE de una fortaleza que no se conoce se descarta")
	assert_eq(_view.get_stats()["ignored_states"], 1, "y se cuenta")
	assert_false(_view.on_spawn(null))
	var player := NetMessages.EntitySpawn.new()
	player.kind = NetProtocol.EntityKind.PLAYER
	assert_false(_view.on_spawn(player), "solo las estructuras")
	_view.on_spawn(_spawn_for_fortress(100))
	var unknown_only := NetMessages.ObjectState.new()
	unknown_only.net_id = NET_ID
	unknown_only.tick = 120
	unknown_only.add_field(99, NetMessages.ObjectField.ValueType.U8, 1)
	assert_false(_view.on_object_state(unknown_only), "un mensaje con solo campos desconocidos no cambia nada")
	assert_eq(_view.get_timeline(NET_ID).get_entry_count(), 1)
	# Un segundo SPAWN de la misma estructura (salir de interés y volver) es un cambio más.
	assert_true(_view.on_spawn(_spawn_for_fortress(500, {FortressFields.OWNER: ASKARRA})))
	assert_eq(_view.get_fortress_ids().size(), 1)
	assert_eq(_view.get_latest_state(NET_ID).owner, ASKARRA)
	assert_eq(_view.get_progress(NET_ID + 1, 100.0), 0, "una fortaleza desconocida no tiene progreso")


func test_the_view_loads_the_definition_without_a_scene() -> void:
	await _build_view(false)
	_view.on_spawn(_spawn_for_fortress(100))
	var definition: FortressDefinition = _view.get_definition(NET_ID)
	if not assert_not_null(definition):
		return
	assert_eq(definition.id, &"vado_gris_fort", "sin escena, la definición sale de data/fortresses por su id")
	assert_eq(_view.get_timeline(NET_ID).state_at(100).progress_max, 21600, "con sus tiempos")
	_view.on_object_state(_change(100, {FortressFields.CAPTURE_REALM: VARDHEIM, FortressFields.CAPTURE_RATE: 12,
			FortressFields.CAPTURE_START_TICK: 100, FortressFields.PHASE: FortressState.Phase.CAPTURING}))
	assert_eq(_view.get_progress(NET_ID, 160.0), 720)
	assert_near(_view.get_progress_fraction(NET_ID, 100.0 + 900.0), 0.5, 1e-9, "a mitad de la captura")


func test_states_by_definition_feed_the_respawn_rules() -> void:
	await _build_view()
	_view.on_spawn(_spawn_for_fortress(100, {FortressFields.OWNER: VARDHEIM}))
	_view.on_object_state(_change(300, {FortressFields.UNDER_ATTACK_UNTIL_TICK: 2000}))
	var states: Dictionary = _view.get_states_by_definition(200)
	assert_true(states.has(&"vado_gris_fort"), "la clave es el id de la definición")
	# La zona de la prueba solo tiene la fortaleza: los puntos del interior del fuerte los pone la prueba.
	var points: Array[Node3D] = _fort_points()
	var valid: PackedInt32Array = RespawnRules.points_for(VARDHEIM, points, states, 200)
	assert_eq(valid.size(), 4, "con el fuerte de Vardheim en reposo valen sus cuatro puntos")
	var attacked: PackedInt32Array = RespawnRules.points_for(VARDHEIM, points, _view.get_states_by_definition(400), 400)
	assert_eq(attacked.size(), 0, "«atacado» hasta el tick 2000: ninguno")
	assert_eq(RespawnRules.points_for(SOLMARCH, points, states, 200).size(), 0, "y a Solmarch nunca")


# --- Ayudantes --------------------------------------------------------------------------------

# Una zona con el fuerte (como lo deja el generador: grupo y metadato de la definición) y una vista.
func _build_view(with_zone: bool = true) -> void:
	_view = FortressView.new()
	tree.root.add_child(_view)
	if with_zone:
		_add_zone()
		_view.set_zone(_zone)
	await wait_physics_frames(2)


func _add_zone() -> void:
	_zone = Node3D.new()
	_zone.name = "ZonaDePrueba"
	tree.root.add_child(_zone)
	var scene: PackedScene = load(FORT_SCENE_PATH) as PackedScene
	_fort = scene.instantiate() as Node3D
	_fort.name = "Fuerte"
	_fort.add_to_group(Zones.FORTRESS_GROUP)
	_fort.set_meta(Zones.FORTRESS_DEFINITION_META, DEFINITION_PATH)
	_zone.add_child(_fort)


# Cuatro marcadores como los del interior del fuerte (metadato fortress y sin reino).
func _fort_points() -> Array[Node3D]:
	var points: Array[Node3D] = []
	for i: int in 4:
		var point := Marker3D.new()
		point.set_meta(Zones.FORTRESS_META, &"vado_gris_fort")
		_zone.add_child(point)
		points.append(point)
	return points


func _state_with(values: Dictionary) -> FortressState:
	var state := FortressState.initial(_def, 0)
	for field_id: int in values:
		FortressFields.set_value(state, field_id, int(values[field_id]))
	return state


func _spawn_message(tick: int) -> NetMessages.ObjectState:
	return NetMessages.ObjectState.from_fortress(NET_ID, tick, FortressState.initial(_def, tick))


func _spawn_for_fortress(tick: int, values: Dictionary = {}) -> NetMessages.EntitySpawn:
	var state: FortressState = FortressState.initial(_def, tick)
	for field_id: int in values:
		FortressFields.set_value(state, field_id, int(values[field_id]))
	return NetMessages.EntitySpawn.decode(NetMessages.EntitySpawn.for_fortress(NET_ID, tick,
			FORTRESS_ID, state).encode())


# OBJECT_STATE (pasado por encode/decode) con solo los campos de [param values] (id -> valor).
func _change(tick: int, values: Dictionary) -> NetMessages.ObjectState:
	var message := NetMessages.ObjectState.new()
	message.net_id = NET_ID
	message.tick = tick
	for field_id: int in values:
		message.add_field(field_id, FortressFields.value_type(field_id), int(values[field_id]))
	return NetMessages.ObjectState.decode(message.encode())


func _banner_colors_are(expected: Color) -> bool:
	var banners: Array[MeshInstance3D] = _view.get_banners(NET_ID)
	if banners.is_empty():
		return false
	for mesh: MeshInstance3D in banners:
		var color: Variant = mesh.get("instance_shader_parameters/faction_color")
		if typeof(color) != TYPE_COLOR or not (color as Color).is_equal_approx(expected):
			return false
	return true
