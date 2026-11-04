"""Keep of the Vado Gris fort (ART-57), modeled from scratch in Blender with code. Version 2.

Generates assets/models/environment/custom/fort_keep.glb: a stone keep about 26 m tall (with the
flagpole) and 9.1 m wide at the base, with a battered plinth, a wall with a gentle batter and in bundles (no pilasters or
recessed panels), large ashlar corners hugging both faces, arrow slits and deep
windows, a string course, a cornice with corbels, a wooden hoarding under a hipped roof,
a crenellated parapet, a stair turret with a small roof, a door with a voussoir arch and ironwork
under a porch, banners in their own node and a foot buried in the hill with fallen stones and
a skirt of earth.

Usage, from the repo root (the custom textures have to be generated first):

    python tools/blender/make_fort_keep_textures.py
    blender --background --factory-startup --python tools/blender/build_fort_keep.py -- [options]

Options after "--":
    --out <path.glb>      output GLB (by default assets/models/environment/custom/fort_keep.glb)
    --render <folder>     also saves renders of the model alone (Eevee) in that folder (absolute
                          path or relative to where Blender is launched: it is normalized)
    --blend <path.blend>  also saves the Blender scene (not versioned)

What the GLB contains (top-level nodes):
    FortKeep_LOD0      full detail (modeled ashlars), about 60,000 triangles
    FortKeep_LOD1      medium level, about 5,000 triangles: smooth walls with the cut-ashlar masonry
                       texture (keep_wall), hoarding, brackets, openings and a door with their geometry
    FortKeep_LOD2      distant version, about 600 triangles
    Estandarte         flagpole pennant and banners hanging from the hoarding, outside the LOD
                       meshes so that the fort controller can drive faction_color, emblem_index and
                       capture_progress (instance uniforms of fort_keep_cloth.gdshader) and the
                       shader can animate the wind (the wind weight goes in the vertex color's alpha)
    FortKeep-colonly   separate low-resolution collision (Godot imports it as a StaticBody3D with
                       a trimesh and does not draw the mesh): body, porch, hoarding, parapet, roof and
                       turret

Recommended visibility ranges (set by the game code, not the glTF; see
scripts/client/tools/fort_keep_preview.gd): LOD0 up to 50 m, LOD1 from 50 to 250 m and LOD2 from 250 m,
with visibility_range_fade_mode SELF and a 10 m margin. LOD0 ends early because the modeled joints
(2.4 cm) are subpixel at 30 m or more and flicker when moving; LOD1 flickers half as much.

Axes: it is modeled Z-up with the door toward Blender's -X; the exporter converts it to the Y-up of
glTF/Godot, so the door faces -X in Godot (toward the fort's gate). Origin: center of the
keep at ground level; the plinth goes 1.2 m below the origin to bury itself in the hill.
Footprint: 9.1 m of plinth (with the porch, 10.0 m on the door axis; the fallen stones add
about 0.5 m): before connecting it you have to reposition the CaptureCircle (radius 5 m, center at
x = -8.5) and the CaptainSpawn, re-bake vado_gris_navmesh.tres and fix docs/zonas/vado_gris.md
(it says a tower of 6 x 6 x 12 m).

Vertex color (COLOR_0, linear), which fort_keep_surface.gdshader reads:
    RGB   value and tone of the ashlar (+-8 %), joint occlusion, dirt at the foot, streaks
          under openings, brackets and cornice
    A     wear mask: moss, dust or ash (depending on the realm) and, on the stone, where the
          ember cracks of Eldrun glow; on the mortar, the embers of the joints; on the roof,
          the missing pieces in ruin; on the cloths, the wind weight

Materials (by name, so the game can swap them for the realm ones):
    keep_stone      face ashlars              keep_mortar   bottom of the joints
    keep_trim       dressed stone             keep_wood     painted wood
    keep_iron       ironwork                  keep_dark     openings of arrow slits and windows
    keep_cloth      pennant                   keep_pendant  hanging banners
    keep_roof       roof shingles             keep_wall     cut-ashlar masonry panel (LOD 1 and 2)
    keep_earth      earth skirt at the foot

GLB import settings that are NOT the defaults and must be kept if the editor
regenerates fort_keep.glb.import (the .import is versioned; if it is recreated, set them again):
    meshes/generate_lods = false        the LODs are the ones in this file, with their own ranges and fade;
                                        Godot's automatic generator would overwrite them and deform the
                                        openings and the door
    gltf/embedded_image_handling = 3    (embed uncompressed). This GLB no longer carries images
                                        (the realm materials load the textures from
                                        fort_keep/textures/), but the value is kept so that a recreated
                                        .import does not extract textures next to the model

It is deterministic: fixed seeds.
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
# Dimensions (m)
# ---------------------------------------------------------------------------------------------
FOOT_Z = -1.2                 # bottom of the plinth, buried
PLINTH_HALF_BOTTOM = 4.55     # half-width of the plinth at ground level (z = 0)
PLINTH_HALF_TOP = 4.05
PLINTH_TOP = 3.00             # top of the battered plinth
LEDGE_TOP = 3.25              # first course of the wall (the ledge covers it from below)
H_WALL0 = 3.58                # half-width of the wall at z = LEDGE_TOP
SLOPE_LOW = -0.030            # batter (m of half-width per m of height) of the lower part
CORDON_Z0, CORDON_Z1 = 8.55, 8.90
CORDON_STEP = 0.10            # how much the wall steps in above the string course
SLOPE_UP = -0.022
CORNICE_Z0 = 14.00            # cornice with corbels under the hoarding
WALK_Z = 14.90                # floor of the wall walk and of the hoarding
PARAPET_BASE = 14.30
PARAPET_TOP = 16.05
COPING_TOP = 16.25
MERLON_TOP = 17.45
PLATE_Z = 17.60               # ridge beam on which the roof rests
ROOF_EAVE_Z = 17.72
ROOF_APEX_Z = 22.00
TURRET_TOP = 20.90
TURRET_ROOF_APEX = 23.60
TOTAL_TOP = 25.80             # tip of the flagpole
HOARD_OUT = 1.10              # how far the hoarding projects from the wall above
ROOF_OVERHANG = 0.55
PORCH_FRONT = PLINTH_HALF_BOTTOM + 0.38   # front face of the door porch (at -X)
PORCH_HALF = 1.70
PORCH_TOP = 4.90

BLOCK_GAP = 0.012
STONE_TILE = 3.2              # meters per tile of the stone texture
WOOD_TILE = 3.0
ROOF_TILE = 2.0               # one shingle of the texture measures 0.2 m of course

MATERIALS = ["keep_stone", "keep_mortar", "keep_trim", "keep_wood", "keep_iron", "keep_dark",
		"keep_cloth", "keep_pendant", "keep_roof", "keep_wall", "keep_earth"]

# Base color of each material in the glTF (only visible if the game does not replace it with the realm one).
MATERIAL_COLORS = {
	"keep_stone": (0.46, 0.46, 0.45), "keep_mortar": (0.17, 0.16, 0.15), "keep_trim": (0.58, 0.57, 0.55),
	"keep_wood": (0.30, 0.21, 0.14), "keep_iron": (0.08, 0.08, 0.09), "keep_dark": (0.012, 0.012, 0.015),
	"keep_cloth": (0.80, 0.78, 0.70), "keep_pendant": (0.80, 0.78, 0.70), "keep_roof": (0.28, 0.30, 0.34),
	"keep_wall": (0.46, 0.46, 0.45), "keep_earth": (0.30, 0.27, 0.19), "col": (1.0, 0.0, 1.0),
}


def wall_half(z: float) -> float:
	"""Half-width of the wall (without ashlars) at height z: gentle batter, with a setback at the string course."""
	if z < CORDON_Z1:
		return H_WALL0 + SLOPE_LOW * (z - LEDGE_TOP)
	h_cordon = H_WALL0 + SLOPE_LOW * (CORDON_Z0 - LEDGE_TOP) - CORDON_STEP
	return h_cordon + SLOPE_UP * (z - CORDON_Z1)


H_TOP = wall_half(CORNICE_Z0)             # half-width of the wall below the cornice
HOARD_H = H_TOP + HOARD_OUT               # half-width of the hoarding (outer face)
ROOF_R = HOARD_H + ROOF_OVERHANG          # half-width of the eave


class Style:
	"""Layout and finishing parameters of a panel of ashlars."""

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
		self.quoin = quoin       # (long, short) of the corner stones
		self.q = q               # how far the corner stones protrude from the wall plane
		self.sigma = sigma       # value variation per ashlar
		self.ao_joint = ao_joint


WALL = Style()
PLINTH = Style(lo=1.0, hi=2.3, min_len=0.6, depth=0.095, chamfer=0.045, gap=0.014, drop=0.045,
		quoin=(1.40, 0.82), q=0.17, sigma=0.085)
SMALL = Style(lo=0.5, hi=1.0, min_len=0.3, depth=0.07, chamfer=0.026, sigma=0.07)


# ---------------------------------------------------------------------------------------------
# Finishing context (dirt, streaks, embers): filled in by the pieces and evaluated by to_object
# ---------------------------------------------------------------------------------------------
class ShadeContext:
	def __init__(self) -> None:
		self.streaks = []     # (center, normal, half-width, length, strength)
		self.ledges = []      # (z of the overhang, depth of the shadow, strength)
		self.fissures = []    # (center, normal, half-width, z0, z1): ember cracks of Eldrun

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
# Geometry accumulator
# ---------------------------------------------------------------------------------------------
class Geo:
	"""List of polygons (material, points, UV, tint, occlusion). It is dumped into a Blender mesh."""

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
	"""UV axes (u, v) for a face with normal n. With grain, the grain runs along u."""
	if grain is not None:
		g = grain - n * grain.dot(n)
		if g.length > 1e-5:
			ex = g.normalized()
			return ex, n.cross(ex)
	if abs(n.z) > 0.7:
		return X.copy(), Y.copy()
	return Z.cross(n).normalized(), Z.copy()


def block_tint(rng, sigma=0.05):
	"""Value and tone of each ashlar (the painter does not give every one the same gray)."""
	v = 1.0 + max(-2.0, min(2.0, rng.gauss(0.0, 1.0))) * sigma
	roll = rng.random()
	if roll < 0.06:
		v *= rng.uniform(0.80, 0.90)       # dark ashlar, a replacement
	elif roll < 0.11:
		v *= rng.uniform(1.07, 1.13)       # light ashlar, freshly dressed
	w = rng.gauss(0.0, 0.022)
	return (v * (1.0 + w), v * (1.0 + 0.15 * w), v * (1.0 - w))


def board_tint(rng, sigma=0.07):
	v = 1.0 + max(-2.0, min(2.0, rng.gauss(0.0, 1.0))) * sigma
	w = rng.gauss(0.0, 0.02)
	return (v * (1.0 + w), v, v * (1.0 - w))


# ---------------------------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------------------------
def bevel_box(g, mat, center, axes, size, bevel=0.0, tile=STONE_TILE, grain=None, rng=None,
		jitter=0.0, offset=None, tint=None, skip_back=None):
	"""Beveled box of a section. axes = (ex, ey, ez) orthonormal; size = (sx, sy, sz).
	skip_back: vector; if given, faces pointing the opposite way are not emitted (those that
	end up inside the wall)."""
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
	"""Axis-aligned box between two corners."""
	lo = Vector(lo)
	hi = Vector(hi)
	center = (lo + hi) * 0.5
	size = (hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
	bevel_box(g, mat, center, (X, Y, Z), size, bevel, tile, grain, rng, jitter, tint=tint)


def plank(g, mat, center, axes, size, tile=WOOD_TILE, grain=None, rng=None, tint=None, hide=None):
	"""Unbeveled board (up to 6 faces): for the crowd of hoarding boards. hide is a vector
	toward the interior: the face looking at it is not emitted."""
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
	"""Beam of section w x h between two points (the grain runs along it)."""
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
	"""Rectangular ring with a profile (h, z). rect = (xmin, xmax, ymin, ymax). The profile goes
	counterclockwise around the section: the normal points out to the right of the direction of travel.
	ao: a single value, or a list with the occlusion of each profile point."""
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
	"""Vertical prism (mast, small cylinders). taper scales the top radius."""
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
	"""Ring (pull handle). It lies in the plane of axis_x and axis_y."""
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
	"""Rivet: a low pyramid on a surface."""
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
	"""Course boundaries between z0 and z1: similar but not equal heights, summing exactly to z1-z0."""
	count = max(1, round((z1 - z0) / target))
	heights = [1.0 + rng.uniform(-vary, vary) for _ in range(count)]
	total = sum(heights)
	out = [z0]
	for h in heights:
		out.append(out[-1] + h * (z1 - z0) / total)
	out[-1] = z1
	return out


# ---------------------------------------------------------------------------------------------
# Ashlars
# ---------------------------------------------------------------------------------------------
def cut_pieces(a, b, rng, prev, style):
	"""Splits [a, b] into ashlars of variable length, avoiding joints aligned with the course below."""
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
	"""An ashlar: a slightly irregular flat face and four bevels toward the joint. It carries its own
	tint and the joint occlusion in the vertex color."""
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
	"""Wall of ashlars in a plane: O is the origin (u = 0, v = 0), t the direction of the courses,
	up the upward direction in the plane and n the normal. spans(i, va, vb) gives the spans [(ua, ub)]
	of each course (already without openings or corner stones). Each ashlar carries its piece of
	mortar underneath (the bottom of the joints): this way the ember glow of Eldrun's cracks can go per block."""
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
	"""Subtracts an interval cut = (a, b) from a list of intervals."""
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
	"""Rectangular opening (with an optional arch) in a face. Dimensions in face coordinates."""

	def __init__(self, u_center, width, z0, z1, arch=False, margin=0.0):
		self.uc = u_center
		self.half = width * 0.5
		self.z0 = z0
		self.z1 = z1          # start of the arch if arch, or lintel
		self.arch = arch
		self.margin = margin

	def top(self) -> float:
		return self.z1 + (self.half if self.arch else 0.0)

	def cut_for(self, za, zb):
		"""Interval the opening occupies in a course [za, zb], or None."""
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
	"""Stone face between two corners. With a nonzero slope it is a battered face: the plane
	moves slope meters per meter of height (negative: it closes toward the top)."""

	def __init__(self, n_h, plane, umin, umax, z_courses, openings=(), corners=(), slope=0.0, z_ref=None,
			u_slope=0.0):
		self.n = Vector(n_h)
		self.t = Z.cross(self.n).normalized()
		self.plane = plane          # distance from the plane to the axis (m) at height z_ref
		self.slope = slope
		self.z_ref = z_courses[0] if z_ref is None else z_ref
		self.umin = umin
		self.umax = umax
		self.u_slope = u_slope      # how much the corners (umax) move per meter of height
		self.courses = z_courses
		self.openings = list(openings)
		self.corners = list(corners)  # [(corner, role)] role 'A' or 'B'

	def plane_at(self, z: float) -> float:
		return self.plane + self.slope * (z - self.z_ref)

	def P(self, u: float, z: float, d: float = 0.0) -> Vector:
		"""Point on the face: u along it, height z and d outward (horizontal) from the plane."""
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
		"""Ashlars of the given courses (height limits) with the face's slope."""
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
	"""Outward corner with alternating long and short reinforcing stones."""

	def __init__(self, point, n_a, n_b, parity=0, fixed=None, long=0.80, short=0.46):
		self.P = Vector(point)
		self.nA = Vector(n_a)
		self.nB = Vector(n_b)
		self.parity = parity
		self.fixed = fixed  # (lenA, lenB) for a narrow-return corner
		self.long = long
		self.short = short

	def lens(self, i):
		if self.fixed:
			return self.fixed
		if (i + self.parity) % 2 == 0:
			return (self.long, self.short)
		return (self.short, self.long)

	def end_of(self, face, role):
		"""'max' if the corner is at the face's maximum u."""
		t = face.t
		other = self.nB if role == 'A' else self.nA
		return 'max' if t.dot(other) > 0 else 'min'


