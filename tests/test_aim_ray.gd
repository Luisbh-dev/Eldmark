extends TestCase
## Puntería canónica ([AimRay], docs/habilidades.md, sección 4.4): el rayo canónico coincide con
## [method CameraRig.get_aim_ray] (sin colisión, cualquier zoom y campo de visión, los dos hombros) a
## menos de 1 mm; las reglas de puntería son las de las escenas; el tiro adelantado con el fondo a
## 150 m converge a la profundidad del blanco; [method AimRay.look_for] pasa a menos de 1 mm del
## punto; y el punto apuntado respeta el mundo y las cápsulas.

const CAMERA_RIG_SCENE: String = "res://scenes/client/camera_rig.tscn"
const CHARACTER_SCENE: String = "res://scenes/characters/player_character.tscn"
## Distancia máxima (m) entre el rayo canónico y el de la cámara.
const LINE_TOLERANCE: float = 0.001

var _viewport: SubViewport


func after_each() -> void:
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	await wait_process_frames()


func test_the_aim_rules_are_the_ones_of_the_scenes() -> void:
	var rules: CombatRules = CombatCatalog.rules()
	var rig: Node = (load(CAMERA_RIG_SCENE) as PackedScene).instantiate()
	var camera: Camera3D = rig.get_node(^"Yaw/Pitch/Arm/Camera") as Camera3D
	assert_near(rules.aim_shoulder_offset, absf(camera.h_offset), 1e-6,
			"aim_shoulder_offset es el h_offset de camera_rig.tscn")
	assert_true(camera.h_offset > 0.0, "y el hombro por defecto es el derecho (+)")
	assert_near(rules.aim_camera_v_offset, camera.v_offset, 1e-6,
			"aim_camera_v_offset es su v_offset")
	rig.free()
	var character: Node = (load(CHARACTER_SCENE) as PackedScene).instantiate()
	var target: Node3D = character.get_node(^"CameraTarget") as Node3D
	assert_near(rules.aim_pivot_height, target.position.y, 1e-6,
			"aim_pivot_height es la altura del CameraTarget del personaje")
	character.free()
	assert_eq(AimRay.muzzle(Vector3(1.0, 2.0, 3.0)), Vector3(1.0, 2.0 + rules.muzzle_height, 3.0),
			"la boca de salida, en el pecho")


func test_the_canonical_ray_is_the_camera_aim_ray() -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(640, 360)
	tree.root.add_child(_viewport)
	var feet := Vector3(3.0, 1.25, -7.5)
	var target := Node3D.new()
	target.position = feet + Vector3(0.0, CombatCatalog.rules().aim_pivot_height, 0.0)
	_viewport.add_child(target)
	var rig: CameraRig = (load(CAMERA_RIG_SCENE) as PackedScene).instantiate() as CameraRig
	_viewport.add_child(rig)
	rig.set_scripted_look(true)
	rig.set_target(target)
	await wait_process_frames(2)
	# [yaw, pitch, hombro, distancia del brazo, campo de visión]
	var cases: Array = [
		[0.0, 0.0, 1, 3.5, 72.0],
		[0.8, 0.3, 1, 1.5, 54.0],
		[-2.5, -0.6, -1, 6.0, 90.0],
		[3.0, 0.9, -1, 2.7, 60.0],
		[-1.2, -1.2, 1, 4.4, 72.0 * 0.75],
	]
	for case: Array in cases:
		rig.set_look(case[0], case[1])
		rig.set_default_shoulder(case[2])
		rig._zoom_target = case[3]
		rig._zoom_distance = case[3]
		rig.set_fov(case[4])
		# Pasos largos: el hombro y el zoom convergen del todo (su suavizado es exponencial).
		for _i: int in 4:
			rig._process(10.0)
		var aim: Dictionary = rig.get_aim_ray()
		var camera_origin: Vector3 = aim["origin"]
		var camera_direction: Vector3 = aim["direction"]
		var canonical: Array = AimRay.canonical(feet, rig.get_yaw(), rig.get_pitch(), case[2] < 0)
		var origin: Vector3 = canonical[0]
		var direction: Vector3 = canonical[1]
		var label: String = "yaw %s, pitch %s, hombro %d, brazo %s, FOV %s" % case
		assert_vec_near(direction, camera_direction, 1e-5, "%s: misma dirección" % label)
		var offset: Vector3 = origin - camera_origin
		var off_line: Vector3 = offset - camera_direction * offset.dot(camera_direction)
		assert_true(off_line.length() < LINE_TOLERANCE, "%s: misma recta (a %s m)" % [label,
				off_line.length()])
		assert_true(offset.dot(camera_direction) > 0.0, "%s: el origen canónico va por delante de la cámara"
				% label)


