"""Kit de dibujo de los iconos de la interfaz (ART-12): geometría, materiales y montaje del SVG.

Todo se dibuja en un lienzo de 128 x 128 (el icono final se muestra a 32 a 64 px) con un estilo
único:

  - Fondo con bisel por categoría (ataque, defensa, habilidad, consumible, estado, mundo): marco
    oscuro, degradado vertical, filo de luz arriba a la izquierda y de sombra abajo a la derecha.
  - Un solo foco de luz, arriba a la izquierda: cada material es un degradado de claro a oscuro en esa
    dirección y los filos de luz de los detalles también miran a ese lado.
  - Silueta fuerte: cada figura lleva un contorno oscuro grueso (el color del fondo muy oscurecido) y
    una sombra proyectada hacia abajo, para que se lea a 32 px sin importar el color del fondo.

Las transformaciones se aplican a los puntos al construir el trazado, no con `transform`, así que
los degradados siempre miran hacia el mismo lado aunque la figura esté girada.

Solo usa lo que dibuja bien ThorVG (el rasterizador de Godot): trazados, degradados lineales y
radiales, trazo y opacidad. Nada de filtros ni máscaras.
"""

import math

# --------------------------------------------------------------------------------------------
# Geometría
# --------------------------------------------------------------------------------------------


def _num(value):
    text = "%.2f" % value
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


class Xf:
    """Transformación afín 2D: x' = a x + c y + e, y' = b x + d y + f."""

    __slots__ = ("a", "b", "c", "d", "e", "f")

    def __init__(self, a=1.0, b=0.0, c=0.0, d=1.0, e=0.0, f=0.0):
        self.a, self.b, self.c, self.d, self.e, self.f = a, b, c, d, e, f

    def __call__(self, x, y):
        return (self.a * x + self.c * y + self.e, self.b * x + self.d * y + self.f)

    def __matmul__(self, other):
        """`self @ other`: aplica primero `other` y luego `self`."""
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
    """Giro de `deg` grados (positivo = horario en pantalla) alrededor de (cx, cy)."""
    r = math.radians(deg)
    c, s = math.cos(r), math.sin(r)
    return move(cx, cy) @ Xf(c, s, -s, c) @ move(-cx, -cy)


def scale(sx, sy=None, cx=0.0, cy=0.0):
    sy = sx if sy is None else sy
    return move(cx, cy) @ Xf(sx, 0.0, 0.0, sy) @ move(-cx, -cy)


def flip_h(cx=64.0):
    """Espejo horizontal respecto a la vertical x = cx."""
    return Xf(-1.0, 0.0, 0.0, 1.0, 2.0 * cx, 0.0)


# --------------------------------------------------------------------------------------------
# Trazados
# --------------------------------------------------------------------------------------------


