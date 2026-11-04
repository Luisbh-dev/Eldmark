"""Icon painting pass (ART-12): from flat layers to a drawing with material.

The vector only gives shapes and gradients. This is what separates a flat icon from the "stylised with
textures" look of docs/art.md. It is done in Python (numpy and PIL) over the layers the engine rasterises:

  - Each piece is painted from the bottom up. Before pasting it, it casts a soft occlusion onto what is already
    underneath (bottom right, like the single light): where two pieces overlap it is clear which goes
    on top.
  - Inner edge light: the relief comes from the piece's own outline (its blurred alpha) and the
    light comes from the top left. Light edge on that side, dark edge on the opposite one.
  - Grain per material: streaks in wood, brushing in metal, weave in cloth, mottling in
    stone, plus a fine brush stroke common to the whole icon set.
  - It is rasterised at 256 px and reduced to 128 (or, for the small states, to 4 times the final size).

The backgrounds per category (`make_tile`) are generated right here, without SVG: dark, muted gradient,
mottling, inner halo in the category colour and a fine iron and bronze bevel.

Everything is deterministic (seed per icon name).
"""

import math
import os
import zlib

import numpy as np
from PIL import Image

from svgkit import CATEGORIES, hex_rgb

# --------------------------------------------------------------------------------------------
# Image utilities
# --------------------------------------------------------------------------------------------


def load_rgba(path):
    return np.asarray(Image.open(path).convert("RGBA"), dtype=np.float32) / 255.0


def _kernel(sigma):
    radius = max(1, int(math.ceil(sigma * 3.0)))
    xs = np.arange(-radius, radius + 1, dtype=np.float32)
    k = np.exp(-(xs * xs) / (2.0 * sigma * sigma))
    return k / k.sum(), radius


def _blur_axis(a, sigma, axis):
    if sigma <= 0.05:
        return a
    k, radius = _kernel(sigma)
    pad = [(0, 0)] * a.ndim
    pad[axis] = (radius, radius)
    p = np.pad(a, pad, mode="edge")
    n = a.shape[axis]
    out = np.zeros_like(a)
    for i in range(2 * radius + 1):
        sl = [slice(None)] * a.ndim
        sl[axis] = slice(i, i + n)
        out += k[i] * p[tuple(sl)]
    return out


def gblur(a, sigma):
    return _blur_axis(_blur_axis(a, sigma, 0), sigma, 1)


def shift(a, dx, dy):
    """Shifts `a` by (dx, dy) px with bilinear interpolation; whatever falls off is lost."""
    h, w = a.shape[:2]
    ix, iy = int(math.floor(dx)), int(math.floor(dy))
    fx, fy = dx - ix, dy - iy

    def roll0(arr, sx, sy):
        out = np.zeros_like(arr)
        ys0, ys1 = max(0, sy), min(h, h + sy)
        xs0, xs1 = max(0, sx), min(w, w + sx)
        out[ys0:ys1, xs0:xs1] = arr[ys0 - sy:ys1 - sy, xs0 - sx:xs1 - sx]
        return out

    a00 = roll0(a, ix, iy)
    a10 = roll0(a, ix + 1, iy)
    a01 = roll0(a, ix, iy + 1)
    a11 = roll0(a, ix + 1, iy + 1)
    return (a00 * (1 - fx) * (1 - fy) + a10 * fx * (1 - fy) + a01 * (1 - fx) * fy + a11 * fx * fy)


def _resize_f(a, w, h):
    return np.asarray(Image.fromarray(a.astype(np.float32)).resize((w, h), Image.BICUBIC),
                      dtype=np.float32)


def value_noise(shape, rng, cells):
    """Smooth value noise: a random grid of `cells` x `cells` enlarged with bicubic (-0.5..0.5)."""
    h, w = shape
    small = rng.random((cells + 2, cells + 2)).astype(np.float32)
    big = _resize_f(small, int(w * (cells + 2) / cells), int(h * (cells + 2) / cells))
    ox, oy = (big.shape[1] - w) // 2, (big.shape[0] - h) // 2
    return big[oy:oy + h, ox:ox + w] - 0.5


