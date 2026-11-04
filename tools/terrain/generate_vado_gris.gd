extends SceneTree
## Generador del Vado Gris (fase 4): terreno de Terrain3D, pintura, hierba y vegetación, y la
## escena de la zona con todas sus piezas y colisiones.
##
## Uso (desde la raíz del proyecto, con el editor cerrado):
## [codeblock]
## godot --headless --path . -s res://tools/terrain/generate_vado_gris.gd
## [/codeblock]
## Requisitos previos (una vez): tools/assets/copy_vado_gris_assets.gd, --import,
## tools/assets/extract_kit_meshes.gd, tools/materials/build_realm_materials.gd y
## tools/props/build_vado_gris_props.gd. Ver docs/zonas/vado_gris.md.
## [br][br]
## Es determinista y se puede repetir: borra y vuelve a escribir los datos de región
## (scenes/world/zones/vado_gris/terrain/*.res), los assets del terreno y vado_gris.tscn. Todo
## lo que hay en la escena sale de aquí y de vado_gris_layout.gd: para cambiar la zona se
## cambia el generador, no la escena a mano.
## [br][br]
## Una sola pasada calcula las posiciones de árboles y rocas: las mallas van al instanciador de
## Terrain3D (solo visual, sin colisión) y las colisiones (un cilindro por tronco o roca) se
## guardan en la escena, así que el servidor dedicado tiene exactamente las mismas.

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

## Capa del mundo estático (personajes, cámara y, más adelante, disparos).
const WORLD_LAYER: int = PlayerCharacter.WORLD_COLLISION_LAYER
## Capa de los bloqueos invisibles que solo paran al jugador: límites, orillas profundas y cierre
## del cauce. La cámara no la mira (no se pega a la cabeza junto a una orilla).
const PLAYER_BLOCKER_LAYER: int = PlayerCharacter.PLAYER_BLOCKER_LAYER
const SEED: int = 20261028
## Definición de la fortaleza del Vado Gris (metadato `definition` del nodo del fuerte).
const FORTRESS_DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
## Id de la fortaleza (el `id` de su definición): metadato `fortress` de sus puntos de reaparición.
const FORTRESS_ID: StringName = &"vado_gris_fort"
## Puntos de reaparición del interior del fuerte, en coordenadas del fuerte (x al este, z al sur):
## el patio al este de la hoguera y de la torre, fuera del cilindro del círculo de captura (centro
## x = -8,5, radio 5 m), en espejo norte-sur y mirando a la puerta.
const FORT_RESPAWN_LOCAL: Array[Vector2] = [
	Vector2(11.0, -6.0), Vector2(11.0, -2.0), Vector2(11.0, 2.0), Vector2(11.0, 6.0),
]
## Posiciones (x, |z|) de los dos Guardianes de la Puerta de cada campamento: a los lados de las
## torres de la puerta, dentro de la zona segura.
const GUARDIAN_SPOTS: Array[Vector2] = [Vector2(-11.0, 142.5), Vector2(11.0, 142.5)]
## Segundos que tarda en reaparecer un Guardián de la Puerta muerto.
const GUARDIAN_RESPAWN_S: float = 30.0
## Posiciones x de los cuatro puntos de aparición de cada campamento.
const CAMP_SPAWN_XS: Array[float] = [-7.5, -2.5, 2.5, 7.5]
## Medio ancho exterior de los puentes (tablero + pretil): las orillas profundas acaban aquí.
const BRIDGE_OUTER_HALF: float = Layout.BRIDGE_WIDTH * 0.5 + 0.4

## Texturas del terreno (el índice es el id de Terrain3D): [archivo (sin sufijo), nombre, uv_scale,
## tinte]. Son las CC0 de Poly Haven procesadas por tools/assets/process_terrain_textures.py:
## desaturadas, con la altura en el alfa del albedo y la normal con la rugosidad en el alfa de la
## normal (ART-55). El uv_scale es la inversa del lado de la tesela en metros: la hierba y la tierra
## a 3 m, la grava a 2 m y la roca a 4,5 m; de cerca se ve grano, piedras y briznas, y la proyección
## en pendientes evita las vetas estiradas. La repetición a gran escala la rompen el desfase de
## rotación de cada textura, la variación macro del material y el mapa de color.
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
## Umbral de la proyección en pendientes de Terrain3D (0 a 0,99): a partir de esa inclinación la
## textura se proyecta de lado en vez de estirarse a lo largo de la ladera.
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

## Materiales que sustituyen a los del glTF en el instanciador (tono de Eldrun).
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

## Mallas del instanciador (el índice es el id): [glTF, nombre, alcance visible (m), sombra].
## Terrain3D crea un MultiMesh por variante y celda de 32 m, así que cada variante extra
## multiplica las llamadas de dibujo: las variantes de árbol son pocas (cinco por familia, de las
## que el kit ya trae) y el sotobosque solo se ve de cerca. Los ids nuevos van al final para no
## mover los que ya usa el resto del generador.
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
## Ids de las variantes de cada familia de árbol (los de pino, caducifolio y muerto van en el
## orden del kit; los extra, al final de la lista de mallas).
const TREE_VARIANTS: Dictionary = {
	M_PINE: [2, 3, 4, 16, 17],
	M_COMMON: [5, 6, 7, 18, 19],
	M_DEAD: [8, 9, 20, 21, 22],
	M_TWISTED: [23, 24],
}
## Grosor de las losas de calzada (m): se hunden para que su cara de arriba quede a ras.
const PATH_SLAB_SINK: Dictionary = {M_PATH: 0.155, M_PATH + 1: 0.095}
## Pendiente máxima (grados) para poner una losa: en las laderas del fuerte quedarían al aire.
const PATH_SLAB_MAX_SLOPE: float = 7.0

