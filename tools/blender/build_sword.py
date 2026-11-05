"""Models Eldmark's weapon sword from scratch and exports it to glTF (GLB).

Usage (Blender 5.2 headless, from the repo root):

    blender --background --factory-startup --python tools/blender/build_sword.py -- \
        [--out assets/models/weapons] [--tex build/sword/tex] [--only base] [--blend build/sword/x.blend]

Writes `sword_base.glb` and the three per-realm variants (`sword_vardheim.glb`, `sword_solmarch.glb`
and `sword_askarra.glb`). All four share the SAME blade (identical geometry and UVs) and change
the guard, pommel and the leather and metal colors; the blade texture is specific to each realm (ice with
runes, inlaid gold or blackened steel with an emissive crack), because from the game camera
only the blade is readable.

Heroic proportions: the blade is about 10.8 cm wide and 3 cm thick, not the 8.9 x 1.4 of a real
sword, and the tip stays at 0.94 m from the grip (decision 8 of docs/calidad.md: the strike's reach
does not depend on the mesh). The bevel faces that `slab` creates are mapped to the polished-edge
strip of the metal atlas; `check_triangulation` warns if a bevel larger than the piece breaks a
polygon.

Everything is original: no mesh or texture comes from a pack. The textures come from
`tools/blender/sword_textures.py` (numpy, no photos).

Model convention (glTF's, +Y up):
- The origin is the CENTER OF THE GRIP, the point where the hand closes.
- The blade extends along +Y. It measures about 0.94 m from that point, and the whole about 1.1 m with the pommel.
- The width of the blade and the guard runs along X; the thickness, along Z (the flat faces of the blade face
  +Z and -Z, the edge faces +X and -X).
- (In Blender, which is Z up, it is the same rotated: blade along +Z, thickness along Y.)

File structure: a `Sword` node with two empty markers (`TrailBase` and `TrailTip`, the start of the
edge and the tip, for the strike's trail) and two child meshes, `Sword_LOD0` (full detail, about
3000 triangles) and `Sword_LOD1` (about 500, without the fuller or leather wraps in the geometry) to
see it from afar. The client decides which one is shown according to distance (scripts/client/weapon_props.gd).

Each piece is modeled in its own bmesh and dumped at the end into a single mesh per LOD, with three or
four materials (blade, leather, metal and, only on Askarra, ember).
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
# Z where the leather ends at the bottom and the pommel starts (the metal ring covers it).
POMMEL_Z = -0.078

# Blade: (z, half width, half thickness). Heroic proportions: about 10.8 cm wide and 3 cm thick
# at mid-blade (a real sword would be 8.9 and 1.4), a soft widening up to 65 % and an ogival tip.
# The tip stays at TIP_Z = 0.94 (decision 8 of docs/calidad.md: the strike's reach does not change).
BLADE_STATIONS = [
	(0.075, 0.0420, 0.0150), (0.145, 0.0420, 0.0150), (0.195, 0.0428, 0.0138),
	(0.215, 0.0434, 0.0134), (0.235, 0.0439, 0.0132), (0.255, 0.0445, 0.0130), (0.330, 0.0468, 0.0124), (0.420, 0.0498, 0.0117),
	(0.510, 0.0525, 0.0110), (0.600, 0.0540, 0.0103), (0.680, 0.0535, 0.0096),
	(0.750, 0.0512, 0.0088), (0.800, 0.0478, 0.0080), (0.840, 0.0430, 0.0072),
	(0.875, 0.0350, 0.0063), (0.905, 0.0245, 0.0052), (0.925, 0.0135, 0.0040),
]
# The LOD1 ones, by their z (the LOD0 list carries extra stations near the start of the fuller).
BLADE_STATIONS_LOD1_Z = [0.075, 0.145, 0.255, 0.420, 0.600, 0.750, 0.840, 0.905]

# Material indices in the final mesh.
M_BLADE, M_LEATHER, M_METAL, M_EMBER = 0, 1, 2, 3
# Metal atlas zones (u0, v0, u1, v1), with a margin so they do not bleed when filtering.
_BAND = 1.0 / tex.ATLAS_BANDS
REGION_METAL = (0.02, 0.02, 0.98, _BAND - 0.02)
REGION_ACCENT = (0.02, _BAND + 0.02, 0.98, 2.0 * _BAND - 0.02)
# The polished edge: the bevel faces of each piece (created by `slab`) land here and catch the light.
REGION_EDGE = (0.02, 2.0 * _BAND + 0.02, 0.98, 0.98)
# Meters of piece per UV unit, inverted: UV per meter of the box mapping.
BOX_UV_SCALE = 2.2
# Name of the face layer where `slab` marks the bevel ones.
EDGE_TAG = "edge"
# Strength of Askarra's ember emission (the blade's crack and the pommel's): 3 to 4 so that it
# reads from afar and in motion.
EMBER_STRENGTH = 3.5


# --- Geometry utilities ---------------------------------------------------------------------------

def smoothstep(edge0, edge1, x):
	t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
	return t * t * (3.0 - 2.0 * t)


def new_part():
	part = bmesh.new()
	part.loops.layers.uv.verify()
	return part


def finish(part, material, smooth=False, region=None, recalc=True, edge_region=None):
	"""Leaves the piece ready: normals outward, material, shading and (if requested) box UVs.

	With `edge_region`, the bevel faces marked by `slab` go to that zone of the atlas (the polished edge).
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
	"""Box mapping: each face is projected along its dominant axis, with constant pixel density.

	Each piece's UVs start at the corner of its atlas zone (`region`), so they never
	invade the neighboring zone. The metal is repeating noise, so it needs no separate islands.
	Faces marked as bevel (`edge_region` given) are mapped to the polished-edge zone.
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
	"""Copies a piece (vertices, faces, material, shading and UVs) to the common mesh."""
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
	"""Piece of revolution around Z. `profile` is a list of (radius, z) from bottom to top."""
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
	"""Prism of the `outline` silhouette (list of (x, z)) between the planes y = y0 and y = y1.

	With `bevel` > 0 the two cap contours are beveled: this way the silhouette gets a polished
	edge that catches the light, which is what makes a flat piece look forged.
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
	"""Symmetric silhouette from its right half, from bottom-center to top-center."""
	outline = list(half)
	for x, z in reversed(half[1:-1]):
		outline.append((-x, z))
	return outline


