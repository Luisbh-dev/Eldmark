extends TestCase
## Pruebas de las placas de nombre y vida ([Nameplates], UI-07 y UI-13) con remotos sintéticos
## ([RemoteWorld]) y la cámara de acción de verdad: quién tiene placa (aliados cerca, enemigos solo
## apuntados o dañados hace poco), qué enseña cada una (nombre, color de reino, barra desde
## health_q), la oclusión con rayos espaciados, el pool limitado y que la placa queda anclada a la
## cabeza proyectada del remoto.

const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const OWN_ID: int = 5
const ALLY_ID: int = 31
const ENEMY_ID: int = 41
const OTHER_ENEMY_ID: int = 42


## Reloj cuyo tick de dibujo se fija desde la prueba.
class FakeClock extends InterpolationClock:
	var render: float = 0.0

	func get_render_tick() -> float:
		return render


var _root: Node3D
var _remote_world: RemoteWorld
var _clock: FakeClock
var _rig: CameraRig
var _canvas: CanvasLayer
var _plates: Nameplates
var _wall: StaticBody3D
## Tick del servidor de la última muestra de los remotos (cada cambio es una muestra nueva).
var _tick: int = 1


func before_each() -> void:
	_root = Node3D.new()
	_root.name = "NameplatesTest"
	tree.root.add_child(_root)
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	floor_shape.shape = box
	floor_shape.position = Vector3(0.0, -0.5, 0.0)
	floor_body.add_child(floor_shape)
	_root.add_child(floor_body)
	_clock = FakeClock.new()
	_remote_world = RemoteWorld.new()
	_remote_world.install_visuals = false
	_remote_world.setup(_clock)
	_root.add_child(_remote_world)
	_rig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_rig.set_scripted_look(true)
	_root.add_child(_rig)
	_rig.global_position = Vector3(0.0, 1.6, 0.0)
	_rig.set_look(0.0, 0.0)
	_canvas = CanvasLayer.new()
	tree.root.add_child(_canvas)
	_plates = Nameplates.new()
	_plates.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(_plates)
	_plates.setup(_remote_world, _rig, VARDHEIM)
	_wall = null
	_tick = 1
	_rig._process(0.016)


func after_each() -> void:
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	if is_instance_valid(_canvas):
		tree.root.remove_child(_canvas)
		_canvas.free()
	_root = null
	_canvas = null
	_plates = null
	_rig = null
	_remote_world = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

## Un remoto de [param realm] con [param player_name] en [param feet] (pies), ya dibujándose.
func _spawn(net_id: int, realm: int, player_name: String, feet: Vector3,
		health_q: int = 255) -> void:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = NetProtocol.EntityKind.PLAYER
	spawn.spawn_tick = 1
	spawn.realm = realm
	spawn.display_name = player_name
	var state := PlayerState.new()
	state.position = feet
	state.grounded = true
	spawn.state = state
	_remote_world.on_spawn(spawn)
	_set_health(net_id, feet, health_q)


## Fija la posición y la vida cuantizada de un remoto y lo dibuja.
func _set_health(net_id: int, feet: Vector3, health_q: int) -> void:
	_tick += 1
	var record := EntityRecord.new()
	record.net_id = net_id
	record.position = feet
	record.flags = EntityRecord.FLAG_GROUNDED
	record.health_q = health_q
	var snapshot := NetMessages.Snapshot.new()
	snapshot.server_tick = _tick
	snapshot.records = [record] as Array[EntityRecord]
	_remote_world.on_snapshot(snapshot)
	_redraw()


func _redraw() -> void:
	_clock.render = float(_tick)
	_remote_world.draw(float(_tick), 0.016)


## Pies de un punto a [param meters] metros delante de la retícula, bajado a la altura del suelo
## para que el remoto quede justo en el rayo de puntería.
func _on_the_aim_ray(meters: float) -> Vector3:
	var ray: Dictionary = _rig.get_aim_ray()
	var point: Vector3 = Vector3(ray["origin"]) + Vector3(ray["direction"]) * meters
	return Vector3(point.x, 0.0, point.z)


## Un fotograma de las placas (con la cámara al día).
func _frame(delta: float = 0.016) -> void:
	_rig._process(delta)
	_plates.refresh(delta)