def build_quoins(g, corner, courses, rng, protrude=0.045, style=WALL):
	"""Corner stones of a vertical wall: one beveled box per course, alternating long and short."""
	nA, nB = corner.nA, corner.nB
	for i in range(len(courses) - 1):
		za, zb = courses[i] + 0.012, courses[i + 1] - 0.012
		la, lb = corner.lens(i)
		# the body protrudes `protrude` in front of both faces and goes into the wall at the back
		center = corner.P - nA * (lb * 0.5 - protrude * 0.5) - nB * (la * 0.5 - protrude * 0.5)
		center.z = (za + zb) * 0.5
		bevel = 0.032 + rng.uniform(-0.006, 0.014)
		bevel_box(g, "keep_stone", center, (nA, nB, Z), (lb + protrude, la + protrude, zb - za), bevel,
				style.tile, None, rng, 0.004, tint=block_tint(rng, style.sigma))


def quoin_block(g, rng, sx, sy, za, zb, h_a, h_b, la, lb, style, bevel=True):
	"""Corner stone of a battered wall: a parallelepiped whose two outer faces follow
	the two sloped planes and meet at the edge (the hip), with a bevel. This way the two faces
	hug each other without wedges between them. h_a and h_b are the wall's half-widths (without stones) at the bottom and
	top of the course; the stone protrudes style.q from that plane."""
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
# Framed openings
# ---------------------------------------------------------------------------------------------
def frame_opening(g, face, op, rng, reveal=0.6, kind='slit', detail=True, fill=True):
	"""Opening with jambs, dark back, sill and lintel or voussoirs. Arrow slits are splayed
	(they narrow inward) and all of them darken toward the back. Face coordinates."""
	n, t = face.n, face.t
	P = face.P
	hw = op.half
	z0, z1 = op.z0, op.z1
	depth = 0.075      # plane of the ashlars
	splay = 0.42 if kind == 'slit' else 1.0
	hwb = hw * splay
	uc = op.uc
	dark = 0.12
	# dark back
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
	# jambs and sill
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
		# the course passing right over the ring is cut by the arch: it is filled with
		# ashlars so that no gap is left above the voussoirs
		for ci in range(len(face.courses) - 1) if fill else ():
			za, zb = face.courses[ci], face.courses[ci + 1]
			cut = op.cut_for(za, zb)
			if cut and zb > z1 + hw + ring + 0.02:
				lo_z = max(za, z1 + hw + ring - 0.03)
				face.ashlar_rows(g, [lo_z, zb], lambda i, a, b, cut=cut: [cut], rng, WALL)
	elif detail:
		# lintel: a thick, long stone
		center = P(uc, z1 + 0.11, 0.045)
		bevel_box(g, "keep_trim", center, (t, n, Z), (2 * hw + 0.34, 0.14, 0.22), 0.025, STONE_TILE, None, rng, 0.003,
				tint=block_tint(rng, 0.03))
	# projecting sill
	if detail:
		center = P(uc, z0 - 0.07, 0.07)
		bevel_box(g, "keep_trim", center, (t, n, Z), (2 * hw + 0.34, 0.22, 0.14), 0.025, STONE_TILE, None, rng, 0.003,
				tint=block_tint(rng, 0.03))
	# dressed-stone jambs on each side
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
		# vertical iron bars inside the opening
		for k in range(3):
			u = uc + hw * (-0.5 + k * 0.5)
			a = P(u, z0 + 0.05, -0.14)
			b = P(u, z1 + hw * math.sqrt(max(1 - ((u - uc) / hw) ** 2, 0)) * 0.95, -0.14)
			beam(g, "keep_iron", a, b, 0.035, 0.035, 0.004, STONE_TILE, n)
		a = P(uc - hw, z0 + (z1 - z0) * 0.55, -0.14)
		b = P(uc + hw, z0 + (z1 - z0) * 0.55, -0.14)
		beam(g, "keep_iron", a, b, 0.035, 0.035, 0.004, STONE_TILE, n)
	# streak under the sill
	if kind != 'door':
		CTX.streak(P(uc, z0 - 0.1, depth), n, hw * 1.2 + 0.10, 2.8 if kind == 'window' else 2.0, 0.34)