def ellipse_outline(cx, cz, rx, rz, count=10):
	return [(cx + rx * math.cos(math.tau * i / count), cz + rz * math.sin(math.tau * i / count))
			for i in range(count)]


# --- The blade (identical in all variants) --------------------------------------------------------

def blade_section(w, ht, edge, fuller, groove_scale=1.0):
	"""18-point ring of the cross-section: edge bevel, major bevel, flat face and fuller.

	Returns [(x, y, u)] starting at the right edge, going over the top to the left and back
	along the bottom. `u` is the position across the width (x / w, from 0 to 1) that the texture uses; the fractions
	come from sword_textures so the painted highlight lands exactly on each bevel.
	"""
	e = edge
	bevel_x = 1.0 - (1.0 - tex.S_BEVEL) * e
	bevel_y = 0.95 - 0.65 * e
	shoulder_x = 0.93 - (0.93 - tex.S_SHOULDER) * e
	# The fuller starts and ends in an ogive: its width (rim and floor) grows with `groove_scale`, just like in the
	# texture (sword_textures.fuller_width_scale).
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
	"""Simple hexagonal cross-section of the distant blade."""
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


# --- Leather grip ---------------------------------------------------------------------------------

def build_grip(detail):
	"""Spiral leather: the ridge of each wrap is modeled, not just painted."""
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
		# A little thicker in the middle and open at the base, like a real grip.
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
			# Unwrapped v: rises one unit per wrap, also when going around the cylinder.
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
	"""The two metal rings that close the leather (under the guard and over the pommel)."""
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
	"""The guard body the blade passes through: thicker than the wings, with a chamfer.

	It is wider than the heroic blade (10.8 cm) to cover the ricasso on both sides.
	"""
	outline = [(-0.040, 0.064), (0.040, 0.064), (0.054, 0.078), (0.054, 0.108), (0.040, 0.122),
			(-0.040, 0.122), (-0.054, 0.108), (-0.054, 0.078)]
	part = slab(outline, -0.0205, 0.0205, bevel=0.0045 if detail == 0 else 0.0, segments=1)
	return finish(part, M_METAL, smooth=False, region=REGION_METAL, edge_region=REGION_EDGE)


