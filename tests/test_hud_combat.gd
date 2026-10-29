extends TestCase
## Pruebas de la interfaz de combate (UI-10, UI-14) con estados falsos: las barras de vida y
## resistencia ([VitalsHud]: valores, fantasma, parpadeo, resistencia oculta llena), los arcos de
## dirección del daño ([DamageIndicator]: ángulo respecto a la cámara), la viñeta de vida baja, la
## pantalla de muerte ([DeathScreen]: cuenta atrás con el tick del servidor, botón, 10 ciclos sin
## restos) y la lista de puntos de reaparición ([RespawnPointList]). La última parte monta el [HUD]
## entero con un cliente de red falso que da la vida y el estado a voluntad.

const OWN_ID: int = 5
const OTHER_ID: int = 21
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"


## Cliente de red que no conecta con nada: da la vida, el estado y el tick del servidor que pide la
## prueba y apunta las peticiones de reaparición.
class FakeClient extends NetClient:
	var fake_has_health: bool = true
	var fake_health: int = 1000
	var fake_max_health: int = 1000
	var fake_dead: bool = false
	var fake_respawn_tick: int = 0
	var fake_estimated_tick: int = 0
	var fake_snapshot_tick: int = 1
	var fake_config: ClientConfig = ClientConfig.new()
	var respawn_requests: Array[int] = []

	func has_health() -> bool:
		return fake_has_health

	func get_health() -> int:
		return fake_health

	func get_max_health() -> int:
		return fake_max_health

	func is_dead() -> bool:
		return fake_dead

	func get_respawn_tick() -> int:
		return fake_respawn_tick

	func get_estimated_server_tick() -> int:
		return fake_estimated_tick

	func get_last_snapshot_tick() -> int:
		return fake_snapshot_tick

	func get_net_id() -> int:
		return OWN_ID

	func get_config() -> ClientConfig:
		return fake_config

	func send_respawn_request(point_index: int) -> bool:
		respawn_requests.append(point_index)
		return true


var _root: Node3D
var _nodes: Array[Node] = []


func before_each() -> void:
	_root = Node3D.new()
	_root.name = "HudCombatTest"
	tree.root.add_child(_root)


func after_each() -> void:
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


## Añade [param node] a la raíz de la prueba (o a [param parent]) y lo libera al acabar.
func _track(node: Node, parent: Node = null) -> Node:
	(parent if parent != null else _root).add_child(node)
	_nodes.append(node)
	return node


# --- Barras de vida y resistencia -------------------------------------------------------------

func test_health_bar_shows_the_values_and_hides_without_network() -> void:
	var vitals: VitalsHud = _track(VitalsHud.new()) as VitalsHud
	assert_true(vitals.is_health_visible(), "por defecto se ve")
	vitals.set_health(750, 1000)
	assert_eq(vitals.get_health(), 750)
	assert_eq(vitals.get_max_health(), 1000)
	assert_near(vitals.get_health_fraction(), 0.75, 0.0001)
	vitals.set_health(5000, 1000)
	assert_eq(vitals.get_health(), 1000, "no pasa de la máxima")
	vitals.set_health(-3, 1000)
	assert_eq(vitals.get_health(), 0, "ni baja de 0")
	vitals.set_health_visible(false)
	assert_false(vitals.is_health_visible(), "sin red la vida se oculta")


func test_health_ghost_holds_then_shrinks_to_the_current_value() -> void:
	var vitals: VitalsHud = _track(VitalsHud.new()) as VitalsHud
	vitals.snap_health(1000, 1000)
	vitals.set_health(600, 1000)
	assert_near(vitals.get_health_fraction(), 0.6, 0.0001)
	assert_near(vitals.get_ghost_fraction(), 1.0, 0.0001, "el fantasma conserva la pérdida")
	vitals.advance(VitalsHud.GHOST_HOLD_SECONDS * 0.9)
	assert_near(vitals.get_ghost_fraction(), 1.0, 0.0001, "y espera")
	vitals.advance(VitalsHud.GHOST_HOLD_SECONDS * 0.2)
	vitals.advance(0.2)
	assert_true(vitals.get_ghost_fraction() < 1.0, "luego se encoge")
	assert_true(vitals.get_ghost_fraction() > 0.6, "sin pasarse")
	vitals.advance(5.0)
	assert_near(vitals.get_ghost_fraction(), 0.6, 0.0001, "hasta la vida actual")


