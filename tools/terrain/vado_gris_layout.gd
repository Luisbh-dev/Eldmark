extends RefCounted
## Trazado del Vado Gris: posiciones clave, el río, las calzadas y la función de alturas.
##
## Es la única fuente de verdad que comparten el generador del terreno y el montaje de la escena
## (tools/terrain/generate_vado_gris.gd). Coordenadas en metros con el origen en el centro del
## fuerte; el norte es -Z. Vardheim (Muro de Escarcha) está al norte y Solmarch (Muralla del
## Alba) al sur. Diseño y justificación en docs/zonas/vado_gris.md.
##
## Equidad: todo lo jugable es simétrico respecto al eje z = 0 (espejo norte-sur). La función de
## alturas usa ruido simetrizado (n(x, z) + n(x, -z)) dentro del área jugable y el río, las
## calzadas, los campamentos y las ruinas se definen en la mitad norte y se reflejan.

# --- Terreno ---------------------------------------------------------------------------------

## Esquina del mapa de alturas: 512 x 512 px a 1 m, en 2 x 2 regiones de 256 m.
const MAP_ORIGIN: Vector3 = Vector3(-256.0, 0.0, -256.0)
const MAP_SIZE: int = 512
const REGION_SIZE: int = 256
## Medio lado del área jugable (300 x 300 m).
const PLAY_HALF: float = 150.0

# --- Murallas, puertas y campamentos ----------------------------------------------------------

## Distancia del centro a la cara interior de cada muralla.
const WALL_Z: float = 152.0
## Altura del suelo junto a las murallas (campamentos y pie del muro).
const CAMP_GROUND: float = 6.2
## Centro de cada campamento (en la mitad norte; el sur es el reflejo).
const CAMP_CENTER_NORTH: Vector2 = Vector2(0.0, -128.0)
const CAMP_RADIUS: float = 24.0
## La muralla se extiende hasta aquí a cada lado y se hunde en las montañas.
const WALL_HALF_LENGTH: float = 180.0

# --- Fuerte ----------------------------------------------------------------------------------

const FORT_CENTER: Vector2 = Vector2.ZERO
## Medio lado de la empalizada (unos 40 m de lado).
const FORT_HALF: float = 20.0
## Altura de la meseta de la colina.
const FORT_GROUND: float = 10.2
## Puerta del fuerte: en la cara oeste, mirando al vado (sobre el eje de simetría).
const FORT_GATE: Vector2 = Vector2(-20.0, 0.0)
const FORT_GATE_WIDTH: float = 4.0

# --- Río -------------------------------------------------------------------------------------

## El río rodea la colina en herradura abierta al este: brazo norte en z = -RIVER_RADIUS, curva
## alrededor del oeste y brazo sur en z = +RIVER_RADIUS. Ambos reinos lo cruzan para llegar.
const RIVER_RADIUS: float = 62.0
const WATER_LEVEL: float = 3.0
const BANK_LEVEL: float = 4.0
## Distancia al eje del cauce donde el lecho corta la superficie del agua (orilla visible).
const WATER_HALF_WIDTH: float = 7.0
## Profundidad del lecho bajo el agua fuera del vado.
const RIVER_DEPTH: float = 1.6
## Vado: tramo de la curva oeste (medido a lo largo del cauce desde el vértice) con lecho somero.
const FORD_HALF_LENGTH: float = 17.0
## Medio tramo del vado con el lecho somero completo (de aquí a FORD_HALF_LENGTH el lecho baja
## hasta el cauce profundo, donde vuelven las orillas y el cierre del cauce).
const FORD_PLATEAU: float = 14.0
const FORD_DEPTH: float = 0.32
## Puentes de piedra: uno en cada brazo, sobre la línea directa puerta-fuerte (x = 0).
const BRIDGE_X: float = 0.0
const BRIDGE_LENGTH: float = 24.0
const BRIDGE_WIDTH: float = 4.0

# --- Ruinas ----------------------------------------------------------------------------------

## Aldea del viejo Eld en la orilla oeste, a ambos lados de la calzada que llega al vado.
const VILLAGE_CENTER: Vector2 = Vector2(-104.0, 0.0)
## Donde acaba la vieja calle de la aldea (dos pilares y escombros), antes de que las montañas
## del oeste cierren el área jugable.
const VILLAGE_ROAD_END_X: float = -136.0
## Capilla en ruinas en la península, al este del fuerte.
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