def guard_slab(outline, detail, region=REGION_METAL, half=0.0125, bevel=0.0045, taper=None):
	"""Guard piece with volume: a plate with the large bevel (flattened diamond section, not a
	prism of constant thickness) and, with `taper = (x_ini, x_fin, factor)`, thinning toward the tips: the
	thickness drops to `factor` between |x| = x_ini and x_fin (from about 2.5 cm at the center to 1.2 cm at the tip)."""
	part = slab(outline, -half, half, bevel=bevel if detail == 0 else 0.0, segments=1)
	if taper is not None:
		x0, x1, factor = taper
		for vert in part.verts:
			t = smoothstep(x0, x1, abs(vert.co.x))
			vert.co.y *= 1.0 - (1.0 - factor) * t
	return finish(part, M_METAL, smooth=False, region=region, edge_region=REGION_EDGE)


def gem(cx, cz, radius, y0, y1, sides=6):
	"""Stone or rivet: a small prism that protrudes from the piece, in the accent color."""
	outline = ellipse_outline(cx, cz, radius, radius, sides)
	part = slab(outline, y0, y1, bevel=radius * 0.28, segments=1)
	return finish(part, M_METAL, smooth=False, region=REGION_ACCENT)


def facet_gem(cx, cz, radius, height, sides, base, side=1.0):
	"""Faceted stone: a dome of `sides` faces that protrudes from the piece toward +Y (`side` = 1) or
	toward -Y (`side` = -1), resting on the plane y = base. Uses the accent color."""
	profile = [(radius, 0.0), (radius * 0.97, height * 0.30), (radius * 0.62, height * 0.78),
			(0.0, height)]
	part = lathe(profile, sides, caps=True)
	for vert in part.verts:
		x, y, z = vert.co
		vert.co = Vector((cx + x, side * (base + z), cz + y))
	return finish(part, M_METAL, smooth=False, region=REGION_ACCENT)


def ember_bar(p0, p1, width, y0, y1):
	"""A section of emissive crack: a thin rectangle from `p0` to `p1` (x, z) between the planes y0 and y1."""
	dx, dz = p1[0] - p0[0], p1[1] - p0[1]
	length = math.hypot(dx, dz)
	nx, nz = -dz / length * width * 0.5, dx / length * width * 0.5
	outline = [(p0[0] + nx, p0[1] + nz), (p1[0] + nx, p1[1] + nz), (p1[0] - nx, p1[1] - nz),
			(p0[0] - nx, p0[1] - nz)]
	return finish(slab(outline, y0, y1), M_EMBER, smooth=False)


# --- Guards by variant ----------------------------------------------------------------------------

def swept_guard(widths, rise, x_end, tip_drop, power=2.0, base_z=0.092):
	"""Right half of a guard with wings that rise (rise > 0) or drop (rise < 0) toward the tip.

	`widths` = [(x, thickness)] along the wing; the midline is base_z + rise * (x / x_end)^power.
	"""
	def spine(x):
		return base_z + rise * (x / x_end) ** power

	lower = [(x, spine(x) - t * 0.5) for x, t in widths]
	upper = [(x, spine(x) + t * 0.5) for x, t in widths]
	tip = (x_end + 0.016, spine(x_end) + tip_drop)
	return lower + [tip] + list(reversed(upper))


def guard_base(detail):
	"""Guard with wings that curve toward the tip and end in a bulb."""
	widths = [(0.0, 0.052), (0.03, 0.044), (0.07, 0.036), (0.11, 0.032), (0.14, 0.032),
			(0.158, 0.040), (0.172, 0.048), (0.184, 0.042)]
	half = swept_guard(widths, 0.070, 0.184, 0.002)
	parts = [guard_slab(mirrored(half), detail, half=0.0150, bevel=0.0085, taper=(0.04, 0.17, 0.50))]
	parts.append(gem(0.0, 0.092, 0.013, 0.0205, 0.0250))
	parts.append(gem(0.0, 0.092, 0.013, -0.0250, -0.0205))
	bulb_z = 0.092 + 0.070 * (0.172 / 0.184) ** 2.0
	for side in (-1.0, 1.0):
		# A gold rivet on each bulb, on both faces.
		parts.append(gem(side * 0.172, bulb_z, 0.0085, 0.0060, 0.0105))
		parts.append(gem(side * 0.172, bulb_z, 0.0085, -0.0105, -0.0060))
	return parts


