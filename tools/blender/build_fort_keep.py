"""Torreón del fuerte del Vado Gris (ART-57), modelado desde cero en Blender con código. Versión 2.

Genera assets/models/environment/custom/fort_keep.glb: un torreón de piedra de unos 26 m (con el
asta) y 9,1 m de planta, con zócalo ataludado, muro con talud suave y a haces (sin pilastras ni
paños rehundidos), esquinas de sillares grandes abrazando las dos caras, saeteras y ventanas
profundas, cordón, cornisa con canecillos, cadalso de madera bajo un tejado a cuatro aguas,
parapeto almenado, torrecilla de escalera con tejadillo, puerta con arco de dovelas y herrajes
bajo un porche, estandartes en un nodo propio y un pie enterrado en la colina con piedras caídas y
una falda de tierra.

Uso, desde la raíz del repo (antes hay que generar las texturas propias):

    python tools/blender/make_fort_keep_textures.py
    blender --background --factory-startup --python tools/blender/build_fort_keep.py -- [opciones]

Opciones tras "--":
    --out <ruta.glb>      GLB de salida (por defecto assets/models/environment/custom/fort_keep.glb)
    --render <carpeta>    además guarda renders del modelo solo (Eevee) en esa carpeta (ruta
                          absoluta o relativa a donde se lanza Blender: se normaliza)
    --blend <ruta.blend>  guarda también la escena de Blender (no se versiona)

Qué contiene el GLB (nodos de primer nivel):
    FortKeep_LOD0      detalle completo (sillares modelados), unos 60 000 triángulos
    FortKeep_LOD1      nivel medio, unos 5 000 triángulos: muros lisos con la textura de sillería
                       despiezada (keep_wall), cadalso, ménsulas, vanos y puerta con su geometría
    FortKeep_LOD2      versión lejana, unos 600 triángulos
    Estandarte         gallardete del asta y pendones colgados del cadalso, fuera de las mallas de
                       los LOD para que el controlador del fuerte mueva faction_color, emblem_index y
                       capture_progress (instance uniforms de fort_keep_cloth.gdshader) y el
                       viento lo mueva el shader (el peso del viento va en el alfa del color de vértice)
    FortKeep-colonly   colisión aparte de baja resolución (Godot la importa como StaticBody3D con
                       trimesh y no dibuja la malla): cuerpo, porche, cadalso, parapeto, tejado y
                       torrecilla

Rangos de visibilidad recomendados (los pone el código del juego, no el glTF; ver
scripts/client/tools/fort_keep_preview.gd): LOD0 hasta 50 m, LOD1 de 50 a 250 m y LOD2 desde 250 m,
con visibility_range_fade_mode SELF y 10 m de margen. LOD0 acaba pronto porque las juntas modeladas
(2,4 cm) son subpíxel a 30 m o más y centellean al moverse; el LOD1 centellea la mitad.

Ejes: se modela en Z arriba con la puerta hacia -X de Blender; el exportador lo pasa a Y arriba de
glTF/Godot, así que la puerta mira a -X en Godot (hacia la puerta del fuerte). Origen: centro del
torreón a la altura del suelo; el zócalo baja 1,2 m bajo el origen para enterrarse en la colina.
Planta: 9,1 m de zócalo (con el porche, 10,0 m en el eje de la puerta; las piedras caídas añaden
unos 0,5 m): antes de conectarlo hay que recolocar el CaptureCircle (radio 5 m, centro en
x = -8,5) y el CaptainSpawn, reornear vado_gris_navmesh.tres y corregir docs/zonas/vado_gris.md
(dice torre de 6 x 6 x 12 m).

Color de vértice (COLOR_0, lineal), que lee fort_keep_surface.gdshader:
    RGB   valor y tono del sillar (+-8 %), oclusión de las juntas, suciedad del pie, churretes
          bajo vanos, ménsulas y cornisa
    A     máscara de desgaste: musgo, polvo o ceniza (según el reino) y, en la piedra, dónde brillan
          las grietas de brasa de Eldrun; en la argamasa, la brasa de las juntas; en el tejado,
          los trozos que faltan en ruina; en las telas, el peso del viento

Materiales (por nombre, para que el juego los cambie por los de reino):
    keep_stone      sillares de cara          keep_mortar   fondo de las juntas
    keep_trim       piedra labrada            keep_wood     madera pintada
    keep_iron       herrajes                  keep_dark     huecos de saeteras y ventanas
    keep_cloth      gallardete                keep_pendant  pendones colgantes
    keep_roof       tablillas del tejado      keep_wall     paño de sillería despiezada (LOD 1 y 2)
    keep_earth      falda de tierra del pie

Ajustes de importación del GLB que NO son los de por defecto y hay que conservar si el editor
regenera fort_keep.glb.import (el .import está versionado; si se recrea, volver a ponerlos):
    meshes/generate_lods = false        los LOD son los de este archivo, con rangos y fundido propios;
                                        el generador automático de Godot los pisaría y deformaría los
                                        vanos y la puerta
    gltf/embedded_image_handling = 3    (insertar sin comprimir). Este GLB ya no lleva imágenes
                                        (los materiales de reino cargan las texturas desde
                                        fort_keep/textures/), pero se mantiene el valor para que un
                                        .import recreado no extraiga texturas junto al modelo

Es determinista: semillas fijas.
"""

import math
import os
import random
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
MODELS = os.path.join(ROOT, "assets", "models", "environment")
DEFAULT_OUT = os.path.join(MODELS, "custom", "fort_keep.glb")

Z = Vector((0.0, 0.0, 1.0))
X = Vector((1.0, 0.0, 0.0))
Y = Vector((0.0, 1.0, 0.0))

# ---------------------------------------------------------------------------------------------
# Medidas (m)
# ---------------------------------------------------------------------------------------------
FOOT_Z = -1.2                 # fondo del zócalo, enterrado
PLINTH_HALF_BOTTOM = 4.55     # semilado del zócalo a ras de suelo (z = 0)
PLINTH_HALF_TOP = 4.05
PLINTH_TOP = 3.00             # arriba del zócalo ataludado
LEDGE_TOP = 3.25              # primera hilada del muro (la repisa la tapa por abajo)
H_WALL0 = 3.58                # semilado del muro a z = LEDGE_TOP
SLOPE_LOW = -0.030            # talud (m de semilado por m de altura) de la parte baja
CORDON_Z0, CORDON_Z1 = 8.55, 8.90
CORDON_STEP = 0.10            # lo que el muro entra por encima del cordón
SLOPE_UP = -0.022
CORNICE_Z0 = 14.00            # cornisa con canecillos bajo el cadalso
WALK_Z = 14.90                # suelo del adarve y del cadalso
PARAPET_BASE = 14.30
PARAPET_TOP = 16.05
COPING_TOP = 16.25
MERLON_TOP = 17.45
PLATE_Z = 17.60               # carrera sobre la que apoya el tejado
ROOF_EAVE_Z = 17.72
ROOF_APEX_Z = 22.00
TURRET_TOP = 20.90
TURRET_ROOF_APEX = 23.60
TOTAL_TOP = 25.80             # punta del asta
HOARD_OUT = 1.10              # cuánto sale el cadalso del muro de arriba
ROOF_OVERHANG = 0.55
PORCH_FRONT = PLINTH_HALF_BOTTOM + 0.38   # cara delantera del porche de la puerta (a -X)
PORCH_HALF = 1.70
PORCH_TOP = 4.90

BLOCK_GAP = 0.012
STONE_TILE = 3.2              # metros por baldosa de la textura de piedra
WOOD_TILE = 3.0
ROOF_TILE = 2.0               # una tablilla de la textura mide 0,2 m de hilada

MATERIALS = ["keep_stone", "keep_mortar", "keep_trim", "keep_wood", "keep_iron", "keep_dark",
		"keep_cloth", "keep_pendant", "keep_roof", "keep_wall", "keep_earth"]

# Color base de cada material en el glTF (solo se ve si el juego no lo sustituye por el de reino).
MATERIAL_COLORS = {
	"keep_stone": (0.46, 0.46, 0.45), "keep_mortar": (0.17, 0.16, 0.15), "keep_trim": (0.58, 0.57, 0.55),
	"keep_wood": (0.30, 0.21, 0.14), "keep_iron": (0.08, 0.08, 0.09), "keep_dark": (0.012, 0.012, 0.015),
	"keep_cloth": (0.80, 0.78, 0.70), "keep_pendant": (0.80, 0.78, 0.70), "keep_roof": (0.28, 0.30, 0.34),
	"keep_wall": (0.46, 0.46, 0.45), "keep_earth": (0.30, 0.27, 0.19), "col": (1.0, 0.0, 1.0),
}


def wall_half(z: float) -> float:
	"""Semilado del muro (sin sillares) a la altura z: talud suave, con un retranqueo en el cordón."""
	if z < CORDON_Z1:
		return H_WALL0 + SLOPE_LOW * (z - LEDGE_TOP)
	h_cordon = H_WALL0 + SLOPE_LOW * (CORDON_Z0 - LEDGE_TOP) - CORDON_STEP
	return h_cordon + SLOPE_UP * (z - CORDON_Z1)


H_TOP = wall_half(CORNICE_Z0)             # semilado del muro bajo la cornisa
HOARD_H = H_TOP + HOARD_OUT               # semilado del cadalso (cara exterior)
ROOF_R = HOARD_H + ROOF_OVERHANG          # semilado del alero


class Style:
	"""Parámetros de despiece y de acabado de un paño de sillares."""

	def __init__(self, tile=STONE_TILE, lo=0.72, hi=1.5, min_len=0.42, depth=0.075, chamfer=0.030,
			gap=BLOCK_GAP, drop=0.034, quoin=(0.95, 0.55), q=0.125, sigma=0.075, ao_joint=0.45) -> None:
		self.tile = tile
		self.lo = lo
		self.hi = hi
		self.min_len = min_len
		self.depth = depth
		self.chamfer = chamfer
		self.gap = gap
		self.drop = drop
		self.quoin = quoin       # (largo, corto) de las piedras de esquina
		self.q = q               # cuánto sobresalen las piedras de esquina del plano del muro
		self.sigma = sigma       # variación de valor por sillar
		self.ao_joint = ao_joint


WALL = Style()
PLINTH = Style(lo=1.0, hi=2.3, min_len=0.6, depth=0.095, chamfer=0.045, gap=0.014, drop=0.045,
		quoin=(1.40, 0.82), q=0.17, sigma=0.085)
SMALL = Style(lo=0.5, hi=1.0, min_len=0.3, depth=0.07, chamfer=0.026, sigma=0.07)


# ---------------------------------------------------------------------------------------------
# Contexto de acabado (suciedad, churretes, brasas): lo rellenan las piezas y lo evalúa to_object
# ---------------------------------------------------------------------------------------------
class ShadeContext:
	def __init__(self) -> None:
		self.streaks = []     # (centro, normal, semiancho, largo, fuerza)
		self.ledges = []      # (z del vuelo, fondo de la sombra, fuerza)
		self.fissures = []    # (centro, normal, semiancho, z0, z1): grietas de brasa de Eldrun

	def streak(self, center, normal, half_width, length, strength) -> None:
		self.streaks.append((Vector(center), Vector(normal), half_width, length, strength))

	def ledge(self, z, depth=0.9, strength=0.32) -> None:
		self.ledges.append((z, depth, strength))

	def fissure(self, center, normal, half_width, z0, z1) -> None:
		self.fissures.append((Vector(center), Vector(normal), half_width, z0, z1))

	def reset(self) -> None:
		self.streaks.clear()
		self.ledges.clear()
		self.fissures.clear()


CTX = ShadeContext()


# ---------------------------------------------------------------------------------------------
# Acumulador de geometría
# ---------------------------------------------------------------------------------------------
class Geo:
	"""Lista de polígonos (material, puntos, UV, tinte, oclusión). Se vuelca a una malla de Blender."""

	def __init__(self) -> None:
		self.faces = []

	def add(self, mat, pts, uvs, hint=None, tint=None, ao=None) -> None:
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
		if isinstance(ao, (list, tuple)):
			ao = list(ao)
		if isinstance(tint, list):
			tint = list(tint)
		if hint is not None and n.dot(hint) < 0.0:
			pts.reverse()
			uvs.reverse()
			if isinstance(ao, list):
				ao.reverse()
			if isinstance(tint, list):
				tint.reverse()
		self.faces.append((mat, pts, uvs, tint, ao))

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


def block_tint(rng, sigma=0.05):
	"""Valor y tono propios de cada sillar (el pintor no reparte el mismo gris a todos)."""
	v = 1.0 + max(-2.0, min(2.0, rng.gauss(0.0, 1.0))) * sigma
	roll = rng.random()
	if roll < 0.06:
		v *= rng.uniform(0.80, 0.90)       # sillar oscuro, de reposición
	elif roll < 0.11:
		v *= rng.uniform(1.07, 1.13)       # sillar claro, recién picado
	w = rng.gauss(0.0, 0.022)
	return (v * (1.0 + w), v * (1.0 + 0.15 * w), v * (1.0 - w))


def board_tint(rng, sigma=0.07):
	v = 1.0 + max(-2.0, min(2.0, rng.gauss(0.0, 1.0))) * sigma
	w = rng.gauss(0.0, 0.02)
	return (v * (1.0 + w), v, v * (1.0 - w))


# ---------------------------------------------------------------------------------------------
# Primitivas
# ---------------------------------------------------------------------------------------------
def bevel_box(g, mat, center, axes, size, bevel=0.0, tile=STONE_TILE, grain=None, rng=None,
		jitter=0.0, offset=None, tint=None, skip_back=None):
	"""Caja con bisel de un tramo. axes = (ex, ey, ez) ortonormales; size = (sx, sy, sz).
	skip_back: vector; si se da, no se emiten las caras que miran en sentido contrario (las que
	quedan dentro del muro)."""
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
		if skip_back is not None and n.dot(skip_back) < -0.55:
			continue
		fu, fv = uv_frame(n, grain)
		uvs = [(p.dot(fu) / tile + offset[0], p.dot(fv) / tile + offset[1]) for p in pts]
		g.add(mat, pts, uvs, n, tint)
	bm.free()