def voussoirs(g, face, uc, zc, r_in, thick, rng, count=9):
	"""Ring of voussoirs of a semicircular arch over a face."""
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
		# sides of the voussoir (intrados, extrados and joints)
		for k in range(4):
			k2 = (k + 1) % 4
			q = [pts_front[k], pts_front[k2], pts_back[k2], pts_back[k]]
			center_f = (pts_front[0] + pts_front[2]) * 0.5
			hint = (q[0] + q[2]) * 0.5 - (center_f - n * (protrude * 0.5))
			g.add("keep_trim", q, [uvf(p) for p in q], hint, tint, [0.62, 0.62, 0.4, 0.4])


# ---------------------------------------------------------------------------------------------
# Smooth panels with the cut-ashlar masonry texture (medium LOD)
# ---------------------------------------------------------------------------------------------
def panel_face(g, face, z_lo, z_hi, ops, tile=STONE_TILE, mat="keep_wall", depth=0.07, quoins=True):
	"""Wall face as a few flat strips (one per span between openings) with the cut-ashlar
	masonry panel texture. The openings are cut with no margin: the frame covers them. It is split at the
	heights of the openings and, on the arches, into segments to follow the curve."""
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
# Battered tower sections: four faces of ashlars and four corners of hugging stones
# ---------------------------------------------------------------------------------------------
FACE_NORMALS = (("E", X), ("N", Y), ("W", -X), ("S", -Y))
CORNER_SIGNS = ((1, 1), (-1, 1), (-1, -1), (1, -1))