## Factor de escala de las variantes que el kit trae más altas que las tres primeras de su familia
## (DeadTree_3 a _5 miden de 13 a 16 m y Pine_4 10 m, frente a los 7 a 11 m de las demás): solo
## afecta al dibujo, nunca a la colisión.
const VARIANT_SCALE: Dictionary = {16: 0.8, 17: 0.9, 18: 0.85, 20: 0.78, 21: 0.8, 22: 0.62}
## Radio del tronco (m, a escala 1) para la colisión de cada familia de árbol.
const TRUNK_RADIUS: Dictionary = {M_PINE: 0.4, M_COMMON: 0.38, M_DEAD: 0.45}
## Radio de la base del tronco de cada familia (m, a escala 1), medido en las mallas: lo que hay que
## hundir un árbol por cada unidad de pendiente para que no quede aire bajo el lado de abajo.
const ROOT_RADIUS: Dictionary = {M_PINE: 0.27, M_COMMON: 0.74, M_DEAD: 0.67, M_TWISTED: 0.6}
## Por encima de esta pendiente (grados) no se plantan árboles: va roca y canchal (ART-58).
const TREE_MAX_SLOPE: float = 45.0
## Altura y radio de la base de las rocas medianas del kit (m, a escala 1), medidos en las mallas.
const ROCK_HEIGHT: float = 2.2
const ROCK_RADIUS: float = 1.8
## Fracción de su altura que se hunde una roca con colisión (la colisión no se toca: el dibujo queda a
## la altura de su cilindro) y una roca suelta del borde, que sí puede quedar medio enterrada.
const GAMEPLAY_ROCK_SINK: float = 0.14
const LOOSE_ROCK_SINK: float = 0.45

var _layout: Layout
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
## Generador aparte para lo que es solo decoración (sotobosque, guijarros): así la cobertura de
## juego (árboles y rocas con colisión), que sale de [member _rng], no se mueve nunca.
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
# Terreno
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


## Pendiente en grados en un píxel (diferencias centrales, 1 m entre vértices).
func _slope_at_pixel(px: int, pz: int) -> float:
	var dx: float = (_height_at_pixel(px + 1, pz) - _height_at_pixel(px - 1, pz)) * 0.5
	var dz: float = (_height_at_pixel(px, pz + 1) - _height_at_pixel(px, pz - 1)) * 0.5
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))


## Mapa de control: textura base, textura superpuesta y mezcla por píxel, según la pendiente,
## la altura, la distancia al río, las calzadas y las zonas de juego.
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
			# Terrain3D 1.0.2: base == overlay con mezcla 255 se ve negro.
			if base == overlay:
				blend = 0
			var bits: int = Terrain3DUtil.enc_base(base) | Terrain3DUtil.enc_overlay(overlay) \
					| Terrain3DUtil.enc_blend(blend)
			image.set_pixel(px, pz, Color(Terrain3DUtil.as_float(bits), 0.0, 0.0, 1.0))
	return image


