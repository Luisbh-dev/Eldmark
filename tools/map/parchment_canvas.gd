class_name ParchmentCanvas
extends RefCounted
## Lienzo de coma flotante y rasterizador de [ParchmentMapBaker] (UI-51). Todo se calcula en la CPU y
## sin GPU, así que el resultado es el mismo en cualquier máquina y vale en headless.
## [br][br]
## [b]Lienzo[/b]: tres canales ([member r], [member g], [member b]) de 0 a 1 en sRGB y dos mapas del
## tamaño de la imagen: [member grain] (variación del papel, media 1) y [member wear] (0 a 1, dónde se
## salta la tinta, como en un papel viejo).
## [br][br]
## [b]Formas[/b]: [method rasterize] convierte polígonos cualesquiera (cóncavos, con agujeros, anillos)
## en una [ParchmentCanvas.Mask] de cobertura exacta por área, sin escalones. Una línea gruesa, un punteado
## o un círculo son polígonos ([method stroke_polygons], [method dash], [method circle]). Después
## [method paint] extiende la máscara sobre el lienzo con un modo de mezcla.
## [br][br]
## [b]Modos[/b]: [constant MODE_OVER] cubre (gouache); [constant MODE_MULTIPLY] oscurece o tiñe como
## lo haría una aguada o la tinta, y deja ver las fibras del papel.

## Cubre lo que hay debajo (con el grano del papel).
const MODE_OVER: int = 0
## Multiplica lo que hay debajo por el color (la tinta y las aguadas). El color puede pasar de 1.
const MODE_MULTIPLY: int = 1

## Lado máximo de una máscara (px); las líneas largas se parten antes para no pasar de aquí.
const MAX_MASK_SIDE: int = 1100
## Segmentos de un semicírculo en las puntas redondas.
const CAP_SEGMENTS: int = 6
## Longitud máxima (px) de un tramo recto de una línea antes de partirlo.
const MAX_SEGMENT: float = 48.0

## Una máscara de cobertura (0 a 1) sobre un rectángulo del lienzo.
class Mask extends RefCounted:
	var x0: int = 0
	var y0: int = 0
	var w: int = 0
	var h: int = 0
	var a: PackedFloat32Array = PackedFloat32Array()


	## La parte común de esta máscara y [param other], con la cobertura multiplicada; null si no se tocan.
	func intersect(other: Mask) -> Mask:
		var nx0: int = maxi(x0, other.x0)
		var ny0: int = maxi(y0, other.y0)
		var nx1: int = mini(x0 + w, other.x0 + other.w)
		var ny1: int = mini(y0 + h, other.y0 + other.h)
		if nx1 <= nx0 or ny1 <= ny0:
			return null
		var result := Mask.new()
		result.x0 = nx0
		result.y0 = ny0
		result.w = nx1 - nx0
		result.h = ny1 - ny0
		result.a.resize(result.w * result.h)
		for y: int in result.h:
			var row_a: int = (ny0 + y - y0) * w + (nx0 - x0)
			var row_b: int = (ny0 + y - other.y0) * other.w + (nx0 - other.x0)
			var row_out: int = y * result.w
			for x: int in result.w:
				result.a[row_out + x] = a[row_a + x] * other.a[row_b + x]
		return result


	## Multiplica toda la cobertura por [param factor].
	func scale(factor: float) -> void:
		for i: int in a.size():
			a[i] *= factor

var width: int = 0
var height: int = 0
var r: PackedFloat32Array = PackedFloat32Array()
var g: PackedFloat32Array = PackedFloat32Array()
var b: PackedFloat32Array = PackedFloat32Array()
## Variación de brillo del papel (media 1): la aguada cubriente la conserva.
var grain: PackedFloat32Array = PackedFloat32Array()
## 0 a 1: dónde falla la tinta (1 = no pinta).
var wear: PackedFloat32Array = PackedFloat32Array()


func _init(p_width: int, p_height: int) -> void:
	width = p_width
	height = p_height
	var count: int = width * height
	r.resize(count)
	g.resize(count)
	b.resize(count)
	grain.resize(count)
	grain.fill(1.0)
	wear.resize(count)


# --- Pintar -------------------------------------------------------------------------------------

