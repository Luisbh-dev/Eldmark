extends SceneTree
## Generates the prop scenes (scenes/world/props/...) used by Vado Gris: each one is a kit mesh
## + realm material + simple collision on layer 1, so that client and server
## load the same collisions.
##
## Usage, after copying the assets, importing, extracting the meshes and generating the materials:
## [codeblock]
## godot --headless --path . -s res://tools/props/build_vado_gris_props.gd
## [/codeblock]
## Deterministic (fixed-seed generator). Custom pieces that do not exist in the kits (the
## stone bridge) are modeled here with the kit textures and saved in
## assets/models/environment/custom/.

const PROPS_DIR: String = "res://scenes/world/props"
const CUSTOM_DIR: String = "res://assets/models/environment/custom"
const MAT: String = "res://assets/materials/realms/"
const CW_MESH: String = "res://assets/models/environment/castle_wall/meshes/"
const VIL_MESH: String = "res://assets/models/environment/village/meshes/"
const KEN_MESH: String = "res://assets/models/blockout/kenney_castle/meshes/"

const BAKED_MULTIMESH: GDScript = preload("res://scripts/world/baked_multimesh.gd")
const FORT_GATE_SCRIPT: GDScript = preload("res://scripts/world/fort_gate.gd")

## Physics layer of the static world (the one PlayerCharacter looks at; also the camera).
const WORLD_LAYER: int = PlayerCharacter.WORLD_COLLISION_LAYER
## Layer of the invisible blockers that stop only the player (not the camera or the shots).
const PLAYER_BLOCKER_LAYER: int = PlayerCharacter.PLAYER_BLOCKER_LAYER

## Distance (m) at which small pieces stop being drawn (crates, fences, rubble...).
const SMALL_PROP_RANGE: float = 140.0
## Distance (m) at which medium pieces stop being drawn (tents, carts, bonfires).
const MEDIUM_PROP_RANGE: float = 220.0

# Fort.
const FORT_HALF: float = 20.0
const LOG_RADIUS: float = 0.23
const LOG_SPACING: float = 0.46
const LOG_HEIGHT: float = 4.9
const LOG_BURY: float = 0.6
const TIP_HEIGHT: float = 0.7
## Walkway height: the parapet (top of the palisade, 4.65 m) ends up at 1.3 m, chest height,
## and the camera pivot (1.6 m above the feet) above the tips.
const WALKWAY_HEIGHT: float = 3.35
const WALKWAY_WIDTH: float = 2.0
## Horizontal run of each ramp (about a 26° slope).
const RAMP_RUN: float = 6.9
const GATE_HALF_WIDTH: float = 2.0
## Height of the gate leaves (they reach the lintel).
const GATE_LEAF_HEIGHT: float = 4.3
const TOWER_HALF: float = 3.0
const STOREY: float = 6.0

# Bridge.
const BRIDGE_LENGTH: float = 24.0
const BRIDGE_DECK_HALF: float = 2.0
const BRIDGE_PARAPET: float = 0.4
const BRIDGE_PARAPET_HEIGHT: float = 0.95
const BRIDGE_CROWN: float = 1.5
## Height of the deck at the ends relative to the bank (negative: it is buried).
const BRIDGE_END_DEPTH: float = -0.3
const BRIDGE_SPAN: float = 15.0
## Final stretch (m) in which the parapets drop down to the deck and sink into the bank.
const BRIDGE_WING: float = 2.5
## Height (m) of the invisible blocker above the parapets: more than a jump (1.45 m), so nobody
## jumps into the deep channel (which can only be left through the ford).
const BRIDGE_JUMP_BLOCK: float = 1.7

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _failed: bool = false
var _materials: Dictionary = {}


func _initialize() -> void:
	_rng.seed = 20261028
	_build_crate("eldrun")
	_build_fire_pit()
	_build_fort_gate()
	_build_wooden_ramp()
	_build_banner_pole()
	_build_fort()
	_build_stone_bridge()
	for realm: String in ["vardheim", "solmarch"]:
		_build_tent(realm)
		_build_crate(realm)
		_build_wagon(realm)
		_build_fence(realm)
		_build_camp_banner(realm)
		_build_wall_tower(realm)
		_build_gatehouse(realm)
	_build_ruin_pieces()
	quit(1 if _failed else 0)


# =============================================================================================
# Vado Gris fort
# =============================================================================================

## Face [param side] (0 = south, 1 = east, 2 = north, 3 = west) of a box of half-side
## [param half]: the kit's Wall_* pieces are 6 x 6 m planes with their origin at a corner.
func _tower_face_transform(side: int, half: float, y: float) -> Transform3D:
	var basis: Basis = Basis(Vector3.UP, _side_yaw(side))
	var corner: Vector3 = basis * Vector3(-half, 0, half)
	return Transform3D(basis, corner + Vector3(0, y, 0))


## Rotation that takes the +Z normal of a piece to the face [param side].
static func _side_yaw(side: int) -> float:
	return [0.0, PI * 0.5, PI, -PI * 0.5][side]


## Wooden gate of the fort: two leaves of vertical planks (plank texture from the Castle
## Wall Kit) with three iron straps, square up to the lintel. It is a separate node (group
## "fort_gate", script FortGate) because it has health and breaks under blows. It is saved closed and with two
## bodies (docs/fortress.md, section 3.1; see scripts/world/fort_gate.gd): the node itself is the
## movement one (realm layers 5 to 7, all three because the fort starts neutral) and "Vista" is the
## view one (structure layer 4), which the camera and the line of sight of the blows see. Origin:
## center of the opening at ground level.
func _build_fort_gate() -> void:
	var root := StaticBody3D.new()
	root.name = "FortGate"
	root.collision_layer = FortGate.layers_for(0, false)
	root.collision_mask = 0
	root.set_script(FORT_GATE_SCRIPT)
	root.add_to_group(&"fort_gate", true)
	var leaf_mesh: ArrayMesh = _build_gate_leaf_mesh()
	for i: int in 2:
		var leaf := MeshInstance3D.new()
		leaf.name = "Hoja%d" % (i + 1)
		leaf.mesh = leaf_mesh
		leaf.set_surface_override_material(0, _mat("eldrun/planks"))
		leaf.set_surface_override_material(1, _mat("eldrun/metal"))
		# The mesh runs from the hinge toward +Z: the south leaf is the same one rotated 180°.
		leaf.transform = Transform3D(Basis(Vector3.UP, 0.0 if i == 0 else PI), Vector3(0, 0, -GATE_HALF_WIDTH if i == 0 else GATE_HALF_WIDTH))
		root.add_child(leaf)
	var gate_size: Vector3 = Vector3(0.5, GATE_LEAF_HEIGHT, GATE_HALF_WIDTH * 2.0)
	var gate_center: Vector3 = Vector3(0, GATE_LEAF_HEIGHT * 0.5, 0)
	_box(root, "ColisionCerrada", gate_size, gate_center)
	var view := StaticBody3D.new()
	view.name = "Vista"
	view.collision_layer = PlayerCharacter.STRUCTURE_LAYER
	view.collision_mask = 0
	root.add_child(view)
	_box(view, "ColisionVista", gate_size, gate_center)
	_save(root, PROPS_DIR.path_join("fort/fort_gate.tscn"))


