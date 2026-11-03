#!/usr/bin/env python3
"""Genera las texturas propias del torreón del fuerte (ART-57) con numpy y PIL.

No hay IA ni fotos: todo sale de ruido periódico filtrado por FFT, trazos de cincel y una
derivada para el relieve. Las texturas se pueden repetir sin costuras (el ruido es periódico),
y cada sillar de la malla usa una ventana aleatoria distinta de la misma baldosa.

Salida, en assets/models/environment/custom/fort_keep/textures/:

    keep_stone_albedo.jpg / keep_stone_normal.png   sillar de cara (gris cálido, grano y cincel)
    keep_trim_albedo.jpg  / keep_trim_normal.png    piedra labrada más clara y lisa (cornisas)
    keep_banner_albedo.png                           tela de estandarte con tejido y dobladillo
    keep_textures.txt                                luminancias medias (para realm_surface)

Uso, desde la raíz del repo y antes de build_fort_keep.py:

    python tools/blender/make_fort_keep_textures.py

Es determinista (semillas fijas). Normales en convención OpenGL (verde hacia arriba), la de
Godot y glTF.
"""

import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(
		HERE, "..", "..", "assets", "models", "environment", "custom", "fort_keep", "textures"))
SIZE = 1024


def fft_noise(n: int, beta: float, seed: int) -> np.ndarray:
	"""Ruido periódico con espectro 1/f^beta, normalizado a media 0 y desviación 1."""
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


def strokes(n: int, count: int, length: tuple, angle: float, spread: float,
		seed: int, width: float = 1.4) -> np.ndarray:
	"""Trazos cortos de cincel (altura 0..1 acumulada), envolviendo en los bordes."""
	rng = np.random.default_rng(seed)
	canvas = np.zeros((n, n), dtype=np.float32)
	for _ in range(count):
		cx = rng.uniform(0, n)
		cy = rng.uniform(0, n)
		ln = rng.uniform(*length)
		a = angle + rng.normal(0.0, spread)
		dx, dy = np.cos(a), np.sin(a)
		steps = int(ln * 1.5)
		t = np.linspace(-ln / 2, ln / 2, steps)
		amp = rng.uniform(0.35, 1.0)
		for w in (-width * 0.5, 0.0, width * 0.5):
			xs = ((cx + dx * t - dy * w) % n).astype(int)
			ys = ((cy + dy * t + dx * w) % n).astype(int)
			canvas[ys, xs] = np.maximum(canvas[ys, xs], amp * (1.0 - abs(w) / (width + 0.5)))
	return canvas


def blur(img: np.ndarray, radius: float) -> np.ndarray:
	"""Desenfoque gaussiano periódico por FFT."""
	fx = np.fft.fftfreq(img.shape[0])[:, None]
	fy = np.fft.fftfreq(img.shape[1])[None, :]
	kernel = np.exp(-2.0 * (np.pi ** 2) * (radius ** 2) * (fx * fx + fy * fy))
	return np.real(np.fft.ifft2(np.fft.fft2(img) * kernel))


def normal_from_height(h: np.ndarray, strength: float) -> np.ndarray:
	"""Mapa de normales OpenGL (X a la derecha, Y hacia arriba de la imagen) desde una altura."""
	dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5
	d_row = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5
	nx = -dx * strength
	ny = d_row * strength
	nz = np.ones_like(h)
	length = np.sqrt(nx * nx + ny * ny + nz * nz)
	out = np.stack([nx / length, ny / length, nz / length], axis=-1)
	return ((out * 0.5 + 0.5) * 255.0).clip(0, 255).astype(np.uint8)


def save_rgb(path: str, array: np.ndarray) -> None:
	image = Image.fromarray(array, "RGB")
	if path.endswith(".jpg"):
		image.save(path, quality=93, subsampling=0, optimize=True)
	else:
		image.save(path, optimize=True)


def stone(seed: int, base: float, contrast: float, warm: float, tooling: float) -> tuple:
	"""Piedra de cara: manchas grandes, grano medio, cincelado y poros. Devuelve (albedo, altura)."""
	n = SIZE
	blotch = fft_noise(n, 2.6, seed)          # manchas grandes de tono
	mid = fft_noise(n, 1.7, seed + 1)          # grano medio
	fine = fft_noise(n, 0.5, seed + 2)         # grano fino (casi blanco)
	tint = fft_noise(n, 3.0, seed + 3)         # deriva cálida / fría
	chisel = strokes(n, int(2600 * tooling), (28.0, 80.0), np.deg2rad(32.0), 0.35, seed + 4)
	chisel = blur(chisel, 0.8)
	pits = (fft_noise(n, 0.8, seed + 5) > 1.9).astype(np.float32)
	pits = blur(pits, 1.2) * 3.0
	scuff = np.clip(fft_noise(n, 1.2, seed + 6) - 1.1, 0.0, None)  # rozaduras claras

	lum = base + contrast * (0.55 * blotch * 0.075 + 0.35 * mid * 0.04 + 0.10 * fine * 0.012)
	lum = lum + 0.022 * chisel - 0.05 * pits + 0.03 * scuff
	lum = np.clip(lum, 0.05, 0.95)
	r = lum * (1.0 + warm * tint * 0.035 + 0.02)
	g = lum * (1.0 + warm * tint * 0.008)
	b = lum * (1.0 - warm * tint * 0.035 - 0.02)
	albedo = (np.stack([r, g, b], axis=-1).clip(0, 1) * 255.0).astype(np.uint8)
	height = 0.35 * mid + 0.15 * fine + 1.1 * chisel - 1.4 * pits + 0.5 * blotch * 0.3
	return albedo, height


