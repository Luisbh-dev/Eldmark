extends TestCase
## Pruebas de la sensación de combate del cliente (UI-12, ART-09 básico, CMB-11):
## [DpsMeter], [HitMarker], [DamageNumbers] (agrupación en 0,3 s y pool limitado) y
## [CombatFeedback] con eventos sintéticos: solo un golpe confirmado por el servidor produce
## marcador y número, la sacudida y el destello van a quien corresponde, los ganchos de sonido
## suenan, y la acción propia se detecta sin señales de la simulación (una corrección que repite
## ticks no duplica efectos).

const OWN_ID: int = 5
const OTHER_ID: int = 21
const THIRD_ID: int = 22
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"

var _root: Node3D
var _feedback: CombatFeedback
var _marker: HitMarker
var _numbers: DamageNumbers
var _canvas: CanvasLayer
var _rig: CameraRig
var _character: PlayerCharacter
var _sounds: Array[StringName] = []
var _dt: float = 1.0 / 60.0


func before_each() -> void:
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	_sounds.clear()
	_root = Node3D.new()
	_root.name = "CombatFeedbackTest"
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	if is_instance_valid(_canvas):
		tree.root.remove_child(_canvas)
		_canvas.free()
	_root = null
	_canvas = null
	_feedback = null
	_marker = null
	_numbers = null
	_rig = null
	_character = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _hit(victim: int, attacker: int, amount: int = 90, flags: int = 0, attack_id: int = 0,
		tick: int = 100) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.hit(victim, tick, attacker, amount, 0, flags, attack_id)


## Reparto con marcador, números, cámara y personaje local (sin cliente de red).
func _make_feedback(with_rig: bool = true) -> void:
	_canvas = CanvasLayer.new()
	tree.root.add_child(_canvas)
	_marker = HitMarker.new()
	_canvas.add_child(_marker)
	_numbers = DamageNumbers.new()
	_canvas.add_child(_numbers)
	_character = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_root.add_child(_character)
	_character.position = Vector3(0.0, 0.0, 0.0)
	var mesh := MeshInstance3D.new()
	mesh.name = "Cuerpo"
	mesh.mesh = CapsuleMesh.new()
	_character.add_child(mesh)
	if with_rig:
		_rig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
		_rig.set_scripted_look(true)
		_root.add_child(_rig)
	_feedback = CombatFeedback.new()
	_root.add_child(_feedback)
	_feedback.setup(null, _rig, _character, _marker, _numbers)
	_feedback.set_own_net_id(OWN_ID)
	# Sin cliente no hay vistas de remotos: todos están en el mismo sitio, delante del jugador.
	_feedback.position_resolver = func(_net_id: int) -> Vector3: return Vector3(0.0, 0.0, -3.0)
	_feedback.sound_requested.connect(func(sound: StringName, _at: Vector3) -> void:
		_sounds.append(sound))


# --- DpsMeter ---------------------------------------------------------------------------------

func test_dps_meter_sums_the_window_and_divides_by_the_elapsed_time() -> void:
	var meter := DpsMeter.new()
	assert_eq(meter.get_dps(100), 0.0, "sin golpes no hay DPS")
	meter.add_hit(60, 100)
	assert_near(meter.get_dps(60), 100.0, 0.001, "un golpe: como poco 1 s")
	meter.add_hit(120, 100)
	meter.add_hit(180, 100)
	assert_eq(meter.get_damage(180), 300)
	assert_near(meter.get_dps(180), 150.0, 0.001, "300 de daño en 2 s")
	assert_eq(meter.get_hit_count(180), 3)


func test_dps_meter_over_a_full_window_matches_the_expected_figure() -> void:
	# Un golpe de 90 por segundo durante 40 s: la ventana de 30 s da 90 de DPS.
	var meter := DpsMeter.new()
	for second: int in 40:
		meter.add_hit(60 * (second + 1), 90)
	var now: int = 60 * 40
	assert_eq(meter.get_hit_count(now), 30, "solo caben los golpes de la ventana de 30 s")
	assert_near(meter.get_dps(now), 90.0, 0.001, "tras 30 s seguidos, el daño de la ventana entre 30")
	assert_eq(meter.get_total_damage(), 40 * 90, "el total desde el principio no se pierde")
	assert_eq(meter.get_total_hits(), 40)


