"""Drawing kit for the interface icons (ART-12): geometry, materials and SVG layers.

Everything is drawn on a 128 x 128 canvas with a single style:

  - A single light at the top left: each material is a gradient from light to dark in that
    direction, and the paint pass (`paint.py`) adds inner edge light on that same side.
  - Strong silhouette: each shape carries a dark outline of a single thickness and a shadow cast
    towards the bottom right, so that it reads small whatever the background.
  - Colours from the game's palette (desaturated): no violet and no nearly pure materials. The backgrounds
    per category are not here but in `paint.py`, because the shape is exported on its own, without a background.

This module does not write the final icon: it splits each shape into LAYERS (shadow, silhouette and one per piece)
and sends them to be rasterised by the engine (`rasterize_icons.gd`). `paint.py` composes them with grain,
occlusion between pieces and edge light. The transformations are applied to the points when building the
path, not with `transform`, so the gradients always face the same side even if the shape
is rotated.

It only uses what ThorVG (Godot's rasteriser) draws well: paths, linear gradients, stroke and
groups with a transform. No filters or masks.
"""

import math

from PIL import Image, ImageDraw

# --------------------------------------------------------------------------------------------
# Geometry
# --------------------------------------------------------------------------------------------


def _num(value):
    text = "%.2f" % value
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


class Xf:
    """2D affine transform: x' = a x + c y + e, y' = b x + d y + f."""

    __slots__ = ("a", "b", "c", "d", "e", "f")

    def __init__(self, a=1.0, b=0.0, c=0.0, d=1.0, e=0.0, f=0.0):
        self.a, self.b, self.c, self.d, self.e, self.f = a, b, c, d, e, f

    def __call__(self, x, y):
        return (self.a * x + self.c * y + self.e, self.b * x + self.d * y + self.f)

    def __matmul__(self, other):
        """`self @ other`: applies `other` first and then `self`."""
        return Xf(
            self.a * other.a + self.c * other.b,
            self.b * other.a + self.d * other.b,
            self.a * other.c + self.c * other.d,
            self.b * other.c + self.d * other.d,
            self.a * other.e + self.c * other.f + self.e,
            self.b * other.e + self.d * other.f + self.f,
        )


IDENT = Xf()


def move(x, y):
    return Xf(e=x, f=y)


def rot(deg, cx=0.0, cy=0.0):
    """Rotation by `deg` degrees (positive = clockwise on screen) around (cx, cy)."""
    r = math.radians(deg)
    c, s = math.cos(r), math.sin(r)
    return move(cx, cy) @ Xf(c, s, -s, c) @ move(-cx, -cy)


def scale(sx, sy=None, cx=0.0, cy=0.0):
    sy = sx if sy is None else sy
    return move(cx, cy) @ Xf(sx, 0.0, 0.0, sy) @ move(-cx, -cy)


def flip_h(cx=64.0):
    """Horizontal mirror about the vertical x = cx."""
    return Xf(-1.0, 0.0, 0.0, 1.0, 2.0 * cx, 0.0)


# --------------------------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------------------------


