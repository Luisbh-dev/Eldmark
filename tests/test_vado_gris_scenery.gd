extends TestCase
## Pruebas del escenario del Vado Gris (oleada 5 de calidad: ART-54, ART-55, ART-57, ART-59, ART-62):
## el cielo propio y el entorno que lo usa, el juego de texturas del terreno, los materiales de hierba,
## el torreón y las luces de las murallas. Todo es solo visual: la capa de juego tiene sus propias pruebas.

const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const ENVIRONMENT_PATH: String = "res://assets/environments/vado_gris_frontier.tres"
const SKY_SHADER_PATH: String = "res://assets/materials/shaders/storm_sky.gdshader"
const TERRAIN_ASSETS_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris_terrain_assets.tres"
const GRASS_MATERIALS: Array[String] = [
	"grass_blade_green", "grass_blade_dry", "grass_blade_wispy", "grass_blade_lush", "grass_blade_frost",
	"grass_blade_tall",
]


func test_the_environment_uses_the_own_sky_shader_and_not_an_addon() -> void:
	var environment: Environment = load(ENVIRONMENT_PATH) as Environment
	if not assert_not_null(environment, "se carga el entorno"):
		return
	assert_eq(environment.background_mode, Environment.BG_SKY)
	var material: ShaderMaterial = environment.sky.sky_material as ShaderMaterial
	if not assert_not_null(material, "el cielo es un shader propio"):
		return
	assert_eq(material.shader.resource_path, SKY_SHADER_PATH)
	assert_eq(material.shader.get_mode(), Shader.MODE_SKY, "es un shader de cielo")
	assert_not_null(material.get_shader_parameter(&"cloud_noise"), "lleva el ruido de las nubes")
	assert_false(ResourceLoader.exists("res://addons/sky_3d/plugin.cfg"), "no hay addon de cielo que cargar en el servidor")


func test_the_environment_keeps_the_light_budget_decisions() -> void:
	var environment: Environment = load(ENVIRONMENT_PATH) as Environment
	if not assert_not_null(environment):
		return
	# Ambiente bajo (la luz con dirección la pone el sol) y sin desaturación global.
	assert_true(environment.ambient_light_energy >= 0.35 and environment.ambient_light_energy <= 0.6)
	assert_true(environment.adjustment_saturation >= 0.99, "sin desaturación global")
	assert_true(environment.volumetric_fog_enabled, "niebla volumétrica ligera")
	assert_true(environment.volumetric_fog_density < 0.01, "poco densa")
	assert_eq(environment.tonemap_mode, Environment.TONE_MAPPER_AGX)


func test_the_sun_and_the_wall_fills_keep_the_zone_mirrored() -> void:
	var zone: Node3D = (load(ZONE_SCENE_PATH) as PackedScene).instantiate() as Node3D
	tree.root.add_child(zone)
	var sun: DirectionalLight3D = zone.get_node_or_null(^"Sun") as DirectionalLight3D
	if assert_not_null(sun, "el sol"):
		# El sol viaja a lo largo de X: ninguna componente en Z, así que las dos mitades reciben lo mismo.
		var direction: Vector3 = -sun.global_basis.z
		assert_true(absf(direction.z) < 0.001, "el sol no favorece a ninguna mitad")
		assert_true(sun.light_energy >= 2.0 and sun.light_energy <= 3.0)
		assert_true(sun.shadow_enabled)
	var north: DirectionalLight3D = zone.get_node_or_null(^"RellenoMurallaNorte") as DirectionalLight3D
	var south: DirectionalLight3D = zone.get_node_or_null(^"RellenoMurallaSur") as DirectionalLight3D
	if assert_not_null(north, "relleno del muro norte") and assert_not_null(south, "relleno del muro sur"):
		var dn: Vector3 = -north.global_basis.z
		var ds: Vector3 = -south.global_basis.z
		assert_vec_near(Vector3(dn.x, dn.y, -dn.z), ds, 0.0001, "los rellenos son espejo uno del otro")
		assert_eq(north.light_cull_mask, WallLightTag.LIGHT_LAYER, "solo iluminan la capa de las murallas")
		assert_eq(south.light_cull_mask, WallLightTag.LIGHT_LAYER)
		assert_false(north.shadow_enabled)
		assert_eq(north.light_energy, south.light_energy)
	var walls: Node = zone.get_node_or_null(^"Murallas")
	if assert_not_null(walls, "las murallas") and assert_true(walls is WallLightTag, "con su etiquetador de capa"):
		var tagged: int = 0
		for node: Node in walls.find_children("*", "MeshInstance3D", true, false):
			if ((node as MeshInstance3D).layers & WallLightTag.LIGHT_LAYER) != 0:
				tagged += 1
		assert_true(tagged > 10, "las torres y las puertas llevan la capa (%d mallas)" % tagged)
		var multimeshes: Array[Node] = walls.find_children("*", "MultiMeshInstance3D", true, false)
		assert_true(multimeshes.size() >= 4, "hay tramos de muralla en MultiMesh")
		for node: Node in multimeshes:
			assert_true(((node as MultiMeshInstance3D).layers & WallLightTag.LIGHT_LAYER) != 0, "%s lleva la capa" % node.name)
	zone.get_parent().remove_child(zone)
	zone.queue_free()
	await wait_process_frames()