def fbm(shape, rng, cells=(3, 6, 12, 24), decay=0.55):
    out = np.zeros(shape, np.float32)
    amp, total = 1.0, 0.0
    for c in cells:
        out += amp * value_noise(shape, rng, c)
        total += amp
        amp *= decay
    return out / total * 2.0  # approx. -1..1


def streak_noise(shape, rng, along, across, angle):
    """Noise stretched along direction `angle` (degrees, 0 = horizontal): streaks or brushing. Mean 0, sigma 1."""
    h, w = shape
    big = int(max(h, w) * 1.5)
    n = rng.standard_normal((big, big)).astype(np.float32)
    n = _blur_axis(_blur_axis(n, along, 1), across, 0)
    n /= max(float(n.std()), 1e-6)
    if angle:
        n = np.asarray(Image.fromarray(n).rotate(angle, resample=Image.BICUBIC), dtype=np.float32)
    oy, ox = (big - h) // 2, (big - w) // 2
    return n[oy:oy + h, ox:ox + w]


def weave(shape, period, angle=0.0):
    """Cloth weave (-1..1): soft grid of `period` px."""
    h, w = shape
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    ca, sa = math.cos(math.radians(angle)), math.sin(math.radians(angle))
    u = xs * ca + ys * sa
    v = -xs * sa + ys * ca
    k = 2.0 * math.pi / period
    return np.cos(u * k) * np.cos(v * k)


# --------------------------------------------------------------------------------------------
# Textures per material: they multiply the colour (relative amplitude)
# --------------------------------------------------------------------------------------------

# kind: streak (streaks), brushed (fine brushing), weave (cloth), blotch (mottling), soft (almost smooth).
# The parameters are in units of the 128 px canvas; `grain` scales to the working resolution.
TEXTURES = {
    "wood": ("streak", 0.17), "wood_dark": ("streak", 0.15), "wood_light": ("streak", 0.13),
    "leather": ("blotch", 0.13), "earth": ("blotch", 0.14),
    "steel": ("brushed", 0.06), "steel_dark": ("brushed", 0.08), "iron": ("brushed", 0.10),
    "gold": ("brushed", 0.06), "bronze": ("brushed", 0.08),
    "bone": ("blotch", 0.06), "stone": ("blotch", 0.17), "stone_dark": ("blotch", 0.17),
    "blood": ("soft", 0.05), "ice": ("soft", 0.05), "ember": ("soft", 0.06), "lime": ("soft", 0.06),
    "moss": ("blotch", 0.11), "rust": ("blotch", 0.14),
    "cloth_red": ("weave", 0.09), "cloth_blue": ("weave", 0.09), "cloth_gold": ("weave", 0.08),
    "cloth_bone": ("weave", 0.07), "cloth_gray": ("weave", 0.08),
    "skin": ("soft", 0.04), "glass": ("soft", 0.02), "dust": ("blotch", 0.08),
    "white": ("soft", 0.02), "black": ("brushed", 0.10),
}
FLAT_TEXTURE = ("soft", 0.05)


def piece_axis_angle(alpha):
    """Angle (degrees) of the piece's long axis, to align streaks with it."""
    ys, xs = np.nonzero(alpha > 0.5)
    if len(xs) < 20:
        return 0.0
    x, y = xs - xs.mean(), ys - ys.mean()
    cov = np.array([[np.mean(x * x), np.mean(x * y)], [np.mean(x * y), np.mean(y * y)]])
    vals, vecs = np.linalg.eigh(cov)
    major = vecs[:, int(np.argmax(vals))]
    return -math.degrees(math.atan2(major[1], major[0]))


