extends TestCase
## Tests for the combat interface (UI-10, UI-14) with fake states: the health and
## stamina bars ([VitalsHud]: values, ghost, flashing, stamina hidden when full), the damage
## direction arcs ([DamageIndicator]: angle relative to the camera), the low-health vignette, the
## death screen ([DeathScreen]: countdown with the server tick, button, 10 cycles with no
## leftovers) and the list of respawn points ([RespawnPointList]). The last part mounts the entire
## [HUD] with a fake network client that provides health and state at will.
## [br][br]
## Phase 4 (H4, docs/habilidades.md, section 6.5): the knocked-down alerts (countdown, get up, finish off and
## the invitation to help an ally up), the template selector on the death screen and the bow
## aiming (camera zoom and reticle).

const OWN_ID: int = 5
const OTHER_ID: int = 21
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"


## Network client that connects to nothing: provides the health, state and server tick that the
## test asks for and records the respawn requests.
class FakeClient extends NetClient:
	var fake_has_health: bool = true
	var fake_health: int = 1000
	var fake_max_health: int = 1000
	var fake_dead: bool = false
	var fake_respawn_tick: int = 0
	var fake_estimated_tick: int = 0
	var fake_snapshot_tick: int = 1
	var fake_config: ClientConfig = ClientConfig.new()
	var fake_downed: bool = false
	var respawn_requests: Array[int] = []
	var loadout_selects: Array[int] = []

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

	func is_downed() -> bool:
		return fake_downed

	func send_loadout_select(template_id: int) -> bool:
		loadout_selects.append(template_id)
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


## Adds [param node] to the test's root (or to [param parent]) and frees it at the end.
func _track(node: Node, parent: Node = null) -> Node:
	(parent if parent != null else _root).add_child(node)
	_nodes.append(node)
	return node


# --- Health and stamina bars ------------------------------------------------------------------

func test_health_bar_shows_the_values_and_hides_without_network() -> void:
	var vitals: VitalsHud = _track(VitalsHud.new()) as VitalsHud
	assert_true(vitals.is_health_visible(), "visible by default")
	vitals.set_health(750, 1000)
	assert_eq(vitals.get_health(), 750)
	assert_eq(vitals.get_max_health(), 1000)
	assert_near(vitals.get_health_fraction(), 0.75, 0.0001)
	vitals.set_health(5000, 1000)
	assert_eq(vitals.get_health(), 1000, "does not exceed the maximum")
	vitals.set_health(-3, 1000)
	assert_eq(vitals.get_health(), 0, "nor go below 0")
	vitals.set_health_visible(false)
	assert_false(vitals.is_health_visible(), "without a network the health is hidden")


func test_health_ghost_holds_then_shrinks_to_the_current_value() -> void:
	var vitals: VitalsHud = _track(VitalsHud.new()) as VitalsHud
	vitals.snap_health(1000, 1000)
	vitals.set_health(600, 1000)
	assert_near(vitals.get_health_fraction(), 0.6, 0.0001)
	assert_near(vitals.get_ghost_fraction(), 1.0, 0.0001, "the ghost keeps the loss")
	vitals.advance(VitalsHud.GHOST_HOLD_SECONDS * 0.9)
	assert_near(vitals.get_ghost_fraction(), 1.0, 0.0001, "and waits")
	vitals.advance(VitalsHud.GHOST_HOLD_SECONDS * 0.2)
	vitals.advance(0.2)
	assert_true(vitals.get_ghost_fraction() < 1.0, "then it shrinks")
	assert_true(vitals.get_ghost_fraction() > 0.6, "without overshooting")
	vitals.advance(5.0)
	assert_near(vitals.get_ghost_fraction(), 0.6, 0.0001, "down to the current health")


func test_health_ghost_follows_when_healing_and_snaps_without_a_trail() -> void:
	var vitals: VitalsHud = _track(VitalsHud.new()) as VitalsHud
	vitals.snap_health(1000, 1000)
	vitals.set_health(400, 1000)
	vitals.advance(10.0)
	vitals.set_health(700, 1000)
	assert_near(vitals.get_ghost_fraction(), 0.7, 0.0001, "when healing the ghost follows the bar")
	vitals.set_health(300, 1000)
	vitals.snap_health(1000, 1000)
	assert_near(vitals.get_ghost_fraction(), 1.0, 0.0001, "snap_health leaves no ghost")
	assert_near(vitals.get_health_fraction(), 1.0, 0.0001)


func test_second_loss_during_the_ghost_keeps_the_trail() -> void:
	var vitals: VitalsHud = _track(VitalsHud.new()) as VitalsHud
	vitals.snap_health(1000, 1000)
	vitals.set_health(800, 1000)
	vitals.advance(0.3)
	vitals.set_health(500, 1000)
	assert_near(vitals.get_ghost_fraction(), 1.0, 0.0001, "the ghost covers both losses")
	vitals.advance(VitalsHud.GHOST_HOLD_SECONDS + 5.0)
	assert_near(vitals.get_ghost_fraction(), 0.5, 0.0001)


