extends TestCase
## Pruebas de la geometría de los golpes ([HitShapes], docs/combate.md sección 4.1): sector anular
## con altura contra cápsula vertical (borde del ángulo, alcance con el radio, hueco interior,
## altura), segmento contra cápsula, cono frontal y línea de visión contra un muro real en un
## espacio de física propio.
##
## Convención: yaw 0 mira hacia -Z; un yaw positivo gira hacia -X (como [member PlayerCharacter.yaw]).

## Distancia con la que se sitúan los objetivos «justo dentro» y «justo fuera» de un borde (m).
const MARGIN: float = 0.01
## Lo mismo para los ángulos (grados).
const ANGLE_MARGIN_DEG: float = 0.05

var _viewport: SubViewport


func after_each() -> void:
	if _viewport != null:
		_viewport.queue_free()
		_viewport = null


# --- Sector anular con altura contra cápsula --------------------------------------------------

func test_sector_hits_target_in_front_and_not_behind() -> void:
	var shape := HitShape.new()
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -2.0)), "de frente a 2 m")
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -0.5)), "de frente a 0,5 m")
	assert_false(_sector(shape, 0.0, Vector3(0.0, 0.0, 2.0)), "a la espalda a 2 m")
	assert_false(_sector(shape, 0.0, Vector3(2.0, 0.0, 0.0)), "a 90° a 2 m (el sector es de 100°)")
	assert_false(_sector(shape, 0.0, Vector3(-2.0, 0.0, 0.0)), "a -90° a 2 m")


func test_sector_follows_attacker_yaw() -> void:
	var shape := HitShape.new()
	# Yaw +90°: mira hacia -X.
	assert_true(_sector(shape, PI * 0.5, Vector3(-2.0, 0.0, 0.0)), "yaw 90°: el -X está delante")
	assert_false(_sector(shape, PI * 0.5, Vector3(2.0, 0.0, 0.0)), "yaw 90°: el +X está detrás")
	assert_false(_sector(shape, PI * 0.5, Vector3(0.0, 0.0, -2.0)), "yaw 90°: el -Z queda a un lado")
	# Yaw 180°: mira hacia +Z.
	assert_true(_sector(shape, PI, Vector3(0.0, 0.0, 2.0)), "yaw 180°: el +Z está delante")
	assert_false(_sector(shape, PI, Vector3(0.0, 0.0, -2.0)), "yaw 180°: el -Z está detrás")
	# El origen no es el (0, 0, 0).
	assert_true(HitShapes.sector_hits_capsule(Vector3(10.0, 0.0, 5.0), 0.0, shape,
			Vector3(10.0, 0.0, 3.0), HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT),
			"con el atacante desplazado")


func test_sector_angle_edge_grows_with_capsule_radius() -> void:
	var shape := HitShape.new()
	var distance: float = 2.0
	var radius: float = HitShapes.CAPSULE_RADIUS
	# Borde: la mitad del ángulo más lo que subtiende el disco de la cápsula a esa distancia.
	var edge_deg: float = shape.angle_deg * 0.5 + rad_to_deg(asin(radius / distance))
	for side: float in [1.0, -1.0]:
		var inside: float = deg_to_rad(edge_deg - ANGLE_MARGIN_DEG)
		var outside: float = deg_to_rad(edge_deg + ANGLE_MARGIN_DEG)
		assert_true(_sector(shape, 0.0, _polar(distance, side * inside)),
				"justo dentro del borde (lado %d)" % int(side))
		assert_false(_sector(shape, 0.0, _polar(distance, side * outside)),
				"justo fuera del borde (lado %d)" % int(side))
	# Sin radio de cápsula el borde es el del sector: 50°.
	var half_deg: float = shape.angle_deg * 0.5
	assert_true(HitShapes.sector_hits_capsule(Vector3.ZERO, 0.0, shape,
			_polar(distance, deg_to_rad(half_deg - ANGLE_MARGIN_DEG)), 0.0, 1.8),
			"radio 0 justo dentro de 50°")
	assert_false(HitShapes.sector_hits_capsule(Vector3.ZERO, 0.0, shape,
			_polar(distance, deg_to_rad(half_deg + ANGLE_MARGIN_DEG)), 0.0, 1.8),
			"radio 0 justo fuera de 50°")
	# Más cerca, el disco subtiende más: a 1 m el borde es 50° + asin(0,4) = 73,6°.
	var near_edge_deg: float = half_deg + rad_to_deg(asin(radius / 1.0))
	assert_true(_sector(shape, 0.0, _polar(1.0, deg_to_rad(near_edge_deg - ANGLE_MARGIN_DEG))),
			"a 1 m, justo dentro")
	assert_false(_sector(shape, 0.0, _polar(1.0, deg_to_rad(near_edge_deg + ANGLE_MARGIN_DEG))),
			"a 1 m, justo fuera")