def texture_field(material, alpha, rng, r):
    """Modulation field (positive and negative, already with amplitude) for a piece."""
    kind, amp = TEXTURES.get(material, FLAT_TEXTURE) if material else FLAT_TEXTURE
    shape = alpha.shape
    if kind == "streak":
        ang = piece_axis_angle(alpha)
        f = streak_noise(shape, rng, 11.0 * r, 0.9 * r, ang) * 0.75
        f += 0.45 * fbm(shape, rng, (4, 9, 18)) + 0.25 * rng.standard_normal(shape).astype(np.float32)
    elif kind == "brushed":
        ang = piece_axis_angle(alpha)
        f = streak_noise(shape, rng, 9.0 * r, 0.6 * r, ang) * 0.8
        f += 0.25 * fbm(shape, rng, (3, 7, 14))
    elif kind == "weave":
        f = weave(shape, 3.4 * r, 0.0) * 0.7 + 0.5 * fbm(shape, rng, (4, 8, 16))
        f += 0.2 * rng.standard_normal(shape).astype(np.float32)
    elif kind == "blotch":
        f = fbm(shape, rng, (3, 6, 12, 24, 48)) * 1.1
        f += 0.28 * rng.standard_normal(shape).astype(np.float32)
    else:  # soft
        f = fbm(shape, rng, (3, 6, 12)) * 0.8 + 0.2 * rng.standard_normal(shape).astype(np.float32)
    return f * amp


# --------------------------------------------------------------------------------------------
# Relief (edge light) and composition
# --------------------------------------------------------------------------------------------


def bevel(alpha, sigma):
    """Relief shading from the alpha: +1 facing the light (top left), -1 the opposite."""
    h = gblur(alpha, sigma)
    gy, gx = np.gradient(h)
    s = (gx + gy) * 0.7071 * sigma * 2.6
    return np.clip(s, -1.0, 1.0)


def _luma(c):
    return 0.2126 * c[..., 0] + 0.7152 * c[..., 1] + 0.0722 * c[..., 2]


def paint_figure(entry, root, res, seed, small=False):
    """Composes a shape from its rasterised layers. Returns an RGBA image (res x res)."""
    r = res / 128.0
    rng = np.random.default_rng(seed)
    layers = entry["layers"]
    by_kind = {}
    pieces = []
    for ly in layers:
        if ly["kind"] == "piece":
            pieces.append(ly)
        else:
            by_kind[ly["kind"]] = ly

    def read(ly):
        return load_rgba(os.path.join(root, ly["png"]))

    sil = read(by_kind["silhouette"])
    ink = np.array(hex_rgb("#1B1511"), np.float32) / 255.0
    a_can = sil[..., 3].copy()
    p_can = np.zeros(sil.shape[:2] + (3,), np.float32)
    p_can[:] = ink * a_can[..., None]

    # parameters: at small sizes there is no grain and the relief is finer and stronger
    grain_gain = 0.0 if small else 1.0
    bev_broad = (1.6 if small else 2.3) * r
    bev_fine = (0.55 if small else 0.8) * r
    ao_strength = 0.30 if small else 0.34
    ao_sigma = (1.0 if small else 2.2) * r
    ao_off = (0.5 * r, 1.0 * r) if small else (0.9 * r, 1.7 * r)
    brush = None if small else streak_noise((res, res), rng, 16.0 * r, 1.3 * r, -38.0) * 0.045

    for ly in pieces:
        img = read(ly)
        c = img[..., :3].copy()
        a = img[..., 3]
        role = ly["role"]
        op = float(ly["op"])
        thick = role in ("body", "tube")
        if role == "tube" and ly.get("sw", 0.0) < 5.0:
            thick = False
        if ly.get("relief") is not None:
            thick = bool(ly["relief"])
        if thick:
            # occlusion onto what is underneath
            occ = gblur(shift(a, ao_off[0], ao_off[1]), ao_sigma)
            p_can *= (1.0 - ao_strength * np.clip(occ * 1.25, 0.0, 1.0))[..., None]
            # grain
            if grain_gain:
                f = texture_field(ly.get("material"), a, rng, r) * grain_gain
                f += brush
                c *= (1.0 + f)[..., None]
            # inner edge light
            s = 0.65 * bevel(a, bev_broad) + 0.55 * bevel(a, bev_fine)
            lit = np.clip(s, 0.0, 1.0)[..., None]
            dark = np.clip(-s, 0.0, 1.0)[..., None]
            c = c + (1.0 - c) * lit * 0.50
            c = c * (1.0 - 0.38 * dark)
            c = np.clip(c, 0.0, 1.0)
        aa = (a * op)[..., None]
        p_can = c * aa + p_can * (1.0 - aa)
        a_can = aa[..., 0] + a_can * (1.0 - aa[..., 0])

    # shadow cast beneath everything
    shadow = read(by_kind["shadow"])[..., 3]
    sh = gblur(shadow, (0.9 if small else 1.3) * r) * (0.40 if small else 0.34)
    a_out = a_can + sh * (1.0 - a_can)
    rgb = p_can / np.maximum(a_out[..., None], 1e-5)
    out = np.dstack([np.clip(rgb, 0, 1), np.clip(a_out, 0, 1)])
    img8 = Image.fromarray((out * 255.0 + 0.5).astype(np.uint8))
    return img8