func test_stamina_bar_values_and_hiding_when_full() -> void:
	var vitals: VitalsHud = _track(VitalsHud.new()) as VitalsHud
	vitals.set_stamina(1000, 1000)
	vitals.advance(VitalsHud.STAMINA_HIDE_DELAY + 1.0)
	assert_false(vitals.is_stamina_visible(), "full and still, it hides")
	assert_eq(vitals.get_stamina_alpha(), 0.0)
	vitals.set_stamina(700, 1000)
	vitals.advance(0.5)
	assert_true(vitals.is_stamina_visible(), "when spending it reappears")
	assert_near(vitals.get_stamina_fraction(), 0.7, 0.0001)
	assert_eq(vitals.get_stamina_alpha(), 1.0)
	vitals.set_stamina(1000, 1000)
	vitals.advance(VitalsHud.STAMINA_HIDE_DELAY * 0.5)
	assert_eq(vitals.get_stamina_alpha(), 1.0, "just filled it is still visible for a moment")
	vitals.advance(VitalsHud.STAMINA_HIDE_DELAY + 1.0)
	assert_eq(vitals.get_stamina_alpha(), 0.0, "and then it fades")
	vitals.set_stamina(120, 1000, true)
	vitals.advance(0.5)
	assert_true(vitals.is_exhausted(), "exhausted")
	assert_true(vitals.is_stamina_visible())


func test_stamina_bar_blinks_when_an_action_fails_for_lack_of_stamina() -> void:
	var vitals: VitalsHud = _track(VitalsHud.new()) as VitalsHud
	vitals.set_stamina(1000, 1000)
	vitals.advance(5.0)
	assert_false(vitals.is_stamina_visible())
	assert_false(vitals.is_blinking())
	vitals.notify_no_stamina()
	assert_true(vitals.is_blinking(), "flashes")
	assert_true(vitals.is_stamina_visible(), "and the bar appears even if full")
	vitals.advance(VitalsHud.BLINK_SECONDS * 0.5)
	assert_true(vitals.is_blinking())
	vitals.advance(VitalsHud.BLINK_SECONDS)
	assert_false(vitals.is_blinking(), "lasts a moment")


# --- Damage direction arcs --------------------------------------------------------------------

func test_relative_angle_is_zero_in_front_and_signed_to_the_sides() -> void:
	var victim := Vector3(10.0, 0.0, 10.0)
	# Camera facing -Z (yaw 0).
	assert_near(DamageIndicator.relative_angle(0.0, victim, victim + Vector3(0.0, 0.0, -5.0)), 0.0,
			0.001, "in front")
	assert_near(DamageIndicator.relative_angle(0.0, victim, victim + Vector3(5.0, 0.0, 0.0)),
			PI * 0.5, 0.001, "to the right")
	assert_near(DamageIndicator.relative_angle(0.0, victim, victim + Vector3(-5.0, 0.0, 0.0)),
			-PI * 0.5, 0.001, "to the left")
	assert_near(absf(DamageIndicator.relative_angle(0.0, victim, victim + Vector3(0.0, 0.0, 5.0))),
			PI, 0.001, "behind")
	assert_near(DamageIndicator.relative_angle(0.0, victim, victim + Vector3(0.0, 40.0, 0.0)), 0.0,
			0.001, "only the horizontal plane counts")


func test_relative_angle_follows_the_camera_yaw() -> void:
	var victim := Vector3.ZERO
	var attacker := Vector3(0.0, 0.0, -5.0)
	# Turning 90° left (yaw +PI/2): what was in front is now to the right.
	assert_near(DamageIndicator.relative_angle(PI * 0.5, victim, attacker), PI * 0.5, 0.001)
	assert_near(DamageIndicator.relative_angle(-PI * 0.5, victim, attacker), -PI * 0.5, 0.001)
	# Looking right at the attacker, they are in front.
	var facing: float = DamageIndicator.world_heading(victim, attacker)
	assert_near(DamageIndicator.relative_angle(facing, victim, attacker), 0.0, 0.001)
	# Two positions at the same point give no direction.
	assert_eq(DamageIndicator.world_heading(victim, victim), 0.0)


func test_damage_indicator_keeps_world_direction_when_the_camera_turns() -> void:
	var indicator: DamageIndicator = _track(DamageIndicator.new()) as DamageIndicator
	indicator.set_camera_yaw(0.0)
	indicator.add_hit(DamageIndicator.world_heading(Vector3.ZERO, Vector3(5.0, 0.0, 0.0)), 1.0)
	assert_eq(indicator.get_arc_count(), 1)
	assert_near(indicator.get_arc_angle(0), PI * 0.5, 0.001, "the hit came from the right")
	indicator.set_camera_yaw(-PI * 0.5)
	assert_near(indicator.get_arc_angle(0), 0.0, 0.001, "if the camera turns right, it ends up in front")
	indicator.set_camera_yaw(PI * 0.5)
	assert_near(absf(indicator.get_arc_angle(0)), PI, 0.001, "and if it turns left, behind")


func test_damage_indicator_fades_out_and_is_bounded() -> void:
	var indicator: DamageIndicator = _track(DamageIndicator.new()) as DamageIndicator
	for i: int in DamageIndicator.MAX_ARCS + 5:
		indicator.add_hit(float(i) * 0.1, 1.0)
	assert_eq(indicator.get_arc_count(), DamageIndicator.MAX_ARCS, "no more arcs than the cap")
	var fresh: float = indicator.get_arc_alpha(0)
	indicator.advance(DamageIndicator.LIFETIME_SECONDS * 0.9)
	assert_true(indicator.get_arc_alpha(0) < fresh, "they fade")
	indicator.advance(DamageIndicator.LIFETIME_SECONDS)
	assert_eq(indicator.get_arc_count(), 0, "and disappear")


# --- Low-health vignette ----------------------------------------------------------------------

