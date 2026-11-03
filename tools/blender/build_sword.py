"""Modela la espada de armas de Eldmark desde cero y la exporta a glTF (GLB).

Uso (Blender 5.2 sin interfaz, desde la raíz del repo):

    blender --background --factory-startup --python tools/blender/build_sword.py -- \
        [--out assets/models/weapons] [--tex build/sword/tex] [--only base] [--blend build/sword/x.blend]

Escribe `sword_base.glb` y las tres variantes por reino (`sword_vardheim.glb`, `sword_solmarch.glb`
y `sword_askarra.glb`). Las cuatro comparten la MISMA hoja (geometría, UV y textura idénticas) y
cambian solo guarda, pomo y colores del cuero y el metal.

Todo es propio: ninguna malla ni textura viene de un pack. Las texturas salen de
`tools/blender/sword_textures.py` (numpy, sin fotos).

Convención del modelo (la del glTF, +Y arriba):
- El origen es el CENTRO DE LA EMPUÑADURA, el punto donde cierra la mano.
- La hoja sale por +Y. Mide unos 0,94 m desde ese punto, y el conjunto unos 1,1 m con el pomo.
- El ancho de la hoja y de la guarda va por X; el grosor, por Z (las caras planas de la hoja miran
  a +Z y -Z, el filo a +X y -X).
- (En Blender, que es Z arriba, es lo mismo girado: hoja por +Z, grosor por Y.)

Estructura del archivo: un nodo `Sword` con dos marcas vacías (`TrailBase` y `TrailTip`, el arranque
del filo y la punta, para la estela del golpe) y dos mallas hijas, `Sword_LOD0` (detalle completo, unos
3000 triángulos) y `Sword_LOD1` (unos 500, sin acanaladura ni vueltas de cuero en la geometría) para
verla de lejos. El cliente decide cuál se ve según la distancia (scripts/client/weapon_props.gd).

Cada pieza se modela en su propio bmesh y se vuelca al final en una sola malla por LOD, con tres o
cuatro materiales (hoja, cuero, metal y, solo en Askarra, brasa).
"""

import argparse
import math
import os
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sword_textures as tex  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))

# --- Medidas (metros, con el origen en el centro de la empuñadura) --------------------------------

TIP_Z = 0.94
BLADE_ROOT_Z = 0.075
GRIP_Z0, GRIP_Z1 = -0.070, 0.070
GRIP_RX, GRIP_RY = 0.0205, 0.0170
GRIP_PITCH = 0.0158
GRIP_AMP = 0.18
# Z donde acaba por abajo el cuero y empieza el pomo (el anillo metálico lo tapa).
POMMEL_Z = -0.078

# Hoja: (z, medio ancho, medio grosor). Ensanche suave hasta el 65 % y punta en ojiva.
BLADE_STATIONS = [
	(0.075, 0.0340, 0.0105), (0.145, 0.0340, 0.0105), (0.195, 0.0345, 0.0097),
	(0.255, 0.0360, 0.0092), (0.330, 0.0380, 0.0087), (0.420, 0.0405, 0.0082),
	(0.510, 0.0430, 0.0077), (0.600, 0.0445, 0.0072), (0.680, 0.0440, 0.0067),
	(0.750, 0.0420, 0.0062), (0.800, 0.0390, 0.0057), (0.840, 0.0350, 0.0052),
	(0.875, 0.0285, 0.0046), (0.905, 0.0200, 0.0040), (0.925, 0.0110, 0.0032),
]
BLADE_STATIONS_LOD1 = [0, 1, 3, 5, 7, 9, 11, 13]

# Índices de material en la malla final.
M_BLADE, M_LEATHER, M_METAL, M_EMBER = 0, 1, 2, 3
# Zonas del atlas de metal (u0, v0, u1, v1), con un margen para que no sangren al filtrar.
REGION_METAL = (0.02, 0.02, 0.98, tex.ATLAS_SPLIT - 0.02)
REGION_ACCENT = (0.02, tex.ATLAS_SPLIT + 0.02, 0.98, 0.98)
# Metros de pieza por unidad de UV, al revés: UV por metro del mapeado en caja.
BOX_UV_SCALE = 2.2


# --- Utilidades de geometría ----------------------------------------------------------------------

def smoothstep(edge0, edge1, x):
	t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
	return t * t * (3.0 - 2.0 * t)


def new_part():
	part = bmesh.new()
	part.loops.layers.uv.verify()
	return part


def finish(part, material, smooth=False, region=None, recalc=True):
	"""Deja la pieza lista: normales hacia fuera, material, sombreado y (si se pide) UV en caja."""
	if recalc:
		bmesh.ops.recalc_face_normals(part, faces=part.faces[:])
	for face in part.faces:
		face.material_index = material
		face.smooth = smooth
	if region is not None:
		box_uv(part, region)
	return part