func test_health_ghost_follows_when_healing_and_snaps_without_a_trail() -> void:
	var vitals: VitalsHud = _track(VitalsHud.new()) as VitalsHud
	vitals.snap_health(1000, 1000)
	vitals.set_health(400, 1000)
	vitals.advance(10.0)
	vitals.set_health(700, 1000)
	assert_near(vitals.get_ghost_fraction(), 0.7, 0.0001, "al curarse el fantasma sigue a la barra")
	vitals.set_health(300, 1000)
	vitals.snap_health(1000, 1000)
	assert_near(vitals.get_ghost_fraction(), 1.0, 0.0001, "snap_health no deja fantasma")
	assert_near(vitals.get_health_fraction(), 1.0, 0.0001)


func test_second_loss_during_the_ghost_keeps_the_trail() -> void:
	var vitals: VitalsHud = _track(VitalsHud.new()) as VitalsHud
	vitals.snap_health(1000, 1000)
	vitals.set_health(800, 1000)
	vitals.advance(0.3)
	vitals.set_health(500, 1000)
	assert_near(vitals.get_ghost_fraction(), 1.0, 0.0001, "el fantasma cubre las dos pérdidas")
	vitals.advance(VitalsHud.GHOST_HOLD_SECONDS + 5.0)
	assert_near(vitals.get_ghost_fraction(), 0.5, 0.0001)


func test_stamina_bar_values_and_hiding_when_full() -> void:
	var vitals: VitalsHud = _track(VitalsHud.new()) as VitalsHud
	vitals.set_stamina(1000, 1000)
	vitals.advance(VitalsHud.STAMINA_HIDE_DELAY + 1.0)
	assert_false(vitals.is_stamina_visible(), "llena y quieta, se oculta")
	assert_eq(vitals.get_stamina_alpha(), 0.0)
	vitals.set_stamina(700, 1000)
	vitals.advance(0.5)
	assert_true(vitals.is_stamina_visible(), "al gastar reaparece")
	assert_near(vitals.get_stamina_fraction(), 0.7, 0.0001)
	assert_eq(vitals.get_stamina_alpha(), 1.0)
	vitals.set_stamina(1000, 1000)
	vitals.advance(VitalsHud.STAMINA_HIDE_DELAY * 0.5)
	assert_eq(vitals.get_stamina_alpha(), 1.0, "recién llena aún se ve un momento")
	vitals.advance(VitalsHud.STAMINA_HIDE_DELAY + 1.0)
	assert_eq(vitals.get_stamina_alpha(), 0.0, "y luego se desvanece")
	vitals.set_stamina(120, 1000, true)
	vitals.advance(0.5)
	assert_true(vitals.is_exhausted(), "agotado")
	assert_true(vitals.is_stamina_visible())


func test_stamina_bar_blinks_when_an_action_fails_for_lack_of_stamina() -> void:
	var vitals: VitalsHud = _track(VitalsHud.new()) as VitalsHud
	vitals.set_stamina(1000, 1000)
	vitals.advance(5.0)
	assert_false(vitals.is_stamina_visible())
	assert_false(vitals.is_blinking())
	vitals.notify_no_stamina()
	assert_true(vitals.is_blinking(), "parpadea")
	assert_true(vitals.is_stamina_visible(), "y la barra aparece aunque esté llena")
	vitals.advance(VitalsHud.BLINK_SECONDS * 0.5)
	assert_true(vitals.is_blinking())
	vitals.advance(VitalsHud.BLINK_SECONDS)
	assert_false(vitals.is_blinking(), "dura un momento")


# --- Arcos de dirección del daño --------------------------------------------------------------

func test_relative_angle_is_zero_in_front_and_signed_to_the_sides() -> void:
	var victim := Vector3(10.0, 0.0, 10.0)
	# Cámara mirando a -Z (yaw 0).
	assert_near(DamageIndicator.relative_angle(0.0, victim, victim + Vector3(0.0, 0.0, -5.0)), 0.0,
			0.001, "delante")
	assert_near(DamageIndicator.relative_angle(0.0, victim, victim + Vector3(5.0, 0.0, 0.0)),
			PI * 0.5, 0.001, "a la derecha")
	assert_near(DamageIndicator.relative_angle(0.0, victim, victim + Vector3(-5.0, 0.0, 0.0)),
			-PI * 0.5, 0.001, "a la izquierda")
	assert_near(absf(DamageIndicator.relative_angle(0.0, victim, victim + Vector3(0.0, 0.0, 5.0))),
			PI, 0.001, "detrás")
	assert_near(DamageIndicator.relative_angle(0.0, victim, victim + Vector3(0.0, 40.0, 0.0)), 0.0,
			0.001, "solo cuenta el plano horizontal")