## Mesh of one gate leaf: a 2 m x 4.3 m x 0.14 m board (surface 0, vertical planks)
## and three iron straps on each face (surface 1). It runs from the hinge (z = 0) to
## z = 2. Saved in assets/models/environment/custom/fort_gate_leaf.tres.
func _build_gate_leaf_mesh() -> ArrayMesh:
	var width: float = GATE_HALF_WIDTH - 0.02
	var thickness: float = 0.14
	var planks := SurfaceTool.new()
	planks.begin(Mesh.PRIMITIVE_TRIANGLES)
	# U along the planks (vertical), V across: the texture has 12 planks per
	# repetition, so 2.4 m of V gives 20 cm planks.
	_box_faces(planks, Vector3(-thickness * 0.5, 0.0, 0.01), Vector3(thickness * 0.5, GATE_LEAF_HEIGHT, 0.01 + width),
			func(p: Vector3) -> Vector2: return Vector2(p.y / 3.0, (p.z + p.x) / 2.4))
	var bands := SurfaceTool.new()
	bands.begin(Mesh.PRIMITIVE_TRIANGLES)
	for y: float in [0.55, 2.15, 3.75]:
		for face: float in [-1.0, 1.0]:
			var x0: float = face * thickness * 0.5
			var x1: float = x0 + face * 0.025
			_box_faces(bands, Vector3(minf(x0, x1), y - 0.06, 0.06), Vector3(maxf(x0, x1), y + 0.06, width - 0.04),
					func(p: Vector3) -> Vector2: return Vector2(p.z, p.y) * 0.5)
	var mesh := ArrayMesh.new()
	for st: SurfaceTool in [planks, bands]:
		st.generate_normals()
		st.generate_tangents()
		st.commit(mesh)
	mesh.resource_name = "fort_gate_leaf"
	return _save_custom_mesh(mesh, "fort_gate_leaf.tres")


## Wooden ramp 2 m wide that rises [constant WALKWAY_HEIGHT] m. Origin: foot of the ramp
## on the ground; it rises toward -Z.
func _build_wooden_ramp() -> void:
	var root := StaticBody3D.new()
	root.name = "WoodenRamp"
	root.collision_layer = WORLD_LAYER
	root.collision_mask = 0
	var wood: Material = _mat("eldrun/wood")
	var run: float = RAMP_RUN
	var length: float = sqrt(run * run + WALKWAY_HEIGHT * WALKWAY_HEIGHT)
	var angle: float = atan2(WALKWAY_HEIGHT, run)
	var tilt := Basis(Vector3.RIGHT, angle)
	var tiles: int = 3
	for i: int in tiles:
		var along: float = (float(i) + 0.5) * length / tiles
		var center: Vector3 = tilt * Vector3(0, 0, -along)
		var basis: Basis = tilt.scaled(Vector3(1.0, 1.0, length / tiles / 2.0))
		_mesh(root, "Tablas%d" % i, VIL_MESH + "floor_wood_dark.tres", [wood],
				Transform3D(basis, center + Vector3(0, 0.02, 0)))
	# Stringers and posts.
	var beam := BoxMesh.new()
	beam.size = Vector3(0.18, 0.25, length)
	for x: float in [-1.0, 1.0]:
		var mi := MeshInstance3D.new()
		mi.name = "Larguero%s" % ("I" if x < 0 else "D")
		mi.mesh = beam
		mi.material_override = wood
		mi.transform = Transform3D(tilt, tilt * Vector3(x, -0.12, -length * 0.5))
		root.add_child(mi)
	var post := BoxMesh.new()
	post.size = Vector3(0.2, 1.0, 0.2)
	for x: float in [-0.9, 0.9]:
		for t: float in [0.45, 0.85]:
			var h: float = WALKWAY_HEIGHT * t
			var mi := MeshInstance3D.new()
			mi.name = "Pie%d" % mi.get_instance_id()
			mi.mesh = post
			mi.material_override = wood
			mi.transform = Transform3D(Basis().scaled(Vector3(1, h, 1)), Vector3(x, h * 0.5 - 0.1, -run * t))
			root.add_child(mi)
	var shape := CollisionShape3D.new()
	shape.name = "Colision"
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 0.2, length)
	shape.shape = box
	shape.transform = Transform3D(tilt, tilt * Vector3(0, -0.1, -length * 0.5))
	root.add_child(shape)
	_save(root, PROPS_DIR.path_join("fort/wooden_ramp.tscn"))


## Mast with banner (faction color per instance: faction_color). Origin: foot of the mast.
func _build_banner_pole() -> void:
	var root := Node3D.new()
	root.name = "BannerPole"
	var pole := CylinderMesh.new()
	pole.top_radius = 0.07
	pole.bottom_radius = 0.09
	pole.height = 6.0
	pole.radial_segments = 8
	var mi := MeshInstance3D.new()
	mi.name = "Mastil"
	mi.mesh = pole
	mi.material_override = _mat("eldrun/wood")
	mi.position = Vector3(0, 3.0, 0)
	root.add_child(mi)
	var banner := MeshInstance3D.new()
	banner.name = "Estandarte"
	banner.mesh = load(KEN_MESH + "flag_banner_long.tres") as Mesh
	banner.material_override = _mat("eldrun/banner")
	banner.transform = Transform3D(Basis().scaled(Vector3(1.6, 1.6, 2.4)), Vector3(0.08, 1.9, 0))
	banner.set_instance_shader_parameter(&"faction_color", RealmCatalog.color_of(RealmCatalog.HUECOS))
	root.add_child(banner)
	_save(root, PROPS_DIR.path_join("fort/banner_pole.tscn"))