# --- Río -------------------------------------------------------------------------------------

## Meandro suave del brazo norte (en x >= 0), nulo junto al puente para que el cruce sea recto.
static func arm_offset(x: float) -> float:
	return 7.0 * sin(x * 0.034 + 0.9) * smoothstep(18.0, 70.0, x)


static func _arm_offset_slope(x: float) -> float:
	var e: float = 0.5
	return (arm_offset(x + e) - arm_offset(x - e)) / (2.0 * e)


## Distancia (m) al eje del cauce. Analítica: brazo con meandro para x >= 0 y arco de radio
## RIVER_RADIUS alrededor del fuerte para x < 0. Simétrica en z.
static func river_distance(x: float, z: float) -> float:
	var zz: float = -absf(z)
	if x >= 0.0:
		var arm_z: float = -(RIVER_RADIUS + arm_offset(x))
		var slope: float = _arm_offset_slope(x)
		return absf(zz - arm_z) / sqrt(1.0 + slope * slope)
	return absf(sqrt(x * x + zz * zz) - RIVER_RADIUS)


## Distancia a lo largo del cauce desde el vértice oeste de la curva (centro del vado).
static func ford_arc_distance(x: float, z: float) -> float:
	if x >= 0.0:
		return RIVER_RADIUS * PI * 0.5 + x
	var phi: float = atan2(-x, absf(z))
	return RIVER_RADIUS * (PI * 0.5 - phi)


## 1 en el centro del vado, 0 fuera de él.
static func ford_factor(x: float, z: float) -> float:
	return 1.0 - smoothstep(FORD_PLATEAU, FORD_HALF_LENGTH, ford_arc_distance(x, z))


## Eje del cauce como polilínea (del brazo norte, por la curva oeste, al brazo sur), cada
## [param step] metros. Sirve para la malla del agua y los bloqueos de las orillas.
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


# --- Calzadas --------------------------------------------------------------------------------

## Calzadas de la mitad norte como polilíneas (se reflejan para el sur). La transversal de la
## aldea va sobre el eje.
static func road_polylines() -> Array[PackedVector2Array]:
	var roads: Array[PackedVector2Array] = []
	# Puerta del Lobo -> puente norte -> rodea la esquina noroeste del fuerte -> puerta del fuerte.
	roads.append(PackedVector2Array([
		Vector2(0, -150), Vector2(0, -116), Vector2(0, -76), Vector2(0, -48),
		Vector2(-12, -35), Vector2(-26, -26), Vector2(-29, -10), Vector2(-24, 0),
	]))
	# Ramal al vado: sale del campamento, cruza la llanura noroeste y baja a la orilla oeste.
	roads.append(PackedVector2Array([
		Vector2(0, -116), Vector2(-36, -100), Vector2(-70, -74), Vector2(-92, -40),
		Vector2(-90, -10), Vector2(-82, 0),
	]))
	# Calzada transversal: la vieja calle de la aldea, cruza el vado y sube a la puerta.
	roads.append(PackedVector2Array([
		Vector2(VILLAGE_ROAD_END_X, 0), Vector2(-112, 0), Vector2(-82, 0), Vector2(-62, 0), Vector2(-24, 0),
	]))
	return roads


## Distancia a la calzada más cercana (con el reflejo sur).
static func road_distance(x: float, z: float) -> float:
	var p: Vector2 = Vector2(x, -absf(z))
	var best: float = INF
	for road: PackedVector2Array in road_polylines():
		for i: int in road.size() - 1:
			var q: Vector2 = Geometry2D.get_closest_point_to_segment(p, road[i], road[i + 1])
			best = minf(best, p.distance_to(q))
	return best


# --- Alturas ---------------------------------------------------------------------------------

## Ruido simetrizado respecto a z = 0 (liso en el eje).
func _sym_noise(noise: FastNoiseLite, x: float, z: float) -> float:
	return 0.5 * (noise.get_noise_2d(x, z) + noise.get_noise_2d(x, -z))


## Distancia con signo a la empalizada redondeada (negativa dentro).
static func fort_sdf(x: float, z: float) -> float:
	var q: Vector2 = Vector2(absf(x - FORT_CENTER.x), absf(z - FORT_CENTER.y)) - Vector2(FORT_HALF - 5.0, FORT_HALF - 5.0)
	return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - 5.0