func test_relative_angle_follows_the_camera_yaw() -> void:
	var victim := Vector3.ZERO
	var attacker := Vector3(0.0, 0.0, -5.0)
	# Giro de 90° a la izquierda (yaw +PI/2): lo que estaba delante queda a la derecha.
	assert_near(DamageIndicator.relative_angle(PI * 0.5, victim, attacker), PI * 0.5, 0.001)
	assert_near(DamageIndicator.relative_angle(-PI * 0.5, victim, attacker), -PI * 0.5, 0.001)
	# Mirando justo al atacante, está delante.
	var facing: float = DamageIndicator.world_heading(victim, attacker)
	assert_near(DamageIndicator.relative_angle(facing, victim, attacker), 0.0, 0.001)
	# Dos posiciones en el mismo punto no dan dirección.
	assert_eq(DamageIndicator.world_heading(victim, victim), 0.0)


func test_damage_indicator_keeps_world_direction_when_the_camera_turns() -> void:
	var indicator: DamageIndicator = _track(DamageIndicator.new()) as DamageIndicator
	indicator.set_camera_yaw(0.0)
	indicator.add_hit(DamageIndicator.world_heading(Vector3.ZERO, Vector3(5.0, 0.0, 0.0)), 1.0)
	assert_eq(indicator.get_arc_count(), 1)
	assert_near(indicator.get_arc_angle(0), PI * 0.5, 0.001, "el golpe vino de la derecha")
	indicator.set_camera_yaw(-PI * 0.5)
	assert_near(indicator.get_arc_angle(0), 0.0, 0.001, "si la cámara gira a la derecha, queda delante")
	indicator.set_camera_yaw(PI * 0.5)
	assert_near(absf(indicator.get_arc_angle(0)), PI, 0.001, "y si gira a la izquierda, detrás")


func test_damage_indicator_fades_out_and_is_bounded() -> void:
	var indicator: DamageIndicator = _track(DamageIndicator.new()) as DamageIndicator
	for i: int in DamageIndicator.MAX_ARCS + 5:
		indicator.add_hit(float(i) * 0.1, 1.0)
	assert_eq(indicator.get_arc_count(), DamageIndicator.MAX_ARCS, "no más arcos que el tope")
	var fresh: float = indicator.get_arc_alpha(0)
	indicator.advance(DamageIndicator.LIFETIME_SECONDS * 0.9)
	assert_true(indicator.get_arc_alpha(0) < fresh, "se desvanecen")
	indicator.advance(DamageIndicator.LIFETIME_SECONDS)
	assert_eq(indicator.get_arc_count(), 0, "y desaparecen")


# --- Viñeta de vida baja ----------------------------------------------------------------------

func test_vignette_appears_only_with_low_health() -> void:
	var vignette: LowHealthVignette = _track(LowHealthVignette.new()) as LowHealthVignette
	vignette.set_health_fraction(1.0)
	assert_eq(vignette.get_base_alpha(), 0.0, "con la vida llena no hay viñeta")
	vignette.set_health_fraction(LowHealthVignette.START_FRACTION + 0.01)
	assert_eq(vignette.get_base_alpha(), 0.0, "tampoco justo por encima del umbral")
	vignette.set_health_fraction(0.2)
	var middle: float = vignette.get_base_alpha()
	assert_true(middle > 0.0 and middle < LowHealthVignette.MAX_ALPHA, "a media subida")
	vignette.set_health_fraction(0.1)
	assert_true(vignette.get_base_alpha() > middle, "cuanto menos vida, más viñeta")
	vignette.set_health_fraction(0.0)
	assert_near(vignette.get_base_alpha(), LowHealthVignette.MAX_ALPHA, 0.0001, "con el tope")


func test_vignette_flashes_on_a_hit_even_with_full_health() -> void:
	var vignette: LowHealthVignette = _track(LowHealthVignette.new()) as LowHealthVignette
	vignette.set_health_fraction(1.0)
	vignette.advance(0.0)
	assert_false(vignette.visible, "invisible sin motivo")
	vignette.flash()
	assert_true(vignette.get_alpha() > 0.3, "el golpe la enciende")
	assert_true(vignette.visible)
	vignette.advance(LowHealthVignette.FLASH_SECONDS + 0.1)
	assert_eq(vignette.get_alpha(), 0.0, "y se apaga")
	assert_false(vignette.visible)
	assert_not_null(vignette.texture, "la textura se genera al arrancar")


# --- Puntos de reaparición --------------------------------------------------------------------

func _point(world: Node3D, node_name: String, realm: StringName, group: StringName) -> Marker3D:
	var marker := Marker3D.new()
	marker.name = node_name
	world.add_child(marker)
	marker.add_to_group(group)
	if not realm.is_empty():
		marker.set_meta(&"realm", realm)
	return marker