## Complete fort: 40 m-per-side log palisade, interior walkway, two ramps, wooden gate
## on the west face and central tower with the banner. Origin: center of the plateau at
## ground height. Collisions: one body per side of palisade and of walkway.
func _build_fort() -> void:
	var root := Node3D.new()
	root.name = "VadoGrisFort"
	var log_material: Material = _mat("eldrun/palisade_log")
	var wood: Material = _mat("eldrun/wood")

	# --- Palisade: logs in a MultiMesh (2 draw calls for the whole fort).
	var log_mesh := CylinderMesh.new()
	log_mesh.top_radius = LOG_RADIUS
	log_mesh.bottom_radius = LOG_RADIUS * 1.05
	log_mesh.height = LOG_HEIGHT
	log_mesh.radial_segments = 8
	log_mesh.rings = 1
	log_mesh.cap_bottom = false
	var tip_mesh := CylinderMesh.new()
	tip_mesh.top_radius = 0.02
	tip_mesh.bottom_radius = LOG_RADIUS
	tip_mesh.height = TIP_HEIGHT
	tip_mesh.radial_segments = 8
	tip_mesh.rings = 1
	tip_mesh.cap_bottom = false
	var log_xforms: Array[Transform3D] = []
	var tip_xforms: Array[Transform3D] = []
	var count: int = int(round(FORT_HALF * 2.0 / LOG_SPACING))
	for side: int in 4:
		var basis: Basis = Basis(Vector3.UP, _side_yaw(side))
		for i: int in count:
			var along: float = -FORT_HALF + (float(i) + 0.5) * (FORT_HALF * 2.0 / count)
			var local: Vector3 = Vector3(along, 0, FORT_HALF)
			var world: Vector3 = basis * local
			if side == 3 and absf(world.z) < GATE_HALF_WIDTH + 0.1:
				continue
			var height_jitter: float = _rng.randf_range(-0.25, 0.2)
			var tilt := Basis(Vector3(1, 0, 0), _rng.randf_range(-0.03, 0.03)) \
					* Basis(Vector3(0, 0, 1), _rng.randf_range(-0.03, 0.03)) \
					* Basis(Vector3.UP, _rng.randf_range(0.0, TAU))
			var log_height: float = LOG_HEIGHT + height_jitter
			var center: Vector3 = world + Vector3(0, log_height * 0.5 - LOG_BURY, 0)
			log_xforms.append(Transform3D(tilt.scaled(Vector3(1, log_height / LOG_HEIGHT, 1)), center))
			var top: Vector3 = world + tilt * Vector3(0, log_height - LOG_BURY + TIP_HEIGHT * 0.5, 0)
			tip_xforms.append(Transform3D(tilt, Vector3(world.x, 0, world.z) + Vector3(0, log_height - LOG_BURY + TIP_HEIGHT * 0.5, 0)))
			if top.y < 0.0:
				_fail("tronco bajo el suelo")
	_multimesh(root, "Troncos", log_mesh, log_material, log_xforms)
	_multimesh(root, "Puntas", tip_mesh, log_material, tip_xforms)

	# Palisade collision: one body with one box per side (the west one split by the gate).
	var palisade_body := StaticBody3D.new()
	palisade_body.name = "EmpalizadaColision"
	palisade_body.collision_layer = WORLD_LAYER
	palisade_body.collision_mask = 0
	root.add_child(palisade_body)
	var wall_height: float = LOG_HEIGHT - LOG_BURY + TIP_HEIGHT * 0.5
	var thickness: float = LOG_RADIUS * 2.2
	_box(palisade_body, "Sur", Vector3(FORT_HALF * 2.0 + thickness, wall_height, thickness), Vector3(0, wall_height * 0.5, FORT_HALF))
	_box(palisade_body, "Norte", Vector3(FORT_HALF * 2.0 + thickness, wall_height, thickness), Vector3(0, wall_height * 0.5, -FORT_HALF))
	_box(palisade_body, "Este", Vector3(thickness, wall_height, FORT_HALF * 2.0), Vector3(FORT_HALF, wall_height * 0.5, 0))
	var west_len: float = FORT_HALF - GATE_HALF_WIDTH
	_box(palisade_body, "OesteNorte", Vector3(thickness, wall_height, west_len), Vector3(-FORT_HALF, wall_height * 0.5, -GATE_HALF_WIDTH - west_len * 0.5))
	_box(palisade_body, "OesteSur", Vector3(thickness, wall_height, west_len), Vector3(-FORT_HALF, wall_height * 0.5, GATE_HALF_WIDTH + west_len * 0.5))

	# --- Interior walkway (2 x 2 m Floor_WoodDark) on posts.
	var walk_center: float = FORT_HALF - LOG_RADIUS - WALKWAY_WIDTH * 0.5
	var tiles_per_side: int = int(round(walk_center * 2.0 / 2.0)) + 1
	var floor_mesh: Mesh = load(VIL_MESH + "floor_wood_dark.tres") as Mesh
	var floor_xforms: Array[Transform3D] = []
	var post_xforms: Array[Transform3D] = []
	var step: float = walk_center * 2.0 / float(tiles_per_side - 1)
	for side: int in 4:
		var basis: Basis = Basis(Vector3.UP, _side_yaw(side))
		for i: int in tiles_per_side - 1:
			var along: float = -walk_center + float(i) * step
			var p: Vector3 = basis * Vector3(along, WALKWAY_HEIGHT, walk_center)
			floor_xforms.append(Transform3D(basis.scaled(Vector3(step / 2.0, 1.0, 1.0)), p))
			# No posts in the gate opening (west face): you pass underneath.
			if i % 2 == 0 and not (side == 3 and absf(along) < GATE_HALF_WIDTH + 0.4):
				for offset: float in [-0.85, 0.85]:
					var q: Vector3 = basis * Vector3(along, 0.0, walk_center + offset)
					post_xforms.append(Transform3D(Basis().scaled(Vector3(1.0, WALKWAY_HEIGHT + 0.5, 1.0)), q + Vector3(0, (WALKWAY_HEIGHT + 0.5) * 0.5 - 0.5, 0)))
	_multimesh(root, "Pasarela", floor_mesh, wood, floor_xforms)
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.22, 1.0, 0.22)
	_multimesh(root, "PiesDerechos", post_mesh, wood, post_xforms)
	var walk_body := StaticBody3D.new()
	walk_body.name = "PasarelaColision"
	walk_body.collision_layer = WORLD_LAYER
	walk_body.collision_mask = 0
	root.add_child(walk_body)
	var walk_len: float = walk_center * 2.0 + WALKWAY_WIDTH
	for side: int in 4:
		var basis: Basis = Basis(Vector3.UP, _side_yaw(side))
		var shape := CollisionShape3D.new()
		shape.name = "Lado%d" % side
		var box := BoxShape3D.new()
		box.size = Vector3(walk_len, 0.2, WALKWAY_WIDTH)
		shape.shape = box
		shape.transform = Transform3D(basis, basis * Vector3(0, WALKWAY_HEIGHT - 0.1, walk_center))
		walk_body.add_child(shape)

	# --- Two symmetrical ramps (north and south) next to the walkway, east of the tower.
	var ramp_scene: PackedScene = load(PROPS_DIR.path_join("fort/wooden_ramp.tscn")) as PackedScene
	var ramp_foot: float = walk_center - WALKWAY_WIDTH * 0.5 - RAMP_RUN
	var north_ramp: Node3D = ramp_scene.instantiate() as Node3D
	north_ramp.name = "RampaNorte"
	north_ramp.position = Vector3(7.0, 0.0, -ramp_foot)
	root.add_child(north_ramp)
	var south_ramp: Node3D = ramp_scene.instantiate() as Node3D
	south_ramp.name = "RampaSur"
	south_ramp.transform = Transform3D(Basis(Vector3.UP, PI), Vector3(7.0, 0.0, ramp_foot))
	root.add_child(south_ramp)

	# --- Gate: frame of two posts and a lintel; the gate is its own scene.
	var frame_mat: Material = wood
	var post := BoxMesh.new()
	post.size = Vector3(0.7, 5.6, 0.7)
	for z: float in [-GATE_HALF_WIDTH - 0.35, GATE_HALF_WIDTH + 0.35]:
		var mi := MeshInstance3D.new()
		mi.name = "PostePuerta%s" % ("N" if z < 0 else "S")
		mi.mesh = post
		mi.material_override = frame_mat
		mi.position = Vector3(-FORT_HALF, 2.8 - LOG_BURY * 0.5, z)
		root.add_child(mi)
	var lintel := BoxMesh.new()
	lintel.size = Vector3(0.6, 0.5, GATE_HALF_WIDTH * 2.0 + 1.4)
	var lintel_mi := MeshInstance3D.new()
	lintel_mi.name = "Dintel"
	lintel_mi.mesh = lintel
	lintel_mi.material_override = frame_mat
	lintel_mi.position = Vector3(-FORT_HALF, 4.6, 0)
	root.add_child(lintel_mi)
	_box(palisade_body, "PostesPuerta", Vector3(0.7, 5.6, 0.7), Vector3(-FORT_HALF, 2.8, -GATE_HALF_WIDTH - 0.35))
	_box(palisade_body, "PostesPuerta2", Vector3(0.7, 5.6, 0.7), Vector3(-FORT_HALF, 2.8, GATE_HALF_WIDTH + 0.35))
	var gate: Node3D = (load(PROPS_DIR.path_join("fort/fort_gate.tscn")) as PackedScene).instantiate() as Node3D
	gate.name = "FortGate"
	gate.position = Vector3(-FORT_HALF, 0.0, 0.0)
	root.add_child(gate)

	# --- Central keep (ART-57): the custom model fort_keep.glb, with its banner and its low-resolution
	# collision (scripts/world/fort_keep.gd). It replaces the two-story tower of the Castle Wall Kit.
	var keep: Node3D = (load(PROPS_DIR.path_join("fort/fort_keep.tscn")) as PackedScene).instantiate() as Node3D
	keep.name = "FortKeep"
	root.add_child(keep)

	# --- Life in the yard: crates of the old garrison (mirrored north-south: the two piles give the
	# same shortcut to the walkway) and a bonfire on the axis, east of the tower.
	var crate_scene: PackedScene = load(PROPS_DIR.path_join("camp/eldrun_crate.tscn")) as PackedScene
	var crate_spots: Array[Vector4] = [
		Vector4(14.5, 0.0, -15.0, 0.2), Vector4(15.6, 0.0, -13.9, 0.7), Vector4(15.0, 1.06, -14.5, 0.4),
		Vector4(-15.0, 0.0, -12.5, 1.1),
	]
	var index: int = 1
	for mirror: int in 2:
		for spot: Vector4 in crate_spots:
			var crate: Node3D = crate_scene.instantiate() as Node3D
			crate.name = "Caja%d" % index
			index += 1
			var z: float = spot.z if mirror == 0 else -spot.z
			var yaw: float = spot.w if mirror == 0 else PI - spot.w
			crate.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(spot.x, spot.y, z))
			root.add_child(crate)
	var fire: Node3D = (load(PROPS_DIR.path_join("camp/fire_pit.tscn")) as PackedScene).instantiate() as Node3D
	fire.name = "Hoguera"
	fire.position = Vector3(8.0, 0.0, 0.0)
	root.add_child(fire)
	# Neutral banners on both sides of the gate, outside the palisade (they do not get in the way on
	# the walkway or of the open leaves).
	for zs: float in [-1.0, 1.0]:
		var gate_banner: Node3D = (load(PROPS_DIR.path_join("fort/banner_pole.tscn")) as PackedScene).instantiate() as Node3D
		gate_banner.name = "EstandartePuerta%s" % ("N" if zs < 0.0 else "S")
		gate_banner.position = Vector3(-FORT_HALF - 1.5, 0.0, zs * (GATE_HALF_WIDTH + 1.8))
		root.add_child(gate_banner)

	# --- Markers for the phase 4 logic. The capture circle sits between the gate and
	# the tower, with its edge 0.5 m from the tower (x = -3).
	var circle := Marker3D.new()
	circle.name = "CaptureCircle"
	circle.position = Vector3(-8.5, 0.05, 0.0)
	circle.set_meta(&"radius", 5.0)
	circle.add_to_group(&"capture_points", true)
	root.add_child(circle)
	var captain := Marker3D.new()
	captain.name = "CaptainSpawn"
	captain.position = Vector3(-6.0, 0.05, 4.0)
	root.add_child(captain)
	var guard_corners: Array[Vector2] = [Vector2(-14, -14), Vector2(-14, 14), Vector2(12, -12), Vector2(12, 12)]
	for i: int in 4:
		var guard := Marker3D.new()
		guard.name = "GuardSpawn%d" % (i + 1)
		guard.position = Vector3(guard_corners[i].x, 0.05, guard_corners[i].y)
		root.add_child(guard)
	_add_fort_npc_markers(root, guard_corners, captain.position)
	_save(root, PROPS_DIR.path_join("fort/vado_gris_fort.tscn"))