## Devuelve (base, superpuesta, mezcla 0..255).
func _paint(x: float, z: float, h: float, slope: float) -> Vector3i:
	var n: float = _layout.paint_noise(x, z)
	var n2: float = _layout.paint_noise(x * 2.3 + 91.0, z * 2.3 - 37.0)
	# Hierba: seca y gris hacia el norte y en el centro (Eldrun), más verde hacia el sur.
	var south: float = smoothstep(-20.0, 150.0, z)
	var north: float = smoothstep(-20.0, 150.0, -z)
	var base: int = T_GRASS
	var overlay: int = T_DRY
	var blend: float = clampf(0.45 + n * 1.3 + north * 0.35 - south * 0.55, 0.0, 1.0)
	if z > 20.0 and n2 > -0.1:
		overlay = T_LUSH
		blend = clampf(south * 0.9 + n2 * 0.8, 0.0, 1.0)

	# Laderas empinadas y montaña: roca.
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

	# Identidad de cada mitad (ART-62), solo pintura (la capa de juego sigue en espejo): al norte
	# (Vardheim) nieve a manchas en la hierba y suelo de bosque oscuro bajo las coníferas, y nieve
	# continua en lo alto; al sur (Solmarch) hierba verde y suelo vivo, sin nieve. Fuera del área
	# jugable la diferencia es mayor.
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
	# Cimas y riscos: la roca manda, con nieve en las cumbres del norte.
	if high > 0.8 and z < -20.0 and h > 62.0:
		overlay = T_SNOW
		blend = clampf((h - 62.0) / 14.0, 0.0, 1.0)

	var grass_base: int = base
	# Pie de las murallas y campamentos: tierra pisada con calvas de hierba.
	var az: float = absf(z)
	var wall_band: float = 1.0 - smoothstep(3.0, 9.0, absf(az - Layout.WALL_Z))
	var camp: float = 1.0 - smoothstep(Layout.CAMP_RADIUS - 8.0, Layout.CAMP_RADIUS + 2.0, Layout.camp_distance(x, z))
	var trodden: float = maxf(wall_band * (1.0 - smoothstep(150.0, 175.0, absf(x))), camp)
	if trodden > 0.05:
		base = T_GRAVEL if n2 > 0.1 else T_DIRT
		overlay = T_DRY if z < 0.0 else T_GRASS
		blend = clampf(1.0 - trodden + n * 0.9 + 0.3, 0.0, 1.0)

	# Meseta del fuerte: tierra y grava.
	var fort_d: float = Layout.fort_sdf(x, z)
	if fort_d < 6.0:
		base = T_DIRT
		overlay = T_GRAVEL if fort_d < 1.0 else T_DRY
		blend = clampf(0.35 + n * 0.6 if fort_d < 1.0 else smoothstep(1.0, 6.0, fort_d), 0.0, 1.0)

	# Calzadas: núcleo de grava gris (la vieja calzada de Eld, con las losas encima en el
	# instanciador) que pasa a tierra y se funde con la hierba en un borde roto por ruido, con
	# mezcla fraccionaria (no 0/1) para que el contorno no siga la rejilla de 1 m.
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

	# Río: lecho oscuro, vado de grava gris (el "Vado Gris"), orillas de barro y grava.
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


## Mapa de color (multiplica el albedo): manchas grandes de luz y sombra, calvas secas más
## pardas y orillas más verdes y oscuras, para que el valle no sea un verde uniforme. El alfa
## es el modificador de rugosidad de Terrain3D (0,5 = neutro).
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
	# Se ajusta el material que crea el propio nodo (asignar uno nuevo en headless registra
	# errores del servidor de render ficticio). Sin fondo plano fuera de las regiones.
	_terrain.material.world_background = Terrain3DMaterial.NONE
	# Transiciones más suaves entre texturas (con la mezcla por altura de las texturas de
	# acuarela) y variación de color a gran escala para que los bordes de la pintura no sigan la
	# rejilla de 1 m del mapa de control.
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


## Altura del terreno sin el fallo de get_height() junto a los vértices (Terrain3D 1.0.2).
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
# Vegetación
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


## ¿Se puede poner un árbol o una roca de juego aquí (mitad norte)?
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


## Cobertura de juego (árboles y rocas con colisión). Se genera en la mitad norte y se refleja
## en el eje z = 0: misma posición, mismo radio de colisión; cambia solo el modelo (pinos al
## norte, caducifolios al sur). Así los dos reinos tienen exactamente la misma cobertura.
func _place_gameplay_cover() -> void:
	# Bosquetes en los flancos: [centro, radio, árboles].
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
	# Árboles muertos sueltos en la franja central (Eldrun) y en la península.
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
	# Rocas: grupos de cobertura en las llanuras, cerca de las orillas y junto a la península.
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
				# La colisión se queda donde estaba (cilindro desde 0,15 de escala bajo el suelo);
				# solo el dibujo se asienta en la ladera (ART-58).
				var y: float = _ground(x, mz) - 0.15 * scale
				_add_instance(mesh_id, _settle_rock(x, mz, scale, scale, my, GAMEPLAY_ROCK_SINK, 0.8))
				_rock_colliders.append({"position": Vector3(x, y, mz), "radius": 1.35 * scale, "height": 2.0 * scale})
				_scatter_pebbles(x, mz, 2.6 * scale)
			_occupied.append(Vector3(x, 1.6 * scale, z))


func _add_mirrored_tree(x: float, z: float, family: int) -> void:
	var variants: Array = TREE_VARIANTS[family]
	var variant: int = _rng.randi_range(0, variants.size() - 1)
	# Algo más grandes que el modelo del kit (7,3 m): junto a murallas de 12 m y torres de 18 m
	# los árboles a escala 1 parecían arbustos.
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
		# La colisión se queda en h - 0,1; el dibujo se hunde además según la pendiente (ART-58).
		var y: float = _ground(x, mz) - 0.1
		var visual_scale: float = scale * float(VARIANT_SCALE.get(mesh_id, 1.0))
		var basis: Basis = Basis(Vector3.UP, yaw if mirror == 0 else PI - yaw).scaled(Vector3(visual_scale, visual_scale, visual_scale))
		_add_instance(mesh_id, Transform3D(basis, Vector3(x, _trunk_y(x, mz, mesh_family, visual_scale, 0.1), mz)))
		_tree_colliders.append({"position": Vector3(x, y, mz), "radius": TRUNK_RADIUS[family] * scale, "height": 7.0})
		_scatter_undergrowth(x, mz, 5.0, 7)
	_occupied.append(Vector3(x, 2.5, z))


