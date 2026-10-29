extends TestCase
## La puerta del fuerte como blanco de los golpes (docs/fuerte.md, sección 3.3): el sector anular de un
## ataque contra una caja orientada ([method HitShapes.sector_hits_box]) y el solape de una cápsula con
## la caja ([method HitShapes.capsule_overlaps_box]), que decide si el vano de la puerta está ocupado.
## La caja de las pruebas es la de la puerta real: 0,5 m de grosor en X, 4,3 m de alto y 4 m de ancho en Z,
## con el centro a 2,15 m.

const HALF_EXTENTS: Vector3 = Vector3(0.25, 2.15, 2.0)
const BOX_CENTER: Vector3 = Vector3(0.0, 2.15, 0.0)
const MARGIN: float = 0.01
## Yaw que mira hacia +X (hacia la puerta, desde el oeste): yaw -90°.
const YAW_EAST: float = -PI * 0.5


func _box(rotation_y: float = 0.0, at: Vector3 = Vector3.ZERO) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, rotation_y), at + BOX_CENTER)


func _hits(origin: Vector3, yaw: float, shape: HitShape, box: Transform3D = _box()) -> bool:
	return HitShapes.sector_hits_box(origin, yaw, shape, box, HALF_EXTENTS)


# --- Sector contra caja -------------------------------------------------------------------------

func test_a_sector_in_front_of_the_gate_hits_it_and_one_behind_does_not() -> void:
	var shape := HitShape.new()
	# Alcance 2,6 m; la cara oeste de la caja está en x = -0,25.
	assert_true(_hits(Vector3(-2.0, 0.0, 0.0), YAW_EAST, shape), "de frente a 1,75 m de la cara")
	assert_true(_hits(Vector3(-2.8, 0.0, 0.0), YAW_EAST, shape), "justo dentro del alcance (2,55 m)")
	assert_false(_hits(Vector3(-2.9, 0.0, 0.0), YAW_EAST, shape), "justo fuera del alcance (2,65 m)")
	assert_false(_hits(Vector3(-2.0, 0.0, 0.0), -YAW_EAST, shape), "de espaldas a la puerta")
	assert_false(_hits(Vector3(-3.0, 0.0, 0.0), 0.0, shape),
			"mirando a lo largo de la puerta desde lejos: ni su cara cercana cae en el alcance")


func test_the_cone_catches_the_gate_corners_off_axis() -> void:
	var shape := HitShape.new()
	# A 1 m de la cara oeste y desplazado 1,9 m en Z: se golpea hacia el lado, dentro de los 50° de
	# semiángulo, porque el extremo cercano de la puerta cae dentro del cono.
	assert_true(_hits(Vector3(-1.25, 0.0, 3.0), YAW_EAST, shape),
			"desde un lado de la puerta, mirando de frente, el extremo cae en el cono")
	# Lejos de lado: ni el extremo de la puerta cabe en el alcance.
	assert_false(_hits(Vector3(-1.25, 0.0, 6.5), YAW_EAST, shape), "demasiado a un lado")
	# Mirando hacia el otro lado del extremo, aunque esté cerca.
	assert_false(_hits(Vector3(-1.25, 0.0, 3.0), PI, shape), "mirando hacia el lado contrario")


func test_the_sector_height_overlaps_the_gate_height() -> void:
	var shape := HitShape.new()
	assert_true(_hits(Vector3(-2.0, 0.0, 0.0), YAW_EAST, shape), "a ras de suelo")
	# La caja llega hasta 4,3 m; el golpe sube hasta height_max = 2 m sobre los pies.
	assert_true(_hits(Vector3(-2.0, 2.2, 0.0), YAW_EAST, shape), "con los pies 2,2 m más arriba (pasarela)")
	assert_false(_hits(Vector3(-2.0, 4.2, 0.0), YAW_EAST, shape),
			"los golpes empiezan a 0,2 m sobre los pies: con los pies a 4,2 m quedan por encima")
	assert_false(_hits(Vector3(-2.0, -3.0, 0.0), YAW_EAST, shape), "muy por debajo de la caja")


func test_an_attacker_inside_the_box_footprint_hits_it() -> void:
	var shape := HitShape.new()
	assert_true(_hits(Vector3(0.0, 0.0, 0.0), 0.3, shape), "con el origen dentro de la caja")
	assert_true(_hits(Vector3(0.1, 0.0, 1.0), PI, shape), "dentro y mirando a cualquier lado")


func test_the_inner_radius_leaves_a_hole() -> void:
	var shape := HitShape.new()
	shape.inner_m = 1.5
	assert_true(_hits(Vector3(-1.0, 0.0, 0.0), YAW_EAST, shape),
			"la parte lejana de la caja cae en el anillo, aunque la cercana esté en el hueco")
	# Con el origen pegado a la puerta, el borde más lejano de la caja está a 0,5 m: dentro del hueco.
	assert_false(_hits(Vector3(-0.25, 0.0, 0.0), YAW_EAST, shape), "toda la caja cae en el hueco central")
	shape.inner_m = 0.0
	assert_true(_hits(Vector3(-0.25, 0.0, 0.0), YAW_EAST, shape), "sin hueco, sí")