## Markers for the fort NPCs (docs/fortress.md, section 4.3), data only for the server:
## [br]- Patrol routes of the Hollow (group patrol_points, metadata route): from the yard up the
## ramp to the walkway and along it toward the gate, one through the north and another through the south (mirrored).
## [br]- A spawner (NpcSpawner) per Hollow at each GuardSpawn, active while the fort is neutral; the
## two on the east (next to the ramps) patrol, the two at the gate stay put.
## [br]- The Ford Captain's spawner at the CaptainSpawn (inside the capture circle).
## All of them face the gate (west, -X).
func _add_fort_npc_markers(root: Node3D, guard_corners: Array[Vector2], captain_position: Vector3) -> void:
	var walkway_y: float = WALKWAY_HEIGHT + 0.05
	var walkway_z: float = FORT_HALF - LOG_RADIUS - WALKWAY_WIDTH * 0.5
	for side: String in ["North", "South"]:
		var z_side: float = -1.0 if side == "North" else 1.0
		var points: Array[Vector3] = [
			Vector3(7.0, 0.05, z_side * 7.0),
			Vector3(7.0, walkway_y, z_side * walkway_z),
			Vector3(-12.0, walkway_y, z_side * walkway_z),
		]
		for i: int in points.size():
			var marker := Marker3D.new()
			marker.name = "Patrol%s%d" % [side, i + 1]
			marker.position = points[i]
			marker.set_meta(&"route", StringName("hollow_" + side.to_lower()))
			marker.add_to_group(&"patrol_points", true)
			root.add_child(marker)
	var facing: Basis = Basis(Vector3.UP, PI * 0.5)
	for i: int in guard_corners.size():
		var spawner := NpcSpawner.new()
		spawner.name = "HollowSpawner%d" % (i + 1)
		spawner.transform = Transform3D(facing, Vector3(guard_corners[i].x, 0.05, guard_corners[i].y))
		spawner.npc_id = &"hollow"
		spawner.max_alive = 1
		spawner.respawn_s = 0.0
		spawner.alert_group = &"vado_gris_hollows"
		spawner.condition = NpcSpawner.Condition.FORT_NEUTRAL
		if i >= 2:
			spawner.patrol_route = &"hollow_north" if guard_corners[i].y < 0.0 else &"hollow_south"
		spawner.add_to_group(&"npc_spawners", true)
		root.add_child(spawner)
	var captain_spawner := NpcSpawner.new()
	captain_spawner.name = "FordCaptainSpawner"
	captain_spawner.transform = Transform3D(facing, captain_position)
	captain_spawner.npc_id = &"ford_captain"
	captain_spawner.max_alive = 1
	captain_spawner.respawn_s = 0.0
	captain_spawner.alert_group = &"vado_gris_hollows"
	captain_spawner.condition = NpcSpawner.Condition.FORT_NEUTRAL
	captain_spawner.add_to_group(&"npc_spawners", true)
	root.add_child(captain_spawner)


# =============================================================================================
# Stone bridge
# =============================================================================================