func test_sector_reach_includes_capsule_radius() -> void:
	var shape := HitShape.new()
	var reach: float = shape.range_m + HitShapes.CAPSULE_RADIUS
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -(reach - MARGIN))),
			"eje de la cápsula justo dentro (alcance + radio)")
	assert_false(_sector(shape, 0.0, Vector3(0.0, 0.0, -(reach + MARGIN))),
			"eje de la cápsula justo fuera")
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -(shape.range_m + MARGIN))),
			"el eje pasa del alcance pero el borde de la cápsula lo toca")
	# Con otro radio de cápsula cambia el alcance.
	assert_true(HitShapes.sector_hits_capsule(Vector3.ZERO, 0.0, shape,
			Vector3(0.0, 0.0, -(shape.range_m + 0.1 - MARGIN)), 0.1, 1.8), "radio 0,1 dentro")
	assert_false(HitShapes.sector_hits_capsule(Vector3.ZERO, 0.0, shape,
			Vector3(0.0, 0.0, -(shape.range_m + 0.1 + MARGIN)), 0.1, 1.8), "radio 0,1 fuera")
	# Un alcance mayor en la forma lo amplía.
	shape.range_m = 5.0
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -5.0)), "con alcance 5 m")


func test_sector_inner_radius_leaves_a_hole() -> void:
	var shape := HitShape.new()
	shape.inner_m = 1.0
	var hole: float = shape.inner_m - HitShapes.CAPSULE_RADIUS
	assert_false(_sector(shape, 0.0, Vector3(0.0, 0.0, -(hole - MARGIN))),
			"dentro del hueco (el borde de la cápsula no llega)")
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -(hole + MARGIN))),
			"el borde de la cápsula justo alcanza el anillo")
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -2.0)), "en pleno anillo")
	assert_false(_sector(shape, 0.0, Vector3(0.0, 0.0, -0.2)), "casi pegado al atacante")


func test_sector_origin_inside_capsule_ignores_angle() -> void:
	var shape := HitShape.new()
	# El atacante está dentro del disco de la víctima: no hay ángulo, y le alcanza aunque
	# la tenga «a la espalda».
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, 0.2)), "a 0,2 m por detrás")
	assert_true(_sector(shape, 0.0, Vector3.ZERO), "en el mismo punto")
	# Un poco más allá del radio sí cuenta el ángulo.
	assert_false(_sector(shape, 0.0, Vector3(0.0, 0.0, 0.45)), "a 0,45 m por detrás ya no")


func test_sector_height_overlap() -> void:
	var shape := HitShape.new()
	var height: float = HitShapes.CAPSULE_HEIGHT
	var ahead := Vector3(0.0, 0.0, -2.0)
	# La forma cubre [0,2, 2,0] sobre los pies del atacante; la cápsula, [y, y + 1,8].
	assert_true(_sector_at(shape, Vector3(ahead.x, 0.0, ahead.z)), "a la misma altura")
	assert_true(_sector_at(shape, Vector3(ahead.x, shape.height_max - MARGIN, ahead.z)),
			"los pies justo por debajo del techo de la forma")
	assert_false(_sector_at(shape, Vector3(ahead.x, shape.height_max + MARGIN, ahead.z)),
			"los pies justo por encima del techo de la forma (saltando por encima)")
	assert_true(_sector_at(shape, Vector3(ahead.x, shape.height_min - height + MARGIN, ahead.z)),
			"la cabeza justo por encima del suelo de la forma")
	assert_false(_sector_at(shape, Vector3(ahead.x, shape.height_min - height - MARGIN, ahead.z)),
			"la cabeza justo por debajo del suelo de la forma (en un foso)")
	# Las alturas son relativas a los pies del atacante.
	var origin := Vector3(0.0, 10.0, 0.0)
	assert_true(HitShapes.sector_hits_capsule(origin, 0.0, shape, Vector3(0.0, 10.0, -2.0),
			HitShapes.CAPSULE_RADIUS, height), "atacante en y = 10, objetivo a su altura")
	assert_false(HitShapes.sector_hits_capsule(origin, 0.0, shape, Vector3(0.0, 0.0, -2.0),
			HitShapes.CAPSULE_RADIUS, height), "atacante en y = 10, objetivo 10 m más abajo")
	# Las alturas de la forma se pueden estrechar (un golpe bajo).
	shape.height_min = 0.0
	shape.height_max = 0.5
	assert_true(_sector_at(shape, Vector3(ahead.x, 0.0, ahead.z)), "golpe bajo, a ras de suelo")
	assert_false(_sector_at(shape, Vector3(ahead.x, 0.6, ahead.z)),
			"golpe bajo, los pies del objetivo por encima")


