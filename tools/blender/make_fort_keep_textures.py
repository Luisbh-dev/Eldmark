#!/usr/bin/env python3
"""Generates the fort keep's own textures (ART-57) with numpy and PIL: a painted look.

No AI and no photos. The target style is that of the Quaternius family (docs/art.md): almost
smooth surfaces with soft color washes, brush marks, fine cracks with a light lip, few
pores and no high-frequency noise. The value and tone of each ashlar, the joint occlusion and the dirt at the
foot come from the mesh's vertex color (build_fort_keep.py), not from
these textures, which only supply the common "paint" and the soft relief.

Output, in assets/models/environment/custom/fort_keep/textures/ (all PNG, so that
tools/assets/apply_texture_import_presets.gd sets VRAM compression, mipmaps and normal map):

    keep_stone_albedo.png / keep_stone_normal.png   face ashlar. Alpha = crack mask
                                                    (the embers of Eldrun glow through there)
    keep_trim_albedo.png  / keep_trim_normal.png    dressed stone: lighter, smoother
    keep_wall_albedo.png  / keep_wall_normal.png    already-cut ashlar masonry panel (medium LOD)
    keep_wood_albedo.png  / keep_wood_normal.png    painted boards with grain (hoarding, door)
    keep_shingle_albedo.png / keep_shingle_normal.png  roof shingles
    keep_pennant_atlas.png                           pennant: 4 stacked emblems (1024 x 2048)
    keep_pendant_atlas.png                           vertical banner: 4 emblems in a row (1536 x 1024)
    keep_textures.txt                                mean luminances (for realm_surface)

Usage, from the repo root and before build_fort_keep.py:

    python tools/blender/make_fort_keep_textures.py

It is deterministic (fixed seeds). Normals in the OpenGL convention (green up), the one Godot and
glTF use. The emblems are read from assets/emblems/*.svg (polygons, lines and a semicircle).
"""

import math
import os
import re

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT_DIR = os.path.join(ROOT, "assets", "models", "environment", "custom", "fort_keep", "textures")
EMBLEM_DIR = os.path.join(ROOT, "assets", "emblems")
SIZE = 1024

# Order of the emblems in the banner atlases (the index the fort controller provides).
EMBLEMS = ["vardheim", "solmarch", "askarra", "huecos"]


# ---------------------------------------------------------------------------------------------
# Numeric utilities
# ---------------------------------------------------------------------------------------------
def fft_noise(n: int, beta: float, seed: int) -> np.ndarray:
	"""Periodic noise with a 1/f^beta spectrum, normalized to mean 0 and deviation 1."""
	rng = np.random.default_rng(seed)
	spectrum = np.fft.fft2(rng.standard_normal((n, n)))
	fx = np.fft.fftfreq(n)[:, None]
	fy = np.fft.fftfreq(n)[None, :]
	f = np.sqrt(fx * fx + fy * fy)
	f[0, 0] = 1.0
	spectrum *= 1.0 / f ** (beta / 2.0)
	spectrum[0, 0] = 0.0
	out = np.real(np.fft.ifft2(spectrum))
	return (out - out.mean()) / out.std()


def blur(img: np.ndarray, radius: float) -> np.ndarray:
	"""Periodic Gaussian blur via FFT."""
	fx = np.fft.fftfreq(img.shape[0])[:, None]
	fy = np.fft.fftfreq(img.shape[1])[None, :]
	kernel = np.exp(-2.0 * (np.pi ** 2) * (radius ** 2) * (fx * fx + fy * fy))
	return np.real(np.fft.ifft2(np.fft.fft2(img) * kernel))