func test_dps_meter_forgets_old_hits_and_ignores_zero_damage() -> void:
	var meter := DpsMeter.new()
	meter.add_hit(10, 500)
	meter.add_hit(20, 0)
	meter.add_hit(30, -5)
	assert_eq(meter.get_hit_count(100), 1, "los golpes sin daño no cuentan")
	assert_eq(meter.get_damage(10 + DpsMeter.WINDOW_TICKS - 1), 500, "dentro de la ventana")
	assert_eq(meter.get_damage(10 + DpsMeter.WINDOW_TICKS), 0, "pasada la ventana se olvida")
	assert_eq(meter.get_dps(10 + DpsMeter.WINDOW_TICKS), 0.0)
	meter.add_hit(5000, 10)
	meter.reset()
	assert_eq(meter.get_total_damage(), 0)
	assert_eq(meter.get_dps(5000), 0.0)


# --- HitMarker --------------------------------------------------------------------------------

func test_hit_marker_shows_each_variant_and_fades() -> void:
	var marker := HitMarker.new()
	_root.add_child(marker)
	assert_false(marker.is_active())
	assert_eq(marker.get_alpha(), 0.0)
	for kind: int in [HitMarker.Kind.HIT, HitMarker.Kind.HEAVY, HitMarker.Kind.BLOCKED,
			HitMarker.Kind.KILL]:
		marker.show_marker(kind)
		assert_true(marker.is_active())
		assert_eq(marker.get_variant(), kind)
		assert_eq(marker.get_alpha(), 1.0, "recién enseñado, opaco")
		marker.advance(HitMarker.DURATIONS[kind] * 0.5)
		assert_near(marker.get_alpha(), 0.5, 0.01, "a media vida, medio opaco")
		marker.advance(HitMarker.DURATIONS[kind])
		assert_false(marker.is_active(), "y desaparece")
	assert_true(HitMarker.DURATIONS[HitMarker.Kind.KILL] > HitMarker.DURATIONS[HitMarker.Kind.HIT],
			"el de muerte dura más")


func test_hit_marker_can_be_disabled() -> void:
	var marker := HitMarker.new()
	_root.add_child(marker)
	marker.enabled = false
	marker.show_marker(HitMarker.Kind.HIT)
	assert_false(marker.is_active(), "desactivado no enseña nada")
	assert_eq(marker.get_shown_count(), 0)
	marker.enabled = true
	marker.show_marker(HitMarker.Kind.HIT)
	assert_true(marker.is_active())
	marker.enabled = false
	assert_false(marker.is_active(), "y al desactivarlo se quita el que hubiera")


# --- DamageNumbers ----------------------------------------------------------------------------

func test_damage_numbers_group_hits_on_the_same_target_within_the_window() -> void:
	var numbers := DamageNumbers.new()
	_root.add_child(numbers)
	var first: Label = numbers.add_number(OTHER_ID, Vector3.ZERO, 90)
	numbers.advance(0.1)
	var second: Label = numbers.add_number(OTHER_ID, Vector3.ZERO, 90)
	assert_true(first == second, "el segundo golpe se suma al mismo número")
	assert_eq(numbers.get_active_count(), 1)
	assert_eq(numbers.get_number_amount(0), 180)
	assert_eq(numbers.get_number_hits(0), 2)
	assert_eq(numbers.get_number_text(0), "180")
	numbers.advance(0.15)
	numbers.add_number(OTHER_ID, Vector3.ZERO, 30)
	assert_eq(numbers.get_active_count(), 1, "0,25 s después del primero aún se agrupa")
	assert_eq(numbers.get_number_amount(0), 210)
	numbers.advance(0.1)
	numbers.add_number(OTHER_ID, Vector3.ZERO, 40)
	assert_eq(numbers.get_active_count(), 2, "pasados 0,3 s del primero sale otro número")
	assert_eq(numbers.get_number_amount(1), 40)
	assert_eq(numbers.get_spawned_count(), 2)


func test_damage_numbers_do_not_group_different_targets_or_directions() -> void:
	var numbers := DamageNumbers.new()
	_root.add_child(numbers)
	numbers.add_number(OTHER_ID, Vector3.ZERO, 90)
	numbers.add_number(THIRD_ID, Vector3.ZERO, 90)
	numbers.add_number(OTHER_ID, Vector3.ZERO, 50, DamageNumbers.Kind.HIT, true)
	assert_eq(numbers.get_active_count(), 3, "objetivos distintos y daño dado/recibido no se mezclan")