def build_section(g, rng, courses, h0, h1, style, openings=None, cuts=None, weathered_fn=None, reveal=1.0, lod=0,
		tile=None):
	"""Tower stretch between courses[0] and courses[-1], with half-width h0 at the bottom and h1 at the top (linear batter).
	openings: {face: [(Opening, type)]}. cuts: {face: [Opening]} openings with no frame (the porch).
	The corner stones of each course are a single piece that hugs both faces, with alternating long
	and short ashlars (stretcher and header). With lod = 1 the walls are flat strips with the cut-ashlar
	masonry texture and the corner stones, two courses tall, carry no bevel."""
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
# Pieces of the keep
# ---------------------------------------------------------------------------------------------
TURRET_IN = 1.75           # how far the turret goes into the wall
TURRET_OUT = 0.50          # how far it projects from the cornice wall


def pyramid_roof(g, rng, cx, cy, half, eave_z, apex_z, rows, thick=0.045, mat="keep_roof", row_group=1):
	"""Pyramidal shingle roof in overlapping rows. Each row is a strip of the
	slope with its edge (the "border" that receives shadow); the upper row rests on
	the lower one. The UVs match the shingle texture (one row of the texture per row)."""
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
			# edge (the thick shingle): from the surface of the row below to this one's
			e0 = base0 - tang * h0 + Z * z0 + nrm * (-0.02 if j == 0 else 0.0)
			e1 = base0 + tang * h0 + Z * z0 + nrm * (-0.02 if j == 0 else 0.0)
			butt = (d * half - Z * rise).normalized()
			g.add(mat, [e0, e1, lo1, lo0], [(u_lo0, 0.0), (u_lo1, 0.0), (u_lo1, 0.012), (u_lo0, 0.012)], butt,
					tint, [0.45, 0.45, 0.85, 0.85])