static func camp_distance(x: float, z: float) -> float:
	return Vector2(x, -absf(z)).distance_to(CAMP_CENTER_NORTH)


## Altura del terreno (m) en (x, z). Determinista.
func height(x: float, z: float) -> float:
	var ax: float = absf(x)
	var az: float = absf(z)

	# Fondo del valle: sube suave hacia las murallas y hacia los flancos.
	var h: float = 4.3
	h += (CAMP_GROUND - 4.3) * smoothstep(62.0, 140.0, az)
	h += 3.2 * smoothstep(105.0, 152.0, ax)
	var play_mask: float = 1.0 - smoothstep(PLAY_HALF - 10.0, PLAY_HALF + 30.0, maxf(ax, az))
	var undulation: float = _sym_noise(_noise_small, x, z) * 0.9 + _sym_noise(_noise_large, x, z) * 1.6
	var asym: float = _noise_small.get_noise_2d(x, z) * 0.9 + _noise_large.get_noise_2d(x, z) * 1.6
	h += lerpf(asym, undulation, play_mask)

	# Colina del fuerte: meseta plana y laderas suaves.
	var fort_d: float = fort_sdf(x, z)
	h = lerpf(FORT_GROUND + _sym_noise(_noise_small, x, z) * 0.15, h, smoothstep(4.0, 26.0, fort_d))

	# Campamentos y pie de las murallas, llanos.
	h = lerpf(h, CAMP_GROUND, 1.0 - smoothstep(CAMP_RADIUS - 6.0, CAMP_RADIUS + 6.0, camp_distance(x, z)))
	var wall_band: float = (1.0 - smoothstep(6.0, 14.0, absf(az - WALL_Z))) * (1.0 - smoothstep(150.0, 168.0, ax))
	h = lerpf(h, CAMP_GROUND, wall_band)

	# Montañas del borde (fuera del área jugable).
	h += _mountains(x, z)

	# Cauce: orillas suaves hasta el agua, lecho hundido salvo en el vado.
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
	# Montañas de los lados: empiezan 15 m dentro del área jugable, así que antes de la pared
	# invisible (x = ±150) la ladera ya pasa de 40° y el borde se lee como el pie de la montaña,
	# no como una pared en mitad del prado. Dentro del área jugable el relieve es simétrico en z.
	var ax: float = absf(x)
	var ridge_sym: float = clampf(_sym_noise(_noise_ridge, x, z) * 0.5 + 0.5, 0.0, 1.0)
	var ridge_side: float = lerpf(ridge_sym, ridge, smoothstep(PLAY_HALF, PLAY_HALF + 25.0, ax))
	var side: float = smoothstep(-15.0, 40.0, ax - PLAY_HALF) * (30.0 + 26.0 * ridge_side)
	# Paso detrás de cada puerta: la calzada sigue hacia el reino entre dos lomas.
	var notch: float = 1.0 - 0.8 * exp(-pow(x / 34.0, 2.0))
	var north: float = smoothstep(0.0, 80.0, -z - 162.0) * (50.0 + 30.0 * ridge) * notch
	var south: float = smoothstep(0.0, 78.0, z - 162.0) * (18.0 + 14.0 * rolling) * notch
	var m: float = maxf(side, maxf(north, south))
	# Relieve fino en las laderas (cárcavas y resaltes), para que no se lean como arcilla lisa.
	# Dentro del área jugable, simétrico en z como el resto.
	var detail_noise: float = lerpf(_sym_noise(_noise_small, x * 2.6, z * 2.6), _noise_small.get_noise_2d(x * 2.6, z * 2.6),
			smoothstep(PLAY_HALF, PLAY_HALF + 25.0, ax))
	m += detail_noise * 5.0 * smoothstep(4.0, 30.0, m)
	# El río sale por el este entre dos lomas: se abre un barranco.
	var d: float = river_distance(x, z)
	m *= smoothstep(9.0, 46.0, d)
	# Cerca del borde del mapa las cumbres bajan un poco para no mostrar el corte del terreno.
	var edge: float = maxf(absf(x), absf(z))
	m *= 1.0 - 0.3 * smoothstep(236.0, 256.0, edge)
	return m


## Ruido para variar la pintura del terreno (no afecta a la jugabilidad).
func paint_noise(x: float, z: float) -> float:
	return _noise_paint.get_noise_2d(x, z)