class Path:
    """Path with absolute commands; each point goes through the transform `xf`.

    Besides the SVG string it keeps a flattened version (`polys`) to measure the silhouette without
    rasterising with the engine.
    """

    def __init__(self, xf=IDENT):
        self.xf = xf
        self.cmds = []
        self.cur = None
        self.polys = []  # [[points], closed]
        self._last = None

    def _p(self, x, y):
        px, py = self.xf(x, y)
        return "%s %s" % (_num(px), _num(py))

    def M(self, x, y):
        self.cmds.append("M" + self._p(x, y))
        self.cur = (x, y)
        self._last = self.xf(x, y)
        self.polys.append([[self._last], False])
        return self

    def L(self, x, y):
        self.cmds.append("L" + self._p(x, y))
        self.cur = (x, y)
        self._last = self.xf(x, y)
        self.polys[-1][0].append(self._last)
        return self

    def C(self, x1, y1, x2, y2, x, y):
        self.cmds.append("C%s %s %s" % (self._p(x1, y1), self._p(x2, y2), self._p(x, y)))
        p0 = self._last
        p1, p2, p3 = self.xf(x1, y1), self.xf(x2, y2), self.xf(x, y)
        for i in range(1, 15):
            t = i / 14.0
            u = 1.0 - t
            self.polys[-1][0].append((
                u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
                u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1]))
        self.cur = (x, y)
        self._last = p3
        return self

    def Q(self, x1, y1, x, y):
        self.cmds.append("Q%s %s" % (self._p(x1, y1), self._p(x, y)))
        p0 = self._last
        p1, p2 = self.xf(x1, y1), self.xf(x, y)
        for i in range(1, 11):
            t = i / 10.0
            u = 1.0 - t
            self.polys[-1][0].append((u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
                                      u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]))
        self.cur = (x, y)
        self._last = p2
        return self

    def Z(self):
        self.cmds.append("Z")
        if self.polys:
            self.polys[-1][1] = True
        return self

    def arc(self, cx, cy, rx, ry, a0, a1, rot_deg=0.0):
        """Elliptical arc from `a0` to `a1` degrees (0 = right, 90 = down), as cubic curves.

        If the path is empty it opens with M; otherwise it joins with L to the start of the arc.
        """
        steps = max(1, int(math.ceil(abs(a1 - a0) / 90.0)))
        da = (a1 - a0) / steps
        cr, sr = math.cos(math.radians(rot_deg)), math.sin(math.radians(rot_deg))

        def pt(angle):
            ex = rx * math.cos(math.radians(angle))
            ey = ry * math.sin(math.radians(angle))
            return (cx + ex * cr - ey * sr, cy + ex * sr + ey * cr)

        def tan(angle):
            ex = -rx * math.sin(math.radians(angle))
            ey = ry * math.cos(math.radians(angle))
            return (ex * cr - ey * sr, ex * sr + ey * cr)

        k = 4.0 / 3.0 * math.tan(math.radians(da) / 4.0)
        start = pt(a0)
        if not self.cmds:
            self.M(*start)
        else:
            self.L(*start)
        for i in range(steps):
            t0, t1 = a0 + i * da, a0 + (i + 1) * da
            p0, p1 = pt(t0), pt(t1)
            d0, d1 = tan(t0), tan(t1)
            self.C(p0[0] + k * d0[0], p0[1] + k * d0[1], p1[0] - k * d1[0], p1[1] - k * d1[1],
                   p1[0], p1[1])
        return self

    def d(self):
        return " ".join(self.cmds)


def poly(points, xf=IDENT, close=True):
    path = Path(xf)
    for i, (x, y) in enumerate(points):
        path.M(x, y) if i == 0 else path.L(x, y)
    if close:
        path.Z()
    return path


def rpoly(points, radius, xf=IDENT):
    """Polygon with rounded corners (a single `radius` or one per vertex)."""
    n = len(points)
    radii = radius if isinstance(radius, (list, tuple)) else [radius] * n
    path = Path(xf)
    for i in range(n):
        p_prev, p, p_next = points[i - 1], points[i], points[(i + 1) % n]
        r = radii[i]
        v1 = (p_prev[0] - p[0], p_prev[1] - p[1])
        v2 = (p_next[0] - p[0], p_next[1] - p[1])
        l1, l2 = math.hypot(*v1), math.hypot(*v2)
        cut = min(r, l1 * 0.5, l2 * 0.5)
        if cut <= 0.01 or l1 == 0 or l2 == 0:
            a = b = p
        else:
            a = (p[0] + v1[0] / l1 * cut, p[1] + v1[1] / l1 * cut)
            b = (p[0] + v2[0] / l2 * cut, p[1] + v2[1] / l2 * cut)
        if i == 0:
            path.M(*a)
        else:
            path.L(*a)
        if a != b:
            path.Q(p[0], p[1], b[0], b[1])
    path.Z()
    return path


def rect(x, y, w, h, r=0.0, xf=IDENT):
    return rpoly([(x, y), (x + w, y), (x + w, y + h), (x, y + h)], r, xf)