def smoothstep(a: float, b: float, x: np.ndarray) -> np.ndarray:
	t = np.clip((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


def normal_from_height(h: np.ndarray, strength: float) -> np.ndarray:
	"""OpenGL normal map (X to the right, Y toward the top of the image) from a height."""
	dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5
	d_row = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5
	nx = -dx * strength
	ny = d_row * strength
	nz = np.ones_like(h)
	length = np.sqrt(nx * nx + ny * ny + nz * nz)
	out = np.stack([nx / length, ny / length, nz / length], axis=-1)
	return ((out * 0.5 + 0.5) * 255.0).clip(0, 255).astype(np.uint8)


def save_png(path: str, array: np.ndarray) -> None:
	mode = "RGBA" if array.shape[-1] == 4 else "RGB"
	Image.fromarray(array, mode).save(path, optimize=True)


def luminance(rgb: np.ndarray) -> float:
	f = rgb[..., :3].astype(np.float32) / 255.0
	return float((0.299 * f[..., 0] + 0.587 * f[..., 1] + 0.114 * f[..., 2]).mean())


def add_wrapped(canvas: np.ndarray, patch: np.ndarray, cx: int, cy: int) -> None:
	"""Adds a patch centered at (cx, cy), wrapping around the edges."""
	ph, pw = patch.shape
	ys = (np.arange(ph) + cy - ph // 2) % canvas.shape[0]
	xs = (np.arange(pw) + cx - pw // 2) % canvas.shape[1]
	canvas[np.ix_(ys, xs)] += patch


def dabs(n: int, count: int, size: tuple, angle: float, spread: float, amp: tuple, seed: int) -> np.ndarray:
	"""Soft elliptical brush strokes (positive and negative), oriented toward `angle`."""
	rng = np.random.default_rng(seed)
	canvas = np.zeros((n, n), dtype=np.float32)
	for _ in range(count):
		rx = rng.uniform(*size)
		ry = rx * rng.uniform(0.25, 0.6)
		a = angle + rng.normal(0.0, spread)
		half = int(max(rx, ry) * 2.2)
		yy, xx = np.mgrid[-half:half + 1, -half:half + 1].astype(np.float32)
		u = xx * math.cos(a) + yy * math.sin(a)
		v = -xx * math.sin(a) + yy * math.cos(a)
		patch = np.exp(-((u / rx) ** 2 + (v / ry) ** 2)) * rng.uniform(*amp) * rng.choice([-1.0, 1.0])
		add_wrapped(canvas, patch.astype(np.float32), int(rng.integers(0, n)), int(rng.integers(0, n)))
	return canvas


def cracks(n: int, count: int, length: tuple, seed: int, branch: float = 0.5) -> np.ndarray:
	"""Fine cracks: random walks with some branching. Returns the stroke (0..1)."""
	rng = np.random.default_rng(seed)
	canvas = np.zeros((n, n), dtype=np.float32)

	def walk(x: float, y: float, heading: float, steps: int, width: float, depth: int) -> None:
		for i in range(steps):
			heading += rng.normal(0.0, 0.22)
			x += math.cos(heading) * 1.4
			y += math.sin(heading) * 1.4
			taper = 1.0 - 0.6 * (i / max(steps, 1))
			r = max(0.55, width * taper)
			xi, yi = int(x) % n, int(y) % n
			for dy in (-1, 0, 1):
				for dx in (-1, 0, 1):
					d = math.hypot(dx, dy)
					if d <= r + 0.4:
						canvas[(yi + dy) % n, (xi + dx) % n] = max(canvas[(yi + dy) % n, (xi + dx) % n], 1.0 - 0.35 * d / (r + 0.4))
			if depth < 2 and rng.random() < branch / 40.0:
				walk(x, y, heading + rng.choice([-1, 1]) * rng.uniform(0.5, 1.0), int(steps * 0.45), width * 0.7, depth + 1)

	for _ in range(count):
		walk(rng.uniform(0, n), rng.uniform(0, n), rng.uniform(0, 2 * math.pi), int(rng.uniform(*length)), 1.15, 0)
	return canvas


def pits(n: int, count: int, radius: tuple, seed: int) -> tuple:
	"""Small pits. Returns (pit 0..1, light lip 0..1)."""
	rng = np.random.default_rng(seed)
	hole = np.zeros((n, n), dtype=np.float32)
	for _ in range(count):
		r = rng.uniform(*radius)
		half = int(r * 2.5) + 2
		yy, xx = np.mgrid[-half:half + 1, -half:half + 1].astype(np.float32)
		patch = np.exp(-((xx * xx + yy * yy) / (r * r)) ** 1.5)
		add_wrapped(hole, patch.astype(np.float32) * rng.uniform(0.5, 1.0), int(rng.integers(0, n)), int(rng.integers(0, n)))
	hole = np.clip(hole, 0.0, 1.0)
	lip = np.clip(blur(hole, 1.4) - hole * 0.9, 0.0, 1.0)
	return hole, lip


# ---------------------------------------------------------------------------------------------
# Painted stone
# ---------------------------------------------------------------------------------------------
def painted_stone(seed: int, base: float, wash: float, crack_count: int, pit_count: int,
		warm: float, glaze: float = 1.0) -> tuple:
	"""Painted stone. Returns (RGBA albedo, height). The alpha is the crack mask."""
	n = SIZE
	a = fft_noise(n, 3.2, seed)
	b = fft_noise(n, 2.4, seed + 1)
	c = fft_noise(n, 1.7, seed + 2)
	patch_a = smoothstep(-0.25, 0.45, a)
	patch_b = smoothstep(-0.1, 0.6, b)
	lum = base + wash * (0.030 * (patch_a - 0.5) + 0.022 * (patch_b - 0.5) + 0.006 * c)

	# brush strokes: oval, slightly tilted, of two sizes
	big = blur(dabs(n, 420, (26.0, 70.0), math.radians(24.0), 0.45, (0.004, 0.014), seed + 3), 2.0)
	small = blur(dabs(n, 700, (9.0, 24.0), math.radians(28.0), 0.55, (0.004, 0.012), seed + 4), 0.8)
	lum = lum + wash * (big + small) * glaze

	# fine cracks: dark with an offset light lip
	crack = cracks(n, crack_count, (50.0, 170.0), seed + 5)
	crack_core = np.clip(blur(crack, 0.55) * 1.35, 0.0, 1.0)
	lip = np.clip(np.roll(crack, (2, 2), axis=(0, 1)) - crack, 0.0, 1.0)
	lum = lum - 0.095 * crack_core + 0.030 * blur(lip, 0.5)

	# few, soft pits
	hole, hole_lip = pits(n, pit_count, (2.4, 6.5), seed + 6)
	lum = lum - 0.070 * blur(hole, 0.6) + 0.030 * hole_lip

	# very loose light scuffs
	scuff = np.clip(fft_noise(n, 1.4, seed + 7) - 1.35, 0.0, None)
	lum = lum + 0.020 * blur(scuff, 0.8)
	lum = np.clip(lum, 0.05, 0.95)

	tint = fft_noise(n, 3.0, seed + 8)
	r = lum * (1.0 + warm * tint * 0.020 + 0.010)
	g = lum * (1.0 + warm * tint * 0.004)
	bl = lum * (1.0 - warm * tint * 0.020 - 0.010)
	alpha = np.clip(crack_core, 0.0, 1.0)
	albedo = np.stack([r, g, bl, np.ones_like(lum)], axis=-1).clip(0, 1)
	albedo[..., 3] = alpha
	height = (0.55 * (patch_a - 0.5) + 0.30 * (patch_b - 0.5) + 0.10 * c * 0.5 + 6.0 * big + 5.0 * small
			- 1.30 * crack_core - 0.9 * blur(hole, 0.6))
	return (albedo * 255.0).astype(np.uint8), height


def trim_stone(seed: int) -> tuple:
	"""Dressed stone: lighter and almost smooth, with fine horizontal mallet lines."""
	albedo, height = painted_stone(seed, base=0.60, wash=0.7, crack_count=3, pit_count=14, warm=0.4, glaze=0.8)
	rows = np.sin(np.arange(SIZE) * 0.62)[:, None] * np.ones((1, SIZE))
	rough = blur(fft_noise(SIZE, 1.0, seed + 40), 0.8)
	f = albedo.astype(np.float32)
	f[..., :3] *= (1.0 + 0.012 * rows + 0.006 * rough)[..., None]
	albedo = f.clip(0, 255).astype(np.uint8)
	height = height * 0.55 + rows * 0.10
	return albedo, height


# ---------------------------------------------------------------------------------------------
# Cut-ashlar masonry panel (medium LOD)
# ---------------------------------------------------------------------------------------------
def ashlar_tile(seed: int, courses: int = 7, tile_m: float = 3.2) -> tuple:
	"""Panel of painted ashlars for the medium LOD: courses, dark joints, light bevel and a different value
	per ashlar. A course measures tile_m / courses (0.457 m with the default values)."""
	n = SIZE
	rng = np.random.default_rng(seed)
	stone_albedo, stone_height = painted_stone(seed + 100, base=0.50, wash=1.0, crack_count=6, pit_count=24, warm=0.5)
	sa = stone_albedo[..., :3].astype(np.float32) / 255.0
	lum = np.zeros((n, n, 3), dtype=np.float32)
	height = np.zeros((n, n), dtype=np.float32)
	ao = np.ones((n, n), dtype=np.float32)
	row_h = n / courses
	joint = 7.0
	yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
	for row in range(courses):
		y0 = row * row_h
		y1 = y0 + row_h
		# ashlars of the course: widths between 0.7 and 1.5 m, laid out so that they close the tile's width
		widths = []
		total = 0.0
		while total < n - 1:
			w = rng.uniform(0.7, 1.5) / tile_m * n
			if n - total - w < 0.5 / tile_m * n:
				w = n - total
			widths.append(w)
			total += w
		shift = rng.uniform(0, n)
		x = shift
		for w in widths:
			x0, x1 = x, x + w
			x = x1
			tint = 1.0 + rng.normal(0.0, 0.045)
			warm = rng.normal(0.0, 0.018)
			mask_x = ((xx - x0) % n) < w
			inner = mask_x & (yy >= y0) & (yy < y1)
			# distances to the ashlar's edge (for joint, bevel and occlusion)
			dx = np.minimum((xx - x0) % n, w - ((xx - x0) % n))
			dy = np.minimum(yy - y0, y1 - yy)
			d = np.minimum(dx, dy)
			d = np.where(inner, d, 0.0)
			core = inner & (d > joint * 0.5)
			bevel = smoothstep(joint * 0.5, joint * 0.5 + 9.0, d)
			rim = np.exp(-((d - (joint * 0.5 + 5.0)) / 4.0) ** 2)
			col = sa * tint
			col[..., 0] *= 1.0 + warm
			col[..., 2] *= 1.0 - warm
			col = col * (1.0 + 0.10 * rim[..., None])
			# inside the ashlar, lighter at the top and darker at the bottom (brush stroke)
			grad = 1.0 + 0.045 * ((yy - y0) / row_h * -2.0 + 1.0)
			col = col * grad[..., None]
			lum = np.where(core[..., None], col, lum)
			height = np.where(core, 1.0 * bevel + stone_height * 0.15, height)
			ao = np.where(core, 0.55 + 0.45 * smoothstep(joint * 0.5, joint * 0.5 + 26.0, d), ao)
	# joints (gaps): mortar color
	mortar = np.array([0.20, 0.19, 0.17], dtype=np.float32)
	filled = (lum.sum(axis=-1) > 0)
	lum = np.where(filled[..., None], lum, mortar[None, None, :] * (0.9 + 0.1 * fft_noise(n, 2.0, seed + 5)[..., None]))
	lum = lum * (0.78 + 0.22 * ao)[..., None]
	albedo = np.clip(lum, 0.0, 1.0)
	crack_alpha = stone_albedo[..., 3].astype(np.float32) / 255.0
	rgba = np.concatenate([albedo, (crack_alpha * (filled.astype(np.float32)))[..., None]], axis=-1)
	return (rgba * 255.0).astype(np.uint8), blur(height, 1.0) * 1.3


# ---------------------------------------------------------------------------------------------
# Painted wood
# ---------------------------------------------------------------------------------------------
def painted_wood(seed: int) -> tuple:
	"""Horizontal boards of 0.18 m with fine grain, knots and a different tone per board."""
	n = SIZE
	rng = np.random.default_rng(seed)
	plank_h = 0.18 / 3.0 * n
	count = int(round(n / plank_h))
	rows = np.zeros(n, dtype=np.float32)
	plank_id = (np.arange(n) / (n / count)).astype(int)
	tint = rng.normal(0.0, 0.055, size=count)
	grain_a = blur(fft_noise(n, 1.6, seed + 1), 0.7)
	# grain: noise stretched along x
	stretch = np.zeros((n, n), dtype=np.float32)
	g = fft_noise(n, 2.2, seed + 2)
	for k in range(28):
		stretch += np.roll(g, k * 3, axis=1)
	stretch /= max(stretch.std(), 1e-5)
	stretch = blur(stretch, 0.6)
	lum = np.full((n, n), 0.46, dtype=np.float32)
	lum += tint[plank_id][:, None] * np.ones((1, n))
	lum += 0.030 * stretch + 0.012 * grain_a
	fine = blur(fft_noise(n, 0.9, seed + 3), 0.5)
	lum += 0.004 * fine
	height = 0.25 * stretch + 0.06 * grain_a
	# joints between boards
	local = (np.arange(n) % (n / count)) / (n / count)
	seam = np.exp(-((np.minimum(local, 1.0 - local)) / 0.045) ** 2)
	lum -= 0.16 * seam[:, None] * np.ones((1, n))
	height -= 1.4 * seam[:, None] * np.ones((1, n))
	lum += 0.04 * np.exp(-(((local - 0.10)) / 0.05) ** 2)[:, None] * np.ones((1, n))
	# knots
	yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
	for _ in range(14):
		cx, cy = rng.uniform(0, n), rng.uniform(0, n)
		r = rng.uniform(9.0, 18.0)
		dx = (xx - cx + n / 2) % n - n / 2
		dy = (yy - cy + n / 2) % n - n / 2
		d2 = (dx / 1.5) ** 2 + (dy * 1.1) ** 2
		knot = np.exp(-d2 / (r * r * 0.5))
		ring = np.exp(-((np.sqrt(d2) - r * 0.8) / 2.5) ** 2)
		lum -= 0.09 * knot + 0.03 * ring
		height -= 0.4 * knot
	# nails
	for _ in range(30):
		cx, cy = rng.uniform(0, n), rng.uniform(0, n)
		dx = (xx - cx + n / 2) % n - n / 2
		dy = (yy - cy + n / 2) % n - n / 2
		nail = np.exp(-(dx * dx + dy * dy) / 7.0)
		lum += 0.09 * nail
		height += 0.35 * nail
	lum = np.clip(lum, 0.04, 0.95)
	t = fft_noise(n, 3.0, seed + 9)
	r = lum * (1.0 + 0.060 + 0.012 * t)
	gc = lum * (0.88 + 0.004 * t)
	b = lum * (0.68 - 0.010 * t)
	albedo = (np.stack([r, gc, b], axis=-1).clip(0, 1) * 255.0).astype(np.uint8)
	return albedo, height


# ---------------------------------------------------------------------------------------------
# Roof shingles
# ---------------------------------------------------------------------------------------------
def shingles(seed: int, rows: int = 10, tile_m: float = 2.0) -> tuple:
	"""Shingle roof: a 0.2 m row, 0.18 m shingles offset from one another, each with a different value,
	lighter at the top and with a shadow under the edge, fine grain and an occasional patch of light moss."""
	n = SIZE
	rng = np.random.default_rng(seed)
	row_h = n / rows
	cols = 11
	col_w = n / cols
	yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
	lum = np.zeros((n, n), dtype=np.float32)
	height = np.zeros((n, n), dtype=np.float32)
	grain = blur(fft_noise(n, 1.3, seed + 1), 0.6)
	stripes = np.zeros((n, n), dtype=np.float32)
	g = fft_noise(n, 2.2, seed + 2)
	for k in range(14):
		stripes += np.roll(g, k * 2, axis=0)
	stripes = blur(stripes / max(stripes.std(), 1e-5), 0.6)
	for row in range(rows):
		y0 = row * row_h
		offset = (row % 2) * col_w * 0.5 + rng.uniform(-3, 3)
		for col in range(cols + 1):
			x0 = col * col_w + offset
			tint = 1.0 + rng.normal(0.0, 0.07)
			wmask = ((xx - x0) % n) < (col_w - 6.0)
			hmask = (yy >= y0) & (yy < y0 + row_h)
			m = wmask & hmask
			ty = (yy - y0) / row_h
			shade = tint * (1.12 - 0.34 * ty)
			shade = shade * (1.0 - 0.28 * smoothstep(0.84, 1.0, ty))
			lum = np.where(m, shade * (0.50 + 0.020 * stripes + 0.010 * grain), lum)
			height = np.where(m, 0.9 * ty + 0.25 * stripes * 0.1, height)
	mortar = lum <= 0.0
	lum = np.where(mortar, 0.13, lum)
	moss = np.clip(fft_noise(n, 2.4, seed + 9) - 1.0, 0.0, None) * 0.6
	rgb = np.stack([lum, lum, lum], axis=-1)
	rgb[..., 1] += moss * 0.06
	rgb[..., 0] -= moss * 0.015
	rgb[..., 2] -= moss * 0.03
	return (np.clip(rgb, 0, 1) * 255.0).astype(np.uint8), height


# ---------------------------------------------------------------------------------------------
# Banners
# ---------------------------------------------------------------------------------------------
def _numbers(text: str) -> list:
	return [float(v) for v in re.findall(r"-?\d+\.?\d*", text)]


def render_emblem(name: str, size: int, supersample: int = 4) -> Image.Image:
	"""Rasterizes an emblem from assets/emblems/<name>.svg (polygons, lines and semicircles) into an
	RGBA of `size` px. It only understands what the provisional emblems use."""
	with open(os.path.join(EMBLEM_DIR, name + ".svg"), encoding="utf-8") as handle:
		text = handle.read()
	s = size * supersample / 128.0
	canvas = Image.new("RGBA", (size * supersample, size * supersample), (0, 0, 0, 0))
	draw = ImageDraw.Draw(canvas)
	# walks the elements in order, with the translate of the nearest <g>
	offset = (0.0, 0.0)
	for match in re.finditer(r"<(/?)(g|polygon|polyline|line|path)\b([^>]*)>", text):
		closing, tag, attrs = match.group(1), match.group(2), match.group(3)
		if tag == "g":
			if closing:
				offset = (0.0, 0.0)
			else:
				t = re.search(r'translate\(([^)]*)\)', attrs)
				offset = tuple(_numbers(t.group(1))[:2]) if t else (0.0, 0.0)
			continue

		def tx(x, y):
			return ((x + offset[0]) * s, (y + offset[1]) * s)

		fill = re.search(r'fill="(#[0-9A-Fa-f]{6})"', attrs)
		stroke = re.search(r'stroke="(#[0-9A-Fa-f]{6})"', attrs)
		width = re.search(r'stroke-width="([\d.]+)"', attrs)
		if tag == "polygon" and fill:
			v = _numbers(re.search(r'points="([^"]*)"', attrs).group(1))
			draw.polygon([tx(v[i], v[i + 1]) for i in range(0, len(v), 2)], fill=fill.group(1))
		elif tag == "polyline" and stroke:
			v = _numbers(re.search(r'points="([^"]*)"', attrs).group(1))
			draw.line([tx(v[i], v[i + 1]) for i in range(0, len(v), 2)], fill=stroke.group(1),
					width=int(float(width.group(1)) * s), joint="curve")
		elif tag == "line" and stroke:
			x1, y1, x2, y2 = [float(re.search(k + r'="([-\d.]+)"', attrs).group(1)) for k in ("x1", "y1", "x2", "y2")]
			draw.line([tx(x1, y1), tx(x2, y2)], fill=stroke.group(1), width=int(float(width.group(1)) * s))
		elif tag == "path" and fill:
			# semicircle "M64 38 A26 26 0 0 f 64 90 Z": f = 0 the left half, 1 the right half
			d = re.search(r'd="([^"]*)"', attrs).group(1)
			v = _numbers(d)
			radius, sweep = v[2], int(v[5])
			cy = (v[1] + v[7]) * 0.5 if len(v) > 7 else (v[1] + v[6]) * 0.5
			cx = v[0]
			pts = []
			for k in range(0, 49):
				a = math.pi * (-0.5 + k / 48.0) * (1 if sweep == 1 else -1)
				pts.append(tx(cx + radius * math.cos(a), cy + radius * math.sin(a)))
			draw.polygon(pts, fill=fill.group(1))
	return canvas.resize((size, size), Image.LANCZOS)


def cloth_base(w: int, h: int, seed: int) -> np.ndarray:
	"""Light gray cloth (multiplied by the faction color) with soft weave and folds."""
	weave_x = np.sin(np.arange(w) * np.pi / 2.0)[None, :]
	weave_y = np.sin(np.arange(h) * np.pi / 2.0 + 1.0)[:, None]
	weave = 0.5 + 0.25 * weave_x * weave_y
	folds = fft_noise(max(w, h), 3.4, seed)[:h, :w]
	return 0.84 + 0.012 * (weave - 0.5) * 4.0 + 0.030 * folds


def banner_cell(emblem: str, w: int, h: int, seed: int, roundel_u: float, roundel_v: float,
		roundel_r: float, pendant: bool) -> np.ndarray:
	"""One banner cell, RGBA. RGB: cloth (gray, tinted with the faction color) or emblem with its
	colors; A: 1 where the emblem rules (dark disc with the emblem on top) and 0 on the cloth."""
	lum = cloth_base(w, h, seed)
	img = Image.new("L", (w, h), 255)
	draw = ImageDraw.Draw(img)
	hem = int(min(w, h) * (0.10 if pendant else 0.12))
	# woven hems and battens
	if pendant:
		draw.rectangle([0, 0, w, hem], fill=150)
		draw.rectangle([0, 0, hem, h], fill=150)
		draw.rectangle([w - hem, 0, w, h], fill=150)
		draw.rectangle([hem + 6, hem + 6, hem + 12, h], fill=205)
		draw.rectangle([w - hem - 12, hem + 6, w - hem - 6, h], fill=205)
		# dark wedge under the emblem
		cx = w // 2
		draw.polygon([(cx - int(w * 0.34), int(h * 0.62)), (cx + int(w * 0.34), int(h * 0.62)),
				(cx + int(w * 0.34), int(h * 0.78)), (cx, int(h * 0.92)), (cx - int(w * 0.34), int(h * 0.78))], fill=170)
	else:
		draw.rectangle([0, 0, w, hem], fill=150)
		draw.rectangle([0, h - hem, w, h], fill=150)
		draw.rectangle([0, hem + 8, w, hem + 15], fill=205)
		draw.rectangle([0, h - hem - 15, w, h - hem - 8], fill=205)
		draw.rectangle([0, 0, int(w * 0.035), h], fill=140)
	mask = np.asarray(img, dtype=np.float32) / 255.0
	lum = lum * mask
	rgb = np.stack([lum, lum * 0.985, lum * 0.95], axis=-1)

	yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
	cx, cy = roundel_u * w, roundel_v * h
	r = roundel_r * min(w, h)
	dist = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
	disc = smoothstep(r, r - 3.0, dist)
	ring = smoothstep(r - 4.0, r - 7.0, dist) * (1.0 - smoothstep(r - 12.0, r - 15.0, dist))
	field = np.array([0.105, 0.115, 0.125], dtype=np.float32)
	trim = np.array([0.74, 0.62, 0.30], dtype=np.float32)
	rgb = rgb * (1.0 - disc[..., None]) + field[None, None, :] * disc[..., None]
	rgb = rgb * (1.0 - ring[..., None] * 0.9) + trim[None, None, :] * ring[..., None] * 0.9
	alpha = disc.copy()
	# emblem on top
	size = int(r * 1.52)
	emb = np.asarray(render_emblem(emblem, size), dtype=np.float32) / 255.0
	x0, y0 = int(cx - size / 2), int(cy - size / 2)
	ys = slice(max(y0, 0), min(y0 + size, h))
	xs = slice(max(x0, 0), min(x0 + size, w))
	sub = emb[ys.start - y0:ys.stop - y0, xs.start - x0:xs.stop - x0]
	a = sub[..., 3:4]
	rgb[ys, xs] = rgb[ys, xs] * (1.0 - a) + sub[..., :3] * a
	return np.concatenate([np.clip(rgb, 0, 1), alpha[..., None]], axis=-1)


def pennant_atlas() -> np.ndarray:
	w, h = 1024, 512
	cells = [banner_cell(name, w, h, 77 + i, 0.30, 0.50, 0.40, False) for i, name in enumerate(EMBLEMS)]
	return (np.concatenate(cells, axis=0) * 255.0).astype(np.uint8)


def pendant_atlas() -> np.ndarray:
	w, h = 384, 1024
	cells = [banner_cell(name, w, h, 91 + i, 0.5, 0.30, 0.34, True) for i, name in enumerate(EMBLEMS)]
	return (np.concatenate(cells, axis=1) * 255.0).astype(np.uint8)


# ---------------------------------------------------------------------------------------------
def main() -> None:
	os.makedirs(OUT_DIR, exist_ok=True)
	report = []

	def write(name: str, array: np.ndarray) -> None:
		save_png(os.path.join(OUT_DIR, name), array)
		report.append("%s luminancia media %.4f" % (name.replace(".png", ""), luminance(array)))

	def write_normal(name: str, height: np.ndarray, strength: float) -> None:
		normal = normal_from_height(height, strength)
		save_png(os.path.join(OUT_DIR, name), normal)
		slope = float(np.sqrt(((normal[..., :2].astype(np.float32) / 127.5 - 1.0) ** 2).sum(axis=-1)).mean())
		report.append("%s pendiente media %.3f" % (name.replace(".png", ""), slope))

	albedo, height = painted_stone(seed=2610, base=0.50, wash=1.0, crack_count=9, pit_count=26, warm=0.55)
	write("keep_stone_albedo.png", albedo)
	write_normal("keep_stone_normal.png", height, 0.55)

	albedo, height = trim_stone(seed=4807)
	write("keep_trim_albedo.png", albedo)
	write_normal("keep_trim_normal.png", height, 0.5)

	albedo, height = ashlar_tile(seed=3300)
	write("keep_wall_albedo.png", albedo)
	write_normal("keep_wall_normal.png", height, 3.2)

	albedo, height = painted_wood(seed=5210)
	write("keep_wood_albedo.png", albedo)
	write_normal("keep_wood_normal.png", height, 0.9)

	albedo, height = shingles(seed=6120)
	write("keep_shingle_albedo.png", albedo)
	write_normal("keep_shingle_normal.png", height, 2.2)

	write("keep_pennant_atlas.png", pennant_atlas())
	write("keep_pendant_atlas.png", pendant_atlas())

	with open(os.path.join(OUT_DIR, "keep_textures.txt"), "w", encoding="utf-8") as handle:
		handle.write("\n".join(report) + "\n")
	print("\n".join(report))


if __name__ == "__main__":
	main()