def box_uv(part, region, scale=BOX_UV_SCALE):
	"""Mapeado en caja: cada cara se proyecta por su eje dominante, con densidad de píxel constante.

	Las UV de cada pieza arrancan en la esquina de su zona del atlas (`region`), así que nunca
	invaden la zona de al lado. El metal es ruido que se repite, así que no necesita islas aparte.
	"""
	uv_layer = part.loops.layers.uv.verify()
	u0, v0, u1, v1 = region
	xs = [v.co.x for v in part.verts]
	ys = [v.co.y for v in part.verts]
	zs = [v.co.z for v in part.verts]
	mins = (min(xs), min(ys), min(zs))
	for face in part.faces:
		normal = face.normal
		axis = max(range(3), key=lambda i: abs(normal[i]))
		for loop in face.loops:
			co = loop.vert.co
			if axis == 0:
				a, b = co.y - mins[1], co.z - mins[2]
			elif axis == 1:
				a, b = co.x - mins[0], co.z - mins[2]
			else:
				a, b = co.x - mins[0], co.y - mins[1]
			u = min(max(u0 + a * scale, u0), u1)
			v = min(max(v0 + b * scale, v0), v1)
			loop[uv_layer].uv = (u, v)


def emit(master, part):
	"""Copia una pieza (vértices, caras, material, sombreado y UV) a la malla común."""
	uv_master = master.loops.layers.uv.verify()
	uv_part = part.loops.layers.uv.verify()
	part.verts.index_update()
	vmap = [master.verts.new(v.co) for v in part.verts]
	for face in part.faces:
		new_face = master.faces.new([vmap[v.index] for v in face.verts])
		new_face.material_index = face.material_index
		new_face.smooth = face.smooth
		for new_loop, loop in zip(new_face.loops, face.loops):
			new_loop[uv_master].uv = loop[uv_part].uv
	part.free()


def lathe(profile, segments, scale_x=1.0, scale_y=1.0, caps=True):
	"""Pieza de revolución alrededor de Z. `profile` es una lista de (radio, z) de abajo a arriba."""
	part = new_part()
	rings = []
	for radius, z in profile:
		if radius < 1e-6:
			rings.append([part.verts.new((0.0, 0.0, z))])
		else:
			ring = []
			for i in range(segments):
				angle = math.tau * i / segments
				ring.append(part.verts.new(
						(radius * scale_x * math.cos(angle), radius * scale_y * math.sin(angle), z)))
			rings.append(ring)
	for lower, upper in zip(rings, rings[1:]):
		if len(lower) == 1 and len(upper) == 1:
			continue
		for i in range(segments):
			j = (i + 1) % segments
			if len(lower) == 1:
				part.faces.new((lower[0], upper[j], upper[i]))
			elif len(upper) == 1:
				part.faces.new((lower[i], lower[j], upper[0]))
			else:
				part.faces.new((lower[i], lower[j], upper[j], upper[i]))
	if caps:
		if len(rings[0]) > 1:
			part.faces.new(rings[0])
		if len(rings[-1]) > 1:
			part.faces.new(rings[-1])
	return part


def slab(outline, y0, y1, bevel=0.0, segments=1):
	"""Prisma de la silueta `outline` (lista de (x, z)) entre los planos y = y0 e y = y1.

	Con `bevel` > 0 se biselan los dos contornos de las tapas: así la silueta se ve con un filo
	pulido que recoge la luz, que es lo que hace que una pieza plana parezca forjada.
	"""
	part = new_part()
	bottom = [part.verts.new((x, y0, z)) for x, z in outline]
	top = [part.verts.new((x, y1, z)) for x, z in outline]
	part.faces.new(bottom)
	part.faces.new(list(reversed(top)))
	count = len(outline)
	for i in range(count):
		j = (i + 1) % count
		part.faces.new((bottom[i], bottom[j], top[j], top[i]))
	bmesh.ops.recalc_face_normals(part, faces=part.faces[:])
	if bevel > 0.0:
		bottom_set, top_set = set(bottom), set(top)
		edges = [e for e in part.edges
				if (e.verts[0] in bottom_set and e.verts[1] in bottom_set)
				or (e.verts[0] in top_set and e.verts[1] in top_set)]
		bmesh.ops.bevel(part, geom=edges, offset=bevel, offset_type='OFFSET', segments=segments,
				profile=0.5, affect='EDGES', clamp_overlap=True)
	return part


