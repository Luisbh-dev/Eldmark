"""Torreón del fuerte del Vado Gris (ART-57), modelado desde cero en Blender con código.

Genera assets/models/environment/custom/fort_keep.glb: un torreón de piedra de 21 m (24 m con la
torrecilla, su tejado y el asta) de planta cuadrada con contrafuertes escalonados en las
esquinas, zócalo ataludado, sillares marcados en la geometría, saeteras y ventanas con arco,
puerta con arco, dovelas y herrajes bajo un tejadillo, cadalso de madera con ménsulas, parapeto
almenado, torrecilla de escalera con tejado y asta con estandarte.

Uso, desde la raíz del repo (antes hay que generar las texturas propias):

    python tools/blender/make_fort_keep_textures.py
    blender --background --factory-startup --python tools/blender/build_fort_keep.py -- [opciones]

Opciones tras "--":
    --out <ruta.glb>      GLB de salida (por defecto assets/models/environment/custom/fort_keep.glb)
    --render <carpeta>    además guarda renders del modelo solo (Eevee) en esa carpeta
    --blend <ruta.blend>  guarda también la escena de Blender (no se versiona)

Qué contiene el GLB (nodos de primer nivel):
    FortKeep_LOD0      detalle completo, unos 57 000 triángulos, 8 materiales
    FortKeep_LOD1      versión lejana (unos 400 triángulos), con la piedra del Castle Wall Kit
    FortKeep-colonly   colisión aparte de baja resolución (Godot la importa como StaticBody3D con
                       trimesh y no dibuja la malla); sin cadalso, almenas ni herrajes

Ejes: se modela en Z arriba con la puerta hacia -X de Blender; el exportador lo pasa a Y arriba de
glTF/Godot, así que la puerta mira a -X en Godot (hacia la puerta del fuerte). Origen: centro del
torreón a la altura del suelo; el zócalo baja 1,2 m bajo el origen para enterrarse en la colina.

Materiales (por nombre, para que el juego los cambie por los de reino con realm_surface):
    keep_stone      sillares de cara          keep_mortar   fondo de las juntas
    keep_trim       piedra labrada            keep_wood     madera (tablones del Castle Wall Kit)
    keep_iron       herrajes                  keep_dark     huecos de saeteras y ventanas
    keep_cloth      estandarte                keep_roof     tejas (Village MegaKit)
    keep_stone_far  piedra del LOD lejano (brick_wall del Castle Wall Kit)

Es determinista: semilla fija.
"""

import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
MODELS = os.path.join(ROOT, "assets", "models", "environment")
TEX_OWN = os.path.join(MODELS, "custom", "fort_keep", "textures")
TEX_CASTLE = os.path.join(MODELS, "castle_wall", "textures")
TEX_VILLAGE = os.path.join(MODELS, "village")
DEFAULT_OUT = os.path.join(MODELS, "custom", "fort_keep.glb")

Z = Vector((0.0, 0.0, 1.0))
X = Vector((1.0, 0.0, 0.0))
Y = Vector((0.0, 1.0, 0.0))

# ---------------------------------------------------------------------------------------------
# Medidas (m)
# ---------------------------------------------------------------------------------------------
W = 3.5                    # semilado del muro (7 m de muro)
FOOT_Z = -1.2              # fondo del zócalo, enterrado
PLINTH_TOP = 3.30          # arriba del zócalo ataludado
PLINTH_HALF_BOTTOM = 5.00  # semilado del zócalo a ras de suelo (z = 0)
PLINTH_HALF_TOP = 4.45
WALL_START = 3.60          # primera hilada del muro (empieza bajo la repisa)
CORDON_Z0, CORDON_Z1 = 9.00, 9.35
CORNICE_Z0 = 17.90
WALK_Z = 18.70             # suelo del adarve y del cadalso
PARAPET_TOP = 19.90
COPING_TOP = 20.10
MERLON_TOP = 21.30         # remate del torreón
TURRET_TOP = 22.30
TURRET_ROOF_APEX = 23.90
TOTAL_TOP = 24.00          # punta del asta
PIER_IN = 1.2              # cuánto entra cada contrafuerte en el muro
PIER_OUT_LOW = 0.55
PIER_OUT_HIGH = 0.35
TURRET_IN = 2.25
TURRET_OUT_LOW = 0.85
TURRET_OUT_HIGH = 0.65
PORCH_FRONT = 5.15         # cara delantera del porche de la puerta (a -X)
PORCH_HALF = 1.70
PORCH_TOP = 4.90

BLOCK_GAP = 0.012
BLOCK_CHAMFER = 0.030
STONE_TILE = 3.2           # metros por baldosa de la textura de piedra
WOOD_TILE = 3.0
ROOF_TILE = 2.0

MATERIALS = ["keep_stone", "keep_mortar", "keep_trim", "keep_wood", "keep_iron", "keep_dark",
		"keep_cloth", "keep_roof", "keep_stone_far"]


# ---------------------------------------------------------------------------------------------
# Acumulador de geometría
# ---------------------------------------------------------------------------------------------
class Geo:
	"""Lista de polígonos (material, puntos, UV). Se vuelca a una malla de Blender al final."""

	def __init__(self) -> None:
		self.faces = []

	def add(self, mat, pts, uvs, hint=None) -> None:
		pts = [Vector(p) for p in pts]
		if len(pts) < 3:
			return
		n = Vector((0.0, 0.0, 0.0))
		count = len(pts)
		for i in range(count):
			a = pts[i]
			b = pts[(i + 1) % count]
			n.x += (a.y - b.y) * (a.z + b.z)
			n.y += (a.z - b.z) * (a.x + b.x)
			n.z += (a.x - b.x) * (a.y + b.y)
		if n.length < 1e-10:
			return
		uvs = list(uvs)
		if hint is not None and n.dot(hint) < 0.0:
			pts.reverse()
			uvs.reverse()
		self.faces.append((mat, pts, uvs))

	def triangle_count(self) -> int:
		return sum(len(f[1]) - 2 for f in self.faces)


def uv_frame(n: Vector, grain=None):
	"""Ejes de UV (u, v) para una cara de normal n. Con grain, la veta va a lo largo de u."""
	if grain is not None:
		g = grain - n * grain.dot(n)
		if g.length > 1e-5:
			ex = g.normalized()
			return ex, n.cross(ex)
	if abs(n.z) > 0.7:
		return X.copy(), Y.copy()
	return Z.cross(n).normalized(), Z.copy()


# ---------------------------------------------------------------------------------------------
# Primitivas
# ---------------------------------------------------------------------------------------------
def bevel_box(g, mat, center, axes, size, bevel=0.0, tile=STONE_TILE, grain=None, rng=None,
		jitter=0.0, offset=None):
	"""Caja con bisel de un tramo. axes = (ex, ey, ez) ortonormales; size = (sx, sy, sz)."""
	ex, ey, ez = [Vector(a) for a in axes]
	bm = bmesh.new()
	bmesh.ops.create_cube(bm, size=1.0)
	for v in bm.verts:
		v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]))
	if bevel > 0.0:
		limit = min(size) * 0.45
		bmesh.ops.bevel(bm, geom=bm.edges[:], offset=min(bevel, limit), offset_type='OFFSET',
				segments=1, profile=0.5, affect='EDGES')
	if jitter > 0.0 and rng is not None:
		for v in bm.verts:
			v.co += Vector((rng.uniform(-jitter, jitter), rng.uniform(-jitter, jitter),
					rng.uniform(-jitter, jitter)))
	bm.normal_update()
	if offset is None:
		offset = (rng.random(), rng.random()) if rng is not None else (0.0, 0.0)
	center = Vector(center)
	for f in bm.faces:
		pts = []
		for v in f.verts:
			pts.append(center + ex * v.co.x + ey * v.co.y + ez * v.co.z)
		ln = f.normal
		n = (ex * ln.x + ey * ln.y + ez * ln.z).normalized()
		fu, fv = uv_frame(n, grain)
		uvs = [(p.dot(fu) / tile + offset[0], p.dot(fv) / tile + offset[1]) for p in pts]
		g.add(mat, pts, uvs, n)
	bm.free()