## Altura a la que se pone un árbol (ART-58): el suelo menos [param base_sink] menos lo que hay que
## hundirlo según la pendiente, tan(pendiente) por el radio de su base, para que el lado de abajo del
## tronco no quede en el aire. Por encima de [constant TREE_MAX_SLOPE] no se ponen árboles.
func _trunk_y(x: float, z: float, family: int, scale: float, base_sink: float) -> float:
	var slope: float = minf(_ground_slope(x, z), TREE_MAX_SLOPE)
	return _ground(x, z) - base_sink - tan(deg_to_rad(slope)) * float(ROOT_RADIUS[family]) * scale


## Posición y giro de una roca asentada en la ladera (ART-58): inclinada hacia la normal del terreno
## ([param tilt] de 0 a 1) y hundida una fracción [param sink_fraction] de su altura más el hueco que
## deja la inclinación que falta. Escala [param scale_xz] en horizontal y [param scale_y] en vertical.
func _settle_rock(x: float, z: float, scale_xz: float, scale_y: float, yaw: float, sink_fraction: float,
		tilt: float) -> Transform3D:
	var normal: Vector3 = _ground_normal(x, z)
	var axis: Vector3 = Vector3.UP.lerp(normal, tilt).normalized()
	var residual: float = acos(clampf(axis.dot(normal), -1.0, 1.0))
	var basis: Basis = _basis_on_normal(axis, yaw) * Basis.from_scale(Vector3(scale_xz, scale_y, scale_xz))
	var sink: float = sink_fraction * ROCK_HEIGHT * scale_y + tan(residual) * ROCK_RADIUS * scale_xz
	return Transform3D(basis, Vector3(x, _ground(x, z) - sink, z))


## Sotobosque alrededor de un tronco (ART-59): helechos, plantas, setas y hierba alta. Solo dibujo (sin
## colisión), con el generador de decoración para no mover la cobertura de juego. No pisa calzadas,
## río, fuerte, campamentos ni ruinas.
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


## Guijarros alrededor de una roca (ART-59), solo dibujo.
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


## ¿Cae (x, z) dentro del área jugable (el cuadrado de [constant Layout.PLAY_HALF] hasta las murallas)?
static func _in_play_area(x: float, z: float) -> bool:
	return absf(x) <= Layout.PLAY_HALF and absf(z) <= Layout.WALL_Z


## ¿Se puede poner decoración suelta aquí? Fuera de calzadas (margen [param road_margin] m), del
## río, del fuerte, de los campamentos y de las ruinas, y en pendientes de menos de [param max_slope].
func _decor_allowed(x: float, z: float, road_margin: float, max_slope: float) -> bool:
	if Layout.road_distance(x, z) < road_margin or Layout.river_distance(x, z) < 11.5:
		return false
	if Layout.fort_sdf(x, z) < 3.0 or Layout.camp_distance(x, z) < Layout.CAMP_RADIUS:
		return false
	if _in_ruins(x, z, 1.0):
		return false
	var h: float = _ground(x, z)
	return not is_nan(h) and _ground_slope(x, z) <= max_slope


## Bosque del borde, fuera del área jugable (sin colisión: no se llega). Pinos al norte,
## caducifolios al sur y árboles muertos y retorcidos donde se juntan, como pide la identidad
## visual. No hay árboles por encima de [constant TREE_MAX_SLOPE]: allí va canchal (ART-58).
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
			# Paso de la calzada detrás de cada puerta, despejado.
			if absf(x) < 14.0 and absf(z) > Layout.WALL_Z:
				continue
			if Layout.river_distance(x, z) < 15.0:
				continue
			var h: float = _ground(x, z)
			if is_nan(h) or h > 110.0:
				continue
			var slope: float = _ground_slope(x, z)
			# Laderas de más de 45°: canchal de rocas en vez de árboles.
			if slope > TREE_MAX_SLOPE:
				if _rng.randf() < 0.45:
					_add_scree(x, z)
				continue
			# Bosque en grupos (ruido), que se aclara en las laderas fuertes (de 38° hacia arriba) en
			# vez de quedarse solo en las crestas.
			var clump: float = _layout.paint_noise(x * 0.5 + 300.0, z * 0.5 - 120.0)
			var density: float = (0.85 if z < -40.0 else 0.7) * clampf(0.8 + clump * 1.4, 0.2, 1.0)
			density *= 1.0 - smoothstep(34.0, 50.0, slope) * 0.55
			# Más lejos del área jugable el bosque se aclara (presupuesto de primitivas, y a esa
			# distancia la niebla lo funde en una masa).
			var beyond: float = maxf(absf(x) - Layout.PLAY_HALF, absf(z) - Layout.WALL_Z)
			density *= lerpf(1.0, 0.45, smoothstep(30.0, 110.0, beyond))
			if _rng.randf() > density:
				if slope > 34.0 and _rng.randf() < 0.18:
					_add_scree(x, z)
				# Laderas sin árbol: matorral (helechos, plantas y arbustos) para que no queden peladas.
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
			# Coníferas del borde mucho más grandes (las montañas llegan a 80 m y el Muro de
			# Escarcha mide 12 m): mismo modelo del kit, a escala de bosque de montaña. Los
			# retorcidos del kit son enormes (17 m a escala 1) y se achican.
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
			# Sotobosque al pie de algunos árboles (ART-59).
			if _decor_rng.randf() < 0.8:
				_scatter_undergrowth(x, z, 4.0, 4)
			if _rng.randf() < 0.12:
				var rock_scale: float = _rng.randf_range(0.8, 1.8)
				var rx: float = x + _rng.randf_range(-3.0, 3.0)
				var rz: float = z + _rng.randf_range(-3.0, 3.0)
				var rh: float = _ground(rx, rz)
				var rock_id: int = M_ROCK + _rng.randi_range(0, 2)
				var rock_yaw: float = _rng.randf_range(0, TAU)
				# Dentro del área jugable toda roca tiene colisión: las sueltas solo van fuera.
				if not is_nan(rh) and not _in_play_area(rx, rz):
					_add_instance(rock_id, _settle_rock(rx, rz, rock_scale, rock_scale, rock_yaw,
							LOOSE_ROCK_SINK, 0.85))
		gx += step
	print("   bosque del borde: %d árboles" % count)