def banner(seed: int) -> np.ndarray:
	"""Tela del gallardete (relación 3,5 : 1,55, de ahí 1024 x 448) con tejido, pliegues, dobladillo
	y un dibujo heráldico sencillo en tonos oscuros: banda con punta de lanza y dos listones.
	Se recolorea por bando con realm_surface (faction_color); en el glTF queda color hueso."""
	from PIL import ImageDraw
	w, h = 1024, 448
	weave_x = np.sin(np.arange(w) * np.pi / 2.0)[None, :]
	weave_y = np.sin(np.arange(h) * np.pi / 2.0 + 1.0)[:, None]
	weave = 0.5 + 0.25 * weave_x * weave_y
	folds = fft_noise(1024, 3.2, seed)[:h, :w]
	lum = 0.80 + 0.020 * (weave - 0.5) * 4.0 + 0.035 * folds
	art = Image.new("L", (w, h), 255)
	draw = ImageDraw.Draw(art)
	hem = int(h * 0.075)
	draw.rectangle([0, 0, w, hem], fill=170)
	draw.rectangle([0, h - hem, w, h], fill=170)
	draw.rectangle([0, hem + 10, w, hem + 20], fill=120)
	draw.rectangle([0, h - hem - 20, w, h - hem - 10], fill=120)
	mid = h // 2
	draw.rectangle([60, mid - 46, 700, mid + 46], fill=110)
	draw.polygon([(700, mid - 92), (840, mid), (700, mid + 92)], fill=110)
	draw.rectangle([60, mid - 12, 700, mid + 12], fill=190)
	draw.ellipse([120, mid - 30, 180, mid + 30], fill=200)
	mask = np.asarray(art, dtype=np.float32) / 255.0
	mask = blur(mask, 1.2)
	lum = lum * (0.45 + 0.55 * mask)
	img = np.stack([lum, lum * 0.97, lum * 0.92], axis=-1)
	return (img.clip(0, 1) * 255.0).astype(np.uint8)


def luminance(rgb: np.ndarray) -> float:
	f = rgb.astype(np.float32) / 255.0
	return float((0.299 * f[..., 0] + 0.587 * f[..., 1] + 0.114 * f[..., 2]).mean())


def main() -> None:
	os.makedirs(OUT_DIR, exist_ok=True)
	report = []

	albedo, height = stone(seed=2610, base=0.50, contrast=1.0, warm=0.55, tooling=1.0)
	save_rgb(os.path.join(OUT_DIR, "keep_stone_albedo.jpg"), albedo)
	save_rgb(os.path.join(OUT_DIR, "keep_stone_normal.png"), normal_from_height(height, 1.1))
	report.append("keep_stone_albedo luminancia media %.4f" % luminance(albedo))

	albedo, height = stone(seed=4807, base=0.60, contrast=0.55, warm=0.30, tooling=0.35)
	# Piedra labrada: líneas finas horizontales de maza, casi lisa.
	rows = np.sin(np.arange(SIZE) * 0.55)[:, None] * np.ones((1, SIZE)) * 0.012
	albedo = (albedo.astype(np.float32) * (1.0 + rows[..., None])).clip(0, 255).astype(np.uint8)
	save_rgb(os.path.join(OUT_DIR, "keep_trim_albedo.jpg"), albedo)
	save_rgb(os.path.join(OUT_DIR, "keep_trim_normal.png"), normal_from_height(height * 0.6 + rows * 6.0, 1.0))
	report.append("keep_trim_albedo luminancia media %.4f" % luminance(albedo))

	cloth = banner(seed=77)
	save_rgb(os.path.join(OUT_DIR, "keep_banner_albedo.png"), cloth)
	report.append("keep_banner_albedo luminancia media %.4f" % luminance(cloth))

	with open(os.path.join(OUT_DIR, "keep_textures.txt"), "w", encoding="utf-8") as handle:
		handle.write("\n".join(report) + "\n")
	print("\n".join(report))


if __name__ == "__main__":
	main()