## Single-arch bridge, narrow (4 m of deck) and with parapets. Custom mesh made by
## extruding a section along the bridge, with the stone texture of the Castle Wall Kit.
## Origin: center of the opening at bank height; the bridge runs along Z.
func _build_stone_bridge() -> void:
	var slices: int = 48
	var outer: float = BRIDGE_DECK_HALF + BRIDGE_PARAPET
	var section_x: Array[float] = [-outer, -outer, -BRIDGE_DECK_HALF, -BRIDGE_DECK_HALF, BRIDGE_DECK_HALF, BRIDGE_DECK_HALF, outer, outer]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var deck_faces: PackedVector3Array = PackedVector3Array()
	var sections: Array[PackedVector3Array] = []
	for s: int in slices + 1:
		var z: float = -BRIDGE_LENGTH * 0.5 + BRIDGE_LENGTH * float(s) / float(slices)
		sections.append(_bridge_section(z, section_x))
	for s: int in slices:
		var a: PackedVector3Array = sections[s]
		var b: PackedVector3Array = sections[s + 1]
		var perimeter: float = 0.0
		for e: int in a.size():
			var e2: int = (e + 1) % a.size()
			var edge_len: float = a[e].distance_to(a[e2])
			var u0: float = perimeter / 3.0
			var u1: float = (perimeter + edge_len) / 3.0
			perimeter += edge_len
			var v0: float = a[e].z / 3.0
			var v1: float = b[e].z / 3.0
			_quad(st, a[e], a[e2], b[e2], b[e], Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1))
			# Collision of the whole outline, including the belly of the arch (otherwise, from the channel you
			# could get into the bridge masonry).
			deck_faces.append_array(PackedVector3Array([a[e], a[e2], b[e2], a[e], b[e2], b[e]]))
	# End caps (against the bank).
	for cap: int in 2:
		var sec: PackedVector3Array = sections[0] if cap == 0 else sections[slices]
		var centroid: Vector3 = Vector3.ZERO
		for p: Vector3 in sec:
			centroid += p
		centroid /= sec.size()
		for e: int in sec.size():
			var e2: int = (e + 1) % sec.size()
			var p0: Vector3 = sec[e]
			var p1: Vector3 = sec[e2]
			if cap == 0:
				_tri(st, centroid, p0, p1)
			else:
				_tri(st, centroid, p1, p0)
	st.generate_normals()
	st.generate_tangents()
	var mesh: ArrayMesh = st.commit()
	mesh.resource_name = "stone_bridge"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CUSTOM_DIR))
	var mesh_path: String = CUSTOM_DIR.path_join("stone_bridge.tres")
	var error: Error = ResourceSaver.save(mesh, mesh_path)
	if error != OK:
		_fail("No se pudo guardar %s" % mesh_path)
		return
	mesh = load(mesh_path) as ArrayMesh

	var root := StaticBody3D.new()
	root.name = "StoneBridge"
	root.collision_layer = WORLD_LAYER
	root.collision_mask = 0
	var mi := MeshInstance3D.new()
	mi.name = "Puente"
	mi.mesh = mesh
	mi.material_override = _mat("eldrun/stone_bridge")
	root.add_child(mi)
	var shape := CollisionShape3D.new()
	shape.name = "Colision"
	var concave := ConcavePolygonShape3D.new()
	concave.backface_collision = true
	concave.set_faces(deck_faces)
	shape.shape = concave
	root.add_child(shape)
	# Invisible blocker above the parapets (player only): you cannot jump into the channel.
	var blocker := StaticBody3D.new()
	blocker.name = "BloqueoSalto"
	blocker.collision_layer = PLAYER_BLOCKER_LAYER
	blocker.collision_mask = 0
	root.add_child(blocker)
	var block_length: float = BRIDGE_LENGTH - BRIDGE_WING * 2.0
	var block_bottom: float = BRIDGE_END_DEPTH
	var block_top: float = BRIDGE_CROWN + BRIDGE_PARAPET_HEIGHT + BRIDGE_JUMP_BLOCK
	for x: float in [-1.0, 1.0]:
		_box(blocker, "Pretil%s" % ("O" if x < 0.0 else "E"),
				Vector3(BRIDGE_PARAPET, block_top - block_bottom, block_length),
				Vector3(x * (BRIDGE_DECK_HALF + BRIDGE_PARAPET * 0.5), (block_top + block_bottom) * 0.5, 0.0))
	_save(root, PROPS_DIR.path_join("bridge/stone_bridge.tscn"))


## Height of the deck at z: BRIDGE_CROWN at the center and somewhat below the bank at the
## ends, so that the deck comes out of the terrain without a step (move_and_slide does not climb
## steps) and with a slope of about 15° where you cross.
static func _deck_height(z: float) -> float:
	var t: float = z / (BRIDGE_LENGTH * 0.5)
	return BRIDGE_END_DEPTH + (BRIDGE_CROWN - BRIDGE_END_DEPTH) * (1.0 - t * t)


## Intrados: a segmental arch over the water; outside the opening, a solid abutment down below ground.
static func _underside(z: float) -> float:
	var t: float = z / (BRIDGE_SPAN * 0.5)
	if absf(t) >= 1.0:
		return -2.6
	return -1.6 + 2.0 * sqrt(1.0 - t * t)


## Closed section (counterclockwise seen from +Z): left outer side, parapet, deck,
## right parapet, right outer side and belly.
func _bridge_section(z: float, xs: Array[float]) -> PackedVector3Array:
	var deck: float = _deck_height(z)
	# At the ends the parapets drop down to the deck (wings that sink into the bank): this way
	# they do not frame a pit of earth where the deck enters the terrain.
	var half: float = BRIDGE_LENGTH * 0.5
	var top: float = deck + BRIDGE_PARAPET_HEIGHT * smoothstep(half, half - BRIDGE_WING, absf(z))
	var bottom: float = _underside(z)
	return PackedVector3Array([
		Vector3(xs[0], bottom, z), Vector3(xs[1], top, z), Vector3(xs[2], top, z),
		Vector3(xs[3], deck, z), Vector3(xs[4], deck, z), Vector3(xs[5], top, z),
		Vector3(xs[6], top, z), Vector3(xs[7], bottom, z),
	])


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2) -> void:
	# Clockwise order seen from outside (front face in Godot): normals pointing outward.
	st.set_uv(ua)
	st.add_vertex(a)
	st.set_uv(ub)
	st.add_vertex(b)
	st.set_uv(uc)
	st.add_vertex(c)
	st.set_uv(ua)
	st.add_vertex(a)
	st.set_uv(uc)
	st.add_vertex(c)
	st.set_uv(ud)
	st.add_vertex(d)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	for p: Vector3 in [a, b, c]:
		st.set_uv(Vector2(p.x, p.y) / 3.0)
		st.add_vertex(p)


# =============================================================================================
# Camps
# =============================================================================================