func test_a_rotated_gate_is_hit_where_it_actually_is() -> void:
	var shape := HitShape.new()
	# La misma puerta girada 90°: ahora ocupa el plano z = 0 con el ancho a lo largo de X.
	var rotated: Transform3D = _box(PI * 0.5, Vector3(10.0, 0.0, 5.0))
	# Al sur de la puerta (z mayor) y mirando hacia -Z (yaw 0), a 1,5 m de su cara.
	assert_true(_hits(Vector3(10.0, 0.0, 6.75), 0.0, shape, rotated), "de frente a la puerta girada")
	assert_false(_hits(Vector3(10.0, 0.0, 6.75), PI, shape, rotated), "dándole la espalda")
	assert_false(_hits(Vector3(-2.0, 0.0, 0.0), YAW_EAST, shape, rotated), "y no donde estaba antes")


func test_a_wide_sector_is_the_union_of_two_half_planes() -> void:
	var shape := HitShape.new()
	shape.angle_deg = 240.0
	# Un sector de 240° deja sin cubrir solo el cono de 120° de detrás (±60°): desde 2 m, la puerta entera
	# cabe en ±49° de la dirección a ella.
	assert_true(_hits(Vector3(-2.0, 0.0, 0.0), YAW_EAST, shape), "de frente")
	assert_true(_hits(Vector3(-2.0, 0.0, 0.0), 0.0, shape), "con la puerta a un lado")
	assert_false(_hits(Vector3(-2.0, 0.0, 0.0), -YAW_EAST, shape),
			"de espaldas, la puerta queda entera en el cono ciego")
	shape.angle_deg = 360.0
	assert_true(_hits(Vector3(-2.0, 0.0, 0.0), -YAW_EAST, shape), "con 360° no hay cono")


func test_every_swing_direction_agrees_with_a_brute_force_sample() -> void:
	# Contrasta la prueba exacta con un muestreo de puntos de la caja: si algún punto muestreado está en
	# el sector, la prueba tiene que dar true; si la prueba da true, algún punto cercano al sector tiene
	# que existir (con margen de muestreo).
	var shape := HitShape.new()
	var box: Transform3D = _box()
	var mismatches: int = 0
	for ix: int in range(-6, 3):
		for iz: int in range(-5, 6):
			for yaw_step: int in 16:
				var origin := Vector3(float(ix) * 0.6, 0.0, float(iz) * 0.6)
				var yaw: float = float(yaw_step) * TAU / 16.0
				var expected: bool = _sample_hits(origin, yaw, shape, box)
				var actual: bool = _hits(origin, yaw, shape, box)
				if expected and not actual:
					mismatches += 1
	assert_eq(mismatches, 0, "la prueba exacta nunca falla un golpe que el muestreo ve")


func _sample_hits(origin: Vector3, yaw: float, shape: HitShape, box: Transform3D) -> bool:
	var forward: Vector3 = Basis(Vector3.UP, yaw) * Vector3.FORWARD
	for sx: int in 9:
		for sz: int in 17:
			var local := Vector3(lerpf(-HALF_EXTENTS.x, HALF_EXTENTS.x, float(sx) / 8.0), 0.0,
					lerpf(-HALF_EXTENTS.z, HALF_EXTENTS.z, float(sz) / 16.0))
			var point: Vector3 = box * local
			var offset := Vector3(point.x - origin.x, 0.0, point.z - origin.z)
			var distance: float = offset.length()
			if distance > shape.range_m or distance < shape.inner_m:
				continue
			if distance < 0.0001 or rad_to_deg(forward.angle_to(offset)) <= shape.angle_deg * 0.5:
				return true
	return false


# --- Cápsula contra caja (el vano ocupado) -------------------------------------------------------

func test_a_character_in_the_doorway_overlaps_the_box() -> void:
	var box: Transform3D = _box()
	var feet := Vector3(0.0, 0.0, 0.0)
	assert_true(HitShapes.capsule_overlaps_box(feet, 0.4, 1.8, box, HALF_EXTENTS), "justo en el vano")
	assert_true(HitShapes.capsule_overlaps_box(Vector3(0.6, 0.0, 0.0), 0.4, 1.8, box, HALF_EXTENTS),
			"rozando la cara este con el radio (0,25 + 0,4 = 0,65)")
	assert_false(HitShapes.capsule_overlaps_box(Vector3(0.7, 0.0, 0.0), 0.4, 1.8, box, HALF_EXTENTS),
			"a 0,45 m de la cara este ya no la toca")
	assert_false(HitShapes.capsule_overlaps_box(Vector3(-0.7, 0.0, 0.0), 0.4, 1.8, box, HALF_EXTENTS),
			"ni por el oeste")
	assert_true(HitShapes.capsule_overlaps_box(Vector3(0.0, 0.0, 2.3), 0.4, 1.8, box, HALF_EXTENTS),
			"en el extremo del ancho, rozando el poste con el radio")
	assert_false(HitShapes.capsule_overlaps_box(Vector3(0.0, 0.0, 2.5), 0.4, 1.8, box, HALF_EXTENTS),
			"fuera del ancho de la puerta")


func test_a_character_standing_on_the_walkway_above_the_gate_does_not_block_it() -> void:
	var box: Transform3D = _box()
	assert_false(HitShapes.capsule_overlaps_box(Vector3(0.0, 4.4, 0.0), 0.4, 1.8, box, HALF_EXTENTS),
			"pisando la pasarela a 4,4 m, por encima de la caja")
	assert_true(HitShapes.capsule_overlaps_box(Vector3(0.0, 3.0, 0.0), 0.4, 1.8, box, HALF_EXTENTS),
			"con los pies dentro del alto de la caja")
	assert_false(HitShapes.capsule_overlaps_box(Vector3(0.0, -2.0, 0.0), 0.4, 1.8, box, HALF_EXTENTS),
			"bajo el suelo de la caja, con la cabeza por debajo")