func test_damage_numbers_pool_is_bounded_and_recycles_the_oldest() -> void:
	var numbers := DamageNumbers.new()
	_root.add_child(numbers)
	for i: int in DamageNumbers.MAX_NUMBERS + 8:
		numbers.add_number(100 + i, Vector3.ZERO, i + 1)
	assert_eq(numbers.get_pool_size(), DamageNumbers.MAX_NUMBERS, "nunca más etiquetas que el tope")
	assert_eq(numbers.get_active_count(), DamageNumbers.MAX_NUMBERS)
	assert_eq(numbers.get_number_amount(0), 9, "se reciclaron los 8 más antiguos")
	assert_eq(numbers.get_number_amount(DamageNumbers.MAX_NUMBERS - 1),
			DamageNumbers.MAX_NUMBERS + 8)
	var children: int = numbers.get_child_count()
	numbers.advance(DamageNumbers.LIFETIME_SECONDS + 0.1)
	assert_eq(numbers.get_active_count(), 0, "al acabar su vida vuelven al pool")
	numbers.add_number(1, Vector3.ZERO, 5)
	assert_eq(numbers.get_pool_size(), DamageNumbers.MAX_NUMBERS, "y se reutilizan")
	assert_eq(numbers.get_child_count(), children, "sin crear nodos nuevos")


func test_damage_numbers_can_be_disabled_and_show_custom_text() -> void:
	var numbers := DamageNumbers.new()
	_root.add_child(numbers)
	var label: Label = numbers.add_number(OTHER_ID, Vector3.ZERO, 0, DamageNumbers.Kind.BLOCKED,
			false, false, "Bloqueado")
	assert_eq(label.text, "Bloqueado")
	numbers.add_number(THIRD_ID, Vector3.ZERO, 120, DamageNumbers.Kind.HEAVY, false, true)
	assert_eq(numbers.get_number_text(1), "120!", "un crítico lleva la exclamación")
	numbers.enabled = false
	assert_eq(numbers.get_active_count(), 0, "desactivar quita los que había")
	assert_null(numbers.add_number(OTHER_ID, Vector3.ZERO, 10), "y no se crea ninguno")
	assert_eq(numbers.get_active_count(), 0)


# --- CombatFeedback: golpes -------------------------------------------------------------------

func test_own_confirmed_hit_shows_marker_number_and_counts_dps() -> void:
	_make_feedback()
	var kills: Array[int] = []
	_feedback.hit_confirmed.connect(func(kind: int, amount: int, _e: NetMessages.EntityEvent) -> void:
		kills.append(kind * 1000 + amount))
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90, 0, CombatCatalog.attack_id(&"sword_light_1")),
			true)
	assert_true(_marker.is_active(), "marcador al confirmarse el golpe")
	assert_eq(_marker.get_variant(), HitMarker.Kind.HIT)
	assert_eq(kills, [HitMarker.Kind.HIT * 1000 + 90] as Array[int])
	assert_eq(_feedback.get_damage_in_window(), 90, "el DPS suma el daño")
	assert_true(_sounds.has(CombatFeedback.SOUND_HIT_DEALT), "y suena el gancho del golpe")
	assert_false(_rig.is_shaking(), "dar un golpe no sacude la cámara")


func test_hit_variants_follow_the_flags_and_the_attack() -> void:
	_make_feedback()
	var heavy: int = CombatCatalog.attack_id(&"sword_heavy")
	var light: int = CombatCatalog.attack_id(&"sword_light_1")
	assert_eq(_feedback.kind_of(_hit(OTHER_ID, OWN_ID, 90, 0, light)), HitMarker.Kind.HIT)
	assert_eq(_feedback.kind_of(_hit(OTHER_ID, OWN_ID, 200, 0, heavy)), HitMarker.Kind.HEAVY)
	assert_eq(_feedback.kind_of(_hit(OTHER_ID, OWN_ID, 0, NetMessages.EntityEvent.HIT_FLAG_BLOCKED,
			heavy)), HitMarker.Kind.BLOCKED, "bloqueado pesa más que fuerte")
	assert_eq(_feedback.kind_of(_hit(OTHER_ID, OWN_ID, 0, NetMessages.EntityEvent.HIT_FLAG_PARRIED,
			light)), HitMarker.Kind.BLOCKED)
	assert_eq(_feedback.kind_of(_hit(OTHER_ID, OWN_ID, 90, NetMessages.EntityEvent.HIT_FLAG_LETHAL
			| NetMessages.EntityEvent.HIT_FLAG_BLOCKED, light)), HitMarker.Kind.KILL,
			"y matar pesa más que todo")
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 0, NetMessages.EntityEvent.HIT_FLAG_PARRIED), true)
	assert_eq(_numbers.get_number_text(0), CombatFeedback.TEXT_PARRIED)
	assert_true(_sounds.has(CombatFeedback.SOUND_PARRY))
	_feedback.handle_event(_hit(THIRD_ID, OWN_ID, 0, NetMessages.EntityEvent.HIT_FLAG_BLOCKED), true)
	assert_eq(_numbers.get_number_text(1), CombatFeedback.TEXT_BLOCKED)
	assert_eq(_feedback.get_damage_in_window(), 0, "lo bloqueado y parado no suma DPS")