func test_respawn_list_uses_the_respawn_group_filtered_by_realm_in_scene_order() -> void:
	var world: Node3D = _track(Node3D.new()) as Node3D
	_point(world, "Campamento_Norte", &"vardheim", RespawnPointList.GROUP)
	_point(world, "Campamento_Sur", &"solmarch", RespawnPointList.GROUP)
	var fort: Marker3D = _point(world, "Fuerte", &"vardheim", RespawnPointList.GROUP)
	fort.set_meta(&"title", "Fuerte del Vado")
	var points: Array[Node3D] = RespawnPointList.list(world, NetProtocol.Realm.VARDHEIM)
	assert_eq(points.size(), 2)
	assert_eq(String(points[0].name), "Campamento_Norte", "en el orden de la escena")
	assert_eq(String(points[1].name), "Fuerte")
	assert_eq(RespawnPointList.labels(points), PackedStringArray(["Campamento Norte",
			"Fuerte del Vado"]), "con el título si lo hay y los guiones bajos como espacios")
	var south: Array[Node3D] = RespawnPointList.list(world, NetProtocol.Realm.SOLMARCH)
	assert_eq(south.size(), 1)
	var no_realm: Array[Node3D] = RespawnPointList.list(world, NetProtocol.Realm.ASKARRA)
	assert_eq(no_realm.size(), 3, "un reino sin puntos propios ve los del grupo entero")


func test_respawn_list_falls_back_to_spawn_points() -> void:
	var world: Node3D = _track(Node3D.new()) as Node3D
	_point(world, "Entrada_Norte", &"vardheim", Zones.SPAWN_GROUP)
	_point(world, "Entrada_Sur", &"solmarch", Zones.SPAWN_GROUP)
	var points: Array[Node3D] = RespawnPointList.list(world, NetProtocol.Realm.SOLMARCH)
	assert_eq(points.size(), 1)
	assert_eq(String(points[0].name), "Entrada_Sur")
	assert_eq(RespawnPointList.list(world, NetProtocol.Realm.ASKARRA).size(), 2,
			"y sin puntos del reino, todos")
	var empty_world: Node3D = _track(Node3D.new()) as Node3D
	assert_eq(RespawnPointList.list(empty_world, NetProtocol.Realm.VARDHEIM).size(), 0)
	assert_eq(RespawnPointList.list(null, NetProtocol.Realm.VARDHEIM).size(), 0)


func test_the_real_zones_offer_respawn_points() -> void:
	for zone_id: String in ["test_world", "vado_gris"]:
		var packed: PackedScene = load(NetZones.scene_path(zone_id)) as PackedScene
		var world: Node3D = packed.instantiate() as Node3D
		_track(world)
		for realm: int in [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH]:
			assert_true(RespawnPointList.list(world, realm).size() >= 1,
					"%s tiene puntos para el reino %d" % [zone_id, realm])


# --- Pantalla de muerte -----------------------------------------------------------------------

func _death_screen() -> DeathScreen:
	var screen: DeathScreen = _track(DeathScreen.new()) as DeathScreen
	return screen


func test_death_screen_counts_down_with_the_server_tick_and_enables_the_button() -> void:
	var screen: DeathScreen = _death_screen()
	assert_false(screen.is_open())
	assert_false(screen.visible)
	screen.open("Te ha derrotado Ana con un golpe pesado.", 1000, PackedStringArray(["Campamento", "Fuerte"]))
	assert_true(screen.is_open())
	assert_true(screen.visible)
	assert_eq(screen.get_cause_text(), "Te ha derrotado Ana con un golpe pesado.")
	screen.update_countdown(400)
	assert_eq(screen.get_remaining_ticks(), 600)
	assert_eq(screen.get_remaining_seconds(), 10)
	assert_eq(screen.get_countdown_text(), "Podrás reaparecer en 10 s")
	assert_false(screen.is_respawn_enabled(), "hasta que el servidor lo permite, el botón está apagado")
	screen.update_countdown(461)
	assert_eq(screen.get_remaining_seconds(), 9, "la cuenta va por ticks del servidor, redondeada hacia arriba")
	screen.update_countdown(999)
	assert_eq(screen.get_remaining_ticks(), 1)
	assert_false(screen.is_respawn_enabled(), "a un tick de poder, aún no")
	screen.update_countdown(1000)
	assert_eq(screen.get_remaining_ticks(), 0)
	assert_true(screen.is_respawn_enabled(), "al llegar el tick, se habilita")
	assert_eq(screen.get_countdown_text(), DeathScreen.TEXT_READY)