## Extiende [param mask] sobre el lienzo. [param alpha] multiplica la cobertura. [param grain_strength]
## (solo en [constant MODE_OVER]) cuánto del grano del papel se ve en lo pintado; [param wear_strength],
## cuánto falla la tinta donde [member wear] es alto. [param hole] (del tamaño del lienzo, 0 a 1) quita
## lo pintado donde vale 1 (la calzada no se pinta sobre el agua).
func paint(mask: Mask, mode: int, color: Color, alpha: float = 1.0, grain_strength: float = 0.5,
		wear_strength: float = 0.0, hole: PackedFloat32Array = PackedFloat32Array()) -> void:
	if mask == null:
		return
	var cr: float = color.r
	var cg: float = color.g
	var cb: float = color.b
	var mw: int = mask.w
	var use_hole: bool = not hole.is_empty()
	for my: int in mask.h:
		var cy: int = mask.y0 + my
		if cy < 0 or cy >= height:
			continue
		var row_m: int = my * mw
		var row_c: int = cy * width
		for mx: int in mw:
			var cover: float = mask.a[row_m + mx]
			if cover < 0.004:
				continue
			var cx: int = mask.x0 + mx
			if cx < 0 or cx >= width:
				continue
			var i: int = row_c + cx
			var a: float = cover * alpha
			if wear_strength > 0.0:
				a *= 1.0 - wear_strength * wear[i]
			if use_hole:
				a *= 1.0 - hole[i]
			if mode == MODE_OVER:
				var gr: float = 1.0 - grain_strength + grain_strength * grain[i]
				var inv: float = 1.0 - a
				r[i] = r[i] * inv + cr * gr * a
				g[i] = g[i] * inv + cg * gr * a
				b[i] = b[i] * inv + cb * gr * a
			else:
				r[i] *= 1.0 + (cr - 1.0) * a
				g[i] *= 1.0 + (cg - 1.0) * a
				b[i] *= 1.0 + (cb - 1.0) * a


## Pinta un degradado vertical dentro de [param mask]: [param top] arriba y [param bottom] abajo (del
## rectángulo de la máscara). Siempre cubre ([constant MODE_OVER]).
func paint_vertical_gradient(mask: Mask, top: Color, bottom: Color, alpha: float = 1.0,
		grain_strength: float = 0.5) -> void:
	if mask == null:
		return
	for my: int in mask.h:
		var cy: int = mask.y0 + my
		if cy < 0 or cy >= height:
			continue
		var t: float = float(my) / float(maxi(mask.h - 1, 1))
		var color: Color = top.lerp(bottom, t)
		var row_m: int = my * mask.w
		var row_c: int = cy * width
		for mx: int in mask.w:
			var cover: float = mask.a[row_m + mx]
			if cover < 0.004:
				continue
			var cx: int = mask.x0 + mx
			if cx < 0 or cx >= width:
				continue
			var i: int = row_c + cx
			var a: float = cover * alpha
			var gr: float = 1.0 - grain_strength + grain_strength * grain[i]
			var inv: float = 1.0 - a
			r[i] = r[i] * inv + color.r * gr * a
			g[i] = g[i] * inv + color.g * gr * a
			b[i] = b[i] * inv + color.b * gr * a


## Como [method paint], pero la opacidad va de [param alpha_top] a [param alpha_bottom] en vertical a lo largo
## del rectángulo de la máscara, entre sus fracciones [param t0] y [param t1] de alto (fuera de ese tramo vale
## la del extremo más cercano). Sirve para fundir una forma con el papel por abajo sin dejar un borde duro.
func paint_ramp(mask: Mask, mode: int, color: Color, alpha_top: float, alpha_bottom: float, t0: float = 0.0,
		t1: float = 1.0, grain_strength: float = 0.5) -> void:
	if mask == null:
		return
	var span: float = maxf(t1 - t0, 1e-4)
	for my: int in mask.h:
		var cy: int = mask.y0 + my
		if cy < 0 or cy >= height:
			continue
		var t: float = clampf((float(my) / float(maxi(mask.h - 1, 1)) - t0) / span, 0.0, 1.0)
		t = t * t * (3.0 - 2.0 * t)
		var row_alpha: float = lerpf(alpha_top, alpha_bottom, t)
		if row_alpha <= 0.002:
			continue
		var row_m: int = my * mask.w
		var row_c: int = cy * width
		for mx: int in mask.w:
			var cover: float = mask.a[row_m + mx]
			if cover < 0.004:
				continue
			var cx: int = mask.x0 + mx
			if cx < 0 or cx >= width:
				continue
			var i: int = row_c + cx
			var a: float = cover * row_alpha
			if mode == MODE_OVER:
				var gr: float = 1.0 - grain_strength + grain_strength * grain[i]
				var inv: float = 1.0 - a
				r[i] = r[i] * inv + color.r * gr * a
				g[i] = g[i] * inv + color.g * gr * a
				b[i] = b[i] * inv + color.b * gr * a
			else:
				r[i] *= 1.0 + (color.r - 1.0) * a
				g[i] *= 1.0 + (color.g - 1.0) * a
				b[i] *= 1.0 + (color.b - 1.0) * a


