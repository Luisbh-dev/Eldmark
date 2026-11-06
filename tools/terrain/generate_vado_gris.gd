extends SceneTree
## Vado Gris generator (phase 4): Terrain3D terrain, paint, grass and vegetation, and the
## zone scene with all its pieces and collisions.
##
## Usage (from the project root, with the editor closed):
## [codeblock]
## godot --headless --path . -s res://tools/terrain/generate_vado_gris.gd
## [/codeblock]
## Prerequisites (once): tools/assets/copy_vado_gris_assets.gd, --import,
## tools/assets/extract_kit_meshes.gd, tools/materials/build_realm_materials.gd and
## tools/props/build_vado_gris_props.gd. See docs/zones/vado_gris.md.
## [br][br]
## It is deterministic and can be repeated: it deletes and rewrites the region data
## (scenes/world/zones/vado_gris/terrain/*.res), the terrain assets and vado_gris.tscn. Everything
## in the scene comes from here and from vado_gris_layout.gd: to change the zone you
## change the generator, not the scene by hand.
## [br][br]
## A single pass computes the positions of trees and rocks: the meshes go to the Terrain3D
## instancer (visual only, no collision) and the collisions (one cylinder per trunk or rock) are
## saved in the scene, so the dedicated server has exactly the same ones.

const Layout = preload("res://tools/terrain/vado_gris_layout.gd")
const BakedMultiMeshScript: GDScript = preload("res://scripts/world/baked_multimesh.gd")
const ZoneRootScript: GDScript = preload("res://scripts/world/zone_root.gd")
const WallLightTagScript: GDScript = preload("res://scripts/world/wall_light_tag.gd")

const ZONE_DIR: String = "res://scenes/world/zones/vado_gris"
const DATA_DIR: String = ZONE_DIR + "/terrain"
const TERRAIN_ASSETS_PATH: String = ZONE_DIR + "/vado_gris_terrain_assets.tres"
const WATER_MESH_PATH: String = ZONE_DIR + "/vado_gris_river_water.tres"
const SCENE_PATH: String = ZONE_DIR + "/vado_gris.tscn"
const SKY_SHADER_PATH: String = "res://assets/materials/shaders/storm_sky.gdshader"
const ENVIRONMENT_PATH: String = "res://assets/environments/vado_gris_frontier.tres"
const WATER_MATERIAL_PATH: String = "res://assets/materials/water/river_eldrun.tres"

const TEX_DIR: String = "res://assets/textures/terrain/polyhaven/"
const NATURE_DIR: String = "res://assets/models/environment/nature/"
const PROPS: String = "res://scenes/world/props/"
const MAT: String = "res://assets/materials/realms/"
const CW_MESH: String = "res://assets/models/environment/castle_wall/meshes/"
const VIL_MESH: String = "res://assets/models/environment/village/meshes/"
const CUSTOM_MESH: String = "res://assets/models/environment/custom/"

## Layer of the static world (characters, camera and, later, shots).
const WORLD_LAYER: int = PlayerCharacter.WORLD_COLLISION_LAYER
## Layer of the invisible blockers that stop only the player: limits, deep banks and the closing
## of the channel. The camera does not look at it (it does not stick to the head next to a bank).
const PLAYER_BLOCKER_LAYER: int = PlayerCharacter.PLAYER_BLOCKER_LAYER
const SEED: int = 20261028
## Definition of the Vado Gris fortress (`definition` metadata of the fort node).
const FORTRESS_DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
## Id of the fortress (the `id` of its definition): `fortress` metadata of its respawn points.
const FORTRESS_ID: StringName = &"vado_gris_fort"
## Respawn points inside the fort, in fort coordinates (x to the east, z to the south):
## the yard east of the bonfire and the tower, outside the capture circle cylinder (center
## x = -8.5, radius 5 m), mirrored north-south and facing the gate.
const FORT_RESPAWN_LOCAL: Array[Vector2] = [
	Vector2(11.0, -6.0), Vector2(11.0, -2.0), Vector2(11.0, 2.0), Vector2(11.0, 6.0),
]
## Positions (x, |z|) of the two Gate Guardians of each camp: on the sides of the
## gate towers, inside the safe zone.
const GUARDIAN_SPOTS: Array[Vector2] = [Vector2(-11.0, 142.5), Vector2(11.0, 142.5)]
## Seconds it takes a dead Gate Guardian to respawn.
const GUARDIAN_RESPAWN_S: float = 30.0
## x positions of the four spawn points of each camp.
const CAMP_SPAWN_XS: Array[float] = [-7.5, -2.5, 2.5, 7.5]
## Outer half-width of the bridges (deck + parapet): the deep banks end here.
const BRIDGE_OUTER_HALF: float = Layout.BRIDGE_WIDTH * 0.5 + 0.4

## Terrain textures (the index is the Terrain3D id): [file (without suffix), name, uv_scale,
## tint]. They are the Poly Haven CC0 ones processed by tools/assets/process_terrain_textures.py:
## desaturated, with the height in the albedo alpha and the normal with the roughness in the normal
## alpha (ART-55). The uv_scale is the inverse of the tile side in meters: grass and dirt
## at 3 m, gravel at 2 m and rock at 4.5 m; up close you see grain, stones and blades, and the projection
## on slopes avoids stretched streaks. Large-scale repetition is broken up by each texture's rotation
## offset, the macro variation of the material and the color map.
const TERRAIN_TEXTURES: Array[Array] = [
	["grass_ground", "Hierba", 0.3, Color(0.84, 1.08, 0.76)],
	["grass_ground", "Hierba seca", 0.27, Color(1.06, 1.02, 0.84)],
	["dirt_floor", "Tierra", 0.34, Color(0.86, 0.86, 0.86)],
	["ground_grey", "Grava", 0.5, Color(1.0, 1.0, 1.0)],
	["rock_boulder_dry", "Roca", 0.24, Color(0.74, 0.76, 0.8)],
	["grass_ground", "Hierba verde", 0.3, Color(0.74, 1.2, 0.64)],
	["rocky_trail", "Lecho", 0.38, Color(0.95, 0.95, 0.95)],
	["damp_beach_sand", "Barro de orilla", 0.4, Color(0.9, 0.88, 0.84)],
	["snow_02", "Nieve", 0.3, Color(1.0, 1.0, 1.02)],
	["forest_ground_06", "Suelo de bosque", 0.32, Color(1.0, 1.0, 1.0)],
]
## Threshold of the Terrain3D slope projection (0 to 0.99): beyond that steepness the
## texture is projected sideways instead of stretching along the slope.
const PROJECTION_THRESHOLD: float = 0.6
const T_GRASS: int = 0
const T_DRY: int = 1
const T_DIRT: int = 2
const T_GRAVEL: int = 3
const T_ROCK: int = 4
const T_LUSH: int = 5
const T_BED: int = 6
const T_MUD: int = 7
const T_SNOW: int = 8
const T_FOREST: int = 9

## Materials that replace the glTF's in the instancer (Eldrun tone).
const MESH_MATERIALS: Dictionary = {
	0: "res://assets/materials/vegetation/grass_blade_green.tres",
	1: "res://assets/materials/vegetation/grass_blade_wispy.tres",
	14: "res://assets/materials/vegetation/path_stones.tres",
	15: "res://assets/materials/vegetation/path_stones.tres",
	25: "res://assets/materials/vegetation/leaves_green.tres",
	26: "res://assets/materials/vegetation/leaves_green.tres",
	27: "res://assets/materials/vegetation/grass_blade_tall.tres",
	31: "res://assets/materials/vegetation/grass_blade_dry.tres",
	32: "res://assets/materials/vegetation/grass_blade_lush.tres",
	33: "res://assets/materials/vegetation/grass_blade_frost.tres",
	28: "res://assets/materials/vegetation/path_stones.tres",
	29: "res://assets/materials/vegetation/path_stones.tres",
}

## Instancer meshes (the index is the id): [glTF, name, visible range (m), shadow].
## Terrain3D creates one MultiMesh per variant and 32 m cell, so each extra variant
## multiplies the draw calls: the tree variants are few (five per family, from those
## the kit already ships) and the undergrowth is only seen up close. New ids go at the end so as not to
## shift those the rest of the generator already uses.
const MESHES: Array[Array] = [
	["grass_common_short.gltf", "Hierba corta", 48.0, false],
	["grass_wispy_short.gltf", "Hierba seca", 40.0, false],
	["pine_1.gltf", "Pino 1", 260.0, true],
	["pine_2.gltf", "Pino 2", 260.0, true],
	["pine_3.gltf", "Pino 3", 260.0, true],
	["common_tree_1.gltf", "Caducifolio 1", 260.0, true],
	["common_tree_2.gltf", "Caducifolio 2", 260.0, true],
	["common_tree_3.gltf", "Caducifolio 3", 260.0, true],
	["dead_tree_1.gltf", "Árbol muerto 1", 260.0, true],
	["dead_tree_2.gltf", "Árbol muerto 2", 260.0, true],
	["rock_medium_1.gltf", "Roca 1", 150.0, true],
	["rock_medium_2.gltf", "Roca 2", 150.0, true],
	["rock_medium_3.gltf", "Roca 3", 150.0, true],
	["bush_common_flowers.gltf", "Arbusto", 120.0, false],
	["rock_path_square_wide.gltf", "Losa de calzada", 120.0, false],
	["rock_path_round_wide.gltf", "Losa redonda", 120.0, false],
	["pine_4.gltf", "Pino 4", 260.0, true],
	["pine_5.gltf", "Pino 5", 260.0, true],
	["common_tree_4.gltf", "Caducifolio 4", 260.0, true],
	["common_tree_5.gltf", "Caducifolio 5", 260.0, true],
	["dead_tree_3.gltf", "Árbol muerto 3", 260.0, true],
	["dead_tree_4.gltf", "Árbol muerto 4", 260.0, true],
	["dead_tree_5.gltf", "Árbol muerto 5", 260.0, true],
	["twisted_tree_1.gltf", "Retorcido 1", 260.0, true],
	["twisted_tree_2.gltf", "Retorcido 2", 260.0, true],
	["fern_1.gltf", "Helecho", 60.0, false],
	["plant_1_big.gltf", "Planta grande", 60.0, false],
	["grass_common_tall.gltf", "Hierba alta", 60.0, false],
	["pebble_round_2.gltf", "Guijarro redondo", 40.0, false],
	["pebble_square_1.gltf", "Guijarro cuadrado", 40.0, false],
	["mushroom_common.gltf", "Seta", 30.0, false],
	["grass_common_short.gltf", "Hierba corta seca", 48.0, false],
	["grass_common_short.gltf", "Hierba corta viva", 48.0, false],
	["grass_common_short.gltf", "Hierba corta escarchada", 48.0, false],
]
const M_GRASS: int = 0
const M_GRASS_DRY: int = 1
const M_PINE: int = 2
const M_COMMON: int = 5
const M_DEAD: int = 8
const M_ROCK: int = 10
const M_BUSH: int = 13
const M_PATH: int = 14
const M_TWISTED: int = 23
const M_FERN: int = 25
const M_PLANT: int = 26
const M_TALL_GRASS: int = 27
const M_PEBBLE: int = 28
const M_MUSHROOM: int = 30
const M_GRASS_DRY_SHORT: int = 31
const M_GRASS_LUSH: int = 32
const M_GRASS_FROST: int = 33
## Ids of the variants of each tree family (those of pine, deciduous and dead are in the
## kit's order; the extra ones, at the end of the mesh list).
const TREE_VARIANTS: Dictionary = {
	M_PINE: [2, 3, 4, 16, 17],
	M_COMMON: [5, 6, 7, 18, 19],
	M_DEAD: [8, 9, 20, 21, 22],
	M_TWISTED: [23, 24],
}
## Thickness of the road slabs (m): they are sunk so that their top face is flush.
const PATH_SLAB_SINK: Dictionary = {M_PATH: 0.155, M_PATH + 1: 0.095}
## Maximum slope (degrees) for placing a slab: on the fort's slopes they would hang in the air.
const PATH_SLAB_MAX_SLOPE: float = 7.0

## Scale factor of the variants that the kit ships taller than the first three of their family
## (DeadTree_3 to _5 are 13 to 16 m tall and Pine_4 10 m, against the 7 to 11 m of the others): it only
## affects the drawing, never the collision.
const VARIANT_SCALE: Dictionary = {16: 0.8, 17: 0.9, 18: 0.85, 20: 0.78, 21: 0.8, 22: 0.62}
## Trunk radius (m, at scale 1) for the collision of each tree family.
const TRUNK_RADIUS: Dictionary = {M_PINE: 0.4, M_COMMON: 0.38, M_DEAD: 0.45}
## Radius of the trunk base of each family (m, at scale 1), measured on the meshes: how much a tree has to
## be sunk per unit of slope so that no air is left under its downhill side.
const ROOT_RADIUS: Dictionary = {M_PINE: 0.27, M_COMMON: 0.74, M_DEAD: 0.67, M_TWISTED: 0.6}
## Above this slope (degrees) no trees are planted: rock and scree go there (ART-58).
const TREE_MAX_SLOPE: float = 45.0
## Height and base radius of the kit's medium rocks (m, at scale 1), measured on the meshes.
const ROCK_HEIGHT: float = 2.2
const ROCK_RADIUS: float = 1.8
## Fraction of its height that a rock with collision is sunk (the collision is not touched: the drawing stays at
## the height of its cylinder) and a loose rock on the edge, which can end up half buried.
const GAMEPLAY_ROCK_SINK: float = 0.14
const LOOSE_ROCK_SINK: float = 0.45