func test_death_screen_button_sends_the_chosen_point_once() -> void:
	var screen: DeathScreen = _death_screen()
	var requests: Array[int] = []
	screen.respawn_requested.connect(func(index: int) -> void: requests.append(index))
	screen.open("x", 100, PackedStringArray(["Campamento", "Fuerte", "Torre"]))
	assert_eq(screen.get_point_count(), 3)
	assert_eq(screen.get_point_label(1), "Fuerte")
	assert_eq(screen.get_selected_point(), 0, "por defecto el primero")
	screen.update_countdown(50)
	screen.get_button().pressed.emit()
	assert_eq(requests.size(), 0, "antes de tiempo no sale nada")
	screen.update_countdown(100)
	screen.select_point(2)
	assert_eq(screen.get_selected_point(), 2)
	screen.get_button().pressed.emit()
	assert_eq(requests, [2] as Array[int], "sale el punto elegido")
	assert_false(screen.is_respawn_enabled(), "y el botón se apaga mientras espera")
	assert_eq(screen.get_countdown_text(), DeathScreen.TEXT_REQUESTED)
	screen.get_button().pressed.emit()
	assert_eq(requests.size(), 1, "una sola petición")


func test_death_screen_reenables_the_button_if_the_server_does_not_answer() -> void:
	var screen: DeathScreen = _death_screen()
	var requests: Array[int] = []
	screen.respawn_requested.connect(func(index: int) -> void: requests.append(index))
	screen.open("x", 100, PackedStringArray(["A"]))
	screen.update_countdown(200)
	screen.get_button().pressed.emit()
	assert_false(screen.is_respawn_enabled())
	screen.advance(DeathScreen.REQUEST_TIMEOUT_SECONDS * 0.5)
	assert_false(screen.is_respawn_enabled(), "aún espera")
	screen.advance(DeathScreen.REQUEST_TIMEOUT_SECONDS)
	assert_true(screen.is_respawn_enabled(), "pasado el tiempo se puede volver a intentar")
	screen.get_button().pressed.emit()
	assert_eq(requests.size(), 2)


func test_death_screen_with_a_single_point_hides_the_list() -> void:
	var screen: DeathScreen = _death_screen()
	screen.open("x", 10, PackedStringArray())
	assert_eq(screen.get_point_count(), 1, "sin lista se ofrece un único punto")
	screen.update_countdown(10)
	var requests: Array[int] = []
	screen.respawn_requested.connect(func(index: int) -> void: requests.append(index))
	screen.get_button().pressed.emit()
	assert_eq(requests, [0] as Array[int])


func test_dying_and_respawning_ten_times_leaves_nothing_behind() -> void:
	var screen: DeathScreen = _death_screen()
	var opened: Array[int] = [0]
	var closed: Array[int] = [0]
	screen.opened.connect(func() -> void: opened[0] += 1)
	screen.closed.connect(func() -> void: closed[0] += 1)
	screen.open("primera", 10, PackedStringArray(["A", "B"]))
	screen.close()
	var baseline_nodes: int = screen.get_node_total()
	var baseline_children: int = screen.get_child_count()
	var requests: Array[int] = []
	screen.respawn_requested.connect(func(index: int) -> void: requests.append(index))
	for cycle: int in 10:
		screen.open("Te ha derrotado a la %d vez." % cycle, 100 * (cycle + 1),
				PackedStringArray(["A", "B", "C"]))
		assert_true(screen.is_open())
		screen.update_countdown(100 * (cycle + 1))
		screen.select_point(cycle % 3)
		screen.get_button().pressed.emit()
		screen.close()
		assert_false(screen.is_open())
		assert_false(screen.visible, "cerrada, oculta")
		assert_false(screen.is_respawn_enabled(), "y con el botón apagado")
	assert_eq(requests.size(), 10)
	assert_eq(requests[4], 1, "cada ciclo envía su propio punto")
	assert_eq(opened[0], 11)
	assert_eq(closed[0], 11, "tantos cierres como aperturas")
	assert_eq(screen.get_node_total(), baseline_nodes, "ningún nodo de más")
	assert_eq(screen.get_child_count(), baseline_children)
	screen.close()
	assert_eq(closed[0], 11, "cerrar una pantalla cerrada no hace nada")


# --- El HUD entero con un cliente falso -------------------------------------------------------

class HudRig:
	var hud: HUD
	var client: FakeClient
	var character: PlayerCharacter
	var rig: CameraRig
	var world: Node3D


func _make_hud(online: bool = true) -> HudRig:
	var hud_rig := HudRig.new()
	hud_rig.world = _track(Node3D.new()) as Node3D
	_point(hud_rig.world, "Campamento_Norte", &"vardheim", RespawnPointList.GROUP)
	_point(hud_rig.world, "Fuerte_Norte", &"vardheim", RespawnPointList.GROUP)
	hud_rig.character = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_track(hud_rig.character, hud_rig.world)
	hud_rig.rig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	hud_rig.rig.set_scripted_look(false)
	_track(hud_rig.rig)
	hud_rig.hud = (load(HUD_SCENE_PATH) as PackedScene).instantiate() as HUD
	_track(hud_rig.hud)
	hud_rig.hud.bind(hud_rig.character, hud_rig.rig)
	if online:
		hud_rig.client = FakeClient.new()
		hud_rig.client.fake_config.realm = NetProtocol.Realm.VARDHEIM
		_track(hud_rig.client)
		hud_rig.hud.bind_net(hud_rig.client, hud_rig.world)
	return hud_rig


