"""Texturas de la espada de Eldmark, generadas por código (sin fotos ni pintura a mano).

Lo usa tools/blender/build_sword.py (dentro de Blender) y también se puede ejecutar suelto con
Python 3 y numpy para ver las texturas sin abrir Blender:

    python tools/blender/sword_textures.py build/sword/tex

Cada textura es una imagen RGBA de 8 bits. Las de color (albedo) van en sRGB y las de
metal/rugosidad en lineal, empaquetadas como pide glTF: G = rugosidad, B = metálico (R = 1, sin
oclusión). Las matrices se calculan con la fila 0 en la parte de ABAJO de la imagen (v = 0 en
Blender); al guardar el PNG se voltean.

Texturas:
- hoja (256 x 512): u = posición a lo ancho de la sección (0 = filo izquierdo, 1 = filo derecho,
  fijo para cualquier ancho de la hoja), v = distancia a lo largo (0 = pomo, 1 = punta). Marca el
  brillo del bisel de filo, las caras planas, la acanaladura y el recazo.
- cuero (256 x 256): u = vuelta alrededor de la empuñadura, v = fase de la vuelta del cuero (una
  vuelta completa por unidad). Lleva dibujada la sombra entre vueltas y las puntadas.
- metal (256 x 256, atlas): mitad de abajo = metal principal (guarda, pomo, anillos), mitad de
  arriba = acento (piedras, remaches, incrustaciones).
"""

import os
import struct
import sys
import zlib

import numpy as np

# Paletas por reino, en sRGB de 0 a 1. "metal" y "acento" son el color base del metal principal y
# del secundario; el metálico y la rugosidad van aparte.
PALETTES = {
	"base": {
		"leather": (0.36, 0.21, 0.11), "thread": (0.80, 0.67, 0.46),
		"metal": (0.72, 0.75, 0.82), "metal_rough": 0.36, "metal_metallic": 0.72,
		"accent": (0.88, 0.66, 0.30), "accent_metal": 0.9, "accent_rough": 0.30,
	},
	"vardheim": {
		"leather": (0.10, 0.15, 0.28), "thread": (0.62, 0.80, 0.94),
		"metal": (0.62, 0.73, 0.90), "metal_rough": 0.36, "metal_metallic": 0.72,
		"accent": (0.42, 0.80, 1.00), "accent_metal": 0.15, "accent_rough": 0.10,
	},
	"solmarch": {
		"leather": (0.86, 0.83, 0.75), "thread": (0.86, 0.64, 0.20),
		"metal": (0.98, 0.78, 0.33), "metal_rough": 0.32, "metal_metallic": 0.80,
		"accent": (0.98, 0.95, 0.86), "accent_metal": 0.05, "accent_rough": 0.30,
	},
	"askarra": {
		"leather": (0.52, 0.07, 0.09), "thread": (0.84, 0.54, 0.26),
		"metal": (0.76, 0.45, 0.21), "metal_rough": 0.40, "metal_metallic": 0.75,
		"accent": (0.17, 0.12, 0.11), "accent_metal": 0.85, "accent_rough": 0.50,
	},
}

# Sección de la hoja: dónde (como fracción del medio ancho, 0 = eje, 1 = filo) cae cada quiebro.
# build_sword.py usa las mismas cifras para modelar la hoja, así que el brillo pintado coincide.
S_FULLER_FLOOR = 0.18
S_FULLER_RIM = 0.30
S_SHOULDER = 0.50
S_BEVEL = 0.84

# Lo que se reparte de la mitad de abajo del atlas de metal: se usa v < ATLAS_SPLIT para el metal
# principal y v >= ATLAS_SPLIT para el acento.
ATLAS_SPLIT = 0.5


def wrap_profile(p):
	"""Perfil de una vuelta de cuero, p en [0, 1): 0 en el valle entre vueltas y 1 en la cresta.

	Sube despacio hasta la cresta (cerca de p = 0,75) y baja más rápido hacia el valle, como una tira
	de cuero que monta sobre la anterior. Lo comparten la geometría y la textura para que la sombra
	pintada caiga justo en el hueco modelado.
	"""
	p = np.asarray(p, dtype=np.float64) % 1.0
	rise = np.clip(p / 0.75, 0.0, 1.0)
	fall = np.clip((1.0 - p) / 0.25, 0.0, 1.0)
	up = np.sin(rise * np.pi * 0.5) ** 0.9
	down = np.sin(fall * np.pi * 0.5) ** 1.3
	return np.where(p < 0.75, up, down)