def fang_half(center_z=0.092, bar_x=0.095, radius=0.115, sweep_deg=84.0, base_width=0.044, steps=16):
	"""Right half of a fang guard: a straight bar that curves toward the blade's tip.

	The fang is a circular arc (center above the bar) whose thickness tapers to the tip.
	It goes from bottom-center to top-center, like the rest of the halves.
	"""
	outer, inner = [], []
	for index in range(steps + 1):
		t = index / steps
		angle = math.radians(sweep_deg * t)
		x = bar_x + radius * math.sin(angle)
		z = center_z + radius * (1.0 - math.cos(angle))
		width = base_width * (1.0 - t) ** 0.85 + 0.009
		# The tangent is (cos, sin); the normal toward the arc's center, (-sin, cos).
		nx, nz = -math.sin(angle), math.cos(angle)
		outer.append((x - nx * width * 0.5, z - nz * width * 0.5))
		inner.append((x + nx * width * 0.5, z + nz * width * 0.5))
	bar_low = center_z - 0.027
	bar_high = center_z + 0.027
	return [(0.0, bar_low), (bar_x * 0.55, bar_low)] + outer + list(reversed(inner)) \
			+ [(bar_x * 0.55, bar_high), (0.0, bar_high)]


def guard_vardheim(detail):
	"""Wolf guard: a sturdy bar that ends in two fangs curved toward the tip."""
	half = fang_half()
	parts = [guard_slab(mirrored(half), detail, half=0.0150, bevel=0.0040, taper=(0.07, 0.19, 0.50))]
	for side in (-1.0, 1.0):
		# An ice stone on each arm of the bar, on both faces.
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
	"""Half-sun silhouette: rays only in the upper half and the lower one solid.

	`rays` = [(angle from 0 to 180, length, half-angle of the base)]. The rays at 0 and 180 degrees are the
	horizontal ones (the quillons). The lower half is a half ellipse of width `lower_width` (by default
	`hub`) and depth `lower_depth`.
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
	# From the base of the last ray (180 + half-angle) to that of the first (360 - half-angle), along the bottom.
	last_angle, _, last_half = rays[-1]
	first_angle, _, first_half = rays[0]
	start, end = last_angle + last_half, 360.0 + first_angle - first_half
	steps = max(int((end - start) // step), 4)
	for s in range(1, steps):
		a = math.radians(start + (end - start) * s / steps)
		outline.append((lower_width * math.cos(a), center_z + lower_depth * math.sin(a)))
	return outline


def guard_solmarch(detail):
	"""Half-sun guard, the split sun of the emblem: thick, short rays only on the blade side (the two
	long horizontal ones serve as quillons) and the lower half solid (no ray comes out toward the hand).
	No rays next to the ricasso: at needle size they vanish at 3 m and the ones stuck to the blade looked like they floated."""
	rays = [(0.0, 0.160, 16.0), (34.0, 0.106, 15.0), (146.0, 0.106, 15.0), (180.0, 0.160, 16.0)]
	outline = half_sun_outline(0.092, 0.064, rays, 0.046, lower_width=0.070)
	parts = [guard_slab(outline, detail, half=0.0145, bevel=0.0080, taper=(0.06, 0.16, 0.55))]
	# The sun stone, warm and faceted, at the center of both faces.
	parts.append(facet_gem(0.0, 0.092, 0.022, 0.0120, 8, 0.0205, 1.0))
	parts.append(facet_gem(0.0, 0.092, 0.022, 0.0120, 8, 0.0205, -1.0))
	return parts


def guard_askarra(detail):
	"""Forge guard: a solid bronze bar with the ends cut by chisel blows, the upper one
	taller, and a soot-black rivet on each side. The blade's crack runs down through the guard body."""
	half = [(0.0, 0.062), (0.100, 0.062), (0.168, 0.058), (0.206, 0.078), (0.208, 0.112),
			(0.186, 0.140), (0.158, 0.124), (0.100, 0.116), (0.0, 0.116)]
	parts = [guard_slab(mirrored(half), detail, half=0.0160, bevel=0.0090, taper=(0.07, 0.20, 0.50))]
	for side in (-1.0, 1.0):
		parts.append(facet_gem(side * 0.150, 0.090, 0.0095, 0.0050, 6, 0.0100, 1.0))
		parts.append(facet_gem(side * 0.150, 0.090, 0.0095, 0.0050, 6, 0.0100, -1.0))
	if detail == 0:
		# The blade's crack continues across both faces of the guard body (the piece that hugs the ricasso):
		# it runs down in a zigzag from the top and drops two short branches to the sides.
		trunk = [(0.003, 0.121), (-0.010, 0.109), (0.006, 0.097), (-0.006, 0.085), (0.002, 0.072)]
		branches = [[(0.006, 0.097), (0.026, 0.092), (0.042, 0.099)], [(-0.010, 0.109), (-0.030, 0.104), (-0.044, 0.111)]]
		for sign in (1.0, -1.0):
			y0, y1 = (0.0200, 0.0226) if sign > 0 else (-0.0226, -0.0200)
			for chain, width in [(trunk, 0.0062)] + [(b, 0.0042) for b in branches]:
				for p0, p1 in zip(chain, chain[1:]):
					parts.append(ember_bar(p0, p1, width, y0, y1))
	return parts