class Path:
    """Trazado con comandos absolutos; cada punto pasa por la transformación `xf`."""

    def __init__(self, xf=IDENT):
        self.xf = xf
        self.cmds = []
        self.cur = None

    def _p(self, x, y):
        px, py = self.xf(x, y)
        return "%s %s" % (_num(px), _num(py))

    def M(self, x, y):
        self.cmds.append("M" + self._p(x, y))
        self.cur = (x, y)
        return self

    def L(self, x, y):
        self.cmds.append("L" + self._p(x, y))
        self.cur = (x, y)
        return self

    def C(self, x1, y1, x2, y2, x, y):
        self.cmds.append("C%s %s %s" % (self._p(x1, y1), self._p(x2, y2), self._p(x, y)))
        self.cur = (x, y)
        return self

    def Q(self, x1, y1, x, y):
        self.cmds.append("Q%s %s" % (self._p(x1, y1), self._p(x, y)))
        self.cur = (x, y)
        return self

    def Z(self):
        self.cmds.append("Z")
        return self

    def arc(self, cx, cy, rx, ry, a0, a1, rot_deg=0.0):
        """Arco de elipse de `a0` a `a1` grados (0 = derecha, 90 = abajo), como curvas cúbicas.

        Si el trazado está vacío abre con M; si no, une con L hasta el inicio del arco.
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
    """Polígono con las esquinas redondeadas (`radius` único o uno por vértice)."""
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
    """Banda de grosor variable alrededor de la curva cuadrática p0-c-p2 (más fina en los extremos)."""
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
# Color
# --------------------------------------------------------------------------------------------


def hex_rgb(color):
    return tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))


def rgb_hex(rgb):
    return "#%02X%02X%02X" % tuple(max(0, min(255, int(round(c)))) for c in rgb)


def mix(a, b, t):
    """Mezcla `a` y `b` (t = 0 da a, t = 1 da b)."""
    ra, rb = hex_rgb(a), hex_rgb(b)
    return rgb_hex([ra[i] + (rb[i] - ra[i]) * t for i in range(3)])


def darken(color, t):
    return mix(color, "#000000", t)


def lighten(color, t):
    return mix(color, "#FFFFFF", t)


# Materiales: (claro, medio, oscuro). El degradado va de arriba a la izquierda (claro) a abajo a la
# derecha (oscuro), el foco de luz único del juego de iconos.
MATERIALS = {
    "steel": ("#F4F8FC", "#B9C6D4", "#6F7F93"),
    "steel_dark": ("#B9C6D4", "#7D8CA0", "#434F60"),
    "iron": ("#9AA3B0", "#646D7B", "#363C47"),
    "wood": ("#C98F55", "#97602F", "#5A3416"),
    "wood_dark": ("#9C6A3C", "#69401D", "#3A210C"),
    "wood_light": ("#FBDCA0", "#DDA255", "#9A6122"),
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
}


# --------------------------------------------------------------------------------------------
# Categorías (fondos con bisel)
# --------------------------------------------------------------------------------------------

# top = color arriba, bottom = abajo, glow = halo detrás de la figura. El contorno de las figuras sale
# del color de abajo muy oscurecido.
CATEGORIES = {
    "ataque": {"top": "#B5372C", "bottom": "#561812", "glow": "#FF7A4C", "label": "Ataque"},
    "defensa": {"top": "#42679C", "bottom": "#1A2C4A", "glow": "#78AEE6", "label": "Defensa"},
    "habilidad": {"top": "#7448A8", "bottom": "#2C1A4C", "glow": "#B88CF0", "label": "Habilidad"},
    "consumible": {"top": "#8E6038", "bottom": "#3A2310", "glow": "#E0A868", "label": "Consumible"},
    "estado": {"top": "#5E6C80", "bottom": "#232A36", "glow": "#9CB2CC", "label": "Estado"},
    "mundo": {"top": "#7B7456", "bottom": "#34301F", "glow": "#D8CC98", "label": "Mundo"},
}

FRAME_COLOR = "#0B0B10"
OUTLINE_WIDTH = 3.6
# Trazo fino oscuro que separa las piezas de una figura unas de otras (el contorno grueso solo rodea
# la silueta completa).
EDGE_WIDTH = 2.0


# --------------------------------------------------------------------------------------------
# Figuras y montaje
# --------------------------------------------------------------------------------------------


class Sh:
    """Una figura del glifo.

    path: [Path]. fill: nombre de material o `#RRGGBB` (None = sin relleno). stroke y sw: trazo.
    outline: aporta a la silueta (contorno y sombra); los detalles (brillos, rayas) no.
    op: opacidad. cap: extremos del trazo.
    """

    def __init__(self, path, fill=None, stroke=None, sw=0.0, outline=True, op=1.0, cap="round",
                 join="round", ow=None, edge=None):
        self.path = path
        self.fill = fill
        self.stroke = stroke
        self.sw = sw
        self.outline = outline
        self.op = op
        self.cap = cap
        self.join = join
        self.ow = ow  # ancho propio del contorno (None = el general)
        self.edge = edge  # ancho del filo entre piezas (None = el general; 0 = sin filo)


def shape(path, fill, **kw):
    return Sh(path, fill=fill, **kw)


def line(path, color, width, **kw):
    """Línea o curva con solo trazo. Por defecto no aporta a la silueta."""
    kw.setdefault("outline", False)
    return Sh(path, fill=None, stroke=color, sw=width, **kw)


def detail(path, fill, **kw):
    """Relleno que no aporta a la silueta (brillos, sombras internas, marcas)."""
    kw["outline"] = False
    return Sh(path, fill=fill, **kw)


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


def _tile(category):
    cat = CATEGORIES[category]
    top, bottom, glow = cat["top"], cat["bottom"], cat["glow"]
    rim = mix(bottom, "#000000", 0.35)
    defs = (
        '<linearGradient id="t_fill" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>'
        '<radialGradient id="t_glow" cx="62" cy="56" r="66" gradientUnits="userSpaceOnUse">'
        '<stop offset="0" stop-color="%s" stop-opacity="0.55"/>'
        '<stop offset="0.6" stop-color="%s" stop-opacity="0.14"/>'
        '<stop offset="1" stop-color="%s" stop-opacity="0"/></radialGradient>'
        '<linearGradient id="t_floor" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#000000" stop-opacity="0"/>'
        '<stop offset="1" stop-color="#000000" stop-opacity="0.34"/></linearGradient>'
        % (top, bottom, glow, glow, glow)
    )
    body = (
        '<rect x="0" y="0" width="128" height="128" rx="17" fill="%s"/>' % FRAME_COLOR
        + '<rect x="2.5" y="2.5" width="123" height="123" rx="14.5" fill="%s"/>' % rim
        + '<rect x="4" y="4" width="120" height="120" rx="13.5" fill="url(#t_fill)"/>'
        + '<rect x="4" y="4" width="120" height="120" rx="13.5" fill="url(#t_glow)"/>'
        + '<rect x="4" y="64" width="120" height="60" rx="13.5" fill="url(#t_floor)"/>'
        # filo de luz (arriba e izquierda) y de sombra (abajo y derecha)
        + '<path d="M5.5 112 L5.5 18 Q5.5 5.5 18 5.5 L112 5.5" fill="none" stroke="#FFFFFF" '
        'stroke-opacity="0.42" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>'
        + '<path d="M122.5 16 L122.5 110 Q122.5 122.5 110 122.5 L16 122.5" fill="none" stroke="#000000" '
        'stroke-opacity="0.45" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>'
        # marco interior fino: da la sensación de casilla hundida
        + '<rect x="9" y="9" width="110" height="110" rx="9" fill="none" stroke="#000000" '
        'stroke-opacity="0.22" stroke-width="1.6"/>'
    )
    return defs, body, darken(bottom, 0.62)


def _path_el(sh, fill_attr, stroke_attr, sw, extra=""):
    return '<path d="%s" fill="%s"%s%s%s/>' % (sh.path.d(), fill_attr, stroke_attr, extra, "")


def icon_svg(name, category, shapes, title):
    """Monta el SVG completo de un icono: fondo con bisel, sombra, contorno y figuras."""
    tile_defs, tile_body, outline_color = _tile(category)
    used = set()
    figure = []

    # 1) sombra proyectada hacia abajo (solo la silueta)
    for sh in shapes:
        if not sh.outline:
            continue
        ow = (OUTLINE_WIDTH if sh.ow is None else sh.ow) * 2.0
        if sh.fill is not None:
            figure.append(
                '<path d="%s" transform="translate(1.5 4.5)" fill="#000000" fill-opacity="0.30" '
                'stroke="#000000" stroke-opacity="0.30" stroke-width="%s" stroke-linejoin="round" '
                'stroke-linecap="round"/>' % (sh.path.d(), _num(ow + sh.sw))
            )
        else:
            figure.append(
                '<path d="%s" transform="translate(1.5 4.5)" fill="none" stroke="#000000" '
                'stroke-opacity="0.30" stroke-width="%s" stroke-linejoin="round" '
                'stroke-linecap="round"/>' % (sh.path.d(), _num(ow + sh.sw))
            )

    # 2) contorno oscuro
    for sh in shapes:
        if not sh.outline:
            continue
        ow = (OUTLINE_WIDTH if sh.ow is None else sh.ow) * 2.0
        fill = outline_color if sh.fill is not None else "none"
        figure.append(
            '<path d="%s" fill="%s" stroke="%s" stroke-width="%s" stroke-linejoin="round" '
            'stroke-linecap="round"/>' % (sh.path.d(), fill, outline_color, _num(ow + sh.sw))
        )

    # 3) relleno y detalles, en el orden en que se dibujaron
    for sh in shapes:
        attrs = ""
        fill = _fill_ref(sh.fill, used)
        if sh.stroke is not None:
            attrs += ' stroke="%s" stroke-width="%s" stroke-linecap="%s" stroke-linejoin="%s"' % (
                sh.stroke, _num(sh.sw), sh.cap, sh.join)
        elif sh.outline and sh.fill is not None:
            edge = EDGE_WIDTH if sh.edge is None else sh.edge
            if edge > 0:
                attrs += ' stroke="%s" stroke-width="%s" stroke-linejoin="round"' % (
                    outline_color, _num(edge))
        if sh.op < 1.0:
            attrs += ' opacity="%s"' % _num(sh.op)
        figure.append('<path d="%s" fill="%s"%s/>' % (sh.path.d(), fill, attrs))

    defs = tile_defs + "".join(_defs_for(m) for m in sorted(used))
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">\n'
        "<title>%s</title>\n<defs>%s</defs>\n%s\n%s\n</svg>\n"
        % (title, defs, tile_body, "\n".join(figure))
    )
