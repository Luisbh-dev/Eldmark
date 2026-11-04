extends TestCase
## Tests for Terrain3D (GDExtension, addons/terrain_3d) in headless mode, just as the dedicated
## server will use it: no camera, no window and with the terrain's full collision.
##
## Each test builds a small terrain in code (2 x 2 regions of 64 m, one vertex per
## meter): a plateau at [constant BASE_HEIGHT] with a gentle hill in the center. Heights are
## imported with [method Terrain3DData.import_images] from an [Image] [code]FORMAT_RF[/code]
## in meters, just as the zone generator will.
## [br][br]
## Terrain3D 1.0.2 rules that these tests pin down (if any changes when updating the addon,
## the server is affected too):
## [br]- [member Terrain3D.data] and [member Terrain3D.collision] do not exist until the node
## created in code enters the tree; the [code]collision_*[/code] properties assigned earlier are lost
## without warning. That is why everything is configured after [method Node.add_child]. (When instantiating a
## saved [code].tscn[/code] scene they are kept.)
## [br]- Without a camera, Terrain3D's first [code]_physics_process[/code] logs an error and
## disables itself. On the server it is disabled beforehand by hand with
## [code]set_physics_process(false)[/code]: full collision does not need it.
## [br]- [member Terrain3D.free_editor_textures] (on by default) reloads the
## [Terrain3DAssets] from their file when an already initialized terrain re-enters the
## tree (for example, if [member Terrain3D.data_directory] was assigned before
## [method Node.add_child] or when the node is reparented); if they are not saved in a
## [code].tres[/code], it logs an error. Here it is disabled as a precaution.
## [br]- [method Terrain3DData.get_height] fails within 1 cm of a vertex (see
## [method test_safe_height_near_vertices]); collision does not.
## [br][br]
## The runner marks as failed any test that logs an engine error, so these
## tests also check that terrain startup is clean.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
## Static world layer (the one PlayerCharacter.collision_mask looks at).
const WORLD_LAYER: int = 1
## Side of each region in vertices (and in meters, with vertex_spacing = 1).
const REGION_SIZE: Terrain3D.RegionSize = Terrain3D.SIZE_64
## Side of the height map: 2 x 2 regions.
const MAP_SIZE: int = 128
## Corner of the map: import_images places regions aligned to the region grid, so
## the position must be a multiple of REGION_SIZE * vertex_spacing.
const MAP_ORIGIN: Vector3 = Vector3(-64.0, 0.0, -64.0)
const BASE_HEIGHT: float = 3.0
const HILL_HEIGHT: float = 6.0
const HILL_RADIUS: float = 30.0
## Test points away from the edge: the last vertex of each axis is x = 63 and beyond that
## get_height() returns NAN.
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


# --- Extension and data -----------------------------------------------------------------------

func test_extension_is_loaded() -> void:
	assert_true(ClassDB.class_exists(&"Terrain3D"),
			"the Terrain3D GDExtension must be loaded (addons/terrain_3d)")
	var terrain := Terrain3D.new()
	assert_true(terrain.version.begins_with("1.0."),
			"Terrain3D version 1.0.x (it is %s)" % terrain.version)
	assert_null(terrain.data, "data does not exist until the node enters the tree")
	assert_null(terrain.collision, "collision does not exist until the node enters the tree")
	terrain.free()