def reduce(img, side):
    """Reduces an RGBA image to `side` px (Pillow premultiplies alpha when rescaling)."""
    if img.size[0] == side:
        return img
    return img.resize((side, side), Image.LANCZOS)


# --------------------------------------------------------------------------------------------
# Backgrounds per category
# --------------------------------------------------------------------------------------------

# Warm iron and bronze of the slot (UIPalette.BORDER and BORDER_LIGHT): bevel of the background.
BEVEL_LIGHT = np.array([0.50, 0.47, 0.42], np.float32)


def make_tile(category, side=128):
    """Background of a category, full-bleed and frameless (the slot adds the border): opaque RGBA."""
    cat = CATEGORIES[category]
    seed = zlib.crc32(("tile_" + category).encode("utf-8"))
    rng = np.random.default_rng(seed)
    r = side / 128.0
    h = w = side
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    t = (ys + 0.5) / h
    top = np.array(hex_rgb(cat["top"]), np.float32) / 255.0
    bottom = np.array(hex_rgb(cat["bottom"]), np.float32) / 255.0
    glow = np.array(hex_rgb(cat["glow"]), np.float32) / 255.0
    col = top[None, None, :] * (1 - t)[..., None] + bottom[None, None, :] * t[..., None]

    # leather or stone mottling and fine brush stroke
    mott = fbm((h, w), rng, (3, 6, 12, 24, 48)) * 0.10
    brush = streak_noise((h, w), rng, 18.0 * r, 1.4 * r, -35.0) * 0.045
    grain = rng.standard_normal((h, w)).astype(np.float32) * 0.022
    col *= (1.0 + mott + brush + grain)[..., None]

    # inner halo in the category colour, behind the shape
    cx, cy = 0.49 * w, 0.44 * h
    d = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2) / (0.62 * w)
    halo = np.clip(1.0 - d, 0.0, 1.0) ** 1.7
    col += glow[None, None, :] * (0.20 * halo)[..., None]

    # inner edge: soft halo hugging the border and a fine line in the category colour
    edge = np.minimum(np.minimum(xs + 0.5, w - xs - 0.5), np.minimum(ys + 0.5, h - ys - 0.5)) / r
    col += glow[None, None, :] * (0.14 * np.exp(-edge / 6.0))[..., None]
    line = np.exp(-((edge - 5.5) ** 2) / 0.8)
    col += glow[None, None, :] * (0.20 * line)[..., None]

    # floor: the lower half darkens a little
    col *= (1.0 - 0.22 * np.clip((t - 0.45) / 0.55, 0.0, 1.0))[..., None]

    # iron and bronze bevel: light at the top and left, shadow at the bottom and right
    lit = np.clip(1.0 - np.minimum(xs / r, ys / r) / 2.4, 0.0, 1.0)
    shade = np.clip(1.0 - np.minimum((w - 1 - xs) / r, (h - 1 - ys) / r) / 2.4, 0.0, 1.0)
    col = col + (BEVEL_LIGHT[None, None, :] - col) * (0.55 * lit)[..., None]
    col *= (1.0 - 0.55 * shade)[..., None]
    out = np.dstack([np.clip(col, 0, 1), np.ones((h, w), np.float32)])
    return Image.fromarray((out * 255.0 + 0.5).astype(np.uint8))