func test_vignette_appears_only_with_low_health() -> void:
	var vignette: LowHealthVignette = _track(LowHealthVignette.new()) as LowHealthVignette
	vignette.set_health_fraction(1.0)
	assert_eq(vignette.get_base_alpha(), 0.0, "with full health there is no vignette")
	vignette.set_health_fraction(LowHealthVignette.START_FRACTION + 0.01)
	assert_eq(vignette.get_base_alpha(), 0.0, "nor just above the threshold")
	vignette.set_health_fraction(0.2)
	var middle: float = vignette.get_base_alpha()
	assert_true(middle > 0.0 and middle < LowHealthVignette.MAX_ALPHA, "halfway up")
	vignette.set_health_fraction(0.1)
	assert_true(vignette.get_base_alpha() > middle, "the less health, the more vignette")
	vignette.set_health_fraction(0.0)
	assert_near(vignette.get_base_alpha(), LowHealthVignette.MAX_ALPHA, 0.0001, "at the cap")


func test_vignette_flashes_on_a_hit_even_with_full_health() -> void:
	var vignette: LowHealthVignette = _track(LowHealthVignette.new()) as LowHealthVignette
	vignette.set_health_fraction(1.0)
	vignette.advance(0.0)
	assert_false(vignette.visible, "invisible for no reason")
	vignette.flash(90, 1000)
	assert_true(vignette.get_alpha() >= LowHealthVignette.FLASH_MIN_ALPHA, "the hit lights it up")
	assert_true(vignette.visible)
	vignette.advance(LowHealthVignette.FLASH_SECONDS + 0.1)
	assert_eq(vignette.get_alpha(), 0.0, "and it goes off")
	assert_false(vignette.visible)
	assert_not_null(vignette.texture, "the texture is generated at startup")


# --- Respawn points ---------------------------------------------------------------------------

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
	assert_eq(String(points[0].name), "Campamento_Norte", "in scene order")
	assert_eq(String(points[1].name), "Fuerte")
	assert_eq(RespawnPointList.labels(points), PackedStringArray(["Campamento Norte",
			"Fuerte del Vado"]), "with the title if there is one and underscores as spaces")
	var south: Array[Node3D] = RespawnPointList.list(world, NetProtocol.Realm.SOLMARCH)
	assert_eq(south.size(), 1)
	var no_realm: Array[Node3D] = RespawnPointList.list(world, NetProtocol.Realm.ASKARRA)
	assert_eq(no_realm.size(), 3, "a realm without its own points sees those of the whole group")


func test_respawn_list_falls_back_to_spawn_points() -> void:
	var world: Node3D = _track(Node3D.new()) as Node3D
	_point(world, "Entrada_Norte", &"vardheim", Zones.SPAWN_GROUP)
	_point(world, "Entrada_Sur", &"solmarch", Zones.SPAWN_GROUP)
	var points: Array[Node3D] = RespawnPointList.list(world, NetProtocol.Realm.SOLMARCH)
	assert_eq(points.size(), 1)
	assert_eq(String(points[0].name), "Entrada_Sur")
	assert_eq(RespawnPointList.list(world, NetProtocol.Realm.ASKARRA).size(), 2,
			"and without realm points, all of them")
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
					"%s has points for realm %d" % [zone_id, realm])


# --- Death screen -----------------------------------------------------------------------------

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
	assert_false(screen.is_respawn_enabled(), "until the server allows it, the button is off")
	screen.update_countdown(461)
	assert_eq(screen.get_remaining_seconds(), 9, "the countdown runs on server ticks, rounded up")
	screen.update_countdown(999)
	assert_eq(screen.get_remaining_ticks(), 1)
	assert_false(screen.is_respawn_enabled(), "one tick short of being possible, not yet")
	screen.update_countdown(1000)
	assert_eq(screen.get_remaining_ticks(), 0)
	assert_true(screen.is_respawn_enabled(), "when the tick arrives, it is enabled")
	assert_eq(screen.get_countdown_text(), DeathScreen.TEXT_READY)


func test_death_screen_button_sends_the_chosen_point_once() -> void:
	var screen: DeathScreen = _death_screen()
	var requests: Array[int] = []
	screen.respawn_requested.connect(func(index: int) -> void: requests.append(index))
	screen.open("x", 100, PackedStringArray(["Campamento", "Fuerte", "Torre"]))
	assert_eq(screen.get_point_count(), 3)
	assert_eq(screen.get_point_label(1), "Fuerte")
	assert_eq(screen.get_selected_point(), 0, "the first by default")
	screen.update_countdown(50)
	screen.get_button().pressed.emit()
	assert_eq(requests.size(), 0, "too early, nothing is sent")
	screen.update_countdown(100)
	screen.select_point(2)
	assert_eq(screen.get_selected_point(), 2)
	screen.get_button().pressed.emit()
	assert_eq(requests, [2] as Array[int], "the chosen point is sent")
	assert_false(screen.is_respawn_enabled(), "and the button turns off while waiting")
	assert_eq(screen.get_countdown_text(), DeathScreen.TEXT_REQUESTED)
	screen.get_button().pressed.emit()
	assert_eq(requests.size(), 1, "a single request")


func test_death_screen_reenables_the_button_if_the_server_does_not_answer() -> void:
	var screen: DeathScreen = _death_screen()
	var requests: Array[int] = []
	screen.respawn_requested.connect(func(index: int) -> void: requests.append(index))
	screen.open("x", 100, PackedStringArray(["A"]))
	screen.update_countdown(200)
	screen.get_button().pressed.emit()
	assert_false(screen.is_respawn_enabled())
	screen.advance(DeathScreen.REQUEST_TIMEOUT_SECONDS * 0.5)
	assert_false(screen.is_respawn_enabled(), "still waiting")
	screen.advance(DeathScreen.REQUEST_TIMEOUT_SECONDS)
	assert_true(screen.is_respawn_enabled(), "after the time has passed it can be tried again")
	screen.get_button().pressed.emit()
	assert_eq(requests.size(), 2)


