class_name ParchmentMapBaker
extends RefCounted
## Hornea el mapa de pergamino de una zona (UI-51, docs/calidad.md §2 «Mapa y minimapa»): un mapa
## dibujado a pluma y aguada sobre papel envejecido en lugar del volcado de la pintura del terreno
## ([ZoneMapBaker]). Lo usa [code]tools/map/bake_parchment_map.gd[/code]. Es CPU pura (sin GPU, sin
## renderizar la escena), determinista y vale en headless.
## [br][br]
## Se pinta por capas, de abajo arriba, con los datos reales de la zona:
## [br]1. [b]Papel[/b]: color base con manchas de tono, grano, fibras, manchas de humedad y calor.
## [br]2. [b]Aguada del suelo[/b]: el color de la textura pintada en el terreno ([code]get_texture_id[/code]),
## más gris y frío cuanto más alto.
## [br]3. [b]Relieve[/b]: alturas de [code]Terrain3D.data[/code]; lavado de tinta donde la ladera da la
## espalda a la luz (noroeste) y trazos de pluma (hachures) que bajan por la ladera.
## [br]4. [b]Río[/b]: la orilla sale de la altura del cauce contra el nivel del agua; aguada azul gris,
## orillas entintadas, líneas paralelas rotas y marcas de corriente.
## [br]5. [b]Caminos[/b] (doble trazo, del trazado del Vado Gris), [b]vado[/b] (piedras y postes de la
## escena) y [b]puentes[/b].
## [br]6. [b]Construcciones[/b]: murallas con almenas y torres, el fuerte (empalizada de la escena),
## campamentos con el color de su reino y ruinas.
## [br]7. [b]Símbolos[/b], de norte a sur para que los de delante tapen a los de detrás: árboles de las
## instancias del terreno, rocas y montañas dibujadas con su cara en sombra rayada y nieve en las cumbres.
## [br]8. [b]Adornos[/b]: rosa de los vientos, escala, marco con graduación y quemado de los bordes.
## [br][br]
## Nada de texto: los rótulos los pone la interfaz con sus fuentes. Las medidas están en metros y se
## pasan a píxeles con la escala de la [ZoneMapDefinition], así que sirve a cualquier resolución.

const Layout: GDScript = preload("res://tools/terrain/vado_gris_layout.gd")

# --- Paleta -------------------------------------------------------------------------------------

const PAPER: Color = Color(0.80, 0.70, 0.52)
## Tinta sepia con la que se dibuja todo el trazo.
const INK: Color = Color(0.15, 0.105, 0.075)
const INK_SOFT: Color = Color(0.32, 0.23, 0.15)
const SHADOW_WASH: Color = Color(0.58, 0.50, 0.42)
const WATER_SHALLOW: Color = Color(0.58, 0.72, 0.72)
const WATER_DEEP: Color = Color(0.36, 0.52, 0.61)
const WATER_LINE: Color = Color(0.22, 0.34, 0.44)
const SNOW: Color = Color(0.95, 0.94, 0.89)
const STONE_LIGHT: Color = Color(0.82, 0.78, 0.69)
const STONE_DARK: Color = Color(0.58, 0.54, 0.48)
const FOLIAGE_LIGHT: Color = Color(0.64, 0.70, 0.49)
const FOLIAGE_DARK: Color = Color(0.38, 0.46, 0.32)
const ROAD_SAND: Color = Color(0.92, 0.82, 0.60)
const WOOD: Color = Color(0.55, 0.40, 0.26)
## Color de cada reino sobre el mapa (código de red 1 a 3).
const REALM_COLORS: Dictionary = {
	1: Color(0.22, 0.47, 0.78),
	2: Color(0.93, 0.70, 0.10),
	3: Color(0.72, 0.17, 0.13),
}

## Multiplicador de la aguada del suelo por id de textura del Vado Gris (sobre el papel).
const GROUND_WASH: Dictionary[int, Color] = {
	0: Color(0.84, 0.94, 0.70),
	1: Color(0.96, 0.92, 0.66),
	2: Color(0.93, 0.80, 0.62),
	3: Color(0.93, 0.90, 0.83),
	4: Color(0.80, 0.78, 0.76),
	5: Color(0.74, 0.88, 0.62),
	6: Color(0.68, 0.67, 0.68),
}
const GROUND_WASH_UNKNOWN: Color = Color(0.88, 0.86, 0.78)
## Cuánto de cada aguada del suelo llega al papel (1 = todo; menos, más desaturado).
const WASH_STRENGTH: float = 0.60
## Cuánto se desatura el mapa entero al final (0 a 1).
const FINAL_DESATURATION: float = 0.10

## Dirección de la luz (noroeste y arriba; el norte es -Z).
const LIGHT: Vector3 = Vector3(-0.55, 0.70, -0.55)
## Exageración del relieve en el sombreado.
const RELIEF_EXAGGERATION: float = 3.2

# Alturas de referencia del Vado Gris (m).
const HILL_MIN_HEIGHT: float = 9.5
const FOREST_MAX_HEIGHT: float = 24.0
const SNOW_MIN_HEIGHT: float = 52.0

# --- Estado -------------------------------------------------------------------------------------

var _zone: Node3D = null
var _terrain: Terrain3D = null
var _def: ZoneMapDefinition = null
var _canvas: ParchmentCanvas = null
var _width: int = 0
var _height: int = 0
## Píxeles por metro.
var _ppm: float = 4.0
## Altura del terreno en cada píxel (m).
var _heights: PackedFloat32Array = PackedFloat32Array()
## Pendiente en x y en z (m por m) en cada píxel.
var _grad_x: PackedFloat32Array = PackedFloat32Array()
var _grad_z: PackedFloat32Array = PackedFloat32Array()
## Oscuridad de la ladera (0 a 1) respecto a la luz.
var _dark: PackedFloat32Array = PackedFloat32Array()
## Cobertura del agua (0 a 1) y distancia con signo a la orilla (px; positiva dentro del agua).
var _water: PackedFloat32Array = PackedFloat32Array()
var _shore: PackedFloat32Array = PackedFloat32Array()
var _noise_a: FastNoiseLite = null
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
## Símbolos pendientes de dibujar (árboles, montañas, tiendas, enseñas...), de norte a sur al pintarlos.
var _sprites: Array[Dictionary] = []
var _clock: int = 0


## Hornea el mapa de [param zone] (en el árbol) con las medidas de [param definition]. Devuelve null si
## la zona no tiene un [Terrain3D] con datos.
static func bake(zone: Node3D, definition: ZoneMapDefinition) -> Image:
	var baker := ParchmentMapBaker.new()
	return baker._run(zone, definition)


func _run(zone: Node3D, definition: ZoneMapDefinition) -> Image:
	_zone = zone
	_def = definition
	_terrain = zone.get_node_or_null(^"Terrain3D") as Terrain3D
	if _terrain == null or _terrain.data == null:
		return null
	_width = definition.image_size.x
	_height = definition.image_size.y
	_ppm = definition.pixels_per_meter().x
	_canvas = ParchmentCanvas.new(_width, _height)
	_noise_a = FastNoiseLite.new()
	_noise_a.seed = 4242
	_noise_a.frequency = 0.05
	_clock = Time.get_ticks_msec()
	_step("papel")
	_paint_paper()
	_step("alturas")
	_sample_heights()
	_step("aguada del suelo")
	_paint_ground_wash()
	_step("relieve")
	_paint_relief_wash()
	_paint_hachures()
	_step("río")
	_paint_water()
	_step("caminos y matas")
	_paint_roads()
	_paint_ground_marks()
	_step("vado y puentes")
	_paint_ford()
	_paint_bridges()
	_step("construcciones")
	_paint_walls()
	_paint_ruins()
	_paint_camps_ground()
	_paint_fort_ground()
	_step("símbolos")
	_paint_symbols()
	_step("adornos")
	_paint_compass_rose()
	_paint_scale_bar()
	_paint_frame()
	_age_edges()
	_step("fin")
	return _canvas.to_image()


func _step(name: String) -> void:
	var now: int = Time.get_ticks_msec()
	print("  [%6.1f s] %s" % [(now - _clock) / 1000.0, name])


# --- Utilidades ---------------------------------------------------------------------------------

## Posición en la imagen (px) de un punto del mundo (x, z).
func _px(x: float, z: float) -> Vector2:
	return _def.world_to_pixel(Vector3(x, 0.0, z))


## Metros a píxeles.
func _m(meters: float) -> float:
	return meters * _ppm


## Ancho de línea en píxeles: nunca menos de [param minimum] para que el trazo no desaparezca.
func _line(meters: float, minimum: float = 0.9) -> float:
	return maxf(meters * _ppm, minimum)


## Factor que mantiene el tamaño en metros de las frecuencias de ruido que se dieron para 4 px/m.
func _fk() -> float:
	return 4.0 / _ppm


func _byte01(bytes: PackedByteArray, index: int) -> float:
	return float(bytes[index]) * 0.003921569


static func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t: float = clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Pinta [param polygons] con el modo y color dados (atajo de rasterizar y pintar).
func _fill(polygons: Array[PackedVector2Array], mode: int, color: Color, alpha: float = 1.0,
		grain_strength: float = 0.5, wear_strength: float = 0.0) -> void:
	_canvas.paint(ParchmentCanvas.rasterize(polygons), mode, color, alpha, grain_strength, wear_strength)


## Una línea de tinta que sigue [param points] (píxeles), de [param width] px.
func _ink_line(points: PackedVector2Array, width: float, alpha: float = 0.85, color: Color = INK,
		mode: int = ParchmentCanvas.MODE_MULTIPLY, wear: float = 0.6, closed: bool = false) -> void:
	var widths := PackedFloat32Array([width])
	for mask: ParchmentCanvas.Mask in ParchmentCanvas.stroke_masks(points, widths, closed):
		_canvas.paint(mask, mode, color, alpha, 0.5, wear)


## Una línea con el ancho que va de [param w0] a [param w1] a lo largo de la polilínea (ahusada).
func _ink_taper(points: PackedVector2Array, w0: float, w1: float, alpha: float = 0.85,
		color: Color = INK, wear: float = 0.6) -> void:
	var widths := PackedFloat32Array()
	var count: int = points.size()
	for i: int in count:
		widths.append(lerpf(w0, w1, float(i) / float(maxi(count - 1, 1))))
	for mask: ParchmentCanvas.Mask in ParchmentCanvas.stroke_masks(points, widths):
		_canvas.paint(mask, ParchmentCanvas.MODE_MULTIPLY, color, alpha, 0.5, wear)


## Bilinear: pinta un punto de tinta de [param a] en (x, y) sin máscara (para trazos finísimos y muchos).
func _splat(x: float, y: float, a: float, color: Color) -> void:
	var ix: int = floori(x)
	var iy: int = floori(y)
	if ix < 0 or iy < 0 or ix >= _width - 1 or iy >= _height - 1:
		return
	var fx: float = x - float(ix)
	var fy: float = y - float(iy)
	var i0: int = iy * _width + ix
	var weights: Array[float] = [(1.0 - fx) * (1.0 - fy), fx * (1.0 - fy), (1.0 - fx) * fy, fx * fy]
	var offsets: Array[int] = [i0, i0 + 1, i0 + _width, i0 + _width + 1]
	for k: int in 4:
		var i: int = offsets[k]
		var amount: float = a * weights[k] * (1.0 - 0.7 * _canvas.wear[i])
		_canvas.r[i] *= 1.0 + (color.r - 1.0) * amount
		_canvas.g[i] *= 1.0 + (color.g - 1.0) * amount
		_canvas.b[i] *= 1.0 + (color.b - 1.0) * amount


# --- 1. Papel -----------------------------------------------------------------------------------

func _paint_paper() -> void:
	var count: int = _width * _height
	var fk: float = _fk()
	var low: PackedByteArray = ParchmentCanvas.noise_bytes(101, 0.0030 * fk, 4, _width, _height)
	var mid: PackedByteArray = ParchmentCanvas.noise_bytes(102, 0.0140 * fk, 3, _width, _height)
	var fine: PackedByteArray = ParchmentCanvas.noise_bytes(103, 0.42, 2, _width, _height)
	var mottle: PackedByteArray = ParchmentCanvas.noise_bytes(104, 0.11, 3, _width, _height)
	var worn: PackedByteArray = ParchmentCanvas.noise_bytes(105, 0.30, 2, _width, _height)
	for i: int in count:
		var lo: float = _byte01(low, i) - 0.5
		var mi: float = _byte01(mid, i) - 0.5
		var fi: float = _byte01(fine, i) - 0.5
		var mo: float = _byte01(mottle, i) - 0.5
		var lum: float = 1.0 + lo * 0.30 + mi * 0.11 + fi * 0.10 + mo * 0.06
		var warm: float = lo * 0.16
		_canvas.r[i] = clampf(PAPER.r * lum + warm * 0.55, 0.0, 1.0)
		_canvas.g[i] = clampf(PAPER.g * lum + warm * 0.05, 0.0, 1.0)
		_canvas.b[i] = clampf(PAPER.b * lum - warm * 0.55, 0.0, 1.0)
		_canvas.grain[i] = 1.0 + fi * 0.16 + mo * 0.08
		_canvas.wear[i] = clampf((_byte01(worn, i) - 0.60) * 3.2, 0.0, 1.0)
	_rng.seed = 7001
	var area_factor: float = float(count) / 4194304.0
	# Fibras: hebras cortas y curvas, oscuras y claras.
	for k: int in int(7000.0 * area_factor):
		var start := Vector2(_rng.randf() * _width, _rng.randf() * _height)
		var heading: float = _rng.randf() * TAU
		var points := PackedVector2Array([start])
		var steps: int = _rng.randi_range(3, 6)
		var length: float = _rng.randf_range(10.0, 46.0) * _ppm * 0.25
		var cursor: Vector2 = start
		for s: int in steps:
			heading += _rng.randf_range(-0.7, 0.7)
			cursor += Vector2(cos(heading), sin(heading)) * (length / float(steps))
			points.append(cursor)
		var smooth: PackedVector2Array = ParchmentCanvas.smooth(points, 4)
		var dark_fiber: bool = _rng.randf() < 0.6
		var color: Color = Color(0.70, 0.58, 0.42) if dark_fiber else Color(0.96, 0.90, 0.74)
		var mode: int = ParchmentCanvas.MODE_MULTIPLY if dark_fiber else ParchmentCanvas.MODE_OVER
		var alpha: float = _rng.randf_range(0.10, 0.30) if dark_fiber else _rng.randf_range(0.08, 0.22)
		for mask: ParchmentCanvas.Mask in ParchmentCanvas.stroke_masks(smooth,
				PackedFloat32Array([_rng.randf_range(0.5, 0.95)]), false, false):
			_canvas.paint(mask, mode, color, alpha, 0.0)
	# Manchas de humedad con borde más oscuro y quemaduras de tono.
	for k: int in 46:
		var center := Vector2(_rng.randf_range(0.05, 0.95) * _width, _rng.randf_range(0.05, 0.95) * _height)
		var radius: float = _rng.randf_range(0.012, 0.075) * _width
		var seed_offset: float = _rng.randf() * 1000.0
		var tone: Color = Color(0.78, 0.60, 0.38) if _rng.randf() < 0.75 else Color(0.62, 0.52, 0.36)
		var strength: float = _rng.randf_range(0.5, 1.0)
		for ring: int in 6:
			var shrink: float = 1.0 - 0.13 * float(ring)
			var polygon := PackedVector2Array()
			for v: int in 30:
				var angle: float = TAU * float(v) / 30.0
				var wob: float = 1.0 + 0.22 * _noise_a.get_noise_2d(cos(angle) * 9.0 + seed_offset, sin(angle) * 9.0)
				polygon.append(center + Vector2(cos(angle), sin(angle)) * radius * shrink * wob)
			var polygons: Array[PackedVector2Array] = [polygon]
			_canvas.paint(ParchmentCanvas.rasterize(polygons), ParchmentCanvas.MODE_MULTIPLY, tone, 0.050 * strength, 0.0)
			if ring == 0:
				var rim: PackedVector2Array = polygon.duplicate()
				for mask: ParchmentCanvas.Mask in ParchmentCanvas.stroke_masks(rim, PackedFloat32Array([_m(0.7)]), true):
					_canvas.paint(mask, ParchmentCanvas.MODE_MULTIPLY, Color(0.66, 0.50, 0.30), 0.16 * strength, 0.0)
	# Pecas: puntitos de óxido.
	for k: int in int(900.0 * area_factor):
		var at := Vector2(_rng.randf() * _width, _rng.randf() * _height)
		var polygons: Array[PackedVector2Array] = [ParchmentCanvas.circle(at, _rng.randf_range(0.5, 1.8), 8)]
		_canvas.paint(ParchmentCanvas.rasterize(polygons), ParchmentCanvas.MODE_MULTIPLY,
				Color(0.55, 0.38, 0.22), _rng.randf_range(0.25, 0.6), 0.0)