var _layout: Layout
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
## Separate generator for what is only decoration (undergrowth, pebbles): this way the gameplay
## cover (trees and rocks with collision), which comes from [member _rng], never moves.
var _decor_rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _terrain: Terrain3D
var _zone: Node3D
var _heights: PackedFloat32Array
var _instances: Dictionary = {}
var _tree_colliders: Array[Dictionary] = []
var _rock_colliders: Array[Dictionary] = []
var _occupied: Array[Vector3] = []
var _floor_xforms: Array[Transform3D] = []
var _rubble_xforms: Array[Transform3D] = []
var _failed: bool = false


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var started: int = Time.get_ticks_msec()
	_layout = Layout.new()
	_rng.seed = SEED
	_decor_rng.seed = SEED + 7
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DATA_DIR))

	_zone = Node3D.new()
	_zone.name = "VadoGris"
	_zone.set_script(ZoneRootScript)
	_zone.set(&"zone_id", &"vado_gris")
	root.add_child(_zone)

	print("[1/6] Alturas y pintura (%d x %d)..." % [Layout.MAP_SIZE, Layout.MAP_SIZE])
	var height_image: Image = _build_height_image()
	var control_image: Image = _build_control_image()
	var color_image: Image = _build_color_image()
	print("[2/6] Terrain3D...")
	_create_terrain(height_image, control_image, color_image)
	print("[3/6] Vegetación...")
	_place_vegetation()
	print("[4/6] Guardando datos del terreno...")
	_save_terrain()
	print("[5/6] Montando la escena...")
	_assemble_scene()
	print("[6/6] Guardando %s..." % SCENE_PATH)
	_save_scene()
	print("Listo en %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	quit(1 if _failed else 0)


# =============================================================================================
# Terrain
# =============================================================================================

func _build_height_image() -> Image:
	var size: int = Layout.MAP_SIZE
	var image: Image = Image.create_empty(size, size, false, Image.FORMAT_RF)
	_heights = PackedFloat32Array()
	_heights.resize(size * size)
	for pz: int in size:
		for px: int in size:
			var x: float = Layout.MAP_ORIGIN.x + px
			var z: float = Layout.MAP_ORIGIN.z + pz
			var h: float = _layout.height(x, z)
			_heights[pz * size + px] = h
			image.set_pixel(px, pz, Color(h, 0.0, 0.0, 1.0))
	return image


func _height_at_pixel(px: int, pz: int) -> float:
	var size: int = Layout.MAP_SIZE
	return _heights[clampi(pz, 0, size - 1) * size + clampi(px, 0, size - 1)]


## Slope in degrees at a pixel (central differences, 1 m between vertices).
func _slope_at_pixel(px: int, pz: int) -> float:
	var dx: float = (_height_at_pixel(px + 1, pz) - _height_at_pixel(px - 1, pz)) * 0.5
	var dz: float = (_height_at_pixel(px, pz + 1) - _height_at_pixel(px, pz - 1)) * 0.5
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))


## Control map: base texture, overlay texture and per-pixel blend, according to slope,
## height, distance to the river, roads and gameplay zones.
func _build_control_image() -> Image:
	var size: int = Layout.MAP_SIZE
	var image: Image = Image.create_empty(size, size, false, Image.FORMAT_RF)
	for pz: int in size:
		for px: int in size:
			var x: float = Layout.MAP_ORIGIN.x + px
			var z: float = Layout.MAP_ORIGIN.z + pz
			var paint: Vector3i = _paint(x, z, _height_at_pixel(px, pz), _slope_at_pixel(px, pz))
			var base: int = paint.x
			var overlay: int = paint.y
			var blend: int = clampi(paint.z, 0, 255)
			# Terrain3D 1.0.2: base == overlay with blend 255 looks black.
			if base == overlay:
				blend = 0
			var bits: int = Terrain3DUtil.enc_base(base) | Terrain3DUtil.enc_overlay(overlay) \
					| Terrain3DUtil.enc_blend(blend)
			image.set_pixel(px, pz, Color(Terrain3DUtil.as_float(bits), 0.0, 0.0, 1.0))
	return image


## Returns (base, overlay, blend 0..255).
func _paint(x: float, z: float, h: float, slope: float) -> Vector3i:
	var n: float = _layout.paint_noise(x, z)
	var n2: float = _layout.paint_noise(x * 2.3 + 91.0, z * 2.3 - 37.0)
	# Grass: dry and gray toward the north and in the center (Eldrun), greener toward the south.
	var south: float = smoothstep(-20.0, 150.0, z)
	var north: float = smoothstep(-20.0, 150.0, -z)
	var base: int = T_GRASS
	var overlay: int = T_DRY
	var blend: float = clampf(0.45 + n * 1.3 + north * 0.35 - south * 0.55, 0.0, 1.0)
	if z > 20.0 and n2 > -0.1:
		overlay = T_LUSH
		blend = clampf(south * 0.9 + n2 * 0.8, 0.0, 1.0)

	# Steep slopes and mountain: rock.
	var rock: float = smoothstep(30.0, 46.0, slope + n2 * 9.0)
	var high: float = smoothstep(28.0, 46.0, h + n * 8.0)
	if rock > 0.0 or high > 0.0:
		var r: float = maxf(rock, high * 0.7)
		if r > 0.5:
			base = T_ROCK
			overlay = T_GRAVEL if h > 55.0 + n * 10.0 else T_DRY
			blend = clampf((1.0 - r) * 2.0 + (0.4 if overlay == T_GRAVEL else 0.0), 0.0, 1.0)
		else:
			overlay = T_ROCK
			blend = r * 2.0

	# Identity of each half (ART-62), paint only (the gameplay layer stays mirrored): in the north
	# (Vardheim) patchy snow on the grass and dark forest floor under the conifers, and continuous
	# snow up high; in the south (Solmarch) green grass and lively soil, no snow. Outside the
	# playable area the difference is greater.
	var outside: float = smoothstep(0.0, 14.0, maxf(absf(x) - Layout.PLAY_HALF, absf(z) - Layout.WALL_Z))
	if z < 0.0 and base != T_ROCK:
		var snow_noise: float = _layout.paint_noise(x * 0.9 + 400.0, z * 0.9 + 77.0)
		var snow_zone: float = smoothstep(-70.0, -150.0, z) * 0.55 + outside * 0.35 + smoothstep(18.0, 45.0, h) * 0.5
		var snow: float = smoothstep(0.02, 0.28, snow_noise + snow_zone - 0.45)
		if snow > 0.05:
			overlay = T_SNOW
			blend = snow
		if outside > 0.3 and h < 40.0 and snow < 0.4:
			overlay = T_FOREST
			blend = clampf(0.5 + n * 0.6, 0.0, 1.0)
	elif z >= 0.0 and base != T_ROCK and outside > 0.3 and h < 40.0:
		overlay = T_LUSH
		blend = clampf(0.55 + n2 * 0.5, 0.0, 1.0)
	# Summits and crags: rock rules, with snow on the northern peaks.
	if high > 0.8 and z < -20.0 and h > 62.0:
		overlay = T_SNOW
		blend = clampf((h - 62.0) / 14.0, 0.0, 1.0)

	var grass_base: int = base
	# Foot of the walls and camps: trampled earth with bald patches of grass.
	var az: float = absf(z)
	var wall_band: float = 1.0 - smoothstep(3.0, 9.0, absf(az - Layout.WALL_Z))
	var camp: float = 1.0 - smoothstep(Layout.CAMP_RADIUS - 8.0, Layout.CAMP_RADIUS + 2.0, Layout.camp_distance(x, z))
	var trodden: float = maxf(wall_band * (1.0 - smoothstep(150.0, 175.0, absf(x))), camp)
	if trodden > 0.05:
		base = T_GRAVEL if n2 > 0.1 else T_DIRT
		overlay = T_DRY if z < 0.0 else T_GRASS
		blend = clampf(1.0 - trodden + n * 0.9 + 0.3, 0.0, 1.0)

	# Fort plateau: earth and gravel.
	var fort_d: float = Layout.fort_sdf(x, z)
	if fort_d < 6.0:
		base = T_DIRT
		overlay = T_GRAVEL if fort_d < 1.0 else T_DRY
		blend = clampf(0.35 + n * 0.6 if fort_d < 1.0 else smoothstep(1.0, 6.0, fort_d), 0.0, 1.0)

	# Roads: gray gravel core (the old road of Eld, with the slabs on top in the
	# instancer) that turns to dirt and blends into the grass at an edge broken up by noise, with
	# fractional blend (not 0/1) so that the outline does not follow the 1 m grid.
	var road: float = Layout.road_distance(x, z) + n * 1.4 + n2 * 0.6
	if road < 4.2:
		if road < 1.8:
			base = T_GRAVEL
			overlay = T_DIRT
			blend = clampf(smoothstep(0.6, 1.8, road) * 0.7 + n2 * 0.2, 0.0, 0.85)
		else:
			base = T_DIRT
			overlay = grass_base if fort_d >= 6.0 else T_DRY
			blend = smoothstep(1.8, 4.2, road)

	# River: dark bed, gray gravel ford (the "Vado Gris"), banks of mud and gravel.
	var d: float = Layout.river_distance(x, z) + n * 1.2
	var ford: float = Layout.ford_factor(x, z)
	if d < Layout.WATER_HALF_WIDTH + 1.0 + ford * 6.0:
		base = T_BED if ford < 0.5 else T_GRAVEL
		overlay = T_GRAVEL if ford < 0.5 else T_BED
		blend = clampf((0.25 + n2 * 0.5) if ford < 0.5 else 0.3 + n * 0.4, 0.0, 1.0)
	elif d < 12.0 + ford * 8.0:
		base = T_GRAVEL if ford > 0.3 else T_MUD
		overlay = T_DIRT if ford > 0.3 else T_GRAVEL
		var t: float = smoothstep(Layout.WATER_HALF_WIDTH + 1.0, 12.0 + ford * 8.0, d)
		blend = clampf(0.5 + n * 0.8, 0.0, 1.0) * (1.0 - t * 0.5)
		if t > 0.55:
			overlay = grass_base
			blend = smoothstep(0.55, 1.0, t)
	if absf(x - Layout.BRIDGE_X) < BRIDGE_OUTER_HALF + 1.5 and absf(absf(z) - Layout.RIVER_RADIUS) < Layout.BRIDGE_LENGTH * 0.5 + 2.0:
		base = T_GRAVEL
		overlay = T_DIRT
		blend = clampf(0.25 + n2 * 0.3, 0.0, 0.6)
	return Vector3i(base, overlay, roundi(blend * 255.0))


## Color map (multiplies the albedo): large patches of light and shadow, browner dry
## bald patches and greener, darker banks, so that the valley is not a uniform green. The alpha
## is Terrain3D's roughness modifier (0.5 = neutral).
func _build_color_image() -> Image:
	var size: int = Layout.MAP_SIZE
	var image: Image = Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	for pz: int in size:
		for px: int in size:
			var x: float = Layout.MAP_ORIGIN.x + px
			var z: float = Layout.MAP_ORIGIN.z + pz
			var large: float = _layout.paint_noise(x * 0.3, z * 0.3)
			var small: float = _layout.paint_noise(x * 1.7 + 13.0, z * 1.7 - 7.0)
			var bright: float = 0.92 + large * 0.16 + small * 0.06
			var tint: Color = Color(1.0, 1.0, 1.0)
			var dry: float = smoothstep(0.05, 0.45, _layout.paint_noise(x * 0.6 - 40.0, z * 0.6 + 25.0))
			tint = tint.lerp(Color(1.08, 1.0, 0.82), dry * 0.6)
			var d: float = Layout.river_distance(x, z)
			var wet: float = 1.0 - smoothstep(10.0, 26.0, d)
			tint = tint.lerp(Color(0.86, 0.95, 0.88), wet * 0.7)
			var h: float = _height_at_pixel(px, pz)
			var high: float = smoothstep(20.0, 60.0, h)
			tint = tint.lerp(Color(0.95, 0.97, 1.02), high)
			image.set_pixel(px, pz, Color(clampf(bright * tint.r, 0.0, 1.0), clampf(bright * tint.g, 0.0, 1.0),
					clampf(bright * tint.b, 0.0, 1.0), 0.5))
	return image


