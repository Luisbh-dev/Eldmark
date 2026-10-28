extends TestCase
## Pruebas de Terrain3D (GDExtension, addons/terrain_3d) en modo headless, tal como lo usará el
## servidor dedicado: sin cámara, sin ventana y con la colisión completa del terreno.
##
## Cada prueba construye en código un terreno pequeño (2 x 2 regiones de 64 m, un vértice por
## metro): una meseta a [constant BASE_HEIGHT] con una colina suave en el centro. Las alturas se
## importan con [method Terrain3DData.import_images] desde una [Image] [code]FORMAT_RF[/code]
## en metros, igual que hará el generador de zonas.
## [br][br]
## Reglas de Terrain3D 1.0.2 que estas pruebas fijan (si alguna cambia al actualizar el addon,
## el servidor también se ve afectado):
## [br]- [member Terrain3D.data] y [member Terrain3D.collision] no existen hasta que el nodo
## creado en código entra en el árbol; los [code]collision_*[/code] asignados antes se pierden
## sin aviso. Por eso todo se configura después de [method Node.add_child]. (Al instanciar una
## escena [code].tscn[/code] guardada sí se conservan.)
## [br]- Sin cámara, el primer [code]_physics_process[/code] de Terrain3D registra un error y se
## desactiva. En el servidor se desactiva antes a mano con
## [code]set_physics_process(false)[/code]: la colisión completa no lo necesita.
## [br]- [member Terrain3D.free_editor_textures] (activado por defecto) recarga los
## [Terrain3DAssets] desde su archivo cuando un terreno ya inicializado vuelve a entrar en el
## árbol (por ejemplo, si se asignó [member Terrain3D.data_directory] antes de
## [method Node.add_child] o al cambiar el nodo de padre); si no están guardados en un
## [code].tres[/code], registra un error. Aquí se desactiva por precaución.
## [br]- [method Terrain3DData.get_height] falla a menos de 1 cm de un vértice (ver
## [method test_safe_height_near_vertices]); la colisión no.
## [br][br]
## El ejecutor marca como fallida cualquier prueba que registre un error del motor, así que estas
## pruebas también comprueban que el arranque del terreno es limpio.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
## Capa del mundo estático (la que mira PlayerCharacter.collision_mask).
const WORLD_LAYER: int = 1
## Lado de cada región en vértices (y en metros, con vertex_spacing = 1).
const REGION_SIZE: Terrain3D.RegionSize = Terrain3D.SIZE_64
## Lado del mapa de alturas: 2 x 2 regiones.
const MAP_SIZE: int = 128
## Esquina del mapa: import_images coloca las regiones alineadas a la rejilla de regiones, así que
## la posición debe ser múltiplo de REGION_SIZE * vertex_spacing.
const MAP_ORIGIN: Vector3 = Vector3(-64.0, 0.0, -64.0)
const BASE_HEIGHT: float = 3.0
const HILL_HEIGHT: float = 6.0
const HILL_RADIUS: float = 30.0
## Puntos de prueba lejos del borde: el último vértice de cada eje es x = 63 y más allá
## get_height() devuelve NAN.
const FLAT_POINT: Vector3 = Vector3(-45.0, 0.0, -40.0)
const SLOPE_POINT: Vector3 = Vector3(17.0, 0.0, 3.0)
const TEMP_DATA_DIR: String = "user://test_terrain3d_headless"

var _world: Node3D
var _terrain: Terrain3D
var _dt: float = 1.0 / 60.0
var _next_tick: int = 1


func before_each() -> void:
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	_world = Node3D.new()
	_world.name = "Terrain3DTestWorld"
	tree.root.add_child(_world)


func after_each() -> void:
	if is_instance_valid(_world):
		_world.get_parent().remove_child(_world)
		_world.queue_free()
	_world = null
	_terrain = null
	await wait_process_frames()
	_remove_temp_dir()


# --- Extensión y datos ------------------------------------------------------------------------