## El lienzo como imagen RGB8.
func to_image() -> Image:
	var bytes := PackedByteArray()
	bytes.resize(width * height * 3)
	var k: int = 0
	for i: int in width * height:
		bytes[k] = clampi(roundi(r[i] * 255.0), 0, 255)
		bytes[k + 1] = clampi(roundi(g[i] * 255.0), 0, 255)
		bytes[k + 2] = clampi(roundi(b[i] * 255.0), 0, 255)
		k += 3
	return Image.create_from_data(width, height, false, Image.FORMAT_RGB8, bytes)


# --- Rasterizador -------------------------------------------------------------------------------

## Máscara de cobertura de [param polygons] (cada uno es un contorno cerrado en píxeles del lienzo;
## el relleno es el de "enrollamiento no nulo": un contorno contrario dentro de otro hace un agujero).
## null si no hay puntos o la máscara pasaría de [constant MAX_MASK_SIDE] píxeles de lado.
static func rasterize(polygons: Array[PackedVector2Array]) -> Mask:
	var min_x: float = INF
	var min_y: float = INF
	var max_x: float = -INF
	var max_y: float = -INF
	for polygon: PackedVector2Array in polygons:
		for point: Vector2 in polygon:
			min_x = minf(min_x, point.x)
			min_y = minf(min_y, point.y)
			max_x = maxf(max_x, point.x)
			max_y = maxf(max_y, point.y)
	if min_x > max_x:
		return null
	var x0: int = floori(min_x) - 2
	var y0: int = floori(min_y) - 2
	var w: int = ceili(max_x) + 3 - x0
	var h: int = ceili(max_y) + 3 - y0
	if w > MAX_MASK_SIDE or h > MAX_MASK_SIDE:
		push_warning("Máscara demasiado grande (%d x %d): se descarta" % [w, h])
		return null
	var accumulation := PackedFloat32Array()
	accumulation.resize(w * h + 4)
	var ox: float = float(x0)
	var oy: float = float(y0)
	for polygon: PackedVector2Array in polygons:
		var count: int = polygon.size()
		if count < 3:
			continue
		for i: int in count:
			var p: Vector2 = polygon[i]
			var q: Vector2 = polygon[(i + 1) % count]
			_add_edge(accumulation, w, h, p.x - ox, p.y - oy, q.x - ox, q.y - oy)
	var mask := Mask.new()
	mask.x0 = x0
	mask.y0 = y0
	mask.w = w
	mask.h = h
	mask.a.resize(w * h)
	for y: int in h:
		var row: int = y * w
		var total: float = 0.0
		for x: int in w:
			total += accumulation[row + x]
			mask.a[row + x] = minf(absf(total), 1.0)
	return mask


