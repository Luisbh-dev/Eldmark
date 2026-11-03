"""Glifos de los iconos de la interfaz (ART-12): cada función devuelve la lista de figuras de un icono.

Lienzo de 128 x 128. Luz arriba a la izquierda. Las piezas reutilizables (espada, escudos, yelmo,
arco, flecha...) se construyen con una transformación `xf` para poder colocarlas giradas; los
degradados no giran con ellas (ver svgkit).

No hace falta centrar ni escalar a mano: `svgkit.fit_transform` mide la silueta y la lleva a un 35 a
55 % del interior, centrada. Sí hay que respetar las zonas seguras de la casilla: la esquina de
arriba a la izquierda es del rótulo de tecla y la de abajo a la derecha del contador, así que las
figuras largas van por la diagonal que sube a la derecha.

Cada icono se distingue por la SILUETA de los que comparten barra (esa es la prueba que hace
`qa.py`): el bloqueo es un escudo de frente con la espada rebotando, el golpe de escudo uno de
perfil contra un yelmo, la embestida un cuerpo inclinado tras el escudo y el muro de escudos una
fila de escudos altos con lanzas detrás. Los estados llevan además una variante pequeña
(`SMALL_ICONS`) para las placas de nombre y la fila de efectos.
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


def tube(path, color, sw, ow=2.8, **kw):
    """Trazo grueso con contorno (raíces, patas, flechas curvas)."""
    return Sh(path, stroke=color, sw=sw, outline=True, ow=ow, **kw)


def tip_xf(tip, ang, length):
    """Transformación que coloca una espada (ver `sword`) con la punta en `tip` y el eje apuntando de
    la punta a la empuñadura según `ang` (grados, 0 = derecha, 90 = abajo)."""
    gx = tip[0] + length * math.cos(math.radians(ang))
    gy = tip[1] + length * math.sin(math.radians(ang))
    return move(gx, gy) @ rot(ang - 90.0)


def sword(xf, length=64, w=12, gw=34, gh=7, grip=15, guard="bronze"):
    """Espada con la punta hacia arriba y el centro de la cruz en el origen."""
    hb = gh / 2.0
    out = []
    out.append(Sh(poly([(0, -length), (-w / 2, -length + 15), (-w / 2, -hb), (0, -hb)], xf),
                  "steel", edge=0))
    out.append(Sh(poly([(0, -length), (w / 2, -length + 15), (w / 2, -hb), (0, -hb)], xf),
                  "steel_dark", edge=0))
    out.append(Sh(Path(xf).M(0, -length + 12).L(0, -hb - 2), stroke="#53626F", sw=1.6, outline=False,
                  op=0.55))
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


def tall_shield(x, y, w, h, band="cloth_red"):
    """Escudo alto de frente (de muro): aro de hierro, cara de madera con una franja y un centro de metal."""
    out = []
    out.append(Sh(rpoly([(x, y), (x + w, y), (x + w, y + h), (x, y + h)], [w * 0.42, w * 0.42, 5, 5]),
                  "steel_dark", edge=1.8))
    inset = 3.4
    face = rpoly([(x + inset, y + inset), (x + w - inset, y + inset), (x + w - inset, y + h - inset),
                  (x + inset, y + h - inset)], [w * 0.36, w * 0.36, 3, 3])
    out.append(Sh(face, "wood", edge=1.2))
    cx = x + w / 2.0
    out.append(Sh(Path().M(cx, y + 8).L(cx, y + h - 6), stroke="#3A210C", sw=1.4, outline=False, op=0.5))
    out.append(Sh(rect(x + inset, y + h * 0.55, w - 2 * inset, h * 0.13), band, outline=False, edge=0))
    out.append(Sh(ellipse(cx, y + h * 0.36, w * 0.24, w * 0.24), "steel"))
    out.append(Sh(ellipse(cx - 1.2, y + h * 0.36 - 1.4, w * 0.07, w * 0.06), "#FFFFFF", outline=False,
                  op=0.85))
    return out


def helm(cx, cy, s=1.0, rot_deg=0.0, plume=None):
    """Yelmo cerrado de frente con la visera en el centro (origen en el centro del casco)."""
    xf = move(cx, cy) @ rot(rot_deg) @ scale(s)
    out = []
    if plume:
        out.append(Sh(swoosh((6, -34), (-38, -6), 12, 4, xf), plume, edge=1.4))
    shell = Path(xf).M(-24, 26).L(-26, -4)
    shell.C(-26, -30, -11, -37, 0, -37)
    shell.C(11, -37, 26, -30, 26, -4)
    shell.L(24, 26).Q(0, 33, -24, 26).Z()
    out.append(Sh(shell, "steel"))
    out.append(Sh(rect(-4, -37, 8, 60, 2, xf), "steel_dark", outline=False, edge=0, op=0.9))
    out.append(Sh(rpoly([(-20, -6), (20, -6), (19, 2), (-19, 2)], 2.4, xf), "#14100C", outline=False))
    for hx, hy in ((9, 12), (15, 12), (9, 18), (15, 18), (-9, 12), (-15, 12), (-9, 18), (-15, 18)):
        out.append(Sh(ellipse(hx, hy, 1.7, 1.7, xf), "#14100C", outline=False, op=0.85))
    out.append(Sh(Path(xf).M(-19, -26).Q(-22, -12, -21, -9), stroke="#FFFFFF", sw=2.2, outline=False,
                  op=0.75))
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
    out.append(Sh(rect(belly - thick / 2 - 1.8, -10, thick + 3.6, 20, 3.0, xf), "leather"))
    for sy in (-1, 1):
        out.append(Sh(ellipse(-tip_back, sy * h2, 3.4, 3.4, xf), "bone", edge=1.4))
    return out


def string(xf, height, tip_back, nock_x=None, color="#F6F0DA", width=2.2):
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
    fl = min(shaft * 1.9, 14.0)
    vl = min(shaft * 3.2, 20.0)
    for sy in (-1, 1):
        fx = poly([(1, sy * shaft / 2), (vl, sy * shaft / 2), (vl * 0.56, sy * (shaft / 2 + fl)),
                   (-min(shaft, 9.0), sy * (shaft / 2 + fl))], xf)
        out.append(Sh(fx, fletch, ow=2.4, edge=1.4))
    hw = head * 0.9
    out.append(Sh(poly([(length - head, -hw / 2), (length, 0), (length - head, 0)], xf), head_mat,
                  ow=2.6, edge=0))
    out.append(Sh(poly([(length - head, 0), (length, 0), (length - head, hw / 2)], xf),
                  tip_mat or "steel_dark", ow=2.6, edge=0))
    return out


def _arrow_head(cx, cy, ang, size, fill, **kw):
    """Punta de flecha triangular centrada en (cx, cy) que mira hacia `ang` grados."""
    xf = move(cx, cy) @ rot(ang, 0, 0)
    return Sh(poly([(size, 0), (-size * 0.6, -size * 0.85), (-size * 0.6, size * 0.85)], xf), fill, **kw)


def curved_arrow(p0, c, p2, width, head, color, head_mat):
    """Flecha curva gruesa por la cuadrática p0-c-p2, con la punta (de largo `head`) en p2."""

    def at(t):
        a = ((1 - t) * p0[0] + t * c[0], (1 - t) * p0[1] + t * c[1])
        b = ((1 - t) * c[0] + t * p2[0], (1 - t) * c[1] + t * p2[1])
        return ((1 - t) * a[0] + t * b[0], (1 - t) * a[1] + t * b[1])

    t_end = 1.0
    while t_end > 0.3 and math.hypot(at(t_end)[0] - p2[0], at(t_end)[1] - p2[1]) < head * 0.78:
        t_end -= 0.01
    # subcurva de p0 a at(t_end): mismo control reescalado
    a = ((1 - t_end) * p0[0] + t_end * c[0], (1 - t_end) * p0[1] + t_end * c[1])
    end = at(t_end)
    out = [Sh(Path().M(*p0).Q(a[0], a[1], end[0], end[1]), stroke=color, sw=width, outline=True,
              ow=2.6, cap="butt")]
    ang = math.degrees(math.atan2(p2[1] - c[1], p2[0] - c[0]))
    size = head / 1.6
    cx = p2[0] - size * math.cos(math.radians(ang))
    cy = p2[1] - size * math.sin(math.radians(ang))
    out.append(_arrow_head(cx, cy, ang, size, head_mat, ow=2.6))
    return out


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


def dust(cx, cy, r, op=0.85):
    return Sh(ellipse(cx, cy, r, r * 0.8), "dust", outline=False, op=op, relief=True)


# --------------------------------------------------------------------------------------------
# Ataque
# --------------------------------------------------------------------------------------------


def sword_light():
    out = [Sh(swoosh((8, 78), (114, 42), 38, 19), "white", outline=False, op=0.9)]
    out.append(Sh(swoosh((22, 76), (106, 49), 28, 17), "#FFFFFF", outline=False, op=0.45))
    out += sword(move(42, 90) @ rot(45), length=76, w=18, gw=44, gh=10, grip=17)
    out.append(sparkle(106, 28, 10, "#FFFFFF", outline=False))
    return out


def sword_heavy():
    """Golpe desde arriba: la espada clavada en vertical, con la onda del impacto abierta a los lados."""
    out = [Sh(ellipse(60, 106, 50, 10), "dust", outline=False, op=0.8)]
    out.append(burst(60, 98, 34, 15, 11, "ember", 4, 1.6))
    out.append(burst(60, 98, 21, 9, 11, "gold", 4, 1.2, outline=False))
    for x, y, r in ((20, 82, 4), (100, 78, 3.5), (30, 62, 3), (92, 58, 3), (46, 76, 2.6)):
        out.append(Sh(ellipse(x, y, r, r), "ember", outline=False, op=0.9))
    out += sword(move(60, 42) @ rot(180), length=64, w=21, gw=50, gh=11, grip=16)
    return out


def bow_quick():
    """Dos flechas en vuelo con rayas de velocidad."""
    out = []
    for y, x0, x1 in ((40, 4, 32), (66, 0, 28), (92, 6, 32), (112, 4, 24)):
        out.append(Sh(Path().M(x0, y).L(x1, y), stroke="#F4F1E8", sw=4.0, outline=False, op=0.8))
    out += arrow(move(12, 48) @ rot(-4), length=106, head=31, shaft=11.5, fletch="cloth_red")
    out += arrow(move(12, 88) @ rot(-4), length=106, head=31, shaft=11.5, fletch="cloth_red")
    return out


def bow_drawn():
    """Arco vertical tensado del todo: cuerda en V hasta la muesca, que brilla cargada."""
    out = []
    out.append(Sh(ellipse(36, 64, 26, 26), "ember", outline=False, op=0.32))
    out.append(burst(36, 64, 22, 10, 8, "gold", 0, 1.0, outline=False, op=0.9))
    out += bow(move(88, 64), height=98, belly=22, thick=15, tip_back=20)
    out.append(string(move(88, 64), 98, 20, nock_x=-52, width=3.0))
    out += arrow(move(32, 64), length=88, head=28, shaft=10.0, fletch="cloth_red")
    out.append(sparkle(36, 64, 14, "#FFFFFF", outline=False))
    return out


# --------------------------------------------------------------------------------------------
# Defensa
# --------------------------------------------------------------------------------------------


def block():
    """Escudo de frente y la espada rebotando contra el canto; la espada va por encima del aro."""
    out = []
    out += round_shield(50, 78, 42)
    out += sword(tip_xf((83, 50), -48, 40), length=40, w=13, gw=30, gh=7, grip=13)
    out.append(burst(83, 50, 21, 8, 9, "gold", 10, 1.0))
    out.append(Sh(ellipse(83, 50, 7, 7), "white", outline=False))
    out.append(Sh(Path().M(70, 34).L(76, 26), stroke="#FFF3C0", sw=3.4, outline=False))
    out.append(Sh(Path().M(104, 58).L(114, 62), stroke="#FFF3C0", sw=3.4, outline=False))
    out.append(Sh(Path().M(98, 78).L(108, 88), stroke="#FFF3C0", sw=3.0, outline=False, op=0.8))
    return out


def dodge():
    """Una figura de capa roja rodando hacia delante, con su estela de siluetas detrás."""
    out = []
    ang = rot(-20, 74, 66)
    # estelas: siluetas planas que se desvanecen y rayas de velocidad
    for dx, op in ((-52, 0.18), (-30, 0.32)):
        out.append(Sh(ellipse(74 + dx, 66, 28, 24, ang), "#D8D0BC", outline=False, op=op, relief=False))
        out.append(Sh(ellipse(102 + dx, 84, 12, 12), "#D8D0BC", outline=False, op=op * 0.8, relief=False))
    for y, x0, x1 in ((38, 4, 30), (104, 6, 30), (118, 0, 22)):
        out.append(Sh(Path().M(x0, y).L(x1, y), stroke="#F4F1E8", sw=4.0, outline=False, op=0.7))
    # capa que ondea hacia atrás
    cape = Path().M(64, 42).Q(34, 24, -14, 38).Q(18, 50, -6, 66).Q(30, 62, 60, 84).Z()
    out.append(Sh(cape, "cloth_red", edge=1.6))
    # botas atrás
    out.append(Sh(ellipse(44, 94, 13, 9, rot(28, 44, 94)), "leather"))
    out.append(Sh(ellipse(56, 106, 12, 8.5, rot(14, 56, 106)), "leather"))
    # torso encogido, con cinto y costura
    out.append(Sh(ellipse(76, 66, 29, 26, ang), "cloth_bone"))
    out.append(Sh(Path().arc(76, 66, 24, 21, 20, 118, -20), stroke="#5A3A1C", sw=5, outline=False))
    out.append(Sh(Path().arc(76, 66, 21, 18, 215, 275, -20), stroke="#8C826A", sw=2.0, outline=False, op=0.7))
    # cabeza metida hacia delante, con la cofia
    out.append(Sh(ellipse(104, 86, 14, 14), "skin"))
    cap = Path().arc(104, 86, 14.5, 14.5, 150, 330)
    cap.Z()
    out.append(Sh(cap, "wood_dark", outline=False, edge=0))
    out.append(Sh(ellipse(109, 90, 2.0, 2.0), "#2A170A", outline=False))
    # mano apoyada
    out.append(Sh(ellipse(88, 101, 9, 8), "skin"))
    # flecha curva de giro por encima, en sentido horario
    out += curved_arrow((34, 52), (74, 14), (112, 54), 6.0, 17, "#F4EBD0", "bone")
    return out


# --------------------------------------------------------------------------------------------
# Habilidades
# --------------------------------------------------------------------------------------------


def shield_bash():
    """Escudo de perfil empujado contra un yelmo, con la estrella del impacto entre los dos."""
    out = []
    out += helm(94, 60, 1.08)
    # escudo de canto, con el centro de metal hacia el yelmo
    out.append(Sh(ellipse(34, 68, 21, 47), "steel_dark"))
    out.append(Sh(ellipse(33, 68, 15.5, 41), "wood", edge=1.6))
    for dy in (-20, -7, 7, 20):
        out.append(Sh(Path().M(22, 68 + dy).L(44, 68 + dy + (1 if dy > 0 else -1)), stroke="#3A210C",
                      sw=1.6, outline=False, op=0.5))
    out.append(Sh(Path().arc(34, 68, 18, 44, 195, 255), stroke="#FFFFFF", sw=2.0, outline=False, op=0.7))
    out.append(Sh(ellipse(46, 68, 14, 14), "steel"))
    out.append(Sh(ellipse(42, 63, 4.5, 4), "#FFFFFF", outline=False, op=0.8))
    out.append(burst(66, 58, 26, 11, 9, "ember", 8, 1.5))
    out.append(burst(66, 58, 15, 6.5, 9, "gold", 8, 1.0, outline=False))
    out.append(Sh(Path().M(70, 24).L(76, 14), stroke="#FFE8A8", sw=3.4, outline=False))
    out.append(Sh(Path().M(50, 26).L(44, 16), stroke="#FFE8A8", sw=3.4, outline=False))
    return out


def shield_rush():
    """Un guerrero inclinado hacia delante tras su escudo, con las rayas de la carrera detrás."""
    out = []
    for y, x0, x1, w in ((34, 4, 40, 5.0), (52, 0, 36, 6.0), (70, 4, 34, 5.0)):
        out.append(Sh(Path().M(x0, y).L(x1, y), stroke="#F4F1E8", sw=w, outline=False, op=0.8))
    out.append(dust(18, 110, 8))
    out.append(dust(34, 114, 9))
    out.append(dust(8, 102, 5.5))
    # pierna de atrás, estirada
    out.append(tube(Path().M(52, 82).Q(42, 98, 26, 105), "#6B4E2E", 13))
    out.append(Sh(ellipse(24, 107, 9, 6, rot(-20, 24, 107)), "wood_dark"))
    # torso inclinado
    out.append(Sh(rect(-14, -23, 28, 46, 11, move(60, 62) @ rot(30)), "cloth_red"))
    out.append(Sh(Path().M(46, 80).L(66, 86), stroke="#432A12", sw=4.5, outline=False, op=0.8))
    # pierna de delante, flexionada
    out.append(tube(Path().M(68, 84).Q(90, 86, 86, 106), "#7C5A36", 13))
    out.append(Sh(ellipse(88, 108, 10, 6, rot(8, 88, 108)), "wood_dark"))
    # brazo hacia el escudo, hombrera y cabeza con casco y penacho
    out.append(tube(Path().M(72, 54).L(96, 66), "#9E3C34", 10, ow=2.4))
    out.append(Sh(ellipse(72, 48, 12, 9, rot(28, 72, 48)), "steel"))
    plume = Path().M(70, 26).Q(46, 16, 36, 32)
    plume.Q(52, 30, 68, 38).Z()
    out.append(Sh(plume, "cloth_red", edge=1.4))
    out.append(Sh(ellipse(80, 36, 14, 14), "steel"))
    out.append(Sh(rect(86, 32, 9, 3.6, 1.2), "#14100C", outline=False))
    out.append(Sh(Path().M(70, 26).Q(74, 22, 80, 22), stroke="#FFFFFF", sw=2.0, outline=False, op=0.7))
    # escudo grande por delante
    shield = [(92, 38), (116, 44), (118, 74), (104, 108), (92, 80)]
    out.append(Sh(rpoly(shield, 9), "steel_dark"))
    inner = [(96, 44), (112, 49), (113, 72), (103, 98), (96, 77)]
    out.append(Sh(rpoly(inner, 6), "wood", edge=1.4))
    out.append(Sh(Path().M(98, 66).L(112, 68), stroke="#C9B87E", sw=7, outline=False, cap="butt", op=0.9))
    out.append(Sh(ellipse(105, 62, 6.5, 6.5), "steel"))
    return out


def shield_wall():
    """Fila de escudos altos canto con canto, con las lanzas asomando por detrás: un rectángulo bajo."""
    out = []
    w, h, y = 29, 50, 64
    for i in range(4):
        cx = 6 + i * 27 + w / 2.0
        out.append(tube(Path().M(cx, 78).L(cx, 24), "#B98A52", 5.0, ow=2.4))
        head = poly([(cx, 2), (cx + 8.5, 20), (cx, 29), (cx - 8.5, 20)])
        out.append(Sh(head, "steel", ow=2.8))
    for i in range(4):
        out += tall_shield(6 + i * 27, y, w, h)
    return out


def bow_volley():
    out = []
    r = rot(-12, 64, 70)
    out += bow(r @ move(64, 108) @ rot(-90), height=100, belly=14, thick=14, tip_back=14)
    for ang in (-32, 0, 32):
        xf = r @ move(64, 98) @ rot(ang - 90)
        out += arrow(xf, length=82, head=25, shaft=8.5)
    out.append(string(r @ move(64, 108) @ rot(-90), 100, 14, width=2.8))
    return out


def bow_slowing_shot():
    out = []
    xf = move(10, 100) @ rot(-22)
    for x, y, r in ((18, 72, 8), (46, 100, 6.5), (6, 96, 6)):
        out.append(sparkle(x, y, r * 1.6, "ice", outline=False))
    out += arrow(xf, length=94, head=14, shaft=19.0, head_mat="ice", tip_mat="ice", fletch="cloth_blue")
    tip = xf(88, 0)
    crystal = poly([(tip[0] - 2, tip[1] - 48), (tip[0] + 29, tip[1] - 4), (tip[0] + 5, tip[1] + 48),
                    (tip[0] - 28, tip[1] + 4)])
    out.append(Sh(crystal, "ice", ow=3.6))
    out.append(Sh(poly([(tip[0] - 2, tip[1] - 48), (tip[0] - 28, tip[1] + 4), (tip[0] - 1, tip[1] - 1)]),
                  "white", outline=False, op=0.8))
    out.append(Sh(poly([(tip[0] - 2, tip[1] - 30), (tip[0] + 12, tip[1] - 3), (tip[0] - 2, tip[1] - 1)]),
                  "#FFFFFF", outline=False, op=0.35))
    out.append(sparkle(tip[0] + 22, tip[1] - 38, 11, "#FFFFFF", outline=False))
    return out


def bow_evasive_shot():
    out = []
    out += arrow(move(26, 72) @ rot(-34), length=94, head=34, shaft=17.0)
    for cx, cy, r in ((112, 112, 8), (122, 100, 5.5), (100, 122, 5)):
        out.append(dust(cx, cy, r))
    out += curved_arrow((104, 114), (74, 66), (40, 116), 22, 34, "#F4EBD0", "bone")
    return out


# --------------------------------------------------------------------------------------------
# Consumibles
# --------------------------------------------------------------------------------------------


def potion_health():
    out = []
    out.append(Sh(rpoly([(52, 22), (76, 22), (76, 52), (52, 52)], 3), "glass"))
    out.append(Sh(ellipse(64, 80, 32, 32), "glass"))
    liquid = Path()
    liquid.arc(64, 80, 30, 30, 205, -25)
    liquid.Z()
    out.append(Sh(liquid, "blood", outline=False))
    out.append(Sh(Path().M(38, 72).Q(52, 64, 64, 70).Q(76, 76, 90, 68), stroke="#FFB0A8", sw=2.4,
                  outline=False, op=0.8))
    out.append(Sh(ellipse(50, 72, 5.5, 10, rot(25, 50, 72)), "#FFFFFF", outline=False, op=0.65))
    out.append(Sh(rpoly([(50, 8), (78, 8), (76, 24), (52, 24)], 3), "wood"))
    out.append(Sh(Path().M(54, 13).L(74, 13), stroke="#FFE2B0", sw=1.8, outline=False, op=0.5))
    out.append(Sh(poly([(60, 78), (68, 78), (68, 84), (74, 84), (74, 92), (68, 92), (68, 98), (60, 98),
                        (60, 92), (54, 92), (54, 84), (60, 84)]), "#FFF4EC", outline=False, op=0.9))
    return out


def potion_stamina():
    """Matraz de cuello largo y base ancha, inclinado, con el líquido verde y un rayo."""
    out = []
    T = move(64, 64) @ rot(32) @ move(-64, -64)
    flask = rpoly([(54, 14), (74, 14), (74, 44), (106, 98), (106, 108), (22, 108), (22, 98), (54, 44)],
                  [3, 3, 4, 14, 14, 14, 14, 4], T)
    out.append(Sh(flask, "glass"))
    liquid = rpoly([(36, 76), (92, 76), (106, 98), (106, 104), (22, 104), (22, 98)], [2, 2, 12, 12, 12, 12], T)
    out.append(Sh(liquid, "lime", outline=False))
    out.append(Sh(Path(T).M(38, 76).L(90, 76), stroke="#EFFFC0", sw=2.2, outline=False, op=0.8))
    out.append(Sh(poly([(72, 78), (50, 96), (62, 96), (54, 110), (82, 90), (68, 90), (78, 78)], T),
                  "#FFF6D0", outline=False, edge=1.6, op=1.0))
    out.append(Sh(ellipse(55, 56, 3.4, 11, T @ rot(-14, 55, 56)), "#FFFFFF", outline=False, op=0.5))
    out.append(Sh(rpoly([(52, 4), (76, 4), (74, 18), (54, 18)], 3, T), "wood"))
    out.append(Sh(Path(T).M(56, 9).L(72, 9), stroke="#FFE2B0", sw=1.8, outline=False, op=0.5))
    return out


# --------------------------------------------------------------------------------------------
# Mundo: cambiar de arma, armas, interactuar, fuerte, puerta, campamento y estandarte
# --------------------------------------------------------------------------------------------


def swap_weapon():
    out = []
    out += sword(move(40, 78) @ rot(18), length=64, w=15, gw=34, gh=8, grip=13)
    out += bow(move(76, 54), height=82, belly=14, thick=11, tip_back=10)
    out.append(string(move(76, 54), 82, 10, width=2.6))
    bx, by = 90, 94
    out.append(Sh(ellipse(bx, by, 22, 22), "iron"))
    out.append(Sh(ellipse(bx, by, 16.5, 16.5), "#262A33", outline=False, edge=1.4))
    for start in (200, 20):
        p = Path()
        p.arc(bx, by, 12, 12, start, start + 120)
        out.append(Sh(p, stroke="#F4EBD0", sw=5.5, outline=False, cap="butt"))
        ex, ey = polar(bx, by, 12, start + 120)
        out.append(_arrow_head(ex, ey, start + 120 + 90, 7.5, "bone", outline=False, edge=0))
    return out


def weapon_sword_shield():
    """Espada y escudo como equipo: un escudo de lágrima a un lado y la espada recta al otro."""
    out = []
    out += sword(move(94, 58) @ rot(8), length=82, w=17, gw=40, gh=9, grip=18)
    kite = [(8, 30), (76, 30), (76, 62), (42, 118), (8, 62)]
    out.append(Sh(rpoly(kite, [12, 12, 8, 12, 8]), "steel_dark"))
    inner = [(14, 36), (70, 36), (70, 60), (42, 108), (14, 60)]
    out.append(Sh(rpoly(inner, [9, 9, 6, 9, 6]), "wood", edge=1.4))
    out.append(Sh(poly([(14, 36), (42, 36), (14, 66)]), "cloth_red", outline=False, edge=0, op=0.95))
    out.append(Sh(Path().M(42, 40).L(42, 100), stroke="#3A210C", sw=1.6, outline=False, op=0.5))
    out.append(Sh(ellipse(42, 62, 11, 11), "steel"))
    out.append(Sh(ellipse(39, 58, 3.6, 3.2), "#FFFFFF", outline=False, op=0.85))
    return out


def weapon_bow():
    """Arco con su carcaj de flechas al lado, todo inclinado para dejar libres las esquinas de la casilla."""
    out = []
    t = rot(14, 64, 64)
    q = t @ move(98, 78) @ rot(14)
    for dx, tilt in ((-8, -6), (2, 0), (12, 6)):
        axf = q @ move(dx, -8) @ rot(tilt)
        out.append(Sh(rect(-2.2, -44, 4.4, 40, 1.0, axf), "wood", ow=2.2, edge=1.0))
        for sy in (-1, 1):
            out.append(Sh(poly([(sy * 1.6, -44), (sy * 7.5, -52), (sy * 7.5, -36), (sy * 1.6, -30)], axf),
                          "cloth_red", ow=2.0, edge=1.0))
    out.append(Sh(rpoly([(-17, -12), (17, -12), (13, 46), (-13, 46)], 6, q), "leather"))
    out.append(Sh(rect(-17, -12, 34, 9, 3, q), "bronze", edge=1.4))
    out.append(Sh(rect(-14, 28, 28, 7, 2, q), "wood_dark", edge=1.2))
    out += bow(t @ move(46, 64), height=116, belly=22, thick=15, tip_back=18)
    out.append(string(t @ move(46, 64), 116, 18, width=3.0))
    return out


def interact():
    out = []
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
    out.append(sparkle(22, 40, 9, "#FFE8A0", outline=False))
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
    out.append(Sh(rect(44, 38, 40, 66, 2), "stone"))
    out += _crenel(44, 40, 40, 3, 9)
    out.append(Sh(rect(18, 58, 30, 46, 2), "stone_dark"))
    out += _crenel(18, 60, 30, 3, 8, "stone_dark")
    out.append(Sh(rect(80, 58, 30, 46, 2), "stone_dark"))
    out += _crenel(80, 60, 30, 3, 8, "stone_dark")
    for y in (54, 68, 82):
        out.append(Sh(Path().M(46, y).L(82, y), stroke="#2E2B26", sw=1.4, outline=False, op=0.35))
    gate_ = Path().M(54, 104).L(54, 86).Q(54, 74, 64, 74).Q(74, 74, 74, 86).L(74, 104).Z()
    out.append(Sh(gate_, "#1E1812", outline=False))
    out.append(Sh(rect(61.5, 48, 5, 14, 2), "#1E1812", outline=False))
    out.append(Sh(rect(28, 70, 4.5, 12, 2), "#1E1812", outline=False))
    out.append(Sh(rect(95, 70, 4.5, 12, 2), "#1E1812", outline=False))
    out.append(Sh(rect(63, 4, 3.4, 34, 1), "wood_dark", ow=2.4, edge=1.2))
    out.append(Sh(poly([(66.4, 6), (92, 14), (66.4, 24)]), "cloth_red", ow=2.6, edge=1.4))
    return out


def gate():
    out = []
    out.append(Sh(rect(14, 36, 100, 70, 2), "stone"))
    out += _crenel(14, 38, 100, 6, 10)
    arch = Path().M(36, 106).L(36, 66).Q(36, 42, 64, 42).Q(92, 42, 92, 66).L(92, 106).Z()
    out.append(Sh(arch, "wood", ow=2.0, edge=2.0))
    for x in (50, 64, 78):
        out.append(Sh(Path().M(x, 46).L(x, 106), stroke="#3A210C", sw=1.8, outline=False, op=0.55))
    for y in (70, 90):
        out.append(Sh(rect(36, y - 3.5, 56, 7, 1.5), "iron", outline=False, edge=1.4, relief=True))
        for x in (42, 86):
            out.append(Sh(ellipse(x, y, 1.6, 1.6), "#EDEDED", outline=False, op=0.9))
    out.append(Sh(ellipse(64, 80, 5.5, 5.5), "gold", outline=False, edge=1.6, relief=True))
    out.append(Sh(Path().M(64, 46).L(64, 106), stroke="#1E1812", sw=2.0, outline=False, op=0.8))
    out.append(Sh(poly([(58, 36), (70, 36), (68, 48), (60, 48)]), "stone_dark", edge=1.4))
    return out


def camp():
    out = []
    out.append(Sh(ellipse(60, 104, 52, 7), "#000000", outline=False, op=0.3))
    out.append(Sh(poly([(10, 102), (52, 32), (52, 102)]), "cloth_bone", edge=0))
    out.append(Sh(poly([(52, 32), (96, 102), (52, 102)]), "cloth_gray", edge=0))
    out.append(Sh(poly([(52, 54), (68, 102), (36, 102)]), "#2A1E14", outline=False))
    out.append(Sh(poly([(52, 54), (60, 78), (52, 102)]), "#150E08", outline=False, op=0.6))
    out.append(Sh(Path().M(30, 66).L(52, 40).L(74, 66), stroke="#B0443A", sw=4.0, outline=False))
    out.append(Sh(rect(51, 12, 3, 24, 1), "wood_dark", ow=2.4, edge=1.2))
    out.append(Sh(poly([(54, 13), (72, 19), (54, 26)]), "cloth_red", ow=2.6, edge=1.4))
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
                  op=0.14, relief=False))
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


def _drop(cx, top, bottom, half, fill="blood"):
    p = Path().M(cx, top)
    p.C(cx, top, cx - half, top + (bottom - top) * 0.46, cx - half, top + (bottom - top) * 0.7)
    p.C(cx - half, bottom - (bottom - top) * 0.12, cx - half * 0.55, bottom, cx, bottom)
    p.C(cx + half * 0.55, bottom, cx + half, bottom - (bottom - top) * 0.12, cx + half,
        top + (bottom - top) * 0.7)
    p.C(cx + half, top + (bottom - top) * 0.46, cx, top, cx, top)
    p.Z()
    return Sh(p, fill)


def bleed():
    out = []
    out.append(_drop(58, 8, 118, 40))
    out.append(Sh(Path().M(34, 82).Q(34, 102, 50, 108), stroke="#FFC4BC", sw=6, outline=False, op=0.75))
    out.append(Sh(ellipse(42, 70, 3.6, 3.6), "#FFFFFF", outline=False, op=0.8))
    out.append(_drop(106, 18, 66, 18))
    out.append(Sh(ellipse(100, 48, 2.4, 5, rot(15, 100, 48)), "#FFC4BC", outline=False, op=0.8))
    return out


def regen():
    out = []
    pts = [(48, 14), (80, 14), (80, 48), (114, 48), (114, 80), (80, 80), (80, 114), (48, 114), (48, 80),
           (14, 80), (14, 48), (48, 48)]
    out.append(Sh(rpoly(pts, 5), "lime"))
    out.append(Sh(Path().M(54, 22).L(54, 52), stroke="#F4FFD0", sw=3.0, outline=False, op=0.75))
    out.append(Sh(Path().M(22, 54).L(52, 54), stroke="#F4FFD0", sw=3.0, outline=False, op=0.5))
    out.append(sparkle(104, 20, 11, "#FFFFFF", outline=False))
    out.append(sparkle(20, 106, 8, "#FFFFFF", outline=False))
    out.append(sparkle(112, 108, 5, "#FFFFFF", outline=False))
    return out


def stun():
    """Estrellas girando alrededor de un yelmo."""
    out = []
    out += helm(64, 82, 0.98)
    out.append(Sh(Path().arc(64, 40, 48, 14, 0, 360), stroke="#FFE08A", sw=3.4, outline=False, op=0.5))
    out.append(Sh(star(22, 44, 21, 9, 5, start_deg=-100.0, round_r=1.5), "gold"))
    out.append(Sh(star(106, 40, 19, 8.4, 5, start_deg=-80.0, round_r=1.4), "gold"))
    out.append(Sh(star(64, 18, 20, 8.6, 5, start_deg=-92.0, round_r=1.5), "gold"))
    out.append(sparkle(96, 66, 7, "#FFFFFF", outline=False))
    out.append(sparkle(30, 70, 6, "#FFFFFF", outline=False))
    return out


def slowed():
    out = []
    cx, cy = 64, 50
    arms = []
    for i in range(6):
        ang = i * 60.0 - 90.0
        x1, y1 = polar(cx, cy, 38, ang)
        arms.append((ang, x1, y1))
        out.append(Sh(Path().M(cx, cy).L(x1, y1), stroke="#D8F2FF", sw=8.4, outline=True, ow=2.4))
    for ang, x1, y1 in arms:
        bx, by = polar(cx, cy, 23, ang)
        for da in (-52, 52):
            ex, ey = polar(bx, by, 12, ang + da)
            out.append(Sh(Path().M(bx, by).L(ex, ey), stroke="#D8F2FF", sw=6.0, outline=True, ow=2.4))
    out.append(Sh(poly([polar(cx, cy, 12, 30 + 60 * k) for k in range(6)]), "ice"))
    for dy in (0, 14):
        out.append(Sh(Path().M(36, 98 + dy).L(64, 112 + dy).L(92, 98 + dy), stroke="#F4EBD0", sw=9,
                      outline=True, ow=2.6))
    return out


def knockback():
    """Impacto y, saliendo de él, una flecha gruesa que lo aleja; con el polvo del arrastre."""
    out = []
    out.append(dust(30, 108, 7))
    out.append(dust(48, 112, 6))
    out.append(burst(30, 64, 32, 14, 9, "ember", 4, 1.6))
    out.append(Sh(ellipse(30, 64, 11, 11), "gold", outline=False))
    arrow_shape = poly([(42, 44), (82, 44), (82, 20), (124, 64), (82, 108), (82, 84), (42, 84)])
    out.append(Sh(arrow_shape, "bone"))
    out.append(Sh(poly([(42, 64), (82, 64), (82, 84), (42, 84)]), "#000000", outline=False, op=0.1,
                  relief=False))
    out.append(Sh(Path().M(48, 52).L(78, 52), stroke="#FFFFFF", sw=2.8, outline=False, op=0.85))
    return out


def downed():
    """Yelmo caído de lado junto a una espada rota."""
    out = []
    out.append(Sh(ellipse(64, 104, 58, 8), "dust", outline=False, op=0.7))
    # espada rota: empuñadura con un muñón de hoja y el trozo suelto
    xf = move(88, 82) @ rot(100)
    hb = 4
    blade = poly([(-8, -hb), (-8, -27), (-3, -31), (0, -25), (4, -33), (8, -28), (8, -hb)], xf)
    out.append(Sh(blade, "steel", edge=1.6))
    out.append(Sh(rect(-3.6, hb - 1, 7.2, 17, 2.0, xf), "leather"))
    out.append(Sh(ellipse(0, hb + 19, 5.6, 5.6, xf), "bronze"))
    out.append(Sh(rpoly([(-17, -hb - 1.5), (17, -hb - 1.5), (15.5, hb + 1.5), (-15.5, hb + 1.5)], 2.6, xf),
                  "bronze"))
    frag = poly([(66, 96), (96, 97), (112, 99), (98, 104), (66, 103)])
    out.append(Sh(frag, "steel_dark", edge=1.4))
    # yelmo tumbado: la boca mira hacia la derecha
    out += helm(36, 76, 1.05, rot_deg=-80)
    out.append(Sh(Path().M(30, 40).L(26, 52).L(33, 60), stroke="#14100C", sw=2.2, outline=False, op=0.8))
    return out


def rooted():
    """Una bota atrapada: raíces que se enroscan en la caña y la hunden en el suelo."""
    out = []
    out.append(Sh(ellipse(64, 110, 58, 10), "earth"))
    boot = rpoly([(50, 6), (88, 6), (88, 98), (12, 98), (6, 86), (16, 74), (50, 68)],
                 [5, 5, 6, 12, 10, 8, 5])
    out.append(Sh(boot, "leather"))
    out.append(Sh(rect(48, 8, 42, 12, 3), "wood_dark", edge=1.4))
    out.append(Sh(rect(6, 92, 84, 9, 3), "wood_dark", edge=1.4))
    for y in (32, 44, 56):
        out.append(Sh(Path().M(56, y).L(80, y + 4), stroke="#E8D8B0", sw=2.2, outline=False, op=0.8))
    root = "#7B5731"
    out.append(tube(Path().M(38, 34).Q(66, 52, 98, 30), root, 8.5))
    out.append(tube(Path().M(38, 62).Q(66, 80, 98, 58), root, 8.5))
    out.append(tube(Path().M(98, 30).C(120, 56, 110, 90, 114, 112), root, 9))
    out.append(tube(Path().M(38, 62).C(18, 84, 28, 98, 12, 116), root, 9))
    out.append(tube(Path().M(98, 58).C(86, 80, 96, 100, 84, 116), root, 7))
    for x, y, a in ((98, 30, -50), (38, 34, 200), (38, 62, 190), (98, 58, 10)):
        out.append(Sh(ellipse(0, 0, 11, 5.5, move(x, y) @ rot(a)), "moss", edge=1.2))
    return out


# --------------------------------------------------------------------------------------------
# Variantes pequeñas de los estados (placas de nombre y fila de efectos): pocas piezas, formas
# macizas. Se dibujan en un lienzo de 128 y se rasterizan a su tamaño exacto con el contorno más
# grueso (ver make_icons.py).
# --------------------------------------------------------------------------------------------


def small_bleed():
    out = [_drop(64, 6, 120, 44)]
    out.append(Sh(ellipse(46, 80, 6, 11, rot(12, 46, 80)), "#FFE0DA", outline=False, op=0.85))
    return out


def small_regen():
    pts = [(46, 10), (82, 10), (82, 46), (118, 46), (118, 82), (82, 82), (82, 118), (46, 118), (46, 82),
           (10, 82), (10, 46), (46, 46)]
    out = [Sh(rpoly(pts, 6), "lime")]
    out.append(Sh(Path().M(54, 22).L(54, 50), stroke="#F4FFD0", sw=5, outline=False, op=0.8))
    return out


def small_stun():
    out = []
    out.append(Sh(star(34, 42, 34, 15, 5, start_deg=-100.0, round_r=3), "gold"))
    out.append(Sh(star(94, 34, 30, 13, 5, start_deg=-80.0, round_r=3), "gold"))
    out.append(Sh(star(62, 92, 36, 16, 5, start_deg=-92.0, round_r=3), "gold"))
    return out


def small_slowed():
    out = []
    for ang in (-90.0, -30.0, 30.0):
        x1, y1 = polar(64, 64, 50, ang)
        x2, y2 = polar(64, 64, 50, ang + 180)
        out.append(Sh(Path().M(x1, y1).L(x2, y2), stroke="#E4F6FF", sw=15, outline=True, ow=2.0))
    out.append(Sh(poly([polar(64, 64, 17, 30 + 60 * k) for k in range(6)]), "ice"))
    return out


def small_knockback():
    out = [burst(28, 64, 30, 13, 7, "ember", 4, 2.0)]
    out.append(Sh(poly([(46, 48), (84, 48), (84, 26), (122, 64), (84, 102), (84, 80), (46, 80)]), "bone"))
    return out


def small_downed():
    out = []
    out += helm(52, 66, 1.45, rot_deg=-80)
    out.append(Sh(poly([(86, 108), (124, 84), (128, 92), (96, 116)]), "steel"))
    return out


def small_rooted():
    """Un brote sobre el suelo y las raíces que se hunden: pocas piezas gruesas."""
    out = []
    root = "#8A6238"
    for x_end in (24, 64, 104):
        out.append(Sh(Path().M(64, 66).L(x_end, 118), stroke=root, sw=15, outline=True, ow=2.0))
    out.append(Sh(rect(6, 54, 116, 16, 6), "earth"))
    out.append(Sh(Path().M(64, 54).L(64, 26), stroke="#58763A", sw=10, outline=True, ow=2.0))
    out.append(Sh(ellipse(0, 0, 25, 13, move(38, 28) @ rot(-28)), "moss"))
    out.append(Sh(ellipse(0, 0, 25, 13, move(90, 28) @ rot(28)), "moss"))
    return out


# --------------------------------------------------------------------------------------------
# Registro: nombre -> (categoría de fondo, título en español, constructor)
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
    "weapon_sword_shield": ("mundo", "Espada y escudo", weapon_sword_shield),
    "weapon_bow": ("mundo", "Arco", weapon_bow),
    "interact": ("mundo", "Interactuar", interact),
    "bleed": ("estado_malo", "Sangrado", bleed),
    "regen": ("estado_bueno", "Regeneración", regen),
    "stun": ("estado_malo", "Aturdimiento", stun),
    "slowed": ("estado_malo", "Ralentización", slowed),
    "knockback": ("estado_malo", "Empuje", knockback),
    "downed": ("estado_malo", "Derribado", downed),
    "rooted": ("estado_malo", "Enraizado", rooted),
    "fort": ("mundo", "Fuerte", fort),
    "gate": ("mundo", "Puerta", gate),
    "camp": ("mundo", "Campamento", camp),
    "banner": ("mundo", "Estandarte", banner),
    "banner_vardheim": ("mundo", "Estandarte de Vardheim", banner_vardheim),
    "banner_solmarch": ("mundo", "Estandarte de Solmarch", banner_solmarch),
    "banner_askarra": ("mundo", "Estandarte de Askarra", banner_askarra),
    "banner_huecos": ("mundo", "Estandarte de los Huecos", banner_huecos),
}

SMALL_ICONS = {
    "bleed": ("estado_malo", "Sangrado", small_bleed),
    "regen": ("estado_bueno", "Regeneración", small_regen),
    "stun": ("estado_malo", "Aturdimiento", small_stun),
    "slowed": ("estado_malo", "Ralentización", small_slowed),
    "knockback": ("estado_malo", "Empuje", small_knockback),
    "downed": ("estado_malo", "Derribado", small_downed),
    "rooted": ("estado_malo", "Enraizado", small_rooted),
}


# Ajustes de encuadre por icono (ver svgkit.fit_transform): centro y cobertura objetivo. Los iconos
# que van por el suelo (esquiva) bajan; el resto se centra. Sirven para que las siluetas de una misma
# barra no ocupen el mismo sitio (qa.py mide el solape).
FIT = {
    "sword_light": dict(center=(68.0, 74.0)),
    "block": dict(center=(53.0, 74.0)),
    "dodge": dict(center=(62.0, 67.0), target=0.36),
    "shield_bash": dict(center=(66.0, 47.0)),
    "shield_rush": dict(center=(74.0, 57.0)),
    "shield_wall": dict(center=(54.0, 49.0)),
    "potion_health": dict(center=(56.0, 70.0)),
    "potion_stamina": dict(center=(65.0, 62.0), target=0.36),
    "swap_weapon": dict(center=(70.0, 60.0)),
    "weapon_sword_shield": dict(center=(75.0, 80.0), target=0.36),
    "weapon_bow": dict(center=(53.0, 57.0), target=0.36),
    "bow_slowing_shot": dict(center=(65.0, 75.0)),
    "bow_evasive_shot": dict(center=(60.0, 76.0), target=0.38),
    "bow_volley": dict(center=(59.0, 61.0)),
    "bow_drawn": dict(center=(59.0, 68.0)),
    "bow_quick": dict(center=(62.0, 74.0)),
}