# --- Segmento contra cápsula ------------------------------------------------------------------

func test_segment_hits_capsule_through_body() -> void:
	var feet := Vector3.ZERO
	var r: float = HitShapes.CAPSULE_RADIUS
	var h: float = HitShapes.CAPSULE_HEIGHT
	# Horizontal a media altura, de lado a lado: la distancia al eje es la desviación en z.
	assert_true(_segment(Vector3(-2.0, 1.0, 0.0), Vector3(2.0, 1.0, 0.0), feet, r, h),
			"por el centro")
	assert_true(_segment(Vector3(-2.0, 1.0, r - MARGIN), Vector3(2.0, 1.0, r - MARGIN), feet, r, h),
			"rozando por dentro")
	assert_false(_segment(Vector3(-2.0, 1.0, r + MARGIN), Vector3(2.0, 1.0, r + MARGIN), feet, r,
			h), "rozando por fuera")
	# Un segmento que acaba antes de llegar.
	assert_false(_segment(Vector3(-2.0, 1.0, 0.0), Vector3(-r - MARGIN, 1.0, 0.0), feet, r, h),
			"se queda a punto de tocar")
	assert_true(_segment(Vector3(-2.0, 1.0, 0.0), Vector3(-r + MARGIN, 1.0, 0.0), feet, r, h),
			"acaba justo dentro del cuerpo")
	# Un segmento que empieza detrás y atraviesa en diagonal.
	assert_true(_segment(Vector3(-3.0, 0.5, -3.0), Vector3(3.0, 1.5, 3.0), feet, r, h),
			"en diagonal por el cuerpo")
	assert_false(_segment(Vector3(-3.0, 0.5, 3.0), Vector3(3.0, 1.5, 4.0), feet, r, h),
			"en diagonal por fuera")


func test_segment_hits_capsule_end_caps() -> void:
	var feet := Vector3.ZERO
	var r: float = HitShapes.CAPSULE_RADIUS
	var h: float = HitShapes.CAPSULE_HEIGHT
	# La cápsula acaba en y = 1,8 (casquete esférico). Pasando por encima del eje:
	assert_true(_segment(Vector3(-2.0, h - MARGIN, 0.0), Vector3(2.0, h - MARGIN, 0.0), feet, r, h),
			"justo por debajo de la coronilla")
	assert_false(_segment(Vector3(-2.0, h + MARGIN, 0.0), Vector3(2.0, h + MARGIN, 0.0), feet, r,
			h), "justo por encima de la coronilla")
	assert_true(_segment(Vector3(-2.0, MARGIN, 0.0), Vector3(2.0, MARGIN, 0.0), feet, r, h),
			"justo por encima de los pies")
	assert_false(_segment(Vector3(-2.0, -MARGIN, 0.0), Vector3(2.0, -MARGIN, 0.0), feet, r, h),
			"justo por debajo de los pies")
	# En el casquete la anchura se reduce: a la altura de la coronilla - 0,05 m, un desvío de
	# 0,35 m ya queda fuera (el borde del casquete está a sqrt(0,4² - 0,35²) ≈ 0,19 m del eje).
	assert_false(_segment(Vector3(-2.0, h - 0.05, 0.35), Vector3(2.0, h - 0.05, 0.35), feet, r, h),
			"por el casquete, con desvío")
	assert_true(_segment(Vector3(-2.0, h - 0.05, 0.1), Vector3(2.0, h - 0.05, 0.1), feet, r, h),
			"por el casquete, centrado")