func test_events_of_others_do_not_produce_marker_number_or_shake() -> void:
	_make_feedback()
	_feedback.handle_event(_hit(OTHER_ID, THIRD_ID, 90), false)
	assert_false(_marker.is_active(), "un golpe entre otros no marca nada")
	assert_eq(_numbers.get_active_count(), 0, "ni saca número")
	assert_false(_rig.is_shaking(), "ni sacude la cámara")
	assert_eq(_feedback.get_damage_in_window(), 0, "ni cuenta para el DPS")
	assert_eq(_feedback.get_events_handled(), 1)


func test_nothing_happens_without_a_confirmed_event() -> void:
	_make_feedback()
	await wait_physics_frames(5)
	assert_false(_marker.is_active(), "sin evento no hay marcador")
	assert_eq(_numbers.get_active_count(), 0, "ni número")
	assert_eq(_feedback.get_dps(), 0.0)


func test_damage_taken_shakes_the_camera_and_signals_the_attacker() -> void:
	_make_feedback()
	var taken: Array[Vector2i] = []
	_feedback.damage_taken.connect(func(amount: int, attacker: int, _e: NetMessages.EntityEvent) -> void:
		taken.append(Vector2i(amount, attacker)))
	_feedback.handle_event(_hit(OWN_ID, OTHER_ID, 120), true)
	assert_eq(taken, [Vector2i(120, OTHER_ID)] as Array[Vector2i])
	assert_true(_rig.is_shaking(), "la cámara se sacude al recibir")
	assert_false(_marker.is_active(), "y el marcador de impacto es de los golpes propios")
	assert_eq(_numbers.get_active_count(), 1, "el daño recibido sale como número rojo")
	assert_true(_sounds.has(CombatFeedback.SOUND_HIT_TAKEN))
	assert_eq(_feedback.get_damage_in_window(), 0, "y no cuenta para el DPS")


func test_camera_shake_decays_and_respects_the_option() -> void:
	_make_feedback()
	_rig.add_shake(0.1, 0.2)
	await wait_process_frames(2)
	assert_true(_rig.is_shaking())
	assert_true(_rig.get_shake_offset().length() <= 0.1 + 0.0001, "no pasa de la amplitud pedida")
	_rig.add_shake(5.0, 0.2)
	await wait_process_frames(1)
	assert_true(_rig.get_shake_offset().length() <= CameraRig.MAX_SHAKE_AMPLITUDE + 0.0001,
			"y hay un tope")
	var waited: int = 0
	while _rig.is_shaking() and waited < 120:
		await wait_process_frames(1)
		waited += 1
	assert_false(_rig.is_shaking(), "dura poco")
	await wait_process_frames(1)
	assert_eq(_rig.get_shake_offset(), Vector2.ZERO, "y vuelve a 0")
	_feedback.camera_shake_enabled = false
	_feedback.handle_event(_hit(OWN_ID, OTHER_ID, 120), true)
	assert_false(_rig.is_shaking(), "con la opción apagada no se sacude")
	_rig.shake_enabled = false
	_rig.add_shake(0.1, 0.2)
	assert_false(_rig.is_shaking(), "tampoco desde la propia cámara")


func test_flash_tints_the_victim_briefly_and_cleans_up() -> void:
	_make_feedback()
	var mesh: MeshInstance3D = _character.get_node(^"Cuerpo") as MeshInstance3D
	assert_null(mesh.material_overlay)
	_feedback.handle_event(_hit(OWN_ID, OTHER_ID, 50), true)
	assert_not_null(mesh.material_overlay, "la víctima destella")
	assert_true(_feedback.get_flashing_count() >= 1, "con todas las mallas visibles de su cuerpo")
	_feedback.advance_flashes(CombatFeedback.FLASH_SECONDS * 0.5)
	assert_not_null(mesh.material_overlay, "a medias sigue")
	_feedback.advance_flashes(CombatFeedback.FLASH_SECONDS)
	assert_null(mesh.material_overlay, "y se quita al acabar")
	assert_eq(_feedback.get_flashing_count(), 0)
	for node: Node in _character.find_children("*", "MeshInstance3D", true, false):
		assert_null((node as MeshInstance3D).material_overlay, "ninguna malla se queda teñida")
	_feedback.flash_enabled = false
	_feedback.handle_event(_hit(OWN_ID, OTHER_ID, 50), true)
	assert_null(mesh.material_overlay, "sin destello si el jugador lo apaga")