func _create_terrain(height_image: Image, control_image: Image, color_image: Image) -> void:
	_terrain = Terrain3D.new()
	_terrain.name = "Terrain3D"
	_zone.add_child(_terrain)
	_terrain.set_physics_process(false)
	_terrain.region_size = Terrain3D.SIZE_256
	_terrain.vertex_spacing = 1.0
	_terrain.collision_mode = Terrain3DCollision.FULL_GAME
	_terrain.collision_layer = WORLD_LAYER
	_terrain.collision_mask = WORLD_LAYER
	# The material that the node itself creates is tweaked (assigning a new one in headless logs
	# errors from the dummy render server). No flat background outside the regions.
	_terrain.material.world_background = Terrain3DMaterial.NONE
	# Softer transitions between textures (with the height blend of the watercolor
	# textures) and large-scale color variation so that the paint edges do not follow the
	# 1 m grid of the control map.
	_terrain.material.set_shader_param(&"blend_sharpness", 0.45)
	_terrain.material.set_shader_param(&"enable_projection", true)
	_terrain.material.set_shader_param(&"projection_threshold", PROJECTION_THRESHOLD)
	_terrain.material.set_shader_param(&"enable_macro_variation", true)
	_terrain.material.set_shader_param(&"macro_variation1", Color(0.86, 0.87, 0.83))
	_terrain.material.set_shader_param(&"macro_variation2", Color(0.94, 0.9, 0.85))
	_terrain.material.set_shader_param(&"macro_variation_slope", 0.4)

	var assets := Terrain3DAssets.new()
	for i: int in TERRAIN_TEXTURES.size():
		var spec: Array = TERRAIN_TEXTURES[i]
		var texture := Terrain3DTextureAsset.new()
		texture.name = spec[1]
		texture.albedo_texture = load(TEX_DIR + spec[0] + "_alb_ht.png") as Texture2D
		texture.normal_texture = load(TEX_DIR + spec[0] + "_nrm_rough.png") as Texture2D
		texture.uv_scale = spec[2]
		texture.detiling_rotation = 0.2
		texture.roughness = 0.0
		texture.normal_depth = 1.0
		texture.ao_strength = 0.0
		texture.albedo_color = spec[3]
		assets.set_texture(i, texture)
	for i: int in MESHES.size():
		var spec: Array = MESHES[i]
		var mesh_asset := Terrain3DMeshAsset.new()
		mesh_asset.name = spec[1]
		mesh_asset.scene_file = load(NATURE_DIR + spec[0]) as PackedScene
		mesh_asset.height_offset = 0.0
		mesh_asset.lod0_range = spec[2]
		mesh_asset.fade_margin = 8.0 if spec[2] < 100.0 else 20.0
		mesh_asset.cast_shadows = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if spec[3] \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if MESH_MATERIALS.has(i):
			mesh_asset.material_override = load(MESH_MATERIALS[i]) as Material
		assets.set_mesh_asset(i, mesh_asset)
	var error: Error = assets.save(TERRAIN_ASSETS_PATH)
	if error != OK:
		_fail("No se pudieron guardar los assets del terreno (%s)" % error_string(error))
	_terrain.assets = load(TERRAIN_ASSETS_PATH) as Terrain3DAssets
	_terrain.data.import_images([height_image, control_image, color_image], Layout.MAP_ORIGIN, 0.0, 1.0)
	_terrain.data.calc_height_range(true)
	print("   regiones: %d" % _terrain.data.get_region_count())


## Terrain height without the get_height() flaw next to vertices (Terrain3D 1.0.2).
func _ground(x: float, z: float) -> float:
	var flat: Vector3 = Vector3(x, 0.0, z)
	var vertex: Vector3 = flat.snapped(Vector3(1.0, 0.0, 1.0))
	if flat.distance_squared_to(vertex) < 0.0004:
		return _terrain.data.get_height(vertex)
	return _terrain.data.get_height(flat)


func _ground_slope(x: float, z: float) -> float:
	var dx: float = (_ground(x + 1.0, z) - _ground(x - 1.0, z)) * 0.5
	var dz: float = (_ground(x, z + 1.0) - _ground(x, z - 1.0)) * 0.5
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))


func _save_terrain() -> void:
	var global_dir: String = ProjectSettings.globalize_path(DATA_DIR)
	DirAccess.make_dir_recursive_absolute(global_dir)
	for file_name: String in DirAccess.get_files_at(DATA_DIR):
		if file_name.begins_with("terrain3d") and file_name.get_extension() == "res":
			DirAccess.remove_absolute(DATA_DIR.path_join(file_name))
	for mesh_id: int in _instances:
		var xforms: Array[Transform3D] = []
		xforms.assign(_instances[mesh_id])
		_terrain.instancer.add_transforms(mesh_id, xforms)
		print("   instancias %s: %d" % [MESHES[mesh_id][1], xforms.size()])
	_terrain.data_directory = DATA_DIR
	_terrain.data.save_directory(DATA_DIR)
	for file_name: String in DirAccess.get_files_at(DATA_DIR):
		print("   %s (%.0f KB)" % [file_name, FileAccess.get_file_as_bytes(DATA_DIR.path_join(file_name)).size() / 1024.0])


# =============================================================================================
# Vegetation
# =============================================================================================

func _add_instance(mesh_id: int, xform: Transform3D) -> void:
	if not _instances.has(mesh_id):
		_instances[mesh_id] = []
	(_instances[mesh_id] as Array).append(xform)


func _place_vegetation() -> void:
	_place_gameplay_cover()
	_place_border_forest()
	_place_grass()
	_place_bushes()
	_place_road_stones()
	print("   colisiones: %d troncos, %d rocas" % [_tree_colliders.size(), _rock_colliders.size()])


## Can a gameplay tree or rock be placed here (north half)?
func _cover_allowed(x: float, z: float, clearance: float) -> bool:
	if absf(x) > Layout.PLAY_HALF - 5.0 or z > -6.0 or z < -Layout.WALL_Z + 9.0:
		return false
	if Layout.river_distance(x, z) < 13.0:
		return false
	if Layout.road_distance(x, z) < 4.5:
		return false
	if Layout.fort_sdf(x, z) < 9.0:
		return false
	if Layout.camp_distance(x, z) < Layout.CAMP_RADIUS + 3.0:
		return false
	if _in_ruins(x, z, 5.0):
		return false
	if _ground_slope(x, z) > 24.0:
		return false
	var p := Vector3(x, 0.0, z)
	for other: Vector3 in _occupied:
		if Vector2(p.x, p.z).distance_to(Vector2(other.x, other.z)) < clearance + other.y:
			return false
	return true


## Gameplay cover (trees and rocks with collision). It is generated in the north half and mirrored
## on the z = 0 axis: same position, same collision radius; only the model changes (pines in the
## north, deciduous in the south). This way both realms have exactly the same cover.
func _place_gameplay_cover() -> void:
	# Groves on the flanks: [center, radius, trees].
	var groves: Array[Array] = [
		[Vector2(-118, -112), 18.0, 9], [Vector2(-72, -128), 12.0, 5], [Vector2(-130, -62), 13.0, 5],
		[Vector2(70, -122), 16.0, 8], [Vector2(118, -96), 16.0, 7], [Vector2(112, -132), 10.0, 4],
		[Vector2(36, -88), 9.0, 3],
	]
	for grove: Array in groves:
		var center: Vector2 = grove[0]
		var placed: int = 0
		var attempts: int = 0
		while placed < grove[2] and attempts < 200:
			attempts += 1
			var angle: float = _rng.randf_range(0.0, TAU)
			var radius: float = sqrt(_rng.randf()) * grove[1]
			var x: float = center.x + cos(angle) * radius
			var z: float = center.y + sin(angle) * radius
			if not _cover_allowed(x, z, 6.0):
				continue
			var family: int = M_PINE if z < -70.0 else M_DEAD
			_add_mirrored_tree(x, z, family)
			placed += 1
	# Loose dead trees in the central strip (Eldrun) and on the peninsula.
	var singles: int = 0
	var attempts: int = 0
	while singles < 9 and attempts < 400:
		attempts += 1
		var x: float = _rng.randf_range(-140.0, 140.0)
		var z: float = _rng.randf_range(-95.0, -14.0)
		if not _cover_allowed(x, z, 12.0):
			continue
		_add_mirrored_tree(x, z, M_DEAD)
		singles += 1
	# Rocks: cover groups on the plains, near the banks and next to the peninsula.
	var rock_spots: Array[Vector2] = [
		Vector2(-40, -118), Vector2(-96, -88), Vector2(-60, -40), Vector2(-26, -76), Vector2(24, -102),
		Vector2(58, -74), Vector2(96, -70), Vector2(132, -118), Vector2(-138, -100), Vector2(64, -30),
		Vector2(106, -22), Vector2(-120, -40), Vector2(-48, -138), Vector2(40, -136),
	]
	for spot: Vector2 in rock_spots:
		var count: int = _rng.randi_range(1, 3)
		for i: int in count:
			var x: float = spot.x + _rng.randf_range(-5.0, 5.0)
			var z: float = spot.y + _rng.randf_range(-5.0, 5.0)
			if not _cover_allowed(x, z, 3.5):
				continue
			var scale: float = _rng.randf_range(0.7, 1.35)
			var mesh_id: int = M_ROCK + _rng.randi_range(0, 2)
			var yaw: float = _rng.randf_range(0.0, TAU)
			for mirror: int in 2:
				var mz: float = z if mirror == 0 else -z
				var my: float = yaw if mirror == 0 else PI - yaw
				# The collision stays where it was (cylinder from 0.15 of scale below the ground);
				# only the drawing settles on the slope (ART-58).
				var y: float = _ground(x, mz) - 0.15 * scale
				_add_instance(mesh_id, _settle_rock(x, mz, scale, scale, my, GAMEPLAY_ROCK_SINK, 0.8))
				_rock_colliders.append({"position": Vector3(x, y, mz), "radius": 1.35 * scale, "height": 2.0 * scale})
				_scatter_pebbles(x, mz, 2.6 * scale)
			_occupied.append(Vector3(x, 1.6 * scale, z))


func _add_mirrored_tree(x: float, z: float, family: int) -> void:
	var variants: Array = TREE_VARIANTS[family]
	var variant: int = _rng.randi_range(0, variants.size() - 1)
	# Somewhat bigger than the kit model (7.3 m): next to 12 m walls and 18 m towers
	# trees at scale 1 looked like bushes.
	var scale: float = _rng.randf_range(1.05, 1.4)
	var yaw: float = _rng.randf_range(0.0, TAU)
	for mirror: int in 2:
		var mz: float = z if mirror == 0 else -z
		var mesh_family: int = family
		var mesh_variant: int = variant
		if mirror == 1 and family == M_PINE:
			mesh_family = M_COMMON
			mesh_variant = variant % (TREE_VARIANTS[M_COMMON] as Array).size()
		var mesh_id: int = (TREE_VARIANTS[mesh_family] as Array)[mesh_variant]
		# The collision stays at h - 0.1; the drawing also sinks according to the slope (ART-58).
		var y: float = _ground(x, mz) - 0.1
		var visual_scale: float = scale * float(VARIANT_SCALE.get(mesh_id, 1.0))
		var basis: Basis = Basis(Vector3.UP, yaw if mirror == 0 else PI - yaw).scaled(Vector3(visual_scale, visual_scale, visual_scale))
		_add_instance(mesh_id, Transform3D(basis, Vector3(x, _trunk_y(x, mz, mesh_family, visual_scale, 0.1), mz)))
		_tree_colliders.append({"position": Vector3(x, y, mz), "radius": TRUNK_RADIUS[family] * scale, "height": 7.0})
		_scatter_undergrowth(x, mz, 5.0, 7)
	_occupied.append(Vector3(x, 2.5, z))


## Height at which a tree is placed (ART-58): the ground minus [param base_sink] minus how much it has to
## be sunk according to the slope, tan(slope) times the radius of its base, so that the downhill side of the
## trunk is not left in the air. Above [constant TREE_MAX_SLOPE] no trees are placed.
func _trunk_y(x: float, z: float, family: int, scale: float, base_sink: float) -> float:
	var slope: float = minf(_ground_slope(x, z), TREE_MAX_SLOPE)
	return _ground(x, z) - base_sink - tan(deg_to_rad(slope)) * float(ROOT_RADIUS[family]) * scale


## Position and rotation of a rock settled on the slope (ART-58): tilted toward the terrain normal
## ([param tilt] from 0 to 1) and sunk a fraction [param sink_fraction] of its height plus the gap that
## the missing tilt leaves. Scale [param scale_xz] horizontally and [param scale_y] vertically.
func _settle_rock(x: float, z: float, scale_xz: float, scale_y: float, yaw: float, sink_fraction: float,
		tilt: float) -> Transform3D:
	var normal: Vector3 = _ground_normal(x, z)
	var axis: Vector3 = Vector3.UP.lerp(normal, tilt).normalized()
	var residual: float = acos(clampf(axis.dot(normal), -1.0, 1.0))
	var basis: Basis = _basis_on_normal(axis, yaw) * Basis.from_scale(Vector3(scale_xz, scale_y, scale_xz))
	var sink: float = sink_fraction * ROCK_HEIGHT * scale_y + tan(residual) * ROCK_RADIUS * scale_xz
	return Transform3D(basis, Vector3(x, _ground(x, z) - sink, z))