func test_segment_hits_capsule_vertical_and_degenerate() -> void:
	var feet := Vector3(5.0, 2.0, -1.0)
	var r: float = HitShapes.CAPSULE_RADIUS
	var h: float = HitShapes.CAPSULE_HEIGHT
	# Paralelo al eje.
	assert_true(_segment(Vector3(5.3, -10.0, -1.0), Vector3(5.3, 10.0, -1.0), feet, r, h),
			"vertical a 0,3 m del eje")
	assert_false(_segment(Vector3(5.5, -10.0, -1.0), Vector3(5.5, 10.0, -1.0), feet, r, h),
			"vertical a 0,5 m del eje")
	# Segmento de longitud 0 (un proyectil quieto).
	var inside := Vector3(5.1, 3.0, -1.1)
	assert_true(_segment(inside, inside, feet, r, h), "punto dentro")
	var outside := Vector3(6.0, 3.0, -1.0)
	assert_false(_segment(outside, outside, feet, r, h), "punto fuera")
	# La posición de la cápsula (y de los pies) cuenta.
	assert_false(_segment(Vector3(0.0, 1.0, 0.0), Vector3(10.0, 1.0, 0.0), feet, r, h),
			"a la altura de los pies del otro, pero 1 m por debajo de los de esta cápsula")
	# Una cápsula más baja que dos radios se reduce a un punto.
	assert_true(_segment(Vector3(-1.0, 0.3, 0.0), Vector3(1.0, 0.3, 0.0), Vector3.ZERO, 0.4, 0.6),
			"cápsula achaparrada, por el centro")
	assert_false(_segment(Vector3(-1.0, 0.8, 0.0), Vector3(1.0, 0.8, 0.0), Vector3.ZERO, 0.4, 0.6),
			"cápsula achaparrada, por encima")


# --- Cono frontal -----------------------------------------------------------------------------

func test_is_in_front_cone_edge() -> void:
	var defender := Vector3(1.0, 0.0, 1.0)
	for cone: float in [120.0, 90.0, 180.0]:
		var half: float = cone * 0.5
		for side: float in [1.0, -1.0]:
			var inside: Vector3 = defender + _polar(3.0, side * deg_to_rad(half - ANGLE_MARGIN_DEG))
			var outside: Vector3 = defender + _polar(3.0, side * deg_to_rad(half + ANGLE_MARGIN_DEG))
			assert_true(HitShapes.is_in_front(defender, 0.0, inside, cone),
					"cono de %d°: justo dentro (lado %d)" % [int(cone), int(side)])
			assert_false(HitShapes.is_in_front(defender, 0.0, outside, cone),
					"cono de %d°: justo fuera (lado %d)" % [int(cone), int(side)])
	assert_true(HitShapes.is_in_front(defender, 0.0, defender + Vector3(0.0, 0.0, -5.0), 120.0),
			"justo delante")
	assert_false(HitShapes.is_in_front(defender, 0.0, defender + Vector3(0.0, 0.0, 5.0), 120.0),
			"justo detrás")
	assert_true(HitShapes.is_in_front(defender, 0.0, defender + Vector3(0.0, 0.0, 5.0), 360.0),
			"un cono de 360° lo cubre todo")


func test_is_in_front_uses_defender_yaw_and_ignores_height() -> void:
	var defender := Vector3.ZERO
	# Yaw 90°: mira hacia -X.
	assert_true(HitShapes.is_in_front(defender, PI * 0.5, Vector3(-3.0, 0.0, 0.0), 120.0),
			"yaw 90°: el -X está delante")
	assert_false(HitShapes.is_in_front(defender, PI * 0.5, Vector3(0.0, 0.0, -3.0), 120.0),
			"yaw 90°: el -Z queda a 90°, fuera de un cono de 120° (±60°)")
	assert_false(HitShapes.is_in_front(defender, PI * 0.5, Vector3(3.0, 0.0, 0.0), 120.0),
			"yaw 90°: el +X está detrás")
	# La altura del atacante no cambia el ángulo horizontal.
	assert_true(HitShapes.is_in_front(defender, 0.0, Vector3(0.0, 8.0, -2.0), 120.0),
			"el atacante en un piso más alto, delante")
	assert_false(HitShapes.is_in_front(defender, 0.0, Vector3(0.0, 8.0, 2.0), 120.0),
			"el atacante en un piso más alto, detrás")
	# Justo encima: sin dirección horizontal, cuenta como delante.
	assert_true(HitShapes.is_in_front(defender, 0.0, Vector3(0.0, 3.0, 0.0), 120.0),
			"atacante en la misma vertical")


