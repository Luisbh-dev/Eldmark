extends RefCounted
## Vado Gris layout: key positions, the river, the roads and the height function.
##
## It is the single source of truth shared by the terrain generator and the scene assembly
## (tools/terrain/generate_vado_gris.gd). Coordinates in metres with the origin at the centre of the
## fort; north is -Z. Vardheim (Muro de Escarcha, "Frost Wall") is to the north and Solmarch (Muralla del
## Alba, "Dawn Wall") to the south. Design and rationale in docs/zonas/vado_gris.md.
##
## Fairness: everything playable is symmetric about the z = 0 axis (north-south mirror). The height
## function uses symmetrised noise (n(x, z) + n(x, -z)) inside the playable area and the river, the
## roads, the camps and the ruins are defined in the north half and mirrored.

# --- Terrain ---------------------------------------------------------------------------------

## Corner of the heightmap: 512 x 512 px at 1 m, in 2 x 2 regions of 256 m.
const MAP_ORIGIN: Vector3 = Vector3(-256.0, 0.0, -256.0)
const MAP_SIZE: int = 512
const REGION_SIZE: int = 256
## Half side of the playable area (300 x 300 m).
const PLAY_HALF: float = 150.0

# --- Walls, gates and camps -------------------------------------------------------------------

## Distance from the centre to the inner face of each wall.
const WALL_Z: float = 152.0
## Ground height next to the walls (camps and foot of the wall).
const CAMP_GROUND: float = 6.2
## Centre of each camp (in the north half; the south is the mirror).
const CAMP_CENTER_NORTH: Vector2 = Vector2(0.0, -128.0)
const CAMP_RADIUS: float = 24.0
## The wall extends this far on each side and sinks into the mountains.
const WALL_HALF_LENGTH: float = 180.0

# --- Fort ------------------------------------------------------------------------------------

const FORT_CENTER: Vector2 = Vector2.ZERO
## Half side of the palisade (about 40 m per side).
const FORT_HALF: float = 20.0
## Height of the hill plateau.
const FORT_GROUND: float = 10.2
## Fort gate: on the west face, facing the ford (on the symmetry axis).
const FORT_GATE: Vector2 = Vector2(-20.0, 0.0)
const FORT_GATE_WIDTH: float = 4.0

# --- River -------------------------------------------------------------------------------------

## The river surrounds the hill in a horseshoe open to the east: north arm at z = -RIVER_RADIUS, curving
## round the west and south arm at z = +RIVER_RADIUS. Both realms cross it to arrive.
const RIVER_RADIUS: float = 62.0
const WATER_LEVEL: float = 3.0
const BANK_LEVEL: float = 4.0
## Distance to the channel axis where the bed cuts the water surface (visible bank).
const WATER_HALF_WIDTH: float = 7.0
## Depth of the bed under the water outside the ford.
const RIVER_DEPTH: float = 1.6
## Ford: stretch of the west curve (measured along the channel from the vertex) with a shallow bed.
const FORD_HALF_LENGTH: float = 17.0
## Half stretch of the ford with the fully shallow bed (from here to FORD_HALF_LENGTH the bed drops
## to the deep channel, where the banks and the closing of the channel return).
const FORD_PLATEAU: float = 14.0
const FORD_DEPTH: float = 0.32
## Stone bridges: one on each arm, on the direct gate-fort line (x = 0).
const BRIDGE_X: float = 0.0
const BRIDGE_LENGTH: float = 24.0
const BRIDGE_WIDTH: float = 4.0

# --- Ruins -----------------------------------------------------------------------------------

## Village of old Eld on the west bank, on both sides of the road that reaches the ford.
const VILLAGE_CENTER: Vector2 = Vector2(-104.0, 0.0)
## Where the old village street ends (two pillars and rubble), before the western mountains
## close off the playable area.
const VILLAGE_ROAD_END_X: float = -136.0
## Ruined chapel on the peninsula, east of the fort.
const CHAPEL_CENTER: Vector2 = Vector2(82.0, 0.0)

var _noise_small: FastNoiseLite
var _noise_large: FastNoiseLite
var _noise_ridge: FastNoiseLite
var _noise_paint: FastNoiseLite


func _init() -> void:
	_noise_small = FastNoiseLite.new()
	_noise_small.seed = 1471
	_noise_small.frequency = 0.022
	_noise_small.fractal_octaves = 3
	_noise_large = FastNoiseLite.new()
	_noise_large.seed = 913
	_noise_large.frequency = 0.006
	_noise_large.fractal_octaves = 3
	_noise_ridge = FastNoiseLite.new()
	_noise_ridge.seed = 5309
	_noise_ridge.frequency = 0.011
	_noise_ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_noise_ridge.fractal_octaves = 4
	_noise_paint = FastNoiseLite.new()
	_noise_paint.seed = 77
	_noise_paint.frequency = 0.035
	_noise_paint.fractal_octaves = 2


# --- River -------------------------------------------------------------------------------------

## Gentle meander of the north arm (at x >= 0), zero next to the bridge so that the crossing is straight.
static func arm_offset(x: float) -> float:
	return 7.0 * sin(x * 0.034 + 0.9) * smoothstep(18.0, 70.0, x)


