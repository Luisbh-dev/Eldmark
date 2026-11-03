"""Glifos de los iconos de la interfaz (ART-12): cada función devuelve la lista de figuras de un icono.

Lienzo de 128 x 128, zona útil de unos 16 a 112 px. Luz arriba a la izquierda. Las piezas
reutilizables (espada, escudo redondo, arco, flecha...) se construyen con una transformación `xf`
para poder colocarlas giradas; los degradados no giran con ellas (ver svgkit).
"""

import math

from svgkit import (
    IDENT, Path, Sh, curve_band, detail, ellipse, flip_h, line, move, polar, poly, rect, rot, rpoly, scale,
    star,
)

# --------------------------------------------------------------------------------------------
# Piezas reutilizables
# --------------------------------------------------------------------------------------------


def swoosh(a, b, out, inn, xf=IDENT):
    """Media luna entre los puntos `a` y `b`: `out` es la panza exterior y `inn` la interior."""
    mx, my = (a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = math.hypot(dx, dy)
    nx, ny = dy / length, -dx / length  # normal a la izquierda del sentido a -> b
    path = Path(xf)
    path.M(*a)
    path.Q(mx + nx * out * 2.0, my + ny * out * 2.0, *b)
    path.Q(mx + nx * inn * 2.0, my + ny * inn * 2.0, *a)
    path.Z()
    return path


def burst(cx, cy, r_out, r_in, n, fill, rot_deg=0.0, rr=1.2, **kw):
    """Estrella de impacto de `n` puntas."""
    return Sh(star(cx, cy, r_out, r_in, n, start_deg=rot_deg - 90.0, round_r=rr), fill, **kw)


def sparkle(cx, cy, r, fill="white", **kw):
    """Destello de cuatro puntas."""
    pts = []
    for i in range(8):
        ang = math.radians(i * 45.0 - 90.0)
        rad = r if i % 2 == 0 else r * 0.3
        pts.append((cx + rad * math.cos(ang), cy + rad * math.sin(ang)))
    return Sh(poly(pts), fill, **kw)


def sword(xf, length=64, w=12, gw=34, gh=7, grip=15, guard="gold"):
    """Espada con la punta hacia arriba y el centro de la cruz en el origen."""
    hb = gh / 2.0
    out = []
    out.append(Sh(poly([(0, -length), (-w / 2, -length + 15), (-w / 2, -hb), (0, -hb)], xf),
                  "steel", edge=0))
    out.append(Sh(poly([(0, -length), (w / 2, -length + 15), (w / 2, -hb), (0, -hb)], xf),
                  "steel_dark", edge=0))
    out.append(Sh(Path(xf).M(-w / 2 + 2.4, -hb - 3).L(-w / 2 + 2.4, -length + 20), stroke="#FFFFFF",
                  sw=1.8, outline=False, op=0.9))
    out.append(Sh(rect(-3.4, hb - 1, 6.8, grip, 2.0, xf), "leather"))
    for i in range(3):
        y = hb + 2.5 + i * 4.2
        out.append(Sh(Path(xf).M(-3.4, y).L(3.4, y + 1.6), stroke="#2A170A", sw=1.4, outline=False,
                      op=0.8))
    out.append(Sh(ellipse(0, hb + grip + 2.2, 5.4, 5.4, xf), guard))
    out.append(Sh(rpoly([(-gw / 2, -hb - 1.5), (gw / 2, -hb - 1.5), (gw / 2 - 1.5, hb + 1.5),
                         (-gw / 2 + 1.5, hb + 1.5)], 2.6, xf), guard))
    return out


def round_shield(cx, cy, r, xf=IDENT, rim="steel_dark", face="wood", boss="steel", paint=None):
    """Escudo redondo de frente: aro de hierro, tablones de madera y centro de metal."""
    out = []
    out.append(Sh(ellipse(cx, cy, r, r, xf), rim))
    out.append(Sh(ellipse(cx, cy, r * 0.8, r * 0.8, xf), face, edge=1.6))
    # tablones: líneas verticales recortadas al círculo de la cara
    fr = r * 0.8
    for k in (-0.5, 0.0, 0.5):
        dx = k * fr
        dy = math.sqrt(max(fr * fr - dx * dx, 0.0)) - 1.5
        out.append(Sh(Path(xf).M(cx + dx, cy - dy).L(cx + dx, cy + dy), stroke="#3A210C", sw=1.6,
                      outline=False, op=0.55))
    if paint:
        # franja pintada que cruza la cara (de lado a lado, por detrás del centro)
        out.append(Sh(Path(xf).M(cx - fr * 0.92, cy).L(cx + fr * 0.92, cy), stroke=paint,
                      sw=r * 0.2, outline=False, op=0.95, cap="butt"))
    # remaches del aro
    for i in range(8):
        px, py = polar(cx, cy, r * 0.9, i * 45.0 + 22.5)
        out.append(Sh(ellipse(px, py, max(r * 0.045, 1.1), max(r * 0.045, 1.1), xf), "#F6F2E4",
                      outline=False, op=0.9))
    out.append(Sh(ellipse(cx, cy, r * 0.3, r * 0.3, xf), boss))
    out.append(Sh(ellipse(cx - r * 0.07, cy - r * 0.09, r * 0.1, r * 0.08, xf), "#FFFFFF",
                  outline=False, op=0.85))
    # filo de luz del aro (arriba a la izquierda)
    out.append(Sh(Path(xf).arc(cx, cy, r * 0.93, r * 0.93, 190, 265), stroke="#FFFFFF", sw=max(r * 0.05, 1.6),
                  outline=False, op=0.7))
    return out


def bow(xf, height=84, belly=16, thick=9.0, tip_back=14, limb="wood_light"):
    """Arco visto de lado con la panza hacia +x (el lado del blanco); el origen está en la empuñadura."""
    h2 = height / 2.0
    out = []
    ctrl_x = 2.0 * belly + tip_back
    out.append(Sh(curve_band((-tip_back, -h2), (ctrl_x, 0), (-tip_back, h2), thick, thick * 0.5, xf),
                  limb))
    # filo de luz en la panza (lado de la luz: arriba a la izquierda)
    hl = Path(xf)
    hl.M(-tip_back + 5, -h2 + 12)
    hl.Q(ctrl_x - belly * 0.5 - 1.0, -h2 * 0.2, belly - thick * 0.22, -10)
    out.append(Sh(hl, stroke="#FFF1CC", sw=1.8, outline=False, op=0.75))
    out.append(Sh(rect(belly - thick / 2 - 1.8, -9, thick + 3.6, 18, 3.0, xf), "leather"))
    for sy in (-1, 1):
        out.append(Sh(ellipse(-tip_back, sy * h2, 3.0, 3.0, xf), "bone", edge=1.4))
    return out


def string(xf, height, tip_back, nock_x=None, color="#F6F0DA", width=1.9):
    """Cuerda del arco; si hay `nock_x` va tensada en V hasta la muesca de la flecha."""
    h2 = height / 2.0
    p = Path(xf).M(-tip_back, -h2)
    if nock_x is not None:
        p.L(nock_x, 0)
    p.L(-tip_back, h2)
    return Sh(p, stroke=color, sw=width, outline=False, join="round")


def arrow(xf, length=64, head=15, shaft=5.0, fletch="cloth_red", head_mat="steel", tip_mat=None):
    """Flecha con la cola en el origen y la punta en +x."""
    out = []
    out.append(Sh(rect(0, -shaft / 2, length - head + 2, shaft, 1.6, xf), "wood", ow=2.4, edge=1.4))
    for sy in (-1, 1):
        fx = poly([(1, sy * shaft / 2), (16, sy * shaft / 2), (9, sy * (shaft / 2 + 8.5)),
                   (-5, sy * (shaft / 2 + 8.5))], xf)
        out.append(Sh(fx, fletch, ow=2.4, edge=1.4))
    hw = head * 0.78
    out.append(Sh(poly([(length - head, -hw / 2), (length, 0), (length - head, 0)], xf), head_mat,
                  ow=2.6, edge=0))
    out.append(Sh(poly([(length - head, 0), (length, 0), (length - head, hw / 2)], xf),
                  tip_mat or "steel_dark", ow=2.6, edge=0))
    return out


def _arrow_head(cx, cy, ang, size, fill, **kw):
    """Punta de flecha triangular centrada en (cx, cy) que mira hacia `ang` grados."""
    xf = move(cx, cy) @ rot(ang, 0, 0)
    return Sh(poly([(size, 0), (-size * 0.6, -size * 0.85), (-size * 0.6, size * 0.85)], xf), fill, **kw)


def flame(cx, cy, w, h, outer="ember", inner="gold", xf=IDENT):
    """Llama con la base en (cx, cy)."""
    p = Path(xf)
    p.M(cx, cy)
    p.C(cx - w * 0.62, cy, cx - w * 0.55, cy - h * 0.42, cx - w * 0.12, cy - h * 0.62)
    p.C(cx - w * 0.2, cy - h * 0.8, cx + w * 0.02, cy - h * 0.92, cx + w * 0.04, cy - h)
    p.C(cx + w * 0.3, cy - h * 0.78, cx + w * 0.66, cy - h * 0.42, cx + w * 0.55, cy - h * 0.16)
    p.C(cx + w * 0.5, cy - h * 0.03, cx + w * 0.3, cy, cx, cy)
    p.Z()
    out = [Sh(p, outer)]
    q = Path(xf)
    q.M(cx, cy - h * 0.02)
    q.C(cx - w * 0.3, cy - h * 0.02, cx - w * 0.3, cy - h * 0.3, cx, cy - h * 0.5)
    q.C(cx + w * 0.3, cy - h * 0.3, cx + w * 0.3, cy - h * 0.02, cx, cy - h * 0.02)
    q.Z()
    out.append(Sh(q, inner, outline=False))
    return out


# --------------------------------------------------------------------------------------------
# Ataque
# --------------------------------------------------------------------------------------------


def sword_light():
    out = [Sh(swoosh((12, 70), (110, 46), 34, 16), "white", outline=False, op=0.92)]
    out.append(Sh(swoosh((20, 70), (104, 50), 26, 14), "#FFFFFF", outline=False, op=0.5))
    out += sword(move(42, 88) @ rot(45, 0, 0), length=68, w=13, gw=36)
    out.append(sparkle(100, 30, 8, "#FFFFFF", outline=False))
    return out


def sword_heavy():
    out = [Sh(swoosh((16, 26), (104, 104), 46, 18), "#FFE6A8", outline=False, op=0.9)]
    out.append(burst(92, 92, 24, 11, 9, "ember", 8, 1.4))
    out.append(Sh(ellipse(92, 92, 7, 7), "gold", outline=False))
    out += sword(move(38, 38) @ rot(135, 0, 0), length=72, w=17, gw=44, gh=9, grip=15)
    return out


def bow_quick():
    out = []
    for i, (y, x0, x1) in enumerate(((46, 50, 84), (64, 40, 70), (82, 50, 84))):
        out.append(Sh(Path().M(x0, y).L(x1, y), stroke="#FFFFFF", sw=3.4, outline=False, op=0.8))
    out += bow(move(34, 64), height=88, belly=18, thick=8, tip_back=14)
    out.append(string(move(34, 64), 88, 14))
    out += arrow(move(60, 64), length=58, head=17, shaft=5.4)
    return out


def bow_drawn():
    out = []
    # halo de carga alrededor de la punta
    out.append(Sh(ellipse(100, 64, 20, 20), "ember", outline=False, op=0.35))
    out.append(burst(100, 64, 16, 8, 8, "gold", 0, 1.0, outline=False, op=0.8))
    out += bow(move(60, 64), height=92, belly=20, thick=8.5, tip_back=14)
    out.append(string(move(60, 64), 92, 14, nock_x=-34))
    out += arrow(move(26, 64), length=80, head=17, shaft=5.4)
    return out


# --------------------------------------------------------------------------------------------
# Defensa
# --------------------------------------------------------------------------------------------


def block():
    out = []
    # espada que llega desde arriba a la derecha y choca con el aro del escudo
    out += sword(move(108, 20) @ rot(225, 0, 0), length=56, w=12, gw=30, gh=7, grip=12)
    out += round_shield(54, 74, 38)
    out.append(burst(81, 47, 19, 7, 8, "gold", 10, 1.0))
    out.append(Sh(ellipse(81, 47, 6, 6), "white", outline=False))
    out.append(Sh(Path().M(66, 36).L(74, 28), stroke="#FFF3C0", sw=3, outline=False))
    out.append(Sh(Path().M(94, 60).L(104, 62), stroke="#FFF3C0", sw=3, outline=False))
    return out


def dodge():
    out = []
    # estelas de velocidad
    for y, x0, x1 in ((78, 8, 30), (90, 14, 34), (102, 8, 30)):
        out.append(Sh(Path().M(x0, y).L(x1, y), stroke="#F4F1E8", sw=4.0, outline=False, op=0.75))
    # ala (tres plumas)
    for ang, ln in ((-172, 44), (-150, 40), (-128, 34), (-106, 26)):
        xf = move(48, 56) @ rot(ang, 0, 0)
        out.append(Sh(ellipse(ln / 2.0, 0, ln / 2.0, 7.4, xf), "bone", edge=1.6))
    # bota
    boot = rpoly([(42, 24), (72, 24), (72, 62), (88, 68), (108, 80), (112, 92), (112, 100),
                  (38, 100), (38, 88)], [4, 4, 5, 6, 8, 5, 5, 5, 6])
    out.append(Sh(boot, "leather"))
    out.append(Sh(rect(38, 91, 74, 10, 3), "wood_dark", edge=1.6))
    out.append(Sh(rect(40, 22, 34, 12, 3), "gold", edge=1.6))
    out.append(Sh(Path().M(76, 70).L(100, 80), stroke="#2A170A", sw=1.8, outline=False, op=0.7))
    out.append(Sh(Path().M(49, 38).L(49, 80), stroke="#FFE2B0", sw=2.0, outline=False, op=0.45))
    return out


# --------------------------------------------------------------------------------------------
# Habilidades
# --------------------------------------------------------------------------------------------


def shield_bash():
    out = []
    out.append(burst(86, 62, 34, 15, 10, "ember", 6, 1.6))
    out.append(burst(86, 62, 22, 9, 10, "gold", 6, 1.2, outline=False))
    out += round_shield(46, 68, 34)
    return out


def shield_rush():
    out = []
    for y, x0, x1, w in ((40, 8, 52, 5.0), (58, 4, 50, 6.0), (76, 12, 52, 5.0), (94, 20, 54, 4.0)):
        out.append(Sh(Path().M(x0, y).L(x1, y), stroke="#F4F1E8", sw=w, outline=False, op=0.8))
    for cx, cy, r in ((26, 106, 7), (42, 104, 9), (14, 100, 5)):
        out.append(Sh(ellipse(cx, cy, r, r * 0.8), "dust", outline=False, op=0.85))
    out += round_shield(76, 62, 32, paint="#E8D9A8")
    # chevrones de avance delante
    for x in (108, 118):
        out.append(Sh(Path().M(x - 6, 46).L(x, 62).L(x - 6, 78), stroke="#FFE8A8", sw=4.4, outline=False,
                      op=0.9))
    return out


def shield_wall():
    out = []
    out += round_shield(26, 72, 24, paint=None)
    out += round_shield(102, 72, 24, paint=None)
    out += round_shield(64, 62, 36)
    # lanzas por encima del muro
    for x in (20, 64, 108):
        pass
    return out


def bow_volley():
    out = []
    out += bow(move(64, 104) @ rot(-90, 0, 0), height=104, belly=14, thick=9, tip_back=12)
    for ang in (-32, 0, 32):
        xf = move(64, 92) @ rot(ang - 90, 0, 0)
        out += arrow(xf, length=76, head=17, shaft=5.0)
    out.append(string(move(64, 104) @ rot(-90, 0, 0), 104, 12))
    return out


def bow_slowing_shot():
    out = []
    xf = move(30, 96) @ rot(-42, 0, 0)
    # rastro helado
    for x, y, r in ((22, 74, 7), (38, 90, 5), (14, 92, 4.5)):
        out.append(sparkle(x, y, r * 1.4, "ice", outline=False))
    out += arrow(xf, length=84, head=12, shaft=5.0, head_mat="ice", tip_mat="ice")
    # cristal de hielo en la punta
    tip = xf(80, 0)
    crystal = poly([(tip[0] - 2, tip[1] - 22), (tip[0] + 12, tip[1] - 2), (tip[0] + 2, tip[1] + 22),
                    (tip[0] - 12, tip[1] + 2)])
    out.append(Sh(crystal, "ice"))
    out.append(Sh(poly([(tip[0] - 2, tip[1] - 22), (tip[0] - 12, tip[1] + 2), (tip[0] - 1, tip[1] - 1)]),
                  "white", outline=False, op=0.8))
    out.append(sparkle(104, 20, 9, "#FFFFFF", outline=False))
    return out


def bow_evasive_shot():
    out = []
    # flecha que sale hacia delante
    out += arrow(move(30, 38) @ rot(-10, 0, 0), length=80, head=17, shaft=5.0)
    # salto atrás: flecha curva gruesa que vuelve hacia la izquierda, con polvo
    for cx, cy, r in ((106, 104, 8), (116, 92, 6), (96, 112, 5)):
        out.append(Sh(ellipse(cx, cy, r, r * 0.8), "dust", outline=False, op=0.85))
    p = Path().M(108, 78).Q(70, 118, 36, 90)
    out.append(Sh(p, stroke="#F4EBD0", sw=10, outline=True, ow=2.8, cap="butt"))
    tang = math.degrees(math.atan2(90 - 118, 36 - 70))
    out.append(_arrow_head(33, 88, tang, 16, "bone"))
    return out


# --------------------------------------------------------------------------------------------
# Consumibles
# --------------------------------------------------------------------------------------------


def potion_health():
    out = []
    # cristal: cuerpo redondo y cuello
    out.append(Sh(rpoly([(54, 26), (74, 26), (74, 52), (54, 52)], 3), "glass"))
    out.append(Sh(ellipse(64, 78, 29, 29), "glass"))
    # líquido
    liquid = Path()
    liquid.arc(64, 78, 27, 27, 205, -25)
    liquid.Z()
    out.append(Sh(liquid, "blood", outline=False))
    out.append(Sh(Path().M(40, 70).Q(52, 62, 64, 68).Q(76, 74, 88, 66), stroke="#FFB0A8", sw=2.2,
                  outline=False, op=0.8))
    out.append(Sh(ellipse(51, 70, 5, 9, rot(25, 51, 70)), "#FFFFFF", outline=False, op=0.65))
    # corcho
    out.append(Sh(rpoly([(52, 14), (76, 14), (74, 28), (54, 28)], 3), "wood"))
    out.append(Sh(Path().M(55, 18).L(73, 18), stroke="#FFE2B0", sw=1.6, outline=False, op=0.5))
    # cruz clara de cura sobre el líquido
    out.append(Sh(poly([(61, 76), (67, 76), (67, 82), (73, 82), (73, 88), (67, 88), (67, 94), (61, 94),
                        (61, 88), (55, 88), (55, 82), (61, 82)]), "#FFF4EC", outline=False, op=0.9))
    return out


def potion_stamina():
    out = []
    flask = rpoly([(56, 26), (72, 26), (72, 54), (96, 98), (96, 104), (32, 104), (32, 98), (56, 54)],
                  [3, 3, 4, 7, 6, 6, 7, 4])
    out.append(Sh(flask, "glass"))
    liquid = rpoly([(44, 78), (84, 78), (96, 98), (96, 100), (32, 100), (32, 98)], [2, 2, 6, 5, 5, 6])
    out.append(Sh(liquid, "lime", outline=False))
    out.append(Sh(Path().M(46, 78).L(82, 78), stroke="#EFFFC0", sw=2.0, outline=False, op=0.8))
    out.append(Sh(poly([(70, 78), (52, 94), (62, 94), (56, 108), (78, 90), (67, 90), (74, 78)]),
                  "#FFF6D0", outline=False, edge=1.6, op=1.0))
    out.append(Sh(ellipse(52, 62, 3, 10, rot(-14, 52, 62)), "#FFFFFF", outline=False, op=0.5))
    out.append(Sh(rpoly([(54, 14), (74, 14), (72, 28), (56, 28)], 3), "wood"))
    out.append(Sh(Path().M(57, 18).L(71, 18), stroke="#FFE2B0", sw=1.6, outline=False, op=0.5))
    return out


# --------------------------------------------------------------------------------------------
# Mundo: cambiar de arma, interactuar, fuerte, puerta, campamento y estandarte
# --------------------------------------------------------------------------------------------


def swap_weapon():
    out = []
    # espada y arco grandes, uno junto al otro
    out += sword(move(42, 72) @ rot(-14, 0, 0), length=62, w=12, gw=30, gh=7, grip=13)
    out += bow(move(74, 56), height=82, belly=14, thick=8, tip_back=10)
    out.append(string(move(74, 56), 82, 10))
    # chapa con dos flechas circulares en la esquina
    out.append(Sh(ellipse(96, 98, 23, 23), "iron"))
    out.append(Sh(ellipse(96, 98, 17.5, 17.5), "#262A33", outline=False, edge=1.4))
    for start in (200, 20):
        p = Path()
        p.arc(96, 98, 13, 13, start, start + 120)
        out.append(Sh(p, stroke="#F4EBD0", sw=5.5, outline=False, cap="butt"))
        ex, ey = polar(96, 98, 13, start + 120)
        out.append(_arrow_head(ex, ey, start + 120 + 90, 7.5, "bone", outline=False, edge=0))
    return out


def interact():
    out = []
    # dedos (el pulgar y la palma van encima de sus bases)
    for xb, yb, ln, w, ang in ((86, 74, 30, 12, 20), (75, 68, 40, 13, 8), (62, 66, 44, 14, -2),
                               (49, 70, 38, 13, -13)):
        xf = move(xb, yb) @ rot(ang, 0, 0)
        out.append(Sh(rect(-w / 2, -ln, w, ln + 10, w / 2, xf), "skin"))
        out.append(Sh(Path(xf).M(-w / 2 + 2.6, -ln + 7).L(-w / 2 + 2.6, -ln + 20), stroke="#FFF1DC",
                      sw=1.8, outline=False, op=0.6))
    out.append(Sh(rect(42, 66, 52, 40, 15), "skin"))
    xf = move(46, 90) @ rot(-52, 0, 0)
    out.append(Sh(rect(-7, -30, 14.5, 38, 7.2, xf), "skin"))
    out.append(Sh(rect(44, 98, 48, 14, 5), "gold", edge=1.6))
    out.append(Sh(Path().M(52, 78).Q(64, 86, 80, 80), stroke="#9C6338", sw=1.8, outline=False, op=0.5))
    out.append(sparkle(22, 36, 9, "#FFE8A0", outline=False))
    out.append(sparkle(108, 30, 8, "#FFE8A0", outline=False))
    out.append(sparkle(112, 62, 5, "#FFFFFF", outline=False))
    return out


def _crenel(x, y, w, n, h=8, fill="stone"):
    """Almenas: `n` dientes repartidos en el ancho `w` empezando en (x, y) hacia arriba."""
    out = []
    step = w / (2 * n - 1)
    for i in range(n):
        out.append(Sh(rect(x + i * 2 * step, y - h, step, h + 2, 1.0), fill, edge=1.4))
    return out


def fort():
    out = []
    # torre central
    out.append(Sh(rect(44, 38, 40, 66, 2), "stone"))
    out += _crenel(44, 40, 40, 3, 9)
    # torres laterales
    out.append(Sh(rect(18, 58, 30, 46, 2), "stone_dark"))
    out += _crenel(18, 60, 30, 3, 8, "stone_dark")
    out.append(Sh(rect(80, 58, 30, 46, 2), "stone_dark"))
    out += _crenel(80, 60, 30, 3, 8, "stone_dark")
    # sillares
    for y in (54, 68, 82):
        out.append(Sh(Path().M(46, y).L(82, y), stroke="#2E2B26", sw=1.4, outline=False, op=0.35))
    # puerta y aspilleras
    gate = Path().M(54, 104).L(54, 86).Q(54, 74, 64, 74).Q(74, 74, 74, 86).L(74, 104).Z()
    out.append(Sh(gate, "#1E1812", outline=False))
    out.append(Sh(rect(61.5, 48, 5, 14, 2), "#1E1812", outline=False))
    out.append(Sh(rect(28, 70, 4.5, 12, 2), "#1E1812", outline=False))
    out.append(Sh(rect(95, 70, 4.5, 12, 2), "#1E1812", outline=False))
    # mástil y bandera
    out.append(Sh(rect(63, 8, 2.8, 30, 1), "wood_dark", ow=2.4, edge=1.2))
    out.append(Sh(poly([(65.8, 9), (86, 15), (65.8, 22)]), "cloth_red", ow=2.6, edge=1.4))
    return out


def gate():
    out = []
    # muro de piedra con almenas y vano en arco
    out.append(Sh(rect(14, 36, 100, 70, 2), "stone"))
    out += _crenel(14, 38, 100, 6, 10)
    arch = Path().M(36, 106).L(36, 66).Q(36, 42, 64, 42).Q(92, 42, 92, 66).L(92, 106).Z()
    out.append(Sh(arch, "wood", ow=2.0, edge=2.0))
    # tablones, flejes y remaches
    for x in (50, 64, 78):
        out.append(Sh(Path().M(x, 46).L(x, 106), stroke="#3A210C", sw=1.8, outline=False, op=0.55))
    for y in (70, 90):
        out.append(Sh(rect(36, y - 3.5, 56, 7, 1.5), "iron", outline=False, edge=1.4))
        for x in (42, 86):
            out.append(Sh(ellipse(x, y, 1.6, 1.6), "#EDEDED", outline=False, op=0.9))
    out.append(Sh(ellipse(64, 80, 5.5, 5.5), "gold", outline=False, edge=1.6))
    out.append(Sh(Path().M(64, 46).L(64, 106), stroke="#1E1812", sw=2.0, outline=False, op=0.8))
    # clave del arco
    out.append(Sh(poly([(58, 36), (70, 36), (68, 48), (60, 48)]), "stone_dark", edge=1.4))
    return out


def camp():
    out = []
    out.append(Sh(ellipse(60, 104, 52, 7), "#000000", outline=False, op=0.3))
    # tienda: mitad iluminada y mitad en sombra
    out.append(Sh(poly([(10, 102), (52, 32), (52, 102)]), "cloth_bone", edge=0))
    out.append(Sh(poly([(52, 32), (96, 102), (52, 102)]), "cloth_gray", edge=0))
    out.append(Sh(poly([(52, 54), (68, 102), (36, 102)]), "#2A1E14", outline=False))
    out.append(Sh(poly([(52, 54), (60, 78), (52, 102)]), "#150E08", outline=False, op=0.6))
    # franja de color y mástil con banderín
    out.append(Sh(Path().M(30, 66).L(52, 40).L(74, 66), stroke="#C2342E", sw=4.0, outline=False))
    out.append(Sh(rect(51, 16, 2.6, 20, 1), "wood_dark", ow=2.4, edge=1.2))
    out.append(Sh(poly([(53.6, 17), (70, 22), (53.6, 28)]), "cloth_red", ow=2.6, edge=1.4))
    # hoguera
    out.append(Sh(rect(92, 100, 24, 6, 3), "wood_dark", ow=2.4, edge=1.4))
    out += flame(104, 100, 22, 36)
    return out


def _emblem_star(fill):
    return [Sh(star(74.5, 58, 16, 7, 8, start_deg=-90.0), fill, edge=1.4)]


def _emblem_wolf(fill):
    """Cabeza de lobo de frente: dos orejas y un hocico en punta (Vardheim)."""
    head = poly([(59, 40), (68, 49), (81, 49), (90, 40), (91, 58), (80, 76), (69, 76), (58, 58)])
    eyes = [Sh(poly([(65, 56), (71, 58), (66, 61)]), "#10242E", outline=False),
            Sh(poly([(84, 56), (78, 58), (83, 61)]), "#10242E", outline=False)]
    return [Sh(head, fill, edge=1.4)] + eyes


def _emblem_sun(fill):
    """Sol de rayos triangulares (Solmarch)."""
    out = []
    for i in range(8):
        ang = i * 45.0
        xf = move(74.5, 58) @ rot(ang, 0, 0)
        out.append(Sh(poly([(-4.2, -9), (0, -20), (4.2, -9)], xf), fill, edge=1.2))
    out.append(Sh(ellipse(74.5, 58, 10.5, 10.5), fill, edge=1.4))
    return out


def _emblem_anvil(fill):
    """Yunque (Askarra)."""
    anvil = poly([(56, 46), (93, 46), (90, 53), (82, 56), (80, 66), (88, 72), (88, 77), (61, 77),
                  (61, 72), (69, 66), (67, 56), (59, 53)])
    return [Sh(anvil, fill, edge=1.4)]


def _emblem_crown(fill):
    """Corona rota de cinco puntas (los Huecos)."""
    crown = poly([(58, 74), (58, 46), (66, 57), (74.5, 42), (83, 57), (91, 46), (91, 74)])
    crack = Sh(Path().M(76, 42).L(71, 56).L(78, 62).L(72, 76), stroke="#1E1812", sw=2.4, outline=False)
    return [Sh(crown, fill, edge=1.4), crack]


def _banner(cloth, trim, emblem, emblem_fn=_emblem_star):
    out = []
    out.append(Sh(rect(36, 14, 4.2, 98, 1.5), "wood", ow=2.8, edge=1.4))
    out.append(Sh(poly([(38.1, 4), (44, 16), (32.2, 16)]), "gold", ow=2.6, edge=1.4))
    cloth_shape = poly([(41, 26), (108, 26), (108, 96), (74.5, 82), (41, 96)])
    out.append(Sh(cloth_shape, cloth))
    out.append(Sh(poly([(41, 26), (108, 26), (108, 33), (41, 33)]), trim, edge=1.4))
    out.append(Sh(poly([(74.5, 33), (108, 33), (108, 96), (74.5, 82)]), "#000000", outline=False,
                  op=0.14))
    out.append(Sh(Path().M(46, 40).L(46, 86), stroke="#FFFFFF", sw=2.0, outline=False, op=0.25))
    out += emblem_fn(emblem)
    return out


def banner():
    return _banner("cloth_red", "gold", "gold")


def banner_vardheim():
    return _banner("cloth_blue", "ice", "#EAFBFF", _emblem_wolf)


def banner_solmarch():
    return _banner("cloth_gold", "white", "#FFFFFF", _emblem_sun)


def banner_askarra():
    return _banner("cloth_red", "bronze", "bronze", _emblem_anvil)


def banner_huecos():
    return _banner("cloth_gray", "bone", "#F2EBD8", _emblem_crown)


# --------------------------------------------------------------------------------------------
# Estados
# --------------------------------------------------------------------------------------------


def bleed():
    out = []
    drop = Path().M(62, 12)
    drop.C(62, 12, 24, 54, 24, 78)
    drop.C(24, 98, 40, 112, 62, 112)
    drop.C(84, 112, 100, 98, 100, 78)
    drop.C(100, 54, 62, 12, 62, 12)
    drop.Z()
    out.append(Sh(drop, "blood"))
    out.append(Sh(Path().M(40, 72).Q(40, 92, 54, 98), stroke="#FFC4BC", sw=5, outline=False, op=0.75))
    out.append(Sh(ellipse(46, 66, 3, 3), "#FFFFFF", outline=False, op=0.8))
    small = Path().M(104, 22)
    small.C(104, 22, 90, 38, 90, 47)
    small.C(90, 55, 96, 60, 104, 60)
    small.C(112, 60, 118, 55, 118, 47)
    small.C(118, 38, 104, 22, 104, 22)
    small.Z()
    out.append(Sh(small, "blood"))
    out.append(Sh(ellipse(98, 46, 2, 4, rot(15, 98, 46)), "#FFC4BC", outline=False, op=0.8))
    return out


def stun():
    out = []
    out.append(Sh(Path().arc(64, 72, 44, 15, 0, 360), stroke="#FFE08A", sw=3.4, outline=False, op=0.45))
    out.append(Sh(star(38, 50, 22, 9.5, 5, start_deg=-100.0, round_r=1.5), "gold"))
    out.append(Sh(star(90, 42, 17, 7.5, 5, start_deg=-80.0, round_r=1.4), "gold"))
    out.append(Sh(star(66, 88, 21, 9, 5, start_deg=-92.0, round_r=1.5), "gold"))
    out.append(sparkle(104, 82, 8, "#FFFFFF", outline=False))
    out.append(sparkle(20, 92, 6, "#FFFFFF", outline=False))
    return out


def slowed():
    out = []
    cx, cy = 64, 50
    arms = []
    for i in range(6):
        ang = i * 60.0 - 90.0
        x1, y1 = polar(cx, cy, 33, ang)
        arms.append((ang, x1, y1))
        p = Path().M(cx, cy).L(x1, y1)
        out.append(Sh(p, stroke="#D8F2FF", sw=6.4, outline=True, ow=2.4))
    for ang, x1, y1 in arms:
        bx, by = polar(cx, cy, 21, ang)
        for da in (-52, 52):
            ex, ey = polar(bx, by, 10, ang + da)
            out.append(Sh(Path().M(bx, by).L(ex, ey), stroke="#D8F2FF", sw=4.6, outline=True, ow=2.4))
    out.append(Sh(poly([polar(cx, cy, 9, 30 + 60 * k) for k in range(6)]), "ice"))
    for dy in (0, 13):
        out.append(Sh(Path().M(40, 90 + dy).L(64, 104 + dy).L(88, 90 + dy), stroke="#F4EBD0", sw=7.5,
                      outline=True, ow=2.6))
    return out


def regen():
    out = []
    # cruz verde de cura con destellos y un halo que sube
    for ang in (-35, 215):
        pass
    cross = poly([(52, 24), (76, 24), (76, 52), (104, 52), (104, 76), (76, 76), (76, 104), (52, 104),
                  (52, 76), (24, 76), (24, 52), (52, 52)])
    out.append(Sh(rpoly([(52, 24), (76, 24), (76, 52), (104, 52), (104, 76), (76, 76), (76, 104),
                         (52, 104), (52, 76), (24, 76), (24, 52), (52, 52)], 4), "lime"))
    del cross
    out.append(Sh(Path().M(56, 30).L(56, 56), stroke="#F4FFD0", sw=2.6, outline=False, op=0.75))
    out.append(Sh(Path().M(30, 56).L(56, 56), stroke="#F4FFD0", sw=2.6, outline=False, op=0.5))
    out.append(sparkle(100, 28, 10, "#FFFFFF", outline=False))
    out.append(sparkle(24, 100, 8, "#FFFFFF", outline=False))
    out.append(sparkle(108, 100, 5, "#FFFFFF", outline=False))
    return out


def knockback():
    out = []
    out.append(burst(30, 64, 23, 10, 9, "ember", 4, 1.4))
    out.append(Sh(ellipse(30, 64, 7, 7), "gold", outline=False))
    arrow_shape = poly([(40, 51), (82, 51), (82, 32), (116, 64), (82, 96), (82, 77), (40, 77)])
    out.append(Sh(arrow_shape, "bone"))
    out.append(Sh(poly([(40, 64), (82, 64), (82, 77), (40, 77)]), "#000000", outline=False, op=0.1))
    out.append(Sh(Path().M(46, 57).L(78, 57), stroke="#FFFFFF", sw=2.4, outline=False, op=0.85))
    return out


def downed():
    out = []
    out.append(Sh(Path().M(8, 104).L(120, 104), stroke="#8C8576", sw=4, outline=False, op=0.8))
    # figura tumbada: cabeza, torso, brazo y piernas
    out.append(Sh(rect(40, 74, 50, 22, 10), "cloth_red"))
    out.append(Sh(ellipse(30, 80, 13, 13), "skin"))
    leg = Path().M(86, 84).L(104, 66).L(116, 92)
    out.append(Sh(leg, stroke="#8A5E34", sw=11, outline=True, ow=2.8, join="round"))
    arm = Path().M(52, 78).L(46, 56)
    out.append(Sh(arm, stroke="#F6D0A4", sw=9, outline=True, ow=2.6))
    out.append(Sh(Path().M(34, 76).L(40, 74), stroke="#2A170A", sw=2.0, outline=False))
    # chevrón naranja hacia abajo
    for dy in (0, 12):
        out.append(Sh(Path().M(52, 18 + dy).L(66, 32 + dy).L(80, 18 + dy), stroke="#FFA54A", sw=8,
                      outline=True, ow=2.6))
    return out


# --------------------------------------------------------------------------------------------
# Registro: nombre -> (categoría, título en español, constructor)
# --------------------------------------------------------------------------------------------

ICONS = {
    "sword_light": ("ataque", "Ataque ligero", sword_light),
    "sword_heavy": ("ataque", "Ataque fuerte", sword_heavy),
    "block": ("defensa", "Bloqueo", block),
    "dodge": ("defensa", "Esquiva", dodge),
    "shield_bash": ("habilidad", "Golpe de escudo", shield_bash),
    "shield_rush": ("habilidad", "Embestida", shield_rush),
    "shield_wall": ("habilidad", "Muro de escudos", shield_wall),
    "bow_quick": ("ataque", "Disparo rápido", bow_quick),
    "bow_drawn": ("ataque", "Disparo tensado", bow_drawn),
    "bow_volley": ("habilidad", "Descarga", bow_volley),
    "bow_slowing_shot": ("habilidad", "Disparo ralentizador", bow_slowing_shot),
    "bow_evasive_shot": ("habilidad", "Disparo evasivo", bow_evasive_shot),
    "potion_health": ("consumible", "Poción de vida", potion_health),
    "potion_stamina": ("consumible", "Poción de resistencia", potion_stamina),
    "swap_weapon": ("mundo", "Cambiar de arma", swap_weapon),
    "interact": ("mundo", "Interactuar", interact),
    "bleed": ("estado", "Sangrado", bleed),
    "regen": ("estado", "Regeneración", regen),
    "stun": ("estado", "Aturdimiento", stun),
    "slowed": ("estado", "Ralentización", slowed),
    "knockback": ("estado", "Empuje", knockback),
    "downed": ("estado", "Derribado", downed),
    "fort": ("mundo", "Fuerte", fort),
    "gate": ("mundo", "Puerta", gate),
    "camp": ("mundo", "Campamento", camp),
    "banner": ("mundo", "Estandarte", banner),
    "banner_vardheim": ("mundo", "Estandarte de Vardheim", banner_vardheim),
    "banner_solmarch": ("mundo", "Estandarte de Solmarch", banner_solmarch),
    "banner_askarra": ("mundo", "Estandarte de Askarra", banner_askarra),
    "banner_huecos": ("mundo", "Estandarte de los Huecos", banner_huecos),
}