func test_imports_heightmap_into_regions() -> void:
	_terrain = _create_terrain()
	var data: Terrain3DData = _terrain.data
	assert_eq(data.get_region_count(), 4, "a 128 x 128 map with 64 regions is 4 regions")
	assert_true(data.has_region(Vector2i(-1, -1)) and data.has_region(Vector2i(0, 0)),
			"regions (-1, -1) to (0, 0)")
	for point: Vector3 in [FLAT_POINT, SLOPE_POINT, Vector3.ZERO, Vector3(10.0, 0.0, -20.0),
			Vector3(-64.0, 0.0, -64.0)]:
		assert_near(data.get_height(point), _expected_height(point), 1e-3,
				"get_height at %s" % point)
	# Between vertices, get_height() interpolates.
	var between: Vector3 = Vector3(12.5, 0.0, 7.5)
	assert_near(data.get_height(between), _expected_height(between), 0.02,
			"get_height interpolates between vertices")
	assert_true(is_nan(data.get_height(Vector3(200.0, 0.0, 0.0))),
			"outside the regions get_height returns NAN")
	# Each region computes its range on import. Terrain3DData's global range starts at 0 and
	# only grows (in 1.0.2 its minimum does not rise above 0 even if the whole terrain is higher).
	var highest: float = -INF
	for location: Vector2i in data.get_region_locations():
		var region_range: Vector2 = data.get_region(location).height_range
		assert_near(region_range.x, BASE_HEIGHT, 1e-3, "minimum height of region %s" % location)
		highest = maxf(highest, region_range.y)
	assert_near(highest, BASE_HEIGHT + HILL_HEIGHT, 1e-3, "maximum height of the regions")
	assert_near(data.get_height_range().y, BASE_HEIGHT + HILL_HEIGHT, 1e-3,
			"maximum height of Terrain3DData")


## Terrain3D 1.0.2: within 1 cm of a vertex, get_height() returns the height of vertex
## (floor(x), floor(z)) instead of the nearest one, with an error of up to slope x spacing.
## Collision does not have that flaw. The safe query (for NPCs or spawn points on the
## server) is [method _safe_height]: if the position is almost on a vertex, the exact
## vertex is queried.
func test_safe_height_near_vertices() -> void:
	_terrain = _create_terrain()
	var data: Terrain3DData = _terrain.data
	# Cell corners on the slope, reached "from below" (x and z slightly below).
	var near_vertices: Array[Vector3] = [
		Vector3(7.995, 0.0, 0.001), Vector3(7.995, 0.0, 7.995), Vector3(12.997, 0.0, -5.002),
		Vector3(-9.996, 0.0, 14.997),
	]
	for point: Vector3 in near_vertices:
		var vertex: Vector3 = point.snapped(Vector3(1.0, 0.0, 1.0))
		assert_near(_safe_height(data, point), _expected_height(vertex), 1e-3,
				"safe height next to vertex %s" % vertex)
	await wait_physics_frames(2)
	for point: Vector3 in near_vertices:
		var hit: Dictionary = _raycast_down(point)
		if assert_false(hit.is_empty(), "the ray at %s must hit the terrain" % point):
			var hit_position: Vector3 = hit["position"]
			assert_near(hit_position.y, _safe_height(data, point), 0.01,
					"the collision matches the safe height at %s" % point)


# --- Collision --------------------------------------------------------------------------------

func test_full_collision_covers_terrain_without_camera() -> void:
	_terrain = _create_terrain()
	assert_eq(_terrain.collision_mode, Terrain3DCollision.FULL_GAME, "collision mode")
	assert_true(_terrain.collision.is_enabled(), "collision enabled")
	assert_false(_terrain.collision.is_dynamic_mode(), "full collision, not dynamic")
	assert_eq(_terrain.collision_layer, WORLD_LAYER, "the terrain is on the world layer")
	assert_null(_terrain.get_viewport().get_camera_3d(), "the test runs without a camera")
	await wait_physics_frames(2)

	# In FULL mode, collision covers the whole terrain, also far from the origin (in dynamic
	# mode it would only exist within a radius around the camera).
	for point: Vector3 in [FLAT_POINT, SLOPE_POINT, Vector3.ZERO, Vector3(55.0, 0.0, 55.0),
			Vector3(-60.0, 0.0, 50.0)]:
		var hit: Dictionary = _raycast_down(point)
		if not assert_false(hit.is_empty(), "the vertical ray at %s must hit the terrain" % point):
			continue
		assert_true(hit["collider"] == _terrain,
				"in *_GAME mode the collider is the Terrain3D node itself")
		var hit_position: Vector3 = hit["position"]
		assert_near(hit_position.y, _terrain.data.get_height(point), 0.01,
				"collision height at %s" % point)


