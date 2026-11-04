#!/usr/bin/env python3
"""Generates the hit effect textures (ART-09) in scenes/vfx/textures/.

Everything comes from code (numpy and PIL), with fixed seeds: running it again gives the same pixels.
There is nothing third-party. Each texture is 8-bit RGBA and is imported WITHOUT VRAM compression (the smooth
curves of sparks and smoke break into blocks with S3TC), with mipmaps. Conventions:

    - Light masks (flashes, rays, sparks) carry the value in RGB and in alpha, so they work
      both for additive blending (R is read) and for normal blending (A is read).
    - Shapes with volume (smoke, splinters, drops, splash) carry the silhouette in alpha and the shading in RGB
      (1 = light), so that the shader can tint them without losing relief.
    - Atlases are 2 x 2 cells (h_frames = 2, v_frames = 2 in the shaders).

Usage, from the project root (afterwards, import with Godot so that it creates the .ctex files):

    python tools/vfx/make_vfx_textures.py
"""

import math
import os

import numpy as np
from PIL import Image, ImageDraw

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scenes", "vfx",
		"textures")

# Text of the .import files written next to each new PNG: no VRAM compression and with mipmaps.
IMPORT_TEMPLATE = """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=0
compress/high_quality=false
compress/lossy_quality=0.7
compress/normal_map=2
mipmaps/generate=true
mipmaps/limit=-1
process/fix_alpha_border=true
process/premult_alpha=false
detect_3d/compress_to=0
"""


# --- Utilities ---------------------------------------------------------------------------------