def ellipse(cx, cy, rx, ry=None, xf=IDENT):
    ry = rx if ry is None else ry
    k = 0.5522847498
    path = Path(xf)
    path.M(cx + rx, cy)
    path.C(cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry)
    path.C(cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy)
    path.C(cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry)
    path.C(cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy)
    path.Z()
    return path


def star(cx, cy, r_out, r_in, n=5, start_deg=-90.0, xf=IDENT, round_r=0.0):
    pts = []
    for i in range(n * 2):
        ang = math.radians(start_deg + i * 180.0 / n)
        r = r_out if i % 2 == 0 else r_in
        pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
    return rpoly(pts, round_r, xf) if round_r > 0 else poly(pts, xf)


def curve_band(p0, c, p2, w_mid, w_end, xf=IDENT, n=28):
    """Variable-thickness band around the quadratic curve p0-c-p2 (thinner at the ends)."""
    left, right = [], []
    for i in range(n + 1):
        t = i / float(n)
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * c[0] + t * t * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * c[1] + t * t * p2[1]
        dx = 2 * (1 - t) * (c[0] - p0[0]) + 2 * t * (p2[0] - c[0])
        dy = 2 * (1 - t) * (c[1] - p0[1]) + 2 * t * (p2[1] - c[1])
        length = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / length, dx / length
        half = (w_end + (w_mid - w_end) * math.sin(math.pi * t)) / 2.0
        left.append((x + nx * half, y + ny * half))
        right.append((x - nx * half, y - ny * half))
    return poly(left + right[::-1], xf)


def polar(cx, cy, r, deg):
    return (cx + r * math.cos(math.radians(deg)), cy + r * math.sin(math.radians(deg)))


# --------------------------------------------------------------------------------------------
# Colour
# --------------------------------------------------------------------------------------------


def hex_rgb(color):
    return tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))


def rgb_hex(rgb):
    return "#%02X%02X%02X" % tuple(max(0, min(255, int(round(c)))) for c in rgb)


def mix(a, b, t):
    """Mixes `a` and `b` (t = 0 gives a, t = 1 gives b)."""
    ra, rb = hex_rgb(a), hex_rgb(b)
    return rgb_hex([ra[i] + (rb[i] - ra[i]) * t for i in range(3)])


def darken(color, t):
    return mix(color, "#000000", t)


def lighten(color, t):
    return mix(color, "#FFFFFF", t)


def desaturate(color, amount):
    """Moves `color` towards its grey of equal luminance (amount = 0 leaves it alone, 1 gives the grey)."""
    r, g, b = hex_rgb(color)
    gray = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return rgb_hex([c + (gray - c) * amount for c in (r, g, b)])


def hsv(color):
    r, g, b = [c / 255.0 for c in hex_rgb(color)]
    mx, mn = max(r, g, b), min(r, g, b)
    return (0.0 if mx == 0 else (mx - mn) / mx), mx


# Raw materials: (light, mid, dark). The gradient goes from top left (light) to bottom
# right (dark), the single light source of the icon set.
_MATERIALS_RAW = {
    "steel": ("#F2F6FA", "#B4C1CF", "#66768A"),
    "steel_dark": ("#B4C1CF", "#788799", "#424D5D"),
    "iron": ("#9AA3B0", "#646D7B", "#363C47"),
    "wood": ("#C98F55", "#97602F", "#5A3416"),
    "wood_dark": ("#9C6A3C", "#69401D", "#3A210C"),
    "wood_light": ("#F3D39A", "#D39C55", "#92602A"),
    "leather": ("#B07A46", "#7D5028", "#432A12"),
    "gold": ("#FFE9A0", "#E3AE32", "#A5681A"),
    "bronze": ("#F0B672", "#C07A38", "#7C4318"),
    "bone": ("#FFFBEC", "#E4D8B8", "#A99C7C"),
    "stone": ("#C9C3B6", "#948E81", "#5C574E"),
    "stone_dark": ("#9B968A", "#69645A", "#403C36"),
    "blood": ("#FF7468", "#D3231F", "#7E0B10"),
    "ice": ("#EAFBFF", "#7FCBEF", "#2F7FB8"),
    "ember": ("#FFE08A", "#F08A2A", "#B8400E"),
    "lime": ("#E8FFB0", "#9BD83A", "#4C8A12"),
    "cloth_red": ("#E8473F", "#B01E26", "#6B0F18"),
    "cloth_blue": ("#6FB2E6", "#3A78B8", "#1D4170"),
    "cloth_gold": ("#FFE27A", "#E0B02C", "#A06E14"),
    "cloth_bone": ("#F2EBD8", "#C9BEA2", "#8C826A"),
    "cloth_gray": ("#C6C2B6", "#8F8B80", "#58554D"),
    "skin": ("#F6D0A4", "#D9A06C", "#9C6338"),
    "glass": ("#F4FCFF", "#CFE9F5", "#8DB6C8"),
    "dust": ("#E9DFC8", "#C9BB9B", "#9B8C6D"),
    "white": ("#FFFFFF", "#F4F1E8", "#D6D0BF"),
    "black": ("#4A4A52", "#2A2A31", "#121216"),
    "moss": ("#D6E8A0", "#8DAE4E", "#476B2A"),
    "earth": ("#A58660", "#74583A", "#422F1D"),
    "rust": ("#E39A72", "#B05A3A", "#6A2E1C"),
}