# --- Pommels by variant ---------------------------------------------------------------------------

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
	"""Silhouette (x, z) from points (x, d) in centimeters, with `d` outward from the leather ring
	(in the model it is z = POMMEL_Z - d)."""
	return [(x * 0.01 * scale, POMMEL_Z - d * 0.01 * scale) for x, d in points]


# Front-facing wolf head, with the muzzle pointing out of the sword (cm; x across, z up, centered on
# the pommel's axis; right half from bottom to top, the other is mirrored). What makes it a wolf and not a cat or an owl is the
# SILHOUETTE: a long, narrow muzzle ending in a nose, cheeks with spiky fur and two tall, separated ears.
# There is no disc behind it any more (a circle with two eyes is an owl): the head itself is the piece.
WOLF_SILHOUETTE_HALF = [(0.0, -3.10), (0.50, -3.05), (0.68, -2.55), (0.78, -1.75), (1.20, -1.00), (2.05, -0.80),
		(1.70, -0.15), (2.30, 0.55), (1.80, 1.15), (2.55, 3.30), (1.10, 2.05), (0.0, 1.55)]
# Slit eye (narrow triangle, slanted outward and up), nose and brows, in the same system.
WOLF_EYE_CM = [(0.28, 0.30), (1.15, 0.92), (1.00, 0.34)]
WOLF_NOSE_CM = [(-0.30, -2.55), (0.30, -2.55), (0.18, -3.00), (-0.18, -3.00)]
WOLF_BROW_CM = [(0.20, 0.98), (1.30, 1.38), (1.30, 1.18), (0.20, 0.78)]
# Half the head's thickness (m) and scale over the measurements above.
WOLF_HALF_THICKNESS = 0.0150
WOLF_HEAD_SCALE = 1.0
WOLF_CENTER_D = 0.050


def wheel(cz, profile, segments):
	"""Wheel with its axis along Y (facing the camera from the front), centered at z = `cz`.

	`profile` is [(radius, axial position)] from one face to the other: it is modeled as a piece of revolution
	around Z and laid down so the axis ends up on Y.
	"""
	part = lathe(profile, segments, caps=True)
	for vert in part.verts:
		x, y, z = vert.co
		vert.co = Vector((x, z, cz + y))
	return finish(part, M_METAL, smooth=False, region=REGION_METAL)