## Rocas sueltas de canchal en una ladera empinada del borde (sin colisión: no se llega), inclinadas
## con la ladera y medio enterradas (ART-58).
func _add_scree(x: float, z: float) -> void:
	# Canchal en regueros, no lunares: de 3 a 6 rocas de tamaños distintos alineadas con la línea de
	# máxima pendiente (cuesta abajo), las pequeñas a los lados, y guijarros entre ellas.
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
		# Dentro del área jugable toda roca tiene colisión: el canchal solo va fuera.
		if is_nan(rh) or absf(rx) > 246.0 or absf(rz) > 246.0 or _in_play_area(rx, rz):
			continue
		_add_instance(rock_id, _settle_rock(rx, rz, rock_scale, rock_scale * 0.8, rock_yaw, LOOSE_ROCK_SINK, 0.9))
		if not big and _decor_rng.randf() < 0.7:
			_scatter_pebbles(rx, rz, 1.2 * rock_scale + 0.6)


## Hierba (instanciador, sin colisión, visible hasta 48 m): en matas agrupadas por un ruido de
## manchas (prado espeso y claros, no una rejilla), seca y gris hacia el centro (Eldrun) y el
## norte, algo más verde hacia el sur. Cada celda de 1 m tiene su posición al azar dentro de la
## celda, así que no se ven hileras.
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
			# Manchas: densidad alta en los prados, claros entre ellos.
			var clump: float = _layout.paint_noise(cx * 2.2 + 57.0, cz * 2.2 - 11.0) * 0.7 \
					+ _layout.paint_noise(cx * 0.7 - 23.0, cz * 0.7 + 41.0) * 0.6
			var keep: float = clampf(0.58 + clump * 1.5, 0.1, 0.97)
			# Junto a las calzadas, un borde de matas más espeso.
			if road < 4.5:
				keep = maxf(keep, 0.7)
			if Layout.camp_distance(cx, cz) < Layout.CAMP_RADIUS:
				keep *= 0.3
			if _in_ruins(cx, cz, 0.5):
				keep *= 0.35
			if _rng.randf() > keep:
				continue
			var tufts: int = 1 if keep < 0.5 else (2 if keep < 0.8 else 3)
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
				var scale: float = _rng.randf_range(0.2, 0.34) if road < 4.5 else _rng.randf_range(0.24, 0.42)
				var basis: Basis = Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(Vector3(scale, scale * _rng.randf_range(0.8, 1.2), scale))
				_add_instance(mesh_id, Transform3D(basis, Vector3(x, h - 0.03, z)))
		gx += step


## Matorral de ladera (ART-59): un manchón de helechos, plantas y arbustos, solo dibujo.
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


## Variante de hierba según la zona (ART-59 y ART-62): al norte (Vardheim) matas escarchadas y
## verdes frías, en la franja central (Eldrun) secas y grises, al sur (Solmarch) verde vivo. La
## de hojas finas y caras (wispy, 190 triángulos) solo entra en pequeña proporción.
func _grass_variant(z: float, dry_chance: float) -> int:
	if _rng.randf() < dry_chance:
		return M_GRASS_DRY if _rng.randf() < 0.18 else M_GRASS_DRY_SHORT
	if z < -55.0 and _rng.randf() < smoothstep(-55.0, -120.0, z) * 0.9 + 0.1:
		return M_GRASS_FROST
	if z > 55.0 and _rng.randf() < smoothstep(55.0, 120.0, z) * 0.9 + 0.1:
		return M_GRASS_LUSH
	return M_GRASS


## Arbustos decorativos (sin colisión) en orillas, lindes de los bosquetes y ruinas.
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


## Losas del viejo Eld a lo largo de las calzadas (decorativas, sin colisión). Cada losa se
## inclina con el terreno (normal en su centro) y se hunde hasta que su cara de arriba queda a
## ras; en pendientes de más de [constant PATH_SLAB_MAX_SLOPE]° no se ponen (sobresaldrían).
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


## Normal del terreno en (x, z) por diferencias centrales a 1 m.
func _ground_normal(x: float, z: float) -> Vector3:
	var dx: float = (_ground(x + 1.0, z) - _ground(x - 1.0, z)) * 0.5
	var dz: float = (_ground(x, z + 1.0) - _ground(x, z - 1.0)) * 0.5
	return Vector3(-dx, 1.0, -dz).normalized()