## Undergrowth around a trunk (ART-59): ferns, plants, mushrooms and tall grass. Drawing only (no
## collision), with the decoration generator so as not to move the gameplay cover. It does not step on roads,
## river, fort, camps or ruins.
func _scatter_undergrowth(x: float, z: float, radius: float, count: int) -> void:
	var kinds: Array[int] = [M_FERN, M_FERN, M_PLANT, M_TALL_GRASS, M_MUSHROOM]
	for i: int in count:
		var angle: float = _decor_rng.randf_range(0.0, TAU)
		var dist: float = radius * (0.3 + 0.7 * sqrt(_decor_rng.randf()))
		var px: float = x + cos(angle) * dist
		var pz: float = z + sin(angle) * dist
		var kind: int = kinds[_decor_rng.randi_range(0, kinds.size() - 1)]
		var scale: float = _decor_rng.randf_range(0.3, 0.55)
		var yaw: float = _decor_rng.randf_range(0.0, TAU)
		if not _decor_allowed(px, pz, 2.5, 32.0):
			continue
		match kind:
			M_PLANT:
				scale *= 0.7
			M_TALL_GRASS:
				scale = _decor_rng.randf_range(0.5, 0.85)
			M_MUSHROOM:
				scale = _decor_rng.randf_range(0.8, 1.4)
		var basis: Basis = Basis(Vector3.UP, yaw).scaled(Vector3(scale, scale, scale))
		_add_instance(kind, Transform3D(basis, Vector3(px, _ground(px, pz) - 0.03, pz)))


## Pebbles around a rock (ART-59), drawing only.
func _scatter_pebbles(x: float, z: float, radius: float) -> void:
	for i: int in _decor_rng.randi_range(3, 6):
		var angle: float = _decor_rng.randf_range(0.0, TAU)
		var dist: float = radius * (0.5 + 0.5 * _decor_rng.randf())
		var px: float = x + cos(angle) * dist
		var pz: float = z + sin(angle) * dist
		var scale: float = _decor_rng.randf_range(0.8, 1.7)
		var yaw: float = _decor_rng.randf_range(0.0, TAU)
		var kind: int = M_PEBBLE + _decor_rng.randi_range(0, 1)
		if not _decor_allowed(px, pz, 3.0, 24.0):
			continue
		var basis: Basis = Basis(Vector3.UP, yaw).scaled(Vector3(scale, scale, scale))
		_add_instance(kind, Transform3D(basis, Vector3(px, _ground(px, pz) - 0.02, pz)))


## Does (x, z) fall inside the playable area (the square of [constant Layout.PLAY_HALF] up to the walls)?
static func _in_play_area(x: float, z: float) -> bool:
	return absf(x) <= Layout.PLAY_HALF and absf(z) <= Layout.WALL_Z


## Can loose decoration be placed here? Away from roads (margin [param road_margin] m), the
## river, the fort, the camps and the ruins, and on slopes under [param max_slope].
func _decor_allowed(x: float, z: float, road_margin: float, max_slope: float) -> bool:
	if Layout.road_distance(x, z) < road_margin or Layout.river_distance(x, z) < 11.5:
		return false
	if Layout.fort_sdf(x, z) < 3.0 or Layout.camp_distance(x, z) < Layout.CAMP_RADIUS:
		return false
	if _in_ruins(x, z, 1.0):
		return false
	var h: float = _ground(x, z)
	return not is_nan(h) and _ground_slope(x, z) <= max_slope


## Border forest, outside the playable area (no collision: it cannot be reached). Pines in the north,
## deciduous in the south and dead and twisted trees where they meet, as the visual identity
## asks. There are no trees above [constant TREE_MAX_SLOPE]: scree goes there (ART-58).
func _place_border_forest() -> void:
	var step: float = 6.5
	var count: int = 0
	var gx: float = Layout.MAP_ORIGIN.x + 4.0
	while gx < 252.0:
		var gz: float = Layout.MAP_ORIGIN.z + 4.0
		while gz < 252.0:
			var x: float = gx + _rng.randf_range(-4.0, 4.0)
			var z: float = gz + _rng.randf_range(-4.0, 4.0)
			gz += step
			var outside: bool = absf(x) > Layout.PLAY_HALF + 2.0 or absf(z) > Layout.WALL_Z + 12.0
			if not outside:
				continue
			if absf(x) < Layout.WALL_HALF_LENGTH + 4.0 and absf(absf(z) - Layout.WALL_Z) < 12.0:
				continue
			# Road passage behind each gate, kept clear.
			if absf(x) < 14.0 and absf(z) > Layout.WALL_Z:
				continue
			if Layout.river_distance(x, z) < 15.0:
				continue
			var h: float = _ground(x, z)
			if is_nan(h) or h > 110.0:
				continue
			var slope: float = _ground_slope(x, z)
			# Slopes over 45°: rock scree instead of trees.
			if slope > TREE_MAX_SLOPE:
				if _rng.randf() < 0.45:
					_add_scree(x, z)
				continue
			# Forest in clumps (noise), thinning out on steep slopes (from 38° up) instead of
			# staying only on the ridges.
			var clump: float = _layout.paint_noise(x * 0.5 + 300.0, z * 0.5 - 120.0)
			var density: float = (0.85 if z < -40.0 else 0.7) * clampf(0.8 + clump * 1.4, 0.2, 1.0)
			density *= 1.0 - smoothstep(34.0, 50.0, slope) * 0.55
			# Farther from the playable area the forest thins out (primitive budget, and at that
			# distance the fog blends it into a mass).
			var beyond: float = maxf(absf(x) - Layout.PLAY_HALF, absf(z) - Layout.WALL_Z)
			density *= lerpf(1.0, 0.45, smoothstep(30.0, 110.0, beyond))
			if _rng.randf() > density:
				if slope > 34.0 and _rng.randf() < 0.18:
					_add_scree(x, z)
				# Treeless slopes: scrub (ferns, plants and bushes) so they do not stay bare.
				if slope > 20.0 and _decor_rng.randf() < 0.6:
					_scatter_scrub(x, z)
				continue
			var family: int
			if z < -40.0:
				family = M_PINE
			elif z > 40.0:
				family = M_COMMON
			else:
				var pick: float = _rng.randf()
				family = M_DEAD if pick < 0.4 else (M_TWISTED if pick < 0.55 else (M_PINE if _rng.randf() < 0.5 else M_COMMON))
			var variants: Array = TREE_VARIANTS[family]
			# Border conifers much bigger (the mountains reach 80 m and the Frost
			# Wall is 12 m tall): same kit model, at mountain forest scale. The kit's twisted
			# ones are huge (17 m at scale 1) and are scaled down.
			var scale: float
			if family == M_TWISTED:
				scale = _rng.randf_range(0.5, 0.7)
			elif family == M_PINE:
				scale = _rng.randf_range(1.5, 2.2)
			else:
				scale = _rng.randf_range(1.3, 1.8)
			var basis: Basis = Basis(Vector3.UP, _rng.randf_range(0.0, TAU))
			var mesh_id: int = variants[_rng.randi_range(0, variants.size() - 1)]
			scale *= float(VARIANT_SCALE.get(mesh_id, 1.0))
			basis = basis.scaled(Vector3(scale, scale, scale))
			_add_instance(mesh_id, Transform3D(basis, Vector3(x, _trunk_y(x, z, family, scale, 0.15), z)))
			count += 1
			# Undergrowth at the foot of some trees (ART-59).
			if _decor_rng.randf() < 0.8:
				_scatter_undergrowth(x, z, 4.0, 4)
			if _rng.randf() < 0.12:
				var rock_scale: float = _rng.randf_range(0.8, 1.8)
				var rx: float = x + _rng.randf_range(-3.0, 3.0)
				var rz: float = z + _rng.randf_range(-3.0, 3.0)
				var rh: float = _ground(rx, rz)
				var rock_id: int = M_ROCK + _rng.randi_range(0, 2)
				var rock_yaw: float = _rng.randf_range(0, TAU)
				# Inside the playable area every rock has collision: loose ones go only outside.
				if not is_nan(rh) and not _in_play_area(rx, rz):
					_add_instance(rock_id, _settle_rock(rx, rz, rock_scale, rock_scale, rock_yaw,
							LOOSE_ROCK_SINK, 0.85))
		gx += step
	print("   bosque del borde: %d árboles" % count)


## Loose scree rocks on a steep slope at the border (no collision: it cannot be reached), tilted
## with the slope and half buried (ART-58).
func _add_scree(x: float, z: float) -> void:
	# Scree in rivulets, not polka dots: 3 to 6 rocks of different sizes aligned with the line of
	# steepest slope (downhill), the small ones on the sides, and pebbles among them.
	var normal: Vector3 = _ground_normal(x, z)
	var downhill: Vector2 = Vector2(normal.x, normal.z)
	downhill = downhill.normalized() if downhill.length() > 0.01 else Vector2(0.0, 1.0)
	var count: int = _rng.randi_range(3, 6)
	for i: int in count:
		var along: float = _rng.randf_range(-2.0, 5.0)
		var side: float = _rng.randf_range(-1.8, 1.8)
		var rx: float = x + downhill.x * along - downhill.y * side
		var rz: float = z + downhill.y * along + downhill.x * side
		var rh: float = _ground(rx, rz)
		var big: bool = i < 2
		var rock_scale: float = _rng.randf_range(0.9, 1.7) if big else _rng.randf_range(0.3, 0.8)
		var rock_yaw: float = _rng.randf_range(0.0, TAU)
		var rock_id: int = M_ROCK + _rng.randi_range(0, 2)
		# Inside the playable area every rock has collision: scree goes only outside.
		if is_nan(rh) or absf(rx) > 246.0 or absf(rz) > 246.0 or _in_play_area(rx, rz):
			continue
		_add_instance(rock_id, _settle_rock(rx, rz, rock_scale, rock_scale * 0.8, rock_yaw, LOOSE_ROCK_SINK, 0.9))
		if not big and _decor_rng.randf() < 0.7:
			_scatter_pebbles(rx, rz, 1.2 * rock_scale + 0.6)


## Grass (instancer, no collision, visible up to 48 m): in tufts grouped by a patch noise
## (thick meadow and clearings, not a grid), dry and gray toward the center (Eldrun) and the
## north, somewhat greener toward the south. Each 1 m cell has its position at random inside the
## cell, so no rows are visible.
func _place_grass() -> void:
	var step: float = 1.0
	var gx: float = -186.0
	while gx < 186.0:
		var gz: float = -176.0
		while gz < 176.0:
			var cx: float = gx
			var cz: float = gz
			gz += step
			var d: float = Layout.river_distance(cx, cz)
			if d < 10.5 + Layout.ford_factor(cx, cz) * 8.0:
				continue
			var road: float = Layout.road_distance(cx, cz)
			if road < 2.4:
				continue
			if Layout.fort_sdf(cx, cz) < 3.0:
				continue
			if absf(absf(cz) - Layout.WALL_Z) < 4.0 and absf(cx) < 190.0:
				continue
			# Patches: high density in the meadows, clearings between them.
			var clump: float = _layout.paint_noise(cx * 2.2 + 57.0, cz * 2.2 - 11.0) * 0.7 \
					+ _layout.paint_noise(cx * 0.7 - 23.0, cz * 0.7 + 41.0) * 0.6
			var keep: float = clampf(0.9 + clump * 0.6, 0.55, 1.0)
			# Next to the roads, a thicker edge of tufts.
			if road < 4.5:
				keep = maxf(keep, 0.7)
			if Layout.camp_distance(cx, cz) < Layout.CAMP_RADIUS:
				keep *= 0.3
			if _in_ruins(cx, cz, 0.5):
				keep *= 0.35
			if _rng.randf() > (keep * 0.6 if not _in_play_area(cx, cz) else keep):
				continue
			var tufts: int = 3 if keep < 0.8 else 5
			# Outside the playable area the grass is only seen from afar: half the density keeps the
			# region files (and the server pack) small.
			var outside: bool = not _in_play_area(cx, cz)
			if outside:
				tufts = mini(tufts, 2)
			for t: int in tufts:
				var x: float = cx + _rng.randf_range(-0.5, 0.5)
				var z: float = cz + _rng.randf_range(-0.5, 0.5)
				var h: float = _ground(x, z)
				if is_nan(h) or h > 40.0 or _ground_slope(x, z) > 32.0:
					continue
				var dryness: float = clampf(0.5 + _layout.paint_noise(x, z) * 1.3 + smoothstep(-20.0, 150.0, -z) * 0.4 - smoothstep(-20.0, 150.0, z) * 0.6, 0.0, 1.0)
				var center: float = 1.0 - smoothstep(30.0, 110.0, absf(z))
				var dry_chance: float = clampf(dryness * 0.8 + center * 0.3, 0.0, 0.92)
				var mesh_id: int = _grass_variant(z, dry_chance)
				var scale: float = _rng.randf_range(0.18, 0.3) if road < 4.5 else _rng.randf_range(0.2, 0.36)
				var basis: Basis = Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(Vector3(scale, scale * _rng.randf_range(0.8, 1.2), scale))
				_add_instance(mesh_id, Transform3D(basis, Vector3(x, h - 0.03, z)))
		gx += step