func test_death_screen_with_a_single_point_hides_the_list() -> void:
	var screen: DeathScreen = _death_screen()
	screen.open("x", 10, PackedStringArray())
	assert_eq(screen.get_point_count(), 1, "without a list a single point is offered")
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
		assert_false(screen.visible, "closed, hidden")
		assert_false(screen.is_respawn_enabled(), "and with the button off")
	assert_eq(requests.size(), 10)
	assert_eq(requests[4], 1, "each cycle sends its own point")
	assert_eq(opened[0], 11)
	assert_eq(closed[0], 11, "as many closes as opens")
	assert_eq(screen.get_node_total(), baseline_nodes, "no extra nodes")
	assert_eq(screen.get_child_count(), baseline_children)
	screen.close()
	assert_eq(closed[0], 11, "closing a closed screen does nothing")


# --- The whole HUD with a fake client ---------------------------------------------------------

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


## One interface frame with a step of [param delta] s (without waiting for a real frame).
func _step(hud_rig: HudRig, delta: float = 0.016) -> void:
	hud_rig.hud._process(delta)


func test_sandbox_hud_hides_health_but_shows_stamina() -> void:
	var h: HudRig = _make_hud(false)
	var vitals: VitalsHud = h.hud.get_vitals()
	assert_false(vitals.is_health_visible(), "in the sandbox there is no health")
	h.character.combat.stamina = 500
	_step(h)
	assert_near(vitals.get_stamina_fraction(), 0.5, 0.001, "stamina does: the simulation is local")
	assert_eq(vitals.get_max_stamina(), CombatCatalog.rules().stamina_max)
	h.character.combat.combat_flags |= CombatState.FLAG_EXHAUSTED
	_step(h)
	assert_true(vitals.is_exhausted())
	assert_not_null(h.hud.get_feedback(), "and the combat split follows the character's actions")
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
	assert_near(vitals.get_ghost_fraction(), 0.64, 0.001, "the first value leaves no ghost")
	h.client.fake_health = 400
	_step(h)
	assert_eq(vitals.get_health(), 400)
	assert_near(vitals.get_ghost_fraction(), 0.64, 0.001, "but a loss does")
	h.hud.set_debug_visible(true)
	var label: Label = h.hud.get_node(^"DebugPanel/DebugLabel") as Label
	assert_true(label.text.contains("Resistencia: 350 / 1000"), "F3 shows the stamina: %s" % label.text)
	assert_true(label.text.contains("Vida: 400 / 1000"), "and the health over the network")
	assert_true(label.text.contains("DPS (30 s): 0.0"), "and the DPS")


func test_stamina_blink_is_latched_from_the_one_tick_flag() -> void:
	var h: HudRig = _make_hud(false)
	var vitals: VitalsHud = h.hud.get_vitals()
	_step(h)
	vitals.advance(5.0)
	assert_false(vitals.is_blinking())
	h.character.combat.combat_flags |= CombatState.FLAG_NO_STAMINA
	h.hud._physics_process(0.016)
	assert_true(vitals.is_blinking(), "the one-tick bit is enough to make it flash")
	h.character.combat.combat_flags &= ~CombatState.FLAG_NO_STAMINA
	_step(h, 0.1)
	assert_true(vitals.is_blinking(), "and it keeps flashing even though the bit has been cleared")


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
	assert_eq(indicator.get_arc_count(), 1, "one hit received, one arc")
	assert_near(indicator.get_arc_angle(0), 0.0, 0.001, "the attacker is in front")
	h.rig.set_look(PI * 0.5, 0.0)
	_step(h)
	assert_near(indicator.get_arc_angle(0), PI * 0.5, 0.01, "when the camera turns left, they end up to the right")
	assert_true(h.hud.get_vignette().get_alpha() > 0.0, "and the vignette flashes")
	assert_true(h.hud.get_war_hud().get_world_markers().is_in_combat(),
			"and the world markers stay with the target (UI-54)")
	# Damage from an unknown attacker (out of interest) draws no arc but does draw the vignette.
	feedback.position_resolver = func(net_id: int) -> Vector3:
		return Vector3.INF if net_id == OTHER_ID else Vector3.ZERO
	feedback.handle_event(NetMessages.EntityEvent.hit(OWN_ID, 11, OTHER_ID, 80, 0, 0, 2), true)
	assert_eq(indicator.get_arc_count(), 1, "without the attacker's position there is no arc")


func test_a_parry_or_a_full_block_without_damage_does_not_flash_the_red_vignette() -> void:
	# T8: the red vignette warns of damage; a parry or a full block (amount 0) is not.
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
		assert_eq(vignette.get_alpha(), 0.0, "without damage (flags %d) there is no vignette" % flag)
		assert_false(vignette.visible, "and it stays hidden (flags %d)" % flag)
	# Control: a hit with damage does light it, whether or not it knows the attacker.
	feedback.handle_event(NetMessages.EntityEvent.hit(OWN_ID, 11, OTHER_ID, 90, 0, 0, 2), true)
	assert_true(vignette.get_alpha() >= LowHealthVignette.FLASH_MIN_ALPHA, "with 90 damage it flashes")
	assert_true(vignette.get_alpha() <= LowHealthVignette.FLASH_MAX_ALPHA, "but with the alpha of a small hit")
	vignette.advance(LowHealthVignette.FLASH_SECONDS + 0.1)
	assert_eq(vignette.get_alpha(), 0.0)
	feedback.handle_event(NetMessages.EntityEvent.hit(OWN_ID, 12, 0, 90, 0, 0, 2), true)
	assert_true(vignette.get_alpha() >= LowHealthVignette.FLASH_MIN_ALPHA, "and also if the attacker is not known")