## Base con el eje Y en [param normal] y girada [param yaw] alrededor de ella.
static func _basis_on_normal(normal: Vector3, yaw: float) -> Basis:
	var heading: Vector3 = Basis(Vector3.UP, yaw) * Vector3.FORWARD
	var x_axis: Vector3 = normal.cross(-heading).normalized()
	var z_axis: Vector3 = x_axis.cross(normal).normalized()
	return Basis(x_axis, normal, z_axis)


# =============================================================================================
# Ruinas (definición compartida por la vegetación y el montaje)
# =============================================================================================

## Casas de la aldea en la mitad norte: [centro, segmentos x, segmentos z, lado de la puerta,
## semilla de daño]. Se reflejan para el sur. Lado: 0 sur, 1 este, 2 norte, 3 oeste.
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
# Montaje de la escena
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
	# Cielo de la frontera de Eldrun (ART-54): una tormenta que se abre. Shader propio sobre la cúpula
	# (assets/materials/shaders/storm_sky.gdshader): nubes rotas, oscuras al este y en el cénit, con un
	# claro hacia el oeste y filo plateado, y el disco solar donde está la luz direccional. Es un
	# recurso de Environment como otro cualquiera: el servidor headless no lo dibuja y no carga
	# ningún addon de cielo.
	var sky_material := ShaderMaterial.new()
	sky_material.shader = load(SKY_SHADER_PATH) as Shader
	sky_material.set_shader_parameter(&"cloud_noise", _make_cloud_noise())
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# Ambiente bajo: la luz con dirección la pone el sol. Con el claro del cielo hacia el oeste y las
	# nubes oscuras al este, el ambiente ya trae un degradado de color, no un gris uniforme.
	environment.ambient_light_energy = 0.55
	environment.ambient_light_sky_contribution = 1.0
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.tonemap_exposure = 1.0
	environment.tonemap_white = 6.0
	environment.ssao_enabled = true
	environment.ssao_radius = 1.6
	environment.ssao_intensity = 1.6
	# Rebote de luz en pantalla: el interior del fuerte y el pie de las murallas no se quedan negros.
	environment.ssil_enabled = true
	environment.ssil_radius = 4.0
	environment.ssil_intensity = 0.8
	environment.glow_enabled = true
	environment.glow_intensity = 0.35
	environment.glow_bloom = 0.04
	environment.glow_hdr_threshold = 1.2
	# Niebla de distancia fría y baja, con la dispersión del sol bajo del oeste.
	environment.fog_enabled = true
	environment.fog_light_color = Color("#9ba5ae")
	environment.fog_light_energy = 1.0
	environment.fog_sun_scatter = 0.18
	environment.fog_density = 0.0016
	environment.fog_aerial_perspective = 0.3
	environment.fog_sky_affect = 0.25
	environment.fog_height = 3.0
	environment.fog_height_density = 0.01
	# Niebla volumétrica ligera: las sombras de las nubes y de las torres dejan haces de luz.
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
	# Sol bajo del oeste (28°), algo cálido y con sombras largas. Va exactamente a lo largo de +X,
	# así que no da de lleno en ninguna de las dos fachadas de muralla (miran a +Z y a -Z): las dos
	# reciben la misma luz (la del ambiente), y la simetría entre reinos no se toca. Ya no hay
	# rellenos: con ellos la luz era plana (ART-54). Lo que mira al oeste recibe sol y lo que mira al
	# este queda en sombra, con un ambiente de 0,48.
	sun.rotation_degrees = Vector3(-28.0, -90.0, 0.0)
	sun.light_color = Color("#ffe6c4")
	sun.light_energy = 2.6
	sun.light_volumetric_fog_energy = 1.0
	sun.light_angular_distance = 1.5
	sun.shadow_enabled = true
	sun.shadow_blur = 1.4
	# Cuatro cortes hasta 130 m (antes dos hasta 120 m): las sombras largas de un sol bajo llegan a
	# los árboles y a la muralla. El coste en llamadas de dibujo se mide con
	# tools/render/render_screenshot_points.gd (docs/zonas/vado_gris.md, «Rendimiento medido»).
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 110.0
	sun.directional_shadow_blend_splits = false
	_zone.add_child(sun)
	_zone.move_child(sun, 1)

	# Relleno de las murallas (ART-54): dos luces simétricas, sin sombra, que solo iluminan la capa 20
	# (WallLightTag la pone en las murallas). Con el sol en el plano X, las fachadas de las murallas
	# quedan de canto y salen grises y planas; cada una recibe aquí una luz rasante del oeste, una desde
	# el suroeste y otra desde el noroeste, y se lee el relieve de la sillería. La zona sigue en espejo.
	for side: float in [-1.0, 1.0]:
		var fill := DirectionalLight3D.new()
		fill.name = "RellenoMuralla%s" % ("Norte" if side < 0.0 else "Sur")
		# La luz viaja hacia el este y hacia la fachada (la del muro norte mira a +Z): de lado, a 28°.
		fill.basis = Basis.looking_at(Vector3(0.62, -0.47, -side * 0.62).normalized(), Vector3.UP)
		fill.light_color = Color("#ffe9cf")
		fill.light_energy = 0.9
		fill.light_cull_mask = WallLightTagScript.LIGHT_LAYER
		fill.shadow_enabled = false
		fill.light_specular = 0.3
		_zone.add_child(fill)
		_zone.move_child(fill, 2 if side < 0.0 else 3)