def mirrored(half):
	"""Silueta simétrica a partir de su mitad derecha, de abajo-centro a arriba-centro."""
	outline = list(half)
	for x, z in reversed(half[1:-1]):
		outline.append((-x, z))
	return outline


def ellipse_outline(cx, cz, rx, rz, count=10):
	return [(cx + rx * math.cos(math.tau * i / count), cz + rz * math.sin(math.tau * i / count))
			for i in range(count)]


# --- La hoja (idéntica en todas las variantes) ----------------------------------------------------

def blade_section(w, ht, edge, fuller):
	"""Anillo de 18 puntos de la sección: bisel de filo, bisel mayor, cara plana y acanaladura.

	Devuelve [(x, y, u)] empezando por el filo derecho, por arriba hacia la izquierda y de vuelta
	por abajo. `u` es la posición a lo ancho (x / w, de 0 a 1) que usa la textura; las fracciones
	vienen de sword_textures para que el brillo pintado caiga exactamente en cada bisel.
	"""
	e = edge
	bevel_x = 1.0 - (1.0 - tex.S_BEVEL) * e
	bevel_y = 0.95 - 0.65 * e
	shoulder_x = 0.93 - (0.93 - tex.S_SHOULDER) * e
	rim = tex.S_FULLER_RIM
	floor_x = tex.S_FULLER_FLOOR
	floor_y = 1.0 - 0.62 * fuller
	top = [
		(1.0, 0.0), (bevel_x, bevel_y), (shoulder_x, 1.0), (rim, 1.0), (floor_x, floor_y),
		(-floor_x, floor_y), (-rim, 1.0), (-shoulder_x, 1.0), (-bevel_x, bevel_y), (-1.0, 0.0),
	]
	bottom = [
		(-bevel_x, -bevel_y), (-shoulder_x, -1.0), (-rim, -1.0), (-floor_x, -floor_y),
		(floor_x, -floor_y), (rim, -1.0), (shoulder_x, -1.0), (bevel_x, -bevel_y),
	]
	return [(fx * w, fy * ht, 0.5 + 0.5 * fx) for fx, fy in top + bottom]


def blade_section_lod1(w, ht):
	"""Sección hexagonal sencilla de la hoja lejana."""
	fx = tex.S_SHOULDER
	pts = [(1.0, 0.0), (fx, 1.0), (-fx, 1.0), (-1.0, 0.0), (-fx, -1.0), (fx, -1.0)]
	return [(x * w, y * ht, 0.5 + 0.5 * x) for x, y in pts]


def build_blade(detail):
	part = new_part()
	uv_layer = part.loops.layers.uv.verify()
	stations = BLADE_STATIONS if detail == 0 else [BLADE_STATIONS[i] for i in BLADE_STATIONS_LOD1]
	rings = []
	for z, w, ht in stations:
		if detail == 0:
			edge = smoothstep(0.145, 0.195, z)
			fuller = smoothstep(0.185, 0.265, z) * (1.0 - smoothstep(0.66, 0.80, z))
			points = blade_section(w, ht, edge, fuller)
		else:
			points = blade_section_lod1(w, ht)
		verts = [(part.verts.new((x, y, z)), u) for x, y, u in points]
		rings.append((z, verts))
	count = len(rings[0][1])
	for (z0, lower), (z1, upper) in zip(rings, rings[1:]):
		for k in range(count):
			m = (k + 1) % count
			face = part.faces.new((lower[k][0], lower[m][0], upper[m][0], upper[k][0]))
			for loop, (u, z) in zip(face.loops, ((lower[k][1], z0), (lower[m][1], z0),
					(upper[m][1], z1), (upper[k][1], z1))):
				loop[uv_layer].uv = (u, z / TIP_Z)
	apex = part.verts.new((0.0, 0.0, TIP_Z))
	z_last, last = rings[-1]
	for k in range(count):
		m = (k + 1) % count
		face = part.faces.new((last[k][0], last[m][0], apex))
		coords = ((last[k][1], z_last / TIP_Z), (last[m][1], z_last / TIP_Z), (0.5, 1.0))
		for loop, uv in zip(face.loops, coords):
			loop[uv_layer].uv = uv
	finish(part, M_BLADE, smooth=False, recalc=False)
	return part


# --- Empuñadura de cuero --------------------------------------------------------------------------