def pommel_vardheim(detail):
	"""Volumetric wolf-head pommel: the head silhouette (long muzzle, spiky cheeks, tall ears)
	extruded to 3 cm thick with a polished edge, slit eyes and brows in the accent metal (ice) and the nose in
	accent. From the front it reads as a wolf; from the side, a wedge. No disc behind it."""
	center = POMMEL_Z - WOLF_CENTER_D
	k = 0.01 * WOLF_HEAD_SCALE
	head = mirrored([(x * k, center + z * k) for x, z in WOLF_SILHOUETTE_HALF])
	stem = lathe([(0.0165, POMMEL_Z + 0.003), (0.0165, center + 0.0050)], 12 if detail == 0 else 8, scale_y=0.86)
	parts = [finish(stem, M_METAL, smooth=False, region=REGION_METAL)]
	parts.append(finish(slab(head, -WOLF_HALF_THICKNESS, WOLF_HALF_THICKNESS,
			bevel=0.0035 if detail == 0 else 0.0), M_METAL, smooth=False, region=REGION_METAL,
			edge_region=REGION_EDGE))
	if detail == 1:
		return parts
	for sign in (1.0, -1.0):
		y0, y1 = (WOLF_HALF_THICKNESS, WOLF_HALF_THICKNESS + 0.0045) if sign > 0 				else (-WOLF_HALF_THICKNESS - 0.0045, -WOLF_HALF_THICKNESS)
		for eye_side in (-1.0, 1.0):
			eye = [(eye_side * x * k, center + z * k) for x, z in WOLF_EYE_CM]
			if eye_side < 0:
				eye = list(reversed(eye))
			parts.append(finish(slab(eye, y0, y1), M_METAL, smooth=False, region=REGION_ACCENT))
			brow = [(eye_side * x * k, center + z * k) for x, z in WOLF_BROW_CM]
			if eye_side < 0:
				brow = list(reversed(brow))
			parts.append(finish(slab(brow, y0, y1 - 0.0010), M_METAL, smooth=False, region=REGION_EDGE))
		nose = [(x * k, center + z * k) for x, z in WOLF_NOSE_CM]
		parts.append(finish(slab(nose, y0, y1), M_METAL, smooth=False, region=REGION_ACCENT))
	return parts


def pommel_solmarch(detail):
	"""Sun pommel: eight rays alternating long and short and a warm, faceted sun stone."""
	rays = [(i * 45.0, 0.060 if i % 2 == 0 else 0.042, 9.0) for i in range(8)]
	center = POMMEL_Z - 0.052
	outline = sun_outline(center, rays, 0.034)
	disc = slab(outline, -0.0145, 0.0145, bevel=0.0040 if detail == 0 else 0.0, segments=1)
	parts = [finish(disc, M_METAL, smooth=False, region=REGION_METAL, edge_region=REGION_EDGE)]
	parts.append(facet_gem(0.0, center, 0.0200, 0.0110, 8, 0.0145, 1.0))
	parts.append(facet_gem(0.0, center, 0.0200, 0.0110, 8, 0.0145, -1.0))
	return parts


# Double-horned anvil pommel, compact and symmetric (cm; d = outward from the leather): working
# face stuck to the leather, a horn on each side, waist and foot. It is crossed by an ember crack.
ANVIL_HALF = [
	(0.0, -0.4), (2.4, -0.4), (2.4, 1.0), (3.2, 1.0), (6.4, 1.5), (7.5, 2.1), (6.8, 2.9), (3.8, 3.5),
	(2.7, 4.5), (2.4, 6.2), (4.2, 7.0), (4.2, 8.4), (0.0, 8.4),
]
# The crack (x, d, in cm) that runs across both faces of the anvil, from top left to bottom
# right, and a short branch.
ANVIL_CRACK = [(-4.6, 1.5), (-2.6, 2.4), (-1.5, 3.4), (-0.2, 3.9), (0.8, 5.2), (0.2, 6.1), (1.9, 7.2),
		(3.2, 8.3)]
ANVIL_BRANCH = [(-0.2, 3.9), (1.6, 3.2), (2.4, 2.1)]


def pommel_askarra(detail):
	"""Bronze anvil pommel, symmetric, with a live ember crack crossing it."""
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


# --- Assembly by variant --------------------------------------------------------------------------

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
	"""Warns if any polygon is triangulated badly (the area of the triangles must equal the polygon's).

	It happens with a bevel larger than the piece's size (a very thin tip whose contour crosses itself) and shows
	up as a face that fills a hole that is not its own.
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
	"""glTF PBR material: albedo + (roughness in G, metallic in B) from a single texture.

	With `emit_path`, the emission texture (the flaming crack of Askarra's blade) with the strength
	`emit_strength`, which glTF stores as KHR_materials_emissive_strength.
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


# --- Export ---------------------------------------------------------------------------------------

def triangle_count(mesh):
	return sum(len(poly.vertices) - 2 for poly in mesh.polygons)


def build_variant(variant, out_dir, paths, blend_path=""):
	bpy.ops.wm.read_factory_settings(use_empty=True)
	materials = make_materials(variant, paths)
	root = bpy.data.objects.new("Sword", None)
	bpy.context.scene.collection.objects.link(root)
	# Points for the strike's trail (ART-09): the start of the edge and the tip.
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