def snap_opening(op, courses):
	"""Adjusts an opening so that its cut (with margin) starts and ends at course boundaries: a
	course the opening only grazes is removed whole, and if the cut does not match it a
	strip with no stone is left under the sill and over the lintel through which the interior shows."""
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
	"""Assembles the keep. lod = 0: ashlars modeled one by one. lod = 1: medium level, with the walls
	as flat strips of cut-ashlar masonry texture and less fine detail (same silhouette)."""

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

	# --- plinth ---------------------------------------------------------------------------
	def plinth(self) -> None:
		g, rng = self.g, self.rng
		# the porch opening in the plinth: the ashlars (LOD0) and the panels (LOD1) are tucked a few
		# centimeters under the porch's side faces, so that no gap is left between them
		cut_half = PORCH_HALF - 0.05 if self.lod == 0 else PORCH_HALF - 0.12
		porch_cut = {"W": [Opening(0.0, 2 * cut_half, -5.0, PORCH_TOP, False, 0.0)]}

		def wear(i, va) -> float:
			return 0.06 if i < 2 else 0.0

		tile = PLINTH.tile * 1.6   # a plinth course measures 0.75 m: larger than the panel's (0.46 m)
		build_section(g, rng, self.c_foot, PLINTH_HALF_BOTTOM, PLINTH_HALF_BOTTOM, PLINTH, cuts=porch_cut, weathered_fn=wear,
				lod=self.lod, tile=tile)
		build_section(g, rng, self.c_batter, PLINTH_HALF_BOTTOM, PLINTH_HALF_TOP, PLINTH, cuts=porch_cut, weathered_fn=wear,
				lod=self.lod, tile=tile)
		# ledge with glacis: it leaves the plinth and returns to the wall (counterclockwise)
		h = wall_half(LEDGE_TOP)
		out = PLINTH_HALF_TOP + PLINTH.q + 0.10 - h
		loft(g, "keep_trim", (-h, h, -h, h), [(out, PLINTH_TOP - 0.08), (out, PLINTH_TOP + 0.10), (-0.02, PLINTH_TOP + 0.34)],
				STONE_TILE, ao=[0.7, 1.0, 1.0])
		CTX.ledge(PLINTH_TOP, 0.7, 0.30)

	# --- walls ------------------------------------------------------------------------------
	def bays(self) -> None:
		g, rng = self.g, self.rng
		openings = self.make_openings()
		for stage, courses in (("low", self.c_low), ("up", self.c_up)):
			z0, z1 = courses[0], courses[-1]
			ops = {name: [(snap_opening(op, courses), kind) for st, op, kind in items if st == stage]
					for name, items in openings.items()}
			build_section(g, rng, courses, wall_half(z0), wall_half(z1), WALL, openings=ops, reveal=0.95, lod=self.lod)

	def make_openings(self):
		"""Openings per face: {face: [(stage, Opening, type)]}. Stage 'low' (below the string course) or 'up'. Few
		and deep: one arched window per face and narrow splayed arrow slits."""
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

	# --- string course and cornice --------------------------------------------------------------------
	def string_courses(self) -> None:
		g, rng = self.g, self.rng
		# string course: a ring that marks the wall's setback and sheds water away from it
		h = wall_half(CORDON_Z0)
		hu = wall_half(CORDON_Z1)
		loft(g, "keep_trim", (-h, h, -h, h), [(-0.03, CORDON_Z0), (0.17, CORDON_Z0), (0.17, CORDON_Z0 + 0.20),
				(hu - h - 0.01, CORDON_Z1)], STONE_TILE, ao=[0.75, 1.0, 1.0, 0.9])
		CTX.ledge(CORDON_Z0, 0.8, 0.34)
		# cornice: under the hoarding
		h = wall_half(CORNICE_Z0)
		loft(g, "keep_trim", (-h, h, -h, h), [(-0.03, CORNICE_Z0), (0.30, CORNICE_Z0), (0.30, CORNICE_Z0 + 0.14),
				(0.48, CORNICE_Z0 + 0.14), (0.48, CORNICE_Z0 + 0.34), (-0.03, CORNICE_Z0 + 0.55)], STONE_TILE,
				ao=[0.75, 1.0, 0.95, 1.0, 1.0, 0.9])
		CTX.ledge(CORNICE_Z0, 1.0, 0.36)
		# stepped corbels under the cornice
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

	# --- parapet and crenellations ----------------------------------------------------------------------
	def parapet(self) -> None:
		g, rng = self.g, self.rng
		h = H_TOP
		if self.lod == 1:
			self.parapet_simple()
			return
		# parapet wall with ashlars (above the cornice, up to the coping)
		for side_index, n_h in enumerate((X, Y, -X, -Y)):
			face = Face(n_h, h, -h - 0.09, h + 0.09, self.c_parapet)

			def spans(i, za, zb, side_index=side_index):
				lo = -h - (0.09 if (i + side_index) % 2 == 0 else 0.03)
				hi = h + (0.09 if (i + side_index + 1) % 2 == 0 else 0.03)
				return [(lo, hi)]

			face.ashlar_rows(g, self.c_parapet, spans, rng, SMALL)
		# coping and inner face
		loft(g, "keep_trim", (-h, h, -h, h), [(0.0, PARAPET_TOP), (0.11, PARAPET_TOP), (0.11, COPING_TOP - 0.04),
				(0.02, COPING_TOP), (-0.8, COPING_TOP), (-0.8, PARAPET_TOP - 0.02)], STONE_TILE)
		# wall walk floor (slabs)
		inner = h - 0.8
		axis_box(g, "keep_trim", (-inner, -inner, WALK_Z - 0.25), (inner, inner, WALK_Z), 0.0, STONE_TILE, None, rng)
		# inner face of the parapet, with ashlars (seen from above and from the crenellations)
		inner_courses = make_courses(WALK_Z, PARAPET_TOP, 0.40, rng)
		for side_index, n_h in enumerate((X, Y, -X, -Y)):
			face = Face(-n_h, -inner, -inner - 0.09, inner + 0.09, inner_courses)

			def inner_spans(i, za, zb, side_index=side_index):
				lo = -inner - (0.09 if (i + side_index) % 2 == 0 else 0.03)
				hi = inner + (0.09 if (i + side_index + 1) % 2 == 0 else 0.03)
				return [(lo, hi)]

			face.ashlar_rows(g, inner_courses, inner_spans, rng, SMALL)
		# crenellations: four at the corners and two per side
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
		"""Medium-level parapet: flat panels, coping, wall walk and merlons as boxes."""
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
		"""Merlon: four faces of ashlars over a core and a beveled coping on top."""
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

	# --- door porch --------------------------------------------------------------------------------
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
		# porch sides (they disappear inside the plinth and the wall)
		wall_in = H_WALL0 - 0.14
		for sgn in (1, -1):
			side = Face(Y * sgn, PORCH_HALF, 0.0, 0.0, self.c_porch)
			ux = sorted([Z.cross(Y * sgn).dot(Vector((x_, 0, 0))) for x_ in (-PORCH_FRONT + 0.30, -wall_in)])
			side.umin, side.umax = ux[0], ux[1]
			if lod0:
				side.build(g, rng, WALL)
			else:
				panel_face(g, side, FOOT_Z, PORCH_TOP - 0.30, [], STONE_TILE, quoins=False)
		# door with frame, voussoirs, leaves and ironwork
		frame_opening(g, front, door, rng, 0.55, 'door', detail=True, fill=lod0)
		self.door_leaves(front, door)
		# threshold and step
		axis_box(g, "keep_trim", (-PORCH_FRONT - 0.30, -1.15, FOOT_Z + 1.0), (-PORCH_FRONT + 0.9, 1.15, 0.12), 0.03,
				STONE_TILE, None, rng, 0.003, tint=block_tint(rng, 0.03))
		self.porch_roof()

	def door_leaves(self, front, door) -> None:
		"""Two leaves of vertical planks with an arch, pointed iron straps, rivets and a pull handle."""
		g, rng = self.g, self.rng
		n, t = front.n, front.t
		d = -0.40            # plane of the leaves, inside the opening
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
			# plank joints: dark vertical grooves
			for k in range(1, 4) if self.lod == 0 else ():
				u = sgn * hw * k / 4.0
				top = z1 + math.sqrt(max(hw * hw - u * u, 0.0)) - 0.03
				beam(g, "keep_dark", P(u, z0 + 0.02, d + 0.012), P(u, top, d + 0.012), 0.012, 0.012, 0.0, WOOD_TILE, n)
			# three iron straps from the hinge, with a pointed finial, and their rivets
			for zf in (0.62, 1.55, 2.38):
				end = sgn * 0.20 * hw
				beam(g, "keep_iron", P(u1, zf, d + 0.03), P(end, zf, d + 0.03), 0.12, 0.028, 0.004, WOOD_TILE, n)
				tip = [P(end, zf + 0.06, d + 0.03), P(end, zf - 0.06, d + 0.03), P(end - sgn * 0.17, zf, d + 0.03)]
				g.add("keep_iron", tip, [(0, 0), (1, 0), (0.5, 1)], n)
				if self.lod == 0:
					for k in range(0, 6):
						u = end + (u1 - end) * (0.10 + 0.84 * k / 5.0)
						cone_stud(g, "keep_iron", P(u, zf, d + 0.032), n, t, 0.026, 0.020)
					# hinge pintle: a short cylinder on the edge of the leaf
					hinge = P(u1 - sgn * 0.02, zf, d + 0.03)
					cylinder(g, "keep_iron", (hinge.x, hinge.y), 0.035, zf - 0.10, zf + 0.10, 6, STONE_TILE, 1.0, True)
			# pull handle: an iron ring on a plate
			if self.lod == 0:
				torus(g, "keep_iron", P(sgn * 0.22, 1.25, d + 0.075), t, Z, 0.07, 0.014)
				cone_stud(g, "keep_iron", P(sgn * 0.22, 1.325, d + 0.03), n, t, 0.04, 0.035, 6)
		# bar and lock plate across both leaves
		axis_box(g, "keep_iron", P(-0.30, 1.04, d + 0.03), P(0.30, 1.12, d + 0.065), 0.004, STONE_TILE, None, rng)

	def porch_roof(self) -> None:
		g, rng = self.g, self.rng
		# stone cornice over the porch
		center = Vector((-PORCH_FRONT + 0.50, 0.0, PORCH_TOP - 0.15))
		bevel_box(g, "keep_trim", center, (X, Y, Z), (1.30 + 0.4, 2 * PORCH_HALF + 0.5, 0.30), 0.03, STONE_TILE, None, rng, 0.004)
		# small roof: a shingle slope resting on the wall, with eaves
		zw = PORCH_TOP + 1.35
		xe = -PORCH_FRONT - 0.30     # eave
		xw = -(wall_half(zw) - 0.08)  # wall
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
		# stone gables under the slope
		for sgn in (-1, 1):
			y = sgn * (PORCH_HALF + 0.12)
			tri = [Vector((-PORCH_FRONT + 0.15, y, PORCH_TOP + 0.10)), Vector((xw + 0.07, y, PORCH_TOP + 0.10)),
					Vector((xw + 0.07, y, zw - 0.12))]
			g.add("keep_trim", tri, [(p.x / STONE_TILE, p.z / STONE_TILE) for p in tri], Y * sgn)
			tri2 = [Vector((tri[0].x, y - sgn * 0.14, tri[0].z)), Vector((tri[1].x, y - sgn * 0.14, tri[1].z)),
					Vector((tri[2].x, y - sgn * 0.14, tri[2].z))]
			g.add("keep_trim", tri2, [(p.x / STONE_TILE, p.z / STONE_TILE) for p in tri2], -Y * sgn)

	# --- wooden hoarding ----------------------------------------------------------------------
	def hoarding(self) -> None:
		g, rng = self.g, self.rng
		H = HOARD_H
		bv = 0.012 if self.lod == 0 else 0.0
		turret_cut = H_TOP - TURRET_IN - 0.13
		sides = []
		# each side: (normal, u0, u1) with u along the tangent t = Z x n
		for n_h in (X, Y, -X, -Y):
			t = Z.cross(n_h).normalized()
			lo, hi = -H, H
			# the turret (NE) cuts the E and N sides
			if n_h == X:
				hi = turret_cut
			elif n_h == Y:
				lo = -turret_cut
			sides.append((n_h, t, lo, hi))
		for n_h, t, lo, hi in sides:
			# supports: brackets every ~1.5 m
			count = int((hi - lo) / 1.5) + 1
			us = [lo + 0.60 + (hi - lo - 1.20) * k / max(count - 1, 1) for k in range(count)]
			for u in us:
				base = t * u
				tint = board_tint(rng, 0.06)
				# cantilever joist
				a = base + n_h * (H_TOP - 0.15) + Z * (WALK_Z - 0.28)
				b = base + n_h * (H + 0.12) + Z * (WALK_Z - 0.28)
				beam(g, "keep_wood", a, b, 0.22, 0.24, bv, WOOD_TILE, Z, rng, 0.004, tint)
				# diagonal brace (bracket)
				c = base + n_h * (H_TOP + 0.50) + Z * (WALK_Z - 0.98)
				d = base + n_h * (H - 0.20) + Z * (WALK_Z - 0.36)
				beam(g, "keep_wood", c, d, 0.19, 0.19, bv, WOOD_TILE, Z, rng, 0.004, tint)
				# foot of the brace against the cornice
				axis_pad = base + n_h * (H_TOP + 0.48) + Z * (WALK_Z - 1.02)
				bevel_box(g, "keep_wood", axis_pad, (t, n_h, Z), (0.30, 0.10, 0.22), 0.01, WOOD_TILE, Z, rng, 0.003, tint=tint)
				# outer vertical post, up to the roof's ridge beam
				pa = base + n_h * (H - 0.04) + Z * WALK_Z
				pb = base + n_h * (H - 0.04) + Z * PLATE_Z
				beam(g, "keep_wood", pa, pb, 0.22, 0.22, bv, WOOD_TILE, n_h, rng, 0.004, tint)
				CTX.streak(base + n_h * (H_TOP + 0.4) + Z * (WALK_Z - 1.1), n_h, 0.22, 1.8, 0.2)
			# plank sole plate (the grain runs outward)
			deck_center = n_h * ((H_TOP + H + 0.12) * 0.5 - 0.02) + t * ((lo + hi) * 0.5) + Z * (WALK_Z - 0.04)
			bevel_box(g, "keep_wood", deck_center, (n_h, t, Z), (H + 0.12 - H_TOP + 0.04, hi - lo, 0.09), 0.006, WOOD_TILE, n_h)
			# edge beam and ridge beam
			rail_center = n_h * (H - 0.04) + t * ((lo + hi) * 0.5) + Z * (PLATE_Z - 0.10)
			bevel_box(g, "keep_wood", rail_center, (n_h, t, Z), (0.22, hi - lo, 0.20), 0.012, WOOD_TILE, t)
			base_center = n_h * (H - 0.04) + t * ((lo + hi) * 0.5) + Z * (WALK_Z + 0.10)
			bevel_box(g, "keep_wood", base_center, (n_h, t, Z), (0.20, hi - lo, 0.17), 0.012, WOOD_TILE, t)
			# vertical planks on the outside: a continuous low row and a high frieze, with the strip in between
			# left open (continuous loopholes) so the merlons and the roof can be seen from inside
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
		# end caps that butt against the turret
		for n_h, t, lo, hi in sides:
			if (n_h == X and hi == turret_cut) or (n_h == Y and lo == -turret_cut):
				end_u = hi if n_h == X else lo
				pos = t * end_u
				c = n_h * ((H_TOP + H) * 0.5) + pos + Z * (WALK_Z + 1.35)
				bevel_box(g, "keep_wood", c, (n_h, t, Z), (H - H_TOP + 0.06, 0.10, 2.7), 0.008, WOOD_TILE, Z, rng, 0.003)

	# --- hipped roof ------------------------------------------------------------------------------
	def roof(self) -> None:
		g, rng = self.g, self.rng
		R = ROOF_R
		rise = ROOF_APEX_Z - ROOF_EAVE_Z
		group = 1 if self.lod == 0 else 3
		rows = int(round(math.hypot(R, rise) / 0.2 / group))
		pyramid_roof(g, rng, 0.0, 0.0, R, ROOF_EAVE_Z, ROOF_APEX_Z, rows, 0.045, row_group=group)
		# inner skirt (the underside, wooden) and rafters visible under the eave
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
				# the rafter reaches the ridge; the part that sticks out below the eave is visible
				beam(g, "keep_wood", start + drop - d * 0.20 + Z * -0.02, end_point + drop, 0.10, 0.12, 0.008, WOOD_TILE, Z, rng, 0.003,
						board_tint(rng, 0.06))
			# eave board along the roof's edge
			c = d * (R + 0.02) + Z * (ROOF_EAVE_Z - 0.08)
			bevel_box(g, "keep_wood", c, (d, tang, Z), (0.10, 2 * R + 0.10, 0.24), 0.01, WOOD_TILE, tang, rng, 0.0,
					tint=board_tint(rng, 0.05))
		# hips: a ridge board over each arris
		for sx, sy in CORNER_SIGNS:
			start = Vector((sx * R, sy * R, ROOF_EAVE_Z + 0.02))
			beam(g, "keep_wood", start, apex + Z * 0.04, 0.16, 0.16, 0.012, WOOD_TILE, Z, rng, 0.003, board_tint(rng, 0.05))
		# ceiling of the covered wall walk: boards under the skirt are seen from below through the open frieze
		# ridge cap
		cylinder(g, "keep_wood", (0.0, 0.0), 0.16, ROOF_APEX_Z - 0.10, ROOF_APEX_Z + 0.30, 8, WOOD_TILE, 0.7, False)

	# --- turret ----------------------------------------------------------------------------
	def turret_top(self) -> None:
		g, rng = self.g, self.rng
		x0, x1 = H_TOP - TURRET_IN, H_TOP + TURRET_OUT
		rect = (x0, x1, x0, x1)
		# the upper part of the turret, from the cornice to its top
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
		# crown with an overhang and a pyramidal shingle roof
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

	# --- flagpole and finial --------------------------------------------------------------------------
	def flagpole(self) -> None:
		"""Wooden flagpole over the roof's ridge, with an iron finial. The pennant goes separately
		(build_banners): it is the Estandarte node."""
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
		"""Wooden pole from which each banner hangs, at the edge of the hoarding on each face."""
		g, rng = self.g, self.rng
		for n_h in (X, Y, -X, -Y):
			t = Z.cross(n_h).normalized()
			c = n_h * (HOARD_H + 0.17) + Z * (WALK_Z - 0.14)
			bevel_box(g, "keep_wood", c, (n_h, t, Z), (0.10, 1.9, 0.10), 0.01, WOOD_TILE, t, rng, 0.0, tint=board_tint(rng, 0.04))
			for sgn in (-1, 1):
				bevel_box(g, "keep_iron", c + t * sgn * 0.9, (n_h, t, Z), (0.04, 0.04, 0.10), 0.005, STONE_TILE, None, None, 0.0)

	# --- ground contact --------------------------------------------------------------------
	def foot_rubble(self) -> None:
		"""Fallen stones and half-buried ashlars: grouped at the corners and next to the porch,
		of very different sizes, with half below ground. They tie the keep to the hill."""
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
			# one large block at the corner and four smaller ones around it
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
		# along each side, a few loose, almost buried stones
		for side, n_h in enumerate((X, Y, -X, -Y)):
			t = Z.cross(n_h).normalized()
			for _ in range(3):
				u = rng.uniform(-HB + 1.6, HB - 1.6)
				if side == 2 and abs(u) < PORCH_HALF + 1.4:
					continue
				p = n_h * (HB + rng.uniform(0.18, 0.5)) + t * u
				stone(p.x, p.y, Vector((rng.uniform(0.3, 0.6), rng.uniform(0.25, 0.45), rng.uniform(0.2, 0.35))),
						rng.uniform(0.0, math.pi), rng.uniform(0.10, 0.2))
		# next to the porch: two large stones on each side of the step and a fallen slab in front
		for sgn in (-1, 1):
			stone(-PORCH_FRONT - 0.35, sgn * (PORCH_HALF + 0.55), Vector((0.9, 0.7, 0.5)), rng.uniform(-0.3, 0.3), 0.22)
			stone(-PORCH_FRONT + 0.4, sgn * (PORCH_HALF + 0.95), Vector((0.55, 0.45, 0.34)), rng.uniform(0, 3), 0.1)
		stone(-PORCH_FRONT - 1.15, 0.15, Vector((1.3, 0.8, 0.22)), 0.25, 0.12)

	def foot_skirt(self) -> None:
		"""Skirt of earth and grass that climbs the plinth and sinks into the terrain: the plinth no longer
		ends in a hard line over the courtyard. Vertex colors from earth to grass."""
		g = self.g
		rng = random.Random(777)
		HB = PLINTH_HALF_BOTTOM + PLINTH.q
		loop = []
		for k, (sx, sy) in enumerate(CORNER_SIGNS):
			# each stretch goes from one corner to the next along the side that joins them
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
		# (distance from the plinth, height, color from earth to grass)
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
				# next to the porch the skirt drops so as not to cover the threshold
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
		register_fissures()   # ember cracks (Eldrun)
		return self.g