# --- Línea de visión --------------------------------------------------------------------------

func test_line_of_sight_blocked_by_wall() -> void:
	await _build_world([_wall(Vector3(0.0, 2.0, -3.0), Vector3(4.0, 4.0, 0.2))])
	var space: PhysicsDirectSpaceState3D = _viewport.find_world_3d().direct_space_state
	var attacker := Vector3.ZERO
	assert_false(HitShapes.has_line_of_sight(space, attacker, Vector3(0.0, 0.0, -6.0)),
			"el muro entre los dos")
	assert_true(HitShapes.has_line_of_sight(space, attacker, Vector3(0.0, 0.0, -2.0)),
			"el objetivo delante del muro")
	assert_true(HitShapes.has_line_of_sight(space, attacker, Vector3(0.0, 0.0, 4.0)),
			"el objetivo en el lado contrario, sin muro")
	assert_true(HitShapes.has_line_of_sight(space, attacker, Vector3(10.0, 0.0, -6.0)),
			"el objetivo detrás pero rodeando el muro (el rayo pasa por el lado)")
	assert_false(HitShapes.has_line_of_sight(space, Vector3(0.0, 0.0, -6.0), attacker),
			"el muro también corta en sentido contrario")


func test_line_of_sight_uses_chest_and_center_heights() -> void:
	# El rayo va de 1,4 m (pecho del atacante) a 0,9 m (centro de la víctima): en la mitad del
	# trayecto está a 1,15 m. Un murete de 1,0 m lo deja pasar y uno de 1,3 m lo corta.
	await _build_world([
		_wall(Vector3(-10.0, 0.5, -3.0), Vector3(4.0, 1.0, 0.2)),
		_wall(Vector3(10.0, 0.65, -3.0), Vector3(4.0, 1.3, 0.2)),
	])
	var space: PhysicsDirectSpaceState3D = _viewport.find_world_3d().direct_space_state
	assert_true(HitShapes.has_line_of_sight(space, Vector3(-10.0, 0.0, 0.0),
			Vector3(-10.0, 0.0, -6.0)), "por encima de un murete de 1,0 m")
	assert_false(HitShapes.has_line_of_sight(space, Vector3(10.0, 0.0, 0.0),
			Vector3(10.0, 0.0, -6.0)), "contra un murete de 1,3 m")
	# Las alturas son relativas a los pies: con los pies a 1 m, el murete de 1,3 m queda por debajo.
	assert_true(HitShapes.has_line_of_sight(space, Vector3(10.0, 1.0, 0.0),
			Vector3(10.0, 1.0, -6.0)), "los dos subidos 1 m encima del murete de 1,3 m")


func test_line_of_sight_only_looks_at_world_layer() -> void:
	# Un cuerpo de la capa de los personajes (2) o de los bloqueos invisibles (3) no corta el rayo.
	var character_like: StaticBody3D = _wall(Vector3(0.0, 2.0, -3.0), Vector3(4.0, 4.0, 0.2))
	character_like.collision_layer = PlayerCharacter.CHARACTER_COLLISION_LAYER
	var blocker: StaticBody3D = _wall(Vector3(0.0, 2.0, -4.0), Vector3(4.0, 4.0, 0.2))
	blocker.collision_layer = PlayerCharacter.PLAYER_BLOCKER_LAYER
	# Control: un muro de verdad, igual de grande, en otro sitio.
	var world_wall: StaticBody3D = _wall(Vector3(20.0, 2.0, -3.0), Vector3(4.0, 4.0, 0.2))
	await _build_world([character_like, blocker, world_wall])
	var space: PhysicsDirectSpaceState3D = _viewport.find_world_3d().direct_space_state
	assert_true(HitShapes.has_line_of_sight(space, Vector3.ZERO, Vector3(0.0, 0.0, -6.0)),
			"los cuerpos de otras capas no cuentan")
	assert_true(HitShapes.is_ray_clear(space, Vector3(0.0, 1.0, 0.0), Vector3(0.0, 1.0, -6.0)),
			"is_ray_clear tampoco los mira")
	assert_false(HitShapes.has_line_of_sight(space, Vector3(20.0, 0.0, 0.0),
			Vector3(20.0, 0.0, -6.0)), "el muro de la capa del mundo sí corta")