## Gable canvas tent (prism; there are no tents in the kits). Origin: center on the ground.
func _build_tent(realm: String) -> void:
	var root := StaticBody3D.new()
	root.name = "Tent"
	root.collision_layer = WORLD_LAYER
	root.collision_mask = 0
	var size := Vector3(3.4, 2.5, 4.2)
	var prism := PrismMesh.new()
	prism.size = size
	var cloth: Material = _mat(realm + ("/hide" if realm == "vardheim" else "/cloth"))
	var mi := MeshInstance3D.new()
	mi.name = "Lona"
	mi.mesh = prism
	mi.material_override = cloth
	mi.position = Vector3(0, size.y * 0.5, 0)
	mi.visibility_range_end = MEDIUM_PROP_RANGE
	root.add_child(mi)
	var pole := CylinderMesh.new()
	pole.top_radius = 0.05
	pole.bottom_radius = 0.05
	pole.height = size.y + 0.5
	pole.radial_segments = 6
	for z: float in [-size.z * 0.5 - 0.05, size.z * 0.5 + 0.05]:
		var p := MeshInstance3D.new()
		p.name = "Palo%s" % ("A" if z < 0 else "B")
		p.mesh = pole
		p.material_override = _mat(realm + "/wood")
		p.position = Vector3(0, pole.height * 0.5, z)
		p.visibility_range_end = SMALL_PROP_RANGE
		root.add_child(p)
	var shape := CollisionShape3D.new()
	shape.name = "Colision"
	var convex := ConvexPolygonShape3D.new()
	var hx: float = size.x * 0.5
	var hz: float = size.z * 0.5
	convex.points = PackedVector3Array([
		Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(0, size.y, -hz),
		Vector3(-hx, 0, hz), Vector3(hx, 0, hz), Vector3(0, size.y, hz),
	])
	shape.shape = convex
	root.add_child(shape)
	_save(root, PROPS_DIR.path_join("camp/%s_tent.tscn" % realm))


func _build_crate(realm: String) -> void:
	var root := _static_root("Crate")
	_mesh(root, "Caja", VIL_MESH + "prop_crate.tres", [_mat(realm + "/wood")], Transform3D.IDENTITY).visibility_range_end = SMALL_PROP_RANGE
	_box(root, "Colision", Vector3(1.08, 1.06, 1.08), Vector3(0, 0.53, 0))
	_save(root, PROPS_DIR.path_join("camp/%s_crate.tscn" % realm))


func _build_wagon(realm: String) -> void:
	var root := _static_root("Wagon")
	_mesh(root, "Carro", VIL_MESH + "prop_wagon.tres", [_mat(realm + "/wood")], Transform3D.IDENTITY).visibility_range_end = MEDIUM_PROP_RANGE
	_box(root, "Colision", Vector3(1.9, 1.5, 4.0), Vector3(0, 0.75, -1.14))
	_save(root, PROPS_DIR.path_join("camp/%s_wagon.tscn" % realm))


## 2 m fence section.
func _build_fence(realm: String) -> void:
	var root := _static_root("Fence")
	_mesh(root, "Valla", VIL_MESH + "prop_wooden_fence_single.tres", [_mat(realm + "/wood")], Transform3D.IDENTITY).visibility_range_end = SMALL_PROP_RANGE
	_box(root, "Colision", Vector3(2.0, 1.0, 0.15), Vector3(0, 0.5, 0))
	_save(root, PROPS_DIR.path_join("camp/%s_fence.tscn" % realm))


## Realm banner on a mast (faction color per instance).
func _build_camp_banner(realm: String) -> void:
	var root := _static_root("CampBanner")
	var pole := CylinderMesh.new()
	pole.top_radius = 0.07
	pole.bottom_radius = 0.09
	pole.height = 5.5
	pole.radial_segments = 8
	var mi := MeshInstance3D.new()
	mi.name = "Mastil"
	mi.mesh = pole
	mi.material_override = _mat(realm + "/wood")
	mi.position = Vector3(0, 2.75, 0)
	root.add_child(mi)
	var banner := MeshInstance3D.new()
	banner.name = "Estandarte"
	banner.mesh = load(KEN_MESH + "flag_banner_long.tres") as Mesh
	banner.material_override = _mat(realm + "/banner")
	banner.transform = Transform3D(Basis().scaled(Vector3(1.5, 1.5, 2.2)), Vector3(0.08, 1.9, 0))
	banner.set_instance_shader_parameter(&"faction_color", RealmCatalog.color_of(StringName(realm)))
	root.add_child(banner)
	var shape := CollisionShape3D.new()
	shape.name = "Colision"
	var cylinder := CylinderShape3D.new()
	cylinder.radius = 0.12
	cylinder.height = 5.5
	shape.shape = cylinder
	shape.position = Vector3(0, 2.75, 0)
	root.add_child(shape)
	_save(root, PROPS_DIR.path_join("camp/%s_banner.tscn" % realm))


## Bonfire: ring of stones, logs and embers with a warm light.
func _build_fire_pit() -> void:
	var root := _static_root("FirePit")
	var stone: Material = _mat("eldrun/ruin_trim")
	var stone_parts: Array[Array] = []
	for i: int in 9:
		var angle: float = TAU * float(i) / 9.0
		var piece: String = "prop_brick_1.tres" if i % 2 == 0 else "prop_brick_3.tres"
		var basis: Basis = Basis(Vector3.UP, -angle + _rng.randf_range(-0.2, 0.2)).scaled(Vector3(2.2, 2.2, 2.2))
		stone_parts.append([VIL_MESH + piece, Transform3D(basis, Vector3(cos(angle) * 0.85, 0.15, sin(angle) * 0.85))])
	var stones := MeshInstance3D.new()
	stones.name = "Piedras"
	stones.mesh = _merged_mesh(stone_parts, "fire_pit_stones.tres")
	stones.material_override = stone
	stones.visibility_range_end = MEDIUM_PROP_RANGE
	root.add_child(stones)
	var wood: Material = _mat("eldrun/wood")
	var log_parts: Array[Array] = []
	for i: int in 3:
		var angle: float = TAU * float(i) / 3.0
		var basis: Basis = (Basis(Vector3.UP, angle) * Basis(Vector3.RIGHT, -0.45)).scaled(Vector3(1.6, 1.6, 1.6))
		log_parts.append([KEN_MESH + "tree_log.tres", Transform3D(basis, Vector3(cos(angle) * 0.25, 0.3, sin(angle) * 0.25))])
	var logs := MeshInstance3D.new()
	logs.name = "Leños"
	logs.mesh = _merged_mesh(log_parts, "fire_pit_logs.tres")
	logs.material_override = wood
	logs.visibility_range_end = MEDIUM_PROP_RANGE
	root.add_child(logs)
	var ember := CylinderMesh.new()
	ember.top_radius = 0.55
	ember.bottom_radius = 0.6
	ember.height = 0.12
	ember.radial_segments = 12
	var ember_mi := MeshInstance3D.new()
	ember_mi.name = "Brasas"
	ember_mi.mesh = ember
	ember_mi.material_override = _mat("eldrun/ember")
	ember_mi.position = Vector3(0, 0.08, 0)
	ember_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ember_mi.visibility_range_end = MEDIUM_PROP_RANGE
	root.add_child(ember_mi)
	var light := OmniLight3D.new()
	light.name = "Luz"
	light.light_color = Color("#ffb060")
	light.light_energy = 1.6
	light.omni_range = 9.0
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 80.0
	light.distance_fade_length = 20.0
	light.position = Vector3(0, 1.0, 0)
	root.add_child(light)
	var shape := CollisionShape3D.new()
	shape.name = "Colision"
	var cylinder := CylinderShape3D.new()
	cylinder.radius = 1.05
	cylinder.height = 0.6
	shape.shape = cylinder
	shape.position = Vector3(0, 0.3, 0)
	root.add_child(shape)
	_save(root, PROPS_DIR.path_join("camp/fire_pit.tscn"))