func test_a_lead_shot_with_the_background_at_150_m_converges_at_the_target_depth() -> void:
	_viewport = _world_with_box(Vector3(400.0, 100.0, 2.0), Vector3(0.0, 0.0, -150.0))
	await wait_physics_frames(2)
	await tree.physics_frame
	var space: PhysicsDirectSpaceState3D = _viewport.find_world_3d().direct_space_state
	var feet := Vector3.ZERO
	var target_feet := Vector3(0.0, 0.0, -30.0)
	# La mira, 3 m por delante del blanco (a su profundidad), como al adelantar el tiro.
	var aim_at: Vector3 = target_feet + Vector3(3.0, AimRay.TARGET_CENTER_HEIGHT, 0.0)
	var look: Vector2 = AimRay.look_for(feet, aim_at, false)
	var ray: Array = AimRay.canonical(feet, look.x, look.y, false)
	var origin: Vector3 = ray[0]
	var direction: Vector3 = ray[1]
	var hostiles := PackedVector3Array([target_feet])
	var point: Vector3 = AimRay.aim_point(space, origin, direction, hostiles)
	var depth: float = (target_feet + Vector3(0.0, AimRay.TARGET_CENTER_HEIGHT, 0.0) - origin).dot(direction)
	assert_near((point - origin).dot(direction), depth, 1e-3, "converge a la profundidad del blanco")
	var muzzle: Vector3 = AimRay.muzzle(feet)
	var gap: float = _gap_at_depth(muzzle, (point - muzzle).normalized(), origin, direction, depth)
	assert_true(gap < 0.02, "la flecha cruza la mira a menos de 2 cm a esa profundidad (%s m)" % gap)
	# Control: sin blanco, el punto es el fondo (150 m) y la flecha se desvía medio metro.
	var background: Vector3 = AimRay.aim_point(space, origin, direction, PackedVector3Array())
	assert_true((background - origin).dot(direction) > 145.0 and (background - origin).dot(direction) < 150.0,
			"sin blanco, el fondo (%s m)" % (background - origin).dot(direction))
	var stray: float = _gap_at_depth(muzzle, (background - muzzle).normalized(), origin, direction, depth)
	assert_true(stray > 0.3, "sin convergencia se desviaría %s m" % stray)
	# Un blanco a más de 12° de la mira no cuenta.
	var aside := PackedVector3Array([Vector3(15.0, 0.0, -30.0)])
	var far_point: Vector3 = AimRay.aim_point(space, origin, direction, aside)
	assert_true((far_point - origin).dot(direction) > 145.0, "fuera del cono, el fondo")
	# Dos dentro del cono: el de menor ángulo.
	var both := PackedVector3Array([Vector3(4.5, 0.0, -20.0), target_feet])
	var chosen: Vector3 = AimRay.aim_point(space, origin, direction, both)
	assert_near((chosen - origin).dot(direction), depth, 1e-3, "el más cercano a la mira")


func test_the_aim_point_stops_at_the_world_and_at_a_capsule() -> void:
	_viewport = _world_with_box(Vector3(20.0, 20.0, 1.0), Vector3(0.0, 0.0, -20.0))
	await wait_physics_frames(2)
	await tree.physics_frame
	var space: PhysicsDirectSpaceState3D = _viewport.find_world_3d().direct_space_state
	var feet := Vector3.ZERO
	var ray: Array = AimRay.canonical(feet, 0.0, 0.0, false)
	var origin: Vector3 = ray[0]
	var direction: Vector3 = ray[1]
	var wall: Vector3 = AimRay.aim_point(space, origin, direction, PackedVector3Array())
	assert_near(wall.z, -19.5, 0.01, "el rayo para en el muro")
	# Un hostil detrás del muro no cuenta (ni para la convergencia).
	var behind: Vector3 = AimRay.aim_point(space, origin, direction,
			PackedVector3Array([Vector3(0.6, 0.0, -30.0)]))
	assert_near(behind.z, -19.5, 0.01, "detrás del muro, el muro")
	# Un hostil delante, en la línea: el choque con su cápsula.
	var front := Vector3(origin.x, origin.y - 0.9, -10.0)
	var hit: Vector3 = AimRay.aim_point(space, origin, direction, PackedVector3Array([front]))
	assert_near(hit.z, -10.0 + HitShapes.CAPSULE_RADIUS, 0.01, "en la superficie de la cápsula")
	# Sin mundo (space null): el alcance.
	var reach: Vector3 = AimRay.aim_point(null, origin, direction, PackedVector3Array())
	assert_near((reach - origin).dot(direction), CombatCatalog.rules().aim_range_m, 1e-3, "150 m")


func test_look_for_aims_the_canonical_ray_through_the_point() -> void:
	var feet := Vector3(-4.0, 2.0, 11.0)
	var points: Array[Vector3] = [
		Vector3(-4.0, 3.0, -30.0), Vector3(20.0, 0.5, 11.0), Vector3(-70.0, 30.0, 80.0),
		Vector3(-3.0, 3.6, 9.0), Vector3(-4.0, -40.0, 0.0), Vector3(-5.5, 2.4, 13.5),
	]
	for point: Vector3 in points:
		for left: bool in [false, true]:
			var look: Vector2 = AimRay.look_for(feet, point, left)
			assert_true(look.x >= -PI and look.x <= PI, "yaw en [-PI, PI]")
			var ray: Array = AimRay.canonical(feet, look.x, look.y, left)
			var origin: Vector3 = ray[0]
			var direction: Vector3 = ray[1]
			var offset: Vector3 = point - origin
			var depth: float = offset.dot(direction)
			var miss: float = (offset - direction * depth).length()
			assert_true(depth > 0.0, "%s (izq. %s): el punto queda delante" % [point, left])
			assert_true(miss < 0.001, "%s (izq. %s): el rayo pasa a %s m" % [point, left, miss])


# La distancia, a la profundidad [param depth] de la mira, entre la recta que sale de [param from] en
# [param direction] y la de la mira ([param origin], [param aim_direction]).
static func _gap_at_depth(from: Vector3, direction: Vector3, origin: Vector3, aim_direction: Vector3,
		depth: float) -> float:
	var along: float = (depth - (from - origin).dot(aim_direction)) / direction.dot(aim_direction)
	var on_arrow: Vector3 = from + direction * along
	var on_aim: Vector3 = origin + aim_direction * depth
	return on_arrow.distance_to(on_aim)


func _world_with_box(size: Vector3, center: Vector3) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	tree.root.add_child(viewport)
	var body := StaticBody3D.new()
	body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = center
	viewport.add_child(body)
	return viewport