static func _arm_offset_slope(x: float) -> float:
	var e: float = 0.5
	return (arm_offset(x + e) - arm_offset(x - e)) / (2.0 * e)


## Distance (m) to the channel axis. Analytic: arm with a meander for x >= 0 and an arc of radius
## RIVER_RADIUS around the fort for x < 0. Symmetric in z.
static func river_distance(x: float, z: float) -> float:
	var zz: float = -absf(z)
	if x >= 0.0:
		var arm_z: float = -(RIVER_RADIUS + arm_offset(x))
		var slope: float = _arm_offset_slope(x)
		return absf(zz - arm_z) / sqrt(1.0 + slope * slope)
	return absf(sqrt(x * x + zz * zz) - RIVER_RADIUS)


## Distance along the channel from the west vertex of the curve (centre of the ford).
static func ford_arc_distance(x: float, z: float) -> float:
	if x >= 0.0:
		return RIVER_RADIUS * PI * 0.5 + x
	var phi: float = atan2(-x, absf(z))
	return RIVER_RADIUS * (PI * 0.5 - phi)


## 1 at the centre of the ford, 0 outside it.
static func ford_factor(x: float, z: float) -> float:
	return 1.0 - smoothstep(FORD_PLATEAU, FORD_HALF_LENGTH, ford_arc_distance(x, z))


## Channel axis as a polyline (from the north arm, through the west curve, to the south arm), every
## [param step] metres. Used for the water mesh and the bank blockers.
static func river_polyline(step: float = 2.0) -> PackedVector2Array:
	var north: PackedVector2Array = PackedVector2Array()
	var x: float = 262.0
	while x > 0.0:
		north.append(Vector2(x, -(RIVER_RADIUS + arm_offset(x))))
		x -= step
	var arc_steps: int = int(ceil(RIVER_RADIUS * PI * 0.5 / step))
	for i: int in arc_steps + 1:
		var phi: float = (PI * 0.5) * float(i) / float(arc_steps)
		north.append(Vector2(-RIVER_RADIUS * sin(phi), -RIVER_RADIUS * cos(phi)))
	var full: PackedVector2Array = north.duplicate()
	for i: int in range(north.size() - 2, -1, -1):
		full.append(Vector2(north[i].x, -north[i].y))
	return full


# --- Roads -----------------------------------------------------------------------------------

## Roads of the north half as polylines (mirrored for the south). The village
## cross road runs along the axis.
static func road_polylines() -> Array[PackedVector2Array]:
	var roads: Array[PackedVector2Array] = []
	# Wolf Gate (Puerta del Lobo) -> north bridge -> around the fort's northwest corner -> fort gate.
	roads.append(PackedVector2Array([
		Vector2(0, -150), Vector2(0, -116), Vector2(0, -76), Vector2(0, -48),
		Vector2(-12, -35), Vector2(-26, -26), Vector2(-29, -10), Vector2(-24, 0),
	]))
	# Branch to the ford: leaves the camp, crosses the northwest plain and descends to the west bank.
	roads.append(PackedVector2Array([
		Vector2(0, -116), Vector2(-36, -100), Vector2(-70, -74), Vector2(-92, -40),
		Vector2(-90, -10), Vector2(-82, 0),
	]))
	# Cross road: the old village street, crosses the ford and climbs to the gate.
	roads.append(PackedVector2Array([
		Vector2(VILLAGE_ROAD_END_X, 0), Vector2(-112, 0), Vector2(-82, 0), Vector2(-62, 0), Vector2(-24, 0),
	]))
	return roads


## Distance to the nearest road (with the south mirror).
static func road_distance(x: float, z: float) -> float:
	var p: Vector2 = Vector2(x, -absf(z))
	var best: float = INF
	for road: PackedVector2Array in road_polylines():
		for i: int in road.size() - 1:
			var q: Vector2 = Geometry2D.get_closest_point_to_segment(p, road[i], road[i + 1])
			best = minf(best, p.distance_to(q))
	return best


# --- Heights ---------------------------------------------------------------------------------

## Noise symmetrised about z = 0 (smooth on the axis).
func _sym_noise(noise: FastNoiseLite, x: float, z: float) -> float:
	return 0.5 * (noise.get_noise_2d(x, z) + noise.get_noise_2d(x, -z))


## Signed distance to the rounded palisade (negative inside).
static func fort_sdf(x: float, z: float) -> float:
	var q: Vector2 = Vector2(absf(x - FORT_CENTER.x), absf(z - FORT_CENTER.y)) - Vector2(FORT_HALF - 5.0, FORT_HALF - 5.0)
	return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - 5.0


static func camp_distance(x: float, z: float) -> float:
	return Vector2(x, -absf(z)).distance_to(CAMP_CENTER_NORTH)