def build_grip(detail):
	"""Cuero en espiral: la cresta de cada vuelta está modelada, no solo pintada."""
	part = new_part()
	uv_layer = part.loops.layers.uv.verify()
	if detail == 0:
		columns = 14
		rows = int(round((GRIP_Z1 - GRIP_Z0) / GRIP_PITCH * 6))
	else:
		columns, rows = 8, 2
	length = GRIP_Z1 - GRIP_Z0
	grid = []
	for j in range(rows + 1):
		z = GRIP_Z0 + length * j / rows
		t = j / rows
		# Un poco más gruesa en el centro y abierta en la base, como una empuñadura de verdad.
		swell = 1.0 + 0.07 * math.sin(math.pi * t) + 0.05 * (1.0 - t) ** 3
		row = []
		for i in range(columns):
			angle = math.tau * i / columns
			phase = z / GRIP_PITCH + i / columns
			if detail == 0:
				bump = 1.0 + GRIP_AMP * (float(tex.wrap_profile(phase)) - 0.5)
			else:
				bump = 1.0
			row.append(part.verts.new((
					GRIP_RX * swell * bump * math.cos(angle),
					GRIP_RY * swell * bump * math.sin(angle), z)))
		grid.append(row)
	for j in range(rows):
		z0 = GRIP_Z0 + length * j / rows
		z1 = GRIP_Z0 + length * (j + 1) / rows
		for i in range(columns):
			k = (i + 1) % columns
			face = part.faces.new((grid[j][i], grid[j][k], grid[j + 1][k], grid[j + 1][i]))
			# v desenrollado: sube una unidad por vuelta, también al dar la vuelta al cilindro.
			coords = (
				(i / columns, z0 / GRIP_PITCH + i / columns),
				((i + 1) / columns, z0 / GRIP_PITCH + (i + 1) / columns),
				((i + 1) / columns, z1 / GRIP_PITCH + (i + 1) / columns),
				(i / columns, z1 / GRIP_PITCH + i / columns),
			)
			for loop, uv in zip(face.loops, coords):
				loop[uv_layer].uv = uv
	finish(part, M_LEATHER, smooth=True, recalc=False)
	return part


# --- Piezas de metal comunes ----------------------------------------------------------------------

def build_ferrules(detail):
	"""Los dos anillos de metal que cierran el cuero (bajo la guarda y sobre el pomo)."""
	segments = 12 if detail == 0 else 8
	parts = []
	top = lathe([(0.0210, 0.058), (0.0235, 0.060), (0.0235, 0.074), (0.0210, 0.076)],
			segments, scale_y=0.86)
	parts.append(finish(top, M_METAL, smooth=False, region=REGION_METAL))
	low = lathe([(0.0200, -0.066), (0.0235, -0.068), (0.0235, -0.080), (0.0210, -0.083)],
			segments, scale_y=0.86)
	parts.append(finish(low, M_METAL, smooth=False, region=REGION_METAL))
	return parts


def build_guard_boss(detail):
	"""El cuerpo de la guarda por el que pasa la hoja: más grueso que las alas, con chaflán."""
	outline = [(-0.030, 0.064), (0.030, 0.064), (0.042, 0.078), (0.042, 0.108), (0.030, 0.122),
			(-0.030, 0.122), (-0.042, 0.108), (-0.042, 0.078)]
	part = slab(outline, -0.0205, 0.0205, bevel=0.0045 if detail == 0 else 0.0, segments=1)
	return finish(part, M_METAL, smooth=False, region=REGION_METAL)


def guard_slab(outline, detail, region=REGION_METAL, half=0.0125, bevel=0.0045):
	part = slab(outline, -half, half, bevel=bevel if detail == 0 else 0.0, segments=1)
	return finish(part, M_METAL, smooth=False, region=region)


def gem(cx, cz, radius, y0, y1, sides=6):
	"""Piedra o remache: un prisma pequeño que sobresale de la pieza, con el color de acento."""
	outline = ellipse_outline(cx, cz, radius, radius, sides)
	part = slab(outline, y0, y1, bevel=radius * 0.28, segments=1)
	return finish(part, M_METAL, smooth=False, region=REGION_ACCENT)


# --- Guardas por variante -------------------------------------------------------------------------

def swept_guard(widths, rise, x_end, tip_drop, power=2.0, base_z=0.092):
	"""Mitad derecha de una guarda de alas que suben (rise > 0) o bajan (rise < 0) hacia la punta.

	`widths` = [(x, grosor)] a lo largo del ala; la línea media es base_z + rise * (x / x_end)^power.
	"""
	def spine(x):
		return base_z + rise * (x / x_end) ** power

	lower = [(x, spine(x) - t * 0.5) for x, t in widths]
	upper = [(x, spine(x) + t * 0.5) for x, t in widths]
	tip = (x_end + 0.016, spine(x_end) + tip_drop)
	return lower + [tip] + list(reversed(upper))