# Saturation reduction for all materials and an extra one for the nearly pure ones (blood, lime, gold...):
# the game's palette is desaturated and the icons cannot be the loudest thing on the screen.
GLOBAL_DESAT = 0.12
EXTRA_DESAT = {
    "blood": 0.20, "lime": 0.32, "moss": 0.10, "gold": 0.18, "ember": 0.16, "cloth_red": 0.14,
    "cloth_blue": 0.14, "cloth_gold": 0.16, "ice": 0.08, "bronze": 0.08, "rust": 0.06,
}

MATERIALS = {
    name: tuple(desaturate(c, GLOBAL_DESAT + EXTRA_DESAT.get(name, 0.0)) for c in tones)
    for name, tones in _MATERIALS_RAW.items()
}


# --------------------------------------------------------------------------------------------
# Categories (backgrounds): drawn by paint.py
# --------------------------------------------------------------------------------------------

# top/bottom: background fill (value 25 to 35 % at the top, saturation 0.45 or less). glow: inner halo
# and edge in the category colour. The frame is added by the slot (UIPalette.BORDER and
# BORDER_LIGHT, iron and warm bronze); here there is only a fine edge in those same tones.
CATEGORIES = {
    # attack: dark crimson and bronze (Askarra)
    "ataque": {"top": "#573532", "bottom": "#36211F", "glow": "#C9704F", "label": "Ataque"},
    # defence: steel and ice blue (Vardheim)
    "defensa": {"top": "#34414F", "bottom": "#1F2831", "glow": "#86B1D1", "label": "Defensa"},
    # ability: old gold / ember (Eldrun)
    "habilidad": {"top": "#524532", "bottom": "#322A1E", "glow": "#D3A94C", "label": "Habilidad"},
    # consumable: leather
    "consumible": {"top": "#4F3D2E", "bottom": "#302419", "glow": "#C0905A", "label": "Consumible"},
    # harmful status: rust red
    "estado_malo": {"top": "#563730", "bottom": "#34231E", "glow": "#C0583A", "label": "Estado perjudicial"},
    # beneficial status: moss green
    "estado_bueno": {"top": "#38452B", "bottom": "#222B1B", "glow": "#92B15A", "label": "Estado beneficioso"},
    # world: warm stone
    "mundo": {"top": "#4A463D", "bottom": "#2C2A25", "glow": "#B2A88C", "label": "Mundo"},
}

# Outline of the shapes: warm black, the same on all of them (the shape is exported without a background).
INK = "#1B1511"
OUTLINE_WIDTH = 3.6
# Fine dark stroke that separates the pieces of a shape from one another (the thick outline only surrounds
# the complete silhouette).
EDGE_WIDTH = 2.0
# Offset of the cast shadow (in canvas units): bottom right.
SHADOW_OFFSET = (1.6, 4.4)


# --------------------------------------------------------------------------------------------
# Shapes
# --------------------------------------------------------------------------------------------