## Terrain height (m) at (x, z). Deterministic.
func height(x: float, z: float) -> float:
	var ax: float = absf(x)
	var az: float = absf(z)

	# Valley floor: rises gently towards the walls and towards the flanks.
	var h: float = 4.3
	h += (CAMP_GROUND - 4.3) * smoothstep(62.0, 140.0, az)
	h += 3.2 * smoothstep(105.0, 152.0, ax)
	var play_mask: float = 1.0 - smoothstep(PLAY_HALF - 10.0, PLAY_HALF + 30.0, maxf(ax, az))
	var undulation: float = _sym_noise(_noise_small, x, z) * 0.9 + _sym_noise(_noise_large, x, z) * 1.6
	var asym: float = _noise_small.get_noise_2d(x, z) * 0.9 + _noise_large.get_noise_2d(x, z) * 1.6
	h += lerpf(asym, undulation, play_mask)

	# Fort hill: flat plateau and gentle slopes.
	var fort_d: float = fort_sdf(x, z)
	h = lerpf(FORT_GROUND + _sym_noise(_noise_small, x, z) * 0.15, h, smoothstep(4.0, 26.0, fort_d))

	# Camps and foot of the walls, flat.
	h = lerpf(h, CAMP_GROUND, 1.0 - smoothstep(CAMP_RADIUS - 6.0, CAMP_RADIUS + 6.0, camp_distance(x, z)))
	var wall_band: float = (1.0 - smoothstep(6.0, 14.0, absf(az - WALL_Z))) * (1.0 - smoothstep(150.0, 168.0, ax))
	h = lerpf(h, CAMP_GROUND, wall_band)

	# Edge mountains (outside the playable area).
	h += _mountains(x, z)

	# Channel: gentle banks down to the water, sunken bed except at the ford.
	var d: float = river_distance(x, z)
	if d < 22.0:
		var ford: float = ford_factor(x, z)
		var profile: float
		if d >= 11.0:
			profile = BANK_LEVEL
		elif d >= WATER_HALF_WIDTH:
			profile = WATER_LEVEL - 0.1 + (d - WATER_HALF_WIDTH) / (11.0 - WATER_HALF_WIDTH) * (BANK_LEVEL - WATER_LEVEL + 0.1)
		else:
			profile = WATER_LEVEL - 0.1 - (RIVER_DEPTH - 0.1) * smoothstep(WATER_HALF_WIDTH, 3.0, d)
		var ford_profile: float
		if d < 9.0:
			ford_profile = WATER_LEVEL - FORD_DEPTH
		else:
			ford_profile = lerpf(WATER_LEVEL - FORD_DEPTH, BANK_LEVEL, smoothstep(9.0, 17.0, d))
		profile = lerpf(profile, ford_profile, ford)
		var reach: float = lerpf(18.0, 21.0, ford)
		h = lerpf(profile, h, smoothstep(lerpf(11.0, 17.0, ford), reach, d))
	return h


func _mountains(x: float, z: float) -> float:
	var ridge: float = clampf(_noise_ridge.get_noise_2d(x, z) * 0.5 + 0.5, 0.0, 1.0)
	var rolling: float = _noise_large.get_noise_2d(x * 1.7, z * 1.7) * 0.5 + 0.5
	# Side mountains: they start 15 m inside the playable area, so before the invisible
	# wall (x = ±150) the slope already exceeds 40° and the edge reads as the foot of the mountain,
	# not as a wall in the middle of the meadow. Inside the playable area the relief is symmetric in z.
	var ax: float = absf(x)
	var ridge_sym: float = clampf(_sym_noise(_noise_ridge, x, z) * 0.5 + 0.5, 0.0, 1.0)
	var ridge_side: float = lerpf(ridge_sym, ridge, smoothstep(PLAY_HALF, PLAY_HALF + 25.0, ax))
	var side: float = smoothstep(-15.0, 40.0, ax - PLAY_HALF) * (30.0 + 26.0 * ridge_side)
	# Pass behind each gate: the road continues towards the realm between two hills.
	var notch: float = 1.0 - 0.8 * exp(-pow(x / 34.0, 2.0))
	var north: float = smoothstep(0.0, 80.0, -z - 162.0) * (50.0 + 30.0 * ridge) * notch
	var south: float = smoothstep(0.0, 78.0, z - 162.0) * (18.0 + 14.0 * rolling) * notch
	var m: float = maxf(side, maxf(north, south))
	# Fine relief on the slopes (gullies and outcrops), so that they do not read as smooth clay.
	# Inside the playable area, symmetric in z like the rest.
	var detail_noise: float = lerpf(_sym_noise(_noise_small, x * 2.6, z * 2.6), _noise_small.get_noise_2d(x * 2.6, z * 2.6),
			smoothstep(PLAY_HALF, PLAY_HALF + 25.0, ax))
	m += detail_noise * 5.0 * smoothstep(4.0, 30.0, m)
	# The river exits to the east between two hills: a ravine opens up.
	var d: float = river_distance(x, z)
	m *= smoothstep(9.0, 46.0, d)
	# Near the edge of the map the peaks drop a little so as not to show the cut-off of the terrain.
	var edge: float = maxf(absf(x), absf(z))
	m *= 1.0 - 0.3 * smoothstep(236.0, 256.0, edge)
	return m


## Noise to vary the terrain paint (does not affect gameplay).
func paint_noise(x: float, z: float) -> float:
	return _noise_paint.get_noise_2d(x, z)
