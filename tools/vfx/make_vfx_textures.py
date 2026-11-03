#!/usr/bin/env python3
"""Genera las texturas de los efectos de golpe (ART-09) en scenes/vfx/textures/.

Todo sale de código (numpy y PIL), con semillas fijas: volver a ejecutarlo da los mismos píxeles.
No hay nada de terceros. Cada textura es RGBA de 8 bits y se importa SIN compresión de VRAM (las
curvas suaves de chispas y humo se rompen en bloques con S3TC), con mipmaps. Convenciones:

    - Las máscaras de luz (destellos, rayos, chispas) llevan el valor en RGB y en alfa, así sirven
      tanto para mezcla aditiva (se lee R) como para mezcla normal (se lee A).
    - Las de forma con volumen (humo, astillas, gotas, salpicadura) llevan en alfa la silueta y en RGB
      el sombreado (1 = claro), para que el sombreador las tiña sin perder relieve.
    - Los atlas son de 2 x 2 casillas (h_frames = 2, v_frames = 2 en los sombreadores).

Uso, desde la raíz del proyecto (después, importar con Godot para que cree los .ctex):

    python tools/vfx/make_vfx_textures.py
"""

import math
import os

import numpy as np
from PIL import Image, ImageDraw

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scenes", "vfx",
		"textures")

# Texto de los .import que se escriben junto a cada PNG: sin compresión de VRAM y con mipmaps.
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


# --- Utilidades --------------------------------------------------------------------------------