## H3a (docs/habilidades.md, 4.4): is_ray_clear usa hit_from_inside: un rayo que empieza dentro de un cuerpo
## choca en su origen (sin eso, Godot lo ignora y el dueño de un fuerte golpearía desde el vano de su puerta).
func test_a_ray_that_starts_inside_a_body_is_not_clear() -> void:
	await _build_world([_wall(Vector3(0.0, 2.0, -3.0), Vector3(4.0, 4.0, 0.6))])
	var space: PhysicsDirectSpaceState3D = _viewport.find_world_3d().direct_space_state
	assert_false(HitShapes.is_ray_clear(space, Vector3(0.0, 1.4, -3.0), Vector3(0.0, 0.9, 3.0)),
			"del interior del muro hacia fuera")
	assert_false(HitShapes.is_ray_clear(space, Vector3(0.0, 1.4, 3.0), Vector3(0.0, 0.9, -3.0)),
			"de fuera hacia el interior (entra por su cara)")
	assert_true(HitShapes.is_ray_clear(space, Vector3(0.0, 1.4, -1.0), Vector3(0.0, 0.9, 3.0)),
			"pegado al muro pero fuera, libre")


# --- Utilidades -------------------------------------------------------------------------------

## Sector contra una cápsula de personaje con sus pies en [param target_feet], desde el origen.
func test_segment_capsule_fraction_finds_the_first_entry() -> void:
	var feet := Vector3(0.0, 0.0, -10.0)
	var radius: float = 0.45
	# De frente, a media altura: entra en la cara del cilindro.
	var a := Vector3(0.0, 0.9, 0.0)
	var b := Vector3(0.0, 0.9, -20.0)
	assert_near(HitShapes.segment_capsule_fraction(a, b, feet, radius, 1.8), (10.0 - radius) / 20.0, 1e-5,
			"entra en el cilindro")
	# Por encima de la cabeza: no toca.
	assert_eq(HitShapes.segment_capsule_fraction(Vector3(0.0, 2.3, 0.0), Vector3(0.0, 2.3, -20.0), feet,
			radius, 1.8), -1.0, "por encima, -1")
	# Rozando la semiesfera de arriba: la entrada cae en la esfera.
	var top_y: float = 1.8 - radius
	var graze_y: float = top_y + 0.3
	var expected_z: float = -10.0 + sqrt(radius * radius - 0.3 * 0.3)
	var graze: float = HitShapes.segment_capsule_fraction(Vector3(0.0, graze_y, 0.0),
			Vector3(0.0, graze_y, -20.0), feet, radius, 1.8)
	assert_near(graze, -expected_z / 20.0, 1e-5, "entra por la semiesfera superior")
	# Vertical, cayendo sobre la cabeza.
	var fall: float = HitShapes.segment_capsule_fraction(Vector3(0.0, 5.0, -10.0), Vector3(0.0, 0.0, -10.0),
			feet, radius, 1.8)
	assert_near(fall, (5.0 - 1.8) / 5.0, 1e-5, "desde arriba, en lo alto de la cápsula")
	# El segmento empieza dentro: 0.
	assert_eq(HitShapes.segment_capsule_fraction(Vector3(0.1, 1.0, -10.0), Vector3(5.0, 1.0, -10.0),
			feet, radius, 1.8), 0.0, "empieza dentro: 0")
	# No llega.
	assert_eq(HitShapes.segment_capsule_fraction(a, Vector3(0.0, 0.9, -9.0), feet, radius, 1.8), -1.0,
			"se queda corto: -1")
	# Coherente con segment_hits_capsule en una nube de segmentos.
	for i: int in 200:
		var from := Vector3(sin(i * 0.37) * 3.0, 0.9 + sin(i * 0.91) * 1.5, -10.0 + cos(i * 0.53) * 3.0)
		var to := Vector3(cos(i * 0.71) * 3.0, 0.9 + cos(i * 0.29) * 1.5, -10.0 + sin(i * 0.17) * 3.0)
		var fraction: float = HitShapes.segment_capsule_fraction(from, to, feet, radius, 1.8)
		var hits: bool = HitShapes.segment_hits_capsule(from, to, feet, radius, 1.8)
		if (fraction >= 0.0) != hits:
			fail("segmento %d: fracción %s y segment_hits_capsule %s" % [i, fraction, hits])
			return
		if fraction > 0.0:
			var entry: Vector3 = from.lerp(to, fraction)
			var before: Vector3 = from.lerp(to, maxf(fraction - 0.001, 0.0))
			assert_true(HitShapes.segment_hits_capsule(entry, entry, feet, radius + 1e-4, 1.8),
					"segmento %d: el punto de entrada está en la superficie" % i)
			assert_false(HitShapes.segment_hits_capsule(from, before, feet, radius - 1e-4, 1.8),
					"segmento %d: y antes no tocaba" % i)