func test_extension_is_loaded() -> void:
	assert_true(ClassDB.class_exists(&"Terrain3D"),
			"la GDExtension de Terrain3D debe estar cargada (addons/terrain_3d)")
	var terrain := Terrain3D.new()
	assert_true(terrain.version.begins_with("1.0."),
			"versión de Terrain3D 1.0.x (es %s)" % terrain.version)
	assert_null(terrain.data, "data no existe hasta que el nodo entra en el árbol")
	assert_null(terrain.collision, "collision no existe hasta que el nodo entra en el árbol")
	terrain.free()


func test_imports_heightmap_into_regions() -> void:
	_terrain = _create_terrain()
	var data: Terrain3DData = _terrain.data
	assert_eq(data.get_region_count(), 4, "un mapa de 128 x 128 con regiones de 64 son 4 regiones")
	assert_true(data.has_region(Vector2i(-1, -1)) and data.has_region(Vector2i(0, 0)),
			"regiones (-1, -1) a (0, 0)")
	for point: Vector3 in [FLAT_POINT, SLOPE_POINT, Vector3.ZERO, Vector3(10.0, 0.0, -20.0),
			Vector3(-64.0, 0.0, -64.0)]:
		assert_near(data.get_height(point), _expected_height(point), 1e-3,
				"get_height en %s" % point)
	# Entre vértices, get_height() interpola.
	var between: Vector3 = Vector3(12.5, 0.0, 7.5)
	assert_near(data.get_height(between), _expected_height(between), 0.02,
			"get_height interpola entre vértices")
	assert_true(is_nan(data.get_height(Vector3(200.0, 0.0, 0.0))),
			"fuera de las regiones get_height devuelve NAN")
	# Cada región calcula su rango al importar. El rango global de Terrain3DData parte de 0 y
	# solo crece (en 1.0.2 su mínimo no sube de 0 aunque todo el terreno esté más alto).
	var highest: float = -INF
	for location: Vector2i in data.get_region_locations():
		var region_range: Vector2 = data.get_region(location).height_range
		assert_near(region_range.x, BASE_HEIGHT, 1e-3, "altura mínima de la región %s" % location)
		highest = maxf(highest, region_range.y)
	assert_near(highest, BASE_HEIGHT + HILL_HEIGHT, 1e-3, "altura máxima de las regiones")
	assert_near(data.get_height_range().y, BASE_HEIGHT + HILL_HEIGHT, 1e-3,
			"altura máxima de Terrain3DData")


## Terrain3D 1.0.2: a menos de 1 cm de un vértice, get_height() devuelve la altura del vértice
## (floor(x), floor(z)) en vez del más cercano, con un error de hasta pendiente x separación.
## La colisión no tiene ese fallo. La consulta segura (para PNJ o puntos de aparición en el
## servidor) es [method _safe_height]: si la posición está casi en un vértice, se consulta el
## vértice exacto.
func test_safe_height_near_vertices() -> void:
	_terrain = _create_terrain()
	var data: Terrain3DData = _terrain.data
	# Esquinas de celda en la ladera, alcanzadas "desde abajo" (x y z un poco por debajo).
	var near_vertices: Array[Vector3] = [
		Vector3(7.995, 0.0, 0.001), Vector3(7.995, 0.0, 7.995), Vector3(12.997, 0.0, -5.002),
		Vector3(-9.996, 0.0, 14.997),
	]
	for point: Vector3 in near_vertices:
		var vertex: Vector3 = point.snapped(Vector3(1.0, 0.0, 1.0))
		assert_near(_safe_height(data, point), _expected_height(vertex), 1e-3,
				"altura segura junto al vértice %s" % vertex)
	await wait_physics_frames(2)
	for point: Vector3 in near_vertices:
		var hit: Dictionary = _raycast_down(point)
		if assert_false(hit.is_empty(), "el rayo en %s debe tocar el terreno" % point):
			var hit_position: Vector3 = hit["position"]
			assert_near(hit_position.y, _safe_height(data, point), 0.01,
					"la colisión coincide con la altura segura en %s" % point)