def grid(width, height):
	"""Coordenadas (u, v) del centro de cada píxel; la fila 0 es v ≈ 0."""
	u = (np.arange(width) + 0.5) / width
	v = (np.arange(height) + 0.5) / height
	return np.meshgrid(u, v)


def fft_noise(width, height, cutoff_u, cutoff_v, seed):
	"""Ruido que se repite sin costuras, de -1 a 1 aproximado.

	cutoff_u y cutoff_v son ciclos por textura: valores bajos dan manchas grandes, altos dan grano.
	"""
	rng = np.random.default_rng(seed)
	spectrum = np.fft.fft2(rng.standard_normal((height, width)))
	ky = np.fft.fftfreq(height)[:, None] * height
	kx = np.fft.fftfreq(width)[None, :] * width
	spectrum *= np.exp(-((kx / cutoff_u) ** 2 + (ky / cutoff_v) ** 2))
	out = np.real(np.fft.ifft2(spectrum))
	out /= max(float(out.std()) * 3.0, 1e-9)
	return np.clip(out, -1.0, 1.0)


def _smooth(edge0, edge1, x):
	t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


def _pack(color, rough, metal):
	"""Apila albedo (sRGB) y metal/rugosidad (lineal) en dos RGBA de 8 bits."""
	height, width = rough.shape
	albedo = np.concatenate([np.clip(color, 0.0, 1.0), np.ones((height, width, 1))], axis=2)
	mr = np.stack([np.ones_like(rough), np.clip(rough, 0.0, 1.0), np.clip(metal, 0.0, 1.0),
			np.ones_like(rough)], axis=2)
	return (albedo * 255.0 + 0.5).astype(np.uint8), (mr * 255.0 + 0.5).astype(np.uint8)


def blade_textures(width=256, height=512):
	"""Acero con degradado a lo largo, bisel de filo brillante y acanaladura más apagada."""
	u, v = grid(width, height)
	s = np.abs(2.0 * u - 1.0)  # 0 en el eje, 1 en el filo
	# Brillo por zona de la sección (ver build_sword.py): acanaladura, cara plana, bisel mayor y
	# bisel de filo. Las transiciones son cortas pero no de un píxel, para que no centelleen.
	ff, rim, sh, bev = S_FULLER_FLOOR, S_FULLER_RIM, S_SHOULDER, S_BEVEL
	stops_s = [0.00, ff - 0.015, ff + 0.01, rim - 0.01, rim + 0.015, sh - 0.015, sh + 0.015,
			bev - 0.015, bev + 0.015, 0.97, 1.00]
	stops_tone = [0.52, 0.54, 0.40, 0.40, 0.62, 0.64, 0.80, 0.82, 0.97, 1.00, 1.00]
	tone = np.interp(s, stops_s, stops_tone)
	stops_r = [0.00, ff - 0.015, ff + 0.01, rim + 0.015, sh + 0.015, bev - 0.015, bev + 0.015,
			0.97, 1.00]
	stops_rough = [0.46, 0.46, 0.52, 0.42, 0.38, 0.36, 0.28, 0.20, 0.20]
	rough = np.interp(s, stops_r, stops_rough)
	# Degradado a lo largo: más frío y oscuro junto a la guarda, más claro y cálido hacia la punta.
	along = _smooth(0.05, 0.95, v)
	cool = np.array([0.86, 0.92, 1.00])
	mid = np.array([0.96, 0.98, 1.00])
	warm = np.array([1.00, 0.99, 0.95])
	tint = np.where((along < 0.5)[..., None],
			cool + (mid - cool) * (along / 0.5)[..., None],
			mid + (warm - mid) * ((along - 0.5) / 0.5)[..., None])
	tone = tone * (0.94 + 0.10 * along)
	# Recazo (junto a la guarda, sin filo): más opaco y azulado.
	ricasso = 1.0 - _smooth(0.14, 0.22, v)
	tone = tone * (1.0 - 0.10 * ricasso)
	tint = tint * (1.0 - ricasso[..., None]) + np.array([0.84, 0.88, 0.96]) * ricasso[..., None]
	# Pulido en cepillo: rayas finas a lo largo, y un grano casi invisible.
	brushed = fft_noise(width, height, 70.0, 4.0, 11)
	grain = fft_noise(width, height, 100.0, 100.0, 12)
	tone = tone + brushed * 0.035 + grain * 0.012
	# Punta más viva.
	tone = tone + 0.05 * _smooth(0.90, 0.99, v)
	color = np.clip(tone[..., None] * tint, 0.0, 1.0)
	rough = rough + brushed * 0.05
	metal = np.full_like(rough, 0.80)
	# Una muesca fina de acabado en el filo, cerca del recazo.
	mark = np.exp(-(((v - 0.205) / 0.006) ** 2)) * (s < 0.95)
	color = color * (1.0 - 0.18 * mark[..., None])
	return _pack(color, rough, metal)