## Ruido de las nubes del cielo (textura procedural que se guarda como parámetros, no como imagen):
## ruido simplex suave y sin costuras, que el shader del cielo muestrea a varias escalas.
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


## Agua del río: cinta de malla a lo largo del cauce, a la cota WATER_LEVEL. UV.x son metros a
## lo largo del río (para la corriente) y UV.y metros desde el eje.
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
		# Orden horario visto desde arriba (cara frontal en Godot).
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


## El fuerte es el nodo de la fortaleza (docs/fuerte.md, sección 1.6): del grupo `fortresses` y con
## el metadato `definition`. Sus hijos son los marcadores que usa el controlador: `CaptureCircle`
## (con `radius`), `CaptainSpawn`, `GuardSpawn1`..4, `FortGate` y los estandartes `Estandarte`,
## `EstandartePuertaN` y `EstandartePuertaS`, más los generadores de PNJ (`NpcSpawner`) y los
## marcadores de patrulla de los Huecos.
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


# --- Murallas --------------------------------------------------------------------------------

func _add_walls() -> void:
	var group := _group("Murallas")
	group.set_script(WallLightTagScript)
	_build_wall(group, "vardheim", -1.0, "MuroDeEscarcha", [48.0, 96.0, 144.0])
	_build_wall(group, "solmarch", 1.0, "MurallaDelAlba", [36.0, 72.0, 108.0, 144.0])


## Fachada de una muralla: puerta con torres (escena), hiladas de Castle Wall Kit en MultiMesh
## (dos llamadas de dibujo por tramo), torres intermedias y una colisión por lado.
## [param side] = -1 para la del norte (la cara mira a +Z) y +1 para la del sur.
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
			# Tramo de 6 m entre x0 y x0 + 6 (en la dirección del lado).
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


## Esquina de una pieza Courtine (origen en su extremo izquierdo visto desde el valle).
static func _wall_point(start_x: float, y: float, face_z: float, side: float) -> Vector3:
	# La pieza va de x a x + 6 en su espacio local; girada 180° (muralla sur) va de x a x - 6.
	return Vector3(start_x if side < 0.0 else start_x + 6.0, y, face_z)


# --- Campamentos -----------------------------------------------------------------------------

## Campamento dentro de cada puerta. Se define en la mitad norte y se refleja con las piezas de
## cada reino: [escena, x, z, giro en grados, altura extra].
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


# --- Ruinas ----------------------------------------------------------------------------------

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


## Final de la vieja calle de la aldea antes del borde oeste: dos pilares de una puerta caída y
## escombros, para que la calzada no acabe contra la pared invisible.
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


## Estado de cada tramo de 2 m de una casa: [tipo, hundimiento, inclinación]. Tipo: "wall",
## "window", "door" o "" (derrumbado). Se calcula una vez y se usa en las dos casas reflejadas.
## Las puertas no se hunden (el dintel queda a más de 2 m: se pasa por debajo) y los muros o se
## saltan (cima a 1,2 m o menos) o tapan (cima a 1,9 m o más): nada a la altura justa del salto.
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
		# Normal exterior del lado y dirección a lo largo de él.
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
			# Los muros hundidos, algo vencidos hacia fuera o hacia dentro (la colisión va con ellos).
			# Girar sobre el eje local X (a lo largo del muro) inclina hacia la normal local +Z,
			# que en la casa reflejada también es la exterior: el reflejo sale solo.
			var tilt: float = float(state[2])
			var basis: Basis = Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, tilt)
			piece.transform = Transform3D(basis, Vector3(world.x, y, world.y))
			# Escombros al pie de los muros más derrumbados, por fuera.
			if float(state[1]) > 1.5:
				var out: Vector2 = world + normal * 1.0 + Vector2(normal.y, -normal.x) * 0.3
				_rubble_xforms.append(Transform3D(Basis(Vector3.UP, yaw + 0.6), Vector3(out.x, _ground(out.x, out.y) - 0.05, out.y)))
	# Suelo parcial, escombros y, en la casa grande, la chimenea. Suelos y escombros son solo
	# visuales: van a dos MultiMesh de toda la aldea (ver _add_ruins).
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


## Capilla en ruinas en la península, sobre el eje (simétrica): planta de 12 x 10 m, puerta al
## oeste en el eje, cabecera este derrumbada y dos pilares del viejo Eld.
func _build_chapel(parent: Node3D) -> void:
	var chapel := Node3D.new()
	chapel.name = "Capilla"
	parent.add_child(chapel)
	var c: Vector2 = Layout.CHAPEL_CENTER
	var pieces: Array[Array] = []
	# Muros laterales (norte y sur): 6 tramos, iguales a los dos lados.
	var sinks: Array[float] = [0.0, 0.3, 0.0, 1.2, 1.7, 2.4]
	var kinds: Array[String] = ["wall", "window", "wall", "window", "wall", ""]
	for i: int in 6:
		var x: float = c.x - 5.0 + i * 2.0
		for zs: float in [-1.0, 1.0]:
			if not kinds[i].is_empty():
				pieces.append([kinds[i], Vector2(x, c.y + zs * 5.0), Vector2(0, zs), sinks[i]])
	# Fachada oeste (5 tramos, puerta en el eje) y cabecera este casi desaparecida.
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