class Sh:
    """A shape of the glyph.

    path: [Path]. fill: material name or `#RRGGBB` (None = no fill). stroke and sw: stroke.
    outline: contributes to the silhouette (outline and shadow); details (highlights, streaks) do not.
    op: opacity. cap: stroke ends.
    """

    def __init__(self, path, fill=None, stroke=None, sw=0.0, outline=True, op=1.0, cap="round",
                 join="round", ow=None, edge=None, relief=None):
        self.path = path
        self.fill = fill
        self.stroke = stroke
        self.sw = sw
        self.outline = outline
        self.op = op
        self.cap = cap
        self.join = join
        self.ow = ow  # own outline width (None = the general one)
        self.edge = edge  # width of the edge between pieces (None = the general one; 0 = no edge)
        self.relief = relief  # forces (True) or removes (False) the edge-light relief and grain

    @property
    def role(self):
        """body: filled piece that contributes to the silhouette; tube: thick stroke with outline; detail:
        loose fill (highlights, marks); line: fine stroke without outline."""
        if self.stroke is not None:
            return "tube" if self.outline else "line"
        return "body" if self.outline and self.fill is not None else "detail"


def shape(path, fill, **kw):
    return Sh(path, fill=fill, **kw)


def line(path, color, width, **kw):
    """Line or curve with stroke only. By default it does not contribute to the silhouette."""
    kw.setdefault("outline", False)
    return Sh(path, fill=None, stroke=color, sw=width, **kw)


def detail(path, fill, **kw):
    """Fill that does not contribute to the silhouette (highlights, inner shadows, marks)."""
    kw["outline"] = False
    return Sh(path, fill=fill, **kw)


# --------------------------------------------------------------------------------------------
# Silhouette measurement (without the engine): coverage and box, to equalise visual weight
# --------------------------------------------------------------------------------------------

INTERIOR = 112.0  # side of the usable interior of the slot, in canvas units


def silhouette_image(shapes, side=128, ss=4, ow_scale=1.0, fit=(1.0, 0.0, 0.0), pad=0.0):
    """Silhouette mask (outline included, shadow not) with PIL, at `side` x `side` px.

    `fit` = (s, tx, ty) is the same transform as `layers`: it scales and translates the geometry, but
    the outline keeps its width (which is why it is compensated when emitting the layers). `pad` adds a margin (in
    canvas units) on all sides to measure shapes that spill off the canvas; with a margin the
    image measures `side * (128 + 2 pad) / 128` px.
    """
    unit = side * ss / 128.0
    big = int(round(side * ss * (128.0 + 2.0 * pad) / 128.0))
    img = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(img)
    fs, ftx, fty = fit

    def tr(pts):
        return [((x * fs + ftx + pad) * unit, (y * fs + fty + pad) * unit) for x, y in pts]

    for sh in shapes:
        if not sh.outline:
            if sh.op < 0.5:
                continue
            for pts, _closed in sh.path.polys:
                xy = tr(pts)
                if sh.fill is not None and len(xy) >= 3:
                    draw.polygon(xy, fill=255)
                if sh.stroke is not None and len(xy) >= 2:
                    draw.line(xy, fill=255, width=max(1, int(round(sh.sw * fs * unit))), joint="curve")
            continue
        ow = (OUTLINE_WIDTH if sh.ow is None else sh.ow) * ow_scale
        stroke_w = 2.0 * ow + sh.sw * fs
        for pts, closed in sh.path.polys:
            xy = tr(pts)
            if len(xy) < 2:
                continue
            if sh.fill is not None and len(xy) >= 3:
                draw.polygon(xy, fill=255)
            width = max(1, int(round(stroke_w * unit)))
            seq = xy + [xy[0]] if closed or sh.fill is not None else xy
            draw.line(seq, fill=255, width=width, joint="curve")
            r = width / 2.0
            for ex, ey in ([xy[0], xy[-1]] if not (closed or sh.fill is not None) else xy[::6]):
                draw.ellipse((ex - r, ey - r, ex + r, ey + r), fill=255)
    out = int(round(side * (128.0 + 2.0 * pad) / 128.0))
    return img.resize((out, out), Image.BOX)