# ---------------------------------------------------------------------------------------------
# Banners (own node)
# ---------------------------------------------------------------------------------------------
def sway_color(direction):
	"""Direction of a cloth's sway encoded as a color (0..1), already in Godot space (the
	exporter goes from Z-up to Y-up: x, y, z -> x, z, -y). The shader reads it from COLOR.rgb: a
	direction common to the whole piece keeps loose faces from separating when moving."""
	d = Vector(direction).normalized()
	return (d.x * 0.5 + 0.5, d.z * 0.5 + 0.5, -d.y * 0.5 + 0.5)


def build_banners() -> Geo:
	"""Pennant on the flagpole and one banner hanging from the hoarding on each face. They go in their own object
	(Estandarte), outside the merged LOD meshes. The vertex color's alpha is the
	wind weight (0 where the cloth is fixed, 1 at the free tip); fort_keep_cloth.gdshader
	moves the vertices with it and reads faction_color, emblem_index and capture_progress per instance."""
	g = Geo()
	# pennant: 3.5 m long and 1.55 tall at the pole, with a swallowtail; it flies toward -X.

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
	# banners: 1.5 m wide and about 3.4 long, with a point, on each side of the hoarding
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
# Low-resolution collision
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
	# parapet and wall walk body (solid, so that neither the camera nor projectiles get in)
	axis_box(g, "col", (-H_TOP, -H_TOP, CORNICE_Z0 + 0.4), (H_TOP, H_TOP, COPING_TOP), 0.0, tile)
	# hoarding: sole plate, low wall and frieze, on all four sides
	for n_h in (X, Y, -X, -Y):
		t = Z.cross(n_h).normalized()
		half = HOARD_H + 0.05
		deck = n_h * ((H_TOP + HOARD_H + 0.1) * 0.5) + Z * (WALK_Z - 0.09)
		bevel_box(g, "col", deck, (n_h, t, Z), (HOARD_H + 0.1 - H_TOP, 2 * half, 0.18), 0.0, tile)
		wall_c = n_h * (HOARD_H) + Z * ((WALK_Z + WALK_Z + 1.2) * 0.5)
		bevel_box(g, "col", wall_c, (n_h, t, Z), (0.22, 2 * half, 1.2), 0.0, tile)
		plate_c = n_h * (HOARD_H) + Z * (PLATE_Z - 0.3)
		bevel_box(g, "col", plate_c, (n_h, t, Z), (0.22, 2 * half, 0.6), 0.0, tile)
	# roof: closed pyramid
	apex = Vector((0.0, 0.0, ROOF_APEX_Z))
	R = ROOF_R
	rise = ROOF_APEX_Z - ROOF_EAVE_Z
	for d in (X, Y, -X, -Y):
		tang = Z.cross(d)
		a = d * R - tang * R + Z * ROOF_EAVE_Z
		b = d * R + tang * R + Z * ROOF_EAVE_Z
		g.add("col", [a, b, apex], [(0, 0), (1, 0), (0.5, 1)], (d * rise + Z * R))
	# turret and porch
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
# Distant LOD
# ---------------------------------------------------------------------------------------------
def build_lod_far() -> Geo:
	"""Silhouette of about 600 triangles for beyond 250 m: plinth and battered wall, string course, cornice,
	hoarding, roof, turret, porch, openings as dark patches and the flagpole."""
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
	# hoarding
	loft(g, "keep_wood", (-1.0, 1.0, -1.0, 1.0), [(h + 0.1 - 1.0, WALK_Z - 0.6), (HOARD_H - 1.0, WALK_Z - 0.2), (HOARD_H - 1.0, PLATE_Z),
			(h - 1.0, PLATE_Z)], WOOD_TILE, ao=[0.5, 0.9, 1.0, 1.0])
	# roof
	R = ROOF_R
	apex = Vector((0.0, 0.0, ROOF_APEX_Z))
	rise = ROOF_APEX_Z - ROOF_EAVE_Z
	for d in (X, Y, -X, -Y):
		tang = Z.cross(d)
		a = d * R - tang * R + Z * ROOF_EAVE_Z
		b = d * R + tang * R + Z * ROOF_EAVE_Z
		g.add("keep_roof", [a, b, apex], [(0, 0), (2 * R / ROOF_TILE, 0), (R / ROOF_TILE, R / ROOF_TILE * 1.2)], d * rise + Z * R, None, 1.0)
	# turret
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
	# porch and door
	axis_box(g, wall, (-PORCH_FRONT, -PORCH_HALF, FOOT_Z), (-H_WALL0, PORCH_HALF, PORCH_TOP - 0.3), 0.0, tile)
	g.add("keep_dark", [Vector((-PORCH_FRONT - 0.01, -0.95, 0.0)), Vector((-PORCH_FRONT - 0.01, 0.95, 0.0)),
			Vector((-PORCH_FRONT - 0.01, 0.95, 3.0)), Vector((-PORCH_FRONT - 0.01, -0.95, 3.0))], [(0, 0)] * 4, -X)
	axis_box(g, "keep_roof", (-PORCH_FRONT - 0.3, -PORCH_HALF - 0.3, PORCH_TOP), (-H_WALL0 + 0.1, PORCH_HALF + 0.3, PORCH_TOP + 0.25), 0.0, ROOF_TILE)
	# dark openings (windows and main arrow slits)
	for name, n_h in FACE_NORMALS:
		t = Z.cross(n_h).normalized()
		for u, z0, z1, w in ((0.0, 9.6, 11.7, 0.9), (-1.0, 11.9, 13.2, 0.28), (1.0, 11.9, 13.2, 0.28), (0.0, 6.0, 7.5, 0.28)):
			if name == "W" and z0 < 7.0:
				continue
			base = n_h * (wall_half(z0) + 0.09) + t * u
			p = [base - t * (w * 0.5) + Z * z0, base + t * (w * 0.5) + Z * z0, base + t * (w * 0.5) + Z * z1, base - t * (w * 0.5) + Z * z1]
			g.add("keep_dark", p, [(0, 0)] * 4, n_h)
	# flagpole
	cylinder(g, "keep_wood", (0.0, 0.0), 0.11, ROOF_APEX_Z, TOTAL_TOP - 0.1, 5, 3.0, 0.7, False)
	return g


