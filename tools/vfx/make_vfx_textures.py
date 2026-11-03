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

# Texto de los .import que se escriben junto a cada PNG nuevo: sin compresión de VRAM y con mipmaps.
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
	# El .import solo se escribe si no existe: Godot le añade un uid propio al importar y reescribirlo en cada
	# ejecución se lo cambiaría a la textura (y a todo lo que la referencia por uid).
	if not os.path.exists(path + ".import"):
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


def make_puffs():
	"""Cuatro bocanadas de polvo con volumen, en un atlas de 2 x 2 casillas de 256 px (512 x 512).

	No llevan el color cocinado: son datos para el sombreador con luz (vfx_particle_lit):
	    R = altura del relieve (0 fuera de la bocanada, 1 en la cima de los lóbulos); de ella sale la
	        normal, así el sol la modela y la sombra la oscurece;
	    G = ruido fino (la erosión: la bocanada se deshace desde el borde, no baja el alfa de golpe);
	    B = ruido de remolino, que desplaza la erosión para que cada copia se rompa distinta;
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
			# Cada lóbulo es una media esfera: el borde arrugado con ruido de dos escalas.
			d = np.hypot(x - cx, y - cy) / radius + (coarse - 0.5) * 0.3 + (fine - 0.5) * 0.12
			domes.append(np.sqrt(np.clip(1.0 - d * d, 0.0, 1.0)))
		# Máximo suave de las medias esferas: entre lóbulo y lóbulo queda un pliegue, como en una coliflor.
		smooth = np.log(np.sum([np.exp(7.0 * dome) for dome in domes], axis=0)) / 7.0 - math.log(lobes) / 7.0
		height = smooth / smooth.max()
		height = height * (0.88 + 0.24 * (fine - 0.5)) * smoothstep(1.0, 0.82, np.hypot(x, y))
		height = np.clip(blur(height, 1), 0.0, 1.0)
		detail = fbm_tile(size, 1.15, 160 + index)
		swirl = fbm_tile(size, 1.7, 180 + index)
		frames.append(np.stack([height, detail, swirl, np.ones_like(height)], axis=-1))
	save("puffs.png", atlas(frames))


def make_splat_jets():
	"""Chorros de salpicadura en secuencia, para el golpe en carne: 4 variantes (filas) por 5 fotogramas
	(columnas), casillas de 128 px, 640 x 512. El chorro sale del centro de la casilla hacia +X (el
	sombreador la gira hacia la dirección del golpe).

	    R = sombreado (1 = claro; el centro del chorro es más claro, da grosor de líquido);
	    G = brillo especular (un reflejo alargado en el chorro y un punto en cada gota);
	    A = silueta.
	Cada fotograma es un instante del chorro: nace como una mancha gorda, se estira, se estrecha y se
	rompe en gotas alargadas por delante."""
	cell = 128
	X0 = -0.72  # el chorro nace cerca del borde izquierdo de la casilla (el sombreador la desplaza)
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
			# Mancha del impacto, que se encoge y se aclara con el tiempo.
			blob_r = 0.15 * (1.0 - 0.55 * t) * thick
			blob = smoothstep(blob_r, blob_r * 0.55, np.hypot(x - X0, y * 1.1))
			blob *= 1.0 - 0.7 * smoothstep(0.5, 1.0, t)
			alpha = np.maximum(alpha, blob)
			shade = np.maximum(shade, blob * 0.8)
			# Gotas por delante: aparecen según avanza el chorro, alargadas en el sentido del movimiento.
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
			# Se apaga por los bordes de la casilla.
			window = smoothstep(1.0, 0.86, np.hypot(x, y))
			alpha = alpha * window
			rgba = np.stack([0.5 + 0.5 * shade, spec, np.zeros_like(shade), alpha], axis=-1)
			sheet[variant * cell:(variant + 1) * cell, f * cell:(f + 1) * cell] = rgba
	save("splat_jets.png", sheet)


def make_planks():
	"""Cuatro tablillas de madera planas, atlas de 2 x 2 casillas de 128 px (256 x 256). Cada una es un
	trozo plano de tabla: un extremo cortado en bisel, el otro roto en dientes, con veta a lo largo.

	    R = sombreado (veta, borde oscuro);
	    G = madera fresca (1 en la rotura, donde la madera sin curtir es clara); el sombreador la tiñe con
	        un segundo tono ([accent]), así la tabla tiene dos tonos de madera;
	    A = silueta."""
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
		# Extremo izquierdo cortado en bisel; derecho roto en dientes.
		outline = [pt(-half_l + bevel, -half_w), pt(half_l * 0.9, -half_w)]
		teeth = int(rng.integers(3, 6))
		for tooth in range(teeth + 1):
			v = -half_w + width * tooth / teeth
			u = half_l - rng.uniform(0.0, 0.14) * length * (1 if tooth % 2 else 0.35)
			outline.append(pt(u, v))
		outline.append(pt(-half_l, half_w))
		outline.append(pt(-half_l, half_w - bevel * 0.5))
		draw_a.polygon(outline, fill=255)
		# Madera fresca: el extremo roto y una franja del bisel.
		draw_f.polygon([pt(half_l * 0.38, -half_w * 1.2), pt(half_l * 1.1, -half_w * 1.2),
				pt(half_l * 1.1, half_w * 1.2), pt(half_l * 0.38, half_w * 1.2)], fill=255)
		draw_f.polygon([pt(-half_l * 1.05, half_w * 1.1), pt(-half_l + bevel * 1.3, half_w * 1.1),
				pt(-half_l + bevel * 0.2, -half_w * 1.1), pt(-half_l * 1.05, -half_w * 1.1)], fill=140)
		alpha = np.asarray(alpha_img.resize((size, size), Image.LANCZOS), dtype=np.float32) / 255.0
		fresh = np.asarray(fresh_img.resize((size, size), Image.LANCZOS), dtype=np.float32) / 255.0
		fresh = blur(fresh, 2) * (alpha > 0.02)
		gx, gy = grid(size)
		noise = fbm_tile(size, 1.1, 400 + index)
		# Veta a lo largo de la tabla (el eje del plano es x girado por [angle]).
		v = -(gx - 0.5) * sa + (gy - 0.5) * ca
		grain = 0.5 + 0.5 * np.sin(v * 70.0 + noise * 10.0)
		grain = 0.7 + 0.22 * grain + 0.12 * (noise - 0.5)
		# Borde oscuro: el contorno de la tabla se hunde en sombra.
		inner = blur(alpha, 4)
		edge = 0.62 + 0.38 * smoothstep(0.55, 0.98, inner)
		shade = grain * edge
		frames.append(np.stack([shade, fresh, np.zeros_like(shade), alpha], axis=-1))
	save("planks.png", atlas(frames))


def make_fibers():
	"""Cuatro hilachas de tela (hebras finas y rizadas), atlas de 2 x 2 casillas de 128 px (256 x 256).
	R = sombreado, A = silueta."""
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
	"""Anillo de polvo bajo para el suelo (solo caídas fuertes): estrecho, sin borde duro, con grumos."""
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
	# Las que ya no se usan se borran para que la carpeta sea justo lo que genera este script.
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