# --- 2. Alturas y aguada del suelo --------------------------------------------------------------

func _sample_heights() -> void:
	var cells: int = roundi(_def.world_size.x)
	var cell_size: Vector2 = _def.world_size / float(cells)
	var grid := PackedFloat32Array()
	grid.resize(cells * cells)
	var lowest: float = INF
	var missing: Array[int] = []
	var margin: float = 0.01
	for j: int in cells:
		for i: int in cells:
			var x: float = _def.world_origin.x + (float(i) + 0.5) * cell_size.x
			var z: float = _def.world_origin.y + (float(j) + 0.5) * cell_size.y
			var value: float = _terrain.data.get_height(Vector3(x, 0.0, z))
			if is_nan(value):
				missing.append(j * cells + i)
				value = 0.0
			else:
				lowest = minf(lowest, value)
			grid[j * cells + i] = value
	for index: int in missing:
		grid[index] = lowest if is_finite(lowest) else 0.0
	var image: Image = Image.create_from_data(cells, cells, false, Image.FORMAT_RF, grid.to_byte_array())
	image.resize(_width, _height, Image.INTERPOLATE_CUBIC)
	_heights = image.get_data().to_float32_array()
	_grad_x.resize(_width * _height)
	_grad_z.resize(_width * _height)
	_dark.resize(_width * _height)
	var inv_step: float = _ppm * 0.5
	var light: Vector3 = LIGHT.normalized()
	for y: int in _height:
		var row: int = y * _width
		var up_row: int = maxi(y - 1, 0) * _width
		var down_row: int = mini(y + 1, _height - 1) * _width
		for x: int in _width:
			var gx: float = (_heights[row + mini(x + 1, _width - 1)] - _heights[row + maxi(x - 1, 0)]) * inv_step
			var gz: float = (_heights[down_row + x] - _heights[up_row + x]) * inv_step
			_grad_x[row + x] = gx
			_grad_z[row + x] = gz
			var normal := Vector3(-gx * RELIEF_EXAGGERATION, 1.0, -gz * RELIEF_EXAGGERATION).normalized()
			_dark[row + x] = clampf((light.y - normal.dot(light)) / light.y, 0.0, 1.0)


## Aguada del suelo: el color de la textura pintada en el terreno, un poco de gris con la altura y un
## toque frío al norte y cálido al sur.
func _paint_ground_wash() -> void:
	var cells: int = roundi(_def.world_size.x)
	var cell_size: Vector2 = _def.world_size / float(cells)
	var colors := PackedFloat32Array()
	colors.resize(cells * cells * 3)
	for j: int in cells:
		for i: int in cells:
			var world := Vector3(_def.world_origin.x + (float(i) + 0.5) * cell_size.x, 0.0,
					_def.world_origin.y + (float(j) + 0.5) * cell_size.y)
			var ids: Vector3 = _terrain.data.get_texture_id(world)
			var base: Color = GROUND_WASH.get(roundi(ids.x), GROUND_WASH_UNKNOWN)
			var over: Color = GROUND_WASH.get(roundi(ids.y), GROUND_WASH_UNKNOWN)
			var mixed: Color = base.lerp(over, clampf(ids.z, 0.0, 1.0))
			var k: int = (j * cells + i) * 3
			colors[k] = mixed.r
			colors[k + 1] = mixed.g
			colors[k + 2] = mixed.b
	var image: Image = Image.create_from_data(cells, cells, false, Image.FORMAT_RGBF, colors.to_byte_array())
	image.resize(_width, _height, Image.INTERPOLATE_CUBIC)
	var wash: PackedFloat32Array = image.get_data().to_float32_array()
	var fk: float = _fk()
	var blotch: PackedByteArray = ParchmentCanvas.noise_bytes(201, 0.011 * fk, 3, _width, _height)
	var bloom: PackedByteArray = ParchmentCanvas.noise_bytes(202, 0.045 * fk, 2, _width, _height)
	var cool: Color = Color(0.93, 0.96, 1.02)
	var warm: Color = Color(1.04, 1.0, 0.93)
	for y: int in _height:
		var row: int = y * _width
		# Mitad norte (Vardheim) más fría, mitad sur (Solmarch) más cálida, muy sutil.
		var z_world: float = _def.world_origin.y + (float(y) + 0.5) / _ppm
		var realm_t: float = _smoothstep(-90.0, 90.0, z_world)
		var tint: Color = cool.lerp(warm, realm_t)
		for x: int in _width:
			var i: int = row + x
			var k: int = i * 3
			var alpha: float = 0.62 + 0.38 * _byte01(blotch, i) + 0.18 * (_byte01(bloom, i) - 0.5)
			var h: float = _heights[i]
			var rock: float = _smoothstep(16.0, 44.0, h)
			var mr: float = lerpf(lerpf(1.0, wash[k], WASH_STRENGTH), 0.82, rock) * lerpf(1.0, tint.r, 0.45)
			var mg: float = lerpf(lerpf(1.0, wash[k + 1], WASH_STRENGTH), 0.81, rock) * lerpf(1.0, tint.g, 0.45)
			var mb: float = lerpf(lerpf(1.0, wash[k + 2], WASH_STRENGTH), 0.80, rock) * lerpf(1.0, tint.b, 0.45)
			# Borde más oscuro donde cambia el color (la aguada se acumula en el límite).
			var edge: float = 0.0
			if x + 1 < _width and y + 1 < _height:
				edge = absf(wash[k] - wash[k + 3]) + absf(wash[k + 1] - wash[k + 4]) \
						+ absf(wash[k] - wash[k + _width * 3]) + absf(wash[k + 2] - wash[k + _width * 3 + 2])
			var pool: float = 1.0 - clampf(edge * 1.1, 0.0, 0.07)
			_canvas.r[i] *= (1.0 + (mr - 1.0) * alpha) * pool
			_canvas.g[i] *= (1.0 + (mg - 1.0) * alpha) * pool
			_canvas.b[i] *= (1.0 + (mb - 1.0) * alpha) * pool


# --- 3. Relieve ---------------------------------------------------------------------------------

func _paint_relief_wash() -> void:
	var fk: float = _fk()
	var texture: PackedByteArray = ParchmentCanvas.noise_bytes(301, 0.020 * fk, 3, _width, _height)
	for i: int in _width * _height:
		var dark: float = _dark[i]
		if dark < 0.02:
			continue
		var a: float = clampf(dark * 0.95, 0.0, 0.62) * (0.65 + 0.35 * _byte01(texture, i))
		_canvas.r[i] *= 1.0 + (SHADOW_WASH.r - 1.0) * a
		_canvas.g[i] *= 1.0 + (SHADOW_WASH.g - 1.0) * a
		_canvas.b[i] *= 1.0 + (SHADOW_WASH.b - 1.0) * a


## Trazos de pluma que bajan por la ladera, más densos y oscuros donde da la espalda a la luz.
func _paint_hachures() -> void:
	_rng.seed = 7002
	var spacing: float = 4.6 * _ppm / 4.0 * 1.0
	var ink_color: Color = Color(0.30, 0.22, 0.15)
	var strokes: int = 0
	var y_pos: float = 2.0
	while y_pos < _height - 2:
		var x_pos: float = 2.0
		while x_pos < _width - 2:
			var px: float = x_pos + _rng.randf_range(-spacing * 0.5, spacing * 0.5)
			var py: float = y_pos + _rng.randf_range(-spacing * 0.5, spacing * 0.5)
			x_pos += spacing
			if px < 2.0 or py < 2.0 or px >= _width - 3 or py >= _height - 3:
				continue
			var i: int = int(py) * _width + int(px)
			var slope: float = sqrt(_grad_x[i] * _grad_x[i] + _grad_z[i] * _grad_z[i])
			if slope < 0.10:
				continue
			var dark: float = _dark[i]
			var chance: float = clampf((slope - 0.10) * 3.2, 0.0, 1.0) * (0.12 + 0.88 * dark)
			if _rng.randf() > chance:
				continue
			if _heights[i] < Layout.WATER_LEVEL - 0.2:
				continue
			var length: float = clampf(slope * 22.0, 3.0, 11.0) * (_ppm / 4.0)
			var cursor := Vector2(px, py)
			var steps: int = maxi(int(length), 2)
			var alpha: float = (0.16 + 0.34 * dark) * clampf(slope * 4.0, 0.4, 1.0) * (1.0 - 0.5 * _smoothstep(0.5, 1.2, slope))
			for s: int in steps:
				var t: float = float(s) / float(steps)
				var ci: int = clampi(int(cursor.y), 0, _height - 1) * _width + clampi(int(cursor.x), 0, _width - 1)
				var gx: float = _grad_x[ci]
				var gz: float = _grad_z[ci]
				var gl: float = sqrt(gx * gx + gz * gz)
				if gl < 1e-4:
					break
				_splat(cursor.x, cursor.y, alpha * (1.0 - 0.75 * t), ink_color)
				cursor += Vector2(-gx, -gz) / gl
			strokes += 1
		y_pos += spacing
	print("      %d trazos de pluma" % strokes)


# --- 4. Río -------------------------------------------------------------------------------------

func _paint_water() -> void:
	var count: int = _width * _height
	_water.resize(count)
	_shore.resize(count)
	var fk: float = _fk()
	var wobble_noise: PackedByteArray = ParchmentCanvas.noise_bytes(401, 0.030 * fk, 2, _width, _height)
	var chop: PackedByteArray = ParchmentCanvas.noise_bytes(402, 0.055 * fk, 2, _width, _height)
	var wash_noise: PackedByteArray = ParchmentCanvas.noise_bytes(403, 0.012 * fk, 3, _width, _height)
	var level: float = Layout.WATER_LEVEL
	var bank_wash: Color = Color(0.56, 0.48, 0.38)
	for y: int in _height:
		var row: int = y * _width
		var z_world: float = _def.world_origin.y + (float(y) + 0.5) / _ppm
		for x: int in _width:
			var i: int = row + x
			var h: float = _heights[i] + (_byte01(wobble_noise, i) - 0.5) * 0.12
			var gm: float = sqrt(_grad_x[i] * _grad_x[i] + _grad_z[i] * _grad_z[i])
			var sd: float = clampf((level - h) * _ppm / maxf(gm, 0.02), -40.0, 40.0)
			_shore[i] = sd
			_water[i] = clampf(sd + 0.5, 0.0, 1.0)
			if sd < -11.0:
				continue
			var x_world: float = _def.world_origin.x + (float(x) + 0.5) / _ppm
			var axis: float = Layout.river_distance(x_world, z_world)
			var ford: float = Layout.ford_factor(x_world, z_world)
			if sd <= -1.0:
				# Orilla entintada: aguada parda que se desvanece hacia fuera.
				var t: float = clampf((-sd - 1.0) / 10.0, 0.0, 1.0)
				var a_bank: float = 0.26 * (1.0 - t) * (1.0 - t)
				_canvas.r[i] *= 1.0 + (bank_wash.r - 1.0) * a_bank
				_canvas.g[i] *= 1.0 + (bank_wash.g - 1.0) * a_bank
				_canvas.b[i] *= 1.0 + (bank_wash.b - 1.0) * a_bank
			var cover: float = _water[i]
			if cover > 0.0:
				var depth: float = _smoothstep(7.5, 0.5, axis)
				var color: Color = WATER_SHALLOW.lerp(WATER_DEEP, depth * 0.92)
				var ford_soft: float = 1.0 - _smoothstep(4.0, 26.0, Layout.ford_arc_distance(x_world, z_world))
				color = color.lerp(Color(0.74, 0.77, 0.64), ford_soft * 0.40)
				var a_water: float = cover * (0.84 - 0.12 * ford_soft) * (0.86 + 0.14 * _byte01(wash_noise, i))
				var g: float = 0.45 + 0.55 * _canvas.grain[i]
				var inv: float = 1.0 - a_water
				_canvas.r[i] = _canvas.r[i] * inv + color.r * g * a_water
				_canvas.g[i] = _canvas.g[i] * inv + color.g * g * a_water
				_canvas.b[i] = _canvas.b[i] * inv + color.b * g * a_water
				# Líneas paralelas a la orilla, rotas por el ruido (grabado del agua).
				if ford < 0.55 and sd > 2.0:
					var chop_value: float = _byte01(chop, i)
					for k: int in 3:
						var d0: float = 5.6 - 1.8 * float(k)
						var a_line: float = clampf(1.0 - absf(axis - d0) * _ppm / 0.85, 0.0, 1.0)
						if a_line > 0.0 and chop_value > 0.40 + 0.08 * float(k):
							var strength: float = a_line * (0.55 - 0.12 * float(k)) * (1.0 - ford * 1.6) * (1.0 - 0.6 * _canvas.wear[i])
							_canvas.r[i] *= 1.0 + (WATER_LINE.r - 1.0) * strength
							_canvas.g[i] *= 1.0 + (WATER_LINE.g - 1.0) * strength
							_canvas.b[i] *= 1.0 + (WATER_LINE.b - 1.0) * strength
			# Línea de la orilla (tinta).
			var ink: float = clampf(1.35 - absf(sd), 0.0, 1.0)
			if ink > 0.0:
				var a_ink: float = ink * 0.95 * (0.70 + 0.30 * _byte01(wash_noise, i)) * (1.0 - 0.7 * _canvas.wear[i])
				_canvas.r[i] *= 1.0 + (INK.r - 1.0) * a_ink
				_canvas.g[i] *= 1.0 + (INK.g - 1.0) * a_ink
				_canvas.b[i] *= 1.0 + (INK.b - 1.0) * a_ink
	# Marcas de corriente: trazos cortos a lo largo del cauce.
	_rng.seed = 7003
	var marks: int = 0
	for k: int in int(26000.0 * float(_width * _height) / 4194304.0):
		var at := Vector2(_rng.randf() * _width, _rng.randf() * _height)
		var i: int = int(at.y) * _width + int(at.x)
		if _shore[i] < 9.0 or _rng.randf() > 0.55:
			continue
		var world: Vector3 = _def.pixel_to_world(at)
		var e: float = 0.6
		var gdx: float = Layout.river_distance(world.x + e, world.z) - Layout.river_distance(world.x - e, world.z)
		var gdz: float = Layout.river_distance(world.x, world.z + e) - Layout.river_distance(world.x, world.z - e)
		var flow := Vector2(-gdz, gdx)
		if flow.length() < 1e-4 or Layout.ford_factor(world.x, world.z) > 0.3:
			continue
		flow = flow.normalized()
		var length: float = _rng.randf_range(7.0, 17.0) * _ppm / 4.0
		var bend: Vector2 = Vector2(-flow.y, flow.x) * _rng.randf_range(-1.6, 1.6)
		var points := PackedVector2Array([at - flow * length * 0.5, at + bend, at + flow * length * 0.5])
		_ink_taper(ParchmentCanvas.smooth(points, 5), 1.0, 0.35, 0.40, WATER_LINE, 0.4)
		marks += 1
	print("      %d marcas de corriente" % marks)