# --- Colisión ---------------------------------------------------------------------------------

func test_full_collision_covers_terrain_without_camera() -> void:
	_terrain = _create_terrain()
	assert_eq(_terrain.collision_mode, Terrain3DCollision.FULL_GAME, "modo de colisión")
	assert_true(_terrain.collision.is_enabled(), "colisión activada")
	assert_false(_terrain.collision.is_dynamic_mode(), "colisión completa, no dinámica")
	assert_eq(_terrain.collision_layer, WORLD_LAYER, "el terreno está en la capa del mundo")
	assert_null(_terrain.get_viewport().get_camera_3d(), "la prueba corre sin cámara")
	await wait_physics_frames(2)

	# En modo FULL, la colisión llega a todo el terreno, también lejos del origen (en modo
	# dinámico solo existiría en un radio alrededor de la cámara).
	for point: Vector3 in [FLAT_POINT, SLOPE_POINT, Vector3.ZERO, Vector3(55.0, 0.0, 55.0),
			Vector3(-60.0, 0.0, 50.0)]:
		var hit: Dictionary = _raycast_down(point)
		if not assert_false(hit.is_empty(), "el rayo vertical en %s debe tocar el terreno" % point):
			continue
		assert_true(hit["collider"] == _terrain,
				"en modo *_GAME el colisionador es el propio nodo Terrain3D")
		var hit_position: Vector3 = hit["position"]
		assert_near(hit_position.y, _terrain.data.get_height(point), 0.01,
				"altura de la colisión en %s" % point)


func test_player_lands_on_terrain() -> void:
	_terrain = _create_terrain()
	var character: PlayerCharacter = _spawn_character()
	if character == null:
		return
	await wait_physics_frames(2)
	if not await _begin():
		return

	# Sobre la meseta: cae 5 m y queda con los pies a la altura del terreno.
	var flat_height: float = _terrain.data.get_height(FLAT_POINT)
	var landed_tick: int = _drop(character, FLAT_POINT + Vector3(0.0, flat_height + 5.0, 0.0))
	assert_true(landed_tick > 0, "debe aterrizar en la meseta (tick %d)" % landed_tick)
	assert_true(character.grounded, "grounded tras caer en la meseta")
	assert_near(character.global_position.y, flat_height, 0.02,
			"pies sobre el terreno en la meseta")
	assert_vec_near(Vector2(character.global_position.x, character.global_position.z),
			Vector2(FLAT_POINT.x, FLAT_POINT.z), 0.01, "cae en vertical, sin deriva")
	_step(character, Vector2.ZERO, 0.0, 30)
	assert_true(character.grounded, "sigue en el suelo en reposo")
	assert_near(character.global_position.y, flat_height, 0.02, "sigue a ras de terreno")

	# En la ladera de la colina (unos 17°): la cápsula toca algo por encima del centro.
	var slope_height: float = _terrain.data.get_height(SLOPE_POINT)
	landed_tick = _drop(character, SLOPE_POINT + Vector3(0.0, slope_height + 5.0, 0.0))
	assert_true(landed_tick > 0, "debe aterrizar en la ladera (tick %d)" % landed_tick)
	assert_true(character.grounded, "grounded tras caer en la ladera")
	assert_near(character.global_position.y,
			_safe_height(_terrain.data, character.global_position), 0.06,
			"pies sobre el terreno en la ladera")