func _add_wall(at: Vector3) -> void:
	_wall = StaticBody3D.new()
	_wall.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30.0, 8.0, 0.5)
	shape.shape = box
	_wall.add_child(shape)
	_root.add_child(_wall)
	_wall.global_position = at


# --- Aliados ----------------------------------------------------------------------------------

func test_ally_shows_name_realm_color_and_health_bar_within_range() -> void:
	_spawn(ALLY_ID, VARDHEIM, "Ana", Vector3(6.0, 0.0, -15.0), 128)
	_frame()
	var plate: Nameplate = _plates.get_plate_for(ALLY_ID)
	if not assert_not_null(plate, "un aliado cerca tiene placa"):
		return
	assert_true(plate.visible)
	assert_eq(plate.get_name_text(), "Ana")
	assert_true(plate.is_name_shown(), "con nombre")
	assert_true(plate.is_bar_shown(), "y barra de vida siempre")
	assert_true(plate.is_ally())
	assert_eq(plate.get_color(), RealmCatalog.color_of(RealmCatalog.VARDHEIM), "con el color de su reino")
	assert_near(plate.get_health_fraction(), 128.0 / 255.0, 0.001, "la barra sale de health_q")
	assert_eq(_plates.get_visible_count(), 1)


func test_ally_beyond_forty_meters_has_no_plate_and_fades_near_the_limit() -> void:
	_spawn(ALLY_ID, VARDHEIM, "Ana", Vector3(0.0, 0.0, -60.0))
	_frame()
	assert_null(_plates.get_plate_for(ALLY_ID), "a 60 m no se ve")
	_set_health(ALLY_ID, Vector3(0.0, 0.0, -34.0), 255)
	_frame()
	var far_plate: Nameplate = _plates.get_plate_for(ALLY_ID)
	if not assert_not_null(far_plate, "a unos 38 m (con la cámara detrás del jugador) se ve"):
		return
	assert_true(far_plate.get_alpha() < 0.5, "pero casi apagada (%.2f)" % far_plate.get_alpha())
	_set_health(ALLY_ID, Vector3(0.0, 0.0, -10.0), 255)
	_frame()
	assert_eq(_plates.get_plate_for(ALLY_ID).get_alpha(), 1.0, "de cerca, opaca")


func test_dead_players_and_players_behind_the_camera_have_no_plate() -> void:
	_spawn(ALLY_ID, VARDHEIM, "Ana", Vector3(2.0, 0.0, -10.0), 0)
	_spawn(OTHER_ENEMY_ID, VARDHEIM, "Bruno", Vector3(0.0, 0.0, 12.0))
	_frame()
	assert_null(_plates.get_plate_for(ALLY_ID), "un muerto (health_q 0) no tiene placa")
	assert_null(_plates.get_plate_for(OTHER_ENEMY_ID), "ni quien está detrás de la cámara")
	assert_eq(_plates.get_visible_count(), 0)


func test_the_plate_is_anchored_to_the_projected_head() -> void:
	var feet := Vector3(4.0, 0.0, -12.0)
	_spawn(ALLY_ID, VARDHEIM, "Ana", feet)
	_frame()
	var plate: Nameplate = _plates.get_plate_for(ALLY_ID)
	if not assert_not_null(plate):
		return
	var head: Vector3 = feet + Vector3(0.0, Nameplates.HEAD_HEIGHT, 0.0)
	var expected: Vector2 = _rig.get_camera().unproject_position(head)
	var anchor: Vector2 = plate.position + Vector2(plate.size.x * 0.5, plate.size.y)
	assert_vec_near(anchor, expected, 0.01, "el borde inferior central de la placa está en la cabeza")
	# Si el remoto se mueve, la placa lo sigue.
	_set_health(ALLY_ID, feet + Vector3(2.0, 0.0, 0.0), 255)
	_frame()
	var moved: Vector2 = _rig.get_camera().unproject_position(
			feet + Vector3(2.0, Nameplates.HEAD_HEIGHT, 0.0))
	assert_vec_near(plate.position + Vector2(plate.size.x * 0.5, plate.size.y), moved, 0.01)
	assert_true(moved.x > expected.x, "y se movió hacia la derecha en pantalla")