## Slope scrub (ART-59): a patch of ferns, plants and bushes, drawing only.
func _scatter_scrub(x: float, z: float) -> void:
	if absf(x) > 246.0 or absf(z) > 246.0 or _in_play_area(x, z):
		return
	var kinds: Array[int] = [M_FERN, M_FERN, M_PLANT, M_BUSH, M_TALL_GRASS]
	for i: int in _decor_rng.randi_range(3, 6):
		var px: float = x + _decor_rng.randf_range(-4.0, 4.0)
		var pz: float = z + _decor_rng.randf_range(-4.0, 4.0)
		var kind: int = kinds[_decor_rng.randi_range(0, kinds.size() - 1)]
		var h: float = _ground(px, pz)
		if is_nan(h) or absf(px) > 246.0 or absf(pz) > 246.0 or _ground_slope(px, pz) > 50.0:
			continue
		var scale: float = _decor_rng.randf_range(0.5, 0.9) if kind != M_BUSH else _decor_rng.randf_range(0.7, 1.2)
		var basis: Basis = Basis(Vector3.UP, _decor_rng.randf_range(0.0, TAU)).scaled(Vector3(scale, scale, scale))
		_add_instance(kind, Transform3D(basis, Vector3(px, h - 0.05, pz)))


## Grass variant according to the zone (ART-59 and ART-62): in the north (Vardheim) frosted tufts and
## cold greens, in the central strip (Eldrun) dry and gray, in the south (Solmarch) vivid green. The
## thin, expensive-leaved one (wispy, 190 triangles) only comes in at a small proportion.
func _grass_variant(z: float, dry_chance: float) -> int:
	if _rng.randf() < dry_chance:
		return M_GRASS_DRY if _rng.randf() < 0.18 else M_GRASS_DRY_SHORT
	if z < -55.0 and _rng.randf() < smoothstep(-55.0, -120.0, z) * 0.9 + 0.1:
		return M_GRASS_FROST
	if z > 55.0 and _rng.randf() < smoothstep(55.0, 120.0, z) * 0.9 + 0.1:
		return M_GRASS_LUSH
	return M_GRASS


## Decorative bushes (no collision) on banks, grove edges and ruins.
func _place_bushes() -> void:
	var placed: int = 0
	var attempts: int = 0
	while placed < 70 and attempts < 2000:
		attempts += 1
		var x: float = _rng.randf_range(-145.0, 145.0)
		var z: float = _rng.randf_range(-145.0, -6.0)
		var d: float = Layout.river_distance(x, z)
		var near_bank: bool = d > 12.5 and d < 20.0
		if not near_bank and _rng.randf() < 0.6:
			continue
		if Layout.road_distance(x, z) < 3.5 or Layout.fort_sdf(x, z) < 6.0 or d < 12.5:
			continue
		if Layout.camp_distance(x, z) < Layout.CAMP_RADIUS or _in_ruins(x, z, 1.0):
			continue
		var scale: float = _rng.randf_range(0.6, 1.0)
		var yaw: float = _rng.randf_range(0.0, TAU)
		for mirror: int in 2:
			var mz: float = z if mirror == 0 else -z
			var basis: Basis = Basis(Vector3.UP, yaw if mirror == 0 else PI - yaw).scaled(Vector3(scale, scale, scale))
			_add_instance(M_BUSH, Transform3D(basis, Vector3(x, _ground(x, mz) - 0.1, mz)))
		placed += 1


## Slabs of old Eld along the roads (decorative, no collision). Each slab is
## tilted with the terrain (normal at its center) and sunk until its top face is
## flush; on slopes of more than [constant PATH_SLAB_MAX_SLOPE]° they are not placed (they would stick out).
func _place_road_stones() -> void:
	for road: PackedVector2Array in Layout.road_polylines():
		for mirror: int in 2:
			if mirror == 1 and road[0].y == 0.0 and road[road.size() - 1].y == 0.0:
				continue
			for i: int in road.size() - 1:
				var a: Vector2 = road[i]
				var b: Vector2 = road[i + 1]
				var length: float = a.distance_to(b)
				var steps: int = int(length / 2.3)
				for s: int in steps:
					if _rng.randf() < 0.3:
						continue
					var t: float = (float(s) + 0.5) / float(steps)
					var p: Vector2 = a.lerp(b, t)
					var z: float = p.y if mirror == 0 else -p.y
					var x: float = p.x + _rng.randf_range(-0.5, 0.5)
					var mesh_id: int = M_PATH + (1 if _rng.randf() < 0.3 else 0)
					var yaw: float = atan2(b.x - a.x, b.y - a.y) + _rng.randf_range(-0.3, 0.3)
					if Layout.river_distance(x, z) < 11.0 or Layout.fort_sdf(x, z) < 1.0:
						continue
					if _ground_slope(x, z) > PATH_SLAB_MAX_SLOPE:
						continue
					var normal: Vector3 = _ground_normal(x, z)
					var basis: Basis = _basis_on_normal(normal, yaw)
					var y: float = _ground(x, z) - float(PATH_SLAB_SINK[mesh_id])
					_add_instance(mesh_id, Transform3D(basis, Vector3(x, y, z)))


## Terrain normal at (x, z) by central differences at 1 m.
func _ground_normal(x: float, z: float) -> Vector3:
	var dx: float = (_ground(x + 1.0, z) - _ground(x - 1.0, z)) * 0.5
	var dz: float = (_ground(x, z + 1.0) - _ground(x, z - 1.0)) * 0.5
	return Vector3(-dx, 1.0, -dz).normalized()


## Basis with the Y axis on [param normal] and rotated [param yaw] around it.
static func _basis_on_normal(normal: Vector3, yaw: float) -> Basis:
	var heading: Vector3 = Basis(Vector3.UP, yaw) * Vector3.FORWARD
	var x_axis: Vector3 = normal.cross(-heading).normalized()
	var z_axis: Vector3 = x_axis.cross(normal).normalized()
	return Basis(x_axis, normal, z_axis)


# =============================================================================================
# Ruins (definition shared by the vegetation and the assembly)
# =============================================================================================

## Village houses in the north half: [center, x segments, z segments, door side,
## damage seed]. They are mirrored for the south. Side: 0 south, 1 east, 2 north, 3 west.
func _village_houses() -> Array[Array]:
	return [
		[Vector2(-121, -13), 4, 3, 0, 1],
		[Vector2(-98, -14), 3, 3, 0, 2],
		[Vector2(-131, -33), 3, 2, 1, 3],
		[Vector2(-104, -34), 2, 2, 0, 4],
		[Vector2(-80, -30), 2, 2, 3, 5],
		[Vector2(-136, -14), 2, 3, 1, 6],
	]


func _in_ruins(x: float, z: float, margin: float) -> bool:
	var p: Vector2 = Vector2(x, -absf(z))
	for house: Array in _village_houses():
		var center: Vector2 = house[0]
		var half: Vector2 = Vector2(house[1], house[2]) + Vector2(margin, margin)
		if absf(p.x - center.x) < half.x and absf(p.y - center.y) < half.y:
			return true
	var chapel: Vector2 = Layout.CHAPEL_CENTER
	return absf(x - chapel.x) < 8.0 + margin and absf(z) < 6.0 + margin


# =============================================================================================
# Scene assembly
# =============================================================================================

func _assemble_scene() -> void:
	_add_environment()
	_add_water()
	_add_fort()
	_add_bridges()
	_add_walls()
	_add_camps()
	_add_ruins()
	_add_ford_posts()
	_add_vegetation_colliders()
	_add_boundaries()
	_add_spawn_points()
	_add_respawn_points()
	_add_safe_areas()
	_add_dummy_points()
	_add_gate_guardians()
	_add_screenshot_points()


func _add_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	# Sky of the Eldrun frontier (ART-54): a storm that is breaking up. Custom shader on the dome
	# (assets/materials/shaders/storm_sky.gdshader): broken clouds, dark in the east and at the zenith, with a
	# clearing toward the west and a silver lining, and the sun disc where the directional light is. It is an
	# Environment resource like any other: the headless server does not draw it and does not load
	# any sky addon.
	var sky_material := ShaderMaterial.new()
	sky_material.shader = load(SKY_SHADER_PATH) as Shader
	sky_material.set_shader_parameter(&"cloud_noise", _make_cloud_noise())
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# Low ambient: the directional light is provided by the sun. With the sky clearing in the west and the
	# dark clouds in the east, the ambient already brings a color gradient, not a uniform gray.
	environment.ambient_light_energy = 0.55
	environment.ambient_light_sky_contribution = 1.0
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.tonemap_exposure = 1.0
	environment.tonemap_white = 6.0
	environment.ssao_enabled = true
	environment.ssao_radius = 1.6
	environment.ssao_intensity = 1.6
	# Screen-space light bounce: the inside of the fort and the foot of the walls do not stay black.
	environment.ssil_enabled = true
	environment.ssil_radius = 4.0
	environment.ssil_intensity = 0.8
	environment.glow_enabled = true
	environment.glow_intensity = 0.35
	environment.glow_bloom = 0.04
	environment.glow_hdr_threshold = 1.2
	# Cold, low distance fog, with the scattering of the low western sun.
	environment.fog_enabled = true
	environment.fog_light_color = Color("#9ba5ae")
	environment.fog_light_energy = 1.0
	environment.fog_sun_scatter = 0.18
	environment.fog_density = 0.0016
	environment.fog_aerial_perspective = 0.3
	environment.fog_sky_affect = 0.25
	environment.fog_height = 3.0
	environment.fog_height_density = 0.01
	# Light volumetric fog: the shadows of the clouds and the towers leave beams of light.
	environment.volumetric_fog_enabled = true
	environment.volumetric_fog_density = 0.0012
	environment.volumetric_fog_albedo = Color("#b8c4d0")
	environment.volumetric_fog_emission = Color("#000000")
	environment.volumetric_fog_length = 120.0
	environment.volumetric_fog_detail_spread = 2.0
	environment.volumetric_fog_ambient_inject = 0.25
	environment.volumetric_fog_sky_affect = 0.4
	environment.adjustment_enabled = true
	environment.adjustment_saturation = 1.0
	environment.adjustment_contrast = 1.06
	environment.adjustment_brightness = 1.0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ENVIRONMENT_PATH.get_base_dir()))
	var error: Error = ResourceSaver.save(environment, ENVIRONMENT_PATH)
	if error != OK:
		_fail("No se pudo guardar el entorno (%s)" % error_string(error))
	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = load(ENVIRONMENT_PATH) as Environment
	_zone.add_child(world_environment)
	_zone.move_child(world_environment, 0)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	# Low sun from the west (28°), slightly warm and with long shadows. It runs exactly along +X,
	# so it does not hit either of the two wall facades head-on (they face +Z and -Z): both
	# get the same light (the ambient's), and the symmetry between realms is not touched. There are no
	# fill lights anymore: with them the light was flat (ART-54). What faces west gets sun and what faces
	# east is left in shadow, with an ambient of 0.48.
	sun.rotation_degrees = Vector3(-28.0, -90.0, 0.0)
	sun.light_color = Color("#ffe6c4")
	sun.light_energy = 2.6
	sun.light_volumetric_fog_energy = 1.0
	sun.light_angular_distance = 1.5
	sun.shadow_enabled = true
	sun.shadow_blur = 1.4
	# Four splits up to 130 m (before, two up to 120 m): the long shadows of a low sun reach
	# the trees and the wall. The cost in draw calls is measured with
	# tools/render/render_screenshot_points.gd (docs/zones/vado_gris.md, «Measured performance»).
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 110.0
	sun.directional_shadow_blend_splits = false
	_zone.add_child(sun)
	_zone.move_child(sun, 1)

	# Wall fill (ART-54): two symmetrical lights, without shadow, that only light layer 20
	# (WallLightTag puts it on the walls). With the sun in the X plane, the wall facades
	# are seen edge-on and come out gray and flat; each one gets here a grazing light from the west, one from
	# the southwest and another from the northwest, and the relief of the ashlar reads. The zone stays mirrored.
	for side: float in [-1.0, 1.0]:
		var fill := DirectionalLight3D.new()
		fill.name = "RellenoMuralla%s" % ("Norte" if side < 0.0 else "Sur")
		# The light travels toward the east and toward the facade (the north wall's faces +Z): sideways, at 28°.
		fill.basis = Basis.looking_at(Vector3(0.62, -0.47, -side * 0.62).normalized(), Vector3.UP)
		fill.light_color = Color("#ffe9cf")
		fill.light_energy = 0.9
		fill.light_cull_mask = WallLightTagScript.LIGHT_LAYER
		fill.shadow_enabled = false
		fill.light_specular = 0.3
		_zone.add_child(fill)
		_zone.move_child(fill, 2 if side < 0.0 else 3)