func test_entity_damaged_is_emitted_for_every_hit_with_damage() -> void:
	_make_feedback()
	var damaged: Array[int] = []
	_feedback.entity_damaged.connect(func(net_id: int) -> void: damaged.append(net_id))
	_feedback.handle_event(_hit(OTHER_ID, THIRD_ID, 40), false)
	_feedback.handle_event(_hit(OWN_ID, THIRD_ID, 40), true)
	_feedback.handle_event(_hit(OTHER_ID, THIRD_ID, 0, NetMessages.EntityEvent.HIT_FLAG_BLOCKED), false)
	assert_eq(damaged, [OTHER_ID, OWN_ID] as Array[int], "lo bloqueado sin daño no cuenta")


func test_death_kill_and_respawn_signals() -> void:
	_make_feedback()
	var deaths: Array[Vector2i] = []
	var kills: Array[int] = []
	var respawns: Array[int] = []
	_feedback.local_died.connect(func(killer: int, attack: int) -> void:
		deaths.append(Vector2i(killer, attack)))
	_feedback.kill_confirmed.connect(func(victim: int, _e: NetMessages.EntityEvent) -> void:
		kills.append(victim))
	_feedback.local_respawned.connect(func(point: int, _tick: int) -> void: respawns.append(point))
	_feedback.handle_event(NetMessages.EntityEvent.death(OTHER_ID, 100, THIRD_ID, 3), false)
	assert_eq(deaths.size(), 0, "la muerte de otro no es la propia")
	_feedback.handle_event(NetMessages.EntityEvent.death(OWN_ID, 100, OTHER_ID, 3), true)
	assert_eq(deaths, [Vector2i(OTHER_ID, 3)] as Array[Vector2i])
	_feedback.handle_event(NetMessages.EntityEvent.kill(OTHER_ID, 100, OWN_ID, 3,
			PackedInt32Array()), true)
	assert_eq(kills, [OTHER_ID] as Array[int])
	_feedback.handle_event(NetMessages.EntityEvent.kill(OTHER_ID, 100, THIRD_ID, 3,
			PackedInt32Array([OWN_ID])), true)
	assert_eq(kills.size(), 1, "un asistente no es el asesino")
	_feedback.handle_event(NetMessages.EntityEvent.respawn(THIRD_ID, 100, 0), false)
	assert_eq(respawns.size(), 0)
	_feedback.handle_event(NetMessages.EntityEvent.respawn(OWN_ID, 100, 2), true)
	assert_eq(respawns, [2] as Array[int])
	assert_true(_sounds.has(CombatFeedback.SOUND_DEATH))
	assert_true(_sounds.has(CombatFeedback.SOUND_RESPAWN))
	assert_true(_sounds.has(CombatFeedback.SOUND_KILL))


func test_options_disable_marker_and_numbers() -> void:
	_make_feedback()
	_feedback.hit_markers_enabled = false
	_feedback.damage_numbers_enabled = false
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90), true)
	assert_false(_marker.is_active())
	assert_eq(_numbers.get_active_count(), 0)
	assert_eq(_feedback.get_damage_in_window(), 90, "el DPS se mide igual")
	_feedback.hit_markers_enabled = true
	_feedback.damage_numbers_enabled = true
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90), true)
	assert_true(_marker.is_active())
	assert_eq(_numbers.get_active_count(), 1)


func test_dps_through_the_feedback_matches_the_expected_combo_figure() -> void:
	_make_feedback()
	var light: int = CombatCatalog.attack_id(&"sword_light_1")
	# Un golpe de 90 cada 36 ticks (el ligero 1 sin enlazar) durante 30 s.
	var tick: int = 100
	var total: int = 0
	while tick < 100 + DpsMeter.WINDOW_TICKS - 36:
		_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90, 0, light, tick), true)
		total += 90
		tick += 36
	assert_eq(_feedback.get_damage_in_window(), total)
	assert_near(_feedback.get_dps_meter().get_dps(tick), float(total) / 30.0, 3.0,
			"el DPS medido coincide con el calculado a partir de los datos")


# --- Los eventos propios sobre un remoto esperan a su tick de dibujo ---------------------------

## Reloj de dibujo que dice el tick que quiere la prueba.
class FakeClock extends InterpolationClock:
	var fake_render_tick: float = 0.0

	func get_render_tick() -> float:
		return fake_render_tick