# =============================================================================================
# Walls
# =============================================================================================

## Square wall tower, 6 x 6 m: 18 m above the ground (three courses and a buried
## foundation), recolored Castle Wall Kit.
## Vardheim: dark wooden hoarding on top. Solmarch: conical blue slate roof.
## Origin: center of the base at ground level; the back face (z = -3) rests on the wall.
func _build_wall_tower(realm: String) -> void:
	var root := _static_root("WallTower")
	var stone: Material = _mat(realm + "/stone_wall")
	var trim: Material = _mat(realm + "/stone_trim")
	var base_y: float = -STOREY
	var courses: int = 4
	for course: int in courses:
		for side: int in 4:
			var piece: String = "courtine_slits" if course == courses - 1 and side == 0 else "courtine_wall"
			var basis: Basis = Basis(Vector3.UP, _side_yaw(side))
			var xform := Transform3D(basis, basis * Vector3(-TOWER_HALF, 0, TOWER_HALF) + Vector3(0, base_y + course * STOREY, 0))
			_mesh(root, "Hilada%d_%d" % [course, side], CW_MESH + piece + ".tres", [stone], xform)
	var top: float = base_y + courses * STOREY
	_mesh(root, "Terraza", CW_MESH + "wall_floor.tres", [_mat("eldrun/stone_floor")], Transform3D(Basis(), Vector3(0, top - 0.05, 0)))
	if realm == "vardheim":
		for side: int in 4:
			var basis: Basis = Basis(Vector3.UP, _side_yaw(side))
			_mesh(root, "Almenas%d" % side, CW_MESH + "wall_battlements.tres", [trim], Transform3D(basis, basis * Vector3(0, 0, TOWER_HALF) + Vector3(0, top, 0)))
			_mesh(root, "Cadalso%d" % side, CW_MESH + "brattice_wall_1.tres", [_mat("vardheim/planks"), _mat("vardheim/planks")],
					Transform3D(basis, basis * Vector3(0, 0, TOWER_HALF - 0.2) + Vector3(0, top + 0.85, 0)))
	else:
		var roof_basis: Basis = Basis().scaled(Vector3(1.12, 1.15, 1.12))
		_mesh(root, "Tejado", VIL_MESH + "roof_tower_round_tiles.tres",
				[_mat("solmarch/wood"), _mat("solmarch/stone_trim"), _mat("solmarch/roof_slate"), _mat("solmarch/metal")],
				Transform3D(roof_basis, Vector3(0, top + 0.6, 0)))
	_box(root, "Colision", Vector3(TOWER_HALF * 2.0, top - base_y, TOWER_HALF * 2.0), Vector3(0, (top + base_y) * 0.5, 0))
	_save(root, PROPS_DIR.path_join("walls/%s_wall_tower.tscn" % realm))


## Wall gate: arch with a closed portcullis door between two towers that jut out toward the valley.
## Origin: center of the arch at ground level, wall face at z = 0, the valley toward +Z.
func _build_gatehouse(realm: String) -> void:
	var root := _static_root("Gatehouse")
	var stone: Material = _mat(realm + "/stone_wall")
	var trim: Material = _mat(realm + "/stone_trim")
	# Buried foundation, arch, wall on top and battlements (the wall is 12 m above the ground).
	_mesh(root, "Cimiento", CW_MESH + "courtine_wall.tres", [stone], Transform3D(Basis(), Vector3(-3, -STOREY, 0)))
	_mesh(root, "Arco", CW_MESH + "courtine_door_arch.tres", [stone, trim], Transform3D(Basis(), Vector3(-3, 0, 0)))
	_mesh(root, "SobreArco", CW_MESH + "courtine_wall.tres", [stone], Transform3D(Basis(), Vector3(-3, STOREY, 0)))
	_mesh(root, "Almenas", CW_MESH + "wall_battlements.tres", [trim], Transform3D(Basis(), Vector3(0, 2.0 * STOREY, 0)))
	# Closed gate (the kit's door decal) and portcullis.
	var door_mat: Material = _mat(realm + "/door")
	_mesh(root, "Porton", CW_MESH + "door_sticker_gate_arch.tres", [door_mat], Transform3D(Basis(), Vector3(0, 0, -0.45)))
	_mesh(root, "Rastrillo", CW_MESH + "door_sticker_portcullis.tres", [_mat(realm + "/metal")], Transform3D(Basis(), Vector3(0, 0, 0.05)))
	_box(root, "ColisionArco", Vector3(6.0, 19.0, 1.2), Vector3(0, 3.5, -0.4))
	# Towers on the sides.
	var tower_scene: PackedScene = load(PROPS_DIR.path_join("walls/%s_wall_tower.tscn" % realm)) as PackedScene
	for x: float in [-6.0, 6.0]:
		var tower: Node3D = tower_scene.instantiate() as Node3D
		tower.name = "Torre%s" % ("O" if x < 0 else "E")
		tower.position = Vector3(x, 0, 3.0)
		root.add_child(tower)
	# Realm banners on both sides of the arch.
	var banner_scene: PackedScene = load(PROPS_DIR.path_join("camp/%s_banner.tscn" % realm)) as PackedScene
	for x: float in [-4.2, 4.2]:
		var banner: Node3D = banner_scene.instantiate() as Node3D
		banner.name = "Estandarte%s" % ("O" if x < 0 else "E")
		banner.position = Vector3(x, 0, 6.6)
		root.add_child(banner)
	_save(root, PROPS_DIR.path_join("walls/%s_gatehouse.tscn" % realm))


# =============================================================================================
# Ruins of the village of Eld
# =============================================================================================