## Sky cloud noise (procedural texture saved as parameters, not as an image):
## soft, seamless simplex noise, which the sky shader samples at several scales.
static func _make_cloud_noise() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.seed = 4113
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.01
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.5
	var texture := NoiseTexture2D.new()
	texture.width = 512
	texture.height = 512
	texture.seamless = true
	texture.normalize = true
	texture.noise = noise
	return texture


## River water: mesh ribbon along the channel, at height WATER_LEVEL. UV.x is meters along
## the river (for the current) and UV.y meters from the axis.
func _add_water() -> void:
	var line: PackedVector2Array = Layout.river_polyline(2.0)
	var half_width: float = 15.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var along: float = 0.0
	var vertex_count: int = 0
	for i: int in line.size():
		var p: Vector2 = line[i]
		var tangent: Vector2 = (line[mini(i + 1, line.size() - 1)] - line[maxi(i - 1, 0)]).normalized()
		var normal: Vector2 = Vector2(-tangent.y, tangent.x)
		if i > 0:
			along += p.distance_to(line[i - 1])
		var left: Vector2 = p + normal * half_width
		var right: Vector2 = p - normal * half_width
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(along, half_width))
		st.add_vertex(Vector3(left.x, Layout.WATER_LEVEL, left.y))
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(along, -half_width))
		st.add_vertex(Vector3(right.x, Layout.WATER_LEVEL, right.y))
		vertex_count += 2
	for i: int in line.size() - 1:
		var a: int = i * 2
		# Clockwise order seen from above (front face in Godot).
		st.add_index(a)
		st.add_index(a + 1)
		st.add_index(a + 2)
		st.add_index(a + 1)
		st.add_index(a + 3)
		st.add_index(a + 2)
	st.generate_tangents()
	var mesh: ArrayMesh = st.commit()
	mesh.resource_name = "vado_gris_river_water"
	var error: Error = ResourceSaver.save(mesh, WATER_MESH_PATH)
	if error != OK:
		_fail("No se pudo guardar la malla del agua (%s)" % error_string(error))
	var water := MeshInstance3D.new()
	water.name = "Rio"
	water.mesh = load(WATER_MESH_PATH) as Mesh
	water.material_override = load(WATER_MATERIAL_PATH) as Material
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var group := _group("Agua")
	group.add_child(water)


## The fort is the fortress node (docs/fortress.md, section 1.6): in the `fortresses` group and with
## the `definition` metadata. Its children are the markers the controller uses: `CaptureCircle`
## (with `radius`), `CaptainSpawn`, `GuardSpawn1`..4, `FortGate` and the banners `Estandarte`,
## `EstandartePuertaN` and `EstandartePuertaS`, plus the NPC spawners (`NpcSpawner`) and the
## patrol markers of the Hollow.
func _add_fort() -> void:
	var fort: Node3D = _instance(PROPS + "fort/vado_gris_fort.tscn", _zone)
	fort.name = "Fuerte"
	fort.position = Vector3(Layout.FORT_CENTER.x, _ground(Layout.FORT_CENTER.x, Layout.FORT_CENTER.y), Layout.FORT_CENTER.y)
	fort.add_to_group(&"fortresses", true)
	fort.set_meta(&"definition", FORTRESS_DEFINITION_PATH)


func _add_bridges() -> void:
	var group := _group("Puentes")
	for mirror: int in 2:
		var z: float = -Layout.RIVER_RADIUS if mirror == 0 else Layout.RIVER_RADIUS
		var bridge: Node3D = _instance(PROPS + "bridge/stone_bridge.tscn", group)
		bridge.name = "PuenteNorte" if mirror == 0 else "PuenteSur"
		bridge.position = Vector3(Layout.BRIDGE_X, Layout.BANK_LEVEL, z)


# --- Walls -----------------------------------------------------------------------------------

func _add_walls() -> void:
	var group := _group("Murallas")
	group.set_script(WallLightTagScript)
	_build_wall(group, "vardheim", -1.0, "MuroDeEscarcha", [48.0, 96.0, 144.0])
	_build_wall(group, "solmarch", 1.0, "MurallaDelAlba", [36.0, 72.0, 108.0, 144.0])


## Facade of a wall: gate with towers (scene), Castle Wall Kit courses in MultiMesh
## (two draw calls per section), intermediate towers and one collision per side.
## [param side] = -1 for the north one (the face looks toward +Z) and +1 for the south one.
func _build_wall(parent: Node3D, realm: String, side: float, node_name: String, tower_xs: Array) -> void:
	var wall := Node3D.new()
	wall.name = node_name
	parent.add_child(wall)
	var ground: float = Layout.CAMP_GROUND
	var face_z: float = side * Layout.WALL_Z
	var yaw: float = 0.0 if side < 0.0 else PI
	var basis := Basis(Vector3.UP, yaw)
	var gate: Node3D = _instance(PROPS + "walls/%s_gatehouse.tscn" % realm, wall)
	gate.name = "Puerta"
	gate.transform = Transform3D(basis, Vector3(0.0, ground, face_z))

	var courses: Array[Transform3D] = []
	var battlements: Array[Transform3D] = []
	var hoardings: Array[Transform3D] = []
	var wall_end: float = 9.0
	for direction: float in [-1.0, 1.0]:
		var x0: float = 9.0
		while x0 < Layout.WALL_HALF_LENGTH:
			# 6 m section between x0 and x0 + 6 (in the direction of the side).
			var mid: float = direction * (x0 + 3.0)
			var terrain_mid: float = _ground(mid, face_z + side * 6.0)
			if not is_nan(terrain_mid) and terrain_mid > ground + 11.0:
				break
			var start_x: float = direction * x0 if direction > 0.0 else direction * (x0 + 6.0)
			for course: int in 3:
				var y: float = ground - 6.0 + course * 6.0
				courses.append(Transform3D(basis, _wall_point(start_x, y, face_z, side)))
			battlements.append(Transform3D(basis, Vector3(mid, ground + 12.0, face_z)))
			if realm == "vardheim" and int(x0 / 6.0) % 2 == 0:
				hoardings.append(Transform3D(basis, Vector3(mid, ground + 12.85, face_z + side * 0.25)))
			x0 += 6.0
		wall_end = maxf(wall_end, x0)
	var stone: Material = load(MAT + realm + "/stone_wall.tres") as Material
	var trim: Material = load(MAT + realm + "/stone_trim.tres") as Material
	_baked(wall, "Hiladas", CW_MESH + "courtine_wall.tres", stone, courses)
	_baked(wall, "Almenas", CW_MESH + "wall_battlements.tres", trim, battlements)
	if not hoardings.is_empty():
		_baked(wall, "Cadalsos", CW_MESH + "brattice_wall_1.tres", load(MAT + "vardheim/planks.tres") as Material, hoardings)

	for tx: float in tower_xs:
		for direction: float in [-1.0, 1.0]:
			var x: float = direction * tx
			if tx > wall_end - 3.0:
				continue
			var tower: Node3D = _instance(PROPS + "walls/%s_wall_tower.tscn" % realm, wall)
			tower.name = "Torre%s%d" % ["O" if direction < 0.0 else "E", int(tx)]
			tower.transform = Transform3D(basis, Vector3(x, ground, face_z - side * 3.05))

	var body := StaticBody3D.new()
	body.name = "Colision"
	body.collision_layer = WORLD_LAYER
	body.collision_mask = 0
	wall.add_child(body)
	var run: float = wall_end - 9.0
	for direction: float in [-1.0, 1.0]:
		_box_shape(body, "Lado%s" % ("O" if direction < 0.0 else "E"), Vector3(run, 20.0, 1.0),
				Vector3(direction * (9.0 + run * 0.5), ground + 4.0, face_z + side * 0.45))


## Corner of a Courtine piece (origin at its left end seen from the valley).
static func _wall_point(start_x: float, y: float, face_z: float, side: float) -> Vector3:
	# The piece goes from x to x + 6 in its local space; rotated 180° (south wall) it goes from x to x - 6.
	return Vector3(start_x if side < 0.0 else start_x + 6.0, y, face_z)


# --- Camps -----------------------------------------------------------------------------------

## Camp inside each gate. It is defined in the north half and mirrored with the pieces of
## each realm: [scene, x, z, rotation in degrees, extra height].
func _camp_layout() -> Array[Array]:
	return [
		["tent", -17.0, -141.0, 90.0, 0.0], ["tent", -17.0, -133.5, 90.0, 0.0],
		["tent", 17.0, -141.0, -90.0, 0.0], ["tent", 21.0, -128.0, 180.0, 0.0],
		["crate", -21.5, -127.0, 12.0, 0.0], ["crate", -22.6, -125.8, 40.0, 0.0],
		["crate", -21.9, -126.4, 25.0, 1.06], ["crate", 12.5, -145.5, 5.0, 0.0],
		["wagon", 24.0, -138.0, 160.0, 0.0],
		["fence", -26.0, -118.0, 0.0, 0.0], ["fence", -24.0, -118.0, 0.0, 0.0],
		["fence", 24.0, -118.0, 0.0, 0.0], ["fence", 26.0, -118.0, 0.0, 0.0],
		["fence", 28.0, -119.0, 30.0, 0.0],
		["banner", -6.0, -114.0, 0.0, 0.0], ["banner", 6.0, -114.0, 0.0, 0.0],
		["fire_pit", -9.0, -126.0, 0.0, 0.0],
	]


func _add_camps() -> void:
	var group := _group("Campamentos")
	for realm: String in ["vardheim", "solmarch"]:
		var camp := Node3D.new()
		camp.name = "Campamento" + realm.capitalize()
		group.add_child(camp)
		var mirror: bool = realm == "solmarch"
		var index: int = 0
		for item: Array in _camp_layout():
			var kind: String = item[0]
			var path: String = PROPS + ("camp/fire_pit.tscn" if kind == "fire_pit" else "camp/%s_%s.tscn" % [realm, kind])
			var x: float = item[1]
			var z: float = -float(item[2]) if mirror else float(item[2])
			var yaw: float = deg_to_rad(item[3])
			if mirror:
				yaw = PI - yaw
			var node: Node3D = _instance(path, camp)
			node.name = "%s%d" % [kind.capitalize().replace(" ", ""), index]
			node.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(x, _ground(x, z) + float(item[4]), z))
			index += 1


# --- Ruins -----------------------------------------------------------------------------------

func _add_ruins() -> void:
	var group := _group("Ruinas")
	var village := Node3D.new()
	village.name = "AldeaDeEld"
	group.add_child(village)
	_floor_xforms.clear()
	_rubble_xforms.clear()
	var damage := RandomNumberGenerator.new()
	var house_index: int = 0
	for house: Array in _village_houses():
		damage.seed = SEED + int(house[4]) * 31
		var states: Array = _house_wall_states(house, damage)
		for mirror: int in 2:
			var node := Node3D.new()
			node.name = "Casa%d%s" % [house_index + 1, "N" if mirror == 0 else "S"]
			village.add_child(node)
			_build_house(node, house, states, mirror == 1)
		house_index += 1
	_build_chapel(group)
	_build_road_end(group)
	_baked(village, "Suelos", VIL_MESH + "floor_uneven_brick.tres", load(MAT + "eldrun/ruin_stone.tres") as Material, _floor_xforms)
	_baked(group, "Escombros", CUSTOM_MESH + "rubble.tres", load(MAT + "eldrun/ruin_trim.tres") as Material, _rubble_xforms)


## End of the old village street before the west edge: two pillars of a fallen gate and
## rubble, so that the road does not end against the invisible wall.
func _build_road_end(parent: Node3D) -> void:
	var end := Node3D.new()
	end.name = "FinCalzada"
	parent.add_child(end)
	var x: float = Layout.VILLAGE_ROAD_END_X - 1.0
	for zs: float in [-1.0, 1.0]:
		var pillar: Node3D = _instance(PROPS + "ruins/ruin_pillar.tscn", end)
		pillar.name = "Pilar%s" % ("N" if zs < 0.0 else "S")
		pillar.position = Vector3(x, _ground(x, zs * 2.6) - 0.3, zs * 2.6)
	for spot: Vector2 in [Vector2(x - 2.5, 0.0), Vector2(x - 1.0, 1.2), Vector2(x - 1.0, -1.2)]:
		_rubble_xforms.append(Transform3D(Basis(Vector3.UP, spot.x + spot.y), Vector3(spot.x, _ground(spot.x, spot.y), spot.y)))