## Cliente de red que no conecta con nada: da el id propio y el reloj falso.
class FakeClient extends NetClient:
	var fake_clock: FakeClock = FakeClock.new()

	func get_net_id() -> int:
		return OWN_ID

	func get_interpolation_clock() -> InterpolationClock:
		return fake_clock


func _remote_spawn(net_id: int) -> NetMessages.EntitySpawn:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = NetProtocol.EntityKind.PLAYER
	spawn.spawn_tick = 10
	spawn.realm = NetProtocol.Realm.SOLMARCH
	spawn.display_name = "Remoto%d" % net_id
	var state := PlayerState.new()
	state.position = Vector3(0.0, 0.0, -6.0)
	state.grounded = true
	spawn.state = state
	return spawn


## Reparto con un cliente falso y un remoto ([constant OTHER_ID]) con su cuerpo, para que su
## destello y su posición existan. El reloj de dibujo empieza en [param render_tick].
func _make_feedback_with_remote(render_tick: float) -> FakeClient:
	_make_feedback()
	var client := FakeClient.new()
	client.fake_clock.fake_render_tick = render_tick
	_root.add_child(client)
	client.get_remote_world().on_spawn(_remote_spawn(OTHER_ID))
	_feedback.position_resolver = Callable()
	_feedback.setup(client, _rig, _character, _marker, _numbers)
	return client


## Un paso de física del reparto con el reloj de dibujo en [param render_tick].
func _step_feedback(client: FakeClient, render_tick: float) -> void:
	client.fake_clock.fake_render_tick = render_tick
	_feedback._physics_process(_dt)


func test_an_own_hit_on_a_remote_shows_the_flash_when_the_draw_tick_reaches_it() -> void:
	# C3/T6: el HIT propio llega nada más producirse, pero el remoto se dibuja unos ticks por detrás:
	# marcador y número salen ya, el destello y la placa esperan a que se le vea recibir el golpe.
	var client: FakeClient = _make_feedback_with_remote(92.0)
	var damaged: Array[int] = []
	_feedback.entity_damaged.connect(func(net_id: int) -> void: damaged.append(net_id))
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90, 0, 0, 100), true)
	assert_true(_marker.is_active(), "el marcador sale al llegar")
	assert_eq(_numbers.get_active_count(), 1, "y el número")
	assert_eq(_feedback.get_damage_in_window(), 90, "y el DPS")
	assert_eq(_feedback.get_flashing_count(), 0, "pero el remoto todavía no ha recibido el golpe")
	assert_true(damaged.is_empty(), "ni su placa de vida se ha enterado")
	_step_feedback(client, 99.0)
	assert_eq(_feedback.get_flashing_count(), 0, "un tick antes, nada")
	_step_feedback(client, 100.0)
	assert_true(_feedback.get_flashing_count() >= 1, "al llegar el tick de dibujo al del golpe, destella")
	assert_eq(damaged, [OTHER_ID] as Array[int], "y su placa enseña la vida")
	_step_feedback(client, 101.0)
	assert_eq(damaged.size(), 1, "una sola vez")


func test_own_death_and_kill_sounds_of_a_remote_wait_for_the_draw_tick() -> void:
	var client: FakeClient = _make_feedback_with_remote(80.0)
	_feedback.handle_event(NetMessages.EntityEvent.death(OTHER_ID, 100, OWN_ID, 2), true)
	_feedback.handle_event(NetMessages.EntityEvent.kill(OTHER_ID, 100, OWN_ID, 2, PackedInt32Array()),
			true)
	assert_false(_sounds.has(CombatFeedback.SOUND_DEATH), "no suena la muerte de quien aún se ve vivo")
	assert_false(_sounds.has(CombatFeedback.SOUND_KILL))
	_step_feedback(client, 100.0)
	assert_true(_sounds.has(CombatFeedback.SOUND_DEATH), "suena cuando se le ve caer")
	assert_true(_sounds.has(CombatFeedback.SOUND_KILL))


func test_what_is_about_the_local_player_or_already_due_is_not_delayed() -> void:
	var client: FakeClient = _make_feedback_with_remote(80.0)
	var damaged: Array[int] = []
	_feedback.entity_damaged.connect(func(net_id: int) -> void: damaged.append(net_id))
	# El local es la víctima: no hay un remoto que esperar.
	_feedback.handle_event(_hit(OWN_ID, OTHER_ID, 90, 0, 0, 100), true)
	assert_true(_feedback.get_flashing_count() >= 1, "el golpe recibido destella al llegar")
	assert_eq(damaged, [OWN_ID] as Array[int])
	_feedback.advance_flashes(CombatFeedback.FLASH_SECONDS * 2.0)
	assert_eq(_feedback.get_flashing_count(), 0)
	# Un evento ajeno ya viene temporizado por NetClient: se aplica tal cual.
	_feedback.handle_event(_hit(OTHER_ID, 33, 40, 0, 0, 100), false)
	assert_true(_feedback.get_flashing_count() >= 1, "un evento ajeno no espera otra vez")
	_feedback.advance_flashes(CombatFeedback.FLASH_SECONDS * 2.0)
	# Un golpe propio cuyo tick ya se ha dibujado destella enseguida.
	client.fake_clock.fake_render_tick = 120.0
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90, 0, 0, 100), true)
	assert_true(_feedback.get_flashing_count() >= 1, "si el remoto ya está en ese tick, no hay espera")