def smoothstep(a, b, x):
	t = np.clip((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


def grid(height, width=None):
	"""Normalised coordinates (x, y) of the center of each pixel, in [0, 1)."""
	width = width or height
	yy, xx = np.mgrid[0:height, 0:width]
	return (xx + 0.5) / width, (yy + 0.5) / height


def fbm_tile(size, beta, seed, stretch=1.0):
	"""1/f^beta color noise that tiles at the edges (via FFT), normalised to [0, 1].
	[stretch] > 1 lengthens it along x (streaks)."""
	rng = np.random.default_rng(seed)
	white = rng.standard_normal((size, size if isinstance(size, int) else size[1]))
	spectrum = np.fft.fft2(white)
	fy = np.fft.fftfreq(white.shape[0])[:, None]
	fx = np.fft.fftfreq(white.shape[1])[None, :] * stretch
	radius = np.sqrt(fx * fx + fy * fy)
	radius[0, 0] = 1.0
	spectrum = spectrum / radius ** beta
	spectrum[0, 0] = 0.0
	field = np.real(np.fft.ifft2(spectrum))
	field -= field.min()
	return field / field.max()


def save(name, rgba):
	"""Saves a float array (h, w, 4) in [0, 1] as a PNG and writes its .import."""
	os.makedirs(OUT_DIR, exist_ok=True)
	data = (np.clip(rgba, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
	path = os.path.join(OUT_DIR, name)
	Image.fromarray(data, "RGBA").save(path, optimize=True)
	# The .import is only written if it does not exist: Godot adds its own uid to it on import and rewriting it on every
	# run would change it for the texture (and for everything that references it by uid).
	if not os.path.exists(path + ".import"):
		with open(path + ".import", "w", newline="\n") as handle:
			handle.write(IMPORT_TEMPLATE)
	print("  %s  %dx%d" % (name, data.shape[1], data.shape[0]))


def mask_rgba(mask):
	"""Light mask: value in RGB and in alpha."""
	mask = np.clip(mask, 0.0, 1.0)
	return np.stack([mask, mask, mask, mask], axis=-1)


def shaded_rgba(alpha, shade):
	"""Silhouette in alpha and shading in RGB."""
	shade = np.clip(shade, 0.0, 1.0)
	return np.stack([shade, shade, shade, np.clip(alpha, 0.0, 1.0)], axis=-1)


def blur(field, passes=2):
	"""Cheap box blur (wrapping at the edges)."""
	for _ in range(passes):
		field = (field + np.roll(field, 1, 0) + np.roll(field, -1, 0)
				+ np.roll(field, 1, 1) + np.roll(field, -1, 1)) / 5.0
	return field


def atlas(frames):
	"""Joins 4 cells of the same size into a 2 x 2 atlas."""
	top = np.concatenate([frames[0], frames[1]], axis=1)
	bottom = np.concatenate([frames[2], frames[3]], axis=1)
	return np.concatenate([top, bottom], axis=0)


# --- Textures ----------------------------------------------------------------------------------

def make_soft_dot():
	"""Dot of light: hot core and soft falloff."""
	x, y = grid(64)
	r = np.hypot(x - 0.5, y - 0.5) * 2.0
	core = np.exp(-(r / 0.22) ** 2)
	halo = np.exp(-(r / 0.55) ** 2) * 0.55
	edge = smoothstep(1.0, 0.75, r)
	save("soft_dot.png", mask_rgba(np.clip(core + halo, 0.0, 1.0) * edge))


def make_flare_star():
	"""Four-pointed flash: core, halo, long cross (more horizontal than vertical) and two short
	diagonals."""
	size = 256
	x, y = grid(size)
	x = (x - 0.5) * 2.0
	y = (y - 0.5) * 2.0
	r = np.hypot(x, y)
	core = np.exp(-(r / 0.07) ** 2)
	halo = np.exp(-r * 5.5) * 0.5
	horizontal = np.exp(-(y / 0.022) ** 2) * np.exp(-np.abs(x) * 3.2)
	vertical = np.exp(-(x / 0.022) ** 2) * np.exp(-np.abs(y) * 4.5) * 0.85
	u = (x + y) * 0.7071
	v = (x - y) * 0.7071
	diag_a = np.exp(-(v / 0.018) ** 2) * np.exp(-np.abs(u) * 7.0) * 0.45
	diag_b = np.exp(-(u / 0.018) ** 2) * np.exp(-np.abs(v) * 7.0) * 0.45
	mask = core * 1.4 + halo + horizontal + vertical + diag_a + diag_b
	mask *= smoothstep(1.0, 0.8, r)
	save("flare_star.png", mask_rgba(mask))


def make_spark_streak():
	"""Spark with a tail, 64 x 256. The head (what leads) is at the TOP, which is where the
	engine points the particle's Y axis when it aligns it with its velocity."""
	width, height = 64, 256
	x, y = grid(height, width)
	x = (x - 0.5) * 2.0
	t = y
	fall = np.clip(1.0 - t, 0.0, 1.0)
	# Thin body that narrows towards the tail, with a thread of white core and a small head.
	taper = 0.05 + 0.2 * fall ** 1.8
	body = np.exp(-(x / taper) ** 2) * fall ** 1.25 * smoothstep(0.0, 0.05, t)
	core = np.exp(-(x / (taper * 0.4)) ** 2) * np.clip(1.0 - t * 1.15, 0.0, 1.0) ** 1.5
	head = np.exp(-((t - 0.075) / 0.035) ** 2) * np.exp(-(x / 0.3) ** 2)
	halo = np.exp(-((t - 0.1) / 0.1) ** 2) * np.exp(-(x / 0.7) ** 2) * 0.25
	mask = body * 0.7 + core * 0.8 + head * 0.9 + halo
	save("spark_streak.png", mask_rgba(mask))


def make_rays():
	"""Radial rays for the perfect block: thin, of different lengths, with halo and core."""
	size = 512
	x, y = grid(size)
	x = (x - 0.5) * 2.0
	y = (y - 0.5) * 2.0
	r = np.hypot(x, y)
	theta = np.arctan2(y, x)
	rng = np.random.default_rng(7)
	count = 18
	mask = np.zeros_like(r)
	for i in range(count):
		angle = (i + rng.uniform(-0.28, 0.28)) / count * 2.0 * math.pi
		length = rng.uniform(0.38, 0.95) if i % 2 == 0 else rng.uniform(0.22, 0.5)
		strength = rng.uniform(0.65, 1.0)
		half_width = rng.uniform(0.012, 0.03)
		delta = np.angle(np.exp(1j * (theta - angle)))
		perp = r * np.sin(np.clip(np.abs(delta), 0.0, math.pi / 2.0))
		forward = r * np.cos(np.clip(np.abs(delta), 0.0, math.pi / 2.0))
		forward = np.where(np.abs(delta) < math.pi / 2.0, forward, 0.0)
		width_here = half_width * (1.0 - np.clip(forward / length, 0.0, 1.0)) + 0.002
		ray = np.exp(-(perp / width_here) ** 2) * np.clip(1.0 - forward / length, 0.0, 1.0) ** 0.8
		mask += ray * strength * smoothstep(0.0, 0.04, r)
	core = np.exp(-(r / 0.09) ** 2) * 1.2 + np.exp(-r * 6.0) * 0.45
	mask = (mask + core) * smoothstep(1.0, 0.85, r)
	save("rays.png", mask_rgba(mask))


def make_noise():
	"""Three tiling noises, one per channel (soft clouds, fine clouds and long streaks), 256 px."""
	soft = fbm_tile(256, 1.7, 21)
	fine = fbm_tile(256, 1.0, 22)
	streak = fbm_tile(256, 1.3, 23, stretch=7.0)
	rgba = np.stack([soft, fine, streak, np.ones_like(soft)], axis=-1)
	save("noise.png", rgba)


def make_shards():
	"""Four metal shards (faceted splinters with a light side and a dark one), 4 x 64 px."""
	rng = np.random.default_rng(31)
	frames = []
	for index in range(4):
		size = 64
		scale = 6
		big = size * scale
		alpha_img = Image.new("L", (big, big), 0)
		light_img = Image.new("L", (big, big), 0)
		alpha_draw = ImageDraw.Draw(alpha_img)
		light_draw = ImageDraw.Draw(light_img)
		c = big / 2.0
		angle = rng.uniform(0.0, math.pi)
		length = rng.uniform(0.36, 0.46) * big
		half = rng.uniform(0.07, 0.11) * big
		ca, sa = math.cos(angle), math.sin(angle)

		def pt(u, v):
			return (c + u * ca - v * sa, c + u * sa + v * ca)

		bend = rng.uniform(-0.06, 0.06) * big
		tip = pt(length, bend)
		tail_a = pt(-length * rng.uniform(0.7, 1.0), -half)
		tail_b = pt(-length * rng.uniform(0.6, 0.9), half * rng.uniform(0.8, 1.4))
		mid_a = pt(length * 0.1, -half * 1.1)
		mid_b = pt(length * 0.0, half * 1.2)
		alpha_draw.polygon([tip, mid_a, tail_a, tail_b, mid_b], fill=255)
		# Light facet: from the tip to the middle of the lower edge.
		ridge_tail = pt(-length * 0.8, 0.0)
		light_draw.polygon([tip, mid_a, ridge_tail], fill=255)
		light_draw.polygon([tip, mid_b, ridge_tail], fill=110)
		alpha = np.asarray(alpha_img.resize((size, size), Image.LANCZOS), dtype=np.float32) / 255.0
		light = np.asarray(light_img.resize((size, size), Image.LANCZOS), dtype=np.float32) / 255.0
		shade = 0.45 + 0.55 * light
		frames.append(shaded_rgba(alpha, shade))
	save("shards.png", atlas(frames))


def make_droplets():
	"""Four stylised drops (round, teardrop, elongated and double), 4 x 64 px."""
	frames = []
	size = 64
	x, y = grid(size)
	x = (x - 0.5) * 2.0
	y = (y - 0.5) * 2.0
	# 1) Round with a highlight.
	r = np.hypot(x, y)
	round_alpha = smoothstep(0.62, 0.56, r)
	shade = 0.7 + 0.3 * smoothstep(0.35, 0.0, np.hypot(x + 0.2, y + 0.2))
	frames.append(shaded_rgba(round_alpha, shade))
	# 2) Teardrop with the tip DOWN: the drop travels upward (Y axis following the velocity) and the tip
	# ends up behind.
	flipped = -y
	t = np.clip((flipped + 0.78) / 1.5, 0.0, 1.0)
	half = 0.5 * np.sin(np.pi * np.clip(t, 0.0, 1.0) ** 0.62) ** 1.1 * (0.2 + 0.8 * t)
	tear = smoothstep(0.03, -0.03, np.abs(x) - half) * smoothstep(0.0, 0.03, t) * smoothstep(1.0, 0.97, t)
	frames.append(shaded_rgba(tear, 0.68 + 0.3 * smoothstep(0.4, 0.0, np.hypot(x + 0.18, y + 0.25))))
	# 3) Elongated (a little streak).
	long_half = 0.2 * np.sin(np.pi * np.clip((y + 0.9) / 1.8, 0.0, 1.0)) ** 0.8
	flick = smoothstep(0.03, -0.03, np.abs(x) - long_half)
	frames.append(shaded_rgba(flick, 0.78 - 0.15 * np.abs(x) * 3.0))
	# 4) Double: two drops stuck together.
	a = smoothstep(0.34, 0.3, np.hypot(x + 0.28, y + 0.12))
	b = smoothstep(0.22, 0.18, np.hypot(x - 0.32, y - 0.3))
	frames.append(shaded_rgba(np.maximum(a, b), 0.72 + 0.25 * smoothstep(0.3, 0.0, np.hypot(x + 0.4, y + 0.2))))
	save("droplets.png", atlas(frames))


def make_puffs():
	"""Four puffs of dust with volume, in a 2 x 2 atlas of 256 px cells (512 x 512).

	They do not carry baked color: they are data for the lit shader (vfx_particle_lit):
	    R = relief height (0 outside the puff, 1 at the top of the lobes); the
	        normal comes from it, so the sun shapes it and the shadow darkens it;
	    G = fine noise (the erosion: the puff dissolves from the edge, the alpha does not drop all at once);
	    B = swirl noise, which displaces the erosion so that each copy breaks up differently;
	    A = 1."""
	size = 256
	frames = []
	for index in range(4):
		rng = np.random.default_rng(100 + index)
		x, y = grid(size)
		x = (x - 0.5) * 2.0
		y = (y - 0.5) * 2.0
		coarse = fbm_tile(size, 2.0, 120 + index)
		fine = fbm_tile(size, 1.3, 140 + index)
		lobes = int(rng.integers(7, 10))
		domes = []
		for lobe in range(lobes):
			angle = rng.uniform(0.0, 2.0 * math.pi)
			dist = 0.0 if lobe == 0 else rng.uniform(0.2, 0.52)
			radius = rng.uniform(0.28, 0.42) if lobe else 0.5
			cx, cy = dist * math.cos(angle), dist * math.sin(angle) * 0.8
			# Each lobe is a hemisphere: the edge wrinkled with noise at two scales.
			d = np.hypot(x - cx, y - cy) / radius + (coarse - 0.5) * 0.3 + (fine - 0.5) * 0.12
			domes.append(np.sqrt(np.clip(1.0 - d * d, 0.0, 1.0)))
		# Soft maximum of the hemispheres: a crease is left between one lobe and the next, as in a cauliflower.
		smooth = np.log(np.sum([np.exp(7.0 * dome) for dome in domes], axis=0)) / 7.0 - math.log(lobes) / 7.0
		height = smooth / smooth.max()
		height = height * (0.88 + 0.24 * (fine - 0.5)) * smoothstep(1.0, 0.82, np.hypot(x, y))
		height = np.clip(blur(height, 1), 0.0, 1.0)
		detail = fbm_tile(size, 1.15, 160 + index)
		swirl = fbm_tile(size, 1.7, 180 + index)
		frames.append(np.stack([height, detail, swirl, np.ones_like(height)], axis=-1))
	save("puffs.png", atlas(frames))


def make_splat_jets():
	"""Splash jets in sequence, for the hit on flesh: 4 variants (rows) by 5 frames
	(columns), 128 px cells, 640 x 512. The jet leaves the center of the cell towards +X (the
	shader rotates it towards the direction of the hit).

	    R = shading (1 = light; the center of the jet is lighter, giving the thickness of a liquid);
	    G = specular highlight (an elongated reflection on the jet and a dot on each drop);
	    A = silhouette.
	Each frame is an instant of the jet: it is born as a fat blob, stretches, narrows and
	breaks into elongated drops at the front."""
	cell = 128
	X0 = -0.72  # the jet is born near the left edge of the cell (the shader displaces it)
	frames_n, variants = 5, 4
	sheet = np.zeros((cell * variants, cell * frames_n, 4))
	x, y = grid(cell)
	x = (x - 0.5) * 2.0
	y = (y - 0.5) * 2.0
	for variant in range(variants):
		rng = np.random.default_rng(300 + variant)
		bend = rng.uniform(-0.45, 0.45)
		thick = rng.uniform(0.85, 1.2)
		edge_noise = fbm_tile(cell, 1.2, 320 + variant)
		branches = []
		for angle in (rng.uniform(0.12, 0.28), -rng.uniform(0.12, 0.28), rng.uniform(0.4, 0.62),
				-rng.uniform(0.4, 0.62)):
			if rng.uniform() < 0.8:
				branches.append((angle, rng.uniform(0.5, 0.85), rng.uniform(0.45, 0.8), 0.0))
		drops = []
		for _ in range(9):
			drops.append((rng.uniform(0.05, 0.55), rng.uniform(-0.28, 0.28), rng.uniform(0.022, 0.05)))

		def jet(x0, angle, length, width, curve, ragged=1.0):
			ca, sa = math.cos(angle), math.sin(angle)
			u = (x - x0) * ca + y * sa
			v = -(x - x0) * sa + y * ca + (edge_noise - 0.5) * 0.1 * np.clip(u, 0.0, 1.0)
			s = np.clip(u / max(length, 0.01), -0.3, 1.2)
			center = curve * np.clip(s, 0.0, 1.0) ** 2 * length * 0.5
			ramp = 1.0 - np.exp(-np.clip(s, 0.0, 1.0) * 7.0)
			half = width * np.clip(1.0 - s, 0.0, 1.0) ** 0.75 * (0.3 + 0.7 * ramp)
			half = half * (1.0 + (edge_noise - 0.5) * 0.75 * ragged * np.clip(s, 0.0, 1.0))
			mask = smoothstep(0.012, -0.012, np.abs(v - center) - half) * smoothstep(-0.02, 0.02, u) \
					* smoothstep(1.02, 0.96, s)
			core = np.clip(1.0 - np.abs(v - center) / np.maximum(half, 0.01), 0.0, 1.0)
			return mask, core, v - center, half

		for f in range(frames_n):
			t = (f + 1) / frames_n
			grow = 1.0 - (1.0 - t) ** 2
			length = 0.3 + 1.35 * grow
			width = 0.17 * thick * (1.0 - 0.45 * t)
			alpha = np.zeros((cell, cell))
			shade = np.zeros((cell, cell))
			spec = np.zeros((cell, cell))
			stem, core, off, half = jet(X0, 0.0, length, width, bend)
			alpha = np.maximum(alpha, stem)
			shade = np.maximum(shade, core * stem)
			spec = np.maximum(spec, stem * np.exp(-((off + half * 0.38) / np.maximum(half * 0.2, 0.012)) ** 2)
					* smoothstep(0.1, 0.35, half) * 0.9)
			for angle, factor, w_factor, start in branches:
				m, c, _, _ = jet(X0, angle, length * factor, width * w_factor, bend * 0.6)
				alpha = np.maximum(alpha, m * smoothstep(0.1, 0.35, t))
				shade = np.maximum(shade, c * m * 0.9)
			# Impact blob, which shrinks and lightens over time.
			blob_r = 0.15 * (1.0 - 0.55 * t) * thick
			blob = smoothstep(blob_r, blob_r * 0.55, np.hypot(x - X0, y * 1.1))
			blob *= 1.0 - 0.7 * smoothstep(0.5, 1.0, t)
			alpha = np.maximum(alpha, blob)
			shade = np.maximum(shade, blob * 0.8)
			# Drops at the front: they appear as the jet advances, elongated along the direction of motion.
			for pos, side, radius in drops:
				if pos > grow * 1.05 - 0.03:
					continue
				dx = X0 + length * 0.82 + pos * 1.1 * grow
				dy = side * (0.25 + 0.5 * grow) + bend * (dx - X0) ** 2 * 0.25
				ex = radius * (1.9 + 1.2 * (1.0 - t))
				d = np.hypot((x - dx) / ex, (y - dy) / radius)
				drop = smoothstep(1.0, 0.7, d)
				alpha = np.maximum(alpha, drop)
				shade = np.maximum(shade, drop * 0.85)
				spec = np.maximum(spec, drop * np.exp(-(np.hypot((x - dx + ex * 0.3) / (ex * 0.35),
						(y - dy + radius * 0.3) / (radius * 0.35))) ** 2))
			# Fades out at the edges of the cell.
			window = smoothstep(1.0, 0.86, np.hypot(x, y))
			alpha = alpha * window
			rgba = np.stack([0.5 + 0.5 * shade, spec, np.zeros_like(shade), alpha], axis=-1)
			sheet[variant * cell:(variant + 1) * cell, f * cell:(f + 1) * cell] = rgba
	save("splat_jets.png", sheet)


def make_planks():
	"""Four flat wooden planks, a 2 x 2 atlas of 128 px cells (256 x 256). Each one is a
	flat piece of board: one end cut at a bevel, the other broken into teeth, with grain along its length.

	    R = shading (grain, dark edge);
	    G = fresh wood (1 at the break, where untanned wood is light); the shader tints it with
	        a second tone ([accent]), so the plank has two wood tones;
	    A = silhouette."""
	rng = np.random.default_rng(17)
	frames = []
	for index in range(4):
		size = 128
		scale = 6
		big = size * scale
		alpha_img = Image.new("L", (big, big), 0)
		fresh_img = Image.new("L", (big, big), 0)
		draw_a = ImageDraw.Draw(alpha_img)
		draw_f = ImageDraw.Draw(fresh_img)
		length = rng.uniform(0.78, 0.9) * big
		width = rng.uniform(0.2, 0.3) * big
		cx, cy = big / 2.0, big / 2.0
		angle = rng.uniform(-0.25, 0.25)
		ca, sa = math.cos(angle), math.sin(angle)

		def pt(u, v):
			return (cx + u * ca - v * sa, cy + u * sa + v * ca)

		half_l, half_w = length / 2.0, width / 2.0
		bevel = rng.uniform(0.3, 0.7) * width
		# Left end cut at a bevel; right end broken into teeth.
		outline = [pt(-half_l + bevel, -half_w), pt(half_l * 0.9, -half_w)]
		teeth = int(rng.integers(3, 6))
		for tooth in range(teeth + 1):
			v = -half_w + width * tooth / teeth
			u = half_l - rng.uniform(0.0, 0.14) * length * (1 if tooth % 2 else 0.35)
			outline.append(pt(u, v))
		outline.append(pt(-half_l, half_w))
		outline.append(pt(-half_l, half_w - bevel * 0.5))
		draw_a.polygon(outline, fill=255)
		# Fresh wood: the broken end and a strip of the bevel.
		draw_f.polygon([pt(half_l * 0.38, -half_w * 1.2), pt(half_l * 1.1, -half_w * 1.2),
				pt(half_l * 1.1, half_w * 1.2), pt(half_l * 0.38, half_w * 1.2)], fill=255)
		draw_f.polygon([pt(-half_l * 1.05, half_w * 1.1), pt(-half_l + bevel * 1.3, half_w * 1.1),
				pt(-half_l + bevel * 0.2, -half_w * 1.1), pt(-half_l * 1.05, -half_w * 1.1)], fill=140)
		alpha = np.asarray(alpha_img.resize((size, size), Image.LANCZOS), dtype=np.float32) / 255.0
		fresh = np.asarray(fresh_img.resize((size, size), Image.LANCZOS), dtype=np.float32) / 255.0
		fresh = blur(fresh, 2) * (alpha > 0.02)
		gx, gy = grid(size)
		noise = fbm_tile(size, 1.1, 400 + index)
		# Grain along the plank (the plane's axis is x rotated by [angle]).
		v = -(gx - 0.5) * sa + (gy - 0.5) * ca
		grain = 0.5 + 0.5 * np.sin(v * 70.0 + noise * 10.0)
		grain = 0.7 + 0.22 * grain + 0.12 * (noise - 0.5)
		# Dark edge: the outline of the plank sinks into shadow.
		inner = blur(alpha, 4)
		edge = 0.62 + 0.38 * smoothstep(0.55, 0.98, inner)
		shade = grain * edge
		frames.append(np.stack([shade, fresh, np.zeros_like(shade), alpha], axis=-1))
	save("planks.png", atlas(frames))


def make_fibers():
	"""Four wisps of cloth (fine, curly strands), a 2 x 2 atlas of 128 px cells (256 x 256).
	R = shading, A = silhouette."""
	rng = np.random.default_rng(23)
	frames = []
	for index in range(4):
		size = 128
		scale = 6
		big = size * scale
		alpha_img = Image.new("L", (big, big), 0)
		shade_img = Image.new("L", (big, big), 0)
		draw_a = ImageDraw.Draw(alpha_img)
		draw_s = ImageDraw.Draw(shade_img)
		for _ in range(int(rng.integers(3, 6))):
			ax = rng.uniform(0.15, 0.4) * big
			ay = rng.uniform(0.2, 0.8) * big
			length = rng.uniform(0.45, 0.8) * big
			angle = rng.uniform(-0.8, 0.8)
			curl = rng.uniform(-0.18, 0.18) * big
			wobble = rng.uniform(0.0, 1.0)
			points = []
			for k in range(17):
				s = k / 16.0
				u = ax + s * length * math.cos(angle) - curl * math.sin(s * math.pi) * math.sin(angle)
				v = ay + s * length * math.sin(angle) + curl * math.sin(s * math.pi) * math.cos(angle)
				points.append((u, v + 0.05 * big * math.sin(s * 9.0 + wobble)))
			width = int(rng.uniform(0.014, 0.024) * big)
			draw_a.line(points, fill=255, width=width, joint="curve")
			draw_s.line(points, fill=int(rng.uniform(150, 255)), width=max(1, width // 2), joint="curve")
		alpha = np.asarray(alpha_img.resize((size, size), Image.LANCZOS), dtype=np.float32) / 255.0
		shade = np.asarray(shade_img.resize((size, size), Image.LANCZOS), dtype=np.float32) / 255.0
		frames.append(shaded_rgba(alpha, 0.6 + 0.4 * blur(shade, 1)))
	save("fibers.png", atlas(frames))


def make_ring_dust():
	"""Low dust ring for the ground (hard landings only): narrow, no hard edge, with clumps."""
	size = 256
	x, y = grid(size)
	x = (x - 0.5) * 2.0
	y = (y - 0.5) * 2.0
	r = np.hypot(x, y)
	noise = fbm_tile(256, 1.5, 81)
	fine = fbm_tile(256, 1.0, 82)
	r_n = r + (noise - 0.5) * 0.3
	ring = smoothstep(0.5, 0.78, r_n) * smoothstep(1.0, 0.8, r_n)
	ring = ring * (0.55 + 0.9 * (fine - 0.35))
	save("ring_dust.png", shaded_rgba(np.clip(ring, 0.0, 1.0), 0.7 + 0.3 * smoothstep(0.5, 0.95, r_n)))


def main():
	print("Texturas de efectos de golpe en", os.path.normpath(OUT_DIR))
	# Those no longer in use are deleted so that the folder is exactly what this script generates.
	for stale in ("wisp.png", "splat.png", "splinters.png"):
		for suffix in ("", ".import"):
			path = os.path.join(OUT_DIR, stale + suffix)
			if os.path.exists(path):
				os.remove(path)
	make_soft_dot()
	make_flare_star()
	make_spark_streak()
	make_rays()
	make_noise()
	make_puffs()
	make_splat_jets()
	make_shards()
	make_planks()
	make_fibers()
	make_droplets()
	make_ring_dust()


if __name__ == "__main__":
	main()