# --- 5. Caminos, vado y puentes -----------------------------------------------------------------

## La polilínea [param points] (px) desplazada [param distance] px hacia su izquierda.
func _offset_line(points: PackedVector2Array, distance: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	var count: int = points.size()
	for i: int in count:
		var prev: Vector2 = points[maxi(i - 1, 0)]
		var next: Vector2 = points[mini(i + 1, count - 1)]
		var tangent: Vector2 = (next - prev).normalized() if next != prev else Vector2.RIGHT
		result.append(points[i] + Vector2(-tangent.y, tangent.x) * distance)
	return result


func _paint_roads() -> void:
	var roads: Array[PackedVector2Array] = Layout.road_polylines()
	var noise := FastNoiseLite.new()
	noise.seed = 4301
	noise.frequency = 0.04
	for index: int in roads.size():
		for mirror: int in 2:
			# La calzada transversal va sobre el eje: se dibuja una sola vez.
			if index == 2 and mirror == 1:
				continue
			var points := PackedVector2Array()
			for p: Vector2 in roads[index]:
				points.append(_px(p.x, p.y if mirror == 0 else -p.y))
			points = ParchmentCanvas.resample(ParchmentCanvas.smooth(points, 14), 1.5)
			var solid: bool = index != 1
			_draw_road(points, solid, noise, index * 2 + mirror)
	# Las calzadas siguen detrás de las puertas por el paso entre las montañas, hasta el borde del mapa
	# (a los otros reinos), con trazo discontinuo.
	for mirror: int in 2:
		var sign_z: float = -1.0 if mirror == 0 else 1.0
		var outward := PackedVector2Array([_px(0.0, sign_z * 150.0), _px(2.0, sign_z * 176.0), _px(-3.0, sign_z * 206.0),
				_px(1.0, sign_z * 236.0), _px(0.0, sign_z * 258.0)])
		outward = ParchmentCanvas.resample(ParchmentCanvas.smooth(outward, 14), 1.5)
		_draw_road(outward, false, noise, 20 + mirror)


func _draw_road(points: PackedVector2Array, solid: bool, noise: FastNoiseLite, phase: int) -> void:
	var center: PackedVector2Array = ParchmentCanvas.wobble(points, noise, 0.5, float(phase) * 31.0)
	var widths := PackedFloat32Array([_m(3.2)])
	for mask: ParchmentCanvas.Mask in ParchmentCanvas.stroke_masks(center, widths, false, false):
		_canvas.paint(mask, ParchmentCanvas.MODE_OVER, ROAD_SAND, 0.58, 0.7, 0.0, _water)
	for side: int in 2:
		var side_sign: float = -1.0 if side == 0 else 1.0
		var edge: PackedVector2Array = ParchmentCanvas.wobble(_offset_line(points, side_sign * _m(1.7)), noise, 0.7,
				float(phase) * 31.0 + 7.0 * float(side) + 11.0)
		var pieces: Array[PackedVector2Array] = []
		if solid:
			pieces.append(edge)
		else:
			pieces = ParchmentCanvas.dash(edge, 20.0 * _ppm / 4.0, 6.0 * _ppm / 4.0, float(side) * 9.0)
		for piece: PackedVector2Array in pieces:
			for mask: ParchmentCanvas.Mask in ParchmentCanvas.stroke_masks(piece, PackedFloat32Array([_line(0.26, 1.15)]), false, false):
				_canvas.paint(mask, ParchmentCanvas.MODE_MULTIPLY, INK, 0.72, 0.5, 0.7, _water)


## Matas de hierba en la llanura y juncos en las orillas: trazos de pluma muy finos.
func _paint_ground_marks() -> void:
	_rng.seed = 7011
	var area_factor: float = float(_width * _height) / 4194304.0
	var grass_color: Color = Color(0.34, 0.31, 0.16)
	var tufts: int = 0
	for k: int in int(14000.0 * area_factor):
		var x: float = _rng.randf_range(-150.0, 150.0)
		var z: float = _rng.randf_range(-152.0, 152.0)
		var at: Vector2 = _px(x, z)
		var i: int = int(at.y) * _width + int(at.x)
		if _shore[i] > -4.5 or _heights[i] > 12.0:
			continue
		if Layout.road_distance(x, z) < 3.4 or Layout.fort_sdf(x, z) < 6.0 or Layout.camp_distance(x, z) < 27.0 or _near_ruins(x, z):
			continue
		var size: float = _rng.randf_range(2.8, 5.0) * _ppm / 4.0
		for blade: int in 3:
			var angle: float = -PI * 0.5 + float(blade - 1) * 0.5 + _rng.randf_range(-0.12, 0.12)
			var direction := Vector2(cos(angle), sin(angle))
			for step: int in 4:
				var t: float = float(step) / 3.0
				_splat(at.x + direction.x * size * t, at.y + direction.y * size * t, 0.50 * (1.0 - 0.45 * t), grass_color)
		tufts += 1
	var reeds: int = 0
	for k: int in int(240000.0 * area_factor):
		var at := Vector2(_rng.randf() * _width, _rng.randf() * _height)
		var i: int = int(at.y) * _width + int(at.x)
		var shore: float = _shore[i]
		if shore > -2.0 or shore < -6.5 or _rng.randf() > 0.16:
			continue
		var size: float = _rng.randf_range(5.0, 9.0) * _ppm / 4.0
		for blade: int in 4:
			var lean: float = float(blade - 1) * 0.28 + _rng.randf_range(-0.08, 0.08)
			for step: int in 5:
				var t: float = float(step) / 4.0
				_splat(at.x + lean * size * t * t * 1.4, at.y - size * t, 0.62 * (1.0 - 0.4 * t), Color(0.26, 0.28, 0.14))
		reeds += 1
	print("      %d matas y %d juncos" % [tufts, reeds])


## Instancias del terreno de ids [param mesh_ids]: posición del mundo, escala y giro.
func _terrain_instances(mesh_ids: Array[int]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var region_size: float = float(_terrain.get_region_size()) * _terrain.vertex_spacing
	for region: Terrain3DRegion in _terrain.data.get_regions_active():
		var origin := Vector3(float(region.location.x) * region_size, 0.0, float(region.location.y) * region_size)
		var all: Dictionary = region.get_instances()
		for mesh_id: int in mesh_ids:
			if not all.has(mesh_id):
				continue
			var by_cell: Dictionary = all[mesh_id]
			for cell: Variant in by_cell:
				var entry: Array = by_cell[cell]
				for transform: Transform3D in (entry[0] as Array):
					var world: Vector3 = transform.origin + origin
					result.append({"id": mesh_id, "x": world.x, "y": world.y, "z": world.z,
							"scale": transform.basis.get_scale().y, "yaw": transform.basis.get_euler().y})
	return result


func _paint_ford() -> void:
	_rng.seed = 7004
	# Banco de arena: puntitos claros donde el lecho es somero.
	var dots: int = 0
	for k: int in 5200:
		var x: float = _rng.randf_range(-86.0, -38.0)
		var z: float = _rng.randf_range(-24.0, 24.0)
		var at: Vector2 = _px(x, z)
		var i: int = int(at.y) * _width + int(at.x)
		if _water[i] < 0.9:
			continue
		var ford: float = Layout.ford_factor(x, z)
		if ford < 0.25 or _rng.randf() > ford * 0.30:
			continue
		var radius: float = _rng.randf_range(0.45, 1.0) * _ppm / 4.0
		var polygons: Array[PackedVector2Array] = [ParchmentCanvas.circle(at, radius, 8)]
		_canvas.paint(ParchmentCanvas.rasterize(polygons), ParchmentCanvas.MODE_OVER, Color(0.88, 0.82, 0.62),
				_rng.randf_range(0.35, 0.65), 0.6)
		dots += 1
	# Cruce marcado: línea de puntos sobre la calzada transversal (z = 0) y piedras del paso.
	var crossing := PackedVector2Array([_px(-84.0, 0.0), _px(-40.0, 0.0)])
	for piece: PackedVector2Array in ParchmentCanvas.dash(crossing, 5.0 * _ppm / 4.0, 5.0 * _ppm / 4.0):
		_ink_line(piece, _line(0.22, 1.1), 0.55, INK_SOFT, ParchmentCanvas.MODE_MULTIPLY, 0.5)
	for stone: Dictionary in _terrain_instances([15]):
		if Vector2(stone["x"] + 62.0, stone["z"]).length() > 24.0:
			continue
		var at: Vector2 = _px(stone["x"], stone["z"])
		var radius: float = _m(0.8) * float(stone["scale"])
		var polygons: Array[PackedVector2Array] = [ParchmentCanvas.ellipse(at, radius, radius * 0.8, float(stone["yaw"]), 12)]
		_fill(polygons, ParchmentCanvas.MODE_OVER, STONE_LIGHT, 0.95, 0.6)
		_ink_line(polygons[0], _line(0.18, 0.9), 0.85, INK, ParchmentCanvas.MODE_MULTIPLY, 0.4, true)
	# Los postes del vado (las dos hileras del paso), de la escena.
	var posts: BakedMultiMesh = _zone.get_node_or_null(^"Vado/Postes") as BakedMultiMesh
	if posts != null:
		for k: int in posts.instance_transforms.size() / BakedMultiMesh.FLOATS_PER_INSTANCE:
			var base: int = k * BakedMultiMesh.FLOATS_PER_INSTANCE
			var local := Vector3(posts.instance_transforms[base + 9], posts.instance_transforms[base + 10], posts.instance_transforms[base + 11])
			var world: Vector3 = posts.global_transform * local
			var at: Vector2 = _px(world.x, world.z)
			var polygons: Array[PackedVector2Array] = [ParchmentCanvas.circle(at, _line(0.34, 1.7), 10)]
			_fill(polygons, ParchmentCanvas.MODE_OVER, WOOD, 0.95, 0.3)
			_ink_line(polygons[0], 0.9, 0.9, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3, true)
	print("      %d puntos de arena" % dots)


func _paint_bridges() -> void:
	for bridge: Node in _zone.get_node(^"Puentes").get_children():
		var node: Node3D = bridge as Node3D
		if node == null:
			continue
		var cx: float = node.global_position.x
		var cz: float = node.global_position.z
		var half_w: float = 2.4
		var half_l: float = 12.0
		var deck: PackedVector2Array = PackedVector2Array([_px(cx - half_w, cz - half_l), _px(cx + half_w, cz - half_l),
				_px(cx + half_w, cz + half_l), _px(cx - half_w, cz + half_l)])
		var shadow: PackedVector2Array = PackedVector2Array()
		for p: Vector2 in deck:
			shadow.append(p + Vector2(2.6, 3.6) * _ppm / 4.0)
		var shadow_polys: Array[PackedVector2Array] = [shadow]
		_fill(shadow_polys, ParchmentCanvas.MODE_MULTIPLY, Color(0.45, 0.52, 0.55), 0.55, 0.0)
		# Rampas de acceso que se ensanchan en los dos extremos.
		for end_sign: float in [-1.0, 1.0]:
			var z_edge: float = cz + end_sign * half_l
			var ramp: PackedVector2Array = PackedVector2Array([_px(cx - half_w, z_edge), _px(cx + half_w, z_edge),
					_px(cx + half_w + 1.6, z_edge + end_sign * 2.2), _px(cx - half_w - 1.6, z_edge + end_sign * 2.2)])
			var ramp_polys: Array[PackedVector2Array] = [ramp]
			_fill(ramp_polys, ParchmentCanvas.MODE_OVER, STONE_LIGHT, 0.95, 0.6)
			_ink_line(ramp, _line(0.3, 1.3), 0.85, INK, ParchmentCanvas.MODE_MULTIPLY, 0.5, true)
		var deck_polys: Array[PackedVector2Array] = [deck]
		_fill(deck_polys, ParchmentCanvas.MODE_OVER, STONE_LIGHT, 0.98, 0.7)
		# Tablones.
		var planks: int = int(half_l * 2.0 / 0.9)
		for p: int in range(1, planks):
			var z: float = cz - half_l + float(p) * 0.9
			_ink_line(PackedVector2Array([_px(cx - half_w, z), _px(cx + half_w, z)]), 0.8, 0.28, INK_SOFT,
					ParchmentCanvas.MODE_MULTIPLY, 0.4)
		# Pretiles y cabezales.
		for side: float in [-1.0, 1.0]:
			_ink_line(PackedVector2Array([_px(cx + side * half_w, cz - half_l), _px(cx + side * half_w, cz + half_l)]),
					_line(0.42, 1.8), 0.95, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3)
		for end_sign: float in [-1.0, 1.0]:
			_ink_line(PackedVector2Array([_px(cx - half_w, cz + end_sign * half_l), _px(cx + half_w, cz + end_sign * half_l)]),
					_line(0.4, 1.7), 0.95, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3)



# --- 6. Construcciones --------------------------------------------------------------------------

## Cajas de colisión de [param body]: centro (x, z), tamaño local (x, z), giro y altura.
func _body_boxes(body: Node) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for node: Node in body.find_children("*", "CollisionShape3D", true, false):
		var collision: CollisionShape3D = node as CollisionShape3D
		if collision.shape is BoxShape3D:
			var box: BoxShape3D = collision.shape as BoxShape3D
			var scale_value: Vector3 = collision.global_transform.basis.get_scale()
			result.append({"center": Vector2(collision.global_position.x, collision.global_position.z),
					"size": Vector2(box.size.x * scale_value.x, box.size.z * scale_value.z),
					"yaw": collision.global_transform.basis.get_euler().y, "height": box.size.y * scale_value.y})
	return result


## Casco en planta de todas las colisiones de [param body], en píxeles.
func _body_hull_px(body: Node) -> PackedVector2Array:
	var points := PackedVector2Array()
	for node: Node in body.find_children("*", "CollisionShape3D", true, false):
		var collision: CollisionShape3D = node as CollisionShape3D
		if collision.shape == null:
			continue
		var footprint: ZoneMapBaker.Footprint = ZoneMapBaker.footprint_of_shape(collision.shape, collision.global_transform)
		if footprint != null:
			points.append_array(footprint.polygon)
	var hull: PackedVector2Array = ZoneMapBaker.convex_hull(points)
	var result := PackedVector2Array()
	for p: Vector2 in hull:
		result.append(_px(p.x, p.y))
	return result


## Transformaciones del mundo de las instancias de una malla repetida.
func _instance_transforms(baked: BakedMultiMesh) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	var count: int = baked.instance_transforms.size() / BakedMultiMesh.FLOATS_PER_INSTANCE
	for i: int in count:
		var k: int = i * BakedMultiMesh.FLOATS_PER_INSTANCE
		var data: PackedFloat32Array = baked.instance_transforms
		var basis := Basis(Vector3(data[k], data[k + 1], data[k + 2]), Vector3(data[k + 3], data[k + 4], data[k + 5]),
				Vector3(data[k + 6], data[k + 7], data[k + 8]))
		result.append(baked.global_transform * Transform3D(basis, Vector3(data[k + 9], data[k + 10], data[k + 11])))
	return result


## Un bloque de piedra visto desde arriba: sombra, relleno, tejado hundido (opcional) y borde de tinta.
func _draw_block(polygon: PackedVector2Array, fill: Color = STONE_LIGHT, outline: float = 1.6, inset_roof: float = 0.0) -> void:
	var shadow := PackedVector2Array()
	for p: Vector2 in polygon:
		shadow.append(p + Vector2(2.4, 3.2) * _ppm / 4.0)
	var shadow_polys: Array[PackedVector2Array] = [shadow]
	_fill(shadow_polys, ParchmentCanvas.MODE_MULTIPLY, Color(0.42, 0.38, 0.34), 0.42, 0.0)
	var body_polys: Array[PackedVector2Array] = [polygon]
	_fill(body_polys, ParchmentCanvas.MODE_OVER, fill, 0.97, 0.7)
	if inset_roof > 0.0 and polygon.size() >= 3:
		var center := Vector2.ZERO
		for p: Vector2 in polygon:
			center += p
		center /= float(polygon.size())
		var roof := PackedVector2Array()
		for p: Vector2 in polygon:
			var toward: Vector2 = center - p
			roof.append(p + toward.normalized() * minf(inset_roof, toward.length() * 0.7))
		var roof_polys: Array[PackedVector2Array] = [roof]
		_fill(roof_polys, ParchmentCanvas.MODE_MULTIPLY, Color(0.80, 0.75, 0.68), 0.55, 0.0)
		_ink_line(roof, maxf(outline * 0.5, 0.8), 0.6, INK_SOFT, ParchmentCanvas.MODE_MULTIPLY, 0.5, true)
	_ink_line(polygon, outline, 0.92, INK, ParchmentCanvas.MODE_MULTIPLY, 0.35, true)


func _instances_rect(baked: BakedMultiMesh) -> Rect2:
	var rect := Rect2()
	var first: bool = true
	var footprints: Array[ZoneMapBaker.Footprint] = ZoneMapBaker.footprints_of_instances(baked.source_mesh.get_aabb(),
			baked.instance_transforms, baked.global_transform)
	for footprint: ZoneMapBaker.Footprint in footprints:
		for p: Vector2 in footprint.polygon:
			if first:
				rect = Rect2(p, Vector2.ZERO)
				first = false
			else:
				rect = rect.expand(p)
	return rect


func _paint_walls() -> void:
	var walls: Node = _zone.get_node_or_null(^"Murallas")
	if walls == null:
		return
	for wall: Node in walls.get_children():
		var courses: BakedMultiMesh = wall.get_node_or_null(^"Hiladas") as BakedMultiMesh
		if courses == null:
			continue
		var rect: Rect2 = _instances_rect(courses)
		var zc: float = rect.get_center().y
		var outward: float = -1.0 if zc < 0.0 else 1.0
		var x0: float = rect.position.x
		var x1: float = rect.end.x
		var half: float = 1.7
		# Cuerpo de la muralla.
		# Se pinta por tramos de 30 m para que las máscaras sean pequeñas.
		var piece_x: float = x0
		while piece_x < x1:
			var piece_end: float = minf(piece_x + 30.0, x1)
			var body: PackedVector2Array = PackedVector2Array([_px(piece_x, zc - half), _px(piece_end + 0.05, zc - half),
					_px(piece_end + 0.05, zc + half), _px(piece_x, zc + half)])
			var shadow := PackedVector2Array()
			for p: Vector2 in body:
				shadow.append(p + Vector2(2.2, 3.0) * _ppm / 4.0)
			var shadow_polys: Array[PackedVector2Array] = [shadow]
			_fill(shadow_polys, ParchmentCanvas.MODE_MULTIPLY, Color(0.42, 0.38, 0.34), 0.22, 0.0)
			piece_x = piece_end
		piece_x = x0
		while piece_x < x1:
			var piece_end: float = minf(piece_x + 30.0, x1)
			var body: PackedVector2Array = PackedVector2Array([_px(piece_x, zc - half), _px(piece_end + 0.05, zc - half),
					_px(piece_end + 0.05, zc + half), _px(piece_x, zc + half)])
			var body_polys: Array[PackedVector2Array] = [body]
			_fill(body_polys, ParchmentCanvas.MODE_OVER, STONE_LIGHT, 0.97, 0.7)
			piece_x = piece_end
		# Sillares: marcas cortas a lo ancho de la muralla.
		var x: float = x0 + 0.8
		while x < x1:
			_ink_line(PackedVector2Array([_px(x, zc - half * 0.8), _px(x, zc + half * 0.8)]), 0.8, 0.22, INK_SOFT,
					ParchmentCanvas.MODE_MULTIPLY, 0.5)
			x += 1.6
		# Almenas: dientes a los dos lados, mayores por fuera.
		var merlon_x: float = x0 + 1.4
		while merlon_x < x1 - 1.0:
			for side: int in 2:
				var depth: float = 1.05 if side == 0 else 0.7
				var z_inner: float = zc + outward * half * (1.0 if side == 0 else -1.0)
				var z_outer: float = z_inner + outward * (1.0 if side == 0 else -1.0) * depth
				var merlon: PackedVector2Array = PackedVector2Array([_px(merlon_x - 0.6, z_inner), _px(merlon_x + 0.6, z_inner),
						_px(merlon_x + 0.6, z_outer), _px(merlon_x - 0.6, z_outer)])
				var merlon_polys: Array[PackedVector2Array] = [merlon]
				_fill(merlon_polys, ParchmentCanvas.MODE_OVER, STONE_LIGHT, 0.97, 0.7)
				_ink_line(merlon, 0.9, 0.85, INK, ParchmentCanvas.MODE_MULTIPLY, 0.4, true)
			merlon_x += 2.4
		for side_sign: float in [-1.0, 1.0]:
			_ink_line(PackedVector2Array([_px(x0, zc + side_sign * half), _px(x1, zc + side_sign * half)]),
					_line(0.32, 1.4), 0.9, INK, ParchmentCanvas.MODE_MULTIPLY, 0.35)
		# Torres.
		for child: Node in wall.get_children():
			if String(child.name).begins_with("Torre"):
				_draw_block(_body_hull_px(child), STONE_LIGHT, _line(0.42, 1.7), _m(0.9))
		# Puerta: bloque con el paso de la calzada y las enseñas del reino.
		var gate: Node3D = wall.get_node_or_null(^"Puerta") as Node3D
		if gate != null:
			var hull: PackedVector2Array = _body_hull_px(gate)
			_draw_block(hull, STONE_LIGHT, _line(0.5, 2.0), _m(0.8))
			var passage: PackedVector2Array = PackedVector2Array([_px(gate.global_position.x - 2.2, zc - 4.6),
					_px(gate.global_position.x + 2.2, zc - 4.6), _px(gate.global_position.x + 2.2, zc + 4.6),
					_px(gate.global_position.x - 2.2, zc + 4.6)])
			var passage_polys: Array[PackedVector2Array] = [passage]
			_fill(passage_polys, ParchmentCanvas.MODE_OVER, ROAD_SAND, 0.95, 0.7)
			for side_sign: float in [-1.0, 1.0]:
				_ink_line(PackedVector2Array([_px(gate.global_position.x + side_sign * 2.2, zc - 4.6),
						_px(gate.global_position.x + side_sign * 2.2, zc + 4.6)]), _line(0.3, 1.3), 0.9, INK,
						ParchmentCanvas.MODE_MULTIPLY, 0.3)
			var pass_entry: Array = ZoneMapBaker.WALL_PASSES.get(String(wall.name), ["", 0])
			var realm: int = int(pass_entry[1])
			var banner_color: Color = REALM_COLORS.get(realm, Color(0.4, 0.4, 0.4))
			for flag_x: float in [-7.4, 7.4]:
				_add_sprite(&"flag", _px(gate.global_position.x + flag_x, zc + outward * 0.8), _m(9.5),
						{"color": banner_color})


func _paint_ruins() -> void:
	var ruins: Node = _zone.get_node_or_null(^"Ruinas")
	if ruins == null:
		return
	_rng.seed = 7005
	# Suelos de las casas.
	var floors: BakedMultiMesh = ruins.get_node_or_null(^"AldeaDeEld/Suelos") as BakedMultiMesh
	if floors != null:
		for transform: Transform3D in _instance_transforms(floors):
			var center: Vector2 = _px(transform.origin.x, transform.origin.z)
			var polygons: Array[PackedVector2Array] = [ParchmentCanvas.box(center, _m(1.0), _m(1.0), -transform.basis.get_euler().y)]
			_fill(polygons, ParchmentCanvas.MODE_OVER, Color(0.86, 0.80, 0.62), 0.55, 0.7)
			_ink_line(polygons[0], 0.8, 0.28, INK_SOFT, ParchmentCanvas.MODE_MULTIPLY, 0.5, true)
	# Suelo de la capilla: baldosas pálidas entre sus cuatro muros.
	var chapel: Node3D = ruins.get_node_or_null(^"Capilla") as Node3D
	if chapel != null:
		var low := Vector2(INF, INF)
		var high := Vector2(-INF, -INF)
		for child: Node in chapel.get_children():
			var spatial: Node3D = child as Node3D
			if spatial != null:
				low = low.min(Vector2(spatial.global_position.x, spatial.global_position.z))
				high = high.max(Vector2(spatial.global_position.x, spatial.global_position.z))
		if low.x < high.x:
			var floor_polys: Array[PackedVector2Array] = [PackedVector2Array([_px(low.x, low.y), _px(high.x, low.y), _px(high.x, high.y), _px(low.x, high.y)])]
			_fill(floor_polys, ParchmentCanvas.MODE_OVER, Color(0.88, 0.82, 0.64), 0.60, 0.7)
			var tile_x: float = low.x + 2.0
			while tile_x < high.x:
				_ink_line(PackedVector2Array([_px(tile_x, low.y), _px(tile_x, high.y)]), 0.8, 0.22, INK_SOFT, ParchmentCanvas.MODE_MULTIPLY, 0.5)
				tile_x += 2.0
			var tile_z: float = low.y + 2.0
			while tile_z < high.y:
				_ink_line(PackedVector2Array([_px(low.x, tile_z), _px(high.x, tile_z)]), 0.8, 0.22, INK_SOFT, ParchmentCanvas.MODE_MULTIPLY, 0.5)
				tile_z += 2.0
	# Muros: tramos gruesos con huecos (se dibujan más anchos de lo que son para que se lean).
	for body: Node in ruins.find_children("*", "StaticBody3D", true, false):
		for box: Dictionary in _body_boxes(body):
			var size: Vector2 = box["size"]
			var half_x: float = maxf(size.x * 0.5, 0.55)
			var half_z: float = maxf(size.y * 0.5, 0.55)
			var center: Vector2 = _px(box["center"].x, box["center"].y)
			var polygon: PackedVector2Array = ParchmentCanvas.box(center, _m(half_x), _m(half_z), -float(box["yaw"]))
			var shadow := PackedVector2Array()
			for p: Vector2 in polygon:
				shadow.append(p + Vector2(1.6, 2.2) * _ppm / 4.0)
			var shadow_polys: Array[PackedVector2Array] = [shadow]
			_fill(shadow_polys, ParchmentCanvas.MODE_MULTIPLY, Color(0.45, 0.40, 0.36), 0.35, 0.0)
			var polys: Array[PackedVector2Array] = [polygon]
			_fill(polys, ParchmentCanvas.MODE_OVER, STONE_LIGHT.darkened(0.06), 0.96, 0.7)
			_ink_line(polygon, _line(0.2, 1.0), 0.88, INK, ParchmentCanvas.MODE_MULTIPLY, 0.45, true)
	# Escombros.
	var rubble: BakedMultiMesh = ruins.get_node_or_null(^"Escombros") as BakedMultiMesh
	if rubble != null:
		for transform: Transform3D in _instance_transforms(rubble):
			var center: Vector2 = _px(transform.origin.x, transform.origin.z)
			for k: int in 3:
				var at: Vector2 = center + Vector2(_rng.randf_range(-1.6, 1.6), _rng.randf_range(-1.6, 1.6)) * _ppm
				var radius: float = _m(_rng.randf_range(0.28, 0.55))
				var stone: PackedVector2Array = PackedVector2Array()
				for v: int in 6:
					var angle: float = TAU * float(v) / 6.0 + _rng.randf() * 0.4
					stone.append(at + Vector2(cos(angle), sin(angle) * 0.75) * radius * _rng.randf_range(0.8, 1.15))
				var polys: Array[PackedVector2Array] = [stone]
				_fill(polys, ParchmentCanvas.MODE_OVER, STONE_LIGHT, 0.95, 0.7)
				_ink_line(stone, 0.9, 0.8, INK, ParchmentCanvas.MODE_MULTIPLY, 0.4, true)


## Los campamentos: el suelo del reino, el contorno de la zona segura y lo que hay dentro. Las tiendas y
## las enseñas son símbolos que se dibujan con los demás ([method _paint_symbols]).
func _paint_camps_ground() -> void:
	var camps: Node = _zone.get_node_or_null(^"Campamentos")
	if camps == null:
		return
	_rng.seed = 7006
	for group: Node in camps.get_children():
		var kids: Array[Node3D] = []
		var centroid := Vector2.ZERO
		for child: Node in group.get_children():
			var spatial: Node3D = child as Node3D
			if spatial != null:
				kids.append(spatial)
				centroid += Vector2(spatial.global_position.x, spatial.global_position.z)
		if kids.is_empty():
			continue
		centroid /= float(kids.size())
		var center_world: Vector2 = centroid
		var realm: int = 1 if centroid.y < 0.0 else 2
		var best: float = INF
		for landmark: MapLandmark in _def.get_landmarks(MapLandmark.KIND_CAMP):
			var distance: float = Vector2(landmark.position.x, landmark.position.z).distance_to(centroid)
			if distance < best:
				best = distance
				realm = landmark.realm
				center_world = Vector2(landmark.position.x, landmark.position.z)
		var color: Color = REALM_COLORS.get(realm, Color(0.5, 0.5, 0.5))
		var center: Vector2 = _px(center_world.x, center_world.y)
		for ring: int in 4:
			var polys: Array[PackedVector2Array] = [ParchmentCanvas.circle(center, _m(25.0 - 1.4 * float(ring)), 40)]
			_fill(polys, ParchmentCanvas.MODE_OVER, color.lerp(PAPER, 0.35), 0.075, 0.9)
		var ring_points: PackedVector2Array = ParchmentCanvas.circle(center, _m(23.0), 72)
		ring_points.append(ring_points[0])
		for piece: PackedVector2Array in ParchmentCanvas.dash(ring_points, 9.0 * _ppm / 4.0, 6.0 * _ppm / 4.0):
			_ink_line(piece, _line(0.3, 1.3), 0.7, color.darkened(0.35), ParchmentCanvas.MODE_MULTIPLY, 0.5)
		for spatial: Node3D in kids:
			var name_text: String = String(spatial.name)
			var at: Vector2 = _px(spatial.global_position.x, spatial.global_position.z)
			if name_text.begins_with("Tent"):
				var hull: PackedVector2Array = _body_hull_px(spatial)
				var longest: float = 0.0
				for a: Vector2 in hull:
					for b: Vector2 in hull:
						longest = maxf(longest, a.distance_to(b))
				_add_sprite(&"tent", at + Vector2(0.0, _m(0.9)), maxf(longest * 1.7, _m(6.6)), {"color": color})
			elif name_text.begins_with("Banner"):
				_add_sprite(&"flag", at, _m(10.0), {"color": color})
			elif name_text.begins_with("Crate"):
				var polygon: PackedVector2Array = ParchmentCanvas.box(at, _m(0.85), _m(0.85), -spatial.global_transform.basis.get_euler().y)
				var polys: Array[PackedVector2Array] = [polygon]
				_fill(polys, ParchmentCanvas.MODE_OVER, WOOD, 0.95, 0.5)
				_ink_line(polygon, 1.0, 0.85, INK, ParchmentCanvas.MODE_MULTIPLY, 0.4, true)
				_ink_line(PackedVector2Array([polygon[0], polygon[2]]), 0.7, 0.45, INK, ParchmentCanvas.MODE_MULTIPLY, 0.4)
			elif name_text.begins_with("Wagon"):
				var yaw: float = -spatial.global_transform.basis.get_euler().y
				var polygon: PackedVector2Array = ParchmentCanvas.box(at, _m(1.5), _m(2.2), yaw)
				var polys: Array[PackedVector2Array] = [polygon]
				_fill(polys, ParchmentCanvas.MODE_OVER, WOOD.lightened(0.1), 0.95, 0.5)
				_ink_line(polygon, 1.3, 0.9, INK, ParchmentCanvas.MODE_MULTIPLY, 0.4, true)
				for wheel_side: float in [-1.0, 1.0]:
					for wheel_end: float in [-0.9, 0.9]:
						var wheel_center: Vector2 = at + Transform2D(yaw, Vector2.ZERO) * Vector2(_m(1.75) * wheel_side, _m(1.3) * wheel_end)
						_ink_line(PackedVector2Array([wheel_center - Transform2D(yaw, Vector2.ZERO) * Vector2(0.0, _m(0.55)),
								wheel_center + Transform2D(yaw, Vector2.ZERO) * Vector2(0.0, _m(0.55))]), 1.8, 0.9, INK,
								ParchmentCanvas.MODE_MULTIPLY, 0.3)
			elif name_text.begins_with("Fence"):
				var yaw: float = -spatial.global_transform.basis.get_euler().y
				var along: Vector2 = Transform2D(yaw, Vector2.ZERO) * Vector2(_m(1.0), 0.0)
				_ink_line(PackedVector2Array([at - along, at + along]), _line(0.2, 1.2), 0.9, INK, ParchmentCanvas.MODE_MULTIPLY, 0.4)
				for post: float in [-1.0, 0.0, 1.0]:
					var polys: Array[PackedVector2Array] = [ParchmentCanvas.circle(at + along * post, 1.5, 8)]
					_fill(polys, ParchmentCanvas.MODE_OVER, WOOD, 0.95, 0.3)
					_ink_line(polys[0], 0.8, 0.85, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3, true)
			elif name_text.begins_with("FirePit"):
				_draw_fire(at)


## Hoguera: anillo de piedras, brasas y una llama de aguada naranja.
func _draw_fire(at: Vector2) -> void:
	var ring: PackedVector2Array = ParchmentCanvas.circle(at, _m(1.15), 14)
	var polys: Array[PackedVector2Array] = [ring]
	_fill(polys, ParchmentCanvas.MODE_MULTIPLY, Color(0.50, 0.40, 0.32), 0.65, 0.0)
	for k: int in 9:
		var angle: float = TAU * float(k) / 9.0
		var stone: Vector2 = at + Vector2(cos(angle), sin(angle)) * _m(1.1)
		var stone_polys: Array[PackedVector2Array] = [ParchmentCanvas.circle(stone, _line(0.3, 1.5), 8)]
		_fill(stone_polys, ParchmentCanvas.MODE_OVER, STONE_LIGHT, 0.95, 0.6)
		_ink_line(stone_polys[0], 0.8, 0.8, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3, true)
	var flame: PackedVector2Array = PackedVector2Array([at + Vector2(0.0, -_m(2.0)), at + Vector2(_m(0.55), -_m(0.55)),
			at + Vector2(_m(0.3), _m(0.35)), at + Vector2(-_m(0.3), _m(0.35)), at + Vector2(-_m(0.55), -_m(0.55))])
	var flame_polys: Array[PackedVector2Array] = [ParchmentCanvas.smooth_closed(flame, 6)]
	_fill(flame_polys, ParchmentCanvas.MODE_OVER, Color(0.92, 0.50, 0.14), 0.9, 0.4)
	var core_polys: Array[PackedVector2Array] = [ParchmentCanvas.smooth_closed(PackedVector2Array([at + Vector2(0.0, -_m(1.1)),
			at + Vector2(_m(0.28), -_m(0.2)), at + Vector2(-_m(0.28), -_m(0.2))]), 5)]
	_fill(core_polys, ParchmentCanvas.MODE_OVER, Color(0.98, 0.84, 0.34), 0.9, 0.4)
	_ink_line(flame_polys[0], 0.9, 0.75, Color(0.45, 0.2, 0.08), ParchmentCanvas.MODE_MULTIPLY, 0.3, true)


## El fuerte visto desde arriba: patio, pasarela, empalizada (sus troncos), puerta, torreón y cajas.
func _paint_fort_ground() -> void:
	var fort: Node3D = _zone.get_node_or_null(^"Fuerte") as Node3D
	if fort == null:
		return
	_rng.seed = 7007
	var center: Vector2 = _px(fort.global_position.x, fort.global_position.z)
	# Patio de tierra apisonada dentro de la empalizada.
	var yard_polys: Array[PackedVector2Array] = [_rounded_square(center, _m(19.6), _m(4.5))]
	_fill(yard_polys, ParchmentCanvas.MODE_OVER, Color(0.88, 0.76, 0.56), 0.55, 0.8)
	# Pasarela: tablones de la escena.
	var walkway: BakedMultiMesh = fort.get_node_or_null(^"Pasarela") as BakedMultiMesh
	if walkway != null:
		for transform: Transform3D in _instance_transforms(walkway):
			var at: Vector2 = _px(transform.origin.x, transform.origin.z)
			var polys: Array[PackedVector2Array] = [ParchmentCanvas.box(at, _m(1.05), _m(1.05), -transform.basis.get_euler().y)]
			_fill(polys, ParchmentCanvas.MODE_OVER, WOOD.lightened(0.18), 0.7, 0.6)
			_ink_line(polys[0], 0.7, 0.3, INK_SOFT, ParchmentCanvas.MODE_MULTIPLY, 0.5, true)
	# Rampas a la pasarela.
	for ramp_name: String in ["RampaNorte", "RampaSur"]:
		var ramp: Node = fort.get_node_or_null(NodePath(ramp_name))
		if ramp == null:
			continue
		var hull: PackedVector2Array = _body_hull_px(ramp)
		var ramp_polys: Array[PackedVector2Array] = [hull]
		_fill(ramp_polys, ParchmentCanvas.MODE_OVER, WOOD.lightened(0.12), 0.9, 0.6)
		_ink_line(hull, 1.1, 0.85, INK, ParchmentCanvas.MODE_MULTIPLY, 0.4, true)
		if hull.size() >= 4:
			var bounds := Rect2(hull[0], Vector2.ZERO)
			for p: Vector2 in hull:
				bounds = bounds.expand(p)
			var step: float = _m(0.9)
			var y: float = bounds.position.y + step
			while y < bounds.end.y:
				_ink_line(PackedVector2Array([Vector2(bounds.position.x + 1.0, y), Vector2(bounds.end.x - 1.0, y)]), 0.8, 0.5,
						INK, ParchmentCanvas.MODE_MULTIPLY, 0.4)
				y += step
	# Cajas, hoguera y puerta.
	for child: Node in fort.get_children():
		var name_text: String = String(child.name)
		var spatial: Node3D = child as Node3D
		if spatial == null:
			continue
		var at: Vector2 = _px(spatial.global_position.x, spatial.global_position.z)
		if name_text.begins_with("Caja"):
			var polygon: PackedVector2Array = ParchmentCanvas.box(at, _m(0.75), _m(0.75), -spatial.global_transform.basis.get_euler().y)
			var polys: Array[PackedVector2Array] = [polygon]
			_fill(polys, ParchmentCanvas.MODE_OVER, WOOD, 0.95, 0.5)
			_ink_line(polygon, 0.9, 0.85, INK, ParchmentCanvas.MODE_MULTIPLY, 0.4, true)
		elif name_text == "Hoguera":
			_draw_fire(at)
	# Empalizada: los troncos de la escena, de uno en uno, unidos por una línea de base.
	var stakes: BakedMultiMesh = fort.get_node_or_null(^"Troncos") as BakedMultiMesh
	if stakes != null:
		var ring := PackedVector2Array()
		var transforms: Array[Transform3D] = _instance_transforms(stakes)
		for transform: Transform3D in transforms:
			ring.append(_px(transform.origin.x, transform.origin.z))
		var ring_shadow := PackedVector2Array()
		for p: Vector2 in ring:
			ring_shadow.append(p + Vector2(3.0, 4.0) * _ppm / 4.0)
		_ink_line(ring_shadow, _line(0.9, 3.0), 0.30, Color(0.50, 0.44, 0.38), ParchmentCanvas.MODE_MULTIPLY, 0.0)
		_ink_line(ring, _line(0.5, 1.8), 0.9, INK, ParchmentCanvas.MODE_MULTIPLY, 0.2)
		for at: Vector2 in ring:
			var polys: Array[PackedVector2Array] = [ParchmentCanvas.circle(at, _line(0.34, 1.5), 8)]
			_fill(polys, ParchmentCanvas.MODE_OVER, WOOD.lightened(0.08), 0.95, 0.3)
			_ink_line(polys[0], 0.7, 0.75, INK, ParchmentCanvas.MODE_MULTIPLY, 0.2, true)
	# Puerta del fuerte: dos postes y las hojas cerradas.
	var gate_center: Vector2 = _px(-20.0, 0.0)
	for side_sign: float in [-1.0, 1.0]:
		var post: Vector2 = _px(-20.0, side_sign * 2.35)
		var post_polys: Array[PackedVector2Array] = [ParchmentCanvas.box(post, _m(0.6), _m(0.6))]
		_fill(post_polys, ParchmentCanvas.MODE_OVER, WOOD.darkened(0.15), 0.98, 0.3)
		_ink_line(post_polys[0], 1.2, 0.92, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3, true)
		_add_sprite(&"flag", _px(-21.5, side_sign * 3.8), _m(9.0), {"color": Color(0.46, 0.40, 0.46)})
	_ink_line(PackedVector2Array([gate_center + Vector2(0.0, -_m(2.0)), gate_center + Vector2(0.0, _m(2.0))]),
			_line(0.45, 1.8), 0.85, WOOD.darkened(0.45), ParchmentCanvas.MODE_MULTIPLY, 0.3)
	# Torreón central.
	var tower: Node = fort.get_node_or_null(^"FortTower")
	if tower != null:
		var hull: PackedVector2Array = _body_hull_px(tower)
		_draw_block(hull, STONE_LIGHT, _line(0.5, 2.0), _m(1.0))
		for corner: Vector2 in hull:
			var merlon_polys: Array[PackedVector2Array] = [ParchmentCanvas.box(corner, _m(0.55), _m(0.55))]
			_fill(merlon_polys, ParchmentCanvas.MODE_OVER, STONE_LIGHT, 0.97, 0.7)
			_ink_line(merlon_polys[0], 1.0, 0.9, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3, true)
		_add_sprite(&"flag", center + Vector2(0.0, _m(0.4)), _m(15.0), {"color": Color(0.46, 0.40, 0.46)})


## Cuadrado de esquinas redondeadas ([param half] de lado a lado, [param radius] de esquina).
func _rounded_square(center: Vector2, half: float, radius: float) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	var corners: Array[Vector2] = [Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1), Vector2(1, -1)]
	var starts: Array[float] = [0.0, PI * 0.5, PI, PI * 1.5]
	for c: int in 4:
		var corner: Vector2 = center + corners[c] * (half - radius)
		for k: int in 7:
			var angle: float = starts[c] + (PI * 0.5) * float(k) / 6.0
			polygon.append(corner + Vector2(cos(angle), sin(angle)) * radius)
	return polygon


# --- 7. Símbolos: árboles, rocas, montañas, tiendas y enseñas -----------------------------------

## Un símbolo que se dibuja en su sitio y en su orden (de norte a sur).
func _add_sprite(kind: StringName, p: Vector2, size: float, extra: Dictionary = {}) -> void:
	var sprite: Dictionary = {"kind": kind, "p": p, "size": size}
	sprite.merge(extra)
	_sprites.append(sprite)


func _sprite_less(a: Dictionary, b: Dictionary) -> bool:
	var pa: Vector2 = a["p"]
	var pb: Vector2 = b["p"]
	if not is_equal_approx(pa.y, pb.y):
		return pa.y < pb.y
	if not is_equal_approx(pa.x, pb.x):
		return pa.x < pb.x
	return String(a["kind"]) < String(b["kind"])


func _paint_symbols() -> void:
	_collect_tree_sprites()
	_collect_mountain_sprites()
	_sprites.sort_custom(_sprite_less)
	print("      %d símbolos" % _sprites.size())
	for sprite: Dictionary in _sprites:
		var p: Vector2 = sprite["p"]
		if p.x < -300.0 or p.y < -300.0 or p.x > _width + 300.0 or p.y > _height + 100.0:
			continue
		_rng.seed = int(p.x * 7919.0 + p.y * 104729.0) + 17
		match StringName(sprite["kind"]):
			&"pine":
				_draw_pine(p, float(sprite["size"]))
			&"broadleaf":
				_draw_broadleaf(p, float(sprite["size"]))
			&"dead":
				_draw_dead_tree(p, float(sprite["size"]))
			&"rock":
				_draw_rock(p, float(sprite["size"]))
			&"mountain":
				_draw_mountain(p, float(sprite["size"]), float(sprite["height"]), bool(sprite["snow"]))
			&"hill":
				_draw_hill(p, float(sprite["size"]), float(sprite["height"]))
			&"tent":
				_draw_tent(p, float(sprite["size"]), sprite["color"])
			&"flag":
				_draw_flag(p, float(sprite["size"]), sprite["color"])


func _collect_tree_sprites() -> void:
	_rng.seed = 7010
	var ids: Array[int] = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
	for instance: Dictionary in _terrain_instances(ids):
		var id: int = int(instance["id"])
		var at: Vector2 = _px(instance["x"], instance["z"])
		var ground: float = float(instance["y"])
		var scale_value: float = float(instance["scale"])
		# El paso de la calzada detrás de cada puerta se queda despejado.
		if absf(float(instance["x"])) < 9.0 and absf(float(instance["z"])) > 148.0:
			continue
		if id >= 10:
			if ground > 30.0 or _shore_at(at) > -3.0:
				continue
			_add_sprite(&"rock", at, _m(1.15 * scale_value))
			continue
		if ground > FOREST_MAX_HEIGHT or _shore_at(at) > -6.0:
			continue
		var size: float = _m(6.0 * pow(scale_value, 0.85)) * 0.86
		var kind: StringName = &"pine" if id <= 4 else (&"broadleaf" if id <= 7 else &"dead")
		_add_sprite(kind, at, size * (1.12 if id <= 4 else 1.0))
		# Los bosquetes del valle son pocos árboles: en el mapa se dibujan con compañeros alrededor para
		# que se lean como bosque. Los del borde de la montaña ya son densos.
		var world_x: float = float(instance["x"])
		var world_z: float = float(instance["z"])
		if id <= 7 and absf(world_x) < 148.0 and absf(world_z) < 150.0:
			for k: int in 3:
				var angle: float = _rng.randf() * TAU
				var distance: float = _rng.randf_range(2.6, 6.5)
				var sx: float = world_x + cos(angle) * distance
				var sz: float = world_z + sin(angle) * distance
				var sat_at: Vector2 = _px(sx, sz)
				if _shore_at(sat_at) > -9.0 or Layout.road_distance(sx, sz) < 4.5 or Layout.fort_sdf(sx, sz) < 8.0 \
						or Layout.camp_distance(sx, sz) < 28.0 or _near_ruins(sx, sz):
					continue
				_add_sprite(kind, sat_at, size * _rng.randf_range(0.72, 0.95) * (1.12 if id <= 4 else 1.0))


## true si (x, z) cae en la aldea en ruinas o en la capilla.
func _near_ruins(x: float, z: float) -> bool:
	return Vector2(x, z).distance_to(Layout.VILLAGE_CENTER) < 30.0 or Vector2(x, z).distance_to(Layout.CHAPEL_CENTER) < 16.0 \
			or (x < -128.0 and absf(z) < 8.0)


func _shore_at(at: Vector2) -> float:
	var x: int = clampi(int(at.x), 0, _width - 1)
	var y: int = clampi(int(at.y), 0, _height - 1)
	return _shore[y * _width + x]


func _height_at(at: Vector2) -> float:
	var x: int = clampi(int(at.x), 0, _width - 1)
	var y: int = clampi(int(at.y), 0, _height - 1)
	return _heights[y * _width + x]


## Montañas: una rejilla de símbolos donde el terreno sube, más grandes cuanto más alto, sin tapar el río,
## los caminos, las murallas ni los campamentos.
func _collect_mountain_sprites() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7008
	var peak_noise := FastNoiseLite.new()
	peak_noise.seed = 77
	peak_noise.frequency = 0.034
	peak_noise.fractal_octaves = 2
	var step_x: float = 15.0
	var step_z: float = 9.6
	var row: int = 0
	var z: float = _def.world_origin.y - 6.0
	var end_z: float = _def.world_origin.y + _def.world_size.y + 14.0
	var mountains: int = 0
	var hills: int = 0
	while z < end_z:
		var x: float = _def.world_origin.x - 8.0 + (step_x * 0.5 if row % 2 == 1 else 0.0)
		while x < _def.world_origin.x + _def.world_size.x + 8.0:
			var jx: float = x + rng.randf_range(-0.36, 0.36) * step_x
			var jz: float = z + rng.randf_range(-0.36, 0.36) * step_z
			x += step_x
			var at: Vector2 = _px(jx, jz)
			var ground: float = _height_at(at)
			if ground < HILL_MIN_HEIGHT or not _mountain_allowed(jx, jz):
				continue
			var modulation: float = 0.70 + 0.62 * (peak_noise.get_noise_2d(jx, jz) * 0.5 + 0.5)
			var height_m: float = clampf(3.5 + (ground - 6.5) * 0.52, 4.0, 60.0) * modulation * rng.randf_range(0.88, 1.14)
			if height_m < 11.5:
				_add_sprite(&"hill", at + Vector2(0.0, _m(height_m) * 0.1), _m(height_m * rng.randf_range(2.4, 3.4)),
						{"height": _m(height_m)})
				hills += 1
				continue
			var width_m: float = height_m * rng.randf_range(1.15, 1.85)
			_add_sprite(&"mountain", at + Vector2(0.0, _m(height_m) * 0.12), _m(width_m),
					{"height": _m(height_m), "snow": ground > SNOW_MIN_HEIGHT and height_m > 24.0})
			mountains += 1
		z += step_z
		row += 1
	print("      %d montañas y %d lomas" % [mountains, hills])


func _mountain_allowed(x: float, z: float) -> bool:
	# Dentro del valle jugable no hay montañas: el relieve suave se dibuja con lavado y trazos.
	if absf(x) < Layout.PLAY_HALF - 14.0 and absf(z) < Layout.WALL_Z + 6.0:
		return false
	if Layout.river_distance(x, z) < 13.0:
		return false
	if Layout.road_distance(x, z) < 5.0:
		return false
	if absf(absf(z) - Layout.WALL_Z) < 6.0 and absf(x) < 160.0:
		return false
	if Layout.camp_distance(x, z) < 30.0:
		return false
	if absf(x) < 14.0 and absf(z) > 140.0:
		return false
	return true


## Color del follaje: más frío al norte (pinos de Vardheim) y más cálido al sur (Solmarch).
func _foliage(at: Vector2, dark: bool) -> Color:
	var south: float = clampf(at.y / float(_height), 0.0, 1.0)
	var base: Color = (FOLIAGE_DARK if dark else FOLIAGE_LIGHT)
	var cold: Color = Color(0.52, 0.66, 0.60) if not dark else Color(0.27, 0.42, 0.38)
	var warm: Color = Color(0.74, 0.76, 0.44) if not dark else Color(0.46, 0.50, 0.26)
	return base.lerp(cold.lerp(warm, south), 0.55).lerp(base, 0.0)


func _draw_pine(p: Vector2, height: float) -> void:
	var width: float = height * 0.56
	var light: Color = _foliage(p, false).lerp(PAPER, _rng.randf_range(0.0, 0.15))
	var dark: Color = _foliage(p, true)
	_ink_line(PackedVector2Array([p, p + Vector2(0.0, -height * 0.20)]), maxf(height * 0.07, 1.2), 0.9, INK,
			ParchmentCanvas.MODE_MULTIPLY, 0.3)
	# Sombra en el suelo.
	var ground_polys: Array[PackedVector2Array] = [ParchmentCanvas.ellipse(p + Vector2(width * 0.12, 0.0), width * 0.5, width * 0.16, 0.0, 12)]
	_fill(ground_polys, ParchmentCanvas.MODE_MULTIPLY, Color(0.50, 0.45, 0.38), 0.45, 0.0)
	for tier: int in 3:
		var y_base: float = p.y - height * (0.09 + 0.26 * float(tier))
		var y_apex: float = p.y - height * (0.46 + 0.27 * float(tier))
		var half: float = width * 0.5 * (1.0 - 0.24 * float(tier))
		var apex := Vector2(p.x + _rng.randf_range(-0.05, 0.05) * width, y_apex)
		var mid_y: float = lerpf(y_apex, y_base, 0.55)
		var shape := PackedVector2Array([apex, Vector2(p.x + half * 0.58, mid_y), Vector2(p.x + half * 0.42, mid_y + 0.5),
				Vector2(p.x + half, y_base), Vector2(p.x + half * 0.2, y_base - height * 0.045), Vector2(p.x - half * 0.1, y_base),
				Vector2(p.x - half, y_base), Vector2(p.x - half * 0.42, mid_y + 0.5), Vector2(p.x - half * 0.58, mid_y)])
		var polys: Array[PackedVector2Array] = [shape]
		_fill(polys, ParchmentCanvas.MODE_OVER, light, 0.97, 0.6)
		var shade := PackedVector2Array([apex, Vector2(p.x + half * 0.58, mid_y), Vector2(p.x + half * 0.42, mid_y + 0.5),
				Vector2(p.x + half, y_base), Vector2(p.x + half * 0.2, y_base - height * 0.045), Vector2(p.x + half * 0.04, y_base - height * 0.02)])
		var shade_polys: Array[PackedVector2Array] = [shade]
		_fill(shade_polys, ParchmentCanvas.MODE_OVER, dark, 0.62, 0.5)
		_ink_line(shape, maxf(height * 0.035, 0.85), 0.85, INK, ParchmentCanvas.MODE_MULTIPLY, 0.45, true)


func _draw_broadleaf(p: Vector2, height: float) -> void:
	var r: float = height * 0.30
	var light: Color = _foliage(p, false).lerp(Color(0.80, 0.78, 0.46), _rng.randf_range(0.0, 0.25))
	var dark: Color = _foliage(p, true)
	_ink_line(PackedVector2Array([p, p + Vector2(0.0, -height * 0.34)]), maxf(height * 0.08, 1.3), 0.9, INK,
			ParchmentCanvas.MODE_MULTIPLY, 0.3)
	var ground_polys: Array[PackedVector2Array] = [ParchmentCanvas.ellipse(p + Vector2(r * 0.35, 0.0), r * 1.1, r * 0.34, 0.0, 12)]
	_fill(ground_polys, ParchmentCanvas.MODE_MULTIPLY, Color(0.50, 0.45, 0.38), 0.42, 0.0)
	var lobes: Array[Vector3] = [Vector3(0.0, -0.66, 1.0), Vector3(-0.78, -0.50, 0.86), Vector3(0.80, -0.52, 0.86), Vector3(0.0, -0.40, 0.98)]
	for lobe: Vector3 in lobes:
		var center: Vector2 = p + Vector2(lobe.x * r, lobe.y * height * 0.9)
		var radius: float = r * lobe.z
		var base_polys: Array[PackedVector2Array] = [_blob(center, radius, 13)]
		_fill(base_polys, ParchmentCanvas.MODE_OVER, dark, 0.96, 0.6)
		var lit_polys: Array[PackedVector2Array] = [_blob(center + Vector2(-radius * 0.18, -radius * 0.2), radius * 0.82, 13)]
		_fill(lit_polys, ParchmentCanvas.MODE_OVER, light, 0.96, 0.6)
		_ink_line(base_polys[0], maxf(height * 0.035, 0.85), 0.82, INK, ParchmentCanvas.MODE_MULTIPLY, 0.45, true)
		# Hojas: trazos cortos en arco dentro de la copa.
		for leaf: int in 5:
			var inside: Vector2 = center + Vector2(_rng.randf_range(-0.5, 0.5), _rng.randf_range(-0.2, 0.7)) * radius
			for step: int in 3:
				_splat(inside.x + float(step) * radius * 0.16, inside.y + sin(float(step) * 1.4) * radius * 0.12,
						0.5, Color(0.24, 0.30, 0.16))


## Un círculo con el radio algo irregular (trazo a mano).
func _blob(center: Vector2, radius: float, segments: int) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	for i: int in segments:
		var angle: float = TAU * float(i) / float(segments)
		polygon.append(center + Vector2(cos(angle), sin(angle)) * radius * _rng.randf_range(0.90, 1.08))
	return ParchmentCanvas.smooth_closed(polygon, 3)


func _draw_dead_tree(p: Vector2, height: float) -> void:
	var bend: float = _rng.randf_range(-0.12, 0.12) * height
	var trunk: PackedVector2Array = ParchmentCanvas.smooth(PackedVector2Array([p, p + Vector2(bend * 0.5, -height * 0.4),
			p + Vector2(bend, -height * 0.85)]), 6)
	_ink_taper(trunk, maxf(height * 0.08, 1.5), 0.8, 0.92, INK, 0.3)
	for k: int in _rng.randi_range(3, 5):
		var at_t: float = _rng.randf_range(0.3, 0.9)
		var origin: Vector2 = p + Vector2(bend * at_t, -height * 0.9 * at_t)
		var direction: float = -1.0 if _rng.randf() < 0.5 else 1.0
		var tip: Vector2 = origin + Vector2(direction * _rng.randf_range(0.2, 0.42) * height, -_rng.randf_range(0.1, 0.3) * height)
		_ink_taper(PackedVector2Array([origin, origin.lerp(tip, 0.5) + Vector2(0.0, _rng.randf_range(-1.0, 1.0)), tip]),
				maxf(height * 0.045, 1.0), 0.45, 0.88, INK, 0.3)


func _draw_rock(p: Vector2, size: float) -> void:
	var points := PackedVector2Array()
	var count: int = 7
	for k: int in count:
		var angle: float = TAU * float(k) / float(count) + _rng.randf() * 0.35
		var reach: float = size * _rng.randf_range(0.78, 1.1)
		points.append(p + Vector2(cos(angle) * reach, sin(angle) * reach * 0.62 - size * 0.25))
	var polys: Array[PackedVector2Array] = [points]
	_fill(polys, ParchmentCanvas.MODE_OVER, STONE_LIGHT, 0.97, 0.7)
	var shade := PackedVector2Array([points[0], points[1], points[2], points[3], p + Vector2(0.0, -size * 0.1)])
	var shade_polys: Array[PackedVector2Array] = [shade]
	_fill(shade_polys, ParchmentCanvas.MODE_MULTIPLY, Color(0.64, 0.60, 0.56), 0.7, 0.0)
	_ink_line(points, maxf(size * 0.12, 0.9), 0.88, INK, ParchmentCanvas.MODE_MULTIPLY, 0.4, true)


func _draw_tent(p: Vector2, size: float, color: Color) -> void:
	var h: float = size * 0.78
	var ground_polys: Array[PackedVector2Array] = [ParchmentCanvas.ellipse(p + Vector2(size * 0.08, 1.0), size * 0.62, size * 0.17, 0.0, 14)]
	_fill(ground_polys, ParchmentCanvas.MODE_MULTIPLY, Color(0.48, 0.42, 0.34), 0.5, 0.0)
	var apex := Vector2(p.x, p.y - h)
	var left := Vector2(p.x - size * 0.5, p.y)
	var right := Vector2(p.x + size * 0.5, p.y)
	var body: PackedVector2Array = PackedVector2Array([apex, right, left])
	var body_polys: Array[PackedVector2Array] = [body]
	_fill(body_polys, ParchmentCanvas.MODE_OVER, color.lerp(PAPER, 0.15), 0.97, 0.5)
	var shade: PackedVector2Array = PackedVector2Array([apex, right, Vector2(p.x + size * 0.04, p.y)])
	var shade_polys: Array[PackedVector2Array] = [shade]
	_fill(shade_polys, ParchmentCanvas.MODE_MULTIPLY, Color(0.66, 0.62, 0.62), 0.7, 0.0)
	var door: PackedVector2Array = PackedVector2Array([Vector2(p.x - size * 0.02, p.y - h * 0.55), Vector2(p.x + size * 0.17, p.y),
			Vector2(p.x - size * 0.2, p.y)])
	var door_polys: Array[PackedVector2Array] = [door]
	_fill(door_polys, ParchmentCanvas.MODE_MULTIPLY, Color(0.30, 0.24, 0.22), 0.85, 0.0)
	# Franja clara de los faldones (blanco de la lana).
	_ink_line(PackedVector2Array([apex.lerp(left, 0.62), apex.lerp(right, 0.62)]), maxf(size * 0.08, 1.2), 0.5, SNOW,
			ParchmentCanvas.MODE_OVER, 0.0)
	_ink_line(body, maxf(size * 0.055, 1.2), 0.92, INK, ParchmentCanvas.MODE_MULTIPLY, 0.35, true)
	_ink_line(PackedVector2Array([apex, apex + Vector2(0.0, -size * 0.18)]), 1.1, 0.9, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3)


func _draw_flag(p: Vector2, height: float, color: Color) -> void:
	var top := Vector2(p.x, p.y - height)
	_ink_line(PackedVector2Array([p, top]), maxf(height * 0.045, 1.2), 0.92, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3)
	var length: float = height * 0.52
	var thick: float = height * 0.30
	var flag: PackedVector2Array = PackedVector2Array([top + Vector2(0.6, 0.0), top + Vector2(length * 0.55, thick * 0.12),
			top + Vector2(length, thick * 0.05), top + Vector2(length * 0.78, thick * 0.5), top + Vector2(length, thick * 0.95),
			top + Vector2(length * 0.55, thick * 0.88), top + Vector2(0.6, thick)])
	var polys: Array[PackedVector2Array] = [flag]
	_fill(polys, ParchmentCanvas.MODE_OVER, color, 0.97, 0.4)
	_ink_line(flag, maxf(height * 0.03, 0.9), 0.9, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3, true)
	var dot_polys: Array[PackedVector2Array] = [ParchmentCanvas.circle(top, maxf(height * 0.05, 1.3), 8)]
	_fill(dot_polys, ParchmentCanvas.MODE_OVER, INK, 0.95, 0.0)


# --- Montañas dibujadas -------------------------------------------------------------------------

## Una loma: un arco con la cara de la derecha en sombra y unos trazos cortos de rayado.
func _draw_hill(base: Vector2, width: float, height: float) -> void:
	var arc := PackedVector2Array()
	var samples: int = 12
	for k: int in samples + 1:
		var t: float = float(k) / float(samples)
		var lift: float = pow(sin(PI * t), 0.85) * height * (1.0 + _rng.randf_range(-0.05, 0.05))
		arc.append(Vector2(base.x - width * 0.5 + t * width, base.y - lift))
	var body := PackedVector2Array(arc)
	body.append(Vector2(base.x + width * 0.5, base.y + 1.0))
	body.append(Vector2(base.x - width * 0.5, base.y + 1.0))
	var body_polys: Array[PackedVector2Array] = [body]
	var body_mask: ParchmentCanvas.Mask = ParchmentCanvas.rasterize(body_polys)
	_canvas.paint_vertical_gradient(body_mask, Color(0.91, 0.87, 0.72), Color(0.80, 0.77, 0.58), 0.97, 0.7)
	var shade := PackedVector2Array()
	var split: int = int(samples * 0.52)
	for k: int in range(split, samples + 1):
		shade.append(arc[k])
	shade.append(Vector2(base.x + width * 0.5, base.y + 1.0))
	shade.append(Vector2(arc[split].x, base.y + 1.0))
	var shade_polys: Array[PackedVector2Array] = [shade]
	_canvas.paint(ParchmentCanvas.rasterize(shade_polys), ParchmentCanvas.MODE_MULTIPLY, Color(0.70, 0.66, 0.58), 0.65, 0.0)
	var hatch_polys: Array[PackedVector2Array] = []
	var x: float = arc[split].x + 2.0
	while x < base.x + width * 0.5 - 2.0:
		var top: Vector2 = Vector2(x, _arc_y(arc, x) + 1.5)
		var length: float = (base.y - top.y) * _rng.randf_range(0.45, 0.85)
		for polygon: PackedVector2Array in ParchmentCanvas.stroke_polygons(PackedVector2Array([top, top + Vector2(0.6, length)]),
				PackedFloat32Array([0.9]), false, false):
			hatch_polys.append(polygon)
		x += 3.0
	_canvas.paint(ParchmentCanvas.rasterize(hatch_polys), ParchmentCanvas.MODE_MULTIPLY, Color(0.26, 0.20, 0.14), 0.62, 0.0, 0.5)
	_ink_line(arc, clampf(width * 0.014, 1.0, 1.8), 0.9, INK, ParchmentCanvas.MODE_MULTIPLY, 0.45)


func _arc_y(arc: PackedVector2Array, x: float) -> float:
	for i: int in range(1, arc.size()):
		if arc[i].x >= x:
			var t: float = (x - arc[i - 1].x) / maxf(arc[i].x - arc[i - 1].x, 1e-6)
			return lerpf(arc[i - 1].y, arc[i].y, t)
	return arc[arc.size() - 1].y


## Una línea de [param from] a [param to] con picos y hondonadas, y el pie más abierto hacia fuera.
func _jagged_line(from: Vector2, to: Vector2, jag: float, flare: float, flare_at_start: bool, direction: float) -> PackedVector2Array:
	var points := PackedVector2Array([from])
	var segments: int = 5
	for k: int in range(1, segments):
		var t: float = float(k) / float(segments)
		var point: Vector2 = from.lerp(to, t)
		var perpendicular: Vector2 = Vector2(-(to - from).y, (to - from).x).normalized()
		point += perpendicular * jag * _rng.randf_range(-1.0, 1.0)
		var away: float = pow(1.0 - t, 2.2) if flare_at_start else pow(t, 2.2)
		point.x += direction * flare * away
		points.append(point)
	points.append(to)
	return points


## El punto a la fracción [param t] (0 a 1) de la longitud de [param line].
func _point_along(line: PackedVector2Array, t: float) -> Vector2:
	var total: float = ParchmentCanvas.length_of(line)
	var target: float = total * clampf(t, 0.0, 1.0)
	var travelled: float = 0.0
	for i: int in range(1, line.size()):
		var segment: float = line[i].distance_to(line[i - 1])
		if travelled + segment >= target and segment > 0.0:
			return line[i - 1].lerp(line[i], (target - travelled) / segment)
		travelled += segment
	return line[line.size() - 1]


func _draw_mountain(base: Vector2, width: float, height: float, snow: bool) -> void:
	# Las cumbres grandes llevan detrás un hombro más bajo, a un lado.
	if height > _m(26.0) and _rng.randf() < 0.65:
		var side: float = -1.0 if _rng.randf() < 0.5 else 1.0
		_draw_mountain_core(base + Vector2(side * width * 0.34, -height * 0.03), width * 0.62, height * _rng.randf_range(0.50, 0.68), false)
	_draw_mountain_core(base, width, height, snow)


func _draw_mountain_core(base: Vector2, width: float, height: float, snow: bool) -> void:
	# Lejos del valle los trazos se aclaran: el valle queda como protagonista.
	var from_center: float = base.distance_to(Vector2(float(_width) * 0.5, float(_height) * 0.5))
	var fade: float = _smoothstep(_m(170.0), _m(330.0), from_center)
	var ink_alpha: float = 0.90 - 0.26 * fade
	var peak := Vector2(base.x + _rng.randf_range(-0.20, 0.20) * width, base.y - height)
	var left_foot := Vector2(base.x - width * 0.5, base.y)
	var right_foot := Vector2(base.x + width * 0.5, base.y)
	var jag: float = width * 0.05
	var left: PackedVector2Array = _jagged_line(left_foot, peak, jag, width * 0.08, true, -1.0)
	var right: PackedVector2Array = _jagged_line(peak, right_foot, jag, width * 0.08, false, 1.0)
	var bottom := PackedVector2Array()
	for k: int in range(1, 5):
		var t: float = float(k) / 5.0
		bottom.append(right_foot.lerp(left_foot, t) + Vector2(0.0, _rng.randf_range(-1.0, 2.0) + sin(t * PI) * 1.5))
	var body := PackedVector2Array()
	body.append_array(left)
	for i: int in range(1, right.size()):
		body.append(right[i])
	body.append_array(bottom)
	# Cresta: la línea que separa la cara iluminada de la que está en sombra.
	var ridge_foot := Vector2(base.x + width * _rng.randf_range(0.0, 0.13), base.y + 1.0)
	var ridge := PackedVector2Array([peak])
	for k: int in range(1, 5):
		var t: float = float(k) / 5.0
		ridge.append(peak.lerp(ridge_foot, t) + Vector2(_rng.randf_range(-1.0, 1.0) * jag * 1.2, 0.0))
	ridge.append(ridge_foot)
	var shadow := PackedVector2Array()
	for i: int in right.size():
		shadow.append(right[i])
	shadow.append(ridge_foot)
	for i: int in range(ridge.size() - 2, -1, -1):
		shadow.append(ridge[i])
	# Cuerpo: papel claro arriba, más cálido abajo (tapa lo que hay detrás).
	var body_polys: Array[PackedVector2Array] = [body]
	var body_mask: ParchmentCanvas.Mask = ParchmentCanvas.rasterize(body_polys)
	var tone: float = _rng.randf_range(-0.04, 0.04)
	_canvas.paint_vertical_gradient(body_mask, Color(0.93, 0.89, 0.77).lerp(PAPER, 0.20 * fade + tone),
			Color(0.83, 0.77, 0.61).lerp(PAPER, 0.20 * fade + tone), 0.97, 0.7)
	# Pie verdoso: la ladera baja se funde con el bosque.
	var foot_polys: Array[PackedVector2Array] = [PackedVector2Array([Vector2(left_foot.x - 6.0, base.y - height * 0.30),
			Vector2(right_foot.x + 6.0, base.y - height * 0.30), Vector2(right_foot.x + 6.0, base.y + 4.0),
			Vector2(left_foot.x - 6.0, base.y + 4.0)])]
	var foot_mask: ParchmentCanvas.Mask = ParchmentCanvas.rasterize(foot_polys)
	if foot_mask != null and body_mask != null:
		_canvas.paint(foot_mask.intersect(body_mask), ParchmentCanvas.MODE_MULTIPLY, Color(0.82, 0.88, 0.70), 0.55, 0.0)
	var hatch_from: float = 0.10
	if snow:
		var snow_fraction: float = _rng.randf_range(0.28, 0.40)
		var left_cut: Vector2 = _point_along(left, 1.0 - snow_fraction)
		var right_cut: Vector2 = _point_along(right, snow_fraction)
		var cap := PackedVector2Array([peak])
		var teeth: int = 6
		cap.append(left_cut)
		for k: int in range(1, teeth):
			var t: float = float(k) / float(teeth)
			var drop: float = (_rng.randf_range(0.35, 1.0) if k % 2 == 1 else _rng.randf_range(-0.2, 0.3)) * height * 0.07
			cap.append(left_cut.lerp(right_cut, t) + Vector2(0.0, drop))
		cap.append(right_cut)
		var cap_polys: Array[PackedVector2Array] = [cap]
		_fill(cap_polys, ParchmentCanvas.MODE_OVER, SNOW, 0.97, 0.8)
		hatch_from = snow_fraction + 0.06
		_ink_line(cap.slice(1, cap.size()), maxf(width * 0.012, 0.9), 0.55, INK_SOFT, ParchmentCanvas.MODE_MULTIPLY, 0.5)
	# Cara en sombra: aguada fría y rayado.
	var shadow_polys: Array[PackedVector2Array] = [shadow]
	var shadow_mask: ParchmentCanvas.Mask = ParchmentCanvas.rasterize(shadow_polys)
	_canvas.paint(shadow_mask, ParchmentCanvas.MODE_MULTIPLY, Color(0.60, 0.55, 0.55), 0.74, 0.0)
	var line_width: float = clampf(width * 0.0085, 0.75, 1.15)
	var spacing: float = clampf(width * 0.042, 3.0, 5.0)
	var ridge_length: float = ParchmentCanvas.length_of(ridge)
	var lines: int = int(ridge_length / spacing)
	var hatch_polys: Array[PackedVector2Array] = []
	for k: int in lines:
		var t: float = hatch_from + (0.99 - hatch_from) * float(k) / float(maxi(lines - 1, 1))
		var start: Vector2 = _point_along(ridge, t) + Vector2(1.0, 0.0)
		var finish: Vector2 = _point_along(right, t)
		var length_factor: float = _rng.randf_range(0.55, 0.97)
		var end_point: Vector2 = start.lerp(finish, length_factor)
		var segment_points := PackedVector2Array([start, start.lerp(end_point, 0.5) + Vector2(0.0, _rng.randf_range(-0.8, 0.8)), end_point])
		for polygon: PackedVector2Array in ParchmentCanvas.stroke_polygons(segment_points, PackedFloat32Array([line_width]), false, false):
			hatch_polys.append(polygon)
	_canvas.paint(ParchmentCanvas.rasterize(hatch_polys), ParchmentCanvas.MODE_MULTIPLY, Color(0.26, 0.19, 0.13), 0.78 * (1.0 - 0.3 * fade), 0.0, 0.5)
	# Grietas en la cara iluminada.
	for k: int in _rng.randi_range(2, 4):
		var t: float = _rng.randf_range(0.25, 0.75)
		var origin: Vector2 = _point_along(left, 1.0 - t * 0.5).lerp(_point_along(ridge, t * 0.7), 0.35)
		var direction: Vector2 = Vector2(_rng.randf_range(-0.2, 0.35), 1.0).normalized()
		var tip: Vector2 = origin + direction * height * _rng.randf_range(0.14, 0.26)
		_ink_taper(PackedVector2Array([origin, origin.lerp(tip, 0.5) + Vector2(_rng.randf_range(-1.5, 1.5), 0.0), tip]), 1.0, 0.4, 0.5, INK_SOFT, 0.5)
	# Contorno y cresta.
	var outline := PackedVector2Array()
	outline.append_array(left)
	for i: int in range(1, right.size()):
		outline.append(right[i])
	_ink_line(outline, clampf(width * 0.0125, 1.0, 1.7), ink_alpha, INK_SOFT.darkened(0.35), ParchmentCanvas.MODE_MULTIPLY, 0.5)
	_ink_line(ridge, clampf(width * 0.008, 0.75, 1.2), ink_alpha * 0.8, INK_SOFT.darkened(0.2), ParchmentCanvas.MODE_MULTIPLY, 0.55)


# --- 8. Adornos: rosa de los vientos, escala, marco y bordes ------------------------------------

## Rosa de los vientos de 16 rumbos con el norte arriba y una flor de lis, en la esquina suroeste.
func _paint_compass_rose() -> void:
	var center: Vector2 = _px(_def.world_origin.x + 42.0, _def.world_origin.y + _def.world_size.y - 44.0)
	var radius: float = _m(25.0)
	# Parche de papel liso para que la rosa se lea sobre las montañas, con el borde difuso.
	for ring: int in 5:
		var polys: Array[PackedVector2Array] = [ParchmentCanvas.circle(center, radius * (1.42 - 0.06 * float(ring)), 48)]
		_fill(polys, ParchmentCanvas.MODE_OVER, Color(0.86, 0.78, 0.60), 0.20 + 0.10 * float(ring), 0.9)
	# Anillos y graduación.
	for ring_data: Vector2 in [Vector2(1.0, 1.7), Vector2(0.86, 0.9), Vector2(0.60, 0.7)]:
		_ink_line(ParchmentCanvas.circle(center, radius * ring_data.x, 64), ring_data.y, 0.92, INK,
				ParchmentCanvas.MODE_MULTIPLY, 0.3, true)
	for k: int in 64:
		var angle: float = TAU * float(k) / 64.0 - PI * 0.5
		var direction := Vector2(cos(angle), sin(angle))
		var inner: float = 0.86 if k % 4 != 0 else 0.80
		_ink_line(PackedVector2Array([center + direction * radius * inner, center + direction * radius * 0.995]),
				1.3 if k % 4 == 0 else 0.8, 0.85, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3)
	# Puntas: de las menores a las mayores.
	for level: int in 3:
		for k: int in 16:
			var kind: int = 0 if k % 4 == 0 else (1 if k % 2 == 0 else 2)
			if (level == 0 and kind != 2) or (level == 1 and kind != 1) or (level == 2 and kind != 0):
				continue
			var angle: float = TAU * float(k) / 16.0 - PI * 0.5
			var direction := Vector2(cos(angle), sin(angle))
			var perpendicular := Vector2(-direction.y, direction.x)
			var length: float = radius * (1.06 if kind == 0 else (0.76 if kind == 1 else 0.50))
			var half_base: float = radius * (0.115 if kind == 0 else (0.085 if kind == 1 else 0.055))
			var tip: Vector2 = center + direction * length
			var side_a: Vector2 = center + perpendicular * half_base + direction * length * 0.20
			var side_b: Vector2 = center - perpendicular * half_base + direction * length * 0.20
			var left_polys: Array[PackedVector2Array] = [PackedVector2Array([center, side_a, tip])]
			var right_polys: Array[PackedVector2Array] = [PackedVector2Array([center, tip, side_b])]
			_fill(left_polys, ParchmentCanvas.MODE_OVER, Color(0.24, 0.17, 0.12), 0.92, 0.4)
			_fill(right_polys, ParchmentCanvas.MODE_OVER, Color(0.95, 0.91, 0.80), 0.97, 0.7)
			_ink_line(PackedVector2Array([center, side_a, tip, side_b]), 1.0, 0.92, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3, true)
	var hub_polys: Array[PackedVector2Array] = [ParchmentCanvas.circle(center, radius * 0.09, 14)]
	_fill(hub_polys, ParchmentCanvas.MODE_OVER, Color(0.82, 0.62, 0.20), 0.95, 0.4)
	_ink_line(hub_polys[0], 1.1, 0.92, INK, ParchmentCanvas.MODE_MULTIPLY, 0.3, true)
	# Flor de lis sobre el norte.
	var lily: Vector2 = center + Vector2(0.0, -radius * 1.30)
	var unit: float = radius * 0.30
	var petals: Array[PackedVector2Array] = []
	var central: Array[Vector2] = [Vector2(0.0, -1.05), Vector2(0.17, -0.62), Vector2(0.15, -0.12), Vector2(0.06, 0.26),
			Vector2(-0.06, 0.26), Vector2(-0.15, -0.12), Vector2(-0.17, -0.62)]
	# Pétalos laterales: hojas que salen del tallo, se abren hacia fuera y vuelven a curvarse hacia arriba.
	var side: Array[Vector2] = [Vector2(0.12, 0.10), Vector2(0.30, -0.10), Vector2(0.62, -0.18), Vector2(0.92, -0.42),
			Vector2(0.98, -0.12), Vector2(0.78, 0.14), Vector2(0.44, 0.22)]
	petals.append(_unit_shape(central, lily, unit, 1.0))
	petals.append(_unit_shape(side, lily, unit, 1.0))
	petals.append(_unit_shape(side, lily, unit, -1.0))
	petals.append(ParchmentCanvas.box(lily + Vector2(0.0, unit * 0.40), unit * 0.50, unit * 0.07))
	var stem: Array[Vector2] = [Vector2(-0.12, 0.50), Vector2(0.12, 0.50), Vector2(0.0, 0.90)]
	petals.append(_unit_shape(stem, lily, unit, 1.0, false))
	# Cada pieza por separado: con el relleno de enrollamiento, la espejada (de sentido contrario) restaría.
	for petal: PackedVector2Array in petals:
		var single: Array[PackedVector2Array] = [petal]
		_fill(single, ParchmentCanvas.MODE_OVER, Color(0.22, 0.16, 0.11), 0.94, 0.3)


## Una forma dada en unidades de [param unit] px alrededor de [param origin] (y hacia arriba es negativa),
## espejada en x si [param mirror] es -1, con las esquinas suavizadas si [param smoothed].
func _unit_shape(points: Array[Vector2], origin: Vector2, unit: float, mirror: float, smoothed: bool = true) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	for p: Vector2 in points:
		polygon.append(origin + Vector2(p.x * mirror, p.y) * unit)
	if mirror < 0.0:
		polygon.reverse()
	return ParchmentCanvas.smooth_closed(polygon, 6) if smoothed else polygon


## Rectángulo de esquinas redondeadas ([param radius] de esquina).
func _rounded_rect(center: Vector2, half_x: float, half_y: float, radius: float) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	var corners: Array[Vector2] = [Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1), Vector2(1, -1)]
	var starts: Array[float] = [0.0, PI * 0.5, PI, PI * 1.5]
	for c: int in 4:
		var corner: Vector2 = center + Vector2(corners[c].x * (half_x - radius), corners[c].y * (half_y - radius))
		for k: int in 6:
			var angle: float = starts[c] + (PI * 0.5) * float(k) / 5.0
			polygon.append(corner + Vector2(cos(angle), sin(angle)) * radius)
	return polygon