# ---------------------------------------------------------------------------------------------
# Per-vertex finishing: dirt, streaks, shadows under overhangs and embers
# ---------------------------------------------------------------------------------------------
COLOR_GAIN = 1.25   # the shader multiplies the vertex color by this (the value is stored divided)


def _hash3(ix, iy, iz):
	h = (ix * 374761393 + iy * 668265263 + iz * 2147483629) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return (h & 0xFFFF).astype(np.float64) / 65535.0


def vnoise(P, scale, offset=0.0):
	"""3D value noise (0..1), smooth, at the positions P (N, 3)."""
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
	"""Returns (RGB multiplier, alpha) per vertex. P and N are (N, 3); cat is the material category:
	0 stone, 1 mortar, 2 wood, 3 roof and 4 the rest (no finishing)."""
	n = len(P)
	z = P[:, 2]
	n1 = vnoise(P, 0.55, 1.7)
	n2 = vnoise(P, 1.9, 5.3)
	n3 = vnoise(P, 0.23, 9.1)
	wallish = (np.abs(N[:, 2]) < 0.75).astype(np.float64)
	# moisture and dirt rising from the ground
	base = np.clip(1.0 - (z + 0.1) / 2.7, 0.0, 1.0)
	grime = np.clip(base ** 1.3 * np.clip(0.30 + 1.25 * n1 + 0.35 * (n2 - 0.5), 0.0, 1.0), 0.0, 1.0)
	m = 1.0 - 0.36 * grime
	m = m * (1.0 + 0.16 * (n3 - 0.5))
	m = m * (1.0 - 0.28 * np.clip(1.0 - (z + 0.15) / 0.8, 0.0, 1.0))
	# streaks under openings and brackets
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
	# shadow under cornices, string courses and ledges
	for zl, depth, strength in CTX.ledges:
		dz = zl - z
		ok = (dz > 0.0) & (dz < depth)
		m = m * (1.0 - strength * np.where(ok, np.clip(1.0 - dz / depth, 0.0, 1.0) ** 1.6, 0.0) * wallish)
	# ember cracks (Eldrun): vertical bands with an edge broken up by noise
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
# Dump to Blender, materials, export
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
	"""glTF materials: base color only (the game's realm materials replace them with
	fort_keep_surface using the textures from fort_keep/textures/)."""
	mats = {}
	for name in MATERIALS + ["col"]:
		rough, metal = 0.9, 0.0
		if name == "keep_iron":
			rough, metal = 0.45, 0.85
		mats[name] = make_material(name, MATERIAL_COLORS[name], rough, metal, name in ("keep_cloth", "keep_pendant"))
	return mats


def to_object(name, geo, mats, collection, mode="shade", roof_alpha=1.0):
	"""Converts a Geo into a Blender object with one material slot per material used and,
	depending on mode, vertex color: "shade" (tint x occlusion x to_object finishing), "wind" (RGB is the
	sway direction, see sway_color, and the alpha the wind weight, which is stored in the ao list)
	or "none" (collision)."""
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
	"""The distant LOD does not assemble pieces with streaks: only the shadows under overhangs and the cracks."""
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

	# each level registers its own finishing (streaks, shadows under overhangs) and is painted before
	# assembling the next one: this way the medium and distant LODs darken the same as the detailed one
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
	"""Renders of the model alone with Eevee (quick check views, with no textures or vertex
	color: the visual reference is the Godot captures from tools/render/)."""
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