def guard_base(detail):
	"""Guarda de alas que se curvan hacia la punta y acaban en un bulbo."""
	widths = [(0.0, 0.052), (0.03, 0.044), (0.07, 0.036), (0.11, 0.032), (0.14, 0.032),
			(0.158, 0.040), (0.172, 0.048), (0.184, 0.042)]
	half = swept_guard(widths, 0.070, 0.184, 0.002)
	parts = [guard_slab(mirrored(half), detail, half=0.0145, bevel=0.0055)]
	parts.append(gem(0.0, 0.092, 0.013, 0.0205, 0.0250))
	parts.append(gem(0.0, 0.092, 0.013, -0.0250, -0.0205))
	bulb_z = 0.092 + 0.070 * (0.172 / 0.184) ** 2.0
	for side in (-1.0, 1.0):
		# Un remache de oro en cada bulbo, a las dos caras.
		parts.append(gem(side * 0.172, bulb_z, 0.0085, 0.0145, 0.0185))
		parts.append(gem(side * 0.172, bulb_z, 0.0085, -0.0185, -0.0145))
	return parts


def guard_vardheim(detail):
	"""Guarda de lobo: barra recia con un colmillo que sube y una púa que baja en cada punta."""
	half = [(0.0, 0.064), (0.055, 0.064), (0.105, 0.068), (0.140, 0.060), (0.174, 0.032),
			(0.162, 0.064), (0.154, 0.082), (0.180, 0.098), (0.190, 0.135), (0.174, 0.196),
			(0.155, 0.152), (0.135, 0.124), (0.100, 0.115), (0.050, 0.120), (0.0, 0.124)]
	parts = [guard_slab(mirrored(half), detail, half=0.0145, bevel=0.0055)]
	for side in (-1.0, 1.0):
		# Una piedra de hielo en cada brazo, a las dos caras.
		parts.append(gem(side * 0.098, 0.092, 0.0115, 0.0145, 0.0190, sides=6))
		parts.append(gem(side * 0.098, 0.092, 0.0115, -0.0190, -0.0145, sides=6))
	return parts