def leather_textures(palette, width=256, height=256):
	"""Cuero de una vuelta por unidad de v: sombra entre vueltas, grano y puntadas."""
	u, v = grid(width, height)
	base = np.array(PALETTES[palette]["leather"])
	thread = np.array(PALETTES[palette]["thread"])
	profile = wrap_profile(v)
	occlusion = 0.42 + 0.58 * profile ** 0.8
	# Luz de la cresta: sube un poco el color donde la tira es más alta.
	shade = occlusion * (0.88 + 0.16 * profile)
	grain = fft_noise(width, height, 80.0, 80.0, 21) * 0.07
	mottling = fft_noise(width, height, 7.0, 5.0, 22) * 0.10
	# Arrugas del cuero: finas y casi paralelas a la vuelta.
	wrinkle = fft_noise(width, height, 36.0, 6.0, 23) * 0.05
	color = base[None, None, :] * (shade * (1.0 + grain + mottling + wrinkle))[..., None]
	# Puntadas: trazos alternos junto al valle (v ≈ 0,06).
	dash = (np.floor(u * 24.0) % 2 == 0).astype(np.float64)
	stitch_band = np.exp(-(((v - 0.07) / 0.022) ** 2))
	stitch = stitch_band * (0.55 + 0.45 * dash) * 0.85
	color = color * (1.0 - stitch[..., None]) + thread[None, None, :] * stitch[..., None] * 0.9
	# Borde del cuero algo más claro (desgaste) en la cresta.
	edge = np.exp(-(((v - 0.76) / 0.05) ** 2)) * 0.10
	color = color + edge[..., None] * 0.35
	rough = 0.74 + fft_noise(width, height, 40.0, 40.0, 24) * 0.10 - 0.08 * profile
	metal = np.zeros_like(rough)
	return _pack(color, rough, metal)


def metal_textures(palette, width=256, height=256):
	"""Atlas de metal: abajo el principal (guarda, pomo), arriba el acento (piedras, remaches)."""
	u, v = grid(width, height)
	spec = PALETTES[palette]
	main = np.array(spec["metal"])
	accent = np.array(spec["accent"])
	brushed = fft_noise(width, height, 3.0, 80.0, 31)
	grain = fft_noise(width, height, 90.0, 90.0, 32)
	blotch = fft_noise(width, height, 5.0, 5.0, 33)
	variation = 1.0 + brushed * 0.045 + grain * 0.02 + blotch * 0.07
	top = v >= ATLAS_SPLIT
	base_color = np.where(top[..., None], accent[None, None, :], main[None, None, :])
	color = base_color * variation[..., None]
	# El borde de cada mitad se oscurece un pelo para que no se mezclen al filtrar.
	rough = np.where(top, spec["accent_rough"], spec["metal_rough"]) + blotch * 0.06 + grain * 0.03
	metal = np.where(top, spec["accent_metal"], spec["metal_metallic"]) + np.zeros_like(rough)
	return _pack(color, rough, metal)


def write_png(path, rgba):
	"""Guarda un RGBA uint8 (fila 0 = abajo) como PNG sin dependencias."""
	data = np.flipud(rgba)
	height, width, channels = data.shape
	raw = b"".join(b"\x00" + data[row].tobytes() for row in range(height))

	def chunk(kind, payload):
		body = kind + payload
		return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

	color_type = {3: 2, 4: 6}[channels]
	header = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
	png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) \
			+ chunk(b"IEND", b"")
	with open(path, "wb") as handle:
		handle.write(png)


def write_all(out_dir):
	"""Escribe todas las texturas en out_dir y devuelve {nombre: ruta}."""
	os.makedirs(out_dir, exist_ok=True)
	paths = {}

	def save(name, pair):
		albedo, mr = pair
		for suffix, image in (("albedo", albedo), ("mr", mr)):
			path = os.path.join(out_dir, "%s_%s.png" % (name, suffix))
			write_png(path, image)
			paths["%s_%s" % (name, suffix)] = path

	save("blade", blade_textures())
	for palette in PALETTES:
		save("leather_" + palette, leather_textures(palette))
		save("metal_" + palette, metal_textures(palette))
	return paths


if __name__ == "__main__":
	target = sys.argv[1] if len(sys.argv) > 1 else "build/sword/tex"
	for key, value in write_all(target).items():
		print(key, value)