func test_player_runs_over_the_hill() -> void:
	_terrain = _create_terrain()
	var character: PlayerCharacter = _spawn_character()
	if character == null:
		return
	await wait_physics_frames(2)
	if not await _begin():
		return
	var start: Vector3 = Vector3(-40.0, 0.0, 0.0)
	if _drop(character, start + Vector3(0.0, _safe_height(_terrain.data, start) + 0.05, 0.0)) < 0:
		fail("el personaje no se posó en %s" % start)
		return

	# look_yaw = -PI/2 mira hacia +X: cruza la colina por su cima, de x = -40 a x = 35.
	var max_gap: float = 0.0
	var airborne_ticks: int = 0
	var ticks: int = 0
	while character.global_position.x < 35.0 and ticks < 1200:
		_step(character, Vector2(0.0, 1.0), -PI / 2.0)
		ticks += 1
		var ground: float = _safe_height(_terrain.data, character.global_position)
		var gap: float = character.global_position.y - ground
		if gap < -0.05:
			fail("atravesó el terreno en %s (%.3f m por debajo)" % [
				character.global_position, -gap])
			return
		max_gap = maxf(max_gap, gap)
		if not character.grounded:
			airborne_ticks += 1
	assert_true(character.global_position.x >= 35.0,
			"debe cruzar la colina (llegó a x = %.2f en %d ticks)" % [
				character.global_position.x, ticks])
	assert_true(max_gap < 0.15, "va pegado al terreno (separación máxima %.3f m)" % max_gap)
	assert_true(airborne_ticks <= 3,
			"no despega al pasar la cima (%d ticks en el aire)" % airborne_ticks)
	assert_true(character.grounded, "acaba en el suelo")


# --- Guardado y carga -------------------------------------------------------------------------

func test_saved_regions_reload_with_collision() -> void:
	_remove_temp_dir()
	DirAccess.make_dir_recursive_absolute(TEMP_DATA_DIR)
	var source: Terrain3D = _create_terrain()
	source.data.save_directory(TEMP_DATA_DIR)
	var files: PackedStringArray = DirAccess.get_files_at(TEMP_DATA_DIR)
	for location: Vector2i in source.data.get_region_locations():
		var file_name: String = Terrain3DUtil.location_to_filename(location)
		assert_true(files.has(file_name), "se guardó %s" % file_name)
	assert_eq(files.size(), 4, "un archivo .res por región")
	_world.remove_child(source)
	source.free()

	# Un nodo nuevo que solo conoce el directorio, como la escena de zona en el servidor.
	_terrain = _new_terrain()
	_world.add_child(_terrain)
	_configure_for_server(_terrain)
	_terrain.data_directory = TEMP_DATA_DIR
	assert_eq(_terrain.data.get_region_count(), 4, "regiones cargadas del directorio")
	for point: Vector3 in [FLAT_POINT, SLOPE_POINT, Vector3.ZERO]:
		assert_near(_terrain.data.get_height(point), _expected_height(point), 1e-3,
				"altura recargada en %s" % point)
	await wait_physics_frames(2)
	var hit: Dictionary = _raycast_down(Vector3(50.0, 0.0, -50.0))
	if assert_false(hit.is_empty(), "la colisión se construye al cargar las regiones"):
		var hit_position: Vector3 = hit["position"]
		assert_near(hit_position.y, BASE_HEIGHT, 0.01, "altura de la colisión recargada")


# --- Utilidades -------------------------------------------------------------------------------

## Crea el terreno de prueba dentro de [member _world], configurado como en el servidor y con el
## mapa de alturas importado.
func _create_terrain() -> Terrain3D:
	var terrain: Terrain3D = _new_terrain()
	_world.add_child(terrain)
	_configure_for_server(terrain)
	terrain.data.import_images([_build_heightmap(), null, null], MAP_ORIGIN, 0.0, 1.0)
	return terrain


func _new_terrain() -> Terrain3D:
	var terrain := Terrain3D.new()
	terrain.name = "Terrain3D"
	# Sin Terrain3DAssets guardados en un .tres, recargarlos al volver a entrar en el árbol da
	# error.
	terrain.free_editor_textures = false
	return terrain


## Lo que hará la zona en el servidor justo después de add_child().
func _configure_for_server(terrain: Terrain3D) -> void:
	# Sin cámara, _physics_process registraría un error en el primer tick.
	terrain.set_physics_process(false)
	terrain.region_size = REGION_SIZE
	terrain.vertex_spacing = 1.0
	terrain.collision_mode = Terrain3DCollision.FULL_GAME
	terrain.collision_layer = WORLD_LAYER
	terrain.collision_mask = WORLD_LAYER