## Un fotograma de la interfaz con un paso de [param delta] s (sin esperar a un fotograma real).
func _step(hud_rig: HudRig, delta: float = 0.016) -> void:
	hud_rig.hud._process(delta)


func test_sandbox_hud_hides_health_but_shows_stamina() -> void:
	var h: HudRig = _make_hud(false)
	var vitals: VitalsHud = h.hud.get_vitals()
	assert_false(vitals.is_health_visible(), "en el sandbox no hay vida")
	h.character.combat.stamina = 500
	_step(h)
	assert_near(vitals.get_stamina_fraction(), 0.5, 0.001, "la resistencia sí: la simulación es local")
	assert_eq(vitals.get_max_stamina(), CombatCatalog.rules().stamina_max)
	h.character.combat.combat_flags |= CombatState.FLAG_EXHAUSTED
	_step(h)
	assert_true(vitals.is_exhausted())
	assert_not_null(h.hud.get_feedback(), "y el reparto de combate sigue las acciones del personaje")
	assert_false(h.hud.get_death_screen().is_open())


func test_hud_shows_the_servers_health_and_the_stamina_in_the_debug_panel() -> void:
	var h: HudRig = _make_hud()
	h.client.fake_health = 640
	h.character.combat.stamina = 350
	_step(h)
	var vitals: VitalsHud = h.hud.get_vitals()
	assert_true(vitals.is_health_visible())
	assert_eq(vitals.get_health(), 640)
	assert_near(vitals.get_health_fraction(), 0.64, 0.001)
	assert_near(vitals.get_ghost_fraction(), 0.64, 0.001, "el primer valor no deja fantasma")
	h.client.fake_health = 400
	_step(h)
	assert_eq(vitals.get_health(), 400)
	assert_near(vitals.get_ghost_fraction(), 0.64, 0.001, "pero una pérdida sí")
	h.hud.set_debug_visible(true)
	var label: Label = h.hud.get_node(^"DebugPanel/DebugLabel") as Label
	assert_true(label.text.contains("Resistencia: 350 / 1000"), "F3 enseña la resistencia: %s" % label.text)
	assert_true(label.text.contains("Vida: 400 / 1000"), "y la vida en red")
	assert_true(label.text.contains("DPS (30 s): 0.0"), "y el DPS")


func test_stamina_blink_is_latched_from_the_one_tick_flag() -> void:
	var h: HudRig = _make_hud(false)
	var vitals: VitalsHud = h.hud.get_vitals()
	_step(h)
	vitals.advance(5.0)
	assert_false(vitals.is_blinking())
	h.character.combat.combat_flags |= CombatState.FLAG_NO_STAMINA
	h.hud._physics_process(0.016)
	assert_true(vitals.is_blinking(), "el bit de un tick basta para que parpadee")
	h.character.combat.combat_flags &= ~CombatState.FLAG_NO_STAMINA
	_step(h, 0.1)
	assert_true(vitals.is_blinking(), "y sigue parpadeando aunque el bit ya se haya borrado")


func test_damage_indicator_points_at_the_attacker_relative_to_the_camera() -> void:
	var h: HudRig = _make_hud()
	var feedback: CombatFeedback = h.hud.get_feedback()
	var attacker_position := Vector3(0.0, 0.0, -6.0)
	feedback.position_resolver = func(net_id: int) -> Vector3:
		return attacker_position if net_id == OTHER_ID else Vector3.ZERO
	h.rig.set_look(0.0, 0.0)
	_step(h)
	feedback.handle_event(NetMessages.EntityEvent.hit(OWN_ID, 10, OTHER_ID, 80, 0, 0, 2), true)
	var indicator: DamageIndicator = h.hud.get_damage_indicator()
	assert_eq(indicator.get_arc_count(), 1, "un golpe recibido, un arco")
	assert_near(indicator.get_arc_angle(0), 0.0, 0.001, "el atacante está delante")
	h.rig.set_look(PI * 0.5, 0.0)
	_step(h)
	assert_near(indicator.get_arc_angle(0), PI * 0.5, 0.01, "al girar la cámara a la izquierda, queda a la derecha")
	assert_true(h.hud.get_vignette().get_alpha() > 0.0, "y la viñeta destella")
	# Un daño de un atacante desconocido (fuera de interés) no dibuja arco pero sí la viñeta.
	feedback.position_resolver = func(net_id: int) -> Vector3:
		return Vector3.INF if net_id == OTHER_ID else Vector3.ZERO
	feedback.handle_event(NetMessages.EntityEvent.hit(OWN_ID, 11, OTHER_ID, 80, 0, 0, 2), true)
	assert_eq(indicator.get_arc_count(), 1, "sin posición del atacante no hay arco")