func _build_ruin_pieces() -> void:
	# The Village MegaKit piece caps the wall with a wooden sleeper (surface 0):
	# in a ruin of old Eld it reads as intact work, so it gets gray capstone.
	var coping: Material = _mat("eldrun/ruin_trim")
	var plaster: Material = _mat("eldrun/ruin_plaster")
	var stone: Material = _mat("eldrun/ruin_stone")
	var specs: Array[Array] = [
		["ruin_wall", "wall_uneven_brick_straight.tres", false],
		["ruin_wall_window", "wall_uneven_brick_window_wide_round.tres", false],
		["ruin_wall_door", "wall_uneven_brick_door_round.tres", true],
	]
	for spec: Array in specs:
		var root := _static_root("RuinWall")
		_mesh(root, "Muro", VIL_MESH + spec[1], [coping, plaster, stone], Transform3D.IDENTITY)
		if spec[2]:
			_box(root, "ColisionI", Vector3(0.45, 3.1, 0.4), Vector3(-0.78, 1.55, -0.1))
			_box(root, "ColisionD", Vector3(0.45, 3.1, 0.4), Vector3(0.78, 1.55, -0.1))
			_box(root, "ColisionDintel", Vector3(2.0, 0.6, 0.4), Vector3(0, 2.8, -0.1))
		else:
			_box(root, "Colision", Vector3(2.0, 3.1, 0.4), Vector3(0, 1.55, -0.1))
		_save(root, PROPS_DIR.path_join("ruins/%s.tscn" % spec[0]))
	var chimney := _static_root("RuinChimney")
	_mesh(chimney, "Chimenea", VIL_MESH + "prop_chimney.tres", [_mat("eldrun/ruin_trim"), _mat("eldrun/ruin_brick")], Transform3D.IDENTITY)
	_box(chimney, "Colision", Vector3(0.95, 3.2, 1.0), Vector3(0, 1.6, 0))
	_save(chimney, PROPS_DIR.path_join("ruins/ruin_chimney.tscn"))
	# Rubble: no collision (you walk over it). The nine stones are merged into a single mesh.
	var rubble := Node3D.new()
	rubble.name = "Rubble"
	var parts: Array[Array] = []
	for i: int in 9:
		var piece: String = "prop_brick_1.tres" if i % 3 != 0 else "prop_brick_3.tres"
		var s: float = _rng.randf_range(1.6, 2.6)
		var basis: Basis = (Basis(Vector3.UP, _rng.randf_range(0, TAU)) * Basis(Vector3.RIGHT, _rng.randf_range(-0.4, 0.4))).scaled(Vector3(s, s, s))
		parts.append([VIL_MESH + piece, Transform3D(basis, Vector3(_rng.randf_range(-1.2, 1.2), 0.1, _rng.randf_range(-1.0, 1.0)))])
	var stones := MeshInstance3D.new()
	stones.name = "Piedras"
	stones.mesh = _merged_mesh(parts, "rubble.tres")
	stones.material_override = _mat("eldrun/ruin_trim")
	stones.visibility_range_end = SMALL_PROP_RANGE
	rubble.add_child(stones)
	_save(rubble, PROPS_DIR.path_join("ruins/rubble.tscn"))
	var floor_root := Node3D.new()
	floor_root.name = "RuinFloor"
	_mesh(floor_root, "Suelo", VIL_MESH + "floor_uneven_brick.tres", [stone], Transform3D(Basis(), Vector3(0, 0.03, 0))).visibility_range_end = SMALL_PROP_RANGE
	_save(floor_root, PROPS_DIR.path_join("ruins/ruin_floor.tscn"))
	# Chapel pillar (Castle Wall Kit).
	var pillar := _static_root("RuinPillar")
	_mesh(pillar, "Pilar", CW_MESH + "pillar.tres", [_mat("eldrun/stone_trim")], Transform3D(Basis().scaled(Vector3(0.7, 0.75, 0.7)), Vector3(0.07, -0.3, 0.28)))
	_box(pillar, "Colision", Vector3(1.3, 4.5, 1.3), Vector3(0, 2.0, 0))
	_save(pillar, PROPS_DIR.path_join("ruins/ruin_pillar.tscn"))


# =============================================================================================
# Utilities
# =============================================================================================

## Merges several kit meshes ([path, transform]) into a single surface and saves it in
## assets/models/environment/custom/[param file_name] (one draw call instead of several).
func _merged_mesh(parts: Array[Array], file_name: String) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part: Array in parts:
		var mesh: Mesh = load(part[0]) as Mesh
		if mesh == null:
			_fail("Falta la malla %s" % part[0])
			continue
		for surface: int in mesh.get_surface_count():
			st.append_from(mesh, surface, part[1])
	st.generate_tangents()
	var merged: ArrayMesh = st.commit()
	merged.resource_name = file_name.get_basename()
	return _save_custom_mesh(merged, file_name)


## Saves a custom mesh in assets/models/environment/custom/ and returns it loaded.
func _save_custom_mesh(mesh: ArrayMesh, file_name: String) -> ArrayMesh:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CUSTOM_DIR))
	var path: String = CUSTOM_DIR.path_join(file_name)
	var error: Error = ResourceSaver.save(mesh, path)
	if error != OK:
		_fail("No se pudo guardar %s (%s)" % [path, error_string(error)])
		return mesh
	return load(path) as ArrayMesh


## The six faces of an axis-aligned box, with outward normals and UVs from [param uv].
func _box_faces(st: SurfaceTool, lo: Vector3, hi: Vector3, uv: Callable) -> void:
	var c: Array[Vector3] = [
		Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z),
		Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z),
	]
	var faces: Array[Array] = [
		[0, 1, 2, 3], [4, 5, 6, 7], [0, 4, 7, 3], [1, 2, 6, 5], [3, 7, 6, 2], [0, 1, 5, 4],
	]
	var center: Vector3 = (lo + hi) * 0.5
	for f: Array in faces:
		var a: Vector3 = c[f[0]]
		var b: Vector3 = c[f[1]]
		var cc: Vector3 = c[f[2]]
		var d: Vector3 = c[f[3]]
		# Front face in Godot = clockwise seen from outside; generate_normals() takes as the
		# normal (a - c) x (a - b): if it points inward, the order is reversed.
		var outward: Vector3 = (a + b + cc + d) * 0.25 - center
		if (a - cc).cross(a - b).dot(outward) < 0.0:
			var tmp: Vector3 = b
			b = d
			d = tmp
		_quad(st, a, b, cc, d, uv.call(a), uv.call(b), uv.call(cc), uv.call(d))


func _static_root(node_name: String) -> StaticBody3D:
	var root := StaticBody3D.new()
	root.name = node_name
	root.collision_layer = WORLD_LAYER
	root.collision_mask = 0
	return root


func _mat(key: String) -> Material:
	if not _materials.has(key):
		var material: Material = load(MAT + key + ".tres") as Material
		if material == null:
			_fail("Falta el material %s" % key)
		_materials[key] = material
	return _materials[key]


func _mesh(parent: Node, node_name: String, mesh_path: String, materials: Array, xform: Transform3D) -> MeshInstance3D:
	var mesh: Mesh = load(mesh_path) as Mesh
	if mesh == null:
		_fail("Falta la malla %s" % mesh_path)
		return null
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.transform = xform
	for i: int in mini(materials.size(), mesh.get_surface_count()):
		mi.set_surface_override_material(i, materials[i])
	if materials.size() == 1 and mesh.get_surface_count() > 1:
		mi.material_override = materials[0]
	parent.add_child(mi)
	return mi


## MultiMesh with the transforms saved as text (see BakedMultiMesh: in headless the
## buffer of a regular MultiMesh is not saved).
func _multimesh(parent: Node, node_name: String, mesh: Mesh, material: Material, xforms: Array[Transform3D]) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.set_script(BAKED_MULTIMESH)
	mmi.name = node_name
	mmi.set(&"source_mesh", mesh)
	mmi.set(&"instance_transforms", BAKED_MULTIMESH.pack_transforms(xforms))
	mmi.material_override = material
	parent.add_child(mmi)
	return mmi


func _box(parent: Node, node_name: String, size: Vector3, center: Vector3) -> void:
	var shape := CollisionShape3D.new()
	shape.name = node_name
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = center
	parent.add_child(shape)


func _save(root: Node, path: String) -> void:
	_own(root, root)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var packed := PackedScene.new()
	var error: Error = packed.pack(root)
	if error == OK:
		error = ResourceSaver.save(packed, path)
	if error != OK:
		_fail("No se pudo guardar %s (%s)" % [path, error_string(error)])
	else:
		print("pieza: %s" % path)
	root.free()


## Makes [param owner] the owner of all the descendants, except the inside of the
## instanced scenes (which are saved as a reference to their file).
func _own(node: Node, owner: Node) -> void:
	for child: Node in node.get_children():
		child.owner = owner
		if child.scene_file_path.is_empty():
			_own(child, owner)


func _fail(message: String) -> void:
	_failed = true
	printerr(message)