def sun_outline(center_z, rays, hub, step=12.0):
	"""Silueta de sol: `rays` = [(ángulo en grados, largo, semiángulo de la base)], antihorario."""
	rays = sorted(rays)
	outline = []
	count = len(rays)
	for index, (angle, length, half_base) in enumerate(rays):
		outline.append(_polar(center_z, angle - half_base, hub))
		outline.append(_polar(center_z, angle, length))
		outline.append(_polar(center_z, angle + half_base, hub))
		next_angle, _, next_half = rays[(index + 1) % count]
		if index == count - 1:
			next_angle += 360.0
		start = angle + half_base
		end = next_angle - next_half
		steps = int((end - start) // step)
		for s in range(1, steps + 1):
			outline.append(_polar(center_z, start + (end - start) * s / (steps + 1), hub))
	return outline


def _polar(center_z, angle_deg, radius):
	a = math.radians(angle_deg)
	return (radius * math.cos(a), center_z + radius * math.sin(a))


def guard_solmarch(detail):
	"""Guarda de sol: rayos de oro que salen de un disco, los dos largos horizontales."""
	right = [(0.0, 0.190, 8.0), (22.0, 0.118, 8.5), (42.0, 0.094, 8.5),
			(-22.0, 0.102, 8.5), (-44.0, 0.082, 8.5), (-65.0, 0.068, 8.5)]
	rays = []
	for angle, length, half_base in right:
		rays.append((angle % 360.0, length, half_base))
		if abs(angle) > 1e-6:
			rays.append(((180.0 - angle) % 360.0, length, half_base))
	rays.append((180.0, 0.190, 8.0))
	outline = sun_outline(0.092, rays, 0.054)
	parts = [guard_slab(outline, detail, half=0.0135, bevel=0.0040)]
	parts.append(gem(0.0, 0.092, 0.021, 0.0205, 0.0260, sides=8))
	parts.append(gem(0.0, 0.092, 0.021, -0.0260, -0.0205, sides=8))
	return parts


def guard_askarra(detail):
	"""Guarda de yunque: dos cuernos de bronce que salen de un bloque recio y bajan un poco."""
	widths = [(0.0, 0.076), (0.04, 0.068), (0.08, 0.056), (0.12, 0.042), (0.15, 0.030),
			(0.175, 0.018)]
	half = swept_guard(widths, -0.034, 0.175, -0.004, power=2.0, base_z=0.094)
	parts = [guard_slab(mirrored(half), detail, half=0.0150, bevel=0.0055)]
	rivet_z = 0.094 - 0.034 * (0.070 / 0.175) ** 2.0
	for side in (-1.0, 1.0):
		# Remaches del bronce, a las dos caras.
		parts.append(gem(side * 0.070, rivet_z, 0.0095, 0.0150, 0.0190, sides=6))
		parts.append(gem(side * 0.070, rivet_z, 0.0095, -0.0190, -0.0150, sides=6))
	return parts


# --- Pomos por variante ---------------------------------------------------------------------------

def pommel_base(detail):
	"""Pomo de gema facetada: ocho caras, collar y banda de oro."""
	profile = [(0.024, 0.000), (0.029, 0.006), (0.024, 0.013), (0.034, 0.028), (0.043, 0.050),
			(0.040, 0.070), (0.029, 0.088), (0.013, 0.097), (0.0, 0.101)]
	segments = 8 if detail == 0 else 6
	part = lathe([(r, POMMEL_Z - a) for r, a in reversed(profile)], segments, scale_y=0.86)
	parts = [finish(part, M_METAL, smooth=False, region=REGION_METAL)]
	if detail == 0:
		band = lathe([(0.0445, POMMEL_Z - 0.054), (0.0445, POMMEL_Z - 0.0615)], segments, scale_y=0.86,
				caps=False)
		parts.append(finish(band, M_METAL, smooth=False, region=REGION_ACCENT))
	return parts


def mask_outline(points, scale=1.0):
	"""Silueta (x, z) a partir de la mitad derecha (x, d), de arriba-centro a abajo-centro.

	`d` es la distancia hacia fuera desde el anillo del cuero; en el modelo es z = POMMEL_Z - d.
	"""
	half = list(points)
	full = list(half)
	for x, d in reversed(half[1:-1]):
		full.append((-x, d))
	return [(x * scale, POMMEL_Z - d * scale) for x, d in full]


# Máscara de lobo, vista de frente por la cara plana de la hoja: orejas que suben a los lados del
# cuero, mejillas con mechones, hocico abajo.
WOLF_MASK = [
	(0.000, 0.014), (0.016, 0.014), (0.030, 0.006), (0.040, -0.040), (0.058, 0.014),
	(0.068, 0.036), (0.078, 0.056), (0.062, 0.060), (0.072, 0.078), (0.048, 0.086),
	(0.036, 0.104), (0.018, 0.112), (0.000, 0.118),
]
# Relieve del hocico (la mitad derecha; el resto es su espejo).
WOLF_MUZZLE = [(0.000, 0.108), (0.020, 0.094), (0.026, 0.070), (0.016, 0.050), (0.000, 0.044)]


def _quad(points, side, scale):
	"""Cuadrilátero de la cara derecha (x, d) llevado al lado `side` (1 derecha, -1 izquierda)."""
	quad = [(side * x * scale, POMMEL_Z - d * scale) for x, d in points]
	return quad if side > 0 else list(reversed(quad))


def pommel_vardheim(detail):
	"""Pomo de lobo: la cabeza vista de frente en cada cara, con ojos de hielo."""
	scale = 1.0
	head = slab(mask_outline(WOLF_MASK, scale), -0.0165, 0.0165,
			bevel=0.0055 if detail == 0 else 0.0, segments=1)
	parts = [finish(head, M_METAL, smooth=False, region=REGION_METAL)]
	if detail == 1:
		return parts
	muzzle = mask_outline(WOLF_MUZZLE, scale)
	brow = [(0.008, 0.034), (0.046, 0.026), (0.050, 0.038), (0.014, 0.050)]
	eye = [(0.022, 0.052), (0.036, 0.047), (0.034, 0.057), (0.020, 0.059)]
	for sign in (1.0, -1.0):
		# Cada cara lleva sus relieves: se levantan desde la cara plana hacia fuera.
		def layer(top: float):
			return (0.0, top) if sign > 0 else (-top, 0.0)

		y0, y1 = layer(0.0255)
		parts.append(finish(slab(muzzle, y0, y1, bevel=0.005, segments=1), M_METAL, smooth=False,
				region=REGION_METAL))
		for side in (-1.0, 1.0):
			y0, y1 = layer(0.0215)
			parts.append(finish(slab(_quad(brow, side, scale), y0, y1, bevel=0.003, segments=1),
					M_METAL, smooth=False, region=REGION_METAL))
			y0, y1 = layer(0.0275)
			parts.append(finish(slab(_quad(eye, side, scale), y0, y1), M_METAL, smooth=False,
					region=REGION_ACCENT))
	return parts


def pommel_solmarch(detail):
	"""Pomo de sol: disco de rayos de oro con una piedra clara en el centro."""
	rays = [(i * 30.0, 0.056, 8.0) for i in range(12)]
	center = POMMEL_Z - 0.056
	outline = sun_outline(center, rays, 0.036)
	disc = slab(outline, -0.0145, 0.0145, bevel=0.0038 if detail == 0 else 0.0, segments=1)
	parts = [finish(disc, M_METAL, smooth=False, region=REGION_METAL)]
	parts.append(gem(0.0, center, 0.0185, 0.0125, 0.0190, sides=8))
	parts.append(gem(0.0, center, 0.0185, -0.0190, -0.0125, sides=8))
	return parts


# Yunque de pie (a = hacia fuera del pomo): la cara de trabajo pega al cuero, el pie queda fuera y
# el cuerno apunta a +b.
ANVIL = [
	(0.000, -0.040), (0.000, 0.046), (0.008, 0.092), (0.020, 0.052), (0.034, 0.020),
	(0.048, 0.016), (0.054, 0.032), (0.066, 0.040), (0.066, -0.040), (0.054, -0.040),
	(0.050, -0.020), (0.034, -0.018), (0.022, -0.030), (0.010, -0.046),
]


def pommel_askarra(detail):
	"""Pomo de yunque de bronce sobre un lecho de brasas encendidas."""
	scale = 1.3
	outline = [(b * scale, POMMEL_Z - a * scale) for a, b in ANVIL]
	anvil = slab(outline, -0.0235, 0.0235, bevel=0.0060 if detail == 0 else 0.0, segments=1)
	parts = [finish(anvil, M_METAL, smooth=False, region=REGION_METAL)]
	foot_z = POMMEL_Z - 0.066 * scale
	# Las brasas bajo el pie: piedras bajas y ásperas que brillan un poco.
	chunks = [(-0.012, 0.0, 0.024, 0.022, 0.0125), (0.018, 0.0, 0.0150, 0.0165, 0.0100),
			(-0.043, 0.0, 0.0110, 0.0130, 0.0085), (0.048, 0.0, 0.0100, 0.0120, 0.0080)]
	for index, (dx, dy, rx, ry, rz) in enumerate(chunks):
		if detail == 1 and index > 0:
			continue
		ember = new_part()
		bmesh.ops.create_icosphere(ember, subdivisions=1, radius=1.0)
		center_z = foot_z - rz * 0.85
		for number, vert in enumerate(ember.verts):
			jitter = 1.0 + 0.16 * math.sin(number * 12.9898 + dx * 91.0)
			vert.co = Vector((vert.co.x * rx * jitter + dx, vert.co.y * ry * jitter + dy,
					center_z + vert.co.z * rz * jitter))
		parts.append(finish(ember, M_EMBER, smooth=False))
	return parts


# --- Montaje por variante -------------------------------------------------------------------------

VARIANTS = {
	"base": (guard_base, pommel_base),
	"vardheim": (guard_vardheim, pommel_vardheim),
	"solmarch": (guard_solmarch, pommel_solmarch),
	"askarra": (guard_askarra, pommel_askarra),
}


def build_mesh(name, variant, detail, materials):
	guard_fn, pommel_fn = VARIANTS[variant]
	master = bmesh.new()
	master.loops.layers.uv.verify()
	pieces = [build_blade(detail), build_grip(detail)]
	pieces += build_ferrules(detail)
	pieces.append(build_guard_boss(detail))
	pieces += guard_fn(detail)
	pieces += pommel_fn(detail)
	for number, piece in enumerate(pieces):
		try:
			emit(master, piece)
		except ValueError as error:
			raise ValueError("pieza %d de %d (%s): %s" % (number, len(pieces), variant, error))
	mesh = bpy.data.meshes.new(name)
	master.to_mesh(mesh)
	master.free()
	for material in materials:
		mesh.materials.append(material)
	mesh.validate()
	mesh.update()
	return mesh


# --- Materiales -----------------------------------------------------------------------------------

def load_image(path, srgb):
	image = bpy.data.images.load(path, check_existing=True)
	image.colorspace_settings.name = 'sRGB' if srgb else 'Non-Color'
	image.alpha_mode = 'NONE'
	return image


def make_textured_material(name, albedo_path, mr_path):
	"""Material PBR de glTF: albedo + (rugosidad en G, metálico en B) de una sola textura."""
	material = bpy.data.materials.new(name)
	material.use_nodes = True
	material.use_backface_culling = True
	nodes, links = material.node_tree.nodes, material.node_tree.links
	bsdf = nodes["Principled BSDF"]
	albedo = nodes.new("ShaderNodeTexImage")
	albedo.image = load_image(albedo_path, True)
	albedo.location = (-700, 200)
	mr = nodes.new("ShaderNodeTexImage")
	mr.image = load_image(mr_path, False)
	mr.location = (-700, -100)
	split = nodes.new("ShaderNodeSeparateColor")
	split.location = (-380, -100)
	links.new(albedo.outputs["Color"], bsdf.inputs["Base Color"])
	links.new(mr.outputs["Color"], split.inputs["Color"])
	links.new(split.outputs["Green"], bsdf.inputs["Roughness"])
	links.new(split.outputs["Blue"], bsdf.inputs["Metallic"])
	return material


def make_ember_material(name):
	material = bpy.data.materials.new(name)
	material.use_nodes = True
	material.use_backface_culling = True
	bsdf = material.node_tree.nodes["Principled BSDF"]
	bsdf.inputs["Base Color"].default_value = (0.10, 0.025, 0.015, 1.0)
	bsdf.inputs["Roughness"].default_value = 0.7
	bsdf.inputs["Metallic"].default_value = 0.0
	bsdf.inputs["Emission Color"].default_value = (0.90, 0.13, 0.015, 1.0)
	bsdf.inputs["Emission Strength"].default_value = 1.5
	return material


def make_materials(variant, paths):
	materials = [
		make_textured_material("SwordBlade", paths["blade_albedo"], paths["blade_mr"]),
		make_textured_material("SwordLeather_" + variant, paths["leather_%s_albedo" % variant],
				paths["leather_%s_mr" % variant]),
		make_textured_material("SwordMetal_" + variant, paths["metal_%s_albedo" % variant],
				paths["metal_%s_mr" % variant]),
	]
	if variant == "askarra":
		materials.append(make_ember_material("SwordEmber"))
	return materials


# --- Exportación ----------------------------------------------------------------------------------

def triangle_count(mesh):
	return sum(len(poly.vertices) - 2 for poly in mesh.polygons)


def build_variant(variant, out_dir, paths, blend_path=""):
	bpy.ops.wm.read_factory_settings(use_empty=True)
	materials = make_materials(variant, paths)
	root = bpy.data.objects.new("Sword", None)
	bpy.context.scene.collection.objects.link(root)
	# Puntos para la estela del golpe (ART-09): el arranque del filo y la punta.
	for name, z in (("TrailBase", 0.15), ("TrailTip", TIP_Z)):
		marker = bpy.data.objects.new(name, None)
		marker.location = (0.0, 0.0, z)
		bpy.context.scene.collection.objects.link(marker)
		marker.parent = root
	stats = {}
	for lod in (0, 1):
		mesh = build_mesh("Sword_LOD%d_%s" % (lod, variant), variant, lod, materials)
		obj = bpy.data.objects.new("Sword_LOD%d" % lod, mesh)
		obj["lod"] = lod
		bpy.context.scene.collection.objects.link(obj)
		obj.parent = root
		stats[lod] = triangle_count(mesh)
	bpy.ops.object.select_all(action='SELECT')
	bounds = _bounds(root)
	path = os.path.join(out_dir, "sword_%s.glb" % variant)
	bpy.ops.export_scene.gltf(
		filepath=path, export_format='GLB', use_selection=True, export_apply=True, export_yup=True,
		export_materials='EXPORT', export_image_format='AUTO', export_extras=True,
		export_cameras=False, export_lights=False, export_animations=False, export_skins=False,
		export_morph=False, export_texcoords=True, export_normals=True, export_tangents=False,
		export_vertex_color='NONE')
	if blend_path:
		bpy.ops.wm.save_as_mainfile(filepath=blend_path.replace(".blend", "_%s.blend" % variant))
	print("[sword] %-9s LOD0 %4d tris  LOD1 %4d tris  largo %.3f m  ancho %.3f m  -> %s" % (
			variant, stats[0], stats[1], bounds[1] - bounds[0], bounds[3], path))


def _bounds(root):
	low, high, width = 1e9, -1e9, 0.0
	for obj in root.children:
		if obj.name.endswith("LOD0"):
			for vert in obj.data.vertices:
				low = min(low, vert.co.z)
				high = max(high, vert.co.z)
				width = max(width, abs(vert.co.x) * 2.0)
	return low, high, 0.0, width


def main():
	argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
	parser = argparse.ArgumentParser()
	parser.add_argument("--out", default=os.path.join(ROOT, "assets", "models", "weapons"))
	parser.add_argument("--tex", default=os.path.join(ROOT, "build", "sword", "tex"))
	parser.add_argument("--only", default="")
	parser.add_argument("--blend", default="")
	args = parser.parse_args(argv)
	os.makedirs(args.out, exist_ok=True)
	paths = tex.write_all(args.tex)
	names = [args.only] if args.only else list(VARIANTS)
	for name in names:
		build_variant(name, args.out, paths, args.blend)


if __name__ == "__main__":
	main()