# --- Enemigos ---------------------------------------------------------------------------------

func test_enemy_has_no_plate_unless_aimed_at_or_recently_damaged() -> void:
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", Vector3(9.0, 0.0, -14.0))
	_frame()
	assert_null(_plates.get_plate_for(ENEMY_ID), "un enemigo cualquiera no tiene placa")
	assert_eq(_plates.get_targeted_id(), 0)


func test_enemy_under_the_crosshair_shows_name_and_health_bar() -> void:
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", _on_the_aim_ray(15.0), 200)
	_frame()
	assert_eq(_plates.get_targeted_id(), ENEMY_ID, "la retícula le apunta")
	var plate: Nameplate = _plates.get_plate_for(ENEMY_ID)
	if not assert_not_null(plate):
		return
	assert_true(plate.is_name_shown(), "con nombre")
	assert_true(plate.is_bar_shown(), "y barra")
	assert_false(plate.is_ally())
	assert_eq(plate.get_color(), RealmCatalog.color_of(RealmCatalog.SOLMARCH), "con el color de su reino")
	assert_near(plate.get_health_fraction(), 200.0 / 255.0, 0.001)
	# Al apartar la retícula, desaparece.
	_rig.set_look(1.0, 0.0)
	_frame()
	assert_null(_plates.get_plate_for(ENEMY_ID), "sin apuntarle ni haberle dañado, nada")


func test_only_the_nearest_enemy_on_the_aim_ray_is_targeted() -> void:
	_spawn(ENEMY_ID, SOLMARCH, "Cerca", _on_the_aim_ray(10.0))
	_spawn(OTHER_ENEMY_ID, SOLMARCH, "Lejos", _on_the_aim_ray(25.0))
	_frame()
	assert_eq(_plates.get_targeted_id(), ENEMY_ID)
	assert_not_null(_plates.get_plate_for(ENEMY_ID))
	assert_null(_plates.get_plate_for(OTHER_ENEMY_ID), "el de detrás no se apunta")


func test_damaged_enemy_keeps_a_health_bar_without_name_for_five_seconds() -> void:
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", Vector3(9.0, 0.0, -14.0), 100)
	_plates.mark_damaged(ENEMY_ID)
	_frame()
	var plate: Nameplate = _plates.get_plate_for(ENEMY_ID)
	if not assert_not_null(plate, "dañado hace un instante, tiene placa"):
		return
	assert_true(plate.is_bar_shown(), "con barra de vida")
	assert_false(plate.is_name_shown(), "pero sin nombre: la retícula no le apunta")
	assert_true(_plates.was_damaged_recently(ENEMY_ID))
	_frame(Nameplates.DAMAGED_SECONDS - 0.5)
	assert_not_null(_plates.get_plate_for(ENEMY_ID), "a los 4,5 s aún")
	_frame(1.0)
	assert_null(_plates.get_plate_for(ENEMY_ID), "pasados 5 s, fuera")
	assert_false(_plates.was_damaged_recently(ENEMY_ID))


func test_a_damaged_enemy_under_the_crosshair_gets_both() -> void:
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", _on_the_aim_ray(12.0))
	_plates.mark_damaged(ENEMY_ID)
	_frame()
	var plate: Nameplate = _plates.get_plate_for(ENEMY_ID)
	assert_true(plate.is_name_shown() and plate.is_bar_shown())


func test_no_enemy_is_targeted_while_the_cursor_is_free() -> void:
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", _on_the_aim_ray(12.0))
	_rig.set_scripted_look(false)
	_rig.set_ui_cursor_release(true, self)
	_frame()
	assert_eq(_plates.get_targeted_id(), 0, "con el cursor libre no hay retícula")
	assert_null(_plates.get_plate_for(ENEMY_ID))
	_rig.set_ui_cursor_release(false, self)


func test_the_local_player_never_has_a_plate() -> void:
	# El RemoteWorld solo contiene a los demás: ni el id propio ni nada suyo aparece.
	_spawn(ALLY_ID, VARDHEIM, "Ana", Vector3(3.0, 0.0, -9.0))
	_frame()
	assert_null(_plates.get_plate_for(OWN_ID), "el propio jugador no tiene placa")
	assert_eq(_plates.get_visible_count(), 1)
	assert_eq(_remote_world.get_view(OWN_ID), null)