def measure(shapes, ow_scale=1.0, fit=(1.0, 0.0, 0.0)):
    """(box (x0, y0, x1, y1) in canvas units, coverage 0..1 of the 112 x 112 interior).

    Measures the whole shape even if it spills off the canvas (the box may have negative coordinates).
    """
    pad = 64.0
    img = silhouette_image(shapes, 128, 4, ow_scale, fit, pad)
    mask = img.point(lambda v: 255 if v > 127 else 0)
    bbox = mask.getbbox()
    if bbox is None:
        return (0, 0, 0, 0), 0.0
    covered = sum(1 for v in mask.getdata() if v)
    # px -> units: the image has 128 px for every 128 units
    box = (bbox[0] - pad, bbox[1] - pad, bbox[2] - pad, bbox[3] - pad)
    return box, covered / (INTERIOR * INTERIOR)


def _centered(shapes, s, center, ow_scale):
    """Translation that centres the box of the shape scaled by `s` at `center`."""
    bbox, _cover = measure(shapes, ow_scale, (s, 0.0, 0.0))
    cx, cy = (bbox[0] + bbox[2]) / 2.0, (bbox[1] + bbox[3]) / 2.0
    return center[0] - cx, center[1] - cy


def fit_transform(shapes, target=0.375, lo=0.6, hi=1.6, max_extent=110.0, center=(64.0, 62.0),
                  ow_scale=1.0):
    """Scale and translation that leave the shape centred and with coverage close to `target`.

    Returns (s, tx, ty): x' = s * x + tx. The outline does not scale (it is compensated when emitting the layers), so
    the coverage does not follow s squared exactly: it is refined in a few passes. The scale is limited
    so that the box (outline included) fits in `max_extent` and so as not to distort the drawing.
    """
    s = 1.0
    for _ in range(4):
        tx, ty = _centered(shapes, s, center, ow_scale)
        bbox, cover = measure(shapes, ow_scale, (s, tx, ty))
        if cover <= 0:
            return 1.0, 0.0, 0.0
        s = min(max(s * math.sqrt(target / cover), lo), hi)
        extent = max(bbox[2] - bbox[0], bbox[3] - bbox[1], 1.0)
        if extent > max_extent and s > 0.2:
            # reduce until the box fits
            s *= max_extent / extent
    tx, ty = _centered(shapes, s, center, ow_scale)
    bbox, _cover = measure(shapes, ow_scale, (s, tx, ty))
    extent = max(bbox[2] - bbox[0], bbox[3] - bbox[1], 1.0)
    if extent > max_extent:
        s *= max_extent / extent
        tx, ty = _centered(shapes, s, center, ow_scale)
        bbox, _cover = measure(shapes, ow_scale, (s, tx, ty))
    # keep the box from spilling off the canvas (margin of 6 units)
    dx = max(6 - bbox[0], 0) - max(bbox[2] - 122, 0)
    dy = max(6 - bbox[1], 0) - max(bbox[3] - 122, 0)
    return s, tx + dx, ty + dy


def fit_square(shapes, fill=0.9, ow_scale=1.0):
    """Fit for the small variants: the box (outline included) fills `fill` of the square."""
    target = fill * 128.0
    s = 1.0
    for _ in range(6):
        bbox, _cover = measure(shapes, ow_scale, (s, 0.0, 0.0))
        extent = max(bbox[2] - bbox[0], bbox[3] - bbox[1], 1.0)
        s *= target / extent
    tx, ty = _centered(shapes, s, (64.0, 64.0), ow_scale)
    return s, tx, ty


# --------------------------------------------------------------------------------------------
# Layers
# --------------------------------------------------------------------------------------------


def _fill_ref(fill, used):
    if fill is None:
        return "none"
    if fill.startswith("#"):
        return fill
    used.add(fill)
    return "url(#m_%s)" % fill


def _defs_for(material):
    light, mid, dark = MATERIALS[material]
    return (
        '<linearGradient id="m_%s" x1="0.12" y1="0" x2="0.72" y2="1">'
        '<stop offset="0" stop-color="%s"/><stop offset="0.5" stop-color="%s"/>'
        '<stop offset="1" stop-color="%s"/></linearGradient>' % (material, light, mid, dark)
    )