func test_death_flow_opens_the_screen_frees_the_cursor_and_closes_on_respawn() -> void:
	var h: HudRig = _make_hud()
	var screen: DeathScreen = h.hud.get_death_screen()
	var feedback: CombatFeedback = h.hud.get_feedback()
	h.client.get_remote_world().on_spawn(_remote_spawn(OTHER_ID, "Ana"))
	h.client.fake_estimated_tick = 500
	_step(h)
	assert_false(screen.is_open(), "alive, no screen")
	assert_false(h.rig.is_cursor_free())
	assert_false(h.hud.is_dimmed())
	var heavy: int = CombatCatalog.attack_id(&"sword_heavy")
	feedback.handle_event(NetMessages.EntityEvent.death(OWN_ID, 520, OTHER_ID, heavy), true)
	h.client.fake_dead = true
	h.client.fake_health = 0
	h.client.fake_respawn_tick = 1100
	h.client.fake_snapshot_tick = 521
	_step(h)
	assert_true(screen.is_open(), "dead, it opens")
	assert_eq(screen.get_cause_text(), "Te ha derrotado Ana con un golpe pesado.",
			"who defeated you and with what")
	assert_eq(screen.get_point_count(), 2, "with the realm's list of points")
	assert_eq(screen.get_point_label(1), "Fuerte Norte")
	assert_true(h.hud.is_dimmed(), "the rest of the interface dims")
	assert_true(h.hud.get_vignette().is_suppressed(), "and no red vignette on top of the death screen (UI-50)")
	assert_eq(h.hud.get_vignette().get_alpha(), 0.0)
	assert_true(h.rig.is_cursor_free(), "the cursor is left free")
	assert_false(h.hud.get_node(^"Crosshair").visible, "and no crosshair")
	assert_eq(screen.get_remaining_seconds(), 10, "countdown of 600 ticks")
	assert_false(screen.is_respawn_enabled())
	# The server allows respawning when the estimated tick reaches respawn_tick.
	h.client.fake_estimated_tick = 1100
	_step(h)
	assert_true(screen.is_respawn_enabled())
	screen.select_point(1)
	screen.get_button().pressed.emit()
	assert_eq(h.client.respawn_requests, [1] as Array[int], "the HUD sends the RESPAWN_REQUEST with the chosen index")
	# The RESPAWN event arrives and then snapshots with health.
	feedback.handle_event(NetMessages.EntityEvent.respawn(OWN_ID, 1110, 1), true)
	assert_false(screen.is_open(), "on respawning it closes")
	h.client.fake_dead = false
	h.client.fake_health = 1000
	h.client.fake_respawn_tick = 0
	h.client.fake_snapshot_tick = 1111
	_step(h)
	assert_false(screen.is_open())
	assert_false(h.hud.is_dimmed(), "the interface goes back to normal")
	assert_false(h.hud.get_vignette().is_suppressed(), "and the vignette can be drawn again")
	assert_false(h.rig.is_cursor_free(), "the cursor is recaptured")
	assert_near(h.hud.get_vitals().get_ghost_fraction(), 1.0, 0.001, "without leftovers from the previous life")


## Kills the local player in the fake client and lets the HUD open the death screen.
func _die(h: HudRig, tick: int) -> void:
	h.hud.get_feedback().handle_event(NetMessages.EntityEvent.death(OWN_ID, tick, OTHER_ID, 1), true)
	h.client.fake_dead = true
	h.client.fake_health = 0
	h.client.fake_respawn_tick = tick + 600
	h.client.fake_snapshot_tick = tick + 1
	h.client.fake_estimated_tick = tick + 2
	_step(h)


## The player respawns: the RESPAWN event arrives and then a snapshot with health.
func _respawn(h: HudRig, tick: int) -> void:
	h.hud.get_feedback().handle_event(NetMessages.EntityEvent.respawn(OWN_ID, tick, 0), true)
	h.client.fake_dead = false
	h.client.fake_health = 1000
	h.client.fake_respawn_tick = 0
	h.client.fake_snapshot_tick = tick + 1
	_step(h)


func test_closing_a_window_over_the_death_screen_keeps_the_cursor_free() -> void:
	# T1: the settings window (F10) and the death screen both ask for the cursor; closing one
	# must not recapture the mouse while the other is still open.
	var h: HudRig = _make_hud()
	var window: UIWindow = _track(UIWindow.new()) as UIWindow
	window.bind_camera(h.rig)
	_die(h, 1000)
	assert_true(h.hud.get_death_screen().is_open())
	assert_true(h.rig.is_cursor_free())
	window.open()
	window.close()
	_step(h)
	assert_true(h.rig.is_cursor_free(), "with the death screen open the cursor stays free")
	assert_false(h.hud.get_node(^"Crosshair").visible, "and the crosshair stays hidden")
	_respawn(h, 1610)
	assert_false(h.hud.get_death_screen().is_open())
	assert_false(h.rig.is_cursor_free(), "on respawning, now it is recaptured")
	assert_true(h.hud.get_node(^"Crosshair").visible)