# Suma a la rejilla de acumulación el área con signo que deja una arista (algoritmo de font-rs).
static func _add_edge(acc: PackedFloat32Array, w: int, h: int, ax: float, ay: float, bx: float, by: float) -> void:
	if ay == by:
		return
	var dir: float = 1.0
	var p0x: float = ax
	var p0y: float = ay
	var p1x: float = bx
	var p1y: float = by
	if ay > by:
		dir = -1.0
		p0x = bx
		p0y = by
		p1x = ax
		p1y = ay
	var dxdy: float = (p1x - p0x) / (p1y - p0y)
	var x: float = p0x
	var y_start: int = 0
	if p0y < 0.0:
		x -= p0y * dxdy
	else:
		y_start = int(p0y)
	var y_end: int = mini(h, ceili(p1y))
	for y: int in range(y_start, y_end):
		var row: int = y * w
		var dy: float = minf(float(y + 1), p1y) - maxf(float(y), p0y)
		var xnext: float = x + dxdy * dy
		var d: float = dy * dir
		var xa: float = minf(x, xnext)
		var xb: float = maxf(x, xnext)
		var xa_floor: float = floorf(xa)
		var xi0: int = int(xa_floor)
		var xb_ceil: float = ceilf(xb)
		var xi1: int = int(xb_ceil)
		if xi1 <= xi0 + 1:
			var xmf: float = 0.5 * (x + xnext) - xa_floor
			acc[row + xi0] += d - d * xmf
			acc[row + xi0 + 1] += d * xmf
		else:
			var s: float = 1.0 / (xb - xa)
			var x0f: float = xa - xa_floor
			var a0: float = 0.5 * s * (1.0 - x0f) * (1.0 - x0f)
			var x1f: float = xb - xb_ceil + 1.0
			var am: float = 0.5 * s * x1f * x1f
			acc[row + xi0] += d * a0
			if xi1 == xi0 + 2:
				acc[row + xi0 + 1] += d * (1.0 - a0 - am)
			else:
				var a1: float = s * (1.5 - x0f)
				acc[row + xi0 + 1] += d * (a1 - a0)
				for xi: int in range(xi0 + 2, xi1 - 1):
					acc[row + xi] += d * s
				var a2: float = a1 + float(xi1 - xi0 - 3) * s
				acc[row + xi1 - 1] += d * (1.0 - a2 - am)
			acc[row + xi1] += d * am
		x = xnext


# --- Formas -------------------------------------------------------------------------------------

## Contornos de una línea gruesa que sigue [param points], con [param widths] (grosor en cada punto,
## uno solo vale para todos). Con [param closed] es un anillo. Las puntas son redondas.
static func stroke_polygons(points: PackedVector2Array, widths: PackedFloat32Array,
		closed: bool = false, round_caps: bool = true) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	var count: int = points.size()
	if count < 2:
		return result
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var normals := PackedVector2Array()
	var tangents := PackedVector2Array()
	for i: int in count:
		var prev: Vector2 = points[(i - 1 + count) % count] if (closed or i > 0) else points[i]
		var next: Vector2 = points[(i + 1) % count] if (closed or i < count - 1) else points[i]
		var tangent: Vector2 = next - prev
		if tangent.length_squared() < 1e-12:
			tangent = Vector2.RIGHT
		tangent = tangent.normalized()
		tangents.append(tangent)
		normals.append(Vector2(-tangent.y, tangent.x))
	for i: int in count:
		var half: float = 0.5 * widths[mini(i, widths.size() - 1)]
		# Esquinas: alarga el desplazamiento para que el grosor no se estreche (límite de inglete).
		var miter: float = 1.0
		if (closed or (i > 0 and i < count - 1)):
			var a: Vector2 = points[i] - points[(i - 1 + count) % count]
			var c: Vector2 = points[(i + 1) % count] - points[i]
			if a.length_squared() > 1e-12 and c.length_squared() > 1e-12:
				var cos_turn: float = a.normalized().dot(c.normalized())
				miter = clampf(1.0 / sqrt(maxf(0.5 * (1.0 + cos_turn), 0.25)), 1.0, 2.0)
		left.append(points[i] + normals[i] * half * miter)
		right.append(points[i] - normals[i] * half * miter)
	if closed:
		var inner := PackedVector2Array()
		for i: int in range(count - 1, -1, -1):
			inner.append(right[i])
		result.append(left)
		result.append(inner)
		return result
	var outline := PackedVector2Array()
	outline.append_array(left)
	var half_end: float = 0.5 * widths[mini(count - 1, widths.size() - 1)]
	var half_start: float = 0.5 * widths[0]
	if round_caps:
		for k: int in range(1, CAP_SEGMENTS):
			var theta: float = PI * float(k) / float(CAP_SEGMENTS)
			outline.append(points[count - 1] + normals[count - 1] * (half_end * cos(theta))
					+ tangents[count - 1] * (half_end * sin(theta)))
	for i: int in range(count - 1, -1, -1):
		outline.append(right[i])
	if round_caps:
		for k: int in range(1, CAP_SEGMENTS):
			var theta: float = PI * float(k) / float(CAP_SEGMENTS)
			outline.append(points[0] - normals[0] * (half_start * cos(theta)) - tangents[0] * (half_start * sin(theta)))
	result.append(outline)
	return result


## Un contorno circular con [param segments] lados.
static func circle(center: Vector2, radius: float, segments: int = 16) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	for i: int in segments:
		var angle: float = TAU * float(i) / float(segments)
		polygon.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return polygon