## State of each 2 m section of a house: [type, sinking, tilt]. Type: "wall",
## "window", "door" or "" (collapsed). It is computed once and used for both mirrored houses.
## Doors do not sink (the lintel stays above 2 m: you pass underneath) and walls are either
## jumped over (top at 1.2 m or less) or block the way (top at 1.9 m or more): nothing at the exact jump height.
func _house_wall_states(house: Array, damage: RandomNumberGenerator) -> Array:
	var states: Array = []
	var nx: int = house[1]
	var nz: int = house[2]
	var door_side: int = house[3]
	for side: int in 4:
		var count: int = nx if side % 2 == 0 else nz
		for i: int in count:
			var kind: String = "wall"
			if side == door_side and i == count / 2:
				kind = "door"
			elif damage.randf() < 0.25:
				kind = "window"
			if kind != "door" and damage.randf() < 0.3:
				kind = ""
			var sink: float = 0.0
			var roll: float = damage.randf()
			if roll < 0.35:
				sink = damage.randf_range(1.75, 2.1)
			elif roll < 0.55:
				sink = damage.randf_range(0.3, 0.8)
			var tilt: float = damage.randf_range(-0.07, 0.07) if sink > 0.0 else 0.0
			if kind == "door":
				sink = 0.0
				tilt = 0.0
			states.append([kind, sink, tilt])
	return states


func _build_house(node: Node3D, house: Array, states: Array, mirror: bool) -> void:
	var center: Vector2 = house[0]
	var nx: int = house[1]
	var nz: int = house[2]
	var cz: float = -center.y if mirror else center.y
	var half := Vector2(nx, nz)
	var k: int = 0
	for side: int in 4:
		var count: int = nx if side % 2 == 0 else nz
		# Outward normal of the side and direction along it.
		var outward: Vector2 = [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)][side]
		var along: Vector2 = Vector2(-outward.y, outward.x)
		for i: int in count:
			var state: Array = states[k]
			k += 1
			var kind: String = state[0]
			if kind.is_empty():
				continue
			var offset: float = -float(count) + 1.0 + float(i) * 2.0
			var local: Vector2 = outward * (half.y if side % 2 == 0 else half.x) + along * offset
			if mirror:
				local.y = -local.y
			var world := Vector2(center.x + local.x, cz + local.y)
			var normal: Vector2 = outward
			if mirror:
				normal.y = -normal.y
			var yaw: float = atan2(normal.x, normal.y)
			var path: String = PROPS + "ruins/%s.tscn" % {"wall": "ruin_wall", "window": "ruin_wall_window", "door": "ruin_wall_door"}[kind]
			var piece: Node3D = _instance(path, node)
			piece.name = "Muro%d" % k
			var y: float = minf(_ground(world.x, world.y), _ground(world.x + along.x, world.y + along.y)) - 0.25 - float(state[1])
			# Sunken walls, somewhat leaning outward or inward (the collision goes with them).
			# Rotating about the local X axis (along the wall) tilts toward the local +Z normal,
			# which in the mirrored house is also the outer one: the mirroring comes out by itself.
			var tilt: float = float(state[2])
			var basis: Basis = Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, tilt)
			piece.transform = Transform3D(basis, Vector3(world.x, y, world.y))
			# Rubble at the foot of the most collapsed walls, on the outside.
			if float(state[1]) > 1.5:
				var out: Vector2 = world + normal * 1.0 + Vector2(normal.y, -normal.x) * 0.3
				_rubble_xforms.append(Transform3D(Basis(Vector3.UP, yaw + 0.6), Vector3(out.x, _ground(out.x, out.y) - 0.05, out.y)))
	# Partial floor, rubble and, in the big house, the chimney. Floors and rubble are visual
	# only: they go into two MultiMeshes for the whole village (see _add_ruins).
	for ix: int in nx:
		for iz: int in nz:
			if (ix + iz + int(house[4])) % 3 == 0:
				continue
			var fx: float = center.x - float(nx) + 1.0 + ix * 2.0
			var fz: float = cz - float(nz) + 1.0 + iz * 2.0
			_floor_xforms.append(Transform3D(Basis(), Vector3(fx, _ground(fx, fz) + 0.03, fz)))
	var rz: float = cz + (1.5 if mirror else -1.5)
	var rx: float = center.x + float(nx) * 0.4
	_rubble_xforms.append(Transform3D(Basis(), Vector3(rx, _ground(rx, rz), rz)))
	if nx >= 4:
		var chimney: Node3D = _instance(PROPS + "ruins/ruin_chimney.tscn", node)
		chimney.name = "Chimenea"
		var cx: float = center.x - float(nx) + 1.0
		var chz: float = cz + (float(nz) - 1.2 if mirror else -float(nz) + 1.2)
		chimney.position = Vector3(cx, _ground(cx, chz) - 0.2, chz)


## Ruined chapel on the peninsula, on the axis (symmetrical): 12 x 10 m floor plan, door to the
## west on the axis, collapsed east chancel and two pillars of old Eld.
func _build_chapel(parent: Node3D) -> void:
	var chapel := Node3D.new()
	chapel.name = "Capilla"
	parent.add_child(chapel)
	var c: Vector2 = Layout.CHAPEL_CENTER
	var pieces: Array[Array] = []
	# Side walls (north and south): 6 sections, the same on both sides.
	var sinks: Array[float] = [0.0, 0.3, 0.0, 1.2, 1.7, 2.4]
	var kinds: Array[String] = ["wall", "window", "wall", "window", "wall", ""]
	for i: int in 6:
		var x: float = c.x - 5.0 + i * 2.0
		for zs: float in [-1.0, 1.0]:
			if not kinds[i].is_empty():
				pieces.append([kinds[i], Vector2(x, c.y + zs * 5.0), Vector2(0, zs), sinks[i]])
	# West facade (5 sections, door on the axis) and east chancel almost gone.
	for j: int in 5:
		var z: float = c.y - 4.0 + j * 2.0
		pieces.append(["door" if j == 2 else "wall", Vector2(c.x - 6.0, z), Vector2(-1, 0), 0.0 if j != 0 and j != 4 else 0.5])
		if j == 0 or j == 4:
			pieces.append(["wall", Vector2(c.x + 6.0, z), Vector2(1, 0), 1.6])
	var index: int = 0
	for spec: Array in pieces:
		var path: String = PROPS + "ruins/%s.tscn" % {"wall": "ruin_wall", "window": "ruin_wall_window", "door": "ruin_wall_door"}[spec[0]]
		var piece: Node3D = _instance(path, chapel)
		piece.name = "Muro%d" % index
		index += 1
		var p: Vector2 = spec[1]
		var normal: Vector2 = spec[2]
		var y: float = _ground(p.x, p.y) - 0.25 - float(spec[3])
		piece.transform = Transform3D(Basis(Vector3.UP, atan2(normal.x, normal.y)), Vector3(p.x, y, p.y))
	for zs: float in [-1.0, 1.0]:
		var pillar: Node3D = _instance(PROPS + "ruins/ruin_pillar.tscn", chapel)
		pillar.name = "Pilar%s" % ("N" if zs < 0.0 else "S")
		var px: float = c.x + 3.0
		var pz: float = c.y + zs * 1.8
		pillar.position = Vector3(px, _ground(px, pz) - 0.3, pz)
	for zs: float in [-1.0, 1.0]:
		var rx: float = c.x + 5.5
		var rz: float = c.y + zs * 1.5
		_rubble_xforms.append(Transform3D(Basis(Vector3.UP, zs), Vector3(rx, _ground(rx, rz), rz)))


## Wooden posts that mark the ford crossing (the line of the old road along the axis),
## so that it is readable from afar where it can be crossed. With thin collision: they are a real obstacle.
func _add_ford_posts() -> void:
	var group := _group("Vado")
	var xforms: Array[Transform3D] = []
	var body := StaticBody3D.new()
	body.name = "PostesColision"
	body.collision_layer = WORLD_LAYER
	body.collision_mask = 0
	group.add_child(body)
	var post_rng := RandomNumberGenerator.new()
	post_rng.seed = SEED + 7
	var index: int = 0
	var x: float = -Layout.RIVER_RADIUS - 13.0
	while x <= -Layout.RIVER_RADIUS + 13.0:
		for zs: float in [-1.0, 1.0]:
			var z: float = zs * 4.5
			var height: float = post_rng.randf_range(1.6, 2.3)
			var base: float = _ground(x, z) - 0.5
			var tilt := Basis(Vector3(1, 0, 0), post_rng.randf_range(-0.08, 0.08)) * Basis(Vector3(0, 0, 1), post_rng.randf_range(-0.08, 0.08))
			xforms.append(Transform3D(tilt.scaled(Vector3(1.0, height, 1.0)), Vector3(x, base + height * 0.5, z)))
			var shape := CollisionShape3D.new()
			shape.name = "Poste%d" % index
			index += 1
			var cylinder := CylinderShape3D.new()
			cylinder.radius = 0.16
			cylinder.height = height
			shape.shape = cylinder
			shape.position = Vector3(x, base + height * 0.5, z)
			body.add_child(shape)
		x += 3.25
	var post := CylinderMesh.new()
	post.top_radius = 0.12
	post.bottom_radius = 0.16
	post.height = 1.0
	post.radial_segments = 7
	post.rings = 1
	var mmi := MultiMeshInstance3D.new()
	mmi.set_script(BakedMultiMeshScript)
	mmi.name = "Postes"
	mmi.set(&"source_mesh", post)
	mmi.set(&"instance_transforms", BakedMultiMeshScript.pack_transforms(xforms))
	mmi.material_override = load(MAT + "eldrun/palisade_log.tres") as Material
	group.add_child(mmi)


# --- Collisions, boundaries and markers ------------------------------------------------------

func _add_vegetation_colliders() -> void:
	var group := _group("Colisiones")
	var trees := StaticBody3D.new()
	trees.name = "Troncos"
	trees.collision_layer = WORLD_LAYER
	trees.collision_mask = 0
	group.add_child(trees)
	var i: int = 0
	for spec: Dictionary in _tree_colliders:
		var shape := CollisionShape3D.new()
		shape.name = "Tronco%d" % i
		var cylinder := CylinderShape3D.new()
		cylinder.radius = spec["radius"]
		cylinder.height = spec["height"]
		shape.shape = cylinder
		shape.position = (spec["position"] as Vector3) + Vector3(0, float(spec["height"]) * 0.5, 0)
		trees.add_child(shape)
		i += 1
	var rocks := StaticBody3D.new()
	rocks.name = "Rocas"
	rocks.collision_layer = WORLD_LAYER
	rocks.collision_mask = 0
	group.add_child(rocks)
	i = 0
	for spec: Dictionary in _rock_colliders:
		var shape := CollisionShape3D.new()
		shape.name = "Roca%d" % i
		var cylinder := CylinderShape3D.new()
		cylinder.radius = spec["radius"]
		cylinder.height = spec["height"]
		shape.shape = cylinder
		shape.position = (spec["position"] as Vector3) + Vector3(0, float(spec["height"]) * 0.5, 0)
		rocks.add_child(shape)
		i += 1


## Invisible walls of the 300 x 300 m playable area, deep river banks (the water is
## visual only: outside the ford, the water's edge cannot be crossed) and closing of the channel on both sides
## of the ford (without it, from the ford you could walk along the deep bed to the bridges). All of it
## on the player blocker layer: the camera does not collide with them.
func _add_boundaries() -> void:
	var group := _group("Limites")
	var limits := StaticBody3D.new()
	limits.name = "LimitesInvisibles"
	limits.collision_layer = PLAYER_BLOCKER_LAYER
	limits.collision_mask = 0
	group.add_child(limits)
	var half: float = Layout.PLAY_HALF
	_box_shape(limits, "Oeste", Vector3(2.0, 120.0, half * 2.0 + 8.0), Vector3(-half - 1.0, 40.0, 0.0))
	_box_shape(limits, "Este", Vector3(2.0, 120.0, half * 2.0 + 8.0), Vector3(half + 1.0, 40.0, 0.0))
	_box_shape(limits, "Norte", Vector3(half * 2.0 + 8.0, 120.0, 2.0), Vector3(0.0, 40.0, -half - 2.0))
	_box_shape(limits, "Sur", Vector3(half * 2.0 + 8.0, 120.0, 2.0), Vector3(0.0, 40.0, half + 2.0))

	var banks := StaticBody3D.new()
	banks.name = "OrillasProfundas"
	banks.collision_layer = PLAYER_BLOCKER_LAYER
	banks.collision_mask = 0
	group.add_child(banks)
	var line: PackedVector2Array = Layout.river_polyline(2.0)
	var offset: float = Layout.WATER_HALF_WIDTH + 0.4
	var bottom: float = Layout.WATER_LEVEL - 2.0
	# Higher than a jump from the highest point of the bank (a jump of about 1.45 m).
	var top: float = Layout.BANK_LEVEL + 1.6
	var index: int = 0
	var cross_index: int = 0
	var was_ford: bool = false
	var i: int = 0
	while i < line.size() - 2:
		var a: Vector2 = line[i]
		var b: Vector2 = line[i + 2]
		i += 2
		var mid: Vector2 = (a + b) * 0.5
		if absf(mid.x) > half + 2.0:
			continue
		var tangent: Vector2 = (b - a).normalized()
		var normal: Vector2 = Vector2(-tangent.y, tangent.x)
		var in_ford: bool = Layout.ford_factor(mid.x, mid.y) > 0.02
		# Where the ford starts or ends, a wall across the channel, on the deep side.
		if in_ford != was_ford and index > 0:
			var joint: Vector2 = a + tangent * (0.3 if was_ford else -0.3)
			var shape := CollisionShape3D.new()
			shape.name = "CierreCauce%d" % cross_index
			cross_index += 1
			var box := BoxShape3D.new()
			box.size = Vector3(offset * 2.0 + 0.6, top - bottom, 0.6)
			shape.shape = box
			shape.transform = Transform3D(Basis(Vector3.UP, atan2(tangent.x, tangent.y)), Vector3(joint.x, (top + bottom) * 0.5, joint.y))
			banks.add_child(shape)
		was_ford = in_ford
		if in_ford:
			continue
		for side: float in [-1.0, 1.0]:
			var pa: Vector2 = a + normal * offset * side
			var pb: Vector2 = b + normal * offset * side
			# Under the bridges the bank is closed off by the sides of the bridge: the section is trimmed
			# exactly at its outer face (before it was skipped at the midpoint and a block
			# went 0.7 m into the deck).
			for piece: Array in _bank_pieces(pa, pb):
				var p0: Vector2 = piece[0]
				var p1: Vector2 = piece[1]
				var dir: Vector2 = (p1 - p0).normalized()
				p0 -= dir * float(piece[2])
				p1 += dir * float(piece[3])
				var length: float = p0.distance_to(p1)
				if length < 0.05:
					continue
				var center: Vector2 = (p0 + p1) * 0.5
				var shape := CollisionShape3D.new()
				shape.name = "Orilla%d" % index
				index += 1
				var box := BoxShape3D.new()
				box.size = Vector3(0.6, top - bottom, length)
				shape.shape = box
				shape.transform = Transform3D(Basis(Vector3.UP, atan2(dir.x, dir.y)), Vector3(center.x, (top + bottom) * 0.5, center.y))
				banks.add_child(shape)