func test_wall_light_tag_adds_the_layer_without_removing_layer_one() -> void:
	var root := Node3D.new()
	var child := MeshInstance3D.new()
	root.add_child(child)
	WallLightTag.tag(root)
	assert_eq(child.layers & 1, 1, "sigue en la capa 1")
	assert_true((child.layers & WallLightTag.LIGHT_LAYER) != 0, "y entra en la capa de las murallas")
	root.free()


func test_the_terrain_texture_set_has_normals_and_equal_sizes() -> void:
	var assets: Terrain3DAssets = load(TERRAIN_ASSETS_PATH) as Terrain3DAssets
	if not assert_not_null(assets, "se cargan los assets del terreno"):
		return
	assert_true(assets.get_texture_count() >= 10, "el juego de texturas de Poly Haven")
	# Terrain3D pide el mismo tamaño dentro de cada familia (todos los albedos, todas las normales).
	var albedo_size: Vector2i = Vector2i.ZERO
	var normal_size: Vector2i = Vector2i.ZERO
	for i: int in assets.get_texture_count():
		var texture: Terrain3DTextureAsset = assets.get_texture(i)
		if not assert_not_null(texture.albedo_texture, "textura %d: albedo" % i) or not assert_not_null(texture.normal_texture, "textura %d: normal" % i):
			continue
		var this_albedo: Vector2i = Vector2i(texture.albedo_texture.get_width(), texture.albedo_texture.get_height())
		var this_normal: Vector2i = Vector2i(texture.normal_texture.get_width(), texture.normal_texture.get_height())
		if albedo_size == Vector2i.ZERO:
			albedo_size = this_albedo
			normal_size = this_normal
		assert_eq(this_albedo, albedo_size, "textura %d: albedo del mismo tamaño que el resto" % i)
		assert_eq(this_normal, normal_size, "textura %d: normal del mismo tamaño que el resto" % i)
		assert_true(texture.uv_scale >= 0.2 and texture.uv_scale <= 0.6, "textura %d: teselas de 1,7 a 5 m" % i)
		assert_true(texture.normal_texture.resource_path.contains("polyhaven"), "textura %d: sin la normal plana" % i)


func test_the_grass_materials_fade_from_the_terrain_colour_up_to_the_tip() -> void:
	for name: String in GRASS_MATERIALS:
		var material: ShaderMaterial = load("res://assets/materials/vegetation/%s.tres" % name) as ShaderMaterial
		if not assert_not_null(material, name):
			continue
		var base: Color = material.get_shader_parameter(&"base_color")
		var tip: Color = material.get_shader_parameter(&"tip_color")
		assert_true(tip.get_luminance() > base.get_luminance(), "%s: la punta es más clara que la base" % name)
		assert_true(float(material.get_shader_parameter(&"blade_height")) > 1.0, "%s: altura del modelo" % name)
		assert_true(float(material.get_shader_parameter(&"wind_strength")) > 0.0, "%s: con viento" % name)


func test_the_keep_applies_its_realm_materials_and_three_lods() -> void:
	var keep: FortKeep = (load("res://scenes/world/props/fort/fort_keep.tscn") as PackedScene).instantiate() as FortKeep
	tree.root.add_child(keep)
	var lods: Array[Node] = keep.find_children("FortKeep_LOD*", "MeshInstance3D", true, false)
	assert_eq(lods.size(), 3, "tres niveles de detalle")
	var by_name: Dictionary = {}
	for node: Node in lods:
		by_name[node.name] = node
	if by_name.has(&"FortKeep_LOD0") and by_name.has(&"FortKeep_LOD1") and by_name.has(&"FortKeep_LOD2"):
		var lod0: MeshInstance3D = by_name[&"FortKeep_LOD0"]
		var lod1: MeshInstance3D = by_name[&"FortKeep_LOD1"]
		var lod2: MeshInstance3D = by_name[&"FortKeep_LOD2"]
		assert_eq(lod0.visibility_range_end, FortKeep.LOD1_DISTANCE)
		assert_eq(lod1.visibility_range_begin, FortKeep.LOD1_DISTANCE)
		assert_eq(lod1.visibility_range_end, FortKeep.LOD2_DISTANCE)
		assert_eq(lod2.visibility_range_begin, FortKeep.LOD2_DISTANCE)
		assert_eq(lod2.visibility_range_end, 0.0, "la silueta no se apaga")
	var overridden: int = 0
	for node: Node in keep.find_children("*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = node as MeshInstance3D
		for i: int in instance.mesh.get_surface_count():
			if instance.get_surface_override_material(i) != null:
				overridden += 1
	assert_true(overridden > 0, "los materiales del reino sustituyen a los del glTF")
	tree.root.remove_child(keep)
	keep.free()