func test_respawning_with_a_window_open_keeps_the_cursor_free() -> void:
	var h: HudRig = _make_hud()
	var window: UIWindow = _track(UIWindow.new()) as UIWindow
	window.bind_camera(h.rig)
	window.open()
	_die(h, 1000)
	_respawn(h, 1610)
	assert_false(h.hud.get_death_screen().is_open())
	assert_true(window.is_open())
	assert_true(h.rig.is_cursor_free(), "the window is still open: the mouse is still its own")
	_step(h)
	assert_false(h.hud.get_node(^"Crosshair").visible)
	window.close()
	assert_false(h.rig.is_cursor_free(), "once closed, nobody is left asking for it")


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
	# A delayed snapshot (tick 100 < 120) still says "dead".
	h.client.fake_snapshot_tick = 100
	_step(h)
	assert_false(screen.is_open(), "a snapshot older than the respawn does not reopen it")
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
		assert_true(screen.is_open(), "cycle %d: open" % cycle)
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
		assert_false(screen.is_open(), "cycle %d: closed" % cycle)
		assert_false(h.hud.is_dimmed())
		assert_false(h.rig.is_cursor_free(), "cycle %d: cursor captured again" % cycle)
	assert_eq(h.client.respawn_requests.size(), 10)
	assert_eq(h.hud.find_children("*", "", true, false).size(), baseline_nodes,
			"the HUD does not accumulate nodes")
	assert_eq(h.hud.get_damage_numbers().get_active_count(), 0)
	assert_eq(h.hud.get_damage_indicator().get_arc_count(), 0)
	for item: CanvasItem in [h.hud.get_vitals(), h.hud.get_node(^"Crosshair"),
			h.hud.get_node(^"HintLabel")]:
		assert_eq(item.modulate.a, 1.0, "nothing is left dimmed")


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
	# A hit by a third party on another player: their nameplates show the health bar for a few seconds.
	h.hud.get_feedback().handle_event(NetMessages.EntityEvent.hit(OTHER_ID, 10, 33, 80, 0, 0, 2),
			false)
	assert_true(plates.was_damaged_recently(OTHER_ID), "damage to another marks their nameplate")
	assert_false(plates.was_damaged_recently(33), "and not the attacker's")


# --- Phase 4: knocked down, templates and bow -----------------------------------------------------

func _interact(downed_id: int, tick: int, actor: int, operation: int, ends: int) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.interact(downed_id, tick, actor, operation, ends)


func test_downed_notices_count_down_and_show_who_revives_or_executes_you() -> void:
	var h: HudRig = _make_hud()
	var notice: DownedNotice = h.hud.get_downed_notice()
	if not assert_not_null(notice, "the HUD has the knocked-down alerts"):
		return
	assert_true(notice.get_index() < h.hud.get_death_screen().get_index(), "below the death screen")
	h.client.get_remote_world().on_spawn(_remote_spawn(OTHER_ID, "Ana"))
	h.client.get_directory().remember(OTHER_ID, "Ana", NetProtocol.Realm.VARDHEIM)
	h.client.fake_estimated_tick = 1000
	_step(h)
	assert_false(notice.visible, "standing and with nobody knocked down nearby, nothing")
	# Knocked down: the extra block's health is the knocked-down health (300 of 400: 15 s at the bleed-out rate).
	h.client.combat_event.emit(NetMessages.EntityEvent.downed(OWN_ID, 1000, 33, 0), true)
	h.client.fake_downed = true
	h.client.fake_health = 300
	h.client.fake_max_health = 400
	_step(h)
	assert_true(notice.visible)
	assert_eq(notice.get_title_text(), CombatText.TEXT_DOWNED, "\"Derribado\" (knocked down)")
	assert_eq(notice.get_countdown_text(), CombatText.TEXT_DOWNED_COUNTDOWN % 15, "with the countdown")
	assert_false(h.hud.get_death_screen().is_open(), "knocked down is not dead: no death screen")
	# Ana starts to lift him (INTERACT 1, 180 ticks): "Ana te está levantando" (Ana is lifting you) with its bar.
	h.client.combat_event.emit(_interact(OWN_ID, 1000, OTHER_ID,
			NetMessages.EntityEvent.InteractOp.REVIVE, 1180), true)
	h.client.fake_estimated_tick = 1090
	_step(h)
	assert_eq(notice.get_detail_text(), CombatText.TEXT_BEING_REVIVED_BY % "Ana")
	assert_near(notice.get_progress(), 0.5, 0.01, "halfway up")
	# They cut it off (INTERACT 2): the bar goes away.
	h.client.combat_event.emit(_interact(OWN_ID, 1095, OTHER_ID,
			NetMessages.EntityEvent.InteractOp.REVIVE_CUT, 1180), true)
	_step(h)
	assert_eq(notice.get_detail_text(), "", "cut off, no bar")
	assert_eq(notice.get_progress(), -1.0)
	# An enemy starts to finish him off (INTERACT 4).
	h.client.combat_event.emit(_interact(OWN_ID, 1100, 33,
			NetMessages.EntityEvent.InteractOp.EXECUTE, 1160), true)
	h.client.fake_estimated_tick = 1130
	_step(h)
	assert_eq(notice.get_detail_text(), CombatText.TEXT_BEING_EXECUTED, "\"¡Te rematan!\" (they are finishing you off)")
	assert_near(notice.get_progress(), 0.5, 0.01)
	# Lifted (INTERACT 3) and standing again: nothing.
	h.client.combat_event.emit(_interact(OWN_ID, 1140, OTHER_ID,
			NetMessages.EntityEvent.InteractOp.REVIVED, 1140), true)
	h.client.fake_downed = false
	h.client.fake_health = 300
	h.client.fake_max_health = 1000
	_step(h)
	assert_false(notice.visible, "lifted, the alert goes away")