## Part of the bank section [param pa]-[param pb] that is not under a bridge: list of
## [start, end, extension at the start, extension at the end]. Free ends are extended
## 0.2 m (overlap between sections); those trimmed against the bridge are not.
func _bank_pieces(pa: Vector2, pb: Vector2) -> Array[Array]:
	var whole: Array[Array] = [[pa, pb, 0.2, 0.2]]
	var mid_z: float = absf((pa.y + pb.y) * 0.5)
	if absf(mid_z - Layout.RIVER_RADIUS) > Layout.BRIDGE_LENGTH * 0.5:
		return whole
	var lo: float = Layout.BRIDGE_X - BRIDGE_OUTER_HALF
	var hi: float = Layout.BRIDGE_X + BRIDGE_OUTER_HALF
	var dx: float = pb.x - pa.x
	if absf(dx) < 1e-5:
		return [] if pa.x > lo and pa.x < hi else whole
	var t_a: float = (lo - pa.x) / dx
	var t_b: float = (hi - pa.x) / dx
	var t0: float = minf(t_a, t_b)
	var t1: float = maxf(t_a, t_b)
	if t1 <= 0.0 or t0 >= 1.0:
		return whole
	var pieces: Array[Array] = []
	if t0 > 0.0:
		pieces.append([pa, pa.lerp(pb, t0), 0.2, 0.0])
	if t1 < 1.0:
		pieces.append([pa.lerp(pb, t1), pb, 0.0, 0.2])
	return pieces


## Transform of a spawn point of the [param realm] camp at [param x]: 14 m from
## its wall and facing the fort (the north one faces +Z, rotation PI; the south one -Z, rotation 0).
func _camp_spawn_transform(realm: String, x: float) -> Transform3D:
	var side: float = -1.0 if realm == "vardheim" else 1.0
	var z: float = side * 138.0
	return Transform3D(Basis(Vector3.UP, PI if side < 0.0 else 0.0), Vector3(x, _ground(x, z) + 0.05, z))


func _add_spawn_points() -> void:
	var group := _group("SpawnPoints")
	for realm: String in ["vardheim", "solmarch"]:
		var index: int = 1
		for x: float in CAMP_SPAWN_XS:
			var marker := Marker3D.new()
			marker.name = "%s%d" % [realm.capitalize(), index]
			index += 1
			marker.transform = _camp_spawn_transform(realm, x)
			marker.set_meta(&"realm", realm)
			marker.add_to_group(&"spawn_points", true)
			group.add_child(marker)


## Respawn points after death (docs/fortress.md, section 5), in scene order, which is
## the index that client and server use: first those of the two camps (at the place of their
## spawn points, with the `realm` metadata) and then those inside the fort (with the
## `fortress` metadata, the fortress id; without `realm`, because they are valid for whichever realm
## owns the fort). Nodes are never reordered or inserted in front of the last ones.
func _add_respawn_points() -> void:
	var group := _group("RespawnPoints")
	for realm: String in ["vardheim", "solmarch"]:
		var index: int = 1
		for x: float in CAMP_SPAWN_XS:
			var marker := Marker3D.new()
			marker.name = "Campamento%s%d" % [realm.capitalize(), index]
			index += 1
			marker.transform = _camp_spawn_transform(realm, x)
			marker.set_meta(&"realm", realm)
			marker.add_to_group(&"respawn_points", true)
			group.add_child(marker)
	var fort: Node3D = _zone.get_node(^"Fuerte") as Node3D
	var fort_index: int = 1
	for local: Vector2 in FORT_RESPAWN_LOCAL:
		var marker := Marker3D.new()
		marker.name = "FuerteVadoGris%d" % fort_index
		fort_index += 1
		# Faces the gate (west, -X): rotation of +90°.
		marker.transform = Transform3D(Basis(Vector3.UP, PI * 0.5),
				fort.position + Vector3(local.x, 0.05, local.y))
		marker.set_meta(&"fortress", FORTRESS_ID)
		marker.add_to_group(&"respawn_points", true)
		group.add_child(marker)


## The two Gate Guardians of each camp (docs/fortress.md, section 4.3): NPC spawners
## (`NpcSpawner`, data only) of the camp's realm, always active, that look at the
## fort from the sides of the gate in their wall.
func _add_gate_guardians() -> void:
	var group := _group("NpcSpawners")
	for realm: String in ["vardheim", "solmarch"]:
		var side: float = -1.0 if realm == "vardheim" else 1.0
		var index: int = 1
		for spot: Vector2 in GUARDIAN_SPOTS:
			var z: float = side * spot.y
			var spawner := NpcSpawner.new()
			spawner.name = "GateGuardian%s%d" % [realm.capitalize(), index]
			index += 1
			spawner.transform = Transform3D(Basis(Vector3.UP, PI if side < 0.0 else 0.0),
					Vector3(spot.x, _ground(spot.x, z) + 0.05, z))
			spawner.npc_id = &"gate_guardian"
			spawner.max_alive = 1
			spawner.respawn_s = GUARDIAN_RESPAWN_S
			spawner.alert_group = StringName("camp_" + realm)
			spawner.condition = NpcSpawner.Condition.ALWAYS
			spawner.realm = StringName(realm)
			spawner.add_to_group(&"npc_spawners", true)
			group.add_child(spawner)


## Safe zones (docs/combat.md, section 5): one per camp, centered on the center of its
## spawn points (x = 0, z = ±138) and with the camp's radius (24 m). They only protect their
## realm ([code]realm[/code] metadata); the server reads them from the [code]safe_areas[/code] group.
func _add_safe_areas() -> void:
	var group := _group("SafeAreas")
	for realm: String in ["vardheim", "solmarch"]:
		var side: float = -1.0 if realm == "vardheim" else 1.0
		var z: float = side * 138.0
		var marker := Marker3D.new()
		marker.name = "Campamento" + realm.capitalize()
		marker.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, _ground(0.0, z) + 0.05, z))
		marker.set_meta(&"realm", realm)
		marker.set_meta(&"radius", Layout.CAMP_RADIUS)
		marker.add_to_group(&"safe_areas", true)
		group.add_child(marker)


## Training dummies: one next to each camp, outside its safe zone (30 m from the
## center of the spawn points, toward the fort) and facing the camp, so that it can be
## hit from outside. The server places a dummy at each marker of the
## [code]dummy_points[/code] group.
func _add_dummy_points() -> void:
	var group := _group("DummyPoints")
	for realm: String in ["vardheim", "solmarch"]:
		var side: float = -1.0 if realm == "vardheim" else 1.0
		var z: float = side * 108.0
		var marker := Marker3D.new()
		marker.name = "Muneco" + realm.capitalize()
		# Faces the camp: the north one faces -Z (rotation 0), the south one +Z (rotation PI).
		marker.transform = Transform3D(Basis(Vector3.UP, 0.0 if side < 0.0 else PI),
				Vector3(0.0, _ground(0.0, z) + 0.05, z))
		marker.add_to_group(&"dummy_points", true)
		group.add_child(marker)


## Review cameras: [name, position (y = meters above the ground), point it looks at (y =
## meters above the ground), fov].
func _screenshot_specs() -> Array[Array]:
	return [
		["vista_desde_puerta_vardheim", Vector3(-6, 15, -140), Vector3(0, 2, -10), 62.0],
		["vista_desde_puerta_solmarch", Vector3(6, 15, 140), Vector3(0, 2, 10), 62.0],
		["fuerte_de_cerca", Vector3(-40, 17, -36), Vector3(-2, -1, 2), 55.0],
		["puente_norte", Vector3(17, 3.0, -86), Vector3(-1, 1.5, -60), 60.0],
		["vado", Vector3(-104, 5.5, -30), Vector3(-58, 0.5, 2), 60.0],
		["ruinas_aldea", Vector3(-138, 3.2, 9), Vector3(-108, 1.2, -8), 60.0],
		["muralla_vardheim", Vector3(36, 4, -106), Vector3(0, 9, -150), 62.0],
		["campamento_solmarch", Vector3(28, 3.0, 112), Vector3(-2, 2, 136), 62.0],
		["vista_aerea", Vector3(150, 120, 150), Vector3(-10, -6, 0), 55.0],
		["puerta_del_fuerte", Vector3(-34, 3.0, -7), Vector3(-19, 2.2, 0), 60.0],
	]


func _add_screenshot_points() -> void:
	var group := _group("ScreenshotPoints")
	for spec: Array in _screenshot_specs():
		var marker := Marker3D.new()
		marker.name = spec[0]
		var from: Vector3 = spec[1]
		var target: Vector3 = spec[2]
		from.y += _ground(from.x, from.z)
		target.y += _ground(target.x, target.z)
		marker.transform = Transform3D(Basis.looking_at(target - from, Vector3.UP), from)
		marker.set_meta(&"fov", spec[3])
		marker.add_to_group(&"screenshot_points", true)
		group.add_child(marker)


# =============================================================================================
# Utilities
# =============================================================================================

func _group(node_name: String) -> Node3D:
	var existing: Node3D = _zone.get_node_or_null(NodePath(node_name)) as Node3D
	if existing != null:
		return existing
	var group := Node3D.new()
	group.name = node_name
	_zone.add_child(group)
	return group


func _instance(path: String, parent: Node) -> Node3D:
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		_fail("No se pudo cargar %s" % path)
		var placeholder := Node3D.new()
		parent.add_child(placeholder)
		return placeholder
	var node: Node3D = scene.instantiate() as Node3D
	parent.add_child(node)
	return node


func _baked(parent: Node3D, node_name: String, mesh_path: String, material: Material, xforms: Array[Transform3D]) -> void:
	var mmi := MultiMeshInstance3D.new()
	mmi.set_script(BakedMultiMeshScript)
	mmi.name = node_name
	mmi.set(&"source_mesh", load(mesh_path) as Mesh)
	mmi.set(&"instance_transforms", BakedMultiMeshScript.pack_transforms(xforms))
	mmi.material_override = material
	parent.add_child(mmi)


func _box_shape(body: Node, node_name: String, size: Vector3, center: Vector3) -> void:
	var shape := CollisionShape3D.new()
	shape.name = node_name
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = center
	body.add_child(shape)


func _save_scene() -> void:
	_own(_zone, _zone)
	var packed := PackedScene.new()
	var error: Error = packed.pack(_zone)
	if error == OK:
		error = ResourceSaver.save(packed, SCENE_PATH)
	if error != OK:
		_fail("No se pudo guardar la escena (%s)" % error_string(error))
		return
	print("   %s (%.0f KB)" % [SCENE_PATH, FileAccess.get_file_as_bytes(SCENE_PATH).size() / 1024.0])


## Makes [param owner] the owner of the nodes that get saved. It does not enter the instanced scenes
## (they are saved as a reference) or the internal children of Terrain3D (instancer meshes,
## which are regenerated on load from the region data).
func _own(node: Node, owner: Node) -> void:
	for child: Node in node.get_children():
		child.owner = owner
		if child.scene_file_path.is_empty() and not child is Terrain3D:
			_own(child, owner)


func _fail(message: String) -> void:
	_failed = true
	printerr(message)