## Postes de madera que marcan el paso del vado (la línea de la vieja calzada sobre el eje),
## para que se lea desde lejos dónde se puede cruzar. Con colisión fina: son obstáculo real.
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


# --- Colisiones, límites y marcadores --------------------------------------------------------

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


## Paredes invisibles del área jugable de 300 x 300 m, orillas profundas del río (el agua es
## solo visual: fuera del vado, el borde del agua no se cruza) y cierre del cauce a los dos lados
## del vado (sin él, desde el vado se podía andar por el lecho profundo hasta los puentes). Todo
## en la capa de bloqueos del jugador: la cámara no choca con ellos.
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
	# Más alto que un salto desde lo más alto de la orilla (salto de unos 1,45 m).
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
		# Donde el vado empieza o acaba, una pared a través del cauce, en el lado profundo.
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
			# Bajo los puentes la orilla la cierran los costados del puente: el tramo se recorta
			# exactamente en su cara exterior (antes se saltaba por el punto medio y un bloque se
			# metía 0,7 m en el tablero).
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


## Parte del tramo de orilla [param pa]-[param pb] que no queda bajo un puente: lista de
## [inicio, fin, prolongación al inicio, prolongación al final]. Los extremos libres se prolongan
## 0,2 m (solape entre tramos); los recortados contra el puente, no.
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


## Transformación de un punto de aparición del campamento de [param realm] en [param x]: a 14 m de
## su muralla y mirando al fuerte (el norte mira a +Z, giro PI; el sur a -Z, giro 0).
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


## Puntos de reaparición tras morir (docs/fuerte.md, sección 5), en el orden de la escena, que es
## el índice que usan cliente y servidor: primero los de los dos campamentos (en el sitio de sus
## puntos de aparición, con el metadato `realm`) y después los del interior del fuerte (con el
## metadato `fortress`, el id de la fortaleza; sin `realm`, porque valen para el reino que sea
## dueño del fuerte). Nunca se reordenan ni se insertan nodos delante de los últimos.
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
		# Mira a la puerta (oeste, -X): giro de +90°.
		marker.transform = Transform3D(Basis(Vector3.UP, PI * 0.5),
				fort.position + Vector3(local.x, 0.05, local.y))
		marker.set_meta(&"fortress", FORTRESS_ID)
		marker.add_to_group(&"respawn_points", true)
		group.add_child(marker)


## Los dos Guardianes de la Puerta de cada campamento (docs/fuerte.md, sección 4.3): generadores
## de PNJ (`NpcSpawner`, solo datos) del reino del campamento, siempre activos, que miran al
## fuerte desde los lados de la puerta de su muralla.
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


## Zonas seguras (docs/combate.md, sección 5): una por campamento, centrada en el centro de sus
## puntos de aparición (x = 0, z = ±138) y con el radio del campamento (24 m). Solo protegen a su
## reino (metadato [code]realm[/code]); las lee el servidor del grupo [code]safe_areas[/code].
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


## Maniquíes de entrenamiento: uno junto a cada campamento, fuera de su zona segura (a 30 m del
## centro de los puntos de aparición, hacia el fuerte) y mirando al campamento, para que se pueda
## golpear desde fuera. El servidor coloca un maniquí en cada marcador del grupo
## [code]dummy_points[/code].
func _add_dummy_points() -> void:
	var group := _group("DummyPoints")
	for realm: String in ["vardheim", "solmarch"]:
		var side: float = -1.0 if realm == "vardheim" else 1.0
		var z: float = side * 108.0
		var marker := Marker3D.new()
		marker.name = "Muneco" + realm.capitalize()
		# Mira hacia el campamento: el norte mira a -Z (giro 0), el sur a +Z (giro PI).
		marker.transform = Transform3D(Basis(Vector3.UP, 0.0 if side < 0.0 else PI),
				Vector3(0.0, _ground(0.0, z) + 0.05, z))
		marker.add_to_group(&"dummy_points", true)
		group.add_child(marker)


## Cámaras de revisión: [nombre, posición (y = metros sobre el suelo), punto al que mira (y =
## metros sobre el suelo), fov].
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
# Utilidades
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


## Hace a [param owner] dueño de los nodos que se guardan. No entra en las escenas instanciadas
## (se guardan como referencia) ni en los hijos internos de Terrain3D (mallas del instanciador,
## que se regeneran al cargar desde los datos de región).
func _own(node: Node, owner: Node) -> void:
	for child: Node in node.get_children():
		child.owner = owner
		if child.scene_file_path.is_empty() and not child is Terrain3D:
			_own(child, owner)


func _fail(message: String) -> void:
	_failed = true
	printerr(message)