func test_rebinding_the_feedback_drops_the_pending_reactions() -> void:
	var client: FakeClient = _make_feedback_with_remote(50.0)
	_feedback.handle_event(_hit(OTHER_ID, OWN_ID, 90, 0, 0, 100), true)
	_feedback.setup(client, _rig, _character, _marker, _numbers)
	_step_feedback(client, 200.0)
	assert_eq(_feedback.get_flashing_count(), 0, "lo pendiente de la conexión anterior se descarta")


# --- CombatFeedback: acciones propias sin señales ---------------------------------------------

func _floor() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	body.add_child(shape)
	_root.add_child(body)


func _input(tick: int, buttons: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.buttons = buttons
	return input.quantized()


func test_own_actions_are_detected_without_simulation_signals() -> void:
	_floor()
	_make_feedback(false)
	await wait_physics_frames(3)
	_feedback.observe_action()
	var changes: Array[int] = []
	var swings: Array[bool] = []
	_feedback.action_changed.connect(func(action: int, _id: int, _t: int, _prev: int) -> void:
		changes.append(action))
	_feedback.swing_active_changed.connect(func(active: bool, _id: int) -> void:
		swings.append(active))
	var light: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"sword_light_1"))
	var tick: int = 1000
	for i: int in light.total_ticks + 4:
		await wait_physics_frames(1)
		tick += 1
		_character.simulate(_input(tick, PlayerInput.PRIMARY if i < 3 else 0), _dt)
		_feedback.observe_action()
	assert_eq(changes, [CombatState.Action.LIGHT, CombatState.Action.NONE] as Array[int],
			"empieza el ligero y acaba")
	assert_eq(swings, [true, false] as Array[bool], "el barrido se lanza y se corta una vez")
	assert_true(_sounds.has(CombatFeedback.SOUND_SWING))
	assert_false(_feedback.is_swing_active())


func test_swing_follows_the_active_window_exactly() -> void:
	_floor()
	_make_feedback(false)
	await wait_physics_frames(3)
	_feedback.observe_action()
	var light: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"sword_light_1"))
	var active_ticks: Array[int] = []
	var tick: int = 2000
	# Unos ticks quietos para que el personaje pise el suelo (en el aire no se ataca).
	for _i: int in 4:
		await wait_physics_frames(1)
		tick += 1
		_character.simulate(_input(tick, 0), _dt)
	for i: int in light.total_ticks + 2:
		await wait_physics_frames(1)
		tick += 1
		_character.simulate(_input(tick, PlayerInput.PRIMARY if i < 3 else 0), _dt)
		_feedback.observe_action()
		if _feedback.is_swing_active():
			active_ticks.append(i)
	assert_eq(active_ticks.size(), light.active_ticks, "activo durante los ticks del golpe")
	assert_eq(active_ticks[0], light.windup_ticks, "empieza justo al acabar la anticipación")


func test_replaying_ticks_does_not_duplicate_action_effects() -> void:
	_floor()
	_make_feedback(false)
	await wait_physics_frames(3)
	_feedback.observe_action()
	var changes: Array[int] = []
	_feedback.action_changed.connect(func(action: int, _id: int, _t: int, _prev: int) -> void:
		changes.append(action))
	# Se juega hasta mitad del ligero y se anota el estado.
	var tick: int = 3000
	await wait_physics_frames(1)
	var saved: PlayerState = _character.get_state()
	var inputs: Array[PlayerInput] = []
	for i: int in 8:
		tick += 1
		inputs.append(_input(tick, PlayerInput.PRIMARY if i < 3 else 0))
	for input: PlayerInput in inputs:
		await wait_physics_frames(1)
		_character.simulate(input, _dt)
	_feedback.observe_action()
	assert_eq(changes.size(), 1, "una sola acción empezada")
	# La reconciliación repite los mismos ticks desde el estado guardado, dentro de un mismo tick.
	await wait_physics_frames(1)
	_character.set_state(saved)
	for input: PlayerInput in inputs:
		_character.simulate(input, _dt)
	_feedback.observe_action()
	assert_eq(changes.size(), 1, "repetir los ticks no repite el efecto: la clave es la misma")