func test_a_parry_or_a_full_block_without_damage_does_not_flash_the_red_vignette() -> void:
	# T8: la viñeta roja avisa de daño; una parada o un bloqueo completo (amount 0) no lo es.
	var h: HudRig = _make_hud()
	var feedback: CombatFeedback = h.hud.get_feedback()
	feedback.position_resolver = func(_net_id: int) -> Vector3:
		return Vector3.ZERO
	_step(h)
	var vignette: LowHealthVignette = h.hud.get_vignette()
	var flags: Array[int] = [
		NetMessages.EntityEvent.HIT_FLAG_PARRIED,
		NetMessages.EntityEvent.HIT_FLAG_BLOCKED,
	]
	for flag: int in flags:
		feedback.handle_event(NetMessages.EntityEvent.hit(OWN_ID, 10, OTHER_ID, 0, 0, flag, 2), true)
		vignette.advance(0.0)
		assert_eq(vignette.get_alpha(), 0.0, "sin daño (flags %d) no hay viñeta" % flag)
		assert_false(vignette.visible, "y sigue oculta (flags %d)" % flag)
	# Control: un golpe con daño sí la enciende, conozca o no al atacante.
	feedback.handle_event(NetMessages.EntityEvent.hit(OWN_ID, 11, OTHER_ID, 90, 0, 0, 2), true)
	assert_true(vignette.get_alpha() > 0.3, "con 90 de daño destella")
	vignette.advance(LowHealthVignette.FLASH_SECONDS + 0.1)
	assert_eq(vignette.get_alpha(), 0.0)
	feedback.handle_event(NetMessages.EntityEvent.hit(OWN_ID, 12, 0, 90, 0, 0, 2), true)
	assert_true(vignette.get_alpha() > 0.3, "y también si el atacante no se conoce")


func test_death_flow_opens_the_screen_frees_the_cursor_and_closes_on_respawn() -> void:
	var h: HudRig = _make_hud()
	var screen: DeathScreen = h.hud.get_death_screen()
	var feedback: CombatFeedback = h.hud.get_feedback()
	h.client.get_remote_world().on_spawn(_remote_spawn(OTHER_ID, "Ana"))
	h.client.fake_estimated_tick = 500
	_step(h)
	assert_false(screen.is_open(), "vivo, sin pantalla")
	assert_false(h.rig.is_cursor_free())
	assert_false(h.hud.is_dimmed())
	var heavy: int = CombatCatalog.attack_id(&"sword_heavy")
	feedback.handle_event(NetMessages.EntityEvent.death(OWN_ID, 520, OTHER_ID, heavy), true)
	h.client.fake_dead = true
	h.client.fake_health = 0
	h.client.fake_respawn_tick = 1100
	h.client.fake_snapshot_tick = 521
	_step(h)
	assert_true(screen.is_open(), "muerto, se abre")
	assert_eq(screen.get_cause_text(), "Te ha derrotado Ana con un golpe pesado.",
			"quién te derrotó y con qué")
	assert_eq(screen.get_point_count(), 2, "con la lista de puntos del reino")
	assert_eq(screen.get_point_label(1), "Fuerte Norte")
	assert_true(h.hud.is_dimmed(), "el resto de la interfaz se atenúa")
	assert_true(h.rig.is_cursor_free(), "el cursor queda libre")
	assert_false(h.hud.get_node(^"Crosshair").visible, "y sin punto de mira")
	assert_eq(screen.get_remaining_seconds(), 10, "cuenta atrás de 600 ticks")
	assert_false(screen.is_respawn_enabled())
	# El servidor deja reaparecer cuando el tick estimado llega a respawn_tick.
	h.client.fake_estimated_tick = 1100
	_step(h)
	assert_true(screen.is_respawn_enabled())
	screen.select_point(1)
	screen.get_button().pressed.emit()
	assert_eq(h.client.respawn_requests, [1] as Array[int], "el HUD envía el RESPAWN_REQUEST con el índice elegido")
	# Llega el evento RESPAWN y luego snapshots con vida.
	feedback.handle_event(NetMessages.EntityEvent.respawn(OWN_ID, 1110, 1), true)
	assert_false(screen.is_open(), "al reaparecer se cierra")
	h.client.fake_dead = false
	h.client.fake_health = 1000
	h.client.fake_respawn_tick = 0
	h.client.fake_snapshot_tick = 1111
	_step(h)
	assert_false(screen.is_open())
	assert_false(h.hud.is_dimmed(), "la interfaz vuelve a la normalidad")
	assert_false(h.rig.is_cursor_free(), "el cursor se recaptura")
	assert_near(h.hud.get_vitals().get_ghost_fraction(), 1.0, 0.001, "sin restos de la vida anterior")


