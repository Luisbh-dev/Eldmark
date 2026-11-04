"""Modela la espada de armas de Eldmark desde cero y la exporta a glTF (GLB).

Uso (Blender 5.2 sin interfaz, desde la raíz del repo):

    blender --background --factory-startup --python tools/blender/build_sword.py -- \
        [--out assets/models/weapons] [--tex build/sword/tex] [--only base] [--blend build/sword/x.blend]

Escribe `sword_base.glb` y las tres variantes por reino (`sword_vardheim.glb`, `sword_solmarch.glb`
y `sword_askarra.glb`). Las cuatro comparten la MISMA hoja (geometría y UV idénticas) y cambian
guarda, pomo y colores del cuero y el metal; la textura de la hoja es propia de cada reino (hielo con
runas, oro incrustado o acero ennegrecido con una grieta emisiva), porque desde la cámara del juego
solo se lee la hoja.

Proporciones heroicas: la hoja mide unos 10,8 cm de ancho y 3 cm de canto, no los 8,9 x 1,4 de una
espada real, y la punta sigue a 0,94 m de la empuñadura (decisión 8 de docs/calidad.md: el alcance
del golpe no depende de la malla). Las caras de bisel que crea `slab` se mapean a la franja del canto
pulido del atlas de metal; `check_triangulation` avisa si un bisel mayor que la pieza rompe un
polígono.

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
GRIP_AMP = 0.12
# Z donde acaba por abajo el cuero y empieza el pomo (el anillo metálico lo tapa).
POMMEL_Z = -0.078

# Hoja: (z, medio ancho, medio grosor). Proporciones heroicas: unos 10,8 cm de ancho y 3 cm de canto
# a media hoja (de espada real serían 8,9 y 1,4), ensanche suave hasta el 65 % y punta en ojiva.
# La punta sigue en TIP_Z = 0,94 (decisión 8 de docs/calidad.md: el alcance del golpe no cambia).
BLADE_STATIONS = [
	(0.075, 0.0420, 0.0150), (0.145, 0.0420, 0.0150), (0.195, 0.0428, 0.0138),
	(0.215, 0.0434, 0.0134), (0.235, 0.0439, 0.0132), (0.255, 0.0445, 0.0130), (0.330, 0.0468, 0.0124), (0.420, 0.0498, 0.0117),
	(0.510, 0.0525, 0.0110), (0.600, 0.0540, 0.0103), (0.680, 0.0535, 0.0096),
	(0.750, 0.0512, 0.0088), (0.800, 0.0478, 0.0080), (0.840, 0.0430, 0.0072),
	(0.875, 0.0350, 0.0063), (0.905, 0.0245, 0.0052), (0.925, 0.0135, 0.0040),
]
# Las del LOD1, por su z (la lista del LOD0 lleva estaciones de más junto al arranque de la acanaladura).
BLADE_STATIONS_LOD1_Z = [0.075, 0.145, 0.255, 0.420, 0.600, 0.750, 0.840, 0.905]

# Índices de material en la malla final.
M_BLADE, M_LEATHER, M_METAL, M_EMBER = 0, 1, 2, 3
# Zonas del atlas de metal (u0, v0, u1, v1), con un margen para que no sangren al filtrar.
_BAND = 1.0 / tex.ATLAS_BANDS
REGION_METAL = (0.02, 0.02, 0.98, _BAND - 0.02)
REGION_ACCENT = (0.02, _BAND + 0.02, 0.98, 2.0 * _BAND - 0.02)
# El canto pulido: las caras de bisel de cada pieza (las crea `slab`) caen aquí y recogen la luz.
REGION_EDGE = (0.02, 2.0 * _BAND + 0.02, 0.98, 0.98)
# Metros de pieza por unidad de UV, al revés: UV por metro del mapeado en caja.
BOX_UV_SCALE = 2.2
# Nombre de la capa de caras donde `slab` marca las de bisel.
EDGE_TAG = "edge"
# Fuerza de la emisión de la brasa de Askarra (la grieta de la hoja y la del pomo): 3 a 4 para que se
# lea de lejos y en movimiento.
EMBER_STRENGTH = 3.5


# --- Utilidades de geometría ----------------------------------------------------------------------

def smoothstep(edge0, edge1, x):
	t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
	return t * t * (3.0 - 2.0 * t)


def new_part():
	part = bmesh.new()
	part.loops.layers.uv.verify()
	return part


def finish(part, material, smooth=False, region=None, recalc=True, edge_region=None):
	"""Deja la pieza lista: normales hacia fuera, material, sombreado y (si se pide) UV en caja.

	Con `edge_region`, las caras de bisel que marcó `slab` van a esa zona del atlas (el canto pulido).
	"""
	if recalc:
		bmesh.ops.recalc_face_normals(part, faces=part.faces[:])
	for face in part.faces:
		face.material_index = material
		face.smooth = smooth
	if region is not None:
		box_uv(part, region, edge_region=edge_region)
	return part


def box_uv(part, region, scale=BOX_UV_SCALE, edge_region=None):
	"""Mapeado en caja: cada cara se proyecta por su eje dominante, con densidad de píxel constante.

	Las UV de cada pieza arrancan en la esquina de su zona del atlas (`region`), así que nunca
	invaden la zona de al lado. El metal es ruido que se repite, así que no necesita islas aparte.
	Las caras marcadas como bisel (`edge_region` dado) se mapean en la zona del canto pulido.
	"""
	uv_layer = part.loops.layers.uv.verify()
	tag = part.faces.layers.int.get(EDGE_TAG) if edge_region is not None else None
	xs = [v.co.x for v in part.verts]
	ys = [v.co.y for v in part.verts]
	zs = [v.co.z for v in part.verts]
	mins = (min(xs), min(ys), min(zs))
	for face in part.faces:
		if tag is not None and face[tag]:
			u0, v0, u1, v1 = edge_region
		else:
			u0, v0, u1, v1 = region
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
	tag = part.faces.layers.int.new(EDGE_TAG)
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
		result = bmesh.ops.bevel(part, geom=edges, offset=bevel, offset_type='OFFSET', segments=segments,
				profile=0.5, affect='EDGES', clamp_overlap=True)
		for face in result["faces"]:
			face[tag] = 1
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

def blade_section(w, ht, edge, fuller, groove_scale=1.0):
	"""Anillo de 18 puntos de la sección: bisel de filo, bisel mayor, cara plana y acanaladura.

	Devuelve [(x, y, u)] empezando por el filo derecho, por arriba hacia la izquierda y de vuelta
	por abajo. `u` es la posición a lo ancho (x / w, de 0 a 1) que usa la textura; las fracciones
	vienen de sword_textures para que el brillo pintado caiga exactamente en cada bisel.
	"""
	e = edge
	bevel_x = 1.0 - (1.0 - tex.S_BEVEL) * e
	bevel_y = 0.95 - 0.65 * e
	shoulder_x = 0.93 - (0.93 - tex.S_SHOULDER) * e
	# La acanaladura nace y acaba en ojiva: su ancho (rim y suelo) crece con `groove_scale`, igual que en la
	# textura (sword_textures.fuller_width_scale).
	rim = tex.S_FULLER_RIM * groove_scale
	floor_x = tex.S_FULLER_FLOOR * groove_scale
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
	stations = BLADE_STATIONS if detail == 0 else [st for st in BLADE_STATIONS if st[0] in BLADE_STATIONS_LOD1_Z]
	rings = []
	for z, w, ht in stations:
		if detail == 0:
			edge = smoothstep(0.145, 0.195, z)
			fuller = smoothstep(*tex.FULLER_START, z) * (1.0 - smoothstep(*tex.FULLER_END, z))
			points = blade_section(w, ht, edge, fuller, float(tex.fuller_width_scale(z / TIP_Z)))
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
	"""El cuerpo de la guarda por el que pasa la hoja: más grueso que las alas, con chaflán.

	Es más ancho que la hoja heroica (10,8 cm) para taparle el recazo por los dos lados.
	"""
	outline = [(-0.040, 0.064), (0.040, 0.064), (0.054, 0.078), (0.054, 0.108), (0.040, 0.122),
			(-0.040, 0.122), (-0.054, 0.108), (-0.054, 0.078)]
	part = slab(outline, -0.0205, 0.0205, bevel=0.0045 if detail == 0 else 0.0, segments=1)
	return finish(part, M_METAL, smooth=False, region=REGION_METAL, edge_region=REGION_EDGE)


def guard_slab(outline, detail, region=REGION_METAL, half=0.0125, bevel=0.0045, taper=None):
	"""Pieza de guarda con volumen: una plancha con el bisel grande (sección en rombo achatado, no un
	prisma de grosor constante) y, con `taper = (x_ini, x_fin, factor)`, afinándose hacia las puntas: el
	grosor baja al `factor` entre |x| = x_ini y x_fin (de unos 2,5 cm en el centro a 1,2 cm en la punta)."""
	part = slab(outline, -half, half, bevel=bevel if detail == 0 else 0.0, segments=1)
	if taper is not None:
		x0, x1, factor = taper
		for vert in part.verts:
			t = smoothstep(x0, x1, abs(vert.co.x))
			vert.co.y *= 1.0 - (1.0 - factor) * t
	return finish(part, M_METAL, smooth=False, region=region, edge_region=REGION_EDGE)


def gem(cx, cz, radius, y0, y1, sides=6):
	"""Piedra o remache: un prisma pequeño que sobresale de la pieza, con el color de acento."""
	outline = ellipse_outline(cx, cz, radius, radius, sides)
	part = slab(outline, y0, y1, bevel=radius * 0.28, segments=1)
	return finish(part, M_METAL, smooth=False, region=REGION_ACCENT)


def facet_gem(cx, cz, radius, height, sides, base, side=1.0):
	"""Piedra facetada: una cúpula de `sides` caras que sobresale de la pieza hacia +Y (`side` = 1) o
	hacia -Y (`side` = -1), apoyada en el plano y = base. Usa el color de acento."""
	profile = [(radius, 0.0), (radius * 0.97, height * 0.30), (radius * 0.62, height * 0.78),
			(0.0, height)]
	part = lathe(profile, sides, caps=True)
	for vert in part.verts:
		x, y, z = vert.co
		vert.co = Vector((cx + x, side * (base + z), cz + y))
	return finish(part, M_METAL, smooth=False, region=REGION_ACCENT)


def ember_bar(p0, p1, width, y0, y1):
	"""Un tramo de grieta emisiva: un rectángulo fino de `p0` a `p1` (x, z) entre los planos y0 e y1."""
	dx, dz = p1[0] - p0[0], p1[1] - p0[1]
	length = math.hypot(dx, dz)
	nx, nz = -dz / length * width * 0.5, dx / length * width * 0.5
	outline = [(p0[0] + nx, p0[1] + nz), (p1[0] + nx, p1[1] + nz), (p1[0] - nx, p1[1] - nz),
			(p0[0] - nx, p0[1] - nz)]
	return finish(slab(outline, y0, y1), M_EMBER, smooth=False)


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
	parts = [guard_slab(mirrored(half), detail, half=0.0150, bevel=0.0085, taper=(0.04, 0.17, 0.50))]
	parts.append(gem(0.0, 0.092, 0.013, 0.0205, 0.0250))
	parts.append(gem(0.0, 0.092, 0.013, -0.0250, -0.0205))
	bulb_z = 0.092 + 0.070 * (0.172 / 0.184) ** 2.0
	for side in (-1.0, 1.0):
		# Un remache de oro en cada bulbo, a las dos caras.
		parts.append(gem(side * 0.172, bulb_z, 0.0085, 0.0060, 0.0105))
		parts.append(gem(side * 0.172, bulb_z, 0.0085, -0.0105, -0.0060))
	return parts


def fang_half(center_z=0.092, bar_x=0.095, radius=0.115, sweep_deg=84.0, base_width=0.044, steps=16):
	"""Mitad derecha de una guarda de colmillos: una barra recta que se curva hacia la punta de la hoja.

	El colmillo es un arco de círculo (centro encima de la barra) cuyo grosor se afila hasta la punta.
	Va de abajo-centro a arriba-centro, como el resto de las mitades.
	"""
	outer, inner = [], []
	for index in range(steps + 1):
		t = index / steps
		angle = math.radians(sweep_deg * t)
		x = bar_x + radius * math.sin(angle)
		z = center_z + radius * (1.0 - math.cos(angle))
		width = base_width * (1.0 - t) ** 0.85 + 0.009
		# La tangente es (cos, sin); la normal hacia el centro del arco, (-sin, cos).
		nx, nz = -math.sin(angle), math.cos(angle)
		outer.append((x - nx * width * 0.5, z - nz * width * 0.5))
		inner.append((x + nx * width * 0.5, z + nz * width * 0.5))
	bar_low = center_z - 0.027
	bar_high = center_z + 0.027
	return [(0.0, bar_low), (bar_x * 0.55, bar_low)] + outer + list(reversed(inner)) \
			+ [(bar_x * 0.55, bar_high), (0.0, bar_high)]


def guard_vardheim(detail):
	"""Guarda de lobo: una barra recia que acaba en dos colmillos curvados hacia la punta."""
	half = fang_half()
	parts = [guard_slab(mirrored(half), detail, half=0.0150, bevel=0.0040, taper=(0.07, 0.19, 0.50))]
	for side in (-1.0, 1.0):
		# Una piedra de hielo en cada brazo de la barra, a las dos caras.
		parts.append(facet_gem(side * 0.070, 0.092, 0.0105, 0.0055, 6, 0.0145, 1.0))
		parts.append(facet_gem(side * 0.070, 0.092, 0.0105, 0.0055, 6, 0.0145, -1.0))
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


def half_sun_outline(center_z, hub, rays, lower_depth, lower_width=None, step=10.0):
	"""Silueta de medio sol: rayos solo en la mitad de arriba y la de abajo maciza.

	`rays` = [(ángulo de 0 a 180, largo, semiángulo de la base)]. Los rayos de 0 y 180 grados son los
	horizontales (los gavilanes). La mitad de abajo es media elipse de ancho `lower_width` (por defecto
	`hub`) y fondo `lower_depth`.
	"""
	lower_width = hub if lower_width is None else lower_width
	outline = []
	rays = sorted(rays)
	for index, (angle, length, half_base) in enumerate(rays):
		outline.append(_polar(center_z, angle - half_base, hub))
		outline.append(_polar(center_z, angle, length))
		outline.append(_polar(center_z, angle + half_base, hub))
		if index + 1 < len(rays):
			next_angle, _, next_half = rays[index + 1]
			start, end = angle + half_base, next_angle - next_half
			steps = int((end - start) // step)
			for s in range(1, steps + 1):
				outline.append(_polar(center_z, start + (end - start) * s / (steps + 1), hub))
	# De la base del último rayo (180 + semiángulo) a la del primero (360 - semiángulo), por abajo.
	last_angle, _, last_half = rays[-1]
	first_angle, _, first_half = rays[0]
	start, end = last_angle + last_half, 360.0 + first_angle - first_half
	steps = max(int((end - start) // step), 4)
	for s in range(1, steps):
		a = math.radians(start + (end - start) * s / steps)
		outline.append((lower_width * math.cos(a), center_z + lower_depth * math.sin(a)))
	return outline


def guard_solmarch(detail):
	"""Guarda de medio sol, el sol partido del emblema: rayos gruesos y cortos solo del lado de la hoja (los dos
	largos horizontales hacen de gavilanes) y la mitad de abajo maciza (hacia la mano no sale ningún rayo).
	Sin rayos junto al recazo: de aguja desaparecen a 3 m y los pegados a la hoja parecían flotar."""
	rays = [(0.0, 0.160, 16.0), (34.0, 0.106, 15.0), (146.0, 0.106, 15.0), (180.0, 0.160, 16.0)]
	outline = half_sun_outline(0.092, 0.064, rays, 0.046, lower_width=0.070)
	parts = [guard_slab(outline, detail, half=0.0145, bevel=0.0080, taper=(0.06, 0.16, 0.55))]
	# La piedra solar, cálida y facetada, en el centro de las dos caras.
	parts.append(facet_gem(0.0, 0.092, 0.022, 0.0120, 8, 0.0205, 1.0))
	parts.append(facet_gem(0.0, 0.092, 0.022, 0.0120, 8, 0.0205, -1.0))
	return parts


def guard_askarra(detail):
	"""Guarda de forja: una barra maciza de bronce con las puntas cortadas a golpe de cincel, la de arriba más
	alta, y un remache negro de hollín a cada lado. La grieta de la hoja baja por el cuerpo de la guarda."""
	half = [(0.0, 0.062), (0.100, 0.062), (0.168, 0.058), (0.206, 0.078), (0.208, 0.112),
			(0.186, 0.140), (0.158, 0.124), (0.100, 0.116), (0.0, 0.116)]
	parts = [guard_slab(mirrored(half), detail, half=0.0160, bevel=0.0090, taper=(0.07, 0.20, 0.50))]
	for side in (-1.0, 1.0):
		parts.append(facet_gem(side * 0.150, 0.090, 0.0095, 0.0050, 6, 0.0100, 1.0))
		parts.append(facet_gem(side * 0.150, 0.090, 0.0095, 0.0050, 6, 0.0100, -1.0))
	if detail == 0:
		# La grieta de la hoja sigue por las dos caras del cuerpo de la guarda (la pieza que abraza el recazo):
		# baja en zigzag desde arriba y suelta dos ramas cortas hacia los lados.
		trunk = [(0.003, 0.121), (-0.010, 0.109), (0.006, 0.097), (-0.006, 0.085), (0.002, 0.072)]
		branches = [[(0.006, 0.097), (0.026, 0.092), (0.042, 0.099)], [(-0.010, 0.109), (-0.030, 0.104), (-0.044, 0.111)]]
		for sign in (1.0, -1.0):
			y0, y1 = (0.0200, 0.0226) if sign > 0 else (-0.0226, -0.0200)
			for chain, width in [(trunk, 0.0062)] + [(b, 0.0042) for b in branches]:
				for p0, p1 in zip(chain, chain[1:]):
					parts.append(ember_bar(p0, p1, width, y0, y1))
	return parts


# --- Pomos por variante ---------------------------------------------------------------------------

def pommel_base(detail):
	"""Pomo de gema facetada: doce caras, collar y banda de oro."""
	profile = [(0.024, 0.000), (0.029, 0.006), (0.024, 0.013), (0.034, 0.028), (0.043, 0.050),
			(0.040, 0.070), (0.029, 0.088), (0.013, 0.097), (0.0, 0.101)]
	segments = 12 if detail == 0 else 6
	part = lathe([(r, POMMEL_Z - a) for r, a in reversed(profile)], segments, scale_y=0.86)
	parts = [finish(part, M_METAL, smooth=False, region=REGION_METAL)]
	if detail == 0:
		band = lathe([(0.0445, POMMEL_Z - 0.054), (0.0445, POMMEL_Z - 0.0615)], segments, scale_y=0.86,
				caps=False)
		parts.append(finish(band, M_METAL, smooth=False, region=REGION_ACCENT))
	return parts


def pommel_outline(points, scale=1.0):
	"""Silueta (x, z) a partir de puntos (x, d) en centímetros, con `d` hacia fuera del anillo del cuero
	(en el modelo es z = POMMEL_Z - d)."""
	return [(x * 0.01 * scale, POMMEL_Z - d * 0.01 * scale) for x, d in points]


# Cabeza de lobo de frente (cm; x a lo ancho, z hacia arriba, centrada en el eje del pomo): orejas tiesas,
# frente, mejillas con pelo y hocico. Es el relieve de las dos caras de la rueda, mitad derecha de abajo a
# arriba (la otra se espeja).
WOLF_FACE_HALF = [(0.0, -1.95), (0.40, -1.95), (0.65, -1.70), (1.30, -1.10), (1.95, -0.45), (1.55, 0.25),
		(1.60, 1.00), (1.05, 2.00), (0.55, 1.80), (0.50, 1.20), (0.0, 1.15)]
WOLF_EYE_CM = (0.68, 0.35)
# La rueda del pomo: centro, mitad del grosor y perfil (radio, posición axial) en metros.
WOLF_WHEEL_CENTER_D = 0.040
WOLF_WHEEL_PROFILE = [(0.0, -0.0150), (0.0240, -0.0150), (0.0262, -0.0178), (0.0294, -0.0178),
		(0.0318, -0.0120), (0.0318, 0.0120), (0.0294, 0.0178), (0.0262, 0.0178), (0.0240, 0.0150),
		(0.0, 0.0150)]
# Ampliación de la cabeza de lobo sobre las medidas de WOLF_FACE_HALF (cabe en el hueco de la rueda; las
# puntas de las orejas se montan sobre el aro).
WOLF_HEAD_SCALE = 1.22


def wheel(cz, profile, segments):
	"""Rueda con el eje a lo largo de Y (de cara a la cámara de frente), centrada en z = `cz`.

	`profile` es [(radio, posición axial)] de una cara a la otra: se modela como una pieza de revolución
	alrededor de Z y se tumba para que el eje quede en Y.
	"""
	part = lathe(profile, segments, caps=True)
	for vert in part.verts:
		x, y, z = vert.co
		vert.co = Vector((x, z, cz + y))
	return finish(part, M_METAL, smooth=False, region=REGION_METAL)


def pommel_vardheim(detail):
	"""Pomo de lobo en volumen: una rueda gruesa (6 cm de diámetro, 3,5 de canto) centrada en el eje con la
	cabeza de lobo en relieve en las dos caras (de frente se lee como cabeza, de perfil como un disco) y una
	gema de hielo por ojo. Nada de planchas de perfil ni piedras en la espalda."""
	center = POMMEL_Z - WOLF_WHEEL_CENTER_D
	segments = 18 if detail == 0 else 8
	stem = lathe([(0.0165, POMMEL_Z + 0.003), (0.0165, center + 0.0200)], 12 if detail == 0 else 8, scale_y=0.86)
	parts = [finish(stem, M_METAL, smooth=False, region=REGION_METAL)]
	parts.append(wheel(center, WOLF_WHEEL_PROFILE, segments))
	if detail == 1:
		return parts
	k = 0.01 * WOLF_HEAD_SCALE
	half = [(x * k, center + z * k) for x, z in WOLF_FACE_HALF]
	head = mirrored(half)
	for sign in (1.0, -1.0):
		y0, y1 = (0.0150, 0.0215) if sign > 0 else (-0.0215, -0.0150)
		# La cabeza en el metal pulido (más claro que el fondo de la rueda): se lee a distancia.
		parts.append(finish(slab(head, y0, y1, bevel=0.0030), M_METAL, smooth=False,
				region=REGION_EDGE, edge_region=REGION_EDGE))
		for eye_side in (-1.0, 1.0):
			parts.append(facet_gem(eye_side * WOLF_EYE_CM[0] * k, center + WOLF_EYE_CM[1] * k,
					0.0066, 0.0045, 6, 0.0215, sign))
	return parts


def pommel_solmarch(detail):
	"""Pomo de sol: ocho rayos que alternan largo y corto y una piedra solar cálida y facetada."""
	rays = [(i * 45.0, 0.060 if i % 2 == 0 else 0.042, 9.0) for i in range(8)]
	center = POMMEL_Z - 0.052
	outline = sun_outline(center, rays, 0.034)
	disc = slab(outline, -0.0145, 0.0145, bevel=0.0040 if detail == 0 else 0.0, segments=1)
	parts = [finish(disc, M_METAL, smooth=False, region=REGION_METAL, edge_region=REGION_EDGE)]
	parts.append(facet_gem(0.0, center, 0.0200, 0.0110, 8, 0.0145, 1.0))
	parts.append(facet_gem(0.0, center, 0.0200, 0.0110, 8, 0.0145, -1.0))
	return parts


# Pomo de yunque de doble cuerno, compacto y simétrico (cm; d = hacia fuera del cuero): cara de
# trabajo pegada al cuero, un cuerno a cada lado, cintura y pie. Está cruzado por una grieta de brasa.
ANVIL_HALF = [
	(0.0, -0.4), (2.4, -0.4), (2.4, 1.0), (3.2, 1.0), (6.4, 1.5), (7.5, 2.1), (6.8, 2.9), (3.8, 3.5),
	(2.7, 4.5), (2.4, 6.2), (4.2, 7.0), (4.2, 8.4), (0.0, 8.4),
]
# La grieta (x, d, en cm) que corre por las dos caras del yunque, de arriba a la izquierda a abajo
# a la derecha, y una rama corta.
ANVIL_CRACK = [(-4.6, 1.5), (-2.6, 2.4), (-1.5, 3.4), (-0.2, 3.9), (0.8, 5.2), (0.2, 6.1), (1.9, 7.2),
		(3.2, 8.3)]
ANVIL_BRANCH = [(-0.2, 3.9), (1.6, 3.2), (2.4, 2.1)]


def pommel_askarra(detail):
	"""Pomo de yunque de bronce, simétrico, con una grieta de brasa viva cruzándolo."""
	scale = 1.0
	half = [(x * 0.01 * scale, POMMEL_Z - d * 0.01 * scale) for x, d in ANVIL_HALF]
	outline = [(x, z) for x, z in half]
	for x, z in reversed(half[1:-1]):
		outline.append((-x, z))
	anvil = slab(outline, -0.0205, 0.0205, bevel=0.0060 if detail == 0 else 0.0, segments=1)
	parts = [finish(anvil, M_METAL, smooth=False, region=REGION_METAL, edge_region=REGION_EDGE)]

	def point(p):
		return (p[0] * 0.01 * scale, POMMEL_Z - p[1] * 0.01 * scale)

	for sign in (1.0, -1.0):
		y0, y1 = (0.0200, 0.0228) if sign > 0 else (-0.0228, -0.0200)
		for chain, width in ((ANVIL_CRACK, 0.0058), (ANVIL_BRANCH, 0.0042)):
			for a, b in zip(chain, chain[1:]):
				if detail == 1 and chain is ANVIL_BRANCH:
					continue
				parts.append(ember_bar(point(a), point(b), width, y0, y1))
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
	check_triangulation(mesh, name)
	return mesh


def check_triangulation(mesh, name):
	"""Avisa si algún polígono se triangula mal (el área de los triángulos tiene que ser la del polígono).

	Pasa con un bisel mayor que lo que mide la pieza (una punta muy fina cuyo contorno se cruza) y se
	ve como una cara que rellena un hueco que no es suyo.
	"""
	mesh.calc_loop_triangles()
	polygon_area = sum(poly.area for poly in mesh.polygons)
	triangle_area = 0.0
	for tri in mesh.loop_triangles:
		a, b, c = (mesh.vertices[i].co for i in tri.vertices)
		triangle_area += (b - a).cross(c - a).length * 0.5
	if abs(triangle_area - polygon_area) > 0.01 * polygon_area:
		raise ValueError("%s: triangulación rota (área %.5f frente a %.5f); revisa los biseles de las "
				"puntas finas" % (name, triangle_area, polygon_area))


# --- Materiales -----------------------------------------------------------------------------------

def load_image(path, srgb):
	image = bpy.data.images.load(path, check_existing=True)
	image.colorspace_settings.name = 'sRGB' if srgb else 'Non-Color'
	image.alpha_mode = 'NONE'
	return image


def make_textured_material(name, albedo_path, mr_path, emit_path="", emit_strength=1.0):
	"""Material PBR de glTF: albedo + (rugosidad en G, metálico en B) de una sola textura.

	Con `emit_path`, la textura de emisión (la grieta en llamas de la hoja de Askarra) con la fuerza
	`emit_strength`, que el glTF guarda como KHR_materials_emissive_strength.
	"""
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
	if emit_path:
		emit = nodes.new("ShaderNodeTexImage")
		emit.image = load_image(emit_path, True)
		emit.location = (-700, -400)
		links.new(emit.outputs["Color"], bsdf.inputs["Emission Color"])
		bsdf.inputs["Emission Strength"].default_value = emit_strength
	return material


def make_ember_material(name):
	material = bpy.data.materials.new(name)
	material.use_nodes = True
	material.use_backface_culling = True
	bsdf = material.node_tree.nodes["Principled BSDF"]
	bsdf.inputs["Base Color"].default_value = (0.10, 0.025, 0.015, 1.0)
	bsdf.inputs["Roughness"].default_value = 0.7
	bsdf.inputs["Metallic"].default_value = 0.0
	bsdf.inputs["Emission Color"].default_value = (1.0, 0.22, 0.02, 1.0)
	bsdf.inputs["Emission Strength"].default_value = EMBER_STRENGTH
	return material


def make_materials(variant, paths):
	emit = paths.get("blade_%s_emit" % variant, "")
	materials = [
		make_textured_material("SwordBlade", paths["blade_%s_albedo" % variant],
				paths["blade_%s_mr" % variant], emit, EMBER_STRENGTH if emit else 1.0),
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