## Barra de escala de 100 m (cinco tramos de 20 m, el primero con marcas de 5 m) en la esquina sureste.
func _paint_scale_bar() -> void:
	var span: float = 100.0
	var x1: float = _def.world_origin.x + _def.world_size.x - 38.0
	var x0: float = x1 - span
	var z: float = _def.world_origin.y + _def.world_size.y - 30.0
	var patch_center: Vector2 = _px((x0 + x1) * 0.5, z - 1.0)
	for ring: int in 7:
		var grow: float = _m(0.9) * float(6 - ring)
		var polys: Array[PackedVector2Array] = [_rounded_rect(patch_center, _m(span * 0.5 + 9.0) + grow, _m(9.0) + grow, _m(7.0) + grow * 0.5)]
		_fill(polys, ParchmentCanvas.MODE_OVER, Color(0.86, 0.78, 0.60), 0.15 + 0.07 * float(ring), 0.9)
	var bar_h: float = 1.3
	for segment: int in 5:
		var sx0: float = x0 + 20.0 * float(segment)
		var cell: PackedVector2Array = PackedVector2Array([_px(sx0, z - bar_h), _px(sx0 + 20.0, z - bar_h), _px(sx0 + 20.0, z + bar_h), _px(sx0, z + bar_h)])
		if segment % 2 == 0:
			var polys: Array[PackedVector2Array] = [cell]
			_fill(polys, ParchmentCanvas.MODE_OVER, Color(0.22, 0.16, 0.11), 0.94, 0.3)
	_ink_line(PackedVector2Array([_px(x0, z - bar_h), _px(x1, z - bar_h), _px(x1, z + bar_h), _px(x0, z + bar_h)]),
			_line(0.30, 1.3), 0.95, INK, ParchmentCanvas.MODE_MULTIPLY, 0.2, true)
	for tick: int in 6:
		var tx: float = x0 + 20.0 * float(tick)
		_ink_line(PackedVector2Array([_px(tx, z - bar_h - 2.2), _px(tx, z - bar_h)]), _line(0.28, 1.2), 0.92, INK,
				ParchmentCanvas.MODE_MULTIPLY, 0.2)
	for tick: int in range(1, 4):
		var tx: float = x0 + 5.0 * float(tick)
		_ink_line(PackedVector2Array([_px(tx, z + bar_h), _px(tx, z + bar_h + 1.6)]), _line(0.22, 1.0), 0.85, INK,
				ParchmentCanvas.MODE_MULTIPLY, 0.2)