## Phase 4 review ("abilities" lens): the server lets one ally lift and one or more enemies
## finish off the same knocked-down player at the same time. The alert kept a single interaction and any cut or end
## erased it: the lifter's cut removed "¡Te rematan!" even though the finishing continued, and a lift that
## began during the finishing covered it. Now it keeps each one with its actor, only that actor's cut
## (or standing up) removes it, and the finishing is shown before the lift.
func test_the_downed_notice_keeps_each_interaction_until_its_own_actor_ends_it() -> void:
	var notice: DownedNotice = _track(DownedNotice.new()) as DownedNotice
	notice.set_own_id(OWN_ID)
	var names: Dictionary[int, String] = {7: "Ana", 9: "Bruno", 10: "Carla"}
	notice.name_of = func(net_id: int) -> String: return names.get(net_id, "")
	var op_revive: int = NetMessages.EntityEvent.InteractOp.REVIVE
	var op_execute: int = NetMessages.EntityEvent.InteractOp.EXECUTE
	# 1) Ana lifts (100-280) and Bruno finishes (105-165); Ana is cut off at 106: the finishing continues.
	notice.handle_event(_interact(OWN_ID, 100, 7, op_revive, 280))
	notice.handle_event(_interact(OWN_ID, 105, 9, op_execute, 165))
	notice.update_view(true, 300, 110)
	assert_eq(notice.get_detail_text(), CombatText.TEXT_BEING_EXECUTED, "the finishing goes before the lift")
	notice.handle_event(_interact(OWN_ID, 106, 7, NetMessages.EntityEvent.InteractOp.REVIVE_CUT, 106))
	assert_eq(notice.get_interaction(), DownedNotice.Interaction.BEING_EXECUTED, "Ana's cut does not remove it")
	notice.update_view(true, 300, 120)
	assert_eq(notice.get_detail_text(), CombatText.TEXT_BEING_EXECUTED, "\"¡Te rematan!\" continues")
	assert_near(notice.get_progress(), 0.25, 0.01, "with the bar of Bruno's finishing")
	notice.handle_event(_interact(OWN_ID, 130, 9, NetMessages.EntityEvent.InteractOp.EXECUTE_CUT, 130))
	notice.update_view(true, 300, 131)
	assert_eq(notice.get_detail_text(), "", "finishing cut off, nothing")
	# 2) Bruno finishes (200-260) and Ana starts lifting at 210: the finishing is still seen; when Bruno
	# is cut off, the lift that follows.
	notice.handle_event(_interact(OWN_ID, 200, 9, op_execute, 260))
	notice.handle_event(_interact(OWN_ID, 210, 7, op_revive, 390))
	notice.update_view(true, 300, 230)
	assert_eq(notice.get_detail_text(), CombatText.TEXT_BEING_EXECUTED, "a lift that begins does not cover the finishing")
	notice.handle_event(_interact(OWN_ID, 235, 9, NetMessages.EntityEvent.InteractOp.EXECUTE_CUT, 235))
	notice.update_view(true, 300, 240)
	assert_eq(notice.get_detail_text(), CombatText.TEXT_BEING_REVIVED_BY % "Ana",
			"finishing cut off, the following lift is seen")
	assert_near(notice.get_progress(), 30.0 / 180.0, 0.01)
	# 3) Two finishing: one's cut does not remove the other's finishing.
	notice.handle_event(_interact(OWN_ID, 250, 9, op_execute, 310))
	notice.handle_event(_interact(OWN_ID, 252, 10, op_execute, 312))
	notice.handle_event(_interact(OWN_ID, 255, 10, NetMessages.EntityEvent.InteractOp.EXECUTE_CUT, 255))
	notice.update_view(true, 300, 280)
	assert_eq(notice.get_detail_text(), CombatText.TEXT_BEING_EXECUTED, "Bruno's finishing continues")
	assert_near(notice.get_progress(), 0.5, 0.01)
	# Lifted: standing, they are no longer finished off or lifted.
	notice.handle_event(_interact(OWN_ID, 290, 7, NetMessages.EntityEvent.InteractOp.REVIVED, 290))
	assert_eq(notice.get_interaction(), DownedNotice.Interaction.NONE, "lifted, nothing")
	# 4) What he does: the cut of another who lifts the same ally does not remove "Levantando a Ana" (lifting Ana).
	notice.handle_event(_interact(7, 400, OWN_ID, op_revive, 580))
	notice.handle_event(_interact(7, 405, 10, NetMessages.EntityEvent.InteractOp.EXECUTE_CUT, 405))
	notice.update_view(false, 0, 445)
	assert_eq(notice.get_detail_text(), CombatText.TEXT_REVIVING % "Ana", "\"Levantando a Ana\" continues")
	assert_near(notice.get_progress(), 0.25, 0.01)
	notice.handle_event(_interact(7, 450, OWN_ID, NetMessages.EntityEvent.InteractOp.REVIVE_CUT, 450))
	notice.update_view(false, 0, 451)
	assert_eq(notice.get_detail_text(), "", "their own cut does")