func test_a_correction_that_shifts_the_start_of_a_dodge_does_not_repeat_the_effects() -> void:
	# T5: la entrada del flanco de la esquiva se pierde y el servidor la sustituye (repite los botones
	# anteriores): esquiva un tick después. Al adoptar su estado el tick de inicio cambia de 1 tick, pero
	# es la misma esquiva: un solo aviso y un solo sonido.
	_floor()
	_make_feedback(false)
	await wait_physics_frames(3)
	_feedback.observe_action()
	var dodges: Array[int] = []
	_feedback.action_changed.connect(func(action: int, _id: int, tick: int, _prev: int) -> void:
		if action == CombatState.Action.DODGE:
			dodges.append(tick))
	# Unos ticks quietos para que el personaje aterrice antes de esquivar.
	for i: int in 12:
		await wait_physics_frames(1)
		_character.simulate(_input(4980 + i, 0), _dt)
	var saved: PlayerState = _character.get_state()
	var first_tick: int = 5001
	# El cliente predice: pulsa esquivar en el tick 5001 y la mantiene 4 ticks.
	for i: int in 6:
		await wait_physics_frames(1)
		_character.simulate(_input(first_tick + i, PlayerInput.DODGE if i < 4 else 0), _dt)
		_feedback.observe_action()
	assert_eq(dodges, [first_tick] as Array[int], "la predicción empieza la esquiva en su tick")
	assert_eq(_sounds.count(CombatFeedback.SOUND_DODGE), 1)
	# El servidor no recibió la entrada del 5001 (la sustituta repite los botones previos: ninguno) y
	# ve el flanco un tick después, con el botón aún pulsado. La reconciliación adopta ese estado.
	await wait_physics_frames(1)
	_character.set_state(saved)
	for i: int in 6:
		_character.simulate(_input(first_tick + i, PlayerInput.DODGE if i >= 1 and i < 5 else 0), _dt)
	assert_eq(_character.combat.action_tick, first_tick + 1, "el servidor esquivó un tick más tarde")
	_feedback.observe_action()
	assert_eq(dodges, [first_tick] as Array[int], "no hay un segundo aviso de la misma esquiva")
	assert_eq(_sounds.count(CombatFeedback.SOUND_DODGE), 1, "ni un segundo sonido")


func test_two_dodges_chained_by_the_buffer_are_two_actions() -> void:
	_floor()
	_make_feedback(false)
	await wait_physics_frames(3)
	_feedback.observe_action()
	var dodges: Array[int] = []
	_feedback.action_changed.connect(func(action: int, _id: int, tick: int, _prev: int) -> void:
		if action == CombatState.Action.DODGE:
			dodges.append(tick))
	var first_tick: int = 6001
	# Esquivar y, durante ella, otra pulsación: la segunda sale del búfer al acabar la primera.
	for i: int in 60:
		await wait_physics_frames(1)
		var pressed: bool = i < 2 or (i >= 21 and i < 23)
		_character.simulate(_input(first_tick + i, PlayerInput.DODGE if pressed else 0), _dt)
		_feedback.observe_action()
	assert_eq(dodges.size(), 2, "dos esquivas, dos avisos")
	assert_eq(_sounds.count(CombatFeedback.SOUND_DODGE), 2, "y dos sonidos")


func test_a_new_attack_in_the_combo_is_a_new_action() -> void:
	_floor()
	_make_feedback(false)
	await wait_physics_frames(3)
	_feedback.observe_action()
	var ids: Array[int] = []
	_feedback.action_changed.connect(func(action: int, id: int, _t: int, _prev: int) -> void:
		if action == CombatState.Action.LIGHT:
			ids.append(id))
	var light1: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"sword_light_1"))
	var tick: int = 4000
	# Primer ligero, y otra pulsación dentro de su ventana de enlace.
	var link_press: int = light1.combo_window_from() + 2
	for i: int in light1.total_ticks + 10:
		await wait_physics_frames(1)
		tick += 1
		var pressed: bool = i < 3 or (i >= link_press and i < link_press + 3)
		_character.simulate(_input(tick, PlayerInput.PRIMARY if pressed else 0), _dt)
		_feedback.observe_action()
	assert_eq(ids, [CombatCatalog.attack_id(&"sword_light_1"),
			CombatCatalog.attack_id(&"sword_light_2")] as Array[int], "el combo encadena el segundo")