# --- Oclusión ---------------------------------------------------------------------------------

func test_a_wall_hides_the_plate_and_removing_it_brings_it_back() -> void:
	_spawn(ALLY_ID, VARDHEIM, "Ana", Vector3(0.0, 0.0, -20.0))
	_add_wall(Vector3(0.0, 4.0, -10.0))
	await wait_physics_frames(2)
	for _i: int in Nameplates.OCCLUSION_INTERVAL_FRAMES + 1:
		_frame()
	assert_null(_plates.get_plate_for(ALLY_ID), "detrás de un muro, sin placa")
	_wall.get_parent().remove_child(_wall)
	_wall.free()
	_wall = null
	await wait_physics_frames(2)
	for _i: int in Nameplates.OCCLUSION_INTERVAL_FRAMES + 1:
		_frame()
	assert_not_null(_plates.get_plate_for(ALLY_ID), "sin el muro vuelve")


func test_a_targeted_enemy_behind_a_wall_is_not_targeted() -> void:
	_spawn(ENEMY_ID, SOLMARCH, "Hostil", _on_the_aim_ray(20.0))
	_add_wall(Vector3(0.0, 4.0, -8.0))
	await wait_physics_frames(2)
	for _i: int in Nameplates.OCCLUSION_INTERVAL_FRAMES + 1:
		_frame()
	assert_eq(_plates.get_targeted_id(), 0, "el muro tapa al apuntado")
	assert_null(_plates.get_plate_for(ENEMY_ID))


func test_occlusion_rays_are_spread_over_frames() -> void:
	for i: int in 12:
		_spawn(100 + i, VARDHEIM, "Aliado%d" % i, Vector3(-6.0 + float(i), 0.0, -14.0))
	_frame()
	var after_first: int = _plates.get_ray_count()
	assert_eq(after_first, 12, "la primera vez cada uno lanza su rayo")
	for _i: int in Nameplates.OCCLUSION_INTERVAL_FRAMES * 2:
		_frame()
	var total: int = _plates.get_ray_count()
	var per_frame_cost: int = 12 * (Nameplates.OCCLUSION_INTERVAL_FRAMES * 2 + 1)
	assert_true(total < per_frame_cost / 3, "unos %d rayos en lugar de %d (uno por jugador y fotograma)" % [total, per_frame_cost])
	assert_true(total >= 12 * 2, "pero cada jugador repite el suyo (%d)" % total)
	assert_eq(_plates.get_visible_count(), 12)


# --- Pool -------------------------------------------------------------------------------------

func test_the_pool_is_bounded_and_shows_the_nearest() -> void:
	for i: int in 50:
		_spawn(200 + i, VARDHEIM, "Aliado%d" % i, Vector3(-10.0 + float(i % 10) * 2.0, 0.0,
				-8.0 - float(i / 10) * 3.0))
	_frame()
	assert_eq(_plates.get_visible_count(), Nameplates.MAX_PLATES, "no más placas que el tope")
	assert_eq(_plates.get_pool_size(), Nameplates.MAX_PLATES)
	var children: int = _plates.get_child_count()
	for _i: int in 5:
		_frame()
	assert_eq(_plates.get_child_count(), children, "el pool no crece")
	# Se quedan las más cercanas: la fila de delante (z = -8) entera tiene placa.
	for i: int in 10:
		assert_not_null(_plates.get_plate_for(200 + i), "el aliado %d, de la fila cercana, tiene placa" % i)


func test_plates_are_released_when_the_remotes_leave() -> void:
	_spawn(ALLY_ID, VARDHEIM, "Ana", Vector3(3.0, 0.0, -9.0))
	_frame()
	var plate: Nameplate = _plates.get_plate_for(ALLY_ID)
	assert_true(plate.visible)
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = ALLY_ID
	despawn.despawn_tick = _tick + 1
	_remote_world.on_despawn(despawn)
	_tick += 2
	_redraw()
	_frame()
	assert_false(plate.visible, "la placa vuelve al pool")
	assert_eq(_plates.get_visible_count(), 0)