func _build_heightmap() -> Image:
	var image: Image = Image.create_empty(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_RF)
	for z: int in MAP_SIZE:
		for x: int in MAP_SIZE:
			var world: Vector3 = MAP_ORIGIN + Vector3(x, 0.0, z)
			image.set_pixel(x, z, Color(_expected_height(world), 0.0, 0.0, 1.0))
	return image


## Altura del terreno en [param point] sin el fallo de get_height() junto a los vértices (ver
## [method test_safe_height_near_vertices]). Supone vertex_spacing = 1.
static func _safe_height(data: Terrain3DData, point: Vector3) -> float:
	var flat: Vector3 = Vector3(point.x, 0.0, point.z)
	var vertex: Vector3 = flat.snapped(Vector3(1.0, 0.0, 1.0))
	# Mismo umbral que Terrain3D (distancia al cuadrado < 0.0001), con margen.
	if flat.distance_squared_to(vertex) < 0.0004:
		return data.get_height(vertex)
	return data.get_height(flat)


## Meseta con una colina suave: h = base + alto * (1 - d²/r²)² dentro del radio. La pendiente
## máxima, en d = r / sqrt(3), es de unos 17°.
func _expected_height(point: Vector3) -> float:
	var d2: float = (point.x * point.x + point.z * point.z) / (HILL_RADIUS * HILL_RADIUS)
	if d2 >= 1.0:
		return BASE_HEIGHT
	return BASE_HEIGHT + HILL_HEIGHT * (1.0 - d2) * (1.0 - d2)


func _spawn_character() -> PlayerCharacter:
	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	if not assert_not_null(scene, "no se pudo cargar %s" % CHARACTER_SCENE_PATH):
		return null
	var instance: Node = scene.instantiate()
	var character: PlayerCharacter = instance as PlayerCharacter
	if not assert_not_null(character, "la raíz de %s debe ser un PlayerCharacter" % [
			CHARACTER_SCENE_PATH]):
		if instance != null:
			instance.free()
		return null
	_world.add_child(character)
	return character


## Espera un tick de física: simulate() debe llamarse dentro de él (ver test_player_movement.gd).
func _begin() -> bool:
	await wait_physics_frames()
	return assert_true(Engine.is_in_physics_frame(),
			"simulate() debe llamarse dentro del tick de física")


## Coloca al personaje en [param position] y simula en reposo hasta que aterriza. Devuelve el
## tick en el que aterrizó, o -1 si no lo hizo en 3 s.
func _drop(character: PlayerCharacter, position: Vector3) -> int:
	var state := PlayerState.new()
	state.position = position
	state.grounded = false
	character.set_state(state)
	for tick: int in range(1, 181):
		_step(character, Vector2.ZERO, 0.0)
		if character.grounded:
			_step(character, Vector2.ZERO, 0.0, 2)
			return tick
	return -1


func _step(character: PlayerCharacter, move: Vector2, look_yaw: float, ticks: int = 1) -> void:
	for _i: int in ticks:
		var input := PlayerInput.new()
		input.tick = _next_tick
		_next_tick += 1
		input.move = move
		input.look_yaw = look_yaw
		character.simulate(input.quantized(), _dt)


func _raycast_down(point: Vector3) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	# Ligeramente inclinado: los rayos perfectamente verticales pueden fallar contra
	# HeightMapShape3D (lo advierte la documentación de Terrain3D).
	var from: Vector3 = Vector3(point.x, 100.0, point.z)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.001, -200.0, 0.0),
			WORLD_LAYER)
	return space.intersect_ray(query)


func _remove_temp_dir() -> void:
	if not DirAccess.dir_exists_absolute(TEMP_DATA_DIR):
		return
	for file_name: String in DirAccess.get_files_at(TEMP_DATA_DIR):
		DirAccess.remove_absolute(TEMP_DATA_DIR.path_join(file_name))
	DirAccess.remove_absolute(TEMP_DATA_DIR)