func test_segment_box_fraction_with_a_turned_box() -> void:
	var box := Transform3D(Basis(Vector3.UP, 0.4), Vector3(2.0, 1.0, -6.0))
	var half := Vector3(1.3, 1.0, 0.15)
	var normal: Vector3 = box.basis * Vector3(0.0, 0.0, 1.0)
	var start: Vector3 = box.origin + normal * 5.0
	var end: Vector3 = box.origin - normal * 5.0
	assert_near(HitShapes.segment_box_fraction(start, end, box, half), (5.0 - 0.15) / 10.0, 1e-5,
			"de frente, la cara")
	assert_eq(HitShapes.segment_box_fraction(box.origin, end, box, half), 0.0, "desde dentro: 0")
	var aside: Vector3 = box.basis * Vector3(2.0, 0.0, 0.0)
	assert_eq(HitShapes.segment_box_fraction(start + aside, end + aside, box, half), -1.0,
			"por el lado: -1")
	assert_eq(HitShapes.segment_box_fraction(start, box.origin + normal * 0.5, box, half), -1.0,
			"se queda corto: -1")
	var over := Vector3(0.0, 1.2, 0.0)
	assert_eq(HitShapes.segment_box_fraction(start + over, end + over, box, half), -1.0, "por encima: -1")
	assert_eq(HitShapes.segment_box_fraction(start, start, box, half), -1.0, "un punto fuera: -1")
	# Paralelo a una cara, dentro de su franja.
	var along: Vector3 = box.basis * Vector3(1.0, 0.0, 0.0)
	assert_near(HitShapes.segment_box_fraction(box.origin - along * 4.0, box.origin + along * 4.0, box, half),
			(4.0 - 1.3) / 8.0, 1e-5, "a lo largo, entra por el canto")


func _sector(shape: HitShape, yaw: float, target_feet: Vector3) -> bool:
	return HitShapes.sector_hits_capsule(Vector3.ZERO, yaw, shape, target_feet,
			HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT)


func _sector_at(shape: HitShape, target_feet: Vector3) -> bool:
	return _sector(shape, 0.0, target_feet)


func _segment(a: Vector3, b: Vector3, feet: Vector3, radius: float, height: float) -> bool:
	return HitShapes.segment_hits_capsule(a, b, feet, radius, height)


## Punto horizontal a [param distance] del origen, girado [param angle] radianes desde -Z hacia
## +X (positivo) o -X (negativo): el ángulo se mide respecto a la dirección de un yaw 0.
func _polar(distance: float, angle: float) -> Vector3:
	return Vector3(distance * sin(angle), 0.0, -distance * cos(angle))


## Muro estático de la capa del mundo, centrado en [param center].
func _wall(center: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	collision.shape = box
	body.add_child(collision)
	body.position = center
	return body


## Crea un mundo de física propio (SubViewport con own_world_3d) con [param bodies] y espera a que
## el motor de física los registre.
func _build_world(bodies: Array[StaticBody3D]) -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	for body: StaticBody3D in bodies:
		_viewport.add_child(body)
	await wait_physics_frames(3)