func test_a_downed_ally_nearby_shows_the_revive_prompt() -> void:
	var h: HudRig = _make_hud()
	var notice: DownedNotice = h.hud.get_downed_notice()
	var remote_world: RemoteWorld = h.client.get_remote_world()
	remote_world.install_visuals = false
	var ally: NetMessages.EntitySpawn = _remote_spawn(OTHER_ID, "Bruno")
	ally.realm = NetProtocol.Realm.VARDHEIM
	ally.state.position = Vector3(1.2, 0.0, -1.0)
	remote_world.on_spawn(ally)
	h.client.get_directory().remember(OTHER_ID, "Bruno", NetProtocol.Realm.VARDHEIM)
	remote_world.draw(20.0, 0.0)
	_step(h)
	assert_eq(notice.get_prompt_text(), "", "standing, there is nothing to lift")
	var record: EntityRecord = EntityRecord.from_state(OTHER_ID, NetProtocol.EntityKind.PLAYER, ally.state, 0)
	record.action = CombatState.Action.DOWNED | (ActionMachine.PHASE_NONE << 4)
	remote_world.get_view(OTHER_ID).push(22, record)
	remote_world.draw(24.0, 0.0)
	_step(h)
	assert_eq(notice.get_prompt_text(), CombatText.TEXT_REVIVE_PROMPT % [
			UIKeyGlyph.label_for_action(&"interact"), "Bruno"], "\"Mantén E para levantar a Bruno\" (hold E to lift Bruno)")
	assert_eq(DownedNotice.find_downed_ally(remote_world, Vector3.ZERO, NetProtocol.Realm.SOLMARCH), 0,
			"a knocked-down player of another realm cannot be lifted")
	assert_eq(DownedNotice.find_downed_ally(remote_world, Vector3(0.0, 0.0, 5.0), NetProtocol.Realm.VARDHEIM),
			0, "nor one far away")
	# Lifting him (INTERACT 1 with the local player as actor): "Levantando a Bruno" (lifting Bruno).
	h.client.combat_event.emit(_interact(OTHER_ID, 30, OWN_ID,
			NetMessages.EntityEvent.InteractOp.REVIVE, 210), true)
	h.client.fake_estimated_tick = 75
	_step(h)
	assert_eq(notice.get_detail_text(), CombatText.TEXT_REVIVING % "Bruno")
	assert_near(notice.get_progress(), 0.25, 0.01)


func test_the_death_screen_template_selector_sends_the_loadout_select() -> void:
	var h: HudRig = _make_hud()
	var selector: TemplateSelector = h.hud.get_death_screen().get_template_selector()
	if not assert_not_null(selector, "the death screen has the template selector"):
		return
	var marksman: int = CombatCatalog.template_id(&"marksman")
	var squire: int = CombatCatalog.template_id(&"squire")
	assert_true(selector.get_template_ids().has(marksman) and selector.get_template_ids().has(squire),
			"it offers the squire and the marksman")
	assert_eq(selector.get_selected(), CombatCatalog.default_template_id(), "the default one is checked")
	assert_true(selector.get_button(marksman).text.begins_with("Tirador"), "with its name")
	assert_true(selector.get_button(marksman).text.contains("Arco"), "and its weapons")
	_die(h, 1000)
	assert_true(selector.choose(marksman))
	assert_eq(h.client.loadout_selects, [marksman] as Array[int], "choosing sends the LOADOUT_SELECT")
	assert_eq(selector.get_selected(), marksman)


func test_drawing_the_bow_zooms_the_camera_and_closes_the_reticle() -> void:
	var h: HudRig = _make_hud()
	var crosshair: Crosshair = h.hud.get_node(^"Crosshair") as Crosshair
	var bow: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(&"bow"))
	var drawn: AttackTicks = CombatCatalog.attack(bow.heavy_id)
	h.character.combat.copy_from(CombatState.initial(CombatCatalog.rules(), bow.id))
	h.character.combat.action = CombatState.Action.CHARGE
	h.character.combat.action_tick = 500
	h.character.last_input_tick = 500 + drawn.charge_min_ticks / 2
	_step(h)
	assert_near(h.rig.get_aim_zoom(), 0.5, 0.05, "the camera closes in while drawing")
	assert_eq(crosshair.get_tension(), 0.0, "the reticle not yet (below the minimum charge)")
	h.character.last_input_tick = 500 + drawn.charge_max_ticks
	_step(h)
	assert_eq(h.rig.get_aim_zoom(), 1.0, "drawn: the full zoom")
	assert_eq(crosshair.get_tension(), 1.0, "and the closed reticle")
	assert_true(crosshair.get_ring_radius() < crosshair.ring_radius)
	h.rig._process(10.0)
	assert_near(h.rig.get_camera().fov, h.rig.get_fov() * CameraRig.AIM_ZOOM_FOV_SCALE, 0.01,
			"at 75 % during the zoom, relative to the configured field of view")
	assert_eq(h.rig.get_fov(), 72.0, "which does not change")
	# With the sword, a charge does not zoom.
	h.character.combat.copy_from(CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"sword_shield")))
	h.character.combat.action = CombatState.Action.CHARGE
	_step(h)
	assert_eq(h.rig.get_aim_zoom(), 0.0)
	assert_eq(crosshair.get_tension(), 0.0)
	h.rig._process(10.0)
	assert_near(h.rig.get_camera().fov, 72.0, 0.01, "it returns to the configured field of view")


func test_the_kill_feed_shows_downed_players() -> void:
	var h: HudRig = _make_hud()
	var feed: KillFeed = h.hud.get_war_hud().get_kill_feed()
	h.client.get_directory().remember(OTHER_ID, "Ana", NetProtocol.Realm.SOLMARCH)
	h.client.get_directory().remember(33, "Bruno", NetProtocol.Realm.VARDHEIM)
	var drawn_source: int = CombatSource.make(CombatSource.Kind.ATTACK, CombatCatalog.attack_id(&"bow_drawn"))
	var text: String = feed.show_downed(NetMessages.EntityEvent.downed(33, 100, OTHER_ID, drawn_source))
	assert_eq(text, "Ana derribó a Bruno con un disparo tensado", "one line per knockdown")
	var slowing: int = CombatSource.make(CombatSource.Kind.ABILITY, CombatCatalog.ability_id(&"bow_slowing_shot"))
	assert_eq(CombatText.source_label(slowing), "una flecha lastrante", "the abilities have a name")
	assert_eq(CombatText.death_text(OTHER_ID, "Ana", CombatSource.EXECUTE), "Te ha rematado Ana.")
	assert_eq(CombatText.death_text(OTHER_ID, "Ana", CombatSource.BLEED_OUT), "Te has desangrado: te derribó Ana.")
	assert_eq(CombatText.death_text(0, "", CombatSource.BLEED_OUT), "Te has desangrado.")