func test_player_lands_on_terrain() -> void:
	_terrain = _create_terrain()
	var character: PlayerCharacter = _spawn_character()
	if character == null:
		return
	await wait_physics_frames(2)
	if not await _begin():
		return

	# On the plateau: it falls 5 m and ends up with its feet at terrain height.
	var flat_height: float = _terrain.data.get_height(FLAT_POINT)
	var landed_tick: int = _drop(character, FLAT_POINT + Vector3(0.0, flat_height + 5.0, 0.0))
	assert_true(landed_tick > 0, "it must land on the plateau (tick %d)" % landed_tick)
	assert_true(character.grounded, "grounded after falling onto the plateau")
	assert_near(character.global_position.y, flat_height, 0.02,
			"feet on the terrain on the plateau")
	assert_vec_near(Vector2(character.global_position.x, character.global_position.z),
			Vector2(FLAT_POINT.x, FLAT_POINT.z), 0.01, "falls vertically, with no drift")
	_step(character, Vector2.ZERO, 0.0, 30)
	assert_true(character.grounded, "stays on the ground at rest")
	assert_near(character.global_position.y, flat_height, 0.02, "stays flush with the terrain")

	# On the hill's slope (about 17°): the capsule touches something above the center.
	var slope_height: float = _terrain.data.get_height(SLOPE_POINT)
	landed_tick = _drop(character, SLOPE_POINT + Vector3(0.0, slope_height + 5.0, 0.0))
	assert_true(landed_tick > 0, "it must land on the slope (tick %d)" % landed_tick)
	assert_true(character.grounded, "grounded after falling onto the slope")
	assert_near(character.global_position.y,
			_safe_height(_terrain.data, character.global_position), 0.06,
			"feet on the terrain on the slope")


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
		fail("the character did not settle at %s" % start)
		return

	# look_yaw = -PI/2 looks toward +X: it crosses the hill over its summit, from x = -40 to x = 35.
	var max_gap: float = 0.0
	var airborne_ticks: int = 0
	var ticks: int = 0
	while character.global_position.x < 35.0 and ticks < 1200:
		_step(character, Vector2(0.0, 1.0), -PI / 2.0)
		ticks += 1
		var ground: float = _safe_height(_terrain.data, character.global_position)
		var gap: float = character.global_position.y - ground
		if gap < -0.05:
			fail("it went through the terrain at %s (%.3f m below)" % [
				character.global_position, -gap])
			return
		max_gap = maxf(max_gap, gap)
		if not character.grounded:
			airborne_ticks += 1
	assert_true(character.global_position.x >= 35.0,
			"it must cross the hill (reached x = %.2f in %d ticks)" % [
				character.global_position.x, ticks])
	assert_true(max_gap < 0.15, "it hugs the terrain (maximum separation %.3f m)" % max_gap)
	assert_true(airborne_ticks <= 3,
			"it does not take off when passing the summit (%d ticks in the air)" % airborne_ticks)
	assert_true(character.grounded, "ends up on the ground")


# --- Saving and loading -----------------------------------------------------------------------