## Marco doble con una banda de graduación alterna y adornos en las esquinas.
func _paint_frame() -> void:
	var outer: float = _m(1.9)
	var inner: float = _m(4.6)
	var w: float = float(_width)
	var h: float = float(_height)
	# Cenefa: banda entre las dos líneas, sobre papel liso.
	var strips: Array[PackedVector2Array] = [
			PackedVector2Array([Vector2(outer, outer), Vector2(w - outer, outer), Vector2(w - outer, inner), Vector2(outer, inner)]),
			PackedVector2Array([Vector2(outer, h - inner), Vector2(w - outer, h - inner), Vector2(w - outer, h - outer), Vector2(outer, h - outer)]),
			PackedVector2Array([Vector2(outer, inner), Vector2(inner, inner), Vector2(inner, h - inner), Vector2(outer, h - inner)]),
			PackedVector2Array([Vector2(w - inner, inner), Vector2(w - outer, inner), Vector2(w - outer, h - inner), Vector2(w - inner, h - inner)])]
	for strip: PackedVector2Array in strips:
		# Cada franja se parte en trozos para que la máscara no pase del tamaño máximo.
		var low := Vector2(INF, INF)
		var high := Vector2(-INF, -INF)
		for p: Vector2 in strip:
			low = low.min(p)
			high = high.max(p)
		var long_axis_is_x: bool = (high.x - low.x) > (high.y - low.y)
		var length: float = (high.x - low.x) if long_axis_is_x else (high.y - low.y)
		var pieces: int = maxi(ceili(length / 480.0), 1)
		for k: int in pieces:
			var t0: float = float(k) / float(pieces)
			var t1: float = float(k + 1) / float(pieces)
			var piece: PackedVector2Array
			if long_axis_is_x:
				var x0: float = lerpf(low.x, high.x, t0)
				var x1: float = lerpf(low.x, high.x, t1) + 1.0
				piece = PackedVector2Array([Vector2(x0, low.y), Vector2(x1, low.y), Vector2(x1, high.y), Vector2(x0, high.y)])
			else:
				var y0: float = lerpf(low.y, high.y, t0)
				var y1: float = lerpf(low.y, high.y, t1) + 1.0
				piece = PackedVector2Array([Vector2(low.x, y0), Vector2(high.x, y0), Vector2(high.x, y1), Vector2(low.x, y1)])
			var piece_polys: Array[PackedVector2Array] = [piece]
			_fill(piece_polys, ParchmentCanvas.MODE_OVER, Color(0.84, 0.76, 0.58), 0.95, 0.9)
	# Graduación: tramos alternos de 12,5 m.
	var block: float = _m(12.5)
	var inset: float = _m(0.55)
	var blocks: int = int(w / block)
	for k: int in blocks:
		if k % 2 != 0:
			continue
		var x0: float = float(k) * block + (w - float(blocks) * block) * 0.5
		var cells: Array[PackedVector2Array] = []
		cells.append(PackedVector2Array([Vector2(x0, outer + inset), Vector2(x0 + block, outer + inset), Vector2(x0 + block, inner - inset), Vector2(x0, inner - inset)]))
		cells.append(PackedVector2Array([Vector2(x0, h - inner + inset), Vector2(x0 + block, h - inner + inset), Vector2(x0 + block, h - outer - inset), Vector2(x0, h - outer - inset)]))
		cells.append(PackedVector2Array([Vector2(outer + inset, x0), Vector2(inner - inset, x0), Vector2(inner - inset, x0 + block), Vector2(outer + inset, x0 + block)]))
		cells.append(PackedVector2Array([Vector2(w - inner + inset, x0), Vector2(w - outer - inset, x0), Vector2(w - outer - inset, x0 + block), Vector2(w - inner + inset, x0 + block)]))
		for cell: PackedVector2Array in cells:
			var cell_polys: Array[PackedVector2Array] = [cell]
			_fill(cell_polys, ParchmentCanvas.MODE_OVER, Color(0.24, 0.17, 0.12), 0.88, 0.3)
	_ink_line(PackedVector2Array([Vector2(outer, outer), Vector2(w - outer, outer), Vector2(w - outer, h - outer), Vector2(outer, h - outer)]),
			_line(0.7, 3.0), 0.96, INK, ParchmentCanvas.MODE_MULTIPLY, 0.15, true)
	_ink_line(PackedVector2Array([Vector2(inner, inner), Vector2(w - inner, inner), Vector2(w - inner, h - inner), Vector2(inner, h - inner)]),
			_line(0.30, 1.4), 0.95, INK, ParchmentCanvas.MODE_MULTIPLY, 0.15, true)
	# Esquinas: cuadrado con rombo.
	for corner: Vector2 in [Vector2(outer, outer), Vector2(w - outer, outer), Vector2(w - outer, h - outer), Vector2(outer, h - outer)]:
		var toward: Vector2 = Vector2(1.0 if corner.x < w * 0.5 else -1.0, 1.0 if corner.y < h * 0.5 else -1.0)
		var square_center: Vector2 = corner + toward * (inner - outer) * 0.5
		var s: float = (inner - outer) * 0.5
		var square_polys: Array[PackedVector2Array] = [ParchmentCanvas.box(square_center, s * 1.05, s * 1.05)]
		_fill(square_polys, ParchmentCanvas.MODE_OVER, Color(0.84, 0.76, 0.58), 0.98, 0.9)
		_ink_line(square_polys[0], _line(0.30, 1.4), 0.95, INK, ParchmentCanvas.MODE_MULTIPLY, 0.15, true)
		var diamond: PackedVector2Array = PackedVector2Array([square_center + Vector2(0.0, -s * 0.62), square_center + Vector2(s * 0.62, 0.0),
				square_center + Vector2(0.0, s * 0.62), square_center + Vector2(-s * 0.62, 0.0)])
		var diamond_polys: Array[PackedVector2Array] = [diamond]
		_fill(diamond_polys, ParchmentCanvas.MODE_OVER, Color(0.70, 0.30, 0.20), 0.9, 0.4)
		_ink_line(diamond, 1.0, 0.9, INK, ParchmentCanvas.MODE_MULTIPLY, 0.2, true)