def axis_box(g, mat, lo, hi, bevel=0.0, tile=STONE_TILE, grain=None, rng=None, jitter=0.0):
	"""Caja alineada con los ejes entre dos esquinas."""
	lo = Vector(lo)
	hi = Vector(hi)
	center = (lo + hi) * 0.5
	size = (hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
	bevel_box(g, mat, center, (X, Y, Z), size, bevel, tile, grain, rng, jitter)


def beam(g, mat, p0, p1, w, h, bevel=0.012, tile=WOOD_TILE, up=Z, rng=None, jitter=0.0):
	"""Viga de sección w x h entre dos puntos (la veta va a lo largo)."""
	p0 = Vector(p0)
	p1 = Vector(p1)
	d = p1 - p0
	length = d.length
	ex = d / length
	ey = up - ex * up.dot(ex)
	if ey.length < 1e-4:
		ey = X - ex * X.dot(ex)
	ey.normalize()
	ez = ex.cross(ey)
	bevel_box(g, mat, (p0 + p1) * 0.5, (ex, ey, ez), (length, h, w), bevel, tile, ex, rng, jitter)


def loft(g, mat, rect, profile, tile=STONE_TILE, skip=()):
	"""Anillo rectangular con un perfil (h, z). rect = (xmin, xmax, ymin, ymax). El perfil va en
	sentido antihorario alrededor de la sección: la normal sale por la derecha de la marcha."""
	xmin, xmax, ymin, ymax = rect
	sides = [
		(Vector((1, 0, 0)), lambda h: (Vector((xmax + h, ymin - h, 0)), Vector((xmax + h, ymax + h, 0)))),
		(Vector((0, 1, 0)), lambda h: (Vector((xmax + h, ymax + h, 0)), Vector((xmin - h, ymax + h, 0)))),
		(Vector((-1, 0, 0)), lambda h: (Vector((xmin - h, ymax + h, 0)), Vector((xmin - h, ymin - h, 0)))),
		(Vector((0, -1, 0)), lambda h: (Vector((xmin - h, ymin - h, 0)), Vector((xmax + h, ymin - h, 0)))),
	]
	cum = [0.0]
	for i in range(len(profile) - 1):
		cum.append(cum[-1] + math.hypot(profile[i + 1][0] - profile[i][0], profile[i + 1][1] - profile[i][1]))
	for i in range(len(profile) - 1):
		h0, z0 = profile[i]
		h1, z1 = profile[i + 1]
		for index, (n_h, ends) in enumerate(sides):
			if index in skip:
				continue
			a0, b0 = ends(h0)
			a1, b1 = ends(h1)
			a0.z = z0
			b0.z = z0
			a1.z = z1
			b1.z = z1
			normal = Vector((n_h.x * (z1 - z0), n_h.y * (z1 - z0), -(h1 - h0)))
			if normal.length < 1e-9:
				continue
			fu = Z.cross(n_h)
			pts = [a0, b0, b1, a1]
			uvs = [(p.dot(fu) / tile, (cum[i] if k < 2 else cum[i + 1]) / tile) for k, p in enumerate(pts)]
			g.add(mat, pts, uvs, normal)


def cylinder(g, mat, center, radius, z0, z1, sides=8, tile=WOOD_TILE, taper=1.0, cap_top=True):
	"""Prisma vertical (mástil, cilindros pequeños). taper escala el radio de arriba."""
	cx, cy = center
	for i in range(sides):
		a0 = 2 * math.pi * i / sides
		a1 = 2 * math.pi * (i + 1) / sides
		p0 = Vector((cx + math.cos(a0) * radius, cy + math.sin(a0) * radius, z0))
		p1 = Vector((cx + math.cos(a1) * radius, cy + math.sin(a1) * radius, z0))
		q0 = Vector((cx + math.cos(a0) * radius * taper, cy + math.sin(a0) * radius * taper, z1))
		q1 = Vector((cx + math.cos(a1) * radius * taper, cy + math.sin(a1) * radius * taper, z1))
		mid = (a0 + a1) * 0.5
		n = Vector((math.cos(mid), math.sin(mid), 0.0))
		u0 = i / sides * 2 * math.pi * radius / tile
		u1 = (i + 1) / sides * 2 * math.pi * radius / tile
		g.add(mat, [p0, p1, q1, q0], [(u0, z0 / tile), (u1, z0 / tile), (u1, z1 / tile), (u0, z1 / tile)], n)
		if cap_top and taper > 0.0:
			top = Vector((cx, cy, z1))
			g.add(mat, [q0, q1, top], [(0, 0), (1, 0), (0.5, 1)], Z)


def torus(g, mat, center, axis_x, axis_y, big, small, seg_big=14, seg_small=5):
	"""Anillo (tirador). Está en el plano de axis_x y axis_y."""
	center = Vector(center)
	normal_axis = axis_x.cross(axis_y)
	pts = {}
	for i in range(seg_big):
		a = 2 * math.pi * i / seg_big
		radial = axis_x * math.cos(a) + axis_y * math.sin(a)
		for j in range(seg_small):
			b = 2 * math.pi * j / seg_small
			pts[(i, j)] = center + radial * (big + small * math.cos(b)) + normal_axis * (small * math.sin(b))
	for i in range(seg_big):
		for j in range(seg_small):
			p = [pts[(i, j)], pts[((i + 1) % seg_big, j)], pts[((i + 1) % seg_big, (j + 1) % seg_small)],
					pts[(i, (j + 1) % seg_small)]]
			ring_center = center + (axis_x * math.cos(2 * math.pi * (i + 0.5) / seg_big)
					+ axis_y * math.sin(2 * math.pi * (i + 0.5) / seg_big)) * big
			hint = (p[0] + p[2]) * 0.5 - ring_center
			g.add(mat, p, [(0, 0), (1, 0), (1, 1), (0, 1)], hint)


def cone_stud(g, mat, base, normal, tangent, radius, height, sides=5):
	"""Remache: pirámide baja sobre una superficie."""
	base = Vector(base)
	bitangent = normal.cross(tangent)
	ring = []
	for i in range(sides):
		a = 2 * math.pi * i / sides
		ring.append(base + tangent * (math.cos(a) * radius) + bitangent * (math.sin(a) * radius))
	apex = base + normal * height
	for i in range(sides):
		p = [ring[i], ring[(i + 1) % sides], apex]
		g.add(mat, p, [(0, 0), (1, 0), (0.5, 1)], (ring[i] + ring[(i + 1) % sides]) * 0.5 - base + normal * 0.2)


def make_courses(z0, z1, target, rng, vary=0.09):
	"""Límites de hiladas entre z0 y z1: alturas parecidas pero no iguales, que suman justo z1-z0."""
	count = max(1, round((z1 - z0) / target))
	heights = [1.0 + rng.uniform(-vary, vary) for _ in range(count)]
	total = sum(heights)
	out = [z0]
	for h in heights:
		out.append(out[-1] + h * (z1 - z0) / total)
	out[-1] = z1
	return out


# ---------------------------------------------------------------------------------------------
# Sillares
# ---------------------------------------------------------------------------------------------
def cut_pieces(a, b, rng, prev, lo=0.72, hi=1.5, min_len=0.42):
	"""Reparte [a, b] en sillares de largo variable evitando juntas alineadas con la hilada de abajo."""
	out = []
	x = a
	while b - x > 1e-4:
		rem = b - x
		if rem < lo + min_len:
			length = rem
		else:
			length = rem
			for _ in range(7):
				cand = rng.uniform(lo, hi)
				if rem - cand < min_len:
					cand = rem
				joint = x + cand
				length = cand
				if cand == rem or all(abs(joint - j) > 0.2 for j in prev):
					break
		out.append((x, x + length))
		x += length
	return out


def stone_block(g, O, t, up, n, ua, ub, va, vb, rng, tile=STONE_TILE, weathered=0.0):
	"""Un sillar: cara plana ligeramente irregular y cuatro biseles hacia la junta."""
	w = ub - ua
	h = vb - va
	c = min(BLOCK_CHAMFER, 0.3 * w, 0.3 * h)
	gap = BLOCK_GAP
	depth = 0.075 + rng.uniform(-0.014, 0.016)
	if rng.random() < 0.05 + weathered:
		depth -= 0.028
	drop = 0.034
	off = (rng.random(), rng.random())

	def P(u, v, d):
		return O + t * u + up * v + n * d

	outer_uv = [(ua + gap, va + gap), (ub - gap, va + gap), (ub - gap, vb - gap), (ua + gap, vb - gap)]
	inner_uv = [(ua + gap + c, va + gap + c), (ub - gap - c, va + gap + c),
			(ub - gap - c, vb - gap - c), (ua + gap + c, vb - gap - c)]
	outer = [P(u, v, depth - drop) for u, v in outer_uv]
	inner = []
	inner_coords = []
	for u, v in inner_uv:
		ju = u + rng.uniform(-0.006, 0.006)
		jv = v + rng.uniform(-0.006, 0.006)
		inner.append(P(ju, jv, depth + rng.uniform(-0.005, 0.005)))
		inner_coords.append((ju, jv))
	outer_coords = outer_uv

	def uv(coords):
		return (coords[0] / tile + off[0], coords[1] / tile + off[1])

	g.add("keep_stone", inner, [uv(c_) for c_ in inner_coords], n)
	for k in range(4):
		k2 = (k + 1) % 4
		g.add("keep_stone", [outer[k], outer[k2], inner[k2], inner[k]],
				[uv(outer_coords[k]), uv(outer_coords[k2]), uv(inner_coords[k2]), uv(inner_coords[k])], n)


def ashlar(g, O, t, up, n, course_v, spans, rng, tile=STONE_TILE, weathered_fn=None, mortar_pad=0.0):
	"""Muro de sillares en un plano: O es el origen (u = 0, v = 0), t el sentido de las hiladas,
	up el sentido de subida en el plano y n la normal. spans(i, va, vb) da los tramos [(ua, ub)]
	de cada hilada (ya sin huecos ni piedras de esquina). mortar_pad alarga el fondo de las juntas
	más allá de los extremos del tramo: en las aristas salientes sin piedras de esquina hace que
	los fondos de las dos caras se crucen y no quede un hueco por el que se vea el interior."""
	prev = []
	for i in range(len(course_v) - 1):
		va, vb = course_v[i], course_v[i + 1]
		joints = []
		for ua, ub in spans(i, va, vb):
			if ub - ua < 0.03:
				continue
			# fondo de la junta
			qa, qb = ua - mortar_pad, ub + mortar_pad
			quad = [O + t * qa + up * va, O + t * qb + up * va, O + t * qb + up * vb, O + t * qa + up * vb]
			g.add("keep_mortar", quad, [(p.dot(t) / tile, p.dot(up) / tile) for p in quad], n)
			for a, b in cut_pieces(ua, ub, rng, prev):
				weathered = weathered_fn(i, va) if weathered_fn else 0.0
				stone_block(g, O, t, up, n, a, b, va, vb, rng, tile, weathered)
				if b < ub - 0.01:
					joints.append(b)
		prev = joints


def subtract(intervals, cut):
	"""Resta un intervalo cut = (a, b) de una lista de intervalos."""
	out = []
	for a, b in intervals:
		if cut[1] <= a or cut[0] >= b:
			out.append((a, b))
			continue
		if cut[0] > a:
			out.append((a, cut[0]))
		if cut[1] < b:
			out.append((cut[1], b))
	return out


class Opening:
	"""Hueco rectangular (con arco opcional) en una cara. Medidas en coordenadas de cara."""

	def __init__(self, u_center, width, z0, z1, arch=False, margin=0.0):
		self.uc = u_center
		self.half = width * 0.5
		self.z0 = z0
		self.z1 = z1          # arranque del arco si arch, o dintel
		self.arch = arch
		self.margin = margin

	def top(self) -> float:
		return self.z1 + (self.half if self.arch else 0.0)

	def cut_for(self, za, zb):
		"""Intervalo que ocupa el hueco en una hilada [za, zb], o None."""
		lo = self.z0 - self.margin
		hi = self.top() + self.margin
		if zb <= lo or za >= hi:
			return None
		half = self.half + self.margin
		if self.arch and zb > self.z1:
			z_ref = max(za, self.z1)
			r = self.half + self.margin
			dz = z_ref - self.z1
			if dz >= r:
				return None
			half = math.sqrt(max(r * r - dz * dz, 0.0))
			if za < self.z1 < zb:
				half = r
		return (self.uc - half, self.uc + half)


class Face:
	"""Cara vertical de piedra entre dos esquinas."""

	def __init__(self, n_h, plane, umin, umax, z_courses, openings=(), corners=()):
		self.n = Vector(n_h)
		self.t = Z.cross(self.n).normalized()
		self.plane = plane          # distancia del plano al eje (m)
		self.umin = umin
		self.umax = umax
		self.courses = z_courses
		self.openings = list(openings)
		self.corners = list(corners)  # [(corner, rol)] rol 'A' o 'B'

	def origin(self) -> Vector:
		return self.n * self.plane

	def spans(self, i, va, vb):
		lo, hi = self.umin, self.umax
		for corner, role in self.corners:
			la, lb = corner.lens(i)
			length = la if role == 'A' else lb
			if corner.end_of(self, role) == 'max':
				hi -= length
			else:
				lo += length
		if hi - lo < 0.03:
			return []
		spans = [(lo, hi)]
		for op in self.openings:
			cut = op.cut_for(va, vb)
			if cut:
				spans = subtract(spans, cut)
		return spans


class Corner:
	"""Esquina saliente con piedras de refuerzo alternas, largas y cortas."""
	LONG = 0.80
	SHORT = 0.46

	def __init__(self, point, n_a, n_b, parity=0, fixed=None):
		self.P = Vector(point)
		self.nA = Vector(n_a)
		self.nB = Vector(n_b)
		self.parity = parity
		self.fixed = fixed  # (lenA, lenB) para una esquina de retorno estrecho

	def lens(self, i):
		if self.fixed:
			return self.fixed
		if (i + self.parity) % 2 == 0:
			return (self.LONG, self.SHORT)
		return (self.SHORT, self.LONG)

	def end_of(self, face, role):
		"""'max' si la esquina está en el u máximo de la cara."""
		t = face.t
		other = self.nB if role == 'A' else self.nA
		return 'max' if t.dot(other) > 0 else 'min'


def build_face(g, face, rng, weathered_fn=None):
	O = face.origin()
	ashlar(g, O, face.t, Z, face.n, face.courses, face.spans, rng, STONE_TILE, weathered_fn)


def build_quoins(g, corner, courses, rng, protrude=0.045):
	"""Piedras de esquina: una caja con bisel por hilada, alternando largo y corto."""
	nA, nB = corner.nA, corner.nB
	for i in range(len(courses) - 1):
		za, zb = courses[i] + 0.012, courses[i + 1] - 0.012
		la, lb = corner.lens(i)
		# el cuerpo sobresale `protrude` por delante de las dos caras y entra en el muro por detrás
		center = corner.P - nA * (lb * 0.5 - protrude * 0.5) - nB * (la * 0.5 - protrude * 0.5)
		center.z = (za + zb) * 0.5
		bevel = 0.032 + rng.uniform(-0.006, 0.014)
		bevel_box(g, "keep_stone", center, (nA, nB, Z), (lb + protrude, la + protrude, zb - za), bevel,
				STONE_TILE, None, rng, 0.004)


# ---------------------------------------------------------------------------------------------
# Aberturas con marco
# ---------------------------------------------------------------------------------------------
def frame_opening(g, face, op, rng, reveal=0.6, kind='slit'):
	"""Hueco con jambas, fondo oscuro, alféizar y dintel o dovelas. Coordenadas de cara."""
	n, t = face.n, face.t
	base = face.origin()

	def P(u, z, d):
		return base + t * u + Z * z + n * d

	hw = op.half
	z0, z1 = op.z0, op.z1
	depth = 0.075      # plano de los sillares
	# fondo oscuro
	back = [P(op.uc - hw, z0, -reveal), P(op.uc + hw, z0, -reveal), P(op.uc + hw, op.top(), -reveal),
			P(op.uc - hw, op.top(), -reveal)]
	if op.arch:
		pts = [P(op.uc - hw, z0, -reveal), P(op.uc + hw, z0, -reveal), P(op.uc + hw, z1, -reveal)]
		steps = 10
		for i in range(1, steps):
			a = math.pi * i / steps
			pts.append(P(op.uc + hw * math.cos(a), z1 + hw * math.sin(a), -reveal))
		pts.append(P(op.uc - hw, z1, -reveal))
		g.add("keep_dark", pts, [(0, 0)] * len(pts), n)
	else:
		g.add("keep_dark", back, [(0, 0)] * 4, n)
	# jambas y alféizar
	for sgn in (-1, 1):
		u = op.uc + sgn * hw
		q = [P(u, z0, depth), P(u, z0, -reveal), P(u, z1, -reveal), P(u, z1, depth)]
		g.add("keep_trim", q, [(0, 0), (reveal / STONE_TILE, 0), (reveal / STONE_TILE, (z1 - z0) / STONE_TILE),
				(0, (z1 - z0) / STONE_TILE)], -t * sgn)
	sill = [P(op.uc - hw, z0, depth), P(op.uc - hw, z0, -reveal), P(op.uc + hw, z0, -reveal), P(op.uc + hw, z0, depth)]
	g.add("keep_trim", sill, [(0, 0), (1, 0), (1, 1), (0, 1)], Z)
	if op.arch:
		steps = 10
		for i in range(steps):
			a0 = math.pi * i / steps
			a1 = math.pi * (i + 1) / steps
			p0 = (op.uc + hw * math.cos(a0), z1 + hw * math.sin(a0))
			p1 = (op.uc + hw * math.cos(a1), z1 + hw * math.sin(a1))
			q = [P(p0[0], p0[1], depth), P(p0[0], p0[1], -reveal), P(p1[0], p1[1], -reveal), P(p1[0], p1[1], depth)]
			mid = (a0 + a1) * 0.5
			inward = -t * math.cos(mid) - Z * math.sin(mid)
			g.add("keep_trim", q, [(0, 0), (1, 0), (1, 1), (0, 1)], inward)
		ring = 0.34 if kind == 'window' else 0.45
		voussoirs(g, face, op.uc, z1, hw, ring, rng, count=9 if kind == 'window' else 11)
		# la hilada que pasa justo sobre el anillo queda recortada por el arco: se rellena con
		# sillares para que no quede un hueco por encima de las dovelas
		for ci in range(len(face.courses) - 1):
			za, zb = face.courses[ci], face.courses[ci + 1]
			cut = op.cut_for(za, zb)
			if cut and zb > z1 + hw + ring + 0.02:
				lo_z = max(za, z1 + hw + ring - 0.03)
				ashlar(g, face.origin(), t, Z, n, [lo_z, zb], lambda i, a, b, cut=cut: [cut], rng)
	else:
		# dintel liso
		center = base + t * op.uc + Z * (z1 + 0.11) + n * 0.045
		bevel_box(g, "keep_trim", center, (t, n, Z), (2 * hw + 0.34, 0.14, 0.22), 0.025, STONE_TILE, None, rng, 0.003)
	# alféizar saliente
	center = base + t * op.uc + Z * (z0 - 0.07) + n * 0.07
	bevel_box(g, "keep_trim", center, (t, n, Z), (2 * hw + 0.34, 0.22, 0.14), 0.025, STONE_TILE, None, rng, 0.003)
	# jambas de piedra labrada a cada lado
	jamb = 0.15
	for sgn in (-1, 1):
		center = base + t * (op.uc + sgn * (hw + jamb * 0.5)) + Z * ((z0 + op.top()) * 0.5) + n * 0.045
		height = (op.top() - z0) + (0.0 if op.arch else 0.0)
		if op.arch:
			height = z1 - z0 + 0.0
			center = base + t * (op.uc + sgn * (hw + jamb * 0.5)) + Z * ((z0 + z1) * 0.5) + n * 0.045
		bevel_box(g, "keep_trim", center, (t, n, Z), (jamb, 0.14, height), 0.02, STONE_TILE, None, rng, 0.003)
	if kind == 'window':
		# barrotes de hierro verticales dentro del hueco
		bars = 3
		for k in range(bars):
			u = op.uc + hw * (-0.5 + k * 0.5)
			a = base + t * u + Z * (z0 + 0.05) - n * 0.14
			b = base + t * u + Z * (z1 + hw * math.sqrt(max(1 - ((u - op.uc) / hw) ** 2, 0)) * 0.95) - n * 0.14
			beam(g, "keep_iron", a, b, 0.035, 0.035, 0.004, STONE_TILE, n)
		# travesaño
		a = base + t * (op.uc - hw) + Z * (z0 + (z1 - z0) * 0.55) - n * 0.14
		b = base + t * (op.uc + hw) + Z * (z0 + (z1 - z0) * 0.55) - n * 0.14
		beam(g, "keep_iron", a, b, 0.035, 0.035, 0.004, STONE_TILE, n)


def voussoirs(g, face, uc, zc, r_in, thick, rng, count=9):
	"""Anillo de dovelas de un arco de medio punto sobre una cara."""
	n, t = face.n, face.t
	base = face.origin()
	protrude = 0.105
	back = 0.0
	r_out = r_in + thick
	gap = 0.008
	for i in range(count):
		a0 = math.pi * i / count + gap / r_in
		a1 = math.pi * (i + 1) / count - gap / r_in
		pts_front = []
		pts_back = []
		for r, a in ((r_in, a0), (r_in, a1), (r_out, a1), (r_out, a0)):
			u = uc + r * math.cos(a)
			z = zc + r * math.sin(a)
			pts_front.append(base + t * u + Z * z + n * protrude)
			pts_back.append(base + t * u + Z * z + n * back)
		off = (rng.random(), rng.random())
		mid = (a0 + a1) * 0.5

		def uvf(p):
			return (p.dot(t) / STONE_TILE + off[0], p.dot(Z) / STONE_TILE + off[1])

		g.add("keep_trim", pts_front, [uvf(p) for p in pts_front], n)
		# lados de la dovela (intradós, trasdós y juntas)
		for k in range(4):
			k2 = (k + 1) % 4
			q = [pts_front[k], pts_front[k2], pts_back[k2], pts_back[k]]
			center_f = (pts_front[0] + pts_front[2]) * 0.5
			hint = (q[0] + q[2]) * 0.5 - (center_f - n * (protrude * 0.5))
			g.add("keep_trim", q, [uvf(p) for p in q], hint)
		_ = mid


# ---------------------------------------------------------------------------------------------
# Piezas del torreón
# ---------------------------------------------------------------------------------------------
class Builder:
	def __init__(self) -> None:
		self.rng = random.Random(20261103)
		self.g = Geo()
		rng = self.rng
		self.c_plinth = make_courses(FOOT_Z, 0.0, 0.62, rng)[:-1] + make_courses(0.0, PLINTH_TOP, 0.55, rng)
		self.c_low = make_courses(WALL_START, CORDON_Z0, 0.46, rng)
		self.c_up = make_courses(CORDON_Z1, CORNICE_Z0, 0.46, rng)
		self.c_parapet = make_courses(18.35, PARAPET_TOP, 0.40, rng)
		self.c_turret = make_courses(CORNICE_Z0, TURRET_TOP - 0.0, 0.46, rng)
		self.c_porch = make_courses(FOOT_Z, PORCH_TOP - 0.30, 0.55, rng)
		self.c_turret_low = make_courses(WALL_START, CORDON_Z0, 0.46, rng)

	# --- zócalo ---------------------------------------------------------------------------
	def plinth(self) -> None:
		g, rng = self.g, self.rng
		# parte enterrada y vertical, de z = FOOT_Z a 0, y la ataludada de 0 a PLINTH_TOP
		for part, courses, hb, ht, zb, zt in (
				("foot", [z for z in self.c_plinth if z <= 0.0001], PLINTH_HALF_BOTTOM, PLINTH_HALF_BOTTOM, FOOT_Z, 0.0),
				("batter", [z for z in self.c_plinth if z >= -0.0001], PLINTH_HALF_BOTTOM, PLINTH_HALF_TOP, 0.0, PLINTH_TOP)):
			if len(courses) < 2:
				continue
			slope = (ht - hb) / (zt - zb)
			length = math.sqrt((ht - hb) ** 2 + (zt - zb) ** 2)
			for index, n_h in enumerate([X, Y, -X, -Y]):
				t = Z.cross(n_h).normalized()
				up = (n_h * (ht - hb) + Z * (zt - zb)).normalized()
				normal = t.cross(up)
				if normal.dot(n_h) < 0:
					normal = -normal
				O = n_h * hb + Z * zb
				course_v = [(z - zb) / (zt - zb) * length for z in courses]

				def spans(i, va, vb, hb=hb, slope=slope, zb=zb, zt=zt, length=length, index=index):
					zmid = zb + (va + vb) * 0.5 / length * (zt - zb)
					half = hb + slope * (zmid - zb)
					ext_hi = 0.12 if (i + index) % 2 == 0 else 0.06
					ext_lo = 0.12 if (i + index + 1) % 2 == 0 else 0.06
					out = [(-half - ext_lo, half + ext_hi)]
					if index == 2 and zmid < PORCH_TOP:
						# el porche de la puerta atraviesa el zócalo en la cara oeste
						out = subtract(out, (-PORCH_HALF - 0.03, PORCH_HALF + 0.03))
					return out

				def weathered(i, va):
					return 0.06 if i < 2 else 0.0

				ashlar(g, O, t, up, normal, course_v, spans, rng, STONE_TILE, weathered, 0.07)
		# repisa con goterón: sale del zócalo y vuelve al muro (sentido antihorario)
		rect = (-1.0, 1.0, -1.0, 1.0)
		h0 = PLINTH_HALF_TOP + 0.12 - 1.0
		loft(g, "keep_trim", rect, [(h0, PLINTH_TOP - 0.06), (h0, PLINTH_TOP + 0.12),
				(W - 1.0, PLINTH_TOP + 0.48)], STONE_TILE)

	# --- muros y contrafuertes ---------------------------------------------------------------
	def bays_and_piers(self) -> None:
		g, rng = self.g, self.rng
		stages = [("low", self.c_low, PIER_OUT_LOW, TURRET_OUT_LOW), ("up", self.c_up, PIER_OUT_HIGH, TURRET_OUT_HIGH)]
		openings = self.make_openings()
		for stage, courses, pe, te in stages:
			# --- cuatro contrafuertes: NE es la torrecilla
			for sx, sy, is_turret in ((1, 1, True), (-1, 1, False), (-1, -1, False), (1, -1, False)):
				pi = TURRET_IN if is_turret else PIER_IN
				po = te if is_turret else pe
				self.pier(sx, sy, pi, po, courses, stage)
			# --- tramos de muro entre contrafuertes
			for name, n_h in (("E", X), ("N", Y), ("W", -X), ("S", -Y)):
				t = Z.cross(n_h).normalized()
				umin, umax = self.bay_range(n_h, t)
				face = Face(n_h, W, umin, umax, courses)
				face.openings = [o[1] for o in openings[name] if o[0] == stage]
				build_face(g, face, rng)
				for op_stage, op, kind in openings[name]:
					if op_stage == stage:
						frame_opening(g, face, op, rng, 0.6, kind)

	def bay_range(self, n_h, t):
		"""Rango de u del muro visible entre contrafuertes (la torrecilla se come parte de N y E)."""
		lo, hi = -(W - PIER_IN), (W - PIER_IN)
		if n_h == X:
			hi = W - TURRET_IN       # y de la torrecilla
		elif n_h == Y:
			lo = -(W - TURRET_IN)    # u = -x
		return lo, hi

	def make_openings(self):
		"""Huecos por cara: {cara: [(etapa, Opening, tipo)]}. Etapa 'low' (bajo el cordón) o 'up'."""
		def slit(u, z0, z1):
			return Opening(u, 0.28, z0, z1, False, 0.16)

		def win(u, z0, z1):
			return Opening(u, 0.90, z0, z1, True, 0.17)

		out = {"E": [], "N": [], "W": [], "S": []}
		# fachada oeste (puerta): saeteras bajas, ventana alta con arco y saeteras en lo alto
		out["W"] += [("low", slit(-1.45, 7.0, 8.5), 'slit'), ("low", slit(1.45, 7.0, 8.5), 'slit'),
				("up", win(0.0, 11.2, 12.55), 'window'),
				("up", slit(-1.6, 15.2, 16.7), 'slit'), ("up", slit(0.0, 15.2, 16.7), 'slit'),
				("up", slit(1.6, 15.2, 16.7), 'slit')]
		out["S"] += [("low", slit(0.0, 6.3, 7.9), 'slit'),
				("up", win(0.0, 11.2, 12.55), 'window'),
				("up", slit(-1.6, 15.2, 16.7), 'slit'), ("up", slit(0.0, 15.2, 16.7), 'slit'),
				("up", slit(1.6, 15.2, 16.7), 'slit')]
		out["N"] += [("low", slit(0.5, 6.3, 7.9), 'slit'),
				("up", win(0.5, 11.2, 12.55), 'window'),
				("up", slit(-0.7, 15.2, 16.7), 'slit'), ("up", slit(0.5, 15.2, 16.7), 'slit'),
				("up", slit(1.7, 15.2, 16.7), 'slit')]
		out["E"] += [("low", slit(-0.6, 6.3, 7.9), 'slit'),
				("up", slit(-1.5, 11.4, 13.0), 'slit'), ("up", slit(-0.2, 11.4, 13.0), 'slit'),
				("up", slit(-1.6, 15.2, 16.7), 'slit'), ("up", slit(-0.4, 15.2, 16.7), 'slit'),
				("up", slit(0.8, 15.2, 16.7), 'slit')]
		return out

	def pier(self, sx, sy, pi, po, courses, stage) -> None:
		"""Contrafuerte de esquina: su cara exterior en X, su cara exterior en Y, dos retornos
		estrechos y piedras de esquina en las tres aristas salientes."""
		g, rng = self.g, self.rng
		ex = Vector((sx, 0, 0))
		ey = Vector((0, sy, 0))
		xo = sx * (W + po)
		yo = sy * (W + po)
		xi = sx * (W - pi)
		yi = sy * (W - pi)
		par = 0 if (sx * sy > 0) else 1
		# esquinas: exterior (A = cara +x, B = cara +y), y las dos del retorno
		corner_out = Corner(Vector((xo, yo, 0)), ex, ey, par)
		corner_bc = Corner(Vector((xi, yo, 0)), ey, -ex, par + 1, fixed=(Corner.SHORT, po))
		corner_ad = Corner(Vector((xo, yi, 0)), ex, -ey, par + 1, fixed=(Corner.SHORT, po))
		# cara A (normal ex)
		fa = Face(ex, W + po, 0, 0, courses)
		ys = sorted([yi, yo])
		ua = sorted([Z.cross(ex).dot(Vector((0, y_, 0))) for y_ in ys])
		fa.umin, fa.umax = ua[0], ua[1]
		fa.corners = [(corner_out, 'A'), (corner_ad, 'A')]
		# cara B (normal ey)
		fb = Face(ey, W + po, 0, 0, courses)
		xs = sorted([xi, xo])
		ub = sorted([Z.cross(ey).dot(Vector((x_, 0, 0))) for x_ in xs])
		fb.umin, fb.umax = ub[0], ub[1]
		fb.corners = [(corner_out, 'B'), (corner_bc, 'A')]
		build_face(g, fa, rng, self.pier_wear)
		build_face(g, fb, rng, self.pier_wear)
		# retornos: las piedras de esquina ya cubren todo su ancho
		for corner in (corner_out, corner_bc, corner_ad):
			build_quoins(g, corner, courses, rng)

	def pier_wear(self, i, va) -> float:
		return 0.10 if va > 16.5 else 0.0

	# --- cordón, repisas y cornisa ------------------------------------------------------------
	def string_courses(self) -> None:
		g = self.g
		# cordón a z = 9: anillo alrededor del muro y de los contrafuertes (sale del contrafuerte
		# bajo y vuelve al alto: es su "vierteaguas")
		rect = (-W, W, -W, W)
		loft(g, "keep_trim", rect, [(0.0, CORDON_Z0), (0.14, CORDON_Z0), (0.14, CORDON_Z0 + 0.20),
				(-0.01, CORDON_Z1)], STONE_TILE)
		# vierteaguas en los contrafuertes: del plano bajo (0,55) al alto (0,35)
		for sx, sy in ((1, 1), (-1, 1), (-1, -1), (1, -1)):
			is_turret = sx == 1 and sy == 1
			pin = TURRET_IN if is_turret else PIER_IN
			po_low = TURRET_OUT_LOW if is_turret else PIER_OUT_LOW
			po_high = TURRET_OUT_HIGH if is_turret else PIER_OUT_HIGH
			x0, x1 = sorted([sx * (W - pin), sx * (W + po_low)])
			y0, y1 = sorted([sy * (W - pin), sy * (W + po_low)])
			d = po_low - po_high
			# vierteaguas: sale 0,09 del plano bajo y vuelve bajo los sillares del plano alto
			loft(g, "keep_trim", (x0, x1, y0, y1), [(0.09, CORDON_Z0), (0.09, CORDON_Z0 + 0.12), (-d + 0.04, CORDON_Z1)],
					STONE_TILE)
		# cornisa: bajo el cadalso, rodea el torreón con los contrafuertes
		rect2 = (-(W + PIER_OUT_HIGH), (W + PIER_OUT_HIGH), -(W + PIER_OUT_HIGH), (W + PIER_OUT_HIGH))
		loft(g, "keep_trim", rect2, [(-PIER_OUT_HIGH, CORNICE_Z0), (0.17, CORNICE_Z0), (0.17, CORNICE_Z0 + 0.28),
				(-PIER_OUT_HIGH, 18.36)], STONE_TILE)

	def parapet(self) -> None:
		g, rng = self.g, self.rng
		# muro del parapeto con sillares (por encima del cadalso, de 18,36 a 19,90)
		for name, n_h in (("E", X), ("N", Y), ("W", -X), ("S", -Y)):
			face = Face(n_h, W, -W - 0.09, W + 0.09, self.c_parapet)
			side_index = [X, Y, -X, -Y].index(n_h)

			def spans(i, va, vb, side_index=side_index):
				lo = -W - (0.09 if (i + side_index) % 2 == 0 else 0.03)
				hi = W + (0.09 if (i + side_index + 1) % 2 == 0 else 0.03)
				return [(lo, hi)]

			ashlar(g, face.origin(), face.t, Z, face.n, face.courses, spans, rng, STONE_TILE, None, 0.04)
		# albardilla y cara interior
		loft(g, "keep_trim", (-W, W, -W, W), [(0.0, PARAPET_TOP), (0.11, PARAPET_TOP), (0.11, COPING_TOP - 0.04),
				(0.02, COPING_TOP), (-0.8, COPING_TOP), (-0.8, PARAPET_TOP - 0.02)], STONE_TILE)
		# suelo del adarve (losas) y la bajada de la torrecilla
		inner = W - 0.8
		axis_box(g, "keep_trim", (-inner, -inner, WALK_Z - 0.25), (inner, inner, WALK_Z), 0.0, STONE_TILE, None, rng)
		# cara interior del parapeto, con sillares (se ve desde arriba y desde las almenas)
		inner = W - 0.8
		inner_courses = make_courses(WALK_Z, PARAPET_TOP, 0.40, rng)
		for side_index, n_h in enumerate([X, Y, -X, -Y]):
			n_in = -n_h
			face = Face(n_in, -inner, -inner - 0.09, inner + 0.09, inner_courses)

			def inner_spans(i, va, vb, side_index=side_index):
				lo = -inner - (0.09 if (i + side_index) % 2 == 0 else 0.03)
				hi = inner + (0.09 if (i + side_index + 1) % 2 == 0 else 0.03)
				return [(lo, hi)]

			ashlar(g, face.origin(), face.t, Z, face.n, face.courses, inner_spans, rng, STONE_TILE, None, 0.04)
		# almenas con sillares y albardilla: cuatro de esquina y dos por lado
		m_w = 1.1
		gap = (2 * W - 4 * m_w) / 3.0
		thick = 0.8
		spans_m = []
		pos = -W
		for k in range(4):
			spans_m.append((pos, pos + m_w))
			pos += m_w + gap
		for side, n_h in enumerate([X, Y, -X, -Y]):
			t = Z.cross(n_h).normalized()
			for k, (a_, b_) in enumerate(spans_m):
				if k in (0, 3):
					continue
				c = n_h * (W - thick * 0.5) + t * ((a_ + b_) * 0.5)
				self.merlon(c.x, c.y, abs(t.x) * (b_ - a_) * 0.5 + abs(n_h.x) * thick * 0.5,
						abs(t.y) * (b_ - a_) * 0.5 + abs(n_h.y) * thick * 0.5)
		for sx, sy in ((1, 1), (-1, 1), (-1, -1), (1, -1)):
			self.merlon(sx * (W - m_w * 0.5), sy * (W - m_w * 0.5), m_w * 0.5, m_w * 0.5)

	def merlon(self, cx, cy, hx, hy) -> None:
		"""Almena: cuatro caras de sillares sobre un núcleo y una albardilla biselada encima."""
		g, rng = self.g, self.rng
		z0, z1 = COPING_TOP, MERLON_TOP - 0.13
		courses = make_courses(z0, z1, 0.40, rng)
		for index, n_h in enumerate([X, Y, -X, -Y]):
			t = Z.cross(n_h).normalized()
			plane = n_h.x * cx + n_h.y * cy + (hx if abs(n_h.x) > 0.5 else hy)
			if abs(n_h.x) > 0.5:
				extent = (t.y * cy - hy, t.y * cy + hy)
			else:
				extent = (t.x * cx - hx, t.x * cx + hx)
			lo_u, hi_u = min(extent), max(extent)
			face = Face(n_h, plane, lo_u, hi_u, courses)

			def spans(i, va, vb, face=face, index=index):
				lo = face.umin - (0.09 if (i + index) % 2 == 0 else 0.03)
				hi = face.umax + (0.09 if (i + index + 1) % 2 == 0 else 0.03)
				return [(lo, hi)]

			ashlar(g, face.origin(), face.t, Z, face.n, courses, spans, rng, STONE_TILE, None, 0.04)
		center = Vector((cx, cy, MERLON_TOP - 0.065))
		bevel_box(g, "keep_trim", center, (X, Y, Z), (2 * hx + 0.20, 2 * hy + 0.20, 0.13), 0.03, STONE_TILE, None, rng, 0.003)

	# --- porche de la puerta --------------------------------------------------------------------
	def porch(self) -> None:
		g, rng = self.g, self.rng
		n_h = -X
		t = Z.cross(n_h).normalized()        # = -Y
		door = Opening(0.0, 1.9, 0.0, 2.45, True, 0.20)
		front = Face(n_h, PORCH_FRONT, -PORCH_HALF, PORCH_HALF, self.c_porch, [door])
		c1 = Corner(Vector((-PORCH_FRONT, PORCH_HALF, 0)), n_h, Y, 0)
		c2 = Corner(Vector((-PORCH_FRONT, -PORCH_HALF, 0)), n_h, -Y, 1)
		front.corners = [(c1, 'A'), (c2, 'A')]
		build_face(g, front, rng, lambda i, va: 0.08 if va < 0.5 else 0.0)
		build_quoins(g, c1, self.c_porch, rng)
		build_quoins(g, c2, self.c_porch, rng)
		# lados del porche (se pierden dentro del zócalo y del muro)
		for sgn in (1, -1):
			side = Face(Y * sgn, PORCH_HALF, -(PORCH_FRONT - 0.7), PORCH_FRONT - 3.4, self.c_porch)
			# los lados van de x = -PORCH_FRONT+0.5 a x = -W
			side.umin = (-PORCH_FRONT + 0.5) * (1 if sgn == 1 else -1)
			side.umax = (-W) * (1 if sgn == 1 else -1)
			if side.umin > side.umax:
				side.umin, side.umax = side.umax, side.umin
			# t = Z x n  -> para n = +Y es -X; los u crecen hacia -X
			ux = sorted([Z.cross(Y * sgn).dot(Vector((x_, 0, 0))) for x_ in (-PORCH_FRONT + 0.5, -W)])
			side.umin, side.umax = ux[0], ux[1]
			build_face(g, side, rng)
		# puerta con marco, dovelas, hojas y herrajes
		frame_opening(g, front, door, rng, 0.55, 'door')
		self.door_leaves(front, door)
		# umbral
		axis_box(g, "keep_trim", (-PORCH_FRONT - 0.30, -1.15, FOOT_Z + 1.0), (-PORCH_FRONT + 0.9, 1.15, 0.12), 0.03,
				STONE_TILE, None, rng, 0.003)
		# remate del porche: cornisa y tejadillo
		self.porch_roof()

	def door_leaves(self, front, door) -> None:
		"""Dos hojas de tablones verticales con arco, flejes de hierro con punta, remaches y tirador."""
		g, rng = self.g, self.rng
		n, t = front.n, front.t
		base = front.origin()
		d = -0.40            # plano de las hojas, dentro del hueco
		hw = door.half - 0.02
		z0, z1 = 0.08, door.z1
		steps = 12

		def P(u, z, dd=d):
			return base + t * u + Z * z + n * dd

		for sgn in (-1, 1):
			u0 = 0.015 * sgn
			u1 = sgn * hw
			arc = []
			for i in range(1, steps):
				a = math.pi * 0.5 * i / steps
				arc.append(P(sgn * hw * math.cos(a), z1 + hw * math.sin(a)))
			poly = [P(u0, z0), P(u1, z0), P(u1, z1)] + arc + [P(u0, z1 + hw)]
			uvs = [(p.dot(Z) / WOOD_TILE, (p.dot(t) * sgn) / WOOD_TILE) for p in poly]
			g.add("keep_wood", poly, uvs, n)
			# juntas de los tablones: ranuras oscuras verticales
			for k in range(1, 4):
				u = sgn * hw * k / 4.0
				top = z1 + math.sqrt(max(hw * hw - u * u, 0.0)) - 0.03
				beam(g, "keep_dark", P(u, z0 + 0.02, d + 0.012), P(u, top, d + 0.012), 0.012, 0.012, 0.0, WOOD_TILE, n)
			# tres flejes de hierro desde el gozne, con remate en punta, y sus remaches
			for zf in (0.62, 1.55, 2.38):
				end = sgn * 0.20 * hw
				beam(g, "keep_iron", P(u1, zf, d + 0.03), P(end, zf, d + 0.03), 0.12, 0.028, 0.004, WOOD_TILE, n)
				tip = [P(end, zf + 0.06, d + 0.03), P(end, zf - 0.06, d + 0.03), P(end - sgn * 0.17, zf, d + 0.03)]
				g.add("keep_iron", tip, [(0, 0), (1, 0), (0.5, 1)], n)
				for k in range(0, 6):
					u = end + (u1 - end) * (0.10 + 0.84 * k / 5.0)
					cone_stud(g, "keep_iron", P(u, zf, d + 0.032), n, t, 0.026, 0.020)
				# pernio del gozne: cilindro corto en el canto de la hoja
				hinge = P(u1 - sgn * 0.02, zf, d + 0.03)
				cylinder(g, "keep_iron", (hinge.x, hinge.y), 0.035, zf - 0.10, zf + 0.10, 6, STONE_TILE, 1.0, True)
			# tirador: anillo de hierro sobre una chapa
			torus(g, "keep_iron", P(sgn * 0.22, 1.25, d + 0.075), t, Z, 0.07, 0.014)
			cone_stud(g, "keep_iron", P(sgn * 0.22, 1.325, d + 0.03), n, t, 0.04, 0.035, 6)
		# barra y placa de cerradura sobre las dos hojas
		axis_box(g, "keep_iron", base + t * -0.30 + Z * 1.04 + n * (d + 0.03),
				base + t * 0.30 + Z * 1.12 + n * (d + 0.065), 0.004, STONE_TILE, None, rng)

	def porch_roof(self) -> None:
		g, rng = self.g, self.rng
		# cornisa de piedra sobre el porche
		center = Vector((-PORCH_FRONT + 0.50, 0.0, PORCH_TOP - 0.15))
		bevel_box(g, "keep_trim", center, (X, Y, Z), (1.30 + 0.4, 2 * PORCH_HALF + 0.5, 0.30), 0.03, STONE_TILE, None, rng, 0.004)
		# tejadillo: una vertiente de tejas apoyada en el muro, con aleros
		xe = -PORCH_FRONT - 0.30     # alero
		xw = -W + 0.02               # muro
		ze = PORCH_TOP + 0.12
		zw = PORCH_TOP + 1.35
		yh = PORCH_HALF + 0.30
		slope = Vector((xw - xe, 0, zw - ze))
		length = slope.length
		sdir = slope / length
		nrm = Vector((-sdir.z, 0, sdir.x))
		if nrm.z < 0:
			nrm = -nrm
		thick = 0.10
		pts_top = [Vector((xe, -yh, ze)), Vector((xe, yh, ze)), Vector((xw, yh, zw)), Vector((xw, -yh, zw))]
		uv_top = [(-yh / ROOF_TILE, 0), (yh / ROOF_TILE, 0), (yh / ROOF_TILE, length / ROOF_TILE), (-yh / ROOF_TILE, length / ROOF_TILE)]
		g.add("keep_roof", pts_top, uv_top, nrm)
		bottom = [p - nrm * thick for p in pts_top]
		g.add("keep_wood", bottom, [(p.y / WOOD_TILE, p.x / WOOD_TILE) for p in bottom], -nrm)
		# canto del alero y los dos laterales
		g.add("keep_wood", [bottom[0], bottom[1], pts_top[1], pts_top[0]], [(0, 0), (1, 0), (1, 0.1), (0, 0.1)], -sdir)
		for a, b, sgn in ((0, 3, -1), (1, 2, 1)):
			g.add("keep_wood", [bottom[a], bottom[b], pts_top[b], pts_top[a]], [(0, 0), (1, 0), (1, 0.1), (0, 0.1)], Y * sgn)
		# hastiales de piedra bajo la vertiente
		for sgn in (-1, 1):
			y = sgn * (PORCH_HALF + 0.12)
			tri = [Vector((-PORCH_FRONT + 0.15, y, PORCH_TOP + 0.10)), Vector((-W + 0.01, y, PORCH_TOP + 0.10)),
					Vector((-W + 0.01, y, zw - 0.12))]
			g.add("keep_trim", tri, [(p.x / STONE_TILE, p.z / STONE_TILE) for p in tri], Y * sgn)
			tri2 = [Vector((tri[0].x, y - sgn * 0.14, tri[0].z)), Vector((tri[1].x, y - sgn * 0.14, tri[1].z)),
					Vector((tri[2].x, y - sgn * 0.14, tri[2].z))]
			g.add("keep_trim", tri2, [(p.x / STONE_TILE, p.z / STONE_TILE) for p in tri2], -Y * sgn)

	# --- cadalso de madera ----------------------------------------------------------------------
	def hoarding(self) -> None:
		g, rng = self.g, self.rng
		H = W + 1.15
		turret_cut = W - TURRET_IN - 0.13
		sides = []
		# cada lado: (normal, u0, u1) con u a lo largo de la tangente t = Z x n
		for n_h in (X, Y, -X, -Y):
			t = Z.cross(n_h).normalized()
			lo, hi = -H, H
			# la torrecilla (NE) corta los lados E y N
			if n_h == X:
				hi = turret_cut
			elif n_h == Y:
				lo = -turret_cut
			sides.append((n_h, t, lo, hi))
		post_h0, post_h1 = WALK_Z, 20.40
		for n_h, t, lo, hi in sides:
			# soportes: ménsulas cada ~1,5 m
			count = int((hi - lo) / 1.5) + 1
			us = [lo + 0.60 + (hi - lo - 1.20) * k / max(count - 1, 1) for k in range(count)]
			for u in us:
				base = t * u
				# vigueta voladiza
				a = base + n_h * (W - 0.15) + Z * 18.42
				b = base + n_h * (H + 0.12) + Z * 18.42
				beam(g, "keep_wood", a, b, 0.22, 0.24, 0.012, WOOD_TILE, Z, rng, 0.004)
				# riostra diagonal (ménsula)
				c = base + n_h * (W + 0.50) + Z * 17.98
				d = base + n_h * (H - 0.20) + Z * 18.34
				beam(g, "keep_wood", c, d, 0.19, 0.19, 0.012, WOOD_TILE, Z, rng, 0.004)
				# pie de la riostra contra la cornisa
				axis_pad = base + n_h * (W + 0.45) + Z * 17.95
				bevel_box(g, "keep_wood", axis_pad, (t, n_h, Z), (0.30, 0.10, 0.22), 0.01, WOOD_TILE, Z, rng, 0.003)
				# poste vertical exterior
				pa = base + n_h * (H - 0.04) + Z * post_h0
				pb = base + n_h * (H - 0.04) + Z * post_h1
				beam(g, "keep_wood", pa, pb, 0.22, 0.22, 0.012, WOOD_TILE, n_h, rng, 0.004)
			# solera de tablas (la veta va hacia afuera)
			deck_center = n_h * ((W + H + 0.12) * 0.5 - 0.02) + t * ((lo + hi) * 0.5) + Z * (WALK_Z - 0.04)
			bevel_box(g, "keep_wood", deck_center, (n_h, t, Z), (H + 0.12 - W + 0.04, hi - lo, 0.09), 0.006, WOOD_TILE, n_h)
			# viga de borde y barandal alto
			rail_center = n_h * (H - 0.04) + t * ((lo + hi) * 0.5) + Z * 20.30
			bevel_box(g, "keep_wood", rail_center, (n_h, t, Z), (0.20, hi - lo, 0.17), 0.012, WOOD_TILE, t)
			base_center = n_h * (H - 0.04) + t * ((lo + hi) * 0.5) + Z * (WALK_Z + 0.10)
			bevel_box(g, "keep_wood", base_center, (n_h, t, Z), (0.20, hi - lo, 0.17), 0.012, WOOD_TILE, t)
			# tablas verticales por fuera: fila baja continua y fila alta con aspilleras
			board_w = 0.235
			u = lo + 0.10
			while u < hi - 0.12:
				bw = board_w + rng.uniform(-0.02, 0.02)
				if u + bw > hi - 0.08:
					bw = hi - 0.08 - u
				if bw < 0.06:
					break
				ub = u + bw * 0.5
				h_lo = WALK_Z + 0.16
				h_hi = 19.62 + rng.uniform(-0.05, 0.05)
				bevel_box(g, "keep_wood", n_h * (H + 0.04) + t * ub + Z * ((h_lo + h_hi) * 0.5),
						(n_h, t, Z), (0.07, bw - 0.018, h_hi - h_lo), 0.006, WOOD_TILE, Z, rng, 0.003)
				# fila alta salvo en el centro de cada vano entre postes
				phase = ((ub - lo) % 1.5) / 1.5
				if not (0.28 < phase < 0.72):
					z_lo = 19.70
					z_hi = 20.22 + rng.uniform(-0.04, 0.04)
					bevel_box(g, "keep_wood", n_h * (H + 0.04) + t * ub + Z * ((z_lo + z_hi) * 0.5),
							(n_h, t, Z), (0.07, bw - 0.018, z_hi - z_lo), 0.006, WOOD_TILE, Z, rng, 0.003)
				u += bw
		# tapas de los extremos que topan con la torrecilla
		cap_x = turret_cut
		for n_h, t, lo, hi in sides:
			if (n_h == X and hi == turret_cut) or (n_h == Y and lo == -turret_cut):
				end_u = hi if n_h == X else lo
				pos = t * end_u
				c = n_h * ((W + H) * 0.5) + pos + Z * 19.55
				bevel_box(g, "keep_wood", c, (n_h, t, Z), (H - W + 0.06, 0.10, 1.7), 0.008, WOOD_TILE, Z, rng, 0.003)
		_ = cap_x

	# --- torrecilla ----------------------------------------------------------------------------
	def turret_top(self) -> None:
		g, rng = self.g, self.rng
		x0, x1 = W - TURRET_IN, W + TURRET_OUT_HIGH
		rect = (x0, x1, x0, x1)
		# ladrillo: la parte alta de la torrecilla, desde la cornisa hasta su remate
		ex, ey = X, Y
		xo, yo = x1, x1
		corner_out = Corner(Vector((xo, yo, 0)), ex, ey, 0)
		corner_bc = Corner(Vector((x0, yo, 0)), ey, -ex, 1, fixed=(Corner.SHORT, TURRET_OUT_HIGH))
		corner_ad = Corner(Vector((xo, x0, 0)), ex, -ey, 1, fixed=(Corner.SHORT, TURRET_OUT_HIGH))
		fa = Face(ex, x1, x0, x1, self.c_turret)
		fa.corners = [(corner_out, 'A'), (corner_ad, 'A')]
		fa.openings = [Opening((x0 + x1) * 0.5, 0.28, 19.4, 21.0, False, 0.16)]
		fb = Face(ey, x1, -x1, -x0, self.c_turret)
		fb.corners = [(corner_out, 'B'), (corner_bc, 'A')]
		fb.openings = [Opening(-(x0 + x1) * 0.5, 0.28, 19.4, 21.0, False, 0.16)]
		for f in (fa, fb):
			build_face(g, f, rng)
			for op in f.openings:
				frame_opening(g, f, op, rng, 0.6, 'slit')
		for c in (corner_out, corner_bc, corner_ad):
			build_quoins(g, c, self.c_turret, rng)
		# corona con vuelo y tejado piramidal de tejas
		loft(g, "keep_trim", rect, [(-0.3, TURRET_TOP - 0.02), (0.20, TURRET_TOP - 0.02), (0.20, TURRET_TOP + 0.20),
				(-0.3, TURRET_TOP + 0.20)], STONE_TILE)
		cx = (x0 + x1) * 0.5
		half = (x1 - x0) * 0.5 + 0.40
		eave_z = TURRET_TOP + 0.20
		apex = Vector((cx, cx, TURRET_ROOF_APEX))
		ring = [Vector((cx - half, cx - half, eave_z)), Vector((cx + half, cx - half, eave_z)),
				Vector((cx + half, cx + half, eave_z)), Vector((cx - half, cx + half, eave_z))]
		slope_len = math.hypot(half, TURRET_ROOF_APEX - eave_z)
		for i in range(4):
			a, b = ring[i], ring[(i + 1) % 4]
			mid = (a + b) * 0.5
			hint = Vector((mid.x - cx, mid.y - cx, 0.4))
			g.add("keep_roof", [a, b, apex], [(0, 0), ((b - a).length / ROOF_TILE, 0),
					((b - a).length / ROOF_TILE * 0.5, slope_len / ROOF_TILE)], hint)
			# dos hileras de tablas de borde (cara inferior)
			g.add("keep_wood", [b, a, Vector((cx, cx, eave_z - 0.25))], [(0, 0), (1, 0), (0.5, 1)], -hint)
		# cumbrera con remate
		cylinder(g, "keep_iron", (cx, cx), 0.04, TURRET_ROOF_APEX - 0.02, TURRET_ROOF_APEX + 0.09, 4, STONE_TILE, 0.0, False)

	# --- cubierta, asta y estandarte -----------------------------------------------------------
	def flagpole(self) -> None:
		"""Asta de madera sobre un pedestal de piedra en el centro del adarve, con remate de hierro
		y un gallardete largo con cola de golondrina que ondea hacia -X (la torrecilla, al noreste,
		no lo tapa desde el norte ni desde el sur)."""
		g, rng = self.g, self.rng
		cx, cy = 0.0, 0.0
		base_center = Vector((cx, cy, WALK_Z + 0.30))
		bevel_box(g, "keep_trim", base_center, (X, Y, Z), (1.0, 1.0, 0.60), 0.04, STONE_TILE, None, rng, 0.004)
		cylinder(g, "keep_wood", (cx, cy), 0.10, WALK_Z + 0.55, TOTAL_TOP - 0.10, 8, WOOD_TILE, 0.70, False)
		for sx, sy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
			a = Vector((cx + sx * 0.42, cy + sy * 0.42, WALK_Z + 0.58))
			b = Vector((cx + sx * 0.08, cy + sy * 0.08, WALK_Z + 1.65))
			beam(g, "keep_wood", a, b, 0.09, 0.09, 0.008, WOOD_TILE, Z, rng, 0.002)
		self.ball((cx, cy, TOTAL_TOP - 0.08), 0.07)
		self.pennant(cx - 0.06, cy, TOTAL_TOP - 0.20)

	def ball(self, center, radius) -> None:
		g = self.g
		c = Vector(center)
		pts = [c + X * radius, c - X * radius, c + Y * radius, c - Y * radius, c + Z * radius, c - Z * radius]
		faces = [(4, 0, 2), (4, 2, 1), (4, 1, 3), (4, 3, 0), (5, 2, 0), (5, 1, 2), (5, 3, 1), (5, 0, 3)]
		for f in faces:
			p = [pts[i] for i in f]
			g.add("keep_iron", p, [(0, 0), (1, 0), (0.5, 1)], (p[0] + p[1] + p[2]) / 3 - c)

	def pennant(self, x0, y0, z_top) -> None:
		"""Gallardete: 3,5 m de largo y 1,55 de alto en el asta, con cola de golondrina y ondulación."""
		g = self.g
		length = 3.5
		height = 1.55
		notch = 1.15
		cols, rows = 16, 8
		for j in range(rows):
			for i in range(cols):
				quad = []
				uvs = []
				for di, dj in ((0, 0), (1, 0), (1, 1), (0, 1)):
					f = (j + dj) / rows
					x_end = length - notch * (1.0 - abs(2.0 * f - 1.0))
					x = x_end * (i + di) / cols
					along = x / length
					top = z_top - 0.18 * along
					bottom = z_top - height * (1.0 - 0.18 * along)
					z = top + (bottom - top) * f
					y = y0 + 0.16 * math.sin(along * 7.0 - 0.5) * along + 0.04 * math.sin(f * 6.0 + along * 3.0)
					quad.append(Vector((x0 - x, y, z)))
					uvs.append((along, 1.0 - f))
				g.add("keep_cloth", quad, uvs, Y)
		# manga: cilindro corto en el asta para la jareta
		cylinder(g, "keep_cloth", (x0, y0), 0.07, z_top - height * 1.0, z_top + 0.02, 6, 1.0, 1.0, False)

	def foot_rubble(self) -> None:
		"""Piedras sueltas y sillares caídos alrededor del pie del zócalo, medio enterrados: atan el
		torreón a la colina y tapan el borde en pendiente."""
		g = self.g
		rng = random.Random(4242)
		count = 0
		for side, n_h in enumerate([X, Y, -X, -Y]):
			t = Z.cross(n_h).normalized()
			u = -PLINTH_HALF_BOTTOM + 0.3
			while u < PLINTH_HALF_BOTTOM - 0.2:
				if side == 2 and abs(u) < PORCH_HALF + 0.9:
					u += 0.8
					continue
				size = Vector((rng.uniform(0.55, 1.15), rng.uniform(0.40, 0.75), rng.uniform(0.28, 0.55)))
				out = PLINTH_HALF_BOTTOM + rng.uniform(0.12, 0.50)
				if rng.random() < 0.2:
					out += rng.uniform(0.25, 0.65)
				center = n_h * out + t * u + Z * rng.uniform(-0.02, 0.10)
				yaw = rng.uniform(-0.45, 0.45)
				ex = (t * math.cos(yaw) + n_h * math.sin(yaw)).normalized()
				ey = Z.cross(ex).normalized()
				bevel_box(g, "keep_stone", center, (ex, ey, Z), (size.x, size.y, size.z), 0.09, STONE_TILE, None, rng, 0.03)
				u += size.x * rng.uniform(0.75, 1.1)
				count += 1
		_ = count

	def run(self) -> Geo:
		self.plinth()
		self.foot_rubble()
		self.bays_and_piers()
		self.string_courses()
		self.parapet()
		self.porch()
		self.hoarding()
		self.turret_top()
		self.flagpole()
		return self.g


# ---------------------------------------------------------------------------------------------
# LOD lejano y colisión
# ---------------------------------------------------------------------------------------------
def build_lod1() -> Geo:
	g = Geo()
	rng = random.Random(7)
	far = "keep_stone_far"
	tile = 4.0

	def prism(lo, hi, mat=far, bevel=0.0):
		axis_box(g, mat, lo, hi, bevel, tile, None, None)

	# zócalo ataludado
	loft(g, far, (-1.0, 1.0, -1.0, 1.0), [(PLINTH_HALF_BOTTOM - 1.0, FOOT_Z), (PLINTH_HALF_BOTTOM - 1.0, 0.0),
			(PLINTH_HALF_TOP - 1.0, PLINTH_TOP), (W - 1.0, PLINTH_TOP + 0.48)], tile)
	# muro central (z desde la repisa hasta el cadalso)
	loft(g, far, (-W, W, -W, W), [(0.0, PLINTH_TOP + 0.4), (0.0, 18.36)], tile)
	# contrafuertes bajos y altos
	for sx, sy in ((1, 1), (-1, 1), (-1, -1), (1, -1)):
		is_turret = sx == 1 and sy == 1
		pin = TURRET_IN if is_turret else PIER_IN
		po_low = TURRET_OUT_LOW if is_turret else PIER_OUT_LOW
		po_high = TURRET_OUT_HIGH if is_turret else PIER_OUT_HIGH
		for lo_z, hi_z, po in ((PLINTH_TOP + 0.3, CORDON_Z1, po_low), (CORDON_Z1, CORNICE_Z0, po_high)):
			x0, x1 = sorted([sx * (W - pin), sx * (W + po)])
			y0, y1 = sorted([sy * (W - pin), sy * (W + po)])
			prism((x0, y0, lo_z), (x1, y1, hi_z))
	# cornisa, cadalso y parapeto
	ring = W + PIER_OUT_HIGH
	loft(g, "keep_trim", (-ring, ring, -ring, ring),
			[(-PIER_OUT_HIGH, CORNICE_Z0), (0.17, CORNICE_Z0), (0.17, 18.36), (-PIER_OUT_HIGH, 18.36)], tile)
	loft(g, "keep_wood", (-W, W, -W, W), [(0.0, 18.5), (1.15, 18.5), (1.15, 20.4), (0.0, 20.4)], tile)
	loft(g, far, (-W, W, -W, W), [(0.0, 18.36), (0.0, PARAPET_TOP)], tile)
	loft(g, "keep_trim", (-W, W, -W, W), [(0.0, PARAPET_TOP), (0.11, PARAPET_TOP), (0.11, COPING_TOP), (-0.8, COPING_TOP)], tile)
	# almenas simples
	m_w = 1.1
	gap = (2 * W - 4 * m_w) / 3.0
	for side, n_h in enumerate([X, Y, -X, -Y]):
		t = Z.cross(n_h).normalized()
		pos = -W
		for k in range(4):
			if not (k in (0, 3) and side != 0):
				center = n_h * (W - 0.4) + t * (pos + m_w * 0.5) + Z * ((COPING_TOP + MERLON_TOP) * 0.5)
				bevel_box(g, "keep_trim", center, (t, n_h, Z), (m_w, 0.8, MERLON_TOP - COPING_TOP), 0.0, tile)
			pos += m_w + gap
	# torrecilla
	x0, x1 = W - TURRET_IN, W + TURRET_OUT_HIGH
	prism((x0, x0, CORNICE_Z0 - 0.1), (x1, x1, TURRET_TOP))
	cx = (x0 + x1) * 0.5
	half = (x1 - x0) * 0.5 + 0.4
	eave = TURRET_TOP + 0.2
	apex = Vector((cx, cx, TURRET_ROOF_APEX))
	ring = [Vector((cx - half, cx - half, eave)), Vector((cx + half, cx - half, eave)),
			Vector((cx + half, cx + half, eave)), Vector((cx - half, cx + half, eave))]
	for i in range(4):
		a, b = ring[i], ring[(i + 1) % 4]
		hint = (a + b) * 0.5 - Vector((cx, cx, 0.0)) + Z * 0.4
		g.add("keep_roof", [a, b, apex], [(0, 0), (2, 0), (1, 2)], hint)
	# porche y puerta
	prism((-PORCH_FRONT, -PORCH_HALF, FOOT_Z), (-W, PORCH_HALF, PORCH_TOP - 0.3))
	g.add("keep_dark", [Vector((-PORCH_FRONT - 0.01, -0.95, 0.0)), Vector((-PORCH_FRONT - 0.01, 0.95, 0.0)),
			Vector((-PORCH_FRONT - 0.01, 0.95, 3.0)), Vector((-PORCH_FRONT - 0.01, -0.95, 3.0))], [(0, 0)] * 4, -X)
	axis_box(g, "keep_roof", (-PORCH_FRONT - 0.3, -PORCH_HALF - 0.3, PORCH_TOP), (-W, PORCH_HALF + 0.3, PORCH_TOP + 0.25), 0.0, ROOF_TILE)
	# huecos oscuros (saeteras y ventanas)
	for name, n_h in (("E", X), ("N", Y), ("W", -X), ("S", -Y)):
		t = Z.cross(n_h).normalized()
		for u, z0, z1, w in ((0.0, 6.3, 7.9, 0.28), (0.0, 11.2, 13.4, 0.9), (-1.5, 15.2, 16.7, 0.28), (0.0, 15.2, 16.7, 0.28),
				(1.5, 15.2, 16.7, 0.28)):
			if name in ("N", "E") and (u > 1.2 or u < -1.2):
				continue
			base = n_h * (W + 0.02) + t * u
			p = [base - t * (w * 0.5) + Z * z0, base + t * (w * 0.5) + Z * z0, base + t * (w * 0.5) + Z * z1, base - t * (w * 0.5) + Z * z1]
			g.add("keep_dark", p, [(0, 0)] * 4, n_h)
	# mástil y gallardete
	cylinder(g, "keep_wood", (0.0, 0.0), 0.11, WALK_Z, TOTAL_TOP - 0.1, 5, 3.0, 0.7, False)
	zt = TOTAL_TOP - 0.20
	pen = [Vector((-0.06, 0.0, zt)), Vector((-3.5, 0.0, zt - 0.6)), Vector((-2.4, 0.0, zt - 0.95)),
			Vector((-3.3, 0.0, zt - 1.45)), Vector((-0.06, 0.0, zt - 1.55))]
	g.add("keep_cloth", pen, [(0, 1), (1, 0.85), (0.7, 0.5), (0.95, 0.08), (0, 0)], Y)
	_ = rng
	return g


def build_collision() -> Geo:
	g = Geo()
	tile = 4.0
	loft(g, "col", (-1.0, 1.0, -1.0, 1.0), [(PLINTH_HALF_BOTTOM - 1.0, FOOT_Z), (PLINTH_HALF_BOTTOM - 1.0, 0.0),
			(PLINTH_HALF_TOP - 1.0, PLINTH_TOP), (W - 1.0, PLINTH_TOP + 0.48)], tile)
	axis_box(g, "col", (-W, -W, PLINTH_TOP), (W, W, COPING_TOP), 0.0, tile)
	for sx, sy in ((1, 1), (-1, 1), (-1, -1), (1, -1)):
		is_turret = sx == 1 and sy == 1
		pin = TURRET_IN if is_turret else PIER_IN
		# dos tramos, como el modelo: el contrafuerte se estrecha por encima del cordón
		for z0, z1, po in ((PLINTH_TOP, CORDON_Z1, TURRET_OUT_LOW if is_turret else PIER_OUT_LOW),
				(CORDON_Z1, CORNICE_Z0, TURRET_OUT_HIGH if is_turret else PIER_OUT_HIGH)):
			x0, x1 = sorted([sx * (W - pin), sx * (W + po)])
			y0, y1 = sorted([sy * (W - pin), sy * (W + po)])
			axis_box(g, "col", (x0, y0, z0), (x1, y1, z1), 0.0, tile)
	x0, x1 = W - TURRET_IN, W + TURRET_OUT_HIGH
	axis_box(g, "col", (x0, x0, CORNICE_Z0), (x1, x1, TURRET_TOP), 0.0, tile)
	axis_box(g, "col", (-PORCH_FRONT, -PORCH_HALF, FOOT_Z), (-W, PORCH_HALF, PORCH_TOP), 0.0, tile)
	return g


# ---------------------------------------------------------------------------------------------
# Volcado a Blender, materiales, exportación
# ---------------------------------------------------------------------------------------------
def load_image(path, size=None, colorspace='sRGB'):
	img = bpy.data.images.load(path, check_existing=True)
	img.colorspace_settings.name = colorspace
	if size is not None and (img.size[0] > size or img.size[1] > size):
		img.scale(size, size)
	return img


def make_material(name, color=(0.5, 0.5, 0.5, 1.0), albedo=None, normal=None, rough=0.9, metal=0.0, size=None,
		double_sided=False, normal_strength=1.0):
	mat = bpy.data.materials.new(name)
	mat.use_nodes = True
	nodes = mat.node_tree.nodes
	links = mat.node_tree.links
	bsdf = nodes.get("Principled BSDF")
	bsdf.inputs["Base Color"].default_value = color
	bsdf.inputs["Roughness"].default_value = rough
	bsdf.inputs["Metallic"].default_value = metal
	if albedo:
		tex = nodes.new("ShaderNodeTexImage")
		tex.image = load_image(albedo, size)
		tex.interpolation = 'Linear'
		tex.extension = 'REPEAT'
		links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
	if normal:
		ntex = nodes.new("ShaderNodeTexImage")
		ntex.image = load_image(normal, size, 'Non-Color')
		ntex.interpolation = 'Linear'
		ntex.extension = 'REPEAT'
		nmap = nodes.new("ShaderNodeNormalMap")
		nmap.inputs["Strength"].default_value = normal_strength
		links.new(ntex.outputs["Color"], nmap.inputs["Color"])
		links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
	mat.use_backface_culling = not double_sided
	return mat


def make_materials():
	mats = {}
	mats["keep_stone"] = make_material("keep_stone", albedo=os.path.join(TEX_OWN, "keep_stone_albedo.jpg"),
			normal=os.path.join(TEX_OWN, "keep_stone_normal.png"), rough=0.92, normal_strength=0.9)
	mats["keep_mortar"] = make_material("keep_mortar", (0.13, 0.13, 0.125, 1.0), rough=1.0)
	mats["keep_trim"] = make_material("keep_trim", albedo=os.path.join(TEX_OWN, "keep_trim_albedo.jpg"),
			normal=os.path.join(TEX_OWN, "keep_trim_normal.png"), rough=0.85, normal_strength=0.8)
	mats["keep_wood"] = make_material("keep_wood", albedo=os.path.join(TEX_CASTLE, "wood_wall_albedo.png"),
			normal=os.path.join(TEX_CASTLE, "wood_wall_normal.png"), rough=0.88, size=512)
	mats["keep_iron"] = make_material("keep_iron", (0.09, 0.09, 0.10, 1.0), rough=0.45, metal=0.85)
	mats["keep_dark"] = make_material("keep_dark", (0.012, 0.012, 0.015, 1.0), rough=1.0)
	mats["keep_cloth"] = make_material("keep_cloth", albedo=os.path.join(TEX_OWN, "keep_banner_albedo.png"), rough=0.95,
			double_sided=True, size=512)
	mats["keep_roof"] = make_material("keep_roof", albedo=os.path.join(TEX_VILLAGE, "t_round_tiles_base_color.png"),
			normal=os.path.join(TEX_VILLAGE, "t_round_tiles_normal.png"), rough=0.8, size=512)
	mats["keep_stone_far"] = make_material("keep_stone_far", albedo=os.path.join(TEX_CASTLE, "brick_wall_albedo.png"),
			normal=os.path.join(TEX_CASTLE, "brick_wall_normal.png"), rough=0.9, size=512)
	mats["col"] = make_material("col", (1, 0, 1, 1))
	return mats


def to_object(name, geo, mats, collection):
	"""Convierte un Geo en un objeto de Blender con un hueco de material por material usado."""
	used = []
	for mat, _pts, _uv in geo.faces:
		if mat not in used:
			used.append(mat)
	order = [m for m in MATERIALS + ["col"] if m in used]
	index = {m: i for i, m in enumerate(order)}
	verts = []
	polys = []
	mat_index = []
	for mat, pts, _uv in geo.faces:
		start = len(verts)
		verts.extend([tuple(p) for p in pts])
		polys.append(tuple(range(start, start + len(pts))))
		mat_index.append(index[mat])
	mesh = bpy.data.meshes.new(name)
	mesh.from_pydata(verts, [], polys)
	for m in order:
		mesh.materials.append(mats[m])
	uv_layer = mesh.uv_layers.new(name="UVMap")
	loop = 0
	for poly_i, (_mat, pts, uvs) in enumerate(geo.faces):
		mesh.polygons[poly_i].material_index = mat_index[poly_i]
		mesh.polygons[poly_i].use_smooth = False
		for k in range(len(pts)):
			uv_layer.data[loop].uv = uvs[k]
			loop += 1
	mesh.update()
	obj = bpy.data.objects.new(name, mesh)
	collection.objects.link(obj)
	return obj


def parse_args():
	argv = sys.argv
	argv = argv[argv.index("--") + 1:] if "--" in argv else []
	opts = {"out": DEFAULT_OUT, "render": None, "blend": None}
	i = 0
	while i < len(argv):
		if argv[i] in ("--out", "--render", "--blend") and i + 1 < len(argv):
			opts[argv[i][2:]] = argv[i + 1]
			i += 2
		else:
			i += 1
	return opts


def main() -> None:
	opts = parse_args()
	bpy.ops.wm.read_factory_settings(use_empty=True)
	scene = bpy.context.scene
	collection = scene.collection
	mats = make_materials()

	builder = Builder()
	lod0 = builder.run()
	lod1 = build_lod1()
	col = build_collision()
	obj0 = to_object("FortKeep_LOD0", lod0, mats, collection)
	obj1 = to_object("FortKeep_LOD1", lod1, mats, collection)
	objc = to_object("FortKeep-colonly", col, mats, collection)

	xs = [v.co for v in obj0.data.vertices]
	top = max(v.z for v in xs)
	print("FORTKEEP triangulos LOD0=%d LOD1=%d colision=%d" % (lod0.triangle_count(), lod1.triangle_count(), col.triangle_count()))
	print("FORTKEEP altura LOD0=%.2f m (min %.2f) anchura=%.2f m" % (top, min(v.z for v in xs),
			max(v.x for v in xs) - min(v.x for v in xs)))
	print("FORTKEEP caras LOD0=%d" % len(lod0.faces))

	os.makedirs(os.path.dirname(opts["out"]), exist_ok=True)
	bpy.ops.object.select_all(action='DESELECT')
	bpy.ops.export_scene.gltf(
		filepath=opts["out"], export_format='GLB', use_selection=False, export_apply=True, export_yup=True,
		export_image_format='AUTO', export_texcoords=True, export_normals=True, export_tangents=False,
		export_materials='EXPORT', export_cameras=False, export_lights=False, export_extras=False,
		export_animations=False, export_draco_mesh_compression_enable=False)
	print("FORTKEEP exportado %s (%.1f MB)" % (opts["out"], os.path.getsize(opts["out"]) / 1048576.0))
	if opts["blend"]:
		bpy.ops.wm.save_as_mainfile(filepath=opts["blend"])
	if opts["render"]:
		render_previews(opts["render"], obj0, obj1, objc)


def render_previews(folder, obj0, obj1, objc) -> None:
	"""Renders del modelo solo con Eevee (vistas de comprobación rápida)."""
	os.makedirs(folder, exist_ok=True)
	scene = bpy.context.scene
	objc.hide_render = True
	obj1.hide_render = True
	scene.render.engine = 'BLENDER_EEVEE'
	scene.render.resolution_x = 1280
	scene.render.resolution_y = 1280
	world = bpy.data.worlds.new("w")
	world.use_nodes = True
	bg = world.node_tree.nodes["Background"]
	bg.inputs["Color"].default_value = (0.62, 0.68, 0.74, 1.0)
	bg.inputs["Strength"].default_value = 0.9
	scene.world = world
	sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", 'SUN'))
	sun.data.energy = 4.0
	sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(-35))
	scene.collection.objects.link(sun)
	cam_data = bpy.data.cameras.new("cam")
	cam = bpy.data.objects.new("cam", cam_data)
	scene.collection.objects.link(cam)
	scene.camera = cam
	views = {
		"sw": (Vector((-27, -33, 12.5)), Vector((0, 0, 11.5))),
		"ne": (Vector((30, 30, 13)), Vector((0, 0, 11.5))),
		"puerta": (Vector((-13.5, -4.0, 3.0)), Vector((-5.0, 0.0, 3.4))),
		"cadalso": (Vector((-9.0, -8.5, 20.5)), Vector((-1.0, -0.5, 20.2))),
	}
	for name, (loc, target) in views.items():
		cam.location = loc
		direction = target - loc
		cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
		cam_data.lens = 40 if name in ("sw", "ne") else 35
		scene.render.filepath = os.path.join(folder, "blender_%s.png" % name)
		bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
	main()