def axis_box(g, mat, lo, hi, bevel=0.0, tile=STONE_TILE, grain=None, rng=None, jitter=0.0, tint=None):
	"""Caja alineada con los ejes entre dos esquinas."""
	lo = Vector(lo)
	hi = Vector(hi)
	center = (lo + hi) * 0.5
	size = (hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
	bevel_box(g, mat, center, (X, Y, Z), size, bevel, tile, grain, rng, jitter, tint=tint)


def plank(g, mat, center, axes, size, tile=WOOD_TILE, grain=None, rng=None, tint=None, hide=None):
	"""Tabla sin bisel (hasta 6 caras): para la multitud de tablas del cadalso. hide es un vector
	hacia el interior: no se emite la cara que lo mira."""
	vec = [Vector(a) for a in axes]
	h = (size[0] * 0.5, size[1] * 0.5, size[2] * 0.5)
	center = Vector(center)
	offset = (rng.random(), rng.random()) if rng is not None else (0.0, 0.0)
	for ai in range(3):
		for sgn in (1, -1):
			axis = vec[ai] * sgn
			if hide is not None and axis.dot(hide) > 0.9:
				continue
			b1, b2 = [vec[k] for k in range(3) if k != ai]
			h1, h2 = [h[k] for k in range(3) if k != ai]
			c = center + axis * h[ai]
			pts = [c - b1 * h1 - b2 * h2, c + b1 * h1 - b2 * h2, c + b1 * h1 + b2 * h2, c - b1 * h1 + b2 * h2]
			fu, fv = uv_frame(axis, grain)
			uvs = [(p.dot(fu) / tile + offset[0], p.dot(fv) / tile + offset[1]) for p in pts]
			g.add(mat, pts, uvs, axis, tint)


def beam(g, mat, p0, p1, w, h, bevel=0.012, tile=WOOD_TILE, up=Z, rng=None, jitter=0.0, tint=None):
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
	bevel_box(g, mat, (p0 + p1) * 0.5, (ex, ey, ez), (length, h, w), bevel, tile, ex, rng, jitter, tint=tint)


def loft(g, mat, rect, profile, tile=STONE_TILE, skip=(), tint=None, ao=None):
	"""Anillo rectangular con un perfil (h, z). rect = (xmin, xmax, ymin, ymax). El perfil va en
	sentido antihorario alrededor de la sección: la normal sale por la derecha de la marcha.
	ao: un valor, o una lista con la oclusión de cada punto del perfil."""
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
			if isinstance(ao, (list, tuple)):
				face_ao = [ao[i], ao[i], ao[i + 1], ao[i + 1]]
			else:
				face_ao = ao
			g.add(mat, pts, uvs, normal, tint, face_ao)


def cylinder(g, mat, center, radius, z0, z1, sides=8, tile=WOOD_TILE, taper=1.0, cap_top=True, tint=None):
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
		g.add(mat, [p0, p1, q1, q0], [(u0, z0 / tile), (u1, z0 / tile), (u1, z1 / tile), (u0, z1 / tile)], n, tint)
		if cap_top and taper > 0.0:
			top = Vector((cx, cy, z1))
			g.add(mat, [q0, q1, top], [(0, 0), (1, 0), (0.5, 1)], Z, tint)


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
def cut_pieces(a, b, rng, prev, style):
	"""Reparte [a, b] en sillares de largo variable evitando juntas alineadas con la hilada de abajo."""
	lo, hi, min_len = style.lo, style.hi, style.min_len
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


def stone_block(g, O, t, up, n, ua, ub, va, vb, rng, style, weathered=0.0):
	"""Un sillar: cara plana ligeramente irregular y cuatro biseles hacia la junta. Lleva su propio
	tinte y la oclusión de las juntas en el color de vértice."""
	w = ub - ua
	h = vb - va
	c = min(style.chamfer, 0.3 * w, 0.3 * h)
	gap = style.gap
	depth = style.depth + rng.uniform(-0.014, 0.016)
	if rng.random() < 0.05 + weathered:
		depth -= 0.028
	drop = style.drop
	off = (rng.random(), rng.random())
	tint = block_tint(rng, style.sigma)
	tile = style.tile

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

	aj = style.ao_joint
	ao_inner = [0.93, 0.93, 1.06, 1.06]
	ao_outer = [aj * 0.9, aj * 0.9 + 0.04, aj + 0.14, aj + 0.14]
	g.add("keep_stone", inner, [uv(c_) for c_ in inner_coords], n, tint, ao_inner)
	for k in range(4):
		k2 = (k + 1) % 4
		g.add("keep_stone", [outer[k], outer[k2], inner[k2], inner[k]],
				[uv(outer_coords[k]), uv(outer_coords[k2]), uv(inner_coords[k2]), uv(inner_coords[k])], n, tint,
				[ao_outer[k], ao_outer[k2], ao_inner[k2], ao_inner[k]])


MORTAR_TINT = (1.0, 1.0, 1.0)


def ashlar(g, O, t, up, n, course_v, spans, rng, style=WALL, weathered_fn=None, row_spans=False):
	"""Muro de sillares en un plano: O es el origen (u = 0, v = 0), t el sentido de las hiladas,
	up el sentido de subida en el plano y n la normal. spans(i, va, vb) da los tramos [(ua, ub)]
	de cada hilada (ya sin huecos ni piedras de esquina). Cada sillar lleva debajo su pieza de
	argamasa (el fondo de las juntas): así la brasa de las grietas de Eldrun puede ir por bloque."""
	prev = []
	for i in range(len(course_v) - 1):
		va, vb = course_v[i], course_v[i + 1]
		joints = []
		for ua, ub in spans(i, va, vb):
			if ub - ua < 0.03:
				continue
			for a, b in cut_pieces(ua, ub, rng, prev, style):
				weathered = weathered_fn(i, va) if weathered_fn else 0.0
				quad = [O + t * a + up * va, O + t * b + up * va, O + t * b + up * vb, O + t * a + up * vb]
				g.add("keep_mortar", quad, [(p.dot(t) / style.tile, p.dot(up) / style.tile) for p in quad], n,
						MORTAR_TINT, 0.8)
				stone_block(g, O, t, up, n, a, b, va, vb, rng, style, weathered)
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
	"""Cara de piedra entre dos esquinas. Con slope distinto de 0 es una cara con talud: el plano
	se mueve slope metros por metro de altura (negativo: se cierra hacia arriba)."""

	def __init__(self, n_h, plane, umin, umax, z_courses, openings=(), corners=(), slope=0.0, z_ref=None,
			u_slope=0.0):
		self.n = Vector(n_h)
		self.t = Z.cross(self.n).normalized()
		self.plane = plane          # distancia del plano al eje (m) a la altura z_ref
		self.slope = slope
		self.z_ref = z_courses[0] if z_ref is None else z_ref
		self.umin = umin
		self.umax = umax
		self.u_slope = u_slope      # cuánto se mueven las esquinas (umax) por metro de altura
		self.courses = z_courses
		self.openings = list(openings)
		self.corners = list(corners)  # [(corner, rol)] rol 'A' o 'B'

	def plane_at(self, z: float) -> float:
		return self.plane + self.slope * (z - self.z_ref)

	def P(self, u: float, z: float, d: float = 0.0) -> Vector:
		"""Punto de la cara: u a lo largo, altura z y d hacia fuera (horizontal) del plano."""
		return self.n * (self.plane_at(z) + d) + self.t * u + Z * z

	def origin(self) -> Vector:
		return self.n * self.plane_at(self.courses[0]) + Z * self.courses[0]

	def spans(self, i, za, zb):
		dz = za - self.z_ref
		lo = self.umin - self.u_slope * dz
		hi = self.umax + self.u_slope * dz
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
			cut = op.cut_for(za, zb)
			if cut:
				spans = subtract(spans, cut)
		return spans

	def ashlar_rows(self, g, zs, spans_fn, rng, style=WALL, weathered_fn=None):
		"""Sillares de las hiladas dadas (límites en altura) con la pendiente de la cara."""
		z0 = zs[0]
		length = math.sqrt(1.0 + self.slope * self.slope)
		O = self.n * self.plane_at(z0) + Z * z0
		up = (self.n * self.slope + Z) / length
		normal = self.t.cross(up)
		if normal.dot(self.n) < 0:
			normal = -normal
		course_v = [(z - z0) * length for z in zs]

		def spans(i, va, vb):
			return spans_fn(i, z0 + va / length, z0 + vb / length)

		ashlar(g, O, self.t, up, normal, course_v, spans, rng, style, weathered_fn)

	def build(self, g, rng, style=WALL, weathered_fn=None):
		self.ashlar_rows(g, self.courses, self.spans, rng, style, weathered_fn)


class Corner:
	"""Esquina saliente con piedras de refuerzo alternas, largas y cortas."""

	def __init__(self, point, n_a, n_b, parity=0, fixed=None, long=0.80, short=0.46):
		self.P = Vector(point)
		self.nA = Vector(n_a)
		self.nB = Vector(n_b)
		self.parity = parity
		self.fixed = fixed  # (lenA, lenB) para una esquina de retorno estrecho
		self.long = long
		self.short = short

	def lens(self, i):
		if self.fixed:
			return self.fixed
		if (i + self.parity) % 2 == 0:
			return (self.long, self.short)
		return (self.short, self.long)

	def end_of(self, face, role):
		"""'max' si la esquina está en el u máximo de la cara."""
		t = face.t
		other = self.nB if role == 'A' else self.nA
		return 'max' if t.dot(other) > 0 else 'min'


def build_quoins(g, corner, courses, rng, protrude=0.045, style=WALL):
	"""Piedras de esquina de un muro vertical: una caja con bisel por hilada, alternando largo y corto."""
	nA, nB = corner.nA, corner.nB
	for i in range(len(courses) - 1):
		za, zb = courses[i] + 0.012, courses[i + 1] - 0.012
		la, lb = corner.lens(i)
		# el cuerpo sobresale `protrude` por delante de las dos caras y entra en el muro por detrás
		center = corner.P - nA * (lb * 0.5 - protrude * 0.5) - nB * (la * 0.5 - protrude * 0.5)
		center.z = (za + zb) * 0.5
		bevel = 0.032 + rng.uniform(-0.006, 0.014)
		bevel_box(g, "keep_stone", center, (nA, nB, Z), (lb + protrude, la + protrude, zb - za), bevel,
				style.tile, None, rng, 0.004, tint=block_tint(rng, style.sigma))


def quoin_block(g, rng, sx, sy, za, zb, h_a, h_b, la, lb, style, bevel=True):
	"""Piedra de esquina de un muro con talud: un paralelepípedo cuyas dos caras exteriores siguen
	los dos planos inclinados y se juntan en la arista (la limatesa), con bisel. Así las dos caras
	se abrazan sin cuñas entre ellas. h_a y h_b son los semilados del muro (sin piedras) abajo y
	arriba de la hilada; la piedra sobresale style.q de ese plano."""
	q = style.q
	gap = style.gap
	zlo, zhi = za + gap, zb - gap

	def h_at(z):
		return h_a + (h_b - h_a) * (z - za) / (zb - za)

	x_far = sx * (h_a + q - lb)
	y_far = sy * (h_a + q - la)
	bm = bmesh.new()
	verts = {}
	for k, (zz) in enumerate((zlo, zhi)):
		hh = h_at(zz) + q
		for i in (0, 1):
			for j in (0, 1):
				x = sx * hh if i == 0 else x_far
				y = sy * hh if j == 0 else y_far
				verts[(i, j, k)] = bm.verts.new((x, y, zz))
	quads = [((0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)), ((0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)),
			((0, 0, 0), (0, 1, 0), (0, 1, 1), (0, 0, 1)), ((1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1)),
			((0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)), ((0, 1, 0), (1, 1, 0), (1, 1, 1), (0, 1, 1))]
	for quad in quads:
		bm.faces.new([verts[v] for v in quad])
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
	c = min(style.chamfer * 1.15, 0.3 * min(la, lb), 0.3 * (zhi - zlo))
	if bevel:
		bmesh.ops.bevel(bm, geom=bm.edges[:], offset=c, offset_type='OFFSET', segments=1, profile=0.5, affect='EDGES')
	bm.normal_update()
	off = (rng.random(), rng.random())
	tint = block_tint(rng, style.sigma)
	aj = style.ao_joint
	for f in bm.faces:
		n = f.normal.copy()
		pts = [v.co.copy() for v in f.verts]
		fu, fv = uv_frame(n, None)
		uvs = [(p.dot(fu) / style.tile + off[0], p.dot(fv) / style.tile + off[1]) for p in pts]
		ao = []
		for p in pts:
			hh = h_at(min(max(p.z, za), zb)) + q
			depth = min(hh - sx * p.x, hh - sy * p.y)
			k = min(1.0, max(0.0, depth / max(c, 1e-4)))
			ao.append(1.04 - (1.04 - aj) * k)
		g.add("keep_stone", pts, uvs, n, tint, ao)
	bm.free()


# ---------------------------------------------------------------------------------------------
# Aberturas con marco
# ---------------------------------------------------------------------------------------------
def frame_opening(g, face, op, rng, reveal=0.6, kind='slit', detail=True, fill=True):
	"""Hueco con jambas, fondo oscuro, alféizar y dintel o dovelas. Las saeteras tienen ebrasamiento
	(se estrechan hacia dentro) y todas oscurecen hacia el fondo. Coordenadas de cara."""
	n, t = face.n, face.t
	P = face.P
	hw = op.half
	z0, z1 = op.z0, op.z1
	depth = 0.075      # plano de los sillares
	splay = 0.42 if kind == 'slit' else 1.0
	hwb = hw * splay
	uc = op.uc
	dark = 0.12
	# fondo oscuro
	if op.arch:
		pts = [P(uc - hw, z0, -reveal), P(uc + hw, z0, -reveal), P(uc + hw, z1, -reveal)]
		steps = 10
		for i in range(1, steps):
			a = math.pi * i / steps
			pts.append(P(uc + hw * math.cos(a), z1 + hw * math.sin(a), -reveal))
		pts.append(P(uc - hw, z1, -reveal))
		g.add("keep_dark", pts, [(0, 0)] * len(pts), n)
	else:
		g.add("keep_dark", [P(uc - hwb, z0, -reveal), P(uc + hwb, z0, -reveal), P(uc + hwb, op.top(), -reveal),
				P(uc - hwb, op.top(), -reveal)], [(0, 0)] * 4, n)
	# jambas y alféizar
	for sgn in (-1, 1):
		uf = uc + sgn * hw
		ub = uc + sgn * hwb
		q = [P(uf, z0, depth), P(ub, z0, -reveal), P(ub, z1, -reveal), P(uf, z1, depth)]
		g.add("keep_trim", q, [(0, 0), (reveal / STONE_TILE, 0), (reveal / STONE_TILE, (z1 - z0) / STONE_TILE),
				(0, (z1 - z0) / STONE_TILE)], -t * sgn, None, [1.0, dark, dark, 1.0])
	sill = [P(uc - hw, z0, depth), P(uc - hwb, z0, -reveal), P(uc + hwb, z0, -reveal), P(uc + hw, z0, depth)]
	g.add("keep_trim", sill, [(0, 0), (1, 0), (1, 1), (0, 1)], Z, None, [1.0, dark, dark, 1.0])
	if op.arch:
		steps = 10
		for i in range(steps):
			a0 = math.pi * i / steps
			a1 = math.pi * (i + 1) / steps
			p0 = (uc + hw * math.cos(a0), z1 + hw * math.sin(a0))
			p1 = (uc + hw * math.cos(a1), z1 + hw * math.sin(a1))
			q = [P(p0[0], p0[1], depth), P(p0[0], p0[1], -reveal), P(p1[0], p1[1], -reveal), P(p1[0], p1[1], depth)]
			mid = (a0 + a1) * 0.5
			inward = -t * math.cos(mid) - Z * math.sin(mid)
			g.add("keep_trim", q, [(0, 0), (1, 0), (1, 1), (0, 1)], inward, None, [1.0, dark, dark, 1.0])
		ring = 0.34 if kind == 'window' else 0.45
		voussoirs(g, face, uc, z1, hw, ring, rng, count=9 if kind == 'window' else 11)
		# la hilada que pasa justo sobre el anillo queda recortada por el arco: se rellena con
		# sillares para que no quede un hueco por encima de las dovelas
		for ci in range(len(face.courses) - 1) if fill else ():
			za, zb = face.courses[ci], face.courses[ci + 1]
			cut = op.cut_for(za, zb)
			if cut and zb > z1 + hw + ring + 0.02:
				lo_z = max(za, z1 + hw + ring - 0.03)
				face.ashlar_rows(g, [lo_z, zb], lambda i, a, b, cut=cut: [cut], rng, WALL)
	elif detail:
		# dintel: una piedra gruesa y larga
		center = P(uc, z1 + 0.11, 0.045)
		bevel_box(g, "keep_trim", center, (t, n, Z), (2 * hw + 0.34, 0.14, 0.22), 0.025, STONE_TILE, None, rng, 0.003,
				tint=block_tint(rng, 0.03))
	# alféizar saliente
	if detail:
		center = P(uc, z0 - 0.07, 0.07)
		bevel_box(g, "keep_trim", center, (t, n, Z), (2 * hw + 0.34, 0.22, 0.14), 0.025, STONE_TILE, None, rng, 0.003,
				tint=block_tint(rng, 0.03))
	# jambas de piedra labrada a cada lado
	jamb = 0.15
	for sgn in (-1, 1) if detail else ():
		if op.arch:
			height = z1 - z0
			zc = (z0 + z1) * 0.5
		else:
			height = op.top() - z0
			zc = (z0 + op.top()) * 0.5
		center = P(uc + sgn * (hw + jamb * 0.5), zc, 0.045)
		bevel_box(g, "keep_trim", center, (t, n, Z), (jamb, 0.14, height), 0.02, STONE_TILE, None, rng, 0.003,
				tint=block_tint(rng, 0.03))
	if kind == 'window' and detail:
		# barrotes de hierro verticales dentro del hueco
		for k in range(3):
			u = uc + hw * (-0.5 + k * 0.5)
			a = P(u, z0 + 0.05, -0.14)
			b = P(u, z1 + hw * math.sqrt(max(1 - ((u - uc) / hw) ** 2, 0)) * 0.95, -0.14)
			beam(g, "keep_iron", a, b, 0.035, 0.035, 0.004, STONE_TILE, n)
		a = P(uc - hw, z0 + (z1 - z0) * 0.55, -0.14)
		b = P(uc + hw, z0 + (z1 - z0) * 0.55, -0.14)
		beam(g, "keep_iron", a, b, 0.035, 0.035, 0.004, STONE_TILE, n)
	# churrete bajo el alféizar
	if kind != 'door':
		CTX.streak(P(uc, z0 - 0.1, depth), n, hw * 1.2 + 0.10, 2.8 if kind == 'window' else 2.0, 0.34)


def voussoirs(g, face, uc, zc, r_in, thick, rng, count=9):
	"""Anillo de dovelas de un arco de medio punto sobre una cara."""
	n, t = face.n, face.t
	P = face.P
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
			pts_front.append(P(u, z, protrude))
			pts_back.append(P(u, z, back))
		off = (rng.random(), rng.random())
		tint = block_tint(rng, 0.045)

		def uvf(p):
			return (p.dot(t) / STONE_TILE + off[0], p.dot(Z) / STONE_TILE + off[1])

		g.add("keep_trim", pts_front, [uvf(p) for p in pts_front], n, tint, [1.0, 1.0, 1.02, 1.02])
		# lados de la dovela (intradós, trasdós y juntas)
		for k in range(4):
			k2 = (k + 1) % 4
			q = [pts_front[k], pts_front[k2], pts_back[k2], pts_back[k]]
			center_f = (pts_front[0] + pts_front[2]) * 0.5
			hint = (q[0] + q[2]) * 0.5 - (center_f - n * (protrude * 0.5))
			g.add("keep_trim", q, [uvf(p) for p in q], hint, tint, [0.62, 0.62, 0.4, 0.4])


# ---------------------------------------------------------------------------------------------
# Paños lisos con la textura de sillería despiezada (LOD medio)
# ---------------------------------------------------------------------------------------------
def panel_face(g, face, z_lo, z_hi, ops, tile=STONE_TILE, mat="keep_wall", depth=0.07, quoins=True):
	"""Cara de muro como unas pocas franjas planas (una por tramo entre huecos) con la textura del
	paño de sillería. Los huecos se cortan sin margen: el marco los cubre. Se parte por las
	alturas de los huecos y, en los arcos, por tramos para seguir la curva."""
	flat = [Opening(op.uc, 2 * op.half, op.z0, op.z1, op.arch, 0.0) for op in ops]
	zs = {z_lo, z_hi}
	for op in flat:
		zs.add(min(max(op.z0, z_lo), z_hi))
		zs.add(min(max(op.top(), z_lo), z_hi))
		if op.arch:
			for k in range(1, 8):
				zs.add(min(max(op.z1 + op.half * math.sin(k * (math.pi / 2.0) / 8.0), z_lo), z_hi))
	zs = sorted(zs)
	length = math.sqrt(1.0 + face.slope * face.slope)
	n = face.t.cross((face.n * face.slope + Z) / length)
	if n.dot(face.n) < 0:
		n = -n
	for za, zb in zip(zs[:-1], zs[1:]):
		if zb - za < 1e-4:
			continue
		dz = za - face.z_ref
		lo = face.umin - face.u_slope * dz
		hi = face.umax + face.u_slope * dz
		if quoins:
			for corner, role in face.corners:
				ln = min(corner.lens(0)) * 0.9
				if corner.end_of(face, role) == 'max':
					hi -= ln
				else:
					lo += ln
		spans = [(lo, hi)]
		for op in flat:
			cut = op.cut_for(zb - 1e-3, zb) if op.arch else op.cut_for(za, zb)
			if cut:
				spans = subtract(spans, cut)
		for ua, ub in spans:
			if ub - ua < 0.02:
				continue
			pts = [face.P(ua, za, depth), face.P(ub, za, depth), face.P(ub, zb, depth), face.P(ua, zb, depth)]
			uvs = [(ua / tile, za * length / tile), (ub / tile, za * length / tile), (ub / tile, zb * length / tile),
					(ua / tile, zb * length / tile)]
			g.add(mat, pts, uvs, n, None, 1.0)


# ---------------------------------------------------------------------------------------------
# Secciones de torre con talud: cuatro caras de sillares y cuatro esquinas de piedras abrazadas
# ---------------------------------------------------------------------------------------------
FACE_NORMALS = (("E", X), ("N", Y), ("W", -X), ("S", -Y))
CORNER_SIGNS = ((1, 1), (-1, 1), (-1, -1), (1, -1))


def build_section(g, rng, courses, h0, h1, style, openings=None, cuts=None, weathered_fn=None, reveal=1.0, lod=0,
		tile=None):
	"""Tramo de torre entre courses[0] y courses[-1], con semilado h0 abajo y h1 arriba (talud lineal).
	openings: {cara: [(Opening, tipo)]}. cuts: {cara: [Opening]} huecos sin marco (el porche).
	Las piedras de esquina de cada hilada son una pieza que abraza las dos caras, con sillares largos
	y cortos alternos (soga y tizón). Con lod = 1 los muros son franjas planas con la textura de
	sillería despiezada y las piedras de esquina, de dos hiladas, no llevan bisel."""
	openings = openings or {}
	cuts = cuts or {}
	z0, z1 = courses[0], courses[-1]
	slope = (h1 - h0) / (z1 - z0)
	q = style.q
	corners = {}
	for k, (sx, sy) in enumerate(CORNER_SIGNS):
		corners[(sx, sy)] = Corner(Vector((sx * (h0 + q), sy * (h0 + q), 0.0)), Vector((sx, 0, 0)), Vector((0, sy, 0)),
				k % 2, None, style.quoin[0], style.quoin[1])
	for name, n_h in FACE_NORMALS:
		face = Face(n_h, h0, -(h0 + q), h0 + q, courses, slope=slope, z_ref=z0, u_slope=slope)
		for (sx, sy), corner in corners.items():
			if corner.nA.dot(n_h) > 0.5:
				face.corners.append((corner, 'A'))
			elif corner.nB.dot(n_h) > 0.5:
				face.corners.append((corner, 'B'))
		face.openings = [op for op, _kind in openings.get(name, [])] + list(cuts.get(name, []))
		if lod == 0:
			face.build(g, rng, style, weathered_fn)
		else:
			panel_face(g, face, z0, z1, face.openings, tile or style.tile)
		for op, kind in openings.get(name, []):
			frame_opening(g, face, op, rng, reveal, kind, detail=(lod == 0 or kind != 'slit'), fill=(lod == 0))
	step = 1 if lod == 0 else 2
	for (sx, sy), corner in corners.items():
		for i in range(0, len(courses) - 1, step):
			j = min(i + step, len(courses) - 1)
			za, zb = courses[i], courses[j]
			la, lb = corner.lens(i // step)
			h_a = h0 + slope * (za - z0)
			h_b = h0 + slope * (zb - z0)
			quoin_block(g, rng, sx, sy, za, zb, h_a, h_b, la, lb, style, bevel=(lod == 0))


# ---------------------------------------------------------------------------------------------
# Piezas del torreón
# ---------------------------------------------------------------------------------------------
TURRET_IN = 1.75           # cuánto entra la torrecilla en el muro
TURRET_OUT = 0.50          # cuánto sobresale del muro de la cornisa


def pyramid_roof(g, rng, cx, cy, half, eave_z, apex_z, rows, thick=0.045, mat="keep_roof", row_group=1):
	"""Tejado piramidal de tablillas en hileras solapadas. Cada hilera es una franja de la
	vertiente con su canto (el "borde" que recibe sombra); la hilera de arriba se apoya sobre
	la de abajo. Las UV casan con la textura de tablillas (una hilera de la textura por hilera)."""
	center = Vector((cx, cy, 0.0))
	rise = apex_z - eave_z
	for d in (X, Y, -X, -Y):
		tang = Z.cross(d)
		nrm = (d * rise + Z * half).normalized()
		off_u = rng.random()
		for j in range(rows):
			s0 = j / rows
			s1 = (j + 1) / rows
			h0 = half * (1.0 - s0)
			h1 = half * (1.0 - s1)
			z0 = eave_z + rise * s0
			z1 = eave_z + rise * s1
			base0 = center + d * h0
			base1 = center + d * h1
			lo0 = base0 - tang * h0 + Z * z0 + nrm * thick
			lo1 = base0 + tang * h0 + Z * z0 + nrm * thick
			up1 = base1 + tang * h1 + Z * z1
			up0 = base1 - tang * h1 + Z * z1
			tint = board_tint(rng, 0.06)
			v_lo = (j - 1.0) * row_group / 10.0
			v_up = float(j) * row_group / 10.0
			u_lo0, u_lo1 = (-h0) / ROOF_TILE + off_u, h0 / ROOF_TILE + off_u
			u_up0, u_up1 = (-h1) / ROOF_TILE + off_u, h1 / ROOF_TILE + off_u
			g.add(mat, [lo0, lo1, up1, up0], [(u_lo0, v_lo), (u_lo1, v_lo), (u_up1, v_up), (u_up0, v_up)], nrm, tint, 1.0)
			# canto (la tablilla gruesa): de la superficie de la hilera de abajo a la de esta
			e0 = base0 - tang * h0 + Z * z0 + nrm * (-0.02 if j == 0 else 0.0)
			e1 = base0 + tang * h0 + Z * z0 + nrm * (-0.02 if j == 0 else 0.0)
			butt = (d * half - Z * rise).normalized()
			g.add(mat, [e0, e1, lo1, lo0], [(u_lo0, 0.0), (u_lo1, 0.0), (u_lo1, 0.012), (u_lo0, 0.012)], butt,
					tint, [0.45, 0.45, 0.85, 0.85])


def snap_opening(op, courses):
	"""Ajusta un hueco para que su recorte (con margen) empiece y acabe en límites de hilada: una
	hilada que el hueco solo roza se quita entera, y si el recorte no coincide con ella queda una
	franja sin piedra bajo el alféizar y sobre el dintel por la que se ve el interior."""
	m = op.margin
	b0 = min(courses, key=lambda z: abs(z - (op.z0 - m)))
	b1 = min(courses, key=lambda z: abs(z - (op.top() + m)))
	z0 = b0 + m
	top = b1 - m
	if top - z0 < 0.5:
		return op
	z1 = top - (op.half if op.arch else 0.0)
	return Opening(op.uc, op.half * 2.0, z0, z1, op.arch, m)


class Builder:
	"""Monta el torreón. lod = 0: sillares modelados uno a uno. lod = 1: nivel medio, con los muros
	como franjas planas de textura de sillería despiezada y menos detalle fino (misma silueta)."""

	def __init__(self, lod: int = 0) -> None:
		self.lod = lod
		self.rng = random.Random(20261103)
		self.g = Geo()
		rng = self.rng
		self.c_foot = make_courses(FOOT_Z, 0.0, 0.70, rng)
		self.c_batter = make_courses(0.0, PLINTH_TOP, 0.75, rng)
		self.c_low = make_courses(LEDGE_TOP, CORDON_Z0, 0.46, rng)
		self.c_up = make_courses(CORDON_Z1, CORNICE_Z0, 0.46, rng)
		self.c_parapet = make_courses(PARAPET_BASE, PARAPET_TOP, 0.40, rng)
		self.c_turret = make_courses(CORNICE_Z0 + 0.05, TURRET_TOP, 0.46, rng)
		self.c_porch = make_courses(FOOT_Z, PORCH_TOP - 0.30, 0.55, rng)

	# --- zócalo ---------------------------------------------------------------------------
	def plinth(self) -> None:
		g, rng = self.g, self.rng
		# el hueco del porche en el zócalo: los sillares (LOD0) y los paños (LOD1) se meten unos
		# centímetros bajo las caras laterales del porche, para que no quede una rendija entre ambos
		cut_half = PORCH_HALF - 0.05 if self.lod == 0 else PORCH_HALF - 0.12
		porch_cut = {"W": [Opening(0.0, 2 * cut_half, -5.0, PORCH_TOP, False, 0.0)]}

		def wear(i, va) -> float:
			return 0.06 if i < 2 else 0.0

		tile = PLINTH.tile * 1.6   # una hilada del zócalo mide 0,75 m: más grande que la del paño (0,46 m)
		build_section(g, rng, self.c_foot, PLINTH_HALF_BOTTOM, PLINTH_HALF_BOTTOM, PLINTH, cuts=porch_cut, weathered_fn=wear,
				lod=self.lod, tile=tile)
		build_section(g, rng, self.c_batter, PLINTH_HALF_BOTTOM, PLINTH_HALF_TOP, PLINTH, cuts=porch_cut, weathered_fn=wear,
				lod=self.lod, tile=tile)
		# repisa con glacis: sale del zócalo y vuelve al muro (sentido antihorario)
		h = wall_half(LEDGE_TOP)
		out = PLINTH_HALF_TOP + PLINTH.q + 0.10 - h
		loft(g, "keep_trim", (-h, h, -h, h), [(out, PLINTH_TOP - 0.08), (out, PLINTH_TOP + 0.10), (-0.02, PLINTH_TOP + 0.34)],
				STONE_TILE, ao=[0.7, 1.0, 1.0])
		CTX.ledge(PLINTH_TOP, 0.7, 0.30)

	# --- muros ------------------------------------------------------------------------------
	def bays(self) -> None:
		g, rng = self.g, self.rng
		openings = self.make_openings()
		for stage, courses in (("low", self.c_low), ("up", self.c_up)):
			z0, z1 = courses[0], courses[-1]
			ops = {name: [(snap_opening(op, courses), kind) for st, op, kind in items if st == stage]
					for name, items in openings.items()}
			build_section(g, rng, courses, wall_half(z0), wall_half(z1), WALL, openings=ops, reveal=0.95, lod=self.lod)

	def make_openings(self):
		"""Huecos por cara: {cara: [(etapa, Opening, tipo)]}. Etapa 'low' (bajo el cordón) o 'up'. Pocos
		y hondos: una ventana con arco por cara y saeteras estrechas con ebrasamiento."""
		def slit(u, z0, z1):
			return Opening(u, 0.28, z0, z1, False, 0.16)

		def win(u, z0, z1):
			return Opening(u, 0.90, z0, z1, True, 0.17)

		out = {"E": [], "N": [], "W": [], "S": []}
		out["W"] += [("low", slit(-1.25, 6.9, 8.2), 'slit'), ("low", slit(1.25, 6.9, 8.2), 'slit'),
				("up", win(0.0, 9.6, 10.9), 'window'),
				("up", slit(-1.0, 11.9, 13.2), 'slit'), ("up", slit(1.0, 11.9, 13.2), 'slit')]
		out["S"] += [("low", slit(0.0, 6.0, 7.5), 'slit'),
				("up", win(0.0, 9.6, 10.9), 'window'),
				("up", slit(-1.0, 11.9, 13.2), 'slit'), ("up", slit(1.0, 11.9, 13.2), 'slit')]
		out["N"] += [("low", slit(0.3, 6.0, 7.5), 'slit'),
				("up", win(0.3, 9.6, 10.9), 'window'),
				("up", slit(-0.9, 11.9, 13.2), 'slit'), ("up", slit(1.5, 11.9, 13.2), 'slit')]
		out["E"] += [("low", slit(-0.4, 6.0, 7.5), 'slit'),
				("up", slit(-1.1, 9.7, 11.2), 'slit'), ("up", slit(0.2, 9.7, 11.2), 'slit'),
				("up", slit(-0.5, 11.9, 13.2), 'slit')]
		return out

	# --- cordón y cornisa --------------------------------------------------------------------
	def string_courses(self) -> None:
		g, rng = self.g, self.rng
		# cordón: anillo que marca el retranqueo del muro y vierte el agua lejos de él
		h = wall_half(CORDON_Z0)
		hu = wall_half(CORDON_Z1)
		loft(g, "keep_trim", (-h, h, -h, h), [(-0.03, CORDON_Z0), (0.17, CORDON_Z0), (0.17, CORDON_Z0 + 0.20),
				(hu - h - 0.01, CORDON_Z1)], STONE_TILE, ao=[0.75, 1.0, 1.0, 0.9])
		CTX.ledge(CORDON_Z0, 0.8, 0.34)
		# cornisa: bajo el cadalso
		h = wall_half(CORNICE_Z0)
		loft(g, "keep_trim", (-h, h, -h, h), [(-0.03, CORNICE_Z0), (0.30, CORNICE_Z0), (0.30, CORNICE_Z0 + 0.14),
				(0.48, CORNICE_Z0 + 0.14), (0.48, CORNICE_Z0 + 0.34), (-0.03, CORNICE_Z0 + 0.55)], STONE_TILE,
				ao=[0.75, 1.0, 0.95, 1.0, 1.0, 0.9])
		CTX.ledge(CORNICE_Z0, 1.0, 0.36)
		# canecillos escalonados bajo la cornisa
		for n_h in (X, Y, -X, -Y):
			t = Z.cross(n_h).normalized()
			count = 7
			for k in range(count):
				u = -h + 0.32 + (2 * h - 0.64) * k / (count - 1)
				base = n_h * h + t * u
				bv = 0.03 if self.lod == 0 else 0.0
				c = base + n_h * 0.08 + Z * (CORNICE_Z0 - 0.25)
				bevel_box(g, "keep_trim", c, (t, n_h, Z), (0.40, 0.40, 0.50), bv, STONE_TILE, None, rng, 0.003,
						tint=block_tint(rng, 0.04), skip_back=-n_h)
				c2 = base + n_h * 0.02 + Z * (CORNICE_Z0 - 0.66)
				if self.lod == 0:
					bevel_box(g, "keep_trim", c2, (t, n_h, Z), (0.30, 0.30, 0.38), 0.025, STONE_TILE, None, rng, 0.003,
							tint=block_tint(rng, 0.04), skip_back=-n_h)
				CTX.streak(base + Z * (CORNICE_Z0 - 0.90) + n_h * 0.05, n_h, 0.26, 1.5, 0.22)

	# --- parapeto y almenas ----------------------------------------------------------------------
	def parapet(self) -> None:
		g, rng = self.g, self.rng
		h = H_TOP
		if self.lod == 1:
			self.parapet_simple()
			return
		# muro del parapeto con sillares (por encima de la cornisa, hasta la albardilla)
		for side_index, n_h in enumerate((X, Y, -X, -Y)):
			face = Face(n_h, h, -h - 0.09, h + 0.09, self.c_parapet)

			def spans(i, za, zb, side_index=side_index):
				lo = -h - (0.09 if (i + side_index) % 2 == 0 else 0.03)
				hi = h + (0.09 if (i + side_index + 1) % 2 == 0 else 0.03)
				return [(lo, hi)]

			face.ashlar_rows(g, self.c_parapet, spans, rng, SMALL)
		# albardilla y cara interior
		loft(g, "keep_trim", (-h, h, -h, h), [(0.0, PARAPET_TOP), (0.11, PARAPET_TOP), (0.11, COPING_TOP - 0.04),
				(0.02, COPING_TOP), (-0.8, COPING_TOP), (-0.8, PARAPET_TOP - 0.02)], STONE_TILE)
		# suelo del adarve (losas)
		inner = h - 0.8
		axis_box(g, "keep_trim", (-inner, -inner, WALK_Z - 0.25), (inner, inner, WALK_Z), 0.0, STONE_TILE, None, rng)
		# cara interior del parapeto, con sillares (se ve desde arriba y desde las almenas)
		inner_courses = make_courses(WALK_Z, PARAPET_TOP, 0.40, rng)
		for side_index, n_h in enumerate((X, Y, -X, -Y)):
			face = Face(-n_h, -inner, -inner - 0.09, inner + 0.09, inner_courses)

			def inner_spans(i, za, zb, side_index=side_index):
				lo = -inner - (0.09 if (i + side_index) % 2 == 0 else 0.03)
				hi = inner + (0.09 if (i + side_index + 1) % 2 == 0 else 0.03)
				return [(lo, hi)]

			face.ashlar_rows(g, inner_courses, inner_spans, rng, SMALL)
		# almenas: cuatro de esquina y dos por lado
		m_w = 0.9
		gap = (2 * h - 4 * m_w) / 3.0
		thick = 0.8
		spans_m = []
		pos = -h
		for _k in range(4):
			spans_m.append((pos, pos + m_w))
			pos += m_w + gap
		for n_h in (X, Y, -X, -Y):
			t = Z.cross(n_h).normalized()
			for k, (a_, b_) in enumerate(spans_m):
				if k in (0, 3):
					continue
				c = n_h * (h - thick * 0.5) + t * ((a_ + b_) * 0.5)
				self.merlon(c.x, c.y, abs(t.x) * (b_ - a_) * 0.5 + abs(n_h.x) * thick * 0.5,
						abs(t.y) * (b_ - a_) * 0.5 + abs(n_h.y) * thick * 0.5)
		for sx, sy in CORNER_SIGNS:
			self.merlon(sx * (h - m_w * 0.5), sy * (h - m_w * 0.5), m_w * 0.5, m_w * 0.5)

	def parapet_simple(self) -> None:
		"""Parapeto del nivel medio: paños planos, albardilla, adarve y almenas como cajas."""
		g, rng = self.g, self.rng
		h = H_TOP
		inner = h - 0.8
		for n_h in (X, Y, -X, -Y):
			t = Z.cross(n_h).normalized()
			for plane, hint in ((h, n_h), (inner, -n_h)):
				z0, z1 = (PARAPET_BASE, PARAPET_TOP) if hint == n_h else (WALK_Z, PARAPET_TOP)
				ext = plane + 0.09
				pts = [n_h * plane + t * -ext + Z * z0, n_h * plane + t * ext + Z * z0, n_h * plane + t * ext + Z * z1,
						n_h * plane + t * -ext + Z * z1]
				g.add("keep_wall", pts, [(p.dot(t) / STONE_TILE, p.z / STONE_TILE) for p in pts], hint)
		loft(g, "keep_trim", (-h, h, -h, h), [(0.0, PARAPET_TOP), (0.11, PARAPET_TOP), (0.11, COPING_TOP - 0.04),
				(0.02, COPING_TOP), (-0.8, COPING_TOP), (-0.8, PARAPET_TOP - 0.02)], STONE_TILE)
		axis_box(g, "keep_trim", (-inner, -inner, WALK_Z - 0.25), (inner, inner, WALK_Z), 0.0, STONE_TILE, None, rng)
		m_w = 0.9
		gap = (2 * h - 4 * m_w) / 3.0
		pos = -h
		spans_m = []
		for _k in range(4):
			spans_m.append((pos, pos + m_w))
			pos += m_w + gap
		for n_h in (X, Y, -X, -Y):
			t = Z.cross(n_h).normalized()
			for k, (a_, b_) in enumerate(spans_m):
				if k in (0, 3):
					continue
				c = n_h * (h - 0.4) + t * ((a_ + b_) * 0.5)
				bevel_box(g, "keep_wall", c + Z * ((COPING_TOP + MERLON_TOP) * 0.5), (t, n_h, Z), (m_w, 0.8, MERLON_TOP - COPING_TOP),
						0.0, STONE_TILE)
		for sx, sy in CORNER_SIGNS:
			bevel_box(g, "keep_wall", Vector((sx * (h - m_w * 0.5), sy * (h - m_w * 0.5), (COPING_TOP + MERLON_TOP) * 0.5)),
					(X, Y, Z), (m_w, m_w, MERLON_TOP - COPING_TOP), 0.0, STONE_TILE)

	def merlon(self, cx, cy, hx, hy) -> None:
		"""Almena: cuatro caras de sillares sobre un núcleo y una albardilla biselada encima."""
		g, rng = self.g, self.rng
		z0, z1 = COPING_TOP, MERLON_TOP - 0.13
		courses = make_courses(z0, z1, 0.40, rng)
		for index, n_h in enumerate((X, Y, -X, -Y)):
			t = Z.cross(n_h).normalized()
			plane = n_h.x * cx + n_h.y * cy + (hx if abs(n_h.x) > 0.5 else hy)
			if abs(n_h.x) > 0.5:
				extent = (t.y * cy - hy, t.y * cy + hy)
			else:
				extent = (t.x * cx - hx, t.x * cx + hx)
			lo_u, hi_u = min(extent), max(extent)
			face = Face(n_h, plane, lo_u, hi_u, courses)

			def spans(i, za, zb, face=face, index=index):
				lo = face.umin - (0.09 if (i + index) % 2 == 0 else 0.03)
				hi = face.umax + (0.09 if (i + index + 1) % 2 == 0 else 0.03)
				return [(lo, hi)]

			face.ashlar_rows(g, courses, spans, rng, SMALL)
		center = Vector((cx, cy, MERLON_TOP - 0.065))
		bevel_box(g, "keep_trim", center, (X, Y, Z), (2 * hx + 0.20, 2 * hy + 0.20, 0.13), 0.03, STONE_TILE, None, rng, 0.003)

	# --- porche de la puerta --------------------------------------------------------------------
	def porch(self) -> None:
		g, rng = self.g, self.rng
		n_h = -X
		door = Opening(0.0, 1.9, 0.0, 2.45, True, 0.20)
		front = Face(n_h, PORCH_FRONT, -PORCH_HALF, PORCH_HALF, self.c_porch, [door])
		c1 = Corner(Vector((-PORCH_FRONT, PORCH_HALF, 0)), n_h, Y, 0)
		c2 = Corner(Vector((-PORCH_FRONT, -PORCH_HALF, 0)), n_h, -Y, 1)
		front.corners = [(c1, 'A'), (c2, 'A')]
		lod0 = self.lod == 0
		if lod0:
			front.build(g, rng, WALL, lambda i, va: 0.08 if va < 0.5 else 0.0)
			build_quoins(g, c1, self.c_porch, rng)
			build_quoins(g, c2, self.c_porch, rng)
		else:
			panel_face(g, front, FOOT_Z, PORCH_TOP - 0.30, [door], STONE_TILE, quoins=False)
		# lados del porche (se pierden dentro del zócalo y del muro)
		wall_in = H_WALL0 - 0.14
		for sgn in (1, -1):
			side = Face(Y * sgn, PORCH_HALF, 0.0, 0.0, self.c_porch)
			ux = sorted([Z.cross(Y * sgn).dot(Vector((x_, 0, 0))) for x_ in (-PORCH_FRONT + 0.30, -wall_in)])
			side.umin, side.umax = ux[0], ux[1]
			if lod0:
				side.build(g, rng, WALL)
			else:
				panel_face(g, side, FOOT_Z, PORCH_TOP - 0.30, [], STONE_TILE, quoins=False)
		# puerta con marco, dovelas, hojas y herrajes
		frame_opening(g, front, door, rng, 0.55, 'door', detail=True, fill=lod0)
		self.door_leaves(front, door)
		# umbral y peldaño
		axis_box(g, "keep_trim", (-PORCH_FRONT - 0.30, -1.15, FOOT_Z + 1.0), (-PORCH_FRONT + 0.9, 1.15, 0.12), 0.03,
				STONE_TILE, None, rng, 0.003, tint=block_tint(rng, 0.03))
		self.porch_roof()

	def door_leaves(self, front, door) -> None:
		"""Dos hojas de tablones verticales con arco, flejes de hierro con punta, remaches y tirador."""
		g, rng = self.g, self.rng
		n, t = front.n, front.t
		d = -0.40            # plano de las hojas, dentro del hueco
		hw = door.half - 0.02
		z0, z1 = 0.08, door.z1
		steps = 12

		def P(u, z, dd=d):
			return front.P(u, z, dd)

		for sgn in (-1, 1):
			u0 = 0.015 * sgn
			u1 = sgn * hw
			arc = []
			for i in range(1, steps):
				a = math.pi * 0.5 * i / steps
				arc.append(P(sgn * hw * math.cos(a), z1 + hw * math.sin(a)))
			poly = [P(u0, z0), P(u1, z0), P(u1, z1)] + arc + [P(u0, z1 + hw)]
			uvs = [(p.dot(Z) / WOOD_TILE, (p.dot(t) * sgn) / WOOD_TILE) for p in poly]
			g.add("keep_wood", poly, uvs, n, board_tint(rng, 0.05), 0.95)
			# juntas de los tablones: ranuras oscuras verticales
			for k in range(1, 4) if self.lod == 0 else ():
				u = sgn * hw * k / 4.0
				top = z1 + math.sqrt(max(hw * hw - u * u, 0.0)) - 0.03
				beam(g, "keep_dark", P(u, z0 + 0.02, d + 0.012), P(u, top, d + 0.012), 0.012, 0.012, 0.0, WOOD_TILE, n)
			# tres flejes de hierro desde el gozne, con remate en punta, y sus remaches
			for zf in (0.62, 1.55, 2.38):
				end = sgn * 0.20 * hw
				beam(g, "keep_iron", P(u1, zf, d + 0.03), P(end, zf, d + 0.03), 0.12, 0.028, 0.004, WOOD_TILE, n)
				tip = [P(end, zf + 0.06, d + 0.03), P(end, zf - 0.06, d + 0.03), P(end - sgn * 0.17, zf, d + 0.03)]
				g.add("keep_iron", tip, [(0, 0), (1, 0), (0.5, 1)], n)
				if self.lod == 0:
					for k in range(0, 6):
						u = end + (u1 - end) * (0.10 + 0.84 * k / 5.0)
						cone_stud(g, "keep_iron", P(u, zf, d + 0.032), n, t, 0.026, 0.020)
					# pernio del gozne: cilindro corto en el canto de la hoja
					hinge = P(u1 - sgn * 0.02, zf, d + 0.03)
					cylinder(g, "keep_iron", (hinge.x, hinge.y), 0.035, zf - 0.10, zf + 0.10, 6, STONE_TILE, 1.0, True)
			# tirador: anillo de hierro sobre una chapa
			if self.lod == 0:
				torus(g, "keep_iron", P(sgn * 0.22, 1.25, d + 0.075), t, Z, 0.07, 0.014)
				cone_stud(g, "keep_iron", P(sgn * 0.22, 1.325, d + 0.03), n, t, 0.04, 0.035, 6)
		# barra y placa de cerradura sobre las dos hojas
		axis_box(g, "keep_iron", P(-0.30, 1.04, d + 0.03), P(0.30, 1.12, d + 0.065), 0.004, STONE_TILE, None, rng)

	def porch_roof(self) -> None:
		g, rng = self.g, self.rng
		# cornisa de piedra sobre el porche
		center = Vector((-PORCH_FRONT + 0.50, 0.0, PORCH_TOP - 0.15))
		bevel_box(g, "keep_trim", center, (X, Y, Z), (1.30 + 0.4, 2 * PORCH_HALF + 0.5, 0.30), 0.03, STONE_TILE, None, rng, 0.004)
		# tejadillo: una vertiente de tablillas apoyada en el muro, con aleros
		zw = PORCH_TOP + 1.35
		xe = -PORCH_FRONT - 0.30     # alero
		xw = -(wall_half(zw) - 0.08)  # muro
		ze = PORCH_TOP + 0.12
		yh = PORCH_HALF + 0.30
		slope = Vector((xw - xe, 0, zw - ze))
		length = slope.length
		sdir = slope / length
		nrm = Vector((-sdir.z, 0, sdir.x))
		if nrm.z < 0:
			nrm = -nrm
		thick = 0.10
		rows = max(2, int(round(length / 0.2)))
		for r in range(rows):
			f0, f1 = r / rows, (r + 1) / rows
			p00 = Vector((xe + (xw - xe) * f0, -yh, ze + (zw - ze) * f0)) + nrm * (0.04 if r > 0 else 0.02)
			p10 = Vector((xe + (xw - xe) * f0, yh, ze + (zw - ze) * f0)) + nrm * (0.04 if r > 0 else 0.02)
			p11 = Vector((xe + (xw - xe) * f1, yh, ze + (zw - ze) * f1))
			p01 = Vector((xe + (xw - xe) * f1, -yh, ze + (zw - ze) * f1))
			tint = board_tint(rng, 0.06)
			g.add("keep_roof", [p00, p10, p11, p01], [(-yh / ROOF_TILE, (r - 1) / 10.0), (yh / ROOF_TILE, (r - 1) / 10.0),
					(yh / ROOF_TILE, r / 10.0), (-yh / ROOF_TILE, r / 10.0)], nrm, tint, 1.0)
			lower = [Vector((xe + (xw - xe) * f0, -yh, ze + (zw - ze) * f0)) + nrm * (-0.02 if r == 0 else 0.0),
					Vector((xe + (xw - xe) * f0, yh, ze + (zw - ze) * f0)) + nrm * (-0.02 if r == 0 else 0.0)]
			g.add("keep_roof", [lower[0], lower[1], p10, p00], [(0, 0), (1, 0), (1, 0.01), (0, 0.01)], -sdir, tint,
					[0.45, 0.45, 0.85, 0.85])
		pts_top = [Vector((xe, -yh, ze)), Vector((xe, yh, ze)), Vector((xw, yh, zw)), Vector((xw, -yh, zw))]
		bottom = [p - nrm * thick for p in pts_top]
		g.add("keep_wood", bottom, [(p.y / WOOD_TILE, p.x / WOOD_TILE) for p in bottom], -nrm, None, 0.55)
		g.add("keep_wood", [bottom[0], bottom[1], pts_top[1], pts_top[0]], [(0, 0), (1, 0), (1, 0.1), (0, 0.1)], -sdir)
		for a, b, sgn in ((0, 3, -1), (1, 2, 1)):
			g.add("keep_wood", [bottom[a], bottom[b], pts_top[b], pts_top[a]], [(0, 0), (1, 0), (1, 0.1), (0, 0.1)], Y * sgn)
		# hastiales de piedra bajo la vertiente
		for sgn in (-1, 1):
			y = sgn * (PORCH_HALF + 0.12)
			tri = [Vector((-PORCH_FRONT + 0.15, y, PORCH_TOP + 0.10)), Vector((xw + 0.07, y, PORCH_TOP + 0.10)),
					Vector((xw + 0.07, y, zw - 0.12))]
			g.add("keep_trim", tri, [(p.x / STONE_TILE, p.z / STONE_TILE) for p in tri], Y * sgn)
			tri2 = [Vector((tri[0].x, y - sgn * 0.14, tri[0].z)), Vector((tri[1].x, y - sgn * 0.14, tri[1].z)),
					Vector((tri[2].x, y - sgn * 0.14, tri[2].z))]
			g.add("keep_trim", tri2, [(p.x / STONE_TILE, p.z / STONE_TILE) for p in tri2], -Y * sgn)

	# --- cadalso de madera ----------------------------------------------------------------------
	def hoarding(self) -> None:
		g, rng = self.g, self.rng
		H = HOARD_H
		bv = 0.012 if self.lod == 0 else 0.0
		turret_cut = H_TOP - TURRET_IN - 0.13
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
		for n_h, t, lo, hi in sides:
			# soportes: ménsulas cada ~1,5 m
			count = int((hi - lo) / 1.5) + 1
			us = [lo + 0.60 + (hi - lo - 1.20) * k / max(count - 1, 1) for k in range(count)]
			for u in us:
				base = t * u
				tint = board_tint(rng, 0.06)
				# vigueta voladiza
				a = base + n_h * (H_TOP - 0.15) + Z * (WALK_Z - 0.28)
				b = base + n_h * (H + 0.12) + Z * (WALK_Z - 0.28)
				beam(g, "keep_wood", a, b, 0.22, 0.24, bv, WOOD_TILE, Z, rng, 0.004, tint)
				# riostra diagonal (ménsula)
				c = base + n_h * (H_TOP + 0.50) + Z * (WALK_Z - 0.98)
				d = base + n_h * (H - 0.20) + Z * (WALK_Z - 0.36)
				beam(g, "keep_wood", c, d, 0.19, 0.19, bv, WOOD_TILE, Z, rng, 0.004, tint)
				# pie de la riostra contra la cornisa
				axis_pad = base + n_h * (H_TOP + 0.48) + Z * (WALK_Z - 1.02)
				bevel_box(g, "keep_wood", axis_pad, (t, n_h, Z), (0.30, 0.10, 0.22), 0.01, WOOD_TILE, Z, rng, 0.003, tint=tint)
				# poste vertical exterior, hasta la carrera del tejado
				pa = base + n_h * (H - 0.04) + Z * WALK_Z
				pb = base + n_h * (H - 0.04) + Z * PLATE_Z
				beam(g, "keep_wood", pa, pb, 0.22, 0.22, bv, WOOD_TILE, n_h, rng, 0.004, tint)
				CTX.streak(base + n_h * (H_TOP + 0.4) + Z * (WALK_Z - 1.1), n_h, 0.22, 1.8, 0.2)
			# solera de tablas (la veta va hacia afuera)
			deck_center = n_h * ((H_TOP + H + 0.12) * 0.5 - 0.02) + t * ((lo + hi) * 0.5) + Z * (WALK_Z - 0.04)
			bevel_box(g, "keep_wood", deck_center, (n_h, t, Z), (H + 0.12 - H_TOP + 0.04, hi - lo, 0.09), 0.006, WOOD_TILE, n_h)
			# viga de borde y carrera
			rail_center = n_h * (H - 0.04) + t * ((lo + hi) * 0.5) + Z * (PLATE_Z - 0.10)
			bevel_box(g, "keep_wood", rail_center, (n_h, t, Z), (0.22, hi - lo, 0.20), 0.012, WOOD_TILE, t)
			base_center = n_h * (H - 0.04) + t * ((lo + hi) * 0.5) + Z * (WALK_Z + 0.10)
			bevel_box(g, "keep_wood", base_center, (n_h, t, Z), (0.20, hi - lo, 0.17), 0.012, WOOD_TILE, t)
			# tablas verticales por fuera: fila baja continua y friso alto, con la franja de en medio
			# abierta (aspilleras corridas) para ver las almenas y el tejado por dentro
			board_w = 0.235 if self.lod == 0 else (hi - lo)
			u = lo + 0.10
			low_top = WALK_Z + 1.05
			while u < hi - 0.12:
				bw = board_w + (rng.uniform(-0.02, 0.02) if self.lod == 0 else -0.20)
				if u + bw > hi - 0.08:
					bw = hi - 0.08 - u
				if bw < 0.06:
					break
				ub = u + bw * 0.5
				tint = board_tint(rng, 0.08)
				h_lo = WALK_Z + 0.16
				h_hi = low_top + rng.uniform(-0.05, 0.05)
				plank(g, "keep_wood", n_h * (H + 0.04) + t * ub + Z * ((h_lo + h_hi) * 0.5), (n_h, t, Z),
						(0.07, bw - 0.018, h_hi - h_lo), WOOD_TILE, Z, rng, tint, hide=-n_h)
				z_lo = PLATE_Z - 0.62
				z_hi = PLATE_Z - 0.18 + rng.uniform(-0.03, 0.03)
				plank(g, "keep_wood", n_h * (H + 0.04) + t * ub + Z * ((z_lo + z_hi) * 0.5), (n_h, t, Z),
						(0.07, bw - 0.018, z_hi - z_lo), WOOD_TILE, Z, rng, tint, hide=-n_h)
				u += bw
		# tapas de los extremos que topan con la torrecilla
		for n_h, t, lo, hi in sides:
			if (n_h == X and hi == turret_cut) or (n_h == Y and lo == -turret_cut):
				end_u = hi if n_h == X else lo
				pos = t * end_u
				c = n_h * ((H_TOP + H) * 0.5) + pos + Z * (WALK_Z + 1.35)
				bevel_box(g, "keep_wood", c, (n_h, t, Z), (H - H_TOP + 0.06, 0.10, 2.7), 0.008, WOOD_TILE, Z, rng, 0.003)

	# --- tejado a cuatro aguas ------------------------------------------------------------------
	def roof(self) -> None:
		g, rng = self.g, self.rng
		R = ROOF_R
		rise = ROOF_APEX_Z - ROOF_EAVE_Z
		group = 1 if self.lod == 0 else 3
		rows = int(round(math.hypot(R, rise) / 0.2 / group))
		pyramid_roof(g, rng, 0.0, 0.0, R, ROOF_EAVE_Z, ROOF_APEX_Z, rows, 0.045, row_group=group)
		# faldón interior (la cara de abajo, de madera) y cabios que se ven bajo el alero
		apex = Vector((0.0, 0.0, ROOF_APEX_Z))
		for d in (X, Y, -X, -Y):
			tang = Z.cross(d)
			a = d * R - tang * R + Z * ROOF_EAVE_Z
			b = d * R + tang * R + Z * ROOF_EAVE_Z
			nrm = (d * rise + Z * R).normalized()
			drop = -nrm * 0.12
			g.add("keep_wood", [a + drop, b + drop, apex + drop], [(0, 0), (2 * R / WOOD_TILE, 0), (R / WOOD_TILE, R / WOOD_TILE)],
					-nrm, None, 0.5)
			count = 7 if self.lod == 0 else 3
			for k in range(count):
				f = -1.0 + 2.0 * (k + 0.5) / count
				start = d * R + tang * (R * f) + Z * ROOF_EAVE_Z
				end_point = apex + tang * (R * f * 0.02)
				# el cabio llega a la cumbrera; se ve la parte que sale por debajo del alero
				beam(g, "keep_wood", start + drop - d * 0.20 + Z * -0.02, end_point + drop, 0.10, 0.12, 0.008, WOOD_TILE, Z, rng, 0.003,
						board_tint(rng, 0.06))
			# tabla de alero a lo largo del borde del tejado
			c = d * (R + 0.02) + Z * (ROOF_EAVE_Z - 0.08)
			bevel_box(g, "keep_wood", c, (d, tang, Z), (0.10, 2 * R + 0.10, 0.24), 0.01, WOOD_TILE, tang, rng, 0.0,
					tint=board_tint(rng, 0.05))
		# limatesas: tabla de cumbrera sobre cada arista
		for sx, sy in CORNER_SIGNS:
			start = Vector((sx * R, sy * R, ROOF_EAVE_Z + 0.02))
			beam(g, "keep_wood", start, apex + Z * 0.04, 0.16, 0.16, 0.012, WOOD_TILE, Z, rng, 0.003, board_tint(rng, 0.05))
		# techo del adarve cubierto: tablones bajo el faldón se ven desde abajo por el friso abierto
		# remate de cumbrera
		cylinder(g, "keep_wood", (0.0, 0.0), 0.16, ROOF_APEX_Z - 0.10, ROOF_APEX_Z + 0.30, 8, WOOD_TILE, 0.7, False)

	# --- torrecilla ----------------------------------------------------------------------------
	def turret_top(self) -> None:
		g, rng = self.g, self.rng
		x0, x1 = H_TOP - TURRET_IN, H_TOP + TURRET_OUT
		rect = (x0, x1, x0, x1)
		# la parte alta de la torrecilla, desde la cornisa hasta su remate
		ex, ey = X, Y
		xo, yo = x1, x1
		corner_out = Corner(Vector((xo, yo, 0)), ex, ey, 0, None, 0.95, 0.55)
		corner_bc = Corner(Vector((x0, yo, 0)), ey, -ex, 1, (0.55, TURRET_OUT))
		corner_ad = Corner(Vector((xo, x0, 0)), ex, -ey, 1, (0.55, TURRET_OUT))
		fa = Face(ex, x1, x0, x1, self.c_turret)
		fa.corners = [(corner_out, 'A'), (corner_ad, 'A')]
		fa.openings = [Opening((x0 + x1) * 0.5, 0.28, 17.4, 18.9, False, 0.16)]
		fb = Face(ey, x1, -x1, -x0, self.c_turret)
		fb.corners = [(corner_out, 'B'), (corner_bc, 'A')]
		fb.openings = [Opening(-(x0 + x1) * 0.5, 0.28, 17.4, 18.9, False, 0.16)]
		for f in (fa, fb):
			if self.lod == 0:
				f.build(g, rng, WALL)
			else:
				panel_face(g, f, self.c_turret[0], TURRET_TOP, f.openings, STONE_TILE, quoins=False)
			for op in f.openings:
				frame_opening(g, f, op, rng, 0.9, 'slit', detail=(self.lod == 0), fill=False)
		for c in (corner_out, corner_bc, corner_ad):
			if self.lod == 0:
				build_quoins(g, c, self.c_turret, rng)
		# corona con vuelo y tejado piramidal de tablillas
		loft(g, "keep_trim", rect, [(-0.3, TURRET_TOP - 0.02), (0.20, TURRET_TOP - 0.02), (0.20, TURRET_TOP + 0.20),
				(-0.3, TURRET_TOP + 0.20)], STONE_TILE)
		cx = (x0 + x1) * 0.5
		half = (x1 - x0) * 0.5 + 0.34
		eave_z = TURRET_TOP + 0.20
		rows = int(round(math.hypot(half, TURRET_ROOF_APEX - eave_z) / 0.2))
		pyramid_roof(g, rng, cx, cx, half, eave_z, TURRET_ROOF_APEX, rows, 0.04)
		apex = Vector((cx, cx, TURRET_ROOF_APEX))
		for sx, sy in CORNER_SIGNS:
			start = Vector((cx + sx * half, cx + sy * half, eave_z + 0.02))
			beam(g, "keep_wood", start, apex + Z * 0.03, 0.10, 0.10, 0.008, WOOD_TILE, Z, rng, 0.002, board_tint(rng, 0.05))
		cylinder(g, "keep_iron", (cx, cx), 0.05, TURRET_ROOF_APEX - 0.02, TURRET_ROOF_APEX + 0.40, 4, STONE_TILE, 0.0, False)
		self.ball((cx, cx, TURRET_ROOF_APEX + 0.40), 0.07)

	# --- asta y remate --------------------------------------------------------------------------
	def flagpole(self) -> None:
		"""Asta de madera sobre la cumbrera del tejado, con remate de hierro. El gallardete va aparte
		(build_banners): es el nodo Estandarte."""
		g, rng = self.g, self.rng
		cylinder(g, "keep_wood", (0.0, 0.0), 0.11, ROOF_APEX_Z + 0.2, TOTAL_TOP - 0.10, 8, WOOD_TILE, 0.65, False)
		self.ball((0.0, 0.0, TOTAL_TOP - 0.06), 0.08)

	def ball(self, center, radius) -> None:
		g = self.g
		c = Vector(center)
		pts = [c + X * radius, c - X * radius, c + Y * radius, c - Y * radius, c + Z * radius, c - Z * radius]
		faces = [(4, 0, 2), (4, 2, 1), (4, 1, 3), (4, 3, 0), (5, 2, 0), (5, 1, 2), (5, 3, 1), (5, 0, 3)]
		for f in faces:
			p = [pts[i] for i in f]
			g.add("keep_iron", p, [(0, 0), (1, 0), (0.5, 1)], (p[0] + p[1] + p[2]) / 3 - c)

	def pendant_rails(self) -> None:
		"""Varal de madera del que cuelga cada pendón, en el borde del cadalso de cada cara."""
		g, rng = self.g, self.rng
		for n_h in (X, Y, -X, -Y):
			t = Z.cross(n_h).normalized()
			c = n_h * (HOARD_H + 0.17) + Z * (WALK_Z - 0.14)
			bevel_box(g, "keep_wood", c, (n_h, t, Z), (0.10, 1.9, 0.10), 0.01, WOOD_TILE, t, rng, 0.0, tint=board_tint(rng, 0.04))
			for sgn in (-1, 1):
				bevel_box(g, "keep_iron", c + t * sgn * 0.9, (n_h, t, Z), (0.04, 0.04, 0.10), 0.005, STONE_TILE, None, None, 0.0)

	# --- contacto con el suelo --------------------------------------------------------------------
	def foot_rubble(self) -> None:
		"""Piedras caídas y sillares medio enterrados: agrupados en las esquinas y junto al porche,
		de tamaños muy distintos, con la mitad bajo tierra. Atan el torreón a la colina."""
		g = self.g
		rng = random.Random(4242)
		grng = random.Random(99)
		HB = PLINTH_HALF_BOTTOM
		lod0 = self.lod == 0

		def stone(cx, cy, size, yaw, bury):
			ex = Vector((math.cos(yaw), math.sin(yaw), 0.0))
			ey = Z.cross(ex).normalized()
			center = Vector((cx, cy, 0.0)) + Z * (size.z * 0.5 - bury)
			tint = block_tint(grng, 0.09)
			tint = (tint[0] * 0.92, tint[1] * 0.93, tint[2] * 0.9)
			bevel_box(g, "keep_stone", center, (ex, ey, Z), (size.x, size.y, size.z), 0.08 if lod0 else 0.0, STONE_TILE, None,
					grng, 0.035, tint=tint)

		for sx, sy in CORNER_SIGNS:
			# un bloque grande en la esquina y cuatro de menor tamaño alrededor
			stone(sx * (HB + 0.42), sy * (HB + 0.42), Vector((rng.uniform(1.0, 1.35), rng.uniform(0.75, 0.95), rng.uniform(0.55, 0.8))),
					math.atan2(sy, sx) + rng.uniform(-0.4, 0.4), rng.uniform(0.25, 0.4))
			for _ in range(4):
				if rng.random() < 0.5:
					cx = sx * (HB - rng.uniform(0.0, 1.6))
					cy = sy * (HB + rng.uniform(0.25, 0.85))
				else:
					cx = sx * (HB + rng.uniform(0.25, 0.85))
					cy = sy * (HB - rng.uniform(0.0, 1.6))
				stone(cx, cy, Vector((rng.uniform(0.4, 0.8), rng.uniform(0.32, 0.55), rng.uniform(0.25, 0.45))),
						rng.uniform(0.0, math.pi), rng.uniform(0.08, 0.22))
		# a lo largo de cada lado, alguna piedra suelta y casi enterrada
		for side, n_h in enumerate((X, Y, -X, -Y)):
			t = Z.cross(n_h).normalized()
			for _ in range(3):
				u = rng.uniform(-HB + 1.6, HB - 1.6)
				if side == 2 and abs(u) < PORCH_HALF + 1.4:
					continue
				p = n_h * (HB + rng.uniform(0.18, 0.5)) + t * u
				stone(p.x, p.y, Vector((rng.uniform(0.3, 0.6), rng.uniform(0.25, 0.45), rng.uniform(0.2, 0.35))),
						rng.uniform(0.0, math.pi), rng.uniform(0.10, 0.2))
		# junto al porche: dos piedras grandes a cada lado del peldaño y una losa caída delante
		for sgn in (-1, 1):
			stone(-PORCH_FRONT - 0.35, sgn * (PORCH_HALF + 0.55), Vector((0.9, 0.7, 0.5)), rng.uniform(-0.3, 0.3), 0.22)
			stone(-PORCH_FRONT + 0.4, sgn * (PORCH_HALF + 0.95), Vector((0.55, 0.45, 0.34)), rng.uniform(0, 3), 0.1)
		stone(-PORCH_FRONT - 1.15, 0.15, Vector((1.3, 0.8, 0.22)), 0.25, 0.12)

	def foot_skirt(self) -> None:
		"""Falda de tierra y hierba que sube por el zócalo y se hunde en el terreno: el zócalo deja de
		acabar en una línea dura sobre el patio. Colores de vértice de tierra a hierba."""
		g = self.g
		rng = random.Random(777)
		HB = PLINTH_HALF_BOTTOM + PLINTH.q
		loop = []
		for k, (sx, sy) in enumerate(CORNER_SIGNS):
			# cada tramo va de una esquina a la siguiente por el lado que las une
			nxt = CORNER_SIGNS[(k + 1) % 4]
			steps = 13
			for s in range(steps):
				f = s / steps
				nx = sx + (nxt[0] - sx) * f
				ny = sy + (nxt[1] - sy) * f
				ln = math.hypot(nx, ny)
				loop.append((HB * nx, HB * ny, nx / ln, ny / ln))
		count = len(loop)
		noise = [rng.uniform(0.0, 1.0) for _ in range(count)]
		# (separación al zócalo, altura, color de tierra a hierba)
		profile = [(-0.15, 0.40, (0.075, 0.058, 0.040)), (0.40, 0.30, (0.088, 0.071, 0.046)),
				(1.00, 0.12, (0.095, 0.104, 0.058)), (1.75, -0.04, (0.104, 0.128, 0.070)), (2.35, -0.30, (0.107, 0.133, 0.074))]
		rings = []
		for off, z, col in profile:
			ring = []
			for i, (x, y, nx, ny) in enumerate(loop):
				w = 0.65 + 0.7 * (0.5 * noise[i] + 0.5 * noise[(i + 1) % count])
				o = off if off < 0.1 else off * w
				px = x + nx * o
				py = y + ny * o
				zz = z + (0.06 * (noise[i] - 0.5) if off > 0.1 else 0.0)
				# junto al porche la falda baja para no tapar el umbral
				if px < 0 and abs(py) < PORCH_HALF + 0.7 and off < 1.5:
					zz = min(zz, 0.02)
				shade = 0.88 + 0.24 * noise[(i * 7) % count]
				ring.append((Vector((px, py, zz)), (col[0] * shade, col[1] * shade, col[2] * shade)))
			rings.append(ring)
		for r in range(len(rings) - 1):
			a, b = rings[r], rings[r + 1]
			for i in range(count):
				j = (i + 1) % count
				pts = [a[i][0], a[j][0], b[j][0], b[i][0]]
				cols = [a[i][1], a[j][1], b[j][1], b[i][1]]
				uvs = [(p.x * 0.3, p.y * 0.3) for p in pts]
				g.add("keep_earth", pts, uvs, Z, cols, 1.0)

	def run(self) -> Geo:
		self.plinth()
		self.foot_skirt()
		self.foot_rubble()
		self.bays()
		self.string_courses()
		self.parapet()
		self.porch()
		self.hoarding()
		self.pendant_rails()
		self.roof()
		self.turret_top()
		self.flagpole()
		register_fissures()   # grietas de brasa (Eldrun)
		return self.g


# ---------------------------------------------------------------------------------------------
# Estandartes (nodo propio)
# ---------------------------------------------------------------------------------------------
def sway_color(direction):
	"""Direccion del vaiven de una tela codificada como color (0..1), ya en el espacio de Godot (el
	exportador pasa de Z arriba a Y arriba: x, y, z -> x, z, -y). El shader la lee de COLOR.rgb: una
	direccion comun a toda la pieza evita que las caras sueltas se separen al moverse."""
	d = Vector(direction).normalized()
	return (d.x * 0.5 + 0.5, d.z * 0.5 + 0.5, -d.y * 0.5 + 0.5)


def build_banners() -> Geo:
	"""Gallardete del asta y un pendón colgado del cadalso en cada cara. Van en su propio objeto
	(Estandarte), fuera de las mallas fusionadas de los LOD. El alfa del color de vértice es el
	peso del viento (0 donde la tela está sujeta, 1 en la punta libre); fort_keep_cloth.gdshader
	mueve los vértices con él y lee faction_color, emblem_index y capture_progress por instancia."""
	g = Geo()
	# gallardete: 3,5 m de largo y 1,55 de alto en el asta, con cola de golondrina; ondea hacia -X.

	x0, y0 = -0.10, 0.0
	z_top = TOTAL_TOP - 0.22
	length, height, notch = 3.5, 1.55, 1.15
	cols, rows = 16, 8
	for j in range(rows):
		for i in range(cols):
			quad = []
			uvs = []
			wind = []
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
				wind.append(min(1.0, along ** 1.1 + 0.02))
			g.add("keep_cloth", quad, uvs, Y, sway_color(Y), wind)
	# pendones: 1,5 m de ancho y unos 3,4 de largo, con punta, a cada lado del cadalso
	width, drop = 1.5, 2.9
	prow, pcols = 10, 6
	z_hang = WALK_Z - 0.19
	for n_h in (X, Y, -X, -Y):
		t = Z.cross(n_h).normalized()
		center = n_h * (HOARD_H + 0.12)
		for j in range(prow):
			f0, f1 = j / prow, (j + 1) / prow
			w0 = 0.5 * width if f0 < 0.8 else 0.5 * width * max(0.0, 1.0 - (f0 - 0.8) / 0.2)
			w1 = 0.5 * width if f1 < 0.8 else 0.5 * width * max(0.0, 1.0 - (f1 - 0.8) / 0.2)

			def vert(f, w, k, cnt):
				u = (-w + 2.0 * w * k / cnt) if w > 1e-6 else 0.0
				bulge = 0.05 * math.sin(f * 5.5 + 0.8) * (0.25 + f) + 0.03 * math.sin(u * 4.0 + f * 3.0)
				p = center + t * u + n_h * bulge + Z * (z_hang - drop * f)
				return p, (u / width + 0.5, 1.0 - f)

			for k in range(pcols):
				if w1 < 1e-6:
					a, ua = vert(f0, w0, k, pcols)
					b, ub = vert(f0, w0, k + 1, pcols)
					c, uc = vert(f1, w1, 0, pcols)
					g.add("keep_pendant", [a, b, c], [ua, ub, uc], n_h, sway_color(n_h), [f0, f0, f1])
				else:
					a, ua = vert(f0, w0, k, pcols)
					b, ub = vert(f0, w0, k + 1, pcols)
					c, uc = vert(f1, w1, k + 1, pcols)
					d, ud = vert(f1, w1, k, pcols)
					g.add("keep_pendant", [a, b, c, d], [ua, ub, uc, ud], n_h, sway_color(n_h), [f0, f0, f1, f1])
	return g


# ---------------------------------------------------------------------------------------------
# Colisión de baja resolución
# ---------------------------------------------------------------------------------------------
def build_collision() -> Geo:
	g = Geo()
	tile = 4.0
	hb = PLINTH_HALF_BOTTOM
	q = 0.12
	profile = [(hb - 1.0, FOOT_Z), (hb - 1.0, 0.0), (PLINTH_HALF_TOP - 1.0, PLINTH_TOP),
			(wall_half(LEDGE_TOP) + q - 1.0, PLINTH_TOP + 0.35), (wall_half(CORDON_Z0) + 0.17 - 1.0, CORDON_Z0),
			(wall_half(CORDON_Z0) + 0.17 - 1.0, CORDON_Z0 + 0.20), (wall_half(CORDON_Z1) + q - 1.0, CORDON_Z1),
			(wall_half(CORNICE_Z0) + q - 1.0, CORNICE_Z0), (wall_half(CORNICE_Z0) + 0.48 - 1.0, CORNICE_Z0),
			(wall_half(CORNICE_Z0) + 0.48 - 1.0, CORNICE_Z0 + 0.34), (H_TOP - 1.0, CORNICE_Z0 + 0.55)]
	loft(g, "col", (-1.0, 1.0, -1.0, 1.0), profile, tile)
	# cuerpo del parapeto y adarve (sólido, para que ni la cámara ni los proyectiles entren)
	axis_box(g, "col", (-H_TOP, -H_TOP, CORNICE_Z0 + 0.4), (H_TOP, H_TOP, COPING_TOP), 0.0, tile)
	# cadalso: solera, pared baja y friso, por los cuatro lados
	for n_h in (X, Y, -X, -Y):
		t = Z.cross(n_h).normalized()
		half = HOARD_H + 0.05
		deck = n_h * ((H_TOP + HOARD_H + 0.1) * 0.5) + Z * (WALK_Z - 0.09)
		bevel_box(g, "col", deck, (n_h, t, Z), (HOARD_H + 0.1 - H_TOP, 2 * half, 0.18), 0.0, tile)
		wall_c = n_h * (HOARD_H) + Z * ((WALK_Z + WALK_Z + 1.2) * 0.5)
		bevel_box(g, "col", wall_c, (n_h, t, Z), (0.22, 2 * half, 1.2), 0.0, tile)
		plate_c = n_h * (HOARD_H) + Z * (PLATE_Z - 0.3)
		bevel_box(g, "col", plate_c, (n_h, t, Z), (0.22, 2 * half, 0.6), 0.0, tile)
	# tejado: pirámide cerrada
	apex = Vector((0.0, 0.0, ROOF_APEX_Z))
	R = ROOF_R
	rise = ROOF_APEX_Z - ROOF_EAVE_Z
	for d in (X, Y, -X, -Y):
		tang = Z.cross(d)
		a = d * R - tang * R + Z * ROOF_EAVE_Z
		b = d * R + tang * R + Z * ROOF_EAVE_Z
		g.add("col", [a, b, apex], [(0, 0), (1, 0), (0.5, 1)], (d * rise + Z * R))
	# torrecilla y porche
	x0, x1 = H_TOP - TURRET_IN, H_TOP + TURRET_OUT
	axis_box(g, "col", (x0, x0, CORNICE_Z0), (x1, x1, TURRET_TOP), 0.0, tile)
	half = (x1 - x0) * 0.5 + 0.34
	cx = (x0 + x1) * 0.5
	eave = TURRET_TOP + 0.2
	tapex = Vector((cx, cx, TURRET_ROOF_APEX))
	for d in (X, Y, -X, -Y):
		tang = Z.cross(d)
		a = Vector((cx, cx, 0.0)) + d * half - tang * half + Z * eave
		b = Vector((cx, cx, 0.0)) + d * half + tang * half + Z * eave
		g.add("col", [a, b, tapex], [(0, 0), (1, 0), (0.5, 1)], (d * (TURRET_ROOF_APEX - eave) + Z * half))
	axis_box(g, "col", (-PORCH_FRONT, -PORCH_HALF, FOOT_Z), (-H_WALL0, PORCH_HALF, PORCH_TOP), 0.0, tile)
	return g


# ---------------------------------------------------------------------------------------------
# LOD lejano
# ---------------------------------------------------------------------------------------------
def build_lod_far() -> Geo:
	"""Silueta de unos 600 triángulos para más de 250 m: zócalo y muro con talud, cordón, cornisa,
	cadalso, tejado, torrecilla, porche, vanos como manchas oscuras y el asta."""
	g = Geo()
	wall = "keep_wall"
	tile = STONE_TILE
	hb = PLINTH_HALF_BOTTOM
	q = 0.12
	profile = [(hb - 1.0, FOOT_Z), (hb - 1.0, 0.0), (PLINTH_HALF_TOP - 1.0, PLINTH_TOP),
			(PLINTH_HALF_TOP + 0.2 - 1.0, PLINTH_TOP + 0.12), (wall_half(LEDGE_TOP) - 1.0, PLINTH_TOP + 0.34)]
	loft(g, wall, (-1.0, 1.0, -1.0, 1.0), profile, tile, ao=[0.6, 0.8, 1.0, 1.0, 1.0])
	body = [(wall_half(LEDGE_TOP) - 1.0, LEDGE_TOP), (wall_half(CORDON_Z0) - 1.0, CORDON_Z0)]
	loft(g, wall, (-1.0, 1.0, -1.0, 1.0), body, tile)
	loft(g, "keep_trim", (-1.0, 1.0, -1.0, 1.0), [(wall_half(CORDON_Z0) - 1.0, CORDON_Z0), (wall_half(CORDON_Z0) + 0.17 - 1.0, CORDON_Z0),
			(wall_half(CORDON_Z0) + 0.17 - 1.0, CORDON_Z0 + 0.2), (wall_half(CORDON_Z1) - 1.0, CORDON_Z1)], tile)
	loft(g, wall, (-1.0, 1.0, -1.0, 1.0), [(wall_half(CORDON_Z1) - 1.0, CORDON_Z1), (H_TOP - 1.0, CORNICE_Z0)], tile)
	h = H_TOP
	loft(g, "keep_trim", (-1.0, 1.0, -1.0, 1.0), [(h - 1.0, CORNICE_Z0), (h + 0.30 - 1.0, CORNICE_Z0), (h + 0.48 - 1.0, CORNICE_Z0 + 0.14),
			(h + 0.48 - 1.0, CORNICE_Z0 + 0.34), (h - 1.0, CORNICE_Z0 + 0.55)], tile)
	# cadalso
	loft(g, "keep_wood", (-1.0, 1.0, -1.0, 1.0), [(h + 0.1 - 1.0, WALK_Z - 0.6), (HOARD_H - 1.0, WALK_Z - 0.2), (HOARD_H - 1.0, PLATE_Z),
			(h - 1.0, PLATE_Z)], WOOD_TILE, ao=[0.5, 0.9, 1.0, 1.0])
	# tejado
	R = ROOF_R
	apex = Vector((0.0, 0.0, ROOF_APEX_Z))
	rise = ROOF_APEX_Z - ROOF_EAVE_Z
	for d in (X, Y, -X, -Y):
		tang = Z.cross(d)
		a = d * R - tang * R + Z * ROOF_EAVE_Z
		b = d * R + tang * R + Z * ROOF_EAVE_Z
		g.add("keep_roof", [a, b, apex], [(0, 0), (2 * R / ROOF_TILE, 0), (R / ROOF_TILE, R / ROOF_TILE * 1.2)], d * rise + Z * R, None, 1.0)
	# torrecilla
	x0, x1 = H_TOP - TURRET_IN, H_TOP + TURRET_OUT
	axis_box(g, wall, (x0, x0, CORNICE_Z0), (x1, x1, TURRET_TOP), 0.0, tile)
	cx = (x0 + x1) * 0.5
	half = (x1 - x0) * 0.5 + 0.34
	eave = TURRET_TOP + 0.2
	tapex = Vector((cx, cx, TURRET_ROOF_APEX))
	for d in (X, Y, -X, -Y):
		tang = Z.cross(d)
		a = Vector((cx, cx, 0.0)) + d * half - tang * half + Z * eave
		b = Vector((cx, cx, 0.0)) + d * half + tang * half + Z * eave
		g.add("keep_roof", [a, b, tapex], [(0, 0), (2, 0), (1, 2)], d * (TURRET_ROOF_APEX - eave) + Z * half, None, 1.0)
	# porche y puerta
	axis_box(g, wall, (-PORCH_FRONT, -PORCH_HALF, FOOT_Z), (-H_WALL0, PORCH_HALF, PORCH_TOP - 0.3), 0.0, tile)
	g.add("keep_dark", [Vector((-PORCH_FRONT - 0.01, -0.95, 0.0)), Vector((-PORCH_FRONT - 0.01, 0.95, 0.0)),
			Vector((-PORCH_FRONT - 0.01, 0.95, 3.0)), Vector((-PORCH_FRONT - 0.01, -0.95, 3.0))], [(0, 0)] * 4, -X)
	axis_box(g, "keep_roof", (-PORCH_FRONT - 0.3, -PORCH_HALF - 0.3, PORCH_TOP), (-H_WALL0 + 0.1, PORCH_HALF + 0.3, PORCH_TOP + 0.25), 0.0, ROOF_TILE)
	# huecos oscuros (ventanas y saeteras principales)
	for name, n_h in FACE_NORMALS:
		t = Z.cross(n_h).normalized()
		for u, z0, z1, w in ((0.0, 9.6, 11.7, 0.9), (-1.0, 11.9, 13.2, 0.28), (1.0, 11.9, 13.2, 0.28), (0.0, 6.0, 7.5, 0.28)):
			if name == "W" and z0 < 7.0:
				continue
			base = n_h * (wall_half(z0) + 0.09) + t * u
			p = [base - t * (w * 0.5) + Z * z0, base + t * (w * 0.5) + Z * z0, base + t * (w * 0.5) + Z * z1, base - t * (w * 0.5) + Z * z1]
			g.add("keep_dark", p, [(0, 0)] * 4, n_h)
	# asta
	cylinder(g, "keep_wood", (0.0, 0.0), 0.11, ROOF_APEX_Z, TOTAL_TOP - 0.1, 5, 3.0, 0.7, False)
	return g


# ---------------------------------------------------------------------------------------------
# Acabado por vértice: suciedad, churretes, sombras bajo los vuelos y brasas
# ---------------------------------------------------------------------------------------------
COLOR_GAIN = 1.25   # el shader multiplica el color de vértice por esto (el valor se guarda dividido)


def _hash3(ix, iy, iz):
	h = (ix * 374761393 + iy * 668265263 + iz * 2147483629) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return (h & 0xFFFF).astype(np.float64) / 65535.0


def vnoise(P, scale, offset=0.0):
	"""Ruido de valor 3D (0..1), suave, en las posiciones P (N, 3)."""
	q = P * scale + offset
	i = np.floor(q).astype(np.int64)
	f = q - i
	f = f * f * (3.0 - 2.0 * f)

	def c(dx, dy, dz):
		return _hash3(i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz)

	x00 = c(0, 0, 0) + (c(1, 0, 0) - c(0, 0, 0)) * f[:, 0]
	x10 = c(0, 1, 0) + (c(1, 1, 0) - c(0, 1, 0)) * f[:, 0]
	x01 = c(0, 0, 1) + (c(1, 0, 1) - c(0, 0, 1)) * f[:, 0]
	x11 = c(0, 1, 1) + (c(1, 1, 1) - c(0, 1, 1)) * f[:, 0]
	y0 = x00 + (x10 - x00) * f[:, 1]
	y1 = x01 + (x11 - x01) * f[:, 1]
	return y0 + (y1 - y0) * f[:, 2]


CATEGORY = {"keep_stone": 0, "keep_trim": 0, "keep_wall": 0, "keep_mortar": 1, "keep_wood": 2, "keep_roof": 3}


def shade_arrays(P, N, cat, roof_alpha=1.0):
	"""Devuelve (multiplicador RGB, alfa) por vértice. P y N son (N, 3); cat la categoría de material:
	0 piedra, 1 argamasa, 2 madera, 3 tejado y 4 el resto (sin acabado)."""
	n = len(P)
	z = P[:, 2]
	n1 = vnoise(P, 0.55, 1.7)
	n2 = vnoise(P, 1.9, 5.3)
	n3 = vnoise(P, 0.23, 9.1)
	wallish = (np.abs(N[:, 2]) < 0.75).astype(np.float64)
	# humedad y suciedad que suben del suelo
	base = np.clip(1.0 - (z + 0.1) / 2.7, 0.0, 1.0)
	grime = np.clip(base ** 1.3 * np.clip(0.30 + 1.25 * n1 + 0.35 * (n2 - 0.5), 0.0, 1.0), 0.0, 1.0)
	m = 1.0 - 0.36 * grime
	m = m * (1.0 + 0.16 * (n3 - 0.5))
	m = m * (1.0 - 0.28 * np.clip(1.0 - (z + 0.15) / 0.8, 0.0, 1.0))
	# churretes bajo vanos y ménsulas
	streak = np.zeros(n)
	for c, nrm, hw, length, strength in CTX.streaks:
		tdir = Z.cross(nrm)
		d = P - np.array(c)
		lat = np.abs(d @ np.array(tdir))
		dist = d @ np.array(nrm)
		dz = c.z - z
		eff = hw * (1.0 + 0.6 * np.clip(dz / length, 0.0, 1.0))
		ok = (dz > -0.05) & (dz < length) & (lat < eff) & (np.abs(dist) < 1.3) & (N @ np.array(nrm) > 0.3)
		amt = strength * np.clip(1.0 - dz / length, 0.0, 1.0) ** 1.2 * np.clip(1.0 - lat / eff, 0.0, 1.0) ** 0.7 * (0.75 + 0.5 * n2)
		streak = np.maximum(streak, np.where(ok, amt, 0.0))
	m = m * (1.0 - streak)
	# sombra bajo cornisas, cordones y repisas
	for zl, depth, strength in CTX.ledges:
		dz = zl - z
		ok = (dz > 0.0) & (dz < depth)
		m = m * (1.0 - strength * np.where(ok, np.clip(1.0 - dz / depth, 0.0, 1.0) ** 1.6, 0.0) * wallish)
	# grietas de brasa (Eldrun): bandas verticales con un borde roto por el ruido
	fiss = np.zeros(n)
	for c, nrm, hw, z0, z1 in CTX.fissures:
		tdir = Z.cross(nrm)
		d = P - np.array(c)
		lat = np.abs(d @ np.array(tdir)) + 0.30 * (n2 - 0.5)
		dist = d @ np.array(nrm)
		ok = (np.abs(dist) < 1.6) & (N @ np.array(nrm) > 0.3) & (z >= z0) & (z <= z1)
		val = np.clip(1.0 - lat / hw, 0.0, 1.0) ** 1.1 * np.clip((z1 - z) / 0.8 + 0.2, 0.0, 1.0)
		fiss = np.maximum(fiss, np.where(ok, val, 0.0))
	rgb = np.stack([m * (1.0 + 0.05 * grime), m, m * (1.0 - 0.07 * grime)], axis=-1)
	alpha = np.zeros(n)
	stone = cat == 0
	alpha = np.where(stone, np.clip(0.62 * grime * (0.6 + 0.8 * n2) + 0.4 * streak, 0.0, 0.66), alpha)
	alpha = np.where(stone, np.maximum(alpha, fiss), alpha)
	alpha = np.where(cat == 1, fiss * (0.45 + 0.55 * n2), alpha)
	alpha = np.where(cat == 3, roof_alpha, alpha)
	wood = (cat == 2)
	rgb = np.where(wood[:, None], np.stack([np.ones(n)] * 3, axis=-1) * (1.0 - 0.18 * grime + 0.12 * (n1 - 0.5))[:, None], rgb)
	rgb = np.where((cat == 3)[:, None], (0.96 + 0.10 * (n3 - 0.5))[:, None] * np.ones((n, 3)), rgb)
	rgb = np.where((cat == 4)[:, None], np.ones((n, 3)), rgb)
	return rgb, alpha


# ---------------------------------------------------------------------------------------------
# Volcado a Blender, materiales, exportación
# ---------------------------------------------------------------------------------------------
def make_material(name, color, rough=0.9, metal=0.0, double_sided=False):
	mat = bpy.data.materials.new(name)
	mat.use_nodes = True
	bsdf = mat.node_tree.nodes.get("Principled BSDF")
	bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
	bsdf.inputs["Roughness"].default_value = rough
	bsdf.inputs["Metallic"].default_value = metal
	mat.use_backface_culling = not double_sided
	return mat


def make_materials():
	"""Materiales del glTF: solo color base (los materiales de reino del juego los sustituyen por
	fort_keep_surface con las texturas de fort_keep/textures/)."""
	mats = {}
	for name in MATERIALS + ["col"]:
		rough, metal = 0.9, 0.0
		if name == "keep_iron":
			rough, metal = 0.45, 0.85
		mats[name] = make_material(name, MATERIAL_COLORS[name], rough, metal, name in ("keep_cloth", "keep_pendant"))
	return mats


def to_object(name, geo, mats, collection, mode="shade", roof_alpha=1.0):
	"""Convierte un Geo en un objeto de Blender con un hueco de material por material usado y,
	según mode, color de vértice: "shade" (tinte x oclusión x acabado de to_object), "wind" (RGB es la
	dirección del vaivén, ver sway_color, y el alfa el peso del viento, que se guarda en la lista ao)
	o "none" (colisión)."""
	used = []
	for face in geo.faces:
		if face[0] not in used:
			used.append(face[0])
	order = [m for m in MATERIALS + ["col"] if m in used]
	index = {m: i for i, m in enumerate(order)}
	verts = []
	polys = []
	mat_index = []
	pos = []
	nrm = []
	cat = []
	tint = []
	ao = []
	for mat, pts, _uv, f_tint, f_ao in geo.faces:
		start = len(verts)
		verts.extend([tuple(p) for p in pts])
		polys.append(tuple(range(start, start + len(pts))))
		mat_index.append(index[mat])
		normal = Vector((0.0, 0.0, 0.0))
		count = len(pts)
		for i in range(count):
			a = pts[i]
			b = pts[(i + 1) % count]
			normal.x += (a.y - b.y) * (a.z + b.z)
			normal.y += (a.z - b.z) * (a.x + b.x)
			normal.z += (a.x - b.x) * (a.y + b.y)
		normal.normalize()
		for k, p in enumerate(pts):
			pos.append((p.x, p.y, p.z))
			nrm.append((normal.x, normal.y, normal.z))
			cat.append(CATEGORY.get(mat, 4))
			if isinstance(f_tint, list):
				tint.append(f_tint[k])
			else:
				tint.append(f_tint if f_tint is not None else (1.0, 1.0, 1.0))
			ao.append(f_ao[k] if isinstance(f_ao, list) else (1.0 if f_ao is None else f_ao))
	mesh = bpy.data.meshes.new(name)
	mesh.from_pydata(verts, [], polys)
	for m in order:
		mesh.materials.append(mats[m])
	uv_layer = mesh.uv_layers.new(name="UVMap")
	loop = 0
	for poly_i, (_mat, pts, uvs, _t, _a) in enumerate(geo.faces):
		mesh.polygons[poly_i].material_index = mat_index[poly_i]
		mesh.polygons[poly_i].use_smooth = False
		for k in range(len(pts)):
			uv_layer.data[loop].uv = uvs[k]
			loop += 1
	mesh.update()
	if mode != "none" and pos:
		P = np.array(pos, dtype=np.float64)
		N = np.array(nrm, dtype=np.float64)
		T = np.array(tint, dtype=np.float64)
		A = np.array(ao, dtype=np.float64)
		if mode == "shade":
			rgb, alpha = shade_arrays(P, N, np.array(cat), roof_alpha)
			col = np.clip(rgb * T * A[:, None] / COLOR_GAIN, 0.0, 1.0)
			col4 = np.concatenate([col, alpha[:, None]], axis=1)
		else:
			col4 = np.concatenate([np.clip(T, 0.0, 1.0), np.clip(A, 0.0, 1.0)[:, None]], axis=1)
		attr = mesh.color_attributes.new(name="Color", type='FLOAT_COLOR', domain='CORNER')
		attr.data.foreach_set("color", col4.astype(np.float32).ravel())
		mesh.color_attributes.active_color = attr
	obj = bpy.data.objects.new(name, mesh)
	collection.objects.link(obj)
	return obj


def register_far_shading() -> None:
	"""El LOD lejano no monta piezas con churretes: solo las sombras bajo los vuelos y las grietas."""
	CTX.ledge(PLINTH_TOP, 0.7, 0.30)
	CTX.ledge(CORDON_Z0, 0.8, 0.34)
	CTX.ledge(CORNICE_Z0, 1.0, 0.36)
	register_fissures()


def register_fissures() -> None:
	hb = PLINTH_HALF_BOTTOM
	CTX.fissure((1.2, -hb, 0.0), -Y, 0.55, -0.2, 2.9)
	CTX.fissure((hb, -1.4, 0.0), X, 0.5, -0.2, 2.6)
	CTX.fissure((-hb, 2.9, 0.0), -X, 0.5, -0.2, 2.4)
	CTX.fissure((-1.9, hb, 0.0), Y, 0.45, -0.2, 3.0)


def parse_args():
	argv = sys.argv
	argv = argv[argv.index("--") + 1:] if "--" in argv else []
	opts = {"out": DEFAULT_OUT, "render": None, "blend": None}
	i = 0
	while i < len(argv):
		if argv[i] in ("--out", "--render", "--blend") and i + 1 < len(argv):
			opts[argv[i][2:]] = os.path.abspath(argv[i + 1])
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

	# cada nivel registra su propio acabado (churretes, sombras bajo los vuelos) y se pinta antes de
	# montar el siguiente: así el LOD medio y el lejano oscurecen igual que el detallado
	CTX.reset()
	lod0 = Builder(0).run()
	obj0 = to_object("FortKeep_LOD0", lod0, mats, collection)
	CTX.reset()
	lod1 = Builder(1).run()
	obj1 = to_object("FortKeep_LOD1", lod1, mats, collection)
	CTX.reset()
	register_far_shading()
	lod2 = build_lod_far()
	obj2 = to_object("FortKeep_LOD2", lod2, mats, collection, "shade", 0.0)
	banners = build_banners()
	objb = to_object("Estandarte", banners, mats, collection, "wind")
	col = build_collision()
	objc = to_object("FortKeep-colonly", col, mats, collection, "none")

	xs = [v.co for v in obj0.data.vertices]
	top = max(v.z for v in xs)
	print("FORTKEEP triangulos LOD0=%d LOD1=%d LOD2=%d estandarte=%d colision=%d" % (
			lod0.triangle_count(), lod1.triangle_count(), lod2.triangle_count(), banners.triangle_count(), col.triangle_count()))
	print("FORTKEEP altura LOD0=%.2f m (min %.2f) anchura=%.2f m" % (top, min(v.z for v in xs),
			max(v.x for v in xs) - min(v.x for v in xs)))
	print("FORTKEEP caras LOD0=%d" % len(lod0.faces))

	os.makedirs(os.path.dirname(opts["out"]), exist_ok=True)
	bpy.ops.object.select_all(action='DESELECT')
	bpy.ops.export_scene.gltf(
		filepath=opts["out"], export_format='GLB', use_selection=False, export_apply=True, export_yup=True,
		export_image_format='NONE', export_texcoords=True, export_normals=True, export_tangents=False,
		export_materials='EXPORT', export_vertex_color='ACTIVE', export_active_vertex_color_when_no_material=True,
		export_cameras=False, export_lights=False, export_extras=False, export_animations=False,
		export_draco_mesh_compression_enable=False)
	print("FORTKEEP exportado %s (%.1f MB)" % (opts["out"], os.path.getsize(opts["out"]) / 1048576.0))
	if opts["blend"]:
		bpy.ops.wm.save_as_mainfile(filepath=opts["blend"])
	if opts["render"]:
		render_previews(opts["render"], obj0, [obj1, obj2, objc])


def render_previews(folder, obj0, hidden) -> None:
	"""Renders del modelo solo con Eevee (vistas de comprobación rápida, sin texturas ni color de
	vértice: la referencia visual son las capturas de Godot de tools/render/)."""
	os.makedirs(folder, exist_ok=True)
	scene = bpy.context.scene
	for obj in hidden:
		obj.hide_render = True
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
		"sw": (Vector((-27, -33, 14.5)), Vector((0, 0, 13.0))),
		"ne": (Vector((30, 30, 15)), Vector((0, 0, 13.0))),
		"puerta": (Vector((-13.5, -4.0, 3.0)), Vector((-5.0, 0.0, 3.4))),
		"cadalso": (Vector((-9.0, -8.5, 17.5)), Vector((-1.0, -0.5, 17.2))),
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