## Bordes quemados, viñeta suave, pliegues de doblar el mapa en cuatro y motas de tinta.
func _age_edges() -> void:
	var fk: float = _fk()
	var burn_noise: PackedByteArray = ParchmentCanvas.noise_bytes(501, 0.012 * fk, 4, _width, _height)
	var burn_fine: PackedByteArray = ParchmentCanvas.noise_bytes(502, 0.060 * fk, 3, _width, _height)
	var reach: float = _m(26.0)
	var center_x: float = float(_width) * 0.5
	var center_y: float = float(_height) * 0.5
	var max_radius: float = sqrt(center_x * center_x + center_y * center_y)
	var brown: Color = Color(0.46, 0.30, 0.17)
	for y: int in _height:
		var row: int = y * _width
		var dy: float = absf(float(y) - center_y)
		for x: int in _width:
			var i: int = row + x
			var edge: float = float(mini(mini(x, y), mini(_width - 1 - x, _height - 1 - y)))
			var noise: float = _byte01(burn_noise, i)
			var fine: float = _byte01(burn_fine, i)
			var t: float = 1.0 - _smoothstep(0.0, reach * (0.55 + 0.95 * noise), edge)
			var burn: float = t * t * (0.75 + 0.25 * fine)
			var dx: float = absf(float(x) - center_x)
			var radial: float = _smoothstep(0.42, 1.0, sqrt(dx * dx + dy * dy) / max_radius)
			var factor_r: float = lerpf(1.0, brown.r, clampf(burn * 0.95, 0.0, 1.0)) * (1.0 - 0.14 * radial)
			var factor_g: float = lerpf(1.0, brown.g, clampf(burn * 0.95, 0.0, 1.0)) * (1.0 - 0.15 * radial)
			var factor_b: float = lerpf(1.0, brown.b, clampf(burn * 0.95, 0.0, 1.0)) * (1.0 - 0.17 * radial)
			# Pliegues: una raya fina y su brillo, en el centro, con sombra suave a un lado.
			var fold: float = minf(dx, dy)
			var crease: float = clampf(1.0 - fold / (_ppm * 0.28), 0.0, 1.0)
			var glow: float = clampf(1.0 - absf(fold - _ppm * 0.7) / (_ppm * 0.5), 0.0, 1.0)
			var side: float = (1.0 - _smoothstep(0.0, _m(6.0), fold)) * 0.03
			var fold_factor: float = 1.0 - crease * 0.045 + glow * 0.02 - side
			factor_r *= fold_factor
			factor_g *= fold_factor
			factor_b *= fold_factor
			var out_r: float = _canvas.r[i] * factor_r
			var out_g: float = _canvas.g[i] * factor_g
			var out_b: float = _canvas.b[i] * factor_b
			# Entonación final: un poco menos saturado, como la gama apagada del juego.
			var luma: float = out_r * 0.30 + out_g * 0.59 + out_b * 0.11
			_canvas.r[i] = clampf(lerpf(out_r, luma, FINAL_DESATURATION), 0.0, 1.0)
			_canvas.g[i] = clampf(lerpf(out_g, luma, FINAL_DESATURATION), 0.0, 1.0)
			_canvas.b[i] = clampf(lerpf(out_b, luma, FINAL_DESATURATION), 0.0, 1.0)
	# Motas de tinta sueltas.
	_rng.seed = 7009
	for k: int in int(380.0 * float(_width * _height) / 4194304.0):
		var at := Vector2(_rng.randf() * _width, _rng.randf() * _height)
		var polys: Array[PackedVector2Array] = [ParchmentCanvas.circle(at, _rng.randf_range(0.5, 1.4) * _ppm / 4.0, 7)]
		_canvas.paint(ParchmentCanvas.rasterize(polys), ParchmentCanvas.MODE_MULTIPLY, Color(0.30, 0.22, 0.14), _rng.randf_range(0.2, 0.55), 0.0)