def _wrap(side, defs, body, fit):
    """Builds an SVG of `side` px with a transform group `fit` = (s, tx, ty)."""
    s, tx, ty = fit
    group = '<g transform="translate(%s %s) scale(%s)">%s</g>' % (_num(tx), _num(ty), _num(s), body)
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 128 128">'
        "<defs>%s</defs>%s</svg>\n" % (side, side, defs, group)
    )


def layers(shapes, side=256, fit=(1.0, 0.0, 0.0), ow_scale=1.0, shadow=1.0):
    """Splits the shape into SVG layers: shadow, silhouette and one per piece.

    Returns a list of dicts: {"kind": "shadow"|"silhouette"|"piece", "svg": text, ...}. Each piece
    also carries its `role` (see `Sh.role`), the material or flat colour, the opacity and whether it has an edge.
    The outline and edge widths are divided by the scale so they neither thicken nor thin when
    fitting the shape to the canvas; `ow_scale` multiplies them (the small states carry a proportionally
    thicker outline) and `shadow` does the same with the shadow offset.
    """
    s = fit[0]
    comp = ow_scale / s
    out = []

    def ow_of(sh):
        return (OUTLINE_WIDTH if sh.ow is None else sh.ow) * comp

    # 1) cast shadow (opaque black; opacity and blur are set by paint.py)
    body = []
    dx, dy = SHADOW_OFFSET[0] * shadow / s, SHADOW_OFFSET[1] * shadow / s
    for sh in shapes:
        if not sh.outline:
            continue
        w = _num(ow_of(sh) * 2.0 + sh.sw)
        fill = "#000000" if sh.fill is not None else "none"
        body.append('<path d="%s" transform="translate(%s %s)" fill="%s" stroke="#000000" '
                    'stroke-width="%s" stroke-linejoin="round" stroke-linecap="round"/>'
                    % (sh.path.d(), _num(dx), _num(dy), fill, w))
    out.append({"kind": "shadow", "svg": _wrap(side, "", "".join(body), fit)})

    # 2) silhouette: dark outline of all the pieces that have a silhouette
    body = []
    for sh in shapes:
        if not sh.outline:
            continue
        w = _num(ow_of(sh) * 2.0 + sh.sw)
        fill = INK if sh.fill is not None else "none"
        body.append('<path d="%s" fill="%s" stroke="%s" stroke-width="%s" stroke-linejoin="round" '
                    'stroke-linecap="round"/>' % (sh.path.d(), fill, INK, w))
    out.append({"kind": "silhouette", "svg": _wrap(side, "", "".join(body), fit)})

    # 3) one layer per piece, in the order they were drawn
    for sh in shapes:
        used = set()
        fill = _fill_ref(sh.fill, used)
        attrs = ""
        if sh.stroke is not None:
            attrs += ' stroke="%s" stroke-width="%s" stroke-linecap="%s" stroke-linejoin="%s"' % (
                sh.stroke, _num(sh.sw), sh.cap, sh.join)
        elif sh.outline and sh.fill is not None:
            edge = EDGE_WIDTH if sh.edge is None else sh.edge
            if edge > 0:
                attrs += ' stroke="%s" stroke-width="%s" stroke-linejoin="round"' % (
                    INK, _num(edge * comp))
        defs = "".join(_defs_for(m) for m in sorted(used))
        svg = _wrap(side, defs, '<path d="%s" fill="%s"%s/>' % (sh.path.d(), fill, attrs), fit)
        flat = None
        material = None
        if sh.fill is not None:
            if sh.fill.startswith("#"):
                flat = sh.fill
            else:
                material = sh.fill
        elif sh.stroke is not None:
            flat = sh.stroke
        out.append({"kind": "piece", "svg": svg, "role": sh.role, "material": material, "flat": flat,
                    "op": sh.op, "relief": sh.relief, "edge": bool(sh.outline and sh.fill is not None
                                              and (EDGE_WIDTH if sh.edge is None else sh.edge) > 0),
                    "sw": sh.sw})
    return out