def smoothstep(a, b, x):
	t = np.clip((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


def grid(height, width=None):
	"""Coordenadas normalizadas (x, y) del centro de cada píxel, en [0, 1)."""
	width = width or height
	yy, xx = np.mgrid[0:height, 0:width]
	return (xx + 0.5) / width, (yy + 0.5) / height


def fbm_tile(size, beta, seed, stretch=1.0):
	"""Ruido de color 1/f^beta que se repite en los bordes (por FFT), normalizado a [0, 1].
	[stretch] > 1 lo alarga a lo largo de x (vetas)."""
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
	"""Guarda un array float (h, w, 4) en [0, 1] como PNG y escribe su .import."""
	os.makedirs(OUT_DIR, exist_ok=True)
	data = (np.clip(rgba, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
	path = os.path.join(OUT_DIR, name)
	Image.fromarray(data, "RGBA").save(path, optimize=True)
	with open(path + ".import", "w", newline="\n") as handle:
		handle.write(IMPORT_TEMPLATE)
	print("  %s  %dx%d" % (name, data.shape[1], data.shape[0]))


def mask_rgba(mask):
	"""Máscara de luz: valor en RGB y en alfa."""
	mask = np.clip(mask, 0.0, 1.0)
	return np.stack([mask, mask, mask, mask], axis=-1)


def shaded_rgba(alpha, shade):
	"""Silueta en alfa y sombreado en RGB."""
	shade = np.clip(shade, 0.0, 1.0)
	return np.stack([shade, shade, shade, np.clip(alpha, 0.0, 1.0)], axis=-1)


def blur(field, passes=2):
	"""Desenfoque barato de caja (con repetición en los bordes)."""
	for _ in range(passes):
		field = (field + np.roll(field, 1, 0) + np.roll(field, -1, 0)
				+ np.roll(field, 1, 1) + np.roll(field, -1, 1)) / 5.0
	return field


def atlas(frames):
	"""Une 4 casillas del mismo tamaño en un atlas de 2 x 2."""
	top = np.concatenate([frames[0], frames[1]], axis=1)
	bottom = np.concatenate([frames[2], frames[3]], axis=1)
	return np.concatenate([top, bottom], axis=0)


# --- Texturas ----------------------------------------------------------------------------------

def make_soft_dot():
	"""Punto de luz: núcleo caliente y caída suave."""
	x, y = grid(64)
	r = np.hypot(x - 0.5, y - 0.5) * 2.0
	core = np.exp(-(r / 0.22) ** 2)
	halo = np.exp(-(r / 0.55) ** 2) * 0.55
	edge = smoothstep(1.0, 0.75, r)
	save("soft_dot.png", mask_rgba(np.clip(core + halo, 0.0, 1.0) * edge))


def make_flare_star():
	"""Destello de cuatro puntas: núcleo, halo, cruz larga (horizontal más que vertical) y dos
	diagonales cortas."""
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
	"""Chispa con cola, 64 x 256. La cabeza (lo que va delante) está ARRIBA, que es hacia donde el
	motor apunta el eje Y de la partícula cuando la alinea con su velocidad."""
	width, height = 64, 256
	x, y = grid(height, width)
	x = (x - 0.5) * 2.0
	t = y
	fall = np.clip(1.0 - t, 0.0, 1.0)
	# Cuerpo fino que se estrecha hacia la cola, con un hilo de núcleo blanco y una cabeza pequeña.
	taper = 0.05 + 0.2 * fall ** 1.8
	body = np.exp(-(x / taper) ** 2) * fall ** 1.25 * smoothstep(0.0, 0.05, t)
	core = np.exp(-(x / (taper * 0.4)) ** 2) * np.clip(1.0 - t * 1.15, 0.0, 1.0) ** 1.5
	head = np.exp(-((t - 0.075) / 0.035) ** 2) * np.exp(-(x / 0.3) ** 2)
	halo = np.exp(-((t - 0.1) / 0.1) ** 2) * np.exp(-(x / 0.7) ** 2) * 0.25
	mask = body * 0.7 + core * 0.8 + head * 0.9 + halo
	save("spark_streak.png", mask_rgba(mask))


def make_wisp():
	"""Lengua de energía que sube, 64 x 256 (cabeza arriba): ancha en el centro, puntiaguda y con
	cola que se difumina; el ruido la deshilacha."""
	width, height = 64, 256
	x, y = grid(height, width)
	noise = fbm_tile(256, 1.4, 11)[:height, :width]
	t = y
	wobble = 0.12 * np.sin(t * 9.0 + 1.3) * (1.0 - t)
	centered = (x - 0.5) - wobble * 0.5
	profile = np.sin(np.pi * np.clip(1.0 - t, 0.0, 1.0) ** 0.7) ** 1.2
	half_width = 0.05 + 0.26 * profile
	d = np.abs(centered) / half_width + (noise - 0.5) * 0.45
	density = smoothstep(1.0, 0.15, d) * smoothstep(0.0, 0.12, t) * smoothstep(1.0, 0.45, t)
	core = smoothstep(0.55, 0.0, d) * smoothstep(0.0, 0.2, t) * smoothstep(0.95, 0.3, t)
	save("wisp.png", mask_rgba(density * 0.7 + core * 0.6))


def make_rays():
	"""Rayos radiales para la parada perfecta: delgados, de distinto largo, con halo y núcleo."""
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
	"""Tres ruidos que se repiten, uno por canal (nubes suaves, nubes finas y vetas largas), 256 px."""
	soft = fbm_tile(256, 1.7, 21)
	fine = fbm_tile(256, 1.0, 22)
	streak = fbm_tile(256, 1.3, 23, stretch=7.0)
	rgba = np.stack([soft, fine, streak, np.ones_like(soft)], axis=-1)
	save("noise.png", rgba)


def make_puffs():
	"""Cuatro bocanadas de humo o polvo con volumen (sombreado arriba a la izquierda), 4 x 128 px."""
	frames = []
	for index in range(4):
		size = 128
		noise = fbm_tile(size, 1.9, 40 + index)
		fine = fbm_tile(size, 1.2, 50 + index)
		x, y = grid(size)
		d = np.hypot(x - 0.5, y - 0.5) * 2.0
		base = np.clip(1.0 - d, 0.0, 1.0) ** 1.2
		density = np.clip(base * 1.9 + (noise - 0.5) * 1.15 + (fine - 0.5) * 0.25, 0.0, 1.0)
		density = smoothstep(0.05, 1.0, density) ** 1.35 * smoothstep(1.0, 0.5, d)
		density = blur(density, 2)
		blurred = blur(density, 3)
		gy, gx = np.gradient(blurred)
		light = -(gx * 0.7 + gy * 0.7) * 18.0
		shade = 0.74 + np.clip(light, -0.3, 0.3) * 0.7 + blurred * 0.18
		frames.append(shaded_rgba(density * 0.85, shade))
	save("puffs.png", atlas(frames))


def make_splat():
	"""Salpicadura de tinta estilizada: mancha central con puntas y gotas sueltas, 256 px."""
	size = 256
	x, y = grid(size)
	x = (x - 0.5) * 2.0
	y = (y - 0.5) * 2.0
	r = np.hypot(x, y)
	theta = np.arctan2(y, x)
	rng = np.random.default_rng(3)
	boundary = 0.25 + 0.04 * np.sin(theta * 3.0 + 0.7) + 0.025 * np.sin(theta * 7.0 + 2.1)
	satellites = np.zeros_like(r)
	spikes = 11
	for i in range(spikes):
		angle = (i + rng.uniform(-0.3, 0.3)) / spikes * 2.0 * math.pi
		length = rng.uniform(0.2, 0.52)
		width = rng.uniform(0.07, 0.16)
		delta = np.angle(np.exp(1j * (theta - angle)))
		boundary = boundary + length * np.exp(-(delta / width) ** 2) * (0.55 + 0.45 * smoothstep(
				0.0, 1.0, np.exp(-(delta / width) ** 2)))
		# Gota suelta justo más allá de la punta.
		drop_r = 0.25 + length + rng.uniform(0.07, 0.14)
		dx = drop_r * math.cos(angle)
		dy = drop_r * math.sin(angle)
		radius = rng.uniform(0.022, 0.045)
		satellites = np.maximum(satellites, smoothstep(radius, radius * 0.55, np.hypot(x - dx, y - dy)))
	for _ in range(7):
		angle = rng.uniform(0.0, 2.0 * math.pi)
		drop_r = rng.uniform(0.5, 0.88)
		dx = drop_r * math.cos(angle)
		dy = drop_r * math.sin(angle)
		radius = rng.uniform(0.012, 0.03)
		satellites = np.maximum(satellites, smoothstep(radius, radius * 0.5, np.hypot(x - dx, y - dy)))
	body = smoothstep(0.02, -0.02, r - boundary)
	alpha = np.maximum(body, satellites) * smoothstep(1.0, 0.9, r)
	# Más oscuro en el borde y más claro hacia el centro: da grosor de tinta.
	inner = np.clip(1.0 - r / np.maximum(boundary, 0.05), 0.0, 1.0)
	shade = 0.62 + 0.38 * np.sqrt(inner) + (fbm_tile(256, 1.6, 5) - 0.5) * 0.12
	shade = np.where(satellites > body, 0.82, shade)
	save("splat.png", shaded_rgba(alpha, shade))


def make_shards():
	"""Cuatro esquirlas de metal (astillas facetadas con un lado claro y otro oscuro), 4 x 64 px."""
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
		# Faceta clara: de la punta a la mitad de la arista inferior.
		ridge_tail = pt(-length * 0.8, 0.0)
		light_draw.polygon([tip, mid_a, ridge_tail], fill=255)
		light_draw.polygon([tip, mid_b, ridge_tail], fill=110)
		alpha = np.asarray(alpha_img.resize((size, size), Image.LANCZOS), dtype=np.float32) / 255.0
		light = np.asarray(light_img.resize((size, size), Image.LANCZOS), dtype=np.float32) / 255.0
		shade = 0.45 + 0.55 * light
		frames.append(shaded_rgba(alpha, shade))
	save("shards.png", atlas(frames))


def make_splinters():
	"""Cuatro astillas de madera con veta, extremo roto claro y punta afilada, 4 x 128 px."""
	rng = np.random.default_rng(17)
	frames = []
	for index in range(4):
		size = 128
		x, y = grid(size)
		x = x - 0.5
		y = y - 0.5
		angle = rng.uniform(0.0, math.pi)
		ca, sa = math.cos(angle), math.sin(angle)
		u = x * ca + y * sa
		v = -x * sa + y * ca
		length = rng.uniform(0.40, 0.47)
		t = np.clip((u + length) / (2.0 * length), -0.2, 1.2)
		noise = fbm_tile(size, 1.1, 60 + index)
		width = 0.075 * np.clip(1.0 - t, 0.0, 1.0) ** 0.75 * (1.0 + 0.5 * (noise - 0.5))
		width *= smoothstep(0.0, 0.06, t)
		# Extremo roto: borde dentado.
		jag = 0.03 * (fbm_tile(size, 0.8, 70 + index) - 0.5)
		inside = smoothstep(0.004, -0.004, np.abs(v + 0.005 * np.sin(u * 40.0)) - width)
		inside *= smoothstep(-length - jag, -length - jag + 0.012, u)
		inside *= smoothstep(length, length - 0.02, u)
		grain = 0.72 + 0.2 * np.sin(v * 220.0 + noise * 9.0) + 0.1 * (noise - 0.5)
		edge = smoothstep(0.0, 0.03, width - np.abs(v))
		fresh = smoothstep(0.35, 0.0, t)
		shade = (grain * (0.62 + 0.38 * edge)) * (1.0 - 0.0 * fresh) + 0.28 * fresh
		frames.append(shaded_rgba(inside, shade))
	save("splinters.png", atlas(frames))


def make_droplets():
	"""Cuatro gotas estilizadas (redonda, lágrima, alargada y doble), 4 x 64 px."""
	frames = []
	size = 64
	x, y = grid(size)
	x = (x - 0.5) * 2.0
	y = (y - 0.5) * 2.0
	# 1) Redonda con brillo.
	r = np.hypot(x, y)
	round_alpha = smoothstep(0.62, 0.56, r)
	shade = 0.7 + 0.3 * smoothstep(0.35, 0.0, np.hypot(x + 0.2, y + 0.2))
	frames.append(shaded_rgba(round_alpha, shade))
	# 2) Lágrima con la punta ABAJO: la gota va hacia arriba (eje Y siguiendo la velocidad) y la punta
	# queda detrás.
	flipped = -y
	t = np.clip((flipped + 0.78) / 1.5, 0.0, 1.0)
	half = 0.5 * np.sin(np.pi * np.clip(t, 0.0, 1.0) ** 0.62) ** 1.1 * (0.2 + 0.8 * t)
	tear = smoothstep(0.03, -0.03, np.abs(x) - half) * smoothstep(0.0, 0.03, t) * smoothstep(1.0, 0.97, t)
	frames.append(shaded_rgba(tear, 0.68 + 0.3 * smoothstep(0.4, 0.0, np.hypot(x + 0.18, y + 0.25))))
	# 3) Alargada (rayita).
	long_half = 0.2 * np.sin(np.pi * np.clip((y + 0.9) / 1.8, 0.0, 1.0)) ** 0.8
	flick = smoothstep(0.03, -0.03, np.abs(x) - long_half)
	frames.append(shaded_rgba(flick, 0.78 - 0.15 * np.abs(x) * 3.0))
	# 4) Doble: dos gotas pegadas.
	a = smoothstep(0.34, 0.3, np.hypot(x + 0.28, y + 0.12))
	b = smoothstep(0.22, 0.18, np.hypot(x - 0.32, y - 0.3))
	frames.append(shaded_rgba(np.maximum(a, b), 0.72 + 0.25 * smoothstep(0.3, 0.0, np.hypot(x + 0.4, y + 0.2))))
	save("droplets.png", atlas(frames))


def make_ring_dust():
	"""Anillo de polvo para el suelo (aterrizaje y esquiva): borde irregular, 256 px."""
	size = 256
	x, y = grid(size)
	x = (x - 0.5) * 2.0
	y = (y - 0.5) * 2.0
	r = np.hypot(x, y)
	noise = fbm_tile(256, 1.5, 81)
	r_n = r + (noise - 0.5) * 0.22
	ring = smoothstep(0.52, 0.8, r_n) * smoothstep(1.0, 0.82, r_n)
	save("ring_dust.png", shaded_rgba(ring, 0.7 + 0.3 * smoothstep(0.52, 0.9, r_n)))


def main():
	print("Texturas de efectos de golpe en", os.path.normpath(OUT_DIR))
	make_soft_dot()
	make_flare_star()
	make_spark_streak()
	make_wisp()
	make_rays()
	make_noise()
	make_puffs()
	make_splat()
	make_shards()
	make_splinters()
	make_droplets()
	make_ring_dust()


if __name__ == "__main__":
	main()