func test_a_stale_dead_snapshot_after_the_respawn_does_not_reopen_the_screen() -> void:
	var h: HudRig = _make_hud()
	var screen: DeathScreen = h.hud.get_death_screen()
	h.client.fake_dead = true
	h.client.fake_health = 0
	h.client.fake_respawn_tick = 100
	h.client.fake_snapshot_tick = 90
	_step(h)
	assert_true(screen.is_open())
	h.hud.get_feedback().handle_event(NetMessages.EntityEvent.respawn(OWN_ID, 120, 0), true)
	assert_false(screen.is_open())
	# Un snapshot atrasado (tick 100 < 120) todavía dice «muerto».
	h.client.fake_snapshot_tick = 100
	_step(h)
	assert_false(screen.is_open(), "un snapshot anterior a la reaparición no la reabre")
	h.client.fake_snapshot_tick = 130
	h.client.fake_dead = false
	h.client.fake_health = 1000
	_step(h)
	assert_false(screen.is_open())


func test_ten_deaths_in_the_hud_leave_no_leftovers() -> void:
	var h: HudRig = _make_hud()
	var screen: DeathScreen = h.hud.get_death_screen()
	var feedback: CombatFeedback = h.hud.get_feedback()
	h.client.get_remote_world().on_spawn(_remote_spawn(OTHER_ID, "Ana"))
	_step(h)
	var baseline_nodes: int = h.hud.find_children("*", "", true, false).size()
	var tick: int = 1000
	for cycle: int in 10:
		tick += 700
		feedback.handle_event(NetMessages.EntityEvent.death(OWN_ID, tick, OTHER_ID, 1), true)
		h.client.fake_dead = true
		h.client.fake_health = 0
		h.client.fake_respawn_tick = tick + 600
		h.client.fake_snapshot_tick = tick + 1
		h.client.fake_estimated_tick = tick + 2
		_step(h)
		assert_true(screen.is_open(), "ciclo %d: abierta" % cycle)
		assert_true(h.rig.is_cursor_free())
		h.client.fake_estimated_tick = tick + 600
		_step(h)
		screen.get_button().pressed.emit()
		feedback.handle_event(NetMessages.EntityEvent.respawn(OWN_ID, tick + 610, 0), true)
		h.client.fake_dead = false
		h.client.fake_health = 1000
		h.client.fake_respawn_tick = 0
		h.client.fake_snapshot_tick = tick + 611
		_step(h)
		assert_false(screen.is_open(), "ciclo %d: cerrada" % cycle)
		assert_false(h.hud.is_dimmed())
		assert_false(h.rig.is_cursor_free(), "ciclo %d: cursor capturado otra vez" % cycle)
	assert_eq(h.client.respawn_requests.size(), 10)
	assert_eq(h.hud.find_children("*", "", true, false).size(), baseline_nodes,
			"el HUD no acumula nodos")
	assert_eq(h.hud.get_damage_numbers().get_active_count(), 0)
	assert_eq(h.hud.get_damage_indicator().get_arc_count(), 0)
	for item: CanvasItem in [h.hud.get_vitals(), h.hud.get_node(^"Crosshair"),
			h.hud.get_node(^"HintLabel")]:
		assert_eq(item.modulate.a, 1.0, "nada se queda atenuado")


func _remote_spawn(net_id: int, display_name: String) -> NetMessages.EntitySpawn:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = NetProtocol.EntityKind.PLAYER
	spawn.spawn_tick = 10
	spawn.realm = NetProtocol.Realm.SOLMARCH
	spawn.display_name = display_name
	var state := PlayerState.new()
	state.position = Vector3(0.0, 0.0, -6.0)
	state.grounded = true
	spawn.state = state
	return spawn


func test_hud_marks_damaged_entities_for_the_nameplates() -> void:
	var h: HudRig = _make_hud()
	var plates: Nameplates = h.hud.get_nameplates()
	assert_not_null(plates)
	assert_false(plates.was_damaged_recently(OTHER_ID))
	# Un golpe de un tercero a otro jugador: sus placas enseñan la barra de vida unos segundos.
	h.hud.get_feedback().handle_event(NetMessages.EntityEvent.hit(OTHER_ID, 10, 33, 80, 0, 0, 2),
			false)
	assert_true(plates.was_damaged_recently(OTHER_ID), "el daño a otro marca su placa")
	assert_false(plates.was_damaged_recently(33), "y no la del atacante")