## Una elipse girada [param angle] radianes.
static func ellipse(center: Vector2, radius_x: float, radius_y: float, angle: float = 0.0,
		segments: int = 20) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	var turn: Transform2D = Transform2D(angle, Vector2.ZERO)
	for i: int in segments:
		var t: float = TAU * float(i) / float(segments)
		polygon.append(center + turn * Vector2(cos(t) * radius_x, sin(t) * radius_y))
	return polygon


## Un rectángulo girado [param angle] radianes alrededor de [param center].
static func box(center: Vector2, half_x: float, half_y: float, angle: float = 0.0) -> PackedVector2Array:
	var turn: Transform2D = Transform2D(angle, Vector2.ZERO)
	return PackedVector2Array([
		center + turn * Vector2(-half_x, -half_y), center + turn * Vector2(half_x, -half_y),
		center + turn * Vector2(half_x, half_y), center + turn * Vector2(-half_x, half_y)])


# --- Polilíneas ---------------------------------------------------------------------------------

## Longitud de una polilínea.
static func length_of(points: PackedVector2Array) -> float:
	var total: float = 0.0
	for i: int in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
	return total


## La polilínea con puntos cada [param step] píxeles (el último se conserva).
static func resample(points: PackedVector2Array, step: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	if points.is_empty():
		return result
	result.append(points[0])
	var carried: float = 0.0
	for i: int in range(1, points.size()):
		var a: Vector2 = points[i - 1]
		var c: Vector2 = points[i]
		var segment: float = a.distance_to(c)
		if segment < 1e-9:
			continue
		var at: float = step - carried
		while at <= segment:
			result.append(a.lerp(c, at / segment))
			at += step
		carried = segment - (at - step)
	if result[result.size() - 1].distance_to(points[points.size() - 1]) > 0.05 * step:
		result.append(points[points.size() - 1])
	return result


## Curva suave (Catmull-Rom) que pasa por [param points], con [param samples] puntos por tramo.
static func smooth(points: PackedVector2Array, samples: int = 8) -> PackedVector2Array:
	var count: int = points.size()
	if count < 3:
		return points
	var result := PackedVector2Array()
	for i: int in count - 1:
		var p0: Vector2 = points[maxi(i - 1, 0)]
		var p1: Vector2 = points[i]
		var p2: Vector2 = points[i + 1]
		var p3: Vector2 = points[mini(i + 2, count - 1)]
		for k: int in samples:
			var t: float = float(k) / float(samples)
			var t2: float = t * t
			var t3: float = t2 * t
			result.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
					+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	result.append(points[count - 1])
	return result


## Curva suave cerrada (Catmull-Rom) que pasa por todos los puntos de [param points].
static func smooth_closed(points: PackedVector2Array, samples: int = 8) -> PackedVector2Array:
	var count: int = points.size()
	if count < 3:
		return points
	var result := PackedVector2Array()
	for i: int in count:
		var p0: Vector2 = points[(i - 1 + count) % count]
		var p1: Vector2 = points[i]
		var p2: Vector2 = points[(i + 1) % count]
		var p3: Vector2 = points[(i + 2) % count]
		for k: int in samples:
			var t: float = float(k) / float(samples)
			var t2: float = t * t
			var t3: float = t2 * t
			result.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
					+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	return result


## Desplaza cada punto de [param points] a lo largo de la normal con ruido (pulso de mano). [param noise]
## se lee en 1D con la distancia recorrida como entrada.
static func wobble(points: PackedVector2Array, noise: FastNoiseLite, amplitude: float, phase: float = 0.0) -> PackedVector2Array:
	var result := PackedVector2Array()
	var count: int = points.size()
	var travelled: float = 0.0
	for i: int in count:
		var prev: Vector2 = points[maxi(i - 1, 0)]
		var next: Vector2 = points[mini(i + 1, count - 1)]
		var tangent: Vector2 = (next - prev).normalized() if next != prev else Vector2.RIGHT
		var normal: Vector2 = Vector2(-tangent.y, tangent.x)
		if i > 0:
			travelled += points[i].distance_to(points[i - 1])
		result.append(points[i] + normal * (noise.get_noise_2d(travelled, phase) * amplitude))
	return result


## Trozos de [param points] con el patrón de [param on] píxeles pintados y [param off] sin pintar (cada
## trozo es una polilínea). [param offset] adelanta el patrón.
static func dash(points: PackedVector2Array, on: float, off: float, offset: float = 0.0) -> Array[PackedVector2Array]:
	var pieces: Array[PackedVector2Array] = []
	var dense: PackedVector2Array = resample(points, 1.0)
	var period: float = on + off
	var current := PackedVector2Array()
	for i: int in dense.size():
		var phase: float = fposmod(float(i) + offset, period)
		if phase < on:
			current.append(dense[i])
		elif not current.is_empty():
			if current.size() >= 2:
				pieces.append(current)
			current = PackedVector2Array()
	if current.size() >= 2:
		pieces.append(current)
	return pieces


## Una línea gruesa ya rasterizada y partida en trozos para que ninguna máscara pase del tamaño máximo.
## Devuelve las máscaras (para pintarlas una a una).
static func stroke_masks(p_points: PackedVector2Array, p_widths: PackedFloat32Array, closed: bool = false,
		round_caps: bool = true, chunk: int = 90) -> Array[Mask]:
	var masks: Array[Mask] = []
	if p_points.size() < 2:
		return masks
	# Los tramos largos (marcos, murallas) se parten para que ninguna máscara pase del tamaño máximo.
	var points := PackedVector2Array()
	var widths := PackedFloat32Array()
	var segments: int = p_points.size() if closed else p_points.size() - 1
	for i: int in segments:
		var a: Vector2 = p_points[i]
		var b: Vector2 = p_points[(i + 1) % p_points.size()]
		var wa: float = p_widths[mini(i, p_widths.size() - 1)]
		var wb: float = p_widths[mini((i + 1) % p_points.size(), p_widths.size() - 1)]
		var pieces: int = maxi(ceili(a.distance_to(b) / MAX_SEGMENT), 1)
		for k: int in pieces:
			var t: float = float(k) / float(pieces)
			points.append(a.lerp(b, t))
			widths.append(lerpf(wa, wb, t))
	if not closed:
		points.append(p_points[p_points.size() - 1])
		widths.append(p_widths[mini(p_points.size() - 1, p_widths.size() - 1)])
	if closed:
		var low := Vector2(INF, INF)
		var high := Vector2(-INF, -INF)
		for p: Vector2 in points:
			low = low.min(p)
			high = high.max(p)
		if (high.x - low.x) < MAX_MASK_SIDE * 0.8 and (high.y - low.y) < MAX_MASK_SIDE * 0.8:
			var ring: Mask = rasterize(stroke_polygons(points, widths, true, round_caps))
			if ring != null:
				masks.append(ring)
			return masks
		# Un anillo enorme se pinta como una línea abierta que vuelve al principio.
		points.append(points[0])
		widths.append(widths[0])
	if points.size() <= chunk and length_of(points) < 420.0:
		var single: Mask = rasterize(stroke_polygons(points, widths, false, round_caps))
		if single != null:
			masks.append(single)
		return masks
	var start: int = 0
	while start < points.size() - 1:
		# Un trozo acaba al llegar a [param chunk] puntos o a unos 420 px de largo.
		var stop: int = start + 1
		var travelled: float = points[stop].distance_to(points[start])
		while stop < points.size() - 1 and stop - start < chunk and travelled < 420.0:
			stop += 1
			travelled += points[stop].distance_to(points[stop - 1])
		var piece: PackedVector2Array = points.slice(start, stop + 1)
		var piece_widths := PackedFloat32Array()
		for i: int in range(start, stop + 1):
			piece_widths.append(widths[mini(i, widths.size() - 1)])
		var mask: Mask = rasterize(stroke_polygons(piece, piece_widths, false, round_caps))
		if mask != null:
			masks.append(mask)
		start = stop
	return masks


# --- Ruido --------------------------------------------------------------------------------------

## Un campo de ruido de [param w] x [param h] píxeles como bytes (0 a 255, normalizado).
static func noise_bytes(p_seed: int, frequency: float, octaves: int, w: int, h: int,
		fractal: FastNoiseLite.FractalType = FastNoiseLite.FRACTAL_FBM) -> PackedByteArray:
	var noise := FastNoiseLite.new()
	noise.seed = p_seed
	noise.frequency = frequency
	noise.fractal_type = fractal
	noise.fractal_octaves = octaves
	var image: Image = noise.get_image(w, h, false, false, true)
	return image.get_data()