func test_saved_regions_reload_with_collision() -> void:
	_remove_temp_dir()
	DirAccess.make_dir_recursive_absolute(TEMP_DATA_DIR)
	var source: Terrain3D = _create_terrain()
	source.data.save_directory(TEMP_DATA_DIR)
	var files: PackedStringArray = DirAccess.get_files_at(TEMP_DATA_DIR)
	for location: Vector2i in source.data.get_region_locations():
		var file_name: String = Terrain3DUtil.location_to_filename(location)
		assert_true(files.has(file_name), "%s was saved" % file_name)
	assert_eq(files.size(), 4, "one .res file per region")
	_world.remove_child(source)
	source.free()

	# A new node that only knows the directory, like the zone scene on the server.
	_terrain = _new_terrain()
	_world.add_child(_terrain)
	_configure_for_server(_terrain)
	_terrain.data_directory = TEMP_DATA_DIR
	assert_eq(_terrain.data.get_region_count(), 4, "regions loaded from the directory")
	for point: Vector3 in [FLAT_POINT, SLOPE_POINT, Vector3.ZERO]:
		assert_near(_terrain.data.get_height(point), _expected_height(point), 1e-3,
				"reloaded height at %s" % point)
	await wait_physics_frames(2)
	var hit: Dictionary = _raycast_down(Vector3(50.0, 0.0, -50.0))
	if assert_false(hit.is_empty(), "the collision is built when loading the regions"):
		var hit_position: Vector3 = hit["position"]
		assert_near(hit_position.y, BASE_HEIGHT, 0.01, "reloaded collision height")


# --- Utilities --------------------------------------------------------------------------------

## Creates the test terrain inside [member _world], configured as on the server and with the
## height map imported.
func _create_terrain() -> Terrain3D:
	var terrain: Terrain3D = _new_terrain()
	_world.add_child(terrain)
	_configure_for_server(terrain)
	terrain.data.import_images([_build_heightmap(), null, null], MAP_ORIGIN, 0.0, 1.0)
	return terrain


func _new_terrain() -> Terrain3D:
	var terrain := Terrain3D.new()
	terrain.name = "Terrain3D"
	# Without Terrain3DAssets saved in a .tres, reloading them on re-entering the tree gives an
	# error.
	terrain.free_editor_textures = false
	return terrain


## What the zone will do on the server right after add_child().
func _configure_for_server(terrain: Terrain3D) -> void:
	# Without a camera, _physics_process would log an error on the first tick.
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


## Terrain height at [param point] without get_height()'s flaw next to vertices (see
## [method test_safe_height_near_vertices]). Assumes vertex_spacing = 1.
static func _safe_height(data: Terrain3DData, point: Vector3) -> float:
	var flat: Vector3 = Vector3(point.x, 0.0, point.z)
	var vertex: Vector3 = flat.snapped(Vector3(1.0, 0.0, 1.0))
	# Same threshold as Terrain3D (squared distance < 0.0001), with margin.
	if flat.distance_squared_to(vertex) < 0.0004:
		return data.get_height(vertex)
	return data.get_height(flat)


## Plateau with a gentle hill: h = base + height * (1 - d²/r²)² within the radius. The maximum
## slope, at d = r / sqrt(3), is about 17°.
func _expected_height(point: Vector3) -> float:
	var d2: float = (point.x * point.x + point.z * point.z) / (HILL_RADIUS * HILL_RADIUS)
	if d2 >= 1.0:
		return BASE_HEIGHT
	return BASE_HEIGHT + HILL_HEIGHT * (1.0 - d2) * (1.0 - d2)


func _spawn_character() -> PlayerCharacter:
	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	if not assert_not_null(scene, "%s could not be loaded" % CHARACTER_SCENE_PATH):
		return null
	var instance: Node = scene.instantiate()
	var character: PlayerCharacter = instance as PlayerCharacter
	if not assert_not_null(character, "the root of %s must be a PlayerCharacter" % [
			CHARACTER_SCENE_PATH]):
		if instance != null:
			instance.free()
		return null
	_world.add_child(character)
	return character


## Waits one physics tick: simulate() must be called inside it (see test_player_movement.gd).
func _begin() -> bool:
	await wait_physics_frames()
	return assert_true(Engine.is_in_physics_frame(),
			"simulate() must be called inside the physics tick")


## Places the character at [param position] and simulates at rest until it lands. Returns the
## tick on which it landed, or -1 if it did not within 3 s.
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
	# Slightly tilted: perfectly vertical rays can fail against
	# HeightMapShape3D (Terrain3D's documentation warns of this).
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
